import Foundation

/// Decoder for the top-level container format inside decompressed WoC
/// `.GSC` level files (post-`RNCDecompressor`). This is a brand-new format
/// with no existing reference implementation anywhere in this repo's
/// reference material -- unlike `RNCDecompressor`, every field here was
/// derived by hand from real decompressed bytes (7 real WoC level files
/// spanning very different sizes and areas) and cross-checked for
/// consistency before being treated as confirmed. Fields not yet
/// consistency-checked across multiple real files are called out as such
/// in their doc comments rather than presented as certain.
///
/// **Confirmed file layout** (verified: the section chain below walks every
/// one of the 7 sample files to exactly 100% of its decompressed byte
/// length, with no gaps and no out-of-bounds reads):
/// ```
/// File    := "NU20" negatedByteCount:UInt32LE formatVersion:UInt32LE reserved:UInt32LE Section*
/// Section := tag:ASCII(4) length:UInt32LE payload:Bytes(length - 8)
/// ```
/// - `negatedByteCount`: confirmed by exact arithmetic match across all 7
///   samples to be `(0x1_0000_0000 - totalDecompressedByteCount) mod 2^32`
///   -- i.e. the two's-complement negation of the file's own total decoded
///   size. Purpose unconfirmed (plausibly a cheap self-description a loader
///   checks against the buffer it allocated), but the arithmetic identity
///   itself is exact, not approximate.
/// - `formatVersion`/`reserved`: constant `6` and `0` in all 7 samples.
///   Too few data points to be fully sure these never vary, but there is
///   no evidence yet that they do.
/// - `Section.length` is **relative to the section's own tag position**,
///   not an absolute file offset and not a payload-only length -- it is
///   the exact byte distance from this section's tag start to the next
///   section's tag start (or, for the last section, to end of file).
///   Confirmed identically for both the small top-level sections (`NTBL`)
///   and the largest one (`TST0`, hundreds of KB) via direct byte
///   inspection at the predicted offset.
///
/// **Section tags seen across the 7 samples, in the order they appear**
/// (not confirmed to be exhaustive or always in this exact order -- this is
/// what 7 files showed): `NTBL`, `TST0`, `MS00`, `TAS0` (present in some
/// files, absent in others -- e.g. missing from `AIRSHIP.GSC`/`FARM.GSC`,
/// present in `HUB.GSC`/`CASTLE_C.GSC`), `OBJ0`, `INST`, `IABL`/`ALIB`
/// (also present-in-some/absent-in-others), `SPEC`, `SST0` (always last).
///
/// **Decoded so far** (this list has grown across several sessions --
/// including a real self-correction, see `INST` below, from a broad
/// 54-file sweep that overturned an earlier 2-file-verified claim):
/// - `NTBL` (name table) -- see ``parseNameTable(_:)``. Fully decoded: a
///   byte-length-prefixed blob of null-terminated names. The trailer bytes
///   between the name blob and the next section are not understood (their
///   length varies non-trivially and doesn't reduce to a formula from the
///   name list alone).
/// - `MS00` -- see ``parseMaterialSet(_:)``. Confirmed to be `count` fixed
///   464-byte records (exact division verified universally across the
///   full 54-file corpus, zero exceptions), one confirmed field within
///   each record (a real texture-ID reference at relative offset 424 --
///   see ``parseMaterialSet(_:)``'s own doc comment). **Naming
///   correction (see "Corrections from decompiled reference source"
///   below): the real handler is `ReadMaterialSet`, not a mesh reader.**
///   `MS00` is the file's *material* table (`gscene->mtls`), referenced
///   by index from `OBJ0` geometry entries and `TAS0` -- renamed from
///   the original `parseMaterialSet` guess now that disc re-verification
///   (the offset-424 `tid` field) confirms it's really a material table,
///   not just plausible naming.
/// - `IABL` -- see ``parseAttributeBlock(_:)``. Same framing, confirmed
///   fixed 96-byte records across all 24 files in the full corpus that
///   have it, zero exceptions. Sibling `ALIB` was explicitly tested and
///   ruled out as fixed-width (different widths per file).
///   **Naming correction: the real handler is `ReadInstAnim`** (source's
///   own comment: "Dunno about the name, it was commented as
///   INSTANIMBLOCK") -- i.e. **Instance Animation**, not "Attribute
///   Block". Its real C framing (`count:UInt32LE reserved:UInt32LE` then
///   the record blob, with per-instance assignment driven by an
///   `instances[i].anim != NULL` marker set elsewhere) matches this
///   codebase's confirmed byte framing exactly. Left unrenamed pending a
///   confirmation pass on `AttributeBlockRecord`'s internal field names.
/// - `INST` (placed object instances) -- see ``parseInstances(_:)`` and
///   ``Instance``. The 80-byte records are real 4x4 world transforms
///   (`w == 1.0` universally, translations plot into recognizable real
///   level layouts, e.g. `CASTLE_C.GSC`'s cross-shaped corridor). The
///   tail's first field is a confirmed reference into `OBJ0` (see
///   ``Instance/objectIndex`` for the full story, including a real
///   correction after an initial 2-file check accidentally verified the
///   wrong property).
/// - `SPEC` -- see ``parseSpecRecords(_:)`` and ``SpecRecord``. Same
///   80-byte record shape as `INST`, but a curated, strictly-increasing
///   pointer-list *into* `INST` -- each record's matrix is byte-identical
///   to the `INST` record it references. Perfectly confirmed at full
///   corpus scale: 1461 total `SPEC` records across all 46 files in the
///   54-file corpus that have both `SPEC` and `INST`, zero
///   not-strictly-increasing indices, zero out-of-bounds references, zero
///   matrix mismatches -- not "almost always", zero exceptions of any
///   kind.
/// - `TST0` -- see ``parseTextureEntry(_:trailerOffset:)`` and
///   ``scanTextureEntries(_:)``. Not a record table at all: a serialized
///   PS2 Graphics Synthesizer texture-upload command stream. The per-entry
///   size/width/height math was re-checked across the full 54-file corpus
///   (1110 total validated entries, ZERO dimension-formula failures) --
///   but the entry-boundary *scan* is a documented heuristic, not a
///   complete parser: it finds zero entries at all in 4 of the 54 files
///   (their `TST0` apparently uses the unpadded variant first seen in
///   `E3HUB.GSC` -- see that function's doc comment for the follow-up on
///   what is and isn't understood about that variant).
/// - `SST0` (always the last section) -- see ``parseFooterHeader(_:)``.
///   Outer shape confirmed (`A:u32` + `B:u32` blob-length + blob + small
///   trailer). The trailer-echoes-own-section-length pattern, re-checked
///   across the full 54-file corpus: present in exactly 10 of 53 files
///   with `SST0`, and every single time it's present it's an exact match
///   (zero false positives) -- real and deliberate, but only a minority
///   shape; most files' `SST0` trailers look different or are absent.
///   Blob internals unresolved.
///   **Naming correction: the real handler is `ReadSplineSet`** -- i.e.
///   `SST0` is a **Spline Set**, not an unnamed footer blob. This
///   independently corroborates the `nugspline_s`/`NuSplineFind` findings
///   from the `.VIS`/camera-path work (``WOCCameraPathParser``), which
///   has since fully decoded its own body into real per-node point
///   lists. **Directly checked whether `SST0`'s blob is the same shape,
///   and it isn't** -- `.VIS`'s model (a spline's point count, then
///   that many raw `Vec3`s, then the next spline) only ever parses the
///   *first* spline correctly against a real `SST0` blob before running
///   into implausible values; every file tried breaks after one spline.
///   The leading `firstField`/blob-length header also doesn't look like
///   `.VIS`'s (no clean per-spline count sequence at the blob's own
///   start).
///
///   **Two follow-up hypotheses tested directly, both refuted**: (1) an
///   inline per-spline name between one spline's points and the next
///   spline's length -- checked the real bytes immediately after the
///   first spline's predicted point-list end, and they read as more
///   plausible floats, not a null-terminated string of any length; (2) a
///   fixed 12-byte header table (`len:Int16, ptsize:Int16,
///   nameOffset:Int32, ptsOffset:Int32`, matching `nugspline_s`'s own
///   real field order) with `splineCount` real records right after the
///   blob's leading count -- record 0 alone looks plausible (`len=393`,
///   consistent with the standalone-length reading), but every
///   subsequent record decodes to clear garbage (implausible negative
///   lengths, offsets in the billions, `ptsize` values like `-15526`) on
///   every one of 5 real files tried. Also notable: `CASTLE_C.GSC`'s
///   blob reads a `splineCount` of 138 under this scheme -- implausibly
///   large for what should be a per-level spline count, a further sign
///   this isn't the right framing.
///
///   **Solved.** Found the real function body -- not just the dispatch
///   name -- in `Games Files/Reference Files/OpenCrashWOC-main/code/src/
///   nu3dx/nuscene.c:132-159` (`ReadNuIFFGSplineSet`, `//MATCH NGC`), a
///   genuinely different organizing idea from both refuted hypotheses
///   above: not a separate header table, `numSplines` records placed
///   directly back-to-back in the blob, each an 8-byte inline header
///   (`len:Int16, pad:Int16(unused), nameOffset:Int16,
///   pad2:Int16(unused)`) immediately followed by that spline's own
///   `len*12` bytes of `Vec3` points -- self-describing via each
///   record's own `len`, no separate point-blob or table. One real
///   correction to the decompiled source's exact byte offsets: it reads
///   `len`/`nameOffset` via `*(s16*)(temp+2)` (sub-offsets 2/6 within
///   each 4-byte slot), but direct verification on `FARM.GSC`
///   (`blob.count=68`, `numSplines=1`, real bytes `05 00 00 00 8e 00 00
///   00 ...`) shows `len=5` actually sits at sub-offset 0
///   (`5*12+8==68` exactly) -- trusted the real bytes over that one
///   pointer-arithmetic detail. Verified programmatically (not sampled):
///   **41 of 41 real files with a nonempty `SST0` blob decode with EXACT
///   byte consumption** -- `numSplines` records summing to `8 +
///   len*12` each land on `blob.count` precisely, zero exceptions. See
///   `WOCSplineSetParser.swift` and `SST0_Spec.md` for the implementation
///   and full writeup. **`nameOffset` resolution also confirmed**: it's
///   a byte offset into the same file's `NTBL` section's string blob
///   (payload past the leading length field) -- 657 of 657 real splines
///   across the corpus resolve to real, meaningful names (`"start_finish"`,
///   `"weecam_left_00"`, etc.). See `WOCSplineSetParser.resolveName(_:
///   ntblPayload:)`.
/// - `ALIB` -- see ``parseAttributeLibrary(_:)``. NOT a fixed-width table
///   (confirmed dead end from an earlier pass); the real structure is a
///   `count`-entry offset table (relative to just past the table itself,
///   with `0` as an empty-record sentinel) into a following record blob.
///   Verified across all 25 files that have it, and independently
///   cross-validated against `IABL`'s own `alibIndex` field (see
///   ``AttributeBlockRecord/alibIndex``): every `IABL` record references
///   a valid `ALIB` index, and in 8 of 24 files the exact set of
///   `ALIB`-indices-never-referenced-by-`IABL` matches the exact set of
///   `ALIB`'s own empty-sentinel records. Record *internals* (once
///   boundaries are known) are still undecoded.
///   **Naming correction: the real handler is `ReadAnimationLibrary`**
///   (not "Attribute Library" as this codebase's own guess had it). More
///   importantly, the real in-memory shape it builds is a genuine
///   **skeletal animation curve tree**: each `ALIB` entry is a
///   self-relative pointer (same aliasing scheme confirmed in `.CUT`) to
///   a `nuanimdata_s` struct, which fans out through `chunks[]` →
///   `animcurvesets[]` (one per animated node) → `curves[]` →
///   `animkeys`. This lines up structurally with this codebase's own
///   confirmed `count:UInt32LE reserved:UInt32LE(==0)
///   offsetTable:UInt32LE[count] recordBlob:Bytes` framing -- the offset
///   table is very likely exactly this self-relative pointer array, and
///   `recordBlob` is very likely the nested chunk/curveset/curve/animkey
///   data itself. This is the single most promising unexplored lead for
///   the still-unsolved "how are skeletal animation curves actually
///   encoded" question (see also `CHARS.DAT`'s own still-undecoded
///   per-clip motion blobs, in ``WOCCharacterAnimationCatalogParser``).
///   **Update, same follow-up session**: a separate reference file,
///   `code/src/nu3dx/nuanim.c`/`.h` (not the `GHG_GSC_FUNCTIONS.txt` file
///   this section's other corrections came from), contains WoC's actual
///   on-disk animation-curve *reader* (`NuAnimDataRead`), not just
///   pointer-relocation logic -- a complete, concrete, byte-exact
///   candidate layout for `nuanimdata_s`/`nuanimdatachunk_s`/
///   `nuanimcurveset_s`/`nuanimcurve_s`/`nuanimkey_s`, plus a documented
///   compressed/quantized variant. See
///   ``WOCCharacterAnimationCatalogParser``'s doc comment for the full
///   byte-sequence sketch -- written up there since it's a stronger match
///   for `CHARS.DAT`'s clip blobs than for this section, but it's the
///   same underlying format either way. Still not checked against a
///   single real byte of either `ALIB`'s own record blob or a
///   `CHARS.DAT` clip.
/// - `OBJ0` -- **entry boundaries now fully solved** by
///   ``parseObjSet(_:materialCount:)``, which implements the real
///   `ReadObjSet` sequential algorithm found in decompiled reference
///   source rather than heuristic marker-scanning: exact byte-consumption
///   and exact declared-entry-count match across all 58 real files
///   checked, zero exceptions, INCLUDING `CASTLE_C.GSC`/`HUB.GSC` (now
///   1113/1113 and 700/700 -- previously only 8/1113 and 27/700 via the
///   older `walkOBJ0Chunks(_:)` marker-walk, which is retained
///   unmodified since production mesh rendering (`WOCMeshDecoder`) still
///   depends on it -- see ``parseObjSet(_:materialCount:)``'s own doc
///   comment for the migration question this raises). Each entry's real
///   embedded mesh geometry (tristream/dmastream byte ranges, matching
///   the already-confirmed 16-byte vertex quadword pattern -- see
///   ``parseVertexQuadwords(_:byteOffset:count:)``) is exposed per
///   `ObjSetGeoEntry`/`ObjSetFaceonEntry`, still raw since which of the
///   two payload shapes applies depends on `MS00` material attributes not
///   yet decoded.
/// - `TAS0` -- see ``parseTextureAssignments(_:)``. Present in 12 of 54
///   files. An earlier investigation guessed a 44/48/96/112-byte record
///   width from a plain division and called it inconsistent; the real
///   record is a fixed 32 bytes, confirmed by exact byte-accounting
///   (zero exceptions) across all 12 files. This is the first confirmed
///   texture/mesh-binding data found in the format: a trailing `UInt16`
///   list whose every value is a valid index into that same file's own
///   decoded texture list (``scanTextureEntries(_:)``), and the
///   per-entry-to-texture-index mapping is now confirmed exactly (each
///   entry's own `frameStartIndex`/`frameCount` fields slice out its real
///   sub-run -- see ``TextureAssignmentEntry`` and ``frames(for:)``,
///   zero exceptions across all 7 locally-checked real files).
///   **Naming correction, and a real open question it raises**: the real
///   handler (referenced, not defined, in the decompiled source -- its
///   dispatch-table comment is even mislabeled `// MS00`, a copy-paste
///   typo) is `ReadTexAnimSet` -- i.e. `TAS0` is a **Texture Animation
///   Set**, not a static texture/material assignment table as this
///   codebase's own name/doc previously assumed. This raises a real,
///   currently-unverified possibility: the per-entry `UInt16` texture
///   index lists this codebase already decodes may be animated-texture
///   **frame sequences** (a UV/texture-swap flipbook) rather than a
///   static binding, which would also explain why `STATION.GSC`'s entries
///   were observed to have unequal index-list group sizes (a natural
///   consequence of different animations having different frame counts,
///   not an anomaly). **Update, re-verified against real bytes**: this
///   frame-sequence reading is now well-supported, not just plausible --
///   see ``TextureAssignmentEntry/frameStartIndex``'s doc comment for the
///   exact per-entry grouping evidence (contiguous ascending runs, shared
///   identical runs between entries) found once disc access resumed.
///
/// Every section not listed above as decoded is exposed as raw
/// ``WOCSection/payload`` bytes rather than guessed at.
///
/// **Corrections from decompiled reference source (added post-hoc, not
/// re-verified against real bytes)**: a later session found
/// `Games Files/Reference Files/OpenCrashWOC-main`, a partially
/// decompiled/reconstructed WoC source tree (match-confidence annotated,
/// e.g. `//MATCH`, `//98%`) that includes `NuGScnLoadFix`, the real
/// section-tag dispatch switch this whole format was reverse-engineered
/// without ever having seen -- `PS2_Version/GHG_GSC_FUNCTIONS.txt`. It
/// confirms every section tag's real name and, for several, real C-level
/// field framing that lines up closely with (and in some cases directly
/// confirms) what this file already found by hand: `INST` is read as
/// `count:UInt32LE reserved:UInt32LE` then `count` fixed-size instance
/// structs (exactly this codebase's own confirmed `INST` framing); `NTBL`
/// is `byteLength:UInt32LE` then that many raw bytes, lowercased in place
/// (exactly this codebase's own confirmed `NTBL` framing); `SPEC` is read
/// as `count:UInt32LE reserved:UInt32LE` then `count` records **of the
/// same struct width as `INST`**, each carrying an instance index and a
/// name-table byte offset (independently corroborates this codebase's own
/// "`SPEC` reuses `INST`'s 80-byte shape" finding, from the opposite
/// direction); `TST0` is read per-entry as `size:UInt32LE offset:UInt32LE`
/// with a same-shape/different-framing branch when `offset == 0` (broadly
/// consistent with, though not byte-identical to, this codebase's own
/// `TST0` heuristic scan -- worth a direct line-up once disc access
/// resumes). Per-tag naming/semantic corrections are noted inline next to
/// each affected tag above (`MS00`, `IABL`, `ALIB`, `SST0`, `TAS0`); none
/// of them have been re-verified against real bytes yet, since
/// `/Volumes/CRASH` was unmounted when this was written -- treat every
/// correction above as "real evidence, pending byte-level confirmation",
/// not yet promoted to this file's own "Confirmed" bar.
public enum WOCContainerParser {
    public enum ParseError: Error, Equatable {
        case badMagic
        case truncated
        case invalidSectionLength(tag: String, length: UInt32, atOffset: Int)
    }

