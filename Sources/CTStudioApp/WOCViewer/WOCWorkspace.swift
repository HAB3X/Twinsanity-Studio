import Foundation
import AppKit
import Observation

/// One level found under the WOC root -- a real `.GSC` file paired with
/// the level-folder name it lives in (`LEVELS/A/AIRSHIP/AIRSHIP.GSC` →
/// `"AIRSHIP"`).
public struct WOCLevelHubEntry: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let gscURL: URL
}

/// Separate from `WorkspaceViewModel` deliberately -- WoC is a different
/// game with a completely different file layout (no `.BD`/`.BH` archives,
/// no `ChunkNode` tree; see `WOCContainerParser`'s doc comment for the
/// format itself). Bolting a second, unrelated root/scan/asset system onto
/// the already large `WorkspaceViewModel` would blur what that type means;
/// this mirrors its `masterDirectoryURL` persistence pattern exactly, just
/// scoped to its own `ObservableObject`.
@MainActor
@Observable
public final class WOCWorkspace {
    public var rootURL: URL? {
        didSet {
            if let rootURL {
                UserDefaults.standard.set(rootURL.path, forKey: Self.rootDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.rootDefaultsKey)
            }
            rescanLevels()
        }
    }
    private static let rootDefaultsKey = "TwinsanityStudio.WOCRootURL"

    public private(set) var levels: [WOCLevelHubEntry] = []
    public private(set) var isScanning = false
    public var statusMessage: String?
    public var isLevelsHubPresented = false
    public var isSoundBrowserPresented = false
    public var isCharacterBrowserPresented = false

    /// `SFX.DAT` lives at the disc's top level, a sibling of `LEVELS/` --
    /// not inside it. Checked both directly under `rootURL` (root chosen
    /// as the disc mount itself) and under its parent (root chosen as the
    /// `LEVELS/` folder directly, per `chooseRoot()`'s prompt) so either
    /// choice `WOCLevelsHubView`'s picker allows also finds the archive.
    public var soundArchiveURL: URL? {
        archiveURL(named: "SFX.DAT")
    }

    /// Same top-level placement and lookup rule as `soundArchiveURL`, for
    /// `CHARS.DAT` (see `WOCCharacterArchiveParser`'s doc comment for
    /// what's decoded).
    public var characterArchiveURL: URL? {
        archiveURL(named: "CHARS.DAT")
    }

    private func archiveURL(named fileName: String) -> URL? {
        guard let rootURL else { return nil }
        let fm = FileManager.default
        let direct = rootURL.appendingPathComponent(fileName)
        if fm.fileExists(atPath: direct.path) { return direct }
        let sibling = rootURL.deletingLastPathComponent().appendingPathComponent(fileName)
        if fm.fileExists(atPath: sibling.path) { return sibling }
        return nil
    }

    /// Drives `WOCViewerWindowHost` exactly the way `WorkspaceViewModel.
    /// modelViewerAsset` etc. drive their own `Window` scenes -- nil ↔
    /// non-nil is the open/close signal.
    public var viewerAsset: WOCLevelAsset?

    public init() {
        // Was `_rootURL = Published(initialValue:)`, a property-wrapper-only
        // trick with no `@Observable` equivalent, to set the persisted
        // value without `didSet` firing (which would both redundantly
        // rewrite the same value back to `UserDefaults` and call
        // `rescanLevels()` a second time, on top of the unconditional call
        // below). Restructured instead: let `didSet` do its normal job in
        // the persisted-root case, and only call `rescanLevels()` directly
        // for the no-persisted-root case (where `didSet` never fires).
        if let path = UserDefaults.standard.string(forKey: Self.rootDefaultsKey) {
            rootURL = URL(fileURLWithPath: path)
        } else {
            rescanLevels()
        }
    }

    public func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Select"
        panel.message = "Select the WoC disc's LEVELS folder (e.g. the mounted disc's LEVELS/, or its parent)."
        if panel.runModal() == .OK, let url = panel.url {
            rootURL = url
        }
    }

    public func rescanLevels() {
        guard let rootURL else {
            levels = []
            return
        }
        isScanning = true
        let capturedRoot = rootURL
        Task.detached { [weak self] in
            let found = Self.scan(rootURL: capturedRoot)
            await MainActor.run { [weak self] in
                guard let self, self.rootURL == capturedRoot else { return }
                self.levels = found
                self.isScanning = false
            }
        }
    }

    /// Accepts either a `LEVELS` folder directly or a folder containing
    /// one (so pointing at the disc mount root also works) -- walks up to
    /// 2 levels of subdirectories looking for `.GSC` files, matching the
    /// real disc's `LEVELS/A|B|C/<LEVELNAME>/<LEVELNAME>.GSC` shape without
    /// hardcoding the `A`/`B`/`C` group names.
    private nonisolated static func scan(rootURL: URL) -> [WOCLevelHubEntry] {
        let fm = FileManager.default
        let searchRoot: URL
        if fm.fileExists(atPath: rootURL.appendingPathComponent("LEVELS").path) {
            searchRoot = rootURL.appendingPathComponent("LEVELS")
        } else {
            searchRoot = rootURL
        }

        var results: [WOCLevelHubEntry] = []
        guard let enumerator = fm.enumerator(at: searchRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        for case let url as URL in enumerator {
            guard url.pathExtension.uppercased() == "GSC" else { continue }
            let levelName = url.deletingPathExtension().lastPathComponent
            results.append(WOCLevelHubEntry(id: url.path, name: levelName, gscURL: url))
        }
        return results.sorted { $0.name < $1.name }
    }

    public func open(_ entry: WOCLevelHubEntry) async {
        statusMessage = "Loading \(entry.name)…"
        do {
            let asset = try await Task.detached {
                try WOCLevelLoader.load(gscURL: entry.gscURL, name: entry.name)
            }.value
            viewerAsset = asset
            statusMessage = nil
        } catch {
            statusMessage = "Failed to load \(entry.name): \(error)"
        }
    }
}
