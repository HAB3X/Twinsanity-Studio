import Foundation
import CTModels

public enum CrateArchiveError: Error, LocalizedError, Equatable {
    case unzipToolUnavailable
    case unzipFailed(Int32)
    case manifestMissing
    /// "Crate Region Gating" (`VerifyModCrates`, `CrateModAPI/ModCrates.cs`
    ///, see `ModManifest.declaredRegion`'s own doc comment for the exact
    /// citation): the crate names a region (`modcratesettings.txt`'s
    /// `GameRegion` key) that doesn't match the disc region this workspace
    /// last detected off a real, mounted `SYSTEM.CNF`. Installing anyway
    /// would silently corrupt the result, executable byte offsets differ
    /// by region (see `GameExecutableRevision`'s own doc comment), so this
    /// blocks the install rather than just warning.
    case regionMismatch(declared: GameRegion, detected: GameRegion)

    public var errorDescription: String? {
        switch self {
        case .unzipToolUnavailable: return "The system unzip tool (/usr/bin/unzip) isn't available on this Mac."
        case .unzipFailed(let code): return "unzip exited with status \(code)."
        case .manifestMissing: return "This archive has no modcrateinfo.txt at its root, it isn't a CrateModLoader .crate package."
        case .regionMismatch(let declared, let detected):
            return "This crate is built for \(declared.displayName), but the currently detected disc is \(detected.displayName), installing it would corrupt the result, since executable byte offsets differ by region."
        }
    }
}

/// Reads real `.crate` mod packages, the inspection/extraction
/// counterpart to `CrateExporter`, which only writes them. A `.crate` is a
/// plain zip (see `CrateExporter`'s doc comment for the verified layout:
/// `modcrateinfo.txt` at the root plus one `layer<N>/` folder per install
/// layer); this shells out to the system `/usr/bin/unzip` the same way
/// `CrateExporter` shells out to `/usr/bin/zip`, for the same reason , 
/// `CrateModLoader` itself reads/writes crates with .NET's
/// `System.IO.Compression.ZipFile`, so round-tripping through a real zip
/// tool on both ends is what stays compatible with it.
public enum CrateArchiveManager {
    /// Every entry path inside the archive, root-relative, directories
    /// included with a trailing `/`, `unzip -Z1` (zipinfo's "just the
    /// names" mode) lists them without extracting anything.
    public static func listEntries(in crateURL: URL) throws -> [String] {
        let output = try runUnzip(["-Z1", crateURL.path])
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// "Nested Crate Support": where inside the archive `modcrateinfo.txt`
    /// actually sits, `""` when it's at the zip root (the overwhelmingly
    /// common case CrateModLoader itself expects), or the prefix up to and
    /// including the last `/` before it when the whole crate was zipped
    /// with a wrapping folder (e.g. `"MyMod/"` for `MyMod/modcrateinfo.txt`).
    /// `nil` when no `modcrateinfo.txt` exists anywhere in the archive , 
    /// this isn't a `.crate` at all. Matches CrateModLoader's own
    /// `NestedPath` handling (`ModCrates.cs`).
    static func manifestPrefix(in entries: [String]) -> String? {
        if entries.contains("modcrateinfo.txt") { return "" }
        for entry in entries where entry.hasSuffix("/modcrateinfo.txt") {
            return String(entry.dropLast("modcrateinfo.txt".count))
        }
        return nil
    }

    /// Parses the manifest without extracting the whole archive to disk , 
    /// `modcrateinfo.txt`/`modcratesettings.txt` are pulled into a
    /// throwaway temp directory, and layer/icon presence is read straight
    /// off the real entry list rather than assumed.
    public static func readManifest(from crateURL: URL) throws -> ModManifest {
        let entries = try listEntries(in: crateURL)
        guard let nestedPath = manifestPrefix(in: entries) else { throw CrateArchiveError.manifestMissing }
        let infoMember = nestedPath + "modcrateinfo.txt"
        let settingsMember = nestedPath + "modcratesettings.txt"
        let iconMember = nestedPath + "modcrateicon.png"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwinsanityStudioCrateRead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try runUnzip(["-o", "-q", crateURL.path, infoMember, "-d", tempDir.path])
        let infoText = try String(contentsOf: tempDir.appendingPathComponent(infoMember), encoding: .utf8)

        var settingsText: String?
        if entries.contains(settingsMember) {
            try runUnzip(["-o", "-q", crateURL.path, settingsMember, "-d", tempDir.path])
            settingsText = try? String(contentsOf: tempDir.appendingPathComponent(settingsMember), encoding: .utf8)
        }

        return ModManifestParser.parseInfo(
            infoText,
            settingsText: settingsText,
            layerIndices: layerIndices(in: entries, nestedPath: nestedPath),
            hasIcon: entries.contains(iconMember),
            nestedPath: nestedPath
        )
    }

    /// Extracts one arbitrary member's raw bytes from the archive , 
    /// `readManifest`'s own `modcrateinfo.txt`/`modcratesettings.txt`
    /// extraction generalized to any member path, for callers that need a
    /// specific file out of a crate without extracting the whole archive
    /// (e.g. a `modassets/` bundled asset, see `ModAssetTexture`'s own
    /// doc comment, and `CrateTextureOverrideInstaller`, which is what
    /// actually reads a bundled texture back out this way).
    public static func extractedFileData(_ memberPath: String, from crateURL: URL) throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwinsanityStudioCrateAssetRead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try runUnzip(["-o", "-q", crateURL.path, memberPath, "-d", tempDir.path])
        return try Data(contentsOf: tempDir.appendingPathComponent(memberPath))
    }

