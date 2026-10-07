import Foundation
import XCTest
import CTCore
import CTModels
import CTParsers

/// Tests for MHWriter and MBWriter functionality
final class SoundBankWriterTests: XCTestCase {

    func testMHWriterEncoding() throws {
        // Create a simple sound bank asset with one mono entry
        let entry = SoundBankEntry(
            index: 0,
            rawKind: SoundBankEntryKind.mono.rawValue,
            size: 100, // arbitrary size
            offset: 0, // will be set by parser, but for header we just need to write it
            sampleRateHz: 44100,
            skip: 0,
            name: "TEST",
            sound: SoundEffectAsset(
                id: 0,
                sampleRateHz: UInt16(44100),
                pcmSamples: [Int16](repeating: 0, count: 50) // 50 samples -> 100 bytes PCM
            )
        )

        let asset = SoundBankAsset(sourceLabel: "TEST_BANK", interleave: 0, entries: [entry])

        // Encode to MH format
        let mhData = try MHWriter.encode(asset)

        // Verify we got data back
        XCTAssertGreaterThan(mhData.count, 0)

        // Basic structure check: first 8 bytes should be count (1) and interleave (0)
        var cursor = BinaryCursor(data: mhData)
        let count = try cursor.readUInt32()
        let interleave = try cursor.readUInt32()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(interleave, 0)

        // Check the entry fields
        let rawKind = try cursor.readUInt32()
        let size = try cursor.readUInt32()
        let offset = try cursor.readUInt32()
        let sampleRate = try cursor.readUInt32()
        let skip = try cursor.readUInt32()

        XCTAssertEqual(rawKind, SoundBankEntryKind.mono.rawValue)
        XCTAssertEqual(size, 100)
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(sampleRate, 44100)
        XCTAssertEqual(skip, 0)
    }

    func testMBWriterEncoding() throws {
        // Create a simple mono entry with PCM data
        let pcmSamples = [Int16](repeating: 1000, count: 50) // 50 samples
        let sound = SoundEffectAsset(
            id: 0,
            sampleRateHz: UInt16(22050),
            pcmSamples: pcmSamples
        )

        // We'll need to determine the encoded ADPCM size - for simplicity, we can use a known size
        // In a real test we would encode and measure, but for now we'll use a placeholder
        let entrySize: UInt32 = 48 + 70 // MSVp header (48) + estimated ADPCM size

        let entry = SoundBankEntry(
            index: 0,
            rawKind: SoundBankEntryKind.mono.rawValue,
            size: entrySize,
            offset: 0,
            sampleRateHz: 22050,
            skip: 0,
            name: "TEST_MONO",
            sound: sound
        )

        let entries = [entry]

        // Encode to MB format
        let (mbData, _) = try MBWriter.encode(entries, interleave: 0)

        // Verify we got data back
        XCTAssertGreaterThan(mbData.count, 0)

        // Check for MSVp magic
        XCTAssertTrue(mbData.prefix(4).elementsEqual(Array("MSVp".utf8)), "Missing MSVp magic")

        // Version should be 1
        XCTAssertEqual(mbData[4], 0)
        XCTAssertEqual(mbData[5], 0)
        XCTAssertEqual(mbData[6], 0)
        XCTAssertEqual(mbData[7], 1)
    }

    /// The MSVp header's size field must reflect the real, just-encoded
    /// ADPCM byte count, not whatever `entry.size` the caller happened to
    /// supply beforehand. Deliberately passes a wildly wrong `entrySize`
    /// (9999) to prove the header isn't just echoing it back: a stale
    /// header size (this test's exact regression target) would show up
    /// here as `9999`, not the real payload length.
    func testMBWriterHeaderSizeReflectsRealEncodedLength() throws {
        let pcmSamples = [Int16](repeating: 1000, count: 50)
        let sound = SoundEffectAsset(id: 0, sampleRateHz: UInt16(22050), pcmSamples: pcmSamples)
        let entry = SoundBankEntry(
            index: 0,
            rawKind: SoundBankEntryKind.mono.rawValue,
            size: 9999, // deliberately wrong, must not end up in the header
            offset: 0,
            sampleRateHz: 22050,
            skip: 0,
            name: "TEST_MONO",
            sound: sound
        )

        let (mbData, correctedEntries) = try MBWriter.encode([entry], interleave: 0)
        let realPayloadLength = mbData.count - 48 // whole file minus the one 48-byte MSVp header

        // Header layout: magic(4) + version(4) + unused(4) + size(4), the
        // size field is bytes 12-15, not immediately after version.
        let sizeFieldBE = (UInt32(mbData[12]) << 24) | (UInt32(mbData[13]) << 16) | (UInt32(mbData[14]) << 8) | UInt32(mbData[15])
        XCTAssertEqual(sizeFieldBE, UInt32(realPayloadLength))
        XCTAssertNotEqual(sizeFieldBE, 9999, "header size field must not be the stale entry.size")
        XCTAssertEqual(correctedEntries.first?.size, UInt32(realPayloadLength), "corrected entry's own size must match what was actually written too")
    }

