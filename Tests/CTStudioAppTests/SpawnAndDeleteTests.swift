import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// "Add Trigger"/"Add Camera" (closing the parity gap the original
/// editor's `Menu_AddNew` has for these record types) and real delete
/// (closing the parity gap the original editor's `ItemController`'s
/// universal Remove has), both new this session, both exercised through
/// the same real spawn/remove pipeline the Forge Palette already trusts.
@MainActor
final class SpawnAndDeleteTests: XCTestCase {
    private func makeRenderer() throws -> LevelViewerRenderer {
        try XCTUnwrap(LevelViewerRenderer(placements: []))
    }

    /// Minimal real (non-empty) resolved asset, same construction
    /// `ModelViewerRendererTests.makeTestAsset()` uses, `spawnScenery`
    /// guards on `!built.submeshes.isEmpty`, so an asset with an actual
    /// triangle (not `MeshAsset(submeshes: [])`) is required for it to
    /// succeed.
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

    // MARK: - Interactive Scenery Placement

    func testSpawnSceneryAddsARealSelectableSceneryObject() throws {
        let renderer = try makeRenderer()
        let asset = makeTestAsset()
        let countBefore = renderer.objectCount
        let index = try XCTUnwrap(renderer.spawnScenery(modelID: 7, isSpecial: true, asset: asset, at: SIMD3<Float>(11, 2, -5)))
        XCTAssertEqual(renderer.objectCount, countBefore + 1)
        XCTAssertEqual(renderer.selectedObjectIndex, index, "spawning should select the new object immediately, matching spawnInstance/spawnTrigger/spawnCamera")

        let info = try XCTUnwrap(renderer.newSceneryInfo(at: index))
        XCTAssertEqual(info.modelID, 7)
        XCTAssertTrue(info.isSpecial)
        // `+ placementGroundClearance` on Y: a real, disclosed best-effort
        // clearance a fresh placement now adds, to avoid real, reported
        // angle-dependent depth-fight flicker (both in this app's own
        // preview and, more importantly, in a real PCSX2 boot) against
        // whatever surface it lands on.
        XCTAssertEqual(info.worldPosition, SIMD3<Float>(11, 2 + LevelViewerRenderer.placementGroundClearance, -5))
        XCTAssertEqual(info.asset.recordID, asset.recordID, "the exact resolved asset must be retained for a later redo/duplicate to re-spawn from, not just its ID")
    }

    /// `spawnScenery` returns `nil` (and adds nothing) for an asset with no
    /// real geometry, same "don't fabricate a placement nobody can see"
    /// guard `ModelViewerRendererTests.testRendererHandlesEmptyMeshWithoutCrashing`
    /// checks at the standalone-viewer level.
    func testSpawnSceneryWithAnEmptyMeshReturnsNilAndAddsNothing() throws {
        let renderer = try makeRenderer()
        let emptyMesh = MeshAsset(id: 2, isSkinned: false, submeshes: [])
        let emptyAsset = ResolvedModelAsset(recordID: 2, displayName: "Empty", mesh: emptyMesh, submeshMaterials: [])
        let countBefore = renderer.objectCount
        XCTAssertNil(renderer.spawnScenery(modelID: 1, isSpecial: false, asset: emptyAsset, at: .zero))
        XCTAssertEqual(renderer.objectCount, countBefore)
    }

    /// The exact regression `ScenerPlacementArchiveRegressionTests
    /// .testInsertingNewSceneryThroughLiveViewportPlacementPathRoundTripsOnArchiveBrowsedLevel`
    /// caught against real disc data, pinned here as a fast, offline unit
    /// test too: `pendingNewScenery` must hand `WorkspaceViewModel` the
    /// object's plain `worldPosition`, unmirrored, `composingModelMatrix`
    /// (which actually encodes it) already does the one and only world->raw
    /// X negation itself. Mirroring here *again* silently placed every
    /// live-placed scenery object at the wrong X on save.
    func testPendingNewSceneryReflectsASpawnedSceneryObjectsPositionUnmirrored() throws {
        let renderer = try makeRenderer()
        let asset = makeTestAsset()
        _ = try XCTUnwrap(renderer.spawnScenery(modelID: 3, isSpecial: false, asset: asset, at: SIMD3<Float>(9, -1, 4)))
        let pending = try XCTUnwrap(renderer.pendingNewScenery.first)
        XCTAssertEqual(pending.modelID, 3)
        XCTAssertFalse(pending.isSpecial)
        // See `testSpawnSceneryAddsARealSelectableSceneryObject`'s own
        // comment on `+ placementGroundClearance`.
        XCTAssertEqual(pending.position, SIMD3<Float>(9, -1 + LevelViewerRenderer.placementGroundClearance, 4), "must be the object's own worldPosition, not ModelViewerRenderer.mirroredWorldPosition(...) of it")
    }

