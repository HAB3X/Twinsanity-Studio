import Foundation
import CTModels
import CTParsers

public enum GameLauncherError: Error, CustomStringConvertible {
    case notAnISO9660Image
    case systemCNFNotFound
    case systemCNFUnreadable
    case bootExecutableNotFound(String)
    case unrecognizedExecutableSerial(String)
    case archiveIndexNotFound
    case levelNotFoundInArchive(String)
    case pcsx2NotConfigured
    case pcsx2LaunchFailed(String)
    case integrityCheckFailed(String)
    case writeVerificationFailed(expected: Int, actual: Int, path: String)

    public var description: String {
        switch self {
        case .notAnISO9660Image:
            return "That file isn't a plain ISO-9660 image this build can read (raw .bin/.cue images aren't supported for launching, see ISO9660Writer's own doc comment)."
        case .systemCNFNotFound:
            return "No SYSTEM.CNF found at the disc's root, this doesn't look like a real PS2 disc image."
        case .systemCNFUnreadable:
            return "SYSTEM.CNF's BOOT2 line didn't name a real boot executable."
        case .bootExecutableNotFound(let name):
            return "Couldn't find \(name) (SYSTEM.CNF's own boot executable) at the disc's root."
        case .unrecognizedExecutableSerial(let serial):
            return "\(serial) isn't a PS2 serial prefix this build recognizes (expected SLES/SCES, SLUS/SCUS, or SLPS/SCPS/SLPM/SCAJ)."
        case .archiveIndexNotFound:
            return "No .BH archive index found anywhere on this disc."
        case .levelNotFoundInArchive(let name):
            return "\(name) isn't in this disc's archive, can't quick-launch into it."
        case .pcsx2NotConfigured:
            return "PCSX2's app location hasn't been set yet."
        case .pcsx2LaunchFailed(let reason):
            return "Couldn't launch PCSX2: \(reason)"
        case .integrityCheckFailed(let reason):
            return "Rebuilt image failed its own independent re-verification: \(reason)"
        case .writeVerificationFailed(let expected, let actual, let path):
            return "Wrote \(path), but the file on disk is \(actual) bytes, not the \(expected) bytes actually built, refusing to treat this as a successful save (likely ran out of disk space, or the write was interrupted partway through). The disc image at \(path) may be a partial, corrupt file; don't try booting it."
        }
    }
}

/// What a launch build should apply on top of a real, already-bootable
/// PS2 disc image, deliberately just two things, both real, verified
/// mechanisms this project already has, not a general "build the whole
/// modded game" pipeline (this app has no persistent cross-session dirty-
/// tracking to drive that from, see `WorkspaceViewModel.
/// otherLevelSceneryFileRoots`'s own doc comment on the same limitation
/// elsewhere):
/// - `startingChunkBaseName`: boots straight past the menu into one real
///   chunk, via the exact same executable field `ExecutablePatcher.
///   writingStartingChunkPath` already patches, real byte offsets ported
///   from CrateModLoader, not this project's own reverse engineering.
/// - `archiveReplacements`: real archive entries to swap in before
///   repackaging, keyed by their bare filename (e.g. `"beach.rm2"`), this
///   build resolves each one against the disc's own real archive index to
///   find its full path, so callers never need to know the "Levels\..."
///   directory structure themselves.
/// - `newArchiveEntries`: "Chunk Cloning", entries with no existing match
///   in the archive at all, keyed by their full, already-path-qualified
///   name (e.g. `"Levels\\Earth\\Hub\\beach_v2.sm2"`), unlike
///   `archiveReplacements`'s bare-filename keys. There's no existing entry
///   to resolve a bare name against for something that doesn't exist yet , 
///   the caller has already decided exactly where the new file lives
///   (`WorkspaceViewModel.cloningChunk` places it in the same directory as
///   the chunk it was cloned from), so this is used as-is,
///   `ArchiveRepackager.repackage`'s own "no existing match -> append as a
///   new entry" behavior (see that function's own doc comment) doing the
///   actual insertion.
public struct GameLaunchPlan {
    public var startingChunkBaseName: String?
    public var archiveReplacements: [String: Data]
    public var newArchiveEntries: [String: Data]

