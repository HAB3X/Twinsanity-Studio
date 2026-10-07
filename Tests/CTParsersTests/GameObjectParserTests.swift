import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class GameObjectParserTests: XCTestCase {
    /// The minimal shape: no optional blocks, empty everything, zero
    /// trailing script commands, proves the reader consumes exactly the
    /// always-present fields and stops cleanly.
    func testParseMinimalRecordWithNoOptionalBlocks() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)              // UnkBitfield, neither optional block present
        w.writeBytes([UInt8](repeating: 0, count: 8)) // ScriptSlots

        let name = "AKUAKUCRATE"
        w.writeInt32(Int32(name.utf8.count))
        w.writeASCIIString(name)

        w.writeInt32(2)               // UI32 count
        w.writeUInt32(111)
        w.writeUInt32(222)

        w.writeInt32(3)               // OGIs count
        w.writeUInt16(10)
        w.writeUInt16(65535)          // "no value" sentinel, preserved as-is
        w.writeUInt16(30)

        w.writeInt32(0)               // Anims count
        w.writeInt32(0)               // Scripts count
        w.writeInt32(0)               // Objects count
        w.writeInt32(0)               // Sounds count
        // UnkBitfield has neither 0x20000000 nor 0x40000000 set, so no
        // instance-properties or linked-ID blocks follow.
        w.writeUInt32(0)              // scriptCommandsAmount, no trailing chain

        var cursor = BinaryCursor(data: w.data)
        let gameObject = try GameObjectParser.parse(&cursor, recordID: 7, platform: .ps2)

        XCTAssertEqual(gameObject.id, 7)
        XCTAssertEqual(gameObject.name, "AKUAKUCRATE")
        XCTAssertEqual(gameObject.ui32, [111, 222])
        XCTAssertEqual(gameObject.ogiIDs, [10, 65535, 30])
        XCTAssertEqual(gameObject.animIDs, [])
        XCTAssertEqual(gameObject.scriptIDs, [])
        XCTAssertEqual(gameObject.objectIDs, [])
        XCTAssertEqual(gameObject.soundIDs, [])
        XCTAssertNil(gameObject.instanceProperties)
        XCTAssertNil(gameObject.linkedIDs)
        XCTAssertTrue(gameObject.scriptCommands.isEmpty)
        XCTAssertEqual(cursor.position, w.data.count)
    }

    /// Every non-optional list populated, to prove each is read in the
    /// real on-disk order (OGIs, Anims, Scripts, Objects, Sounds).
    func testParseReadsAllFiveIDLists() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeASCIIString("")
        w.writeInt32(0) // UI32
        w.writeInt32(1); w.writeUInt16(1) // OGIs
        w.writeInt32(1); w.writeUInt16(2) // Anims
        w.writeInt32(1); w.writeUInt16(3) // Scripts
        w.writeInt32(1); w.writeUInt16(4) // Objects
        w.writeInt32(1); w.writeUInt16(5) // Sounds
        w.writeUInt32(0) // scriptCommandsAmount

        var cursor = BinaryCursor(data: w.data)
        let gameObject = try GameObjectParser.parse(&cursor, recordID: 1, platform: .ps2)

        XCTAssertEqual(gameObject.ogiIDs, [1])
        XCTAssertEqual(gameObject.animIDs, [2])
        XCTAssertEqual(gameObject.scriptIDs, [3])
        XCTAssertEqual(gameObject.objectIDs, [4])
        XCTAssertEqual(gameObject.soundIDs, [5])
    }

    /// `UnkBitfield & 0x20000000` gates a real, decoded instance-properties
    /// block (`PHeader`/`PUI32`/three typed lists).
    func testParseInstancePropertiesBlockWhenBitSet() throws {
        var w = BinaryWriter()
        w.writeUInt32(0x2000_0000)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeASCIIString("")
        w.writeInt32(0) // UI32
        w.writeInt32(0) // OGIs
        w.writeInt32(0) // Anims
        w.writeInt32(0) // Scripts
        w.writeInt32(0) // Objects
        w.writeInt32(0) // Sounds

        w.writeUInt32(0x0002_0100) // PHeader
        w.writeUInt32(42)          // PUI32
        w.writeInt32(1); w.writeUInt32(0x6)       // instFlagsList
        w.writeInt32(2); w.writeFloat32(1.5); w.writeFloat32(-2.5) // instFloatsList
        w.writeInt32(1); w.writeUInt32(99)        // instIntegerList

        w.writeUInt32(0) // scriptCommandsAmount

        var cursor = BinaryCursor(data: w.data)
        let gameObject = try GameObjectParser.parse(&cursor, recordID: 2, platform: .ps2)

        let props = try XCTUnwrap(gameObject.instanceProperties)
        XCTAssertEqual(props.pHeader, 0x0002_0100)
        XCTAssertEqual(props.pUI32, 42)
        XCTAssertEqual(props.flags, [0x6])
        XCTAssertEqual(props.floats, [1.5, -2.5])
        XCTAssertEqual(props.integers, [99])
        XCTAssertNil(gameObject.linkedIDs)
        XCTAssertEqual(cursor.position, w.data.count)
    }

    /// `UnkBitfield & 0x40000000` gates the linked-ID block, whose own
    /// inner `flag` bits (0x01..0x40) each independently gate one of the
    /// 7 real ID lists, this test sets only 0x02 (OGIs) and 0x40
    /// (Sounds) to prove the others are correctly skipped, not
    /// zero-filled.
    func testParseLinkedIDBlockRespectsInnerFlagBits() throws {
        var w = BinaryWriter()
        w.writeUInt32(0x4000_0000)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeASCIIString("")
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)

        w.writeUInt32(0x02 | 0x40) // flag: cOGIs + cSounds only
        w.writeInt32(2); w.writeUInt16(11); w.writeUInt16(12) // cOGIs
        w.writeInt32(1); w.writeUInt16(21) // cSounds

        w.writeUInt32(0)

        var cursor = BinaryCursor(data: w.data)
        let gameObject = try GameObjectParser.parse(&cursor, recordID: 3, platform: .ps2)

        let linked = try XCTUnwrap(gameObject.linkedIDs)
        XCTAssertEqual(linked.flag, 0x02 | 0x40)
        XCTAssertEqual(linked.objects, [])
        XCTAssertEqual(linked.ogis, [11, 12])
        XCTAssertEqual(linked.anims, [])
        XCTAssertEqual(linked.codeModels, [])
        XCTAssertEqual(linked.scripts, [])
        XCTAssertEqual(linked.unk, [])
        XCTAssertEqual(linked.sounds, [21])
        XCTAssertEqual(cursor.position, w.data.count)
    }

    /// The object's own trailing `scriptCommand` chain, same on-disk
    /// format `CustomAgentParser.readCommandChain` already decodes for
    /// `CustomAgent` records, now reused here. `ArglessAction` (command ID
    /// 0, per `AgentLabCommandCatalog`) has zero arguments, keeping this
    /// test self-contained without needing a real argument-count lookup.
    func testParseTrailingScriptCommandChain() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeASCIIString("")
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)

        w.writeUInt32(1) // scriptCommandsAmount != 0
        w.writeUInt32(0) // internalIndex: commandID 0, no chain-continue bit

        var cursor = BinaryCursor(data: w.data)
        let gameObject = try GameObjectParser.parse(&cursor, recordID: 4, platform: .ps2)

        XCTAssertEqual(gameObject.scriptCommands.count, 1)
        XCTAssertEqual(gameObject.scriptCommands.first?.commandID, 0)
        XCTAssertEqual(cursor.position, w.data.count)
    }
}
