import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// `SkeletonWriter`, the write-back half of `GraphicsInfoParser`. Every
/// test here proves `parse(write(parse(x))) == parse(x)` (and, for the
/// unmodified case, `write(parse(x)) == x` bit-for-bit), the same
/// discipline `AnimationWriterTests` holds `AnimationWriter` to.
final class SkeletonWriterTests: XCTestCase {
    /// Builds a fully valid `GraphicsInfo` record with 2 joints (root +
    /// child), no exit points/model links, and nonzero values in every
    /// byte this parser doesn't itself interpret, `headerBytes`'
    /// reserved slots and the bounding-volume pair, so a naive writer
    /// that zero-fills or drops them gets caught.
    private func buildRecord(jointCount: UInt8 = 2, skinID: UInt32 = 42, blendSkinID: UInt32 = 43) -> Data {
        var w = BinaryWriter()
        var header = [UInt8](repeating: 0, count: 16)
        header[0] = jointCount
        header[1] = 0 // exitPointCount
        header[2] = 7 // reactJointCount, real, uninterpreted-by-this-parser byte
        header[5] = 0 // modelLinkCount
        header[6] = 1 // skinFlag, real, uninterpreted-by-this-parser byte
        header[7] = 1 // blendSkinFlag, real, uninterpreted-by-this-parser byte
        header[8] = 0 // collisionDataCount
        header[9] = 0xAB // padding tail, still real on-disk bytes
        w.writeBytes(header)

        // Coord1, Coord2 (bounding volume), nonzero, to prove these
        // survive a round trip rather than getting discarded.
        for v: Float in [1, 2, 3, 4, 5, 6, 7, 8] { w.writeFloat32(v) }

        for joint in 0..<Int(jointCount) {
            w.writeUInt32(UInt32(100 + joint)) // reactJointID
            w.writeUInt32(UInt32(joint)) // jointIndex
            w.writeUInt32(joint == 0 ? 0 : 0) // parentJointIndex (both attach to root)
            w.writeUInt32(joint == 0 ? 1 : 0) // childJointAmount
            w.writeUInt32(0) // childJointAmount2
            for row in 0..<5 {
                for axis in 0..<4 { w.writeFloat32(Float(joint * 100 + row * 4 + axis)) }
            }
        }

        for _ in 0..<Int(jointCount) {
            for _ in 0..<16 { w.writeFloat32(0) }
        }

        w.writeUInt32(skinID)
        w.writeUInt32(blendSkinID)

        return w.data
    }

    func testRoundTripsExactlyForASimpleRecord() throws {
        let data = buildRecord()
        var cursor = BinaryCursor(data: data)
        let parsed = try GraphicsInfoParser.parse(&cursor, recordID: 5)

        let reEncoded = SkeletonWriter.write(parsed)
        XCTAssertEqual(reEncoded, data, "re-encoding an unmodified parse must reproduce the original bytes exactly")
    }

    /// The real, load-bearing case: `headerBytes[2]`/`[6]`/`[7]`/`[9]`
    /// (reactJointCount/skinFlag/blendSkinFlag/padding) and the
    /// bounding-volume pair are never touched by this parser's own decode
    /// logic, a writer that rebuilds the header from scratch using only
    /// the fields it understands would silently zero them.
    func testPreservesUnknownHeaderBytesAndBoundingVolume() throws {
        let data = buildRecord()
        var cursor = BinaryCursor(data: data)
        let parsed = try GraphicsInfoParser.parse(&cursor, recordID: 5)

        XCTAssertEqual(parsed.headerBytes[2], 7)
        XCTAssertEqual(parsed.headerBytes[6], 1)
        XCTAssertEqual(parsed.headerBytes[7], 1)
        XCTAssertEqual(parsed.headerBytes[9], 0xAB)
        XCTAssertEqual(parsed.boundingVolume, [SIMD4<Float>(1, 2, 3, 4), SIMD4<Float>(5, 6, 7, 8)])

        let reEncoded = SkeletonWriter.write(parsed)
        XCTAssertEqual(reEncoded, data)
    }

    /// The actual editable surface `SkeletonInspectorView` exposes:
    /// re-parenting a joint and nudging one bind-pose matrix component.
    /// Proves the edit survives a full write/reparse cycle *and* the
    /// record stays exactly its original byte length (required for
    /// `WorkspaceViewModel.patchedFileBytes(replacing:with:)`, which only
    /// accepts an exact-size match).
    func testEditingParentJointIndexAndMatrixRoundTrips() throws {
        let data = buildRecord()
        var cursor = BinaryCursor(data: data)
        var parsed = try GraphicsInfoParser.parse(&cursor, recordID: 5)
        XCTAssertEqual(parsed.joints.count, 2)

        parsed.joints[1].parentJointIndex = 99
        parsed.joints[0].matrix[2].x = -12.5

        let edited = SkeletonWriter.write(parsed)
        XCTAssertEqual(edited.count, data.count, "in-place scalar edits must not change the record's on-disk size")

        var reCursor = BinaryCursor(data: edited)
        let reparsed = try GraphicsInfoParser.parse(&reCursor, recordID: 5)
        XCTAssertEqual(reparsed.joints[1].parentJointIndex, 99)
        XCTAssertEqual(reparsed.joints[0].matrix[2].x, -12.5)
        // Everything else stays untouched.
        XCTAssertEqual(reparsed.joints[0].reactJointID, 100)
        XCTAssertEqual(reparsed.skinID, 42)
        XCTAssertEqual(reparsed.blendSkinID, 43)
        XCTAssertEqual(reparsed.headerBytes[9], 0xAB)
        XCTAssertEqual(reparsed.boundingVolume, parsed.boundingVolume)
    }