    public init(startingChunkBaseName: String? = nil, archiveReplacements: [String: Data] = [:], newArchiveEntries: [String: Data] = [:]) {
        self.startingChunkBaseName = startingChunkBaseName
        self.archiveReplacements = archiveReplacements
        self.newArchiveEntries = newArchiveEntries
    }
}

/// Builds a real, patched copy of an existing bootable PS2 `.iso` and
/// launches it in PCSX2, "Direct Boot/Launch." Deliberately patches an
/// already-known-bootable image in place (`ISO9660Writer.replacingFile`)
/// rather than building a brand-new disc from a folder tree
/// (`ISO9660ImageBuilder`, which that type's own doc comment is explicit
/// has never been verified to actually boot anywhere), every byte this
/// doesn't touch is guaranteed identical to the original disc, so nothing
/// about *booting* the result is new risk, only the specific files this
/// plan asks to change.
public enum GameLauncher {
    /// Reads `isoURL`'s full bytes and applies `plan` on top, returning the
    /// finished image ready to write out and boot. `scratchDirectory` holds
    /// short-lived extraction/repackaging files (the disc's own `.BH`/`.BD`
    /// pair, and the repackaged replacement), safe to delete once this
    /// returns.
    public static func building(isoURL: URL, plan: GameLaunchPlan, scratchDirectory: URL) throws -> Data {
        let isoData = try Data(contentsOf: isoURL, options: .mappedIfSafe)
        let source = PlainISOSource(data: isoData)
        guard let root = try? ISO9660Reader.readRootDirectory(from: source), !root.children.isEmpty else {
            throw GameLauncherError.notAnISO9660Image
        }

        // Created unconditionally, before the early-return below, a
        // caller writing its own output file into `scratchDirectory`
        // afterward (as `GameLauncherView` does) shouldn't have to know
        // whether this call happened to need it internally. A real bug:
        // the "Play in PCSX2" global launch (no starting-chunk override,
        // no archive replacements) hit the early return before this used
        // to run, so the directory never existed and the caller's own
        // write failed with "No such file or directory."
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

        var patchedISO = isoData
        guard plan.startingChunkBaseName != nil || !plan.archiveReplacements.isEmpty || !plan.newArchiveEntries.isEmpty else {
            return patchedISO
        }

        let (bhEntry, bdEntry) = try locateArchivePair(in: root)
        guard let bhData = ISO9660Reader.readFile(bhEntry, from: source),
              let bdData = ISO9660Reader.readFile(bdEntry, from: source)
        else { throw GameLauncherError.archiveIndexNotFound }

        let tempBH = scratchDirectory.appendingPathComponent((bhEntry.name as NSString).lastPathComponent)
        let tempBD = scratchDirectory.appendingPathComponent((bdEntry.name as NSString).lastPathComponent)
        try bhData.write(to: tempBH)
        try bdData.write(to: tempBD)
        let index = try BDArchiveParser.readIndex(bhURL: tempBH)

        if let baseName = plan.startingChunkBaseName {
            // Unlike `archiveReplacements` (matched by full filename, e.g.
            // "cavent.rm2"), a chunk name has no single extension of its
            // own, it names the pair of .sm2/.rm2 files that share it , 
            // so this strips the entry's extension before comparing.
            guard let match = index.entries.first(where: { (entryBaseName($0.name) as NSString).deletingPathExtension.lowercased() == baseName.lowercased() }) else {
                throw GameLauncherError.levelNotFoundInArchive(baseName)
            }
            // Not lowercased: the retail executable's own default value for
            // this exact field (verified against real disc bytes) reads
            // "Levels\Earth\Hub\Beach" -- mixed case, matching neither a
            // fully-lowercased path nor the archive's own stored filename
            // case ("Levels/Earth/Hub/beach.rm2", lowercase filename). A
            // prior version of this code force-lowercased the whole path
            // based on a different subsystem's convention (`ChunkLink.path`,
            // a runtime level-transition record decoded from level data,
            // confirmed lowercase) -- but that's an unrelated mechanism from
            // this static, boot-time executable field, and real, isolated
            // PCSX2 boots (both in-place-patch and full-rebuild strategies)
            // showed the lowercased value black-screening. Using the
            // archive's own real, disc-verified path segments here --
            // rather than inventing a transformation this project has no
            // evidence for -- is the least-invented option: not proven
            // correct for every level, but the closest available match to
            // what's actually on the disc.
            let windowsPath = match.name.replacingOccurrences(of: "/", with: "\\")
            let startingChunkPath = (windowsPath as NSString).deletingPathExtension
            let (exeEntry, revision) = try locateBootExecutable(in: root, source: source)
            guard let exeData = ISO9660Reader.readFile(exeEntry, from: source) else {
                throw GameLauncherError.bootExecutableNotFound(exeEntry.name)
            }
            let patchedExe = try ExecutablePatcher.writingStartingChunkPath(startingChunkPath, revision: revision, into: exeData)
            patchedISO = try ISO9660Writer.replacingFile(exeEntry, with: patchedExe, in: patchedISO)
        }

        if !plan.archiveReplacements.isEmpty || !plan.newArchiveEntries.isEmpty {
            var fullNameReplacements: [String: Data] = [:]
            for (bareName, data) in plan.archiveReplacements {
                guard let match = index.entries.first(where: { entryBaseName($0.name).lowercased() == bareName.lowercased() }) else {
                    throw GameLauncherError.levelNotFoundInArchive(bareName)
                }
                fullNameReplacements[match.name] = data
            }
            // `newArchiveEntries` is already keyed by full, path-qualified
            // name (see `GameLaunchPlan`'s own doc comment), no bare-name
            // resolution needed, merged straight in.
            for (fullName, data) in plan.newArchiveEntries {
                fullNameReplacements[fullName] = data
            }
            let newBH = scratchDirectory.appendingPathComponent("relaunch_\(tempBH.lastPathComponent)")
            let newBD = scratchDirectory.appendingPathComponent("relaunch_\(tempBD.lastPathComponent)")
            try? FileManager.default.removeItem(at: newBH)
            try? FileManager.default.removeItem(at: newBD)
            try ArchiveRepackager.repackage(index: index, replacements: fullNameReplacements, outputBH: newBH, outputBD: newBD)
            let newBHData = try Data(contentsOf: newBH)
            let newBDData = try Data(contentsOf: newBD)
            patchedISO = try ISO9660Writer.replacingFile(bhEntry, with: newBHData, in: patchedISO)
            patchedISO = try ISO9660Writer.replacingFile(bdEntry, with: newBDData, in: patchedISO)
        }

        return patchedISO
    }

