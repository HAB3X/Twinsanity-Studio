import SwiftUI
import CTModels

/// Read-only summary for a decoded `SceneryData` record, with a button into
/// the dedicated multi-object level viewport (`LevelViewerWindow`), like
/// `CollisionInspectorView`, this is level-wide data, not a single
/// composite-eligible object.
struct SceneryInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let scenery: SceneryAsset

    @State private var isResolving = false
    @State private var isEditingLighting = false

    var body: some View {
        // `SceneryAsset.placements` walks the record's whole recursive
        // placement tree fresh on every access (it's not a stored
        // property), computed once here and reused, rather than twice
        // (`.count` below, `.isEmpty` further down) on every body
        // evaluation.
        let placements = scenery.placements
        return VStack(alignment: .leading, spacing: 16) {
            Form {
                Section("Chunk") {
                    LabeledContent("Name", value: scenery.chunkName.isEmpty ? "(unnamed)" : scenery.chunkName)
                    if let skydomeID = scenery.skydomeID {
                        LabeledContent("Skydome ID", value: "\(skydomeID)")
                    }
                }
                Section("Placements") {
                    LabeledContent("Total in tree", value: "\(placements.count)")
                }
                if !scenery.ambientLights.isEmpty || !scenery.directionalLights.isEmpty || !scenery.pointLights.isEmpty || !scenery.negativeLights.isEmpty {
                    Section("Lights") {
                        if !scenery.ambientLights.isEmpty { LabeledContent("Ambient", value: "\(scenery.ambientLights.count)") }
                        if !scenery.directionalLights.isEmpty { LabeledContent("Directional", value: "\(scenery.directionalLights.count)") }
                        if !scenery.pointLights.isEmpty { LabeledContent("Point", value: "\(scenery.pointLights.count)") }
                        if !scenery.negativeLights.isEmpty { LabeledContent("Negative", value: "\(scenery.negativeLights.count)") }
                        Button("Edit Lighting…") { isEditingLighting = true }
                            .disabled(!workspace.canSaveEdits(for: node))
                    }
                }
            }
            .formStyle(.grouped)

            if placements.isEmpty {
                ContentUnavailableView("No Placements", systemImage: "map", description: Text("This record decoded but has no scenery tree. See its own Chunk Name/header fields above."))
            } else {
                Button {
                    isResolving = true
                    Task {
                        // Resolving every placement (mesh + material +
                        // texture lookups for potentially thousands of
                        // objects) runs off the main actor, this used to
                        // block the whole UI for however long that took.
                        await workspace.openLevelViewer(for: scenery, node: node)
                        isResolving = false
                    }
                } label: {
                    if isResolving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Open Chunk Viewer", systemImage: "map")
                    }
                }
                // Code review: `isResolving` only knew about *this* button , 
                // clicking here, then immediately opening a level from the
                // Chunk Hub or the sidebar before this `await` returned,
                // could still start a second overlapping `openLevelViewer`
                // call. `workspace.isOpeningLevelViewer` is shared across
                // all three real entry points.
                .disabled(isResolving || workspace.isOpeningLevelViewer)
            }

            if !workspace.canSaveEdits(for: node) {
                Text("Editing lighting only saves for a standalone-opened .RM2/.SM2 file, this record's file is archive-packed, which this build doesn't have a write path for yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isEditingLighting) {
            SceneryLightingEditorSheet(node: node, scenery: scenery)
        }
    }
}

struct DynamicSceneryInspectorView: View {
    let scenery: DynamicSceneryAsset

    var body: some View {
        if scenery.placements.isEmpty {
            ContentUnavailableView("No Dynamic Scenery", systemImage: "arrow.triangle.2.circlepath")
        } else {
            Form {
                Section("Placements (\(scenery.placements.count))") {
                    ForEach(Array(scenery.placements.enumerated()), id: \.offset) { _, placement in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Model #\(placement.modelID)").font(.callout.bold())
                            Text(String(format: "Resting position: %.2f, %.2f, %.2f", placement.worldPosition.x, placement.worldPosition.y, placement.worldPosition.z))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .formStyle(.grouped)
            Text("Resting position only. Per-frame motion curves aren't modeled yet (see DynamicSceneryDataParser).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
