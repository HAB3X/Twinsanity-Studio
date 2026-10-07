import Foundation
import CTModels

/// A single element-level edit to one `PlacedInstance`'s record, the
/// output of a `GameplayMod`'s `patch` closure. Kept as sparse
/// index/value pairs (not a whole new `PlacedInstance`) since every field
/// these mods touch is patched in place at a captured file offset
/// (`unknownFloatListFileOffset`/etc.), never by re-encoding the whole
/// variable-length record.
public struct InstancePatch: Sendable {
    /// `(index, value)` pairs into `unknownFloatList` (`UnkI322` , 
    /// `CharacterInstanceFloats` in the reference).
    public var floatListElements: [(index: Int, value: Float)] = []
    /// `(index, value)` pairs into `unknownUInt32List` (`UnkI321` , 
    /// `CharacterInstanceFlags` in the reference).
    public var uint32ListElements: [(index: Int, value: UInt32)] = []
    /// `(index, value)` pairs into `unknownUInt32List2` (`UnkI323`).
    public var uint32List2Elements: [(index: Int, value: UInt32)] = []
    /// A full replacement for `flags`, when a mod needs the whole field
    /// rather than one bit.
    public var flags: UInt32?

    public var isEmpty: Bool {
        floatListElements.isEmpty && uint32ListElements.isEmpty && uint32List2Elements.isEmpty && flags == nil
    }
}

/// A single named, verified gameplay-mod toggle: real field-offset
/// patches ported from **CrateModLoader**'s own `CrateModGames/
/// GameSpecific/CrashTS/Mods/*.cs` (`https://github.com/DKY2020/
/// CrateModLoader`, "Twinsanity API by NeoKesha, Smartkin, ManDude, BetaM
/// and Marko"), the community's actual, working gameplay-hack tool for
/// Crash Twinsanity, not reverse-engineered or guessed at by this
/// project. Every numeric value below (array indices, byte offsets,
/// enum ordinals, magic constants like `72.951` or `0x188B2E`) is copied
/// verbatim from that source.
///
/// Scope: only mods whose *entire* effect is expressible as `Instance`
/// record patches (`UnkI321`/`UnkI322`/`UnkI323`/`Flags`) are ported
/// here. CrateModLoader mods that also rewire `GameObject.Scripts` or
/// `Script` command chains (`TS_EnableStompKick`, `TS_SwitchCharacters`,
/// `TS_ClassicExplosions`, `TS_SkipCutscenes`) need a `GameObject`/
/// `Script` *writer*, which this codebase doesn't have yet (the `Script`
/// decoder is read-only, see `ScriptAsset`'s doc comment), not
/// included here rather than half-applied.
public struct GameplayMod: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    /// Real Twinsanity `ObjectID` values this mod looks for, instances
    /// with any other `objectID` are left untouched.
    public let matchesObjectIDs: Set<UInt16>
    public let patch: @Sendable (PlacedInstance) -> InstancePatch?

    public init(id: String, title: String, summary: String, matchesObjectIDs: Set<UInt16>, patch: @escaping @Sendable (PlacedInstance) -> InstancePatch?) {
        self.id = id
        self.title = title
        self.summary = summary
        self.matchesObjectIDs = matchesObjectIDs
        self.patch = patch
    }
}

/// Real, verified `ObjectID` values, ported from CrateModLoader's own
/// `ObjectID` enum (`Common/Twins_Data_Objects.cs`).
public enum KnownObjectID {
    public static let crash: UInt16 = 0
    public static let cortex: UInt16 = 74
    public static let globalBatDarkpurple: UInt16 = 116
    public static let nina: UInt16 = 347
    public static let mechabandicoot: UInt16 = 379
    public static let schoolFrogenstein: UInt16 = 451
}

public enum GameplayModCatalog {
    /// `CharacterInstanceFloats` ordinals, ported from CrateModLoader's
    /// own enum (`Common/Twins_Common.cs`), which documents each slot's
    /// real, observed in-game meaning.
    private enum Floats {
        static let strafingSpeed = 8
        static let doubleJumpHeight = 20
        static let doubleJumpUnk22 = 21
        static let doubleJumpArcUnk = 22
        static let flyingKickHangTime = 34
        static let flyingKickForwardSpeed = 35
        static let flyingKickGravity = 36
    }

