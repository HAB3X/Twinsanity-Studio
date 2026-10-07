import SwiftUI
import CTModels
import CTParsers

/// "AgentLab" argument editing, the write-back half of the AgentLab
/// Graph's decode. Edits one command's raw `uint32` arguments and patches
/// them straight into a copy of the owning file: the same decode -> edit
/// -> encode -> patch -> save-as-copy loop every other write path in this
/// app already uses, with `AgentLabWriter` standing in for
/// `WorldPlacementWriter`. Argument *count* is fixed (see that type's own
/// doc comment), this only ever changes values, never how many slots
/// exist or what command runs.
///
/// Deliberately raw, not typed, even for the ~14 commands
/// `AgentLabActionDecoder` gives a friendly name to: building a
/// typed-field-back-to-raw-slot encoder for each of those individually is
/// real, separate work this pass doesn't attempt, editing the real
/// on-disk `uint32`s directly is strictly more general (it already covers
/// every command, decoded or not) and doesn't risk silently mis-encoding
/// one of the 14 by guessing at a round-trip this session hasn't verified
/// against the reference `Save()` side.
struct AgentLabArgumentEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let command: AgentLabCommand

    @State private var argumentTexts: [String]
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, command: AgentLabCommand) {
        self.node = node
        self.command = command
        _argumentTexts = State(initialValue: command.rawArguments.map { "0x" + String($0, radix: 16) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(command.commandName ?? "Command #\(command.commandID)").font(.title3.bold())
            Text("Editing the real on-disk uint32 arguments. This build doesn't have a verified field-name mapping for every command (see AgentLabActionDecoder for the ones it does), so these are raw values, not invented ones. Enter plain decimal or 0x-prefixed hex; a leading \"-\" is read as a signed 32-bit value and stored as its unsigned bit pattern.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Form {
                ForEach(argumentTexts.indices, id: \.self) { index in
                    LabeledContent("Argument \(index)") {
                        TextField("value", text: $argumentTexts[index])
                            .textFieldStyle(.roundedBorder)
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
        .frame(minWidth: 380)
    }

    private func save() {
        var parsed: [UInt32] = []
        parsed.reserveCapacity(argumentTexts.count)
        for (index, text) in argumentTexts.enumerated() {
            guard let value = Self.parseUInt32(text) else {
                errorMessage = "Argument \(index) (\"\(text)\") isn't a valid 32-bit value. Use plain decimal or 0x-prefixed hex."
                return
            }
            parsed.append(value)
        }
        errorMessage = nil

        let encoded = AgentLabWriter.writeArguments(parsed)
        let absoluteOffset = node.fileOffset + command.fileOffset + 4 // past internalIndex
        guard let patchedBytes = workspace.patchedFileBytes(applyingAbsoluteByteRangePatches: [(node: node, absoluteOffset: absoluteOffset, encoded: encoded)]) else {
            return // workspace.lastError already set
        }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this command's arguments changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this command's arguments changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }

    private static func parseUInt32(_ text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt32(trimmed.dropFirst(2), radix: 16)
        }
        if trimmed.hasPrefix("-"), let signed = Int32(trimmed) {
            return UInt32(bitPattern: signed)
        }
        return UInt32(trimmed)
    }
}
