import Foundation

/// A decoded `Script`/`ScriptX`/`ScriptDemo` leaf record, ported field-for-
/// field from `Twinsanity.Script`'s `Load` (`Twinsanity/Items/Code/
/// Script.cs`). This is the AI condition/state-machine system: a script is
/// either a `HeaderScript` (`flag != 0`, a "B.Starter": a priority-ordered
/// pointer to another script, used to pick which script actually runs for
/// an object) or a `MainScript` (`flag == 0`, the real state machine: a
/// chain of `ScriptState`s, each with zero or more `ScriptStateBody`s
/// pairing an optional `ScriptCondition` with a `ScriptCommand` chain, the
/// same on-disk command format as `CustomAgent`'s AgentLab bytecode, reused
/// here via `AgentLabCommandCatalog`/`AgentLabCommand`/`AgentLabActionDecoder`
/// rather than re-decoded).
///
/// Read-only, matching the `CollisionSurface`/`Skydome`/`Path`/`ParticleData`
/// precedent, no write-back attempted here.
public struct ScriptAsset: Sendable, Identifiable {
    public let id: UInt32
    /// The on-disk `id` field (`Script.id`), a real, distinct fact from the
    /// chunk index's own record ID, kept rather than assumed identical.
    public let inlineID: UInt16
    /// "B.Starter Priority" value, used to order `HeaderScript` alternatives.
    public let mask: UInt8
    /// `0` selects `MainScript`; nonzero selects `HeaderScript`.
    public let flag: UInt8
    public let content: ScriptContent
    /// Real trailing bytes after `Main`/`Header`, up to the record's
    /// declared size. The reference's own loader logs a warning when this
    /// is non-empty for a `MainScript` ("Script has leftovers (check
    /// command size mapper)"), meaning a nonzero value here is a known,
    /// occasionally-real quirk of the command-size tables, not necessarily
    /// evidence this decode went wrong.
    public let trailingBytes: Data

    public init(id: UInt32, inlineID: UInt16, mask: UInt8, flag: UInt8, content: ScriptContent, trailingBytes: Data) {
        self.id = id
        self.inlineID = inlineID
        self.mask = mask
        self.flag = flag
        self.content = content
        self.trailingBytes = trailingBytes
    }
}

public enum ScriptContent: Sendable {
    case main(MainScript)
    case header(HeaderScript)
}

/// A "B.Starter": a priority-ordered list of `(mainScriptIndex, unkInt2)`
/// pairs. `unkInt2` packs four small enums plus an object ID, ported
/// verbatim from `HeaderScript.UnkIntPairs`'s bit-packed accessors.
public struct HeaderScript: Sendable {
    public struct Entry: Sendable {
        /// 1-based index of the `MainScript` this pair points to
        /// (`mainScriptIndex - 1` is the real, 0-based script index).
        public var mainScriptIndex: Int32
        public var unkInt2: UInt32

        public init(mainScriptIndex: Int32, unkInt2: UInt32) {
            self.mainScriptIndex = mainScriptIndex
            self.unkInt2 = unkInt2
        }

        public var objectID: UInt16 { UInt16(truncatingIfNeeded: unkInt2 >> 0x10) }
        public var resolvedAssignType: AssignTypeID? { AssignTypeID(rawValue: UInt8(unkInt2 & 0xF)) }
        public var resolvedAssignLocality: AssignLocalityID? { AssignLocalityID(rawValue: UInt8((unkInt2 >> 4) & 0xF)) }
        public var resolvedAssignStatus: AssignStatusID? { AssignStatusID(rawValue: UInt8((unkInt2 >> 8) & 0xF)) }
        public var resolvedAssignPreference: AssignPreferenceID? { AssignPreferenceID(rawValue: UInt8((unkInt2 >> 0xC) & 0xF)) }
    }

    public var entries: [Entry]
    /// Byte offset of `entries[0]`, relative to this `Script` record's own
    /// start, same capture-once, patch-at-a-fixed-offset reasoning as
    /// `PlacedInstance.objectIDFileOffset`. Each entry is a fixed 8 bytes
    /// (`Int32` + `UInt32`), so entry `i` lives at `entriesFileOffset + i * 8`.
    public var entriesFileOffset: Int

    public init(entries: [Entry], entriesFileOffset: Int = 0) {
        self.entries = entries
        self.entriesFileOffset = entriesFileOffset
    }

    public enum AssignTypeID: UInt8, Sendable {
        case me = 0, objectChild, linkedObject, globalAgent, humanPlayer, backgroundCharacter, anybody, generateAgent, originator
    }
    public enum AssignLocalityID: UInt8, Sendable {
        case nearby = 0, local, global, anywhere
    }
    public enum AssignStatusID: UInt8, Sendable {
        case idle = 0, busy, anyState
    }
    public enum AssignPreferenceID: UInt8, Sendable {
        case nearest = 0, furthest, strongest, weakest, bestAligned, anyhow
    }
}

