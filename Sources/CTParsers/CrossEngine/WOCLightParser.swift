import Foundation
import simd

/// Decoder for WoC `.LGT` (lighting) files -- see `LGT_Spec.md` at the
/// repo root for the full investigation history this is built on.
///
/// **CONFIRMED, file-level framing** (checked against all 37 real files,
/// zero exceptions): `fileSize = 4 (leading count) + 24 (header) +
/// 55*count + 12*K`, where `count` is the leading `UInt32LE` and `K` is a
/// real, present count of "extended" 67-byte records mixed in among the
/// otherwise-uniform 55-byte ones.
///
/// **CONFIRMED, extended record shape** (direct byte verification on
/// `FARM.LGT`, `count=8, K=6`): an extended record is a real 12-byte
/// prefix (present, not decoded -- a leading `UInt32` that was `2` on
/// every extended record checked, plus two floats) immediately followed
/// by the exact same 55-byte "normal" body described below, at
/// `recordStart + 12`. Confirmed by validating the body's radius/color
/// cross-check at that offset -- passes cleanly, and the file's own
/// record order (2 normal records then 6 extended, matching `K=6`
/// exactly by total byte count) resolves without ambiguity.
///
/// **Which records are extended is not knowable from a fixed rule alone**
/// (only one real file's order -- "normal records first" -- has been
/// directly verified, not enough to generalize), so this parser instead
/// resolves record boundaries per file with a validated search: at each
/// position, try both the 55-byte and 67-byte interpretation (bounded by
/// how many of each shape remain per the file's own `count`/`K`), prune
/// to whichever interpretation's body passes the same real
/// radius/color-cross-check validation used for normal records, and only
/// accept a full resolution when it's unique and consumes the record
/// region exactly (byte-exact, no leftover). If a file's boundaries can't
/// be resolved this way (no unique fit, or a search too large to
/// exhaustively prove -- capped rather than guessed), the whole record
/// region is exposed as one raw, undivided blob instead of a guess, same
/// as before.
///
/// **CONFIRMED, per-record "normal" shape** (independently re-verified
/// against real bytes multiple times, most recently by directly decoding
/// `AIRSHIP.LGT`'s own light 0 field-by-field): `position:Vec3` +
/// `extra:Float32` (16 bytes), `radius:Float32` (4 bytes),
/// `colorByte:UInt8x3` (3 bytes, confirmed via WoC's own decompiled
/// symbol table -- `edlightMakeNUCOLOUR3`, a real `NUCOLOUR3` type with
/// no alpha channel), `colorFloat:Float32x3` (12 bytes, confirmed to
/// equal `colorByte/255` to 3 decimal places on every real "normal"
/// record checked), then a 20-byte `tail` that's real but not decoded.
///
/// **A second record shape exists and this parser does NOT attempt to
/// decode it** -- confirmed real (not a bug in reading the normal shape)
/// via a hand check on `AIRSHIP.LGT`'s own light 1: computed "radius"
/// comes out negative and "colorByte"/"colorFloat" don't cross-validate
/// at all. Every record is independently validated (`radius >= 0` and
/// `colorFloat` matching `colorByte/255` within a real tolerance) before
/// being trusted -- a record that fails validation is exposed as `nil`
/// in `File.lights` with its raw 55 bytes preserved in
/// `File.rawRecords`, never silently misdecoded. **Real, useful
/// structure found in when this happens**: on both real `K == 0` files
/// that have a variant record at all (`AIRSHIP.LGT`, `WESTERN.LGT`), it
/// is always the file's *last* record -- a small sample (2 of 2), not a
/// proven rule, so this parser doesn't rely on it structurally (every
/// record is still independently validated on its own merits), but it's
/// worth knowing when interpreting `nil` entries.
///
/// **Checked against a real source reference, real conflict found, left
/// unresolved rather than forced.** `OpenCrashWOC-main/code/src/gamecode/
/// lights.c`'s `LoadLights()` (tagged `//94% NGC`) reads a *different*
/// record shape: a leading `type:Int32` (0 ambient/point, 1 directional,
/// 2 spot), then `pos:Vec3, radius_pos:Vec3, radius:Float32,
/// colorByte:UInt8x3, colorFloat:Vec3x3` (47 bytes total for `type==0`),
/// with a `direction:Vec3` (12 bytes) inserted *between* `colorFloat` and
/// a trailing `globalflag:Int32, brightness:Int32` only when `type` is 1
/// or 2 -- giving 55/67-byte totals that match this parser's own
/// confirmed record sizes exactly, and a real, mechanical explanation for
/// the extended shape's extra 12 bytes (a mid-record insert, not a
/// prefix). Tempting to adopt directly, but it doesn't actually
/// reconcile with what's independently confirmed here: this parser's own
/// "normal" body has no leading `type` field at all -- `position` starts
/// at byte 0 -- and has no separate `radius_pos` field, both load-bearing
/// parts of the source's shape. The source's file-level header also
/// reads as 16 bytes (`LIGHTCOUNT/AMBIENTCOUNT/DIRECTCOUNT/POINTCOUNT`,
/// four `Int32`s), not this parser's own byte-exact-confirmed 28 bytes
/// (checked against all 37 real files, zero exceptions -- a harder
/// verification than a single source reading). Real possibilities, not
/// disambiguated: this source is for a build/version of the format that
/// doesn't exactly match the shipped PS2 disc this parser is verified
/// against; the "94% NGC"-tagged decompilation has a genuine error in
/// this specific function; or there's a reconciling reinterpretation
/// neither reading has found yet. Left as a documented, real lead rather
/// than acted on, since acting on it would mean discarding this file's
/// own harder, corpus-wide byte verification for a single, lower-
/// confidence source reading that doesn't actually fit without
/// unexplained field drops.
public enum WOCLightParser {
    public enum ParseError: Error, Equatable {
        case truncated
    }

