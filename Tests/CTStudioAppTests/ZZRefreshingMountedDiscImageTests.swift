import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Direct, focused test of `WorkspaceViewModel.refreshingMountedDiscImage`'s
/// actual new logic, closing a stale archive root (like `CRASH.BH`,
/// already browsed into from a mounted disc) before remounting, without
/// depending on `select(_:)`'s `DispatchQueue.main.async`-deferred dispatch,
/// which doesn't reliably fire under polling in a headless XCTest host
/// (confirmed separately: `ZZDiscRemountAfterSaveTests` couldn't get
/// `select()` to complete even with explicit RunLoop pumping). Simulates
/// "already browsed into this disc's archive" the same way `openDiscEntry`
/// itself does under the hood, extracting a copy and calling the real,
/// public `open(url:)` on it, bare-named to match, sidestepping only the
/// dispatch-timing problem, not the actual logic under test.
final class ZZRefreshingMountedDiscImageTests: XCTestCase {
    private static let realISOCandidates = [
        "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/Crash Twinsanity (Europe, Australia) (En,Fr,De,Es,It).iso",
    ]

    @MainActor
    func testRefreshingMountedDiscImageClosesAStaleAlreadyOpenArchiveRoot() async throws {
        guard let realISOPath = Self.realISOCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("Real disc image not present on this machine.")
        }
        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("ZZRefreshingMountedDiscImageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let workingISO = scratchDir.appendingPathComponent("working.iso")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: realISOPath), to: workingISO)

        let workspace = WorkspaceViewModel()
        workspace.mountDiscImage(url: workingISO)
        for _ in 0..<600 where workspace.rootNodes.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(workspace.rootNodes.isEmpty, "mountDiscImage never populated rootNodes")
        let discRootCount = workspace.rootNodes.count
        XCTAssertEqual(discRootCount, 1, "sanity: exactly one disc root expected right after mounting")

        // Extract the real CRASH.BH/.BD from the disc and open them exactly
        // the way `openDiscEntry` does under the hood (extract to a stable
        // location, `open(url:)` the result) -- registering a second,
        // independent top-level root bare-named "CRASH.BH", simulating
        // "the user already clicked into this archive before saving."
        let isoData = try Data(contentsOf: workingISO, options: .mappedIfSafe)
        let source = PlainISOSource(data: isoData)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        func findEntry(_ node: ISO9660Entry, name: String) -> ISO9660Entry? {
            if node.name.caseInsensitiveCompare(name) == .orderedSame { return node }
            for child in node.children { if let found = findEntry(child, name: name) { return found } }
            return nil
        }
        func findDir(_ node: ISO9660Entry, name: String) -> ISO9660Entry? {
            if node.isDirectory, node.name.caseInsensitiveCompare(name) == .orderedSame { return node }
            for child in node.children where child.isDirectory { if let found = findDir(child, name: name) { return found } }
            return nil
        }
        guard let crash6 = findDir(root, name: "CRASH6"),
              let bhEntry = findEntry(crash6, name: "CRASH.BH"),
              let bdEntry = findEntry(crash6, name: "CRASH.BD"),
              let bhData = ISO9660Reader.readFile(bhEntry, from: source),
              let bdData = ISO9660Reader.readFile(bdEntry, from: source)
        else {
            throw XCTSkip("Couldn't extract CRASH.BH/.BD from the scratch disc copy.")
        }
        let extractedDir = scratchDir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        let extractedBH = extractedDir.appendingPathComponent("CRASH.BH")
        let extractedBD = extractedDir.appendingPathComponent("CRASH.BD")
        try bhData.write(to: extractedBH)
        try bdData.write(to: extractedBD)

        workspace.open(url: extractedBH)
        XCTAssertNil(workspace.lastError, "opening the extracted CRASH.BH must succeed, got: \(workspace.lastError ?? "")")
        XCTAssertEqual(workspace.rootNodes.count, discRootCount + 1, "opening the extracted archive should register one new independent root")
        // Real bug found here: an opened archive root's own displayName
        // isn't the bare filename -- open(url:)'s archive path appends a
        // real entry count ("CRASH.BH  (697 files)"), so a naive
        // lastPathComponent match (no "/" to split on) never matches
        // "CRASH.BH". Matching the same way the fixed production code
        // now does: strip the "  (" suffix first.
        func bareRootName(_ displayName: String) -> String {
            let withoutCountSuffix = displayName.components(separatedBy: "  (").first ?? displayName
            return (withoutCountSuffix as NSString).lastPathComponent.lowercased()
        }
        let staleArchiveRootID = try XCTUnwrap(workspace.rootNodes.first(where: { bareRootName($0.displayName) == "crash.bh" })?.id, "no CRASH.BH root registered after open(url:), rootNodes: \(workspace.rootNodes.map(\.displayName))")

        // The actual fix under test: refresh, and confirm the stale
        // archive root is gone (closed), not just left sitting there.
        workspace.refreshingMountedDiscImage(url: workingISO)
        for _ in 0..<600 where workspace.rootNodes.contains(where: { $0.id == staleArchiveRootID }) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(workspace.rootNodes.contains(where: { $0.id == staleArchiveRootID }), "refreshingMountedDiscImage should have closed the stale CRASH.BH root, but it's still present")

        // The disc itself should also have been freshly re-mounted (a real
        // disc root present, not just the stale archive root removed with
        // nothing replacing it). `mountDiscImage`'s own remount work runs
        // in a detached Task -- closing the stale root above happens
        // synchronously first, so it's not safe to assume the remount
        // finished by the same point; wait for a real disc root
        // (containing CRASH6) to actually show up.
        for _ in 0..<600 where !workspace.rootNodes.contains(where: { root in root.children.contains(where: { $0.displayName.caseInsensitiveCompare("CRASH6") == .orderedSame }) }) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(workspace.rootNodes.contains(where: { root in
            root.children.contains(where: { $0.displayName.caseInsensitiveCompare("CRASH6") == .orderedSame })
        }), "expected a freshly re-mounted disc root after refreshingMountedDiscImage")
    }

