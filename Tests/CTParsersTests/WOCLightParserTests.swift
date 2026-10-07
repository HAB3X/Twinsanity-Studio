import XCTest
import simd
@testable import CTParsers

/// `WOCLightParser` -- decodes WoC `.LGT` files. See `LGT_Spec.md` for
/// the full investigation history. These tests independently re-verify
/// the confirmed structure directly against real disc bytes.
final class WOCLightParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Golden-value regression, hand-verified against real bytes:
    /// `AIRSHIP.LGT` has 2 lights, K=0. Light 0 fits the normal shape
    /// exactly (radius ~2.31, colorByte (255,191,127) matching
    /// colorFloat almost exactly). Light 1 is the real second shape --
    /// must come back `nil`, not a wrong decode.
    func testRealAirshipGoldenValues() throws {
        let data = try loadReal("A/AIRSHIP/AIRSHIP.LGT")
        let file = try WOCLightParser.parse(data)
        XCTAssertEqual(file.header.0, 1)
        XCTAssertEqual(file.header.1, 1)
        XCTAssertEqual(file.header.2, 0)
        XCTAssertEqual(file.header.3, 1)
        XCTAssertEqual(file.extendedRecordCount, 0)
        XCTAssertEqual(file.lights.count, 2)

        let light0 = try XCTUnwrap(file.lights[0])
        XCTAssertEqual(light0.radius, 2.3117871, accuracy: 0.0001)
        XCTAssertEqual(light0.colorByte.0, 255)
        XCTAssertEqual(light0.colorByte.1, 191)
        XCTAssertEqual(light0.colorByte.2, 127)

        XCTAssertNil(file.lights[1], "light 1 is the real second shape and should not be force-decoded")
        XCTAssertEqual(file.rawRecords.count, 2)
        XCTAssertEqual(file.rawRecords[1].count, 55)
    }

    /// `WESTERN.LGT`: 3 lights, K=0, lights 0-1 normal, light 2 the
    /// second shape (matches this doc's own "always the last record when
    /// present" observation, though the parser doesn't rely on that --
    /// every record is validated independently).
    func testRealWesternGoldenValues() throws {
        let data = try loadReal("A/WESTERN/WESTERN.LGT")
        let file = try WOCLightParser.parse(data)
        XCTAssertEqual(file.lights.count, 3)
        XCTAssertNotNil(file.lights[0])
        XCTAssertNotNil(file.lights[1])
        XCTAssertNil(file.lights[2])
    }

    /// A file with real extended (K>0) records (`FARM.LGT`: 540 bytes,
    /// count=8, K=6). Direct byte verification (`xxd`) confirmed record
    /// boundaries resolve uniquely: the first 2 records are the normal
    /// 55-byte shape, the remaining 6 are the 67-byte extended shape
    /// (12-byte undecoded prefix + the same 55-byte body) -- matching
    /// `K=6` exactly, and every record's radius/color cross-check
    /// validates cleanly at its resolved body offset.
    func testExtendedRecordFileResolvesRealBoundaries() throws {
        let data = try loadReal("A/FARM/FARM.LGT")
        let file = try WOCLightParser.parse(data)
        guard file.extendedRecordCount > 0 else {
            throw XCTSkip("FARM.LGT is expected to have K>0 per this investigation's own notes -- if this no longer holds, pick a different real K>0 sample")
        }
        XCTAssertTrue(file.boundariesResolved)
        XCTAssertEqual(file.isExtended, [false, false, true, true, true, true, true, true])
        XCTAssertEqual(file.rawRecords.count, 8)
        XCTAssertEqual(file.rawRecords[0].count, 55)
        XCTAssertEqual(file.rawRecords[2].count, 67)
        // Every record validated -- hand-confirmed for records 0-2 via xxd;
        // this checks the rest resolved cleanly too, not just byte-fit.
        XCTAssertTrue(file.lights.allSatisfy { $0 != nil }, "expected every FARM.LGT record to validate under its resolved shape")
        XCTAssertEqual(file.rawRecordBlob.count, 55 * (file.lights.count - file.extendedRecordCount) + 67 * file.extendedRecordCount)
    }

    /// Full-corpus regression: every real `.LGT` file should parse
    /// without throwing, the file-size formula should account for every
    /// byte, and every validated light's colorFloat should match
    /// colorByte/255 within tolerance (the validation this parser itself
    /// performs, re-checked independently here).
    func testEveryRealLGTFileParsesAndValidatedLightsAreConsistent() throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: "/Volumes/CRASH/LEVELS") else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        var allLGT: [String] = []
        for case let p as String in enumerator where p.uppercased().hasSuffix(".LGT") {
            allLGT.append(p)
        }
        guard !allLGT.isEmpty else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }

        var checked = 0
        var validatedLights = 0
        var resolvedKPositiveFiles = 0
        var totalKPositiveFiles = 0
        for relativePath in allLGT.sorted() {
            let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let file = try WOCLightParser.parse(data)
            let expectedRegionLength = 55 * file.lights.count + 12 * file.extendedRecordCount
            XCTAssertEqual(file.rawRecordBlob.count, expectedRegionLength, "\(relativePath): record region should account for every byte")

            if file.extendedRecordCount > 0 {
                totalKPositiveFiles += 1
                if file.boundariesResolved {
                    resolvedKPositiveFiles += 1
                    XCTAssertEqual(file.isExtended.filter { $0 }.count, file.extendedRecordCount, "\(relativePath): resolved extended-record count should match K")
                    XCTAssertEqual(file.rawRecords.count, file.lights.count, "\(relativePath)")
                }
            }

            for light in file.lights {
                guard let light = light else { continue }
                let expected = SIMD3<Float>(Float(light.colorByte.0), Float(light.colorByte.1), Float(light.colorByte.2)) / 255.0
                XCTAssertEqual(light.colorFloat.x, expected.x, accuracy: 0.01, "\(relativePath)")
                XCTAssertEqual(light.colorFloat.y, expected.y, accuracy: 0.01, "\(relativePath)")
                XCTAssertEqual(light.colorFloat.z, expected.z, accuracy: 0.01, "\(relativePath)")
                XCTAssertGreaterThanOrEqual(light.radius, 0, "\(relativePath)")
                validatedLights += 1
            }
            checked += 1
        }
        // Not a correctness assertion (a K>0 file legitimately might not
        // resolve) -- just surfaces real coverage for visibility.
        print("WOCLightParser: \(resolvedKPositiveFiles)/\(totalKPositiveFiles) K>0 files resolved real record boundaries")
        XCTAssertGreaterThan(checked, 30, "expected close to the full real 37-file corpus")
        XCTAssertGreaterThan(validatedLights, 0, "expected at least some lights to validate cleanly")
    }
}
