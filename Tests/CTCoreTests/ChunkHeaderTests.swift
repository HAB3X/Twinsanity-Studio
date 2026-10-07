import XCTest
@testable import CTCore

final class ChunkHeaderTests: XCTestCase {
    private func synthesizeHeader(magic: UInt32, entries: [ChunkIndexEntry]) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(magic)
        writer.writeInt32(Int32(entries.count))
        writer.writeUInt32(0) // content size, unused by the reader itself
        for entry in entries {
            writer.writeUInt32(entry.offset)
            writer.writeInt32(entry.size)
            writer.writeUInt32(entry.id)
        }
        return writer.data
    }

    func testReadsWellFormedHeader() throws {
        let entries = [
            ChunkIndexEntry(offset: 100, size: 20, id: 0),
            ChunkIndexEntry(offset: 120, size: 40, id: 1)
        ]
        let data = synthesizeHeader(magic: TwinsMagic.v1, entries: entries)
        var cursor = BinaryCursor(data: data)
        let header = try ChunkHeaderReader.readHeader(from: &cursor)

        XCTAssertEqual(header.magic, TwinsMagic.v1)
        XCTAssertEqual(header.recordCount, 2)
        XCTAssertEqual(header.entries, entries)
        XCTAssertEqual(header.indexStartPosition, 0)
    }

    func testAcceptsBothMagicValues() throws {
        let data = synthesizeHeader(magic: TwinsMagic.v2, entries: [])
        var cursor = BinaryCursor(data: data)
        let header = try ChunkHeaderReader.readHeader(from: &cursor)
        XCTAssertEqual(header.magic, TwinsMagic.v2)
        XCTAssertEqual(header.recordCount, 0)
    }

    func testRejectsBadMagic() {
        var writer = BinaryWriter()
        writer.writeUInt32(0xDEADBEEF)
        writer.writeInt32(0)
        writer.writeUInt32(0)
        var cursor = BinaryCursor(data: writer.data)
        XCTAssertThrowsError(try ChunkHeaderReader.readHeader(from: &cursor)) { error in
            guard case TwinsChunkError.badMagic = error else {
                return XCTFail("expected badMagic, got \(error)")
            }
        }
    }

    /// A corrupt/malicious file could declare a huge record count with no
    /// actual index table behind it. Before this guard, `readHeader` would
    /// call `reserveCapacity` for that declared count *before* validating a
    /// single entry against the buffer, for a count near `Int32.max` that's
    /// an attempt to allocate gigabytes, which can crash/hang the process
    /// well before the per-entry bounds check ever gets a chance to throw a
    /// normal, catchable error (this reader's whole stated point, per its
    /// own doc comment, is never doing that on corrupt input).
    func testHugeDeclaredCountOnATinyBufferThrowsInsteadOfOverAllocating() {
        var writer = BinaryWriter()
        writer.writeUInt32(TwinsMagic.v1)
        writer.writeInt32(Int32.max) // declared 2+ billion entries...
        writer.writeUInt32(0)
        // ...but the buffer actually has zero bytes of index table behind it.
        var cursor = BinaryCursor(data: writer.data)
        XCTAssertThrowsError(try ChunkHeaderReader.readHeader(from: &cursor)) { error in
            guard case TwinsChunkError.truncatedIndex = error else {
                return XCTFail("expected truncatedIndex, got \(error)")
            }
        }
    }

    func testNestedOffsetsAreRelativeToIndexStart() throws {
        // Simulate a nested section embedded 50 bytes into a larger buffer.
        var writer = BinaryWriter()
        writer.writeBytes([UInt8](repeating: 0xAA, count: 50)) // padding before the nested section
        let nestedStart = writer.count
        writer.writeUInt32(TwinsMagic.v1)
        writer.writeInt32(1)
        writer.writeUInt32(0)
        writer.writeUInt32(24) // child offset, relative to nestedStart: 12-byte section header + 12-byte index entry
        writer.writeInt32(4)
        writer.writeUInt32(99)
        writer.writeUInt32(0xCAFEBABE) // the child's 4 bytes of "content"

        var cursor = BinaryCursor(data: writer.data)
        try cursor.seek(to: nestedStart)
        let header = try ChunkHeaderReader.readHeader(from: &cursor)
        XCTAssertEqual(header.indexStartPosition, nestedStart)

        let childAbsoluteOffset = header.indexStartPosition + Int(header.entries[0].offset)
        var childCursor = BinaryCursor(data: writer.data)
        try childCursor.seek(to: childAbsoluteOffset)
        XCTAssertEqual(try childCursor.readUInt32(), 0xCAFEBABE)
    }
}
