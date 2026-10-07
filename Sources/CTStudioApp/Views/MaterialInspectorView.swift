import SwiftUI
import CTModels

/// Read-only inspector for a decoded `Material` record, see
/// `MaterialInfo`'s doc comment for why only `shaderType`/`textureId` are
/// decoded per shader, out of the ~90-byte PS2 GS render-state block each
/// `TwinsShader` entry actually carries.
struct MaterialInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let material: MaterialInfo
    @State private var isEditing = false

    var body: some View {
        Form {
            Section("Material #\(material.id)") {
                LabeledContent("Name", value: material.name)
                LabeledContent("Shader Count", value: "\(material.shaders.count)")
                if workspace.canSaveEdits(for: node) {
                    Button("Edit…") { isEditing = true }
                }
            }
            if !material.shaders.isEmpty {
                Section("Shaders") {
                    ForEach(Array(material.shaders.enumerated()), id: \.offset) { _, shader in
                        LabeledContent("Type \(shader.shaderType)", value: "texture #\(shader.textureId)")
                    }
                }
            }
            Section {
                Text("Only the shader's texture ID is editable per shader, the surrounding PS2 GS render state (alpha blending, depth test, fog, LOD params, ...) isn't decoded field-by-field anywhere in this build, so it's preserved byte-for-byte rather than exposed for editing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isEditing) {
            MaterialEditorSheet(node: node, material: material)
        }
    }
}
