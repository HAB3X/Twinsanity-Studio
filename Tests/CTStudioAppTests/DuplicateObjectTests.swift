import XCTest
import simd
@testable import CTModels
@testable import CTStudioApp

/// "Unrestricted Chunk Free-Edit Mode", duplication through the real
/// spawn+write-back pipeline, not a purely visual copy.
@MainActor
final class DuplicateObjectTests: XCTestCase {
    private func makeRenderer() throws -> LevelViewerRenderer {
        try XCTUnwrap(LevelViewerRenderer(placements: []))
    }

    func testDuplicatingAFreshlyPlacedActorSpawnsARealSecondInstance() throws {
        let renderer = try makeRenderer()
        guard let originalIndex = renderer.spawnInstance(objectID: 42, at: SIMD3<Float>(5, 0, 5)) else {
            return XCTFail("spawnInstance failed, asset resolution unavailable in this test environment")
        }
        XCTAssertTrue(renderer.canDuplicate(at: originalIndex))

        let countBefore = renderer.objectCount
        guard let duplicateIndex = renderer.duplicateSelectedObject() else {
            return XCTFail("duplicateSelectedObject returned nil for a real, duplicable actor")
        }
        XCTAssertEqual(renderer.objectCount, countBefore + 1)
        XCTAssertNotEqual(duplicateIndex, originalIndex)

        // Real write-back: the duplicate must carry its own real objectID,
        // ready for the exact same insertion pipeline a fresh Forge
        // Palette placement uses.
        let duplicateInfo = try XCTUnwrap(renderer.newInstanceInfo(at: duplicateIndex))
        XCTAssertEqual(duplicateInfo.objectID, 42)
        // Offset, not stacked exactly on top of the original, a
        // duplicate landing pixel-identical to its source would be
        // impossible to tell apart or grab with the gizmo.
        XCTAssertNotEqual(duplicateInfo.worldPosition, SIMD3<Float>(5, 0, 5))
    }

    func testDuplicatingAnAIWaypointPreservesItsRealNodeType() throws {
        let renderer = try makeRenderer()
        guard let originalIndex = renderer.spawnAIWaypoint(at: SIMD3<Float>(1, 2, 3), rawNodeType: 2) else {
            return XCTFail("spawnAIWaypoint failed")
        }
        renderer.select(index: originalIndex)
        XCTAssertTrue(renderer.canDuplicate(at: originalIndex))

        guard let duplicateIndex = renderer.duplicateSelectedObject() else {
            return XCTFail("duplicateSelectedObject returned nil for a real, duplicable AI waypoint")
        }
        let duplicateInfo = try XCTUnwrap(renderer.newAIWaypointInfo(at: duplicateIndex))
        XCTAssertEqual(duplicateInfo.rawNodeType, 2, "the real node type must carry over, not reset to a default")
    }

    func testDuplicateWithNoSelectionIsANoOp() throws {
        let renderer = try makeRenderer()
        XCTAssertNil(renderer.duplicateSelectedObject())
    }

