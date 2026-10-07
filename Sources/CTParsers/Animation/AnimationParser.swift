import Foundation
import CTCore
import CTModels

/// Decodes an `Animation` record, two independent curve tracks (body, then
/// facial), each a joint-indirection table over a shared static/animated
/// value pool. Ported from `Twinsanity/Items/Code/Animation.cs`.
public enum AnimationParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> AnimationAsset {
        // Real, verified-against-reference leading field (`Animation.
        // Bitfield`, `Animation.cs:12,78`), 4 bytes read once, before the
        // body track's own packer/frame-count, and never repeated for the
        // facial track. Its meaning isn't decoded anywhere in the reference
        // tool beyond being written back verbatim, so it's consumed here
        // purely to keep every following field's offset correct; skipping
        // it (the previous state of this parser) silently shifted the
        // entire record 4 bytes early, every joint setting, static
        // transform, and per-frame value decoded from the wrong bytes, and
        // `totalFrames` itself decoded as the low 16 bits of what should
        // have been `AnimationDataPacker`, producing implausible frame
        // counts (seen in the wild: 23,730) and a garbled pose.
        let bitfield = try cursor.readUInt32()
        let body = try readTrack(&cursor, requireNonEmpty: true)
        let facial = try readTrack(&cursor, requireNonEmpty: false)
        return AnimationAsset(id: recordID, bitfield: bitfield, body: body, facial: facial)
    }

    /// `requireNonEmpty` mirrors the original's asymmetry: the body track's
    /// packer/frame-count fields are always followed by data, but the facial
    /// track only actually has joint/transform/frame data when its computed
    /// `facialAnimationDataSize` is nonzero (`Animation.cs:104-131`), some
    /// records carry a facial packer field that describes zero joints and no
    /// trailing data at all.
    private static func readTrack(_ cursor: inout BinaryCursor, requireNonEmpty: Bool) throws -> AnimationTrack {
        let packer = try cursor.readUInt32()
        let totalFrames = try cursor.readUInt16()

        let jointCount = Int(packer & 0x7F)
        let transformationCount = Int((packer >> 0xA) & 0xFFE) / 2
        let componentsPerFrame = Int(packer >> 0x16)
        // Bits 7–10, see `AnimationTrack.reservedPackerBits`'s own doc
        // comment for why these specific 4 bits (and no others) need to
        // survive a round-trip untouched.
        let reservedPackerBits = (packer >> 7) & 0xF

        let dataSize = jointCount * 8 + transformationCount * 2 + componentsPerFrame * Int(totalFrames) * 2
        guard requireNonEmpty || dataSize > 0 else {
            return AnimationTrack(jointSettings: [], staticTransforms: [], frames: [], componentsPerFrame: componentsPerFrame, reservedPackerBits: reservedPackerBits)
        }

        var jointSettings: [AnimJointSettings] = []
        jointSettings.reserveCapacity(jointCount)
        for _ in 0..<jointCount {
            jointSettings.append(AnimJointSettings(
                flags: try cursor.readUInt16(),
                transformationChoice: try cursor.readUInt16(),
                transformationIndex: try cursor.readUInt16(),
                animatedTransformIndex: try cursor.readUInt16()
            ))
        }

        var staticTransforms: [AnimStaticTransform] = []
        staticTransforms.reserveCapacity(transformationCount)
        for _ in 0..<transformationCount {
            staticTransforms.append(AnimStaticTransform(stored: try cursor.readInt16()))
        }

        var frames: [AnimFrame] = []
        frames.reserveCapacity(Int(totalFrames))
        for _ in 0..<totalFrames {
            var values: [Int16] = []
            values.reserveCapacity(componentsPerFrame)
            for _ in 0..<componentsPerFrame {
                values.append(try cursor.readInt16())
            }
            frames.append(AnimFrame(values: values))
        }

        return AnimationTrack(jointSettings: jointSettings, staticTransforms: staticTransforms, frames: frames, componentsPerFrame: componentsPerFrame, reservedPackerBits: reservedPackerBits)
    }
}
