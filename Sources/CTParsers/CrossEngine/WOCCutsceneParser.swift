import Foundation

/// Decoder for WoC `.CUT` (cutscene) files. See `CUT_Spec.md` at the repo
/// root for the full investigation this is built on, that document is
/// the authority on what's confirmed; this file implements exactly what
/// it verified and nothing beyond it.
///
/// **Design note (important, and different from the spec's own "decoder
/// design sketch")**: `.CUT` uses self-relative pointers with pervasive
/// mid-structure aliasing, which is why the spec's sketch calls for a
/// pointer-following graph walker. But the spec's own byte-accounting
/// tables for all three fully-mapped files (`BLACK.CUT`, `CORRIDOR.CUT`,
/// `STATION.CUT`) are, in every case, a **strictly increasing, gap-free,
/// non-overlapping sequence of offsets**, i.e. the real on-disk layout is
/// linear front-to-back; pointers are used for cross-referencing/aliasing,
/// not for reordering content. This decoder exploits that: it scans
/// forward from the fixed prologue using shape recognizers validated
/// against the spec's own confirmed formulas (transform's `w==1`, the
/// dense-array closer/tail/sentinel magic constants, the sparse table's
/// `weight == 1/Δframe` formula, a track header's self-consistent
/// trailing-pointer count, fixed magic headers), and falls back to raw
/// `.unrecognized` bytes rather than guessing when nothing matches. This
/// produces the same byte-exact result as a graph walk on these 3 files
/// while being far simpler and more robust than pointer-chasing, but it
/// is a real design choice, not something `CUT_Spec.md` itself proposed,
/// so it's called out here explicitly. Pointer fields are still resolved
/// and exposed (for cross-referencing / alias diagnostics) but never used
/// to drive traversal order.
///
/// Fields with confirmed *placement* but only inferred *purpose* (Record
/// C's non-pointer fields, the two free tail floats per dense array, which
/// property a sparse milestone table drives, etc., see `CUT_Spec.md`'s
/// own "purpose gaps" list) are exposed as raw `Data`/plain values, never
/// a guessed named interpretation.
///
/// **A real, promising external reference now exists for this format's
/// remaining ~98% unclassified bytes, documented here as the next
/// investigation target, deliberately NOT adopted without real-bytes
/// reconciliation first, given how different its own organizing
/// principle is from what's confirmed above.** `OpenCrashWOC-main`'s
/// `code/src/gamelib/gcutscn.c` (`NuGCutSceneLoad`, tagged `//PS2` , 
/// asserted behaviorally equivalent to the original PS2 code, not just a
/// GameCube-only reimplementation) is a real file loader for this exact
/// format, and its root struct is DWARF-verified byte-for-byte
/// (`dump_alphaNGCport_DWARF.txt`, 9 duplicate copies, all identical):
/// ```
/// struct NUGCUTSCENE_s {              // 0x28 bytes
///     int version;                     // 0x0 (must be 1)
///     int address_offset;              // 0x4 (a single global relocation
///                                       //      base, not a per-field
///                                       //      self-relative offset , 
///                                       //      every raw pointer field
///                                       //      gets `loadAddress -
///                                       //      address_offset` added once)
///     float nframes;                   // 0x8
///     char* name_table;                // 0xC
///     NUGCUTCAMSYS* cameras;           // 0x10  (nullable)
///     NUGCUTRIGIDSYS* rigids;          // 0x14  (nullable)
///     NUGCUTCHARSYS* chars;            // 0x18  (nullable)
///     NUGCUTLOCATORSYS* locators;      // 0x1C  (nullable)
///     NUGCUTBBOX* bbox;                // 0x20
///     NUGCUTTRIGGERSYS* triggersys;    // 0x24  (nullable)
/// };
/// ```
/// Five real, optional, named subsystems hang off this header (cameras,
/// animated "rigid" props, characters, effect-attachment "locators",
/// level-trigger cross-references), each with its own DWARF-verified
/// struct, real 4x4 transform matrices, real name-table string offsets
/// (confirmed 1-based against `name_table`), and, most relevantly for
/// the unclassified-bytes problem, every animated channel on every one
/// of those five subsystems bottoms out in one shared curve format,
/// `nuanimdata2_s`/`nuanimcurve2_s`/`nuanimcurvedata_s` (the same struct
/// family already cross-checked and ruled out for `CHARS.DAT`'s clip
/// blobs, see `WOCCharacterAnimationCatalogParser`'s own doc comment , 
/// but not yet checked against `.CUT`'s own unclassified regions, a
/// genuinely different question). Its real shape: a `mask:UInt32` per
/// 32-frame chunk (one present/absent bit per frame), a `key_ixs:UInt16`
/// prefix-sum array (one per chunk, a running count of real keys before
/// that chunk), and a tightly packed `key_array` of `NUANIMKEYBIG_s`
/// (`time,dtime,val,grad:Float32`, 16 bytes) or `NUANIMKEYINTEGER_s`
/// (`val,time:Float32`, 8 bytes) records, a real sparse-bitmap-indexed
/// keyframe scheme, decoded via a `BitCountTable` popcount lookup
/// (`nuanim.c:454-544`).
///
/// **Why this isn't adopted as-is**: this format's own organizing
/// principle (one fixed-offset root header with 5 typed subsystem
/// pointers, one global relocation base) is structurally very different
/// from what's independently confirmed above (a linear, front-to-back,
/// shape-recognizer-scanned layout with per-structure self-relative
/// pointers), reconciling the two needs a real check against
/// `BLACK.CUT`/`CORRIDOR.CUT`/`STATION.CUT`'s own already-mapped bytes
/// (does byte 0 read `version==1`? does the address-offset relocation
/// scheme match what pointer fields already found there imply? do any
/// of the "unrecognized" regions have the real mask/key_ixs/key_array
/// triple's structural signature?), not a blind swap-in. Confidence
/// note from the source itself: high for algorithm/field-relationships
/// (explicitly asserted PS2-equivalent), medium for exact byte offsets
/// beyond the DWARF-verified structs (a GameCube alpha port, so 32-bit
/// pointer fields should match, but padding/alignment specifics aren't
/// guaranteed identical to the shipped PS2 disc this parser targets).
/// No subtitle/dialogue-timing data was found anywhere in that
/// reference either (grepped exhaustively), if `.CUT` carries that, it
/// isn't explained by this source.
public enum WOCCutsceneParser {
    // MARK: - Confirmed shared shapes

