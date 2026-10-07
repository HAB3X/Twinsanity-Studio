import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Real, reported bug: closing the Chunk Viewer window (which only nils
/// `levelViewerContext`, see `GPUViewerWindowHosts.LevelViewerWindowHost`'s
/// own doc comment) and then clicking the *same* level a second time in the
/// sidebar tree either reopened showing scenery only or didn't reopen at
/// all. Root cause: `WorkspaceViewModel.select(_:)`'s "Frictionless Chunk
/// Loading" auto-open only fired right after a *fresh* `expandArchiveEntry`
/// call, `isExpandableArchiveEntry` only recognizes the still-unexpanded
/// placeholder shape a chunk file starts as, so every later click on the
/// *same*, by-then already-expanded `.sm2` silently fell through the whole
/// guard chain and did nothing.
///
/// `select(_:)`'s own body is wrapped in `DispatchQueue.main.async`, which
/// doesn't reliably fire under `Task.sleep`-based polling in a headless
/// XCTest host (confirmed separately, at length, earlier in this session , 
/// see `ZZRefreshingMountedDiscImageTests`'s own doc comment for the same
/// issue). The fix's actual decision logic was pulled out into
/// `WorkspaceViewModel.reclickedAlreadyExpandedLevelSceneryNode(_:)`, a
/// pure, `nonisolated` function, specifically so it can be tested directly
/// without needing that dispatch to fire, this exercises that function
/// against the same real, synthetic archive shape
/// `ArchiveBrowsedLevelSiblingTests` already proves the underlying
/// `openLevelViewer` data-gathering handles correctly.
@MainActor
final class ZZReclickSameSidebarLevelTests: XCTestCase {
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

    // `WorkspaceViewModel.firstSceneryNode` (which the fix under test , 
    // `reclickedAlreadyExpandedLevelSceneryNode`, relies on) requires a
    // *non-empty* placement tree, matching the Chunk Hub's own real-level
    // filter (see that function's own doc comment), an empty record
    // legitimately isn't "a level" to reopen. Needs one real placement,
    // unlike `ArchiveBrowsedLevelSiblingTests`' own `makeEmptySceneryRecord`
    // (which only feeds `openLevelViewer` directly, never through
    // `firstSceneryNode`).
    private func makeSceneryRecordWithOnePlacement(chunkName: String) -> Data {
        let position = SIMD3<Float>(4, 5, 6)
        let placement = SceneryModelPlacement(
            modelID: 1, isSpecial: false,
            boundingBoxMin: SIMD4<Float>(position, 1) - SIMD4<Float>(1, 1, 1, 0),
            boundingBoxMax: SIMD4<Float>(position, 1) + SIMD4<Float>(1, 1, 1, 0),
            modelMatrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(position.x, position.y, position.z, 1)]
        )
        // `header: 0x1613` (not `0`, matches `LiveSceneryPlacementTests`'
        // own `makeSceneryRecordWithOnePlacement`), the real magic a
        // non-empty model group needs for `SceneryDataWriter`/`RM2Parser`
        // to round-trip its placements at all, `header: 0` round-trips as
        // zero placements regardless of what's passed in.
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
        for child in node.children {
            if let found = findScenery(in: child) { return found }
        }
        return nil
    }

    func testReclickingTheSameAlreadyExpandedLevelFindsItsSceneryNodeAgain() async throws {
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

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ZZReclickSameSidebarLevelTests-\(UUID().uuidString)")
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

        // Before the first click (the real still-unexpanded placeholder
        // shape): the reclick branch must NOT fire, there's nothing
        // expanded yet, so this has to fall through to the normal
        // fresh-expand path instead, exactly as before this fix.
        XCTAssertNil(WorkspaceViewModel.reclickedAlreadyExpandedLevelSceneryNode(smNode), "an unexpanded placeholder must never satisfy the reclick branch")

        // First click: the real fresh-expand path (already covered end to
        // end by `ArchiveBrowsedLevelSiblingTests`), expand for real here
        // too, so this test's second-click assertion is against real,
        // parsed data, not a hand-built stand-in.
        await workspace.expandArchiveEntry(smNode, rootID: archiveRoot.id)
        let expandedRoot = try XCTUnwrap(workspace.rootNodes.first { $0.displayName.hasPrefix("TEST.BH") })
        let expandedSMNode = try XCTUnwrap(expandedRoot.children.first { $0.displayName == "\(entryName).sm2" })
        XCTAssertFalse(expandedSMNode.children.isEmpty, "sanity: the .sm2 node must be genuinely expanded (real children) before testing the reclick branch")

        // "Close the window", the only thing closing the Chunk Viewer
        // does to `workspace` state.
        workspace.levelViewerContext = nil

        // The actual fix under test: re-clicking this same, already-
        // expanded `.sm2` must resolve straight back to its real scenery
        // node, not `nil` (the pre-fix behavior that left the window
        // closed instead of reopening it).
        let expectedSceneryNode = try XCTUnwrap(findScenery(in: expandedSMNode))
        let reclickResult = WorkspaceViewModel.reclickedAlreadyExpandedLevelSceneryNode(expandedSMNode)
        XCTAssertTrue(reclickResult === expectedSceneryNode, "re-clicking the same already-expanded level must resolve to its real scenery node so the Level Viewer actually reopens")

        // And confirm the full, real, end-to-end effect: feeding that
        // result into `openLevelViewer` (exactly what `select`'s new
        // branch does) finds the sibling `.rm2`'s real Instance record,
        // not scenery only.
        guard case .scenery(let asset)? = reclickResult?.payload else {
            return XCTFail("unreachable, reclickedAlreadyExpandedLevelSceneryNode only ever returns a .scenery-payloaded node")
        }
        await workspace.openLevelViewer(for: asset, node: reclickResult!)
        let context = try XCTUnwrap(workspace.levelViewerContext)
        XCTAssertEqual(context.instanceMarkers.count, 1, "reopening via the reclick branch must still find the real Instance record")

        // A deep, unrelated child (an individual Instance record clicked to
        // inspect it, not the level's own file root) must never satisfy
        // this branch, the "don't yank focus back to the 3D viewer for an
        // inspection click" guarantee the original code already had.
        let unrelatedChild = expandedSMNode.children.first
        if let unrelatedChild {
            XCTAssertNil(WorkspaceViewModel.reclickedAlreadyExpandedLevelSceneryNode(unrelatedChild), "clicking an unrelated child inside an open chunk must not reopen the Level Viewer")
        }
    }
}
