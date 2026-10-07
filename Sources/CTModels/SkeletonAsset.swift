import Foundation
import simd

/// Shared by every `Codable` conformance in this file that flattens a
/// `[SIMD4<Float>]` matrix to `Data`, see `Joint`'s own doc comment for
/// why. A single named helper (rather than inlining the `stride`/`map`
/// expression at each call site) also sidesteps a real Swift type-checker
/// timeout the inline form hits here.
private func unflattenVector4Array(_ raw: [Float]) -> [SIMD4<Float>] {
    var result: [SIMD4<Float>] = []
    result.reserveCapacity(raw.count / 4)
    var i = 0
    while i + 4 <= raw.count {
        result.append(SIMD4(raw[i], raw[i + 1], raw[i + 2], raw[i + 3]))
        i += 4
    }
    return result
}

/// A single skeleton joint. Note this is **matrix-based, not quaternion +
/// translation**, `matrix` holds 5 raw XYZW rows as stored on disk
/// (`GraphicsInfo.Joint.Matrix`, `Twinsanity/Items/Code/GraphicsInfo.cs:402-410`).
/// Interpreting those 5 rows into a usable 4x4 transform is left to the
/// animation/skinning layer, since the original tool never fully documents the
/// exact row semantics either (bind pose + something auxiliary per the parser's
/// own comments).
public struct Joint: Sendable, Identifiable, Codable {
    public var id: UInt32 { jointIndex }
    public var reactJointID: UInt32
    public var jointIndex: UInt32
    public var parentJointIndex: UInt32
    public var childJointAmount: UInt32
    public var childJointAmount2: UInt32
    public var matrix: [SIMD4<Float>] // 5 rows

    public init(reactJointID: UInt32, jointIndex: UInt32, parentJointIndex: UInt32, childJointAmount: UInt32, childJointAmount2: UInt32, matrix: [SIMD4<Float>]) {
        self.reactJointID = reactJointID
        self.jointIndex = jointIndex
        self.parentJointIndex = parentJointIndex
        self.childJointAmount = childJointAmount
        self.childJointAmount2 = childJointAmount2
        self.matrix = matrix
    }

    private enum CodingKeys: String, CodingKey {
        case reactJointID, jointIndex, parentJointIndex, childJointAmount, childJointAmount2, matrix
    }

    /// Custom `Codable`, same "ScanCache Codable perf gotcha" this
    /// project's already fixed twice elsewhere (`MeshSubmesh`,
    /// `AnimationTrack`): `[SIMD4<Float>]` under synthesized `Codable`
    /// wraps every row in its own container. `matrix` is always a handful
    /// of rows, so the *scalar* `UInt32` fields stay plain `Codable` , 
    /// only the array needs flattening.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reactJointID = try container.decode(UInt32.self, forKey: .reactJointID)
        jointIndex = try container.decode(UInt32.self, forKey: .jointIndex)
        parentJointIndex = try container.decode(UInt32.self, forKey: .parentJointIndex)
        childJointAmount = try container.decode(UInt32.self, forKey: .childJointAmount)
        childJointAmount2 = try container.decode(UInt32.self, forKey: .childJointAmount2)
        let raw = try container.decode(Data.self, forKey: .matrix).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        matrix = unflattenVector4Array(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reactJointID, forKey: .reactJointID)
        try container.encode(jointIndex, forKey: .jointIndex)
        try container.encode(parentJointIndex, forKey: .parentJointIndex)
        try container.encode(childJointAmount, forKey: .childJointAmount)
        try container.encode(childJointAmount2, forKey: .childJointAmount2)
        let flat = matrix.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        try container.encode(flat.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .matrix)
    }
}

public struct ExitPoint: Sendable, Identifiable, Codable {
    public var id: UInt32
    public var parentJointIndex: UInt32
    public var matrix: [SIMD4<Float>] // 4 rows

    public init(id: UInt32, parentJointIndex: UInt32, matrix: [SIMD4<Float>]) {
        self.id = id
        self.parentJointIndex = parentJointIndex
        self.matrix = matrix
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentJointIndex, matrix
    }

    /// Same fix as `Joint`'s own Codable, see that type's doc comment.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt32.self, forKey: .id)
        parentJointIndex = try container.decode(UInt32.self, forKey: .parentJointIndex)
        let raw = try container.decode(Data.self, forKey: .matrix).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        matrix = unflattenVector4Array(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(parentJointIndex, forKey: .parentJointIndex)
        let flat = matrix.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        try container.encode(flat.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .matrix)
    }
}

