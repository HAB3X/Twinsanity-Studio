import Foundation
import CTCore
import CTModels

/// Full byte-exact re-encode of a `CustomAgent`/`CustomAgentX`/
/// `CustomAgentDemo` leaf record (`CodeModel` in the reference source) , 
/// the write-back counterpart to `CustomAgentParser`, needed so
/// `CrossFileGameObjectCopier` can remap each entry's own `scriptID`
/// (a reference into the same Script/Code collection `GameObject.scriptIDs`
/// already needs remapped, same "copy the record graph, don't guess"
/// discipline) rather than only ever copying these raw and unremapped.
/// Ported from `CodeModel.Save` (`Twinsanity/Items/Code/CodeModel.cs`).
public enum CustomAgentWriter {
    /// `CodeModel.Save`: `Header` (`arraySize` recomputed fresh from
    /// `entries.count`, packed into bits 16-23, matching `ArraySize`'s own
    /// setter, every other bit of `headerRaw` preserved verbatim, since
    /// this build has no confirmed meaning for them), then each entry's own
    /// `(scriptCommandsAmount, [ScriptCommand chain], scriptID)`, then the
    /// unconditional trailing chain. `scriptCommandsAmount` is recomputed as
    /// `commands.isEmpty ? 0 : 1`, the reference only ever gates "is there
    /// a chain to read" on this being `> 0`; the actual command count comes
    /// from the chain's own continuation bits (`AgentLabWriter.
    /// encodeCommandChain`), not a separately-trusted counter, same
    /// "recomputed fresh from array structure" discipline `ScriptWriter`
    /// already applies to `ScriptStateBody.commandCount`.
    public static func encode(_ record: CustomAgentRecord) -> Data {
        var writer = BinaryWriter()
        let header = (record.headerRaw & ~UInt32(0xFF0000)) | (UInt32(min(record.entries.count, 0xFF)) << 16)
        writer.writeUInt32(header)
        for entry in record.entries {
            writer.writeInt32(entry.commands.isEmpty ? 0 : 1)
            if !entry.commands.isEmpty {
                writer.writeBytes(AgentLabWriter.encodeCommandChain(entry.commands))
            }
            writer.writeUInt16(entry.scriptID)
        }
        writer.writeBytes(AgentLabWriter.encodeCommandChain(record.finalCommands))
        return writer.data
    }
}
