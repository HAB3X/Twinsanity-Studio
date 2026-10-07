import Foundation

/// One node in a composite object's relational chain, a mesh, material,
/// texture, skeleton, or animation that's part of the same
/// `ResolvedModelAsset` as whatever the user actually selected. Distinct
/// from `ChunkPayload.Kind`: that's a coarse *browsing* category (several
/// `SectionType`s bucketed together); this is "this specific record is
/// part of this specific composite object," derived from an already-
/// resolved asset rather than re-walking the chunk tree.
public struct LinkedComponent: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable {
        case mesh = "Mesh"
        case material = "Material"
        case texture = "Texture"
        case skeleton = "Skeleton"
        case animation = "Animation"
    }

    public var id: String { "\(kind.rawValue)-\(recordID)" }
    public var kind: Kind
    public var recordID: UInt32
    public var displayName: String
    /// Populated only for `.material`/`.texture` entries, *every* submesh
    /// index (into `ResolvedModelAsset.mesh.submeshes`) that uses this
    /// material/texture, not just the first. A texture shared by several
    /// submeshes must hide all of them when toggled off, or "uncheck this
    /// texture" would silently only affect one of the places it's actually
    /// used (see `ModelViewerRenderer.hiddenSubmeshIndices`).
    public var submeshIndices: [Int]

    public init(kind: Kind, recordID: UInt32, displayName: String, submeshIndices: [Int] = []) {
        self.kind = kind
        self.recordID = recordID
        self.displayName = displayName
        self.submeshIndices = submeshIndices
    }
}

/// "Deep Hierarchy & Linked Asset Resolution": the full relational picture
/// around a selected node, its parent composite object, if any, and every
/// component that composite is built from.
public struct RelationalChain: Sendable {
    public var parentRecordID: UInt32
    public var parentDisplayName: String
    public var components: [LinkedComponent]

    public init(parentRecordID: UInt32, parentDisplayName: String, components: [LinkedComponent]) {
        self.parentRecordID = parentRecordID
        self.parentDisplayName = parentDisplayName
        self.components = components
    }

    /// Builds a chain from an already-resolved composite asset, every
    /// submesh's material/texture (skipped when unresolved), the shared
    /// mesh record, the skeleton (if rigged), and every candidate animation.
    public init(asset: ResolvedModelAsset) {
        self.parentRecordID = asset.recordID
        self.parentDisplayName = asset.displayName
        var components: [LinkedComponent] = [
            LinkedComponent(kind: .mesh, recordID: asset.mesh.id, displayName: "Mesh #\(asset.mesh.id)")
        ]
        // Every submesh index that uses each material/texture ID, keyed by
        // ID, a shared texture must report *all* its submeshes so
        // visibility toggling (which operates per-submesh on the GPU side)
        // hides every place it's actually used, not just the first.
        var materialSubmeshes: [UInt32: [Int]] = [:]
        var textureSubmeshes: [UInt32: [Int]] = [:]
        var materialOrder: [UInt32] = []
        var textureOrder: [UInt32] = []
        for (index, submeshMaterial) in asset.submeshMaterials.enumerated() {
            if let materialID = submeshMaterial.materialID {
                if materialSubmeshes[materialID] == nil { materialOrder.append(materialID) }
                materialSubmeshes[materialID, default: []].append(index)
            }
            if let textureID = submeshMaterial.textureID {
                if textureSubmeshes[textureID] == nil { textureOrder.append(textureID) }
                textureSubmeshes[textureID, default: []].append(index)
            }
        }
        for materialID in materialOrder {
            components.append(LinkedComponent(kind: .material, recordID: materialID, displayName: "Material #\(materialID)", submeshIndices: materialSubmeshes[materialID] ?? []))
        }
        for textureID in textureOrder {
            components.append(LinkedComponent(kind: .texture, recordID: textureID, displayName: "Texture #\(textureID)", submeshIndices: textureSubmeshes[textureID] ?? []))
        }
        if let skeleton = asset.skeleton {
            components.append(LinkedComponent(kind: .skeleton, recordID: skeleton.id, displayName: "Skeleton #\(skeleton.id) (\(skeleton.joints.count) joints)"))
        }
        for animation in asset.availableAnimations.sorted(by: { $0.id < $1.id }) {
            components.append(LinkedComponent(kind: .animation, recordID: animation.id, displayName: "Animation #\(animation.id)"))
        }
        self.components = components
    }
}
