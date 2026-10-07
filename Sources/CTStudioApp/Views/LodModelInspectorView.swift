import SwiftUI
import CTModels

/// Read-only inspector for a decoded `LodModel` record, see
/// `LodModelInfo`'s doc comment for why this record type mattered: it was
/// the real, confirmed root cause of scenery objects silently not
/// rendering (a scenery placement's `modelID` pointing here instead of
/// directly at a `RigidModel`).
struct LodModelInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let lodModel: LodModelInfo
    @State private var isEditing = false

    var body: some View {
        Form {
            Section("LOD Model #\(lodModel.id)") {
                LabeledContent("Header", value: "\(lodModel.header)")
                LabeledContent("LOD Levels", value: "\(lodModel.lodModelIDs.count)")
                if workspace.canSaveEdits(for: node) {
                    Button("Edit…") { isEditing = true }
                }
            }
            Section("Alternate RigidModel IDs (highest detail first)") {
                ForEach(Array(lodModel.lodModelIDs.enumerated()), id: \.offset) { index, id in
                    LabeledContent("LOD \(index)", value: String(format: "#%X", id))
                }
            }
            Section("LOD Distances".tagged(.custom("round-tripped, units unverified"))) {
                ForEach(Array(lodModel.lodDistances.enumerated()), id: \.offset) { index, d in
                    LabeledContent("Slot \(index)", value: "\(d)")
                }
            }
            Section {
                Text("This viewer resolves scenery placements through the first of these IDs that actually has a real RigidModel, not a distance-based LOD selection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isEditing) {
            LodModelEditorSheet(node: node, lodModel: lodModel)
        }
    }
}
