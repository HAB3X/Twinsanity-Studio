import XCTest
import simd
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// Regression coverage for "Auto-Update Collision on Add/Delete"'s manual
/// rebuild tool (`LevelCollisionRebuilder`), the real, reported bug is
/// that a newly-placed object has no collision in `ColData` at all, so
/// Crash falls straight through it in real PCSX2. Verifies the rebuilder
/// (a) never touches the original mesh's own real data, and (b) produces
/// bytes that round-trip cleanly back through the real parser, the same
/// "prove the writer and parser agree, not just that the writer runs"
/// discipline this codebase already applies to every other writer.
final class LevelCollisionRebuilderTests: XCTestCase {
    /// A minimal, real, decodable baseline mesh: one ground quad (2
    /// triangles sharing 4 vertices), one group covering both, no trigger
    /// boxes of its own (empty groups list would be atypical for a real
    /// level, but the rebuilder must still handle it) -- surfaceID 42 on
    /// every original triangle, so "did the rebuilder touch this" is easy
    /// to check by surfaceID alone.
    private func makeBaselineMesh() -> CollisionMesh {
        let vertices: [SIMD4<Float>] = [
            SIMD4(-10, 0, -10, 1), SIMD4(10, 0, -10, 1),
            SIMD4(10, 0, 10, 1), SIMD4(-10, 0, 10, 1),
        ]
        let triangles = [
            CollisionTriangle(vertexIndex1: 0, vertexIndex2: 1, vertexIndex3: 2, surfaceID: 42),
            CollisionTriangle(vertexIndex1: 0, vertexIndex2: 2, vertexIndex3: 3, surfaceID: 42),
        ]
        let groups = [CollisionGroup(size: 2, offset: 0)]
        let triggerBoxes = CollisionOBJImporter.buildTriggerTree(groups: groups, triangles: triangles, vertices: vertices)
        return CollisionMesh(id: 1, vertices: vertices, triangles: triangles, groups: groups, triggerBoxes: triggerBoxes)
    }

    func testReturnsBaselineUnchangedWhenNoBoxesGiven() {
        let baseline = makeBaselineMesh()
        let result = LevelCollisionRebuilder.rebuilding(baseline, addingBoxes: [], surfaceID: 99)
        XCTAssertEqual(result.vertices.count, baseline.vertices.count)
        XCTAssertEqual(result.triangles.count, baseline.triangles.count)
        XCTAssertEqual(result.groups.count, baseline.groups.count)
    }

    func testAppendingOneBoxPreservesOriginalGeometryAndAddsANewGroup() {
        let baseline = makeBaselineMesh()
        let box = LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(1, 1, 1), worldMax: SIMD3(2, 3, 4))
        let result = LevelCollisionRebuilder.rebuilding(baseline, addingBoxes: [box], surfaceID: 7)

        // Original vertices/triangles untouched, at their original indices,
        // with their real surfaceID preserved exactly.
        for (a, b) in zip(result.vertices.prefix(4), baseline.vertices) {
            XCTAssertEqual(a, b)
        }
        for (a, b) in zip(result.triangles.prefix(2), baseline.triangles) {
            XCTAssertEqual(a.vertexIndex1, b.vertexIndex1)
            XCTAssertEqual(a.vertexIndex2, b.vertexIndex2)
            XCTAssertEqual(a.vertexIndex3, b.vertexIndex3)
            XCTAssertEqual(a.surfaceID, b.surfaceID)
        }
        for original in result.triangles.prefix(2) {
            XCTAssertEqual(original.surfaceID, 42)
        }

        // 8 new corner vertices appended.
        XCTAssertEqual(result.vertices.count, baseline.vertices.count + 8)

        // The new box's own triangles all carry the requested surfaceID
        // and only reference the newly appended vertices (index >= 4).
        let newTriangles = result.triangles.dropFirst(baseline.triangles.count)
        XCTAssertFalse(newTriangles.isEmpty)
        for triangle in newTriangles {
            XCTAssertEqual(triangle.surfaceID, 7)
            XCTAssertGreaterThanOrEqual(triangle.vertexIndex1, 4)
            XCTAssertGreaterThanOrEqual(triangle.vertexIndex2, 4)
            XCTAssertGreaterThanOrEqual(triangle.vertexIndex3, 4)
        }

