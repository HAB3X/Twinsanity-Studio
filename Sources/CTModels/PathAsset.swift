import Foundation
import simd

/// A decoded `Path` record (`SectionType.path`, Instance collection
/// sub-ID 4), a real position list plus one float pair per point. Ported
/// field-for-field from `Twinsanity/Items/Instances/Path.cs`'s `Load`.
/// Distinct from both `PositionMarker` (a single named point) and
/// `AIPosition`/`AIPath` (`SectionType.aiPosition`/`.aiPath`, the AI
/// waypoint system), this is a separate real record type the reference
/// tool itself keeps separate.
public struct PathAsset: Sendable, Identifiable {
    /// One point's real `float pair` (`Path.PathParam` in the reference)
    ///, kept under the reference tool's own field names since it never
    /// determined a more specific meaning (a common shape for "speed +
    /// wait time" or "in/out tangent," but not confirmed).
    public struct Param: Sendable {
        public var p1: Float
        public var p2: Float
        public init(p1: Float, p2: Float) {
            self.p1 = p1
            self.p2 = p2
        }
    }

    public let id: UInt32
    public var positions: [SIMD4<Float>]
    /// Parallel to `positions` in real data (both lists come from the
    /// same point sequence), but decoded and stored independently, same
    /// as the reference tool's own two separately-counted lists, not
    /// assumed to always be the same length.
    public var params: [Param]

    public init(id: UInt32, positions: [SIMD4<Float>], params: [Param]) {
        self.id = id
        self.positions = positions
        self.params = params
    }
}
