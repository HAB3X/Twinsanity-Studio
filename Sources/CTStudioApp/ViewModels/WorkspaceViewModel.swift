import Foundation
import SwiftUI
import Observation
import simd
import CTCore
import CTModels
import CTParsers
import CTExport

/// One entry in the Textures Hub (QoL sweep), a decoded texture plus which
/// file it came from. Own type rather than reusing `TextureAsset.id`
/// directly as `Identifiable`: `TextureAsset.id` is the on-disk record ID,
/// which (same reasoning as `Resolved  ModelAsset.id`) recurs constantly
/// across hundreds of different files in a global, workspace-wide list.
public struct TextureHubEntry: Sendable, Identifiable, Codable {
    public let id = UUID()
    public var sourceLabel: String
    public var texture: TextureAsset

    /// `id` is deliberately excluded, it's a fresh, per-session identity
    /// (see this type's own doc comment), never meant to round-trip
    /// through `ScanCache`'s `Codable` persistence. Without this, the
    /// compiler-synthesized `Codable` conformance still tries to decode
    /// `id` against an immutable `let`, which can't actually be
    /// overwritten, harmless (a fresh `UUID()` wins either way) but a
    /// real build warning on every build.
    private enum CodingKeys: String, CodingKey {
        case sourceLabel, texture
    }

    public init(sourceLabel: String, texture: TextureAsset) {
        self.sourceLabel = sourceLabel
        self.texture = texture
    }
}

/// One entry in the Levels Hub, a decoded `SceneryData` record (a level's
/// static-geometry placement tree) plus the `ChunkNode` it came from, so
/// clicking a card can both resolve its placements (`resolvedLevelPlacements`)
/// and look up sibling `Instance` records in the same file for the Level
/// Viewer's markers. Deliberately *not* `Codable`/cached through
/// `ScanCache` like `ResolvedModelAsset`/`TextureHubEntry` are: `ChunkNode`
/// is a reference-type chunk tree, not a value snapshot, so this only ever
/// exists for files that are actually parsed and held in memory this
/// session, same as browsing the sidebar tree itself, `levelsHub` is empty
/// again after a cache-hit load until something re-parses the file.
public struct LevelHubEntry: Sendable, Identifiable {
    public let id = UUID()
    public var sourceLabel: String
    public var scenery: SceneryAsset
    public var node: ChunkNode

    public init(sourceLabel: String, scenery: SceneryAsset, node: ChunkNode) {
        self.sourceLabel = sourceLabel
        self.scenery = scenery
        self.node = node
    }
}

/// One line in the Engine Console (blueprint 7.5), a real status/error
/// event this session actually produced, timestamped when it happened.
public struct EngineLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let message: String
    public let isError: Bool

    public init(timestamp: Date = Date(), message: String, isError: Bool) {
        self.timestamp = timestamp
        self.message = message
        self.isError = isError
    }
}

/// Drives the whole workspace: what's open, the search filter, the current
/// selection, and drag-drop ingestion. One instance is shared by the whole
/// app (`ContentView` owns it as a `@StateObject`).
@MainActor
@Observable
public final class WorkspaceViewModel {
    /// `findFileRoot(containing:in:)` memoizes its result here, keyed by
    /// `ChunkNode.id`, see that function's own doc comment for why. Any
    /// structural change to the tree can change what a given node's file
    /// root actually is (a placeholder entry expanding into real content,
    /// an archive scan replacing entries wholesale), so this must be
    /// invalidated on every `rootNodes` mutation; the `didSet` below does
    /// that unconditionally rather than relying on every individual mutation
    /// site remembering to clear it.
    // Real, reported crash (SwiftUI AttributeGraph precondition failure,
    // `abort()`): every one of these four caches is a plain `@Observable`-
    // tracked stored property, and each gets *written* from inside a pure
    // query function (`findFileRoot`/`owningArchiveRootID`/`topLevelRoot`/
    // `filteredRootNodes`) that views call synchronously mid-`body` (e.g.
    // `canSaveEdits`, read from `LevelViewerWindow.modeRail`'s own view
    // body). A cache *miss* during that exact call mutates tracked state
    // while the view graph is still mid-read of it, genuinely undefined
    // under Swift's Observation framework (same underlying "don't mutate
    // observed state mid-update" rule `select(_:)`'s own doc comment
    // describes, just triggered by a cache write instead of a Binding
    // callback), and unlike `select`'s fix, deferring to the next run loop
    // tick isn't an option here: `canSaveEdits` needs a synchronous answer
    // to render the *current* frame, it can't wait a tick. `@ObservationIgnored`
    // is the correct fix instead: nothing legitimately needs a view to
    // re-render because one of these internal memoization caches changed
    //, each cache's own real invalidation is already driven by genuinely
    // tracked state (`rootNodes`'s `didSet`, etc.), so excluding the cache
    // storage itself from Observation loses no real reactivity.
    @ObservationIgnored
    private var fileRootCache: [UUID: ChunkNode?] = [:]
    /// `owningArchiveRootID(of:)`'s own memoization, same shape and same
    /// invalidation as `fileRootCache` right above, a real, reported
    /// performance bug this pass missed: unlike `findFileRoot`/
    /// `canSaveEdits`, `owningArchiveRootID` still did a full, uncached
    /// recursive tree walk per call, and it's exactly what `select(_:)`
    /// calls for every click on an unexpanded archive entry, the dominant
    /// case while a background scan is still in progress, when most of the
    /// tree is still unexpanded placeholders. At "hundreds of archive
    /// roots, each with a large subtree" scale that's real, multi-second
    /// dead latency per click.
    @ObservationIgnored
    private var owningArchiveRootIDCache: [UUID: UUID?] = [:]
    /// `topLevelRoot(containing:in:)`'s own memoization, the same
    /// `owningArchiveRootID`-shaped bug, found in a follow-up consistency
    /// sweep: `InspectorView.canReplaceDiscFile(node)` calls this on every
    /// single `InspectorView.body` re-evaluation (that view's own doc
    /// comment already notes it re-renders on *any* `workspace` mutation,
    /// not just a `node` change), and this did a full uncached recursive
    /// `node.children.contains(where:)` walk every time.
    @ObservationIgnored
    private var topLevelRootCache: [UUID: ChunkNode?] = [:]
    /// `filteredRootNodes`'s own memoization key, real, reported
    /// performance bug: that computed property does three full recursive
    /// tree passes (raw-content pruning, type filter, search filter), each
    /// allocating a fresh `ChunkNode` per surviving node, with *no*
    /// memoization at all, and it's read on essentially every `SidebarView`
    /// render. At "hundreds of files" scale, once a background scan
    /// finishes and the tree is fully populated, this is real, repeated,
    /// unbounded work on every render, not just once. Bumped (not just
    /// cleared) by every input `filteredRootNodes` actually reads , 
    /// `rootNodes`, `showRawFiles`, `typeFilter`, `searchQuery`, and
    /// `discEntryByNodeID` (subscript mutation on a stored `var` dictionary
    /// still triggers its own `didSet`, so registering new disc entries
    /// invalidates this too), so the cache can never observe a stale
    /// combination of inputs.
    @ObservationIgnored
    private var filterInputsGeneration = 0
    @ObservationIgnored
    private var filteredRootNodesCache: (generation: Int, result: [ChunkNode])?
    public var rootNodes: [ChunkNode] = [] {
        didSet {
            fileRootCache.removeAll()
            owningArchiveRootIDCache.removeAll()
            topLevelRootCache.removeAll()
            filterInputsGeneration += 1
        }
    }
    public var searchQuery: String = "" {
        didSet { filterInputsGeneration += 1 }
    }
    /// `nil` means "every kind", set to jump straight to e.g. every decoded
    /// `Animation` in the workspace, regardless of which file it's buried in.
    public var typeFilter: ChunkPayload.Kind? {
        didSet { filterInputsGeneration += 1 }
    }
    /// "Smart File Filtering" (Settings' Developer Mode toggle): when
    /// `false` (the default), `filteredRootNodes` prunes undecoded/raw
    /// leaves and any folder that only contains them, see `ChunkNode.
    /// prunedOfRawContent()`. Persisted so a developer who turns this on
    /// doesn't have to re-toggle it every launch.
    public var showRawFiles = false {
        didSet {
            UserDefaults.standard.set(showRawFiles, forKey: Self.showRawFilesDefaultsKey)
            filterInputsGeneration += 1
        }
    }
    private static let showRawFilesDefaultsKey = "TwinsanityStudio.ShowRawFiles"
    public var selectedNode: ChunkNode?
    /// "Real-Time Engine Console" (blueprint 7.5): every non-empty value
    /// this property (and `lastError` below) ever takes is also appended to
    /// `engineLog`, one `didSet` here instead of touching every one of the
    /// ~20 call sites that already set `statusMessage` throughout this file,
    /// so the console always shows exactly the same real events the status
    /// banner does, nothing invented. Note this deliberately does *not*
    /// attempt "translating raw hex crash addresses into plain-language
    /// explanations" from the original blueprint wording, that needs a
    /// crash/symbolication pipeline this app has no source for; the console
    /// is a real event log, not a fabricated one.
    public var statusMessage: String = "Drop a .BH/.BD archive, .RM2/.SM2 file, or a folder to begin." {
        didSet { if !statusMessage.isEmpty { engineLog.append(EngineLogEntry(message: statusMessage, isError: false)) } }
    }
    public var isLoading = false
    public var isScanning = false
    /// "Visual Loading Feedback": every save path (`saveHexEdit`,
    /// `saveLevelOverrides`, the Position/Instance/Trigger/Camera inspector
    /// "Save Edited Copy…" buttons) writes a full patched copy of the
    /// source file, which can be a genuinely large level file even for a
    /// tiny edit, real work, not a formality, so it gets the same
    /// real spinner treatment as loading. See `writeDataAsync`.
    public var isSaving = false
    /// "Visual Loading Feedback" (performance mandate, Part 4): real
    /// per-file progress during `scanAllArchives()`, `nil` when no scan
    /// is running. Updated in throttled batches (not on every single file)
    /// so a scan of thousands of files doesn't pay a MainActor hop per
    /// file just to report progress.
    public var scanProgress: (completed: Int, total: Int)?
    /// "Responsive Main Thread... allowing... cancellations" (performance
    /// mandate, Part 4): a real, working cancel path, `cancelScan()`
    /// cancels this exact task, and `scanAllArchives`'s own loop checks
    /// `Task.isCancelled` between archives to actually stop starting new
    /// work rather than just discarding the result at the end.
    private var scanTask: Task<Void, Never>?

    public func cancelScan() {
        scanTask?.cancel()
    }
    public var lastError: String? {
        didSet { if let lastError { engineLog.append(EngineLogEntry(message: lastError, isError: true)) } }
    }
    /// Rolling log backing the Engine Console drawer. Unbounded growth isn't
    /// a real concern for a desktop inspection session (thousands of
    /// entries is still a trivially small array of small structs), so this
    /// doesn't truncate.
    public private(set) var engineLog: [EngineLogEntry] = []

    public func clearEngineLog() {
        engineLog.removeAll()
    }

    // MARK: - Memory Card Inspector (blueprint 7.3)

    /// Performance/architecture fix (audit): storage moved to
    /// `MemoryCardInspectorStore`, see its own doc comment. This stays a
    /// plain get/set facade so every existing `workspace.memoryCardAsset`
    /// call site (read or write) keeps working completely unchanged.
    private let memoryCardInspectorStore = MemoryCardInspectorStore()
    public var memoryCardAsset: MemoryCardAsset? {
        get { memoryCardInspectorStore.asset }
        set { memoryCardInspectorStore.asset = newValue }
    }

    /// "Global Command/Search Bar" (⌘K), see `ContentView`'s `.commands`.
    public var isCommandPalettePresented = false

    /// What the main window's detail pane is currently showing. The
    /// browse-type hubs (Models/Textures/Chunks/Sound Banks/…) dock here as
    /// modules instead of opening a `.sheet` over the whole window, see
    /// `WorkspaceDetailRoute` and `DetailColumn`. Genuinely modal tasks
    /// (Game Launcher, Crate Installer, …) still use `.sheet`.
    public var workspaceDetail: WorkspaceDetailRoute = .assetPreview

    /// A completely separate document type from the `.BD`/`.RM2` workspace
    /// tree above, a PS2 memory card image has nothing to do with
    /// Twinsanity's own formats, so this doesn't touch `rootNodes` at all.
    public func openMemoryCard(url: URL) {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            memoryCardAsset = try MemoryCardParser.parse(data: data)
            statusMessage = "Loaded memory card \(url.lastPathComponent)."
        } catch {
            lastError = "Couldn't read \(url.lastPathComponent) as a PS2 memory card: \(error)"
        }
    }

    // MARK: - Disc Image Mounting (roadmap 1.4/Task 7, ISO-9660 / BIN-CUE)

    /// Extension this build recognizes well enough to be worth offering an
    /// "extract and open" action for, the same real chunk/archive/sound-
    /// bank/cross-engine extensions the regular Open panel accepts.
    nonisolated static let recognizedDiscFileExtensions: Set<String> = ["RM2", "SM2", "RMX", "SMX", "BH", "BD", "MH", "MB", "CRT", "WMP"]

    /// Real `ISO9660Entry` + the `LogicalSectorSource` to extract it from,
    /// keyed by the synthetic `ChunkNode.id` mirroring it in `rootNodes` , 
    /// lets `select(_:)` extract and open a disc-mounted file's real bytes
    /// on click, the same one-click affordance an archive entry already
    /// has, without `ChunkNode`/`ISO9660Entry` needing to know about each
    /// other. Only real file leaves are registered (never directories , 
    /// nothing to extract for those, they're just tree structure).
    private var discEntryByNodeID: [UUID: CTModels.DiscEntryHolder] = [:] {
        didSet { filterInputsGeneration += 1 }
    }
    /// In-flight reservation for `openDiscEntry`, see that function's own
    /// doc comment for the exact race this closes (two concurrent calls
    /// for the same entry, e.g. mount-time auto-open racing a sidebar
    /// click, both passing the `rootNodes`-based de-dup check because
    /// neither has appended its root yet).
    private var discEntriesCurrentlyOpening: Set<String> = []
    /// One real, not-yet-decoded clip inside a mounted WoC sound archive
    /// (`SFX.DAT`/`ATS.DAT`), keyed by the synthetic leaf `ChunkNode.id`
    /// `expandWOCSoundArchive` mints for it. Decoding all ~782 real clips
    /// up front (hundreds of MB of PCM) isn't reasonable just to populate
    /// a browsable tree -- this is the same "lazy, decode on click"
    /// pattern `discEntryByNodeID`/`expandArchiveEntry` already use for a
    /// `.BH` archive's unopened entries, just keyed to one numbered record
    /// inside an already-extracted archive file rather than a whole
    /// separate file. See `ChunkNode.isLazyLoadable` for how these leaves
    /// stay visible under "Smart File Filtering" despite having no real
    /// file extension to key off of.
    private var wocSoundClipPending: [UUID: (archiveURL: URL, entry: WOCSoundParser.Entry)] = [:]
    /// "ISO/ROM Rebuild" (roadmap 7): the source `.iso` file each mounted
    /// disc's top-level `ChunkNode.id` was actually read from, only
    /// populated for a plain `.iso` mount, never a `.bin`/`.cue` pair
    /// (`ISO9660Writer` only rebuilds a flat `.iso`; see its own doc
    /// comment for why raw-sector `.bin` framing is out of scope). Lets
    /// `replacingDiscImage` re-read the real original bytes fresh from
    /// disk rather than needing to keep a second full copy in memory
    /// alongside whatever `mountDiscImage` already mapped in.
    private var mountedDiscImageURLByRootID: [UUID: URL] = [:]

    /// Real, reported bug ("if I ejected a disc I shouldn't still see these
    /// files available"): `openDiscEntry` opens a `.BH`/`.BD` clicked from
    /// inside a mounted disc as its own, fully independent top-level root
    /// (see that function's own doc comment on why, a real, extracted
    /// local copy, not a live view into the disc). `closeRoot`'s own doc
    /// comment deliberately keeps that independence for closing *that*
    /// archive specifically (closing one unrelated thing shouldn't cascade
    /// into another). But "Eject" is different: a user ejecting a disc
    /// means "I'm done with everything from this disc," and an archive
    /// they only ever reached *by browsing into it* is exactly that, left
    /// behind, it reads as "ejecting didn't actually do anything." Tracked
    /// here (disc root ID -> every independent root `openDiscEntry` ever
    /// spawned from browsing into it) purely so `unmountDiscImage` can
    /// close them too; nothing else consults this.
    private var childRootIDsByDiscRootID: [UUID: Set<UUID>] = [:]

    /// "Native ISO & BIN/CUE Disc Image Mounting" (roadmap 1.4/Task 7),
    /// merged directly into the main sidebar tree, not a separate modal
    /// browser. Mounts a real `.iso`, or a `.bin`/`.cue` pair, reads its
    /// real ISO-9660 root directory, and adds it to `rootNodes` as a real
    /// top-level entry the user can browse, filter, and search exactly
    /// like any other opened archive, clicking a recognized file extracts
    /// and opens it through the same real `open(url:)` pipeline a file
    /// picked from a regular folder uses. `.mappedIfSafe` so mounting a
    /// multi-gigabyte disc image doesn't materialize the whole thing in
    /// RAM up front, only the sectors `ISO9660Reader` actually touches
    /// (the volume descriptor, directory extents, and whichever file gets
    /// opened) get paged in.
    /// `onComplete` fires once `rootNodes` genuinely reflects the fresh
    /// mount (right after `autoOpenDiscArchives`, the very last thing the
    /// success path does), success only, never on a failed mount (nothing
    /// changed for a caller to react to). Exists for
    /// `refreshingMountedDiscImage`'s own level-viewer-reopen fix: firing
    /// that reopen logic immediately after *calling* this function (rather
    /// than after its real, `Task.detached` work actually finishes) was a
    /// genuine race, `rootNodes` could still be the stale pre-remount
    /// tree at that point, so the "find this node's fresh successor"
    /// search would fail. `nil` default keeps every other call site
    /// unchanged.
    public func mountDiscImage(url: URL, onComplete: (() -> Void)? = nil) {
        // Real, reported bug: mounting a disc never closed a previously-
        // mounted one, every call (including the every-launch auto-
        // remount) just appended another "Disc" root, so the sidebar
        // accumulated one duplicate entry per mount instead of showing the
        // one active disc a user actually expects. Closed synchronously,
        // up front, so the old entry disappears the moment "Mount" is
        // clicked rather than lingering until the new disc finishes
        // reading.
        closeMountedDiscImages()

        // The `.iso`/`.bin` reads below are `.mappedIfSafe` (lazily paged),
        // but the `.cue` sheet read and the full `ISO9660Reader` directory
        // walk are not, and used to run synchronously on MainActor -- real
        // blocking risk on a slow/network volume or a disc with many
        // entries. `LogicalSectorSource` is `Sendable`, so the whole read +
        // directory-walk moves to a background Task; only the final
        // `self`-touching bookkeeping hops back.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let source: any LogicalSectorSource
                switch url.pathExtension.uppercased() {
                case "ISO":
                    source = PlainISOSource(data: try Data(contentsOf: url, options: .mappedIfSafe))
                case "CUE":
                    let cue = try CueSheetParser.parse(contents: try String(contentsOf: url, encoding: .ascii))
                    let binURL = url.deletingLastPathComponent().appendingPathComponent(cue.binFileName)
                    let binData = try Data(contentsOf: binURL, options: .mappedIfSafe)
                    source = BinCueLogicalSource(binData: binData, framing: cue.framing)
                case "BIN":
                    let cueURL = url.deletingPathExtension().appendingPathExtension("cue")
                    guard FileManager.default.fileExists(atPath: cueURL.path) else {
                        await MainActor.run { [weak self] in
                            self?.lastError = "\(url.lastPathComponent) has no matching .cue file alongside it, a raw .bin's sector framing can't be determined without one."
                        }
                        return
                    }
                    let cue = try CueSheetParser.parse(contents: try String(contentsOf: cueURL, encoding: .ascii))
                    let binData = try Data(contentsOf: url, options: .mappedIfSafe)
                    source = BinCueLogicalSource(binData: binData, framing: cue.framing)
                default:
                    await MainActor.run { [weak self] in
                        self?.lastError = "\(url.lastPathComponent) isn't a recognized disc image, choose a .iso, .bin, or .cue file."
                    }
                    return
                }
                let root = try ISO9660Reader.readRootDirectory(from: source)
                let node = Self.buildDiscNode(from: root, isRoot: true)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.registerDiscEntries(root, node: node, source: source)
                    // "Remember the last mounted disc", success case only
                    // (we're already past every `throw`/early-return above),
                    // and every recognized format, not just `.iso` (unlike
                    // `discImageURL` just below, which stays `.iso`-only).
                    self.lastMountedDiscImageURL = url
                    if url.pathExtension.uppercased() == "ISO" {
                        self.mountedDiscImageURLByRootID[node.id] = url
                        // "Quick Launch should use the disc I've already
                        // mounted, not make me pick it again": Direct
                        // Boot/Launch (`GameLauncherView`) only supports a
                        // plain .iso (see `ISO9660Writer`'s own doc
                        // comment, no raw .bin/.cue), which is exactly
                        // the case this branch is already in. A user only
                        // has one disc actively mounted/relevant at a
                        // time in practice, so defaulting to whichever one
                        // they just mounted is the real fix, manually
                        // choosing a different image afterward still
                        // overrides this until the next mount.
                        self.discImageURL = url
                    }
                    self.rootNodes.append(node)
                    self.statusMessage = "Mounted \(url.lastPathComponent), \(self.discEntryByNodeID.count) recognized file(s) available to open."
                    // "Auto-open the disc's own archive on mount", real,
                    // requested behavior: previously, every `.BH`/`.BD`
                    // pair sat in the mounted disc's tree as a plain file
                    // until the user explicitly clicked into it, nothing
                    // else in the sidebar (Levels Hub, the Scenery tab, a
                    // sidebar click on a level inside it) is reachable
                    // before that one click happens. Opening every `.BH`
                    // found in the freshly-mounted tree right here means
                    // there's exactly one, single, canonical open per
                    // mount, on a background task (`openDiscEntry` itself
                    // no longer blocks the main actor for the read, see
                    // its own doc comment), rather than leaving it to
                    // whenever the user happens to click into it.
                    self.autoOpenDiscArchives(in: node)
                    onComplete?()
                }
            } catch let error as CueSheetParser.ParseError {
                await MainActor.run { [weak self] in
                    self?.lastError = "Couldn't read \(url.lastPathComponent)'s cue sheet: \(error)"
                }
            } catch is ISO9660Error {
                await MainActor.run { [weak self] in
                    self?.lastError = "\(url.lastPathComponent) doesn't look like a real ISO-9660 disc image (no valid volume descriptor found)."
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "Couldn't mount \(url.lastPathComponent): \(error)"
                }
            }
        }
    }

    /// Real, reported bug this fixes: after any save that overwrites a
    /// mounted disc's own file in place (Quick Launch's default "Save
    /// changes to this ISO", the quit-time autosave), a plain
    /// `mountDiscImage(url:)` refreshes the disc's own top-level tree, but
    /// an archive the user had *already* browsed into from inside it
    /// (clicking `CRASH.BH`, which `openDiscEntry` opens as its own
    /// independent root, see `closeMountedDiscImages`'s own doc comment
    /// for why `mountDiscImage` deliberately never touches those) stays
    /// exactly as stale as before: `openDiscEntry`'s own de-duplication
    /// check (matching by bare filename against every already-open root)
    /// means re-selecting that same disc leaf afterward is a silent no-op,
    /// never re-extracting the now-updated bytes. This is the real
    /// mechanism behind "I edited and saved, closed the Chunk Viewer,
    /// reopened the same level, and saw no edits and only scenery", the
    /// sidebar kept leading back into the exact same pre-edit archive root
    /// that was opened before the save, since nothing ever closed it.
    ///
    /// Closes every top-level root whose bare filename matches a real,
    /// recognized leaf file inside `url`'s own disc tree (`CRASH.BH` and
    /// its siblings, found via `ChunkNode.isLazyLoadable`, the same flag
    /// `openDiscEntry`/`select(_:)` use to recognize an openable disc
    /// leaf) before remounting, so the archive root gets genuinely
    /// re-extracted and re-opened, fresh, the next time the user clicks
    /// back into it, not just the disc's own outer tree.
    ///
    /// Real bug found verifying this against a real archive (not a
    /// synthetic fixture): an already-opened archive root's own
    /// `displayName` isn't the bare filename, `open(url:)`'s archive
    /// path appends a real, user-facing entry count (`"CRASH.BH  (697
    /// files)"`, see the literal format string where that's built), so a
    /// naive `(displayName as NSString).lastPathComponent` on *that*
    /// string just returns it unchanged (no `/` to split on), never
    /// matching the disc tree's own clean `"CRASH.BH"`. `bareRootName(_:)`
    /// strips that suffix (splitting on the same `"  ("` separator the
    /// format string uses) before comparing. `openDiscEntry`'s own
    /// same-shaped de-dup check has this identical gap, a separate,
    /// related bug worth fixing on its own, not addressed here.
    public func refreshingMountedDiscImage(url: URL) {
        if let discRootID = mountedDiscImageURLByRootID.first(where: { $0.value.standardizedFileURL == url.standardizedFileURL })?.key,
           let discRoot = rootNodes.first(where: { $0.id == discRootID }) {
            var recognizedLeafNames: Set<String> = []
            func collectRecognizedLeafNames(_ node: ChunkNode) {
                if node.isLazyLoadable { recognizedLeafNames.insert(Self.bareRootName(node.displayName)) }
                for child in node.children { collectRecognizedLeafNames(child) }
            }
            collectRecognizedLeafNames(discRoot)
            let staleRoots = rootNodes.filter { root in
                root.id != discRootID && recognizedLeafNames.contains(Self.bareRootName(root.displayName))
            }
            for staleRoot in staleRoots { closeRoot(staleRoot) }
        }
        // Real, reported bug: this remount gives every open Instance/
        // Trigger/Camera/scenery `ChunkNode` a fresh identity (a genuinely
        // new object per node, `rootNodes` rebuilt from scratch), but an
        // already-open Level Viewer window's `LevelViewerContext` is a
        // frozen `let` snapshot from whenever it was opened, still holding
        // the *old* nodes. `findFileRoot`'s `===` reference-identity walk
        // can never match those old nodes against the new tree, so
        // `canSaveEdits` starts returning false for every node in that
        // window, "Play"/"Save" go permanently disabled, and the Scenery
        // tab's placement menu (which needs its own stale `sceneryNode` to
        // resolve) goes missing entirely. Both were real, reported
        // symptoms of this one root cause, surfacing right after "Rebuild
        // All Collision" (whose own save routes through here) even though
        // the window never closed. Fire-and-forget re-opens the same level
        // against the fresh tree, `LevelViewerWindowHost`'s `.id(context.id)`
        // already treats a new `LevelViewerContext` as a brand-new window
        // (built for switching levels, see its own doc comment), which is
        // exactly what's needed here too: a completely fresh `ChunkNode`
        // tree and renderer, not a patch applied to the stale one in place.
        // Captured *before* `mountDiscImage`, `levelViewerContext` itself
        // is never touched by mounting, only `rootNodes` is, so there's no
        // race in reading it now; the race this fixes is the *other* half
        // (see `mountDiscImage(url:onComplete:)`'s own doc comment for
        // why the reopen has to wait for its real completion, not fire
        // right after this call returns).
        guard let current = levelViewerContext else {
            mountDiscImage(url: url)
            return
        }
        mountDiscImage(url: url) { [weak self] in
            Task { @MainActor in
                await self?.reopeningLevelViewerAfterRemount(current)
            }
        }
    }

    /// See `refreshingMountedDiscImage`'s own doc comment for why this
    /// exists. Finds `previous.sceneryNode`'s real successor in the
    /// freshly-rebuilt `rootNodes`, same "match by bare file name" the
    /// remount above already uses to recognize a stale root as the *same*
    /// file, since the node's own identity is exactly what just changed , 
    /// then reopens the level through the normal `openLevelViewer` path,
    /// which replaces `levelViewerContext` with a fresh one built entirely
    /// from the new tree. `previous.scenery` is reused as-is: a plain,
    /// already-decoded value (not a `ChunkNode`), so its own field values
    /// are still correct, a collision-rebuild-triggered remount never
    /// changes scenery placement data, only collision bytes. Leaves the
    /// window exactly as stale as before (rather than closing it) when no
    /// successor is found, since that's a strictly rarer case (the file
    /// genuinely disappeared from the disc) this fix isn't targeting.
    private func reopeningLevelViewerAfterRemount(_ previous: LevelViewerContext) async {
        // `previous.sceneryNode` itself is a deeply-nested `SceneryData`
        // record, not a file, after a remount, its *enclosing* `.sm2`/
        // `.smx` file comes back as an unexpanded placeholder
        // (`autoOpenDiscArchives` only re-opens the archive's own top-
        // level file *listing*, same as any fresh archive open, see
        // `expandArchiveEntry`'s own doc comment for why a file's actual
        // contents need their own explicit expand), so searching for that
        // exact deep node by identity never succeeds until the file is
        // expanded again. `previous.scenery.chunkName` is the one piece
        // of `LevelViewerContext` that survives a remount unchanged and
        // names the real archive entry (`ChunkNode` carries no parent
        // pointer to walk up from `sceneryNode` itself, see
        // `seedLookupCaches`'s own doc comment on why), used here to
        // re-find that same file, expand it if needed, then re-resolve
        // its own real scenery node inside. `mountDiscImage`'s own
        // `onComplete` (this function's one caller) fires right after
        // *starting* `autoOpenDiscArchives`, not after it finishes, so
        // this also has to retry until that archive listing itself shows
        // up at all.
        let candidateFileNames = Set(["sm2", "smx"].map { "\(previous.scenery.chunkName).\($0)".lowercased() })
        func findFileNode(in nodes: [ChunkNode]) -> (node: ChunkNode, rootID: UUID)? {
            func recurse(_ node: ChunkNode, rootID: UUID) -> (node: ChunkNode, rootID: UUID)? {
                if candidateFileNames.contains(node.displayName.lowercased()) { return (node, rootID) }
                for child in node.children {
                    if let found = recurse(child, rootID: rootID) { return found }
                }
                return nil
            }
            for root in nodes {
                if let found = recurse(root, rootID: root.id) { return found }
            }
            return nil
        }

        var match: (node: ChunkNode, rootID: UUID)?
        for _ in 0..<300 {
            match = findFileNode(in: rootNodes)
            if match != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let match else {
            AppLog.rendering.debug("[RemountReopenDiag] no successor file found for chunkName=\(previous.scenery.chunkName, privacy: .public), leaving levelViewerContext as-is")
            return
        }
        if match.node.children.isEmpty {
            await expandArchiveEntry(match.node, rootID: match.rootID)
        }
        // `expandArchiveEntry` replaces the node it expands with a fresh
        // identity, re-find rather than reuse `match.node`.
        guard let expandedMatch = findFileNode(in: rootNodes), let sceneryNode = Self.firstSceneryNode(in: expandedMatch.node) else {
            AppLog.rendering.debug("[RemountReopenDiag] expanded \(previous.scenery.chunkName, privacy: .public) but found no real scenery node inside it, leaving levelViewerContext as-is")
            return
        }
        await openLevelViewer(for: previous.scenery, node: sceneryNode)
    }

    /// Strips a top-level root's own display embellishments (an archive's
    /// `"  (N files)"` entry-count suffix; any directory path down to the
    /// last component) down to the bare filename it was actually opened
    /// from, so two differently-*displayed* roots for the same real file
    /// (a disc tree's clean `"CRASH.BH"` vs. an already-opened archive's
    /// `"CRASH.BH  (697 files)"`) compare equal.
    private nonisolated static func bareRootName(_ displayName: String) -> String {
        let withoutCountSuffix = displayName.components(separatedBy: "  (").first ?? displayName
        return (withoutCountSuffix as NSString).lastPathComponent.lowercased()
    }

    /// Removes every currently-mounted disc image root via `closeRoot(_:)` , 
    /// so `mountDiscImage` can start clean instead of stacking a new "Disc"
    /// root on top of the old one. Scoped to exactly what disc-mounting
    /// itself owns: a `.BH`/`.rm2`/etc. the user separately opened by
    /// clicking into a mounted disc's entry becomes its own independent
    /// top-level root (see `openDiscEntry`'s own doc comment), not closed
    /// here (used by `mountDiscImage`'s own "start clean" reset, where
    /// reaching into an unrelated, independently-opened archive would be
    /// a real surprise). `unmountDiscImage` (the user-facing "Eject") does
    /// close those too, see its own doc comment for why that case is
    /// different, via `childRootIDsByDiscRootID`, not by changing what
    /// this function itself reaches into.
    private func closeMountedDiscImages() {
        for rootID in mountedDiscImageURLByRootID.keys {
            guard let root = rootNodes.first(where: { $0.id == rootID }) else { continue }
            closeRoot(root)
        }
    }

    /// Public "Eject" for the unified source menu, closes whatever disc is
    /// mounted and forgets it as the auto-remount target, so it doesn't
    /// silently come back on next launch after the user deliberately
    /// ejected it.
    ///
    /// Real, reported bug: ejecting left every archive the user had opened
    /// by browsing *into* that disc (see `childRootIDsByDiscRootID`'s own
    /// doc comment) sitting right there in the sidebar afterward, fully
    /// readable, "if I ejected a disc I shouldn't still see these files
    /// available." Those are closed first, before the disc root itself
    /// (`closeRoot` on an already-closed child is a harmless no-op, but
    /// ordering it this way means the disc root's own bookkeeping isn't
    /// gone yet while `childRootIDsByDiscRootID` is still being read).
    public func unmountDiscImage() {
        for discRootID in mountedDiscImageURLByRootID.keys {
            guard let childRootIDs = childRootIDsByDiscRootID[discRootID] else { continue }
            for childRootID in childRootIDs {
                guard let childRoot = rootNodes.first(where: { $0.id == childRootID }) else { continue }
                closeRoot(childRoot)
            }
        }
        closeMountedDiscImages()
        lastMountedDiscImageURL = nil
    }

    /// Closes any top-level entry in `rootNodes`, a loose opened file, an
    /// archive index, or a mounted disc, cleaning up every piece of
    /// per-root bookkeeping keyed by it or one of its descendants
    /// (`rawFileBytesByRootID`, `archiveIndexByRootID`,
    /// `mountedDiscImageURLByRootID`, `discEntryByNodeID`, `fileRootCache`),
    /// not just removing the sidebar node. Real, reported gap: nothing in
    /// this app could close *anything* that had been opened, the only
    /// existing removal logic was `closeMountedDiscImages`' own disc-only
    /// bookkeeping cleanup, duplicated here as the one general version both
    /// that and the sidebar's own "Close" action use.
    ///
    /// Deliberately doesn't reach into a *different* top-level root just
    /// because it was originally opened by clicking into `root`'s own tree
    /// (e.g. a `.BH` archive expanded from inside a mounted disc becomes its
    /// own separate root, see `openDiscEntry`'s doc comment): those are
    /// independent entries in `rootNodes` a user can close on their own.
    public func closeRoot(_ root: ChunkNode) {
        let nodeIDs = Self.collectingNodeIDs(in: root)
        let nodeIDSet = Set(nodeIDs)
        for nodeID in nodeIDs {
            discEntryByNodeID.removeValue(forKey: nodeID)
            rawFileBytesByRootID.removeValue(forKey: nodeID)
            looseFileURLByRootID.removeValue(forKey: nodeID)
            fileRootCache.removeValue(forKey: nodeID)
        }
        archiveIndexByRootID.removeValue(forKey: root.id)
        mountedDiscImageURLByRootID.removeValue(forKey: root.id)
        // Keeps `childRootIDsByDiscRootID` honest regardless of *which*
        // side of the relationship just closed: the disc root itself
        // (removed wholesale) or one of the independent archives it was
        // tracking (removed from whichever disc's set still names it).
        childRootIDsByDiscRootID.removeValue(forKey: root.id)
        for discRootID in childRootIDsByDiscRootID.keys {
            childRootIDsByDiscRootID[discRootID]?.remove(root.id)
        }
        removingHubContributions(forRootID: root.id)
        if let selectedNode, nodeIDSet.contains(selectedNode.id) {
            self.selectedNode = nil
        }
        rootNodes.removeAll { $0.id == root.id }
    }

    private nonisolated static func collectingNodeIDs(in node: ChunkNode) -> [UUID] {
        [node.id] + node.children.flatMap { collectingNodeIDs(in: $0) }
    }

    /// Mirrors one `ISO9660Entry` (and, recursively, its children) into a
    /// real `ChunkNode` so the sidebar's existing `OutlineGroup`/filter/
    /// search machinery, all built around `ChunkNode`, renders it with
    /// zero special-casing. `sectionType` stays `.null` (same as an
    /// unexpanded archive-index entry): a disc entry isn't chunk-headered
    /// data itself, just a directory listing.
    private nonisolated static func buildDiscNode(from entry: ISO9660Entry, isRoot: Bool) -> ChunkNode {
        // A disc file's own name never ends in `.RM2`/`.SM2`, those live
        // packed *inside* `CRASH.BH`/`CRASH.BD`, invisible to the ISO's own
        // directory listing, so `looksLikeChunkFileName` alone never
        // matches anything here, and every disc leaf (`CRASH.BH` included)
        // silently vanished under "Smart File Filtering"'s default pruning
        // before this was wired up. `recognizedDiscFileExtensions` existed
        // for exactly this and was simply never consulted, a real bug,
        // not a design choice: mounting a disc image showed nothing at all.
        let ext = (entry.name as NSString).pathExtension.uppercased()
        let node = ChunkNode(
            recordID: 0,
            sectionType: .null,
            displayName: isRoot ? "\(entry.name.isEmpty ? "Disc" : entry.name)" : entry.name,
            byteSize: Int(entry.size),
            fileOffset: Int(entry.lba),
            isLazyLoadable: !entry.isDirectory && recognizedDiscFileExtensions.contains(ext)
        )
        node.children = entry.children
            .sorted { $0.name < $1.name }
            .map { buildDiscNode(from: $0, isRoot: false) }
        return node
    }

    /// Populates `discEntryByNodeID` for every real (non-directory) entry
    /// in this mounted disc's mirrored tree, walked separately from
    /// `buildDiscNode` since that one's `nonisolated static` (safe to call
    /// off the main actor if ever needed) while this mutates `@MainActor`
    /// state.
    private func registerDiscEntries(_ entry: ISO9660Entry, node: ChunkNode, source: any LogicalSectorSource) {
        if !entry.isDirectory {
            discEntryByNodeID[node.id] = CTModels.DiscEntryHolder(entry: entry, source: source)
        }
        let sortedChildren = entry.children.sorted { $0.name < $1.name }
        for (childEntry, childNode) in zip(sortedChildren, node.children) {
            registerDiscEntries(childEntry, node: childNode, source: source)
        }
    }

    /// "ISO/ROM Rebuild" (roadmap 7): whether `node` is a disc-mounted file
    /// this build can actually replace, real disc entry, and mounted from
    /// a plain `.iso` (not `.bin`/`.cue`; see `mountedDiscImageURLByRootID`'s
    /// doc comment).
    public func canReplaceDiscFile(_ node: ChunkNode) -> Bool {
        guard discEntryByNodeID[node.id] != nil, let root = topLevelRoot(containing: node, in: rootNodes) else { return false }
        return mountedDiscImageURLByRootID[root.id] != nil
    }

    /// Re-reads the disc's real original `.iso` bytes fresh from disk (so
    /// this never depends on whatever `mountDiscImage` may have mapped in
    /// staying resident) and hands them to `ISO9660Writer` to replace
    /// `node`'s contents with `newData`. Returns the complete new image,
    /// ready to save, the original file on disk is never modified.
    /// `nil` (with `lastError` set) if `node` isn't a replaceable disc
    /// entry (see `canReplaceDiscFile`) or the rebuild itself fails.
    public func replacingDiscImage(afterReplacing node: ChunkNode, with newData: Data) async -> Data? {
        guard let holder = discEntryByNodeID[node.id], let entry = holder.entry as? ISO9660Entry else {
            lastError = "This isn't a recognized disc-mounted file."
            return nil
        }
        guard let root = topLevelRoot(containing: node, in: rootNodes), let imageURL = mountedDiscImageURLByRootID[root.id] else {
            lastError = "This file's disc image was mounted from a .bin/.cue pair, rebuilding a raw-sector image isn't supported yet, only a plain .iso."
            return nil
        }
        do {
            // The original image can be hundreds of MB to several GB (see
            // this function's own doc comment) -- both the re-read and
            // `ISO9660Writer`'s in-memory byte relocation used to run
            // synchronously right here on MainActor before this became
            // `async`; now they run in a detached Task like every other
            // heavy path in this class.
            return try await Task.detached(priority: .userInitiated) {
                let originalImage = try Data(contentsOf: imageURL)
                return try ISO9660Writer.replacingFile(entry, with: newData, in: originalImage)
            }.value
        } catch {
            lastError = "Couldn't rebuild \(imageURL.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    /// What actually happened when the quit-time prompt's "Save & Quit"
    /// tried to save the currently-open Level Viewer's pending edits back
    /// into the mounted disc image, see `savingPendingLevelViewerEditsToMountedDisc`.
    /// `verificationFailed` and `writeFailed` are kept distinct on purpose:
    /// a `verificationFailed` means the rebuilt image itself couldn't be
    /// trusted (nothing safe to write anywhere), while `writeFailed` means
    /// a genuinely *verified* image just couldn't be written back to
    /// `discImageURL` in place (disk full, permissions, …), that one still
    /// has real, valid bytes worth offering to save somewhere else instead.
    public enum LevelViewerQuitSaveOutcome {
        case noPendingEdits
        case noDiscImageConfigured
        case saved(diagnostics: [String])
        case verificationFailed(String)
        case writeFailed(verifiedData: Data, diagnostics: [String], reason: String)
        /// "Strict Size Guardrails", the rebuilt image would grow the
        /// disc more than `GameLauncher.defaultSizeGrowthWarningThreshold`
        /// (25%) over its own original size. Never written automatically , 
        /// `verifiedData` is the real, already-verified result, kept here
        /// so a caller that gets explicit confirmation to proceed anyway
        /// can call `savingPendingLevelViewerEditsToMountedDisc(allowingLargeGrowth: true)`
        /// to actually write it, the same "retry with the decision already
        /// made" shape `writeFailed`'s own caller already uses.
        case sizeThresholdExceeded(verifiedData: Data, diagnostics: [String], originalSizeBytes: Int, rebuiltSizeBytes: Int)
    }

    /// "Save Level Viewer changes before quitting", the real save behind
    /// `CTStudioApp.AppDelegate`'s quit-confirmation alert. Gathers this
    /// session's actual pending Level Viewer edits (`currentLevelViewerPendingPatchProvider`),
    /// patches the correct archive entry, and, exactly like
    /// `GameLauncherView`'s own "Save changes to this ISO" toggle
    /// (`GameLauncher.rebuildingAndVerifying`), independently re-verifies
    /// the whole rebuilt disc image before this ever overwrites the real
    /// mounted `.iso` in place. Never writes an unverified result: if the
    /// rebuild/verification itself fails, `discImageURL` is untouched.
    ///
    /// Targets `discImageURL` specifically (the same "the disc" this app's
    /// Direct Boot/Launch already treats as the one active disc image for
    /// save/launch purposes, see `GameLauncherView`), not a per-node lookup
    /// of which mounted root a given `ChunkNode` structurally lives under:
    /// `GameLauncher`'s own archive-replacement matching already works by
    /// bare entry name against the disc's real archive index, regardless of
    /// where the in-session edit's source file happened to be opened from,
    /// so this mirrors that same existing behavior rather than inventing a
    /// stricter, inconsistent rule just for quitting.
    /// "Save History, Full Version History", every in-place save (Quick
    /// Launch's own "Save changes to this ISO" toggle, and the Level
    /// Viewer's own "Save In-Place to Disc Image…") overwrites the real
    /// mounted disc image; this keeps a real, browsable trail of what it
    /// looked like before each of the last few overwrites, not just a
    /// single one-off snapshot from the start of the session. A hidden
    /// sibling directory (`.<name>-versions/`, next to the disc image
    /// itself) holds one timestamped copy per in-place save, oldest
    /// entries pruned once there are more than `maxVersionsPerDiscImage` , 
    /// disc images are hundreds of MB to a few GB each, so unbounded
    /// accumulation would quietly fill the disk; capping at a handful of
    /// the *most recent* versions is the useful trade-off (an old-enough
    /// mistake is one Quick Launch away anyway, but you always have a
    /// literal undo for whichever save just went wrong). Runs best-effort
    /// on both ends, a failed backup or a failed prune never blocks the
    /// real save it's protecting.
    public static let maxVersionsPerDiscImage = 8

    public struct DiscImageVersion: Identifiable, Equatable {
        public var id: URL { url }
        public let url: URL
        public let createdAt: Date
        public let byteSize: Int
    }

    /// The hidden sibling directory a given disc image's own versions live
    /// in, deliberately named after the disc image itself (not one shared
    /// folder for every disc ever opened) so switching between several
    /// different `.iso`s keeps each one's own history separate and
    /// trivially discoverable by just looking next to the file.
    public func versionsDirectory(for discImageURL: URL) -> URL {
        let standardized = discImageURL.standardizedFileURL
        return standardized.deletingLastPathComponent()
            .appendingPathComponent(".\(standardized.deletingPathExtension().lastPathComponent)-versions", isDirectory: true)
    }

    private static let versionTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'_'HH-mm-ss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    public func backingUpMountedDiscImageIfNeeded(url: URL) {
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else { return }
        let dir = versionsDirectory(for: standardized)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = standardized.pathExtension
        let baseName = standardized.deletingPathExtension().lastPathComponent
        var stamp = Self.versionTimestampFormatter.string(from: Date())
        var backupURL = dir.appendingPathComponent(ext.isEmpty ? "\(baseName).\(stamp)" : "\(baseName).\(stamp).\(ext)")
        // Two in-place saves inside the same wall-clock second (rapid
        // successive Quick Launches) would otherwise collide on an
        // identical timestamped name, disambiguate rather than silently
        // skip the second version.
        var suffix = 2
        while FileManager.default.fileExists(atPath: backupURL.path) {
            stamp = "\(Self.versionTimestampFormatter.string(from: Date()))-\(suffix)"
            backupURL = dir.appendingPathComponent(ext.isEmpty ? "\(baseName).\(stamp)" : "\(baseName).\(stamp).\(ext)")
            suffix += 1
        }
        try? FileManager.default.copyItem(at: standardized, to: backupURL)
        pruningOldVersions(in: dir, keepingMost: Self.maxVersionsPerDiscImage)
    }

    private func pruningOldVersions(in dir: URL, keepingMost limit: Int) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = items.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
        for stale in sorted.dropFirst(limit) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// Every currently-kept version for `discImageURL`, newest first, the
    /// real listing `DiscImageVersionHistoryView` presents so the user can
    /// see and restore from any of them, not just whatever backup happened
    /// to land most recently.
    public func listDiscImageVersions(for discImageURL: URL) -> [DiscImageVersion] {
        let dir = versionsDirectory(for: discImageURL)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }
        return items.compactMap { url -> DiscImageVersion? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return DiscImageVersion(url: url, createdAt: values.contentModificationDate ?? .distantPast, byteSize: values.fileSize ?? 0)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public enum DiscImageVersionRestoreError: Error, CustomStringConvertible {
        case sourceMissing
        public var description: String {
            switch self {
            case .sourceMissing: return "That version no longer exists on disk."
            }
        }
    }

    /// Restores `version` over `discImageURL` in place, the live disc
    /// image's *current* state is itself backed up first (via the same
    /// `backingUpMountedDiscImageIfNeeded` every other in-place overwrite
    /// goes through), so restoring an older version is itself undoable
    /// rather than a one-way trip that could lose whatever was live a
    /// moment ago.
    ///
    /// Real edge case this guards against: if `version` happens to be the
    /// *oldest* currently-kept version, backing up the live disc image
    /// first (which adds one more version and can trigger pruning back
    /// down to `maxVersionsPerDiscImage`) could otherwise prune `version`
    /// itself out from under this call, right before it gets read, a
    /// restore that fails purely because of its own bookkeeping. Reading
    /// `version`'s bytes into memory up front, before any backup/prune
    /// happens, avoids that regardless of where `version` ranks.
    public func restoringDiscImageVersion(_ version: DiscImageVersion, to discImageURL: URL) throws {
        guard FileManager.default.fileExists(atPath: version.url.path) else { throw DiscImageVersionRestoreError.sourceMissing }
        let restoredBytes = try Data(contentsOf: version.url, options: .mappedIfSafe)
        backingUpMountedDiscImageIfNeeded(url: discImageURL)
        let standardized = discImageURL.standardizedFileURL
        try restoredBytes.write(to: standardized)
        refreshingMountedDiscImage(url: standardized)
    }

    /// `allowingLargeGrowth`: `false` (the default) means a rebuild that
    /// exceeds `GameLauncher.defaultSizeGrowthWarningThreshold` returns
    /// `.sizeThresholdExceeded` instead of writing anything, the caller
    /// (`CTStudioApp.AppDelegate.saveAndTerminate`) shows a real
    /// confirmation alert and, only on an explicit "Save Anyway," calls
    /// this again with `true` to actually write the already-verified
    /// bytes. Never skips the check silently: this app has no "background,
    /// no user present" quit path that writes real disc bytes without a
    /// human explicitly seeing this exact confirmation first.
    public func savingPendingLevelViewerEditsToMountedDisc(allowingLargeGrowth: Bool = false) async -> LevelViewerQuitSaveOutcome {
        // Same precedence as `hasPendingLevelViewerEdits`: an open window's
        // live answer (even "nothing pending") wins over a stashed snapshot
        // from a since-closed session.
        let patch: LevelViewerPendingPatch?
        if let currentLevelViewerPendingPatchProvider {
            patch = currentLevelViewerPendingPatchProvider()
        } else {
            patch = pendingLevelViewerPatchSnapshot
        }
        guard let patch else { return .noPendingEdits }
        guard let isoURL = discImageURL else { return .noDiscImageConfigured }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TwinsanityStudioQuitSave", isDirectory: true)
        let result: GameLauncher.RebuildResult
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try LevelViewerDiscAutosave.rebuildingAndVerifying(patch: patch, isoURL: isoURL, scratchDirectory: scratch)
            }.value
        } catch {
            return .verificationFailed("\(error)")
        }
        if !allowingLargeGrowth, result.exceedsSizeGrowthThreshold() {
            return .sizeThresholdExceeded(verifiedData: result.data, diagnostics: result.diagnostics, originalSizeBytes: result.originalSizeBytes, rebuiltSizeBytes: result.data.count)
        }
        do {
            backingUpMountedDiscImageIfNeeded(url: isoURL)
            // Real, serious bug this fixes: a bare `Data.write(to:)` here
            // (unlike `GameLauncherView.buildAndLaunch`'s `saveInPlace`
            // branch, which already uses `GameLauncher.writingVerified`)
            // never confirmed the file on disk actually matches what was
            // built. `ISO9660Writer`'s own doc comments already document
            // real, measured Foundation bugs around the ~2GB mark for this
            // exact class of large-buffer operation, real evidence: a
            // save through this exact path once left a mounted disc image
            // silently truncated to exactly 2,147,483,647 bytes (2^31 - 1,
            // the signed 32-bit boundary) with no error at all, only
            // discovered by manually inspecting the file afterward.
            // `writingVerified` re-reads the file's real on-disk size and
            // throws rather than reporting success when it doesn't match
            //, turning a silent, destructive corruption into the loud,
            // safe `.writeFailed` this function already has a real handler
            // for below.
            try GameLauncher.writingVerified(result.data, to: isoURL)
            pendingLevelViewerPatchSnapshot = nil
            // Same fix as `GameLauncherView.buildAndLaunch`'s `saveInPlace`
            // branch, and the same real reason: this writes fresh bytes
            // over the mounted disc's own file, but nothing else ever
            // refreshes the in-memory snapshot `mountDiscImage` captured
            // at mount time. This call only runs during the quit
            // confirmation flow (see its one caller), so the practical
            // payoff is smaller than the Quick Launch case -- but it's
            // cheap, and correct regardless of whether quitting actually
            // proceeds right after.
            refreshingMountedDiscImage(url: isoURL)
            return .saved(diagnostics: result.diagnostics)
        } catch {
            return .writeFailed(verifiedData: result.data, diagnostics: result.diagnostics, reason: "\(error.localizedDescription)")
        }
    }

    /// The top-level entry in `rootNodes` whose subtree actually contains
    /// `target`, unlike `findFileRoot` (which looks specifically for an
    /// RM2/SM2-shaped Graphics/Code file root and wouldn't recognize a
    /// disc-mounted node's shape at all), this is a plain ancestor lookup
    /// that works for any node in the sidebar tree.
    private func topLevelRoot(containing target: ChunkNode, in topLevelNodes: [ChunkNode]) -> ChunkNode? {
        if let cached = topLevelRootCache[target.id] { return cached }
        func contains(_ node: ChunkNode) -> Bool {
            node === target || node.children.contains(where: contains)
        }
        let result = topLevelNodes.first(where: contains)
        topLevelRootCache[target.id] = result
        return result
    }

    /// Extracts `entry`'s real bytes from `source`, writes them to a temp
    /// file, and hands off to the *existing* `open(url:)`, reusing the
    /// one real, already-tested ingestion path rather than a second
    /// parallel one for disc-mounted files.
    ///
    /// A real, reported bug: for a `.BH` (or `.BD`) entry specifically,
    /// this used to extract *only* the one file clicked. `open(url:)`'s
    /// `.BH` handling (`BDArchiveParser.readIndex`) parses the index fine
    /// from that alone, real archive entries showed up correctly, but
    /// every entry's own data lives in the sibling `.BD`, which
    /// `counterpartURL(for:)` expects to find *alongside* the `.BH` in the
    /// same directory. Since only the `.BH` was ever extracted, every
    /// attempt to actually read an entry's bytes ("Parse") failed with
    /// "CRASH.BD ... no such file", the sibling was never there to find.
    /// Now the real sibling is located in the disc's own tree (same
    /// pairing `siblingActorEntryName`/`registerDiscEntries` already use
    /// elsewhere) and extracted into the same temp directory first.
    /// One stable location for `openDiscEntry`'s own extraction, see that
    /// function's own doc comment for why this must never be a fresh
    /// `UUID()` per call.
    private nonisolated static let discEntryScratchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TwinsanityStudioDiscEntry")

    /// Finds every real `.BH` leaf reachable from `node` (a freshly-mounted
    /// disc's own root, or any subtree of it) and opens each one via the
    /// same `openDiscEntry` a manual click already uses, see
    /// `mountDiscImage`'s own call site for why this runs automatically
    /// now instead of waiting for a click. Each open is independently
    /// awaited in its own `Task` (not sequenced one-after-another): a disc
    /// with more than one archive shouldn't make the second one wait on
    /// the first one's extraction, and `openDiscEntry`'s own de-duplication
    /// guard already makes calling it more than once for the same entry
    /// harmless.
    private func autoOpenDiscArchives(in node: ChunkNode) {
        if (node.displayName as NSString).pathExtension.caseInsensitiveCompare("BH") == .orderedSame,
           let holder = discEntryByNodeID[node.id],
           let entry = holder.entry as? ISO9660Entry,
           let source = holder.source as? any LogicalSectorSource {
            Task { [weak self] in await self?.openDiscEntry(entry, source: source, node: node) }
        }
        for child in node.children {
            autoOpenDiscArchives(in: child)
        }
    }

    private func openDiscEntry(_ entry: ISO9660Entry, source: any LogicalSectorSource, node: ChunkNode) async {
        // Real, reported bug (severe): this had no de-duplication at all , 
        // every single click/tap on the same disc-mounted entry re-extracted
        // and re-opened it as a brand-new root, appended to `rootNodes`
        // without ever checking whether that same entry was already open.
        // Combined with anything that could re-trigger this handler
        // rapidly for the same node, that's an unbounded pile of duplicate
        // trees for what the user sees as "the same file", exactly the
        // "mounting the same image twice keeps coming up with new files to
        // parse" / "tapping this parses me unlimited times" reports. A
        // bare-filename match (same normalization `LevelDisplayNameMatching`
        // already established elsewhere) against every already-open root's
        // own `displayName` is enough: if it's already there, there's
        // nothing left to do.
        //
        // Real, reported bug (severe, found investigating "auto-parse
        // finishes, then the Level Viewer shows scenery only, no Instance/
        // Trigger/Camera data"): an already-open archive root's own
        // `displayName` isn't the bare filename, `load(_:)`'s archive path
        // appends a real entry count (`"CRASH.BH  (697 files)"`), so
        // `($0.displayName as NSString).lastPathComponent` on *that* string
        // just returns it unchanged (no `/` to split on), never matching
        // this disc leaf's own clean `bareName`. Every re-selection of the
        // same disc-mounted `.BH` after its first open silently failed this
        // check and extracted+opened a brand-new duplicate root, the
        // scan-populated one stayed exactly where it was, but any later
        // sibling `.sm2`->`.rm2` lookup keyed by archive root could land on
        // either root depending on tree-walk order, and the fresh duplicate
        // is always unscanned. `bareRootName(_:)` (already used by
        // `refreshingMountedDiscImage` for this identical comparison) strips
        // the "  (N files)" suffix before comparing, same as `mountDiscImage`
        // was already fixed to do for the disc root itself.
        let bareName = Self.bareRootName((entry.name as NSString).lastPathComponent)
        if rootNodes.contains(where: { Self.bareRootName($0.displayName) == bareName }) {
            return
        }
        // Real, reported bug (severe, race condition): the check above only
        // catches an already-*completed* open, `rootNodes` isn't updated
        // until `open(url:)` runs at the very end of this function, after
        // the `await` on the extraction task below suspends this call and
        // yields the main actor. `@MainActor` serializes synchronous code,
        // not separate `Task { }` bodies across a suspension point, so two
        // calls to this function for the same entry, e.g. `mountDiscImage`
        // auto-opening a disc's own `.BH` (`autoOpenDiscArchives`) racing a
        // user's own sidebar click on that identical entry moments later
        // (`select(_:)`), can both reach this line, both see `rootNodes`
        // still missing the not-yet-appended root, and both proceed to
        // extract and open a duplicate. This is the same "scenery only, no
        // Instance/Trigger/Camera data" symptom as every duplicate-root bug
        // already fixed above, just reached through a race instead of a
        // stale-string comparison. A synchronous reservation, checked and
        // inserted in the same actor-isolated statement before any `await`,
        // closes the gap the `rootNodes` check alone can't: the second
        // caller sees its own entry already reserved and bails out
        // immediately, regardless of how far the first call has gotten.
        guard discEntriesCurrentlyOpening.insert(bareName).inserted else {
            return
        }
        defer { discEntriesCurrentlyOpening.remove(bareName) }
        // Real, reported bug: every byte of this read-then-write , 
        // including the sibling `.BD` extraction below, routinely the
        // *whole* ~900MB main archive, used to run synchronously right
        // here on the main actor. Fine for a deliberate click (a brief,
        // expected wait), but freezes the whole app for however long that
        // takes; genuinely bad if this is ever triggered automatically
        // (e.g. auto-opening the disc's own archive right at mount time)
        // rather than from a single user click. The disc-entry lookups
        // themselves (`discArchiveSibling`, which needs live `rootNodes`)
        // stay on the main actor; only the actual byte read/write moves to
        // a detached task, matching every other heavy-I/O path in this
        // class (`mountDiscImage`, `expandArchiveEntry`).
        let sibling = discArchiveSibling(of: entry, node: node)
        let siblingName = sibling?.entry.name
        isLoading = true
        let extraction: Result<(tempURL: URL, siblingReadFailed: Bool), Error> = await Task.detached(priority: .userInitiated) {
            guard let data = ISO9660Reader.readFile(entry, from: source) else {
                return .failure(CocoaError(.fileReadUnknown))
            }
            // Real, reported bug: a fresh `UUID()`-named directory here,
            // never cleaned up afterward, meant every single click into a
            // mounted disc's `.BH`/`.BD` archive pair left a brand-new,
            // permanent copy behind, dozens of them piling up over a
            // normal editing session, observed as tens of gigabytes of
            // orphaned scratch data. One stable, reused location instead:
            // cleared right before each extraction, so there's only ever
            // the one currently-open disc entry's worth of scratch data on
            // disk, not one per click ever made this session.
            let tempDirectory = Self.discEntryScratchDirectory
            let tempURL = tempDirectory.appendingPathComponent(entry.name)
            do {
                try? FileManager.default.removeItem(at: tempDirectory)
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                try data.write(to: tempURL)
                if let (siblingEntry, siblingSource) = sibling {
                    guard let siblingData = ISO9660Reader.readFile(siblingEntry, from: siblingSource) else {
                        return .success((tempURL, true))
                    }
                    try siblingData.write(to: tempDirectory.appendingPathComponent(siblingEntry.name))
                }
                return .success((tempURL, false))
            } catch {
                return .failure(error)
            }
        }.value
        isLoading = false

        switch extraction {
        case .success(let (tempURL, siblingReadFailed)):
            if siblingReadFailed, let siblingName {
                lastError = "Couldn't read \(siblingName)'s real bytes from the mounted image, \(entry.name) will only show its index, not real entry data."
            }
            // See `childRootIDsByDiscRootID`'s own doc comment, recorded
            // *before* `open(url:)` so a disc root resolved from `node`
            // (still live in `rootNodes` at this point) is captured even
            // though this whole function already awaited once above; the
            // before/after `rootNodes` diff is how the newly-created root
            // itself gets identified, since `open(url:)` returns nothing.
            let discRootID = topLevelRoot(containing: node, in: rootNodes)?.id
            let rootIDsBeforeOpen = Set(rootNodes.map(\.id))
            open(url: tempURL)
            if let discRootID {
                let newRootIDs = Set(rootNodes.map(\.id)).subtracting(rootIDsBeforeOpen)
                if !newRootIDs.isEmpty {
                    childRootIDsByDiscRootID[discRootID, default: []].formUnion(newRootIDs)
                }
            }
        case .failure:
            lastError = "Couldn't extract \(entry.name) from the mounted image."
        }
    }

    /// `entry`'s real `.BH`/`.BD` counterpart, if `entry` is one half of an
    /// archive pair and its sibling is also a real disc-mounted leaf in
    /// the same directory, `nil` for every other kind of disc entry
    /// (nothing else needs a paired extraction).
    private func discArchiveSibling(of entry: ISO9660Entry, node: ChunkNode) -> (entry: ISO9660Entry, source: any LogicalSectorSource)? {
        let ext = (entry.name as NSString).pathExtension
        let siblingExt: String
        switch ext {
        case "BH": siblingExt = "BD"
        case "bh": siblingExt = "bd"
        case "BD": siblingExt = "BH"
        case "bd": siblingExt = "bh"
        default: return nil
        }
        let siblingName = (entry.name as NSString).deletingPathExtension + "." + siblingExt
        guard let parentNode = parent(of: node, inAnyOf: rootNodes) else { return nil }
        guard let siblingNode = parentNode.children.first(where: { $0.displayName.caseInsensitiveCompare(siblingName) == .orderedSame }) else { return nil }
        guard let siblingHolder = discEntryByNodeID[siblingNode.id],
              let siblingEntry = siblingHolder.entry as? ISO9660Entry,
              let siblingSource = siblingHolder.source as? any LogicalSectorSource
        else { return nil }
        return (siblingEntry, siblingSource)
    }

    /// Non-nil presents the Model Viewer sheet (see `ContentView`).
    public var modelViewerAsset: ResolvedModelAsset?
    /// Non-nil presents the Collision Viewer sheet (see `ContentView`).
    public var collisionViewerMesh: CollisionMesh?
    /// Non-nil presents the Level Viewer sheet (see `ContentView`).
    public var levelViewerContext: LevelViewerContext?
    /// Real, measured performance bug ("opened it and closed it and it
    /// lagged again"): closing the Chunk Viewer and reopening the same (or
    /// a different) level starts a brand-new `openLevelViewer` call while
    /// the previous one may not have finished yet, nothing ever stopped
    /// that. Real captured timing showed two overlapping calls each taking
    /// 4-8 SECONDS instead of the normal 0.06-0.3s, entirely from
    /// contending with each other (and the continuously-running 20fps
    /// render loop) for the main actor, the camera/render-loop slowdown
    /// the user saw was a *symptom* of this, not its own separate bug (the
    /// same capture showed `draw(in:)` itself was fine, ~16-20fps, ~10ms
    /// encode, whenever only one open was in flight). Bumped at the start
    /// of every `openLevelViewer` call; a call whose generation has been
    /// superseded by a newer one bails out at its next checkpoint instead
    /// of continuing to burn CPU/main-actor time toward a result nobody
    /// will ever see, and, separately, never overwrites `levelViewerContext`
    /// with a stale result once superseded.
    private var levelViewerOpenGeneration = 0
    /// Code review finding: `levelViewerOpenGeneration` above stops a
    /// superseded call from *corrupting* final state, but nothing stopped
    /// a second `openLevelViewer` from being *started* in the first place , 
    /// every one of the three UI entry points (`LevelsHubView`'s card grid,
    /// `SceneryInspectorView`'s button, the sidebar reclick branch in
    /// `select` below) could each independently kick off their own call
    /// with no shared signal that one was already in flight, so every
    /// superseded call still fully ran its expensive background work
    /// before being discarded. `true` for as long as *any* `openLevelViewer`
    /// call is in flight, in a shared place instead of three separate local
    /// `@State` flags that don't know about each other, every entry point
    /// can now disable its own "open" affordance off this one value.
    /// Backed by a count (not a bare bool) since overlapping calls are
    /// still possible (the generation guard above tolerates them, it just
    /// discards a stale result), the flag needs to stay `true` until the
    /// *last* one finishes.
    public var isOpeningLevelViewer: Bool { openLevelViewerInFlightCount > 0 }
    private var openLevelViewerInFlightCount = 0
    /// A live query for "wherever the 3D camera currently is", set by
    /// `LevelViewerWindow` while it's open, cleared on close. The
    /// reference editor's `PositionEditor`/`AIPositionEditor`/
    /// `AIPathEditor`'s own "Copy Viewer Pos" buttons read the *currently
    /// open* 3D viewer's camera at the moment of the click, not a
    /// continuously-mirrored value, this closure indirection matches
    /// that same "ask right now" semantics without `PositionInspectorView`
    /// (a plain sidebar sheet, not necessarily backed by an open Level
    /// Viewer) needing a direct reference to whichever `LevelViewerRenderer`
    /// happens to be alive. `nil` when no Level Viewer is open, or when
    /// the one that's open belongs to a different file than the position
    /// being edited, this build doesn't try to disambiguate multiple
    /// simultaneously-open viewers, matching the reference tool's own
    /// single-viewer-at-a-time design.
    public var currentViewerCameraPositionProvider: (() -> SIMD3<Float>?)?
    /// "Quit-time Level Viewer autosave prompt" (app-lifecycle sweep): set
    /// by `LevelViewerWindow` while it's open (same lifetime/pattern as
    /// `currentViewerCameraPositionProvider` immediately above), `nil` when
    /// no Level Viewer is open. Gives app-level code (the quit hook in
    /// `CTStudioApp.AppDelegate`) a real, live answer to "does the
    /// currently-open Level Viewer have anything unsaved" without needing a
    /// direct reference to that (transient, struct) View or its renderer.
    /// Deliberately scoped to exactly this one source of pending edits , 
    /// see `hasPendingLevelViewerEdits`'s own doc comment for why this
    /// doesn't attempt to cover every other editor in the app.
    public var currentLevelViewerDirtyProvider: (() -> Bool)?
    /// The companion to `currentLevelViewerDirtyProvider`: when non-`nil`,
    /// actually building the real patch that a save would write, the same
    /// `LevelViewerWindow.computingPendingOverridePatch()` logic "Save Chunk
    /// Overrides…"/"Quick Launch…" already use, packaged as
    /// `LevelViewerPendingPatch` so it can cross from that transient View
    /// onto this long-lived view model. Returns `nil` if, by the time it's
    /// actually called, there's nothing pending after all (matches
    /// `computingPendingOverridePatch()`'s own "nil means no edits" contract).
    public var currentLevelViewerPendingPatchProvider: (() -> LevelViewerPendingPatch?)?
    /// Materialized fallback for `currentLevelViewerPendingPatchProvider`:
    /// real, reported bug, closing just the Level Viewer window (an
    /// entirely ordinary thing to do before continuing other work, long
    /// before actually quitting the app) deallocates its `LevelViewerRenderer`
    /// (a plain `@State` owned by that transient View, see
    /// `LevelViewerWindow`), which the two providers above only capture
    /// *weakly*. The moment that window closed, `hasPendingLevelViewerEdits`
    /// silently went back to `false` and the quit-time "unsaved changes"
    /// prompt never fired again, pending edits vanished with no warning at
    /// all. `LevelViewerWindow.onDisappear` now calls the live provider one
    /// last time, while its renderer is still alive, and stashes the result
    /// here before tearing the live providers down, so quitting later still
    /// has something real to ask about. Cleared once those edits are
    /// actually saved (`savingPendingLevelViewerEditsToMountedDisc`); left
    /// alone if a *different* Level Viewer session opens and closes with no
    /// edits of its own (see `hasPendingLevelViewerEdits`'s precedence).
    public var pendingLevelViewerPatchSnapshot: LevelViewerPendingPatch?
    /// True when the currently-open Level Viewer (if any) has real pending
    /// edits that haven't been saved anywhere yet. This is honest about its
    /// own scope: it answers for the Level Viewer specifically (position/
    /// rotation changes, new/deleted instances, AI waypoint edits, see
    /// `LevelViewerRenderer.hasPendingEdits`), not for every other editor
    /// in this app (Recipe Book, Shader Graph Editor, sound/texture
    /// inspectors, PTC Sheets, Agent Lab, …), each of which tracks its own
    /// separate pending-edit state this pass deliberately does not unify
    /// into one signal, that's real, separate future work.
    ///
    /// Prefers the *live* provider whenever a Level Viewer window is
    /// actually open, including a live "no, nothing pending" answer from
    /// it, and only consults `pendingLevelViewerPatchSnapshot` when no
    /// window is open at all, so a since-closed session's stashed edits
    /// never mask a currently-open window's own honest answer.
    public var hasPendingLevelViewerEdits: Bool {
        if let currentLevelViewerDirtyProvider { return currentLevelViewerDirtyProvider() }
        return pendingLevelViewerPatchSnapshot != nil
    }
    /// Every RigidModel/Skeleton successfully resolved (mesh + textures, and
    /// skeleton + animations where rigged) across every scanned file , 
    /// populated automatically as archives are scanned, so browsing models
    /// never requires manually parsing/resolving a specific chunk first.
    public var modelsHub: [ResolvedModelAsset] = []
    public var isModelsHubPresented = false
    /// Real, reported performance bug: `modelsHub`/`orphanedContent`/
    /// `texturesHub`/`levelsHub` are only ever *appended* to (a fresh
    /// archive scan, a cache hit on remount), nothing ever removed a
    /// root's own earlier contribution first. A workflow that repeats
    /// "edit, save (which re-mounts the disc), scan/re-open the same
    /// archive again", Quick Launch's own "Save changes to this ISO", or
    /// just re-opening the same level after any save, kept its *same*
    /// archive's hundreds of resolved models/textures piling up as full
    /// duplicates on every single cycle, with nothing ever bounding it:
    /// real, measured "extreme performance issues" the more times a user
    /// saved and came back to keep editing, not a one-time cost. Tracks
    /// exactly which hub entries (`Identifiable`, so by `id`) came from
    /// which root, so `removingHubContributions(forRootID:)` can strip a
    /// root's own prior entries before it contributes fresh ones again, and
    /// `closeRoot` can strip them for good when the root itself closes.
    private var hubEntryIDsByRootID: [UUID: (models: Set<UUID>, orphans: Set<UUID>, textures: Set<UUID>, levels: Set<UUID>)] = [:]

    /// Removes whatever `rootID` previously contributed to `modelsHub`/
    /// `orphanedContent`/`texturesHub`/`levelsHub` (a no-op if it never
    /// contributed anything), called immediately before that same root
    /// contributes fresh results again, so a re-scan/re-open *replaces*
    /// its own prior entries instead of duplicating them; also called from
    /// `closeRoot` so a closed root's contribution doesn't linger forever.
    private func removingHubContributions(forRootID rootID: UUID) {
        guard let previous = hubEntryIDsByRootID.removeValue(forKey: rootID) else { return }
        if !previous.models.isEmpty { modelsHub.removeAll { previous.models.contains($0.id) } }
        if !previous.orphans.isEmpty { orphanedContent.removeAll { previous.orphans.contains($0.id) } }
        if !previous.textures.isEmpty { texturesHub.removeAll { previous.textures.contains($0.id) } }
        if !previous.levels.isEmpty { levelsHub.removeAll { previous.levels.contains($0.id) } }
    }

    /// Records `rootID`'s freshly-appended contribution (called right after
    /// appending its results into the hub arrays) so a *later*
    /// `removingHubContributions(forRootID:)`, the next time this same
    /// root contributes again, or when it closes, knows exactly which
    /// entries to remove.
    private func recordingHubContribution(forRootID rootID: UUID, models: [ResolvedModelAsset], orphans: [OrphanedAsset], textures: [TextureHubEntry], levels: [LevelHubEntry]) {
        guard !models.isEmpty || !orphans.isEmpty || !textures.isEmpty || !levels.isEmpty else { return }
        hubEntryIDsByRootID[rootID] = (Set(models.map(\.id)), Set(orphans.map(\.id)), Set(textures.map(\.id)), Set(levels.map(\.id)))
    }
    /// "Global Thumbnails": every `Instance.objectID` this session has
    /// ever successfully resolved to real geometry in *any* opened level,
    /// keyed by that `objectID`, grows every time `placeModeContent`'s
    /// Forge Palette resolves one (see `recordGlobalObjectThumbnail`), so
    /// an object seen once in level A still shows its real thumbnail (and
    /// counts as "available") when browsing the palette in level B, even
    /// though B's own file has no geometry for it. Deliberately session-
    /// only, not persisted to `ScanCache` or eagerly built by scanning
    /// every archive up front, `objectID -> GameObject -> mesh` isn't
    /// data any existing scan pass already computes (unlike `modelsHub`,
    /// which resolves `RigidModel`/`Skeleton` records directly by their
    /// own on-disk ID), and eagerly resolving every real `GameObject` in
    /// every scanned file just to pre-fill this would risk the same
    /// scan-time memory/perf cost class the codebase already hit once
    /// with over-eager `ScanCache` persistence. Grows for free instead,
    /// piggybacking on resolution work the palette was doing anyway.
    public private(set) var globalObjectThumbnails: [UInt16: ResolvedModelAsset] = [:]
    /// "Cross-Level Forge Placement": the byte-level counterpart to
    /// `globalObjectThumbnails`, see `cachingCrossLevelGameObjectSourceIfSkinnedCharacter`'s
    /// own doc comment for how this gets populated and why it can be a
    /// strict subset of `globalObjectThumbnails`'s own keys (a rigid,
    /// `modelLinks`-only resolution has a thumbnail but no entry here).
    public private(set) var globalObjectGameObjectSources: [UInt16: CrossLevelGameObjectSource] = [:]
    /// Performance fix (audit): `globalObjectThumbnails` used to have no
    /// cap at all, every distinct `objectID` the Forge Palette ever
    /// resolved, across *every* level browsed in the whole session, stayed
    /// resident forever (each entry holds a full decoded mesh + texture/mip
    /// data, not just a thumbnail-sized preview). Bounded FIFO eviction
    /// here, same shape as `ModelViewerRenderer.BoundedGPUCache`, oldest-
    /// recorded objectID evicted first once the cap is hit. 256 is
    /// generous relative to how many *distinct* object types a real
    /// session's worth of Forge Palette browsing actually touches, while
    /// still giving this a real, finite ceiling instead of "however long
    /// until the app quits."
    private static let maxGlobalObjectThumbnails = 256
    private var globalObjectThumbnailInsertionOrder: [UInt16] = []

    /// Records a real, already-resolved object so later Forge Palette
    /// views (in a different level) can show its thumbnail too. Never
    /// overwrites an existing entry, first successful resolution is as
    /// good as any other for a thumbnail, and re-storing the same
    /// (mesh+texture-carrying) value on every re-render would be pure
    /// waste.
    public func recordGlobalObjectThumbnail(objectID: UInt16, asset: ResolvedModelAsset) {
        guard globalObjectThumbnails[objectID] == nil else { return }
        globalObjectThumbnailInsertionOrder.append(objectID)
        if globalObjectThumbnailInsertionOrder.count > Self.maxGlobalObjectThumbnails {
            let evicted = globalObjectThumbnailInsertionOrder.removeFirst()
            globalObjectThumbnails.removeValue(forKey: evicted)
            // Keep in sync, see this property's own doc comment on why
            // it's a strict subset of `globalObjectThumbnails`'s keys.
            globalObjectGameObjectSources.removeValue(forKey: evicted)
        }
        globalObjectThumbnails[objectID] = asset
    }
    /// "Textures Hub" (QoL sweep), every decoded texture across every
    /// scanned file, populated alongside `modelsHub` the same way.
    public var texturesHub: [TextureHubEntry] = []
    public var isTexturesHubPresented = false
    /// "Cross-Engine Texture Variant": every real, decoded texture from a
    /// user-loaded Wrath of Cortex `.GSC` level (typically `CRATES.GSC`),
    /// offered as a candidate texture override for a Twinsanity crate's
    /// own real, working UVs, see `ResolvedModelAsset.
    /// applyingTextureOverride(_:)`'s own doc comment for why this
    /// sidesteps WoC's still-undecoded per-vertex UV data entirely
    /// (Twinsanity's own UVs do the wrapping; only the pixel data comes
    /// from WoC). Empty until the user explicitly loads a `.GSC` file , 
    /// this build never guesses which WoC texture "is" a given crate
    /// type, since that correspondence isn't decoded data, just a real
    /// picker over real, honestly-labeled textures.
    public var wocCrateTextureLibrary: [TextureHubEntry] = []

    /// Loads every real, decoded texture from a real Wrath of Cortex
    /// `.GSC` file (RNC-decompressed if needed, same real pipeline
    /// `WOCLevelLoader.load` already uses for the sidebar's WoC level
    /// tree) into `wocCrateTextureLibrary`. Appends to (doesn't replace)
    /// any textures already loaded from a previous file, de-duplicated by
    /// real pixel content so loading the same file twice, or two files
    /// that happen to share a texture, doesn't create visible
    /// duplicates in the picker.
    public func loadWOCCrateTextureLibrary(from url: URL) {
        // `WOCLevelLoader.load`'s own doc comment: "Synchronous and
        // potentially slow (RNC decompression of a multi-megabyte file) --
        // callers should run this off the main actor." Every other caller
        // already does; this one used to run the read, decompress, and
        // parse directly on MainActor. Signature/call site are unchanged
        // (still a plain, non-async `func`) -- only the work inside moves
        // to a background Task, same shape as `openAsMonkeyBall` above.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let raw = try Data(contentsOf: url)
                let bytes = [UInt8](raw)
                let containerBytes = RNCDecompressor.isRNCStream(bytes) ? Data(try RNCDecompressor.decompress(bytes, verifyCRC: true)) : raw
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let gscURL = tempDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("GSC")
                try containerBytes.write(to: gscURL)
                let asset = try WOCLevelLoader.load(gscURL: gscURL, name: url.deletingPathExtension().lastPathComponent)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    var existingHashes = Set(self.wocCrateTextureLibrary.map { Data($0.texture.rgba).hashValue })
                    var added = 0
                    for decoded in asset.textures where !decoded.rgba.isEmpty {
                        let hash = Data(decoded.rgba).hashValue
                        guard !existingHashes.contains(hash) else { continue }
                        existingHashes.insert(hash)
                        let texture = TextureAsset(id: UInt32(decoded.id), width: decoded.width, height: decoded.height, pixelFormat: .rawRGBA, rgba: decoded.rgba)
                        self.wocCrateTextureLibrary.append(TextureHubEntry(sourceLabel: "\(url.lastPathComponent), texture #\(decoded.id)", texture: texture))
                        added += 1
                    }
                    self.statusMessage = "Loaded \(added) new real WoC texture(s) from \(url.lastPathComponent) (\(self.wocCrateTextureLibrary.count) total in the library)."
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "Couldn't load WoC textures from \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }
    /// "Visual Levels Hub", every decoded `SceneryData` record (one per
    /// level file that actually has an assembled scenery tree) across every
    /// parsed file, populated alongside `modelsHub`/`texturesHub`. See
    /// `LevelHubEntry`'s doc comment for why this one isn't cache-backed.
    public var levelsHub: [LevelHubEntry] = []
    public var isLevelsHubPresented = false
    /// "Audio Bank Extractor & Player" (roadmap 2.4), every standalone
    /// `.MH`/`.MB` sound bank opened this session (`MUSIC`, `ENGLISH`,
    /// ...). Loaded asynchronously (`loadSoundBankAsync`) since the real
    /// `.MB` payload can be well over 200MB, never blocks the main actor
    /// like every other heavy parse in this view model.
    public var soundBanks: [SoundBankAsset] = []
    public var isSoundBanksHubPresented = false
    public var isLoadingSoundBank = false
    /// Every standalone `.ptc`/`.psm` font/particle-sprite sheet opened
    /// this session, unlike `.MH`/`.MB` sound banks, these are small,
    /// single-file, self-contained formats (real embedded Texture/Material
    /// pairs, not a separate index+data pair), so loading is synchronous.
    /// A standalone `.ptc` file is modeled as a one-entry `TwinsPSMAsset`
    /// rather than a third array, same real on-disk shape (a
    /// `TwinsPTCEntry`), just one of them.
    public var ptcSheets: [TwinsPSMAsset] = []
    /// Every standalone `.psf` font container opened this session.
    public var fontSheets: [TwinsPSFAsset] = []
    public var isPTCSheetsHubPresented = false
    /// Every dangling reference / unreferenced record flagged by the
    /// "Scrapped Content Scanner" across every scanned file, populated
    /// alongside `modelsHub` so cut content surfaces automatically as
    /// archives are scanned, with no separate manual scan step.
    public var orphanedContent: [OrphanedAsset] = []
    public var isScrappedContentScannerPresented = false
    /// "Asset Diff & Version Comparison" (blueprint 4.3): non-nil presents
    /// the diff sheet.
    public var isAssetDiffPresented = false
    /// "Offline Mod Package Manager (.Crate Hub)" (roadmap 3.3): presents
    /// `ModCrateInspectorView`. Unlike the other hubs, this isn't gated on
    /// any workspace scan state, it opens standalone `.crate` files
    /// directly, independent of whatever archive is currently loaded.
    public var isModCrateHubPresented = false
    /// "Executable Patcher", presents `ExecutablePatcherView`. Also
    /// independent of any open archive: it operates on the game's boot
    /// executable directly (`default.xbe`/PS2 binary), a file this
    /// workspace never otherwise loads.
    public var isExecutablePatcherPresented = false
    /// "Archive Repackager", presents `ArchiveRepackagerView`. Also
    /// independent of any open archive: it operates on a `.BH`/`.BD` pair
    /// the user picks directly, not anything already mounted here.
    public var isArchiveRepackagerPresented = false
    /// "Crate Installer", presents `CrateInstallerView`, the install-side
    /// counterpart to "Export as Mod Crate…": patches texture records
    /// declared by a `.crate`'s `TextureOverride_<id>` settings
    /// (`CrateTextureOverrideInstaller.install`) into a real `.BH`/`.BD`
    /// archive pair. Same "operates on files the user picks, not anything
    /// already mounted here" independence as `ArchiveRepackagerView`.
    public var isCrateInstallerPresented = false
    public var isImageMakerPresented = false

    /// A real, ready-to-build "Quick Launch" plan for whatever chunk is
    /// currently open in the Level Viewer, `startingChunkBaseName` boots
    /// straight into it, `archiveReplacements` (keyed by bare filename,
    /// e.g. `"beach.rm2"`) carries this session's own real pending edits,
    /// computed the same way "Save Level Overrides…" already computes them.
    /// Assembled by `LevelViewerWindow` right before presenting
    /// `GameLauncherView`, not by `WorkspaceViewModel` itself, it has no
    /// visibility into a Level Viewer's live `renderer` state.
    public struct GameLauncherContext {
        public var summary: String
        public var startingChunkBaseName: String
        public var archiveReplacements: [String: Data]

        public init(summary: String, startingChunkBaseName: String, archiveReplacements: [String: Data]) {
            self.summary = summary
            self.startingChunkBaseName = startingChunkBaseName
            self.archiveReplacements = archiveReplacements
        }
    }

    /// "Direct Boot/Launch", presents `GameLauncherView`. `gameLauncherContext`
    /// is set (to a real, non-nil chunk-launch plan) right before presenting
    /// for a contextual "Quick Launch" from the Level Viewer, and left `nil`
    /// for the global "Play in PCSX2…" toolbar entry, same nil-means-
    /// global-scope convention `typeFilter` already uses.
    public var isGameLauncherPresented = false
    public var gameLauncherContext: GameLauncherContext?

    private var archiveIndexByRootID: [UUID: ArchiveIndex] = [:]
    /// Correctness fix (real, reported bug: opening a level intermittently
    /// showed real Scenery but zero Instance/Trigger/Camera markers, or
    /// placeholder objects, on an otherwise-normal load, not just the
    /// already-fixed "wrong archive root" / "stale cross-window" cases
    /// `siblingActorFileRoot`'s own doc comment already covers). Keyed by
    /// the still-unexpanded placeholder's own `id`. `expandArchiveEntry`
    /// has 4 real call sites that can each reach the *same* not-yet-
    /// expanded placeholder independently, the sibling auto-pull-in right
    /// inside `expandArchiveEntry` itself, and `siblingActorFileRoot`'s own
    /// on-demand expand, in particular, both do a "still bare?" check then
    /// expand, with no coordination between them. Two concurrent expansions
    /// of the *same* node both parse and build their own `replacement`
    /// `ChunkNode`, but only the one that finishes first actually lands in
    /// `rootNodes`, `replacingDescendant`'s `===` search for the original
    /// placeholder silently no-ops for whichever call runs second, since
    /// its own `node` reference no longer matches anything live in the
    /// tree by the time it applies its own replacement. Callers that
    /// re-fetch from `rootNodes` afterward (as `siblingActorFileRoot`
    /// itself does) still land on the correct, real result either way , 
    /// but this is real wasted duplicate parsing regardless, and any
    /// caller anywhere in this class that instead trusted its own
    /// already-in-hand node reference post-expansion (rather than
    /// re-fetching) could observe the *losing* call's still-technically-
    /// valid-but-orphaned replacement, or a race window where the checked-
    /// then-acted-on placeholder looks unexpanded to a second caller for
    /// longer than it should. Coordinating through one in-flight task per
    /// node, the same "a second caller awaits the first's real result
    /// instead of starting its own redundant one" shape
    /// `loadSharedDefaultAssetIndexIfNeeded` already uses for the shared
    /// `Default.rm2` index, removes the whole race, not just its
    /// currently-understood symptoms.
    private var inFlightArchiveEntryExpansions: [UUID: Task<Void, Never>] = [:]
    /// "No More Placeholder Squares": the real game's shared object
    /// resource (`Startup/Default.rm2`, confirmed against the actual
    /// archive, see `AssetResolver.resolveInstanceObject`'s doc comment),
    /// loaded once and reused for every subsequent Instance resolution in
    /// this workspace rather than re-parsed per level. Caching the `Task`
    /// itself (not just its eventual result) means a second Level Viewer
    /// opened while the first load is still in flight awaits the same load
    /// instead of racing it -- a boolean "already attempted" flag set
    /// before the `await` used to let a concurrent second call see the
    /// flag already true and return `nil` prematurely, before the real
    /// result ever landed.
    private var sharedDefaultAssetIndexTask: Task<GraphicsAssetIndex?, Never>?
    /// "Real Flags for Forge-Placed Objects": same one-load-shared-forever
    /// caching as `sharedDefaultAssetIndexTask`, for `Startup/Default.rm2`'s
    /// own `InstanceTemplate`/`InstanceTemplateDemo` records instead of its
    /// `GraphicsAssetIndex`, see `FileRecordBundle.instanceTemplateProperties`'s
    /// own doc comment for what this feeds.
    private var sharedDefaultInstanceTemplatePropertiesTask: Task<[UInt16: UInt32], Never>?
    /// "Forge Palette anywhere": one real level `.rm2`/`.rmx` archive
    /// entry's own parsed `GraphicsAssetIndex`, keyed by `"<archive
    /// rootID>|<entry name>"`, the exact same "cache the `Task` itself, not
    /// just its eventual result" pattern as `sharedDefaultAssetIndexTask`
    /// immediately above, generalized from the one shared `Default.rm2` to
    /// any level entry `resolvingObjectIDAcrossAllLevels` visits. A second
    /// concurrent lookup against a level whose parse is already in flight
    /// (the same level can appear as a candidate for two different object
    /// IDs searched around the same time) awaits the same `Task` instead of
    /// re-parsing, and a level already fully parsed this session is never
    /// re-parsed again for a later object ID.
    private var levelAssetIndexTaskByKey: [String: Task<GraphicsAssetIndex?, Never>] = [:]
    /// "Forge Palette anywhere": every `Instance.objectID` this session has
    /// confirmed resolves to real geometry in *no* level on this disc , 
    /// see `resolvingObjectIDAcrossAllLevels`'s doc comment. Real, permanent
    /// examples exist (`ALTEARTH_CORE_HOLOGRAPHIC_SPAWNER` #986,
    /// `ALTEARTH_CORE_LASER_ROTOGUN_TARGET` #1016, both carry
    /// `AssetResolver.resolveInstanceObject`'s real `65535` "no value"
    /// sentinel, so no level can ever resolve them). Not `private` so
    /// `WorkspaceViewModelTests` can assert the negative cache actually
    /// populates without needing a real mounted archive to prove a search
    /// stops early on a repeat lookup.
    private(set) var confirmedUnresolvableObjectIDs: Set<UInt16> = []
    /// Raw file bytes for standalone-opened `.RM2`/`.SM2` files, keyed by
    /// their root `ChunkNode.id`, the "Editing GUI" write path's source
    /// material for patching an edited record back in at its known offset.
    /// Deliberately scoped to standalone files only (not archive-nested
    /// entries) for now; see `WorldPlacementWriter`'s doc comment.
    /// Performance fix (audit): these bytes are load-bearing for
    /// correctness (the record-patch write-back path reads them at exact
    /// byte offsets, see the doc comment above), so unlike the GPU/asset
    /// caches elsewhere in this app, entries here can *never* be silently
    /// evicted while their root is still open without breaking the save
    /// path for that file. The real gap the audit found isn't "no cap" , 
    /// it's "no visibility": a session with many large loose files open at
    /// once grows this indefinitely with no signal to the user. This
    /// `didSet` gives them that signal (once, not on every edit) instead
    /// of silently discarding data that's still needed.
    private var rawFileBytesByRootID: [UUID: Data] = [:] {
        didSet {
            let totalBytes = rawFileBytesByRootID.values.reduce(0) { $0 + $1.count }
            if totalBytes > Self.rawOpenFileBytesWarningThreshold {
                if !hasWarnedAboutOpenFileMemory {
                    hasWarnedAboutOpenFileMemory = true
                    let gb = Double(totalBytes) / 1_073_741_824
                    statusMessage = "You have \(String(format: "%.1f", gb)) GB of loose files open at once, close ones you're done editing to free memory."
                }
            } else {
                // Room to warn again if it climbs back over the threshold
                // after the user closes some files and reopens others.
                hasWarnedAboutOpenFileMemory = false
            }
        }
    }
    private static let rawOpenFileBytesWarningThreshold = 2_147_483_648 // 2 GB
    private var hasWarnedAboutOpenFileMemory = false

    /// Source file URL for every standalone-opened `.RM2`/`.SM2` root,
    /// keyed the same way as `rawFileBytesByRootID`, lets a loose file
    /// find its own sibling actor/scenery file by directory scan (same
    /// folder, same base name, `.sm2`<->`.rm2`) the same way "Save Chunk
    /// Overrides…" always writes them, without requiring either half to
    /// have come from a mounted archive.
    private var looseFileURLByRootID: [UUID: URL] = [:]

    // MARK: - Recent Files (QoL sweep)

    /// Performance/architecture fix (audit): storage moved to
    /// `RecentFilesStore`, see its own doc comment. Facade properties/
    /// methods below keep every existing call site (`workspace.
    /// recentFileURLs`, `workspace.clearRecentFiles()`) unchanged.
    private let recentFilesStore = RecentFilesStore()

    public var recentFileURLs: [URL] { recentFilesStore.urls }

    private func addRecentFile(_ url: URL) {
        recentFilesStore.add(url)
    }

    public func clearRecentFiles() {
        recentFilesStore.clear()
    }

    /// Performance/architecture fix (audit): the Settings-window state
    /// this used to restore inline (`accentColorChoice`, `masterDirectoryURL`,
    /// `discImageURL`, `lastMountedDiscImageURL`, `pcsx2AppURL`) is now
    /// restored by `AppSettingsStore`'s own `init()`, see that type's doc
    /// comment. `recentFilesStore`'s `init()` similarly self-restores, so
    /// this initializer only has `showRawFiles` (genuinely core state, kept
    /// on this class, see `AppSettingsStore`'s doc comment) left to do.
    public init() {
        if UserDefaults.standard.object(forKey: Self.showRawFilesDefaultsKey) != nil {
            showRawFiles = UserDefaults.standard.bool(forKey: Self.showRawFilesDefaultsKey)
        }
    }

    // MARK: - Settings (Preferences window)

    /// Performance/architecture fix (audit): storage moved to
    /// `AppSettingsStore`, see its own doc comment for what did and didn't
    /// move. `AccentColorChoice` stays a typealias here (rather than the
    /// stored properties below becoming plain forwarders to a differently-
    /// named type) so the one existing fully-qualified external reference,
    /// `WorkspaceViewModel.AccentColorChoice.allCases` in `SettingsView`,
    /// keeps compiling completely unchanged.
    public typealias AccentColorChoice = AppSettingsStore.AccentColorChoice

    private let appSettingsStore = AppSettingsStore()

    public var accentColorChoice: AccentColorChoice {
        get { appSettingsStore.accentColorChoice }
        set { appSettingsStore.accentColorChoice = newValue }
    }
    public var masterDirectoryURL: URL? {
        get { appSettingsStore.masterDirectoryURL }
        set { appSettingsStore.masterDirectoryURL = newValue }
    }
    public var discImageURL: URL? {
        get { appSettingsStore.discImageURL }
        set { appSettingsStore.discImageURL = newValue }
    }
    public var lastMountedDiscImageURL: URL? {
        get { appSettingsStore.lastMountedDiscImageURL }
        set { appSettingsStore.lastMountedDiscImageURL = newValue }
    }
    public var pcsx2AppURL: URL? {
        get { appSettingsStore.pcsx2AppURL }
        set { appSettingsStore.pcsx2AppURL = newValue }
    }
    private var hasAttemptedAutoRemount: Bool {
        get { appSettingsStore.hasAttemptedAutoRemount }
        set { appSettingsStore.hasAttemptedAutoRemount = newValue }
    }

    /// Called from `CTStudioApp`'s startup path. If a disc was mounted last
    /// session and that exact file still exists at the same path, mounts it
    /// again automatically, otherwise fails silently (clearing the now-
    /// stale persisted URL) rather than surfacing an error banner for a disc
    /// the user didn't just now ask to open.
    public func autoRemountLastDiscImageIfAvailable() {
        guard !hasAttemptedAutoRemount else { return }
        hasAttemptedAutoRemount = true
        guard let url = lastMountedDiscImageURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastMountedDiscImageURL = nil
            return
        }
        mountDiscImage(url: url)
    }

    /// "Multi-Region & Cross-Game Auto-Patcher" (roadmap 1.4): the real
    /// `SYSTEM.CNF` info detected the last time a folder was opened, `nil`
    /// until a folder open finds one, and never guessed from a filename or
    /// left over from a previous open on a different folder. See
    /// `detectRegion(inFolder:)`.
    public private(set) var detectedRegion: SystemCNFInfo?

    /// Looks for a real `SYSTEM.CNF` at `folder`'s root (case-insensitively
    ///, real disc images vary in casing) and parses it if present.
    /// Deliberately not recursive: `SYSTEM.CNF` is only ever meaningful at
    /// an actual disc/ISO root, so searching subfolders would risk
    /// matching an unrelated file and reporting a wrong region with false
    /// confidence. `static`/non-isolated (unlike the rest of this
    /// `@MainActor` class) so `open(url:)` can run it inside a
    /// `Task.detached` alongside `WorkspaceAutoDetector.scanFolder`, same
    /// reasoning as that function's own doc comment about not blocking the
    /// main actor on folder-sized disk I/O.
    private nonisolated static func detectRegionSync(inFolder folder: URL) -> SystemCNFInfo? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        guard let cnfURL = entries.first(where: { $0.lastPathComponent.uppercased() == "SYSTEM.CNF" }) else { return nil }
        guard let contents = try? String(contentsOf: cnfURL, encoding: .ascii) else { return nil }
        return SystemCNFParser.parse(contents: contents)
    }

    /// The tree the sidebar actually renders: `rootNodes` narrowed by the
    /// type filter (see `ChunkNode.filtered(byKind:)`) and then by the
    /// search text (see `ChunkNode.filtered(matching:)`), each pass keeping
    /// ancestors of any match so the result stays a navigable tree.
    public var filteredRootNodes: [ChunkNode] {
        if let cache = filteredRootNodesCache, cache.generation == filterInputsGeneration {
            return cache.result
        }
        var nodes = rootNodes
        // "Smart File Filtering": applied first, as the baseline view , 
        // undecoded/raw content (and folders that only contain it) is
        // hidden by default regardless of the type/search filters below,
        // not just when one happens to be active. Settings' Developer Mode
        // toggle (`showRawFiles`) brings it back.
        if !showRawFiles {
            nodes = nodes.compactMap { $0.prunedOfRawContent(discEntryRegistry: self.discEntryByNodeID) }
        }
        if let typeFilter {
            nodes = nodes.compactMap { $0.filtered(byKind: typeFilter) }
        }
        if !searchQuery.isEmpty {
            nodes = nodes.compactMap { $0.filtered(matching: searchQuery) }
        }
        filteredRootNodesCache = (filterInputsGeneration, nodes)
        return nodes
    }

    /// Whether any loaded archive still has `.RM2`/`.SM2`/etc. entries that
    /// haven't been parsed yet, drives the sidebar's "Scan Archive" prompt,
    /// since the type filter can only find assets inside files that have
    /// actually been decoded.
    public var hasUnscannedArchives: Bool {
        archiveIndexByRootID.keys.contains { rootID in
            guard let root = rootNodes.first(where: { $0.id == rootID }) else { return false }
            return root.children.contains { isExpandableArchiveEntry($0) }
        }
    }

    // MARK: - Ingestion

    public func open(urls: [URL]) {
        for url in urls { open(url: url) }
    }

    public func open(url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            // The folder walk itself (`WorkspaceAutoDetector.scanFolder`'s
            // recursive `FileManager.enumerator` plus a `resourceValues`
            // call per entry, and `detectRegionSync`'s own directory
            // listing) is real, scale-with-folder-size disk I/O, the same
            // "instantly crashed"-looking freeze this function's own
            // pre-existing comment below already fixed for the *parsing*
            // half (loose level files). The scan half was still running
            // inline on the main actor; moved off it here for the same
            // reason, mirroring `loadLooseLevelFilesAsync`'s
            // `Task.detached` shape.
            isScanning = true
            statusMessage = "Scanning \(url.lastPathComponent)…"
            Task.detached(priority: .userInitiated) { [weak self] in
                let region = Self.detectRegionSync(inFolder: url)
                let detected = WorkspaceAutoDetector.scanFolder(url)
                await self?.applyFolderScanResults(url: url, region: region, detected: detected)
            }
            return
        }
        // "Modular TT Engine Cross-Compatibility" (roadmap 5.3): a file
        // extension a *different* registered `EngineDriver` recognizes
        // (today, just Wrath of Cortex's `.CRT`/`.WMP`) isn't "unknown" , 
        // it's real, just not something the main sidebar tree/scan can
        // ingest directly (it's not chunk-headered, has no archive index,
        // nothing to build a `ChunkNode` tree from). Saying so explicitly,
        // with where to actually load it, beats `load(_:)`'s silent
        // `.unknown`/`.folder` no-op for a file this build genuinely does
        // understand.
        let detected = WorkspaceAutoDetector.detect(url: url)
        if detected.kind == .unknown, let driver = EngineDriverRegistry.driver(forExtension: url.pathExtension),
           case .standaloneOnly(let loadHint) = driver.ingestionCapability {
            statusMessage = "\(url.lastPathComponent) is a real \(driver.displayName) file, but this build doesn't load it into the main workspace tree, \(loadHint)"
            return
        }
        load(detected)
    }

    /// Applies the results of the off-main-actor folder scan `open(url:)`'s
    /// directory branch starts, the on-main-actor "finish up" half, same
    /// split `applyLooseLevelFileResults` uses for the loose-file parse
    /// results below.
    private func applyFolderScanResults(url: URL, region: SystemCNFInfo?, detected: [DetectedFile]) {
        isScanning = false
        detectedRegion = region
        statusMessage = "Found \(detected.count) recognizable file(s) in \(url.lastPathComponent)."
        if let detectedRegion, detectedRegion.region != .unknown {
            statusMessage += " Detected region: \(detectedRegion.region.displayName)\(detectedRegion.serial.map { " (\($0))" } ?? "")."
        }
        // "Fatal Crash on File Selection": `.archiveIndex`/`.archiveData`
        // are cheap (a header + entry-name list, not a full parse) and
        // stay on `load(_:)`'s existing synchronous path, matching
        // single-file open. `.levelResource`/`.sceneryResource` loose
        // files are each a *full* parse, potentially many of them for
        // a folder pick (an extracted mod folder, a whole disc root),
        // and running that in a plain `for` loop on the main actor
        // blocked the UI for however long all of them took combined,
        // with zero opportunity for AppKit to service events in
        // between. On this machine that's easily long enough to look
        // and feel exactly like "the app instantly crashed" even
        // though every individual parse was already safely wrapped in
        // `load(_:)`'s own `do`/`catch`, the freeze was real, not a
        // Swift-level crash, but indistinguishable from one to a user
        // watching a spinning beachball. Routed through the same
        // off-main-actor `TaskGroup` shape `scanAllArchives()` already
        // uses for exactly this reason.
        let looseLevelFiles = detected.filter { $0.kind == .levelResource || $0.kind == .sceneryResource }
        let remaining = detected.filter { $0.kind != .levelResource && $0.kind != .sceneryResource }
        for file in remaining { load(file) }
        if !looseLevelFiles.isEmpty { loadLooseLevelFilesAsync(looseLevelFiles) }
    }

    /// One parsed loose `.RM2`/`.SM2` file's full result, everything
    /// `load(_:)`'s `.levelResource`/`.sceneryResource` case already
    /// computes for a single such file, bundled so a `TaskGroup` child task
    /// can hand it back in one `Sendable` value. `nil` `node`/`data` means
    /// this file failed to parse (see `error`), still reported, never
    /// silently dropped.
    private struct LooseLevelFileResult: Sendable {
        let file: DetectedFile
        let node: ChunkNode?
        let data: Data?
        let models: [ResolvedModelAsset]
        let orphans: [OrphanedAsset]
        let textures: [TextureHubEntry]
        let levels: [LevelHubEntry]
        let error: String?
    }

    /// Parses every loose level/scenery file found by a folder scan off the
    /// main actor, fanned out across cores (same shape as
    /// `scanAllArchives`'s `TaskGroup`), then applies every result, parsed
    /// or failed, back on the main actor in one batch. A single
    /// malformed/truncated/unrelated file (a real risk when the user picks
    /// a broad folder rather than a curated one) fails on its own and
    /// reports through `lastError` alongside whatever else did load;
    /// it never aborts the rest of the batch.
    /// Single-file counterpart to `loadLooseLevelFilesAsync`, same real
    /// off-main-actor read+parse, same `LooseLevelFileResult`/
    /// `applyLooseLevelFileResults` application, just for the one file a
    /// direct `open(url:)` (not a folder scan) hands `load(_:)`. Before
    /// this, a directly-opened `.RM2`/`.SM2` was the one `.levelResource`/
    /// `.sceneryResource` path never routed through the async fix, see
    /// `load(_:)`'s own doc comment at its call site.
    /// "MonkeyBall (MB) File-Kind Detection", there's no reliable magic
    /// byte distinguishing a Super Monkey Ball Adventure `.RM2`/`.SM2` from
    /// a retail Crash Twinsanity one (both are the same underlying "nu2"
    /// engine container format); this is the closest real equivalent to
    /// automatic detection this project's reference material supports: an
    /// explicit "open as Monkey Ball" entry point, same posture
    /// `ExecutablePatcherView`'s manual `GameExecutableRevision` picker
    /// already takes for a build variant with no reliable auto-probe. Once
    /// routed through `.rm2MB`/`.sm2MB`, every previously-unreachable
    /// `SectionType.*MB` case (`RM2Parser.tier0Kind`/`tier1ChildType`) is
    /// real and taggable in the tree, not dead code.
    public func openAsMonkeyBall(url: URL) {
        let ext = url.pathExtension.uppercased()
        let fileKind: TwinsFileKind
        switch ext {
        case "RM2": fileKind = .rm2MB
        case "SM2": fileKind = .sm2MB
        default:
            lastError = "\(url.lastPathComponent): Monkey Ball opening only applies to .RM2/.SM2 files."
            return
        }
        // Real, reported bug (same class as `load(_:)`'s `.archiveIndex`
        // case): no de-duplication at all, reopening the same file "as
        // Monkey Ball" piled up a duplicate root exactly like the pre-fix
        // `.BH`/disc-mount bugs, just for this entry point instead.
        if rootNodes.contains(where: { $0.displayName == url.lastPathComponent }) {
            statusMessage = "\(url.lastPathComponent) is already open."
            return
        }
        isLoading = true
        statusMessage = "Loading \(url.lastPathComponent) as Monkey Ball…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let node = try Self.mainTreeDriver(forExtension: url.pathExtension).parseChunkFile(data: data, fileKind: fileKind, fileName: url.lastPathComponent)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.rawFileBytesByRootID[node.id] = data
                    self.rootNodes.append(node)
                    self.isLoading = false
                    self.statusMessage = "Loaded \(url.lastPathComponent) as Monkey Ball."
                    self.addRecentFile(url)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isLoading = false
                    self?.lastError = "\(url.lastPathComponent): \(error)"
                }
            }
        }
    }

    private enum PTCSheetLoadResult {
        case ptc(TwinsPSMAsset)
        case psm(TwinsPSMAsset)
        case psf(TwinsPSFAsset)
        case unrecognizedExtension
    }

    /// Performance fix (audit): `Data(contentsOf:)` + the real
    /// `TwinsPTCParser` decode (every embedded texture/material entry, for
    /// `.PSM`) used to run synchronously in `load(_:)`'s switch, directly
    /// on whatever called it, a drag-drop or File > Open action, i.e. the
    /// main actor. Same shape of fix as `loadSingleLevelFileAsync` right
    /// below: the de-dup check stays synchronous (cheap, and avoids
    /// dispatching work for a file that's already open), everything else
    /// moves to `Task.detached`.
    private func loadPTCSheetAsync(_ file: DetectedFile) {
        let baseName = file.url.deletingPathExtension().lastPathComponent
        guard !ptcSheets.contains(where: { $0.id == baseName }), !fontSheets.contains(where: { $0.id == baseName }) else {
            statusMessage = "\(file.url.lastPathComponent) is already open."
            return
        }
        isLoading = true
        statusMessage = "Loading \(file.url.lastPathComponent)…"
        let ext = file.url.pathExtension.uppercased()
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<PTCSheetLoadResult, Error>
            do {
                let data = try Data(contentsOf: file.url)
                switch ext {
                case "PTC":
                    let entry = try TwinsPTCParser.parsePTCFile(data)
                    outcome = .success(.ptc(TwinsPSMAsset(sourceLabel: baseName, entries: [entry], sourceURL: file.url)))
                case "PSM":
                    let sheet = try TwinsPTCParser.parsePSM(data, sourceLabel: baseName, sourceURL: file.url)
                    outcome = .success(.psm(sheet))
                case "PSF":
                    let font = try TwinsPTCParser.parsePSF(data, sourceLabel: baseName)
                    outcome = .success(.psf(font))
                default:
                    outcome = .success(.unrecognizedExtension)
                }
            } catch {
                outcome = .failure(error)
            }
            await self?.applyPTCSheetLoadResult(outcome, fileName: file.url.lastPathComponent)
        }
    }

    private func applyPTCSheetLoadResult(_ outcome: Result<PTCSheetLoadResult, Error>, fileName: String) {
        isLoading = false
        switch outcome {
        case .success(.ptc(let sheet)):
            ptcSheets.append(sheet)
            statusMessage = "Loaded \(fileName), 1 entry."
        case .success(.psm(let sheet)):
            ptcSheets.append(sheet)
            statusMessage = "Loaded \(fileName), \(sheet.entries.count) entries."
        case .success(.psf(let font)):
            fontSheets.append(font)
            statusMessage = "Loaded \(fileName), \(font.fontPages.count) font page(s), \(font.vectors.count) vector(s)."
        case .success(.unrecognizedExtension):
            break
        case .failure(let error):
            lastError = "\(fileName): \(error)"
        }
    }

    private func loadSingleLevelFileAsync(_ file: DetectedFile) {
        isLoading = true
        statusMessage = "Loading \(file.url.lastPathComponent)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: LooseLevelFileResult
            do {
                let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                let node = try Self.mainTreeDriver(forExtension: file.url.pathExtension).parseChunkFile(data: data, fileKind: Self.fileKind(for: file), fileName: file.url.lastPathComponent)
                let label = file.url.lastPathComponent
                let index = AssetResolver.buildIndex(fileRoot: node)
                result = LooseLevelFileResult(
                    file: file, node: node, data: data,
                    models: Self.resolveModels(index: index, sourceLabel: label),
                    orphans: AssetResolver.scanForOrphans(index: index, sourceLabel: label),
                    textures: Self.collectTextures(index: index, sourceLabel: label),
                    levels: Self.collectLevels(inFileRoot: node, sourceLabel: label),
                    error: nil
                )
            } catch {
                result = LooseLevelFileResult(file: file, node: nil, data: nil, models: [], orphans: [], textures: [], levels: [], error: "\(error)")
            }
            await self?.applyLooseLevelFileResults([result])
        }
    }

    private func loadLooseLevelFilesAsync(_ files: [DetectedFile]) {
        isLoading = true
        statusMessage = "Parsing \(files.count) level file(s)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let results = await withTaskGroup(of: LooseLevelFileResult.self) { group in
                for file in files {
                    group.addTask {
                        do {
                            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                            let node = try Self.mainTreeDriver(forExtension: file.url.pathExtension).parseChunkFile(data: data, fileKind: Self.fileKind(for: file), fileName: file.url.lastPathComponent)
                            let label = file.url.lastPathComponent
                            let index = AssetResolver.buildIndex(fileRoot: node)
                            return LooseLevelFileResult(
                                file: file, node: node, data: data,
                                models: Self.resolveModels(index: index, sourceLabel: label),
                                orphans: AssetResolver.scanForOrphans(index: index, sourceLabel: label),
                                textures: Self.collectTextures(index: index, sourceLabel: label),
                                levels: Self.collectLevels(inFileRoot: node, sourceLabel: label),
                                error: nil
                            )
                        } catch {
                            return LooseLevelFileResult(file: file, node: nil, data: nil, models: [], orphans: [], textures: [], levels: [], error: "\(error)")
                        }
                    }
                }
                var collected: [LooseLevelFileResult] = []
                collected.reserveCapacity(files.count)
                for await result in group { collected.append(result) }
                return collected
            }
            await self?.applyLooseLevelFileResults(results)
        }
    }

    private func applyLooseLevelFileResults(_ results: [LooseLevelFileResult]) {
        defer { isLoading = false }
        var loadedCount = 0
        var failedNames: [String] = []
        for result in results {
            guard let node = result.node, let data = result.data else {
                failedNames.append(result.file.url.lastPathComponent)
                lastError = "\(result.file.url.lastPathComponent): \(result.error ?? "unknown error")"
                continue
            }
            // Real, reported bug (same class as `load(_:)`'s `.archiveIndex`
            // case, which already guards this): reopening an already-open
            // loose `.RM2`/`.SM2` had no de-duplication at all, a repeat
            // drag-drop or double-click piled up a full duplicate sidebar
            // tree *and* duplicate Models/Textures/Levels Hub entries below.
            if rootNodes.contains(where: { $0.displayName == node.displayName }) {
                loadedCount += 1
                continue
            }
            rawFileBytesByRootID[node.id] = data
            looseFileURLByRootID[node.id] = result.file.url
            rootNodes.append(node)
            modelsHub.append(contentsOf: result.models)
            orphanedContent.append(contentsOf: result.orphans)
            texturesHub.append(contentsOf: result.textures)
            levelsHub.append(contentsOf: result.levels)
            addRecentFile(result.file.url)
            loadedCount += 1
        }
        statusMessage = failedNames.isEmpty
            ? "Parsed \(loadedCount) level file(s)."
            : "Parsed \(loadedCount) level file(s), \(failedNames.count) failed (see errors above)."
    }

    /// "Audio Bank Extractor & Player" (roadmap 2.4): resolves `mhURL`'s
    /// sibling `.MB` file (same directory, same base name, case-
    /// insensitive extension, real discs use `.MH`/`.MB` uppercase),
    /// reads and decodes the whole bank off the main actor, then applies
    /// the result. `mbData` is read with `.mappedIfSafe` for the same
    /// reason `.levelResource`/`.sceneryResource` already do, `MUSIC.MB`
    /// alone is over 200MB on the real disc.
    private func loadSoundBankAsync(mhURL: URL) {
        let directory = mhURL.deletingLastPathComponent()
        let baseName = mhURL.deletingPathExtension().lastPathComponent
        guard let mbURL = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first(where: { $0.deletingPathExtension().lastPathComponent == baseName && $0.pathExtension.caseInsensitiveCompare("MB") == .orderedSame })
        else {
            lastError = "\(mhURL.lastPathComponent): no matching .MB file found in the same folder."
            return
        }

        isLoadingSoundBank = true
        statusMessage = "Parsing sound bank \(baseName)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<SoundBankAsset, Error>
            do {
                let mhData = try Data(contentsOf: mhURL)
                let mbData = try Data(contentsOf: mbURL, options: .mappedIfSafe)
                let bank = try SoundBankParser.parse(mhData: mhData, mbData: mbData, sourceLabel: baseName)
                result = .success(bank)
            } catch {
                result = .failure(error)
            }
            await self?.applySoundBankResult(result, baseName: baseName)
        }
    }

    private func applySoundBankResult(_ result: Result<SoundBankAsset, Error>, baseName: String) {
        isLoadingSoundBank = false
        switch result {
        case .success(let bank):
            // Real, reported bug (same class as `load(_:)`'s `.archiveIndex`
            // case): no de-duplication, reopening the same `.MH`/`.MB`
            // pair piled up a duplicate `soundBanks` entry.
            guard !soundBanks.contains(where: { $0.id == bank.id }) else {
                statusMessage = "\(baseName) is already open."
                return
            }
            soundBanks.append(bank)
            statusMessage = "Loaded sound bank \(baseName), \(bank.entries.count) entries, \(bank.decodedCount) decoded."
        case .failure(let error):
            lastError = "\(baseName): \(error)"
        }
    }

    /// `ScanCache.load`'s `PropertyListDecoder().decode` on a previously
    /// scanned archive's cached Models/Textures Hub metadata used to run
    /// synchronously right here on MainActor, right after opening an
    /// archive index, a real blocking risk on a large, already-scanned
    /// archive (the payload is "the large flat float/byte arrays a decoded
    /// mesh/texture is mostly made of", per `ScanCachePayload`'s own doc
    /// comment) on the single most common reopen path there is. Moved to a
    /// background `Task`.
    private func applyScanCacheOrScan(bdURL: URL, fileDisplayName: String, entryCount: Int, rootID: UUID) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let cached = ScanCache.load(for: bdURL)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let cached {
                    // Real, reported performance bug: re-mounting the same
                    // disc after a save (Quick Launch's own "Save changes
                    // to this ISO") re-opens this same archive fresh, and a
                    // cache hit used to just append on top of whatever this
                    // same root had already contributed on an earlier
                    // mount, never removed. Every save-and-reopen cycle
                    // silently duplicated the whole archive's worth of
                    // resolved models/textures again. Strip this root's own
                    // prior contribution first so a re-mount replaces it
                    // instead of piling another copy on top.
                    self.removingHubContributions(forRootID: rootID)
                    self.modelsHub.append(contentsOf: cached.modelsHub)
                    self.orphanedContent.append(contentsOf: cached.orphanedContent)
                    self.texturesHub.append(contentsOf: cached.texturesHub)
                    self.recordingHubContribution(forRootID: rootID, models: cached.modelsHub, orphans: cached.orphanedContent, textures: cached.texturesHub, levels: [])
                    self.statusMessage = "Loaded \(fileDisplayName) from cache, \(cached.modelsHub.count) model(s), \(cached.texturesHub.count) texture(s) available instantly. Individual files still parse on selection; Scan Archive refreshes the cache."
                } else {
                    // Real, reported problem: auto-scanning immediately on
                    // every fresh (uncached) archive open, no user action
                    // needed, meant simply mounting a freshly-rebuilt disc
                    // image (a new/changed `.BD`, always a cache miss)
                    // silently kicked off a full, heavy parse of every level
                    // file in the archive, with no way to opt out. Scanning
                    // is real, unavoidable CPU/memory work for a large
                    // archive; that's a decision worth leaving to an
                    // explicit "Scan Archive" click (already in the sidebar,
                    // see `SidebarView.filterBar`) rather than something
                    // that just happens the moment an archive is opened.
                    self.statusMessage = "Loaded \(fileDisplayName), \(entryCount) entries. Click \"Scan Archive\" to find models/textures across the whole archive; individual files still parse on selection."
                }
            }
        }
    }

    private func load(_ file: DetectedFile) {
        // "Visual Loading Feedback": a single directly-opened .RM2/.SM2 can
        // be a full level's worth of chunk data, same as one entry out of
        // a folder scan, that path was already fixed to parse off the
        // main actor (see `loadLooseLevelFilesAsync`'s own doc comment for
        // exactly why blocking here reads as "the app crashed," not just
        // "looks busy"). Single-file open never went through that fix
        // since it calls `load(_:)` directly instead of the folder path,
        // so route these two kinds through the same real async machinery
        // here too, before the synchronous branch below even starts.
        if file.kind == .levelResource || file.kind == .sceneryResource {
            loadSingleLevelFileAsync(file)
            return
        }
        // Performance fix (audit): `.ptcSheet` (`.PTC`/`.PSM`/`.PSF`) did a
        // synchronous `Data(contentsOf:)` + real parse directly in the
        // switch below, unlike `.archiveIndex`'s sibling case, there's no
        // "this is cheap, just a header read" justification for this one
        // (`TwinsPTCParser.parsePSM` decodes every embedded texture+
        // material entry). Routed out the same way `.levelResource`/
        // `.sceneryResource` already are, just above.
        if file.kind == .ptcSheet {
            loadPTCSheetAsync(file)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            switch file.kind {
            case .archiveIndex:
                // Real, severe, reported bug: re-opening the same already-
                // loaded `.BH` (e.g. clicking its own already-open sidebar
                // entry again) had no de-duplication at all, every call
                // parsed a fresh archive index and appended a brand-new
                // root, piling up unlimited duplicate "CRASH.BH (697
                // files)" trees. Worse, only the *first* one's root ID ever
                // got registered anywhere else that matters (`.sm2`->
                // `.rm2` sibling lookups keyed by archive root, cross-level
                // scenery catalogs, etc.), so once duplicates existed,
                // which specific tree a later lookup landed on became
                // essentially random, the real cause behind "I can only
                // see scenery, no Instance/Trigger/Camera data" once this
                // had already happened a few times.
                let bareName = file.url.lastPathComponent
                if rootNodes.contains(where: { ($0.displayName as NSString).components(separatedBy: "  (").first == bareName }) {
                    statusMessage = "\(bareName) is already open."
                    return
                }
                let index = try Self.mainTreeDriver(forExtension: file.url.pathExtension).parseArchiveIndex(bhURL: file.url)
                let node = ChunkNode(
                    recordID: 0, sectionType: .null,
                    displayName: "\(file.url.lastPathComponent)  (\(index.entries.count) files)",
                    byteSize: 0, fileOffset: 0
                )
                for entry in index.entries {
                    node.children.append(ChunkNode(
                        recordID: 0, sectionType: .null, displayName: entry.name,
                        byteSize: Int(entry.size), fileOffset: Int(entry.offset)
                    ))
                }
                archiveIndexByRootID[node.id] = index
                rootNodes.append(node)

                // Real, measured performance bug: `Startup/Default.rm2` (the
                // shared crate/pickup asset data every level's Instance
                // resolution falls back to) was only ever parsed lazily, on
                // whichever level the user happened to open *first*, real
                // timing showed that one archive-read + parse + `buildIndex`
                // costing 1.3+ seconds, entirely attributed to that first
                // level even though it has nothing to do with that level's
                // own data, while every subsequent level in the same session
                // opened in under 0.06s once the shared index was warm.
                // Firing this off now, the moment the archive it lives in
                // becomes available, means it's very likely already warm by
                // the time the user actually clicks a level, same memoized
                // `loadSharedDefaultAssetIndexIfNeeded()` either way, just
                // started opportunistically instead of on the level-open
                // critical path. Fire-and-forget: failure/absence is already
                // handled (and cached) inside that function itself.
                //
                // `loadSharedDefaultInstanceTemplatePropertiesIfNeeded` does
                // its own *separate* archive-read + parse of this exact same
                // `Startup/Default.rm2` file (for its `InstanceTemplate`
                // records rather than its Graphics section), confirmed by
                // real measurement to pay the identical 1.3s cold-start cost
                // independently the first time *it* runs, even after the
                // line above was already warming the other one. Prewarming
                // both here, not just one.
                Task { [weak self] in _ = await self?.loadSharedDefaultAssetIndexIfNeeded() }
                Task { [weak self] in _ = await self?.loadSharedDefaultInstanceTemplatePropertiesIfNeeded() }

                applyScanCacheOrScan(bdURL: index.bdURL, fileDisplayName: file.url.lastPathComponent, entryCount: index.entries.count, rootID: node.id)
                addRecentFile(file.url)

            case .levelResource, .sceneryResource:
                // Unreachable, handled by the early `loadSingleLevelFileAsync`
                // return above, kept as an explicit case (not `default:`)
                // so a future new `DetectedFile.Kind` case fails to compile
                // here until it's deliberately handled one way or the other.
                break

            case .archiveData:
                statusMessage = "Drop the matching .BH file to browse \(file.url.lastPathComponent) (a .BD alone has no index)."

            case .soundBank:
                // Real `.MB` payloads run well over 200MB (`MUSIC.MB`) , 
                // `load(_:)` itself stays synchronous/non-blocking by just
                // scheduling the actual read+decode, matching this view
                // model's standing rule against blocking the main actor on
                // a heavy parse.
                loadSoundBankAsync(mhURL: file.url)

            case .ptcSheet:
                // Unreachable, routed to `loadPTCSheetAsync` above, before
                // this synchronous switch is ever entered. Kept as an
                // explicit case (not folded into `.folder, .unknown`) so a
                // future new `DetectedFile.Kind` case still fails to
                // compile here until deliberately handled, same convention
                // `load(_:)`'s own `.levelResource`/`.sceneryResource`
                // cases already use just above.
                break

            case .folder, .unknown:
                break
            }
        } catch {
            lastError = "\(file.url.lastPathComponent): \(error)"
        }
    }

    private nonisolated static func fileKind(for file: DetectedFile) -> TwinsFileKind {
        switch (file.kind, file.platform) {
        case (.levelResource, .xbox): return .rmx
        case (.levelResource, _): return .rm2
        case (.sceneryResource, .xbox): return .smx
        case (.sceneryResource, _): return .sm2
        default: return .rm2
        }
    }

    /// "Modular Driver Dispatch" (roadmap 5.3): the one real place chunk-
    /// file/archive parsing dispatches through `EngineDriver` instead of
    /// calling `RM2Parser`/`BDArchiveParser` directly, every call site
    /// below routes through this, so a real second `.mainWorkspaceTree`
    /// driver (should one ever exist) only needs its own `EngineDriver`
    /// conformance, not changes at every parse call site. Falls back to
    /// `TwinsanityEngineDriver` directly only as a defensive default , 
    /// every extension this is ever called with (RM2/SM2/RMX/SMX/BH) is
    /// already hardcoded into that driver's own `recognizedExtensions`,
    /// so the fallback is unreachable in practice, not a silent behavior
    /// change from before this refactor.
    private nonisolated static func mainTreeDriver(forExtension ext: String) -> any EngineDriver {
        EngineDriverRegistry.driver(forExtension: ext) ?? TwinsanityEngineDriver()
    }

    // MARK: - Drilling into archived RM2/SM2 files

    /// Whether `node` is an unexpanded archive entry whose name looks like a
    /// chunk file (`.RM2`/`.SM2`/`.RMX`/`.SMX`).
    public func isExpandableArchiveEntry(_ node: ChunkNode) -> Bool {
        guard node.children.isEmpty, node.payload == nil else { return false }
        return Self.isChunkFileName(node.displayName)
    }

    /// `nonisolated`: pure string logic with no dependency on view-model
    /// state, called from `scanAllArchives`'s background parsing loop , 
    /// without this it inherits `@MainActor` isolation from the enclosing
    /// type and can't be called off the main thread without a warning.
    private nonisolated static func isChunkFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.uppercased()
        return ["RM2", "SM2", "RMX", "SMX"].contains(ext)
    }

    private nonisolated static func fileKind(forEntryNamed name: String) -> TwinsFileKind {
        switch (name as NSString).pathExtension.uppercased() {
        case "RMX": return .rmx
        case "SMX": return .smx
        case "SM2": return .sm2
        default: return .rm2
        }
    }

    /// Parses every unparsed `.RM2`/`.SM2`/etc. entry across every loaded
    /// archive in the background, so the type filter (and search) can find
    /// assets no matter which file they're packed into, without this, a
    /// filter can only ever see inside files you've individually opened.
    /// Runs off the main actor since a full archive (hundreds of files) can
    /// take tens of seconds; the UI stays responsive and `isScanning` drives
    /// a progress indicator instead of freezing during the scan.
    ///
    /// Bounded, sliding-window concurrency: at most `maxConcurrent` entries'
    /// raw bytes + parse products are ever resident at once, refilled one at
    /// a time as each finishes, not "read every candidate entry's bytes for
    /// the whole archive into RAM up front, then parse," which is real
    /// memory-spike risk on a large archive (hundreds of multi-MB level
    /// files all held in memory simultaneously before a single one starts
    /// parsing). `BDArchiveReader` reuses one open file handle and isn't
    /// safe for concurrent reads from a single instance (see its own doc
    /// comment), worked around here by giving each concurrent task its own
    /// reader (an independent `FileHandle` over the same read-only `.BD`
    /// file) rather than serializing all reads through one shared instance.
    public func scanAllArchives() {
        guard !isScanning else { return }
        let targets = archiveIndexByRootID.map { ($0.key, $0.value) }
        guard !targets.isEmpty else { return }

        let totalCandidates = targets.reduce(0) { partial, pair in
            partial + pair.1.entries.filter { Self.isChunkFileName($0.name) }.count
        }
        guard totalCandidates > 0 else { return }

        isScanning = true
        scanProgress = (0, totalCandidates)
        statusMessage = "Scanning \(totalCandidates) level file(s) across \(targets.count) archive(s)…"

        // Extra concurrency past the core count doesn't speed up CPU-bound
        // parsing, it just means more entries' raw bytes + parse products
        // resident in memory at once, capped here, floor 2 so a
        // single-core-visible sandbox still parallelizes I/O against CPU
        // work, ceiling 8 so a many-core machine doesn't hold dozens of
        // large level files in memory simultaneously for no benefit.
        let maxConcurrent = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            var resultsByRoot: [UUID: [String: ChunkNode]] = [:]
            var groupedByRootID: [UUID: (models: [ResolvedModelAsset], orphans: [OrphanedAsset], textures: [TextureHubEntry], levels: [LevelHubEntry])] = [:]
            var resolvedModels: [ResolvedModelAsset] = []
            var orphans: [OrphanedAsset] = []
            var textures: [TextureHubEntry] = []
            var levels: [LevelHubEntry] = []
            var completedCount = 0

            for (rootID, index) in targets {
                guard !Task.isCancelled else { break }
                let chunkEntries = index.entries.filter { Self.isChunkFileName($0.name) }

                let parsed = await withTaskGroup(of: ParsedEntryResult?.self) { group -> [ParsedEntryResult] in
                    var collected: [ParsedEntryResult] = []
                    collected.reserveCapacity(chunkEntries.count)
                    var iterator = chunkEntries.makeIterator()

                    // Sliding window: never more than `maxConcurrent` tasks
                    // in flight, each holding just its own entry's raw
                    // bytes, not the whole archive's.
                    func addNext() {
                        guard let entry = iterator.next() else { return }
                        group.addTask {
                            // Own reader per task (see this function's own
                            // doc comment on BDArchiveReader thread-safety)
                            //, opened fresh per entry rather than reused,
                            // since tasks in this group run concurrently
                            // and complete in any order.
                            //
                            // `applyBulkScan` already counts a `nil` here
                            // toward `failedCount` in the final status
                            // message, but a plain `try?` chain discarded
                            // *which* entry failed and *why*, unlike every
                            // other per-item batch loop in this file
                            // (`stitchChunk`, `loadChunkLinkPlacements`),
                            // which logs both via `AppLog`.
                            do {
                                let reader = try BDArchiveReader(index: index)
                                let data = try reader.read(entry)
                                let kind = Self.fileKind(forEntryNamed: entry.name)
                                let node = try Self.mainTreeDriver(forExtension: (entry.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: kind, fileName: entry.name)
                                let index = AssetResolver.buildIndex(fileRoot: node)
                                let models = Self.resolveModels(index: index, sourceLabel: entry.name)
                                let entryOrphans = AssetResolver.scanForOrphans(index: index, sourceLabel: entry.name)
                                let entryTextures = Self.collectTextures(index: index, sourceLabel: entry.name)
                                let entryLevels = Self.collectLevels(inFileRoot: node, sourceLabel: entry.name)
                                return ParsedEntryResult(name: entry.name, node: node, models: models, orphans: entryOrphans, textures: entryTextures, levels: entryLevels)
                            } catch {
                                AppLog.scanning.debug("Archive scan, \(entry.name) failed to parse: \(error)")
                                return nil
                            }
                        }
                    }

                    for _ in 0..<maxConcurrent { addNext() }
                    while let result = await group.next() {
                        completedCount += 1
                        // Throttled: a MainActor hop per file would add
                        // real overhead for a scan of thousands of files , 
                        // every 5th completion (plus always the very last
                        // one) keeps the progress text moving visibly
                        // without paying that cost per file.
                        if completedCount.isMultiple(of: 5) || completedCount == totalCandidates {
                            let progress = (completedCount, totalCandidates)
                            await MainActor.run { [weak self] in self?.scanProgress = progress }
                        }
                        if let result { collected.append(result) }
                        addNext()
                    }
                    return collected
                }

                var parsedByName: [String: ChunkNode] = [:]
                var modelsForThisArchive: [ResolvedModelAsset] = []
                var orphansForThisArchive: [OrphanedAsset] = []
                var texturesForThisArchive: [TextureHubEntry] = []
                var levelsForThisArchive: [LevelHubEntry] = []
                for result in parsed {
                    parsedByName[result.name] = result.node
                    modelsForThisArchive.append(contentsOf: result.models)
                    orphansForThisArchive.append(contentsOf: result.orphans)
                    texturesForThisArchive.append(contentsOf: result.textures)
                    levelsForThisArchive.append(contentsOf: result.levels)
                }
                resultsByRoot[rootID] = parsedByName
                resolvedModels.append(contentsOf: modelsForThisArchive)
                orphans.append(contentsOf: orphansForThisArchive)
                textures.append(contentsOf: texturesForThisArchive)
                levels.append(contentsOf: levelsForThisArchive)
                groupedByRootID[rootID] = (modelsForThisArchive, orphansForThisArchive, texturesForThisArchive, levelsForThisArchive)
                // Cached per archive, right after its own scan finishes,
                // rather than waiting for every archive in this batch , 
                // pure file I/O over already-`Sendable` value types, safe
                // to do straight from this background task.
                ScanCache.save(ScanCachePayload(modelsHub: modelsForThisArchive, orphanedContent: orphansForThisArchive, texturesHub: texturesForThisArchive), for: index.bdURL)
            }

            let wasCancelled = Task.isCancelled
            await self?.applyBulkScan(resultsByRoot, groupedByRootID: groupedByRootID, resolvedModels: resolvedModels, orphans: orphans, textures: textures, levels: levels, wasCancelled: wasCancelled)
        }
    }

    /// One archive entry's parsed chunk tree plus everything derived from
    /// it, grouped so a single `TaskGroup` child task can hand its whole
    /// result back in one `Sendable` value.
    private struct ParsedEntryResult: Sendable {
        let name: String
        let node: ChunkNode
        let models: [ResolvedModelAsset]
        let orphans: [OrphanedAsset]
        let textures: [TextureHubEntry]
        let levels: [LevelHubEntry]
    }

    private func applyBulkScan(_ resultsByRoot: [UUID: [String: ChunkNode]], groupedByRootID: [UUID: (models: [ResolvedModelAsset], orphans: [OrphanedAsset], textures: [TextureHubEntry], levels: [LevelHubEntry])], resolvedModels: [ResolvedModelAsset], orphans: [OrphanedAsset], textures: [TextureHubEntry], levels: [LevelHubEntry], wasCancelled: Bool = false) {
        defer { isScanning = false; scanProgress = nil }
        var parsedCount = 0
        var failedCount = 0
        // See `hubEntryIDsByRootID`'s own doc comment: every root in this
        // scan is about to contribute fresh hub entries below, strip
        // whatever it contributed on an earlier scan/mount first, so this
        // *replaces* that root's own contribution instead of piling a
        // duplicate copy on top of it.
        for rootID in groupedByRootID.keys { removingHubContributions(forRootID: rootID) }
        // Real, reported performance bug: every one of these freshly-
        // parsed file roots is about to get its `owningArchiveRootIDCache`/
        // `fileRootCache` entry wiped by `rootNodes`'s own `didSet` below
        // (a correct, but blanket, invalidation), which means selecting or
        // opening *any* file this scan just parsed pays a full, uncached
        // tree walk over the whole workspace the moment the user clicks
        // it, right after a scan of hundreds of files is exactly when
        // that's most likely and most expensive. `rootID` is already known
        // here with certainty (the loop key, not derived), so this
        // collects each new node alongside it to re-seed both caches once,
        // right after the invalidating write, instead of leaving every one
        // of them a guaranteed first-click cache miss.
        var seedableFileRoots: [(node: ChunkNode, rootID: UUID)] = []
        for (rootID, parsedByName) in resultsByRoot {
            guard let root = rootNodes.first(where: { $0.id == rootID }) else { continue }
            root.children = root.children.map { child -> ChunkNode in
                guard isExpandableArchiveEntry(child) else { return child }
                guard let parsed = parsedByName[child.displayName] else {
                    failedCount += 1
                    return child
                }
                parsedCount += 1
                let replacement = ChunkNode(
                    recordID: child.recordID,
                    sectionType: parsed.sectionType,
                    displayName: child.displayName,
                    byteSize: child.byteSize,
                    fileOffset: child.fileOffset,
                    children: parsed.children,
                    payload: parsed.payload
                )
                seedableFileRoots.append((replacement, rootID))
                return replacement
            }
        }
        rootNodes = rootNodes
        // `seedLookupCaches` seeds every *descendant* of each freshly-
        // parsed file, not just the file root itself, selecting an
        // Instance/Trigger/Camera/AIPosition record inside any file this
        // scan just parsed is now a cache hit too, not just opening the
        // file's own root.
        for (node, rootID) in seedableFileRoots {
            seedLookupCaches(forFreshFileRoot: node, rootID: rootID)
        }
        modelsHub.append(contentsOf: resolvedModels)
        orphanedContent.append(contentsOf: orphans)
        texturesHub.append(contentsOf: textures)
        levelsHub.append(contentsOf: levels)
        for (rootID, grouped) in groupedByRootID {
            recordingHubContribution(forRootID: rootID, models: grouped.models, orphans: grouped.orphans, textures: grouped.textures, levels: grouped.levels)
        }
        let prefix = wasCancelled ? "Scan cancelled" : "Scan complete"
        statusMessage = failedCount == 0
            ? "\(prefix), parsed \(parsedCount) level file(s), found \(resolvedModels.count) model(s) and \(orphans.count) orphaned/cut record(s)."
            : "\(prefix), parsed \(parsedCount) level file(s), \(failedCount) failed to parse, found \(resolvedModels.count) model(s) and \(orphans.count) orphaned/cut record(s)."
    }

    /// Resolves every `RigidModel` and every rigged `GraphicsInfo` skeleton
    /// in one already-parsed file into `ResolvedModelAsset`s for the Models
    /// Hub. `nonisolated`: pure computation over value types and a
    /// `ChunkNode` tree that hasn't been published anywhere yet, so it's
    /// safe to run off the main actor (called from `scanAllArchives`'s
    /// background loop).
    private nonisolated static func resolveModels(index: GraphicsAssetIndex, sourceLabel: String) -> [ResolvedModelAsset] {
        var results: [ResolvedModelAsset] = []
        for rigidModel in index.rigidModels.values {
            if let resolved = AssetResolver.resolveRigidModel(rigidModel, displayName: "\(sourceLabel), Object #\(rigidModel.id)", index: index) {
                results.append(resolved)
            }
        }
        for skeleton in index.skeletons.values {
            if let resolved = AssetResolver.resolveSkeleton(skeleton, displayName: "\(sourceLabel), Character #\(skeleton.id)", index: index) {
                results.append(resolved)
            }
        }
        return results
    }

    /// "Textures Hub" (QoL sweep), every decoded texture in one already-
    /// parsed file, mirroring `resolveModels`' pattern exactly (same
    /// `nonisolated`/background-scan-safe shape, same per-file population
    /// point in both `load(_:)` and `scanAllArchives`).
    private nonisolated static func collectTextures(index: GraphicsAssetIndex, sourceLabel: String) -> [TextureHubEntry] {
        index.textures.values.map {
            TextureHubEntry(sourceLabel: sourceLabel, texture: $0)
        }
    }

    /// "Visual Levels Hub": every decoded `SceneryData` record with a
    /// non-empty placement tree in one already-parsed file, same shape as
    /// `collectTextures`, but a direct tree walk rather than an
    /// `AssetResolver.buildIndex` lookup, since `SceneryData` lives under a
    /// file's `Code`/level-data sections that index doesn't cover (it's
    /// scoped to `Graphics`/skeleton/animation lookups only). Skips scenery
    /// records with zero placements, an empty/degenerate tree isn't a
    /// level worth a gallery card.
    private nonisolated static func collectLevels(inFileRoot fileRoot: ChunkNode, sourceLabel: String) -> [LevelHubEntry] {
        var results: [LevelHubEntry] = []
        func walk(_ node: ChunkNode) {
            if case .scenery(let scenery) = node.payload, !scenery.placements.isEmpty {
                results.append(LevelHubEntry(sourceLabel: sourceLabel, scenery: scenery, node: node))
            }
            for child in node.children { walk(child) }
        }
        walk(fileRoot)
        return results
    }

    /// Every `Instance` record (placed entity, crate, enemy, platform, …)
    /// in the same file `levelNode` came from, paired with its `ChunkNode`
    /// so an edited transform can be patched straight back to this exact
    /// record's byte offset. Used by the Level Viewer to draw placeholder
    /// markers for objects this build has no verified mesh mapping for (see
    /// `LevelViewerContext.instanceMarkers`'s doc comment), a live tree
    /// walk, not cached, since it's only ever called once per "Open Level
    /// Viewer" click.
    public func instanceRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, instance: PlacedInstance)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .instance(let placed) = payload { return placed }
            return nil
        }.map { (node: $0.node, instance: $0.value) }
    }

    /// "Level Editor Overhaul": every `Trigger` record in the same file , 
    /// same shape as `instanceRecords`, feeding the "Trigger Volumes & Death
    /// Planes" scene layer and the Level Events panel.
    public func triggerRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, trigger: TriggerVolume)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .trigger(let trigger) = payload { return trigger }
            return nil
        }.map { (node: $0.node, trigger: $0.value) }
    }

    /// Every `Camera` record in the same file, feeds the "Camera Splines"
    /// scene layer.
    public func cameraRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, camera: PlacedCamera)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .camera(let camera) = payload { return camera }
            return nil
        }.map { (node: $0.node, camera: $0.value) }
    }

    /// "Collision / Ground Floor": every real `ColData` collision mesh in
    /// the same file, the level's actual walkable ground, decoded as real
    /// triangle geometry (see `CollisionMesh`'s own doc comment), but
    /// never previously rendered anywhere in the Level Viewer. `ColData`
    /// only lives in `.RM2` actor files (confirmed against the reference
    /// tool: `SMViewer.cs` has no `ColData` handling at all), so calling
    /// this for a scenery-only `.sm2` node returns an empty list, same
    /// "always call on both node and siblingNode, use whichever file
    /// actually has it" pattern `openLevelViewer` already uses for
    /// instances/triggers/cameras.
    public func collisionMeshRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, mesh: CollisionMesh)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .collision(let mesh) = payload { return mesh }
            return nil
        }.map { (node: $0.node, mesh: $0.value) }
    }

    /// Every decoded `SoundEffect` record in the same file, feeds the
    /// Level Audio panel. Deliberately presented as exactly that ("sound
    /// effects in this file"), not "BGM"/"ambient bank": `SoundEffectAsset`
    /// carries no category field distinguishing those, and this format
    /// doesn't record which chunk a level's music/ambience actually comes
    /// from, so claiming that distinction would be inventing data this
    /// build doesn't have.
    public func soundEffectRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, sound: SoundEffectAsset)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .soundEffect(let sound) = payload { return sound }
            return nil
        }.map { (node: $0.node, sound: $0.value) }
    }

    /// "Chunk-Based Architecture" (Part 2): every real `ChunkLink` entry
    /// (flattened out of every `ChunkLinks` record, a `.SM2` chunk has at
    /// most one, but this stays list-shaped like its siblings above) in the
    /// same file as `levelNode`. `ChunkLinks` sits at the same tier-0 level
    /// as `SceneryData`/`Graphics` (see `RM2Parser.tier0Kind`), so it's
    /// already reachable via the same `findFileRoot`-rooted walk
    /// `recordsInSameFile` does for Instance/Trigger/Camera/SoundEffect , 
    /// no separate tree-walk entry point needed.
    public func chunkLinkRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, link: ChunkLink)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .chunkLinks(let asset) = payload { return asset }
            return nil
        }.flatMap { entry in entry.value.links.map { (node: entry.node, link: $0) } }
    }

    /// "AI Pathfinding/Navmesh Editor" (roadmap 5.1): every real
    /// `AIPosition` waypoint in the same file, feeds the Level Viewer's
    /// "AI Waypoints" scene layer.
    public func aiPositionRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, marker: AIPositionMarker)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .aiPosition(let marker) = payload { return marker }
            return nil
        }.map { (node: $0.node, marker: $0.value) }
    }

    /// Every real `AIPath` record in the same file, no spatial position of
    /// its own (see `AIPathRecord`'s doc comment), so this feeds a factual
    /// list panel only, not a scene layer.
    public func aiPathRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, path: AIPathRecord)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .aiPath(let path) = payload { return path }
            return nil
        }.map { (node: $0.node, path: $0.value) }
    }

    /// Every real `GameObject` record in the same file, added for "Spawn
    /// Points" (roadmap item 4a): `InstanceInspectorView` cross-references
    /// a `PlacedInstance.objectID` against these to check whether it
    /// resolves to `GameObjectInfo.ObjectTypeID.character`, the closest
    /// real, citable signal this project has for "this Instance is a
    /// playable-character placement" (see that view's own doc comment for
    /// the full citation chain). Same `recordsInSameFile` shape as
    /// `aiPositionRecords`/`aiPathRecords` above, a live walk, not cached.
    public func gameObjectRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, gameObject: GameObjectInfo)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .gameObject(let gameObject) = payload { return gameObject }
            return nil
        }.map { (node: $0.node, gameObject: $0.value) }
    }

    /// Shared tree walk behind `instanceRecords`/`triggerRecords`/
    /// `cameraRecords`/`soundEffectRecords`: every node in the same file as
    /// `levelNode` whose payload `extract` recognizes, paired with that
    /// node. A live walk, not cached, each of these is only ever called
    /// once per "Open Level Viewer" click.
    private func recordsInSameFile<T>(as levelNode: ChunkNode, extract: (ChunkPayload?) -> T?) -> [(node: ChunkNode, value: T)] {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else { return [] }
        var results: [(node: ChunkNode, value: T)] = []
        func walk(_ node: ChunkNode) {
            if let value = extract(node.payload) {
                results.append((node, value))
            }
            for child in node.children { walk(child) }
        }
        walk(fileRoot)
        return results
    }

    /// Everything `openLevelViewer` needs out of one file, gathered in a
    /// single tree walk, real, reported performance bug: `openLevelViewer`
    /// used to call `instanceRecords`/`triggerRecords`/`cameraRecords`/
    /// `soundEffectRecords`/`aiPositionRecords`/`aiPathRecords`/
    /// `collisionMeshRecords` independently, each one its own full,
    /// separate `recordsInSameFile` walk of the *same* file's tree, 7
    /// redundant full walks per file, 14 total across the scenery file and
    /// its sibling actor file, entirely synchronous on the main actor,
    /// every single time a level opens. `findFileRoot` itself is no longer
    /// the expensive part (seeded by `seedLookupCaches` at parse time) , 
    /// this fixes the other half: actually visiting every node in the tree
    /// 7 times over instead of once.
    private struct FileRecordBundle {
        var instances: [(node: ChunkNode, instance: PlacedInstance)] = []
        var triggers: [(node: ChunkNode, trigger: TriggerVolume)] = []
        var cameras: [(node: ChunkNode, camera: PlacedCamera)] = []
        var sounds: [(node: ChunkNode, sound: SoundEffectAsset)] = []
        var aiPositions: [(node: ChunkNode, marker: AIPositionMarker)] = []
        var aiPaths: [(node: ChunkNode, path: AIPathRecord)] = []
        var collisionMeshes: [(node: ChunkNode, mesh: CollisionMesh)] = []
        var chunkLinks: [(node: ChunkNode, link: ChunkLink)] = []
        /// "Real Flags for Forge-Placed Objects": every `InstanceTemplate`/
        /// `InstanceTemplateDemo` record in this file, keyed by the
        /// `objectID` it's a preset for, `InstanceTemplateInfo.properties`
        /// is the exact on-disk field CrateModLoader's own working
        /// randomizer mods (`TS_Rand_Crates.cs`/`TS_Rand_Enemies.cs`) assign
        /// straight into a placed `Instance.Flags` (`instance.Flags =
        /// template.Properties`), confirmed against real disc data: this
        /// level's own `AKUAKUCRATE` template's `properties` is `0x811E`,
        /// byte-for-byte the value this project's placement writer already
        /// hardcoded as its one-size-fits-all fallback. See
        /// `WorldPlacementWriter.writeNewInstance`'s own doc comment for why
        /// that single hardcoded value was never actually right for a
        /// non-crate object type.
        var instanceTemplateProperties: [UInt16: UInt32] = [:]
    }

    private func allRecordsInSameFile(as levelNode: ChunkNode) -> FileRecordBundle {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else { return FileRecordBundle() }
        var bundle = FileRecordBundle()
        func walk(_ node: ChunkNode) {
            switch node.payload {
            case .instance(let value): bundle.instances.append((node, value))
            case .trigger(let value): bundle.triggers.append((node, value))
            case .camera(let value): bundle.cameras.append((node, value))
            case .soundEffect(let value): bundle.sounds.append((node, value))
            case .aiPosition(let value): bundle.aiPositions.append((node, value))
            case .aiPath(let value): bundle.aiPaths.append((node, value))
            case .collision(let value): bundle.collisionMeshes.append((node, value))
            case .chunkLinks(let value): bundle.chunkLinks.append(contentsOf: value.links.map { (node, $0) })
            case .instanceTemplate(let value): bundle.instanceTemplateProperties[value.objectID] = value.properties
            case .instanceTemplateDemo(let value): bundle.instanceTemplateProperties[value.objectID] = value.properties
            default: break
            }
            for child in node.children { walk(child) }
        }
        walk(fileRoot)
        return bundle
    }

    /// Sets the selection and, if the node is an unparsed archive entry,
    /// parses it in the same step. Selecting a `.RM2`/`.SM2` entry is the
    /// obvious, discoverable action, requiring a separate small "Parse"
    /// button click first (nothing else in the sidebar works that way) reads
    /// as "this file won't open" rather than "click this other thing first."
    ///
    /// The actual parse-and-mutate work is dispatched to the next run loop
    /// tick rather than done inline: `select` is called from `List`'s
    /// selection `Binding.set`, which SwiftUI invokes *during* its own view
    /// update pass, mutating `@Observable` state synchronously in there
    /// produces genuinely undefined rendering (rows not updating,
    /// disclosure state going stale), not just a console warning to
    /// ignore. Same underlying "don't mutate observed state mid-update"
    /// rule this codebase already had to respect back when this class was
    /// `ObservableObject`/`@Published` (the warning text SwiftUI logs
    /// differs, the hazard doesn't).
    public func select(_ node: ChunkNode?) {
        // `selectedNode = node` is an `@Observable` mutation, and `select`
        // is called from `List`'s selection `Binding.set`, which SwiftUI
        // invokes *during* its own view update pass, mutating observed
        // state synchronously in there produces genuinely undefined
        // behavior (not just a console warning), matching exactly what
        // was observed clicking around the sidebar. The whole
        // body, not just the archive-expansion half that was already
        // deferred, has to move to the next run loop tick.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectedNode = node
            guard let node else { return }

            // One real, unopened clip inside an already-extracted WoC
            // sound archive (see `expandWOCSoundArchive`), decode just
            // this one clip and swap its payload in, rather than the
            // whole-file "extract and open" path below (there's no
            // separate file to extract; the archive was already pulled
            // once when its own node was clicked).
            if let pending = self.wocSoundClipPending[node.id] {
                self.wocSoundClipPending.removeValue(forKey: node.id)
                Task { [weak self] in
                    await self?.decodeWOCSoundClip(node, archiveURL: pending.archiveURL, entry: pending.entry)
                }
                return
            }

            // A disc-mounted file leaf (see `mountDiscImage`), extract and
            // open it the same one-click way an archive entry expands,
            // rather than requiring a second explicit action. Checked
            // before the archive-expand path since a disc leaf can
            // structurally satisfy `isExpandableArchiveEntry` too (empty
            // children, nil payload, a recognized extension) without
            // actually being one.
            if let holder = self.discEntryByNodeID[node.id],
               let entry = holder.entry as? ISO9660Entry,
               let source = holder.source as? any LogicalSectorSource {
                // WoC's own real, decoded formats (see `WOCLevelLoader`/
                // `WOCSoundParser`), routed to their own expansion instead
                // of `openDiscEntry`'s generic "extract, then run through
                // the Twinsanity-only `open(url:)` pipeline" path, which
                // doesn't understand any WoC extension and would just fail
                // silently. `.GSC` gets the full per-level tree (objects,
                // textures, AI, foliage, animations, paths, terrain);
                // `SFX.DAT`/`ATS.DAT` get their real per-clip table.
                let ext = (entry.name as NSString).pathExtension.uppercased()
                if ext == "GSC" {
                    Task { [weak self] in await self?.expandWOCLevelEntry(node, entry: entry, source: source) }
                    return
                }
                let upperName = entry.name.uppercased()
                if upperName == "SFX.DAT" || upperName == "ATS.DAT" {
                    Task { [weak self] in await self?.expandWOCSoundArchive(node, entry: entry, source: source) }
                    return
                }
                Task { [weak self] in await self?.openDiscEntry(entry, source: source, node: node) }
                return
            }

            // Real, reported bug ("close the Chunk Viewer window, click the
            // same level in the sidebar again" reopens showing scenery
            // only, or sometimes doesn't reopen at all): `isExpandableArchiveEntry`
            // only recognizes the *unexpanded placeholder* shape (empty
            // children, nil payload) a chunk file starts as. The very first
            // click on a level's `.sm2` hits that below and auto-opens the
            // Level Viewer via the fresh-expand branch's own doc comment.
            // But `expandArchiveEntry` replaces the node with a real,
            // populated tree, so every click *after* that first one no
            // longer satisfies `isExpandableArchiveEntry` at all, and used
            // to just fall through this whole `guard` silently: closing the
            // window (which only nils `levelViewerContext`, never touches
            // `rootNodes`) then re-clicking the same already-expanded level
            // did nothing, leaving the window closed instead of reopening
            // it. Re-clicking an already-expanded recognized chunk file
            // (`.sm2`/`.smx`/`.rm2`/`.rmx`) that itself has a real scenery
            // descendant is unambiguously "open this level again", unlike
            // clicking some unrelated record *inside* an open chunk (an
            // Instance/Trigger/Camera node), which never carries one of
            // these four extensions as its own `displayName`, so this can't
            // spuriously reopen the viewer for an inspection click deeper
            // in the tree.
            if let sceneryNode = Self.reclickedAlreadyExpandedLevelSceneryNode(node),
               case .scenery(let asset) = sceneryNode.payload {
                // Code review: this branch had no loading-state guard at
                // all, unlike `LevelsHubView`/`SceneryInspectorView`, which
                // at least disabled their own button, rapid re-clicking (or
                // arrow-key reselecting) the same sidebar row could start a
                // new overlapping `openLevelViewer` call on every click with
                // zero feedback that one was already running. No spinner
                // plumbed through here (would need new `@State` threaded
                // into the sidebar view), but silently no-op'ing while one
                // is already in flight stops the pile-up this same session
                // already measured at 4-8s per overlapping call.
                guard !self.isOpeningLevelViewer else { return }
                Task { [weak self] in
                    await self?.openLevelViewer(for: asset, node: sceneryNode)
                }
                return
            }

            guard self.isExpandableArchiveEntry(node) else { return }
            guard let rootID = self.owningArchiveRootID(of: node) else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.expandArchiveEntry(node, rootID: rootID)
                // "Frictionless Chunk Loading": a chunk file selected straight
                // from the sidebar goes to the same place clicking its Chunk
                // Hub card does, no separate hub lookup required. Only fires
                // right after *this* expand (the node this file's root just
                // became), not on every later re-select of an already-parsed
                // file, so re-clicking a node inside an open chunk to inspect
                // one record doesn't keep yanking focus back into the 3D
                // viewer window.
                guard let expanded = self.selectedNode, expanded !== node,
                      let sceneryNode = Self.firstSceneryNode(in: expanded),
                      case .scenery(let asset) = sceneryNode.payload
                else { return }
                await self.openLevelViewer(for: asset, node: sceneryNode)
            }
        }
    }

    /// `select`'s "re-click an already-expanded level" branch (see that
    /// function's own doc comment for the real bug this fixes), pulled out
    /// as a pure, `nonisolated` function so a test can exercise the exact
    /// same decision `select` makes without needing its
    /// `DispatchQueue.main.async`-deferred body to actually run (confirmed,
    /// separately, not to fire reliably under polling in a headless XCTest
    /// host, same reasoning as `magnetSnappedPosition`'s own "exposed for
    /// testing" doc comment). `nil` unless `node` is itself a real,
    /// already-expanded (non-empty children) recognized chunk file with a
    /// real scenery descendant, never true for some unrelated record
    /// clicked *inside* an open chunk, since only a level's own `.sm2`/
    /// `.smx`/`.rm2`/`.rmx` file-root entry carries one of those four
    /// extensions as its own `displayName`.
    nonisolated static func reclickedAlreadyExpandedLevelSceneryNode(_ node: ChunkNode) -> ChunkNode? {
        guard !node.children.isEmpty, Self.isChunkFileName(node.displayName) else { return nil }
        return firstSceneryNode(in: node)
    }

    /// First descendant (including `root` itself) carrying real, non-empty
    /// `SceneryData` placements, same match `collectLevels` uses for the
    /// Chunk Hub, just short-circuiting on the first hit instead of
    /// collecting every one, since `select`'s one-click path only needs to
    /// know whether *a* level exists in the file that was just parsed.
    private nonisolated static func firstSceneryNode(in root: ChunkNode) -> ChunkNode? {
        if case .scenery(let scenery) = root.payload, !scenery.placements.isEmpty { return root }
        for child in root.children {
            if let found = firstSceneryNode(in: child) { return found }
        }
        return nil
    }

    private func owningArchiveRootID(of node: ChunkNode) -> UUID? {
        if let cached = owningArchiveRootIDCache[node.id] { return cached }
        var result: UUID?
        for rootID in archiveIndexByRootID.keys {
            guard let root = rootNodes.first(where: { $0.id == rootID }) else { continue }
            if contains(root, node) { result = rootID; break }
        }
        owningArchiveRootIDCache[node.id] = result
        return result
    }

    private func contains(_ subtree: ChunkNode, _ target: ChunkNode) -> Bool {
        if subtree === target { return true }
        return subtree.children.contains { contains($0, target) }
    }

    /// Pre-computes and caches `findFileRoot`'s and `owningArchiveRootID`'s
    /// own answers for *every* node in a subtree that was just freshly
    /// parsed (from `expandArchiveEntry`/`applyBulkScan`), real, reported
    /// performance bug: `rootNodes`'s own `didSet` wipes both caches on
    /// every tree write, including the one that just added this subtree,
    /// so selecting *any* Instance/Trigger/Camera/AIPosition record inside
    /// it, not just the file root itself, was a guaranteed first-select
    /// cache miss, paying a full walk over the *entire* workspace tree
    /// (`findFileRootRecursive`'s own doc comment: "plain tree search...
    /// nodes get replaced... which would leave stale parent references" , 
    /// this seeds the *cache* instead of adding parent pointers to
    /// `ChunkNode` itself, since parent pointers would get silently
    /// corrupted the moment any filtered/pruned tree *view* is built , 
    /// `filtered(matching:)`/`filtered(byKind:)`/`prunedOfRawContent()` all
    /// reuse the same child objects by reference under a brand-new parent
    /// wrapper, exactly the shape this codebase already relies on for
    /// `filteredRootNodes`'s own performance).
    ///
    /// Walks `fileRoot`'s subtree exactly once, replicating
    /// `findFileRootRecursive`'s own "nearest ancestor (or self) that
    /// looks like a file root" decision at each node, not just stamping
    /// every descendant with `fileRoot` itself, which would give the wrong
    /// answer for anything under a *nested* container that happens to
    /// satisfy that same shape (a real, structurally possible case, not a
    /// hypothetical one, `fileRootSectionTypes`'s own doc comment already
    /// documents one real file whose only top-level section was its own
    /// Instance container).
    private func seedLookupCaches(forFreshFileRoot fileRoot: ChunkNode, rootID: UUID) {
        let fileRootSectionTypes = Self.fileRootSectionTypes
        func walk(_ node: ChunkNode, nearestFileRoot: ChunkNode?) {
            let looksLikeFileRoot = node.sectionType == .null && node.children.contains { fileRootSectionTypes.contains($0.sectionType) }
            let nextFileRoot = looksLikeFileRoot ? node : nearestFileRoot
            fileRootCache[node.id] = nextFileRoot
            owningArchiveRootIDCache[node.id] = rootID
            for child in node.children {
                walk(child, nearestFileRoot: nextFileRoot)
            }
        }
        walk(fileRoot, nearestFileRoot: nil)
    }

    /// Extracts an archived entry's bytes from its `.BD` and parses it as a
    /// chunk tree, so levels packed inside a master archive are browsable
    /// without a separate manual extract step.
    ///
    /// This *replaces* `node` in the tree with a brand-new `ChunkNode`
    /// (fresh `UUID`) rather than mutating `node.children`/`.payload` in
    /// place. `ChunkNode` isn't `ObservableObject`, `List`/`OutlineGroup`
    /// diff the tree using each node's `Identifiable.id`, and mutating an
    /// already-diffed reference-type instance's contents in place is not
    /// guaranteed to be picked back up (SwiftUI has no way to know a
    /// property on a plain class changed). Giving the replacement a new
    /// identity makes the change unambiguous to SwiftUI's diffing instead of
    /// relying on it noticing an in-place mutation.
    /// "Visual Loading Feedback": the read+parse used to run fully
    /// synchronously on the main actor, `isLoading` flipped true then
    /// false again within one blocked run-loop turn, so SwiftUI never
    /// actually got a chance to paint the spinner it gates on that flag.
    /// The heavy work now runs in a detached task (same shape as
    /// `openChunkLink`/`loadSingleLevelFileAsync`), with only the tree
    /// mutation itself back on the main actor, a real suspension point in
    /// between, so the spinner genuinely shows for however long parsing an
    /// archived file actually takes.
    public func expandArchiveEntry(_ node: ChunkNode, rootID: UUID) async {
        // See `inFlightArchiveEntryExpansions`'s own doc comment. A second
        // concurrent call for the exact same still-unexpanded placeholder
        // awaits the first call's real result instead of racing it with
        // its own redundant parse.
        if let inFlight = inFlightArchiveEntryExpansions[node.id] {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performExpandingArchiveEntry(node, rootID: rootID)
        }
        inFlightArchiveEntryExpansions[node.id] = task
        await task.value
        inFlightArchiveEntryExpansions[node.id] = nil
    }

    private func performExpandingArchiveEntry(_ node: ChunkNode, rootID: UUID) async {
        guard let index = archiveIndexByRootID[rootID] else { return }
        guard let entry = index.entries.first(where: { $0.name == node.displayName }) else { return }
        let kind = Self.fileKind(forEntryNamed: entry.name)

        isLoading = true
        defer { isLoading = false }

        let outcome: Result<(ChunkNode, Data), Error> = await Task.detached(priority: .userInitiated) {
            do {
                let data = try BDArchiveParser.readEntryData(entry, index: index)
                let parsed = try Self.mainTreeDriver(forExtension: (entry.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: kind, fileName: entry.name)
                return .success((parsed, data))
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let (parsed, data)):
            // Real, reported bug ("place scenery", and, by the same
            // mechanism, any other insert-a-new-record save, always fails
            // with "couldn't safely apply the record change... refusing to
            // save a possibly-corrupt result" for *any* level reached by
            // browsing a mounted archive/disc): `node` here is still the
            // unexpanded archive-entry placeholder from `load(_:)`, whose
            // `byteSize`/`fileOffset` are `entry.size`/`entry.offset`, this
            // file's span *inside the shared `.BD` archive* (e.g. a real
            // beach.sm2 sits at archive offset 107204180). `parsed` is the
            // fresh `RM2Parser.parse` of `data`, which is this file's own
            // *standalone, already-extracted* bytes (`BDArchiveParser.
            // readEntryData`), addressed from 0, per `RM2Parser.parse`'s
            // own root (`fileOffset: 0, byteSize: data.count`), same as any
            // directly-opened loose `.RM2`/`.SM2`. Building `replacement`
            // with `node`'s archive-relative offset instead of `parsed`'s
            // own would leave `replacement.fileOffset` pointing tens/
            // hundreds of megabytes past the end of `data` (which is only
            // this one file's bytes), harmless for every *leaf* record
            // (their own `fileOffset`s are computed independently, relative
            // to `data`, by `RM2Parser`'s recursion, never derived from the
            // root's own field) but fatal the moment anything targets the
            // file root itself as a section to rebuild: `ChunkSectionInserter`
            // slices `originalFileBytes` (= `rawFileBytesByRootID[replacement.
            // id]` = `data`) at `sectionNode.fileOffset..<+byteSize`, for
            // `SceneryData` (a tier-0 "raw leaf" whose containing section
            // *is* the file root, see `RM2Parser.tier0Kind`'s doc comment)
            // that slice is always out of `data`'s bounds, and for every
            // other insertion (Instance/Trigger/Camera/AIPosition/AIPath)
            // the file root is still the outermost ancestor
            // `insertingRecords`/`applyingRecordChanges` walks up to and
            // rebuilds via the same offset, so both fail identically.
            // `byteSize` numerically happens to match either way (no
            // compression, `entry.size == data.count` exactly), which is
            // why this only ever showed up as a *save* failure, never a
            // *browse/parse* one. Using `parsed`'s own root fields keeps
            // this node's coordinates consistent with the bytes actually
            // stored for it, exactly like a standalone-opened file.
            let replacement = ChunkNode(
                recordID: node.recordID,
                sectionType: parsed.sectionType,
                displayName: node.displayName,
                byteSize: parsed.byteSize,
                fileOffset: parsed.fileOffset,
                children: parsed.children,
                payload: parsed.payload
            )
            // Real, reported gap: expanding an archive entry (whether from
            // a directly-opened `.BH` or one extracted from a mounted disc
            // image, both converge here) used to only ever update the
            // browsable tree, never register this file's own raw bytes.
            // `canSaveEdits`/`patchedFileBytes` (and everything built on
            // them, "Save Chunk Overrides…", Quick Launch's pending-edit
            // bake-in) all gate on `rawFileBytesByRootID`, so every level
            // reached by *browsing* an archive, the normal way anyone
            // opens a level from a mounted ISO, silently couldn't be
            // saved at all, with no error until the save button itself
            // turned out disabled. `replacement` is exactly the file root
            // `findFileRoot` will later identify for any record inside it
            // (`sectionType == .null` with a `.graphics`/`.code`-family
            // child, the same shape a standalone `Data(contentsOf:)` open
            // already produces), so this is the same real invariant
            // `load(_:)`'s own `rawFileBytesByRootID[node.id] = data` line
            // establishes for a directly-opened file, not a special case.
            rawFileBytesByRootID[replacement.id] = data
            rootNodes = rootNodes.map { replacingDescendant(node, with: replacement, in: $0) }
            if selectedNode === node {
                selectedNode = replacement
            }
            seedLookupCaches(forFreshFileRoot: replacement, rootID: rootID)
            // "Parsing one half of a scenery/actor pair pulls in the
            // other", real, requested behavior: a level's Instance/
            // Trigger/Camera/AIPosition/AIPath data lives entirely in the
            // sibling actor file (`.rm2`/`.rmx`), never the scenery file
            // (`.sm2`/`.smx`) itself, or vice versa (see `siblingActorFileRoot`'s
            // own doc comment for the full "scenery only" symptom this
            // avoids). `siblingActorFileRoot` already falls back to
            // expanding the sibling on demand the first time something
            // asks for it, but that means opening a level from a mounted
            // archive silently triggers a *second*, separate parse right
            // as the Level Viewer opens. Doing it here, the instant
            // either half of the pair gets clicked in the sidebar, means
            // both halves are ready together. Guarded by "still the bare,
            // unexpanded placeholder" so this can't loop between the two
            // files re-expanding each other back and forth.
            if let siblingName = Self.siblingChunkFileEntryName(for: entry.name, in: index.entries),
               let siblingPlaceholder = Self.findArchiveEntryPlaceholder(named: siblingName, in: rootNodes),
               siblingPlaceholder.payload == nil, siblingPlaceholder.children.isEmpty {
                await expandArchiveEntry(siblingPlaceholder, rootID: rootID)
            }
        case .failure(let error):
            lastError = "\(entry.name): \(error)"
        }
    }

    /// The WoC counterpart to `expandArchiveEntry`: a mounted disc's real
    /// `.GSC` level file, clicked for the first time. Extracts its real
    /// bytes, plus any real sibling `.AI`/`.GRA`/`.ANM`/`.PAD`/`.TER` bytes
    /// found in the same disc directory (looked up by walking `node`'s
    /// parent's other children, WoC has no separate archive index the
    /// way `.BH` does, so there's no index to look siblings up in), and
    /// hands them to `WOCDiscTreeBuilder`, which runs them through the
    /// same `WOCLevelLoader` pipeline `WOCWorkspace` uses for a real
    /// mounted folder. Replaces `node` in place, same identity-swap
    /// pattern as `expandArchiveEntry`.
    private func expandWOCLevelEntry(_ node: ChunkNode, entry: ISO9660Entry, source: any LogicalSectorSource) async {
        isLoading = true
        defer { isLoading = false }

        guard let gscData = ISO9660Reader.readFile(entry, from: source) else {
            lastError = "Couldn't read \(entry.name)'s real bytes from the mounted image."
            return
        }
        let levelName = (entry.name as NSString).deletingPathExtension

        var siblingData: [String: Data] = [:]
        if let parentNode = parent(of: node, inAnyOf: rootNodes) {
            for sibling in parentNode.children where sibling !== node {
                let ext = (sibling.displayName as NSString).pathExtension.uppercased()
                guard Self.wocSiblingExtensions.contains(ext) else { continue }
                guard (sibling.displayName as NSString).deletingPathExtension.caseInsensitiveCompare(levelName) == .orderedSame else { continue }
                guard let siblingHolder = discEntryByNodeID[sibling.id],
                      let siblingEntry = siblingHolder.entry as? ISO9660Entry,
                      let siblingSource = siblingHolder.source as? any LogicalSectorSource,
                      let data = ISO9660Reader.readFile(siblingEntry, from: siblingSource) else { continue }
                siblingData[ext] = data
            }
        }

        let outcome: Result<(node: ChunkNode, asset: WOCLevelAsset), Error> = await Task.detached(priority: .userInitiated) {
            do {
                let built = try WOCDiscTreeBuilder.buildLevelNode(
                    recordID: node.recordID, displayName: node.displayName, byteSize: node.byteSize, fileOffset: node.fileOffset,
                    gscData: gscData, siblingData: siblingData, levelName: levelName
                )
                return .success(built)
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let built):
            rootNodes = rootNodes.map { replacingDescendant(node, with: built.node, in: $0) }
            wocLevelAssetsByRootID[built.node.id] = built.asset
            if selectedNode === node { selectedNode = built.node }
        case .failure(let error):
            lastError = "\(entry.name): \(error)"
        }
    }

    /// The WoC counterpart to `archiveIndexByRootID`/`discEntryByNodeID`:
    /// keyed by the `ChunkNode.id` `WOCDiscTreeBuilder.buildLevelNode`
    /// returns for a given `.GSC`'s expanded tree, so `resolveComposite(for:)`
    /// can find the real `WOCLevelAsset` (and its `objectMeshes`/
    /// `materialTextureIDs` reference chain) a texture deep in that tree
    /// came from, the tree itself carries none of that, see
    /// `WOCCompositeResolver`'s own doc comment.
    private var wocLevelAssetsByRootID: [UUID: WOCLevelAsset] = [:]

    /// Depth-first search for the nearest ancestor of `target` whose `id`
    /// is a key in `wocLevelAssetsByRootID`, the WoC-tree counterpart to
    /// `findFileRoot`, which only recognizes the RM2/SM2 `Graphics`/`Code`
    /// shape and so never matches anything inside a WoC-sourced subtree.
    private func findWOCLevelAsset(containing target: ChunkNode, in nodes: [ChunkNode]) -> WOCLevelAsset? {
        for node in nodes {
            if let asset = wocLevelAssetsByRootID[node.id], contains(node, target) {
                return asset
            }
            if let found = findWOCLevelAsset(containing: target, in: node.children) {
                return found
            }
        }
        return nil
    }

    /// Extension list for WoC's per-level sibling loose files this build
    /// currently understands, see `WOCLevelAsset`'s doc comment. `.GSC`
    /// itself isn't in this list; it's the file being expanded, not a
    /// sibling of itself.
    private static let wocSiblingExtensions: Set<String> = ["AI", "GRA", "ANM", "PAD", "TER"]

    /// A mounted `SFX.DAT`/`ATS.DAT`, clicked for the first time: extracts
    /// the whole real archive to a temp file once (same one-time-extract
    /// cost `openDiscEntry` already pays for any disc file), reads its
    /// real offset table (cheap, header + table only, no per-clip decode
    /// yet), and builds one real leaf per clip. Each leaf's own PCM decode
    /// is deferred to `decodeWOCSoundClip`, triggered by actually clicking
    /// that specific clip (see `wocSoundClipPending`), decoding all ~782
    /// real clips up front would mean holding the better part of a
    /// gigabyte of PCM resident just to populate a browsable list.
    private func expandWOCSoundArchive(_ node: ChunkNode, entry: ISO9660Entry, source: any LogicalSectorSource) async {
        isLoading = true
        defer { isLoading = false }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(entry.name)
        let outcome: Result<(URL, [WOCSoundParser.Entry]), Error> = await Task.detached(priority: .userInitiated) {
            guard let data = ISO9660Reader.readFile(entry, from: source) else {
                return .failure(CocoaError(.fileReadUnknown))
            }
            do {
                try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: tempURL)
                let entries = try WOCSoundParser.parseTable(fileURL: tempURL)
                return .success((tempURL, entries))
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let (archiveURL, soundEntries)):
            var children: [ChunkNode] = []
            children.reserveCapacity(soundEntries.count)
            for soundEntry in soundEntries {
                let clipNode = ChunkNode(
                    recordID: UInt32(soundEntry.index), sectionType: .null,
                    displayName: "Clip #\(soundEntry.index)", byteSize: Int(soundEntry.size), fileOffset: Int(soundEntry.offset),
                    isLazyLoadable: true
                )
                wocSoundClipPending[clipNode.id] = (archiveURL, soundEntry)
                children.append(clipNode)
            }
            let replacement = ChunkNode(recordID: node.recordID, sectionType: node.sectionType, displayName: node.displayName, byteSize: node.byteSize, fileOffset: node.fileOffset, children: children)
            rootNodes = rootNodes.map { replacingDescendant(node, with: replacement, in: $0) }
            if selectedNode === node { selectedNode = replacement }
        case .failure(let error):
            lastError = "\(entry.name): \(error)"
        }
    }

    /// One real WoC sound clip, decoded on click (see `wocSoundClipPending`'s
    /// doc comment). Reuses `SoundEffectAsset`, the decoded PCM genuinely
    /// fits that type's contract, so the existing `SoundEffectInspectorView`
    /// (waveform, play/stop, WAV export) renders it with no new UI needed.
    /// `sourceAudioByteRange` stays `nil`: this build has no verified WoC
    /// sound *write* path, so "Replace with Audio…" correctly stays
    /// unavailable rather than offering an edit this can't actually save.
    private func decodeWOCSoundClip(_ node: ChunkNode, archiveURL: URL, entry: WOCSoundParser.Entry) async {
        isLoading = true
        defer { isLoading = false }

        let outcome: Result<WOCSoundParser.DecodedClip, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try WOCSoundParser.decode(entry, fileURL: archiveURL)) }
            catch { return .failure(error) }
        }.value

        switch outcome {
        case .success(let clip):
            let asset = SoundEffectAsset(id: UInt32(entry.index), sampleRateHz: UInt16(clamping: clip.sampleRate), pcmSamples: clip.samples)
            let replacement = ChunkNode(recordID: node.recordID, sectionType: node.sectionType, displayName: node.displayName, byteSize: node.byteSize, fileOffset: node.fileOffset, payload: .soundEffect(asset))
            rootNodes = rootNodes.map { replacingDescendant(node, with: replacement, in: $0) }
            if selectedNode === node { selectedNode = replacement }
        case .failure(let error):
            lastError = "Clip #\(entry.index): \(error)"
        }
    }

    /// `target`'s immediate parent, searched across every root tree , 
    /// `ChunkNode` has no back-pointer, so this is a plain depth-first
    /// walk. Used by `expandWOCLevelEntry` to find a `.GSC`'s real sibling
    /// files (same disc folder, same base name) without WoC having any
    /// archive-index concept to look them up in the way `.BH` entries do.
    /// "Cross-Reference Validation, Colliding IDs", real, requested
    /// missing feature: `IDEditorSheet` let a user reassign a record's ID
    /// to *any* number, including one another sibling record in the same
    /// section already uses, silently producing two records with the
    /// same ID and no warning at all (which of the two an ID-based
    /// reference like a Trigger's instance list or a script slot actually
    /// resolves to at that point is anyone's guess). Every other record ID
    /// currently in `node`'s own containing section, so a caller can check
    /// a proposed new ID against real, current sibling data before saving.
    public func siblingRecordIDs(of node: ChunkNode, excludingSelf: Bool = true) -> Set<UInt32> {
        guard let section = parent(of: node, inAnyOf: rootNodes) else { return [] }
        var ids = Set(section.children.map(\.recordID))
        if excludingSelf { ids.remove(node.recordID) }
        return ids
    }

    private func parent(of target: ChunkNode, inAnyOf roots: [ChunkNode]) -> ChunkNode? {
        for root in roots {
            if let found = parent(of: target, in: root) { return found }
        }
        return nil
    }

    private func parent(of target: ChunkNode, in root: ChunkNode) -> ChunkNode? {
        for child in root.children {
            if child === target { return root }
            if let found = parent(of: target, in: child) { return found }
        }
        return nil
    }

    /// Returns a tree equal to `root` except that `target` (found anywhere
    /// in it, by identity) is swapped for `replacement`. `root` itself is
    /// returned unchanged (same identity) when `target` isn't inside it , 
    /// only nodes on the path to `target` get their `children` array
    /// reassigned, so unrelated branches of a large tree (e.g. the other 696
    /// archive entries) aren't touched.
    private func replacingDescendant(_ target: ChunkNode, with replacement: ChunkNode, in root: ChunkNode) -> ChunkNode {
        if root === target { return replacement }
        guard !root.children.isEmpty else { return root }
        var changed = false
        let newChildren = root.children.map { child -> ChunkNode in
            let updated = replacingDescendant(target, with: replacement, in: child)
            if updated !== child { changed = true }
            return updated
        }
        if changed { root.children = newChildren }
        return root
    }

    // MARK: - Editing (proof of concept, see WorldPlacementWriter's doc comment)

    /// Whether `node`'s enclosing file is one this build can currently save
    /// edits back to: a standalone-opened `.RM2`/`.SM2`, not one still
    /// packed inside a `.BD` archive (`rawFileBytesByRootID` is only
    /// populated for the former, see `load(_:)`).
    public func canSaveEdits(for node: ChunkNode) -> Bool {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else {
            AppLog.rendering.debug("[PlayDiag] canSaveEdits: findFileRoot(containing: node) returned nil, node.displayName=\(node.displayName, privacy: .public) recordID=\(node.recordID, privacy: .public)")
            return false
        }
        let hasBytes = rawFileBytesByRootID[fileRoot.id] != nil
        AppLog.rendering.debug("[PlayDiag] canSaveEdits: fileRoot=\(fileRoot.displayName, privacy: .public) id=\(fileRoot.id, privacy: .public) hasRawBytes=\(hasBytes, privacy: .public) knownRootIDs=\(self.rawFileBytesByRootID.keys.map(\.uuidString), privacy: .public)")
        return hasBytes
    }

    /// The original file name `node`'s enclosing standalone-opened
    /// `.RM2`/`.SM2` was loaded from (`ChunkNode.displayName` on the file
    /// root, see `RM2Parser.parse`, which sets it directly from the
    /// caller's `fileName`). Used as the default in-crate file name for
    /// "Export as Mod Crate…", since that's the only name this build
    /// actually knows for the file.
    public func originalFileName(for node: ChunkNode) -> String? {
        findFileRoot(containing: node, in: rootNodes)?.displayName
    }

    /// Public wrapper over `findFileRoot`, "Add Scenery From Other
    /// Level…" needs the destination `.sm2`'s own file root (not just any
    /// node inside it) to pass to `placingSceneryFromAnotherLevel`.
    public func fileRoot(containing node: ChunkNode) -> ChunkNode? {
        findFileRoot(containing: node, in: rootNodes)
    }

    /// "Memory-Mapped Hex Engine" (blueprint 5.2): the exact on-disk bytes
    /// backing `node`, for the raw hex viewer/editor. Same standalone-file
    /// scope as `canSaveEdits`/`patchedFileBytes`, an archive-packed
    /// entry's bytes aren't held anywhere after `expandArchiveEntry`
    /// discards them post-parse, only a standalone-opened file's full bytes
    /// are kept around (`rawFileBytesByRootID`).
    public func rawBytes(for node: ChunkNode) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id],
              node.fileOffset >= 0, node.byteSize >= 0,
              node.fileOffset + node.byteSize <= bytes.count
        else { return nil }
        return bytes.subdata(in: node.fileOffset..<(node.fileOffset + node.byteSize))
    }

    /// Non-nil presents the Hex Viewer sheet (see `ContentView`).
    public var hexViewerNode: ChunkNode?

    /// "AgentLab Visual Node Graph" (Part 3, roadmap 4.2): non-nil presents
    /// the AgentLab graph sheet (see `ContentView`) for a `CustomAgent`
    /// section container node, see `AgentLabGraphView`'s doc comment for
    /// why its nodes hold raw bytes rather than decoded behavior data.
    public var agentLabNode: ChunkNode?

    /// Saves a hex-edited byte range back the same way `PositionInspectorView`
    /// saves a structured edit, patch a copy of the owning file's bytes,
    /// prompt for where to write it, leave the originally-opened file alone.
    /// `editedBytes.count` must equal `node.byteSize`; the hex editor UI
    /// enforces this by construction (it edits a fixed-size buffer, no
    /// insert/delete), matching `patchedFileBytes`'s own same-size
    /// requirement.
    public func saveHexEdit(node: ChunkNode, editedBytes: Data, to url: URL) async {
        guard let patched = patchedFileBytes(replacing: node, with: editedBytes) else { return }
        do {
            try await writeDataAsync(patched, to: url)
            statusMessage = "Saved edited copy to \(url.lastPathComponent). The original file was not modified."
        } catch {
            lastError = "Save failed: \(error)"
        }
    }

    /// "Visual Loading Feedback": every save path writes a full patched
    /// copy of the source file, genuinely large for a full level file
    /// even when the edit itself is tiny. Runs the actual `Data.write` off
    /// the main actor, bracketed by `isSaving`, so the toolbar spinner
    /// (same real-feedback pattern as loading) has an actual suspension
    /// point to paint across instead of a main-actor call that returns
    /// before SwiftUI gets a chance to render anything.
    public func writeDataAsync(_ data: Data, to url: URL) async throws {
        isSaving = true
        defer { isSaving = false }
        try await Task.detached(priority: .userInitiated) {
            try data.write(to: url)
        }.value
    }

    /// Patches `encoded` into a *copy* of the owning file's original bytes
    /// at `node`'s known offset, pure and side-effect-free; the caller
    /// (a view) is responsible for prompting where to save the result and
    /// actually writing it, matching this codebase's established split
    /// (compare `ExportPanel` + `exportTexturePNG`). Only valid when
    /// `encoded.count == node.byteSize`: this proof of concept covers a
    /// fixed-size record (`Position`, always 16 bytes), so nothing else in
    /// the file needs its offsets adjusted.
    public func patchedFileBytes(replacing node: ChunkNode, with encoded: Data) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              var bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard encoded.count == node.byteSize else {
            lastError = "Internal error: encoded record is \(encoded.count) bytes, expected \(node.byteSize), refusing to save a size-changing edit."
            return nil
        }
        guard node.fileOffset >= 0, node.fileOffset + encoded.count <= bytes.count else {
            lastError = "Internal error: this record's offset is outside its file's bounds."
            return nil
        }
        bytes.replaceSubrange(node.fileOffset..<(node.fileOffset + encoded.count), with: encoded)
        return bytes
    }

    /// "AgentLab Phase B"'s structural counterpart to `patchedFileBytes(
    /// replacing:with:)`: `encoded` need not be `node.byteSize` bytes , 
    /// unlike every other patch function in this file, this one can grow or
    /// shrink `node`'s own on-disk record (adding/removing a `ScriptState`,
    /// `ScriptStateBody`, or `ScriptCommand` changes the record's total
    /// size). Built on the same `ChunkSectionInserter.
    /// applyingRecordChanges` remove-then-insert-same-`id` path "Save Chunk
    /// Overrides" already uses to append brand-new records, applied here to
    /// replace an *existing* one in place instead, the record's own `id`
    /// is preserved (nothing else in the file references it by index/
    /// position, only by this `id`), so every other reference to it stays
    /// valid.
    public func patchedFileBytes(replacingWholeRecord node: ChunkNode, with encoded: Data) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let targetSection = parent(of: node, inAnyOf: rootNodes) else {
            lastError = "Internal error: couldn't find this record's containing section, refusing to save a possibly-corrupt result."
            return nil
        }
        guard let result = ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: targetSection, insert: [(id: node.recordID, encoded: encoded)], removeIDs: [node.recordID])],
            fileRoot: fileRoot,
            originalFileBytes: bytes
        ) else {
            lastError = "Internal error: couldn't safely apply the record change to the file structure, refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    /// Same idea as `patchedFileBytes(replacing:with:)`, but for a record
    /// where only a *leading* fixed-layout portion is being overwritten , 
    /// `Instance`'s 28-byte transform prefix (`WorldPlacementWriter.
    /// writeInstanceTransform`), ahead of its variable-length ID/unknown
    /// lists. Safe for the same reason: the prefix's on-disk size never
    /// changes, so nothing after it, inside this record or later in the
    /// file, needs its offset adjusted. Requires `encoded.count <=
    /// node.byteSize`, not `==`: unlike the fixed-size `Position` case,
    /// `node.byteSize` here is the *whole* variable-length record.
    public func patchedFileBytes(replacingPrefixOf node: ChunkNode, with encoded: Data) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              var bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard encoded.count <= node.byteSize else {
            lastError = "Internal error: encoded prefix is \(encoded.count) bytes, longer than the record's own \(node.byteSize) bytes, refusing to save."
            return nil
        }
        guard node.fileOffset >= 0, node.fileOffset + encoded.count <= bytes.count else {
            lastError = "Internal error: this record's offset is outside its file's bounds."
            return nil
        }
        bytes.replaceSubrange(node.fileOffset..<(node.fileOffset + encoded.count), with: encoded)
        return bytes
    }

    /// The "Save Level Overrides" pipeline: applies every `(node, encoded
    /// prefix)` edit into *one* copy of their shared owning file's bytes,
    /// so moving several objects in the Level Viewer and saving once
    /// produces one consistent file, not one save per object. All edits
    /// must belong to the same standalone-opened file, a level's `Instance`
    /// records always do, since they're read from the same `.RM2`/`.SM2`
    /// the level's `SceneryData` came from, but this still checks rather
    /// than assuming it, since patching the wrong file silently would be
    /// far worse than refusing.
    public func patchedFileBytes(applyingPrefixPatches edits: [(node: ChunkNode, encoded: Data)]) -> Data? {
        guard let first = edits.first,
              let fileRoot = findFileRoot(containing: first.node, in: rootNodes),
              var bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this level's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        for (node, encoded) in edits {
            guard findFileRoot(containing: node, in: rootNodes)?.id == fileRoot.id else {
                lastError = "Internal error: level edits spanned more than one file, refusing to save a partial result."
                return nil
            }
            guard encoded.count <= node.byteSize, node.fileOffset >= 0, node.fileOffset + encoded.count <= bytes.count else {
                lastError = "Internal error: an edited record's offset/size didn't check out, refusing to save."
                return nil
            }
            bytes.replaceSubrange(node.fileOffset..<(node.fileOffset + encoded.count), with: encoded)
        }
        return bytes
    }

    /// "Spline & Camera Path Persistence" (roadmap 6.3): patches one or
    /// more fixed-size edits in at *arbitrary* absolute byte offsets
    /// within a file, rather than at an edited node's own
    /// `node.fileOffset`, needed because a Camera Path/Spline control
    /// point isn't a record of its own; it's a `Vector4` nested somewhere
    /// inside its owning Camera record's variable-length body. `node` is
    /// still required per edit (not just a raw offset) so this can verify
    /// the target offset actually falls inside that record's own real
    /// byte range before writing, a stale/wrong offset silently patching
    /// bytes in an unrelated part of the file is exactly the failure mode
    /// worth refusing outright rather than risking.
    public func patchedFileBytes(applyingAbsoluteByteRangePatches edits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)]) -> Data? {
        guard let first = edits.first,
              let fileRoot = findFileRoot(containing: first.node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this level's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        return applyingAbsoluteByteRangePatches(edits, into: bytes, fileRootID: fileRoot.id)
    }

    /// Shared validate-and-overwrite loop behind
    /// `patchedFileBytes(applyingAbsoluteByteRangePatches:)` and the
    /// combined Level Viewer save path, factored out so the combined path
    /// can fold these patches into the *same* already-in-progress buffer
    /// as the ordinary transform-prefix edits, instead of each patch
    /// function re-reading fresh bytes from `rawFileBytesByRootID` and one
    /// silently discarding the other's edits.
    private func applyingAbsoluteByteRangePatches(_ edits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)], into bytes: Data, fileRootID: UUID) -> Data? {
        var bytes = bytes
        for (node, absoluteOffset, encoded) in edits {
            guard findFileRoot(containing: node, in: rootNodes)?.id == fileRootID else {
                lastError = "Internal error: edits spanned more than one file, refusing to save a partial result."
                return nil
            }
            guard absoluteOffset >= node.fileOffset, absoluteOffset + encoded.count <= node.fileOffset + node.byteSize else {
                lastError = "Internal error: an edited control point's offset fell outside its own record, refusing to save."
                return nil
            }
            guard absoluteOffset >= 0, absoluteOffset + encoded.count <= bytes.count else {
                lastError = "Internal error: an edited control point's offset was outside its file's bounds."
                return nil
            }
            bytes.replaceSubrange(absoluteOffset..<(absoluteOffset + encoded.count), with: encoded)
        }
        return bytes
    }

    /// "Sound Import", the write-back half of Sound Playback: replaces a
    /// per-level `SoundEffect` record's real ADPCM audio bytes with
    /// `encodedADPCM`, patched into the *enclosing section's* trailing
    /// extra-data blob at this sound's own known byte range (see
    /// `SoundEffectAsset.sourceAudioByteRange`'s doc comment for why
    /// that's not within the record's own span, the record itself is
    /// just a 22-byte header). `nil` (with `lastError` set) when `node`
    /// has no `sourceAudioByteRange` (a standalone sound-bank entry, not a
    /// per-level record, no chunk section to patch into), when the
    /// enclosing section can't be found, or when `encodedADPCM` is longer
    /// than the original slot: like every other write path in this app,
    /// this never changes a file's total size, so a replacement that
    /// needs *more* room than the original sound had isn't supported , 
    /// shortening is fine, the unused tail is zero-padded, which
    /// `ADPCMDecoder.toPCMMono` already stops decoding at cleanly once it
    /// reaches the real end-of-stream line the encoder always writes.
    public func replaceSoundEffectAudio(node: ChunkNode, encodedADPCM: Data) -> Data? {
        guard case .soundEffect(let asset) = node.payload, let range = asset.sourceAudioByteRange else {
            lastError = "This sound has no known on-disk location to write back to, only per-level SoundEffect records support replacement, not standalone sound-bank entries."
            return nil
        }
        guard encodedADPCM.count <= range.length else {
            lastError = "This replacement audio encodes to \(encodedADPCM.count) byte(s), but the original only has room for \(range.length), try a shorter clip."
            return nil
        }
        guard let sectionNode = findParent(of: node, in: rootNodes) else {
            lastError = "Couldn't find this sound's enclosing section in the current tree."
            return nil
        }
        var padded = encodedADPCM
        if padded.count < range.length {
            padded.append(Data(repeating: 0, count: range.length - padded.count))
        }
        return patchedFileBytes(applyingAbsoluteByteRangePatches: [(node: sectionNode, absoluteOffset: range.offset, encoded: padded)])
    }

    /// The immediate parent of `target` in the tree, nodes don't carry a
    /// parent pointer (see `findFileRoot`'s own doc comment for why:
    /// replaced, not mutated, elsewhere in this view model), so this is a
    /// plain search.
    private func findParent(of target: ChunkNode, in nodes: [ChunkNode]) -> ChunkNode? {
        for node in nodes {
            if node.children.contains(where: { $0 === target }) { return node }
            if let found = findParent(of: target, in: node.children) { return found }
        }
        return nil
    }

    /// The `.objectInstance` (or, for a Demo file, `.objectInstanceDemo`)
    /// Tier 2 collection in the same file as `levelNode`, "The Forge
    /// Palette"'s (Part 4C/4D) new-Instance insertion target. Distinct from
    /// `instanceRecords(inSameFileAs:)`, which returns the already-decoded
    /// leaf records themselves; this returns the *collection node* those
    /// leaves live under, since that's what `ChunkSectionInserter` needs to
    /// append a new one.
    private func objectInstanceCollectionNode(inSameFileAs levelNode: ChunkNode) -> ChunkNode? {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else { return nil }
        let targetTypes: Set<SectionType> = [.objectInstance, .objectInstanceDemo]
        func walk(_ node: ChunkNode) -> ChunkNode? {
            if targetTypes.contains(node.sectionType) { return node }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// The `.aiPosition` Tier 2 collection in the same file as `levelNode`
    ///, "AI Pathfinding & Navmesh Editor" (roadmap 5.1)'s new-waypoint
    /// insertion target, same role `objectInstanceCollectionNode` plays for
    /// Instance placements. `nil` when the level's own file has no AI
    /// waypoints at all yet, this build only appends to an existing
    /// collection, matching `ChunkSectionInserter`'s own scope (it grows a
    /// section, it doesn't fabricate a brand-new one from nothing).
    private func aiPositionCollectionNode(inSameFileAs levelNode: ChunkNode) -> ChunkNode? {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else { return nil }
        func walk(_ node: ChunkNode) -> ChunkNode? {
            if node.sectionType == .aiPosition, !node.children.isEmpty { return node }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// The `.position` Tier 2 collection in the same file as `node` , 
    /// `PositionInspectorView`'s Add/Duplicate/Delete insertion/removal
    /// target, same role/limitation as `aiPositionCollectionNode`: `nil`
    /// when this file has no `Position` collection at all yet (only grows
    /// an existing one, doesn't fabricate a brand-new section).
    public func positionCollectionNode(inSameFileAs node: ChunkNode) -> ChunkNode? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else { return nil }
        func walk(_ n: ChunkNode) -> ChunkNode? {
            if n.sectionType == .position, !n.children.isEmpty { return n }
            for child in n.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// "PositionEditor" parity, one new record ID higher than every
    /// existing record already in `collection`, matching the same
    /// `(existing.max() ?? 0) + 1` scheme `LevelViewerRenderer`'s
    /// `nextSyntheticInstanceID`/`nextSyntheticTriggerID`/
    /// `nextSyntheticCameraID` seed themselves from, recomputed fresh
    /// from the live tree each call rather than a stored counter, since
    /// `PositionInspectorView` adds/duplicates one record per user action
    /// with no multi-add staging session to keep a counter warm across.
    private func nextAvailableRecordID(in collection: ChunkNode) -> UInt32 {
        (collection.children.map(\.recordID).max() ?? 0) + 1
    }

    /// Appends one brand-new `Position` record (id one past every existing
    /// one in this file's `.position` collection), real structural
    /// insertion via `ChunkSectionInserter`, same generic path the Forge
    /// Palette trusts for Instance/Trigger/Camera placement. `nil` (with
    /// `lastError` set) when this file has no existing `Position`
    /// collection to grow.
    public func patchedFileBytes(insertingPosition point: SIMD4<Float>, inSameFileAs node: ChunkNode) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = positionCollectionNode(inSameFileAs: node) else {
            lastError = "Can't add a Position here, this file has no existing Position collection this build recognizes."
            return nil
        }
        let newID = nextAvailableRecordID(in: collection)
        let encoded = WorldPlacementWriter.writePosition(PositionMarker(id: newID, point: point))
        guard let result = ChunkSectionInserter.insertingRecord(id: newID, encoded: encoded, into: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely insert the new Position into the file structure, refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    /// Removes one existing `Position` record, the deletion counterpart
    /// to `patchedFileBytes(insertingPosition:inSameFileAs:)`. `nil` (with
    /// `lastError` set) when `node` isn't actually a `Position` record, or
    /// its containing collection can't be found.
    public func patchedFileBytes(removingPosition node: ChunkNode) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = parent(of: node, inAnyOf: rootNodes) else {
            lastError = "Internal error: couldn't find this record's containing section, refusing to save a possibly-corrupt result."
            return nil
        }
        guard let result = ChunkSectionInserter.removingRecord(id: node.recordID, from: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely remove this Position from the file structure, refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    /// The `.object`/`.objectDemo` collection in the same file as `node`
    ///, `GameObjectEditorSheet`'s "New Blank Object"/"Duplicate"/"Delete"
    /// insertion/removal target, same role/limitation as
    /// `positionCollectionNode`: `nil` when this file has no `GameObject`
    /// collection at all yet.
    public func gameObjectCollectionNode(inSameFileAs node: ChunkNode) -> ChunkNode? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else { return nil }
        let targetTypes: Set<SectionType> = [.object, .objectDemo]
        func walk(_ n: ChunkNode) -> ChunkNode? {
            if targetTypes.contains(n.sectionType), !n.children.isEmpty { return n }
            for child in n.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// "ObjectEditor" parity, the reference's own `createObjectToolStripMenuItem_Click`/
    /// `duplicateObjectToolStripMenuItem_Click` ID scheme exactly:
    /// `max(8192, every existing ID in this collection) + 1`. The 8192
    /// floor keeps new custom objects out of the range real game content
    /// actually uses, same as the reference tool does.
    private func nextGameObjectID(in collection: ChunkNode) -> UInt32 {
        max(8192, collection.children.map(\.recordID).max() ?? 0) + 1
    }

    /// Inserts `object` (with a fresh ID one past every existing
    /// `GameObject` in this file, or `object.id` itself if the caller
    /// already assigned one, `duplicatingGameObject` needs that so it can
    /// show the caller which ID landed before saving) into this file's
    /// `.object`/`.objectDemo` collection. `nil` (with `lastError` set)
    /// when this file has no existing collection to grow.
    public func patchedFileBytes(insertingGameObject object: GameObjectInfo, inSameFileAs node: ChunkNode) -> (data: Data, insertedID: UInt32)? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = gameObjectCollectionNode(inSameFileAs: node) else {
            lastError = "Can't add a GameObject here, this file has no existing GameObject collection this build recognizes."
            return nil
        }
        let newID = nextGameObjectID(in: collection)
        let withNewID = GameObjectInfo(
            id: newID, name: object.name, ogiIDs: object.ogiIDs, unkBitfield: object.unkBitfield,
            ui32: object.ui32, animIDs: object.animIDs, scriptIDs: object.scriptIDs,
            objectIDs: object.objectIDs, soundIDs: object.soundIDs,
            instanceProperties: object.instanceProperties, linkedIDs: object.linkedIDs,
            scriptCommands: object.scriptCommands
        )
        let encoded = GameObjectWriter.encode(withNewID)
        guard let result = ChunkSectionInserter.insertingRecord(id: newID, encoded: encoded, into: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely insert the new GameObject into the file structure, refusing to save a possibly-corrupt result."
            return nil
        }
        return (result, newID)
    }

    /// Removes one existing `GameObject` record, the deletion
    /// counterpart to `patchedFileBytes(insertingGameObject:inSameFileAs:)`.
    public func patchedFileBytes(removingGameObject node: ChunkNode) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = parent(of: node, inAnyOf: rootNodes) else {
            lastError = "Internal error: couldn't find this record's containing section, refusing to save a possibly-corrupt result."
            return nil
        }
        guard let result = ChunkSectionInserter.removingRecord(id: node.recordID, from: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely remove this GameObject from the file structure, refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    /// "IDEditor" parity, ports the reference editor's own `IDEditor.
    /// button1_Click` exactly: reassigns `node`'s ID *in place*, by
    /// patching only the 4-byte `id` field of its own entry in the
    /// containing section's index table
    /// (`Magic(4)+RecordCount(4)+ContentSize(4)` header, then
    /// `{offset(4), size(4), id(4)}` per entry, in on-disk order, see
    /// `ChunkSectionInserter`'s own doc comment for this exact layout).
    /// Nothing else moves: the record's own bytes, its position in the
    /// section, and every other entry are untouched, the same minimal
    /// diff the reference's own `RecordIDs.Remove`/`Add` produces (it
    /// swaps a dictionary key, never touches the physical `Records` list
    /// order). Deliberately narrow, matching the reference tool's own
    /// real behavior rather than a "fixed" version of it: nothing else in
    /// the file that references the old ID by value (an `Instance.
    /// objectID`, a `Trigger.instanceIDs` entry, a script slot, ...) gets
    /// updated, the reference editor's own `IDEditor` doesn't chase
    /// those down either. `nil` (with `lastError` set) when `newID`
    /// already exists in the same section (the reference's own "New ID
    /// already exists" refusal) or `node` has no containing section.
    public func patchedFileBytes(reassigningIDOf node: ChunkNode, to newID: UInt32) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let section = parent(of: node, inAnyOf: rootNodes) else {
            lastError = "Internal error: couldn't find this record's containing section, refusing to save a possibly-corrupt result."
            return nil
        }
        guard newID != node.recordID else { return bytes } // matches the reference: "if ID == DataID, Close()", a same-value rename is a no-op, not an error.
        guard !section.children.contains(where: { $0.recordID == newID }) else {
            lastError = "A record with ID \(newID) already exists in this section, the reference editor refuses this too (\"New ID already exists\")."
            return nil
        }
        guard let entryIndex = section.children.firstIndex(where: { $0 === node }) else {
            lastError = "Internal error: this record isn't actually a child of its own containing section, refusing to save a possibly-corrupt result."
            return nil
        }
        let idFieldOffset = section.fileOffset + 12 + entryIndex * 12 + 8
        guard idFieldOffset >= 0, idFieldOffset + 4 <= bytes.count else {
            lastError = "Internal error: this record's index-table entry falls outside its file's bounds."
            return nil
        }
        var writer = BinaryWriter()
        writer.writeUInt32(newID)
        var patched = bytes
        patched.replaceSubrange((bytes.startIndex + idFieldOffset)..<(bytes.startIndex + idFieldOffset + 4), with: writer.data)
        return patched
    }

    /// The `.aiPath` Tier 2 collection in the same file as `node` , 
    /// `AIPathInspectorView`'s Add/Duplicate/Delete insertion/removal
    /// target, same role/limitation as `positionCollectionNode`.
    public func aiPathCollectionNode(inSameFileAs node: ChunkNode) -> ChunkNode? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else { return nil }
        func walk(_ n: ChunkNode) -> ChunkNode? {
            if n.sectionType == .aiPath, !n.children.isEmpty { return n }
            for child in n.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// Public wrapper over `aiPositionCollectionNode` , 
    /// `AIPositionInspectorView`'s Add/Duplicate/Delete target. The
    /// private helper stays as-is (still used internally by the Forge
    /// Palette's combined save path); this just exposes the same lookup
    /// to a plain inspector sheet that isn't part of that combined flow.
    public func aiWaypointCollectionNode(inSameFileAs node: ChunkNode) -> ChunkNode? {
        aiPositionCollectionNode(inSameFileAs: node)
    }

    /// Inserts one brand-new `AIPosition` waypoint (id one past every
    /// existing one in this file's `.aiPosition` collection) via
    /// `ChunkSectionInserter`, same insertion path the Forge Palette's
    /// own "Add Waypoint" trusts, exposed here for `AIPositionInspectorView`
    /// to call directly (immediate insert-and-save, not staged).
    public func patchedFileBytes(insertingAIPosition position: SIMD4<Float>, rawNodeType: UInt16, inSameFileAs node: ChunkNode) -> (data: Data, insertedID: UInt32)? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = aiWaypointCollectionNode(inSameFileAs: node) else {
            lastError = "Can't add an AI waypoint here, this file has no existing AIPosition collection this build recognizes."
            return nil
        }
        let newID = (collection.children.map(\.recordID).max() ?? 0) + 1
        let encoded = WorldPlacementWriter.writeAIPosition(position: position, rawNodeType: rawNodeType)
        guard let result = ChunkSectionInserter.insertingRecord(id: newID, encoded: encoded, into: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely insert the new AI waypoint into the file structure, refusing to save a possibly-corrupt result."
            return nil
        }
        return (result, newID)
    }

    public func patchedFileBytes(removingAIPosition node: ChunkNode) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = parent(of: node, inAnyOf: rootNodes) else {
            lastError = "Internal error: couldn't find this record's containing section, refusing to save a possibly-corrupt result."
            return nil
        }
        guard let result = ChunkSectionInserter.removingRecord(id: node.recordID, from: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely remove this AI waypoint from the file structure, refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    /// Same insertion/removal shape as the AIPosition pair above, for
    /// `AIPathInspectorView`'s `.aiPath` collection.
    public func patchedFileBytes(insertingAIPath args: [UInt16], inSameFileAs node: ChunkNode) -> (data: Data, insertedID: UInt32)? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = aiPathCollectionNode(inSameFileAs: node) else {
            lastError = "Can't add an AI path here, this file has no existing AIPath collection this build recognizes."
            return nil
        }
        let newID = (collection.children.map(\.recordID).max() ?? 0) + 1
        let encoded = WorldPlacementWriter.writeAIPath(args)
        guard let result = ChunkSectionInserter.insertingRecord(id: newID, encoded: encoded, into: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely insert the new AI path into the file structure, refusing to save a possibly-corrupt result."
            return nil
        }
        return (result, newID)
    }

    public func patchedFileBytes(removingAIPath node: ChunkNode) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here, this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = parent(of: node, inAnyOf: rootNodes) else {
            lastError = "Internal error: couldn't find this record's containing section, refusing to save a possibly-corrupt result."
            return nil
        }
        guard let result = ChunkSectionInserter.removingRecord(id: node.recordID, from: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely remove this AI path from the file structure, refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    // MARK: - "Place Scenery From Another Level"

    /// Every already-open standalone `.sm2`/`.smx` file root this session
    /// that has at least one real, decoded `SceneryData` placement.
    /// `sceneryLevelSources` is the real candidate list "Add Scenery From
    /// Other Level…"'s picker uses, this stays a separate, narrower
    /// property because `placingSceneryFromAnotherLevel`'s *destination*
    /// side still needs "already open, byte-tracked" specifically (see
    /// `canSaveEdits`'s own doc comment on why every edit feature in this
    /// build requires that).
    public var otherLevelSceneryFileRoots: [ChunkNode] {
        rootNodes.filter { root in
            root.displayName.lowercased().hasSuffix(".sm2") || root.displayName.lowercased().hasSuffix(".smx")
        }.filter { root in
            sceneryNode(in: root) != nil
        }
    }

    /// The real `SceneryData` node inside `fileRoot`, if any.
    public func sceneryNode(in fileRoot: ChunkNode) -> ChunkNode? {
        func walk(_ node: ChunkNode) -> ChunkNode? {
            if case .scenery = node.payload { return node }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// The `.rm2`/`.rmx` file root already open this session whose base
    /// filename matches `sm2Root`'s own, real scenery geometry
    /// (`RigidModel`/`Material`/`Texture`/`Model`) lives in a level's
    /// paired `.rm2`, not its `.sm2` (confirmed against real disc data , 
    /// see `CrossFileModelCopierTests`' own doc comment), the same real
    /// pairing `loadSoundBankAsync` already applies to `.MH`/`.MB`. `nil`
    /// if that sibling isn't *also* already open, this doesn't reach
    /// into the archive to open it automatically.
    public func pairedGraphicsFileRoot(for sm2Root: ChunkNode) -> ChunkNode? {
        // Same bare-filename normalization bug class documented on
        // `LevelDisplayNameMatching`, `displayName` is a full archive
        // path ("Levels/Earth/Hub/beach.sm2") for any level reached by
        // browsing a mounted disc/archive, not just a bare filename. Real,
        // reported bug this caused: placing scenery copied from another
        // level failed with "its destination graphics file isn't one of
        // this level's own currently-open files" even when the current
        // level's own paired `.rm2` genuinely *was* already open , 
        // comparing a full-path `baseName` against a bare `rootBase` (or
        // vice versa) never matched, so this fell through to the "read
        // straight from the archive" fallback in `resolvingGraphicsRoot`,
        // handing back a `ChunkNode` that isn't in `rootNodes` at all and
        // that `patchedFileBytes`'s save-time scenery-copy resolution can
        // never recognize as one of this level's own tracked files.
        let baseName = ((sm2Root.displayName as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        return rootNodes.first { root in
            let rootBase = ((root.displayName as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            let ext = (root.displayName as NSString).pathExtension.lowercased()
            return rootBase == baseName && (ext == "rm2" || ext == "rmx")
        }
    }

    /// One entry in "Add Scenery From Other Level…"'s level picker, either
    /// an already-open standalone `.sm2`/`.smx` (`openFileRoot`, resolved
    /// through the existing byte-tracked path), or a real `.sm2`/`.smx`
    /// entry sitting in a *mounted* archive that's never been opened at all
    /// (`archiveRootID`/`sceneryEntryName`/`graphicsEntryName`), read
    /// straight off the archive on demand in `loadingSceneryLevelSource`,
    /// same as `siblingActorFileRoot`/`loadChunkLinkActors` already read
    /// sibling files without requiring them pre-opened. This is the real
    /// fix for "the button is always greyed out": most levels a user wants
    /// to borrow scenery from were never individually opened as loose
    /// files, they're just sitting in the mounted `.BD`, which this now
    /// browses directly instead of requiring that manual step first.
    public struct SceneryLevelSource: Identifiable, Hashable {
        public var id: String
        public var displayName: String
        public var openFileRoot: ChunkNode?
        public var archiveRootID: UUID?
        public var sceneryEntryName: String?
        public var graphicsEntryName: String?

        public static func == (lhs: SceneryLevelSource, rhs: SceneryLevelSource) -> Bool { lhs.id == rhs.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Every real source level "Add Scenery From Other Level…" can borrow
    /// from: already-open standalone files first, then every other
    /// `.sm2`/`.smx` archive entry (across every mounted archive) that has
    /// a real sibling `.rm2`/`.rmx` in the same archive, the geometry a
    /// scenery placement actually needs lives there (see
    /// `pairedGraphicsFileRoot`'s own doc comment). Excludes the
    /// destination level itself so it doesn't offer to borrow scenery from
    /// the very file being edited.
    public func sceneryLevelSources(excluding destinationSceneryFileRoot: ChunkNode?) -> [SceneryLevelSource] {
        var seenNames = Set<String>()
        var results: [SceneryLevelSource] = []
        // Normalized to bare filename to match the (now also
        // bare-normalized, see below) keys inserted by the
        // `otherLevelSceneryFileRoots` loop, `destinationSceneryFileRoot`
        // is exactly the disc/archive-browsed case whose `displayName` can
        // be a full path, and an un-normalized exclusion key here would
        // silently stop excluding the destination level from its own
        // "borrow scenery from another level" picker.
        if let excludedName = destinationSceneryFileRoot?.displayName {
            seenNames.insert((excludedName as NSString).lastPathComponent.lowercased())
        }

        for root in otherLevelSceneryFileRoots {
            // Real bug this fixes: `root.displayName` is the FULL archive
            // path (e.g. "Levels/Earth/Cavern/cavent") for a level reached
            // by browsing into a mounted disc/archive, not just the bare
            // filename, used raw here, unlike the archive-index branch
            // below which already normalizes via `lastPathComponent`. That
            // inconsistency broke both `seenNames` de-duplication against
            // the archive-index branch (this bare/full-path key wouldn't
            // match the other branch's) and every downstream exact-match
            // comparison against `SceneryLevelSource.displayName`, see
            // `LevelDisplayNameMatching`'s own doc comment for the
            // Scenery-mode/Quick-Launch symptoms this same class of bug
            // caused. Bare filename is robust to both shapes.
            let bareDisplayName = (root.displayName as NSString).lastPathComponent
            let key = bareDisplayName.lowercased()
            guard seenNames.insert(key).inserted else { continue }
            results.append(SceneryLevelSource(id: key, displayName: bareDisplayName, openFileRoot: root))
        }

        for (rootID, index) in archiveIndexByRootID {
            // Real, reported performance bug: this used to call
            // `siblingActorEntryName(forSceneryEntryName:in:)`, a linear
            // scan of *every* entry in the archive, once per `.sm2`/`.smx`
            // entry, then did a *second* full linear scan to confirm the
            // sibling exists. For a full archive (hundreds of scenery files
            // among thousands of total entries) that's O(scenery-count ×
            // total-entries), easily millions of string comparisons, paid
            // every time the Scenery tab opens. One lowercased-name lookup
            // table, built once per archive, turns both scans into O(1)
            // dictionary lookups.
            let entriesByLowercasedName = Dictionary(index.entries.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            for entry in index.entries {
                let ext = (entry.name as NSString).pathExtension.lowercased()
                guard ext == "sm2" || ext == "smx" else { continue }
                let key = entry.name.lowercased()
                guard !seenNames.contains(key) else { continue }
                let targetExt = ext == "sm2" ? "rm2" : "rmx"
                let base = (entry.name as NSString).deletingPathExtension
                guard let sibling = entriesByLowercasedName["\(base).\(targetExt)".lowercased()] else { continue }
                seenNames.insert(key)
                results.append(SceneryLevelSource(
                    id: key, displayName: (entry.name as NSString).lastPathComponent,
                    archiveRootID: rootID, sceneryEntryName: entry.name, graphicsEntryName: sibling.name
                ))
            }
        }
        return results.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// A `.sm2`/`.smx` file root's own real, parsed graphics root and raw
    /// bytes, its paired `.rm2`/`.rmx` if already open and byte-tracked,
    /// falling back to reading it straight off the same mounted archive
    /// `sceneryFileRoot` itself came from. Shared by both sides of "Add
    /// Scenery From Other Level…": the *source* level (via
    /// `loadingSceneryLevelSource`) and the *destination* level currently
    /// open in the Level Viewer (`placingSceneryFromAnotherLevel`'s own
    /// caller resolves this before invoking it), the destination side
    /// used to only check `rawFileBytesByRootID` directly, which silently
    /// failed whenever the current level was reached by browsing a mounted
    /// archive rather than manually opening a loose file pair, a real bug.
    private func resolvingGraphicsRoot(for sceneryFileRoot: ChunkNode) async -> (graphicsRoot: ChunkNode, graphicsBytes: Data)? {
        if let graphicsRoot = pairedGraphicsFileRoot(for: sceneryFileRoot), let graphicsBytes = rawFileBytesByRootID[graphicsRoot.id] {
            return (graphicsRoot, graphicsBytes)
        }
        guard let rootID = owningArchiveRootID(of: sceneryFileRoot), let index = archiveIndexByRootID[rootID],
              let graphicsName = Self.siblingActorEntryName(forSceneryEntryName: sceneryFileRoot.displayName, in: index.entries),
              let graphicsEntry = index.entries.first(where: { $0.name.caseInsensitiveCompare(graphicsName) == .orderedSame })
        else {
            lastError = "\(sceneryFileRoot.displayName)'s paired .rm2/.rmx isn't available, it's not open, and isn't sitting in the same mounted archive."
            return nil
        }
        // Real, reported bug: this used to read the entry directly
        // (`BDArchiveParser.readEntryData` + a one-off parse) and hand back
        // a `ChunkNode` that was never actually inserted into `rootNodes`
        // at all, fine for reading its bytes *right now*, but broken for
        // any later consumer that needs this exact node to still be
        // `findFileRoot`-reachable, which the save-time cross-level-scenery
        // validation (`patchedFileBytes`) requires. Reusing
        // `expandArchiveEntry`, the same real "open this archive entry"
        // path a sidebar click already uses, and the same fix
        // `siblingActorFileRoot` already applied to an identical problem , 
        // makes this a genuinely open, tree-connected file instead of a
        // disconnected read, and also means a level visited twice this
        // session doesn't re-parse its graphics file from scratch each time.
        guard let placeholder = Self.findArchiveEntryPlaceholder(named: graphicsEntry.name, in: rootNodes) else {
            lastError = "\(sceneryFileRoot.displayName)'s paired .rm2/.rmx isn't available, it's not open, and isn't sitting in the same mounted archive."
            return nil
        }
        if placeholder.payload == nil, placeholder.children.isEmpty {
            await expandArchiveEntry(placeholder, rootID: rootID)
        }
        guard let expanded = Self.findArchiveEntryPlaceholder(named: graphicsEntry.name, in: rootNodes),
              let bytes = rawFileBytesByRootID[expanded.id]
        else {
            lastError = "\(sceneryFileRoot.displayName)'s paired .rm2/.rmx couldn't be opened."
            return nil
        }
        return (expanded, bytes)
    }

    /// Resolves one `SceneryLevelSource` into its real, parsed scenery root
    /// plus its real, parsed graphics root and raw bytes, reading straight
    /// off a mounted archive when the source isn't already an open file.
    /// Deliberately doesn't touch `rootNodes`/`rawFileBytesByRootID`: same
    /// read-only posture `siblingActorFileRoot`'s own doc comment already
    /// establishes for a stitched neighbor's data, this is browsing another
    /// level's geometry to copy *from*, not opening it for editing.
    /// `sceneryBytes` alongside `sceneryRoot`, needed because a scenery
    /// placement's `modelID` doesn't reliably resolve against the same file
    /// on every level: real archive evidence has both shapes (`hubb.sm2`
    /// carries its *own* embedded Graphics section that every one of its
    /// 462 real placements resolves against, with its paired `hubb.rm2`
    /// resolving none of them; other levels, see `CrossFileModelCopierTests`'
    /// own real-disc test, carry no Graphics data of their own and rely
    /// entirely on their paired `.rm2`). `placingSceneryFromAnotherLevel`
    /// tries the level's own scenery-file graphics first (matching
    /// `resolvedSceneryCatalog`'s already-verified resolution source, which
    /// is what actually proved this `modelID` copyable to begin with), then
    /// falls back to the paired `.rm2`, so it needs both files' real bytes
    /// on hand, not just the paired one.
    public func loadingSceneryLevelSource(_ source: SceneryLevelSource) async -> (sceneryRoot: ChunkNode, sceneryBytes: Data, graphicsRoot: ChunkNode, graphicsBytes: Data)? {
        if let openRoot = source.openFileRoot {
            guard let sceneryBytes = rawFileBytesByRootID[openRoot.id] else { return nil }
            guard let (graphicsRoot, graphicsBytes) = await resolvingGraphicsRoot(for: openRoot) else { return nil }
            return (openRoot, sceneryBytes, graphicsRoot, graphicsBytes)
        }

        guard let rootID = source.archiveRootID, let index = archiveIndexByRootID[rootID],
              let sceneryName = source.sceneryEntryName, let graphicsName = source.graphicsEntryName,
              let sceneryEntry = index.entries.first(where: { $0.name == sceneryName }),
              let graphicsEntry = index.entries.first(where: { $0.name.caseInsensitiveCompare(graphicsName) == .orderedSame })
        else {
            lastError = "\(source.displayName) isn't in a mounted archive anymore."
            return nil
        }
        return await Task.detached(priority: .userInitiated) { () -> (ChunkNode, Data, ChunkNode, Data)? in
            guard let sceneryData = try? BDArchiveParser.readEntryData(sceneryEntry, index: index),
                  let sceneryRoot = try? Self.mainTreeDriver(forExtension: (sceneryEntry.name as NSString).pathExtension).parseChunkFile(data: sceneryData, fileKind: Self.fileKind(forEntryNamed: sceneryEntry.name), fileName: sceneryEntry.name),
                  let graphicsData = try? BDArchiveParser.readEntryData(graphicsEntry, index: index),
                  let graphicsRoot = try? Self.mainTreeDriver(forExtension: (graphicsEntry.name as NSString).pathExtension).parseChunkFile(data: graphicsData, fileKind: Self.fileKind(forEntryNamed: graphicsEntry.name), fileName: graphicsEntry.name)
            else { return nil }
            return (sceneryRoot, sceneryData, graphicsRoot, graphicsData)
        }.value
    }

    /// One real, distinct model this level places, resolved into a real
    /// `ResolvedModelAsset` so the picker can render an actual thumbnail , 
    /// the same `AssetResolver.resolveModelID` call `resolvedLevelPlacements`
    /// already uses for the live viewport, not a re-derived resolution path.
    public struct SceneryCatalogEntry: Identifiable {
        public var id: String { "\(modelID)-\(isSpecial)" }
        public var modelID: UInt32
        public var isSpecial: Bool
        public var count: Int
        public var asset: ResolvedModelAsset
    }

    /// Every distinct real model placed in `sceneryRoot`, resolved against
    /// `sceneryRoot`'s *own* Graphics data, the click-to-place catalog for
    /// one picked source level.
    ///
    /// Previously built its index from a separate paired `graphicsRoot`
    /// (`.rm2`) parameter instead, on the assumption scenery geometry lived
    /// there. Verified empirically against the real disc archive
    /// (`Levels/Earth/Hub/hubb.sm2`/`hubb.rm2`): every one of `hubb.sm2`'s
    /// real 462 scenery placements resolves against `hubb.sm2`'s own
    /// Graphics section (245 `RigidModel`s / 80 `LodModel`s); *none*
    /// resolve against `hubb.rm2`'s (which carries the level's Instance/
    /// Trigger/Camera/AI data instead, see `resolvedLevelPlacements`'s own
    /// doc comment, independently confirming `.rm2` has "zero scenery").
    /// Building the index from the wrong file made every `resolveModelID`
    /// call fail, so this panel always reported zero placements regardless
    /// of how much real scenery a level actually had, the viewport
    /// rendered fine the whole time because `resolvedLevelPlacements`
    /// already indexed the scenery file itself. This now matches that
    /// working code path exactly, and the now-unnecessary `graphicsRoot`
    /// parameter (its only call site, in `LevelViewerWindow`, still has the
    /// paired `.rm2` handy for other reasons -- see `SceneryLevelSource`'s
    /// "Add Scenery From Other Level" use of it -- but no real scenery
    /// model ever needed it here) was dropped rather than kept unused.
    public func resolvedSceneryCatalog(sceneryRoot: ChunkNode) async -> [SceneryCatalogEntry] {
        guard let sceneryNode = sceneryNode(in: sceneryRoot), case .scenery(let asset)? = sceneryNode.payload else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let index = AssetResolver.buildIndex(fileRoot: sceneryRoot)
            var byKey: [String: SceneryCatalogEntry] = [:]
            for placement in asset.placements {
                let key = "\(placement.modelID)-\(placement.isSpecial)"
                if byKey[key] != nil {
                    byKey[key]?.count += 1
                } else if let resolved = AssetResolver.resolveModelID(placement.modelID, displayName: "Model #\(placement.modelID)", index: index) {
                    byKey[key] = SceneryCatalogEntry(modelID: placement.modelID, isSpecial: placement.isSpecial, count: 1, asset: resolved)
                }
            }
            return byKey.values.sorted { $0.modelID < $1.modelID }
        }.value
    }

    /// "Add Scenery From Other Level…", the full cross-file operation:
    /// copies `modelID`/`isSpecial`'s real `RigidModel` chain from
    /// `sourceGraphicsRoot` (the source level's `.rm2`) into the
    /// *destination* level's own paired `.rm2`, then inserts one new,
    /// real, non-special `SceneryModelPlacement` (at `position`,
    /// referencing the freshly-copied `RigidModel`) into the destination
    /// level's `.sm2` `SceneryData` tree, two files, two separate saves,
    /// since the geometry and the placement genuinely live in different
    /// files. Real insertion, same non-aggregated-bbox reasoning
    /// `SceneryModelPlacement.matrixFileOffset`'s doc comment and
    /// `SceneryDataWriter`'s own doc comment establish: always joins the
    /// tree's *root* group directly (no group-level bounding box exists to
    /// maintain, so nesting depth is a spatial-culling optimization this
    /// doesn't need to replicate for a modded placement to render
    /// correctly).
    public struct CrossLevelSceneryPlacementResult {
        public var graphicsFileRoot: ChunkNode
        public var graphicsBytes: Data
        public var sceneryFileRoot: ChunkNode
        public var sceneryBytes: Data
    }

    /// Places another copy of a model *this level's own file already
    /// resolves*, the same-file counterpart to `placingSceneryFromAnotherLevel`,
    /// with no cross-file geometry copy at all: `modelID`/`isSpecial` are
    /// reused exactly as-is, since the placement they came from already
    /// proves that reference resolves here. One file, one save. Real
    /// insertion into the tree's root group, same reasoning as the
    /// cross-level version's own doc comment.
    public func duplicatingSceneryPlacement(modelID: UInt32, isSpecial: Bool, position: SIMD4<Float>, sceneryFileRoot: ChunkNode) -> Data? {
        guard let sceneryNode = sceneryNode(in: sceneryFileRoot),
              case .scenery(let sceneryAsset)? = sceneryNode.payload,
              var root = sceneryAsset.root
        else {
            lastError = "This level has no real SceneryData tree this build recognizes."
            return nil
        }
        // Real, reported bug (same root cause `LevelViewerRenderer.
        // localAABBCorners(of:)`'s own doc comment documents for the
        // primary Scenery-tab placement path): every real, on-disk
        // `SceneryModelPlacement.boundingBoxMin`/`Max` is LOCAL, centered
        // on the placement's own origin, not offset by its real world
        // position (confirmed: a real placement at world position
        // `(105.6, 5.1, 13.2)` carries a bbox of exactly `(-9.1,-16.3,-9.1)`
        // to `(9.1,16.3,9.1)`, `min == -max` exactly). Writing
        // `position ± 1` here wrote a wildly mislocated bbox for any
        // duplicate placed away from the level's own local origin, same
        // class of bug, just never reached by the fix that already
        // covered the main placement path.
        let newPlacement = SceneryModelPlacement(
            modelID: modelID, isSpecial: isSpecial,
            boundingBoxMin: SIMD4<Float>(-1, -1, -1, 0), boundingBoxMax: SIMD4<Float>(1, 1, 1, 0),
            modelMatrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), position]
        )
        let insertIndex = root.model.placements.firstIndex(where: { $0.isSpecial }) ?? root.model.placements.count
        root.model.placements.insert(newPlacement, at: insertIndex)
        root.model.header = 0x1613
        var mutatedScenery = sceneryAsset
        mutatedScenery.root = root
        let encoded = SceneryDataWriter.encode(mutatedScenery)
        return patchedFileBytes(replacingWholeRecord: sceneryNode, with: encoded)
    }

    /// The public entry point for resolving the *destination* level's
    /// graphics root/bytes before calling `placingSceneryFromAnotherLevel`
    ///, the same archive-reaching fallback `loadingSceneryLevelSource`
    /// uses for the source side, now shared by the destination side too.
    public func loadingDestinationGraphics(for sceneryFileRoot: ChunkNode) async -> (graphicsRoot: ChunkNode, graphicsBytes: Data)? {
        await resolvingGraphicsRoot(for: sceneryFileRoot)
    }

    public func placingSceneryFromAnotherLevel(
        modelID: UInt32, isSpecial: Bool, position: SIMD4<Float>,
        sourceSceneryFileRoot: ChunkNode, sourceSceneryBytes: Data,
        sourceGraphicsRoot: ChunkNode, sourceGraphicsBytes: Data,
        destinationSceneryFileRoot: ChunkNode,
        destinationGraphicsRoot: ChunkNode, destinationGraphicsBytes: Data
    ) -> CrossLevelSceneryPlacementResult? {
        guard let sceneryNode = sceneryNode(in: destinationSceneryFileRoot),
              case .scenery(let sceneryAsset)? = sceneryNode.payload,
              var root = sceneryAsset.root
        else {
            lastError = "The destination level has no real SceneryData tree this build recognizes."
            return nil
        }

        // Real evidence a scenery `modelID` doesn't reliably live in the
        // same file on every level: `resolvedSceneryCatalog` (which is what
        // actually proved this `modelID`/`isSpecial` pair resolves to real
        // geometry, for the thumbnail the user clicked) builds its index
        // from the level's *own* scenery-file Graphics section, not its
        // paired `.rm2`, confirmed against real disc data (`hubb.sm2`: all
        // 462 real placements resolve there, none via `hubb.rm2`). Other
        // real levels carry no Graphics data of their own and genuinely
        // need the paired `.rm2` (`CrossFileModelCopierTests`' own real-disc
        // test). Trying the level's own file first matches what actually
        // proved this placement copyable; falling back to the paired
        // `.rm2` covers the other real shape instead of failing outright.
        let copyResult: CrossFileModelCopier.CopyResult
        do {
            copyResult = try CrossFileModelCopier.copyingRigidModelChain(
                modelID: modelID, isSpecial: isSpecial,
                sourceFileRoot: sourceSceneryFileRoot, sourceBytes: sourceSceneryBytes,
                destinationFileRoot: destinationGraphicsRoot, destinationBytes: destinationGraphicsBytes
            )
        } catch {
            do {
                copyResult = try CrossFileModelCopier.copyingRigidModelChain(
                    modelID: modelID, isSpecial: isSpecial,
                    sourceFileRoot: sourceGraphicsRoot, sourceBytes: sourceGraphicsBytes,
                    destinationFileRoot: destinationGraphicsRoot, destinationBytes: destinationGraphicsBytes
                )
            } catch {
                lastError = "Couldn't copy the source model's geometry: \(error.localizedDescription)"
                return nil
            }
        }

        // Same local-not-world bbox bug `duplicatingSceneryPlacement`'s own
        // doc comment documents, fixed the same way.
        let newPlacement = SceneryModelPlacement(
            modelID: copyResult.rigidModelID, isSpecial: false,
            boundingBoxMin: SIMD4<Float>(-1, -1, -1, 0), boundingBoxMax: SIMD4<Float>(1, 1, 1, 0),
            modelMatrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), position]
        )
        let insertIndex = root.model.placements.firstIndex(where: { $0.isSpecial }) ?? root.model.placements.count
        root.model.placements.insert(newPlacement, at: insertIndex)
        root.model.header = 0x1613
        var mutatedScenery = sceneryAsset
        mutatedScenery.root = root
        let encodedScenery = SceneryDataWriter.encode(mutatedScenery)

        guard let sceneryBytes = patchedFileBytes(replacingWholeRecord: sceneryNode, with: encodedScenery) else {
            return nil // lastError already set
        }

        return CrossLevelSceneryPlacementResult(
            graphicsFileRoot: destinationGraphicsRoot, graphicsBytes: copyResult.destinationBytes,
            sceneryFileRoot: destinationSceneryFileRoot, sceneryBytes: sceneryBytes
        )
    }

    /// The `.trigger` Tier 2 collection in the same file as `levelNode` , 
    /// "Add Trigger"'s insertion/removal target, same role
    /// `aiPositionCollectionNode` plays for waypoints. Same "must already
    /// have at least one real Trigger" limitation: a chunk with zero
    /// existing triggers has no `.trigger` node in the tree to target,
    /// matching the AI-waypoint case's own documented behavior rather than
    /// inventing new whole-section creation.
    private func triggerCollectionNode(inSameFileAs levelNode: ChunkNode) -> ChunkNode? {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else { return nil }
        func walk(_ node: ChunkNode) -> ChunkNode? {
            if node.sectionType == .trigger, !node.children.isEmpty { return node }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// The `.camera`/`.cameraDemo` Tier 2 collection in the same file as
    /// `levelNode`, "Add Camera"'s insertion/removal target. Returns which
    /// of the two section kinds was actually found alongside the node,
    /// since `WorldPlacementWriter.writeNewCamera(isDemo:)` needs to match
    /// it (`.cameraDemo` omits `UnkShort`/`UnkByte`, per `Camera.cs`'s own
    /// `ParentType == SectionType.CameraDemo` check).
    private func cameraCollectionNode(inSameFileAs levelNode: ChunkNode) -> (node: ChunkNode, isDemo: Bool)? {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else { return nil }
        let targetTypes: Set<SectionType> = [.camera, .cameraDemo]
        func walk(_ node: ChunkNode) -> ChunkNode? {
            if targetTypes.contains(node.sectionType), !node.children.isEmpty { return node }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        guard let found = walk(fileRoot) else { return nil }
        return (found, found.sectionType == .cameraDemo)
    }

    /// Result of `patchedFileBytes(applyingPrefixPatches:...)`, split into
    /// two independent files because scenery genuinely can't always be
    /// folded into the same bytes as everything else. Real, disc-verified
    /// fact this type exists to respect: a level's `SceneryData` almost
    /// always lives in a *different* archive entry (`.sm2`) than its
    /// Instance/Trigger/Camera/AIPosition/AIPath records (`.rm2`), see
    /// `openLevelViewer`'s own doc comment ("`hubb.sm2` has 462 scenery
    /// placements and zero instances/triggers/cameras; `hubb.rm2` has
    /// 114/7/11/22/21 of those and zero scenery"). Treating scenery as
    /// just another edit folded into `levelNode`'s own bytes, this type's
    /// entire reason for existing, silently found no `SceneryData` record
    /// at all for that (by far the most common) case and failed the whole
    /// combined save, not only the scenery part of it.
    public struct LevelOverridePatch {
        /// `levelNode`'s own file, every non-scenery edit, plus scenery
        /// edits too on the rare level whose `SceneryData` genuinely lives
        /// in the same file.
        public var primaryBytes: Data
        /// The scenery file's own patched bytes, present only when there
        /// were pending scenery edits *and* the scenery record lives in a
        /// file distinct from `levelNode`'s own. `nil` otherwise, no
        /// pending scenery edits, or (the same-file case) already folded
        /// into `primaryBytes`.
        public var sceneryBytes: Data?
        /// `sceneryBytes`'s own archive entry display name (e.g.
        /// `"beach.sm2"`), callers writing `sceneryBytes` anywhere archive-
        /// entry-keyed (`GameLaunchPlan.archiveReplacements`) need this to
        /// address the right entry. `nil` exactly when `sceneryBytes` is.
        public var sceneryFileDisplayName: String?

        public init(primaryBytes: Data, sceneryBytes: Data? = nil, sceneryFileDisplayName: String? = nil) {
            self.primaryBytes = primaryBytes
            self.sceneryBytes = sceneryBytes
            self.sceneryFileDisplayName = sceneryFileDisplayName
        }
    }

    /// "Backend Requirement: safely inject this new record" (Part 4D) +
    /// "AI Pathfinding & Navmesh Editor" (roadmap 5.1), the combined save
    /// path "Save Chunk Overrides…" uses. `transformEdits` (a mix of
    /// Instance transform patches and AI waypoint patches, both are just
    /// fixed-size `(node, encoded)` prefix patches, so they compose freely
    /// in one list) are applied first since they never change any record's
    /// size; then every new Instance is appended into the Instance
    /// collection, then every new AI waypoint into the AIPosition
    /// collection, each insertion building on the previous step's
    /// already-patched bytes, so one "Save" produces one file reflecting
    /// every edit and every placement together, not a save-per-change
    /// sequence. Deliberately has no matching "remove a waypoint" path:
    /// shrinking a section's record count safely is real, separate work
    /// `ChunkSectionInserter` doesn't do today (only growth), so waypoint
    /// deletion stays session-only rather than risk a rushed, unverified
    /// shrink operation.
    public func patchedFileBytes(
        applyingPrefixPatches transformEdits: [(node: ChunkNode, encoded: Data)],
        applyingAbsoluteByteRangePatches controlPointEdits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] = [],
        applyingSceneryTransformPatches sceneryTransformEdits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] = [],
        insertingNewInstances newInstances: [(id: UInt32, encoded: Data)],
        insertingNewAIPositions newAIPositions: [(id: UInt32, encoded: Data)],
        insertingNewTriggers newTriggers: [(id: UInt32, encoded: Data)] = [],
        insertingNewCameras newCameras: [(id: UInt32, encoded: Data)] = [],
        insertingNewAIPaths newAIPaths: [(id: UInt32, encoded: Data)] = [],
        removingInstanceIDs: [UInt32] = [],
        removingTriggerIDs: [UInt32] = [],
        removingCameraIDs: [UInt32] = [],
        removingAIPositionIDs: [UInt32] = [],
        removingAIPathIDs: [UInt32] = [],
        insertingNewScenery newScenery: [(modelID: UInt32, isSpecial: Bool, position: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>)] = [],
        removingSceneryOffsets: [Int] = [],
        insertingNewCrossLevelScenery crossLevelScenery: [(source: CrossLevelSceneryGeometrySource, position: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>)] = [],
        insertingCrossLevelGameObjects crossLevelGameObjects: [CrossLevelGameObjectSource] = [],
        insertingPropSkinSpawns propSkinSpawns: [PropSkinSpawnSource] = [],
        applyingPlayerCharacterSwap playerCharacterSwap: PlayableCharacterOption? = nil,
        replacingCollisionRecord: (node: ChunkNode, encoded: Data)? = nil,
        sceneryFileNode: ChunkNode? = nil,
        levelNode: ChunkNode
    ) -> LevelOverridePatch? {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else {
            lastError = "Can't save edits here, this chunk's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }

        // `sceneryTransformEdits` (an *existing* on-disk scenery placement's
        // moved/rotated/scaled matrix) needs the scenery file's own root
        // resolved up front, same as every other scenery operation below , 
        // real levels almost always keep `SceneryData` in a different file
        // than `levelNode`'s own (see `LevelOverridePatch`'s doc comment),
        // so these overwrites can't just assume `fileRoot` is the right
        // target. Resolved only when actually needed (any real scenery edit
        // is pending, or a control-point edit's own node turns out to live
        // outside `fileRoot`) so a caller with no scenery context at all (no
        // `sceneryFileNode`, nothing scenery-related pending) never pays
        // for, or can fail on, a lookup it never asked for.
        //
        // Real, reported bug: `controlPointEdits` (Camera/Trigger Path
        // control points) used to be assumed *always* safe against
        // `fileRoot` alone, wrong for the same reason the doc comment
        // right below this one already documents for scenery:
        // `openLevelViewer` combines Camera/Trigger records from *both* a
        // level's scenery file and its sibling actor file (see its own
        // "instanceMarkers += instanceRecords(inSameFileAs: siblingNode)"-
        // style combining), so a real on-disk Camera/Trigger control point
        // can just as easily live in the *other* file as `fileRoot` itself.
        // On a level where that's true, dragging that control point and
        // saving threw exactly "edits spanned more than one file , 
        // refusing to save a partial result", the same failure mode the
        // scenery-specific fix below already exists to prevent, just for
        // a different edit kind that never got the same treatment.
        let needsSceneryFileRoot = !sceneryTransformEdits.isEmpty || !newScenery.isEmpty || !removingSceneryOffsets.isEmpty || !crossLevelScenery.isEmpty
            || controlPointEdits.contains { findFileRoot(containing: $0.node, in: rootNodes)?.id != fileRoot.id }
        var sceneryFileRoot: ChunkNode? = nil
        var sceneryIsSameFileAsLevelNode = false
        if needsSceneryFileRoot {
            let sceneryAnchor = sceneryFileNode ?? levelNode
            guard let resolvedSceneryFileRoot = findFileRoot(containing: sceneryAnchor, in: rootNodes) else {
                lastError = "Can't save scenery edits here, its file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
                return nil
            }
            sceneryFileRoot = resolvedSceneryFileRoot
            sceneryIsSameFileAsLevelNode = resolvedSceneryFileRoot.id == fileRoot.id
        }

        let afterTransformEdits: Data?
        if transformEdits.isEmpty {
            afterTransformEdits = rawFileBytesByRootID[fileRoot.id]
        } else {
            afterTransformEdits = patchedFileBytes(applyingPrefixPatches: transformEdits)
        }
        guard var currentBytes = afterTransformEdits else { return nil }

        // Control-point patches are, like `transformEdits`, pure fixed-size
        // overwrites, folded into the *same* pre-insertion buffer for the
        // same reason `ChunkSectionInserter`'s own doc comment gives for
        // never chaining two single-target insert passes: `insertingRecords`
        // below rebuilds sections using the *original* tree's node offsets
        // against whatever buffer it's handed, so any patch must land
        // before that rebuild runs, not after (an insertion changes total
        // file length and shifts everything downstream of it; an overwrite
        // never does, so overwrites are always safe to apply first).
        // Split by which real file each control point's own node actually
        // lives in, matching `sceneryTransformEdits`' own routing right
        // below, instead of assuming every one belongs to `fileRoot`.
        let controlPointEditsInFileRoot = controlPointEdits.filter { findFileRoot(containing: $0.node, in: rootNodes)?.id == fileRoot.id }
        let controlPointEditsInSceneryFile = controlPointEdits.filter { findFileRoot(containing: $0.node, in: rootNodes)?.id != fileRoot.id }
        if !controlPointEditsInFileRoot.isEmpty {
            guard let afterControlPointEdits = applyingAbsoluteByteRangePatches(controlPointEditsInFileRoot, into: currentBytes, fileRootID: fileRoot.id) else { return nil }
            currentBytes = afterControlPointEdits
        }

        // Real bug this fixes: scenery-transform overwrites used to be
        // folded into `controlPointEdits` above and checked against
        // `fileRoot.id` unconditionally, correct only on the rare level
        // whose `SceneryData` happens to live in the same file as its
        // Instance/Trigger/Camera records. On a normal split-file level
        // (scenery in `.sm2`, everything else in `.rm2`), that per-edit
        // guard saw a node belonging to a *different* file root and threw
        // "edits spanned more than one file," refusing to save *any*
        // pending edit at all, including unrelated Instance/Trigger
        // changes bundled into the same save. When scenery genuinely lives
        // in its own file, these overwrites land in that file's own bytes
        // instead, independently of `currentBytes`; `sceneryBytesFromTransformEdits`
        // carries the result down to the scenery section below so it
        // becomes the starting point there instead of raw untouched bytes.
        //
        // `controlPointEditsInSceneryFile` (see above) joins the same list:
        // a Camera/Trigger control point whose own node lives in the
        // scenery file needs exactly the same routing `sceneryTransformEdits`
        // already gets, not a separate pass, both are plain
        // `(node, absoluteOffset, encoded)` overwrites into the same buffer.
        var sceneryBytesFromTransformEdits: Data? = nil
        let sceneryFileOverwrites = sceneryTransformEdits + controlPointEditsInSceneryFile
        if !sceneryFileOverwrites.isEmpty, let sceneryFileRoot {
            if sceneryIsSameFileAsLevelNode {
                guard let afterSceneryTransformEdits = applyingAbsoluteByteRangePatches(sceneryFileOverwrites, into: currentBytes, fileRootID: fileRoot.id) else { return nil }
                currentBytes = afterSceneryTransformEdits
            } else {
                guard let rawSceneryBytes = rawFileBytesByRootID[sceneryFileRoot.id] else {
                    lastError = "Can't save scenery edits here, this chunk's scenery file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
                    return nil
                }
                guard let afterSceneryTransformEdits = applyingAbsoluteByteRangePatches(sceneryFileOverwrites, into: rawSceneryBytes, fileRootID: sceneryFileRoot.id) else { return nil }
                sceneryBytesFromTransformEdits = afterSceneryTransformEdits
            }
        }

        let hasInsertions = !newInstances.isEmpty || !newAIPositions.isEmpty || !newTriggers.isEmpty || !newCameras.isEmpty || !newAIPaths.isEmpty
        let hasRemovals = !removingInstanceIDs.isEmpty || !removingTriggerIDs.isEmpty || !removingCameraIDs.isEmpty || !removingAIPositionIDs.isEmpty || !removingAIPathIDs.isEmpty
        let hasCollisionReplacement = replacingCollisionRecord != nil
        // `!removingSceneryOffsets.isEmpty` must be part of this guard too , 
        // a scenery-deletion-only save (nothing else pending) used to fall
        // through here and return unmodified bytes, silently skipping the
        // scenery step below entirely: the UI reported "1 deleted object(s)"
        // saved successfully while the file on disk stayed byte-identical.
        // `sceneryBytesFromTransformEdits != nil` must be part of it too , 
        // a scenery-move-only save on a split-file level has nothing else
        // pending either, and that patched buffer would otherwise be
        // discarded here instead of reaching the scenery section below
        // that actually returns it as `LevelOverridePatch.sceneryBytes`.
        // `!sceneryTransformEdits.isEmpty` must be part of this guard too , 
        // see the later, identically-reasoned guard right before the
        // scenery rebuild section below for why a *same-file* move-only
        // save (where `sceneryBytesFromTransformEdits` stays nil) still
        // needs to reach that section instead of returning early here.
        guard hasInsertions || hasRemovals || hasCollisionReplacement || !newScenery.isEmpty || !removingSceneryOffsets.isEmpty || !crossLevelScenery.isEmpty || !crossLevelGameObjects.isEmpty || !propSkinSpawns.isEmpty || (playerCharacterSwap != nil && playerCharacterSwap!.id != 0) || !sceneryTransformEdits.isEmpty || sceneryBytesFromTransformEdits != nil else {
            return LevelOverridePatch(primaryBytes: currentBytes)
        }

        // Every insertion *and* removal goes through the *one* multi-target
        // rebuild (`applyingRecordChanges(intoSections:...)`), never
        // sequential single-target calls, `.objectInstance`/`.trigger`/
        // `.camera`/`.aiPosition` are all siblings under the same
        // `.instance` container in real files, so calling separate passes
        // would rebuild each later pass's ancestor chain from the
        // *original* tree's offsets against a buffer an earlier pass had
        // already resized, silently corrupting the result. See that
        // function's own doc comment.
        var targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)], removeIDs: [UInt32])] = []

        // "Cross-Level Forge Placement": folded into the *same* combined
        // rebuild as everything else in `targets` below, never a separate,
        // earlier `ChunkSectionInserter` call (this file's own doc comment
        // just above explains why that would be unsafe). Best-effort per
        // object: a real, disclosed limitation (a non-skinned/`modelLinks`
        // object, or a source that genuinely doesn't resolve) skips just
        // that one object rather than failing this entire save, the
        // Instance record for it still gets written either way, exactly
        // the pre-existing "won't actually spawn" behavior for that one
        // object, not a new way for an unrelated edit to fail.
        //
        // Fresh IDs (`CrossFileGameObjectCopier.resolvingSkinnedGameObjectInsertions`'s
        // own `additionalClaimedIDs`) are threaded across objects since
        // neither call mutates `fileRoot`'s tree, see that function's own
        // doc comment for exactly why that's required to avoid two
        // different objects' copies claiming the same fresh OGI/Skin/
        // Material/Texture ID. Same-section insertions across objects are
        // merged by node identity before being appended to `targets`, a
        // real, caught-during-testing bug: `ChunkSectionInserter.
        // applyingRecordChanges` only rebuilds the *first* `targets` entry
        // for a given section and silently skips any later one targeting
        // that same node, so two objects both landing in (say) the same
        // Object collection must arrive as *one* merged entry, not two.
        if !crossLevelGameObjects.isEmpty {
            var claimed: (ogi: Set<UInt32>, skin: Set<UInt32>, material: Set<UInt32>, texture: Set<UInt32>, script: Set<UInt32>, animation: Set<UInt32>) = ([], [], [], [], [], [])
            var mergedBySection: [ObjectIdentifier: (section: ChunkNode, insert: [(id: UInt32, encoded: Data)])] = [:]
            for source in crossLevelGameObjects {
                do {
                    let resolved = try CrossFileGameObjectCopier.resolvingSkinnedGameObjectInsertions(
                        objectID: source.objectID, sourceFileRoot: source.sourceFileRoot, sourceBytes: source.sourceBytes,
                        destinationFileRoot: fileRoot, additionalClaimedIDs: claimed
                    )
                    claimed.ogi.insert(resolved.claimedIDs.ogi)
                    claimed.skin.insert(resolved.claimedIDs.skin)
                    claimed.material.formUnion(resolved.claimedIDs.material)
                    claimed.texture.formUnion(resolved.claimedIDs.texture)
                    claimed.script.formUnion(resolved.claimedIDs.script)
                    claimed.animation.formUnion(resolved.claimedIDs.animation)
                    for target in resolved.targets {
                        let key = ObjectIdentifier(target.section)
                        mergedBySection[key, default: (target.section, [])].insert.append(contentsOf: target.insert)
                    }
                } catch CrossFileGameObjectCopier.CopyError.gameObjectAlreadyPresent {
                    continue // already real in the destination, nothing to do
                } catch {
                    continue // real, disclosed limitation, see this block's own doc comment
                }
            }
            targets.append(contentsOf: mergedBySection.values.map { (section: $0.section, insert: $0.insert, removeIDs: []) })
        }

        // "Spawn Interactive Cortex (Prop)", same merge-by-section
        // discipline as the `crossLevelGameObjects` block just above, and
        // for the identical reason: `ChunkSectionInserter.
        // applyingRecordChanges` only rebuilds the *first* `targets` entry
        // per section, so two spawns both touching (say) the Object
        // collection must arrive as one merged entry.
        if !propSkinSpawns.isEmpty {
            var claimed: (ogi: Set<UInt32>, skin: Set<UInt32>, material: Set<UInt32>, texture: Set<UInt32>) = ([], [], [], [])
            var mergedBySection: [ObjectIdentifier: (section: ChunkNode, insert: [(id: UInt32, encoded: Data)])] = [:]
            for source in propSkinSpawns {
                do {
                    let resolved = try CrossFileGameObjectCopier.resolvingPropSkinInsertion(
                        freshObjectID: source.freshObjectID, baseGameObject: source.baseGameObject,
                        skinSourceObjectID: source.skinSourceObjectID, skinSourceFileRoot: source.skinSourceFileRoot, skinSourceBytes: source.skinSourceBytes,
                        destinationFileRoot: fileRoot, additionalClaimedIDs: claimed
                    )
                    claimed.ogi.insert(resolved.claimedIDs.ogi)
                    claimed.skin.insert(resolved.claimedIDs.skin)
                    claimed.material.formUnion(resolved.claimedIDs.material)
                    claimed.texture.formUnion(resolved.claimedIDs.texture)
                    for target in resolved.targets {
                        let key = ObjectIdentifier(target.section)
                        mergedBySection[key, default: (target.section, [])].insert.append(contentsOf: target.insert)
                    }
                } catch CrossFileGameObjectCopier.CopyError.gameObjectAlreadyPresent {
                    continue // already real in the destination, nothing to do
                } catch {
                    lastError = "Couldn't spawn the interactive Cortex prop: \(error.localizedDescription)"
                    return nil
                }
            }
            targets.append(contentsOf: mergedBySection.values.map { (section: $0.section, insert: $0.insert, removeIDs: []) })
        }

        // "Play As" (Advanced panel): replaces whichever character
        // currently occupies `GameObject` id 0 with a real, verified
        // alternate character's own rig, see `PlayableCharacterOption`'s
        // and `CrossFileGameObjectCopier.resolvingPlayerCharacterReplacement`'s
        // own doc comments for why id 0 specifically, and why each
        // catalog entry points at the *real* playable rig rather than a
        // thin generic-NPC cameo of the same character. Same "merge into
        // any already-pending target for the same section" discipline as
        // `crossLevelGameObjects`/`propSkinSpawns` just above, a swap can
        // land in the very same Object collection those already touched.
        if let playerCharacterSwap, playerCharacterSwap.id != 0 {
            guard let archiveRootID = owningArchiveRootID(of: fileRoot), let archiveIndex = archiveIndexByRootID[archiveRootID],
                  let sourceEntry = archiveIndex.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare(playerCharacterSwap.sourceFileBaseName) == .orderedSame }),
                  let sourceBytes = try? BDArchiveParser.readEntryData(sourceEntry, index: archiveIndex),
                  let sourceRoot = try? Self.mainTreeDriver(forExtension: (sourceEntry.name as NSString).pathExtension).parseChunkFile(data: sourceBytes, fileKind: Self.fileKind(forEntryNamed: sourceEntry.name), fileName: sourceEntry.name)
            else {
                lastError = "Couldn't find \(playerCharacterSwap.displayName)'s own real character data (\(playerCharacterSwap.sourceFileBaseName)) on the mounted disc, nothing was changed."
                return nil
            }
            do {
                let resolved = try CrossFileGameObjectCopier.resolvingPlayerCharacterReplacement(
                    replacingObjectID: 0, withRealCharacter: playerCharacterSwap.id,
                    sourceFileRoot: sourceRoot, sourceBytes: sourceBytes, destinationFileRoot: fileRoot
                )
                var mergedBySection: [ObjectIdentifier: (section: ChunkNode, insert: [(id: UInt32, encoded: Data)], removeIDs: [UInt32])] = [:]
                for target in resolved.targets {
                    let key = ObjectIdentifier(target.section)
                    mergedBySection[key, default: (target.section, [], [])].insert.append(contentsOf: target.insert)
                    mergedBySection[key]!.removeIDs.append(contentsOf: target.removeIDs)
                }
                targets.append(contentsOf: mergedBySection.values)
            } catch {
                lastError = "Couldn't replace the level's player character with \(playerCharacterSwap.displayName): \(error.localizedDescription)"
                return nil
            }
        }

        if !newInstances.isEmpty || !removingInstanceIDs.isEmpty {
            guard let collectionNode = objectInstanceCollectionNode(inSameFileAs: levelNode) else {
                lastError = "Can't place or remove objects here, this chunk's file has no Instance collection this build recognizes."
                return nil
            }
            targets.append((collectionNode, newInstances, removingInstanceIDs))
        }
        if !newAIPositions.isEmpty || !removingAIPositionIDs.isEmpty {
            guard let collectionNode = aiPositionCollectionNode(inSameFileAs: levelNode) else {
                lastError = "Can't add or remove AI waypoints here, this chunk's file has no existing AIPosition collection."
                return nil
            }
            targets.append((collectionNode, newAIPositions, removingAIPositionIDs))
        }
        if !newTriggers.isEmpty || !removingTriggerIDs.isEmpty {
            guard let collectionNode = triggerCollectionNode(inSameFileAs: levelNode) else {
                lastError = "Can't add or remove triggers here, this chunk's file has no existing Trigger collection to add into."
                return nil
            }
            targets.append((collectionNode, newTriggers, removingTriggerIDs))
        }
        if !newCameras.isEmpty || !removingCameraIDs.isEmpty {
            guard let collection = cameraCollectionNode(inSameFileAs: levelNode) else {
                lastError = "Can't add or remove cameras here, this chunk's file has no existing Camera collection to add into."
                return nil
            }
            targets.append((collection.node, newCameras, removingCameraIDs))
        }
        if !newAIPaths.isEmpty || !removingAIPathIDs.isEmpty {
            guard let collectionNode = aiPathCollectionNode(inSameFileAs: levelNode) else {
                lastError = "Can't add or remove AI paths here, this chunk's file has no existing AIPath collection."
                return nil
            }
            targets.append((collectionNode, newAIPaths, removingAIPathIDs))
        }
        // "Auto-Update Collision on Add/Delete" (real, reported bug, see
        // `LevelCollisionRebuilder`'s own doc comment): a rebuilt `ColData`
        // record is a *whole-record replacement*, same shape as
        // `patchedFileBytes(replacingWholeRecord:with:)` (insert the new
        // encoded bytes under the record's own existing `recordID`, remove
        // that same ID first), joining the *same* multi-target rebuild as
        // Instance/Trigger/Camera/AIPosition/AIPath above, for the identical
        // reason their own doc comment gives: a separate, later pass would
        // rebuild this record's ancestor chain from the *original* tree's
        // offsets against a buffer the earlier passes already resized,
        // silently corrupting the result. `ColData` lives in the same actor
        // file as Instance/Trigger/Camera (confirmed: `collisionMeshRecords`'
        // own doc comment, "ColData only lives in .RM2 actor files"), so
        // its containing section is resolved the same way `fileRoot` itself
        // was, not against a second, separate file root.
        if let replacingCollisionRecord {
            guard let collisionSection = parent(of: replacingCollisionRecord.node, inAnyOf: rootNodes) else {
                lastError = "Internal error: couldn't find the collision record's containing section, refusing to save a possibly-corrupt result."
                return nil
            }
            targets.append((collisionSection, [(replacingCollisionRecord.node.recordID, replacingCollisionRecord.encoded)], [replacingCollisionRecord.node.recordID]))
        }

        guard let afterCollectionChanges = ChunkSectionInserter.applyingRecordChanges(intoSections: targets, fileRoot: fileRoot, originalFileBytes: currentBytes) else {
            lastError = "Internal error: couldn't safely apply the record change(s) to the file structure, refusing to save a possibly-corrupt result."
            return nil
        }
        currentBytes = afterCollectionChanges
        // `!sceneryTransformEdits.isEmpty` must be part of this guard too , 
        // a *same-file* scenery move already lands in `currentBytes` above
        // via the plain 64-byte matrix patch (`sceneryBytesFromTransformEdits`
        // stays nil for that case), but that move's real new position can
        // carry the moved placement outside its containing group's
        // `unkPos` culling bound. Without also entering the section below
        // for this case, that bound is left stale. This function only runs
        // at real save time (Quick Launch, Save Chunk Overrides, Save
        // In-Place, quit-time autosave), never per-drag-frame, so
        // re-entering the fuller scenery rebuild here on every move-only
        // save is not a hot path.
        guard !newScenery.isEmpty || !removingSceneryOffsets.isEmpty || !crossLevelScenery.isEmpty || !sceneryTransformEdits.isEmpty || sceneryBytesFromTransformEdits != nil else {
            return LevelOverridePatch(primaryBytes: currentBytes)
        }

        // Scenery placements can't join `targets` above in the same
        // `applyingRecordChanges` call: `SceneryData` is a tier-0 record
        // whose containing section *is* the file root itself (see
        // `RM2Parser.tier0Kind`'s doc comment), so it would have to be a
        // *direct* target on `fileRoot`, but `applyingRecordChanges`'s own
        // `rebuild(_:)` short-circuits the instant `fileRoot` matches a
        // direct target, returning that rebuild's own result without ever
        // recursing into fileRoot's *other* children to also pick up a
        // nested target's change (like the Instance/Trigger collection
        // insert above). Combining them in one call would silently discard
        // whichever change isn't fileRoot's own direct target. Applying
        // scenery as a genuinely separate, later step avoids that.
        //
        // Which file actually owns the SceneryData record: `sceneryFileNode`
        // when the caller supplied one (every real Level Viewer save site
        // does, see `LevelViewerContext.sceneryNode`'s own doc comment),
        // else `levelNode` itself for a caller with no scenery context at
        // all (a bare `SceneryData`-in-the-same-file scenario, or a test).
        // For a real, normally-split level these are two *different* files
        //, `.sm2` carries scenery, `.rm2` carries everything else this
        // function's other parameters edit, so this reads and rebuilds
        // the scenery file's own bytes independently rather than assuming
        // it's reachable through `currentBytes`/`fileRoot`, which used to
        // silently find no SceneryData record at all for that case and
        // fail the *entire* combined save, not only the scenery part.
        // `sceneryFileRoot`/`sceneryIsSameFileAsLevelNode` were already
        // resolved up front (`needsSceneryFileRoot`), reaching this line at
        // all requires one of `sceneryTransformEdits`/`newScenery`/
        // `removingSceneryOffsets`/`crossLevelScenery` to be non-empty
        // (both guards above), every one of which sets `needsSceneryFileRoot`,
        // so `sceneryFileRoot` is guaranteed non-nil here.
        guard let sceneryFileRoot else {
            lastError = "Internal error: reached scenery structural changes with no scenery file resolved."
            return nil
        }
        // A same-file save reuses the *already-edited* `currentBytes` (so a
        // scenery edit composes with the Instance/Trigger/etc changes above
        // in one buffer, same as before); a different-file save starts from
        // `sceneryBytesFromTransformEdits` when a pending scenery-transform
        // edit already patched that file's bytes above, or else fresh from
        // that file's own last-known-good bytes, since nothing above this
        // point has touched it at all.
        guard var sceneryOriginalBytes = sceneryIsSameFileAsLevelNode ? currentBytes : (sceneryBytesFromTransformEdits ?? rawFileBytesByRootID[sceneryFileRoot.id]) else {
            lastError = "Can't save scenery edits here, this chunk's scenery file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }

        // "Live Cross-Level Scenery Placement," the deferred half: the
        // actual `CrossFileModelCopier` byte copy happens here, at save
        // time, never at placement time, see `CrossLevelSceneryGeometrySource`'s
        // own doc comment for why. Must run *before* `freshSceneryRoot`
        // below re-parses `sceneryOriginalBytes`: a copy landing in the
        // scenery file mutates `sceneryOriginalBytes` right here, and that
        // re-parse has to see the grown buffer, not the pre-copy one.
        // Each entry gets its own fresh re-parse of whichever buffer it
        // targets (not just one re-parse up front) since an earlier
        // entry's copy in this same loop already changed that buffer's
        // size, reusing a tree parsed before that would be exactly the
        // stale-offsets bug this function's own established "re-parse
        // before continuing" convention exists to prevent.
        var resolvedCrossLevelPlacements: [(modelID: UInt32, position: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>)] = []
        for entry in crossLevelScenery {
            guard let destinationOwnerRoot = findFileRoot(containing: entry.source.destinationGraphicsRoot, in: rootNodes),
                  destinationOwnerRoot.id == sceneryFileRoot.id || destinationOwnerRoot.id == fileRoot.id
            else {
                lastError = "Can't place scenery copied from another level here, its destination graphics file isn't one of this level's own currently-open files."
                return nil
            }
            let targetsScenery = destinationOwnerRoot.id == sceneryFileRoot.id
            let targetRoot = targetsScenery ? sceneryFileRoot : fileRoot
            let targetBytes = targetsScenery ? sceneryOriginalBytes : currentBytes
            guard let freshTargetRoot = try? Self.mainTreeDriver(forExtension: (targetRoot.displayName as NSString).pathExtension).parseChunkFile(data: targetBytes, fileKind: Self.fileKind(forEntryNamed: targetRoot.displayName), fileName: targetRoot.displayName) else {
                lastError = "Can't place scenery copied from another level here, its destination file's structure isn't one this build recognizes."
                return nil
            }
            // Same "try the source's own embedded Graphics first, fall
            // back to the paired .rm2" real evidence `placingSceneryFromAnotherLevel`
            // documents.
            let copyResult: CrossFileModelCopier.CopyResult
            do {
                copyResult = try CrossFileModelCopier.copyingRigidModelChain(
                    modelID: entry.source.sourceModelID, isSpecial: entry.source.sourceIsSpecial,
                    sourceFileRoot: entry.source.sourceSceneryFileRoot, sourceBytes: entry.source.sourceSceneryBytes,
                    destinationFileRoot: freshTargetRoot, destinationBytes: targetBytes
                )
            } catch {
                do {
                    copyResult = try CrossFileModelCopier.copyingRigidModelChain(
                        modelID: entry.source.sourceModelID, isSpecial: entry.source.sourceIsSpecial,
                        sourceFileRoot: entry.source.sourceGraphicsRoot, sourceBytes: entry.source.sourceGraphicsBytes,
                        destinationFileRoot: freshTargetRoot, destinationBytes: targetBytes
                    )
                } catch {
                    lastError = "Couldn't copy the source model's geometry: \(error.localizedDescription)"
                    return nil
                }
            }
            if targetsScenery {
                sceneryOriginalBytes = copyResult.destinationBytes
            } else {
                currentBytes = copyResult.destinationBytes
            }
            resolvedCrossLevelPlacements.append((copyResult.rigidModelID, entry.position, entry.rotation, entry.scale))
        }

        // Only safe because of this re-parse: reusing `sceneryAnchor`'s
        // existing (pre-edit) tree here would carry exactly the archive-
        // relative-vs-standalone-byte-coordinate mismatch this session's
        // scenery-placement fix exists to prevent, since `sceneryOriginalBytes`
        // may already differ in size (and therefore every downstream
        // offset) from whatever tree `sceneryAnchor` was originally parsed
        // against, once the Instance/Trigger/etc changes above ran (same-
        // file case) or an earlier save in this session ran (either case).
        // A real, genuinely pre-*this-save* baseline (before the scenery-
        // transform patch above, before any insert/remove below), used
        // only to scope the `unkPos` recompute at the bottom of this
        // function to the groups this specific save actually touched. See
        // `SceneryGroup.recomputingUnkPos(sinceEditFrom:)`'s own doc
        // comment. Computed *before* the guard right below introduces its
        // own local `sceneryNode` binding, which would otherwise shadow
        // the `sceneryNode(in:)` method this closure also needs to call.
        let sceneryBaselineRootForUnkPosDiff: SceneryGroup? = {
            guard let baselineBytes = rawFileBytesByRootID[sceneryFileRoot.id],
                  let baselineTree = try? Self.mainTreeDriver(forExtension: (sceneryFileRoot.displayName as NSString).pathExtension).parseChunkFile(data: baselineBytes, fileKind: Self.fileKind(forEntryNamed: sceneryFileRoot.displayName), fileName: sceneryFileRoot.displayName),
                  let baselineSceneryNode = sceneryNode(in: baselineTree),
                  case .scenery(let baselineAsset)? = baselineSceneryNode.payload
            else { return nil }
            return baselineAsset.root
        }()
        guard let freshSceneryRoot = try? Self.mainTreeDriver(forExtension: (sceneryFileRoot.displayName as NSString).pathExtension).parseChunkFile(data: sceneryOriginalBytes, fileKind: Self.fileKind(forEntryNamed: sceneryFileRoot.displayName), fileName: sceneryFileRoot.displayName),
              let sceneryNode = sceneryNode(in: freshSceneryRoot),
              case .scenery(let sceneryAsset)? = sceneryNode.payload,
              var root = sceneryAsset.root
        else {
            lastError = "Can't place scenery here, this chunk's file has no real SceneryData tree this build recognizes."
            return nil
        }
        if !removingSceneryOffsets.isEmpty {
            root = root.removingPlacements(withFileOffsets: Set(removingSceneryOffsets))
        }
        for placement in newScenery {
            let matrix = SceneryModelPlacement.composingModelMatrix(position: placement.position, rotation: placement.rotation, scale: placement.scale)
            // Real, reported bug ("phases in and out of reality" / vanishes
            // entirely in-game): this used to hardcode a `position ± 1`
            // placeholder box here regardless of the real model's actual
            // size, `LevelViewerRenderer.pendingNewScenery` now computes
            // and hands over the real, rotated/scaled/translated world-space
            // AABB (the same `worldAABBCorners` math the ColData collision
            // rebuild already trusted for this exact object), so a placed
            // object's own declared bounding box actually matches its mesh.
            let newPlacement = SceneryModelPlacement(
                modelID: placement.modelID, isSpecial: placement.isSpecial,
                boundingBoxMin: SIMD4<Float>(placement.boundsMin, 1), boundingBoxMax: SIMD4<Float>(placement.boundsMax, 1),
                modelMatrix: matrix
            )
            // See `SceneryGroup.insertingPlacementNearestExistingNeighbor`'s
            // own doc comment: real, reported bug, a freshly-placed
            // scenery object always went straight into the tree's own
            // top-level root, bypassing whatever real, dev-authored
            // spatial grouping (and group-level visibility bound data this
            // project has never decoded) every real placement nearby
            // already has.
            root = root.insertingPlacementNearestExistingNeighbor(newPlacement, targetPosition: placement.position)
        }
        // Same "resolves straight to the concrete RigidModel, always
        // non-special" simplification `CrossFileModelCopier` itself
        // documents, the copy already resolved past any LodModel
        // indirection, so the new placement points directly at it.
        for placement in resolvedCrossLevelPlacements {
            let matrix = SceneryModelPlacement.composingModelMatrix(position: placement.position, rotation: placement.rotation, scale: placement.scale)
            // Same local-not-world bbox bug `duplicatingSceneryPlacement`'s
            // own doc comment documents, fixed the same way.
            let newPlacement = SceneryModelPlacement(
                modelID: placement.modelID, isSpecial: false,
                boundingBoxMin: SIMD4<Float>(-1, -1, -1, 0), boundingBoxMax: SIMD4<Float>(1, 1, 1, 0),
                modelMatrix: matrix
            )
            let insertIndex = root.model.placements.firstIndex(where: { $0.isSpecial }) ?? root.model.placements.count
            root.model.placements.insert(newPlacement, at: insertIndex)
        }
        root.model.header = 0x1613
        // Real, reported bug ("placed scenery pops in and out of existence
        // depending purely on camera angle in a real PCSX2 boot"): a group
        // touched by an insert/remove/move just now keeps whatever `unkPos`
        // group-level culling bound it had *before* this edit, stale
        // relative to its new real membership. See
        // `SceneryGroup.recomputingUnkPos(sinceEditFrom:)`'s own doc
        // comment, this preserves every changed group's real, original
        // axis/orientation exactly, only expanding the shared radius, and
        // touches nothing at all in any group this edit didn't reach.
        if let sceneryBaselineRootForUnkPosDiff {
            root = root.recomputingUnkPos(sinceEditFrom: sceneryBaselineRootForUnkPosDiff)
        }
        var mutatedScenery = sceneryAsset
        mutatedScenery.root = root
        let encodedScenery = SceneryDataWriter.encode(mutatedScenery)
        guard let afterScenery = ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: freshSceneryRoot, insert: [(sceneryNode.recordID, encodedScenery)], removeIDs: [sceneryNode.recordID])],
            fileRoot: freshSceneryRoot, originalFileBytes: sceneryOriginalBytes
        ) else {
            lastError = "Internal error: couldn't safely apply the record change to the file structure, refusing to save a possibly-corrupt result."
            return nil
        }
        if sceneryIsSameFileAsLevelNode {
            return LevelOverridePatch(primaryBytes: afterScenery)
        }
        return LevelOverridePatch(primaryBytes: currentBytes, sceneryBytes: afterScenery, sceneryFileDisplayName: sceneryFileRoot.displayName)
    }

    /// Whether the destination `.camera` collection for `levelNode` is the
    /// Demo layout (`WorldPlacementWriter.writeNewCamera(isDemo:)` needs to
    /// match it), `nil` when there's no existing Camera collection to add
    /// into yet, same limitation `cameraCollectionNode` itself documents.
    public func cameraCollectionIsDemo(inSameFileAs levelNode: ChunkNode) -> Bool? {
        cameraCollectionNode(inSameFileAs: levelNode)?.isDemo
    }

    /// Packages an edited file's patched bytes (see `patchedFileBytes`) into
    /// a real, installable `CrateModLoader` `.crate`, the "Crate Mod
    /// Loader & Multi-Game Packager" export path (blueprint 3.3), built on
    /// top of the one record type this build can actually write edits back
    /// to (see `PositionInspectorView`'s doc comment).
    ///
    /// - Parameter settings: Optional `modcratesettings.txt` key/value pairs
    ///   (see `ModCrateSettings`), defaulting to none. This app has no
    ///   general "mod property/settings" registry to populate these from
    ///   (its editing model is per-record-type inspectors, not
    ///   CrateModLoader's own global Mod Menu property list), this
    ///   parameter is real, tested file-format/crate plumbing, wired
    ///   through as an inert pass-through for whichever caller has an
    ///   actual key/value pair to attach (e.g. a `GameRegion` declaration,
    ///   or a Cross-Engine Texture Variant's `TextureOverride_<id>` entry , 
    ///   see `exportCrossEngineTextureOverrideAsCrate`).
    /// Performance fix (audit): `CrateExporter.export` writes real files to
    /// disk and, for most crates, spawns a real `zip` subprocess and
    /// synchronously blocks on `Process.waitUntilExit()`, this used to run
    /// entirely inline on whatever actor called it (a SwiftUI button
    /// action, i.e. the main actor), freezing the whole app for however
    /// long that took. `async` + `Task.detached` here matches the pattern
    /// already proven for `replacingDiscImage`'s disc-image rebuild.
    public func exportAsCrate(patchedBytes: Data, originalFileName: String, metadata: CrateMetadata, settings: [String: String] = [:], to crateURL: URL) async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try CrateExporter.export(files: [(relativePath: originalFileName, data: patchedBytes)], metadata: metadata, settings: settings, to: crateURL)
            }.value
            statusMessage = "Exported mod crate to \(crateURL.lastPathComponent)."
        } catch {
            lastError = "Crate export failed: \(error)"
        }
    }

    /// "Cross-Engine Texture Variant" crate export (see `CompositePreviewView
    /// `'s picker, and `ResolvedModelAsset.applyingTextureOverride`'s own doc
    /// comment for what the preview itself does): bundles `overrideTexture`
    /// as a real `modassets/` file (`ModAssetTexture`), with one real
    /// `TextureOverride_<textureID>` settings key
    /// (`CrateTextureOverrideInstaller.settingsKey(forTextureID:)`) per
    /// unique real, on-disk texture ID `asset.submeshMaterials` references , 
    /// so installing this crate (`CrateTextureOverrideInstaller.install`)
    /// can find every texture record the preview was overriding and patch
    /// each one with the same bundled pixels. This crate carries no
    /// `layer0/` file at all, unlike `exportAsCrate`/
    /// `exportCompleteAssetAsCrate`, its only real content is the settings
    /// + bundled asset, since a texture override doesn't replace a whole
    /// file, it patches one record inside an archive at install time.
    /// Performance fix (audit), same reasoning as `exportAsCrate`.
    public func exportCrossEngineTextureOverrideAsCrate(asset: ResolvedModelAsset, overrideTexture: TextureAsset, metadata: CrateMetadata, to crateURL: URL) async {
        let textureIDs = Set(asset.submeshMaterials.compactMap(\.textureID)).sorted()
        guard !textureIDs.isEmpty else {
            lastError = "This object has no real, on-disk texture ID to override, nothing to bundle into a crate."
            return
        }
        let assetFileName = "texture_override.tstex"
        var settings: [String: String] = [:]
        for textureID in textureIDs {
            settings[CrateTextureOverrideInstaller.settingsKey(forTextureID: textureID)] = "crate:modassets/\(assetFileName)"
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try CrateExporter.export(
                    files: [],
                    metadata: metadata,
                    settings: settings,
                    modAssets: [(relativePath: assetFileName, data: ModAssetTexture.serialize(overrideTexture))],
                    to: crateURL
                )
            }.value
            statusMessage = "Exported texture override crate (\(textureIDs.count) texture record(s)) to \(crateURL.lastPathComponent)."
        } catch {
            lastError = "Crate export failed: \(error)"
        }
    }

    // MARK: - Linked asset resolution / Model Viewer

    /// Resolves `node` (a `RigidModel` or a `GraphicsInfo` skeleton) into a
    /// fully textured `ResolvedModelAsset` and opens the Model Viewer on it.
    /// This is the fix for "the model and its textures show up as separate,
    /// unrelated files": it cross-references the node's enclosing file's
    /// Graphics/Code sections (mesh, material, texture, skeleton records)
    /// instead of treating them as independent chunks.
    public func openModelViewer(for node: ChunkNode) {
        guard let resolved = resolveComposite(for: node) else {
            lastError = "Couldn't resolve this into a complete model, either this record isn't part of a model/texture/animation chain, or nothing in this file currently references it (check the Scrapped Content Scanner)."
            return
        }
        modelViewerAsset = resolved
    }

    /// The "View Parent / Composite" feature: resolves `node`, a texture,
    /// raw mesh, material, or animation, not just the `RigidModel`/
    /// `GraphicsInfo` link record itself, into the complete object it's
    /// part of. Record IDs in this format are large hash-like values (not
    /// small per-file indices), which means they're effectively global: a
    /// texture stored in one `.RM2` is routinely referenced by a
    /// `RigidModel`/`Material` living in a *different* file (a shared
    /// texture/material bank referenced from many level files is a common
    /// layout for this engine). Restricting the search to "the file this
    /// node happens to live in", which is all the original implementation
    /// did, means most cross-file references never resolve. This tries
    /// that fast, common-case file first, then falls back to every other
    /// already-parsed file in the workspace, stopping at the first match.
    /// See `AssetResolver.resolveComposite` for the per-payload-kind lookup.
    public func resolveComposite(for node: ChunkNode) -> ResolvedModelAsset? {
        // WoC-sourced textures (e.g. `CRATES.GSC`) never live under a
        // Graphics/Code section `findFileRoot` recognizes -- check the WoC
        // reference chain first, see `WOCCompositeResolver`'s doc comment.
        if case .texture(let texture) = node.payload,
           let wocAsset = findWOCLevelAsset(containing: node, in: rootNodes),
           let resolved = WOCCompositeResolver.resolveComposite(forTextureIndex: Int(texture.id), in: wocAsset, displayNamePrefix: "\(wocAsset.name), ") {
            return resolved
        }
        if let ownFileRoot = findFileRoot(containing: node, in: rootNodes),
           let resolved = AssetResolver.resolveComposite(for: node, fileRoot: ownFileRoot, displayNamePrefix: "\(ownFileRoot.displayName), ") {
            return resolved
        }
        for fileRoot in allFileRoots(in: rootNodes) {
            if let resolved = AssetResolver.resolveComposite(for: node, fileRoot: fileRoot, displayNamePrefix: "\(fileRoot.displayName), ") {
                return resolved
            }
        }
        return nil
    }

    /// The Textures Hub's counterpart to `resolveComposite(for:)`, the Hub
    /// only ever has a `TextureHubEntry` in hand (a `Codable`, `ScanCache`-
    /// persisted value type), never the originating `ChunkNode`, so it
    /// can't call the node-based overload. `TextureHubEntry.texture.id` is
    /// always populated from the same `recordID` the node would carry (see
    /// `TextureParser`/`TextureXParser`'s own `TextureAsset(id: recordID,
    /// ...)` construction), so this is the same real lookup, just entered
    /// from a bare ID. Searches every already-parsed file root in the
    /// workspace, same reasoning as `resolveComposite(for:)`'s own
    /// cross-file fallback: texture IDs are effectively global, so the
    /// referencing material/model is routinely in a different file than
    /// the texture itself. `nil` means nothing currently loaded references
    /// this texture, not necessarily that nothing ever does; a file that
    /// hasn't been parsed this session can't be searched.
    public func resolveComposite(forTextureID textureID: UInt32) -> ResolvedModelAsset? {
        for fileRoot in allFileRoots(in: rootNodes) {
            if let resolved = AssetResolver.resolveComposite(forTextureID: textureID, fileRoot: fileRoot, displayNamePrefix: "\(fileRoot.displayName), ") {
                return resolved
            }
        }
        return nil
    }

    /// "Scenery/Level Assembly": resolves every placement in `scenery`
    /// (found via `node`, the `SceneryData` chunk itself) into an actual
    /// textured mesh, keyed by the model ID the placement references.
    /// Placements whose `modelID` doesn't match any `RigidModel` in this
    /// file's Graphics section (skinned/`Skin`-based scenery, or a model
    /// this build's resolver can't reach) are silently skipped rather than
    /// failing the whole level, a level with some unresolved pieces is
    /// still far more useful than no level view at all.
    /// A level's scenery tree can carry hundreds/thousands of placements,
    /// each needing a full `RigidModel` -> mesh -> material -> texture
    /// resolution, real CPU work that used to run synchronously on the
    /// main actor when the user clicked "Open Level Viewer," freezing the
    /// UI for however long that took. `scenery` is a plain `Sendable`
    /// struct; `fileRoot` is a `ChunkNode`, and while `ChunkNode` asserts
    /// `@unchecked Sendable`, `findFileRoot` returns the real *live* node
    /// still reachable from `rootNodes` -- handing that straight to a
    /// background `Task` would race any later main-actor mutation of the
    /// same tree (`expandArchiveEntry`, `applyBulkScan`). `deepCopy()`
    /// (see its own doc comment) takes an independent snapshot here, on
    /// the main actor, before the resolution loop runs entirely off it.
    public func resolvedLevelPlacements(for scenery: SceneryAsset, node: ChunkNode) async -> [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)] {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else { return [] }
        // `fileRoot` is a *live* node still reachable from `rootNodes` --
        // `expandArchiveEntry`/`applyBulkScan` can mutate the same node's
        // `children` in place on the main actor while this background Task
        // is still reading it. `deepCopy()` (see its own doc comment on
        // `ChunkNode`) takes a fully independent snapshot synchronously,
        // here, before handing off, so the background read can never race
        // a later main-actor write to the live tree.
        let fileRootSnapshot = fileRoot.deepCopy()
        // Reverted a same-session cancellation-propagation attempt here:
        // a real, reported regression ("all just placeholder objects" for
        // AI/Forge/everything in the level) appeared immediately after it
        // landed. Suspected mechanism: if cancellation propagated into
        // this detached task for *any* reason during a call that was
        // actually still wanted (not genuinely superseded, the full
        // trigger wasn't pinned down before reverting), this loop would
        // bail out with a partial/empty result, and since every object in
        // the level resolves against this same result, one bad
        // cancellation doesn't just drop one placement, it starves the
        // whole level down to nothing but placeholder fallbacks. That risk
        // outweighs the real but narrower win this was going for (not
        // re-running already-superseded background work), so this reverts
        // to always running to completion until the actual trigger is
        // understood from real evidence, not just reasoned safe from
        // static reading. See git history for the reverted
        // `withTaskCancellationHandler` version if revisiting this.
        return await Task.detached(priority: .userInitiated) {
            let index = AssetResolver.buildIndex(fileRoot: fileRootSnapshot)
            var results: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)] = []
            for placement in scenery.placements {
                guard let transform = placement.worldTransform,
                      let resolved = AssetResolver.resolveModelID(placement.modelID, displayName: "Scenery Object #\(placement.modelID)", index: index)
                else { continue }
                results.append((transform.position, transform.rotation, transform.scale, resolved, placement.matrixFileOffset))
            }
            return results
        }.value
    }

    /// "Visual Levels Hub" / "Direct .RM2 Write-Back" / "Level Editor
    /// Overhaul": the one call every entry point into the Level Viewer
    /// makes, resolves the scenery placements (see
    /// `resolvedLevelPlacements`) and gathers every Instance/Trigger/
    /// Camera/SoundEffect record from the same file *and* its sibling
    /// actor file (see `siblingActorFileRoot`) for the scene-layer markers,
    /// audio panel, and events panel. Kept in one place so no entry point
    /// can drift into gathering different data for what's supposed to be
    /// the same view.
    ///
    /// Real Twinsanity levels are conventionally split across two sibling
    /// archive entries with the same base name: `.sm2` carries scenery/
    /// terrain geometry, `.rm2` carries every Instance/Trigger/Camera/
    /// AIPosition/AIPath/Script for that same level, confirmed against
    /// the real archive (`Levels/Earth/Hub/hubb.sm2` has 462 scenery
    /// placements and *zero* instances/triggers/cameras/AI records;
    /// `hubb.rm2` has 114/7/11/22/21 of those respectively and zero
    /// scenery). `openLevelViewer` is always entered from the scenery side
    /// (see this file's three call sites), so gathering "from the same
    /// file as `node`" alone silently produced a Level Viewer that could
    /// never show a single actor, trigger, camera, or AI waypoint for any
    /// real level, the geometry rendered, everything gameplay-relevant
    /// didn't. This was a real, reproducible bug, not a design choice.
    public func openLevelViewer(for scenery: SceneryAsset, node: ChunkNode) async {
        // See `levelViewerOpenGeneration`'s own doc comment, real,
        // measured bug: closing/reopening (or reopening a level while a
        // prior open is still in flight) let overlapping calls pile up and
        // fight each other for the main actor, real captured cost 4-8s per
        // call instead of 0.06-0.3s. This call claims the latest
        // generation; `isStale` (checked at the one checkpoint below that
        // matters, right before committing state) tells it whether a
        // *newer* call has since superseded it.
        levelViewerOpenGeneration += 1
        let myGeneration = levelViewerOpenGeneration
        func isStale() -> Bool { myGeneration != levelViewerOpenGeneration }
        // See `isOpeningLevelViewer`'s own doc comment, a shared "is a
        // level currently opening" signal every UI entry point can disable
        // its own affordance off, so overlapping calls stop getting
        // *started*, not just discarded after the fact. `defer` covers
        // every exit path below, including both early `isStale()` returns.
        openLevelViewerInFlightCount += 1
        defer { openLevelViewerInFlightCount -= 1 }
        // TEMPORARY perf-diagnostic instrumentation, real, reported bug:
        // level open is still very slow even after restructuring this
        // function's phases to run concurrently (see below). Timing each
        // phase directly, logged via `AppLog.rendering`, so the next real
        // load pins down which one actually dominates instead of guessing
        // again.
        // Remove once that's identified and fixed.
        let openStart = CFAbsoluteTimeGetCurrent()
        func markPhase(_ label: String, since previous: Double) -> Double {
            let now = CFAbsoluteTimeGetCurrent()
            // Code review: this used to hand-roll `FileHandle.standardError.write(...
            // .data(using: .utf8)!)`, a real crash risk (`AppLog` calls have
            // none) that also always pays the string-interpolation cost
            // unconditionally, unlike `Logger`'s near-zero-cost-when-not-
            // listening design (see `AppLog`'s own doc comment).
            AppLog.rendering.debug("[LevelViewerPerf] \(label): \(String(format: "%.3f", now - previous))s (total so far: \(String(format: "%.3f", now - openStart))s)")
            return now
        }
        // Real, reported performance bug: every phase below used to run
        // strictly sequentially (`let x = await ...` one after another),
        // so total open time was the *sum* of every phase ever added to
        // this function, each new feature (InstanceTemplate properties,
        // collision meshes, chunk links, ...) made every level open
        // measurably slower, compounding indefinitely. `resolvedLevelPlacements`
        // is independent of everything else this function does (it only
        // needs `scenery`/`node`, both already in hand), started here via
        // `async let` so its own `deepCopy()` + background resolution work
        // runs concurrently with `siblingActorFileRoot` and the bundle walk
        // below instead of blocking ahead of them. `allRecordsInSameFile`
        // deliberately stays a synchronous, main-actor, live-node walk (not
        // backgrounded): the `ChunkNode`s it returns are threaded into
        // `LevelViewerContext.instanceMarkers`/`.triggers`/`.cameras` and
        // later patched *in place* by "Save Chunk Overrides…", handing out
        // a `deepCopy()` instead (safe for `resolvedLevelPlacements`/
        // `resolvedInstanceAssets`, which only ever read a snapshot to
        // resolve geometry and discard it) would silently break every
        // live-edit/save-back path for these records.
        async let placementsTask = resolvedLevelPlacements(for: scenery, node: node)

        var t = openStart
        let siblingNode = await siblingActorFileRoot(for: node)
        AppLog.rendering.debug("[SiblingDiag] openLevelViewer: node=\(node.displayName, privacy: .public) siblingNode=\(siblingNode?.displayName ?? "nil", privacy: .public) siblingChildCount=\(siblingNode?.children.count ?? -1, privacy: .public)")
        if let siblingNode {
            let cacheState: String
            if let cached = self.fileRootCache[siblingNode.id] {
                cacheState = cached == nil ? "cached-nil" : "cached-\(cached!.displayName)"
            } else {
                cacheState = "no-cache-entry"
            }
            AppLog.rendering.debug("[SiblingDiag] siblingNode.sectionType=\(String(describing: siblingNode.sectionType), privacy: .public) childSectionTypes=\(siblingNode.children.map { String(describing: $0.sectionType) }, privacy: .public) fileRootCacheState=\(cacheState, privacy: .public) liveFindFileRoot=\(self.findFileRoot(containing: siblingNode, in: self.rootNodes)?.displayName ?? "nil", privacy: .public)")
            let refoundBySameName = Self.findArchiveEntryPlaceholder(named: siblingNode.displayName, in: self.rootNodes)
            let sameObject = refoundBySameName.map { ObjectIdentifier($0) == ObjectIdentifier(siblingNode) } ?? false
            AppLog.rendering.debug("[SiblingDiag] re-searching rootNodes fresh by name: found=\(refoundBySameName != nil, privacy: .public) sameObjectAsSiblingNode=\(sameObject, privacy: .public) refoundChildCount=\(refoundBySameName?.children.count ?? -1, privacy: .public) rootNodes.count=\(self.rootNodes.count, privacy: .public)")
        }
        t = markPhase("siblingActorFileRoot", since: t)
        // A newer open (a fast reopen, or a click on a different level)
        // already superseded this one, bail out now, before starting the
        // expensive bundle walk/asset resolution below, instead of
        // continuing to burn main-actor time toward a `levelViewerContext`
        // this call will refuse to commit anyway (see the guard at the very
        // end). `placementsTask`'s still-running child task is
        // auto-cancelled by leaving this scope without awaiting it.
        guard !isStale() else { return }

        var bundle = allRecordsInSameFile(as: node)
        t = markPhase("allRecordsInSameFile(node)", since: t)
        AppLog.rendering.debug("[SiblingDiag] allRecordsInSameFile(node), instances=\(bundle.instances.count, privacy: .public) triggers=\(bundle.triggers.count, privacy: .public) cameras=\(bundle.cameras.count, privacy: .public)")
        if let siblingNode {
            let siblingBundle = allRecordsInSameFile(as: siblingNode)
            t = markPhase("allRecordsInSameFile(siblingNode)", since: t)
            AppLog.rendering.debug("[SiblingDiag] allRecordsInSameFile(siblingNode), instances=\(siblingBundle.instances.count, privacy: .public) triggers=\(siblingBundle.triggers.count, privacy: .public) cameras=\(siblingBundle.cameras.count, privacy: .public)")
            bundle.instances += siblingBundle.instances
            bundle.triggers += siblingBundle.triggers
            bundle.cameras += siblingBundle.cameras
            bundle.sounds += siblingBundle.sounds
            bundle.aiPositions += siblingBundle.aiPositions
            bundle.aiPaths += siblingBundle.aiPaths
            bundle.collisionMeshes += siblingBundle.collisionMeshes
            // Actor-file templates win over any same-objectID scenery-file
            // one, real `InstanceTemplate`/`GameObject` data structurally
            // lives in the actor (`.rm2`) file, same reasoning as
            // `resolvedInstanceAssets`'s own doc comment on why building
            // its index from `node` alone (the scenery file) was a real,
            // previously-silent bug.
            bundle.instanceTemplateProperties.merge(siblingBundle.instanceTemplateProperties) { _, sibling in sibling }
            // ChunkLinks deliberately stays scenery-file-only, matching
            // the original per-accessor call (`chunkLinkRecords(inSameFileAs: node)`
            // was never also called on `siblingNode`), see `chunkLinkRecords`'s
            // own doc comment: it sits at the same tier-0 level as
            // `SceneryData`, which only ever lives in the `.sm2`/`.smx` half.
        }

        // These three no longer depend on each other (`resolvedInstanceAssets`
        // needs `bundle.instances`, now ready; the two shared-cache loaders
        // never did), started together via `async let` instead of three
        // back-to-back `await`s so their independent background work
        // (`resolvedInstanceAssets`'s own `deepCopy()` + `buildIndex`
        // included) overlaps rather than stacking.
        // A plain `let` snapshot, not `bundle.instances` read directly , 
        // `bundle` is a `var` still in scope below (read again for
        // `bundle.instanceTemplateProperties`/`instanceMarkers` after
        // this), and Swift 6's strict concurrency checker flags capturing
        // a piece of a mutable local into a concurrently-executing `async
        // let` child task even when nothing here actually mutates it
        // afterward.
        let instancesForResolution = bundle.instances
        async let resolvedTask = resolvedInstanceAssets(for: instancesForResolution, node: node, siblingNode: siblingNode)
        async let defaultInstanceTemplatePropertiesTask = loadSharedDefaultInstanceTemplatePropertiesIfNeeded()

        // Efficiency fix (code review): this used to *also* start its own
        // `defaultAssetIndexTask = loadSharedDefaultAssetIndexIfNeeded()`
        // here, redundant, since `resolvedTask` already fetches the exact
        // same (memoized) value for its own resolution work and now
        // returns it directly instead of it being re-derived a second time.
        let (resolvedAssets, assetIndex, resolvedFromSharedDefault, defaultIndexFromResolve) = await resolvedTask
        t = markPhase("resolvedInstanceAssets", since: t)
        let defaultAssetIndex = defaultIndexFromResolve ?? GraphicsAssetIndex()
        // "Real Flags for Forge-Placed Objects": this level's own real
        // `InstanceTemplate` data wins over the shared `Default.rm2`
        // fallback, same precedence `assetIndex`/`defaultAssetIndex`
        // already establish for geometry resolution.
        var instanceTemplateProperties = await defaultInstanceTemplatePropertiesTask
        t = markPhase("loadSharedDefaultInstanceTemplatePropertiesIfNeeded", since: t)
        instanceTemplateProperties.merge(bundle.instanceTemplateProperties) { _, level in level }
        let placements = await placementsTask
        _ = markPhase("placementsTask (awaited, may already be done)", since: t)
        _ = markPhase("TOTAL openLevelViewer", since: openStart)
        // The real point of this whole guard: never let a stale call
        // overwrite what a newer one already committed (or is about to).
        // All the CPU work above still ran, Swift's `async let` isn't
        // preemptible mid-flight, but at minimum the *result* a newer
        // open superseded can no longer clobber `levelViewerContext` with
        // stale data once it finally finishes.
        guard !isStale() else { return }
        levelViewerContext = LevelViewerContext(
            scenery: scenery,
            sceneryNode: node,
            placements: placements,
            instanceMarkers: bundle.instances,
            resolvedInstanceAssets: resolvedAssets,
            resolvedFromSharedDefault: resolvedFromSharedDefault,
            assetIndex: assetIndex,
            defaultAssetIndex: defaultAssetIndex,
            triggers: bundle.triggers,
            cameras: bundle.cameras,
            sounds: bundle.sounds,
            chunkLinks: bundle.chunkLinks,
            aiPositions: bundle.aiPositions,
            aiPaths: bundle.aiPaths,
            collisionMeshes: bundle.collisionMeshes,
            instanceTemplatePropertiesByObjectID: instanceTemplateProperties
        )
    }

    /// Finds `sceneryNode`'s sibling actor file, the same base name with a
    /// `.RM2`/`.RMX` extension, where this engine actually stores a level's
    /// Instance/Trigger/Camera/AIPosition/AIPath data (see `openLevelViewer`'s
    /// doc comment). Parses it on demand (reusing `expandArchiveEntry`, the
    /// same path a sidebar click already uses) if it isn't already expanded,
    /// so this works whether or not "Parse All" was run first. Falls back to
    /// a same-folder disk lookup (`siblingActorFileRootFromDisk`) when
    /// `sceneryNode` isn't backed by a mounted archive at all. Returns
    /// `nil`, not an error, just nothing to add, only when neither lookup
    /// finds a real matching file.
    private func siblingActorFileRoot(for sceneryNode: ChunkNode) async -> ChunkNode? {
        // `sceneryNode` is the deeply-nested record that actually carries
        // the `.scenery` payload, its own `displayName` is that record's
        // name, not the file's. The file's real entry name (what needs to
        // be swapped `.sm2`->`.rm2`) lives on the *file-root* ancestor.
        guard let ownFileRoot = findFileRoot(containing: sceneryNode, in: rootNodes) else {
            AppLog.rendering.debug("[SiblingDiag] findFileRoot(containing: sceneryNode) returned nil, no file root owns this scenery node at all")
            return nil
        }
        AppLog.rendering.debug("[SiblingDiag] ownFileRoot=\(ownFileRoot.displayName, privacy: .public) id=\(ownFileRoot.id, privacy: .public)")

        let rootIDOpt = owningArchiveRootID(of: ownFileRoot)
        AppLog.rendering.debug("[SiblingDiag] owningArchiveRootID=\(rootIDOpt?.uuidString ?? "nil", privacy: .public)")
        if let rootID = rootIDOpt {
            AppLog.rendering.debug("[SiblingDiag] archiveIndexByRootID has entry for rootID=\(self.archiveIndexByRootID[rootID] != nil, privacy: .public), known archive rootIDs=\(self.archiveIndexByRootID.keys.map(\.uuidString), privacy: .public)")
            if let index = archiveIndexByRootID[rootID] {
                let resolvedName = Self.siblingActorEntryName(forSceneryEntryName: ownFileRoot.displayName, in: index.entries)
                AppLog.rendering.debug("[SiblingDiag] siblingActorEntryName(for: \(ownFileRoot.displayName, privacy: .public))=\(resolvedName ?? "nil", privacy: .public); archive has \(index.entries.count, privacy: .public) entries: \(index.entries.map(\.name).prefix(40), privacy: .public)")
            }
        }

        if let rootID = owningArchiveRootID(of: ownFileRoot),
           let index = archiveIndexByRootID[rootID],
           let siblingName = Self.siblingActorEntryName(forSceneryEntryName: ownFileRoot.displayName, in: index.entries) {
            AppLog.rendering.debug("[SiblingDiag] resolved siblingName=\(siblingName, privacy: .public) from \(index.entries.count) archive entries")
            // Real, reported bug: `allFileRoots` only recognizes an *already-
            // expanded* file root (`.null` with a real `.graphics`/`.code`-family
            // child), the sibling `.rm2` almost always hasn't been clicked into
            // yet the first time a level's own scenery loads, so it's still
            // sitting in the tree as the bare, childless placeholder every
            // archive entry starts as (`load(_:)`'s `.archiveIndex` case). That
            // placeholder satisfies none of `allFileRoots`' own recognition
            // criteria, so the lookup below found nothing to expand at all and
            // silently returned `nil`, the real cause of a level reached by
            // browsing a `.BH` archive showing real scenery but zero Instance/
            // Trigger/Camera markers, even though its own `.rm2` genuinely has
            // them. `findArchiveEntryPlaceholder` matches by name regardless of
            // expansion state, so this can actually reach the `expandArchiveEntry`
            // call below for the normal, not-yet-clicked case.
            // Scoped to *this* archive's own root subtree, not the whole
            // `rootNodes` forest: real, reported bug, "close the Chunk
            // Viewer, reopen the same level" sometimes came back with real
            // Scenery but zero Instance/Trigger/Camera markers even though
            // the previous open found them fine. `findArchiveEntryPlaceholder`
            // matches by *name only*; the same archive (e.g. `CRASH.BH`) can
            // legitimately exist as more than one independent root at once
            //, browsing into it from a mounted disc opens its own separate
            // root alongside a directly-opened one (see `openDiscEntry`'s
            // own doc comment), so an unscoped forest-wide search can match
            // a *different* root's same-named, still-unexpanded placeholder
            // instead of the one this exact `rootID`/`index` pair was
            // computed for. That mismatched node then gets expanded with the
            // wrong archive's `rootID`, or, worse, matched again next time
            // and returned without ever being expanded at all. Searching only
            // `archiveRoot`'s own subtree makes the match unambiguous.
            guard let archiveRoot = rootNodes.first(where: { $0.id == rootID }) else {
                AppLog.rendering.debug("[SiblingDiag] rootNodes has no root matching rootID, returning nil")
                return nil
            }
            if let existing = Self.findArchiveEntryPlaceholder(named: siblingName, in: [archiveRoot]) {
                AppLog.rendering.debug("[SiblingDiag] found placeholder/node named \(siblingName, privacy: .public): payload!=nil=\(existing.payload != nil, privacy: .public) childCount=\(existing.children.count, privacy: .public)")
                // Already a real parsed tree (non-empty children or a decoded
                // payload) rather than the still-unexpanded placeholder every
                // archive entry starts as.
                if existing.payload != nil || !existing.children.isEmpty { return existing }
                await expandArchiveEntry(existing, rootID: rootID)
                let reFound = Self.findArchiveEntryPlaceholder(named: siblingName, in: [archiveRoot])
                AppLog.rendering.debug("[SiblingDiag] after expandArchiveEntry, re-found node childCount=\(reFound?.children.count ?? -1, privacy: .public) payload!=nil=\(reFound?.payload != nil, privacy: .public)")
                return reFound
            }
            AppLog.rendering.debug("[SiblingDiag] findArchiveEntryPlaceholder found NOTHING named \(siblingName, privacy: .public) under archiveRoot=\(archiveRoot.displayName, privacy: .public), falling through to disk lookup")
        }

        let fromDisk = await siblingActorFileRootFromDisk(for: ownFileRoot)
        AppLog.rendering.debug("[SiblingDiag] siblingActorFileRootFromDisk returned \(fromDisk == nil ? "nil" : "a node", privacy: .public)")
        return fromDisk
    }

    /// Archive-independent counterpart to the branch above: real, reported
    /// bug, "Save Chunk Overrides…" always writes its Instance/Trigger/
    /// Camera half and its scenery half as two loose, same-folder,
    /// same-base-name files (`performSaveLevelOverrides`'s own doc comment),
    /// never as archive entries. Reopening the scenery half of that pair hit
    /// the archive-only lookup above, found no owning archive at all, and
    /// returned `nil`, a level that showed real Scenery but zero Instance/
    /// Trigger/Camera markers, even though the sibling `.rm2` sits right
    /// next to it on disk. Mirrors `loadSoundBankAsync`'s same-folder
    /// `.MH`/`.MB` pairing, and inserts the parsed sibling into `rootNodes`
    /// the same way any other standalone-opened file is tracked, so it's a
    /// real, editable root rather than a read-only shadow copy.
    private func siblingActorFileRootFromDisk(for ownFileRoot: ChunkNode) async -> ChunkNode? {
        guard let ownURL = looseFileURLByRootID[ownFileRoot.id] else { return nil }
        let sceneryExt = (ownFileRoot.displayName as NSString).pathExtension
        let targetExt: String
        switch sceneryExt.lowercased() {
        case "sm2": targetExt = "rm2"
        case "smx": targetExt = "rmx"
        default: return nil
        }
        let baseName = ownURL.deletingPathExtension().lastPathComponent
        let directory = ownURL.deletingLastPathComponent()
        guard let siblingURL = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first(where: { $0.deletingPathExtension().lastPathComponent == baseName && $0.pathExtension.caseInsensitiveCompare(targetExt) == .orderedSame })
        else { return nil }

        if let existing = rootNodes.first(where: { $0.displayName == siblingURL.lastPathComponent }) { return existing }

        let parsed: (node: ChunkNode, data: Data)? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: siblingURL, options: .mappedIfSafe),
                  let node = try? Self.mainTreeDriver(forExtension: siblingURL.pathExtension).parseChunkFile(data: data, fileKind: Self.fileKind(forEntryNamed: siblingURL.lastPathComponent), fileName: siblingURL.lastPathComponent)
            else { return nil }
            return (node, data)
        }.value
        guard let parsed else { return nil }

        rawFileBytesByRootID[parsed.node.id] = parsed.data
        looseFileURLByRootID[parsed.node.id] = siblingURL
        rootNodes.append(parsed.node)
        return parsed.node
    }

    /// Finds a node anywhere in `nodes` whose `displayName` matches `name`
    /// (case-insensitive), deliberately broader than `allFileRoots`, which
    /// only recognizes an *already-expanded* file root and so can never see
    /// the bare, childless placeholder every archive entry starts as before
    /// it's been clicked into.
    private nonisolated static func findArchiveEntryPlaceholder(named name: String, in nodes: [ChunkNode]) -> ChunkNode? {
        for node in nodes {
            if node.displayName.caseInsensitiveCompare(name) == .orderedSame { return node }
            if let found = findArchiveEntryPlaceholder(named: name, in: node.children) { return found }
        }
        return nil
    }

    /// The real archive entry name for `sceneryEntryName`'s sibling actor
    /// file, same base name, `.sm2`→`.rm2`/`.smx`→`.rmx`, looked up
    /// against the archive's own real entry list rather than string-built,
    /// "Chunk Stitching Rendering Bug": the missing half of chunk stitching
    /// -- confirmed by direct investigation that `loadChunkLinkPlacements`
    /// only ever gathers a stitched neighbor's *scenery* (`SceneryAsset`)
    /// placements, never its `Instance`/`Trigger`/`Camera`/`AIPosition`
    /// records. Those don't live in the `.sm2` this function resolves
    /// `link.path` to at all -- exactly like the *primary* chunk (see
    /// `openLevelViewer`'s own doc comment), they live in that file's
    /// sibling `.rm2`/`.rmx` actor file, found the same way
    /// `siblingActorFileRoot` finds one for an already-open primary chunk.
    ///
    /// Deliberately read-only: every returned record's `node` comes from a
    /// **standalone-parsed** tree that's never inserted into `rootNodes`
    /// (unlike the primary chunk's own actor file, which genuinely is
    /// tracked there) -- `LevelViewerRenderer.stitchChunkActors` passes
    /// `sourceNode: nil` for these, so a stitched neighbor's markers are
    /// visible but not selectable/editable/save-able. Building real
    /// multi-file write-back (editing a *different* file than the one
    /// "Save Chunk Overrides…" targets) is a separate, larger feature this
    /// doesn't attempt.
    public func loadChunkLinkActors(for link: ChunkLink) async -> (
        fileName: String,
        instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)],
        resolvedInstanceAssets: [UUID: ResolvedModelAsset],
        triggers: [(node: ChunkNode, trigger: TriggerVolume)],
        cameras: [(node: ChunkNode, camera: PlacedCamera)],
        aiPositions: [(node: ChunkNode, marker: AIPositionMarker)]
    )? {
        let normalizedPath = link.path.replacingOccurrences(of: "\\", with: "/")
        let targetSceneryName = normalizedPath.lowercased().hasSuffix(".sm2") ? normalizedPath : normalizedPath + ".sm2"

        guard let match = archiveIndexByRootID.values.compactMap({ archiveIndex -> (ArchiveIndex, ArchiveEntry)? in
            archiveIndex.entries.first { entry in
                entry.name.replacingOccurrences(of: "\\", with: "/").caseInsensitiveCompare(targetSceneryName) == .orderedSame
            }.map { (archiveIndex, $0) }
        }).first else { return nil }

        guard let siblingName = Self.siblingActorEntryName(forSceneryEntryName: match.1.name, in: match.0.entries),
              let actorEntry = match.0.entries.first(where: { $0.name.caseInsensitiveCompare(siblingName) == .orderedSame })
        else { return nil }

        let index = match.0
        let defaultIndex = await loadSharedDefaultAssetIndexIfNeeded()

        return await Task.detached(priority: .userInitiated) { () -> (String, [(node: ChunkNode, instance: PlacedInstance)], [UUID: ResolvedModelAsset], [(node: ChunkNode, trigger: TriggerVolume)], [(node: ChunkNode, camera: PlacedCamera)], [(node: ChunkNode, marker: AIPositionMarker)])? in
            guard let data = try? BDArchiveParser.readEntryData(actorEntry, index: index),
                  let actorRoot = try? Self.mainTreeDriver(forExtension: (actorEntry.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: .rm2, fileName: actorEntry.name)
            else { return nil }

            var instances: [(node: ChunkNode, instance: PlacedInstance)] = []
            var triggers: [(node: ChunkNode, trigger: TriggerVolume)] = []
            var cameras: [(node: ChunkNode, camera: PlacedCamera)] = []
            var aiPositions: [(node: ChunkNode, marker: AIPositionMarker)] = []
            func walk(_ node: ChunkNode) {
                switch node.payload {
                case .instance(let instance): instances.append((node, instance))
                case .trigger(let trigger): triggers.append((node, trigger))
                case .camera(let camera): cameras.append((node, camera))
                case .aiPosition(let marker): aiPositions.append((node, marker))
                default: break
                }
                for child in node.children { walk(child) }
            }
            walk(actorRoot)

            let assetIndex = AssetResolver.buildIndex(fileRoot: actorRoot)
            var resolvedAssets: [UUID: ResolvedModelAsset] = [:]
            for (markerNode, instance) in instances {
                let selector = instance.unknownUInt32List2.first ?? 0
                guard let resolved = AssetResolver.resolveInstanceObject(objectID: instance.objectID, instanceSelector: selector, index: assetIndex, defaultIndex: defaultIndex) else { continue }
                resolvedAssets[markerNode.id] = resolved
            }

            return (actorEntry.name, instances, resolvedAssets, triggers, cameras, aiPositions)
        }.value
    }

    /// so this only ever returns a name that genuinely exists.
    private nonisolated static func siblingActorEntryName(forSceneryEntryName sceneryEntryName: String, in entries: [ArchiveEntry]) -> String? {
        let sceneryExt = (sceneryEntryName as NSString).pathExtension
        let targetExt: String
        switch sceneryExt.lowercased() {
        case "sm2": targetExt = "rm2"
        case "smx": targetExt = "rmx"
        default: return nil
        }
        let sceneryBase = (sceneryEntryName as NSString).deletingPathExtension
        return entries.first { entry in
            let entryExt = (entry.name as NSString).pathExtension
            guard entryExt.caseInsensitiveCompare(targetExt) == .orderedSame else { return false }
            let entryBase = (entry.name as NSString).deletingPathExtension
            return entryBase.caseInsensitiveCompare(sceneryBase) == .orderedSame
        }?.name
    }

    /// The bidirectional counterpart to `siblingActorEntryName` above:
    /// same base name, `.sm2`<->`.rm2`/`.smx`<->`.rmx`, but works starting
    /// from *either* half of the pair, used by `expandArchiveEntry` to
    /// pull in whichever half wasn't clicked, regardless of which one was.
    private nonisolated static func siblingChunkFileEntryName(for entryName: String, in entries: [ArchiveEntry]) -> String? {
        let ext = (entryName as NSString).pathExtension
        let targetExt: String
        switch ext.lowercased() {
        case "sm2": targetExt = "rm2"
        case "rm2": targetExt = "sm2"
        case "smx": targetExt = "rmx"
        case "rmx": targetExt = "smx"
        default: return nil
        }
        let base = (entryName as NSString).deletingPathExtension
        return entries.first { candidate in
            let candidateExt = (candidate.name as NSString).pathExtension
            guard candidateExt.caseInsensitiveCompare(targetExt) == .orderedSame else { return false }
            return (candidate.name as NSString).deletingPathExtension.caseInsensitiveCompare(base) == .orderedSame
        }?.name
    }

    /// "Connect Chunks", every `.sm2`/`.smx` (scenery) entry across every
    /// archive currently mounted in the workspace, as a real, pickable
    /// target for a `ChunkLink.path` edit, the friendly counterpart to
    /// typing a path by hand in `ChunkLinksEditorSheet`. `ChunkLink.path`
    /// is matched against the *full*, path-qualified entry name minus its
    /// extension (see `loadChunkLinkPlacements`'s own normalization), so
    /// `path` here is exactly that: ready to assign to `ChunkLink.path`
    /// as-is. Deliberately scoped to already-open archives, not a disc-wide
    /// scan, the same real lookup `loadChunkLinkPlacements` itself already
    /// depends on, so a link built from this list is guaranteed resolvable
    /// the moment it's created, not just plausible-looking.
    public struct ChunkLinkTarget: Identifiable, Hashable {
        public var id: String { path }
        /// Full archive-relative path, no extension, assign straight to
        /// `ChunkLink.path`.
        public let path: String
        public let displayName: String
    }

    public func availableChunkLinkTargets() -> [ChunkLinkTarget] {
        var seenPaths = Set<String>()
        var results: [ChunkLinkTarget] = []
        for index in archiveIndexByRootID.values {
            for entry in index.entries {
                let ext = (entry.name as NSString).pathExtension.lowercased()
                guard ext == "sm2" || ext == "smx" else { continue }
                let normalizedPath = (entry.name as NSString).deletingPathExtension.replacingOccurrences(of: "\\", with: "/")
                guard seenPaths.insert(normalizedPath.lowercased()).inserted else { continue }
                results.append(ChunkLinkTarget(path: normalizedPath, displayName: (normalizedPath as NSString).lastPathComponent))
            }
        }
        return results.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    /// "Create New Chunks/Levels, Chunk Cloning": the real, buildable
    /// version of "create a new level" this engine's own data actually
    /// supports. There's no decoded master level table anywhere in this
    /// codebase (the game's real in-menu level list, wherever it lives in
    /// the executable, is never consulted, `GameLauncher.building`'s own
    /// doc comment is explicit that Quick Launch boots straight past the
    /// menu), so a clone can't be made to show up there. What it *can* do,
    /// fully for real: duplicate an existing chunk's scenery (`.sm2`/
    /// `.smx`) and, when one exists, its sibling actor (`.rm2`/`.rmx`)
    /// file into two brand-new archive entries, in the same directory,
    /// under a new base name, genuinely new, separately-editable chunk
    /// files reachable via Quick Launch's starting-chunk override or a
    /// `ChunkLink`, exactly the two mechanisms this app already has.
    public enum ChunkCloneError: Error, CustomStringConvertible {
        case invalidName
        case nameCollision(String)
        case sourceNotAnOpenArchiveEntry
        case sourceEntryNotFound
        case noDiscImageConfigured
        case buildFailed(String)
        case writeFailed(String)

        public var description: String {
            switch self {
            case .invalidName: return "Enter a name with no \"/\" or \"\\\" characters."
            case .nameCollision(let name): return "\"\(name)\" already exists in this archive, choose a different name."
            case .sourceNotAnOpenArchiveEntry: return "This chunk isn't part of a currently mounted disc archive, so it can't be cloned this way."
            case .sourceEntryNotFound: return "Couldn't find this chunk's own bytes in its archive's index."
            case .noDiscImageConfigured: return "Choose a disc image (.iso) first, cloning writes the new chunk straight into it."
            case .buildFailed(let reason): return "Couldn't build the updated disc image: \(reason)"
            case .writeFailed(let reason): return "Couldn't save the updated disc image: \(reason)"
            }
        }
    }

    public struct ChunkCloneOutcome {
        public let sceneryEntryName: String
        public let actorEntryName: String?
        public let diagnostics: [String]
    }

    public func cloningChunk(sceneryFileRoot: ChunkNode, newBaseName: String) async -> Result<ChunkCloneOutcome, ChunkCloneError> {
        let cleanBaseName = (newBaseName.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).deletingPathExtension
        guard !cleanBaseName.isEmpty, !cleanBaseName.contains("/"), !cleanBaseName.contains("\\") else {
            return .failure(.invalidName)
        }
        guard let rootID = owningArchiveRootID(of: sceneryFileRoot), let index = archiveIndexByRootID[rootID] else {
            return .failure(.sourceNotAnOpenArchiveEntry)
        }
        guard let sceneryEntry = index.entries.first(where: { $0.name.caseInsensitiveCompare(sceneryFileRoot.displayName) == .orderedSame }),
              let sceneryBytes = try? BDArchiveParser.readEntryData(sceneryEntry, index: index)
        else {
            return .failure(.sourceEntryNotFound)
        }

        let directory = (sceneryEntry.name as NSString).deletingLastPathComponent
        func qualifiedName(ext: String) -> String {
            directory.isEmpty ? "\(cleanBaseName).\(ext)" : "\(directory)/\(cleanBaseName).\(ext)"
        }

        let sceneryExt = (sceneryEntry.name as NSString).pathExtension
        let newSceneryName = qualifiedName(ext: sceneryExt)
        guard !index.entries.contains(where: { $0.name.caseInsensitiveCompare(newSceneryName) == .orderedSame }) else {
            return .failure(.nameCollision(newSceneryName))
        }

        var newEntries: [String: Data] = [newSceneryName: sceneryBytes]
        var actorEntryName: String?
        if let siblingName = Self.siblingActorEntryName(forSceneryEntryName: sceneryEntry.name, in: index.entries),
           let actorEntry = index.entries.first(where: { $0.name.caseInsensitiveCompare(siblingName) == .orderedSame }),
           let actorBytes = try? BDArchiveParser.readEntryData(actorEntry, index: index) {
            let newActorName = qualifiedName(ext: (actorEntry.name as NSString).pathExtension)
            guard !index.entries.contains(where: { $0.name.caseInsensitiveCompare(newActorName) == .orderedSame }) else {
                return .failure(.nameCollision(newActorName))
            }
            newEntries[newActorName] = actorBytes
            actorEntryName = newActorName
        }

        guard let isoURL = discImageURL else { return .failure(.noDiscImageConfigured) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TwinsanityStudioChunkClone", isDirectory: true)
        let plan = GameLaunchPlan(newArchiveEntries: newEntries)
        let result: GameLauncher.RebuildResult
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try GameLauncher.rebuildingAndVerifying(isoURL: isoURL, plan: plan, scratchDirectory: scratch)
            }.value
        } catch {
            return .failure(.buildFailed("\(error)"))
        }

        do {
            backingUpMountedDiscImageIfNeeded(url: isoURL)
            try await writeDataAsync(result.data, to: isoURL)
            refreshingMountedDiscImage(url: isoURL)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }

        return .success(ChunkCloneOutcome(sceneryEntryName: newSceneryName, actorEntryName: actorEntryName, diagnostics: result.diagnostics))
    }

    /// "Comprehensive Instance Population" (Part 4B): resolves every
    /// `Instance.objectID` to real geometry where this build's decoded data
    /// allows it (`AssetResolver.resolveInstanceObject`, `GameObject` ->
    /// `GraphicsInfo` -> skinned mesh or rigid model-link parts), keyed by
    /// the `Instance` node's own identity so `LevelViewerRenderer` can look
    /// each one up directly. Missing from this dictionary is exactly the
    /// "no 3D model available" case `LevelViewerRenderer.upload` falls back
    /// to the colored placeholder marker for, this never fabricates a
    /// substitute for one that doesn't resolve. Also returns the
    /// `GraphicsAssetIndex` itself (built once, here) so "The Forge
    /// Palette" (Part 4C) can resolve a *newly placed* object's geometry
    /// through the exact same index without rebuilding it.
    ///
    /// The index is built from `siblingNode`'s file root when one exists,
    /// falling back to `node`'s own file root otherwise, real, verified
    /// data (see `openLevelViewer`'s own doc comment: `hubb.sm2` has zero
    /// `Instance`/`GameObject` records of its own, `hubb.rm2` has 32) shows
    /// `GameObject` records structurally live in the *actor* file, not the
    /// scenery file `node` always is (`openLevelViewer` is "always entered
    /// from the scenery side"). Building this index from `node` alone was a
    /// real, previously-silent bug: every level's own `GameObject`s were
    /// invisible to this resolver, so both the Forge Palette and already-
    /// placed Instance markers could only ever resolve through the shared
    /// `Default.rm2` fallback, never this level's own actor data.
    private func resolvedInstanceAssets(for instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)], node: ChunkNode, siblingNode: ChunkNode?) async -> (assets: [UUID: ResolvedModelAsset], index: GraphicsAssetIndex, resolvedFromSharedDefault: Set<UUID>, defaultIndex: GraphicsAssetIndex?) {
        // TEMPORARY perf-diagnostic instrumentation, see `openLevelViewer`'s
        // matching block. Remove once the dominant sub-step here is
        // identified and fixed.
        let innerStart = CFAbsoluteTimeGetCurrent()
        func markInner(_ label: String, since previous: Double) -> Double {
            let now = CFAbsoluteTimeGetCurrent()
            AppLog.rendering.debug("[LevelViewerPerf]   resolvedInstanceAssets.\(label): \(String(format: "%.3f", now - previous))s")
            return now
        }
        guard let fileRoot = findFileRoot(containing: siblingNode ?? node, in: rootNodes) else { return ([:], GraphicsAssetIndex(), [], nil) }
        // See `resolvedLevelPlacements`'s identical comment / `ChunkNode.
        // deepCopy()`'s own doc comment -- same live-tree-vs-background-
        // read race, same fix.
        let fileRootSnapshot = fileRoot.deepCopy()
        var it = markInner("deepCopy", since: innerStart)
        // Efficiency fix (code review): `openLevelViewer` used to *also*
        // fetch this via its own separate `defaultAssetIndexTask` async let
        //, redundant, since this call already needs the exact same value
        // for its own per-marker resolution below. `loadSharedDefaultAssetIndexIfNeeded`
        // is memoized so the redundant call was never unsafe, just wasted
        // work (an extra function call + task-handle await on every level
        // open); returning it here instead lets the caller reuse this
        // result directly.
        let defaultIndex = await loadSharedDefaultAssetIndexIfNeeded()
        it = markInner("loadSharedDefaultAssetIndexIfNeeded (inner)", since: it)
        // Reverted a same-session cancellation-propagation attempt, see
        // `resolvedLevelPlacements`'s matching comment for why: a real,
        // reported regression ("all just placeholder objects" for AI/
        // Forge/everything) appeared immediately after it landed, and this
        // function's per-marker loop feeds the exact `index`/`assets`
        // every object in the level resolves against, a bad cancellation
        // here doesn't drop one object, it starves all of them.
        let detached = Task.detached(priority: .userInitiated) {
            let buildStart = CFAbsoluteTimeGetCurrent()
            let index = AssetResolver.buildIndex(fileRoot: fileRootSnapshot)
            let buildElapsed = CFAbsoluteTimeGetCurrent() - buildStart
            AppLog.rendering.debug("[LevelViewerPerf]   resolvedInstanceAssets.buildIndex (background thread): \(String(format: "%.3f", buildElapsed))s")
            let resolveStart = CFAbsoluteTimeGetCurrent()
            var results: [UUID: ResolvedModelAsset] = [:]
            // "No Cross-Level GPU Cache" fix: which markers resolved
            // *only* via the shared `defaultIndex` fallback (crates,
            // Wumpa, other common pickups defined once in `Default.rm2`),
            // as opposed to this level's own `index`, determined by a
            // real re-check (does it resolve against `index` alone?), not
            // guessed from `recordID` collisions, which would risk exactly
            // the "silently reusing the wrong texture" bug `TextureUploadCache`'s
            // own doc comment warns a naive cross-file cache could cause.
            // `defaultIndex` is the *same* single, process-wide-memoized
            // `GraphicsAssetIndex` instance for the whole session (see
            // `loadSharedDefaultAssetIndexIfNeeded`), so, unlike a level's
            // own `index`, which differs per level and *does* have
            // colliding `recordID`s across files, a `recordID` from this
            // specific set really is safe to key a persistent GPU cache on
            // by `recordID` alone.
            var resolvedFromSharedDefault: Set<UUID> = []
            for (markerNode, instance) in instanceMarkers {
                let selector = instance.unknownUInt32List2.first ?? 0
                // Single resolve pass reports its own source directly (see
                // `resolveInstanceObjectReportingSource`'s doc comment) , 
                // this used to call `resolveInstanceObject` a second time,
                // with `defaultIndex: nil`, purely to classify the result
                // it already had.
                guard let (resolved, viaSharedDefault) = AssetResolver.resolveInstanceObjectReportingSource(objectID: instance.objectID, instanceSelector: selector, index: index, defaultIndex: defaultIndex) else { continue }
                results[markerNode.id] = resolved
                if viaSharedDefault {
                    resolvedFromSharedDefault.insert(markerNode.id)
                }
            }
            let resolveElapsed = CFAbsoluteTimeGetCurrent() - resolveStart
            AppLog.rendering.debug("[LevelViewerPerf]   resolvedInstanceAssets.perMarkerResolve (\(instanceMarkers.count) markers, background thread): \(String(format: "%.3f", resolveElapsed))s")
            return (results, index, resolvedFromSharedDefault)
        }
        let result = await detached.value
        _ = markInner("Task.detached (awaited)", since: it)
        return (result.0, result.1, result.2, defaultIndex)
    }

    /// "No More Placeholder Squares": lazily loads and caches
    /// `Startup/Default.rm2`, the real shared-object resource every open
    /// `.BH` archive carries, confirmed against the actual disc (see
    /// `AssetResolver.resolveInstanceObject`'s doc comment), from
    /// whichever currently-open archive actually has it. `nil` (cached as
    /// such, not retried every call) when no open archive carries it, e.g.
    /// a workspace with only loose `.RM2` files open and no `.BH`.
    private func loadSharedDefaultAssetIndexIfNeeded() async -> GraphicsAssetIndex? {
        if let sharedDefaultAssetIndexTask { return await sharedDefaultAssetIndexTask.value }

        guard let match = archiveIndexByRootID.values.compactMap({ archiveIndex -> (ArchiveIndex, ArchiveEntry)? in
            archiveIndex.entries.first { $0.name.caseInsensitiveCompare("Startup/Default.rm2") == .orderedSame }.map { (archiveIndex, $0) }
        }).first else {
            sharedDefaultAssetIndexTask = Task { nil }
            return nil
        }

        let task = Task<GraphicsAssetIndex?, Never> {
            await Task.detached(priority: .userInitiated) { () -> GraphicsAssetIndex? in
                guard let data = try? BDArchiveParser.readEntryData(match.1, index: match.0),
                      let fileRoot = try? Self.mainTreeDriver(forExtension: (match.1.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: .rm2, fileName: match.1.name)
                else { return nil }
                return AssetResolver.buildIndex(fileRoot: fileRoot)
            }.value
        }
        sharedDefaultAssetIndexTask = task
        return await task.value
    }

    /// "Real Flags for Forge-Placed Objects": the `Startup/Default.rm2`
    /// counterpart to `loadSharedDefaultAssetIndexIfNeeded`, for real
    /// `InstanceTemplate` `properties` values instead of graphics data , 
    /// same lazy-load-once-and-share caching, same "no `.BH` open" `nil`
    /// case. Real disc data confirms `Default.rm2` only ever carries
    /// crate/pickup templates (30 records, all crates/health/wumpa/gems),
    /// never an enemy/AI one, a per-level `InstanceTemplate` lookup
    /// (`FileRecordBundle.instanceTemplateProperties`, checked first , 
    /// see `openLevelViewer`) is what a level-specific object would need,
    /// this is only the always-available fallback tier underneath it.
    private func loadSharedDefaultInstanceTemplatePropertiesIfNeeded() async -> [UInt16: UInt32] {
        if let sharedDefaultInstanceTemplatePropertiesTask { return await sharedDefaultInstanceTemplatePropertiesTask.value }

        guard let match = archiveIndexByRootID.values.compactMap({ archiveIndex -> (ArchiveIndex, ArchiveEntry)? in
            archiveIndex.entries.first { $0.name.caseInsensitiveCompare("Startup/Default.rm2") == .orderedSame }.map { (archiveIndex, $0) }
        }).first else {
            sharedDefaultInstanceTemplatePropertiesTask = Task { [:] }
            return [:]
        }

        let task = Task<[UInt16: UInt32], Never> {
            await Task.detached(priority: .userInitiated) { () -> [UInt16: UInt32] in
                guard let data = try? BDArchiveParser.readEntryData(match.1, index: match.0),
                      let fileRoot = try? Self.mainTreeDriver(forExtension: (match.1.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: .rm2, fileName: match.1.name)
                else { return [:] }
                var result: [UInt16: UInt32] = [:]
                func walk(_ node: ChunkNode) {
                    switch node.payload {
                    case .instanceTemplate(let value): result[value.objectID] = value.properties
                    case .instanceTemplateDemo(let value): result[value.objectID] = value.properties
                    default: break
                    }
                    for child in node.children { walk(child) }
                }
                walk(fileRoot)
                return result
            }.value
        }
        sharedDefaultInstanceTemplatePropertiesTask = task
        return await task.value
    }

    // MARK: - "Forge Palette anywhere" (global object resolution across every level)

    /// Splits `count` candidate indices into `laneCount` round-robin lanes , 
    /// lane 0 gets indices `0, laneCount, 2*laneCount, …`, lane 1 gets
    /// `1, laneCount+1, …`, and so on. This is the exact assignment
    /// `resolvingObjectIDAcrossAllLevels`'s bounded-concurrency search uses
    /// to split its candidate level list across a handful of lanes (matching
    /// `SceneryLoadCache`'s own lane-count approach). Pulled out as a free,
    /// `nonisolated`, pure function so the assignment itself is directly
    /// unit-testable without a real workspace or archive.
    nonisolated static func laneIndices(count: Int, laneCount: Int) -> [[Int]] {
        guard count > 0, laneCount > 0 else { return [] }
        return (0..<laneCount).map { lane in Array(stride(from: lane, to: count, by: laneCount)) }
    }

    /// One real `.rm2`/`.rmx` archive entry this session can reach , 
    /// `resolvingObjectIDAcrossAllLevels`'s own candidate unit. Deliberately
    /// broader than `SceneryLevelSource`: an object's real geometry lives
    /// directly in a level's own `.rm2`/`.rmx` Graphics/Code sections, with
    /// no `.sm2`/`.smx` scenery sibling required at all, so this enumerates
    /// every graphics-bearing archive entry, not just scenery-paired ones.
    private struct LevelGraphicsCandidate {
        var key: String
        var archiveRootID: UUID
        var entry: ArchiveEntry
    }

    /// Every real `.rm2`/`.rmx` entry across every mounted archive this
    /// session has open, the same `archiveIndexByRootID` universe
    /// `sceneryLevelSources`'s own archive-index loop enumerates, widened
    /// from ".sm2/.smx with a paired sibling" to "every graphics file,
    /// period." Deliberately doesn't also enumerate already-open standalone
    /// files (unlike `sceneryLevelSources`), this search only ever runs for
    /// an object ID that already missed this *session's* own currently-open
    /// level (checked by the three existing sources before this ever
    /// engages), so re-checking that same open level again here would be
    /// pure waste.
    private func allLevelGraphicsCandidates() -> [LevelGraphicsCandidate] {
        var results: [LevelGraphicsCandidate] = []
        for (rootID, index) in archiveIndexByRootID {
            for entry in index.entries {
                let ext = (entry.name as NSString).pathExtension.lowercased()
                guard ext == "rm2" || ext == "rmx" else { continue }
                results.append(LevelGraphicsCandidate(key: "\(rootID)|\(entry.name)", archiveRootID: rootID, entry: entry))
            }
        }
        return results
    }

    /// Parses (or reuses an already-in-flight/-completed parse of) one
    /// candidate level's own `GraphicsAssetIndex`, the exact coalescing
    /// cache `loadSharedDefaultAssetIndexIfNeeded` established for the one
    /// shared `Default.rm2`, generalized here to any level entry: concurrent
    /// lookups against the same not-yet-parsed level coalesce onto the same
    /// in-flight `Task` rather than each starting their own redundant parse,
    /// and a level already parsed this session is never parsed again.
    private func loadingLevelAssetIndex(_ candidate: LevelGraphicsCandidate) async -> GraphicsAssetIndex? {
        if let existingTask = levelAssetIndexTaskByKey[candidate.key] {
            return await existingTask.value
        }
        guard let index = archiveIndexByRootID[candidate.archiveRootID] else { return nil }
        let entry = candidate.entry
        let task = Task<GraphicsAssetIndex?, Never> {
            await Task.detached(priority: .utility) { () -> GraphicsAssetIndex? in
                guard let data = try? BDArchiveParser.readEntryData(entry, index: index),
                      let fileRoot = try? Self.mainTreeDriver(forExtension: (entry.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: Self.fileKind(forEntryNamed: entry.name), fileName: entry.name)
                else { return nil }
                return AssetResolver.buildIndex(fileRoot: fileRoot)
            }.value
        }
        levelAssetIndexTaskByKey[candidate.key] = task
        return await task.value
    }

    /// "I want the thumbnail to load in the forge palette even if the level
    /// is not loaded", the real, bounded, non-blocking disc-wide search
    /// behind that request. Called only on demand, per object ID actually
    /// displayed (`GlobalObjectResolutionCache.search`), never as an eager
    /// pre-scan: searches every other real `.rm2`/`.rmx` level this session
    /// can reach (`allLevelGraphicsCandidates`) across a handful of
    /// concurrent lanes (`laneIndices`, matching `SceneryLoadCache`'s own
    /// lane count), stopping at the first level whose own `GraphicsAssetIndex`
    /// actually resolves `objectID` to real geometry (a resolved `GameObject`
    /// whose mesh has at least one submesh, the same bar
    /// `ModelViewerRenderer.canResolveObjectID` already holds every other
    /// resolution source to).
    ///
    /// Every lane checks `foundAsset` before parsing its next candidate, so
    /// a resolution in one lane stops every other lane from parsing further
    /// candidates it no longer needs, mutating `foundAsset` is safe despite
    /// several lanes touching it because this whole method (and every lane
    /// `Task` it starts, since a plain, non-detached `Task { }` inherits its
    /// creator's actor) runs on this `@MainActor` class, so every actual
    /// read/write is serialized between the `await` points inside
    /// `loadingLevelAssetIndex`, the same "plain parallel Tasks, not a
    /// `TaskGroup`" shape `SceneryModeView.loadAllLevels` already uses, for
    /// the same Sendable-capture reasoning.
    ///
    /// On success, records the resolution into `globalObjectThumbnails` so
    /// it's immediately available everywhere else that already checks it
    /// (the Forge Palette in every other open level, `ModelViewerRenderer.
    /// globalObjectFallbacks`), no new cache for the *result* itself. On
    /// total failure, caches `objectID` in `confirmedUnresolvableObjectIDs`
    /// so a permanently-unresolvable ID (a real one exists, see that
    /// property's own doc comment) never triggers a second full disc scan.
    public func resolvingObjectIDAcrossAllLevels(_ objectID: UInt16) async -> ResolvedModelAsset? {
        if let cached = globalObjectThumbnails[objectID] { return cached }
        guard !confirmedUnresolvableObjectIDs.contains(objectID) else { return nil }

        let candidates = allLevelGraphicsCandidates()
        guard !candidates.isEmpty else {
            confirmedUnresolvableObjectIDs.insert(objectID)
            return nil
        }

        let laneCount = min(4, candidates.count)
        var foundAsset: ResolvedModelAsset?
        var foundCandidate: LevelGraphicsCandidate?
        var laneTasks: [Task<Void, Never>] = []
        for lane in Self.laneIndices(count: candidates.count, laneCount: laneCount) {
            let laneCandidates = lane.map { candidates[$0] }
            // `[weak self]` for consistency with every other Task/
            // MainActor.run touching `self` in this file, every lane is
            // awaited before this method returns, so this specific capture
            // was never a real leak, but a strong capture here reads as
            // the exception rather than a deliberate choice.
            laneTasks.append(Task { [weak self] in
                guard let self else { return }
                for candidate in laneCandidates {
                    if foundAsset != nil { return }
                    guard let index = await self.loadingLevelAssetIndex(candidate) else { continue }
                    if let resolved = AssetResolver.resolveInstanceObject(objectID: objectID, instanceSelector: 0, index: index),
                       !resolved.mesh.submeshes.isEmpty, foundAsset == nil {
                        foundAsset = resolved
                        foundCandidate = candidate
                    }
                }
            })
        }
        for laneTask in laneTasks { await laneTask.value }

        if let foundAsset {
            recordGlobalObjectThumbnail(objectID: objectID, asset: foundAsset)
            if let foundCandidate {
                await cachingCrossLevelGameObjectSourceIfSkinnedCharacter(objectID: objectID, candidate: foundCandidate)
            }
            return foundAsset
        }
        confirmedUnresolvableObjectIDs.insert(objectID)
        return nil
    }

    /// "Cross-Level Forge Placement": the byte-level counterpart to
    /// `recordGlobalObjectThumbnail`, `resolvingObjectIDAcrossAllLevels`'s
    /// own search only ever needed a `GraphicsAssetIndex` (decoded values,
    /// no raw bytes/tree) to find *whether* `objectID` resolves somewhere;
    /// this does one more, cheap real read of that same winning candidate's
    /// entry to get the raw tree + bytes `CrossFileGameObjectCopier` needs
    /// at save time. Only caches when the object is actually reachable
    /// through the *skinned-character* chain that copier supports (see its
    /// own top-level doc comment on why `modelLinks`-only objects are real,
    /// separate, unimplemented work), a rigid-prop-only resolution is left
    /// uncached here, same as an unresolved one, so a save attempt for it
    /// correctly finds nothing to copy rather than a source that would only
    /// fail later.
    private func cachingCrossLevelGameObjectSourceIfSkinnedCharacter(objectID: UInt16, candidate: LevelGraphicsCandidate) async {
        guard globalObjectGameObjectSources[objectID] == nil,
              let archiveIndex = archiveIndexByRootID[candidate.archiveRootID]
        else { return }
        let entry = candidate.entry
        let resolved: (fileRoot: ChunkNode, bytes: Data)? = await Task.detached(priority: .utility) {
            guard let data = try? BDArchiveParser.readEntryData(entry, index: archiveIndex),
                  let fileRoot = try? Self.mainTreeDriver(forExtension: (entry.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: Self.fileKind(forEntryNamed: entry.name), fileName: entry.name)
            else { return nil }
            return (fileRoot, data)
        }.value
        guard let resolved, CrossFileGameObjectCopier.hasNativeGameObject(objectID: objectID, in: resolved.fileRoot) else { return }
        globalObjectGameObjectSources[objectID] = CrossLevelGameObjectSource(objectID: objectID, sourceFileRoot: resolved.fileRoot, sourceBytes: resolved.bytes)
    }

    /// "Chunk-Based Architecture" (Part 2), "seamlessly load and stitch
    /// adjoining chunk in the 3D viewport": resolves a real `ChunkLink.path`
    /// (confirmed against the mounted disc: real values look like
    /// `levels\earth\cavern\tunnel01`, lowercase, backslash-separated, no
    /// extension, naming another `.SM2` file in the same archive) to an
    /// actual entry in any currently-open archive, parses it, and resolves
    /// its own `SceneryData` placements exactly like
    /// `resolvedLevelPlacements` does for the primary chunk. `nil` when the
    /// path doesn't resolve to any open archive's contents (the neighbor
    /// chunk hasn't been scanned/opened yet) or the neighbor has no
    /// resolvable scenery of its own.
    ///
    /// Only the neighbor's *placement translations* get offset by
    /// `chunkMatrix`'s own translation row (row 3) before being handed
    /// back, the same "position is trustworthy, full matrix orientation
    /// isn't independently confirmed" simplification already documented on
    /// `LevelViewerRenderer`'s own placement-matrix doc comment, now
    /// applied to the chunk-to-chunk alignment transform too.
    /// "Load Chunk" from the Chunk Links inspector, resolves `link.path`
    /// against the archives already open in this workspace (same lookup
    /// `loadChunkLinkPlacements` uses for the Level Viewer's 3D stitching),
    /// parses the target file through the normal ingestion path, and adds
    /// it as a real, first-class entry in `rootNodes`, so it shows up in
    /// the sidebar tree exactly like any file the user opened directly,
    /// not just as geometry merged into a 3D view. Returns `false` (and
    /// sets `lastError`) when the target isn't in a currently open archive,
    /// matching the existing "open the level or archive it belongs to
    /// first" guidance already given elsewhere in this codebase for the
    /// same lookup.
    @discardableResult
    public func openChunkLink(_ link: ChunkLink) async -> Bool {
        let normalizedPath = link.path.replacingOccurrences(of: "\\", with: "/")
        let targetName = normalizedPath.lowercased().hasSuffix(".sm2") ? normalizedPath : normalizedPath + ".sm2"

        guard let match = archiveIndexByRootID.values.compactMap({ archiveIndex -> (ArchiveIndex, ArchiveEntry)? in
            archiveIndex.entries.first { entry in
                entry.name.replacingOccurrences(of: "\\", with: "/").caseInsensitiveCompare(targetName) == .orderedSame
            }.map { (archiveIndex, $0) }
        }).first else {
            lastError = "Couldn't find \(targetName) in any currently open archive, open the level or archive it belongs to first."
            return false
        }

        // Already open from an earlier "Load Chunk" click, or from being
        // separately expanded in the archive tree, select it instead of
        // adding a duplicate root.
        if let existing = rootNodes.first(where: { $0.displayName.caseInsensitiveCompare(match.1.name) == .orderedSame }) {
            select(existing)
            return true
        }

        let entry = match.1
        let index = match.0
        guard let node = await Task.detached(priority: .userInitiated, operation: { () -> ChunkNode? in
            guard let data = try? BDArchiveParser.readEntryData(entry, index: index) else { return nil }
            return try? Self.mainTreeDriver(forExtension: (entry.name as NSString).pathExtension)
                .parseChunkFile(data: data, fileKind: .sm2, fileName: entry.name)
        }).value else {
            lastError = "Failed to parse \(entry.name)."
            return false
        }

        rootNodes.append(node)
        select(node)
        return true
    }

    public func loadChunkLinkPlacements(for link: ChunkLink) async -> (fileName: String, placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)])? {
        let normalizedPath = link.path.replacingOccurrences(of: "\\", with: "/")
        let targetName = normalizedPath.lowercased().hasSuffix(".sm2") ? normalizedPath : normalizedPath + ".sm2"

        guard let match = archiveIndexByRootID.values.compactMap({ archiveIndex -> (ArchiveIndex, ArchiveEntry)? in
            archiveIndex.entries.first { entry in
                entry.name.replacingOccurrences(of: "\\", with: "/").caseInsensitiveCompare(targetName) == .orderedSame
            }.map { (archiveIndex, $0) }
        }).first else { return nil }

        return await Task.detached(priority: .userInitiated) { () -> (String, [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)])? in
            guard let data = try? BDArchiveParser.readEntryData(match.1, index: match.0),
                  let fileRoot = try? Self.mainTreeDriver(forExtension: (match.1.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: .sm2, fileName: match.1.name)
            else { return nil }

            var scenery: SceneryAsset?
            func walk(_ node: ChunkNode) {
                if scenery == nil, case .scenery(let found) = node.payload, !found.placements.isEmpty { scenery = found }
                for child in node.children { walk(child) }
            }
            walk(fileRoot)
            guard let scenery else { return (match.1.name, []) }

            let index = AssetResolver.buildIndex(fileRoot: fileRoot)
            var results: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)] = []
            var droppedCount = 0
            for placement in scenery.placements {
                guard let transform = placement.worldTransform,
                      let resolved = AssetResolver.resolveModelID(placement.modelID, displayName: "Scenery Object #\(placement.modelID)", index: index)
                else { droppedCount += 1; continue }
                // `matrixFileOffset` deliberately dropped to `nil`, even
                // though the real placement carries one, it's a byte
                // position in *this stitched neighbor's own file*, not
                // `levelNode`'s (the only file `deleteObject`'s removal
                // path can actually save back into), so treating it as
                // deletable here would mark the wrong file's bytes.
                results.append((transform.position, transform.rotation, transform.scale, resolved, nil))
            }
            // "Chunk Stitching Rendering Bug": these two `continue`s used to
            // drop a stitched neighbor's scenery/terrain placements with no
            // trace at all, indistinguishable from "stitching worked but
            // there was nothing there." Surfacing the real count here (and
            // in `ModelViewerRenderer.stitchChunk`'s own build-failure count)
            // is what actually lets a real drop be diagnosed instead of
            // guessed at.
            if droppedCount > 0 {
                AppLog.rendering.debug("Chunk stitch \(match.1.name), \(droppedCount) of \(scenery.placements.count) scenery placements failed to resolve (missing transform or unresolvable modelID), dropped before rendering")
            }
            return (match.1.name, results)
        }.value
    }

    /// "Deep Hierarchy & Linked Asset Resolution": the parent composite
    /// object `node` belongs to, plus every component that composite is
    /// built from, one call standing in for what used to be scattered
    /// across the Model Viewer's separate sections.
    public func relationalChain(for node: ChunkNode) -> RelationalChain? {
        resolveComposite(for: node).map(RelationalChain.init(asset:))
    }

    /// Jumps the sidebar selection to the chunk backing `component`, the
    /// "click a linked component to go inspect it directly" affordance in
    /// the relational chain panel. Searches every parsed file (component
    /// IDs are the same global, hash-like values discussed on
    /// `resolveComposite`, so the record isn't guaranteed to be in the same
    /// file as the composite that references it); silently does nothing
    /// findable if the underlying chunk isn't in the currently loaded
    /// workspace at all, e.g. a texture record from an archive entry that
    /// hasn't been scanned/expanded yet.
    public func selectComponent(_ component: LinkedComponent) {
        guard let found = findNode(matching: component, in: rootNodes) else {
            lastError = "\(component.displayName) isn't loaded in the current workspace yet, try Scan Archive."
            return
        }
        select(found)
    }

    private func findNode(matching component: LinkedComponent, in nodes: [ChunkNode]) -> ChunkNode? {
        for node in nodes {
            if matches(node.payload, component) { return node }
            if !isExpandableArchiveEntry(node), let found = findNode(matching: component, in: node.children) {
                return found
            }
        }
        return nil
    }

    private func matches(_ payload: ChunkPayload?, _ component: LinkedComponent) -> Bool {
        switch (payload, component.kind) {
        case (.mesh(let mesh), .mesh): return mesh.id == component.recordID
        case (.material(let material), .material): return material.id == component.recordID
        case (.texture(let texture), .texture): return texture.id == component.recordID
        case (.skeleton(let skeleton), .skeleton): return skeleton.id == component.recordID
        case (.animation(let animation), .animation): return animation.id == component.recordID
        default: return false
        }
    }

    /// Memoized entry point over `findFileRootRecursive`, every one of this
    /// view model's ~35 call sites passes `rootNodes` itself (never a
    /// sub-slice), always looking up the file root for one already-in-hand
    /// node. That plain DFS is a full walk of *every* parsed node reachable
    /// from `rootNodes` in the worst case, fine for a single lookup, but
    /// several inspector views (e.g. `WorldPlacementInspectorViews`' record
    /// editor) call `canSaveEdits`/`rawBytes`/`originalFileName`, all of
    /// which route through here, several times in a single view body
    /// evaluation. On a fully-scanned disc archive (hundreds of level files,
    /// tens of thousands of decoded nodes) that's tens of thousands of node
    /// visits repeated on every re-render of an open inspector: the concrete
    /// "the app runs really slow when everything is parsed" cost this
    /// session's profiling traced. Keyed on `ChunkNode.id` (the stable UUID
    /// identity `ChunkNode`'s own doc comment establishes) rather than
    /// `ObjectIdentifier`, so a deallocated-and-reused heap address can never
    /// produce a false hit. `rootNodes`'s `didSet` clears this whenever the
    /// tree structurally changes, so a stale answer is never returned, a
    /// cache miss just re-walks, same cost as before this existed.
    private func findFileRoot(containing target: ChunkNode, in nodes: [ChunkNode]) -> ChunkNode? {
        if let cached = fileRootCache[target.id] { return cached }
        let result = findFileRootRecursive(containing: target, in: nodes)
        fileRootCache[target.id] = result
        return result
    }

    /// Every `SectionType` `RM2Parser` can dispatch a *top-level* (Tier 0)
    /// entry to as a container section, kept in sync with `RM2Parser.
    /// containerTypes` by hand, since that list is private to a different
    /// module. A `.RM2` file root's own top-level entries aren't guaranteed
    /// to include Code or Graphics at all: a real, reported bug had this
    /// set missing `.instance`/`.instanceDemo`/`.instanceMB` (RM2 sub-IDs
    /// 0-7), any actor file whose only top-level section was its Instance
    /// container (no Code, no Graphics, a plausible, real shape for a
    /// simple level) was never recognized as a file root at all, so every
    /// Instance/Trigger/Camera/ColData record inside it silently came back
    /// empty from `recordsInSameFile`, even once the sibling `.rm2` was
    /// correctly located. `.graphicsMB`/`.codeMB` were missing for the same
    /// reason, just not yet reported.
    private static let fileRootSectionTypes: Set<SectionType> = [
        .graphics, .graphicsX, .graphicsD, .graphicsMB,
        .code, .codeX, .codeDemo, .codeMB,
        .instance, .instanceDemo, .instanceMB,
    ]

    /// Depth-first search for the nearest ancestor of `target` that looks
    /// like a parsed file root (a `.null`-typed node with a Graphics, Code,
    /// or Instance section child), i.e. the specific `.RM2`/`.SM2` a
    /// RigidModel, GraphicsInfo, or Instance/Trigger/Camera record came
    /// from, so its sibling Texture/Material sections (or sibling actor
    /// file) can be found. Plain tree search rather than parent pointers:
    /// nodes get replaced (not mutated) elsewhere in this view model (see
    /// `expandArchiveEntry`), which would leave stale parent references.
    private func findFileRootRecursive(containing target: ChunkNode, in nodes: [ChunkNode], currentRoot: ChunkNode? = nil) -> ChunkNode? {
        let fileRootSectionTypes = Self.fileRootSectionTypes
        for node in nodes {
            let looksLikeFileRoot = node.sectionType == .null && node.children.contains { fileRootSectionTypes.contains($0.sectionType) }
            let nextRoot = looksLikeFileRoot ? node : currentRoot
            if node === target { return nextRoot }
            if let found = findFileRootRecursive(containing: target, in: node.children, currentRoot: nextRoot) {
                return found
            }
        }
        return nil
    }

    /// Every already-parsed file root reachable from `nodes`, the
    /// workspace-wide counterpart to `findFileRoot`, used to fall back to a
    /// cross-file search. Doesn't descend into an unexpanded archive entry
    /// (`isExpandableArchiveEntry`): those have no decoded payload yet, so
    /// there's nothing in them to match against regardless.
    private func allFileRoots(in nodes: [ChunkNode]) -> [ChunkNode] {
        let fileRootSectionTypes = Self.fileRootSectionTypes
        var roots: [ChunkNode] = []
        for node in nodes {
            if node.sectionType == .null && node.children.contains(where: { fileRootSectionTypes.contains($0.sectionType) }) {
                roots.append(node)
            }
            if !isExpandableArchiveEntry(node) {
                roots.append(contentsOf: allFileRoots(in: node.children))
            }
        }
        return roots
    }

    /// One-click bundled export: the mesh (OBJ), an `.mtl` linking each
    /// resolved submesh material to its exported texture, every uniquely
    /// referenced texture (PNG), and every candidate animation's decoded
    /// curve data (JSON), all in one folder, so opening the result in
    /// another tool (Blender, etc.) shows a properly textured model instead
    /// of a pile of unrelated files.
    /// Performance fix (audit): PNG encode + OBJ/MTL serialize + real disk
    /// writes for potentially many textures used to run inline on whatever
    /// actor called this (a SwiftUI button action). `completeAssetFiles`
    /// was already `nonisolated static` (no main-actor affinity), so
    /// wrapping the whole build+write in `Task.detached` is a direct,
    /// low-risk move, nothing about what gets written changes.
    public func exportCompleteAsset(_ asset: ResolvedModelAsset, to directory: URL) async {
        let baseName = Self.sanitizedFileName(asset.displayName)
        let assetFolder = directory.appendingPathComponent(baseName)
        do {
            let built = try await Task.detached(priority: .userInitiated) {
                let built = try Self.completeAssetFiles(for: asset, baseName: baseName)
                try FileManager.default.createDirectory(at: assetFolder, withIntermediateDirectories: true)
                for file in built.files {
                    let destination = assetFolder.appendingPathComponent(file.relativePath)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try file.data.write(to: destination)
                }
                return built
            }.value
            statusMessage = "Exported complete asset (\(built.materialCount) material(s), \(built.textureCount) texture(s), \(built.animationCount) animation(s)) to \(assetFolder.path)."
        } catch {
            lastError = "Export failed: \(error)"
        }
    }

    /// "Cross-Object Dependency Packaging" (blueprint 3.2), "Export with
    /// Dependencies": the same mesh/textures/materials/animations
    /// `exportCompleteAsset` writes as loose files gets bundled instead
    /// into one portable `.crate`, reusing `CrateExporter.export`'s
    /// existing multi-file `layer0/` packaging (already built for blueprint
    /// 3.3, just never called with more than one file). Built from the same
    /// `resolveComposite` linked-asset graph as the folder export, nothing
    /// here invents a new notion of "dependency," it's the real mesh ->
    /// material -> texture / mesh -> animation links this codebase already
    /// resolves and trusts elsewhere.
    /// Performance fix (audit), same reasoning as `exportCompleteAsset`,
    /// plus this one also goes through `CrateExporter.export`'s real `zip`
    /// subprocess (see `exportAsCrate`'s own doc comment).
    public func exportCompleteAssetAsCrate(_ asset: ResolvedModelAsset, metadata: CrateMetadata, to crateURL: URL) async {
        let baseName = Self.sanitizedFileName(asset.displayName)
        do {
            let built = try await Task.detached(priority: .userInitiated) {
                let built = try Self.completeAssetFiles(for: asset, baseName: baseName)
                let files = built.files.map { (relativePath: "\(baseName)/\($0.relativePath)", data: $0.data) }
                try CrateExporter.export(files: files, metadata: metadata, to: crateURL)
                return built
            }.value
            statusMessage = "Exported mod crate with \(built.materialCount) material(s), \(built.textureCount) texture(s), \(built.animationCount) animation(s) to \(crateURL.lastPathComponent)."
        } catch {
            lastError = "Crate export failed: \(error)"
        }
    }

    private struct CompleteAssetFiles {
        var files: [(relativePath: String, data: Data)]
        var materialCount: Int
        var textureCount: Int
        var animationCount: Int
    }

    /// Builds every file `exportCompleteAsset`/`exportCompleteAssetAsCrate`
    /// need, purely in memory, paths are relative to the asset's own
    /// folder (e.g. `"\(baseName).obj"`, `"animations/animation_1.json"`),
    /// so callers decide whether that folder lands loose on disk or inside
    /// a zipped crate's `layer0/`.
    private nonisolated static func completeAssetFiles(for asset: ResolvedModelAsset, baseName: String) throws -> CompleteAssetFiles {
        var files: [(relativePath: String, data: Data)] = []

        var exportedTextureNames: [UInt32: String] = [:]
        for material in asset.submeshMaterials {
            guard let textureID = material.textureID, let texture = material.texture, exportedTextureNames[textureID] == nil else { continue }
            let texName = "texture_\(textureID)"
            let pngData = try TextureExporter.pngData(texture)
            files.append((relativePath: "\(texName).png", data: pngData))
            exportedTextureNames[textureID] = texName
        }

        let mtlFileName = "\(baseName).mtl"
        var seenMaterials: Set<UInt32> = []
        var mtlLines = ["# Generated by TwinsanityStudio"]
        for material in asset.submeshMaterials {
            guard let materialID = material.materialID, !seenMaterials.contains(materialID) else { continue }
            seenMaterials.insert(materialID)
            mtlLines.append("")
            mtlLines.append("newmtl material_\(materialID)")
            mtlLines.append("Kd 1.000 1.000 1.000")
            if let textureID = material.textureID, let texName = exportedTextureNames[textureID] {
                mtlLines.append("map_Kd \(texName).png")
            }
        }
        guard let mtlData = (mtlLines.joined(separator: "\n") + "\n").data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        files.append((relativePath: mtlFileName, data: mtlData))

        let submeshMaterialIDs = asset.submeshMaterials.map(\.materialID)
        let objContents = try OBJExporter.contents(asset.mesh, submeshMaterialIDs: submeshMaterialIDs, mtlFileName: mtlFileName)
        guard let objData = objContents.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        files.append((relativePath: "\(baseName).obj", data: objData))

        for animation in asset.availableAnimations {
            let json = Self.animationJSON(animation)
            guard let jsonData = json.data(using: .utf8) else { continue }
            files.append((relativePath: "animations/animation_\(animation.id).json", data: jsonData))
        }

        return CompleteAssetFiles(files: files, materialCount: seenMaterials.count, textureCount: exportedTextureNames.count, animationCount: asset.availableAnimations.count)
    }

    private nonisolated static func animationJSON(_ animation: AnimationAsset) -> String {
        func trackDict(_ track: AnimationTrack) -> [String: Any] {
            [
                "jointCount": track.jointSettings.count,
                "staticTransformCount": track.staticTransforms.count,
                "totalFrames": track.totalFrames,
                "componentsPerFrame": track.componentsPerFrame,
                "frames": track.frames.map { $0.values.map { Int($0) } }
            ]
        }
        let dict: [String: Any] = [
            "id": animation.id,
            "body": trackDict(animation.body),
            "facial": trackDict(animation.facial)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private nonisolated static func sanitizedFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let withoutExtension = (base as NSString).deletingPathExtension
        let cleaned = withoutExtension.isEmpty ? base : withoutExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = String(cleaned.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return sanitized.isEmpty ? "asset" : sanitized
    }

    // MARK: - Export

    /// Performance fix (audit): PNG encode of every mip level + disk write,
    /// same off-main move as the other export functions in this section.
    public func exportTexturePNG(_ asset: TextureAsset, suggestedName: String, to directory: URL) async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try TextureExporter.exportAllLevels(asset, baseName: suggestedName, to: directory)
            }.value
            statusMessage = "Exported \(suggestedName).png (+\(asset.mips.count) mip level(s))."
        } catch {
            lastError = "Export failed: \(error)"
        }
    }

    /// Performance fix (audit), same reasoning as `exportTexturePNG`.
    public func exportMeshOBJ(_ mesh: MeshAsset, suggestedName: String, to directory: URL) async {
        do {
            let url = directory.appendingPathComponent(suggestedName).appendingPathExtension("obj")
            try await Task.detached(priority: .userInitiated) {
                try OBJExporter.export(mesh, to: url)
            }.value
            statusMessage = "Exported \(suggestedName).obj."
        } catch {
            lastError = "Export failed: \(error)"
        }
    }

    // MARK: - Batch export (blueprint 3.1)

    /// Non-nil while a batch export (see `exportBatch`) is running, drives
    /// the Models Hub's progress indicator.
    public var batchExportProgress: (completed: Int, total: Int)?

    /// "One-Click Batch Export": runs the same per-asset `exportCompleteAsset`
    /// logic the single-asset "Export Complete Asset…"/"Export as Group…"
    /// actions already use, queued across a multi-selection instead of
    /// called once, each asset gets its own subfolder under `directory`
    /// (see `exportCompleteAsset`), so there's no collision between them,
    /// including when running concurrently.
    ///
    /// Performance fix (audit): this used to call the (then-synchronous)
    /// `exportCompleteAsset` strictly one asset at a time, with
    /// `Task.yield()` only ever letting the progress bar repaint between
    /// them, real work never actually overlapped. `exportCompleteAsset`
    /// is now itself `async` (its own real PNG/OBJ work moved off-main , 
    /// see that function's doc comment), so a bounded `withTaskGroup` here
    /// lets several assets' exports genuinely run in parallel, the same
    /// sliding-window-concurrency shape `scanAllArchives` already proves
    /// works well in this exact file.
    public func exportBatch(_ assets: [ResolvedModelAsset], to directory: URL) async {
        guard !assets.isEmpty else { return }
        batchExportProgress = (0, assets.count)
        let maxConcurrent = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        var completed = 0
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            func addNext() {
                guard nextIndex < assets.count else { return }
                let asset = assets[nextIndex]
                nextIndex += 1
                group.addTask { await self.exportCompleteAsset(asset, to: directory) }
            }
            for _ in 0..<min(maxConcurrent, assets.count) { addNext() }
            while await group.next() != nil {
                completed += 1
                batchExportProgress = (completed, assets.count)
                addNext()
            }
        }
        statusMessage = "Batch export complete, \(assets.count) asset(s) exported to \(directory.path)."
        batchExportProgress = nil
    }
}
