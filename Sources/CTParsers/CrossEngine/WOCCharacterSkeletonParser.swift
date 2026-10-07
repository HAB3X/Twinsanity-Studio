import Foundation
import simd

/// Decodes a real joint hierarchy from one already-decompressed
/// `CHARS.DAT` entry (see `WOCCharacterArchiveParser` for the archive
/// container/decompression layer this builds on).
///
/// **CONFIRMED, very high confidence** -- corpus-validated across all 12
/// real "skeleton" entries in the archive (decompressed-header offset 4
/// `== 0` and offset 12 `== 0`, i.e. no mesh geometry -- see
/// `WOCCharacterArchiveParser`'s doc comment on the Format-A header
/// shape this refines), zero exceptions:
/// ```
/// Entry (decompressed) := totalSize:UInt32LE(==own length) 0:UInt32LE 0:UInt32LE 0:UInt32LE
///         field16:UInt32LE field20:UInt32LE
///         jointCount:UInt32LE tableAOffset:UInt32LE tableBOffset:UInt32LE tableCOffset:UInt32LE
///         0:UInt32LE tableDOffset:UInt32LE
///         nameTableOffset:UInt32LE nameTableLength:UInt32LE
///         ... (unrelated bytes before/around/between the tables above)
/// JointRecord := Bytes(96), see ``Joint`` for the confirmed fields within it
/// ```
/// `tableAOffset`/`tableBOffset`/`tableCOffset`/`tableDOffset` are
/// **stored absolute byte offsets into the entry**, not fixed structural
/// positions -- confirmed by direct arithmetic: `tableAOffset +
/// jointCount*96 == tableBOffset`, and `tableBOffset + jointCount*64 ==
/// tableCOffset`, exactly, on every real skeleton entry checked (this is
/// `WOCCharacterArchiveParser`'s already-independently-confirmed "Table
/// A"/two 64-byte tables, now with their real addressing scheme pinned
/// down). Table D is not decoded by this type. `field16`/`field20`
/// correlate with something outside the scope of skeleton entries
/// (`WOCCharacterArchiveParser`'s own "N"/mesh-arc count investigation)
/// and are ignored here.
///
/// **Tables A/B/C's real content, confirmed against
/// `OpenCrashWOC-main`'s `nu3dx/nuhgobj.c`'s `ReadNuIFFHGobjSet`
/// (tagged `MATCH GCN`) and byte-verified against real `CHARS.DAT`
/// bytes, not just trusted from source.** That function reads, per
/// joint, in this exact order: a `numtx_s orient` (4x4 float matrix,
/// 0x40 bytes), a `numtx_s T` (local bind matrix, into a *separate*
/// parallel array), a `numtx_s INV_WT` (inverse-world/bind matrix, into
/// another separate parallel array), a `nuvec_s locator_offset` (0xC),
/// `parent_ix:UInt8`, and a `nameOffset:Int32` -- and the compiler-
/// verified DWARF struct for the non-array fields (`NUJOINTDATA_s`,
/// 0x60=96 bytes) puts `name` at offset **0x4C=76** and `parent_ix` at
/// offset **0x50=80** -- an *exact* match to this parser's own,
/// independently-confirmed `nameOffset`/`parentIndex` byte positions in
/// `Table A`'s 96-byte record, found from real bytes with no source
/// access. That match, found after the fact, is what promotes this from
/// "a plausible sibling-engine analogy" to "confirmed": `Table A` really
/// is `NUJOINTDATA_s` (`orient` at bytes 0-63, `locator_offset` at bytes
/// 64-75, matching the same struct's own offsets 0x0/0x40), `Table B`
/// really is the separate `T[]` array (local bind matrix per joint), and
/// `Table C` really is the separate `INV_WT[]` array (inverse-world/bind
/// matrix per joint) -- both real, standard `numtx_s` (4x4 float, row-
/// major, translation in row 3 -- same convention this codebase's own
/// `WOCObjectInstance.matrix` doc comment already established for WoC).
/// Re-verified directly on real entry #71 (the 47-joint Crash rig):
/// `orient` is exactly the identity matrix for every joint sampled
/// (root, `Pelvis`, `LeftToe`) -- real, valid rest orientations, not
/// noise; every sampled `Table B`/`Table C` matrix has a real, correct
/// affine bottom row (`[0,0,0,1]` to float precision); `Table B[LeftToe]`
/// (a leaf joint) has a small, plausible local translation
/// (`(0.018, -0.044, -0.115)`) with a near-identity rotation submatrix
/// (off-diagonal terms `~1e-5`); `Table C[LeftToe]`'s rotation submatrix
/// is genuinely **orthonormal** (each row's magnitude ≈1.0 to 3 decimal
/// places) and visibly the *cumulative* chain rotation (much larger
/// off-diagonal terms than `Table B`'s local-only one) -- exactly the
/// local-vs-cumulative-world distinction the source's `T`/`INV_WT`
/// naming predicts, and a hard signal to fake by coincidence.
///
/// `nameTableOffset`/`nameTableLength` mark a packed, null-terminated
/// ASCII string table (e.g. entry 71, a real 47-joint Crash rig:
/// `"CrashBones\0Pelvis\0LeftLeg\0LeftKnee\0LeftAnkle\0LeftToe\0..."`) --
/// but `JointRecord.name` is resolved via each record's own absolute
/// name offset (below), not by walking this table in order, so this
/// range is informational rather than required for decoding.
///
/// Validated end-to-end on all 12 real skeleton entries: exactly one
/// root joint (`parentIndex == -1`) and zero invalid parent references
/// (every non-root `parentIndex` is a valid, already-defined, strictly
/// earlier joint index -- a real DAG) in every single one, including a
/// full 47-bone anatomically-correct Crash rig (`Pelvis -> LeftLeg ->
/// LeftKnee -> LeftAnkle -> LeftToe`, a mirrored `Right*` chain, `Back ->
/// UpperTorso -> NeckBase -> {LeftArm, RightArm, Face}`, finger and
/// spike/ear chains all correctly parented), a 3-joint creature rig
/// (`Mouse_Root -> Mouse_Tail`/`Mouse_Head`), and 8 single-bone prop
/// roots (`blue_root`, `bonus_gem_root`, `Crystal_Root`, ...).
public enum WOCCharacterSkeletonParser {
    public enum ParseError: Error, Equatable {
        case truncated
        case notASkeletonEntry
    }

