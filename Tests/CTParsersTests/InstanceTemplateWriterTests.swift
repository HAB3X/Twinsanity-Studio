import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// "Instance Template Editor", `InstanceTemplateWriter.encode(_:)` for
/// both the retail (`InstanceTemplateInfo`) and demo-build
/// (`InstanceTemplateDemoInfo`) record shapes, byte-exact round-tripped
/// against `WorldPlacementParser.parseInstanceTemplate`/
/// `parseInstanceTemplateDemo`, same discipline as `ChunkLinksWriterTests`.
final class InstanceTemplateWriterTests: XCTestCase {
    // MARK: - Retail

    private func writeRetailTemplate(headerInt1: UInt32, includeUnkShort: Bool) -> Data {
        var w = BinaryWriter()
        let name = "crate_template"
        w.writeUInt32(UInt32(name.utf8.count))
        w.writeASCIIString(name)
        w.writeUInt16(42) // objectID
        w.writeUInt16(0x0F0F) // bitfield
        w.writeUInt32(headerInt1)
        w.writeUInt32(2) // headerInt2
        w.writeUInt32(3) // headerInt3
        if includeUnkShort { w.writeUInt16(99) }
        w.writeBytes([1, 2, 3, 4, 5, 6]) // unkFlags, 6 bytes
        w.writeUInt32(0xDEADBEEF) // properties
        w.writeInt32(2) // flags count
        w.writeUInt32(10); w.writeUInt32(20)
        w.writeInt32(1) // floats count
        w.writeFloat32(1.5)
        w.writeInt32(3) // ints count
        w.writeUInt32(100); w.writeUInt32(200); w.writeUInt32(300)
        return w.data
    }

    func testRetailTemplateWithUnkShortRoundTripsByteExact() throws {
        let originalBytes = writeRetailTemplate(headerInt1: 1, includeUnkShort: true)
        var cursor = BinaryCursor(data: originalBytes)
        let template = try WorldPlacementParser.parseInstanceTemplate(&cursor, recordID: 7)
        XCTAssertEqual(template.unkShort, 99)
        let encoded = InstanceTemplateWriter.encode(template)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    func testRetailTemplateWithoutUnkShortRoundTripsByteExact() throws {
        let originalBytes = writeRetailTemplate(headerInt1: 0, includeUnkShort: false)
        var cursor = BinaryCursor(data: originalBytes)
        let template = try WorldPlacementParser.parseInstanceTemplate(&cursor, recordID: 7)
        XCTAssertNil(template.unkShort)
        let encoded = InstanceTemplateWriter.encode(template)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    /// Real edge this guards against: `unkShort` must only be written when
    /// `headerInt1 == 1` (matching the parser's own conditional read), a
    /// stale non-nil `unkShort` left over from an edit that also changed
    /// `headerInt1` away from 1 must be silently dropped, not written
    /// where the parser would never read it back.
    func testUnkShortIsOmittedWhenHeaderInt1IsNotOneEvenIfSet() throws {
        let originalBytes = writeRetailTemplate(headerInt1: 1, includeUnkShort: true)
        var cursor = BinaryCursor(data: originalBytes)
        var template = try WorldPlacementParser.parseInstanceTemplate(&cursor, recordID: 7)
        template.headerInt1 = 0
        let encoded = InstanceTemplateWriter.encode(template)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try WorldPlacementParser.parseInstanceTemplate(&reparseCursor, recordID: 7)
        XCTAssertNil(reparsed.unkShort)
        XCTAssertEqual(reparseCursor.position, encoded.count, "the whole record must consume exactly, proving unkShort wasn't left as a stray extra field")
    }

    func testEditingRetailListsReparsesCorrectly() throws {
        let originalBytes = writeRetailTemplate(headerInt1: 0, includeUnkShort: false)
        var cursor = BinaryCursor(data: originalBytes)
        var template = try WorldPlacementParser.parseInstanceTemplate(&cursor, recordID: 7)
        template.flags = [1, 2, 3, 4]
        template.name = "renamed_template"
        let encoded = InstanceTemplateWriter.encode(template)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try WorldPlacementParser.parseInstanceTemplate(&reparseCursor, recordID: 7)
        XCTAssertEqual(reparsed.name, "renamed_template")
        XCTAssertEqual(reparsed.flags, [1, 2, 3, 4])
        XCTAssertEqual(reparseCursor.position, encoded.count)
    }

    // MARK: - Demo

    private func writeDemoTemplate() -> Data {
        var w = BinaryWriter()
        let name = "demo_template"
        w.writeUInt32(UInt32(name.utf8.count))
        w.writeASCIIString(name)
        w.writeUInt16(7) // objectID
        w.writeUInt16(0x1234) // bitfield
        w.writeUInt32(0) // headerInt1 (no unkShort)
        w.writeUInt32(0) // headerInt2
        w.writeUInt32(0) // headerInt3
        w.writeBytes([9, 8]) // unkFlags, 2 bytes
        w.writeUInt8(2) // flagsCount
        w.writeUInt8(1) // floatsCount
        w.writeUInt8(3) // intsCount
        w.writeUInt8(0) // padding
        w.writeUInt32(0x1122) // properties
        w.writeUInt32(11); w.writeUInt32(22) // flags
        w.writeFloat32(3.25) // floats
        w.writeUInt32(1); w.writeUInt32(2); w.writeUInt32(3) // ints
        return w.data
    }

    func testDemoTemplateRoundTripsByteExact() throws {
        let originalBytes = writeDemoTemplate()
        var cursor = BinaryCursor(data: originalBytes)
        let template = try WorldPlacementParser.parseInstanceTemplateDemo(&cursor, recordID: 5)
        let encoded = InstanceTemplateWriter.encode(template)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    func testDemoTemplateListCountsAreClampedToUInt8Range() throws {
        let originalBytes = writeDemoTemplate()
        var cursor = BinaryCursor(data: originalBytes)
        var template = try WorldPlacementParser.parseInstanceTemplateDemo(&cursor, recordID: 5)
        template.ints = Array(repeating: 0, count: 300) // past the real 255-entry format ceiling
        let encoded = InstanceTemplateWriter.encode(template)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try WorldPlacementParser.parseInstanceTemplateDemo(&reparseCursor, recordID: 5)
        XCTAssertEqual(reparsed.ints.count, 255, "the single-byte count field can't represent more than 255 entries -- must clamp, not silently corrupt the byte stream")
    }
}
