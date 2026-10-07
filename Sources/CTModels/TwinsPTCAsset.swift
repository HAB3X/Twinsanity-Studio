import Foundation
import simd

/// A decoded `TwinsPTC` entry, a texture+material pair embedded *inline*
/// (not by chunk-tree ID reference) inside a `.ptc`/`.psm`/`.psf` file.
/// Ported from `Twinsanity/Items/TwinsPTC.cs`'s real `Load`/`Save`: `TexID`/
/// `MatID` are real on-disk IDs for this pair, followed immediately by a
/// full `Texture` record and a full `Material` record, the exact same
/// on-disk shape `TextureParser`/`MaterialParser` already decode for
/// chunk-tree records, just not addressed by a section index table here.
public struct TwinsPTCEntry: Sendable, Identifiable {
    public var id: UInt32 { texID }
    public var texID: UInt32
    public var matID: UInt32
    public var texture: TextureAsset
    public var material: MaterialInfo
    /// Byte offset (relative to the start of the standalone `.ptc`/`.psm`/
    /// `.psf` file this entry was parsed from) of this entry's `Texture`
    /// record, right after `texID`/`matID`, where `TextureParser.parse`
    /// itself starts reading. Captured during parse the same way
    /// `PlacedCamera.fixedFieldsFileOffset` is, so a "PSM Editor" write-back
    /// can patch just this record's bytes in place without needing to
    /// reconstruct the whole container.
    public var textureFileOffset: Int
    /// How many bytes `TextureParser.parse` actually consumed for this
    /// entry's `Texture` record, the record's own self-describing length,
    /// captured (not assumed) so a patch always replaces exactly the bytes
    /// the original record occupied, never more or fewer.
    public var textureRecordByteLength: Int

    public init(texID: UInt32, matID: UInt32, texture: TextureAsset, material: MaterialInfo, textureFileOffset: Int = 0, textureRecordByteLength: Int = 0) {
        self.texID = texID
        self.matID = matID
        self.texture = texture
        self.material = material
        self.textureFileOffset = textureFileOffset
        self.textureRecordByteLength = textureRecordByteLength
    }
}

/// A decoded `.psm` file (`Twinsanity/Items/TwinsPSM.cs`), a flat sequence
/// of `TwinsPTCEntry` packed back-to-back with no count prefix at all;
/// `Load` just keeps reading entries until the stream position reaches the
/// file's own byte length. The reference's `PSMWorker` browses/edits these
/// as a texture-atlas sheet (its own "8-segment 512×512" UI framing is
/// about how it *displays* a `.psm`'s entries, not part of this on-disk
/// shape).
public struct TwinsPSMAsset: Sendable, Identifiable {
    public var id: String { sourceLabel }
    public var sourceLabel: String
    public var entries: [TwinsPTCEntry]
    /// Where this file actually lives on disk -- needed (unlike the
    /// `ChunkNode`-based chunk-tree formats, which look this up via
    /// `WorkspaceViewModel.rawBytes(for:)`) because a standalone `.ptc`/
    /// `.psm` file has no `ChunkNode` of its own to key off of. A "PSM
    /// Editor" write-back re-reads fresh bytes from here, patches one
    /// entry's `Texture` record via `textureFileOffset`/
    /// `textureRecordByteLength`, and always saves to a *new* location --
    /// this URL is never written back to, same convention as every other
    /// edit path in this app.
    public var sourceURL: URL

    public init(sourceLabel: String, entries: [TwinsPTCEntry], sourceURL: URL) {
        self.sourceLabel = sourceLabel
        self.entries = entries
        self.sourceURL = sourceURL
    }
}

/// A decoded `.psf` file (`Twinsanity/Items/TwinsPSF.cs`), a real font
/// container: a count-prefixed list of `TwinsPTCEntry` "font pages" (the
/// rendered glyph-sheet textures), then a separate count-prefixed list of
/// real `Vector4`s (per-glyph metrics, advance width/UV rect, unconfirmed
/// exact meaning; kept for round-tripping, not interpreted), plus one
/// genuinely undocumented `int32`.
public struct TwinsPSFAsset: Sendable, Identifiable {
    public var id: String { sourceLabel }
    public var sourceLabel: String
    public var fontPages: [TwinsPTCEntry]
    public var vectors: [SIMD4<Float>]
    public var unkInt: Int32

    public init(sourceLabel: String, fontPages: [TwinsPTCEntry], vectors: [SIMD4<Float>], unkInt: Int32) {
        self.sourceLabel = sourceLabel
        self.fontPages = fontPages
        self.vectors = vectors
        self.unkInt = unkInt
    }
}
