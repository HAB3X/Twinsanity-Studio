import Foundation

/// One decoded command from a `CustomAgent`/`GameObject` script-command chain.
/// Ported from `Twinsanity.Script.MainScript.ScriptCommand`'s `Load` (see
/// `AgentLabCommandCatalog`'s doc comment for the verified reference source
/// this mirrors byte-for-byte).
public struct AgentLabCommand: Sendable, Identifiable {
    public let id = UUID()
    /// Raw `internalIndex & 0xFFFF`, the on-disk `CommandID`. Kept even when
    /// `commandName`/`decoded` are both `nil`, so the raw value is never
    /// silently dropped for an ID this build doesn't have a name or decoder
    /// for.
    public let commandID: UInt16
    /// Raw `(internalIndex & 0xFFFF0000) >> 16`, `ScriptCommand.UnkShort` in
    /// the reference. Always `0` in every real command the reference's own
    /// constructors ever create, but captured (not dropped) so a full
    /// chain re-encode (`AgentLabWriter.encodeCommandChain`) never silently
    /// zeroes a value this build simply never learned the meaning of.
    public let unkShort: UInt16
    /// Real name from `Twinsanity.DefaultEnums.CommandID`, when this ID has
    /// one, an actual gap in the reference enum (an ID nobody named, not
    /// something this build declined to look up) shows as `nil`.
    public let commandName: String?
    /// Raw `uint32` arguments. Count comes from the real, per-platform
    /// `CommandSizeMapper_PS2`/`_Xbox`/`_Demo` table, never guessed.
    public let rawArguments: [UInt32]
    /// Named, typed decode of `rawArguments`, populated only for the
    /// commands this build has a *verified* reference `Load()` for (see
    /// `AgentLabActionDecoder`). Every other command still shows its real
    /// `rawArguments`, just without invented field names.
    public let decoded: AgentLabDecodedAction?
    /// Byte offset of this command's `internalIndex` within the record's raw
    /// bytes, lets a UI jump straight to it in the hex viewer.
    public let fileOffset: Int

    public init(commandID: UInt16, unkShort: UInt16 = 0, commandName: String?, rawArguments: [UInt32], decoded: AgentLabDecodedAction?, fileOffset: Int) {
        self.commandID = commandID
        self.unkShort = unkShort
        self.commandName = commandName
        self.rawArguments = rawArguments
        self.decoded = decoded
        self.fileOffset = fileOffset
    }
}

/// Named, typed argument decode for the commands this build has a verified
/// reference `Load()` implementation for, ported field-for-field from the
/// `Twinsanity.Actions.*` classes under `Code/Actions/Confirmed/` in the
/// reference tool (see `AgentLabActionDecoder`'s doc comment). Every case
/// here corresponds to a real, actively-registered `[ActionID(...)]` class
/// in that reference, nothing here is a guess at what an argument
/// "probably" means.
public enum AgentLabDecodedAction: Sendable, Equatable {
    case addAmmo(Int32)
    case addGem(AgentLabGemType)
    case addLives(Int32)
    case addWumpa(Int32)
    case cutsceneStart(fadeDuration: Float)
    case cutsceneEnd(fadeDuration: Float)
    case damageBoss(Int32)
    case hideBottomText(fadeDuration: Float)
    case progressWhackaworm(Int32)
    case reduceHitPoints(Int32)
    case setBehaviourPriority(UInt8)
    case setHitPoints(Int32)
    case showBottomText(fadeDuration: Float)
}

/// `AddGemAction.GemType`, ported verbatim (same raw values).
public enum AgentLabGemType: UInt32, Sendable, CaseIterable {
    case blue = 0, clear, green, purple, red, yellow
}

/// One slot of a `CodeModel` record's `agentLabAdditionsList`, a real,
/// literally-named `AgentLabAdditions` entry in the reference source (see
/// `CustomAgentParser`'s doc comment). `commands` is empty when the on-disk
/// `scriptCommandsAmount` was `0` (no chain stored for this slot).
public struct AgentLabScriptEntry: Sendable, Identifiable {
    public let id = UUID()
    public let scriptID: UInt16
    public let commands: [AgentLabCommand]

    public init(scriptID: UInt16, commands: [AgentLabCommand]) {
        self.scriptID = scriptID
        self.commands = commands
    }
}

/// A fully decoded `CustomAgent`/`CustomAgentX`/`CustomAgentDemo` leaf record
///, the real on-disk format `CodeModel.Load` reads (see `CustomAgentParser`).
public struct CustomAgentRecord: Sendable {
    public let recordID: UInt32
    /// Raw `Header` field; `entries.count` is `(headerRaw >> 16) & 0xFF`,
    /// kept alongside the parsed count since the reference tool exposes both.
    public let headerRaw: UInt32
    public let entries: [AgentLabScriptEntry]
    /// The record's own trailing command chain, read unconditionally after
    /// `entries`, exactly as `CodeModel.Load`'s own final
    /// `scriptCommand = new Script.MainScript.ScriptCommand(...)` does.
    public let finalCommands: [AgentLabCommand]

    public init(recordID: UInt32, headerRaw: UInt32, entries: [AgentLabScriptEntry], finalCommands: [AgentLabCommand]) {
        self.recordID = recordID
        self.headerRaw = headerRaw
        self.entries = entries
        self.finalCommands = finalCommands
    }
}

/// Which per-platform `CommandSizeMapper`/`scriptGameVersion` table applies , 
/// selected from the record's real `SectionType` (`.customAgent` -> `.ps2`,
/// `.customAgentX` -> `.xbox`, `.customAgentDemo` -> `.demo`), exactly
/// mirroring `CodeModel.Load`'s own `ParentType` check.
public enum AgentLabPlatformVariant: Sendable {
    case ps2
    case xbox
    case demo
}
