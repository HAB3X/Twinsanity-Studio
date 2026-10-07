import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// "AgentLab Phase B": `ScriptWriter.encode(_:)`, a full, byte-exact
/// re-encode of an entire `Script` leaf record, able to add/remove
/// `ScriptState`s, `ScriptStateBody`s, `ScriptCommand`s, and create/delete a
/// `ScriptCondition`. Two kinds of coverage: (1) parse real synthetic bytes,
/// encode the *unmodified* result, and assert it's byte-for-byte identical
/// to the original, the strongest possible check that every structural bit
/// (`0x8000` next-state, `0x1F` body count, `0x4000` type1 presence, `0x800`
/// next-body, `0x200` has-condition, command `commandCount`/chain-flag) is
/// recomputed to exactly what it already was; (2) parse, mutate the Swift
/// model's own arrays/optionals (add/remove a state/body/command, create/
/// delete a condition), encode, reparse, and assert the new structure reads
/// back correctly.
final class ScriptWriterStructuralTests: XCTestCase {
    private static func writeName(_ w: inout BinaryWriter, _ name: String) {
        let bytes = Array(name.utf8)
        w.writeInt32(Int32(bytes.count))
        w.writeBytes(bytes)
    }

    private func makeCommand(commandID: UInt16, arguments: [UInt32]) -> AgentLabCommand {
        AgentLabCommand(commandID: commandID, unkShort: 0, commandName: nil, rawArguments: arguments, decoded: nil, fileOffset: 0)
    }

    // MARK: - Unmodified round-trips (byte-exact)

    func testHeaderScriptEncodeRoundTripsByteExact() throws {
        var w = BinaryWriter()
        w.writeUInt16(7)
        w.writeUInt8(3)
        w.writeUInt8(1) // flag != 0 -> HeaderScript
        w.writeUInt32(2) // pair count
        w.writeInt32(41); w.writeUInt32(0x1234_5678)
        w.writeInt32(10); w.writeUInt32(0xABCD_EF01)

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let asset = try ScriptParser.parse(&cursor, recordID: 1, size: originalBytes.count, platform: .ps2)
        let encoded = ScriptWriter.encode(asset)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    func testMainScriptSingleStateNoBodyEncodeRoundTripsByteExact() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "Test")
        w.writeInt32(1) // statesAmountRaw
        w.writeInt32(5) // startUnit
        w.writeInt16(0x1000) // IsSlot set, no type1, no next, no bodies, a non-structural bit that must survive
        w.writeInt16(7)

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let asset = try ScriptParser.parse(&cursor, recordID: 2, size: originalBytes.count, platform: .ps2)
        let encoded = ScriptWriter.encode(asset)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    func testConditionAndCommandBodyEncodeRoundTripsByteExact() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(1)
        w.writeInt32(0)
        w.writeInt16(0x1) // declaredBodyCount = 1
        w.writeInt16(9)
        w.writeInt32(0x201) // condition present, commandCount=1
        w.writeInt32(Int32(bitPattern: 0x10005))
        w.writeFloat32(0.25)
        w.writeFloat32(0.5)
        w.writeFloat32(2.0)
        w.writeUInt32(3) // commandID=3 (PS2 table size 0x20 -> 5 args), no chain flag
        for v: UInt32 in [10, 20, 30, 40, 50] { w.writeUInt32(v) }

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let asset = try ScriptParser.parse(&cursor, recordID: 3, size: originalBytes.count, platform: .ps2)
        let encoded = ScriptWriter.encode(asset)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    func testChainedStatesAndBodiesWithSupportType1EncodeRoundTripsByteExact() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(2)
        w.writeInt32(0)

        w.writeInt16(Int16(bitPattern: 0x4000 | 0x8000))
        w.writeInt16(1)
        w.writeUInt8(1) // unkByte1 (bytes count)
        w.writeUInt8(1) // unkByte2 (floats count)
        w.writeUInt16(6)
        w.writeUInt32(0x0102_0304)
        w.writeFloat32(42.5) // floats[0], not overridden (bytes[0] will be a sentinel >= 128 below)
        w.writeUInt8(200) // bytes[0] = 200 (>= 128 -> no override)

        w.writeInt16(0x2) // declaredBodyCount = 2
        w.writeInt16(2)

        w.writeInt32(0x800) // body 0: empty, chained
        w.writeInt32(0x0) // body 1: empty, terminal

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let asset = try ScriptParser.parse(&cursor, recordID: 4, size: originalBytes.count, platform: .ps2)
        let encoded = ScriptWriter.encode(asset)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    func testTrailingBytesSurviveEncodeRoundTrip() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(0)
        w.writeInt32(0)
        let leftover: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        w.writeBytes(leftover)

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let asset = try ScriptParser.parse(&cursor, recordID: 7, size: originalBytes.count, platform: .ps2)
        let encoded = ScriptWriter.encode(asset)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    // MARK: - Structural edits

