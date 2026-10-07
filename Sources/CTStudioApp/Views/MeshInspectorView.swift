import SwiftUI
import AppKit
import CTModels

struct MeshInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let mesh: MeshAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                LabeledContent("Kind", value: mesh.isSkinned ? "Skinned (Skin)" : "Rigid (Model)")
                LabeledContent("Submeshes", value: "\(mesh.submeshes.count)")
                LabeledContent("Vertices", value: "\(mesh.totalVertexCount)")
                LabeledContent("Triangles", value: "\(mesh.totalTriangleCount)")
            }
            .formStyle(.grouped)

            List {
                ForEach(Array(mesh.submeshes.enumerated()), id: \.offset) { index, sub in
                    HStack {
                        Text("Submesh \(index)")
                        Spacer()
                        if let materialID = sub.materialID {
                            Text("material #\(materialID)").foregroundStyle(.secondary)
                        }
                        Text("\(sub.vertices.count) v · \(sub.triangleCount) tri")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 100, maxHeight: 220)

            HStack {
                Button {
                    exportOBJ()
                } label: {
                    Label("Export OBJ…", systemImage: "square.and.arrow.up")
                }
                .disabled(mesh.totalVertexCount == 0)
                Spacer()
            }

            Text("Shown in the viewport panel on the right.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func exportOBJ() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder to export this mesh as Wavefront OBJ."
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task { await workspace.exportMeshOBJ(mesh, suggestedName: node.displayName.replacingOccurrences(of: " ", with: "_"), to: directory) }
    }
}