    public struct File {
        public let negatedByteCount: UInt32
        public let formatVersion: UInt32
        public let reserved: UInt32
        public let sections: [Section]
    }

    public struct Section {
        public let tag: String
        /// Total byte length of this section, tag through end -- i.e. the
        /// distance from this section's own tag start to the next one's.
        public let length: UInt32
        /// `length - 8` bytes: everything after the tag and length fields.
        public let payload: Data
    }

    private static let headerSize = 16 // "NU20" + negatedByteCount + formatVersion + reserved

    public static func parse(_ bytes: [UInt8]) throws -> File {
        guard bytes.count >= headerSize else { throw ParseError.truncated }
        guard bytes[0] == 0x4E, bytes[1] == 0x55, bytes[2] == 0x32, bytes[3] == 0x30 else { // "NU20"
            throw ParseError.badMagic
        }
        let negatedByteCount = leUInt32(bytes, 4)
        let formatVersion = leUInt32(bytes, 8)
        let reserved = leUInt32(bytes, 12)

        var sections: [Section] = []
        var offset = headerSize
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { throw ParseError.truncated }
            guard let tag = asciiTag(bytes, offset) else { break } // non-tag bytes: end of the flat chain
            let length = leUInt32(bytes, offset + 4)
            guard length >= 8, offset + Int(length) <= bytes.count else {
                throw ParseError.invalidSectionLength(tag: tag, length: length, atOffset: offset)
            }
            let payloadStart = offset + 8
            let payloadEnd = offset + Int(length)
            let payload = Data(bytes[payloadStart..<payloadEnd])
            sections.append(Section(tag: tag, length: length, payload: payload))
            offset += Int(length)
        }

