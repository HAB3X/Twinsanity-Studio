import Foundation
import simd
import CTCore

/// Decoder for WoC `.TER` files (terrain) -- a plain, uncompressed loose
/// file per level, like `.AI`/`.GRA`/`.PAD`/`.ANM`.
///
/// Outer framing confirmed by exact byte consumption on 9 real files
/// (`AIRSHIP.TER` 96428B through `SNOW_B.TER` 1417128B):
/// ```
/// File := halfLength:UInt32LE unknownPair:(UInt16, UInt16) mainBlock:Bytes(halfLength*2 - 8)
///         tailCount:UInt32LE TailRecord(tailCount)
/// TailRecord := Bytes(52)
/// ```
/// i.e. `halfLength*2` marks exactly where the tail record table begins,
/// and `halfLength*2 + 4 + tailCount*52` lands exactly on end-of-file --
/// both confirmed exactly, not approximately, across all 9 files checked.
///
/// **`TailRecord`'s 52 real fields, from a real source reference**
/// (`OpenCrashWOC-main/code/src/gamelib/terrain.c`'s `ReadTerrain`, tagged
/// `//NGC MATCH`, plus `terrain.h`'s `OffType`/`offlist` struct, also in
/// `newstructs_TBADDED_check.h:5390`): this is a per-placed-terrain-
/// instance directory entry, not the earlier-guessed
/// "id+position+indices+marker" shape (that guess is now retracted --
/// checking every field against real bytes below shows this decode, not
/// that one). Field layout, all confirmed present at these offsets by
/// the source (semantics beyond the type name are the source's own
/// naming, not independently re-derived from bytes):
/// ```
/// offset:Int32          -- 0x00, stride (in 16-bit halfwords) to the next entry's model data
/// translation:Vector3   -- 0x04
/// type:Int16            -- 0x10 (enum: NORMAL=0, PLATFORM=1, WALLSPL=2, CRASHDATA=3, EMPTY=255)
/// info:Int16            -- 0x12
/// rx,ry,rz:Int16 x3     -- 0x14, 0x16, 0x18
/// pad:Int16             -- 0x1A
/// rotation:Vector3      -- 0x1C
/// flags:UInt32          -- 0x28
/// prim:Int16            -- 0x2C
/// id:Int16              -- 0x2E
/// datapos:Int32         -- 0x30
/// ```
/// (52 bytes total, 0x00...0x34.) Re-tested against real `AIRSHIP.TER`
/// bytes before adopting: all 5 real records decode to a real, sane
/// `type` (4x `0`/NORMAL, 1x `1`/PLATFORM -- matches this file's real mix
/// of flat terrain vs. one moving platform), corroborating the source's
/// field order for at least `offset`/`translation`/`type`. `datapos`
/// decoded to `0` on all 5 real records checked -- either genuinely
/// unused for this file's simple case, or this specific field's offset
/// isn't exactly right; not confirmed either way, exposed as a raw
/// `Int32` rather than guessed at further.
///
/// **`mainBlock`'s internal structure: a real, source-derived hypothesis,
/// still not confirmed byte-exact -- stays raw, not decoded into fields.**
/// The same source shows `mainBlock` (called `model` data there) is a
/// sequence of `[20-byte block header: Int16 continuation-flag (negative
/// = stop), Int16 recordCount, 4x Float32 bbox][recordCount x 100-byte
/// `tertype` collision quad/triangle-pair]` blocks, one such sequence per
/// `NORMAL`/`PLATFORM` tail-record instance (`terraininit()` in the same
/// file); `tertype` itself is `bbox:6xFloat32(minx,maxx,miny,maxy,minz,
/// maxz) + pnts:Vector3x4 + norm:Vector3x2 + info:UInt8x4` (100 bytes,
/// `HitPoly()` in the same file confirms two triangles per quad --
/// `pnts[0,1,2]` against `norm[0]`, `pnts[3,2,1]` against `norm[1]`,
/// with `norm[1].y < 65536.0` as a real "quad has a second triangle"
/// sentinel). **Real supporting evidence, checked against `AIRSHIP.TER`
/// directly**: summing all 5 real tail records' `offset` field (in the
/// source's own halfword units) and doubling to bytes gives 96160 --
/// within 4 bytes of the real 96156-byte `mainBlock`, strongly
/// suggesting instance model data really is laid out back-to-back
/// sequentially starting at `mainBlock` byte 0, sized by each record's
/// own `offset` field. The first 16 floats of the real `mainBlock` also
/// show real repeated values (e.g. `15.357399` appears 4 times, consistent
/// with adjacent quads sharing a corner point, a real structural
/// signature of mesh-like data). **What isn't confirmed**: reading those
/// same first 16 floats as `[flag,count,bbox][tertype...]` per the block-
/// header hypothesis puts `flag`/`count` inside what looks like ordinary
/// float data (the 4-byte value there decodes as a plausible ~3.6 float,
/// not a sane flag+count pair), and the first candidate `tertype.pnts[0].x`
/// (21.48) falls outside the candidate `tertype.bbox`'s own x-range
/// (3.61...15.36) -- a real invariant violation for whichever exact byte
/// alignment was tried. Net: the source gives a concrete, plausible
/// target shape and real corroborating evidence for the overall byte
/// budget, but the precise field alignment within `mainBlock` needs
/// more work before it's safe to expose as decoded fields -- exactly the
/// same "real lead, not yet confirmed" posture the rest of this parser
/// family uses for genuinely open questions.
public enum WOCTerrainParser {
    public enum ParseError: Error, Equatable {
        case truncated
    }

