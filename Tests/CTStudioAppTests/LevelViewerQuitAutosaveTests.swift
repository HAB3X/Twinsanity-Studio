import XCTest
import CTExport
import CTParsers
@testable import CTStudioApp

/// Covers the pure/testable pieces behind the quit-time "you have unsaved
/// Level Viewer changes" prompt (`CTStudioApp.AppDelegate.applicationShouldTerminate`)
///, deliberately does *not* attempt to drive the real `NSApplication`
/// termination flow itself (that needs a live app/window lifecycle this
/// test target doesn't have); instead it pins the two things that flow
/// actually depends on: "does this count as dirty" (`LevelViewerDirtyCheck`)
/// and "does patching + independently re-verifying an archive replacement
/// actually work" (`LevelViewerDiscAutosave`).
final class LevelViewerQuitAutosaveTests: XCTestCase {
    // MARK: - LevelViewerDirtyCheck (pure, no renderer/window needed)

    func testNotDirtyWhenEveryCountIsZero() {
        XCTAssertFalse(LevelViewerDirtyCheck.isDirty(
            levelOverrideCount: 0, aiWaypointOverrideCount: 0, aiPathArgOverrideCount: 0, cameraControlPointOverrideCount: 0,
            newInstanceCount: 0, newAIPositionCount: 0, newTriggerCount: 0, newCameraCount: 0, newAIPathCount: 0,
            removedInstanceCount: 0, removedTriggerCount: 0, removedCameraCount: 0, removedAIPositionCount: 0, removedAIPathCount: 0
        ))
    }

    /// Each of the 14 counts `computingPendingOverridePatch()`'s own guard
    /// checks should independently be enough to flip this dirty, a
    /// regression here (e.g. a copy-paste that dropped one term from the
    /// `||` chain) would silently stop warning about that one specific kind
    /// of edit at quit time.
    func testEachIndividualCountAloneMakesItDirty() {
        struct Case { let name: String; let apply: (inout [String: Int]) -> Void }
        let keys = [
            "levelOverrideCount", "aiWaypointOverrideCount", "aiPathArgOverrideCount", "cameraControlPointOverrideCount",
            "newInstanceCount", "newAIPositionCount", "newTriggerCount", "newCameraCount", "newAIPathCount",
            "removedInstanceCount", "removedTriggerCount", "removedCameraCount", "removedAIPositionCount", "removedAIPathCount",
        ]
        for keyToSet in keys {
            var counts = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
            counts[keyToSet] = 1
            let isDirty = LevelViewerDirtyCheck.isDirty(
                levelOverrideCount: counts["levelOverrideCount"]!,
                aiWaypointOverrideCount: counts["aiWaypointOverrideCount"]!,
                aiPathArgOverrideCount: counts["aiPathArgOverrideCount"]!,
                cameraControlPointOverrideCount: counts["cameraControlPointOverrideCount"]!,
                newInstanceCount: counts["newInstanceCount"]!,
                newAIPositionCount: counts["newAIPositionCount"]!,
                newTriggerCount: counts["newTriggerCount"]!,
                newCameraCount: counts["newCameraCount"]!,
                newAIPathCount: counts["newAIPathCount"]!,
                removedInstanceCount: counts["removedInstanceCount"]!,
                removedTriggerCount: counts["removedTriggerCount"]!,
                removedCameraCount: counts["removedCameraCount"]!,
                removedAIPositionCount: counts["removedAIPositionCount"]!,
                removedAIPathCount: counts["removedAIPathCount"]!
            )
            XCTAssertTrue(isDirty, "setting only \(keyToSet) to 1 should already count as dirty")
        }
    }

    // MARK: - pendingLevelViewerPatchSnapshot (real, reported bug: closing the window before quitting silently lost edits)