    /// One real "normal"-shape light record. See this file's own doc
    /// comment for exactly what's confirmed.
    public struct Light {
        /// Relative offset 0-11 -- a real position, cross-checked
        /// against that same level's `INST` coordinate range in earlier
        /// investigation, but the per-axis assignment (whether this is
        /// literally `(x,y,z)` in that order) is not independently
        /// confirmed here.
        public let position: SIMD3<Float>
        /// Relative offset 12-15 -- a real, present 4th value alongside
        /// `position`; not understood.
        public let extra: Float
        /// Relative offset 16-19.
        public let radius: Float
        /// Relative offset 20-22 -- confirmed `NUCOLOUR3` (no alpha).
        public let colorByte: (UInt8, UInt8, UInt8)
        /// Relative offset 23-34 -- confirmed to equal `colorByte/255`.
        public let colorFloat: SIMD3<Float>
        /// Relative offset 35-54 (20 bytes) -- real, present, not
        /// decoded (contains at least two small `UInt32` fields per
        /// earlier investigation; exposed raw rather than guessed at).
        public let tail: Data
    }

    public struct File {
        /// The header's four `Int32`s -- real, present; only a rough,
        /// unconfirmed correlation with `K` is known (see `LGT_Spec.md`).
        public let header: (Int32, Int32, Int32, Int32)
        /// Two floats following the header ints -- real, not understood.
        public let headerFloats: (Float, Float)
        /// `K` from the confirmed file-size formula -- the count of
        /// "extended" 67-byte records mixed in among the 55-byte ones.
        public let extendedRecordCount: Int
        /// One entry per `count`-many records, in file order. `nil` when
        /// either this specific record failed validation (the second,
        /// undecoded shape) or record boundaries couldn't be resolved at
        /// all for this file (see `boundariesResolved`).
        public let lights: [Light?]
        /// `true` for an entry whose record is the 67-byte extended
        /// shape (12-byte undecoded prefix + the normal body), `false`
        /// for the normal 55-byte shape. Empty when `!boundariesResolved`.
        public let isExtended: [Bool]
        /// `false` when this file's record boundaries couldn't be
        /// uniquely resolved (either no fit consumes the region exactly,
        /// or the search space was too large to exhaustively prove
        /// unique -- never guessed). `lights`/`isExtended`/`rawRecords`
        /// are all-empty/all-nil in that case; use `rawRecordBlob`.
        public let boundariesResolved: Bool
        /// Every record's own raw bytes (55 or 67 depending on
        /// `isExtended`), one entry per `lights` element, same order --
        /// empty when `!boundariesResolved`.
        public let rawRecords: [Data]
        /// The entire record region as one undivided blob -- always
        /// present, redundant with `rawRecords`/`lights` when
        /// `boundariesResolved`.
        public let rawRecordBlob: Data
    }

    public static func parse(_ data: Data) throws -> File {
        let bytes = [UInt8](data)
        guard bytes.count >= 28 else { throw ParseError.truncated }
        let count = Int(leUInt32(bytes, 0))
        let header = (leInt32(bytes, 4), leInt32(bytes, 8), leInt32(bytes, 12), leInt32(bytes, 16))
        let headerFloats = (leFloat32(bytes, 20), leFloat32(bytes, 24))

        let recordRegionStart = 28
        guard count >= 0, bytes.count >= recordRegionStart else { throw ParseError.truncated }
        let recordRegionLength = bytes.count - recordRegionStart
        guard recordRegionLength >= 55 * count else { throw ParseError.truncated }
        let remainder = recordRegionLength - 55 * count
        guard remainder % 12 == 0 else { throw ParseError.truncated }
        let extendedRecordCount = remainder / 12

        let rawRecordBlob = Data(bytes[recordRegionStart...])

        guard let resolved = resolveRecords(bytes, regionStart: recordRegionStart, count: count, extendedCount: extendedRecordCount) else {
            return File(header: header, headerFloats: headerFloats, extendedRecordCount: extendedRecordCount,
                        lights: Array(repeating: nil, count: count), isExtended: [], boundariesResolved: false,
                        rawRecords: [], rawRecordBlob: rawRecordBlob)
        }

        var lights: [Light?] = []
        var isExtended: [Bool] = []
        var rawRecords: [Data] = []
        var pos = recordRegionStart
        for entry in resolved {
            let raw = Data(bytes[pos..<(pos + entry.length)])
            rawRecords.append(raw)
            lights.append(entry.light)
            isExtended.append(entry.length == 67)
            pos += entry.length
        }
        return File(header: header, headerFloats: headerFloats, extendedRecordCount: extendedRecordCount,
                    lights: lights, isExtended: isExtended, boundariesResolved: true,
                    rawRecords: rawRecords, rawRecordBlob: rawRecordBlob)
    }

