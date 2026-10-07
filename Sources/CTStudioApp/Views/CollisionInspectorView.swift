import SwiftUI
import CTModels

/// Read-only summary for a decoded `ColData` record, with a button into the
/// dedicated wireframe viewer (`CollisionViewerWindow`), this is a
/// level-wide collision mesh, not a single composite-eligible object, so it
/// doesn't go through `WorkspaceViewModel.resolveComposite`/the Model
/// Viewer sheet the way textures/meshes do.
struct CollisionInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let mesh: CollisionMesh
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if mesh.isEmpty {
                ContentUnavailableView(
                    "No Collision Geometry",
                    systemImage: "square.grid.3x1.below.line.grid.1x2",
                    description: Text("This record decoded but has no vertices/triangles. The reference tool treats a short ColData record as an intentionally empty placeholder.")
                )
            } else {
                Form {
                    Section("Geometry") {
                        LabeledContent("Triangles", value: "\(mesh.triangles.count)")
                        LabeledContent("Vertices", value: "\(mesh.vertices.count)")
                        LabeledContent("Spatial Groups", value: "\(mesh.groups.count)")
                        if workspace.canSaveEdits(for: node) {
                            Button("Edit…") { isEditing = true }
                        }
                    }
                    if !mesh.triggerBoxes.isEmpty {
                        Section("Trigger Boxes (\(mesh.triggerBoxes.count))") {
                            TriggerTreeView(triggerBoxes: mesh.triggerBoxes)
                        }
                    }
                    Section {
                        Text("Each triangle carries a raw `surfaceID` linking it to a `CollisionSurface` record's impact sound/particle/physics properties. This build doesn't yet decode `CollisionSurface` records or the game-logic data that assigns meaning (e.g. \"deadly\") to specific surface IDs, so the wireframe below is shown in a single color rather than an invented category-color scheme.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .sheet(isPresented: $isEditing) {
                    ColDataEditorSheet(node: node, mesh: mesh)
                }

                Button {
                    workspace.collisionViewerMesh = mesh
                } label: {
                    Label("Open Collision Viewer", systemImage: "cube.transparent")
                }
            }
        }
    }
}

/// Reconstructs the same hierarchical trigger tree the reference tool's
/// `ColDataEditor` builds from `ColData.Trigger.Flag1`/`Flag2`, a tree
/// where `Flag1`/`Flag2` bracket a range of child triggers and a leaf
/// (both flags < 0) names a collision group by its `-Flag1` value. Read-
/// only here because the tree semantics aren't editable in the reference
/// tool either.
struct TriggerTreeView: View {
    let triggerBoxes: [CollisionTriggerBox]

    var body: some View {
        if let root = buildNode(at: 0, depth: 0) {
            DisclosureGroup {
                ForEach(root.children, id: \.id) { child in
                    triggerTreeNodeView(child)
                }
            } label: {
                Text("Root Node").font(.callout.monospaced())
            }
        } else {
            Text("(empty trigger tree)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func triggerTreeNodeView(_ node: TriggerTreeNode) -> AnyView {
        if let groupID = node.leafGroupID {
            return AnyView(Label("Leaf Node (\(node.id)): Group \(-groupID)", systemImage: "leaf")
                .font(.caption.monospaced()))
        } else {
            return AnyView(DisclosureGroup {
                ForEach(node.children, id: \.id) { child in
                    triggerTreeNodeView(child)
                }
            } label: {
                Text("Sub-Node (\(node.id))").font(.callout.monospaced())
            })
        }
    }

    private struct TriggerTreeNode {
        let id: Int
        let leafGroupID: Int?
        var children: [TriggerTreeNode]
    }

    /// Mirrors `ColDataEditor.AddTriggerNode` in the reference: a node's
    /// `[flag1, flag2]` range enumerates child indices; a child whose
    /// both flags are negative is a leaf tagged with group `-(flag1)`.
    private func buildNode(at index: Int, depth: Int) -> TriggerTreeNode? {
        guard index < triggerBoxes.count else { return nil }
        let t = triggerBoxes[index]
        var children: [TriggerTreeNode] = []
        var i = Int(t.flag1)
        while i <= Int(t.flag2) && i < triggerBoxes.count {
            let child = triggerBoxes[i]
            if child.flag1 < 0 && child.flag2 < 0 {
                children.append(TriggerTreeNode(id: i, leafGroupID: Int(child.flag1), children: []))
            } else if let childNode = buildNode(at: i, depth: depth + 1) {
                children.append(childNode)
            }
            i += 1
        }
        return TriggerTreeNode(id: index, leafGroupID: nil, children: children)
    }
}