    /// One joint. See this file's own doc comment for what's confirmed
    /// and how -- `raw` still carries the full record for anything not
    /// exposed as a typed property.
    public struct Joint {
        public let name: String
        /// `-1` for the root joint; otherwise a valid, strictly-earlier
        /// index into the same `Skeleton.joints` array (confirmed a real
        /// DAG on every sample checked -- see this file's own doc
        /// comment).
        public let parentIndex: Int
        /// `Table A` bytes 0-63 -- this joint's rest orientation matrix
        /// (`NUJOINTDATA_s.orient`). Row-major, translation (if any) in
        /// row 3, matching this codebase's established WoC matrix
        /// convention. Identity on every real joint sampled so far.
        public let restOrientation: simd_float4x4
        /// `Table A` bytes 64-75 -- a real per-joint offset
        /// (`NUJOINTDATA_s.locator_offset`); non-zero real values seen
        /// (e.g. the Crash rig's root), zero on most joints sampled.
        /// Purpose beyond "a real offset" not independently confirmed.
        public let locatorOffset: SIMD3<Float>
        /// `Table B`, this joint's own row -- the local bind-pose matrix
        /// (`NUHGOBJ_s.T[i]`). Row-major, translation in row 3.
        public let localBindMatrix: simd_float4x4
        /// `Table C`, this joint's own row -- the inverse-world/bind
        /// matrix (`NUHGOBJ_s.INV_WT[i]`), i.e. the matrix a real-time
        /// renderer would multiply by the joint's current animated world
        /// matrix to get a skinning matrix. Row-major, translation in
        /// row 3; unlike `localBindMatrix`, this is cumulative across the
        /// joint's whole ancestor chain, not just relative to its parent.
        public let inverseBindMatrix: simd_float4x4
        /// The full 96-byte `Table A` record. Byte 81 is a small flag
        /// (`8` on the two "material root"/entry-0-joint cases checked,
        /// `1` otherwise) -- real, structured, but not decoded further.
        public let raw: Data
    }

