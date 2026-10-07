import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// "Parity Phase D": `GameObjectWriter.encode(_:)`, byte-exact round-trips
/// of unmodified records (proving `ScriptSlots`/`PHeader`/`LinkedIDs.flag`
/// are recomputed to exactly what they already were), plus structural
/// mutation correctness (add an ID, toggle an optional block on/off, add a
/// command).
final class GameObjectWriterTests: XCTestCase {
    func testMinimalRecordEncodeRoundTripsByteExact() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        // ScriptSlots, always recomputed by `Save`/`GetWriter.encode` from
        // the real list counts below ([OGIs, Scripts, Objects, UI32,
        // Sounds, 0, 0, 0]), never independently meaningful; for a
        // byte-exact round-trip test this must already match what encoding
        // would produce, since it's not preserved verbatim from input.
        w.writeBytes([UInt8]([3, 0, 0, 2, 0, 0, 0, 0]))
        let name = "AKUAKUCRATE"
        w.writeInt32(Int32(name.utf8.count))
        w.writeASCIIString(name)
        w.writeInt32(2); w.writeUInt32(111); w.writeUInt32(222)
        w.writeInt32(3); w.writeUInt16(10); w.writeUInt16(65535); w.writeUInt16(30)
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)
        w.writeUInt32(0)

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let gameObject = try GameObjectParser.parse(&cursor, recordID: 7, platform: .ps2)
        let encoded = GameObjectWriter.encode(gameObject)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    func testInstancePropertiesRecordEncodeRoundTripsByteExact() throws {
        var w = BinaryWriter()
        w.writeUInt32(0x2000_0000)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeASCIIString("")
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)
        // PHeader, always recomputed as `flags.count | floats.count << 8 |
        // integers.count << 16`; must match the real list counts below
        // (1, 2, 1) for a byte-exact round-trip, same reasoning as
        // `ScriptSlots` above.
        w.writeUInt32(0x0001_0201)
        w.writeUInt32(42)
        w.writeInt32(1); w.writeUInt32(0x6)
        w.writeInt32(2); w.writeFloat32(1.5); w.writeFloat32(-2.5)
        w.writeInt32(1); w.writeUInt32(99)
        w.writeUInt32(0)

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let gameObject = try GameObjectParser.parse(&cursor, recordID: 2, platform: .ps2)
        let encoded = GameObjectWriter.encode(gameObject)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    func testLinkedIDsRecordEncodeRoundTripsByteExact() throws {
        var w = BinaryWriter()
        w.writeUInt32(0x4000_0000)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeASCIIString("")
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)
        w.writeUInt32(0x02 | 0x40)
        w.writeInt32(2); w.writeUInt16(11); w.writeUInt16(12)
        w.writeInt32(1); w.writeUInt16(21)
        w.writeUInt32(0)

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let gameObject = try GameObjectParser.parse(&cursor, recordID: 3, platform: .ps2)
        let encoded = GameObjectWriter.encode(gameObject)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    func testTrailingCommandChainEncodeRoundTripsByteExact() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeASCIIString("")
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)
        w.writeUInt32(1)
        w.writeUInt32(0) // commandID 0, no chain-continue

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let gameObject = try GameObjectParser.parse(&cursor, recordID: 4, platform: .ps2)
        let encoded = GameObjectWriter.encode(gameObject)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    // MARK: - Structural edits

    func testAddingAnOGIUpdatesScriptSlotAndReparsesCorrectly() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeASCIIString("")
        w.writeInt32(0)
        w.writeInt32(1); w.writeUInt16(1) // one OGI
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)
        w.writeUInt32(0)

        var cursor = BinaryCursor(data: w.data)
        var gameObject = try GameObjectParser.parse(&cursor, recordID: 5, platform: .ps2)
        XCTAssertEqual(gameObject.ogiIDs, [1])
        gameObject.ogiIDs.append(2)
        let encoded = GameObjectWriter.encode(gameObject)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try GameObjectParser.parse(&reparseCursor, recordID: 5, platform: .ps2)
        XCTAssertEqual(reparsed.ogiIDs, [1, 2])
    }

    func testTogglingInstancePropertiesOffOmitsTheBlock() throws {
        var w = BinaryWriter()
        w.writeUInt32(0x2000_0000)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeASCIIString("")
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)
        w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)
        w.writeUInt32(0)

        var cursor = BinaryCursor(data: w.data)
        var gameObject = try GameObjectParser.parse(&cursor, recordID: 6, platform: .ps2)
        XCTAssertNotNil(gameObject.instanceProperties)
        gameObject.instanceProperties = nil
        gameObject.unkBitfield &= ~0x2000_0000
        let encoded = GameObjectWriter.encode(gameObject)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try GameObjectParser.parse(&reparseCursor, recordID: 6, platform: .ps2)
        XCTAssertNil(reparsed.instanceProperties)
        XCTAssertEqual(reparsed.unkBitfield & 0x2000_0000, 0)
    }

    func testCreatingLinkedIDsRecomputesFlagFromListContents() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeASCIIString("")
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)
        w.writeUInt32(0)

        var cursor = BinaryCursor(data: w.data)
        var gameObject = try GameObjectParser.parse(&cursor, recordID: 8, platform: .ps2)
        XCTAssertNil(gameObject.linkedIDs)
        gameObject.unkBitfield |= 0x4000_0000
        gameObject.linkedIDs = GameObjectInfo.LinkedIDs(flag: 0, objects: [], ogis: [7], anims: [], codeModels: [], scripts: [], unk: [], sounds: [9, 10])
        let encoded = GameObjectWriter.encode(gameObject)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try GameObjectParser.parse(&reparseCursor, recordID: 8, platform: .ps2)
        let linked = try XCTUnwrap(reparsed.linkedIDs)
        XCTAssertEqual(linked.flag, 0x02 | 0x40, "flag must be recomputed from which lists are non-empty, not trusted from the (stale, zero) stored value")
        XCTAssertEqual(linked.ogis, [7])
        XCTAssertEqual(linked.sounds, [9, 10])
        XCTAssertEqual(linked.objects, [])
    }

    func testAddingACommandUpdatesScriptCommandsAmount() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeASCIIString("")
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)
        w.writeUInt32(0) // no commands

        var cursor = BinaryCursor(data: w.data)
        var gameObject = try GameObjectParser.parse(&cursor, recordID: 9, platform: .ps2)
        XCTAssertTrue(gameObject.scriptCommands.isEmpty)
        gameObject.scriptCommands.append(AgentLabCommand(commandID: 0, unkShort: 0, commandName: "MakeInert", rawArguments: [], decoded: nil, fileOffset: 0))
        let encoded = GameObjectWriter.encode(gameObject)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try GameObjectParser.parse(&reparseCursor, recordID: 9, platform: .ps2)
        XCTAssertEqual(reparsed.scriptCommands.count, 1)
        XCTAssertEqual(reparsed.scriptCommands[0].commandID, 0)
    }
}