    /// `CharacterInstanceFlags` ordinals, same source as `Floats`.
    private enum Flags {
        static let slideJumpRotationSpeed = 8
    }

    /// `PropertyFlags.DisableObject`, same source.
    private static let disableObjectFlag: UInt32 = 0xC000_0000

    public static let allMods: [GameplayMod] = [
        GameplayMod(
            id: "classicHealth",
            title: "Classic Health",
            summary: "Restores the original 3-hit health system on Crash, Cortex, Nina, and Mecha-Bandicoot instead of Twinsanity's default health model.",
            matchesObjectIDs: [KnownObjectID.crash, KnownObjectID.cortex, KnownObjectID.nina, KnownObjectID.mechabandicoot]
        ) { instance in
            guard instance.unknownUInt32List2.count > 2 else { return nil }
            var patch = InstancePatch()
            patch.uint32List2Elements = [(2, 1)]
            return patch
        },
        GameplayMod(
            id: "cortexDoubleJump",
            title: "Cortex Double Jump",
            summary: "Gives Cortex a double jump with the same real arc constants Crash's own double jump uses.",
            matchesObjectIDs: [KnownObjectID.cortex]
        ) { instance in
            guard instance.unknownFloatList.count > Floats.doubleJumpArcUnk else { return nil }
            var patch = InstancePatch()
            patch.floatListElements = [
                (Floats.doubleJumpHeight, 16),
                (Floats.doubleJumpUnk22, 64),
                (Floats.doubleJumpArcUnk, 72.951)
            ]
            return patch
        },
        GameplayMod(
            id: "ninaDoubleJump",
            title: "Nina Double Jump",
            summary: "Gives Nina a double jump with the same real arc constants Crash's own double jump uses.",
            matchesObjectIDs: [KnownObjectID.nina]
        ) { instance in
            guard instance.unknownFloatList.count > Floats.doubleJumpArcUnk else { return nil }
            var patch = InstancePatch()
            patch.floatListElements = [
                (Floats.doubleJumpHeight, 16),
                (Floats.doubleJumpUnk22, 64),
                (Floats.doubleJumpArcUnk, 72.951)
            ]
            return patch
        },
        GameplayMod(
            id: "classicSlideJump",
            title: "Classic Slide Jump Rotation",
            summary: "Enables Crash's slide-jump rotation speed, which is zeroed out by default in Twinsanity.",
            matchesObjectIDs: [KnownObjectID.crash]
        ) { instance in
            guard instance.unknownUInt32List.count > Flags.slideJumpRotationSpeed else { return nil }
            var patch = InstancePatch()
            patch.uint32ListElements = [(Flags.slideJumpRotationSpeed, 0x10000)]
            return patch
        },
        GameplayMod(
            id: "flyingKick",
            title: "Flying Kick",
            summary: "Enables Crash's unused Flying Kick move (a single-jump air attack, replaces the bodyslam) by setting its hang time, forward speed, and fall gravity to the values that make it work. Character-stat only, this doesn't rewire the move's animation/script hooks the way CrateModLoader's own \"Stomp Kick\" variant does, since that needs a GameObject script writer this tool doesn't have yet.",
            matchesObjectIDs: [KnownObjectID.crash]
        ) { instance in
            guard instance.unknownFloatList.count > Floats.flyingKickGravity else { return nil }
            var patch = InstancePatch()
            patch.floatListElements = [
                (Floats.flyingKickHangTime, 0.15),
                (Floats.flyingKickForwardSpeed, 50),
                (Floats.flyingKickGravity, 10)
            ]
            return patch
        },
        GameplayMod(
            id: "enableHiddenEnemies",
            title: "Enable Hidden Enemies",
            summary: "Re-enables two enemy placements Twinsanity ships disabled: the dark-purple bat (clears its DisableObject flag) and the School Frogenstein (forces its known-working flag value).",
            matchesObjectIDs: [KnownObjectID.globalBatDarkpurple, KnownObjectID.schoolFrogenstein]
        ) { instance in
            var patch = InstancePatch()
            if instance.objectID == KnownObjectID.globalBatDarkpurple {
                guard instance.flags > disableObjectFlag else { return nil }
                patch.flags = instance.flags - disableObjectFlag
            } else if instance.objectID == KnownObjectID.schoolFrogenstein {
                patch.flags = 0x0018_8B2E
            } else {
                return nil
            }
            return patch
        }
    ]
}
