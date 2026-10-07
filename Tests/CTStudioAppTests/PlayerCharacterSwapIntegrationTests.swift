import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// `WorkspaceViewModel.patchedFileBytes(...applyingPlayerCharacterSwap:...)`
///, the "Play As" panel's own save-path wiring: resolves the character's
/// real source file from the mounted disc's own archive index (the same
/// one `beach.rm2` itself was opened from) and folds
/// `CrossFileGameObjectCopier.resolvingPlayerCharacterReplacement`'s result
/// in. The underlying replacement itself is already covered end-to-end by
/// `PlayerCharacterReplacementTests`; this covers the wiring around it , 
/// archive-entry resolution, the early-return guard, and the real
/// `WorkspaceViewModel` save path a real "Play As" selection actually goes
/// through.
@MainActor
final class PlayerCharacterSwapIntegrationTests: XCTestCase {
    private func findNode(named bareName: String, in nodes: [ChunkNode]) -> ChunkNode? {
        for node in nodes {
            if (node.displayName as NSString).lastPathComponent.caseInsensitiveCompare(bareName) == .orderedSame { return node }
            if let found = findNode(named: bareName, in: node.children) { return found }
        }
        return nil
    }

    func testPlayerCharacterSwapReplacesGameObjectZeroInBeach() throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }

        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)
        XCTAssertEqual(workspace.rootNodes.count, 1)

        guard let archiveRoot = workspace.rootNodes.first,
              let beachEntryNode = findNode(named: "beach.rm2", in: archiveRoot.children)
        else { throw XCTSkip("beach.rm2 not found in the archive tree") }

        let expectation = expectation(description: "beach.rm2 expanded")
        Task {
            await workspace.expandArchiveEntry(beachEntryNode, rootID: archiveRoot.id)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 60)

        guard let beachFileRoot = findNode(named: "beach.rm2", in: workspace.rootNodes),
              CrossFileGameObjectCopier.hasNativeGameObject(objectID: 0, in: beachFileRoot)
        else { throw XCTSkip("beach.rm2 didn't expand into a real, parsed file root") }

        let patch = workspace.patchedFileBytes(
            applyingPrefixPatches: [],
            insertingNewInstances: [],
            insertingNewAIPositions: [],
            applyingPlayerCharacterSwap: .cortex,
            levelNode: beachFileRoot
        )
        guard let patch else { return XCTFail("expected a real patch, lastError=\(workspace.lastError ?? "none")") }

        let reparsed = try RM2Parser.parse(data: patch.primaryBytes, fileKind: .rm2, fileName: "beach.rm2")
        var gameObjects: [UInt32: GameObjectInfo] = [:]
        func walk(_ node: ChunkNode) {
            if case .gameObject(let g) = node.payload { gameObjects[node.recordID] = g }
            for c in node.children { walk(c) }
        }
        walk(reparsed)

        guard let replaced = gameObjects[0] else { return XCTFail("GameObject id 0 missing after the swap") }
        XCTAssertTrue(replaced.name.uppercased().contains("CORTEX"), "GameObject id 0 must now be Cortex's own real data, got name=\(replaced.name)")
    }

    /// Same real save path, Nina instead of Cortex, proves the "Play As"
    /// mechanism is genuinely character-agnostic, not something that only
    /// happens to work for the one character it was built against.
    func testPlayerCharacterSwapReplacesGameObjectZeroWithNinaInBeach() throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)
        guard let archiveRoot = workspace.rootNodes.first,
              let beachEntryNode = findNode(named: "beach.rm2", in: archiveRoot.children)
        else { throw XCTSkip("beach.rm2 not found in the archive tree") }
        let expectation = expectation(description: "beach.rm2 expanded")
        Task {
            await workspace.expandArchiveEntry(beachEntryNode, rootID: archiveRoot.id)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 60)
        guard let beachFileRoot = findNode(named: "beach.rm2", in: workspace.rootNodes) else {
            throw XCTSkip("beach.rm2 didn't expand into a real, parsed file root")
        }

        let patch = workspace.patchedFileBytes(
            applyingPrefixPatches: [],
            insertingNewInstances: [],
            insertingNewAIPositions: [],
            applyingPlayerCharacterSwap: .nina,
            levelNode: beachFileRoot
        )
        guard let patch else { return XCTFail("expected a real patch, lastError=\(workspace.lastError ?? "none")") }

        let reparsed = try RM2Parser.parse(data: patch.primaryBytes, fileKind: .rm2, fileName: "beach.rm2")
        var gameObjects: [UInt32: GameObjectInfo] = [:]
        func walk(_ node: ChunkNode) {
            if case .gameObject(let g) = node.payload { gameObjects[node.recordID] = g }
            for c in node.children { walk(c) }
        }
        walk(reparsed)
        guard let replaced = gameObjects[0] else { return XCTFail("GameObject id 0 missing after the swap") }
        XCTAssertTrue(replaced.name.uppercased().contains("NINA"), "GameObject id 0 must now be Nina's own real data, got name=\(replaced.name)")
        XCTAssertGreaterThan(replaced.animIDs.filter { $0 != 65535 }.count, 20, "the replaced object 0 must carry Nina's own real animations, not a stub")
    }

    /// Picking "Crash (Default)" (`nil`/id 0) must be a real no-op, no
    /// crash, no spurious patch, not silently attempt a "replacement"
    /// with itself.
    func testCrashDefaultSelectionProducesNoPatchWhenNothingElseIsPending() throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)
        guard let archiveRoot = workspace.rootNodes.first,
              let beachEntryNode = findNode(named: "beach.rm2", in: archiveRoot.children)
        else { throw XCTSkip("beach.rm2 not found in the archive tree") }
        let expectation = expectation(description: "beach.rm2 expanded")
        Task {
            await workspace.expandArchiveEntry(beachEntryNode, rootID: archiveRoot.id)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 60)
        guard let beachFileRoot = findNode(named: "beach.rm2", in: workspace.rootNodes) else {
            throw XCTSkip("beach.rm2 didn't expand into a real, parsed file root")
        }

        let patch = workspace.patchedFileBytes(
            applyingPrefixPatches: [],
            insertingNewInstances: [],
            insertingNewAIPositions: [],
            applyingPlayerCharacterSwap: .crash,
            levelNode: beachFileRoot
        )
        // No pending edits at all -> the early-return guard hands back the
        // *unmodified* bytes (not `nil`, `patchedFileBytes` only returns
        // `nil` on a real failure), so GameObject 0 must still be whatever
        // it already was, not Cortex.
        let unpatched = try XCTUnwrap(patch)
        let reparsed = try RM2Parser.parse(data: unpatched.primaryBytes, fileKind: .rm2, fileName: "beach.rm2")
        var gameObjects: [UInt32: GameObjectInfo] = [:]
        func walk(_ node: ChunkNode) {
            if case .gameObject(let g) = node.payload { gameObjects[node.recordID] = g }
            for c in node.children { walk(c) }
        }
        walk(reparsed)
        XCTAssertFalse(gameObjects[0]?.name.uppercased().contains("CORTEX") ?? false, "picking Crash (Default) alone must not replace GameObject 0")
    }
}
