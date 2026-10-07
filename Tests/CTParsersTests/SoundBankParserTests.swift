import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class SoundBankParserTests: XCTestCase {
    /// One mono entry, one reserved entry, matches the real `MHWorker.
    /// LoadMH`/`LoadBuffer` layout exactly, including the `MSVp` header
    /// this session verified against real `ENGLISH.MH`/`.MB` bytes.
    func testParsesMonoAndReservedEntries() throws {
        var mh = BinaryWriter()
        mh.writeUInt32(2) // soundCount
        mh.writeUInt32(65536) // interleave

        // Entry 0: mono, real ADPCM data at .MB offset 0.
        mh.writeUInt32(0) // type: mono
        mh.writeUInt32(16) // size: one ADPCM line
        mh.writeUInt32(0) // offset
        mh.writeUInt32(32000) // sampleRateHz (MH copy)
        mh.writeUInt32(0) // skip

        // Entry 1: reserved (empty).
        mh.writeUInt32(2)
        mh.writeUInt32(0)
        mh.writeUInt32(0)
        mh.writeUInt32(0)
        mh.writeUInt32(0)

        var mb = BinaryWriter()
        mb.writeASCIIString("MSVp") // magic
        mb.writeBytes([0, 0, 0, 32]) // version
        mb.writeUInt32(0) // unused
        mb.writeBytes([0, 0, 0, 16]) // size-48, big-endian (unused by the parser)
        mb.writeBytes([0, 0, 0x7d, 0]) // sampleRateHz = 32000, big-endian
        mb.writeUInt32(0); mb.writeUInt32(0); mb.writeUInt32(0) // 3 unused uint32s
        mb.writeASCIIString("TestSound") // name, padded below
        mb.writeBytes([UInt8](repeating: 0, count: 16 - "TestSound".utf8.count))
        // One real ADPCM line: factor=0, predict=0, low nibble=1 -> first sample 4096, then end-of-stream flag.
        var adpcmLine = [UInt8](repeating: 0, count: 16)
        adpcmLine[2] = 0x01
        mb.writeBytes(adpcmLine)

        let bank = try SoundBankParser.parse(mhData: mh.data, mbData: mb.data, sourceLabel: "TEST")

        XCTAssertEqual(bank.interleave, 65536)
        XCTAssertEqual(bank.entries.count, 2)

        let mono = bank.entries[0]
        XCTAssertEqual(mono.kind, .mono)
        XCTAssertEqual(mono.name, "TestSound")
        XCTAssertEqual(mono.sampleRateHz, 32000)
        XCTAssertEqual(mono.sound?.pcmSamples.first, 4096)

        let reserved = bank.entries[1]
        XCTAssertEqual(reserved.kind, .reserved)
        XCTAssertNil(reserved.sound)
        XCTAssertNil(reserved.name)
    }

    /// A stereo entry whose offset/size don't fit inside the `.MB` data is
    /// reported honestly (kind + metadata) without a fabricated decode , 
    /// `rawData` (and therefore `sound`) stay `nil` rather than guessing.
    func testStereoEntryReportsMetadataWithoutFabricatingAudio() throws {
        var mh = BinaryWriter()
        mh.writeUInt32(1)
        mh.writeUInt32(65536)
        mh.writeUInt32(1) // type: stereo
        mh.writeUInt32(32)
        mh.writeUInt32(0)
        mh.writeUInt32(44100)
        mh.writeUInt32(0)

        let bank = try SoundBankParser.parse(mhData: mh.data, mbData: Data(), sourceLabel: "TEST")
        let entry = try XCTUnwrap(bank.entries.first)
        XCTAssertEqual(entry.kind, .stereo)
        XCTAssertNil(entry.sound)
        XCTAssertEqual(entry.sampleRateHz, 44100)
    }

    /// A stereo entry's real, untouched on-disk bytes (raw interleaved
    /// ADPCM directly at `offset`, no MSVp header, per this format's own
    /// layout) must be captured into `rawData` regardless of whether the
    /// bytes happen to be enough for a real decode, so `MBWriter` can
    /// round-trip a bank containing it either way. This fixture's 8 bytes
    /// aren't a multiple of 32 (one L+R line pair), so `toPCMStereo`
    /// correctly refuses to decode them, `sound` is still non-nil (a
    /// real decode was attempted) but reports zero samples rather than
    /// fabricating audio from data too short to be a real line pair.
    func testStereoEntryCapturesRawBytesForRoundTrip() throws {
        var mh = BinaryWriter()
        mh.writeUInt32(1)
        mh.writeUInt32(65536)
        mh.writeUInt32(1) // type: stereo
        mh.writeUInt32(8) // size
        mh.writeUInt32(4) // offset
        mh.writeUInt32(44100)
        mh.writeUInt32(0)

        var mb = BinaryWriter()
        mb.writeBytes([0xAA, 0xBB, 0xCC, 0xDD]) // 4 bytes of unrelated leading data
        let expectedRawBytes: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
        mb.writeBytes(expectedRawBytes)

        let bank = try SoundBankParser.parse(mhData: mh.data, mbData: mb.data, sourceLabel: "TEST")
        let entry = try XCTUnwrap(bank.entries.first)
        XCTAssertEqual(entry.kind, .stereo)
        XCTAssertEqual(entry.sound?.pcmSamples, [], "8 bytes isn't a multiple of 32, toPCMStereo must refuse rather than fabricate")
        XCTAssertEqual(entry.sound?.rightChannelSamples, [])
        XCTAssertEqual(entry.rawData.map(Array.init), expectedRawBytes, "the real bytes must still be captured for MBWriter's verbatim round-trip regardless of decode outcome")
    }

    /// A real, decodable stereo entry (32-byte-aligned, real interleave)
    /// must actually decode into separate left/right channels, the
    /// production path this build previously left undecoded entirely.
    func testStereoEntryDecodesRealAudioWhenDataIsWellFormed() throws {
        var mh = BinaryWriter()
        mh.writeUInt32(1)
        mh.writeUInt32(16) // interleave: one 16-byte line per block
        mh.writeUInt32(1) // type: stereo
        mh.writeUInt32(32) // size: one L line + one R line
        mh.writeUInt32(0) // offset
        mh.writeUInt32(44100)
        mh.writeUInt32(0)

        var lLine = [UInt8](repeating: 0, count: 16)
        lLine[2] = 0x01 // first L sample = 1 << 12 = 4096
        var rLine = [UInt8](repeating: 0, count: 16)
        rLine[2] = 0x02 // first R sample = 2 << 12 = 8192

        var mb = BinaryWriter()
        mb.writeBytes(lLine)
        mb.writeBytes(rLine)

        let bank = try SoundBankParser.parse(mhData: mh.data, mbData: mb.data, sourceLabel: "TEST")
        let entry = try XCTUnwrap(bank.entries.first)
        XCTAssertEqual(entry.kind, .stereo)
        XCTAssertEqual(entry.sound?.pcmSamples.first, 4096)
        XCTAssertEqual(entry.sound?.rightChannelSamples?.first, 8192)
    }

    /// An offset that doesn't fit inside the `.MB` data (a real possibility
    /// this format allows for) must not crash the parse, the entry just
    /// comes back with no name/sound.
    func testOutOfBoundsOffsetDoesNotCrashOrFabricate() throws {
        var mh = BinaryWriter()
        mh.writeUInt32(1)
        mh.writeUInt32(65536)
        mh.writeUInt32(0) // mono
        mh.writeUInt32(16)
        mh.writeUInt32(1_000_000) // offset way past the tiny .MB below
        mh.writeUInt32(32000)
        mh.writeUInt32(0)

        let bank = try SoundBankParser.parse(mhData: mh.data, mbData: Data([0, 1, 2, 3]), sourceLabel: "TEST")
        let entry = try XCTUnwrap(bank.entries.first)
        XCTAssertNil(entry.sound)
        XCTAssertNil(entry.name)
    }
}
