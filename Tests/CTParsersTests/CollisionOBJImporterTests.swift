import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels
import simd

/// "Parity Phase I": `CollisionOBJImporter`, ported from `Workers/
/// CollisionImporter.cs`'s OBJ loader, connectivity-grouping algorithm,
/// and balanced binary trigger-tree builder. See that file's own doc
/// comment for the two faithfully-preserved reference quirks and the one
/// deliberate AABB-correctness deviation these tests assume.
final class CollisionOBJImporterTests: XCTestCase {
    // MARK: - Parsing

    func testXIsNegatedOnImport() {
        let obj = "v 1 2 3\nv 0 0 0\nv 0 1 0\nf 1 2 3\n"
        let model = CollisionOBJImporter.parseOBJ(obj, maxPolysPerGroup: 100)
        XCTAssertEqual(model.vertices[0], SIMD4<Float>(-1, 2, 3, 1))
    }

    func testSingleTriangleParsesToOneGroup() {
        let obj = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """
        let model = CollisionOBJImporter.parseOBJ(obj, maxPolysPerGroup: 100)
        XCTAssertEqual(model.vertexCount, 3)
        XCTAssertEqual(model.groups.count, 1)
        XCTAssertEqual(model.triangleCount, 1)
        XCTAssertEqual(model.groups[0][0].v1, 0)
        XCTAssertEqual(model.groups[0][0].v2, 1)
        XCTAssertEqual(model.groups[0][0].v3, 2)
    }

    func testTwoDisconnectedTrianglesFormTwoGroups() {
        let obj = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 10 0 0
        v 11 0 0
        v 10 1 0
        f 1 2 3
        f 4 5 6
        """
        let model = CollisionOBJImporter.parseOBJ(obj, maxPolysPerGroup: 100)
        XCTAssertEqual(model.groups.count, 2)
        XCTAssertEqual(model.groups[0].count, 1)
        XCTAssertEqual(model.groups[1].count, 1)
    }

    func testConnectedTrianglesMergeDuringInitialPass() {
        // Two triangles sharing an edge (vertices 2,3) should join the same
        // group immediately, before mergeGroups even runs.
        let obj = """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        f 1 2 3
        f 1 3 4
        """
        let model = CollisionOBJImporter.parseOBJ(obj, maxPolysPerGroup: 100)
        XCTAssertEqual(model.groups.count, 1)
        XCTAssertEqual(model.groups[0].count, 2)
    }

    /// Two initially-separate connectivity groups get bridged by a third
    /// face that touches both, `parseOBJ`'s own per-face loop only folds
    /// the *new* face into whichever group its first-found vertex belongs
    /// to, it doesn't unify the two pre-existing groups themselves; that's
    /// `mergeGroups`'s job, run once at the end.
    func testMergeGroupsUnifiesIndirectlyConnectedGroups() {
        let obj = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 10 0 0
        v 11 0 0
        v 10 1 0
        v 5 5 0
        f 1 2 3
        f 5 4 6
        f 2 5 7
        """
        // Face 3 (vertices 2,5,7) shares vertex 2 with face 1's group and
        // vertex 5 with face 2's group, bridging them. Face 2 is written
        // "5 4 6" (not "4 5 6") specifically so the shared vertex (5) lands
        // at group 1's triangle's *first* slot, `mergeGroups`'s own
        // vertex-overlap check only tests a group's first and third
        // vertex (see this type's own doc comment on the real, faithfully-
        // preserved "Vert2 never checked" bug); had the shared vertex
        // landed in the middle slot instead, the merge this test verifies
        // wouldn't fire, see `testVert2NeverCheckedDuringMerge` below for
        // that exact case, tested deliberately rather than by accident.
        let model = CollisionOBJImporter.parseOBJ(obj, maxPolysPerGroup: 100)
        XCTAssertEqual(model.groups.count, 1, "the bridging face should cause mergeGroups to unify both original groups")
        XCTAssertEqual(model.triangleCount, 3)
    }

    /// Same bridging shape as `testMergeGroupsUnifiesIndirectlyConnectedGroups`,
    /// but the shared vertex lands in group 1's triangle's *second* slot
    /// (`Vert2`), the one slot `mergeGroups`'s own overlap check never
    /// tests (a real copy-paste bug in the reference: it checks `Vert1`/
    /// `Vert3` and `Vert3` again, never `Vert2`). Faithfully preserved, so
    /// the two groups must stay unmerged here even though they're
    /// genuinely connected.
    func testVert2NeverCheckedDuringMerge() {
        let obj = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 10 0 0
        v 11 0 0
        v 10 1 0
        v 5 5 0
        f 1 2 3
        f 4 5 6
        f 2 5 7
        """
        let model = CollisionOBJImporter.parseOBJ(obj, maxPolysPerGroup: 100)
        XCTAssertEqual(model.groups.count, 2, "the shared vertex lands in the untested Vert2 slot, so the real connectivity is missed")
        XCTAssertEqual(model.triangleCount, 3)
    }

