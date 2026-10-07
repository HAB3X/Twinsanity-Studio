import Foundation
import CTCore

/// ID-keyed lookup tables built from one parsed file's `Graphics`/`Code`
/// sections, the "linked asset resolution" step. On disk, a mesh, its
/// materials, its textures, and its skeleton are independent chunk records
/// that only reference each other by numeric ID (`RigidModel.meshID`,
/// `Material.shader.textureId`, `GraphicsInfo.skinID`, ...); nothing in the
/// chunk tree itself groups them into one logical asset. This index exists
/// so that grouping can happen once, in one place, instead of ad hoc ID
/// lookups scattered through UI code.
public struct GraphicsAssetIndex: Sendable {
    public var textures: [UInt32: TextureAsset] = [:]
    public var materials: [UInt32: MaterialInfo] = [:]
    /// Rigid (non-skinned) geometry, keyed by its record ID in the `Model` section.
    public var models: [UInt32: MeshAsset] = [:]
    /// Skinned geometry, keyed by its record ID in the `Skin` section.
    public var skins: [UInt32: MeshAsset] = [:]
    public var rigidModels: [UInt32: RigidModelInfo] = [:]
    /// `LodModel` records, keyed by their own ID, a scenery placement's
    /// `modelID` can point here instead of directly into `rigidModels`.
    /// See `LodModelInfo`'s doc comment; use `AssetResolver.resolveModelID`
    /// rather than indexing `rigidModels` directly so both cases resolve.
    public var lodModels: [UInt32: LodModelInfo] = [:]
    public var skeletons: [UInt32: SkeletonAsset] = [:]
    public var animations: [UInt32: AnimationAsset] = [:]
    /// `GameObject` records, keyed by their own ID, `Instance.objectID`
    /// looks up into this. "Comprehensive Instance Population" (Part 4B).
    public var gameObjects: [UInt32: GameObjectInfo] = [:]

    public init() {}
}

/// One submesh's resolved texture, if its material/texture chain resolved
/// successfully. Aligned index-for-index with `ResolvedModelAsset.mesh.submeshes`.
public struct ResolvedSubmeshMaterial: Sendable, Codable {
    public var materialID: UInt32?
    public var textureID: UInt32?
    public var texture: TextureAsset?

    public init(materialID: UInt32? = nil, textureID: UInt32? = nil, texture: TextureAsset? = nil) {
        self.materialID = materialID
        self.textureID = textureID
        self.texture = texture
    }
}

/// A mesh bound together with everything needed to actually render it: a
/// resolved texture per submesh, and, for rigged characters, the skeleton
/// and the animations available to preview against it. This is the single
/// logical asset the Model Viewer renders, replacing the "mesh here, texture
/// floating separately over there" experience of browsing raw chunk records.
public struct ResolvedModelAsset: Sendable, Identifiable, Codable {
    /// Synthesized, globally unique, deliberately *not* `recordID`.
    /// RigidModel IDs and Skeleton IDs are independent on-disk namespaces
    /// (a RigidModel and a Skeleton can legitimately share the same numeric
    /// ID), and a global list aggregating results from hundreds of files
    /// will see the same `recordID` recur constantly. Using `recordID`
    /// itself as `Identifiable.id` would make SwiftUI's list/sheet identity
    /// tracking silently collide across unrelated models.
    public var id = UUID()
    public let recordID: UInt32
    public var displayName: String
    public var mesh: MeshAsset
    public var submeshMaterials: [ResolvedSubmeshMaterial]
    public var skeleton: SkeletonAsset?
    public var availableAnimations: [AnimationAsset]

    public init(
        recordID: UInt32,
        displayName: String,
        mesh: MeshAsset,
        submeshMaterials: [ResolvedSubmeshMaterial],
        skeleton: SkeletonAsset? = nil,
        availableAnimations: [AnimationAsset] = []
    ) {
        self.recordID = recordID
        self.displayName = displayName
        self.mesh = mesh
        self.submeshMaterials = submeshMaterials
        self.skeleton = skeleton
        self.availableAnimations = availableAnimations
    }

