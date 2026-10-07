import XCTest
import Foundation
@testable import CTParsers

final class WOCAnimationParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Confirmed by exact byte consumption -- the parser throws rather
    /// than returning partial/garbage data if it doesn't land exactly on
    /// EOF, so a successful parse here is itself the verification.
    func testRealSimpleAnimationFiles() throws {
        let data = try loadReal("A/AVALANCH/AVALANCH.ANM")
        let entries = try WOCAnimationParser.parse(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "avalanche")
        XCTAssertEqual(entries[0].subEntries.map(\.name), ["AVA_MID", "AVA_SML", "AVA_LRG", "AVA_LRG"])
    }

    func testRealCastleAnimationFile() throws {
        let data = try loadReal("A/CASTLE/CASTLE.ANM")
        let entries = try WOCAnimationParser.parse(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "ball_04")
        XCTAssertEqual(entries[0].subEntries.map(\.name), ["BALL"])
    }

    /// `TOONARMY.ANM` was originally believed to be a real skeletal
    /// animation file needing a materially different decoder -- a
    /// disc-wide sweep found it actually fits the same template plus one
    /// optional trailing `Vector3` per entry (gated by `formatFlag == 4`).
    /// Its "joint-like" names (`pcube2318`, etc.) read as Maya
    /// object/debris names -- this file lives in the `TSUNAMI` level
    /// directory -- not skeleton joints; every entry here has zero
    /// sub-effects and just a spawn/pivot position.
    func testRealTsunamiDebrisFileParsesWithTrailer() throws {
        let data = try loadReal("A/TSUNAMI/TOONARMY.ANM")
        let entries = try WOCAnimationParser.parse(data)
        XCTAssertEqual(entries.count, 20)
        XCTAssertEqual(entries[0].name, "pcube2318")
        XCTAssertEqual(entries[0].subEntries.count, 0)
        XCTAssertNotNil(entries[0].trailer, "formatFlag==4 files should carry a trailing Vector3 per entry")
    }

    /// `DROID.ANM` also carries the `formatFlag == 4` trailer -- unlike
    /// `TOONARMY.ANM` its entries DO have real sub-effects, confirming
    /// the trailer is independent of `subCount`.
    func testRealDroidAnimationFileParsesWithTrailerAndSubEffects() throws {
        let data = try loadReal("A/DROID/DROID.ANM")
        let entries = try WOCAnimationParser.parse(data)
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            XCTAssertNotNil(entry.trailer)
            XCTAssertEqual(entry.subEntries.count, 6)
        }
    }

    /// Every real `.ANM` file that exists anywhere on the disc (10 total)
    /// must decode with exact byte consumption -- the same bar this
    /// codebase already holds `.AI`/`.GRA` to.
    func testAllRealAnimationFilesConsumeExactlyTheirWholeFile() throws {
        let samples = [
            "A/AVALANCH/AVALANCH.ANM",
            "A/CASTLE/CASTLE.ANM",
            "A/CASTLE_A/CASTLE_A.ANM",
            "A/CASTLE_C/CASTLE_C.ANM",
            "A/DROID/DROID.ANM",
            "A/FIREBALL/BALLSOF.ANM",
            "A/SPACE_R/SPACE_R.ANM",
            "A/TSUNAMI/TOONARMY.ANM",
            "A/JUNGLE_A/JUNGLE_A.ANM",
            "B/HUB/HUB.ANM",
        ]
        var checked = 0
        for relativePath in samples {
            let data = try loadReal(relativePath)
            // parse() itself throws .didNotConsumeWholeFile on any drift,
            // so a successful parse is the verification.
            _ = try WOCAnimationParser.parse(data)
            checked += 1
        }
        XCTAssertEqual(checked, samples.count, "expected all 10 real .ANM files to be available and parse cleanly")
    }
}
