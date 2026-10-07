import Foundation
import CTCore
import CTModels

/// Decodes a `GameObject` record (`Object` section, sub-ID 0 under `Code`)
/// in full. Ported from `Twinsanity/Items/Code/GameObject.cs`'s `Load`:
/// ```
/// uint32 UnkBitfield
/// byte[8] ScriptSlots               // derived from the lists below on
///                                    // save, not independently meaningful
///                                    // on load -- not stored
/// int32 nameLength; char[nameLength] Name
/// int32 ui32Count;    uint32[ui32Count]    UI32
/// int32 ogiCount;     uint16[ogiCount]     OGIs
/// int32 animCount;    uint16[animCount]    Anims
/// int32 scriptCount;  uint16[scriptCount]  Scripts
/// int32 objectCount;  uint16[objectCount]  Objects
/// int32 soundCount;   uint16[soundCount]   Sounds
/// if UnkBitfield & 0x20000000:
///     uint32 PHeader; uint32 PUI32
///     int32 flagsCount;   uint32[flagsCount]   instFlagsList
///     int32 floatsCount;  float[floatsCount]   instFloatsList
///     int32 integerCount; uint32[integerCount] instIntegerList
/// if UnkBitfield & 0x40000000:
///     uint32 flag
///     for each of 7 bits (0x01 Objects, 0x02 OGIs, 0x04 Anims, 0x08 CM,
///                         0x10 Scripts, 0x20 Unk, 0x40 Sounds) set in flag:
///         int32 count; uint16[count] ids
/// int32 scriptCommandsAmount
/// if scriptCommandsAmount != 0: ScriptCommand chain (see
///     `CustomAgentParser.readCommandChain` -- same on-disk format)
/// ```
public enum GameObjectParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32, platform: AgentLabPlatformVariant) throws -> GameObjectInfo {
        let unkBitfield = try cursor.readUInt32()
        _ = try cursor.readBytes(8) // ScriptSlots -- derived on save, not independently meaningful

        let nameLength = Int(try cursor.readInt32())
        let name = try cursor.readASCIIString(length: nameLength)

        let ui32Count = try cursor.readInt32()
        var ui32: [UInt32] = []
        ui32.reserveCapacity(cursor.safeReserveCount(ui32Count, elementSize: 4))
        for _ in 0..<max(0, ui32Count) { ui32.append(try cursor.readUInt32()) }

        let ogiCount = try cursor.readInt32()
        var ogiIDs: [UInt32] = []
        ogiIDs.reserveCapacity(cursor.safeReserveCount(ogiCount, elementSize: 2))
        for _ in 0..<max(0, ogiCount) { ogiIDs.append(UInt32(try cursor.readUInt16())) }

        let animIDs = try readUInt16List(&cursor)
        let scriptIDs = try readUInt16List(&cursor)
        let objectIDs = try readUInt16List(&cursor)
        let soundIDs = try readUInt16List(&cursor)

        var instanceProperties: GameObjectInfo.InstanceProperties?
        if unkBitfield & 0x2000_0000 != 0 {
            let pHeader = try cursor.readUInt32()
            let pUI32 = try cursor.readUInt32()

            let flagsCount = try cursor.readInt32()
            var flags: [UInt32] = []
            flags.reserveCapacity(cursor.safeReserveCount(flagsCount, elementSize: 4))
            for _ in 0..<max(0, flagsCount) { flags.append(try cursor.readUInt32()) }

            let floatsCount = try cursor.readInt32()
            var floats: [Float] = []
            floats.reserveCapacity(cursor.safeReserveCount(floatsCount, elementSize: 4))
            for _ in 0..<max(0, floatsCount) { floats.append(try cursor.readFloat32()) }

            let integerCount = try cursor.readInt32()
            var integers: [UInt32] = []
            integers.reserveCapacity(cursor.safeReserveCount(integerCount, elementSize: 4))
            for _ in 0..<max(0, integerCount) { integers.append(try cursor.readUInt32()) }

            instanceProperties = GameObjectInfo.InstanceProperties(pHeader: pHeader, pUI32: pUI32, flags: flags, floats: floats, integers: integers)
        }

        var linkedIDs: GameObjectInfo.LinkedIDs?
        if unkBitfield & 0x4000_0000 != 0 {
            let flag = try cursor.readUInt32()
            let objects = flag & 0x01 != 0 ? try readUInt16List(&cursor) : []
            let ogis = flag & 0x02 != 0 ? try readUInt16List(&cursor) : []
            let anims = flag & 0x04 != 0 ? try readUInt16List(&cursor) : []
            let codeModels = flag & 0x08 != 0 ? try readUInt16List(&cursor) : []
            let scripts = flag & 0x10 != 0 ? try readUInt16List(&cursor) : []
            let unk = flag & 0x20 != 0 ? try readUInt16List(&cursor) : []
            let sounds = flag & 0x40 != 0 ? try readUInt16List(&cursor) : []
            linkedIDs = GameObjectInfo.LinkedIDs(flag: flag, objects: objects, ogis: ogis, anims: anims, codeModels: codeModels, scripts: scripts, unk: unk, sounds: sounds)
        }

        let scriptCommandsAmount = try cursor.readUInt32()
        let scriptCommands: [AgentLabCommand] = scriptCommandsAmount != 0 ? try CustomAgentParser.readCommandChain(&cursor, platform: platform) : []

        return GameObjectInfo(
            id: recordID, name: name, ogiIDs: ogiIDs,
            unkBitfield: unkBitfield, ui32: ui32,
            animIDs: animIDs, scriptIDs: scriptIDs, objectIDs: objectIDs, soundIDs: soundIDs,
            instanceProperties: instanceProperties, linkedIDs: linkedIDs,
            scriptCommands: scriptCommands
        )
    }

    private static func readUInt16List(_ cursor: inout BinaryCursor) throws -> [UInt16] {
        let count = try cursor.readInt32()
        var values: [UInt16] = []
        values.reserveCapacity(cursor.safeReserveCount(count, elementSize: 2))
        for _ in 0..<max(0, count) { values.append(try cursor.readUInt16()) }
        return values
    }
}
