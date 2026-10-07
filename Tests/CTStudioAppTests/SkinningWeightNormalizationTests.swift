import XCTest
import Metal
import simd
@testable import CTModels
@testable import CTStudioApp

/// Regression test for the "animation crumpling" bug: `skinVertices` used
/// to sum `weight * (matrix * position)` across up to 4 joint lanes but
/// never divided by the total weight actually applied. Any vertex whose
/// `jointIndices` referenced a joint absent from that frame's
/// `skinningMatrices` dictionary (a real, unremarkable occurrence, the
/// dictionary only contains entries for joints the current animation track
/// actually touched) got its position scaled down by the *missing*
/// fraction, pulling it toward the coordinate origin. Across a whole mesh
/// that reads as "the model scrunches into a ball."
final class SkinningWeightNormalizationTests: XCTestCase {
    private func makeTexture(device: MTLDevice) throws -> MTLTexture {
        let asset = TextureAsset(id: 1, width: 2, height: 2, pixelFormat: .psmct32, rgba: [UInt8](repeating: 200, count: 16))
        return try XCTUnwrap(ModelViewerRenderer.makeTexture(device: device, asset: asset))
    }

    /// One vertex, two joint influences (0.6 / 0.4). Joint 0 is present in
    /// `skinningMatrices` (identity); joint 99 is deliberately absent,
    /// simulating a joint this frame's animation track didn't touch. Real
    /// linear-blend skinning must still reproduce the bind-pose position
    /// exactly here, since the only joint that *did* resolve is an
    /// identity transform, before the fix, the missing 0.4 of weight
    /// silently scaled the result down to 60% of bind position instead.
    func testPartiallyResolvedJointWeightsDoNotCollapseTowardOrigin() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available in this environment")
        }

        let bindPosition = SIMD3<Float>(2, 0, 4)
        let bindVertices = [StaticVertex(position: bindPosition, normal: SIMD3(0, 0, 1))]
        let jointIndices: [SIMD4<UInt16>] = [SIMD4(0, 99, 0, 0)]
        let jointWeights: [SIMD4<Float>] = [SIMD4(0.6, 0.4, 0, 0)]

        let vertexBuffer = try XCTUnwrap(device.makeBuffer(length: MemoryLayout<ModelVertexGPU>.stride, options: .storageModeShared))
        let indexBuffer = try XCTUnwrap(device.makeBuffer(length: MemoryLayout<UInt16>.stride, options: .storageModeShared))

        let submesh = GPUSubmesh(
            originalIndex: 0,
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            indexCount: 0,
            texture: try makeTexture(device: device),
            bindVertices: bindVertices,
            jointIndices: jointIndices,
            jointWeights: jointWeights
        )

        // Only joint 0 (identity) resolves; joint 99 is absent, exactly
        // the "animation track never touched this joint this frame" case.
        let skinningMatrices: [UInt32: simd_float4x4] = [0: matrix_identity_float4x4]

        ModelViewerRenderer.skinVertices(submesh: submesh, skinningMatrices: skinningMatrices)

        let ptr = vertexBuffer.contents().bindMemory(to: ModelVertexGPU.self, capacity: 1)
        let result = SIMD3<Float>(ptr[0].px, ptr[0].py, ptr[0].pz)

        XCTAssertEqual(result.x, bindPosition.x, accuracy: 0.001)
        XCTAssertEqual(result.y, bindPosition.y, accuracy: 0.001)
        XCTAssertEqual(result.z, bindPosition.z, accuracy: 0.001)
    }

    /// When a vertex has real weight from two joints that both resolve, and
    /// one of them is a translation, the blended result must land on the
    /// real weighted average, not be scaled down, confirming the
    /// renormalization doesn't just cancel out in the single-joint case
    /// above but also holds for a genuine multi-joint blend.
    func testFullyResolvedTwoJointBlendAveragesCorrectly() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available in this environment")
        }

        let bindPosition = SIMD3<Float>(0, 0, 0)
        let bindVertices = [StaticVertex(position: bindPosition, normal: SIMD3(0, 0, 1))]
        let jointIndices: [SIMD4<UInt16>] = [SIMD4(0, 1, 0, 0)]
        let jointWeights: [SIMD4<Float>] = [SIMD4(0.5, 0.5, 0, 0)]

        let vertexBuffer = try XCTUnwrap(device.makeBuffer(length: MemoryLayout<ModelVertexGPU>.stride, options: .storageModeShared))
        let indexBuffer = try XCTUnwrap(device.makeBuffer(length: MemoryLayout<UInt16>.stride, options: .storageModeShared))

        let submesh = GPUSubmesh(
            originalIndex: 0,
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            indexCount: 0,
            texture: try makeTexture(device: device),
            bindVertices: bindVertices,
            jointIndices: jointIndices,
            jointWeights: jointWeights
        )

        var translated = matrix_identity_float4x4
        translated.columns.3 = SIMD4(10, 0, 0, 1)
        let skinningMatrices: [UInt32: simd_float4x4] = [0: matrix_identity_float4x4, 1: translated]

        ModelViewerRenderer.skinVertices(submesh: submesh, skinningMatrices: skinningMatrices)

        let ptr = vertexBuffer.contents().bindMemory(to: ModelVertexGPU.self, capacity: 1)
        let result = SIMD3<Float>(ptr[0].px, ptr[0].py, ptr[0].pz)

        // 0.5 * (0,0,0) + 0.5 * (10,0,0) = (5,0,0), total weight already 1
        // so renormalization is a no-op here, this pins that the fix
        // didn't disturb the already-correct fully-resolved case.
        XCTAssertEqual(result.x, 5, accuracy: 0.001)
        XCTAssertEqual(result.y, 0, accuracy: 0.001)
        XCTAssertEqual(result.z, 0, accuracy: 0.001)
    }
}