        // One new group for the box, on top of the original.
        XCTAssertEqual(result.groups.count, baseline.groups.count + 1)

        // The new box's real vertices actually span its requested world
        // min/max, not some other, wrong box.
        let newVertices = result.vertices.suffix(8)
        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in newVertices {
            let p = SIMD3(v.x, v.y, v.z)
            minP = simd_min(minP, p); maxP = simd_max(maxP, p)
        }
        XCTAssertEqual(minP, box.worldMin)
        XCTAssertEqual(maxP, box.worldMax)

        // A real trigger tree was rebuilt covering every group (leaves ==
        // groups for a 2-group tree: one branch + two leaves == 3 nodes).
        XCTAssertEqual(result.triggerBoxes.count, 3)
    }

    func testMultipleBoxesEachGetTheirOwnGroup() {
        let baseline = makeBaselineMesh()
        let boxes = [
            LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(0, 0, 0), worldMax: SIMD3(1, 1, 1)),
            LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(5, 5, 5), worldMax: SIMD3(6, 6, 6)),
        ]
        let result = LevelCollisionRebuilder.rebuilding(baseline, addingBoxes: boxes, surfaceID: 0)
        XCTAssertEqual(result.groups.count, baseline.groups.count + 2)
        XCTAssertEqual(result.vertices.count, baseline.vertices.count + 16)
    }

    /// The real, must-hold property: bytes the rebuilder's output encodes
    /// to must decode back through the *actual* parser into the same real
    /// data, not just "the writer didn't crash."
    func testRebuiltMeshRoundTripsThroughTheRealWriterAndParser() throws {
        let baseline = makeBaselineMesh()
        let box = LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(-1, -1, -1), worldMax: SIMD3(1, 1, 1))
        let rebuilt = LevelCollisionRebuilder.rebuilding(baseline, addingBoxes: [box], surfaceID: 3)

        let encoded = ColDataWriter.write(rebuilt)
        var cursor = BinaryCursor(data: encoded)
        let decoded = try ColDataParser.parse(&cursor, recordID: rebuilt.id, size: encoded.count)

        XCTAssertEqual(decoded.vertices.count, rebuilt.vertices.count)
        XCTAssertEqual(decoded.triangles.count, rebuilt.triangles.count)
        XCTAssertEqual(decoded.groups.count, rebuilt.groups.count)
        XCTAssertEqual(decoded.triggerBoxes.count, rebuilt.triggerBoxes.count)
        for (a, b) in zip(decoded.vertices, rebuilt.vertices) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.001)
            XCTAssertEqual(a.z, b.z, accuracy: 0.001)
        }
        for (a, b) in zip(decoded.triangles, rebuilt.triangles) {
            XCTAssertEqual(a.vertexIndex1, b.vertexIndex1)
            XCTAssertEqual(a.vertexIndex2, b.vertexIndex2)
            XCTAssertEqual(a.vertexIndex3, b.vertexIndex3)
            XCTAssertEqual(a.surfaceID, b.surfaceID)
        }
        XCTAssertEqual(cursor.position, encoded.count)
    }

    /// A degenerate box (max < min on some axis, e.g. from a malformed
    /// caller) must be skipped rather than corrupt the mesh with a
    /// zero/negative-extent box.
    func testDegenerateBoxIsSkipped() {
        let baseline = makeBaselineMesh()
        let degenerate = LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(5, 5, 5), worldMax: SIMD3(1, 1, 1))
        let result = LevelCollisionRebuilder.rebuilding(baseline, addingBoxes: [degenerate], surfaceID: 0)
        XCTAssertEqual(result.vertices.count, baseline.vertices.count)
        XCTAssertEqual(result.triangles.count, baseline.triangles.count)
        XCTAssertEqual(result.groups.count, baseline.groups.count)
    }

    // MARK: - Ghost Collision Removal

    /// Two distinct, far-apart groups: one near the origin ("the object
    /// about to be deleted"), one far away ("unrelated collision that must
    /// survive"). Real, decodable, independently buildable trigger tree.
    private func makeTwoGroupMesh() -> CollisionMesh {
        let vertices: [SIMD4<Float>] = [
            // Group 0: a small triangle clustered right at the origin.
            SIMD4(-1, 0, -1, 1), SIMD4(1, 0, -1, 1), SIMD4(0, 0, 1, 1),
            // Group 1: a small triangle far away, near (100, 0, 100).
            SIMD4(99, 0, 99, 1), SIMD4(101, 0, 99, 1), SIMD4(100, 0, 101, 1),
        ]
        let triangles = [
            CollisionTriangle(vertexIndex1: 0, vertexIndex2: 1, vertexIndex3: 2, surfaceID: 42),
            CollisionTriangle(vertexIndex1: 3, vertexIndex2: 4, vertexIndex3: 5, surfaceID: 42),
        ]
        let groups = [
            CollisionGroup(size: 1, offset: 0),
            CollisionGroup(size: 1, offset: 1),
        ]
        let triggerBoxes = CollisionOBJImporter.buildTriggerTree(groups: groups, triangles: triangles, vertices: vertices)
        return CollisionMesh(id: 1, vertices: vertices, triangles: triangles, groups: groups, triggerBoxes: triggerBoxes)
    }

    func testRemovingGroupsNearDropsOnlyTheMatchingGroup() {
        let mesh = makeTwoGroupMesh()
        let removal = LevelCollisionRebuilder.RemovalBox(worldMin: SIMD3(-2, -2, -2), worldMax: SIMD3(2, 2, 2))
        let (result, removedCount) = LevelCollisionRebuilder.removingGroupsNear(mesh, boxes: [removal])

        XCTAssertEqual(removedCount, 1)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.triangles.count, 1)
        // The surviving triangle must be the far-away one, not the origin one.
        let survivor = result.vertices[result.triangles[0].vertexIndex1]
        XCTAssertGreaterThan(survivor.x, 50, "the group near the origin must be the one removed, not the far one")
        // A real trigger tree still covers exactly the surviving group.
        XCTAssertEqual(result.triggerBoxes.count, 1)
    }

    func testRemovingGroupsNearWithNoMatchingBoxesLeavesMeshUnchanged() {
        let mesh = makeTwoGroupMesh()
        let farRemoval = LevelCollisionRebuilder.RemovalBox(worldMin: SIMD3(500, 500, 500), worldMax: SIMD3(501, 501, 501))
        let (result, removedCount) = LevelCollisionRebuilder.removingGroupsNear(mesh, boxes: [farRemoval])
        XCTAssertEqual(removedCount, 0)
        XCTAssertEqual(result.groups.count, mesh.groups.count)
        XCTAssertEqual(result.triangles.count, mesh.triangles.count)
    }

    func testRemovingGroupsNearWithEmptyBoxesIsANoOp() {
        let mesh = makeTwoGroupMesh()
        let (result, removedCount) = LevelCollisionRebuilder.removingGroupsNear(mesh, boxes: [])
        XCTAssertEqual(removedCount, 0)
        XCTAssertEqual(result.groups.count, mesh.groups.count)
    }

    /// Real, reported bug: "Update Collision for Moved Objects" made a
    /// player fall through the entire level floor. A level's whole Ground
    /// Floor is commonly authored as *one* large connected `CollisionGroup`
    /// (see the Scene Layers panel's own "Collision / Ground Floor (1)"
    /// count), its one real centroid can land inside a small removal box
    /// for a moved prop sitting anywhere near the middle of that floor's
    /// own extent, even though the group is nothing like that prop's own
    /// size. Centroid-inside-box alone can't tell "this group is the moved
    /// object" from "this enormous group's centroid happens to fall here";
    /// this is the regression test for the size-comparison guard that now
    /// makes that distinction.
    private func makeFloorPlusSmallPropMesh() -> CollisionMesh {
        let vertices: [SIMD4<Float>] = [
            // Group 0: a huge floor quad, -50..50 on X and Z, its own
            // centroid sits exactly at the world origin.
            SIMD4(-50, 0, -50, 1), SIMD4(50, 0, -50, 1),
            SIMD4(50, 0, 50, 1), SIMD4(-50, 0, 50, 1),
            // Group 1: a small prop's own collision triangle, also near the
            // origin, genuinely the thing that should be removed.
            SIMD4(-0.5, 1, -0.5, 1), SIMD4(0.5, 1, -0.5, 1), SIMD4(0, 1, 0.5, 1),
        ]
        let triangles = [
            CollisionTriangle(vertexIndex1: 0, vertexIndex2: 1, vertexIndex3: 2, surfaceID: 42),
            CollisionTriangle(vertexIndex1: 0, vertexIndex2: 2, vertexIndex3: 3, surfaceID: 42),
            CollisionTriangle(vertexIndex1: 4, vertexIndex2: 5, vertexIndex3: 6, surfaceID: 42),
        ]
        let groups = [
            CollisionGroup(size: 2, offset: 0),
            CollisionGroup(size: 1, offset: 2),
        ]
        let triggerBoxes = CollisionOBJImporter.buildTriggerTree(groups: groups, triangles: triangles, vertices: vertices)
        return CollisionMesh(id: 1, vertices: vertices, triangles: triangles, groups: groups, triggerBoxes: triggerBoxes)
    }

    func testRemovingGroupsNearNeverDropsAGroupMuchLargerThanTheRemovalBox() {
        let mesh = makeFloorPlusSmallPropMesh()
        // A small removal box for the moved/deleted prop, comfortably
        // contains group 1's own extent, and (this is the point) also
        // contains the floor group's centroid (the origin), even though
        // the floor itself extends far outside this box.
        let removal = LevelCollisionRebuilder.RemovalBox(worldMin: SIMD3(-1, 0, -1), worldMax: SIMD3(1, 2, 1))
        let (result, removedCount) = LevelCollisionRebuilder.removingGroupsNear(mesh, boxes: [removal])

        XCTAssertEqual(removedCount, 1, "only the small prop's group should be removed")
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.triangles.count, 2, "the floor's own 2 triangles must survive")
        // The surviving triangles must be the floor's, not the prop's.
        for triangle in result.triangles {
            let v = result.vertices[triangle.vertexIndex1]
            XCTAssertEqual(v.y, 0, "the surviving geometry must be the floor (y=0), not the removed prop (y=1)")
        }
    }

    /// The real, must-hold property for the removal half too: what
    /// survives must still round-trip cleanly through the real writer and
    /// parser.
    func testRemovalResultRoundTripsThroughTheRealWriterAndParser() throws {
        let mesh = makeTwoGroupMesh()
        let removal = LevelCollisionRebuilder.RemovalBox(worldMin: SIMD3(-2, -2, -2), worldMax: SIMD3(2, 2, 2))
        let (result, removedCount) = LevelCollisionRebuilder.removingGroupsNear(mesh, boxes: [removal])
        XCTAssertEqual(removedCount, 1)

        let encoded = ColDataWriter.write(result)
        var cursor = BinaryCursor(data: encoded)
        let decoded = try ColDataParser.parse(&cursor, recordID: result.id, size: encoded.count)

        XCTAssertEqual(decoded.triangles.count, result.triangles.count)
        XCTAssertEqual(decoded.groups.count, result.groups.count)
        XCTAssertEqual(cursor.position, encoded.count)
    }

    // MARK: - "Rebuild All Collision" (destroy-and-rebuild-from-scratch)

    /// The defining, must-hold difference from `rebuilding`: this destroys
    /// the baseline's own real geometry entirely rather than preserving it
    ///, a "Rebuild All Collision" that left the old, possibly-stale mesh
    /// underneath the fresh boxes would defeat the whole point of asking
    /// for a from-scratch rebuild.
    func testRebuildingFromScratchDiscardsAllOfTheBaselinesOwnGeometry() {
        let baseline = makeBaselineMesh()
        let box = LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(1, 1, 1), worldMax: SIMD3(2, 3, 4))
        let result = LevelCollisionRebuilder.rebuildingFromScratch(preservingIDFrom: baseline, addingBoxes: [box], surfaceID: 7)

        // None of the baseline's own real vertices survive.
        for baselineVertex in baseline.vertices {
            XCTAssertFalse(result.vertices.contains(baselineVertex), "the baseline's own real geometry must not survive a from-scratch rebuild")
        }
        // Every triangle carries the new box's surfaceID, none of the
        // baseline's own surfaceID (42) leaked through.
        XCTAssertTrue(result.triangles.allSatisfy { $0.surfaceID == 7 })
        XCTAssertFalse(result.triangles.contains { $0.surfaceID == 42 })
        // Exactly the new box's own 8 corners and one group, nothing else.
        XCTAssertEqual(result.vertices.count, 8)
        XCTAssertEqual(result.groups.count, 1)
    }

    /// The `id` is the one thing that must survive, it's this mesh's own
    /// real record identity, not part of "the old geometry."
    func testRebuildingFromScratchPreservesTheBaselinesID() {
        let baseline = makeBaselineMesh()
        let box = LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(0, 0, 0), worldMax: SIMD3(1, 1, 1))
        let result = LevelCollisionRebuilder.rebuildingFromScratch(preservingIDFrom: baseline, addingBoxes: [box], surfaceID: 0)
        XCTAssertEqual(result.id, baseline.id)
    }

    /// Multiple boxes (standing in for "every scenery object in the
    /// level") each get their own real, independent group, same
    /// per-box-group contract `rebuilding` already guarantees, just
    /// starting from nothing instead of an existing mesh.
    func testRebuildingFromScratchGivesEveryBoxItsOwnGroup() {
        let baseline = makeBaselineMesh()
        let boxes = [
            LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(0, 0, 0), worldMax: SIMD3(1, 1, 1)),
            LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(5, 5, 5), worldMax: SIMD3(6, 6, 6)),
            LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(20, 20, 20), worldMax: SIMD3(21, 21, 21)),
        ]
        let result = LevelCollisionRebuilder.rebuildingFromScratch(preservingIDFrom: baseline, addingBoxes: boxes, surfaceID: 0)
        XCTAssertEqual(result.groups.count, 3)
        XCTAssertEqual(result.vertices.count, 24)
        // A real trigger tree covers all three groups (leaves == groups
        // for a balanced tree over 3 leaves means at least 3 leaf nodes).
        XCTAssertGreaterThanOrEqual(result.triggerBoxes.count, 3)
    }

    /// Real, must-hold property for the from-scratch path too: the result
    /// round-trips cleanly through the actual writer and parser.
    func testRebuildingFromScratchRoundTripsThroughTheRealWriterAndParser() throws {
        let baseline = makeBaselineMesh()
        let boxes = [
            LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(-1, -1, -1), worldMax: SIMD3(1, 1, 1)),
            LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(3, 3, 3), worldMax: SIMD3(4, 4, 4)),
        ]
        let rebuilt = LevelCollisionRebuilder.rebuildingFromScratch(preservingIDFrom: baseline, addingBoxes: boxes, surfaceID: 3)

        let encoded = ColDataWriter.write(rebuilt)
        var cursor = BinaryCursor(data: encoded)
        let decoded = try ColDataParser.parse(&cursor, recordID: rebuilt.id, size: encoded.count)

        XCTAssertEqual(decoded.vertices.count, rebuilt.vertices.count)
        XCTAssertEqual(decoded.triangles.count, rebuilt.triangles.count)
        XCTAssertEqual(decoded.groups.count, rebuilt.groups.count)
        XCTAssertEqual(decoded.triggerBoxes.count, rebuilt.triggerBoxes.count)
        for (a, b) in zip(decoded.triangles, rebuilt.triangles) {
            XCTAssertEqual(a.surfaceID, b.surfaceID)
        }
        XCTAssertEqual(cursor.position, encoded.count)
    }

    /// An empty box list against a real, non-empty baseline must still
    /// discard the baseline's own geometry (this is "destroy," not "no-op
    /// like `rebuilding` with no boxes"), an empty level (or one whose
    /// scenery objects genuinely have no collision data) rebuilds to a
    /// genuinely empty mesh, not the untouched original.
    func testRebuildingFromScratchWithNoBoxesProducesAGenuinelyEmptyMesh() {
        let baseline = makeBaselineMesh()
        let result = LevelCollisionRebuilder.rebuildingFromScratch(preservingIDFrom: baseline, addingBoxes: [], surfaceID: 0)
        XCTAssertTrue(result.vertices.isEmpty)
        XCTAssertTrue(result.triangles.isEmpty)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.id, baseline.id)
    }

    // MARK: - dominantSolidSurfaceID ("don't pick water")

    /// Builds a `CollisionMesh` with two surfaces: a huge, near-perfectly
    /// flat plane (real water's own measured shape in this game's actual
    /// `beach.rm2`: ~330 units wide, well under 1 unit tall) covering more
    /// *triangles* than a smaller, genuinely 3D terrain chunk (varied
    /// height), the exact shape of the failure this hardening exists for.
    private func makeMeshWithDominantFlatWaterAndSparserTerrain() -> CollisionMesh {
        var vertices: [SIMD4<Float>] = []
        var triangles: [CollisionTriangle] = []

        // A wide, flat "water" grid at y=0 -- many small triangles, the
        // dominant surface by raw triangle count.
        let waterSurfaceID = 12
        let gridSize = 12
        let cell: Float = 30
        for gz in 0..<gridSize {
            for gx in 0..<gridSize {
                let x0 = Float(gx) * cell, x1 = x0 + cell
                let z0 = Float(gz) * cell, z1 = z0 + cell
                let base = vertices.count
                vertices.append(SIMD4(x0, 0, z0, 1))
                vertices.append(SIMD4(x1, 0, z0, 1))
                vertices.append(SIMD4(x1, 0, z1, 1))
                vertices.append(SIMD4(x0, 0, z1, 1))
                triangles.append(CollisionTriangle(vertexIndex1: base, vertexIndex2: base + 1, vertexIndex3: base + 2, surfaceID: waterSurfaceID))
                triangles.append(CollisionTriangle(vertexIndex1: base, vertexIndex2: base + 2, vertexIndex3: base + 3, surfaceID: waterSurfaceID))
            }
        }
        // A small, genuinely 3D terrain chunk -- far fewer triangles, but
        // real height variance (a little cliff/rock), surfaceID 0.
        let terrainSurfaceID = 0
        let terrainBase = vertices.count
        vertices.append(SIMD4(0, 0, 0, 1))
        vertices.append(SIMD4(5, 0, 0, 1))
        vertices.append(SIMD4(0, 0, 5, 1))
        vertices.append(SIMD4(0, 20, 0, 1))
        triangles.append(CollisionTriangle(vertexIndex1: terrainBase, vertexIndex2: terrainBase + 1, vertexIndex3: terrainBase + 3, surfaceID: terrainSurfaceID))
        triangles.append(CollisionTriangle(vertexIndex1: terrainBase, vertexIndex2: terrainBase + 2, vertexIndex3: terrainBase + 3, surfaceID: terrainSurfaceID))

        XCTAssertGreaterThan(triangles.filter { $0.surfaceID == waterSurfaceID }.count, triangles.filter { $0.surfaceID == terrainSurfaceID }.count,
                             "sanity: the flat water surface must genuinely outnumber terrain by raw triangle count, or this test doesn't exercise the real failure mode")

        let groups = [CollisionGroup(size: UInt32(triangles.count), offset: 0)]
        let triggerBoxes = CollisionOBJImporter.buildTriggerTree(groups: groups, triangles: triangles, vertices: vertices)
        return CollisionMesh(id: 1, vertices: vertices, triangles: triangles, groups: groups, triggerBoxes: triggerBoxes)
    }

    func testDominantSolidSurfaceIDSkipsAFlatWaterPlaneEvenWhenItOutnumbersTerrain() {
        let mesh = makeMeshWithDominantFlatWaterAndSparserTerrain()
        let picked = LevelCollisionRebuilder.dominantSolidSurfaceID(in: mesh)
        XCTAssertEqual(picked, 0, "a huge flat plane must never be picked as 'ordinary solid ground,' even when it has more raw triangles than real terrain")
    }

    /// Sanity/regression guard: when every surface is genuinely 3D (no
    /// flat-plane candidate to exclude), this must behave exactly like
    /// plain "most common by triangle count" always did.
    func testDominantSolidSurfaceIDFallsBackToPlainMajorityWhenNoFlatPlaneExists() {
        let baseline = makeBaselineMesh() // one small, slightly-flat-but-tiny quad, surfaceID 42
        XCTAssertEqual(LevelCollisionRebuilder.dominantSolidSurfaceID(in: baseline), 42)
    }

    func testDominantSolidSurfaceIDOnEmptyMeshReturnsZero() {
        let empty = CollisionMesh(id: 1, vertices: [], triangles: [], groups: [], triggerBoxes: [])
        XCTAssertEqual(LevelCollisionRebuilder.dominantSolidSurfaceID(in: empty), 0)
    }
}
