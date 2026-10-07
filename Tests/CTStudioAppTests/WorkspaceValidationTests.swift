import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Regression coverage for two s added to close
/// gaps a senior-engineer code review flagged: "Cross-Reference Validation
///, Colliding IDs" (`WorkspaceViewModel.siblingRecordIDs`, used by
/// `IDEditorSheet` to block reassigning a record to an ID a sibling
/// already uses) and "Save History, Backup Before First In-Place
/// Overwrite" (`WorkspaceViewModel.backingUpMountedDiscImageIfNeeded`).
@MainActor
final class WorkspaceValidationTests: XCTestCase {
    private func makeSection(children: [(id: UInt32, bytes: Data)]) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(TwinsMagic.v1)
        writer.writeInt32(Int32(children.count))
        let contentSize = children.reduce(0) { $0 + $1.bytes.count }
        writer.writeUInt32(UInt32(contentSize))
        var offset = 12 + children.count * 12
        for child in children {
            writer.writeUInt32(UInt32(offset))
            writer.writeInt32(Int32(child.bytes.count))
            writer.writeUInt32(child.id)
            offset += child.bytes.count
        }
        for child in children {
            writer.writeBytes(child.bytes)
        }
        return writer.data
    }

    // MARK: - siblingRecordIDs

    func testSiblingRecordIDsFindsRealSiblingsExcludingSelf() async throws {
        // A section with three real sibling leaf records: IDs 5, 9, 12.
        let fileData = makeSection(children: [
            (5, Data([1, 2, 3])),
            (9, Data([4, 5, 6])),
            (12, Data([7, 8, 9])),
        ])
        let workspace = WorkspaceViewModel()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceValidationTests-\(UUID().uuidString).RM2")
        try fileData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        workspace.open(url: tempURL)
        // Loose `.RM2`/`.SM2` files parse asynchronously (`open(url:)`'s
        // own doc comment) -- `rootNodes` isn't populated the instant this
        // call returns.
        for _ in 0..<200 where workspace.rootNodes.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(workspace.lastError)

        let root = try XCTUnwrap(workspace.rootNodes.first)
        let targetNode = try XCTUnwrap(root.children.first { $0.recordID == 9 })

        let siblings = workspace.siblingRecordIDs(of: targetNode)
        XCTAssertEqual(siblings, [5, 12], "must include every other real sibling, excluding the node itself")

        let siblingsIncludingSelf = workspace.siblingRecordIDs(of: targetNode, excludingSelf: false)
        XCTAssertEqual(siblingsIncludingSelf, [5, 9, 12])
    }

    func testSiblingRecordIDsIsEmptyForANodeWithNoFindableParent() {
        // A node that was never actually inserted into `rootNodes` has no
        // real parent to find, must fail safe (empty set), not crash.
        let workspace = WorkspaceViewModel()
        let orphan = ChunkNode(recordID: 1, sectionType: .unknown, displayName: "orphan", byteSize: 0, fileOffset: 0)
        XCTAssertEqual(workspace.siblingRecordIDs(of: orphan), [])
    }

    // MARK: - backingUpMountedDiscImageIfNeeded / full version history

    func testBackingUpCreatesARealTimestampedCopyOfThePreEditBytes() throws {
        let workspace = WorkspaceViewModel()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceValidationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let discURL = tempDir.appendingPathComponent("game.iso")
        let originalBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try originalBytes.write(to: discURL)

        workspace.backingUpMountedDiscImageIfNeeded(url: discURL)

        let versions = workspace.listDiscImageVersions(for: discURL)
        XCTAssertEqual(versions.count, 1)
        let version = try XCTUnwrap(versions.first)
        XCTAssertEqual(try Data(contentsOf: version.url), originalBytes, "the version must be a byte-exact copy of the pre-edit disc image")
        XCTAssertEqual(version.byteSize, originalBytes.count)
    }

    /// Real change from the earlier "backup only the first time this
    /// session" behavior: every in-place save now keeps its own version,
    /// so a real, browsable history accumulates rather than one static
    /// snapshot from the start of the session.
    func testEachSuccessiveSaveAddsItsOwnVersionRatherThanReusingTheFirstOne() throws {
        let workspace = WorkspaceViewModel()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceValidationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let discURL = tempDir.appendingPathComponent("game.iso")

        try Data([0x01]).write(to: discURL)
        workspace.backingUpMountedDiscImageIfNeeded(url: discURL)
        try Data([0x02]).write(to: discURL)
        workspace.backingUpMountedDiscImageIfNeeded(url: discURL)

        let versions = workspace.listDiscImageVersions(for: discURL)
        XCTAssertEqual(versions.count, 2, "each save should add a new version rather than being skipped after the first")
        let capturedBytes = Set(versions.map { try? Data(contentsOf: $0.url) })
        XCTAssertTrue(capturedBytes.contains(Data([0x01])))
        XCTAssertTrue(capturedBytes.contains(Data([0x02])))
    }

    /// Disc images are large, unbounded version accumulation would
    /// quietly fill the disk. Pruning must keep only the newest
    /// `maxVersionsPerDiscImage`, discarding the oldest first.
    func testOldVersionsArePrunedBeyondTheConfiguredLimit() throws {
        let workspace = WorkspaceViewModel()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceValidationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let discURL = tempDir.appendingPathComponent("game.iso")

        for i in 0..<(WorkspaceViewModel.maxVersionsPerDiscImage + 3) {
            try Data([UInt8(i)]).write(to: discURL)
            workspace.backingUpMountedDiscImageIfNeeded(url: discURL)
        }

        let versions = workspace.listDiscImageVersions(for: discURL)
        XCTAssertEqual(versions.count, WorkspaceViewModel.maxVersionsPerDiscImage, "must never keep more than the configured cap")
    }

    /// `restoringDiscImageVersion` must both replace the live disc image
    /// with the chosen version's bytes *and* itself back up whatever was
    /// live immediately beforehand, restoring an old version is not
    /// supposed to be a one-way trip.
    func testRestoringAVersionReplacesTheLiveDiscAndBacksUpWhatWasThereFirst() throws {
        let workspace = WorkspaceViewModel()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceValidationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let discURL = tempDir.appendingPathComponent("game.iso")

        try Data([0x01]).write(to: discURL)
        workspace.backingUpMountedDiscImageIfNeeded(url: discURL) // version of 0x01
        try Data([0x02]).write(to: discURL) // live disc is now 0x02, un-versioned

        let firstVersion = try XCTUnwrap(workspace.listDiscImageVersions(for: discURL).first)
        try workspace.restoringDiscImageVersion(firstVersion, to: discURL)

        XCTAssertEqual(try Data(contentsOf: discURL), Data([0x01]), "the live disc image must now match the restored version's bytes")
        let versionsAfterRestore = workspace.listDiscImageVersions(for: discURL)
        XCTAssertTrue(versionsAfterRestore.contains { (try? Data(contentsOf: $0.url)) == Data([0x02]) }, "the pre-restore live state (0x02) must itself have been saved as a version before being overwritten")
    }

    /// Real edge case: restoring the *oldest* currently-kept version must
    /// not fail merely because restoring it backs up the live disc first,
    /// which could otherwise push the total past the cap and prune that
    /// exact version out from under the restore before it's read.
    func testRestoringTheOldestKeptVersionSucceedsEvenAtTheCap() throws {
        let workspace = WorkspaceViewModel()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceValidationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let discURL = tempDir.appendingPathComponent("game.iso")

        for i in 0..<WorkspaceViewModel.maxVersionsPerDiscImage {
            try Data([UInt8(i)]).write(to: discURL)
            workspace.backingUpMountedDiscImageIfNeeded(url: discURL)
        }
        // The versions directory is now exactly at the cap.
        let versionsBeforeRestore = workspace.listDiscImageVersions(for: discURL)
        XCTAssertEqual(versionsBeforeRestore.count, WorkspaceViewModel.maxVersionsPerDiscImage)
        let oldest = try XCTUnwrap(versionsBeforeRestore.last, "listDiscImageVersions is sorted newest first")
        let oldestBytes = try Data(contentsOf: oldest.url)

        try Data([0xFF]).write(to: discURL) // live, un-versioned edit
        try workspace.restoringDiscImageVersion(oldest, to: discURL)

        XCTAssertEqual(try Data(contentsOf: discURL), oldestBytes, "restoring the oldest kept version must still succeed and produce its real bytes, not fail because of its own backup/prune side effect")
    }

    func testListDiscImageVersionsIsEmptyWhenNothingHasBeenBackedUpYet() throws {
        let workspace = WorkspaceViewModel()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceValidationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let discURL = tempDir.appendingPathComponent("game.iso")
        try Data([0x01]).write(to: discURL)

        XCTAssertEqual(workspace.listDiscImageVersions(for: discURL), [])
    }
}
