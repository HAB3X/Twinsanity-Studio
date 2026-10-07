import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(WOCWorkspace.self) private var wocWorkspace
    /// "Persist Window Layout" (QoL sweep): `@SceneStorage` only supports a
    /// closed set of primitive types, and `NavigationSplitViewVisibility`
    /// isn't one, this stores a plain `Int` proxy and converts through
    /// `columnVisibility` below.
    @SceneStorage("columnVisibilityRaw") private var columnVisibilityRaw: Int = 0
    @State private var isTargetedForDrop = false
    @State private var isConsoleExpanded = false
    /// "Unsaved Changes Indicator", polled, not observed: it ultimately
    /// reads `LevelViewerRenderer.hasPendingEdits`, a plain `NSObject` with
    /// no Observation support, through a closure indirection.
    @State private var hasUnsavedLevelViewerEdits = false
    @State private var unsavedEditsSummary: String?
    @State private var unsavedEditsPollTimer: Timer?

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                switch columnVisibilityRaw {
                case 1: return .detailOnly
                case 2: return .doubleColumn
                default: return .all
                }
            },
            set: { newValue in
                if newValue == .detailOnly { columnVisibilityRaw = 1 }
                else if newValue == .doubleColumn { columnVisibilityRaw = 2 }
                else { columnVisibilityRaw = 0 }
            }
        )
    }

    /// Whether anything is loaded at all. Drives the first-launch empty
    /// state vs. the real 3-column workspace.
    private var hasAnySource: Bool {
        !workspace.rootNodes.isEmpty || workspace.memoryCardAsset != nil
    }

    var body: some View {
        rootContent
            .tint(workspace.accentColorChoice.color)
            .navigationTitle("Twinsanity Studio")
            .toolbar { workspaceToolbar }
            .overlay(alignment: .bottom) { statusBanner }
            .overlay { if isTargetedForDrop { DropOverlay() } }
            .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
                WorkspaceDropHandler.load(providers) { workspace.open(urls: $0) }
            }
            .modifier(GPUWindowOpeners())
            .modifier(ModalTaskSheets())
            .modifier(SourceCommandHandlers())
            .onAppear(perform: startUnsavedEditsPoll)
            .onDisappear {
                unsavedEditsPollTimer?.invalidate()
                unsavedEditsPollTimer = nil
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if hasAnySource {
            loadedWorkspace
        } else {
            WorkspaceEmptyStateView()
        }
    }

    // MARK: - Loaded workspace

    private var loadedWorkspace: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: columnVisibility) {
                splitSidebar
            } content: {
                splitContent
            } detail: {
                splitDetail
            }
            Divider()
            EngineConsoleView(isExpanded: $isConsoleExpanded)
        }
    }

    private var splitSidebar: some View {
        SidebarView()
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
    }

    private var splitContent: some View {
        InspectorView(node: workspace.selectedNode)
            .navigationSplitViewColumnWidth(min: 360, ideal: 480)
    }

    private var splitDetail: some View {
        DetailColumn(route: workspace.workspaceDetail)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            UnifiedSourceMenu()
        }

        if hasUnsavedLevelViewerEdits {
            ToolbarItem(placement: .primaryAction) {
                Label(unsavedEditsSummary ?? "Unsaved changes", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help("Unsaved Level Viewer edits. Quitting will prompt to save them.")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                workspace.gameLauncherContext = nil
                workspace.isGameLauncherPresented = true
            } label: {
                Label("Play in PCSX2", systemImage: "play.fill")
            }
            .help("Build and boot the full modded game in PCSX2.")
            .disabled(!hasAnySource)
        }

        ToolbarItem(placement: .primaryAction) {
            libraryMenu
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isConsoleExpanded.toggle() }
            } label: {
                Label("Console", systemImage: "terminal")
            }
            .help("Toggle the Engine Console.")
            .disabled(!hasAnySource)
        }

        ToolbarItem(placement: .primaryAction) {
            scanProgressIndicator
        }
    }

    /// Catalog browsers only, the old `Library ▾` also carried power tools,
    /// a whole second game, and docked-vs-popup duplicates. Tools and Wrath
    /// of Cortex now live in the menu bar (`CommandMenu`s in `CTStudioApp`).
    private var libraryMenu: some View {
        Menu {
            Section("Catalogs") {
                libraryButton("Models", .models,
                              enabled: !workspace.modelsHub.isEmpty || workspace.isScanning)
                libraryButton("Textures", .textures,
                              enabled: !workspace.texturesHub.isEmpty || workspace.isScanning)
                libraryButton("Chunks", .chunks,
                              enabled: !workspace.levelsHub.isEmpty || workspace.isScanning)
                libraryButton("Sound Banks", .soundBanks,
                              enabled: !workspace.soundBanks.isEmpty)
                libraryButton("Font & Particle Sheets", .fontParticleSheets,
                              enabled: !workspace.ptcSheets.isEmpty || !workspace.fontSheets.isEmpty)
            }
            Section("Analysis") {
                libraryButton("Scrapped Content", .scrappedContent,
                              enabled: !workspace.orphanedContent.isEmpty || workspace.isScanning)
                libraryButton("Asset Diff", .assetDiff,
                              enabled: workspace.modelsHub.count >= 2)
            }
            if workspace.workspaceDetail.isModule {
                Divider()
                Button("Back to Asset Preview") {
                    workspace.workspaceDetail = .assetPreview
                }
            }
        } label: {
            Label("Library", systemImage: "books.vertical.fill")
        }
        .help("Dock a catalog browser into the workspace.")
        .disabled(!hasAnySource)
    }

    private func libraryButton(_ title: String, _ route: WorkspaceDetailRoute, enabled: Bool) -> some View {
        Button {
            workspace.workspaceDetail = route
        } label: {
            Label(title, systemImage: route.symbol)
        }
        .disabled(!enabled)
    }

    @ViewBuilder
    private var scanProgressIndicator: some View {
        if let scanProgress = workspace.scanProgress, scanProgress.total > 0 {
            HStack(spacing: 6) {
                ProgressView(value: Double(scanProgress.completed), total: Double(scanProgress.total))
                    .controlSize(.small)
                    .frame(width: 80)
                Text("\(Int(100 * Double(scanProgress.completed) / Double(scanProgress.total)))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    workspace.cancelScan()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel Scan")
                .help("Cancel scanning. Whatever's already been parsed stays loaded.")
            }
        } else if workspace.isLoading || workspace.isScanning || workspace.isLoadingSoundBank || workspace.isSaving {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: - Status banner

    @ViewBuilder
    private var statusBanner: some View {
        if let error = workspace.lastError {
            StatusBanner(text: error, isError: true) { workspace.lastError = nil }
        } else if !workspace.statusMessage.isEmpty {
            StatusBanner(text: workspace.statusMessage, isError: false) { workspace.statusMessage = "" }
                .task(id: workspace.statusMessage) {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    workspace.statusMessage = ""
                }
        }
    }

    // MARK: - Helpers

    /// Performance fix, real, captured evidence (a `sample` of the app
    /// sitting completely idle showed the main thread pinned at 100% CPU,
    /// entirely inside this poll's call chain): `currentLevelViewerPendingPatchProvider`
    /// doesn't compute a cheap summary, it runs the exact same work a
    /// real save would (`WorkspaceViewModel.patchedFileBytes(...)` via
    /// `LevelViewerWindow.computingPendingOverridePatch`), which fully
    /// re-parses the level's file and re-decodes/re-unswizzles every one
    /// of its textures (`RM2Parser.parse` → `TextureParser.parse` →
    /// `EzSwizzle`). This doc comment used to claim the summary only
    /// recomputes "right after `hasUnsavedLevelViewerEdits` flips true, or
    /// while it stays true but the underlying edit set keeps changing" , 
    /// but the code below called it unconditionally on every single timer
    /// tick regardless, for as long as *any* edit was pending, which is
    /// most of any real editing session. Once that per-tick cost exceeds
    /// the timer's own 1-second interval, trivially true for a real
    /// level with real textures, `Timer`'s `repeats: true` just fires the
    /// next tick back-to-back with no gap, sustaining ~100% main-thread
    /// CPU indefinitely and starving everything else on the main actor
    /// (the render loop, clicks, legitimate async work elsewhere), very
    /// likely the actual mechanism behind reports of multi-second stalls
    /// on essentially any interaction.
    ///
    /// This label (`Label(unsavedEditsSummary ?? "Unsaved changes", ...)`)
    /// is its only consumer, cosmetic toolbar text, not anything a real
    /// save reads. Recomputing it live, continuously, was never worth this
    /// cost. Now computed once, actually matching this doc comment's
    /// original stated intent: right when `hasUnsavedLevelViewerEdits`
    /// flips false -> true. Deliberate, visible tradeoff: the summary text
    /// can go stale while continuing to edit within the same session
    /// (e.g. still reading "moved 1 object" after moving several more) , 
    /// an honest cost given the alternative was the editor being
    /// effectively unusable.
    private func startUnsavedEditsPoll() {
        hasUnsavedLevelViewerEdits = workspace.hasPendingLevelViewerEdits
        refreshUnsavedEditsSummaryIfNeeded()
        unsavedEditsPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                let wasUnsaved = hasUnsavedLevelViewerEdits
                hasUnsavedLevelViewerEdits = workspace.hasPendingLevelViewerEdits
                if hasUnsavedLevelViewerEdits != wasUnsaved {
                    refreshUnsavedEditsSummaryIfNeeded()
                }
            }
        }
    }

    private func refreshUnsavedEditsSummaryIfNeeded() {
        guard hasUnsavedLevelViewerEdits else {
            unsavedEditsSummary = nil
            return
        }
        if let patch = workspace.currentLevelViewerPendingPatchProvider?() {
            unsavedEditsSummary = patch.summary
        } else if let snapshot = workspace.pendingLevelViewerPatchSnapshot {
            unsavedEditsSummary = snapshot.summary
        }
    }
}

