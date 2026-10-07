import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class ChunkLinksParserTests: XCTestCase {
    /// One link with a boundary wall (`flags & 0x80000`) and a one-node load
    /// tree (`type & 0x1`), matching `Twinsanity/Items/ChunkLinks.cs`'s
    /// `Load`/`ReadTree` field order exactly, including a real trailing
    /// undecoded blob inside the tree node (`blobSize` bigger than the fixed
    /// 320-byte `loadArea`/`areaMatrix`/`unknownMatrix` block) to confirm the
    /// cursor seeks past it rather than desyncing the rest of the stream.
    func testDecodesLinkWithWallAndTreeNode() throws {
        var w = BinaryWriter()
        w.writeInt32(1) // linkCount

        w.writeInt32(1) // type: bit0 set -> hasTree
        let path = "east_chunk.sm2"
        w.writeInt32(Int32(path.utf8.count))
        w.writeASCIIString(path)
        w.writeUInt32(0x80000) // flags: hasWall

        for _ in 0..<4 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) } // objectMatrix
        for _ in 0..<4 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) } // chunkMatrix

        // loadWall: 4 real corners of a boundary quad
        w.writeFloat32(-5); w.writeFloat32(0); w.writeFloat32(-5); w.writeFloat32(1)
        w.writeFloat32(5); w.writeFloat32(0); w.writeFloat32(-5); w.writeFloat32(1)
        w.writeFloat32(5); w.writeFloat32(10); w.writeFloat32(-5); w.writeFloat32(1)
        w.writeFloat32(-5); w.writeFloat32(10); w.writeFloat32(-5); w.writeFloat32(1)

        // Tree node: header=0 (no further node), 11 x uint16 GI header,
        // blobSize = 320 + 8 (8 extra undecoded bytes).
        w.writeInt32(0)
        for _ in 0..<11 { w.writeUInt16(0) }
        w.writeInt32(328)
        for _ in 0..<8 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) } // loadArea
        for _ in 0..<6 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) } // areaMatrix
        for _ in 0..<6 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) } // unknownMatrix
        w.writeBytes([UInt8](repeating: 0xCD, count: 8)) // undecoded trailing blob

        var cursor = BinaryCursor(data: w.data)
        let asset = try ChunkLinksParser.parse(&cursor, recordID: 3)

        XCTAssertEqual(asset.links.count, 1)
        let link = try XCTUnwrap(asset.links.first)
        XCTAssertEqual(link.path, path)
        XCTAssertTrue(link.hasWall)
        XCTAssertTrue(link.hasTree)
        XCTAssertEqual(link.loadWall?.count, 4)
        XCTAssertEqual(link.loadWall?[0], SIMD4<Float>(-5, 0, -5, 1))
        XCTAssertEqual(link.treeNodes.count, 1)
        XCTAssertEqual(link.treeNodes[0].loadArea.count, 8)
        XCTAssertEqual(link.treeNodes[0].undecodedBlob.count, 8)
        XCTAssertEqual(cursor.position, w.data.count, "cursor should land exactly at the end of the record")
    }

    func testDecodesLinkWithoutWallOrTree() throws {
        var w = BinaryWriter()
        w.writeInt32(1)
        w.writeInt32(0) // type: no tree
        let path = "x"
        w.writeInt32(Int32(path.utf8.count))
        w.writeASCIIString(path)
        w.writeUInt32(0) // flags: no wall
        for _ in 0..<4 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        for _ in 0..<4 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }

        var cursor = BinaryCursor(data: w.data)
        let asset = try ChunkLinksParser.parse(&cursor, recordID: 0)

        let link = try XCTUnwrap(asset.links.first)
        XCTAssertFalse(link.hasWall)
        XCTAssertFalse(link.hasTree)
        XCTAssertNil(link.loadWall)
        XCTAssertTrue(link.treeNodes.isEmpty)
        XCTAssertEqual(cursor.position, w.data.count)
    }
}
