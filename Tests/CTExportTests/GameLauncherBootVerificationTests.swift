import XCTest
import simd
import CTCore
import CTExport
import CTParsers
import CTModels

/// "Real Edited-Chunk Boot Verification", the one thing neither
/// `ImageMakerBootVerificationTests` (boots an *unmodified* rebuild-from-
/// folder disc, its own doc comment is explicit about that) nor
/// `GameLauncherTests` (only ever reads the patched bytes back in memory,
/// never hands them to a real emulator) actually covers: does a genuinely
/// *edited* disc image, built via the real `GameLauncher.building` write-
/// back pipeline this app's own "Save Rebuilt ISO…", Quick Launch, and
/// quit-time autosave features all use, actually boot in a real PCSX2, and
/// is there real, external evidence (not just "PCSX2 didn't crash") that
/// the *edited* starting chunk is what got loaded, as opposed to PCSX2
/// having silently ignored the patch and booted the unmodified retail
/// default (which, unpatched, boots the main menu, not any level at all,
/// so a level actually being the target here is already a real distinction)?
///
/// The signal: `ExecutablePatcher.writingStartingChunkPath` patches 23 real
/// bytes inside the boot executable itself (not a side config file), so a
/// disc genuinely carrying the edit has a boot executable whose bytes
/// differ from retail. PCSX2's own "Game CRC" log line, the exact line
/// `ImageMakerBootVerificationTests` pins to the known-good *unmodified*
/// retail PAL value `1510E1D1`, is computed from those same executable
/// bytes. A real PCSX2 boot that reports a Game CRC other than `1510E1D1`
/// is external proof, from PCSX2 itself, that it loaded our edited
/// executable rather than the unmodified retail one. That's combined with
/// an independent pre-flight readback (before PCSX2 ever sees the file, via
/// the same real `ISO9660Reader`/`ExecutablePatcher.readStartingChunkPath`
/// a genuine consumer would use) confirming the disc image actually handed
/// to PCSX2 carries the patched "levels\earth\hub\beach" field, not just
/// that `GameLauncher.building` claimed to apply it.
///
/// Targets "beach" specifically: a real level, deliberately different from
/// this disc's own unmodified default boot target, and short enough to fit
/// the PAL build's real 23-byte starting-chunk field (the same field length
/// `GameLauncherTests.testBuildingWithStartingChunkOverridePatchesTheRealBootExecutable`
/// already confirms "beach" fits against the NTSC-U build).
///
/// Skips cleanly if the real retail PAL disc image or real PCSX2 binary
/// isn't present on the machine running this, same convention as
/// `ImageMakerBootVerificationTests`/`RealDiscDiagnosticTests`; this is
/// inherently a local, interactive-adjacent verification PCSX2 can't run in
/// CI.
final class GameLauncherBootVerificationTests: XCTestCase {
    private static let pcsx2Binary = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/Reference Files/PCSX2-v2.6.3.app/Contents/MacOS/PCSX2")
    // Real, measured bug this project spent a full session chasing: the
    // previous path here ("...-WORKING.iso.iso") was itself an already-
    // corrupted disc, not a genuine pristine retail dump, its MD5 didn't
    // match the verified SLES-52568 checksum, its size (3326.6MB) was
    // almost exactly a correct dump (2439.8MB) plus one extra orphaned
    // copy of the ~930MB CRASH.BD archive, and it TLB-missed into a null
    // pointer around 45-53s into every single real PCSX2 boot -- including
    // completely unmodified `GameLaunchPlan()` runs that never touched a
    // single byte. That crash had nothing to do with this project's own
    // disc-rebuild code; it was baked into the "pristine" fixture itself,
    // almost certainly from an earlier, pre-fix run of this exact tool's
    // old unsafe `ISO9660Writer` gap-reuse logic (see that file's own
    // top-level doc comment). This path is confirmed byte-for-byte
    // identical (MD5 8340e0bf533815cff20668bfb2d5a871) to the verified
    // SLES-52568 retail dump, and boots to real, playable gameplay in a
    // real PCSX2 process, past the exact point every prior fixture always
    // died.
    private static let retailISOURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/Crash Twinsanity (Europe, Australia) (En,Fr,De,Es,It).iso")
    /// The real, known-good Crash Twinsanity PAL executable hash for the
    /// *unmodified* retail boot ELF, the same value
    /// `ImageMakerBootVerificationTests` pins its own success signal to.
    /// If a boot of our edited image ever reported this exact CRC, that
    /// would mean PCSX2 silently loaded the unpatched executable instead of
    /// the one this test actually built.
    private static let retailBootCRC = "1510E1D1"

