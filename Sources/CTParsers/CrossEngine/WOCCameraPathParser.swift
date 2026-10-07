import Foundation
import simd

/// Decoder for WoC `.VIS` files -- and the one real `.POO` file
/// (`WEST_A.POO`), confirmed to be the exact same format under a
/// different extension (same header shape, same `weecam_*` string
/// vocabulary). Despite the `.VIS` extension, **this is not a
/// visibility/PVS system** -- an earlier survey's "per-instance
/// visibility bitfield" hypothesis is directly ruled out (the payload is
/// float/coordinate-typed, not boolean-packed) and superseded by real
/// evidence of what it actually is.
///
/// **CONFIRMED, high confidence**: every real file (14 `.VIS` + 1
/// `.POO`, zero exceptions) ends in a packed, null-terminated ASCII
/// string table whose real entries are literal named camera path
/// entry points -- `weecam_mid_00`, `weecam_in_bonus`,
/// `weecam_out_bonus`, `weecam_mid_bonus`, `weecam_mid_death`,
/// `weecam_in_death`, `weecam_in_gem`, `weecam_mid_gem`,
/// `weecam_right_bonus` -- "weecam" being WoC's small/cutscene camera.
/// This is real, named **cinematic camera path data**: bonus-round,
/// gem, and death-respawn camera sequences per level, not a spatial
/// visibility system.
/// ```
/// File := sentinel:UInt32LE(==0xFFFFFFFF) nodeCount:UInt32LE headerB:UInt32LE
///         body:Bytes(...)   -- a node/path graph, see below
///         stringCount:UInt32LE
///         String(stringCount)   -- null-terminated ASCII, packed, ends exactly at EOF
/// ```
/// The string table's own leading count is located unambiguously:
/// scanning for the offset where reading that many consecutive
/// null-terminated printable-ASCII strings lands EXACTLY on end-of-file
/// -- verified to find exactly one such offset in all 15 real files,
/// with the real camera-path names as a result (a naive backward scan
/// for "the last run of printable-or-null bytes" is genuinely ambiguous
/// here, since a small count's own zero-padding bytes are
/// indistinguishable from string null-terminators; this scan-forward
/// exact-EOF-landing approach avoids that ambiguity entirely).
///
/// **CONFIRMED, the body's real node/path graph is now fully decoded**
/// (a follow-up session solved what this doc originally left open):
/// `headerB` is specifically **node 0's own point count** -- not a
/// generic file-level count, which is why treating it as one had been
/// ruled out. The body decodes as:
/// ```
/// body := Node0Points(headerB * 12 bytes, Vec3 each)
///         Node(nodeCount - 1) {           -- for nodes 1..<nodeCount
///           pointCount:UInt32LE
///           Points(pointCount * 12 bytes, Vec3 each)
///         }
///         indexTable: nodeCount:UInt32LE
///                     IndexRecord(nodeCount)  -- 16 bytes each
/// IndexRecord := nameIndex:Int32LE selfIndex:Int32LE fieldC:Int32LE fieldD:Int32LE
/// ```
/// Each `Vec3` is a real world-space point (cross-referenced against
/// that same level's `INST` coordinate range and confirmed to fall in
/// the same envelope). Verified with exact, zero-slack byte accounting
/// on **14 of the 15 real `.VIS`/`.POO` files on the mounted disc**: the
/// point-list walk consumes exactly `body.count - (4 + nodeCount*16)`
/// bytes, landing precisely on the index table's own leading
/// `nodeCount` echo, on every file except `TOONARMY.VIS` (see below).
///
/// `IndexRecord.nameIndex` is the field that actually matters: **always
/// a valid index into `cameraPathNames`, zero exceptions across all 5
/// files spot-checked at the record level** (`CASTLE`/`CASTLE_C`/
/// `DROID`/`VOLCANO`/`GARDEN`) -- this is how multiple physical point-
/// list nodes share one logical named path (e.g. `CASTLE.VIS` has 9
/// nodes but only 6 names; nodes 0-3 all share name index 0, i.e. one
/// multi-segment path built from 4 separate point lists).
///
/// **`selfIndex` is NOT a self-reference -- it's a real sort rank**,
/// confirmed by cross-referencing against `unknownFieldC`/
/// `unknownFieldD` (the name kept for compatibility with earlier,
/// less-understood documentation, not because it's accurate): within
/// every group of nodes sharing one `nameIndex`, sorting by `selfIndex`
/// ascending also sorts `fieldC` and `fieldD` ascending -- confirmed on
/// 14 of 19 real multi-node-groups checked across 13 files, zero
/// exceptions among those 14 (this is *why* `selfIndex` looked like a
/// plain self-reference on small groups -- when a group's file order
/// already matches `fieldC` order, the "rank" and "position" are the
/// same number -- and why `VOLCANO.VIS`'s pairs cross-referenced each
/// other: a 2-node group whose file order is reversed relative to
/// `fieldC` order produces exactly that swap). `fieldC`/`fieldD` are
/// still not understood beyond being real, monotonic-under-this-sort
/// values (plausibly a cumulative arc-length or time range stitching
/// each node's own segment into the full named path) -- the 5 groups
/// that broke strict monotonicity all did so in a structured way (a
/// cleanly monotonic "head" sub-sequence plus a separate, later
/// sub-sequence that doesn't chain smoothly with it), consistent with
/// some names covering multiple *disconnected* path segments rather
/// than one continuous chain -- a real, plausible explanation, not
/// independently confirmed.
///
/// **`TOONARMY.VIS` is the one real exception**: its point-list walk
/// still succeeds cleanly (15 plausible node lengths, `ok`), but the
/// trailing bytes don't land exactly on `4 + nodeCount*16` (`228` real
/// bytes left vs. `244` expected) -- consistent with this doc's
/// already-known "doesn't fit the uniform 16-byte-per-node index-record
/// width other files do" finding. Rather than guess at that file's index
/// table, ``File/nodes`` still gets real, correct points for every node
/// on `TOONARMY.VIS`, just with `nameIndex == nil` throughout (see
/// ``CameraPathNode``) -- an honest partial result, not silently wrong
/// data.
///
/// **Checked against `OpenCrashWOC-main`, real tension found, not
/// adopted -- this file's own byte-level evidence is stronger.** That
/// reference's `code/src/gamecode/visi.c`/`visidat.c` describe `.vis` as
/// a visibility/PVS cache: a runtime fallback (`BuildVisiTable`) scans
/// the level's own spline table for splines whose *name* contains the
/// substring `"vis"` and records which scene instances fall inside each
/// one's 2D footprint, used only when no `.vis` file loads successfully.
/// This doesn't override what's confirmed above: `visiLoadData` (the
/// actual on-disk `.vis` file parser in that reference) is an
/// **unimplemented stub** (`//TODO`, no body) -- that source has zero
/// real byte-level knowledge of what a `.vis` file actually contains,
/// only of a same-purpose runtime-computed substitute used when one
/// isn't available. This file's own decode is real, byte-exact evidence
/// from the files themselves (14-15 real files, zero-slack accounting,
/// named camera-path strings, points that cross-reference real level
/// coordinates) -- categorically stronger than an inferred analogy to an
/// unimplemented function's probable purpose. Real, complementary lead
/// worth recording rather than acting on: that same reference shows
/// named camera rails (`weecam_*`, matching this file's own decoded
/// names exactly) are *also* resolved as ordinary named splines inside
/// the level's own scene data (`NuSplineFind(world_scene[0], name)`,
/// `code/src/gamecode/game.c`'s `InitSplineTable`) and walked with plain
/// linear interpolation between points (`PointAlongSpline`, same file) --
/// no separate curve/tangent math. If a level's own `SST0` spline table
/// (already fully decoded by `WOCSplineSetParser`) turns out to contain
/// entries with these same `weecam_*` names, that would be a real,
/// checkable cross-reference between the two systems -- not yet checked
/// here.
public enum WOCCameraPathParser {
    public enum ParseError: Error, Equatable {
        case truncated
        case badSentinel
        case stringTableNotFound
    }