    /// Row-major 4x4 transform, translation in row 3, the same shape as
    /// `WOCContainerParser.Instance.matrix`.
    public struct Transform {
        public let matrix: (Float, Float, Float, Float,
                             Float, Float, Float, Float,
                             Float, Float, Float, Float,
                             Float, Float, Float, Float)
        public var translation: (Float, Float, Float) { (matrix.12, matrix.13, matrix.14) }
    }

    /// 12-byte "track" header + its trailing pointer list. `pointers.count`
    /// is confirmed to always equal `count + 1` or `count + 4` (never
    /// anything else), see `CUT_Spec.md`'s "Track-header list length:
    /// resolved with a 3rd file". This decoder determines which by
    /// greedily counting consecutive pointer-tagged dwords immediately
    /// following the header and only accepts the header as real if that
    /// count matches one of the two confirmed formulas exactly.
    public struct TrackHeader {
        public let duration: Float
        public let u16A: UInt16
        public let u16B: UInt16
        public let count: UInt32
        /// Real per-pointer resolved offsets (`nil` for an
        /// end-of-list/past-EOF sentinel), in file order.
        public let pointers: [Int?]
    }

    /// 48-byte "Record C", confirmed present after every track header's
    /// pointer list in all 3 files, always opening with `f32 == 1.0`, but
    /// its remaining internal layout genuinely differs per file/instance
    /// (per `CUT_Spec.md`), exposed raw beyond that leading float.
    public struct RecordC {
        public let leadingFloat: Float
        public let raw: Data
    }

    /// 16-byte "Record D", two confirmed shapes.
    public enum RecordD {
        /// `BLACK.CUT`'s shape: `u32, ptr?, ptr?, f32`.
        case twoPointer(u32: UInt32, ptrA: Int?, ptrB: Int?, trailingFloat: Float)
        /// `CORRIDOR.CUT`/`STATION.CUT`'s shape: four pointer-tagged dwords.
        case fourPointer(ptrs: [Int?])
    }

    /// 16-byte quad of `Float32`s, real and confirmed-present at several
    /// fixed structural positions, but semantic meaning is only
    /// medium-confidence per `CUT_Spec.md`, exposed as plain values.
    public struct ChannelQuad {
        public let values: (Float, Float, Float, Float)
    }

    /// One entry of the dense, one-sample-per-frame animation curve
    /// confirmed identically in all six of `STATION.CUT`'s zones.
    public struct DenseFrameChannelEntry {
        public let frameIndex: Float
        public let valueX: Float
        public let valueY: Float
    }

    public struct DenseFrameChannelArray {
        public let entries: [DenseFrameChannelEntry]
        /// Closer's duplicate of the last entry's `valueX` (confirmed to
        /// always match exactly).
        public let closerValueX: Float
        /// The two free floats in the 16-byte "tail" entry, real
        /// per-zone data in most instances, `FLT_MAX` ("no value"
        /// sentinel) in others. Purpose beyond that not confirmed.
        public let tailParam1: Float
        public let tailParam2: Float
    }

    /// One entry of a sparse, milestone-keyed animation curve. `weight` is
    /// confirmed to equal `1 / (nextEntry.milestoneFrame -
    /// milestoneFrame)` for every non-terminal entry, `0` for the last , 
    /// this decoder validates that formula before accepting a candidate
    /// run as a real instance of this shape.
    public struct SparseMilestoneEntry {
        public let milestoneFrame: Float
        public let weight: Float
        public let valueX: Float
        public let valueY: Float
    }

    /// `BLACK.CUT`'s `STARS2`-style named particle/effect reference: a
    /// 16-byte header (2 confirmed pointers + a zero dword) immediately
    /// followed by 7 `Vec4`s (28 floats) of real tuning parameters whose
    /// individual meanings aren't confirmed, and (separately, reached by
    /// this decoder's generic name scanner rather than folded in here)
    /// a null-terminated ASCII name nearby.
    public struct NamedAssetReference {
        public let headerPtrA: Int?
        public let headerPtrB: Int?
        public let parameters: [Float]
    }

