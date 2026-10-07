import SwiftUI
import CTModels

/// Inspector for a decoded `Script` record, either a `HeaderScript`
/// ("B.Starter": a priority-ordered pointer to another script) or a
/// `MainScript` (the real condition/state-machine). See `ScriptAsset`'s
/// doc comment. Real write-back: "Edit…" opens `ScriptEditorSheet`, which
/// patches state slots/command arguments/header entries straight into a
/// copy of this file, see that view's own doc comment for exactly what's
/// editable and why the rest (structural changes, condition fields) isn't.
struct ScriptInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let script: ScriptAsset
    @State private var isEditing = false

    var body: some View {
        Form {
            Section("Script #\(script.id)") {
                LabeledContent("Inline ID", value: "\(script.inlineID)")
                LabeledContent("Priority (mask)", value: "\(script.mask)")
                LabeledContent("Flag", value: script.flag == 0 ? "0 (MainScript)" : "\(script.flag) (HeaderScript)")
                if !script.trailingBytes.isEmpty {
                    LabeledContent("Trailing Bytes", value: "\(script.trailingBytes.count) (real, see doc comment)")
                }
                if workspace.canSaveEdits(for: node) {
                    Button("Edit…") { isEditing = true }
                }
            }

            switch script.content {
            case .main(let main):
                MainScriptDetail(main: main)
            case .header(let header):
                HeaderScriptDetail(header: header)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isEditing) {
            ScriptEditorSheet(node: node, script: script)
        }
    }
}

private struct HeaderScriptDetail: View {
    let header: HeaderScript

    var body: some View {
        Section("B.Starter Entries (\(header.entries.count))") {
            ForEach(Array(header.entries.enumerated()), id: \.offset) { index, entry in
                DisclosureGroup("Entry \(index) -> Script \(entry.mainScriptIndex - 1)") {
                    LabeledContent("Object ID", value: "\(entry.objectID)")
                    LabeledContent("Assign Type", value: entry.resolvedAssignType.map { "\($0)" } ?? "raw \(entry.unkInt2 & 0xF) (unrecognized)")
                    LabeledContent("Assign Locality", value: entry.resolvedAssignLocality.map { "\($0)" } ?? "unrecognized")
                    LabeledContent("Assign Status", value: entry.resolvedAssignStatus.map { "\($0)" } ?? "unrecognized")
                    LabeledContent("Assign Preference", value: entry.resolvedAssignPreference.map { "\($0)" } ?? "unrecognized")
                }
            }
        }
    }
}

private struct MainScriptDetail: View {
    let main: MainScript

    var body: some View {
        Section("Main Script") {
            LabeledContent("Name", value: main.name.isEmpty ? "(unnamed)" : main.name)
            LabeledContent("Start Unit", value: "\(main.startUnit)")
            LabeledContent("States", value: "\(main.states.count)")
        }
        ForEach(Array(main.states.enumerated()), id: \.offset) { index, state in
            Section("State \(index)") {
                LabeledContent("Slot", value: state.isSlot ? "\(state.scriptIndexOrSlot)" : "index \(state.scriptIndexOrSlot)")
                if let type1 = state.type1 {
                    DisclosureGroup("Motion (SupportType1)") {
                        SupportType1Detail(type1: type1)
                    }
                }
                ForEach(Array(state.bodies.enumerated()), id: \.offset) { bodyIndex, body in
                    DisclosureGroup("Body \(bodyIndex): \(body.commands.count) command(s)") {
                        LabeledContent("Enabled", value: body.isEnabled ? "yes" : "no")
                        if let listIndex = body.scriptStateListIndex {
                            LabeledContent("State List Index", value: "\(listIndex)")
                        }
                        if let condition = body.condition {
                            let conditionLabel = ScriptConditionCatalog.conditionName(forID: condition.vTableIndex) ?? "vtable \(condition.vTableIndex)"
                            LabeledContent("Condition", value: "\(conditionLabel), interval \(condition.interval), threshold \(condition.threshold)\(condition.notGate ? " (NOT)" : "")")
                            if let category = ScriptConditionCatalog.perceptArgumentCategory(forID: condition.vTableIndex) {
                                LabeledContent("Parameter (\(condition.parameter))", value: "\(category)")
                            }
                        }
                        ForEach(Array(body.commands.enumerated()), id: \.offset) { cmdIndex, command in
                            LabeledContent("Command \(cmdIndex)", value: command.commandName ?? "#\(command.commandID)")
                        }
                    }
                }
            }
        }
    }
}

private struct SupportType1Detail: View {
    let type1: SupportType1

    var body: some View {
        LabeledContent("Space", value: type1.resolvedSpace.map { "\($0)" } ?? "unrecognized")
        LabeledContent("Motion", value: type1.resolvedMotion.map { "\($0)" } ?? "unrecognized")
        LabeledContent("Translates / Rotates", value: "\(type1.translates) / \(type1.rotates)")
        LabeledContent("Tracks Destination", value: type1.tracksDestination ? "yes" : "no")
        LabeledContent("Uses Physics", value: type1.usesPhysics ? "yes" : "no")
        LabeledContent("Floats", value: "\(type1.floats.count)")
        LabeledContent("Bytes", value: "\(type1.bytes.count)")
    }
}
