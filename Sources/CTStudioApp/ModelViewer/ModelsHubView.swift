import SwiftUI
import CTModels

/// A flat, globally searchable list of every model resolved so far , 
/// "Global Asset Indexing": rather than hunting through the chunk tree for a
/// specific RigidModel or rigged skeleton, this is every one of them, from
/// every scanned file, in one place. Clicking a row loads it straight into
/// the Model Viewer using the *already-resolved* asset, no re-parsing, no
/// tree walking, so this is also the most reliable way to open the viewer.
struct ModelsHubView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    /// Set when this hub is docked into the main window's detail column
    /// (see `DetailColumn`); `nil` when it's still presented as a `.sheet`.
    var onClose: (() -> Void)? = nil
    @State private var searchText = ""
    @State private var onlyRigged = false
    @State private var onlyFullyTextured = false
    @State private var isBatchSelectionMode = false
    @State private var selectedIDs: Set<ResolvedModelAsset.ID> = []
    /// "Parent Objects Gallery": a second, visual presentation of the exact
    /// same `workspace.modelsHub` data the list view already shows , 
    /// `modelsHub` is already every *resolved composite* (a complete
    /// character/vehicle/prop: mesh + skeleton + textures), never a loose
    /// texture/bone/collision mesh, so it's already the "parent objects,
    /// clutter filtered out" set this needs; no separate data source or
    /// filtering logic to build.
    @State private var displayMode: DisplayMode = .list
    /// Rendered lazily (only for cards actually scrolled into view, see
    /// `GalleryCard.onAppear`) and cached here for the rest of this sheet's
    /// lifetime, so scrolling back to an already-seen card is instant
    /// instead of re-running a full offscreen Metal render.
    @State private var thumbnailCache: [ResolvedModelAsset.ID: NSImage] = [:]
    /// Tracked separately from `thumbnailCache` (not folded into it as a
    /// generic placeholder image) so `GalleryCard` can tell "still loading"
    /// apart from "genuinely failed to render" and draw the latter as a
    /// real, per-model labeled box instead of one indistinguishable stock
    /// icon for every failure.
    @State private var failedThumbnailIDs: Set<ResolvedModelAsset.ID> = []

    private enum DisplayMode {
        case list, gallery
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Models Hub").font(.title2.bold())
                if let progress = workspace.batchExportProgress {
                    Text("Exporting \(progress.completed) of \(progress.total)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(filteredModels.count) of \(workspace.modelsHub.count) models")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if workspace.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            }
            if let progress = workspace.batchExportProgress {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .frame(width: 100)
            } else if isBatchSelectionMode {
                Button("Export Selected (\(selectedIDs.count))…") { exportSelected() }
                    .disabled(selectedIDs.isEmpty)
                Button("Cancel") {
                    isBatchSelectionMode = false
                    selectedIDs.removeAll()
                }
            } else {
                Button("Select…") { isBatchSelectionMode = true }
                    .disabled(workspace.modelsHub.isEmpty)
            }
            Picker("", selection: $displayMode) {
                Image(systemName: "list.bullet").tag(DisplayMode.list)
                Image(systemName: "square.grid.2x2").tag(DisplayMode.gallery)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 90)
            Button("Close") { closeHub() }
        }
        .padding()
    }

    /// Routes to the docked-panel dismissal when embedded in `DetailColumn`,
    /// or the sheet dismissal when still presented as a `.sheet`.
    private func closeHub() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("Search models by name…", text: $searchText)
                .textFieldStyle(.roundedBorder)
            Toggle("Rigged only", isOn: $onlyRigged)
                .toggleStyle(.checkbox)
            Toggle("Fully textured only", isOn: $onlyFullyTextured)
                .toggleStyle(.checkbox)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if workspace.modelsHub.isEmpty {
            ContentUnavailableView(
                workspace.isScanning ? "Scanning…" : "No Models Found Yet",
                systemImage: "cube.transparent",
                description: Text(workspace.isScanning
                    ? "Models will appear here as the archive scan finds them."
                    : "Load a .BH archive or a .RM2/.SM2 file, scanning starts automatically.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredModels.isEmpty {
            ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try a different search or clear the filters above."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayMode == .gallery {
            gallery
        } else {
            List(filteredModels) { model in
                if isBatchSelectionMode {
                    Button {
                        toggleSelection(model.id)
                    } label: {
                        HStack {
                            Image(systemName: selectedIDs.contains(model.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(model.id) ? Color.accentColor : Color.secondary)
                            ModelsHubRow(model: model)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        workspace.modelViewerAsset = model
                        closeHub()
                    } label: {
                        ModelsHubRow(model: model)
                    }
                    .buttonStyle(.plain)
                    // "Drag-and-Drop Asset Palette" (blueprint 6.2): drags
                    // the model's UUID, not the model itself, a
                    // `ResolvedModelAsset` carries real GPU-scale mesh/
                    // texture data, and `Transferable` serialization is the
                    // wrong tool for handing that between two windows in
                    // the same process. The Level Viewer's drop target
                    // looks the UUID back up in `workspace.modelsHub`.
                    .draggable(model.id.uuidString)
                }
            }
            .listStyle(.plain)
        }
    }

    /// "Parent Objects Gallery": a `LazyVGrid` of thumbnail cards, one per
    /// resolved composite, `LazyVGrid` (not `VGrid`/a plain `HStack`
    /// wrapping) is load-bearing here, not decorative, same reasoning as
    /// the hex viewer's `LazyVStack`: a full workspace can resolve
    /// hundreds of models, and only cards actually scrolled into view
    /// should exist as real views (and, by extension, only those should
    /// ever trigger a real offscreen 3D thumbnail render).
    private var gallery: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 14)], spacing: 14) {
                ForEach(filteredModels) { model in
                    GalleryCard(
                        model: model,
                        thumbnail: thumbnailCache[model.id],
                        thumbnailFailed: failedThumbnailIDs.contains(model.id),
                        isBatchSelectionMode: isBatchSelectionMode,
                        isSelected: selectedIDs.contains(model.id),
                        onTap: { galleryCardTapped(model) }
                    )
                    .onAppear { loadThumbnailIfNeeded(for: model) }
                    .draggable(model.id.uuidString)
                }
            }
            .padding(14)
        }
    }

    private func galleryCardTapped(_ model: ResolvedModelAsset) {
        if isBatchSelectionMode {
            toggleSelection(model.id)
        } else {
            // Opens straight into the Metal Asset Viewer, which is itself
            // the "deep hierarchy" view for an already-resolved composite
            //, its own Components section lists every linked material/
            // texture (and, for rigged models, skeleton/animations), the
            // same relationship the sidebar's Relational Chain panel shows
            // for a tree-selected node. A gallery card only carries a
            // `ResolvedModelAsset`, not a specific source `ChunkNode` (the
            // same composite can legitimately resolve from more than one
            // reference in the workspace), so there's no single sidebar
            // tree node to jump the main selection to here.
            workspace.modelViewerAsset = model
            closeHub()
        }
    }

    /// Renders one thumbnail off the main thread (`ModelViewerRenderer`'s
    /// offscreen path is plain Metal + CoreGraphics, no AppKit/SwiftUI
    /// state touched, and `MTLCommandQueue` is documented safe to use
    /// concurrently from multiple threads) so scrolling through a large
    /// gallery doesn't stall on GPU work, only skipped if already cached.
    private func loadThumbnailIfNeeded(for model: ResolvedModelAsset) {
        guard thumbnailCache[model.id] == nil, !failedThumbnailIDs.contains(model.id) else { return }
        Task.detached(priority: .userInitiated) {
            let image = await ModelThumbnailRenderer.render(model, size: 256)
            await MainActor.run {
                if let image {
                    thumbnailCache[model.id] = image
                } else {
                    failedThumbnailIDs.insert(model.id)
                }
            }
        }
    }

    private var filteredModels: [ResolvedModelAsset] {
        workspace.modelsHub.filter { model in
            (searchText.isEmpty || model.displayName.localizedCaseInsensitiveContains(searchText))
                && (!onlyRigged || model.skeleton != nil)
                && (!onlyFullyTextured || model.isFullyTextured)
        }
    }

    private func toggleSelection(_ id: ResolvedModelAsset.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// "One-Click Batch Export" (blueprint 3.1): one destination folder
    /// picker, then `WorkspaceViewModel.exportBatch` queues every selected
    /// model's full complete-asset export (mesh + textures + animations)
    /// into its own subfolder underneath it.
    private func exportSelected() {
        let assets = workspace.modelsHub.filter { selectedIDs.contains($0.id) }
        guard !assets.isEmpty, let directory = ExportPanel.chooseFolder(message: "Choose a folder to export \(assets.count) selected model(s) into, each gets its own subfolder.") else { return }
        isBatchSelectionMode = false
        selectedIDs.removeAll()
        Task { await workspace.exportBatch(assets, to: directory) }
    }
}

