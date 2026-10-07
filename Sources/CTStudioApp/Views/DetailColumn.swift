import SwiftUI

/// The main window's detail pane. Shows the per-selection asset preview by
/// default; when `WorkspaceViewModel.workspaceDetail` names a module, docks
/// that module here (in `AssetHubPanel` chrome) instead of the app throwing
/// a `.sheet` over everything. See `WorkspaceDetailRoute`.
struct DetailColumn: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(WOCWorkspace.self) private var wocWorkspace
    let route: WorkspaceDetailRoute

    private func back() { workspace.workspaceDetail = .assetPreview }

    var body: some View {
        switch route {
        case .assetPreview:
            ViewportPanel(node: workspace.selectedNode)

        case .models:
            AssetHubPanel(title: "Models", systemImage: route.symbol,
                          subtitle: "\(workspace.modelsHub.count) resolved", onClose: back) {
                ModelsHubView(onClose: back).environment(workspace)
            }

        case .textures:
            AssetHubPanel(title: "Textures", systemImage: route.symbol,
                          subtitle: "\(workspace.texturesHub.count) decoded", onClose: back) {
                TexturesHubView(onClose: back).environment(workspace)
            }

        case .chunks:
            AssetHubPanel(title: "Chunks", systemImage: route.symbol,
                          subtitle: "\(workspace.levelsHub.count) recognized", onClose: back) {
                LevelsHubView(onClose: back).environment(workspace)
            }

        case .soundBanks:
            AssetHubPanel(title: "Sound Banks", systemImage: route.symbol,
                          subtitle: "\(workspace.soundBanks.count) open", onClose: back) {
                SoundBanksHubView(onClose: back).environment(workspace)
            }

        case .fontParticleSheets:
            AssetHubPanel(title: "Font & Particle Sheets", systemImage: route.symbol, onClose: back) {
                PTCSheetsHubView(onClose: back).environment(workspace)
            }

        case .scrappedContent:
            AssetHubPanel(title: "Scrapped Content", systemImage: route.symbol,
                          subtitle: "\(workspace.orphanedContent.count) flagged", onClose: back) {
                ScrappedContentScannerView(onClose: back).environment(workspace)
            }

        case .assetDiff:
            AssetHubPanel(title: "Asset Diff", systemImage: route.symbol, onClose: back) {
                AssetDiffView(onClose: back).environment(workspace)
            }

        case .wocLevels:
            AssetHubPanel(title: "Wrath of Cortex Levels", systemImage: route.symbol,
                          subtitle: "a different game's data", onClose: back) {
                WOCLevelsHubView(onClose: back).environment(wocWorkspace)
            }

        case .wocSettings:
            AssetHubPanel(title: "Wrath of Cortex", systemImage: route.symbol,
                          subtitle: "disc / sound / character archive paths", onClose: back) {
                WOCSettingsModule().environment(wocWorkspace)
            }
        }
    }
}

/// The isolated Wrath of Cortex settings surface, root folder plus a
/// read-only status readout, previously buried inside `DockedLibraryPanelView`.
struct WOCSettingsModule: View {
    @Environment(WOCWorkspace.self) private var wocWorkspace

    var body: some View {
        Form {
            Section {
                LabeledContent("Root Folder", value: wocWorkspace.rootURL?.path ?? "Not selected")
                Button("Choose Folder…") { wocWorkspace.chooseRoot() }
            } header: {
                Text("Disc Location")
            } footer: {
                Text("Select the mounted WoC disc (or its LEVELS folder). Used by the Wrath of Cortex Levels, Sounds, and Characters browsers.")
            }
            Section("Status") {
                if wocWorkspace.isScanning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Scanning…")
                    }
                } else {
                    LabeledContent("Levels Found", value: "\(wocWorkspace.levels.count)")
                }
                LabeledContent("Sound Archive", value: wocWorkspace.soundArchiveURL != nil ? "Found" : "Not found")
                LabeledContent("Character Archive", value: wocWorkspace.characterArchiveURL != nil ? "Found" : "Not found")
            }
        }
        .formStyle(.grouped)
    }
}
