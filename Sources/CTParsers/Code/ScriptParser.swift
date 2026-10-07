import Foundation
import CTCore
import CTModels

/// Decodes a `Script`/`ScriptX`/`ScriptDemo` leaf record, ported field-for-
/// field from `Twinsanity.Script`'s `Load`/`MainScript`/`HeaderScript`/
/// `ScriptState`/`ScriptStateBody`/`ScriptCondition` constructors
/// (`Twinsanity/Items/Code/Script.cs`). See `ScriptAsset`'s doc comment for
/// the model this produces.
///
/// The reference builds `ScriptState`/`ScriptStateBody`/`ScriptCommand`
/// chains via direct recursion in each type's own reader constructor; this
/// port flattens every chain into a loop (same technique, same reasoning,
/// as `CustomAgentParser.readCommandChain` already uses for its identical
/// `ScriptCommand` chain), no unbounded call-stack depth on a malformed or
/// hostile file. A chain with its continuation bit permanently set doesn't
/// loop forever either: each iteration consumes real bytes, so a truncated
/// buffer eventually throws `BinaryCursorError.outOfBounds` and the whole
/// record falls back to `.raw`, same as every other parser here.
public enum ScriptParser {
    public enum ScriptParseError: Error, CustomStringConvertible {
        case negativeRemainder
        case floatOverrideIndexOutOfRange(slot: Int, floatCount: Int)

