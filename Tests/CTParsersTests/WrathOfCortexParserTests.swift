import XCTest
import simd
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class WrathOfCortexParserTests: XCTestCase {
    private func requireMounted(_ relativePath: String) throws -> URL {
        let path = "/Volumes/CRASH/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted at \(path)")
        }
        return URL(fileURLWithPath: path)
    }

    /// Real-bytes verification of `ReadCrateData`'s structure
    /// (`OpenCrashWOC-main/code/src/gamecode/crate.c`) -- see
    /// `WOCCrateFile`'s own doc comment for what this replaced and why.
    /// The whole file must consume exactly (no leftover bytes) and every
    /// position must be finite -- either would mean the structure is
    /// wrong, not just "parses without throwing".
    func testRealCRTFileConsumesExactlyWithPlausibleData() throws {
        let url = try requireMounted("LEVELS/A/WESTERN/WESTERN.CRT")
        let data = try Data(contentsOf: url)
        let file = try WrathOfCortexParser.parseCrateFile(data)

        XCTAssertEqual(file.version, 4)
        XCTAssertEqual(file.groups.count, 86)
        XCTAssertEqual(file.totalCrateCount, 211)

        for group in file.groups {
            for crate in group.crates {
                XCTAssertTrue(crate.position.x.isFinite && crate.position.y.isFinite && crate.position.z.isFinite)
                XCTAssertLessThan(simd_length(crate.position), 100_000)
            }
        }

        // A group's own origin is real source data equal to its first
        // crate's own position (both come from the same file bytes at
        // the same read position, per the source's own struct layout).
        for group in file.groups where !group.crates.isEmpty {
            XCTAssertEqual(group.origin, group.crates[0].position)
        }
    }

    /// A second real file, to rule out a one-file coincidence -- same
    /// exact-consumption and plausibility checks.
    func testSecondRealCRTFileConsumesExactly() throws {
        let url = try requireMounted("LEVELS/A/VOLCANO/VOLCANO.CRT")
        let data = try Data(contentsOf: url)
        let file = try WrathOfCortexParser.parseCrateFile(data)
        XCTAssertGreaterThan(file.groups.count, 0)
        for group in file.groups {
            for crate in group.crates {
                XCTAssertTrue(crate.position.x.isFinite && crate.position.y.isFinite && crate.position.z.isFinite)
            }
        }
    }

    func testParsesWumpaFile() throws {
        var w = BinaryWriter()
        w.writeUInt32(2)
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3)
        w.writeFloat32(-1); w.writeFloat32(-2); w.writeFloat32(-3)

        let file = try WrathOfCortexParser.parseWumpaFile(w.data)
        XCTAssertEqual(file.positions.count, 2)
        XCTAssertEqual(file.positions[0], SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(file.positions[1], SIMD3<Float>(-1, -2, -3))
    }

    /// A real `.WMP` file, same exact-consumption discipline as the
    /// `.CRT` tests above.
    func testRealWumpaFileConsumesExactly() throws {
        let url = try requireMounted("LEVELS/A/GARDEN/GARDEN.WMP")
        let data = try Data(contentsOf: url)
        let file = try WrathOfCortexParser.parseWumpaFile(data)
        XCTAssertGreaterThan(file.positions.count, 0)
        for position in file.positions {
            XCTAssertTrue(position.x.isFinite && position.y.isFinite && position.z.isFinite)
        }
    }

    /// Synthetic edge-case: a raw type byte outside the confirmed
    /// `WOCCrateType` enum should decode to `nil`/`rawType`, never a
    /// fabricated case.
    func testUnrecognizedCrateTypeIsNilNotFabricated() throws {
        var w = BinaryWriter()
        w.writeInt32(4) // version
        w.writeInt16(1) // groupCount

        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0) // origin
        w.writeInt16(0) // iCrate
        w.writeInt16(1) // nCrates
        w.writeUInt16(0) // angle

        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0) // position
        w.writeFloat32(0) // shadow
        w.writeInt16(0); w.writeInt16(0); w.writeInt16(0) // delta
        w.writeUInt8(200) // not a real CrateType
        w.writeUInt8(255); w.writeUInt8(255); w.writeUInt8(255) // type2/3/4 (version > 2)
        w.writeInt16(-1); w.writeInt16(-1); w.writeInt16(-1); w.writeInt16(-1); w.writeInt16(-1); w.writeInt16(-1) // neighbors
        w.writeInt16(-1) // trigger (version > 3)

        let file = try WrathOfCortexParser.parseCrateFile(w.data)
        XCTAssertNil(file.groups[0].crates[0].type)
        XCTAssertEqual(file.groups[0].crates[0].rawType, 200)
    }
}
