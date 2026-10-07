import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTStudioApp

/// Regression tests for a real, user-reported bug: `ChunkNode.displayName`
/// holds the FULL archive path (e.g. "Levels/Earth/Cavern/cavent") for a
/// level reached by browsing into a mounted disc/archive, not just the bare
/// filename ("cavent"), confirmed against this codebase's own real archive
/// data (`LevelViewerAssetIndexSiblingTests` looks entries up by exactly
/// this full-path form, e.g. "levels/earth/hub/hubb.sm2"). Two real call
/// sites assumed `displayName` was always bare and compared/derived from it
/// directly, so the comparison silently never matched for any disc/archive-
/// browsed level:
///
/// 1. Scenery mode's `isDestinationLevel(named:)` -> "Couldn't identify this
///    level."
/// 2. Quick Launch's `performQuickLaunchThisChunk()` -> "isn't in this
///    disc's archive."
///
/// Both now route through `LevelDisplayNameMatching`, extracted as a small,
/// testable pure type (same pattern as `DanglingReferenceChecker`) since the
/// View's own methods are private.
@MainActor
final class LevelDisplayNameMatchingTests: XCTestCase {
    // MARK: - isSameLevel (the `isDestinationLevel(named:)` comparison)

    func testIsSameLevelMatchesFullArchivePathAgainstBareFilename() {
        // Exactly the reported scenario: the destination level's own
        // `displayName` is a full archive path (disc/archive-browsed),
        // while a candidate from the archive-index branch of
        // `sceneryLevelSources` is already bare.
        XCTAssertTrue(LevelDisplayNameMatching.isSameLevel("cavent.sm2", "Levels/Earth/Cavern/cavent.sm2"))
        XCTAssertTrue(LevelDisplayNameMatching.isSameLevel("Levels/Earth/Cavern/cavent.sm2", "cavent.sm2"))
    }

    func testIsSameLevelMatchesTwoFullArchivePaths() {
        XCTAssertTrue(LevelDisplayNameMatching.isSameLevel("Levels/Earth/Cavern/cavent.sm2", "Levels/Earth/Cavern/cavent.sm2"))
    }

    func testIsSameLevelMatchesTwoBareFilenames() {
        // The already-working case must keep working.
        XCTAssertTrue(LevelDisplayNameMatching.isSameLevel("cavent.sm2", "cavent.sm2"))
    }

    func testIsSameLevelIsCaseInsensitive() {
        XCTAssertTrue(LevelDisplayNameMatching.isSameLevel("Levels/Earth/Cavern/CAVENT.SM2", "cavent.sm2"))
    }

    func testIsSameLevelRejectsGenuinelyDifferentLevels() {
        XCTAssertFalse(LevelDisplayNameMatching.isSameLevel("Levels/Earth/Hub/beach.sm2", "cavent.sm2"))
    }

    // MARK: - quickLaunchBaseName (the `performQuickLaunchThisChunk` derivation)

    func testQuickLaunchBaseNameStripsFullArchivePathAndExtension() {
        // Exactly the reported scenario: without `lastPathComponent`
        // normalization this used to yield "Levels/Earth/Cavern/cavent",
        // which `GameLauncher.building`'s own bare-`lastPathComponent`
        // archive-entry matching (`entryBaseName`) could never match.
        XCTAssertEqual(
            LevelDisplayNameMatching.quickLaunchBaseName(fromDisplayName: "Levels/Earth/Cavern/cavent.sm2"),
            "cavent"
        )
    }

    func testQuickLaunchBaseNameIsANoOpOnAnAlreadyBareDisplayName() {
        // The already-working (standalone-opened-file) case must keep working.
        XCTAssertEqual(LevelDisplayNameMatching.quickLaunchBaseName(fromDisplayName: "cavent.sm2"), "cavent")
    }

    func testQuickLaunchBaseNameHandlesMixedCaseArchivePath() {
        // Real archive entries in this codebase's own index use
        // forward-slash-separated paths (confirmed by
        // `LevelViewerAssetIndexSiblingTests`, which looks entries up by
        // exactly "levels/earth/hub/hubb.sm2"), pin that shape explicitly
        // since it's the one `NSString.lastPathComponent` actually splits on.
        XCTAssertEqual(
            LevelDisplayNameMatching.quickLaunchBaseName(fromDisplayName: "Levels/Earth/Cavern/CAVENT.SM2"),
            "CAVENT"
        )
    }

    // MARK: - `WorkspaceViewModel.sceneryLevelSources`'s sibling instance of the same bug

    /// Minimal `SceneryData`-bearing `ChunkNode` whose file-root
    /// `displayName` is a full archive path, exactly like a level reached
    /// by browsing into a mounted disc/archive, `otherLevelSceneryFileRoots`
    /// only requires `sceneryNode(in:)` to find a real `.scenery` payload
    /// somewhere in the tree.
    private func makeSceneryFileRoot(displayName: String) -> ChunkNode {
        let sceneryAsset = SceneryAsset(
            id: 1, chunkName: "test", skydomeID: nil,
            ambientLights: [], directionalLights: [], pointLights: [], negativeLights: [], root: nil
        )
        let sceneryChild = ChunkNode(recordID: 1, sectionType: .null, displayName: "SceneryData", byteSize: 0, fileOffset: 0, payload: .scenery(sceneryAsset))
        return ChunkNode(recordID: 0, sectionType: .null, displayName: displayName, byteSize: 0, fileOffset: 0, children: [sceneryChild])
    }

    /// Real bug this fixes: `sceneryLevelSources`'s `otherLevelSceneryFileRoots`
    /// branch used `root.displayName` raw for its own `SceneryLevelSource
    /// .displayName`, unlike the archive-index branch right below it,
    /// which already normalized via `lastPathComponent`. For a level
    /// reached by browsing into a mounted disc/archive (a full-path
    /// `displayName`), this leaked the full path into the picker instead
    /// of a clean bare filename.
    func testSceneryLevelSourcesNormalizesFullPathDisplayNameFromOpenFileRoot() {
        let workspace = WorkspaceViewModel()
        let fileRoot = makeSceneryFileRoot(displayName: "Levels/Earth/Cavern/cavent.sm2")
        workspace.rootNodes = [fileRoot]

        let sources = workspace.sceneryLevelSources(excluding: nil)

        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.displayName, "cavent.sm2", "expected the bare filename, not the full archive path")
    }

    /// Real bug this fixes: the `excluding:` parameter's own `seenNames`
    /// exclusion key was built from the raw, un-normalized
    /// `destinationSceneryFileRoot.displayName`, for a disc/archive-browsed
    /// destination level (full-path `displayName`), this key could never
    /// match the now-bare-normalized key the `otherLevelSceneryFileRoots`
    /// loop inserts, so the destination level would silently stop being
    /// excluded from its own "borrow scenery from another level" picker.
    func testSceneryLevelSourcesExcludesDestinationLevelEvenWithFullPathDisplayName() {
        let workspace = WorkspaceViewModel()
        let fileRoot = makeSceneryFileRoot(displayName: "Levels/Earth/Cavern/cavent.sm2")
        workspace.rootNodes = [fileRoot]

        let sources = workspace.sceneryLevelSources(excluding: fileRoot)

        XCTAssertTrue(sources.isEmpty, "the destination level itself should never be offered as a source to borrow scenery from")
    }
}
