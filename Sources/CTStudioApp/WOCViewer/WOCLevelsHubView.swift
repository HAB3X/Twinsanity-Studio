import SwiftUI

/// Mirrors `LevelsHubView`'s shape for WoC levels, driven by
/// `WOCWorkspace` instead of `WorkspaceViewModel`.
struct WOCLevelsHubView: View {
    @Environment(WOCWorkspace.self) private var wocWorkspace
    @Environment(\.dismiss) private var dismiss
    /// Set when docked into the main window's detail column (see
    /// `DetailColumn`); nil when still presented as a `.sheet`.
    var onClose: (() -> Void)? = nil
    @State private var searchText = ""
    @State private var loadingEntryID: WOCLevelHubEntry.ID?

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Wrath of Cortex Levels").font(.title2.bold())
                if wocWorkspace.rootURL != nil {
                    Text("\(filteredLevels.count) of \(wocWorkspace.levels.count) levels")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if wocWorkspace.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            }
            Button("Choose Folder…") { wocWorkspace.chooseRoot() }
            Button("Close") { (onClose ?? { dismiss() })() }
        }
        .padding()
    }

    private var controls: some View {
        TextField("Search levels by name…", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if wocWorkspace.rootURL == nil {
            ContentUnavailableView(
                "No WoC Folder Selected",
                systemImage: "folder.badge.questionmark",
                description: Text("Choose the mounted WoC disc (or its LEVELS folder) to browse real levels.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if wocWorkspace.levels.isEmpty {
            ContentUnavailableView(
                wocWorkspace.isScanning ? "Scanning…" : "No Levels Found",
                systemImage: "map",
                description: Text(wocWorkspace.isScanning ? "Looking for .GSC files…" : "No .GSC files were found under the selected folder.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredLevels.isEmpty {
            ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filteredLevels) { entry in
                        WOCLevelCard(entry: entry, isLoading: loadingEntryID == entry.id) {
                            open(entry)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func open(_ entry: WOCLevelHubEntry) {
        loadingEntryID = entry.id
        Task {
            await wocWorkspace.open(entry)
            loadingEntryID = nil
            (onClose ?? { dismiss() })()
        }
    }

    private var filteredLevels: [WOCLevelHubEntry] {
        guard !searchText.isEmpty else { return wocWorkspace.levels }
        return wocWorkspace.levels.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

private struct WOCLevelCard: View {
    let entry: WOCLevelHubEntry
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    LinearGradient(colors: [.orange.opacity(0.35), .orange.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if isLoading {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: "globe.americas.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .aspectRatio(1.4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(entry.name)
                    .font(.callout.bold())
                    .lineLimit(1)
            }
            .padding(8)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}