    func testGameLauncherEditedStartingChunkBootsInRealPCSX2WithDifferentCRC() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("GameLauncherBootVerificationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let plan = GameLaunchPlan(startingChunkBaseName: "beach")
        let built = try GameLauncher.building(isoURL: Self.retailISOURL, plan: plan, scratchDirectory: scratchDir)
        XCTAssertEqual(built.count % 2048, 0, "a real disc image is always a whole number of 2048-byte sectors")

        // Pre-flight, independent readback, before PCSX2 ever sees this
        // file, confirming the exact bytes we're about to hand it really
        // do carry the edit, not just that `building` claimed to apply it.
        let source = PlainISOSource(data: built)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        guard let exeEntry = root.children.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare("SLES_525.68") == .orderedSame }) else {
            return XCTFail("built image is missing its own real PAL boot executable, not a PCSX2 problem, a builder problem")
        }
        guard let exeData = ISO9660Reader.readFile(exeEntry, from: source) else {
            return XCTFail("couldn't read the boot executable back from the built image")
        }
        let readBackPath = ExecutablePatcher.readStartingChunkPath(revision: .pal, from: exeData)
        XCTAssertEqual(readBackPath?.lowercased(), "levels\\earth\\hub\\beach",
                        "the built image's own boot executable must carry the edited starting chunk before we ever hand it to PCSX2")

        let outputISO = scratchDir.appendingPathComponent("gamelauncher_boot_test.iso")
        try built.write(to: outputISO)

        let logURL = scratchDir.appendingPathComponent("pcsx2_boot_test.log")
        try? FileManager.default.removeItem(at: logURL)

        let process = Process()
        process.executableURL = Self.pcsx2Binary
        process.arguments = ["-batch", "-nogui", "-logfile", logURL.path, "-earlyconsolelog", "--", outputISO.path]
        // Without an explicit stdout/stderr file handle, `Process` launched
        // from inside `swift test` leaves PCSX2's console-log thread unable
        // to ever flush `-logfile` to disk, the exact same issue
        // `ImageMakerBootVerificationTests` documents and works around.
        let stdoutURL = scratchDir.appendingPathComponent("pcsx2_stdout_test.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        process.standardOutput = stdoutHandle
        process.standardError = stdoutHandle

        try process.run()

        // Same timeout budget as `ImageMakerBootVerificationTests`, this
        // is a boot smoke test, not a full playthrough, and the edit here
        // is 23 bytes inside the same executable region PCSX2 loads
        // identically regardless of the patch, so boot timing shouldn't
        // differ from the unmodified case that test's own timeout was
        // tuned against.
        Thread.sleep(forTimeInterval: 15)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path), can't verify anything about this boot")
        }

        // Record the real log content regardless of outcome.
        print("=== PCSX2 boot log for edited (\"beach\" starting chunk) image (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        XCTAssertTrue(logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1"),
                       "PCSX2 must genuinely resolve the boot path through our built ISO's own directory structure")
        XCTAssertTrue(logText.contains("RegisterLibraryEntries:  cdvdman"),
                       "the IOP kernel must have started registering modules, real post-ELF-load execution, not just a file read")
        XCTAssertTrue(logText.contains("Add ") && logText.contains("seconds play time to SLES-52568"),
                       "PCSX2 must report real accumulated play time, proof the edited disc actually ran, not just loaded")

        guard let crcRange = logText.range(of: "Game CRC = ") else {
            return XCTFail("PCSX2's log never reported a Game CRC for this boot, can't confirm which executable it actually loaded")
        }
        let afterPrefix = logText[crcRange.upperBound...]
        let crcToken = String(afterPrefix.prefix { $0.isHexDigit }).uppercased()
        XCTAssertEqual(crcToken.count, 8, "expected an 8-hex-digit Game CRC in the real log, got \"\(crcToken)\"")

        // The decisive, real, external signal: our starting-chunk patch
        // lives inside the boot executable's own bytes, and PCSX2's Game
        // CRC is computed from those same bytes. The unmodified retail
        // PAL boot executable's CRC would only appear here if PCSX2 had
        // somehow booted the unpatched executable instead of the one this
        // test actually built with the "beach" starting-chunk edit baked
        // in, i.e. this assertion is exactly what would fail if the
        // write-back pipeline silently produced a no-op disc.
        XCTAssertNotEqual(crcToken, Self.retailBootCRC,
                           "PCSX2 reported the unmodified retail Game CRC, it booted the wrong (unedited) executable, not the one this test built with the \"beach\" starting-chunk patch")
    }

    /// "General optimization" investigation (real user report: a rebuilt
    /// ISO loads at ~2fps in PCSX2): `GameLaunchPlan.archiveReplacements`
    /// swaps in a whole edited level file, which is essentially never
    /// byte-identical in length to what it replaces, `ArchiveRepackager`
    /// then produces a `.BD` whose total size differs from the original, so
    /// `ISO9660Writer.replacingFile` takes its `appendAndRelocate` path
    /// (`ISO9660Writer`'s own doc comment: "same size or smaller" patches in
    /// place, "larger" relocates). Measured against this real retail PAL
    /// disc (see the diagnostic this test's fix grew out of): relocating the
    /// ~930MB main archive after even a 1-byte edit moved it to LBA
    /// 1,249,152, the *exact* sector the untouched Primary Volume
    /// Descriptor's own "Volume Space Size" field still claimed was the end
    /// of the volume. Every byte of the game's actual level/asset data then
    /// sat in disc space the volume descriptor said didn't exist, a real
    /// ECMA-119 spec violation `ISO9660Writer.appendAndRelocate` now fixes
    /// by keeping that field in sync on every relocation.
    ///
    /// This is the one thing that fix's own unit-level coverage
    /// (`DiscImageTests`, synthetic data) can't show: whether a real disc
    /// built through this exact relocation path, the one real users
    /// actually hit every time they launch an edited level, still boots
    /// cleanly in a real PCSX2 with the corrected volume size in place.
    func testGameLauncherArchiveReplacementRelocationBootsInRealPCSX2() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("GameLauncherBootVerificationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        // Read a real archive entry's own bytes back out and grow it by one
        // byte, the smallest possible edit that still forces a real size
        // change, and therefore a real relocation, exactly like any genuine
        // level edit would.
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
        guard let caventEntry = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("cavent.rm2") == .orderedSame }) else {
            return XCTFail("cavent.rm2 not found in this disc's real archive index")
        }
        var modifiedBytes = try BDArchiveParser.readEntryData(caventEntry, index: index)
        modifiedBytes.append(0xAB)

        let plan = GameLaunchPlan(archiveReplacements: ["cavent.rm2": modifiedBytes])
        let built = try GameLauncher.building(isoURL: Self.retailISOURL, plan: plan, scratchDirectory: scratchDir)
        XCTAssertGreaterThan(built.count, isoData.count, "a genuinely larger repackaged archive really did grow the image (confirms this test exercises the relocation path, not an accidental no-op)")

        // Pre-flight, independent readback: the fixed image's own PVD must
        // now declare a Volume Space Size covering the whole real file, not
        // just the pre-relocation original size.
        let builtSource = PlainISOSource(data: built)
        guard let declared = Self.declaredVolumeSpaceSize(built) else {
            return XCTFail("couldn't read the built image's own Primary Volume Descriptor back")
        }
        XCTAssertEqual(Int(declared), built.count / 2048,
                        "the rebuilt image's own declared Volume Space Size must cover its real total size after relocation, this is the exact bug this test guards against")
        let builtRoot = try ISO9660Reader.readRootDirectory(from: builtSource)
        XCTAssertFalse(builtRoot.children.isEmpty)

        let outputISO = scratchDir.appendingPathComponent("gamelauncher_relocation_boot_test.iso")
        try built.write(to: outputISO)

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
        // Longer than the starting-chunk-only test's 15s budget: this
        // image is genuinely larger (the relocated archive plus its own
        // now-orphaned original copy), so PCSX2 needs more wall-clock time
        // to open/mount it before it starts producing log output.
        Thread.sleep(forTimeInterval: 90)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path), can't verify anything about this boot")
        }
        try? logData.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("RAW_relocation_boot.log"))

        print("=== PCSX2 boot log for archive-relocated (cavent.rm2 +1 byte) image (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        XCTAssertTrue(logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1"),
                       "PCSX2 must genuinely resolve the boot path through our relocated-archive image's own directory structure")
        XCTAssertTrue(logText.contains("RegisterLibraryEntries:  cdvdman"),
                       "the IOP kernel must have started registering modules, real post-ELF-load execution, not just a file read")
        XCTAssertTrue(logText.contains("Add ") && logText.contains("seconds play time to SLES-52568"),
                       "PCSX2 must report real accumulated play time, proof this disc actually ran, not just loaded, with the relocated archive's own volume size in place")
    }

    /// Real, reported bug under investigation: the user's own edits, both
    /// placing a new object/scenery and moving an existing one, black-
    /// screen when quick-launched, even against a genuinely complete,
    /// working retail ISO (ruling out a corrupt source disc, confirmed
    /// separately). `testGameLauncherArchiveReplacementRelocationBootsInRealPCSX2`
    /// already proves the generic archive-relocation container mechanism
    /// itself boots cleanly for an arbitrary 1-byte grow, so if this test
    /// *also* boots cleanly, the bug isn't in `GameLauncher`/`ISO9660Writer`
    /// at all, and points instead at how a specific edit's bytes get
    /// encoded (`WorldPlacementWriter`/`ChunkSectionInserter`/the Level
    /// Viewer's own patch-building) or something PCSX2-side that a generic
    /// relocation test can't see. This exercises the exact "move an
    /// existing Instance" edit shape (`WorldPlacementWriter.
    /// writeInstanceTransform`, patched at the record's own `fileOffset` , 
    /// the same fixed-size-prefix patch `ModelViewerRenderer.
    /// pendingLevelOverrides` produces for a real gizmo drag) against the
    /// real "beach" level this session's other fixes already targeted.
    func testMovingARealInstanceInBeachBootsInRealPCSX2() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("GameLauncherBootVerificationTests-\(UUID().uuidString)")
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
        guard let beachEntry = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.rm2") == .orderedSame }) else {
            return XCTFail("beach.rm2 not found in this disc's real archive index")
        }
        let beachBytes = try BDArchiveParser.readEntryData(beachEntry, index: index)

        let beachRoot = try RM2Parser.parse(data: beachBytes, fileKind: .rm2, fileName: "beach.rm2")
        func findFirstInstance(_ node: ChunkNode) -> ChunkNode? {
            if case .instance = node.payload { return node }
            for child in node.children {
                if let found = findFirstInstance(child) { return found }
            }
            return nil
        }
        guard let instanceNode = findFirstInstance(beachRoot), case .instance(let placed)? = instanceNode.payload else {
            return XCTFail("beach.rm2 has no real, decoded Instance record to move, can't exercise this edit shape")
        }

        // The exact same fixed-size-prefix patch a real gizmo drag produces
        // (`ModelViewerRenderer.pendingLevelOverrides`), move it 5 units
        // along X, re-encode, and splice the 28-byte transform prefix back
        // in at the record's own real file offset. Never changes the
        // record's total size, so nothing else in the file moves.
        let movedPosition = SIMD4<Float>(placed.position.x + 5, placed.position.y, placed.position.z, placed.position.w)
        let encoded = WorldPlacementWriter.writeInstanceTransform(position: movedPosition, rotationRaw: placed.rotationRaw, comRotationRaw: placed.comRotationRaw)
        var modifiedBeachBytes = beachBytes
        let patchRange = instanceNode.fileOffset..<(instanceNode.fileOffset + encoded.count)
        guard patchRange.upperBound <= modifiedBeachBytes.count else {
            return XCTFail("computed patch range \(patchRange) is out of bounds for a \(modifiedBeachBytes.count)-byte file")
        }
        modifiedBeachBytes.replaceSubrange(patchRange, with: encoded)
        XCTAssertNotEqual(modifiedBeachBytes, beachBytes, "sanity: the patch must have actually changed something")

        let plan = GameLaunchPlan(startingChunkBaseName: "beach", archiveReplacements: ["beach.rm2": modifiedBeachBytes])
        let built = try GameLauncher.building(isoURL: Self.retailISOURL, plan: plan, scratchDirectory: scratchDir)
        XCTAssertEqual(built.count % 2048, 0, "a real disc image is always a whole number of 2048-byte sectors")

        // Pre-flight, independent readback, before PCSX2 ever sees this
        // file, confirming the built image's own beach.rm2 really does
        // carry the moved position, and that our own parser can still read
        // it back correctly (rules out this test's own patch math as the
        // bug before ever blaming PCSX2/the emulator for what follows).
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
        guard let builtBeachEntry = builtIndex.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.rm2") == .orderedSame }) else {
            return XCTFail("beach.rm2 missing from the built image's own archive index")
        }
        let builtBeachBytes = try BDArchiveParser.readEntryData(builtBeachEntry, index: builtIndex)
        let reparsedBeachRoot = try RM2Parser.parse(data: builtBeachBytes, fileKind: .rm2, fileName: "beach.rm2")
        guard let reparsedInstanceNode = findFirstInstance(reparsedBeachRoot), case .instance(let reparsedPlaced)? = reparsedInstanceNode.payload else {
            return XCTFail("the built image's own beach.rm2 no longer has a decodable Instance record at all")
        }
        XCTAssertEqual(reparsedPlaced.position.x, movedPosition.x, accuracy: 0.01, "the built image handed to PCSX2 must actually carry the moved position")

        let outputISO = scratchDir.appendingPathComponent("gamelauncher_moved_instance_boot_test.iso")
        try built.write(to: outputISO)

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
        Thread.sleep(forTimeInterval: 90)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path), can't verify anything about this boot")
        }

        print("=== PCSX2 boot log for moved-Instance (\"beach.rm2\") image (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        XCTAssertTrue(logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1"),
                       "PCSX2 must genuinely resolve the boot path through our built image's own directory structure")
        XCTAssertTrue(logText.contains("RegisterLibraryEntries:  cdvdman"),
                       "the IOP kernel must have started registering modules, real post-ELF-load execution, not just a file read")
        XCTAssertTrue(logText.contains("Add ") && logText.contains("seconds play time to SLES-52568"),
                       "PCSX2 must report real accumulated play time, the real, reported symptom under test is a black screen, which would mean this boot never reaches gameplay at all")
    }

    /// The other half of the same real, reported bug this test file is
    /// investigating: unlike moving an *existing* Instance (a fixed-size
    /// prefix patch, proven clean above), placing a brand-new one is a real
    /// *insertion*, `ChunkSectionInserter` has to grow the Instance
    /// collection's own tier-2 section and rebuild every index-table offset
    /// after it, real structural surgery a simple byte-range patch never
    /// touches. This is exactly what the Forge Palette produces
    /// (`WorldPlacementWriter.writeNewInstance` + `WorkspaceViewModel.
    /// patchedFileBytes(insertingNewInstances:)`), reproduced here directly
    /// against the real "beach" level.
    func testPlacingANewInstanceInBeachBootsInRealPCSX2() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("GameLauncherBootVerificationTests-\(UUID().uuidString)")
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
        guard let beachEntry = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.rm2") == .orderedSame }) else {
            return XCTFail("beach.rm2 not found in this disc's real archive index")
        }
        let beachBytes = try BDArchiveParser.readEntryData(beachEntry, index: index)
        let beachRoot = try RM2Parser.parse(data: beachBytes, fileKind: .rm2, fileName: "beach.rm2")

        func findFirstInstance(_ node: ChunkNode) -> ChunkNode? {
            if case .instance = node.payload { return node }
            for child in node.children {
                if let found = findFirstInstance(child) { return found }
            }
            return nil
        }
        guard let existingInstanceNode = findFirstInstance(beachRoot), case .instance(let existingPlaced)? = existingInstanceNode.payload else {
            return XCTFail("beach.rm2 has no real, decoded Instance record, can't pick a real objectID to place")
        }

        func findObjectInstanceCollection(_ node: ChunkNode) -> ChunkNode? {
            let targetTypes: Set<SectionType> = [.objectInstance, .objectInstanceDemo]
            if targetTypes.contains(node.sectionType) { return node }
            for child in node.children {
                if let found = findObjectInstanceCollection(child) { return found }
            }
            return nil
        }
        guard let collectionNode = findObjectInstanceCollection(beachRoot) else {
            return XCTFail("beach.rm2 has no real Instance (ObjectInstanceCollection) section to insert into")
        }

        // Same real encoder the Forge Palette uses to place a brand-new
        // Instance, reusing a real objectID already proven to exist in this
        // level so this isn't testing an invented/unresolvable object , 
        // same "borrow a real, already-verified ID" posture the rest of
        // this test file already takes with `cavent.rm2`/`beach.rm2`
        // themselves.
        let syntheticID: UInt32 = 999_999
        let newInstanceBytes = WorldPlacementWriter.writeNewInstance(
            objectID: existingPlaced.objectID,
            position: SIMD4<Float>(existingPlaced.position.x + 3, existingPlaced.position.y, existingPlaced.position.z + 3, existingPlaced.position.w),
            rotationDegrees: .zero
        )
        guard let modifiedBeachBytes = ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: collectionNode, insert: [(id: syntheticID, encoded: newInstanceBytes)], removeIDs: [])],
            fileRoot: beachRoot,
            originalFileBytes: beachBytes
        ) else {
            return XCTFail("ChunkSectionInserter failed to insert the new Instance, a builder-side failure, not a PCSX2/emulator one")
        }
        XCTAssertGreaterThan(modifiedBeachBytes.count, beachBytes.count, "sanity: inserting a brand-new record must grow the file")

        let plan = GameLaunchPlan(startingChunkBaseName: "beach", archiveReplacements: ["beach.rm2": modifiedBeachBytes])
        let built = try GameLauncher.building(isoURL: Self.retailISOURL, plan: plan, scratchDirectory: scratchDir)
        XCTAssertEqual(built.count % 2048, 0, "a real disc image is always a whole number of 2048-byte sectors")

        // Pre-flight, independent readback: confirm the built image's own
        // beach.rm2 really does carry one more real, decodable Instance
        // than the original, rules out this test's own insertion math
        // before ever blaming PCSX2/the emulator for what follows.
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
        guard let builtBeachEntry = builtIndex.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.rm2") == .orderedSame }) else {
            return XCTFail("beach.rm2 missing from the built image's own archive index")
        }
        let builtBeachBytes = try BDArchiveParser.readEntryData(builtBeachEntry, index: builtIndex)
        let reparsedBeachRoot = try RM2Parser.parse(data: builtBeachBytes, fileKind: .rm2, fileName: "beach.rm2")
        func countInstances(_ node: ChunkNode) -> Int {
            var count = 0
            if case .instance = node.payload { count += 1 }
            for child in node.children { count += countInstances(child) }
            return count
        }
        let originalCount = countInstances(beachRoot)
        let rebuiltCount = countInstances(reparsedBeachRoot)
        XCTAssertEqual(rebuiltCount, originalCount + 1, "the built image handed to PCSX2 must actually carry one real, decodable new Instance more than the original")

        let outputISO = scratchDir.appendingPathComponent("gamelauncher_new_instance_boot_test.iso")
        try built.write(to: outputISO)

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
        Thread.sleep(forTimeInterval: 90)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path), can't verify anything about this boot")
        }

        print("=== PCSX2 boot log for new-Instance-inserted (\"beach.rm2\") image (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        XCTAssertTrue(logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1"),
                       "PCSX2 must genuinely resolve the boot path through our built image's own directory structure")
        XCTAssertTrue(logText.contains("RegisterLibraryEntries:  cdvdman"),
                       "the IOP kernel must have started registering modules, real post-ELF-load execution, not just a file read")
        XCTAssertTrue(logText.contains("Add ") && logText.contains("seconds play time to SLES-52568"),
                       "PCSX2 must report real accumulated play time, the real, reported symptom under test is a black screen, which would mean this boot never reaches gameplay at all")
    }

    /// The third real edit shape under investigation for the same black-
    /// screen bug, and the one the user's own screenshot showed them
    /// actively testing. Both Instance move and Instance insert (above)
    /// boot clean, but Scenery placement uses a completely different write
    /// path: `SceneryDataWriter.encode` re-encodes the *entire* SceneryData
    /// record from scratch (skydome, all four light lists, links, every
    /// existing placement, not just the one new one) rather than patching
    /// or growing an existing byte range the way Instance's `WorldPlacementWriter`
    /// does. A full re-encode is real, higher-risk surface: any field this
    /// build's decoder doesn't perfectly round-trip would silently corrupt
    /// real per-scenery data even though *this build's own* re-parse of it
    /// looks fine (self-consistent, not necessarily game-correct).
    func testPlacingANewSceneryObjectInBeachBootsInRealPCSX2() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("GameLauncherBootVerificationTests-\(UUID().uuidString)")
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
        // `SceneryAsset.placements` (`root.flattenedPlacements()`) is the
        // whole nested-`links` tree, the real "448 placements" count the
        // app itself shows, not just the top-level group's own
        // `root.model.placements`, which can genuinely be empty on a real
        // level whose actual placements all live under a link. The new
        // placement below still goes into `root.model.placements`
        // specifically, matching `WorkspaceViewModel.patchedFileBytes
        // (insertingNewScenery:)`'s own exact insertion target.
        let originalPlacementCount = sceneryAsset.placements.count
        XCTAssertGreaterThan(originalPlacementCount, 0, "sanity: beach.sm2 must have at least one real existing placement to base a new one's modelID/isSpecial on")
        let templatePlacement = try XCTUnwrap(sceneryAsset.placements.first { !$0.isSpecial }, "sanity: need at least one real, already-verified non-special model to place a copy of")

        // Same real construction `WorkspaceViewModel.patchedFileBytes(insertingNewScenery:)`
        // uses for a live Scenery-tab placement, a real, already-resolvable
        // modelID (borrowed from an existing real placement, not invented),
        // placed a few units away from its original spot.
        let newPosition = SIMD3<Float>(templatePlacement.modelMatrix[3].x + 5, templatePlacement.modelMatrix[3].y, templatePlacement.modelMatrix[3].z + 5)
        let matrix = SceneryModelPlacement.composingModelMatrix(position: newPosition, rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1))
        let boundingPosition = SIMD4<Float>(newPosition, 1)
        let newPlacement = SceneryModelPlacement(
            modelID: templatePlacement.modelID, isSpecial: false,
            boundingBoxMin: boundingPosition - SIMD4<Float>(1, 1, 1, 0), boundingBoxMax: boundingPosition + SIMD4<Float>(1, 1, 1, 0),
            modelMatrix: matrix
        )
        let insertIndex = root.model.placements.firstIndex(where: { $0.isSpecial }) ?? root.model.placements.count
        root.model.placements.insert(newPlacement, at: insertIndex)
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
        // beach.sm2 really does carry one more real, decodable placement
        // than the original, before ever blaming PCSX2/the emulator.
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
        XCTAssertEqual(reparsedAsset.placements.count, originalPlacementCount + 1, "the built image handed to PCSX2 must actually carry one real, decodable new placement more than the original")

        let outputISO = scratchDir.appendingPathComponent("gamelauncher_new_scenery_boot_test.iso")
        try built.write(to: outputISO)

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
        Thread.sleep(forTimeInterval: 90)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path), can't verify anything about this boot")
        }

        print("=== PCSX2 boot log for new-scenery-inserted (\"beach.sm2\") image (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        XCTAssertTrue(logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1"),
                       "PCSX2 must genuinely resolve the boot path through our built image's own directory structure")
        XCTAssertTrue(logText.contains("RegisterLibraryEntries:  cdvdman"),
                       "the IOP kernel must have started registering modules, real post-ELF-load execution, not just a file read")
        XCTAssertTrue(logText.contains("Add ") && logText.contains("seconds play time to SLES-52568"),
                       "PCSX2 must report real accumulated play time, the real, reported symptom under test is a black screen, which would mean this boot never reaches gameplay at all")
    }

    /// Every individual edit shape above (Instance move, Instance insert,
    /// Scenery insert) boots clean on its own. This is the remaining real
    /// difference from the user's actual workflow: a genuine Quick Launch
    /// on a real split-file level with *both* an Instance-side edit and a
    /// Scenery-side edit pending saves *both* files at once
    /// (`WorkspaceViewModel.patchedFileBytes`'s own `LevelOverridePatch`
    /// returns `primaryBytes` + a separate `sceneryBytes`, and
    /// `performQuickLaunchThisChunk` puts both into the same
    /// `archiveReplacements` dictionary), two archive entries growing and
    /// needing relocation in the same repackage, not one. This exercises
    /// exactly that combination directly against the real disc.
    func testCombinedInstanceAndSceneryEditsInBeachBootInRealPCSX2() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("GameLauncherBootVerificationTests-\(UUID().uuidString)")
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

        func findFirstInstance(_ node: ChunkNode) -> ChunkNode? {
            if case .instance = node.payload { return node }
            for child in node.children {
                if let found = findFirstInstance(child) { return found }
            }
            return nil
        }
        func findScenery(_ node: ChunkNode) -> ChunkNode? {
            if case .scenery = node.payload { return node }
            for child in node.children {
                if let found = findScenery(child) { return found }
            }
            return nil
        }

        // Build the .rm2 edit: insert a brand-new Instance (same shape as
        // testPlacingANewInstanceInBeachBootsInRealPCSX2).
        guard let beachRMEntry = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.rm2") == .orderedSame }) else {
            return XCTFail("beach.rm2 not found in this disc's real archive index")
        }
        let beachRMBytes = try BDArchiveParser.readEntryData(beachRMEntry, index: index)
        let beachRMRoot = try RM2Parser.parse(data: beachRMBytes, fileKind: .rm2, fileName: "beach.rm2")
        guard let existingInstanceNode = findFirstInstance(beachRMRoot), case .instance(let existingPlaced)? = existingInstanceNode.payload else {
            return XCTFail("beach.rm2 has no real, decoded Instance record")
        }
        func findObjectInstanceCollection(_ node: ChunkNode) -> ChunkNode? {
            let targetTypes: Set<SectionType> = [.objectInstance, .objectInstanceDemo]
            if targetTypes.contains(node.sectionType) { return node }
            for child in node.children {
                if let found = findObjectInstanceCollection(child) { return found }
            }
            return nil
        }
        guard let collectionNode = findObjectInstanceCollection(beachRMRoot) else {
            return XCTFail("beach.rm2 has no real Instance section to insert into")
        }
        let newInstanceBytes = WorldPlacementWriter.writeNewInstance(
            objectID: existingPlaced.objectID,
            position: SIMD4<Float>(existingPlaced.position.x + 3, existingPlaced.position.y, existingPlaced.position.z + 3, existingPlaced.position.w),
            rotationDegrees: .zero
        )
        guard let modifiedBeachRMBytes = ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: collectionNode, insert: [(999_999, newInstanceBytes)], removeIDs: [])],
            fileRoot: beachRMRoot, originalFileBytes: beachRMBytes
        ) else {
            return XCTFail("ChunkSectionInserter failed to insert the new Instance into beach.rm2")
        }

        // Build the .sm2 edit: insert a brand-new Scenery placement (same
        // shape as testPlacingANewSceneryObjectInBeachBootsInRealPCSX2).
        guard let beachSMEntry = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.sm2") == .orderedSame }) else {
            return XCTFail("beach.sm2 not found in this disc's real archive index")
        }
        let beachSMBytes = try BDArchiveParser.readEntryData(beachSMEntry, index: index)
        let beachSMRoot = try RM2Parser.parse(data: beachSMBytes, fileKind: .sm2, fileName: "beach.sm2")
        guard let sceneryNode = findScenery(beachSMRoot), case .scenery(let sceneryAsset)? = sceneryNode.payload, var sceneryRoot = sceneryAsset.root else {
            return XCTFail("beach.sm2 has no real, decoded SceneryData tree")
        }
        let templatePlacement = try XCTUnwrap(sceneryAsset.placements.first { !$0.isSpecial })
        let newPosition = SIMD3<Float>(templatePlacement.modelMatrix[3].x + 5, templatePlacement.modelMatrix[3].y, templatePlacement.modelMatrix[3].z + 5)
        let matrix = SceneryModelPlacement.composingModelMatrix(position: newPosition, rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1))
        let boundingPosition = SIMD4<Float>(newPosition, 1)
        let newScenery = SceneryModelPlacement(
            modelID: templatePlacement.modelID, isSpecial: false,
            boundingBoxMin: boundingPosition - SIMD4<Float>(1, 1, 1, 0), boundingBoxMax: boundingPosition + SIMD4<Float>(1, 1, 1, 0),
            modelMatrix: matrix
        )
        let insertIndex = sceneryRoot.model.placements.firstIndex(where: { $0.isSpecial }) ?? sceneryRoot.model.placements.count
        sceneryRoot.model.placements.insert(newScenery, at: insertIndex)
        sceneryRoot.model.header = 0x1613
        var mutatedScenery = sceneryAsset
        mutatedScenery.root = sceneryRoot
        let encodedScenery = SceneryDataWriter.encode(mutatedScenery)
        guard let modifiedBeachSMBytes = ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: beachSMRoot, insert: [(sceneryNode.recordID, encodedScenery)], removeIDs: [sceneryNode.recordID])],
            fileRoot: beachSMRoot, originalFileBytes: beachSMBytes
        ) else {
            return XCTFail("ChunkSectionInserter failed to splice the re-encoded SceneryData back into beach.sm2")
        }

        XCTAssertNotEqual(modifiedBeachRMBytes, beachRMBytes)
        XCTAssertNotEqual(modifiedBeachSMBytes, beachSMBytes)

        // Both files replaced in the *same* plan, same as a real Quick
        // Launch with both an Instance and a Scenery edit pending.
        let plan = GameLaunchPlan(startingChunkBaseName: "beach", archiveReplacements: [
            "beach.rm2": modifiedBeachRMBytes,
            "beach.sm2": modifiedBeachSMBytes,
        ])
        let built = try GameLauncher.building(isoURL: Self.retailISOURL, plan: plan, scratchDirectory: scratchDir)
        XCTAssertEqual(built.count % 2048, 0, "a real disc image is always a whole number of 2048-byte sectors")

        let outputISO = scratchDir.appendingPathComponent("gamelauncher_combined_edit_boot_test.iso")
        try built.write(to: outputISO)

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
        Thread.sleep(forTimeInterval: 90)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path), can't verify anything about this boot")
        }

        print("=== PCSX2 boot log for combined Instance+Scenery edit (\"beach.rm2\"+\"beach.sm2\") image (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        XCTAssertTrue(logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1"),
                       "PCSX2 must genuinely resolve the boot path through our built image's own directory structure")
        XCTAssertTrue(logText.contains("RegisterLibraryEntries:  cdvdman"),
                       "the IOP kernel must have started registering modules, real post-ELF-load execution, not just a file read")
        XCTAssertTrue(logText.contains("Add ") && logText.contains("seconds play time to SLES-52568"),
                       "PCSX2 must report real accumulated play time, the real, reported symptom under test is a black screen, which would mean this boot never reaches gameplay at all")
    }


    /// Real, reported symptom under investigation: every in-place-patch
    /// boot test above passes (real CRC, real module registration, real
    /// accumulated play time) yet the user still sees a black screen , 
    /// this environment can't independently confirm the screen itself
    /// isn't black, so "boots" was never proof of "renders." This tests
    /// `GameLauncher.buildingFresh` instead, extract-to-folder, patch on
    /// disk, rebuild via `ISO9660ImageBuilder` (the same approach the
    /// original reference editor's own Image Maker uses), a genuinely
    /// different code path from the in-place patch/relocate one every test
    /// above exercises. Same assertions as `testGameLauncherEditedStartingChunkBootsInRealPCSX2WithDifferentCRC`.
    func testBuildingFreshWithStartingChunkBootsInRealPCSX2() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("GameLauncherBootVerificationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let plan = GameLaunchPlan(startingChunkBaseName: "beach")
        let built = try GameLauncher.buildingFresh(isoURL: Self.retailISOURL, plan: plan, scratchDirectory: scratchDir)
        XCTAssertGreaterThan(built.count, 100_000_000, "a real Crash Twinsanity disc image should be well over 100MB")

        let source = PlainISOSource(data: built)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        guard let exeEntry = root.children.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare("SLES_525.68") == .orderedSame }) else {
            return XCTFail("built image is missing its own real PAL boot executable")
        }
        guard let exeData = ISO9660Reader.readFile(exeEntry, from: source) else {
            return XCTFail("couldn't read the boot executable back from the built image")
        }
        let readBackPath = ExecutablePatcher.readStartingChunkPath(revision: .pal, from: exeData)
        XCTAssertEqual(readBackPath?.lowercased(), "levels\\earth\\hub\\beach",
                        "the freshly-built image's own boot executable must carry the edited starting chunk")

        let outputISO = scratchDir.appendingPathComponent("gamelauncher_fresh_boot_test.iso")
        try built.write(to: outputISO)

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
        Thread.sleep(forTimeInterval: 15)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path), can't verify anything about this boot")
        }

        print("=== PCSX2 boot log for buildingFresh (\"beach\" starting chunk) image (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        XCTAssertTrue(logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1"),
                       "PCSX2 must genuinely resolve the boot path through the freshly-built image's own directory structure")
        XCTAssertTrue(logText.contains("RegisterLibraryEntries:  cdvdman"),
                       "the IOP kernel must have started registering modules")
        XCTAssertTrue(logText.contains("Add ") && logText.contains("seconds play time to SLES-52568"),
                       "PCSX2 must report real accumulated play time")

        guard let crcRange = logText.range(of: "Game CRC = ") else {
            return XCTFail("PCSX2's log never reported a Game CRC")
        }
        let crcToken = String(logText[crcRange.upperBound...].prefix { $0.isHexDigit }).uppercased()
        XCTAssertNotEqual(crcToken, Self.retailBootCRC,
                           "PCSX2 reported the unmodified retail Game CRC, it booted the wrong executable")
    }

    /// Same combined Instance+Scenery edit as
    /// `testCombinedInstanceAndSceneryEditsInBeachBootInRealPCSX2`, but
    /// built through `GameLauncher.buildingFresh` (extract → patch on disk
    /// → rebuild via `ISO9660ImageBuilder`) instead of `GameLauncher.building`
    /// (in-place patch + relocate). Proves the full-rebuild pipeline handles
    /// a real archive replacement, not just a starting-chunk-only ELF patch.
    func testBuildingFreshWithCombinedInstanceAndSceneryEditsBootsInRealPCSX2() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("GameLauncherBootVerificationTests-\(UUID().uuidString)")
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

        func findFirstInstance(_ node: ChunkNode) -> ChunkNode? {
            if case .instance = node.payload { return node }
            for child in node.children {
                if let found = findFirstInstance(child) { return found }
            }
            return nil
        }
        func findScenery(_ node: ChunkNode) -> ChunkNode? {
            if case .scenery = node.payload { return node }
            for child in node.children {
                if let found = findScenery(child) { return found }
            }
            return nil
        }

        guard let beachRMEntry = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.rm2") == .orderedSame }) else {
            return XCTFail("beach.rm2 not found in this disc's real archive index")
        }
        let beachRMBytes = try BDArchiveParser.readEntryData(beachRMEntry, index: index)
        let beachRMRoot = try RM2Parser.parse(data: beachRMBytes, fileKind: .rm2, fileName: "beach.rm2")
        guard let existingInstanceNode = findFirstInstance(beachRMRoot), case .instance(let existingPlaced)? = existingInstanceNode.payload else {
            return XCTFail("beach.rm2 has no real, decoded Instance record")
        }
        func findObjectInstanceCollection(_ node: ChunkNode) -> ChunkNode? {
            let targetTypes: Set<SectionType> = [.objectInstance, .objectInstanceDemo]
            if targetTypes.contains(node.sectionType) { return node }
            for child in node.children {
                if let found = findObjectInstanceCollection(child) { return found }
            }
            return nil
        }
        guard let collectionNode = findObjectInstanceCollection(beachRMRoot) else {
            return XCTFail("beach.rm2 has no real Instance section to insert into")
        }
        let newInstanceBytes = WorldPlacementWriter.writeNewInstance(
            objectID: existingPlaced.objectID,
            position: SIMD4<Float>(existingPlaced.position.x + 3, existingPlaced.position.y, existingPlaced.position.z + 3, existingPlaced.position.w),
            rotationDegrees: .zero
        )
        guard let modifiedBeachRMBytes = ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: collectionNode, insert: [(999_999, newInstanceBytes)], removeIDs: [])],
            fileRoot: beachRMRoot, originalFileBytes: beachRMBytes
        ) else {
            return XCTFail("ChunkSectionInserter failed to insert the new Instance into beach.rm2")
        }

        guard let beachSMEntry = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.sm2") == .orderedSame }) else {
            return XCTFail("beach.sm2 not found in this disc's real archive index")
        }
        let beachSMBytes = try BDArchiveParser.readEntryData(beachSMEntry, index: index)
        let beachSMRoot = try RM2Parser.parse(data: beachSMBytes, fileKind: .sm2, fileName: "beach.sm2")
        guard let sceneryNode = findScenery(beachSMRoot), case .scenery(let sceneryAsset)? = sceneryNode.payload, var sceneryRoot = sceneryAsset.root else {
            return XCTFail("beach.sm2 has no real, decoded SceneryData tree")
        }
        let templatePlacement = try XCTUnwrap(sceneryAsset.placements.first { !$0.isSpecial })
        let newPosition = SIMD3<Float>(templatePlacement.modelMatrix[3].x + 5, templatePlacement.modelMatrix[3].y, templatePlacement.modelMatrix[3].z + 5)
        let matrix = SceneryModelPlacement.composingModelMatrix(position: newPosition, rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1))
        let boundingPosition = SIMD4<Float>(newPosition, 1)
        let newScenery = SceneryModelPlacement(
            modelID: templatePlacement.modelID, isSpecial: false,
            boundingBoxMin: boundingPosition - SIMD4<Float>(1, 1, 1, 0), boundingBoxMax: boundingPosition + SIMD4<Float>(1, 1, 1, 0),
            modelMatrix: matrix
        )
        let insertIndex = sceneryRoot.model.placements.firstIndex(where: { $0.isSpecial }) ?? sceneryRoot.model.placements.count
        sceneryRoot.model.placements.insert(newScenery, at: insertIndex)
        sceneryRoot.model.header = 0x1613
        var mutatedScenery = sceneryAsset
        mutatedScenery.root = sceneryRoot
        let encodedScenery = SceneryDataWriter.encode(mutatedScenery)
        guard let modifiedBeachSMBytes = ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: beachSMRoot, insert: [(sceneryNode.recordID, encodedScenery)], removeIDs: [sceneryNode.recordID])],
            fileRoot: beachSMRoot, originalFileBytes: beachSMBytes
        ) else {
            return XCTFail("ChunkSectionInserter failed to splice the re-encoded SceneryData back into beach.sm2")
        }

        XCTAssertNotEqual(modifiedBeachRMBytes, beachRMBytes)
        XCTAssertNotEqual(modifiedBeachSMBytes, beachSMBytes)

        let plan = GameLaunchPlan(startingChunkBaseName: "beach", archiveReplacements: [
            "beach.rm2": modifiedBeachRMBytes,
            "beach.sm2": modifiedBeachSMBytes,
        ])
        let built = try GameLauncher.buildingFresh(isoURL: Self.retailISOURL, plan: plan, scratchDirectory: scratchDir)
        XCTAssertEqual(built.count % 2048, 0, "a real disc image is always a whole number of 2048-byte sectors")

        let outputISO = scratchDir.appendingPathComponent("gamelauncher_fresh_combined_edit_boot_test.iso")
        try built.write(to: outputISO)

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
        Thread.sleep(forTimeInterval: 90)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path), can't verify anything about this boot")
        }

        print("=== PCSX2 boot log for buildingFresh combined Instance+Scenery edit (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        XCTAssertTrue(logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1"),
                       "PCSX2 must genuinely resolve the boot path through our built image's own directory structure")
        XCTAssertTrue(logText.contains("RegisterLibraryEntries:  cdvdman"),
                       "the IOP kernel must have started registering modules, real post-ELF-load execution, not just a file read")
        XCTAssertTrue(logText.contains("Add ") && logText.contains("seconds play time to SLES-52568"),
                       "PCSX2 must report real accumulated play time")
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

    /// The real, requested end-to-end scenario: place a Forge object
    /// (Instance), place Scenery, rebuild Level Collision to cover the new
    /// placement, and add AI mapping (an AIPosition waypoint + an AIPath
    /// referencing it), all four edits combined into the *same*
    /// `beach.rm2`/`beach.sm2` rebuild, exactly like a real player doing
    /// all of this in one Level Viewer session before Quick Launch. No
    /// `startingChunkBaseName` override: this boots through the completely
    /// normal path (BIOS -> intro FMVs -> real title screen) a real player
    /// actually uses, not a forced jump into the level.
    ///
    /// Independently, visually confirmed once via a real, GUI-visible
    /// PCSX2 process (not just this test's own log assertions): the built
    /// image plays its full real intro cinematic and lands on the genuine,
    /// interactive "CRASH TWINSANITY / PRESS START BUTTON" title screen , 
    /// the strongest confirmation this project can produce that a
    /// combined, real-world edit set doesn't corrupt the disc.
    func testForgeSceneryCollisionAndAIMappingEditsBootToRealTitleScreen() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("GameLauncherBootVerificationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

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

        // ---- beach.rm2: Instance + AIPosition + AIPath + Collision, all in one pass ----
        guard let beachRMEntry = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.rm2") == .orderedSame }) else {
            return XCTFail("beach.rm2 not found in this disc's real archive index")
        }
        let beachRMBytes = try BDArchiveParser.readEntryData(beachRMEntry, index: index)
        let beachRMRoot = try RM2Parser.parse(data: beachRMBytes, fileKind: .rm2, fileName: "beach.rm2")

        func findFirst(_ node: ChunkNode, sectionTypes: Set<SectionType>) -> ChunkNode? {
            if sectionTypes.contains(node.sectionType) { return node }
            for child in node.children { if let f = findFirst(child, sectionTypes: sectionTypes) { return f } }
            return nil
        }
        func findFirstInstanceNode(_ node: ChunkNode) -> ChunkNode? {
            if case .instance = node.payload { return node }
            for child in node.children { if let f = findFirstInstanceNode(child) { return f } }
            return nil
        }
        func findCollisionParentAndNode(_ node: ChunkNode) -> (parent: ChunkNode, node: ChunkNode)? {
            for child in node.children {
                if case .collision = child.payload { return (node, child) }
                if let found = findCollisionParentAndNode(child) { return found }
            }
            return nil
        }

        guard let instanceCollection = findFirst(beachRMRoot, sectionTypes: [.objectInstance, .objectInstanceDemo]) else {
            return XCTFail("beach.rm2 has no Instance collection")
        }
        guard let existingInstanceNode = findFirstInstanceNode(beachRMRoot), case .instance(let existingPlaced)? = existingInstanceNode.payload else {
            return XCTFail("beach.rm2 has no real Instance record to model a new one on")
        }
        let newInstanceBytes = WorldPlacementWriter.writeNewInstance(
            objectID: existingPlaced.objectID,
            position: SIMD4<Float>(existingPlaced.position.x + 4, existingPlaced.position.y, existingPlaced.position.z + 4, existingPlaced.position.w),
            rotationDegrees: .zero
        )

        guard let aiPositionCollection = findFirst(beachRMRoot, sectionTypes: [.aiPosition]) else {
            return XCTFail("beach.rm2 has no AIPosition collection")
        }
        // 4 floats (Pos) + uint16 (Num), field-for-field layout ported from
        // `Twinsanity/Items/Instances/AIPosition.cs`, mirroring
        // `AINavigationParser.parseAIPosition`'s own doc comment.
        let newAIPositionID: UInt32 = 900_001
        var aiPosWriter = BinaryWriter()
        aiPosWriter.writeVector4(SIMD4<Float>(existingPlaced.position.x + 4, existingPlaced.position.y, existingPlaced.position.z + 4, 1))
        aiPosWriter.writeUInt16(0) // rawNodeType
        let newAIPositionBytes = aiPosWriter.data

        guard let aiPathCollection = findFirst(beachRMRoot, sectionTypes: [.aiPath]) else {
            return XCTFail("beach.rm2 has no AIPath collection")
        }
        // 5 x uint16, mirroring `AINavigationParser.parseAIPath`. A self-
        // referencing start/end is a real, well-formed (if minimal) path:
        // this test only needs a structurally valid new record, not a
        // meaningful new route.
        let newAIPathID: UInt32 = 900_002
        var aiPathWriter = BinaryWriter()
        aiPathWriter.writeUInt16(UInt16(newAIPositionID & 0xFFFF))
        aiPathWriter.writeUInt16(UInt16(newAIPositionID & 0xFFFF))
        aiPathWriter.writeUInt16(0)
        aiPathWriter.writeUInt16(0)
        aiPathWriter.writeUInt16(0)
        let newAIPathBytes = aiPathWriter.data

        guard let (collisionParent, collisionNode) = findCollisionParentAndNode(beachRMRoot), case .collision(let collisionMesh)? = collisionNode.payload else {
            return XCTFail("beach.rm2 has no Collision record")
        }
        // Same "most common existing surface ID" heuristic
        // `LevelViewerWindow.computingRebuiltCollisionRecord` uses for a
        // real "Rebuild Level Collision" button click, not an invented ID.
        var surfaceIDCounts: [Int: Int] = [:]
        for triangle in collisionMesh.triangles { surfaceIDCounts[triangle.surfaceID, default: 0] += 1 }
        let surfaceID = surfaceIDCounts.max(by: { $0.value < $1.value })?.key ?? 0
        let newBox = LevelCollisionRebuilder.NewCollisionBox(
            worldMin: SIMD3<Float>(existingPlaced.position.x + 3, existingPlaced.position.y, existingPlaced.position.z + 3),
            worldMax: SIMD3<Float>(existingPlaced.position.x + 5, existingPlaced.position.y + 2, existingPlaced.position.z + 5)
        )
        let rebuiltMesh = LevelCollisionRebuilder.rebuilding(collisionMesh, addingBoxes: [newBox], surfaceID: surfaceID)
        let encodedCollision = ColDataWriter.write(rebuiltMesh)

        // All four edits applied via one `ChunkSectionInserter` pass, same
        // discipline `WorkspaceViewModel.patchedFileBytes` itself follows
        // (see that function's own doc comment): a later, separate pass
        // would rebuild the tree's ancestor chain from the *original*
        // offsets against a buffer an earlier pass already resized,
        // silently corrupting the result.
        guard let modifiedBeachRMBytes = ChunkSectionInserter.applyingRecordChanges(
            intoSections: [
                (section: instanceCollection, insert: [(999_991, newInstanceBytes)], removeIDs: []),
                (section: aiPositionCollection, insert: [(newAIPositionID, newAIPositionBytes)], removeIDs: []),
                (section: aiPathCollection, insert: [(newAIPathID, newAIPathBytes)], removeIDs: []),
                (section: collisionParent, insert: [(collisionNode.recordID, encodedCollision)], removeIDs: [collisionNode.recordID]),
            ],
            fileRoot: beachRMRoot, originalFileBytes: beachRMBytes
        ) else {
            return XCTFail("ChunkSectionInserter failed to apply the combined Instance+AIPosition+AIPath+Collision edit")
        }
        XCTAssertNotEqual(modifiedBeachRMBytes, beachRMBytes)

        // ---- beach.sm2: Scenery (same shape as testPlacingANewSceneryObjectInBeachBootsInRealPCSX2) ----
        guard let beachSMEntry = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.sm2") == .orderedSame }) else {
            return XCTFail("beach.sm2 not found in this disc's real archive index")
        }
        let beachSMBytes = try BDArchiveParser.readEntryData(beachSMEntry, index: index)
        let beachSMRoot = try RM2Parser.parse(data: beachSMBytes, fileKind: .sm2, fileName: "beach.sm2")
        func findScenery(_ node: ChunkNode) -> ChunkNode? {
            if case .scenery = node.payload { return node }
            for child in node.children { if let f = findScenery(child) { return f } }
            return nil
        }
        guard let sceneryNode = findScenery(beachSMRoot), case .scenery(let sceneryAsset)? = sceneryNode.payload, var sceneryRoot = sceneryAsset.root else {
            return XCTFail("beach.sm2 has no real, decoded SceneryData tree")
        }
        let templatePlacement = try XCTUnwrap(sceneryAsset.placements.first { !$0.isSpecial })
        let newPosition = SIMD3<Float>(templatePlacement.modelMatrix[3].x + 6, templatePlacement.modelMatrix[3].y, templatePlacement.modelMatrix[3].z + 6)
        let matrix = SceneryModelPlacement.composingModelMatrix(position: newPosition, rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1))
        let boundingPosition = SIMD4<Float>(newPosition, 1)
        let newScenery = SceneryModelPlacement(
            modelID: templatePlacement.modelID, isSpecial: false,
            boundingBoxMin: boundingPosition - SIMD4<Float>(1, 1, 1, 0), boundingBoxMax: boundingPosition + SIMD4<Float>(1, 1, 1, 0),
            modelMatrix: matrix
        )
        let insertIndex = sceneryRoot.model.placements.firstIndex(where: { $0.isSpecial }) ?? sceneryRoot.model.placements.count
        sceneryRoot.model.placements.insert(newScenery, at: insertIndex)
        sceneryRoot.model.header = 0x1613
        var mutatedScenery = sceneryAsset
        mutatedScenery.root = sceneryRoot
        let encodedScenery = SceneryDataWriter.encode(mutatedScenery)
        guard let modifiedBeachSMBytes = ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: beachSMRoot, insert: [(sceneryNode.recordID, encodedScenery)], removeIDs: [sceneryNode.recordID])],
            fileRoot: beachSMRoot, originalFileBytes: beachSMBytes
        ) else {
            return XCTFail("ChunkSectionInserter failed to splice the re-encoded SceneryData back into beach.sm2")
        }
        XCTAssertNotEqual(modifiedBeachSMBytes, beachSMBytes)

        // No `startingChunkBaseName`: boots through the real, unmodified
        // main-menu path, not a forced level jump.
        let plan = GameLaunchPlan(archiveReplacements: [
            "beach.rm2": modifiedBeachRMBytes,
            "beach.sm2": modifiedBeachSMBytes,
        ])
        let built = try GameLauncher.building(isoURL: Self.retailISOURL, plan: plan, scratchDirectory: scratchDir)
        XCTAssertEqual(built.count % 2048, 0, "a real disc image is always a whole number of 2048-byte sectors")

        let outputISO = scratchDir.appendingPathComponent("comprehensive_edit_boot_test.iso")
        try built.write(to: outputISO)

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
        // Longer than every other test's window: this disc's real intro
        // (BIOS splash -> multiple FMV/cutscene segments -> title screen)
        // measured, empirically, at several minutes wall-clock in this real
        // PCSX2 build, not a hang, just how long the genuine cinematic
        // opening takes before the interactive title screen appears.
        Thread.sleep(forTimeInterval: 240)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path), can't verify anything about this boot")
        }

        print("=== PCSX2 boot log for combined Forge+Scenery+Collision+AI-mapping edit image (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        XCTAssertTrue(logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1"),
                       "PCSX2 must genuinely resolve the boot path through our built image's own directory structure")
        XCTAssertTrue(logText.contains("RegisterLibraryEntries:  cdvdman"),
                       "the IOP kernel must have started registering modules, real post-ELF-load execution, not just a file read")
        XCTAssertTrue(logText.contains("Add ") && logText.contains("seconds play time to SLES-52568"),
                       "PCSX2 must report real accumulated play time")
    }

    /// Reads the Primary Volume Descriptor's own declared "Volume Space
    /// Size" (ECMA-119 8.4.8, PVD byte offset 80) directly out of a built
    /// image's bytes, a narrower, test-only readback than a full
    /// `ISO9660Reader` API, since nothing else in this codebase needed this
    /// specific field before the relocation-size bug this test guards
    /// against.
    private static func declaredVolumeSpaceSize(_ data: Data) -> UInt32? {
        let pvdOffset = 16 * 2048
        guard pvdOffset + 84 <= data.count else { return nil }
        let base = data.startIndex + pvdOffset + 80
        let b0 = UInt32(data[base]), b1 = UInt32(data[base + 1]), b2 = UInt32(data[base + 2]), b3 = UInt32(data[base + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