    /// `SoundBankParser.decodeMonoEntry` reads the sample rate at
    /// offset+16 genuinely MSB-first ("confirmed against real data" per
    /// its own doc comment), this pins the writer to produce bytes that
    /// round-trip through that exact reader, catching the double
    /// byte-swap regression (`.bigEndian` value + manual MSB-first
    /// extraction silently produces little-endian bytes) a sibling test
    /// for the size field already caught once.
    func testMBWriterSampleRateIsGenuinelyBigEndian() throws {
        let sampleRateHz: UInt16 = 0x5622 // 22050, high and low bytes both nonzero, so a swap is visible
        let sound = SoundEffectAsset(id: 0, sampleRateHz: sampleRateHz, pcmSamples: [Int16](repeating: 500, count: 20))
        let entry = SoundBankEntry(
            index: 0, rawKind: SoundBankEntryKind.mono.rawValue, size: 0, offset: 0,
            sampleRateHz: UInt32(sampleRateHz), skip: 0, name: "RATE_TEST", sound: sound
        )

        let (mbData, _) = try MBWriter.encode([entry], interleave: 0)
        // Sample rate lives at header offset 16 (magic 4 + version 4 + unused 4 + size 4).
        let rateBytes = mbData[(mbData.startIndex + 16)..<(mbData.startIndex + 20)]
        XCTAssertEqual(Array(rateBytes), [0x00, 0x00, 0x56, 0x22], "expected genuine big-endian (MSB first) bytes, matching SoundBankParser.decodeMonoEntry's own read order")
    }

    /// A `.stereo` entry with real captured `rawData` (this build's audio
    /// it can't decode/re-encode) must round-trip verbatim, no MSVp
    /// header, exactly the original bytes, matching the real on-disk
    /// layout `SoundBankParser`'s own doc comment describes.
    func testMBWriterWritesStereoEntryRawDataVerbatim() throws {
        let rawBytes = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
        let entry = SoundBankEntry(
            index: 0, rawKind: SoundBankEntryKind.stereo.rawValue, size: UInt32(rawBytes.count), offset: 0,
            sampleRateHz: 44100, skip: 0, name: "Stereo", sound: nil, rawData: rawBytes
        )

        let (mbData, correctedEntries) = try MBWriter.encode([entry], interleave: 0)
        XCTAssertEqual(mbData, rawBytes, "stereo entries have no MSVp header, the whole .MB output for this one entry should be exactly its raw bytes")
        XCTAssertEqual(correctedEntries.first?.offset, 0)
        XCTAssertEqual(correctedEntries.first?.size, UInt32(rawBytes.count))
    }

    /// A `.stereo` entry with neither `sound` nor `rawData` (can't be
    /// re-encoded and was never captured) must throw a clear error rather
    /// than silently emitting a corrupt/empty payload.
    func testMBWriterThrowsForStereoEntryMissingRawData() {
        let entry = SoundBankEntry(
            index: 3, rawKind: SoundBankEntryKind.stereo.rawValue, size: 8, offset: 0,
            sampleRateHz: 44100, skip: 0, name: "Stereo", sound: nil, rawData: nil
        )
        XCTAssertThrowsError(try MBWriter.encode([entry], interleave: 0)) { error in
            guard case MBWriterError.missingAudioData(let index) = error else {
                return XCTFail("Expected .missingAudioData, got \(error)")
            }
            XCTAssertEqual(index, 3)
        }
    }

    /// The actual regression this return-type change exists for: when one
    /// entry's real encoded size differs from its stale pre-edit `size`
    /// (exactly what happens whenever `.mono` audio is edited), every
    /// entry *after* it must still get the real offset it actually landed
    /// at in the `.MB` output, not the stale offset carried over from the
    /// original parse. Two mono entries, the first's declared `size` (999)
    /// deliberately wrong so its real encoded length is smaller.
    func testMBWriterCorrectedOffsetsAccountForRealEncodedSizeOfEarlierEntries() throws {
        let firstSound = SoundEffectAsset(id: 0, sampleRateHz: 22050, pcmSamples: [Int16](repeating: 100, count: 10))
        let firstEntry = SoundBankEntry(
            index: 0, rawKind: SoundBankEntryKind.mono.rawValue, size: 999, offset: 999, // both deliberately wrong
            sampleRateHz: 22050, skip: 0, name: "FIRST", sound: firstSound
        )
        let secondSound = SoundEffectAsset(id: 1, sampleRateHz: 22050, pcmSamples: [Int16](repeating: 200, count: 10))
        let secondEntry = SoundBankEntry(
            index: 1, rawKind: SoundBankEntryKind.mono.rawValue, size: 999, offset: 999, // stale, from the original (different) parse
            sampleRateHz: 22050, skip: 0, name: "SECOND", sound: secondSound
        )

        let (mbData, correctedEntries) = try MBWriter.encode([firstEntry, secondEntry], interleave: 0)

        XCTAssertEqual(correctedEntries.count, 2)
        // First entry always starts at 0, the real, not stale (999), offset.
        XCTAssertEqual(correctedEntries[0].offset, 0)
        XCTAssertNotEqual(correctedEntries[0].size, 999, "must be the real encoded size, not the stale declared one")
        // Second entry must start exactly where the first's real bytes
        // (48-byte header + its real encoded ADPCM length) actually ended
        //, not at the stale 999. This is the actual regression: before
        // this fix, MHWriter would have written 999 here regardless of
        // what MBWriter really produced.
        let firstEntryRealTotalLength = 48 + Int(correctedEntries[0].size)
        XCTAssertEqual(correctedEntries[1].offset, UInt32(firstEntryRealTotalLength))
        XCTAssertEqual(Int(correctedEntries[1].offset) + 48 + Int(correctedEntries[1].size), mbData.count, "second entry's own corrected offset+size must exactly account for the rest of the real output")
    }

    func testDataExtensions() {
        // Test that our Data extensions work correctly
        var testData = Data()

        testData.append(littleEndian: UInt16(0x1234))
        testData.append(littleEndian: UInt32(0x12345678))

        XCTAssertEqual(testData.count, 6)
        XCTAssertEqual(testData[0], 0x34)   // Little endian: low byte first
        XCTAssertEqual(testData[1], 0x12)
        XCTAssertEqual(testData[2], 0x78)
        XCTAssertEqual(testData[3], 0x56)
        XCTAssertEqual(testData[4], 0x34)
        XCTAssertEqual(testData[5], 0x12)
    }
}