    /// One real spline/path node from a `.VIS` file's body -- see this
    /// file's own doc comment for the confirmed byte layout.
    public struct CameraPathNode {
        /// Real world-space points, in file order.
        public let points: [SIMD3<Float>]
        /// Index into `File.cameraPathNames` -- multiple nodes can share
        /// one name (a multi-segment path). `nil` only on files whose
        /// index table doesn't byte-account cleanly (`TOONARMY.VIS` is
        /// the one known case) -- see this file's own doc comment.
        public let nameIndex: Int?
        /// **Not a self-reference despite the name** (kept for
        /// compatibility with earlier, less-understood documentation) --
        /// a real sort rank within this node's `nameIndex` group,
        /// confirmed by cross-referencing against `unknownFieldC`/
        /// `unknownFieldD`. See this file's own doc comment for the full
        /// evidence. `nil` under the same condition as `nameIndex`.
        public let selfIndex: Int32?
        public let unknownFieldC: Int32?
        public let unknownFieldD: Int32?
    }

    public struct File {
        public let nodeCount: UInt32
        /// Header's third `UInt32` field -- confirmed to be node 0's own
        /// point count (see ``nodes``), not a generic file-level count.
        public let headerB: UInt32
        /// Everything between the 12-byte header and the string table,
        /// exposed raw for anyone auditing the decode in ``nodes``. See
        /// this type's own doc comment for the confirmed byte layout.
        public let body: Data
        /// Real, decoded named camera path entry points (e.g.
        /// `"weecam_mid_bonus"`).
        public let cameraPathNames: [String]
        /// The real, decoded per-node point lists -- see
        /// ``CameraPathNode`` and this file's own doc comment. Always
        /// `nodeCount` entries with real points; `nameIndex`/`selfIndex`/
        /// `unknownFieldC`/`unknownFieldD` are `nil` together on the one
        /// known file (`TOONARMY.VIS`) whose index table doesn't
        /// byte-account cleanly.
        public let nodes: [CameraPathNode]
    }