    /// Same contract as `building(isoURL:plan:scratchDirectory:)`, but
    /// builds the result the way the original reference editor's own
    /// "Image Maker" does, and the way real, reported evidence points at:
    /// extracts every real file to a scratch folder, patches the specific
    /// files this plan asks to change *on disk*, then rebuilds a genuinely
    /// fresh disc from that folder via `ISO9660ImageBuilder`, instead of
    /// patching an existing image in place and relocating whatever grew
    /// (`ISO9660Writer.replacingFile`/`appendAndRelocate`). Every edit-
    /// verification this project could run against the in-place-patch
    /// approach passed (real PCSX2 boots, correct Game CRC, accumulated
    /// play time, byte-exact round-trip re-reads), but none of them could
    /// see the actual screen, and the one thing they never independently
    /// confirmed is "shows real gameplay, not a black screen," which is
    /// exactly the real, reported, still-unresolved symptom. `ISO9660ImageBuilder`
    /// itself already has separate real-PCSX2-boot verification of its own
    /// (`ImageMakerBootVerificationTests`), so this reuses a genuinely
    /// different, independently-proven code path rather than guessing at
    /// another patch to the relocation logic.
    public static func buildingFresh(isoURL: URL, plan: GameLaunchPlan, scratchDirectory: URL) throws -> Data {
        let isoData = try Data(contentsOf: isoURL, options: .mappedIfSafe)
        let source = PlainISOSource(data: isoData)
        guard let root = try? ISO9660Reader.readRootDirectory(from: source), !root.children.isEmpty else {
            throw GameLauncherError.notAnISO9660Image
        }

        let extractedRoot = scratchDirectory.appendingPathComponent("extracted", isDirectory: true)
        try? FileManager.default.removeItem(at: extractedRoot)
        try FileManager.default.createDirectory(at: extractedRoot, withIntermediateDirectories: true)

        // Every real file, preserving the disc's own directory structure , 
        // `ISO9660ImageBuilder` walks this same folder shape back into a
        // fresh image.
        func extract(_ entry: ISO9660Entry, into directory: URL) throws {
            if entry.isDirectory {
                let subdirectory = directory.appendingPathComponent(entry.name, isDirectory: true)
                if !entry.name.isEmpty {
                    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
                }
                for child in entry.children {
                    try extract(child, into: entry.name.isEmpty ? directory : subdirectory)
                }
            } else {
                guard let data = ISO9660Reader.readFile(entry, from: source) else {
                    throw GameLauncherError.bootExecutableNotFound(entry.name)
                }
                try data.write(to: directory.appendingPathComponent(entry.name))
            }
        }
        try extract(root, into: extractedRoot)

        if let baseName = plan.startingChunkBaseName {
            let (bhEntry, _) = try locateArchivePair(in: root)
            let bhData = ISO9660Reader.readFile(bhEntry, from: source) ?? Data()
            let tempBH = scratchDirectory.appendingPathComponent("fresh_index_\(bhEntry.name.replacingOccurrences(of: "/", with: "_")).BH")
            try bhData.write(to: tempBH)
            let index = try BDArchiveParser.readIndex(bhURL: tempBH)
            guard let match = index.entries.first(where: { (entryBaseName($0.name) as NSString).deletingPathExtension.lowercased() == baseName.lowercased() }) else {
                throw GameLauncherError.levelNotFoundInArchive(baseName)
            }
            let windowsPath = match.name.replacingOccurrences(of: "/", with: "\\")
            let startingChunkPath = (windowsPath as NSString).deletingPathExtension
            let (exeEntry, revision) = try locateBootExecutable(in: root, source: source)
            let exePath = extractedRoot.appendingPathComponent(exeEntry.name)
            let exeData = try Data(contentsOf: exePath)
            let patchedExe = try ExecutablePatcher.writingStartingChunkPath(startingChunkPath, revision: revision, into: exeData)
            try patchedExe.write(to: exePath)
        }

        if !plan.archiveReplacements.isEmpty || !plan.newArchiveEntries.isEmpty {
            let (bhEntry, bdEntry) = try locateArchivePair(in: root)
            let bhData = ISO9660Reader.readFile(bhEntry, from: source) ?? Data()
            let bdData = ISO9660Reader.readFile(bdEntry, from: source) ?? Data()
            let tempBH = scratchDirectory.appendingPathComponent("fresh_index2_\(bhEntry.name.replacingOccurrences(of: "/", with: "_")).BH")
            let (_, tempBD) = try BDArchiveParser.counterpartURL(for: tempBH)
            try bhData.write(to: tempBH)
            try bdData.write(to: tempBD)
            let index = try BDArchiveParser.readIndex(bhURL: tempBH)
            var fullNameReplacements: [String: Data] = [:]
            for (bareName, data) in plan.archiveReplacements {
                guard let match = index.entries.first(where: { entryBaseName($0.name).lowercased() == bareName.lowercased() }) else {
                    throw GameLauncherError.levelNotFoundInArchive(bareName)
                }
                fullNameReplacements[match.name] = data
            }
            for (fullName, data) in plan.newArchiveEntries {
                fullNameReplacements[fullName] = data
            }
            let newBH = scratchDirectory.appendingPathComponent("relaunch_fresh_\(bhEntry.name.replacingOccurrences(of: "/", with: "_"))")
            let newBD = scratchDirectory.appendingPathComponent("relaunch_fresh_\(bdEntry.name.replacingOccurrences(of: "/", with: "_"))")
            try? FileManager.default.removeItem(at: newBH)
            try? FileManager.default.removeItem(at: newBD)
            try ArchiveRepackager.repackage(index: index, replacements: fullNameReplacements, outputBH: newBH, outputBD: newBD)
            try Data(contentsOf: newBH).write(to: extractedRoot.appendingPathComponent(bhEntry.name))
            try Data(contentsOf: newBD).write(to: extractedRoot.appendingPathComponent(bdEntry.name))
        }

        let volumeLabel = Self.readVolumeLabel(from: isoData) ?? "TWINSANITY"
        return try ISO9660ImageBuilder.buildingImage(from: extractedRoot, volumeLabel: volumeLabel)
    }