/// The real state machine: `name`, a `startUnit`, and a flattened
/// `ScriptState` chain (the reference links these via `ScriptState.
/// nextState`/bit `0x8000`; flattened here into array order, same
/// technique `CustomAgentParser.readCommandChain` already uses for its own
/// command chain, for the same reason, no unbounded recursion on
/// malformed/hostile data).
public struct MainScript: Sendable {
    public var name: String
    /// On-disk `StatesAmount`, real, but only used by the reference to
    /// decide *whether* to read any states at all (`> 0`); the true count
    /// is `states.count`, from actually walking the chain.
    public var statesAmountRaw: Int32
    public var startUnit: Int32
    public var states: [ScriptState]

    public init(name: String, statesAmountRaw: Int32, startUnit: Int32, states: [ScriptState]) {
        self.name = name
        self.statesAmountRaw = statesAmountRaw
        self.startUnit = startUnit
        self.states = states
    }
}

/// One node of the state chain. `bitfieldRaw` bit `0x4000` gates `type1`;
/// bit `0x1000` is `isSlot`; the low 5 bits are how many `ScriptStateBody`
/// entries follow (`bodies.count`, once read).
public struct ScriptState: Sendable {
    public var bitfieldRaw: Int16
    public var scriptIndexOrSlot: Int16
    public var type1: SupportType1?
    public var bodies: [ScriptStateBody]
    /// Byte offset of `scriptIndexOrSlot` itself, relative to this
    /// `Script` record's own start, captured during parse
    /// (`ScriptParser.readStateChain`), same "capture the real offset
    /// once, patch a fixed-size range there" pattern as
    /// `PlacedInstance.objectIDFileOffset`. Lets a `ScriptState` be
    /// redirected to a different script/slot (the same real operation
    /// CrateModLoader's own cutscene-skip mods perform) without
    /// re-encoding the whole variable-length `Script` record.
    public var scriptIndexOrSlotFileOffset: Int

    public init(bitfieldRaw: Int16, scriptIndexOrSlot: Int16, type1: SupportType1?, bodies: [ScriptStateBody], scriptIndexOrSlotFileOffset: Int = 0) {
        self.bitfieldRaw = bitfieldRaw
        self.scriptIndexOrSlot = scriptIndexOrSlot
        self.type1 = type1
        self.bodies = bodies
        self.scriptIndexOrSlotFileOffset = scriptIndexOrSlotFileOffset
    }

    public var isSlot: Bool { (bitfieldRaw & 0x1000) != 0 }
    /// Low 5 bits of `bitfieldRaw`, how many `ScriptStateBody` entries this
    /// state declares (matches `bodies.count` on a well-formed record).
    public var declaredBodyCount: Int16 { bitfieldRaw & 0x1F }
}

/// `SupportType1`, a motion/orientation descriptor. `unkInt1Raw` packs a
/// large number of small enums and flags, ported verbatim from the
/// reference's own bit-accessor properties.
public struct SupportType1: Sendable {
    /// Real byte-list, length `unkByte1`.
    public var bytes: [UInt8]
    /// Real float-list, length `unkByte2`. Three specific slots (indices
    /// `bytes[0]`, `bytes[1]`, `bytes[22]`, when that byte value is `< 128`)
    /// are stored on disk as the *numeric value of a `uint32`* read from the
    /// same 4 bytes, not an IEEE float bit pattern, ported exactly per the
    /// reference's own re-seek-and-reread logic in `SupportType1`'s reader
    /// constructor.
    public var floats: [Float]
    /// Version, "always 6" per the reference's own comment.
    public var unkUShort1: UInt16
    public var unkInt1Raw: UInt32
    /// Byte offset of `unkInt1Raw` (4 bytes, immediately after `unkUShort1`),
    /// relative to the enclosing `Script` record's own start, captured
    /// during parse the same "fixed offset, patch in place" way as
    /// `ScriptState.scriptIndexOrSlotFileOffset`. `unkInt1Raw` packs every
    /// `resolved*`/flag accessor on this type, so this one offset is enough
    /// to make all of them writable without touching the variable-length
    /// `bytes`/`floats` lists that follow.
    public var unkInt1RawFileOffset: Int

    public init(bytes: [UInt8], floats: [Float], unkUShort1: UInt16, unkInt1Raw: UInt32, unkInt1RawFileOffset: Int = 0) {
        self.bytes = bytes
        self.floats = floats
        self.unkUShort1 = unkUShort1
        self.unkInt1Raw = unkInt1Raw
        self.unkInt1RawFileOffset = unkInt1RawFileOffset
    }

