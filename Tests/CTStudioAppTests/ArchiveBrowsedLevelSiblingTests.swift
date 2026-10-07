import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Regression test for a real, reported bug: opening a level reached by
/// browsing a standalone `.BH` archive (the normal way, click the `.BH`,
/// expand into its entries, click a `.sm2`) showed real scenery but zero
/// Instance/Trigger/Camera markers, even though the level's own paired
/// `.rm2` genuinely has them. This exercises the exact real user path , 
/// `open(url:)` on a loose `.BH`, `expandArchiveEntry` on its `.sm2`
/// entry, then `openLevelViewer`, rather than testing `siblingActorFileRoot`
/// in isolation, so it catches anything wrong anywhere along that chain.
@MainActor
final class ArchiveBrowsedLevelSiblingTests: XCTestCase {
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

    /// The `.scenery`-payloaded node can be anywhere in the parsed file
    /// root's own children, `RM2Parser.parse`'s root itself is always a
    /// plain `.null` file-root node, never the payload-carrying leaf.
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

    /// `BDArchiveParser`'s own real, minimal `.BH` format: magic `0x501`,
    /// then repeated `nameLen:Int32, name:ASCII, offset:UInt32, size:UInt32`
    /// entries, matches `DiscImageSidebarMergeTests`' own single-entry
    /// helper, extended here to pack multiple real entries into one `.BD`.
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

    func testOpeningALevelThroughAStandaloneBHArchiveFindsItsRealInstanceMarkers() async throws {
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

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveBrowsedLevelSiblingTests-\(UUID().uuidString)")
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

        // `expandArchiveEntry` replaces the node in place (fresh UUID) , 
        // re-find it by name rather than reusing the pre-expansion reference.
        let expandedRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName.hasPrefix("TEST.BH") })
        let expandedSMFileRoot = try XCTUnwrap(expandedRoot.children.first { $0.displayName == "\(entryName).sm2" })
        let sceneryLeaf = try XCTUnwrap(findScenery(in: expandedSMFileRoot), "expanded .sm2 entry didn't decode a real SceneryData payload anywhere in its tree")
        guard case .scenery(let sceneryAsset)? = sceneryLeaf.payload else {
            return XCTFail("unreachable, findScenery only returns nodes with a .scenery payload")
        }

        await workspace.openLevelViewer(for: sceneryAsset, node: sceneryLeaf)

        let context = try XCTUnwrap(workspace.levelViewerContext, "openLevelViewer must populate a real context")
        XCTAssertEqual(context.instanceMarkers.count, 1,
                       "the level's real paired .rm2 has one real Instance record, it must be found via the sibling lookup, not silently come back empty")
    }

    /// Regression test for a second, real bug in the same feature: even once
    /// the sibling `.rm2` is correctly located (the fix above), its own
    /// Instance/Trigger/Camera records still came back empty when that
    /// `.rm2`'s *own* top-level entries were only its Instance container , 
    /// no Code, no Graphics section, a real, plausible shape for a simple
    /// actor file. `findFileRoot`'s "looks like a file root" heuristic only
    /// recognized Code/Graphics-family children, not Instance-family ones,
    /// so it silently failed to recognize the `.rm2`'s own root at all.
    func testSiblingRM2WithOnlyAnInstanceSectionAndNoCodeOrGraphicsStillFindsItsMarkers() async throws {
        let entryName = "Levels/Earth/Hub/beach"
        let smBytes = makeSection(children: [(0, makeEmptySceneryRecord(chunkName: entryName)), (6, makeSection(children: []))])

        let instance = WorldPlacementWriter.writeNewInstance(objectID: 3, position: SIMD4<Float>(1, 2, 3, 1), rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(100, instance)])
        let instanceContainer = makeSection(children: [(6, objectInstanceCollection)])
        // No Code (sub-ID 10), no Graphics (sub-ID 11), only the Instance
        // container (sub-ID 0-7), unlike the sibling test above.
        let rmBytes = makeSection(children: [(0, instanceContainer)])

        let (bhData, bdData) = buildArchivePair(entries: [
            (name: "\(entryName).sm2", content: smBytes),
            (name: "\(entryName).rm2", content: rmBytes),
        ])

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveBrowsedLevelSiblingTests-\(UUID().uuidString)")
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

        await workspace.openLevelViewer(for: sceneryAsset, node: sceneryLeaf)

        let context = try XCTUnwrap(workspace.levelViewerContext, "openLevelViewer must populate a real context")
        XCTAssertEqual(context.instanceMarkers.count, 1,
                       "the sibling .rm2's real Instance record must be found even though that file has no Code/Graphics section of its own")
    }
}
