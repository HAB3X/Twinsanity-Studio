import Foundation
import CTCore
import CTModels

/// Encodes an `AnimationAsset` back to its real on-disk layout, the exact
/// inverse of `AnimationParser.parse`, ported from `Twinsanity/Items/Code/
/// Animation.cs`'s real `Save` (mirrors `Editors/AnimationEditor.cs` in the
/// reference tool, specifically its "Add/Delete Timeline" (frame)
/// buttons). Every packer word is rebuilt fresh from this track's own
/// `jointSettings.count`/`staticTransforms.count`/`componentsPerFrame`,
/// with `reservedPackerBits` folded back into the 4 bits `Animation.Save`
/// itself never touches, see that property's own doc comment.
public enum AnimationWriter {
    public static func write(_ animation: AnimationAsset) -> Data {
        var w = BinaryWriter()
        w.writeUInt32(animation.bitfield)
        writeTrack(animation.body, into: &w)
        writeTrack(animation.facial, into: &w)
        return w.data
    }

    private static func writeTrack(_ track: AnimationTrack, into w: inout BinaryWriter) {
        let jointBits = UInt32(track.jointSettings.count) & 0x7F
        let transformBits = (UInt32(track.staticTransforms.count * 2) & 0xFFE) << 0xA
        let componentBits = UInt32(track.componentsPerFrame) << 0x16
        let reservedBits = (track.reservedPackerBits & 0xF) << 7
        let packer = jointBits | transformBits | componentBits | reservedBits
        w.writeUInt32(packer)
        w.writeUInt16(UInt16(track.totalFrames))

        for joint in track.jointSettings {
            w.writeUInt16(joint.flags)
            w.writeUInt16(joint.transformationChoice)
            w.writeUInt16(joint.transformationIndex)
            w.writeUInt16(joint.animatedTransformIndex)
        }
        for transform in track.staticTransforms {
            w.writeInt16(transform.stored)
        }
        for frame in track.frames {
            for value in frame.values {
                w.writeInt16(value)
            }
        }
    }
}
