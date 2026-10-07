import Foundation
import CTCore
import CTModels

public enum BDArchiveError: Error, CustomStringConvertible {
    case missingCounterpart(String)
    case badMagic(UInt32)
    case entryOutOfBounds(name: String, offset: UInt32, size: UInt32, fileSize: Int)
    /// Real, security-relevant bug fix: an entry name that would resolve
    /// outside the chosen extraction directory (a `..`-containing path,
    /// classic zip-slip), see `safeExtractionURL`'s own doc comment.
    case unsafeEntryName(String)

    public var description: String {
        switch self {
        case .missingCounterpart(let path):
            return "Could not find the matching .BD/.BH file for \(path)."
        case .badMagic(let magic):
            return String(format: "Unexpected .BH magic number: 0x%08X (expected 0x501).", magic)
        case .entryOutOfBounds(let name, let offset, let size, let fileSize):
            return "Archive entry '\(name)' (offset \(offset), size \(size)) exceeds the .BD file size (\(fileSize))."
        case .unsafeEntryName(let name):
            return "Archive entry '\(name)' would extract outside the chosen destination folder, refusing to extract it."
        }
    }
}

/// A reusable open handle to a `.BD` file, for reading many entries without
/// paying per-call file-open + `stat()` overhead. Reading N entries via the
/// static `BDArchiveParser.readEntryData(_:index:)` opens/stats/closes the
/// file N times; a full-archive scan (hundreds of entries) makes that the
/// dominant cost, especially against a mounted disc image rather than a
/// local SSD file. Not thread-safe for concurrent reads, a single
/// `FileHandle`'s seek+read must not interleave across threads, but safe
/// (and intended) for sequential reads from one background thread.
public final class BDArchiveReader {
    private let handle: FileHandle
    private let fileSize: Int

    public init(index: ArchiveIndex) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: index.bdURL.path)
        // `NSNumber.intValue` bridges through Objective-C's 32-bit `int`
        // even on a 64-bit platform, silently truncating any `.BD` file
        // size at or past 2GB instead of throwing. `as? Int` bridges the
        // full 64-bit value directly, matching the same correct pattern
        // `GameLauncher.writingVerified` already uses for its own file-size
        // check.
        fileSize = (attributes[.size] as? Int) ?? 0
        handle = try FileHandle(forReadingFrom: index.bdURL)
    }

    deinit {
        try? handle.close()
    }

    public func read(_ entry: ArchiveEntry) throws -> Data {
        guard Int(entry.offset) + Int(entry.size) <= fileSize else {
            throw BDArchiveError.entryOutOfBounds(name: entry.name, offset: entry.offset, size: entry.size, fileSize: fileSize)
        }
        try handle.seek(toOffset: UInt64(entry.offset))
        return try handle.read(upToCount: Int(entry.size)) ?? Data()
    }
}

/// Reads and writes Twinsanity's `.BD`/`.BH` archive pair.
///
/// Format (ported from `Twinsanity/BDArchive.cs`):
/// - `.BH` (index): `int32 magic` (0x501 when written) followed by back-to-back,
///   EOF-terminated entries: `int32 nameLength`, `char[nameLength]` ASCII name,
///   `uint32 offset`, `uint32 size`. No explicit entry count.
/// - `.BD` (data): raw file bytes concatenated back-to-back at the offsets named
///   above. No alignment or padding between entries.
public enum BDArchiveParser {
    /// Given either a `.BH` or `.BD` URL (any case), resolves the sibling path,
    /// preserving the original tool's case-sensitive suffix-swap behavior
    /// (`BDArchive.cs:13-41`) so archives written by the Windows tool keep working.
    public static func counterpartURL(for url: URL) throws -> (bh: URL, bd: URL) {
        let path = url.path
        if path.hasSuffix(".BH") {
            return (url, URL(fileURLWithPath: String(path.dropLast(1)) + "D"))
        } else if path.hasSuffix(".bh") {
            return (url, URL(fileURLWithPath: String(path.dropLast(1)) + "d"))
        } else if path.hasSuffix(".BD") {
            return (URL(fileURLWithPath: String(path.dropLast(1)) + "H"), url)
        } else if path.hasSuffix(".bd") {
            return (URL(fileURLWithPath: String(path.dropLast(1)) + "h"), url)
        } else {
            return (url.appendingPathExtension("BH"), url.appendingPathExtension("BD"))
        }
    }

    /// Parses just the `.BH` index, cheap, does not touch the (potentially huge) `.BD`.
    public static func readIndex(bhURL: URL) throws -> ArchiveIndex {
        let (bh, bd) = try counterpartURL(for: bhURL)
        let data = try Data(contentsOf: bh)
        var cursor = BinaryCursor(data: data)
        _ = try cursor.readInt32() // magic; not validated on read, mirrors original tool's tolerance for foreign archives

        var entries: [ArchiveEntry] = []
        while !cursor.isAtEnd {
            let nameLen = Int(try cursor.readInt32())
            guard nameLen >= 0 else { break }
            let name = try cursor.readASCIIString(length: nameLen)
            let offset = try cursor.readUInt32()
            let size = try cursor.readUInt32()
            entries.append(ArchiveEntry(name: normalizingSeparators(name), offset: offset, size: size))
        }
        return ArchiveIndex(bhURL: bh, bdURL: bd, entries: entries)
    }

    /// Reads a single entry's bytes out of the `.BD` file. Convenient for a
    /// one-off read (e.g. the user clicking a single archive entry), but
    /// opens a fresh `FileHandle` and re-`stat`s the file on every call , 
    /// reading more than a handful of entries this way (e.g. scanning a
    /// whole archive) pays that overhead hundreds of times over. Use
    /// `BDArchiveReader` for that instead.
    public static func readEntryData(_ entry: ArchiveEntry, index: ArchiveIndex) throws -> Data {
        try BDArchiveReader(index: index).read(entry)
    }

