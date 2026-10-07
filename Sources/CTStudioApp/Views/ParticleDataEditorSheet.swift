import SwiftUI
import CTModels
import CTParsers

/// Write-back editor for a decoded `ParticleData` record, ports
/// `Editors/ParticlesEditor.cs`'s field set for the scalar fields (every
/// `numericUpDown`-bound field the reference exposes), plus a real
/// curve-graph editor (`GradientCurveEditor`/`ColorGradientEditor`,
/// roadmap 10.1) for the reference's own 8-entry gradient curves, color,
/// alpha, size width/height, rotation, and collision, every one a real,
/// confirmed field from this codebase's own decoded model. The two
/// `unkGradient1`/`unkGradient2` curves stay as flat number lists further
/// down: this codebase has no confirmed name *or* value range for them,
/// and a graph implies a scale that isn't verified. List counts
/// (definitions/instances) are fixed by the record's on-disk size, same
/// constraint as every other editor in this app.
struct ParticleDataEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let original: ParticleDataAsset

    @State private var particleTypes: [ParticleSystemDefinition]
    @State private var particleInstances: [ParticleSystemInstance]
    @State private var selectedDefinitionIndex = 0
    @State private var selectedInstanceIndex = 0
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, particleData: ParticleDataAsset) {
        self.node = node
        self.original = particleData
        _particleTypes = State(initialValue: particleData.particleTypes)
        _particleInstances = State(initialValue: particleData.particleInstances)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Particle Data #\(original.id)").font(.title3.bold())

            if !particleTypes.isEmpty {
                Picker("Type", selection: $selectedDefinitionIndex) {
                    ForEach(particleTypes.indices, id: \.self) { i in
                        Text(particleTypes[i].name.isEmpty ? "Type \(i)" : particleTypes[i].name).tag(i)
                    }
                }
                ScrollView {
                    DefinitionFields(definition: $particleTypes[selectedDefinitionIndex])
                    CurveFields(definition: $particleTypes[selectedDefinitionIndex])
                }
                .frame(maxHeight: 480)
            }

            if !particleInstances.isEmpty {
                Picker("Instance", selection: $selectedInstanceIndex) {
                    ForEach(particleInstances.indices, id: \.self) { i in
                        Text(particleInstances[i].name.isEmpty ? "Instance \(i)" : particleInstances[i].name).tag(i)
                    }
                }
                InstanceFields(instance: $particleInstances[selectedInstanceIndex])
            }

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
        .frame(minWidth: 480, minHeight: 520)
    }

    private func save() {
        errorMessage = nil
        var edited = original
        edited.particleTypes = particleTypes
        edited.particleInstances = particleInstances

        let encoded: Data
        do {
            encoded = try ParticleDataWriter.write(edited)
        } catch {
            errorMessage = "\(error)"
            return
        }
        guard let patchedBytes = workspace.patchedFileBytes(replacing: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this particle data changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this particle data changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}

private struct DefinitionFields: View {
    @Binding var definition: ParticleSystemDefinition

    var body: some View {
        Form {
            Section("Emission") {
                LabeledField("Gen Rate", value: Binding(get: { Double(definition.genRate) }, set: { definition.genRate = Int16($0) }))
                LabeledField("Max Particle Count", value: Binding(get: { Double(definition.maxParticleCount) }, set: { definition.maxParticleCount = UInt16(max(0, $0)) }))
                LabeledField("Emitter Over Time", value: Binding(get: { Double(definition.emitterOverTime) }, set: { definition.emitterOverTime = UInt16(max(0, $0)) }))
                LabeledField("Emitter Over Time Random", value: Binding(get: { Double(definition.emitterOverTimeRandom) }, set: { definition.emitterOverTimeRandom = UInt16(max(0, $0)) }))
                LabeledField("Emitter Off Time", value: Binding(get: { Double(definition.emitterOffTime) }, set: { definition.emitterOffTime = UInt16(max(0, $0)) }))
                LabeledField("Emitter Off Time Random", value: Binding(get: { Double(definition.emitterOffTimeRandom) }, set: { definition.emitterOffTimeRandom = UInt16(max(0, $0)) }))
            }
            Section("Motion") {
                LabeledField("Velocity", value: $definition.velocity)
                LabeledField("Random Emit X", value: $definition.randomEmitX)
                LabeledField("Random Emit Y", value: $definition.randomEmitY)
                LabeledField("Random Emit Z", value: $definition.randomEmitZ)
                LabeledField("Random Start X", value: $definition.randomStartX)
                LabeledField("Random Start Y", value: $definition.randomStartY)
                LabeledField("Random Start Z", value: $definition.randomStartZ)
                LabeledField("Gravity", value: $definition.gravity)
                LabeledField("Particle Life Time", value: $definition.particleLifeTime)
            }
            Section("Appearance") {
                LabeledField("Min Size", value: $definition.minSize)
                LabeledField("Max Size", value: $definition.maxSize)
                LabeledField("Min Rotation", value: $definition.minRotation)
                LabeledField("Max Rotation", value: $definition.maxRotation)
                LabeledField("Distortion X", value: $definition.distortionX)
                LabeledField("Distortion Y", value: $definition.distortionY)
                LabeledField("Scale Factor", value: $definition.scaleFactor)
            }
            Section("Radius / Draw") {
                LabeledField("Cut On Radius", value: $definition.cutOnRadius)
                LabeledField("Cut Off Radius", value: $definition.cutOffRadius)
                LabeledField("Draw Cut Off", value: $definition.drawCutOff)
                LabeledField("Texture Page", value: Binding(get: { Double(definition.texturePage) }, set: { definition.texturePage = Int32($0) }))
            }
            Section("Ghosts / Star Radial / Ramp") {
                LabeledField("Ghosts Num", value: Binding(get: { Double(definition.particleGhostsNum) }, set: { definition.particleGhostsNum = Int16($0) }))
                LabeledField("Ghost Separation", value: $definition.ghostSeparation)
                LabeledField("Star Radial Points", value: Binding(get: { Double(definition.starRadialPoints) }, set: { definition.starRadialPoints = Int16($0) }))
                LabeledField("Star Radius Ratio", value: $definition.starRadiusRatio)
                LabeledField("Ramp Time", value: $definition.rampTime)
            }
            Section("Jibber") {
                LabeledField("Jibber X Freq", value: $definition.jibberXFreq)
                LabeledField("Jibber X Amp", value: $definition.jibberXAmp)
                LabeledField("Jibber Y Freq", value: $definition.jibberYFreq)
                LabeledField("Jibber Y Amp", value: $definition.jibberYAmp)
            }
            Section("Collision") {
                LabeledField("Collision Num Spheres", value: Binding(get: { Double(definition.collisionNumSpheres) }, set: { definition.collisionNumSpheres = UInt8(max(0, min(255, $0))) }))
            }
            Section("Generation / Rendering Mode") {
                Picker("Gen Sort", selection: Binding(
                    get: { definition.resolvedGenSort },
                    set: { if let value = $0 { definition.genSort = value.rawValue } }
                )) {
                    Text("(raw \(definition.genSort))").tag(ParticleSystemDefinition.GenSort?.none)
                    ForEach(Self.genSorts, id: \.self) { sort in
                        Text(String(describing: sort)).tag(ParticleSystemDefinition.GenSort?.some(sort))
                    }
                }
                Picker("Texture Filter", selection: Binding(
                    get: { definition.resolvedTextureFilter },
                    set: { if let value = $0 { definition.textureFilter = value.rawValue } }
                )) {
                    Text("(raw \(definition.textureFilter))").tag(ParticleSystemDefinition.TextureFiltering?.none)
                    ForEach(Self.textureFilters, id: \.self) { filter in
                        Text(String(describing: filter)).tag(ParticleSystemDefinition.TextureFiltering?.some(filter))
                    }
                }
                Picker("Draw Flag", selection: Binding(
                    get: { definition.resolvedDrawFlag },
                    set: { if let value = $0 { definition.drawFlag = value.rawValue } }
                )) {
                    Text("(raw \(definition.drawFlag))").tag(ParticleSystemDefinition.DrawFlags?.none)
                    ForEach(Self.drawFlags, id: \.self) { flag in
                        Text(String(describing: flag)).tag(ParticleSystemDefinition.DrawFlags?.some(flag))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static let genSorts: [ParticleSystemDefinition.GenSort] = [.normal, .unk1, .unk2, .unk3, .unk4, .unk5, .radial, .radialRotor, .spheroid, .bounceY, .bounceXZ, .improvedRadial, .starRadial]
    private static let textureFilters: [ParticleSystemDefinition.TextureFiltering] = [.additive, .unknown, .modulation, .subtractive, .unk4, .unk5, .unk6, .glass]
    private static let drawFlags: [ParticleSystemDefinition.DrawFlags] = [.afterFog, .beforeFog, .glassRelated, .superEarly]
}

/// "Particle Curve Graph Editor" (roadmap 10.1), real graphical editors
/// for the six confirmed-named 8-entry gradient curves. See this file's
/// own doc comment for why `unkGradient1`/`unkGradient2` aren't included
/// here.
private struct CurveFields: View {
    @Binding var definition: ParticleSystemDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Curves").font(.headline)
            ColorGradientEditor(colorGradient: $definition.colorGradient)
            GradientCurveEditor(times: $definition.alphaGradientTime, values: $definition.alphaGradientValue, valueLabel: "Alpha", lineColor: .white, fixedRange: 0...255)
            GradientCurveEditor(times: $definition.sizeWidthTime, values: $definition.sizeWidthValue, valueLabel: "Size Width", lineColor: .cyan)
            GradientCurveEditor(times: $definition.sizeHeightTime, values: $definition.sizeHeightValue, valueLabel: "Size Height", lineColor: .teal)
            GradientCurveEditor(
                times: $definition.rotationTime, values: $definition.rotationValue, valueLabel: "Rotation", lineColor: .orange, fixedRange: 0...65535,
                valueFormatter: { String(format: "%.0f (%.0f°)", $0, ($0 / 65535) * 360) }
            )
            GradientCurveEditor(times: $definition.collisionTime, values: $definition.collisionValue, valueLabel: "Collision Sphere Size", lineColor: .pink)
        }
        .padding(.top, 8)
    }
}

private struct InstanceFields: View {
    @Binding var instance: ParticleSystemInstance

    var body: some View {
        Form {
            LabeledField("Position X", value: Binding(get: { Double(instance.position.x) }, set: { instance.position.x = Float($0) }))
            LabeledField("Position Y", value: Binding(get: { Double(instance.position.y) }, set: { instance.position.y = Float($0) }))
            LabeledField("Position Z", value: Binding(get: { Double(instance.position.z) }, set: { instance.position.z = Float($0) }))
            Picker("Switch Type", selection: $instance.switchType) {
                Text("None").tag(Int32(0))
                Text("Global Switch").tag(Int32(1))
            }
            LabeledField("Switch ID", value: Binding(get: { Double(instance.switchID) }, set: { instance.switchID = Int32($0) }))
            LabeledField("Switch Value", value: $instance.switchValue)
            LabeledField("Plane Offset", value: $instance.planeOffset)
            LabeledField("Bounce Factor", value: $instance.bounceFactor)
            LabeledField("Group ID", value: Binding(get: { Double(instance.groupID) }, set: { instance.groupID = Int16($0) }))
        }
        .formStyle(.grouped)
    }
}

/// A `TextField` bound to a `Double`, with tolerant text parsing, every
/// numeric field in this editor funnels through here rather than
/// hand-rolling a `TextField<->String<->Numeric` conversion per field.
private struct LabeledField: View {
    let label: String
    @Binding var value: Double
    @State private var text: String = ""

    init(_ label: String, value: Binding<Double>) {
        self.label = label
        self._value = value
    }

    init(_ label: String, value: Binding<Float>) {
        self.label = label
        self._value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) })
    }

    var body: some View {
        LabeledContent(label) {
            TextField("value", text: $text)
                .textFieldStyle(.roundedBorder)
                .onAppear { text = Self.format(value) }
                .onChange(of: value) { _, newValue in text = Self.format(newValue) }
                .onSubmit { commit() }
                .onChange(of: text) { _, _ in commit() }
        }
    }

    private func commit() {
        if let parsed = Double(text) { value = parsed }
    }

    private static func format(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int64(v)) : "\(v)"
    }
}