    /// `CORRIDOR.CUT`'s repeating 112-byte "track node" unit. The leading
    /// 28-byte header is a real, confirmed constant
    /// (`1,0,0x8000,0,0,0,0x80`), used here as the shape's detector.
    /// Everything past it (5-slot pointer array + 3 channel-quads +
    /// int-list quad) is exposed raw since per-instance slot usage varies
    /// (per `CUT_Spec.md`, unused pointer slots hold real non-zero filler,
    /// not padding, so it can't be cleanly typed without guessing which
    /// slots are "real").
    public struct TrackNodeUnit112 {
        public let raw: Data
    }

    /// `STATION.CUT`'s 16-byte zone "chain header": 3 pointer-tagged
    /// dwords + a trailing scalar. Confirmed arithmetic per
    /// `CUT_Spec.md`: pointer 0 → next zone's array row 1, pointer 1 →
    /// next zone's own start, pointer 2 → this zone's own array row 3
    /// (self-alias), exposed as raw resolved offsets, not asserted as
    /// "next zone" since that's this decoder's own sequential model, not
    /// a value read from the bytes.
    public struct ChainHeader {
        public let pointers: [Int?]
        public let trailingRaw: UInt32
    }

    /// One real node this decoder recognized. `.unrecognized` is an
    /// honest, expected outcome for bytes whose shape doesn't match
    /// anything `CUT_Spec.md` has confirmed, never guessed at.
    public enum Node {
        case rootRecord(kind: UInt32, ptr0: Int?, duration: Float, slot3: UInt32, rootTransformPtr: Int?, slot5: Float, slot6: Float, slot7: UInt32)
        case zeroPadding
        case nodeBHeader(kind: UInt32, ptrA: Int?, ptrB: Int?, slot3: UInt32)
        case reservedBlob
        case transform(Transform)
        case postTransformBlock(leadingU32: UInt32, isAllZeroTail: Bool)
        case trackHeader(TrackHeader)
        case recordC(RecordC)
        case recordD(RecordD)
        case channelQuad(ChannelQuad)
        case denseFrameChannelArray(DenseFrameChannelArray)
        case sparseMilestoneTable([SparseMilestoneEntry])
        case namedAssetReference(NamedAssetReference)
        case trackNodeUnit112(TrackNodeUnit112)
        case chainHeader(ChainHeader)
        case connector(raw: Data, hasKnownMagic: Bool)
        case sentinel16
        case name(String)
        case unrecognized(Data)
    }

    public struct Region {
        public let offset: Int
        public let length: Int
        public let node: Node
    }

    public struct File {
        public let byteCount: Int
        public let pointerConstant: UInt16
        /// Every byte range this decoder accounted for, strictly ordered
        /// and gap-free by construction, verified in tests to sum to
        /// exactly `byteCount` with zero overlaps, matching
        /// `CUT_Spec.md`'s own verification method.
        public let regions: [Region]
    }

    public enum ParseError: Error, Equatable {
        case tooSmallForPrologue
    }

    // MARK: - Entry point

    public static func parse(_ data: Data) throws -> File {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x50 else { throw ParseError.tooSmallForPrologue }

        let pointerConstant = UInt16(leUInt32(bytes, 4) >> 16)
        var scanner = Scanner(bytes: bytes, pointerConstant: pointerConstant)

        // Fixed positional prologue, confirmed byte-identical placement
        // (though not identical population) across all 3 mapped files.
        scanner.emitRootRecord()
        scanner.emit(0x20, 16, .zeroPadding)
        scanner.emitNodeBHeader()
        scanner.emit(0x40, 16, .reservedBlob)

        // Everything else: sequential shape scan to EOF.
        scanner.scanForward(to: bytes.count)

        return File(byteCount: bytes.count, pointerConstant: pointerConstant, regions: scanner.regions)
    }

    // MARK: - Byte helpers