    func testDuplicatingATriggerSpawnsARealSecondTrigger() throws {
        let renderer = try makeRenderer()
        let originalIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(1, 0, 1)))
        renderer.select(index: originalIndex)
        XCTAssertTrue(renderer.canDuplicate(at: originalIndex))

        let countBefore = renderer.objectCount
        let duplicateIndex = try XCTUnwrap(renderer.duplicateSelectedObject())
        XCTAssertEqual(renderer.objectCount, countBefore + 1)
        XCTAssertNotEqual(duplicateIndex, originalIndex)
        XCTAssertNotNil(renderer.newTriggerInfo(at: duplicateIndex), "the duplicate must be a real, newly-synthesized Trigger, not a visual-only copy")
    }

    func testDuplicatingACameraSpawnsARealSecondCamera() throws {
        let renderer = try makeRenderer()
        let originalIndex = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(2, 0, 2)))
        renderer.select(index: originalIndex)
        XCTAssertTrue(renderer.canDuplicate(at: originalIndex))

        let countBefore = renderer.objectCount
        let duplicateIndex = try XCTUnwrap(renderer.duplicateSelectedObject())
        XCTAssertEqual(renderer.objectCount, countBefore + 1)
        XCTAssertNotNil(renderer.newCameraInfo(at: duplicateIndex))
    }

    /// A single-triangle asset, just enough for `buildGPUSubmeshes` to
    /// produce a non-empty submesh (`triangleIndices()` needs 3 vertices
    /// with the apex's connectivity flag set), standing in for a real
    /// resolved scenery model's mesh, same "the actual geometry doesn't
    /// matter, only that resolution succeeds" reasoning `makeMarkerCubeAsset`
    /// already uses for Instance placeholders.
    private func makeTestSceneryAsset() -> ResolvedModelAsset {
        let vertices = [
            StaticVertex(position: SIMD3<Float>(0, 0, 0)),
            StaticVertex(position: SIMD3<Float>(1, 0, 0)),
            StaticVertex(position: SIMD3<Float>(0, 1, 0)),
        ]
        let submesh = MeshSubmesh(vertices: vertices, connectivity: [false, false, true])
        let mesh = MeshAsset(id: 1, isSkinned: false, submeshes: [submesh])
        return ResolvedModelAsset(recordID: 1, displayName: "Test Scenery", mesh: mesh, submeshMaterials: [ResolvedSubmeshMaterial()])
    }

    /// Regression test for the bug where `canDuplicate(at:)` reported a
    /// session-placed scenery object as duplicable, but
    /// `duplicateSelectedObject`'s switch had no `.scenery` case at all , 
    /// the Duplicate button showed enabled and clicking it silently did
    /// nothing.
    func testDuplicatingASessionPlacedSceneryObjectSpawnsARealSecondScenery() throws {
        let renderer = try makeRenderer()
        let asset = makeTestSceneryAsset()
        let originalIndex = try XCTUnwrap(renderer.spawnScenery(modelID: 77, isSpecial: false, asset: asset, at: SIMD3<Float>(4, 0, 4)))
        renderer.select(index: originalIndex)
        XCTAssertTrue(renderer.canDuplicate(at: originalIndex))

        let countBefore = renderer.objectCount
        let duplicateIndex = try XCTUnwrap(renderer.duplicateSelectedObject(), "duplicateSelectedObject must not silently no-op for a session-placed scenery object")
        XCTAssertEqual(renderer.objectCount, countBefore + 1)
        XCTAssertNotEqual(duplicateIndex, originalIndex)

        let pending = renderer.pendingNewScenery
        // The original plus its duplicate, both must be real,
        // save-eligible placements, not a purely visual copy.
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.last?.modelID, 77)
        XCTAssertNotEqual(pending.last?.position, SIMD3<Float>(4, 0, 4), "the duplicate must land at an offset, not stacked exactly on the original")
    }

    /// Regression test for the bug where `LevelViewerWindow.duplicateSelected()`
    /// only ever registered undo for an Instance/AI-waypoint duplicate,
    /// never a Trigger or Camera one -- so ⌘D on a duplicated Trigger/Camera
    /// spawned it correctly but left nothing for ⌘Z to undo.
    /// `registerTriggerPlacementUndo`/`registerCameraPlacementUndo` are the
    /// exact functions `duplicateSelected()` must call after a successful
    /// duplicate; this exercises them directly against a real duplicate
    /// index, the same way `duplicateSelected()` itself now does.
    func testRegisterTriggerPlacementUndoUndoesAndRedoesADuplicatedTrigger() throws {
        let renderer = try makeRenderer()
        let undoManager = UndoManager()
        let originalIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(1, 0, 1)))
        renderer.select(index: originalIndex)
        let duplicateIndex = try XCTUnwrap(renderer.duplicateSelectedObject())
        let countAfterDuplicate = renderer.objectCount

        LevelViewerWindow.registerTriggerPlacementUndo(undoManager: undoManager, renderer: renderer, index: duplicateIndex)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(renderer.objectCount, countAfterDuplicate - 1, "undo must remove exactly the duplicate")

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertEqual(renderer.objectCount, countAfterDuplicate, "redo must re-spawn the duplicate")
    }

    func testRegisterCameraPlacementUndoUndoesAndRedoesADuplicatedCamera() throws {
        let renderer = try makeRenderer()
        let undoManager = UndoManager()
        let originalIndex = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(2, 0, 2)))
        renderer.select(index: originalIndex)
        let duplicateIndex = try XCTUnwrap(renderer.duplicateSelectedObject())
        let countAfterDuplicate = renderer.objectCount

        LevelViewerWindow.registerCameraPlacementUndo(undoManager: undoManager, renderer: renderer, index: duplicateIndex)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(renderer.objectCount, countAfterDuplicate - 1, "undo must remove exactly the duplicate")

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertEqual(renderer.objectCount, countAfterDuplicate, "redo must re-spawn the duplicate")
    }

    /// Regression test: `duplicateSelected()` gained a `.scenery` case
    /// this session but no matching undo registration, ⌘D on a
    /// session-placed scenery object spawned a real duplicate that ⌘Z
    /// couldn't remove. Same pattern as the Trigger/Camera tests above,
    /// now exercising `registerSceneryPlacementUndo`/`newSceneryInfo`.
    func testRegisterSceneryPlacementUndoUndoesAndRedoesADuplicatedScenery() throws {
        let renderer = try makeRenderer()
        let undoManager = UndoManager()
        let asset = makeTestSceneryAsset()
        let originalIndex = try XCTUnwrap(renderer.spawnScenery(modelID: 77, isSpecial: false, asset: asset, at: SIMD3<Float>(4, 0, 4)))
        renderer.select(index: originalIndex)
        let duplicateIndex = try XCTUnwrap(renderer.duplicateSelectedObject())
        let countAfterDuplicate = renderer.objectCount

        LevelViewerWindow.registerSceneryPlacementUndo(undoManager: undoManager, renderer: renderer, index: duplicateIndex)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(renderer.objectCount, countAfterDuplicate - 1, "undo must remove exactly the duplicate")

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertEqual(renderer.objectCount, countAfterDuplicate, "redo must re-spawn the duplicate")
    }
}
