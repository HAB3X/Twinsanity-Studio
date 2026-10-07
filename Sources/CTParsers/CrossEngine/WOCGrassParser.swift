import Foundation
import CTCore

/// Decoder for WoC `.GRA` files (foliage/grass scatter placements) -- a
/// plain, uncompressed loose file per level, like `.AI`.
///
/// Format, confirmed by exact byte consumption across 4 real files
/// (`CORAL.GRA` 1360B/26 records, `JUNGLE_A.GRA` 3336B/64, `WESTERN.GRA`
/// 1360B/26, all format `A==3`/52-byte records; `VOLCANO.GRA` 404B/9
/// records, format `A==1`/44-byte records):
/// ```
/// File   := formatFlag:UInt32LE(1 or 3) count:UInt32LE Record(count)
/// Record := name:Bytes(16, null-padded ASCII) pad:UInt32LE(==0) value:UInt32LE
///           position:Vector3
///           if formatFlag==1: tail:(Float32, Float32)   -- record is 44 bytes
///           if formatFlag==3: extra:(Float32, UInt32(==1), Float32) -- record is 52 bytes
/// ```
/// `name` is a real plant/foliage type (`"pinkweed"`, `"grass_01"`,
/// `"grass_02"`, `"flowers_02"`, ...) and `position` a world-space scatter
/// placement. `value`'s meaning is unconfirmed (observed varying: 8, 16,
/// 59...). Only one real sample of the `formatFlag==1` variant was found
/// (`VOLCANO.GRA`), so that specific 44-byte layout rests on a single
/// file -- everything about the `formatFlag==3`/52-byte variant is
/// confirmed across 3 independent files.
public enum WOCGrassParser {
    public enum ParseError: Error, Equatable {
        case truncated
        case unsupportedFormat(UInt32)
    }

    public struct Placement {
        public let name: String
        public let value: UInt32
        public let position: SIMD3<Float>
    }

    public static func parse(_ data: Data) throws -> [Placement] {
        var cursor = BinaryCursor(data: data)
        let formatFlag = try cursor.readUInt32()
        let count = try cursor.readUInt32()
        guard formatFlag == 1 || formatFlag == 3 else { throw ParseError.unsupportedFormat(formatFlag) }

        var placements: [Placement] = []
        placements.reserveCapacity(Int(count))
        for _ in 0..<count {
            let nameBytes = try cursor.readBytes(16)
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            _ = try cursor.readUInt32() // pad, confirmed 0
            let value = try cursor.readUInt32()
            let position = try cursor.readVector3()
            if formatFlag == 1 {
                _ = try cursor.readFloat32()
                _ = try cursor.readFloat32()
            } else {
                _ = try cursor.readFloat32()
                _ = try cursor.readUInt32()
                _ = try cursor.readFloat32()
            }
            placements.append(Placement(name: name, value: value, position: position))
        }
        return placements
    }
}
