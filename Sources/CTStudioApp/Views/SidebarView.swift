import SwiftUI
import CTCore
import CTModels

struct SidebarView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    /// "Multi-Select & Batch Operations" (QoL sweep), a separate toggled
    /// mode rather than switching `List`'s own selection to a `Set`
    /// binding: the single-selection binding below is what drives
    /// `InspectorView`/`ViewportPanel` throughout the rest of the app, and
    /// this mirrors the exact same batch-mode pattern `ModelsHubView`
    /// already uses rather than touching that wiring.
    @State private var isBatchSelectionMode = false
    @State private var batchSelectedIDs: Set<UUID> = []

    var body: some View {
        // `@Bindable` shadow for `.searchable(text: $workspace.searchQuery...)`
        // below -- `filterBar` needs its own separate shadow for
        // `$workspace.typeFilter`, since a local variable declared here
        // isn't visible from that other computed property's own scope.
        @Bindable var workspace = workspace
        // `filteredRootNodes` is a computed property that re-walks the whole
        // tree (raw-content pruning, then type filter, then search filter , 
        // up to three full passes) on every single access, with no
        // memoization of its own (see its doc comment). This body used to
        // call it twice unconditionally, every render, once for `ForEach`,
        // once for the empty-state check, doubling that cost for no reason
        // once a large archive is fully scanned. Computed once here and
        // reused for those two, same fix shape as `SceneryInspectorView.
        // placements`. Deliberately *not* reused inside the selection
        // `Binding`'s `set` below, which keeps its own fresh
        // `workspace.filteredRootNodes` call: that closure fires later, at
        // click time, and `workspace` (unlike this local `let`) always
        // reflects whatever the tree looks like *then*, e.g. a background
        // scan that finished between this render and the click. Reusing the
        // render-time snapshot there would resolve a click against a
        // possibly-stale copy of the clicked node instead of the live one.
        let filteredRootNodes = workspace.filteredRootNodes
        return VStack(spacing: 0) {
            if !workspace.rootNodes.isEmpty {
                sidebarHeader
                Divider()
                filterBar
                Divider()
                if isBatchSelectionMode {
                    batchActionBar
                    Divider()
                }
            }

            List(selection: Binding(
                get: { workspace.selectedNode?.id },
                set: { newID in
                    workspace.select(findNode(id: newID, in: workspace.filteredRootNodes))
                }
            )) {
                ForEach(filteredRootNodes) { root in
                    OutlineGroup(root, children: \.displayChildren) { node in
                        SidebarRow(node: node, rootID: root.id, isBatchSelectionMode: isBatchSelectionMode, batchSelectedIDs: $batchSelectedIDs)
                            .tag(node.id)
                    }
                }
            }
            .listStyle(.sidebar)

            if workspace.rootNodes.isEmpty {
                emptyState
            } else if filteredRootNodes.isEmpty {
                filteredEmptyState
            }
        }
        .searchable(text: $workspace.searchQuery, placement: .sidebar, prompt: "Filter chunks, assets, IDs…")
    }

    /// "Complete UI Overhaul" (Part 1): a lightweight orientation strip
    /// above the filter bar, how many files are actually open, since
    /// nothing else in the sidebar surfaces that at a glance once the tree
    /// scrolls past one screen.
    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(workspace.rootNodes.count == 1 ? "1 file open" : "\(workspace.rootNodes.count) files open")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // "Multi-Region Auto-Patcher" (roadmap 1.4): real detected
            // region from the last opened folder's actual SYSTEM.CNF, when
            // one was found, silent otherwise, never a guessed default.
            if let detectedRegion = workspace.detectedRegion, detectedRegion.region != .unknown {
                Text(detectedRegion.region.displayName)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                    .help(regionHelpText(detectedRegion))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func regionHelpText(_ info: SystemCNFInfo) -> String {
        var parts = ["Detected from this folder's real SYSTEM.CNF."]
        if let serial = info.serial { parts.append("Serial: \(serial).") }
        if let videoMode = info.videoMode { parts.append("VMODE: \(videoMode).") }
        return parts.joined(separator: " ")
    }

    /// Type filter + "Scan Archive", the type filter can only find assets
    /// inside files that have actually been parsed, so the scan action is
    /// surfaced right alongside it rather than buried in a menu.
    private var filterBar: some View {
        @Bindable var workspace = workspace
        return HStack(spacing: 8) {
            Picker("", selection: $workspace.typeFilter) {
                Text("All Kinds").tag(ChunkPayload.Kind?.none)
                ForEach(ChunkPayload.Kind.allCases) { kind in
                    Text(kind.rawValue).tag(ChunkPayload.Kind?.some(kind))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            Spacer()

            if workspace.isScanning {
                ProgressView().controlSize(.small)
            } else if workspace.hasUnscannedArchives {
                Button {
                    workspace.scanAllArchives()
                } label: {
                    Label("Scan Archive", systemImage: "sparkle.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Parse every level file so the type filter and search can find assets anywhere in the archive.")
            }

            Button {
                isBatchSelectionMode.toggle()
                if !isBatchSelectionMode { batchSelectedIDs.removeAll() }
            } label: {
                Image(systemName: isBatchSelectionMode ? "checklist.checked" : "checklist")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Select multiple chunks for batch export.")
            .accessibilityLabel(isBatchSelectionMode ? "Exit Batch Selection Mode" : "Enter Batch Selection Mode")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var batchActionBar: some View {
        HStack {
            Text("\(batchSelectedIDs.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Export Selected…") { exportBatchSelection() }
                .disabled(batchSelectedIDs.isEmpty)
            Button("Done") {
                isBatchSelectionMode = false
                batchSelectedIDs.removeAll()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Resolves every selected node into a composite asset (same
    /// `resolveComposite` the single-node "Export as Group…" context menu
    /// action already uses) and hands the resolvable ones to
    /// `WorkspaceViewModel.exportBatch`, a node with no resolvable
    /// composite (a raw/undecoded record, a `Position`/`Trigger`, …) is
    /// silently skipped from the export rather than failing the whole
    /// batch, but the status message says how many that was so it isn't a
    /// silent surprise.
    private func exportBatchSelection() {
        let nodes = batchSelectedIDs.compactMap { findNode(id: $0, in: workspace.rootNodes) }
        let resolved = nodes.compactMap { workspace.resolveComposite(for: $0) }
        let skipped = nodes.count - resolved.count
        guard !resolved.isEmpty, let directory = ExportPanel.chooseFolder(message: "Choose a folder to export \(resolved.count) selected object(s) into. Each gets its own subfolder.") else { return }
        isBatchSelectionMode = false
        batchSelectedIDs.removeAll()
        Task {
            await workspace.exportBatch(resolved, to: directory)
            if skipped > 0 {
                workspace.statusMessage += " (\(skipped) selected record(s) had no resolvable model/texture and were skipped.)"
            }
        }
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(workspace.hasUnscannedArchives ? "No matches yet. Try Scan Archive above." : "No matches")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No archives or level files open")
                .font(.callout)
                .foregroundStyle(.secondary)
            // "Persist last-opened file" (QoL sweep): offered, not
            // auto-loaded on launch, silently kicking off a scan of a
            // potentially large archive the moment the app opens would be
            // a surprising thing for the app to decide on its own.
            if let mostRecent = workspace.recentFileURLs.first {
                Button("Reopen \(mostRecent.lastPathComponent)") {
                    workspace.open(url: mostRecent)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            // "Directory Config" (Settings): the master directory picked
            // there is a real, working shortcut here, not just stored
            // inertly, same "offer, don't auto-load" reasoning as Recent
            // Files above.
            if let masterDirectory = workspace.masterDirectoryURL {
                Button("Open Master Directory (\(masterDirectory.lastPathComponent))") {
                    workspace.open(url: masterDirectory)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func findNode(id: UUID?, in nodes: [ChunkNode]) -> ChunkNode? {
        guard let id else { return nil }
        for node in nodes {
            if node.id == id { return node }
            if let match = findNode(id: id, in: node.children) { return match }
        }
        return nil
    }
}

private struct SidebarRow: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let rootID: UUID
    let isBatchSelectionMode: Bool
    @Binding var batchSelectedIDs: Set<UUID>
    /// "Close" (real, reported gap, nothing in this app could close
    /// anything that had been opened; see `WorkspaceViewModel.closeRoot`'s
    /// own doc comment): guards the confirmation shown only when there's
    /// something to lose. `hasPendingLevelViewerEdits` is a single global
    /// signal, not scoped to *this* root specifically, closing an
    /// unrelated root while a different one has pending Level Viewer edits
    /// still prompts here. That's over-cautious rather than wrong: it never
    /// silently discards real work, which is the property that actually
    /// matters, at the cost of an occasional needless confirmation.
    @State private var showingUnsavedCloseConfirmation = false
    /// "Create New Chunks/Levels, Chunk Cloning": see `WorkspaceViewModel.
    /// cloningChunk`'s own doc comment for exactly what this can and can't
    /// do (a genuinely new, editable chunk file, not a new entry in the
    /// game's own in-menu level list, which this codebase hasn't decoded).
    @State private var showingCloneChunkSheet = false

    /// A `.sm2`/`.smx` file-root node is a real clone source regardless of
    /// whether it's been expanded yet, `cloningChunk` reads its raw
    /// archive bytes directly, the same way `rawBytes(for:)`/the Hex
    /// Viewer do, without needing it parsed first.
    private var isCloneableSceneryRoot: Bool {
        node.id == rootID && ["sm2", "smx"].contains((node.displayName as NSString).pathExtension.lowercased())
    }

    var body: some View {
        HStack {
            if isBatchSelectionMode {
                // A `Button` here (not a bare tap gesture on the row) so the
                // tap is consumed by this control instead of also
                // triggering the enclosing `List`'s own row-selection , 
                // the exact same trick the "Parse" button below already
                // relies on to coexist with `List(selection:)`.
                Button {
                    if batchSelectedIDs.contains(node.id) {
                        batchSelectedIDs.remove(node.id)
                    } else {
                        batchSelectedIDs.insert(node.id)
                    }
                } label: {
                    Image(systemName: batchSelectedIDs.contains(node.id) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(batchSelectedIDs.contains(node.id) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(batchSelectedIDs.contains(node.id) ? "Remove from Batch Selection" : "Add to Batch Selection")
            }
            Image(systemName: icon)
                .foregroundStyle(node.isUninteresting ? AnyShapeStyle(.tertiary) : AnyShapeStyle(iconColor))
                .frame(width: 18)
            Text(node.displayName)
                .lineLimit(1)
                .foregroundStyle(node.isUninteresting ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Spacer()
            if workspace.isExpandableArchiveEntry(node) {
                Button("Parse") {
                    Task { await workspace.expandArchiveEntry(node, rootID: rootID) }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            } else if Self.customAgentSectionTypes.contains(node.sectionType), !node.children.isEmpty {
                // "Feature Discoverability" audit: AgentLab was previously
                // only reachable via this exact node type's right-click
                // context menu, nothing in the row itself hinted that a
                // graph editor exists here at all. A visible button (same
                // "Parse"-button convention as the row above) makes it a
                // one-click action instead of something you'd only find by
                // already knowing to right-click a "CustomAgent" node.
                Button {
                    workspace.agentLabNode = node
                } label: {
                    Label("AgentLab", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            } else if node.byteSize > 0 {
                Text(node.byteSize.formattedByteCount)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(node.isUninteresting ? 0.55 : 1.0)
        .contextMenu {
            if let composite = workspace.resolveComposite(for: node) {
                Button {
                    workspace.modelViewerAsset = composite
                } label: {
                    Label("View Parent / Composite", systemImage: "cube.fill")
                }
                Button {
                    exportGroup(composite)
                } label: {
                    Label("Export as Group…", systemImage: "shippingbox")
                }
            }
            if node.byteSize > 0, workspace.rawBytes(for: node) != nil {
                Button {
                    workspace.hexViewerNode = node
                } label: {
                    Label("View Raw Bytes (Hex)…", systemImage: "number")
                }
            }
            if Self.customAgentSectionTypes.contains(node.sectionType), !node.children.isEmpty {
                Button {
                    workspace.agentLabNode = node
                } label: {
                    Label("Open AgentLab Graph…", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            if isCloneableSceneryRoot {
                Divider()
                Button {
                    showingCloneChunkSheet = true
                } label: {
                    Label("Clone as New Chunk…", systemImage: "doc.on.doc")
                }
            }
            if node.id == rootID {
                Divider()
                Button(role: .destructive) {
                    if workspace.hasPendingLevelViewerEdits {
                        showingUnsavedCloseConfirmation = true
                    } else {
                        workspace.closeRoot(node)
                    }
                } label: {
                    Label("Close", systemImage: "xmark.circle")
                }
            }
        }
        .sheet(isPresented: $showingCloneChunkSheet) {
            CloneChunkSheet(sceneryFileRoot: node)
        }
        .alert("You have unsaved Level Viewer changes", isPresented: $showingUnsavedCloseConfirmation) {
            Button("Close Without Saving", role: .destructive) { workspace.closeRoot(node) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This session has pending edits that haven't been saved back into a disc image yet. Closing \"\(node.displayName)\" now won't save them.")
        }
    }

    private static let customAgentSectionTypes: Set<SectionType> = [.customAgent, .customAgentX, .customAgentDemo]

    private func exportGroup(_ asset: ResolvedModelAsset) {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this composite object (mesh, textures, and animations) into.") else { return }
        Task { await workspace.exportCompleteAsset(asset, to: directory) }
    }

    private var icon: String {
        switch node.payload {
        case .texture: return "photo"
        case .mesh(let mesh): return mesh.isSkinned ? "figure.walk" : "cube"
        case .rigidModel: return "cube.transparent"
        case .xboxModel: return "cube.transparent"
        case .xboxSkin: return "figure.walk"
        case .xboxBlendSkin: return "figure.walk.motion"
        case .material: return "paintpalette"
        case .skeleton: return "figure.stand"
        case .animation: return "play.circle"
        case .position: return "mappin"
        case .instance, .instanceDemo, .instanceMB: return "cube.transparent.fill"
        case .trigger: return "square.dashed"
        case .camera: return "video.fill"
        case .collision: return "square.grid.3x1.below.line.grid.1x2"
        case .scenery: return "map"
        case .dynamicScenery: return "arrow.triangle.2.circlepath"
        case .soundEffect, .soundEffectX: return "speaker.wave.2"
        case .gameObject: return "cpu"
        case .chunkLinks: return "link"
        case .aiPosition: return "figure.walk.motion"
        case .aiPath: return "point.topleft.down.curvedto.point.bottomright.up"
        case .lodModel: return "square.stack.3d.up"
        case .collisionSurface: return "waveform.path"
        case .skydome: return "cloud.fill"
        case .path: return "point.topleft.down.curvedto.point.bottomright.up"
        case .particleData: return "sparkles"
        case .script: return "chart.xyaxis.line"
        case .customAgent: return "chart.xyaxis.line"
        case .instanceTemplate, .instanceTemplateDemo: return "doc.badge.gearshape"
        case .raw, .none: return node.children.isEmpty ? "doc" : "folder"
        }
    }

    private var iconColor: Color {
        switch node.payload {
        case .texture: return .purple
        case .mesh: return .blue
        case .rigidModel: return .teal
        case .xboxModel: return .teal
        case .xboxSkin, .xboxBlendSkin: return .blue
        case .material: return .pink
        case .skeleton: return .orange
        case .animation: return .green
        case .position: return .mint
        case .instance, .instanceDemo, .instanceMB: return .indigo
        case .trigger: return .red
        case .camera: return .yellow
        case .collision: return .cyan
        case .scenery: return .green
        case .dynamicScenery: return .mint
        case .soundEffect, .soundEffectX: return .pink
        case .gameObject: return .gray
        case .chunkLinks: return .brown
        case .aiPosition, .aiPath: return .mint
        case .lodModel: return .teal
        case .collisionSurface: return .cyan
        case .skydome: return .blue
        case .path: return .mint
        case .particleData: return .yellow
        case .script: return .indigo
        case .customAgent: return .indigo
        case .instanceTemplate, .instanceTemplateDemo: return .gray
        case .raw, .none: return .secondary
        }
    }

}

extension ChunkNode {
    /// Coarse display priority: decoded, meaningful content (textures,
    /// models, skeletons, animations, materials) sorts before raw/unhandled
    /// records and empty containers, so browsing the tree surfaces the
    /// interesting stuff first instead of forcing a scroll past hundreds of
    /// undecoded Object/Script/Trigger/Position records to find it.
    private var displaySortRank: Int {
        switch payload {
        case .texture, .mesh, .rigidModel, .xboxModel, .xboxSkin, .xboxBlendSkin, .skeleton, .animation, .instance, .instanceDemo, .instanceMB, .trigger, .camera, .collision, .scenery, .dynamicScenery, .soundEffect, .soundEffectX, .chunkLinks, .aiPosition, .aiPath, .path, .script: return 0
        case .material, .position, .gameObject, .lodModel, .collisionSurface, .skydome, .particleData, .instanceTemplate, .instanceTemplateDemo, .customAgent: return 1
        case .none: return children.isEmpty ? 3 : 2
        case .raw: return 3
        }
    }

    /// `children`, sorted for display only (a stable sort, nodes with the
    /// same rank keep their on-disk order). `OutlineGroup` wants `nil` (not
    /// an empty array) to treat a row as a non-expandable leaf. Export/hex
    /// offset logic elsewhere keeps using `children` directly; this exists
    /// purely for the sidebar tree.
    var displayChildren: [ChunkNode]? {
        children.isEmpty ? nil : children.sorted { $0.displaySortRank < $1.displaySortRank }
    }

    /// A dead-end the user almost certainly doesn't care about browsing:
    /// no children of its own, and either undecoded or genuinely raw.
    /// Sections that merely *contain* raw children (e.g. an Instance
    /// section full of undecoded Object records) are not themselves dimmed
    ///, only the actual dead-end leaves are.
    var isUninteresting: Bool {
        guard children.isEmpty else { return false }
        switch payload {
        case .none: return true
        case .raw: return true
        default: return false
        }
    }
}
