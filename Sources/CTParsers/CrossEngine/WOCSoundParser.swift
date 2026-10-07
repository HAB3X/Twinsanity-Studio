import Foundation

/// Decodes WoC's centralized sound archive: `SFX.DAT` (and the
/// structurally-identical `ATS.DAT`, which turned out to hold compiled
/// text scripts rather than audio -- same container, different payload).
/// Confirmed on the real disc: a plain offset-table archive of standard
/// Sony `VAGp`-header PS-ADPCM clips, PS2-sector-aligned (2048 bytes).
///
/// Independently re-verified against real bytes (not just an agent
/// report): the offset-table chain (`next.offset ==
/// roundup(prev.offset+prev.size, 2048)`) holds for all 781 consecutive
/// pairs in the real `SFX.DAT`, every VAG header's `data_size` field plus
/// its own 48-byte header exactly equals the outer table's `size` field
/// for every entry checked, and decoded PCM from several entries spread
/// across the whole file shows real-waveform statistics (wide dynamic
/// range, high lag-1 sample autocorrelation) rather than noise.
///
/// Per-level `.GSC` files carry no sound of their own -- every sound in
/// the game lives in this one archive.
public enum WOCSoundParser {
    public enum ParseError: Error, Equatable {
        case fileTooSmall
        case badTableSentinel
        case badVAGMagic
    }

    /// One playable clip: its byte range in the archive (`offset`/`size`
    /// span the 48-byte VAG header *and* the ADPCM payload together, as
    /// stored in the outer table) plus the sample rate read from its own
    /// VAG header at decode time.
    public struct Entry: Identifiable, Hashable {
        public var id: Int { index }
        public let index: Int
        public let offset: UInt32
        public let size: UInt32
    }

    /// Reads only the archive's 8-byte header plus its trailing table --
    /// megabytes of audio payload in between are never touched. Cheap
    /// enough to call on every launch against a 289MB real archive.
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
                let size = raw.loadUnaligned(fromByteOffset: base + 4, as: UInt32.self)
                entries.append(Entry(index: i, offset: offset, size: size))
            }
        }
        return entries
    }

    /// One decoded clip: sample rate from the real VAG header, plus PCM16
    /// mono samples from the standard PS-ADPCM decode.
    public struct DecodedClip {
        public let sampleRate: UInt32
        public let samples: [Int16]
    }

    /// Reads exactly `entry.size` bytes at `entry.offset` and decodes
    /// them: 48-byte `VAGp` header (big-endian fields, standard Sony
    /// format) followed by 16-byte PS-ADPCM blocks (28 samples/block).
    public static func decode(_ entry: Entry, fileURL: URL) throws -> DecodedClip {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.offset))
        guard let blob = try handle.read(upToCount: Int(entry.size)), blob.count >= 48 else {
            throw ParseError.fileTooSmall
        }
        guard blob.prefix(4).elementsEqual([0x56, 0x41, 0x47, 0x70]) else { // "VAGp"
            throw ParseError.badVAGMagic
        }
        let sampleRate = blob.withUnsafeBytes { raw -> UInt32 in
            let be = raw.loadUnaligned(fromByteOffset: 0x10, as: UInt32.self)
            return UInt32(bigEndian: be)
        }
        let adpcm = blob.suffix(from: 48)
        let samples = WOCADPCMDecoder.decode(adpcm)
        return DecodedClip(sampleRate: sampleRate, samples: samples)
    }

    /// The real VAG header carries a 16-byte scratch field at relative
    /// offset `0x20` -- confirmed on the real archive to be leftover
    /// authoring-tool metadata: a (16-byte-truncated) Windows source path
    /// from whatever machine/drive originally exported the clip, e.g.
    /// `"C:\WINDOWS\DESKT"`, `"Z:\ARTHUR~1\CRAS"`, `"D:\CRASHM~1\AIFS"`.
    /// Not a clip name in any user-facing sense, but real and useful: see
    /// ``findMusicTracks(in:fileURL:)``.
    public static func readEmbeddedPathField(_ entry: Entry, fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.offset))
        guard let header = try handle.read(upToCount: 48), header.count == 48 else {
            throw ParseError.fileTooSmall
        }
        let field = header[header.startIndex + 0x20..<header.startIndex + 0x30]
        return String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// One real background-music track: two consecutive `SFX.DAT` table
    /// entries, independent left/right channels of the same track.
    public struct MusicTrack: Identifiable {
        public var id: Int { left.index }
        public let left: Entry
        public let right: Entry
    }

    /// **Confirmed on the real archive**: of `SFX.DAT`'s 782 entries, 72
    /// carry `"CRASHM"` (truncated `"D:\CRASH MUSIC\..."`) in their
    /// embedded path field -- exactly 36 pairs of consecutive indices
    /// with byte-identical `size`, zero exceptions/anomalies. Everywhere
    /// else in the archive, that embedded path field points at ordinary
    /// SFX/dialogue source folders (`Z:\ARTHUR~1\CRAS...`,
    /// `D:\FOREIG~1\ITAL...`), never `"CRASHM"`. Decoded PCM from a real
    /// pair (independently verified: ~135s at 44.1kHz, real dynamic
    /// range, cross-channel correlation r=0.37 consistent with
    /// independent stereo channels of one track, not duplicate data) --
    /// these are real music tracks' left/right channels, not incidental
    /// large SFX entries. This is an I/O cost `parseTable` deliberately
    /// avoids paying by default (a 48-byte read per entry, 782 total) --
    /// call this only when you actually want the music list, not on
    /// every table load.
    public static func findMusicTracks(in entries: [Entry], fileURL: URL) throws -> [MusicTrack] {
        var tracks: [MusicTrack] = []
        var i = 0
        while i < entries.count {
            let field = try readEmbeddedPathField(entries[i], fileURL: fileURL)
            guard field.contains("CRASHM") else { i += 1; continue }
            if i + 1 < entries.count, entries[i + 1].size == entries[i].size {
                tracks.append(MusicTrack(left: entries[i], right: entries[i + 1]))
                i += 2
            } else {
                i += 1
            }
        }
        return tracks
    }
}