    public var resolvedSpace: SpaceType? { SpaceType(rawValue: UInt8(unkInt1Raw & 7)) }
    public var resolvedMotion: MotionType? { MotionType(rawValue: UInt8((unkInt1Raw >> 3) & 0xF)) }
    public var resolvedContRotate: ContinuousRotate? { ContinuousRotate(rawValue: UInt8((unkInt1Raw >> 7) & 0xF)) }
    public var resolvedAccelFunc: AccelFunction? { AccelFunction(rawValue: UInt8((unkInt1Raw >> 0xB) & 3)) }
    public var resolvedAxes: NaturalAxes? { NaturalAxes(rawValue: UInt8((unkInt1Raw >> 0x1B) & 7)) }
    public var translates: Bool { (unkInt1Raw >> 0xD) & 1 != 0 }
    public var rotates: Bool { (unkInt1Raw >> 0xE) & 1 != 0 }
    public var translationContinues: Bool { (unkInt1Raw >> 0xF) & 1 != 0 }
    public var tracksDestination: Bool { (unkInt1Raw >> 0x10) & 1 != 0 }
    public var interpolatesAngles: Bool { (unkInt1Raw >> 0x11) & 1 != 0 }
    public var yawFaces: Bool { (unkInt1Raw >> 0x12) & 1 != 0 }
    public var pitchFaces: Bool { (unkInt1Raw >> 0x13) & 1 != 0 }
    public var orientsPredicts: Bool { (unkInt1Raw >> 0x14) & 1 != 0 }
    public var hasValidData: Bool { (unkInt1Raw >> 0x15) & 1 != 0 }
    public var keyIsLocal: Bool { (unkInt1Raw >> 0x16) & 1 != 0 }
    public var usesRotator: Bool { (unkInt1Raw >> 0x17) & 1 != 0 }
    public var usesInterpolator: Bool { (unkInt1Raw >> 0x18) & 1 != 0 }
    public var usesPhysics: Bool { (unkInt1Raw >> 0x19) & 1 != 0 }
    public var contRotatesInWorldSpace: Bool { (unkInt1Raw >> 0x1A) & 1 != 0 }
    public var stalls: Bool { (unkInt1Raw >> 0x1F) & 1 != 0 }

    public enum SpaceType: UInt8, Sendable, CaseIterable {
        case worldSpace = 0, initialSpace, currentSpace, targetSpace, parentSpace, initialPos, currentPos, storedSpace
    }
    public enum MotionType: UInt8, Sendable, CaseIterable {
        case noMotion = 0, constantVel, accelerated, spring, projectile, linearInterp, smoothPath, faceDestOnly, drive, groundChase, airChase
    }
    public enum ContinuousRotate: UInt8, Sendable {
        case noContRotation = 0, numFullRots, radsPerSecond, naturalRoll
    }
    public enum NaturalAxes: UInt8, Sendable {
        case noNatural = 0, xNatural, yNatural, zNatural, allNatural
    }
    public enum AccelFunction: UInt8, Sendable {
        case noAccel = 0, constantAccel, smoothCurve
    }
}

/// One `(condition, command-chain)` pair for a `ScriptState`. `bitfieldRaw`
/// bit `0x400` gates `scriptStateListIndex` (and doubles as `isEnabled`);
/// bit `0x200` gates `condition`; the low byte is `commandCount` (nonzero
/// gates `commands`); bit `0x800` chains to the next `ScriptStateBody`
/// (flattened into the parent `ScriptState.bodies` array here).
public struct ScriptStateBody: Sendable {
    public var bitfieldRaw: Int32
    public var scriptStateListIndex: Int32?
    public var condition: ScriptCondition?
    public var commands: [AgentLabCommand]

    public init(bitfieldRaw: Int32, scriptStateListIndex: Int32?, condition: ScriptCondition?, commands: [AgentLabCommand]) {
        self.bitfieldRaw = bitfieldRaw
        self.scriptStateListIndex = scriptStateListIndex
        self.condition = condition
        self.commands = commands
    }

    public var isEnabled: Bool { (bitfieldRaw & 0x400) != 0 }
    public var commandCount: UInt8 { UInt8(bitfieldRaw & 0xFF) }
}

/// A single evaluated condition, ported verbatim from `ScriptCondition`'s
/// reader constructor and bit accessors. `vTableAddress` is never read from
/// disk in the reference (always set to `0`, a runtime-only field), so it
/// isn't modeled here.
public struct ScriptCondition: Sendable {
    public var unkInt1Raw: Int32
    public var interval: Float
    public var threshold: Float
    public var thresholdInverse: Float
    /// Byte offset of `unkInt1Raw`, relative to the enclosing `Script`
    /// record's own start, the four fields here are fixed-size and
    /// written in this exact sequential order (`unkInt1Raw`, `interval`,
    /// `threshold`, `thresholdInverse`, 4 bytes each), so `fileOffset +
    /// 0/4/8/12` addresses each one directly for a same-size patch,
    /// same "capture once, patch in place" pattern as `ScriptState.
    /// scriptIndexOrSlotFileOffset`.
    public var fileOffset: Int

    public init(unkInt1Raw: Int32, interval: Float, threshold: Float, thresholdInverse: Float, fileOffset: Int = 0) {
        self.unkInt1Raw = unkInt1Raw
        self.interval = interval
        self.threshold = threshold
        self.thresholdInverse = thresholdInverse
        self.fileOffset = fileOffset
    }

    public var vTableIndex: UInt16 { UInt16(truncatingIfNeeded: unkInt1Raw & 0xFFFF) }
    public var parameter: UInt16 { UInt16(truncatingIfNeeded: (UInt32(bitPattern: unkInt1Raw) & 0xFFFF0000) >> 17) }
    public var notGate: Bool { (unkInt1Raw & 0x10000) != 0 }
}
