import Foundation
import CTCore
import CTModels

/// Decodes a `Skydome` record, ported field-for-field from
/// `Twinsanity/Items/Graphics/Skydome.cs`'s `Load` (`uint32 Unknown` +
/// `int32 count` + `uint32[count] MeshIDs`).
public enum SkydomeParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> SkydomeInfo {
        let unknown = try cursor.readUInt32()
        let count = try cursor.readInt32()
        var meshIDs: [UInt32] = []
        meshIDs.reserveCapacity(cursor.safeReserveCount(count, elementSize: 4))
        for _ in 0..<max(0, count) {
            meshIDs.append(try cursor.readUInt32())
        }
        return SkydomeInfo(id: recordID, unknown: unknown, meshIDs: meshIDs)
    }
}
