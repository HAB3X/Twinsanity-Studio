import XCTest
@testable import CTCore
@testable import CTModels

/// Exercises `AssetResolver` against a hand-built `ChunkNode` tree, this
/// operates purely on already-decoded payloads (no binary parsing involved),
/// so the fixture just needs the right *shape*, not real chunk bytes.
final class AssetResolverTests: XCTestCase {
    private func leaf(_ recordID: UInt32, _ sectionType: SectionType, _ payload: ChunkPayload) -> ChunkNode {
        ChunkNode(recordID: recordID, sectionType: sectionType, displayName: "\(sectionType.rawValue)#\(recordID)", byteSize: 0, fileOffset: 0, payload: payload)
    }

    private func section(_ sectionType: SectionType, _ children: [ChunkNode]) -> ChunkNode {
        ChunkNode(recordID: 0, sectionType: sectionType, displayName: sectionType.rawValue, byteSize: 0, fileOffset: 0, children: children)
    }

    private func makeTexture(id: UInt32) -> TextureAsset {
        TextureAsset(id: id, width: 2, height: 2, pixelFormat: .psmct32, rgba: [UInt8](repeating: 255, count: 16))
    }

    private func makeMesh(id: UInt32, isSkinned: Bool, submeshMaterialIDs: [UInt32?]) -> MeshAsset {
        let submeshes = submeshMaterialIDs.map { materialID in
            MeshSubmesh(
                vertices: [StaticVertex(position: .zero), StaticVertex(position: .zero), StaticVertex(position: .zero)],
                connectivity: [true, true, true],
                materialID: materialID
            )
        }
        return MeshAsset(id: id, isSkinned: isSkinned, submeshes: submeshes)
    }

    func testResolveRigidModelLinksTextureThroughMaterial() throws {
        let texture = makeTexture(id: 100)
        let material = MaterialInfo(id: 5, name: "mat", shaders: [TwinsShaderInfo(shaderType: 0, textureId: 100)])
        let mesh = makeMesh(id: 9, isSkinned: false, submeshMaterialIDs: [nil]) // RigidModel meshes don't carry their own materialID
        let rigidModel = RigidModelInfo(id: 3, header: 257, materialIDs: [5], meshID: 9)

        let graphics = section(.graphics, [
            section(.texture, [leaf(100, .texture, .texture(texture))]),
            section(.material, [leaf(5, .material, .material(material))]),
            section(.model, [leaf(9, .model, .mesh(mesh))]),
            section(.rigidModel, [leaf(3, .rigidModel, .rigidModel(rigidModel))])
        ])
        let fileRoot = ChunkNode(recordID: 0, sectionType: .null, displayName: "test.rm2", byteSize: 0, fileOffset: 0, children: [graphics])

        let index = AssetResolver.buildIndex(fileRoot: fileRoot)
        XCTAssertEqual(index.textures.count, 1)
        XCTAssertEqual(index.materials.count, 1)
        XCTAssertEqual(index.models.count, 1)
        XCTAssertEqual(index.rigidModels.count, 1)

        let resolved = try XCTUnwrap(AssetResolver.resolveRigidModel(rigidModel, displayName: "Test", index: index))
        XCTAssertEqual(resolved.submeshMaterials.count, 1)
        XCTAssertEqual(resolved.submeshMaterials[0].materialID, 5)
        XCTAssertEqual(resolved.submeshMaterials[0].textureID, 100)
        XCTAssertEqual(resolved.submeshMaterials[0].texture?.id, 100)
        XCTAssertTrue(resolved.isFullyTextured)
    }

    func testResolveSkeletonUsesPerSubmeshMaterialIDDirectly() throws {
        let texture = makeTexture(id: 200)
        let material = MaterialInfo(id: 8, name: "skin_mat", shaders: [TwinsShaderInfo(shaderType: 0, textureId: 200)])
        // Skin submeshes carry their own materialID (unlike RigidModel submeshes).
        let mesh = makeMesh(id: 55, isSkinned: true, submeshMaterialIDs: [8])
        let skeleton = SkeletonAsset(id: 1, joints: [], exitPoints: [], skinTransforms: [], skinID: 55, blendSkinID: 0, modelLinks: [])
        let animation = AnimationAsset(id: 42, body: AnimationTrack(jointSettings: [], staticTransforms: [], frames: [], componentsPerFrame: 0), facial: AnimationTrack(jointSettings: [], staticTransforms: [], frames: [], componentsPerFrame: 0))

        let graphics = section(.graphics, [
            section(.texture, [leaf(200, .texture, .texture(texture))]),
            section(.material, [leaf(8, .material, .material(material))]),
            section(.skin, [leaf(55, .skin, .mesh(mesh))])
        ])
        let code = section(.code, [
            section(.ogi, [leaf(1, .ogi, .skeleton(skeleton))]),
            section(.animation, [leaf(42, .animation, .animation(animation))])
        ])
        let fileRoot = ChunkNode(recordID: 0, sectionType: .null, displayName: "test2.rm2", byteSize: 0, fileOffset: 0, children: [graphics, code])

        let index = AssetResolver.buildIndex(fileRoot: fileRoot)
        XCTAssertEqual(index.skins.count, 1)
        XCTAssertEqual(index.skeletons.count, 1)
        XCTAssertEqual(index.animations.count, 1)

        let resolved = try XCTUnwrap(AssetResolver.resolveSkeleton(skeleton, displayName: "Crash", index: index))
        XCTAssertEqual(resolved.submeshMaterials.count, 1)
        XCTAssertEqual(resolved.submeshMaterials[0].texture?.id, 200)
        XCTAssertEqual(resolved.availableAnimations.map(\.id), [42])
        XCTAssertTrue(resolved.isFullyTextured)
    }

