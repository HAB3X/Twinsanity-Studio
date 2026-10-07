import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class SoundEffectParserTests: XCTestCase {
    func testSampleRateTableMatchesReference() {
        XCTAssertEqual(SoundEffectParser.sampleRate(forFreqFac: 0x2), 8000)
        XCTAssertEqual(SoundEffectParser.sampleRate(forFreqFac: 0x7), 22050)
        XCTAssertEqual(SoundEffectParser.sampleRate(forFreqFac: 0xE), 44100)
        XCTAssertEqual(SoundEffectParser.sampleRate(forFreqFac: 0x10), 48000)
        XCTAssertNil(SoundEffectParser.sampleRate(forFreqFac: 0x99), "Unrecognized FreqFac values must not be guessed at.")
    }

    /// 22-byte header layout ported from `SoundEffect.cs`:
    /// Head(4) + UnkFlag(1) + FreqFac(1) + Param1..4(2 each) + SoundSize(4) + SoundOffset(4).
    func testParseHeaderReadsExactly22Bytes() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)      // Head
        w.writeUInt8(0)       // UnkFlag
        w.writeUInt8(0xE)     // FreqFac -> 44100 Hz
        w.writeUInt16(0); w.writeUInt16(0); w.writeUInt16(0); w.writeUInt16(0) // Param1..4
        w.writeUInt32(16)     // SoundSize
        w.writeUInt32(100)    // SoundOffset

        XCTAssertEqual(w.count, 22)

        var cursor = BinaryCursor(data: w.data)
        let record = try SoundEffectParser.parseHeader(&cursor, recordID: 5)

        XCTAssertEqual(record.freqFac, 0xE)
        XCTAssertEqual(record.soundSize, 16)
        XCTAssertEqual(record.soundOffset, 100)
        XCTAssertEqual(cursor.position, w.count)
    }

    func testResolveSlicesFromExtraDataAtSoundOffset() throws {
        var extra = Data(repeating: 0xAA, count: 100) // padding before the sound
        var line = [UInt8](repeating: 0, count: 16)
        line[1] = 7 // end-of-stream, decodes to zero samples but must not fail
        extra.append(contentsOf: line)
        extra.append(Data(repeating: 0xBB, count: 20)) // padding after

        let record = SoundEffectParser.RawRecord(recordID: 1, freqFac: 0x7, soundSize: 16, soundOffset: 100)
        let asset = SoundEffectParser.resolve(record, extraData: extra)

        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.sampleRateHz, 22050)
        XCTAssertEqual(asset?.pcmSamples, [])
    }

    func testResolveReturnsNilForOutOfBoundsOffset() {
        let record = SoundEffectParser.RawRecord(recordID: 1, freqFac: 0x7, soundSize: 999, soundOffset: 0)
        XCTAssertNil(SoundEffectParser.resolve(record, extraData: Data(count: 10)))
    }

    func testResolveReturnsNilForUnrecognizedFreqFac() {
        let record = SoundEffectParser.RawRecord(recordID: 1, freqFac: 0x99, soundSize: 0, soundOffset: 0)
        XCTAssertNil(SoundEffectParser.resolve(record, extraData: Data()))
    }

    /// "Sound Import" write-back needs the audio's real *absolute file*
    /// byte range, not just its offset within `extraData`, this pins the
    /// arithmetic (`extraDataAbsoluteFileOffset + record.soundOffset`,
    /// length == `record.soundSize`) callers rely on.
    func testResolvePopulatesAbsoluteSourceByteRangeWhenGivenABaseOffset() throws {
        var extra = Data(repeating: 0xAA, count: 100)
        var line = [UInt8](repeating: 0, count: 16)
        line[1] = 7
        extra.append(contentsOf: line)

        let record = SoundEffectParser.RawRecord(recordID: 1, freqFac: 0x7, soundSize: 16, soundOffset: 100)
        let asset = try XCTUnwrap(SoundEffectParser.resolve(record, extraData: extra, extraDataAbsoluteFileOffset: 5000))

        let range = try XCTUnwrap(asset.sourceAudioByteRange)
        XCTAssertEqual(range.offset, 5100) // 5000 (section base) + 100 (soundOffset)
        XCTAssertEqual(range.length, 16)
    }

    func testResolveLeavesSourceByteRangeNilWithoutABaseOffset() throws {
        var extra = Data(repeating: 0xAA, count: 100)
        var line = [UInt8](repeating: 0, count: 16)
        line[1] = 7
        extra.append(contentsOf: line)

        let record = SoundEffectParser.RawRecord(recordID: 1, freqFac: 0x7, soundSize: 16, soundOffset: 100)
        let asset = try XCTUnwrap(SoundEffectParser.resolve(record, extraData: extra))
        XCTAssertNil(asset.sourceAudioByteRange)
    }
}
