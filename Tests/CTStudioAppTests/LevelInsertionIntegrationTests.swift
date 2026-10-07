import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// "Save Level Overrides…" (Part 4D), exercised through the real,
/// self-contained flow a user actually drives, `WorkspaceViewModel.
/// open(url:)` on a real `.rm2` file on disk, then `patchedFileBytes(
/// applyingPrefixPatches:insertingNewInstances:levelNode:)`, rather than
/// calling `ChunkSectionInserter` directly (already covered by
/// `ChunkSectionInserterTests`). This is specifically checking the glue:
/// finding the right file root and `.objectInstance` collection from a
/// node the workspace actually produced, not synthetic fixtures.
@MainActor
final class LevelInsertionIntegrationTests: XCTestCase {
    private func makeSection(children: [(id: UInt32, bytes: Data)]) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(TwinsMagic.v1)
        writer.writeInt32(Int32(children.count))
        let contentSize = children.reduce(0) { $0 + $1.bytes.count }
        writer.writeUInt32(UInt32(contentSize))
        var offset = 12 + children.count * 12
        for child in children {
            writer.writeUInt32(UInt32(offset))
            writer.writeInt32(Int32(child.bytes.count))
            writer.writeUInt32(child.id)
            offset += child.bytes.count
        }
        for child in children {
            writer.writeBytes(child.bytes)
        }
        return writer.data
    }

    private func findFirst(_ node: ChunkNode, sectionType: SectionType) -> ChunkNode? {
        if node.sectionType == sectionType { return node }
        for child in node.children {
            if let found = findFirst(child, sectionType: sectionType) { return found }
        }
        return nil
    }

    private func findScenery(_ node: ChunkNode) -> ChunkNode? {
        if case .scenery = node.payload { return node }
        for child in node.children {
            if let found = findScenery(child) { return found }
        }
        return nil
    }

    func testSaveLevelOverridesInsertsNewInstanceThroughRealWorkspaceFlow() throws {
        let originalInstance = WorldPlacementWriter.writeNewInstance(objectID: 3, position: SIMD4<Float>(1, 2, 3, 1), rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(id: 100, bytes: originalInstance)])
        // "AI Pathfinding & Navmesh Editor" (roadmap 5.1): a real
        // AIPosition collection (subID 1) alongside the Instance one
        // (subID 6), both inside the same `.instance` container, exactly
        // how a real file lays these out, so this fixture also exercises
        // `insertingNewAIPositions` through the real workspace flow, not
        // just `ChunkSectionInserter` in isolation.
        let originalWaypoint = WorldPlacementWriter.writeAIPosition(position: SIMD4<Float>(9, 9, 9, 1), rawNodeType: 0)
        let aiPositionCollection = makeSection(children: [(id: 200, bytes: originalWaypoint)])
        let instanceContainer = makeSection(children: [(id: 1, bytes: aiPositionCollection), (id: 6, bytes: objectInstanceCollection)])
        // `WorkspaceViewModel.findFileRoot` recognizes a file root by its
        // having a direct `.graphics`/`.code`-family child, a real .rm2
        // always has both; this fixture only needs the empty `.code`
        // section (top-level id 10) to satisfy that check.
        let emptyCodeSection = makeSection(children: [])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer), (id: 10, bytes: emptyCodeSection)])

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).rm2")
        try fileBytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let workspace = WorkspaceViewModel()
        workspace.open(url: tempURL)

        // "Visual Loading Feedback": a standalone .rm2 open now parses off
        // the main actor (same real fix as folder-scanned loose level
        // files) so the loading spinner has an actual suspension point to
        // paint across, wait for that real async load to finish instead
        // of assuming it already has by the time `open(url:)` returns.
        let loadExpectation = expectation(description: "single-file load completes")
        fulfill(loadExpectation, whenTrue: { !workspace.isLoading })
        wait(for: [loadExpectation], timeout: 10)

        XCTAssertEqual(workspace.rootNodes.count, 1, "the file should have finished loading asynchronously")

        let fileRoot = try XCTUnwrap(workspace.rootNodes.first)
        let instanceLeaf = try XCTUnwrap(findFirst(fileRoot, sectionType: .objectInstance)?.children.first)
        XCTAssertTrue(workspace.canSaveEdits(for: instanceLeaf), "a standalone-opened file should report as save-able")

        let newRecord = WorldPlacementWriter.writeNewInstance(objectID: 77, position: SIMD4<Float>(5, 5, 5, 1), rotationDegrees: .zero)
        let newWaypoint = WorldPlacementWriter.writeAIPosition(position: SIMD4<Float>(6, 6, 6, 1), rawNodeType: 4)
        let patched = try XCTUnwrap(workspace.patchedFileBytes(
            applyingPrefixPatches: [],
            insertingNewInstances: [(id: 999, encoded: newRecord)],
            insertingNewAIPositions: [(id: 888, encoded: newWaypoint)],
            levelNode: instanceLeaf
        )).primaryBytes

        let reparsed = try RM2Parser.parse(data: patched, fileKind: .rm2, fileName: "synthetic.rm2")
        let reparsedCollection = try XCTUnwrap(findFirst(reparsed, sectionType: .objectInstance))
        XCTAssertEqual(reparsedCollection.children.count, 2)

        guard case .instance(let original)? = reparsedCollection.children.first(where: { $0.recordID == 100 })?.payload else {
            return XCTFail("pre-existing instance record didn't survive a save with no transform edits")
        }
        XCTAssertEqual(original.objectID, 3)

        guard case .instance(let inserted)? = reparsedCollection.children.first(where: { $0.recordID == 999 })?.payload else {
            return XCTFail("newly inserted record didn't decode after going through the real WorkspaceViewModel save path")
        }
        XCTAssertEqual(inserted.objectID, 77)
        XCTAssertEqual(inserted.position, SIMD4<Float>(5, 5, 5, 1))

        let reparsedWaypoints = try XCTUnwrap(findFirst(reparsed, sectionType: .aiPosition))
        XCTAssertEqual(reparsedWaypoints.children.count, 2)
        guard case .aiPosition(let originalWaypointDecoded)? = reparsedWaypoints.children.first(where: { $0.recordID == 200 })?.payload else {
            return XCTFail("pre-existing AI waypoint didn't survive a save alongside an Instance insertion")
        }
        XCTAssertEqual(originalWaypointDecoded.position, SIMD4<Float>(9, 9, 9, 1))
        guard case .aiPosition(let insertedWaypoint)? = reparsedWaypoints.children.first(where: { $0.recordID == 888 })?.payload else {
            return XCTFail("newly inserted AI waypoint didn't decode after going through the real WorkspaceViewModel save path")
        }
        XCTAssertEqual(insertedWaypoint.position, SIMD4<Float>(6, 6, 6, 1))
        XCTAssertEqual(insertedWaypoint.rawNodeType, 4)
    }

    /// "PositionEditor" parity: `positionCollectionNode`/
    /// `patchedFileBytes(insertingPosition:inSameFileAs:)`/
    /// `patchedFileBytes(removingPosition:)` through the real
    /// `WorkspaceViewModel` flow, same discipline as the Instance/
    /// AIPosition test above, not just `ChunkSectionInserter` in
    /// isolation.
    func testPositionAddAndRemoveThroughRealWorkspaceFlow() throws {
        let originalPosition = WorldPlacementWriter.writePosition(PositionMarker(id: 50, point: SIMD4<Float>(1, 2, 3, 1)))
        let toRemove = WorldPlacementWriter.writePosition(PositionMarker(id: 51, point: SIMD4<Float>(4, 5, 6, 1)))
        let positionCollection = makeSection(children: [(id: 50, bytes: originalPosition), (id: 51, bytes: toRemove)])
        let instanceContainer = makeSection(children: [(id: 3, bytes: positionCollection)])
        let emptyCodeSection = makeSection(children: [])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer), (id: 10, bytes: emptyCodeSection)])

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).rm2")
        try fileBytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let workspace = WorkspaceViewModel()
        workspace.open(url: tempURL)

        let loadExpectation = expectation(description: "single-file load completes")
        fulfill(loadExpectation, whenTrue: { !workspace.isLoading })
        wait(for: [loadExpectation], timeout: 10)

        let fileRoot = try XCTUnwrap(workspace.rootNodes.first)
        let positionLeaves = try XCTUnwrap(findFirst(fileRoot, sectionType: .position)?.children)
        XCTAssertEqual(positionLeaves.count, 2)

        let collectionNode = try XCTUnwrap(workspace.positionCollectionNode(inSameFileAs: positionLeaves[0]))
        XCTAssertEqual(collectionNode.sectionType, .position)

        // Insert: new record ID must be one past the highest existing ID (51 -> 52).
        let inserted = try XCTUnwrap(workspace.patchedFileBytes(insertingPosition: SIMD4<Float>(7, 8, 9, 1), inSameFileAs: positionLeaves[0]))
        let reparsedAfterInsert = try RM2Parser.parse(data: inserted, fileKind: .rm2, fileName: "synthetic.rm2")
        let collectionAfterInsert = try XCTUnwrap(findFirst(reparsedAfterInsert, sectionType: .position))
        XCTAssertEqual(collectionAfterInsert.children.count, 3)
        guard case .position(let insertedMarker)? = collectionAfterInsert.children.first(where: { $0.recordID == 52 })?.payload else {
            return XCTFail("newly inserted Position didn't decode with the expected next-available ID")
        }
        XCTAssertEqual(insertedMarker.point, SIMD4<Float>(7, 8, 9, 1))

        // Remove: the second original record is gone, the first survives untouched.
        let removed = try XCTUnwrap(workspace.patchedFileBytes(removingPosition: positionLeaves[1]))
        let reparsedAfterRemove = try RM2Parser.parse(data: removed, fileKind: .rm2, fileName: "synthetic.rm2")
        let collectionAfterRemove = try XCTUnwrap(findFirst(reparsedAfterRemove, sectionType: .position))
        XCTAssertEqual(collectionAfterRemove.children.count, 1)
        guard case .position(let survivingMarker)? = collectionAfterRemove.children.first(where: { $0.recordID == 50 })?.payload else {
            return XCTFail("pre-existing Position didn't survive removing a sibling")
        }
        XCTAssertEqual(survivingMarker.point, SIMD4<Float>(1, 2, 3, 1))
    }

    /// "PathEditor" parity: `patchedFileBytes(replacingWholeRecord:with:)`
    /// through the real `WorkspaceViewModel` flow, exercising a genuine
    /// size-changing edit (adding a point grows the record), the one
    /// case `patchedFileBytes(replacing:with:)` explicitly refuses.
    /// `replacingWholeRecord` had no direct test coverage anywhere before
    /// this, despite `PathEditorSheet`'s add/remove-point buttons and
    /// `MainScriptEditorSheet`'s State/Body/Command CRUD both depending on
    /// it.
    func testPathReplaceWholeRecordSurvivesASizeChangingEditThroughRealWorkspaceFlow() throws {
        let originalPath = PathWriter.write(PathAsset(id: 30, positions: [SIMD4<Float>(1, 1, 1, 1)], params: [PathAsset.Param(p1: 0.5, p2: 1.5)]))
        let pathCollection = makeSection(children: [(id: 30, bytes: originalPath)])
        let instanceContainer = makeSection(children: [(id: 4, bytes: pathCollection)])
        let emptyCodeSection = makeSection(children: [])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer), (id: 10, bytes: emptyCodeSection)])

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).rm2")
        try fileBytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let workspace = WorkspaceViewModel()
        workspace.open(url: tempURL)

        let loadExpectation = expectation(description: "single-file load completes")
        fulfill(loadExpectation, whenTrue: { !workspace.isLoading })
        wait(for: [loadExpectation], timeout: 10)

        let fileRoot = try XCTUnwrap(workspace.rootNodes.first)
        let pathLeaf = try XCTUnwrap(findFirst(fileRoot, sectionType: .path)?.children.first)

        var grown = PathAsset(id: 30, positions: [SIMD4<Float>(1, 1, 1, 1), SIMD4<Float>(2, 2, 2, 1)], params: [PathAsset.Param(p1: 0.5, p2: 1.5)])
        grown.positions.append(SIMD4<Float>(3, 3, 3, 1))
        let encoded = PathWriter.write(grown)
        let patched = try XCTUnwrap(workspace.patchedFileBytes(replacingWholeRecord: pathLeaf, with: encoded))

        let reparsed = try RM2Parser.parse(data: patched, fileKind: .rm2, fileName: "synthetic.rm2")
        let reparsedCollection = try XCTUnwrap(findFirst(reparsed, sectionType: .path))
        XCTAssertEqual(reparsedCollection.children.count, 1, "record count in the collection shouldn't change from a same-ID replace")
        guard case .path(let survivingPath)? = reparsedCollection.children.first(where: { $0.recordID == 30 })?.payload else {
            return XCTFail("the size-changed Path record didn't decode back after going through the real WorkspaceViewModel save path")
        }
        XCTAssertEqual(survivingPath.positions, grown.positions)
        XCTAssertEqual(survivingPath.params.count, 1)
        XCTAssertEqual(survivingPath.params[0].p1, 0.5)
        XCTAssertEqual(survivingPath.params[0].p2, 1.5)
    }

    /// "ObjectEditor" parity: `gameObjectCollectionNode`/
    /// `patchedFileBytes(insertingGameObject:inSameFileAs:)`/
    /// `patchedFileBytes(removingGameObject:)` through the real
    /// `WorkspaceViewModel` flow. Also proves the `max(8192, ...) + 1` ID
    /// scheme matches the reference editor's own create/duplicate exactly.
    func testGameObjectCreateAndDeleteThroughRealWorkspaceFlow() throws {
        let existingObject = GameObjectWriter.encode(GameObjectInfo(id: 500, name: "Keep Me", ogiIDs: [1, 2]))
        let objectCollection = makeSection(children: [(id: 500, bytes: existingObject)])
        let codeContainer = makeSection(children: [(id: 0, bytes: objectCollection)])
        let instanceContainer = makeSection(children: [])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer), (id: 10, bytes: codeContainer)])

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).rm2")
        try fileBytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let workspace = WorkspaceViewModel()
        workspace.open(url: tempURL)

        let loadExpectation = expectation(description: "single-file load completes")
        fulfill(loadExpectation, whenTrue: { !workspace.isLoading })
        wait(for: [loadExpectation], timeout: 10)

        let fileRoot = try XCTUnwrap(workspace.rootNodes.first)
        let objectLeaves = try XCTUnwrap(findFirst(fileRoot, sectionType: .object)?.children)
        XCTAssertEqual(objectLeaves.count, 1)
        let existingLeaf = try XCTUnwrap(objectLeaves.first)

        // Insert: ID must be one past max(8192, existing max), here 500 < 8192, so 8193.
        let newObject = GameObjectInfo(id: 0, name: "New Game Object", ogiIDs: [])
        let (inserted, insertedID) = try XCTUnwrap(workspace.patchedFileBytes(insertingGameObject: newObject, inSameFileAs: existingLeaf))
        XCTAssertEqual(insertedID, 8193)

        let reparsedAfterInsert = try RM2Parser.parse(data: inserted, fileKind: .rm2, fileName: "synthetic.rm2")
        let collectionAfterInsert = try XCTUnwrap(findFirst(reparsedAfterInsert, sectionType: .object))
        XCTAssertEqual(collectionAfterInsert.children.count, 2)
        guard case .gameObject(let insertedDecoded)? = collectionAfterInsert.children.first(where: { $0.recordID == 8193 })?.payload else {
            return XCTFail("newly inserted GameObject didn't decode with the expected next-available ID")
        }
        XCTAssertEqual(insertedDecoded.name, "New Game Object")

        // Remove: the original object is gone.
        let removed = try XCTUnwrap(workspace.patchedFileBytes(removingGameObject: existingLeaf))
        let reparsedAfterRemove = try RM2Parser.parse(data: removed, fileKind: .rm2, fileName: "synthetic.rm2")
        let collectionAfterRemove = try XCTUnwrap(findFirst(reparsedAfterRemove, sectionType: .object))
        XCTAssertEqual(collectionAfterRemove.children.count, 0)
    }

    /// "AIPositionEditor"/"AIPathEditor" parity: real write-back through
    /// the real `WorkspaceViewModel` flow, both record types are
    /// fixed-size, so insert/remove exercises `ChunkSectionInserter`
    /// exactly like Position's own test above, just for a different
    /// section pair (`.aiPosition` sub-ID 1, `.aiPath` sub-ID 2).
    func testAIPositionAndAIPathAddAndRemoveThroughRealWorkspaceFlow() throws {
        let originalWaypoint = WorldPlacementWriter.writeAIPosition(position: SIMD4<Float>(1, 2, 3, 1), rawNodeType: 0)
        let aiPositionCollection = makeSection(children: [(id: 50, bytes: originalWaypoint)])
        let originalPath = WorldPlacementWriter.writeAIPath([1, 2, 3, 4, 5])
        let aiPathCollection = makeSection(children: [(id: 60, bytes: originalPath)])
        let instanceContainer = makeSection(children: [(id: 1, bytes: aiPositionCollection), (id: 2, bytes: aiPathCollection)])
        let emptyCodeSection = makeSection(children: [])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer), (id: 10, bytes: emptyCodeSection)])

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).rm2")
        try fileBytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let workspace = WorkspaceViewModel()
        workspace.open(url: tempURL)
        let loadExpectation = expectation(description: "single-file load completes")
        fulfill(loadExpectation, whenTrue: { !workspace.isLoading })
        wait(for: [loadExpectation], timeout: 10)

        let fileRoot = try XCTUnwrap(workspace.rootNodes.first)
        let waypointLeaf = try XCTUnwrap(findFirst(fileRoot, sectionType: .aiPosition)?.children.first)
        let pathLeaf = try XCTUnwrap(findFirst(fileRoot, sectionType: .aiPath)?.children.first)

        let (insertedWaypointBytes, waypointID) = try XCTUnwrap(workspace.patchedFileBytes(insertingAIPosition: SIMD4<Float>(4, 5, 6, 1), rawNodeType: 2, inSameFileAs: waypointLeaf))
        XCTAssertEqual(waypointID, 51)
        var reparsed = try RM2Parser.parse(data: insertedWaypointBytes, fileKind: .rm2, fileName: "synthetic.rm2")
        var waypointCollection = try XCTUnwrap(findFirst(reparsed, sectionType: .aiPosition))
        XCTAssertEqual(waypointCollection.children.count, 2)
        guard case .aiPosition(let inserted)? = waypointCollection.children.first(where: { $0.recordID == 51 })?.payload else {
            return XCTFail("newly inserted AIPosition didn't decode")
        }
        XCTAssertEqual(inserted.rawNodeType, 2)

        let removedWaypointBytes = try XCTUnwrap(workspace.patchedFileBytes(removingAIPosition: waypointLeaf))
        reparsed = try RM2Parser.parse(data: removedWaypointBytes, fileKind: .rm2, fileName: "synthetic.rm2")
        waypointCollection = try XCTUnwrap(findFirst(reparsed, sectionType: .aiPosition))
        XCTAssertEqual(waypointCollection.children.count, 0)

        let (insertedPathBytes, pathID) = try XCTUnwrap(workspace.patchedFileBytes(insertingAIPath: [9, 8, 7, 6, 5], inSameFileAs: pathLeaf))
        XCTAssertEqual(pathID, 61)
        reparsed = try RM2Parser.parse(data: insertedPathBytes, fileKind: .rm2, fileName: "synthetic.rm2")
        var pathCollection = try XCTUnwrap(findFirst(reparsed, sectionType: .aiPath))
        XCTAssertEqual(pathCollection.children.count, 2)
        guard case .aiPath(let insertedPath)? = pathCollection.children.first(where: { $0.recordID == 61 })?.payload else {
            return XCTFail("newly inserted AIPath didn't decode")
        }
        XCTAssertEqual(insertedPath.args, [9, 8, 7, 6, 5])

        let removedPathBytes = try XCTUnwrap(workspace.patchedFileBytes(removingAIPath: pathLeaf))
        reparsed = try RM2Parser.parse(data: removedPathBytes, fileKind: .rm2, fileName: "synthetic.rm2")
        pathCollection = try XCTUnwrap(findFirst(reparsed, sectionType: .aiPath))
        XCTAssertEqual(pathCollection.children.count, 0)
    }

    /// "IDEditor" parity: `patchedFileBytes(reassigningIDOf:to:)` through
    /// the real `WorkspaceViewModel` flow, the record's own bytes and
    /// position in the section must survive untouched, only the
    /// index-table `id` field changes; a sibling record must be
    /// completely unaffected.
    func testReassigningIDThroughRealWorkspaceFlow() throws {
        let keep = WorldPlacementWriter.writePosition(PositionMarker(id: 10, point: SIMD4<Float>(1, 1, 1, 1)))
        let rename = WorldPlacementWriter.writePosition(PositionMarker(id: 20, point: SIMD4<Float>(2, 2, 2, 1)))
        let positionCollection = makeSection(children: [(id: 10, bytes: keep), (id: 20, bytes: rename)])
        let instanceContainer = makeSection(children: [(id: 3, bytes: positionCollection)])
        let emptyCodeSection = makeSection(children: [])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer), (id: 10, bytes: emptyCodeSection)])

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).rm2")
        try fileBytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let workspace = WorkspaceViewModel()
        workspace.open(url: tempURL)
        let loadExpectation = expectation(description: "single-file load completes")
        fulfill(loadExpectation, whenTrue: { !workspace.isLoading })
        wait(for: [loadExpectation], timeout: 10)

        let fileRoot = try XCTUnwrap(workspace.rootNodes.first)
        let positionLeaves = try XCTUnwrap(findFirst(fileRoot, sectionType: .position)?.children)
        let toRename = try XCTUnwrap(positionLeaves.first { $0.recordID == 20 })

        // Refuses a collision with an existing ID (reference: "New ID already exists").
        XCTAssertNil(workspace.patchedFileBytes(reassigningIDOf: toRename, to: 10))

        let patched = try XCTUnwrap(workspace.patchedFileBytes(reassigningIDOf: toRename, to: 99))
        let reparsed = try RM2Parser.parse(data: patched, fileKind: .rm2, fileName: "synthetic.rm2")
        let collection = try XCTUnwrap(findFirst(reparsed, sectionType: .position))
        XCTAssertEqual(collection.children.count, 2, "record count must be unchanged, this is a rename, not an insert/remove")
        XCTAssertNil(collection.children.first { $0.recordID == 20 }, "the old ID must no longer resolve")

        guard case .position(let renamed)? = collection.children.first(where: { $0.recordID == 99 })?.payload else {
            return XCTFail("the renamed record didn't decode under its new ID")
        }
        XCTAssertEqual(renamed.point, SIMD4<Float>(2, 2, 2, 1), "the record's own bytes must be untouched by a pure ID rename")

        guard case .position(let untouched)? = collection.children.first(where: { $0.recordID == 10 })?.payload else {
            return XCTFail("the sibling record must be completely unaffected by renaming a different record's ID")
        }
        XCTAssertEqual(untouched.point, SIMD4<Float>(1, 1, 1, 1))
    }

    /// Real-delete parity foundation: a single "Save Chunk Overrides…" that
    /// both adds a new Trigger and removes a pre-existing Instance, through
    /// the real `WorkspaceViewModel` flow, not just `ChunkSectionInserter`
    /// in isolation. Exercises `triggerCollectionNode`/`removingInstanceIDs`
    /// together with an unrelated insertion in the same save, the same
    /// "one combined rebuild" shape a real user's delete-plus-place session
    /// would produce.
    func testSaveLevelOverridesInsertsTriggerAndRemovesInstanceThroughRealWorkspaceFlow() throws {
        let keepInstance = WorldPlacementWriter.writeNewInstance(objectID: 1, position: .zero, rotationDegrees: .zero)
        let removeInstance = WorldPlacementWriter.writeNewInstance(objectID: 2, position: .zero, rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(id: 100, bytes: keepInstance), (id: 101, bytes: removeInstance)])
        let existingTrigger = WorldPlacementWriter.writeNewTrigger(position: SIMD4<Float>(1, 1, 1, 1))
        let triggerCollection = makeSection(children: [(id: 200, bytes: existingTrigger)])
        let instanceContainer = makeSection(children: [(id: 6, bytes: objectInstanceCollection), (id: 7, bytes: triggerCollection)])
        let emptyCodeSection = makeSection(children: [])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer), (id: 10, bytes: emptyCodeSection)])

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).rm2")
        try fileBytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let workspace = WorkspaceViewModel()
        workspace.open(url: tempURL)

        let loadExpectation = expectation(description: "single-file load completes")
        fulfill(loadExpectation, whenTrue: { !workspace.isLoading })
        wait(for: [loadExpectation], timeout: 10)

        let fileRoot = try XCTUnwrap(workspace.rootNodes.first)
        let instanceLeaf = try XCTUnwrap(findFirst(fileRoot, sectionType: .objectInstance)?.children.first)

        let newTrigger = WorldPlacementWriter.writeNewTrigger(position: SIMD4<Float>(9, 9, 9, 1))
        let patched = try XCTUnwrap(workspace.patchedFileBytes(
            applyingPrefixPatches: [],
            insertingNewInstances: [],
            insertingNewAIPositions: [],
            insertingNewTriggers: [(id: 999, encoded: newTrigger)],
            removingInstanceIDs: [101],
            levelNode: instanceLeaf
        )).primaryBytes

        let reparsed = try RM2Parser.parse(data: patched, fileKind: .rm2, fileName: "synthetic.rm2")

        let reparsedInstances = try XCTUnwrap(findFirst(reparsed, sectionType: .objectInstance))
        XCTAssertEqual(reparsedInstances.children.count, 1, "removed instance should really be gone")
        XCTAssertNil(reparsedInstances.children.first(where: { $0.recordID == 101 }))
        guard case .instance(let survivor)? = reparsedInstances.children.first(where: { $0.recordID == 100 })?.payload else {
            return XCTFail("surviving instance didn't decode")
        }
        XCTAssertEqual(survivor.objectID, 1)

        let reparsedTriggers = try XCTUnwrap(findFirst(reparsed, sectionType: .trigger))
        XCTAssertEqual(reparsedTriggers.children.count, 2)
        guard case .trigger(let originalTrigger)? = reparsedTriggers.children.first(where: { $0.recordID == 200 })?.payload else {
            return XCTFail("pre-existing trigger didn't survive")
        }
        XCTAssertEqual(originalTrigger.position, SIMD4<Float>(1, 1, 1, 1))
        guard case .trigger(let insertedTrigger)? = reparsedTriggers.children.first(where: { $0.recordID == 999 })?.payload else {
            return XCTFail("newly inserted trigger didn't decode after going through the real WorkspaceViewModel save path")
        }
        XCTAssertEqual(insertedTrigger.position, SIMD4<Float>(9, 9, 9, 1))
        XCTAssertEqual(insertedTrigger.header, 50)
    }

    /// Regression test for a real bug found this session: a level's real
    /// `SceneryData` almost always lives in a *different* file (`.sm2`)
    /// than its Instance/Trigger/Camera records (`.rm2`), see
    /// `WorkspaceViewModel.LevelOverridePatch`'s own doc comment for the
    /// disc-verified fact behind this (`hubb.sm2` has 462 scenery
    /// placements and zero instances; `hubb.rm2` has the reverse).
    /// `patchedFileBytes` used to unconditionally treat scenery as just
    /// another edit folded into `levelNode`'s own bytes, which silently
    /// found no `SceneryData` record at all in that (by far the most
    /// common) case and failed the *entire* combined save, not only the
    /// scenery part. This opens two genuinely separate synthetic files
    /// (never sharing a `rootNodes` entry) through the real
    /// `WorkspaceViewModel.open(url:)` flow, exactly like the two tests
    /// above do for the single-file case, and confirms a scenery-only
    /// edit produces a real, independently re-parseable `sceneryBytes`
    /// result instead of `nil` or a silently-unchanged file.
    func testSaveOverridesRoutesSceneryEditsToItsOwnSeparateFileNotTheInstanceFile() throws {
        // The .rm2 side: a minimal, otherwise-untouched file, proves the
        // scenery-only save doesn't require (or corrupt) any Instance data.
        let objectInstanceCollection = makeSection(children: [])
        let instanceContainer = makeSection(children: [(id: 6, bytes: objectInstanceCollection)])
        let emptyCodeSection = makeSection(children: [])
        let rmBytes = makeSection(children: [(id: 0, bytes: instanceContainer), (id: 10, bytes: emptyCodeSection)])
        let rmURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-actor-\(UUID().uuidString).rm2")
        try rmBytes.write(to: rmURL)
        defer { try? FileManager.default.removeItem(at: rmURL) }

        // The .sm2 side: a real SceneryData record (top-level sub-ID 0 for
        // a .sm2 file, `RM2Parser.tier0Kind`) with one real placement.
        let placement = SceneryModelPlacement(
            modelID: 42, isSpecial: false,
            boundingBoxMin: SIMD4<Float>(-1, -1, -1, 1), boundingBoxMax: SIMD4<Float>(1, 1, 1, 1),
            modelMatrix: [SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(5, 5, 5, 1)]
        )
        let modelGroup = SceneryModelGroup(header: 0x1613, placements: [placement])
        // `SceneryGroup.links` is always exactly 8 child slots on real disk
        // data (`SceneryData.cs`'s own fixed-size format) -- an empty array
        // here would make the writer emit 0 type tags where the parser
        // unconditionally reads 8, corrupting the round trip.
        let sceneryAsset = SceneryAsset(id: 0, chunkName: "TestChunk", skydomeID: nil, ambientLights: [], directionalLights: [], pointLights: [], negativeLights: [], root: SceneryGroup(model: modelGroup, links: Array(repeating: .empty, count: 8)))
        let sceneryRecordBytes = SceneryDataWriter.encode(sceneryAsset)
        // `WorkspaceViewModel.findFileRoot` recognizes a file root by its
        // having a direct `.graphics`/`.code`-family child (same reasoning
        // as `emptyCodeSection` above) -- a real .sm2 always has an empty-
        // or-not `.graphics` section at top-level sub-ID 6 (`RM2Parser
        // .tier0Kind`), so this fixture needs one too, even empty.
        let emptyGraphicsSection = makeSection(children: [])
        let smBytes = makeSection(children: [(id: 0, bytes: sceneryRecordBytes), (id: 6, bytes: emptyGraphicsSection)])
        let smURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-scenery-\(UUID().uuidString).sm2")
        try smBytes.write(to: smURL)
        defer { try? FileManager.default.removeItem(at: smURL) }

        let workspace = WorkspaceViewModel()
        workspace.open(url: rmURL)
        let rmLoaded = expectation(description: "actor file load completes")
        fulfill(rmLoaded, whenTrue: { !workspace.isLoading })
        wait(for: [rmLoaded], timeout: 10)
        workspace.open(url: smURL)
        let smLoaded = expectation(description: "scenery file load completes")
        fulfill(smLoaded, whenTrue: { !workspace.isLoading })
        wait(for: [smLoaded], timeout: 10)

        XCTAssertEqual(workspace.rootNodes.count, 2, "the two files must load as two genuinely separate roots, never merged into one")
        let instanceLeaf = try XCTUnwrap(findFirst(workspace.rootNodes[0], sectionType: .objectInstance))
        let sceneryFileRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName == smURL.lastPathComponent })
        let sceneryLeaf = try XCTUnwrap(findScenery(sceneryFileRoot))
        guard case .scenery(let parsedScenery)? = sceneryLeaf.payload, let matrixOffset = parsedScenery.placements.first?.matrixFileOffset else {
            return XCTFail("synthetic SceneryData didn't parse back with a real placement/matrixFileOffset")
        }

        let patch = try XCTUnwrap(workspace.patchedFileBytes(
            applyingPrefixPatches: [],
            insertingNewInstances: [],
            insertingNewAIPositions: [],
            removingSceneryOffsets: [matrixOffset],
            sceneryFileNode: sceneryLeaf,
            levelNode: instanceLeaf
        ), "a scenery-only edit across two files must still produce a real patch, not nil")

        XCTAssertEqual(patch.primaryBytes, rmBytes, "the .rm2 file must come back byte-identical -- nothing about it was edited")
        let sceneryResult = try XCTUnwrap(patch.sceneryBytes, "the scenery edit must land in its own separate result, not be silently dropped")
        XCTAssertEqual(patch.sceneryFileDisplayName, smURL.lastPathComponent)

        let reparsedSceneryFile = try RM2Parser.parse(data: sceneryResult, fileKind: .sm2, fileName: "synthetic.sm2")
        guard case .scenery(let reparsedAsset)? = findScenery(reparsedSceneryFile)?.payload else {
            return XCTFail("scenery result bytes didn't re-parse back to a real SceneryData record")
        }
        XCTAssertTrue(reparsedAsset.placements.isEmpty, "the one real placement must actually be gone after removal")
    }
}
