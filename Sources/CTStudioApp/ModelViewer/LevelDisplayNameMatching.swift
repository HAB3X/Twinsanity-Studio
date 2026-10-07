import Foundation

/// The pure "is this the same level?"/"what's its bare archive base name?"
/// logic behind `LevelViewerWindow.isDestinationLevel(named:)` and
/// `performQuickLaunchThisChunk()`, pulled out as free functions (same
/// testability pattern as `DanglingReferenceChecker`) so a unit test can
/// exercise the exact comparison without a full View/renderer.
///
/// Real bug this fixes: `ChunkNode.displayName` holds the FULL archive path
/// (e.g. "Levels/Earth/Cavern/cavent") for a level reached by browsing into
/// a mounted disc/archive, not just the bare filename ("cavent"), but two
/// real call sites assumed `displayName` was always bare:
///
/// 1. Scenery mode's `isDestinationLevel(named:)` compared a candidate's
///    already-bare `SceneryLevelSource.displayName` (built via
///    `lastPathComponent` in `sceneryLevelSources`'s archive-index branch)
///    directly against `destinationSceneryFileRoot.displayName` with no
///    normalization on the destination side. When the destination was
///    reached by browsing a disc/archive, its `displayName` was a full
///    path, so it could never equal the bare candidate, producing
///    ".notFound" and "Couldn't identify this level."
/// 2. Quick Launch's `performQuickLaunchThisChunk()` derived
///    `startingChunkBaseName` as `(actorFileRoot.displayName as NSString)
///    .deletingPathExtension`, for a full-path `displayName` this yielded
///    "Levels/Earth/Cavern/cavent" instead of "cavent", which
///    `GameLauncher.building`'s own archive-entry matching (`entryBaseName`,
///    always `lastPathComponent`-normalized) could never match, producing
///    "isn't in this disc's archive."
///
/// `lastPathComponent` is a safe no-op on an already-bare string, so
/// normalizing both sides here fixes the disc/archive-browsed case without
/// risking the already-working standalone-file case.
enum LevelDisplayNameMatching {
    /// Whether two `ChunkNode`/`SceneryLevelSource` display names name the
    /// same real level, regardless of whether either side happens to be a
    /// bare filename or a full archive path.
    static func isSameLevel(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBare = (lhs as NSString).lastPathComponent
        let rhsBare = (rhs as NSString).lastPathComponent
        return lhsBare.caseInsensitiveCompare(rhsBare) == .orderedSame
    }

    /// The bare, extension-stripped base name `GameLauncher.building`'s own
    /// archive-entry matching expects (see its `entryBaseName` helper),
    /// derived from a `ChunkNode.displayName` that may be either bare or a
    /// full archive path.
    static func quickLaunchBaseName(fromDisplayName displayName: String) -> String {
        ((displayName as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
