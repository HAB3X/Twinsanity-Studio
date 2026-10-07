import Foundation
import CTCore
import CTModels

/// Decodes a `RigidModel` record (`SectionType.rigidModel`/`.mesh`, sub-ID 3 or
/// 6 under `Graphics`), the small link record tying a set of materials and a
/// `Mesh`/`Model` geometry record together. Ported from
/// `Twinsanity/Items/Graphics/RigidModel.cs`.
public enum RigidModelParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> RigidModelInfo {
        let header = try cursor.readUInt32()
        let count = try cursor.readInt32()
        var materialIDs: [UInt32] = []
        materialIDs.reserveCapacity(cursor.safeReserveCount(count, elementSize: 4))
        for _ in 0..<max(0, count) {
            materialIDs.append(try cursor.readUInt32())
        }
        let meshID = try cursor.readUInt32()
        return RigidModelInfo(id: recordID, header: header, materialIDs: materialIDs, meshID: meshID)
    }
}