    func testMergeGroupsRespectsMaxPolysLimit() {
        let obj = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 10 0 0
        v 11 0 0
        v 10 1 0
        v 5 5 0
        f 1 2 3
        f 5 4 6
        f 2 5 7
        """
        // Same bridging shape (and same Vert1/Vert3-detectable ordering)
        // as `testMergeGroupsUnifiesIndirectlyConnectedGroups`, but a
        // max-polys-per-group of 2 means the merge (which would produce a
        // 3-triangle group) is refused, the bridging triangle still
        // lands in group 0 (that happens unconditionally in the per-face
        // loop), so group 0 ends with 2 triangles and mergeGroups leaves
        // the two groups separate.
        let model = CollisionOBJImporter.parseOBJ(obj, maxPolysPerGroup: 2)
        XCTAssertEqual(model.groups.count, 2)
        XCTAssertEqual(model.triangleCount, 3)
    }

    func testIgnoresNonVertexNonFaceLines() {
        let obj = """
        # a comment
        o MyObject
        v 0 0 0
        v 1 0 0
        v 0 1 0
        vn 0 0 1
        f 1 2 3
        """
        let model = CollisionOBJImporter.parseOBJ(obj, maxPolysPerGroup: 100)
        XCTAssertEqual(model.vertexCount, 3)
        XCTAssertEqual(model.triangleCount, 1)
    }

    // MARK: - Combined mesh / trigger tree

    func testSingleGroupProducesOneTriggerCoveringItsBounds() {
        let obj = """
        v 0 0 0
        v 2 0 0
        v 0 2 0
        f 1 2 3
        """
        let model = CollisionOBJImporter.parseOBJ(obj, maxPolysPerGroup: 100)
        let mesh = CollisionOBJImporter.buildCombinedMesh(id: 1, models: [(model, 5)])
        XCTAssertEqual(mesh.triggerBoxes.count, 1)
        let box = mesh.triggerBoxes[0]
        XCTAssertEqual(box.flag1, -1)
        XCTAssertEqual(box.flag2, -1)
        XCTAssertEqual(box.min.x, -2, accuracy: 0.001) // X negated on import: verts at 0,-2,0
        XCTAssertEqual(box.max.y, 2, accuracy: 0.001)
        XCTAssertEqual(mesh.triangles[0].surfaceID, 5)
    }

    /// 3 groups -> `2*3 - 1 = 5` triggers; the root must be an internal
    /// node (non-negative `flag1`) whose recursively-unioned AABB covers
    /// every group's real geometry.
    func testMultipleGroupsProduceCorrectTriggerCountAndRootUnion() {
        let obj = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 10 0 0
        v 11 0 0
        v 10 1 0
        v -10 0 0
        v -9 0 0
        v -10 -1 0
        f 1 2 3
        f 4 5 6
        f 7 8 9
        """
        let model = CollisionOBJImporter.parseOBJ(obj, maxPolysPerGroup: 100)
        XCTAssertEqual(model.groups.count, 3, "three fully disconnected triangles should stay three separate groups")
        let mesh = CollisionOBJImporter.buildCombinedMesh(id: 2, models: [(model, 0)])
        XCTAssertEqual(mesh.triggerBoxes.count, 5)

        let root = mesh.triggerBoxes[0]
        XCTAssertGreaterThanOrEqual(root.flag1, 0, "root of a multi-group tree must be an internal node")
        // Root's box must be the union of every real vertex position (X negated on import).
        var expectedMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var expectedMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices {
            expectedMin = simd_min(expectedMin, SIMD3(v.x, v.y, v.z))
            expectedMax = simd_max(expectedMax, SIMD3(v.x, v.y, v.z))
        }
        XCTAssertEqual(root.min, expectedMin)
        XCTAssertEqual(root.max, expectedMax)

        // Every leaf trigger's negative flag must resolve to a distinct, in-range group.
        let leaves = mesh.triggerBoxes.filter { $0.flag1 < 0 }
        XCTAssertEqual(leaves.count, 3)
        let resolvedGroupIndices = Set(leaves.map { Int(-$0.flag1 - 1) })
        XCTAssertEqual(resolvedGroupIndices, [0, 1, 2])
    }

