import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// "Integrate Wrath of Cortex into the Sidebar": `mountDiscImage` used to
/// only populate a separate `mountedDiscImage` sheet, this pins the real
/// replacement behavior, that a mounted disc's real directory tree becomes
/// actual `ChunkNode` entries in `rootNodes`, browsable/searchable/
/// filterable through the exact same sidebar machinery as any opened
/// archive, with no separate modal browser.
///
/// Builds the same real, spec-compliant (ECMA-119) synthetic ISO-9660
/// image byte layout `DiscImageTests` (CTParsersTests) already verifies
/// `ISO9660Reader` parses correctly, this test instead exercises the
/// `WorkspaceViewModel` layer built on top of it.
final class DiscImageSidebarMergeTests: XCTestCase {
    private static let sectorSize = 2048
    /// Mirrors `WorkspaceViewModel`'s own private `lastMountedDiscImageURLDefaultsKey`
    /// literal, used only to scrub `UserDefaults.standard` around the
    /// persistence test below so it's self-contained across repeated runs.
    private static let lastMountedDiscImageURLDefaultsKeyForTest = "TwinsanityStudio.LastMountedDiscImageURL"

    private func bothEndian32(_ v: UInt32) -> [UInt8] {
        let le: [UInt8] = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        return le + le.reversed()
    }

    private func bothEndian16(_ v: UInt16) -> [UInt8] {
        let le: [UInt8] = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
        return le + le.reversed()
    }

    private func directoryRecord(lba: UInt32, size: UInt32, isDirectory: Bool, identifier: [UInt8]) -> [UInt8] {
        var rest: [UInt8] = [0]
        rest += bothEndian32(lba)
        rest += bothEndian32(size)
        rest += [UInt8](repeating: 0, count: 7)
        rest.append(isDirectory ? 0x02 : 0x00)
        rest.append(0)
        rest.append(0)
        rest += bothEndian16(1)
        rest.append(UInt8(identifier.count))
        rest += identifier
        var total = 1 + rest.count
        if total % 2 != 0 {
            rest.append(0)
            total += 1
        }
        return [UInt8(total)] + rest
    }

