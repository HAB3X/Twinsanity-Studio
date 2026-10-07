import Foundation
import CTCore
import CTModels

/// Encodes a `CollisionSurfaceInfo` back to its real on-disk layout, the
/// exact inverse of `CollisionSurfaceParser.parse`, ported from
/// `Twinsanity/Items/Instances/CollisionSurface.cs`'s `Save` (mirrors
/// `Editors/SurfaceEditor.cs` in the reference tool). Fixed-size (114
/// bytes): always produces exactly `node.byteSize` bytes for a decoded
/// record, so it's safe to use with `WorkspaceViewModel.patchedFileBytes(
/// replacing:with:)`.
public enum CollisionSurfaceWriter {
    public static func write(_ surface: CollisionSurfaceInfo) -> Data {
        var w = BinaryWriter()
        w.writeUInt32(surface.flags)
        w.writeUInt16(surface.surfaceID)
        w.writeUInt16(surface.sound1)
        w.writeUInt16(surface.sound2)
        w.writeUInt16(surface.particle1)
        w.writeUInt16(surface.particle2)
        w.writeUInt16(surface.sound3)
        w.writeUInt16(surface.sound4)
        w.writeUInt16(surface.particle3)
        w.writeUInt16(surface.sound5)
        w.writeUInt16(surface.sound6)
        w.writeUInt16(surface.paddingRaw)
        w.writeFloat32(surface.unkFloat1)
        w.writeFloat32(surface.unkFloat2)
        w.writeFloat32(surface.unkFloat3)
        w.writeFloat32(surface.unkFloat4)
        w.writeFloat32(surface.unkFloat5)
        w.writeFloat32(surface.unkFloat6)
        w.writeFloat32(surface.unkFloat7)
        w.writeFloat32(surface.unkFloat8)
        w.writeFloat32(surface.unkFloat9)
        w.writeFloat32(surface.unkFloat10)
        w.writeVector4(surface.unkVector)
        w.writeVector4(surface.unkBoundingBox1)
        w.writeVector4(surface.unkBoundingBox2)
        return w.data
    }
}
