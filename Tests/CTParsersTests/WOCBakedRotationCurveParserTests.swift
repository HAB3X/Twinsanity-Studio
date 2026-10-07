import XCTest
@testable import CTParsers

/// `WOCBakedRotationCurveParser` -- decodes WEST_A's `.AI0`-`.AI3` files.
/// These tests independently re-verify the confirmed structure directly
/// against real disc bytes: fixed 28-byte records, a real unit
/// quaternion in every one.
final class WOCBakedRotationCurveParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Golden-value regression: exact record count and the confirmed
    /// held-rest-pose header shape on the first record.
    func testRealAI0GoldenValues() throws {
        let data = try loadReal("A/WEST_A/WEST_A.AI0")
        let samples = try WOCBakedRotationCurveParser.parse(data)
        XCTAssertEqual(samples.count, 4510)

        let first = samples[0]
        XCTAssertEqual(first.rotation.x, 0, accuracy: 0.001)
        XCTAssertEqual(first.rotation.y, 1, accuracy: 0.001)
        XCTAssertEqual(first.rotation.z, 0, accuracy: 0.001)
        XCTAssertEqual(first.auxShort1, -115)
        XCTAssertEqual(first.auxValue, 35136)
    }

    /// Every real sample across all 4 real files should be a valid unit
    /// quaternion -- the confirmed claim, re-verified independently
    /// rather than trusting the investigation's report.
    func testEveryRealSampleIsAUnitQuaternion() throws {
        let samples = [
            "A/WEST_A/WEST_A.AI0",
            "A/WEST_A/WEST_A.AI1",
            "A/WEST_A/WEST_A.AI2",
            "A/WEST_A/WEST_A.AI3",
        ]
        var totalChecked = 0
        for relativePath in samples {
            let data = try loadReal(relativePath)
            let records = try WOCBakedRotationCurveParser.parse(data)
            XCTAssertFalse(records.isEmpty)
            for record in records {
                let normSquared = (record.rotation * record.rotation).sum()
                XCTAssertEqual(normSquared, 1.0, accuracy: 0.001, "\(relativePath): every real record should be a valid unit quaternion")
            }
            totalChecked += records.count
        }
        XCTAssertEqual(totalChecked, 4510 + 4864 + 4966 + 5450)
    }

    func testTruncatedDataThrows() {
        XCTAssertThrowsError(try WOCBakedRotationCurveParser.parse(Data([0, 1, 2])))
    }
}
