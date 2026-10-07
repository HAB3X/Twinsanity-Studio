import Foundation
import CTExport

/// "Remember + auto-save the Level Viewer" (app-lifecycle sweep), the
/// pure, unit-testable core of a deliberately *narrow* quit-time safety
/// net: this covers exactly one source of pending edits in the whole app,
/// `LevelViewerRenderer`'s own `pendingLevelOverrides`/
/// `pendingAIWaypointOverrides`/`pendingAIPathArgOverrides`/`pendingNewInstances`/etc
/// (position/rotation changes, new/deleted instances, AI waypoint edits,
/// AI Path start/end edits, the same
/// state `LevelViewerWindow.computingPendingOverridePatch()` already
/// gathers for "Save Chunk Overrides…"/"Quick Launch…"). It does **not**
/// cover every other editor's own separate pending-edit state (Recipe
/// Book, Shader Graph Editor, sound/texture inspectors, PTC Sheets, Agent
/// Lab, …), those are real, separate, much larger future work; quitting
/// with unsaved changes in any of *those* still quits silently, exactly
/// as before this file existed.

/// Pure "does this specific set of pending Level Viewer edits count as
/// dirty" check, factored out of `LevelViewerWindow.
/// computingPendingOverridePatch()`'s own guard condition so quit-time
/// dirty-checking has one real, directly unit-testable answer to ask
/// instead of hand-duplicating that guard's condition list a second time
/// and risking the two drifting apart. Takes plain counts, not the actual
/// renderer, so a test can exercise every combination without a live
/// `LevelViewerRenderer`/GPU context at all.
enum LevelViewerDirtyCheck {
    static func isDirty(
        levelOverrideCount: Int,
        aiWaypointOverrideCount: Int,
        aiPathArgOverrideCount: Int,
        cameraControlPointOverrideCount: Int,
        newInstanceCount: Int,
        newAIPositionCount: Int,
        newTriggerCount: Int,
        newCameraCount: Int,
        newAIPathCount: Int,
        removedInstanceCount: Int,
        removedTriggerCount: Int,
        removedCameraCount: Int,
        removedAIPositionCount: Int,
        removedAIPathCount: Int
    ) -> Bool {
        levelOverrideCount > 0
            || aiWaypointOverrideCount > 0
            || aiPathArgOverrideCount > 0
            || cameraControlPointOverrideCount > 0
            || newInstanceCount > 0
            || newAIPositionCount > 0
            || newTriggerCount > 0
            || newCameraCount > 0
            || newAIPathCount > 0
            || removedInstanceCount > 0
            || removedTriggerCount > 0
            || removedCameraCount > 0
            || removedAIPositionCount > 0
            || removedAIPathCount > 0
    }
}

extension LevelViewerRenderer {
    /// True when this session has any real pending edit that "Save Chunk
    /// Overrides…"/"Quick Launch…"/the quit-time autosave below would
    /// actually write, the exact same condition `computingPendingOverridePatch()`
    /// guards on, asked here as a plain, always-available property so
    /// app-level code (the quit hook) can check it without needing this
    /// renderer's owning `LevelViewerWindow` view to still be around to ask.
    var hasPendingEdits: Bool {
        LevelViewerDirtyCheck.isDirty(
            levelOverrideCount: pendingLevelOverrides.count,
            aiWaypointOverrideCount: pendingAIWaypointOverrides.count,
            aiPathArgOverrideCount: pendingAIPathArgOverrides.count,
            cameraControlPointOverrideCount: pendingCameraControlPointOverrides.count,
            newInstanceCount: pendingNewInstances.count,
            newAIPositionCount: pendingNewAIPositions.count,
            newTriggerCount: pendingNewTriggers.count,
            newCameraCount: pendingNewCameras.count,
            newAIPathCount: pendingNewAIPaths.count,
            removedInstanceCount: pendingRemovedInstanceIDs.count,
            removedTriggerCount: pendingRemovedTriggerIDs.count,
            removedCameraCount: pendingRemovedCameraIDs.count,
            removedAIPositionCount: pendingRemovedAIPositionIDs.count,
            removedAIPathCount: pendingRemovedAIPathIDs.count
        )
    }
}