    public var isFullyTextured: Bool { submeshMaterials.allSatisfy { $0.texture != nil } }

    /// A real, disk-untouched **visual-only** texture override: every
    /// submesh keeps its own real `materialID`/`textureID`, only
    /// `texture` (the actual pixel data the renderer samples) changes.
    /// Mesh geometry, `skeleton`, and `availableAnimations` are identical
    /// to `self`, this never touches collision data, `PlacedInstance`/
    /// `GameObjectInfo` entity data, or any on-disk record, since none of
    /// that lives on `ResolvedModelAsset` in the first place. Built for
    /// "Cross-Engine Texture Variant" (previewing a real Wrath of Cortex
    /// crate texture on a Twinsanity crate's own real, working UVs,
    /// sidestepping WoC's still-undecoded per-vertex UV data entirely , 
    /// see `WOCCompositeResolver`'s own doc comment for that gap): call
    /// with a real decoded `TextureAsset` to preview it, or `nil` to
    /// revert to every submesh's own original texture.
    public func applyingTextureOverride(_ overrideTexture: TextureAsset?) -> ResolvedModelAsset {
        var copy = self
        copy.id = UUID() // a real, distinct preview asset, not the same identity as the un-overridden original
        copy.submeshMaterials = submeshMaterials.map { material in
            var m = material
            m.texture = overrideTexture ?? material.texture
            return m
        }
        return copy
    }
}

public enum AssetResolver {
    private static let graphicsSectionTypes: Set<SectionType> = [.graphics, .graphicsX, .graphicsD]
    private static let codeSectionTypes: Set<SectionType> = [.code, .codeX, .codeDemo]

    /// Builds a `GraphicsAssetIndex` from a parsed file's root node (the
    /// node representing a whole `.RM2`/`.SM2`, whose direct children
    /// include the top-level `Graphics` and `Code` sections).
    public static func buildIndex(fileRoot: ChunkNode) -> GraphicsAssetIndex {
        var index = GraphicsAssetIndex()

        if let graphics = fileRoot.children.first(where: { graphicsSectionTypes.contains($0.sectionType) }) {
            for section in graphics.children {
                for leaf in section.children {
                    guard let payload = leaf.payload else { continue }
                    switch payload {
                    case .texture(let texture):
                        index.textures[leaf.recordID] = texture
                    case .material(let material):
                        index.materials[leaf.recordID] = material
                    case .mesh(let mesh):
                        if mesh.isSkinned {
                            index.skins[leaf.recordID] = mesh
                        } else {
                            index.models[leaf.recordID] = mesh
                        }
                    case .rigidModel(let rigidModel):
                        index.rigidModels[leaf.recordID] = rigidModel
                    case .lodModel(let lodModel):
                        index.lodModels[leaf.recordID] = lodModel
                    case .skeleton, .animation, .position, .instance, .trigger, .camera, .collision, .scenery, .dynamicScenery, .soundEffect, .soundEffectX, .gameObject, .chunkLinks, .aiPosition, .aiPath, .collisionSurface, .skydome, .path, .particleData, .script, .raw, .instanceTemplate, .instanceTemplateDemo, .instanceDemo, .instanceMB,
                         .xboxModel, .xboxSkin, .xboxBlendSkin, .customAgent:
                        // Real, decoded (see `XboxMeshAssets.swift`), but not yet
                        // wired into `GraphicsAssetIndex`/the render pipeline , 
                        // this pass's scope was decoding the real vertex data,
                        // not building the material/texture resolution and
                        // Metal upload path a renderable `ResolvedModelAsset`
                        // needs (a materially larger, separate piece of work).
                        break
                    }
                }
            }
        }

        if let code = fileRoot.children.first(where: { codeSectionTypes.contains($0.sectionType) }) {
            if let ogi = code.children.first(where: { $0.sectionType == .ogi }) {
                for leaf in ogi.children {
                    if case .skeleton(let skeleton) = leaf.payload {
                        index.skeletons[leaf.recordID] = skeleton
                    }
                }
            }
            if let animationSection = code.children.first(where: { $0.sectionType == .animation }) {
                for leaf in animationSection.children {
                    if case .animation(let animation) = leaf.payload {
                        index.animations[leaf.recordID] = animation
                    }
                }
            }
            if let objectSection = code.children.first(where: { $0.sectionType == .object }) {
                for leaf in objectSection.children {
                    if case .gameObject(let gameObject) = leaf.payload {
                        index.gameObjects[leaf.recordID] = gameObject
                    }
                }
            }
        }

        return index
    }

