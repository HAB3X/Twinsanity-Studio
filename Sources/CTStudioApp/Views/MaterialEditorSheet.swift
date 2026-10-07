import SwiftUI
import CTModels
import CTParsers

/// Write-back editor for a decoded `Material` record, see `MaterialWriter`'s
/// doc comment for exactly what is and isn't safe to edit here. `name` and
/// each shader's `textureId` are the only fields exposed: everything else in
/// a `TwinsShader` block (alpha blending, depth test, fog, LOD params, ...)
/// is preserved verbatim from the original bytes (`TwinsShaderInfo.
/// renderStateBytes`) rather than decoded, so `shaderType` itself stays
/// read-only, changing it would leave the preserved render-state bytes
/// mismatched with the new type's parameter-block length. Variable-length
/// (renaming can change the record's total byte size), so this saves through
/// `patchedFileBytes(replacingWholeRecord:with:)`, the same whole-record
/// replace path `LodModelEditorSheet` uses.
struct MaterialEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let original: MaterialInfo

    @State private var name: String
    @State private var textureIdsText: [String]
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, material: MaterialInfo) {
        self.node = node
        self.original = material
        _name = State(initialValue: material.name)
        _textureIdsText = State(initialValue: material.shaders.map { "\($0.textureId)" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Material #\(original.id)").font(.title3.bold())
            Text("Only the name and each shader's texture ID are editable. The rest of each shader's render state (alpha blending, depth test, fog, LOD params, ...) isn't decoded anywhere in this build, so it's carried over byte-for-byte and shader type/count can't be changed here.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Form {
                Section("Core") {
                    LabeledContent("Name") { TextField("value", text: $name).textFieldStyle(.roundedBorder) }
                    LabeledContent("Shader Count", value: "\(textureIdsText.count)")
                }
                if !textureIdsText.isEmpty {
                    Section("Shader Texture IDs") {
                        ForEach(textureIdsText.indices, id: \.self) { i in
                            LabeledContent("Type \(original.shaders[i].shaderType)") {
                                TextField("value", text: $textureIdsText[i]).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isSaving ? "Saving…" : "Save Edited Copy…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }

    private func save() {
        let trimmedName = name
        guard !trimmedName.isEmpty else {
            errorMessage = "Name can't be empty."
            return
        }
        let textureIds = textureIdsText.map { UInt32($0) }
        guard textureIds.allSatisfy({ $0 != nil }) else {
            errorMessage = "Every texture ID must be a whole number."
            return
        }
        errorMessage = nil

        var edited = original
        edited.name = trimmedName
        for (i, id) in textureIds.enumerated() {
            edited.shaders[i].textureId = id!
        }

        let encoded = MaterialWriter.write(edited)
        guard let patchedBytes = workspace.patchedFileBytes(replacingWholeRecord: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this material changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this material changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
