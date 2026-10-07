import Foundation
import simd

/// One collision triangle (`ColData.ColTri`), indices into the record's
/// shared `vertices` pool, plus a `surfaceID` linking it to a
/// `CollisionSurface` record (`SectionType.collisionSurface`) for its
/// physical properties (impact sound, particle effect, friction-ish
/// floats). This package doesn't currently decode `CollisionSurface`
/// records or the `Object`/`Script` data that would say which surface IDs
/// are "deadly" vs "solid" vs whatever else, `surfaceID` is exposed raw
/// rather than pre-sorted into an invented category, since that mapping
/// isn't something this codebase has verified yet.
public struct CollisionTriangle: Sendable {
    public var vertexIndex1: Int
    public var vertexIndex2: Int
    public var vertexIndex3: Int
    public var surfaceID: Int

    public init(vertexIndex1: Int, vertexIndex2: Int, vertexIndex3: Int, surfaceID: Int) {
        self.vertexIndex1 = vertexIndex1
        self.vertexIndex2 = vertexIndex2
        self.vertexIndex3 = vertexIndex3
        self.surfaceID = surfaceID
    }
}

/// An axis-aligned collision trigger box (`ColData.Trigger`, note this is
/// a distinct, simpler struct from the gameplay `TriggerVolume`/`Trigger`
/// record decoded elsewhere; the reference tool reuses the name for two
/// unrelated things).
public struct CollisionTriggerBox: Sendable {
    public var min: SIMD3<Float>
    public var flag1: Int32
    public var max: SIMD3<Float>
    public var flag2: Int32

    public init(min: SIMD3<Float>, flag1: Int32, max: SIMD3<Float>, flag2: Int32) {
        self.min = min
        self.flag1 = flag1
        self.max = max
        self.flag2 = flag2
    }
}

/// A spatial partition entry (`ColData.GroupInfo`), `offset`/`size` index
/// into the triangle list for a broad-phase collision bucket. Kept for
/// completeness/inspection; not used by the wireframe renderer, which just
/// draws every triangle.
public struct CollisionGroup: Sendable {
    public var size: UInt32
    public var offset: UInt32

    public init(size: UInt32, offset: UInt32) {
        self.size = size
        self.offset = offset
    }
}

/// A decoded `ColData` record (`Twinsanity/Items/ColData.cs`), a whole
/// level file's static collision mesh: a shared vertex pool, indexed
/// triangles (each tagged with a surface ID), a spatial group index, and
/// axis-aligned trigger boxes. This is physics geometry, distinct from the
/// gameplay `Trigger`/`Camera`/`Instance` records under `SectionType.instance`.
public struct CollisionMesh: Sendable, Identifiable {
    public let id: UInt32
    public var vertices: [SIMD4<Float>]
    public var triangles: [CollisionTriangle]
    public var groups: [CollisionGroup]
    public var triggerBoxes: [CollisionTriggerBox]

    public init(id: UInt32, vertices: [SIMD4<Float>], triangles: [CollisionTriangle], groups: [CollisionGroup], triggerBoxes: [CollisionTriggerBox]) {
        self.id = id
        self.vertices = vertices
        self.triangles = triangles
        self.groups = groups
        self.triggerBoxes = triggerBoxes
    }

    /// `ColData.Load` treats any record shorter than the 20-byte header as
    /// an intentionally empty placeholder (`isEmpty` in the reference
    /// tool) rather than a malformed one.
    public var isEmpty: Bool { vertices.isEmpty || triangles.isEmpty }
}
