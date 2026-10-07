import Foundation
import CTCore

/// Decoder for WoC `.AI` files -- one per level, sitting alongside the
/// RNC-compressed `.GSC` (already decoded by `WOCContainerParser`) as a
/// **plain, uncompressed** loose file. Unlike `.GSC`'s formats, this one
/// was reverse-engineered directly from files on the real mounted disc
/// (no RNC layer to strip first).
///
/// Format, fully confirmed by exact byte consumption (`consumed ==
/// fileSize`, not just "close") across 4 real files of very different
/// sizes (`FARM.AI` 36 bytes/1 entry, `GARDEN.AI` 1996 bytes/51 entries,
/// `CASTLE_C.AI` 1360 bytes/39 entries, `WESTERN.AI` 2348 bytes/56
/// entries):
/// ```
/// File  := entryCount:UInt32LE Entry*
/// Entry := name:Bytes(16, null-padded ASCII) waypointCount:UInt32LE Vector3(waypointCount)
/// ```
/// `name` is a real enemy/AI entity type (`"bat"`, `"knight"`, `"wizard"`,
/// `"scorpion"`, `"koi carp"`, `"flying clock"`, ...), repeated once per
/// placed instance of that type, and the trailing `Vector3` list reads as
/// a patrol waypoint path (a single-entry list is presumably just that
/// entity's spawn point, no patrol).
public enum WOCAIParser {
    public enum ParseError: Error, Equatable {
        case truncated
    }

    public struct Entity {
        public let name: String
        public let waypoints: [SIMD3<Float>]
    }

    public static func parse(_ data: Data) throws -> [Entity] {
        var cursor = BinaryCursor(data: data)
        let count = try cursor.readUInt32()
        var entities: [Entity] = []
        entities.reserveCapacity(Int(count))
        for _ in 0..<count {
            let nameBytes = try cursor.readBytes(16)
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            let waypointCount = try cursor.readUInt32()
            var waypoints: [SIMD3<Float>] = []
            waypoints.reserveCapacity(Int(waypointCount))
            for _ in 0..<waypointCount { waypoints.append(try cursor.readVector3()) }
            entities.append(Entity(name: name, waypoints: waypoints))
        }
        return entities
    }
}
