import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CTCore
import CTExport

/// "Direct Boot/Launch", builds a real, patched copy of a real bootable
/// PS2 disc image and boots it straight in PCSX2. Two entry points share
/// this one view: the toolbar's global "Play in PCSX2…" (`workspace.
/// gameLauncherContext == nil`, boots the disc image exactly as it is)
/// and a Level Viewer's "Quick Launch" (`gameLauncherContext` set to a real
/// plan built from that level's own current pending edits, see
/// `WorkspaceViewModel.GameLauncherContext`'s own doc comment). Every byte
/// this doesn't need to change is copied straight through from the disc
/// image the user points at (`GameLauncher.building`'s own doc comment) , 
/// nothing here builds a disc from scratch.
///
/// "Save changes to this ISO" (`saveToDiscImage`, on by default) decides
/// whether launching also writes the independently-verified result back
/// into that same disc image in place, so it sticks around for next time,
/// or only ever builds a throwaway scratch copy for the one PCSX2 run , 
/// see that property's own doc comment.
struct GameLauncherView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var isBuilding = false
    @State private var isSaving = false
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    /// Real, reported confusion: the "This Level" boot target's own hint
    /// box ("Boots straight into cavent", lightning-bolt icon) is a static
    /// description of what that segment does, computed independently of
    /// `errorMessage`, so after a real `pathTooLong` failure, the sheet
    /// showed that confident "boots straight into X" box directly above a
    /// red error saying the opposite, with nothing tying the two together.
    /// Tracked separately from `isIntegrityFailure` (a different failure
    /// class, unrelated to which boot target is viable) so the hint box
    /// itself can switch to a warning instead of quietly contradicting the
    /// error underneath it.
    @State private var isPathTooLongForThisLevel = false
    @State private var isIntegrityFailure = false
    @State private var diagnostics: [String] = []
    /// "Boot from either the level I'm in or the game": reached via Quick
    /// Launch (`context != nil`) always used to force a level-specific
    /// boot with no way back to a normal boot without closing this sheet
    /// and finding the toolbar's separate "Play in PCSX2…" entry point
    /// instead. This toggle lets both choices live in the one place the
    /// user actually is, against the same already-chosen disc image.
    @State private var bootTarget: BootTarget = .thisLevel
    /// "When I boot from my level I want it to auto save to the current
    /// ISO": on by default, since that's the explicit ask -- launching
    /// used to only ever write into a throwaway scratch copy, so nothing
    /// about a Quick Launch ever stuck around afterward. With this on,
    /// launching independently re-verifies the patched result
    /// (`GameLauncher.rebuildingAndVerifying`, the same real check "Save
    /// Rebuilt ISO…" already uses) and writes it back into the disc image
    /// above *in place* before booting it, so the level override/edits
    /// this session baked in are still there the next time this same
    /// file is mounted or launched, not just for this one PCSX2 run.
    /// Turning it off restores the old throwaway-scratch-copy behavior,
    /// for a one-off test nobody wants to keep.
    @State private var saveToDiscImage = true
    @State private var showingVersionHistory = false

    private enum BootTarget: String, CaseIterable, Identifiable {
        case thisLevel = "This Level"
        case mainGame = "Main Game"
        var id: String { rawValue }
    }

    private var context: WorkspaceViewModel.GameLauncherContext? { workspace.gameLauncherContext }

    /// The real plan for whichever `bootTarget` is currently selected.
    /// `context`'s pending-edit `archiveReplacements` always ride along
    /// whenever this sheet was reached via a level's own "Quick Launch"
    /// (`context != nil`), regardless of `bootTarget`, only
    /// `startingChunkBaseName` (the "skip the main menu" convenience) is
    /// gated on it. Real bug this fixes: some real levels' archive path
    /// genuinely can't fit the executable's fixed-size starting-chunk
    /// field (see `ExecutablePatcherError.pathTooLong`'s own doc comment , 
    /// a real, verified format limit, not a bug to work around by
    /// truncating). Before this, the *only* way to avoid that failure was
    /// switching to "Main Game," which used to return a completely empty
    /// plan and silently drop this session's pending edits too, so a
    /// deep-path level's edits could never reach the disc image via Quick
    /// Launch at all. A normal game boot with no Quick Launch context
    /// (the toolbar's own "Play in PCSX2…") still uses neither field,
    /// same as before.
    private var effectivePlan: GameLaunchPlan {
        guard let context else { return GameLaunchPlan() }
        return GameLaunchPlan(
            startingChunkBaseName: bootTarget == .thisLevel ? context.startingChunkBaseName : nil,
            archiveReplacements: context.archiveReplacements
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(context != nil ? "Quick Launch" : "Play in PCSX2").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text(saveToDiscImage
                 ? "Patches a real, already-bootable PS2 disc image and boots it in PCSX2. Every byte this doesn't need to change is copied straight through. The verified result is saved back into the disc image below before it boots, so this sticks around for next time too."
                 : "Patches a real, already-bootable PS2 disc image and boots it in PCSX2. Every byte this doesn't need to change is copied straight through from the disc image below. The original file is never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Save changes to this ISO", isOn: $saveToDiscImage)
                .help("On: updates the disc image in place. Off: builds a throwaway copy for this run only.")

            Form {
                LabeledContent("Disc Image (.iso)") {
                    HStack {
                        Text(workspace.discImageURL?.path ?? "Not chosen")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…") { chooseDiscImage() }
                        if let discImageURL = workspace.discImageURL {
                            Button("Version History…") { showingVersionHistory = true }
                                .disabled(workspace.listDiscImageVersions(for: discImageURL).isEmpty)
                        }
                    }
                }
                LabeledContent("PCSX2") {
                    HStack {
                        Text(workspace.pcsx2AppURL?.path ?? "Not chosen")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…") { choosePCSX2() }
                    }
                }
            }
            .formStyle(.grouped)

            if let context {
                Picker("Boot", selection: $bootTarget) {
                    ForEach(BootTarget.allCases) { target in
                        Text(target.rawValue).tag(target)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 4) {
                    if bootTarget == .thisLevel, isPathTooLongForThisLevel {
                        // Real, reported confusion this replaces: the
                        // confident "Boots straight into X" framing stayed
                        // shown, unchanged, directly above the red
                        // "Chunk path is too long" error below, nothing
                        // tied the two together, so it read as a
                        // contradiction rather than a coherent explanation.
                        Label("\(context.startingChunkBaseName)'s path doesn't fit this boot target", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                        Text("This level's own chunk path is too long for the executable's direct-boot field, switch to \"Main Game\" below; your pending edits still get baked in, you'll just need to navigate to the level yourself.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if bootTarget == .thisLevel {
                        Label("Boots straight into \(context.startingChunkBaseName)", systemImage: "bolt.fill")
                            .font(.headline)
                        Text(context.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Boots the game normally, straight to the main menu", systemImage: "gamecontroller.fill")
                            .font(.headline)
                        Text(context.archiveReplacements.isEmpty
                             ? "No level override, no pending edits to bake in, the same disc image above, booted exactly as it is."
                             : "No level override, you'll need to navigate to \(context.startingChunkBaseName) yourself, but this session's pending edits are still baked into the disc image below, same as \"This Level.\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background((isPathTooLongForThisLevel && bootTarget == .thisLevel ? Color.orange : Color.accentColor).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Boots the disc image above exactly as it is. No in-session edits are folded in automatically. To test a specific level's edits, use that level's own \"Quick Launch\" button in the Level Viewer instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: isIntegrityFailure ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Verification log").font(.caption.bold())
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 60, maxHeight: 140)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack {
                Spacer()
                Button(isSaving ? "Saving…" : "Save Rebuilt ISO…") { rebuildAndSave() }
                    .disabled(isBuilding || isSaving || workspace.discImageURL == nil)
                Button(isBuilding ? "Building…" : (context != nil ? "Build & Quick Launch" : "Build & Launch")) { buildAndLaunch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBuilding || isSaving || workspace.discImageURL == nil || workspace.pcsx2AppURL == nil)
            }
        }
        .padding()
        .frame(minWidth: 560)
        .onDisappear { workspace.gameLauncherContext = nil }
        .sheet(isPresented: $showingVersionHistory) {
            if let discImageURL = workspace.discImageURL {
                DiscImageVersionHistoryView(discImageURL: discImageURL)
            }
        }
    }

    private func chooseDiscImage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let isoType = UTType(filenameExtension: "iso") {
            panel.allowedContentTypes = [isoType]
        }
        panel.message = "Choose a real, already-bootable PS2 disc image (.iso). A raw .bin/.cue pair isn't supported for launching."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.discImageURL = url
        errorMessage = nil
        isPathTooLongForThisLevel = false
    }

    private func choosePCSX2() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose PCSX2.app (or its bundled executable inside Contents/MacOS)."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.pcsx2AppURL = url
        errorMessage = nil
        isPathTooLongForThisLevel = false
    }

    /// "Strict Size Guardrails", the real, requested confirmation gate:
    /// no minor edit should ever grow the whole disc image by more than
    /// `GameLauncher.defaultSizeGrowthWarningThreshold` (25%) over its own
    /// original size without an explicit, informed choice to proceed.
    /// Blocking (`NSAlert.runModal()`), the same pattern `CTStudioApp.
    /// AppDelegate.saveAndTerminate`'s own quit-time confirmation alerts
    /// already use, safe to call from inside a `MainActor.run` block
    /// nested in a background `Task`, since it only blocks *that* task's
    /// continuation, never the whole app. Returns `true` when nothing
    /// needs confirming (growth is within the threshold) or the user
    /// explicitly chose to proceed anyway; `false` only on an explicit
    /// "Cancel."
    @MainActor
    private static func confirmingLargeSizeGrowth(originalBytes: Int, rebuiltBytes: Int) -> Bool {
        let fraction = GameLauncher.sizeGrowthFraction(originalBytes: originalBytes, rebuiltBytes: rebuiltBytes)
        guard fraction > GameLauncher.defaultSizeGrowthWarningThreshold else { return true }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let percentText = String(format: "%+.0f%%", fraction * 100)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This rebuild grew the disc image a lot"
        alert.informativeText = "The rebuilt image is \(percentText) larger than the original (\(formatter.string(fromByteCount: Int64(originalBytes))) → \(formatter.string(fromByteCount: Int64(rebuiltBytes)))), well past the \(Int(GameLauncher.defaultSizeGrowthWarningThreshold * 100))% guardrail. No small edit should normally cause growth like this. Proceeding anyway still writes/launches the rebuilt image as-is."
        alert.addButton(withTitle: "Proceed Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func buildAndLaunch() {
        // Real, serious bug: this used to return here completely silently
        //, no error, no status message, nothing, whenever either field
        // wasn't configured. Clicking "Build & Quick Launch" then does
        // *nothing at all* visible, which reads exactly like "I placed an
        // object, pressed the button, and it's just not showing up" even
        // though nothing was ever built or booted in the first place.
        guard let discImageURL = workspace.discImageURL else {
            errorMessage = "No disc image is configured, set one above before building."
            return
        }
        guard let pcsx2AppURL = workspace.pcsx2AppURL else {
            errorMessage = "PCSX2's app location isn't set, choose it above before building."
            return
        }
        let plan = effectivePlan
        let saveInPlace = saveToDiscImage
        errorMessage = nil
        isPathTooLongForThisLevel = false
        isIntegrityFailure = false
        diagnostics = []
        isBuilding = true
        statusMessage = saveInPlace ? "Building and verifying…" : "Building…"
        Task.detached(priority: .userInitiated) {
            do {
                let outputURL: URL
                if saveInPlace {
                    // Independently re-verified (same real check "Save
                    // Rebuilt ISO…" already uses) before this ever
                    // overwrites the user's real disc image in place , 
                    // never write back an image that hasn't actually been
                    // confirmed to still be a valid, readable disc.
                    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TwinsanityStudioLaunch", isDirectory: true)
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                    let result = try GameLauncher.rebuildingAndVerifying(isoURL: discImageURL, plan: plan, scratchDirectory: scratch)
                    await MainActor.run { diagnostics = result.diagnostics }
                    guard await Self.confirmingLargeSizeGrowth(originalBytes: result.originalSizeBytes, rebuiltBytes: result.data.count) else {
                        await MainActor.run {
                            isBuilding = false
                            statusMessage = "Canceled, the rebuild grew the disc image more than expected."
                        }
                        return
                    }
                    // "Save History, Backup Before First In-Place
                    // Overwrite": see `WorkspaceViewModel.
                    // backingUpMountedDiscImageIfNeeded`'s own doc comment
                    //, a real, bounded safety net before this genuinely
                    // overwrites the user's own disc image file.
                    await MainActor.run { workspace.backingUpMountedDiscImageIfNeeded(url: discImageURL) }
                    try GameLauncher.writingVerified(result.data, to: discImageURL)
                    outputURL = discImageURL
                    // Real, reported bug: this writes the newly-edited
                    // bytes straight over the mounted disc image's own
                    // file on disk, but `workspace.mountDiscImage` reads a
                    // disc exactly once at mount time (`discEntryByNodeID`
                    // captures a `LogicalSectorSource` snapshot of the
                    // file's bytes as they were then) and nothing ever
                    // refreshes it afterward. Every subsequent browse back
                    // into the archive -- reopening the very level just
                    // edited included -- kept reading through that stale,
                    // pre-edit snapshot: not just "shows the old version,"
                    // since a repacked archive's entries generally land at
                    // different byte offsets than before, so structured
                    // records (Instance/Trigger/Camera) read against the
                    // wrong offsets came back empty while scenery (read
                    // differently) still rendered something -- exactly the
                    // "I can't see my edits, and now I can't see anything
                    // but scenery" symptom this fixes. Re-mounting the
                    // same URL rebuilds every disc-derived structure fresh
                    // from what was actually just written.
                    await MainActor.run { workspace.refreshingMountedDiscImage(url: discImageURL) }
                } else {
                    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TwinsanityStudioLaunch", isDirectory: true)
                    // `GameLauncher.building` only creates `scratch` itself
                    // when `plan` actually needs it (a starting-chunk
                    // override or archive replacements), the global "Play
                    // in PCSX2" case has neither and returns the image
                    // untouched, so this write's own destination folder
                    // needs to exist regardless of whether building itself
                    // ever touched it.
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                    let built = try GameLauncher.building(isoURL: discImageURL, plan: plan, scratchDirectory: scratch)
                    let originalBytes = ((try? FileManager.default.attributesOfItem(atPath: discImageURL.path))?[.size] as? Int) ?? 0
                    guard await Self.confirmingLargeSizeGrowth(originalBytes: originalBytes, rebuiltBytes: built.count) else {
                        await MainActor.run {
                            isBuilding = false
                            statusMessage = "Canceled, the rebuild grew the disc image more than expected."
                        }
                        return
                    }
                    // Real, reported bug: this used to write to a *fixed*
                    // filename ("quicklaunch.iso"/"launch.iso") reused by
                    // every single launch. PCSX2 is started fire-and-forget
                    // (`GameLauncher.launching`'s own doc comment, this app
                    // never waits for it to quit) and keeps its boot image
                    // open for as long as it's running; if the user hits
                    // Quick Launch again before fully closing (or closing)
                    // the previous PCSX2 window, this in-place-overwrote the
                    // exact file that PCSX2 process could still have open , 
                    // exactly the "doesn't work/crashes after the first use"
                    // symptom. A fresh, unique filename per launch means a
                    // second launch never touches bytes an earlier PCSX2
                    // instance might still be reading.
                    let stem = plan.startingChunkBaseName != nil ? "quicklaunch" : "launch"
                    outputURL = scratch.appendingPathComponent("\(stem)_\(UUID().uuidString).iso")
                    try GameLauncher.writingVerified(built, to: outputURL)
                    // Best-effort cleanup of previous launches' leftover
                    // images (each one is a full disc image, several GB , 
                    // and without this they'd accumulate forever). Safe even
                    // if an old PCSX2 process still has one open: unlinking
                    // a file a process still holds open just detaches the
                    // directory entry on macOS/Unix, that process keeps
                    // working until it closes the file, it just won't show
                    // up in Finder/`ls` anymore.
                    if let existing = try? FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil) {
                        for file in existing where file != outputURL && file.lastPathComponent.hasPrefix(stem) && file.pathExtension.lowercased() == "iso" {
                            try? FileManager.default.removeItem(at: file)
                        }
                    }
                }
                AppLog.rendering.debug("[BuildLaunchDiag] about to launch PCSX2 with outputURL=\(outputURL.path, privacy: .public) saveInPlace=\(saveInPlace, privacy: .public)")
                try GameLauncher.launching(pcsx2AppURL: pcsx2AppURL, isoURL: outputURL)
                AppLog.rendering.debug("[BuildLaunchDiag] GameLauncher.launching returned without throwing")
                await MainActor.run {
                    isBuilding = false
                    statusMessage = saveInPlace
                        ? "Saved to \(outputURL.lastPathComponent) and launched PCSX2."
                        : "Launched PCSX2 with \(outputURL.lastPathComponent)."
                }
            } catch {
                AppLog.rendering.debug("[BuildLaunchDiag] buildAndLaunch failed with error: \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    isBuilding = false
                    isIntegrityFailure = (error as? GameLauncherError).map { if case .integrityCheckFailed = $0 { return true } else { return false } } ?? false
                    isPathTooLongForThisLevel = Self.isPathTooLong(error)
                    errorMessage = Self.friendlyErrorMessage(error, plan: plan)
                }
            }
        }
    }

    /// Whether `error` is specifically the "This Level" boot target's own
    /// path-length limit, drives `isPathTooLongForThisLevel`, which
    /// switches that boot target's hint box from its default confident
    /// "Boots straight into X" framing to a warning, so it doesn't sit
    /// directly above a contradicting red error with nothing tying the two
    /// together.
    private static func isPathTooLong(_ error: Error) -> Bool {
        if case ExecutablePatcherError.pathTooLong = error { return true }
        return false
    }

    /// `error.description` alone, except for `pathTooLong`, a real,
    /// verified format limit (`ExecutablePatcherError.pathTooLong`'s own
    /// doc comment), not a bug, but by itself it doesn't tell the user
    /// there's still a real way to get their pending edits onto the disc:
    /// `bootTarget`'s own "Main Game" option (`effectivePlan`'s doc
    /// comment) still bakes `archiveReplacements` in, it just can't also
    /// skip straight past the main menu for a level whose path doesn't
    /// fit the field.
    private static func friendlyErrorMessage(_ error: Error, plan: GameLaunchPlan) -> String {
        guard case ExecutablePatcherError.pathTooLong = error, !plan.archiveReplacements.isEmpty else {
            return "\(error)"
        }
        return "\(error) Your pending edits are still safe, switch to the \"Main Game\" boot target above and try again; it skips only the direct-boot-to-this-level convenience, not the save."
    }

    /// Rebuilds `plan` on top of the chosen disc image, independently
    /// re-verifies the result (`GameLauncher.rebuildingAndVerifying`), and , 
    /// only once that verification actually passes, lets the user pick a
    /// permanent destination for it. Unlike `buildAndLaunch`, this never
    /// touches PCSX2 and never writes into a throwaway scratch directory the
    /// caller doesn't control the lifetime of.
    private func rebuildAndSave() {
        guard let discImageURL = workspace.discImageURL else { return }
        let plan = effectivePlan
        errorMessage = nil
        isPathTooLongForThisLevel = false
        isIntegrityFailure = false
        diagnostics = []
        isSaving = true
        statusMessage = "Rebuilding and verifying…"
        Task.detached(priority: .userInitiated) {
            do {
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TwinsanityStudioRebuild", isDirectory: true)
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let result = try GameLauncher.rebuildingAndVerifying(isoURL: discImageURL, plan: plan, scratchDirectory: scratch)
                await MainActor.run {
                    diagnostics = result.diagnostics
                }
                guard await Self.confirmingLargeSizeGrowth(originalBytes: result.originalSizeBytes, rebuiltBytes: result.data.count) else {
                    await MainActor.run {
                        isSaving = false
                        statusMessage = "Canceled, the rebuild grew the disc image more than expected."
                    }
                    return
                }
                let suggestedName = discImageURL.deletingPathExtension().lastPathComponent + "-rebuilt.iso"
                let destination: URL? = await MainActor.run {
                    ExportPanel.chooseSaveLocation(suggestedName: suggestedName, message: "Choose where to save the rebuilt, verified disc image.")
                }
                guard let destination else {
                    await MainActor.run {
                        isSaving = false
                        statusMessage = "Save canceled."
                    }
                    return
                }
                try GameLauncher.writingVerified(result.data, to: destination)
                await MainActor.run {
                    isSaving = false
                    statusMessage = "Saved verified rebuilt image to \(destination.lastPathComponent)."
                    // Same fix as `buildAndLaunch`'s `saveInPlace` branch:
                    // if the user picked the *same* path as the disc image
                    // already mounted (not the common case -- the
                    // suggested name steers toward a distinct "-rebuilt"
                    // file -- but a real one), that file's in-memory
                    // mounted snapshot is now stale the same way. Only
                    // refreshes when it's actually the mounted disc, so
                    // this doesn't touch anything when saving to a
                    // genuinely separate file.
                    if destination.standardizedFileURL == workspace.discImageURL?.standardizedFileURL {
                        workspace.refreshingMountedDiscImage(url: destination)
                    }
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    isIntegrityFailure = (error as? GameLauncherError).map { if case .integrityCheckFailed = $0 { return true } else { return false } } ?? false
                    isPathTooLongForThisLevel = Self.isPathTooLong(error)
                    errorMessage = Self.friendlyErrorMessage(error, plan: plan)
                }
            }
        }
    }
}