    func testResolveRigidModelReturnsNilWhenMeshIDMissing() {
        let rigidModel = RigidModelInfo(id: 1, header: 257, materialIDs: [], meshID: 999)
        let index = GraphicsAssetIndex()
        XCTAssertNil(AssetResolver.resolveRigidModel(rigidModel, displayName: "Missing", index: index))
    }

    func testUnresolvedSubmeshGetsNilTextureNotACrash() throws {
        // Mesh has 2 submeshes but RigidModel only lists 1 materialID.
        let mesh = makeMesh(id: 1, isSkinned: false, submeshMaterialIDs: [nil, nil])
        let rigidModel = RigidModelInfo(id: 1, header: 257, materialIDs: [7], meshID: 1)
        let graphics = section(.graphics, [
            section(.model, [leaf(1, .model, .mesh(mesh))])
        ])
        let fileRoot = ChunkNode(recordID: 0, sectionType: .null, displayName: "test3.rm2", byteSize: 0, fileOffset: 0, children: [graphics])
        let index = AssetResolver.buildIndex(fileRoot: fileRoot)

        let resolved = try XCTUnwrap(AssetResolver.resolveRigidModel(rigidModel, displayName: "Partial", index: index))
        XCTAssertEqual(resolved.submeshMaterials.count, 2)
        XCTAssertNil(resolved.submeshMaterials[1].texture)
        XCTAssertFalse(resolved.isFullyTextured)
    }

    // MARK: - resolveInstanceObject ("Comprehensive Instance Population", Part 4B)

    /// The common case for a simple prop (a crate, a fruit, a pickup):
    /// `GameObject.OGIs[0]` -> a `GraphicsInfo` with no skin but one
    /// `modelLinks` entry -> a `RigidModel`. This is the path that used to
    /// have no real mesh at all, only the amber placeholder cube.
    func testResolveInstanceObjectViaModelLinks() throws {
        let texture = makeTexture(id: 300)
        let material = MaterialInfo(id: 9, name: "crate_mat", shaders: [TwinsShaderInfo(shaderType: 0, textureId: 300)])
        let mesh = makeMesh(id: 40, isSkinned: false, submeshMaterialIDs: [nil])
        let rigidModel = RigidModelInfo(id: 12, header: 257, materialIDs: [9], meshID: 40)
        let skeleton = SkeletonAsset(id: 500, joints: [], exitPoints: [], skinTransforms: [], skinID: 0, blendSkinID: 0, modelLinks: [ModelLink(jointIndex: 0, modelID: 12)])
        let gameObject = GameObjectInfo(id: 3, name: "BASICCRATE", ogiIDs: [500])

        let graphics = section(.graphics, [
            section(.texture, [leaf(300, .texture, .texture(texture))]),
            section(.material, [leaf(9, .material, .material(material))]),
            section(.model, [leaf(40, .model, .mesh(mesh))]),
            section(.rigidModel, [leaf(12, .rigidModel, .rigidModel(rigidModel))])
        ])
        let code = section(.code, [
            section(.ogi, [leaf(500, .ogi, .skeleton(skeleton))]),
            section(.object, [leaf(3, .object, .gameObject(gameObject))])
        ])
        let fileRoot = ChunkNode(recordID: 0, sectionType: .null, displayName: "test4.rm2", byteSize: 0, fileOffset: 0, children: [graphics, code])

        let index = AssetResolver.buildIndex(fileRoot: fileRoot)
        XCTAssertEqual(index.gameObjects.count, 1)

        let resolved = try XCTUnwrap(AssetResolver.resolveInstanceObject(objectID: 3, instanceSelector: 0, index: index))
        XCTAssertEqual(resolved.mesh.totalVertexCount, 3)
        XCTAssertEqual(resolved.submeshMaterials.first?.texture?.id, 300)
    }

