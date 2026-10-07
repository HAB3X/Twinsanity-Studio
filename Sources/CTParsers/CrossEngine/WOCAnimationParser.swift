import Foundation
import CTCore
import simd

/// Decoder for WoC `.ANM` files -- a plain, uncompressed loose file per
/// level, like `.AI`/`.GRA`/`.PAD`.
///
/// Format, confirmed by exact byte consumption on all 10 real `.ANM`
/// files that exist anywhere on the disc (`AVALANCH.ANM` 212B,
/// `CASTLE.ANM` 92B, `CASTLE_A.ANM` 340B, `CASTLE_C.ANM` 52B,
/// `DROID.ANM` 600B, `BALLSOF.ANM` 292B, `SPACE_R.ANM` 8B/0 entries,
/// `TOONARMY.ANM` 1128B, `JUNGLE_A.ANM` 620B, `HUB.ANM` 260B):
/// ```
/// File  := formatFlag:UInt32LE entryCount:UInt32LE Entry(entryCount)
/// Entry := name:Bytes(16, null-padded ASCII) flag:UInt32LE(==0 in samples)
///          subCount:UInt32LE reserved:Bytes(20) SubEntry(subCount)
///          [trailer:Vector3(Float32 x3) -- present only when formatFlag == 4]
/// SubEntry := name:Bytes(16, null-padded ASCII) flag:UInt32LE
///             params:(Float32, Float32, Float32, Float32, Float32)
/// ```
/// `formatFlag` is `3` in 8 of the 10 files (no trailer) and `4` in
/// exactly 2 (`DROID.ANM`, `TOONARMY.ANM` -- both carry the trailing
/// `Vector3`).
///
/// **History**: this format was originally confirmed only on the 4
/// `formatFlag == 3` files sampled first, with a 5th real file,
/// `TOONARMY.ANM` (1128 bytes, 20 top-level entries with Maya-derived
/// names like `"pcube2318"`), flagged as diverging after its first entry
/// -- read at the time as evidence that real skeletal-animation files
/// use a materially different, more complex per-joint curve encoding.
/// A full disc-wide sweep of all 10 real `.ANM` files found the true
/// cause instead: `TOONARMY.ANM` (and `DROID.ANM`, which happened not to
/// be in the original 4-file sample) both carry one extra trailing
/// `Vector3` per top-level entry, gated by `formatFlag == 4` -- once that
/// field is accounted for, ALL 10 real files decode with exact
/// byte-consumption, `TOONARMY.ANM` included. Its "joint-like" names read
/// as Maya object/debris names (it lives in the `TSUNAMI` level
/// directory) with a spawn/pivot `Vector3` and zero sub-effects, not
/// skeleton joints. **No genuine per-joint keyframe/curve skeletal
/// animation format has been found in any real `.ANM` file on this
/// disc** -- if WoC stores real character/creature skeletal animation
/// data at all, it is not in these loose files (a plausible next place
/// to look: `CHARS.DAT`, unexamined as of this writing -- since
/// examined; see `WOCCharacterSkeletonParser`'s own doc comment for
/// real, confirmed skeleton/joint data there).
///
/// **Cross-checked against `OpenCrashWOC-main`'s real loader
/// (`code/src/gamelib/edanim.c`'s `edanimFileLoad`) -- confirms the same
/// conclusion independently.** Its own in-memory struct
/// (`anim_parameters_s`, DWARF-verified 0x2D0 bytes) is a trigger +
/// particle-emitter + sound-emitter template with no joint/bone/skeletal
/// field anywhere, matching this file's own simple `Entry`/`SubEntry`
/// shape in spirit (name + flag + a small parameter set) even though the
/// exact field list differs. Real, independent confirmation that the
/// "richer skeletal `.ANM`" gap doesn't exist as a variant of this
/// format -- both this file's own full-corpus byte sweep and a separate
/// real source say so. `parse` still
/// throws rather than silently returning garbage if byte-consumption
/// doesn't land exactly on end-of-file, so a genuinely different format
/// showing up in a future file remains detectable rather than silently
/// misdecoded.
public enum WOCAnimationParser {
    public enum ParseError: Error, Equatable {
        case truncated
        case didNotConsumeWholeFile
    }

    public struct SubEntry {
        public let name: String
        public let flag: UInt32
        public let params: (Float, Float, Float, Float, Float)
    }

    public struct Entry {
        public let name: String
        public let flag: UInt32
        public let subEntries: [SubEntry]
        /// Present only when the file's `formatFlag == 4` -- a per-entry
        /// spawn/pivot position on the two real files confirmed to carry
        /// it (`DROID.ANM`, `TOONARMY.ANM`). `nil` on every `formatFlag
        /// == 3` file (the other 8 of 10 real files).
        public let trailer: SIMD3<Float>?
    }

    public static func parse(_ data: Data) throws -> [Entry] {
        var cursor = BinaryCursor(data: data)
        let formatFlag = try cursor.readUInt32()
        let entryCount = try cursor.readUInt32()
        let hasTrailer = formatFlag == 4

        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        for _ in 0..<entryCount {
            let nameBytes = try cursor.readBytes(16)
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            let flag = try cursor.readUInt32()
            let subCount = try cursor.readUInt32()
            _ = try cursor.readBytes(20) // reserved

            var subEntries: [SubEntry] = []
            subEntries.reserveCapacity(Int(subCount))
            for _ in 0..<subCount {
                let subNameBytes = try cursor.readBytes(16)
                let subName = String(decoding: subNameBytes.prefix { $0 != 0 }, as: UTF8.self)
                let subFlag = try cursor.readUInt32()
                let p0 = try cursor.readFloat32()
                let p1 = try cursor.readFloat32()
                let p2 = try cursor.readFloat32()
                let p3 = try cursor.readFloat32()
                let p4 = try cursor.readFloat32()
                subEntries.append(SubEntry(name: subName, flag: subFlag, params: (p0, p1, p2, p3, p4)))
            }
            let trailer = hasTrailer ? try cursor.readVector3() : nil
            entries.append(Entry(name: name, flag: flag, subEntries: subEntries, trailer: trailer))
        }

        guard cursor.remaining == 0 else { throw ParseError.didNotConsumeWholeFile }
        return entries
    }
}
