import Foundation
import simd

/// "Xbox Morphs" (roadmap item 4e): unlike the PS2 `Model`/`Skin`/
/// `BlendSkin` family (VIF-encoded vertex streams, see `VIFInterpreter`),
/// the Xbox `ModelX`/`SkinX`/`BlendSkinX` records use a plain, fixed-size
/// vertex layout with **no VU/VIF chip involved at all** (Xbox hardware
/// has none). This is a real, fully confirmed layout, ported field-for-
/// field from the reference tool's own working `Load`/`Save` methods
/// (`Twinsanity/Items/Graphics/{ModelX,SkinX,BlendSkinX}.cs`), including
/// its own PLY/OBJ exporters, which consume these exact same fields. This
/// is *not* the "unverified, assumed layout" scaffold the roadmap
/// originally anticipated (matching its own framing "blocked due to
/// unverified vertex-buffer layouts"), that framing turned out not to
/// hold for the Xbox variants specifically, once the reference tool's own
/// source was read directly.
///
/// One real gap remains: the PS2 `.blendSkin` (VIF-encoded, non-Xbox)
/// record is *not* covered here. `BlendSkin.cs`'s own `Load` is real and
/// working too, but its vertex extraction goes through a materially more
/// involved path (`VIFInterpreter`, several undocumented per-vertex bit-
/// packing steps in `CalculateData`) that this pass didn't have time to
/// port and verify, left for a future session, not guessed at here.

/// One `ModelX` vertex (28 bytes / `0x1C` on disk), real, confirmed
/// layout ported from `ModelX.cs`.
public struct XboxRigidVertex: Sendable, Equatable {
    public var position: SIMD3<Float>
    /// `PackedNormals`, real, decoded as a raw `uint32`. The reference
    /// tool's own comment on this exact field (`SkinX.cs`, which shares
    /// it) only guesses "Packed normals? (into 10-bit x3 + 2?)", never
    /// confirmed, so this build keeps it raw rather than unpacking a
    /// guessed bit layout.
    public var packedNormalsRaw: UInt32
    public var color: SIMD4<UInt8>
    public var uv: SIMD2<Float>

    public init(position: SIMD3<Float>, packedNormalsRaw: UInt32 = 0, color: SIMD4<UInt8> = SIMD4<UInt8>(255, 255, 255, 255), uv: SIMD2<Float> = .zero) {
        self.position = position
        self.packedNormalsRaw = packedNormalsRaw
        self.color = color
        self.uv = uv
    }
}

/// One rigid-triangle-group submodel of a `ModelX` record.
public struct XboxModelXSubModel: Sendable {
    /// Vertex count per triangle-strip-like group, `GroupList` in the
    /// reference, real but with no further documented meaning beyond "how
    /// `ToPLY`/`ToOBJ` walk the shared vertex list into triangles."
    public var groupList: [UInt32]
    public var vertices: [XboxRigidVertex]

    public init(groupList: [UInt32], vertices: [XboxRigidVertex]) {
        self.groupList = groupList
        self.vertices = vertices
    }
}

/// A decoded `ModelX` record (`SectionType.modelX`), Xbox's static
/// (non-skinned) mesh format. See this file's own top-of-file doc comment
/// for how confirmed this layout is.
public struct XboxModelXAsset: Sendable, Identifiable {
    public let id: UInt32
    public var subModels: [XboxModelXSubModel]

    public init(id: UInt32, subModels: [XboxModelXSubModel]) {
        self.id = id
        self.subModels = subModels
    }
}

