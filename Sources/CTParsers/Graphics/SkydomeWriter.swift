import Foundation
import CTCore
import CTModels

/// Encodes a `SkydomeInfo` back to its real on-disk layout, the exact
/// inverse of `SkydomeParser.parse` (mirrors `Editors/SkydomeEditor.cs` in
/// the reference tool). Only safe to use with `WorkspaceViewModel.
/// patchedFileBytes(replacing:with:)` when `meshIDs.count` is unchanged
/// from the decoded record, that keeps the encoded size equal to
/// `node.byteSize`, which that save path requires.
public enum SkydomeWriter {
    public static func write(_ skydome: SkydomeInfo) -> Data {
        var w = BinaryWriter()
        w.writeUInt32(skydome.unknown)
        w.writeInt32(Int32(skydome.meshIDs.count))
        for meshID in skydome.meshIDs {
            w.writeUInt32(meshID)
        }
        return w.data
    }
}
