import SwiftUI
import CTModels
import CTParsers

/// Write-back editor for a decoded `GameObject` record, ports
/// `Editors/ObjectEditor.cs`'s full field set, including create/duplicate/
/// delete-whole-record (`WorkspaceViewModel.gameObjectCollectionNode`/
/// `patchedFileBytes(insertingGameObject:inSameFileAs:)`/
/// `patchedFileBytes(removingGameObject:)`, the same `ChunkSectionInserter`
/// path the Forge Palette trusts for Instance placement). Unlike every
/// field-level "Apply" sheet elsewhere in this app, `GameObject` has no
/// individually offset-patchable fields worth the complexity , 
/// `ScriptSlots`/`PHeader`/`LinkedIDs.flag` are all derived caches
/// recomputed from list contents on save (see `GameObjectWriter`), so any
/// in-place field edit here already needs a whole-record re-encode. One
/// editable working copy, one "Save Edited Copy…" button for in-place
/// edits, same as `SkydomeEditorSheet`'s simpler pattern; New/Duplicate/
/// Delete are separate, immediate structural actions.
struct GameObjectEditorSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode

    @State private var editableObject: GameObjectInfo
    @State private var editingCommand: AgentLabCommand?
    @State private var newCommandIDText = ""
    /// "Sound-to-Entity Mapping UI" (roadmap item 4d): index into
    /// `editableObject.soundIDs` currently being reassigned via
    /// `SoundEffectPickerSheet`, `nil` when the sheet isn't showing.
    @State private var pickingSoundSlotIndex: Int?
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, gameObject: GameObjectInfo) {
        self.node = node
        _editableObject = State(initialValue: gameObject)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GameObject, \(editableObject.name.isEmpty ? "<unnamed>" : editableObject.name)").font(.title3.bold())
                Text("Real write-back: every change here re-encodes and saves the whole record as an edited copy of this file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    generalSection
                    idListsSection
                    instancePropertiesSection
                    linkedIDsSection
                    scriptCommandsSection
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
            Divider()
            HStack {
                Button("New Blank Object…") { createNewObject() }
                    .disabled(isSaving || !workspace.canSaveEdits(for: node))
                    .help("Adds a new blank GameObject and saves it as a copy; doesn't change this one.")
                Button("Duplicate This Object…") { duplicateObject() }
                    .disabled(isSaving || !workspace.canSaveEdits(for: node))
                Button("Delete This Object…", role: .destructive) { deleteObject() }
                    .disabled(isSaving || !workspace.canSaveEdits(for: node))
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
            Text("\"ObjectEditor\" parity, a new object's ID is one past the highest existing GameObject ID (floor 8192), matching the reference editor's own create/duplicate scheme exactly.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)

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
        .sheet(item: $editingCommand) { command in
            AgentLabArgumentEditorSheet(node: node, command: command)
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("General").font(.callout.bold())
            LabeledContent("Object ID") { Text("\(editableObject.id)").font(.caption.monospaced()) }
            LabeledContent("Name") {
                TextField("", text: $editableObject.name).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                Picker("Object Type", selection: Binding(
                    get: { editableObject.resolvedObjectType },
                    set: { newValue in guard let newValue else { return }; setBitfieldField(mask: 0xFF, shift: 0x14, value: UInt32(newValue.rawValue)) }
                )) {
                    Text("(raw \(editableObject.objectTypeRaw))").tag(GameObjectInfo.ObjectTypeID?.none)
                    ForEach(GameObjectInfo.ObjectTypeID.allCases, id: \.self) { type in
                        Text(String(describing: type)).tag(GameObjectInfo.ObjectTypeID?.some(type))
                    }
                }
                .frame(width: 240)

                Picker("Mobile Type", selection: Binding(
                    get: { editableObject.resolvedMobileType },
                    set: { newValue in guard let newValue else { return }; setBitfieldField(mask: 0xFF, shift: 0xC, value: UInt32(newValue.rawValue)) }
                )) {
                    Text("(raw \(editableObject.mobileTypeRaw))").tag(GameObjectInfo.MobileTypeID?.none)
                    ForEach(GameObjectInfo.MobileTypeID.allCases, id: \.self) { type in
                        Text(String(describing: type)).tag(GameObjectInfo.MobileTypeID?.some(type))
                    }
                }
                .frame(width: 220)
            }
            .font(.caption)

            HStack(spacing: 16) {
                Stepper("Joint IDs: \(editableObject.jointIDCount)", value: Binding(
                    get: { Int(editableObject.jointIDCount) },
                    set: { setBitfieldField(mask: 0x3F, shift: 0x6, value: UInt32(clamping: $0)) }
                ), in: 0...63)
                Stepper("Exit Points: \(editableObject.exitPointCount)", value: Binding(
                    get: { Int(editableObject.exitPointCount) },
                    set: { setBitfieldField(mask: 0x3F, shift: 0x0, value: UInt32(clamping: $0)) }
                ), in: 0...63)
            }
            .font(.caption)

            HStack(spacing: 16) {
                Toggle("Use Template", isOn: Binding(
                    get: { editableObject.useTemplate },
                    set: { setBitfieldBit(0x1C, $0) }
                ))
                Toggle("Bitfield Flag 4", isOn: Binding(
                    get: { editableObject.bitfieldFlag4 },
                    set: { setBitfieldBit(0x1F, $0) }
                ))
            }
            .font(.caption)
            .toggleStyle(.checkbox)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    /// Replaces an arbitrary-width field within `unkBitfield` at `shift`,
    /// masked to `mask` bits, same "clear then OR in" pattern
    /// `MainScriptEditorSheet.applyType1` already uses for `SupportType1.
    /// unkInt1Raw`.
    private func setBitfieldField(mask: UInt32, shift: UInt32, value: UInt32) {
        editableObject.unkBitfield &= ~(mask << shift)
        editableObject.unkBitfield |= (value & mask) << shift
    }

    private func setBitfieldBit(_ bit: UInt32, _ value: Bool) {
        if value { editableObject.unkBitfield |= (1 << bit) } else { editableObject.unkBitfield &= ~(1 << bit) }
    }

    // MARK: - ID lists

    private var idListsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ID Lists").font(.callout.bold())
            uint32ListEditor(title: "UI32 (Events)", values: $editableObject.ui32)
            uint32ListEditor(title: "Graphics Info (OGI) Links", values: $editableObject.ogiIDs)
            uint16ListEditor(title: "Animations", values: $editableObject.animIDs)
            uint16ListEditor(title: "Scripts", values: $editableObject.scriptIDs)
            uint16ListEditor(title: "Objects", values: $editableObject.objectIDs)
            soundIDListEditor
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    /// Same shape as `uint16ListEditor` but with a real "Pick…" button per
    /// slot, see `SoundEffectPickerSheet`'s own doc comment for why this
    /// replaces a bare numeric field with a picker over this file's real,
    /// decoded sounds. The raw text field stays too: a level's sound bank
    /// isn't guaranteed to be in the same file this `GameObject` lives in,
    /// so a picker that finds nothing shouldn't be the only way to set
    /// this value.
    @ViewBuilder
    private var soundIDListEditor: some View {
        DisclosureGroup("Sounds (\(editableObject.soundIDs.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(editableObject.soundIDs.indices, id: \.self) { i in
                    HStack {
                        TextField("value", text: Binding(
                            get: { "\(editableObject.soundIDs[i])" },
                            set: { if let v = UInt16($0) { editableObject.soundIDs[i] = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .frame(width: 70)
                        Button("Pick…") { pickingSoundSlotIndex = i }
                            .controlSize(.small)
                        Button(role: .destructive) { editableObject.soundIDs.remove(at: i) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove Sound ID")
                    }
                }
                HStack {
                    Button("Add") { editableObject.soundIDs.append(0) }
                        .controlSize(.small)
                    Button("Add via Picker…") {
                        editableObject.soundIDs.append(0)
                        pickingSoundSlotIndex = editableObject.soundIDs.count - 1
                    }
                    .controlSize(.small)
                }
            }
            .padding(.leading, 8)
        }
        .font(.caption)
        .sheet(item: Binding<PickingSoundSlot?>(
            get: { pickingSoundSlotIndex.map(PickingSoundSlot.init) },
            set: { pickingSoundSlotIndex = $0?.index }
        )) { slot in
            SoundEffectPickerSheet(node: node) { selectedID in
                if editableObject.soundIDs.indices.contains(slot.index) {
                    editableObject.soundIDs[slot.index] = selectedID
                }
            }
        }
    }

    /// `Identifiable` wrapper so `pickingSoundSlotIndex: Int?` (a plain
    /// optional Int has no stable per-presentation identity of its own)
    /// can drive `.sheet(item:)`.
    private struct PickingSoundSlot: Identifiable {
        let index: Int
        var id: Int { index }
    }

    // MARK: - Instance properties ("Template")

    private var instancePropertiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Instance Properties (Template)").font(.callout.bold())
                Spacer()
                Toggle("Present", isOn: Binding(
                    get: { editableObject.instanceProperties != nil },
                    set: { present in
                        if present {
                            editableObject.unkBitfield |= 0x2000_0000
                            if editableObject.instanceProperties == nil {
                                editableObject.instanceProperties = GameObjectInfo.InstanceProperties(pHeader: 0, pUI32: 0, flags: [], floats: [], integers: [])
                            }
                        } else {
                            editableObject.unkBitfield &= ~0x2000_0000
                            editableObject.instanceProperties = nil
                        }
                    }
                ))
                .toggleStyle(.checkbox)
            }
            if editableObject.instanceProperties != nil {
                LabeledContent("PUI32 (Flags)") {
                    TextField("", text: Binding(
                        get: { "\(editableObject.instanceProperties?.pUI32 ?? 0)" },
                        set: { if let v = UInt32($0) { editableObject.instanceProperties?.pUI32 = v } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                }
                .font(.caption)
                uint32ListEditor(title: "Instance Flags", values: Binding(
                    get: { editableObject.instanceProperties?.flags ?? [] },
                    set: { editableObject.instanceProperties?.flags = $0 }
                ))
                floatListEditor(title: "Instance Floats", values: Binding(
                    get: { editableObject.instanceProperties?.floats ?? [] },
                    set: { editableObject.instanceProperties?.floats = $0 }
                ))
                uint32ListEditor(title: "Instance Integers", values: Binding(
                    get: { editableObject.instanceProperties?.integers ?? [] },
                    set: { editableObject.instanceProperties?.integers = $0 }
                ))
                aiBehaviorExperimentalSection
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.06)))
    }

    /// "AI/Behavior Inspector" (roadmap item 4c): "Aggression"/"Patrol
    /// Radius"/"Health"/"Respawn Delay" have no confirmed mapping anywhere
    /// in this project's reference material, `ObjectEditor.Designer.cs`
    /// labels the three lists above only generically ("Instance flags"/
    /// "Instance floats"/"Instance integers", plus a self-contradictory
    /// "Instance angles" label on the widget group actually wired to the
    /// flags list, see `ObjectEditor.cs`'s own `instFlagsManipulator`
    /// binding), never per-index. So this is the honest scaffold the task
    /// calls for: real, working, wired-to-real-on-disk-data editors for a
    /// few chosen slots of `instanceProperties.floats`/`integers`, tagged
    /// with these user-facing labels for convenience only, **not** a
    /// claim that slot 0 of `floats` really is "Aggression" in the game's
    /// own logic. Padding a short array up to the needed length rather
    /// than disabling the field keeps this usable on a record that hasn't
    /// populated these slots yet.
    private var aiBehaviorExperimentalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("AI Behavior".tagged(.experimentalUnconfirmed)).font(.caption.bold())
            Text("No reference source maps any index of Instance Floats/Integers to a specific gameplay meaning, these four fields just relabel chosen slots of the real lists above for convenience. Editing here edits the exact same underlying data as the raw list editors; the labels themselves are this build's own guess, not verified.")
                .font(.caption2)
                .foregroundStyle(.orange)
            experimentalFloatSlotField(label: "Aggression", index: 0)
            experimentalFloatSlotField(label: "Patrol Radius", index: 1)
            experimentalFloatSlotField(label: "Respawn Delay", index: 2)
            experimentalIntegerSlotField(label: "Health", index: 0)
        }
    }

    private func experimentalFloatSlotField(label: String, index: Int) -> some View {
        LabeledContent(label.tagged(.custom("Floats[\(index)], unconfirmed"))) {
            TextField("value", text: Binding(
                get: {
                    let floats = editableObject.instanceProperties?.floats ?? []
                    return floats.indices.contains(index) ? "\(floats[index])" : "0"
                },
                set: { newValue in
                    guard let parsed = Float(newValue) else { return }
                    var floats = editableObject.instanceProperties?.floats ?? []
                    while floats.count <= index { floats.append(0) }
                    floats[index] = parsed
                    editableObject.instanceProperties?.floats = floats
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
        }
        .font(.caption)
    }

    private func experimentalIntegerSlotField(label: String, index: Int) -> some View {
        LabeledContent(label.tagged(.custom("Integers[\(index)], unconfirmed"))) {
            TextField("value", text: Binding(
                get: {
                    let integers = editableObject.instanceProperties?.integers ?? []
                    return integers.indices.contains(index) ? "\(integers[index])" : "0"
                },
                set: { newValue in
                    guard let parsed = UInt32(newValue) else { return }
                    var integers = editableObject.instanceProperties?.integers ?? []
                    while integers.count <= index { integers.append(0) }
                    integers[index] = parsed
                    editableObject.instanceProperties?.integers = integers
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
        }
        .font(.caption)
    }

    // MARK: - Linked IDs ("Resources")

    private var linkedIDsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Linked Resource IDs").font(.callout.bold())
                Spacer()
                Toggle("Present", isOn: Binding(
                    get: { editableObject.linkedIDs != nil },
                    set: { present in
                        if present {
                            editableObject.unkBitfield |= 0x4000_0000
                            if editableObject.linkedIDs == nil {
                                editableObject.linkedIDs = GameObjectInfo.LinkedIDs(flag: 0, objects: [], ogis: [], anims: [], codeModels: [], scripts: [], unk: [], sounds: [])
                            }
                        } else {
                            editableObject.unkBitfield &= ~0x4000_0000
                            editableObject.linkedIDs = nil
                        }
                    }
                ))
                .toggleStyle(.checkbox)
            }
            if editableObject.linkedIDs != nil {
                Text("Each list's presence bit is recomputed on save from whether it's non-empty, no separate toggle needed per list.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                uint16ListEditor(title: "Linked Objects", values: Binding(get: { editableObject.linkedIDs?.objects ?? [] }, set: { editableObject.linkedIDs?.objects = $0 }))
                uint16ListEditor(title: "Linked OGIs", values: Binding(get: { editableObject.linkedIDs?.ogis ?? [] }, set: { editableObject.linkedIDs?.ogis = $0 }))
                uint16ListEditor(title: "Linked Animations", values: Binding(get: { editableObject.linkedIDs?.anims ?? [] }, set: { editableObject.linkedIDs?.anims = $0 }))
                uint16ListEditor(title: "Linked Code Models", values: Binding(get: { editableObject.linkedIDs?.codeModels ?? [] }, set: { editableObject.linkedIDs?.codeModels = $0 }))
                uint16ListEditor(title: "Linked Scripts", values: Binding(get: { editableObject.linkedIDs?.scripts ?? [] }, set: { editableObject.linkedIDs?.scripts = $0 }))
                uint16ListEditor(title: "Linked Unknown", values: Binding(get: { editableObject.linkedIDs?.unk ?? [] }, set: { editableObject.linkedIDs?.unk = $0 }))
                uint16ListEditor(title: "Linked Sounds", values: Binding(get: { editableObject.linkedIDs?.sounds ?? [] }, set: { editableObject.linkedIDs?.sounds = $0 }))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.06)))
    }

    // MARK: - Script commands

    private var scriptCommandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Script Commands (\(editableObject.scriptCommands.count))").font(.callout.bold())
            ForEach(Array(editableObject.scriptCommands.enumerated()), id: \.offset) { index, command in
                HStack {
                    Text(command.commandName ?? "Command #\(command.commandID)")
                        .font(.caption.monospaced())
                    Text("(\(command.rawArguments.count) arg\(command.rawArguments.count == 1 ? "" : "s"))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit Arguments…") { editingCommand = command }
                        .controlSize(.small)
                        .disabled(!workspace.canSaveEdits(for: node) || command.fileOffset == 0)
                        .help(command.fileOffset == 0 ? "Save and reopen the file first, this command has no on-disk offset yet." : "")
                    Button("Delete", role: .destructive) { editableObject.scriptCommands.remove(at: index) }
                        .controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                Text("New command ID:").font(.caption2)
                TextField("", text: $newCommandIDText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(.caption2.monospaced())
                Button("Add Command") { addCommand() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.06)))
    }

    private func addCommand() {
        let text = newCommandIDText.trimmingCharacters(in: .whitespaces)
        guard let commandID = UInt16(text) else {
            errorMessage = "New command ID (\"\(text)\") isn't a valid 16-bit integer."
            return
        }
        errorMessage = nil
        let size = AgentLabCommandCatalog.commandSize(forID: commandID, platform: platform)
        let argCount = size > 0x0C ? (size - 0x0C) / 4 : 0
        let command = AgentLabCommand(
            commandID: commandID,
            unkShort: 0,
            commandName: AgentLabCommandCatalog.commandName(forID: commandID),
            rawArguments: Array(repeating: 0, count: argCount),
            decoded: AgentLabActionDecoder.decode(commandID: commandID, arguments: Array(repeating: 0, count: argCount)),
            fileOffset: 0
        )
        editableObject.scriptCommands.append(command)
        newCommandIDText = ""
    }

    /// Which per-platform command-size table applies, same reasoning as
    /// `MainScriptEditorSheet.platform`, read from this leaf record's own
    /// `SectionType` (`.objectDemo` -> demo, everything else -> PS2; there
    /// is no `.objectX` on disk, matching `TwinsFileKind`'s own coverage).
    private var platform: AgentLabPlatformVariant {
        node.sectionType == .objectDemo ? .demo : .ps2
    }

    // MARK: - Generic list editors

    @ViewBuilder
    private func uint32ListEditor(title: String, values: Binding<[UInt32]>) -> some View {
        DisclosureGroup("\(title) (\(values.wrappedValue.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(values.wrappedValue.indices, id: \.self) { i in
                    HStack {
                        TextField("value", text: Binding(
                            get: { "\(values.wrappedValue[i])" },
                            set: { if let v = UInt32($0) { values.wrappedValue[i] = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        Button(role: .destructive) { values.wrappedValue.remove(at: i) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(title) Entry")
                    }
                }
                Button("Add") { values.wrappedValue.append(0) }
                    .controlSize(.small)
            }
            .padding(.leading, 8)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func uint16ListEditor(title: String, values: Binding<[UInt16]>) -> some View {
        DisclosureGroup("\(title) (\(values.wrappedValue.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(values.wrappedValue.indices, id: \.self) { i in
                    HStack {
                        TextField("value", text: Binding(
                            get: { "\(values.wrappedValue[i])" },
                            set: { if let v = UInt16($0) { values.wrappedValue[i] = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        Button(role: .destructive) { values.wrappedValue.remove(at: i) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(title) Entry")
                    }
                }
                Button("Add") { values.wrappedValue.append(0) }
                    .controlSize(.small)
            }
            .padding(.leading, 8)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func floatListEditor(title: String, values: Binding<[Float]>) -> some View {
        DisclosureGroup("\(title) (\(values.wrappedValue.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(values.wrappedValue.indices, id: \.self) { i in
                    HStack {
                        TextField("value", text: Binding(
                            get: { "\(values.wrappedValue[i])" },
                            set: { if let v = Float($0) { values.wrappedValue[i] = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        Button(role: .destructive) { values.wrappedValue.remove(at: i) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(title) Entry")
                    }
                }
                Button("Add") { values.wrappedValue.append(0) }
                    .controlSize(.small)
            }
            .padding(.leading, 8)
        }
        .font(.caption)
    }

    /// A blank object (`id` assigned by `WorkspaceViewModel` itself, per
    /// its own doc comment), matches the reference's own
    /// `createObjectToolStripMenuItem_Click` defaults (empty name/lists).
    private func createNewObject() {
        let blank = GameObjectInfo(id: 0, name: "New Game Object", ogiIDs: [])
        guard let (patchedBytes, insertedID) = workspace.patchedFileBytes(insertingGameObject: blank, inSameFileAs: node) else { return }
        saveAsCopy(patchedBytes, suffix: "object_\(insertedID)_added", statusSuffix: "with new GameObject #\(insertedID) added")
    }

    /// Inserts a copy of `editableObject`, the currently in-sheet edited
    /// state, not necessarily what's still on disk, as a brand-new
    /// record with its own fresh ID. The object currently open in this
    /// sheet is untouched either way.
    private func duplicateObject() {
        guard let (patchedBytes, insertedID) = workspace.patchedFileBytes(insertingGameObject: editableObject, inSameFileAs: node) else { return }
        saveAsCopy(patchedBytes, suffix: "object_\(insertedID)_duplicated", statusSuffix: "with GameObject #\(editableObject.id) duplicated as #\(insertedID)")
    }

    private func deleteObject() {
        guard let patchedBytes = workspace.patchedFileBytes(removingGameObject: node) else { return }
        saveAsCopy(patchedBytes, suffix: "object_\(editableObject.id)_deleted", statusSuffix: "with GameObject #\(editableObject.id) deleted")
        dismiss()
    }

    private func saveAsCopy(_ patchedBytes: Data, suffix: String, statusSuffix: String) {
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_\(suffix).rm2",
            message: "Save the edited copy of this file, \(statusSuffix). The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) \(statusSuffix)."
                isSaving = false
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }

    private func save() {
        errorMessage = nil
        let encoded = GameObjectWriter.encode(editableObject)
        guard let patchedBytes = workspace.patchedFileBytes(replacingWholeRecord: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this GameObject changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with GameObject #\(editableObject.id) changed."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
