import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class AINavigationParserTests: XCTestCase {
    func testParsesAIPosition() throws {
        var w = BinaryWriter()
        w.writeFloat32(1.5); w.writeFloat32(-2.5); w.writeFloat32(3.5); w.writeFloat32(0.75)
        w.writeUInt16(4) // NodeType.wormPath

        var cursor = BinaryCursor(data: w.data)
        let marker = try AINavigationParser.parseAIPosition(&cursor, recordID: 7)

        XCTAssertEqual(marker.id, 7)
        XCTAssertEqual(marker.position, SIMD4<Float>(1.5, -2.5, 3.5, 0.75))
        XCTAssertEqual(marker.nodeType, .wormPath)
        XCTAssertEqual(cursor.position, w.data.count)
    }

    func testUnrecognizedNodeTypeIsNilNotFabricated() throws {
        var w = BinaryWriter()
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeUInt16(999)

        var cursor = BinaryCursor(data: w.data)
        let marker = try AINavigationParser.parseAIPosition(&cursor, recordID: 0)
        XCTAssertNil(marker.nodeType)
        XCTAssertEqual(marker.rawNodeType, 999)
    }

    func testParsesAIPath() throws {
        var w = BinaryWriter()
        for value: UInt16 in [10, 20, 30, 40, 50] { w.writeUInt16(value) }

        var cursor = BinaryCursor(data: w.data)
        let path = try AINavigationParser.parseAIPath(&cursor, recordID: 3)

        XCTAssertEqual(path.id, 3)
        XCTAssertEqual(path.args, [10, 20, 30, 40, 50])
        XCTAssertEqual(cursor.position, w.data.count)
    }

    /// `startAIPositionID`/`endAIPositionID` are exactly `args[0]`/
    /// `args[1]`, see `AIPathRecord`'s doc comment for the real reference-
    /// tool UI label ("AI Pos 1"/"AI Pos 2") backing that reading.
    func testAIPathStartEndPositionIDsMapToFirstTwoArgs() throws {
        var w = BinaryWriter()
        for value: UInt16 in [111, 222, 30, 40, 50] { w.writeUInt16(value) }
        var cursor = BinaryCursor(data: w.data)
        let path = try AINavigationParser.parseAIPath(&cursor, recordID: 3)

        XCTAssertEqual(path.startAIPositionID, 111)
        XCTAssertEqual(path.endAIPositionID, 222)
    }
}

extension AINavigationParserTests {
    func testWriteAIPositionRoundTripsThroughParser() throws {
        let position = SIMD4<Float>(1.5, -2.5, 3.5, 0.75)
        let encoded = WorldPlacementWriter.writeAIPosition(position: position, rawNodeType: 4)
        XCTAssertEqual(encoded.count, 18, "AIPosition is fixed-size, 4 floats + uint16")

        var cursor = BinaryCursor(data: encoded)
        let decoded = try AINavigationParser.parseAIPosition(&cursor, recordID: 99)
        XCTAssertEqual(decoded.position, position)
        XCTAssertEqual(decoded.rawNodeType, 4)
        XCTAssertEqual(decoded.nodeType, .wormPath)
        XCTAssertEqual(cursor.position, encoded.count)
    }

    func testWriteAIPathRoundTripsThroughParser() throws {
        let args: [UInt16] = [10, 20, 30, 40, 50]
        let encoded = WorldPlacementWriter.writeAIPath(args)
        XCTAssertEqual(encoded.count, 10, "AIPath is fixed-size, 5 uint16s")

        var cursor = BinaryCursor(data: encoded)
        let decoded = try AINavigationParser.parseAIPath(&cursor, recordID: 5)
        XCTAssertEqual(decoded.args, args)
        XCTAssertEqual(cursor.position, encoded.count)
    }
}
