import SwiftUI
import AppKit
import CTExport

/// "Executable Patcher", direct byte patches to the Crash Twinsanity
/// boot executable itself (`default.xbe`/PS2 binary), ported from
/// **CrateModLoader**'s own `TS_ChangeStartingChunk`/`TS_ChangeCreditsChunk`/
/// `TS_SwapStartCreditsSpawn`/`TS_StartSpawnCredits` (see
/// `ExecutablePatcher`'s doc comment). Independent of the rest of this
/// app's "workspace" concept: it opens a standalone executable file the
/// user picks, not anything already loaded from an archive.
struct ExecutablePatcherView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var exeURL: URL?
    @State private var exeData: Data?
    @State private var revision: GameExecutableRevision?
    @State private var startingChunkPath = ""
    @State private var creditsChunkPath = ""
    @State private var gameArchivePath = ""
    @State private var statusMessage = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if exeData == nil {
                ContentUnavailableView("No Executable Loaded", systemImage: "doc.badge.gearshape",
                    description: Text("Open a Crash Twinsanity boot executable (default.xbe on Xbox, the PS2 SLUS/SLES/SLPS binary) to patch it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { content }
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Executable Patcher").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Real, verified byte-offset patches ported from CrateModLoader's own Twinsanity mods, not this project's own reverse engineering. Every action here saves an edited copy; the original executable is never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Executable…") { openExecutable() }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let exeURL {
                Text(exeURL.lastPathComponent).font(.callout.bold())
            }
            revisionPicker
            if let revision {
                Divider()
                gameArchiveSection(revision: revision)
                Divider()
                startingChunkSection(revision: revision)
                Divider()
                creditsChunkSection(revision: revision)
                Divider()
                spawnSwapSection(revision: revision)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
    }

    private var revisionPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Executable Build").font(.headline)
            Text("Pick the exact build this file is. The four fields below live at different byte offsets in each one. PS2 NTSC-U is auto-detected by probing a real byte CrateModLoader itself uses to tell the two prints apart.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { revision },
                set: { newValue in
                    revision = newValue
                    refreshFieldsFromExecutable()
                }
            )) {
                Text("Choose…").tag(GameExecutableRevision?.none)
                ForEach(GameExecutableRevision.allCases) { rev in
                    Text(rev.displayName).tag(GameExecutableRevision?.some(rev))
                }
            }
            .labelsHidden()
            .frame(width: 320)
        }
    }

    @ViewBuilder
    private func gameArchiveSection(revision: GameExecutableRevision) -> some View {
        if revision.archiveField != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("Game Archive").font(.headline)
                Text("The boot archive filename (the .BD/.BH pair) the executable loads at startup. This is the reference editor's \"Patch Game Archive\" field.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Archive name…", text: $gameArchivePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Apply") { applyGameArchive(revision: revision) }
                        .disabled(gameArchivePath.isEmpty)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Game Archive").font(.headline)
                Text("No verified offset exists for \(revision.displayName). The reference tool never shipped this field for Xbox builds.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func startingChunkSection(revision: GameExecutableRevision) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Starting Chunk").font(.headline)
            Text("Which real level chunk path the game boots into (e.g. earth\\hub\\beach). This is the same string this workspace already resolves ChunkLinks/level paths against.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Chunk path…", text: $startingChunkPath)
                    .textFieldStyle(.roundedBorder)
                Button("Apply") { applyStartingChunk(revision: revision) }
                    .disabled(startingChunkPath.isEmpty)
            }
        }
    }

    private func creditsChunkSection(revision: GameExecutableRevision) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Credits Chunk").font(.headline)
            Text("Which real level chunk path the game loads for the ending credits sequence.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Chunk path…", text: $creditsChunkPath)
                    .textFieldStyle(.roundedBorder)
                Button("Apply") { applyCreditsChunk(revision: revision) }
                    .disabled(creditsChunkPath.isEmpty)
            }
        }
    }

    private func spawnSwapSection(revision: GameExecutableRevision) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spawn Pointers").font(.headline)
            Text("Two real 4-byte pointers the game reads to decide where to boot into and where to load for credits. Swapped or copied directly, not decoded as text.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Swap Start ⇄ Credits Spawn") { swapSpawnPointers(revision: revision) }
                Button("Start Spawn = Credits Spawn") { copyCreditsSpawnToStart(revision: revision) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    // MARK: - Actions

    private func openExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Crash Twinsanity boot executable (default.xbe, or the PS2 SLUS/SLES/SLPS binary)."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Same "keep file I/O off the main actor" discipline as every
        // other open/save path in this app, a boot executable is small in
        // practice, but there's no reason this one path should be the
        // exception that can still block the UI on a slow/network volume.
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                exeURL = url
                exeData = data
                errorMessage = nil
                statusMessage = "Loaded \(url.lastPathComponent) (\(data.count) bytes)."
                if let detected = ExecutablePatcher.detectNTSCURevision(exeData: data), detected == .ntscU || detected == .ntscU2 {
                    // Only a hint, the probe byte only disambiguates the two
                    // NTSC-U builds; it says nothing about PAL/NTSC-J/Xbox, so
                    // this never silently guesses one of those instead.
                    statusMessage += " Detected \(detected.displayName) via CrateModLoader's own probe byte. Verify before applying."
                }
            } catch {
                errorMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func refreshFieldsFromExecutable() {
        guard let revision, let exeData else { return }
        startingChunkPath = ExecutablePatcher.readStartingChunkPath(revision: revision, from: exeData) ?? ""
        creditsChunkPath = ExecutablePatcher.readCreditsChunkPath(revision: revision, from: exeData) ?? ""
        gameArchivePath = ExecutablePatcher.readGameArchivePath(revision: revision, from: exeData) ?? ""
        errorMessage = nil
    }

    private func applyGameArchive(revision: GameExecutableRevision) {
        guard let exeData else { return }
        do {
            let patched = try ExecutablePatcher.writingGameArchivePath(gameArchivePath, revision: revision, into: exeData)
            saveEditedCopy(patched, suffix: "game_archive")
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func applyStartingChunk(revision: GameExecutableRevision) {
        guard let exeData else { return }
        do {
            let patched = try ExecutablePatcher.writingStartingChunkPath(startingChunkPath, revision: revision, into: exeData)
            saveEditedCopy(patched, suffix: "starting_chunk")
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func applyCreditsChunk(revision: GameExecutableRevision) {
        guard let exeData else { return }
        do {
            let patched = try ExecutablePatcher.writingCreditsChunkPath(creditsChunkPath, revision: revision, into: exeData)
            saveEditedCopy(patched, suffix: "credits_chunk")
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func swapSpawnPointers(revision: GameExecutableRevision) {
        guard let exeData else { return }
        do {
            let patched = try ExecutablePatcher.swappingStartAndCreditsSpawn(revision: revision, in: exeData)
            saveEditedCopy(patched, suffix: "swapped_spawn")
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func copyCreditsSpawnToStart(revision: GameExecutableRevision) {
        guard let exeData else { return }
        do {
            let patched = try ExecutablePatcher.copyingCreditsSpawnToStart(revision: revision, in: exeData)
            saveEditedCopy(patched, suffix: "start_from_credits")
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func saveEditedCopy(_ patched: Data, suffix: String) {
        let originalName = exeURL?.deletingPathExtension().lastPathComponent ?? "executable"
        let ext = exeURL?.pathExtension ?? "bin"
        guard let saveURL = ExportPanel.chooseSaveLocation(
            suggestedName: "\(originalName)_\(suffix).\(ext)",
            message: "Save the patched copy of this executable. The original file is never modified."
        ) else { return }
        do {
            try patched.write(to: saveURL)
            errorMessage = nil
            statusMessage = "Saved patched copy to \(saveURL.lastPathComponent)."
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}
