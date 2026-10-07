import Foundation
import CTCore
import CTModels
import CTParsers

/// Install-side counterpart to the Cross-Engine Texture Variant crate export
/// (`WorkspaceViewModel.exportCrossEngineTextureOverrideAsCrate`): reads a
/// `TextureOverride_<textureID>` crate setting (see `settingsKey(forTextureID:)`)
/// and its bundled `modassets/` texture (`ModAssetTexture`) back out,
/// re-encodes it into the *target* texture record's own real on-disk pixel
/// format (`TextureWriter.replacingPixelData`, PSMCT32/PSMT8 only, same
/// support matrix as everywhere else this codebase writes textures back),
/// and repackages a real `.BD`/`.BH` archive pair with that one entry
/// replaced (`ArchiveRepackager.repackage`, the same safe,
/// streams-everything-else-through pipeline `ArchiveRepackagerView` already
/// exposes for manual whole-entry replacement; the source archive is never
/// modified).
public enum CrateTextureOverrideInstaller {
    public enum InstallError: Error, LocalizedError {
        case entryNotFound(name: String)
        case assetMissingFromCrate(path: String)
        case unsupportedResourceReference(String)
        case textureRecordNotFound(textureID: UInt32, entryName: String)

        public var errorDescription: String? {
            switch self {
            case .entryNotFound(let name):
                return "This archive has no entry named \"\(name)\" to patch."
            case .assetMissingFromCrate(let path):
                return "This crate's settings reference a bundled asset at \"\(path)\", but that file isn't actually in the crate's modassets/ folder."
            case .unsupportedResourceReference(let raw):
                return "This crate's texture override setting (\"\(raw)\") isn't a bundled crate asset, only \"crate:\"-prefixed references (this app's own exporter output) are supported for install."
            case .textureRecordNotFound(let textureID, let entryName):
                return "Couldn't find texture record #\(textureID) inside \(entryName) to patch."
            }
        }
    }

    /// The settings-key convention `exportCrossEngineTextureOverrideAsCrate`
    /// uses for a submesh's real, on-disk texture record ID. This is an
    /// honest, app-specific key this build invented for its own Cross-Engine
    /// Texture Variant feature, not a real `CodeName` from any verified
    /// CrateModLoader Twinsanity mod (see `ModCrateSettings`'s own doc
    /// comment for why: this app has no equivalent of CrateModLoader's
    /// global "Mod Menu" property registry a real `CodeName` would come
    /// from).
    public static func settingsKey(forTextureID textureID: UInt32) -> String {
        "TextureOverride_\(textureID)"
    }

    /// Every `TextureOverride_<id>` key `manifest.settings` declares,
    /// parsed back into the texture IDs a real install would patch , 
    /// exposed separately from `install` so a caller (e.g. a future
    /// install-confirmation UI) can show what a crate is about to change
    /// without actually touching an archive.
    public static func declaredTextureOverrideIDs(in manifest: ModManifest) -> [UInt32] {
        manifest.settings.keys.compactMap { key -> UInt32? in
            guard key.hasPrefix("TextureOverride_") else { return nil }
            return UInt32(key.dropFirst("TextureOverride_".count))
        }.sorted()
    }

