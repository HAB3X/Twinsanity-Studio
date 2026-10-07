import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Regression test for a real, reported bug: "Save Chunk Overrides…"
/// always writes its Instance/Trigger/Camera half and its scenery half as
/// two loose, same-folder, same-base-name files (`performSaveLevelOverrides`'s
/// own doc comment), never as archive entries. Reopening the scenery half
/// of that pair showed real Scenery but zero Instance/Trigger/Camera
/// markers ("I can't see any of the actors or anything but the scenery"),
/// because `siblingActorFileRoot` only ever looked for a sibling inside a
/// *mounted archive* (`archiveIndexByRootID`), a standalone-opened loose
/// `.sm2` has no owning archive at all, so the lookup silently returned
/// `nil`. The fix (`siblingActorFileRootFromDisk`) adds a same-folder,
/// same-base-name disk scan fallback, mirroring `loadSoundBankAsync`'s own
/// `.MH`/`.MB` pairing. This exercises the exact real user path, `open(url:)`
/// on two loose sibling files, then `openLevelViewer`, rather than testing
/// the private fallback in isolation.
@MainActor
final class LooseFileSiblingTests: XCTestCase {
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

    func testReopeningALooseSceneryFileFindsItsRealInstanceMarkersFromTheSiblingRM2OnDisk() async throws {
        let baseName = "beach_edited"
        let smBytes = makeSection(children: [(0, makeEmptySceneryRecord(chunkName: baseName)), (6, makeSection(children: []))])

        let instance = WorldPlacementWriter.writeNewInstance(objectID: 3, position: SIMD4<Float>(1, 2, 3, 1), rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(100, instance)])
        let instanceContainer = makeSection(children: [(6, objectInstanceCollection)])
        let emptyCodeSection = makeSection(children: [])
        let rmBytes = makeSection(children: [(0, instanceContainer), (10, emptyCodeSection)])

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LooseFileSiblingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // Same directory, same base name, real .sm2/.rm2 extensions , 
        // exactly what "Save Chunk Overrides…" writes.
        let smURL = tempDir.appendingPathComponent("\(baseName).sm2")
        let rmURL = tempDir.appendingPathComponent("\(baseName).rm2")
        try smBytes.write(to: smURL)
        try rmBytes.write(to: rmURL)

        let workspace = WorkspaceViewModel()

        workspace.open(url: rmURL)
        let firstLoad = expectation(description: "loose .rm2 load completes")
        fulfill(firstLoad, whenTrue: { !workspace.isLoading })
        await fulfillment(of: [firstLoad], timeout: 30)

        workspace.open(url: smURL)
        let secondLoad = expectation(description: "loose .sm2 load completes")
        fulfill(secondLoad, whenTrue: { !workspace.isLoading })
        await fulfillment(of: [secondLoad], timeout: 30)

        XCTAssertNil(workspace.lastError, "opening both loose files must succeed, got: \(workspace.lastError ?? "")")
        XCTAssertEqual(workspace.rootNodes.count, 2, "both loose files must be tracked as their own root nodes: \(workspace.rootNodes.map(\.displayName))")

        let smRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName == "\(baseName).sm2" })
        let sceneryLeaf = try XCTUnwrap(findScenery(in: smRoot), "the loose .sm2 didn't decode a real SceneryData payload anywhere in its tree")
        guard case .scenery(let sceneryAsset)? = sceneryLeaf.payload else {
            return XCTFail("unreachable, findScenery only returns nodes with a .scenery payload")
        }

        await workspace.openLevelViewer(for: sceneryAsset, node: sceneryLeaf)

        let context = try XCTUnwrap(workspace.levelViewerContext, "openLevelViewer must populate a real context")
        XCTAssertEqual(context.instanceMarkers.count, 1,
                       "the sibling .rm2's real Instance record must be found via the same-folder disk fallback, not silently come back empty")
    }

    /// Same real bug, but the sibling `.rm2` was never opened at all before
    /// `openLevelViewer` runs, only the `.sm2` was. The fallback must find
    /// and parse it itself (mirroring the archive-based fallback's own
    /// on-demand `expandArchiveEntry` behavior), not just work when both
    /// happen to already be loaded.
    func testOpeningOnlyTheLooseSceneryFileStillFindsTheUnopenedSiblingRM2OnDisk() async throws {
        let baseName = "beach_edited"
        let smBytes = makeSection(children: [(0, makeEmptySceneryRecord(chunkName: baseName)), (6, makeSection(children: []))])

        let instance = WorldPlacementWriter.writeNewInstance(objectID: 3, position: SIMD4<Float>(1, 2, 3, 1), rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(100, instance)])
        let instanceContainer = makeSection(children: [(6, objectInstanceCollection)])
        let emptyCodeSection = makeSection(children: [])
        let rmBytes = makeSection(children: [(0, instanceContainer), (10, emptyCodeSection)])

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LooseFileSiblingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let smURL = tempDir.appendingPathComponent("\(baseName).sm2")
        let rmURL = tempDir.appendingPathComponent("\(baseName).rm2")
        try smBytes.write(to: smURL)
        try rmBytes.write(to: rmURL)

        let workspace = WorkspaceViewModel()

        workspace.open(url: smURL)
        let load = expectation(description: "loose .sm2 load completes")
        fulfill(load, whenTrue: { !workspace.isLoading })
        await fulfillment(of: [load], timeout: 30)

        XCTAssertNil(workspace.lastError, "opening the loose .sm2 must succeed, got: \(workspace.lastError ?? "")")
        XCTAssertEqual(workspace.rootNodes.count, 1, "only the .sm2 should be loaded so far: \(workspace.rootNodes.map(\.displayName))")

        let smRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName == "\(baseName).sm2" })
        let sceneryLeaf = try XCTUnwrap(findScenery(in: smRoot))
        guard case .scenery(let sceneryAsset)? = sceneryLeaf.payload else {
            return XCTFail("unreachable, findScenery only returns nodes with a .scenery payload")
        }

        await workspace.openLevelViewer(for: sceneryAsset, node: sceneryLeaf)

        let context = try XCTUnwrap(workspace.levelViewerContext, "openLevelViewer must populate a real context")
        XCTAssertEqual(context.instanceMarkers.count, 1,
                       "the never-individually-opened sibling .rm2 must still be found and parsed on demand")
    }
}