    /// Resolves a static/rigid `RigidModel` into a fully textured mesh:
    /// geometry via `meshID`, and per-submesh textures via
    /// `materialIDs[i]`, `RigidModel.materialIDs` and the mesh's submeshes
    /// are parallel arrays (same index order), matching how the original
    /// engine associates them (`RigidModel.cs`).
    public static func resolveRigidModel(_ rigidModel: RigidModelInfo, displayName: String, index: GraphicsAssetIndex) -> ResolvedModelAsset? {
        guard let mesh = index.models[rigidModel.meshID] else { return nil }
        var materials: [ResolvedSubmeshMaterial] = []
        materials.reserveCapacity(mesh.submeshes.count)
        for i in mesh.submeshes.indices {
            guard i < rigidModel.materialIDs.count else {
                materials.append(ResolvedSubmeshMaterial())
                continue
            }
            let materialID = rigidModel.materialIDs[i]
            let textureID = index.materials[materialID]?.primaryTextureID
            let texture = textureID.flatMap { index.textures[$0] }
            materials.append(ResolvedSubmeshMaterial(materialID: materialID, textureID: textureID, texture: texture))
        }
        return ResolvedModelAsset(recordID: rigidModel.id, displayName: displayName, mesh: mesh, submeshMaterials: materials)
    }

    /// Resolves a `modelID` that may reference either a `RigidModel`
    /// directly or a `LodModel` indirection (see `LodModelInfo`'s doc
    /// comment for the real, verified evidence this indirection exists , 
    /// scenery placements otherwise silently vanish). Tries every
    /// `lodModelIDs` entry in order (highest detail first) rather than
    /// only the first, since real data has entries whose *first* LOD
    /// doesn't resolve but a lower-detail one does; `depth` guards against
    /// a malformed/cyclic chain (a `LodModel` pointing at another
    /// `LodModel`) rather than assuming one level of indirection is
    /// always enough.
    public static func resolveModelID(_ modelID: UInt32, displayName: String, index: GraphicsAssetIndex, depth: Int = 0) -> ResolvedModelAsset? {
        if let rigidModel = index.rigidModels[modelID] {
            return resolveRigidModel(rigidModel, displayName: displayName, index: index)
        }
        guard depth < 4, let lodModel = index.lodModels[modelID] else { return nil }
        for candidateID in lodModel.lodModelIDs {
            if let resolved = resolveModelID(candidateID, displayName: displayName, index: index, depth: depth + 1) {
                return resolved
            }
        }
        return nil
    }

    /// Resolves a rigged character via its `GraphicsInfo` skeleton:
    /// geometry via `skinID`. Unlike `RigidModel`, a `Skin` record carries
    /// its material ID *per submesh* directly (already decoded onto
    /// `MeshSubmesh.materialID` by `SkinParser`), so no parallel array
    /// lookup is needed here. Every decoded `Animation` in the same file's
    /// `Code` section is offered as a preview candidate, the format has no
    /// stored link from a specific animation to a specific skeleton (that
    /// association lives in the undecoded `Object`/`Script` game-logic
    /// layer), so "same file" is the best available heuristic.
    public static func resolveSkeleton(_ skeleton: SkeletonAsset, displayName: String, index: GraphicsAssetIndex) -> ResolvedModelAsset? {
        guard let mesh = index.skins[skeleton.skinID] else { return nil }
        let materials = mesh.submeshes.map { submesh -> ResolvedSubmeshMaterial in
            guard let materialID = submesh.materialID else { return ResolvedSubmeshMaterial() }
            let textureID = index.materials[materialID]?.primaryTextureID
            let texture = textureID.flatMap { index.textures[$0] }
            return ResolvedSubmeshMaterial(materialID: materialID, textureID: textureID, texture: texture)
        }
        let animations = Array(index.animations.values)
        return ResolvedModelAsset(recordID: skeleton.id, displayName: displayName, mesh: mesh, submeshMaterials: materials, skeleton: skeleton, availableAnimations: animations)
    }

