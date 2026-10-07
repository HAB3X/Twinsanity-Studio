import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class GraphicsInfoParserTests: XCTestCase {
    /// Builds a minimal but fully valid `GraphicsInfo` record: 2 joints (a
    /// root and one child), no exit points, no model links, matching
    /// `GraphicsInfo.Load`'s exact field order.
    func testParsesJointsAndBuildsSkeletonTree() throws {
        var w = BinaryWriter()
        var header = [UInt8](repeating: 0, count: 16)
        header[0] = 2 // jointCount
        header[1] = 0 // exitPointCount
        header[5] = 0 // modelLinkCount
        header[8] = 0 // collisionDataCount
        w.writeBytes(header)

        // Coord1, Coord2 (bounding volume), 2 x 16 bytes
        for _ in 0..<8 { w.writeFloat32(0) }

        // Joint 0 (root): reactJointID, jointIndex=0, parentJointIndex=0, childAmt=1, childAmt2=0
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(1); w.writeUInt32(0)
        for _ in 0..<20 { w.writeFloat32(0) } // 5 x Pos (4 floats each)

        // Joint 1 (child of 0): jointIndex=1, parentJointIndex=0, childAmt=0
        w.writeUInt32(0); w.writeUInt32(1); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        for _ in 0..<20 { w.writeFloat32(0) }

        // SkinTransform[jointCount=2]: 4 x Pos each
        for _ in 0..<2 { for _ in 0..<16 { w.writeFloat32(0) } }

        w.writeUInt32(42)  // skinID
        w.writeUInt32(43)  // blendSkinID
        // collisionDataCount == 0: nothing further to write

        var cursor = BinaryCursor(data: w.data)
        let skeleton = try GraphicsInfoParser.parse(&cursor, recordID: 5)

        XCTAssertEqual(skeleton.joints.count, 2)
        XCTAssertEqual(skeleton.skinID, 42)
        XCTAssertEqual(skeleton.blendSkinID, 43)
        XCTAssertEqual(skeleton.skinTransforms.count, 2)

        let tree = try XCTUnwrap(skeleton.buildTree())
        XCTAssertEqual(tree.joint.jointIndex, 0)
        XCTAssertEqual(tree.children.count, 1)
        XCTAssertEqual(tree.children[0].joint.jointIndex, 1)
    }

    func testZeroJointsProducesEmptySkeletonWithNoTree() throws {
        var w = BinaryWriter()
        w.writeBytes([UInt8](repeating: 0, count: 16)) // all counts zero
        for _ in 0..<8 { w.writeFloat32(0) } // Coord1, Coord2
        w.writeUInt32(0) // skinID
        w.writeUInt32(0) // blendSkinID

        var cursor = BinaryCursor(data: w.data)
        let skeleton = try GraphicsInfoParser.parse(&cursor, recordID: 0)
        XCTAssertTrue(skeleton.joints.isEmpty)
        XCTAssertNil(skeleton.buildTree())
    }

    /// "Collision Mask Alignment": `GI_CollisionData`, decoded only as far
    /// as the reference tool's own `Load` does (the leading `header[0]`
    /// `Vector4`s), with real trailing bytes in the blob beyond that
    /// first block, to confirm the cursor correctly seeks to the *declared*
    /// blob end rather than stopping wherever `positions` happened to stop
    /// reading (real files have 6 more header-addressed sub-blocks this
    /// parser doesn't decode yet).
    func testDecodesCollisionDataAndSkipsUndecodedTrailingBytes() throws {
        var w = BinaryWriter()
        var header = [UInt8](repeating: 0, count: 16)
        header[8] = 1 // collisionDataCount
        w.writeBytes(header)
        for _ in 0..<8 { w.writeFloat32(0) } // Coord1, Coord2
        w.writeUInt32(0) // skinID
        w.writeUInt32(0) // blendSkinID

        // One GI_CollisionData entry: header[0] = 2 positions (32 bytes),
        // plus 8 extra undecoded trailing bytes in the blob.
        var collisionHeader = [UInt16](repeating: 0, count: 11)
        collisionHeader[0] = 2
        for value in collisionHeader { w.writeUInt16(value) }
        let blobSize: Int32 = 32 + 8
        w.writeInt32(blobSize)
        w.writeFloat32(-0.5); w.writeFloat32(-0.5); w.writeFloat32(-0.5); w.writeFloat32(1)
        w.writeFloat32(0.5); w.writeFloat32(0.5); w.writeFloat32(0.5); w.writeFloat32(1)
        w.writeBytes([UInt8](repeating: 0xAB, count: 8)) // undecoded trailing sub-blocks
        w.writeBytes([UInt8(0)]) // trailing per-entry byte

        var cursor = BinaryCursor(data: w.data)
        let skeleton = try GraphicsInfoParser.parse(&cursor, recordID: 9)

        XCTAssertEqual(skeleton.collisionData.count, 1)
        let entry = try XCTUnwrap(skeleton.collisionData.first)
        XCTAssertEqual(entry.positions.count, 2)
        XCTAssertEqual(entry.positions[0], SIMD4<Float>(-0.5, -0.5, -0.5, 1))
        XCTAssertEqual(entry.positions[1], SIMD4<Float>(0.5, 0.5, 0.5, 1))
        XCTAssertEqual(cursor.position, w.data.count, "cursor should land exactly at the end of the record after skipping the undecoded trailing bytes")
    }
}
