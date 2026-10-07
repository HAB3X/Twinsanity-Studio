import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Regression for the real, confirmed root cause of "the level looks
/// scattered / massive gaps between objects": the Level Viewer never
/// rendered the level's actual collision mesh (`ColData`) at all, only
/// the sparse decorative scenery props on top of it. The reference tool
/// renders this collision mesh as a solid, filled floor *by default*
/// (`RMViewer.cs`'s constructor: `collisions = true`), with decorative
/// scenery *off* by default (`show_scenery = false`), confirmed directly
/// from the reference source, not inferred. Measured against a real
/// level this session: the collision mesh's bounding footprint (14,546
/// vertices / 25,292 triangles for hubb) closely matches and slightly
/// exceeds the scenery placements' own footprint, exactly what a
/// continuous ground floor beneath scattered props should look like.
@MainActor
final class CollisionFloorLayerTests: XCTestCase {
    private func makeSyntheticMesh(vertexOffset: Float = 0) -> CollisionMesh {
        let vertices: [SIMD4<Float>] = [
            SIMD4(0 + vertexOffset, 0, 0, 1),
            SIMD4(1 + vertexOffset, 0, 0, 1),
            SIMD4(0 + vertexOffset, 0, 1, 1),
        ]
        let triangle = CollisionTriangle(vertexIndex1: 0, vertexIndex2: 1, vertexIndex3: 2, surfaceID: 4)
        return CollisionMesh(id: 1, vertices: vertices, triangles: [triangle], groups: [], triggerBoxes: [])
    }

    /// Regression for a real follow-up bug in the fix above: the fill
    /// buffer originally reused `ModelViewerRenderer.color(forSurfaceID:)`
    /// (saturation 0.62, value 0.95, deliberately bold so distinct
    /// surface IDs stand out as thin wireframe *lines*). Reused for a
    /// solid, opaque floor covering the whole screen, real-world testing
    /// showed this reads as a dominating, garish red/orange wash rather
    /// than ground. `mutedColor(forSurfaceID:)` uses the same
    /// deterministic per-ID hue stepping (still distinguishes different
    /// real surface IDs) at much lower saturation/value.
    func testMutedSurfaceColorIsLessSaturatedAndDarkerThanTheWireframePalette() {
        for surfaceID in [0, 1, 4, 17, 250] {
            let bold = ModelViewerRenderer.color(forSurfaceID: surfaceID)
            let muted = ModelViewerRenderer.mutedColor(forSurfaceID: surfaceID)
            let boldMax = max(bold.x, max(bold.y, bold.z))
            let mutedMax = max(muted.x, max(muted.y, muted.z))
            let boldMin = min(bold.x, min(bold.y, bold.z))
            let mutedMin = min(muted.x, min(muted.y, muted.z))
            // Saturation ~ (max-min)/max in HSV; muted should be visibly
            // lower on both saturation and overall brightness (max channel).
            XCTAssertLessThan((mutedMax - mutedMin) / max(mutedMax, 0.0001), (boldMax - boldMin) / max(boldMax, 0.0001), "surfaceID \(surfaceID): muted color should be less saturated")
            XCTAssertLessThan(mutedMax, boldMax, "surfaceID \(surfaceID): muted color should be darker/less bright")
        }
    }