    /// Resolves a rigid part attached to a joint via `GraphicsInfo.
    /// modelLinks` (`GI.ModelIDs` in the reference), the mechanism a
    /// non-skinned prop (a crate, a fruit, a switch, anything simple
    /// enough not to need smooth per-vertex skin weights) uses instead of
    /// `skinID`: one or more independent `RigidModel` parts, each nominally
    /// attached to a specific joint. Every part is merged into one
    /// `ResolvedModelAsset` (concatenated submeshes/materials) so the
    /// caller gets a single drawable object per `Instance`, same as the
    /// skinned path.
    ///
    /// Deliberately positions every part at the object's own local origin,
    /// **not** offset by that joint's own local transform (`RMViewer.cs`'s
    /// `LocalRot`, built from `SkinTransforms[jointIndex]`/`Joints[jointIndex]
    /// .Matrix[1]`), this build's already-established simplification for
    /// joint-relative placement (see `ModelViewerRenderer`'s bind-pose
    /// skeleton doc comments) extended to this new path rather than
    /// guessing at a second, independently-unverified matrix-slot meaning
    /// on top of the ones Part 3 already confirmed. For a single-part prop
    /// (the overwhelming common case, a crate, a fruit, a single pickup)
    /// this has no visible effect at all, since there's only one part and
    /// it belongs at the instance's own position regardless.
    public static func resolveModelLinks(_ skeleton: SkeletonAsset, displayName: String, index: GraphicsAssetIndex) -> ResolvedModelAsset? {
        guard !skeleton.modelLinks.isEmpty else { return nil }
        var mergedSubmeshes: [MeshSubmesh] = []
        var mergedMaterials: [ResolvedSubmeshMaterial] = []
        for link in skeleton.modelLinks {
            guard let rigidModel = index.rigidModels[link.modelID],
                  let resolvedPart = resolveRigidModel(rigidModel, displayName: displayName, index: index)
            else { continue }
            mergedSubmeshes.append(contentsOf: resolvedPart.mesh.submeshes)
            mergedMaterials.append(contentsOf: resolvedPart.submeshMaterials)
        }
        guard !mergedSubmeshes.isEmpty else { return nil }
        let mesh = MeshAsset(id: skeleton.id, isSkinned: false, submeshes: mergedSubmeshes)
        return ResolvedModelAsset(recordID: skeleton.id, displayName: displayName, mesh: mesh, submeshMaterials: mergedMaterials)
    }

    /// "Comprehensive Instance Population" (Part 4B): resolves an
    /// `Instance.objectID` all the way to real, drawable geometry, the
    /// exact chain `RMViewer.cs`'s own instance-rendering path uses
    /// (`GameObject` lookup by `ObjectID`, pick an `OGIs` entry, then
    /// either a skinned character via `skinID` or one-or-more rigid parts
    /// via `modelLinks`), ported field-for-field including the `OGIs`
    /// index-selection quirk: index 0 is the default, but
    /// `instanceSelector` (the *Instance* record's own third unknown
    /// trailing list, `unknownUInt32List2[0]`, `ins.UnkI323[0]` in the
    /// reference), when non-zero and in range, picks a different `OGIs`
    /// entry instead. `nil` whenever any link in this chain doesn't
    /// resolve (no matching `GameObject`, no usable `OGIs` entry, neither
    /// `skinID` nor `modelLinks` resolves to real geometry), the caller's
    /// fallback to a colored placeholder marker for exactly this case is
    /// what the "comprehensive population" mandate itself asks for.
    ///
    /// `defaultIndex`, when provided, is tried only if `index` (the
    /// level's own file) has no match, ported from `RMViewer.cs`'s own
    /// `file.DataDefault`/`DefaultCont` fallback: common objects reused
    /// across many levels (crates, gems, and other shared pickups/props)
    /// are defined once in a shared resource file (the real disc's
    /// `Startup/Default.rm2`, confirmed against the actual archive, not
    /// guessed at) rather than duplicated into every level that uses them.
    /// The reference tool's fallback branch re-reads `OGIs[0]` directly in
    /// the default file rather than repeating the `instanceSelector`
    /// indexing, a real, deliberate asymmetry in the source, not an
    /// oversight here.
    public static func resolveInstanceObject(objectID: UInt16, instanceSelector: UInt32, index: GraphicsAssetIndex, defaultIndex: GraphicsAssetIndex? = nil) -> ResolvedModelAsset? {
        if let resolved = resolveInstanceObject(objectID: objectID, instanceSelector: instanceSelector, inSingleIndex: index) {
            return resolved
        }
        guard let defaultIndex else { return nil }
        return resolveInstanceObject(objectID: objectID, instanceSelector: 0, inSingleIndex: defaultIndex)
    }

