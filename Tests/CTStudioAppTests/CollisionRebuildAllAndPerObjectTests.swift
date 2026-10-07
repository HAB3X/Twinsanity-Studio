import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// "Rebuild All Collision" / "Rebuild Collision for This Object", real,
/// Destroy-and-rebuild collision from each scenery
/// object's own actual mesh triangles, deliberately more drastic than
/// the existing incremental new-object-only collision sync
/// (`SpawnAndDeleteTests`' own coverage of `computingRebuiltCollisionRecord`'s
/// incremental path). These tests cover the two destroy-and-rebuild paths
/// that short-circuit ahead of that incremental logic, and the post-save
/// overlay-refresh mechanism this task's own instructions specifically
/// asked to be verified, not assumed.
@MainActor
final class CollisionRebuildAllAndPerObjectTests: XCTestCase {
    /// Same minimal, real, decodable baseline as `SpawnAndDeleteTests`'ss
    /// own `makeBaselineCollisionMesh`, one ground quad, surfaceID 42.
    private func makeBaselineCollisionMesh() -> CollisionMesh {
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

    private func makeTestAsset(recordID: UInt32 = 42) -> ResolvedModelAsset {
        let vertices = [
            StaticVertex(position: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 0)),
            StaticVertex(position: SIMD3(1, 0, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(1, 0)),
            StaticVertex(position: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 1)),
        ]
        let submesh = MeshSubmesh(vertices: vertices, connectivity: [true, true, true], materialID: 1)
        let mesh = MeshAsset(id: 1, isSkinned: false, submeshes: [submesh])
        let texture = TextureAsset(id: 1, width: 2, height: 2, pixelFormat: .psmct32, rgba: [UInt8](repeating: 200, count: 16))
        let material = ResolvedSubmeshMaterial(materialID: 1, textureID: 1, texture: texture)
        return ResolvedModelAsset(recordID: recordID, displayName: "Test Scenery Model", mesh: mesh, submeshMaterials: [material])
    }

    // MARK: - "Rebuild All Collision"

