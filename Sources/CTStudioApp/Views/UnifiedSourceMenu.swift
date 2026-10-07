import SwiftUI

/// The single top-left control for getting data into the app. Replaces the
/// scattered set of entry points the toolbar used to have, a bare "Open…"
/// button, plus "Open Memory Card", "Mount Disc Image" and "Open as Monkey
/// Ball" buried three levels deep in the old `Library ▾` mega-menu, plus
/// "Reopen recent" that only ever showed inside the sidebar's empty state.
///
/// Its label reflects the *current* primary source (mounted disc or first
/// open file), so the toolbar always says what you're looking at.
struct UnifiedSourceMenu: View {
    @Environment(WorkspaceViewModel.self) private var workspace

    var body: some View {
        Menu {
            SourceMenuItems()
        } label: {
            Label(currentSourceLabel, systemImage: "tray.and.arrow.down")
        }
        .help("Open a folder or file, mount a disc image, or load a memory card.")
    }

    private var currentSourceLabel: String {
        if let disc = workspace.lastMountedDiscImageURL { return disc.lastPathComponent }
        if let first = workspace.rootNodes.first { return first.displayName }
        return "Open"
    }
}

/// Shared menu body, rendered verbatim inside `UnifiedSourceMenu`'s toolbar
/// `Menu` and inside the "More ways to open…" menu on the empty state, so
/// the two never drift.
struct SourceMenuItems: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    private var actions: SourceActions { SourceActions(workspace: workspace) }

    var body: some View {
        Section("Open") {
            Button {
                actions.chooseFolderOrFile()
            } label: {
                Label("Choose Folder or File…", systemImage: "folder")
            }
            Button {
                actions.mountDiscImage()
            } label: {
                Label("Mount Disc Image…", systemImage: "opticaldiscdrive")
            }
            Button {
                actions.openMemoryCard()
            } label: {
                Label("Open Memory Card…", systemImage: "mediastick")
            }
            Button {
                actions.openAsMonkeyBall()
            } label: {
                Label("Open as Monkey Ball…", systemImage: "circle.grid.2x2")
            }
        }

        if !workspace.recentFileURLs.isEmpty {
            Section("Recent") {
                ForEach(workspace.recentFileURLs.prefix(8), id: \.path) { url in
                    Button(url.lastPathComponent) { workspace.open(url: url) }
                }
                Divider()
                Button("Clear Menu", role: .destructive) { workspace.clearRecentFiles() }
            }
        }

        if let master = workspace.masterDirectoryURL {
            Section("Shortcuts") {
                Button {
                    actions.openMasterDirectory()
                } label: {
                    Label("Master Directory (\(master.lastPathComponent))", systemImage: "star")
                }
            }
        }

        if let disc = workspace.lastMountedDiscImageURL {
            Section("Mounted Disc") {
                Label(disc.lastPathComponent, systemImage: "opticaldiscdrive.fill")
                Button(role: .destructive) {
                    workspace.unmountDiscImage()
                } label: {
                    Label("Eject", systemImage: "eject")
                }
            }
        }
    }
}
