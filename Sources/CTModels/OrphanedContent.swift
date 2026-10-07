import Foundation
import CTCore

/// Why `AssetResolver.scanForOrphans` flagged a record. Split into two
/// families: a *dangling reference* is a pointer to content that isn't
/// there, almost always the leftover of a deleted asset, while an
/// *unreferenced* record is content that's still fully present in the file
/// but that nothing in it points to, which is exactly what cut/prototype
/// content looks like once whatever used it was removed from the level.
public enum OrphanReason: String, Sendable, CaseIterable, Codable {
    case danglingMeshReference = "Dangling Mesh Reference"
    case danglingSkinReference = "Dangling Skin Reference"
    case unreferencedGeometry = "Unreferenced Geometry"
    case unreferencedSkeleton = "Unreferenced Skeleton"
    case unreferencedTexture = "Unreferenced Texture"
}

/// One flagged record from a `Scrapped Content Scanner` pass over a single
/// parsed file. `modelPreview`/`texturePreview` are populated only when
/// there's actually something to look at, a dangling reference has no live
/// target, so both stay `nil` and the UI shows it as a text-only entry.
public struct OrphanedAsset: Sendable, Identifiable, Codable {
    public let id = UUID()
    public var recordID: UInt32
    public var reason: OrphanReason
    public var displayName: String
    public var sourceLabel: String
    public var modelPreview: ResolvedModelAsset?
    public var texturePreview: TextureAsset?

    /// `id` is deliberately excluded, a fresh, per-session identity never
    /// meant to round-trip through `ScanCache`'s `Codable` persistence.
    /// Without this, the synthesized `Codable` conformance still tries to
    /// decode `id` against an immutable `let` (which can't be
    /// overwritten), harmless, but a real warning on every build.
    private enum CodingKeys: String, CodingKey {
        case recordID, reason, displayName, sourceLabel, modelPreview, texturePreview
    }

    public init(
        recordID: UInt32,
        reason: OrphanReason,
        displayName: String,
        sourceLabel: String,
        modelPreview: ResolvedModelAsset? = nil,
        texturePreview: TextureAsset? = nil
    ) {
        self.recordID = recordID
        self.reason = reason
        self.displayName = displayName
        self.sourceLabel = sourceLabel
        self.modelPreview = modelPreview
        self.texturePreview = texturePreview
    }
}