    public static func parse(_ data: Data) throws -> File {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw ParseError.truncated }
        guard leUInt32(bytes, 0) == 0xFFFFFFFF else { throw ParseError.badSentinel }
        let nodeCount = leUInt32(bytes, 4)
        let headerB = leUInt32(bytes, 8)

        guard let (stringTableOffset, names) = findStringTable(bytes) else {
            throw ParseError.stringTableNotFound
        }
        let body = Data(bytes[12..<stringTableOffset])
        let nodes = parseNodes(body, nodeCount: nodeCount, headerB: headerB, nameCount: names.count)
        return File(nodeCount: nodeCount, headerB: headerB, body: body, cameraPathNames: names, nodes: nodes)
    }

    /// Decodes `body` into real per-node point lists, then (only if the
    /// leftover bytes exactly match `4 + nodeCount*16`) the index table
    /// on top of that -- see this file's own doc comment for the
    /// confirmed layout and the one known exception (`TOONARMY.VIS`).
    private static func parseNodes(_ body: Data, nodeCount: UInt32, headerB: UInt32, nameCount: Int) -> [CameraPathNode] {
        let bytes = [UInt8](body)
        var pos = 0
        var pointLists: [[SIMD3<Float>]] = []

        func readPoints(_ count: Int) -> [SIMD3<Float>]? {
            guard count >= 0, count < 10_000, pos + count * 12 <= bytes.count else { return nil }
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(count)
            for _ in 0..<count {
                let x = leFloat32(bytes, pos)
                let y = leFloat32(bytes, pos + 4)
                let z = leFloat32(bytes, pos + 8)
                points.append(SIMD3(x, y, z))
                pos += 12
            }
            return points
        }

        guard let firstPoints = readPoints(Int(headerB)) else { return [] }
        pointLists.append(firstPoints)

        guard nodeCount >= 1 else { return [] }
        for _ in 1..<nodeCount {
            guard pos + 4 <= bytes.count else { return [] }
            let count = Int(leUInt32(bytes, pos))
            pos += 4
            guard let points = readPoints(count) else { return [] }
            pointLists.append(points)
        }

        // Only attempt the index table if the remaining bytes exactly
        // match the confirmed formula -- otherwise leave every node's
        // metadata nil rather than guess (TOONARMY.VIS).
        let remaining = bytes.count - pos
        let expectedIndexTableLength = 4 + Int(nodeCount) * 16
        guard remaining == expectedIndexTableLength else {
            return pointLists.map { CameraPathNode(points: $0, nameIndex: nil, selfIndex: nil, unknownFieldC: nil, unknownFieldD: nil) }
        }

        let indexTableStart = pos + 4 // skip the leading nodeCount echo
        return pointLists.enumerated().map { i, points in
            let recordStart = indexTableStart + i * 16
            let nameIndexRaw = Int32(bitPattern: leUInt32(bytes, recordStart))
            let selfIndex = Int32(bitPattern: leUInt32(bytes, recordStart + 4))
            let fieldC = Int32(bitPattern: leUInt32(bytes, recordStart + 8))
            let fieldD = Int32(bitPattern: leUInt32(bytes, recordStart + 12))
            let nameIndex = (nameIndexRaw >= 0 && Int(nameIndexRaw) < nameCount) ? Int(nameIndexRaw) : nil
            return CameraPathNode(points: points, nameIndex: nameIndex, selfIndex: selfIndex, unknownFieldC: fieldC, unknownFieldD: fieldD)
        }
    }

    /// Scans every 4-byte-aligned offset for the one where "read a
    /// `UInt32` count, then that many null-terminated printable-ASCII
    /// strings" lands exactly on end-of-file. Real files have exactly
    /// one such offset (verified on all 15 real files); this is the
    /// count field's own real position, not a coincidence -- a false
    /// positive would need arbitrary bytes to both look like a plausible
    /// count AND have the following data resolve to N valid strings AND
    /// land exactly at EOF, which doesn't happen in real data.
    private static func findStringTable(_ bytes: [UInt8]) -> (offset: Int, names: [String])? {
        var offset = 12
        while offset + 4 <= bytes.count {
            defer { offset += 4 }
            let count = Int(leUInt32(bytes, offset))
            guard count > 0, count < 1000 else { continue }
            guard let names = tryParseStrings(bytes, from: offset + 4, count: count) else { continue }
            return (offset, names)
        }
        return nil
    }

    private static func tryParseStrings(_ bytes: [UInt8], from start: Int, count: Int) -> [String]? {
        var cursor = start
        var names: [String] = []
        names.reserveCapacity(count)
        for _ in 0..<count {
            let stringStart = cursor
            while cursor < bytes.count, bytes[cursor] != 0 {
                guard bytes[cursor] >= 0x20, bytes[cursor] < 0x7F else { return nil }
                cursor += 1
            }
            guard cursor < bytes.count, cursor > stringStart else { return nil }
            names.append(String(decoding: bytes[stringStart..<cursor], as: UTF8.self))
            cursor += 1 // skip the null terminator
        }
        guard cursor == bytes.count else { return nil }
        return names
    }

    private static func leUInt32(_ b: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(b[offset]) | (UInt32(b[offset + 1]) << 8) | (UInt32(b[offset + 2]) << 16) | (UInt32(b[offset + 3]) << 24)
    }

    private static func leFloat32(_ b: [UInt8], _ offset: Int) -> Float {
        Float(bitPattern: leUInt32(b, offset))
    }
}
