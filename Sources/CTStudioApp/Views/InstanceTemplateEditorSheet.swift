import SwiftUI
import CTModels
import CTParsers

/// "Instance Template Editor",  (a gap Twinsanity
/// Editor's own `InstanceTemplateEditor.cs` covers that this app didn't
/// yet): write-back editor for a decoded `InstanceTemplate` record. Same
/// "one editable working copy, one Save Edited Copy… button" shape as
/// `GameObjectEditorSheet`'s simpler cousins (`SkydomeEditorSheet`) , 
/// `InstanceTemplate` has no individually offset-patchable fields worth the
/// complexity (the flags/floats/ints lists can each grow or shrink, so
/// every field after them shifts), so any edit here already needs a
/// whole-record re-encode via `InstanceTemplateWriter`.
struct InstanceTemplateEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode

    @State private var editable: InstanceTemplateInfo
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, template: InstanceTemplateInfo) {
        self.node = node
        _editable = State(initialValue: template)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Instance Template, \(editable.name.isEmpty ? "<unnamed>" : editable.name)").font(.title3.bold())
                Text("Real write-back: every change here re-encodes and saves the whole record as an edited copy of this file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    InstanceTemplateFieldEditors.byteArrayEditor(title: "Unknown Flags (6 bytes)", values: $editable.unkFlags, fixedCount: 6)
                    LabeledContent("Properties (hex)") {
                        InstanceTemplateFieldEditors.hexUInt32Field($editable.properties)
                    }
                    InstanceTemplateFieldEditors.uint32ListEditor(title: "Flags", values: $editable.flags)
                    InstanceTemplateFieldEditors.floatListEditor(title: "Floats", values: $editable.floats)
                    InstanceTemplateFieldEditors.uint32ListEditor(title: "Ints", values: $editable.ints)
                }
                .padding()
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isSaving ? "Saving…" : "Save Edited Copy…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 560)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Header").font(.callout.bold())
            LabeledContent("Name") {
                TextField("", text: $editable.name).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                InstanceTemplateFieldEditors.uint16Field("Object ID", $editable.objectID)
                InstanceTemplateFieldEditors.hexUInt16Field("Bitfield", $editable.bitfield)
            }
            HStack(spacing: 12) {
                InstanceTemplateFieldEditors.uint32Field("Header Int 1", $editable.headerInt1)
                InstanceTemplateFieldEditors.uint32Field("Header Int 2", $editable.headerInt2)
                InstanceTemplateFieldEditors.uint32Field("Header Int 3", $editable.headerInt3)
            }
            // `unkShort` is only ever round-tripped when `headerInt1 == 1`
            // (see `WorldPlacementParser.parseInstanceTemplate`'s own real
            // conditional read), toggled here rather than always shown,
            // so this stays honest about when the field actually exists on
            // disk instead of silently writing a value the parser would
            // never read back.
            if editable.headerInt1 == 1 {
                InstanceTemplateFieldEditors.uint16Field("Unknown Short", Binding(
                    get: { editable.unkShort ?? 0 },
                    set: { editable.unkShort = $0 }
                ))
            } else if editable.unkShort != nil {
                Text("Unknown Short is set but won't be saved, Header Int 1 must be 1 for it to round-trip.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    private func save() {
        errorMessage = nil
        let encoded = InstanceTemplateWriter.encode(editable)
        guard let patchedBytes = workspace.patchedFileBytes(replacingWholeRecord: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this Instance Template changed."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this Instance Template changed."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}

/// The Demo build's counterpart, `unkFlags` is 2 bytes (not 6), and
/// `InstanceTemplateWriter.encode(_: InstanceTemplateDemoInfo)` writes the
/// packed single-byte list-count header instead of retail's per-list
/// `Int32` count.
struct InstanceTemplateDemoEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode

    @State private var editable: InstanceTemplateDemoInfo
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, template: InstanceTemplateDemoInfo) {
        self.node = node
        _editable = State(initialValue: template)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Instance Template (Demo), \(editable.name.isEmpty ? "<unnamed>" : editable.name)").font(.title3.bold())
                Text("Real write-back: every change here re-encodes and saves the whole record as an edited copy of this file. The demo build's lists are each capped at 255 entries, a real on-disk format limit, not a UI restriction.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    InstanceTemplateFieldEditors.byteArrayEditor(title: "Unknown Flags (2 bytes)", values: $editable.unkFlags, fixedCount: 2)
                    LabeledContent("Properties (hex)") {
                        InstanceTemplateFieldEditors.hexUInt32Field($editable.properties)
                    }
                    InstanceTemplateFieldEditors.uint32ListEditor(title: "Flags", values: $editable.flags, maxCount: 255)
                    InstanceTemplateFieldEditors.floatListEditor(title: "Floats", values: $editable.floats, maxCount: 255)
                    InstanceTemplateFieldEditors.uint32ListEditor(title: "Ints", values: $editable.ints, maxCount: 255)
                }
                .padding()
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isSaving ? "Saving…" : "Save Edited Copy…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 560)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Header").font(.callout.bold())
            LabeledContent("Name") {
                TextField("", text: $editable.name).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                InstanceTemplateFieldEditors.uint16Field("Object ID", $editable.objectID)
                InstanceTemplateFieldEditors.hexUInt16Field("Bitfield", $editable.bitfield)
            }
            HStack(spacing: 12) {
                InstanceTemplateFieldEditors.uint32Field("Header Int 1", $editable.headerInt1)
                InstanceTemplateFieldEditors.uint32Field("Header Int 2", $editable.headerInt2)
                InstanceTemplateFieldEditors.uint32Field("Header Int 3", $editable.headerInt3)
            }
            if editable.headerInt1 == 1 {
                InstanceTemplateFieldEditors.uint16Field("Unknown Short", Binding(
                    get: { editable.unkShort ?? 0 },
                    set: { editable.unkShort = $0 }
                ))
            } else if editable.unkShort != nil {
                Text("Unknown Short is set but won't be saved, Header Int 1 must be 1 for it to round-trip.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    private func save() {
        errorMessage = nil
        let encoded = InstanceTemplateWriter.encode(editable)
        guard let patchedBytes = workspace.patchedFileBytes(replacingWholeRecord: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this Instance Template changed."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this Instance Template changed."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}

/// Shared field-editor builders for both the retail and demo Instance
/// Template editors above, free functions (not view methods) so both
/// otherwise-independent sheet structs can use them without a common base.
enum InstanceTemplateFieldEditors {
    @ViewBuilder
    static func uint16Field(_ title: String, _ value: Binding<UInt16>) -> some View {
        LabeledContent(title) {
            TextField("", text: Binding(
                get: { "\(value.wrappedValue)" },
                set: { if let v = UInt16($0) { value.wrappedValue = v } }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
        }
    }

    @ViewBuilder
    static func uint32Field(_ title: String, _ value: Binding<UInt32>) -> some View {
        LabeledContent(title) {
            TextField("", text: Binding(
                get: { "\(value.wrappedValue)" },
                set: { if let v = UInt32($0) { value.wrappedValue = v } }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
        }
    }

    @ViewBuilder
    static func hexUInt16Field(_ title: String, _ value: Binding<UInt16>) -> some View {
        LabeledContent(title) {
            TextField("", text: Binding(
                get: { String(value.wrappedValue, radix: 16) },
                set: { if let v = UInt16($0, radix: 16) { value.wrappedValue = v } }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .font(.caption.monospaced())
        }
    }

    @ViewBuilder
    static func hexUInt32Field(_ value: Binding<UInt32>) -> some View {
        TextField("", text: Binding(
            get: { String(value.wrappedValue, radix: 16) },
            set: { if let v = UInt32($0, radix: 16) { value.wrappedValue = v } }
        ))
        .textFieldStyle(.roundedBorder)
        .frame(width: 120)
        .font(.caption.monospaced())
    }

    @ViewBuilder
    static func byteArrayEditor(title: String, values: Binding<[UInt8]>, fixedCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.bold())
            HStack(spacing: 4) {
                ForEach(0..<fixedCount, id: \.self) { i in
                    TextField("", text: Binding(
                        get: { i < values.wrappedValue.count ? "\(values.wrappedValue[i])" : "0" },
                        set: { text in
                            guard let v = UInt8(text) else { return }
                            while values.wrappedValue.count <= i { values.wrappedValue.append(0) }
                            values.wrappedValue[i] = v
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .font(.caption2.monospaced())
                }
            }
        }
    }

    @ViewBuilder
    static func uint32ListEditor(title: String, values: Binding<[UInt32]>, maxCount: Int? = nil) -> some View {
        DisclosureGroup("\(title) (\(values.wrappedValue.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(values.wrappedValue.indices, id: \.self) { i in
                    HStack {
                        TextField("value", text: Binding(
                            get: { "\(values.wrappedValue[i])" },
                            set: { if let v = UInt32($0) { values.wrappedValue[i] = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        Button(role: .destructive) { values.wrappedValue.remove(at: i) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(title) Entry")
                    }
                }
                Button("Add") { values.wrappedValue.append(0) }
                    .controlSize(.small)
                    .disabled(maxCount.map { values.wrappedValue.count >= $0 } ?? false)
                if let maxCount, values.wrappedValue.count >= maxCount {
                    Text("At the \(maxCount)-entry format limit.").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.leading, 8)
        }
        .font(.caption)
    }

    @ViewBuilder
    static func floatListEditor(title: String, values: Binding<[Float]>, maxCount: Int? = nil) -> some View {
        DisclosureGroup("\(title) (\(values.wrappedValue.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(values.wrappedValue.indices, id: \.self) { i in
                    HStack {
                        TextField("value", text: Binding(
                            get: { String(format: "%.4f", values.wrappedValue[i]) },
                            set: { if let v = Float($0) { values.wrappedValue[i] = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        Button(role: .destructive) { values.wrappedValue.remove(at: i) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(title) Entry")
                    }
                }
                Button("Add") { values.wrappedValue.append(0) }
                    .controlSize(.small)
                    .disabled(maxCount.map { values.wrappedValue.count >= $0 } ?? false)
                if let maxCount, values.wrappedValue.count >= maxCount {
                    Text("At the \(maxCount)-entry format limit.").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.leading, 8)
        }
        .font(.caption)
    }
}
