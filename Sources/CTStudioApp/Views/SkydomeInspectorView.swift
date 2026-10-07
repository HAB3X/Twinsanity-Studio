import SwiftUI
import CTModels

/// Inspector for a decoded `Skydome` record.
struct SkydomeInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let skydome: SkydomeInfo
    @State private var isEditing = false

    var body: some View {
        Form {
            Section("Skydome #\(skydome.id)") {
                LabeledContent("Unknown", value: "\(skydome.unknown)")
                LabeledContent("Mesh Count", value: "\(skydome.meshIDs.count)")
                if workspace.canSaveEdits(for: node) {
                    Button("Edit…") { isEditing = true }
                }
            }
            Section("Real Model/RigidModel IDs") {
                ForEach(Array(skydome.meshIDs.enumerated()), id: \.offset) { index, id in
                    LabeledContent("Mesh \(index)", value: "#\(id)")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isEditing) {
            SkydomeEditorSheet(node: node, skydome: skydome)
        }
    }
}
