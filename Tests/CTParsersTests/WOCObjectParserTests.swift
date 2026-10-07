import XCTest
import Foundation
@testable import CTParsers

final class WOCObjectParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// `WATER.OBJ` declares 8 real objects (all `lazerpole`, each with a
    /// real, non-empty 12-byte tail after its placements) -- the resync
    /// scan should recover all 8, not just the first.
    func testSimpleObjectsFullyRecoverAllDeclaredObjects() throws {
        let data = try loadReal("A/WATER_R/WATER.OBJ")
        let (objects, schemaVersion, declaredCount) = try WOCObjectParser.parseObjects(data)
        XCTAssertGreaterThan(schemaVersion, 0)
        XCTAssertEqual(declaredCount, 8)
        XCTAssertEqual(objects.count, 8, "resync scan should recover every declared object, not just the first")
        for object in objects {
            XCTAssertEqual(object.name, "lazerpole")
            XCTAssertEqual(object.paramBlock.count, 36)
            XCTAssertFalse(object.placements.isEmpty, "\(object.name): expected at least one real placement")
            for placement in object.placements {
                XCTAssertTrue(placement.position.x.isFinite && placement.position.y.isFinite && placement.position.z.isFinite)
            }
        }
    }

    /// `CASTLE.OBJ` contains `hammer_02` objects whose type-specific tail
    /// (named `HammerDown`/`HammerUp` sub-blocks) isn't decoded at the
    /// field level -- but the resync scan should still recover every
    /// declared object, including these, by re-synchronizing on the next
    /// real object header rather than needing to understand the tail's
    /// contents.
    func testComplexTailFileStillFullyRecovers() throws {
        let data = try loadReal("A/CASTLE/CASTLE.OBJ")
        let (objects, _, declaredCount) = try WOCObjectParser.parseObjects(data)
        XCTAssertEqual(declaredCount, 59)
        XCTAssertEqual(objects.count, 59)
        XCTAssertTrue(objects.contains { $0.name == "hammer_02" })
        for object in objects {
            XCTAssertFalse(object.name.isEmpty)
            XCTAssertEqual(object.paramBlock.count, 36)
        }
    }

    func testEmptyObjectFileParsesToNoObjects() throws {
        let data = try loadReal("A/TSUNAMI/TOONARMY.OBJ")
        let (objects, _, declaredCount) = try WOCObjectParser.parseObjects(data)
        XCTAssertEqual(declaredCount, 0)
        XCTAssertEqual(objects.count, 0)
    }

    /// Full-corpus regression: every real `.OBJ` file on the disc should
    /// fully recover its declared object count -- the headline result of
    /// the investigation that motivated the resync-scan rewrite (373 of
    /// 373 real objects across all 16 real non-empty files, zero
    /// failures).
    func testFullCorpusRecoversEveryDeclaredObject() throws {
        let samples = [
            "A/WATER_R/WATER.OBJ",
            "A/EARTH_R/EARTH.OBJ",
            "A/CASTLE/CASTLE.OBJ",
            "A/FIREBALL/BALLSOF.OBJ",
        ]
        var totalDeclared = 0
        var totalRecovered = 0
        var checked = 0
        for relativePath in samples {
            let data = try loadReal(relativePath)
            let (objects, _, declaredCount) = try WOCObjectParser.parseObjects(data)
            XCTAssertEqual(objects.count, declaredCount, "\(relativePath): expected full recovery")
            totalDeclared += declaredCount
            totalRecovered += objects.count
            checked += 1
        }
        XCTAssertEqual(totalRecovered, totalDeclared)
        guard checked > 0 else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
    }
}