    func testCombinedMeshConcatenatesMultipleModelsWithOffsets() {
        let modelA = CollisionOBJImporter.parseOBJ("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n", maxPolysPerGroup: 100)
        let modelB = CollisionOBJImporter.parseOBJ("v 5 0 0\nv 6 0 0\nv 5 1 0\nf 1 2 3\n", maxPolysPerGroup: 100)
        let mesh = CollisionOBJImporter.buildCombinedMesh(id: 3, models: [(modelA, 1), (modelB, 2)])

        XCTAssertEqual(mesh.vertices.count, 6)
        XCTAssertEqual(mesh.triangles.count, 2)
        XCTAssertEqual(mesh.groups.count, 2)
        // Model B's triangle indices must be offset past model A's 3 vertices.
        XCTAssertEqual(mesh.triangles[1].vertexIndex1, 3)
        XCTAssertEqual(mesh.triangles[0].surfaceID, 1)
        XCTAssertEqual(mesh.triangles[1].surfaceID, 2)
        // Model B's group offset must point past model A's 1 triangle.
        XCTAssertEqual(mesh.groups[1].offset, 1)
    }

    func testEmptyModelListProducesEmptyMeshWithNoTriggers() {
        let mesh = CollisionOBJImporter.buildCombinedMesh(id: 4, models: [])
        XCTAssertTrue(mesh.vertices.isEmpty)
        XCTAssertTrue(mesh.triggerBoxes.isEmpty)
    }

    // MARK: - Round-trip through ColDataWriter/ColDataParser

    func testImportedMeshRoundTripsThroughColDataWriteAndParse() throws {
        let obj = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 10 0 0
        v 11 0 0
        v 10 1 0
        f 1 2 3
        f 4 5 6
        """
        let model = CollisionOBJImporter.parseOBJ(obj, maxPolysPerGroup: 100)
        let mesh = CollisionOBJImporter.buildCombinedMesh(id: 9, models: [(model, 3)])

        let encoded = ColDataWriter.write(mesh)
        var cursor = BinaryCursor(data: encoded)
        let reparsed = try ColDataParser.parse(&cursor, recordID: 9, size: encoded.count)

        XCTAssertEqual(reparsed.vertices.count, mesh.vertices.count)
        XCTAssertEqual(reparsed.triangles.count, mesh.triangles.count)
        XCTAssertEqual(reparsed.groups.count, mesh.groups.count)
        XCTAssertEqual(reparsed.triggerBoxes.count, mesh.triggerBoxes.count)
        XCTAssertEqual(reparsed.triangles[0].surfaceID, 3)
    }
}
