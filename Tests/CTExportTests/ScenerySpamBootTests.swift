import XCTest
import simd
import CTCore
import CTExport
import CTParsers
import CTModels

/// Follow-up experiment to `GameLauncherBootVerificationTests`'s existing
/// `testPlacingANewSceneryObjectInBeachBootsInRealPCSX2` (which proves
/// *one* new Scenery placement boots clean). A prior investigation into a
/// real user report, "adding too many objects to a level and booting it
/// hangs forever on the loading screen in real PCSX2", already tested the
/// same question against raw `Instance` record count (via
/// `WorldPlacementWriter.writeNewInstance` + `ChunkSectionInserter.
/// applyingRecordChanges` on beach.rm2's Instance section) and got a clean
/// negative result up to 100,000 added instances. This test exercises the
/// *other* real edit path instead: Scenery placements, via
/// `SceneryDataWriter.encode`'s full-record re-encode (a structurally
/// different, higher-risk write path than Instance's append-only section
/// insert), the path the reporting user's own screenshot showed them
/// actively using.
///
/// Count is controlled by the `SCENERY_SPAM_COUNT` environment variable
/// (default 8000, empirically confirmed clean below) so this can be
/// re-run at different scales without recompiling.
///
/// **Real finding from this investigation (bracketed by hand, one real
/// PCSX2 boot per count):** 3,000 / 5,000 / 7,000 / 8,500 added scenery
/// placements all boot completely clean, normal FMV progression, no
/// anomalies, real accumulated play time. At **10,000** and **30,000**,
/// something genuinely different happens: right after the second loading
/// FMV ends (the exact point the level itself loads), PCSX2's EE core
/// starts emitting a dense, continuous cascade of `EE: Unrecognized COP0
/// op` / `EE: Unrecognized FPU/COP1 op` lines (15,000+ in the 10,000
/// trial alone), real evidence the CPU jumped into or is reading
/// corrupted/garbage memory as instructions, consistent with a fixed-size
/// buffer somewhere being overrun once too many scenery placements exist.
/// This is a plausible real match for the reported "hangs forever on the
/// loading screen" symptom: PCSX2 itself keeps running (it still reports
/// accumulated play time when this test's harness terminates it), but the
/// *guest* CPU is repeatedly re-trapping on the same handful of garbage
/// opcodes rather than making forward progress, i.e., the emulated
/// console is not crashed, but the game loop inside it never leaves this
/// state, which from the player's seat looks exactly like a permanent
/// loading-screen hang. This is a real, qualitative difference from the
/// Instance-count investigation, which found no anomaly of any kind up to
/// 100,000 added Instance records, scenery placement count, not Instance
/// count, is the more likely real driver of the reported bug. The exact
/// threshold between 8,500 (clean) and 10,000 (corrupted) was not
/// narrowed further here (this file's own boot-attempt budget was spent
/// bracketing this range); a follow-up investigation should narrow it
/// further and, ideally, identify the actual overrun buffer.
final class ScenerySpamBootTests: XCTestCase {
    private static let pcsx2Binary = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/Reference Files/PCSX2-v2.6.3.app/Contents/MacOS/PCSX2")
    private static let retailISOURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/Crash Twinsanity (Europe, Australia) (En,Fr,De,Es,It).iso")

