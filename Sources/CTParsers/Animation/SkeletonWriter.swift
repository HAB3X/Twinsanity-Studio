import Foundation
import CTCore
import CTModels

/// Encodes a `SkeletonAsset` back to its real on-disk `GraphicsInfo` (OGI)
/// layout, the exact inverse of `GraphicsInfoParser.parse`, mirroring
/// that parser's own doc comment for the field layout.
///
/// Every byte the parser doesn't itself interpret, `boundingVolume`, each
/// collision entry's `header`/`rawBlobRemainder`, and
/// `collisionDataTrailer`, is written back completely verbatim from what
/// was captured at parse time, exactly like `AnimationWriter`'s handling
/// of `reservedPackerBits`: this doesn't invent meaning for any of it,
/// only preserves it. The one exception is `headerBytes`' four count
/// fields (`[0]` joint, `[1]` exitPoint, `[5]` modelLink, `[8]`
/// collisionData), which, like every packer word in `AnimationWriter` , 
/// are rebuilt fresh from this asset's own array counts rather than
/// trusted verbatim, so the record can never silently desync from the
/// arrays actually being written; the remaining header bytes (`[2]`
/// reactJointCount, `[6]` skinFlag, `[7]` blendSkinFlag, and the
/// still-unconfirmed rest) are preserved exactly as parsed.
///
/// Only scalar in-place edits are supported: `SkeletonInspectorView`
/// never adds or removes joints/exit points/model links/collision
/// entries, so this always emits a record exactly `node.byteSize` bytes
/// long, safe for `WorkspaceViewModel.patchedFileBytes(replacing:with:)`,
/// which requires an exact size match. Growing/shrinking any of those
/// arrays is not implemented here (it would also need the enclosing
/// chunk section rebuilt, which that patch path deliberately doesn't do).
public enum SkeletonWriter {
    public static func write(_ skeleton: SkeletonAsset) -> Data {
        var w = BinaryWriter()

        var header = skeleton.headerBytes.count == 16 ? skeleton.headerBytes : [UInt8](repeating: 0, count: 16)
        header[0] = UInt8(skeleton.joints.count)
        header[1] = UInt8(skeleton.exitPoints.count)
        header[5] = UInt8(skeleton.modelLinks.count)
        header[8] = UInt8(skeleton.collisionData.count)
        w.writeBytes(header)

        let bounding = skeleton.boundingVolume
        w.writeVector4(bounding.count > 0 ? bounding[0] : .zero)
        w.writeVector4(bounding.count > 1 ? bounding[1] : .zero)

        for joint in skeleton.joints {
            w.writeUInt32(joint.reactJointID)
            w.writeUInt32(joint.jointIndex)
            w.writeUInt32(joint.parentJointIndex)
            w.writeUInt32(joint.childJointAmount)
            w.writeUInt32(joint.childJointAmount2)
            writeRows(joint.matrix, expecting: 5, into: &w)
        }

        for exitPoint in skeleton.exitPoints {
            w.writeUInt32(exitPoint.parentJointIndex)
            w.writeUInt32(exitPoint.id)
            writeRows(exitPoint.matrix, expecting: 4, into: &w)
        }

        // Two separate trailing arrays (joint-index bytes, then model-ID
        // words), not interleaved, matches `GraphicsInfoParser`'s own
        // read order.
        if !skeleton.modelLinks.isEmpty {
            for link in skeleton.modelLinks { w.writeUInt8(UInt8(truncatingIfNeeded: link.jointIndex)) }
            for link in skeleton.modelLinks { w.writeUInt32(link.modelID) }
        }

        for skin in skeleton.skinTransforms {
            writeRows(skin.matrix, expecting: 4, into: &w)
        }

        w.writeUInt32(skeleton.skinID)
        w.writeUInt32(skeleton.blendSkinID)

        for entry in skeleton.collisionData {
            for value in entry.header { w.writeUInt16(value) }
            let blobSize = Int32(entry.positions.count * 16 + entry.rawBlobRemainder.count)
            w.writeInt32(blobSize)
            for position in entry.positions { w.writeVector4(position) }
            w.writeBytes(entry.rawBlobRemainder)
        }
        w.writeBytes(skeleton.collisionDataTrailer)

        return w.data
    }

    /// Writes exactly `count` rows, zero-filling any shortfall, guards
    /// against a hand-built/edited `matrix` array of the wrong length
    /// rather than silently under/over-running the record's fixed-width
    /// layout.
    private static func writeRows(_ rows: [SIMD4<Float>], expecting count: Int, into w: inout BinaryWriter) {
        for i in 0..<count {
            w.writeVector4(i < rows.count ? rows[i] : .zero)
        }
    }
}
