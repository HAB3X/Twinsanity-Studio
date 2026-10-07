import SwiftUI
import CTModels
import CTExport

/// "Textures Hub" (QoL sweep): a searchable thumbnail grid of every decoded
/// texture in the workspace, the same role `ModelsHubView` plays for
/// models, browsing hundreds of textures as a flat name list (the sidebar)
/// doesn't give any visual sense of what's actually in them.
struct TexturesHubView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    /// "Embedded Library Panel": when this view is hosted inline in
    /// `DockedLibraryPanelView` rather than presented via `.sheet()`, there
    /// is no enclosing presentation for `\.dismiss` to act on (it's a silent
    /// no-op outside one), passing a real close action here lets the same
    /// "Close" button and post-selection dismissal both actually close the
    /// docked panel instead. `nil` (the default) preserves the original
    /// `.sheet()` behavior byte-for-byte.
    var onClose: (() -> Void)? = nil
    @State private var searchText = ""
    @State private var selected: TextureHubEntry?
    /// "Offline Texture Atlas Packer" (roadmap 12.3), batch selection,
    /// same on/off toggle + ID-set shape `ModelsHubView` already uses for
    /// its own batch export.
    @State private var isBatchSelectionMode = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var atlasError: String?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 520)
        .sheet(item: $selected) { entry in
            TextureHubDetailView(entry: entry)
                .environment(workspace)
        }
        .alert("Couldn't Pack Atlas", isPresented: Binding(
            get: { atlasError != nil },
            set: { if !$0 { atlasError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(atlasError ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Textures Hub").font(.title2.bold())
                Text(isBatchSelectionMode ? "\(selectedIDs.count) selected" : "\(filteredEntries.count) of \(workspace.texturesHub.count) textures")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if workspace.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            }
            if isBatchSelectionMode {
                Button("Pack into Atlas…") { packSelectedIntoAtlas() }
                    .disabled(selectedIDs.count < 2)
                Button("Cancel") {
                    isBatchSelectionMode = false
                    selectedIDs.removeAll()
                }
            } else {
                Button("Select…") { isBatchSelectionMode = true }
                    .disabled(workspace.texturesHub.isEmpty)
            }
            Button("Close") { close() }
        }
        .padding()
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// "Offline Texture Atlas Packer" (roadmap 12.3): packs every selected
    /// texture into one atlas PNG (`TextureAtlasPacker`, a standard
    /// shelf-packing algorithm, see that type's own doc comment). Doesn't
    /// attempt to rewrite any consuming mesh's UVs to match: that needs a
    /// specific mesh/submesh's material association, which this hub (a
    /// flat, cross-file texture list) doesn't carry, the packed atlas and
    /// its real per-texture placement rects are the honest deliverable
    /// here.
    private func packSelectedIntoAtlas() {
        let textures = workspace.texturesHub.filter { selectedIDs.contains($0.id) }.map(\.texture)
        guard !textures.isEmpty, let url = ExportPanel.chooseSaveLocation(
            suggestedName: "atlas.png",
            message: "Save the packed texture atlas (\(textures.count) textures)."
        ) else { return }
        do {
            let layout = try TextureAtlasPacker.exportAtlas(textures, to: url)
            workspace.statusMessage = "Saved \(url.lastPathComponent): \(layout.atlasWidth)×\(layout.atlasHeight), \(layout.placements.count) texture(s) packed."
            isBatchSelectionMode = false
            selectedIDs.removeAll()
        } catch {
            atlasError = error.localizedDescription
        }
    }

    private var controls: some View {
        TextField("Search textures by name or source file…", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if workspace.texturesHub.isEmpty {
            ContentUnavailableView(
                workspace.isScanning ? "Scanning…" : "No Textures Found Yet",
                systemImage: "photo.stack",
                description: Text(workspace.isScanning
                    ? "Textures will appear here as the archive scan finds them."
                    : "Load a .BH archive or a .RM2/.SM2 file. Scanning starts automatically.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredEntries.isEmpty {
            ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredEntries) { entry in
                        Button {
                            if isBatchSelectionMode {
                                if selectedIDs.contains(entry.id) { selectedIDs.remove(entry.id) } else { selectedIDs.insert(entry.id) }
                            } else {
                                selected = entry
                            }
                        } label: {
                            TextureThumbnailCell(entry: entry, isBatchSelectionMode: isBatchSelectionMode, isSelected: selectedIDs.contains(entry.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
        }
    }

    private var filteredEntries: [TextureHubEntry] {
        guard !searchText.isEmpty else { return workspace.texturesHub }
        return workspace.texturesHub.filter {
            "\($0.texture.id)".localizedCaseInsensitiveContains(searchText)
                || $0.sourceLabel.localizedCaseInsensitiveContains(searchText)
        }
    }
}

private struct TextureThumbnailCell: View {
    let entry: TextureHubEntry
    var isBatchSelectionMode: Bool = false
    var isSelected: Bool = false
    /// Decoding is a computed property recomputed on every `body`
    /// evaluation, cheap once, but `LazyVGrid` re-evaluates every
    /// currently-visible cell's `body` on each scroll-driven relayout, so an
    /// uncached version re-decodes the same bytes into a fresh
    /// `CGDataProvider`/`CGImage` repeatedly while scrolling through a large
    /// hub. Same fix shape as `InspectorView`'s cached `resolveComposite`
    /// elsewhere in this app: decode once into `@State`, keyed off the
    /// entry's own identity.
    @State private var cachedImage: NSImage?
    /// Distinct from "hasn't decoded yet" (`cachedImage == nil` before the
    /// `.task` below runs), this is only set once decode has genuinely
    /// failed, so the cell can show a real labeled placeholder instead of
    /// leaving the user staring at a spinner forever or an unlabeled
    /// warning triangle.
    @State private var decodeFailed = false

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let cachedImage {
                    Image(nsImage: cachedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if decodeFailed {
                    ZStack {
                        Color.red.opacity(0.18)
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(.red)
                            Text("#\(entry.texture.id)")
                                .font(.caption2.bold())
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 4)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 96, height: 96)
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : Color(.separatorColor), lineWidth: isSelected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if isBatchSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }

            Text("#\(entry.texture.id)")
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
            Text("\(entry.texture.width)×\(entry.texture.height) · \(entry.texture.pixelFormat.rawValue)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .task(id: entry.id) {
            guard let cgImage = try? TextureExporter.cgImage(from: entry.texture) else {
                decodeFailed = true
                return
            }
            cachedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }
}

private struct TextureHubDetailView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let entry: TextureHubEntry
    @State private var cachedImage: NSImage?
    /// `nil` until "Locate Parent Object" is pressed; `false` after a
    /// lookup comes back empty, so the "not found" message only shows
    /// after a real attempt, not before the user has asked.
    @State private var parentLookupSucceeded: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Texture #\(entry.texture.id)").font(.title3.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            if let cachedImage {
                Image(nsImage: cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Form {
                LabeledContent("Source File", value: entry.sourceLabel)
                LabeledContent("Dimensions", value: "\(entry.texture.width) × \(entry.texture.height)")
                LabeledContent("Pixel Format", value: entry.texture.pixelFormat.rawValue)
                LabeledContent("Mip Levels", value: "\(entry.texture.mips.count)")
            }
            .formStyle(.grouped)
            HStack {
                Button("Locate Parent Object") { locateParent() }
                Button("Export PNG…") { export() }
            }
            if parentLookupSucceeded == false {
                Label("Nothing currently loaded references this texture. It may be orphaned, or its referencing file hasn't been parsed this session.", systemImage: "questionmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 420)
        .task(id: entry.id) {
            guard let cgImage = try? TextureExporter.cgImage(from: entry.texture) else { return }
            cachedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    private func export() {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this texture into.") else { return }
        Task { await workspace.exportTexturePNG(entry.texture, suggestedName: "texture_\(entry.texture.id)", to: directory) }
    }

    private func locateParent() {
        guard let resolved = workspace.resolveComposite(forTextureID: entry.texture.id) else {
            parentLookupSucceeded = false
            return
        }
        parentLookupSucceeded = true
        workspace.modelViewerAsset = resolved
        dismiss()
    }
}
