import Foundation
import Observation
import SwiftUI

/// Performance/architecture fix (audit, "WorkspaceViewModel god-object"
/// finding): the Settings/Preferences-window state that's genuinely
/// independent of the workspace's actual chunk tree, accent color, the
/// master directory/disc-image/PCSX2 app picker paths. Split out of
/// `WorkspaceViewModel` for the same reason as `RecentFilesStore` (see its
/// own doc comment): a real, separately-invalidating `@Observable` leaf
/// instead of one more slice of the god-object's single giant observation
/// surface. Deliberately does *not* include everything that lived under
/// the old "Settings" `// MARK:` in `WorkspaceViewModel`, `showRawFiles`,
/// `detectedRegion`, `filteredRootNodes`, and `hasUnscannedArchives` were
/// filed there by physical proximity, not because they're actually
/// settings: each is tightly coupled to the core chunk-tree/filter-cache
/// state (`filterInputsGeneration`, `rootNodes`) and moving them here would
/// just relocate the coupling, not remove it, they stay on
/// `WorkspaceViewModel` itself.
@MainActor
@Observable
public final class AppSettingsStore {
    /// "Theme/Appearance": an in-app control tint, applied via `.tint(...)`
    /// at `ContentView`'s root, this is a real, working native SwiftUI
    /// mechanism, not a claim about overriding macOS's own system-wide
    /// accent color (which no sandboxed or unsandboxed app can actually do;
    /// System Settings owns that).
    public enum AccentColorChoice: String, CaseIterable, Identifiable {
        case blue, purple, pink, red, orange, yellow, green, teal, indigo
        public var id: String { rawValue }
        public var color: Color {
            switch self {
            case .blue: return .blue
            case .purple: return .purple
            case .pink: return .pink
            case .red: return .red
            case .orange: return .orange
            case .yellow: return .yellow
            case .green: return .green
            case .teal: return .teal
            case .indigo: return .indigo
            }
        }
        public var displayName: String { rawValue.capitalized }
    }

    private static let accentColorDefaultsKey = "TwinsanityStudio.AccentColorChoice"
    private static let masterDirectoryDefaultsKey = "TwinsanityStudio.MasterDirectoryURL"
    private static let discImageURLDefaultsKey = "TwinsanityStudio.DiscImageURL"
    private static let lastMountedDiscImageURLDefaultsKey = "TwinsanityStudio.LastMountedDiscImageURL"
    private static let pcsx2AppURLDefaultsKey = "TwinsanityStudio.PCSX2AppURL"

    public var accentColorChoice: AccentColorChoice = .blue {
        didSet { UserDefaults.standard.set(accentColorChoice.rawValue, forKey: Self.accentColorDefaultsKey) }
    }

    /// "Directory Config": the folder Settings' "Choose…" picker points at
    ///, surfaced in the sidebar's empty state as a real "Open Master
    /// Directory" action (`SidebarView`), not just stored inertly.
    public var masterDirectoryURL: URL? {
        didSet {
            if let masterDirectoryURL {
                UserDefaults.standard.set(masterDirectoryURL.path, forKey: Self.masterDirectoryDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.masterDirectoryDefaultsKey)
            }
        }
    }

    /// "Direct Boot/Launch": the real, bootable disc image `GameLauncher`
    /// patches and boots, a plain `.iso` only (see `ISO9660Writer`'s own
    /// doc comment on why `.bin`/`.cue` isn't supported for write-back).
    public var discImageURL: URL? {
        didSet {
            if let discImageURL {
                UserDefaults.standard.set(discImageURL.path, forKey: Self.discImageURLDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.discImageURLDefaultsKey)
            }
        }
    }

    /// "Remember the last mounted disc" (app-lifecycle sweep): the source
    /// `.iso`/`.bin`/`.cue` most recently *successfully* mounted via
    /// `WorkspaceViewModel.mountDiscImage(url:)`, restored here and
    /// automatically re-mounted on the next launch (see
    /// `WorkspaceViewModel.autoRemountLastDiscImageIfAvailable`). Kept as a
    /// separate property from `discImageURL` (the Direct Boot/Launch
    /// target above): that one only ever tracks a plain `.iso` and the user
    /// is free to repoint it away from whatever's actually mounted at any
    /// time, whereas this tracks every successful mount regardless of
    /// format and is never touched by anything except `mountDiscImage`
    /// itself.
    public var lastMountedDiscImageURL: URL? {
        didSet {
            if let lastMountedDiscImageURL {
                UserDefaults.standard.set(lastMountedDiscImageURL.path, forKey: Self.lastMountedDiscImageURLDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastMountedDiscImageURLDefaultsKey)
            }
        }
    }

    /// The real PCSX2 app (or its bundled binary) `GameLauncher.launching`
    /// runs the built image with.
    public var pcsx2AppURL: URL? {
        didSet {
            if let pcsx2AppURL {
                UserDefaults.standard.set(pcsx2AppURL.path, forKey: Self.pcsx2AppURLDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pcsx2AppURLDefaultsKey)
            }
        }
    }

    /// Guards `WorkspaceViewModel.autoRemountLastDiscImageIfAvailable`
    /// against actually re-mounting more than once per process, see that
    /// method's own doc comment.
    public var hasAttemptedAutoRemount = false

    public init() {
        if let rawAccent = UserDefaults.standard.string(forKey: Self.accentColorDefaultsKey), let accent = AccentColorChoice(rawValue: rawAccent) {
            accentColorChoice = accent
        }
        if let path = UserDefaults.standard.string(forKey: Self.masterDirectoryDefaultsKey) {
            masterDirectoryURL = URL(fileURLWithPath: path)
        }
        if let path = UserDefaults.standard.string(forKey: Self.discImageURLDefaultsKey) {
            discImageURL = URL(fileURLWithPath: path)
        }
        if let path = UserDefaults.standard.string(forKey: Self.lastMountedDiscImageURLDefaultsKey) {
            lastMountedDiscImageURL = URL(fileURLWithPath: path)
        }
        if let path = UserDefaults.standard.string(forKey: Self.pcsx2AppURLDefaultsKey) {
            pcsx2AppURL = URL(fileURLWithPath: path)
        }
    }
}
