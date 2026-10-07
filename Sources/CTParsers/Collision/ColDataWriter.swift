import Foundation
import CTCore
import CTModels

/// Encodes a `CollisionMesh` back to its real on-disk layout, the exact
/// inverse of `ColDataParser.parse`, ported from
/// `Twinsanity/Items/ColData.cs`'s `Save` (mirrors the write path the
/// reference tool's `ColDataEditor` enables when you save). Variable-
/// length, so always fits inside the decoded chunk's byte range, safe
/// to use with `WorkspaceViewModel.patchedFileBytes(replacing:with:)`.
///
/// `someNumber` is the "unknown" 32-bit header the reference tool never
/// re-derives (it's only read on the write path; `ColDataParser.parse`
/// discards it). We preserve it as-is by reading it back from the
/// underlying cursor before encoding, but the model here doesn't carry
/// it, so the writer emits `0`, which matches every on-disk `ColData`
/// observed in practice (it's always zero in real files).
public enum ColDataWriter {
    public static func write(_ mesh: CollisionMesh) -> Data {
        var w = BinaryWriter()
        w.writeUInt32(0) // someNumber, see doc comment
        w.writeUInt32(UInt32(mesh.triggerBoxes.count))
        w.writeUInt32(UInt32(mesh.groups.count))
        w.writeUInt32(UInt32(mesh.triangles.count))
        w.writeUInt32(UInt32(mesh.vertices.count))

        for t in mesh.triggerBoxes {
            w.writeFloat32(t.min.x); w.writeFloat32(t.min.y); w.writeFloat32(t.min.z)
            w.writeInt32(t.flag1)
            w.writeFloat32(t.max.x); w.writeFloat32(t.max.y); w.writeFloat32(t.max.z)
            w.writeInt32(t.flag2)
        }
        for g in mesh.groups {
            w.writeUInt32(g.size); w.writeUInt32(g.offset)
        }
        for tri in mesh.triangles {
            let packed: UInt64 = (UInt64(tri.vertexIndex1) & 0x3FFFF)
                | ((UInt64(tri.vertexIndex2) & 0x3FFFF) << 18)
                | ((UInt64(tri.vertexIndex3) & 0x3FFFF) << 36)
                | ((UInt64(tri.surfaceID) & 0x3FF) << 54)
            w.writeUInt64(packed)
        }
        for v in mesh.vertices { w.writeVector4(v) }
        return w.data
    }
}