    func testSkinIDAndBlendSkinIDEditsRoundTrip() throws {
        let data = buildRecord(skinID: 1, blendSkinID: 2)
        var cursor = BinaryCursor(data: data)
        var parsed = try GraphicsInfoParser.parse(&cursor, recordID: 1)

        parsed.skinID = 555
        parsed.blendSkinID = 777

        let edited = SkeletonWriter.write(parsed)
        var reCursor = BinaryCursor(data: edited)
        let reparsed = try GraphicsInfoParser.parse(&reCursor, recordID: 1)
        XCTAssertEqual(reparsed.skinID, 555)
        XCTAssertEqual(reparsed.blendSkinID, 777)
    }

    /// `modelLinks` on disk are two separate trailing arrays (joint-index
    /// bytes, then model-ID words) rather than interleaved, proves the
    /// writer reproduces that exact layout.
    func testModelLinksRoundTrip() throws {
        var w = BinaryWriter()
        var header = [UInt8](repeating: 0, count: 16)
        header[0] = 0 // jointCount
        header[5] = 2 // modelLinkCount
        w.writeBytes(header)
        for _ in 0..<8 { w.writeFloat32(0) } // Coord1, Coord2
        w.writeBytes([UInt8(3), UInt8(4)]) // joint indices
        w.writeUInt32(1001) // model IDs
        w.writeUInt32(1002)
        w.writeUInt32(0) // skinID
        w.writeUInt32(0) // blendSkinID

        var cursor = BinaryCursor(data: w.data)
        let parsed = try GraphicsInfoParser.parse(&cursor, recordID: 2)
        XCTAssertEqual(parsed.modelLinks.map(\.jointIndex), [3, 4])
        XCTAssertEqual(parsed.modelLinks.map(\.modelID), [1001, 1002])

        let reEncoded = SkeletonWriter.write(parsed)
        XCTAssertEqual(reEncoded, w.data)
    }

    /// "Collision Mask Alignment": the blob's undecoded trailing bytes
    /// (`rawBlobRemainder`) and the flat `byte[collisionDataCount]`
    /// trailer that follows every entry are real bytes this parser
    /// doesn't interpret but must still round-trip exactly.
    func testCollisionDataRawRemainderAndTrailerRoundTrip() throws {
        var w = BinaryWriter()
        var header = [UInt8](repeating: 0, count: 16)
        header[8] = 1 // collisionDataCount
        w.writeBytes(header)
        for _ in 0..<8 { w.writeFloat32(0) } // Coord1, Coord2
        w.writeUInt32(0) // skinID
        w.writeUInt32(0) // blendSkinID

        var collisionHeader = [UInt16](repeating: 0, count: 11)
        collisionHeader[0] = 1
        for value in collisionHeader { w.writeUInt16(value) }
        let blobSize: Int32 = 16 + 6 // 1 position + 6 undecoded trailing bytes
        w.writeInt32(blobSize)
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3); w.writeFloat32(4)
        w.writeBytes([UInt8](repeating: 0xCD, count: 6)) // undecoded trailing sub-blocks
        w.writeBytes([UInt8(0x77)]) // trailing per-entry byte

        var cursor = BinaryCursor(data: w.data)
        let parsed = try GraphicsInfoParser.parse(&cursor, recordID: 9)
        XCTAssertEqual(parsed.collisionData.count, 1)
        XCTAssertEqual(parsed.collisionData[0].rawBlobRemainder, Data([0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD]))
        XCTAssertEqual(parsed.collisionDataTrailer, [0x77])

        let reEncoded = SkeletonWriter.write(parsed)
        XCTAssertEqual(reEncoded, w.data)
    }

    /// The four count fields in `headerBytes` ([0]/[1]/[5]/[8]) are
    /// rebuilt fresh from the asset's own array counts rather than
    /// trusted verbatim, proves that still holds even if `headerBytes`
    /// itself is stale/inconsistent, mirroring `AnimationWriter`'s own
    /// "rebuilt fresh" packer-word philosophy for the fields it does
    /// interpret.
    func testHeaderCountFieldsAreRederivedFromArrayCounts() throws {
        let data = buildRecord(jointCount: 2)
        var cursor = BinaryCursor(data: data)
        var parsed = try GraphicsInfoParser.parse(&cursor, recordID: 1)
        XCTAssertEqual(parsed.headerBytes[0], 2)

        // Deliberately desync headerBytes[0] from the real joint count to
        // prove the writer doesn't just trust it verbatim.
        parsed.headerBytes[0] = 99

        let encoded = SkeletonWriter.write(parsed)
        XCTAssertEqual(encoded[0], 2, "header[0] must reflect the actual joints.count, not a stale headerBytes[0]")
    }
}
