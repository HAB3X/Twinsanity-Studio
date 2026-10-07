import Foundation
import CTCore
import CTModels

/// Full byte-exact re-encode of a `GameObject` record, "Parity Phase D",
/// ported field-for-field from `GameObject.Save`/`UpdateSlots`/`updateFlag`
/// (`Twinsanity/Items/Code/GameObject.cs`). Same "recompute every derived
/// field from the Swift model's own array/optional structure" discipline
/// `ScriptWriter.encode` established for Phase B, `ScriptSlots` (8 bytes),
/// `InstanceProperties.pHeader`, and `LinkedIDs.flag` are never trusted from
/// their own captured values, always rebuilt from the real list counts, so
/// this can add/remove list entries and it's still correct. Meant to
/// *replace* the whole on-disk record (via `WorkspaceViewModel.
/// patchedFileBytes(replacingWholeRecord:with:)`, the same whole-record
/// replace path Phase B built), not to patch a subrange.
public enum GameObjectWriter {
    public static func encode(_ gameObject: GameObjectInfo) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(gameObject.unkBitfield)

        // `UpdateSlots`: [OGIs.Count, Scripts.Count, Objects.Count,
        // UI32.Count, Sounds.Count, 0, 0, 0], each clamped to a byte , 
        // real game files never exceed 255 of any of these, but a byte
        // overflow here should clamp, not silently wrap.
        let scriptSlots: [UInt8] = [
            UInt8(clamping: gameObject.ogiIDs.count),
            UInt8(clamping: gameObject.scriptIDs.count),
            UInt8(clamping: gameObject.objectIDs.count),
            UInt8(clamping: gameObject.ui32.count),
            UInt8(clamping: gameObject.soundIDs.count),
            0, 0, 0
        ]
        for slot in scriptSlots { writer.writeUInt8(slot) }

        writer.writeInt32(Int32(gameObject.name.utf8.count))
        writer.writeASCIIString(gameObject.name)

        writer.writeInt32(Int32(gameObject.ui32.count))
        for value in gameObject.ui32 { writer.writeUInt32(value) }

        writer.writeInt32(Int32(gameObject.ogiIDs.count))
        for value in gameObject.ogiIDs { writer.writeUInt16(UInt16(truncatingIfNeeded: value)) }

        writeUInt16List(&writer, gameObject.animIDs)
        writeUInt16List(&writer, gameObject.scriptIDs)
        writeUInt16List(&writer, gameObject.objectIDs)
        writeUInt16List(&writer, gameObject.soundIDs)

        if gameObject.unkBitfield & 0x2000_0000 != 0, let properties = gameObject.instanceProperties {
            // `PHeader = byte flags.Count | floats.Count << 8 | integers.Count << 16`
            let pHeader = UInt32(UInt8(clamping: properties.flags.count))
                | (UInt32(clamping: properties.floats.count) << 8)
                | (UInt32(clamping: properties.integers.count) << 16)
            writer.writeUInt32(pHeader)
            writer.writeUInt32(properties.pUI32)

            writer.writeInt32(Int32(properties.flags.count))
            for value in properties.flags { writer.writeUInt32(value) }
            writer.writeInt32(Int32(properties.floats.count))
            for value in properties.floats { writer.writeFloat32(value) }
            writer.writeInt32(Int32(properties.integers.count))
            for value in properties.integers { writer.writeUInt32(value) }
        }

        if gameObject.unkBitfield & 0x4000_0000 != 0, let linked = gameObject.linkedIDs {
            // `updateFlag`: one bit per list, set only when that list is non-empty.
            var flag: UInt32 = 0
            if !linked.objects.isEmpty { flag |= 0x01 }
            if !linked.ogis.isEmpty { flag |= 0x02 }
            if !linked.anims.isEmpty { flag |= 0x04 }
            if !linked.codeModels.isEmpty { flag |= 0x08 }
            if !linked.scripts.isEmpty { flag |= 0x10 }
            if !linked.unk.isEmpty { flag |= 0x20 }
            if !linked.sounds.isEmpty { flag |= 0x40 }
            writer.writeUInt32(flag)

            if flag & 0x01 != 0 { writeUInt16List(&writer, linked.objects) }
            if flag & 0x02 != 0 { writeUInt16List(&writer, linked.ogis) }
            if flag & 0x04 != 0 { writeUInt16List(&writer, linked.anims) }
            if flag & 0x08 != 0 { writeUInt16List(&writer, linked.codeModels) }
            if flag & 0x10 != 0 { writeUInt16List(&writer, linked.scripts) }
            if flag & 0x20 != 0 { writeUInt16List(&writer, linked.unk) }
            if flag & 0x40 != 0 { writeUInt16List(&writer, linked.sounds) }
        }

        // `scriptCommandsAmount` is written verbatim by the reference (kept
        // in sync by its own Add/DeleteCommand handlers, not recomputed in
        // Save), deriving it fresh from `scriptCommands.count` here is
        // equivalent for any record this build itself wrote, and self-
        // corrects a mismatched stored value instead of propagating one.
        writer.writeInt32(Int32(gameObject.scriptCommands.count))
        if !gameObject.scriptCommands.isEmpty {
            writer.writeBytes(AgentLabWriter.encodeCommandChain(gameObject.scriptCommands))
        }

        return writer.data
    }

    private static func writeUInt16List(_ writer: inout BinaryWriter, _ values: [UInt16]) {
        writer.writeInt32(Int32(values.count))
        for value in values { writer.writeUInt16(value) }
    }
}
