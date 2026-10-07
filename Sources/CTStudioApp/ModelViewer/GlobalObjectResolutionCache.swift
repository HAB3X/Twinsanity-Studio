import Foundation
import CTModels

/// "Forge Palette anywhere", the user's own ask: "I want the thumbnail to
/// load in the forge palette even if the level is not loaded." Before this,
/// the Forge Palette only ever resolved a real thumbnail for an object ID
/// through three sources: the currently open level's own `assetIndex`, the
/// shared `Default.rm2` fallback, and whatever some *other* level already
/// resolved this session (`WorkspaceViewModel.globalObjectThumbnails`). An
/// object whose only real geometry lives in a level nobody has opened yet
/// showed a permanent placeholder cube even though the disc almost
/// certainly has it somewhere.
///
/// This class owns exactly the state a palette row needs to show an honest
/// in-between state while that search runs: which object IDs are currently
/// being searched, and which have been confirmed to resolve nowhere on this
/// disc (so "still checking" is never visually indistinguishable from
/// "checked everywhere, genuinely nothing", a real, explicit requirement).
/// The actual search logic, enumerating every mounted archive's `.rm2`/
/// `.rmx` entries, parsing each one's own `GraphicsAssetIndex` (cached, never
/// re-parsed), and racing a handful of concurrent lanes through the
/// candidate list, lives on `WorkspaceViewModel.
/// resolvingObjectIDAcrossAllLevels(_:)`, which already owns every other
/// piece of archive-reading/caching state (`archiveIndexByRootID`,
/// `sharedDefaultAssetIndexTask`, `globalObjectThumbnails`) this needed to
/// reuse. This class is purely the orchestration/UI-facing half: "have I
/// already started (or finished) looking for this one?"
///
/// Owned the same way `SceneryLoadCache` is: a `@State` on
/// `LevelViewerWindow` (this class is `@Observable`, not a legacy
/// `ObservableObject`, so `@State`, not `@StateObject`, is the correct
/// owner, same reasoning as `SceneryLoadCache`'s own doc comment), so it
/// survives switching `editorMode` away from the Forge Palette tab and back
/// without losing in-flight/confirmed search state.
@MainActor
@Observable
final class GlobalObjectResolutionCache {
    enum SearchStatus: Equatable {
        /// A background search across every other level this session can
        /// reach is currently running for this object ID.
        case searching
        /// Every real level this session can reach was checked and none of
        /// them resolved this object ID to real geometry, a real, honest
        /// "nothing here," not a still-loading state. See
        /// `WorkspaceViewModel.confirmedUnresolvableObjectIDs`'s own doc
        /// comment for real, permanently-unresolvable examples.
        case confirmedNowhere
    }

    /// No entry means "never searched yet", `search(objectID:workspace:)`
    /// is what starts one. An entry is removed entirely on success (the
    /// object's real resolution now lives in `workspace.
    /// globalObjectThumbnails`, which is the actual source of truth every
    /// other consumer already checks, this cache has no reason to also
    /// remember "resolved," only "currently looking" and "confirmed
    /// nowhere").
    private(set) var statusByObjectID: [UInt16: SearchStatus] = [:]

    /// The current search/confirmed-nowhere state for `objectID`, or `nil`
    /// if no search has ever been kicked off for it (either it resolved
    /// through one of the three existing, always-checked-first sources, or
    /// nothing has asked about it yet).
    func status(for objectID: UInt16) -> SearchStatus? {
        statusByObjectID[objectID]
    }

    /// Real, reported performance bug: each visible, unresolved palette row
    /// independently calls `search(objectID:workspace:)`, and each one used
    /// to kick off its own `resolvingObjectIDAcrossAllLevels` call
    /// immediately, itself already internally bounded to 4 concurrent
    /// lanes (see that function's own `laneCount`), but with no cap
    /// *across* different object IDs searched at once. Scrolling past a
    /// burst of ~10-15 unresolved rows could start that many simultaneous
    /// disc-wide searches, up to 40-60 concurrent archive parses in
    /// total, directly competing for CPU with whatever else is running,
    /// the Level Viewer's own rendering included. Capping how many
    /// searches actually run at once and queuing the rest keeps the total
    /// concurrent archive-parsing work bounded regardless of how many rows
    /// scroll into view at once, every object ID still eventually gets
    /// searched, just not all in the same instant.
    private static let maxConcurrentSearches = 2
    private var activeSearchCount = 0
    private var pendingObjectIDs: [UInt16] = []

    /// Kicks off a bounded, non-blocking background search for `objectID`
    /// across every other real level this session can reach, but only if
    /// one isn't already running or already confirmed nowhere. Safe to call
    /// on every single row appearance (a beginner scrolling the palette up
    /// and down repeatedly): the guard below makes every call after the
    /// first a genuine no-op for that object ID, so a permanently-
    /// unresolvable ID never re-triggers a full disc scan just because its
    /// row scrolled back into view.
    func search(objectID: UInt16, workspace: WorkspaceViewModel) {
        guard statusByObjectID[objectID] == nil else { return }
        statusByObjectID[objectID] = .searching
        guard activeSearchCount < Self.maxConcurrentSearches else {
            pendingObjectIDs.append(objectID)
            return
        }
        startSearch(objectID: objectID, workspace: workspace)
    }

    /// All archive reads and parses happen off the main thread inside
    /// `WorkspaceViewModel.resolvingObjectIDAcrossAllLevels` (see its own
    /// doc comment), only this method's own state bookkeeping runs here,
    /// on the main actor, which is exactly where `@Observable` needs the
    /// mutation to happen for SwiftUI to pick up the change.
    private func startSearch(objectID: UInt16, workspace: WorkspaceViewModel) {
        activeSearchCount += 1
        // Real lifecycle bug: this class is deliberately kept alive across
        // Level Viewer tab switches (see this type's own doc comment), but
        // a strongly-captured `self` here meant closing the window mid-
        // search kept the whole cache alive until the scan across every
        // mounted archive's .rm2/.rmx entries finished. `[weak self]`
        // matches the convention every other Task/MainActor.run touching
        // `self` in `WorkspaceViewModel` already uses.
        Task { [weak self] in
            let resolved = await workspace.resolvingObjectIDAcrossAllLevels(objectID)
            guard let self else { return }
            if resolved != nil {
                // `resolvingObjectIDAcrossAllLevels` already recorded this
                // into `workspace.globalObjectThumbnails` on success, every
                // consumer of that dictionary (including this same palette's
                // own `canResolve`/`resolveForThumbnail` closures) picks it
                // up automatically the next time they're read, since
                // `WorkspaceViewModel` is `@Observable`. Removing the entry
                // here (rather than tracking a third "resolved" status) is
                // what lets `status(for:)` go back to `nil`, which the
                // palette treats the same as "resolvable through the normal
                // path" once `workspace.globalObjectThumbnails` actually has it.
                statusByObjectID[objectID] = nil
            } else {
                statusByObjectID[objectID] = .confirmedNowhere
            }
            activeSearchCount -= 1
            if !pendingObjectIDs.isEmpty {
                let next = pendingObjectIDs.removeFirst()
                startSearch(objectID: next, workspace: workspace)
            }
        }
    }
}
