import SwiftUI
import CTModels

/// Inspector for a decoded `InstanceTemplate` record, real write-back now
/// too, via `InstanceTemplateEditorSheet`/`InstanceTemplateWriter`, ports
/// `Editors/InstanceTemplateEditor.cs`'s field set (name, object ID,
/// bitfield/header ints, properties, and the flags/floats/ints lists). See
/// `InstanceTemplateInfo`'s own doc comment for why no cross-reference from
/// a placed `Instance` to a specific template is modeled, this is
/// browsable/editable on its own.
struct InstanceTemplateInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let template: InstanceTemplateInfo
    @State private var showEditor = false

    var body: some View {
        Form {
            Section("Instance Template, \(template.name.isEmpty ? "<unnamed>" : template.name)") {
                Button("Edit…") { showEditor = true }
                    .disabled(!workspace.canSaveEdits(for: node))
            }
            Section("Header") {
                LabeledContent("Name", value: template.name)
                LabeledContent("Object ID", value: "\(template.objectID)")
                LabeledContent("Bitfield", value: "0x\(String(template.bitfield, radix: 16))")
                LabeledContent("Header Ints", value: "\(template.headerInt1), \(template.headerInt2), \(template.headerInt3)")
                if let unkShort = template.unkShort {
                    LabeledContent("Unknown Short", value: "\(unkShort)")
                }
                LabeledContent("Properties", value: "0x\(String(template.properties, radix: 16))")
            }
            Section("Lists") {
                LabeledContent("Flags", value: "\(template.flags.count)")
                LabeledContent("Floats", value: "\(template.floats.count)")
                LabeledContent("Ints", value: "\(template.ints.count)")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showEditor) {
            InstanceTemplateEditorSheet(node: node, template: template)
        }
    }
}

/// The Demo build's counterpart, same shape, `InstanceTemplateDemoInfo`'s
/// own doc comment explains the two real layout differences from retail.
struct InstanceTemplateDemoInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let template: InstanceTemplateDemoInfo
    @State private var showEditor = false

    var body: some View {
        Form {
            Section("Instance Template (Demo), \(template.name.isEmpty ? "<unnamed>" : template.name)") {
                Button("Edit…") { showEditor = true }
                    .disabled(!workspace.canSaveEdits(for: node))
            }
            Section("Header") {
                LabeledContent("Name", value: template.name)
                LabeledContent("Object ID", value: "\(template.objectID)")
                LabeledContent("Bitfield", value: "0x\(String(template.bitfield, radix: 16))")
                LabeledContent("Header Ints", value: "\(template.headerInt1), \(template.headerInt2), \(template.headerInt3)")
                if let unkShort = template.unkShort {
                    LabeledContent("Unknown Short", value: "\(unkShort)")
                }
                LabeledContent("Properties", value: "0x\(String(template.properties, radix: 16))")
            }
            Section("Lists") {
                LabeledContent("Flags", value: "\(template.flags.count)")
                LabeledContent("Floats", value: "\(template.floats.count)")
                LabeledContent("Ints", value: "\(template.ints.count)")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showEditor) {
            InstanceTemplateDemoEditorSheet(node: node, template: template)
        }
    }
}