// MARK: - Modifier groups
//
// Split out of `ContentView.body` so the Swift type-checker gets small,
// independently-checkable modifier chains instead of one 40-modifier
// expression that blows past its solver budget.

/// The GPU-heavy viewers open as real windows, every call site that sets
/// `modelViewerAsset` / `collisionViewerMesh` / `levelViewerContext` is
/// unchanged; this is where those transitioning to non-nil open the
/// corresponding window.
private struct GPUWindowOpeners: ViewModifier {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(WOCWorkspace.self) private var wocWorkspace
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onChange(of: workspace.modelViewerAsset?.id) { _, newValue in
                if newValue != nil { openWindow(id: GPUViewerWindowID.model) }
            }
            .onChange(of: workspace.collisionViewerMesh?.id) { _, newValue in
                if newValue != nil { openWindow(id: GPUViewerWindowID.collision) }
            }
            .onChange(of: workspace.levelViewerContext?.id) { _, newValue in
                if newValue != nil { openWindow(id: GPUViewerWindowID.level) }
            }
            .onChange(of: wocWorkspace.viewerAsset?.id) { _, newValue in
                if newValue != nil { openWindow(id: WOCViewerWindowID.viewer) }
            }
            .onChange(of: workspace.hexViewerNode?.id) { _, newValue in
                if newValue != nil { openWindow(id: TearAwayWindowID.hexViewer) }
            }
            .onChange(of: workspace.isModCrateHubPresented) { _, isPresented in
                if isPresented { openWindow(id: TearAwayWindowID.modCrateHub) }
            }
    }
}

