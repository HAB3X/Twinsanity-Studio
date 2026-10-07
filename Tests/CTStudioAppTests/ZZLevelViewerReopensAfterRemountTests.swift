import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Real, reported bug: after "Rebuild All Collision" saves (which routes
/// through `savingPendingLevelViewerEditsToMountedDisc` -> `refreshingMountedDiscImage`),
/// the already-open Level Viewer window's "Play"/"Save" buttons went
/// permanently disabled and the Scenery tab's placement menu went missing
/// entirely, both symptoms of the same root cause: `refreshingMountedDiscImage`
/// gives every node in `rootNodes` a fresh identity, but the open window's
/// `LevelViewerContext` is a frozen snapshot still holding the *old* nodes,
/// which `findFileRoot`'s `===` reference-identity walk can never find
/// again in the new tree. Fix: `refreshingMountedDiscImage` now re-opens
/// the current level against the fresh tree automatically.
///
/// `refreshingMountedDiscImage` only does anything for a URL it recognizes
/// as an actually-mounted disc (`mountedDiscImageURLByRootID`), which
/// `mountDiscImage` only ever populates for a real `.iso`/`.cue`/`.bin` , 
/// a bare `.BH` doesn't qualify. This builds a minimal synthetic `.iso`
/// wrapping a real `.BH`/`.BD` archive pair (same low-level sector
/// construction `DiscImageSidebarMergeTests` already established) around
/// the same real scenery+Instance archive shape `ZZReclickSameSidebarLevelTests`
/// uses, so the whole real `mountDiscImage` -> `refreshingMountedDiscImage`
/// path under test actually runs, not a stand-in for it.
@MainActor
final class ZZLevelViewerReopensAfterRemountTests: XCTestCase {
    private static let sectorSize = 2048

    private func directoryRecord(lba: UInt32, size: UInt32, isDirectory: Bool, identifier: [UInt8]) -> [UInt8] {
        var record: [UInt8] = []
        let identifierLength = identifier.count
        let recordLength = 33 + identifierLength + (identifierLength % 2 == 0 ? 1 : 0)
        record.append(UInt8(recordLength))
        record.append(0)
        record += withUnsafeBytes(of: lba.littleEndian) { Array($0) } + withUnsafeBytes(of: lba.bigEndian) { Array($0) }
        record += withUnsafeBytes(of: size.littleEndian) { Array($0) } + withUnsafeBytes(of: size.bigEndian) { Array($0) }
        record += [UInt8](repeating: 0, count: 7) // date/time
        record.append(isDirectory ? 2 : 0)
        record += [0, 0] // file unit size, interleave gap
        record += withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) } + withUnsafeBytes(of: UInt16(1).bigEndian) { Array($0) }
        record.append(UInt8(identifierLength))
        record += identifier
        if identifierLength % 2 == 0 { record.append(0) }
        return record
    }

    private func makeSector(_ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count <= Self.sectorSize)
        return bytes + [UInt8](repeating: 0, count: Self.sectorSize - bytes.count)
    }

    private func chunked(_ bytes: [UInt8], into size: Int) -> [[UInt8]] {
        guard size > 0, !bytes.isEmpty else { return bytes.isEmpty ? [] : [bytes] }
        return stride(from: 0, to: bytes.count, by: size).map { Array(bytes[$0..<Swift.min($0 + size, bytes.count)]) }
    }

    /// Minimal disc: root directory containing two sibling real files,
    /// `TEST.BH` and `TEST.BD`, same shape `DiscImageSidebarMergeTests.
    /// buildSyntheticISOWithArchivePair` already proved works against the
    /// real `mountDiscImage` pipeline.
    private func buildSyntheticISOWithArchivePair(bhBytes: [UInt8], bdBytes: [UInt8]) throws -> URL {
        var sectors: [[UInt8]] = (0..<20).map { _ in makeSector([]) }

        var pvd: [UInt8] = [1]
        pvd += Array("CD001".utf8)
        pvd.append(1)
        pvd += [UInt8](repeating: 0, count: 156 - pvd.count)
        pvd += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        sectors[16] = makeSector(pvd)

        var terminator: [UInt8] = [255]
        terminator += Array("CD001".utf8)
        terminator.append(1)
        sectors[17] = makeSector(terminator)

        let bdLBA = 19 + UInt32((bhBytes.count + Self.sectorSize - 1) / Self.sectorSize)
        var root: [UInt8] = []
        root += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        root += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [1])
        root += directoryRecord(lba: 19, size: UInt32(bhBytes.count), isDirectory: false, identifier: Array("TEST.BH;1".utf8))
        root += directoryRecord(lba: bdLBA, size: UInt32(bdBytes.count), isDirectory: false, identifier: Array("TEST.BD;1".utf8))
        sectors[18] = makeSector(root)

        var offset = 19
        for chunk in chunked(bhBytes, into: Self.sectorSize) {
            while sectors.count <= offset { sectors.append(makeSector([])) }
            sectors[offset] = makeSector(chunk)
            offset += 1
        }
        for chunk in chunked(bdBytes, into: Self.sectorSize) {
            while sectors.count <= offset { sectors.append(makeSector([])) }
            sectors[offset] = makeSector(chunk)
            offset += 1
        }

        let flatData = Data(sectors.flatMap { $0 })
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-remount-\(UUID().uuidString).iso")
        try flatData.write(to: tempURL)
        return tempURL
    }

    // MARK: - Real scenery+Instance archive content (same fixture shape as ZZReclickSameSidebarLevelTests)

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
        for child in children { writer.writeBytes(child.bytes) }
        return writer.data
    }

    private func makeSceneryRecordWithOnePlacement(chunkName: String) -> Data {
        let position = SIMD3<Float>(4, 5, 6)
        let placement = SceneryModelPlacement(
            modelID: 1, isSpecial: false,
            boundingBoxMin: SIMD4<Float>(position, 1) - SIMD4<Float>(1, 1, 1, 0),
            boundingBoxMax: SIMD4<Float>(position, 1) + SIMD4<Float>(1, 1, 1, 0),
            modelMatrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(position.x, position.y, position.z, 1)]
        )
        let modelGroup = SceneryModelGroup(header: 0x1613, placements: [placement])
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

    private func findScenery(in node: ChunkNode) -> ChunkNode? {
        if case .scenery = node.payload { return node }
        for child in node.children { if let found = findScenery(in: child) { return found } }
        return nil
    }

    func testLevelViewerAutomaticallyReopensAgainstFreshNodesAfterRefreshingMountedDiscImage() async throws {
        let entryName = "Levels/Earth/Hub/beach"
        let smBytes = makeSection(children: [(0, makeSceneryRecordWithOnePlacement(chunkName: entryName)), (6, makeSection(children: []))])
        let instance = WorldPlacementWriter.writeNewInstance(objectID: 3, position: SIMD4<Float>(1, 2, 3, 1), rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(100, instance)])
        let instanceContainer = makeSection(children: [(6, objectInstanceCollection)])
        let emptyCodeSection = makeSection(children: [])
        let rmBytes = makeSection(children: [(0, instanceContainer), (10, emptyCodeSection)])
        let (bhData, bdData) = buildArchivePair(entries: [
            (name: "\(entryName).sm2", content: smBytes),
            (name: "\(entryName).rm2", content: rmBytes),
        ])

        let isoURL = try buildSyntheticISOWithArchivePair(bhBytes: Array(bhData), bdBytes: Array(bdData))
        defer { try? FileManager.default.removeItem(at: isoURL) }

        let workspace = WorkspaceViewModel()
        workspace.mountDiscImage(url: isoURL)
        for _ in 0..<600 where workspace.rootNodes.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let discRoot = try XCTUnwrap(workspace.rootNodes.first, "rootNodes stayed empty after mountDiscImage")
        let bhNode = try XCTUnwrap(discRoot.children.first { $0.displayName.hasPrefix("TEST.BH") }, "disc children: \(discRoot.children.map(\.displayName))")
        // A disc-mounted `.BH`'s sibling `.BD` lives inside the disc image
        // itself, not on the real filesystem, `select(_:)` is the real
        // path that extracts both to a temp directory first (see
        // `DiscImageSidebarMergeTests.testSelectingDiscMountedArchiveIndexAlsoExtractsItsRealDataSibling`'s
        // own doc comment); `expandArchiveEntry` alone doesn't do that
        // extraction. `select`'s own work is deferred via `DispatchQueue.
        // main.async`, which doesn't reliably fire under `Task.sleep`
        // polling, an explicit `expectation`/`fulfillment` wait is what
        // that same reference test uses to make it fire for real.
        workspace.select(bhNode)
        let selectExpectation = expectation(description: "select's deferred archive-open work runs")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { selectExpectation.fulfill() }
        await fulfillment(of: [selectExpectation], timeout: 5)
        XCTAssertNil(workspace.lastError, "opening the disc-mounted TEST.BH must succeed, got: \(workspace.lastError ?? "")")
        // `select(bhNode)` opens the archive as its own new top-level root
        // (same shape `DiscImageSidebarMergeTests`'s own reference test
        // confirms), not a child of the disc root.
        let archiveRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName.hasPrefix("TEST.BH") }, "rootNodes: \(workspace.rootNodes.map(\.displayName))")
        let smNode = try XCTUnwrap(archiveRoot.children.first { $0.displayName == "\(entryName).sm2" }, "TEST.BH children: \(archiveRoot.children.map(\.displayName))")
        await workspace.expandArchiveEntry(smNode, rootID: archiveRoot.id)
        let reExpandedArchiveRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName.hasPrefix("TEST.BH") })
        let expandedSMNode = try XCTUnwrap(reExpandedArchiveRoot.children.first { $0.displayName == "\(entryName).sm2" })
        let sceneryNode = try XCTUnwrap(findScenery(in: expandedSMNode))
        guard case .scenery(let asset)? = sceneryNode.payload else { return XCTFail("unreachable") }

        await workspace.openLevelViewer(for: asset, node: sceneryNode)
        let originalContext = try XCTUnwrap(workspace.levelViewerContext)
        XCTAssertEqual(originalContext.instanceMarkers.count, 1, "sanity: the level must have opened with its real Instance record")
        let originalInstanceNode = try XCTUnwrap(originalContext.instanceMarkers.first?.node)
        XCTAssertTrue(workspace.canSaveEdits(for: originalInstanceNode), "sanity: Play/Save must be enabled right after opening")

        // The actual fix under test, this is exactly what "Rebuild All
        // Collision"'s own save calls under the hood.
        workspace.refreshingMountedDiscImage(url: isoURL)

        // Without the fix, `canSaveEdits(for: originalInstanceNode)` would
        // stay false forever (the old node's root closed, never re-
        // findable by `===` identity) even though a perfectly good, fresh
        // copy of the exact same level is one `openLevelViewer` call away.
        // Poll for the context to actually become a *new* one (the fix
        // runs the real re-open on a `Task`).
        for _ in 0..<600 where workspace.levelViewerContext?.id == originalContext.id {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let refreshedContext = try XCTUnwrap(workspace.levelViewerContext)
        XCTAssertNotEqual(refreshedContext.id, originalContext.id, "refreshingMountedDiscImage must have re-opened the level against a fresh context")
        XCTAssertEqual(refreshedContext.instanceMarkers.count, 1, "the re-opened level must still find its real Instance record")

        let refreshedInstanceNode = try XCTUnwrap(refreshedContext.instanceMarkers.first?.node)
        XCTAssertTrue(workspace.canSaveEdits(for: refreshedInstanceNode), "Play/Save must be enabled again against the freshly re-opened level's own nodes, this is the real, reported bug")
    }
}