/// Column-major skinning transform per joint (`GraphicsInfo.SkinTransform`).
public struct SkinTransform: Sendable, Codable {
    public var matrix: [SIMD4<Float>] // 4 rows

    public init(matrix: [SIMD4<Float>]) {
        self.matrix = matrix
    }

    private enum CodingKeys: String, CodingKey {
        case matrix
    }

    /// Same fix as `Joint`'s own Codable, see that type's doc comment.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(Data.self, forKey: .matrix).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        matrix = unflattenVector4Array(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let flat = matrix.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        try container.encode(flat.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .matrix)
    }
}

public struct ModelLink: Sendable, Codable {
    public var jointIndex: UInt32
    public var modelID: UInt32

    public init(jointIndex: UInt32, modelID: UInt32) {
        self.jointIndex = jointIndex
        self.modelID = modelID
    }
}

/// "Collision Mask Alignment", one `GI_CollisionData` entry
/// (`GraphicsInfo.cs`'s `GI_CollisionData`): a per-object collision blob,
/// keyed to this specific model/skeleton, not the level-wide `ColData`
/// mesh (`CollisionMesh`), see that type's own doc comment for why those
/// two are unrelated. Ported only as far as the reference tool's *own*
/// code actually decodes it: the header's first count field selects a
/// block of raw `Vector4`s (`positions` here) from the blob; the
/// reference itself never further interprets the remaining 6 header-
/// addressed blocks, so this doesn't invent a meaning for them either , 
/// `rawBlobRemainder` keeps those untouched bytes around verbatim
/// (currently unused beyond that first block) so `SkeletonWriter` can
/// reproduce the whole blob byte-for-byte without guessing at their
/// layout.
public struct GraphicsInfoCollisionData: Sendable, Codable {
    /// The 11 `UInt16` header fields exactly as stored, element counts
    /// and byte offsets into the blob for 7 sub-blocks, only the first of
    /// which (`positions`) the reference tool's own code ever reads.
    public var header: [UInt16]
    /// Raw `Vector4`s from the blob's first sub-block (`header[0]` many) , 
    /// real, decoded per-object coordinates; not confirmed to be
    /// positions-only vs. a mixed position/radius encoding, so no further
    /// semantic (e.g. "hull vertex") is claimed beyond "this many real
    /// vectors, in this order."
    public var positions: [SIMD4<Float>]
    /// Every blob byte after `positions` up to the entry's declared
    /// `blobSize`, the other 6 header-addressed sub-blocks, kept
    /// completely uninterpreted (see this type's own top doc comment) so a
    /// writer can round-trip them exactly.
    public var rawBlobRemainder: Data

    public init(header: [UInt16], positions: [SIMD4<Float>], rawBlobRemainder: Data = Data()) {
        self.header = header
        self.positions = positions
        self.rawBlobRemainder = rawBlobRemainder
    }

    private enum CodingKeys: String, CodingKey {
        case header, positions, rawBlobRemainder
    }

    /// Same fix as `Joint`'s own Codable, see that type's doc comment.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decode(Data.self, forKey: .header).withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        let raw = try container.decode(Data.self, forKey: .positions).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        positions = unflattenVector4Array(raw)
        rawBlobRemainder = try container.decodeIfPresent(Data.self, forKey: .rawBlobRemainder) ?? Data()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(header.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .header)
        let flat = positions.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        try container.encode(flat.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .positions)
        try container.encode(rawBlobRemainder, forKey: .rawBlobRemainder)
    }
}