    func testPlacingManyNewSceneryObjectsInBeachBootsInRealPCSX2() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }

        let count = Int(ProcessInfo.processInfo.environment["SCENERY_SPAM_COUNT"] ?? "") ?? 8000

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("ScenerySpamBootTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let isoData = try Data(contentsOf: Self.retailISOURL, options: .mappedIfSafe)
        let source = PlainISOSource(data: isoData)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        guard let (bhEntry, bdEntry) = Self.locateArchivePair(in: root) else {
            return XCTFail("no real .BH/.BD archive pair found on this disc")
        }
        guard let bhData = ISO9660Reader.readFile(bhEntry, from: source), let bdData = ISO9660Reader.readFile(bdEntry, from: source) else {
            return XCTFail("couldn't read the real archive pair back from the disc")
        }
        let readbackDir = scratchDir.appendingPathComponent("readback")
        try FileManager.default.createDirectory(at: readbackDir, withIntermediateDirectories: true)
        let tempBH = readbackDir.appendingPathComponent((bhEntry.name as NSString).lastPathComponent)
        let tempBD = readbackDir.appendingPathComponent((bdEntry.name as NSString).lastPathComponent)
        try bhData.write(to: tempBH)
        try bdData.write(to: tempBD)
        let index = try BDArchiveParser.readIndex(bhURL: tempBH)
        guard let beachSceneryEntry = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.sm2") == .orderedSame }) else {
            return XCTFail("beach.sm2 not found in this disc's real archive index")
        }
        let beachSceneryBytes = try BDArchiveParser.readEntryData(beachSceneryEntry, index: index)
        let beachSceneryRoot = try RM2Parser.parse(data: beachSceneryBytes, fileKind: .sm2, fileName: "beach.sm2")

        func findScenery(_ node: ChunkNode) -> ChunkNode? {
            if case .scenery = node.payload { return node }
            for child in node.children {
                if let found = findScenery(child) { return found }
            }
            return nil
        }
        guard let sceneryNode = findScenery(beachSceneryRoot), case .scenery(let sceneryAsset)? = sceneryNode.payload, var root = sceneryAsset.root else {
            return XCTFail("beach.sm2 has no real, decoded SceneryData tree, can't exercise this edit shape")
        }
        let originalPlacementCount = sceneryAsset.placements.count
        XCTAssertGreaterThan(originalPlacementCount, 0, "sanity: beach.sm2 must have at least one real existing placement to base new ones' modelID/isSpecial on")
        let templatePlacement = try XCTUnwrap(sceneryAsset.placements.first { !$0.isSpecial }, "sanity: need at least one real, already-verified non-special model to place copies of")
        let basePosition = SIMD3<Float>(templatePlacement.modelMatrix[3].x, templatePlacement.modelMatrix[3].y, templatePlacement.modelMatrix[3].z)

        // Scatter `count` new placements across a grid around the template's
        // real position, reusing its real modelID (same "borrow a real,
        // already-verified ID" posture as every other test in this file
        // family) so this isn't also testing an invented/unresolvable asset.
        var newPlacements: [SceneryModelPlacement] = []
        newPlacements.reserveCapacity(count)
        let gridSpacing: Float = 8
        let gridWidth = Int(Double(count).squareRoot().rounded(.up)) + 1
        for i in 0..<count {
            let gx = Float(i % gridWidth)
            let gz = Float(i / gridWidth)
            let newPosition = SIMD3<Float>(basePosition.x + gx * gridSpacing, basePosition.y, basePosition.z + gz * gridSpacing)
            let matrix = SceneryModelPlacement.composingModelMatrix(position: newPosition, rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1))
            let boundingPosition = SIMD4<Float>(newPosition, 1)
            newPlacements.append(SceneryModelPlacement(
                modelID: templatePlacement.modelID, isSpecial: false,
                boundingBoxMin: boundingPosition - SIMD4<Float>(1, 1, 1, 0), boundingBoxMax: boundingPosition + SIMD4<Float>(1, 1, 1, 0),
                modelMatrix: matrix
            ))
        }
        let insertIndex = root.model.placements.firstIndex(where: { $0.isSpecial }) ?? root.model.placements.count
        root.model.placements.insert(contentsOf: newPlacements, at: insertIndex)
        root.model.header = 0x1613
        var mutatedScenery = sceneryAsset
        mutatedScenery.root = root
        let encodedScenery = SceneryDataWriter.encode(mutatedScenery)

        guard let modifiedBeachSceneryBytes = ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: beachSceneryRoot, insert: [(sceneryNode.recordID, encodedScenery)], removeIDs: [sceneryNode.recordID])],
            fileRoot: beachSceneryRoot, originalFileBytes: beachSceneryBytes
        ) else {
            return XCTFail("ChunkSectionInserter failed to splice the re-encoded SceneryData back in, a builder-side failure, not a PCSX2/emulator one")
        }
        XCTAssertNotEqual(modifiedBeachSceneryBytes, beachSceneryBytes, "sanity: the patch must have actually changed something")

        let plan = GameLaunchPlan(startingChunkBaseName: "beach", archiveReplacements: ["beach.sm2": modifiedBeachSceneryBytes])
        let built = try GameLauncher.building(isoURL: Self.retailISOURL, plan: plan, scratchDirectory: scratchDir)
        XCTAssertEqual(built.count % 2048, 0, "a real disc image is always a whole number of 2048-byte sectors")

        // Pre-flight, independent readback: confirm the built image's own
        // beach.sm2 really does carry `count` more real, decodable
        // placements than the original, before ever blaming PCSX2.
        let builtSource = PlainISOSource(data: built)
        let builtRoot = try ISO9660Reader.readRootDirectory(from: builtSource)
        guard let (builtBH, builtBD) = Self.locateArchivePair(in: builtRoot),
              let builtBHData = ISO9660Reader.readFile(builtBH, from: builtSource),
              let builtBDData = ISO9660Reader.readFile(builtBD, from: builtSource)
        else {
            return XCTFail("couldn't read the built image's own archive pair back")
        }
        let builtReadbackDir = scratchDir.appendingPathComponent("built-readback")
        try FileManager.default.createDirectory(at: builtReadbackDir, withIntermediateDirectories: true)
        let builtTempBH = builtReadbackDir.appendingPathComponent((builtBH.name as NSString).lastPathComponent)
        let builtTempBD = builtReadbackDir.appendingPathComponent((builtBD.name as NSString).lastPathComponent)
        try builtBHData.write(to: builtTempBH)
        try builtBDData.write(to: builtTempBD)
        let builtIndex = try BDArchiveParser.readIndex(bhURL: builtTempBH)
        guard let builtBeachSceneryEntry = builtIndex.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.sm2") == .orderedSame }) else {
            return XCTFail("beach.sm2 missing from the built image's own archive index")
        }
        let builtBeachSceneryBytes = try BDArchiveParser.readEntryData(builtBeachSceneryEntry, index: builtIndex)
        let reparsedBeachSceneryRoot = try RM2Parser.parse(data: builtBeachSceneryBytes, fileKind: .sm2, fileName: "beach.sm2")
        guard let reparsedSceneryNode = findScenery(reparsedBeachSceneryRoot), case .scenery(let reparsedAsset)? = reparsedSceneryNode.payload, reparsedAsset.root != nil else {
            return XCTFail("the built image's own beach.sm2 no longer has a decodable SceneryData tree at all")
        }
        XCTAssertEqual(reparsedAsset.placements.count, originalPlacementCount + count, "the built image handed to PCSX2 must actually carry \(count) real, decodable new placements more than the original")

        let outputISO = scratchDir.appendingPathComponent("scenery_spam_boot_test.iso")
        try built.write(to: outputISO)
        print("=== ScenerySpamBootTests: count=\(count), original=\(originalPlacementCount), built ISO size=\(built.count) bytes ===")

        let logURL = scratchDir.appendingPathComponent("pcsx2_boot_test.log")
        try? FileManager.default.removeItem(at: logURL)

        let process = Process()
        process.executableURL = Self.pcsx2Binary
        process.arguments = ["-batch", "-nogui", "-logfile", logURL.path, "-earlyconsolelog", "--", outputISO.path]
        let stdoutURL = scratchDir.appendingPathComponent("pcsx2_stdout_test.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        process.standardOutput = stdoutHandle
        process.standardError = stdoutHandle

        try process.run()
        // Same ~110s per-boot budget as the prior Instance-count
        // investigation, generous enough to distinguish "genuinely hung"
        // from "just a slow real boot."
        Thread.sleep(forTimeInterval: 110)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path), can't verify anything about this boot")
        }

        print("=== PCSX2 boot log for \(count)-new-scenery-placement (\"beach.sm2\") image (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        let sawDiscDetect = logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1")
        let sawModuleRegistration = logText.contains("RegisterLibraryEntries:  cdvdman")
        let sawPlayTime = logText.contains("Add ") && logText.contains("seconds play time to SLES-52568")
        // The real corruption signature found by this investigation (see
        // this file's own doc comment): once too many scenery placements
        // exist, the EE core starts repeatedly trapping on garbage
        // opcodes right after the loading FMVs, instead of the game
        // actually progressing. Unlike `sawPlayTime` (which PCSX2 reports
        // on any clean `terminate()`, hung guest CPU or not, so it can't
        // by itself distinguish a real hang from a real boot), a dense run
        // of these lines is real, direct evidence of that specific failure
        // mode and was never observed at any of this investigation's own
        // clean counts (3,000 / 5,000 / 7,000 / 8,500).
        let unrecognizedOpCount = logText.components(separatedBy: "EE: Unrecognized").count - 1
        let sawTrapException = logText.contains("Trap exception")
        print("=== ScenerySpamBootTests signal summary: count=\(count) discDetect=\(sawDiscDetect) moduleRegistration=\(sawModuleRegistration) playTime(not-hung)=\(sawPlayTime) unrecognizedOpCount=\(unrecognizedOpCount) sawTrapException=\(sawTrapException) ===")

        XCTAssertTrue(sawDiscDetect, "PCSX2 must genuinely resolve the boot path through our built image's own directory structure")
        XCTAssertTrue(sawModuleRegistration, "the IOP kernel must have started registering modules, real post-ELF-load execution, not just a file read")
        XCTAssertLessThan(unrecognizedOpCount, 20,
                           "PCSX2's EE core is repeatedly trapping on unrecognized opcodes (\(unrecognizedOpCount) occurrences), the real corruption signature this investigation found starting at 10,000 added scenery placements (clean through 8,500). If this now fails at \(count), the corruption threshold has moved down; if it now PASSES at 10,000+, whatever caused the corruption may have been fixed and this count is worth re-verifying as a real ceiling.")
        XCTAssertFalse(sawTrapException, "PCSX2 reported a real CPU trap exception, direct evidence of the EE core executing corrupted/garbage memory at this scenery placement count")
    }

    private static func locateArchivePair(in root: ISO9660Entry) -> (bh: ISO9660Entry, bd: ISO9660Entry)? {
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
        return walk(root)
    }
}
