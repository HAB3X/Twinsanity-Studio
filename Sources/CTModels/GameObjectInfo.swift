import Foundation

/// A `GameObject` (`Object` section, sub-ID 0 under `Code`), the game-logic
/// definition an `Instance.objectID` actually refers to. Ported in full from
/// `Twinsanity/Items/Code/GameObject.cs`'s `Load`/`Save`/`GetSize`.
public struct GameObjectInfo: Sendable {
    public let id: UInt32
    public var name: String
    /// `GraphicsInfo` (OGI) record IDs this object can render as, index 0
    /// is the default; `Instance.unknownUInt32List2[0]`, when non-zero,
    /// selects a different entry instead (see `AssetResolver.
    /// resolveInstanceObject`'s doc comment for exactly how, ported from
    /// `RMViewer.cs`). `65535` is the on-disk "no value" sentinel, kept
    /// as-is rather than translated to `nil` so callers can match the
    /// reference logic's own sentinel check directly.
    public var ogiIDs: [UInt32]
    /// Gates the two optional trailing blocks below (`0x20000000` for
    /// `instanceProperties`, `0x40000000` for `linkedIDs`), kept raw
    /// rather than exposing two derived `Bool`s since the reference
    /// itself treats this as one opaque bitfield with only those two bits
    /// confirmed. Real, verified accessors for the reference's own
    /// `comboBoxObjectType`/`comboBoxObjectMobileType`/joint-ID-count/
    /// exit-point-count/`checkBoxUseTemplate`/`BitfieldFlag4` fields (see
    /// `ObjectEditor.cs`'s `InitLists`/`comboBoxObjectType_
    /// SelectedIndexChanged` etc.) live below as computed properties over
    /// this same raw value, `var`, since `GameObjectWriter.encode`
    /// consumes this raw field directly rather than the accessors.
    public var unkBitfield: UInt32
    /// Untyped `uint32` script-slot list, real, decoded, but the
    /// reference tool itself never gives these individual meaning beyond
    /// "a `UI32` slot."
    public var ui32: [UInt32]
    public var animIDs: [UInt16]
    public var scriptIDs: [UInt16]
    public var objectIDs: [UInt16]
    public var soundIDs: [UInt16]
    /// Present only when `unkBitfield & 0x20000000 != 0`.
    public var instanceProperties: InstanceProperties?
    /// Present only when `unkBitfield & 0x40000000 != 0`, the ID lists
    /// `GameObject.FillPackage` walks to bundle a mod-crate's real
    /// dependency closure (linked objects/OGIs/anims/CodeModels/scripts/
    /// sounds). Not yet consumed by this build's own `CrateExporter`
    /// (see that type's doc comment for current scope), but decoded here
    /// since it's real, unambiguous on-disk data.
    public var linkedIDs: LinkedIDs?
    /// This object's own trailing script-bytecode command chain, the
    /// exact same `Script.MainScript.ScriptCommand` format `CustomAgent`
    /// records use (see `CustomAgentParser.readCommandChain`), attached
    /// directly to the object rather than to a separate `CustomAgent`
    /// record. Empty when the record's own `scriptCommandsAmount` is `0`.
    public var scriptCommands: [AgentLabCommand]

    public struct InstanceProperties: Sendable {
        /// Recomputed on save from the three list counts below (`byte
        /// flags.count | floats.count << 8 | integers.count << 16`) , 
        /// matches `GameObject.Save`'s own `PHeader = ...` line exactly;
        /// kept here only because it's real on-disk data to decode, never
        /// trusted as authoritative by the writer.
        public var pHeader: UInt32
        public var pUI32: UInt32
        public var flags: [UInt32]
        public var floats: [Float]
        public var integers: [UInt32]

        public init(pHeader: UInt32, pUI32: UInt32, flags: [UInt32], floats: [Float], integers: [UInt32]) {
            self.pHeader = pHeader
            self.pUI32 = pUI32
            self.flags = flags
            self.floats = floats
            self.integers = integers
        }
    }

    public struct LinkedIDs: Sendable {
        /// Recomputed on save from which of the 7 lists below are
        /// non-empty (`GameObject.updateFlag`'s own bit-per-list logic) , 
        /// same "decoded but never trusted by the writer" reasoning as
        /// `InstanceProperties.pHeader`.
        public var flag: UInt32
        public var objects: [UInt16]
        public var ogis: [UInt16]
        public var anims: [UInt16]
        public var codeModels: [UInt16]
        public var scripts: [UInt16]
        public var unk: [UInt16]
        public var sounds: [UInt16]

