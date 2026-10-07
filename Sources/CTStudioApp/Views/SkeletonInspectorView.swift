import SwiftUI
import CTModels
import CTParsers

/// Shows a decoded `GraphicsInfo` (OGI) skeleton, plus real write-back for
/// the fields the parser's own doc comments confirm are plain, already-
/// decoded scalars: each joint's `parentJointIndex` (re-parenting) and its
/// 5-row bind-pose `matrix`, and the record's `skinID`/`blendSkinID`. This
/// deliberately does **not** expose editing for exit points, model links,
/// skin transforms, or collision data, real fields, but out of this
/// pass's scope, nor for `jointIndex`/`reactJointID` (identity fields
/// other joints' `parentJointIndex` values reference by value; editing
/// them here could silently break the hierarchy or model-link/skin-
/// transform correspondence rather than just re-express it), see
/// `SkeletonWriter`'s own doc comment for exactly what does and doesn't
/// round-trip.
struct SkeletonInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let skeleton: SkeletonAsset

    @State private var working: SkeletonAsset
    @State private var skinIDText: String
    @State private var blendSkinIDText: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, skeleton: SkeletonAsset) {
        self.node = node
        self.skeleton = skeleton
        _working = State(initialValue: skeleton)
        _skinIDText = State(initialValue: "\(skeleton.skinID)")
        _blendSkinIDText = State(initialValue: "\(skeleton.blendSkinID)")
    }

    private var tree: SkeletonTreeNode? { working.buildTree() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                LabeledContent("Joints", value: "\(working.joints.count)")
                LabeledContent("Exit Points", value: "\(working.exitPoints.count)")
                LabeledContent("Skin ID") {
                    TextField("value", text: $skinIDText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: skinIDText) { _, newValue in
                            if let parsed = UInt32(newValue.trimmingCharacters(in: .whitespaces)) { working.skinID = parsed }
                        }
                }
                LabeledContent("Blend Skin ID") {
                    TextField("value", text: $blendSkinIDText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: blendSkinIDText) { _, newValue in
                            if let parsed = UInt32(newValue.trimmingCharacters(in: .whitespaces)) { working.blendSkinID = parsed }
                        }
                }
                LabeledContent("Model Links", value: "\(working.modelLinks.count)")
            }
            .formStyle(.grouped)

            Button {
                workspace.openModelViewer(for: node)
            } label: {
                Label("Open in Model Viewer", systemImage: "cube.fill")
            }

            Text("Joint Hierarchy")
                .font(.headline)
            if let tree {
                List {
                    OutlineGroup(tree, children: \.childrenIfAny) { node in
                        HStack {
                            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange)
                            Text("Joint \(node.joint.jointIndex)")
                            Spacer()
                            Text("parent \(node.joint.parentJointIndex)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 260)
            } else {
                Text("No joints in this record.")
                    .foregroundStyle(.secondary)
            }

            if !working.joints.isEmpty {
                Text("Edit Joints")
                    .font(.headline)
                List {
                    ForEach(Array(working.joints.indices), id: \.self) { index in
                        jointEditor(index: index)
                    }
                }
                .frame(minHeight: 160, maxHeight: 320)
            }

            Divider()
            HStack {
                Button(isSaving ? "Saving…" : "Save Edited Copy…") { save() }
                    .disabled(isSaving)
                Spacer()
            }
            Text("Parent index, bind-pose matrix, Skin ID, and Blend Skin ID are real edits \"Save Edited Copy…\" writes. Exit points, model links, skin transforms, and collision data stay read-only for now.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func jointEditor(index: Int) -> some View {
        let joint = working.joints[index]
        DisclosureGroup {
            HStack {
                Text("Parent Joint Index")
                Spacer()
                TextField("parent", text: parentIndexBinding(index: index))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            .padding(.vertical, 2)

            Text("Bind-Pose Matrix (5 rows × 4)")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<5, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { axis in
                            TextField("", text: floatBinding(jointIndex: index, row: row, axis: axis))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(width: 68)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text("Joint \(joint.jointIndex)")
                Spacer()
                Text("react \(joint.reactJointID)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func parentIndexBinding(index: Int) -> Binding<String> {
        Binding<String>(
            get: { index < working.joints.count ? "\(working.joints[index].parentJointIndex)" : "0" },
            set: { newValue in
                guard index < working.joints.count, let parsed = UInt32(newValue.trimmingCharacters(in: .whitespaces)) else { return }
                working.joints[index].parentJointIndex = parsed
            }
        )
    }

    private func floatBinding(jointIndex: Int, row: Int, axis: Int) -> Binding<String> {
        Binding<String>(
            get: {
                guard jointIndex < working.joints.count, row < working.joints[jointIndex].matrix.count else { return "0" }
                let v = working.joints[jointIndex].matrix[row]
                return String(format: "%.6g", component(of: v, axis: axis))
            },
            set: { newValue in
                guard jointIndex < working.joints.count, row < working.joints[jointIndex].matrix.count,
                      let parsed = Float(newValue.trimmingCharacters(in: .whitespaces)) else { return }
                var v = working.joints[jointIndex].matrix[row]
                setComponent(&v, axis: axis, value: parsed)
                working.joints[jointIndex].matrix[row] = v
            }
        )
    }

    private func component(of v: SIMD4<Float>, axis: Int) -> Float {
        switch axis {
        case 0: return v.x
        case 1: return v.y
        case 2: return v.z
        default: return v.w
        }
    }

    private func setComponent(_ v: inout SIMD4<Float>, axis: Int, value: Float) {
        switch axis {
        case 0: v.x = value
        case 1: v.y = value
        case 2: v.z = value
        default: v.w = value
        }
    }

    private func save() {
        let encoded = SkeletonWriter.write(working)
        guard let patchedBytes = workspace.patchedFileBytes(replacing: node, with: encoded) else {
            errorMessage = workspace.lastError ?? "Internal error: couldn't apply this edit to the file."
            return
        }
        errorMessage = nil
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this skeleton's joints/skin IDs changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this skeleton's edits applied. The original file was not modified."
                isSaving = false
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}

private extension SkeletonTreeNode {
    var childrenIfAny: [SkeletonTreeNode]? { children.isEmpty ? nil : children }
}