extension AssetResolver {
    /// The "Scrapped Content Scanner": walks one already-parsed file's
    /// `GraphicsAssetIndex` looking for two signs of cut content , 
    /// `RigidModel`/`GraphicsInfo` records whose `meshID`/`skinID` points at
    /// nothing (the referencing object was kept but its geometry was
    /// deleted), and raw `Model`/`Skin`/`Texture` records that exist in the
    /// file but that no surviving `RigidModel`/`Skin` submesh points back to
    /// (the geometry was kept but whatever placed it in the level was
    /// deleted). Every unreferenced mesh/skin is resurrected into a
    /// previewable `ResolvedModelAsset` on the spot, so orphaned content is
    /// immediately viewable rather than just reported.
    /// Real, reported bug: `scanForOrphans`, `resolveModels` (the Models Hub
    /// half of the same per-file scan), and `collectTextures` (the Textures
    /// Hub half) each used to build their own `GraphicsAssetIndex` from
    /// scratch, a full walk of the file's Graphics/Code section, even
    /// though they're always called back-to-back on the exact same
    /// `fileRoot`, in both `scanAllArchives`'s per-file scan and loose-file
    /// loading. For a full archive scan (500-700 files) that's ~3x more
    /// tree walks and dictionary rebuilds than necessary, and a real,
    /// measurable share of the reported multi-second scan delay. Taking the
    /// already-built `index` as a parameter, computed once per file by the
    /// caller, instead of rebuilding it here removes that redundancy.
    public static func scanForOrphans(index: GraphicsAssetIndex, sourceLabel: String) -> [OrphanedAsset] {
        var orphans: [OrphanedAsset] = []

        var referencedMeshIDs: Set<UInt32> = []
        var referencedSkinIDs: Set<UInt32> = []
        var referencedTextureIDs: Set<UInt32> = []

        for rigidModel in index.rigidModels.values {
            referencedMeshIDs.insert(rigidModel.meshID)
            for materialID in rigidModel.materialIDs {
                if let textureID = index.materials[materialID]?.primaryTextureID {
                    referencedTextureIDs.insert(textureID)
                }
            }
            guard index.models[rigidModel.meshID] == nil else { continue }
            orphans.append(OrphanedAsset(
                recordID: rigidModel.id,
                reason: .danglingMeshReference,
                displayName: "RigidModel #\(rigidModel.id) → missing Mesh #\(rigidModel.meshID)",
                sourceLabel: sourceLabel
            ))
        }

        for skin in index.skins.values {
            for submesh in skin.submeshes {
                guard let materialID = submesh.materialID else { continue }
                if let textureID = index.materials[materialID]?.primaryTextureID {
                    referencedTextureIDs.insert(textureID)
                }
            }
        }

        for skeleton in index.skeletons.values {
            referencedSkinIDs.insert(skeleton.skinID)
            guard index.skins[skeleton.skinID] == nil else { continue }
            orphans.append(OrphanedAsset(
                recordID: skeleton.id,
                reason: .danglingSkinReference,
                displayName: "Skeleton #\(skeleton.id) → missing Skin #\(skeleton.skinID)",
                sourceLabel: sourceLabel
            ))
        }

        for (meshID, mesh) in index.models where !referencedMeshIDs.contains(meshID) {
            let preview = ResolvedModelAsset(
                recordID: meshID,
                displayName: "\(sourceLabel), Orphaned Mesh #\(meshID)",
                mesh: mesh,
                submeshMaterials: mesh.submeshes.map { _ in ResolvedSubmeshMaterial() }
            )
            orphans.append(OrphanedAsset(
                recordID: meshID,
                reason: .unreferencedGeometry,
                displayName: "Mesh #\(meshID) (\(mesh.submeshes.count) submesh(es), \(mesh.totalVertexCount) verts, unused)",
                sourceLabel: sourceLabel,
                modelPreview: preview
            ))
        }

        for (skinID, skin) in index.skins where !referencedSkinIDs.contains(skinID) {
            let materials = skin.submeshes.map { submesh -> ResolvedSubmeshMaterial in
                guard let materialID = submesh.materialID else { return ResolvedSubmeshMaterial() }
                let textureID = index.materials[materialID]?.primaryTextureID
                let texture = textureID.flatMap { index.textures[$0] }
                return ResolvedSubmeshMaterial(materialID: materialID, textureID: textureID, texture: texture)
            }
            let preview = ResolvedModelAsset(
                recordID: skinID,
                displayName: "\(sourceLabel), Orphaned Skin #\(skinID)",
                mesh: skin,
                submeshMaterials: materials
            )
            orphans.append(OrphanedAsset(
                recordID: skinID,
                reason: .unreferencedSkeleton,
                displayName: "Skin #\(skinID) (\(skin.submeshes.count) submesh(es), \(skin.totalVertexCount) verts, unused)",
                sourceLabel: sourceLabel,
                modelPreview: preview
            ))
        }

        for (textureID, texture) in index.textures where !referencedTextureIDs.contains(textureID) {
            orphans.append(OrphanedAsset(
                recordID: textureID,
                reason: .unreferencedTexture,
                displayName: "Texture #\(textureID) (\(texture.width)×\(texture.height), unused)",
                sourceLabel: sourceLabel,
                texturePreview: texture
            ))
        }

        return orphans.sorted { ($0.reason.rawValue, $0.recordID) < ($1.reason.rawValue, $1.recordID) }
    }
}