/// Everything the quit-time autosave (or any other non-`LevelViewerWindow`
/// caller) needs to actually write this session's pending Level Viewer
/// edits somewhere real, the same three pieces `computingPendingOverridePatch()`
/// plus `performQuickLaunchThisChunk()`'s own `actorFileRoot.displayName`
/// lookup already produce, just packaged so they can cross from
/// `LevelViewerWindow` (a transient View struct) onto `WorkspaceViewModel`
/// (see `currentLevelViewerPendingPatchProvider`) without either side
/// needing a direct reference to the other's live view state.
public struct LevelViewerPendingPatch {
    /// The archive entry's own display name (e.g. "cavent.rm2") , 
    /// `GameLauncher.building`/`rebuildingAndVerifying` matches
    /// `GameLaunchPlan.archiveReplacements` keys against the disc's real
    /// archive index by this same bare name, exactly as `performQuickLaunchThisChunk`
    /// already relies on.
    public var archiveEntryDisplayName: String
    public var patchedBytes: Data
    /// Scenery's own archive entry, almost always a genuinely different
    /// file (`.sm2`) than `archiveEntryDisplayName`'s (`.rm2`), present
    /// only when there was a pending scenery edit and it lives separately.
    /// See `WorkspaceViewModel.LevelOverridePatch`'s own doc comment for
    /// why this can't just be folded into `patchedBytes`.
    public var sceneryArchiveEntryDisplayName: String?
    public var sceneryPatchedBytes: Data?
    public var summary: String

    public init(archiveEntryDisplayName: String, patchedBytes: Data, sceneryArchiveEntryDisplayName: String? = nil, sceneryPatchedBytes: Data? = nil, summary: String) {
        self.archiveEntryDisplayName = archiveEntryDisplayName
        self.patchedBytes = patchedBytes
        self.sceneryArchiveEntryDisplayName = sceneryArchiveEntryDisplayName
        self.sceneryPatchedBytes = sceneryPatchedBytes
        self.summary = summary
    }
}

/// The thin, real bridge from "a pending Level Viewer patch" to "a
/// rebuilt-and-independently-reverified disc image", reuses
/// `GameLauncher.rebuildingAndVerifying` exactly as `GameLauncherView`'s own
/// "Save changes to this ISO" toggle does (see that file's `buildAndLaunch`),
/// rather than inventing a second archive-patching pipeline. Deliberately
/// stops at "produce verified bytes" and never writes them anywhere itself , 
/// writing the result over the real mounted disc image (or a fallback
/// location on failure) is the caller's job (`WorkspaceViewModel.
/// savingPendingLevelViewerEditsToMountedDisc`), so this stays a pure,
/// safely-testable function that can never itself touch, let alone
/// corrupt, a real file.
enum LevelViewerDiscAutosave {
    static func rebuildingAndVerifying(patch: LevelViewerPendingPatch, isoURL: URL, scratchDirectory: URL) throws -> GameLauncher.RebuildResult {
        // Real, reported bug ("Update Collision for Moved Objects" , 
        // confirmed, waited, nothing on disk ever changed): `archiveEntryDisplayName`'s
        // own doc comment claims this is always "this same bare name," but
        // its one real construction site (`LevelViewerWindow`'s
        // `currentLevelViewerPendingPatchProvider`) hands over `ChunkNode.
        // displayName`/`patch.sceneryFileDisplayName` verbatim, a *full*
        // archive path ("Levels/Earth/Hub/beach.sm2") for any level reached
        // by browsing a mounted disc/archive, exactly the same "displayName
        // isn't always bare" trap `LevelDisplayNameMatching`'s own doc
        // comment already documents fixing for `performQuickLaunchThisChunk`
        // specifically. `GameLauncher.building`'s own archive-entry matching
        // only ever compares *bare* names, so a full-path key here never
        // matched anything, the save silently failed with
        // `.levelNotFoundInArchive`, reported to the user as "verification
        // failed," on every archive-browsed level, every time. Normalizing
        // here (not just at that one call site) fixes it for every real and
        // future caller of this function, not only the one that happened to
        // already remember to.
        var replacements = [(patch.archiveEntryDisplayName as NSString).lastPathComponent: patch.patchedBytes]
        if let sceneryName = patch.sceneryArchiveEntryDisplayName, let sceneryBytes = patch.sceneryPatchedBytes {
            replacements[(sceneryName as NSString).lastPathComponent] = sceneryBytes
        }
        let plan = GameLaunchPlan(archiveReplacements: replacements)
        return try GameLauncher.rebuildingAndVerifying(isoURL: isoURL, plan: plan, scratchDirectory: scratchDirectory)
    }
}
