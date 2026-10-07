import Foundation
import CTCore
import CTModels

/// Decodes a `CollisionSurface` record, ported field-for-field from
/// `Twinsanity/Items/Instances/CollisionSurface.cs`'s `Load` (114 bytes,
/// fixed size, no counted lists). The physical-property companion to
/// `ColData`'s `CollisionTriangle.surfaceID` (see `CollisionSurfaceInfo`'s
/// doc comment for how the two cross-reference).
public enum CollisionSurfaceParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> CollisionSurfaceInfo {
        let flags = try cursor.readUInt32()
        let surfaceID = try cursor.readUInt16()
        let sound1 = try cursor.readUInt16()
        let sound2 = try cursor.readUInt16()
        let particle1 = try cursor.readUInt16()
        let particle2 = try cursor.readUInt16()
        let sound3 = try cursor.readUInt16()
        let sound4 = try cursor.readUInt16()
        let particle3 = try cursor.readUInt16()
        let sound5 = try cursor.readUInt16()
        let sound6 = try cursor.readUInt16()
        let paddingRaw = try cursor.readUInt16() // real on-disk padding, not read by the game itself either, kept for exact write-back round trips
        let unkFloat1 = try cursor.readFloat32()
        let unkFloat2 = try cursor.readFloat32()
        let unkFloat3 = try cursor.readFloat32()
        let unkFloat4 = try cursor.readFloat32()
        let unkFloat5 = try cursor.readFloat32()
        let unkFloat6 = try cursor.readFloat32()
        let unkFloat7 = try cursor.readFloat32()
        let unkFloat8 = try cursor.readFloat32()
        let unkFloat9 = try cursor.readFloat32()
        let unkFloat10 = try cursor.readFloat32()
        let unkVector = try cursor.readVector4()
        let unkBoundingBox1 = try cursor.readVector4()
        let unkBoundingBox2 = try cursor.readVector4()

        return CollisionSurfaceInfo(
            id: recordID, surfaceID: surfaceID, flags: flags,
            sound1: sound1, sound2: sound2, particle1: particle1, particle2: particle2,
            sound3: sound3, sound4: sound4, particle3: particle3, sound5: sound5, sound6: sound6, paddingRaw: paddingRaw,
            unkFloat1: unkFloat1, unkFloat2: unkFloat2, unkFloat3: unkFloat3, unkFloat4: unkFloat4, unkFloat5: unkFloat5,
            unkFloat6: unkFloat6, unkFloat7: unkFloat7, unkFloat8: unkFloat8, unkFloat9: unkFloat9, unkFloat10: unkFloat10,
            unkVector: unkVector, unkBoundingBox1: unkBoundingBox1, unkBoundingBox2: unkBoundingBox2
        )
    }
}
