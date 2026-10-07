import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers

final class AgentLabWriterTests: XCTestCase {
    func testWriteArgumentsEncodesLittleEndianUInt32sInOrder() {
        let encoded = AgentLabWriter.writeArguments([1, 0xFFFF_FFFF, 0])
        XCTAssertEqual(Array(encoded), [
            0x01, 0x00, 0x00, 0x00,
            0xFF, 0xFF, 0xFF, 0xFF,
            0x00, 0x00, 0x00, 0x00
        ])
    }

    func testWriteArgumentsRoundTripsThroughParser() throws {
        let cases: [(input: [UInt32], expected: [UInt32])] = [
            ([0], [0]),
            ([UInt32.max], [UInt32.max]),
            ([1, 2, 3], [1, 2, 3])
        ]
        for testCase in cases {
            let encoded = AgentLabWriter.writeArguments(testCase.input)
            var cursor = BinaryCursor(data: encoded)
            var readBack: [UInt32] = []
            for _ in testCase.input {
                readBack.append(try cursor.readUInt32())
            }
            XCTAssertEqual(readBack, testCase.expected)
        }
    }

    /// End-to-end: patch a real synthesized `CodeModel` record's argument
    /// bytes at `command.fileOffset + 4` (the offset the editor sheet
    /// actually uses) and confirm re-parsing sees the new value, pins
    /// that "+4 to skip internalIndex" is the real, correct argument
    /// start, not an off-by-one.
    func testPatchingAtFileOffsetPlusFourChangesTheArgumentAParserReads() throws {
        var w = BinaryWriter()
        w.writeUInt32(UInt32(1) << 16) // arraySize = 1
        w.writeInt32(1) // scriptCommandsAmount
        let setHitPointsID: UInt32 = 529
        w.writeUInt32(setHitPointsID) // internalIndex
        w.writeUInt32(7) // HitPoints argument, this is what we'll patch
        w.writeUInt16(4242) // scriptId
        w.writeUInt32(0) // trailing chain: MakeInert

        var cursor = BinaryCursor(data: w.data)
        let record = try CustomAgentParser.parse(&cursor, recordID: 1, platform: .ps2)
        let command = record.entries[0].commands[0]
        XCTAssertEqual(command.decoded, .setHitPoints(7))

        var patchedBytes = w.data
        let encoded = AgentLabWriter.writeArguments([99])
        let argumentOffset = command.fileOffset + 4
        patchedBytes.replaceSubrange(argumentOffset..<(argumentOffset + encoded.count), with: encoded)

        var reparseCursor = BinaryCursor(data: patchedBytes)
        let reparsed = try CustomAgentParser.parse(&reparseCursor, recordID: 1, platform: .ps2)
        XCTAssertEqual(reparsed.entries[0].commands[0].decoded, .setHitPoints(99))
        XCTAssertEqual(reparsed.entries[0].commands[0].rawArguments, [99])
    }
}
