import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// "Parity Phase E": `ChunkLinksWriter.encode(_:)`, byte-exact round-trips
/// of unmodified records, plus structural correctness for a mutation
/// (adding a link recomputes `linkCount`; editing a path recomputes its
/// length prefix).
final class ChunkLinksWriterTests: XCTestCase {
    func testLinkWithWallAndTreeNodeEncodeRoundTripsByteExact() throws {
        var w = BinaryWriter()
        w.writeInt32(1)
        w.writeInt32(1) // type: hasTree
        let path = "east_chunk.sm2"
        w.writeInt32(Int32(path.utf8.count))
        w.writeASCIIString(path)
        w.writeUInt32(0x80000) // hasWall
        for _ in 0..<4 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        for _ in 0..<4 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeFloat32(-5); w.writeFloat32(0); w.writeFloat32(-5); w.writeFloat32(1)
        w.writeFloat32(5); w.writeFloat32(0); w.writeFloat32(-5); w.writeFloat32(1)
        w.writeFloat32(5); w.writeFloat32(10); w.writeFloat32(-5); w.writeFloat32(1)
        w.writeFloat32(-5); w.writeFloat32(10); w.writeFloat32(-5); w.writeFloat32(1)
        w.writeInt32(0) // tree node header: terminal
        for _ in 0..<11 { w.writeUInt16(0) }
        w.writeInt32(328) // blobSize = 320 + 8
        for _ in 0..<8 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        for _ in 0..<6 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        for _ in 0..<6 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeBytes([UInt8](repeating: 0xCD, count: 8))

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let asset = try ChunkLinksParser.parse(&cursor, recordID: 3)
        let encoded = ChunkLinksWriter.encode(asset)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    func testLinkWithoutWallOrTreeEncodeRoundTripsByteExact() throws {
        var w = BinaryWriter()
        w.writeInt32(1)
        w.writeInt32(0)
        let path = "x"
        w.writeInt32(Int32(path.utf8.count))
        w.writeASCIIString(path)
        w.writeUInt32(0)
        for _ in 0..<4 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        for _ in 0..<4 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let asset = try ChunkLinksParser.parse(&cursor, recordID: 0)
        let encoded = ChunkLinksWriter.encode(asset)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    func testEditingPathRecomputesLengthPrefixAndReparsesCorrectly() throws {
        var w = BinaryWriter()
        w.writeInt32(1)
        w.writeInt32(0)
        let path = "x"
        w.writeInt32(Int32(path.utf8.count))
        w.writeASCIIString(path)
        w.writeUInt32(0)
        for _ in 0..<4 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        for _ in 0..<4 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }

        var cursor = BinaryCursor(data: w.data)
        var asset = try ChunkLinksParser.parse(&cursor, recordID: 0)
        asset.links[0].path = "a_much_longer_neighbor_chunk_name.sm2"
        let encoded = ChunkLinksWriter.encode(asset)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try ChunkLinksParser.parse(&reparseCursor, recordID: 0)
        XCTAssertEqual(reparsed.links[0].path, "a_much_longer_neighbor_chunk_name.sm2")
        XCTAssertEqual(reparseCursor.position, encoded.count)
    }

    func testAddingALinkUpdatesLinkCount() throws {
        var w = BinaryWriter()
        w.writeInt32(1)
        w.writeInt32(0)
        let path = "x"
        w.writeInt32(Int32(path.utf8.count))
        w.writeASCIIString(path)
        w.writeUInt32(0)
        for _ in 0..<4 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        for _ in 0..<4 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }

        var cursor = BinaryCursor(data: w.data)
        var asset = try ChunkLinksParser.parse(&cursor, recordID: 0)
        let identityRows: [SIMD4<Float>] = [SIMD4(0, 0, 0, 1), SIMD4(0, 0, 0, 1), SIMD4(0, 0, 0, 1), SIMD4(0, 0, 0, 1)]
        asset.links.append(ChunkLink(id: 1, type: 0, path: "y", flags: 0, objectMatrix: identityRows, chunkMatrix: identityRows, loadWall: nil, treeNodes: []))
        let encoded = ChunkLinksWriter.encode(asset)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try ChunkLinksParser.parse(&reparseCursor, recordID: 0)
        XCTAssertEqual(reparsed.links.count, 2)
        XCTAssertEqual(reparsed.links[1].path, "y")
    }
}
