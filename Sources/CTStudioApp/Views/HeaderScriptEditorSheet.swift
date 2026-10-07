import SwiftUI
import CTModels
import CTParsers

/// Editor for `HeaderScript` participant entries, real write-back:
/// `mainScriptIndex`/`unkInt2` are patched straight into a copy of the
/// owning file at `HeaderScript.entriesFileOffset + index * 8` (see
/// `ScriptWriter.writeHeaderScriptEntry`'s doc comment), the same
/// decode -> edit -> encode -> patch -> save-as-copy loop every other
/// write path in this app uses. `unkInt2`'s four packed sub-fields
/// (assignment type/locality/status/preference) and its packed
/// `objectID` are edited as one raw hex value, not as four separate
/// pickers, this build has verified *names* for those bit ranges (see
/// `resolvedAssignType`/etc.) but no verified reference `Save()` that
/// repacks them, so round-tripping the whole `uint32` unchanged except
/// where the user actually typed a new value is the honest option.
struct HeaderScriptEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let script: ScriptAsset
    let header: HeaderScript

    @State private var mainScriptIndexTexts: [String]
    @State private var unkInt2Texts: [String]
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, script: ScriptAsset, header: HeaderScript) {
        self.node = node
        self.script = script
        self.header = header
        _mainScriptIndexTexts = State(initialValue: header.entries.map { "\($0.mainScriptIndex)" })
        _unkInt2Texts = State(initialValue: header.entries.map { "0x" + String($0.unkInt2, radix: 16) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Header Script Participants").font(.title3.bold())
            Text("Real write-back: each entry patches straight into a copy of this file. mainScriptIndex is 1-based (the real script index is mainScriptIndex - 1).")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if header.entries.isEmpty {
                Text("No participant entries").foregroundStyle(.secondary)
            } else {
                Form {
                    ForEach(Array(header.entries.enumerated()), id: \.offset) { index, entry in
                        Section("Entry #\(index)") {
                            LabeledContent("Main Script Index") {
                                TextField("", text: $mainScriptIndexTexts[index]).textFieldStyle(.roundedBorder)
                            }
                            LabeledContent("unkInt2 (objectID + assign type/locality/status/preference)") {
                                TextField("", text: $unkInt2Texts[index]).textFieldStyle(.roundedBorder)
                            }
                            LabeledContent("Decoded") {
                                Text("objectID \(entry.objectID) · \(entry.resolvedAssignType.map { "\($0)" } ?? "?") / \(entry.resolvedAssignLocality.map { "\($0)" } ?? "?") / \(entry.resolvedAssignStatus.map { "\($0)" } ?? "?") / \(entry.resolvedAssignPreference.map { "\($0)" } ?? "?")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Apply This Entry…") { applyEntry(index: index) }
                        }
                    }
                }
                .formStyle(.grouped)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .disabled(isSaving)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 420)
    }

    private func applyEntry(index: Int) {
        guard let mainScriptIndex = Int32(mainScriptIndexTexts[index].trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "Entry \(index)'s Main Script Index isn't a valid 32-bit integer."
            return
        }
        guard let unkInt2 = Self.parseUInt32(unkInt2Texts[index]) else {
            errorMessage = "Entry \(index)'s unkInt2 (\"\(unkInt2Texts[index])\") isn't a valid 32-bit value. Use plain decimal or 0x-prefixed hex."
            return
        }
        errorMessage = nil

        let encoded = ScriptWriter.writeHeaderScriptEntry(mainScriptIndex: mainScriptIndex, unkInt2: unkInt2)
        let absoluteOffset = node.fileOffset + header.entriesFileOffset + index * 8
        guard let patchedBytes = workspace.patchedFileBytes(applyingAbsoluteByteRangePatches: [(node: node, absoluteOffset: absoluteOffset, encoded: encoded)]) else {
            return
        }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with participant entry \(index) changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with entry \(index) changed."
                isSaving = false
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
        return UInt32(trimmed)
    }
}