    func testCanDeleteAndDeleteAndRestoreRoundTripForASessionPlacedSceneryObject() throws {
        let renderer = try makeRenderer()
        let asset = makeTestAsset()
        let index = try XCTUnwrap(renderer.spawnScenery(modelID: 5, isSpecial: false, asset: asset, at: SIMD3<Float>(1, 1, 1)))
        XCTAssertTrue(renderer.canDelete(at: index), "a session-placed scenery object must be deletable, unlike scenery loaded from the level's own file")

        let countBefore = renderer.objectCount
        let snapshot = try XCTUnwrap(renderer.deleteObject(at: index))
        XCTAssertEqual(renderer.objectCount, countBefore - 1)
        XCTAssertNil(renderer.newSceneryInfo(at: index), "the deleted index should no longer read back as scenery")

        renderer.restoreObject(snapshot, at: index)
        XCTAssertEqual(renderer.objectCount, countBefore)
        let restored = try XCTUnwrap(renderer.newSceneryInfo(at: index))
        XCTAssertEqual(restored.modelID, 5)
        // See `testSpawnSceneryAddsARealSelectableSceneryObject`'s own
        // comment on `+ placementGroundClearance`, restore returns the
        // object to its own actual snapshot, which already had this baked in.
        XCTAssertEqual(restored.worldPosition, SIMD3<Float>(1, 1 + LevelViewerRenderer.placementGroundClearance, 1))
    }

    // MARK: - Marking Menu Copy/Cut/Paste (`ObjectClipboardEntry`)

    func testCopyThenPasteASceneryObjectSpawnsAnIndependentSecondObject() throws {
        let renderer = try makeRenderer()
        let asset = makeTestAsset()
        let original = try XCTUnwrap(renderer.spawnScenery(modelID: 8, isSpecial: true, asset: asset, at: SIMD3<Float>(2, 0, 2)))
        let entry = try XCTUnwrap(renderer.copyObject(at: original))

        let pasted = try XCTUnwrap(renderer.pasteObject(entry))
        XCTAssertNotEqual(pasted, original)
        XCTAssertEqual(renderer.objectCount, 2)
        let pastedInfo = try XCTUnwrap(renderer.newSceneryInfo(at: pasted))
        XCTAssertEqual(pastedInfo.modelID, 8)
        XCTAssertTrue(pastedInfo.isSpecial)
        // See `testSpawnSceneryAddsARealSelectableSceneryObject`'s own
        // comment on `+ placementGroundClearance`, paste offsets X/Z from
        // the original's own actual (already-cleared) Y, not a fresh spawn.
        XCTAssertEqual(pastedInfo.worldPosition, SIMD3<Float>(3, 0 + LevelViewerRenderer.placementGroundClearance, 3), "paste drops the copy at the same short offset duplicateSelectedObject uses")

        // The original must be untouched, Copy (unlike Cut) never removes
        // anything.
        XCTAssertNotNil(renderer.newSceneryInfo(at: original))
    }

    func testCopyThenPasteAFreshlySpawnedInstanceSpawnsAnIndependentSecondObject() throws {
        let renderer = try makeRenderer()
        let original = try XCTUnwrap(renderer.spawnInstance(objectID: 123, at: SIMD3<Float>(4, 0, 0)))
        let entry = try XCTUnwrap(renderer.copyObject(at: original))
        let pasted = try XCTUnwrap(renderer.pasteObject(entry))
        XCTAssertNotEqual(pasted, original)
        let pastedInfo = try XCTUnwrap(renderer.newInstanceInfo(at: pasted))
        XCTAssertEqual(pastedInfo.objectID, 123)
        XCTAssertEqual(pastedInfo.worldPosition, SIMD3<Float>(5, 0, 1))
    }

    func testCopyObjectReturnsNilForAnOutOfRangeIndex() throws {
        let renderer = try makeRenderer()
        XCTAssertNil(renderer.copyObject(at: 0))
        XCTAssertNil(renderer.copyObject(at: -1))
    }

