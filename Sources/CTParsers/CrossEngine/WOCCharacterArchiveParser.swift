import Foundation

/// Decodes the outer container of WoC's centralized character archive:
/// `CHARS.DAT` (~23MB, root of the disc, alongside `SFX.DAT`/`ATS.DAT`).
///
/// **CONFIRMED, very high confidence** -- the exact same offset-table
/// archive shape already established for `SFX.DAT` (see
/// `WOCSoundParser`'s doc comment), just with a richer 16-byte record:
/// ```
/// File  := dataSize:UInt32LE unexplained:UInt32LE payload:Bytes(dataSize - 8)
///          sentinel:UInt32LE(==0xFFFFFFFF) count:UInt32LE Entry(count)
/// Entry := offset:UInt32LE compressedSize:UInt32LE unpackedSize:UInt32LE flag:UInt32LE
/// ```
/// `flag` is a real `isCompressed` bit, not noise: every entry with
/// `flag == 0` has `compressedSize == unpackedSize` exactly (stored raw);
/// every entry with `flag != 0` begins with the real `RNC\x02` signature.
/// Verified on the real archive by decompressing all 1066 RNC-compressed
/// entries with the existing, unmodified ``RNCDecompressor`` and checking
/// both the packed and unpacked CRCs each RNC stream carries in its own
/// header against the decompressor's own output -- a cryptographic
/// self-check, not just "didn't crash": 1066/1066 pass. The 10 remaining
/// entries (of 1076 total) are exactly the `flag == 0` raw ones.
///
/// **What's inside each entry is a separate, much less settled
/// question** -- see ``isEmbeddedContainer(_:)`` for one confirmed case
/// (a handful of entries are literal `NU20` mini-containers, decodable
/// by the existing, unmodified `WOCContainerParser`) and this type's own
/// doc comment for what's still open. This type only decodes the
/// archive-level table and decompression -- it does not interpret entry
/// contents, since the internal character/skeleton format (joint names,
/// hierarchy, keyframe curves) has not been reverse-engineered yet.
public enum WOCCharacterArchiveParser {
    public enum ParseError: Error, Equatable {
        case fileTooSmall
        case badTableSentinel
    }

    public struct Entry: Identifiable, Hashable {
        public var id: Int { index }
        public let index: Int
        public let offset: UInt32
        public let compressedSize: UInt32
        public let unpackedSize: UInt32
        public let isCompressed: Bool
    }

    /// Reads only the archive's 8-byte header plus its trailing table --
    /// megabytes of entry payload in between are never touched.
    public static func parseTable(fileURL: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        guard let headerData = try handle.read(upToCount: 8), headerData.count == 8 else {
            throw ParseError.fileTooSmall
        }
        let dataSize = headerData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }

        try handle.seek(toOffset: UInt64(dataSize))
        guard let tableHead = try handle.read(upToCount: 8), tableHead.count == 8 else {
            throw ParseError.fileTooSmall
        }
        let sentinel = tableHead.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let count = tableHead.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard sentinel == 0xFFFFFFFF else { throw ParseError.badTableSentinel }

        guard let recordsData = try handle.read(upToCount: Int(count) * 16), recordsData.count == Int(count) * 16 else {
            throw ParseError.fileTooSmall
        }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        recordsData.withUnsafeBytes { raw in
            for i in 0..<Int(count) {
                let base = i * 16
                let offset = raw.loadUnaligned(fromByteOffset: base, as: UInt32.self)
                let compressedSize = raw.loadUnaligned(fromByteOffset: base + 4, as: UInt32.self)
                let unpackedSize = raw.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self)
                let flag = raw.loadUnaligned(fromByteOffset: base + 12, as: UInt32.self)
                entries.append(Entry(index: i, offset: offset, compressedSize: compressedSize, unpackedSize: unpackedSize, isCompressed: flag != 0))
            }
        }
        return entries
    }

    /// Reads and, if needed, RNC-decompresses one entry's raw bytes.
    /// Internal structure is NOT interpreted -- see this type's own doc
    /// comment for what is and isn't understood about entry contents.
    public static func decode(_ entry: Entry, fileURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.offset))
        guard let blob = try handle.read(upToCount: Int(entry.compressedSize)), blob.count == Int(entry.compressedSize) else {
            throw ParseError.fileTooSmall
        }
        guard entry.isCompressed else { return blob }
        return Data(try RNCDecompressor.decompress([UInt8](blob), verifyCRC: true))
    }

    /// `true` for the confirmed real case where a decoded entry is itself
    /// a complete `NU20` mini-container -- byte-identical in format to a
    /// level `.GSC`'s decompressed body, decodable as-is by the existing
    /// `WOCContainerParser.parse`. Confirmed on 3 real entries (indices
    /// 688, 689, 965 in the real archive): two parse perfectly with a
    /// checksum match; the third's section walk still consumes
    /// effectively the whole entry despite a corrupted checksum field.
    /// Most entries are NOT this case -- they're a different, several-
    /// variant native format (see this type's own doc comment) that
    /// isn't decoded yet.
    public static func isEmbeddedContainer(_ decoded: Data) -> Bool {
        decoded.count >= 4 && decoded.prefix(4).elementsEqual(Array("NU20".utf8))
    }
}
