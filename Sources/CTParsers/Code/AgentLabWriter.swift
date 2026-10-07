import Foundation
import CTCore
import CTModels

/// Encodes an AgentLab command's raw `uint32` arguments back to their
/// on-disk form, the inverse of `CustomAgentParser.readCommandChain`'s own
/// per-command argument read loop.
///
/// Argument *count* never changes here, that's fixed by
/// `AgentLabCommandCatalog.commandSize(forID:platform:)`, a property of the
/// command ID itself, not something this write path edits, so this is
/// always a same-size patch: `arguments.count * 4` bytes in, the same out,
/// meant to be written at `AgentLabCommand.fileOffset + 4` (the 4 bytes
/// right after that offset are `internalIndex` itself, which this write
/// path leaves untouched, editing a command's ID or its chain-continuation
/// bit would need real structural surgery this doesn't attempt, same
/// "patch only what's fixed-size and fixed-offset" discipline as every
/// other write path in this app).
public enum AgentLabWriter {
    public static func writeArguments(_ arguments: [UInt32]) -> Data {
        var writer = BinaryWriter()
        for value in arguments {
            writer.writeUInt32(value)
        }
        return writer.data
    }

    /// Full structural re-encode of a `ScriptCommand` chain, the "AgentLab
    /// Phase B" counterpart to `writeArguments`'s same-size patch: this one
    /// can add or remove commands, since the on-disk chain-continuation bit
    /// (`internalIndex & 0x1000000`) is recomputed fresh from the Swift
    /// array's own structure (set on every command but the last) rather than
    /// trusted from each command's own captured bits. `commandID` and
    /// `unkShort` (the reference's own `VTableIndex`/`UnkShort`) are written
    /// back verbatim per command; argument count always comes from
    /// `rawArguments.count` (already the real, per-platform expected size
    /// for that command's ID by construction, this build never lets
    /// `rawArguments` drift out of sync with its own `commandID`).
    public static func encodeCommandChain(_ commands: [AgentLabCommand]) -> Data {
        var writer = BinaryWriter()
        for (index, command) in commands.enumerated() {
            let hasNext = index != commands.count - 1
            var internalIndex = UInt32(command.commandID)
            internalIndex |= UInt32(command.unkShort) << 16
            if hasNext { internalIndex |= 0x0100_0000 }
            writer.writeUInt32(internalIndex)
            for argument in command.rawArguments {
                writer.writeUInt32(argument)
            }
        }
        return writer.data
    }
}
