import SwiftUI
import CTModels
import CTParsers

/// Write-back editor for a decoded `SceneryData` record's real lighting
/// sub-structure (`SceneryAsset.ambientLights`/`directionalLights`/
/// `pointLights`/`negativeLights`, ported from `SceneryData.cs`'s
/// `LightAmbient`/`LightDirectional`/`LightPoint`/`LightNegative`, see
/// `SceneryDataParser`/`SceneryDataWriter`'s own doc comments for the full
/// byte-layout citation, cross-checked against `twinsanity-reversed`'s
/// `GameArchivesItemsStructure.txt` "Scenery data" section). Same
/// "Save Edited Copy…" shape as `SkydomeEditorSheet`: parsing/writing were
/// already real and complete before this sheet existed (`SceneryDataWriter.
/// encode` already round-trips every light field byte-exact), this only
/// adds the missing piece, a real editing surface over it.
///
/// Exposes each light's `radius`/`color`/`position`, the fields with an
/// obvious, directly-usable meaning ("how bright", "what color", "where") , 
/// as editable text fields, following the same `LabeledContent` + `TextField`
/// rows `WorldPlacementInspectorViews.swift` uses throughout. Every other
/// real field this format has (`flagsRaw`, `colorUnk`, `vector1`/`2`/`3`,
/// `unkShort`, the `LightNegative`-only unk fields) stays untouched: each
/// edited light starts from a full copy of the original struct, so those
/// fields round-trip through unedited rather than being reset to zero , 
/// same "never invented, never dropped" rule this codebase applies to every
/// other undocumented field.
struct SceneryLightingEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let original: SceneryAsset

    private struct LightFields {
        var radius = ""
        var colorR = ""
        var colorG = ""
        var colorB = ""
        var posX = ""
        var posY = ""
        var posZ = ""
        var posW = ""
    }

    @State private var ambient: [LightFields] = []
    @State private var directional: [LightFields] = []
    @State private var point: [LightFields] = []
    @State private var negative: [LightFields] = []
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, scenery: SceneryAsset) {
        self.node = node
        self.original = scenery
        _ambient = State(initialValue: scenery.ambientLights.map(Self.fields))
        _directional = State(initialValue: scenery.directionalLights.map(Self.fields))
        _point = State(initialValue: scenery.pointLights.map(Self.fields))
        _negative = State(initialValue: scenery.negativeLights.map(Self.fields))
    }

    private static func fields(_ light: SceneryLight) -> LightFields {
        LightFields(
            radius: "\(light.radius)",
            colorR: "\(light.colorR)", colorG: "\(light.colorG)", colorB: "\(light.colorB)",
            posX: "\(light.position.x)", posY: "\(light.position.y)", posZ: "\(light.position.z)", posW: "\(light.position.w)"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Lighting").font(.title3.bold())
            Text("Radius, color, and position are editable. Every other real field on each light (flags, the extra direction/unk vectors, negative-light-only fields) round-trips through unedited, this build doesn't have a documented meaning for them to expose as editable, so it never invents one.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Form {
                lightSection("Ambient (\(ambient.count))", lights: $ambient)
                lightSection("Directional (\(directional.count))", lights: $directional)
                lightSection("Point (\(point.count))", lights: $point)
                lightSection("Negative (\(negative.count))", lights: $negative)
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
        .frame(minWidth: 420, minHeight: 360)
    }

    @ViewBuilder
    private func lightSection(_ title: String, lights: Binding<[LightFields]>) -> some View {
        if !lights.wrappedValue.isEmpty {
            Section(title) {
                ForEach(lights.wrappedValue.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("#\(i)").font(.caption.bold()).foregroundStyle(.secondary)
                        LabeledContent("Radius") { TextField("radius", text: lights[i].radius).textFieldStyle(.roundedBorder) }
                        LabeledContent("Color") {
                            HStack {
                                TextField("R", text: lights[i].colorR).textFieldStyle(.roundedBorder)
                                TextField("G", text: lights[i].colorG).textFieldStyle(.roundedBorder)
                                TextField("B", text: lights[i].colorB).textFieldStyle(.roundedBorder)
                            }
                        }
                        LabeledContent("Position") {
                            HStack {
                                TextField("X", text: lights[i].posX).textFieldStyle(.roundedBorder)
                                TextField("Y", text: lights[i].posY).textFieldStyle(.roundedBorder)
                                TextField("Z", text: lights[i].posZ).textFieldStyle(.roundedBorder)
                                TextField("W", text: lights[i].posW).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// `nil` if any field in `edited`/`fields` fails to parse, same
    /// "collect everything, bail with one honest error" shape
    /// `InstanceInspectorView.editedFullRecord` uses.
    private func applying(_ fields: [LightFields], to lights: [SceneryLight]) -> [SceneryLight]? {
        guard fields.count == lights.count else { return nil }
        var result: [SceneryLight] = []
        result.reserveCapacity(lights.count)
        for (field, original) in zip(fields, lights) {
            guard let radius = Float(field.radius),
                  let r = Float(field.colorR), let g = Float(field.colorG), let b = Float(field.colorB),
                  let x = Float(field.posX), let y = Float(field.posY), let z = Float(field.posZ), let w = Float(field.posW)
            else { return nil }
            var edited = original
            edited.radius = radius
            edited.colorR = r
            edited.colorG = g
            edited.colorB = b
            edited.position = SIMD4(x, y, z, w)
            result.append(edited)
        }
        return result
    }

    private func save() {
        guard let editedAmbient = applying(ambient, to: original.ambientLights),
              let editedDirectional = applying(directional, to: original.directionalLights),
              let editedPoint = applying(point, to: original.pointLights),
              let editedNegative = applying(negative, to: original.negativeLights)
        else {
            errorMessage = "Every Radius/Color/Position field must be a number."
            return
        }
        errorMessage = nil

        var edited = original
        edited.ambientLights = editedAmbient
        edited.directionalLights = editedDirectional
        edited.pointLights = editedPoint
        edited.negativeLights = editedNegative

        let encoded = SceneryDataWriter.encode(edited)
        guard let patchedBytes = workspace.patchedFileBytes(replacingWholeRecord: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_lighting_edited.sm2",
            message: "Save the edited copy of this file, with this scenery record's lighting changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this scenery record's lighting changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