    public struct Skeleton {
        public let joints: [Joint]
    }

    /// Reads a `numtx_s`-shaped 4x4 float matrix (16 consecutive
    /// `Float32LE`s, row-major -- see this file's own doc comment) at
    /// `base` within `bytes`.
    private static func readMatrix(_ bytes: [UInt8], _ base: Int) -> simd_float4x4 {
        var columns: [SIMD4<Float>] = []
        for row in 0..<4 {
            columns.append(SIMD4(
                leFloat32(bytes, base + row * 16),
                leFloat32(bytes, base + row * 16 + 4),
                leFloat32(bytes, base + row * 16 + 8),
                leFloat32(bytes, base + row * 16 + 12)
            ))
        }
        // `columns` above are really rows (row-major source data); build
        // the matrix from rows directly by transposing simd's column-major
        // constructor input.
        return simd_float4x4(rows: columns)
    }

    private static func leFloat32(_ b: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: leUInt32(b, o))
    }

    /// - Parameter decompressed: one entry's already-decompressed bytes
    ///   (see `WOCCharacterArchiveParser.decode(_:fileURL:)`).
    /// - Throws: ``ParseError/notASkeletonEntry`` if this entry doesn't
    ///   have the confirmed skeleton-entry header shape (most `CHARS.DAT`
    ///   entries are mesh or placeholder entries, not skeletons -- see
    ///   `WOCCharacterArchiveParser`'s doc comment on the three header
    ///   families).
    public static func parseSkeleton(_ decompressed: Data) throws -> Skeleton {
        let bytes = [UInt8](decompressed)
        guard bytes.count >= 56 else { throw ParseError.truncated }
        guard leUInt32(bytes, 0) == UInt32(bytes.count), leUInt32(bytes, 4) == 0, leUInt32(bytes, 12) == 0 else {
            throw ParseError.notASkeletonEntry
        }

        let jointCount = Int(leUInt32(bytes, 24))
        let tableAOffset = Int(leUInt32(bytes, 28))
        guard jointCount > 0, tableAOffset >= 0, tableAOffset + jointCount * 96 <= bytes.count else {
            throw ParseError.truncated
        }
        // See this file's own doc comment: Table B/Table C's real
        // addressing (`tableA + jointCount*96 == tableB`, `tableB +
        // jointCount*64 == tableC`), each a jointCount*64-byte array of
        // real numtx_s matrices.
        let tableBOffset = tableAOffset + jointCount * 96
        let tableCOffset = tableBOffset + jointCount * 64
        guard tableCOffset + jointCount * 64 <= bytes.count else { throw ParseError.truncated }

        var joints: [Joint] = []
        joints.reserveCapacity(jointCount)
        for i in 0..<jointCount {
            let recordBase = tableAOffset + i * 96
            let nameOffset = Int(leUInt32(bytes, recordBase + 76))
            guard nameOffset >= 0, nameOffset < bytes.count else { throw ParseError.truncated }

            var cursor = nameOffset
            var nameBytes: [UInt8] = []
            while cursor < bytes.count, bytes[cursor] != 0 {
                nameBytes.append(bytes[cursor])
                cursor += 1
            }
            let name = String(decoding: nameBytes, as: UTF8.self)
            let parentIndex = Int(Int8(bitPattern: bytes[recordBase + 80]))
            let raw = Data(bytes[recordBase..<(recordBase + 96)])
            let restOrientation = readMatrix(bytes, recordBase)
            let locatorOffset = SIMD3(leFloat32(bytes, recordBase + 64), leFloat32(bytes, recordBase + 68), leFloat32(bytes, recordBase + 72))
            let localBindMatrix = readMatrix(bytes, tableBOffset + i * 64)
            let inverseBindMatrix = readMatrix(bytes, tableCOffset + i * 64)
            joints.append(Joint(
                name: name, parentIndex: parentIndex,
                restOrientation: restOrientation, locatorOffset: locatorOffset,
                localBindMatrix: localBindMatrix, inverseBindMatrix: inverseBindMatrix,
                raw: raw
            ))
        }
        return Skeleton(joints: joints)
    }

    private static func leUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}