    /// The other real path: `GraphicsInfo.skinID` resolves to a real skin
    /// mesh, same skinned-character resolution `resolveSkeleton` already
    /// does directly, just reached through an `Instance.objectID` first.
    func testResolveInstanceObjectViaSkinID() throws {
        let mesh = makeMesh(id: 60, isSkinned: true, submeshMaterialIDs: [nil])
        let skeleton = SkeletonAsset(id: 600, joints: [], exitPoints: [], skinTransforms: [], skinID: 60, blendSkinID: 0, modelLinks: [])
        let gameObject = GameObjectInfo(id: 4, name: "CRASH", ogiIDs: [600])

        let graphics = section(.graphics, [section(.skin, [leaf(60, .skin, .mesh(mesh))])])
        let code = section(.code, [
            section(.ogi, [leaf(600, .ogi, .skeleton(skeleton))]),
            section(.object, [leaf(4, .object, .gameObject(gameObject))])
        ])
        let fileRoot = ChunkNode(recordID: 0, sectionType: .null, displayName: "test5.rm2", byteSize: 0, fileOffset: 0, children: [graphics, code])
        let index = AssetResolver.buildIndex(fileRoot: fileRoot)

        let resolved = try XCTUnwrap(AssetResolver.resolveInstanceObject(objectID: 4, instanceSelector: 0, index: index))
        XCTAssertEqual(resolved.recordID, 600)
    }

    /// Ported directly from `RMViewer.cs`'s own `ins.UnkI323[0]` check: a
    /// non-zero, in-range `instanceSelector` picks a different `OGIs` entry
    /// than index 0.
    func testResolveInstanceObjectHonorsNonZeroSelector() throws {
        let meshA = makeMesh(id: 71, isSkinned: false, submeshMaterialIDs: [nil])
        let meshB = makeMesh(id: 72, isSkinned: false, submeshMaterialIDs: [nil])
        let rigidA = RigidModelInfo(id: 21, header: 257, materialIDs: [], meshID: 71)
        let rigidB = RigidModelInfo(id: 22, header: 257, materialIDs: [], meshID: 72)
        let skeletonA = SkeletonAsset(id: 800, joints: [], exitPoints: [], skinTransforms: [], skinID: 0, blendSkinID: 0, modelLinks: [ModelLink(jointIndex: 0, modelID: 21)])
        let skeletonB = SkeletonAsset(id: 801, joints: [], exitPoints: [], skinTransforms: [], skinID: 0, blendSkinID: 0, modelLinks: [ModelLink(jointIndex: 0, modelID: 22)])
        let gameObject = GameObjectInfo(id: 5, name: "MULTISTATE", ogiIDs: [800, 801])

        let graphics = section(.graphics, [
            section(.model, [leaf(71, .model, .mesh(meshA)), leaf(72, .model, .mesh(meshB))]),
            section(.rigidModel, [leaf(21, .rigidModel, .rigidModel(rigidA)), leaf(22, .rigidModel, .rigidModel(rigidB))])
        ])
        let code = section(.code, [
            section(.ogi, [leaf(800, .ogi, .skeleton(skeletonA)), leaf(801, .ogi, .skeleton(skeletonB))]),
            section(.object, [leaf(5, .object, .gameObject(gameObject))])
        ])
        let fileRoot = ChunkNode(recordID: 0, sectionType: .null, displayName: "test6.rm2", byteSize: 0, fileOffset: 0, children: [graphics, code])
        let index = AssetResolver.buildIndex(fileRoot: fileRoot)

        let defaultResolved = try XCTUnwrap(AssetResolver.resolveInstanceObject(objectID: 5, instanceSelector: 0, index: index))
        XCTAssertEqual(defaultResolved.recordID, 800)

        let selectedResolved = try XCTUnwrap(AssetResolver.resolveInstanceObject(objectID: 5, instanceSelector: 1, index: index))
        XCTAssertEqual(selectedResolved.recordID, 801)
    }

    /// The mandate's explicit fallback case: an `objectID` with no matching
    /// `GameObject` (or no usable link beyond it) must resolve to `nil`, so
    /// the caller draws its colored placeholder marker instead of
    /// fabricating geometry.
    func testResolveInstanceObjectReturnsNilWhenUnresolvable() {
        let index = GraphicsAssetIndex()
        XCTAssertNil(AssetResolver.resolveInstanceObject(objectID: 999, instanceSelector: 0, index: index))
    }
}
