import XCTest
import simd
@testable import CTModels
@testable import CTStudioApp

final class VertexColorBakerTests: XCTestCase {
    private func makeFlatQuadMesh(normal: SIMD3<Float> = SIMD3(0, 1, 0)) -> MeshAsset {
        // Two triangles forming a flat quad on the XZ plane, all normals
        // pointing straight up, starting white.
        let vertices = [
            StaticVertex(position: SIMD3(-1, 0, -1), normal: normal, color: SIMD4(255, 255, 255, 255)),
            StaticVertex(position: SIMD3(1, 0, -1), normal: normal, color: SIMD4(255, 255, 255, 255)),
            StaticVertex(position: SIMD3(-1, 0, 1), normal: normal, color: SIMD4(255, 255, 255, 255)),
            StaticVertex(position: SIMD3(1, 0, 1), normal: normal, color: SIMD4(255, 255, 255, 255))
        ]
        let submesh = MeshSubmesh(vertices: vertices, connectivity: [true, true, true, true], materialID: 1)
        return MeshAsset(id: 1, isSkinned: false, submeshes: [submesh])
    }

    // MARK: - Directional light

    func testVertexFacingTheLightIsBrighterThanVertexFacingAway() {
        let towardLight = makeFlatQuadMesh(normal: SIMD3(0, 1, 0)) // light comes from directly above
        let awayFromLight = makeFlatQuadMesh(normal: SIMD3(0, -1, 0))

        let bakedToward = VertexColorBaker.bakeDirectionalLight(towardLight, lightDirection: SIMD3(0, -1, 0), ambient: 0.1, intensity: 1.0)
        let bakedAway = VertexColorBaker.bakeDirectionalLight(awayFromLight, lightDirection: SIMD3(0, -1, 0), ambient: 0.1, intensity: 1.0)

        let brightToward = bakedToward.submeshes[0].vertices[0].color.x
        let dimAway = bakedAway.submeshes[0].vertices[0].color.x
        XCTAssertGreaterThan(brightToward, dimAway, "a surface facing the light must end up brighter than one facing away from it")
        XCTAssertEqual(dimAway, UInt8(0.1 * 255), accuracy: 2, "a surface facing fully away from the light should sit right at the ambient floor")
    }

    func testDirectionalBakePreservesAlpha() {
        let mesh = makeFlatQuadMesh()
        let baked = VertexColorBaker.bakeDirectionalLight(mesh, lightDirection: SIMD3(0, -1, 0))
        XCTAssertEqual(baked.submeshes[0].vertices[0].color.w, 255)
    }

    func testAmbientFloorPreventsFullBlack() {
        let mesh = makeFlatQuadMesh(normal: SIMD3(0, -1, 0)) // fully away from the light
        let baked = VertexColorBaker.bakeDirectionalLight(mesh, lightDirection: SIMD3(0, -1, 0), ambient: 0.3, intensity: 1.0)
        XCTAssertGreaterThan(baked.submeshes[0].vertices[0].color.x, 0, "the ambient floor must keep a fully-shadowed vertex above pure black")
    }

    // MARK: - Ray-triangle intersection (Möller–Trumbore)

    func testRayHitsATriangleDirectlyInFront() {
        let triangle = (SIMD3<Float>(-1, 0, 2), SIMD3<Float>(1, 0, 2), SIMD3<Float>(0, 2, 2))
        let hit = VertexColorBaker.rayHitsAnyTriangle(origin: .zero, direction: SIMD3(0, 0, 1), maxDistance: 10, triangles: [triangle])
        XCTAssertTrue(hit)
    }

    func testRayMissesATriangleBehindIt() {
        let triangle = (SIMD3<Float>(-1, 0, -2), SIMD3<Float>(1, 0, -2), SIMD3<Float>(0, 2, -2))
        let hit = VertexColorBaker.rayHitsAnyTriangle(origin: .zero, direction: SIMD3(0, 0, 1), maxDistance: 10, triangles: [triangle])
        XCTAssertFalse(hit, "a triangle behind the ray origin must not register as a hit")
    }

    func testRayMissesATriangleBeyondMaxDistance() {
        let triangle = (SIMD3<Float>(-1, 0, 100), SIMD3<Float>(1, 0, 100), SIMD3<Float>(0, 2, 100))
        let hit = VertexColorBaker.rayHitsAnyTriangle(origin: .zero, direction: SIMD3(0, 0, 1), maxDistance: 10, triangles: [triangle])
        XCTAssertFalse(hit, "a triangle beyond maxDistance must not register as a hit")
    }

    // MARK: - Ambient occlusion

    /// A single flat, isolated quad has nothing above it to occlude a
    /// hemisphere of rays cast from its own normal direction, occlusion
    /// should end up near zero (bright), not darkened.
    func testOpenFlatSurfaceHasNearZeroOcclusion() {
        let mesh = makeFlatQuadMesh(normal: SIMD3(0, 1, 0))
        let baked = VertexColorBaker.bakeAmbientOcclusion(mesh, sampleCount: 32, maxDistance: 5, strength: 1.0)
        // Rays from a point ON its own triangle, offset along the normal,
        // sampling a hemisphere around that same normal, should never
        // re-hit the flat quad they started on (all samples point away
        // from the surface), real near-zero occlusion, not just "less than 1".
        XCTAssertGreaterThan(baked.submeshes[0].vertices[0].color.x, 250)
    }

    /// A vertex centered inside a mostly-enclosing box of triangles
    /// (walls all around within sampling range) should register real,
    /// substantial occlusion, not the same near-zero result as the open
    /// surface case above.
    func testEnclosedVertexHasHigherOcclusionThanOpenSurface() {
        // A small cube surrounding the origin (each face two triangles),
        // with a single test vertex placed on the +Y face pointing inward
        // is complex to construct by hand; instead approximate "mostly
        // enclosed" with five real walls (missing the +Y face) around a
        // point just above the floor, normal pointing up into the open
        // vs. having a real ceiling triangle placed close overhead.
        let ceiling = MeshSubmesh(
            vertices: [
                StaticVertex(position: SIMD3(-5, 0.5, -5), normal: SIMD3(0, -1, 0)),
                StaticVertex(position: SIMD3(5, 0.5, -5), normal: SIMD3(0, -1, 0)),
                StaticVertex(position: SIMD3(-5, 0.5, 5), normal: SIMD3(0, -1, 0)),
                StaticVertex(position: SIMD3(5, 0.5, 5), normal: SIMD3(0, -1, 0))
            ],
            connectivity: [true, true, true, true],
            materialID: 1
        )
        let floor = makeFlatQuadMesh(normal: SIMD3(0, 1, 0)).submeshes[0]
        let enclosedMesh = MeshAsset(id: 1, isSkinned: false, submeshes: [floor, ceiling])
        let openMesh = MeshAsset(id: 2, isSkinned: false, submeshes: [floor])

        let bakedEnclosed = VertexColorBaker.bakeAmbientOcclusion(enclosedMesh, sampleCount: 48, maxDistance: 2.0, strength: 1.0)
        let bakedOpen = VertexColorBaker.bakeAmbientOcclusion(openMesh, sampleCount: 48, maxDistance: 2.0, strength: 1.0)

        let enclosedBrightness = bakedEnclosed.submeshes[0].vertices[0].color.x
        let openBrightness = bakedOpen.submeshes[0].vertices[0].color.x
        XCTAssertLessThan(enclosedBrightness, openBrightness, "a vertex with a close ceiling above it must register more occlusion (be darker) than the same vertex with open sky")
    }
}