    /// Installs every texture override `manifest` declares into
    /// `targetEntryName` inside the archive at `bhURL`, writing a new
    /// `.BD`/`.BH` pair at `outputBH`/`outputBD`. Returns the number of
    /// texture records actually patched (`0` when the crate declares none , 
    /// callers should treat that as "nothing to do," not an error).
    ///
    /// Only `TwinsFileKind`-recognized entries (`.RM2`/`.SM2`/`.RMX`/
    /// `.SMX`) can be searched for a texture record, the same real chunk
    /// parsers (`RM2Parser`) every other read path in this codebase already
    /// uses, not a guess at the format.
    @discardableResult
    public static func install(
        crateURL: URL,
        manifest: ModManifest,
        targetEntryName: String,
        bhURL: URL,
        outputBH: URL,
        outputBD: URL
    ) throws -> Int {
        let overrideIDs = declaredTextureOverrideIDs(in: manifest)
        guard !overrideIDs.isEmpty else { return 0 }

        let index = try BDArchiveParser.readIndex(bhURL: bhURL)
        guard let entry = index.entries.first(where: { $0.name == targetEntryName }) else {
            throw InstallError.entryNotFound(name: targetEntryName)
        }
        var entryData = try BDArchiveParser.readEntryData(entry, index: index)
        let fileRoot = try RM2Parser.parse(data: entryData, fileKind: fileKind(forEntryNamed: targetEntryName), fileName: targetEntryName)

        var patchedCount = 0
        for textureID in overrideIDs {
            let key = settingsKey(forTextureID: textureID)
            guard let rawValue = manifest.settings[key] else { continue }
            guard rawValue.hasPrefix("crate:") else {
                throw InstallError.unsupportedResourceReference(rawValue)
            }
            let assetPath = manifest.nestedPath + String(rawValue.dropFirst("crate:".count))

            guard let node = findTextureNode(in: fileRoot, recordID: textureID),
                  case .texture(let originalTexture) = node.payload,
                  node.fileOffset >= 0, node.byteSize >= 0,
                  node.fileOffset + node.byteSize <= entryData.count
            else {
                throw InstallError.textureRecordNotFound(textureID: textureID, entryName: targetEntryName)
            }

            let assetData: Data
            do {
                assetData = try CrateArchiveManager.extractedFileData(assetPath, from: crateURL)
            } catch {
                throw InstallError.assetMissingFromCrate(path: assetPath)
            }
            let bundledTexture = try ModAssetTexture.deserialize(assetData)
            let resizedRGBA = ModAssetTexture.resizedRGBA(bundledTexture, toWidth: originalTexture.width, height: originalTexture.height)
            let replacement = TextureAsset(
                id: originalTexture.id,
                width: originalTexture.width,
                height: originalTexture.height,
                pixelFormat: originalTexture.pixelFormat,
                rgba: resizedRGBA
            )

            let originalRecordBytes = entryData.subdata(in: node.fileOffset..<(node.fileOffset + node.byteSize))
            let newRecordBytes = try TextureWriter.replacingPixelData(of: replacement, inOriginalRecordBytes: originalRecordBytes)
            entryData.replaceSubrange(node.fileOffset..<(node.fileOffset + node.byteSize), with: newRecordBytes)
            patchedCount += 1
        }

        guard patchedCount > 0 else { return 0 }
        try ArchiveRepackager.repackage(index: index, replacements: [targetEntryName: entryData], outputBH: outputBH, outputBD: outputBD)
        return patchedCount
    }

    /// Depth-first search for a `.texture` payload whose own `TextureAsset.
    /// id` matches `recordID`, the same "walk the real chunk tree, don't
    /// assume a flat layout" approach `AssetResolver.buildIndex` uses when
    /// collecting every texture in a file, just narrowed to one target ID
    /// instead of building a full index (this only ever needs one record).
    private static func findTextureNode(in node: ChunkNode, recordID: UInt32) -> ChunkNode? {
        if case .texture(let asset) = node.payload, asset.id == recordID { return node }
        for child in node.children {
            if let found = findTextureNode(in: child, recordID: recordID) { return found }
        }
        return nil
    }

    /// Mirrors `WorkspaceViewModel.fileKind(forEntryNamed:)`'s own
    /// extension -> `TwinsFileKind` mapping, duplicated rather than
    /// shared because that one is `private` and `@MainActor`-adjacent
    /// (part of `WorkspaceViewModel`), where this installer is deliberately
    /// workspace-independent (it operates on a `.BH`/`.BD` pair and a
    /// crate directly, the same way `ArchiveRepackagerView`'s own
    /// standalone repackaging flow does).
    private static func fileKind(forEntryNamed name: String) -> TwinsFileKind {
        switch (name as NSString).pathExtension.uppercased() {
        case "RMX": return .rmx
        case "SMX": return .smx
        case "SM2": return .sm2
        default: return .rm2
        }
    }
}
