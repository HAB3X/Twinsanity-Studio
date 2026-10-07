import Foundation
import CTCore
import CTModels

/// Decodes `.ptc`/`.psm`/`.psf` files, standalone font/particle-sprite
/// texture-atlas containers, entirely separate from the `.RM2`/`.SM2`
/// chunk tree (see `TwinsPTCEntry`'s own doc comment). Ported from
/// `Twinsanity/Items/TwinsPTC.cs`/`TwinsPSM.cs`/`TwinsPSF.cs`'s real
/// `Load`, reusing `TextureParser`/`MaterialParser` for the embedded
/// Texture/Material records, the reference's own `Texture.Load`/
/// `Material.Load` calls here are the exact same on-disk shape those two
/// parsers already decode for chunk-tree records, just addressed inline
/// rather than through a section index table.
public enum TwinsPTCParser {
    /// One `TwinsPTC`: `TexID`(4) + `MatID`(4) + a full `Texture` record +
    /// a full `Material` record. `texID`/`matID` double as this entry's
    /// own identifying "record ID" for the embedded parsers, since a
    /// standalone `.ptc`/`.psm`/`.psf` file has no enclosing section index
    /// table to assign one from.
    public static func parseEntry(_ cursor: inout BinaryCursor) throws -> TwinsPTCEntry {
        let texID = try cursor.readUInt32()
        let matID = try cursor.readUInt32()
        let textureFileOffset = cursor.position
        let texture = try TextureParser.parse(&cursor, recordID: texID)
        let textureRecordByteLength = cursor.position - textureFileOffset
        let material = try MaterialParser.parse(&cursor, recordID: matID)
        return TwinsPTCEntry(texID: texID, matID: matID, texture: texture, material: material, textureFileOffset: textureFileOffset, textureRecordByteLength: textureRecordByteLength)
    }

    /// A standalone `.ptc` file, exactly one `TwinsPTCEntry`, nothing else.
    public static func parsePTCFile(_ data: Data) throws -> TwinsPTCEntry {
        var cursor = BinaryCursor(data: data)
        return try parseEntry(&cursor)
    }

    /// A `.psm` file (`TwinsPSM.Load`): entries packed back-to-back with no
    /// count prefix, read until the stream reaches `data`'s own end, the
    /// reference's own `while (Position < startPos + size)` loop, `size`
    /// here being simply `data.count` (a standalone file has no separate
    /// declared "record size" the way a chunk-tree entry does).
    public static func parsePSM(_ data: Data, sourceLabel: String, sourceURL: URL) throws -> TwinsPSMAsset {
        var cursor = BinaryCursor(data: data)
        var entries: [TwinsPTCEntry] = []
        while cursor.position < data.count {
            entries.append(try parseEntry(&cursor))
        }
        return TwinsPSMAsset(sourceLabel: sourceLabel, entries: entries, sourceURL: sourceURL)
    }

    /// A `.psf` file (`TwinsPSF.Load`): `int32` page count, that many
    /// `TwinsPTCEntry` font pages, then `int32` vector count, one more
    /// `int32` (`UnkInt`, real, undocumented, kept for round-tripping),
    /// then that many real `Vector4`s.
    public static func parsePSF(_ data: Data, sourceLabel: String) throws -> TwinsPSFAsset {
        var cursor = BinaryCursor(data: data)
        let pageCount = try cursor.readInt32()
        var fontPages: [TwinsPTCEntry] = []
        fontPages.reserveCapacity(max(0, Int(pageCount)))
        for _ in 0..<max(0, pageCount) {
            fontPages.append(try parseEntry(&cursor))
        }
        let vectorCount = try cursor.readInt32()
        let unkInt = try cursor.readInt32()
        var vectors: [SIMD4<Float>] = []
        vectors.reserveCapacity(max(0, Int(vectorCount)))
        for _ in 0..<max(0, vectorCount) {
            vectors.append(try cursor.readVector4())
        }
        return TwinsPSFAsset(sourceLabel: sourceLabel, fontPages: fontPages, vectors: vectors, unkInt: unkInt)
    }
}