    /// Real, reported bug ("if I ejected a disc I shouldn't still see these
    /// files available"): ejecting used to close only the disc root itself
    ///, an archive the user had browsed into (`CRASH.BH`, auto-opened as
    /// its own independent root by `autoOpenDiscArchives`, same real
    /// mechanism a manual sidebar click uses) was left sitting in
    /// `rootNodes`, fully readable, after "Eject." Unlike the refresh test
    /// above (which deliberately simulates the stale-archive state via a
    /// direct `open(url:)` to sidestep `select(_:)`'s dispatch-timing
    /// issue), this lets the real auto-open path run, `openDiscEntry`'s
    /// own `Task { }` dispatch, not `select(_:)`'s, is what needs to be
    /// exercised for real here.
    @MainActor
    func testUnmountDiscImageAlsoClosesArchivesOpenedByBrowsingIntoIt() async throws {
        guard let realISOPath = Self.realISOCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("Real disc image not present on this machine.")
        }
        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("ZZRefreshingMountedDiscImageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let workingISO = scratchDir.appendingPathComponent("working.iso")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: realISOPath), to: workingISO)

        let workspace = WorkspaceViewModel()
        workspace.mountDiscImage(url: workingISO)
        // Waits for both the disc root itself *and* its real .BH archive to
        // auto-open as a second, independent root, the exact real-world
        // state ("browsed into the disc's archive") this bug only ever
        // showed up in.
        for _ in 0..<600 where workspace.rootNodes.count < 2 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThanOrEqual(workspace.rootNodes.count, 2, "expected the disc root plus at least one auto-opened archive root, got: \(workspace.rootNodes.map(\.displayName))")
        let archiveRootID = try XCTUnwrap(
            workspace.rootNodes.first(where: { $0.displayName.localizedCaseInsensitiveContains("CRASH.BH") })?.id,
            "no auto-opened CRASH.BH root found, rootNodes: \(workspace.rootNodes.map(\.displayName))"
        )

        workspace.unmountDiscImage()

        XCTAssertTrue(workspace.rootNodes.isEmpty, "Eject must close every root, the disc itself and anything opened by browsing into it, got: \(workspace.rootNodes.map(\.displayName))")
        XCTAssertFalse(workspace.rootNodes.contains(where: { $0.id == archiveRootID }), "the archive opened by browsing into the ejected disc must be closed too")
    }
}
