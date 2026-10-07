import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class SkydomeParserTests: XCTestCase {
    func testParsesUnknownAndMeshIDs() throws {
        var w = BinaryWriter()
        w.writeUInt32(20480) // Unknown
        w.writeInt32(2)      // count
        w.writeUInt32(111)
        w.writeUInt32(222)

        var cursor = BinaryCursor(data: w.data)
        let skydome = try SkydomeParser.parse(&cursor, recordID: 3)

        XCTAssertEqual(skydome.id, 3)
        XCTAssertEqual(skydome.unknown, 20480)
        XCTAssertEqual(skydome.meshIDs, [111, 222])
        XCTAssertEqual(cursor.position, w.count)
    }

    func testZeroMeshesDecodesToEmptyList() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeInt32(0)

        var cursor = BinaryCursor(data: w.data)
        let skydome = try SkydomeParser.parse(&cursor, recordID: 1)
        XCTAssertTrue(skydome.meshIDs.isEmpty)
    }

    func testWriterRoundTripsExactBytes() throws {
        var w = BinaryWriter()
        w.writeUInt32(20480)
        w.writeInt32(2)
        w.writeUInt32(111)
        w.writeUInt32(222)

        var cursor = BinaryCursor(data: w.data)
        let skydome = try SkydomeParser.parse(&cursor, recordID: 3)
        XCTAssertEqual(SkydomeWriter.write(skydome), w.data)
    }

    func testHugeDeclaredCountThrowsInsteadOfOverAllocating() {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeInt32(Int32.max) // declared ~2 billion, no data behind it

        var cursor = BinaryCursor(data: w.data)
        XCTAssertThrowsError(try SkydomeParser.parse(&cursor, recordID: 1)) { error in
            XCTAssertTrue(error is BinaryCursorError)
        }
    }
}
