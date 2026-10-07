import XCTest
import simd
@testable import CTModels
@testable import CTStudioApp

/// Regression tests for a real, reported request: Scenery-tab placement
/// used to spawn immediately at the viewer's own camera position the
/// instant a thumbnail was clicked, unlike every other placeable type in
/// this build (Forge Palette objects, Instance/Trigger/Camera "Add"), which
/// all arm-then-click. `pendingPlacementScenery`/`placeScenery` give scenery
/// the exact same arm-then-click mechanics `pendingPlacementObjectID`/
/// `placeObject` already have, including landing on the real collision
/// surface, the same "Drop-to-Floor Placement" raycast object placement
/// already gets (see `DropToFloorPlacementTests`, which this mirrors).
@MainActor
final class SceneryPlacementArmTests: XCTestCase {
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
        return ResolvedModelAsset(recordID: 42, displayName: "Test Scenery Model", mesh: mesh, submeshMaterials: [material])
    }

    func testPlaceSceneryLandsOnRealCollisionSurfaceInsteadOfGroundPlane() throws {
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [], collisionMeshes: [makeRaisedPlatform(height: 8)]))
        renderer.pendingPlacementScenery = LevelViewerRenderer.PendingSceneryPlacement(
            modelID: 7, isSpecial: false, asset: makeTestAsset(), crossLevelSource: nil
        )
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        let index = try XCTUnwrap(renderer.placeScenery(at: center, viewSize: viewSize))
        let summary = try XCTUnwrap(renderer.objectSummaries.first { $0.index == index })
        // `+ placementGroundClearance`: a real, disclosed best-effort
        // clearance now added on top of the raw surface hit, to avoid
        // real, reported angle-dependent depth-fight flicker (both in this
        // app's own preview and, more importantly, in a real PCSX2 boot)
        // between a freshly-placed object and the surface it landed on.
        XCTAssertEqual(summary.worldPosition.y, 8 + LevelViewerRenderer.placementGroundClearance, accuracy: 0.01, "a freshly armed-and-placed scenery item should drop onto the real platform surface (plus the small clearance placement now adds), not always spawn at the camera position")
    }

    func testPlaceSceneryFallsBackToGroundPlaneWithNoCollisionData() throws {
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: []))
        renderer.pendingPlacementScenery = LevelViewerRenderer.PendingSceneryPlacement(
            modelID: 7, isSpecial: false, asset: makeTestAsset(), crossLevelSource: nil
        )
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        let index = try XCTUnwrap(renderer.placeScenery(at: center, viewSize: viewSize))
        let summary = try XCTUnwrap(renderer.objectSummaries.first { $0.index == index })
        // See the collision-surface test above on `+ placementGroundClearance`.
        XCTAssertEqual(summary.worldPosition.y, 0 + LevelViewerRenderer.placementGroundClearance, accuracy: 0.01, "with no collision data, placement should still work via the ground-plane fallback (plus the small clearance placement now adds)")
    }

    func testPlaceSceneryReturnsNilWithNothingArmed() throws {
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: []))
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        XCTAssertNil(renderer.placeScenery(at: center, viewSize: viewSize), "nothing armed means nothing to place")
    }

    /// Single-shot, same as `placeObject`: one viewport click places exactly
    /// one copy and disarms, a second click without re-arming must do
    /// nothing, not silently keep stamping copies.
    func testPlaceSceneryDisarmsAfterOnePlacement() throws {
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: []))
        renderer.pendingPlacementScenery = LevelViewerRenderer.PendingSceneryPlacement(
            modelID: 7, isSpecial: false, asset: makeTestAsset(), crossLevelSource: nil
        )
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        _ = renderer.placeScenery(at: center, viewSize: viewSize)
        XCTAssertNil(renderer.pendingPlacementScenery, "placing must disarm, one shot per arm, matching placeObject")
        XCTAssertNil(renderer.placeScenery(at: center, viewSize: viewSize), "a second click with nothing re-armed must place nothing")
    }
}