    /// Extracts every entry to `destinationDirectory`, recreating the archive's
    /// internal directory structure (entries may embed `/`-separated paths).
    public static func extractAll(index: ArchiveIndex, to destinationDirectory: URL) throws {
        let fm = FileManager.default
        let bdHandle = try FileHandle(forReadingFrom: index.bdURL)
        defer { try? bdHandle.close() }

        for entry in index.entries {
            let outURL = try Self.safeExtractionURL(for: entry.name, in: destinationDirectory)
            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bdHandle.seek(toOffset: UInt64(entry.offset))
            let data = try bdHandle.read(upToCount: Int(entry.size)) ?? Data()
            try data.write(to: outURL)
        }
    }

    /// Real bug fix (path traversal): `entry.name` comes straight from the
    /// archive's own index data, attacker-controlled if the `.BH`/`.BD`
    /// pair being extracted is a crafted/malicious file, not necessarily a
    /// genuine game archive. Joining it onto `destinationDirectory` with
    /// no validation meant a name like `"../../../../Library/LaunchAgents/
    /// evil.plist"` would write outside the chosen destination entirely , 
    /// classic zip-slip. This resolves the real, standardized destination
    /// path and refuses to extract anywhere `destinationDirectory` isn't
    /// still a real prefix of it, rather than trusting the archive's own
    /// claimed relative path blindly.
    private static func safeExtractionURL(for entryName: String, in destinationDirectory: URL) throws -> URL {
        let destination = destinationDirectory.standardizedFileURL
        let candidate = destination.appendingPathComponent(entryName).standardizedFileURL
        let destinationPath = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"
        guard candidate.path == destination.path || candidate.path.hasPrefix(destinationPath) else {
            throw BDArchiveError.unsafeEntryName(entryName)
        }
        return candidate
    }

    /// Extracts only the named entries to `destinationDirectory`, the
    /// reference editor's `BDExplorer.ExtractRecursively` run against a
    /// single selected tree node/subtree rather than the whole archive.
    /// Names not present in `index` are silently skipped.
    public static func extractSelected(index: ArchiveIndex, entryNames: Set<String>, to destinationDirectory: URL) throws {
        let fm = FileManager.default
        let bdHandle = try FileHandle(forReadingFrom: index.bdURL)
        defer { try? bdHandle.close() }

        for entry in index.entries where entryNames.contains(entry.name) {
            let outURL = try Self.safeExtractionURL(for: entry.name, in: destinationDirectory)
            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bdHandle.seek(toOffset: UInt64(entry.offset))
            let data = try bdHandle.read(upToCount: Int(entry.size)) ?? Data()
            try data.write(to: outURL)
        }
    }

    private static func normalizingSeparators(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/")
    }

    /// Rebuilds a `.BH`/`.BD` pair from a directory tree, matching
    /// `BDArchive.CompileAll` byte-for-byte in spirit (2 MiB streamed copies,
    /// no padding between entries, magic `0x501`).
    ///
    /// This is intentionally a *fresh rebuild from a directory*, not an in-place
    /// patch, see `ArchiveRepackager` (CTExport) for the "replace just these
    /// entries, keep everything else identical" workflow the app's UI drives.
    public static func compileAll(from sourceDirectory: URL, bhURL: URL, bdURL: URL) throws {
        let fm = FileManager.default
        var files: [(relativePath: String, url: URL)] = []
        // Resolve symlinks before computing relative paths: on macOS
        // `FileManager.default.temporaryDirectory` (and `/tmp` generally) is
        // itself a symlink to `/private/tmp`, and `enumerator(at:)` returns
        // paths through the *resolved* location, a naive string-prefix
        // strip against the unresolved `sourceDirectory.path` silently fails
        // to strip anything, leaving full absolute paths as "relative" names.
        let sourceComponents = sourceDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        if let enumerator = fm.enumerator(at: sourceDirectory, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { continue }
                let resolvedComponents = fileURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                let relative = resolvedComponents.dropFirst(sourceComponents.count).joined(separator: "/")
                files.append((relative, fileURL))
            }
        }
        files.sort { $0.relativePath < $1.relativePath }

        fm.createFile(atPath: bhURL.path, contents: nil)
        fm.createFile(atPath: bdURL.path, contents: nil)
        let bhHandle = try FileHandle(forWritingTo: bhURL)
        let bdHandle = try FileHandle(forWritingTo: bdURL)
        defer { try? bhHandle.close(); try? bdHandle.close() }

        var header = BinaryWriter()
        header.writeInt32(0x501)
        bhHandle.write(header.data)

        for (relativePath, fileURL) in files {
            let fileData = try Data(contentsOf: fileURL)
            var entryHeader = BinaryWriter()
            // Real bug fix, same one `ArchiveRepackager.writeEntry` already
            // found and fixed (see its own doc comment): the real disc's
            // raw bytes use `\` as the path separator, verified directly
            // against a real retail disc, writing the `/`-joined form
            // straight through corrupts every entry name on disk even
            // though this tool's own `readIndex` normalizes `\` -> `/` on
            // the way back in, so it round-trips clean through this
            // project's own tools while the real game hangs partway
            // through loading a level built this way.
            let nameBytes = Array(relativePath.replacingOccurrences(of: "/", with: "\\").utf8)
            entryHeader.writeInt32(Int32(nameBytes.count))
            entryHeader.writeBytes(nameBytes)
            let offset = try bdHandle.offset()
            entryHeader.writeUInt32(UInt32(offset))
            entryHeader.writeUInt32(UInt32(fileData.count))
            bhHandle.write(entryHeader.data)
            bdHandle.write(fileData)
        }
    }
}