        public init(flag: UInt32, objects: [UInt16], ogis: [UInt16], anims: [UInt16], codeModels: [UInt16], scripts: [UInt16], unk: [UInt16], sounds: [UInt16]) {
            self.flag = flag
            self.objects = objects
            self.ogis = ogis
            self.anims = anims
            self.codeModels = codeModels
            self.scripts = scripts
            self.unk = unk
            self.sounds = sounds
        }
    }

    public init(
        id: UInt32,
        name: String,
        ogiIDs: [UInt32],
        unkBitfield: UInt32 = 0,
        ui32: [UInt32] = [],
        animIDs: [UInt16] = [],
        scriptIDs: [UInt16] = [],
        objectIDs: [UInt16] = [],
        soundIDs: [UInt16] = [],
        instanceProperties: InstanceProperties? = nil,
        linkedIDs: LinkedIDs? = nil,
        scriptCommands: [AgentLabCommand] = []
    ) {
        self.id = id
        self.name = name
        self.ogiIDs = ogiIDs
        self.unkBitfield = unkBitfield
        self.ui32 = ui32
        self.animIDs = animIDs
        self.scriptIDs = scriptIDs
        self.objectIDs = objectIDs
        self.soundIDs = soundIDs
        self.instanceProperties = instanceProperties
        self.linkedIDs = linkedIDs
        self.scriptCommands = scriptCommands
    }

    // MARK: - unkBitfield accessors
    //
    // Ported from `ObjectEditor.cs`'s own read/write sites (`InitLists`,
    // `comboBoxObjectType_SelectedIndexChanged`, etc.), the reference
    // treats `UnkBitfield` as one opaque uint with these bit ranges, not a
    // named struct, so these are exposed the same "resolved computed
    // property over a raw stored field" way `SupportType1.resolved*` is.

    /// Bits 0x14–0x1B (8 bits): `comboBoxObjectType`'s selected index. The
    /// reference's own combo box only has 9 named entries (`ObjectTypeID`)
    ///, a real file can still carry any 0–255 value here, so this decodes
    /// to `nil` rather than crashing when it's out of that range.
    public var resolvedObjectType: ObjectTypeID? { ObjectTypeID(rawValue: UInt8((unkBitfield >> 0x14) & 0xFF)) }
    public var objectTypeRaw: UInt8 { UInt8((unkBitfield >> 0x14) & 0xFF) }
    /// Bits 0xC–0x13 (8 bits): `comboBoxObjectMobileType`. The reference's
    /// combo box only round-trips 3 specific stored values (1/17/18); any
    /// other raw value decodes to `nil` here, same reasoning as
    /// `resolvedObjectType`.
    public var resolvedMobileType: MobileTypeID? { MobileTypeID(rawValue: UInt8((unkBitfield >> 0xC) & 0xFF)) }
    public var mobileTypeRaw: UInt8 { UInt8((unkBitfield >> 0xC) & 0xFF) }
    /// Bits 0x6–0xB (6 bits): `numericUpDownJointIDs`.
    public var jointIDCount: UInt8 { UInt8((unkBitfield >> 0x6) & 0x3F) }
    /// Bits 0x0–0x5 (6 bits): `numericUpDownExitPoints`.
    public var exitPointCount: UInt8 { UInt8(unkBitfield & 0x3F) }
    /// Bit 0x1C: `checkBoxUseTemplate`.
    public var useTemplate: Bool { (unkBitfield >> 0x1C) & 1 != 0 }
    /// Bit 0x1D (`0x20000000`): `checkBoxHasTemplate`, same bit that
    /// gates `instanceProperties`'s presence.
    public var hasTemplate: Bool { (unkBitfield >> 0x1D) & 1 != 0 }
    /// Bit 0x1E (`0x40000000`): `checkBoxHasResources`, same bit that
    /// gates `linkedIDs`'s presence.
    public var hasResources: Bool { (unkBitfield >> 0x1E) & 1 != 0 }
    /// Bit 0x1F: `checkBoxBitfieldFlag4`, unnamed in the reference itself.
    public var bitfieldFlag4: Bool { (unkBitfield >> 0x1F) & 1 != 0 }

    /// `comboBoxObjectType`'s 9 named entries, in on-disk order.
    public enum ObjectTypeID: UInt8, Sendable, CaseIterable {
        case character = 0, pickup, crate, creature, furniture, chiChiGrass, payGate, foofie, projectile
    }
    /// `comboBoxObjectMobileType`'s 3 entries, note the stored raw values
    /// (1/17/18) are *not* sequential, ported exactly from the reference's
    /// own `switch` in `comboBoxObjectMobileType_SelectedIndexChanged`.
    public enum MobileTypeID: UInt8, Sendable, CaseIterable {
        case mobile = 1, pickup = 17, projectile = 18
    }
}
