import XCTest
import Metal
import simd
@testable import CTModels
@testable import CTStudioApp

/// "Procedural Collision Decimation" (roadmap 4.4) correctness tests: this
/// is a real algorithm run on real (synthetic, for a controlled test) mesh
/// data, not decoded game data, so unlike the disc-gated tests elsewhere
/// in this suite, the right check here is "does the OBB math actually
/// recover a known box," not "does this match real game data."
final class CollisionDecimatorTests: XCTestCase {
    private func makeMesh(vertices: [SIMD3<Float>]) -> MeshAsset {
        let staticVertices = vertices.map { StaticVertex(position: $0) }
        // A flat triangle strip is enough, `CollisionDecimator` only reads
        // vertex positions, connectivity/topology is irrelevant to it.
        let submesh = MeshSubmesh(vertices: staticVertices, connectivity: [Bool](repeating: false, count: staticVertices.count))
        return MeshAsset(id: 0, isSkinned: false, submeshes: [submesh])
    }

    func testRecoversAxisAlignedBoxExtent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available in this environment")
        }
        // An axis-aligned box, 4x2x1 half-extents, centered at the origin , 
        // every corner plus a few interior/face points so the covariance
        // isn't degenerate.
        let corners: [SIMD3<Float>] = [
            SIMD3(-4, -2, -1), SIMD3(4, -2, -1), SIMD3(4, 2, -1), SIMD3(-4, 2, -1),
            SIMD3(-4, -2, 1), SIMD3(4, -2, 1), SIMD3(4, 2, 1), SIMD3(-4, 2, 1)
        ]
        let mesh = makeMesh(vertices: corners)
        let obb = try XCTUnwrap(CollisionDecimator.computeOrientedBoundingBox(mesh: mesh, device: device))

        XCTAssertEqual(simd_length(obb.center), 0, accuracy: 0.01)
        let sortedExtents = [obb.halfExtents.x, obb.halfExtents.y, obb.halfExtents.z].sorted()
        XCTAssertEqual(sortedExtents[0], 1, accuracy: 0.01)
        XCTAssertEqual(sortedExtents[1], 2, accuracy: 0.01)
        XCTAssertEqual(sortedExtents[2], 4, accuracy: 0.01)

        // Every real corner must lie inside (or exactly on) the computed
        // box, the actual "does this hull encapsulate the geometry"
        // property a collision hull needs, not just matching extents.
        for corner in corners {
            let d = corner - obb.center
            let projections = [simd_dot(d, obb.axes.0), simd_dot(d, obb.axes.1), simd_dot(d, obb.axes.2)]
            let extents = [obb.halfExtents.x, obb.halfExtents.y, obb.halfExtents.z]
            for i in 0..<3 {
                XCTAssertLessThanOrEqual(abs(projections[i]), extents[i] + 0.01, "corner \(corner) escapes the computed OBB on axis \(i)")
            }
        }
    }

    func testRecoversRotatedBoxPrincipalAxis() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available in this environment")
        }
        // A long, thin box (half-extents 10x1x1) rotated 37° around Z , 
        // the OBB's longest axis should recover that rotation, unlike a
        // plain AABB which would report a much larger, loose extent.
        let angle: Float = 37 * .pi / 180
        let rotation = simd_quatf(angle: angle, axis: SIMD3(0, 0, 1))
        let localCorners: [SIMD3<Float>] = [
            SIMD3(-10, -1, -1), SIMD3(10, -1, -1), SIMD3(10, 1, -1), SIMD3(-10, 1, -1),
            SIMD3(-10, -1, 1), SIMD3(10, -1, 1), SIMD3(10, 1, 1), SIMD3(-10, 1, 1)
        ]
        let worldCorners = localCorners.map { rotation.act($0) }
        let mesh = makeMesh(vertices: worldCorners)
        let obb = try XCTUnwrap(CollisionDecimator.computeOrientedBoundingBox(mesh: mesh, device: device))

        let expectedLongAxis = rotation.act(SIMD3<Float>(1, 0, 0))
        // The eigenvector's sign is arbitrary (±axis both diagonalize the
        // same covariance), so compare via absolute dot product.
        let alignment = abs(simd_dot(obb.axes.0, expectedLongAxis))
        XCTAssertGreaterThan(alignment, 0.999, "OBB's primary axis should recover the box's real 37° rotation")
        XCTAssertEqual(obb.halfExtents.x, 10, accuracy: 0.05)
    }

    func testEmptyMeshReturnsNil() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let mesh = makeMesh(vertices: [])
        XCTAssertNil(CollisionDecimator.computeOrientedBoundingBox(mesh: mesh, device: device))
    }
}

extension CollisionDecimatorTests {
    /// An already-diagonal covariance matrix needs zero Jacobi rotations , 
    /// the eigenvectors should come back as exactly the standard basis, in
    /// descending-eigenvalue order (16, 4, 1 -> X, Y, Z).
    func testJacobiEigenvectorsTrivialForDiagonalInput() throws {
        let diag = simd_float3x3(SIMD3<Float>(16, 0, 0), SIMD3<Float>(0, 4, 0), SIMD3<Float>(0, 0, 1))
        let axes = CollisionDecimator.jacobiEigenvectors(of: diag)
        XCTAssertEqual(axes.0, SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(axes.1, SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(axes.2, SIMD3<Float>(0, 0, 1))
    }
}
