import XCTest
import Metal
import simd
@testable import CTModels
@testable import CTStudioApp

final class ShaderGraphCompilerTests: XCTestCase {
    func testCompilesDefaultGraphToWellFormedMSL() throws {
        let source = try ShaderGraphCompiler.compile(ShaderGraph.defaultGraph(), functionName: "fragment_test")
        XCTAssertTrue(source.contains("fragment float4 fragment_test("))
        // Each node materializes into its own named temp (`in.uv` feeds the
        // sample call *through* that temp, not inline), check each real
        // fact independently rather than one exact-string match that would
        // be brittle to the (deterministic but incidental) temp-naming order.
        XCTAssertTrue(source.contains("= in.uv;"), "the UV node's own real vertex-stage input")
        XCTAssertTrue(source.contains("colorTexture.sample(textureSampler, n"), "the default graph samples the bound texture using the UV node's output")
        XCTAssertTrue(source.contains("= in.color;"), "the default graph reads real vertex color")
        XCTAssertTrue(source.contains(" * "), "the default graph multiplies texture by vertex color")
        XCTAssertTrue(source.contains("return n"))
    }

    func testMissingFinalColorNodeThrows() {
        let graph = ShaderGraph(nodes: [ShaderGraphNode(kind: .uv)], connections: [])
        XCTAssertThrowsError(try ShaderGraphCompiler.compile(graph, functionName: "f")) { error in
            XCTAssertEqual(error as? ShaderGraphCompiler.CompileError, .noFinalColorNode)
        }
    }

    func testCycleIsDetectedRatherThanInfiniteLooping() {
        let a = ShaderGraphNode(kind: .add)
        let b = ShaderGraphNode(kind: .add)
        let final = ShaderGraphNode(kind: .finalColor)
        // a <- b <- a: a genuine cycle (a feeds b, b feeds a).
        let graph = ShaderGraph(
            nodes: [a, b, final],
            connections: [
                ShaderGraphConnection(fromNodeID: b.id, toNodeID: a.id, toPortIndex: 0),
                ShaderGraphConnection(fromNodeID: a.id, toNodeID: b.id, toPortIndex: 0),
                ShaderGraphConnection(fromNodeID: a.id, toNodeID: final.id, toPortIndex: 0),
            ]
        )
        XCTAssertThrowsError(try ShaderGraphCompiler.compile(graph, functionName: "f")) { error in
            XCTAssertEqual(error as? ShaderGraphCompiler.CompileError, .cycleDetected)
        }
    }

    /// A node feeding a differently-typed port (float2 UV into a float4-
    /// expecting `add`) must be auto-converted, not left to (possibly
    /// invalid) MSL implicit conversion, this is what actually lets
    /// `testAppliedShaderGraphCompilesARealMetalPipeline` below succeed for
    /// graphs mixing UV/color/normal nodes freely.
    func testMismatchedTypesAreExplicitlyConverted() throws {
        let uv = ShaderGraphNode(kind: .uv)
        let add = ShaderGraphNode(kind: .add)
        let final = ShaderGraphNode(kind: .finalColor)
        let graph = ShaderGraph(
            nodes: [uv, add, final],
            connections: [
                ShaderGraphConnection(fromNodeID: uv.id, toNodeID: add.id, toPortIndex: 0),
                ShaderGraphConnection(fromNodeID: add.id, toNodeID: final.id, toPortIndex: 0),
            ]
        )
        let source = try ShaderGraphCompiler.compile(graph, functionName: "f")
        XCTAssertTrue(source.contains("= in.uv;"), "the UV node's own real value")
        XCTAssertTrue(source.contains(", 0.0, 0.0)"), "float2 -> float4 must pad with zeros, not be left mismatched")
    }
}

