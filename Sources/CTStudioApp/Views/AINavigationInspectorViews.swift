import SwiftUI
import CTModels
import CTParsers

/// Write-back inspectors for "AI Pathfinding/Navmesh Editor" (roadmap 5.1)
/// records, both `AIPosition` (18 bytes: `Pos` + `Num`) and `AIPath` (10
/// bytes: 5 `UInt16` args) are fixed-size with no variable-length lists
/// (`AIPosition.cs`/`AIPath.cs`'s own `GetSize()`), so every field patches
/// straight into the record's existing offset via `WorldPlacementWriter.
/// writeAIPosition`/`writeAIPath`, no whole-record re-encode needed for
/// in-place edits. Add/Duplicate/Delete are separate structural edits via
/// `ChunkSectionInserter`, the same insertion path the Forge Palette's own
/// "Add Waypoint" already trusts.
struct AIPositionInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let marker: AIPositionMarker

    @State private var x = ""
    @State private var y = ""
    @State private var z = ""
    @State private var w = ""
    @State private var rawNodeTypeText = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("AI Waypoint #\(marker.id)") {
                    LabeledContent("Position X") { TextField("X", text: $x).textFieldStyle(.roundedBorder) }
                    LabeledContent("Position Y") { TextField("Y", text: $y).textFieldStyle(.roundedBorder) }
                    LabeledContent("Position Z") { TextField("Z", text: $z).textFieldStyle(.roundedBorder) }
                    LabeledContent("W (node weight?)") { TextField("W", text: $w).textFieldStyle(.roundedBorder) }
                    Picker("Node Type", selection: Binding(
                        get: { marker.nodeType },
                        set: { newValue in if let newValue { rawNodeTypeText = "\(newValue.rawValue)" } }
                    )) {
                        Text("(raw \(rawNodeTypeText))").tag(AIPositionMarker.NodeType?.none)
                        ForEach([AIPositionMarker.NodeType.ground, .air, .wormPath, .cortexPoint], id: \.self) { type in
                            Text(type.displayName).tag(AIPositionMarker.NodeType?.some(type))
                        }
                    }
                    LabeledContent("Raw Node Type") { TextField("", text: $rawNodeTypeText).textFieldStyle(.roundedBorder) }
                }
                Button("Copy Viewer Pos") { copyViewerPosition() }
                    .disabled(workspace.currentViewerCameraPositionProvider?() == nil)
            }
            .formStyle(.grouped)
            .onAppear { loadFields() }
            .onChange(of: node.id) { _, _ in loadFields() }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            HStack {
                Button(isSaving ? "Saving…" : "Save Edited Copy…") { save() }
                    .disabled(isSaving || editedValues == nil || !workspace.canSaveEdits(for: node))
                Spacer()
            }
            .padding(.horizontal)

            Divider().padding(.vertical, 4)
            HStack {
                Button("Add Waypoint…") { addWaypoint() }
                    .disabled(!workspace.canSaveEdits(for: node) || workspace.aiWaypointCollectionNode(inSameFileAs: node) == nil)
                Button("Duplicate…") { duplicateWaypoint() }
                    .disabled(!workspace.canSaveEdits(for: node))
                Button("Delete…", role: .destructive) { deleteWaypoint() }
                    .disabled(!workspace.canSaveEdits(for: node))
                Spacer()
            }
            .padding(.horizontal)
            Text(workspace.canSaveEdits(for: node)
                ? "Saves an edited copy under a new name, the file you opened is never modified in place."
                : "Editing only saves for a standalone-opened .RM2/.SM2 file, this record's file is archive-packed, which this build doesn't have a write path for yet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }

    private func loadFields() {
        x = String(marker.position.x)
        y = String(marker.position.y)
        z = String(marker.position.z)
        w = String(marker.position.w)
        rawNodeTypeText = "\(marker.rawNodeType)"
        errorMessage = nil
    }

    private func copyViewerPosition() {
        guard let eye = workspace.currentViewerCameraPositionProvider?() else { return }
        x = String(eye.x)
        y = String(eye.y)
        z = String(eye.z)
    }

    private var editedValues: (position: SIMD4<Float>, rawNodeType: UInt16)? {
        guard let fx = Float(x), let fy = Float(y), let fz = Float(z), let fw = Float(w),
              let rawNodeType = UInt16(rawNodeTypeText.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (SIMD4(fx, fy, fz, fw), rawNodeType)
    }

    private func save() {
        guard let edited = editedValues else {
            errorMessage = "Every field must be a valid number."
            return
        }
        errorMessage = nil
        let encoded = WorldPlacementWriter.writeAIPosition(position: edited.position, rawNodeType: edited.rawNodeType)
        guard let patchedBytes = workspace.patchedFileBytes(replacing: node, with: encoded) else { return }
        saveAsCopy(patchedBytes, suffix: "edited")
    }

    private func addWaypoint() {
        guard let (patchedBytes, insertedID) = workspace.patchedFileBytes(insertingAIPosition: SIMD4<Float>(0, 0, 0, 1), rawNodeType: 0, inSameFileAs: node) else { return }
        saveAsCopy(patchedBytes, suffix: "waypoint_\(insertedID)_added")
    }

    private func duplicateWaypoint() {
        guard let edited = editedValues else { return }
        guard let (patchedBytes, insertedID) = workspace.patchedFileBytes(insertingAIPosition: edited.position, rawNodeType: edited.rawNodeType, inSameFileAs: node) else { return }
        saveAsCopy(patchedBytes, suffix: "waypoint_\(insertedID)_duplicated")
    }

    private func deleteWaypoint() {
        guard let patchedBytes = workspace.patchedFileBytes(removingAIPosition: node) else { return }
        saveAsCopy(patchedBytes, suffix: "waypoint_\(marker.id)_deleted")
    }

    private func saveAsCopy(_ patchedBytes: Data, suffix: String) {
        guard let url = ExportPanel.chooseSaveLocation(suggestedName: "\(node.displayName)_\(suffix).rm2", message: "Save the edited copy of this file. The original file on disk is not modified.") else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent). The original file was not modified."
                isSaving = false
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}

struct AIPathInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let path: AIPathRecord

    @State private var argTexts: [String] = Array(repeating: "0", count: 5)
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("AI Path #\(path.id)") {
                    ForEach(0..<5, id: \.self) { index in
                        LabeledContent("Argument \(index)") {
                            TextField("", text: Binding(
                                get: { argTexts.indices.contains(index) ? argTexts[index] : "0" },
                                set: { if argTexts.indices.contains(index) { argTexts[index] = $0 } }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                Section("Linked Waypoints (candidate, see doc comment)") {
                    Text("This record has no position of its own. The reference tool's own tree-node summary never interprets these 5 raw values beyond printing them, but its dedicated AIPathEditor form labels Arg 0/Arg 1 \"AI Pos 1\"/\"AI Pos 2\", real evidence they're meant as AIPosition IDs, though no reference-tool code ever actually resolves them. Shown here as candidates, not a confirmed link.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    linkedWaypointRow(label: "AI Pos 1 (Arg 0)", positionID: path.startAIPositionID)
                    linkedWaypointRow(label: "AI Pos 2 (Arg 1)", positionID: path.endAIPositionID)
                }
            }
            .formStyle(.grouped)
            .onAppear { loadFields() }
            .onChange(of: node.id) { _, _ in loadFields() }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            HStack {
                Button(isSaving ? "Saving…" : "Save Edited Copy…") { save() }
                    .disabled(isSaving || editedArgs == nil || !workspace.canSaveEdits(for: node))
                Spacer()
            }
            .padding(.horizontal)

            Divider().padding(.vertical, 4)
            HStack {
                Button("Add Path…") { addPath() }
                    .disabled(!workspace.canSaveEdits(for: node) || workspace.aiPathCollectionNode(inSameFileAs: node) == nil)
                Button("Duplicate…") { duplicatePath() }
                    .disabled(!workspace.canSaveEdits(for: node))
                Button("Delete…", role: .destructive) { deletePath() }
                    .disabled(!workspace.canSaveEdits(for: node))
                Spacer()
            }
            .padding(.horizontal)
        }
    }

    private func loadFields() {
        argTexts = path.args.map { "\($0)" }
        errorMessage = nil
    }

    /// Resolves `positionID` against every real `AIPosition` in this same
    /// file (`WorkspaceViewModel.aiPositionRecords(inSameFileAs:)`, the
    /// same lookup already backing the Level Viewer's own AI Waypoints
    /// layer) and shows what it finds, or honestly says it found nothing,
    /// since a candidate ID from `AIPathRecord.startAIPositionID`/
    /// `endAIPositionID` isn't guaranteed to resolve.
    @ViewBuilder
    private func linkedWaypointRow(label: String, positionID: UInt16?) -> some View {
        if let positionID {
            let match = workspace.aiPositionRecords(inSameFileAs: node).first { $0.marker.id == UInt32(positionID) }
            LabeledContent(label) {
                if let match {
                    HStack {
                        Text("#\(positionID), (\(String(format: "%.1f, %.1f, %.1f", match.marker.position.x, match.marker.position.y, match.marker.position.z)))")
                            .font(.caption.monospaced())
                        Button("Select") { workspace.select(match.node) }
                            .controlSize(.small)
                    }
                } else {
                    Text("#\(positionID), not found in this file's AIPosition collection")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var editedArgs: [UInt16]? {
        let parsed = argTexts.map { UInt16($0.trimmingCharacters(in: .whitespaces)) }
        guard parsed.count == 5, parsed.allSatisfy({ $0 != nil }) else { return nil }
        return parsed.compactMap { $0 }
    }

    private func save() {
        guard let args = editedArgs else {
            errorMessage = "Every argument must be a whole number from 0 to 65535."
            return
        }
        errorMessage = nil
        let encoded = WorldPlacementWriter.writeAIPath(args)
        guard let patchedBytes = workspace.patchedFileBytes(replacing: node, with: encoded) else { return }
        saveAsCopy(patchedBytes, suffix: "edited")
    }

    /// Matches the reference's own `AIPath.Arg` default (`{0, 1, 0, 0, 0}`).
    private func addPath() {
        guard let (patchedBytes, insertedID) = workspace.patchedFileBytes(insertingAIPath: [0, 1, 0, 0, 0], inSameFileAs: node) else { return }
        saveAsCopy(patchedBytes, suffix: "path_\(insertedID)_added")
    }

    private func duplicatePath() {
        guard let args = editedArgs else { return }
        guard let (patchedBytes, insertedID) = workspace.patchedFileBytes(insertingAIPath: args, inSameFileAs: node) else { return }
        saveAsCopy(patchedBytes, suffix: "path_\(insertedID)_duplicated")
    }

    private func deletePath() {
        guard let patchedBytes = workspace.patchedFileBytes(removingAIPath: node) else { return }
        saveAsCopy(patchedBytes, suffix: "path_\(path.id)_deleted")
    }

    private func saveAsCopy(_ patchedBytes: Data, suffix: String) {
        guard let url = ExportPanel.chooseSaveLocation(suggestedName: "\(node.displayName)_\(suffix).rm2", message: "Save the edited copy of this file. The original file on disk is not modified.") else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent). The original file was not modified."
                isSaving = false
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
