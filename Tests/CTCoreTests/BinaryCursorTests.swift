import XCTest
@testable import CTCore

final class BinaryCursorTests: XCTestCase {
    func testLittleEndianIntegers() throws {
        var data = Data()
        data.append(contentsOf: [0x01, 0x00]) // UInt16 LE = 1
        data.append(contentsOf: [0x02, 0x00, 0x00, 0x00]) // UInt32 LE = 2
        data.append(contentsOf: [0xFF, 0xFF]) // Int16 LE = -1
        var cursor = BinaryCursor(data: data, endianness: .little)
        XCTAssertEqual(try cursor.readUInt16(), 1)
        XCTAssertEqual(try cursor.readUInt32(), 2)
        XCTAssertEqual(try cursor.readInt16(), -1)
        XCTAssertTrue(cursor.isAtEnd)
    }

    func testBigEndianIntegers() throws {
        var data = Data()
        data.append(contentsOf: [0x00, 0x01]) // UInt16 BE = 1
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x02]) // UInt32 BE = 2
        var cursor = BinaryCursor(data: data, endianness: .big)
        XCTAssertEqual(try cursor.readUInt16(), 1)
        XCTAssertEqual(try cursor.readUInt32(), 2)
    }

    func testFloatBitPatternRoundTrip() throws {
        var data = Data()
        let value: Float = 3.14159
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        var cursor = BinaryCursor(data: data)
        XCTAssertEqual(try cursor.readFloat32(), value, accuracy: 0.0001)
    }

    func testOutOfBoundsThrows() {
        var cursor = BinaryCursor(data: Data([0x01, 0x02]))
        XCTAssertThrowsError(try cursor.readUInt32()) { error in
            guard case BinaryCursorError.outOfBounds = error else {
                return XCTFail("expected outOfBounds, got \(error)")
            }
        }
    }

    func testSeekAndSkip() throws {
        var cursor = BinaryCursor(data: Data([0, 1, 2, 3, 4, 5]))
        try cursor.seek(to: 3)
        XCTAssertEqual(try cursor.readUInt8(), 3)
        try cursor.skip(1)
        XCTAssertEqual(try cursor.readUInt8(), 5)
        XCTAssertThrowsError(try cursor.seek(to: -1))
        XCTAssertThrowsError(try cursor.seek(to: 100))
    }

    func testASCIIStringAndCString() throws {
        var data = Data("HELLO".utf8)
        data.append(0)
        data.append(contentsOf: "WORLD".utf8)
        var cursor = BinaryCursor(data: data)
        XCTAssertEqual(try cursor.readASCIIString(length: 5), "HELLO")
        XCTAssertEqual(try cursor.readCString(maxLength: 20), "")
        XCTAssertEqual(try cursor.readASCIIString(length: 5), "WORLD")
    }

    func testSubCursorIsBoundedAndIndependentlyPositioned() throws {
        let full = BinaryCursor(data: Data([0, 0, 0, 0, 9, 8, 7, 6]))
        let sub = try full.subCursor(offset: 4, length: 4)
        var mutableSub = sub
        XCTAssertEqual(try mutableSub.readUInt8(), 9)
        XCTAssertEqual(sub.count, 4)
        XCTAssertThrowsError(try full.subCursor(offset: 6, length: 10))
    }

    func testSafeReserveCountClampsToWhatCouldActuallyFit() {
        // 8 bytes remaining, 4 bytes/element -> at most 2 could ever fit,
        // even though the file declares 1,000,000.
        let cursor = BinaryCursor(data: Data(repeating: 0, count: 8))
        XCTAssertEqual(cursor.safeReserveCount(Int32(1_000_000), elementSize: 4), 2)
    }

    func testSafeReserveCountPassesThroughWhenItActuallyFits() {
        let cursor = BinaryCursor(data: Data(repeating: 0, count: 100))
        XCTAssertEqual(cursor.safeReserveCount(Int32(10), elementSize: 4), 10)
    }

    func testSafeReserveCountRejectsNonPositiveInputs() {
        let cursor = BinaryCursor(data: Data(repeating: 0, count: 100))
        XCTAssertEqual(cursor.safeReserveCount(Int32(-1), elementSize: 4), 0)
        XCTAssertEqual(cursor.safeReserveCount(Int32(0), elementSize: 4), 0)
    }

    func testWithTemporarySeekRestoresPosition() throws {
        var cursor = BinaryCursor(data: Data([0, 1, 2, 3, 4]))
        try cursor.skip(2)
        let valueAtStart: UInt8 = cursor.withTemporarySeek(to: 0) { c in
            (try? c.readUInt8()) ?? 255
        }
        XCTAssertEqual(valueAtStart, 0)
        XCTAssertEqual(cursor.position, 2)
    }
}
