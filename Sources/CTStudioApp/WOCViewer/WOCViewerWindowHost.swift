import SwiftUI

/// Mirrors `ModelViewerWindowHost`/etc. in `GPUViewerWindowHosts.swift`:
/// `wocWorkspace.viewerAsset` nil ↔ non-nil is the open/close signal for a
/// real `Window` scene (see `CTStudioApp`).
struct WOCViewerWindowHost: View {
    @Environment(WOCWorkspace.self) private var wocWorkspace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let asset = wocWorkspace.viewerAsset {
                WOCViewerWindow(asset: asset)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { wocWorkspace.viewerAsset = nil }
                        }
                    }
            } else {
                Color.clear
            }
        }
        .onDisappear { wocWorkspace.viewerAsset = nil }
        .onChange(of: wocWorkspace.viewerAsset == nil) { _, isNil in
            if isNil { dismissWindow(id: WOCViewerWindowID.viewer) }
        }
    }
}

enum WOCViewerWindowID {
    static let viewer = "woc-viewer"
}
