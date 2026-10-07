import SwiftUI
import CTModels
import CTParsers

/// Write-back editor for a decoded `Skydome` record, ports
/// `Editors/SkydomeEditor.cs`'s field set. `meshIDs` is editable in place
/// only (no add/remove), its count is fixed by the on-disk record's own
/// declared size, and `SkydomeWriter` only produces a byte-identical-length
/// blob when the count is unchanged.
struct SkydomeEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let original: SkydomeInfo

    @State private var unknown: String
    @State private var meshIDs: [String]
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, skydome: SkydomeInfo) {
        self.node = node
        self.original = skydome
        _unknown = State(initialValue: "\(skydome.unknown)")
        _meshIDs = State(initialValue: skydome.meshIDs.map { "\($0)" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Skydome #\(original.id)").font(.title3.bold())
            Text("Mesh count is fixed by this record's on-disk size. This build can change which model/rigid-model IDs it points to, not add or remove slots.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Form {
                LabeledContent("Unknown") { TextField("value", text: $unknown).textFieldStyle(.roundedBorder) }
                Section("Mesh IDs (\(meshIDs.count))") {
                    ForEach(meshIDs.indices, id: \.self) { i in
                        LabeledContent("Slot \(i)") { TextField("record ID", text: $meshIDs[i]).textFieldStyle(.roundedBorder) }
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
        .frame(minWidth: 360)
    }

    private func save() {
        guard let unknownValue = UInt32(unknown) else {
            errorMessage = "Unknown must be a whole number."
            return
        }
        let ids = meshIDs.map { UInt32($0) }
        guard ids.allSatisfy({ $0 != nil }) else {
            errorMessage = "Every mesh ID must be a whole number."
            return
        }
        errorMessage = nil

        var edited = original
        edited.unknown = unknownValue
        edited.meshIDs = ids.compactMap { $0 }

        let encoded = SkydomeWriter.write(edited)
        guard let patchedBytes = workspace.patchedFileBytes(replacing: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this skydome changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this skydome changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
