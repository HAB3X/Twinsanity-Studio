import Foundation
import CTCore

/// What kind of Twinsanity asset a dropped file/folder appears to be, decided
/// purely from extension + a magic-number peek, no user configuration.
public enum DetectedFileKind: String, Sendable {
    case archiveIndex   // .BH
    case archiveData    // .BD
    case levelResource  // .RM2 / .RMX (Demo variants share the .RM2 extension; disambiguated by magic)
    case sceneryResource // .SM2 / .SMX
    /// "Audio Bank Extractor & Player" (roadmap 2.4): a standalone `.MH`
    /// sound bank index (`MUSIC.MH`, `ENGLISH.MH`, ...), a real, global
    /// audio system separate from the `.RM2`/`.SM2` chunk archive, not
    /// nested inside it. Requires a sibling `.MB` in the same directory to
    /// actually load (see `WorkspaceViewModel`'s sound-bank load path).
    case soundBank
    /// A standalone `.ptc`/`.psm`/`.psf` font/particle-sprite texture-atlas
    /// container (`Twinsanity/Items/TwinsPTC.cs`/`TwinsPSM.cs`/`TwinsPSF.cs`)
    ///, like `.soundBank`, entirely separate from the `.RM2`/`.SM2` chunk
    /// tree, and (unlike `.soundBank`) fully self-contained in one file.
    case ptcSheet
    case folder
    case unknown
}

public struct DetectedFile: Sendable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var kind: DetectedFileKind
    public var platform: ConsolePlatform

    public init(url: URL, kind: DetectedFileKind, platform: ConsolePlatform) {
        self.url = url
        self.kind = kind
        self.platform = platform
    }
}

/// Inspects a dropped URL (file or folder) and figures out what it is and
/// which platform it targets, so the workspace can populate itself without
/// the user picking a file type or endianness from a menu.
public enum WorkspaceAutoDetector {
    private static let knownExtensions: Set<String> = ["BH", "BD", "RM2", "SM2", "RMX", "SMX", "MH", "ISO", "BIN", "CUE", "PTC", "PSM", "PSF"]

    /// Detects a single file. Folders should be expanded with
    /// `scanFolder(_:)` first and each result passed through this.
    public static func detect(url: URL) -> DetectedFile {
        let ext = url.pathExtension.uppercased()
        switch ext {
        case "BH": return DetectedFile(url: url, kind: .archiveIndex, platform: platformFromArchiveMagic(url) ?? .ps2)
        case "BD": return DetectedFile(url: url, kind: .archiveData, platform: .ps2)
        case "RM2": return DetectedFile(url: url, kind: .levelResource, platform: .ps2)
        case "RMX": return DetectedFile(url: url, kind: .levelResource, platform: .xbox)
        case "SM2": return DetectedFile(url: url, kind: .sceneryResource, platform: .ps2)
        case "SMX": return DetectedFile(url: url, kind: .sceneryResource, platform: .xbox)
        case "MH": return DetectedFile(url: url, kind: .soundBank, platform: .ps2)
        case "PTC", "PSM", "PSF": return DetectedFile(url: url, kind: .ptcSheet, platform: .ps2)
        case "ISO", "BIN", "CUE": return DetectedFile(url: url, kind: .unknown, platform: .ps2)
        default: return DetectedFile(url: url, kind: .unknown, platform: .unknown)
        }
    }

    /// Recursively finds every recognizable Twinsanity asset file under a
    /// dropped folder (e.g. an extracted `.BD` archive's contents, or a whole
    /// game disc image mount point).
    public static func scanFolder(_ folderURL: URL) -> [DetectedFile] {
        var results: [DetectedFile] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return results
        }
        for case let fileURL as URL in enumerator {
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDir else { continue }
            guard knownExtensions.contains(fileURL.pathExtension.uppercased()) else { continue }
            results.append(detect(url: fileURL))
        }
        return results.sorted { $0.url.path < $1.url.path }
    }

    /// Reads the file's magic number to sanity-check the extension-based
    /// guess isn't looking at a foreign-format file with a coincidentally
    /// matching extension. Returns `nil` (i.e. "trust the extension guess")
    /// if the file is too short to peek or doesn't look like a chunk header
    /// at all, extension detection is still the primary signal.
    public static func verifyLooksLikeChunkFile(_ url: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return nil }
        var cursor = BinaryCursor(data: head)
        guard let magic = try? cursor.readUInt32() else { return nil }
        return magic == TwinsMagic.v1 || magic == TwinsMagic.v2
    }

    private static func platformFromArchiveMagic(_ url: URL) -> ConsolePlatform? {
        // .BH archives don't encode a platform themselves (the platform
        // split lives in the RM2/SM2 payloads inside them), so this is
        // deliberately a no-op hook, kept as a named entry point so a
        // future heuristic (e.g. sniffing the first RM2/RMX payload found
        // inside) has an obvious place to live without touching call sites.
        nil
    }
}
