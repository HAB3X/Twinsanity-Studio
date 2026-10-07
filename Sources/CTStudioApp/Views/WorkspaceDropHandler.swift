import Foundation
import UniformTypeIdentifiers

/// Extracted from `ContentView.handleDrop` so the first-launch empty state,
/// the main window, and anywhere else that wants file drop all resolve the
/// dropped `NSItemProvider`s the same way and route them through the one
/// `WorkspaceViewModel.open(urls:)` ingestion path.
enum WorkspaceDropHandler {
    @MainActor
    @discardableResult
    static func load(_ providers: [NSItemProvider], then apply: @escaping ([URL]) -> Void) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            MainActor.assumeIsolated { apply(urls) }
        }
        return true
    }
}
