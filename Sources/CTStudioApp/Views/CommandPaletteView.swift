import SwiftUI
import CTModels

/// "Global Command/Search Bar" (⌘K), QoL item from the roadmap sweep.
/// Flattens every already-parsed chunk (not archive entries that haven't
/// been scanned/expanded, there's nothing decoded to jump to yet) plus
/// every Models Hub entry into one searchable list. Built only when the
/// palette actually opens, not kept live, a full workspace can have tens
/// of thousands of nodes, and rebuilding that flat index on every keystroke
/// elsewhere in the app would be exactly the kind of needless per-frame/
/// per-edit cost this session's optimization pass was about removing.
struct CommandPaletteView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PaletteResult] = []
    @FocusState private var isSearchFocused: Bool

    private struct PaletteResult: Identifiable {
        let id: UUID
        let title: String
        let subtitle: String
        let systemImage: String
        let action: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chunks, assets, IDs…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit { results.first?.action() }
                Button("Esc") { dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            if results.isEmpty {
                // The palette used to just go blank with no explanation
                // whenever a search had zero hits (or, before anything was
                // even open, on first appearance), indistinguishable from
                // it being broken.
                ContentUnavailableView(
                    query.isEmpty ? "Nothing Open Yet" : "No Matches",
                    systemImage: query.isEmpty ? "shippingbox" : "magnifyingglass",
                    description: Text(query.isEmpty
                        ? "Open a file to search its chunks and resolved models here."
                        : "Try a different name or record ID.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { result in
                    Button(action: result.action) {
                        HStack {
                            Image(systemName: result.systemImage).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.title).lineLimit(1)
                                Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 560, height: 420)
        .onAppear { isSearchFocused = true }
        .onChange(of: query) { _, newValue in results = Self.search(newValue, workspace: workspace, dismiss: dismiss) }
        .onAppear { results = Self.search(query, workspace: workspace, dismiss: dismiss) }
    }

    private static func search(_ query: String, workspace: WorkspaceViewModel, dismiss: DismissAction) -> [PaletteResult] {
        var results: [PaletteResult] = []

        for model in workspace.modelsHub {
            guard query.isEmpty || model.displayName.localizedCaseInsensitiveContains(query) else { continue }
            results.append(PaletteResult(
                id: model.id,
                title: model.displayName,
                subtitle: model.skeleton != nil ? "Rigged model · Models Hub" : "Model · Models Hub",
                systemImage: model.skeleton != nil ? "figure.stand" : "cube.fill",
                action: { workspace.modelViewerAsset = model; dismiss() }
            ))
            if results.count >= 40 { return results }
        }

        func walk(_ nodes: [ChunkNode]) {
            for node in nodes {
                guard results.count < 60 else { return }
                if !query.isEmpty, node.displayName.localizedCaseInsensitiveContains(query) || String(node.recordID).contains(query) {
                    results.append(PaletteResult(
                        id: node.id,
                        title: node.displayName,
                        subtitle: node.sectionType.rawValue,
                        systemImage: "doc.text.magnifyingglass",
                        action: { workspace.select(node); dismiss() }
                    ))
                }
                if !workspace.isExpandableArchiveEntry(node) {
                    walk(node.children)
                }
            }
        }
        if !query.isEmpty { walk(workspace.rootNodes) }

        return results
    }
}
