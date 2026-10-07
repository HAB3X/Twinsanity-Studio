import Foundation
import CTCore
import CTModels

/// Encodes a `PathAsset` back to its real on-disk layout, the exact
/// inverse of `PathParser.parse` (mirrors `Editors/PathEditor.cs` in the
/// reference tool). `positions.count`/`params.count` may differ from the
/// decoded record (adding/removing points or params), use
/// `WorkspaceViewModel.patchedFileBytes(replacingWholeRecord:with:)` in
/// that case, since this record's on-disk size then changes; the
/// fixed-size `patchedFileBytes(replacing:with:)` only works when both
/// counts stay exactly what they were.
public enum PathWriter {
    public static func write(_ path: PathAsset) -> Data {
        var w = BinaryWriter()
        w.writeInt32(Int32(path.positions.count))
        for position in path.positions {
            w.writeVector4(position)
        }
        w.writeInt32(Int32(path.params.count))
        for param in path.params {
            w.writeFloat32(param.p1)
            w.writeFloat32(param.p2)
        }
        return w.data
    }
}
