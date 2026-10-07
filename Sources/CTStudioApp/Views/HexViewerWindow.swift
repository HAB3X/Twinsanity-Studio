import SwiftUI
import CTModels

/// "Memory-Mapped Hex Engine" (blueprint 5.2): a standard offset/hex/ASCII
/// byte viewer and editor over one node's raw bytes, this is generic byte
/// visualization, not a Twinsanity-specific decoder, so it works uniformly
/// over any record, including the many "browsable but not deep-decoded"
/// ones (`Object`/`Script`, Xbox `ModelX`/`SkinX`, `BlendSkin`, ...) that
/// have no typed inspector at all.
///
/// `LazyVStack` inside the `ScrollView` (rather than a plain `VStack`) is
/// load-bearing here, not decorative, a large section's raw bytes can be
/// tens of thousands of 16-byte rows, and only the ones actually on screen
/// get built/laid out.
struct HexViewerWindow: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    let node: ChunkNode
    let originalBytes: Data

    @State private var editedBytes: Data
    @State private var selectedOffset: Int?
    @State private var editFieldText: String = ""

    private static let bytesPerRow = 16

    init(node: ChunkNode, originalBytes: Data) {
        self.node = node
        self.originalBytes = originalBytes
        _editedBytes = State(initialValue: originalBytes)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            grid
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        // "Robust Undo/Redo" (QoL sweep), see the matching mechanism (and
        // its doc comment) in `LevelViewerWindow`. `UndoManager` doesn't
        // route its effects back into SwiftUI `@State` on its own, so this
        // is what keeps the selected byte's displayed hex value in sync
        // after ⌘Z/⌘⇧Z.
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in resyncEditField() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in resyncEditField() }
    }

    private func resyncEditField() {
        guard let selectedOffset, selectedOffset < editedBytes.count else { return }
        editFieldText = String(format: "%02X", editedBytes[editedBytes.startIndex + selectedOffset])
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.displayName).font(.title3.bold())
                Text("\(originalBytes.count) bytes at file offset 0x\(String(node.fileOffset, radix: 16))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDirty {
                Button("Revert") { editedBytes = originalBytes; selectedOffset = nil }
            }
            Button("Save Edited Copy…") { save() }
                .disabled(!isDirty || !workspace.canSaveEdits(for: node))
            Button("Close") { dismiss() }
        }
        .padding()
    }

    private var isDirty: Bool { editedBytes != originalBytes }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HexRow(
                        rowStart: row * Self.bytesPerRow,
                        bytes: editedBytes,
                        originalBytes: originalBytes,
                        selectedOffset: selectedOffset,
                        onSelect: select(offset:)
                    )
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var rowCount: Int {
        (editedBytes.count + Self.bytesPerRow - 1) / Self.bytesPerRow
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let selectedOffset {
                Text("Offset 0x\(String(selectedOffset, radix: 16))")
                    .font(.system(.body, design: .monospaced))
                TextField("hex", text: $editFieldText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { applyEdit(at: selectedOffset) }
                Button("Apply") { applyEdit(at: selectedOffset) }
                    .disabled(byteValue(from: editFieldText) == nil)
                Text("Enter a 2-digit hex value (00–FF) and press Return or Apply.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Click a byte to select and edit it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !workspace.canSaveEdits(for: node) {
                Text("Read-only view. This record's file is archive-packed or wasn't opened standalone, so there's no write path back to it yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 260)
            }
        }
        .padding()
    }

    private func select(offset: Int) {
        selectedOffset = offset
        editFieldText = String(format: "%02X", editedBytes[editedBytes.startIndex + offset])
    }

    private func byteValue(from text: String) -> UInt8? {
        guard text.count <= 2, let v = UInt8(text, radix: 16) else { return nil }
        return v
    }

    private func applyEdit(at offset: Int) {
        guard let value = byteValue(from: editFieldText) else { return }
        let previousValue = editedBytes[editedBytes.startIndex + offset]
        editedBytes[editedBytes.startIndex + offset] = value
        if previousValue != value {
            registerByteUndo(offset: offset, restoreTo: previousValue, thenRedoTo: value)
        }
        let next = offset + 1
        if next < editedBytes.count {
            select(offset: next)
        }
    }

    /// Registers one ⌘Z step restoring `offset` to `restoreTo`, and (via
    /// the recursive helper below) a matching ⌘⇧Z redo back to
    /// `thenRedoTo`, built from a captured `Binding<Data>` rather than
    /// `self`, same reasoning as the equivalent mechanism in
    /// `LevelViewerWindow`: a `Binding` closes over the stable underlying
    /// `@State` storage, not over this ephemeral View struct instance, so
    /// it's safe for `UndoManager` to hold onto for as long as this sheet
    /// stays open. The `NSObject()` target is a disposable anchor , 
    /// `registerUndo` needs *some* `AnyObject`, but nothing here reads
    /// anything off it.
    private func registerByteUndo(offset: Int, restoreTo: UInt8, thenRedoTo: UInt8) {
        guard let undoManager else { return }
        undoManager.setActionName("Edit Byte")
        Self.registerByteUndo(undoManager: undoManager, binding: $editedBytes, offset: offset, restoreTo: restoreTo, thenRedoTo: thenRedoTo)
    }

    private static func registerByteUndo(undoManager: UndoManager, binding: Binding<Data>, offset: Int, restoreTo: UInt8, thenRedoTo: UInt8) {
        undoManager.registerUndo(withTarget: NSObject()) { _ in
            binding.wrappedValue[binding.wrappedValue.startIndex + offset] = restoreTo
            registerByteUndo(undoManager: undoManager, binding: binding, offset: offset, restoreTo: thenRedoTo, thenRedoTo: restoreTo)
        }
    }

    private func save() {
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.bin",
            message: "Save the edited copy of this file. The original file on disk is not modified."
        ) else { return }
        let editedBytesSnapshot = editedBytes
        Task { await workspace.saveHexEdit(node: node, editedBytes: editedBytesSnapshot, to: url) }
        dismiss()
    }
}

/// One 16-byte row: offset gutter, hex bytes, ASCII column, the standard
/// three-pane hex-editor layout. A plain `View` struct (not a class), so
/// SwiftUI can cheaply skip re-rendering rows whose inputs didn't change.
private struct HexRow: View {
    let rowStart: Int
    let bytes: Data
    let originalBytes: Data
    let selectedOffset: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(String(format: "%08X", rowStart))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            ForEach(0..<16, id: \.self) { column in
                byteCell(at: rowStart + column)
            }
            Text(asciiString)
                .padding(.leading, 8)
        }
        .font(.system(.body, design: .monospaced))
    }

    @ViewBuilder
    private func byteCell(at offset: Int) -> some View {
        if offset < bytes.count {
            let value = bytes[bytes.startIndex + offset]
            let isEdited = offset < originalBytes.count && originalBytes[originalBytes.startIndex + offset] != value
            Text(String(format: "%02X ", value))
                .foregroundStyle(isEdited ? Color.orange : Color.primary)
                .background(selectedOffset == offset ? Color.accentColor.opacity(0.3) : Color.clear)
                .onTapGesture { onSelect(offset) }
        } else {
            Text("   ")
        }
    }

    private var asciiString: String {
        var result = ""
        result.reserveCapacity(16)
        for column in 0..<16 {
            let offset = rowStart + column
            guard offset < bytes.count else { break }
            let value = bytes[bytes.startIndex + offset]
            let scalar = (value >= 0x20 && value < 0x7F) ? Character(UnicodeScalar(value)) : "."
            result.append(scalar)
        }
        return result
    }
}