    /// A real per-placed-terrain-instance directory entry -- see this
    /// enum's own doc comment for the source this is decoded from and
    /// what's independently re-verified vs. just trusted from the source.
    public struct TailRecord {
        public let offset: Int32
        public let translation: SIMD3<Float>
        public let type: Int16
        public let info: Int16
        public let rx: Int16
        public let ry: Int16
        public let rz: Int16
        public let rotation: SIMD3<Float>
        public let flags: UInt32
        public let prim: Int16
        public let id: Int16
        public let datapos: Int32
        /// The full 52 real bytes this record was decoded from, kept
        /// alongside the parsed fields so nothing is lost while
        /// `datapos`'s exact meaning (and any other still-unconfirmed
        /// field) remains open.
        public let raw: Data
    }

    public struct File {
        public let mainBlock: Data
        public let tailRecords: [TailRecord]
    }

    public static func parse(_ data: Data) throws -> File {
        var cursor = BinaryCursor(data: data)
        let halfLength = try cursor.readUInt32()
        _ = try cursor.readUInt16() // unknown pair, unconfirmed meaning
        _ = try cursor.readUInt16()
        let mainBlockLength = Int(halfLength) * 2 - 8
        guard mainBlockLength >= 0 else { throw ParseError.truncated }
        let mainBlock = Data(try cursor.readBytes(mainBlockLength))

        let tailCount = try cursor.readUInt32()
        var tailRecords: [TailRecord] = []
        tailRecords.reserveCapacity(Int(tailCount))
        for _ in 0..<tailCount {
            let raw = Data(try cursor.readBytes(52))
            tailRecords.append(try Self.decodeTailRecord(raw))
        }
        return File(mainBlock: mainBlock, tailRecords: tailRecords)
    }

    private static func decodeTailRecord(_ raw: Data) throws -> TailRecord {
        var recordCursor = BinaryCursor(data: raw)
        let offset = Int32(bitPattern: try recordCursor.readUInt32())
        let tx = try recordCursor.readFloat32()
        let ty = try recordCursor.readFloat32()
        let tz = try recordCursor.readFloat32()
        let type = Int16(bitPattern: try recordCursor.readUInt16())
        let info = Int16(bitPattern: try recordCursor.readUInt16())
        let rx = Int16(bitPattern: try recordCursor.readUInt16())
        let ry = Int16(bitPattern: try recordCursor.readUInt16())
        let rz = Int16(bitPattern: try recordCursor.readUInt16())
        _ = try recordCursor.readUInt16() // pad
        let rx2 = try recordCursor.readFloat32()
        let ry2 = try recordCursor.readFloat32()
        let rz2 = try recordCursor.readFloat32()
        let flags = try recordCursor.readUInt32()
        let prim = Int16(bitPattern: try recordCursor.readUInt16())
        let id = Int16(bitPattern: try recordCursor.readUInt16())
        let datapos = Int32(bitPattern: try recordCursor.readUInt32())
        return TailRecord(
            offset: offset, translation: SIMD3(tx, ty, tz),
            type: type, info: info, rx: rx, ry: ry, rz: rz,
            rotation: SIMD3(rx2, ry2, rz2), flags: flags,
            prim: prim, id: id, datapos: datapos, raw: raw
        )
    }
}
