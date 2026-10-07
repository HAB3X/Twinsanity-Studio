import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class LodModelParserTests: XCTestCase {
    func testParsesThreeLevelLodModel() throws {
        var w = BinaryWriter()
        w.writeUInt32(4098) // header, matches the reference tool's own real default
        w.writeUInt8(3)     // modelsAmount
        w.writeUInt32(0)    // zero
        for _ in 0..<4 { w.writeUInt32(1641631945) } // lodDistances
        w.writeUInt32(111); w.writeUInt32(222); w.writeUInt32(333) // lodModelIDs

        var cursor = BinaryCursor(data: w.data)
        let lod = try LodModelParser.parse(&cursor, recordID: 7)

        XCTAssertEqual(lod.header, 4098)
        XCTAssertEqual(lod.lodDistances.count, 4)
        XCTAssertEqual(lod.lodModelIDs, [111, 222, 333])
        XCTAssertEqual(cursor.position, w.data.count)
    }

    func testSingleLevelLodModel() throws {
        var w = BinaryWriter()
        w.writeUInt32(4098)
        w.writeUInt8(1)
        w.writeUInt32(0)
        for _ in 0..<4 { w.writeUInt32(0) }
        w.writeUInt32(999)

        var cursor = BinaryCursor(data: w.data)
        let lod = try LodModelParser.parse(&cursor, recordID: 1)
        XCTAssertEqual(lod.lodModelIDs, [999])
        XCTAssertEqual(cursor.position, w.data.count)
    }

    func testWriterRoundTripPreservesAllFields() throws {
        var w = BinaryWriter()
        w.writeUInt32(0x1234ABCD)
        w.writeUInt8(3)
        w.writeUInt32(0)
        w.writeUInt32(100); w.writeUInt32(200); w.writeUInt32(300); w.writeUInt32(400) // lodDistances
        w.writeUInt32(0xAABBCCDD); w.writeUInt32(0xDEADBEEF); w.writeUInt32(0x11223344) // lodModelIDs

        var cursor = BinaryCursor(data: w.data)
        let lod = try LodModelParser.parse(&cursor, recordID: 7)
        let encoded = LodModelWriter.write(lod)
        XCTAssertEqual(encoded, w.data, "writer must reproduce parser's input exactly")

        var reCursor = BinaryCursor(data: encoded)
        let reParsed = try LodModelParser.parse(&reCursor, recordID: 7)
        XCTAssertEqual(reParsed.header, lod.header)
        XCTAssertEqual(reParsed.lodDistances, lod.lodDistances)
        XCTAssertEqual(reParsed.lodModelIDs, lod.lodModelIDs)
    }

    func testWriterDerivesModelsAmountFromLodCount() throws {
        // Edit: shrink the list to 2 IDs. The writer must re-emit
        // modelsAmount = 2 itself (never trust a stale count).
        let lod = LodModelInfo(id: 1, header: 1, lodDistances: [0, 0, 0, 0], lodModelIDs: [10, 20])
        let encoded = LodModelWriter.write(lod)
        var cursor = BinaryCursor(data: encoded)
        let reParsed = try LodModelParser.parse(&cursor, recordID: 1)
        XCTAssertEqual(reParsed.lodModelIDs.count, 2)
        XCTAssertEqual(reParsed.lodModelIDs, [10, 20])
    }
}