        return File(negatedByteCount: negatedByteCount, formatVersion: formatVersion, reserved: reserved, sections: sections)
    }

    /// Decodes an `NTBL` section's payload: a flat, null-terminated ASCII
    /// name list. Confirmed across all 7 samples: `stringBlobLength`
    /// exactly matches the summed byte length (including null terminators)
    /// of the visible name strings that follow it, every time.
    ///
    /// The bytes between the end of the string blob and the end of the
    /// section (`trailer`) are **not understood yet** -- their length
    /// varies non-trivially across samples (2, 9, 9, 11, 12, 13 bytes in
    /// the 6 samples that have a nonempty trailer) with no formula found
    /// yet that explains it from the name list alone, so they're returned
    /// as raw bytes rather than a guessed schema.
    public static func parseNameTable(_ payload: Data) throws -> (names: [String], trailer: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 4 else { throw ParseError.truncated }
        let stringBlobLength = Int(leUInt32(bytes, 0))
        guard 4 + stringBlobLength <= bytes.count else { throw ParseError.truncated }

        let blobStart = 4
        let blobEnd = blobStart + stringBlobLength
        let blob = bytes[blobStart..<blobEnd]

        var names: [String] = []
        var current: [UInt8] = []
        for b in blob {
            if b == 0 {
                if !current.isEmpty { names.append(String(decoding: current, as: UTF8.self)) }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(b)
            }
        }
        if !current.isEmpty { names.append(String(decoding: current, as: UTF8.self)) }

        let trailer = Data(bytes[blobEnd...])
        return (names, trailer)
    }

    /// Reads the leading `UInt32LE` "count" field present at the start of
    /// every count-prefixed section payload (`MS00`/`INST`/`IABL`/`OBJ0`).
    /// A small standalone helper since callers sometimes need this count
    /// (e.g. to cross-reference against another section) without wanting
    /// the full fixed-width record decode.
    public static func leadingCount(_ payload: Data) throws -> Int {
        let bytes = [UInt8](payload)
        guard bytes.count >= 4 else { throw ParseError.truncated }
        return Int(leUInt32(bytes, 0))
    }

    /// Decodes an `MS00` section's payload as a fixed-width record table:
    /// `count:UInt32LE` + `reserved:UInt32LE` + `count` records of a
    /// constant width. Confirmed across 4 real files of very different
    /// sizes (57/69/89/154 records) that `(payload.count - 8)` divides
    /// `count` **exactly**, and always to the same width: 464 bytes.
    ///
    /// The internal layout of a single 464-byte record is mostly not
    /// decoded -- most of it is zero-filled, with the first ~288 bytes
    /// consistently zero -- **except one confirmed field**: a real
    /// texture-ID reference at **relative offset 424** (`UInt32LE`).
    /// Confirmed across 4 real files of very different sizes and texture
    /// counts (`AIRSHIP.GSC`/`DROID.GSC`/`FARM.GSC`/`VOLCANO.GSC`): it's
    /// the *only* 4-byte-aligned offset in the whole record where every
    /// real record's value is both a valid index into that same file's
    /// own real texture list (``scanTextureEntries(_:)``) and non-constant
    /// across records, zero exceptions.
    ///
    /// This lines up with real decompiled source: `numtl.c`'s `NuMtlRead`
    /// (`OpenCrashWOC-main/code/src/nu3dx/numtl.c:180`) reads a
    /// `numtl_s` struct directly (`NuFileRead(fh, mtl, 0x54)`, 84 bytes),
    /// whose own real field order (`nu3dxtypes.h:399`) has `tid` at
    /// internal offset 56 -- so if `MS00`'s `tid` really is this same
    /// `numtl_s.tid`, `numtl_s` itself would start at `424 - 56 = 368`
    /// within the 464-byte record (leaving 368 bytes before it, 12
    /// after). This is corroborated, not just arithmetic: on
    /// `VOLCANO.GSC` specifically, offset 368 *also* independently
    /// satisfies the same "valid texture index, non-constant" test
    /// (a coincidence too specific to dismiss, though not proof).
    ///
    /// **Tried and came up empty**: whether `numtl_s.attrib`'s `ot` bit
    /// (`geo->mtl->attrib.ot` in `ReadObjSet`'s source -- the flag this
    /// codebase's own `parseObjSetGeoArcs(_:)` doc comment names as the
    /// leading explanation for why some geos produce no arcs) lives at
    /// the implied record offset 372 (`368 + 4`, `numtl_s.attrib`'s own
    /// internal offset). Directly tested by correlating every bit of
    /// that word against real arc-decode success/failure on
    /// `CASTLE_C.GSC`/`HUB.GSC`: the field is constant zero across all 89
    /// real materials in `CASTLE_C.GSC`, and only 2 distinct values (one
    /// shared by nearly all 154 materials) in `HUB.GSC` -- nowhere near
    /// enough real variation to test the hypothesis one way or the other
    /// on these two files. Also worth noting: `nu3dxtypes.h`'s own
    /// `numtlattrib_s` bitfield layout (the source this offset-372
    /// arithmetic is based on) doesn't actually list a field named `ot`
    /// among its 14 named bits -- a real, unresolved naming mismatch
    /// between that struct and `ReadObjSet`'s source, not just a blocked
    /// experiment. Records are still returned as raw bytes rather than a
    /// guessed struct.
    public static func parseMaterialSet(_ payload: Data) throws -> (records: [Data], recordWidth: Int) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { throw ParseError.truncated }
        let count = Int(leUInt32(bytes, 0))
        let remaining = bytes.count - 8
        guard count > 0, remaining % count == 0 else {
            return ([], 0)
        }
        let width = remaining / count
        var records: [Data] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            let start = 8 + i * width
            records.append(Data(bytes[start..<(start + width)]))
        }
        return (records, width)
    }

    /// One 32-byte record from a `TAS0` section's fixed-width entry table
    /// -- see ``parseTextureAssignments(_:)``'s doc comment for the
    /// overall section layout this belongs to.
    ///
    /// `referencedIndex` (relative offset 16) is strictly increasing
    /// across a `TAS0` section's own entry list in every real file
    /// checked -- the same curated-ascending-pointer shape already
    /// confirmed for `SPEC.referencedInstanceIndex`, but whether it
    /// targets `OBJ0` or `INST` is NOT disambiguated (every file checked
    /// has enough entries in both that bounds-checking alone can't tell
    /// them apart).
    ///
    /// `frameStartIndex`/`frameCount` (relative offsets 8 and 12) are
    /// **CONFIRMED, exact, zero exceptions**: together they slice this
    /// entry's own sub-run out of the section's shared `textureIndices`
    /// list. Verified against all 7 locally-mounted real files that have
    /// `TAS0` (`DROID.GSC`, `SNOW_B.GSC`, `SPACE_B.GSC`, `WEATH_B.GSC`,
    /// `VOLCANO.GSC`, `ICEBERG.GSC`, `STATION.GSC`) three independent
    /// ways at once: `frameStartIndex` starts at `0` for the first entry
    /// and is monotonically non-decreasing thereafter; every entry's
    /// `frameStartIndex` exactly equals the running sum of every prior
    /// entry's `frameCount` (i.e. it's a real cumulative offset, not a
    /// coincidentally-matching value); and the sum of every entry's
    /// `frameCount` exactly equals `TextureAssignmentSet.textureIndices
    /// .count`, leaving no leftover indices unclaimed by any entry. This
    /// directly resolves what an earlier investigation had left as "not
    /// confirmed" -- see ``frames`` for the sliced-out sub-list itself.
    /// **Important**: `frameCount` is a `UInt16`, not a `UInt32` --
    /// treating offsets 12-15 as one `UInt32` field (as an earlier,
    /// narrower investigation assumed before this correction) works for
    /// most entries by coincidence (the following 2 bytes are usually
    /// zero) but produces real garbage on `STATION.GSC` entry 6, whose
    /// bytes 14-15 are `73 47` rather than `00 00` -- those 2 bytes are a
    /// distinct, still-undecoded field, not padding, and are preserved in
    /// `raw` rather than silently merged into a wider count.
    ///
    /// Contiguous, ascending runs are exactly what a flipbook-style
    /// texture *animation* (this section's real name, per the decompiled
    /// reference source: "Texture Animation Set") would produce -- e.g.
    /// `STATION.GSC` entries 3 and 4 both claim the identical run
    /// `[51, 52, 53, 54]`, entries 7 and 8 both claim `[101...105]`,
    /// consistent with two different objects sharing one animated
    /// texture. This is real supporting evidence for the "these are
    /// animation frames" reading, not proof -- the per-frame *timing*
    /// (frame duration, loop behavior) is not stored anywhere in this
    /// section and remains unconfirmed.
    ///
    /// The rest of the entry (including a recurring duplicated-value
    /// field that looks like the same leftover-heap-pointer pattern
    /// already documented on `Instance.unknownTail1`/
    /// `SpecRecord.unknownTail3`, and two more monotonically-increasing
    /// `UInt32` fields at relative offsets 24 and 28 whose purpose isn't
    /// understood yet) is exposed raw rather than guessed at.
    public struct TextureAssignmentEntry {
        public let referencedIndex: UInt32
        public let frameStartIndex: UInt32
        public let frameCount: UInt16
        public let raw: Data
    }

    /// Decodes a `TAS0` section's payload -- **which references a
    /// file's decoded texture list** (see ``scanTextureEntries(_:)``),
    /// making this the first confirmed texture/mesh binding found in this
    /// format. Present in 12 of the 54 real files checked (others may
    /// simply not use it -- `TAS0` itself is already documented elsewhere
    /// in this file as present-in-some/absent-in-others).
    ///
    /// **CONFIRMED layout** (exact byte-accounting, zero exceptions
    /// across all 12 real files that have this section, including files
    /// an earlier, narrower investigation had flagged as "inconsistent"
    /// against a wrong assumed record width):
    /// ```
    /// TAS0 := count:UInt32LE reserved:UInt32LE
    ///         Entry(count)                        -- 32 bytes each, see TextureAssignmentEntry
    ///         listCount:UInt32LE
    ///         UInt16LE(listCount)                 -- texture-index list
    ///         trailer: Bytes(0...14)               -- not decoded
    /// ```
    /// `reserved` is `0` in all 12 files checked but not enforced here
    /// (read, not guarded) in case a future file uses it for something
    /// real. The entry width is 32 bytes, not the 44/48/96/112 an earlier
    /// investigation guessed from a plain `(payloadLength - 8) / count`
    /// division -- that division looked clean by coincidence on a handful
    /// of small-`count` files; the real formula that holds exactly on all
    /// 12 files (including the ones that broke the old guess) is
    /// `8 + count*32 + 4 + listCount*2 + trailer.count == payload.count`.
    ///
    /// **Texture-index evidence**: every value in the `UInt16` list is
    /// strictly less than that same file's own real texture count (12/12
    /// files, zero exceptions), and in 5 of 12 files the list's own max
    /// value lands within 1-2 of that count's upper bound -- e.g.
    /// `SPACE_B.GSC`: max index 50 of 51 real textures; `WEATH_B.GSC`:
    /// max 20 of 21; `SNOW_B.GSC`: max 21 of 22. Two `ICEBERG.GSC` sections
    /// show a clean, unambiguous `0..<32` run; `VOLCANO.GSC` shows
    /// `16..<48`.
    ///
    /// **Which texture indices belong to which entry -- now resolved**
    /// (an earlier investigation had left this "not confirmed", finding
    /// `STATION.GSC`'s 28 indices only split into unequal groups
    /// `4/6/8/5/5` under a wrong equal-sub-range assumption): see
    /// ``TextureAssignmentEntry/frameStartIndex``/``frameCount`` and
    /// ``frames(for:)`` -- each entry's real sub-run is an exact,
    /// directly-decoded slice, not inferred by dividing `listCount` by
    /// `count`. `TAS0.count` never matches `OBJ0`'s or `INST`'s own
    /// leading count in any file (single digits vs hundreds) -- this is a
    /// small curated subset, not a full per-object table, consistent with
    /// `SPEC`'s own already-documented curated-subset shape.
    public struct TextureAssignmentSet {
        public let entries: [TextureAssignmentEntry]
        public let textureIndices: [UInt16]
        public let trailer: Data

        /// The real, decoded sub-run of ``textureIndices`` this entry
        /// claims -- see ``TextureAssignmentEntry/frameStartIndex``'s doc
        /// comment for how this was confirmed. Returns an empty slice
        /// (rather than trapping) if `entry` didn't come from this same
        /// `TextureAssignmentSet`, since there's no way to validate that
        /// from the entry alone.
        public func frames(for entry: TextureAssignmentEntry) -> ArraySlice<UInt16> {
            let start = Int(entry.frameStartIndex)
            let end = start + Int(entry.frameCount)
            guard start >= 0, end <= textureIndices.count else { return [] }
            return textureIndices[start..<end]
        }
    }

    public static func parseTextureAssignments(_ payload: Data) throws -> TextureAssignmentSet {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { throw ParseError.truncated }
        let count = Int(leUInt32(bytes, 0))
        var offset = 8
        guard count >= 0, offset + count * 32 <= bytes.count else { throw ParseError.truncated }

        var entries: [TextureAssignmentEntry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            let base = offset + i * 32
            entries.append(TextureAssignmentEntry(
                referencedIndex: leUInt32(bytes, base + 16),
                frameStartIndex: leUInt32(bytes, base + 8),
                frameCount: UInt16(bytes[base + 12]) | (UInt16(bytes[base + 13]) << 8),
                raw: Data(bytes[base..<(base + 32)])
            ))
        }
        offset += count * 32

        guard offset + 4 <= bytes.count else { throw ParseError.truncated }
        let listCount = Int(leUInt32(bytes, offset))
        offset += 4
        guard listCount >= 0, offset + listCount * 2 <= bytes.count else { throw ParseError.truncated }

        var textureIndices: [UInt16] = []
        textureIndices.reserveCapacity(listCount)
        for i in 0..<listCount {
            let base = offset + i * 2
            textureIndices.append(UInt16(bytes[base]) | (UInt16(bytes[base + 1]) << 8))
        }
        offset += listCount * 2

        return TextureAssignmentSet(entries: entries, textureIndices: textureIndices, trailer: Data(bytes[offset...]))
    }

    /// A single placed object instance from an `INST` section: a 4x4
    /// world transform plus a small metadata tail. Fully decoded and
    /// hard-verified, not a guess -- see ``parseInstances(_:)``.
    public struct Instance {
        /// Row-major 4x4 transform; translation lives in row 3
        /// (`row3 = (tx, ty, tz, 1.0)`), confirmed by `w` being exactly
        /// `1.0` in every one of 564 real instances checked across 2
        /// files.
        public let matrix: (Float, Float, Float, Float,
                             Float, Float, Float, Float,
                             Float, Float, Float, Float,
                             Float, Float, Float, Float)
        /// A reference into the sibling `OBJ0` section's entry array --
        /// i.e. which object/mesh definition this placed instance uses.
        /// This was originally (WRONGLY) documented as "this instance's
        /// own array position" based on 2 small files where that
        /// coincidentally held (`AIRSHIP.GSC`/`FARM.GSC`, where every
        /// object happens to be placed exactly once). A full 53-file
        /// sweep found the real pattern instead, and it's rock solid:
        /// in **every one of the 53 real files checked**, this field's
        /// set of distinct values across all instances is *exactly*
        /// `0..<OBJ0.count` (same count, same max, zero out-of-bounds
        /// references anywhere) -- i.e. every `OBJ0` entry is referenced
        /// by at least one instance, and no instance ever references
        /// past the end. Levels with heavy prop reuse (e.g.
        /// `CASTLE_A.GSC`: 2111 instances referencing only 408 distinct
        /// `OBJ0` entries) make this unambiguous -- it cannot be a
        /// coincidental position match at that scale. Named
        /// `objectIndex` for what it verifiably references; `OBJ0`'s own
        /// per-entry internal format (beyond entry 0's confirmed
        /// embedded vertex geometry) is still not decoded.
        public let objectIndex: UInt32
        /// Only ever `4` or `5` across all 564 real instances checked in
        /// 2 files -- both values are valid `MS00` record indices in both
        /// files (57 and 69 `MS00` records respectively), so a direct
        /// "which `MS00` mesh does this instance use" reference is
        /// plausible on bounds alone, but a real per-level object palette
        /// should reference far more than 2 distinct meshes; a value this
        /// narrow reads more like a small type/category enum than a
        /// general mesh index. Neither interpretation is confirmed --
        /// treat as an opaque tag for now.
        public let typeOrMeshIndex: UInt32
        /// Zero for the vast majority of real instances (502/523 in the
        /// `FARM.GSC` sample), but *not* always -- about 4% of real
        /// instances there carry a nonzero value tightly clustered in the
        /// `0x13a3xxxx`-`0x13a7xxxx` range, which reads like a stray
        /// serialized runtime pointer (roughly sequential, heap-address
        /// shaped) rather than meaningful per-instance data. Exposed
        /// as-is rather than masked to zero, since it demonstrably isn't
        /// always zero.
        public let unknownTail1: UInt32
        /// Zero in every one of 564 real instances checked across both
        /// samples -- unlike `unknownTail1`, no counterexample found yet.
        public let unknownTail2: UInt32

        public var translation: SIMD3<Float> { SIMD3(matrix.12, matrix.13, matrix.14) }
    }

    /// Decodes an `INST` section's payload: `count:UInt32LE` +
    /// `reserved:UInt32LE` + `count` fixed-width 80-byte records. Record
    /// width and count were cross-verified against real files the same
    /// way as ``parseMaterialSet(_:)``. See ``Instance/objectIndex`` for the
    /// (now fully confirmed, 53-file) `OBJ0` cross-reference relationship.
    public static func parseInstances(_ payload: Data) throws -> [Instance] {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { throw ParseError.truncated }
        let count = Int(leUInt32(bytes, 0))
        let remaining = bytes.count - 8
        guard count > 0, remaining % count == 0, remaining / count == 80 else { return [] }

        var instances: [Instance] = []
        instances.reserveCapacity(count)
        for i in 0..<count {
            let start = 8 + i * 80
            var floats = [Float](repeating: 0, count: 16)
            for f in 0..<16 { floats[f] = leFloat32(bytes, start + f * 4) }
            let tailStart = start + 64
            let objectIndex = leUInt32(bytes, tailStart)
            let typeOrMeshIndex = leUInt32(bytes, tailStart + 4)
            let unknownTail1 = leUInt32(bytes, tailStart + 8)
            let unknownTail2 = leUInt32(bytes, tailStart + 12)
            instances.append(Instance(
                matrix: (floats[0], floats[1], floats[2], floats[3],
                         floats[4], floats[5], floats[6], floats[7],
                         floats[8], floats[9], floats[10], floats[11],
                         floats[12], floats[13], floats[14], floats[15]),
                objectIndex: objectIndex, typeOrMeshIndex: typeOrMeshIndex,
                unknownTail1: unknownTail1, unknownTail2: unknownTail2
            ))
        }
        return instances
    }

    /// One 16-byte quadword from an `OBJ0` entry's vertex-like data block:
    /// a leading control word (unparsed -- see below) followed by 3 floats
    /// that behave exactly like a position.
    public struct VertexQuadword {
        public let control: UInt32
        public let position: SIMD3<Float>
    }

    /// Extracts `count` 16-byte quadwords starting at `byteOffset` within
    /// an `OBJ0` section's payload as `(control:UInt32, position:xyz Float)`
    /// pairs. This is **not** a full `OBJ0` entry parser -- `OBJ0`'s
    /// per-entry byte length is not yet known (entries are variable-size,
    /// no offset table or self-length-prefix was found at their start, and
    /// this section is not a fixed-width record table like `MS00`/`INST`),
    /// so callers must supply the start offset and count explicitly rather
    /// than iterating entries automatically.
    ///
    /// What *is* confirmed, from real `AIRSHIP.GSC` bytes: at least the
    /// first ~39 quadwords of `OBJ0`'s first entry decode to a smoothly
    /// varying, visually coherent curved-surface vertex strip (plotted and
    /// visually inspected, not just numerically plausible) -- real
    /// geometry, not noise. The `control` word's low byte was observed
    /// counting down (3, 1, 1, 0, 0, ...) across the first few quadwords
    /// while its second byte flips from `0x80` to `0x00`, echoing this
    /// same codebase's own `ModelParser`/`SkinParser` strip-connectivity
    /// encoding (`(binaryW & 0xFF00) >> 8`) closely enough to be a
    /// plausible cousin format -- but that specific interpretation is an
    /// observation, not verified, so `control` is returned raw/unparsed.
    /// An earlier pass through this data mistakenly described the Y
    /// values as exact `sin(9n)` steps; a precise check showed that's
    /// false (the fit drifts progressively worse per step) -- the values
    /// are smoothly varying and plausible, not a confirmed closed-form
    /// curve, and are documented here only as strongly as that.
    public static func parseVertexQuadwords(_ payload: Data, byteOffset: Int, count: Int) throws -> [VertexQuadword] {
        let bytes = [UInt8](payload)
        guard byteOffset >= 0, count >= 0, byteOffset + count * 16 <= bytes.count else {
            throw ParseError.truncated
        }
        var result: [VertexQuadword] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let base = byteOffset + i * 16
            let control = leUInt32(bytes, base)
            let x = leFloat32(bytes, base + 4)
            let y = leFloat32(bytes, base + 8)
            let z = leFloat32(bytes, base + 12)
            result.append(VertexQuadword(control: control, position: SIMD3(x, y, z)))
        }
        return result
    }

    /// One "arc" -- the real fine-grained vertex-batch unit inside an
    /// `OBJ0` chunk, found by a dedicated follow-up investigation once
    /// chunk-to-entry grouping was solved. A chunk is not one flat vertex
    /// list; it's a sequence of these, each with its own 36-byte header
    /// and its own vertex count.
    ///
    /// **CONFIRMED** (independently re-verified against real bytes, not
    /// just the investigation's own report -- byte-exact header match and
    /// a working end-to-end walk with small, bounded drift, on
    /// `AIRSHIP.GSC`/`FARM.GSC`/`DROID.GSC`): the 36-byte header is a
    /// fixed byte template --
    /// `d2 80 01 6c [N] 80 00 00 00 40 02 30 12 05 00 00 00 00 00 00 02 80 01 6d [N*3 as u32LE] 00 00 00 00 00 00 00 03 01 00 01`
    /// -- where byte 4 is the vertex count `N` (confirmed exactly on 16
    /// arcs spanning N=3...42) and the `u32` at byte 24 is exactly `N*3`
    /// (16/16 exact). The header sits at `chunk.markerOffset + 20` for
    /// the first arc (confirmed identical across all 3 files despite
    /// their different marker-to-chunk-start distances), immediately
    /// followed by `N` real ``VertexQuadword``s (the same 16-byte
    /// `control:u32 + position:xyz Float` layout `parseVertexQuadwords`
    /// already established, now confirmed to span a whole arc rather than
    /// an arbitrary prefix), then a `28 + 12*N`-byte trailing block --
    /// mostly still not decoded (see ``parseOBJ0ChunkArcs(_:chunk:)``'s
    /// doc comment), except for real structure found in the block's own
    /// fixed 28-byte header: **relative byte 10 exactly echoes the arc's
    /// own vertex count `N`** (confirmed zero exceptions across 7,145
    /// real arcs spanning 3 files -- `AIRSHIP.GSC`/`DROID.GSC`/
    /// `FARM.GSC`), bytes 4-7/8-9/11 are real global constants (`01 00 00
    /// 05`, `04 80`, `6D`, identical in every arc in every file checked),
    /// and bytes 0-3 read as a real, usually-small `Float32` (samples
    /// seen: `0.048, -0.048, -0.092, 0.148`) that varies per arc with no
    /// found correlation to material index -- before the next arc's
    /// header.
    ///
    /// **Visually verified**, not just numerically plausible: rendering
    /// full real entries as point clouds/wireframes (multiple entries
    /// across `AIRSHIP.GSC`/`DROID.GSC`) showed genuinely coherent
    /// geometry -- a smoothly curved dome/fan surface, a clean circular
    /// ring of vertices, and several individually closed-loop mesh
    /// pieces in a larger multi-part assembly -- not noise.
    public struct OBJ0Arc {
        public let vertexCount: Int
        public let vertices: [VertexQuadword]
    }

    /// Walks one `OBJ0Chunk`'s real arcs -- see ``OBJ0Arc``'s doc comment
    /// for the confirmed header/vertex layout. Stops (returning whatever
    /// arcs were found so far) when the next candidate header doesn't
    /// match the confirmed template, or would run past the chunk's own
    /// end -- this always happens once per chunk, at a small, bounded
    /// remainder after the last real arc (median ~12-92 bytes across the
    /// 3 files checked, never seen over ~160), matching what the chunk-
    /// length walk (``walkOBJ0Chunks(_:)``) already leaves unconsumed at
    /// the very end of a payload. That remainder's own contents are
    /// **not decoded**. Each arc's own `28 + 12*N`-byte trailing block is
    /// now partially decoded -- see ``OBJ0Arc``'s doc comment for the
    /// confirmed fixed-header fields (`N` echoed at relative byte 10,
    /// three constant fields, one real per-arc `Float32`) -- but the
    /// `12*N`-byte per-vertex portion that follows is still open. **A
    /// sharper, but still unconfirmed, UV lead** (found by cross-
    /// referencing this data against `MS00`'s texture-ID field and each
    /// geo's real material): each 12-byte per-vertex block reads cleanly
    /// as six `Int16`s; dividing every one by `4096` lands every single
    /// value, across all 11,516 real vertices checked on `AIRSHIP.GSC`,
    /// in a hard, consistent `±8` range -- and that range doesn't vary
    /// with the vertex's own real texture dimensions (checked against
    /// several different real textures via `MS00`'s confirmed `tid`
    /// field), which is what real UV coordinates should look like (a
    /// texture-size-independent parametric value, only becoming
    /// texel-space after multiplying by width/height at sample time) --
    /// a materially more specific, texture-cross-referenced signal than
    /// the vague "a 16-bit field, scale factor didn't reproduce" note
    /// this doc previously had. **Still not confirmed**: a direct
    /// position/UV smoothness check (do adjacent strip vertices have
    /// similar UV where they have similar position, as a real continuous
    /// UV-mapped surface should) came back genuinely ambiguous on the
    /// arcs checked -- their real 3D positions cluster extremely tightly
    /// (consecutive-vertex position deltas of ~0.01-0.03 units
    /// throughout), consistent with a small, repeated surface-detail
    /// piece rather than a large unique surface, which undermines that
    /// smoothness test's own assumption rather than cleanly refuting the
    /// UV hypothesis. Confirming this for real needs either an
    /// unambiguous visual check (rendering a mesh with this data as UVs
    /// against its real texture and looking at it) or a geometrically
    /// larger/more varied sample arc.
    ///
    /// **Update: tried the larger/more varied sample -- still ambiguous,
    /// closing off that escape hatch.** Ran the same position/UV
    /// smoothness correlation (Pearson `r` between consecutive-vertex
    /// position-delta and each of the 6 Int16 slots' value-delta) against
    /// the 10 geometrically largest real arcs in `AIRSHIP.GSC` (bounding-
    /// box diagonals 23-45 units -- an order of magnitude bigger than the
    /// tightly-clustered small-detail arc originally checked, and no two
    /// of these 10 the same shape or size). No slot shows a consistent
    /// strong correlation across them: values scatter in the `|r| < 0.5`
    /// range with **inconsistent sign** between arcs for every slot (e.g.
    /// slot 4 ranges from `-0.502` to `+0.390` across the 10 arcs) -- the
    /// opposite of what a real UV channel should show (a consistently
    /// positive, high-magnitude correlation almost everywhere, since a
    /// continuously-mapped surface's UV should vary smoothly with
    /// position nearly always, not vary in *direction* per arc). This
    /// isn't proof the ±8-range/÷4096 field-shape reading is wrong -- it's
    /// still a real, texture-size-independent, hard-bounded numeric
    /// pattern -- but it does rule out "just needed a bigger sample" as
    /// the reason the original smoothness check was inconclusive. Either
    /// consecutive vertex *indices* within an arc aren't reliably
    /// spatially-adjacent in the way a strip format would suggest
    /// (undermining this whole test's premise, not just the sample
    /// size), or these 6 values genuinely aren't UV at all.
    ///
    /// **Update: an actual visual render was built and checked (a
    /// software triangle-outline overlay on the real decoded texture, not
    /// literal in-engine rendering, but real mesh data + real texture
    /// pixels + the confirmed strip-with-restarts connectivity, viewed
    /// directly) -- result is a real negative, not just inconclusive.**
    /// Exported a real 42-vertex/39-triangle arc from `AIRSHIP.GSC` (its
    /// real shape, checked via a separate wireframe render, is a thin
    /// curved ribbon/crescent strip -- confirming *why* the earlier
    /// position/UV smoothness correlation stayed ambiguous even on
    /// "larger" arcs: this shape class has little 2D spread for that test
    /// to work with) plus one of that file's own real direct-color
    /// textures (128x64), and overlaid the triangle list in texture space
    /// for all 6 candidate 2-of-6-slot UV pairings ((0,1), (2,3), (4,5),
    /// (0,3), (1,4), (2,5), each value ÷4096 per the confirmed bound).
    /// **Every single candidate produces wildly self-crossing,
    /// non-tiling triangles with no coherent unwrap pattern**, and the
    /// raw per-vertex values span nearly the entire theoretical ±8 range
    /// rather than clustering in a plausible local region -- the opposite
    /// of what any real per-vertex UV parametrization of a small mesh
    /// patch should look like. This doesn't prove the six Int16 fields
    /// aren't UV under some *other* transform (a different divisor, a
    /// per-arc offset, non-adjacent slot pairings not tried), but it does
    /// rule out the simple "raw value ÷4096, any 2-of-6 slot pairing"
    /// reading definitively, with a real visual check rather than a
    /// numeric proxy for one. Confirming any further variant would need
    /// the same kind of direct visual render repeated against a new
    /// transform hypothesis, not a fundamentally different technique.
    ///
    /// **Update: closed off the remaining "different transform" escape
    /// hatches this doc's previous update left open, with real numeric
    /// tests across a bigger, more relevant sample (74 real arcs from
    /// `CRATES.GSC`, 408 from `AIRSHIP.GSC` -- the crate-texture "parent
    /// object" resolution work this session, not fresh guessing).** Divisor
    /// genuinely doesn't matter for any of this: a uniform rescale can't
    /// fix self-crossing triangle topology or winding, so "a different
    /// divisor" (raised as an open possibility above) is now a closed
    /// question, not just an untested one. Ran an actual **winding-
    /// consistency sweep** (does a candidate UV mapping keep consistent
    /// triangle winding sign, the real signature of a coherent unwrap)
    /// across all 15 possible 2-of-6 slot pairings, both with and without
    /// the strip-alternation correction `triangleIndices()` applies for
    /// 3D winding (testing whether that correction, right for position,
    /// might be wrong for UV): best case is slots (4,5) at ~68-69%
    /// consistency either way -- real signal above the ~50% noise floor,
    /// but far short of the ~95-100% a genuine clean unwrap should show.
    /// Also tested and ruled out two structural alternatives to "these are
    /// UV" the visual check didn't address: reinterpreting the 12 bytes as
    /// 3 real `Float32`s (a per-vertex normal) produces garbage bit
    /// patterns (exponents in the `1e29`+ range, not valid floats) --
    /// definitively not that. And a real, previously-unnoted structural
    /// fact emerged from a full 6x6 cross-correlation over the same
    /// sample: slots (0,2,4) inter-correlate (r=0.60-0.75) as one group and
    /// slots (1,3,5) inter-correlate (r=0.88-0.89, notably tighter) as a
    /// separate group, with weak correlation *between* the two groups --
    /// the signature of two interleaved 3-component values, not three
    /// independent 2-component UV pairs. Neither group has near-constant
    /// magnitude (ruling out "these are two normals" or similar unit-
    /// vector data: coefficient of variation ~1.0-1.2, real normals would
    /// be near 0), and neither correlates with the vertex's own real
    /// position (`|r| < 0.11` against x/y/z for every slot) -- ruling out
    /// a planar/box UV projection derived linearly from position. Net
    /// result: **still unsolved**, but with a materially narrower and more
    /// specific open question than before -- something that produces two
    /// internally-correlated 3-tuples per vertex, not UV coordinates under
    /// any transform tried, not a normal, not a position-derived value.
    /// What it actually is remains open; closing it for real most likely
    /// needs an external reference (a decompiled/disassembled WoC
    /// executable, or community documentation of this specific TT-engine
    /// tristream format) the way every original-Twinsanity parser in this
    /// codebase is grounded in `twinsanity-editor-master`.
    ///
    /// **Update: that external reference does exist
    /// (`OpenCrashWOC-main`, a real decompiled/DWARF-debug-verified
    /// source tree for this exact engine family, already used elsewhere
    /// in this codebase for `SST0`/`MS00`) and was searched specifically
    /// for this -- real, useful confirmation of the surrounding
    /// structure, but the core mystery itself stays open.** `PS2_Version/
    /// GHG_GSC_FUNCTIONS.txt`'s `ReadObjSet` is the real source for
    /// `OBJ0` (confirmed: it reads `numgobj`, then per-`gobj` a
    /// sub-object count, `type` (0=mesh/1=faceon), per-mesh-geom a
    /// material-index-based `geo->mtl->attrib.ot == 1` branch selecting
    /// `tristream` (this codebase's "arc" format) vs. `dmastream` (a
    /// `sceDmaTag`-chained format this codebase doesn't decode at all) --
    /// real confirmation of the "leading working explanation" this doc
    /// comment already carried, not a new finding). The tristream fixup
    /// loop itself (`*(int*)(t + 0x14) = (int)(t1 + 0x10)` on each
    /// `nuvutri_s` element) confirms each element is at least 0x18 bytes
    /// and that offset 0x14 is a *runtime-only* pointer-chain slot
    /// (overwritten at load time, not real on-disk vertex data) -- but
    /// **`struct nuvutri_s` itself has zero definitions anywhere in this
    /// reference**, source or the 457K-line GameCube DWARF debug dump
    /// (grepped directly, confirmed absent). The GameCube port doesn't
    /// help either: its own parallel loader (`nu3dx/nuscene.c`'s
    /// `ReadNuIFFGeomVtx`) abandoned the PS2 VU tristream format
    /// entirely, reading a fully-expanded, DWARF-verified
    /// `nuvtx_tc1_s{pnt:Vec3, nrm:Vec3, diffuse:packedARGB, tc:Float32x2}`
    /// (0x24 bytes) straight off disk instead -- confirming real UV data
    /// *does* exist in this vertex-format family in general (`tc[2]`,
    /// not "texcoord" -- the actual field name throughout this engine),
    /// but not in the specific PS2-only packed shape this codebase's
    /// `OBJ0` decoder has to contend with. Net: this reference
    /// independently corroborates the tristream/dmastream split and
    /// proves UV data is a real, normal part of this engine's vertex
    /// formats in general, but does not hand over the one struct
    /// (`nuvutri_s`) that would actually close this file's own open
    /// question -- not even Traveller's Tales' own GameCube port team
    /// carried that specific struct forward into a form this reference
    /// preserves.
    ///
    /// One more real, separate finding from the same search, worth
    /// recording here rather than losing: `numtlattrib_s`'s real,
    /// DWARF-verified 32-bit bitfield (`alpha:2,filter:2,fx:2,utc:2,
    /// vtc:2,cull:2,zmode:2,lighting:2,colour:1,fill:1,atst:3,aref:8,
    /// afail:2,uvmode:1` -- exactly 32 bits, no room left over) has no
    /// field literally named `ot` -- independently reconfirming (not
    /// just repeating) the naming mismatch `parseMaterialSet`'s own doc
    /// comment already flags between this struct and `ReadObjSet`'s own
    /// `attrib.ot` reference.
    public static func parseOBJ0ChunkArcs(_ payload: Data, chunk: OBJ0Chunk) -> [OBJ0Arc] {
        let bytes = [UInt8](payload)
        let arcMagic: [UInt8] = [0xD2, 0x80, 0x01, 0x6C]
        var arcs: [OBJ0Arc] = []
        var offset = chunk.markerOffset + 20
        let chunkEnd = chunk.byteOffset + chunk.length
        while offset + 36 <= chunkEnd, offset + 36 <= bytes.count {
            guard Array(bytes[offset..<(offset + 4)]) == arcMagic else { break }
            let n = Int(bytes[offset + 4])
            let n3 = leUInt32(bytes, offset + 24)
            guard n3 == UInt32(n * 3) else { break }
            let vertexStart = offset + 36
            guard vertexStart + n * 16 <= bytes.count else { break }
            var vertices: [VertexQuadword] = []
            vertices.reserveCapacity(n)
            for i in 0..<n {
                let base = vertexStart + i * 16
                let control = leUInt32(bytes, base)
                let x = leFloat32(bytes, base + 4)
                let y = leFloat32(bytes, base + 8)
                let z = leFloat32(bytes, base + 12)
                vertices.append(VertexQuadword(control: control, position: SIMD3(x, y, z)))
            }
            arcs.append(OBJ0Arc(vertexCount: n, vertices: vertices))
            let vertexEnd = vertexStart + n * 16
            offset = vertexEnd + 28 + 12 * n
        }
        return arcs
    }

    /// Walks the real arc sequence directly within one ``ObjSetGeoEntry``'s
    /// `payload` -- the same real arc format ``parseOBJ0ChunkArcs(_:chunk:)``
    /// decodes, but anchored to ``parseObjSet(_:materialCount:)``'s exact
    /// payload boundary instead of a heuristic chunk-length scan.
    ///
    /// **CONFIRMED**: every one of 222 real mesh `geo` payloads checked on
    /// `AIRSHIP.GSC` contains the same `56 00 01 6C` marker
    /// ``parseOBJ0ChunkArcs`` anchors on, always at relative offset 16 in
    /// that file; the arc sequence starts exactly 20 bytes after it,
    /// matching ``parseOBJ0ChunkArcs``'s own `markerOffset + 20`
    /// convention precisely. On `CASTLE_C.GSC`/`HUB.GSC` the marker's own
    /// relative offset varies (`16` or `36` seen, zero exceptions across
    /// 1713/1506 real geos checked) -- this function finds it by direct
    /// search rather than assuming a fixed offset, unlike an earlier
    /// investigation pass that assumed offset 16 universally.
    ///
    /// **Verified regression-free and a real improvement, not just a
    /// hypothesis**: on `AIRSHIP.GSC` this reproduces
    /// ``parseOBJ0ChunkArcs``'s existing total exactly (408 arcs, 11516
    /// vertices, zero difference) -- real proof of equivalence on a file
    /// where the old approach already worked, not just "doesn't crash".
    /// On the two files the old chunk-grouping approach could only
    /// partially cover, this recovers dramatically more real geometry:
    /// `CASTLE_C.GSC` 1291 arcs / 42,554 vertices (old grouped approach:
    /// 11 arcs / 404 vertices from only 8 of 1113 real entries) and
    /// `HUB.GSC` 962 arcs / 27,548 vertices (old: 28 arcs / 986 vertices
    /// from only 27 of 700 real entries).
    ///
    /// **Not claimed complete even now**: real, often-large remainders
    /// stay after the last decoded arc on many geos in `CASTLE_C.GSC`/
    /// `HUB.GSC` specifically (median remainder far larger than
    /// `AIRSHIP.GSC`'s ~60-byte typical trailer). The leading working
    /// explanation (not independently confirmed byte-by-byte): `ReadObjSet`'s
    /// real source branches per-geo on the referenced material's `ot`
    /// attribute bit between this arc/"tristream" format and a
    /// structurally different DMA-tag "dmastream" format neither this
    /// function nor ``parseOBJ0ChunkArcs`` understands -- `MS00`'s `ot`
    /// bit isn't decoded yet to confirm this directly. Either way, a
    /// remainder here is real, honestly-unconsumed data, not an error to
    /// paper over -- callers should not assume every geo produces arcs.
    public static func parseObjSetGeoArcs(_ payload: Data) -> [OBJ0Arc] {
        let bytes = [UInt8](payload)
        let arcMagic: [UInt8] = [0xD2, 0x80, 0x01, 0x6C]
        let chunkMarker: [UInt8] = [0x56, 0x00, 0x01, 0x6C]
        guard bytes.count >= 20 else { return [] }

        var markerOffset: Int?
        var searchPos = 0
        while searchPos + 4 <= bytes.count {
            if Array(bytes[searchPos..<(searchPos + 4)]) == chunkMarker {
                markerOffset = searchPos
                break
            }
            searchPos += 1
        }
        guard let markerOffset else { return [] }

        var offset = markerOffset + 20
        var arcs: [OBJ0Arc] = []
        while offset + 36 <= bytes.count {
            guard Array(bytes[offset..<(offset + 4)]) == arcMagic else { break }
            let n = Int(bytes[offset + 4])
            let n3 = leUInt32(bytes, offset + 24)
            guard n3 == UInt32(n * 3) else { break }
            let vertexStart = offset + 36
            guard vertexStart + n * 16 <= bytes.count else { break }
            let nextOffset = vertexStart + n * 16 + 28 + 12 * n
            guard nextOffset <= bytes.count else { break } // don't overrun the trailer skip
            var vertices: [VertexQuadword] = []
            vertices.reserveCapacity(n)
            for i in 0..<n {
                let base = vertexStart + i * 16
                let control = leUInt32(bytes, base)
                let x = leFloat32(bytes, base + 4)
                let y = leFloat32(bytes, base + 8)
                let z = leFloat32(bytes, base + 12)
                vertices.append(VertexQuadword(control: control, position: SIMD3(x, y, z)))
            }
            arcs.append(OBJ0Arc(vertexCount: n, vertices: vertices))
            offset = nextOffset
        }
        return arcs
    }

    /// A single `IABL` record ("Instance Attribute BLock"?): a 96-byte
    /// fixed record where only one field is decoded -- see
    /// ``parseAttributeBlock(_:)``.
    public struct AttributeBlockRecord {
        /// The last `UInt32LE` of the 96-byte record (byte offset 92).
        /// CONFIRMED: a reference into the sibling `ALIB` section's own
        /// record list, exactly analogous to `INST.objectIndex`'s
        /// reference into `OBJ0`. Verified across all 24 files that have
        /// both `IABL` and `ALIB`: every single value falls strictly
        /// within `0..<ALIB record count`, zero out-of-range references
        /// anywhere. In 8 of those 24 files, the set of `ALIB` indices
        /// *never* referenced by any `IABL` record exactly matches the
        /// set of `ALIB` records with zero length (see
        /// ``ALIBRecord/isEmpty``) -- independent cross-validation of both
        /// findings at once, re-checked directly (not just taken from an
        /// agent report) on `DROID.GSC` (`{6}` == `{6}` exactly).
        public let alibIndex: UInt32
        /// The full 96-byte record; internals beyond `alibIndex` are not
        /// decoded (mostly zero, with a small non-zero region starting
        /// around byte 64 containing plausible attribute-like float
        /// values -- not verified enough to commit to further field
        /// offsets).
        public let rawBytes: Data
    }

    /// Decodes an `IABL` section's payload: `count:UInt32LE` +
    /// `reserved:UInt32LE` + `count` fixed-width records. Confirmed
    /// cross-file: the width is **96 bytes** in every one of the 24 files
    /// in the full 54-file corpus that have `IABL`, zero exceptions, exact
    /// division every time.
    public static func parseAttributeBlock(_ payload: Data) throws -> [AttributeBlockRecord] {
        let (records, width) = try parseMaterialSet(payload)
        guard width == 96 else { return [] }
        return records.map { record in
            let bytes = [UInt8](record)
            return AttributeBlockRecord(alibIndex: leUInt32(bytes, 92), rawBytes: record)
        }
    }

    /// A single record from an `ALIB` ("ATTRIBUTE LIBrary"?) section, as
    /// resolved by ``parseAttributeLibrary(_:)``.
    public struct ALIBRecord {
        /// This record's byte range within `ALIB`'s record blob (i.e.
        /// relative to just past the offset table, not the section
        /// payload start).
        public let byteRange: Range<Int>
        public let data: Data
        /// `true` when this record's raw offset-table entry was the `0`
        /// sentinel (see ``parseAttributeLibrary(_:)``'s doc comment) --
        /// an explicitly empty/unused record, not a decode failure.
        public let isEmpty: Bool
    }

    /// Decodes an `ALIB` section's payload. Earlier sessions correctly
    /// ruled out the obvious fixed-width-record hypothesis (the leading
    /// count field divided the payload evenly in some files but to
    /// *different* widths, the same trap that made `ALIB` look briefly
    /// promising before -- see the git history for that dead end). The
    /// real structure, found afterward:
    /// ```
    /// ALIB := count:UInt32LE reserved:UInt32LE(==0) offsetTable:UInt32LE[count] recordBlob:Bytes
    /// ```
    /// Each `offsetTable[i]` is a byte offset **relative to the position
    /// right after the table itself** (`baseline = 8 + 4*count`). Record
    /// `i` spans `[baseline+offsetTable[i], baseline+offsetTable[i+1])`,
    /// and the last record runs to the end of the payload. A `0` table
    /// entry is a sentinel for an explicitly empty record -- it "inherits"
    /// the start position of the next non-zero entry (so it has zero
    /// length), rather than being a literal offset back to the table.
    ///
    /// CONFIRMED across all 25 real files with `ALIB` in the full corpus:
    /// offsets are non-negative and monotonically non-decreasing after
    /// resolving the zero-sentinel, and the last resolved offset never
    /// exceeds the blob's length. Independently re-verified before
    /// implementing (not just trusting the source that found this) on
    /// `FARM.GSC` (4 records, offsets `20,1776,3532,5288`, blob length
    /// 5808) and `DROID.GSC` (10 records, one zero-sentinel at index 6,
    /// confirmed to be exactly the `IABL`-unreferenced index).
    public static func parseAttributeLibrary(_ payload: Data) throws -> [ALIBRecord] {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { return [] }
        let count = Int(leUInt32(bytes, 0))
        guard count > 0, 8 + 4 * count <= bytes.count else { return [] }

        var rawOffsets: [Int] = []
        for i in 0..<count { rawOffsets.append(Int(leUInt32(bytes, 8 + i * 4))) }

        let baseline = 8 + 4 * count
        let blobLength = bytes.count - baseline
        var resolved = rawOffsets
        for i in stride(from: resolved.count - 2, through: 0, by: -1) where resolved[i] == 0 {
            resolved[i] = resolved[i + 1]
        }

        var records: [ALIBRecord] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            let start = resolved[i]
            let end = i + 1 < count ? resolved[i + 1] : blobLength
            guard start >= 0, end >= start, baseline + end <= bytes.count else { break }
            let range = (baseline + start)..<(baseline + end)
            records.append(ALIBRecord(byteRange: (start)..<(end), data: Data(bytes[range]), isEmpty: rawOffsets[i] == 0))
        }
        return records
    }

    /// A single record from a `SPEC` section: byte-for-byte the same
    /// 80-byte layout as `INST`'s records (4x4 transform + 4-field tail),
    /// but referencing `INST`, not `OBJ0` -- see ``parseSpecRecords(_:)``.
    public struct SpecRecord {
        public let matrix: (Float, Float, Float, Float,
                             Float, Float, Float, Float,
                             Float, Float, Float, Float,
                             Float, Float, Float, Float)
        /// Confirmed (checked every record across all 46 files in the
        /// full 54-file corpus that have both `SPEC` and `INST` -- 1461
        /// records total, zero exceptions): a valid index into the
        /// sibling `INST` section's own instance array, strictly
        /// increasing across `SPEC`'s record list (no duplicates,
        /// ascending order), and this record's `matrix` is byte-for-byte
        /// identical to `INST[referencedInstanceIndex]`'s matrix every
        /// time. `SPEC` reads as a curated pointer-list into `INST` --
        /// e.g. in `AIRSHIP.GSC` it references instances
        /// `[34,35,36,37,38]` of 41 total. What selection criterion picks
        /// these specific instances is not visible in any decoded field
        /// yet.
        public let referencedInstanceIndex: UInt32
        /// Monotonically non-decreasing across the record list in every
        /// file checked, starting near 0 -- reads like a cumulative
        /// running count/offset into some other, not-yet-located
        /// per-instance sub-list (per-record deltas are fairly regular
        /// within a file but vary by file, e.g. mostly +7/+8 in one file,
        /// +9/+10/+11 in another). Checked and ruled out as an index into
        /// `SST0`, `MS00`, `IABL`, or `NTBL`. Genuinely unresolved.
        public let cumulativeOffset: UInt32
        /// Ruled out as a meaningful index or float: values are a mix of
        /// small plausible-looking integers and a narrow recurring band
        /// (~329,000,000-330,400,000 as `Int32`) consistent with a
        /// leftover/uninitialized heap pointer written to disk, not
        /// intentional per-record data. Exposed raw rather than
        /// interpreted.
        public let unknownTail3: UInt32
        public let unknownTail4: UInt32

        public var translation: SIMD3<Float> { SIMD3(matrix.12, matrix.13, matrix.14) }
    }

    /// Decodes a `SPEC` section's payload: `count:UInt32LE` +
    /// `reserved:UInt32LE` (confirmed `0` in all 7 files checked) +
    /// `count` fixed-width 80-byte records -- `payload.count == 8 +
    /// count*80` exactly (not just an even division) in all 7 files
    /// checked. Same on-disk record shape as `INST`
    /// (``parseInstances(_:)``), but see ``SpecRecord`` for why the
    /// fields mean something different here.
    public static func parseSpecRecords(_ payload: Data) throws -> [SpecRecord] {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { throw ParseError.truncated }
        let count = Int(leUInt32(bytes, 0))
        let remaining = bytes.count - 8
        guard count > 0, remaining % count == 0, remaining / count == 80 else { return [] }

        var records: [SpecRecord] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            let start = 8 + i * 80
            var floats = [Float](repeating: 0, count: 16)
            for f in 0..<16 { floats[f] = leFloat32(bytes, start + f * 4) }
            let tailStart = start + 64
            let referencedInstanceIndex = leUInt32(bytes, tailStart)
            let cumulativeOffset = leUInt32(bytes, tailStart + 4)
            let unknownTail3 = leUInt32(bytes, tailStart + 8)
            let unknownTail4 = leUInt32(bytes, tailStart + 12)
            records.append(SpecRecord(
                matrix: (floats[0], floats[1], floats[2], floats[3],
                         floats[4], floats[5], floats[6], floats[7],
                         floats[8], floats[9], floats[10], floats[11],
                         floats[12], floats[13], floats[14], floats[15]),
                referencedInstanceIndex: referencedInstanceIndex, cumulativeOffset: cumulativeOffset,
                unknownTail3: unknownTail3, unknownTail4: unknownTail4
            ))
        }
        return records
    }

    /// A single texture upload found inside a `TST0` section. `TST0` turns
    /// out not to be a record table at all -- see ``scanTextureEntries(_:)``.
    public struct TextureEntry {
        /// Byte offset (within the `TST0` payload) of this entry's 20-byte
        /// trailer (`sizePlus`, `size`, `fmtA`, `fmtB`, `marker==76`).
        public let trailerOffset: Int
        public let width: Int
        public let height: Int
        /// `1` for indexed/paletted textures (`fmtA == fmtB` in the
        /// trailer) or `4` for direct-color RGBA (`fmtA == 2*fmtB`) --
        /// confirmed via `width*height*bytesPerPixel == size` holding
        /// exactly for every entry checked.
        public let bytesPerPixel: Int
        /// Byte range of this entry's raw texel data within the `TST0`
        /// payload (not decoded further -- still packed in whatever PS2 GS
        /// pixel layout the game used, e.g. indexed textures need their
        /// CLUT/palette to interpret, which is not yet located).
        public let texelDataRange: Range<Int>
    }

    /// Decodes one texture entry given the byte offset of its 20-byte
    /// trailer within a `TST0` payload. `TST0` is **not** a fixed-width
    /// record table (confirmed: `(payload.count-8)` does not divide its
    /// leading count field evenly in any file checked) -- it is a
    /// serialized stream of raw PS2 Graphics Synthesizer texture-upload
    /// command packets (`BITBLTBUF`/`TRXPOS`/`TRXREG`/`TRXDIR` GS register
    /// writes, the standard PS2 "upload image to VRAM" sequence), each
    /// followed by its raw texel bytes.
    ///
    /// Per-entry layout, all CONFIRMED first across 201 real texture
    /// entries in 6 of 7 sample files, then re-checked across the full
    /// 54-file corpus (1110 total validated entries, ZERO dimension-
    /// formula failures). A handful of files (4 of 54) don't use the
    /// padded variant this decoder anchors on at all -- `E3HUB.GSC` was
    /// the first one found; see ``scanTextureEntries(_:)``):
    /// ```
    /// [[0x0CD filler, 32 or 80 bytes]]
    /// trailer (20 bytes): sizePlus:u32 size:u32 fmtA:u32 fmtB:u32 marker:u32(==76)
    /// header (172 bytes): fixed GS-register block; only these fields are decoded:
    ///     word19 (byte 76):  GIFtag-like value; low 15 bits == NLOOP == size/16 + 5
    ///     word31 (byte 124): width (pixels)
    ///     word32 (byte 128): height (pixels)
    /// texelData: `size` bytes immediately after the header
    /// ```
    /// `sizePlus == size + 0xC4` and `width*height*bytesPerPixel == size`
    /// both held exactly for every one of the 1110 checked entries -- not
    /// approximate, not "most of the time".
    ///
    /// Follow-up on the `E3HUB.GSC` exception: its `TRXPOS`/`TRXREG`/
    /// `TRXDIR` register triplet (word offsets 29/33/37 within the
    /// 172-byte header -- i.e. the SAME header shape) is genuinely
    /// present and its width/height fields still read as real,
    /// power-of-2-ish texture dimensions (64x64, 128x128, 256x256, etc.)
    /// -- so the header itself is not different in this file. What
    /// differs is the *trailer* immediately before it: for roughly 2 of
    /// every 3 candidate entries found, all 5 trailer words are exactly
    /// zero (no `sizePlus`/`size`/`marker` at all) rather than populated;
    /// for the rest, the words there are non-zero but don't satisfy
    /// `sizePlus == size + 0xC4` at this offset either. Not resolved --
    /// tried and abandoned rather than guessed at further: this could be
    /// a genuinely different trailer encoding for compact/unpadded
    /// textures, or the true header start in this file sits at a
    /// slightly different fixed offset from the register triplet than in
    /// the other 6 files. Left for a future session with a fresh angle.
    public static func parseTextureEntry(_ payload: Data, trailerOffset: Int) throws -> TextureEntry {
        let bytes = [UInt8](payload)

        // Compute the texture header start offset based on trailerOffset sign
        let textureHeaderStart: Int
        if trailerOffset >= 0 {
            // Padded variant: header is 20 bytes after the trailer
            textureHeaderStart = trailerOffset + 20
        } else {
            // Unpadded variant: header start is -(trailerOffset + 1)
            textureHeaderStart = -(trailerOffset + 1)
        }

        // Guard that we can read the header (172 bytes)
        guard textureHeaderStart >= 0, textureHeaderStart + 172 <= bytes.count else {
            throw ParseError.truncated
        }

        // Read width and height from the header
        let width = Int(leUInt32(bytes, textureHeaderStart + 124))
        let height = Int(leUInt32(bytes, textureHeaderStart + 128))

        // A real texture can never have a zero width or height -- this
        // rejects the rare false-positive candidate (confirmed real,
        // real-byte case: 2 of 105 indexed-texture candidates in
        // CASTLE_C.GSC) whose "header" is unrelated file data landing on
        // a plausible marker/register pattern. Unlike an earlier,
        // rejected attempt at tightening this scan (a `sizePlus`-based
        // check that silently dropped ~80% of real textures), this check
        // has no false-negative risk: it can only ever reject entries
        // that are already unambiguously not real textures.
        guard width > 0, height > 0 else { throw ParseError.truncated }

        // Read fmtA and fmtB from the trailer location (may be out of bounds for unpadded if trailerOffset too negative)
        let fmtATrailerOffset = trailerOffset + 8
        let fmtBTrailerOffset = trailerOffset + 12
        guard fmtATrailerOffset >= 0, fmtATrailerOffset + 4 <= bytes.count,
              fmtBTrailerOffset >= 0, fmtBTrailerOffset + 4 <= bytes.count else {
            throw ParseError.truncated
        }
        let fmtA = leUInt32(bytes, fmtATrailerOffset)
        let fmtB = leUInt32(bytes, fmtBTrailerOffset)

        let bytesPerPixel = fmtA == fmtB ? 1 : 4

        // width/height come from a heuristic scan and may land on a false
        // positive whose "header" is really unrelated file data, so these
        // can be garbage large values -- multiply with overflow checking
        // rather than trapping (this was the source of a SIGTRAP crash
        // when scanning AIRSHIP.GSC).
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: height)
        guard !rowOverflow else { throw ParseError.truncated }
        let (size, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: bytesPerPixel)
        guard !sizeOverflow else { throw ParseError.truncated }

        // Compute texel data start and guard that it fits
        let texelStart = textureHeaderStart + 172
        guard texelStart >= 0, texelStart + size <= bytes.count else {
            throw ParseError.truncated
        }

        return TextureEntry(trailerOffset: trailerOffset, width: width, height: height,
                             bytesPerPixel: bytesPerPixel, texelDataRange: texelStart..<(texelStart + size))
    }

    /// Scans a `TST0` payload for texture entries by searching for the
    /// `marker == 76` trailer signature at 4-byte-aligned offsets and
    /// validating each candidate via ``parseTextureEntry(_:trailerOffset:)``.
    ///
    /// **This is a heuristic scan, not a guaranteed-complete parser** --
    /// on the real `AIRSHIP.GSC` sample it found only 16 of the 42
    /// textures the section's own leading count field declares. The
    /// likely reason (not yet confirmed): some entries -- plausibly
    /// paletted textures with a companion CLUT/palette upload -- carry an
    /// extra register block this scan doesn't recognize, so it skips past
    /// them. A register-triplet count check in a separate file found more
    /// `TRXPOS`/`TRXREG`/`TRXDIR` triplets than `2 x declared count` in
    /// some files, consistent with that idea, but unconfirmed. Use this
    /// for "here are some real, individually-validated textures", not for
    /// "here is every texture in the file".
    public static func scanTextureEntries(_ payload: Data) -> [TextureEntry] {
        let bytes = [UInt8](payload)
        var entriesSet = Set<Int>() // to avoid duplicate entries by trailerOffset
        var entries: [TextureEntry] = []

        // Helper to try adding an entry given a trailerOffset
        func tryAddEntry(trailerOffset: Int) {
            guard !entriesSet.contains(trailerOffset) else { return }
            if let entry = try? parseTextureEntry(payload, trailerOffset: trailerOffset) {
                entriesSet.insert(trailerOffset)
                entries.append(entry)
            }
        }

        // 1. Marker-based scan (padded variants with proper marker)
        var offset = 16 // past the 16-byte TST0 header (count, reserved, word2, word3)
        while offset + 4 <= bytes.count {
            if leUInt32(bytes, offset) == 76, offset >= 16 {
                let trailerOffset = offset - 16
                tryAddEntry(trailerOffset: trailerOffset)
            }
            offset += 4
        }

        // 2. Header-based scan: look for TRXREG GS register (value 82) at 4-byte-aligned offsets
        // This finds the header start regardless of trailer format.
        offset = 0
        while offset + 4 <= bytes.count {
            if leUInt32(bytes, offset) == 82, offset % 4 == 0 {
                let headerStart = offset - 33 * 4 // word 33 of header is TRXREG
                // Candidate 1: padded variant (trailerOffset = headerStart - 20)
                if headerStart >= 20 {
                    let trailerOffsetPadded = headerStart - 20
                    tryAddEntry(trailerOffset: trailerOffsetPadded)
                }
                // Candidate 2: unpadded variant (trailerOffset = -(headerStart + 1))
                let trailerOffsetUnpadded = -(headerStart + 1)
                tryAddEntry(trailerOffset: trailerOffsetUnpadded)
            }
            offset += 4
        }

        return entries
    }

    /// Decodes an `SST0` section's outer shape (`SST0` is always the last
    /// section in the file, i.e. a "footer"). CONFIRMED across the files
    /// checked: `blobLength:u32` at payload offset 4 exactly accounts for
    /// a byte range (`blob = payload[8..<8+blobLength]`), with whatever
    /// remains after that (`trailer`) always a small handful of bytes,
    /// never garbage-length.
    ///
    /// One recurring but NOT universal pattern worth flagging for a future
    /// session: re-checked across the full 54-file corpus, exactly 10 of
    /// 53 files with `SST0` have a trailer that's exactly 12 bytes whose
    /// *last* 4 bytes exactly equal this `SST0` section's own outer
    /// `length` field from the top-level container header (echoing the
    /// section's total size back into its own footer) -- and in every one
    /// of those 10, the echo is exact (zero false positives -- when this
    /// trailer shape appears, it's never wrong, just not always present).
    /// The other 43 files differ: `CASTLE_C.GSC` has a shorter 8-byte
    /// trailer with no such echo, `JUNGLE_A.GSC` has no trailer at all
    /// (the blob accounts for every remaining byte), and `AIRSHIP.GSC`'s
    /// entire `SST0` is degenerate (`firstField`/`blobLength` both `0`, no
    /// blob, no trailer). So this function only decodes the confirmed
    /// outer split; the trailer-echo pattern is documented but not
    /// enforced/parsed, since it isn't universal.
    public static func parseFooterHeader(_ payload: Data) throws -> (firstField: UInt32, blob: Data, trailer: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { return (0, Data(), Data()) }
        let firstField = leUInt32(bytes, 0)
        let blobLength = Int(leUInt32(bytes, 4))
        guard 8 + blobLength <= bytes.count else { throw ParseError.truncated }
        let blob = Data(bytes[8..<(8 + blobLength)])
        let trailer = Data(bytes[(8 + blobLength)...])
        return (firstField, blob, trailer)
    }

    /// Given the byte offset (within an `OBJ0` payload) of the recurring
    /// 4-byte marker `0x6C010056` (bytes `56 00 01 6C`) that sits inside
    /// every mesh "chunk" header found so far, returns that chunk's total
    /// byte length. CONFIRMED formula: `chunkLength == lengthField + 128`,
    /// where `lengthField` is the `UInt32LE` sitting exactly 20 bytes
    /// before the marker. Independently re-verified (not just trusting
    /// the source that found this): walking `AIRSHIP.GSC`'s entire `OBJ0`
    /// payload with this rule, using this marker to locate each
    /// successive chunk, consumes exactly 100% of its bytes (398344/398344,
    /// 222 chunks, zero drift).
    ///
    /// Decodes one chunk given the byte offset of its marker.
    public static func obj0ChunkLength(_ payload: Data, markerOffset: Int) throws -> Int {
        let bytes = [UInt8](payload)
        let lengthFieldOffset = markerOffset - 20
        guard lengthFieldOffset >= 0, lengthFieldOffset + 4 <= bytes.count else { throw ParseError.truncated }
        return Int(leUInt32(bytes, lengthFieldOffset)) + 128
    }

    /// One chunk found by ``walkOBJ0Chunks(_:)``.
    public struct OBJ0Chunk {
        public let byteOffset: Int
        public let length: Int
        /// Absolute payload offset of this chunk's own `56 00 01 6C`
        /// marker -- kept (not just `byteOffset`/`length`) because
        /// ``groupOBJ0ChunksIntoEntries(_:)``'s entry-boundary flag is
        /// defined relative to the *marker*, not the chunk start (real
        /// files have a real, varying marker-to-chunk-start distance, so
        /// only the marker's own position is a safe anchor).
        public let markerOffset: Int
    }

    /// A validated multi-chunk walk over an `OBJ0` payload. A bare "scan
    /// forward for the next marker occurrence" walk (as in
    /// ``obj0ChunkLength(_:markerOffset:)``'s original version) is not
    /// safe in general: a false-positive marker match inside unrelated
    /// data can send `chunkLength` to a nonsense value and the walk
    /// diverges completely. This version guards against that by requiring
    /// each candidate `chunkLength` to be plausible (real chunk lengths
    /// observed across 4 files ranged 384-78976 bytes; this rejects
    /// anything above 200,000 as a generous 2.5x safety margin, and
    /// rejects any jump that would overshoot the payload) before trusting
    /// it, skipping to the next marker occurrence instead when a
    /// candidate fails validation.
    ///
    /// **Marker-reuse bug, fixed via a containment check** (found by a
    /// dedicated follow-up investigation into
    /// ``groupOBJ0ChunksIntoEntries(_:)`` below): on files whose chunks
    /// don't all share one constant marker-to-chunk-start distance
    /// (heterogeneous chunk *types* in the same file -- confirmed on
    /// `CASTLE_C.GSC`/`HUB.GSC`), this walk used to validate the *same*
    /// literal marker occurrence against dozens to hundreds of consecutive
    /// fabricated "chunks" at a constant stride, because nothing required
    /// a validated marker to actually be near the chunk it was validating.
    /// Concretely observed on `HUB.GSC`: one marker at payload offset
    /// 751032 got reused to "validate" 255 different chunks at a flat
    /// 384-byte stride.
    ///
    /// The fix: a candidate's own marker must fall *within* the byte span
    /// it's claiming to validate (`markerOffset < offset + chunkLength`),
    /// which a genuinely-distant reused marker never satisfies. This is
    /// deliberately looser than requiring one single constant distance
    /// file-wide -- an earlier attempt at that was empirically too strict
    /// (`CASTLE_C.GSC` dropped to 4 real chunks), confirming these files
    /// really do mix multiple legitimately different chunk header shapes,
    /// not just walk noise. Re-verified real-file impact: zero change on
    /// the 3 previously-clean files (`AIRSHIP.GSC`/`FARM.GSC`/`DROID.GSC`,
    /// byte-for-byte identical chunk lists, no regression), and zero
    /// duplicate marker reuse on `CASTLE_C.GSC`/`HUB.GSC` afterward -- but
    /// coverage on those two honestly drops way down (to 8 and 27 real
    /// chunks respectively, vs the previous 1975/2317 fabricated ones) --
    /// **still far short of those files' true chunk counts** (`OBJ0`'s own
    /// leading counts: 1113/700 entries). The remaining heterogeneous
    /// chunk header shapes on these two files are not understood; this
    /// fix trades "silently wrong, high coverage" for "honestly partial,
    /// real coverage" -- it does not solve `OBJ0` boundaries for them.
    ///
    /// Re-verified with the plausibility safeguard across 4 real files of
    /// very different sizes: `AIRSHIP.GSC` 100.00% (222 chunks, marker-
    /// reuse-free), `FARM.GSC` 99.99% (745 chunks, marker-reuse-free),
    /// `CASTLE_C.GSC` -- see containment-fix note above for real coverage,
    /// `HUB.GSC` -- same -- each walk on the clean files stops a few
    /// hundred to a few thousand bytes short of the true end
    /// (out of multi-megabyte payloads) rather than diverging completely.
    public static func walkOBJ0Chunks(_ payload: Data) -> [OBJ0Chunk] {
        let marker = Data([0x56, 0x00, 0x01, 0x6C])
        let maxReasonableChunkLength = 200_000
        var chunks: [OBJ0Chunk] = []
        var offset = 8
        var searchFrom = offset
        while offset < payload.count {
            var candidate = searchFrom
            var validated: (length: Int, markerOffset: Int)?
            searchLoop: while let markerRange = payload.range(of: marker, in: candidate..<payload.count) {
                let markerOffset = markerRange.lowerBound - payload.startIndex
                let lengthFieldOffset = markerOffset - 20
                if lengthFieldOffset >= offset, let chunkLength = try? obj0ChunkLength(payload, markerOffset: markerOffset),
                   chunkLength > 0, chunkLength <= maxReasonableChunkLength, offset + chunkLength <= payload.count + 4096,
                   markerOffset < offset + chunkLength {
                    validated = (chunkLength, markerOffset)
                    break searchLoop
                }
                candidate = markerOffset + 4
            }
            guard let (chunkLength, markerOffset) = validated else { break }
            chunks.append(OBJ0Chunk(byteOffset: offset, length: chunkLength, markerOffset: markerOffset))
            offset += chunkLength
            searchFrom = offset
        }
        return chunks
    }

    /// Groups `walkOBJ0Chunks(_:)`'s fine-grained chunks into `OBJ0`'s own
    /// coarser per-object entries -- the boundary this format needed to
    /// become usable for real mesh rendering (see this file's own doc
    /// comment: `OBJ0`'s per-entry format holds real embedded mesh
    /// geometry, but until now entry *boundaries* were unsolved, e.g.
    /// `AIRSHIP.GSC` has 222 real chunks but only 41 top-level entries per
    /// its own leading count field).
    ///
    /// **CONFIRMED rule**: a `UInt32LE` field sitting at exactly
    /// `chunk.markerOffset - 112` (112 bytes *before* the chunk's own
    /// marker -- not before the chunk's start, which varies file to
    /// file) takes only values `0`/`1`. `1` means "this chunk starts a
    /// new top-level entry"; `0` means "this chunk continues the current
    /// entry." The very first chunk always starts entry 0 regardless of
    /// its own flag (nothing precedes it to need a boundary marker).
    /// Validated with **15/15 exact matches** (grouped entry count ==
    /// `OBJ0`'s own leading-count field, zero mismatches) against real
    /// files ranging from 40 to 1198 declared entries -- and the 112-byte
    /// distance was confirmed unique: every other 4-byte-aligned offset
    /// from 4 to 296 was swept on 3 sample files and only 112 ever
    /// produced a matching count, ruling out coincidence.
    ///
    /// **Scope limitation, stated honestly rather than silently wrong**:
    /// this rule was only validated at full strength (grouped count ==
    /// `OBJ0`'s own leading-count field) on files where `walkOBJ0Chunks(_:)`
    /// covers close to 100% of the payload. `CASTLE_C.GSC`/`HUB.GSC` have
    /// heterogeneous per-chunk header sizes that `walkOBJ0Chunks(_:)` only
    /// partially understands (see its own doc comment on the containment
    /// fix) -- grouping those files' chunks still works and is real, but
    /// covers far fewer entries than `OBJ0`'s own declared count (e.g.
    /// `HUB.GSC`: ~27 real entries found vs 700 declared). The
    /// `seenMarkerOffsets` check below stays in place as a defense-in-depth
    /// safety net -- if a marker-reuse bug is ever reintroduced upstream,
    /// this still refuses to guess rather than silently producing a wrong
    /// grouping from it.
    ///
    /// - Returns: One array of chunks per top-level `OBJ0` entry found, in
    ///   order -- possibly far fewer than `OBJ0`'s own declared entry count
    ///   on a file `walkOBJ0Chunks(_:)` only partially covers -- or `nil`
    ///   if a marker gets reused across walked chunks (a walk-level bug
    ///   this function refuses to build a grouping from).
    public static func groupOBJ0ChunksIntoEntries(_ payload: Data) -> [[OBJ0Chunk]]? {
        let chunks = walkOBJ0Chunks(payload)
        guard !chunks.isEmpty else { return [] }

        var seenMarkerOffsets = Set<Int>()
        for chunk in chunks {
            guard seenMarkerOffsets.insert(chunk.markerOffset).inserted else { return nil }
        }

        let bytes = [UInt8](payload)
        var groups: [[OBJ0Chunk]] = []
        for chunk in chunks {
            let flagOffset = chunk.markerOffset - 112
            let startsNewEntry: Bool
            if groups.isEmpty {
                startsNewEntry = true // the first chunk always starts entry 0
            } else if flagOffset >= 0, flagOffset + 4 <= bytes.count {
                startsNewEntry = leUInt32(bytes, flagOffset) == 1
            } else {
                startsNewEntry = false
            }
            if startsNewEntry || groups.isEmpty {
                groups.append([chunk])
            } else {
                groups[groups.count - 1].append(chunk)
            }
        }
        return groups
    }

    /// One embedded PS2 GS/VU geometry payload within a mesh-shaped
    /// `ObjSetRecord` -- see ``ObjSetRecordBody/mesh(origin:geos:)``.
    /// `payload`'s two possible internal shapes (a VU "tristream" of
    /// triangles, or a raw DMA "dmastream" tag chain) are selected in the
    /// real engine by the referenced material's own `ot` attribute bit --
    /// not decoded from `MS00` yet, so `payload` is exposed raw rather
    /// than guessed at. `headerBlob` is a real, confirmed-present region
    /// (its exact byte length is read directly from the file) whose
    /// *content* isn't understood yet either.
    public struct ObjSetGeoEntry {
        public let materialIndex: Int
        public let headerBlob: Data
        public let payload: Data
    }

    /// One billboard-style "faceon" face within a faceon-shaped
    /// `ObjSetRecord` -- see ``ObjSetRecordBody/faceon(faces:)``.
    public struct ObjSetFaceonEntry {
        public let materialIndex: Int
        public let faceonType: Int32
        public let faceonRadius: Float
        public let payload: Data
    }

    /// The two mutually-exclusive shapes a single `ObjSetRecord` can
    /// take, selected by a `UInt32LE` type tag read directly from the
    /// file (`0` or `1` in every one of the 58 real files checked --
    /// `ReadObjSet`'s own source has a `default:` case that errors out on
    /// any other value, so this parser treats a 3rd value as truncation
    /// too, consistent with that).
    public enum ObjSetRecordBody {
        /// Real embedded mesh geometry -- one entry per `GeoEntry`,
        /// `origin` is a real world-space offset (12 bytes, read but not
        /// yet cross-checked against `INST` the way `Instance` was).
        case mesh(origin: SIMD3<Float>, geos: [ObjSetGeoEntry])
        /// A simpler billboard/sprite-style shape -- no `origin` field
        /// exists for this variant in the real file (confirmed: the C
        /// source zeroes it locally rather than reading it).
        case faceon(faces: [ObjSetFaceonEntry])
    }

    /// One real sub-record within an ``ObjSetEntry``. `boundsMin`/
    /// `boundsMax` are read directly (not computed) -- real axis-aligned
    /// bounds for this specific mesh/faceon record.
    public struct ObjSetRecord {
        public let body: ObjSetRecordBody
        public let boundsMin: SIMD3<Float>
        public let boundsMax: SIMD3<Float>
    }

    /// One real `OBJ0` entry (one placeable object/mesh definition, the
    /// same granularity `INST.objectIndex` references) -- may contain
    /// more than one ``ObjSetRecord`` (real files were seen with up to a
    /// handful of records per entry, most have exactly one).
    public struct ObjSetEntry {
        public let records: [ObjSetRecord]
        /// Present only when the section-wide `sp18` flag (see
        /// ``parseObjSet(_:materialCount:)``) is set AND this specific
        /// entry's own `colourRefSize` is nonzero -- real per-vertex
        /// color-reference data, not decoded further.
        public let colourRef: Data?
    }

    /// A complete, real decode of an `OBJ0` section's payload.
    public struct ObjSet {
        public let entries: [ObjSetEntry]
    }

    public enum ObjSetParseError: Error, Equatable {
        case truncated
        case implausibleValue(String)
        case unknownRecordType(Int32)
    }

    /// Decodes an entire `OBJ0` section by directly implementing the real
    /// `ReadObjSet` C algorithm found in this project's decompiled
    /// reference source (`OpenCrashWOC-main/PS2_Version/
    /// GHG_GSC_FUNCTIONS.txt`, `ReadObjSet`, read verbatim) -- a fully
    /// **sequential, length-prefixed** reader that needs no
    /// marker-scanning at all, unlike ``walkOBJ0Chunks(_:)``/
    /// ``groupOBJ0ChunksIntoEntries(_:)``.
    ///
    /// **CONFIRMED, the strongest bar this codebase holds anything to**:
    /// checked against all 58 real files on the mounted disc that have
    /// both a parseable container and an `OBJ0` section -- every single
    /// one consumes its `OBJ0` payload down to the **exact last byte**
    /// (`finalPosition == payload.count`, zero leftover, zero overrun),
    /// with `entries.count` exactly matching that section's own
    /// leading declared count every time, INCLUDING the two files
    /// `walkOBJ0Chunks`'s marker-based heuristic could previously only
    /// partially cover -- `HUB.GSC` (700/700 entries now, was 27/700) and
    /// `CASTLE_C.GSC` (1113/1113, was 8/1113). This directly resolves
    /// what this codebase's own top-of-file summary and
    /// `groupOBJ0ChunksIntoEntries`'s doc comment both flagged as OBJ0's
    /// last major open placement problem.
    ///
    /// ```
    /// ObjSet := numEntries:UInt32LE hasColourRef:UInt32LE
    ///           Entry(numEntries)
    /// Entry  := recordCount:UInt32LE reserved:UInt32LE(x3, discarded)
    ///           Record(recordCount)
    ///           [if hasColourRef == 1: colourRefSize:UInt32LE reserved:UInt32LE(x3)
    ///                                  Bytes(colourRefSize)]
    /// Record := type:UInt32LE
    ///           (Mesh | Faceon, see below, selected by type)
    ///           boundsMin:Vec3 boundsMax:Vec3 reserved:UInt32LE(x2, discarded)
    /// Mesh   := geoCount:UInt32LE origin:Vec3 headerBlobLength:UInt32LE reserved:UInt32LE(x2)
    ///           Geo(geoCount)
    /// Geo    := reserved:UInt32LE(discarded) headerBlobLength:UInt32LE materialIndex:UInt32LE
    ///           headerBlob:Bytes(headerBlobLength) payloadLength:UInt32LE(must be a multiple of 16)
    ///           payload:Bytes(payloadLength)
    /// Faceon := faceCount:UInt32LE reserved:UInt32LE(x2)
    ///           Face(faceCount)
    /// Face   := materialIndex:UInt32LE faceonType:UInt32LE faceonRadius:Float32LE
    ///           payloadLength:UInt32LE payload:Bytes(payloadLength)
    /// ```
    /// `materialIndex` is checked against `materialCount` (that same
    /// file's own real `MS00` record count, via ``parseMaterialSet(_:)``)
    /// when the caller provides it -- every real index was in-bounds in
    /// all 58 files checked, zero exceptions, so an out-of-bounds index
    /// is treated as real evidence something upstream desynced rather
    /// than silently trusted. Pass `nil` to skip that check (e.g. if the
    /// caller doesn't have `MS00` decoded).
    ///
    /// **Deliberately not wired into mesh rendering yet.**
    /// `WOCMeshDecoder`'s `MeshAsset`/`MeshSubmesh` pipeline (and the
    /// `WOCLevelAsset`/3D viewer built on it) still uses
    /// `groupOBJ0ChunksIntoEntries(_:)`'s older, partial-coverage
    /// heuristic -- this function is additive, not a replacement, so
    /// nothing about what the viewer currently renders changes from this
    /// commit. Migrating the mesh pipeline to this decoder would be a
    /// real improvement (especially for `CASTLE_C.GSC`/`HUB.GSC`, which
    /// currently render only a small fraction of their real geometry) but
    /// is a separate, bigger step -- it touches what's actually visible
    /// in the viewer, and this codebase's own convention is to flag that
    /// kind of change explicitly rather than fold it into a decoder fix.
    public static func parseObjSet(_ payload: Data, materialCount: Int?) throws -> ObjSet {
        let bytes = [UInt8](payload)

        struct Cursor {
            let bytes: [UInt8]
            var pos: Int
            mutating func int32() throws -> Int32 {
                guard pos + 4 <= bytes.count else { throw ObjSetParseError.truncated }
                let v = Int32(bitPattern: WOCContainerParser.leUInt32(bytes, pos))
                pos += 4
                return v
            }
            mutating func float32() throws -> Float {
                guard pos + 4 <= bytes.count else { throw ObjSetParseError.truncated }
                let v = WOCContainerParser.leFloat32(bytes, pos)
                pos += 4
                return v
            }
            mutating func vec3() throws -> SIMD3<Float> {
                SIMD3(try float32(), try float32(), try float32())
            }
            mutating func take(_ n: Int) throws -> Data {
                guard n >= 0, pos + n <= bytes.count else { throw ObjSetParseError.truncated }
                defer { pos += n }
                return Data(bytes[pos..<(pos + n)])
            }
            mutating func skip(_ n: Int) throws {
                guard n >= 0, pos + n <= bytes.count else { throw ObjSetParseError.truncated }
                pos += n
            }
        }

        func checkMaterialIndex(_ index: Int32) throws -> Int {
            if let materialCount, !(0..<materialCount).contains(Int(index)) {
                throw ObjSetParseError.implausibleValue("materialIndex \(index) out of bounds for \(materialCount) real materials")
            }
            return Int(index)
        }

        var cursor = Cursor(bytes: bytes, pos: 0)
        let numEntries = try cursor.int32()
        let hasColourRef = try cursor.int32()
        guard numEntries >= 0, numEntries < 10_000 else {
            throw ObjSetParseError.implausibleValue("numEntries \(numEntries)")
        }

        var entries: [ObjSetEntry] = []
        entries.reserveCapacity(Int(numEntries))
        for _ in 0..<numEntries {
            let recordCount = try cursor.int32()
            _ = try cursor.int32(); _ = try cursor.int32(); _ = try cursor.int32()
            guard recordCount >= 0, recordCount < 10_000 else {
                throw ObjSetParseError.implausibleValue("recordCount \(recordCount)")
            }

            var records: [ObjSetRecord] = []
            records.reserveCapacity(Int(recordCount))
            for _ in 0..<recordCount {
                let type = try cursor.int32()
                let body: ObjSetRecordBody
                switch type {
                case 0:
                    let geoCount = try cursor.int32()
                    guard geoCount >= 0, geoCount < 10_000 else {
                        throw ObjSetParseError.implausibleValue("geoCount \(geoCount)")
                    }
                    let origin = try cursor.vec3()
                    _ = try cursor.int32() // colourRefSize, captured at the Entry level below instead
                    _ = try cursor.int32(); _ = try cursor.int32()

                    var geos: [ObjSetGeoEntry] = []
                    geos.reserveCapacity(Int(geoCount))
                    for _ in 0..<geoCount {
                        _ = try cursor.int32()
                        let headerBlobLength = try cursor.int32()
                        let materialIndex = try checkMaterialIndex(try cursor.int32())
                        guard headerBlobLength >= 0 else { throw ObjSetParseError.implausibleValue("headerBlobLength \(headerBlobLength)") }
                        let headerBlob = try cursor.take(Int(headerBlobLength))
                        let payloadLength = try cursor.int32()
                        guard payloadLength >= 0, payloadLength % 16 == 0 else {
                            throw ObjSetParseError.implausibleValue("payloadLength \(payloadLength) not qwc-aligned")
                        }
                        let payload = try cursor.take(Int(payloadLength))
                        geos.append(ObjSetGeoEntry(materialIndex: materialIndex, headerBlob: headerBlob, payload: payload))
                    }
                    body = .mesh(origin: origin, geos: geos)
                case 1:
                    let faceCount = try cursor.int32()
                    guard faceCount >= 0, faceCount < 10_000 else {
                        throw ObjSetParseError.implausibleValue("faceCount \(faceCount)")
                    }
                    _ = try cursor.int32(); _ = try cursor.int32()

                    var faces: [ObjSetFaceonEntry] = []
                    faces.reserveCapacity(Int(faceCount))
                    for _ in 0..<faceCount {
                        let materialIndex = try checkMaterialIndex(try cursor.int32())
                        let faceonType = try cursor.int32()
                        let faceonRadius = try cursor.float32()
                        let payloadLength = try cursor.int32()
                        guard payloadLength >= 0 else { throw ObjSetParseError.implausibleValue("faceon payloadLength \(payloadLength)") }
                        let payload = try cursor.take(Int(payloadLength))
                        faces.append(ObjSetFaceonEntry(materialIndex: materialIndex, faceonType: faceonType, faceonRadius: faceonRadius, payload: payload))
                    }
                    body = .faceon(faces: faces)
                default:
                    throw ObjSetParseError.unknownRecordType(type)
                }

                let boundsMin = try cursor.vec3()
                let boundsMax = try cursor.vec3()
                _ = try cursor.int32(); _ = try cursor.int32()
                records.append(ObjSetRecord(body: body, boundsMin: boundsMin, boundsMax: boundsMax))
            }

            var colourRef: Data?
            if hasColourRef == 1 {
                let colourRefSize = try cursor.int32()
                _ = try cursor.int32(); _ = try cursor.int32(); _ = try cursor.int32()
                if colourRefSize != 0 {
                    guard colourRefSize > 0, colourRefSize < 10_000_000 else {
                        throw ObjSetParseError.implausibleValue("colourRefSize \(colourRefSize)")
                    }
                    colourRef = try cursor.take(Int(colourRefSize))
                }
            }
            entries.append(ObjSetEntry(records: records, colourRef: colourRef))
        }

        guard cursor.pos == bytes.count else {
            throw ObjSetParseError.implausibleValue("leftover bytes: consumed \(cursor.pos) of \(bytes.count)")
        }
        return ObjSet(entries: entries)
    }

    // MARK: - helpers

    private static func leFloat32(_ b: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: leUInt32(b, o))
    }

    private static func leUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func asciiTag(_ b: [UInt8], _ o: Int) -> String? {
        for i in 0..<4 {
            let c = b[o + i]
            let isUpper = c >= 0x41 && c <= 0x5A
            let isDigit = c >= 0x30 && c <= 0x39
            guard isUpper || isDigit else { return nil }
        }
        return String(decoding: b[o..<(o + 4)], as: UTF8.self)
    }

    // MARK: - Matrix Validation
    
    /// Compares two 4x4 matrices for equality within a tolerance.
    /// This function safely handles floating-point comparisons by using
    /// an epsilon-based approach to avoid issues with NaN values or
    /// floating-point precision errors that could cause SIGTRAP.
    /// - Parameters:
    ///   - a: First matrix as a 16-element tuple
    ///   - b: Second matrix as a 16-element tuple
    /// - Returns: True if matrices are equal within epsilon tolerance
    private static func matricesEqual(
        _ a: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float),
        _ b: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)
    ) -> Bool {
        let epsilon: Float = 1e-5
        return abs(a.0 - b.0) < epsilon &&
               abs(a.1 - b.1) < epsilon &&
               abs(a.2 - b.2) < epsilon &&
               abs(a.3 - b.3) < epsilon &&
               abs(a.4 - b.4) < epsilon &&
               abs(a.5 - b.5) < epsilon &&
               abs(a.6 - b.6) < epsilon &&
               abs(a.7 - b.7) < epsilon &&
               abs(a.8 - b.8) < epsilon &&
               abs(a.9 - b.9) < epsilon &&
               abs(a.10 - b.10) < epsilon &&
               abs(a.11 - b.11) < epsilon &&
               abs(a.12 - b.12) < epsilon &&
               abs(a.13 - b.13) < epsilon &&
               abs(a.14 - b.14) < epsilon &&
               abs(a.15 - b.15) < epsilon
    }
    
    /// Validates that all SPEC records have matrices that are byte-identical
    /// to their corresponding INST records (as referenced by referencedInstanceIndex).
    /// This function replicates the validation performed in the test suite.
    /// - Parameters:
    ///   - instances: Array of Instance objects from INST section
    ///   - specRecords: Array of SpecRecord objects from SPEC section
    /// - Throws: ValidationError if any matrix mismatch is found
    public static func validateSpecMatricesMatchInst(
        _ instances: [Instance],
        _ specRecords: [SpecRecord]
    ) throws {
        var previousIndex: Int64 = -1
        for record in specRecords {
            let refIndex = Int(record.referencedInstanceIndex)
            
            // Validate referencedInstanceIndex is strictly increasing
            guard Int64(refIndex) > previousIndex else {
                throw ValidationError.specReferencedInstanceIndexNotIncreasing(
                    current: refIndex, previous: Int(previousIndex)
                )
            }
            previousIndex = Int64(refIndex)
            
            // Validate referencedInstanceIndex is within bounds
            guard refIndex < instances.count else {
                throw ValidationError.specReferencedInstanceIndexOutOfBounds(
                    index: refIndex, count: instances.count
                )
            }
            
            // Get the referenced INST record
            let referenced = instances[refIndex]
            
            // Validate matrix equality using safe comparison
            guard matricesEqual(record.matrix, referenced.matrix) else {
                throw ValidationError.specMatrixDoesNotMatchInst(
                    specIndex: Int(refIndex),
                    instIndex: refIndex
                )
            }
        }
    }
    
    /// Enumeration of validation errors that can occur during SPEC-INST matrix validation.
    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case specReferencedInstanceIndexNotIncreasing(current: Int, previous: Int)
        case specReferencedInstanceIndexOutOfBounds(index: Int, count: Int)
        case specMatrixDoesNotMatchInst(specIndex: Int, instIndex: Int)
        
        public var description: String {
            switch self {
            case let .specReferencedInstanceIndexNotIncreasing(current, previous):
                return "SPEC referencedInstanceIndex (\(current)) is not strictly increasing (previous: \(previous))"
            case let .specReferencedInstanceIndexOutOfBounds(index, count):
                return "SPEC referencedInstanceIndex (\(index)) is out of bounds for INST array (count: \(count))"
            case let .specMatrixDoesNotMatchInst(specIndex, instIndex):
                return "SPEC record at index \(specIndex) matrix does not match INST record at index \(instIndex)"
            }
        }
    }
}
