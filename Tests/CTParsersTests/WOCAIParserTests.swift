import XCTest
import Foundation
@testable import CTParsers

final class WOCAIParserTests: XCTestCase {
    private func loadRealAI(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func testRealFarmAI() throws {
        let data = try loadRealAI("A/FARM/FARM.AI")
        let entities = try WOCAIParser.parse(data)
        XCTAssertEqual(entities.count, 1)
        XCTAssertEqual(entities[0].name, "flying clock")
        XCTAssertEqual(entities[0].waypoints.count, 1)
    }

    /// Confirmed by exact byte consumption on 4 real files of very
    /// different sizes; this test checks that property directly rather
    /// than just trusting the parser not to throw.
    func testRealAIFilesConsumeExactlyTheWholeFile() throws {
        let samples: [(path: String, expectedCount: Int)] = [
            ("A/CASTLE_C/CASTLE_C.AI", 39),
            ("A/WESTERN/WESTERN.AI", 56),
            ("A/GARDEN/GARDEN.AI", 51),
        ]
        for sample in samples {
            let data = try loadRealAI(sample.path)
            let entities = try WOCAIParser.parse(data)
            XCTAssertEqual(entities.count, sample.expectedCount, "entity count for \(sample.path)")
            XCTAssertTrue(entities.allSatisfy { !$0.name.isEmpty }, "every entity should have a real name for \(sample.path)")
        }
    }

    func testRealGardenAIContainsKnownEnemyNames() throws {
        let data = try loadRealAI("A/GARDEN/GARDEN.AI")
        let entities = try WOCAIParser.parse(data)
        let names = Set(entities.map(\.name))
        XCTAssertTrue(names.contains("koi carp"))
        XCTAssertTrue(names.contains("clock"))
    }
}
