import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Real, reported bug: "Save Chunk Overrides…" (which only writes a
/// *separate copy*, `LevelViewerWindow.performSaveLevelOverrides()`'s own
/// doc comment says "The original file(s) were not modified", never
/// touches `rootNodes`/`rawFileBytesByRootID`), then closing the Chunk
/// Viewer window and clicking the *same* level in the sidebar again shows
/// only scenery, zero Instance/Trigger/Camera markers, even though the
/// first open showed them correctly. Since "Save Chunk Overrides…" is
/// confirmed not to mutate any in-memory session state at all, this
/// isolates the actual variable: does a plain close-then-reopen of the
/// *same* archive-browsed level (no save in between) lose its sibling
/// `.rm2` markers the second time? Reuses `ArchiveBrowsedLevelSiblingTests`'
/// own synthetic-archive setup, which already proves the *first* open
/// works correctly.
@MainActor
final class ZZReopenSameArchiveLevelTwiceTests: XCTestCase {
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

    private func findScenery(in node: ChunkNode) -> ChunkNode? {
        if case .scenery = node.payload { return node }
        for child in node.children {
            if let found = findScenery(in: child) { return found }
        }
        return nil
    }

    private func makeEmptySceneryRecord(chunkName: String) -> Data {
        let modelGroup = SceneryModelGroup(header: 0, placements: [])
        let asset = SceneryAsset(id: 0, chunkName: chunkName, skydomeID: nil, ambientLights: [], directionalLights: [], pointLights: [], negativeLights: [], root: SceneryGroup(model: modelGroup, links: Array(repeating: .empty, count: 8)))
        return SceneryDataWriter.encode(asset)
    }

    private func buildArchivePair(entries: [(name: String, content: Data)]) -> (bh: Data, bd: Data) {
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

    func testClosingAndReopeningTheSameArchiveBrowsedLevelStillFindsInstanceMarkersTheSecondTime() async throws {
        let entryName = "Levels/Earth/Hub/beach"
        let smBytes = makeSection(children: [(0, makeEmptySceneryRecord(chunkName: entryName)), (6, makeSection(children: []))])

        let instance = WorldPlacementWriter.writeNewInstance(objectID: 3, position: SIMD4<Float>(1, 2, 3, 1), rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(100, instance)])
        let instanceContainer = makeSection(children: [(6, objectInstanceCollection)])
        let emptyCodeSection = makeSection(children: [])
        let rmBytes = makeSection(children: [(0, instanceContainer), (10, emptyCodeSection)])

        let (bhData, bdData) = buildArchivePair(entries: [
            (name: "\(entryName).sm2", content: smBytes),
            (name: "\(entryName).rm2", content: rmBytes),
        ])

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ZZReopenSameArchiveLevelTwiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bhURL = tempDir.appendingPathComponent("TEST.BH")
        let bdURL = tempDir.appendingPathComponent("TEST.BD")
        try bhData.write(to: bhURL)
        try bdData.write(to: bdURL)

        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)
        XCTAssertNil(workspace.lastError, "open(url:) on the synthetic .BH must succeed, got: \(workspace.lastError ?? "")")

        let archiveRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName.hasPrefix("TEST.BH") }, "rootNodes: \(workspace.rootNodes.map(\.displayName))")
        let smNode = try XCTUnwrap(archiveRoot.children.first { $0.displayName == "\(entryName).sm2" })

        await workspace.expandArchiveEntry(smNode, rootID: archiveRoot.id)

        let expandedRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName.hasPrefix("TEST.BH") })
        let expandedSMFileRoot = try XCTUnwrap(expandedRoot.children.first { $0.displayName == "\(entryName).sm2" })
        let sceneryLeaf = try XCTUnwrap(findScenery(in: expandedSMFileRoot), "expanded .sm2 entry didn't decode a real SceneryData payload anywhere in its tree")
        guard case .scenery(let sceneryAsset)? = sceneryLeaf.payload else {
            return XCTFail("unreachable, findScenery only returns nodes with a .scenery payload")
        }

        // First open, matches `ArchiveBrowsedLevelSiblingTests`, confirmed working.
        await workspace.openLevelViewer(for: sceneryAsset, node: sceneryLeaf)
        let firstContext = try XCTUnwrap(workspace.levelViewerContext, "first openLevelViewer must populate a real context")
        XCTAssertEqual(firstContext.instanceMarkers.count, 1, "sanity: first open must find the real Instance record")

        // "Close the window", the *only* thing `GPUViewerWindowHosts`'
        // `.onDisappear`/Close-button handlers actually do to `workspace`
        // state (see `LevelViewerWindowHost`/`WorkspaceViewModel.
        // currentLevelViewerDirtyProvider` cleanup), no save, no rescan.
        workspace.levelViewerContext = nil

        // Reopen the exact same level via the exact same public entry
        // point the sidebar/Levels Hub itself uses, no edits, no save,
        // nothing else touched `rootNodes` in between.
        await workspace.openLevelViewer(for: sceneryAsset, node: sceneryLeaf)
        let secondContext = try XCTUnwrap(workspace.levelViewerContext, "second openLevelViewer must populate a real context")
        XCTAssertEqual(secondContext.instanceMarkers.count, 1, "reopening the same level a second time must still find its real Instance record, not silently come back empty")
        XCTAssertEqual(secondContext.placements.count, firstContext.placements.count, "scenery placement count must also stay consistent across reopen")
    }
}