    func testSpawnTriggerAddsARealSelectableTrigger() throws {
        let renderer = try makeRenderer()
        let countBefore = renderer.objectCount
        let index = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(3, 0, 4)))
        XCTAssertEqual(renderer.objectCount, countBefore + 1)
        XCTAssertEqual(renderer.selectedObjectIndex, index, "spawning should select the new object immediately, matching spawnInstance/spawnAIWaypoint")
        let worldPosition = try XCTUnwrap(renderer.newTriggerInfo(at: index))
        XCTAssertEqual(worldPosition, SIMD3<Float>(3, 0, 4))
    }

    // MARK: - AI Path (Level Viewer live session)

    /// `AIPathRecord` has no spatial position of its own (see its own doc
    /// comment) and isn't a `GPULevelObject`, so it can't ride
    /// `spawnTrigger`/`spawnCamera`'s index-based create/select/delete --
    /// this exercises its own separate `addAIPath`/`removeAIPath`/
    /// `restoreAIPath` pair.
    func testAddAIPathAddsARealPendingPath() throws {
        let renderer = try makeRenderer()
        let id = renderer.addAIPath()
        XCTAssertEqual(renderer.newAIPaths.map(\.id), [id])
        XCTAssertEqual(renderer.newAIPaths.first?.args, [0, 1, 0, 0, 0], "default args should be a plausible start/end waypoint pair")
    }

    func testAddAIPathUsesItsOwnIndependentSyntheticIDNamespace() throws {
        let renderer = try makeRenderer()
        let trigger = try XCTUnwrap(renderer.spawnTrigger())
        let pathID = renderer.addAIPath()
        // Trigger IDs and AIPath IDs are independent namespaces -- both
        // legitimately start at 1, so this only checks each is tracked in
        // its own place, not that the numeric values themselves differ.
        XCTAssertNotNil(renderer.newTriggerInfo(at: trigger))
        XCTAssertTrue(renderer.newAIPaths.contains { $0.id == pathID })
    }

    func testDuplicateAIPathAddsASecondPathWithTheSameArgs() throws {
        let renderer = try makeRenderer()
        let original = renderer.addAIPath(args: [2, 5, 9, 0, 1])
        let duplicate = renderer.addAIPath(args: [2, 5, 9, 0, 1])
        XCTAssertNotEqual(original, duplicate, "a duplicate must get its own real, distinct ID")
        XCTAssertEqual(renderer.newAIPaths.count, 2)
        XCTAssertEqual(renderer.newAIPaths.map(\.args), [[2, 5, 9, 0, 1], [2, 5, 9, 0, 1]])
    }

    func testRemoveAIPathDropsASessionAddedPathEntirely() throws {
        let renderer = try makeRenderer()
        let id = renderer.addAIPath()
        renderer.removeAIPath(id: id)
        XCTAssertTrue(renderer.newAIPaths.isEmpty, "a session-added path that's removed again shouldn't be tracked as removed real data -- it just never existed")
        XCTAssertTrue(renderer.pendingRemovedAIPathIDs.isEmpty)
    }

    func testRemoveAIPathMarksARealIDAsRemovedWithoutTouchingNewAIPaths() throws {
        let renderer = try makeRenderer()
        renderer.removeAIPath(id: 42) // a real, on-disk ID this session never added
        XCTAssertEqual(renderer.pendingRemovedAIPathIDs, [42])
        XCTAssertTrue(renderer.newAIPaths.isEmpty)
    }

    func testRestoreAIPathUndoesRemovalOfARealID() throws {
        let renderer = try makeRenderer()
        renderer.removeAIPath(id: 7)
        XCTAssertEqual(renderer.pendingRemovedAIPathIDs, [7])
        renderer.restoreAIPath(id: 7)
        XCTAssertTrue(renderer.pendingRemovedAIPathIDs.isEmpty)
    }

    /// `explicitID` is what keeps undo/redo symmetric (`LevelViewerWindow
    /// .registerAIPathAddUndo`'s redo step re-adds under the *original*
    /// ID rather than minting a new one) -- verified directly here rather
    /// than only through the UI-level undo wiring.
    func testAddAIPathWithExplicitIDReusesThatIDInsteadOfMintingANewOne() throws {
        let renderer = try makeRenderer()
        let firstID = renderer.addAIPath() // consumes the synthetic counter once
        renderer.removeAIPath(id: firstID)
        let redoneID = renderer.addAIPath(args: [1, 2, 3, 4, 5], explicitID: firstID)
        XCTAssertEqual(redoneID, firstID)
        XCTAssertEqual(renderer.newAIPaths.first?.args, [1, 2, 3, 4, 5])
    }

    /// `pendingNewAIPaths`' encoded bytes must be exactly what
    /// `AINavigationParser.parseAIPath` reads back -- the same real
    /// encode/decode round-trip every other pending-record test in this
    /// file checks for Trigger/Camera.
    func testPendingNewAIPathsEncodeAndReparseToTheSameArgs() throws {
        let renderer = try makeRenderer()
        let id = renderer.addAIPath(args: [3, 8, 100, 65535, 0])
        let pending = try XCTUnwrap(renderer.pendingNewAIPaths.first { $0.id == id })
        var cursor = BinaryCursor(data: pending.encoded)
        let reparsed = try AINavigationParser.parseAIPath(&cursor, recordID: id)
        XCTAssertEqual(reparsed.args, [3, 8, 100, 65535, 0])
        XCTAssertEqual(cursor.position, pending.encoded.count, "writeAIPath's 10 bytes must be exactly what parseAIPath consumes, nothing more")
    }

    func testSpawnCameraAddsARealSelectableCamera() throws {
        let renderer = try makeRenderer()
        let index = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(1, 2, 3)))
        XCTAssertEqual(renderer.selectedObjectIndex, index)
        let worldPosition = try XCTUnwrap(renderer.newCameraInfo(at: index))
        XCTAssertEqual(worldPosition, SIMD3<Float>(1, 2, 3))
    }

    func testSpawnTriggerAndCameraUseIndependentSyntheticIDNamespaces() throws {
        // Spawning several of each shouldn't collide with each other or
        // with AI-waypoint/Instance synthetic IDs, each record type keeps
        // its own counter (see nextSyntheticTriggerID/nextSyntheticCameraID's
        // own doc comment).
        let renderer = try makeRenderer()
        let trigger1 = try XCTUnwrap(renderer.spawnTrigger())
        let trigger2 = try XCTUnwrap(renderer.spawnTrigger())
        let camera1 = try XCTUnwrap(renderer.spawnCamera())
        XCTAssertNotEqual(trigger1, trigger2)
        XCTAssertNotNil(renderer.newTriggerInfo(at: trigger1))
        XCTAssertNotNil(renderer.newTriggerInfo(at: trigger2))
        XCTAssertNotNil(renderer.newCameraInfo(at: camera1))
        XCTAssertNil(renderer.newCameraInfo(at: trigger1), "a Trigger object must not also read back as a Camera")
    }

    func testPendingNewTriggersAndCamerasEncodeForSave() throws {
        let renderer = try makeRenderer()
        _ = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(5, 5, 5)))
        _ = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(6, 6, 6)))
        XCTAssertEqual(renderer.pendingNewTriggers.count, 1)
        XCTAssertEqual(renderer.pendingNewCameras.count, 1)
        // Real, decodable bytes, not placeholder data. Round-trip
        // correctness itself is covered by WorldPlacementParserTests;
        // this just confirms the renderer actually calls through to the
        // real encoder with the live object's current position.
        XCTAssertGreaterThan(renderer.pendingNewTriggers[0].encoded.count, 0)
        XCTAssertGreaterThan(renderer.pendingNewCameras[0].encoded.count, 0)
    }

    func testDeletingASessionPlacedTriggerRemovesItWithoutTrackingForRemoval() throws {
        let renderer = try makeRenderer()
        let index = try XCTUnwrap(renderer.spawnTrigger())
        XCTAssertTrue(renderer.canDelete(at: index))
        let countBefore = renderer.objectCount
        let snapshot = try XCTUnwrap(renderer.deleteObject(at: index))
        XCTAssertEqual(renderer.objectCount, countBefore - 1)
        // A same-session placement being deleted was never a real on-disk
        // record, so it must not appear in the "remove this real record"
        // list a save would act on.
        XCTAssertTrue(renderer.pendingRemovedTriggerIDs.isEmpty)
        // Undo must bring it back exactly.
        renderer.restoreObject(snapshot, at: index)
        XCTAssertEqual(renderer.objectCount, countBefore)
    }

    func testCanDeleteIsFalseForOutOfRangeIndex() throws {
        let renderer = try makeRenderer()
        XCTAssertFalse(renderer.canDelete(at: 0))
        XCTAssertFalse(renderer.canDelete(at: -1))
        XCTAssertFalse(renderer.canDelete(at: 999))
    }

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

    /// Regression test for the bug where a scenery object loaded from the
    /// level's own real `SceneryData` tree could never be deleted at all
    /// (only a same-session `spawnScenery` placement could), real, on-disk
    /// scenery now has its own write path via `SceneryModelPlacement
    /// .matrixFileOffset`/`SceneryGroup.removingPlacements`, threaded
    /// through to `GPULevelObject.sceneryMatrixFileOffset`.
    func testCanDeleteIsTrueForOnDiskSceneryAndDeletionTracksItsFileOffsetForRemoval() throws {
        let asset = makeTestSceneryAsset()
        let placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)] = [
            (SIMD3<Float>(5, 0, 5), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, 128),
        ]
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: placements))
        XCTAssertEqual(renderer.objectCount, 1)
        XCTAssertTrue(renderer.canDelete(at: 0), "a real, on-disk scenery placement (sceneryMatrixFileOffset != nil) must now be deletable")

        let snapshot = try XCTUnwrap(renderer.deleteObject(at: 0))
        XCTAssertEqual(renderer.objectCount, 0)
        XCTAssertEqual(renderer.pendingRemovedSceneryOffsets, [128], "the real placement's own byte offset must be tracked for removal at save time")

        renderer.restoreObject(snapshot, at: 0)
        XCTAssertEqual(renderer.objectCount, 1)
        XCTAssertTrue(renderer.pendingRemovedSceneryOffsets.isEmpty, "undo must un-mark it for removal")
    }

    /// Regression test for the bug where dragging an *existing* on-disk
    /// scenery placement moved it visually but had no write path at all , 
    /// `pendingSceneryTransformOverrides` now patches its real 64-byte
    /// `modelMatrix` block in place, at `sceneryFileNode.fileOffset +
    /// sceneryMatrixFileOffset` (the same absolute-offset convention
    /// `pendingCameraControlPointOverrides` already uses).
    func testPendingSceneryTransformOverridesPatchesTheMovedPositionAtItsRealFileOffset() throws {
        let asset = makeTestSceneryAsset()
        let fileOffset = 2000
        let relativeMatrixOffset = 128
        let node = ChunkNode(recordID: 1, sectionType: .null, displayName: "test.sm2", byteSize: 100_000, fileOffset: fileOffset)
        let placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)] = [
            (SIMD3<Float>(5, 0, 5), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, relativeMatrixOffset),
        ]
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: placements, sceneryFileNode: node))
        renderer.select(index: 0)
        let movedPosition = SIMD3<Float>(42, 3, -17)
        renderer.setSelectedPosition(to: movedPosition)

        let overrides = renderer.pendingSceneryTransformOverrides
        XCTAssertEqual(overrides.count, 1)
        let override = try XCTUnwrap(overrides.first)
        XCTAssertEqual(override.absoluteOffset, fileOffset + relativeMatrixOffset, "must combine the shared scenery node's own fileOffset with this placement's relative one")
        XCTAssertEqual(override.encoded.count, 64, "4 rows * 4 floats * 4 bytes, matching writeModelMatrix's own real format")

        // Decode the raw 64 bytes back through the same worldTransform this
        // codebase's own real save/reparse round trip uses, and confirm the
        // *moved* position -- not the original -- comes back out.
        var cursor = BinaryCursor(data: override.encoded)
        var rows: [SIMD4<Float>] = []
        for _ in 0..<4 {
            rows.append(SIMD4(try cursor.readFloat32(), try cursor.readFloat32(), try cursor.readFloat32(), try cursor.readFloat32()))
        }
        let decoded = SceneryModelPlacement(modelID: 1, isSpecial: false, boundingBoxMin: .zero, boundingBoxMax: .zero, modelMatrix: rows)
        let transform = try XCTUnwrap(decoded.worldTransform)
        XCTAssertLessThan(simd_distance(transform.position, movedPosition), 0.0001)
    }

    /// A stitched neighbor chunk's scenery (`stitchChunk`, `.linkedChunks`
    /// layer) deliberately never carries a `sceneryMatrixFileOffset`, it's
    /// a real byte offset, but relative to a *different* file than this
    /// renderer's own save path can write back to. Must stay non-deletable.
    func testCanDeleteIsFalseForStitchedNeighborChunkScenery() throws {
        let asset = makeTestSceneryAsset()
        let stitchedPlacements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)] = [
            (SIMD3<Float>(1, 0, 1), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, 256),
        ]
        let renderer = try makeRenderer()
        let added = renderer.stitchChunk(placements: stitchedPlacements, worldOffset: .zero)
        XCTAssertEqual(added, 1)
        XCTAssertFalse(renderer.canDelete(at: 0), "a stitched neighbor's scenery has no write path back into this level's own file")
    }

    func testDeleteWithNoSelectionOrInvalidIndexReturnsNil() throws {
        let renderer = try makeRenderer()
        XCTAssertNil(renderer.deleteObject(at: 0))
        _ = try XCTUnwrap(renderer.spawnTrigger())
        XCTAssertNil(renderer.deleteObject(at: 999))
    }

    func testRestoringADeletedObjectReselectsIt() throws {
        let renderer = try makeRenderer()
        let index = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(9, 9, 9)))
        let snapshot = try XCTUnwrap(renderer.deleteObject(at: index))
        XCTAssertNil(renderer.selectedObjectIndex)
        renderer.restoreObject(snapshot, at: index)
        XCTAssertEqual(renderer.selectedObjectIndex, index)
        XCTAssertEqual(renderer.newCameraInfo(at: index), SIMD3<Float>(9, 9, 9))
    }

    /// "Coordinate-System Overhaul": end-to-end proof that a Trigger/Camera
    /// placed at a given *world* (viewport-displayed) position survives a
    /// real save → re-parse round trip and lands back at that same world
    /// position, not just that `pendingNewTrigger`/`pendingNewCamera`
    /// returns *some* raw bytes. Goes through the exact same
    /// `WorldPlacementWriter`/`WorldPlacementParser` pair a real save uses,
    /// then re-applies the renderer's own display-space mirror
    /// (`ModelViewerRenderer.mirroredWorldPosition`) to the freshly-decoded
    /// raw position, the same conversion `upload(...)` would apply when the
    /// saved file is reopened.
    func testSpawnedTriggerSurvivesSaveReparseRoundTripAtTheSameWorldPosition() throws {
        let renderer = try makeRenderer()
        let worldPosition = SIMD3<Float>(12, -4, 30)
        _ = try XCTUnwrap(renderer.spawnTrigger(at: worldPosition))
        let encoded = try XCTUnwrap(renderer.pendingNewTriggers.first?.encoded)

        var cursor = BinaryCursor(data: encoded)
        let decoded = try WorldPlacementParser.parseTrigger(&cursor, recordID: 999)
        let rawPosition = SIMD3<Float>(decoded.position.x, decoded.position.y, decoded.position.z)
        let redisplayedPosition = ModelViewerRenderer.mirroredWorldPosition(rawPosition)

        XCTAssertLessThan(simd_distance(redisplayedPosition, worldPosition), 0.0001)
    }

    // MARK: - "Real AI/Combat Behavior for Forge-Placed Objects"

    /// `WorldPlacementWriter.writeNewInstance`'s new `scriptID` parameter
    /// must actually reach the encoded bytes, not just default to "no
    /// script" regardless of what's passed.
    func testWriteNewInstanceEncodesAndReparsesTheGivenScriptID() throws {
        let encoded = WorldPlacementWriter.writeNewInstance(
            objectID: 42, position: SIMD4<Float>(0, 0, 0, 1), rotationDegrees: .zero, scriptID: 137
        )
        var cursor = BinaryCursor(data: encoded)
        let decoded = try WorldPlacementParser.parseInstance(&cursor, recordID: 999)
        XCTAssertEqual(decoded.scriptID, 137)
    }

    func testWriteNewInstanceDefaultsScriptIDToNoScript() throws {
        let encoded = WorldPlacementWriter.writeNewInstance(objectID: 42, position: SIMD4<Float>(0, 0, 0, 1), rotationDegrees: .zero)
        var cursor = BinaryCursor(data: encoded)
        let decoded = try WorldPlacementParser.parseInstance(&cursor, recordID: 999)
        XCTAssertEqual(decoded.scriptID, -1)
    }

    private func makePlacedInstance(objectID: UInt16, scriptID: Int16) -> PlacedInstance {
        PlacedInstance(
            id: 1, position: .zero, rotationRaw: .zero, comRotationRaw: .zero,
            childInstanceIDs: [], childPositionIDs: [], childPathIDs: [],
            someNum1: 10, someNum2: 10, someNum3: 10,
            objectID: objectID, refList: -1, scriptID: scriptID, flags: 6,
            unknownUInt32List: [], unknownFloatList: [], unknownUInt32List2: []
        )
    }

    /// The actual lookup `computingPendingOverridePatch` reads per newly-
    /// placed object: a real AI-capable object type already carrying a
    /// working `scriptID` elsewhere in this level should hand that same
    /// script to a *fresh* placement of the same type, instead of every
    /// Forge-placed object silently starting with no AI at all.
    func testInstanceScriptIDByObjectIDReusesTheFirstRealScriptForThatType() throws {
        let node1 = ChunkNode(recordID: 1, sectionType: .instance, displayName: "Instance #1", byteSize: 0, fileOffset: 0)
        let node2 = ChunkNode(recordID: 2, sectionType: .instance, displayName: "Instance #2", byteSize: 0, fileOffset: 0)
        let markers: [(node: ChunkNode, instance: PlacedInstance)] = [
            (node1, makePlacedInstance(objectID: 180, scriptID: 55)),
            (node2, makePlacedInstance(objectID: 180, scriptID: 99)), // same type, later, first real value wins
        ]
        let result = LevelViewerWindow.instanceScriptIDByObjectID(fromInstanceMarkers: markers)
        XCTAssertEqual(result[180], 55)
    }

    func testInstanceScriptIDByObjectIDSkipsObjectsWithNoScriptAttached() throws {
        let node = ChunkNode(recordID: 1, sectionType: .instance, displayName: "Instance #1", byteSize: 0, fileOffset: 0)
        let markers: [(node: ChunkNode, instance: PlacedInstance)] = [(node, makePlacedInstance(objectID: 3, scriptID: -1))]
        let result = LevelViewerWindow.instanceScriptIDByObjectID(fromInstanceMarkers: markers)
        XCTAssertNil(result[3], "an object type with no real scriptID anywhere in this level must not produce a fabricated one")
    }

    /// "Keyboard nudging" (QoL): arrow-key movement should snap to the same
    /// grid a gizmo drag would, and be a no-op with nothing selected
    /// (matches every other selection-scoped mutator in this renderer).
    func testNudgeSelectedPositionMovesByGridStepAlongTheGivenAxis() throws {
        let renderer = try makeRenderer()
        renderer.gridSize = 2.0
        renderer.snapToGrid = true
        let index = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(10, 0, 10)))

        renderer.nudgeSelectedPosition(worldDirection: SIMD3(1, 0, 0))
        XCTAssertEqual(renderer.newTriggerInfo(at: index), SIMD3<Float>(12, 0, 10))

        renderer.nudgeSelectedPosition(worldDirection: SIMD3(0, 1, 0))
        XCTAssertEqual(renderer.newTriggerInfo(at: index), SIMD3<Float>(12, 2, 10))

        renderer.nudgeSelectedPosition(worldDirection: SIMD3(0, 0, -1))
        XCTAssertEqual(renderer.newTriggerInfo(at: index), SIMD3<Float>(12, 2, 8))
    }

    func testNudgeSelectedPositionUsesSmallFixedStepWithSnapOff() throws {
        let renderer = try makeRenderer()
        renderer.snapToGrid = false
        _ = try XCTUnwrap(renderer.spawnTrigger(at: .zero))
        renderer.nudgeSelectedPosition(worldDirection: SIMD3(1, 0, 0))
        let index = try XCTUnwrap(renderer.selectedObjectIndex)
        let position = try XCTUnwrap(renderer.newTriggerInfo(at: index))
        XCTAssertLessThan(simd_distance(position, SIMD3<Float>(0.25, 0, 0)), 0.0001)
    }

    func testNudgeSelectedPositionIsNoOpWithNothingSelected() throws {
        let renderer = try makeRenderer()
        renderer.nudgeSelectedPosition(worldDirection: SIMD3(1, 0, 0)) // must not crash
        XCTAssertNil(renderer.selectedObjectIndex)
    }

    /// "Vertex Magnet-Snapping": dragging a piece close to another
    /// placement's position on the same axis should snap into exact
    /// alignment with it, catching spacing a grid snap alone can't (a
    /// neighbor placed at a non-grid-aligned coordinate).
    func testMagnetSnappedPositionAlignsWithANearbyNeighborOnTheDraggedAxis() throws {
        let renderer = try makeRenderer()
        let neighborIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(10.37, 0, 0)))
        let draggedIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(0, 0, 0)))
        XCTAssertNotEqual(neighborIndex, draggedIndex)

        // Close to the neighbor's X (within magnetSnapThreshold) but not
        // exactly on it -- should snap to the neighbor's real X value.
        let candidate = SIMD3<Float>(10.5, 3, 7)
        let snapped = renderer.magnetSnappedPosition(candidate, excluding: draggedIndex, axis: .x)
        XCTAssertEqual(snapped.x, 10.37, accuracy: 0.0001)
        // Only the dragged axis snaps -- Y/Z pass through unchanged.
        XCTAssertEqual(snapped.y, 3, accuracy: 0.0001)
        XCTAssertEqual(snapped.z, 7, accuracy: 0.0001)
    }

    func testMagnetSnappedPositionPassesThroughUnchangedWhenNoNeighborIsClose() throws {
        let renderer = try makeRenderer()
        let neighborIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(100, 0, 0)))
        let draggedIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(0, 0, 0)))
        XCTAssertNotEqual(neighborIndex, draggedIndex)

        let candidate = SIMD3<Float>(5, 0, 0)
        let snapped = renderer.magnetSnappedPosition(candidate, excluding: draggedIndex, axis: .x)
        XCTAssertEqual(snapped, candidate, "far outside magnetSnapThreshold -- should not snap")
    }

    func testMagnetSnappedPositionPicksTheClosestNeighborWhenMultipleAreInRange() throws {
        let renderer = try makeRenderer()
        _ = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(10.0, 0, 0)))
        _ = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(10.2, 0, 0)))
        let draggedIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(0, 0, 0)))

        let candidate = SIMD3<Float>(10.25, 0, 0)
        let snapped = renderer.magnetSnappedPosition(candidate, excluding: draggedIndex, axis: .x)
        XCTAssertEqual(snapped.x, 10.2, accuracy: 0.0001, "should snap to whichever in-range neighbor is nearest, not just the first one found")
    }

    func testSpawnedCameraSurvivesSaveReparseRoundTripAtTheSameWorldPosition() throws {
        let renderer = try makeRenderer()
        let worldPosition = SIMD3<Float>(-8, 2, 15)
        _ = try XCTUnwrap(renderer.spawnCamera(at: worldPosition))
        let encoded = try XCTUnwrap(renderer.pendingNewCameras.first?.encoded)

        var cursor = BinaryCursor(data: encoded)
        let decoded = try WorldPlacementParser.parseCamera(&cursor, recordID: 999, isDemo: false)
        let rawPosition = SIMD3<Float>(decoded.position.x, decoded.position.y, decoded.position.z)
        let redisplayedPosition = ModelViewerRenderer.mirroredWorldPosition(rawPosition)

        XCTAssertLessThan(simd_distance(redisplayedPosition, worldPosition), 0.0001)
    }

    /// "Hover highlight" (Phase 3): a fresh renderer's default orbit looks
    /// straight at `boundsCenter` (world origin here, since there's no
    /// scenery to derive bounds from), an object spawned there projects
    /// to dead-center of any viewport, giving a deterministic screen point
    /// to drive `hoverObject`/`pickObject` from without needing to expose
    /// the renderer's private view/projection math to the test.
    func testHoverObjectMatchesPickObjectAndProducesADrawableOutline() throws {
        let renderer = try makeRenderer()
        let index = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(0, 0, 0)))
        renderer.select(index: nil)
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        XCTAssertEqual(renderer.pickObject(at: center, viewSize: viewSize), index, "hover and click picking must agree on the same object")
        XCTAssertFalse(renderer.hasHoverOutline)
        XCTAssertEqual(renderer.hoverObject(at: center, viewSize: viewSize), index)
        XCTAssertTrue(renderer.hasHoverOutline, "hovering an unselected object should produce a drawable outline")
    }

    func testHoverOutlineClearsWhenTheHoveredObjectBecomesSelected() throws {
        // The gizmo is already a selection indicator, drawing a second
        // outline around the same object would be redundant.
        let renderer = try makeRenderer()
        let index = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(0, 0, 0)))
        renderer.select(index: nil)
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        _ = renderer.hoverObject(at: center, viewSize: viewSize)
        XCTAssertTrue(renderer.hasHoverOutline)
        renderer.select(index: index)
        XCTAssertFalse(renderer.hasHoverOutline)
    }

    func testHoverOutlineClearsWhenCursorMovesAwayFromEveryObject() throws {
        let renderer = try makeRenderer()
        _ = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(0, 0, 0)))
        renderer.select(index: nil)
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        XCTAssertNotNil(renderer.hoverObject(at: center, viewSize: viewSize))
        XCTAssertTrue(renderer.hasHoverOutline)
        XCTAssertNil(renderer.hoverObject(at: CGPoint(x: 2, y: 2), viewSize: viewSize), "the far corner shouldn't be within picking range of the origin-projected object")
        XCTAssertFalse(renderer.hasHoverOutline)
    }

    /// Regression test: the zoom-clamp floor used to be a fixed
    /// *multiplier*, which silently overrode `focusOnSelected`'s own much
    /// smaller, deliberate multiplier for a small object in a large level
    ///, defeating "Double-Click to Focus" for exactly that case. The
    /// floor must scale with `boundsRadius` instead of fighting it.
    func testMinDistanceMultiplierScalesInverselyWithBoundsRadius() {
        XCTAssertEqual(ModelViewerRenderer.minDistanceMultiplier(forBoundsRadius: 1000), ModelViewerRenderer.minAbsoluteDistance / 1000, accuracy: 0.0001)
        XCTAssertEqual(ModelViewerRenderer.minDistanceMultiplier(forBoundsRadius: 1), ModelViewerRenderer.minAbsoluteDistance, accuracy: 0.0001)
    }

    func testFocusOnSelectedPullsInCloseOnASmallObjectEvenInsideAHugeLevel() throws {
        let asset = makeTestSceneryAsset()
        // Two placements far apart, so this level's own `boundsRadius`
        // ends up large relative to either object's own tiny
        // `boundingRadius`, the exact "small object in a big level"
        // shape the old fixed-multiplier floor broke.
        let placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)] = [
            (SIMD3<Float>(0, 0, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, nil),
            (SIMD3<Float>(2000, 0, 2000), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, nil),
        ]
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: placements))
        renderer.select(index: 0)
        renderer.focusOnSelected()
        // The old fixed-multiplier floor (0.05) applied against this
        // level's own large boundsRadius (~1400) would have clamped this
        // back up to 0.05 -- confirm it stayed small, proportional to the
        // object's own size, instead.
        XCTAssertLessThan(renderer.distanceMultiplier, 0.01, "a small object's own close-up focus distance must not be overridden by the scene-wide zoom floor")
    }

    // MARK: - Batch Editing, instanceObjectID(at:)

    /// The real primitive `LevelViewerWindow`'s "Select All Matching"
    /// groups objects by, must resolve the same real type ID for a
    /// same-session placement (`spawnInstance`'s own `objectID` param)
    /// that a real, on-disk Instance would resolve to via its own
    /// `sourceNode`, so batch-selecting "everything of this type" doesn't
    /// silently miss newly-placed copies of something that also exists on
    /// disk already.
    func testInstanceObjectIDResolvesTheRealSpawnedObjectID() throws {
        let renderer = try makeRenderer()
        let index = try XCTUnwrap(renderer.spawnInstance(objectID: 42, at: SIMD3<Float>(0, 0, 0)))
        XCTAssertEqual(renderer.instanceObjectID(at: index), 42)
    }

    /// Non-Instance layers (Trigger/Camera/AI waypoint/scenery) have no
    /// real "object type ID" concept the way an Instance does, must fail
    /// safe (`nil`), not return some other layer's unrelated numeric ID.
    func testInstanceObjectIDIsNilForNonActorLayers() throws {
        let renderer = try makeRenderer()
        let triggerIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(0, 0, 0)))
        XCTAssertNil(renderer.instanceObjectID(at: triggerIndex))
    }

    func testInstanceObjectIDIsNilForAnOutOfRangeIndex() throws {
        let renderer = try makeRenderer()
        XCTAssertNil(renderer.instanceObjectID(at: 999))
    }

    // MARK: - "Auto-Update Collision on Add/Delete" pipeline integration

    /// A minimal, real, decodable baseline `ColData` mesh, same shape as
    /// `LevelCollisionRebuilderTests.makeBaselineMesh()` (one ground quad,
    /// one group, no trigger boxes of its own).
    private func makeBaselineCollisionMesh() -> CollisionMesh {
        let vertices: [SIMD4<Float>] = [
            SIMD4(-10, 0, -10, 1), SIMD4(10, 0, -10, 1),
            SIMD4(10, 0, 10, 1), SIMD4(-10, 0, 10, 1),
        ]
        let triangles = [
            CollisionTriangle(vertexIndex1: 0, vertexIndex2: 1, vertexIndex3: 2, surfaceID: 42),
            CollisionTriangle(vertexIndex1: 0, vertexIndex2: 2, vertexIndex3: 3, surfaceID: 42),
        ]
        let groups = [CollisionGroup(size: 2, offset: 0)]
        let triggerBoxes = CollisionOBJImporter.buildTriggerTree(groups: groups, triangles: triangles, vertices: vertices)
        return CollisionMesh(id: 1, vertices: vertices, triangles: triangles, groups: groups, triggerBoxes: triggerBoxes)
    }

    /// Regression test for the real, reported bug in "Auto-Update Collision
    /// on Add/Delete": the rebuild used to compute correct bytes, then save
    /// them to a disconnected standalone file nothing else ever read , 
    /// `LevelViewerWindow.computingRebuiltCollisionRecord` is the fixed,
    /// now-integrated replacement (folded into `computingPendingOverridePatch`,
    /// so it's part of every real save/Quick Launch). This proves it
    /// produces real bytes that round-trip back through the actual parser
    /// with a genuinely new collision box for a session-placed object , 
    /// not just that the underlying `LevelCollisionRebuilder` functions
    /// work in isolation (already covered by `LevelCollisionRebuilderTests`).
    func testComputingRebuiltCollisionRecordAddsARealBoxForASessionPlacedSceneryObject() throws {
        let renderer = try makeRenderer()
        let asset = makeTestAsset()
        _ = try XCTUnwrap(renderer.spawnScenery(modelID: 7, isSpecial: false, asset: asset, at: SIMD3<Float>(11, 2, -5)))

        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)

        let result = try XCTUnwrap(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))
        XCTAssertEqual(result.node.recordID, collisionNode.recordID)

        var cursor = BinaryCursor(data: result.encoded)
        let reparsed = try ColDataParser.parse(&cursor, recordID: collisionNode.recordID, size: result.encoded.count)

        XCTAssertGreaterThan(reparsed.triangles.count, baseline.triangles.count, "the spawned object's own collision box must actually be present in the re-parsed bytes, not just computed and discarded")
        XCTAssertGreaterThan(reparsed.groups.count, baseline.groups.count)
        // Original ground quad's own two triangles, at their original
        // indices, byte-for-byte untouched, same invariant
        // `LevelCollisionRebuilderTests.testAppendingOneBoxPreservesOriginalGeometryAndAddsANewGroup`
        // already checks at the `LevelCollisionRebuilder` level, re-checked
        // here after a real encode/parse round-trip.
        for (a, b) in zip(reparsed.triangles.prefix(2), baseline.triangles) {
            XCTAssertEqual(a.surfaceID, b.surfaceID)
        }
    }

    /// No session-placed object has any collision data at all (nothing
    /// spawned), must return `nil`, not a spurious "rebuilt" record that
    /// would otherwise get folded into every single save regardless of
    /// whether anything real changed.
    func testComputingRebuiltCollisionRecordIsNilWithNothingPlaced() throws {
        let renderer = try makeRenderer()
        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)
        XCTAssertNil(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))
    }

}
