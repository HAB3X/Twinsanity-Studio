import XCTest
import CTModels
@testable import CTExport

final class CrateArchiveManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Round-trip through the real CrateExporter (single layer0)

    func testReadManifestRoundTripsExportedMetadata() throws {
        let crateURL = tempDir.appendingPathComponent("mod.crate")
        let metadata = CrateMetadata(name: "Test Mod", description: "A test mod", author: "HAB3X", version: "2.1", targetGame: "Crash Twinsanity")
        try CrateExporter.export(files: [(relativePath: "level.rm2", data: Data([1, 2, 3]))], metadata: metadata, to: crateURL)

        let manifest = try CrateArchiveManager.readManifest(from: crateURL)
        XCTAssertEqual(manifest.name, "Test Mod")
        XCTAssertEqual(manifest.description, "A test mod")
        XCTAssertEqual(manifest.author, "HAB3X")
        XCTAssertEqual(manifest.version, "2.1")
        XCTAssertEqual(manifest.targetGame, "Crash Twinsanity")
        XCTAssertEqual(manifest.layerIndices, [0])
        XCTAssertFalse(manifest.hasIcon)
        XCTAssertTrue(manifest.settings.isEmpty)
    }

    func testListEntriesIncludesManifestAndLayerFiles() throws {
        let crateURL = tempDir.appendingPathComponent("mod.crate")
        let metadata = CrateMetadata(name: "Bundle", description: "", author: "", version: "1.0", targetGame: "Crash Twinsanity")
        let files: [(relativePath: String, data: Data)] = [
            (relativePath: "Wumpa/Wumpa.obj", data: Data("obj".utf8)),
            (relativePath: "Wumpa/texture_1.png", data: Data([0x89, 0x50]))
        ]
        try CrateExporter.export(files: files, metadata: metadata, to: crateURL)

        let entries = try CrateArchiveManager.listEntries(in: crateURL)
        XCTAssertTrue(entries.contains("modcrateinfo.txt"))
        XCTAssertTrue(entries.contains("layer0/Wumpa/Wumpa.obj"))
        XCTAssertTrue(entries.contains("layer0/Wumpa/texture_1.png"))

        let layerFiles = CrateArchiveManager.filesInLayer(0, entries: entries)
        XCTAssertEqual(layerFiles, ["Wumpa/Wumpa.obj", "Wumpa/texture_1.png"])
    }

    func testExtractLayerWritesFilesAtCorrectRelativePaths() throws {
        let crateURL = tempDir.appendingPathComponent("mod.crate")
        let metadata = CrateMetadata(name: "Bundle", description: "", author: "", version: "1.0", targetGame: "Crash Twinsanity")
        let files: [(relativePath: String, data: Data)] = [
            (relativePath: "Wumpa/Wumpa.obj", data: Data("obj-contents".utf8)),
            (relativePath: "Wumpa/animations/animation_2.json", data: Data("{}".utf8))
        ]
        try CrateExporter.export(files: files, metadata: metadata, to: crateURL)

        let destination = tempDir.appendingPathComponent("extracted")
        try CrateArchiveManager.extractLayer(0, from: crateURL, to: destination)

        let obj = try Data(contentsOf: destination.appendingPathComponent("Wumpa/Wumpa.obj"))
        XCTAssertEqual(obj, Data("obj-contents".utf8))
        let anim = try Data(contentsOf: destination.appendingPathComponent("Wumpa/animations/animation_2.json"))
        XCTAssertEqual(anim, Data("{}".utf8))
        // The layer0/ prefix itself must not appear in the extracted tree.
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("layer0").path))
    }

    func testReadManifestThrowsForZipWithNoManifest() throws {
        let plainZipSource = tempDir.appendingPathComponent("not-a-crate-src")
        try FileManager.default.createDirectory(at: plainZipSource, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: plainZipSource.appendingPathComponent("readme.txt"))
        let zipURL = tempDir.appendingPathComponent("not-a-crate.crate")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = plainZipSource
        process.arguments = ["-r", "-X", "-q", zipURL.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        XCTAssertThrowsError(try CrateArchiveManager.readManifest(from: zipURL)) { error in
            XCTAssertEqual(error as? CrateArchiveError, .manifestMissing)
        }
    }

    // MARK: - Multi-layer archive, built directly (CrateExporter only ever writes layer0)

    func testMultiLayerCrateReportsSparseLayerIndicesAndSettings() throws {
        let stageDir = tempDir.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stageDir.appendingPathComponent("layer0"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stageDir.appendingPathComponent("layer2"), withIntermediateDirectories: true)
        try "!comment\nName=Sparse Mod\nAuthor=Someone\nVersion=1.0\nGame=Crash Twinsanity\nModLoaderVersion=1.0\n"
            .write(to: stageDir.appendingPathComponent("modcrateinfo.txt"), atomically: true, encoding: .utf8)
        try "!comment\nFogDensity=0.5\n"
            .write(to: stageDir.appendingPathComponent("modcratesettings.txt"), atomically: true, encoding: .utf8)
        try Data("layer0 file".utf8).write(to: stageDir.appendingPathComponent("layer0/a.txt"))
        try Data("layer2 file".utf8).write(to: stageDir.appendingPathComponent("layer2/b.txt"))

        let crateURL = tempDir.appendingPathComponent("sparse.crate")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = stageDir
        process.arguments = ["-r", "-X", "-q", crateURL.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let manifest = try CrateArchiveManager.readManifest(from: crateURL)
        XCTAssertEqual(manifest.name, "Sparse Mod")
        XCTAssertEqual(manifest.layerIndices, [0, 2])
        XCTAssertEqual(manifest.settings["FogDensity"], "0.5")

        let entries = try CrateArchiveManager.listEntries(in: crateURL)
        XCTAssertEqual(CrateArchiveManager.filesInLayer(1, entries: entries), [])
        XCTAssertEqual(CrateArchiveManager.filesInLayer(2, entries: entries), ["b.txt"])
    }

    // MARK: - Nested crates (modcrateinfo.txt not at the zip root)

    func testNestedCrateOffsetsManifestLayerAndExtractLookups() throws {
        let stageDir = tempDir.appendingPathComponent("stage")
        let wrapperDir = stageDir.appendingPathComponent("MyMod")
        try FileManager.default.createDirectory(at: wrapperDir.appendingPathComponent("layer0/Wumpa"), withIntermediateDirectories: true)
        try "!comment\nName=Nested Mod\nVersion=1.0\n"
            .write(to: wrapperDir.appendingPathComponent("modcrateinfo.txt"), atomically: true, encoding: .utf8)
        try Data("nested contents".utf8).write(to: wrapperDir.appendingPathComponent("layer0/Wumpa/fruit.txt"))

        let crateURL = tempDir.appendingPathComponent("nested.crate")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = stageDir
        process.arguments = ["-r", "-X", "-q", crateURL.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let manifest = try CrateArchiveManager.readManifest(from: crateURL)
        XCTAssertEqual(manifest.name, "Nested Mod")
        XCTAssertEqual(manifest.nestedPath, "MyMod/")
        XCTAssertEqual(manifest.layerIndices, [0])

        let entries = try CrateArchiveManager.listEntries(in: crateURL)
        XCTAssertEqual(CrateArchiveManager.filesInLayer(0, entries: entries, nestedPath: manifest.nestedPath), ["Wumpa/fruit.txt"])

        let destination = tempDir.appendingPathComponent("nested-extracted")
        try CrateArchiveManager.extractLayer(0, from: crateURL, to: destination, nestedPath: manifest.nestedPath)
        let contents = try Data(contentsOf: destination.appendingPathComponent("Wumpa/fruit.txt"))
        XCTAssertEqual(contents, Data("nested contents".utf8))
    }

    // MARK: - Region gating

    func testDeclaredRegionParsesFromSettingsKey() {
        let withRegion = ModManifest(name: "x", description: "", author: "", version: "1.0", targetGame: "", modLoaderVersion: "", layerIndices: [], settings: ["GameRegion": "PAL"], hasIcon: false)
        XCTAssertEqual(withRegion.declaredRegion, .pal)

        let withoutRegion = ModManifest(name: "x", description: "", author: "", version: "1.0", targetGame: "", modLoaderVersion: "", layerIndices: [], settings: [:], hasIcon: false)
        XCTAssertNil(withoutRegion.declaredRegion)

        let unrecognized = ModManifest(name: "x", description: "", author: "", version: "1.0", targetGame: "", modLoaderVersion: "", layerIndices: [], settings: ["GameRegion": "Mars"], hasIcon: false)
        XCTAssertNil(unrecognized.declaredRegion)
    }

    /// "Crate Region Gating" (install-time enforcement, `VerifyModCrates` , 
    /// see `CrateArchiveError.regionMismatch`'s own doc comment): a crate
    /// declaring one region must be refused against a disc detected as a
    /// different region, not silently allowed through to `extractLayer`/
    /// `extractAll` where a mismatched executable byte offset would corrupt
    /// the result.
    func testVerifyRegionCompatibilityThrowsOnMismatch() {
        let palCrate = ModManifest(name: "x", description: "", author: "", version: "1.0", targetGame: "", modLoaderVersion: "", layerIndices: [], settings: ["GameRegion": "PAL"], hasIcon: false)
        XCTAssertThrowsError(try CrateArchiveManager.verifyRegionCompatibility(manifest: palCrate, detectedRegion: .ntscU)) { error in
            guard case CrateArchiveError.regionMismatch(let declared, let detected) = error else {
                return XCTFail("Expected .regionMismatch, got \(error)")
            }
            XCTAssertEqual(declared, .pal)
            XCTAssertEqual(detected, .ntscU)
        }
    }

    /// The matching-region counterpart, must pass through cleanly, not
    /// throw, when the crate's declared region and the detected disc
    /// region agree.
    func testVerifyRegionCompatibilityPassesOnMatch() throws {
        let palCrate = ModManifest(name: "x", description: "", author: "", version: "1.0", targetGame: "", modLoaderVersion: "", layerIndices: [], settings: ["GameRegion": "PAL"], hasIcon: false)
        XCTAssertNoThrow(try CrateArchiveManager.verifyRegionCompatibility(manifest: palCrate, detectedRegion: .pal))
    }

    /// "Nothing to compare" must stay permissive on either side, a crate
    /// that declares no region (the common case) or a workspace that
    /// hasn't detected a disc region yet (`nil`) or detected an
    /// unrecognized one (`.unknown`) is never treated as a mismatch.
    func testVerifyRegionCompatibilityPassesWhenNothingToCompare() throws {
        let undeclaredCrate = ModManifest(name: "x", description: "", author: "", version: "1.0", targetGame: "", modLoaderVersion: "", layerIndices: [], settings: [:], hasIcon: false)
        XCTAssertNoThrow(try CrateArchiveManager.verifyRegionCompatibility(manifest: undeclaredCrate, detectedRegion: .pal))
        XCTAssertNoThrow(try CrateArchiveManager.verifyRegionCompatibility(manifest: undeclaredCrate, detectedRegion: nil))

        let palCrate = ModManifest(name: "x", description: "", author: "", version: "1.0", targetGame: "", modLoaderVersion: "", layerIndices: [], settings: ["GameRegion": "PAL"], hasIcon: false)
        XCTAssertNoThrow(try CrateArchiveManager.verifyRegionCompatibility(manifest: palCrate, detectedRegion: nil))
        XCTAssertNoThrow(try CrateArchiveManager.verifyRegionCompatibility(manifest: palCrate, detectedRegion: .unknown))
    }

    // MARK: - modcratesettings.txt (`ModCrateSettings`)

    /// Format verified against `CrateModLoader-master/CrateModAPI/
    /// ModCrates.cs`'s `Separator`/`CommentSymbol` constants and
    /// `SaveSettingsToFile`'s leading-comment-then-key=value-lines shape:
    /// one `!`-prefixed comment line, then one `Key=Value` line per entry.
    func testModCrateSettingsSerializeMatchesRealKeyValueFormat() {
        let text = ModCrateSettings.serialize(["FogDensity": "0.5", "GameRegion": "PAL"])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("!"))
        // Sorted key order for a stable, diff-friendly file.
        XCTAssertEqual(lines[1], "FogDensity=0.5")
        XCTAssertEqual(lines[2], "GameRegion=PAL")
        XCTAssertEqual(lines.last, "") // trailing newline
    }

    /// Empty settings still produce a valid (comment-only) file rather than
    /// an empty string, `CrateExporter.export` is what actually decides
    /// whether to write the file at all for the empty case (see
    /// `testCrateExporterOmitsSettingsFileWhenNoSettingsGiven`).
    func testModCrateSettingsSerializeEmptyIsJustTheComment() {
        let text = ModCrateSettings.serialize([:])
        XCTAssertEqual(text, "!Generated by Twinsanity Studio\n")
    }

    /// `ModCrateSettings.parse` is the same real key=value/`!`-comment
    /// format `ModManifestParser.parseKeyValues` already implements
    /// (`ModManifest.settings`'s own read path), round trips through
    /// `serialize` exactly, comments and all.
    func testModCrateSettingsParseRoundTripsSerialize() {
        let original = ["FogDensity": "0.5", "GameRegion": "PAL", "SpawnPreset": "Classic"]
        let parsed = ModCrateSettings.parse(ModCrateSettings.serialize(original))
        XCTAssertEqual(parsed, original)
    }

    /// The value-equality diff `diffFromDefaults` uses as its honest
    /// (weaker, see this type's own doc comment) analog of CrateModLoader's
    /// `HasChanged`-flag-gated diff-only save: a key present in both with
    /// the same value is dropped, a key with a different value or no
    /// default at all is kept.
    func testModCrateSettingsDiffFromDefaultsKeepsOnlyChangedOrNewKeys() {
        let settings = ["FogDensity": "0.5", "GameRegion": "PAL", "SpawnPreset": "Classic"]
        let defaults = ["FogDensity": "0.5", "GameRegion": "NTSC-U"]
        let diff = ModCrateSettings.diffFromDefaults(settings, defaults: defaults)
        XCTAssertEqual(diff, ["GameRegion": "PAL", "SpawnPreset": "Classic"])
    }

    /// Real round trip through `CrateExporter.export`/`CrateArchiveManager.
    /// readManifest`: a crate exported with settings has a real
    /// `modcratesettings.txt` at its root, and reading it back yields the
    /// exact same key/value pairs.
    func testCrateExporterWritesRealModcratesettingsFileAndReadsBack() throws {
        let crateURL = tempDir.appendingPathComponent("mod.crate")
        let metadata = CrateMetadata(name: "Settings Mod", description: "", author: "", version: "1.0", targetGame: "Crash Twinsanity")
        try CrateExporter.export(
            files: [(relativePath: "level.rm2", data: Data([1, 2, 3]))],
            metadata: metadata,
            settings: ["GameRegion": "NTSC-U", "FogDensity": "0.75"],
            to: crateURL
        )

        let entries = try CrateArchiveManager.listEntries(in: crateURL)
        XCTAssertTrue(entries.contains("modcratesettings.txt"))

        let manifest = try CrateArchiveManager.readManifest(from: crateURL)
        XCTAssertEqual(manifest.settings, ["GameRegion": "NTSC-U", "FogDensity": "0.75"])
        XCTAssertEqual(manifest.declaredRegion, .ntscU)
    }

    /// The common case, most crates carry no settings at all, must not
    /// grow a `modcratesettings.txt` entry just because the parameter
    /// exists; `manifest.settings` should come back empty, same as before
    /// this parameter was added (`testReadManifestRoundTripsExportedMetadata`).
    func testCrateExporterOmitsSettingsFileWhenNoSettingsGiven() throws {
        let crateURL = tempDir.appendingPathComponent("mod.crate")
        let metadata = CrateMetadata(name: "Plain Mod", description: "", author: "", version: "1.0", targetGame: "Crash Twinsanity")
        try CrateExporter.export(files: [(relativePath: "level.rm2", data: Data([1]))], metadata: metadata, to: crateURL)

        let entries = try CrateArchiveManager.listEntries(in: crateURL)
        XCTAssertFalse(entries.contains("modcratesettings.txt"))
    }

    /// `modassets/` is CrateModLoader's real bundled-external-resource
    /// folder (`ModLoaderGlobals.ModAssetsFolderName`), real round trip
    /// through the same export path, verifying the folder and its file
    /// land at the expected zip paths and the bytes come back unchanged.
    func testCrateExporterWritesModAssetsFolder() throws {
        let crateURL = tempDir.appendingPathComponent("mod.crate")
        let metadata = CrateMetadata(name: "Asset Mod", description: "", author: "", version: "1.0", targetGame: "Crash Twinsanity")
        try CrateExporter.export(
            files: [(relativePath: "level.rm2", data: Data([1]))],
            metadata: metadata,
            settings: ["TextureOverride_42": "crate:modassets/texture_override_42.tstex"],
            modAssets: [(relativePath: "texture_override_42.tstex", data: Data([0xAA, 0xBB, 0xCC]))],
            to: crateURL
        )

        let entries = try CrateArchiveManager.listEntries(in: crateURL)
        XCTAssertTrue(entries.contains("modassets/texture_override_42.tstex"))

        let tempExtract = tempDir.appendingPathComponent("extracted-assets")
        try CrateArchiveManager.extractAll(from: crateURL, to: tempExtract)
        let assetBytes = try Data(contentsOf: tempExtract.appendingPathComponent("modassets/texture_override_42.tstex"))
        XCTAssertEqual(assetBytes, Data([0xAA, 0xBB, 0xCC]))
    }
}
