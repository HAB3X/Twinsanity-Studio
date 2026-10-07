import XCTest
@testable import CTCore

final class BinaryWriterTests: XCTestCase {
    func testWriteThenReadRoundTrip() throws {
        var writer = BinaryWriter(endianness: .little)
        writer.writeUInt32(0xDEAD_BEEF)
        writer.writeInt16(-42)
        writer.writeFloat32(1.5)
        writer.writeASCIIString("AB")

        var cursor = BinaryCursor(data: writer.data, endianness: .little)
        XCTAssertEqual(try cursor.readUInt32(), 0xDEAD_BEEF)
        XCTAssertEqual(try cursor.readInt16(), -42)
        XCTAssertEqual(try cursor.readFloat32(), 1.5)
        XCTAssertEqual(try cursor.readASCIIString(length: 2), "AB")
    }

    func testBigEndianWriteMatchesBigEndianRead() throws {
        var writer = BinaryWriter(endianness: .big)
        writer.writeUInt32(1)
        var cursor = BinaryCursor(data: writer.data, endianness: .big)
        XCTAssertEqual(try cursor.readUInt32(), 1)
        // The raw bytes should be big-endian: 00 00 00 01
        XCTAssertEqual([UInt8](writer.data), [0x00, 0x00, 0x00, 0x01])
    }
}
