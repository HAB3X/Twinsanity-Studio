import SwiftUI
import CTModels
import CTParsers

/// "Trigger Arguments" editor, write-back for `TriggerVolume.arg1...arg4`.
/// No verified per-argument names exist for these (unlike
/// `PlacedInstance.flags`, which has a real reference name table), so this
/// edits the four raw `uint16` values directly, same discipline as the
/// AgentLab argument editor. Same decode -> edit -> encode -> patch ->
/// save-as-copy loop as every other write path in this app.
struct TriggerArgumentsEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let trigger: TriggerVolume

    @State private var arg1: String
    @State private var arg2: String
    @State private var arg3: String
    @State private var arg4: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, trigger: TriggerVolume) {
        self.node = node
        self.trigger = trigger
        _arg1 = State(initialValue: "\(trigger.arg1)")
        _arg2 = State(initialValue: "\(trigger.arg2)")
        _arg3 = State(initialValue: "\(trigger.arg3)")
        _arg4 = State(initialValue: "\(trigger.arg4)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trigger Arguments").font(.title3.bold())
            Text("Raw values only. This build has no verified name for what any of these four arguments mean, so these are the real on-disk uint16 values, not invented field names.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Form {
                LabeledContent("Arg 1") { TextField("value", text: $arg1).textFieldStyle(.roundedBorder) }
                LabeledContent("Arg 2") { TextField("value", text: $arg2).textFieldStyle(.roundedBorder) }
                LabeledContent("Arg 3") { TextField("value", text: $arg3).textFieldStyle(.roundedBorder) }
                LabeledContent("Arg 4") { TextField("value", text: $arg4).textFieldStyle(.roundedBorder) }
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
        guard let a1 = UInt16(arg1), let a2 = UInt16(arg2), let a3 = UInt16(arg3), let a4 = UInt16(arg4) else {
            errorMessage = "Each argument must be a whole number from 0 to 65535."
            return
        }
        errorMessage = nil

        let encoded = WorldPlacementWriter.writeTriggerArguments(a1, a2, a3, a4)
        let absoluteOffset = node.fileOffset + trigger.argsFileOffset
        guard let patchedBytes = workspace.patchedFileBytes(applyingAbsoluteByteRangePatches: [(node: node, absoluteOffset: absoluteOffset, encoded: encoded)]) else {
            return // workspace.lastError already set
        }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this trigger's arguments changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this trigger's arguments changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
