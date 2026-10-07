import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers

final class EngineDriverTests: XCTestCase {
    func testRegistryHasBothRealDrivers() {
        XCTAssertEqual(EngineDriverRegistry.all.count, 2)
        XCTAssertTrue(EngineDriverRegistry.all.contains { $0.id == "twinsanity" })
        XCTAssertTrue(EngineDriverRegistry.all.contains { $0.id == "wrath-of-cortex" })
    }

    func testTwinsanityExtensionsResolveToTwinsanityDriver() {
        for ext in ["RM2", "SM2", "RMX", "SMX", "rm2"] {
            XCTAssertEqual(EngineDriverRegistry.driver(forExtension: ext)?.id, "twinsanity", "\(ext) should resolve to the Twinsanity driver")
        }
    }

    func testWrathOfCortexExtensionsResolveToWrathOfCortexDriver() {
        for ext in ["CRT", "WMP", "crt", "wmp"] {
            XCTAssertEqual(EngineDriverRegistry.driver(forExtension: ext)?.id, "wrath-of-cortex", "\(ext) should resolve to the Wrath of Cortex driver")
        }
    }

    func testUnrecognizedExtensionResolvesToNoDriver() {
        XCTAssertNil(EngineDriverRegistry.driver(forExtension: "TXT"))
    }

    func testWrathOfCortexDriverIsHonestlyScopedToPS2() {
        let driver = WrathOfCortexEngineDriver()
        XCTAssertEqual(driver.supportedPlatforms, [.ps2], "the GameCube variant isn't ported, this must not silently claim otherwise")
    }

    /// "Pluggable Engine Driver System" (roadmap 5.3): `WorkspaceViewModel.
    /// open(url:)` dispatches on this instead of hardcoding a specific
    /// driver ID, this pins the real, currently-declared capability of
    /// each driver so that dispatch logic has something concrete to test
    /// against, and so a future third driver can't silently regress
    /// Twinsanity's own main-tree ingestion just by being added to the
    /// registry.
    func testTwinsanityDriverIngestsIntoMainWorkspaceTree() {
        guard case .mainWorkspaceTree = TwinsanityEngineDriver().ingestionCapability else {
            return XCTFail("Twinsanity's own files must ingest into the main workspace tree")
        }
    }

    func testWrathOfCortexDriverIsStandaloneOnlyWithARealLoadHint() {
        guard case .standaloneOnly(let loadHint) = WrathOfCortexEngineDriver().ingestionCapability else {
            return XCTFail("Wrath of Cortex files aren't chunk-headered, they have no main-tree shape to ingest into")
        }
        XCTAssertFalse(loadHint.isEmpty)
    }

    /// "Modular Driver Dispatch" (roadmap 5.3): `TwinsanityEngineDriver.
    /// parseChunkFile` must be a real, transparent passthrough to
    /// `RM2Parser.parse`, same input, same real result (including on
    /// genuinely malformed input, where both must fail identically),
    /// never a second, subtly-different parsing path.
    func testTwinsanityDriverParseChunkFileMatchesRM2ParserDirectly() throws {
        let malformedData = Data([0x01, 0x02, 0x03]) // too short to even read a real magic/header

        let driver = TwinsanityEngineDriver()
        var directError: Error?
        var driverError: Error?
        do { _ = try RM2Parser.parse(data: malformedData, fileKind: .rm2, fileName: "test.rm2") } catch { directError = error }
        do { _ = try driver.parseChunkFile(data: malformedData, fileKind: .rm2, fileName: "test.rm2") } catch { driverError = error }

        XCTAssertNotNil(directError, "malformed data should fail to parse directly")
        XCTAssertNotNil(driverError, "malformed data should fail through the driver too")
        XCTAssertEqual(String(describing: directError), String(describing: driverError), "the driver must fail exactly the same way RM2Parser itself does, a real passthrough, not a second parsing path")
    }

    /// The Wrath of Cortex driver has no `ChunkNode`-based ingestion , 
    /// calling these must fail loudly (`EngineDriverError.
    /// unsupportedOperation`), not silently return something empty that
    /// would look like "this file has no content."
    func testWrathOfCortexDriverThrowsForUnsupportedMainTreeOperations() {
        let driver = WrathOfCortexEngineDriver()
        XCTAssertThrowsError(try driver.parseChunkFile(data: Data(), fileKind: .rm2, fileName: "x.rm2")) { error in
            XCTAssertEqual(error as? EngineDriverError, .unsupportedOperation(driverID: "wrath-of-cortex"))
        }
        XCTAssertThrowsError(try driver.parseArchiveIndex(bhURL: URL(fileURLWithPath: "/tmp/x.bh"))) { error in
            XCTAssertEqual(error as? EngineDriverError, .unsupportedOperation(driverID: "wrath-of-cortex"))
        }
    }
}
