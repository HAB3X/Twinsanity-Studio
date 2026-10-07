import SwiftUI
import CTModels
import CTParsers
import simd

/// "Parity Phase E": write-back editor for a decoded `ChunkLinks` record , 
/// ports `Editors/ChunkLinksEditor.cs`'s field set (load area/wall arrays,
/// transform matrices, visibility flags). Unlike `ChunkLinksInspectorView`'s
/// old doc comment, this build now has a verified byte-exact encoder
/// (`ChunkLinksWriter`, ported from `ChunkLinks.Save`/`SaveTree`/`GetSize`),
/// so a whole-record re-encode (`WorkspaceViewModel.patchedFileBytes(
/// replacingWholeRecord:with:)`, same path Phase B/D established) is safe.
/// Tree-node `undecodedBlob` stays read-only, the reference's own editor
/// never interprets it either, only ever round-trips it byte-for-byte.
struct ChunkLinksEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode

    @State private var editableAsset: ChunkLinksAsset
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, chunkLinks: ChunkLinksAsset) {
        self.node = node
        _editableAsset = State(initialValue: chunkLinks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chunk Links (\(editableAsset.links.count))").font(.title3.bold())
                Text("Real write-back: every change here re-encodes and saves the whole record as an edited copy of this file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(editableAsset.links.indices, id: \.self) { index in
                        linkSection(index: index)
                    }
                    Button("Add Link") { addLink() }
                        .controlSize(.small)
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
        .frame(minWidth: 640, minHeight: 600)
    }

    private func linkSection(index: Int) -> some View {
        let link = editableAsset.links[index]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Link \(index)").font(.callout.bold())
                Spacer()
                Button("Delete Link", role: .destructive) { editableAsset.links.remove(at: index) }
                    .controlSize(.small)
            }
            LabeledContent("Path") {
                HStack(spacing: 6) {
                    TextField("", text: $editableAsset.links[index].path).textFieldStyle(.roundedBorder)
                    // "Connect Chunks", real, requested friendlier way to
                    // point this link at another chunk than typing its
                    // archive path by hand: every `.sm2`/`.smx` currently
                    // known across this workspace's open archives, ready to
                    // assign as-is (see `WorkspaceViewModel.
                    // availableChunkLinkTargets`'s own doc comment for why
                    // it's scoped to already-open archives).
                    let targets = workspace.availableChunkLinkTargets()
                    Menu {
                        if targets.isEmpty {
                            Text("No chunks found, open the target level's archive first.")
                        } else {
                            ForEach(targets) { target in
                                Button(target.displayName) { editableAsset.links[index].path = target.path }
                            }
                        }
                    } label: {
                        Image(systemName: "link")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                    .help("Connect to a chunk from an already-open archive instead of typing its path.")
                }
            }
            HStack(spacing: 12) {
                LabeledContent("Type") {
                    TextField("", text: Binding(
                        get: { "\(link.type)" },
                        set: { if let v = Int32($0) { editableAsset.links[index].type = v } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                }
                LabeledContent("Flags (hex)") {
                    TextField("", text: Binding(
                        get: { String(link.flags, radix: 16) },
                        set: { if let v = UInt32($0, radix: 16) { editableAsset.links[index].flags = v } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .font(.caption.monospaced())
                }
                Text(link.hasTree ? "(has tree, Type bit 0 set)" : "").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.caption)

            matrixEditor(title: "Object Matrix", rows: $editableAsset.links[index].objectMatrix)
            matrixEditor(title: "Chunk Matrix", rows: $editableAsset.links[index].chunkMatrix)

            HStack {
                Text("Load Wall").font(.caption2.bold())
                if link.loadWall == nil {
                    Button("Create") {
                        editableAsset.links[index].loadWall = [SIMD4(0, 0, 0, 1), SIMD4(0, 0, 0, 1), SIMD4(0, 0, 0, 1), SIMD4(0, 0, 0, 1)]
                        editableAsset.links[index].flags |= 0x80000
                    }
                    .controlSize(.small)
                } else {
                    Button("Delete", role: .destructive) {
                        editableAsset.links[index].loadWall = nil
                        editableAsset.links[index].flags &= ~0x80000
                    }
                    .controlSize(.small)
                }
            }
            if editableAsset.links[index].loadWall != nil {
                matrixEditor(title: "Load Wall Corners", rows: Binding(
                    get: { editableAsset.links[index].loadWall ?? [] },
                    set: { editableAsset.links[index].loadWall = $0 }
                ))
            }

            treeNodesEditor(linkIndex: index)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    private func treeNodesEditor(linkIndex: Int) -> some View {
        let link = editableAsset.links[linkIndex]
        return VStack(alignment: .leading, spacing: 4) {
            Text("Load-Zone Tree Nodes (\(link.treeNodes.count))").font(.caption2.bold())
            Text(link.hasTree ? "" : "Type's bit 0 is clear. Tree nodes won't be read back even if present. Set Type's low bit to re-enable.")
                .font(.caption2)
                .foregroundStyle(.orange)
            ForEach(link.treeNodes.indices, id: \.self) { nodeIndex in
                HStack {
                    Text("Node \(nodeIndex): GI header \(link.treeNodes[nodeIndex].giHeader.map(String.init).joined(separator: ","))")
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                    Spacer()
                    Text("\(link.treeNodes[nodeIndex].undecodedBlob.count)B undecoded")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Delete", role: .destructive) {
                        editableAsset.links[linkIndex].treeNodes.remove(at: nodeIndex)
                    }
                    .controlSize(.small)
                }
            }
            Button("Add Tree Node") {
                editableAsset.links[linkIndex].treeNodes.append(ChunkLinkTreeNode(
                    header: 0,
                    giHeader: Array(repeating: 0, count: 11),
                    loadArea: Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: 8),
                    areaMatrix: Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: 6),
                    unknownMatrix: Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: 6),
                    undecodedBlob: Data()
                ))
                editableAsset.links[linkIndex].type |= 0x1
            }
            .controlSize(.small)
        }
        .padding(.leading, 12)
    }

    @ViewBuilder
    private func matrixEditor(title: String, rows: Binding<[SIMD4<Float>]>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.bold())
            ForEach(rows.wrappedValue.indices, id: \.self) { rowIndex in
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { col in
                        TextField("", text: Binding(
                            get: { String(format: "%.3f", componentValue(rows.wrappedValue[rowIndex], col)) },
                            set: { text in
                                guard let value = Float(text) else { return }
                                var updated = rows.wrappedValue[rowIndex]
                                setComponent(&updated, col, value)
                                rows.wrappedValue[rowIndex] = updated
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .font(.caption2.monospaced())
                    }
                }
            }
        }
    }

    private func componentValue(_ v: SIMD4<Float>, _ index: Int) -> Float {
        switch index { case 0: return v.x; case 1: return v.y; case 2: return v.z; default: return v.w }
    }
    private func setComponent(_ v: inout SIMD4<Float>, _ index: Int, _ value: Float) {
        switch index { case 0: v.x = value; case 1: v.y = value; case 2: v.z = value; default: v.w = value }
    }

    private func addLink() {
        let identityRows: [SIMD4<Float>] = Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: 4)
        editableAsset.links.append(ChunkLink(
            id: (editableAsset.links.map(\.id).max() ?? -1) + 1,
            type: 0, path: "new_chunk.sm2", flags: 0,
            objectMatrix: identityRows, chunkMatrix: identityRows,
            loadWall: nil, treeNodes: []
        ))
    }

    private func save() {
        errorMessage = nil
        let encoded = ChunkLinksWriter.encode(editableAsset)
        guard let patchedBytes = workspace.patchedFileBytes(replacingWholeRecord: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with these chunk links changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with chunk links changed."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
