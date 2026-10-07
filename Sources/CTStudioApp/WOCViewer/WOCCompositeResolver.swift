import Foundation
import CTModels

/// The WoC counterpart to `AssetResolver.resolveComposite` (original
/// Twinsanity `.RM2`/`.SM2`) -- "View Parent / Composite" on a texture
/// decoded from a `.GSC` level (e.g. `CRATES.GSC`) always came back "No
/// Parent Found", because `AssetResolver` only understands the RM2/SM2
/// `ChunkNode` shape (a `Graphics`/`Code` section pair) and
/// `WOCDiscTreeBuilder` builds WoC's tree with none of that shape --
/// "Textures" and "Placed Objects" are flat sibling folders with no
/// reference IDs carried into the `ChunkNode`/`ChunkPayload` at all.
///
/// The real reference chain was already decoded, just never wired past
/// `WOCLevelAsset` into anything that could answer "what uses this
/// texture": `OBJ0`'s per-entry meshes (`WOCLevelAsset.objectMeshes`,
/// indexed the same way `INST.objectIndex` is) carry a real per-submesh
/// `materialID` (an `MS00` record index -- see `WOCMeshDecoder`'s doc
/// comment), and `WOCLevelAsset.materialTextureIDs` is `MS00`'s own real
/// per-record texture reference (confirmed offset 424 -- see
/// `WOCContainerParser.parseMaterialSet`'s doc comment), indexed by that
/// same `materialID`. Chaining those two real, confirmed tables answers
/// "which mesh's material points at this texture index" directly.
///
/// **Caveat carried over from `WOCMeshDecoder`**: real per-vertex UVs
/// aren't decoded for WoC meshes -- every `StaticVertex.uv` here is the
/// honest `.zero` default, not a fabricated mapping. The mesh geometry and
/// the texture-to-material link this resolves are both real; the texture
/// won't appear correctly wrapped onto the mesh's surface the way an
/// original-format composite does.
enum WOCCompositeResolver {
    /// `textureIndex` is `WOCDecodedTexture.id` / the `ChunkNode.recordID`
    /// `WOCDiscTreeBuilder` gives each texture leaf -- both are the same
    /// value, that texture's index into `WOCLevelAsset.textures`. Returns
    /// the first `OBJ0` entry with a submesh whose `materialID` maps (via
    /// `materialTextureIDs`) to this texture; `nil` when nothing in this
    /// level's decoded materials references it (a real "nothing found",
    /// not a resolver failure -- some textures genuinely are only
    /// referenced by structures this codebase hasn't decoded yet, e.g. a
    /// `.faceon`/billboard record).
    static func resolveComposite(forTextureIndex textureIndex: Int, in asset: WOCLevelAsset, displayNamePrefix: String) -> ResolvedModelAsset? {
        guard textureIndex >= 0, textureIndex < asset.textures.count else { return nil }
        let texture = asset.textures[textureIndex]
        guard !texture.rgba.isEmpty else { return nil }
        let textureAsset = TextureAsset(id: UInt32(texture.id), width: texture.width, height: texture.height, pixelFormat: .rawRGBA, rgba: texture.rgba)

        for (entryIndex, mesh) in asset.objectMeshes.enumerated() {
            var materials: [ResolvedSubmeshMaterial] = []
            var matched = false
            for submesh in mesh.submeshes {
                guard let materialID = submesh.materialID,
                      Int(materialID) < asset.materialTextureIDs.count,
                      asset.materialTextureIDs[Int(materialID)] == textureIndex
                else {
                    materials.append(ResolvedSubmeshMaterial())
                    continue
                }
                matched = true
                materials.append(ResolvedSubmeshMaterial(materialID: materialID, textureID: UInt32(textureIndex), texture: textureAsset))
            }
            guard matched else { continue }
            let placementCount = asset.objects.filter { $0.objectIndex == UInt32(entryIndex) }.count
            let placementSuffix = placementCount > 0 ? " (\(placementCount) placement\(placementCount == 1 ? "" : "s"))" : " (unplaced)"
            return ResolvedModelAsset(
                recordID: UInt32(entryIndex),
                displayName: "\(displayNamePrefix)Object #\(entryIndex)\(placementSuffix)",
                mesh: mesh,
                submeshMaterials: materials
            )
        }
        return nil
    }
}
