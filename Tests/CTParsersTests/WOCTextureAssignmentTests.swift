import XCTest
@testable import CTParsers

/// `WOCContainerParser.parseTextureAssignments` -- decodes `TAS0`, the
/// first confirmed texture/mesh-binding data found in the WoC format.
/// These tests independently re-verify the confirmed invariants directly
/// against real disc bytes (not just trusting a report): the section
/// parses without truncation on every real file that has it, and every
/// decoded texture index is a valid index into that same file's own
/// `scanTextureEntries` result.
final class WOCTextureAssignmentTests: XCTestCase {
    private func loadAndDecompressRealGSC(_ relativePath: String) throws -> [UInt8] {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try RNCDecompressor.decompress([UInt8](data), verifyCRC: true)
    }

    /// Every real file with a `TAS0` section that's mounted locally: the
    /// section must parse cleanly (no truncation), and every texture
    /// index in its trailing list must be a valid index into that same
    /// file's own real texture list.
    func testTextureIndicesAreValidAgainstRealTextureList() throws {
        let samples = [
            "A/DROID/DROID.GSC",
            "C/SNOW_B/SNOW_B.GSC",
            "C/SPACE_B/SPACE_B.GSC",
            "C/WEATH_B/WEATH_B.GSC",
            "A/VOLCANO/VOLCANO.GSC",
            "B/OUTRO/ICEBERG.GSC",
            "B/OUTRO/STATION.GSC",
        ]
        var checked = 0
        for relativePath in samples {
            let decoded = try loadAndDecompressRealGSC(relativePath)
            let file = try WOCContainerParser.parse(decoded)
            guard let tas0 = file.sections.first(where: { $0.tag == "TAS0" }) else { continue }
            guard let tst0 = file.sections.first(where: { $0.tag == "TST0" }) else { continue }

            let assignments = try WOCContainerParser.parseTextureAssignments(tas0.payload)
            let textureCount = WOCContainerParser.scanTextureEntries(tst0.payload).count

            XCTAssertFalse(assignments.textureIndices.isEmpty, "\(relativePath): expected a non-empty texture-index list")
            for index in assignments.textureIndices {
                XCTAssertLessThan(Int(index), textureCount, "\(relativePath): texture index \(index) out of bounds for \(textureCount) real textures")
            }

            // The per-entry referencedIndex field is strictly increasing --
            // same curated-ascending-pointer shape already confirmed for
            // SPEC.referencedInstanceIndex.
            var previous: UInt32?
            for entry in assignments.entries {
                if let previous {
                    XCTAssertGreaterThan(entry.referencedIndex, previous, "\(relativePath): referencedIndex should be strictly increasing")
                }
                previous = entry.referencedIndex
            }

            checked += 1
        }
        guard checked > 0 else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
    }

    /// `frameStartIndex`/`frameCount` golden-value regression:
    /// `STATION.GSC`'s 9 real entries, hand-verified against the real
    /// bytes -- including the two repeated-group cases (entries 3/4 and
    /// 7/8 claim identical runs) that are the strongest evidence for the
    /// "these are animation frame sequences" reading.
    func testRealStationGSCFrameGroupingGoldenValues() throws {
        let decoded = try loadAndDecompressRealGSC("B/OUTRO/STATION.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let tas0 = try XCTUnwrap(file.sections.first { $0.tag == "TAS0" })
        let set = try WOCContainerParser.parseTextureAssignments(tas0.payload)

        XCTAssertEqual(set.entries.count, 9)
        XCTAssertEqual(set.textureIndices, [
            44, 45, 46, 47, 49, 50, 51, 52, 53, 54, 51, 52, 53, 54, 55, 56, 57, 58,
            101, 102, 103, 104, 105, 101, 102, 103, 104, 105,
        ])

        let expectedGroups: [[UInt16]] = [
            [44, 45], [46, 47], [49, 50], [51, 52, 53, 54], [51, 52, 53, 54],
            [55, 56], [57, 58], [101, 102, 103, 104, 105], [101, 102, 103, 104, 105],
        ]
        for (i, entry) in set.entries.enumerated() {
            XCTAssertEqual(Array(set.frames(for: entry)), expectedGroups[i], "entry \(i)")
        }
        // Entries 3/4 and 7/8 claim the exact same run -- two different
        // objects sharing one animated texture, real supporting evidence
        // for the frame-sequence reading rather than a coincidence.
        XCTAssertEqual(Array(set.frames(for: set.entries[3])), Array(set.frames(for: set.entries[4])))
        XCTAssertEqual(Array(set.frames(for: set.entries[7])), Array(set.frames(for: set.entries[8])))
    }

    /// Full-corpus regression: `frameStartIndex` starts at 0, is a real
    /// cumulative running sum of prior `frameCount`s (not just
    /// coincidentally monotonic), and every entry's frames sum to exactly
    /// `textureIndices.count` with no leftover -- confirmed on all 7
    /// locally-mounted real files that have `TAS0`, zero exceptions.
    func testFrameGroupingAccountsForEveryIndexAcrossRealFiles() throws {
        let samples = [
            "A/DROID/DROID.GSC", "C/SNOW_B/SNOW_B.GSC", "C/SPACE_B/SPACE_B.GSC",
            "C/WEATH_B/WEATH_B.GSC", "A/VOLCANO/VOLCANO.GSC", "B/OUTRO/ICEBERG.GSC",
            "B/OUTRO/STATION.GSC",
        ]
        var checked = 0
        for relativePath in samples {
            let decoded = try loadAndDecompressRealGSC(relativePath)
            let file = try WOCContainerParser.parse(decoded)
            guard let tas0 = file.sections.first(where: { $0.tag == "TAS0" }) else { continue }
            let set = try WOCContainerParser.parseTextureAssignments(tas0.payload)

            var running: UInt32 = 0
            for entry in set.entries {
                XCTAssertEqual(entry.frameStartIndex, running, "\(relativePath): frameStartIndex should equal the running sum of prior frameCounts")
                running += UInt32(entry.frameCount)
            }
            XCTAssertEqual(Int(running), set.textureIndices.count, "\(relativePath): frame counts should sum to exactly textureIndices.count")
            checked += 1
        }
        guard checked > 0 else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
    }

    /// Every real 32-byte entry record must be captured intact (raw bytes
    /// round-trip) and the section must account for every byte -- no
    /// gap and no overrun -- confirming the `count*32 + 4 + listCount*2 +
    /// trailer` framing exactly, the same "confirmed by exact byte
    /// consumption" bar this codebase already holds its other decoded
    /// sections to.
    func testSectionAccountsForEveryByte() throws {
        let samples = [
            "A/DROID/DROID.GSC",
            "C/SNOW_B/SNOW_B.GSC",
            "A/VOLCANO/VOLCANO.GSC",
        ]
        var checked = 0
        for relativePath in samples {
            let decoded = try loadAndDecompressRealGSC(relativePath)
            let file = try WOCContainerParser.parse(decoded)
            guard let tas0 = file.sections.first(where: { $0.tag == "TAS0" }) else { continue }

            let assignments = try WOCContainerParser.parseTextureAssignments(tas0.payload)
            for entry in assignments.entries {
                XCTAssertEqual(entry.raw.count, 32, "\(relativePath): every TAS0 entry should be exactly 32 bytes")
            }
            let accounted = 8 + assignments.entries.count * 32 + 4 + assignments.textureIndices.count * 2 + assignments.trailer.count
            XCTAssertEqual(accounted, tas0.payload.count, "\(relativePath): TAS0 framing should account for every payload byte")
            checked += 1
        }
        guard checked > 0 else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
    }
}
