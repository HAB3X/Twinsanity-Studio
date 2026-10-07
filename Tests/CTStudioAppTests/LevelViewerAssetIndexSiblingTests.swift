import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Regression test for a real, previously-silent bug: `LevelViewerContext.
/// assetIndex` (what the Forge Palette and already-placed Instance markers
/// resolve `GameObject`/`Instance.objectID` through) was built from the
/// *scenery* node's own file root, always the `.sm2` side, since
/// `openLevelViewer` is "always entered from the scenery side", but real
/// `GameObject` records structurally live in the sibling `.rm2` actor file
/// (`hubb.sm2` carries zero of its own, `hubb.rm2` carries 32, confirmed
/// against the real archive). Every level's own objects were invisible to
/// this resolver; only the shared `Default.rm2` fallback ever worked,
/// which is why most Forge Palette entries, and even some already-placed
/// actors, fell back to an amber placeholder cube instead of real
/// geometry. Skips gracefully when the local disc image isn't present.
@MainActor
final class LevelViewerAssetIndexSiblingTests: XCTestCase {
    func testAssetIndexIncludesSiblingActorFilesGameObjects() async throws {
        let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Real disc image not present at the expected local path")
        }

        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)

        guard let archiveRoot = workspace.rootNodes.first,
              let smEntry = archiveRoot.children.first(where: { $0.displayName.lowercased() == "levels/earth/hub/hubb.sm2" }),
              let rmEntry = archiveRoot.children.first(where: { $0.displayName.lowercased() == "levels/earth/hub/hubb.rm2" })
        else {
            return XCTFail("couldn't find hubb.sm2/hubb.rm2 in the archive tree")
        }

        // Real users reach the Level Viewer after the background auto-scan
        // (`scanAllArchives`, started automatically by `open(url:)`) has
        // already expanded every archive entry, including the sibling
        // actor file `siblingActorFileRoot` needs to already exist as a
        // real parsed tree (it only recognizes an *already-expanded*
        // sibling; it won't discover a still-unexpanded one on its own).
        // Expanding both directly here exercises the same real code path
        // without paying for the full ~697-entry scan in a unit test.
        await workspace.expandArchiveEntry(smEntry, rootID: archiveRoot.id)
        await workspace.expandArchiveEntry(rmEntry, rootID: archiveRoot.id)

        guard let expandedRoot = workspace.rootNodes.first,
              let expandedEntry = expandedRoot.children.first(where: { $0.displayName.lowercased() == "levels/earth/hub/hubb.sm2" })
        else {
            return XCTFail("hubb.sm2 vanished after expansion")
        }

        var sceneryNode: ChunkNode?
        func walk(_ node: ChunkNode) {
            if sceneryNode == nil, case .scenery(let asset) = node.payload, !asset.placements.isEmpty { sceneryNode = node }
            for child in node.children { walk(child) }
        }
        walk(expandedEntry)

        guard let sceneryNode, case .scenery(let sceneryAsset) = sceneryNode.payload else {
            return XCTFail("couldn't find a real scenery leaf inside expanded hubb.sm2")
        }

        await workspace.openLevelViewer(for: sceneryAsset, node: sceneryNode)

        let context = try XCTUnwrap(workspace.levelViewerContext, "openLevelViewer should have populated levelViewerContext")
        XCTAssertGreaterThan(context.assetIndex.gameObjects.count, 0, "assetIndex should include the sibling hubb.rm2's real GameObject records, not just an empty scenery-file index")
    }
}