private struct ModelsHubRow: View {
    let model: ResolvedModelAsset

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.skeleton != nil ? "figure.stand" : "cube.fill")
                .foregroundStyle(model.skeleton != nil ? .orange : .teal)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(model.mesh.submeshes.count) submeshes")
                    Text("· \(model.mesh.totalVertexCount) verts")
                    if model.skeleton != nil {
                        Text("· rigged")
                    }
                    if !model.availableAnimations.isEmpty {
                        Text("· \(model.availableAnimations.count) anim(s)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.isFullyTextured {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Some submeshes have no resolved texture")
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

/// "YouTube-style" parent-object gallery card: a square thumbnail (a real
/// offscreen 3D render of the resolved model, see `ModelThumbnailRenderer`
///, not a generic placeholder icon) plus a title/subtitle strip underneath,
/// the same two-tier layout video-thumbnail grids use.
private struct GalleryCard: View {
    let model: ResolvedModelAsset
    let thumbnail: NSImage?
    let thumbnailFailed: Bool
    let isBatchSelectionMode: Bool
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                thumbnailView
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color(.separatorColor), lineWidth: isSelected ? 2 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if isBatchSelectionMode {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                                .shadow(radius: 2)
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if model.skeleton != nil {
                            Image(systemName: "figure.stand")
                                .font(.caption2)
                                .padding(4)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .padding(4)
                        }
                    }

                Text(model.displayName)
                    .font(.caption.bold())
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text("\(model.mesh.totalVertexCount) verts\(model.isFullyTextured ? "" : " · untextured")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(6)
        } else if thumbnailFailed {
            NamedPlaceholderBox(
                name: model.displayName,
                systemImage: model.skeleton != nil ? "figure.stand" : "cube.fill",
                color: model.skeleton != nil ? .orange : .teal
            )
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}

/// "Redesigned Asset Hubs": the fallback state when a real thumbnail
/// couldn't be generated, not a bare stock icon with no context, but the
/// asset's own name laid directly over a color-coded box (color keyed to
/// the same type distinction the list-view icons already use), so a card
/// with a failed render is still immediately identifiable at a glance.
private struct NamedPlaceholderBox: View {
    let name: String
    let systemImage: String
    let color: Color

    var body: some View {
        ZStack {
            color.opacity(0.22)
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(color)
                Text(name)
                    .font(.caption2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// Caps how many offscreen thumbnail renders run at once, app-wide.
/// `ModelThumbnailRenderer.render` does a real, synchronous Metal render
/// (`renderOffscreen`'s own `commandBuffer.waitUntilCompleted()`) plus a
/// brand-new GPU buffer/texture upload for its own scratch
/// `ModelViewerRenderer`, cheap for the Models Hub's one grid of already-
/// loaded assets, but the Scenery tab's `LazyVGrid` can fire dozens of
/// these `.onAppear`-triggered renders within the same moment (this
/// level's own catalog plus every other level's, streaming in
/// concurrently), each on its own `Task.detached` with no throttle at
/// all. That many concurrent real GPU renders visibly starves the live
/// 3D viewport's own draw loop for the same GPU, the "the whole app
/// goes slow the instant Scenery starts loading" symptom. A small fixed
/// cap keeps thumbnails arriving steadily without swamping the GPU the
/// live viewport also depends on every frame.
private actor ThumbnailRenderThrottle {
    static let shared = ThumbnailRenderThrottle()
    /// Was 2, still real, reported viewport slowdown while the Scenery
    /// tab is loading with two renders concurrently (a shared-memory GPU
    /// has only one physical set of execution units regardless of how
    /// many separate `MTLCommandQueue`s submit to it, so even two
    /// concurrent heavy offscreen renders can still add real per-frame
    /// latency to whatever the live viewport is drawing at the same
    /// moment). Down to strict serialization, trades thumbnail-loading
    /// speed (still streams in continuously, just one at a time) for
    /// leaving the live viewport as much GPU headroom as this throttle can
    /// give it.
    private static let maxConcurrent = 1
    private var availableSlots = maxConcurrent
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if availableSlots > 0 {
            availableSlots -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            availableSlots = min(Self.maxConcurrent, availableSlots + 1)
        }
    }
}

/// Real offscreen 3D thumbnails for the Parent Objects Gallery, reuses
/// `ModelViewerRenderer.renderOffscreen`, the exact same rendering path
/// this session's own automated snapshot test uses to verify the Metal
/// pipeline against real game data, rather than a fabricated placeholder
/// icon standing in for "the model itself."
enum ModelThumbnailRenderer {
    static func render(_ asset: ResolvedModelAsset, size: Int) async -> NSImage? {
        await ThumbnailRenderThrottle.shared.acquire()
        defer { Task { await ThumbnailRenderThrottle.shared.release() } }
        guard let renderer = ModelViewerRenderer(asset: asset), renderer.hasGeometry,
              let cgImage = renderer.renderOffscreen(width: size, height: size)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