    /// The real files inside one `layer<N>/` folder, relative to that
    /// layer's own root (directory entries excluded). `nestedPath` offsets
    /// the lookup the same way `readManifest` does, pass
    /// `manifest.nestedPath`, not `""`, for a crate that isn't zipped at
    /// its root.
    public static func filesInLayer(_ layerIndex: Int, entries: [String], nestedPath: String = "") -> [String] {
        let prefix = "\(nestedPath)layer\(layerIndex)/"
        return entries
            .filter { $0.hasPrefix(prefix) && !$0.hasSuffix("/") }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }

    /// "Crate Region Gating", the real install-time counterpart to
    /// `ModCrateInspectorView`'s passive `regionMismatchWarning` label:
    /// throws `.regionMismatch` rather than just displaying text, so a
    /// caller on the actual install path (`extractLayer`/`extractAll`, or
    /// any future real "apply to disc" flow) can refuse to proceed instead
    /// of only warning about it. Silent, returns normally, whenever
    /// either side has nothing to compare (`manifest.declaredRegion ==
    /// nil`, the common case most crates fall into per that property's own
    /// doc comment, or `detectedRegion` is `nil`/`.unknown`): this mirrors
    /// this codebase's existing "`nil` means nothing to compare, never a
    /// silent assumption of compatibility *or* incompatibility" rule, not
    /// CrateModLoader's own stricter `VerifyModCrates` (which deactivates
    /// any crate lacking a `GameRegion` setting at all), Crash Twinsanity's
    /// own `Modder_Twins` never opts into that stricter check in the real
    /// source (`Modder.ModCrateRegionCheck` defaults `false` and only
    /// `Modder_Crash1`/`2`/`3` override it `true`), so there is no real,
    /// verified Twinsanity behavior this project would be contradicting by
    /// staying permissive when a crate simply doesn't declare a region.
    public static func verifyRegionCompatibility(manifest: ModManifest, detectedRegion: GameRegion?) throws {
        guard let declared = manifest.declaredRegion,
              let detected = detectedRegion,
              detected != .unknown,
              declared != detected
        else { return }
        throw CrateArchiveError.regionMismatch(declared: declared, detected: detected)
    }

    /// Extracts one `layer<N>/` folder's contents into `destinationURL`,
    /// stripping the `layer<N>/` prefix (and any `nestedPath` offset) so
    /// the files land exactly where `CrateModLoader.InstallLayerMod` would
    /// place them relative to a game install directory.
    public static func extractLayer(_ layerIndex: Int, from crateURL: URL, to destinationURL: URL, nestedPath: String = "") throws {
        let prefix = "\(nestedPath)layer\(layerIndex)/"
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwinsanityStudioCrateExtract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        try runUnzip(["-o", "-q", crateURL.path, "\(prefix)*", "-d", stagingDir.path])

        let layerRoot = stagingDir.appendingPathComponent(String(prefix.dropLast()))
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        // The string-relative `enumerator(atPath:)` API, not the URL-based
        // one: `layerRoot` sits under `FileManager.default.temporaryDirectory`
        // (`/var/folders/...`, a symlink to `/private/var/folders/...`), but
        // `enumerator(at:)` resolves that symlink in the URLs it hands back
        // while `layerRoot.path` doesn't, so computing "relative path" by
        // dropping `layerRoot.path`'s length as a string prefix silently
        // produces garbage. Enumerating by path sidesteps the mismatch
        // entirely: every element already comes back relative to
        // `layerRoot`, no prefix arithmetic needed.
        guard let enumerator = FileManager.default.enumerator(atPath: layerRoot.path) else { return }
        for case let relativePath as String in enumerator {
            let source = layerRoot.appendingPathComponent(relativePath)
            let target = destinationURL.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
    }

    /// Extracts the whole archive as-is (manifest + every layer folder) , 
    /// the "just show me the files" counterpart to `extractLayer`.
    public static func extractAll(from crateURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try runUnzip(["-o", "-q", crateURL.path, "-d", destinationURL.path])
    }

    private static func layerIndices(in entries: [String], nestedPath: String) -> [Int] {
        var found = Set<Int>()
        let layerPrefix = "\(nestedPath)layer"
        for entry in entries {
            guard entry.hasPrefix(layerPrefix) else { continue }
            let rest = entry.dropFirst(layerPrefix.count)
            guard let slashIndex = rest.firstIndex(of: "/") else { continue }
            if let index = Int(rest[rest.startIndex..<slashIndex]) {
                found.insert(index)
            }
        }
        return found.sorted()
    }

    @discardableResult
    private static func runUnzip(_ arguments: [String]) throws -> String {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip") else {
            throw CrateArchiveError.unzipToolUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        // Real bug fix: a separate, undrained `standardError` pipe here
        // could deadlock the exact same way an undrained stdout would , 
        // if `unzip` fills *both* kernel pipe buffers, it blocks on the
        // stderr write while this thread is only draining stdout, and
        // neither side ever unblocks. Routing both to the same pipe (its
        // content is discarded on success and only the exit code is
        // reported on failure anyway, so merging loses nothing real)
        // removes that second pipe entirely instead of leaving it as a
        // latent deadlock source.
        process.standardError = outputPipe
        try process.run()
        // Drain stdout before waiting: a large `-Z1` listing can exceed the
        // pipe's kernel buffer, and waiting first would deadlock against a
        // child that's blocked writing to a full pipe.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CrateArchiveError.unzipFailed(process.terminationStatus)
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
