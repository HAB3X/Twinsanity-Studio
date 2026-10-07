import Foundation
import CTCore
import CTModels

/// Decodes a `LodModel` record, ported field-for-field from
/// `Twinsanity/Items/Graphics/LodModel.cs`'s real `Load`.
///
/// Layout:
/// ```
/// uint32 header
/// byte   modelsAmount      // note: a byte, not a uint32, despite the field's type
/// uint32 zero
/// uint32[4] lodDistances
/// uint32[modelsAmount] lodModelIDs
/// ```
public enum LodModelParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> LodModelInfo {
        let header = try cursor.readUInt32()
        let modelsAmount = try cursor.readUInt8()
        _ = try cursor.readUInt32() // zero, unused by the reference reader too

        var lodDistances: [UInt32] = []
        lodDistances.reserveCapacity(4)
        for _ in 0..<4 { lodDistances.append(try cursor.readUInt32()) }

        var lodModelIDs: [UInt32] = []
        lodModelIDs.reserveCapacity(Int(modelsAmount))
        for _ in 0..<Int(modelsAmount) { lodModelIDs.append(try cursor.readUInt32()) }

        return LodModelInfo(id: recordID, header: header, lodDistances: lodDistances, lodModelIDs: lodModelIDs)
    }
}
