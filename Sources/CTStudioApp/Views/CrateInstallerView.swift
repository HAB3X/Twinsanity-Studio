import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CTModels
import CTParsers
import CTExport

/// "Crate Installer", the install-side counterpart to "Export as Mod
/// Crate…"/"Cross-Engine Texture Variant" export: `CrateTextureOverrideInstaller
/// .install` (real, already tested, patches texture records inside a real
/// `.BH`/`.BD` archive from a bundled `.crate`'s `TextureOverride_<id>`
/// settings) had no UI caller anywhere in the app before this, this closes
/// that gap.
///
/// Deliberately a new, small view rather than an `ArchiveRepackagerView`
/// extension: that view's whole data model is "one whole replacement file
/// per archive entry," fundamentally different from "patch specific
/// texture records inside one entry, driven by a crate's declared IDs."
/// Reuses that view's house style for the parts that do match: crate
/// open/manifest-read mirrors `ModCrateInspectorView`'s pattern, archive
/// open/output-location conventions mirror `ArchiveRepackagerView`'s.
///
/// The crate's own manifest only records *which* texture IDs it overrides
/// (`CrateTextureOverrideInstaller.declaredTextureOverrideIDs`), never
/// *which archive entry* holds them, the exporter has no such index to
/// write one from, so the target entry has to be picked manually from the
/// opened archive's real entry list, not auto-derived.
struct CrateInstallerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var crateURL: URL?
    @State private var manifest: ModManifest?
    @State private var declaredTextureIDs: [UInt32] = []
    @State private var index: ArchiveIndex?
    @State private var selectedEntryName: String?
    @State private var searchText = ""
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    @State private var isInstalling = false

    /// "Recent Crates" -- same shape as `WorkspaceViewModel`'s own Recent
    /// Files list (path strings in `UserDefaults`, most recent first,
    /// deduplicated), scoped locally to this view rather than threaded
    /// through `WorkspaceViewModel` since `CrateInstallerView` is already
    /// independent of it, same as `ArchiveRepackagerView`/
    /// `ModCrateInspectorView`. Speeds up the export -> test -> re-export
    /// loop this tool exists for: re-opening the same crate after a fresh
    /// export shouldn't need a file panel every time.
    @State private var recentCrateURLs: [URL] = []
    private static let recentCratesDefaultsKey = "TwinsanityStudio.RecentCrateURLs"
    private static let maxRecentCrates = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                crateSection
                Divider()
                archiveSection
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { loadRecentCrates() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Crate Installer").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Installs a real Cross-Engine Texture Variant crate's texture overrides into a real .BH/.BD archive pair, writing a brand-new copy. The source archive is never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var crateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Open Crate…") { presentOpenCratePanel() }
            if let crateURL {
                Text(crateURL.lastPathComponent).font(.callout.bold()).lineLimit(1)
                if declaredTextureIDs.isEmpty {
                    Text("This crate declares no texture overrides, nothing for this tool to install.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Will patch \(declaredTextureIDs.count) texture record(s):")
                        .font(.caption)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(declaredTextureIDs, id: \.self) { id in
                                Text("#\(id)").font(.caption2.monospaced())
                            }
                        }
                    }
                }
            } else {
                Text("Choose a .crate file exported from the Cross-Engine Texture Variant preview.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !recentCrateURLs.isEmpty {
                    Text("Recent").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(recentCrateURLs, id: \.path) { url in
                            Button {
                                openCrate(at: url)
                            } label: {
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 260, alignment: .topLeading)
    }

    @ViewBuilder
    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Open Archive (.BH)…") { presentOpenArchivePanel() }
                if index != nil {
                    TextField("Search entries…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
            if let index {
                Text("Pick the archive entry that actually contains those texture records, a crate's manifest only names texture IDs, not which entry holds them.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                let filtered = searchText.isEmpty ? index.entries : index.entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
                List(filtered, id: \.name, selection: $selectedEntryName) { entry in
                    Text(entry.name).font(.callout.monospaced()).tag(entry.name)
                }
            } else {
                ContentUnavailableView("No Archive Loaded", systemImage: "shippingbox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(isInstalling ? "Installing…" : "Install…") { install() }
                .disabled(!canInstall || isInstalling)
        }
        .padding()
    }

    private var canInstall: Bool {
        crateURL != nil && !declaredTextureIDs.isEmpty && index != nil && selectedEntryName != nil
    }

    // MARK: - Actions

    private func presentOpenCratePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "crate") ?? .zip, .zip]
        panel.message = "Choose a .crate mod package to install."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openCrate(at: url)
    }

    private func openCrate(at url: URL) {
        do {
            let loadedManifest = try CrateArchiveManager.readManifest(from: url)
            crateURL = url
            manifest = loadedManifest
            declaredTextureIDs = CrateTextureOverrideInstaller.declaredTextureOverrideIDs(in: loadedManifest)
            errorMessage = nil
            statusMessage = ""
            addRecentCrate(url)
        } catch {
            errorMessage = "Couldn't read \(url.lastPathComponent): \(error)"
        }
    }

    private func loadRecentCrates() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentCratesDefaultsKey) ?? []
        recentCrateURLs = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addRecentCrate(_ url: URL) {
        var urls = recentCrateURLs.filter { $0.path != url.path }
        urls.insert(url, at: 0)
        recentCrateURLs = Array(urls.prefix(Self.maxRecentCrates))
        UserDefaults.standard.set(recentCrateURLs.map(\.path), forKey: Self.recentCratesDefaultsKey)
    }

    private func presentOpenArchivePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the archive's .BH index file (the matching .BD is found automatically)."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            index = try BDArchiveParser.readIndex(bhURL: url)
            selectedEntryName = nil
            errorMessage = nil
            statusMessage = "Loaded \(index?.entries.count ?? 0) entries from \(url.lastPathComponent)."
        } catch {
            errorMessage = "Couldn't read \(url.lastPathComponent): \(error)"
        }
    }

    private func install() {
        guard let crateURL, let manifest, let index, let selectedEntryName else { return }
        let suggestedName = index.bhURL.deletingPathExtension().lastPathComponent + "_texture_override"
        guard let outputBH = ExportPanel.chooseSaveLocation(
            suggestedName: "\(suggestedName).BH",
            message: "Save the new archive's .BH index. A matching .BD is created alongside it. The original archive is never modified."
        ) else { return }

        isInstalling = true
        errorMessage = nil
        Task {
            do {
                let (outputBHResolved, outputBD) = try BDArchiveParser.counterpartURL(for: outputBH)
                let bhURL = index.bhURL
                let patchedCount = try await Task.detached(priority: .userInitiated) {
                    try CrateTextureOverrideInstaller.install(
                        crateURL: crateURL,
                        manifest: manifest,
                        targetEntryName: selectedEntryName,
                        bhURL: bhURL,
                        outputBH: outputBHResolved,
                        outputBD: outputBD
                    )
                }.value
                if patchedCount > 0 {
                    statusMessage = "Saved \(outputBHResolved.lastPathComponent) + \(outputBD.lastPathComponent) with \(patchedCount) texture record(s) patched."
                } else {
                    statusMessage = "Nothing to install, this crate's declared texture(s) weren't found in \(selectedEntryName)."
                }
                isInstalling = false
            } catch {
                errorMessage = "Install failed: \(error.localizedDescription)"
                isInstalling = false
            }
        }
    }
}
