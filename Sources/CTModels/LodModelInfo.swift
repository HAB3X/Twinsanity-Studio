import Foundation

/// A `LodModel` record, a thin indirection layer, not geometry of its own:
/// a list of alternate `RigidModel` IDs (highest detail first) to use at
/// different distances. Ported from `Twinsanity/Items/Graphics/LodModel.cs`.
///
/// This was the real, confirmed root cause of scenery objects silently
/// vanishing from the Level Viewer: a scenery placement's `modelID` can
/// point at a `LodModel` record instead of a `RigidModel` directly, and
/// this record type was previously completely undecoded (fell through to
/// `.raw`). Verified against a real level (`Levels/Earth/Hub/hubd.sm2`):
/// every one of that file's "unresolved" scenery placements matched a real
/// `LodModel` record ID, and the overwhelming majority resolved cleanly
/// through their first (highest-detail) `lodModelIDs` entry.
public struct LodModelInfo: Sendable, Codable {
    public let id: UInt32
    public var header: UInt32
    /// Real distance-threshold values per the reference tool's own field
    /// name, but this build doesn't have a confirmed interpretation of
    /// their units/meaning, kept for round-tripping, not used to pick a
    /// LOD level. This viewer always prefers the first (highest-detail)
    /// `lodModelIDs` entry that actually resolves, not a distance-based
    /// selection.
    public var lodDistances: [UInt32]
    /// Alternate `RigidModel` IDs, highest detail first.
    public var lodModelIDs: [UInt32]

    public init(id: UInt32, header: UInt32, lodDistances: [UInt32], lodModelIDs: [UInt32]) {
        self.id = id
        self.header = header
        self.lodDistances = lodDistances
        self.lodModelIDs = lodModelIDs
    }
}