final class ShaderGraphIntegrationTests: XCTestCase {
    private func makeTestAsset() -> ResolvedModelAsset {
        let vertices = [
            StaticVertex(position: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 0)),
            StaticVertex(position: SIMD3(1, 0, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(1, 0)),
            StaticVertex(position: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 1))
        ]
        let submesh = MeshSubmesh(vertices: vertices, connectivity: [true, true, true], materialID: 1)
        let mesh = MeshAsset(id: 1, isSkinned: false, submeshes: [submesh])
        let texture = TextureAsset(id: 1, width: 2, height: 2, pixelFormat: .psmct32, rgba: [UInt8](repeating: 200, count: 16))
        let material = ResolvedSubmeshMaterial(materialID: 1, textureID: 1, texture: texture)
        return ResolvedModelAsset(recordID: 1, displayName: "Test Triangle", mesh: mesh, submeshMaterials: [material])
    }

    /// The real end-to-end check: compiled MSL from a graph that exercises
    /// every node kind (texture sample, vertex color, world normal, math,
    /// UV manipulation, dot/normalize) must actually compile into a real
    /// `MTLRenderPipelineState` and render a frame without crashing , 
    /// proof this is genuine, working Metal integration, not just
    /// structurally-plausible strings.
    func testAppliedShaderGraphCompilesARealMetalPipelineAndRenders() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let uv = ShaderGraphNode(kind: .uv)
        let sample = ShaderGraphNode(kind: .textureSample)
        let color = ShaderGraphNode(kind: .vertexColor)
        let normal = ShaderGraphNode(kind: .worldNormal)
        let normalized = ShaderGraphNode(kind: .normalizeVec)
        let dot = ShaderGraphNode(kind: .dotProduct)
        let scaled = ShaderGraphNode(kind: .uvScale)
        let offset = ShaderGraphNode(kind: .uvOffset)
        let mul = ShaderGraphNode(kind: .multiply)
        let sat = ShaderGraphNode(kind: .saturate)
        let final = ShaderGraphNode(kind: .finalColor)

        let graph = ShaderGraph(
            nodes: [uv, sample, color, normal, normalized, dot, scaled, offset, mul, sat, final],
            connections: [
                ShaderGraphConnection(fromNodeID: uv.id, toNodeID: scaled.id, toPortIndex: 0),
                ShaderGraphConnection(fromNodeID: scaled.id, toNodeID: offset.id, toPortIndex: 0),
                ShaderGraphConnection(fromNodeID: offset.id, toNodeID: sample.id, toPortIndex: 0),
                ShaderGraphConnection(fromNodeID: normal.id, toNodeID: normalized.id, toPortIndex: 0),
                ShaderGraphConnection(fromNodeID: normalized.id, toNodeID: dot.id, toPortIndex: 0),
                ShaderGraphConnection(fromNodeID: normalized.id, toNodeID: dot.id, toPortIndex: 1),
                ShaderGraphConnection(fromNodeID: sample.id, toNodeID: mul.id, toPortIndex: 0),
                ShaderGraphConnection(fromNodeID: color.id, toNodeID: mul.id, toPortIndex: 1),
                ShaderGraphConnection(fromNodeID: mul.id, toNodeID: sat.id, toPortIndex: 0),
                ShaderGraphConnection(fromNodeID: sat.id, toNodeID: final.id, toPortIndex: 0),
            ]
        )

        let mslSource = try ShaderGraphCompiler.compile(graph, functionName: "fragment_graph_test")
        let renderer = try XCTUnwrap(ModelViewerRenderer(asset: makeTestAsset()))
        let result = renderer.applyShaderGraph(mslFragmentSource: mslSource, functionName: "fragment_graph_test")
        switch result {
        case .success: break
        case .failure(let error): return XCTFail("Real MSL failed to compile into a pipeline: \(error)")
        }

        let image = renderer.renderOffscreen(width: 64, height: 64)
        XCTAssertNotNil(image, "the custom shader-graph pipeline must actually render a frame")
    }

    func testClearingOverrideRevertsToDefaultPipeline() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let renderer = try XCTUnwrap(ModelViewerRenderer(asset: makeTestAsset()))
        let mslSource = try ShaderGraphCompiler.compile(ShaderGraph.defaultGraph(), functionName: "fragment_clear_test")
        guard case .success = renderer.applyShaderGraph(mslFragmentSource: mslSource, functionName: "fragment_clear_test") else {
            return XCTFail("Setup failed: couldn't apply the shader graph the first time")
        }
        renderer.clearShaderGraphOverride()
        XCTAssertNotNil(renderer.renderOffscreen(width: 32, height: 32), "must still render correctly after reverting to the default pipeline")
    }
}
