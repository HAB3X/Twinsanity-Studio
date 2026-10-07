import XCTest
import Foundation
@testable import CTParsers

final class WOCGrassParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Confirmed by exact byte consumption -- each of these files parses
    /// with zero leftover/underflow bytes.
    func testRealGRAFilesFormat3() throws {
        let samples: [(path: String, expectedCount: Int, firstName: String)] = [
            ("A/CORAL_C/CORAL.GRA", 26, "pinkweed"),
            ("A/JUNGLE_A/JUNGLE_A.GRA", 64, "flowers_02"),
            ("A/WESTERN/WESTERN.GRA", 26, "grass_02"),
        ]
        for sample in samples {
            let data = try loadReal(sample.path)
            let placements = try WOCGrassParser.parse(data)
            XCTAssertEqual(placements.count, sample.expectedCount, "count for \(sample.path)")
            XCTAssertEqual(placements[0].name, sample.firstName, "first name for \(sample.path)")
        }
    }

    func testRealVolcanoGRAFormat1() throws {
        let data = try loadReal("A/VOLCANO/VOLCANO.GRA")
        let placements = try WOCGrassParser.parse(data)
        XCTAssertEqual(placements.count, 9)
        XCTAssertEqual(placements[0].name, "grass_01")
    }
}