    private func makeSector(_ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count <= Self.sectorSize)
        return bytes + [UInt8](repeating: 0, count: Self.sectorSize - bytes.count)
    }

    /// Root directory (sector 18) containing one real file (`CRATE.CRT;1`)
    /// and one subdirectory (`WMPDATA`, sector 19) containing one more
    /// real file (`FRUIT.WMP;1`), mirrors a real Wrath of Cortex-style
    /// disc layout closely enough to exercise nested-directory mirroring,
    /// not just a flat file list.
    private func buildSyntheticISOFile() throws -> URL {
        let crtContent = Array("CRATE-DATA".utf8)
        let wmpContent = Array("WUMPA-DATA".utf8)

        var sectors: [[UInt8]] = (0..<22).map { _ in makeSector([]) }

        var pvd: [UInt8] = [1]
        pvd += Array("CD001".utf8)
        pvd.append(1)
        pvd = pvd + [UInt8](repeating: 0, count: 156 - pvd.count)
        pvd += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        sectors[16] = makeSector(pvd)

        var terminator: [UInt8] = [255]
        terminator += Array("CD001".utf8)
        terminator.append(1)
        sectors[17] = makeSector(terminator)

        var root: [UInt8] = []
        root += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        root += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [1])
        root += directoryRecord(lba: 20, size: UInt32(crtContent.count), isDirectory: false, identifier: Array("CRATE.CRT;1".utf8))
        root += directoryRecord(lba: 19, size: UInt32(Self.sectorSize), isDirectory: true, identifier: Array("WMPDATA".utf8))
        sectors[18] = makeSector(root)

        var subdir: [UInt8] = []
        subdir += directoryRecord(lba: 19, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        subdir += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [1])
        subdir += directoryRecord(lba: 21, size: UInt32(wmpContent.count), isDirectory: false, identifier: Array("FRUIT.WMP;1".utf8))
        sectors[19] = makeSector(subdir)

        sectors[20] = makeSector(crtContent)
        sectors[21] = makeSector(wmpContent)

        let flatData = Data(sectors.flatMap { $0 })
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).iso")
        try flatData.write(to: tempURL)
        return tempURL
    }

    private func findByName(_ name: String, in nodes: [ChunkNode]) -> ChunkNode? {
        nodes.first { $0.displayName == name }
    }

    /// `mountDiscImage` moved its read + directory-walk onto a background
    /// `Task.detached` (see that function's own doc comment) so it never
    /// blocks the main thread on a slow/large disc image -- real, correct
    /// behavior, but it means `rootNodes` is no longer populated by the
    /// time `mountDiscImage` itself returns. Every test below used to
    /// assert synchronously right after calling it; this polls until the
    /// background work actually lands (or fails loudly on a real timeout)
    /// instead of racing it.
    @MainActor
    private func waitForRootNodes(_ workspace: WorkspaceViewModel, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while workspace.rootNodes.isEmpty {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for mountDiscImage's background Task to populate rootNodes")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testMountDiscImageAddsRealTreeToRootNodesNotASeparateSheet() async throws {
        let isoURL = try buildSyntheticISOFile()
        defer { try? FileManager.default.removeItem(at: isoURL) }

        let workspace = WorkspaceViewModel()
        XCTAssertEqual(workspace.rootNodes.count, 0)

        workspace.mountDiscImage(url: isoURL)
        try await waitForRootNodes(workspace)

        XCTAssertNil(workspace.lastError, "mounting a real, valid synthetic ISO should not report an error")
        XCTAssertEqual(workspace.rootNodes.count, 1, "the mounted disc should be a real top-level sidebar entry, not a separate sheet")

        let discRoot = try XCTUnwrap(workspace.rootNodes.first)
        let names = Set(discRoot.children.map(\.displayName))
        XCTAssertEqual(names, ["CRATE.CRT", "WMPDATA"], "both the real file and the real subdirectory should be mirrored as real ChunkNode children")

        let crtNode = try XCTUnwrap(findByName("CRATE.CRT", in: discRoot.children))
        XCTAssertEqual(crtNode.byteSize, 10, "CRATE-DATA is 10 real bytes")
        XCTAssertTrue(crtNode.children.isEmpty, "a real file leaf has no children")

        let subdirNode = try XCTUnwrap(findByName("WMPDATA", in: discRoot.children))
        XCTAssertEqual(subdirNode.children.map(\.displayName), ["FRUIT.WMP"], "nested directories must mirror recursively, not just the root level")
    }

    /// "Remember the last mounted disc" (app-lifecycle sweep):
    /// `mountDiscImage`'s success path should record `lastMountedDiscImageURL`
    /// (independent of `discImageURL`, which this synthetic image never
    /// touches, it isn't a plain `.iso` extension test target here, it's
    /// the same fixture `testMountDiscImageAddsRealTreeToRootNodesNotASeparateSheet`
    /// already proves mounts cleanly), and `autoRemountLastDiscImageIfAvailable`
    /// should use that persisted value to bring the same disc back on a
    /// fresh `WorkspaceViewModel` standing in for "next launch."
    @MainActor
    func testSuccessfulMountRecordsLastMountedDiscImageURLAndAutoRemountRestoresIt() async throws {
        let isoURL = try buildSyntheticISOFile()
        // `lastMountedDiscImageURL` persists to the real `UserDefaults.standard`
        // (same mechanism as `discImageURL`), so a prior run of this exact
        // test (or a real session on this machine) could leave a stale value
        // behind on disk between process launches, clear it on both ends so
        // this test is self-contained rather than order/history-dependent.
        UserDefaults.standard.removeObject(forKey: Self.lastMountedDiscImageURLDefaultsKeyForTest)
        defer {
            try? FileManager.default.removeItem(at: isoURL)
            UserDefaults.standard.removeObject(forKey: Self.lastMountedDiscImageURLDefaultsKeyForTest)
        }

        let workspace = WorkspaceViewModel()
        XCTAssertNil(workspace.lastMountedDiscImageURL, "nothing mounted yet in this fresh instance")

        workspace.mountDiscImage(url: isoURL)
        try await waitForRootNodes(workspace)
        XCTAssertNil(workspace.lastError)
        XCTAssertEqual(workspace.lastMountedDiscImageURL, isoURL, "a successful mount should record the exact URL passed in")

        // Simulate "next launch": a brand new WorkspaceViewModel restores
        // `lastMountedDiscImageURL` from UserDefaults in its own `init`
        // (same mechanism `discImageURL` already uses), then
        // `autoRemountLastDiscImageIfAvailable` should mount it again
        // without anyone calling `mountDiscImage` directly.
        let relaunched = WorkspaceViewModel()
        XCTAssertEqual(relaunched.lastMountedDiscImageURL, isoURL, "should have restored from UserDefaults, mirroring discImageURL's own persistence")
        XCTAssertEqual(relaunched.rootNodes.count, 0, "shouldn't auto-mount just from being constructed")

        relaunched.autoRemountLastDiscImageIfAvailable()
        try await waitForRootNodes(relaunched)
        XCTAssertNil(relaunched.lastError, "auto-remounting the same still-real file should succeed silently")
        XCTAssertEqual(relaunched.rootNodes.count, 1, "the disc should be mounted again automatically")
    }

    /// A stale persisted URL (the file was moved/deleted since last launch)
    /// should be cleared quietly, not surfaced as an error, the user never
    /// asked to open this file just now, so there's nothing to complain to
    /// them about.
    @MainActor
    func testAutoRemountClearsStalePersistedURLWithoutError() {
        let workspace = WorkspaceViewModel()
        let goneURL = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).iso")
        workspace.lastMountedDiscImageURL = goneURL

        workspace.autoRemountLastDiscImageIfAvailable()

        XCTAssertNil(workspace.lastMountedDiscImageURL, "a nonexistent path should be cleared rather than retried forever")
        XCTAssertNil(workspace.lastError, "the user didn't just ask to open this file, no error banner for a missing auto-remount target")
        XCTAssertEqual(workspace.rootNodes.count, 0)
    }

    /// Real regression: `rootNodes` gained the mounted disc correctly, but
    /// the sidebar actually renders `filteredRootNodes`, which runs every
    /// root through `ChunkNode.prunedOfRawContent()` by default
    /// (`showRawFiles == false` out of the box). `buildDiscNode` never set
    /// `isLazyLoadable` on any disc leaf, and a disc file's own name never
    /// matches `looksLikeChunkFileName` (`.RM2`/`.SM2` live *inside*
    /// `CRASH.BH`/`CRASH.BD`, not as their own ISO directory entries), so
    /// every real file on a freshly mounted disc, `CRASH.BH`/`CRASH.BD`
    /// included, was silently pruned to nothing. A user mounting a real
    /// disc image saw "1 file open" (the root) and an empty tree beneath
    /// it. This pins `filteredRootNodes` specifically, not just
    /// `rootNodes`, so a regression here fails loudly again.
    @MainActor
    func testMountedDiscFilesSurviveDefaultRawContentFiltering() async throws {
        let isoURL = try buildSyntheticISOFile()
        defer { try? FileManager.default.removeItem(at: isoURL) }

        let workspace = WorkspaceViewModel()
        XCTAssertFalse(workspace.showRawFiles, "this test only means anything under the default filtering state")
        workspace.mountDiscImage(url: isoURL)
        try await waitForRootNodes(workspace)

        XCTAssertEqual(workspace.filteredRootNodes.count, 1, "the mounted disc must still be visible under default 'Smart File Filtering', not just present in the unfiltered rootNodes")
        let discRoot = try XCTUnwrap(workspace.filteredRootNodes.first)
        let names = Set(discRoot.children.map(\.displayName))
        XCTAssertEqual(names, ["CRATE.CRT", "WMPDATA"], "both the recognized-extension file and the subdirectory containing one must survive default pruning")
        let subdirNode = try XCTUnwrap(findByName("WMPDATA", in: discRoot.children))
        XCTAssertEqual(subdirNode.children.map(\.displayName), ["FRUIT.WMP"], "a nested recognized-extension file must also survive")
    }

    /// Selecting a disc-mounted file leaf extracts its real bytes and
    /// routes them through the same `open(url:)` pipeline any other file
    /// uses, proven here by picking an unrecognized extension (`.crt` is
    /// real, but this synthetic file's *content* is plain text, not a real
    /// CRT record) and confirming extraction still happens without a
    /// crash or a stuck `isLoading`, rather than asserting on parse
    /// success this fixture was never meant to produce.
    @MainActor
    func testSelectingDiscFileLeafExtractsWithoutCrashing() async throws {
        let isoURL = try buildSyntheticISOFile()
        defer { try? FileManager.default.removeItem(at: isoURL) }

        let workspace = WorkspaceViewModel()
        workspace.mountDiscImage(url: isoURL)
        try await waitForRootNodes(workspace)
        let discRoot = try XCTUnwrap(workspace.rootNodes.first)
        let crtNode = try XCTUnwrap(findByName("CRATE.CRT", in: discRoot.children))

        workspace.select(crtNode)

        let expectation = expectation(description: "select's deferred dispatch runs")
        DispatchQueue.main.async { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 5)

        XCTAssertEqual(workspace.selectedNode?.id, crtNode.id, "the disc node itself should still become selectedNode")
    }

    /// Regression test for a real, reported bug: mounting a disc never
    /// closed a previously-mounted one, every call to `mountDiscImage`
    /// (including the every-launch auto-remount) just appended another
    /// "Disc" root, so the sidebar accumulated a duplicate entry per mount
    /// instead of showing the one active disc a user actually expects.
    @MainActor
    func testMountingASecondDiscImageClosesTheFirstInsteadOfStackingBoth() async throws {
        let firstURL = try buildSyntheticISOFile()
        let secondURL = try buildSyntheticISOFile()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let workspace = WorkspaceViewModel()
        workspace.mountDiscImage(url: firstURL)
        try await waitForRootNodes(workspace)
        XCTAssertEqual(workspace.rootNodes.count, 1)
        let firstRootID = try XCTUnwrap(workspace.rootNodes.first?.id)
        let firstDiscCrateNode = try XCTUnwrap(findByName("CRATE.CRT", in: workspace.rootNodes.first?.children ?? []), "expected the first disc's own real file node before the second mount")
        XCTAssertTrue(workspace.canReplaceDiscFile(firstDiscCrateNode), "sanity: the first disc's own file must be recognized as disc-backed before it's closed")

        workspace.mountDiscImage(url: secondURL)
        // The old root is removed synchronously inside `mountDiscImage`
        // itself, before its background read even starts.
        XCTAssertTrue(workspace.rootNodes.isEmpty || workspace.rootNodes.first?.id != firstRootID, "the previous disc's root must be closed, not left alongside the new one")
        try await waitForRootNodes(workspace)

        XCTAssertEqual(workspace.rootNodes.count, 1, "mounting a second disc must replace the first, not stack a second \"Disc\" entry alongside it")
        XCTAssertNotEqual(workspace.rootNodes.first?.id, firstRootID, "the surviving root must be the newly mounted disc, not the old one")
        XCTAssertFalse(workspace.canReplaceDiscFile(firstDiscCrateNode), "the closed disc's own bookkeeping (discEntryByNodeID) must not outlive it")
    }

    // MARK: - Disc-mounted .BH/.BD archive pair

    /// A minimal, real, valid `.BH` index (`BDArchiveParser`'s own format:
    /// magic `0x501`, then `nameLen:Int32, name:ASCII, offset:UInt32,
    /// size:UInt32` per entry) plus its matching `.BD` data blob holding
    /// one real entry.
    private func buildArchivePairBytes(entryName: String, entryContent: [UInt8]) -> (bh: [UInt8], bd: [UInt8]) {
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        let nameBytes = Array(entryName.utf8)
        var bh: [UInt8] = le32(0x501)
        bh += le32(UInt32(nameBytes.count))
        bh += nameBytes
        bh += le32(0) // offset
        bh += le32(UInt32(entryContent.count))
        return (bh, entryContent)
    }

    /// Root directory containing two sibling real files, `TEST.BH` and
    /// `TEST.BD`, a minimal disc-mounted archive pair, no subdirectory
    /// needed.
    private func buildSyntheticISOWithArchivePair(bhBytes: [UInt8], bdBytes: [UInt8]) throws -> URL {
        var sectors: [[UInt8]] = (0..<20).map { _ in makeSector([]) }

        var pvd: [UInt8] = [1]
        pvd += Array("CD001".utf8)
        pvd.append(1)
        pvd = pvd + [UInt8](repeating: 0, count: 156 - pvd.count)
        pvd += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        sectors[16] = makeSector(pvd)

        var terminator: [UInt8] = [255]
        terminator += Array("CD001".utf8)
        terminator.append(1)
        sectors[17] = makeSector(terminator)

        var root: [UInt8] = []
        root += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        root += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [1])
        root += directoryRecord(lba: 19, size: UInt32(bhBytes.count), isDirectory: false, identifier: Array("TEST.BH;1".utf8))
        root += directoryRecord(lba: 19 + UInt32(sectorCount(for: bhBytes.count)), size: UInt32(bdBytes.count), isDirectory: false, identifier: Array("TEST.BD;1".utf8))
        sectors[18] = makeSector(root)

        var offset = 19
        for chunk in bhBytes.chunked(into: Self.sectorSize) {
            while sectors.count <= offset { sectors.append(makeSector([])) }
            sectors[offset] = makeSector(chunk)
            offset += 1
        }
        for chunk in bdBytes.chunked(into: Self.sectorSize) {
            while sectors.count <= offset { sectors.append(makeSector([])) }
            sectors[offset] = makeSector(chunk)
            offset += 1
        }

        let flatData = Data(sectors.flatMap { $0 })
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-archive-\(UUID().uuidString).iso")
        try flatData.write(to: tempURL)
        return tempURL
    }

    private func sectorCount(for byteCount: Int) -> Int {
        max(1, (byteCount + Self.sectorSize - 1) / Self.sectorSize)
    }

    /// Real regression: clicking a disc-mounted `.BH` used to extract
    /// *only* that one file into a fresh temp directory, then hand it to
    /// the normal `open(url:)` pipeline. `BDArchiveParser.readIndex`
    /// parses the index fine from the `.BH` alone (so the archive's own
    /// entry list showed up correctly, a real, misleadingly-plausible
    /// partial success), but every entry's actual bytes live in the
    /// sibling `.BD`, which `counterpartURL(for:)` expects to find in that
    /// *same* temp directory, never extracted there, so any attempt to
    /// actually read an entry's data failed with "CRASH.BD ... no such
    /// file." This mounts a synthetic disc with a real `.BH`/`.BD` pair,
    /// selects the `.BH` node the same way a sidebar click does, and
    /// confirms the sibling `.BD` really is reachable afterward, not just
    /// that the index parsed.
    @MainActor
    func testSelectingDiscMountedArchiveIndexAlsoExtractsItsRealDataSibling() async throws {
        let entryContent = Array("REAL-ENTRY-BYTES".utf8)
        let (bhBytes, bdBytes) = buildArchivePairBytes(entryName: "ENTRY1", entryContent: entryContent)
        let isoURL = try buildSyntheticISOWithArchivePair(bhBytes: bhBytes, bdBytes: bdBytes)
        defer { try? FileManager.default.removeItem(at: isoURL) }

        let workspace = WorkspaceViewModel()
        workspace.mountDiscImage(url: isoURL)
        try await waitForRootNodes(workspace)
        let discRoot = try XCTUnwrap(workspace.rootNodes.first)
        let bhNode = try XCTUnwrap(findByName("TEST.BH", in: discRoot.children))

        workspace.select(bhNode)

        let expectation = expectation(description: "select's deferred archive-open work runs")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 5)

        XCTAssertNil(workspace.lastError, "the sibling .BD must be reachable now, not just the .BH index, got: \(workspace.lastError ?? "")")

        // The opened archive's own root should now be browsable with the
        // one real entry the synthetic .BH/.BD pair actually defines.
        guard let archiveRoot = workspace.rootNodes.first(where: { $0.displayName.contains("TEST.BH") }) else {
            return XCTFail("Expected a new archive-index root for the opened TEST.BH.")
        }
        XCTAssertEqual(archiveRoot.children.map(\.displayName), ["ENTRY1"])
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
