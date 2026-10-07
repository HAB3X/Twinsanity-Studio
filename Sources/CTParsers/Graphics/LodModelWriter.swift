import Foundation
import CTCore
import CTModels

/// Encodes a `LodModelInfo` back to its real on-disk layout, the exact
/// inverse of `LodModelParser.parse`, ported from `Twinsanity/Items/
/// Graphics/LodModel.cs`'s `Save` (mirrors `Editors/LodEditor.cs` in the
/// reference tool). Variable-length: the emitted byte count is always
/// `21 + 4 * lodModelIDs.count`, which can legitimately differ from the
/// decoded record's original size once `LodModelEditorSheet` lets
/// `lodModelIDs` grow/shrink, use `WorkspaceViewModel.patchedFileBytes
/// (replacingWholeRecord:with:)` for that, not the fixed-size
/// `patchedFileBytes(replacing:with:)`.
///
/// `modelsAmount` (a byte on disk, never a UInt32) is always derived from
/// `lodModelIDs.count` here, mirroring the reference reader's own
/// convention, a manually-set `modelsAmount` that disagrees with
/// `lodModelIDs.count` would only ever confuse the parser, so we never
/// allow it.
public enum LodModelWriter {
    public static func write(_ lod: LodModelInfo) -> Data {
        var w = BinaryWriter()
        w.writeUInt32(lod.header)
        w.writeUInt8(UInt8(lod.lodModelIDs.count))
        w.writeUInt32(0) // zero, unused on read, see `LodModelParser`
        for d in lod.lodDistances { w.writeUInt32(d) }
        for id in lod.lodModelIDs { w.writeUInt32(id) }
        return w.data
    }
}
