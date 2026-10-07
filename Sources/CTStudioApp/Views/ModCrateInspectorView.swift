import SwiftUI
import UniformTypeIdentifiers
import CTExport

/// "Offline Mod Package Manager (.Crate Hub)" (roadmap 3.3), opens real
/// `.crate` mod packages (drag-and-drop or a file panel), parses their
/// manifest and per-layer file listing straight off the archive's actual
/// zip contents (`CrateArchiveManager`, not a guess), and extracts a layer
/// or the whole archive to a folder the user picks. Packaging a new crate
/// is the separate, already-real "Export as Mod Crate…" flow
/// (`CrateExportSheet`/`CrateExporter`), this is the read/inspect side.
///
/// Earlier scaffolding for this screen also had "Apply Mods & Launch" and a
/// fixed list of "Built-in Hacks" toggles (classic physics, character
/// swapping, ...). Those aren't included here: this app has no verified
/// byte-level implementation of any of them and nothing to "launch", a
/// toggle that only prints to the console isn't a real feature, and
/// presenting it as one would be fabricating capability the app doesn't
/// have.
struct ModCrateInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    /// Needed for "Crate Region Gating" (`ModManifest.declaredRegion`
    /// compared against `workspace.detectedRegion`), every other hub view
    /// takes this the same way.
    @Environment(WorkspaceViewModel.self) private var workspace

    private struct LoadedCrate: Identifiable {
        let id = UUID()
        let url: URL
        let manifest: ModManifest
        let entries: [String]
    }

    @State private var loadedCrates: [LoadedCrate] = []
    @State private var selectedCrateID: UUID?
    @State private var isDraggingOver = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                crateList
                Divider()
                detail
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .onDrop(of: [.fileURL], isTargeted: $isDraggingOver) { providers in
            handleDrop(providers: providers)
        }
        .alert("Couldn't Open Crate", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mod Crate Hub").font(.title2.bold())
                Text("\(loadedCrates.count) crate(s) opened")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                presentOpenPanel()
            } label: {
                Label("Open .crate…", systemImage: "shippingbox")
            }
            Button("Close") { dismiss() }
        }
        .padding()
    }

    @ViewBuilder
    private var crateList: some View {
        if loadedCrates.isEmpty {
            ContentUnavailableView {
                Label("No Crates Open", systemImage: "shippingbox")
            } description: {
                Text("Drag a .crate file here, or use \"Open .crate…\" above.")
            }
            .frame(width: 260)
            .background(isDraggingOver ? Color.accentColor.opacity(0.08) : Color.clear)
        } else {
            List(loadedCrates, selection: $selectedCrateID) { crate in
                VStack(alignment: .leading, spacing: 2) {
                    Text(crate.manifest.name).font(.callout.bold())
                    Text("\(crate.manifest.layerIndices.count) layer(s) · \(crate.url.lastPathComponent)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(crate.id)
            }
            .frame(width: 260)
            .listStyle(.sidebar)
            .background(isDraggingOver ? Color.accentColor.opacity(0.08) : Color.clear)
            .onAppear {
                if selectedCrateID == nil { selectedCrateID = loadedCrates.first?.id }
            }
        }
    }

    private var selectedCrate: LoadedCrate? {
        loadedCrates.first { $0.id == selectedCrateID }
    }

    @ViewBuilder
    private var detail: some View {
        if let crate = selectedCrate {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    manifestSection(crate)
                    if !conflicts.isEmpty {
                        conflictsSection
                    }
                    ForEach(crate.manifest.layerIndices, id: \.self) { layerIndex in
                        layerSection(crate, layerIndex: layerIndex)
                    }
                    extractAllSection(crate)
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView("No Crate Selected", systemImage: "shippingbox")
        }
    }

    private func manifestSection(_ crate: LoadedCrate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(crate.manifest.name).font(.title3.bold())
            if !crate.manifest.description.isEmpty {
                Text(crate.manifest.description).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Label(crate.manifest.author.isEmpty ? "(Not credited)" : crate.manifest.author, systemImage: "person")
                Label("v\(crate.manifest.version)", systemImage: "tag")
                if !crate.manifest.targetGame.isEmpty {
                    Label(crate.manifest.targetGame, systemImage: "gamecontroller")
                }
                Label(crate.manifest.hasIcon ? "Has Icon" : "No Icon", systemImage: crate.manifest.hasIcon ? "photo" : "photo.slash")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let mismatch = regionMismatchWarning(for: crate) {
                Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !crate.manifest.settings.isEmpty {
                DisclosureGroup("Settings (\(crate.manifest.settings.count))") {
                    ForEach(crate.manifest.settings.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack {
                            Text(key).font(.caption.monospaced())
                            Spacer()
                            Text(value).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
    }

    /// "Crate Region Gating": a real, non-blocking heads-up when the crate
    /// declares a region (`ModManifest.declaredRegion`) that doesn't match
    /// whatever region this workspace last detected off a mounted disc's
    /// real `SYSTEM.CNF`, never invented, `nil` on either side just means
    /// "nothing to compare," not a silent assumption of compatibility.
    private func regionMismatchWarning(for crate: LoadedCrate) -> String? {
        guard let declared = crate.manifest.declaredRegion,
              let detected = workspace.detectedRegion?.region,
              detected != .unknown, declared != detected
        else { return nil }
        return "Declared for \(declared.displayName), but this workspace's currently detected disc is \(detected.displayName)."
    }

    /// "Mod Crate Conflict Detection": every `(layer, relative path)` pair
    /// more than one currently-open crate touches, CrateModLoader itself
    /// has no automated dependency/load-order solver (confirmed from its
    /// real source: manual reordering only), so this matches that same
    /// scope rather than fabricating one. Later crates in `loadedCrates`
    /// order win when actually installed one-at-a-time the way
    /// `extractLayer` does it, this just surfaces the collision up front.
    private var conflicts: [(layerIndex: Int, relativePath: String, crateNames: [String])] {
        var owners: [String: [String]] = [:]
        for crate in loadedCrates {
            for layerIndex in crate.manifest.layerIndices {
                for file in CrateArchiveManager.filesInLayer(layerIndex, entries: crate.entries, nestedPath: crate.manifest.nestedPath) {
                    owners["\(layerIndex)/\(file)", default: []].append(crate.manifest.name)
                }
            }
        }
        return owners.compactMap { key, names in
            guard names.count > 1, let slashIndex = key.firstIndex(of: "/"), let layerIndex = Int(key[key.startIndex..<slashIndex]) else { return nil }
            return (layerIndex: layerIndex, relativePath: String(key[key.index(after: slashIndex)...]), crateNames: names)
        }.sorted { $0.relativePath < $1.relativePath }
    }

    private var conflictsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(conflicts.count) file conflict(s) across open crates", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(conflicts, id: \.relativePath) { conflict in
                Text("layer\(conflict.layerIndex)/\(conflict.relativePath): \(conflict.crateNames.joined(separator: ", "))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    private func layerSection(_ crate: LoadedCrate, layerIndex: Int) -> some View {
        let files = CrateArchiveManager.filesInLayer(layerIndex, entries: crate.entries, nestedPath: crate.manifest.nestedPath)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("layer\(layerIndex)", systemImage: "square.stack.3d.down.forward")
                    .font(.headline)
                Text("\(files.count) file(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Extract Layer…") {
                    extractLayer(layerIndex, from: crate)
                }
                .disabled(files.isEmpty)
            }
            ForEach(files.prefix(50), id: \.self) { file in
                Text(file).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if files.count > 50 {
                Text("… and \(files.count - 50) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
    }

    private func extractAllSection(_ crate: LoadedCrate) -> some View {
        HStack {
            Text("\(crate.entries.filter { !$0.hasSuffix("/") }.count) file(s) total across the archive")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Extract Entire Crate…") {
                extractAll(from: crate)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "crate") ?? .zip, .zip]
        panel.message = "Choose one or more .crate mod packages."
        if panel.runModal() == .OK {
            for url in panel.urls { openCrate(at: url) }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                }
                guard let url else { return }
                DispatchQueue.main.async { openCrate(at: url) }
            }
        }
        return true
    }

    private func openCrate(at url: URL) {
        guard url.pathExtension.lowercased() == "crate" else {
            errorMessage = "\"\(url.lastPathComponent)\" isn't a .crate file."
            return
        }
        guard !loadedCrates.contains(where: { $0.url == url }) else {
            selectedCrateID = loadedCrates.first { $0.url == url }?.id
            return
        }
        do {
            let entries = try CrateArchiveManager.listEntries(in: url)
            let manifest = try CrateArchiveManager.readManifest(from: url)
            let crate = LoadedCrate(url: url, manifest: manifest, entries: entries)
            loadedCrates.append(crate)
            selectedCrateID = crate.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func extractLayer(_ layerIndex: Int, from crate: LoadedCrate) {
        guard let destination = ExportPanel.chooseFolder(message: "Choose where to extract layer\(layerIndex). Files land at the same relative paths a game install would see.") else { return }
        do {
            try CrateArchiveManager.verifyRegionCompatibility(manifest: crate.manifest, detectedRegion: workspace.detectedRegion?.region)
            try CrateArchiveManager.extractLayer(layerIndex, from: crate.url, to: destination, nestedPath: crate.manifest.nestedPath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func extractAll(from crate: LoadedCrate) {
        guard let destination = ExportPanel.chooseFolder(message: "Choose where to extract the entire crate.") else { return }
        do {
            try CrateArchiveManager.verifyRegionCompatibility(manifest: crate.manifest, detectedRegion: workspace.detectedRegion?.region)
            try CrateArchiveManager.extractAll(from: crate.url, to: destination)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
