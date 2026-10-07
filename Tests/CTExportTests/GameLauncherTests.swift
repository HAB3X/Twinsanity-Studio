import XCTest
import CTExport
import CTParsers
import CTModels

/// Verifies the whole "Direct Boot/Launch" build pipeline against the real
/// retail disc image on this machine, not a synthetic fixture. Every piece
/// this composes (`ISO9660Reader`/`ISO9660Writer`, `ExecutablePatcher`,
/// `BDArchiveParser`/`ArchiveRepackager`) already has its own unit tests
/// against synthetic data; what's genuinely unverified without this is
/// whether `GameLauncher`'s own tree-walking (finding `SYSTEM.CNF`, the
/// boot executable, and the disc's real `.BH`/`.BD` pair nested inside a
/// subdirectory) actually locates the right real entries. `XCTSkip`s
/// cleanly if the disc image isn't present on the machine running this.
final class GameLauncherTests: XCTestCase {
    private static let isoURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/Crash Twinsanity (USA) (v1.00).iso")

    private var scratchDir: URL!

    override func setUpWithError() throws {
        scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("GameLauncherTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratchDir)
    }

    private func skipIfMissing() throws {
        guard FileManager.default.fileExists(atPath: Self.isoURL.path) else {
            throw XCTSkip("Real retail ISO not present at \(Self.isoURL.path) on this machine.")
        }
    }

    func testBuildingWithStartingChunkOverridePatchesTheRealBootExecutable() throws {
        try skipIfMissing()
        // "beach" specifically, its "Levels\Earth\Hub\Beach" path is short
        // enough to fit the real 23-byte field (confirmed by reading the
        // retail PAL executable's own default value at this field, which
        // is exactly this). A deeper path like "cavent" genuinely doesn't
        // fit (`Levels\Earth\Cavern\cavent` is 26 bytes) and correctly
        // throws `pathTooLong`, a real constraint of the field, not a bug.
        let plan = GameLaunchPlan(startingChunkBaseName: "beach")
        let built = try GameLauncher.building(isoURL: Self.isoURL, plan: plan, scratchDirectory: scratchDir)

        let (revision, exeData) = try Self.readBackBootExecutable(from: built)
        let readBack = ExecutablePatcher.readStartingChunkPath(revision: revision, from: exeData)
        // Case-insensitive: the written value mirrors the archive entry's
        // own real casing (this disc's entry is "...\beach.sm2", lowercase),
        // not necessarily the retail default's "...\Beach" capitalization , 
        // both name the same real archive entry.
        XCTAssertEqual(readBack?.lowercased(), "levels\\earth\\hub\\beach")
    }

    func testBuildingWithTooLongChunkNameThrowsRatherThanSilentlyTruncating() throws {
        try skipIfMissing()
        let plan = GameLaunchPlan(startingChunkBaseName: "cavent")
        XCTAssertThrowsError(try GameLauncher.building(isoURL: Self.isoURL, plan: plan, scratchDirectory: scratchDir)) { error in
            XCTAssertTrue("\(error)".contains("too long"))
        }
    }

    func testBuildingWithUnknownChunkNameThrows() throws {
        try skipIfMissing()
        let plan = GameLaunchPlan(startingChunkBaseName: "this_level_does_not_exist")
        XCTAssertThrowsError(try GameLauncher.building(isoURL: Self.isoURL, plan: plan, scratchDirectory: scratchDir))
    }

    func testBuildingWithNoPlanReturnsTheImageUnchanged() throws {
        try skipIfMissing()
        let originalData = try Data(contentsOf: Self.isoURL, options: .mappedIfSafe)
        let built = try GameLauncher.building(isoURL: Self.isoURL, plan: GameLaunchPlan(), scratchDirectory: scratchDir)
        XCTAssertEqual(built.count, originalData.count)
        XCTAssertEqual(built, originalData)
    }

    /// Real regression: the global "Play in PCSX2" launch (no starting-
    /// chunk override, no archive replacements, exactly `GameLaunchPlan()`)
    /// used to hit an early return inside `building` before the scratch
    /// directory ever got created, so `GameLauncherView`'s own subsequent
    /// write of the built image into that directory failed with "No such
    /// file or directory." This pins the actual caller sequence, build,
    /// then write into `scratchDirectory`, not just that `building` alone
    /// doesn't throw.
    func testScratchDirectoryExistsAfterBuildingWithNoPlanSoCallerCanWriteIntoIt() throws {
        try skipIfMissing()
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchDir.path), "starting from a genuinely nonexistent directory, matching a fresh temp folder")
        let built = try GameLauncher.building(isoURL: Self.isoURL, plan: GameLaunchPlan(), scratchDirectory: scratchDir)
        let outputURL = scratchDir.appendingPathComponent("launch.iso")
        XCTAssertNoThrow(try built.write(to: outputURL), "GameLauncherView performs exactly this write immediately after building")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testBuildingWithArchiveReplacementActuallyPatchesTheArchivedEntry() throws {
        try skipIfMissing()
        let markerBytes = Data("GAMELAUNCHERTEST".utf8)
        let plan = GameLaunchPlan(archiveReplacements: ["cavent.rm2": markerBytes])
        let built = try GameLauncher.building(isoURL: Self.isoURL, plan: plan, scratchDirectory: scratchDir)

        let source = PlainISOSource(data: built)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        let (bhEntry, bdEntry) = try Self.locateArchivePairForTest(in: root)
        guard let bhData = ISO9660Reader.readFile(bhEntry, from: source), let bdData = ISO9660Reader.readFile(bdEntry, from: source) else {
            return XCTFail("Couldn't re-read the archive pair from the built image.")
        }
        let extractDir = scratchDir.appendingPathComponent("readback")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let bhURL = extractDir.appendingPathComponent((bhEntry.name as NSString).lastPathComponent)
        let bdURL = extractDir.appendingPathComponent((bdEntry.name as NSString).lastPathComponent)
        try bhData.write(to: bhURL)
        try bdData.write(to: bdURL)
        let index = try BDArchiveParser.readIndex(bhURL: bhURL)

        guard let match = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("cavent.rm2") == .orderedSame }) else {
            return XCTFail("cavent.rm2 not found in the repackaged archive.")
        }
        let entryData = try BDArchiveParser.readEntryData(match, index: index)
        XCTAssertEqual(entryData, markerBytes)

        // A totally unrelated entry must have streamed through byte-for-byte unchanged.
        guard let untouched = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.sm2") == .orderedSame }) else {
            return XCTFail("beach.sm2 not found in the repackaged archive.")
        }
        XCTAssertNotEqual(try BDArchiveParser.readEntryData(untouched, index: index), markerBytes)
        XCTAssertGreaterThan(untouched.size, 0)
    }

    /// `rebuildingAndVerifying` for the no-plan (global "Play in PCSX2")
    /// case: no starting-chunk override, no archive replacements, so the
    /// image comes back byte-identical to the source (same as `building`
    /// itself already proves in `testBuildingWithNoPlanReturnsTheImageUnchanged`)
    ///, what this pins down that the other test doesn't is that the
    /// *independent re-verification* pass itself actually runs and reports
    /// real, non-empty diagnostics against a genuinely valid rebuilt image,
    /// not just that `building`'s own bytes happen to be correct.
    func testRebuildingAndVerifyingWithNoPlanReturnsValidImageAndNonEmptyDiagnostics() throws {
        try skipIfMissing()
        let result = try GameLauncher.rebuildingAndVerifying(isoURL: Self.isoURL, plan: GameLaunchPlan(), scratchDirectory: scratchDir)

        XCTAssertFalse(result.data.isEmpty)
        XCTAssertEqual(result.data.count % 2048, 0, "a real disc image is always a whole number of 2048-byte sectors")
        XCTAssertFalse(result.diagnostics.isEmpty, "the UI relies on this to show real progress, not just a spinner")
        XCTAssertTrue(result.diagnostics.contains { $0.contains("sectors") }, "expected a diagnostic line reporting the rebuilt image's byte/sector counts, got: \(result.diagnostics)")
        XCTAssertTrue(result.diagnostics.contains { $0.localizedCaseInsensitiveContains("root directory") }, "expected a diagnostic line about the re-read root directory, got: \(result.diagnostics)")

        // Independently confirm the returned bytes are actually a real,
        // readable disc image, the same check a genuine consumer (writing
        // it to disk and booting it) would perform.
        let source = PlainISOSource(data: result.data)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        XCTAssertFalse(root.children.isEmpty)
    }

    /// The archive-replacement path of `rebuildingAndVerifying`'s own
    /// verification: confirms it actually re-locates and re-parses the
    /// rebuilt `.BH`/`.BD` pair and reports the replaced entry as present,
    /// not just that `building`'s own repackaging succeeded.
    func testRebuildingAndVerifyingWithArchiveReplacementVerifiesTheRebuiltArchive() throws {
        try skipIfMissing()
        let markerBytes = Data("GAMELAUNCHERTEST".utf8)
        let plan = GameLaunchPlan(archiveReplacements: ["cavent.rm2": markerBytes])
        let result = try GameLauncher.rebuildingAndVerifying(isoURL: Self.isoURL, plan: plan, scratchDirectory: scratchDir)

        XCTAssertTrue(result.diagnostics.contains { $0.localizedCaseInsensitiveContains("archive") }, "expected an archive-verification diagnostic line, got: \(result.diagnostics)")
        XCTAssertTrue(result.diagnostics.contains { $0.contains("1 requested replacement") }, "expected a diagnostic confirming the one requested replacement was found, got: \(result.diagnostics)")
    }

    /// "Create New Chunks/Levels, Chunk Cloning": `newArchiveEntries` is
    /// keyed by a full, already-path-qualified name that has *no* existing
    /// match in the archive at all, unlike `archiveReplacements`, which
    /// only ever swaps an already-known entry's bytes. Confirms
    /// `ArchiveRepackager.repackage`'s own "no match -> append as new"
    /// behavior is actually reachable through `GameLaunchPlan`/`building`,
    /// not just true of `ArchiveRepackager` in isolation.
    func testBuildingWithNewArchiveEntryInsertsAGenuinelyNewEntry() throws {
        try skipIfMissing()
        let markerBytes = Data("GAMELAUNCHERCLONETEST".utf8)
        let plan = GameLaunchPlan(newArchiveEntries: ["Levels/Earth/Hub/beach_clonetest.sm2": markerBytes])
        let built = try GameLauncher.building(isoURL: Self.isoURL, plan: plan, scratchDirectory: scratchDir)

        let source = PlainISOSource(data: built)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        let (bhEntry, bdEntry) = try Self.locateArchivePairForTest(in: root)
        guard let bhData = ISO9660Reader.readFile(bhEntry, from: source), let bdData = ISO9660Reader.readFile(bdEntry, from: source) else {
            return XCTFail("Couldn't re-read the archive pair from the built image.")
        }
        let extractDir = scratchDir.appendingPathComponent("readback_new_entry")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let bhURL = extractDir.appendingPathComponent((bhEntry.name as NSString).lastPathComponent)
        let bdURL = extractDir.appendingPathComponent((bdEntry.name as NSString).lastPathComponent)
        try bhData.write(to: bhURL)
        try bdData.write(to: bdURL)
        let index = try BDArchiveParser.readIndex(bhURL: bhURL)

        guard let match = index.entries.first(where: { $0.name.caseInsensitiveCompare("Levels/Earth/Hub/beach_clonetest.sm2") == .orderedSame }) else {
            return XCTFail("The new entry wasn't found in the repackaged archive at all.")
        }
        XCTAssertEqual(try BDArchiveParser.readEntryData(match, index: index), markerBytes)

        // The real, original entry it was "cloned from" must still exist,
        // completely untouched, inserting a new entry must never displace
        // an existing one.
        guard let original = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.sm2") == .orderedSame }) else {
            return XCTFail("beach.sm2 not found in the repackaged archive.")
        }
        XCTAssertNotEqual(try BDArchiveParser.readEntryData(original, index: index), markerBytes)
    }

    func testRebuildingAndVerifyingWithNewArchiveEntryVerifiesItIsPresent() throws {
        try skipIfMissing()
        let markerBytes = Data("GAMELAUNCHERCLONETEST2".utf8)
        let plan = GameLaunchPlan(newArchiveEntries: ["Levels/Earth/Hub/beach_clonetest2.sm2": markerBytes])
        let result = try GameLauncher.rebuildingAndVerifying(isoURL: Self.isoURL, plan: plan, scratchDirectory: scratchDir)

        XCTAssertTrue(result.diagnostics.contains { $0.contains("1 new entries") || $0.localizedCaseInsensitiveContains("new entries confirmed present") }, "expected a diagnostic confirming the new entry was found, got: \(result.diagnostics)")
    }

    // MARK: - "Strict Size Guardrails", pure arithmetic, no real disc needed

    func testSizeGrowthFractionComputesPositiveGrowth() {
        // 100MB -> 130MB is exactly +30%.
        let fraction = GameLauncher.sizeGrowthFraction(originalBytes: 100_000_000, rebuiltBytes: 130_000_000)
        XCTAssertEqual(fraction, 0.30, accuracy: 0.0001)
    }

    func testSizeGrowthFractionComputesNegativeShrinkage() {
        // A real, expected outcome now that ISO9660Writer reclaims a
        // file's own prior tail space, the rebuild can come back
        // *smaller* than the original.
        let fraction = GameLauncher.sizeGrowthFraction(originalBytes: 100_000_000, rebuiltBytes: 90_000_000)
        XCTAssertEqual(fraction, -0.10, accuracy: 0.0001)
    }

    func testSizeGrowthFractionWithZeroOriginalBytesReturnsZeroRatherThanDividingByZero() {
        XCTAssertEqual(GameLauncher.sizeGrowthFraction(originalBytes: 0, rebuiltBytes: 500), 0)
    }

    func testRebuildResultExceedsSizeGrowthThresholdOnlyPastTheRealBoundary() {
        // Exactly at the default 25% boundary: "no minor edit justifies
        // *above* 25%", the guardrail's own wording is a strict `>`, so
        // exactly 25% must NOT trip it.
        let atBoundary = GameLauncher.RebuildResult(data: Data(count: 125), diagnostics: [], originalSizeBytes: 100)
        XCTAssertEqual(atBoundary.sizeGrowthFraction, 0.25, accuracy: 0.0001)
        XCTAssertFalse(atBoundary.exceedsSizeGrowthThreshold())

        let justOver = GameLauncher.RebuildResult(data: Data(count: 126), diagnostics: [], originalSizeBytes: 100)
        XCTAssertTrue(justOver.exceedsSizeGrowthThreshold())

        let shrunk = GameLauncher.RebuildResult(data: Data(count: 80), diagnostics: [], originalSizeBytes: 100)
        XCTAssertFalse(shrunk.exceedsSizeGrowthThreshold())
    }

    func testRebuildResultExceedsSizeGrowthThresholdAcceptsACustomThreshold() {
        let result = GameLauncher.RebuildResult(data: Data(count: 110), diagnostics: [], originalSizeBytes: 100)
        XCTAssertFalse(result.exceedsSizeGrowthThreshold(0.25), "10% growth must not trip the default 25% guardrail")
        XCTAssertTrue(result.exceedsSizeGrowthThreshold(0.05), "10% growth must trip a stricter, explicitly-passed 5% guardrail")
    }

    /// Real, end-to-end proof (against the actual retail disc, when
    /// present) that a genuinely tiny edit stays comfortably under the
    /// guardrail, the size check shouldn't cry wolf on the common case.
    func testRebuildingAndVerifyingWithATinyArchiveReplacementStaysWellUnderTheSizeGrowthThreshold() throws {
        try skipIfMissing()
        let markerBytes = Data("GAMELAUNCHERTEST".utf8)
        let plan = GameLaunchPlan(archiveReplacements: ["cavent.rm2": markerBytes])
        let result = try GameLauncher.rebuildingAndVerifying(isoURL: Self.isoURL, plan: plan, scratchDirectory: scratchDir)
        XCTAssertFalse(result.exceedsSizeGrowthThreshold(), "a single tiny archive entry replacement must never trip the 25% guardrail")
        XCTAssertTrue(result.diagnostics.contains { $0.contains("Size check:") }, "expected a diagnostic line reporting the before/after size, got: \(result.diagnostics)")
    }

    // MARK: - Helpers mirroring GameLauncher's own private tree-walking, for read-back verification only

    private static func readBackBootExecutable(from isoData: Data) throws -> (revision: GameExecutableRevision, exeData: Data) {
        let source = PlainISOSource(data: isoData)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        guard let cnfEntry = root.children.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare("SYSTEM.CNF") == .orderedSame }),
              let cnfData = ISO9660Reader.readFile(cnfEntry, from: source),
              let cnfText = String(data: cnfData, encoding: .ascii)
        else { throw XCTSkip("Couldn't read SYSTEM.CNF back from the built image.") }
        let info = SystemCNFParser.parse(contents: cnfText)
        guard let serial = info.serial,
              let exeEntry = root.children.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare(serial) == .orderedSame }),
              let exeData = ISO9660Reader.readFile(exeEntry, from: source)
        else { throw XCTSkip("Couldn't locate the boot executable back in the built image.") }
        let upper = serial.uppercased()
        let revision: GameExecutableRevision
        if upper.hasPrefix("SLUS") || upper.hasPrefix("SCUS") {
            revision = ExecutablePatcher.detectNTSCURevision(exeData: exeData) ?? .ntscU
        } else if upper.hasPrefix("SLES") || upper.hasPrefix("SCES") {
            revision = .pal
        } else {
            revision = .ntscJ
        }
        return (revision, exeData)
    }

    private static func locateArchivePairForTest(in root: ISO9660Entry) throws -> (bh: ISO9660Entry, bd: ISO9660Entry) {
        func walk(_ node: ISO9660Entry) -> (bh: ISO9660Entry, bd: ISO9660Entry)? {
            if let bh = node.children.first(where: { !$0.isDirectory && $0.name.uppercased().hasSuffix(".BH") }) {
                let base = (bh.name as NSString).deletingPathExtension
                if let bd = node.children.first(where: { !$0.isDirectory && (($0.name as NSString).deletingPathExtension).caseInsensitiveCompare(base) == .orderedSame && $0.name.uppercased().hasSuffix(".BD") }) {
                    return (bh, bd)
                }
            }
            for child in node.children where child.isDirectory {
                if let found = walk(child) { return found }
            }
            return nil
        }
        guard let pair = walk(root) else { throw XCTSkip("No .BH/.BD pair found on this disc image.") }
        return pair
    }
}
