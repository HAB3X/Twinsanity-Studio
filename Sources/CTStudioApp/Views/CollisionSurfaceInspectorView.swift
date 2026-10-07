import SwiftUI
import CTModels

/// Read-only inspector for a decoded `CollisionSurface` record, see
/// `CollisionSurfaceInfo`'s doc comment for how this cross-references a
/// `ColData` triangle's `surfaceID` (by that field's real *value*, not
/// this record's own chunk index-table ID).
struct CollisionSurfaceInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let surface: CollisionSurfaceInfo
    @State private var isEditing = false

    var body: some View {
        Form {
            Section("Collision Surface") {
                LabeledContent("Surface ID", value: "\(surface.surfaceID)")
                LabeledContent("Flags", value: "0x\(String(surface.flags, radix: 16))")
                if workspace.canSaveEdits(for: node) {
                    Button("Edit…") { isEditing = true }
                }
            }
            if !surface.assignedSoundIDs.isEmpty || !surface.assignedParticleIDs.isEmpty {
                Section("Real Audio/VFX Triggers") {
                    if !surface.assignedSoundIDs.isEmpty {
                        LabeledContent("Sound ID(s)", value: surface.assignedSoundIDs.map(String.init).joined(separator: ", "))
                    }
                    if !surface.assignedParticleIDs.isEmpty {
                        LabeledContent("Particle ID(s)", value: surface.assignedParticleIDs.map(String.init).joined(separator: ", "))
                    }
                }
            }
            Section("Undetermined Physics Fields") {
                LabeledContent("UnkFloat 1–5", value: String(format: "%.3f, %.3f, %.3f, %.3f, %.3f", surface.unkFloat1, surface.unkFloat2, surface.unkFloat3, surface.unkFloat4, surface.unkFloat5))
                LabeledContent("UnkFloat 6–10", value: String(format: "%.3f, %.3f, %.3f, %.3f, %.3f", surface.unkFloat6, surface.unkFloat7, surface.unkFloat8, surface.unkFloat9, surface.unkFloat10))
                LabeledContent("UnkVector", value: String(format: "%.2f, %.2f, %.2f, %.2f", surface.unkVector.x, surface.unkVector.y, surface.unkVector.z, surface.unkVector.w))
                LabeledContent("UnkBoundingBox 1", value: String(format: "%.2f, %.2f, %.2f, %.2f", surface.unkBoundingBox1.x, surface.unkBoundingBox1.y, surface.unkBoundingBox1.z, surface.unkBoundingBox1.w))
                LabeledContent("UnkBoundingBox 2", value: String(format: "%.2f, %.2f, %.2f, %.2f", surface.unkBoundingBox2.x, surface.unkBoundingBox2.y, surface.unkBoundingBox2.z, surface.unkBoundingBox2.w))
            }
            Section {
                Text("Field names beyond Surface ID and the sound/particle slots keep the reference tool's own \"Unk\"-prefixed naming. The reference tool itself never determined what these physics floats or bounding boxes do.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isEditing) {
            CollisionSurfaceEditorSheet(node: node, surface: surface)
        }
    }
}
