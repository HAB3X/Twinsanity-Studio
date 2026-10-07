import Foundation
import simd

/// Decodes WoC's `.AI0`/`.AI1`/`.AI2`/`.AI3` files -- despite the naming
/// convention (which suggested paged/segmented `.AI` entity data), these
/// are a **completely different, unrelated format**. Only `WEST_A` on
/// the whole disc has these files (its own `WEST_A.AI` is a real but
/// essentially-empty normal `.AI` file, 36 bytes/1 entity) -- the naming
/// is almost certainly incidental reuse of the same authoring tool's
/// numbering convention, not evidence of a relationship to `.AI`'s
/// entity-list format. Attempting to parse these with `WOCAIParser`'s
/// `entryCount + Entry(name+waypoints)` logic fails immediately (garbage
/// name bytes, an implausible billions-sized waypoint count).
///
/// **CONFIRMED, very high confidence**: a flat array of fixed 28-byte
/// records, no header/count field at all -- `payload.count % 28 == 0`
/// exactly on all 4 real files (4510/4864/4966/5450 records
/// respectively). Each record's first 16 bytes are a real, valid unit
/// quaternion: `x²+y²+z²+w²` checked against **every one of 19,790 real
/// records across all 4 real files**, max deviation from `1.0` was
/// `4.7e-7` -- exactly float32 rounding noise, zero exceptions. The
/// quaternion (and the other fields below) evolve smoothly from record
/// to record, consistent with a baked per-frame animation/rotation
/// curve, not per-entity metadata (no readable ASCII name strings exist
/// anywhere in any of the 4 files, unlike confirmed real `.AI` entity
/// names like `"bat"`/`"knight"`/`"wizard"`).
/// ```
/// File := Sample*   -- count = payload.count / 28, no leading count field
/// Sample := rotation:Quaternion(Float32 x4)
///           auxShort1:Int16LE auxShort2:Int16LE
///           auxValue:UInt32LE
///           tail:Bytes(4)
/// ```
/// **Not confirmed**: the exact semantics of `auxShort1`/`auxShort2`/
/// `auxValue`/`tail` -- real, structured, smoothly-varying data (not
/// noise: `auxValue` was observed moving in clean multiples of 65536 in
/// one file's tail section, and `tail`'s 4 bytes trace a smooth ramp in
/// the first few records of every file), but not decoded further. The
/// first 3-4 records of every real file are a literal held rest pose
/// (`rotation ≈ (0,1,0,0)`, a valid unit quaternion, with `auxValue`
/// constant and `tail` decreasing by 2 each record) -- this obeys the
/// exact same record shape as the rest of the file, not separate header
/// metadata. Each of the 4 files is independently self-contained (starts
/// fresh with its own rest-pose header, does not continue the previous
/// file's trailing values) -- confirmed by checking there's no second
/// occurrence of the rest-pose template later in any file, and that
/// consecutive files' boundary values don't match up.
///
/// Not yet wired into `WOCLevelAsset` -- only `WEST_A` uses this file
/// family, and which real prop/object this curve actually drives hasn't
/// been cross-referenced against that level's own `.GSC` scene data.
public enum WOCBakedRotationCurveParser {
    public enum ParseError: Error, Equatable {
        case truncated
    }

    private static let sampleWidth = 28

    /// One 28-byte record. Only `rotation` is confirmed and named; the
    /// rest are exposed as real, structured, but undecoded raw fields.
    public struct Sample {
        /// A real, valid unit quaternion (`x²+y²+z²+w² ≈ 1`) -- see this
        /// type's own doc comment for how thoroughly this was checked.
        public let rotation: SIMD4<Float>
        public let auxShort1: Int16
        public let auxShort2: Int16
        public let auxValue: UInt32
        public let tail: (UInt8, UInt8, UInt8, UInt8)
    }

    public static func parse(_ data: Data) throws -> [Sample] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty, bytes.count % sampleWidth == 0 else { throw ParseError.truncated }
        let count = bytes.count / sampleWidth

        var samples: [Sample] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            let base = i * sampleWidth
            let rotation = SIMD4<Float>(
                leFloat32(bytes, base),
                leFloat32(bytes, base + 4),
                leFloat32(bytes, base + 8),
                leFloat32(bytes, base + 12)
            )
            let auxShort1 = Int16(bitPattern: leUInt16(bytes, base + 16))
            let auxShort2 = Int16(bitPattern: leUInt16(bytes, base + 18))
            let auxValue = leUInt32(bytes, base + 20)
            let tail = (bytes[base + 24], bytes[base + 25], bytes[base + 26], bytes[base + 27])
            samples.append(Sample(rotation: rotation, auxShort1: auxShort1, auxShort2: auxShort2, auxValue: auxValue, tail: tail))
        }
        return samples
    }

    private static func leFloat32(_ b: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: leUInt32(b, o))
    }

    private static func leUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func leUInt16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }
}
