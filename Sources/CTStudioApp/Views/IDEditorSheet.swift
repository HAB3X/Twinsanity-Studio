import SwiftUI
import CTModels

/// "IDEditor", ports the reference editor's own generic `IDEditor` form
/// (reachable there from any `ItemController`'s own toolbar), not scoped
/// to any one record type. Reassigns a record's ID within its containing
/// section's index table, see `WorkspaceViewModel.patchedFileBytes(
/// reassigningIDOf:to:)`'s own doc comment for exactly what does and
/// doesn't move. Deliberately narrow, same as the reference: nothing else
/// in the file that references this ID by value gets updated.
struct IDEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode

    @State private var idText: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode) {
        self.node = node
        _idText = State(initialValue: "\(node.recordID)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change ID").font(.title3.bold())
            Text("Reassigns this record's ID within its containing section. The record's own bytes and position are untouched; only the index-table entry's ID changes. Nothing else in the file that references the old ID by value (an object placement, a trigger's instance list, a script slot, ...) is updated. This is the same real, narrow behavior the reference editor's own ID Editor has.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Form {
                LabeledContent("Current ID") { Text("\(node.recordID)").font(.callout.monospaced()) }
                LabeledContent("New ID") {
                    TextField("value", text: $idText).textFieldStyle(.roundedBorder)
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
        guard let newID = UInt32(idText.trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "The new ID must be a whole, non-negative number."
            return
        }
        // "Cross-Reference Validation, Colliding IDs": real, previously-
        // uncovered gap, this used to accept any number at all, including
        // one an existing sibling record in the same section already
        // uses, silently producing two records sharing an ID (which one
        // an ID-based reference, a Trigger's instance list, a script
        // slot, an Instance's own childInstanceIDs, actually resolves to
        // at that point is undefined). Blocked outright, not just warned,
        // since there's no legitimate reason to want two sibling records
        // sharing one ID.
        guard !workspace.siblingRecordIDs(of: node).contains(newID) else {
            errorMessage = "ID #\(newID) is already used by another record in this same section, pick a different one."
            return
        }
        errorMessage = nil
        guard let patchedBytes = workspace.patchedFileBytes(reassigningIDOf: node, to: newID) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_id_\(newID).rm2",
            message: "Save the edited copy of this file, with this record's ID changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with record #\(node.recordID) reassigned to #\(newID)."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
