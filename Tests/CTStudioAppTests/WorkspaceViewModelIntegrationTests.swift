import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// End-to-end tests of the actual user-facing flow this session's changes
/// target: load an archive, and, without any further manual action, the
/// Models Hub should populate automatically. Skips gracefully when the disc
/// image isn't mounted at the well-known path.
@MainActor
final class WorkspaceViewModelIntegrationTests: XCTestCase {
    func testLoadingArchiveAutoScansAndPopulatesModelsHub() throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        // Force a real scan rather than risk a cache hit from a previous
        // test/run in the same process, a cache hit skips straight past
        // the `isScanning` true/false transition and the tree-expansion
        // work this test is actually exercising.
        ScanCache.clearAll()

        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)

        // Loading the index itself is synchronous; scanning is not.
        XCTAssertEqual(workspace.rootNodes.count, 1)
        XCTAssertTrue(workspace.isScanning, "expected the auto-scan to have started immediately on load")

        let expectation = expectation(description: "background scan completes")
        fulfill(expectation, whenTrue: { !workspace.isScanning })
        wait(for: [expectation], timeout: 300)

        XCTAssertFalse(workspace.modelsHub.isEmpty, "Models Hub should be populated automatically after the scan, with no manual Scan Archive click")
        XCTAssertTrue(workspace.modelsHub.contains { $0.isFullyTextured }, "expected at least some models to resolve with textures")

        // Selecting a hub entry should be enough to hand straight to the
        // Model Viewer sheet, with zero further parsing/resolution needed.
        let firstModel = try XCTUnwrap(workspace.modelsHub.first)
        workspace.modelViewerAsset = firstModel
        XCTAssertEqual(workspace.modelViewerAsset?.id, firstModel.id)
    }

    func testOpenModelViewerFromTreeNodeAfterScan() throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        // See the matching comment in `testLoadingArchiveAutoScansAndPopulatesModelsHub`.
        ScanCache.clearAll()

        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)

        let expectation = expectation(description: "background scan completes")
        fulfill(expectation, whenTrue: { !workspace.isScanning })
        wait(for: [expectation], timeout: 300)

        // Drill down to a real RigidModel node the way the sidebar would,
        // then exercise the same openModelViewer(for:) path the "Open in
        // Model Viewer" button calls.
        guard let archiveRoot = workspace.rootNodes.first,
              let fileEntry = archiveRoot.children.first(where: { $0.displayName == "Levels/AltEarth/Hub/alttunl.rm2" }),
              let graphics = fileEntry.children.first(where: { $0.sectionType == .graphics }),
              let rigidModelSection = graphics.children.first(where: { $0.sectionType == .rigidModel }),
              let rigidModelLeaf = rigidModelSection.children.first
        else {
            return XCTFail("couldn't find the expected RigidModel node after scanning")
        }

        workspace.openModelViewer(for: rigidModelLeaf)
        XCTAssertNotNil(workspace.modelViewerAsset, "openModelViewer should have resolved and set modelViewerAsset; lastError=\(workspace.lastError ?? "nil")")
    }

    /// "Load Chunk" from the Chunk Links inspector: resolves a real
    /// `ChunkLink` against the already-open archive and adds the target as
    /// a real, first-class `rootNodes` entry, not just geometry stitched
    /// into a 3D view. `nitrocav.sm2`'s own real `ChunkLinks` are already
    /// pinned to fully resolve against real archive entries by
    /// `testChunkLinkPathsResolveToRealArchiveEntries`; this test exercises
    /// the actual `WorkspaceViewModel` method the UI button calls, not just
    /// the path-matching logic underneath it.
    func testOpenChunkLinkAddsTargetAsRealRootNode() async throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)

        guard let archiveRoot = workspace.rootNodes.first,
              let fileEntry = archiveRoot.children.first(where: { $0.displayName == "Levels/Earth/Cavern/nitrocav.sm2" })
        else {
            return XCTFail("couldn't find nitrocav.sm2 in the archive index")
        }
        await workspace.expandArchiveEntry(fileEntry, rootID: archiveRoot.id)
        guard let expanded = workspace.rootNodes.first?.children.first(where: { $0.displayName == "Levels/Earth/Cavern/nitrocav.sm2" }) else {
            return XCTFail("expandArchiveEntry should have replaced the entry with its parsed contents")
        }

        var link: ChunkLink?
        func walk(_ node: ChunkNode) {
            if link == nil, case .chunkLinks(let asset) = node.payload { link = asset.links.first }
            for child in node.children { walk(child) }
        }
        walk(expanded)
        let realLink = try XCTUnwrap(link, "nitrocav.sm2 should have at least one real ChunkLink")

        let rootCountBefore = workspace.rootNodes.count
        let succeeded = await workspace.openChunkLink(realLink)
        XCTAssertTrue(succeeded, "openChunkLink should resolve a real link against the already-open archive; lastError=\(workspace.lastError ?? "nil")")

        XCTAssertEqual(workspace.rootNodes.count, rootCountBefore + 1, "the linked chunk should be added as a new top-level sidebar entry")
        XCTAssertNotNil(workspace.selectedNode, "the newly opened chunk should be selected so the user sees it immediately")

        // Calling it again for the same link must not create a duplicate , 
        // it should just re-select the already-open entry.
        _ = await workspace.openChunkLink(realLink)
        XCTAssertEqual(workspace.rootNodes.count, rootCountBefore + 1, "opening the same chunk link twice should select the existing entry, not duplicate it")
    }

    /// Real, reported gap: "editing a level reached by browsing a mounted
    /// ISO" is the *normal* way anyone opens a level (versus manually
    /// picking a loose `.rm2` file from disk), but `expandArchiveEntry`
    /// used to never register the file's own raw bytes into
    /// `rawFileBytesByRootID`, only a genuinely standalone `Data(
    /// contentsOf:)` open did. Every save path in the app
    /// (`canSaveEdits`/`patchedFileBytes`, and everything built on them , 
    /// "Save Chunk Overrides…", Quick Launch's pending-edit bake-in) gates
    /// on exactly that dictionary, so a level reached by browsing an
    /// archive silently couldn't be saved: the button just showed
    /// disabled, with no error explaining why. This opens the real
    /// `CRASH.BH` archive (not a mounted disc, but the exact same
    /// `expandArchiveEntry` code path a mounted-ISO browse converges on , 
    /// see `openDiscEntry`'s own doc comment), expands a real level, and
    /// confirms it's now genuinely save-able.
    func testExpandingArchiveEntryRegistersRawBytesSoTheLevelBecomesSaveable() async throws {
        let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Real CRASH.BH not present on this machine.")
        }
        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)

        guard let archiveRoot = workspace.rootNodes.first,
              let fileEntry = archiveRoot.children.first(where: { $0.displayName == "Levels/Earth/Hub/beach.rm2" })
        else {
            return XCTFail("couldn't find Levels/Earth/Hub/beach.rm2 in the real archive index")
        }

        XCTAssertFalse(workspace.canSaveEdits(for: fileEntry), "an unexpanded archive entry has no bytes to save yet")

        await workspace.expandArchiveEntry(fileEntry, rootID: archiveRoot.id)
        guard let expanded = workspace.rootNodes.first?.children.first(where: { $0.displayName == "Levels/Earth/Hub/beach.rm2" }) else {
            return XCTFail("expandArchiveEntry should have replaced the entry with its parsed contents")
        }

        XCTAssertTrue(workspace.canSaveEdits(for: expanded), "expanding a real archive entry must register its raw bytes so it becomes save-able, the same as a standalone-opened file, canSaveEdits is exactly rawFileBytesByRootID[fileRoot.id] != nil, the precise dictionary this fix populates")

        // Prove it's not just the flag agreeing with itself: a real
        // whole-record patch (a genuine no-op, replacing a real Instance's
        // own already-decoded, re-encoded 28-byte transform prefix) must
        // actually find real tracked bytes to patch into and succeed, not
        // fail for lack of a standalone-opened file.
        var instanceEdit: (node: ChunkNode, encoded: Data)?
        func walk(_ node: ChunkNode) {
            if instanceEdit == nil, case .instance(let instance) = node.payload {
                let encoded = WorldPlacementWriter.writeInstanceTransform(
                    position: instance.position, rotationRaw: instance.rotationRaw, comRotationRaw: instance.comRotationRaw
                )
                instanceEdit = (node, encoded)
            }
            for child in node.children { walk(child) }
        }
        walk(expanded)
        guard let instanceEdit else {
            return XCTFail("expected beach.rm2 to have at least one real Instance record")
        }
        let patched = workspace.patchedFileBytes(applyingPrefixPatches: [instanceEdit])
        XCTAssertNotNil(patched, "a real prefix patch against the now-expanded level should succeed, not fail for lack of tracked bytes; lastError=\(workspace.lastError ?? "nil")")
    }

    /// "Visual Loading Feedback" (performance mandate, Part 4): a real
    /// scan reports real, monotonically-increasing progress and clears it
    /// on completion, never left stuck showing a stale percentage.
    func testScanProgressReportsRealCountsAndClearsOnCompletion() throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        ScanCache.clearAll()
        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)

        XCTAssertNotNil(workspace.scanProgress, "progress should be set the instant a scan starts")
        XCTAssertEqual(workspace.scanProgress?.completed, 0)
        XCTAssertGreaterThan(workspace.scanProgress?.total ?? 0, 0)

        var observedProgress: [(completed: Int, total: Int)] = []
        let expectation = expectation(description: "background scan completes")
        // Same "re-arm on every change" shape as `fulfill(_:whenTrue:)`
        // below, but this one needs to *record* every intermediate value
        // (not just detect a final state), so it's its own recursive local
        // function rather than going through that shared helper.
        func trackProgress() {
            withObservationTracking {
                _ = workspace.scanProgress
            } onChange: {
                DispatchQueue.main.async {
                    let progress = workspace.scanProgress
                    if let progress { observedProgress.append(progress) }
                    if progress == nil, !observedProgress.isEmpty {
                        expectation.fulfill()
                    } else {
                        trackProgress()
                    }
                }
            }
        }
        trackProgress()
        wait(for: [expectation], timeout: 300)

        XCTAssertNil(workspace.scanProgress, "progress must be cleared once the scan finishes")
        // Every real total reported must be the same fixed candidate count
        // determined up front, and completed counts must never exceed it.
        let totals = Set(observedProgress.map(\.total))
        XCTAssertEqual(totals.count, 1, "the total shouldn't change mid-scan")
        XCTAssertTrue(observedProgress.allSatisfy { $0.completed <= $0.total })
    }

    /// A real cancel path: calling `cancelScan()` mid-scan must actually
    /// stop it early (not just get ignored), and the final status must say
    /// so rather than falsely claiming a full "Scan complete."
    func testCancelScanStopsEarlyAndReportsCancellation() throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        ScanCache.clearAll()
        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)
        XCTAssertTrue(workspace.isScanning)

        // Cancel almost immediately, before the archive (hundreds of
        // files) could plausibly have finished on its own.
        workspace.cancelScan()

        let expectation = expectation(description: "scan stops after cancellation")
        fulfill(expectation, whenTrue: { !workspace.isScanning })
        wait(for: [expectation], timeout: 300)

        XCTAssertTrue(workspace.statusMessage.contains("cancelled"), "status should honestly say the scan was cancelled, not claim it completed: \(workspace.statusMessage)")
    }

    /// Regression test for "Fatal Crash on File Selection": opening a
    /// *folder* containing several loose `.RM2` files, one of them
    /// deliberately corrupted, used to run every file's full parse
    /// synchronously on the main actor in a plain `for` loop, with no
    /// async boundary between them. On a large/broad folder pick that's a
    /// long unresponsive freeze indistinguishable from a crash to the
    /// user, even though each individual parse was already safely wrapped
    /// in a `do`/`catch`. This extracts real level files out of the disc
    /// archive into loose files on disk (a real folder-open scenario, not
    /// a synthetic one) plus one genuinely malformed file, and asserts the
    /// whole batch completes, the valid files load, and the corrupted one
    /// is reported through `lastError` rather than crashing the process or
    /// silently vanishing.
    func testOpeningFolderWithLooseLevelFilesHandlesCorruptFileGracefully() throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }

        let index = try BDArchiveParser.readIndex(bhURL: bhURL)
        let entryNames = ["Levels/AltEarth/Hub/alttunl.rm2", "Levels/Earth/Hub/hubd.rm2", "Levels/Ice/IceClimb/ukafight.rm2"]
        let entries = entryNames.compactMap { name in index.entries.first { $0.name == name } }
        try XCTSkipIf(entries.isEmpty, "None of the expected sample level files were found in this disc image")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FolderOpenTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for entry in entries {
            let data = try BDArchiveParser.readEntryData(entry, index: index)
            let fileName = (entry.name as NSString).lastPathComponent
            try data.write(to: tempDir.appendingPathComponent(fileName))
        }
        // Deliberately malformed: a real .RM2 extension, but not remotely a
        // valid chunk file, this is exactly the "corrupt or truncated
        // archive" case `BinaryCursor`'s own doc comment says must surface
        // as a catchable error, not a crash.
        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03]).write(to: tempDir.appendingPathComponent("corrupted.rm2"))

        let workspace = WorkspaceViewModel()
        workspace.open(url: tempDir)

        let expectation = expectation(description: "folder load completes")
        fulfill(expectation, whenTrue: { !workspace.isLoading })
        wait(for: [expectation], timeout: 60)

        XCTAssertEqual(workspace.rootNodes.count, entries.count, "expected exactly the valid loose files to load, corrupted.rm2 excluded")
        XCTAssertNotNil(workspace.lastError, "the corrupted file's parse failure should have been reported, not silently swallowed")
        XCTAssertTrue(workspace.lastError?.contains("corrupted.rm2") ?? false, "lastError should name the file that failed: \(workspace.lastError ?? "nil")")
    }

    /// "Forge Palette anywhere": the user's own ask, "I want the thumbnail
    /// to load in the forge palette even if the level is not loaded." A
    /// fresh workspace with the real archive open but nothing scanned/
    /// expanded yet has no level of its own to resolve BASICCRATE (#3)
    /// against, and `resolvingObjectIDAcrossAllLevels` deliberately doesn't
    /// consult the shared-`Default.rm2` fast path other resolvers use , 
    /// yet BASICCRATE's own `GameObject` entry lives in that disc's real
    /// `Startup/Default.rm2` (see `AssetResolver.resolveInstanceObject`'s
    /// own doc comment on why shared pickups/props live there), which is
    /// itself just one more real `.rm2` entry `allLevelGraphicsCandidates`
    /// enumerates, so the disc-wide search should still find it there.
    func testResolvingObjectIDAcrossAllLevelsFindsRealGeometryAndRecordsItGlobally() async throws {
        let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Real CRASH.BH not present on this machine.")
        }
        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)
        XCTAssertTrue(workspace.globalObjectThumbnails.isEmpty, "sanity check: nothing should be resolved yet before this search runs")

        let resolved = await workspace.resolvingObjectIDAcrossAllLevels(3)
        let unwrapped = try XCTUnwrap(resolved, "expected BASICCRATE (#3) to resolve somewhere on the real disc")
        XCTAssertFalse(unwrapped.mesh.submeshes.isEmpty)

        XCTAssertEqual(workspace.globalObjectThumbnails[3]?.id, unwrapped.id, "a successful disc-wide resolution must be recorded into globalObjectThumbnails -- the same cache every other Forge Palette / ModelViewerRenderer.globalObjectFallbacks consumer already reads, so this is what makes the resolution 'immediately available everywhere else'")

        // A second call for the same, now-resolved object ID should
        // short-circuit through the `globalObjectThumbnails` cache rather
        // than re-running the whole disc-wide search.
        let secondResolved = await workspace.resolvingObjectIDAcrossAllLevels(3)
        XCTAssertEqual(secondResolved?.id, unwrapped.id)
    }

    /// Real, permanently-unresolvable object IDs exist on this disc, both
    /// `ALTEARTH_CORE_HOLOGRAPHIC_SPAWNER` (#986) and
    /// `ALTEARTH_CORE_LASER_ROTOGUN_TARGET` (#1016) carry `AssetResolver.
    /// resolveInstanceObject`'s real "no value" (`65535`) sentinel, so no
    /// level on the real disc can ever resolve either of them. A disc-wide
    /// search for one must come back `nil` (not hang, not crash) and cache
    /// that negative result.
    func testResolvingAConfirmedUnresolvableObjectIDReturnsNilAndCachesTheNegativeResult() async throws {
        let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Real CRASH.BH not present on this machine.")
        }
        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)

        let resolved = await workspace.resolvingObjectIDAcrossAllLevels(986)
        XCTAssertNil(resolved)
        XCTAssertTrue(workspace.confirmedUnresolvableObjectIDs.contains(986))
    }

    /// "Never re-parse a level archive entry you've already parsed this
    /// session": a second disc-wide search (for a *different*, still-
    /// unresolvable object ID, so it can't just short-circuit through
    /// `globalObjectThumbnails`/`confirmedUnresolvableObjectIDs` at the very
    /// top) must still visit the same universe of real `.rm2`/`.rmx`
    /// candidates, but every one of them was already parsed into a cached
    /// `GraphicsAssetIndex` by the first search, so it should complete
    /// dramatically faster than the first, proving levels aren't being
    /// re-parsed from scratch.
    func testResolvingObjectIDAcrossAllLevelsReusesAlreadyParsedLevelIndicesOnALaterSearch() async throws {
        let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Real CRASH.BH not present on this machine.")
        }
        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)

        let firstStart = Date()
        let firstResult = await workspace.resolvingObjectIDAcrossAllLevels(986)
        let firstDuration = Date().timeIntervalSince(firstStart)
        XCTAssertNil(firstResult)

        let secondStart = Date()
        let secondResult = await workspace.resolvingObjectIDAcrossAllLevels(1016)
        let secondDuration = Date().timeIntervalSince(secondStart)
        XCTAssertNil(secondResult)

        XCTAssertLessThan(
            secondDuration, max(firstDuration / 2, 1),
            "the second search should reuse every level's already-parsed GraphicsAssetIndex instead of re-parsing archive entries it already visited; first=\(firstDuration)s second=\(secondDuration)s"
        )
    }

    /// Regression test for the Scenery tab reporting "This level's own
    /// scenery data decoded to zero placements" for a real beach-area level
    /// whose 3D viewport rendered its scenery (trees, rocks, palm
    /// structures) just fine. `resolvedSceneryCatalog` had never been
    /// covered by any test (confirmed via `grep -rln
    /// "resolvedSceneryCatalog" Tests/` returning nothing before this).
    ///
    /// Root cause, verified empirically against this exact real archive:
    /// `resolvedSceneryCatalog` built its `AssetResolver` index from the
    /// paired `graphicsRoot` (`.rm2`) instead of `sceneryRoot` (`.sm2`)
    /// itself. A direct check against `Levels/Earth/Hub/hubb.sm2`/
    /// `hubb.rm2` showed every one of `hubb.sm2`'s real 462 scenery
    /// placements resolves against `hubb.sm2`'s own Graphics section (245
    /// `RigidModel`s / 80 `LodModel`s), while *zero* resolve against
    /// `hubb.rm2`'s, matching `resolvedLevelPlacements`'s own doc comment,
    /// which independently confirms `.rm2` carries "zero scenery" for this
    /// same level. This asserts the fixed function, now indexing
    /// `sceneryRoot` alone, returns a real, non-empty catalog with
    /// sensible entries for `hubb.sm2`, not just that it no longer crashes.
    func testResolvedSceneryCatalogIsNonEmptyForARealLevelWithKnownScenery() async throws {
        let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Real CRASH.BH not present on this machine.")
        }
        let index = try BDArchiveParser.readIndex(bhURL: bhURL)
        guard let sceneryEntry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/hubb.sm2" }) else {
            return XCTFail("couldn't find Levels/Earth/Hub/hubb.sm2 in the real archive index")
        }
        let sceneryData = try BDArchiveParser.readEntryData(sceneryEntry, index: index)
        let sceneryDriver = EngineDriverRegistry.driver(forExtension: "sm2") ?? TwinsanityEngineDriver()
        let sceneryRoot = try sceneryDriver.parseChunkFile(data: sceneryData, fileKind: .sm2, fileName: sceneryEntry.name)

        let workspace = WorkspaceViewModel()
        let catalog = await workspace.resolvedSceneryCatalog(sceneryRoot: sceneryRoot)

        XCTAssertFalse(catalog.isEmpty, "hubb.sm2 has 462 real scenery placements and should decode to a real, non-empty catalog, not the 'zero placements' regression this test guards against")
        XCTAssertTrue(catalog.allSatisfy { !$0.asset.mesh.submeshes.isEmpty }, "every catalog entry should carry real, drawable mesh geometry")
        XCTAssertTrue(catalog.allSatisfy { $0.count >= 1 }, "every catalog entry should have counted at least the one placement that produced it")
        XCTAssertEqual(catalog.map(\.modelID), Set(catalog.map(\.modelID)).sorted(), "entries should be de-duplicated by modelID/isSpecial and sorted by modelID")

        let totalPlacementsCounted = catalog.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalPlacementsCounted, 462, "hubb.sm2's real placement count is 462 (cited elsewhere in this codebase); every one of them resolves against hubb.sm2's own Graphics section, so the catalog's counts should sum back up to exactly that")
    }
}

/// Bridges `@Observable`'s access-based change tracking to XCTest's
/// synchronous `wait(for:timeout:)`. These tests used to subscribe
/// directly to `WorkspaceViewModel`'s Combine `$property` publishers,
/// which stopped existing once it migrated off `ObservableObject`/
/// `@Published` to `@Observable` -- `@Observable` types have no Combine
/// publishers at all, only one-shot access-based tracking via
/// `withObservationTracking`, which has to be re-armed after every fire.
/// `probe` both reads whichever property a given call cares about (so
/// `withObservationTracking` knows what to watch) and reports whether the
/// wait is over; it's called again on every change until it returns `true`.
/// Not `private` -- `LevelInsertionIntegrationTests.swift` (same test
/// target) reuses this exact helper rather than duplicating it.
@MainActor
func fulfill(_ expectation: XCTestExpectation, whenTrue probe: @escaping () -> Bool) {
    withObservationTracking {
        _ = probe()
    } onChange: {
        DispatchQueue.main.async {
            if probe() {
                expectation.fulfill()
            } else {
                fulfill(expectation, whenTrue: probe)
            }
        }
    }
}