    /// Same resolution as `resolveInstanceObject(objectID:instanceSelector:index:defaultIndex:)`
    /// above, but also reports whether the result came from `index` or had
    /// to fall back to `defaultIndex`, computed as a byproduct of the
    /// *same* resolve pass (reusing the private `inSingleIndex` helper
    /// directly) instead of a callers having to run a second, redundant
    /// resolve just to find out. Added for `WorkspaceViewModel.
    /// resolvedInstanceAssets`'s "which markers are safe for the
    /// persistent, cross-level GPU cache" classification, which previously
    /// re-ran the full resolve a second time per marker (real, measured
    /// cost, `resolveSkeleton`/`resolveModelLinks` allocate fresh
    /// submesh/material arrays on every hit) purely to answer this.
    public static func resolveInstanceObjectReportingSource(objectID: UInt16, instanceSelector: UInt32, index: GraphicsAssetIndex, defaultIndex: GraphicsAssetIndex?) -> (asset: ResolvedModelAsset, viaSharedDefault: Bool)? {
        if let resolved = resolveInstanceObject(objectID: objectID, instanceSelector: instanceSelector, inSingleIndex: index) {
            return (resolved, false)
        }
        guard let defaultIndex, let resolved = resolveInstanceObject(objectID: objectID, instanceSelector: 0, inSingleIndex: defaultIndex) else { return nil }
        return (resolved, true)
    }

    private static func resolveInstanceObject(objectID: UInt16, instanceSelector: UInt32, inSingleIndex index: GraphicsAssetIndex) -> ResolvedModelAsset? {
        let noValue: UInt32 = 65535
        guard let gameObject = index.gameObjects[UInt32(objectID)],
              !gameObject.ogiIDs.isEmpty, gameObject.ogiIDs[0] != noValue
        else { return nil }

        var targetOGI = gameObject.ogiIDs[0]
        if instanceSelector != 0,
           gameObject.ogiIDs.count > Int(instanceSelector),
           gameObject.ogiIDs[Int(instanceSelector)] != noValue {
            targetOGI = gameObject.ogiIDs[Int(instanceSelector)]
        }

        guard let skeleton = index.skeletons[targetOGI] else { return nil }
        let displayName = "Object #\(objectID) (\(gameObject.name))"

        if skeleton.skinID != 0, index.skins[skeleton.skinID] != nil {
            return resolveSkeleton(skeleton, displayName: displayName, index: index)
        }
        return resolveModelLinks(skeleton, displayName: displayName, index: index)
    }

