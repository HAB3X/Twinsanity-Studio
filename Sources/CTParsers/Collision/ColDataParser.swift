import Foundation
import CTCore
import CTModels

/// Decodes a `ColData` record, ported from `Twinsanity/Items/ColData.cs`.
/// Unlike every other leaf this package decodes, `ColData` is a *top-level*
/// (tier 0) raw entry (subID 9 in an `.RM2`/`.RM2Demo`/`.RMX` file), not
/// nested inside a chunk-headered section, see `RM2Parser.buildTopLevelNode`.
public enum ColDataParser {
    /// `Vert1`/`Vert2`/`Vert3` are packed 18 bits each into a `UInt64`,
    /// followed by a 10-bit `Surface`, `18*3 + 10 = 64` bits exactly
    /// (`ColData.cs`'s `mask = 0x3FFFF`, `Save`/`Load`'s bit-shift pattern).
    private static let vertexIndexMask: UInt64 = 0x3FFFF

    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32, size: Int) throws -> CollisionMesh {
        // `ColData.Load`: any record shorter than the 20-byte header is
        // treated as an intentionally empty placeholder, not a parse failure.
        guard size >= 20 else {
            return CollisionMesh(id: recordID, vertices: [], triangles: [], groups: [], triggerBoxes: [])
        }

        _ = try cursor.readUInt32() // someNumber, only gates the reference tool's *write* path, unused here
        let triggerCount = try cursor.readUInt32()
        let groupCount = try cursor.readUInt32()
        let triCount = try cursor.readUInt32()
        let vertexCount = try cursor.readUInt32()

        var triggerBoxes: [CollisionTriggerBox] = []
        triggerBoxes.reserveCapacity(cursor.safeReserveCount(triggerCount, elementSize: 32))
        for _ in 0..<triggerCount {
            let x1 = try cursor.readFloat32()
            let y1 = try cursor.readFloat32()
            let z1 = try cursor.readFloat32()
            let flag1 = try cursor.readInt32()
            let x2 = try cursor.readFloat32()
            let y2 = try cursor.readFloat32()
            let z2 = try cursor.readFloat32()
            let flag2 = try cursor.readInt32()
            triggerBoxes.append(CollisionTriggerBox(min: SIMD3(x1, y1, z1), flag1: flag1, max: SIMD3(x2, y2, z2), flag2: flag2))
        }

        var groups: [CollisionGroup] = []
        groups.reserveCapacity(cursor.safeReserveCount(groupCount, elementSize: 8))
        for _ in 0..<groupCount {
            let groupSize = try cursor.readUInt32()
            let offset = try cursor.readUInt32()
            groups.append(CollisionGroup(size: groupSize, offset: offset))
        }

        var triangles: [CollisionTriangle] = []
        triangles.reserveCapacity(cursor.safeReserveCount(triCount, elementSize: 8))
        for _ in 0..<triCount {
            let packed = try cursor.readUInt64()
            let v1 = Int(packed & vertexIndexMask)
            let v2 = Int((packed >> 18) & vertexIndexMask)
            let v3 = Int((packed >> 36) & vertexIndexMask)
            let surface = Int(packed >> 54)
            triangles.append(CollisionTriangle(vertexIndex1: v1, vertexIndex2: v2, vertexIndex3: v3, surfaceID: surface))
        }

        var vertices: [SIMD4<Float>] = []
        vertices.reserveCapacity(cursor.safeReserveCount(vertexCount, elementSize: 16))
        for _ in 0..<vertexCount {
            vertices.append(try cursor.readVector4())
        }

        return CollisionMesh(id: recordID, vertices: vertices, triangles: triangles, groups: groups, triggerBoxes: triggerBoxes)
    }
}
