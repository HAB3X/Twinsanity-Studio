import SwiftUI
import CTModels

/// Inspector for a decoded `Path` record, distinct from both `Position`
/// (one point) and the `AIPosition`/`AIPath` waypoint system; see
/// `PathAsset`'s doc comment.
struct PathInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let path: PathAsset
    @State private var isEditing = false

    var body: some View {
        Form {
            Section("Path #\(path.id)") {
                LabeledContent("Positions", value: "\(path.positions.count)")
                LabeledContent("Params", value: "\(path.params.count)")
                if workspace.canSaveEdits(for: node) {
                    Button("Edit…") { isEditing = true }
                }
            }
            if !path.positions.isEmpty {
                Section("Points") {
                    ForEach(Array(path.positions.enumerated()), id: \.offset) { index, point in
                        LabeledContent("Point \(index)", value: String(format: "%.2f, %.2f, %.2f, %.2f", point.x, point.y, point.z, point.w))
                    }
                }
            }
            if !path.params.isEmpty {
                Section("Per-Point Params (real, undetermined meaning)") {
                    ForEach(Array(path.params.enumerated()), id: \.offset) { index, param in
                        LabeledContent("Point \(index)", value: String(format: "P1=%.3f, P2=%.3f", param.p1, param.p2))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isEditing) {
            PathEditorSheet(node: node, path: path)
        }
    }
}
