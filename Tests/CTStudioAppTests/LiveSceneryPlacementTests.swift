import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Regression test for the real, reported bug: clicking a Scenery-tab
/// thumbnail for a model sourced from *another* level immediately
/// computed final file bytes and demanded a native save panel before the
/// object was ever placeable in the viewport, experienced by a
/// non-programmer user as "it just keeps giving me a prompt to save the
/// game and never lets me drop it in."
///
/// The fix defers the real cross-file geometry copy all the way to save
/// time (`CrossLevelSceneryGeometrySource`/`WorkspaceViewModel
/// .patchedFileBytes(insertingNewCrossLevelScenery:)`), matching every
/// other pending edit in this app, placement itself only ever appends an
/// in-session `GPULevelObject` (`LevelViewerRenderer.spawnCrossLevelScenery`),
/// never touches a file's bytes. This test exercises the save-time half:
/// two separate destination files (a `.sm2` carrying `SceneryData` and its
/// paired `.rm2` carrying the actual Graphics collections the copy lands
/// in), the real split every disc level other than `hubb.sm2` itself uses.
@MainActor
final class LiveSceneryPlacementTests: XCTestCase {
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

    /// Header(4) + materialCount(4) + materialIDs + meshID(4), matches
    /// `CrossFileModelCopierTests`' own `makeRigidModel`.
    private func makeRigidModel(materialIDs: [UInt32] = [], meshID: UInt32) -> Data {
        var w = BinaryWriter()
        w.writeUInt32(257)
        w.writeInt32(Int32(materialIDs.count))
        for id in materialIDs { w.writeUInt32(id) }
        w.writeUInt32(meshID)
        return w.data
    }

    /// A real, decodable `Material` record with zero shaders, just
    /// enough for `CrossFileModelCopier`'s upfront "does this file have
    /// at least one real material leaf" check (`graphicsLeaves`, payload-
    /// based, not just "a Material *collection* exists", see that
    /// function's own doc comment) to find something real, without
    /// needing a texture reference at all since this test's RigidModel
    /// never points at it.
    private func makeMaterial(name: String) -> Data {
        var w = BinaryWriter()
        w.writeUInt64(2)
        w.writeInt32(2)
        w.writeInt32(Int32(name.utf8.count))
        w.writeBytes(Array(name.utf8))
        w.writeInt32(0)
        return w.data
    }

    /// A real, decodable 1x1 `Texture` record, matches
    /// `CrossFileModelCopierTests`' own `makeTexture`, trimmed to the one
    /// size this test needs.
    private func makeTexture() -> Data {
        var w = BinaryWriter()
        let pixelData: [UInt8] = [0, 0, 0, 0]
        w.writeInt32(Int32(224 + pixelData.count))
        w.writeInt32(0)
        w.writeInt16(0); w.writeInt16(0)
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt8(0); w.writeUInt8(1); w.writeUInt8(0); w.writeUInt8(0)
        w.writeBytes([0, 0])
        w.writeInt32(0)
        for _ in 0..<6 { w.writeInt32(0) }
        w.writeInt32(1)
        for _ in 0..<6 { w.writeInt32(0) }
        w.writeInt32(0)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeInt32(0)
        w.writeBytes([0, 0]); w.writeBytes([0, 0])
        w.writeBytes([UInt8](repeating: 0, count: 32))
        w.writeBytes([UInt8](repeating: 0, count: 96))
        w.writeBytes(pixelData)
        return w.data
    }

    private func makeGraphicsSection(textures: [(id: UInt32, bytes: Data)] = [], materials: [(id: UInt32, bytes: Data)] = [], models: [(id: UInt32, bytes: Data)], rigidModels: [(id: UInt32, bytes: Data)]) -> Data {
        makeSection(children: [
            (0, makeSection(children: textures)),
            (1, makeSection(children: materials)),
            (2, makeSection(children: models)),
            (3, makeSection(children: rigidModels)),
        ])
    }

    private func makeEmptySceneryRecord() -> Data {
        let modelGroup = SceneryModelGroup(header: 0, placements: [])
        let asset = SceneryAsset(id: 0, chunkName: "Dest", skydomeID: nil, ambientLights: [], directionalLights: [], pointLights: [], negativeLights: [], root: SceneryGroup(model: modelGroup, links: Array(repeating: .empty, count: 8)))
        return SceneryDataWriter.encode(asset)
    }

