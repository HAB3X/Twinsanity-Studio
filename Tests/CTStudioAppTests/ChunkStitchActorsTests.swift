import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// "Chunk Stitching Rendering Bug": real investigation found stitching a
/// linked chunk only ever gathered that neighbor's `SceneryData`
/// placements, its own `Instance`/`Trigger`/`Camera`/`AIPosition` records
/// (living in the neighbor's sibling `.rm2`, exactly like the *primary*
/// chunk's own actor data) were never loaded at all. This is what a user
/// stitching a chunk actually experiences as "only objects render, not
/// terrain", inverted: what they see post-stitch is the *primary*
/// chunk's own pre-existing objects, since the neighbor's own never
/// arrive. `WorkspaceViewModel.loadChunkLinkActors` +
/// `LevelViewerRenderer.stitchChunkActors` are the fix.
@MainActor
final class ChunkStitchActorsTests: XCTestCase {
    private static let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")

    /// A real, diverse sample of chunk links across the archive, the
    /// same "don't trust one coincidentally-fine level" discipline
    /// `CoordinateSystemRegressionTests` already established for this
    /// area of the codebase.
    func testRealChunkLinksLoadNeighborActorsNotJustScenery() async throws {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Real disc image not present")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)

        let workspace = WorkspaceViewModel()
        workspace.open(url: Self.bhURL)
        for _ in 0..<50 {
            if !workspace.rootNodes.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(workspace.rootNodes.isEmpty, "BH archive never loaded root nodes")

        var checked = 0
        var withActors = 0
        for entry in index.entries where entry.name.lowercased().hasSuffix(".sm2") {
            guard withActors < 5, checked < 400 else { break }
            checked += 1
            guard let data = try? BDArchiveParser.readEntryData(entry, index: index),
                  let root = try? RM2Parser.parse(data: data, fileKind: .sm2, fileName: entry.name)
            else { continue }

            var chunkLinks: ChunkLinksAsset?
            func walk(_ node: ChunkNode) {
                if chunkLinks == nil, case .chunkLinks(let found) = node.payload, !found.links.isEmpty { chunkLinks = found }
                for child in node.children { walk(child) }
            }
            walk(root)
            guard let chunkLinks, let link = chunkLinks.links.first(where: { !$0.path.isEmpty }) else { continue }

            guard let actors = await workspace.loadChunkLinkActors(for: link) else { continue }
            let totalActors = actors.instanceMarkers.count + actors.triggers.count + actors.cameras.count + actors.aiPositions.count
            guard totalActors > 0 else { continue }
            withActors += 1

            // Every resolved instance should carry real, non-empty geometry.
            for resolved in actors.resolvedInstanceAssets.values {
                XCTAssertFalse(resolved.mesh.submeshes.isEmpty, "resolved instance asset has zero submeshes")
            }

            let emptyPlacements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)] = []
            guard let renderer = LevelViewerRenderer(placements: emptyPlacements) else {
                XCTFail("LevelViewerRenderer failed to construct (no Metal device on this machine?)")
                continue
            }
            let added = renderer.stitchChunkActors(
                instanceMarkers: actors.instanceMarkers,
                resolvedInstanceAssets: actors.resolvedInstanceAssets,
                triggers: actors.triggers,
                cameras: actors.cameras,
                aiPositions: actors.aiPositions,
                worldOffset: .zero
            )
            XCTAssertGreaterThan(added, 0, "real actor records existed for \(entry.name) -> \(link.path) but stitchChunkActors added none")
        }
        XCTAssertGreaterThan(withActors, 0, "No real chunk link with neighbor actor data found in the sampled window")
    }
}
