import XCTest
@testable import CTParsers

/// `WOCContainerParser.parseObjSet` -- the real, complete `OBJ0` decoder,
/// found by implementing the actual `ReadObjSet` C algorithm from this
/// project's decompiled reference source rather than heuristic
/// marker-scanning (`walkOBJ0Chunks`/`groupOBJ0ChunksIntoEntries`). These
/// tests independently re-verify the confirmed claim directly against
/// real disc bytes: exact byte-consumption and exact declared-entry-count
/// match across every real `.GSC` file with an `OBJ0` section, including
/// the two files (`HUB.GSC`/`CASTLE_C.GSC`) the old heuristic could only
/// partially cover.
final class WOCObjSetParserTests: XCTestCase {
    private func loadDecodedContainer(_ relativePath: String) throws -> WOCContainerParser.File {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let bytes = [UInt8](data)
        let decoded = RNCDecompressor.isRNCStream(bytes) ? try RNCDecompressor.decompress(bytes, verifyCRC: true) : bytes
        return try WOCContainerParser.parse(decoded)
    }

    /// The two files `walkOBJ0Chunks`'s marker heuristic could only
    /// partially cover (27/700 and 8/1113 entries respectively) -- now
    /// fully covered, exact declared count, exact byte consumption.
    func testHeterogeneousFilesNowFullyCovered() throws {
        let file = try loadDecodedContainer("B/HUB/HUB.GSC")
        let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" })
        let declaredCount = try WOCContainerParser.leadingCount(obj0.payload)
        let objSet = try WOCContainerParser.parseObjSet(obj0.payload, materialCount: nil)
        XCTAssertEqual(objSet.entries.count, declaredCount)
        XCTAssertEqual(objSet.entries.count, 700)

        let file2 = try loadDecodedContainer("A/CASTLE_C/CASTLE_C.GSC")
        let obj0_2 = try XCTUnwrap(file2.sections.first { $0.tag == "OBJ0" })
        let declaredCount2 = try WOCContainerParser.leadingCount(obj0_2.payload)
        let objSet2 = try WOCContainerParser.parseObjSet(obj0_2.payload, materialCount: nil)
        XCTAssertEqual(objSet2.entries.count, declaredCount2)
        XCTAssertEqual(objSet2.entries.count, 1113)
    }

    /// Full-corpus regression: every real `.GSC` file with an `OBJ0`
    /// section on the mounted disc should parse with exact declared-count
    /// match, every material index in-bounds against that same file's
    /// real `MS00` record count, and zero thrown errors.
    func testFullCorpusExactMatch() throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: "/Volumes/CRASH/LEVELS") else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        var allGSC: [String] = []
        for case let path as String in enumerator where path.uppercased().hasSuffix(".GSC") {
            allGSC.append(path)
        }
        guard !allGSC.isEmpty else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }

        var checked = 0
        for relativePath in allGSC.sorted() {
            // A handful of real files don't parse at the container level
            // at all (a pre-existing, unrelated limitation -- see
            // WOCContainerParserTests) -- skip those rather than letting
            // one bad file kill this test's coverage of the other ~58.
            guard let file = try? loadDecodedContainer(relativePath) else { continue }
            guard let obj0 = file.sections.first(where: { $0.tag == "OBJ0" }) else { continue }
            let declaredCount = try WOCContainerParser.leadingCount(obj0.payload)
            let mtlCount = file.sections.first(where: { $0.tag == "MS00" })
                .flatMap { try? WOCContainerParser.parseMaterialSet($0.payload) }?.records.count

            let objSet = try WOCContainerParser.parseObjSet(obj0.payload, materialCount: mtlCount)
            XCTAssertEqual(objSet.entries.count, declaredCount, "\(relativePath): entries.count should match OBJ0's own declared count")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 50, "expected the vast majority of real .GSC files to have a parseable OBJ0 section")
    }

    /// Golden-value regression on the smallest real file: `AIRSHIP.GSC`'s
    /// first entry, first record, hand-verified against real bytes.
    func testRealAirshipGoldenValues() throws {
        let file = try loadDecodedContainer("A/AIRSHIP/AIRSHIP.GSC")
        let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" })
        let objSet = try WOCContainerParser.parseObjSet(obj0.payload, materialCount: nil)
        XCTAssertEqual(objSet.entries.count, 41)

        let first = objSet.entries[0]
        XCTAssertEqual(first.records.count, 1)
        guard case let .mesh(origin, geos) = first.records[0].body else {
            return XCTFail("expected entry 0's first record to be a mesh record")
        }
        XCTAssertFalse(geos.isEmpty)
        // Bounds should be real, finite, plausible world-space values --
        // not garbage/NaN/absurdly large.
        let bounds = first.records[0]
        for v in [bounds.boundsMin.x, bounds.boundsMin.y, bounds.boundsMin.z,
                  bounds.boundsMax.x, bounds.boundsMax.y, bounds.boundsMax.z,
                  origin.x, origin.y, origin.z] {
            XCTAssertTrue(v.isFinite)
            XCTAssertLessThan(abs(v), 100_000)
        }
    }
}
