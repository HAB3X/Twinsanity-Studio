import Foundation
import CTModels

/// The `modcrateinfo.txt`/`modcratesettings.txt` metadata read back out of a
/// `.crate` mod package, the read-side counterpart to `CrateMetadata`,
/// which `CrateExporter` only writes. Field names and text format match the
/// real `CrateModLoader` convention `CrateExporter`'s doc comment already
/// verifies against `CrateModLoader-master/CrateModAPI/ModCrates.cs`.
public struct ModManifest: Equatable, Sendable {
    public var name: String
    public var description: String
    public var author: String
    public var version: String
    public var targetGame: String
    public var modLoaderVersion: String
    /// Every `layer<N>/` folder actually present in the archive's real zip
    /// listing, in ascending order, not assumed to be a contiguous
    /// `0..<count` run, since a real crate can modify e.g. only `layer0`
    /// and `layer2`.
    public var layerIndices: [Int]
    /// Game-specific properties from `modcratesettings.txt`, empty if that
    /// file isn't present in the archive.
    public var settings: [String: String]
    public var hasIcon: Bool
    /// "Nested Crate Support": where inside the archive `modcrateinfo.txt`
    /// actually sits (`CrateArchiveManager.manifestPrefix`), `""` for the
    /// overwhelmingly common case where it's at the zip root, or e.g.
    /// `"MyMod/"` when the whole crate was zipped with a wrapping folder.
    /// Every layer/asset lookup for this crate needs this same offset.
    public var nestedPath: String

    public init(
        name: String,
        description: String,
        author: String,
        version: String,
        targetGame: String,
        modLoaderVersion: String,
        layerIndices: [Int],
        settings: [String: String],
        hasIcon: Bool,
        nestedPath: String = ""
    ) {
        self.name = name
        self.description = description
        self.author = author
        self.version = version
        self.targetGame = targetGame
        self.modLoaderVersion = modLoaderVersion
        self.layerIndices = layerIndices
        self.settings = settings
        self.hasIcon = hasIcon
        self.nestedPath = nestedPath
    }

    /// "Crate Region Gating": `CrateModLoader` lets a game opt into
    /// checking a `GameRegion` settings key against the player's detected
    /// disc region, deactivating a crate that doesn't match
    /// (`Modder.ModCrateRegionCheck`, verified key *name* from the real
    /// source). The *values* are a per-game convention CrateModLoader
    /// leaves to each game's own region enum; this build has no verified
    /// real Crash Twinsanity `.crate` using this key to check its exact
    /// values against, so it defines them using this app's own
    /// already-established `GameRegion` raw values (`"NTSC-U"`/`"PAL"`/
    /// `"NTSC-J"`), a crate author targeting this app specifically needs
    /// to use these exact strings. `nil` when the crate declares no
    /// region (the common case, most crates work everywhere).
    public var declaredRegion: GameRegion? {
        settings["GameRegion"].flatMap { GameRegion(rawValue: $0) }
    }
}