    /// The defining, real, requested behavior: not just session-placed
    /// objects. Seeds one *on-disk* scenery placement (via the renderer's
    /// own `placements:` init, a real object with `newSceneryModelID ==
    /// nil`, exactly like something loaded from the level's real file)
    /// plus one *session-placed* one (`spawnScenery`), and proves the
    /// full-rebuild path picks up both, the whole reason "Rebuild All
    /// Collision" exists rather than just reusing the existing, session-
    /// placed-only incremental path.
    func testComputingFullyRebuiltCollisionRecordIncludesBothOnDiskAndSessionPlacedScenery() throws {
        let onDiskAsset = makeTestAsset(recordID: 1)
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [
            (worldPosition: SIMD3<Float>(3, 0, 3), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1), asset: onDiskAsset, matrixFileOffset: 100),
        ]))
        let sessionAsset = makeTestAsset(recordID: 2)
        _ = try XCTUnwrap(renderer.spawnScenery(modelID: 7, isSpecial: false, asset: sessionAsset, at: SIMD3<Float>(30, 0, 30)))

        renderer.rebuildAllCollisionRequested = true
        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)
        let result = try XCTUnwrap(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))
        XCTAssertEqual(result.node.recordID, collisionNode.recordID)

        var cursor = BinaryCursor(data: result.encoded)
        let reparsed = try ColDataParser.parse(&cursor, recordID: collisionNode.recordID, size: result.encoded.count)

        // Destroy semantics: the baseline's own real ground-quad vertices
        // do not survive a full rebuild.
        for baselineVertex in baseline.vertices {
            XCTAssertFalse(reparsed.vertices.contains(baselineVertex), "a full rebuild must not carry over the old, pre-rebuild mesh's own geometry")
        }
        // Two real scenery objects -> two real groups, one per object.
        XCTAssertEqual(reparsed.groups.count, 2)
        // Boxes actually sit near each object's own real position, not
        // some other/invented location. Real on-disk `ColData` stores
        // raw, unmirrored coordinates, `object.worldPosition` is this
        // editor's mirrored *display* X (empirically confirmed against
        // this game's own real `beach.rm2`; see `LevelViewerWindow.
        // rawColDataPosition`'s own doc comment), so what's actually
        // written negates X back.
        let hasBoxNearOnDisk = reparsed.vertices.contains { abs($0.x - (-3)) < 2 && abs($0.z - 3) < 2 }
        let hasBoxNearSessionPlaced = reparsed.vertices.contains { abs($0.x - (-30)) < 2 && abs($0.z - 30) < 2 }
        XCTAssertTrue(hasBoxNearOnDisk, "the on-disk (never session-placed) object must get a real collision box too")
        XCTAssertTrue(hasBoxNearSessionPlaced, "the session-placed object must also get a real collision box")
    }

    /// The real, requested guarantee: since the rebuild reads each object's
    /// *current* `worldPosition` (not any "original" position, that whole
    /// distinction was removed along with "Update Collision for Moved
    /// Objects"), a dragged on-disk object's collision must land at its new
    /// position, and a session-placed object must get collision too, in the
    /// exact same rebuild.
    func testComputingFullyRebuiltCollisionRecordFollowsMovedAndFreshlyPlacedScenery() throws {
        let onDiskAsset = makeTestAsset(recordID: 1)
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [
            (worldPosition: SIMD3<Float>(3, 0, 3), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1), asset: onDiskAsset, matrixFileOffset: 100),
        ]))
        let movedIndex = try XCTUnwrap(renderer.objectSummaries.firstIndex { $0.layer == .scenery })
        renderer.setPositions([(index: movedIndex, position: SIMD3<Float>(75, 0, 75))])

        let sessionAsset = makeTestAsset(recordID: 2)
        _ = try XCTUnwrap(renderer.spawnScenery(modelID: 7, isSpecial: false, asset: sessionAsset, at: SIMD3<Float>(30, 0, 30)))

        renderer.rebuildAllCollisionRequested = true
        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)
        let result = try XCTUnwrap(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))

        var cursor = BinaryCursor(data: result.encoded)
        let reparsed = try ColDataParser.parse(&cursor, recordID: collisionNode.recordID, size: result.encoded.count)

        XCTAssertEqual(reparsed.groups.count, 2, "the moved object and the freshly-placed object -> two real groups")
        // Real on-disk `ColData` stores raw, unmirrored X (see the
        // "IncludesBothOnDiskAndSessionPlacedScenery" test above for the
        // full explanation) -- checked against the negated position.
        let hasCollisionAtOldPosition = reparsed.vertices.contains { abs($0.x - (-3)) < 2 && abs($0.z - 3) < 2 }
        let hasCollisionAtNewPosition = reparsed.vertices.contains { abs($0.x - (-75)) < 2 && abs($0.z - 75) < 2 }
        let hasCollisionForFreshlyPlaced = reparsed.vertices.contains { abs($0.x - (-30)) < 2 && abs($0.z - 30) < 2 }
        XCTAssertFalse(hasCollisionAtOldPosition, "the moved object's collision must not be left behind at its old position")
        XCTAssertTrue(hasCollisionAtNewPosition, "the moved object's collision must follow it to its new position")
        XCTAssertTrue(hasCollisionForFreshlyPlaced, "a freshly session-placed object must also get real collision in the same rebuild")
    }

    /// Sanity/regression guard: with the flag left at its default `false`,
    /// `computingRebuiltCollisionRecord` must fall through to the existing,
    /// already-proven incremental path (session-placed-only, additive , 
    /// `SpawnAndDeleteTests`' own coverage), not the new destroy-and-rebuild
    /// one. Same renderer state as the test above, flag off.
    func testFullRebuildFlagOffFallsThroughToTheExistingIncrementalPath() throws {
        let onDiskAsset = makeTestAsset(recordID: 1)
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [
            (worldPosition: SIMD3<Float>(3, 0, 3), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1), asset: onDiskAsset, matrixFileOffset: 100),
        ]))
        let sessionAsset = makeTestAsset(recordID: 2)
        _ = try XCTUnwrap(renderer.spawnScenery(modelID: 7, isSpecial: false, asset: sessionAsset, at: SIMD3<Float>(30, 0, 30)))
        XCTAssertFalse(renderer.rebuildAllCollisionRequested, "sanity: must default to off")

        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)
        let result = try XCTUnwrap(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))

        var cursor = BinaryCursor(data: result.encoded)
        let reparsed = try ColDataParser.parse(&cursor, recordID: collisionNode.recordID, size: result.encoded.count)
        // Additive, not destructive: the baseline's own ground quad survives.
        for baselineVertex in baseline.vertices {
            XCTAssertTrue(reparsed.vertices.contains(baselineVertex), "the incremental path must never discard the existing mesh")
        }
        // Only the session-placed object got a box, the on-disk one
        // (never moved, never session-placed) is untouched by this path.
        let hasBoxNearOnDisk = reparsed.vertices.contains { abs($0.x - 3) < 2 && abs($0.z - 3) < 2 }
        XCTAssertFalse(hasBoxNearOnDisk, "the existing incremental path must not touch an on-disk object nobody moved or placed this session")
    }

    /// No scenery with any collision data anywhere in the level -> nothing
    /// to rebuild -> `nil`, not a spurious "rebuilt" record with zero real
    /// boxes.
    func testComputingFullyRebuiltCollisionRecordIsNilWithNoSceneryAtAll() throws {
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: []))
        renderer.rebuildAllCollisionRequested = true
        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)
        XCTAssertNil(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))
    }

    /// The defining new behavior: collision must be the object's own real
    /// mesh triangle, not a box or hull approximation. One on-disk object
    /// whose asset is exactly one non-axis-aligned triangle, a box
    /// approximation would produce an 8-corner cuboid (24 double-wound
    /// triangles per `LevelCollisionRebuilder`'s box path); the real-mesh
    /// path must instead produce exactly 3 unique world-space vertex
    /// positions (double-winding reuses them, never invents new ones) at
    /// precisely this triangle's own real shape.
    func testComputingFullyRebuiltCollisionRecordUsesTheObjectsOwnRealTriangleNotABox() throws {
        let asset = makeTestAsset(recordID: 1)
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [
            (worldPosition: SIMD3<Float>(0, 0, 0), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1), asset: asset, matrixFileOffset: 100),
        ]))
        renderer.rebuildAllCollisionRequested = true
        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)
        let result = try XCTUnwrap(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))

        var cursor = BinaryCursor(data: result.encoded)
        let reparsed = try ColDataParser.parse(&cursor, recordID: collisionNode.recordID, size: result.encoded.count)

        XCTAssertEqual(reparsed.groups.count, 1)
        // makeTestAsset's own real local-space triangle: (0,0,0), (1,0,0), (0,1,0).
        // Real on-disk ColData stores raw, unmirrored X (see
        // "IncludesBothOnDiskAndSessionPlacedScenery" above), so the
        // (1,0,0) corner must come out negated.
        let expected: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)]
        for e in expected {
            XCTAssertTrue(reparsed.vertices.contains { SIMD3($0.x, $0.y, $0.z) == e },
                          "collision must reproduce the object's own real vertex \(e), not a box corner")
        }
        XCTAssertEqual(reparsed.vertices.count, 3, "no box-corner geometry should be present, exactly the source triangle's own 3 vertices")
        XCTAssertEqual(reparsed.groups.first?.size, 2, "one source triangle, double-wound -> exactly 2 collision triangles, not a box's 24")
    }

    /// Real, reported bug (collision renders as a mirror image of the
    /// actual scenery, both in the Level Viewer's own overlay and in real
    /// PCSX2): `object.worldPosition` is this editor's mirrored *display*
    /// space (empirically confirmed against this game's own real
    /// `beach.rm2`), but real on-disk `ColData` stores raw, unmirrored
    /// coordinates. An object placed well off-center on X is the sharpest
    /// version of this check, a bug here means every single vertex lands
    /// on the wrong side of the level, not just a few units off.
    func testComputingFullyRebuiltCollisionRecordWritesRawUnmirroredCoordinatesNotDisplaySpace() throws {
        let asset = makeTestAsset(recordID: 1)
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [
            (worldPosition: SIMD3<Float>(40, 0, 5), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1), asset: asset, matrixFileOffset: 100),
        ]))
        renderer.rebuildAllCollisionRequested = true
        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)
        let result = try XCTUnwrap(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))

        var cursor = BinaryCursor(data: result.encoded)
        let reparsed = try ColDataParser.parse(&cursor, recordID: collisionNode.recordID, size: result.encoded.count)

        XCTAssertTrue(reparsed.vertices.contains { abs($0.x - (-40)) < 2 && abs($0.z - 5) < 2 },
                     "collision must land at the object's real on-disk (raw, unmirrored) X, not its mirrored display X")
        XCTAssertFalse(reparsed.vertices.contains { abs($0.x - 40) < 2 && abs($0.z - 5) < 2 },
                      "collision must never be written at the mirrored (display-space) X, that's the actual reported bug")
    }

    /// Real, requested behavior: scenery touching/overlapping another
    /// object collapses into one shared `CollisionGroup` during a whole-
    /// level rebuild. Two on-disk placements positioned so their local
    /// triangles (both span roughly a 1-unit footprint) genuinely overlap
    /// in world space.
    func testComputingFullyRebuiltCollisionRecordMergesTouchingSceneryIntoOneGroup() throws {
        let assetA = makeTestAsset(recordID: 1)
        let assetB = makeTestAsset(recordID: 2)
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [
            (worldPosition: SIMD3<Float>(0, 0, 0), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1), asset: assetA, matrixFileOffset: 100),
            (worldPosition: SIMD3<Float>(0.5, 0, 0), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1), asset: assetB, matrixFileOffset: 200),
        ]))
        renderer.rebuildAllCollisionRequested = true
        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)
        let result = try XCTUnwrap(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))

        var cursor = BinaryCursor(data: result.encoded)
        let reparsed = try ColDataParser.parse(&cursor, recordID: collisionNode.recordID, size: result.encoded.count)

        XCTAssertEqual(reparsed.groups.count, 1, "two touching/overlapping objects must merge into one collision group, not stay separate")
        XCTAssertEqual(reparsed.groups.first?.size, 4, "one merged group carrying both objects' own double-wound triangles (2 + 2)")
    }

    // MARK: - "Rebuild Collision for This Object"

    /// Scoped to just one object: two real on-disk scenery placements, far
    /// apart. Rebuilding collision for only the first must leave the
    /// second's own existing collision (here, standing in via the shared
    /// baseline mesh) completely untouched, and must not affect the whole
    /// level's mesh the way "Rebuild All Collision" does.
    func testComputingSingleObjectRebuiltCollisionRecordIsScopedToJustThatObject() throws {
        let assetA = makeTestAsset(recordID: 1)
        let assetB = makeTestAsset(recordID: 2)
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [
            (worldPosition: SIMD3<Float>(0, 0, 0), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1), asset: assetA, matrixFileOffset: 100),
            (worldPosition: SIMD3<Float>(99, 0, 99), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1), asset: assetB, matrixFileOffset: 200),
        ]))
        let objectIndex = try XCTUnwrap(renderer.objectSummaries.firstIndex { $0.layer == .scenery && abs($0.worldPosition.x - 0) < 1 })

        // A baseline mesh whose own existing collision sits at object A's
        // position (near the origin) -- `removingGroupsNear` should find
        // and remove it, then a fresh box gets added at the same spot.
        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)

        renderer.rebuildCollisionRequestedForObjectIndex = objectIndex
        let result = try XCTUnwrap(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))

        var cursor = BinaryCursor(data: result.encoded)
        let reparsed = try ColDataParser.parse(&cursor, recordID: collisionNode.recordID, size: result.encoded.count)

        // The baseline's own ground-quad collision (near the origin,
        // matching object A's own position) gets removed and replaced by
        // object A's own fresh box -- but object B, 99 units away, is
        // never touched by this call at all (its own collision doesn't
        // exist in this synthetic baseline, so this just proves nothing
        // near (99, 0, 99) gets fabricated).
        XCTAssertFalse(reparsed.vertices.contains { abs($0.x - 99) < 2 && abs($0.z - 99) < 2 },
                       "a single-object rebuild must never add collision for a different object")
        let hasBoxNearObjectA = reparsed.vertices.contains { abs($0.x - 0) < 2 && abs($0.z - 0) < 2 }
        XCTAssertTrue(hasBoxNearObjectA, "the targeted object must get its own real collision box")
    }

    /// A moved on-disk object, rebuilt via "Rebuild Collision for This
    /// Object" (not the whole-level path): the fresh collision must land
    /// at the object's *current*, post-drag position.
    func testComputingSingleObjectRebuiltCollisionRecordFollowsAMovedObject() throws {
        let asset = makeTestAsset(recordID: 1)
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [
            (worldPosition: SIMD3<Float>(0, 0, 0), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1), asset: asset, matrixFileOffset: 100),
        ]))
        let objectIndex = try XCTUnwrap(renderer.objectSummaries.firstIndex { $0.layer == .scenery })
        renderer.setPositions([(index: objectIndex, position: SIMD3<Float>(60, 0, 60))])

        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)
        renderer.rebuildCollisionRequestedForObjectIndex = objectIndex
        let result = try XCTUnwrap(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))

        var cursor = BinaryCursor(data: result.encoded)
        let reparsed = try ColDataParser.parse(&cursor, recordID: collisionNode.recordID, size: result.encoded.count)

        XCTAssertFalse(reparsed.vertices.contains { abs($0.x - 0) < 2 && abs($0.z - 0) < 2 && !baseline.vertices.contains($0) },
                       "no fresh collision should be fabricated at the object's old, pre-move position")
        // Real on-disk ColData stores raw, unmirrored X (see
        // "IncludesBothOnDiskAndSessionPlacedScenery" above).
        XCTAssertTrue(reparsed.vertices.contains { abs($0.x - (-60)) < 2 && abs($0.z - 60) < 2 },
                      "the rebuilt collision must sit at the object's current, post-drag position")
    }

    /// `nil` for a non-scenery object (e.g. an Instance/actor), this
    /// format's collision mesh is authored per-level scenery, not per
    /// entity, matching `canRebuildCollisionForSelected`'s own scoping.
    func testComputingSingleObjectRebuiltCollisionRecordIsNilForNonSceneryObject() throws {
        let node = ChunkNode(recordID: 9, sectionType: .instance, displayName: "Instance #1", byteSize: 0, fileOffset: 0)
        let instance = PlacedInstance(
            id: 1, position: SIMD4<Float>(0, 0, 0, 1), rotationRaw: .zero, comRotationRaw: .zero,
            childInstanceIDs: [], childPositionIDs: [], childPathIDs: [],
            someNum1: 10, someNum2: 10, someNum3: 10,
            objectID: 42, refList: -1, scriptID: -1, flags: 6,
            unknownUInt32List: [], unknownFloatList: [], unknownUInt32List2: []
        )
        let collisionData = GraphicsInfoCollisionData(header: [UInt16](repeating: 0, count: 11), positions: [SIMD4<Float>(-1, -1, -1, 1), SIMD4<Float>(1, 1, 1, 1)])
        let skeleton = SkeletonAsset(id: 1, joints: [], exitPoints: [], skinTransforms: [], skinID: 0, blendSkinID: 0, modelLinks: [], collisionData: [collisionData])
        let asset = ResolvedModelAsset(recordID: 1, displayName: "Test Instance Model", mesh: MeshAsset(id: 1, isSkinned: false, submeshes: []), submeshMaterials: [], skeleton: skeleton)
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [], instanceMarkers: [(node, instance)], resolvedInstanceAssets: [node.id: asset]))
        let index = try XCTUnwrap(renderer.objectSummaries.firstIndex { $0.layer == .actors })

        renderer.rebuildCollisionRequestedForObjectIndex = index
        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)
        XCTAssertNil(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))
    }

    // MARK: - Overlay refresh (the staleness gap this task's instructions flagged)

    /// The real requirement this checks: toggling "Show Collision" after a
    /// rebuild must show the *new* mesh, not the one from when the Level
    /// Viewer first opened. Proves `refreshingCollisionFillBuffer(with:)`
    /// actually replaces the uploaded geometry (not just that it runs
    /// without crashing) by checking the CPU-side mirror
    /// (`collisionTriangles`/`collisionFillVertexCount`) genuinely changes
    /// between two different meshes.
    func testRefreshingCollisionFillBufferActuallyReplacesThePreviouslyUploadedGeometry() throws {
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: []))

        let meshA = makeBaselineCollisionMesh()
        renderer.refreshingCollisionFillBuffer(with: [meshA])
        let vertexCountAfterA = renderer.collisionFillVertexCount
        XCTAssertGreaterThan(vertexCountAfterA, 0)
        let trianglesAfterA = renderer.collisionTriangles
        XCTAssertFalse(trianglesAfterA.isEmpty)

        // A genuinely different mesh -- more triangles, different position.
        let box = LevelCollisionRebuilder.NewCollisionBox(worldMin: SIMD3(50, 50, 50), worldMax: SIMD3(51, 51, 51))
        let meshB = LevelCollisionRebuilder.rebuildingFromScratch(preservingIDFrom: meshA, addingBoxes: [box], surfaceID: 3)
        renderer.refreshingCollisionFillBuffer(with: [meshB])

        XCTAssertNotEqual(renderer.collisionFillVertexCount, vertexCountAfterA, "the overlay's own vertex count must reflect the newly rebuilt mesh, not the stale one")
        // None of mesh A's own ground-quad-region triangles should remain
        // -- the overlay was genuinely replaced, not appended to.
        let stillHasOldGeometry = renderer.collisionTriangles.contains { triangle in
            [triangle.0, triangle.1, triangle.2].contains { abs($0.x) <= 10 && abs($0.z) <= 10 }
        }
        XCTAssertFalse(stillHasOldGeometry, "refreshing must replace the overlay's geometry, not leave the old mesh's triangles mixed in")

        // Empty input must genuinely clear the overlay too (same "nothing
        // to draw" contract `rebuildCollisionFillBuffer`'s own doc comment
        // already promises for an empty `meshes` array).
        renderer.refreshingCollisionFillBuffer(with: [])
        XCTAssertEqual(renderer.collisionFillVertexCount, 0)
        XCTAssertTrue(renderer.collisionTriangles.isEmpty)
    }
}
