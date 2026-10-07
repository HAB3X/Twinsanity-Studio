import XCTest
import CTCore
import CTParsers
import CTModels
import CTExport
@testable import CTStudioApp

/// "Connect Chunks" (`WorkspaceViewModel.availableChunkLinkTargets`) and
/// "Create New Chunks/Levels, Chunk Cloning" (`WorkspaceViewModel.
/// cloningChunk`), s letting a user point one
/// chunk's `ChunkLink` at another already-open chunk without typing its
/// archive path by hand, and duplicate an existing chunk into a brand-new,
/// separately-editable archive entry.
@MainActor
final class ChunkConnectivityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkConnectivityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeSyntheticArchive(named base: String, entries: [(name: String, bytes: [UInt8])]) throws -> URL {
        let bhURL = tempDir.appendingPathComponent("\(base).BH")
        let bdURL = tempDir.appendingPathComponent("\(base).BD")
        var bh = BinaryWriter()
        bh.writeInt32(0x501)
        var bd = Data()
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            bh.writeInt32(Int32(nameBytes.count))
            bh.writeBytes(nameBytes)
            bh.writeUInt32(UInt32(bd.count))
            bh.writeUInt32(UInt32(entry.bytes.count))
            bd.append(contentsOf: entry.bytes)
        }
        try bh.data.write(to: bhURL)
        try bd.write(to: bdURL)
        return bhURL
    }

    // MARK: - availableChunkLinkTargets

    func testAvailableChunkLinkTargetsFindsSceneryEntriesFromAnOpenArchive() throws {
        let bhURL = try writeSyntheticArchive(named: "test1", entries: [
            ("Levels/Earth/Hub/beach.sm2", [1, 2, 3]),
            ("Levels/Earth/Hub/beach.rm2", [4, 5, 6]), // not scenery -- must be excluded
            ("Levels/Earth/Cavern/cavent.smx", [7, 8, 9]),
        ])
        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)

        let targets = workspace.availableChunkLinkTargets()
        XCTAssertEqual(Set(targets.map(\.path)), ["Levels/Earth/Hub/beach", "Levels/Earth/Cavern/cavent"])
        XCTAssertTrue(targets.contains { $0.displayName == "beach" })
    }

    func testAvailableChunkLinkTargetsIsEmptyWithNoOpenArchives() {
        let workspace = WorkspaceViewModel()
        XCTAssertEqual(workspace.availableChunkLinkTargets(), [])
    }

    func testAvailableChunkLinkTargetsPathIsReadyToAssignToChunkLinkPath() throws {
        // Real, load-bearing property: the returned `path` must be exactly
        // what `loadChunkLinkPlacements` matches against (full path, `\`
        // normalized to `/`, no extension) -- not just a display string.
        let bhURL = try writeSyntheticArchive(named: "test2", entries: [
            ("Levels\\Earth\\Hub\\beach.sm2", [1]),
        ])
        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)

        let targets = workspace.availableChunkLinkTargets()
        XCTAssertEqual(targets.map(\.path), ["Levels/Earth/Hub/beach"])
    }

    // MARK: - cloningChunk (real disc, XCTSkip if absent)

    private static let isoURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/Crash Twinsanity (USA) (v1.00).iso")

    private func skipIfMissing() throws {
        guard FileManager.default.fileExists(atPath: Self.isoURL.path) else {
            throw XCTSkip("Real retail ISO not present at \(Self.isoURL.path) on this machine.")
        }
    }

    /// Extracts the real disc's own `.BH`/`.BD` pair to `tempDir`, the
    /// same real archive `cloningChunk` will end up rebuilding, opened
    /// here as a standalone archive (synchronous, no disc-mount polling
    /// needed) purely so a real `sceneryFileRoot` node, with the exact
    /// same `displayName`/entry-name shape `cloningChunk` expects, exists
    /// to hand it.
    private func openRealArchiveStandalone() throws -> (workspace: WorkspaceViewModel, archiveRoot: ChunkNode) {
        let isoData = try Data(contentsOf: Self.isoURL, options: .mappedIfSafe)
        let source = PlainISOSource(data: isoData)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        guard let (bhEntry, bdEntry) = Self.locateArchivePair(in: root),
              let bhData = ISO9660Reader.readFile(bhEntry, from: source),
              let bdData = ISO9660Reader.readFile(bdEntry, from: source)
        else { throw XCTSkip("Couldn't locate the real disc's own .BH/.BD archive pair.") }

        let bhURL = tempDir.appendingPathComponent((bhEntry.name as NSString).lastPathComponent)
        let bdURL = tempDir.appendingPathComponent((bdEntry.name as NSString).lastPathComponent)
        try bhData.write(to: bhURL)
        try bdData.write(to: bdURL)

        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)
        guard let archiveRoot = workspace.rootNodes.first else { throw XCTSkip("Opening the real archive standalone didn't produce a root node.") }
        return (workspace, archiveRoot)
    }

    func testCloningChunkInsertsBothSceneryAndSiblingActorFilesIntoTheRealDisc() async throws {
        try skipIfMissing()
        let (workspace, archiveRoot) = try openRealArchiveStandalone()
        guard let sceneryNode = archiveRoot.children.first(where: { ($0.displayName as NSString).lastPathComponent.caseInsensitiveCompare("beach.sm2") == .orderedSame }) else {
            throw XCTSkip("beach.sm2 not found in the real disc's archive.")
        }

        let scratchISO = tempDir.appendingPathComponent("scratch.iso")
        try FileManager.default.copyItem(at: Self.isoURL, to: scratchISO)
        workspace.discImageURL = scratchISO

        let outcome = await workspace.cloningChunk(sceneryFileRoot: sceneryNode, newBaseName: "beach_unittest_clone")
        guard case .success(let result) = outcome else {
            return XCTFail("Expected cloningChunk to succeed, got \(outcome)")
        }
        XCTAssertTrue(result.sceneryEntryName.lowercased().hasSuffix("beach_unittest_clone.sm2"))
        XCTAssertNotNil(result.actorEntryName, "beach.sm2 has a real beach.rm2 sibling on the retail disc -- it must have been cloned too")

        // Independently re-read the scratch disc image back and confirm
        // both new entries genuinely exist with the source's real bytes.
        let rebuiltData = try Data(contentsOf: scratchISO, options: .mappedIfSafe)
        let rebuiltSource = PlainISOSource(data: rebuiltData)
        let rebuiltRoot = try ISO9660Reader.readRootDirectory(from: rebuiltSource)
        guard let (bhEntry, bdEntry) = Self.locateArchivePair(in: rebuiltRoot),
              let bhData = ISO9660Reader.readFile(bhEntry, from: rebuiltSource),
              let bdData = ISO9660Reader.readFile(bdEntry, from: rebuiltSource)
        else { return XCTFail("Couldn't re-read the archive pair from the saved scratch disc.") }
        let readbackDir = tempDir.appendingPathComponent("readback")
        try FileManager.default.createDirectory(at: readbackDir, withIntermediateDirectories: true)
        let readbackBH = readbackDir.appendingPathComponent((bhEntry.name as NSString).lastPathComponent)
        let readbackBD = readbackDir.appendingPathComponent((bdEntry.name as NSString).lastPathComponent)
        try bhData.write(to: readbackBH)
        try bdData.write(to: readbackBD)
        let index = try BDArchiveParser.readIndex(bhURL: readbackBH)

        guard let clonedScenery = index.entries.first(where: { $0.name.caseInsensitiveCompare(result.sceneryEntryName) == .orderedSame }) else {
            return XCTFail("Cloned scenery entry \(result.sceneryEntryName) not found in the saved disc's own archive.")
        }
        let originalSceneryBytes = try BDArchiveParser.readEntryData(
            index.entries.first { $0.name.caseInsensitiveCompare(sceneryNode.displayName) == .orderedSame }!, index: index
        )
        XCTAssertEqual(try BDArchiveParser.readEntryData(clonedScenery, index: index), originalSceneryBytes)

        if let actorEntryName = result.actorEntryName {
            XCTAssertNotNil(index.entries.first { $0.name.caseInsensitiveCompare(actorEntryName) == .orderedSame }, "Cloned actor entry \(actorEntryName) not found in the saved disc's own archive.")
        }
    }

    func testCloningChunkWithACollidingNameFails() async throws {
        try skipIfMissing()
        let (workspace, archiveRoot) = try openRealArchiveStandalone()
        guard let sceneryNode = archiveRoot.children.first(where: { ($0.displayName as NSString).lastPathComponent.caseInsensitiveCompare("beach.sm2") == .orderedSame }) else {
            throw XCTSkip("beach.sm2 not found in the real disc's archive.")
        }
        let scratchISO = tempDir.appendingPathComponent("scratch_collision.iso")
        try FileManager.default.copyItem(at: Self.isoURL, to: scratchISO)
        workspace.discImageURL = scratchISO

        // "beach" itself already exists -- must be refused, not silently overwritten.
        let outcome = await workspace.cloningChunk(sceneryFileRoot: sceneryNode, newBaseName: "beach")
        guard case .failure(let error) = outcome else {
            return XCTFail("Expected cloningChunk to fail on a name collision, got \(outcome)")
        }
        guard case .nameCollision = error else {
            return XCTFail("Expected .nameCollision, got \(error)")
        }
    }

    func testCloningChunkWithAnInvalidNameFailsWithoutTouchingTheDisc() async throws {
        try skipIfMissing()
        let (workspace, archiveRoot) = try openRealArchiveStandalone()
        guard let sceneryNode = archiveRoot.children.first(where: { ($0.displayName as NSString).lastPathComponent.caseInsensitiveCompare("beach.sm2") == .orderedSame }) else {
            throw XCTSkip("beach.sm2 not found in the real disc's archive.")
        }
        let scratchISO = tempDir.appendingPathComponent("scratch_invalid.iso")
        try FileManager.default.copyItem(at: Self.isoURL, to: scratchISO)
        workspace.discImageURL = scratchISO
        let originalBytes = try Data(contentsOf: scratchISO)

        let outcome = await workspace.cloningChunk(sceneryFileRoot: sceneryNode, newBaseName: "bad/name")
        guard case .failure(.invalidName) = outcome else {
            return XCTFail("Expected .invalidName, got \(outcome)")
        }
        XCTAssertEqual(try Data(contentsOf: scratchISO), originalBytes, "an invalid name must fail before ever touching the disc image")
    }

    // MARK: - Helpers

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
