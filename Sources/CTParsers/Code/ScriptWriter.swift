import Foundation
import CTCore
import CTModels

/// Write-back for `Script` records, same "capture a fixed-offset field
/// once, patch a same-size range there" discipline as `WorldPlacementWriter`
/// and `AgentLabWriter`. Doesn't attempt a full re-encode of the whole
/// variable-length `Script` record (states/bodies/commands can already be
/// added/removed on the reference side in ways this build hasn't verified
/// a byte-exact `Save()` for), only the specific fields real, verified
/// gameplay mods actually patch: a `ScriptState`'s `scriptIndexOrSlot`
/// (the "redirect this state to a different script/slot" operation
/// CrateModLoader's own cutscene-skip mods perform) and, via the existing
/// `AgentLabWriter`/`AgentLabCommand.fileOffset`, any command's raw
/// arguments, `ScriptStateBody.commands` is the exact same
/// `[AgentLabCommand]` type `CustomAgent` already has real write-back for,
/// so no new writer is needed there at all.
public enum ScriptWriter {
    /// Encodes a `ScriptState.scriptIndexOrSlot` back to its on-disk 2-byte
    /// form, meant to be patched at `ScriptState.scriptIndexOrSlotFileOffset`.
    public static func writeScriptIndexOrSlot(_ value: Int16) -> Data {
        var writer = BinaryWriter()
        writer.writeInt16(value)
        return writer.data
    }

    /// Encodes one `HeaderScript.Entry` back to its on-disk 8-byte form
    /// (`Int32` `mainScriptIndex` then `UInt32` `unkInt2`), meant to be
    /// patched at `HeaderScript.entriesFileOffset + index * 8`.
    public static func writeHeaderScriptEntry(mainScriptIndex: Int32, unkInt2: UInt32) -> Data {
        var writer = BinaryWriter()
        writer.writeInt32(mainScriptIndex)
        writer.writeUInt32(unkInt2)
        return writer.data
    }

