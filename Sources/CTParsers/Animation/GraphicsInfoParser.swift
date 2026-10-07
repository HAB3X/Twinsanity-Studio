import Foundation
import CTCore
import CTModels

/// Decodes a `GraphicsInfo` (OGI) record, bind-pose skeleton plus model/skin
/// links. Ported from `Twinsanity/Items/Code/GraphicsInfo.cs`.
///
/// Layout:
/// ```
/// byte[16]  HeaderVars     // [0]=jointCount [1]=exitPointCount [2]=reactJointCount
///                          // [5]=modelLinkCount [6]=skinFlag [7]=blendSkinFlag [8]=collisionDataCount
/// Pos coord1, coord2       // 2 x 16 bytes, bounding volume
/// Joint[jointCount]        // 5 x uint32, then 5 x Pos (16 bytes each) = 100 bytes
/// ExitPoint[exitPointCount]// 2 x uint32, then 4 x Pos = 72 bytes
/// byte[modelLinkCount]     // joint index per model link
/// uint32[modelLinkCount]   // model ID per model link (separate trailing array, not interleaved)
/// SkinTransform[jointCount]// 4 x Pos = 64 bytes each (reuses jointCount, not its own header field)
/// uint32 skinID
/// uint32 blendSkinID
/// GI_CollisionData[collisionDataCount]   // ushort[11] header + int32 blobSize + blob
///                                         // (blob's leading header[0] Vector4s decoded)
/// byte[collisionDataCount] trailer
/// ```
///
/// Every byte this parser doesn't itself interpret, `HeaderVars`,
/// Coord1/Coord2, each collision blob's undecoded remainder, and the
/// trailing per-entry byte array, is still captured verbatim onto
/// `SkeletonAsset` (`headerBytes`/`boundingVolume`/`rawBlobRemainder`/
/// `collisionDataTrailer`) so `SkeletonWriter` can round-trip a record
/// byte-for-byte without inventing meaning for any of it.
public enum GraphicsInfoParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> SkeletonAsset {
        let header = [UInt8](try cursor.readBytes(0x10))
        let jointCount = Int(header[0])
        let exitPointCount = Int(header[1])
        let modelLinkCount = Int(header[5])
        let collisionDataCount = Int(header[8])

        let coord1 = try cursor.readVector4() // Coord1 (bounding volume)
        let coord2 = try cursor.readVector4() // Coord2

        var joints: [Joint] = []
        joints.reserveCapacity(jointCount)
        for _ in 0..<jointCount {
            let reactJointID = try cursor.readUInt32()
            let jointIndex = try cursor.readUInt32()
            let parentJointIndex = try cursor.readUInt32()
            let childJointAmount = try cursor.readUInt32()
            let childJointAmount2 = try cursor.readUInt32()
            var matrix: [SIMD4<Float>] = []
            for _ in 0..<5 { matrix.append(try cursor.readVector4()) }
            joints.append(Joint(
                reactJointID: reactJointID, jointIndex: jointIndex, parentJointIndex: parentJointIndex,
                childJointAmount: childJointAmount, childJointAmount2: childJointAmount2, matrix: matrix
            ))
        }

        var exitPoints: [ExitPoint] = []
        exitPoints.reserveCapacity(exitPointCount)
        for _ in 0..<exitPointCount {
            let parentJointIndex = try cursor.readUInt32()
            let exitID = try cursor.readUInt32()
            var matrix: [SIMD4<Float>] = []
            for _ in 0..<4 { matrix.append(try cursor.readVector4()) }
            exitPoints.append(ExitPoint(id: exitID, parentJointIndex: parentJointIndex, matrix: matrix))
        }

        var modelLinks: [ModelLink] = []
        if modelLinkCount > 0 {
            var jointIndices: [UInt32] = []
            for _ in 0..<modelLinkCount { jointIndices.append(UInt32(try cursor.readUInt8())) }
            var modelIDs: [UInt32] = []
            for _ in 0..<modelLinkCount { modelIDs.append(try cursor.readUInt32()) }
            for i in 0..<modelLinkCount {
                modelLinks.append(ModelLink(jointIndex: jointIndices[i], modelID: modelIDs[i]))
            }
        }

        var skinTransforms: [SkinTransform] = []
        skinTransforms.reserveCapacity(jointCount)
        for _ in 0..<jointCount {
            var matrix: [SIMD4<Float>] = []
            for _ in 0..<4 { matrix.append(try cursor.readVector4()) }
            skinTransforms.append(SkinTransform(matrix: matrix))
        }

        let skinID = try cursor.readUInt32()
        let blendSkinID = try cursor.readUInt32()

        // "Collision Mask Alignment": `GI_CollisionData`, ported only as
        // far as `GraphicsInfo.cs`'s own `Load` actually decodes it (see
        // `GraphicsInfoCollisionData`'s doc comment): the header's first
        // count field (`header[0]`) selects a leading block of raw
        // `Vector4`s from the blob; the other 6 header-addressed
        // sub-blocks are consumed for correct stream positioning but never
        // further interpreted, matching the reference.
        var collisionData: [GraphicsInfoCollisionData] = []
        collisionData.reserveCapacity(collisionDataCount)
        for _ in 0..<collisionDataCount {
            var header: [UInt16] = []
            header.reserveCapacity(11)
            for _ in 0..<11 { header.append(try cursor.readUInt16()) }
            let blobSize = Int(try cursor.readInt32())
            let blobStart = cursor.position
            var positions: [SIMD4<Float>] = []
            let positionCount = Int(header[0])
            positions.reserveCapacity(positionCount)
            for _ in 0..<positionCount { positions.append(try cursor.readVector4()) }
            // Seek to the end of the declared blob regardless of how much
            // of it `positions` actually consumed, the remaining 6
            // sub-blocks are real bytes this parser doesn't decode yet,
            // not padding to skip blindly.
            let consumed = cursor.position - blobStart
            var remainder = Data()
            if consumed < blobSize {
                remainder = try cursor.readBytes(blobSize - consumed)
            }
            collisionData.append(GraphicsInfoCollisionData(header: header, positions: positions, rawBlobRemainder: remainder))
        }
        let collisionDataTrailer = [UInt8](try cursor.readBytes(collisionDataCount)) // trailing per-entry byte

        return SkeletonAsset(
            id: recordID, joints: joints, exitPoints: exitPoints, skinTransforms: skinTransforms,
            skinID: skinID, blendSkinID: blendSkinID, modelLinks: modelLinks, collisionData: collisionData,
            headerBytes: header, boundingVolume: [coord1, coord2], collisionDataTrailer: collisionDataTrailer
        )
    }
}
