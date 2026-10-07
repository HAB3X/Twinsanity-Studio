import Foundation
import CTCore
import CTModels

/// "Cross-Engine Chunk Stitcher" (roadmap 5.3): standalone decoders for
/// *Wrath of Cortex*'s `.CRT`/`.WMP` files, not part of the `.RM2`/`.SM2`
/// chunk-header system the rest of `CTParsers` decodes, since WoC uses a
/// completely different, simpler flat binary layout. See
/// `WOCCrateFile`'s doc comment for the real source this is grounded in
/// and how it was re-verified against real bytes.
public enum WrathOfCortexParser {
    public enum ParseError: Error {
        case truncated
    }

    /// `version:Int32 groupCount:Int16`, then per group (interleaved,
    /// not batched -- the real source's own crate-read loop is nested
    /// inside its group-read loop, so each group's crates are read
    /// immediately after that group's own header, before the next
    /// group's header):
    /// `origin:Vector3 iCrate:Int16 nCrates:Int16 angle:UInt16`, then
    /// `nCrates` crates: `position:Vector3 shadow:Float32
    /// delta:(Int16,Int16,Int16) type:UInt8 [type2,type3,type4:UInt8 if
    /// version>2] neighbors:(Int16 x6) [trigger:Int16 if version>3]`.
    /// `iCrate` (each group's own start index into the file's flat crate
    /// list) isn't needed to decode correctly since crates are read in
    /// file order matching each group's own slice -- kept only
    /// implicitly via `WOCCrateGroup.crates`' own array order.
    public static func parseCrateFile(_ data: Data) throws -> WOCCrateFile {
        var cursor = BinaryCursor(data: data)
        let version = try cursor.readInt32()
        let groupCount = try cursor.readInt16()
        var groups: [WOCCrateGroup] = []
        groups.reserveCapacity(max(0, Int(groupCount)))

        for _ in 0..<max(0, groupCount) {
            let origin = try cursor.readVector3()
            _ = try cursor.readInt16() // iCrate -- this group's own start index into the flat crate list, not needed for in-order decoding
            let crateCount = try cursor.readInt16()
            let angle = try cursor.readUInt16()

            var crates: [WOCCrate] = []
            crates.reserveCapacity(max(0, Int(crateCount)))
            for _ in 0..<max(0, crateCount) {
                let position = try cursor.readVector3()
                let shadow = try cursor.readFloat32()
                let dx = try cursor.readInt16()
                let dy = try cursor.readInt16()
                let dz = try cursor.readInt16()
                let type1 = try cursor.readUInt8()
                var type2: UInt8 = 255, type3: UInt8 = 255, type4: UInt8 = 255
                if version > 2 {
                    type2 = try cursor.readUInt8()
                    type3 = try cursor.readUInt8()
                    type4 = try cursor.readUInt8()
                }
                let neighborUp = try cursor.readInt16()
                let neighborDown = try cursor.readInt16()
                let neighborNorth = try cursor.readInt16()
                let neighborSouth = try cursor.readInt16()
                let neighborEast = try cursor.readInt16()
                let neighborWest = try cursor.readInt16()
                var trigger: Int16 = -1
                if version > 3 {
                    trigger = try cursor.readInt16()
                }
                crates.append(WOCCrate(
                    position: position, shadow: shadow, delta: SIMD3(dx, dy, dz),
                    rawType: type1, type2: type2, type3: type3, type4: type4,
                    neighborUp: neighborUp, neighborDown: neighborDown, neighborNorth: neighborNorth,
                    neighborSouth: neighborSouth, neighborEast: neighborEast, neighborWest: neighborWest,
                    triggerIndex: trigger
                ))
            }
            groups.append(WOCCrateGroup(origin: origin, angle: angle, crates: crates))
        }

        return WOCCrateFile(version: version, groups: groups)
    }

    /// `uint32 count` + `count * Vector3`.
    public static func parseWumpaFile(_ data: Data) throws -> WOCWumpaFile {
        var cursor = BinaryCursor(data: data)
        let count = try cursor.readUInt32()
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(cursor.safeReserveCount(count, elementSize: 12)) // Vector3 = 3 x float32
        for _ in 0..<count { positions.append(try cursor.readVector3()) }
        return WOCWumpaFile(positions: positions)
    }
}
