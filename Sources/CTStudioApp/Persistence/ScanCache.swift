import Foundation
import CryptoKit
import CTModels

/// What gets cached per archive: exactly the Models Hub / Scrapped Content
/// output, not the raw `ChunkNode` tree, the tree stays lazily parsed on
/// demand exactly as it already was (see `WorkspaceViewModel.
/// expandArchiveEntry`), so this cache only needs `ResolvedModelAsset`/
/// `OrphanedAsset` to be `Codable`, not the whole chunk-tree/payload graph.
/// That's a deliberate scope cut: caching everything would mean making
/// `ChunkNode`'s entire `ChunkPayload` graph (including every raw/
/// undecoded record kind) round-trip through `Codable`, a much larger
/// surface for a feature whose actual pain point, the archive scan that
/// populates the Models Hub, this already fully addresses.
struct ScanCachePayload: Codable {
    var modelsHub: [ResolvedModelAsset]
    var orphanedContent: [OrphanedAsset]
    var texturesHub: [TextureHubEntry] = []
}

/// "Persistent scan cache" (QoL sweep): reopening the same `.BD`/`.BH`
/// archive skips the ~100s decode pass and loads the Models Hub / Scrapped
/// Content results straight from disk instead.
enum ScanCache {
    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("TwinsanityStudio/ScanCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Keyed by the archive's own identity, path, size, and modification
    /// date, not just its name, so a `.BD` that's been replaced or
    /// re-extracted with the same filename doesn't silently serve stale
    /// cached models. `SHA256` (via `CryptoKit`, part of the system SDK, no
    /// external dependency) rather than Swift's `Hasher`: `Hasher`'s output
    /// is randomly reseeded every process launch specifically so it's
    /// *not* stable across runs, which is exactly wrong for a cache key
    /// that needs to match itself again on the next launch.
    private static func cacheKey(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let raw = "\(url.path)|\(size)|\(modified.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileURL(for url: URL) -> URL? {
        cacheKey(for: url).map { cacheDirectory.appendingPathComponent($0).appendingPathExtension("cache") }
    }

    static func load(for url: URL) -> ScanCachePayload? {
        guard let fileURL = fileURL(for: url), let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? PropertyListDecoder().decode(ScanCachePayload.self, from: data)
    }

    /// Binary (not XML) property-list format, meaningfully more compact
    /// and faster to encode/decode than either XML plists or JSON for the
    /// large flat float/byte arrays a decoded mesh/texture is mostly made
    /// of, and it's a zero-dependency `Foundation` type, not a new library.
    static func save(_ payload: ScanCachePayload, for url: URL) {
        guard let fileURL = fileURL(for: url) else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Discards every cached scan result, the backing store for a "Clear
    /// Scan Cache" settings action, and also what
    /// `WorkspaceViewModelIntegrationTests` uses to force a real end-to-end
    /// scan rather than risk a cache hit from a previous test run in the
    /// same process (a cache hit skips tree expansion entirely, which those
    /// tests specifically exercise).
    static func clearAll() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}
