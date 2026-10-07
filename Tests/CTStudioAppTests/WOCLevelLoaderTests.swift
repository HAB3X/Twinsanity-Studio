import XCTest
@testable import CTParsers
@testable import CTStudioApp

/// `WOCLevelLoader.load` -- a disc-wide survey found 6 of 60 real `.GSC`
/// files carry no RNC compression at all (already a raw `NU20`
/// container), which the loader used to reject outright as
/// `.notRNCCompressed`. These tests confirm both paths actually work
/// against real disc bytes: the common RNC-compressed case, and the
/// raw-container fallback.
final class WOCLevelLoaderTests: XCTestCase {
    private static let discLevelsRoot = "/Volumes/CRASH/LEVELS"

    private func requireMounted(_ relativePath: String) throws -> URL {
        let path = "\(Self.discLevelsRoot)/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted at \(Self.discLevelsRoot)")
        }
        return URL(fileURLWithPath: path)
    }

    func testLoadsRealRNCCompressedLevel() throws {
        let url = try requireMounted("A/AIRSHIP/AIRSHIP.GSC")
        let raw = try Data(contentsOf: url)
        XCTAssertTrue(RNCDecompressor.isRNCStream([UInt8](raw)), "AIRSHIP.GSC should be RNC-compressed")
        let level = try WOCLevelLoader.load(gscURL: url, name: "AIRSHIP")
        XCTAssertFalse(level.sectionTags.isEmpty)
    }

    /// `CORAL.GSC` is a confirmed real, already-raw `NU20` container (no
    /// RNC signature) -- this used to throw `.notRNCCompressed` and make
    /// the level unloadable in the viewer entirely.
    func testLoadsRealUncompressedLevel() throws {
        let url = try requireMounted("A/CORAL_C/CORAL.GSC")
        let raw = try Data(contentsOf: url)
        XCTAssertFalse(RNCDecompressor.isRNCStream([UInt8](raw)), "CORAL.GSC should NOT be RNC-compressed")
        XCTAssertEqual(String(decoding: raw.prefix(4), as: UTF8.self), "NU20", "should already be a raw NU20 container")
        let level = try WOCLevelLoader.load(gscURL: url, name: "CORAL")
        XCTAssertFalse(level.sectionTags.isEmpty)
    }

    /// A second confirmed real raw-container file, in a different level
    /// folder, to rule out a one-file coincidence.
    func testLoadsSecondRealUncompressedLevel() throws {
        let url = try requireMounted("C/SNOW_B/SPACE_B.GSC")
        let raw = try Data(contentsOf: url)
        XCTAssertFalse(RNCDecompressor.isRNCStream([UInt8](raw)))
        let level = try WOCLevelLoader.load(gscURL: url, name: "SPACE_B")
        XCTAssertFalse(level.sectionTags.isEmpty)
    }

    /// End-to-end: `WEATH_B.GSC` has a real `TAS0` section and a sibling
    /// `.PTL` file that fits the confirmed simple 839-byte record format
    /// -- confirms both get wired all the way through
    /// `WOCLevelLoader.load` into the final `WOCLevelAsset`, not just
    /// exercised at the parser level in `CTParsersTests`.
    func testLoadsTextureAssignmentsAndParticleEffects() throws {
        let url = try requireMounted("C/WEATH_B/WEATH_B.GSC")
        let level = try WOCLevelLoader.load(gscURL: url, name: "WEATH_B")
        let assignments = try XCTUnwrap(level.textureAssignments, "WEATH_B.GSC has a confirmed real TAS0 section")
        XCTAssertFalse(assignments.textureIndices.isEmpty)
        for index in assignments.textureIndices {
            XCTAssertLessThan(Int(index), level.textures.count)
        }
        XCTAssertFalse(level.particleEffects.isEmpty, "WEATH_B.PTL is a confirmed real simple-format particle file")
        XCTAssertFalse(level.particleFileExistsButUnparsed)
    }

    /// End-to-end: `AVALANCH.GSC` has sibling `.PTL` and `.CPT` files.
    func testLoadsCheckpointEffects() throws {
        let url = try requireMounted("A/AVALANCH/AVALANCH.GSC")
        let level = try WOCLevelLoader.load(gscURL: url, name: "AVALANCH")
        XCTAssertFalse(level.particleEffects.isEmpty)
        XCTAssertFalse(level.checkpointEffects.isEmpty)
        XCTAssertFalse(level.checkpointFileExistsButUnparsed)
    }

    /// End-to-end: `WATER.GSC` (in `WATER_R/`) has a sibling `.OBJ` file
    /// of all-simple object types.
    func testLoadsInteractiveObjects() throws {
        let url = try requireMounted("A/WATER_R/WATER.GSC")
        let level = try WOCLevelLoader.load(gscURL: url, name: "WATER")
        XCTAssertFalse(level.interactiveObjects.isEmpty)
        XCTAssertGreaterThan(level.interactiveObjectDeclaredCount, 0)
    }
}