/// One `SkinX`/`BlendSkinX` vertex (48 bytes / `0x30` on disk), real,
/// confirmed layout shared identically by both formats (`SkinX.cs`/
/// `BlendSkinX.cs`'s `VertexData` structs are byte-for-byte the same
/// through the base fields; `BlendSkinX` just appends per-blend-shape
/// deltas after).
public struct XboxSkinnedMorphVertex: Sendable, Equatable {
    public var position: SIMD3<Float>
    /// `Weight1`/`2`/`3`, real, decoded; the reference tool's own comment
    /// notes they "always" sum to 1.
    public var jointWeights: SIMD3<Float>
    public var jointIndices: SIMD3<UInt16>
    /// `UnkShort4`, "Confirmed always zero" per the reference tool's own
    /// comment. Kept, not assumed away, so a round-trip of real data with
    /// a non-zero value here (if one ever turns up) isn't silently lost.
    public var unkShort4: UInt16
    /// Same real-but-undecoded raw value as `XboxRigidVertex.
    /// packedNormalsRaw`.
    public var packedNormalsRaw: UInt32
    public var color: SIMD4<UInt8>
    public var uv: SIMD2<Float>
    /// Per-blend-shape position deltas for this vertex, index `n` is
    /// blend-shape `n`'s XYZ offset, applied additively on top of
    /// `position`. Always empty for a plain `SkinX` vertex (that format
    /// has no blend shapes at all); has exactly `blendShapeCount` entries
    /// (`XboxBlendSkinXAsset.blendShapeCount`) for a `BlendSkinX` vertex.
    public var blendShapeDeltas: [SIMD3<Float>]

    public init(
        position: SIMD3<Float>, jointWeights: SIMD3<Float> = .zero, jointIndices: SIMD3<UInt16> = .zero,
        unkShort4: UInt16 = 0, packedNormalsRaw: UInt32 = 0, color: SIMD4<UInt8> = SIMD4<UInt8>(255, 255, 255, 255),
        uv: SIMD2<Float> = .zero, blendShapeDeltas: [SIMD3<Float>] = []
    ) {
        self.position = position
        self.jointWeights = jointWeights
        self.jointIndices = jointIndices
        self.unkShort4 = unkShort4
        self.packedNormalsRaw = packedNormalsRaw
        self.color = color
        self.uv = uv
        self.blendShapeDeltas = blendShapeDeltas
    }
}

/// One submodel shared by `SkinX` and `BlendSkinX`, same real fields
/// (`MaterialID`/`GroupList`/`GroupJoints`/vertex data) in both reference
/// formats; only whether `XboxSkinnedMorphVertex.blendShapeDeltas` is
/// populated differs.
public struct XboxSkinXSubModel: Sendable {
    public var materialID: UInt32
    /// Vertex count per group, same role as `XboxModelXSubModel.groupList`.
    public var groupList: [UInt32]
    /// Joint indices per group (`GroupJoints` in the reference), real,
    /// decoded, parallel to `groupList` (one inner list per group).
    public var groupJoints: [[UInt32]]
    public var vertices: [XboxSkinnedMorphVertex]

    public init(materialID: UInt32, groupList: [UInt32], groupJoints: [[UInt32]], vertices: [XboxSkinnedMorphVertex]) {
        self.materialID = materialID
        self.groupList = groupList
        self.groupJoints = groupJoints
        self.vertices = vertices
    }
}

/// A decoded `SkinX` record (`SectionType.skinX`), Xbox's skinned
/// (jointed, non-morphing) mesh format.
public struct XboxSkinXAsset: Sendable, Identifiable {
    public let id: UInt32
    public var subModels: [XboxSkinXSubModel]

    public init(id: UInt32, subModels: [XboxSkinXSubModel]) {
        self.id = id
        self.subModels = subModels
    }
}

/// A decoded `BlendSkinX` record (`SectionType.blendSkinX`), Xbox's
/// skinned *and* morph-target ("blend shape") mesh format, the real thing
/// "Xbox Morphs" (roadmap item 4e) asked for. Same submodel/vertex shape
/// as `XboxSkinXAsset`, with every vertex's `blendShapeDeltas` populated
/// to `blendShapeCount` entries.
public struct XboxBlendSkinXAsset: Sendable, Identifiable {
    public let id: UInt32
    /// Real, decoded, how many blend shapes every submodel's every vertex
    /// carries a delta for.
    public var blendShapeCount: UInt32
    public var subModels: [XboxSkinXSubModel]

    public init(id: UInt32, blendShapeCount: UInt32, subModels: [XboxSkinXSubModel]) {
        self.id = id
        self.blendShapeCount = blendShapeCount
        self.subModels = subModels
    }
}
