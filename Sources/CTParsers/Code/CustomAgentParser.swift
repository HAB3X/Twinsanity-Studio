import Foundation
import CTCore
import CTModels

/// Decodes a `CustomAgent`/`CustomAgentX`/`CustomAgentDemo` leaf record , 
/// ported from `Twinsanity.CodeModel`'s `Load` (`Twinsanity/Items/Code/
/// CodeModel.cs` in `github.com/Smartkin/twinsanity-editor`, MIT licensed,
/// same author lineage as `twinsanity-editor-master`). That source's own
/// `CodeModel` nests a type it names `AgentLabAdditions`, confirming this
/// *is* the on-disk format behind this codebase's "AgentLab" roadmap item,
/// not a same-sounding but unrelated system.
///
/// Real layout, exactly as read here:
/// ```
/// uint32 Header                    // arraySize = (Header >> 16) & 0xFF
/// repeat arraySize times:
///     int32  scriptCommandsAmount
///     if scriptCommandsAmount > 0:
///         ScriptCommand chain      // see readCommandChain
///     uint16 scriptId
/// ScriptCommand chain              // unconditional trailing chain
/// ```
/// `ScriptCommand` itself (ported from `Script.MainScript.ScriptCommand.
/// Load`):
/// ```
/// uint32 internalIndex             // commandID = internalIndex & 0xFFFF
/// uint32[argCount] arguments       // argCount from AgentLabCommandCatalog,
///                                   // per-platform, per real commandID
/// if internalIndex & 0x1000000 != 0: another ScriptCommand follows (chained)
/// ```
public enum CustomAgentParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32, platform: AgentLabPlatformVariant) throws -> CustomAgentRecord {
        let header = try cursor.readUInt32()
        let arraySize = Int((header >> 16) & 0xFF)

        var entries: [AgentLabScriptEntry] = []
        entries.reserveCapacity(arraySize)
        for _ in 0..<arraySize {
            let scriptCommandsAmount = try cursor.readInt32()
            let commands: [AgentLabCommand]
            if scriptCommandsAmount > 0 {
                commands = try readCommandChain(&cursor, platform: platform)
            } else {
                commands = []
            }
            let scriptID = try cursor.readUInt16()
            entries.append(AgentLabScriptEntry(scriptID: scriptID, commands: commands))
        }

        let finalCommands = try readCommandChain(&cursor, platform: platform)

        return CustomAgentRecord(recordID: recordID, headerRaw: header, entries: entries, finalCommands: finalCommands)
    }

    /// Reads one `ScriptCommand` and follows its `nextCommand` chain
    /// (`internalIndex & 0x1000000`) iteratively, the reference's own
    /// recursive constructor, flattened to avoid unbounded call-stack depth
    /// on a malformed or hostile chain. A truncated/corrupt chain surfaces
    /// as a thrown `BinaryCursorError` from the underlying cursor read,
    /// same as every other parser in this module, never a silent partial
    /// result.
    ///
    /// Not `private`: `ScriptParser` reads the exact same on-disk
    /// `ScriptCommand` chain format inside `ScriptStateBody` (`Twinsanity.
    /// Script.MainScript.ScriptStateBody.Load`'s `command = new
    /// ScriptCommand(reader, ver)`), so it reuses this rather than
    /// duplicating the loop.
    static func readCommandChain(_ cursor: inout BinaryCursor, platform: AgentLabPlatformVariant) throws -> [AgentLabCommand] {
        var commands: [AgentLabCommand] = []
        while true {
            let offset = cursor.position
            let internalIndex = try cursor.readUInt32()
            let commandID = UInt16(internalIndex & 0xFFFF)
            // The reference's own `UnkShort` (`internalIndex`'s top 16 bits)
            // numerically overlaps the chain-continuation flag (bit 24,
            // `0x1000000`), that bit is handled separately below (`hasNext`,
            // re-derived from chain structure on encode) so it's masked out
            // here to avoid double-applying it.
            let unkShort = UInt16(((internalIndex & 0xFFFF0000) & ~UInt32(0x0100_0000)) >> 16)
            let size = AgentLabCommandCatalog.commandSize(forID: commandID, platform: platform)

            var rawArguments: [UInt32] = []
            if size > 0x0C {
                let argCount = (size - 0x0C) / 4
                rawArguments.reserveCapacity(argCount)
                for _ in 0..<argCount {
                    rawArguments.append(try cursor.readUInt32())
                }
            }

            let name = AgentLabCommandCatalog.commandName(forID: commandID)
            let decoded = AgentLabActionDecoder.decode(commandID: commandID, arguments: rawArguments)
            commands.append(AgentLabCommand(commandID: commandID, unkShort: unkShort, commandName: name, rawArguments: rawArguments, decoded: decoded, fileOffset: offset))

            let hasNext = (internalIndex & 0x1000000) != 0
            if !hasNext { break }
        }
        return commands
    }
}
