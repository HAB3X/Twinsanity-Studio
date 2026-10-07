import Foundation
import Observation
import CTModels

/// Performance/architecture fix (audit, "WorkspaceViewModel god-object"
/// finding): a PS2 memory card image is "a completely separate document
/// type from the `.BD`/`.RM2` workspace tree, it has nothing to do with
/// Twinsanity's own formats" (original doc comment on
/// `WorkspaceViewModel.openMemoryCard`), which makes it as clean a leaf as
/// `RecentFilesStore`/`AppSettingsStore` to split out, see their own doc
/// comments for why this reduces unrelated-view re-render churn.
/// `WorkspaceViewModel.openMemoryCard(url:)` itself stays on the parent
/// (it also sets `statusMessage`/`lastError`, core cross-domain state), just
/// writing through to this store's `asset` instead of a property of its own.
@MainActor
@Observable
public final class MemoryCardInspectorStore {
    /// Non-nil presents the Memory Card Inspector sheet (see `ContentView`).
    public var asset: MemoryCardAsset?

    public init() {}
}
