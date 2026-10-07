import SwiftUI
import CTModels
import CTParsers

/// Write-back editor for a decoded `CollisionSurface` record, ports
/// `Editors/SurfaceEditor.cs`'s field set. Fixed-size record (114 bytes),
/// so every field here is editable in place with no risk of resizing the
/// file; same decode -> edit -> encode -> patch -> save-as-copy loop as
/// every other write path in this app.
struct CollisionSurfaceEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let original: CollisionSurfaceInfo

    @State private var flags: String
    /// Mirrors `flags` above as a live `UInt32` for the experimental
    /// toggle section below, kept as a separate `@State` (not re-parsed
    /// from `flags` on every toggle) so a toggle keeps working even while
    /// `flags`'s own text field holds a momentarily-invalid string.
    @State private var flagsValue: UInt32
    @State private var surfaceID: String
    @State private var sound1: String
    @State private var sound2: String
    @State private var particle1: String
    @State private var particle2: String
    @State private var sound3: String
    @State private var sound4: String
    @State private var particle3: String
    @State private var sound5: String
    @State private var sound6: String
    @State private var unkFloats: [String]
    @State private var errorMessage: String?
    @State private var isSaving = false
    /// "Sound-to-Entity Mapping UI" (roadmap item 4d): which sound slot's
    /// `SoundEffectPickerSheet` is currently showing, `nil` when none is.
    @State private var pickingSoundSlot: SoundSlot?

    private enum SoundSlot: Identifiable { case sound1, sound2, sound3, sound4, sound5, sound6
        var id: Self { self }
    }

    init(node: ChunkNode, surface: CollisionSurfaceInfo) {
        self.node = node
        self.original = surface
        _flags = State(initialValue: "\(surface.flags)")
        _flagsValue = State(initialValue: surface.flags)
        _surfaceID = State(initialValue: "\(surface.surfaceID)")
        _sound1 = State(initialValue: "\(surface.sound1)")
        _sound2 = State(initialValue: "\(surface.sound2)")
        _particle1 = State(initialValue: "\(surface.particle1)")
        _particle2 = State(initialValue: "\(surface.particle2)")
        _sound3 = State(initialValue: "\(surface.sound3)")
        _sound4 = State(initialValue: "\(surface.sound4)")
        _particle3 = State(initialValue: "\(surface.particle3)")
        _sound5 = State(initialValue: "\(surface.sound5)")
        _sound6 = State(initialValue: "\(surface.sound6)")
        _unkFloats = State(initialValue: [
            surface.unkFloat1, surface.unkFloat2, surface.unkFloat3, surface.unkFloat4, surface.unkFloat5,
            surface.unkFloat6, surface.unkFloat7, surface.unkFloat8, surface.unkFloat9, surface.unkFloat10,
        ].map { "\($0)" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Collision Surface #\(original.surfaceID)").font(.title3.bold())
            Text("65535 is the on-disk \"no sound/particle\" sentinel, enter it to clear a slot.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Form {
                Section("Core") {
                    LabeledContent("Flags") {
                        TextField("value", text: $flags)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: flags) { _, newValue in
                                if let parsed = UInt32(newValue) { flagsValue = parsed }
                            }
                    }
                    LabeledContent("Surface ID") { TextField("value", text: $surfaceID).textFieldStyle(.roundedBorder) }
                }
                Section("Collision Behavior".tagged(.experimentalUnconfirmed)) {
                    Text("No reference source names any bit of this record's Flags field, the reference tool itself only ever prints it as one raw hex value. These four toggles probe specific bit positions this build chose arbitrarily for experimentation; none of them are confirmed to have this (or any) effect in-game. Toggle, save an edited copy, and test in-emulator to find out.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    ForEach(CollisionSurfaceInfo.ExperimentalFlagBit.allCases, id: \.self) { bit in
                        Toggle(bit.label.tagged(.custom("bit \(bit.rawValue), unconfirmed")), isOn: Binding(
                            get: { (flagsValue >> UInt32(bit.rawValue)) & 1 != 0 },
                            set: { newValue in
                                if newValue { flagsValue |= (1 << UInt32(bit.rawValue)) } else { flagsValue &= ~(1 << UInt32(bit.rawValue)) }
                                flags = "\(flagsValue)"
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                Section("Sound / Particle Slots") {
                    Text("\"Pick…\" turns a bare ID into a real choice from this file's own decoded SoundEffect records, this format has no confirmed particle-ID list to pick from the same way, so Particle 1–3 stay raw numeric fields.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    soundSlotField("Sound 1", text: $sound1, slot: .sound1)
                    soundSlotField("Sound 2", text: $sound2, slot: .sound2)
                    LabeledContent("Particle 1") { TextField("value", text: $particle1).textFieldStyle(.roundedBorder) }
                    LabeledContent("Particle 2") { TextField("value", text: $particle2).textFieldStyle(.roundedBorder) }
                    soundSlotField("Sound 3", text: $sound3, slot: .sound3)
                    soundSlotField("Sound 4", text: $sound4, slot: .sound4)
                    LabeledContent("Particle 3") { TextField("value", text: $particle3).textFieldStyle(.roundedBorder) }
                    soundSlotField("Sound 5", text: $sound5, slot: .sound5)
                    soundSlotField("Sound 6", text: $sound6, slot: .sound6)
                }
                Section("Unknown Floats (real, undetermined meaning)") {
                    ForEach(unkFloats.indices, id: \.self) { i in
                        LabeledContent("Unk Float \(i + 1)") { TextField("value", text: $unkFloats[i]).textFieldStyle(.roundedBorder) }
                    }
                }
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
        .frame(minWidth: 420)
        .sheet(item: $pickingSoundSlot) { slot in
            SoundEffectPickerSheet(node: node, allowsNone: true) { selectedID in
                setSoundSlotText(slot, to: "\(selectedID)")
            }
        }
    }

    @ViewBuilder
    private func soundSlotField(_ label: String, text: Binding<String>, slot: SoundSlot) -> some View {
        LabeledContent(label) {
            HStack {
                TextField("value", text: text).textFieldStyle(.roundedBorder)
                Button("Pick…") { pickingSoundSlot = slot }
                    .controlSize(.small)
            }
        }
    }

    private func setSoundSlotText(_ slot: SoundSlot, to value: String) {
        switch slot {
        case .sound1: sound1 = value
        case .sound2: sound2 = value
        case .sound3: sound3 = value
        case .sound4: sound4 = value
        case .sound5: sound5 = value
        case .sound6: sound6 = value
        }
    }

    private func save() {
        guard let flagsValue = UInt32(flags), let surfaceIDValue = UInt16(surfaceID),
              let s1 = UInt16(sound1), let s2 = UInt16(sound2), let p1 = UInt16(particle1), let p2 = UInt16(particle2),
              let s3 = UInt16(sound3), let s4 = UInt16(sound4), let p3 = UInt16(particle3), let s5 = UInt16(sound5), let s6 = UInt16(sound6)
        else {
            errorMessage = "Flags/IDs must be whole numbers in range."
            return
        }
        let floats = unkFloats.map { Float($0) }
        guard floats.allSatisfy({ $0 != nil }) else {
            errorMessage = "Every unknown float must be a valid number."
            return
        }
        errorMessage = nil

        var edited = original
        edited.flags = flagsValue
        edited.surfaceID = surfaceIDValue
        edited.sound1 = s1; edited.sound2 = s2; edited.particle1 = p1; edited.particle2 = p2
        edited.sound3 = s3; edited.sound4 = s4; edited.particle3 = p3; edited.sound5 = s5; edited.sound6 = s6
        let f = floats.compactMap { $0 }
        edited.unkFloat1 = f[0]; edited.unkFloat2 = f[1]; edited.unkFloat3 = f[2]; edited.unkFloat4 = f[3]; edited.unkFloat5 = f[4]
        edited.unkFloat6 = f[5]; edited.unkFloat7 = f[6]; edited.unkFloat8 = f[7]; edited.unkFloat9 = f[8]; edited.unkFloat10 = f[9]

        let encoded = CollisionSurfaceWriter.write(edited)
        guard let patchedBytes = workspace.patchedFileBytes(replacing: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this collision surface changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this collision surface changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