        public var description: String {
            switch self {
            case .negativeRemainder:
                return "Script record ran past its own declared size while parsing, likely a truncated or corrupt record."
            case .floatOverrideIndexOutOfRange(let slot, let floatCount):
                return "SupportType1 declared a uint32-override slot (\(slot)) outside its own float list (\(floatCount) entries), same condition the reference's own IndexOutOfRangeException guards against."
            }
        }
    }

    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32, size: Int, platform: AgentLabPlatformVariant) throws -> ScriptAsset {
        let startPosition = cursor.position
        let inlineID = try cursor.readUInt16()
        let mask = try cursor.readUInt8()
        let flag = try cursor.readUInt8()

        let content: ScriptContent
        if flag == 0 {
            content = .main(try parseMainScript(&cursor, platform: platform))
        } else {
            content = .header(try parseHeaderScript(&cursor))
        }

        let remaining = (startPosition + size) - cursor.position
        guard remaining >= 0 else { throw ScriptParseError.negativeRemainder }
        let trailingBytes = remaining > 0 ? try cursor.readBytes(remaining) : Data()

        return ScriptAsset(id: recordID, inlineID: inlineID, mask: mask, flag: flag, content: content, trailingBytes: trailingBytes)
    }

    // MARK: - HeaderScript

    private static func parseHeaderScript(_ cursor: inout BinaryCursor) throws -> HeaderScript {
        let count = try cursor.readUInt32()
        let entriesFileOffset = cursor.position
        var entries: [HeaderScript.Entry] = []
        entries.reserveCapacity(cursor.safeReserveCount(count, elementSize: 8))
        for _ in 0..<count {
            let mainScriptIndex = try cursor.readInt32()
            let unkInt2 = try cursor.readUInt32()
            entries.append(HeaderScript.Entry(mainScriptIndex: mainScriptIndex, unkInt2: unkInt2))
        }
        return HeaderScript(entries: entries, entriesFileOffset: entriesFileOffset)
    }

    // MARK: - MainScript

    private static func parseMainScript(_ cursor: inout BinaryCursor, platform: AgentLabPlatformVariant) throws -> MainScript {
        let len = try cursor.readInt32()
        let name = try cursor.readASCIIString(length: Int(len))
        let statesAmountRaw = try cursor.readInt32()
        let startUnit = try cursor.readInt32()

        var states: [ScriptState] = []
        if statesAmountRaw > 0 {
            // Pass 1: the whole ScriptState chain (headers + SupportType1 only).
            states = try readStateChain(&cursor)
            // Pass 2: walk that same chain again, in order, filling in each
            // state's ScriptStateBody chain, exactly where the reference's
            // own `MainScript` constructor reads them (after the full
            // ScriptState chain, not interleaved per-state).
            for i in states.indices where states[i].declaredBodyCount != 0 {
                states[i].bodies = try readStateBodyChain(&cursor, platform: platform)
            }
        }

        return MainScript(name: name, statesAmountRaw: statesAmountRaw, startUnit: startUnit, states: states)
    }

    private static func readStateChain(_ cursor: inout BinaryCursor) throws -> [ScriptState] {
        var result: [ScriptState] = []
        while true {
            let bitfield = try cursor.readInt16()
            let scriptIndexOrSlotFileOffset = cursor.position
            let scriptIndexOrSlot = try cursor.readInt16()
            let type1: SupportType1? = (bitfield & 0x4000) != 0 ? try parseSupportType1(&cursor) : nil
            result.append(ScriptState(bitfieldRaw: bitfield, scriptIndexOrSlot: scriptIndexOrSlot, type1: type1, bodies: [], scriptIndexOrSlotFileOffset: scriptIndexOrSlotFileOffset))
            guard (UInt16(bitPattern: bitfield) & 0x8000) != 0 else { break }
        }
        return result
    }

    private static func readStateBodyChain(_ cursor: inout BinaryCursor, platform: AgentLabPlatformVariant) throws -> [ScriptStateBody] {
        var result: [ScriptStateBody] = []
        while true {
            let bitfield = try cursor.readInt32()
            let scriptStateListIndex: Int32? = (bitfield & 0x400) != 0 ? try cursor.readInt32() : nil
            let condition: ScriptCondition? = (bitfield & 0x200) != 0 ? try parseCondition(&cursor) : nil
            let commands: [AgentLabCommand] = (bitfield & 0xFF) != 0 ? try CustomAgentParser.readCommandChain(&cursor, platform: platform) : []
            result.append(ScriptStateBody(bitfieldRaw: bitfield, scriptStateListIndex: scriptStateListIndex, condition: condition, commands: commands))
            guard (bitfield & 0x800) != 0 else { break }
        }
        return result
    }

    // MARK: - SupportType1

    private static func parseSupportType1(_ cursor: inout BinaryCursor) throws -> SupportType1 {
        let unkByte1 = try cursor.readUInt8() // byte-list count
        let unkByte2 = try cursor.readUInt8() // float-list count
        let unkUShort1 = try cursor.readUInt16()
        let unkInt1RawFileOffset = cursor.position
        let unkInt1Raw = try cursor.readUInt32()

        let beforeFloats = cursor.position
        var floats: [Float] = []
        floats.reserveCapacity(Int(unkByte2))
        for _ in 0..<unkByte2 { floats.append(try cursor.readFloat32()) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(unkByte1))
        for _ in 0..<unkByte1 { bytes.append(try cursor.readUInt8()) }

        // Three specific byte-list slots (int SELECTOR/SYNC_INDEX, int
        // KEY_INDEX/FOCUS_DATA, int JOINT_INDEX) mark a float-list index
        // whose real on-disk value is a uint32's *numeric* value, not an
        // IEEE float bit pattern, the reference re-seeks into the already-
        // read float region and re-reads those 4 bytes as a uint32. (The
        // reference itself has a `// bytes[21] ptr SYNC_UNIT may also need
        // this?` comment questioning a 4th slot, but never implements one , 
        // ported as-is, not extended past what the real code does.)
        for slotIndex in [0, 1, 22] {
            guard bytes.count > slotIndex, bytes[slotIndex] < 128 else { continue }
            let slot = Int(bytes[slotIndex])
            guard slot < floats.count else {
                throw ScriptParseError.floatOverrideIndexOutOfRange(slot: slot, floatCount: floats.count)
            }
            let raw = try cursor.withTemporarySeek(to: beforeFloats + 4 * slot) { c in try c.readUInt32() }
            floats[slot] = Float(raw)
        }
        // `withTemporarySeek` already restores to `afterBytes` after each
        // override read (or the position never left it, if there were no
        // overrides), no explicit re-seek needed.

        return SupportType1(bytes: bytes, floats: floats, unkUShort1: unkUShort1, unkInt1Raw: unkInt1Raw, unkInt1RawFileOffset: unkInt1RawFileOffset)
    }

    // MARK: - ScriptCondition

    private static func parseCondition(_ cursor: inout BinaryCursor) throws -> ScriptCondition {
        let fileOffset = cursor.position
        let unkInt1Raw = try cursor.readInt32()
        let interval = try cursor.readFloat32()
        let threshold = try cursor.readFloat32()
        let thresholdInverse = try cursor.readFloat32()
        return ScriptCondition(unkInt1Raw: unkInt1Raw, interval: interval, threshold: threshold, thresholdInverse: thresholdInverse, fileOffset: fileOffset)
    }
}