/// Only genuinely modal tasks remain sheets, a clear commit/cancel, and no
/// use for the main window while they're up. Every browse-type hub now docks
/// into `DetailColumn` instead (see `WorkspaceDetailRoute`).
private struct ModalTaskSheets: ViewModifier {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(WOCWorkspace.self) private var wocWorkspace

    func body(content: Content) -> some View {
        @Bindable var workspace = workspace
        @Bindable var wocWorkspace = wocWorkspace
        return content
            .sheet(isPresented: $workspace.isExecutablePatcherPresented) { ExecutablePatcherView() }
            .sheet(isPresented: $workspace.isImageMakerPresented) { ImageMakerView() }
            .sheet(isPresented: $workspace.isArchiveRepackagerPresented) { ArchiveRepackagerView() }
            .sheet(isPresented: $workspace.isCrateInstallerPresented) { CrateInstallerView() }
            .sheet(isPresented: $workspace.isGameLauncherPresented) { GameLauncherView() }
            .sheet(item: $workspace.agentLabNode) { node in
                AgentLabGraphView(sectionNode: node).environment(workspace)
            }
            .sheet(isPresented: $workspace.isCommandPalettePresented) {
                CommandPaletteView().environment(workspace)
            }
            .sheet(isPresented: Binding(
                get: { workspace.memoryCardAsset != nil },
                set: { if !$0 { workspace.memoryCardAsset = nil } }
            )) {
                if let asset = workspace.memoryCardAsset {
                    MemoryCardInspectorWindow(asset: asset).environment(workspace)
                }
            }
            .sheet(isPresented: $wocWorkspace.isSoundBrowserPresented) {
                if let soundArchiveURL = wocWorkspace.soundArchiveURL {
                    WOCSoundBrowserView(archiveURL: soundArchiveURL)
                }
            }
            .sheet(isPresented: $wocWorkspace.isCharacterBrowserPresented) {
                if let characterArchiveURL = wocWorkspace.characterArchiveURL {
                    WOCCharacterArchiveBrowserView(archiveURL: characterArchiveURL)
                }
            }
    }
}

/// `File`-menu / command-palette entry points, routed through `SourceActions`
/// (which owns the one copy of each `NSOpenPanel` config).
private struct SourceCommandHandlers: ViewModifier {
    @Environment(WorkspaceViewModel.self) private var workspace

    private var sourceActions: SourceActions { SourceActions(workspace: workspace) }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ctStudioOpenRequested)) { _ in
                sourceActions.chooseFolderOrFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ctStudioMountDiscRequested)) { _ in
                sourceActions.mountDiscImage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ctStudioOpenMemoryCardRequested)) { _ in
                sourceActions.openMemoryCard()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ctStudioOpenMonkeyBallRequested)) { _ in
                sourceActions.openAsMonkeyBall()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ctStudioOpenRecentRequested)) { notification in
                guard let url = notification.object as? URL else { return }
                workspace.open(url: url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ctStudioCommandPaletteRequested)) { _ in
                workspace.isCommandPalettePresented = true
            }
    }
}

// MARK: - Small shared pieces

private struct StatusBanner: View {
    let text: String
    let isError: Bool
    var dismiss: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
            Text(text)
                .lineLimit(2)
            Spacer()
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss Message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(isError ? .red : .primary)
        .padding()
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.12)
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                .padding(24)
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 40))
                Text("Drop .BH/.BD, .RM2/.SM2, or a folder")
                    .font(.headline)
            }
        }
        .allowsHitTesting(false)
    }
}
