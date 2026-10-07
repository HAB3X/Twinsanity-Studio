import Foundation

/// Parses the real `CrateModLoader` `modcrateinfo.txt`/`modcratesettings.txt`
/// key=value text format, the read-side counterpart to `CrateExporter`'s
/// writer, same `=` separator and `!` comment-line convention.
public enum ModManifestParser {
    private static let commentPrefix = "!"
    private static let separator: Character = "="

    /// Splits on the *first* `=` only, not `components(separatedBy:)` with
    /// an exact count of 2, a value containing its own `=` (which
    /// `CrateExporter`'s own writer strips on export, but a real
    /// third-party crate isn't guaranteed to) would otherwise silently drop
    /// the whole line instead of just losing precision on where the value
    /// starts.
    static func parseKeyValues(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(commentPrefix) else { continue }
            guard let separatorIndex = trimmed.firstIndex(of: separator) else { continue }
            let key = trimmed[trimmed.startIndex..<separatorIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    /// Builds a `ModManifest` from `modcrateinfo.txt` content plus facts
    /// the info file itself doesn't carry, settings text, layer indices,
    /// and icon presence all come from the archive's real zip listing
    /// (`CrateArchiveManager`), not from guessing at the text format.
    /// `nestedPath` records where inside the archive this manifest actually
    /// sits (see `CrateArchiveManager.manifestPrefix`), `""` for the
    /// overwhelmingly common root-level case.
    public static func parseInfo(
        _ infoText: String,
        settingsText: String?,
        layerIndices: [Int],
        hasIcon: Bool,
        nestedPath: String = "",
        locale: Locale = .current
    ) -> ModManifest {
        let meta = parseKeyValues(infoText)
        let settings = settingsText.map(parseKeyValues) ?? [:]
        return ModManifest(
            name: localizedValue("Name", in: meta, locale: locale) ?? meta["Name"] ?? "Unnamed Mod",
            description: localizedValue("Description", in: meta, locale: locale) ?? meta["Description"] ?? "",
            author: meta["Author"] ?? "",
            version: meta["Version"] ?? "1.0",
            targetGame: meta["Game"] ?? "",
            modLoaderVersion: meta["ModLoaderVersion"] ?? "",
            layerIndices: layerIndices,
            settings: settings,
            hasIcon: hasIcon,
            nestedPath: nestedPath
        )
    }

    /// "Crate Manifest Localization": `CrateModLoader` overrides `Name`/
    /// `Description` with a `<Key>-<CultureInfo.Name>` variant when the
    /// current culture matches (verified key-naming convention from the
    /// real source: `ModCrates.LoadMetadata`'s `Prop_Name + "-" +
    /// CultureInfo.CurrentCulture.Name` lookup). `localeSuffixes` builds
    /// the equivalent candidate list on this platform, most specific
    /// first (`"fr-FR"` before the bare `"fr"`), so a manifest author only
    /// carrying the bare-language variant still matches a region-specific
    /// user locale.
    private static func localizedValue(_ key: String, in meta: [String: String], locale: Locale) -> String? {
        for suffix in localeSuffixes(for: locale) {
            if let value = meta["\(key)-\(suffix)"] { return value }
        }
        return nil
    }

    private static func localeSuffixes(for locale: Locale) -> [String] {
        guard let language = locale.language.languageCode?.identifier else { return [] }
        var suffixes: [String] = []
        if let region = locale.region?.identifier {
            suffixes.append("\(language)-\(region)")
        }
        suffixes.append(language)
        return suffixes
    }
}
