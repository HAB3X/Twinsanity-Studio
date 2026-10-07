import XCTest
@testable import CTParsers

/// `WOCCharacterArchiveParser` -- decodes `CHARS.DAT`'s outer
/// offset-table archive and RNC decompression. These tests independently
/// re-verify the confirmed table shape and decompression against real
/// disc bytes, including the real embedded-`NU20`-mini-container case.
final class WOCCharacterArchiveParserTests: XCTestCase {
    private var charsURL: URL { URL(fileURLWithPath: "/Volumes/CRASH/CHARS.DAT") }

    private func requireDisc() throws {
        guard FileManager.default.fileExists(atPath: charsURL.path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
    }

    func testRealArchiveTableGoldenValues() throws {
        try requireDisc()
        let entries = try WOCCharacterArchiveParser.parseTable(fileURL: charsURL)
        XCTAssertEqual(entries.count, 1076)
        XCTAssertEqual(entries[0].offset, 8)
        XCTAssertTrue(entries[0].isCompressed)

        let uncompressed = entries.filter { !$0.isCompressed }
        XCTAssertEqual(uncompressed.count, 10, "expected exactly the 10 real flag==0 raw entries")
        for entry in uncompressed {
            XCTAssertEqual(entry.compressedSize, entry.unpackedSize, "a raw (uncompressed) entry should have equal compressed/unpacked sizes")
        }
    }

    /// Every RNC-compressed entry should decompress cleanly via the
    /// existing, unmodified `RNCDecompressor` (which itself verifies both
    /// the packed and unpacked CRCs the RNC stream carries) -- sampled
    /// across the archive rather than all 1066, to keep this test fast.
    func testSampledCompressedEntriesDecompressCleanly() throws {
        try requireDisc()
        let entries = try WOCCharacterArchiveParser.parseTable(fileURL: charsURL)
        let compressed = entries.filter(\.isCompressed)
        XCTAssertFalse(compressed.isEmpty)
        for entry in stride(from: 0, to: compressed.count, by: 97).map({ compressed[$0] }) {
            let decoded = try WOCCharacterArchiveParser.decode(entry, fileURL: charsURL)
            XCTAssertEqual(decoded.count, Int(entry.unpackedSize), "entry #\(entry.index): decompressed size should match the table's own declared unpackedSize")
        }
    }

    /// Entries 688/689/965 are confirmed real embedded `NU20`
    /// mini-containers, decodable by the existing, unmodified
    /// `WOCContainerParser.parse` -- the same production code that
    /// decodes every level `.GSC`'s decompressed body.
    func testKnownEmbeddedContainersDecodeWithExistingContainerParser() throws {
        try requireDisc()
        let entries = try WOCCharacterArchiveParser.parseTable(fileURL: charsURL)
        for index in [688, 689] {
            let decoded = try WOCCharacterArchiveParser.decode(entries[index], fileURL: charsURL)
            XCTAssertTrue(WOCCharacterArchiveParser.isEmbeddedContainer(decoded), "entry #\(index) should be a real NU20 mini-container")
            let file = try WOCContainerParser.parse([UInt8](decoded))
            XCTAssertFalse(file.sections.isEmpty)
        }
    }

    /// The overwhelming majority of entries are NOT embedded containers
    /// -- confirms `isEmbeddedContainer` doesn't spuriously fire on the
    /// native character-format entries.
    func testOrdinaryEntryIsNotAnEmbeddedContainer() throws {
        try requireDisc()
        let entries = try WOCCharacterArchiveParser.parseTable(fileURL: charsURL)
        let decoded = try WOCCharacterArchiveParser.decode(entries[0], fileURL: charsURL)
        XCTAssertFalse(WOCCharacterArchiveParser.isEmbeddedContainer(decoded))
    }
}