    func testAddingAStateProducesAValidReparsableChain() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(1)
        w.writeInt32(0)
        w.writeInt16(0) // single state, no next, no type1, no bodies
        w.writeInt16(11)

        var cursor = BinaryCursor(data: w.data)
        let asset = try ScriptParser.parse(&cursor, recordID: 20, size: w.count, platform: .ps2)
        guard case .main(var main) = asset.content else { return XCTFail("expected .main") }
        XCTAssertEqual(main.states.count, 1)

        let newState = ScriptState(bitfieldRaw: 0, scriptIndexOrSlot: 22, type1: nil, bodies: [])
        main.states.append(newState)
        let mutated = ScriptAsset(id: asset.id, inlineID: asset.inlineID, mask: asset.mask, flag: asset.flag, content: .main(main), trailingBytes: asset.trailingBytes)
        let encoded = ScriptWriter.encode(mutated)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try ScriptParser.parse(&reparseCursor, recordID: 20, size: encoded.count, platform: .ps2)
        guard case .main(let reparsedMain) = reparsed.content else { return XCTFail("expected .main") }
        XCTAssertEqual(reparsedMain.states.count, 2)
        XCTAssertEqual(reparsedMain.states[0].scriptIndexOrSlot, 11)
        XCTAssertNotEqual(reparsedMain.states[0].bitfieldRaw & Int16(bitPattern: 0x8000), 0, "state 0 must now chain to the appended state")
        XCTAssertEqual(reparsedMain.states[1].scriptIndexOrSlot, 22)
        XCTAssertEqual(reparsedMain.states[1].bitfieldRaw & Int16(bitPattern: 0x8000), 0, "the last state must not claim a further chain")
    }

    func testDeletingAStateShrinksTheChainCorrectly() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(2)
        w.writeInt32(0)
        w.writeInt16(Int16(bitPattern: 0x8000)) // state 0: chained
        w.writeInt16(1)
        w.writeInt16(0) // state 1: terminal
        w.writeInt16(2)

        var cursor = BinaryCursor(data: w.data)
        let asset = try ScriptParser.parse(&cursor, recordID: 21, size: w.count, platform: .ps2)
        guard case .main(var main) = asset.content else { return XCTFail("expected .main") }
        XCTAssertEqual(main.states.count, 2)
        main.states.removeLast()
        let mutated = ScriptAsset(id: asset.id, inlineID: asset.inlineID, mask: asset.mask, flag: asset.flag, content: .main(main), trailingBytes: asset.trailingBytes)
        let encoded = ScriptWriter.encode(mutated)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try ScriptParser.parse(&reparseCursor, recordID: 21, size: encoded.count, platform: .ps2)
        guard case .main(let reparsedMain) = reparsed.content else { return XCTFail("expected .main") }
        XCTAssertEqual(reparsedMain.states.count, 1)
        XCTAssertEqual(reparsedMain.states[0].scriptIndexOrSlot, 1)
        XCTAssertEqual(reparsedMain.states[0].bitfieldRaw & Int16(bitPattern: 0x8000), 0, "the remaining state must no longer claim a chain")
    }

    func testDeletingABodyUpdatesDeclaredBodyCount() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(1)
        w.writeInt32(0)
        w.writeInt16(0x2) // declaredBodyCount = 2
        w.writeInt16(0)
        w.writeInt32(0x800) // body 0: empty, chained
        w.writeInt32(0x0) // body 1: empty, terminal

        var cursor = BinaryCursor(data: w.data)
        let asset = try ScriptParser.parse(&cursor, recordID: 22, size: w.count, platform: .ps2)
        guard case .main(var main) = asset.content else { return XCTFail("expected .main") }
        XCTAssertEqual(main.states[0].bodies.count, 2)
        main.states[0].bodies.removeLast()
        let mutated = ScriptAsset(id: asset.id, inlineID: asset.inlineID, mask: asset.mask, flag: asset.flag, content: .main(main), trailingBytes: asset.trailingBytes)
        let encoded = ScriptWriter.encode(mutated)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try ScriptParser.parse(&reparseCursor, recordID: 22, size: encoded.count, platform: .ps2)
        guard case .main(let reparsedMain) = reparsed.content else { return XCTFail("expected .main") }
        XCTAssertEqual(reparsedMain.states[0].declaredBodyCount, 1)
        XCTAssertEqual(reparsedMain.states[0].bodies.count, 1)
        XCTAssertEqual(reparsedMain.states[0].bodies[0].bitfieldRaw & 0x800, 0, "the remaining body must no longer claim a chain")
    }

    func testAddingACommandUpdatesCommandCountAndChainBit() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(1)
        w.writeInt32(0)
        w.writeInt16(0x1)
        w.writeInt16(0)
        w.writeInt32(0x1) // commandCount = 1, no condition
        w.writeUInt32(3) // commandID=3 -> 5 args
        for v: UInt32 in [1, 2, 3, 4, 5] { w.writeUInt32(v) }

        var cursor = BinaryCursor(data: w.data)
        let asset = try ScriptParser.parse(&cursor, recordID: 23, size: w.count, platform: .ps2)
        guard case .main(var main) = asset.content else { return XCTFail("expected .main") }
        XCTAssertEqual(main.states[0].bodies[0].commands.count, 1)
        main.states[0].bodies[0].commands.append(makeCommand(commandID: 3, arguments: [9, 8, 7, 6, 5]))
        let mutated = ScriptAsset(id: asset.id, inlineID: asset.inlineID, mask: asset.mask, flag: asset.flag, content: .main(main), trailingBytes: asset.trailingBytes)
        let encoded = ScriptWriter.encode(mutated)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try ScriptParser.parse(&reparseCursor, recordID: 23, size: encoded.count, platform: .ps2)
        guard case .main(let reparsedMain) = reparsed.content else { return XCTFail("expected .main") }
        let body = reparsedMain.states[0].bodies[0]
        XCTAssertEqual(body.commandCount, 2)
        XCTAssertEqual(body.commands.count, 2)
        XCTAssertEqual(body.commands[0].rawArguments, [1, 2, 3, 4, 5])
        XCTAssertEqual(body.commands[1].rawArguments, [9, 8, 7, 6, 5])
    }

    func testCreatingAConditionSetsThePresenceBit() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(1)
        w.writeInt32(0)
        w.writeInt16(0x1)
        w.writeInt16(0)
        w.writeInt32(0x0) // no condition, no commands

        var cursor = BinaryCursor(data: w.data)
        let asset = try ScriptParser.parse(&cursor, recordID: 24, size: w.count, platform: .ps2)
        guard case .main(var main) = asset.content else { return XCTFail("expected .main") }
        XCTAssertNil(main.states[0].bodies[0].condition)
        main.states[0].bodies[0].condition = ScriptCondition(unkInt1Raw: 42, interval: 1, threshold: 2, thresholdInverse: 3)
        let mutated = ScriptAsset(id: asset.id, inlineID: asset.inlineID, mask: asset.mask, flag: asset.flag, content: .main(main), trailingBytes: asset.trailingBytes)
        let encoded = ScriptWriter.encode(mutated)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try ScriptParser.parse(&reparseCursor, recordID: 24, size: encoded.count, platform: .ps2)
        guard case .main(let reparsedMain) = reparsed.content else { return XCTFail("expected .main") }
        let condition = try XCTUnwrap(reparsedMain.states[0].bodies[0].condition)
        XCTAssertEqual(condition.unkInt1Raw, 42)
        XCTAssertEqual(condition.interval, 1)
        XCTAssertNotEqual(reparsedMain.states[0].bodies[0].bitfieldRaw & 0x200, 0)
    }

    func testDeletingAConditionClearsThePresenceBit() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(1)
        w.writeInt32(0)
        w.writeInt16(0x1)
        w.writeInt16(0)
        w.writeInt32(0x200) // condition present, no commands
        w.writeInt32(Int32(bitPattern: 0x5))
        w.writeFloat32(0)
        w.writeFloat32(0.5)
        w.writeFloat32(2.0)

        var cursor = BinaryCursor(data: w.data)
        let asset = try ScriptParser.parse(&cursor, recordID: 25, size: w.count, platform: .ps2)
        guard case .main(var main) = asset.content else { return XCTFail("expected .main") }
        XCTAssertNotNil(main.states[0].bodies[0].condition)
        main.states[0].bodies[0].condition = nil
        let mutated = ScriptAsset(id: asset.id, inlineID: asset.inlineID, mask: asset.mask, flag: asset.flag, content: .main(main), trailingBytes: asset.trailingBytes)
        let encoded = ScriptWriter.encode(mutated)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try ScriptParser.parse(&reparseCursor, recordID: 25, size: encoded.count, platform: .ps2)
        guard case .main(let reparsedMain) = reparsed.content else { return XCTFail("expected .main") }
        XCTAssertNil(reparsedMain.states[0].bodies[0].condition)
        XCTAssertEqual(reparsedMain.states[0].bodies[0].bitfieldRaw & 0x200, 0)
    }
}
