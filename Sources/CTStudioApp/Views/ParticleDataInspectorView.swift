import SwiftUI
import CTModels

/// Read-only inspector for a decoded `ParticleData` record, the level's
/// particle-effect library: named recipes (`ParticleSystemDefinition`) plus
/// their world placements (`ParticleSystemInstance`). See
/// `ParticleDataAsset`'s doc comment for the version-scoping this decode
/// relies on (only versions 28/30 are parsed).
struct ParticleDataInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let particleData: ParticleDataAsset
    @State private var selectedDefinitionIndex: Int?
    @State private var isEditing = false

    var body: some View {
        Form {
            Section("Particle Data #\(particleData.id)") {
                LabeledContent("Version", value: "\(particleData.version)")
                LabeledContent("Particle Types", value: "\(particleData.particleTypes.count)")
                LabeledContent("Instances", value: "\(particleData.particleInstances.count)")
                if particleData.canWriteBack, workspace.canSaveEdits(for: node) {
                    Button("Edit…") { isEditing = true }
                } else if !particleData.canWriteBack {
                    Text("This record has an on-disk pre-header this build doesn't model. Editing isn't available.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !particleData.particleTypes.isEmpty {
                Section("Particle Types") {
                    Picker("Selected Type", selection: $selectedDefinitionIndex) {
                        Text("None").tag(Int?.none)
                        ForEach(Array(particleData.particleTypes.enumerated()), id: \.offset) { index, definition in
                            Text(definition.name.isEmpty ? "Type \(index)" : definition.name).tag(Int?.some(index))
                        }
                    }
                    if let selectedDefinitionIndex, particleData.particleTypes.indices.contains(selectedDefinitionIndex) {
                        DefinitionDetail(definition: particleData.particleTypes[selectedDefinitionIndex])
                    }
                }
            }

            if !particleData.particleInstances.isEmpty {
                Section("Instances") {
                    ForEach(Array(particleData.particleInstances.enumerated()), id: \.offset) { index, instance in
                        DisclosureGroup(instance.name.isEmpty ? "Instance \(index)" : instance.name) {
                            LabeledContent("Position", value: String(format: "%.2f, %.2f, %.2f", instance.position.x, instance.position.y, instance.position.z))
                            LabeledContent("Group ID", value: "\(instance.groupID)")
                            LabeledContent("Switch", value: "type \(instance.switchType), id \(instance.switchID), value \(instance.switchValue)")
                            LabeledContent("Bounce Factor", value: String(format: "%.3f", instance.bounceFactor))
                            LabeledContent("Plane Offset", value: String(format: "%.3f", instance.planeOffset))
                            LabeledContent("Gravity Rotation", value: "\(instance.gravityRotX), \(instance.gravityRotY)")
                            LabeledContent("Emit Rotation", value: "\(instance.emitRotX), \(instance.emitRotY)")
                            LabeledContent("Definition Offset", value: "\(instance.offset)")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isEditing) {
            ParticleDataEditorSheet(node: node, particleData: particleData)
        }
    }
}

private struct DefinitionDetail: View {
    let definition: ParticleSystemDefinition

    var body: some View {
        Group {
            LabeledContent("Gen Sort", value: definition.resolvedGenSort.map { "\($0)" } ?? "raw \(definition.genSort) (unrecognized)")
            LabeledContent("Texture Filter", value: definition.resolvedTextureFilter.map { "\($0)" } ?? "raw \(definition.textureFilter) (unrecognized)")
            LabeledContent("Draw Flag", value: definition.resolvedDrawFlag.map { "\($0)" } ?? "raw \(definition.drawFlag) (unrecognized)")
            LabeledContent("Gen Rate", value: "\(definition.genRate)")
            LabeledContent("Max Particle Count", value: "\(definition.maxParticleCount)")
            LabeledContent("Velocity", value: String(format: "%.3f", definition.velocity))
            LabeledContent("Gravity", value: String(format: "%.3f", definition.gravity))
            LabeledContent("Particle Life Time", value: String(format: "%.3f", definition.particleLifeTime))
            LabeledContent("Size Range", value: String(format: "%.3f – %.3f", definition.minSize, definition.maxSize))
            LabeledContent("Rotation Range", value: String(format: "%.3f – %.3f", definition.minRotation, definition.maxRotation))
            LabeledContent("Cut On / Off Radius", value: String(format: "%.2f / %.2f", definition.cutOnRadius, definition.cutOffRadius))
            LabeledContent("Draw Cut Off", value: String(format: "%.2f", definition.drawCutOff))
            LabeledContent("Collision Spheres", value: "\(definition.collisionNumSpheres)")
            LabeledContent("Texture Page", value: "\(definition.texturePage)")
            LabeledContent("Scale Factor", value: String(format: "%.3f", definition.scaleFactor))
            LabeledContent("Star Radial Points", value: "\(definition.starRadialPoints)")
        }
    }
}
