import Foundation
import CTCore

/// Decoder for WoC `.PAD` files -- a plain, uncompressed loose file per
/// level, like `.AI`/`.GRA`.
///
/// Format, confirmed by exact byte consumption on all 17 real `.PAD`
/// files in the corpus checked (`40 + recordCount*20 == fileSize` exactly
/// every time, sizes 2180-117360 bytes; note `CAST_BUG.PAD` and
/// `CASTLE.PAD` are byte-identical, so the real corpus is 16 distinct
/// files):
/// ```
/// File := recordCount:UInt32LE constantOne:UInt32LE(==1) recordCountEcho:UInt32LE(==recordCount)
///         magic:UInt32LE reserved:Bytes(24) Record(recordCount)
/// ```
/// `magic` takes one of only 3 observed values across the corpus (7198,
/// 3598, 35998). Record layout is IDENTICAL across all three -- magic
/// does not change internal structure -- but it correlates partially
/// with whether a record's gated parameter bytes are ever used: all 3
/// files with `magic == 3598` never use them (angle-only throughout);
/// the 1 file with `magic == 7198` does; the 12 files with `magic ==
/// 35998` are mixed. Purpose still unconfirmed.
///
/// **Record internals, decoded by a full-corpus sweep (34,234 records
/// across all 16 distinct files, cross-checked against real `INST`
/// coordinate ranges from each level's own `.GSC`) -- see ``Record``.**
///
/// **The leading "AI path-node graph with adjacency links" hypothesis
/// this format used to be described under is NOT supported by the
/// evidence** and should be considered retired: no field anywhere in the
/// record ever behaves like a valid index into the record array (the
/// angle field's magnitude vastly exceeds any real `recordCount`, and
/// the small parameter bytes that could numerically fit as indices
/// instead show smooth monotonic ramps across neighboring records, not
/// the scattered arbitrary-target pattern a graph edge would produce).
/// No embedded position triple was found either (every float32
/// interpretation at every byte offset was checked against each level's
/// real `INST` coordinates; no offset shows a consistent hit rate).
///
/// **Better-supported reading**: a dense, per-sample path/spline stream
/// -- a continuously-sampled heading angle plus up to four gated scalar
/// parameters (plausibly speed/banking/curvature-type values), with rare
/// large angle discontinuities marking boundaries between distinct
/// sub-paths within one file (e.g. `WESTERN.PAD`: ~34 such jumps across
/// 3173 records). This doesn't confirm what consumes the path -- AI
/// patrol, a vehicle rail, and a camera path all remain plausible -- so
/// this codebase still doesn't rename the file's own purpose from "PAD"
/// or claim more than the shape below.
public enum WOCPadParser {
    public enum ParseError: Error, Equatable {
        case truncated
    }

    /// One 20-byte record. Byte offsets refer to position within the
    /// record.
    public struct Record {
        /// Relative offset 0-1 (`Int16LE`). Near-constant per file/
        /// segment, changing only a handful of times across a whole file
        /// -- real, structured, but meaning unconfirmed.
        public let tag: Int16
        /// Relative offset 2-3 (`Int16LE`, converted here as `raw *
        /// 360.0 / 65536.0`). The strongest confirmed field: spans
        /// essentially the full -180...180 degree range in every real
        /// file checked, independent of level size, and varies smoothly
        /// record-to-record (median |consecutive delta| is 0, far below
        /// the ~16384 expected for unrelated/random Int16 values) --
        /// reads as a continuously-sampled heading/orientation angle.
        public let angleDegrees: Float
        /// Relative offsets 9, 10, 11, 13 respectively -- four
        /// single-byte fields, almost always `0` but forming smooth
        /// ramp/hump shapes over runs of roughly 10-30 consecutive
        /// records when active. `flags`'s bits 5/6/7/3 (respectively)
        /// predict which are "active" (nonzero) for 99.6% of the 34,234
        /// real records checked -- exposed raw here rather than as
        /// gated `Optional`s since that relationship isn't exact (the
        /// ~0.4% exceptions are single-record trailing artifacts at the
        /// tail of a decay ramp, not random noise, but real enough that
        /// hiding a nonzero byte behind a "should be absent" `nil` would
        /// be dishonest).
        public let parameterBytes: (b9: UInt8, b10: UInt8, b11: UInt8, b13: UInt8)
        /// Relative offset 19: a real flags bitfield gating
        /// `parameterBytes` (see above). Not decoded further -- only the
        /// four confirmed gating bits (3/5/6/7) have an established
        /// meaning; the rest of this byte is unexplored.
        public let flags: UInt8
        /// The full 20-byte record. Relative offsets 4-8, 12, 14-16 are
        /// confirmed always exactly `0` (zero exceptions across all
        /// 34,234 real records) -- real reserved/dead bytes, not
        /// exposed as separate fields since there's nothing to expose.
        /// Offsets 17/18 are usually `0x79`/`0xFF`; a distinct 44-record
        /// block at the start of one real file (`FIRE_R.PAD`) uses a
        /// different `0x80808080`-style sentinel/placeholder pattern
        /// there instead (with `flags == 0` too) -- those look like
        /// reserved/unused slots, not real path data, but are left in
        /// `raw` rather than filtered out.
        public let raw: Data
    }

    public struct File {
        public let magic: UInt32
        public let records: [Record]
    }

    public static func parse(_ data: Data) throws -> File {
        var cursor = BinaryCursor(data: data)
        let count = try cursor.readUInt32()
        _ = try cursor.readUInt32() // constant 1
        _ = try cursor.readUInt32() // count echo, confirmed == count
        let magic = try cursor.readUInt32()
        _ = try cursor.readBytes(24) // reserved, unconfirmed content

        var records: [Record] = []
        records.reserveCapacity(Int(count))
        for _ in 0..<count {
            let raw = try cursor.readBytes(20)
            let tag = Int16(bitPattern: UInt16(raw[raw.startIndex]) | (UInt16(raw[raw.startIndex + 1]) << 8))
            let angleRaw = Int16(bitPattern: UInt16(raw[raw.startIndex + 2]) | (UInt16(raw[raw.startIndex + 3]) << 8))
            let angleDegrees = Float(angleRaw) * 360.0 / 65536.0
            let parameterBytes = (
                b9: raw[raw.startIndex + 9],
                b10: raw[raw.startIndex + 10],
                b11: raw[raw.startIndex + 11],
                b13: raw[raw.startIndex + 13]
            )
            let flags = raw[raw.startIndex + 19]
            records.append(Record(tag: tag, angleDegrees: angleDegrees, parameterBytes: parameterBytes, flags: flags, raw: raw))
        }
        return File(magic: magic, records: records)
    }
}
