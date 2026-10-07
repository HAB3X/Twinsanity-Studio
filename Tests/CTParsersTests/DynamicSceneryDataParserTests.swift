import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class DynamicSceneryDataParserTests: XCTestCase {
    func testEmptyListDecodesToNoPlacements() throws {
        var w = BinaryWriter()
        w.writeUInt32(0) // Header1
        w.writeUInt16(0) // ModelCount

        var cursor = BinaryCursor(data: w.data)
        let scenery = try DynamicSceneryDataParser.parse(&cursor, recordID: 1)

        XCTAssertTrue(scenery.placements.isEmpty)
        XCTAssertEqual(cursor.position, w.count)
    }

    /// Byte count cross-checked by hand against
    /// `DynamicSceneryData.GetSize()` (`Twinsanity/Items/DynamicSceneryData.cs`):
    /// 6 (header) + 55 per model (8 fixed fields + 0 GI entries + 0-byte blob).
    func testOneStaticModelWithNoAnimatedChannels() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)  // Header1
        w.writeUInt16(1)  // ModelCount

        w.writeUInt32(0)  // UnkInt1
        w.writeUInt32(0)  // GI_amount
        w.writeInt32(0)   // unkInt2 (frame count)
        w.writeUInt32(0)  // unkBlobSizePacked -> blob length 0
        w.writeInt16(0)   // unkBlobSizeHelper
        // dynBlob is 0 bytes here (empty channel data).
        w.writeUInt8(0)   // unkByte
        w.writeUInt32(42) // ModelID
        w.writeFloat32(-1); w.writeFloat32(-1); w.writeFloat32(-1); w.writeFloat32(1) // bbox min
        w.writeFloat32(1); w.writeFloat32(1); w.writeFloat32(1); w.writeFloat32(1)    // bbox max

        XCTAssertEqual(w.count, 6 + 55)

        var cursor = BinaryCursor(data: w.data)
        let scenery = try DynamicSceneryDataParser.parse(&cursor, recordID: 2)

        XCTAssertEqual(scenery.placements.count, 1)
        XCTAssertEqual(scenery.placements[0].modelID, 42)
        XCTAssertEqual(scenery.placements[0].worldPosition, .zero)
        XCTAssertEqual(cursor.position, w.count)
    }

    /// Exercises the motion blob's static-channel path: `AnimFlags = 0x7F`
    /// (all 7 channels static) means the blob holds exactly one float per
    /// channel, no animated arrays. `unkBlobSizePacked` is bit-packed (not
    /// a plain byte count), `18432` was chosen so the reference formula's
    /// middle term (`(packed >> 9) & 0x1FFC`) evaluates to exactly 36, the
    /// blob's real size (4 header bytes + 4-byte AnimInt + 7×4 static floats).
    func testAllChannelsStaticUsesTheSingleStaticFloatPerChannel() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeUInt16(1)

        w.writeUInt32(0)  // UnkInt1
        w.writeUInt32(0)  // GI_amount
        w.writeInt32(0)   // frame count, irrelevant, nothing is animated
        w.writeUInt32(18432) // unkBlobSizePacked -> blob length 36
        w.writeInt16(0)   // unkBlobSizeHelper, unused (packed's high term is 0)

        // The 36-byte motion blob itself.
        w.writeUInt8(0); w.writeUInt8(0)      // AnimByte1, AnimByte2
        w.writeUInt8(0x7F)                    // AnimFlags, all 7 channels static
        w.writeUInt8(0)                       // AnimByte4
        w.writeUInt32(0)                      // AnimInt
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3)   // posX, posY, posZ
        w.writeFloat32(4); w.writeFloat32(5); w.writeFloat32(6); w.writeFloat32(7) // rotX..W

        w.writeUInt8(0)    // unkByte
        w.writeUInt32(9)   // ModelID
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)

        var cursor = BinaryCursor(data: w.data)
        let scenery = try DynamicSceneryDataParser.parse(&cursor, recordID: 4)

        XCTAssertEqual(scenery.placements.count, 1)
        let placement = scenery.placements[0]
        XCTAssertEqual(placement.modelID, 9)
        XCTAssertEqual(placement.worldPosition, SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(placement.worldRotation, SIMD4<Float>(4, 5, 6, 7))
        XCTAssertEqual(cursor.position, w.count)
    }
}