    /// Resolves *any* composite-eligible node, not just a `RigidModel`/
    /// `GraphicsInfo` link record itself, but any of the components it's
    /// built from (a raw `Model`/`Skin` mesh, a `Material`, a `Texture`, or
    /// an `Animation`), into the same complete `ResolvedModelAsset` its
    /// parent resolves to. This is what makes "select an isolated texture,
    /// see the whole character it belongs to" possible: rather than a
    /// texture knowing its own parent, this walks the same index every
    /// other resolution path already builds and asks "what points at me?"
    ///
    /// `nil` means either this node's `payload` kind was never linkable
    /// (e.g. a `Position`/`Trigger`) or nothing in this file's Graphics/Code
    /// sections currently references it, the latter is exactly what the
    /// Scrapped Content Scanner (`scanForOrphans`) flags separately.
    public static func resolveComposite(for node: ChunkNode, fileRoot: ChunkNode, displayNamePrefix: String) -> ResolvedModelAsset? {
        let index = buildIndex(fileRoot: fileRoot)

        switch node.payload {
        case .rigidModel(let rigidModel):
            return resolveRigidModel(rigidModel, displayName: displayNamePrefix + node.displayName, index: index)

        case .skeleton(let skeleton):
            return resolveSkeleton(skeleton, displayName: displayNamePrefix + node.displayName, index: index)

        case .mesh:
            // A raw `Model`/`Skin` geometry record: found by which link
            // record's meshID/skinID points at it, not by its own ID.
            if let rigidModel = index.rigidModels.values.first(where: { $0.meshID == node.recordID }) {
                return resolveRigidModel(rigidModel, displayName: displayNamePrefix + "Object #\(rigidModel.id)", index: index)
            }
            if let skeleton = index.skeletons.values.first(where: { $0.skinID == node.recordID }) {
                return resolveSkeleton(skeleton, displayName: displayNamePrefix + "Character #\(skeleton.id)", index: index)
            }
            return nil

        case .texture, .material:
            let materialID: UInt32?
            if case .texture = node.payload {
                materialID = index.materials.first(where: { $0.value.primaryTextureID == node.recordID })?.key
            } else {
                materialID = node.recordID
            }
            guard let materialID else { return nil }
            if let rigidModel = index.rigidModels.values.first(where: { $0.materialIDs.contains(materialID) }) {
                return resolveRigidModel(rigidModel, displayName: displayNamePrefix + "Object #\(rigidModel.id)", index: index)
            }
            if let skinEntry = index.skins.first(where: { $0.value.submeshes.contains { $0.materialID == materialID } }),
               let skeleton = index.skeletons.values.first(where: { $0.skinID == skinEntry.key }) {
                return resolveSkeleton(skeleton, displayName: displayNamePrefix + "Character #\(skeleton.id)", index: index)
            }
            return nil

        case .animation:
            // No stored link from an animation to a specific skeleton (see
            // `resolveSkeleton`'s doc comment), "the first skeleton in the
            // same file" is the same heuristic used to offer animations as
            // preview candidates in the first place.
            guard let skeleton = index.skeletons.values.first else { return nil }
            return resolveSkeleton(skeleton, displayName: displayNamePrefix + "Character #\(skeleton.id)", index: index)

        default:
            return nil
        }
    }

    /// Same "what points at me?" reverse lookup as
    /// `resolveComposite(for:fileRoot:displayNamePrefix:)`'s `.texture`
    /// case, callable directly from a texture's own record ID rather than
    /// requiring its `ChunkNode`, for callers (like the Textures Hub)
    /// that only have a `TextureAsset.id` in hand, not the node it came
    /// from (`TextureAsset.id` is always populated from the same
    /// `recordID` a `.texture`-payload `ChunkNode` would carry, so this is
    /// the exact same lookup, not an approximation).
    public static func resolveComposite(forTextureID textureID: UInt32, fileRoot: ChunkNode, displayNamePrefix: String) -> ResolvedModelAsset? {
        let index = buildIndex(fileRoot: fileRoot)
        guard let materialID = index.materials.first(where: { $0.value.primaryTextureID == textureID })?.key else { return nil }
        if let rigidModel = index.rigidModels.values.first(where: { $0.materialIDs.contains(materialID) }) {
            return resolveRigidModel(rigidModel, displayName: displayNamePrefix + "Object #\(rigidModel.id)", index: index)
        }
        if let skinEntry = index.skins.first(where: { $0.value.submeshes.contains { $0.materialID == materialID } }),
           let skeleton = index.skeletons.values.first(where: { $0.skinID == skinEntry.key }) {
            return resolveSkeleton(skeleton, displayName: displayNamePrefix + "Character #\(skeleton.id)", index: index)
        }
        return nil
    }
}
