import SwiftUI
import CTModels
import CTParsers

/// Write-back editor for a decoded `LodModel` record, ports the full
/// field set from `Editors/LodEditor.cs`, including its 4-slot cap:
/// `LODDistance` is always exactly 4 real uint32s on disk (`LodModel.cs`'s
/// own fixed-size array), and the reference editor's own UI never lets
/// `lodModelIDs`/`ModelsAmount` grow past 4 either (only 4 text boxes
/// exist for it), this mirrors that same bound rather than allowing
/// unbounded growth into untested territory. `lodDistances` are editable
/// raw numbers (this build still doesn't interpret their units, see
/// `LodModelInfo`'s own doc comment, but round-tripping a value the user
/// explicitly typed is safe regardless of what it means). Saves through
/// `patchedFileBytes(replacingWholeRecord:with:)`, since adding/removing a
/// LOD slot changes this record's total on-disk size.
struct LodModelEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let original: LodModelInfo

    static let maxSlots = 4

    @State private var header: String
    @State private var lodDistancesText: [String]
    @State private var lodModelIDsText: [String]
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, lodModel: LodModelInfo) {
        self.node = node
        self.original = lodModel
        _header = State(initialValue: "\(lodModel.header)")
        _lodDistancesText = State(initialValue: lodModel.lodDistances.map { "\($0)" })
        _lodModelIDsText = State(initialValue: lodModel.lodModelIDs.map { String(format: "%X", $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit LOD Model #\(original.id)").font(.title3.bold())
            Text("LOD distances are real, editable numbers, but this build doesn't have a confirmed interpretation of their units. The viewer always picks the first model ID that actually resolves, not a distance-based selection.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Form {
                Section("Core") {
                    LabeledContent("Header") { TextField("value", text: $header).textFieldStyle(.roundedBorder) }
                    LabeledContent("Models Amount", value: "\(lodModelIDsText.count)")
                }
                Section("LOD Distances (real, undetermined units)") {
                    ForEach(lodDistancesText.indices, id: \.self) { i in
                        LabeledContent("Slot \(i)") { TextField("value", text: $lodDistancesText[i]).textFieldStyle(.roundedBorder) }
                    }
                }
                Section("Alternate RigidModel IDs (hex, highest detail first)") {
                    ForEach(lodModelIDsText.indices, id: \.self) { i in
                        HStack {
                            LabeledContent("LOD \(i)") { TextField("0x...", text: $lodModelIDsText[i]).textFieldStyle(.roundedBorder) }
                            Button(role: .destructive) { lodModelIDsText.remove(at: i) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove LOD Slot \(i)")
                        }
                    }
                    Button("Add LOD Slot") { lodModelIDsText.append("0") }
                        .disabled(lodModelIDsText.count >= Self.maxSlots)
                    if lodModelIDsText.count >= Self.maxSlots {
                        Text("Capped at \(Self.maxSlots) slots. Matches the reference editor's own limit (LODDistance is always exactly 4 real slots on disk).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
        guard let headerValue = UInt32(header) else {
            errorMessage = "Header must be a whole number."
            return
        }
        let distances = lodDistancesText.map { UInt32($0) }
        guard distances.allSatisfy({ $0 != nil }) else {
            errorMessage = "Every LOD distance must be a whole number."
            return
        }
        let ids = lodModelIDsText.map { UInt32($0, radix: 16) }
        guard ids.allSatisfy({ $0 != nil }) else {
            errorMessage = "Every LOD ID must be a valid hex number."
            return
        }
        errorMessage = nil

        var edited = original
        edited.header = headerValue
        edited.lodDistances = distances.compactMap { $0 }
        edited.lodModelIDs = ids.compactMap { $0 }

        let encoded = LodModelWriter.write(edited)
        guard let patchedBytes = workspace.patchedFileBytes(replacingWholeRecord: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this LOD model changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this LOD model changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
