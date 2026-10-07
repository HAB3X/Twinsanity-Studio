import Foundation
import simd

/// A decoded `CollisionSurface` record (`SectionType.collisionSurface`,
/// Instance collection sub-ID 5), the physical-property record
/// `CollisionTriangle.surfaceID` cross-references *by value* (this
/// record's own `surfaceID` field, not its chunk index-table ID, the two
/// are independent namespaces). Ported field-for-field from
/// `Twinsanity/Items/Instances/CollisionSurface.cs`.
///
/// Every field beyond `surfaceID` and the sound/particle slots keeps the
/// reference tool's own `Unk`-prefixed naming, the reference tool itself
/// never determined what the physics floats or the two bounding boxes do,
/// so inventing friendlier names here would dress up a guess as fact, same
/// discipline as `CameraBoss`/`CameraPoint`'s own doc comment.
public struct CollisionSurfaceInfo: Sendable, Identifiable {
    /// This record's own chunk index-table ID, for tree/node identity
    /// only. Look up by `surfaceID` (below) to cross-reference from a
    /// `CollisionTriangle`.
    public let id: UInt32
    /// Real on-disk value `CollisionTriangle.surfaceID` matches against , 
    /// distinct from `id` above.
    public var surfaceID: UInt16
    public var flags: UInt32
    /// `65535` is the on-disk "no sound/particle" sentinel, kept as-is
    /// (not translated to `nil`) so a UI can match the reference tool's
    /// own sentinel check directly, same convention as
    /// `GameObjectInfo.ogiIDs`.
    public var sound1: UInt16
    public var sound2: UInt16
    public var particle1: UInt16
    public var particle2: UInt16
    public var sound3: UInt16
    public var sound4: UInt16
    public var particle3: UInt16
    public var sound5: UInt16
    public var sound6: UInt16
    /// Real on-disk padding after `sound6`, the game itself never reads
    /// it, but it's captured (not assumed `0`) so a write-back round trip
    /// never silently overwrites real bytes with a guess.
    public var paddingRaw: UInt16
    public var unkFloat1: Float
    public var unkFloat2: Float
    public var unkFloat3: Float
    public var unkFloat4: Float
    public var unkFloat5: Float
    public var unkFloat6: Float
    public var unkFloat7: Float
    public var unkFloat8: Float
    public var unkFloat9: Float
    public var unkFloat10: Float
    public var unkVector: SIMD4<Float>
    public var unkBoundingBox1: SIMD4<Float>
    public var unkBoundingBox2: SIMD4<Float>

    public init(
        id: UInt32, surfaceID: UInt16, flags: UInt32,
        sound1: UInt16, sound2: UInt16, particle1: UInt16, particle2: UInt16,
        sound3: UInt16, sound4: UInt16, particle3: UInt16, sound5: UInt16, sound6: UInt16, paddingRaw: UInt16,
        unkFloat1: Float, unkFloat2: Float, unkFloat3: Float, unkFloat4: Float, unkFloat5: Float,
        unkFloat6: Float, unkFloat7: Float, unkFloat8: Float, unkFloat9: Float, unkFloat10: Float,
        unkVector: SIMD4<Float>, unkBoundingBox1: SIMD4<Float>, unkBoundingBox2: SIMD4<Float>
    ) {
        self.id = id
        self.surfaceID = surfaceID
        self.flags = flags
        self.sound1 = sound1
        self.sound2 = sound2
        self.particle1 = particle1
        self.particle2 = particle2
        self.sound3 = sound3
        self.sound4 = sound4
        self.particle3 = particle3
        self.sound5 = sound5
        self.sound6 = sound6
        self.paddingRaw = paddingRaw
        self.unkFloat1 = unkFloat1
        self.unkFloat2 = unkFloat2
        self.unkFloat3 = unkFloat3
        self.unkFloat4 = unkFloat4
        self.unkFloat5 = unkFloat5
        self.unkFloat6 = unkFloat6
        self.unkFloat7 = unkFloat7
        self.unkFloat8 = unkFloat8
        self.unkFloat9 = unkFloat9
        self.unkFloat10 = unkFloat10
        self.unkVector = unkVector
        self.unkBoundingBox1 = unkBoundingBox1
        self.unkBoundingBox2 = unkBoundingBox2
    }

    /// Every real "no sound/particle assigned" slot filtered out, for a
    /// UI that just wants to know what audio/VFX this surface actually
    /// triggers, without the caller re-checking the `65535` sentinel five
    /// times over.
    public var assignedSoundIDs: [UInt16] { [sound1, sound2, sound3, sound4, sound5, sound6].filter { $0 != 65535 } }
    public var assignedParticleIDs: [UInt16] { [particle1, particle2, particle3].filter { $0 != 65535 } }

    /// Unlike `PlacedInstance.flagNames` (which ports real, verified names
    /// from the reference tool's own `InstanceFlagsEditor.flagtext`), the
    /// reference tool has **no** per-bit names for `CollisionSurface.Flags`
    /// anywhere: `CollisionSurface.cs` stores it as a bare `uint` (default
    /// `0x001FF0F0`, never decomposed), and its own
    /// `CollisionSurfaceController.GenText()` prints it back as one raw hex
    /// blob (`$"Flags: {Data.Flags:X8}"`) with no bit-level breakdown at
    /// all, confirmed by reading both files directly, not assumed from
    /// their absence. So every one of these 32 entries is an empty string,
    /// following the exact same "don't invent a name the reference tool
    /// itself never gave" convention `PlacedInstance.flagNames` documents
    /// for its own genuinely unnamed bits, there just happen to be zero
    /// named ones here instead of a handful.
    public static let flagNames: [String] = Array(repeating: "", count: 32)

    /// "Collision Property Semantics" (roadmap item 4b): four bit positions
    /// this build lets a user toggle experimentally to probe what
    /// `CollisionSurface.flags` actually controls in-game, since no
    /// reference source names any of them (see `flagNames`'s doc comment).
    /// The bit index each label uses here is this build's own arbitrary
    /// choice for probing, **not** a claim about what that bit does, see
    /// `CollisionSurfaceEditorSheet`'s "Collision Behavior (experimental)"
    /// section, whose UI copy repeats this same caveat next to every
    /// toggle. Change an index here only after finding real evidence for a
    /// *different* bit, don't just relabel this array without also
    /// updating that disclosure.
    public enum ExperimentalFlagBit: Int, CaseIterable {
        case walkableByPlayer = 0
        case walkableByAI = 1
        case dealsDamage = 2
        case climbable = 3

        public var label: String {
            switch self {
            case .walkableByPlayer: return "Walkable by Player"
            case .walkableByAI: return "Walkable by AI"
            case .dealsDamage: return "Deals Damage"
            case .climbable: return "Climbable"
            }
        }
    }

    /// Reads `ExperimentalFlagBit.rawValue` as a bit index into `flags` , 
    /// unconfirmed, see `ExperimentalFlagBit`'s own doc comment.
    public func experimentalFlag(_ bit: ExperimentalFlagBit) -> Bool {
        (flags >> UInt32(bit.rawValue)) & 1 != 0
    }

    /// The exact inverse of `experimentalFlag(_:)`, for the same
    /// unconfirmed bit, used by the toggle UI's own `Binding`.
    public mutating func setExperimentalFlag(_ bit: ExperimentalFlagBit, _ value: Bool) {
        if value {
            flags |= (1 << UInt32(bit.rawValue))
        } else {
            flags &= ~(1 << UInt32(bit.rawValue))
        }
    }
}
