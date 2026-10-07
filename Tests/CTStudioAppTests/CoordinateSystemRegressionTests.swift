import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Broad, real-data regression for the "Coordinate-System Overhaul", the
/// session-long chain of fixes correcting `SceneryModelPlacement.
/// worldTransform`'s formula and adding the matching world-space X mirror
/// to collision/instance/trigger/camera/AI-waypoint/chunk-link-wall
/// positions, all reverse-engineered directly from the reference tool's
/// `SMViewer.cs`/`RMViewer.cs`. Earlier regressions in this area
/// (`CollisionFloorLayerTests.testRealCollisionMeshOverlapsRealSceneryFootprint`)
/// only checked one level (`hubb`), this sweeps a real, diverse sample
/// across the archive, since the whole reason this bug went unnoticed for
/// a while is that `hubb` happens to look fine by coincidence (its
/// geometry is close to X-symmetric) while smaller/less symmetric levels
/// don't.
@MainActor
final class CoordinateSystemRegressionTests: XCTestCase {
    private static let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")

    /// A deliberately diverse sample, different top-level areas, mixing
    /// large hub levels with small transitional/cutscene chunks like
    /// `cavent` (the exact level the user reported as still broken).
    private static let sampleBaseNames = [
        "Levels/Earth/Hub/hubb",
        "Levels/Earth/Hub/beach",
        "Levels/Earth/Cavern/cavent",
        "Levels/Earth/Cavern/tunnel01",
        "Levels/Earth/Cavern/tunnel02",
        "Levels/Earth/Cavern/cryscave",
        "Levels/Earth/Cavern/nitrocav",
        "Levels/Earth/Cavern/cavbridg",
        "Levels/Earth/Cavern/antfight",
        "Levels/AltEarth/Hub/alttunl",
    ]

    func testSceneryPlacementsSitNearRealCollisionGeometryAcrossADiverseSample() throws {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Real disc image not present")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)

        var totalSampled = 0
        var totalClose = 0
        var checkedLevels = 0
        var results: [String] = []

        for baseName in Self.sampleBaseNames {
            guard let smEntry = index.entries.first(where: { $0.name == "\(baseName).sm2" }),
                  let rmEntry = index.entries.first(where: { $0.name == "\(baseName).rm2" })
            else { continue }

            let smRoot = try RM2Parser.parse(data: try BDArchiveParser.readEntryData(smEntry, index: index), fileKind: .sm2, fileName: smEntry.name)
            let rmRoot = try RM2Parser.parse(data: try BDArchiveParser.readEntryData(rmEntry, index: index), fileKind: .rm2, fileName: rmEntry.name)

            var scenery: SceneryAsset?
            func walkScenery(_ node: ChunkNode) {
                if scenery == nil, case .scenery(let found) = node.payload, !found.placements.isEmpty { scenery = found }
                for child in node.children { walkScenery(child) }
            }
            walkScenery(smRoot)

            var collisionMesh: CollisionMesh?
            func walkCollision(_ node: ChunkNode) {
                if collisionMesh == nil, case .collision(let mesh) = node.payload, !mesh.isEmpty { collisionMesh = mesh }
                for child in node.children { walkCollision(child) }
            }
            walkCollision(rmRoot)

            guard let scenery, let collisionMesh else { continue }

            let worldVertices = collisionMesh.vertices.map { SIMD3<Float>(-$0.x, $0.y, $0.z) }
            var validTriangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
            for triangle in collisionMesh.triangles {
                guard triangle.vertexIndex1 < worldVertices.count,
                      triangle.vertexIndex2 < worldVertices.count,
                      triangle.vertexIndex3 < worldVertices.count
                else { continue }
                validTriangles.append((worldVertices[triangle.vertexIndex1], worldVertices[triangle.vertexIndex2], worldVertices[triangle.vertexIndex3]))
            }
            guard !validTriangles.isEmpty else { continue }

            func nearestTriangleDistance(to point: SIMD3<Float>) -> Float {
                var best = Float.greatestFiniteMagnitude
                for (a, b, c) in validTriangles {
                    let centroid = (a + b + c) / 3
                    best = min(best, simd_distance(point, centroid))
                }
                return best
            }

            let positions = scenery.placements.compactMap { $0.worldTransform?.position }
            guard !positions.isEmpty else { continue }
            let sampled = positions.count > 30 ? Array(stride(from: 0, to: positions.count, by: max(positions.count / 30, 1)).map { positions[$0] }) : positions

            var closeCount = 0
            for position in sampled where nearestTriangleDistance(to: position) < 20 {
                closeCount += 1
            }
            checkedLevels += 1
            totalSampled += sampled.count
            totalClose += closeCount
            results.append("\(baseName): \(closeCount)/\(sampled.count) scenery placements within 20 units of real collision geometry")
        }

        guard checkedLevels > 0 else {
            throw XCTSkip("None of the sampled levels were found in this archive")
        }
        XCTAssertGreaterThanOrEqual(checkedLevels, 4, "expected at least a handful of the sampled levels to actually exist in the archive, got \(checkedLevels)")

        let overallFraction = Double(totalClose) / Double(max(totalSampled, 1))
        let report = results.joined(separator: "\n")
        XCTAssertGreaterThan(overallFraction, 0.6, "scenery should sit near real collision geometry across a diverse sample of levels, not just the one (hubb) that happens to be X-symmetric:\n\(report)")
    }
}
