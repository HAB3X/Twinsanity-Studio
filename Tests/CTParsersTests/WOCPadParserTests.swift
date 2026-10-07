import XCTest
import Foundation
@testable import CTParsers

final class WOCPadParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Confirmed by exact byte consumption -- 40 + count*20 == fileSize
    /// on every file checked, not just an even division.
    func testRealPADFilesConsumeExactlyTheWholeFile() throws {
        let samples: [(path: String, expectedCount: Int, expectedMagic: UInt32)] = [
            ("A/VOLCANO/VOLCANO.PAD", 1384, 35998),
            ("A/CASTLE/CASTLE.PAD", 1819, 7198),
            ("A/GARDEN/GARDEN.PAD", 1625, 35998),
        ]
        for sample in samples {
            let data = try loadReal(sample.path)
            let file = try WOCPadParser.parse(data)
            XCTAssertEqual(file.records.count, sample.expectedCount, "record count for \(sample.path)")
            XCTAssertEqual(file.magic, sample.expectedMagic, "magic for \(sample.path)")
            XCTAssertTrue(file.records.allSatisfy { $0.raw.count == 20 })
        }
    }

    /// Real-data regression for the confirmed `angleDegrees` field: spans
    /// essentially the full -180...180 range and varies smoothly
    /// record-to-record (not scattered/random).
    func testAngleFieldSpansFullRangeAndVariesSmoothly() throws {
        let data = try loadReal("A/VOLCANO/VOLCANO.PAD")
        let file = try WOCPadParser.parse(data)
        let angles = file.records.map(\.angleDegrees)
        XCTAssertLessThan(angles.min() ?? 0, -150)
        XCTAssertGreaterThan(angles.max() ?? 0, 150)

        var deltas: [Float] = []
        for i in 1..<angles.count {
            deltas.append(abs(angles[i] - angles[i - 1]))
        }
        let median = deltas.sorted()[deltas.count / 2]
        XCTAssertLessThan(median, 5, "consecutive angle deltas should mostly be small (smooth sampling), not scattered")
    }

    /// Real-data regression for the confirmed reserved bytes: relative
    /// offsets 4-8, 12, 14-16 should be exactly zero in every record of a
    /// real file.
    func testReservedBytesAreAlwaysZero() throws {
        let data = try loadReal("A/GARDEN/GARDEN.PAD")
        let file = try WOCPadParser.parse(data)
        for record in file.records {
            let bytes = [UInt8](record.raw)
            for offset in [4, 5, 6, 7, 8, 12, 14, 15, 16] {
                XCTAssertEqual(bytes[offset], 0, "relative offset \(offset) should always be 0")
            }
        }
    }
}
