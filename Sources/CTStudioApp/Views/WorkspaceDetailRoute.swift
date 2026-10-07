import SwiftUI

/// What the detail column of the main window is currently showing.
///
/// This is the mechanism that replaces the pile of `is*HubPresented` bools
/// and their `.sheet()`s for everything that's really a *destination you
/// browse* rather than a *modal task*. Setting `WorkspaceViewModel
/// .workspaceDetail` slides the corresponding module into the workspace's
/// own detail pane (wrapped in `AssetHubPanel`), leaving the sidebar and
/// toolbar live, instead of throwing a sheet over the whole window.
///
/// Genuinely modal tasks (Game Launcher, Crate Installer, Image Maker,
/// Executable Patcher, Archive Repackager, Clone Chunk, Command Palette)
/// stay as `.sheet`s, they have a clear commit/cancel and you can't
/// usefully see the main window while doing them.
public enum WorkspaceDetailRoute: Equatable, Hashable, Sendable {
    /// The normal per-selection asset preview (`ViewportPanel`).
    case assetPreview

    case models
    case textures
    case chunks
    case soundBanks
    case fontParticleSheets
    case scrappedContent
    case assetDiff

    case wocLevels
    case wocSettings

    var isModule: Bool { self != .assetPreview }

    var menuTitle: String {
        switch self {
        case .assetPreview:        return "Asset Preview"
        case .models:              return "Models"
        case .textures:            return "Textures"
        case .chunks:              return "Chunks"
        case .soundBanks:          return "Sound Banks"
        case .fontParticleSheets:  return "Font & Particle Sheets"
        case .scrappedContent:     return "Scrapped Content"
        case .assetDiff:           return "Asset Diff"
        case .wocLevels:           return "Wrath of Cortex Levels"
        case .wocSettings:         return "Wrath of Cortex Settings"
        }
    }

    var symbol: String {
        switch self {
        case .assetPreview:        return "cube.transparent"
        case .models:              return "square.grid.3x3.fill"
        case .textures:            return "photo.stack"
        case .chunks:              return "map"
        case .soundBanks:          return "waveform"
        case .fontParticleSheets:  return "textformat"
        case .scrappedContent:     return "questionmark.folder"
        case .assetDiff:           return "rectangle.on.rectangle"
        case .wocLevels:           return "globe.americas.fill"
        case .wocSettings:         return "gearshape"
        }
    }
}