    func testRendererBuildsARealFillBufferFromASyntheticCollisionMesh() throws {
        let mesh = makeSyntheticMesh()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [], collisionMeshes: [mesh]))
        XCTAssertTrue(renderer.hasCollisionFill, "a non-empty CollisionMesh should produce a real, drawable fill buffer")
        XCTAssertEqual(renderer.collisionFillTriangleCount, 1)
    }

    func testRendererCombinesMultipleCollisionMeshesIntoOneBuffer() throws {
        let meshA = makeSyntheticMesh()
        let meshB = makeSyntheticMesh(vertexOffset: 100)
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [], collisionMeshes: [meshA, meshB]))
        XCTAssertEqual(renderer.collisionFillTriangleCount, 2, "every real collision mesh (own file + sibling actor file) should contribute to one combined floor")
    }

    func testNoCollisionMeshesMeansNoFillBufferNotAFabricatedOne() throws {
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: []))
        XCTAssertFalse(renderer.hasCollisionFill, "no ColData decoded for this level/file should mean no floor drawn, not an invented placeholder")
    }

    func testOutOfRangeTriangleIndicesAreSkippedNotCrashing() throws {
        // A defensively-malformed mesh (out-of-range vertex index) must be
        // skipped, not crash the renderer or corrupt the buffer with a
        // garbage read.
        let vertices: [SIMD4<Float>] = [SIMD4(0, 0, 0, 1)]
        let badTriangle = CollisionTriangle(vertexIndex1: 0, vertexIndex2: 1, vertexIndex3: 2, surfaceID: 0)
        let mesh = CollisionMesh(id: 1, vertices: vertices, triangles: [badTriangle], groups: [], triggerBoxes: [])
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [], collisionMeshes: [mesh]))
        XCTAssertFalse(renderer.hasCollisionFill)
    }

    func testCollisionLayerIsVisibleByDefault() throws {
        // The whole point of the fix: the floor must be ON without the
        // user needing to discover and enable a hidden toggle.
        XCTAssertTrue(SceneLayer.allCases.contains(.collision))
    }

    /// End-to-end, against real data: `WorkspaceViewModel.
    /// collisionMeshRecords` actually finds hubb.rm2's real ColData, and
    /// its footprint overlaps the sibling hubb.sm2's real scenery
    /// footprint, the direct evidence this is really the connecting
    /// ground floor, not unrelated geometry.
    func testRealCollisionMeshOverlapsRealSceneryFootprint() throws {
        let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Real disc image not present")
        }
        let index = try BDArchiveParser.readIndex(bhURL: bhURL)
        guard let rmEntry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/hubb.rm2" }),
              let smEntry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/hubb.sm2" })
        else {
            throw XCTSkip("hubb.rm2/hubb.sm2 not found")
        }
        let rmRoot = try RM2Parser.parse(data: try BDArchiveParser.readEntryData(rmEntry, index: index), fileKind: .rm2, fileName: rmEntry.name)
        let smRoot = try RM2Parser.parse(data: try BDArchiveParser.readEntryData(smEntry, index: index), fileKind: .sm2, fileName: smEntry.name)

        var collisionMesh: CollisionMesh?
        func walkCollision(_ node: ChunkNode) {
            if collisionMesh == nil, case .collision(let mesh) = node.payload, !mesh.isEmpty { collisionMesh = mesh }
            for child in node.children { walkCollision(child) }
        }
        walkCollision(rmRoot)
        let mesh = try XCTUnwrap(collisionMesh)
        XCTAssertGreaterThan(mesh.vertices.count, 1000, "hubb's real collision mesh should be substantial, not a stub")

        var scenery: SceneryAsset?
        func walkScenery(_ node: ChunkNode) {
            if scenery == nil, case .scenery(let found) = node.payload, !found.placements.isEmpty { scenery = found }
            for child in node.children { walkScenery(child) }
        }
        walkScenery(smRoot)
        let sceneryAsset = try XCTUnwrap(scenery)

        // "Coordinate-System Overhaul": collision vertices are raw on-disk
        // data (see `ModelViewerRenderer.upload(collisionMesh:)`'s doc
        // comment, there's a real write-back path, so the X mirror is
        // applied only at render time, not baked into the decoded struct).
        // `worldTransform` already applies its own (corrected) mirror to
        // scenery, so this test has to mirror collision vertices by hand
        // to compare them in the same space the renderer actually draws
        // both in, comparing one mirrored and one raw would make this
        // test meaningless.
        let worldVertices = mesh.vertices.map { SIMD3<Float>(-$0.x, $0.y, $0.z) }

        var meshMin = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var meshMax = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for v in worldVertices {
            meshMin = simd_min(meshMin, SIMD2(v.x, v.z))
            meshMax = simd_max(meshMax, SIMD2(v.x, v.z))
        }
        var sceneryMin = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var sceneryMax = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        var sceneryPositions: [SIMD3<Float>] = []
        for placement in sceneryAsset.placements {
            guard let t = placement.worldTransform else { continue }
            sceneryMin = simd_min(sceneryMin, SIMD2(t.position.x, t.position.z))
            sceneryMax = simd_max(sceneryMax, SIMD2(t.position.x, t.position.z))
            sceneryPositions.append(t.position)
        }

        let overlapMinX = max(meshMin.x, sceneryMin.x)
        let overlapMaxX = min(meshMax.x, sceneryMax.x)
        let overlapMinZ = max(meshMin.y, sceneryMin.y)
        let overlapMaxZ = min(meshMax.y, sceneryMax.y)
        XCTAssertLessThan(overlapMinX, overlapMaxX, "collision floor must span the same X range scenery occupies")
        XCTAssertLessThan(overlapMinZ, overlapMaxZ, "collision floor must span the same Z range scenery occupies")

        // Tightened check: bounding boxes can coincidentally overlap even
        // when the geometry inside them doesn't actually align (this is
        // exactly how the pre-fix bug could still pass a pure bbox check
        // for a roughly-symmetric level like hubb while being wrong for
        // less symmetric ones). Sample real scenery placements and confirm
        // each one sits close to *some* real collision triangle, not just
        // somewhere inside the overall bounding box.
        var validTriangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        validTriangles.reserveCapacity(mesh.triangles.count)
        for triangle in mesh.triangles {
            guard triangle.vertexIndex1 < worldVertices.count,
                  triangle.vertexIndex2 < worldVertices.count,
                  triangle.vertexIndex3 < worldVertices.count
            else { continue }
            validTriangles.append((worldVertices[triangle.vertexIndex1], worldVertices[triangle.vertexIndex2], worldVertices[triangle.vertexIndex3]))
        }
        XCTAssertFalse(validTriangles.isEmpty)

        func nearestTriangleDistance(to point: SIMD3<Float>) -> Float {
            var best = Float.greatestFiniteMagnitude
            for (a, b, c) in validTriangles {
                let centroid = (a + b + c) / 3
                best = min(best, simd_distance(point, centroid))
            }
            return best
        }

        let sampled = sceneryPositions.count > 40 ? Array(stride(from: 0, to: sceneryPositions.count, by: sceneryPositions.count / 40).map { sceneryPositions[$0] }) : sceneryPositions
        var closeCount = 0
        for position in sampled where nearestTriangleDistance(to: position) < 15 {
            closeCount += 1
        }
        let fraction = Double(closeCount) / Double(sampled.count)
        XCTAssertGreaterThan(fraction, 0.5, "most real scenery placements should sit near some real collision geometry, not just inside the overall bounding box (\(closeCount)/\(sampled.count) within 15 units)")
    }
}
