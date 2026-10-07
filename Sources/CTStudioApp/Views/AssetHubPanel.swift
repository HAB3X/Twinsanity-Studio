import SwiftUI

/// Card chrome for a docked catalog module. Wrapping a hub in this is what
/// makes it read as its own dedicated workspace, a titled, raised surface
/// with one consistent way back to the asset preview, rather than "the
/// detail pane, but showing something else". Replaces the bare
/// `.pickerStyle(.segmented)` strip the old `DockedLibraryPanelView` used.
struct AssetHubPanel<Content: View>: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            DSPanelHeader(title: title, systemImage: systemImage, subtitle: subtitle, onClose: onClose)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .dsCardSurface()
        .dsElevated()
        .padding(DS.Space.sm)
    }
}
