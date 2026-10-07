import SwiftUI
import CTModels

/// "Visual Levels Hub": a card-per-level gallery over `workspace.levelsHub`,
/// the same "browse the parsed-out parent objects visually instead of
/// hunting through the sidebar tree" idea `ModelsHubView`'s gallery mode
/// already applies to models, here applied to whole levels. Each card is a
/// decoded `SceneryData` record with a non-empty placement tree, clicking
/// one resolves it and opens the same `LevelViewerWindow` the Scenery
/// inspector's "Open Level Viewer" button does (`WorkspaceViewModel.
/// openLevelViewer`), so there's exactly one level-loading code path
/// regardless of entry point.
///
/// Cards use a stylized icon rather than a rendered 3D thumbnail: resolving
/// a level's placements (mesh + material + texture lookups, potentially
/// thousands of objects) is real work already done lazily on click, doing
/// it eagerly for every card just to render a thumbnail would mean
/// resolving every level in the workspace up front, the exact "freezes the
/// UI" problem `resolvedLevelPlacements` was written to avoid.
struct LevelsHubView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    /// "Embedded Library Panel": see `TexturesHubView.onClose`'s doc
    /// comment, same reasoning, same default-preserving shape, for the
    /// Chunk Hub's own docked-panel embedding.
    var onClose: (() -> Void)? = nil
    @State private var searchText = ""
    @State private var loadingEntryID: LevelHubEntry.ID?

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
                Text("Chunk Hub").font(.title2.bold())
                Text("\(filteredLevels.count) of \(workspace.levelsHub.count) chunks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if workspace.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            }
            Button("Close") { close() }
        }
        .padding()
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var controls: some View {
        TextField("Search levels by name or source file…", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if workspace.levelsHub.isEmpty {
            ContentUnavailableView(
                workspace.isScanning ? "Scanning…" : "No Chunks Found Yet",
                systemImage: "map",
                description: Text(workspace.isScanning
                    ? "Chunks will appear here as the archive scan decodes their scenery data."
                    : "Load a .BH archive or a .RM2/.SM2 file, scanning starts automatically.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredLevels.isEmpty {
            ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filteredLevels) { entry in
                        // Code review: this used to disable only the
                        // clicked card, every other card stayed clickable
                        // while a level was already loading, so a second
                        // click could start an overlapping `openLevelViewer`
                        // call before the first finished (the exact
                        // "no shared loading-state gate" gap). `isAnyLoading`
                        // (workspace.isOpeningLevelViewer, shared across all
                        // three real entry points) now disables the whole
                        // grid while any load is in flight; `isLoading`
                        // still scopes the spinner to just this one card.
                        LevelCard(entry: entry, isLoading: loadingEntryID == entry.id, isAnyLoading: workspace.isOpeningLevelViewer) {
                            open(entry)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func open(_ entry: LevelHubEntry) {
        loadingEntryID = entry.id
        Task {
            await workspace.openLevelViewer(for: entry.scenery, node: entry.node)
            loadingEntryID = nil
            close()
        }
    }

    private var filteredLevels: [LevelHubEntry] {
        guard !searchText.isEmpty else { return workspace.levelsHub }
        return workspace.levelsHub.filter {
            displayName(for: $0).localizedCaseInsensitiveContains(searchText)
                || $0.sourceLabel.localizedCaseInsensitiveContains(searchText)
        }
    }
}

private func displayName(for entry: LevelHubEntry) -> String {
    entry.scenery.chunkName.isEmpty ? entry.sourceLabel : entry.scenery.chunkName
}

private struct LevelCard: View {
    let entry: LevelHubEntry
    let isLoading: Bool
    let isAnyLoading: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    LinearGradient(colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if isLoading {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: "map.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .aspectRatio(1.4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: entry))
                        .font(.callout.bold())
                        .lineLimit(1)
                    Text("\(entry.scenery.placements.count) placement(s)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isAnyLoading)
    }
}