    static func leUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o+1]) << 8) | (UInt32(b[o+2]) << 16) | (UInt32(b[o+3]) << 24)
    }
    static func leUInt16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o+1]) << 8)
    }
    static func leFloat32(_ b: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: leUInt32(b, o))
    }

    // MARK: - Scanner

    private struct Scanner {
        let bytes: [UInt8]
        let pointerConstant: UInt16
        var regions: [Region] = []

        func isPointerTagged(_ raw: UInt32) -> Bool {
            raw != 0 && UInt16(raw >> 16) == pointerConstant
        }

        func resolvePointer(_ raw: UInt32) -> Int? {
            guard isPointerTagged(raw) else { return nil }
            let lo = Int(raw & 0xFFFF)
            guard lo < bytes.count else { return nil }
            return lo
        }

        mutating func emit(_ offset: Int, _ length: Int, _ node: Node) {
            regions.append(Region(offset: offset, length: length, node: node))
        }

        mutating func emitRootRecord() {
            let k = WOCCutsceneParser.leUInt32(bytes, 0)
            let ptr0Raw = WOCCutsceneParser.leUInt32(bytes, 4)
            let dur = WOCCutsceneParser.leFloat32(bytes, 8)
            let slot3 = WOCCutsceneParser.leUInt32(bytes, 12)
            let xformPtrRaw = WOCCutsceneParser.leUInt32(bytes, 16)
            let slot5 = WOCCutsceneParser.leFloat32(bytes, 20)
            let slot6 = WOCCutsceneParser.leFloat32(bytes, 24)
            let slot7 = WOCCutsceneParser.leUInt32(bytes, 28)
            emit(0, 32, .rootRecord(kind: k, ptr0: resolvePointer(ptr0Raw), duration: dur, slot3: slot3,
                                     rootTransformPtr: resolvePointer(xformPtrRaw), slot5: slot5, slot6: slot6, slot7: slot7))
        }

        mutating func emitNodeBHeader() {
            let k = WOCCutsceneParser.leUInt32(bytes, 0x30)
            let a = WOCCutsceneParser.leUInt32(bytes, 0x34)
            let b = WOCCutsceneParser.leUInt32(bytes, 0x38)
            let c = WOCCutsceneParser.leUInt32(bytes, 0x3C)
            emit(0x30, 16, .nodeBHeader(kind: k, ptrA: resolvePointer(a), ptrB: resolvePointer(b), slot3: c))
        }

        // MARK: Shape detectors, tried in priority order at each offset.

        /// Transform: 64 bytes, translation row's w must be ~1.0 and no
        /// NaN/Inf anywhere in the 16 floats. `w≈1.0` alone is too weak
        /// (confirmed by a real false match on garbage-looking filler
        /// data whose 16th float happened to be exactly 1.0) -- a real
        /// transform's 3x3 rotation submatrix has unit-length rows by
        /// construction, so this also requires each of the first 3 rows
        /// to have length within [0.8, 1.2] of 1.0, which random/filler
        /// float data essentially never satisfies simultaneously.
        func tryTransform(at o: Int) -> Int? {
            guard o + 64 <= bytes.count else { return nil }
            var vals = [Float](repeating: 0, count: 16)
            for i in 0..<16 {
                let f = WOCCutsceneParser.leFloat32(bytes, o + i * 4)
                guard f.isFinite else { return nil }
                vals[i] = f
            }
            guard abs(vals[15] - 1.0) < 0.01 else { return nil }
            for rowStart in [0, 4, 8] {
                let sumSq = vals[rowStart] * vals[rowStart] + vals[rowStart + 1] * vals[rowStart + 1] + vals[rowStart + 2] * vals[rowStart + 2]
                let len = sumSq.squareRoot()
                guard len >= 0.8, len <= 1.2 else { return nil }
            }
            return 64
        }

        func readTransform(at o: Int) -> Transform {
            var m = [Float](repeating: 0, count: 16)
            for i in 0..<16 { m[i] = WOCCutsceneParser.leFloat32(bytes, o + i * 4) }
            return Transform(matrix: (m[0],m[1],m[2],m[3],m[4],m[5],m[6],m[7],m[8],m[9],m[10],m[11],m[12],m[13],m[14],m[15]))
        }

        /// Dense frame-channel array: entries with `frameIndex == n`,
        /// `f32@+4 == 1.0` (exact bit pattern), followed by an
        /// exact-magic closer, exact-magic tail header, and the exact
        /// 16-byte sentinel. All three trailing magics must match exactly
        /// or the whole candidate is rejected.
        func tryDenseFrameChannelArray(at o: Int) -> (Node, Int)? {
            guard o + 16 <= bytes.count else { return nil }
            var entries: [DenseFrameChannelEntry] = []
            var cursor = o
            var n: Float = 1
            // Bounded loop. Unlike the sparse-table cap (see that
            // function's own comment for the real 34-entry counter-
            // example that motivated raising it), this check was already
            // effectively incremental -- `frameIndex == n` exactly is
            // checked every iteration, so a non-matching candidate always
            // bails within 1 entry regardless of the cap. Raised from 256
            // (chosen from STATION.CUT's confirmed 110-entry maximum) to
            // 4096 defensively, matching the sparse-table cap, since
            // large .CUT files are now confirmed to exercise this
            // decoder's shapes at a bigger scale than the 3 hand-mapped
            // files did.
            while cursor + 16 <= bytes.count, entries.count < 4096 {
                let frameIndex = WOCCutsceneParser.leFloat32(bytes, cursor)
                let constant = WOCCutsceneParser.leUInt32(bytes, cursor + 4)
                guard frameIndex == n, constant == Float(1.0).bitPattern else { break }
                let vx = WOCCutsceneParser.leFloat32(bytes, cursor + 8)
                let vy = WOCCutsceneParser.leFloat32(bytes, cursor + 12)
                entries.append(DenseFrameChannelEntry(frameIndex: frameIndex, valueX: vx, valueY: vy))
                cursor += 16
                n += 1
            }
            guard entries.count >= 8 else { return nil }
            guard cursor + 48 <= bytes.count else { return nil }
            // Closer: f32 == entries.count+1, u32 == 0x1BC72204, f32 == last valueX, f32 == 0.
            let closerFrame = WOCCutsceneParser.leFloat32(bytes, cursor)
            let closerMagic = WOCCutsceneParser.leUInt32(bytes, cursor + 4)
            let closerValueX = WOCCutsceneParser.leFloat32(bytes, cursor + 8)
            let closerZero = WOCCutsceneParser.leFloat32(bytes, cursor + 12)
            guard closerFrame == Float(entries.count + 1), closerMagic == 0x1BC72204,
                  closerValueX == entries.last!.valueX, closerZero == 0 else { return nil }
            // Tail: u16x4 == (0,32,64,96), then 2 free floats.
            let t0 = WOCCutsceneParser.leUInt16(bytes, cursor + 16)
            let t1 = WOCCutsceneParser.leUInt16(bytes, cursor + 18)
            let t2 = WOCCutsceneParser.leUInt16(bytes, cursor + 20)
            let t3 = WOCCutsceneParser.leUInt16(bytes, cursor + 22)
            guard t0 == 0, t1 == 32, t2 == 64, t3 == 96 else { return nil }
            let tail1 = WOCCutsceneParser.leFloat32(bytes, cursor + 24)
            let tail2 = WOCCutsceneParser.leFloat32(bytes, cursor + 28)
            // Sentinel: FF x13, 0x7F, 0x00, 0x00.
            for i in 0..<13 { guard bytes[cursor + 32 + i] == 0xFF else { return nil } }
            guard bytes[cursor + 45] == 0x7F, bytes[cursor + 46] == 0x00, bytes[cursor + 47] == 0x00 else { return nil }

            let array = DenseFrameChannelArray(entries: entries, closerValueX: closerValueX, tailParam1: tail1, tailParam2: tail2)
            let totalLength = (cursor + 48) - o
            return (.denseFrameChannelArray(array), totalLength)
        }

        /// Sparse milestone table: consecutive 16-byte entries where
        /// `weight == 1/(nextFrame - frame)` for every non-terminal entry
        /// (checked within 0.5% relative tolerance) and the final entry's
        /// weight is exactly 0. Requires >=2 entries to accept.
        func trySparseMilestoneTable(at o: Int) -> (Node, Int)? {
            // Validates the reciprocal-delta formula INCREMENTALLY,
            // between each newly-read entry and the one before it, rather
            // than collecting a fixed-size batch and validating
            // afterward. This matters for two reasons:
            // - Correctness: a real table found in a large .CUT file
            //   (SUNNY.CUT, offset 0x3190) has 34 real entries -- far
            //   past the old fixed cap of 16, which silently rejected it
            //   even though every single transition validates cleanly.
            // - Performance: "all 4 floats finite" alone is too weak a
            //   stop condition (most random binary reinterprets as finite
            //   floats), so the cap can't just be raised blindly -- that
            //   reintroduces the O(n) -per-candidate / O(n^2)-overall scan
            //   this function was previously capped at 16 to avoid. With
            //   incremental validation, a non-matching candidate still
            //   bails after reading just 2 entries (the formula check
            //   between them fails almost always on real random data), so
            //   raising the cap doesn't reintroduce that blowup -- it only
            //   lets a genuinely-matching long run keep extending.
            var raw: [(Float, Float, Float, Float)] = []
            var cursor = o
            while cursor + 16 <= bytes.count, raw.count < 4096 {
                let frame = WOCCutsceneParser.leFloat32(bytes, cursor)
                let weight = WOCCutsceneParser.leFloat32(bytes, cursor + 4)
                let vx = WOCCutsceneParser.leFloat32(bytes, cursor + 8)
                let vy = WOCCutsceneParser.leFloat32(bytes, cursor + 12)
                guard frame.isFinite, weight.isFinite, vx.isFinite, vy.isFinite else { break }
                // Sanity bounds matching real confirmed data (milestone
                // frames and weights are small, duration-scale numbers) --
                // without this, a huge frame delta drives the reciprocal
                // formula's expected value toward 0, and the check below's
                // absolute-tolerance term then matches almost anything
                // near 0 too (a real false positive found on garbage
                // filler data during development).
                guard abs(frame) < 100_000, abs(weight) < 1000 else { break }
                if let last = raw.last {
                    let delta = frame - last.0
                    guard delta != 0 else { break }
                    let expected = 1.0 / delta
                    // A near-zero (e.g. subnormal) delta makes `1/delta`
                    // overflow to +/-Infinity in Float arithmetic -- and
                    // without this guard, both the difference and the
                    // tolerance below become Infinity too, so `Inf <= Inf`
                    // silently passes instead of rejecting (a real false
                    // positive found on garbage filler data).
                    guard expected.isFinite else { break }
                    guard abs(last.1 - expected) <= max(abs(expected) * 0.005, 0.00001) else { break }
                }
                raw.append((frame, weight, vx, vy))
                if weight == 0 { cursor += 16; break }
                cursor += 16
            }
            guard raw.count >= 2 else { return nil }
            guard raw.last!.1 == 0 else { return nil }
            let entries = raw.map { SparseMilestoneEntry(milestoneFrame: $0.0, weight: $0.1, valueX: $0.2, valueY: $0.3) }
            return (.sparseMilestoneTable(entries), raw.count * 16)
        }

        /// Track header: `u16A` must be exactly 1 (confirmed constant
        /// across every known instance), `count` must be small, and the
        /// trailing pointer-tagged dword run immediately following must
        /// have length exactly `count+1` or `count+4` (the only two
        /// confirmed formulas), self-validating, rejects otherwise.
        func tryTrackHeader(at o: Int) -> (Node, Int)? {
            guard o + 12 <= bytes.count else { return nil }
            let dur = WOCCutsceneParser.leFloat32(bytes, o)
            guard dur.isFinite, dur >= 0, dur < 100_000 else { return nil }
            let u16A = WOCCutsceneParser.leUInt16(bytes, o + 4)
            guard u16A == 1 else { return nil }
            let u16B = WOCCutsceneParser.leUInt16(bytes, o + 6)
            let count = WOCCutsceneParser.leUInt32(bytes, o + 8)
            guard count < 10_000 else { return nil }

            var runLength = 0
            var cursor = o + 12
            while cursor + 4 <= bytes.count {
                let raw = WOCCutsceneParser.leUInt32(bytes, cursor)
                guard isPointerTagged(raw) else { break }
                runLength += 1
                cursor += 4
            }
            guard runLength == Int(count) + 1 || runLength == Int(count) + 4 else { return nil }

            var pointers: [Int?] = []
            for i in 0..<runLength {
                let raw = WOCCutsceneParser.leUInt32(bytes, o + 12 + i * 4)
                pointers.append(resolvePointer(raw))
            }
            let header = TrackHeader(duration: dur, u16A: u16A, u16B: u16B, count: count, pointers: pointers)
            return (.trackHeader(header), 12 + runLength * 4)
        }

        /// Record C: 48 bytes, confirmed to always open with `f32 == 1.0`
        /// in all 3 mapped files. That alone is too weak a validator --
        /// `BLACK.CUT` has a real filler `Vec4` of `1.0`s immediately
        /// before the real Record C, and the real Record C's own pointer
        /// field (normally at `+4`) ends up sitting at the false
        /// candidate's `+12` by coincidence, so a single secondary field
        /// check isn't enough to disambiguate -- confirmed by hand
        /// against real bytes. Requires BOTH: `+4` is a pointer or a
        /// small `{0,1}` integer (true in all 3 files: `BLACK.CUT` has a
        /// pointer there, `CORRIDOR.CUT`/`STATION.CUT` have `1`/`0`), AND
        /// `+12` is a real pointer (true in all 3: `BLACK.CUT`
        /// `ptr→0x13C`, `CORRIDOR.CUT` `ptr→0x118`, `STATION.CUT`
        /// `ptr→0x228`). The false `Vec4` candidate fails the `+4` half
        /// of this (a real `1.0` float there, neither a pointer nor
        /// `{0,1}`) even though it passes the `+12` half alone.
        func tryRecordC(at o: Int) -> (Node, Int)? {
            guard o + 48 <= bytes.count else { return nil }
            let lead = WOCCutsceneParser.leFloat32(bytes, o)
            guard lead == 1.0 else { return nil }
            let d1 = WOCCutsceneParser.leUInt32(bytes, o + 4)
            guard isPointerTagged(d1) || d1 == 0 || d1 == 1 else { return nil }
            let d3 = WOCCutsceneParser.leUInt32(bytes, o + 12)
            guard isPointerTagged(d3) else { return nil }
            let raw = Data(bytes[o..<(o + 48)])
            return (.recordC(RecordC(leadingFloat: lead, raw: raw)), 48)
        }

        /// Record D: 16 bytes, two confirmed shapes, try the 4-pointer
        /// variant first (stricter: requires 4/4 dwords pointer-tagged),
        /// then the 2-pointer + u32 + f32 variant.
        func tryRecordD(at o: Int) -> (Node, Int)? {
            guard o + 16 <= bytes.count else { return nil }
            let d0 = WOCCutsceneParser.leUInt32(bytes, o)
            let d1 = WOCCutsceneParser.leUInt32(bytes, o + 4)
            let d2 = WOCCutsceneParser.leUInt32(bytes, o + 8)
            let d3 = WOCCutsceneParser.leUInt32(bytes, o + 12)
            if isPointerTagged(d0), isPointerTagged(d1), isPointerTagged(d2), isPointerTagged(d3) {
                let ptrs = [d0, d1, d2, d3].map { resolvePointer($0) }
                return (.recordD(.fourPointer(ptrs: ptrs)), 16)
            }
            // `d0 == 1` exactly, per the only confirmed twoPointer
            // instance (`BLACK.CUT` 0x110) -- `0` isn't actually
            // confirmed and accepting it produced a real false positive
            // (BLACK.CUT's zero tail immediately preceding the STARS2
            // header's own two real pointers satisfied a looser check).
            if d0 == 1, isPointerTagged(d1), isPointerTagged(d2) {
                let f = WOCCutsceneParser.leFloat32(bytes, o + 12)
                guard f.isFinite, abs(f) < 100_000 else { return nil }
                return (.recordD(.twoPointer(u32: d0, ptrA: resolvePointer(d1), ptrB: resolvePointer(d2), trailingFloat: f)), 16)
            }
            return nil
        }

        /// `CORRIDOR.CUT`'s 112-byte periodic unit: detected by its exact
        /// 28-byte magic header. Consumes `min(112, remaining)` bytes
        /// since the confirmed final instance in `CORRIDOR.CUT` is
        /// truncated by EOF at 64 bytes.
        func tryTrackNodeUnit112(at o: Int) -> (Node, Int)? {
            guard o + 28 <= bytes.count else { return nil }
            let magic: [UInt32] = [1, 0, 0x8000, 0, 0, 0, 0x80]
            for (i, expected) in magic.enumerated() {
                guard WOCCutsceneParser.leUInt32(bytes, o + i * 4) == expected else { return nil }
            }
            let length = min(112, bytes.count - o)
            let raw = Data(bytes[o..<(o + length)])
            return (.trackNodeUnit112(TrackNodeUnit112(raw: raw)), length)
        }

        /// `STATION.CUT`'s 16-byte sentinel: `FF x13, 0x7F, 0x00, 0x00`.
        func trySentinel16(at o: Int) -> (Node, Int)? {
            guard o + 16 <= bytes.count else { return nil }
            for i in 0..<13 { guard bytes[o + i] == 0xFF else { return nil } }
            guard bytes[o + 13] == 0x7F, bytes[o + 14] == 0x00, bytes[o + 15] == 0x00 else { return nil }
            return (.sentinel16, 16)
        }

        /// `STATION.CUT`'s zone chain header: 16 bytes, 3 pointer-tagged
        /// dwords, validated by requiring a dense-frame-channel-array
        /// (entry 1 = `frameIndex==1.0, f32==1.0`) to begin immediately
        /// after it, this cross-check is what keeps it from colliding
        /// with the generic `ChannelQuad` fallback.
        func tryChainHeader(at o: Int) -> (Node, Int)? {
            guard o + 32 <= bytes.count else { return nil }
            let d0 = WOCCutsceneParser.leUInt32(bytes, o)
            let d1 = WOCCutsceneParser.leUInt32(bytes, o + 4)
            let d2 = WOCCutsceneParser.leUInt32(bytes, o + 8)
            let d3 = WOCCutsceneParser.leUInt32(bytes, o + 12)
            guard isPointerTagged(d0), isPointerTagged(d1), isPointerTagged(d2) else { return nil }
            let nextFrame = WOCCutsceneParser.leFloat32(bytes, o + 16)
            let nextConstant = WOCCutsceneParser.leUInt32(bytes, o + 20)
            guard nextFrame == 1.0, nextConstant == Float(1.0).bitPattern else { return nil }
            let header = ChainHeader(pointers: [d0, d1, d2].map { resolvePointer($0) }, trailingRaw: d3)
            return (.chainHeader(header), 16)
        }

        /// `STATION.CUT` Zone 1's 28-byte connector: detected by its
        /// fixed magic constant `0x03629DC8` at sub-offset +20.
        func tryConnector(at o: Int) -> (Node, Int)? {
            guard o + 28 <= bytes.count else { return nil }
            guard WOCCutsceneParser.leUInt32(bytes, o + 20) == 0x03629DC8 else { return nil }
            let raw = Data(bytes[o..<(o + 28)])
            return (.connector(raw: raw, hasKnownMagic: true), 28)
        }

        /// `BLACK.CUT`'s named-asset/effect reference: 16-byte header
        /// (dword0 + dword1 pointer-tagged, dword3 == 0) immediately
        /// followed by 7 Vec4s (112 bytes) of real parameters.
        func tryNamedAssetReference(at o: Int) -> (Node, Int)? {
            guard o + 128 <= bytes.count else { return nil }
            let d0 = WOCCutsceneParser.leUInt32(bytes, o)
            let d1 = WOCCutsceneParser.leUInt32(bytes, o + 4)
            let d2 = WOCCutsceneParser.leUInt32(bytes, o + 8)
            let d3 = WOCCutsceneParser.leUInt32(bytes, o + 12)
            // Confirmed shape is a real 3-pointer header (name pointer,
            // sibling pointer, mid-block alias) + a zero dword -- only
            // checking 2 of the 3 pointers plus the zero was loose enough
            // to false-match inside `STATION.CUT` Zone 1's "Record-C-like"
            // block (which also has scattered pointer-tagged dwords).
            guard isPointerTagged(d0), isPointerTagged(d1), isPointerTagged(d2), d3 == 0 else { return nil }
            var params: [Float] = []
            for i in 0..<28 {
                let f = WOCCutsceneParser.leFloat32(bytes, o + 16 + i * 4)
                // Real tuning parameters are small; a misread pointer
                // bit-pattern reinterpreted as a float is huge -- bounding
                // this catches false starts the pointer-tag checks above
                // don't (as seen in the Zone 1 false match).
                guard f.isFinite, abs(f) < 1_000_000 else { return nil }
                params.append(f)
            }
            // Final cross-check: the one confirmed real instance
            // (`BLACK.CUT`'s STARS2 reference) is followed shortly after
            // its 128-byte header+params by a printable name -- require
            // that here too. Without this, the header-shape checks above
            // still coincidentally matched `STATION.CUT` Zone 1's
            // "Record-C-like" block (whose own tail pointer triplet + a
            // trailing zero mimics this shape, and whose neighboring
            // sparse-table values are small enough to pass the parameter
            // bound too) -- but that block is never followed by a name.
            var lookahead = o + 128
            var foundName = false
            while lookahead < min(o + 128 + 64, bytes.count) {
                if tryName(at: lookahead) != nil { foundName = true; break }
                lookahead += 4
            }
            guard foundName else { return nil }
            let ref = NamedAssetReference(headerPtrA: resolvePointer(d0), headerPtrB: resolvePointer(d1), parameters: params)
            return (.namedAssetReference(ref), 128)
        }

        /// Generic null-terminated printable-ASCII name, used both for
        /// `BLACK.CUT`'s `STARS2` name and `STATION.CUT`'s trailing
        /// string pool (which naturally falls out as consecutive `.name`
        /// regions since each string there is directly null-terminated
        /// then followed by the next).
        func tryName(at o: Int) -> (Node, Int)? {
            guard o < bytes.count else { return nil }
            var end = o
            while end < bytes.count, bytes[end] != 0 {
                guard bytes[end] >= 0x20, bytes[end] < 0x7F else { return nil }
                end += 1
            }
            // Require a real minimum length so this doesn't fire on
            // coincidental short printable runs inside unrelated binary
            // data (every confirmed real name in this format is >=6
            // chars: "STARS2", "lower_ring", "top_ring", "station1").
            guard end < bytes.count, end - o >= 4 else { return nil }
            let str = String(decoding: bytes[o..<end], as: UTF8.self)
            return (.name(str), end - o + 1)
        }

        /// Generic 16-byte fallback: 4 finite floats, no NaN/Inf.
        func tryChannelQuad(at o: Int) -> (Node, Int)? {
            guard o + 16 <= bytes.count else { return nil }
            var v = [Float](repeating: 0, count: 4)
            for i in 0..<4 {
                let f = WOCCutsceneParser.leFloat32(bytes, o + i * 4)
                guard f.isFinite else { return nil }
                v[i] = f
            }
            return (.channelQuad(ChannelQuad(values: (v[0], v[1], v[2], v[3]))), 16)
        }

        // MARK: Forward scan
        //
        // Tries strong, formula-validated shape detectors (in confidence
        // order) at the current offset. If none match, this does NOT fall
        // back to a greedy fixed-size read (that risks exactly the
        // misalignment bug this design is built to avoid: filler regions
        // between real structures are NOT always multiples of 16 bytes --
        // e.g. `BLACK.CUT` has an 8-byte gap then two 16-byte Vec4s before
        // its next real anchor, `STATION.CUT` has a 20-byte gap -- so
        // blindly consuming 16 bytes at a time drifts out of phase with
        // the real structure and every later offset misclassifies).
        // Instead it scans ahead (4-byte aligned) for the next offset
        // where a strong detector *does* match, and emits everything in
        // between as a single bounded, honestly-unrecognized gap (or as
        // `.channelQuad` in the one case where the gap is exactly 16
        // bytes of finite floats, since several confirmed real 16-byte
        // filler quads are exactly this shape).

        func tryStrongDetector(at o: Int) -> (Node, Int)? {
            if let r = tryDenseFrameChannelArray(at: o) { return r }
            if let r = trySparseMilestoneTable(at: o) { return r }
            if let r = tryTrackHeader(at: o) { return r }
            if let len = tryTransform(at: o) { return (.transform(readTransform(at: o)), len) }
            if let r = tryTrackNodeUnit112(at: o) { return r }
            if let r = trySentinel16(at: o) { return r }
            if let r = tryChainHeader(at: o) { return r }
            if let r = tryConnector(at: o) { return r }
            if let r = tryNamedAssetReference(at: o) { return r }
            if let r = tryRecordC(at: o) { return r }
            if let r = tryRecordD(at: o) { return r }
            if let r = tryName(at: o) { return r }
            return nil
        }

        mutating func scanForward(to end: Int) {
            var offset = regions.last.map { $0.offset + $0.length } ?? 0

            while offset < end {
                if offset == 0x50, let len = tryTransform(at: offset) {
                    emit(offset, len, .transform(readTransform(at: offset)))
                    offset += len
                    // The `u32=1`+12-zero block is confirmed to sit
                    // positionally right after the root transform.
                    if offset + 16 <= end {
                        let lead = WOCCutsceneParser.leUInt32(bytes, offset)
                        var allZero = true
                        for i in 4..<16 { if bytes[offset + i] != 0 { allZero = false; break } }
                        emit(offset, 16, .postTransformBlock(leadingU32: lead, isAllZeroTail: allZero))
                        offset += 16
                    }
                    continue
                }

                if let (node, len) = tryStrongDetector(at: offset) {
                    emit(offset, len, node)
                    offset += len
                    continue
                }

                // Nothing matched here -- scan ahead for the next real
                // anchor and bound the gap exactly at it.
                var probe = offset + 4
                var anchor: Int? = nil
                while probe < end {
                    if tryStrongDetector(at: probe) != nil { anchor = probe; break }
                    probe += 4
                }
                let gapEnd = anchor ?? end
                if gapEnd - offset == 16, let (node, _) = tryChannelQuad(at: offset) {
                    emit(offset, 16, node)
                } else {
                    emit(offset, gapEnd - offset, .unrecognized(Data(bytes[offset..<gapEnd])))
                }
                offset = gapEnd
            }
        }
    }
}
