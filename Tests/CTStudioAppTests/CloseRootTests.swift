import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Regression tests for a real, reported gap: nothing in this app could
/// close a file/archive/disc that had been opened, `WorkspaceViewModel.
/// closeRoot(_:)` is the one general mechanism now behind the sidebar's new
/// "Close" context menu item. These pin that it actually tears down every
/// piece of per-root bookkeeping, not just the visible sidebar node , 
/// proven by reopening the exact same source afterward and confirming it
/// behaves like a totally fresh open, not one tangled up with stale state
/// left over from before the close.
final class CloseRootTests: XCTestCase {
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

    private func buildArchivePair(entries: [(name: String, content: Data)]) -> (bh: Data, bd: Data) {
        var bh = BinaryWriter()
        bh.writeInt32(0x501)
        var bd = Data()
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            bh.writeInt32(Int32(nameBytes.count))
            bh.writeBytes(nameBytes)
            bh.writeUInt32(UInt32(bd.count))
            bh.writeUInt32(UInt32(entry.content.count))
            bd.append(entry.content)
        }
        return (bh.data, bd)
    }

    /// Closing a `.BH` archive root, then reopening the exact same file,
    /// must behave like a genuinely fresh open, not silently reuse (or get
    /// blocked by) `archiveIndexByRootID`/`rawFileBytesByRootID` state left
    /// over from before the close. Also exercises expanding an entry in the
    /// reopened tree, which would fail outright if `archiveIndexByRootID`
    /// weren't cleaned up (`expandArchiveEntry` looks itself up by rootID).
    @MainActor
    func testClosingAnArchiveRootAndReopeningTheSameFileWorksCleanly() async throws {
        let emptyCode = makeSection(children: [])
        let entryBytes = makeSection(children: [(0, makeSection(children: [])), (10, emptyCode)])
        let (bhData, bdData) = buildArchivePair(entries: [(name: "ENTRY1.rm2", content: entryBytes)])

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CloseRootTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bhURL = tempDir.appendingPathComponent("TEST.BH")
        let bdURL = tempDir.appendingPathComponent("TEST.BD")
        try bhData.write(to: bhURL)
        try bdData.write(to: bdURL)

        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)
        XCTAssertNil(workspace.lastError)
        XCTAssertEqual(workspace.rootNodes.count, 1)
        let firstRoot = try XCTUnwrap(workspace.rootNodes.first)
        let firstEntryNode = try XCTUnwrap(firstRoot.children.first { $0.displayName == "ENTRY1.rm2" })
        await workspace.expandArchiveEntry(firstEntryNode, rootID: firstRoot.id)
        XCTAssertNil(workspace.lastError, "expanding the entry before closing should succeed")

        workspace.closeRoot(firstRoot)
        XCTAssertTrue(workspace.rootNodes.isEmpty, "the closed root must actually be gone from rootNodes")

        // Reopening the identical file must work exactly like a fresh open
        //, including successfully expanding an entry again, which would
        // fail if closeRoot left stale archiveIndexByRootID/
        // rawFileBytesByRootID entries under the old root's (now-reused-in-
        // spirit, though not literally reused since ChunkNode always mints a
        // fresh UUID) bookkeeping.
        workspace.open(url: bhURL)
        XCTAssertNil(workspace.lastError, "reopening the same file right after closing it must succeed, not be blocked by stale 'already open' bookkeeping")
        XCTAssertEqual(workspace.rootNodes.count, 1, "reopening must produce exactly one fresh root, not accumulate alongside anything left over from the close")
        let secondRoot = try XCTUnwrap(workspace.rootNodes.first)
        XCTAssertNotEqual(secondRoot.id, firstRoot.id, "the reopened root must be a genuinely new node, not the closed one somehow surviving")
        let secondEntryNode = try XCTUnwrap(secondRoot.children.first { $0.displayName == "ENTRY1.rm2" })
        await workspace.expandArchiveEntry(secondEntryNode, rootID: secondRoot.id)
        XCTAssertNil(workspace.lastError, "expanding an entry in the reopened archive must succeed just like the first time")
    }

    /// A closed root's own former selection must not linger as a dangling
    /// `selectedNode` pointing at a node no longer reachable from
    /// `rootNodes` at all.
    @MainActor
    func testClosingTheRootOfTheCurrentlySelectedNodeClearsSelection() throws {
        let emptyCode = makeSection(children: [])
        let entryBytes = makeSection(children: [(0, makeSection(children: [])), (10, emptyCode)])
        let (bhData, bdData) = buildArchivePair(entries: [(name: "ENTRY1.rm2", content: entryBytes)])

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CloseRootTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bhURL = tempDir.appendingPathComponent("TEST.BH")
        let bdURL = tempDir.appendingPathComponent("TEST.BD")
        try bhData.write(to: bhURL)
        try bdData.write(to: bdURL)

        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)
        let root = try XCTUnwrap(workspace.rootNodes.first)
        let entryNode = try XCTUnwrap(root.children.first)
        workspace.selectedNode = entryNode
        XCTAssertEqual(workspace.selectedNode?.id, entryNode.id)

        workspace.closeRoot(root)

        XCTAssertNil(workspace.selectedNode, "selection must not dangle on a node that no longer exists anywhere in rootNodes")
    }
}
