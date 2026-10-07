import Foundation
import simd
import CTCore
import CTModels

/// Decodes a `Path` record, ported field-for-field from
/// `Twinsanity/Items/Instances/Path.cs`'s `Load`:
/// `int32 positionCount; Pos[positionCount]; int32 paramCount; PathParam[paramCount]`.
public enum PathParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> PathAsset {
        let positionCount = try cursor.readInt32()
        var positions: [SIMD4<Float>] = []
        positions.reserveCapacity(cursor.safeReserveCount(positionCount, elementSize: 16))
        for _ in 0..<max(0, positionCount) {
            positions.append(try cursor.readVector4())
        }

        let paramCount = try cursor.readInt32()
        var params: [PathAsset.Param] = []
        params.reserveCapacity(cursor.safeReserveCount(paramCount, elementSize: 8))
        for _ in 0..<max(0, paramCount) {
            let p1 = try cursor.readFloat32()
            let p2 = try cursor.readFloat32()
            params.append(PathAsset.Param(p1: p1, p2: p2))
        }

        return PathAsset(id: recordID, positions: positions, params: params)
    }
}
