import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Real, requested verification: "Rebuild All Collision" must only ever
/// generate collision from scenery geometry, never from a Forge-placed
/// Instance (an "actor") sitting in the same level, even though both kinds
/// of object can carry real, resolved collision data
/// (`assetCollisionData`/`generatedCollisionData` are populated for both,
/// see `spawnScenery`/`spawnInstance`'s own doc comments). Mixes one real
/// on-disk scenery placement with one real on-disk Instance placement in
/// the same renderer and proves the full rebuild picks up only the former.
@MainActor
final class RebuildAllCollisionExcludesForgeObjectsTests: XCTestCase {
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

    func testFullRebuildOnlyIncludesSceneryEvenWithAForgeInstancePresent() throws {
        let onDiskAsset = makeTestAsset(recordID: 1)

        let instanceNode = ChunkNode(recordID: 9, sectionType: .instance, displayName: "Instance #1", byteSize: 0, fileOffset: 0)
        let instance = PlacedInstance(
            id: 1, position: SIMD4<Float>(60, 0, 60, 1), rotationRaw: .zero, comRotationRaw: .zero,
            childInstanceIDs: [], childPositionIDs: [], childPathIDs: [],
            someNum1: 10, someNum2: 10, someNum3: 10,
            objectID: 42, refList: -1, scriptID: -1, flags: 6,
            unknownUInt32List: [], unknownFloatList: [], unknownUInt32List2: []
        )
        // Real, resolved collision on the Forge/actor object too, the
        // exclusion has to be by `.layer`, not by "does it happen to have
        // collision data," or this test would pass for the wrong reason.
        let instanceCollisionData = GraphicsInfoCollisionData(header: [UInt16](repeating: 0, count: 11), positions: [SIMD4<Float>(-1, -1, -1, 1), SIMD4<Float>(1, 1, 1, 1)])
        let instanceSkeleton = SkeletonAsset(id: 1, joints: [], exitPoints: [], skinTransforms: [], skinID: 0, blendSkinID: 0, modelLinks: [], collisionData: [instanceCollisionData])
        let instanceAsset = ResolvedModelAsset(recordID: 2, displayName: "Test Forge Instance Model", mesh: MeshAsset(id: 2, isSkinned: false, submeshes: []), submeshMaterials: [], skeleton: instanceSkeleton)

        let renderer = try XCTUnwrap(LevelViewerRenderer(
            placements: [
                (worldPosition: SIMD3<Float>(3, 0, 3), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1), asset: onDiskAsset, matrixFileOffset: 100),
            ],
            instanceMarkers: [(instanceNode, instance)],
            resolvedInstanceAssets: [instanceNode.id: instanceAsset]
        ))
        XCTAssertTrue(renderer.objectSummaries.contains { $0.layer == .actors }, "the Forge instance must actually be present in this level for the exclusion to mean anything")

        renderer.rebuildAllCollisionRequested = true
        let baseline = makeBaselineCollisionMesh()
        let collisionNode = ChunkNode(recordID: 5, sectionType: .null, displayName: "ColData", byteSize: 0, fileOffset: 0)
        let result = try XCTUnwrap(LevelViewerWindow.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: [(collisionNode, baseline)]))

        var cursor = BinaryCursor(data: result.encoded)
        let reparsed = try ColDataParser.parse(&cursor, recordID: collisionNode.recordID, size: result.encoded.count)

        // Exactly one group -- the scenery object only, not a second one
        // for the Forge instance.
        XCTAssertEqual(reparsed.groups.count, 1, "a full rebuild must only generate collision from scenery, never from a Forge-placed Instance, even one with real collision data")
        let hasBoxNearScenery = reparsed.vertices.contains { abs($0.x - (-3)) < 2 && abs($0.z - 3) < 2 }
        XCTAssertTrue(hasBoxNearScenery, "the scenery object must still get a real collision box")
        let hasBoxNearForgeInstance = reparsed.vertices.contains { abs($0.x - (-60)) < 2 && abs($0.z - 60) < 2 }
        XCTAssertFalse(hasBoxNearForgeInstance, "no collision box should be generated at the Forge instance's own position")
    }
}
