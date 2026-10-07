import Foundation
import CTCore
import CTModels

/// Decodes `ModelX`/`SkinX`/`BlendSkinX` records, see `XboxMeshAssets.swift`'s
/// top-of-file doc comment for exactly how confirmed this layout is (real,
/// ported from the reference tool's own working `Load` methods, not this
/// project's own guess). Every read goes through `BinaryCursor`, which is
/// itself bounds-checked and throws on truncation, so a genuinely
/// corrupt/truncated record surfaces as a real thrown error rather than
/// silently returning a partial or garbage mesh.
public enum XboxMeshParser {
    /// Ported from `ModelX.cs`'s `Load`.
    public static func parseModelX(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> XboxModelXAsset {
        let subModelCount = try cursor.readInt32()
        var subModels: [XboxModelXSubModel] = []
        subModels.reserveCapacity(cursor.safeReserveCount(subModelCount, elementSize: 16))
        for _ in 0..<max(0, subModelCount) {
            let vertexCount = try cursor.readInt32()
            _ = try cursor.readUInt32() // DataSize, redundant, vertexCount * 0x1C
            let groupCount = try cursor.readUInt32()

            var groupList: [UInt32] = []
            groupList.reserveCapacity(cursor.safeReserveCount(groupCount, elementSize: 4))
            for _ in 0..<groupCount { groupList.append(try cursor.readUInt32()) }

            var vertices: [XboxRigidVertex] = []
            vertices.reserveCapacity(cursor.safeReserveCount(vertexCount, elementSize: 28))
            for _ in 0..<max(0, vertexCount) {
                vertices.append(try parseRigidVertex(&cursor))
            }
            _ = try cursor.readUInt32() // real trailing zero, confirmed always zero by the reference tool

            subModels.append(XboxModelXSubModel(groupList: groupList, vertices: vertices))
        }
        return XboxModelXAsset(id: recordID, subModels: subModels)
    }

    /// Ported from `SkinX.cs`'s `Load`.
    public static func parseSkinX(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> XboxSkinXAsset {
        let subModelCount = try cursor.readInt32()
        var subModels: [XboxSkinXSubModel] = []
        subModels.reserveCapacity(cursor.safeReserveCount(subModelCount, elementSize: 20))
        for _ in 0..<max(0, subModelCount) {
            subModels.append(try parseSkinnedSubModel(&cursor, blendShapeCount: 0))
        }
        return XboxSkinXAsset(id: recordID, subModels: subModels)
    }

    /// Ported from `BlendSkinX.cs`'s `Load`.
    public static func parseBlendSkinX(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> XboxBlendSkinXAsset {
        let subModelCount = try cursor.readInt32()
        let blendShapeCount = try cursor.readUInt32()
        var subModels: [XboxSkinXSubModel] = []
        subModels.reserveCapacity(cursor.safeReserveCount(subModelCount, elementSize: 20))
        for _ in 0..<max(0, subModelCount) {
            subModels.append(try parseSkinnedSubModel(&cursor, blendShapeCount: blendShapeCount))
        }
        return XboxBlendSkinXAsset(id: recordID, blendShapeCount: blendShapeCount, subModels: subModels)
    }

    // MARK: - Shared pieces

    private static func parseRigidVertex(_ cursor: inout BinaryCursor) throws -> XboxRigidVertex {
        let x = try cursor.readFloat32()
        let y = try cursor.readFloat32()
        let z = try cursor.readFloat32()
        let packedNormals = try cursor.readUInt32()
        let r = try cursor.readUInt8()
        let g = try cursor.readUInt8()
        let b = try cursor.readUInt8()
        let a = try cursor.readUInt8()
        let u = try cursor.readFloat32()
        let v = try cursor.readFloat32()
        return XboxRigidVertex(
            position: SIMD3(x, y, z), packedNormalsRaw: packedNormals,
            color: SIMD4(r, g, b, a), uv: SIMD2(u, v)
        )
    }

    /// `SkinX`/`BlendSkinX` share this exact submodel shape, `Load`'s own
    /// group/joint/vertex-block reads are byte-for-byte identical between
    /// the two reference types, differing only in whether the trailing
    /// per-blend-shape delta block (present only when `blendShapeCount >
    /// 0`) follows. Ported from both `SkinX.cs.Load` and
    /// `BlendSkinX.cs.Load`.
    private static func parseSkinnedSubModel(_ cursor: inout BinaryCursor, blendShapeCount: UInt32) throws -> XboxSkinXSubModel {
        let materialID = try cursor.readUInt32()
        _ = try cursor.readUInt32() // DataSize, redundant, vertexCount * 0x30
        let vertexCount = try cursor.readInt32()
        _ = try cursor.readUInt32() // GroupJointCount, redundant, sum of every group's own joint count
        let groupCount = try cursor.readUInt32()

        var groupList: [UInt32] = []
        groupList.reserveCapacity(cursor.safeReserveCount(groupCount, elementSize: 4))
        for _ in 0..<groupCount { groupList.append(try cursor.readUInt32()) }

        var jointCountList: [UInt32] = []
        jointCountList.reserveCapacity(cursor.safeReserveCount(groupCount, elementSize: 4))
        for _ in 0..<groupCount { jointCountList.append(try cursor.readUInt32()) }

        var groupJoints: [[UInt32]] = []
        groupJoints.reserveCapacity(Int(groupCount))
        for jointCount in jointCountList {
            var joints: [UInt32] = []
            joints.reserveCapacity(cursor.safeReserveCount(jointCount, elementSize: 4))
            for _ in 0..<jointCount { joints.append(try cursor.readUInt32()) }
            groupJoints.append(joints)
        }

        var vertices: [XboxSkinnedMorphVertex] = []
        vertices.reserveCapacity(cursor.safeReserveCount(vertexCount, elementSize: 48))
        for _ in 0..<max(0, vertexCount) {
            vertices.append(try parseSkinnedVertex(&cursor))
        }

        // Trailing blend-shape delta block: `BlendSkinX.Load` walks it
        // blend-shape-major, vertex-minor (outer loop over shapes, inner
        // over vertices), ported exactly, then transposed into each
        // vertex's own `blendShapeDeltas` so a caller doesn't need to know
        // that on-disk ordering.
        if blendShapeCount > 0 {
            var deltasByShape: [[SIMD3<Float>]] = []
            deltasByShape.reserveCapacity(Int(blendShapeCount))
            for _ in 0..<blendShapeCount {
                var shapeDeltas: [SIMD3<Float>] = []
                shapeDeltas.reserveCapacity(vertices.count)
                for _ in 0..<vertices.count {
                    shapeDeltas.append(try cursor.readVector3())
                }
                deltasByShape.append(shapeDeltas)
            }
            for vertexIndex in vertices.indices {
                vertices[vertexIndex].blendShapeDeltas = deltasByShape.map { $0[vertexIndex] }
            }
        }

        return XboxSkinXSubModel(materialID: materialID, groupList: groupList, groupJoints: groupJoints, vertices: vertices)
    }

    private static func parseSkinnedVertex(_ cursor: inout BinaryCursor) throws -> XboxSkinnedMorphVertex {
        let x = try cursor.readFloat32()
        let y = try cursor.readFloat32()
        let z = try cursor.readFloat32()
        let w1 = try cursor.readFloat32()
        let w2 = try cursor.readFloat32()
        let w3 = try cursor.readFloat32()
        let j1 = try cursor.readUInt16()
        let j2 = try cursor.readUInt16()
        let j3 = try cursor.readUInt16()
        let unkShort4 = try cursor.readUInt16()
        let packedNormals = try cursor.readUInt32()
        let r = try cursor.readUInt8()
        let g = try cursor.readUInt8()
        let b = try cursor.readUInt8()
        let a = try cursor.readUInt8()
        let u = try cursor.readFloat32()
        let v = try cursor.readFloat32()
        return XboxSkinnedMorphVertex(
            position: SIMD3(x, y, z), jointWeights: SIMD3(w1, w2, w3), jointIndices: SIMD3(j1, j2, j3),
            unkShort4: unkShort4, packedNormalsRaw: packedNormals, color: SIMD4(r, g, b, a), uv: SIMD2(u, v)
        )
    }
}
