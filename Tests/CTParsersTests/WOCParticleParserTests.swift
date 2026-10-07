import XCTest
import Foundation
@testable import CTParsers

/// `WOCParticleParser` -- decodes the confirmed "simple" fixed-839-byte
/// record shape shared by `.PTL` (particle effects) and `.CPT`
/// (checkpoint-touch effects). These tests independently re-verify the
/// confirmed field values directly against real disc bytes.
final class WOCParticleParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func testRealPTLFileHasFourByteZeroTrailer() throws {
        let data = try loadReal("A/AVALANCH/AVALANCH.PTL")
        let (records, trailer) = try WOCParticleParser.parse(data)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(trailer.count, 4)
        XCTAssertTrue(trailer.allSatisfy { $0 == 0 })
    }

    /// `.CPT` shares the exact record format but has NO trailer -- a
    /// correction to an earlier investigation that assumed byte-identical
    /// framing between the two extensions.
    func testRealCPTFileHasNoTrailer() throws {
        let data = try loadReal("A/AVALANCH/AVALANCH.CPT")
        let (records, trailer) = try WOCParticleParser.parse(data)
        XCTAssertFalse(records.isEmpty)
        XCTAssertEqual(trailer.count, 0)
    }

    /// Every decoded field across every real "simple" record on disk
    /// should land in the sane ranges the original investigation found --
    /// this is the same "confirmed by real-data plausibility across many
    /// files" bar the rest of this codebase's WoC decoders hold to.
    func testDecodedFieldsAreSaneAcrossRealFiles() throws {
        let samples = [
            "A/AVALANCH/AVALANCH.PTL",
            "C/WATER_B/WATER_B.PTL",
            "C/WEATH_B/WEATH_B.PTL",
            "A/AVALANCH/AVALANCH.CPT",
        ]
        var checked = 0
        for relativePath in samples {
            let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let (records, _) = try WOCParticleParser.parse(data)
            for record in records {
                XCTAssertFalse(record.name.isEmpty, "\(relativePath): every real record should have a non-empty name")
                XCTAssertGreaterThan(record.lifetimeSeconds, 0, "\(relativePath)/\(record.name): lifetime should be positive")
                XCTAssertLessThan(record.lifetimeSeconds, 10, "\(relativePath)/\(record.name): lifetime should be a plausible seconds value")
                XCTAssertGreaterThan(record.maxSizeWidth, 0, "\(relativePath)/\(record.name): size should be positive")
                XCTAssertGreaterThan(record.maxSizeHeight, 0, "\(relativePath)/\(record.name): size should be positive")
                XCTAssertEqual(record.raw.count, 839)
            }
            checked += 1
        }
        guard checked > 0 else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
    }

    /// The confirmed-unsupported "complex" variable-length format
    /// (`CASTLE.PTL`) must be rejected rather than silently misdecoded.
    func testComplexVariableLengthFileIsRejectedRatherThanMisdecoded() throws {
        let data = try loadReal("A/CASTLE/CASTLE.PTL")
        XCTAssertThrowsError(try WOCParticleParser.parse(data))
    }
}
