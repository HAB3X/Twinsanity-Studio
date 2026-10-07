import Foundation
import CTCore
import CTModels

/// Decodes `AIPosition`/`AIPath` records, ported field-for-field from
/// `Twinsanity/Items/Instances/AIPosition.cs` and `AIPath.cs`.
public enum AINavigationParser {
    /// `Pos` (4 floats: X, Y, Z, W) + `Num` (uint16) = 18 bytes.
    public static func parseAIPosition(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> AIPositionMarker {
        let position = try cursor.readVector4()
        let num = try cursor.readUInt16()
        return AIPositionMarker(id: recordID, position: position, rawNodeType: num)
    }

    /// 5 x uint16 = 10 bytes.
    public static func parseAIPath(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> AIPathRecord {
        var args: [UInt16] = []
        args.reserveCapacity(5)
        for _ in 0..<5 { args.append(try cursor.readUInt16()) }
        return AIPathRecord(id: recordID, args: args)
    }
}
