import SwiftUI
import CTModels

/// "Asset Diff & Version Comparison Tool" (blueprint 4.3): pick any two
/// models already resolved into the Models Hub and compare them side by
/// side. Useful for e.g. comparing a scenery object across two archive
/// scans, or two candidates that happen to share a display name.
struct AssetDiffView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    /// Set when docked into the main window's detail column (see
    /// `DetailColumn`); nil when still presented as a `.sheet`.
    var onClose: (() -> Void)? = nil

    @State private var leftID: ResolvedModelAsset.ID?
    @State private var rightID: ResolvedModelAsset.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pickers
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear(perform: seedDefaultSelection)
    }

    private var header: some View {
        HStack {
            Text("Asset Diff").font(.title2.bold())
            Spacer()
            Button("Close") { (onClose ?? { dismiss() })() }
        }
        .padding()
    }

    private var pickers: some View {
        HStack(spacing: 16) {
            Picker("Left", selection: $leftID) {
                Text("Choose a model…").tag(ResolvedModelAsset.ID?.none)
                ForEach(workspace.modelsHub) { model in
                    Text(model.displayName).tag(ResolvedModelAsset.ID?.some(model.id))
                }
            }
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(.secondary)
            Picker("Right", selection: $rightID) {
                Text("Choose a model…").tag(ResolvedModelAsset.ID?.none)
                ForEach(workspace.modelsHub) { model in
                    Text(model.displayName).tag(ResolvedModelAsset.ID?.some(model.id))
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let left = selectedModel(leftID), let right = selectedModel(rightID) {
            let rows = AssetDiff.compare(left, right)
            List {
                ForEach(rows) { row in
                    HStack {
                        Text(row.label)
                            .frame(width: 130, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(row.leftValue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.rightValue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(row.isDifferent ? Color.orange : Color.primary)
                    .listRowBackground(row.isDifferent ? Color.orange.opacity(0.08) : Color.clear)
                }
            }
            .listStyle(.plain)
        } else {
            ContentUnavailableView(
                "Pick Two Models",
                systemImage: "rectangle.on.rectangle",
                description: Text("Choose a model on each side above to compare them field by field. Differences are highlighted in orange.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectedModel(_ id: ResolvedModelAsset.ID?) -> ResolvedModelAsset? {
        guard let id else { return nil }
        return workspace.modelsHub.first { $0.id == id }
    }

    private func seedDefaultSelection() {
        guard workspace.modelsHub.count >= 2 else { return }
        leftID = workspace.modelsHub[0].id
        rightID = workspace.modelsHub[1].id
    }
}
