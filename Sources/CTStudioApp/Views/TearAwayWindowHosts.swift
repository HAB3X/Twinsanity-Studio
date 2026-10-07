import SwiftUI
import CTModels

/// "Tear-Away Workspaces" (roadmap 9.5): the Hex Viewer and Mod Crate Hub
/// as real `Window` scenes (see `CTStudioApp`) instead of `.sheet()`s , 
/// floating, independently movable across monitors, and usable alongside
/// every other panel rather than blocking the main window while open.
///
/// A different motivation from `GPUViewerWindowHosts.swift`'s three
/// viewers (which moved to `Window` to sidestep a suspected sheet/
/// `CAMetalLayer` compositing quirk): these two have no GPU content and no
/// bug to work around. They're picked specifically because neither
/// navigates elsewhere on selection the way the asset-browsing hubs
/// (Models/Textures/Levels/Sound Banks Hub) do, e.g. `ModelsHubView`
/// dismisses itself and opens the Model Viewer when you tap a card, which
/// is the right behavior for a sheet but would defeat the point of a
/// tear-away window (stay open, keep working). Converting those hubs the
/// same way would mean revisiting that dismiss-on-select behavior first;
/// out of scope here, so they stay sheets for now.
struct HexViewerWindowHost: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let node = workspace.hexViewerNode, let bytes = workspace.rawBytes(for: node) {
                HexViewerWindow(node: node, originalBytes: bytes)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { workspace.hexViewerNode = nil }
                        }
                    }
            } else {
                Color.clear
            }
        }
        .onDisappear { workspace.hexViewerNode = nil }
        .onChange(of: workspace.hexViewerNode == nil) { _, isNil in
            if isNil { dismissWindow(id: TearAwayWindowID.hexViewer) }
        }
    }
}

struct ModCrateHubWindowHost: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if workspace.isModCrateHubPresented {
                ModCrateInspectorView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { workspace.isModCrateHubPresented = false }
                        }
                    }
            } else {
                Color.clear
            }
        }
        .onDisappear { workspace.isModCrateHubPresented = false }
        .onChange(of: workspace.isModCrateHubPresented) { _, isPresented in
            if !isPresented { dismissWindow(id: TearAwayWindowID.modCrateHub) }
        }
    }
}

enum TearAwayWindowID {
    static let hexViewer = "hex-viewer"
    static let modCrateHub = "mod-crate-hub"
}
