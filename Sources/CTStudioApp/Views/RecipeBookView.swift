import SwiftUI
import CTModels
import CTParsers

/// "Recipe Book, Asset Swap & Quick-Test" (roadmap 6.4): reassigns which
/// real `GameObject` an existing `Instance` placement resolves to, a
/// character/prop swap built on `PlacedInstance.objectIDFileOffset`
/// (Task 1's arbitrary-offset patch, reused for a different field). Every
/// swap candidate offered here is a real `objectID` that already appears
/// somewhere in this level's own `Instance` records, resolved to its real
/// display name via the same `resolvedInstanceAssets` the 3D viewport
/// already uses, never an invented ID.
///
/// The roadmap's other half, "live Sprite-Sheet Canvas for quick texture
/// replacement", isn't built *here*: it lives in `TextureInspectorView`'s
/// "Replace with Image…" instead, since it operates on `Texture` records,
/// not `Instance` placements, and this view has no access to a level's
/// individual textures, only the objects placed in it. That feature is
/// real now (`TextureWriter.replacingPixelData`, PSMCT32 only, see its
/// doc comment for why other GS formats aren't attempted), so this view
/// stays scoped to what its own data actually supports: character/prop
/// swap via `objectID` reassignment (see
/// `WorldPlacementWriter.writeInstanceObjectID`).
struct RecipeBookView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)]
    let resolvedInstanceAssets: [UUID: ResolvedModelAsset]
    /// "Trigger Presets" (roadmap 9, the CrateModLoader-style "toggle a
    /// preset, it patches every matching real record" pattern, applied to
    /// `TriggerVolume` the same way `pendingSwaps` already applies it to
    /// `Instance`). Defaults to `[]` so every existing call site (which
    /// predates this) keeps compiling unchanged.
    var triggers: [(node: ChunkNode, trigger: TriggerVolume)] = []
    /// Backs the "Unlocked Camera" mod, real placed `Camera` records this
    /// chunk contains. Defaults to `[]` for the same reason `triggers` does.
    var cameras: [(node: ChunkNode, camera: PlacedCamera)] = []
    let referenceNode: ChunkNode

    /// `node.id` -> chosen replacement `objectID` (only entries that
    /// differ from the placement's real, on-disk `objectID` end up here).
    @State private var pendingSwaps: [UUID: UInt16] = [:]
    /// `node.id` -> chosen replacement 4-argument tuple (only entries that
    /// differ from the trigger's real, on-disk arguments end up here).
    @State private var pendingTriggerSwaps: [UUID: (UInt16, UInt16, UInt16, UInt16)] = [:]
    @State private var searchText = ""
    /// "Gameplay Mods" (verified, CrateModLoader-sourced toggles, see
    /// `GameplayModCatalog`), which mod IDs are currently checked on.
    @State private var enabledGameplayMods: Set<String> = []
    /// "Unlocked Camera" (CrateModLoader's `TS_UnlockedCamera`), real
    /// enabled/disabled placed-Camera IDs the user has toggled away from
    /// their on-disk state.
    @State private var pendingCameraDisables: Set<UUID> = []
    @State private var isSaving = false
    @State private var showingUnsavedCloseConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if instanceMarkers.isEmpty && triggerGroups.isEmpty {
                ContentUnavailableView("No Placements", systemImage: "shippingbox",
                    description: Text("This chunk has no Instance placements or shared-signature Trigger groups to work with."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // `List` manages its own scrolling and wants to be the
                // primary flexible-height element; the trigger section is
                // secondary (usually far fewer rows) and gets its own
                // bounded `ScrollView` rather than nesting a `List` inside
                // one, which fights over scroll ownership.
                if !instanceMarkers.isEmpty { list }
                if !applicableGameplayMods.isEmpty || !enabledCameras.isEmpty {
                    Divider()
                    ScrollView { gameplayModsSection }
                        .frame(maxHeight: 200)
                }
                if !triggerGroups.isEmpty {
                    Divider()
                    ScrollView { triggerPresetsSection }
                        .frame(maxHeight: instanceMarkers.isEmpty ? .infinity : 220)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
        .alert("You have unapplied recipe changes", isPresented: $showingUnsavedCloseConfirmation) {
            Button("Close Without Applying", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(pendingChangeCount) change(s) queued here haven't been applied yet. Closing now will lose them.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recipe Book").font(.title2.bold())
                Spacer()
                Button("Close") {
                    if pendingChangeCount > 0 {
                        showingUnsavedCloseConfirmation = true
                    } else {
                        dismiss()
                    }
                }
            }
            Text("Reassign which real object each placement resolves to. Every choice below is a real objectID already used somewhere in this chunk, nothing here is invented. Applying writes an edited copy of the file; the original is never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search placements…", text: $searchText)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
    }

    private var swapCandidates: [(objectID: UInt16, displayName: String)] {
        var byID: [UInt16: String] = [:]
        for entry in instanceMarkers {
            guard byID[entry.instance.objectID] == nil else { continue }
            let name = resolvedInstanceAssets[entry.node.id]?.displayName ?? "Object #\(entry.instance.objectID) (unresolved)"
            byID[entry.instance.objectID] = name
        }
        return byID.map { (objectID: $0.key, displayName: $0.value) }.sorted { $0.displayName < $1.displayName }
    }

    private var filteredMarkers: [(node: ChunkNode, instance: PlacedInstance)] {
        guard !searchText.isEmpty else { return instanceMarkers }
        return instanceMarkers.filter { entry in
            let name = resolvedInstanceAssets[entry.node.id]?.displayName ?? "Object #\(entry.instance.objectID)"
            return name.localizedCaseInsensitiveContains(searchText) || "\(entry.instance.id)".contains(searchText)
        }
    }

    private var list: some View {
        List(filteredMarkers, id: \.node.id) { entry in
            RecipeRow(
                entry: entry,
                currentName: resolvedInstanceAssets[entry.node.id]?.displayName ?? "Object #\(entry.instance.objectID) (unresolved)",
                candidates: swapCandidates,
                selection: Binding(
                    get: { pendingSwaps[entry.node.id] ?? entry.instance.objectID },
                    set: { newValue in
                        if newValue == entry.instance.objectID {
                            pendingSwaps[entry.node.id] = nil
                        } else {
                            pendingSwaps[entry.node.id] = newValue
                        }
                    }
                ),
                applyToAllMatching: { newValue in
                    for match in instanceMarkers where match.instance.objectID == entry.instance.objectID {
                        pendingSwaps[match.node.id] = newValue == match.instance.objectID ? nil : newValue
                    }
                }
            )
        }
    }

    // MARK: - Gameplay Mods

    /// Every catalog mod that matches at least one placement's real, on-disk
    /// `objectID` in this chunk, mirroring `swapCandidates`'/`triggerGroups`'
    /// discipline of only ever offering something grounded in this chunk's
    /// own data, never a mod that couldn't possibly do anything here.
    private var applicableGameplayMods: [(mod: GameplayMod, eligibleCount: Int)] {
        GameplayModCatalog.allMods.compactMap { mod in
            let eligible = instanceMarkers.filter { mod.matchesObjectIDs.contains($0.instance.objectID) }
            let applicable = eligible.filter { mod.patch($0.instance) != nil }
            guard !eligible.isEmpty else { return nil }
            return (mod, applicable.count)
        }
    }

    private var gameplayModsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gameplay Mods").font(.headline).padding(.horizontal).padding(.top, 8)
            Text("Verified toggles ported from CrateModLoader's own Twinsanity mod list. These are real field patches, not invented ones. See each mod's description for exactly what it does.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            ForEach(applicableGameplayMods, id: \.mod.id) { entry in
                Toggle(isOn: Binding(
                    get: { enabledGameplayMods.contains(entry.mod.id) },
                    set: { isOn in
                        if isOn { enabledGameplayMods.insert(entry.mod.id) } else { enabledGameplayMods.remove(entry.mod.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.mod.title).font(.callout)
                            Text("(\(entry.eligibleCount) placement\(entry.eligibleCount == 1 ? "" : "s"))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.mod.summary).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .disabled(entry.eligibleCount == 0)
                .padding(.horizontal)
            }
            if !enabledCameras.isEmpty {
                Toggle(isOn: Binding(
                    get: { !pendingCameraDisables.isEmpty },
                    set: { isOn in
                        pendingCameraDisables = isOn ? Set(enabledCameras.map(\.node.id)) : []
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Unlocked Camera").font(.callout)
                            Text("(\(enabledCameras.count) placement\(enabledCameras.count == 1 ? "" : "s"))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("Disables every enabled placed Camera volume in this chunk (CrateModLoader's TS_UnlockedCamera), freeing the view from fixed camera locks.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 8)
    }

    /// Placed cameras whose real, on-disk `enabledMask` is nonzero, the
    /// only ones "Unlocked Camera" has anything to do.
    private var enabledCameras: [(node: ChunkNode, camera: PlacedCamera)] {
        cameras.filter { $0.camera.enabledMask != 0 }
    }

    /// Byte-range edits for the "Unlocked Camera" toggle, re-encodes each
    /// disabled camera's full, real 60-byte `Trigger`/`Camera`-shared
    /// prefix (`writeTriggerOrCameraPrefix`) with every field unchanged
    /// except `enabledMask`, patched at the record's own start (this
    /// prefix is always the first 60 bytes of a `Camera` record).
    private var cameraDisableEdits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] {
        guard !pendingCameraDisables.isEmpty else { return [] }
        return cameras.compactMap { entry in
            guard pendingCameraDisables.contains(entry.node.id) else { return nil }
            let cam = entry.camera
            let encoded = WorldPlacementWriter.writeTriggerOrCameraPrefix(
                header: cam.header,
                enabledMask: 0,
                someFloat: cam.someFloat,
                rotationQuaternion: cam.rotationQuaternion,
                position: cam.position,
                size: cam.size
            )
            return (entry.node, entry.node.fileOffset, encoded)
        }
    }

    /// Every byte-range edit the currently-enabled Gameplay Mods produce , 
    /// one `GameplayMod.patch` call per matching instance, translated from
    /// sparse element indices to absolute file offsets via the offsets
    /// `WorldPlacementParser.parseInstance` captured for exactly this
    /// purpose.
    private var gameplayModEdits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] {
        guard !enabledGameplayMods.isEmpty else { return [] }
        var edits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] = []
        for entry in instanceMarkers {
            for mod in GameplayModCatalog.allMods where enabledGameplayMods.contains(mod.id) {
                guard mod.matchesObjectIDs.contains(entry.instance.objectID),
                      let patch = mod.patch(entry.instance) else { continue }
                for (index, value) in patch.floatListElements {
                    let offset = entry.node.fileOffset + entry.instance.unknownFloatListFileOffset + index * 4
                    edits.append((entry.node, offset, WorldPlacementWriter.writeInstanceUnknownFloatElement(value)))
                }
                for (index, value) in patch.uint32ListElements {
                    let offset = entry.node.fileOffset + entry.instance.unknownUInt32ListFileOffset + index * 4
                    edits.append((entry.node, offset, WorldPlacementWriter.writeInstanceUnknownUInt32Element(value)))
                }
                for (index, value) in patch.uint32List2Elements {
                    let offset = entry.node.fileOffset + entry.instance.unknownUInt32List2FileOffset + index * 4
                    edits.append((entry.node, offset, WorldPlacementWriter.writeInstanceUnknownUInt32Element(value)))
                }
                if let flags = patch.flags {
                    let offset = entry.node.fileOffset + entry.instance.flagsFileOffset
                    edits.append((entry.node, offset, WorldPlacementWriter.writeInstanceFlags(flags)))
                }
            }
        }
        return edits
    }

    // MARK: - Trigger Presets

    /// Every group of 2+ triggers that currently share the exact same
    /// real, on-disk 4-argument signature, mirroring `swapCandidates`'
    /// discipline for Instance objectIDs: this build has no verified
    /// *name* for what any `TriggerVolume` argument means (see
    /// `TriggerArgumentsEditorSheet`'s own doc comment), so a preset here
    /// isn't "the Classic Explosions hack," it's "make every trigger that
    /// currently matches this one also match whatever you change it to" , 
    /// a real, mechanical batch operation, not an invented meaning for
    /// bytes this codebase hasn't confirmed.
    private var triggerGroups: [(signature: (UInt16, UInt16, UInt16, UInt16), members: [(node: ChunkNode, trigger: TriggerVolume)])] {
        var bySignature: [String: [(node: ChunkNode, trigger: TriggerVolume)]] = [:]
        for entry in triggers {
            let t = entry.trigger
            bySignature["\(t.arg1),\(t.arg2),\(t.arg3),\(t.arg4)", default: []].append(entry)
        }
        return bySignature.values
            .filter { $0.count > 1 }
            .map { members in
                let t = members[0].trigger
                return ((t.arg1, t.arg2, t.arg3, t.arg4), members)
            }
            .sorted { $0.members.count > $1.members.count }
    }

    private var triggerPresetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trigger Presets").font(.headline).padding(.horizontal).padding(.top, 8)
            Text("Groups of triggers that currently share the exact same 4 argument values. Change one and apply it to the whole group at once.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            ForEach(Array(triggerGroups.enumerated()), id: \.offset) { _, group in
                TriggerPresetRow(
                    group: group,
                    values: Binding(
                        get: { pendingTriggerSwaps[group.members[0].node.id] ?? group.signature },
                        set: { newValue in applyTriggerGroup(group, newValue: newValue) }
                    )
                )
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 8)
    }

    private func applyTriggerGroup(_ group: (signature: (UInt16, UInt16, UInt16, UInt16), members: [(node: ChunkNode, trigger: TriggerVolume)]), newValue: (UInt16, UInt16, UInt16, UInt16)) {
        let matchesOriginal = newValue == group.signature
        for member in group.members {
            pendingTriggerSwaps[member.node.id] = matchesOriginal ? nil : newValue
        }
    }

    /// Real, reported bug (same class as the Level Viewer's own "closing
    /// loses unsaved edits with no warning" fix): every one of these is a
    /// real, staged, not-yet-applied change, `footer` already surfaces
    /// this exact count as "N change(s) queued," and applying them is a
    /// separate, deliberate "Apply Recipe…" step, so `Button("Close")`
    /// discarding them with zero confirmation was silent data loss, not a
    /// formality.
    private var pendingChangeCount: Int {
        pendingSwaps.count + pendingTriggerSwaps.count + enabledGameplayMods.count + (pendingCameraDisables.isEmpty ? 0 : 1)
    }

    private var footer: some View {
        HStack {
            Text(pendingChangeCount == 0 ? "No changes queued." : "\(pendingChangeCount) change(s) queued.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(isSaving ? "Saving…" : "Apply Recipe…") { applyRecipe() }
                .disabled(pendingChangeCount == 0 || isSaving)
        }
        .padding()
    }

    private func applyRecipe() {
        var edits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] = instanceMarkers.compactMap { entry in
            guard let newID = pendingSwaps[entry.node.id] else { return nil }
            let encoded = WorldPlacementWriter.writeInstanceObjectID(newID)
            return (entry.node, entry.node.fileOffset + entry.instance.objectIDFileOffset, encoded)
        }
        edits += triggers.compactMap { entry in
            guard let newArgs = pendingTriggerSwaps[entry.node.id] else { return nil }
            let encoded = WorldPlacementWriter.writeTriggerArguments(newArgs.0, newArgs.1, newArgs.2, newArgs.3)
            return (entry.node, entry.node.fileOffset + entry.trigger.argsFileOffset, encoded)
        }
        edits += gameplayModEdits
        edits += cameraDisableEdits
        guard !edits.isEmpty, let patchedBytes = workspace.patchedFileBytes(applyingAbsoluteByteRangePatches: edits) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(workspace.originalFileName(for: referenceNode) ?? "chunk")_recipe.rm2",
            message: "Save the edited copy of this file with \(edits.count) change(s) applied. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with \(edits.count) change(s)."
                pendingSwaps.removeAll()
                pendingTriggerSwaps.removeAll()
                enabledGameplayMods.removeAll()
                pendingCameraDisables.removeAll()
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}

private struct TriggerPresetRow: View {
    let group: (signature: (UInt16, UInt16, UInt16, UInt16), members: [(node: ChunkNode, trigger: TriggerVolume)])
    @Binding var values: (UInt16, UInt16, UInt16, UInt16)

    @State private var a1: String
    @State private var a2: String
    @State private var a3: String
    @State private var a4: String

    init(group: (signature: (UInt16, UInt16, UInt16, UInt16), members: [(node: ChunkNode, trigger: TriggerVolume)]), values: Binding<(UInt16, UInt16, UInt16, UInt16)>) {
        self.group = group
        self._values = values
        _a1 = State(initialValue: "\(values.wrappedValue.0)")
        _a2 = State(initialValue: "\(values.wrappedValue.1)")
        _a3 = State(initialValue: "\(values.wrappedValue.2)")
        _a4 = State(initialValue: "\(values.wrappedValue.3)")
    }

    var body: some View {
        HStack {
            Text("\(group.members.count) triggers @ (\(group.signature.0), \(group.signature.1), \(group.signature.2), \(group.signature.3))")
                .font(.caption.monospaced())
            Spacer()
            ForEach([("A1", $a1), ("A2", $a2), ("A3", $a3), ("A4", $a4)], id: \.0) { label, binding in
                TextField(label, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .font(.caption.monospaced())
            }
            Button("Apply") {
                guard let v1 = UInt16(a1), let v2 = UInt16(a2), let v3 = UInt16(a3), let v4 = UInt16(a4) else { return }
                values = (v1, v2, v3, v4)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

private struct RecipeRow: View {
    let entry: (node: ChunkNode, instance: PlacedInstance)
    let currentName: String
    let candidates: [(objectID: UInt16, displayName: String)]
    @Binding var selection: UInt16
    let applyToAllMatching: (UInt16) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentName).font(.callout)
                Text("Instance #\(entry.instance.id)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $selection) {
                ForEach(candidates, id: \.objectID) { candidate in
                    Text(candidate.displayName).tag(candidate.objectID)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            // "Toggleable preset" (roadmap 6.4): a real, non-fabricated
            // preset action, broadcasts this row's chosen swap to every
            // other placement in the level that started with the same
            // real objectID, instead of editing them one at a time.
            Menu {
                Button("Apply to all matching placements") { applyToAllMatching(selection) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 2)
    }
}
