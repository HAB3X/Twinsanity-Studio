import Foundation
import Observation

/// Performance/architecture fix (audit, "WorkspaceViewModel god-object"
/// finding): backs the app's "Open Recent" menu, persisted to
/// `UserDefaults` as bookmark-free path strings, most recent first,
/// deduplicated by path. Split out of `WorkspaceViewModel` into its own
/// `@Observable` leaf: every SwiftUI view that reads `workspace.
/// recentFileURLs` used to re-render on *any* `WorkspaceViewModel` mutation
/// (the god-object's whole surface was one observation unit), even a
/// completely unrelated one like a Model Viewer camera drag. Held as a
/// stored property on `WorkspaceViewModel`, itself independently
/// `@Observable`, so a view that only reads through to this store's own
/// properties is only invalidated when *this* store's own state actually
/// changes, see `WorkspaceViewModel`'s facade properties
/// (`recentFileURLs`/`clearRecentFiles()`) for how existing call sites
/// keep working completely unchanged.
@MainActor
@Observable
public final class RecentFilesStore {
    private static let defaultsKey = "TwinsanityStudio.RecentFileURLs"
    private static let maxRecentFiles = 10

    public private(set) var urls: [URL]

    public init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        urls = paths.map { URL(fileURLWithPath: $0) }
    }

    public func add(_ url: URL) {
        var updated = urls.filter { $0.path != url.path }
        updated.insert(url, at: 0)
        urls = Array(updated.prefix(Self.maxRecentFiles))
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.defaultsKey)
    }

    public func clear() {
        urls = []
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }
}
