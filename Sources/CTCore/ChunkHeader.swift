import Foundation

/// The common header shared by every `TwinsFile` and every nested `TwinsSection`:
/// a magic number, a record count, a declared content size, and a flat index table.
///
/// The original C# reader recomputes each entry's absolute file position with a
/// `sk - (i + 2) * 0xC + sub.Off` trick (`TwinsSection.cs:188`) because it re-derives
/// "where the index table started" from the reader's current position after each
/// entry read. We instead just remember `indexStartPosition` (the position of the
/// magic number itself) once, up front, `entry.offset` is always relative to that
/// for a nested section, and the RM2/SM2 top level additionally treats it as an
/// absolute file offset (see `RM2Parser`). Same semantics, no positional arithmetic
/// smell.
public struct ChunkHeader: Sendable {
    public let magic: UInt32
    public let recordCount: Int
    public let contentSize: UInt32
    public let entries: [ChunkIndexEntry]
    /// Byte position of this header's magic number in the buffer it was read from.
    public let indexStartPosition: Int
}

public enum ChunkHeaderReader {
    /// Reads a chunk header (magic + count + content size + index table) starting
    /// at the cursor's current position. Throws `TwinsChunkError.badMagic` if the
    /// magic doesn't match either known value.
    public static func readHeader(from cursor: inout BinaryCursor) throws -> ChunkHeader {
        let magicStart = cursor.position
        let magic = try cursor.readUInt32()
        guard magic == TwinsMagic.v1 || magic == TwinsMagic.v2 else {
            throw TwinsChunkError.badMagic(found: magic, position: magicStart)
        }
        let count = try cursor.readInt32()
        let contentSize = try cursor.readUInt32()

        guard count >= 0 else {
            throw TwinsChunkError.truncatedIndex(expectedCount: 0)
        }
        // A corrupt/truncated file could declare a huge count (up to
        // Int32.max), reserving capacity for that many entries up front,
        // before a single one is actually validated against the buffer,
        // would try to allocate gigabytes and could crash/hang well before
        // the per-entry bounds check below ever gets a chance to throw a
        // catchable error. 12 bytes/entry, so bail out now if the buffer
        // plainly can't hold `count` of them.
        guard Int(count) <= cursor.remaining / 12 else {
            throw TwinsChunkError.truncatedIndex(expectedCount: Int(count))
        }
        var entries: [ChunkIndexEntry] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            let off = try cursor.readUInt32()
            let size = try cursor.readInt32()
            let id = try cursor.readUInt32()
            entries.append(ChunkIndexEntry(offset: off, size: size, id: id))
        }
        return ChunkHeader(
            magic: magic,
            recordCount: Int(count),
            contentSize: contentSize,
            entries: entries,
            indexStartPosition: magicStart
        )
    }
}