    /// Regression test for a real, reported bug: `LevelViewerWindow`'s
    /// `renderer` is a plain `@State`, so it deallocates the instant that
    /// window closes, `currentLevelViewerDirtyProvider`/
    /// `currentLevelViewerPendingPatchProvider` only capture it *weakly*,
    /// so closing the window before quitting used to silently drop pending
    /// edits with zero warning: `hasPendingLevelViewerEdits` just went back
    /// to `false` and the quit-time prompt never fired. This exercises
    /// exactly `LevelViewerWindow.onDisappear`'s own fix, ask the live
    /// provider one last time and stash the result, without needing a real
    /// window/renderer.
    @MainActor
    func testPendingEditsSurviveTheLevelViewerWindowClosingBeforeQuitting() {
        let workspace = WorkspaceViewModel()
        let patch = LevelViewerPendingPatch(archiveEntryDisplayName: "beach.rm2", patchedBytes: Data("edit".utf8), summary: "1 transform override(s)")

        // A Level Viewer window is open with one real pending edit.
        workspace.currentLevelViewerDirtyProvider = { true }
        workspace.currentLevelViewerPendingPatchProvider = { patch }
        XCTAssertTrue(workspace.hasPendingLevelViewerEdits)

        // Simulates `LevelViewerWindow.onDisappear`'s own exact sequence:
        // ask the live provider one last time, stash it, then clear both.
        if let materialized = workspace.currentLevelViewerPendingPatchProvider?() {
            workspace.pendingLevelViewerPatchSnapshot = materialized
        }
        workspace.currentLevelViewerDirtyProvider = nil
        workspace.currentLevelViewerPendingPatchProvider = nil

        XCTAssertTrue(workspace.hasPendingLevelViewerEdits, "closing the window must not silently make the pending edit invisible to the quit-time prompt")
        XCTAssertEqual(workspace.pendingLevelViewerPatchSnapshot?.archiveEntryDisplayName, "beach.rm2")
    }

    /// A freshly-opened Level Viewer session's own live answer, even a
    /// genuine "nothing pending", must win over a stale snapshot left
    /// behind by a previously-closed, still-unsaved session. Without this
    /// precedence, opening and closing a second, untouched level would
    /// falsely resurrect the first session's already-stashed edit twice.
    @MainActor
    func testALiveOpenWindowWithNoEditsIsNotMaskedByAStaleSnapshotFromAPreviouslyClosedSession() {
        let workspace = WorkspaceViewModel()
        workspace.pendingLevelViewerPatchSnapshot = LevelViewerPendingPatch(
            archiveEntryDisplayName: "beach.rm2", patchedBytes: Data("stale".utf8), summary: "1 transform override(s)"
        )

        // A second, different Level Viewer session is now open, genuinely
        // clean, its live provider is registered and honestly says "no".
        workspace.currentLevelViewerDirtyProvider = { false }

        XCTAssertFalse(workspace.hasPendingLevelViewerEdits, "an open window's own honest answer must take precedence over a stale snapshot from a different, already-closed session")
    }

    // MARK: - LevelViewerDiscAutosave (real disc, XCTSkip if absent)

    /// Same real retail disc image `GameLauncherTests` (CTExportTests)
    /// already uses, this session's one established real-disc fixture for
    /// exercising the actual `.iso`-level archive-replacement pipeline, not
    /// a synthetic one, since the quit-time save always targets a real
    /// mounted `.iso`.
    private static let isoURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/Crash Twinsanity (USA) (v1.00).iso")

    private var scratchDir: URL!

