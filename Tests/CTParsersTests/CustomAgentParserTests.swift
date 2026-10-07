import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers

/// Verifies `CustomAgentParser` against the real, verified on-disk format
/// ported from `Twinsanity.CodeModel`/`Script.MainScript.ScriptCommand`
/// (`github.com/Smartkin/twinsanity-editor`, MIT licensed), see
/// `CustomAgentParser`'s own doc comment for the source.
final class CustomAgentParserTests: XCTestCase {
    /// Every command `AgentLabActionDecoder` decodes has a real, verified
    /// on-disk size of `0x10` (a 4-byte header-adjacent... actually 0x0C
    /// header + one 4-byte argument) in `CommandSizeMapper_PS2`, this
    /// pins that fact so a future edit to the table can't silently break
    /// the "1 uint32 argument" assumption every decoder case relies on.
    func testAllDecodedCommandsHaveExactlyOneArgumentOnPS2() {
        let oneArgCommandIDs: [UInt16] = [636, 537, 92, 585, 93, 513, 589, 590, 639, 620, 597, 528, 42, 529, 619]
        for id in oneArgCommandIDs {
            let size = AgentLabCommandCatalog.commandSize(forID: id, platform: .ps2)
            XCTAssertEqual(size, 0x10, "command \(id) expected a single-argument (0x10 byte) real size")
        }
    }

    func testCommandNameLookupMatchesRealEnum() {
        XCTAssertEqual(AgentLabCommandCatalog.commandName(forID: 529), "SetHitPoints")
        XCTAssertEqual(AgentLabCommandCatalog.commandName(forID: 537), "AddGem")
        XCTAssertEqual(AgentLabCommandCatalog.commandName(forID: 0), "MakeInert")
        // A real gap in the reference enum, nobody named this ID, must
        // stay nil, not get a made-up name.
        XCTAssertNil(AgentLabCommandCatalog.commandName(forID: 95))
    }

    func testCommandSizeOutOfBoundsReturnsZeroMatchingReference() {
        XCTAssertEqual(AgentLabCommandCatalog.commandSize(forID: 65000, platform: .ps2), 0)
    }

    /// Builds one synthetic `CodeModel` record byte-for-byte per the real
    /// format (header -> arraySize entries -> trailing chain) and confirms
    /// the parser decodes it back exactly, including a real named-action
    /// decode (`SetHitPoints`) and a real unnamed-but-sized passthrough.
    func testParseDecodesRealFormatWithOneEntryAndTrailingCommand() throws {
        var w = BinaryWriter()

        // Header: arraySize = 1 in bits 16-23.
        w.writeUInt32(UInt32(1) << 16)

        // Entry 0: one command, SetHitPoints(HitPoints = 7), no chaining.
        w.writeInt32(1) // scriptCommandsAmount
        let setHitPointsID: UInt32 = 529
        w.writeUInt32(setHitPointsID) // internalIndex, no 0x1000000 bit set
        w.writeUInt32(7) // HitPoints argument
        w.writeUInt16(4242) // scriptId

        // Trailing chain: MakeInert (id 0), which is argless (size 0x0C).
        w.writeUInt32(0)

        var cursor = BinaryCursor(data: w.data)
        let record = try CustomAgentParser.parse(&cursor, recordID: 99, platform: .ps2)

        XCTAssertEqual(record.recordID, 99)
        XCTAssertEqual(record.entries.count, 1)
        XCTAssertEqual(record.entries[0].scriptID, 4242)
        XCTAssertEqual(record.entries[0].commands.count, 1)
        XCTAssertEqual(record.entries[0].commands[0].commandID, 529)
        XCTAssertEqual(record.entries[0].commands[0].commandName, "SetHitPoints")
        XCTAssertEqual(record.entries[0].commands[0].rawArguments, [7])
        XCTAssertEqual(record.entries[0].commands[0].decoded, .setHitPoints(7))

        XCTAssertEqual(record.finalCommands.count, 1)
        XCTAssertEqual(record.finalCommands[0].commandID, 0)
        XCTAssertEqual(record.finalCommands[0].commandName, "MakeInert")
        XCTAssertTrue(record.finalCommands[0].rawArguments.isEmpty)
        XCTAssertNil(record.finalCommands[0].decoded)

        // Cursor must have consumed exactly the bytes written, no
        // over-read, no short read.
        XCTAssertEqual(cursor.position, w.data.count)
    }

    /// The `0x1000000` "has next command" bit chains a second command in
    /// the same slot, confirms the iterative chain-follow terminates
    /// correctly and preserves order.
    func testParseFollowsChainedCommandsInOrder() throws {
        var w = BinaryWriter()
        w.writeUInt32(UInt32(1) << 16) // arraySize = 1

        w.writeInt32(1) // scriptCommandsAmount
        // First command: AddGem(Gem = .red), chained to a second command.
        w.writeUInt32(UInt32(537) | 0x1000000)
        w.writeUInt32(AgentLabGemType.red.rawValue)
        // Second command: AddAmmo(AmmoToAdd = 30), not chained further.
        w.writeUInt32(636)
        w.writeUInt32(30)
        w.writeUInt16(1)

        w.writeUInt32(0) // trailing chain: MakeInert

        var cursor = BinaryCursor(data: w.data)
        let record = try CustomAgentParser.parse(&cursor, recordID: 1, platform: .ps2)

        XCTAssertEqual(record.entries[0].commands.count, 2)
        XCTAssertEqual(record.entries[0].commands[0].decoded, .addGem(.red))
        XCTAssertEqual(record.entries[0].commands[1].decoded, .addAmmo(30))
    }

    /// `NowGoBackCollidableAction`'s `[ActionID]` is commented out in the
    /// reference source, its command ID must decode to raw arguments only,
    /// never a fabricated `.decoded` case, matching the reference tool's own
    /// (non-)dispatch.
    func testUnregisteredActionStaysUndecoded() {
        let decoded = AgentLabActionDecoder.decode(commandID: 533, arguments: [0x3F800000])
        XCTAssertNil(decoded, "NowGoBackCollidable has no active [ActionID] registration in the reference tool")
    }
}