/// A fully decoded `GraphicsInfo` (OGI) record: bind-pose skeleton plus links to
/// the skin/blend-skin/model records it drives.
public struct SkeletonAsset: Sendable, Identifiable, Codable {
    public let id: UInt32
    public var joints: [Joint]
    public var exitPoints: [ExitPoint]
    public var skinTransforms: [SkinTransform]
    public var skinID: UInt32
    public var blendSkinID: UInt32
    public var modelLinks: [ModelLink]
    /// "Collision Mask Alignment", every per-object `GI_CollisionData`
    /// entry this `GraphicsInfo` carries. Empty for the many objects that
    /// have none (`collisionDataCount == 0` on disk).
    public var collisionData: [GraphicsInfoCollisionData]
    /// The record's raw 16-byte `HeaderVars` exactly as stored on disk
    /// (see `GraphicsInfoParser`'s own doc comment for the field layout).
    /// Indices `[0]`/`[1]`/`[5]`/`[8]` are this type's own
    /// joint/exitPoint/modelLink/collisionData counts, re-derived from the
    /// arrays above whenever `SkeletonWriter` writes this record back out;
    /// the rest, `[2]` reactJointCount, `[6]` skinFlag, `[7]`
    /// blendSkinFlag, and the still-unconfirmed remaining bytes, are kept
    /// completely verbatim so a writer never has to invent what they mean.
    public var headerBytes: [UInt8]
    /// `GraphicsInfoParser`'s Coord1/Coord2, a bounding-volume pair the
    /// reference tool's own `GraphicsInfo.Load` reads but never
    /// interprets any further, so kept here only for round-tripping, not
    /// claimed as (e.g.) "min/max corners" or any more specific semantic.
    /// Always exactly 2 rows: `[coord1, coord2]`.
    public var boundingVolume: [SIMD4<Float>]
    /// The `byte[collisionDataCount]` trailer that follows every
    /// `GI_CollisionData` entry (`GraphicsInfoParser`'s own doc comment) , 
    /// one uninterpreted byte per `collisionData` entry, in the same
    /// order, kept verbatim for round-tripping.
    public var collisionDataTrailer: [UInt8]

    public init(
        id: UInt32, joints: [Joint], exitPoints: [ExitPoint], skinTransforms: [SkinTransform], skinID: UInt32, blendSkinID: UInt32, modelLinks: [ModelLink],
        collisionData: [GraphicsInfoCollisionData] = [],
        headerBytes: [UInt8] = [UInt8](repeating: 0, count: 16),
        boundingVolume: [SIMD4<Float>] = [SIMD4<Float>](repeating: .zero, count: 2),
        collisionDataTrailer: [UInt8] = []
    ) {
        self.id = id
        self.joints = joints
        self.exitPoints = exitPoints
        self.skinTransforms = skinTransforms
        self.skinID = skinID
        self.blendSkinID = blendSkinID
        self.modelLinks = modelLinks
        self.collisionData = collisionData
        self.headerBytes = headerBytes
        self.boundingVolume = boundingVolume
        self.collisionDataTrailer = collisionDataTrailer
    }

    /// Builds the parent/child joint tree, replicating
    /// `GraphicsInfo.BuildSkeleton` (`GraphicsInfo.cs:301-330`): joint 0 is
    /// always the root; every other joint attaches under whichever joint has a
    /// matching `jointIndex`, looked up by value (not array position).
    ///
    /// Groups every joint by its `parentJointIndex` once, up front, rather
    /// than re-filtering the full joint list once per node (the previous
    /// approach was O(joints²)). This matters because the hierarchy this
    /// builds is 100% invariant across animation frames, only each joint's
    /// *transform* changes frame to frame, yet `AnimationSkeletonBinding`
    /// calls `buildTree()` fresh multiple times per rendered frame during
    /// 30fps playback, so a quadratic rebuild here was real, repeated,
    /// avoidable work every single frame.
    public func buildTree() -> SkeletonTreeNode? {
        guard let rootJoint = joints.first else { return nil }

        var childrenByParentIndex: [UInt32: [Joint]] = [:]
        for joint in joints.dropFirst() {
            childrenByParentIndex[joint.parentJointIndex, default: []].append(joint)
        }

        // Guards against more than just a joint being its own direct
        // parent: a malformed/corrupt file could have a longer
        // `parentJointIndex` cycle (A's parent is B, B's parent is A),
        // which would otherwise recurse forever, same "don't let a
        // corrupt file crash the app via runaway indirection" reasoning as
        // `AssetResolver.resolveModelID`'s depth guard on `LodModel` chains.
        var visited: Set<UInt32> = [rootJoint.jointIndex]
        func build(_ joint: Joint) -> SkeletonTreeNode {
            let childJoints = (childrenByParentIndex[joint.jointIndex] ?? []).filter { !visited.contains($0.jointIndex) }
            for child in childJoints { visited.insert(child.jointIndex) }
            return SkeletonTreeNode(joint: joint, children: childJoints.map(build))
        }
        return build(rootJoint)
    }
}

/// Value-type joint tree node for SwiftUI `OutlineGroup`/skinning traversal.
public struct SkeletonTreeNode: Sendable, Identifiable {
    public var id: UInt32 { joint.jointIndex }
    public var joint: Joint
    public var children: [SkeletonTreeNode]
}