    /// The Primary Volume Descriptor's own Volume Identifier (ECMA-119
    /// 8.4.9, PVD byte offset 40, 32 d-characters, space-padded), read
    /// directly rather than through a dedicated `ISO9660Reader` API purely
    /// because nothing else in this codebase has needed it before now.
    /// `nil` if the image is too small or has no readable PVD at that
    /// offset; the caller falls back to a fixed label rather than failing
    /// the whole build over a cosmetic field.
    private static func readVolumeLabel(from isoData: Data) -> String? {
        let pvdOffset = 16 * 2048
        let base = isoData.startIndex + pvdOffset + 40
        guard base + 32 <= isoData.endIndex else { return nil }
        let bytes = isoData[base..<(base + 32)]
        guard let string = String(bytes: bytes, encoding: .ascii) else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A rebuilt disc image that has passed its own independent re-
    /// verification (see `rebuildingAndVerifying`), `diagnostics` is the
    /// ordered, human-readable trail of exactly what got checked, meant to
    /// be shown to the user directly (e.g. in a scrollable text area), not
    /// just logged.
    public struct RebuildResult {
        public var data: Data
        public var diagnostics: [String]
        /// "Strict Size Guardrails", the real, on-disk byte count of the
        /// disc image this rebuild started from, captured before any edit
        /// was applied. Together with `data.count`, this is what
        /// `sizeGrowthFraction`/`exceedsSizeGrowthThreshold` below check , 
        /// carried on the result itself so a caller never has to
        /// separately re-stat the original file (and risk it having
        /// changed underneath it) just to ask "how much did this grow."
        public var originalSizeBytes: Int

        public init(data: Data, diagnostics: [String], originalSizeBytes: Int) {
            self.data = data
            self.diagnostics = diagnostics
            self.originalSizeBytes = originalSizeBytes
        }

        /// `(rebuilt - original) / original`, negative when the rebuild
        /// actually shrank the image (a real, expected outcome now that
        /// `ISO9660Writer`'s own relocation reclaims a file's prior tail
        /// space instead of always growing). `0` when `originalSizeBytes`
        /// is `0` (nothing to divide by, and not a real disc image
        /// regardless) rather than producing `infinity`/`NaN`.
        public var sizeGrowthFraction: Double {
            GameLauncher.sizeGrowthFraction(originalBytes: originalSizeBytes, rebuiltBytes: data.count)
        }

        /// "No minor edit justifies more than a 25% size increase", the
        /// real, requested guardrail. `true` means the caller should warn
        /// and get explicit confirmation before writing this result
        /// anywhere real (overwriting the user's own disc image, or baking
        /// it into a permanent save), see `GameLauncherView`'s own
        /// confirmation flow and `WorkspaceViewModel.
        /// savingPendingLevelViewerEditsToMountedDisc`'s quit-time one for
        /// the two real call sites that act on this.
        public func exceedsSizeGrowthThreshold(_ threshold: Double = GameLauncher.defaultSizeGrowthWarningThreshold) -> Bool {
            sizeGrowthFraction > threshold
        }
    }

    /// "Strict Size Guardrails", no incidental edit (a moved object, a
    /// swapped texture, a handful of new Instances) plausibly justifies
    /// growing the whole disc image by more than a quarter of its own
    /// size; a rebuild that does is worth a human actually looking at
    /// before it's trusted, not silently written over the user's real
    /// disc image. `25%` is a deliberately generous ceiling for
    /// legitimate large edits (a new texture pack, a big level rebuild)
    /// while still catching the class of bug this guardrail exists for:
    /// an accidental full-content duplication.
    public static let defaultSizeGrowthWarningThreshold: Double = 0.25

    /// Pure, no I/O, `(rebuiltBytes - originalBytes) / originalBytes`.
    /// Factored out of `RebuildResult.sizeGrowthFraction` so it's directly
    /// testable against plain integers, with no need to build a real disc
    /// image just to exercise the arithmetic (and its one edge case: an
    /// `originalBytes` of `0`, which returns `0` rather than dividing by
    /// zero).
    public static func sizeGrowthFraction(originalBytes: Int, rebuiltBytes: Int) -> Double {
        guard originalBytes > 0 else { return 0 }
        return Double(rebuiltBytes - originalBytes) / Double(originalBytes)
    }

    /// Same build `building(isoURL:plan:scratchDirectory:)` performs, but
    /// for a caller that means to keep the result permanently ("Save
    /// Rebuilt ISO…") rather than hand it straight to PCSX2 for one
    /// throwaway launch, so this doesn't just trust the write succeeded,
    /// it independently re-reads the finished bytes back through the same
    /// real parsers (`ISO9660Reader`, `BDArchiveParser`) a genuine consumer
    /// would use, the same way `building` itself only ever *writes* via
    /// `ISO9660Writer.replacingFile` without reading its own output back.
    /// Every check that runs appends one specific, real diagnostic line
    /// (byte/sector counts, entry counts, matched names) rather than a bare
    /// "OK," so a caller can show genuine progress instead of a spinner.
    public static func rebuildingAndVerifying(isoURL: URL, plan: GameLaunchPlan, scratchDirectory: URL) throws -> RebuildResult {
        var diagnostics: [String] = []
        // Captured before `building` touches anything, the real "before"
        // size `RebuildResult.sizeGrowthFraction` compares against. A cheap
        // file-attribute stat, not a second full read of the image.
        let originalSizeBytes = ((try? FileManager.default.attributesOfItem(atPath: isoURL.path))?[.size] as? Int) ?? 0
        let built = try building(isoURL: isoURL, plan: plan, scratchDirectory: scratchDirectory)

        guard built.count % 2048 == 0 else {
            throw GameLauncherError.integrityCheckFailed("Rebuilt image is \(built.count) bytes, not a whole number of 2048-byte sectors.")
        }
        let sectorCount = built.count / 2048
        diagnostics.append("Rebuilt image: \(built.count) bytes (\(sectorCount) sectors).")
        let growthFraction = sizeGrowthFraction(originalBytes: originalSizeBytes, rebuiltBytes: built.count)
        let growthPercentText = String(format: "%+.1f%%", growthFraction * 100)
        diagnostics.append("Size check: original \(originalSizeBytes) bytes -> rebuilt \(built.count) bytes (\(growthPercentText)).")
        if growthFraction > defaultSizeGrowthWarningThreshold {
            diagnostics.append("⚠️ Size growth exceeds the \(Int(defaultSizeGrowthWarningThreshold * 100))% guardrail, this needs explicit confirmation before it's written anywhere real.")
        }

        let source = PlainISOSource(data: built)
        guard let root = try? ISO9660Reader.readRootDirectory(from: source), !root.children.isEmpty else {
            throw GameLauncherError.integrityCheckFailed("Couldn't re-read the rebuilt image's root directory, or it came back with no children.")
        }
        diagnostics.append("Integrity check: root directory re-read cleanly (\(root.children.count) entries).")

        if let baseName = plan.startingChunkBaseName {
            let (exeEntry, revision) = try locateBootExecutable(in: root, source: source)
            guard let exeData = ISO9660Reader.readFile(exeEntry, from: source), !exeData.isEmpty else {
                throw GameLauncherError.integrityCheckFailed("Couldn't re-read the boot executable (\(exeEntry.name)) back from the rebuilt image.")
            }
            guard let readBackPath = ExecutablePatcher.readStartingChunkPath(revision: revision, from: exeData) else {
                throw GameLauncherError.integrityCheckFailed("Couldn't read a starting-chunk path back out of the rebuilt boot executable.")
            }
            diagnostics.append("Integrity check: boot executable \(exeEntry.name) re-read cleanly (\(exeData.count) bytes), starting chunk patched to \"\(readBackPath)\".")
            _ = baseName // the specific chunk name is only used to build `plan`; the read-back above is the real verification.
        }

        if !plan.archiveReplacements.isEmpty || !plan.newArchiveEntries.isEmpty {
            let (bhEntry, bdEntry) = try locateArchivePair(in: root)
            guard let bhData = ISO9660Reader.readFile(bhEntry, from: source), let bdData = ISO9660Reader.readFile(bdEntry, from: source) else {
                throw GameLauncherError.integrityCheckFailed("Couldn't re-read the rebuilt image's own \(bhEntry.name)/\(bdEntry.name) archive pair.")
            }
            // Real, reported bug: this directory (holding a full re-extracted
            // copy of the rebuilt archive, easily the better part of a
            // gigabyte) was never cleaned up, every single "Save changes to
            // this ISO"/"Save Rebuilt ISO…" left one more permanent copy
            // behind. Its own lifetime is entirely local to this block (write,
            // re-parse, done), so it's safe to always remove once that's over.
            let verifyDir = scratchDirectory.appendingPathComponent("verify_\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: verifyDir) }
            try FileManager.default.createDirectory(at: verifyDir, withIntermediateDirectories: true)
            let verifyBH = verifyDir.appendingPathComponent((bhEntry.name as NSString).lastPathComponent)
            let verifyBD = verifyDir.appendingPathComponent((bdEntry.name as NSString).lastPathComponent)
            try bhData.write(to: verifyBH)
            try bdData.write(to: verifyBD)
            let index: ArchiveIndex
            do {
                index = try BDArchiveParser.readIndex(bhURL: verifyBH)
            } catch {
                throw GameLauncherError.integrityCheckFailed("Rebuilt archive index (\(bhEntry.name)) failed to parse: \(error)")
            }
            diagnostics.append("Integrity check: rebuilt archive \(bhEntry.name)/\(bdEntry.name) re-extracted and its index parsed cleanly (\(index.entries.count) entries).")

            for bareName in plan.archiveReplacements.keys {
                guard index.entries.contains(where: { entryBaseName($0.name).caseInsensitiveCompare(bareName) == .orderedSame }) else {
                    throw GameLauncherError.integrityCheckFailed("Replacement \"\(bareName)\" isn't present in the rebuilt archive's own index.")
                }
            }
            if !plan.archiveReplacements.isEmpty {
                diagnostics.append("Integrity check: all \(plan.archiveReplacements.count) requested replacement(s) confirmed present in the rebuilt archive index.")
            }
            for fullName in plan.newArchiveEntries.keys {
                guard index.entries.contains(where: { $0.name.caseInsensitiveCompare(fullName) == .orderedSame }) else {
                    throw GameLauncherError.integrityCheckFailed("New entry \"\(fullName)\" isn't present in the rebuilt archive's own index.")
                }
            }
            if !plan.newArchiveEntries.isEmpty {
                diagnostics.append("Integrity check: all \(plan.newArchiveEntries.count) new entries confirmed present in the rebuilt archive index.")
            }
        }

        return RebuildResult(data: built, diagnostics: diagnostics, originalSizeBytes: originalSizeBytes)
    }

    /// Writes `data` to `url`, then independently reads the file's own
    /// size back off disk and confirms it matches, real, reported bug
    /// this guards against: a disc image saved through this app was later
    /// found sitting on disk at exactly 2GB, while the level/asset data
    /// this build actually produced was several times that. `Data
    /// .write(to:)` throws on most real I/O failures (disk full,
    /// permission denied), but a silent short write is exactly the
    /// failure mode that produces a *file that exists and opens fine* , 
    /// just quietly missing everything past wherever it stopped, which
    /// is indistinguishable from a real, complete disc image until
    /// something tries to read past the cutoff (a PS2 booting it, in this
    /// case, as a black screen once the game reaches for data that was
    /// never actually written). Catching that gap right here, immediately
    /// after the write, is far more useful than a boot log full of
    /// symptoms three steps removed from the actual cause.
    public static func writingVerified(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? Int) ?? -1
        guard actualSize == data.count else {
            throw GameLauncherError.writeVerificationFailed(expected: data.count, actual: actualSize, path: url.path)
        }
    }

    /// Launches PCSX2 with `isoURL` as its boot target, fire-and-forget,
    /// deliberately not waiting for it to quit (unlike this codebase's other
    /// `Process` use in `CrateExporter`/`CrateArchiveManager`, both of which
    /// run short-lived command-line tools and need their exit status; PCSX2
    /// is a long-running interactive GUI app, so `waitUntilExit()` here
    /// would block the whole call until the user closes the emulator).
    public static func launching(pcsx2AppURL: URL, isoURL: URL) throws {
        let executableURL = pcsx2AppURL.pathExtension.lowercased() == "app"
            ? pcsx2AppURL.appendingPathComponent("Contents/MacOS/PCSX2")
            : pcsx2AppURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GameLauncherError.pcsx2LaunchFailed("\(executableURL.lastPathComponent) isn't an executable file.")
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--", isoURL.path]
        do {
            try process.run()
        } catch {
            throw GameLauncherError.pcsx2LaunchFailed(error.localizedDescription)
        }
    }

    // MARK: - Disc tree lookups

    private static func entryBaseName(_ archiveEntryName: String) -> String {
        (archiveEntryName as NSString).lastPathComponent
    }

    /// SYSTEM.CNF + the boot executable it names, both always sit directly
    /// at the disc's root on a real PS2 disc, so this only ever looks at
    /// `root.children`, never recurses.
    private static func locateBootExecutable(in root: ISO9660Entry, source: PlainISOSource) throws -> (entry: ISO9660Entry, revision: GameExecutableRevision) {
        guard let cnfEntry = root.children.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare("SYSTEM.CNF") == .orderedSame }) else {
            throw GameLauncherError.systemCNFNotFound
        }
        guard let cnfData = ISO9660Reader.readFile(cnfEntry, from: source), let cnfText = String(data: cnfData, encoding: .ascii) else {
            throw GameLauncherError.systemCNFUnreadable
        }
        let info = SystemCNFParser.parse(contents: cnfText)
        guard let serial = info.serial else { throw GameLauncherError.systemCNFUnreadable }
        guard let exeEntry = root.children.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare(serial) == .orderedSame }) else {
            throw GameLauncherError.bootExecutableNotFound(serial)
        }
        guard let exeData = ISO9660Reader.readFile(exeEntry, from: source) else {
            throw GameLauncherError.bootExecutableNotFound(serial)
        }
        let revision = try revisionForSerial(serial, exeData: exeData)
        return (exeEntry, revision)
    }

    private static func revisionForSerial(_ serial: String, exeData: Data) throws -> GameExecutableRevision {
        let upper = serial.uppercased()
        if upper.hasPrefix("SLES") || upper.hasPrefix("SCES") { return .pal }
        if upper.hasPrefix("SLPS") || upper.hasPrefix("SCPS") || upper.hasPrefix("SLPM") || upper.hasPrefix("SCAJ") { return .ntscJ }
        if upper.hasPrefix("SLUS") || upper.hasPrefix("SCUS") {
            return ExecutablePatcher.detectNTSCURevision(exeData: exeData) ?? .ntscU
        }
        throw GameLauncherError.unrecognizedExecutableSerial(serial)
    }

    /// The disc's `.BH`/`.BD` archive pair, searched recursively (unlike
    /// the boot executable) since real Twinsanity discs nest it inside a
    /// subdirectory (`CRASH6\CRASH.BH`, confirmed against the real retail
    /// disc), not at the root.
    private static func locateArchivePair(in root: ISO9660Entry) throws -> (bh: ISO9660Entry, bd: ISO9660Entry) {
        func walk(_ node: ISO9660Entry) -> (bh: ISO9660Entry, bd: ISO9660Entry)? {
            if let bh = node.children.first(where: { !$0.isDirectory && $0.name.uppercased().hasSuffix(".BH") }) {
                let base = (bh.name as NSString).deletingPathExtension
                if let bd = node.children.first(where: { !$0.isDirectory && (($0.name as NSString).deletingPathExtension).caseInsensitiveCompare(base) == .orderedSame && $0.name.uppercased().hasSuffix(".BD") }) {
                    return (bh, bd)
                }
            }
            for child in node.children where child.isDirectory {
                if let found = walk(child) { return found }
            }
            return nil
        }
        guard let pair = walk(root) else { throw GameLauncherError.archiveIndexNotFound }
        return pair
    }
}
