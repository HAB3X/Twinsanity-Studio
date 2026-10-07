import SwiftUI
import CTModels
import CTParsers

/// Write-back editor for a decoded `Path` record, ports
/// `Editors/PathEditor.cs`'s field set, including add/remove for both the
/// Positions and Params lists (independently, matching the reference's
/// own two separate list boxes, `PathAsset`'s own doc comment notes
/// they're "not assumed to always be the same length"). Saves through
/// `patchedFileBytes(replacingWholeRecord:with:)` rather than the
/// fixed-size `patchedFileBytes(replacing:with:)`, since adding/removing a
/// point or param changes this record's total on-disk size.
struct PathEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let original: PathAsset

    @State private var positions: [(x: String, y: String, z: String, w: String)]
    @State private var params: [(p1: String, p2: String)]
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, path: PathAsset) {
        self.node = node
        self.original = path
        _positions = State(initialValue: path.positions.map { ("\($0.x)", "\($0.y)", "\($0.z)", "\($0.w)") })
        _params = State(initialValue: path.params.map { ("\($0.p1)", "\($0.p2)") })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Path #\(original.id)").font(.title3.bold())

            Form {
                Section("Points (\(positions.count))") {
                    ForEach(positions.indices, id: \.self) { i in
                        HStack {
                            Text("Point \(i)").frame(width: 60, alignment: .leading)
                            TextField("x", text: $positions[i].x).textFieldStyle(.roundedBorder)
                            TextField("y", text: $positions[i].y).textFieldStyle(.roundedBorder)
                            TextField("z", text: $positions[i].z).textFieldStyle(.roundedBorder)
                            TextField("w", text: $positions[i].w).textFieldStyle(.roundedBorder)
                            Button(role: .destructive) { positions.remove(at: i) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove Point")
                        }
                    }
                    Button("Add Point") { positions.append(("0", "0", "0", "1")) }
                }
                Section("Params (real, undetermined meaning)") {
                    ForEach(params.indices, id: \.self) { i in
                        HStack {
                            Text("Point \(i)").frame(width: 60, alignment: .leading)
                            TextField("p1", text: $params[i].p1).textFieldStyle(.roundedBorder)
                            TextField("p2", text: $params[i].p2).textFieldStyle(.roundedBorder)
                            Button(role: .destructive) { params.remove(at: i) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove Parameter")
                        }
                    }
                    Button("Add Param") { params.append(("0", "0")) }
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
        var newPositions: [SIMD4<Float>] = []
        for p in positions {
            guard let x = Float(p.x), let y = Float(p.y), let z = Float(p.z), let w = Float(p.w) else {
                errorMessage = "Every point coordinate must be a valid number."
                return
            }
            newPositions.append(SIMD4(x, y, z, w))
        }
        var newParams: [PathAsset.Param] = []
        for p in params {
            guard let p1 = Float(p.p1), let p2 = Float(p.p2) else {
                errorMessage = "Every param must be a valid number."
                return
            }
            newParams.append(PathAsset.Param(p1: p1, p2: p2))
        }
        errorMessage = nil

        var edited = original
        edited.positions = newPositions
        edited.params = newParams

        let encoded = PathWriter.write(edited)
        guard let patchedBytes = workspace.patchedFileBytes(replacingWholeRecord: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this path changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this path changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
