import SwiftUI
import CTModels

/// Inspector for a decoded `ChunkLinks` record, "Chunk-Based Architecture"
/// (Part 2). "Parity Phase E": real write-back now too, via
/// `ChunkLinksEditorSheet`/`ChunkLinksWriter`, ports `Editors/
/// ChunkLinksEditor.cs`'s field set (transform matrices, visibility flags,
/// load area/wall arrays).
///
/// "Load Chunk" (below) *is* real, wired to `WorkspaceViewModel.
/// openChunkLink`, it resolves the link's target against currently open
/// archives and adds it as a real sidebar entry, the same real parse path
/// used for any other file. It can only find a target that's in an archive
/// already open in this workspace, same limitation the Level Viewer's own
/// "Load & Stitch" has for the same lookup.
struct ChunkLinksInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let chunkLinks: ChunkLinksAsset
    @State private var loadingLinkID: Int?
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Chunk Links (\(chunkLinks.links.count))") {
                    Text("Every neighboring chunk file this level can stream in, decoded from the real on-disk `ChunkLinks` record. \"Load Chunk\" opens the target into the sidebar if its archive is already open; the Level Viewer additionally stitches its geometry into the 3D view.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Edit Chunk Links…") { showEditor = true }
                        .disabled(!workspace.canSaveEdits(for: node))
                }
                ForEach(chunkLinks.links) { link in
                    Section("Link \(link.id): \(link.path)") {
                        LabeledContent("Type", value: "\(link.type)")
                        LabeledContent("Flags", value: "0x\(String(link.flags, radix: 16))")
                        LabeledContent("Has Boundary Wall", value: link.hasWall ? "Yes" : "No")
                        LabeledContent("Load-Zone Nodes", value: "\(link.treeNodes.count)")
                        Button {
                            loadingLinkID = link.id
                            Task {
                                _ = await workspace.openChunkLink(link)
                                loadingLinkID = nil
                            }
                        } label: {
                            if loadingLinkID == link.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Load Chunk", systemImage: "arrow.down.doc")
                            }
                        }
                        .disabled(loadingLinkID != nil)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .sheet(isPresented: $showEditor) {
            ChunkLinksEditorSheet(node: node, chunkLinks: chunkLinks)
        }
    }
}