    /// One real, non-special placement, unlike `makeEmptySceneryRecord`,
    /// re-parsing this record's own bytes yields a placement with a real
    /// `matrixFileOffset`, exactly what `LevelViewerRenderer.
    /// pendingSceneryTransformOverrides` needs to build a real "move this
    /// existing scenery object" byte-range patch against.
    private func makeSceneryRecordWithOnePlacement(modelID: UInt32, position: SIMD3<Float>) -> Data {
        let placement = SceneryModelPlacement(
            modelID: modelID, isSpecial: false,
            boundingBoxMin: SIMD4<Float>(position, 1) - SIMD4<Float>(1, 1, 1, 0),
            boundingBoxMax: SIMD4<Float>(position, 1) + SIMD4<Float>(1, 1, 1, 0),
            modelMatrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(position.x, position.y, position.z, 1)]
        )
        let modelGroup = SceneryModelGroup(header: 0x1613, placements: [placement])
        let asset = SceneryAsset(id: 0, chunkName: "Dest", skydomeID: nil, ambientLights: [], directionalLights: [], pointLights: [], negativeLights: [], root: SceneryGroup(model: modelGroup, links: Array(repeating: .empty, count: 8)))
        return SceneryDataWriter.encode(asset)
    }

    func testCrossLevelSceneryPlacementCopiesGeometryAndPlacesItOnlyAtSaveTime() async throws {
        // Source: a real RigidModel + mesh, standing in for "another
        // level's scenery model." Combines scenery+graphics in one file,
        // matching `hubb.sm2`'s own real shape.
        let sourceMesh = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let sourceRigidModel = makeRigidModel(meshID: 300)
        let sourceGraphics = makeGraphicsSection(
            textures: [(500, makeTexture())], materials: [(200, makeMaterial(name: "SrcMat"))],
            models: [(300, sourceMesh)], rigidModels: [(100, sourceRigidModel)]
        )
        let sourceBytes = makeSection(children: [(6, sourceGraphics)])
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-source-\(UUID().uuidString).sm2")
        try sourceBytes.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        // Destination: the real, common split shape, `SceneryData` lives
        // in its own `.sm2` (with no Graphics of its own beyond the empty
        // section `findFileRoot` needs to recognize it), while the actual
        // Graphics collections the copy lands in live in the paired
        // `.rm2` (`CrossFileModelCopierTests`' own real-disc case).
        let destBase = "synthetic-dest-\(UUID().uuidString)"
        let destSceneryBytes = makeSection(children: [(0, makeEmptySceneryRecord()), (6, makeGraphicsSection(models: [], rigidModels: []))])
        let destSceneryURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(destBase).sm2")
        try destSceneryBytes.write(to: destSceneryURL)
        defer { try? FileManager.default.removeItem(at: destSceneryURL) }

        // Sub-ID 11 is Graphics for a `.rm2` file (`RM2Parser.tier0Kind`) , 
        // *not* 6, which for `.rm2` falls in the 0-7 Instance-container
        // range instead; using 6 here silently made this fixture fail
        // `findFileRoot`'s own Graphics/Code recognition check.
        let destGraphicsBytes = makeSection(children: [(11, makeGraphicsSection(models: [], rigidModels: []))])
        let destGraphicsURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(destBase).rm2")
        try destGraphicsBytes.write(to: destGraphicsURL)
        defer { try? FileManager.default.removeItem(at: destGraphicsURL) }

        let workspace = WorkspaceViewModel()
        for url in [sourceURL, destSceneryURL, destGraphicsURL] {
            workspace.open(url: url)
            let loaded = expectation(description: "\(url.lastPathComponent) load completes")
            fulfill(loaded, whenTrue: { !workspace.isLoading })
            await fulfillment(of: [loaded], timeout: 10)
        }

        XCTAssertEqual(workspace.rootNodes.count, 3)
        let sourceRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName == sourceURL.lastPathComponent })
        let destSceneryRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName == destSceneryURL.lastPathComponent })
        let destGraphicsRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName == destGraphicsURL.lastPathComponent })

        // Same resolution real production code uses (`SceneryModeView
        // .place`'s cross-level branch), proves the paired `.rm2` really
        // is what gets discovered as the destination graphics owner.
        let resolvedDestinationGraphics = await workspace.loadingDestinationGraphics(for: destSceneryRoot)
        let destinationGraphics = try XCTUnwrap(resolvedDestinationGraphics)
        XCTAssertEqual(destinationGraphics.graphicsRoot.id, destGraphicsRoot.id, "the paired .rm2, not the .sm2 itself, must be discovered as the destination graphics owner")

        let source = CrossLevelSceneryGeometrySource(
            sourceModelID: 100, sourceIsSpecial: false,
            sourceSceneryFileRoot: sourceRoot, sourceSceneryBytes: sourceBytes,
            sourceGraphicsRoot: sourceRoot, sourceGraphicsBytes: sourceBytes,
            destinationGraphicsRoot: destinationGraphics.graphicsRoot
        )

        let patch = try XCTUnwrap(workspace.patchedFileBytes(
            applyingPrefixPatches: [],
            insertingNewInstances: [],
            insertingNewAIPositions: [],
            insertingNewCrossLevelScenery: [(source: source, position: SIMD3<Float>(1, 2, 3), rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1))],
            sceneryFileNode: destSceneryRoot,
            levelNode: destGraphicsRoot
        ), "the deferred cross-level copy + placement must succeed at save time, lastError: \(workspace.lastError ?? "nil")")

        XCTAssertNotEqual(patch.primaryBytes, destGraphicsBytes, "the destination .rm2's Graphics section must have actually grown with the copied geometry")
        let patchedSceneryBytes = try XCTUnwrap(patch.sceneryBytes, "scenery and graphics are two different files here, so the scenery edit must land in its own separate output")
        XCTAssertEqual(patch.sceneryFileDisplayName, destSceneryURL.lastPathComponent)

        let reparsedGraphics = try RM2Parser.parse(data: patch.primaryBytes, fileKind: .rm2, fileName: destGraphicsURL.lastPathComponent)
        let graphicsContainer = try XCTUnwrap(reparsedGraphics.children.first { $0.sectionType == .graphics })
        let rigidModels = try XCTUnwrap(graphicsContainer.children.first { $0.sectionType == .rigidModel })
        XCTAssertEqual(rigidModels.children.count, 1, "exactly one fresh RigidModel must have been copied into the destination .rm2's own Graphics section")
        let copiedModelID = try XCTUnwrap(rigidModels.children.first?.recordID)
        XCTAssertNotEqual(copiedModelID, 100, "the destination copy must get a fresh ID, not reuse the source's own")

        let reparsedScenery = try RM2Parser.parse(data: patchedSceneryBytes, fileKind: .sm2, fileName: destSceneryURL.lastPathComponent)
        guard let sceneryNode = reparsedScenery.children.first(where: { if case .scenery = $0.payload { return true } else { return false } }),
              case .scenery(let scenery)? = sceneryNode.payload
        else { return XCTFail("destination's SceneryData didn't survive the round trip") }
        XCTAssertEqual(scenery.placements.count, 1)
        XCTAssertEqual(scenery.placements.first?.modelID, copiedModelID, "the new placement must reference the freshly-copied destination-local model, not the source's own ID")
        XCTAssertEqual(scenery.placements.first?.isSpecial, false)
    }

    /// Real, reported bug: `loadingDestinationGraphics`'s archive-fallback
    /// path (taken whenever the destination level's paired `.rm2` isn't
    /// already individually open, exactly what happens browsing the
    /// Scenery tab, whose own `loadingSceneryLevelSource` deliberately
    /// never touches `rootNodes`) used to read the entry straight off the
    /// archive and hand back a `ChunkNode` that was never actually
    /// inserted into `rootNodes` at all. That node then got carried inside
    /// `CrossLevelSceneryGeometrySource.destinationGraphicsRoot` all the
    /// way to save time, where `patchedFileBytes`'s own validation requires
    /// that exact node to still be `findFileRoot`-reachable, a check that
    /// could never pass for a node that was never reachable to begin with,
    /// surfacing as "Can't place scenery copied from another level here , 
    /// its destination graphics file isn't one of this level's own
    /// currently-open files" for every real cross-level placement into a
    /// level whose own `.rm2` the user hadn't separately clicked into.
    ///
    /// Update: `expandArchiveEntry`'s later "parsing one half of a scenery/
    /// actor pair pulls in the other" fix means the destination's `.rm2`
    /// is now usually already tree-connected by the time this runs, see
    /// the setup code below for exactly which branch that leaves this test
    /// actually exercising. The end-to-end property under test
    /// (`patchedFileBytes` succeeds against an archive-resolved, not a
    /// loose-file, destination graphics root) still holds regardless.
    func testCrossLevelSceneryPlacementSucceedsWhenDestinationRM2WasNeverIndividuallyOpened() async throws {
        let sourceMesh = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let sourceRigidModel = makeRigidModel(meshID: 300)
        let sourceGraphics = makeGraphicsSection(
            textures: [(500, makeTexture())], materials: [(200, makeMaterial(name: "SrcMat"))],
            models: [(300, sourceMesh)], rigidModels: [(100, sourceRigidModel)]
        )
        let sourceBytes = makeSection(children: [(6, sourceGraphics)])
        let destSceneryBytes = makeSection(children: [(0, makeEmptySceneryRecord()), (6, makeGraphicsSection(models: [], rigidModels: []))])
        let destGraphicsBytes = makeSection(children: [(11, makeGraphicsSection(models: [], rigidModels: []))])

        // A real .BH/.BD archive pair holding all three as entries, the
        // real shape a mounted disc/archive has, unlike the test above's
        // three independently loose-opened files.
        func buildArchivePair(entries: [(name: String, content: Data)]) -> (bh: Data, bd: Data) {
            var bh = BinaryWriter()
            bh.writeInt32(0x501)
            var bd = Data()
            for entry in entries {
                let nameBytes = Array(entry.name.utf8)
                bh.writeInt32(Int32(nameBytes.count))
                bh.writeBytes(nameBytes)
                bh.writeUInt32(UInt32(bd.count))
                bh.writeUInt32(UInt32(entry.content.count))
                bd.append(entry.content)
            }
            return (bh.data, bd)
        }
        let (bhData, bdData) = buildArchivePair(entries: [
            (name: "source.sm2", content: sourceBytes),
            (name: "dest.sm2", content: destSceneryBytes),
            (name: "dest.rm2", content: destGraphicsBytes),
        ])
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LiveSceneryPlacementTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bhURL = tempDir.appendingPathComponent("TEST.BH")
        let bdURL = tempDir.appendingPathComponent("TEST.BD")
        try bhData.write(to: bhURL)
        try bdData.write(to: bdURL)

        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)
        XCTAssertNil(workspace.lastError)
        let archiveRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName.hasPrefix("TEST.BH") })

        // Expand only the two .sm2 entries, *not* the destination's own
        // .rm2 directly. This test predates `expandArchiveEntry`'s later
        // "parsing one half of a scenery/actor pair pulls in the other"
        // fix (see that function's own doc comment): expanding `dest.sm2`
        // now deliberately auto-expands its paired `dest.rm2` too, in the
        // same step, as a correct and desirable side effect (both halves
        // of a split-file level become tree-connected together, instead of
        // the second half silently triggering its own separate parse
        // later). That means `resolvingGraphicsRoot`'s archive-read
        // fallback branch this test originally targeted, reached only
        // when the destination's .rm2 *isn't yet* anywhere in `rootNodes`
        //, is no longer the specific branch this setup exercises; the
        // fast "already open" branch (`pairedGraphicsFileRoot`) is. The
        // real regression this test guards against (see the doc comment
        // above the test) is still fully covered either way: both branches
        // return a genuinely `findFileRoot`-reachable node, which is the
        // actual property `patchedFileBytes` below depends on.
        let sourceEntryNode = try XCTUnwrap(archiveRoot.children.first { $0.displayName == "source.sm2" })
        await workspace.expandArchiveEntry(sourceEntryNode, rootID: archiveRoot.id)
        let refetchedRootAfterFirstExpand = try XCTUnwrap(workspace.rootNodes.first { $0.id == archiveRoot.id })
        let destSceneryEntryNode = try XCTUnwrap(refetchedRootAfterFirstExpand.children.first { $0.displayName == "dest.sm2" })
        await workspace.expandArchiveEntry(destSceneryEntryNode, rootID: archiveRoot.id)

        let currentArchiveRoot = try XCTUnwrap(workspace.rootNodes.first { $0.id == archiveRoot.id })
        let expandedSourceRoot = try XCTUnwrap(currentArchiveRoot.children.first { $0.displayName == "source.sm2" })
        let expandedDestSceneryRoot = try XCTUnwrap(currentArchiveRoot.children.first { $0.displayName == "dest.sm2" })
        let destGraphicsPlaceholder = try XCTUnwrap(currentArchiveRoot.children.first { $0.displayName == "dest.rm2" })
        // Note: `payload` is *not* a useful signal here, a parsed file
        // root never carries one (only leaf chunk records do), whether
        // still an unexpanded placeholder or fully parsed; `children`
        // being non-empty is what actually distinguishes "auto-expanded"
        // from "still a placeholder".
        XCTAssertFalse(destGraphicsPlaceholder.children.isEmpty, "sanity: dest.rm2 is expected to already be auto-expanded here by expandArchiveEntry's sibling-pull-in, if this starts failing, that fix regressed, lastError: \(workspace.lastError ?? "nil")")

        let resolvedDestinationGraphics = await workspace.loadingDestinationGraphics(for: expandedDestSceneryRoot)
        let destinationGraphics = try XCTUnwrap(resolvedDestinationGraphics, "resolving the destination's paired .rm2 (whether already open or freshly read from the mounted archive) must succeed, lastError: \(workspace.lastError ?? "nil")")

        let source = CrossLevelSceneryGeometrySource(
            sourceModelID: 100, sourceIsSpecial: false,
            sourceSceneryFileRoot: expandedSourceRoot, sourceSceneryBytes: sourceBytes,
            sourceGraphicsRoot: expandedSourceRoot, sourceGraphicsBytes: sourceBytes,
            destinationGraphicsRoot: destinationGraphics.graphicsRoot
        )

        let patch = workspace.patchedFileBytes(
            applyingPrefixPatches: [],
            insertingNewInstances: [],
            insertingNewAIPositions: [],
            insertingNewCrossLevelScenery: [(source: source, position: SIMD3<Float>(1, 2, 3), rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1))],
            sceneryFileNode: expandedDestSceneryRoot,
            levelNode: destinationGraphics.graphicsRoot
        )
        XCTAssertNotNil(patch, "cross-level scenery placement must succeed with a destination graphics root resolved from a mounted archive (not a loose standalone file), lastError: \(workspace.lastError ?? "nil")")
    }

    /// Real, reported bug this regression-tests: moving an *existing*
    /// on-disk scenery placement (`LevelViewerRenderer.
    /// pendingSceneryTransformOverrides`) on a normal split-file level , 
    /// `SceneryData` in its own `.sm2`, everything else in the paired
    /// `.rm2`, used to be folded into the same `applyingAbsoluteByteRangePatches`
    /// list as camera control-point edits and checked against the
    /// *level's* file root unconditionally. Since a scenery placement's
    /// node belongs to the *scenery* file's root instead, that per-edit
    /// guard always saw a mismatch and refused with "Internal error:
    /// edits spanned more than one file, refusing to save a partial
    /// result," for every scenery move on every real split-file level , 
    /// exactly what surfaced in the Level Viewer as "no pending edits to
    /// bake in" for Quick Launch (the failed patch silently read as "no
    /// edits") plus that internal error elsewhere. The fix threads
    /// scenery-transform edits through their own dedicated parameter
    /// (`applyingSceneryTransformPatches`), routed to the scenery file's
    /// own bytes when it's a different file than `levelNode`'s own.
    func testSceneryTransformOverrideOnASplitFileLevelPatchesTheSceneryFileNotTheLevelFile() async throws {
        let originalPosition = SIMD3<Float>(5, 0, 5)
        let destBase = "synthetic-transform-dest-\(UUID().uuidString)"
        let destSceneryBytes = makeSection(children: [
            (0, makeSceneryRecordWithOnePlacement(modelID: 42, position: originalPosition)),
            (6, makeGraphicsSection(models: [], rigidModels: [])),
        ])
        let destSceneryURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(destBase).sm2")
        try destSceneryBytes.write(to: destSceneryURL)
        defer { try? FileManager.default.removeItem(at: destSceneryURL) }

        // The paired `.rm2`, has no scenery of its own; every real
        // split-file level's Instance/Trigger/Camera edits (none pending
        // in this test) would land here instead.
        let destGraphicsBytes = makeSection(children: [(11, makeGraphicsSection(models: [], rigidModels: []))])
        let destGraphicsURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(destBase).rm2")
        try destGraphicsBytes.write(to: destGraphicsURL)
        defer { try? FileManager.default.removeItem(at: destGraphicsURL) }

        let workspace = WorkspaceViewModel()
        for url in [destSceneryURL, destGraphicsURL] {
            workspace.open(url: url)
            let loaded = expectation(description: "\(url.lastPathComponent) load completes")
            fulfill(loaded, whenTrue: { !workspace.isLoading })
            await fulfillment(of: [loaded], timeout: 10)
        }

        let destSceneryRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName == destSceneryURL.lastPathComponent })
        let destGraphicsRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName == destGraphicsURL.lastPathComponent })
        let sceneryNode = try XCTUnwrap(workspace.sceneryNode(in: destSceneryRoot))
        guard case .scenery(let sceneryAsset) = sceneryNode.payload else { return XCTFail("expected a real SceneryData payload") }
        let placement = try XCTUnwrap(sceneryAsset.placements.first)
        let relativeMatrixOffset = try XCTUnwrap(placement.matrixFileOffset)

        // A deliberately different position, same "moved, not just
        // re-written" discipline `SceneryDataWriterTests` uses.
        let movedPosition = SIMD3<Float>(42, 3, -17)
        let encodedMatrix = SceneryDataWriter.writeModelMatrix([
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(movedPosition.x, movedPosition.y, movedPosition.z, 1),
        ])
        let sceneryTransformEdits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] = [
            (sceneryNode, sceneryNode.fileOffset + relativeMatrixOffset, encodedMatrix),
        ]

        let patch = try XCTUnwrap(workspace.patchedFileBytes(
            applyingPrefixPatches: [],
            applyingSceneryTransformPatches: sceneryTransformEdits,
            insertingNewInstances: [],
            insertingNewAIPositions: [],
            sceneryFileNode: sceneryNode,
            levelNode: destGraphicsRoot
        ), "a scenery-move-only save on a real split-file level must succeed, not refuse with a file-mismatch error, lastError: \(workspace.lastError ?? "nil")")
        XCTAssertNil(workspace.lastError, "must not set the \"edits spanned more than one file\" internal error for a normal scenery move on a split-file level")

        XCTAssertEqual(patch.primaryBytes, destGraphicsBytes, "no level-file edits were pending, so the .rm2's own bytes must be untouched")
        let patchedSceneryBytes = try XCTUnwrap(patch.sceneryBytes, "the scenery move must land in the scenery file's own separate output, not be silently dropped")
        XCTAssertEqual(patch.sceneryFileDisplayName, destSceneryURL.lastPathComponent)

        let reparsedScenery = try RM2Parser.parse(data: patchedSceneryBytes, fileKind: .sm2, fileName: destSceneryURL.lastPathComponent)
        guard let reparsedSceneryNode = reparsedScenery.children.first(where: { if case .scenery = $0.payload { return true } else { return false } }),
              case .scenery(let reparsedAsset)? = reparsedSceneryNode.payload
        else { return XCTFail("scenery record didn't survive the round trip") }
        XCTAssertEqual(reparsedAsset.placements.count, 1, "the move must not add/remove any placement")
        let moved = try XCTUnwrap(reparsedAsset.placements.first)
        XCTAssertEqual(moved.modelID, 42, "the move must not disturb the placement's identity")
        XCTAssertEqual(moved.translation, movedPosition, "the re-parsed placement must reflect the moved position, not the original")
    }

    /// Real, reported bug, the same "edits spanned more than one file"
    /// failure the scenery-transform test above already fixed for scenery
    /// moves, still open for `controlPointEdits` (Camera/Trigger Path
    /// control points, `applyingAbsoluteByteRangePatches`): that parameter
    /// was still unconditionally checked against `levelNode`'s own file
    /// root, even though `openLevelViewer` combines Camera/Trigger records
    /// from *both* a level's scenery file and its sibling actor file, so a
    /// real on-disk Camera control point can live in the scenery file just
    /// as easily as a scenery placement can. Dragging one and saving threw
    /// the exact same internal error. This pins the fix (splitting
    /// `controlPointEdits` by which file each edit's own node actually
    /// lives in) using a `controlPointEdits`-shaped patch, same
    /// `(node, absoluteOffset, encoded)` shape a real Camera control-point
    /// drag produces, targeting a node that lives in the scenery file
    /// while `levelNode` is the separate paired `.rm2`.
    func testControlPointEditOnANodeLivingInTheSceneryFileDoesNotThrowFileMismatch() async throws {
        let originalPosition = SIMD3<Float>(5, 0, 5)
        let destBase = "synthetic-controlpoint-dest-\(UUID().uuidString)"
        let destSceneryBytes = makeSection(children: [
            (0, makeSceneryRecordWithOnePlacement(modelID: 42, position: originalPosition)),
            (6, makeGraphicsSection(models: [], rigidModels: [])),
        ])
        let destSceneryURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(destBase).sm2")
        try destSceneryBytes.write(to: destSceneryURL)
        defer { try? FileManager.default.removeItem(at: destSceneryURL) }

        let destGraphicsBytes = makeSection(children: [(11, makeGraphicsSection(models: [], rigidModels: []))])
        let destGraphicsURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(destBase).rm2")
        try destGraphicsBytes.write(to: destGraphicsURL)
        defer { try? FileManager.default.removeItem(at: destGraphicsURL) }

        let workspace = WorkspaceViewModel()
        for url in [destSceneryURL, destGraphicsURL] {
            workspace.open(url: url)
            let loaded = expectation(description: "\(url.lastPathComponent) load completes")
            fulfill(loaded, whenTrue: { !workspace.isLoading })
            await fulfillment(of: [loaded], timeout: 10)
        }

        let destSceneryRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName == destSceneryURL.lastPathComponent })
        let destGraphicsRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName == destGraphicsURL.lastPathComponent })
        let sceneryNode = try XCTUnwrap(workspace.sceneryNode(in: destSceneryRoot))
        guard case .scenery(let sceneryAsset) = sceneryNode.payload else { return XCTFail("expected a real SceneryData payload") }
        let placement = try XCTUnwrap(sceneryAsset.placements.first)
        let relativeMatrixOffset = try XCTUnwrap(placement.matrixFileOffset)

        // A `controlPointEdits`-shaped patch (not `sceneryTransformEdits`)
        // whose node, `sceneryNode`, lives in the scenery file, standing
        // in for a real Camera Path control point that happens to be
        // stored there. What matters for this bug is purely structural
        // (which file the node resolves to), not the record's own semantic
        // type.
        let movedValue = SIMD4<Float>(42, 3, -17, 1)
        let encodedPoint = SceneryDataWriter.writeModelMatrix([
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), movedValue,
        ])
        let controlPointEdits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] = [
            (sceneryNode, sceneryNode.fileOffset + relativeMatrixOffset, encodedPoint),
        ]

        // `sceneryFileNode` is passed here because the real production
        // call site (`LevelViewerWindow.computingPendingOverridePatch`)
        // always passes it too, captured once for the whole Level Viewer
        // session (`sceneryAnchorNode = context.sceneryNode`), not just
        // when a scenery-specific edit happens to be pending.
        let patch = try XCTUnwrap(workspace.patchedFileBytes(
            applyingPrefixPatches: [],
            applyingAbsoluteByteRangePatches: controlPointEdits,
            insertingNewInstances: [],
            insertingNewAIPositions: [],
            sceneryFileNode: sceneryNode,
            levelNode: destGraphicsRoot
        ), "a control-point edit whose node lives in the scenery file must succeed, not refuse with a file-mismatch error, lastError: \(workspace.lastError ?? "nil")")
        XCTAssertNil(workspace.lastError, "must not set the \"edits spanned more than one file\" internal error for a control point that genuinely lives in the scenery file")

        XCTAssertEqual(patch.primaryBytes, destGraphicsBytes, "no level-file edits were pending, so the .rm2's own bytes must be untouched")
        let patchedSceneryBytes = try XCTUnwrap(patch.sceneryBytes, "the control-point edit must land in the scenery file's own separate output, not be silently dropped")

        let reparsedScenery = try RM2Parser.parse(data: patchedSceneryBytes, fileKind: .sm2, fileName: destSceneryURL.lastPathComponent)
        guard let reparsedSceneryNode = reparsedScenery.children.first(where: { if case .scenery = $0.payload { return true } else { return false } }),
              case .scenery(let reparsedAsset)? = reparsedSceneryNode.payload
        else { return XCTFail("scenery record didn't survive the round trip") }
        let reparsedPlacement = try XCTUnwrap(reparsedAsset.placements.first)
        XCTAssertEqual(reparsedPlacement.translation, SIMD3<Float>(movedValue.x, movedValue.y, movedValue.z), "the re-parsed record must reflect the patched value")
    }
}
