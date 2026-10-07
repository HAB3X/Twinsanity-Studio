import Foundation

/// A decoded `Skydome` record (`SectionType.skydome`, Graphics collection
/// sub-ID 8), a level's sky-dome mesh reference. Ported field-for-field
/// from `Twinsanity/Items/Graphics/Skydome.cs`'s `Load`. `unknown` keeps
/// the reference tool's own field name, its default value (`20480`)
/// suggests a fixed-point scale or flag word, but the reference tool never
/// interprets it further, so neither does this.
public struct SkydomeInfo: Sendable, Identifiable {
    public let id: UInt32
    public var unknown: UInt32
    /// Real `Model`/`RigidModel` record IDs this skydome renders as, the
    /// reference format allows more than one, though real data typically
    /// has exactly one.
    public var meshIDs: [UInt32]

    public init(id: UInt32, unknown: UInt32, meshIDs: [UInt32]) {
        self.id = id
        self.unknown = unknown
        self.meshIDs = meshIDs
    }
}
