import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// The strongest real-data check yet for `SceneryModelPlacement.worldTransform`'s
/// rotation correctness. Every other regression in this area
/// (`SceneryModelPlacementTransformTests`, `CoordinateSystemRegressionTests`)
/// checks a placement's *position* only, a placement's origin point can sit
/// in exactly the right spot while its mesh is still oriented wrong, which
/// would show up visually as "pieces don't connect at their edges" without
/// tripping a position-only check.
///
/// This finds real, structural (not decorative-clutter) tile pairs in
/// `beach.sm2`, the same model reused at grid-spaced positions with a
/// genuinely different (90°) rotation between two neighbors, resolves their
/// *actual mesh geometry*, transforms every vertex through the real
/// placement transform, and checks the two meshes' nearest vertices land
/// within floating-point noise of each other, not a multi-unit gap. A wrong
/// rotation formula (even one that reproduces the reference tool's matrix
/// bit-for-bit in isolation but has a sign/handedness error) would show up
/// here as a real, multi-unit gap or overlap, the same class of check that
/// caught the original "transpose" bug, just applied to orientation instead
/// of position.
@MainActor
final class AdjacentTileRotationAlignmentTests: XCTestCase {
    func testNinetyDegreeRotatedAdjacentFloorTilesConnectEdgeToEdge() throws {
        let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Real disc image not present")
        }
        let index = try BDArchiveParser.readIndex(bhURL: bhURL)
        guard let smEntry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/beach.sm2" }) else {
            throw XCTSkip("beach.sm2 not found")
        }
        let smRoot = try RM2Parser.parse(data: try BDArchiveParser.readEntryData(smEntry, index: index), fileKind: .sm2, fileName: smEntry.name)

        var scenery: SceneryAsset?
        func walk(_ node: ChunkNode) {
            if scenery == nil, case .scenery(let found) = node.payload, !found.placements.isEmpty { scenery = found }
            for child in node.children { walk(child) }
        }
        walk(smRoot)
        let sceneryAsset = try XCTUnwrap(scenery)

        // Real, verified-against-the-archive case: modelID 2688020295 is a
        // flat 16x16 floor-tile mesh appearing many times across the level;
        // two of its placements sit at (-68.80005, -1.5, 8.0) and
        // (-68.80005, -1.5, -8.0), exactly one tile-width (16.0) apart , 
        // with a real, decoded 90° rotation difference between them.
        let targetModelID: UInt32 = 2688020295
        let matches = sceneryAsset.placements
            .filter { $0.modelID == targetModelID }
            .compactMap { p -> (SceneryModelPlacement, position: SIMD3<Float>, rotation: simd_quatf)? in
                guard let t = p.worldTransform else { return nil }
                return (p, t.position, t.rotation)
            }
        let a = try XCTUnwrap(matches.first { simd_distance($0.position, SIMD3(-68.80005, -1.5, 8.0)) < 0.01 })
        let b = try XCTUnwrap(matches.first { simd_distance($0.position, SIMD3(-68.80005, -1.5, -8.0)) < 0.01 })

        let angleDiffDegrees = acos(max(-1, min(1, simd_dot(a.rotation.act(SIMD3<Float>(1, 0, 0)), b.rotation.act(SIMD3<Float>(1, 0, 0)))))) * 180 / .pi
        XCTAssertEqual(angleDiffDegrees, 90, accuracy: 0.01, "precondition: this real pair should have a genuine 90° rotation difference, not a trivial one")

        let assetIndex = AssetResolver.buildIndex(fileRoot: smRoot)
        let resolvedA = try XCTUnwrap(AssetResolver.resolveModelID(a.0.modelID, displayName: "A", index: assetIndex))
        let resolvedB = try XCTUnwrap(AssetResolver.resolveModelID(b.0.modelID, displayName: "B", index: assetIndex))

        func worldVertices(_ resolved: ResolvedModelAsset, _ position: SIMD3<Float>, _ rotation: simd_quatf) -> [SIMD3<Float>] {
            resolved.mesh.submeshes.flatMap { submesh in
                submesh.vertices.map { rotation.act($0.position) + position }
            }
        }
        let vertsA = worldVertices(resolvedA, a.position, a.rotation)
        let vertsB = worldVertices(resolvedB, b.position, b.rotation)
        XCTAssertFalse(vertsA.isEmpty)
        XCTAssertFalse(vertsB.isEmpty)

        var minGap = Float.greatestFiniteMagnitude
        for va in vertsA {
            for vb in vertsB {
                minGap = min(minGap, simd_distance(va, vb))
            }
        }
        XCTAssertLessThan(minGap, 0.01, "a real 90°-rotated adjacent floor tile pair should connect edge-to-edge (near-zero gap), not leave a visible seam, got a \(minGap)-unit gap")
    }
}
