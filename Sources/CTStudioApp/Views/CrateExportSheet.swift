import SwiftUI
import CTModels
import CTExport

/// Metadata prompt for "Export as Mod Crate…" (blueprint 3.3) and "Export
/// with Dependencies…" (blueprint 3.2), the `modcrateinfo.txt` fields a
/// real `CrateModLoader` install expects (`Name`/`Description`/`Author`/
/// `Version`/`Game`), collected once here rather than guessed at, then
/// handed to whichever `CrateExporter.export` caller presented this sheet
/// (a single edited file, or a resolved asset's mesh/textures/animations , 
/// see `onExport`).
struct CrateExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let suggestedName: String
    let caption: String
    let onExport: (CrateMetadata, URL) -> Void

    @State private var name: String
    @State private var description = ""
    @State private var author = ""
    @State private var version = "1.0"

    init(
        suggestedName: String,
        caption: String = "Packages the edited file into a real CrateModLoader-installable .crate (a modcrateinfo.txt manifest + a layer0 folder containing the edited file, zipped). The in-crate file name defaults to the original file's own name. This build doesn't track its exact in-archive install path, so double-check the destination subfolder after installing.",
        onExport: @escaping (CrateMetadata, URL) -> Void
    ) {
        self.suggestedName = suggestedName
        self.caption = caption
        self.onExport = onExport
        _name = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export as Mod Crate").font(.title3.bold())

            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description)
                TextField("Author", text: $author)
                TextField("Version", text: $version)
            }
            .formStyle(.grouped)

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }

    private func export() {
        guard let url = ExportPanel.chooseSaveLocation(suggestedName: "\(sanitizedFileName(name)).crate", message: "Save the mod crate.") else { return }
        let metadata = CrateMetadata(name: name, description: description, author: author, version: version, targetGame: "Crash Twinsanity")
        onExport(metadata, url)
        dismiss()
    }

    private func sanitizedFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "mod" : cleaned
    }
}
