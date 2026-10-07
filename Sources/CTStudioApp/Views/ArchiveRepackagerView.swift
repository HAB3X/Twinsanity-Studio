import SwiftUI
import AppKit
import CTModels
import CTParsers
import CTExport

/// "Archive Repackager", the UI `BDArchiveParser.compileAll`'s own doc
/// comment describes ("the app's UI drives" the replace-just-these-entries
/// workflow) but that never actually existed until now. Real, tested
/// `ArchiveRepackager` logic (safe-copy: streams every untouched entry's
/// bytes straight from the original `.BD`, writes only to a brand-new
/// output pair, never touches the source archive) had zero call sites in
/// this app before this view.
///
/// Independent of the rest of this app's "workspace" concept, same as
/// `ExecutablePatcherView`/`ModCrateInspectorView`: it opens a standalone
/// `.BH`/`.BD` pair the user picks, not anything already loaded from a
/// mounted archive.
struct ArchiveRepackagerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var index: ArchiveIndex?
    @State private var replacements: [String: URL] = [:]
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    @State private var isRepackaging = false
    @State private var isExtracting = false
    @State private var searchText = ""
    @State private var selectedNames: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let index {
                entryList(index: index)
            } else {
                ContentUnavailableView("No Archive Loaded", systemImage: "shippingbox",
                    description: Text("Open a .BH/.BD archive pair to replace individual entries and repackage a new copy."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 600, minHeight: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Archive Repackager").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Replace one or more entries in a .BH/.BD archive pair and write a brand-new copy. Every unmodified entry streams straight through from the original .BD, unchanged. The source archive is never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Archive (.BH)…") { openArchive() }
                if index != nil {
                    TextField("Search entries…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Spacer()
                    Button("Extract Selected…") { extractSelected() }
                        .disabled(selectedNames.isEmpty || isExtracting)
                    Button(isExtracting ? "Extracting…" : "Extract All…") { extractAll() }
                        .disabled(isExtracting)
                }
            }
        }
        .padding()
    }

    private func entryList(index: ArchiveIndex) -> some View {
        let filtered = searchText.isEmpty ? index.entries : index.entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return List(filtered, selection: $selectedNames) { entry in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.callout.monospaced())
                    Text("\(entry.size) bytes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let replacementURL = replacements[entry.name] {
                    Label(replacementURL.lastPathComponent, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Button("Undo") { replacements[entry.name] = nil }
                        .controlSize(.small)
                } else {
                    Button("Replace…") { chooseReplacement(forEntryNamed: entry.name) }
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
            .tag(entry.name)
        }
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(statusMessage.isEmpty ? (replacements.isEmpty ? "No replacements queued." : "\(replacements.count) replacement(s) queued.") : statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(isRepackaging ? "Repackaging…" : "Repackage…") { repackage() }
                .disabled(index == nil || replacements.isEmpty || isRepackaging)
        }
        .padding()
    }

    // MARK: - Actions

    private func openArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the archive's .BH index file (the matching .BD is found automatically)."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            index = try BDArchiveParser.readIndex(bhURL: url)
            replacements = [:]
            errorMessage = nil
            statusMessage = "Loaded \(index?.entries.count ?? 0) entries from \(url.lastPathComponent)."
        } catch {
            errorMessage = "Couldn't read \(url.lastPathComponent): \(error)"
        }
    }

    private func extractAll() {
        guard let index else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to extract every entry of \(index.bhURL.deletingPathExtension().lastPathComponent) into. Subfolder structure embedded in entry names is recreated."
        panel.prompt = "Extract"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExtracting = true
        errorMessage = nil
        Task {
            do {
                let count = index.entries.count
                try await Task.detached(priority: .userInitiated) {
                    try BDArchiveParser.extractAll(index: index, to: destination)
                }.value
                statusMessage = "Extracted \(count) entries to \(destination.lastPathComponent)."
                isExtracting = false
            } catch {
                errorMessage = "Extract All failed: \(error)"
                isExtracting = false
            }
        }
    }

    private func extractSelected() {
        guard let index, !selectedNames.isEmpty else { return }
        let names = selectedNames
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to extract \(names.count) selected entr\(names.count == 1 ? "y" : "ies") into."
        panel.prompt = "Extract"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExtracting = true
        errorMessage = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try BDArchiveParser.extractSelected(index: index, entryNames: names, to: destination)
                }.value
                statusMessage = "Extracted \(names.count) selected entr\(names.count == 1 ? "y" : "ies") to \(destination.lastPathComponent)."
                isExtracting = false
            } catch {
                errorMessage = "Extract Selected failed: \(error)"
                isExtracting = false
            }
        }
    }

    private func chooseReplacement(forEntryNamed name: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the replacement file for \(name)."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replacements[name] = url
        errorMessage = nil
    }

    private func repackage() {
        guard let index else { return }
        let suggestedName = index.bhURL.deletingPathExtension().lastPathComponent + "_modified"
        guard let outputBH = ExportPanel.chooseSaveLocation(
            suggestedName: "\(suggestedName).BH",
            message: "Save the new archive's .BH index. A matching .BD is created alongside it. The original archive is never modified."
        ) else { return }

        // Capture every value the background work needs *before* starting
        // it, `replacements`/`index` are `@State`, only safe to touch on
        // the main actor. Same "read what you need first, then hop off"
        // shape `WorkspaceViewModel.writeDataAsync` uses for its own
        // `Task.detached` writes.
        let replacementURLs = replacements
        isRepackaging = true
        errorMessage = nil
        Task {
            do {
                let (outputBHResolved, outputBD) = try BDArchiveParser.counterpartURL(for: outputBH)
                let replacementCount = try await Task.detached(priority: .userInitiated) { () -> Int in
                    var replacementData: [String: Data] = [:]
                    for (name, url) in replacementURLs {
                        replacementData[name] = try Data(contentsOf: url)
                    }
                    try ArchiveRepackager.repackage(index: index, replacements: replacementData, outputBH: outputBHResolved, outputBD: outputBD)
                    return replacementData.count
                }.value
                statusMessage = "Saved \(outputBHResolved.lastPathComponent) + \(outputBD.lastPathComponent) with \(replacementCount) entry replacement(s)."
                replacements = [:]
                isRepackaging = false
            } catch {
                errorMessage = "Repackage failed: \(error)"
                isRepackaging = false
            }
        }
    }
}
