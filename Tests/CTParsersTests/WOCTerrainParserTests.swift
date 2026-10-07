import XCTest
import Foundation
@testable import CTParsers

final class WOCTerrainParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Confirmed by exact byte consumption on 3 real files of very
    /// different sizes -- the tail-record table boundary and count are
    /// exact, not approximate.
    func testRealTERFilesConsumeExactlyTheWholeFile() throws {
        let samples: [(path: String, expectedTailCount: Int)] = [
            ("A/AIRSHIP/AIRSHIP.TER", 5),
            ("A/DROID/DROID.TER", 47),
            ("A/WESTERN/WESTERN.TER", 189),
        ]
        for sample in samples {
            let data = try loadReal(sample.path)
            let file = try WOCTerrainParser.parse(data)
            XCTAssertEqual(file.tailRecords.count, sample.expectedTailCount, "tail record count for \(sample.path)")
            XCTAssertTrue(file.tailRecords.allSatisfy { $0.raw.count == 52 })
            XCTAssertFalse(file.mainBlock.isEmpty, "main block should be non-empty for \(sample.path)")
        }
    }

    /// Real `type` values should land in the confirmed enum range
    /// (`NORMAL=0, PLATFORM=1, WALLSPL=2, CRASHDATA=3, EMPTY=255`, from
    /// `OpenCrashWOC-main/code/src/gamelib/terrain.c`'s `ReadTerrain`) --
    /// a real, checkable signal that the source's tail-record field
    /// layout applies here, not just numeric plausibility.
    func testRealTailRecordTypesLandInTheConfirmedEnumRange() throws {
        let data = try loadReal("A/AIRSHIP/AIRSHIP.TER")
        let file = try WOCTerrainParser.parse(data)
        XCTAssertEqual(file.tailRecords.count, 5)
        let validTypes: Set<Int16> = [0, 1, 2, 3, 255]
        for record in file.tailRecords {
            XCTAssertTrue(validTypes.contains(record.type), "unexpected type \(record.type)")
        }
        XCTAssertTrue(file.tailRecords.contains { $0.type == 0 }, "AIRSHIP.TER should have at least one NORMAL terrain instance")
    }
}
