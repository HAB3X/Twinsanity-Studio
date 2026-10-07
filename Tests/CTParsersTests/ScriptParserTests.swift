import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// Pins the real, hand-traced byte layout of `Script.cs`'s `Load`/
/// `MainScript`/`HeaderScript`/`ScriptState`/`ScriptStateBody`/
/// `ScriptCondition` constructors, including the two-pass read order
/// (`MainScript` reads its whole `ScriptState` chain first, then a second
/// pass fills in each state's `ScriptStateBody` chain) and `SupportType1`'s
/// uint32-reinterpreted-as-float override quirk.
final class ScriptParserTests: XCTestCase {
    private static func writeName(_ w: inout BinaryWriter, _ name: String) {
        let bytes = Array(name.utf8)
        w.writeInt32(Int32(bytes.count))
        w.writeBytes(bytes)
    }

    func testHeaderScriptRoundTrips() throws {
        var w = BinaryWriter()
        w.writeUInt16(7) // inlineID
        w.writeUInt8(3) // mask
        w.writeUInt8(1) // flag != 0 -> HeaderScript
        w.writeUInt32(1) // pair count
        w.writeInt32(41) // mainScriptIndex (real script index is 41 - 1 = 40)
        // unkInt2: objectID=0x1234, preference=2 (strongest), status=1 (busy), locality=3 (anywhere), type=6 (anybody)
        let unkInt2: UInt32 = (0x1234 << 16) | (2 << 0xC) | (1 << 8) | (3 << 4) | 6
        w.writeUInt32(unkInt2)

        var cursor = BinaryCursor(data: w.data)
        let asset = try ScriptParser.parse(&cursor, recordID: 1, size: w.count, platform: .ps2)

        XCTAssertEqual(asset.inlineID, 7)
        XCTAssertEqual(asset.mask, 3)
        XCTAssertEqual(asset.flag, 1)
        guard case .header(let header) = asset.content else { return XCTFail("expected .header") }
        XCTAssertEqual(header.entries.count, 1)
        let entry = header.entries[0]
        XCTAssertEqual(entry.mainScriptIndex, 41)
        XCTAssertEqual(entry.objectID, 0x1234)
        XCTAssertEqual(entry.resolvedAssignType, .anybody)
        XCTAssertEqual(entry.resolvedAssignLocality, .anywhere)
        XCTAssertEqual(entry.resolvedAssignStatus, .busy)
        XCTAssertEqual(entry.resolvedAssignPreference, .strongest)
        XCTAssertTrue(asset.trailingBytes.isEmpty)
        XCTAssertEqual(cursor.position, w.count)
    }

    /// "Script writer" write-back for `HeaderScript`: `entriesFileOffset`
    /// must point at entry 0's real bytes, and
    /// `ScriptWriter.writeHeaderScriptEntry`'s 8 bytes patched at
    /// `entriesFileOffset + index * 8` must round-trip a reassigned entry
    /// while leaving every other entry untouched.
    func testHeaderScriptEntryOffsetRoundTripsThroughWriter() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(1) // flag != 0 -> HeaderScript
        w.writeUInt32(2) // pair count
        w.writeInt32(10); w.writeUInt32(0x1111) // entry 0
        w.writeInt32(20); w.writeUInt32(0x2222) // entry 1

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let asset = try ScriptParser.parse(&cursor, recordID: 10, size: w.count, platform: .ps2)
        guard case .header(let header) = asset.content else { return XCTFail("expected .header") }
        XCTAssertEqual(header.entries.count, 2)

        var probe = BinaryCursor(data: originalBytes)
        _ = try probe.seek(to: header.entriesFileOffset)
        XCTAssertEqual(try probe.readInt32(), 10)

