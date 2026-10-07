import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class ColDataParserTests: XCTestCase {
    func testShortRecordDecodesAsEmpty() throws {
        var w = BinaryWriter()
        w.writeBytes([UInt8](repeating: 0, count: 12)) // < 20-byte header

        var cursor = BinaryCursor(data: w.data)
        let mesh = try ColDataParser.parse(&cursor, recordID: 1, size: w.count)

        XCTAssertTrue(mesh.isEmpty)
        XCTAssertTrue(mesh.vertices.isEmpty)
        XCTAssertTrue(mesh.triangles.isEmpty)
    }

    /// Byte-count cross-checked against `ColData.GetSize()`
    /// (`20 + Triggers.Count*32 + Groups.Count*8 + Tris.Count*8 + Vertices.Count*16`).
    func testParsesTrianglesGroupsTriggersAndVertices() throws {
        var w = BinaryWriter()
        w.writeUInt32(1) // someNumber
        w.writeUInt32(1) // triggerCount
        w.writeUInt32(1) // groupCount
        w.writeUInt32(2) // triCount
        w.writeUInt32(4) // vertexCount

        // One trigger box.
        w.writeFloat32(-1); w.writeFloat32(-2); w.writeFloat32(-3); w.writeInt32(7)
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3); w.writeInt32(9)

        // One group.
        w.writeUInt32(2); w.writeUInt32(0)

        // Two triangles, packed 18/18/18/10 bits.
        func packedTriangle(_ v1: UInt64, _ v2: UInt64, _ v3: UInt64, _ surface: UInt64) -> UInt64 {
            (v1 & 0x3FFFF) | ((v2 & 0x3FFFF) << 18) | ((v3 & 0x3FFFF) << 36) | (surface << 54)
        }
        w.writeUInt64(packedTriangle(0, 1, 2, 5))
        w.writeUInt64(packedTriangle(1, 2, 3, 700))

        // Four vertices.
        for i in 0..<4 {
            w.writeFloat32(Float(i)); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        }

        XCTAssertEqual(w.count, 20 + 1 * 32 + 1 * 8 + 2 * 8 + 4 * 16)

        var cursor = BinaryCursor(data: w.data)
        let mesh = try ColDataParser.parse(&cursor, recordID: 3, size: w.count)

        XCTAssertFalse(mesh.isEmpty)
        XCTAssertEqual(mesh.vertices.count, 4)
        XCTAssertEqual(mesh.vertices[2], SIMD4<Float>(2, 0, 0, 1))

        XCTAssertEqual(mesh.triangles.count, 2)
        XCTAssertEqual(mesh.triangles[0].vertexIndex1, 0)
        XCTAssertEqual(mesh.triangles[0].vertexIndex2, 1)
        XCTAssertEqual(mesh.triangles[0].vertexIndex3, 2)
        XCTAssertEqual(mesh.triangles[0].surfaceID, 5)
        XCTAssertEqual(mesh.triangles[1].surfaceID, 700)

        XCTAssertEqual(mesh.groups.count, 1)
        XCTAssertEqual(mesh.groups[0].size, 2)

        XCTAssertEqual(mesh.triggerBoxes.count, 1)
        XCTAssertEqual(mesh.triggerBoxes[0].min, SIMD3<Float>(-1, -2, -3))
        XCTAssertEqual(mesh.triggerBoxes[0].flag1, 7)
        XCTAssertEqual(mesh.triggerBoxes[0].max, SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(mesh.triggerBoxes[0].flag2, 9)

        XCTAssertEqual(cursor.position, w.count)
    }

    /// A corrupt/crafted record could declare a huge count (up to
    /// `UInt32.max`) for any of the four collections with no real data
    /// behind it. Before this was fixed, `reserveCapacity` sized directly
    /// from that declared count would try to allocate gigabytes before a
    /// single element was read, this should instead throw the normal,
    /// catchable `BinaryCursorError` from running out of real bytes.
    func testHugeDeclaredCountsThrowInsteadOfOverAllocating() {
        var w = BinaryWriter()
        w.writeUInt32(1) // someNumber
        w.writeUInt32(.max) // triggerCount, declared ~4 billion, no data behind it
        w.writeUInt32(0)
        w.writeUInt32(0)
        w.writeUInt32(0)

        var cursor = BinaryCursor(data: w.data)
        XCTAssertThrowsError(try ColDataParser.parse(&cursor, recordID: 1, size: w.count)) { error in
            XCTAssertTrue(error is BinaryCursorError)
        }
    }
}
