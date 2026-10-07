import Foundation
import CTCore
import CTModels

/// Decodes a `DynamicSceneryData` record, ported from
/// `Twinsanity/Items/DynamicSceneryData.cs`. Top-level (tier 0) raw entry
/// in `.SM2` files (subID 4), see `RM2Parser.tier0Kind`'s `sm2` case.
///
/// Only the *resting* placement (static value, or first keyframe for an
/// animated channel) is extracted, see `DynamicSceneryPlacement`'s doc
/// comment. Every byte of the full per-channel animation curve data is
/// still read (it has to be, to stay correctly positioned for the next
/// model in the list), just not retained.
public enum DynamicSceneryDataParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> DynamicSceneryAsset {
        _ = try cursor.readUInt32() // Header1, unused by this reader
        let modelCount = try cursor.readUInt16()

        var placements: [DynamicSceneryPlacement] = []
        placements.reserveCapacity(Int(modelCount))
        for _ in 0..<modelCount {
            placements.append(try parseModel(&cursor))
        }

        return DynamicSceneryAsset(id: recordID, placements: placements)
    }

    private static func parseModel(_ cursor: inout BinaryCursor) throws -> DynamicSceneryPlacement {
        _ = try cursor.readUInt32() // UnkInt1
        let giCount = try cursor.readUInt32()
        for _ in 0..<giCount {
            _ = try cursor.readBytes(0x16) // GI_Type3.Header
            let blobLength = Int(try cursor.readInt32())
            _ = try cursor.readBytes(max(0, blobLength)) // GI_Type3.unkBlob
        }

        let frameCount = try cursor.readInt32()
        let packed = Int32(bitPattern: try cursor.readUInt32())
        let sizeHelper = try cursor.readInt16()
        let blobLength = dynamicBlobLength(packed: packed, sizeHelper: sizeHelper)
        let blobData = try cursor.readBytes(max(0, blobLength))

        let (position, rotation) = try parseMotionBlob(blobData, frameCount: Int(frameCount))

        _ = try cursor.readUInt8() // unkByte
        let modelID = try cursor.readUInt32()
        let boundingBoxMin = try cursor.readVector4()
        let boundingBoxMax = try cursor.readVector4()

        return DynamicSceneryPlacement(
            modelID: modelID,
            boundingBoxMin: boundingBoxMin,
            boundingBoxMax: boundingBoxMax,
            worldPosition: position,
            worldRotation: rotation
        )
    }

    /// `Model.unkBlobSizePacked`'s bit layout, ported exactly from the
    /// reference tool's inline expression in `Load` (`DynamicSceneryData.cs`).
    /// The shifts are arithmetic (sign-extending) in both C# and Swift for
    /// a signed `Int32`, so this only differs from the reference by being
    /// spelled out as a named function.
    private static func dynamicBlobLength(packed: Int32, sizeHelper: Int16) -> Int {
        let a = Int(packed & 0x7F) * 0x8
        let b = Int((packed >> 0x9) & 0x1FFC)
        let c = Int(packed >> 0x16) * Int(sizeHelper) * 0x4
        return a + b + c
    }

    /// Decodes the per-model motion blob: 4 header bytes, an unused
    /// `AnimInt`, then, for each of 7 channels (posX/Y/Z, rotX/Y/Z/W) , 
    /// either one static float (bit set in `AnimFlags`) or nothing yet
    /// (bit clear, value comes from the animated array below). Then, for
    /// every *animated* channel, `frameCount` more floats follow, and the
    /// reference tool's own reconciliation takes each animated channel's
    /// *first* frame as its effective resting value, replicated here
    /// rather than exposing the full curve, since nothing renders motion
    /// yet (see this file's top doc comment).
    private static func parseMotionBlob(_ data: Data, frameCount: Int) throws -> (SIMD3<Float>, SIMD4<Float>) {
        guard !data.isEmpty else { return (.zero, SIMD4(0, 0, 0, 0)) }
        var cursor = BinaryCursor(data: data)
        _ = try cursor.readUInt8() // AnimByte1
        _ = try cursor.readUInt8() // AnimByte2
        let flags = try cursor.readUInt8()
        _ = try cursor.readUInt8() // AnimByte4
        _ = try cursor.readUInt32() // AnimInt

        var values: [Float?] = Array(repeating: nil, count: 7) // posX, posY, posZ, rotX, rotY, rotZ, rotW
        for channel in 0..<7 {
            if flags & (1 << channel) != 0 {
                values[channel] = try cursor.readFloat32()
            }
        }

        var firstFrame: [Float?] = Array(repeating: nil, count: 7)
        for _ in 0..<max(0, frameCount) {
            for channel in 0..<7 where flags & (1 << channel) == 0 {
                let value = try cursor.readFloat32()
                if firstFrame[channel] == nil { firstFrame[channel] = value }
            }
        }
        for channel in 0..<7 where values[channel] == nil {
            values[channel] = firstFrame[channel] ?? 0
        }

        let position = SIMD3<Float>(values[0] ?? 0, values[1] ?? 0, values[2] ?? 0)
        let rotation = SIMD4<Float>(values[3] ?? 0, values[4] ?? 0, values[5] ?? 0, values[6] ?? 0)
        return (position, rotation)
    }
}