        var patched = originalBytes
        let entry1Offset = header.entriesFileOffset + 1 * 8
        patched.replaceSubrange(entry1Offset..<(entry1Offset + 8), with: ScriptWriter.writeHeaderScriptEntry(mainScriptIndex: 99, unkInt2: 0xABCD))
        var reparseCursor = BinaryCursor(data: patched)
        let reparsed = try ScriptParser.parse(&reparseCursor, recordID: 10, size: patched.count, platform: .ps2)
        guard case .header(let reparsedHeader) = reparsed.content else { return XCTFail("expected .header") }
        XCTAssertEqual(reparsedHeader.entries[0].mainScriptIndex, 10, "entry 0 must be untouched")
        XCTAssertEqual(reparsedHeader.entries[1].mainScriptIndex, 99)
        XCTAssertEqual(reparsedHeader.entries[1].unkInt2, 0xABCD)
        XCTAssertEqual(patched.count, originalBytes.count)
    }

    func testMainScriptSingleStateNoBodyRoundTrips() throws {
        var w = BinaryWriter()
        w.writeUInt16(1) // inlineID
        w.writeUInt8(0) // mask
        w.writeUInt8(0) // flag == 0 -> MainScript
        Self.writeName(&w, "Test")
        w.writeInt32(1) // statesAmountRaw
        w.writeInt32(5) // startUnit
        w.writeInt16(0) // state bitfield: no type1, no next state, no bodies
        w.writeInt16(7) // scriptIndexOrSlot

        var cursor = BinaryCursor(data: w.data)
        let asset = try ScriptParser.parse(&cursor, recordID: 2, size: w.count, platform: .ps2)

        guard case .main(let main) = asset.content else { return XCTFail("expected .main") }
        XCTAssertEqual(main.name, "Test")
        XCTAssertEqual(main.startUnit, 5)
        XCTAssertEqual(main.states.count, 1)
        XCTAssertEqual(main.states[0].scriptIndexOrSlot, 7)
        XCTAssertNil(main.states[0].type1)
        XCTAssertTrue(main.states[0].bodies.isEmpty)
        XCTAssertEqual(cursor.position, w.count)
    }

    func testStateWithConditionAndCommandBody() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(1) // statesAmountRaw
        w.writeInt32(0) // startUnit
        w.writeInt16(0x1) // state bitfield: declaredBodyCount = 1, no type1, no next state
        w.writeInt16(9) // scriptIndexOrSlot

        // Pass 2: this state's single ScriptStateBody.
        // bitfield: 0x200 (condition present) | 0x001 (commandCount=1) -> 0x201. No 0x400, no 0x800.
        w.writeInt32(0x201)
        // ScriptCondition: unkInt1Raw packs vTableIndex=5 and NotGate (bit 0x10000).
        w.writeInt32(Int32(bitPattern: 0x10005))
        w.writeFloat32(0.25) // interval
        w.writeFloat32(0.5) // threshold
        w.writeFloat32(2.0) // thresholdInverse
        // ScriptCommand chain (PS2 platform, commandID=3 -> table size 0x20 -> 5 uint32 args).
        w.writeUInt32(3) // internalIndex: commandID=3, no chain flag
        for v: UInt32 in [10, 20, 30, 40, 50] { w.writeUInt32(v) }

        var cursor = BinaryCursor(data: w.data)
        let asset = try ScriptParser.parse(&cursor, recordID: 3, size: w.count, platform: .ps2)

        guard case .main(let main) = asset.content else { return XCTFail("expected .main") }
        XCTAssertEqual(main.states.count, 1)
        let state = main.states[0]
        XCTAssertEqual(state.declaredBodyCount, 1)
        XCTAssertEqual(state.bodies.count, 1)
        let body = state.bodies[0]
        XCTAssertFalse(body.isEnabled)
        XCTAssertNil(body.scriptStateListIndex)
        let condition = try XCTUnwrap(body.condition)
        XCTAssertEqual(condition.vTableIndex, 5)
        XCTAssertTrue(condition.notGate)
        XCTAssertEqual(condition.interval, 0.25)
        XCTAssertEqual(condition.threshold, 0.5)
        XCTAssertEqual(condition.thresholdInverse, 2.0)
        XCTAssertEqual(body.commands.count, 1)
        XCTAssertEqual(body.commands[0].commandID, 3)
        XCTAssertEqual(body.commands[0].rawArguments, [10, 20, 30, 40, 50])
        XCTAssertEqual(cursor.position, w.count)
        XCTAssertEqual(ScriptConditionCatalog.conditionName(forID: condition.vTableIndex), "TimeInUnit")
    }

    func testScriptConditionCatalogSpotChecks() {
        XCTAssertEqual(ScriptConditionCatalog.conditionName(forID: 0), "Next")
        XCTAssertEqual(ScriptConditionCatalog.conditionName(forID: 53), "TouchingTerrain")
        XCTAssertEqual(ScriptConditionCatalog.conditionName(forID: 629), "DemoHubMusicFlag")
        XCTAssertNil(ScriptConditionCatalog.conditionName(forID: 579), "579 (IsChargedShot) is commented out in the reference enum, not a confirmed condition")
        XCTAssertEqual(ScriptConditionCatalog.perceptArgumentCategory(forID: 53), .surface)
        XCTAssertEqual(ScriptConditionCatalog.perceptArgumentCategory(forID: 59), .counter)
        XCTAssertNil(ScriptConditionCatalog.perceptArgumentCategory(forID: 0), "Next (0) has no entry in the reference's own Args table")
    }

    func testChainedStatesAndChainedBodiesWithSupportType1() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(2) // statesAmountRaw (informational only, the real count comes from the chain)
        w.writeInt32(0)

        // State 0: has SupportType1 (0x4000) and a next state (0x8000), no bodies.
        w.writeInt16(Int16(bitPattern: 0x4000 | 0x8000))
        w.writeInt16(1) // scriptIndexOrSlot
        // SupportType1: unkByte1=0 (no bytes), unkByte2=0 (no floats), smallest valid instance.
        w.writeUInt8(0) // unkByte1
        w.writeUInt8(0) // unkByte2
        w.writeUInt16(6) // unkUShort1 (version)
        w.writeUInt32(0) // unkInt1Raw

        // State 1 (chained via state 0's 0x8000 bit): declaredBodyCount = 2, no type1, no further next-state.
        w.writeInt16(0x2)
        w.writeInt16(2) // scriptIndexOrSlot

        // Pass 2: state 1 declares 2 bodies -> read a 2-entry ScriptStateBody chain.
        // Body 0: empty (no condition, no commands), chained to body 1 via 0x800.
        w.writeInt32(0x800)
        // Body 1: also empty, no further chain.
        w.writeInt32(0x0)

        var cursor = BinaryCursor(data: w.data)
        let asset = try ScriptParser.parse(&cursor, recordID: 4, size: w.count, platform: .ps2)

        guard case .main(let main) = asset.content else { return XCTFail("expected .main") }
        XCTAssertEqual(main.states.count, 2, "the 0x8000 continuation bit must chain a second ScriptState")
        XCTAssertNotNil(main.states[0].type1)
        XCTAssertEqual(main.states[0].type1?.unkUShort1, 6)
        XCTAssertTrue(main.states[0].bodies.isEmpty)
        XCTAssertEqual(main.states[1].scriptIndexOrSlot, 2)
        XCTAssertEqual(main.states[1].bodies.count, 2, "the 0x800 continuation bit must chain a second ScriptStateBody")
        XCTAssertEqual(cursor.position, w.count)
    }

    func testSupportType1FloatOverrideReinterpretsBitsAsUInt32NumericValue() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(1)
        w.writeInt32(0)
        w.writeInt16(0x4000) // state bitfield: type1 present, no next, no bodies
        w.writeInt16(0)

        let originalFloat: Float = 3.5
        w.writeUInt8(1) // unkByte1 (bytes count)
        w.writeUInt8(2) // unkByte2 (floats count)
        w.writeUInt16(6)
        w.writeUInt32(0)
        w.writeFloat32(originalFloat) // floats[0], will be overridden
        w.writeFloat32(99) // floats[1], left alone
        w.writeUInt8(0) // bytes[0] = 0 -> points at floats[0], and 0 < 128 so the override applies

        var cursor = BinaryCursor(data: w.data)
        let asset = try ScriptParser.parse(&cursor, recordID: 5, size: w.count, platform: .ps2)

        guard case .main(let main) = asset.content else { return XCTFail("expected .main") }
        let type1 = try XCTUnwrap(main.states[0].type1)
        let expectedOverride = Float(originalFloat.bitPattern)
        XCTAssertEqual(type1.floats[0], expectedOverride, "bytes[0] < 128 means floats[0] is really a uint32's numeric value, not the original float bit pattern")
        XCTAssertEqual(type1.floats[1], 99, "floats not referenced by bytes[0]/[1]/[22] are left as real IEEE floats")
        XCTAssertEqual(cursor.position, w.count)
    }

    func testSupportType1FloatOverrideIndexOutOfRangeThrows() {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(1)
        w.writeInt32(0)
        w.writeInt16(0x4000)
        w.writeInt16(0)
        w.writeUInt8(1) // unkByte1: one byte
        w.writeUInt8(0) // unkByte2: zero floats, but bytes[0] will point past this empty list
        w.writeUInt16(6)
        w.writeUInt32(0)
        w.writeUInt8(0) // bytes[0] = 0, < 128, but floats.count == 0 -> out of range

        var cursor = BinaryCursor(data: w.data)
        XCTAssertThrowsError(try ScriptParser.parse(&cursor, recordID: 6, size: w.count, platform: .ps2)) { error in
            guard case ScriptParser.ScriptParseError.floatOverrideIndexOutOfRange = error else {
                return XCTFail("expected floatOverrideIndexOutOfRange, got \(error)")
            }
        }
    }

    func testTrailingBytesAreCapturedRealNotDiscarded() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(0) // statesAmountRaw == 0 -> no states read at all
        w.writeInt32(0)
        let leftover: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        w.writeBytes(leftover)

        var cursor = BinaryCursor(data: w.data)
        let asset = try ScriptParser.parse(&cursor, recordID: 7, size: w.count, platform: .ps2)

        guard case .main(let main) = asset.content else { return XCTFail("expected .main") }
        XCTAssertTrue(main.states.isEmpty)
        XCTAssertEqual([UInt8](asset.trailingBytes), leftover)
        XCTAssertEqual(cursor.position, w.count)
    }

    /// "Script writer" write-back: `scriptIndexOrSlotFileOffset` must point
    /// at the real bytes, and `ScriptWriter.writeScriptIndexOrSlot`'s 2
    /// bytes patched there must round-trip a redirected state (the same
    /// real operation CrateModLoader's own cutscene-skip mods perform)
    /// while leaving every other field (including the bitfield right
    /// before it, and the command body right after) untouched.
    func testScriptIndexOrSlotFileOffsetRoundTripsThroughWriter() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(1) // statesAmountRaw
        w.writeInt32(0) // startUnit
        w.writeInt16(0x1) // state bitfield: declaredBodyCount = 1, no type1, no next state
        w.writeInt16(42) // scriptIndexOrSlot
        w.writeInt32(0) // this state's single, empty ScriptStateBody

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let asset = try ScriptParser.parse(&cursor, recordID: 9, size: w.count, platform: .ps2)
        guard case .main(let main) = asset.content else { return XCTFail("expected .main") }
        let state = main.states[0]
        XCTAssertEqual(state.scriptIndexOrSlot, 42)

        var probe = BinaryCursor(data: originalBytes)
        _ = try probe.seek(to: state.scriptIndexOrSlotFileOffset)
        XCTAssertEqual(try probe.readInt16(), 42)

        var patched = originalBytes
        let offset = state.scriptIndexOrSlotFileOffset
        patched.replaceSubrange(offset..<(offset + 2), with: ScriptWriter.writeScriptIndexOrSlot(-1))
        var reparseCursor = BinaryCursor(data: patched)
        let reparsed = try ScriptParser.parse(&reparseCursor, recordID: 9, size: patched.count, platform: .ps2)
        guard case .main(let reparsedMain) = reparsed.content else { return XCTFail("expected .main") }
        XCTAssertEqual(reparsedMain.states[0].scriptIndexOrSlot, -1)
        XCTAssertEqual(reparsedMain.states[0].bitfieldRaw, 0x1, "the bitfield right before scriptIndexOrSlot must be untouched")
        XCTAssertEqual(reparsedMain.states[0].bodies.count, 1, "the body right after scriptIndexOrSlot must be untouched")
        XCTAssertEqual(patched.count, originalBytes.count)
    }

    /// AgentLab Phase C: `ScriptCondition.fileOffset` + `ScriptWriter.
    /// writeCondition`, same "capture once, patch a same-size range"
    /// discipline as `scriptIndexOrSlotFileOffset`, now covering the
    /// condition's own four fields (which also carry vTableIndex/
    /// parameter/notGate, packed into `unkInt1Raw`) in one patch.
    func testScriptConditionFileOffsetRoundTripsThroughWriter() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(1) // statesAmountRaw
        w.writeInt32(0) // startUnit
        w.writeInt16(0x1) // state bitfield: declaredBodyCount = 1
        w.writeInt16(0) // scriptIndexOrSlot
        w.writeInt32(0x200) // body bitfield: condition present only
        w.writeInt32(Int32(bitPattern: 0x10005)) // unkInt1Raw: vTableIndex=5, notGate set
        w.writeFloat32(0.25)
        w.writeFloat32(0.5)
        w.writeFloat32(2.0)

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let asset = try ScriptParser.parse(&cursor, recordID: 11, size: w.count, platform: .ps2)
        guard case .main(let main) = asset.content else { return XCTFail("expected .main") }
        let condition = try XCTUnwrap(main.states[0].bodies[0].condition)
        XCTAssertEqual(condition.vTableIndex, 5)

        var probe = BinaryCursor(data: originalBytes)
        _ = try probe.seek(to: condition.fileOffset)
        XCTAssertEqual(try probe.readInt32(), Int32(bitPattern: 0x10005))

        let replacement = ScriptCondition(unkInt1Raw: 9, interval: 1.0, threshold: 2.0, thresholdInverse: 3.0)
        var patched = originalBytes
        let offset = condition.fileOffset
        patched.replaceSubrange(offset..<(offset + 16), with: ScriptWriter.writeCondition(replacement))
        var reparseCursor = BinaryCursor(data: patched)
        let reparsed = try ScriptParser.parse(&reparseCursor, recordID: 11, size: patched.count, platform: .ps2)
        guard case .main(let reparsedMain) = reparsed.content else { return XCTFail("expected .main") }
        let reparsedCondition = try XCTUnwrap(reparsedMain.states[0].bodies[0].condition)
        XCTAssertEqual(reparsedCondition.unkInt1Raw, 9)
        XCTAssertEqual(reparsedCondition.interval, 1.0)
        XCTAssertEqual(reparsedCondition.threshold, 2.0)
        XCTAssertEqual(reparsedCondition.thresholdInverse, 3.0)
        XCTAssertEqual(patched.count, originalBytes.count)
    }

    /// AgentLab Phase C: `SupportType1.unkInt1RawFileOffset` + `ScriptWriter.
    /// writeSupportType1UnkInt1Raw`, makes every `resolved*`/flag accessor
    /// on `SupportType1` writable via one 4-byte patch, without touching
    /// the variable-length `bytes`/`floats` lists that follow it.
    func testSupportType1UnkInt1RawFileOffsetRoundTripsThroughWriter() throws {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        Self.writeName(&w, "")
        w.writeInt32(1) // statesAmountRaw
        w.writeInt32(0) // startUnit
        w.writeInt16(0x4000) // state bitfield: type1 present, no body, no next state
        w.writeInt16(0) // scriptIndexOrSlot
        // SupportType1: 0 bytes, 0 floats, unkUShort1=6, unkInt1Raw=1.
        w.writeUInt8(0)
        w.writeUInt8(0)
        w.writeUInt16(6)
        w.writeUInt32(1)

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let asset = try ScriptParser.parse(&cursor, recordID: 12, size: w.count, platform: .ps2)
        guard case .main(let main) = asset.content else { return XCTFail("expected .main") }
        let type1 = try XCTUnwrap(main.states[0].type1)
        XCTAssertEqual(type1.unkInt1Raw, 1)

        var probe = BinaryCursor(data: originalBytes)
        _ = try probe.seek(to: type1.unkInt1RawFileOffset)
        XCTAssertEqual(try probe.readUInt32(), 1)

        var patched = originalBytes
        let offset = type1.unkInt1RawFileOffset
        let newValue: UInt32 = (1 << 3) // resolvedMotion = constantVel
        patched.replaceSubrange(offset..<(offset + 4), with: ScriptWriter.writeSupportType1UnkInt1Raw(newValue))
        var reparseCursor = BinaryCursor(data: patched)
        let reparsed = try ScriptParser.parse(&reparseCursor, recordID: 12, size: patched.count, platform: .ps2)
        guard case .main(let reparsedMain) = reparsed.content else { return XCTFail("expected .main") }
        let reparsedType1 = try XCTUnwrap(reparsedMain.states[0].type1)
        XCTAssertEqual(reparsedType1.unkInt1Raw, newValue)
        XCTAssertEqual(reparsedType1.resolvedMotion, .constantVel)
        XCTAssertEqual(reparsedType1.unkUShort1, 6, "the field right before unkInt1Raw must be untouched")
        XCTAssertEqual(patched.count, originalBytes.count)
    }

    func testHugeDeclaredHeaderPairCountThrowsInsteadOfOverAllocating() {
        var w = BinaryWriter()
        w.writeUInt16(1)
        w.writeUInt8(0)
        w.writeUInt8(1) // flag != 0 -> HeaderScript
        w.writeUInt32(UInt32.max)

        var cursor = BinaryCursor(data: w.data)
        XCTAssertThrowsError(try ScriptParser.parse(&cursor, recordID: 8, size: w.count, platform: .ps2)) { error in
            XCTAssertTrue(error is BinaryCursorError)
        }
    }
}