    /// Resolves each record's real length (55 = normal, 67 = extended) by
    /// a validated, budget-bounded search -- see this file's own top
    /// doc comment for the confirmed extended-record shape and why a
    /// fixed ordering rule isn't assumed. Returns `nil` when no unique,
    /// byte-exact resolution exists (or the search space is too large to
    /// exhaustively prove unique within a sane node budget) -- callers
    /// must fall back to the raw blob rather than guess.
    private static func resolveRecords(_ bytes: [UInt8], regionStart: Int, count: Int, extendedCount: Int) -> [(length: Int, light: Light?)]? {
        guard count >= 0, extendedCount >= 0, extendedCount <= count else { return nil }
        let normalBudget = count - extendedCount

        func validate(at base: Int, length: Int) -> Light?? {
            let bodyBase = length == 67 ? base + 12 : base
            guard bodyBase + 55 <= bytes.count else { return nil }
            return .some(parseValidatedLight(bytes, base: bodyBase))
        }

        var solution: [(Int, Light?)]?
        var ambiguous = false
        var nodesExplored = 0
        let nodeBudget = 200_000

        func dfs(index: Int, pos: Int, normalUsed: Int, extendedUsed: Int, acc: [(Int, Light?)]) {
            if ambiguous { return }
            nodesExplored += 1
            guard nodesExplored <= nodeBudget else { ambiguous = true; return }

            if index == count {
                guard pos == bytes.count else { return }
                if solution != nil { ambiguous = true; solution = nil; return }
                solution = acc
                return
            }

            let normalResult: Light?? = normalUsed < normalBudget ? validate(at: pos, length: 55) : nil
            let extendedResult: Light?? = extendedUsed < extendedCount ? validate(at: pos, length: 67) : nil
            let normalValidates = (normalResult ?? nil) != nil
            let extendedValidates = (extendedResult ?? nil) != nil

            // Prune to whichever shape's body actually validates when
            // only one does -- this keeps the search linear in the
            // common case (confirmed: every record in FARM.LGT resolved
            // this way, zero ambiguity). Explore both only when neither
            // validates (the known "second undecoded shape") or -- in
            // principle -- both do, since then real disambiguation
            // requires the exact-fit constraint at the end.
            let exploreNormal = normalResult != nil && (normalValidates || !extendedValidates)
            let exploreExtended = extendedResult != nil && (extendedValidates || !normalValidates)

            if exploreNormal {
                dfs(index: index + 1, pos: pos + 55, normalUsed: normalUsed + 1, extendedUsed: extendedUsed, acc: acc + [(55, normalResult ?? nil)])
            }
            if ambiguous { return }
            if exploreExtended {
                dfs(index: index + 1, pos: pos + 67, normalUsed: normalUsed, extendedUsed: extendedUsed + 1, acc: acc + [(67, extendedResult ?? nil)])
            }
        }

        dfs(index: 0, pos: regionStart, normalUsed: 0, extendedUsed: 0, acc: [])
        return ambiguous ? nil : solution
    }

    /// Decodes one 55-byte record under the confirmed "normal" shape and
    /// independently validates it before returning -- `nil` if the
    /// record doesn't validate (the second, undecoded shape), rather
    /// than trusting the decode unconditionally.
    private static func parseValidatedLight(_ bytes: [UInt8], base: Int) -> Light? {
        let position = SIMD3(leFloat32(bytes, base), leFloat32(bytes, base + 4), leFloat32(bytes, base + 8))
        let extra = leFloat32(bytes, base + 12)
        let radius = leFloat32(bytes, base + 16)
        let colorByte: (UInt8, UInt8, UInt8) = (bytes[base + 20], bytes[base + 21], bytes[base + 22])
        let colorFloat = SIMD3(leFloat32(bytes, base + 23), leFloat32(bytes, base + 27), leFloat32(bytes, base + 31))
        let tail = Data(bytes[(base + 35)..<(base + 55)])

        guard radius.isFinite, radius >= 0 else { return nil }
        guard colorFloat.x.isFinite, colorFloat.y.isFinite, colorFloat.z.isFinite else { return nil }
        let expected = SIMD3(Float(colorByte.0), Float(colorByte.1), Float(colorByte.2)) / 255.0
        guard simd_length(colorFloat - expected) < 0.01 else { return nil }

        return Light(position: position, extra: extra, radius: radius, colorByte: colorByte, colorFloat: colorFloat, tail: tail)
    }

    private static func leUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func leInt32(_ b: [UInt8], _ o: Int) -> Int32 {
        Int32(bitPattern: leUInt32(b, o))
    }

    private static func leFloat32(_ b: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: leUInt32(b, o))
    }
}