    /// Encodes `SupportType1.unkInt1Raw` back to its on-disk 4-byte form,
    /// meant to be patched at `SupportType1.unkInt1RawFileOffset`, makes
    /// every `resolved*`/flag accessor on that type (space, motion,
    /// continuous-rotate, translates/rotates/tracksDestination/etc.)
    /// writable without touching the variable-length `bytes`/`floats`
    /// lists that follow it in the same record.
    public static func writeSupportType1UnkInt1Raw(_ value: UInt32) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(value)
        return writer.data
    }

    /// Encodes a full `ScriptCondition` back to its on-disk 16-byte form
    /// (`unkInt1Raw`, `interval`, `threshold`, `thresholdInverse`, 4 bytes
    /// each, in that exact sequential order), meant to be patched at
    /// `ScriptCondition.fileOffset`, one patch covers all four fields
    /// (including `vTableIndex`/`parameter`/`notGate`, which are just
    /// `unkInt1Raw`'s own packed bits) since they're already contiguous
    /// and always rewritten together.
    public static func writeCondition(_ condition: ScriptCondition) -> Data {
        var writer = BinaryWriter()
        writer.writeInt32(condition.unkInt1Raw)
        writer.writeFloat32(condition.interval)
        writer.writeFloat32(condition.threshold)
        writer.writeFloat32(condition.thresholdInverse)
        return writer.data
    }

    // MARK: - Phase B: full structural re-encode

    /// Full byte-exact re-encode of an entire `Script`/`ScriptX`/`ScriptDemo`
    /// leaf record, the "AgentLab Phase B" counterpart to every
    /// fixed-offset patch above: this one can add or remove `ScriptState`s,
    /// `ScriptStateBody`s, `ScriptCommand`s, and create/delete a
    /// `ScriptCondition`, because every chain-continuation/presence bit is
    /// recomputed fresh from the Swift model's own array/optional structure
    /// rather than trusted from originally-captured bits, ported field-for-
    /// field from `Script.Save`/`MainScript.Write`/`HeaderScript.Write`/
    /// `ScriptState.Write`/`ScriptStateBody.Write`/`SupportType1.Write`
    /// (`Twinsanity/Items/Code/Script.cs`). Meant to *replace* the whole
    /// on-disk record (via `ChunkSectionInserter`'s remove-then-insert-same-
    /// id path), not to patch a subrange, unlike this file's other
    /// `write*` functions, the result generally isn't the same length as
    /// the original record.
    public static func encode(_ script: ScriptAsset) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt16(script.inlineID)
        writer.writeUInt8(script.mask)
        writer.writeUInt8(script.flag)
        switch script.content {
        case .main(let main):
            writer.writeBytes(encodeMainScript(main))
        case .header(let header):
            writer.writeBytes(encodeHeaderScript(header))
        }
        writer.writeBytes(script.trailingBytes)
        return writer.data
    }

    /// `HeaderScript.Write`: `Int32` pair count, then each `(mainScriptIndex:
    /// Int32, unkInt2: UInt32)` pair, 8 bytes each, in array order. Count
    /// is always `entries.count`, recomputed fresh (never a stored value),
    /// matching the reference writing `pairs.Count` directly.
    static func encodeHeaderScript(_ header: HeaderScript) -> Data {
        var writer = BinaryWriter()
        writer.writeInt32(Int32(header.entries.count))
        for entry in header.entries {
            writer.writeInt32(entry.mainScriptIndex)
            writer.writeUInt32(entry.unkInt2)
        }
        return writer.data
    }

    /// `MainScript.Write`: name length + chars, `GetStatesAmount()` (always
    /// `states.count`, walked fresh, the reference never trusts a stored
    /// count either), `StartUnit`, the full flattened `ScriptState` chain
    /// (headers + `SupportType1` only), then a second pass over that same
    /// chain in order writing each state's own `ScriptStateBody` chain when
    /// it has one, exactly the reference's own two-pass write order (see
    /// `Script.cs`'s `MainScript.Write`), not interleaved per-state.
    static func encodeMainScript(_ main: MainScript) -> Data {
        var writer = BinaryWriter()
        writer.writeInt32(Int32(main.name.utf8.count))
        writer.writeASCIIString(main.name)
        writer.writeInt32(Int32(main.states.count))
        writer.writeInt32(main.startUnit)

        for (index, state) in main.states.enumerated() {
            let hasNext = index != main.states.count - 1
            writer.writeBytes(encodeState(state, hasNext: hasNext))
        }
        for state in main.states where !state.bodies.isEmpty {
            writer.writeBytes(encodeBodyChain(state.bodies))
        }
        return writer.data
    }

    /// `ScriptState.Write`: recomputed `bitfield` (0x8000 chain-continuation
    /// from `hasNext`, 0x4000 `SupportType1` presence from `type1 != nil`,
    /// low 5 bits `scriptStateBodyCount` from `bodies.count`, see
    /// `ScriptState.scriptStateBodyCount`'s setter, every other bit, e.g.
    /// 0x1000 `IsSlot`, preserved verbatim from `bitfieldRaw`), then
    /// `scriptIndexOrSlot`, then `SupportType1` when present. Does *not*
    /// recurse into `nextState`/the body chain, `encodeMainScript` walks
    /// the flattened arrays itself, matching the reference's own recursive
    /// `Write` byte-for-byte without needing recursion here.
    static func encodeState(_ state: ScriptState, hasNext: Bool) -> Data {
        var writer = BinaryWriter()
        var bits = UInt16(bitPattern: state.bitfieldRaw)
        bits &= ~UInt16(0x1F)
        bits &= ~UInt16(0x4000)
        bits &= ~UInt16(0x8000)
        bits |= UInt16(min(state.bodies.count, 0x1F))
        if state.type1 != nil { bits |= 0x4000 }
        if hasNext { bits |= 0x8000 }
        writer.writeInt16(Int16(bitPattern: bits))
        writer.writeInt16(state.scriptIndexOrSlot)
        if let type1 = state.type1 {
            writer.writeBytes(encodeSupportType1(type1))
        }
        return writer.data
    }

    /// `SupportType1.Write`: byte-list/float-list counts (`bytes.count`,
    /// `floats.count`, each must fit a `UInt8`), `unkUShort1`, `unkInt1Raw`,
    /// then every float, written as its raw numeric value reinterpreted as
    /// a `UInt32` for the three specific slots (`bytes[0]`, `bytes[1]`,
    /// `bytes[22]`, when that byte's *value* equals the current float
    /// index) the reference's own reader re-seeks and re-reads that way,
    /// an ordinary IEEE `Float32` otherwise, then the raw byte list.
    /// Ported from the reference's own `Write`, which searches for a
    /// matching byte value per float index rather than checking the three
    /// slots directly; that's algebraically the same lookup, done here by
    /// reading `bytes[0]`/`bytes[1]`/`bytes[22]` directly since Swift
    /// already has them at hand in O(1) instead of an O(n) scan.
    static func encodeSupportType1(_ type1: SupportType1) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt8(UInt8(clamping: type1.bytes.count))
        writer.writeUInt8(UInt8(clamping: type1.floats.count))
        writer.writeUInt16(type1.unkUShort1)
        writer.writeUInt32(type1.unkInt1Raw)

        // Real bug fix: `ScriptParser.parseSupportType1` only treats one of
        // these three slots as a float override when that byte's own
        // *value* is `< 128` (`guard bytes.count > slotIndex, bytes[slotIndex]
        // < 128 else { continue }`), this set was missing that same
        // check, so a byte value >= 128 (a real, valid byte, bytes are
        // arbitrary 0-255 data, not all override indices) got treated as
        // an override slot here even though the parser never would have.
        // With enough floats for that slot to exist, this wrote a plain
        // IEEE float via `UInt32(value)`, which traps on any
        // negative/NaN value and silently corrupts the round-trip
        // otherwise.
        let overrideSlots: Set<Int> = [
            type1.bytes.count > 0 && type1.bytes[0] < 128 ? Int(type1.bytes[0]) : -1,
            type1.bytes.count > 1 && type1.bytes[1] < 128 ? Int(type1.bytes[1]) : -1,
            type1.bytes.count > 22 && type1.bytes[22] < 128 ? Int(type1.bytes[22]) : -1
        ]
        for (index, value) in type1.floats.enumerated() {
            if overrideSlots.contains(index) {
                writer.writeUInt32(UInt32(value))
            } else {
                writer.writeFloat32(value)
            }
        }
        for byte in type1.bytes {
            writer.writeUInt8(byte)
        }
        return writer.data
    }

    /// `ScriptStateBody.Write`, applied over the whole flattened
    /// `[ScriptStateBody]` array, 0x800 chain-continuation recomputed per
    /// element from array position (set on every body but the last).
    static func encodeBodyChain(_ bodies: [ScriptStateBody]) -> Data {
        var writer = BinaryWriter()
        for (index, body) in bodies.enumerated() {
            let hasNext = index != bodies.count - 1
            writer.writeBytes(encodeBody(body, hasNext: hasNext))
        }
        return writer.data
    }

    /// One `ScriptStateBody`'s own bytes: recomputed `bitfield` (0x400
    /// `scriptStateListIndex` presence, 0x200 `condition` presence, low
    /// byte `commandCount` from `commands.count`, see
    /// `ScriptStateBody.commandCount`'s setter, which `AddCommand`/
    /// `DeleteCommand` keep in lock-step with the real chain length, 0x800
    /// chain-continuation from `hasNext`; every other bit preserved
    /// verbatim from `bitfieldRaw`), then each present optional field in
    /// on-disk order, then the command chain via `AgentLabWriter.
    /// encodeCommandChain` when `commands` is non-empty.
    static func encodeBody(_ body: ScriptStateBody, hasNext: Bool) -> Data {
        var writer = BinaryWriter()
        var bits = UInt32(bitPattern: body.bitfieldRaw)
        bits &= ~UInt32(0xFF)
        bits &= ~UInt32(0x200)
        bits &= ~UInt32(0x400)
        bits &= ~UInt32(0x800)
        bits |= UInt32(min(body.commands.count, 0xFF))
        if body.scriptStateListIndex != nil { bits |= 0x400 }
        if body.condition != nil { bits |= 0x200 }
        if hasNext { bits |= 0x800 }
        writer.writeInt32(Int32(bitPattern: bits))
        if let scriptStateListIndex = body.scriptStateListIndex {
            writer.writeInt32(scriptStateListIndex)
        }
        if let condition = body.condition {
            writer.writeBytes(writeCondition(condition))
        }
        if !body.commands.isEmpty {
            writer.writeBytes(AgentLabWriter.encodeCommandChain(body.commands))
        }
        return writer.data
    }
}
