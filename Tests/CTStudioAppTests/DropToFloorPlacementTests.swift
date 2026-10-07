import XCTest
import simd
@testable import CTModels
@testable import CTStudioApp

/// "Drop-to-Floor Placement": `placeObject` should raycast against the
/// level's real collision mesh and land there, not always fall back to the
/// flat ground-plane heuristic, the previous behavior for every placement,
/// which is wrong for anything above/below the level's vertical center
/// (a raised platform, a sunken pit).
@MainActor
final class DropToFloorPlacementTests: XCTestCase {
    /// A large flat quad (two triangles) at a fixed height, spanning a wide
    /// enough XZ range that a screen-center click ray (default orbit
    /// camera, looking at the origin) is guaranteed to cross it.
    private func makeRaisedPlatform(height: Float) -> CollisionMesh {
        let vertices: [SIMD4<Float>] = [
            SIMD4(-20, height, -20, 1),
            SIMD4(20, height, -20, 1),
            SIMD4(20, height, 20, 1),
            SIMD4(-20, height, 20, 1),
        ]
        let triangles = [
            CollisionTriangle(vertexIndex1: 0, vertexIndex2: 1, vertexIndex3: 2, surfaceID: 1),
            CollisionTriangle(vertexIndex1: 0, vertexIndex2: 2, vertexIndex3: 3, surfaceID: 1),
        ]
        return CollisionMesh(id: 1, vertices: vertices, triangles: triangles, groups: [], triggerBoxes: [])
    }

    func testWorldPositionOnCollisionMeshHitsARaisedPlatformNotTheGroundPlane() throws {
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [], collisionMeshes: [makeRaisedPlatform(height: 5)]))
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        let hit = try XCTUnwrap(renderer.worldPositionOnCollisionMesh(at: center, viewSize: viewSize), "a screen-center ray should hit the wide platform under the default orbit camera")
        XCTAssertEqual(hit.y, 5, accuracy: 0.01, "should land on the real collision surface, not the flat ground-plane default (y=0)")
    }

    func testWorldPositionOnCollisionMeshReturnsNilWithNoCollisionData() throws {
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: []))
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        XCTAssertNil(renderer.worldPositionOnCollisionMesh(at: center, viewSize: viewSize), "no collision data means nothing to hit -- caller should fall back to the ground plane")
    }

    func testPlaceObjectLandsOnRealCollisionSurfaceInsteadOfGroundPlane() throws {
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [], collisionMeshes: [makeRaisedPlatform(height: 8)]))
        renderer.pendingPlacementObjectID = 1
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        let index = try XCTUnwrap(renderer.placeObject(at: center, viewSize: viewSize))
        let summary = try XCTUnwrap(renderer.objectSummaries.first { $0.index == index })
        XCTAssertEqual(summary.worldPosition.y, 8, accuracy: 0.01, "a freshly placed object should drop onto the real platform surface, not the ground-plane default")
    }

    func testPlaceObjectFallsBackToGroundPlaneWithNoCollisionData() throws {
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: []))
        renderer.pendingPlacementObjectID = 1
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        let index = try XCTUnwrap(renderer.placeObject(at: center, viewSize: viewSize))
        let summary = try XCTUnwrap(renderer.objectSummaries.first { $0.index == index })
        XCTAssertEqual(summary.worldPosition.y, 0, accuracy: 0.01, "with no collision data, placement should still work via the ground-plane fallback")
    }
}
