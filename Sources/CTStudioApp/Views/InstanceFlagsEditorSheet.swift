import SwiftUI
import CTModels
import CTParsers

/// "Instance Flags" editor, write-back for `PlacedInstance.flags` using
/// the reference tool's own real, verified per-bit name table
/// (`PlacedInstance.flagNames`, ported from `InstanceFlagsEditor.flagtext`).
/// Same decode -> edit -> encode -> patch -> save-as-copy loop as every
/// other write path in this app, patched at `flagsFileOffset` the same way
/// `objectID` reassignment patches its own fixed-size, fixed-offset field.
struct InstanceFlagsEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let instance: PlacedInstance

    @State private var flags: UInt32
    @State private var isSaving = false

    init(node: ChunkNode, instance: PlacedInstance) {
        self.node = node
        self.instance = instance
        _flags = State(initialValue: instance.flags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Instance Flags").font(.title3.bold())
            Text("Real, verified per-bit names from the reference tool's own InstanceFlagsEditor. A handful of bits (and every \"Bit N\" label below) were never named by the reference tool either, so they're shown as their raw bit number here too, not an invented label.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                    ForEach(0..<32, id: \.self) { bit in
                        Toggle(isOn: bitBinding(bit)) {
                            Text(label(for: bit)).font(.caption)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 320)

            HStack {
                Text("Raw: 0x\(String(flags, radix: 16))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isSaving ? "Saving…" : "Save Edited Copy…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 440)
    }

    private func label(for bit: Int) -> String {
        let name = PlacedInstance.flagNames[bit]
        return name.isEmpty ? "Bit \(bit)" : name
    }

    private func bitBinding(_ bit: Int) -> Binding<Bool> {
        Binding(
            get: { (flags & (UInt32(1) << bit)) != 0 },
            set: { newValue in
                if newValue {
                    flags |= (UInt32(1) << bit)
                } else {
                    flags &= ~(UInt32(1) << bit)
                }
            }
        )
    }

    private func save() {
        let encoded = WorldPlacementWriter.writeInstanceFlags(flags)
        let absoluteOffset = node.fileOffset + instance.flagsFileOffset
        guard let patchedBytes = workspace.patchedFileBytes(applyingAbsoluteByteRangePatches: [(node: node, absoluteOffset: absoluteOffset, encoded: encoded)]) else {
            return // workspace.lastError already set
        }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this instance's flags changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this instance's flags changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
