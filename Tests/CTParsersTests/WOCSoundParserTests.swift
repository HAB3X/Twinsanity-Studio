import XCTest
@testable import CTParsers

final class WOCSoundParserTests: XCTestCase {
    private var sfxURL: URL { URL(fileURLWithPath: "/Volumes/CRASH/SFX.DAT") }

    private func requireDisc() throws {
        guard FileManager.default.fileExists(atPath: sfxURL.path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
    }

    /// Golden-value regression: hand-verified against the real disc via an
    /// independent Python re-implementation (not reused from the agent's
    /// script) before being pinned here -- record count, sector-aligned
    /// offset chain for all 781 consecutive pairs, and the outer table's
    /// `size` matching each entry's own VAG header exactly.
    func testRealArchiveTableGoldenValues() throws {
        try requireDisc()
        let entries = try WOCSoundParser.parseTable(fileURL: sfxURL)
        XCTAssertEqual(entries.count, 782)
        XCTAssertEqual(entries[0].offset, 2048)
        XCTAssertEqual(entries[0].size, 4016)
        XCTAssertEqual(entries[1].offset, 6144)

        for i in 1..<entries.count {
            let expected = ((entries[i - 1].offset + entries[i - 1].size + 2047) / 2048) * 2048
            XCTAssertEqual(entries[i].offset, expected, "sector-alignment chain broke at index \(i)")
        }
    }

    /// Decodes a handful of real entries spread across the archive and
    /// checks for real-waveform statistics (RMS energy present, no NaNs,
    /// plausible sample rates) rather than a golden byte match -- ADPCM
    /// decode output is high-volume and not hand-verifiable byte-by-byte,
    /// but a silent/garbage decode would fail these checks.
    func testRealEntriesDecodeToPlausibleAudio() throws {
        try requireDisc()
        let entries = try WOCSoundParser.parseTable(fileURL: sfxURL)
        for index in [0, 1, 100, 500, 781] {
            let entry = entries[index]
            let clip = try WOCSoundParser.decode(entry, fileURL: sfxURL)
            XCTAssertTrue(clip.sampleRate == 11025 || clip.sampleRate == 22050, "unexpected sample rate \(clip.sampleRate) at index \(index)")
            XCTAssertFalse(clip.samples.isEmpty)

            let sumSquares = clip.samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            let rms = (sumSquares / Double(clip.samples.count)).squareRoot()
            XCTAssertGreaterThan(rms, 50, "entry \(index) decoded to near-silence (rms \(rms)) -- likely a decode bug")
        }
    }

    /// Golden-value regression: independently re-verified directly against
    /// the real archive (a standalone Python re-implementation, not reused
    /// from any agent script) before being pinned here -- entries #402/403
    /// both carry the `"D:\CRASHM~1\AIFS"` embedded path and identical size.
    func testKnownMusicPairHasExpectedEmbeddedPathAndSize() throws {
        try requireDisc()
        let entries = try WOCSoundParser.parseTable(fileURL: sfxURL)
        let left = entries[402]
        let right = entries[403]
        XCTAssertEqual(left.size, right.size)
        let leftField = try WOCSoundParser.readEmbeddedPathField(left, fileURL: sfxURL)
        let rightField = try WOCSoundParser.readEmbeddedPathField(right, fileURL: sfxURL)
        XCTAssertTrue(leftField.contains("CRASHM"), "expected a CRASH MUSIC path, got \(leftField)")
        XCTAssertTrue(rightField.contains("CRASHM"), "expected a CRASH MUSIC path, got \(rightField)")
    }

    /// Full-archive regression: exactly 36 clean pairs, matching the
    /// independently re-verified sweep (72 CRASHM-tagged entries, all
    /// forming consecutive equal-size pairs, zero anomalies).
    func testFindsExactlyThirtySixMusicTracks() throws {
        try requireDisc()
        let entries = try WOCSoundParser.parseTable(fileURL: sfxURL)
        let tracks = try WOCSoundParser.findMusicTracks(in: entries, fileURL: sfxURL)
        XCTAssertEqual(tracks.count, 36)
        for track in tracks {
            XCTAssertEqual(track.right.index, track.left.index + 1, "music track channels should be consecutive indices")
            XCTAssertEqual(track.left.size, track.right.size, "music track channels should be equal size")
        }
    }

    /// An ordinary short SFX entry should never spuriously get tagged.
    func testOrdinarySFXEntryIsNotTaggedAsMusic() throws {
        try requireDisc()
        let entries = try WOCSoundParser.parseTable(fileURL: sfxURL)
        let field = try WOCSoundParser.readEmbeddedPathField(entries[0], fileURL: sfxURL)
        XCTAssertFalse(field.contains("CRASHM"))
    }
}