    override func setUpWithError() throws {
        scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("LevelViewerQuitAutosaveTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratchDir)
    }

    private func skipIfMissing() throws {
        guard FileManager.default.fileExists(atPath: Self.isoURL.path) else {
            throw XCTSkip("Real retail ISO not present at \(Self.isoURL.path) on this machine.")
        }
    }

    /// Pins the real thing the quit-time save actually does: build a
    /// `LevelViewerPendingPatch` for one real archive entry, hand it to
    /// `LevelViewerDiscAutosave.rebuildingAndVerifying`, and confirm the
    /// result is a genuinely different, independently-verified image with
    /// the patched entry actually swapped in, mirroring
    /// `GameLauncherTests.testBuildingWithArchiveReplacementActuallyPatchesTheArchivedEntry`,
    /// just through this new, thinner entry point instead of calling
    /// `GameLauncher` directly. Deliberately never writes the result over
    /// `Self.isoURL` itself, writing back over the real mounted disc image
    /// is `WorkspaceViewModel.savingPendingLevelViewerEditsToMountedDisc`'s
    /// job, not this pure function's, and this test must never touch the
    /// real retail image on disk.
    func testRebuildingAndVerifyingPatchesTheRequestedArchiveEntryAndVerifiesCleanly() throws {
        try skipIfMissing()
        let markerBytes = Data("LEVELVIEWERQUITSAVE".utf8)
        let patch = LevelViewerPendingPatch(archiveEntryDisplayName: "cavent.rm2", patchedBytes: markerBytes, summary: "1 transform override(s)")

        let result = try LevelViewerDiscAutosave.rebuildingAndVerifying(patch: patch, isoURL: Self.isoURL, scratchDirectory: scratchDir)

        XCTAssertFalse(result.data.isEmpty)
        XCTAssertEqual(result.data.count % 2048, 0, "a real disc image is always a whole number of 2048-byte sectors")
        XCTAssertFalse(result.diagnostics.isEmpty, "the same real re-verification GameLauncher.rebuildingAndVerifying always performs")
        XCTAssertTrue(result.diagnostics.contains { $0.contains("1 requested replacement") }, "expected confirmation the one requested replacement was found in the rebuilt archive, got: \(result.diagnostics)")

        let originalData = try Data(contentsOf: Self.isoURL, options: .mappedIfSafe)
        XCTAssertNotEqual(result.data, originalData, "the rebuilt image must actually differ from the untouched original")

        // Independently re-read the patched entry back out, the same way a
        // genuine consumer (or the quit-time save's own trust in this
        // result) would.
        let source = PlainISOSource(data: result.data)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        let (bhEntry, bdEntry) = try Self.locateArchivePair(in: root)
        guard let bhData = ISO9660Reader.readFile(bhEntry, from: source), let bdData = ISO9660Reader.readFile(bdEntry, from: source) else {
            return XCTFail("Couldn't re-read the archive pair from the rebuilt image.")
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
        XCTAssertEqual(try BDArchiveParser.readEntryData(match, index: index), markerBytes)
    }

    /// Real, reported bug: "Update Collision for Moved Objects" (and
    /// regular "Save In-Place") silently failed, always, on every
    /// archive-browsed level (`ChunkNode.displayName` is a *full* archive
    /// path like "Levels/Earth/Hub/beach.rm2" there, not the bare filename
    /// `archiveEntryDisplayName`'s own doc comment claims), because this
    /// full path never got normalized before being used as a
    /// `GameLaunchPlan.archiveReplacements` key, and `GameLauncher.building`
    /// only ever matches bare names. The user-visible symptom was
    /// `.verificationFailed` surfacing `GameLauncherError.levelNotFoundInArchive`
    /// with that same full path in its message. Pinned here with a full,
    /// slash-qualified path as input (unlike every other test in this file,
    /// which already uses a bare name and so could never have caught this).
    func testRebuildingAndVerifyingNormalizesAFullArchivePathDisplayName() throws {
        try skipIfMissing()
        let markerBytes = Data("LEVELVIEWERQUITSAVE_FULLPATH".utf8)
        let patch = LevelViewerPendingPatch(archiveEntryDisplayName: "Levels/Earth/Cavern/cavent.rm2", patchedBytes: markerBytes, summary: "1 transform override(s)")

        let result = try LevelViewerDiscAutosave.rebuildingAndVerifying(patch: patch, isoURL: Self.isoURL, scratchDirectory: scratchDir)

        XCTAssertTrue(result.diagnostics.contains { $0.contains("1 requested replacement") }, "expected the full-path display name to still resolve to a real archive entry, got: \(result.diagnostics)")

        let source = PlainISOSource(data: result.data)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        let (bhEntry, bdEntry) = try Self.locateArchivePair(in: root)
        guard let bhData = ISO9660Reader.readFile(bhEntry, from: source), let bdData = ISO9660Reader.readFile(bdEntry, from: source) else {
            return XCTFail("Couldn't re-read the archive pair from the rebuilt image.")
        }
        let extractDir = scratchDir.appendingPathComponent("readback-fullpath")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let bhURL = extractDir.appendingPathComponent((bhEntry.name as NSString).lastPathComponent)
        let bdURL = extractDir.appendingPathComponent((bdEntry.name as NSString).lastPathComponent)
        try bhData.write(to: bhURL)
        try bdData.write(to: bdURL)
        let index = try BDArchiveParser.readIndex(bhURL: bhURL)
        guard let match = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("cavent.rm2") == .orderedSame }) else {
            return XCTFail("cavent.rm2 not found in the repackaged archive.")
        }
        XCTAssertEqual(try BDArchiveParser.readEntryData(match, index: index), markerBytes)
    }

    /// An entry name that doesn't exist anywhere in the disc's real archive
    /// should throw, not silently no-op, the same real failure
    /// `GameLauncher.rebuildingAndVerifying` already surfaces, which the
    /// quit-time save turns into `.verificationFailed` rather than ever
    /// writing anything back.
    func testRebuildingAndVerifyingWithUnknownEntryNameThrows() throws {
        try skipIfMissing()
        let patch = LevelViewerPendingPatch(archiveEntryDisplayName: "this_level_does_not_exist.rm2", patchedBytes: Data("x".utf8), summary: "1 transform override(s)")
        XCTAssertThrowsError(try LevelViewerDiscAutosave.rebuildingAndVerifying(patch: patch, isoURL: Self.isoURL, scratchDirectory: scratchDir))
    }

    // MARK: - Helper mirroring GameLauncher's own archive-pair lookup, for read-back verification only

    private static func locateArchivePair(in root: ISO9660Entry) throws -> (bh: ISO9660Entry, bd: ISO9660Entry) {
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
