import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class PathParserTests: XCTestCase {
    func testParsesPositionsAndParams() throws {
        var w = BinaryWriter()
        w.writeInt32(2) // positionCount
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3); w.writeFloat32(1)
        w.writeFloat32(4); w.writeFloat32(5); w.writeFloat32(6); w.writeFloat32(1)
        w.writeInt32(1) // paramCount
        w.writeFloat32(0.5); w.writeFloat32(1.5)

        var cursor = BinaryCursor(data: w.data)
        let path = try PathParser.parse(&cursor, recordID: 4)

        XCTAssertEqual(path.id, 4)
        XCTAssertEqual(path.positions.count, 2)
        XCTAssertEqual(path.positions[0], SIMD4<Float>(1, 2, 3, 1))
        XCTAssertEqual(path.positions[1], SIMD4<Float>(4, 5, 6, 1))
        XCTAssertEqual(path.params.count, 1)
        XCTAssertEqual(path.params[0].p1, 0.5)
        XCTAssertEqual(path.params[0].p2, 1.5)
        XCTAssertEqual(cursor.position, w.count)
    }

    func testEmptyPathDecodesToEmptyLists() throws {
        var w = BinaryWriter()
        w.writeInt32(0)
        w.writeInt32(0)

        var cursor = BinaryCursor(data: w.data)
        let path = try PathParser.parse(&cursor, recordID: 1)
        XCTAssertTrue(path.positions.isEmpty)
        XCTAssertTrue(path.params.isEmpty)
    }

    func testWriterRoundTripsExactBytes() throws {
        var w = BinaryWriter()
        w.writeInt32(2)
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3); w.writeFloat32(1)
        w.writeFloat32(4); w.writeFloat32(5); w.writeFloat32(6); w.writeFloat32(1)
        w.writeInt32(1)
        w.writeFloat32(0.5); w.writeFloat32(1.5)

        var cursor = BinaryCursor(data: w.data)
        let path = try PathParser.parse(&cursor, recordID: 4)
        XCTAssertEqual(PathWriter.write(path), w.data)
    }

    func testHugeDeclaredPositionCountThrowsInsteadOfOverAllocating() {
        var w = BinaryWriter()
        w.writeInt32(Int32.max)

        var cursor = BinaryCursor(data: w.data)
        XCTAssertThrowsError(try PathParser.parse(&cursor, recordID: 1)) { error in
            XCTAssertTrue(error is BinaryCursorError)
        }
    }
}
