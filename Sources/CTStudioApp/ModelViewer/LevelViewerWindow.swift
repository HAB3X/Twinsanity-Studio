import SwiftUI
import AppKit
import simd
import CTCore
import CTModels
import CTParsers
import CTExport
import UniformTypeIdentifiers
import AVFoundation

/// Bundles a decoded `SceneryData` record with its already-resolved
/// placements (mesh + textures per object), resolved once, when the user
/// clicks "Open Level Viewer" (`SceneryInspectorView`), rather than redone
/// on every render of this window.
public struct LevelViewerContext: Identifiable {
    public let id = UUID()
    public var scenery: SceneryAsset
    /// The real `.sm2`/`.smx` record `scenery` was decoded from, every
    /// entry point into the Level Viewer is opened *from* this exact node
    /// (`openLevelViewer(for:node:)`'s own `node` parameter), so it's
    /// always the scenery file, never `referenceNodeForFileOps`'s actor
    /// (`.rm2`) file. Needed for anything that has to resolve the
    /// scenery file's own root, "Add Scenery From Other Level…" passing
    /// the actor file's root here by mistake was a real bug (fixed by
    /// adding this field instead of trying to derive it from a node in
    /// the wrong file).
    public var sceneryNode: ChunkNode
    public var placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)]
    /// "Direct .RM2 Write-Back": every `Instance` record (crate, enemy,
    /// platform, …) from the same file, paired with the `ChunkNode` its
    /// transform gets patched back into on save. Drawn as placeholder
    /// marker geometry, not a real mesh, this build has no verified
    /// mapping from an `Instance`'s `objectID` to the `RigidModel` it
    /// actually looks like (unlike `SceneryData` placements, which
    /// reference a model ID directly), so rendering anything more specific
    /// here would be a guess dressed up as data. The marker's *position* is
    /// exactly what's on disk, and dragging/saving it is fully real.
    public var instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)]
    /// "Comprehensive Instance Population" (Part 4B): real resolved
    /// geometry for whichever `instanceMarkers` entries this build could
    /// actually resolve (`WorkspaceViewModel.resolvedInstanceAssets`),
    /// keyed by that entry's `node.id`. An entry with no matching key here
    /// draws as the amber placeholder marker instead, the mandate's own
    /// "use a colored bounding-box proxy when a model is missing."
    public var resolvedInstanceAssets: [UUID: ResolvedModelAsset]
    /// "No Cross-Level GPU Cache" fix: the subset of `resolvedInstanceAssets`'
    /// keys whose geometry resolved *only* through the shared, process-wide
    /// `Startup/Default.rm2` fallback (`defaultAssetIndex`) rather than this
    /// level's own `assetIndex`, real crates/pickups/Wumpa reused across
    /// every level, not this level's own unique content. See
    /// `WorkspaceViewModel.resolvedInstanceAssets`'s doc comment for how
    /// this is determined (a real per-marker re-check, not a `recordID`
    /// guess) and why it's the one case a persistent, cross-level GPU
    /// texture/mesh cache is actually safe: `defaultAssetIndex` is the same
    /// single cached index for the whole session, so a `recordID` from
    /// *this specific set* can't collide with a different level's own
    /// content the way a level's own `assetIndex` genuinely can.
    /// `LevelViewerRenderer` routes exactly these through
    /// `ModelViewerGPUContext.sharedDefaultAssetGPUCache` instead of its own
    /// per-upload `TextureUploadCache`/`MeshUploadCache`.
    public var resolvedFromSharedDefault: Set<UUID>
    /// "The Forge Palette" (Part 4C): the same index `resolvedInstanceAssets`
    /// was built from, kept around so `LevelViewerRenderer` can resolve a
    /// *newly placed* object's real geometry without needing a second,
    /// separate index-build pass.
    public var assetIndex: GraphicsAssetIndex
    /// "No More Placeholder Squares": the shared `Startup/Default.rm2`
    /// index, see `AssetResolver.resolveInstanceObject`'s doc comment , 
    /// so a newly Forge-Palette-placed shared object also resolves to
    /// real geometry, not just existing Instance markers.
    public var defaultAssetIndex: GraphicsAssetIndex
    /// "Level Editor Overhaul": every `Trigger`/`Camera`/`SoundEffect`
    /// record from the same file, triggers/cameras feed their scene
    /// layers (wireframe boxes, select-and-inspect only, no write path
    /// yet), sounds feed the Level Audio panel.
    public var triggers: [(node: ChunkNode, trigger: TriggerVolume)]
    public var cameras: [(node: ChunkNode, camera: PlacedCamera)]
    public var sounds: [(node: ChunkNode, sound: SoundEffectAsset)]
    /// "Chunk-Based Architecture" (Part 2): every real `ChunkLink` in this
    /// chunk, each one names a neighboring `.SM2` file this level can
    /// stream in, plus (when present) the boundary wall geometry that
    /// triggers it. See `ChunkLinksAsset`'s doc comment.
    public var chunkLinks: [(node: ChunkNode, link: ChunkLink)]
    /// "AI Pathfinding/Navmesh Editor" (roadmap 5.1): real `AIPosition`
    /// waypoints (spatial, feed the "AI Waypoints" scene layer) and
    /// `AIPath` records (no position of their own, see `AIPathRecord`'s
    /// doc comment, factual list panel only).
    public var aiPositions: [(node: ChunkNode, marker: AIPositionMarker)]
    public var aiPaths: [(node: ChunkNode, path: AIPathRecord)]
    /// "Collision / Ground Floor": the level's real, decoded collision
    /// mesh(es), the actual walkable ground, previously never rendered
    /// anywhere in this Level Viewer (only scattered decorative scenery
    /// props were), which is what made a real level look like scattered
    /// pieces with massive gaps between them. See `WorkspaceViewModel.
    /// collisionMeshRecords`'s doc comment.
    public var collisionMeshes: [(node: ChunkNode, mesh: CollisionMesh)]
    /// "Real Flags for Forge-Placed Objects": real `InstanceTemplate.
    /// properties` values, keyed by `objectID`, this level's own real
    /// templates merged over the shared `Default.rm2` fallback (level wins).
    /// See `WorkspaceViewModel.FileRecordBundle.instanceTemplateProperties`'s
    /// doc comment for what this is and why it exists; `LevelViewerRenderer`
    /// reads this to give a freshly Forge-placed object the real Flags value
    /// its type actually needs, instead of one hardcoded guess for every
    /// object type.
    public var instanceTemplatePropertiesByObjectID: [UInt16: UInt32]

    public init(
        scenery: SceneryAsset,
        sceneryNode: ChunkNode,
        placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)],
        instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)] = [],
        resolvedInstanceAssets: [UUID: ResolvedModelAsset] = [:],
        resolvedFromSharedDefault: Set<UUID> = [],
        assetIndex: GraphicsAssetIndex = GraphicsAssetIndex(),
        defaultAssetIndex: GraphicsAssetIndex = GraphicsAssetIndex(),
        triggers: [(node: ChunkNode, trigger: TriggerVolume)] = [],
        cameras: [(node: ChunkNode, camera: PlacedCamera)] = [],
        sounds: [(node: ChunkNode, sound: SoundEffectAsset)] = [],
        chunkLinks: [(node: ChunkNode, link: ChunkLink)] = [],
        aiPositions: [(node: ChunkNode, marker: AIPositionMarker)] = [],
        aiPaths: [(node: ChunkNode, path: AIPathRecord)] = [],
        collisionMeshes: [(node: ChunkNode, mesh: CollisionMesh)] = [],
        instanceTemplatePropertiesByObjectID: [UInt16: UInt32] = [:]
    ) {
        self.scenery = scenery
        self.sceneryNode = sceneryNode
        self.placements = placements
        self.instanceMarkers = instanceMarkers
        self.resolvedInstanceAssets = resolvedInstanceAssets
        self.resolvedFromSharedDefault = resolvedFromSharedDefault
        self.assetIndex = assetIndex
        self.defaultAssetIndex = defaultAssetIndex
        self.triggers = triggers
        self.cameras = cameras
        self.sounds = sounds
        self.chunkLinks = chunkLinks
        self.aiPositions = aiPositions
        self.aiPaths = aiPaths
        self.collisionMeshes = collisionMeshes
        self.instanceTemplatePropertiesByObjectID = instanceTemplatePropertiesByObjectID
    }
}

/// "Scenery/Level Assembly" + "Forge-Style Editor Mode" (blueprint 6.1/6.2):
/// a multi-object Metal viewport drawing every resolved scenery placement,
/// with a translate gizmo on the selected object, coordinate nudge fields,
/// snap-to-grid, and a drag target for adding new objects from the Models
/// Hub. Scenery placements themselves still have no write path, see
/// `LevelViewerContext.instanceMarkers`'s doc comment, but the amber
/// marker cubes alongside them (one per `Instance` record: crate, enemy,
/// platform, …) are fully save-able via "Save Level Overrides…", the same
/// safe decode -> edit -> encode -> patch -> save-as-copy loop used
/// throughout this build.
/// "Level Editor Overhaul": a coarse preset over the "Scene Layers" panel
/// below, picking one just sets `layerVisibility` to a sensible starting
/// combination; the checkboxes remain independently adjustable afterward,
/// same as the request's "regardless of mode" wording.
enum LevelViewMode: CaseIterable {
    case geometryOnly, populated

    var displayName: String {
        switch self {
        case .geometryOnly: return "Geometry Only"
        case .populated: return "Fully Populated"
        }
    }

    var layerPreset: Set<SceneLayer> {
        switch self {
        case .geometryOnly: return [.scenery, .collision]
        case .populated: return Set(SceneLayer.allCases)
        }
    }
}

/// "Halo Reach Forge / Minecraft"-style mode rail: instead of every panel
/// stacked in one long scroll (the pre-overhaul layout, ~15 panels, a
/// real level's object count alone runs into the hundreds), a beginner
/// picks one task at a time and only sees the controls for it. The
/// current-selection tools (Transform/gizmo, the selected object's own
/// inspector, the Objects list) stay pinned below the rail regardless of
/// mode, every mode still needs "what am I looking at right now."
enum LevelEditorMode: String, CaseIterable, Identifiable {
    case select, place, forgePalette, scenery, terrain, ai, audio, advanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .select: return "Select"
        case .place: return "Add"
        case .forgePalette: return "Forge"
        case .scenery: return "Scenery"
        case .terrain: return "Terrain"
        case .ai: return "AI"
        case .audio: return "Audio"
        case .advanced: return "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .place: return "plus.app.fill"
        case .forgePalette: return "hammer.fill"
        case .scenery: return "tree.fill"
        case .terrain: return "square.grid.3x3.fill"
        case .ai: return "point.3.connected.trianglepath.dotted"
        case .audio: return "speaker.wave.2.fill"
        case .advanced: return "ellipsis.circle.fill"
        }
    }

    var helpText: String {
        switch self {
        case .select: return "Level stats and save"
        case .place: return "Add a new Trigger or Camera"
        case .forgePalette: return "Forge Palette, place new Instances of any object in the game"
        case .scenery: return "Every real scenery model, this level first, click one to place a new copy"
        case .terrain: return "Scene layer visibility and view mode"
        case .ai: return "AI waypoints and paths"
        case .audio: return "Chunk audio and scripted-trigger events"
        case .advanced: return "Chunk links and cross-engine (Wrath of Cortex) data"
        }
    }
}

/// "Numbered Hotbar (1-9)": one Forge Palette entry pinned to a slot.
struct HotbarEntry: Equatable {
    let objectID: UInt16
    let name: String
}

struct LevelViewerWindow: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.undoManager) private var undoManager
    let context: LevelViewerContext

    @State private var renderer: LevelViewerRenderer?
    @State private var selectedIndex: Int?
    /// "Align & Distribute" (`SpatialAlignmentTool`): a second, additive
    /// selection set purely for the batch position tools below, kept
    /// deliberately separate from `selectedIndex` (the single-object gizmo/
    /// inspector selection this app otherwise has everywhere) rather than
    /// generalizing the whole app to multi-select, that's real scope this
    /// task didn't ask for. Populated by ⌘-click in the Objects list
    /// (`toggleAlignmentSelection`); cleared on delete/duplicate, since
    /// either can shift every index after the changed one.
    @State private var alignmentSelection: Set<Int> = []
    /// "Batch Editing, Scripting": presents `BatchScriptSheet` against
    /// `alignmentSelection`, same picked set as Align/Distribute/Batch
    /// Delete above.
    @State private var showingBatchScript = false
    /// "Set AI Path on a Newly-Placed AI": the `objects` index the AI Path
    /// assignment sheet is currently editing, or `nil` when it's closed.
    @State private var aiPathAssignmentTargetIndex: Int?
    /// The sheet's own in-progress selection, real `AIPath` IDs, seeded
    /// from the target object's current `pendingPathIDs` when the sheet
    /// opens, committed back via `commitAIPathAssignment` on "Done."
    @State private var aiPathAssignmentSelection: Set<UInt32> = []
    /// See `syncFromRenderer`'s own doc comment, tracked purely to detect
    /// an object count change across an undo/redo notification, which is
    /// the real signal that indices (and so `alignmentSelection`) may have
    /// shifted.
    @State private var lastKnownObjectCount: Int?
    /// "Collapsible Sidebar Sections" (QoL): every list-heavy panel below
    /// starts collapsed, a real level's object count runs into the
    /// hundreds, and previously there was no way to reach the panels
    /// beneath it without scrolling straight past all of them first.
    @State private var isObjectListExpanded = false
    @State private var isLevelEventsExpanded = false
    @State private var isAIPathsExpanded = false
    @State private var viewMode: LevelViewMode = .populated
    /// Collision starts hidden, real, opaque ground-floor fill is useful
    /// for confirming a level's actual walkable surface, but as a default
    /// it visually dominates every other layer and most editing work
    /// doesn't need it. Toggle it back on any time from the Terrain panel;
    /// the "Fully Populated" preset also still includes it, since that
    /// button is an explicit "show me everything" request.
    ///
    /// Chunk boundaries (load-wall quads) also start hidden, a real,
    /// user-reported bug: a `ChunkLink.loadWall` is a genuinely flat quad
    /// standing vertically *by design* (it marks a streaming boundary, not
    /// terrain), and with this layer on by default it was being mistaken
    /// for broken scenery, especially since its old fill color read close
    /// enough to sandy/rock terrain tones to blend in (see
    /// `ModelViewerRenderer.rebuildOverlayBuffer`'s `wallColor`, now a
    /// saturated, unmistakably-not-terrain magenta). Same "opt into the
    /// debug overlay" posture as collision, and same "Fully Populated"
    /// exception.
    @State private var layerVisibility: Set<SceneLayer> = Set(SceneLayer.allCases).subtracting([.collision, .chunkBoundaries])
    /// "Halo Reach Forge / Minecraft"-style mode rail, see
    /// `LevelEditorMode`'s own doc comment.
    @State private var editorMode: LevelEditorMode = .select
    /// One search field drives both the Object list (filters it directly)
    /// and the Forge Palette (forwarded through its own `searchText`
    /// binding), a beginner shouldn't need to know which of six mode
    /// tabs a specific object or placeable lives under before they can
    /// search for it.
    @State private var sidebarSearchText = ""
    @State private var isControlsLegendExpanded = false
    @State private var positionX: String = ""
    @State private var positionY: String = ""
    @State private var positionZ: String = ""
    @State private var rotationX: String = ""
    @State private var rotationY: String = ""
    @State private var rotationZ: String = ""
    @State private var scaleX: String = ""
    @State private var scaleY: String = ""
    @State private var scaleZ: String = ""
    @State private var gizmoMode: GizmoMode = .translate
    @State private var snapToGrid = true
    @State private var gridSize: Double = 1.0
    @State private var magnetSnapEnabled = true
    @State private var rotationSnapDegrees: Double = 15.0
    @State private var showCollisionVolume = false
    @State private var showCrateChains = false
    /// "Cull Back Faces", off by default, matching this viewer's
    /// long-standing behavior exactly (see `LevelViewerRenderer.
    /// cullBackFaces`'s own doc comment for why: some real level geometry
    /// is deliberately thin/single-sided, foliage cards, decals, and
    /// this viewer has always lit both faces so that content stays visible
    /// from any angle, matching an inspection tool's priorities over
    /// physically-accurate single-sided rendering). Real, reported
    /// performance finding: every opaque triangle in the visible scene is
    /// fragment-shaded twice (front and back) every frame regardless of
    /// this setting, turning it on is a real, roughly 2x reduction in
    /// per-frame fragment work, at the cost of thin/single-sided geometry
    /// no longer being visible from its back side. A toggle rather than a
    /// silent default flip: this is a visible behavior change, not purely
    /// a performance tweak, so it's the user's call to make per-session.
    @State private var cullBackFaces = false
    @State private var isDropTargeted = false
    /// "The Forge Palette" (Part 4C): non-nil while a palette pick is armed
    /// and waiting for the viewport click that places it, mirrors
    /// `renderer.pendingPlacementObjectID` into SwiftUI `@State` the same
    /// way `selectedIndex` mirrors `renderer.selectedObjectIndex`, since
    /// the renderer itself is a plain class AppKit mutates directly, not an
    /// `ObservableObject`.
    @State private var armedPlacement: (objectID: UInt16, name: String)?
    /// "Scenery placement, arm-then-click": the Scenery-tab counterpart to
    /// `armedPlacement` above, mirrors `renderer.pendingPlacementScenery`
    /// the same way, plus `key` (the same `"\(section.id)|\(entry.id)"` key
    /// `SceneryModeView.tile(section:entry:)` already computes) so that
    /// view can yellow-highlight the exact armed tile without needing to
    /// reach back into the renderer's own richer payload.
    @State private var armedScenery: (key: String, name: String)?
    /// "Spawn Interactive Cortex (Prop)", arm-then-click, mirrors
    /// `armedPlacement`/`armedScenery`'s own role, just a plain `Bool`
    /// since there's only ever the one prop-skin kind (no per-entry name/
    /// key to track like the palette or scenery catalog have).
    @State private var armedPropSkin = false
    /// "AI Path Connector Visualization + In-Viewport Endpoint Picking":
    /// non-nil while a path's Start/End waypoint pick is armed, mirroring
    /// `renderer.pendingAIPathEndpointPick` into `@State` the same way
    /// `armedPlacement` mirrors `renderer.pendingPlacementObjectID`.
    /// `isNew` distinguishes a still-session-only path (`newAIPaths`,
    /// edited via `settingNewAIPathArgs`) from a real, on-disk one (edited
    /// via `settingAIPathArgs`), the two are stored differently in the
    /// renderer, so applying a pick needs to know which setter to call.
    @State private var pendingAIPathPick: (pathID: UInt32, isNew: Bool, isStart: Bool)?
    /// The one instance of `SceneryModeView`'s loaded-levels cache, `@State`
    /// specifically so it survives switching `editorMode` away from
    /// `.scenery` and back (see `SceneryLoadCache`'s own doc comment for the
    /// bug this fixes). `SceneryLoadCache` is `@Observable`, not a legacy
    /// `ObservableObject`, so `@State` (not `@StateObject`) is the correct
    /// owner here.
    @State private var sceneryCache = SceneryLoadCache()
    /// See `SceneryModeView.scrollAnchorSectionID`'s own doc comment, real,
    /// reported bug: switching mode tabs and back reset the Scenery
    /// palette's scroll position to the top every time. Same `@State`-
    /// owned-here-not-there shape as `sceneryCache` immediately above, for
    /// the identical reason: `SceneryModeView` itself gets torn down and
    /// rebuilt on every mode switch, so state local to it doesn't survive.
    @State private var sceneryScrollAnchorSectionID: String?
    /// See `ForgePaletteView.scrollAnchorObjectID`'s own doc comment, the
    /// Forge Palette's own version of the same scroll-reset bug/fix.
    @State private var forgeScrollAnchorObjectID: UInt16?
    /// "Forge Palette anywhere", see `GlobalObjectResolutionCache`'s own
    /// doc comment. Same `@State`-owned-here, passed-down-to-the-palette
    /// shape as `sceneryCache` immediately above, for the same reason: it
    /// needs to survive switching `editorMode` away from the Forge Palette
    /// tab and back without losing in-flight/confirmed search state.
    @State private var globalObjectResolutionCache = GlobalObjectResolutionCache()
    /// "Numbered Hotbar (1-9)": what's pinned to each of the 9 slots , 
    /// `nil` for an empty slot. Session-only, like `armedPlacement`; not
    /// persisted to disk. Pinned from the Forge Palette (a small pin
    /// button per row); pressing 1-9 in the viewport arms whatever's in
    /// that slot, the same as clicking the palette row directly.
    @State private var hotbarSlots: [HotbarEntry?] = Array(repeating: nil, count: 9)
    /// "Radial Marking Menu (hold Q)": non-nil while the menu is open, the
    /// AppKit view-point (bottom-left origin, matching `MetalModelView`'s
    /// own coordinate space) where Q went down, the menu's own center.
    /// `nil` hides the overlay entirely.
    @State private var markingMenuCenter: CGPoint?
    /// The cursor's current position (same coordinate space as
    /// `markingMenuCenter`), updated on every `mouseMoved` while the menu
    /// is held, the delta between the two drives which slice highlights.
    @State private var markingMenuCurrentPoint: CGPoint = .zero
    /// Lets `inspectSelected()` scroll the sidebar to the already-live
    /// `selectedObjectInspector` panel from the marking menu's "Inspect"
    /// action, captured once from `sidebar`'s own `ScrollViewReader`.
    @State private var sidebarScrollProxy: ScrollViewProxy?
    /// The marking menu's "Copy"/"Cut": the most recently copied object,
    /// independent of `objects`' own array indices (which shift under
    /// delete/insert), see `LevelViewerRenderer.ObjectClipboardEntry`'s
    /// own doc comment for why a value snapshot, not a raw index.
    @State private var objectClipboard: LevelViewerRenderer.ObjectClipboardEntry?
    /// "Procedural Brush" (roadmap 8.6), see `scatterSelected`'s doc
    /// comment.
    @State private var scatterCount: Double = 8
    @State private var scatterRadius: Double = 3
    /// "Scene Preview Mode" (roadmap 7.1), see `scenePreviewModeToggle`'s
    /// doc comment.
    @State private var isScenePreviewMode = false
    /// "Free Camera System in Chunk Editor".
    @State private var isFreeCameraMode = false
    /// "Top-Down/Minimap", mutually exclusive with `isFreeCameraMode` at
    /// the renderer level; kept as its own `@State` (not derived) so this
    /// view's Toggle bindings stay simple two-way bindings like the free
    /// camera one above.
    @State private var isTopDownMode = false
    @State private var scenePreviewTimer: Timer?
    /// "Pre-save validation", dangling-reference warnings found by
    /// `danglingReferenceWarnings()` for the save/launch action currently
    /// gated behind the confirmation alert below, and the actual action to
    /// run if the user picks "Save Anyway." `nil` means no confirmation is
    /// pending (the common case: `trySave`/`tryQuickLaunch` run the action
    /// immediately when there's nothing to warn about).
    @State private var pendingDanglingWarnings: [String] = []
    @State private var pendingConfirmedSaveAction: (() -> Void)?
    /// See `confirmingRiskyPlacementCount`'s own doc comment.
    @State private var pendingRiskyCountWarning: String?
    @State private var pendingConfirmedRiskyCountAction: (() -> Void)?
    /// "Risky-Count Gate, Hard Block", see `confirmingRiskyPlacementCount`'s
    /// own doc comment. Unlike `pendingRiskyCountWarning`, there is
    /// deliberately no matching "confirmed action" state here: past
    /// `hardBlockSceneryCountThreshold` there is nothing to confirm past,
    /// only an "OK" that dismisses the alert and leaves Quick Launch
    /// blocked.
    @State private var pendingHardBlockedCountMessage: String?
    /// "In-Place Save for Archive-Packed Levels", see `savingInPlaceToDiscImage`'s
    /// own doc comment.
    @State private var isSavingInPlace = false
    @State private var isSpawningInteractiveCortexProp = false
    @State private var interactiveCortexPropError: String?
    @State private var pendingInPlaceSaveConfirmation: String?
    /// "Rebuild All Collision" / "Rebuild Collision for This Object", same
    /// confirm-then-save-in-place shape as `pendingInPlaceSaveConfirmation`
    /// above, kept as two separate strings since they gate two different
    /// renderer flags (`rebuildAllCollisionRequested`/
    /// `rebuildCollisionRequestedForObjectIndex`) that must each only ever
    /// be cleared by their own Cancel button.
    @State private var pendingRebuildAllCollisionSaveConfirmation: String?
    @State private var pendingRebuildObjectCollisionSaveConfirmation: String?
    /// See `confirmingPendingCollisionRebuild`'s own doc comment, non-`nil`
    /// while Quick Launch is blocked on "you have a collision rebuild
    /// that's armed but not saved yet, what do you want to do." Holds the
    /// actual Quick Launch continuation to run once the user picks
    /// "Launch Anyway."
    @State private var pendingUnsavedCollisionRebuildLaunchAction: (() -> Void)?
    /// "Strict Size Guardrails", real, requested confirmation gate: set
    /// whenever `savingPendingLevelViewerEditsToMountedDisc()` reports
    /// `.sizeThresholdExceeded` instead of writing anything. `retryAction`
    /// re-invokes the same save with `allowingLargeGrowth: true`, the only
    /// way the already-verified bytes actually get written, cleared
    /// (never fired) on Cancel.
    @State private var pendingSizeThresholdConfirmation: String?
    @State private var pendingSizeThresholdRetryAction: (() -> Void)?
    /// "Recipe Book" (roadmap 6.4).
    @State private var isRecipeBookPresented = false
    /// "Chunk-Based Architecture" (Part 2): which `ChunkLink.id`s have
    /// already been loaded into the viewport this session (so the button
    /// can show "Loaded" instead of offering to reload the same neighbor),
    /// and which one is actively resolving right now (for a small progress
    /// indicator on that one row only).
    @State private var stitchedLinkIDs: Set<Int> = []
    @State private var stitchingLinkID: Int?
    /// "Cross-Engine Chunk Stitcher" (roadmap 5.3): a running log of what's
    /// been loaded this session, file name plus real decoded counts, or
    /// an error, so the user can see what actually got stitched in.
    @State private var crossEngineLoadLog: [String] = []
    /// Full transform captured at the start of a gizmo drag or a
    /// nudge-field edit, so ⌘Z has something to restore to, see
    /// `registerUndo`. Snapshotting all three (not just whichever one a
    /// given drag actually changes) keeps one undo mechanism instead of
    /// three near-identical ones.
    @State private var transformBeforeEdit: TransformSnapshot?
    /// "Hold to Move" HUD toggle, real, reported request: the movement
    /// pad's fixed-step-per-press felt too coarse for fine positioning.
    /// On, its directional buttons move the selection continuously for as
    /// long as they're held (`nudgeSelectedPositionContinuous`) instead of
    /// jumping by a fixed step per press/repeat.
    @State private var hudContinuousMove = false
    /// Real, reported bug: "Hold to Move" still felt like discrete steps
    /// even with the toggle on. `nudgeSelectedPositionContinuous` itself is
    /// correct, a real 60Hz timer accumulating real delta-time (see
    /// `ContinuousHUDButton`'s own doc comment), but `MetalModelView`'s
    /// viewport only actually *redraws* at 20fps (`preferredFramesPerSecond
    /// = 20`, deliberately capped, see that call site's own doc comment
    /// for the real main-actor contention bug that capped it, and why it
    /// must **not** just be raised back to 60 globally). The fix scopes the
    /// higher rate to exactly an active continuous-move drag instead: a
    /// brief window where `openLevelViewer` (the thing that actually
    /// contended with a global 60fps loop) is never running, since the user
    /// is already inside an opened, loaded level.
    @State private var metalView: InteractiveMTKView?

    private func beginningContinuousMoveHighFrameRate() {
        metalView?.preferredFramesPerSecond = 60
    }

    private func endingContinuousMoveHighFrameRate() {
        metalView?.preferredFramesPerSecond = 20
    }

    private struct TransformSnapshot: Equatable {
        var position: SIMD3<Float>
        var rotationDegrees: SIMD3<Float>
        var scale: SIMD3<Float>
    }

    var body: some View {
        HStack(spacing: 0) {
            viewportArea
            Divider()
            sidebar
                .frame(width: 320)
        }
        .frame(minWidth: 960, minHeight: 620)
        // Real, reported performance bug ("freeze on open"): the renderer
        // build below, vertex interleave, index buffer expansion,
        // `device.makeBuffer`, texture decode/upload for every single
        // placement/Instance/Trigger/Camera/AI marker in the level, with no
        // yield point anywhere in that loop, used to run synchronously
        // inside `.onAppear`, entirely on the main actor, blocking all
        // input (clicks, camera drags, everything) for however long it
        // took. `buildGPUSubmeshes` is already a pure static function with
        // no main-actor affinity, and `MTLDevice`/`MTLBuffer`/`MTLTexture`
        // creation is documented safe to do from any thread, nothing about
        // `LevelViewerRenderer.init?` actually requires the main actor.
        // `.task` (not `.onAppear` + a bare `Task { }`) so this is
        // automatically cancelled if the window closes before it finishes , 
        // that cancellation, and the `guard !Task.isCancelled` below, stop
        // a stale build from resurrecting a `renderer` for a window nobody's
        // looking at anymore. It does NOT stop the build itself: the actual
        // GPU work runs inside `Task.detached` below, which is genuinely
        // unstructured and does not inherit this `.task`'s cancellation , 
        // switching levels quickly can leave an abandoned build still
        // running to completion on a background thread even after its
        // window is gone. That's real, uncorrected wasted work (a separate,
        // smaller efficiency gap from the "GPU cache corruption" risk this
        // *did* need to close, see `TextureUploadCache`'s own doc comment
        // on why every store into `ModelViewerGPUContext.shared`'s
        // persistent caches is now lock-protected regardless of how many of
        // these detached builds end up running at once).
        .task {
            let isDemoCameraCollection = referenceNodeForFileOps.flatMap { workspace.cameraCollectionIsDemo(inSameFileAs: $0) } ?? false
            let placements = context.placements
            let sceneryNode = context.sceneryNode
            let instanceMarkers = context.instanceMarkers
            let resolvedAssets = context.resolvedInstanceAssets
            let resolvedFromSharedDefault = context.resolvedFromSharedDefault
            let assetIndex = context.assetIndex
            let defaultAssetIndex = context.defaultAssetIndex
            let triggers = context.triggers
            let cameras = context.cameras
            let chunkLinks = context.chunkLinks
            let aiPositions = context.aiPositions
            let aiPaths = context.aiPaths
            let collisionMeshes = context.collisionMeshes.map(\.mesh)

            // TEMPORARY perf-diagnostic instrumentation, see matching
            // block in `WorkspaceViewModel.openLevelViewer`. Remove once
            // this fix is confirmed against a real hub-scale level.
            let rendererBuildStart = CFAbsoluteTimeGetCurrent()
            let built = await Task.detached(priority: .userInitiated) {
                LevelViewerRenderer(
                    placements: placements,
                    sceneryFileNode: sceneryNode,
                    instanceMarkers: instanceMarkers,
                    resolvedInstanceAssets: resolvedAssets,
                    resolvedFromSharedDefault: resolvedFromSharedDefault,
                    assetIndex: assetIndex,
                    defaultAssetIndex: defaultAssetIndex,
                    triggers: triggers,
                    cameras: cameras,
                    chunkLinks: chunkLinks,
                    aiPositions: aiPositions,
                    aiPaths: aiPaths,
                    collisionMeshes: collisionMeshes,
                    isDemoCameraCollection: isDemoCameraCollection
                )
            }.value
            let rendererBuildElapsed = CFAbsoluteTimeGetCurrent() - rendererBuildStart
            AppLog.rendering.debug("[LevelViewerPerf] LevelViewerRenderer init (GPU upload, off-main): \(String(format: "%.3f", rendererBuildElapsed))s")
            guard !Task.isCancelled else { return }

            renderer = built
            renderer?.instanceTemplatePropertiesByObjectID = context.instanceTemplatePropertiesByObjectID
            renderer?.instanceScriptIDByObjectID = Self.instanceScriptIDByObjectID(fromInstanceMarkers: instanceMarkers)
            renderer?.snapToGrid = snapToGrid
            renderer?.gridSize = Float(gridSize)
            renderer?.magnetSnapEnabled = magnetSnapEnabled
            renderer?.rotationSnapDegrees = Float(rotationSnapDegrees)
            renderer?.layerVisibility = layerVisibility
            renderer?.cullBackFaces = cullBackFaces
            workspace.currentViewerCameraPositionProvider = { [weak renderer] in renderer?.cameraEyeWorldPosition }
            // "Quit-time Level Viewer autosave prompt" (app-lifecycle sweep):
            // gives `WorkspaceViewModel` a real, live way to ask "is there
            // anything to lose" and "what would saving it look like" without
            // holding a reference to this transient View struct itself , 
            // only a weak `renderer`, a weak `workspace`, and the one stable
            // anchor node this window's file-scoped operations already use
            // (`referenceNodeForFileOps`, captured once here since it's fixed
            // for this window's whole lifetime). Cleared in `.onDisappear`
            // below, same as `currentViewerCameraPositionProvider`.
            let anchorNode = referenceNodeForFileOps
            let sceneryAnchorNode = context.sceneryNode
            let collisionMeshesAnchor = context.collisionMeshes
            workspace.currentLevelViewerDirtyProvider = { [weak renderer] in renderer?.hasPendingEdits ?? false }
            workspace.currentLevelViewerPendingPatchProvider = { [weak renderer, weak workspace] in
                guard let renderer, let workspace, let anchorNode,
                      let patch = LevelViewerWindow.computingPendingOverridePatch(renderer: renderer, referenceNode: anchorNode, sceneryFileNode: sceneryAnchorNode, collisionMeshes: collisionMeshesAnchor, workspace: workspace),
                      let fileRoot = workspace.fileRoot(containing: patch.referenceNode)
                else { return nil }
                return LevelViewerPendingPatch(
                    archiveEntryDisplayName: fileRoot.displayName, patchedBytes: patch.patch.primaryBytes,
                    sceneryArchiveEntryDisplayName: patch.patch.sceneryFileDisplayName, sceneryPatchedBytes: patch.patch.sceneryBytes,
                    summary: patch.summary
                )
            }
        }
        // "Robust Undo/Redo" (QoL sweep), scoped to object moves, the one
        // piece of mutable state this session actually introduced and
        // fully understands the surface of. `NSUndoManager` doesn't route
        // its undo/redo effects back into SwiftUI `@State` on its own, so
        // these notifications (which it posts specifically for observers
        // to resync after an undo/redo) are what keep the sidebar's
        // selection/position fields in sync after ⌘Z/⌘⇧Z.
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in syncFromRenderer() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in syncFromRenderer() }
        .onChange(of: showCollisionVolume) { _, _ in updateCollisionVolumeOverlay() }
        .onDisappear { handlingDisappear() }
        .alert(
            "Dangling References Found",
            isPresented: Binding(
                get: { pendingConfirmedSaveAction != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingConfirmedSaveAction = nil
                        pendingDanglingWarnings = []
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingConfirmedSaveAction = nil
                pendingDanglingWarnings = []
            }
            Button("Save Anyway") {
                let action = pendingConfirmedSaveAction
                pendingConfirmedSaveAction = nil
                pendingDanglingWarnings = []
                action?()
            }
        } message: {
            Text(pendingDanglingWarnings.joined(separator: "\n"))
        }
        .alert(
            "Quick Launch Blocked",
            isPresented: Binding(
                get: { pendingHardBlockedCountMessage != nil },
                set: { isPresented in
                    if !isPresented { pendingHardBlockedCountMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) { pendingHardBlockedCountMessage = nil }
        } message: {
            Text(pendingHardBlockedCountMessage ?? "")
        }
        .alert(
            "Risky Scenery Placement Count",
            isPresented: Binding(
                get: { pendingRiskyCountWarning != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingConfirmedRiskyCountAction = nil
                        pendingRiskyCountWarning = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingConfirmedRiskyCountAction = nil
                pendingRiskyCountWarning = nil
            }
            Button("Launch Anyway") {
                let action = pendingConfirmedRiskyCountAction
                pendingConfirmedRiskyCountAction = nil
                pendingRiskyCountWarning = nil
                action?()
            }
        } message: {
            Text(pendingRiskyCountWarning ?? "")
        }
        .alert(
            "Save In-Place to Disc Image",
            isPresented: Binding(
                get: { pendingInPlaceSaveConfirmation != nil },
                set: { isPresented in
                    if !isPresented { pendingInPlaceSaveConfirmation = nil }
                }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingInPlaceSaveConfirmation = nil }
            Button("Save In-Place") {
                pendingInPlaceSaveConfirmation = nil
                performSavingInPlaceToDiscImage()
            }
        } message: {
            Text(pendingInPlaceSaveConfirmation ?? "")
        }
        .alert(
            "Rebuild All Collision",
            isPresented: Binding(
                get: { pendingRebuildAllCollisionSaveConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRebuildAllCollisionSaveConfirmation = nil
                        renderer?.rebuildAllCollisionRequested = false
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingRebuildAllCollisionSaveConfirmation = nil
                renderer?.rebuildAllCollisionRequested = false
            }
            Button("Rebuild && Save In-Place") {
                pendingRebuildAllCollisionSaveConfirmation = nil
                performRebuildingAllCollisionAndSavingInPlace()
            }
        } message: {
            Text(pendingRebuildAllCollisionSaveConfirmation ?? "")
        }
        .alert(
            "Rebuild Collision for This Object",
            isPresented: Binding(
                get: { pendingRebuildObjectCollisionSaveConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRebuildObjectCollisionSaveConfirmation = nil
                        renderer?.rebuildCollisionRequestedForObjectIndex = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingRebuildObjectCollisionSaveConfirmation = nil
                renderer?.rebuildCollisionRequestedForObjectIndex = nil
            }
            Button("Rebuild && Save In-Place") {
                pendingRebuildObjectCollisionSaveConfirmation = nil
                performRebuildingObjectCollisionAndSavingInPlace()
            }
        } message: {
            Text(pendingRebuildObjectCollisionSaveConfirmation ?? "")
        }
        .alert(
            "Collision Rebuild Not Saved Yet",
            isPresented: Binding(
                get: { pendingUnsavedCollisionRebuildLaunchAction != nil },
                set: { isPresented in
                    if !isPresented { pendingUnsavedCollisionRebuildLaunchAction = nil }
                }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingUnsavedCollisionRebuildLaunchAction = nil }
            Button("Save Collision First") {
                pendingUnsavedCollisionRebuildLaunchAction = nil
                if renderer?.rebuildCollisionRequestedForObjectIndex != nil {
                    rebuildCollisionForSelected()
                } else {
                    rebuildingAllCollision()
                }
            }
            Button("Launch Without Saving") {
                let action = pendingUnsavedCollisionRebuildLaunchAction
                pendingUnsavedCollisionRebuildLaunchAction = nil
                action?()
            }
        } message: {
            Text("You've armed a collision rebuild (\(renderer?.rebuildCollisionRequestedForObjectIndex != nil ? "for this one object" : "for the whole level")) that hasn't actually been saved to the disc image yet. It'll still be baked into this one boot either way, \"Save Collision First\" also keeps it around in the disc image for next time; \"Launch Without Saving\" only applies it to this boot.")
        }
        .alert(
            "This Save Grew the Disc Image a Lot",
            isPresented: Binding(
                get: { pendingSizeThresholdConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingSizeThresholdConfirmation = nil
                        pendingSizeThresholdRetryAction = nil
                        clearingInFlightSaveRequestFlags()
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingSizeThresholdConfirmation = nil
                pendingSizeThresholdRetryAction = nil
                clearingInFlightSaveRequestFlags()
            }
            Button("Save Anyway") {
                pendingSizeThresholdConfirmation = nil
                let retry = pendingSizeThresholdRetryAction
                pendingSizeThresholdRetryAction = nil
                retry?()
            }
        } message: {
            Text(pendingSizeThresholdConfirmation ?? "")
        }
        .sheet(isPresented: $showingBatchScript) {
            BatchScriptSheet(pickedCount: alignmentSelection.count) { operations in
                applyBatchScript(operations)
            }
        }
        .sheet(isPresented: Binding(
            get: { aiPathAssignmentTargetIndex != nil },
            set: { if !$0 { aiPathAssignmentTargetIndex = nil } }
        )) {
            aiPathAssignmentSheet
        }
    }

    private func syncFromRenderer() {
        // Real bug fix: `deleteSelected()` already clears `alignmentSelection`
        // when *it* deletes something (see that function's own doc comment
        // on why, every later index shifts down by one), but undo/redo of
        // a delete/restore/placement shifts indices exactly the same way,
        // and this notification-driven resync never checked for that.
        // Concretely: delete object #5, ⌘-click rows 10 and 20 to build an
        // Align set, ⌘Z, the restore re-inserts at index 5, so the picked
        // set now silently names two different objects, and Align/
        // Distribute would move the wrong ones. Comparing object count
        // (not just relying on the notification firing) scopes the clear
        // to only the undo/redo actions that actually shift indices , 
        // undoing a plain transform move leaves the count, and the picked
        // set, alone.
        if let renderer, let lastKnownObjectCount, renderer.objectCount != lastKnownObjectCount {
            alignmentSelection.removeAll()
        }
        lastKnownObjectCount = renderer?.objectCount
        selectedIndex = renderer?.selectedObjectIndex
        refreshTransformFields()
    }

    /// See `ScenerySpamBootTests`'s own doc comment for the real PCSX2
    /// evidence this threshold is based on, kept comfortably below the
    /// confirmed-clean count (8,500 on beach.rm2) rather than at it, since
    /// the exact boundary wasn't narrowed further and may vary per level.
    private static let riskyScenerycountThreshold = 8000
    /// "Risky-Count Gate, Hard Block", real extension of the softer
    /// warn-and-allow-override gate above: the same real PCSX2 evidence
    /// this whole gate is based on (`ScenerySpamBootTests`) found that at
    /// 10,000 scenery placements, every independent boot showed the exact
    /// same corruption signature, a dense, continuous cascade of "EE:
    /// Unrecognized COP0/FPU op" traps immediately after the loading FMVs,
    /// not an occasional or borderline failure. Past this point "Launch
    /// Anyway" isn't offering a real choice, so Quick Launch is blocked
    /// outright rather than warned-and-overridable, same as
    /// `riskyScenerycountThreshold`'s own doc comment explains for why
    /// *that* threshold sits comfortably below the confirmed-clean count
    /// instead of exactly at it, this one sits at the confirmed-broken
    /// count instead of exactly at it, for the same reason: the true
    /// boundary wasn't narrowed further and may vary per level.
    private static let hardBlockSceneryCountThreshold = 10000

    /// This session's *current* scenery placement total, the on-disk
    /// count plus every pending add (Scenery-tab placements, cross-level
    /// borrows) minus every pending delete, not just `context.scenery.
    /// placements.count`, which is frozen at whatever it was when this
    /// level was opened and never reflects a single edit made since.
    private var liveSceneryPlacementCount: Int {
        guard let renderer else { return context.scenery.placements.count }
        return context.scenery.placements.count + renderer.pendingNewScenery.count + renderer.pendingCrossLevelScenery.count - renderer.pendingRemovedSceneryOffsets.count
    }

    /// "Numbered Hotbar (1-9)": pins an entry into the first empty slot,
    /// or replaces slot 1 once every slot is full, the same "keep going,
    /// don't block" posture as everything else in this palette (no error
    /// state for "hotbar is full," just the oldest/first pin gets bumped).
    private func pinToHotbar(objectID: UInt16, name: String) {
        if let emptyIndex = hotbarSlots.firstIndex(where: { $0 == nil }) {
            hotbarSlots[emptyIndex] = HotbarEntry(objectID: objectID, name: name)
        } else {
            hotbarSlots[0] = HotbarEntry(objectID: objectID, name: name)
        }
    }

    /// Arms whatever's pinned to `slot` (1-9) for placement, identically to
    /// clicking that entry in the Forge Palette, including switching to
    /// the Forge Palette tab, so pressing a hotbar key works from any
    /// sidebar tab, not just while the palette is already open.
    private func armHotbarSlot(_ slot: Int) {
        guard hotbarSlots.indices.contains(slot - 1), let entry = hotbarSlots[slot - 1] else { return }
        editorMode = .forgePalette
        cancelArmedPlacement()
        armedPlacement = (entry.objectID, entry.name)
        renderer?.pendingPlacementObjectID = entry.objectID
    }

    /// "Radial Marking Menu (hold Q)": generic, always-available quick
    /// actions on the current selection, the same four actions
    /// `selectionHUD` already exposes, reachable without moving the mouse
    /// to the corner of the viewport. Mostly not layer-specific (a Trigger
    /// vs. an Instance vs. a Camera all get the same core slices) since
    /// this build has no decoded game-logic data to make a genuinely
    /// different per-type action set honest for most of them, rather than
    /// invented, "Set AI Path" is the one deliberate exception, gated to
    /// a session-placed Instance only (see `canSetAIPathOnSelected`'s own
    /// doc comment), since that one *does* have real, decoded data behind
    /// it now.
    private struct MarkingMenuAction {
        let icon: String
        let label: String
        let isEnabled: Bool
        let perform: () -> Void
    }

    private var markingMenuActions: [MarkingMenuAction] {
        [
            MarkingMenuAction(icon: "scissors", label: "Cut", isEnabled: canCutSelected) { cutSelected() },
            MarkingMenuAction(icon: "doc.on.doc", label: "Copy", isEnabled: canCopySelected) { copySelected() },
            MarkingMenuAction(icon: "doc.on.clipboard", label: "Paste", isEnabled: canPasteClipboard) { pasteClipboard() },
            MarkingMenuAction(icon: "info.circle", label: "Inspect", isEnabled: renderer?.selectedSourceNode != nil) { inspectSelected() },
            MarkingMenuAction(icon: "plus.square.on.square", label: "Duplicate", isEnabled: canDuplicateSelected) { duplicateSelected() },
            MarkingMenuAction(icon: "trash", label: "Delete", isEnabled: canDeleteSelected) { deleteSelected() },
            MarkingMenuAction(icon: "camera.viewfinder", label: "Copy Viewer Pos", isEnabled: selectedIndex != nil) { copyViewerPositionToSelected() },
            MarkingMenuAction(icon: "viewfinder", label: "Frame Selection", isEnabled: true) { renderer?.resetView() },
            // "Set AI Path on a Newly-Placed AI" ( , 
            // set its pathing"): the one genuinely layer-specific slice in
            // this menu, unlike this doc comment's own "not layer-specific"
            // reasoning above, this build *does* now have real, decoded
            // game-logic data behind it (`PlacedInstance.childPathIDs`/
            // `AIPathRecord`), so a per-type action here is honest, not
            // invented. Only enabled for a session-placed Instance, see
            // `canSetAIPathOnSelected`'s own doc comment.
            MarkingMenuAction(icon: "point.topleft.down.curvedto.point.bottomright.up", label: "Set AI Path", isEnabled: canSetAIPathOnSelected) { setAIPathOnSelected() },
            // "Rebuild Collision for This Object", real, requested
            // feature: the per-object counterpart to the Terrain panel's
            // "Rebuild All Collision…" button, for when the user doesn't
            // want to pay the cost of rebuilding the whole level's
            // collision. Scenery-only, matching `canRebuildCollisionForSelected`'s
            // own doc comment.
            MarkingMenuAction(icon: "cube.transparent", label: "Rebuild Collision", isEnabled: canRebuildCollisionForSelected) { rebuildCollisionForSelected() },
        ]
    }

    /// Which slice the cursor is currently over, or `nil` in the small
    /// dead zone right at the center (so a barely-moved cursor doesn't
    /// commit to whatever slice happens to contain the origin). A free
    /// function (not a computed property) specifically so it's directly
    /// unit-testable without a live view/`@State`, this codebase has been
    /// burned repeatedly this session by rotation/angle sign errors that
    /// "looked right" under hand-tracing alone, so this one gets a real
    /// test instead of trusting the derivation.
    ///
    /// Both points are in AppKit's own y-up view space; the angle math
    /// stays entirely in that space and converts to screen-clockwise
    /// internally (`dyScreen = -dy`), the caller never needs to think
    /// about SwiftUI's y-down drawing coordinates, only `markingMenuOverlay`'s
    /// drawing code does, and that's kept in the same convention (clockwise
    /// from straight up / 12 o'clock) so the highlighted slice always
    /// visually agrees with where the cursor actually is.
    static func markingMenuSliceIndex(center: CGPoint, current: CGPoint, sliceCount: Int, deadZoneRadius: Double = 14) -> Int? {
        guard sliceCount > 0 else { return nil }
        let dx = Double(current.x - center.x)
        let dyScreen = -Double(current.y - center.y) // AppKit is y-up; screen-clockwise math is y-down
        guard hypot(dx, dyScreen) > deadZoneRadius else { return nil }
        let theta = atan2(dyScreen, dx) // 0 = east, -pi/2 = up (north); increasing = clockwise on screen
        let sliceSize = 2 * Double.pi / Double(sliceCount)
        var shifted = (theta + .pi / 2 + sliceSize / 2).truncatingRemainder(dividingBy: 2 * .pi)
        if shifted < 0 { shifted += 2 * .pi }
        return Int(shifted / sliceSize) % sliceCount
    }

    private var markingMenuHighlightedIndex: Int? {
        guard let markingMenuCenter else { return nil }
        return Self.markingMenuSliceIndex(center: markingMenuCenter, current: markingMenuCurrentPoint, sliceCount: markingMenuActions.count)
    }

    private func executeHighlightedMarkingMenuAction() {
        guard let index = markingMenuHighlightedIndex, markingMenuActions.indices.contains(index) else { return }
        let action = markingMenuActions[index]
        guard action.isEnabled else { return }
        action.perform()
    }

    /// Radial pie overlay, positioned via `GeometryReader` so it can
    /// convert `markingMenuCenter`'s AppKit (y-up) point into this
    /// overlay's own SwiftUI (y-down) drawing space using the viewport's
    /// actual current size, rather than assuming one.
    @ViewBuilder
    private var markingMenuOverlay: some View {
        if let markingMenuCenter {
            GeometryReader { geo in
                let center = CGPoint(x: markingMenuCenter.x, y: geo.size.height - markingMenuCenter.y)
                let radius: CGFloat = 70
                let highlighted = markingMenuHighlightedIndex
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: radius * 2 + 44, height: radius * 2 + 44)
                        .position(center)
                    ForEach(Array(markingMenuActions.enumerated()), id: \.offset) { index, action in
                        let sliceAngle = 2 * Double.pi / Double(markingMenuActions.count)
                        let angle = -Double.pi / 2 + Double(index) * sliceAngle
                        let itemCenter = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
                        VStack(spacing: 3) {
                            Image(systemName: action.icon)
                            Text(action.label).font(.caption2)
                        }
                        .foregroundStyle(action.isEnabled ? .white : .white.opacity(0.35))
                        .padding(8)
                        .background(Circle().fill(highlighted == index ? Color.accentColor : Color.black.opacity(0.55)))
                        .position(itemCenter)
                    }
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 6, height: 6)
                        .position(center)
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var viewportArea: some View {
        if let renderer {
            if renderer.hasGeometry {
                // See `ModelViewerWindow`'s matching comment, an
                // `NSViewRepresentable` `MTKView` has no intrinsic size, so
                // this needs an explicit expand-to-fill or it can collapse
                // inside the surrounding `HStack`.
                ZStack(alignment: .bottomLeading) {
                    MetalModelView(
                        renderer: renderer,
                        onGizmoDragEnded: {
                            registerUndoAndRefreshCollisionOverlay(from: transformBeforeEdit)
                            refreshTransformFields()
                        },
                        onGizmoDragStarted: {
                            transformBeforeEdit = currentSnapshot()
                            renderer.beginGizmoDrag()
                        },
                        onGizmoModeChanged: { gizmoMode = renderer.gizmoMode },
                        onTopDownModeChanged: { isOn in isTopDownMode = isOn },
                        onObjectPicked: { index in select(index) },
                        onObjectPlaced: { index in
                            selectedIndex = index
                            refreshTransformFields()
                            registerPlacementUndo(index: index)
                            armedPlacement = nil
                        },
                        onSceneryPlaced: { index in
                            selectedIndex = index
                            refreshTransformFields()
                            if let undoManager {
                                undoManager.setActionName("Place Scenery")
                                Self.registerSceneryPlacementUndo(undoManager: undoManager, renderer: renderer, index: index)
                            }
                            armedScenery = nil
                        },
                        onPropSkinPlaced: { index in
                            selectedIndex = index
                            refreshTransformFields()
                            registerPropSkinPlacementUndo(index: index)
                            armedPropSkin = false
                            workspace.statusMessage = "Placed the interactive Cortex prop, move it if needed, then \"Save Chunk Overrides…\" or Quick Launch to make it real."
                        },
                        onAIPathEndpointPicked: { pickedID in applyPickedAIPathEndpoint(pickedID) },
                        onObjectDoubleClicked: { index in
                            select(index)
                            renderer.focusOnSelected()
                        },
                        onEscapePressed: {
                            if pendingAIPathPick != nil {
                                cancelAIPathEndpointPick()
                            } else {
                                deselectAll()
                            }
                        },
                        onHotbarSlotPressed: { slot in armHotbarSlot(slot) },
                        onMarkingMenuBegan: { point in
                            markingMenuCenter = point
                            markingMenuCurrentPoint = point
                        },
                        onMarkingMenuMoved: { point in markingMenuCurrentPoint = point },
                        onMarkingMenuEnded: {
                            executeHighlightedMarkingMenuAction()
                            markingMenuCenter = nil
                        },
                        onViewReady: { metalView = $0 }
                    )
                    // See `ModelViewerWindow`'s matching comment, a
                    // `maxWidth/maxHeight: .infinity`-only frame isn't a
                    // concrete enough size for a `.sheet()`'s first layout
                    // pass to reliably drive the `MTKView` from.
                    .frame(minWidth: 400, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    if let armedName = armedPlacement?.name ?? armedScenery?.name {
                        HStack(spacing: 8) {
                            Image(systemName: "hammer.fill")
                            Text("Click in the viewport to place **\(armedName)**")
                            Button("Cancel") {
                                cancelArmedPlacement()
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                    } else if let pendingAIPathPick {
                        HStack(spacing: 8) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                            Text("Click a waypoint to set Path #\(pendingAIPathPick.pathID)'s \(pendingAIPathPick.isStart ? "Start" : "End")")
                            Button("Cancel") {
                                cancelAIPathEndpointPick()
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                    } else {
                        Text("Drag to orbit · Scroll to zoom · Drag a handle or use arrow keys to \(gizmoMode == .translate ? "move" : gizmoMode == .rotate ? "rotate" : "scale") the selection · W/E/R to switch · F to frame")
                            .font(.caption)
                            .padding(6)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(10)
                    }
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                    if selectedIndex != nil {
                        // Grouped into one VStack anchored at the same
                        // corner `selectionHUD` alone used to occupy,
                        // instead of positioning `movementControlsHUD`
                        // independently at the vertically-centered
                        // trailing edge, that spot was never actually
                        // confirmed to render for a real user, unlike this
                        // corner. `.zIndex` guards against the Metal
                        // viewport's own `NSViewRepresentable` compositing
                        // on top of it in any edge case.
                        VStack(alignment: .trailing, spacing: 10) {
                            movementControlsHUD
                            selectionHUD
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .zIndex(1)
                    }
                    hotbarRow
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    markingMenuOverlay
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: String.self) { items, _ in
                    guard let idString = items.first,
                          let asset = workspace.modelsHub.first(where: { $0.id.uuidString == idString })
                    else { return false }
                    guard let newIndex = renderer.addObject(asset: asset) else { return false }
                    selectedIndex = newIndex
                    refreshTransformFields()
                    return true
                } isTargeted: { isDropTargeted = $0 }
            } else {
                ContentUnavailableView(
                    "No Resolvable Placements",
                    systemImage: "map",
                    description: Text("This level's scenery tree decoded (\(context.scenery.placements.count) placement(s) total), but none of their model IDs matched a RigidModel in this file's Graphics section.")
                )
            }
        } else {
            ContentUnavailableView("Metal Unavailable", systemImage: "exclamationmark.triangle", description: Text("Couldn't initialize a Metal device on this Mac."))
        }
    }

    /// "Halo Reach Forge / Minecraft"-style quick-action bar: the most
    /// common actions on the current selection (duplicate, delete, copy
    /// the camera's position onto it), reachable without touching the
    /// sidebar at all, Forge's own bottom action bar is the direct
    /// inspiration. The sidebar's Transform panel still has the same
    /// three actions (plus precise numeric fields), so nothing here is a
    /// second, diverging implementation, every button below calls the
    /// exact same functions the sidebar buttons do.
    private var selectionHUD: some View {
        HStack(spacing: 10) {
            Button {
                copyViewerPositionToSelected()
            } label: {
                Image(systemName: "camera.viewfinder")
            }
            .accessibilityLabel("Copy Viewer Position")
            .help("Copy Viewer Position")

            Button {
                duplicateSelected()
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .disabled(!canDuplicateSelected)
            .accessibilityLabel("Duplicate Selection")
            .help("Duplicate (⌘D)")

            Button(role: .destructive) {
                deleteSelected()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(!canDeleteSelected)
            .accessibilityLabel("Delete Selection")
            .help("Delete")

            // Adds every other object of this same type in the level to the
            // Align/Distribute picked set (⌘-click), so a whole set of e.g.
            // every crate of one kind can be batch-moved, batch-aligned, or
            // batch-deleted at once.
            Button {
                selectAllMatchingSelectedType()
            } label: {
                Image(systemName: "checklist")
            }
            .disabled(!canSelectAllMatchingSelectedType)
            .accessibilityLabel("Select All Matching")
            .help("Adds every object of this type to the Align/Distribute selection.")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// "Visible Alignment-Mode Indicator", real, requested QoL: "Magnet
    /// Snap" now governs three different behaviors (drag-time snap,
    /// placement snap-to-nearest, placement snap-to-selected, see
    /// `LevelViewerRenderer.magnetSnappedPlacementPosition`'s own doc
    /// comment), and which of the placement ones is active silently
    /// depends on whether something happens to be selected, previously
    /// documented only in a hover tooltip, easy to miss in the moment a
    /// placement actually happens. Small and always-visible rather than
    /// another toggle: this reflects state, it doesn't add a decision.
    private var alignmentModeIndicator: some View {
        Group {
            if !magnetSnapEnabled {
                Label("Alignment: Off", systemImage: "align.horizontal.left.fill")
                    .foregroundStyle(.secondary)
            } else if let selectedIndex, let name = renderer?.objectSummaries.first(where: { $0.index == selectedIndex })?.displayName {
                Label("Aligning to: \(name)", systemImage: "target")
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            } else {
                Label("Aligning to: Nearest", systemImage: "scope")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.system(size: 9))
        .frame(maxWidth: 110)
        .help("Shows what Magnet Snap currently aligns dragging and placement to.")
    }

    /// "On-Screen Move/Rotate Pad": three small button clusters standing
    /// in for precise mouse-drag gizmo control, dragging a thin 3D handle
    /// for a *specific* small nudge is genuinely fiddly, especially at a
    /// distance or a shallow camera angle where the handle's screen-space
    /// direction barely matches its world-space one. Each box nudges by
    /// the same step a keyboard arrow press already does (world Y for
    /// Up/Down, world X/Z for the middle pad, `rotationSnapDegrees` around
    /// world Y for Rotate) and registers one Undo step per press, press
    /// and hold a box to repeat continuously via `RepeatingHUDButton`,
    /// the same "hold for continuous movement" feel a held arrow key
    /// already gives, just reachable without touching the keyboard.
    private var movementControlsHUD: some View {
        VStack(spacing: 8) {
            alignmentModeIndicator
            Toggle("Hold to Move", isOn: $hudContinuousMove)
                .toggleStyle(.button)
                .controlSize(.mini)
                .font(.system(size: 10))
                .help(hudContinuousMove
                    ? "Moves smoothly while held, instead of a fixed step per press."
                    : "Moves by one fixed step per press. Toggle for smooth hold-to-move.")

            VStack(spacing: 2) {
                movementHUDButton(systemImage: "arrow.up", direction: .worldUp)
                movementHUDButton(systemImage: "arrow.down", direction: .worldDown)
            }
            .padding(6)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .help("Move Up / Down")

            VStack(spacing: 2) {
                movementHUDButton(systemImage: "arrow.up", direction: .groundForward)
                HStack(spacing: 2) {
                    movementHUDButton(systemImage: "arrow.left", direction: .groundLeft)
                    movementHUDButton(systemImage: "arrow.right", direction: .groundRight)
                }
                movementHUDButton(systemImage: "arrow.down", direction: .groundBackward)
            }
            .padding(6)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .help("Move Side to Side / Forward-Back")

            HStack(spacing: 2) {
                RepeatingHUDButton(systemImage: "rotate.left") { rotateSelectedFromHUD(sign: -1) }
                RepeatingHUDButton(systemImage: "rotate.right") { rotateSelectedFromHUD(sign: 1) }
            }
            .padding(6)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .help("Rotate")
        }
    }

    /// Real, reported bug: the side-to-side/forward-back pad used to nudge
    /// along fixed world X/Z axes (`SIMD3(1,0,0)` for "right", etc.), only
    /// ever visually matching its own arrow icons when the camera happened
    /// to be looking down world -Z with no orbit. At any other orbit angle
    /// (the normal case), pressing "→" could move the selection sideways,
    /// away from camera, or even toward what looks like screen-left. Up/
    /// Down stays absolute world Y (a real, camera-independent "elevation"
    /// nudge, not a screen direction), only the ground-plane pad needed
    /// this. `cameraGroundForward()`/`cameraGroundRight()` are the exact
    /// same camera-relative ground-plane basis `updateFreeCameraMovement`'s
    /// WASD input already uses, so this reuses already-correct math instead
    /// of re-deriving it.
    private enum HUDMoveDirection {
        case worldUp, worldDown
        case groundForward, groundBackward, groundLeft, groundRight
    }

    private func resolvedHUDDirection(_ direction: HUDMoveDirection) -> SIMD3<Float> {
        guard let renderer else { return .zero }
        switch direction {
        case .worldUp: return SIMD3(0, 1, 0)
        case .worldDown: return SIMD3(0, -1, 0)
        case .groundForward: return renderer.cameraGroundForward()
        case .groundBackward: return -renderer.cameraGroundForward()
        case .groundRight: return renderer.cameraGroundRight()
        case .groundLeft: return -renderer.cameraGroundRight()
        }
    }

    /// Picks between the two HUD button styles for one movement direction
    /// based on `hudContinuousMove`, the direction is resolved fresh on
    /// every press/tick (not once when this body is built), so a
    /// ground-plane arrow always matches what it visually points to even
    /// if the camera orbited between renders.
    @ViewBuilder
    private func movementHUDButton(systemImage: String, direction: HUDMoveDirection) -> some View {
        if hudContinuousMove {
            ContinuousHUDButton(systemImage: systemImage) { deltaSeconds in
                renderer?.nudgeSelectedPositionContinuous(worldDirection: resolvedHUDDirection(direction), deltaSeconds: deltaSeconds)
                refreshTransformFields()
            } onPressStart: {
                transformBeforeEdit = currentSnapshot()
                beginningContinuousMoveHighFrameRate()
            } onPressEnd: {
                registerUndoAndRefreshCollisionOverlay(from: transformBeforeEdit)
                endingContinuousMoveHighFrameRate()
            }
        } else {
            RepeatingHUDButton(systemImage: systemImage) { nudgeSelectedFromHUD(resolvedHUDDirection(direction)) }
        }
    }

    private func nudgeSelectedFromHUD(_ worldDirection: SIMD3<Float>) {
        guard let renderer else { return }
        let before = currentSnapshot()
        renderer.nudgeSelectedPosition(worldDirection: worldDirection)
        registerUndoAndRefreshCollisionOverlay(from: before)
        refreshTransformFields()
    }

    private func rotateSelectedFromHUD(sign: Float) {
        guard let renderer, let current = renderer.selectedRotationDegrees else { return }
        let before = currentSnapshot()
        var degrees = current
        degrees.y += sign * Float(rotationSnapDegrees)
        renderer.setSelectedRotation(eulerDegrees: degrees)
        registerUndoAndRefreshCollisionOverlay(from: before)
        refreshTransformFields()
    }

    /// "Numbered Hotbar (1-9)", always-visible bottom-center strip, the
    /// Minecraft/Forge-style quick-select this Level Viewer never had:
    /// pin an entry from the Forge Palette, then press its digit anywhere
    /// in the viewport to arm it instantly, without opening the palette
    /// list and scrolling to find it again.
    private var hotbarRow: some View {
        HStack(spacing: 4) {
            ForEach(1...9, id: \.self) { slot in
                let entry = hotbarSlots[slot - 1]
                Button {
                    armHotbarSlot(slot)
                } label: {
                    VStack(spacing: 2) {
                        Text("\(slot)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        if let entry {
                            Text(entry.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        } else {
                            Image(systemName: "circle.dashed")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 52, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(entry == nil)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(armedPlacement?.objectID == entry?.objectID && entry != nil ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                .help(entry != nil ? "Press \(slot) to place \(entry!.name)" : "Empty, pin an object here from the Forge Palette (Place mode)")
            }
        }
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var sidebar: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(context.scenery.chunkName.isEmpty ? "Chunk" : context.scenery.chunkName)
                        .font(.title3.bold())

                    TextField("Search objects & placeables…", text: $sidebarSearchText)
                        .textFieldStyle(.roundedBorder)
                        .help("Filters the Objects list and Forge Palette at once.")

                    controlsLegendPanel

                    modeRail

                    modeContent

                    Divider()

                    // Always-pinned regardless of mode, "what am I looking at
                    // right now" is relevant no matter which task tab is
                    // active. This is the single biggest change from the
                    // pre-overhaul layout: these three used to be three of
                    // ~15 panels stacked in one long scroll: now every mode
                    // still shows them without the user hunting for them.
                    gizmoControls

                    if let node = renderer?.selectedSourceNode {
                        Divider()
                        selectedObjectInspector(node: node)
                            .id(Self.selectedObjectInspectorAnchorID)
                    }

                    Divider()

                    objectList
                }
                .padding(16)
            }
            .onAppear { sidebarScrollProxy = proxy }
        }
    }

    /// The marking menu's "Inspect" action reuses this exact panel, it's
    /// already shown live for any current selection with a real record
    /// (`renderer?.selectedSourceNode`), so "Inspect" doesn't build a new
    /// popup/sheet, it just scrolls the sidebar to bring the panel that's
    /// already there into view.
    private static let selectedObjectInspectorAnchorID = "SelectedObjectInspectorAnchor"

    private func inspectSelected() {
        guard renderer?.selectedSourceNode != nil else { return }
        withAnimation {
            sidebarScrollProxy?.scrollTo(Self.selectedObjectInspectorAnchorID, anchor: .top)
        }
    }

    /// Icon-button row switching which task-specific panel shows below , 
    /// see `LevelEditorMode`'s own doc comment for the design rationale.
    private var modeRail: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            ForEach(LevelEditorMode.allCases) { mode in
                Button {
                    editorMode = mode
                } label: {
                    railTile(systemImage: mode.systemImage, label: mode.displayName, isActive: editorMode == mode)
                }
                .buttonStyle(.plain)
                .help(mode.helpText)
            }
            // Not a mode tab, an action button styled the same way, since
            // it was a real, reported complaint that "Play" only lived
            // buried inside Select mode's content (next to "Save Chunk
            // Overrides…") instead of being reachable from this rail like
            // everything else here.
            if let referenceNode = referenceNodeForFileOps {
                Button {
                    quickLaunchThisChunk()
                } label: {
                    railTile(systemImage: "play.fill", label: "Play", isActive: false)
                }
                .buttonStyle(.plain)
                .disabled(!workspace.canSaveEdits(for: referenceNode))
                .help("Builds a patched disc with pending edits, then launches PCSX2.")

                // Real, reported complaint (same shape as "Play" above):
                // the only way to save was switching to Select mode first
                // to reach "Save In-Place"/"Save Chunk Overrides…", with no
                // save action reachable from whatever mode you're actually
                // working in, and no keyboard shortcut at all. This saves
                // straight into the mounted disc image (the same real,
                // verified-before-write path every other in-place save in
                // this window already uses, see `savingInPlaceToDiscImage`'s
                // own doc comment), confirmed the same way, from any mode.
                // ⌘S here is the one global save shortcut for this window.
                Button {
                    savingInPlaceToDiscImage()
                } label: {
                    railTile(systemImage: "square.and.arrow.down.fill", label: "Save", isActive: false)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!workspace.canSaveEdits(for: referenceNode) || workspace.discImageURL == nil)
                .help(workspace.discImageURL == nil
                      ? "Set a Disc Image in the Game Launcher first."
                      : "Saves pending edits directly into the mounted disc image, verified before writing. (⌘S)")
            }
        }
        // ⌘C/⌘X/⌘V for the current selection , 
        // these already exist as real, working marking-menu actions
        // (`copySelected`/`cutSelected`/`pasteClipboard`, right below),
        // just with no keyboard shortcut reaching them from anywhere else
        // in the window. Invisible, zero-size buttons (not shown anywhere
        // in this rail) purely to give SwiftUI a shortcut target that's
        // always part of the active view hierarchy regardless of which
        // mode tab is showing, same "lives on `modeRail` since that's
        // always present" reasoning as ⌘S above, just without a visible
        // tile since these three already have a real, discoverable home
        // in the marking menu.
        .background {
            Group {
                Button(action: copySelected) {}
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(!canCopySelected)
                Button(action: cutSelected) {}
                    .keyboardShortcut("x", modifiers: .command)
                    .disabled(!canCutSelected)
                Button(action: pasteClipboard) {}
                    .keyboardShortcut("v", modifiers: .command)
                    .disabled(!canPasteClipboard)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func railTile(systemImage: String, label: String, isActive: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
            Text(label).font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        )
    }

    @ViewBuilder
    private var modeContent: some View {
        switch editorMode {
        case .select: selectModeContent
        case .place: placeModeContent
        case .forgePalette: forgePaletteModeContent
        case .scenery: sceneryModeContent
        case .terrain: modeAndLayersPanel
        case .ai: aiModeContent
        case .audio: audioModeContent
        case .advanced: advancedModeContent
        }
    }

    /// "Select" (default mode): level-wide stats and the save action , 
    /// the one thing every other mode eventually needs regardless of what
    /// you were just placing/adjusting.
    @ViewBuilder
    private var selectModeContent: some View {
        Form {
            LabeledContent("Placements in tree", value: "\(context.scenery.placements.count)")
            LabeledContent("Scenery resolved", value: "\(context.placements.count)")
            LabeledContent("Instance markers", value: "\(context.instanceMarkers.count)")
            LabeledContent("Triggers", value: "\(context.triggers.count)")
            LabeledContent("Cameras", value: "\(context.cameras.count)")
        }
        .formStyle(.grouped)

        if liveSceneryPlacementCount >= Self.riskyScenerycountThreshold {
            // "Loading screen hang past N objects", real, reported bug,
            // confirmed by direct PCSX2 investigation (see
            // `ScenerySpamBootTests`'s own doc comment): boots clean up to
            // 8,500 added scenery placements on beach.rm2, but at 10,000
            // the PS2 EE core starts a dense, continuous cascade of
            // "Unrecognized COP0/FPU op" traps right after the loading
            // FMVs, direct evidence of a fixed-size buffer somewhere
            // being overrun, not just a slow load. The exact boundary
            // wasn't narrowed further, and may differ per level, so this
            // warns well below the confirmed-clean count rather than
            // exactly at it.
            Text("⚠️ \(liveSceneryPlacementCount) scenery placements, past ~8,000, real PCSX2 testing found this level's collision/scenery data starts overrunning a fixed-size buffer, causing the game to hang forever right after the loading screen instead of crashing outright. Consider keeping levels well under this if you plan to boot them.")
                .font(.caption2)
                .foregroundStyle(.red)
                .padding(.horizontal)
        }

        Text("Scenery objects are drawn at their correct world position, rotation, and scale, decoded from the chunk data, placing a new copy (Scenery tab, including borrowed from another level), moving an existing one with the gizmo, and deleting one are all real, saved by \"Save Chunk Overrides…\" (a stitched neighbor chunk's scenery is inspect-only, it lives in a different file). The amber cubes are Instance records (crate/enemy/platform placements), their position/rotation is real, live-editable with the gizmo, and \"Save Chunk Overrides…\" below writes it back to a copy of the file. Green/cyan wireframe boxes are Triggers/Cameras, click to select and inspect; no 3D gizmo yet, but their inspector panel below has real, writable position/size/rotation fields with their own \"Save Edited Copy…\" button. The small magenta boxes along a camera's path are its real spline/path control points, click and drag one with the gizmo like any other object; \"Save Chunk Overrides…\" patches each moved point's own 16 bytes straight into the file, without needing to re-encode the rest of that Camera record. Inserting or removing a control point isn't supported yet, only moving an existing one.")
            .font(.caption2)
            .foregroundStyle(.orange)

        if let referenceNode = referenceNodeForFileOps {
            HStack {
                Button("Save Chunk Overrides…") { saveLevelOverrides() }
                    .disabled(!workspace.canSaveEdits(for: referenceNode))
                Button {
                    quickLaunchThisChunk()
                } label: {
                    Label("Quick Launch…", systemImage: "bolt.fill")
                }
                .disabled(!workspace.canSaveEdits(for: referenceNode))
                .help("Builds a patched disc with pending edits, then launches PCSX2.")

                // Unlike "Save Chunk Overrides…" (always a separate
                // loose-copy file, even when browsing this exact disc),
                // this writes straight into the mounted disc image's own
                // bytes. The rebuilt image is independently re-verified
                // before anything is written, same discipline as Quick
                // Launch's own "Save changes to this ISO" toggle, so a
                // failed verification leaves the real disc image untouched.
                Button {
                    savingInPlaceToDiscImage()
                } label: {
                    Label(isSavingInPlace ? "Saving…" : "Save In-Place to Disc Image…", systemImage: "opticaldiscdrive")
                }
                .disabled(isSavingInPlace || !workspace.canSaveEdits(for: referenceNode) || workspace.discImageURL == nil)
                .help(workspace.discImageURL == nil
                    ? "Set a Disc Image in the Game Launcher first."
                    : "Writes pending edits directly into the disc image; verified before writing.")
            }
            if !workspace.canSaveEdits(for: referenceNode) {
                // Archive-packed and disc-mounted files register their raw
                // bytes the same way a standalone-opened .RM2/.SM2 does now
                // (see `expandArchiveEntry`) -- `canSaveEdits` returning
                // false here means this file's own raw bytes just haven't
                // been loaded into this session yet, not that its source
                // (archive/disc/loose file) is unsupported.
                Text("This level's file hasn't finished loading its own raw bytes yet, reselect it in the sidebar, then try again.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "Add" mode: just "Add Trigger"/"Add Camera" now, Instance placement
    /// and Scenery each moved to their own top-level rail tab (see
    /// `LevelEditorMode`'s own doc comment), the same real tab mechanism
    /// `Select`/`Terrain`/etc. already use, not a floating modal window.
    @ViewBuilder
    private var placeModeContent: some View {
        addTriggerCameraPanel
    }

    /// "Forge Palette" mode: browse every object in the game and arm one
    /// to place with a viewport click, the sidebar's own full column,
    /// not a popup blocking the viewport (nothing to dismiss: the
    /// viewport sits right beside this sidebar, always clickable).
    @ViewBuilder
    private var forgePaletteModeContent: some View {
        if let armedPlacement {
            Text("Armed: \(armedPlacement.name), click in the viewport to place it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForgePaletteView(
            placedThisSession: renderer?.pendingNewInstances.count ?? 0,
            canResolve: { objectID in
                renderer?.globalObjectFallbacks = workspace.globalObjectThumbnails
                renderer?.globalObjectGameObjectSources = workspace.globalObjectGameObjectSources
                if let can = renderer?.canResolveObjectID(objectID), can { return true }
                return renderer == nil ? nil : false
            },
            canResolveNatively: { objectID in renderer?.canResolveNativelyObjectID(objectID) ?? false },
            resolveForThumbnail: { objectID in
                renderer?.globalObjectFallbacks = workspace.globalObjectThumbnails
                renderer?.globalObjectGameObjectSources = workspace.globalObjectGameObjectSources
                guard let resolved = renderer?.resolvedAsset(forObjectID: objectID) else { return nil }
                workspace.recordGlobalObjectThumbnail(objectID: objectID, asset: resolved)
                return resolved
            },
            resolutionCache: globalObjectResolutionCache,
            scrollAnchorObjectID: $forgeScrollAnchorObjectID,
            searchText: $sidebarSearchText,
            onPin: { objectID, name in pinToHotbar(objectID: objectID, name: name) },
            armedObjectID: armedPlacement?.objectID
        ) { objectID, name in
            cancelArmedPlacement()
            armedPlacement = (objectID, name)
            renderer?.pendingPlacementObjectID = objectID
        }
    }

    /// "Scenery" mode: see `SceneryModeView`'s own doc comment, every
    /// real scenery model, this level first, no folder to click through.
    @ViewBuilder
    private var sceneryModeContent: some View {
        if let destinationRoot = workspace.fileRoot(containing: context.sceneryNode) {
            SceneryModeView(
                cache: sceneryCache,
                destinationSceneryFileRoot: destinationRoot,
                armedKey: armedScenery?.key,
                onArm: { key, modelID, isSpecial, asset, crossLevelSource in
                    cancelArmedPlacement()
                    armedScenery = (key: key, name: asset.displayName)
                    renderer?.pendingPlacementScenery = LevelViewerRenderer.PendingSceneryPlacement(
                        modelID: modelID, isSpecial: isSpecial, asset: asset, crossLevelSource: crossLevelSource
                    )
                },
                scrollAnchorSectionID: $sceneryScrollAnchorSectionID
            )
        }
    }

    @ViewBuilder
    private var aiModeContent: some View {
        if !context.aiPositions.isEmpty || !context.aiPaths.isEmpty {
            aiWaypointsPanel
            if !context.aiPaths.isEmpty {
                Divider()
                aiPathsPanel
            }
        } else {
            Text("No AI waypoints or paths in this chunk.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var audioModeContent: some View {
        if !context.sounds.isEmpty {
            LevelAudioPanel(sounds: context.sounds)
        }
        if !context.triggers.isEmpty || hasScriptedInstances {
            if !context.sounds.isEmpty { Divider() }
            levelEventsPanel
        }
        if context.sounds.isEmpty && context.triggers.isEmpty && !hasScriptedInstances {
            Text("No audio or scripted trigger events in this chunk.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var advancedModeContent: some View {
        if !context.chunkLinks.isEmpty {
            chunkLinksPanel
            Divider()
        }
        characterSwapPanel
        Divider()
        crossEngineDataPanel
    }

    /// "Play As": replaces whichever character
    /// currently occupies `GameObject` id 0, the PS2 engine's own
    /// reserved Player-1 slot, confirmed via a real disc-wide scan (every
    /// non-cutscene playable Crash rig across 91 independent level files
    /// sits at id 0), with a *real*, verified alternate character's own
    /// complete rig: skin, skeleton, every real script (including
    /// `HeaderScript` dispatch chains, correctly remapped by record ID , 
    /// see `CrossFileGameObjectCopier.resolvingSkinnedGameObjectInsertions`'s
    /// own doc comment for the reference-source evidence behind that),
    /// every real animation, and linked objects (a weapon, for Cortex).
    ///
    /// An earlier attempt at this ("Character Swap", now replaced) copied
    /// the new character in as a *separate* object and repointed the
    /// existing Instance at it, leaving id 0 orphaned, the character
    /// rendered but nothing ever drove it, since (real, evidence-based
    /// conclusion) the engine's own Player-1 binding is tied to id 0
    /// itself, not to which Instance references a given object number.
    /// Overwriting id 0 in place, using each character's *own* matched
    /// skeleton+animation+script set (never one character's animations
    /// retargeted onto another's incompatible skeleton, the real reason
    /// the original "Character Swap" panel gave up), sidesteps that
    /// entirely.
    ///
    /// Real, disclosed limitation: picking "Crash (Default)" after another
    /// character has already been swapped in and saved does **not**
    /// restore Crash, this only ever *writes* a replacement, it never
    /// captured what was there before to write back. Switching characters
    /// again (Cortex ↔ Nina) works either direction; getting back to the
    /// level's own original Crash after a save needs a fresh copy of the
    /// disc image.
    private var characterSwapPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Play As").font(.subheadline.bold())
            Picker("Character", selection: Binding<PlayableCharacterOption>(
                get: { renderer?.pendingPlayerCharacterSwap ?? .crash },
                set: { renderer?.pendingPlayerCharacterSwap = $0.id == 0 ? nil : $0 }
            )) {
                ForEach(PlayableCharacterOption.all) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
            .disabled(renderer == nil)
            if let swap = renderer?.pendingPlayerCharacterSwap, swap.id != 0 {
                Text("Replaces this level's own player character with \(swap.displayName)'s real, verified rig (own skin, skeleton, scripts, animations, weapon), takes effect on the next save/Quick Launch. Picking \"Crash (Default)\" again does not restore the original once saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("Spawn Interactive Cortex (Prop), a separate, older feature: places a real BASICCRATE Instance wearing Cortex's mesh, static pose only, its own real break/throw physics kept intact.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let referenceNode = referenceNodeForFileOps {
                Button {
                    if armedPropSkin {
                        cancelArmedPlacement()
                    } else {
                        spawningInteractiveCortexProp()
                    }
                } label: {
                    Label(
                        isSpawningInteractiveCortexProp ? "Resolving…" : (armedPropSkin ? "Click in the viewport to place…" : "Spawn Interactive Cortex (Prop)…"),
                        systemImage: armedPropSkin ? "hand.point.up.left.fill" : "shippingbox"
                    )
                }
                .disabled(isSpawningInteractiveCortexProp || renderer == nil || !workspace.canSaveEdits(for: referenceNode))
                .help(armedPropSkin
                      ? "Click anywhere in the viewport to place it there, click this button again to cancel."
                      : "Arms placement mode: click in the viewport to place a real BASICCRATE Instance, its own real break/throw physics kept intact, wearing Cortex's own real mesh instead of a crate's. Static pose only (no animation); experimental. \"Save Chunk Overrides…\"/Quick Launch write it for real.")
                if let interactiveCortexPropError {
                    Text(interactiveCortexPropError).font(.caption).foregroundStyle(.red)
                }
            } else {
                Text("Needs at least one real Instance/Trigger/Camera in this level to anchor a save to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "On-Screen Control Legend" (QoL): the viewport's own single
    /// rotating caption line only ever shows the *current* gizmo mode's
    /// shortcut, this lists every camera/gizmo/placement shortcut at
    /// once, collapsed by default so it doesn't compete for space with
    /// the panels a returning user already knows how to find.
    private var controlsLegendPanel: some View {
        DisclosureGroup(isExpanded: $isControlsLegendExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                controlLegendRow("Drag", "Orbit the camera")
                controlLegendRow("Scroll", "Zoom (or fly speed, in Free Camera)")
                controlLegendRow("W / E / R", "Move / Rotate / Scale gizmo")
                controlLegendRow("Arrow keys", "Nudge the selection along X/Z")
                controlLegendRow("⇧ + ↑ / ↓", "Nudge the selection along Y")
                controlLegendRow("F", "Frame the current selection")
                controlLegendRow("T", "Toggle the top-down orthographic view")
                controlLegendRow("1-9", "Place whatever's pinned to that hotbar slot")
                controlLegendRow("Hold Q / Right-click", "Radial marking menu, release on a slice to run it (Cut/Copy/Paste/Inspect included)")
                controlLegendRow("⌘D", "Duplicate the selected object")
                controlLegendRow("Delete", "Delete the selected object")
                controlLegendRow("⌘Z / ⌘⇧Z", "Undo / Redo")
                controlLegendRow("WASD + Q/E", "Fly (Free Camera mode only)")
                controlLegendRow("Right-drag", "Look around (Free Camera mode only, right-click opens the marking menu everywhere else)")
            }
            .padding(.top, 4)
        } label: {
            Label("Controls", systemImage: "keyboard").font(.subheadline.bold())
        }
    }

    private func controlLegendRow(_ key: String, _ action: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.caption.monospaced().bold())
                .frame(width: 90, alignment: .leading)
            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "Viewport Rendering Modes" + "Granular Layer Visibility": the mode
    /// picker is a preset over the same `layerVisibility` the checkboxes
    /// edit directly, see `LevelViewMode.layerPreset`'s doc comment.
    private var modeAndLayersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: $viewMode) {
                ForEach(LevelViewMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: viewMode) { _, newValue in
                layerVisibility = newValue.layerPreset
                renderer?.layerVisibility = layerVisibility
            }

            Text("Scene Layers").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(SceneLayer.allCases, id: \.self) { layer in
                Toggle(layerLabel(for: layer), isOn: layerBinding(for: layer))
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            if let referenceNode = referenceNodeForFileOps {
                Divider()
                // "Rebuild All Collision", destroys this level's whole
                // collision mesh and regenerates it from every real scenery
                // object's own actual render-mesh triangles (not a box or
                // approximation, see `LevelViewerWindow.worldMeshTriangles`'s
                // own doc comment). Replaced the old incremental "Update
                // Collision for Moved Objects" button entirely: that
                // feature's box-based relocation never produced collision
                // that actually matched real in-game geometry, so there was
                // no reason to keep the lighter-weight incremental path
                // around once this whole-level rebuild existed.
                Button {
                    rebuildingAllCollision()
                } label: {
                    Label(isSavingInPlace ? "Saving…" : "Rebuild All Collision…", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSavingInPlace || !workspace.canSaveEdits(for: referenceNode) || workspace.discImageURL == nil)
                .help(workspace.discImageURL == nil
                    ? "Set a Disc Image in the Game Launcher first."
                    : "Completely destroys and regenerates this level's whole collision mesh from every scenery object's own real geometry, and saves directly into the disc image; verified before writing.")

                // Real, requested visibility: a full collision rebuild
                // rebuilds and re-verifies the *whole* disc archive before
                // writing anything back, genuinely slow for a large level,
                // not just a button-label swap most users would notice.
                // Shown for either rebuild flow (whole-level or the
                // marking menu's per-object one), since both share the
                // exact same save pipeline and the exact same wait.
                if isSavingInPlace, renderer?.rebuildAllCollisionRequested == true || renderer?.rebuildCollisionRequestedForObjectIndex != nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(renderer?.rebuildAllCollisionRequested == true
                             ? "Rebuilding the whole level's collision and saving…"
                             : "Rebuilding this object's collision and saving…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            freeCameraToggle

            Divider()
            topDownToggle

            Divider()
            scenePreviewModeToggle

            Divider()
            Button {
                isRecipeBookPresented = true
            } label: {
                Label("Recipe Book…", systemImage: "wand.and.stars")
            }
            .disabled(context.instanceMarkers.isEmpty && context.triggers.count < 2 && context.cameras.isEmpty)
            .help(context.instanceMarkers.isEmpty && context.triggers.count < 2 && context.cameras.isEmpty
                  ? "Needs this level to have at least one Instance marker, two Triggers, or one Camera to have anything to batch-edit, none of those are present here."
                  : "Reassign which real object each placement resolves to, batch-edit triggers that share the same arguments, apply verified Gameplay Mods, or unlock placed cameras.")
        }
        .sheet(isPresented: $isRecipeBookPresented) {
            if let referenceNode = referenceNodeForFileOps {
                RecipeBookView(
                    instanceMarkers: context.instanceMarkers,
                    resolvedInstanceAssets: context.resolvedInstanceAssets,
                    triggers: context.triggers,
                    cameras: context.cameras,
                    referenceNode: referenceNode
                )
                .environment(workspace)
            }
        }
    }

    /// "Active Chunk & Asset Preview Engine" (roadmap 7.1), a real,
    /// honest slice of "Scene Preview Mode": while orbiting/zooming, the
    /// camera's real world position is tested against every real decoded
    /// Trigger volume (`LevelViewerRenderer.triggerContains`), and any
    /// trigger the camera is currently "inside" highlights bright red.
    /// Deliberately not a game runtime, no player character, no physics,
    /// no live BGM/animation-cycling system; this build has no decoded
    /// trigger *semantics* to react to (see `SceneLayer.triggers`'s own
    /// history in this codebase for why "what a trigger does" isn't
    /// claimed anywhere else either), just real geometry a real camera
    /// position can be tested against.
    /// "Free Camera System in Chunk Editor": a real, independent 6-DOF
    /// flying camera, WASD/EQ to move, right-click-drag to look, scroll
    /// wheel to adjust speed, no collision (this build has no physics
    /// body to collide with anyway). Off by default; toggling it starts
    /// exactly where the orbit camera currently is/looks, so switching
    /// modes mid-session never jump-cuts the view.
    private var freeCameraToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Free Camera", isOn: $isFreeCameraMode)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: isFreeCameraMode) { _, isOn in
                    if isOn { isTopDownMode = false }
                    renderer?.isFreeCameraMode = isOn
                }
            Text(isFreeCameraMode
                ? "WASD to move, E/Q for up/down, right-click-drag to look, scroll to adjust speed."
                : "Fly freely instead of orbiting a fixed point.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// "Top-Down/Minimap", snaps to a straight-down orthographic view for
    /// spatial layout work (placing objects, reading overall level shape)
    /// without perspective foreshortening. Scroll still "zooms" (scales
    /// the orthographic extents), drag still pans around the orbit target;
    /// only the projection and eye angle change. Mutually exclusive with
    /// Free Camera, same as that toggle is with this one.
    private var topDownToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Top-Down View", isOn: $isTopDownMode)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: isTopDownMode) { _, isOn in
                    if isOn { isFreeCameraMode = false }
                    renderer?.isTopDownMode = isOn
                }
            Text(isTopDownMode
                ? "Orthographic straight-down view. Toggle off to return to the perspective camera."
                : "Snap to a straight-down orthographic minimap view. (T)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var scenePreviewModeToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Scene Preview Mode", isOn: $isScenePreviewMode)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(context.triggers.isEmpty)
                .onChange(of: isScenePreviewMode) { _, isOn in
                    if isOn { startScenePreviewTimer() } else { stopScenePreviewTimer() }
                }
            if isScenePreviewMode {
                Text(activeTriggerStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Highlights any real Trigger volume the camera is currently inside while orbiting, the camera itself, not a player character (this build has no physics/player controller).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activeTriggerStatusText: String {
        let activeIDs = renderer?.activeTriggerIDs ?? []
        guard !activeIDs.isEmpty else { return "Camera is outside every trigger volume." }
        return "Camera is inside: " + activeIDs.sorted().map { "#\($0)" }.joined(separator: ", ")
    }

    private func startScenePreviewTimer() {
        scenePreviewTimer?.invalidate()
        scenePreviewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { _ in
            renderer?.updateActiveTriggers()
        }
    }

    private func stopScenePreviewTimer() {
        scenePreviewTimer?.invalidate()
        scenePreviewTimer = nil
        renderer?.activeTriggerIDs = []
    }

    /// Extracted from `.onDisappear`, inlining this whole body in the
    /// modifier closure pushed the `body` view-builder expression past
    /// what the Swift type checker can resolve in reasonable time (a real
    /// compile error, not a style choice).
    ///
    /// Real, reported bug ("Rebuild All Collision, then Save/place
    /// scenery/Quick Launch are all permanently broken, even after
    /// `refreshingMountedDiscImage`'s own automatic reopen"): this used to
    /// clear the shared, workspace-level providers unconditionally on
    /// *any* disappearance, including one caused by
    /// `reopeningLevelViewerAfterRemount` superseding this exact window
    /// with a freshly re-opened one for the *same* level. That reopen's
    /// own `LevelViewerRenderer` build is genuinely async (`.task` ->
    /// `Task.detached`, real, measured time for a real hub-scale level , 
    /// see this file's own `[LevelViewerPerf]` instrumentation) and only
    /// registers its *own* fresh providers once that build actually
    /// finishes. If this old window's `.onDisappear`, whose own firing
    /// relative to the new window's `.task` starting isn't guaranteed
    /// either way, happened to run *after* the new window's
    /// registration, it silently wiped out the still-correct, freshly-
    /// registered providers right back to `nil`, with nothing left to
    /// ever set them again: every later Save/scenery-placement/Quick-
    /// Launch attempt read a `nil` provider and found "nothing to do,"
    /// indistinguishable from genuinely having no edits.
    ///
    /// `workspace.levelViewerContext` is the one live source of truth for
    /// "which context is actually current right now", set by
    /// `openLevelViewer` *before* the new window's own `.task` even
    /// starts (`LevelViewerWindowHost`'s body only shows a window once
    /// `levelViewerContext` is non-nil). If it's non-nil and points at a
    /// *different* context than this window's own, a newer real window
    /// has already taken over, don't touch the shared providers at all,
    /// whether that newer window already registered its own or hasn't
    /// gotten there yet. Only clear when it's genuinely `nil` (the user
    /// closed this window with nothing newer replacing it) or still
    /// points at *this* window's own context (shouldn't normally happen
    /// at `.onDisappear`, but safe either way).
    private func handlingDisappear() {
        stopScenePreviewTimer()
        // See `SceneryLoadCache.loadTasks`'s own doc comment, without
        // this, closing the window mid-Scenery-tab-load left every
        // remaining level's heavy background work running against a
        // now-orphaned cache, and reopening started a second, parallel
        // run from scratch instead of either resuming or replacing it.
        // Always correct regardless of *why* this window disappeared , 
        // `sceneryCache` is this window's own instance; a superseding
        // window gets a brand-new one either way.
        for task in sceneryCache.loadTasks { task.cancel() }
        sceneryCache.loadTasks.removeAll()
        let supersededByNewerContext = workspace.levelViewerContext != nil && workspace.levelViewerContext?.id != context.id
        guard !supersededByNewerContext else { return }
        workspace.currentViewerCameraPositionProvider = nil
        // Real, reported bug: this window's `renderer` is a plain
        // `@State`, it deallocates the moment this window closes, so
        // the providers below (which only capture it weakly) go dead
        // right along with it. Asking the live provider one last time
        // here, before it's cleared, materializes whatever's actually
        // pending into `workspace.pendingLevelViewerPatchSnapshot` so
        // the quit-time "unsaved changes" prompt still has something
        // real to warn about even after this window has already closed.
        if let patch = workspace.currentLevelViewerPendingPatchProvider?() {
            workspace.pendingLevelViewerPatchSnapshot = patch
        }
        workspace.currentLevelViewerDirtyProvider = nil
        workspace.currentLevelViewerPendingPatchProvider = nil
    }

    /// Updates the collision volume overlay to show both real and generated collision data
    /// for all objects in the level. For each object, uses assetCollisionData if available,
    /// otherwise falls back to generatedCollisionData.
    private func updateCollisionVolumeOverlay() {
        guard let renderer, showCollisionVolume else {
            renderer?.collisionVolumeWorldPositions = []
            return
        }

        var allCollisionVolumes: [(SIMD3<Float>, SIMD3<Float>)] = []

        // Process all level objects (scenery, instances, triggers, etc.)
        for obj in renderer.levelObjects {
            // Determine which collision data to use: prefer asset data, fall back to generated
            let collisionData = !obj.assetCollisionData.isEmpty ? obj.assetCollisionData : obj.generatedCollisionData

            // Skip objects with no collision data
            guard !collisionData.isEmpty else { continue }

            // Convert each collision data entry to world space and collect the box edges
            for collisionEntry in collisionData {
                // Convert collision positions from local space to world space
                let worldSpacePositions = collisionEntry.positions.map { localPos -> SIMD4<Float> in
                    // Apply scale
                    let scaledPos = SIMD3<Float>(localPos.x, localPos.y, localPos.z) * obj.scale
                    // Apply rotation
                    let rotatedPos = obj.rotation.act(scaledPos)
                    // Apply translation (world position)
                    let worldPos = rotatedPos + obj.worldPosition
                    return SIMD4<Float>(worldPos, 1)
                }

                // Generate the line segments for this collision box and add to our collection
                let boxEdges = ModelViewerRenderer.collisionBoxEdges(corners: worldSpacePositions)
                allCollisionVolumes.append(contentsOf: boxEdges)
            }
        }

        // Set the combined collision volumes for rendering
        renderer.collisionVolumeWorldPositions = allCollisionVolumes
    }

    /// Appends a real record count to layers where "I see nothing" is
    /// ambiguous between "this chunk genuinely has none of these" and "the
    /// layer toggle above is off", the two indistinguishable-looking
    /// outcomes behind a real, recurring bug report. The count is always
    /// shown, on or off, so toggling a layer off never makes its count
    /// vanish along with it.
    private func layerLabel(for layer: SceneLayer) -> String {
        let count: Int?
        switch layer {
        case .actors: count = context.instanceMarkers.count
        case .triggers: count = context.triggers.count
        case .cameras: count = context.cameras.count
        case .aiWaypoints: count = context.aiPositions.count
        case .collision: count = context.collisionMeshes.count
        case .scenery, .chunkBoundaries, .linkedChunks, .crossEngine: count = nil
        }
        guard let count else { return layer.displayName }
        return "\(layer.displayName) (\(count))"
    }

    private func layerBinding(for layer: SceneLayer) -> Binding<Bool> {
        Binding(
            get: { layerVisibility.contains(layer) },
            set: { isOn in
                if isOn { layerVisibility.insert(layer) } else { layerVisibility.remove(layer) }
                renderer?.layerVisibility = layerVisibility
            }
        )
    }

    /// "Click any rendered element to select it… open its property
    /// inspector": routes on `node.payload` to the same real inspector
    /// views the sidebar tree already uses, no separate/duplicated
    /// inspector logic for the Level Viewer.
    @ViewBuilder
    private func selectedObjectInspector(node: ChunkNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected Object").font(.headline)
            ExperimentalFieldsWarningView()
            selectedObjectIdentityHeader(node: node)
            switch node.payload {
            case .instance(let instance):
                InstanceInspectorView(node: node, instance: instance)
            case .trigger(let trigger):
                TriggerInspectorView(node: node, trigger: trigger)
            case .camera(let camera):
                CameraInspectorView(node: node, camera: camera)
            case .aiPosition(let marker):
                AIPositionInspectorView(node: node, marker: marker)
            default:
                Text("No inspector available for this record type.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A clear "what is this, and what's it called" line above every
    /// per-record-type inspector below, real object names come from
    /// `DefaultObjectID.names` (the same verified id->name table the Forge
    /// Palette already uses), never invented; a raw `objectID` shows on
    /// its own only when this build has no name for it.
    @ViewBuilder
    private func selectedObjectIdentityHeader(node: ChunkNode) -> some View {
        let identity: (icon: String, kind: String, name: String) = {
            switch node.payload {
            case .instance(let instance):
                let name = DefaultObjectID.names[instance.objectID] ?? "Unnamed Object #\(instance.objectID)"
                return ("cube.transparent.fill", "Actor / Prop Instance", name)
            case .trigger(let trigger):
                return ("square.dashed", "Trigger Volume", "Trigger #\(trigger.id)")
            case .camera(let camera):
                return ("video.fill", "Camera", "Camera #\(camera.id)")
            case .aiPosition(let marker):
                let typeName = marker.nodeType.map { "\($0)" } ?? "Unrecognized Type"
                return ("figure.walk", "AI Waypoint", "Waypoint #\(marker.id) (\(typeName))")
            default:
                return ("questionmark.square.dashed", "Unknown Record", ", ")
            }
        }()
        HStack(spacing: 6) {
            Image(systemName: identity.icon).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(identity.name).font(.callout.bold())
                Text(identity.kind).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var hasScriptedInstances: Bool {
        context.instanceMarkers.contains { $0.instance.scriptID != -1 }
    }

    /// "Level Scripts / Cutscenes": real decoded data (trigger
    /// args/flags, instance script IDs), factually presented, not the
    /// "plain English event descriptions" this build has no source for
    /// (no script bytecode decoder exists here to describe *what* a
    /// trigger/scriptID actually does). Titled "Level Events" rather than
    /// "Scripts" for exactly that reason. Clicking a row selects the
    /// underlying object, which (via `orbitTarget` already following the
    /// current selection) snaps the camera to it.
    private var levelEventsPanel: some View {
        DisclosureGroup(isExpanded: $isLevelEventsExpanded) {
            Text("Factual listing of Trigger volumes and script-carrying Instances, this build doesn't decode script bytecode, so there's no plain-English description of what any of these actually do.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Performance fix (audit): same LazyVStack fix already applied
            // to the main object list, see that ForEach's own doc comment.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(context.triggers, id: \.node.id) { entry in
                    eventRow(
                        icon: "square.dashed",
                        title: "Trigger #\(entry.trigger.id)",
                        subtitle: "args \(entry.trigger.arg1)/\(entry.trigger.arg2)/\(entry.trigger.arg3)/\(entry.trigger.arg4) · mask 0b\(String(entry.trigger.enabledMask, radix: 2))",
                        node: entry.node
                    )
                }
                ForEach(context.instanceMarkers.filter { $0.instance.scriptID != -1 }, id: \.node.id) { entry in
                    eventRow(
                        icon: "cube.transparent.fill",
                        title: "Instance #\(entry.instance.id)",
                        subtitle: "scriptID \(entry.instance.scriptID) · objectID \(entry.instance.objectID)",
                        node: entry.node
                    )
                }
            }
        } label: {
            Text("Chunk Events").font(.headline)
        }
    }

    private func eventRow(icon: String, title: String, subtitle: String, node: ChunkNode) -> some View {
        Button {
            renderer?.selectByNode(node)
            selectedIndex = renderer?.selectedObjectIndex
            refreshTransformFields()
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(4)
        }
        .buttonStyle(.plain)
    }

    /// "Chunk-Based Architecture" (Part 2): the real, decoded list of
    /// neighboring chunk files this level can stream in (`ChunkLinks`),
    /// with a "Load & Stitch" action per link that resolves the neighbor
    /// against whatever archives are currently open and appends its
    /// scenery into this same viewport (`LevelViewerRenderer.stitchChunk`).
    private var chunkLinksPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chunk Links").font(.headline)
            Text("Real neighboring-chunk references decoded from this level's own file. \"Load & Stitch\" only works if that neighbor's archive is already open in this workspace.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Performance fix (audit): same LazyVStack fix as the main
            // object list.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(context.chunkLinks, id: \.link.id) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.link.path).font(.caption).lineLimit(1)
                            Text(entry.link.hasWall ? "Boundary wall present" : "No boundary wall")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if stitchingLinkID == entry.link.id {
                            ProgressView().controlSize(.small)
                        } else if stitchedLinkIDs.contains(entry.link.id) {
                            Label("Loaded", systemImage: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Button("Load & Stitch") { loadAndStitch(entry.link) }
                                .font(.caption2)
                        }
                    }
                    .padding(4)
                }
            }
        }
    }

    /// "Chunk Stitching Rendering Bug": loads *both* halves of a stitched
    /// neighbor now, not just its scenery, see `WorkspaceViewModel.
    /// loadChunkLinkActors`'s doc comment for why actors/triggers/cameras/
    /// AI waypoints were never wired up here before. Runs both loads
    /// concurrently since they read two independent files (the neighbor's
    /// `.sm2` and its sibling `.rm2`) and neither depends on the other's
    /// result.
    private func loadAndStitch(_ link: ChunkLink) {
        stitchingLinkID = link.id
        Task {
            defer { stitchingLinkID = nil }
            async let sceneryResult = workspace.loadChunkLinkPlacements(for: link)
            async let actorResult = workspace.loadChunkLinkActors(for: link)
            let (scenery, actors) = await (sceneryResult, actorResult)

            guard scenery != nil || actors != nil else {
                workspace.lastError = "Couldn't find \"\(link.path)\" in any currently open archive, open the level or archive it belongs to first."
                return
            }
            let hasActors = actors.map { !$0.instanceMarkers.isEmpty || !$0.triggers.isEmpty || !$0.cameras.isEmpty || !$0.aiPositions.isEmpty } ?? false
            guard (scenery?.placements.isEmpty == false) || hasActors else {
                workspace.lastError = "\(scenery?.fileName ?? actors?.fileName ?? link.path) resolved but has nothing to show (no scenery, instances, triggers, cameras, or AI waypoints)."
                return
            }

            // "Coordinate-System Overhaul": `chunkMatrix`'s translation row
            // is raw on-disk data, same as every other position this build
            // decodes, needs the same world-space X mirror
            // `result.placements` already got via the (now-corrected)
            // `SceneryModelPlacement.worldTransform`, or a stitched
            // neighbor lands offset in the wrong direction along X.
            let offset = link.chunkMatrix.count > 3
                ? ModelViewerRenderer.mirroredWorldPosition(SIMD3(link.chunkMatrix[3].x, link.chunkMatrix[3].y, link.chunkMatrix[3].z))
                : SIMD3<Float>.zero

            // Real, reported performance bug (code review): building GPU
            // submeshes for every stitched placement, vertex interleave,
            // `device.makeBuffer`, texture upload, used to run inline
            // here, on the main actor, reproducing the exact freeze-on-open
            // bug this same session already fixed for the *initial* level
            // load, just triggered by "Load & Stitch" instead. `renderer`
            // is captured once up front, `device`/`fallbackTexture` are
            // stable GPU-context values safe to read off-main; only the
            // final `objects.append` (inside `stitchChunk`/`stitchChunkActors`
            // below) needs to stay on whatever thread owns `objects`, which
            // for this Task's un-detached body is still the main actor.
            var added = 0
            var fileName = link.path
            if let scenery, let renderer {
                let device = renderer.device
                let fallbackTexture = renderer.fallbackTexture
                let (built, failedBuildCount) = await Task.detached(priority: .userInitiated) {
                    LevelViewerRenderer.buildingStitchedChunkObjects(placements: scenery.placements, worldOffset: offset, device: device, fallbackTexture: fallbackTexture)
                }.value
                if failedBuildCount > 0 {
                    AppLog.rendering.debug("loadAndStitch, \(failedBuildCount) of \(scenery.placements.count) resolved placements built zero GPU submeshes, dropped before rendering")
                }
                self.renderer?.appendingStitchedObjects(built)
                added += built.count
                fileName = scenery.fileName
            }
            if let actors, let renderer {
                let device = renderer.device
                let fallbackTexture = renderer.fallbackTexture
                let built = await Task.detached(priority: .userInitiated) {
                    LevelViewerRenderer.buildingStitchedChunkActorObjects(
                        instanceMarkers: actors.instanceMarkers, resolvedInstanceAssets: actors.resolvedInstanceAssets,
                        triggers: actors.triggers, cameras: actors.cameras, aiPositions: actors.aiPositions,
                        worldOffset: offset, device: device, fallbackTexture: fallbackTexture
                    )
                }.value
                self.renderer?.appendingStitchedObjects(built)
                added += built.count
                if scenery == nil { fileName = actors.fileName }
            }
            stitchedLinkIDs.insert(link.id)
            layerVisibility.insert(.linkedChunks)
            renderer?.layerVisibility = layerVisibility
            workspace.statusMessage = "Stitched \(added) object(s) from \(fileName)."
        }
    }

    /// "Cross-Engine Chunk Stitcher" (roadmap 5.3): the mandate's other
    /// half of "load chunk files from different engines... side-by-side."
    /// A real Wrath of Cortex `.CRT`/`.WMP` file, parsed by
    /// `WrathOfCortexParser` (real decode, verified against real WoC disc
    /// bytes, see `WOCCrateFile`'s doc comment), plotted directly into
    /// this same Twinsanity chunk's viewport as a separate, offset,
    /// independently toggleable layer.
    private var crossEngineDataPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cross-Engine Data").font(.headline)
            Text("Load a real Wrath of Cortex .CRT (crates) or .WMP (Wumpa fruit) file and plot it alongside this chunk, offset 20 units on X so it doesn't overlap.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Load Wrath of Cortex File…") { loadCrossEngineFile() }
            ForEach(Array(crossEngineLoadLog.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadCrossEngineFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a real Wrath of Cortex .CRT (crates) or .WMP (Wumpa fruit) file."
        panel.prompt = "Load"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Fixed offset so the cross-engine data doesn't land on top of the
        // currently loaded chunk, these two games have no real shared
        // coordinate space to align through, unlike `ChunkLink.chunkMatrix`
        // (a real, decoded alignment transform for same-engine neighbors).
        let offset = SIMD3<Float>(20, 0, 0)
        // Same "keep file I/O off the main actor" discipline as every other
        // open path in this app, a .CRT/.WMP is small in practice, but
        // there's no reason this one should be the exception that can still
        // block the UI on a slow/network volume.
        Task {
            do {
                let readTask = Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url, options: .mappedIfSafe)
                }
                let data = try await readTask.value
                switch url.pathExtension.lowercased() {
                case "crt":
                    let file = try WrathOfCortexParser.parseCrateFile(data)
                    let positions = file.groups.flatMap { $0.crates.map(\.position) }
                    renderer?.stitchCrossEngineData(crates: positions, wumpas: [], worldOffset: offset)
                    layerVisibility.insert(.crossEngine)
                    renderer?.layerVisibility = layerVisibility
                    crossEngineLoadLog.append("\(url.lastPathComponent): \(file.groups.count) group(s), \(file.totalCrateCount) crate(s)")
                case "wmp":
                    let file = try WrathOfCortexParser.parseWumpaFile(data)
                    renderer?.stitchCrossEngineData(crates: [], wumpas: file.positions, worldOffset: offset)
                    layerVisibility.insert(.crossEngine)
                    renderer?.layerVisibility = layerVisibility
                    crossEngineLoadLog.append("\(url.lastPathComponent): \(file.positions.count) Wumpa position(s)")
                default:
                    workspace.lastError = "Unrecognized file, expected a .CRT or .WMP Wrath of Cortex file."
                }
            } catch {
                workspace.lastError = "Failed to parse \(url.lastPathComponent): \(error)"
            }
        }
    }

    @ViewBuilder
    private var gizmoControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transform").font(.headline)

            Picker("Gizmo", selection: $gizmoMode) {
                Text("Move (W)").tag(GizmoMode.translate)
                Text("Rotate (E)").tag(GizmoMode.rotate)
                Text("Scale (R)").tag(GizmoMode.scale)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: gizmoMode) { _, newValue in renderer?.gizmoMode = newValue }

            Toggle("Snap to Grid", isOn: $snapToGrid)
                .toggleStyle(.checkbox)
                .help("Rounds a gizmo drag to the nearest snap step.")
                .onChange(of: snapToGrid) { _, newValue in renderer?.snapToGrid = newValue }

            // Aligns either center-to-center or face-to-face against the
            // neighbor's real edge, whichever is closer to where the piece
            // was dragged, so boxes can stack flush or connect side by
            // side.
            Toggle("Magnet Snap", isOn: $magnetSnapEnabled)
                .toggleStyle(.checkbox)
                .help("Snaps a dragged object into exact alignment with a nearby one.")
                .onChange(of: magnetSnapEnabled) { _, newValue in renderer?.magnetSnapEnabled = newValue }

            // Uses each object's own asset collision data where available,
            // falling back to an automatically generated box otherwise.
            Toggle("Show Collision Volume", isOn: $showCollisionVolume)
                .toggleStyle(.checkbox)
                .help("Draws each object's collision box as an orange wireframe.")

            // Real, on-disk data (Instance.childInstanceIDs), confirmed
            // against the actual disc, not inferred.
            Toggle("Show Crate Chains", isOn: $showCrateChains)
                .toggleStyle(.checkbox)
                .help("Draws a line from each detonator crate to its target crate(s).")
                .onChange(of: showCrateChains) { _, newValue in renderer?.showCrateChains = newValue }

            Toggle("Cull Back Faces", isOn: $cullBackFaces)
                .toggleStyle(.checkbox)
                .help("Roughly halves per-frame rendering cost by not shading the back side of each triangle. Off by default because some level geometry is deliberately thin/single-sided (foliage, decals) and would go invisible from behind if culled, try this if the viewport feels slow, and turn it back off if anything looks like it's missing.")
                .onChange(of: cullBackFaces) { _, newValue in renderer?.cullBackFaces = newValue }

            HStack {
                Text("Grid Size")
                Stepper(value: $gridSize, in: 0.1...100, step: 0.5) {
                    Text(String(format: "%.1f", gridSize))
                }
                .help("World units between move/scale snap points.")
                .onChange(of: gridSize) { _, newValue in renderer?.gridSize = Float(newValue) }
            }
            HStack {
                Text("Rotation Snap")
                Stepper(value: $rotationSnapDegrees, in: 1...90, step: 5) {
                    Text("\(Int(rotationSnapDegrees))°")
                }
                .help("Degrees between rotation snap points.")
                .onChange(of: rotationSnapDegrees) { _, newValue in renderer?.rotationSnapDegrees = Float(newValue) }
            }

            if selectedIndex != nil {
                transformFieldGroup(title: "Position", x: $positionX, y: $positionY, z: $positionZ, apply: applyPositionFields)
                Button {
                    copyViewerPositionToSelected()
                } label: {
                    Label("Copy Viewer Position", systemImage: "camera.viewfinder")
                }
                .controlSize(.small)
                .help("Sets the selected object's position to the camera's current position.")
                transformFieldGroup(title: "Rotation °", x: $rotationX, y: $rotationY, z: $rotationZ, apply: applyRotationFields)
                transformFieldGroup(title: "Scale", x: $scaleX, y: $scaleY, z: $scaleZ, apply: applyScaleFields)
                HStack {
                    // Scenery has no write path back to the file yet, and a
                    // camera's own spline/path control points duplicate with
                    // the whole camera, not individually.
                    Button {
                        duplicateSelected()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!canDuplicateSelected)
                    .help(canDuplicateSelected
                        ? "Duplicate the selected object, with real write-back to disk on save."
                        : "Only Actor, Waypoint, Trigger, and Camera placements can be duplicated.")

                    // A stitched neighbor chunk's scenery (added via a Chunk
                    // Link) lives in a different file, so it can't be
                    // deleted from here either.
                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!canDeleteSelected)
                    .help(canDeleteSelected
                        ? "Deletes the selected object; persists once you Save Chunk Overrides."
                        : "Stitched neighbor scenery and individual camera spline points can't be deleted here.")
                }

                if canScatterSelected {
                    Divider()
                    Label("Procedural Brush", systemImage: "wind").font(.caption.bold())
                    HStack {
                        Text("Count"); Stepper(value: $scatterCount, in: 1...50) { Text("\(Int(scatterCount))") }
                    }
                    HStack {
                        Text("Radius"); Stepper(value: $scatterRadius, in: 0.5...50, step: 0.5) { Text(String(format: "%.1f", scatterRadius)) }
                    }
                    Button {
                        scatterSelected()
                    } label: {
                        Label("Scatter \(Int(scatterCount))…", systemImage: "wind")
                    }
                    Text("Set-dresses the level: scatters \(Int(scatterCount)) more real copies of the selected object at random positions/rotations within \(String(format: "%.1f", scatterRadius))m, each one a genuine new Instance record on save, through the same pipeline Duplicate uses.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Select an object below (or drag one from the Models Hub into the viewport) to transform it with the gizmo or these fields.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func transformFieldGroup(title: String, x: Binding<String>, y: Binding<String>, z: Binding<String>, apply: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow { Text("X"); transformField(x, apply: apply) }
                GridRow { Text("Y"); transformField(y, apply: apply) }
                GridRow { Text("Z"); transformField(z, apply: apply) }
            }
            Button("Apply") { apply() }
                .help("⌘Z undoes it, same as a gizmo drag.")
        }
    }

    private func transformField(_ text: Binding<String>, apply: @escaping () -> Void) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
            .onSubmit(apply)
    }

    /// "AI Pathfinding/Navmesh Editor" (roadmap 5.1): real write-back for
    /// waypoints, "Add Waypoint" inserts a brand-new, real `AIPosition`
    /// record (`ChunkSectionInserter`, the same generic insertion path the
    /// Forge Palette already trusts for Instance records) and every
    /// waypoint's current position (dragged or freshly placed) saves via
    /// "Save Chunk Overrides…" below, since `AIPosition` is fixed-size , 
    /// no separate "remove a waypoint" button: shrinking a section safely
    /// is real, separate work this build doesn't have yet.
    private var aiWaypointsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI Waypoints (\(context.aiPositions.count))").font(.headline)
            Text("Drag a waypoint with the gizmo like any other object, its new position saves for real via \"Save Chunk Overrides…\" below. \"Add Waypoint\" places a brand-new, real AIPosition record.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Add Waypoint") { addAIWaypoint() }
        }
    }

    private func addAIWaypoint() {
        guard let renderer, let index = renderer.spawnAIWaypoint() else { return }
        selectedIndex = index
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Add AI Waypoint")
        Self.registerAIWaypointPlacementUndo(undoManager: undoManager, renderer: renderer, index: index)
    }

    /// Same recursive add/remove undo shape as `registerPlacementUndo`, for
    /// `spawnAIWaypoint` instead of `spawnInstance`.
    private static func registerAIWaypointPlacementUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int) {
        guard let snapshot = renderer.newAIWaypointInfo(at: index) else { return }
        undoManager.registerUndo(withTarget: renderer) { target in
            target.removeObject(at: index)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                let newIndex = redoTarget.spawnAIWaypoint(at: snapshot.worldPosition, rawNodeType: snapshot.rawNodeType) ?? index
                registerAIWaypointPlacementUndo(undoManager: undoManager, renderer: redoTarget, index: newIndex)
            }
        }
    }

    /// "Add Trigger"/"Add Camera": closes the parity gap the original
    /// editor's `Menu_AddNew` has for these two record types, real, brand-
    /// new records inserted via `ChunkSectionInserter` on save, same as
    /// "Add Waypoint."
    private var addTriggerCameraPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add Objects").font(.headline)
            Text("Places a brand-new Trigger or Camera at the level's visual center, drag it into position, then Save Chunk Overrides… to make it real.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Add Trigger") { addTrigger() }
                Button("Add Camera") { addCamera() }
            }
        }
    }

    private func addTrigger() {
        guard let renderer, let index = renderer.spawnTrigger() else { return }
        selectedIndex = index
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Add Trigger")
        Self.registerTriggerPlacementUndo(undoManager: undoManager, renderer: renderer, index: index)
    }

    private func addCamera() {
        guard let renderer, let index = renderer.spawnCamera() else { return }
        selectedIndex = index
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Add Camera")
        Self.registerCameraPlacementUndo(undoManager: undoManager, renderer: renderer, index: index)
    }

    static func registerTriggerPlacementUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int) {
        guard let worldPosition = renderer.newTriggerInfo(at: index) else { return }
        undoManager.registerUndo(withTarget: renderer) { target in
            target.removeObject(at: index)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                let newIndex = redoTarget.spawnTrigger(at: worldPosition) ?? index
                registerTriggerPlacementUndo(undoManager: undoManager, renderer: redoTarget, index: newIndex)
            }
        }
    }

    static func registerCameraPlacementUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int) {
        guard let worldPosition = renderer.newCameraInfo(at: index) else { return }
        undoManager.registerUndo(withTarget: renderer) { target in
            target.removeObject(at: index)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                let newIndex = redoTarget.spawnCamera(at: worldPosition) ?? index
                registerCameraPlacementUndo(undoManager: undoManager, renderer: redoTarget, index: newIndex)
            }
        }
    }

    /// Regression fix: duplicating a session-placed scenery object (real
    /// since `duplicateSelectedObject()` gained a `.scenery` case) had no
    /// matching undo registration at all, ⌘Z after duplicating one did
    /// nothing, silently leaving the duplicate to be written on the next
    /// save. Same recursive add/remove shape as `registerTriggerPlacementUndo`/
    /// `registerCameraPlacementUndo` above.
    static func registerSceneryPlacementUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int) {
        guard let info = renderer.newSceneryInfo(at: index) else { return }
        undoManager.registerUndo(withTarget: renderer) { target in
            target.removeObject(at: index)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                // A cross-level placement's redo must go back through
                // `spawnCrossLevelScenery`, `info.modelID` for one of
                // these is only a session-local placeholder, not a real
                // destination modelID `spawnScenery` could use directly.
                let newIndex: Int?
                if let crossLevelSource = info.crossLevelSource {
                    newIndex = redoTarget.spawnCrossLevelScenery(source: crossLevelSource, asset: info.asset, at: info.worldPosition, applyPlacementAlignment: false)
                } else {
                    newIndex = redoTarget.spawnScenery(modelID: info.modelID, isSpecial: info.isSpecial, asset: info.asset, at: info.worldPosition, applyPlacementAlignment: false)
                }
                registerSceneryPlacementUndo(undoManager: undoManager, renderer: redoTarget, index: newIndex ?? index)
            }
        }
    }

    private var canDeleteSelected: Bool {
        guard let renderer, let selectedIndex else { return false }
        return renderer.canDelete(at: selectedIndex)
    }

    /// "Batch Editing, Select All Matching": only real for an Instance
    /// (crate/enemy/platform) placement, `LevelViewerRenderer.
    /// instanceObjectID(at:)` only resolves a real type ID for the
    /// `.actors` layer, matching every other type-grouping helper in this
    /// file (`scatterAroundSelected`/`duplicateSelectedObject`).
    private var canSelectAllMatchingSelectedType: Bool {
        guard let renderer, let selectedIndex else { return false }
        return renderer.instanceObjectID(at: selectedIndex) != nil
    }

    /// "Batch Editing, Select All Matching", real, requested missing
    /// feature: adds every other Instance of the same real object type as
    /// the current selection to `alignmentSelection` (the same picked set
    /// ⌘-click already builds), so a whole set of e.g. every crate of one
    /// kind in the level can be batch-moved/aligned/deleted at once
    /// instead of ⌘-clicking each one by hand.
    private func selectAllMatchingSelectedType() {
        guard let renderer, let selectedIndex, let objectID = renderer.instanceObjectID(at: selectedIndex) else { return }
        var matched: Set<Int> = []
        for summary in renderer.objectSummaries where summary.layer == .actors {
            if renderer.instanceObjectID(at: summary.index) == objectID {
                matched.insert(summary.index)
            }
        }
        alignmentSelection = matched
        workspace.statusMessage = "Selected \(matched.count) matching object(s) for Align/Distribute/batch delete."
    }

    /// Deletes the selected object through `LevelViewerRenderer.deleteObject`
    /// (real removal from disk on save, for a real record, see that
    /// function's own doc comment) and registers a recursive undo/redo
    /// step, same shape as `registerTransformUndo`/`registerPlacementUndo`:
    /// undo re-inserts the exact removed value via `restoreObject`; redo
    /// (registered as the undo *of that* restore) deletes it again.
    private func deleteSelected() {
        guard let renderer, let index = selectedIndex, let snapshot = renderer.deleteObject(at: index) else { return }
        selectedIndex = nil
        // Removing an object shifts every later index down by one --
        // `alignmentSelection` has no way to know which of its members
        // just became stale, so drop the whole picked set rather than risk
        // Align/Distribute silently operating on the wrong objects next.
        alignmentSelection.removeAll()
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Delete Object")
        Self.registerDeleteUndo(undoManager: undoManager, renderer: renderer, index: index, snapshot: snapshot)
    }

    private static func registerDeleteUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int, snapshot: LevelViewerRenderer.RemovedObjectSnapshot) {
        undoManager.registerUndo(withTarget: renderer) { target in
            target.restoreObject(snapshot, at: index)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                guard let redoSnapshot = redoTarget.deleteObject(at: index) else { return }
                registerDeleteUndo(undoManager: undoManager, renderer: redoTarget, index: index, snapshot: redoSnapshot)
            }
        }
    }

    /// "Batch Editing, Batch Delete", real, requested missing feature:
    /// deletes every object in `alignmentSelection` (the same picked set
    /// "Select All Matching"/⌘-click builds) in one action instead of
    /// deleting each one by hand. Indices are deleted highest-first , 
    /// removing an object shifts every later index down by one, so
    /// deleting in descending order is what keeps every *not-yet-deleted*
    /// index in the batch still pointing at the right object throughout
    /// (the same reason `deleteSelected()` already drops the whole picked
    /// set afterward: once indices have shifted, an old index is no
    /// longer trustworthy for anything else). Wrapped in one real
    /// `NSUndoManager` group so ⌘Z undoes the whole batch at once, not one
    /// object at a time.
    private func batchDeleteAlignmentSelection() {
        guard let renderer, !alignmentSelection.isEmpty else { return }
        let indices = alignmentSelection.sorted(by: >)
        guard let undoManager else { return }
        undoManager.beginUndoGrouping()
        undoManager.setActionName("Delete \(indices.count) Objects")
        var deletedCount = 0
        for index in indices {
            guard let snapshot = renderer.deleteObject(at: index) else { continue }
            deletedCount += 1
            Self.registerDeleteUndo(undoManager: undoManager, renderer: renderer, index: index, snapshot: snapshot)
        }
        undoManager.endUndoGrouping()
        selectedIndex = nil
        alignmentSelection.removeAll()
        refreshTransformFields()
        workspace.statusMessage = "Deleted \(deletedCount) object(s)."
    }

    /// "Copy Viewer Position": the same convenience the original editor's
    /// Position/AIPosition/Instance editors offer, grabs the camera's
    /// current real-world eye position into the selected object's
    /// position field, through the same undo path every other position
    /// edit already uses.
    private func copyViewerPositionToSelected() {
        guard let renderer, selectedIndex != nil else { return }
        let previousSnapshot = currentSnapshot()
        renderer.setSelectedPosition(to: renderer.cameraEyeWorldPosition)
        refreshTransformFields()
        registerUndoAndRefreshCollisionOverlay(from: previousSnapshot)
    }

    /// "AI Pathfinding/Navmesh Editor" (roadmap 5.1): the real `AIPath`
    /// records in this file, no position of their own (see
    /// `AIPathRecord`'s doc comment), so a factual list rather than a
    /// scene-layer overlay. `AIPosition` waypoints render in the viewport
    /// instead (the "AI Waypoints" scene layer).
    /// Real, on-disk AI Paths not marked removed this session -- the
    /// "context data minus removed" half of the effective set. `AIPath`
    /// has no `GPULevelObject`/spatial state for the renderer to merge
    /// this into the way every other placeable type's list already does,
    /// so the merge happens here instead.
    private var remainingRealAIPaths: [(node: ChunkNode, path: AIPathRecord)] {
        let removedIDs = Set(renderer?.pendingRemovedAIPathIDs ?? [])
        return context.aiPaths.filter { !removedIDs.contains($0.path.id) }
    }

    /// "Pre-save validation", scans every real cross-record ID reference
    /// this codebase actually has confirmed (`TriggerVolume.instanceIDs`,
    /// `PlacedCamera.instanceIDs`, `PlacedInstance.childInstanceIDs`, see
    /// each type's own doc comment) plus one the reference tool's editor
    /// labels but never resolves (`AIPathRecord.startAIPositionID`/
    /// `endAIPositionID`, worded as a heads-up rather than a fact below)
    /// against this session's pending deletions, so a Trigger/Camera/
    /// Instance/AIPath that still references something the user just
    /// deleted gets caught *before* it's silently written to disk instead
    /// of discovered later as a broken reference in-game. `ChunkSectionInserter
    /// .removingRecord(s)` only removes the target record's own bytes , 
    /// nothing scrubs surviving records' reference fields, so this is a
    /// real, exercisable gap without this check.
    ///
    /// Deliberately informational, not blocking, this codebase has no
    /// confirmation-dialog pattern anywhere else (Delete itself fires
    /// instantly, with Undo/"nothing hits disk until Save" as the safety
    /// net), and one of the four checks here rests on an explicitly
    /// unconfirmed reference, so hard-blocking risks a false-positive
    /// block on a legitimate edit.
    private func danglingReferenceWarnings() -> [String] {
        guard let renderer else { return [] }
        let triggers = context.triggers.map { (id: $0.trigger.id, instanceIDs: $0.trigger.instanceIDs) }
        let cameras = context.cameras.map { (id: $0.camera.id, instanceIDs: $0.camera.instanceIDs) }
        let instances = context.instanceMarkers.map { (id: $0.instance.id, childInstanceIDs: $0.instance.childInstanceIDs) }
        let aiPaths = remainingRealAIPaths.map { (id: $0.path.id, startAIPositionID: $0.path.startAIPositionID, endAIPositionID: $0.path.endAIPositionID) }
        let removedInstanceIDs = Set(renderer.pendingRemovedInstanceIDs)
        let removedTriggerIDs = Set(renderer.pendingRemovedTriggerIDs)
        let removedCameraIDs = Set(renderer.pendingRemovedCameraIDs)
        let removedAIPositionIDs = Set(renderer.pendingRemovedAIPositionIDs)

        let brokenByThisSession = DanglingReferenceChecker.warnings(
            triggers: triggers, cameras: cameras, instances: instances, aiPaths: aiPaths,
            removedInstanceIDs: removedInstanceIDs,
            removedTriggerIDs: removedTriggerIDs,
            removedCameraIDs: removedCameraIDs,
            removedAIPositionIDs: removedAIPositionIDs
        )
        // "Cross-Reference Validation, Unresolvable References": also
        // catches a reference that was already broken before this session
        // touched anything, see `unresolvedReferenceWarnings`'s own doc
        // comment for why that's a real, separate gap from the
        // this-session-only check above. Source records already being
        // removed this session are excluded here too (same reasoning as
        // `warnings()`'s own `where !removed...Contains(...)` filters) , 
        // there's no point flagging a broken reference belonging to a
        // record that won't exist in the saved output anyway.
        let alreadyBroken = DanglingReferenceChecker.unresolvedReferenceWarnings(
            triggers: triggers.filter { !removedTriggerIDs.contains($0.id) },
            cameras: cameras.filter { !removedCameraIDs.contains($0.id) },
            instances: instances.filter { !removedInstanceIDs.contains($0.id) },
            aiPaths: aiPaths,
            existingInstanceIDs: Set(context.instanceMarkers.map { $0.instance.id }).subtracting(removedInstanceIDs),
            existingAIPositionIDs: Set(context.aiPositions.map { $0.marker.id }).subtracting(removedAIPositionIDs)
        )
        return brokenByThisSession + alreadyBroken
    }

    /// Runs `action` immediately if there's nothing to warn about;
    /// otherwise stashes it behind the confirmation alert (`body`'s
    /// `.alert` modifier) and shows the real warnings first. Shared by
    /// both "Save Chunk Overrides…" and "Quick Launch…", the check has
    /// to run before either one, and the warnings/action-to-run-if-
    /// confirmed shape is identical for both.
    private func confirmingDanglingReferences(before action: @escaping () -> Void) {
        let warnings = danglingReferenceWarnings()
        guard !warnings.isEmpty else {
            action()
            return
        }
        pendingDanglingWarnings = warnings
        pendingConfirmedSaveAction = action
    }

    private var aiPathsPanel: some View {
        DisclosureGroup(isExpanded: $isAIPathsExpanded) {
            Text("Start/End set which two AIPosition waypoints this path connects, shown as a connecting line in the viewport when AI Waypoints are visible. The other 3 raw args have no confirmed meaning.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Performance fix (audit): same LazyVStack fix as the main
            // object list.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(remainingRealAIPaths, id: \.node.id) { entry in
                    aiPathRow(id: entry.path.id, isNew: false) {
                        Button("Select") { workspace.select(entry.node) }
                            .controlSize(.small)
                    }
                }
                ForEach(renderer?.newAIPaths ?? [], id: \.id) { entry in
                    aiPathRow(id: entry.id, isNew: true) { EmptyView() }
                }
            }
            Button("Add Path") { addAIPath() }
        } label: {
            Text("AI Paths (\(remainingRealAIPaths.count + (renderer?.newAIPaths.count ?? 0)))").font(.headline)
        }
    }

    /// One AI Path's row in the panel above, real, current args (not the
    /// static on-disk snapshot, so a pending edit shows immediately),
    /// Start/End each with a resolved waypoint name (or the raw candidate
    /// ID if it doesn't currently resolve to anything real, honest, not
    /// hidden) and a "Pick" button that arms `armAIPathEndpointPick`.
    /// `leadingAccessory` is the existing path's own "Select" button (a
    /// session-added path has no `ChunkNode` yet to select).
    @ViewBuilder
    private func aiPathRow<Accessory: View>(id: UInt32, isNew: Bool, @ViewBuilder leadingAccessory: () -> Accessory) -> some View {
        let args = renderer?.currentAIPathArgs(id: id) ?? []
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(isNew ? "Path #\(id) (new)" : "Path #\(id)")
                    .font(.caption.bold())
                Spacer()
                leadingAccessory()
                Button { duplicateAIPath(args: args) } label: { Image(systemName: "plus.square.on.square") }
                    .controlSize(.small).buttonStyle(.plain)
                    .help("Duplicate this path")
                    .accessibilityLabel("Duplicate path")
                Button(role: .destructive) { deleteAIPath(id: id, args: args, isNew: isNew) } label: { Image(systemName: "trash") }
                    .controlSize(.small).buttonStyle(.plain)
                    .help("Delete this path")
                    .accessibilityLabel("Delete path")
            }
            HStack(spacing: 12) {
                aiPathEndpointField(label: "Start", waypointID: args.indices.contains(0) ? args[0] : nil, pathID: id, isNew: isNew, isStart: true)
                aiPathEndpointField(label: "End", waypointID: args.indices.contains(1) ? args[1] : nil, pathID: id, isNew: isNew, isStart: false)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func aiPathEndpointField(label: String, waypointID: UInt16?, pathID: UInt32, isNew: Bool, isStart: Bool) -> some View {
        let resolvedName = waypointID.flatMap { renderer?.aiWaypointDisplayName(id: UInt32($0)) }
        HStack(spacing: 4) {
            Text("\(label):").font(.caption2).foregroundStyle(.secondary)
            Text(resolvedName ?? waypointID.map { "#\($0) (unresolved)" } ?? ", ")
                .font(.caption2.monospaced())
                .foregroundStyle(resolvedName != nil ? Color.primary : Color.orange)
                .lineLimit(1)
            Button("Pick") { armAIPathEndpointPick(pathID: pathID, isNew: isNew, isStart: isStart) }
                .controlSize(.mini)
                .disabled(pendingAIPathPick != nil)
        }
    }

    /// "Add Path": no spatial placement step (see `AIPathRecord`'s own
    /// doc comment for why) -- a new path with plausible default args
    /// (start/end waypoint 0/1) is added directly to the session's
    /// pending set, editable afterward the same way any other AIPath is
    /// (select the real record once saved, or edit the raw args here for
    /// a still-session-only one -- args editing beyond the default is a
    /// real follow-up, not attempted inline in this small panel yet).
    private func addAIPath() {
        guard let renderer else { return }
        let id = renderer.addAIPath()
        guard let undoManager else { return }
        undoManager.setActionName("Add AI Path")
        Self.registerAIPathAddUndo(undoManager: undoManager, renderer: renderer, id: id, args: [0, 1, 0, 0, 0])
    }

    private func duplicateAIPath(args: [UInt16]) {
        guard let renderer else { return }
        let id = renderer.addAIPath(args: args)
        guard let undoManager else { return }
        undoManager.setActionName("Duplicate AI Path")
        Self.registerAIPathAddUndo(undoManager: undoManager, renderer: renderer, id: id, args: args)
    }

    /// Same recursive add/redo undo shape as `registerAIWaypointPlacementUndo`,
    /// just calling `addAIPath`/`removeAIPath` directly instead of
    /// `spawnAIWaypoint`/`removeObject`, since AIPath has no viewport
    /// index to restore at.
    private static func registerAIPathAddUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, id: UInt32, args: [UInt16]) {
        undoManager.registerUndo(withTarget: renderer) { target in
            target.removeAIPath(id: id)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                let newID = redoTarget.addAIPath(args: args, explicitID: id)
                registerAIPathAddUndo(undoManager: undoManager, renderer: redoTarget, id: newID, args: args)
            }
        }
    }

    private func deleteAIPath(id: UInt32, args: [UInt16], isNew: Bool) {
        guard let renderer else { return }
        renderer.removeAIPath(id: id)
        guard let undoManager else { return }
        undoManager.setActionName("Delete AI Path")
        Self.registerAIPathDeleteUndo(undoManager: undoManager, renderer: renderer, id: id, args: args, isNew: isNew)
    }

    /// Undo re-inserts the exact removed path -- via `restoreAIPath` for a
    /// real, on-disk one (its data was never actually forgotten, just
    /// marked removed) or `addAIPath(explicitID:)` for a session-added
    /// one (same "keep the same ID across undo/redo" reasoning as
    /// `registerAIPathAddUndo`). Redo (the undo *of* that restore)
    /// deletes it again, same shape as `registerDeleteUndo`.
    private static func registerAIPathDeleteUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, id: UInt32, args: [UInt16], isNew: Bool) {
        undoManager.registerUndo(withTarget: renderer) { target in
            if isNew {
                target.addAIPath(args: args, explicitID: id)
            } else {
                target.restoreAIPath(id: id)
            }
            undoManager.registerUndo(withTarget: target) { redoTarget in
                redoTarget.removeAIPath(id: id)
                registerAIPathDeleteUndo(undoManager: undoManager, renderer: redoTarget, id: id, args: args, isNew: isNew)
            }
        }
    }

    /// Collapsed by default, a real level's object list runs into the
    /// hundreds, and a scene this size used to mean scrolling straight
    /// past everything below it just to reach the other sidebar panels.
    @ViewBuilder
    private var objectList: some View {
        let allSummaries = renderer?.objectSummaries ?? []
        let filteredSummaries = sidebarSearchText.isEmpty
            ? allSummaries
            : allSummaries.filter { $0.displayName.localizedCaseInsensitiveContains(sidebarSearchText) }
        DisclosureGroup(isExpanded: $isObjectListExpanded) {
            if filteredSummaries.isEmpty && !sidebarSearchText.isEmpty {
                Text("No objects match “\(sidebarSearchText)”.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // "Feature Discoverability" audit: `alignDistributeControls`
            // itself renders nothing at all until `alignmentSelection` is
            // non-empty, before this, the only hint that ⌘-click does
            // anything special was a per-row `.help()` tooltip nobody sees
            // without already hovering a row. A persistent, always-visible
            // line here (replaced by the real toolbar the moment something
            // is picked) makes Align/Distribute/Batch Script/Batch Delete
            // discoverable without requiring the user to already know they
            // exist.
            if alignmentSelection.isEmpty, !filteredSummaries.isEmpty {
                Text("Tip: ⌘-click objects below to Align, Distribute, run a Batch Script, or Batch Delete them.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            alignDistributeControls
            // Real, reported performance bug: "10 second delay on
            // literally anything", this row list was a plain `ForEach`
            // directly inside the sidebar's single outer `VStack`/
            // `ScrollView` (see that `ScrollView`'s own body), not a
            // `LazyVStack`. SwiftUI has no reason to skip building every
            // row's actual view (icon, background, `.help()` tooltip,
            // `.buttonStyle`) up front rather than only the ones actually
            // scrolled into view, for a real hub-scale level (448 scenery
            // + 222 instances + 11 triggers + 13 cameras here) that's
            // ~700 real `Button` subtrees built and laid out on *every*
            // re-evaluation of this view, which SwiftUI triggers on any
            // `@State` change anywhere in this same monolithic window , 
            // selecting an object, nudging a position, even something
            // unrelated like the search field's own text binding. Scoping
            // this one `ForEach` in its own `LazyVStack` costs nothing
            // (identical rows, identical order) and lets SwiftUI only
            // build what's actually visible.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredSummaries, id: \.index) { summary in
                    Button {
                        if NSEvent.modifierFlags.contains(.command) {
                            toggleAlignmentSelection(summary.index)
                        } else {
                            select(summary.index)
                        }
                    } label: {
                        HStack {
                            Image(systemName: alignmentSelection.contains(summary.index) ? "checkmark.square.fill" : "cube.fill")
                                .foregroundStyle(alignmentSelection.contains(summary.index) ? Color.accentColor : (selectedIndex == summary.index ? Color.accentColor : Color.secondary))
                            Text(summary.displayName)
                                .lineLimit(1)
                                .font(.caption)
                        }
                        .contentShape(Rectangle())
                        .padding(4)
                        .background(selectedIndex == summary.index ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Click to select. ⌘-click to add/remove from the Align/Distribute selection below.")
                }
            }
        } label: {
            Text("Objects (\(renderer?.objectCount ?? 0))").font(.headline)
        }
    }

    private func select(_ index: Int) {
        selectedIndex = index
        renderer?.select(index: index)
        refreshTransformFields()
    }

    /// "Esc to Deselect": clears the current selection the same way
    /// clicking empty viewport space already can, just reachable without
    /// aiming the mouse, also cancels an armed placement (same as its own
    /// Cancel button) and the Align/Distribute pick set, since both read as
    /// "something in progress" a user reaching for Escape most likely wants
    /// cleared too.
    private func deselectAll() {
        selectedIndex = nil
        renderer?.select(index: nil)
        alignmentSelection.removeAll()
        cancelArmedPlacement()
        cancelAIPathEndpointPick()
    }

    /// Clears whichever placement is currently armed, object or scenery,
    /// only one is ever active at once (arming either one clears the
    /// other; see the two `onArm`-style call sites), both the `@State`
    /// mirror and the renderer's own real pending field, matching
    /// `armedPlacement`'s existing single-kind clearing this generalizes.
    private func cancelArmedPlacement() {
        if armedPlacement != nil {
            armedPlacement = nil
            renderer?.pendingPlacementObjectID = nil
        }
        if armedScenery != nil {
            armedScenery = nil
            renderer?.pendingPlacementScenery = nil
        }
        if armedPropSkin {
            armedPropSkin = false
            renderer?.pendingPlacementPropSkin = nil
        }
    }

    /// "AI Path Connector Visualization + In-Viewport Endpoint Picking":
    /// arms the click-to-pick overlay for one path's Start or End , 
    /// clearing any placement/scenery arm first, since only one "click the
    /// viewport to do something" mode makes sense active at once.
    private func armAIPathEndpointPick(pathID: UInt32, isNew: Bool, isStart: Bool) {
        cancelArmedPlacement()
        pendingAIPathPick = (pathID, isNew, isStart)
        renderer?.pendingAIPathEndpointPick = true
    }

    private func cancelAIPathEndpointPick() {
        if pendingAIPathPick != nil {
            pendingAIPathPick = nil
            renderer?.pendingAIPathEndpointPick = false
        }
    }

    /// Applies a viewport-picked waypoint ID into whichever path/slot
    /// `pendingAIPathPick` named, then clears the armed state, same
    /// "one click, done" contract as `onObjectPlaced`. `UInt16(exactly:)`
    /// rather than a forced cast: `AIPath.args` are `UInt16`, and while
    /// every real waypoint ID seen in practice fits, a picked `UInt32` ID
    /// that somehow didn't would silently corrupt an unrelated arg slot
    /// via truncation instead of just declining the pick.
    private func applyPickedAIPathEndpoint(_ pickedID: UInt32) {
        guard let pending = pendingAIPathPick, let renderer, let value = UInt16(exactly: pickedID) else { return }
        guard let previousArgs = renderer.currentAIPathArgs(id: pending.pathID) else {
            cancelAIPathEndpointPick()
            return
        }
        var newArgs = previousArgs
        while newArgs.count < 2 { newArgs.append(0) }
        newArgs[pending.isStart ? 0 : 1] = value
        if pending.isNew {
            renderer.settingNewAIPathArgs(id: pending.pathID, args: newArgs)
        } else {
            renderer.settingAIPathArgs(id: pending.pathID, args: newArgs)
        }
        if let undoManager, previousArgs != newArgs {
            undoManager.setActionName("Set AI Path \(pending.isStart ? "Start" : "End")")
            Self.registerAIPathArgUndo(undoManager: undoManager, renderer: renderer, pathID: pending.pathID, isNew: pending.isNew, restoreTo: previousArgs, thenRedoTo: newArgs)
        }
        cancelAIPathEndpointPick()
    }

    private static func registerAIPathArgUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, pathID: UInt32, isNew: Bool, restoreTo: [UInt16], thenRedoTo: [UInt16]) {
        undoManager.registerUndo(withTarget: renderer) { target in
            if isNew {
                target.settingNewAIPathArgs(id: pathID, args: restoreTo)
            } else {
                target.settingAIPathArgs(id: pathID, args: restoreTo)
            }
            registerAIPathArgUndo(undoManager: undoManager, renderer: target, pathID: pathID, isNew: isNew, restoreTo: thenRedoTo, thenRedoTo: restoreTo)
        }
    }

    private func toggleAlignmentSelection(_ index: Int) {
        if alignmentSelection.contains(index) {
            alignmentSelection.remove(index)
        } else {
            alignmentSelection.insert(index)
        }
    }

    /// "Align & Distribute": only shown once ⌘-click has picked at least
    /// two objects, with fewer than two there's nothing for either tool
    /// to do (`SpatialAlignmentTool.align`/`distribute` both no-op on a
    /// single item). Currently-eligible count (Instance/Actor layer only , 
    /// see `applyAlignmentBatch`'s own doc comment for why) is shown
    /// alongside the raw picked count so ⌘-clicking a Trigger/Camera by
    /// mistake reads as "picked but not eligible," not silently ignored.
    @ViewBuilder
    private var alignDistributeControls: some View {
        if !alignmentSelection.isEmpty {
            let eligibleCount = eligibleAlignmentTargets().count
            HStack {
                Text("\(alignmentSelection.count) picked (\(eligibleCount) eligible)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu("Align") {
                    ForEach(SpatialAlignmentTool.Axis.allCases, id: \.self) { axis in
                        Menu(axisLabel(axis)) {
                            ForEach(SpatialAlignmentTool.AlignMode.allCases, id: \.self) { mode in
                                Button(alignModeLabel(mode)) { applyAlignment(axis: axis, mode: mode) }
                            }
                        }
                    }
                }
                .disabled(eligibleCount < 2)
                Menu("Distribute") {
                    ForEach(SpatialAlignmentTool.Axis.allCases, id: \.self) { axis in
                        Button(axisLabel(axis)) { applyDistribution(axis: axis) }
                    }
                }
                .disabled(eligibleCount < 2)
                Button {
                    showingBatchScript = true
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Run Batch Script")
                .help("Runs a move/rotate/scale script against every picked object at once.")
                Button(role: .destructive) {
                    batchDeleteAlignmentSelection()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete Picked Objects")
                .help("Delete every picked object (\(alignmentSelection.count)) at once, one Undo step for the whole batch.")
                Button {
                    alignmentSelection.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Selection")
                .help("Clear the Align/Distribute selection.")
            }
            .menuStyle(.button)
            .controlSize(.small)
        }
    }

    private func axisLabel(_ axis: SpatialAlignmentTool.Axis) -> String {
        switch axis {
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        }
    }

    private func alignModeLabel(_ mode: SpatialAlignmentTool.AlignMode) -> String {
        switch mode {
        case .min: return "Min"
        case .max: return "Max"
        case .center: return "Center"
        }
    }

    /// Only `.actors` (Instance) objects, the one layer with a confirmed
    /// live write-back path all the way to disk (`LevelViewerRenderer.
    /// pendingLevelOverrides` -> `WorldPlacementWriter.writeInstanceTransform`
    /// -> "Save Chunk Overrides…"/"Quick Launch…"). Triggers/Cameras have
    /// their own separate, inspector-driven position save
    /// (`TriggerInspectorView`/`CameraInspectorView`'s own "Save Edited
    /// Copy…") that doesn't read from this renderer's live `worldPosition`
    /// list, so folding them into this batch edit would move them on
    /// screen without persisting it, same reasoning
    /// `pendingLevelOverrides`'s own doc comment already gives for why it's
    /// `.actors`-only.
    private func eligibleAlignmentTargets() -> [(index: Int, position: SIMD3<Float>)] {
        guard let renderer else { return [] }
        let summaries = renderer.objectSummaries
        return alignmentSelection.sorted().compactMap { index in
            guard summaries.indices.contains(index), summaries[index].layer == .actors else { return nil }
            return (index: index, position: summaries[index].worldPosition)
        }
    }

    private func applyAlignment(axis: SpatialAlignmentTool.Axis, mode: SpatialAlignmentTool.AlignMode) {
        applyAlignmentBatch(actionName: "Align") { SpatialAlignmentTool.align($0, axis: axis, mode: mode) }
    }

    private func applyDistribution(axis: SpatialAlignmentTool.Axis) {
        applyAlignmentBatch(actionName: "Distribute") { SpatialAlignmentTool.distribute($0, axis: axis) }
    }

    /// Shared apply path for both Align and Distribute: reads every
    /// eligible picked object's current position, runs `compute` (the pure
    /// `SpatialAlignmentTool` call), writes the results back through
    /// `LevelViewerRenderer.setPositions` (the same "nothing hits disk
    /// until Save" live-edit path a gizmo drag or nudge-field edit already
    /// uses), and registers one recursive undo/redo step, same shape as
    /// `registerTransformUndo`, just batched over several indices instead
    /// of one.
    private func applyAlignmentBatch(actionName: String, _ compute: ([SIMD3<Float>]) -> [SIMD3<Float>]) {
        guard let renderer, let undoManager else { return }
        let targets = eligibleAlignmentTargets()
        guard targets.count >= 2 else { return }
        let before = targets.map { (index: $0.index, position: $0.position) }
        let newPositions = compute(targets.map(\.position))
        let after = zip(targets, newPositions).map { (index: $0.0.index, position: $0.1) }
        renderer.setPositions(after)
        undoManager.setActionName(actionName)
        Self.registerAlignmentUndo(undoManager: undoManager, renderer: renderer, restoreTo: before, thenRedoTo: after)
        refreshTransformFields()
    }

    private static func registerAlignmentUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, restoreTo: [(index: Int, position: SIMD3<Float>)], thenRedoTo: [(index: Int, position: SIMD3<Float>)]) {
        undoManager.registerUndo(withTarget: renderer) { target in
            target.setPositions(restoreTo)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                redoTarget.setPositions(thenRedoTo)
                registerAlignmentUndo(undoManager: undoManager, renderer: redoTarget, restoreTo: restoreTo, thenRedoTo: thenRedoTo)
            }
        }
    }

    /// "Batch Editing, Scripting": runs `renderer.applyBatchScript` over
    /// every currently-picked object (`alignmentSelection`, the same set
    /// "Select All Matching"/Batch Delete/Align/Distribute already share)
    /// and registers one recursive undo/redo step for the whole run, same
    /// shape as `applyAlignmentBatch`.
    private func applyBatchScript(_ operations: [LevelViewerRenderer.BatchScriptOperation]) {
        guard let renderer, let undoManager, !alignmentSelection.isEmpty, !operations.isEmpty else { return }
        let results = renderer.applyBatchScript(operations, to: alignmentSelection)
        guard !results.isEmpty else { return }
        undoManager.setActionName("Batch Script (\(results.count) Object\(results.count == 1 ? "" : "s"))")
        Self.registerBatchScriptUndo(
            undoManager: undoManager, renderer: renderer,
            restoreTo: results.map { ($0.index, $0.before) },
            thenRedoTo: results.map { ($0.index, $0.after) }
        )
        refreshTransformFields()
        workspace.statusMessage = "Applied batch script to \(results.count) object(s)."
    }

    private static func registerBatchScriptUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, restoreTo: [(index: Int, transform: LevelViewerRenderer.ObjectTransform)], thenRedoTo: [(index: Int, transform: LevelViewerRenderer.ObjectTransform)]) {
        undoManager.registerUndo(withTarget: renderer) { target in
            target.setTransforms(restoreTo)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                redoTarget.setTransforms(thenRedoTo)
                registerBatchScriptUndo(undoManager: undoManager, renderer: redoTarget, restoreTo: restoreTo, thenRedoTo: thenRedoTo)
            }
        }
    }

    private func currentSnapshot() -> TransformSnapshot? {
        guard let renderer,
              let position = renderer.selectedPosition,
              let rotationDegrees = renderer.selectedRotationDegrees,
              let scale = renderer.selectedScale
        else { return nil }
        return TransformSnapshot(position: position, rotationDegrees: rotationDegrees, scale: scale)
    }

    private func refreshTransformFields() {
        guard let snapshot = currentSnapshot() else { return }
        positionX = String(format: "%.2f", snapshot.position.x)
        positionY = String(format: "%.2f", snapshot.position.y)
        positionZ = String(format: "%.2f", snapshot.position.z)
        rotationX = String(format: "%.1f", snapshot.rotationDegrees.x)
        rotationY = String(format: "%.1f", snapshot.rotationDegrees.y)
        rotationZ = String(format: "%.1f", snapshot.rotationDegrees.z)
        scaleX = String(format: "%.2f", snapshot.scale.x)
        scaleY = String(format: "%.2f", snapshot.scale.y)
        scaleZ = String(format: "%.2f", snapshot.scale.z)
    }

    private func applyPositionFields() {
        guard let x = Float(positionX), let y = Float(positionY), let z = Float(positionZ) else { return }
        let before = currentSnapshot()
        renderer?.setSelectedPosition(to: SIMD3(x, y, z))
        registerUndoAndRefreshCollisionOverlay(from: before)
        refreshTransformFields()
    }

    private func applyRotationFields() {
        guard let x = Float(rotationX), let y = Float(rotationY), let z = Float(rotationZ) else { return }
        let before = currentSnapshot()
        renderer?.setSelectedRotation(eulerDegrees: SIMD3(x, y, z))
        registerUndoAndRefreshCollisionOverlay(from: before)
        refreshTransformFields()
    }

    private func applyScaleFields() {
        guard let x = Float(scaleX), let y = Float(scaleY), let z = Float(scaleZ) else { return }
        let before = currentSnapshot()
        renderer?.setSelectedScale(to: SIMD3(x, y, z))
        registerUndoAndRefreshCollisionOverlay(from: before)
        refreshTransformFields()
    }

    /// "Direct .RM2 Write-Back": collects every Instance marker's current
    /// transform (`LevelViewerRenderer.pendingLevelOverrides`, already
    /// encoded, already paired with its owning `ChunkNode`) and patches all
    /// of them into one copy of the level's file bytes, so moving several
    /// objects and saving once produces one consistent file. Scenery
    /// placements aren't included, they still have no write path (see this
    /// file's own top-level doc comment).
    /// A node this level's file-scoped operations (`canSaveEdits`,
    /// `originalFileName`) can anchor off of, any node in the same file
    /// works identically for those, since they only use it to find the
    /// enclosing file root. Prefers an Instance marker (the common case),
    /// falling back to a Trigger/Camera so "Save Level Overrides…" is
    /// still reachable for a level with new Forge Palette placements but
    /// no pre-existing Instance records of its own.
    private var referenceNodeForFileOps: ChunkNode? {
        context.instanceMarkers.first?.node ?? context.triggers.first?.node ?? context.cameras.first?.node
    }

    /// "Real AI/Combat Behavior for Forge-Placed Objects": the first real
    /// (non `-1`) `scriptID` this level's own already-real Instance records
    /// carry, per `objectID`, same "borrow this level's own real per-type
    /// value instead of one hardcoded guess" reasoning `instanceTemplatePropertiesByObjectID`
    /// already establishes for `flags`. A fresh placement of an object type
    /// that already has a working AI script elsewhere in this level starts
    /// with that same script attached instead of none at all. Not
    /// `private`: `SpawnAndDeleteTests`-style regression tests call this
    /// directly, same reasoning as `computingPendingOverridePatch`'s own
    /// non-`private` visibility below.
    static func instanceScriptIDByObjectID(fromInstanceMarkers instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)]) -> [UInt16: Int16] {
        var result: [UInt16: Int16] = [:]
        for marker in instanceMarkers where marker.instance.scriptID != -1 {
            if result[marker.instance.objectID] == nil {
                result[marker.instance.objectID] = marker.instance.scriptID
            }
        }
        return result
    }

    /// "Backend Requirement: safely inject this new record" (Part 4D) , 
    /// one save now covers both existing-object transform edits
    /// (`pendingLevelOverrides`, unchanged) and brand-new Forge Palette
    /// placements (`pendingNewInstances`, encoded here via
    /// `WorldPlacementWriter.writeNewInstance` and structurally inserted
    /// by `ChunkSectionInserter`) in one combined file write.
    /// The shared computation behind both "Save Chunk Overrides…" and
    /// "Quick Launch…", every pending transform/insertion/deletion this
    /// session has made to `referenceNodeForFileOps`'s own file, patched
    /// into real bytes. `nil` when there's nothing pending at all, so both
    /// call sites can tell "no edits" apart from "patch failed."
    private func computingPendingOverridePatch() -> (referenceNode: ChunkNode, patch: WorkspaceViewModel.LevelOverridePatch, summary: String)? {
        guard let renderer, let referenceNode = referenceNodeForFileOps else { return nil }
        return Self.computingPendingOverridePatch(renderer: renderer, referenceNode: referenceNode, sceneryFileNode: context.sceneryNode, collisionMeshes: context.collisionMeshes, workspace: workspace)
    }

    /// `self`-free core of `computingPendingOverridePatch()` above, factored
    /// out so the quit-time autosave path (`WorkspaceViewModel.
    /// currentLevelViewerPendingPatchProvider`, wired in the `.task` below , 
    /// moved there from `.onAppear` when renderer construction went async)
    /// can compute the exact same real patch this window's own "Save Chunk
    /// Overrides…"/"Quick Launch…" buttons would, from only a weakly-held
    /// `renderer`/`workspace` and a plain `ChunkNode`, never a captured
    /// reference to this (transient, struct) View itself.
    /// Computes the rebuilt `ColData` record for this session's newly-
    /// placed and deleted objects, see `LevelCollisionRebuilder`'s own
    /// doc comment for the real bug this fixes ("Auto-Update Collision on
    /// Add/Delete") and exactly what the add/remove halves can and can't
    /// guarantee. `nil` means "nothing to rebuild" (no session-placed/
    /// deleted object has any collision data, or this level has no
    /// existing `ColData` record to rebuild into at all), not an error,
    /// just nothing pending, same contract every other `pending...`-style
    /// check in this file already follows.
    /// Not `private`: `SpawnAndDeleteTests`/`LevelCollisionRebuilderTests`-
    /// style regression tests call this directly, same reasoning as
    /// `computingPendingOverridePatch`'s own non-`private` visibility just
    /// below (its own doc comment: lets a test compute the exact real
    /// result without needing this transient View's full body/environment).
    /// Shared by every collision-rebuild path below (the incremental new/
    /// moved-object loops in `computingRebuiltCollisionRecord`, and the
    /// whole-level/single-object full-rebuild paths further down), the
    /// same math, generalized to take an explicit transform so a moved
    /// object's *original* transform can compute a removal box the same
    /// way its *current* one computes an addition box.
    /// Real, reported bug (rebuilt collision renders as a mirror image of
    /// the actual scenery, both in the Level Viewer's own overlay and in
    /// real PCSX2): `GPULevelObject.worldPosition` and every scenery mesh's
    /// own vertex positions are already in this editor's *mirrored display*
    /// space, `ModelParser.decodeSubModel` bakes a world-space X negation
    /// into every parsed vertex, and `SceneryModelPlacement.worldTransform`
    /// negates the raw placement's own X (`-row3.x`), matching the
    /// reference tool's `LoadSceneryModel`/`LoadColTree` doc comment
    /// (`CollisionViewerWindow`'s own upload path negates `CollisionMesh
    /// .vertices` X *at render time*, specifically because the real,
    /// on-disk `ColData` format stores raw, *unmirrored* coordinates).
    /// Empirically confirmed against this game's own real `beach.rm2`:
    /// checking 200 real scenery placements against real, already-on-disk
    /// collision density, the raw (un-mirrored) position matched real
    /// collision 173 times to the mirrored position's 27, with distances
    /// like 0.6 real units (raw) vs. 35+ units (mirrored) from the nearest
    /// real collision triangle. `worldBoxes`/`worldMeshTriangles` below
    /// compute in the same mirrored display space every other geometry
    /// calculation in this renderer uses (matching what's actually drawn
    /// on screen), this undoes that mirror at the last possible moment,
    /// right before a world-space point becomes real `CollisionMesh`
    /// data, so what gets written matches the format's own real
    /// convention instead of silently mismatching every pre-existing
    /// collision triangle already in the file.
    private static func rawColDataPosition(fromDisplay p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(-p.x, p.y, p.z)
    }

    private static func worldBoxes(_ collisionData: [GraphicsInfoCollisionData], position: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) -> [(min: SIMD3<Float>, max: SIMD3<Float>)] {
        collisionData.compactMap { entry in
            let worldPositions = entry.positions.map { localPos -> SIMD3<Float> in
                let scaledPos = SIMD3<Float>(localPos.x, localPos.y, localPos.z) * scale
                let rotatedPos = rotation.act(scaledPos)
                return Self.rawColDataPosition(fromDisplay: rotatedPos + position)
            }
            guard var minP = worldPositions.first else { return nil }
            var maxP = minP
            for p in worldPositions.dropFirst() { minP = simd_min(minP, p); maxP = simd_max(maxP, p) }
            return (minP, maxP)
        }
    }

    /// Real, world-space triangles of `object`'s own actual render mesh , 
    /// not a box or hull approximation. Reads straight from the exact data
    /// already driving the frame: `GPUSubmesh.bindVertices` (bind-space
    /// vertex positions, retained on the CPU side alongside the GPU
    /// buffers, see that field's own doc comment) transformed by this
    /// object's current world position/rotation/scale, connected by the
    /// index buffer's own real triangle-list winding (uploaded as a flat
    /// `UInt32` triple per triangle, see `ModelViewerRenderer.
    /// buildGPUSubmeshes`). This is why "Rebuild All Collision" can finally
    /// hug an object's actual silhouette (confirmed against real in-game
    /// collision-debug renders) instead of a fixed-shape box: it uses the
    /// same low-poly geometry the PS2 already renders, so there's no
    /// separate "collision budget" being spent at all.
    private static func worldMeshTriangles(for object: GPULevelObject) -> [LevelCollisionRebuilder.MeshTriangle] {
        var triangles: [LevelCollisionRebuilder.MeshTriangle] = []
        for submesh in object.submeshes {
            guard !submesh.excludeFromCollision else { continue }
            guard !submesh.bindVertices.isEmpty, submesh.indexCount >= 3 else { continue }
            let worldPositions = submesh.bindVertices.map { v -> SIMD3<Float> in
                let scaledPos = v.position * object.scale
                let rotatedPos = object.rotation.act(scaledPos)
                return Self.rawColDataPosition(fromDisplay: rotatedPos + object.worldPosition)
            }
            let indexPointer = submesh.indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
            var i = 0
            while i + 3 <= submesh.indexCount {
                let ia = Int(indexPointer[i]), ib = Int(indexPointer[i + 1]), ic = Int(indexPointer[i + 2])
                if worldPositions.indices.contains(ia), worldPositions.indices.contains(ib), worldPositions.indices.contains(ic) {
                    triangles.append(LevelCollisionRebuilder.MeshTriangle(v0: worldPositions[ia], v1: worldPositions[ib], v2: worldPositions[ic]))
                }
                i += 3
            }
        }
        // Real, requested trade-off: "extremely accurate collision but
        // with way less verts and triangles", grid-snap decimation
        // (`CollisionMeshDecimator`) welds vertices at a resolution scaled
        // to this object's own real-world size, so a tiny prop barely
        // changes while a large object's redundant/seam-duplicated
        // vertices collapse together. This also directly shrinks the real
        // crash risk `fullyRebuildingCollisionMesh`'s own doc comment
        // describes (this format's 18-bit-per-index vertex limit) by
        // cutting vertex count at the source, before any merging happens.
        let worldExtent = (object.localBoundsMax - object.localBoundsMin) * object.scale
        let cellSize = CollisionMeshDecimator.adaptiveCellSize(localMin: .zero, localMax: worldExtent)
        return CollisionMeshDecimator.decimating(triangles, cellSize: cellSize)
    }

    /// Groups `bounds` (each entry's own world-space AABB) into connected
    /// clusters by touch/overlap, real union-find over the touch graph,
    /// so a *chain* of touching entries (A touches B, B touches C) all end
    /// up in the same cluster even where A and C don't directly touch, not
    /// just directly-adjacent pairs. Returns each cluster as the list of
    /// original indices it contains. `O(n^2)` pair checks plus near-linear
    /// union-find, fine at real per-level scale (a few hundred scenery
    /// objects; verified against a real, 462-object level).
    private static func clusteringTouchingIndices(_ bounds: [(min: SIMD3<Float>, max: SIMD3<Float>)], epsilon: Float = 0.05) -> [[Int]] {
        guard bounds.count > 1 else { return bounds.indices.map { [$0] } }
        var parent = Array(0..<bounds.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        func overlaps1D(_ aMin: Float, _ aMax: Float, _ bMin: Float, _ bMax: Float) -> Bool {
            aMin - epsilon <= bMax && bMin - epsilon <= aMax
        }
        func touches(_ a: (min: SIMD3<Float>, max: SIMD3<Float>), _ b: (min: SIMD3<Float>, max: SIMD3<Float>)) -> Bool {
            overlaps1D(a.min.x, a.max.x, b.min.x, b.max.x)
                && overlaps1D(a.min.y, a.max.y, b.min.y, b.max.y)
                && overlaps1D(a.min.z, a.max.z, b.min.z, b.max.z)
        }
        for i in 0..<bounds.count {
            for j in (i + 1)..<bounds.count where touches(bounds[i], bounds[j]) {
                union(i, j)
            }
        }
        var indicesByRoot: [Int: [Int]] = [:]
        for i in 0..<bounds.count { indicesByRoot[find(i), default: []].append(i) }
        return Array(indicesByRoot.values)
    }

    /// "Rebuild All Collision", pure computation shared by
    /// `computingFullyRebuiltCollisionRecord` (which encodes the result for
    /// a save) and `LevelViewerWindow`'s own post-save overlay refresh
    /// (which needs the raw `CollisionMesh`, not encoded bytes, to hand to
    /// `LevelViewerRenderer.refreshingCollisionFillBuffer`). Uses one real
    /// mesh-triangle set per scenery object currently in the level
    /// (`SceneLayer.scenery`, every placement, not only session-placed/
    /// moved ones), see `worldMeshTriangles`, keeping the original
    /// mesh's own most-common `surfaceID` (the same data-driven "what
    /// counts as ordinary solid ground here" proxy every other collision-
    /// rebuild path in this file already uses) before destroying it. `nil`
    /// when there are no scenery objects with any real geometry to build
    /// from at all.
    private static func fullyRebuildingCollisionMesh(renderer: LevelViewerRenderer, baseline: CollisionMesh) -> (mesh: CollisionMesh, objectCount: Int, triangleCount: Int, mergedGroupCount: Int, splitClusterCount: Int, surfaceChoice: LevelCollisionRebuilder.SurfaceChoice)? {
        struct PerObject { let bounds: (min: SIMD3<Float>, max: SIMD3<Float>); let triangles: [LevelCollisionRebuilder.MeshTriangle] }
        var perObject: [PerObject] = []
        for object in renderer.levelObjects where object.layer == .scenery {
            let triangles = Self.worldMeshTriangles(for: object)
            guard var minP = triangles.first?.v0 else { continue }
            var maxP = minP
            for t in triangles {
                for p in [t.v0, t.v1, t.v2] { minP = simd_min(minP, p); maxP = simd_max(maxP, p) }
            }
            perObject.append(PerObject(bounds: (minP, maxP), triangles: triangles))
        }
        guard !perObject.isEmpty else { return nil }

        // Real, requested behavior: "most scenery in a level is one
        // object... the collision for scenery touching each other should
        // be one object. It should only have its own collision if you
        // build it separately or it's not connected to anything." Clusters
        // every object that touches/overlaps another (transitively, a
        // chain of touching objects all end up in the same cluster, not
        // just directly-adjacent pairs) into one combined `CollisionGroup`
        // carrying every clustered object's own real triangles; a
        // genuinely isolated object keeps its own group. Deliberately
        // *not* applied to the per-object rebuild path
        // (`computingSingleObjectRebuiltCollisionRecord`), using that
        // specific action is "building it separately," which the same
        // real request says must keep its own collision regardless of
        // what it's touching.
        // Real, reported bug (crash on save): the on-disk `ColData` format
        // packs each triangle's 3 vertex indices into 18 bits apiece
        // (`ColDataWriter.write`'s own `& 0x3FFFF` masking, max index
        // 262,143). Transitive touch-merging has no natural size limit: a
        // real, dense level's scenery can chain-merge into one connected
        // "super-cluster" spanning hundreds of objects (a ground-hugging
        // rock pad touching its neighbor touching *its* neighbor...), and
        // a single measured 460-object stress case already produced one
        // 69,000-vertex group well on the way to that ceiling. Past it,
        // vertex indices silently wrap instead of failing loudly , 
        // corrupted triangles pointing at the wrong geometry, exactly the
        // kind of malformed collision data that would crash the game (or
        // this app re-reading its own output) rather than just look wrong.
        // `maxVerticesPerMergedGroup` is deliberately far below the hard
        // 262,143 ceiling, a merged group anywhere near that size is
        // already unlike anything the original, hand-authored levels ever
        // had in one `CollisionGroup`, so a cluster that would cross it
        // falls back to one group per object instead of one giant (and
        // likely corrupt) combined group. `triangles.count * 3` is a safe
        // upper bound on the vertices `rebuilding(_:addingMeshGroups:)`
        // will actually emit, its own per-group dedup can only make the
        // real count smaller, never larger.
        let clusters = Self.clusteringTouchingIndices(perObject.map(\.bounds))
        let maxVerticesPerMergedGroup = 60_000
        var splitClusterCount = 0
        var meshGroups: [LevelCollisionRebuilder.NewCollisionMeshGroup] = []
        for indices in clusters {
            let triangleCount = indices.reduce(0) { $0 + perObject[$1].triangles.count }
            if indices.count > 1, triangleCount * 3 > maxVerticesPerMergedGroup {
                splitClusterCount += 1
                for index in indices {
                    meshGroups.append(LevelCollisionRebuilder.NewCollisionMeshGroup(triangles: perObject[index].triangles))
                }
            } else {
                meshGroups.append(LevelCollisionRebuilder.NewCollisionMeshGroup(triangles: indices.flatMap { perObject[$0].triangles }))
            }
        }

        let surfaceChoice = LevelCollisionRebuilder.dominantSolidSurfaceChoice(in: baseline)

        let rebuilt = LevelCollisionRebuilder.rebuildingFromScratch(preservingIDFrom: baseline, addingMeshGroups: meshGroups, surfaceID: surfaceChoice.surfaceID)
        let totalTriangleCount = perObject.reduce(0) { $0 + $1.triangles.count }
        return (rebuilt, perObject.count, totalTriangleCount, meshGroups.count, splitClusterCount, surfaceChoice)
    }

    /// "Rebuild All Collision", the save-path half: encodes
    /// `fullyRebuildingCollisionMesh`'s result the same way every other
    /// collision record in this file gets encoded (`ColDataWriter.write`),
    /// paired with the real node its bytes patch into.
    static func computingFullyRebuiltCollisionRecord(renderer: LevelViewerRenderer, collisionMeshes: [(node: ChunkNode, mesh: CollisionMesh)]) -> (node: ChunkNode, encoded: Data, summary: String)? {
        guard let (collisionNode, collisionMesh) = collisionMeshes.first else { return nil }
        guard let (rebuilt, objectCount, triangleCount, mergedGroupCount, splitClusterCount, surfaceChoice) = fullyRebuildingCollisionMesh(renderer: renderer, baseline: collisionMesh) else { return nil }
        let encoded = ColDataWriter.write(rebuilt)
        var summary = "collision mesh completely rebuilt from each object's own real geometry (\(objectCount) scenery object(s), \(triangleCount) source triangle(s), \(mergedGroupCount) final collision group(s) after merging touching objects)"
        if splitClusterCount > 0 {
            summary += ", \(splitClusterCount) touching cluster(s) were too large to safely merge (past this format's own per-group vertex limit) and were kept as separate per-object groups instead"
        }
        summary += ", using surface \(surfaceChoice.surfaceID) (\(surfaceChoice.triangleCount) tris, \(sizeDescription(surfaceChoice.size)))"
        if surfaceChoice.mightBeAHazardSurface {
            summary += " ⚠️ this surface looks like a large flat plane (this app can't reliably tell water/hazard surfaces apart from a legitimate flat floor from this data alone, double-check before saving)"
        }
        return (collisionNode, encoded, summary)
    }

    /// "%.0f×%.1f×%.0f units", a plain, real dimension readout for the
    /// surface-choice warning above, not a claim about what the surface
    /// actually is.
    private static func sizeDescription(_ size: SIMD3<Float>) -> String {
        String(format: "%.0f×%.1f×%.0f units", size.x, size.y, size.z)
    }

    /// "Rebuild Collision for This Object", the per-object counterpart to
    /// `computingFullyRebuiltCollisionRecord`: destroys and regenerates
    /// collision scoped to just one object, reusing the exact same
    /// incremental primitives `computingRebuiltCollisionRecord`'s own
    /// moved-object path already relies on (`removingGroupsNear` +
    /// `rebuilding`) rather than the whole-level from-scratch path, since a
    /// single object's own current world box is real, precise removal
    /// input here, not the approximation those functions' doc comments
    /// warn "moved" collision removal already has to be. Works correctly
    /// whether `object` is an existing, never-moved on-disk placement
    /// (removes whatever collision group already sits at its own current
    /// position, adds a fresh one) or a session-placed object with no
    /// existing collision at all (`removingGroupsNear` simply finds nothing
    /// to remove, same as it would for a genuinely empty removal target).
    static func computingSingleObjectRebuiltCollisionRecord(renderer: LevelViewerRenderer, objectIndex: Int, collisionMeshes: [(node: ChunkNode, mesh: CollisionMesh)]) -> (node: ChunkNode, encoded: Data, summary: String)? {
        guard let (collisionNode, _) = collisionMeshes.first else { return nil }
        guard let (rebuilt, removedGroupCount, newTriangleCount, displayName, surfaceChoice) = singleObjectRebuiltCollisionMesh(renderer: renderer, objectIndex: objectIndex, collisionMeshes: collisionMeshes) else { return nil }
        let encoded = ColDataWriter.write(rebuilt)
        var summary = "collision rebuilt for \(displayName) from its own real geometry (\(removedGroupCount) old group(s) removed, \(newTriangleCount) source triangle(s) added), using surface \(surfaceChoice.surfaceID) (\(surfaceChoice.triangleCount) tris, \(sizeDescription(surfaceChoice.size)))"
        if surfaceChoice.mightBeAHazardSurface {
            summary += " ⚠️ this surface looks like a large flat plane (this app can't reliably tell water/hazard surfaces apart from a legitimate flat floor from this data alone, double-check before saving)"
        }
        return (collisionNode, encoded, summary)
    }

    /// Pure computation behind `computingSingleObjectRebuiltCollisionRecord`
    /// above, factored out the same way `fullyRebuildingCollisionMesh` is,
    /// so the post-save overlay refresh can get the raw `CollisionMesh`
    /// without re-decoding the just-written encoded bytes.
    private static func singleObjectRebuiltCollisionMesh(renderer: LevelViewerRenderer, objectIndex: Int, collisionMeshes: [(node: ChunkNode, mesh: CollisionMesh)]) -> (mesh: CollisionMesh, removedGroupCount: Int, newTriangleCount: Int, displayName: String, surfaceChoice: LevelCollisionRebuilder.SurfaceChoice)? {
        guard renderer.levelObjects.indices.contains(objectIndex) else { return nil }
        let object = renderer.levelObjects[objectIndex]
        guard object.layer == .scenery else { return nil }
        let triangles = Self.worldMeshTriangles(for: object)
        guard var minP = triangles.first?.v0 else { return nil }
        var maxP = minP
        for t in triangles {
            for p in [t.v0, t.v1, t.v2] { minP = simd_min(minP, p); maxP = simd_max(maxP, p) }
        }
        guard let (_, collisionMesh) = collisionMeshes.first else { return nil }

        let removalBoxes = [LevelCollisionRebuilder.RemovalBox(worldMin: minP, worldMax: maxP)]
        let meshGroups = [LevelCollisionRebuilder.NewCollisionMeshGroup(triangles: triangles)]

        let surfaceChoice = LevelCollisionRebuilder.dominantSolidSurfaceChoice(in: collisionMesh)

        let (afterRemoval, removedGroupCount) = LevelCollisionRebuilder.removingGroupsNear(collisionMesh, boxes: removalBoxes)
        let rebuilt = LevelCollisionRebuilder.rebuilding(afterRemoval, addingMeshGroups: meshGroups, surfaceID: surfaceChoice.surfaceID)
        return (rebuilt, removedGroupCount, triangles.count, object.displayName, surfaceChoice)
    }

    static func computingRebuiltCollisionRecord(renderer: LevelViewerRenderer, collisionMeshes: [(node: ChunkNode, mesh: CollisionMesh)]) -> (node: ChunkNode, encoded: Data, summary: String)? {
        // "Rebuild All Collision"/"Rebuild Collision for This Object" , 
        // both are a fundamentally different operation from the
        // incremental new/moved-object logic below (destroy-and-rebuild,
        // not additive patching), so both short-circuit here rather than
        // threading their own state through the incremental loops.
        if let objectIndex = renderer.rebuildCollisionRequestedForObjectIndex {
            return computingSingleObjectRebuiltCollisionRecord(renderer: renderer, objectIndex: objectIndex, collisionMeshes: collisionMeshes)
        }
        if renderer.rebuildAllCollisionRequested {
            return computingFullyRebuiltCollisionRecord(renderer: renderer, collisionMeshes: collisionMeshes)
        }

        // Real, reported bug: this used to also fire for a freshly-placed
        // Forge `Instance` (`object.newInstanceObjectID != nil`), baking it
        // straight into the level's *static* collision mesh, wrong the
        // same way `computingFullyRebuiltCollisionRecord`/
        // `computingSingleObjectRebuiltCollisionRecord` already guard
        // against below: this format's collision mesh is authored per-level
        // scenery/terrain, not per-entity. A placed character/prop keeps
        // its own real hitbox at runtime (`GI_CollisionData`, resolved by
        // the game itself); folding it into the static mesh too makes it
        // permanent, immovable level geometry instead of an ordinary
        // dynamic object, not what "add collision for what I just placed"
        // ever meant for a Forge object. Scenery-only, matching every other
        // collision-rebuild path in this file.
        var newBoxes: [LevelCollisionRebuilder.NewCollisionBox] = []
        for object in renderer.levelObjects where object.layer == .scenery {
            guard object.newSceneryModelID != nil else { continue }
            let collisionData = !object.assetCollisionData.isEmpty ? object.assetCollisionData : object.generatedCollisionData
            for box in Self.worldBoxes(collisionData, position: object.worldPosition, rotation: object.rotation, scale: object.scale) {
                newBoxes.append(LevelCollisionRebuilder.NewCollisionBox(worldMin: box.min, worldMax: box.max))
            }
        }
        let removalBoxes: [LevelCollisionRebuilder.RemovalBox] = renderer.pendingCollisionRemovals.map {
            LevelCollisionRebuilder.RemovalBox(worldMin: $0.worldMin, worldMax: $0.worldMax)
        }

        guard !newBoxes.isEmpty || !removalBoxes.isEmpty else { return nil }
        guard let (collisionNode, collisionMesh) = collisionMeshes.first else { return nil }

        // See `LevelCollisionRebuilder.dominantSolidSurfaceID`'s own doc
        // comment: a real, data-driven "whatever counts as ordinary solid
        // ground here" proxy, not an invented ID, and hardened against
        // picking a large flat hazard surface (water) over real terrain.
        let surfaceID = LevelCollisionRebuilder.dominantSolidSurfaceID(in: collisionMesh)

        // Removal runs first, on the real baseline mesh, additions then
        // append fresh groups on top of *that* result, so the two never
        // interfere with each other's own index math.
        let (afterRemoval, removedGroupCount) = LevelCollisionRebuilder.removingGroupsNear(collisionMesh, boxes: removalBoxes)
        let rebuilt = LevelCollisionRebuilder.rebuilding(afterRemoval, addingBoxes: newBoxes, surfaceID: surfaceID)
        let encoded = ColDataWriter.write(rebuilt)

        var summaryParts: [String] = []
        if !newBoxes.isEmpty { summaryParts.append("\(newBoxes.count) new collision box(es)") }
        if removedGroupCount > 0 { summaryParts.append("\(removedGroupCount) collision group(s) removed near deleted objects (best-effort)") }
        return (collisionNode, encoded, summaryParts.joined(separator: ", "))
    }

    static func computingPendingOverridePatch(renderer: LevelViewerRenderer, referenceNode: ChunkNode, sceneryFileNode: ChunkNode?, collisionMeshes: [(node: ChunkNode, mesh: CollisionMesh)], workspace: WorkspaceViewModel) -> (referenceNode: ChunkNode, patch: WorkspaceViewModel.LevelOverridePatch, summary: String)? {
        let edits = renderer.pendingLevelOverrides + renderer.pendingAIWaypointOverrides + renderer.pendingAIPathArgOverrides
        let controlPointEdits = renderer.pendingCameraControlPointOverrides
        let sceneryTransformEdits = renderer.pendingSceneryTransformOverrides
        let newInstances = renderer.pendingNewInstances
        let newAIPositions = renderer.pendingNewAIPositions
        let newTriggers = renderer.pendingNewTriggers
        let newCameras = renderer.pendingNewCameras
        let newAIPaths = renderer.pendingNewAIPaths
        let removedInstanceIDs = renderer.pendingRemovedInstanceIDs
        let removedTriggerIDs = renderer.pendingRemovedTriggerIDs
        let removedCameraIDs = renderer.pendingRemovedCameraIDs
        let removedAIPositionIDs = renderer.pendingRemovedAIPositionIDs
        let removedAIPathIDs = renderer.pendingRemovedAIPathIDs
        let newScenery = renderer.pendingNewScenery
        let removedSceneryOffsets = renderer.pendingRemovedSceneryOffsets
        let crossLevelScenery = renderer.pendingCrossLevelScenery
        let crossLevelGameObjects = renderer.pendingCrossLevelGameObjects
        let propSkinSpawns = renderer.pendingPropSkinSpawns
        let playerCharacterSwap = renderer.pendingPlayerCharacterSwap.flatMap { $0.id == 0 ? nil : $0 }
        // "Auto-Update Collision on Add/Delete" (real, reported bug): this
        // used to be its own disconnected, manual "Rebuild Level
        // Collision…" save, computed the right data, then wrote it to a
        // standalone loose file nothing else ever read, so newly-placed
        // objects still had no real collision the moment the game actually
        // booted. Computing it right here means it's automatically part
        // of *every* save this function already produces (Quick Launch,
        // Save Chunk Overrides, Save In-Place, the quit-time autosave , 
        // every caller of this one function), the same as every other
        // pending edit kind above.
        let collisionRecord = Self.computingRebuiltCollisionRecord(renderer: renderer, collisionMeshes: collisionMeshes)
        guard !edits.isEmpty || !controlPointEdits.isEmpty || !sceneryTransformEdits.isEmpty || !newInstances.isEmpty || !newAIPositions.isEmpty
            || !newTriggers.isEmpty || !newCameras.isEmpty || !newAIPaths.isEmpty || !newScenery.isEmpty
            || !removedInstanceIDs.isEmpty || !removedTriggerIDs.isEmpty || !removedCameraIDs.isEmpty || !removedAIPositionIDs.isEmpty || !removedAIPathIDs.isEmpty
            || !removedSceneryOffsets.isEmpty || !crossLevelScenery.isEmpty || !crossLevelGameObjects.isEmpty || !propSkinSpawns.isEmpty || collisionRecord != nil || playerCharacterSwap != nil
        else { return nil }

        // "Real Flags for Forge-Placed Objects": a real, per-type
        // `InstanceTemplate.properties` value when this level (or the
        // shared `Default.rm2`) has one for `entry.objectID`, confirmed
        // against real disc data to be the exact value CrateModLoader's own
        // working randomizer mods assign into `Instance.Flags` for that
        // object type. `0x188B2E` when no template exists anywhere (true
        // for every non-crate/pickup object ID, real disc data shows
        // `Default.rm2` carries zero enemy/AI templates): the same
        // "object placed at runtime, no template found" fallback
        // `TS_Rand_Enemies.cs`'s own `ModPass` falls back to, not a
        // guess, see `WorldPlacementWriter.writeNewInstance`'s own doc
        // comment for why the old blanket `0x811E` default (a real value,
        // but crate-specific) was never right for every object type.
        let encodedNewInstances = newInstances.map { entry -> (id: UInt32, encoded: Data) in
            let flags = renderer.instanceTemplatePropertiesByObjectID[entry.objectID] ?? 0x188B2E
            // "Real AI/Combat Behavior for Forge-Placed Objects": see
            // `renderer.instanceScriptIDByObjectID`'s own doc comment , 
            // reuses this level's own real scriptID for the same object
            // type when one exists, `-1` (no script) otherwise.
            let scriptID = renderer.instanceScriptIDByObjectID[entry.objectID] ?? -1
            return (id: entry.syntheticID, encoded: WorldPlacementWriter.writeNewInstance(
                objectID: entry.objectID,
                position: SIMD4<Float>(entry.position, 1),
                rotationDegrees: entry.rotationDegrees,
                flags: flags,
                pathIDs: entry.pathIDs,
                scriptID: scriptID
            ))
        }
        AppLog.rendering.debug("[QuickLaunchDiag] newInstances.count=\(newInstances.count, privacy: .public) encodedNewInstances=\(encodedNewInstances.map { "id=\($0.id) bytes=\($0.encoded.count)" }, privacy: .public) referenceNode.displayName=\(referenceNode.displayName, privacy: .public)")
        guard let patchedBytes = workspace.patchedFileBytes(
            applyingPrefixPatches: edits,
            applyingAbsoluteByteRangePatches: controlPointEdits,
            applyingSceneryTransformPatches: sceneryTransformEdits,
            insertingNewInstances: encodedNewInstances,
            insertingNewAIPositions: newAIPositions,
            insertingNewTriggers: newTriggers,
            insertingNewCameras: newCameras,
            insertingNewAIPaths: newAIPaths,
            removingInstanceIDs: removedInstanceIDs,
            removingTriggerIDs: removedTriggerIDs,
            removingCameraIDs: removedCameraIDs,
            removingAIPositionIDs: removedAIPositionIDs,
            removingAIPathIDs: removedAIPathIDs,
            insertingNewScenery: newScenery,
            removingSceneryOffsets: removedSceneryOffsets,
            insertingNewCrossLevelScenery: crossLevelScenery,
            insertingCrossLevelGameObjects: crossLevelGameObjects,
            insertingPropSkinSpawns: propSkinSpawns,
            applyingPlayerCharacterSwap: playerCharacterSwap,
            replacingCollisionRecord: collisionRecord.map { (node: $0.node, encoded: $0.encoded) },
            sceneryFileNode: sceneryFileNode,
            levelNode: referenceNode
        ) else {
            AppLog.rendering.debug("[QuickLaunchDiag] patchedFileBytes returned nil, lastError=\(workspace.lastError ?? "none", privacy: .public)")
            return nil
        }
        AppLog.rendering.debug("[QuickLaunchDiag] patchedFileBytes succeeded, primaryBytes=\(patchedBytes.primaryBytes.count, privacy: .public) sceneryBytes=\(patchedBytes.sceneryBytes?.count ?? -1, privacy: .public) sceneryFileDisplayName=\(patchedBytes.sceneryFileDisplayName ?? "nil", privacy: .public)")

        var parts: [String] = []
        if !edits.isEmpty { parts.append("\(edits.count) transform override(s)") }
        if !controlPointEdits.isEmpty { parts.append("\(controlPointEdits.count) camera control point(s)") }
        if !sceneryTransformEdits.isEmpty { parts.append("\(sceneryTransformEdits.count) scenery object transform(s)") }
        if !newInstances.isEmpty { parts.append("\(newInstances.count) newly placed object(s)") }
        if !newAIPositions.isEmpty { parts.append("\(newAIPositions.count) newly placed waypoint(s)") }
        if !newTriggers.isEmpty { parts.append("\(newTriggers.count) newly placed trigger(s)") }
        if !newCameras.isEmpty { parts.append("\(newCameras.count) newly placed camera(s)") }
        if !newAIPaths.isEmpty { parts.append("\(newAIPaths.count) newly added AI path(s)") }
        if !newScenery.isEmpty { parts.append("\(newScenery.count) newly placed scenery object(s)") }
        if !crossLevelScenery.isEmpty { parts.append("\(crossLevelScenery.count) scenery object(s) borrowed from another level") }
        if !propSkinSpawns.isEmpty { parts.append("\(propSkinSpawns.count) interactive Cortex prop(s)") }
        if !crossLevelGameObjects.isEmpty { parts.append("\(crossLevelGameObjects.count) object type(s)' real data copied in from another level") }
        let removedTotal = removedInstanceIDs.count + removedTriggerIDs.count + removedCameraIDs.count + removedAIPositionIDs.count + removedAIPathIDs.count + removedSceneryOffsets.count
        if removedTotal > 0 { parts.append("\(removedTotal) deleted object(s)") }
        if let collisionRecord, !collisionRecord.summary.isEmpty { parts.append("collision rebuilt: \(collisionRecord.summary)") }
        return (referenceNode, patchedBytes, parts.joined(separator: " and "))
    }

    private func saveLevelOverrides() {
        confirmingDanglingReferences { performSaveLevelOverrides() }
    }

    private func performSaveLevelOverrides() {
        guard let (referenceNode, patch, summary) = computingPendingOverridePatch() else { return }
        // "Pre-Save Diff/Summary", real, requested QoL: this message used
        // to be a static, generic description regardless of what was
        // actually pending, `summary` (the same real, computed string
        // this function already builds and shows *after* saving, in
        // `workspace.statusMessage`) was sitting right here unused. Now
        // the save panel itself previews exactly what's about to be
        // written before the user commits, not just after.
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(workspace.originalFileName(for: referenceNode) ?? "chunk")_edited.rm2",
            message: "Save the edited copy of this file: \(summary). The original file on disk is not modified."
        ) else { return }
        // Scenery almost always lives in a *different* real file (the
        // level's own `.sm2`) than the Instance/Trigger/Camera edits
        // `url` above is for (its `.rm2`), see `WorkspaceViewModel.
        // LevelOverridePatch`'s own doc comment. When there's a pending
        // scenery edit, that second file gets its own sibling loose copy,
        // named the same way but with the scenery file's own real
        // extension, right next to the one the user just chose, one
        // click still saves everything pending, just as two files instead
        // of silently dropping (or erroring out on) the scenery half.
        let sceneryURL = patch.sceneryFileDisplayName.map { name in
            url.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                .appendingPathExtension((name as NSString).pathExtension)
        }
        Task {
            do {
                try await workspace.writeDataAsync(patch.primaryBytes, to: url)
                var savedNames = [url.lastPathComponent]
                if let sceneryBytes = patch.sceneryBytes, let sceneryURL {
                    try await workspace.writeDataAsync(sceneryBytes, to: sceneryURL)
                    savedNames.append(sceneryURL.lastPathComponent)
                }
                workspace.statusMessage = "Saved edited copy to \(savedNames.joined(separator: " and ")) with \(summary). The original file(s) were not modified."
            } catch {
                workspace.lastError = "Save failed: \(error)"
            }
        }
    }

    /// "In-Place Save for Archive-Packed Levels", real, requested missing
    /// feature: "Save Chunk Overrides…" always writes a brand-new loose
    /// copy, even for a level reached by browsing a mounted disc/archive,
    /// so using it meant managing loose edited copies alongside the
    /// original disc image. This writes straight into the mounted disc
    /// image's own bytes instead, reusing `WorkspaceViewModel.
    /// savingPendingLevelViewerEditsToMountedDisc()`, the exact same
    /// independently-re-verified-before-writing save this app's quit-time
    /// "unsaved changes" prompt already uses internally, just now exposed
    /// as a real, explicit, on-demand button instead of only ever firing
    /// during a quit confirmation.
    private func savingInPlaceToDiscImage() {
        guard let patch = workspace.currentLevelViewerPendingPatchProvider?() else {
            workspace.statusMessage = "No pending edits to save."
            return
        }
        let discName = workspace.discImageURL?.lastPathComponent ?? "the mounted disc image"
        pendingInPlaceSaveConfirmation = "This writes \(patch.summary) directly into \(discName)'s own bytes, not a separate copy. The rebuilt image is independently re-verified first; if verification fails, the real disc image is left completely untouched. Continue?"
    }

    /// "Strict Size Guardrails", the one real branch every save path
    /// below shares: every other `LevelViewerQuitSaveOutcome` case is
    /// handled inline at each call site (their success messages genuinely
    /// differ), but a size-threshold confirmation is identical either way , 
    /// the same alert, retried with `allowingLargeGrowth: true` via
    /// whatever `retry` the caller passes (re-running *that same* save).
    /// Real, reported bug: this shared "the disc grew a lot, save anyway?"
    /// alert (`showingSizeThresholdConfirmationIfNeeded`'s own doc comment
    ///, one alert reused by every in-place save path: plain save,
    /// "Rebuild All Collision," and "Rebuild Collision for This Object")
    /// only ever cleared its own generic
    /// `pendingSizeThresholdConfirmation`/`pendingSizeThresholdRetryAction`
    /// state on Cancel/dismiss, it has no idea which specific operation
    /// actually triggered it. A full collision rebuild is exactly the kind
    /// of edit that legitimately crosses this threshold (a whole new,
    /// much bigger `ColData` record), so Cancelling that specific
    /// confirmation left `renderer.rebuildAllCollisionRequested` (or
    /// `rebuildCollisionRequestedForObjectIndex`) stuck `true`/non-`nil`
    /// permanently, with no UI anywhere to reset it, every *later*,
    /// completely unrelated save (including a plain "Quick Launch…")
    /// silently kept recomputing a full, expensive from-scratch collision
    /// rebuild instead of a normal incremental patch
    /// (`computingRebuiltCollisionRecord`'s own short-circuit checks these
    /// flags first, before anything else). Real, reported symptoms this
    /// caused: Quick Launch appearing permanently unresponsive/greyed out,
    /// and other Level Viewer panels behaving strangely, after Cancelling
    /// this dialog even once following a "Rebuild All Collision" attempt.
    /// Called from every path this shared alert can be dismissed by
    /// (Cancel, and the binding's own "any other way" `set`), resetting a
    /// flag that was never actually set is harmless, so this doesn't need
    /// to know which specific operation was in flight.
    private func clearingInFlightSaveRequestFlags() {
        renderer?.rebuildAllCollisionRequested = false
        renderer?.rebuildCollisionRequestedForObjectIndex = nil
    }

    private func showingSizeThresholdConfirmationIfNeeded(_ outcome: WorkspaceViewModel.LevelViewerQuitSaveOutcome, retry: @escaping () -> Void) -> Bool {
        guard case .sizeThresholdExceeded(_, _, let originalSizeBytes, let rebuiltSizeBytes) = outcome else { return false }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let fraction = GameLauncher.sizeGrowthFraction(originalBytes: originalSizeBytes, rebuiltBytes: rebuiltSizeBytes)
        let percentText = String(format: "%+.0f%%", fraction * 100)
        pendingSizeThresholdConfirmation = "The rebuilt image is \(percentText) larger than the original (\(formatter.string(fromByteCount: Int64(originalSizeBytes))) → \(formatter.string(fromByteCount: Int64(rebuiltSizeBytes)))), well past the \(Int(GameLauncher.defaultSizeGrowthWarningThreshold * 100))% guardrail. No small edit should normally cause growth like this. Save anyway?"
        pendingSizeThresholdRetryAction = retry
        return true
    }

    private func performSavingInPlaceToDiscImage() {
        isSavingInPlace = true
        Task {
            defer { isSavingInPlace = false }
            let outcome = await workspace.savingPendingLevelViewerEditsToMountedDisc()
            if showingSizeThresholdConfirmationIfNeeded(outcome, retry: performSavingInPlaceToDiscImageForced) { return }
            switch outcome {
            case .noPendingEdits:
                workspace.statusMessage = "No pending edits to save."
            case .noDiscImageConfigured:
                workspace.lastError = "No disc image is configured, set one in the Game Launcher first."
            case .saved:
                workspace.statusMessage = "Saved in-place to \(workspace.discImageURL?.lastPathComponent ?? "the mounted disc image")."
            case .verificationFailed(let reason):
                workspace.lastError = "Couldn't verify the rebuilt disc image, nothing was written: \(reason)"
            case .writeFailed(_, _, let reason):
                workspace.lastError = "The rebuilt image passed verification, but writing it back to the disc image failed: \(reason)"
            case .sizeThresholdExceeded:
                break // handled above
            }
        }
    }

    /// "Save Anyway" from the size-threshold confirmation above, re-runs
    /// the exact same save, this time allowing the already-verified,
    /// already-shown-to-the-user bytes to actually be written.
    private func performSavingInPlaceToDiscImageForced() {
        isSavingInPlace = true
        Task {
            defer { isSavingInPlace = false }
            let outcome = await workspace.savingPendingLevelViewerEditsToMountedDisc(allowingLargeGrowth: true)
            switch outcome {
            case .noPendingEdits:
                workspace.statusMessage = "No pending edits to save."
            case .noDiscImageConfigured:
                workspace.lastError = "No disc image is configured, set one in the Game Launcher first."
            case .saved:
                workspace.statusMessage = "Saved in-place to \(workspace.discImageURL?.lastPathComponent ?? "the mounted disc image")."
            case .verificationFailed(let reason):
                workspace.lastError = "Couldn't verify the rebuilt disc image, nothing was written: \(reason)"
            case .writeFailed(_, _, let reason):
                workspace.lastError = "The rebuilt image passed verification, but writing it back to the disc image failed: \(reason)"
            case .sizeThresholdExceeded:
                break // `allowingLargeGrowth: true` never returns this case again
            }
        }
    }

    /// Real gap this task's own instructions specifically flagged for
    /// verification: `context.collisionMeshes` (what the "Collision /
    /// Ground Floor" overlay was built from) is a plain `let` on this View
    ///, it never updates after a save, so without this, toggling the
    /// layer back on after a collision rebuild would keep showing the
    /// stale, pre-rebuild mesh even though the disc image itself now has
    /// the new one. Recomputes the exact same rebuilt mesh the save just
    /// wrote (a pure function of `renderer.levelObjects` and the baseline
    /// mesh, both unchanged since the save started) and pushes it straight
    /// into the renderer's own GPU-bound fill buffer, bypassing `context`
    /// entirely rather than requiring a full Level Viewer re-open.
    private func refreshingCollisionOverlayAfterFullRebuild() {
        guard let renderer, let baseline = context.collisionMeshes.first?.mesh,
              let (mesh, _, _, _, _, _) = LevelViewerWindow.fullyRebuildingCollisionMesh(renderer: renderer, baseline: baseline)
        else { return }
        renderer.refreshingCollisionFillBuffer(with: [mesh])
    }

    private func refreshingCollisionOverlayAfterSingleObjectRebuild(objectIndex: Int) {
        guard let renderer, let (mesh, _, _, _, _) = LevelViewerWindow.singleObjectRebuiltCollisionMesh(renderer: renderer, objectIndex: objectIndex, collisionMeshes: context.collisionMeshes) else { return }
        renderer.refreshingCollisionFillBuffer(with: [mesh])
    }

    /// "Spawn Interactive Cortex (Prop)": finds this level's own real
    /// `BASICCRATE` (#3) record and, if this session hasn't already
    /// resolved Cortex's (#74) real skinned chain from elsewhere in the
    /// workspace, searches for it (`resolvingObjectIDAcrossAllLevels` , 
    /// the exact same cross-level search "Forge Palette anywhere" thumbnails
    /// already use, so this costs nothing extra the first time a session
    /// touches Cortex and nothing at all after). Genuinely honest failure
    /// modes surfaced in `interactiveCortexPropError` rather than silently
    /// no-oping: no native crate here, or Cortex's own chain not resolvable
    /// anywhere on the currently mounted disc.
    /// "Spawn Interactive Cortex (Prop)", arm-then-click, real, reported
    /// complaint: this used to spawn immediately at the level's own
    /// center with no say in where, unlike every other placeable type in
    /// this build (Forge Palette objects, Scenery tab, "Add Trigger"/"Add
    /// Camera"), which all arm placement mode and wait for the next
    /// viewport click. Resolving Cortex's real skinned chain still
    /// happens right away (so the error can surface immediately if his
    /// data isn't reachable), only the actual spawn is deferred to the
    /// click, via `renderer.pendingPlacementPropSkin`.
    private func spawningInteractiveCortexProp() {
        guard let renderer else { return }
        interactiveCortexPropError = nil
        guard let baseCrate = renderer.nativeGameObject(forObjectID: 3) else {
            interactiveCortexPropError = "This level's own file has no real BASICCRATE (#3) record to clone, can't spawn here."
            return
        }
        isSpawningInteractiveCortexProp = true
        Task {
            defer { isSpawningInteractiveCortexProp = false }
            guard let skinAsset = await workspace.resolvingObjectIDAcrossAllLevels(74),
                  let cortexSource = workspace.globalObjectGameObjectSources[74]
            else {
                interactiveCortexPropError = "Couldn't find Cortex's (#74) real skinned character data anywhere on the currently mounted disc."
                return
            }
            let freshObjectID = renderer.freshSyntheticObjectID()
            let source = PropSkinSpawnSource(
                freshObjectID: freshObjectID, baseGameObject: baseCrate,
                skinSourceObjectID: cortexSource.objectID, skinSourceFileRoot: cortexSource.sourceFileRoot, skinSourceBytes: cortexSource.sourceBytes
            )
            cancelArmedPlacement()
            renderer.pendingPlacementPropSkin = LevelViewerRenderer.PendingPropSkinPlacement(source: source, skinAsset: skinAsset)
            armedPropSkin = true
            workspace.statusMessage = "Click in the viewport to place the interactive Cortex prop."
        }
    }

    /// "Rebuild All Collision": completely
    /// destroys and regenerates this level's whole collision mesh from
    /// every real scenery object's own actual geometry (see
    /// `computingFullyRebuiltCollisionRecord`'s own doc comment). Opt-in,
    /// never automatic, same confirm-then-save shape as
    /// `savingInPlaceToDiscImage` above, deliberately not folded silently
    /// into every ordinary save (a real, confirmed disc corruption is
    /// exactly what an earlier *automatic* version of a similar collision
    /// feature caused).
    private func rebuildingAllCollision() {
        guard let renderer else { return }
        renderer.rebuildAllCollisionRequested = true
        guard let patch = workspace.currentLevelViewerPendingPatchProvider?() else {
            renderer.rebuildAllCollisionRequested = false
            workspace.statusMessage = "Nothing to rebuild, this level has no scenery objects with collision data, or no existing collision record to rebuild into."
            return
        }
        let discName = workspace.discImageURL?.lastPathComponent ?? "the mounted disc image"
        pendingRebuildAllCollisionSaveConfirmation = "This completely destroys this level's existing collision mesh and regenerates it from every scenery object currently placed, then writes \(patch.summary) directly into \(discName)'s own bytes, not a separate copy. The rebuilt image is independently re-verified first; if verification fails, the real disc image is left completely untouched. This can't be undone once saved. Continue?"
    }

    private func performRebuildingAllCollisionAndSavingInPlace() {
        isSavingInPlace = true
        Task {
            let outcome = await workspace.savingPendingLevelViewerEditsToMountedDisc()
            // Deliberately does *not* clear `rebuildAllCollisionRequested`
            // on this branch, same reasoning as the moved-object save
            // above: the pending "Save Anyway" retry needs it still set.
            if showingSizeThresholdConfirmationIfNeeded(outcome, retry: performRebuildingAllCollisionAndSavingInPlaceForced) {
                isSavingInPlace = false
                return
            }
            isSavingInPlace = false
            renderer?.rebuildAllCollisionRequested = false
            switch outcome {
            case .noPendingEdits:
                workspace.statusMessage = "No pending edits to save."
            case .noDiscImageConfigured:
                workspace.lastError = "No disc image is configured, set one in the Game Launcher first."
            case .saved:
                workspace.statusMessage = "Saved in-place to \(workspace.discImageURL?.lastPathComponent ?? "the mounted disc image"), the whole level's collision mesh was rebuilt from scratch."
                refreshingCollisionOverlayAfterFullRebuild()
            case .verificationFailed(let reason):
                workspace.lastError = "Couldn't verify the rebuilt disc image, nothing was written: \(reason)"
            case .writeFailed(_, _, let reason):
                workspace.lastError = "The rebuilt image passed verification, but writing it back to the disc image failed: \(reason)"
            case .sizeThresholdExceeded:
                break // handled above
            }
        }
    }

    /// "Save Anyway" from the size-threshold confirmation above, a full
    /// collision rebuild legitimately can grow the disc image more than a
    /// small edit would (a whole new collision mesh's worth of triangles),
    /// so this is a real, expected path here, not just a rare edge case.
    private func performRebuildingAllCollisionAndSavingInPlaceForced() {
        isSavingInPlace = true
        Task {
            defer {
                isSavingInPlace = false
                renderer?.rebuildAllCollisionRequested = false
            }
            let outcome = await workspace.savingPendingLevelViewerEditsToMountedDisc(allowingLargeGrowth: true)
            switch outcome {
            case .noPendingEdits:
                workspace.statusMessage = "No pending edits to save."
            case .noDiscImageConfigured:
                workspace.lastError = "No disc image is configured, set one in the Game Launcher first."
            case .saved:
                workspace.statusMessage = "Saved in-place to \(workspace.discImageURL?.lastPathComponent ?? "the mounted disc image"), the whole level's collision mesh was rebuilt from scratch."
                refreshingCollisionOverlayAfterFullRebuild()
            case .verificationFailed(let reason):
                workspace.lastError = "Couldn't verify the rebuilt disc image, nothing was written: \(reason)"
            case .writeFailed(_, _, let reason):
                workspace.lastError = "The rebuilt image passed verification, but writing it back to the disc image failed: \(reason)"
            case .sizeThresholdExceeded:
                break // `allowingLargeGrowth: true` never returns this case again
            }
        }
    }

    /// "Rebuild Collision for This Object", the per-object counterpart to
    /// "Rebuild All Collision" above, reached from the marking menu.
    private func rebuildCollisionForSelected() {
        guard canRebuildCollisionForSelected, let selectedIndex, let renderer else { return }
        renderer.rebuildCollisionRequestedForObjectIndex = selectedIndex
        guard let patch = workspace.currentLevelViewerPendingPatchProvider?() else {
            renderer.rebuildCollisionRequestedForObjectIndex = nil
            workspace.statusMessage = "Nothing to rebuild for this object, no collision data, or no existing collision record to rebuild into."
            return
        }
        let discName = workspace.discImageURL?.lastPathComponent ?? "the mounted disc image"
        pendingRebuildObjectCollisionSaveConfirmation = "This destroys and regenerates collision for just this one object, then writes \(patch.summary) directly into \(discName)'s own bytes, not a separate copy. The rebuilt image is independently re-verified first; if verification fails, the real disc image is left completely untouched. Continue?"
    }

    private func performRebuildingObjectCollisionAndSavingInPlace() {
        let objectIndex = renderer?.rebuildCollisionRequestedForObjectIndex
        isSavingInPlace = true
        Task {
            let outcome = await workspace.savingPendingLevelViewerEditsToMountedDisc()
            if showingSizeThresholdConfirmationIfNeeded(outcome, retry: performRebuildingObjectCollisionAndSavingInPlaceForced) {
                isSavingInPlace = false
                return
            }
            isSavingInPlace = false
            renderer?.rebuildCollisionRequestedForObjectIndex = nil
            switch outcome {
            case .noPendingEdits:
                workspace.statusMessage = "No pending edits to save."
            case .noDiscImageConfigured:
                workspace.lastError = "No disc image is configured, set one in the Game Launcher first."
            case .saved:
                workspace.statusMessage = "Saved in-place to \(workspace.discImageURL?.lastPathComponent ?? "the mounted disc image"), collision rebuilt for this object."
                if let objectIndex { refreshingCollisionOverlayAfterSingleObjectRebuild(objectIndex: objectIndex) }
            case .verificationFailed(let reason):
                workspace.lastError = "Couldn't verify the rebuilt disc image, nothing was written: \(reason)"
            case .writeFailed(_, _, let reason):
                workspace.lastError = "The rebuilt image passed verification, but writing it back to the disc image failed: \(reason)"
            case .sizeThresholdExceeded:
                break // handled above
            }
        }
    }

    private func performRebuildingObjectCollisionAndSavingInPlaceForced() {
        let objectIndex = renderer?.rebuildCollisionRequestedForObjectIndex
        isSavingInPlace = true
        Task {
            defer {
                isSavingInPlace = false
                renderer?.rebuildCollisionRequestedForObjectIndex = nil
            }
            let outcome = await workspace.savingPendingLevelViewerEditsToMountedDisc(allowingLargeGrowth: true)
            switch outcome {
            case .noPendingEdits:
                workspace.statusMessage = "No pending edits to save."
            case .noDiscImageConfigured:
                workspace.lastError = "No disc image is configured, set one in the Game Launcher first."
            case .saved:
                workspace.statusMessage = "Saved in-place to \(workspace.discImageURL?.lastPathComponent ?? "the mounted disc image"), collision rebuilt for this object."
                if let objectIndex { refreshingCollisionOverlayAfterSingleObjectRebuild(objectIndex: objectIndex) }
            case .verificationFailed(let reason):
                workspace.lastError = "Couldn't verify the rebuilt disc image, nothing was written: \(reason)"
            case .writeFailed(_, _, let reason):
                workspace.lastError = "The rebuilt image passed verification, but writing it back to the disc image failed: \(reason)"
            case .sizeThresholdExceeded:
                break // `allowingLargeGrowth: true` never returns this case again
            }
        }
    }

    // "Auto-Update Collision on Add/Delete": the standalone "Rebuild Level
    // Collision…" button used to live here, real, reported bug: it
    // computed the correct rebuilt `ColData` bytes but saved them to a
    // disconnected standalone loose file via its own save panel, never
    // reaching Quick Launch/Save Chunk Overrides/Save In-Place, so newly
    // placed objects still had no real collision the moment the game
    // actually booted. That computation now runs automatically inside
    // `computingPendingOverridePatch` (see `computingRebuiltCollisionRecord`
    // just above it), so it's part of every save this window already
    // produces, no separate button/action needed.

    /// "Contextual / Chunk-Specific Launch", hands `GameLauncherView` a
    /// real plan built from exactly what "Save Chunk Overrides…" would
    /// have written, without a save dialog first: this level's own real
    /// archive base name (so the patched executable boots straight into
    /// it, bypassing the main menu, `ExecutablePatcher.
    /// writingStartingChunkPath`) plus, if there's anything pending, this
    /// session's own live edits baked in as an archive replacement.
    private func quickLaunchThisChunk() {
        confirmingPendingCollisionRebuild {
            confirmingRiskyPlacementCount {
                confirmingDanglingReferences { performQuickLaunchThisChunk() }
            }
        }
    }

    /// "Rebuild All Collision"/"Rebuild Collision
    /// for This Object" being armed (`renderer.rebuildAllCollisionRequested`/
    /// `.rebuildCollisionRequestedForObjectIndex`) but not yet actually
    /// saved, the user clicked the rebuild button, then clicked Quick
    /// Launch instead of going through that button's own confirm-and-save
    /// flow, used to fall through silently. Quick Launch's own patch
    /// computation *does* still bake the rebuilt collision into the boot
    /// either way (`computingRebuiltCollisionRecord`'s short-circuit checks
    /// these same flags first), so nothing is actually lost, but doing a
    /// full destroy-and-rebuild with no visible confirmation, skipping the
    /// same "this can't be undone" warning that button's own direct save
    /// path always shows, is a real, reasonably surprising gap. Gives an
    /// explicit choice instead: go save it for real first (through the
    /// normal rebuild-and-save flow, so it also sticks around in the disc
    /// image afterward, not just this one boot), or launch anyway with it
    /// only baked into this one-off boot.
    private func confirmingPendingCollisionRebuild(before action: @escaping () -> Void) {
        guard renderer?.rebuildAllCollisionRequested == true || renderer?.rebuildCollisionRequestedForObjectIndex != nil else {
            action()
            return
        }
        pendingUnsavedCollisionRebuildLaunchAction = action
    }

    /// "Make the scenery-count warning harder to miss", real, requested
    /// QoL: `liveSceneryPlacementCount`'s own caption is easy to skip past,
    /// and a silent in-game hang (see `riskyScenerycountThreshold`'s own
    /// doc comment for the real PCSX2 evidence) is a much worse failure
    /// mode than a blocked action. Scoped to Quick Launch specifically
    /// (not "Save Chunk Overrides…", which only ever writes a loose copy , 
    /// nothing boots until something actually launches it), with an
    /// explicit "Launch Anyway" override rather than an unconditional
    /// block, since the exact threshold is a real but level-dependent,
    /// non-exact number (see that same doc comment).
    private func confirmingRiskyPlacementCount(before action: @escaping () -> Void) {
        let decision = SceneryPlacementCountGate.decision(
            count: liveSceneryPlacementCount,
            warnThreshold: Self.riskyScenerycountThreshold,
            hardBlockThreshold: Self.hardBlockSceneryCountThreshold
        )
        switch decision {
        case .allow:
            action()
        case .warn(let message):
            pendingRiskyCountWarning = message
            pendingConfirmedRiskyCountAction = action
        case .block(let message):
            pendingHardBlockedCountMessage = message
        }
    }

    private func performQuickLaunchThisChunk() {
        guard let referenceNode = referenceNodeForFileOps, let actorFileRoot = workspace.fileRoot(containing: referenceNode) else { return }
        // Real bug this fixes (see `LevelDisplayNameMatching`'s own doc
        // comment): this used to derive `baseName` as `(actorFileRoot.
        // displayName as NSString).deletingPathExtension` with no
        // `lastPathComponent` normalization, so a level reached by
        // browsing a mounted disc/archive (`displayName` == a full path
        // like "Levels/Earth/Cavern/cavent") produced "Levels/Earth/Cavern/
        // cavent" instead of "cavent", which `GameLauncher.building`'s own
        // bare-`lastPathComponent` archive-entry matching could never
        // match, always throwing "isn't in this disc's archive."
        let baseName = LevelDisplayNameMatching.quickLaunchBaseName(fromDisplayName: actorFileRoot.displayName)
        var replacements: [String: Data] = [:]
        var summary = "Boots \(baseName) exactly as it is on the disc, no pending edits to bake in."
        if let (_, patch, patchSummary) = computingPendingOverridePatch() {
            // Same bare-filename normalization `baseName` above needs, and
            // for the exact same reason (`LevelDisplayNameMatching`'s own
            // doc comment), `GameLaunchPlan.archiveReplacements`' own doc
            // comment is explicit that its keys are bare filenames (e.g.
            // "beach.rm2"), but `actorFileRoot.displayName`/
            // `sceneryFileDisplayName` are full archive paths
            // ("Levels/Earth/Hub/beach.rm2") for any level reached by
            // browsing a mounted disc/archive. Keying by the full path
            // here meant `GameLauncher.building`'s own bare-filename
            // archive-index lookup could never match it, throwing
            // "isn't in this disc's archive" for every archive-browsed
            // level, exactly the same bug class `baseName` already fixed,
            // just missed on this dictionary's own keys.
            replacements[(actorFileRoot.displayName as NSString).lastPathComponent] = patch.primaryBytes
            // Scenery's own file (almost always a distinct `.sm2` from the
            // Instance/Trigger/Camera edits' `.rm2` above, see
            // `WorkspaceViewModel.LevelOverridePatch`'s own doc comment)
            // needs its own separate archive-replacement entry, or a
            // pending scenery placement/move/delete would boot unpatched.
            if let sceneryBytes = patch.sceneryBytes, let sceneryFileDisplayName = patch.sceneryFileDisplayName {
                replacements[(sceneryFileDisplayName as NSString).lastPathComponent] = sceneryBytes
            }
            summary = "Boots \(baseName) with this session's own pending edits baked in, \(patchSummary)."
        }
        workspace.gameLauncherContext = WorkspaceViewModel.GameLauncherContext(
            summary: summary, startingChunkBaseName: baseName, archiveReplacements: replacements
        )
        workspace.isGameLauncherPresented = true
    }

    /// Registers one ⌘Z step restoring the selected object's full
    /// transform to `previousSnapshot`, and (via the recursive helper
    /// below) a matching ⌘⇧Z redo back to where it ended up, deliberately
    /// built entirely from stable references (`undoManager`, `renderer`,
    /// the object's index, plain value-type snapshots), not by capturing
    /// `self`/`@State` inside the closure `UndoManager` holds onto: this
    /// View struct gets recreated on every SwiftUI re-render, and a stale
    /// captured copy of it would be the wrong kind of thing for a
    /// long-lived undo stack to hold a reference to. One snapshot-based
    /// mechanism covers position/rotation/scale edits alike, rather than
    /// three near-identical ones.
    private func registerUndo(from previousSnapshot: TransformSnapshot?) {
        guard let undoManager, let previousSnapshot, let index = selectedIndex, let renderer,
              let newSnapshot = currentSnapshot(), newSnapshot != previousSnapshot
        else { return }
        undoManager.setActionName("Edit Transform")
        Self.registerTransformUndo(undoManager: undoManager, renderer: renderer, index: index, restoreTo: previousSnapshot, thenRedoTo: newSnapshot)
    }

    /// Real, reported bug: "Show Collision Volume" only ever recomputed its
    /// world-space box overlay in `updateCollisionVolumeOverlay()`'s one
    /// call site, the toggle itself flipping on/off. Moving/rotating/
    /// scaling an object with the toggle already on left its collision box
    /// drawn at the *old* transform indefinitely (only an off-then-on of
    /// the toggle refreshed it), which reads exactly like "I updated it and
    /// the old collision is still there" even though the object's own data
    /// was fine. Every real commit point for a transform edit (gizmo drag/
    /// arrow-key nudge via `onGizmoDragEnded`, HUD nudge/rotate, and the
    /// typed Position/Rotation/Scale fields) already funnels through
    /// `registerUndo(from:)`, piggybacking the refresh there covers all of
    /// them from one place instead of eight near-identical call sites, and
    /// stays cheap: `updateCollisionVolumeOverlay()` itself already no-ops
    /// (clears to empty) when the toggle is off, and this only runs once
    /// per completed edit, never per drag-tick (see the git history around
    /// "stop rebuilding AI path lines on every unrelated drag tick" for why
    /// that distinction matters here).
    private func registerUndoAndRefreshCollisionOverlay(from previousSnapshot: TransformSnapshot?) {
        registerUndo(from: previousSnapshot)
        updateCollisionVolumeOverlay()
    }

    private static func registerTransformUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int, restoreTo: TransformSnapshot, thenRedoTo: TransformSnapshot) {
        undoManager.registerUndo(withTarget: renderer) { target in
            target.select(index: index)
            target.setSelectedPosition(to: restoreTo.position)
            target.setSelectedRotation(eulerDegrees: restoreTo.rotationDegrees)
            target.setSelectedScale(to: restoreTo.scale)
            registerTransformUndo(undoManager: undoManager, renderer: target, index: index, restoreTo: thenRedoTo, thenRedoTo: restoreTo)
        }
    }

    /// "Robust Undo/Redo… for item placement" (Part 4D): the add/remove
    /// counterpart to `registerTransformUndo`, same recursive
    /// undo-then-register-the-opposite-as-the-next-undo shape. ⌘Z removes
    /// the just-placed object; ⌘⇧Z (registered as the undo *of that*
    /// removal) re-spawns it via `spawnInstance` at the exact same
    /// position, which also re-resolves its geometry, cheap, and avoids
    /// this renderer needing to cache GPU buffers for an object that isn't
    /// currently in the scene.
    private func registerPlacementUndo(index: Int) {
        guard let undoManager, let renderer else { return }
        undoManager.setActionName("Place Object")
        Self.registerPlacementUndo(undoManager: undoManager, renderer: renderer, index: index)
    }

    /// "Spawn Interactive Cortex (Prop)" undo/redo, same recursive shape
    /// as `registerPlacementUndo`/`registerSceneryPlacementUndo`, redoing
    /// via `spawnInteractiveCortexProp` instead of `spawnInstance`: see
    /// `ModelViewerRenderer.propSkinPlacementInfo`'s own doc comment for
    /// why a plain `spawnInstance(objectID:)` redo can't work for this
    /// synthetic object type.
    private func registerPropSkinPlacementUndo(index: Int) {
        guard let undoManager, let renderer else { return }
        undoManager.setActionName("Place Interactive Cortex Prop")
        Self.registerPropSkinPlacementUndo(undoManager: undoManager, renderer: renderer, index: index)
    }

    static func registerPropSkinPlacementUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int) {
        guard let info = renderer.propSkinPlacementInfo(at: index) else { return }
        undoManager.registerUndo(withTarget: renderer) { target in
            target.removeObject(at: index)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                let newIndex = redoTarget.spawnInteractiveCortexProp(source: info.source, skinAsset: info.skinAsset, at: info.worldPosition, applyPlacementAlignment: false) ?? index
                registerPropSkinPlacementUndo(undoManager: undoManager, renderer: redoTarget, index: newIndex)
            }
        }
    }

    private var canDuplicateSelected: Bool {
        guard let renderer, let selectedIndex else { return false }
        return renderer.canDuplicate(at: selectedIndex)
    }

    /// "Set AI Path on a Newly-Placed AI", only
    /// enabled for a session-placed Instance (see `GPULevelObject.
    /// pendingPathIDs`'s own doc comment for why this doesn't extend to an
    /// already-real, on-disk one yet).
    private var canSetAIPathOnSelected: Bool {
        guard let renderer, let selectedIndex else { return false }
        return renderer.pendingPathIDs(forObjectAt: selectedIndex) != nil
    }

    /// "Rebuild Collision for This Object", scenery only (this format's
    /// collision mesh is authored per-level, not per-Instance/enemy, see
    /// `computingFullyRebuiltCollisionRecord`'s own `.scenery`-only scope
    /// for the same reasoning), and only when the selected object actually
    /// has collision data to build a box from (real asset data, or the
    /// generated-from-bounds fallback, see `GPULevelObject.
    /// generatedCollisionData`'s own doc comment; this should be true for
    /// essentially every real scenery placement).
    private var canRebuildCollisionForSelected: Bool {
        guard let renderer, let selectedIndex, renderer.levelObjects.indices.contains(selectedIndex) else { return false }
        let object = renderer.levelObjects[selectedIndex]
        guard object.layer == .scenery else { return false }
        return !object.assetCollisionData.isEmpty || !object.generatedCollisionData.isEmpty
    }

    private func setAIPathOnSelected() {
        guard canSetAIPathOnSelected, let selectedIndex, let renderer else { return }
        aiPathAssignmentSelection = Set((renderer.pendingPathIDs(forObjectAt: selectedIndex) ?? []).map { UInt32($0) })
        aiPathAssignmentTargetIndex = selectedIndex
    }

    /// "Set AI Path on a Newly-Placed AI", a checklist over every real AI
    /// Path this level has (on-disk plus session-added, the same union
    /// `aiPathsPanel` already lists), so assigning a path reuses real
    /// records instead of inventing a new mechanism. `AIPathRecord.id` is
    /// `UInt32` (the general chunk-record-ID namespace) while `Instance.
    /// PathIDs` is genuinely `[UInt16]` on disk (confirmed against
    /// `Instance.cs`'s own `List<ushort> PathIDs`), `commitAIPathAssignment`
    /// is where that narrowing happens, dropping (not wrapping) anything
    /// that doesn't fit rather than silently corrupting a reference.
    @ViewBuilder
    private var aiPathAssignmentSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set AI Path").font(.headline)
            Text("Pick which real AI Path(s) this object should reference, saved as its own PathIDs list the next time you save.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(remainingRealAIPaths, id: \.node.id) { entry in
                    Toggle("Path #\(entry.path.id)", isOn: aiPathAssignmentToggleBinding(for: entry.path.id))
                }
                ForEach(renderer?.newAIPaths ?? [], id: \.id) { entry in
                    Toggle("Path #\(entry.id) (new)", isOn: aiPathAssignmentToggleBinding(for: entry.id))
                }
            }
            .frame(minWidth: 260, minHeight: 160, maxHeight: 280)
            HStack {
                Button("Add New Path") { addAIPathAndSelectForAssignment() }
                Spacer()
                Button("Cancel") { aiPathAssignmentTargetIndex = nil }
                Button("Done") { commitAIPathAssignment() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 340)
    }

    private func aiPathAssignmentToggleBinding(for id: UInt32) -> Binding<Bool> {
        Binding(
            get: { aiPathAssignmentSelection.contains(id) },
            set: { isOn in
                if isOn { aiPathAssignmentSelection.insert(id) } else { aiPathAssignmentSelection.remove(id) }
            }
        )
    }

    private func addAIPathAndSelectForAssignment() {
        guard let renderer else { return }
        let id = renderer.addAIPath()
        if let undoManager {
            undoManager.setActionName("Add AI Path")
            Self.registerAIPathAddUndo(undoManager: undoManager, renderer: renderer, id: id, args: [0, 1, 0, 0, 0])
        }
        aiPathAssignmentSelection.insert(id)
    }

    private func commitAIPathAssignment() {
        defer { aiPathAssignmentTargetIndex = nil }
        guard let renderer, let index = aiPathAssignmentTargetIndex else { return }
        let ids = aiPathAssignmentSelection.compactMap { UInt16(exactly: $0) }.sorted()
        renderer.setPendingPathIDs(ids, forObjectAt: index)
    }

    /// "Unrestricted Chunk Free-Edit Mode": duplicates the selected
    /// object via `LevelViewerRenderer.duplicateSelectedObject` (a real
    /// spawn through the same pipeline the Forge Palette uses), then
    /// registers exactly the same kind of add/remove undo step a fresh
    /// placement gets, whichever of Instance/AI-waypoint/Trigger/Camera/
    /// Scenery the duplicate turned out to be, only the matching
    /// registration actually does anything (each guards on its own `nil`
    /// check).
    private func duplicateSelected() {
        guard let renderer, let newIndex = renderer.duplicateSelectedObject() else { return }
        selectedIndex = newIndex
        // Same reasoning as `deleteSelected` -- an insertion can shift
        // later indices, so drop the stale picked set rather than risk it.
        alignmentSelection.removeAll()
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Duplicate Object")
        Self.registerPlacementUndo(undoManager: undoManager, renderer: renderer, index: newIndex)
        Self.registerAIWaypointPlacementUndo(undoManager: undoManager, renderer: renderer, index: newIndex)
        Self.registerTriggerPlacementUndo(undoManager: undoManager, renderer: renderer, index: newIndex)
        Self.registerCameraPlacementUndo(undoManager: undoManager, renderer: renderer, index: newIndex)
        Self.registerSceneryPlacementUndo(undoManager: undoManager, renderer: renderer, index: newIndex)
    }

    private var canCopySelected: Bool {
        guard let renderer, let selectedIndex else { return false }
        return renderer.canDuplicate(at: selectedIndex)
    }

    /// Marking menu "Copy", snapshots the selection into `objectClipboard`
    /// without touching the scene. Same eligibility as Duplicate
    /// (`canDuplicate`); unlike Duplicate, this doesn't act immediately, so
    /// `objectClipboard` outlives whatever gets selected next.
    private func copySelected() {
        guard let renderer, let selectedIndex else { return }
        objectClipboard = renderer.copyObject(at: selectedIndex)
    }

    private var canCutSelected: Bool { canCopySelected && canDeleteSelected }

    /// Marking menu "Cut", Copy, then the exact same `deleteSelected`
    /// used elsewhere (identical undo/redo step; this just also fills the
    /// clipboard first).
    private func cutSelected() {
        copySelected()
        deleteSelected()
    }

    private var canPasteClipboard: Bool { objectClipboard != nil }

    /// Marking menu "Paste", spawns a fresh copy of whatever's in
    /// `objectClipboard` through `LevelViewerRenderer.pasteObject`, then
    /// registers undo/redo for whichever kind it turned out to be. All
    /// five `register*PlacementUndo` calls are unconditional, same
    /// "only the matching one actually does anything" pattern
    /// `duplicateSelected` already uses for its two, calling the static
    /// forms directly (not their instance-method wrappers) so this can
    /// set one "Paste Object" action name instead of a kind-specific one
    /// stomping it.
    private func pasteClipboard() {
        guard let renderer, let entry = objectClipboard, let newIndex = renderer.pasteObject(entry) else { return }
        selectedIndex = newIndex
        alignmentSelection.removeAll()
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Paste Object")
        Self.registerPlacementUndo(undoManager: undoManager, renderer: renderer, index: newIndex)
        Self.registerAIWaypointPlacementUndo(undoManager: undoManager, renderer: renderer, index: newIndex)
        Self.registerTriggerPlacementUndo(undoManager: undoManager, renderer: renderer, index: newIndex)
        Self.registerCameraPlacementUndo(undoManager: undoManager, renderer: renderer, index: newIndex)
        Self.registerSceneryPlacementUndo(undoManager: undoManager, renderer: renderer, index: newIndex)
    }

    /// "Procedural Brush" (roadmap 8.6): only offered for a selected
    /// Actor/Instance placement, `LevelViewerRenderer.scatterAroundSelected`
    /// itself already scopes to that layer (the only one with a real spawn
    /// primitive), this just avoids showing controls that would silently
    /// no-op for scenery/trigger/camera/AI-waypoint selections.
    private var canScatterSelected: Bool {
        guard let renderer, let selectedIndex else { return false }
        return renderer.canDuplicate(at: selectedIndex) && renderer.selectedObjectLayer == .actors
    }

    private func scatterSelected() {
        guard let renderer else { return }
        let newIndices = renderer.scatterAroundSelected(count: Int(scatterCount), radius: Float(scatterRadius))
        guard !newIndices.isEmpty else { return }
        selectedIndex = newIndices.last
        refreshTransformFields()
        guard let undoManager else { return }
        undoManager.setActionName("Scatter \(newIndices.count) Objects")
        for index in newIndices {
            Self.registerPlacementUndo(undoManager: undoManager, renderer: renderer, index: index)
        }
    }

    private static func registerPlacementUndo(undoManager: UndoManager, renderer: LevelViewerRenderer, index: Int) {
        guard let snapshot = renderer.newInstanceInfo(at: index) else { return }
        undoManager.registerUndo(withTarget: renderer) { target in
            target.removeObject(at: index)
            undoManager.registerUndo(withTarget: target) { redoTarget in
                let newIndex = redoTarget.spawnInstance(objectID: snapshot.objectID, at: snapshot.worldPosition, applyPlacementAlignment: false) ?? index
                registerPlacementUndo(undoManager: undoManager, renderer: redoTarget, index: newIndex)
            }
        }
    }

}

/// One button in `LevelViewerWindow.movementControlsHUD`: fires once
/// immediately on press, then repeats at a fixed rate while held, the
/// same "hold for continuous movement" feel a held keyboard arrow key
/// already gives (`InteractiveMTKView.handleArrowKeyNudge` fires on every
/// AppKit key-repeat event), just reachable without a keyboard.
/// `maximumDistance: .infinity` on the long-press gesture keeps tracking
/// the press even if the cursor drifts off the small button mid-hold,
/// so a slightly shaky hand doesn't cut the repeat short.
private struct RepeatingHUDButton: View {
    let systemImage: String
    let action: () -> Void
    @State private var repeatTimer: Timer?

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, perform: {}, onPressingChanged: { pressing in
                if pressing {
                    action()
                    repeatTimer?.invalidate()
                    // Real, reported bug: a held button silently only ever
                    // fired this once, `Timer.scheduledTimer` registers
                    // only on the current run loop's `.default` mode, and
                    // while the mouse button stays down, AppKit runs the
                    // loop in `.eventTracking` mode instead; a `.default`
                    // -only timer simply never fires during that whole
                    // window, so the repeat action never happened until
                    // release. Adding it in `.common` mode (covers both
                    // `.default` and `.eventTracking`) fixes it.
                    let timer = Timer(timeInterval: 0.12, repeats: true) { _ in action() }
                    RunLoop.current.add(timer, forMode: .common)
                    repeatTimer = timer
                } else {
                    repeatTimer?.invalidate()
                    repeatTimer = nil
                }
            })
            // Regression fix: `onPressingChanged(false)` is the only path
            // that used to stop the repeat timer -- if this view left the
            // hierarchy while still held (selection changed mid-press,
            // window closed), the `Timer` kept firing indefinitely, each
            // tick calling `action()` against whatever `renderer`/
            // `workspace` it had captured. `.onDisappear` guarantees
            // cleanup regardless of how the press ends.
            .onDisappear {
                repeatTimer?.invalidate()
                repeatTimer = nil
            }
    }
}

/// "Hold to Move" HUD toggle's own button style, same look as
/// `RepeatingHUDButton`, but ticks at a smooth ~60Hz for the duration of
/// the hold instead of a slower fixed-step repeat, handing each tick the
/// *real* elapsed time since the previous one (not an assumed constant)
/// so `nudgeSelectedPositionContinuous` accumulates a consistent speed
/// even if a tick's actual timing jitters. `onPressStart`/`onPressEnd`
/// bracket the whole hold as a single undo step (via the caller's own
/// `transformBeforeEdit`/`registerUndo`, the same pattern a gizmo drag
/// already uses), registering one per ~60Hz tick would flood undo with
/// one entry per frame.
private struct ContinuousHUDButton: View {
    let systemImage: String
    let tick: (TimeInterval) -> Void
    let onPressStart: () -> Void
    let onPressEnd: () -> Void
    @State private var repeatTimer: Timer?
    @State private var lastTickTime: CFAbsoluteTime?

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, perform: {}, onPressingChanged: { pressing in
                if pressing {
                    onPressStart()
                    lastTickTime = CFAbsoluteTimeGetCurrent()
                    repeatTimer?.invalidate()
                    // Same real bug/fix as `RepeatingHUDButton`'s own
                    // `.common`-mode comment, this one had it worse:
                    // `RepeatingHUDButton` at least fires `action()` once,
                    // synchronously, on press, so a quick tap still nudges;
                    // this button's every single tick (including the very
                    // first) only ever came from the timer, so with a
                    // `.default`-only timer, holding it while the mouse
                    // stayed down moved the selection *not at all*, the
                    // "smooth continuous slide" feature was actually inert
                    // for as long as the button was held down with the
                    // mouse.
                    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
                        let now = CFAbsoluteTimeGetCurrent()
                        let delta = lastTickTime.map { now - $0 } ?? (1.0 / 60.0)
                        lastTickTime = now
                        tick(delta)
                    }
                    RunLoop.current.add(timer, forMode: .common)
                    repeatTimer = timer
                } else {
                    repeatTimer?.invalidate()
                    repeatTimer = nil
                    lastTickTime = nil
                    onPressEnd()
                }
            })
            // Same regression `RepeatingHUDButton`'s own `.onDisappear`
            // guards against (view leaving the hierarchy mid-hold, e.g.
            // the selection changing under it), plus, unlike that button,
            // this one also owes the still-open hold its matching
            // `onPressEnd()` so the undo step it started actually gets
            // registered instead of silently vanishing.
            .onDisappear {
                if repeatTimer != nil { onPressEnd() }
                repeatTimer?.invalidate()
                repeatTimer = nil
            }
    }
}

/// "Integrated Level Audio": every decoded `SoundEffect` in the level's
/// file, with a frictionless inline Play button, reuses `WAVEncoder`/
/// `PlaybackEndDelegate` (`SoundEffectInspectorView.swift`) rather than a
/// second audio-decoding path. Deliberately titled "Sound Effects in This
/// File", not "Background Music"/"Ambient Banks": `SoundEffectAsset` has
/// no field distinguishing those categories, and this format doesn't
/// record which chunk a level's music actually comes from, labeling them
/// by role would be presenting a guess as decoded data.
private struct LevelAudioPanel: View {
    let sounds: [(node: ChunkNode, sound: SoundEffectAsset)]
    @State private var playingNodeID: UUID?
    @State private var player: AVAudioPlayer?
    @State private var playerDelegate: PlaybackEndDelegate?
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text("Sound effects in this file (\(sounds.count)), not categorized as BGM/ambient, since nothing in the decoded data distinguishes those roles.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Performance fix (audit): same LazyVStack fix as the main
            // object list, matters most for a level with a large sound
            // bank.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sounds, id: \.node.id) { entry in
                    HStack {
                        Button {
                            toggle(entry)
                        } label: {
                            Image(systemName: playingNodeID == entry.node.id ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(entry.sound.pcmSamples.isEmpty)
                        .accessibilityLabel(playingNodeID == entry.node.id ? "Stop Sound" : "Play Sound")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.node.displayName).font(.caption).lineLimit(1)
                            Text(String(format: "%.2fs · %d Hz", entry.sound.durationSeconds, entry.sound.sampleRateHz))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        } label: {
            Text("Chunk Audio (\(sounds.count))").font(.headline)
        }
        .onDisappear { player?.stop() }
    }

    private func toggle(_ entry: (node: ChunkNode, sound: SoundEffectAsset)) {
        if playingNodeID == entry.node.id {
            player?.stop()
            playingNodeID = nil
            return
        }
        guard !entry.sound.pcmSamples.isEmpty else { return }
        let wav = WAVEncoder.encode(pcm: entry.sound.pcmSamples, sampleRateHz: entry.sound.sampleRateHz)
        guard let newPlayer = try? AVAudioPlayer(data: wav) else {
            playingNodeID = nil
            return
        }
        let delegate = PlaybackEndDelegate { playingNodeID = nil }
        newPlayer.delegate = delegate
        playerDelegate = delegate
        player = newPlayer
        newPlayer.prepareToPlay()
        playingNodeID = newPlayer.play() ? entry.node.id : nil
    }
}

/// "The Forge Palette: Directory Asset Placement" (Part 4C), a
/// categorized, searchable directory of every named `ObjectID`
/// (`DefaultObjectID`, ported from the reference tool's own enum) a new
/// `Instance` could be spawned as. Picking an entry arms placement mode
/// (`onArm`, wired to `LevelViewerRenderer.pendingPlacementObjectID` by the
/// caller) rather than placing anything itself, this view has no opinion
/// about *where* in the 3D world the next click lands.
private struct ForgePaletteView: View {
    /// "Visual Item Memory Budget" (blueprint 6.1): a live count of new
    /// `Instance` placements armed via this palette in the current editing
    /// session (`ModelViewerRenderer.pendingNewInstances`, the same list
    /// "Save Chunk Overrides…" writes back). Deliberately *not* a
    /// budget-bar against a fixed ceiling, nothing in this codebase's
    /// reference material verifies a real per-chunk object-count limit the
    /// PS2 engine actually enforces, and this codebase's convention is to
    /// never fabricate a number like that from guesswork. This is Forge's
    /// "budget awareness" in the one honest form available: how much
    /// *you've* added, growing live as you place things, not a percentage
    /// against an invented cap.
    let placedThisSession: Int
    /// Whether `objectID` would resolve to real geometry in the level
    /// currently open, see `LevelViewerRenderer.canResolveObjectID`'s doc
    /// comment. `nil` means "renderer not ready yet," shown as available
    /// rather than flashing every entry as unresolvable before load
    /// finishes.
    let canResolve: (UInt16) -> Bool?
    /// "Honest Forge Palette Preview", see `LevelViewerRenderer.
    /// canResolveNativelyObjectID`'s own doc comment. `true` only when
    /// `objectID`'s geometry actually lives in data this session's own
    /// save will write (this level's own file, or the shared always-
    /// shipped `Default.rm2`); `false` when it only resolved through the
    /// cross-level "Forge Palette anywhere" preview search, which never
    /// copies anything into the saved file. Checked independently of
    /// `canResolve` since a row can be `canResolve == true` (looks placeable)
    /// while this is `false` (won't actually spawn once booted).
    let canResolveNatively: (UInt16) -> Bool
    /// "Drag-and-Drop Asset Palette & Tray" (roadmap 6.2): resolves an
    /// entry to the real geometry a thumbnail render needs, `nil` for the
    /// same reasons `canResolve` can be `nil`/`false` (renderer not ready
    /// yet, or this level's data genuinely has no geometry for that ID).
    let resolveForThumbnail: (UInt16) -> ResolvedModelAsset?
    /// "Forge Palette anywhere": drives (and reports the in-flight state of)
    /// the background disc-wide search for an entry `resolveForThumbnail`
    /// currently misses, see `GlobalObjectResolutionCache`'s own doc
    /// comment. Owned by `LevelViewerWindow`, handed down the same way
    /// `SceneryLoadCache` is to `SceneryModeView`.
    let resolutionCache: GlobalObjectResolutionCache
    /// See `SceneryModeView.scrollAnchorSectionID`'s own doc comment, same
    /// real bug (switching mode tabs and back reset scroll to the top),
    /// same fix, for the Forge Palette's own list.
    @Binding var scrollAnchorObjectID: UInt16?
    /// Bound to the sidebar-wide search field (`LevelViewerWindow`'s own
    /// `sidebarSearchText`), typing there filters this palette live even
    /// when "Place" isn't the active mode tab, and the palette's own
    /// search field below both reads and writes the same text, so either
    /// entry point stays in sync with the other. Declared before `onArm`
    /// so trailing-closure call syntax still works at the call site.
    @Binding var searchText: String
    /// "Numbered Hotbar (1-9)": pins this entry into the next free hotbar
    /// slot, a separate action from `onArm` (clicking the row itself
    /// still arms placement immediately, unchanged) so pinning doesn't
    /// require placing one first. Declared before `onArm` so `onArm` stays
    /// the trailing closure at the call site.
    let onPin: (UInt16, String) -> Void
    /// The object ID currently armed for placement (`LevelViewerWindow.
    /// armedPlacement`), highlighted yellow in the list so it's clear at
    /// a glance which entry the next viewport click will place.
    let armedObjectID: UInt16?
    let onArm: (UInt16, String) -> Void

    /// Needed only to hand to `resolutionCache.search(objectID:workspace:)`
    ///, every actual resolve/render call still goes through `canResolve`/
    /// `resolveForThumbnail` above, kept as closures (not a second, direct
    /// path into `workspace`) so this view's own resolve logic stays exactly
    /// in lockstep with whatever `renderer` the caller is actually using.
    @Environment(WorkspaceViewModel.self) private var workspace

    @State private var selectedCategory: DefaultObjectID.Category?
    @State private var hideUnavailable = false
    /// Same cache/failure-set split `ModelsHubView` uses for its gallery
    /// thumbnails, keyed by `objectID` instead of a resolved asset's own
    /// `id`, a palette entry's thumbnail is looked up before any
    /// `ResolvedModelAsset` exists for it. `failedThumbnailIDs` means
    /// specifically "a real resolved asset's *3D render* failed", it must
    /// never be set just because `resolveForThumbnail` came up empty (see
    /// `loadThumbnailIfNeeded`'s doc comment): conflating the two would
    /// freeze a row at the orange placeholder forever, even after a
    /// background `resolutionCache` search later succeeds.
    @State private var thumbnailCache: [UInt16: NSImage] = [:]
    @State private var failedThumbnailIDs: Set<UInt16> = []

    private var filteredEntries: [(id: UInt16, name: String)] {
        DefaultObjectID.names
            .filter { selectedCategory == nil || DefaultObjectID.category(forName: $0.value) == selectedCategory }
            .filter { searchText.isEmpty || $0.value.localizedCaseInsensitiveContains(searchText) }
            .filter { !hideUnavailable || (canResolve($0.key) ?? true) }
            .sorted { $0.value < $1.value }
            .map { (id: $0.key, name: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Forge Palette", systemImage: "hammer.fill").font(.headline)
                Spacer()
                // This build has no verified real object-count ceiling to
                // gauge against, a live count, not a budget bar.
                if placedThisSession > 0 {
                    Text("\(placedThisSession) placed this session")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("New placements armed this session, not yet saved.")
                }
            }
            Text("Pick an object, then click in the viewport to place a brand-new Instance of it. This lists every object ID in the whole game, not every one has geometry data in *this* level's own file (or the shared fallback), so some will place as an amber placeholder cube instead of real geometry; those are marked below. A yellow ⚠︎ means the preview is borrowed from another level for display only, that object's real data won't be in the saved file, so it won't actually appear when you boot the game. Categories are a best-effort grouping by name text, not verified game data.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Categories are pattern-matched from object names, not real game data.")

            TextField("Search objects…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            Picker("Category", selection: $selectedCategory) {
                Text("All").tag(DefaultObjectID.Category?.none)
                ForEach(DefaultObjectID.Category.allCases) { category in
                    Text(category.rawValue).tag(DefaultObjectID.Category?.some(category))
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            // "Global Thumbnails": available also if the object resolved in
            // a different level this session, same real geometry the
            // thumbnail shows.
            Toggle("Hide objects with no known geometry", isOn: $hideUnavailable)
                .font(.caption2)
                .toggleStyle(.checkbox)
                .help("Available includes objects resolved in another level this session.")

            List(filteredEntries, id: \.id) { entry in
                let resolvable = canResolve(entry.id) ?? true
                let isBorrowedPreviewOnly = resolvable && !canResolveNatively(entry.id)
                let isArmed = armedObjectID == entry.id
                HStack {
                    Button {
                        onArm(entry.id, entry.name)
                    } label: {
                        HStack {
                            paletteThumbnail(for: entry.id, resolvable: resolvable)
                                .frame(width: 40, height: 40)
                                // "Forge Palette anywhere": `.task(id:)`
                                // (not `.onAppear`) specifically so this
                                // re-fires the instant `resolvable` flips
                                // from false to true, the moment a
                                // background `resolutionCache` search
                                // resolves this object in some other level,
                                // `canResolve` (which already re-checks
                                // `workspace.globalObjectThumbnails` live)
                                // starts returning true for it, and this row
                                // needs to actually kick off the real 3D
                                // thumbnail render at that point, not just
                                // wait for the user to scroll away and back.
                                .task(id: resolvable) { loadThumbnailIfNeeded(for: entry.id) }
                            Text(entry.name).lineLimit(1).font(.callout)
                                .foregroundStyle(resolvable ? .primary : .secondary)
                            if isBorrowedPreviewOnly {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .help("Preview only, borrowed from another level, this object's real data isn't in this level's own file, so it won't actually appear when you boot the game. Placing it still only adds an Instance record pointing at this object ID.")
                                    .accessibilityLabel("Won't appear when booted, preview only")
                            }
                            Spacer()
                            Text("#\(entry.id)").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        onPin(entry.id, entry.name)
                    } label: {
                        Image(systemName: "pin.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Pin to Hotbar")
                    .help("Pin to the numbered hotbar (next open 1-9 slot)")
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(isArmed ? Color.yellow.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isArmed ? Color.yellow : Color.clear, lineWidth: 1.5)
                )
                .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                .id(entry.id)
            }
            .scrollPosition(id: $scrollAnchorObjectID)
            .frame(minHeight: 460, maxHeight: .infinity)
            .listStyle(.bordered)
        }
    }

    /// "Live 3D/2D thumbnail previews before spawning" (roadmap 6.2): a
    /// real offscreen 3D render (`ModelThumbnailRenderer`, same renderer
    /// the Models Hub gallery already uses) per resolvable entry, not a
    /// generic cube glyph standing in for "some model." Entries with no
    /// real geometry (yet) show one of two honestly-different states , 
    /// "Forge Palette anywhere"'s own requirement that "still checking"
    /// never look identical to "checked everywhere, genuinely nothing":
    /// a spinner with a distinct tooltip while `resolutionCache` is actively
    /// searching every other level on this disc, versus the static amber
    /// placeholder once that search has confirmed there's really nothing
    /// there.
    @ViewBuilder
    private func paletteThumbnail(for objectID: UInt16, resolvable: Bool) -> some View {
        if let thumbnail = thumbnailCache[objectID] {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if !resolvable {
            if resolutionCache.status(for: objectID) == .searching {
                ProgressView().controlSize(.mini)
                    .help("Searching every other level on this disc for this object's real geometry…")
            } else {
                Image(systemName: "cube.transparent")
                    .foregroundStyle(.orange)
                    .help("No geometry found on this disc; placing it drops a placeholder cube.")
            }
        } else if failedThumbnailIDs.contains(objectID) {
            Image(systemName: "cube.transparent")
                .foregroundStyle(.orange)
                .help("This object resolved to real geometry, but rendering its thumbnail failed.")
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    /// Same off-main-thread rendering posture as `ModelsHubView.
    /// loadThumbnailIfNeeded`, only skipped if already cached/failed, or
    /// if this entry has no real geometry to render in the first place.
    ///
    /// "Forge Palette anywhere": when `resolveForThumbnail` comes up empty
    /// (nothing in this level's own data, the shared `Default.rm2`, or an
    /// earlier global resolution), this does *not* fall into
    /// `failedThumbnailIDs`, that set means "a real render of a *resolved*
    /// asset failed," a genuinely different, permanent case from "nothing
    /// resolved here yet, but a background search might still find it
    /// somewhere else." Instead it hands off to `resolutionCache`, which
    /// starts (or no-ops onto an already-running/-confirmed) a bounded
    /// disc-wide search; if that search later succeeds, `canResolve` starts
    /// returning true for this ID (it re-reads `workspace.
    /// globalObjectThumbnails` live), the row's own `.task(id: resolvable)`
    /// re-fires, and this function runs again, this time reaching the real
    /// `resolveForThumbnail` branch below.
    private func loadThumbnailIfNeeded(for objectID: UInt16) {
        guard thumbnailCache[objectID] == nil, !failedThumbnailIDs.contains(objectID) else { return }
        guard let asset = resolveForThumbnail(objectID) else {
            resolutionCache.search(objectID: objectID, workspace: workspace)
            return
        }
        Task.detached(priority: .userInitiated) {
            let image = await ModelThumbnailRenderer.render(asset, size: 64)
            await MainActor.run {
                if let image {
                    thumbnailCache[objectID] = image
                } else {
                    failedThumbnailIDs.insert(objectID)
                }
            }
        }
    }
}

/// "Scenery" mode's real content, one continuous scrolling list, this
/// level's own scenery always first, every other real level in this
/// session streaming in right behind it as each one's catalog resolves.
/// Deliberately no level picker to click through first: every level
/// `WorkspaceViewModel.sceneryLevelSources` finds loads eagerly, in the
/// background, one at a time, a real level's own graphics file can be
/// several megabytes, so this is a genuinely honest cost (see the loading
/// counter at the bottom), not a hidden one. Click a real thumbnail to
/// place a new copy of it live in the viewport at the viewer's current
/// camera position, this level's own scenery places directly
/// (`LevelViewerRenderer.spawnScenery`); another level's scenery places
/// just as live, via a placeholder that only carries what a real
/// cross-file geometry copy needs (`LevelViewerRenderer
/// .spawnCrossLevelScenery`/`CrossLevelSceneryGeometrySource`), the
/// actual `CrossFileModelCopier` copy is deferred all the way to save
/// time (`WorkspaceViewModel.patchedFileBytes(insertingNewCrossLevelScenery:)`),
/// so neither case ever demands a save location up front. `SceneryModeView
/// .place(section:entry:key:)`'s own doc comment has the full story.
/// One level's scenery catalog, once resolved, `SceneryLoadCache`'s own
/// unit of storage.
struct SceneryModeSection: Identifiable {
    var id: String
    var displayName: String
    var isCurrentLevel: Bool
    var sceneryRoot: ChunkNode
    var sceneryBytes: Data
    var graphicsRoot: ChunkNode
    var graphicsBytes: Data
    var catalog: [WorkspaceViewModel.SceneryCatalogEntry]
}

/// Owns everything `SceneryModeView` would otherwise lose every time the
/// user leaves the Scenery tab and comes back, a real, reported bug:
/// `SceneryModeView` is one branch of `LevelEditorMode`'s `@ViewBuilder`
/// switch, so SwiftUI tears the whole view (and every `@State` it owned)
/// down the moment `editorMode` changes to anything else, and builds a
/// brand-new one, with loading started over from zero, the moment it
/// changes back. `LevelViewerWindow` holds the one instance of this class
/// as a `@StateObject`, which *does* survive that switch (its own
/// lifetime is the whole Level Viewer window, not one mode tab), and
/// hands the same instance to `SceneryModeView` every time regardless of
/// which mode tab is currently showing.
@MainActor
@Observable
final class SceneryLoadCache {
    /// The current level specifically, surfaced separately from the
    /// generic "N of 134 loaded" counter so "where's *my* level" always
    /// has a real, visible answer instead of silently blending into a
    /// queue position the user can't see. Real reported confusion: with
    /// only the generic counter, a current level that was slow (or
    /// genuinely had zero scenery) looked identical to one silently stuck.
    enum CurrentLevelStatus: Equatable {
        case loading
        case ready
        case empty
        /// Didn't turn up anywhere in `sceneryLevelSources` at all, a
        /// real, different failure from "still loading" or "empty."
        case notFound
        case failed(String)
    }

    var didStartLoading = false
    var currentLevelStatus: CurrentLevelStatus = .loading
    var sections: [SceneryModeSection] = []
    var totalSourceCount = 0
    var loadedCount = 0
    var thumbnailCache: [String: NSImage] = [:]
    var failedThumbnailIDs: Set<String> = []
    /// Real bug fix: `loadAllLevels()`'s per-level/per-lane `Task`s used to
    /// have no handle kept anywhere, so nothing ever cancelled them , 
    /// closing the Chunk Viewer window mid-load left every remaining level
    /// still extracting/parsing/resolving in the background against this
    /// now-orphaned cache. Reopening created a *fresh* `SceneryLoadCache`
    /// (`didStartLoading` on the new instance is false), so the whole run
    /// started over, in parallel with the still-running orphaned one,
    /// doubling the exact memory/CPU pressure this file's own "Scenery Tab
    /// Slowdown/Crash" fix (see `loadAllLevels`'s doc comment) exists to
    /// avoid. `LevelViewerWindow.onDisappear` cancels every task here.
    var loadTasks: [Task<Void, Never>] = []
}

struct SceneryModeView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    var cache: SceneryLoadCache
    let destinationSceneryFileRoot: ChunkNode
    /// The `"\(section.id)|\(entry.id)"` key of whichever tile is currently
    /// armed for placement (`LevelViewerWindow.armedScenery`), yellow-
    /// highlighted here the same way `ForgePaletteView`'s own armed row is,
    /// so it's clear at a glance which entry the next viewport click places.
    let armedKey: String?
    /// "Scenery placement, arm-then-click", a real, reported request: this
    /// used to place the model live immediately, at the viewer's own camera
    /// position (`LevelViewerRenderer.spawnScenery`/`spawnCrossLevelScenery`
    /// directly), the instant a thumbnail was clicked. Now it only *arms*
    /// placement mode, `LevelViewerWindow` sets `renderer.
    /// pendingPlacementScenery` and the actual spawn happens on the next
    /// real viewport click, matching every other placeable type in this
    /// build (Forge Palette objects, Instance/Trigger/Camera "Add").
    /// `crossLevelSource` is non-nil exactly when the model came from
    /// another level: the real cross-file geometry copy is deferred all the
    /// way to save time (see `CrossLevelSceneryGeometrySource`'s own doc
    /// comment), so arming never touches any file's bytes.
    let onArm: (_ key: String, _ modelID: UInt32, _ isSpecial: Bool, _ asset: ResolvedModelAsset, _ crossLevelSource: CrossLevelSceneryGeometrySource?) -> Void
    /// Real, reported bug: switching to a different mode tab and back (or
    /// this view just getting rebuilt at all, the same underlying
    /// `switch editorMode { ... }` in `LevelViewerWindow.modeContent` that
    /// tears down and recreates whichever mode's own view struct isn't
    /// currently selected) reset this scroll view straight back to the
    /// top every time, even after scrolling deep into "every real scenery
    /// model, every level" to find one specific entry. Owned by
    /// `LevelViewerWindow` itself (survives this view's own teardown/
    /// recreate, unlike a plain local `@State` here would) and bound to
    /// `.scrollPosition(id:)` below, SwiftUI keeps it updated as the user
    /// scrolls, and re-applies it to restore position the next time this
    /// view is built. Section-level granularity (not per-tile): coarser,
    /// but a single stable ID per whole section is far simpler than
    /// tracking exactly which tile was on-screen, and still solves the
    /// actual complaint ("I have to scroll all the way back down again").
    @Binding var scrollAnchorSectionID: String?

    private typealias Section = SceneryModeSection

    /// Still tracks the brief async window for a cross-level pick, where
    /// `arm(section:entry:key:)` has to resolve the destination graphics
    /// file before it can arm placement, same loading-spinner role
    /// `placingKey` always had, just no longer doubling as "this is what
    /// got placed" once arming replaced immediate placement.
    @State private var placingKey: String?
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Scenery", systemImage: "tree.fill").font(.headline)
            Text("Click a real thumbnail, then click in the viewport to place a new copy of it there. This level's own scenery is always first.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            currentLevelStatusView

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let statusMessage {
                Text(statusMessage).font(.caption2).foregroundStyle(.secondary)
            }

            if cache.didStartLoading, cache.sections.isEmpty, cache.loadedCount >= cache.totalSourceCount {
                Text("No real scenery models found anywhere this session.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(cache.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                section.isCurrentLevel ? "\(section.displayName) (this level)" : section.displayName,
                                systemImage: section.isCurrentLevel ? "star.fill" : "doc.text"
                            )
                            .font(.subheadline.bold())
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 92), spacing: 8)], spacing: 8) {
                                ForEach(section.catalog) { entry in
                                    tile(section: section, entry: entry)
                                }
                            }
                        }
                        .id(section.id)
                        Divider()
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 4)
            }
            .scrollPosition(id: $scrollAnchorSectionID)
            .frame(minHeight: 420, maxHeight: .infinity)

            if cache.didStartLoading, cache.loadedCount < cache.totalSourceCount {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading other levels… (\(cache.loadedCount)/\(cache.totalSourceCount)), already-loaded ones above are ready to click now.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { loadAllLevels() }
    }

    @ViewBuilder
    private var currentLevelStatusView: some View {
        switch cache.currentLevelStatus {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading this level's own scenery…").font(.caption2).foregroundStyle(.secondary)
            }
        case .ready:
            EmptyView()
        case .empty:
            Label("This level's own scenery data decoded to zero placements.", systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .notFound:
            Label("Couldn't identify this level among the levels this session can browse, its scenery won't appear here.", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .failed(let reason):
            Label("This level's own scenery failed to load: \(reason)", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func tile(section: Section, entry: WorkspaceViewModel.SceneryCatalogEntry) -> some View {
        let key = "\(section.id)|\(entry.id)"
        let isArmed = armedKey == key
        return Button {
            arm(section: section, entry: entry, key: key)
        } label: {
            VStack(spacing: 3) {
                thumbnail(key: key, entry: entry)
                    .frame(width: 64, height: 64)
                    .onAppear { loadThumbnailIfNeeded(key: key, entry: entry) }
                Text(entry.asset.displayName).font(.caption2).lineLimit(1)
                Text("×\(entry.count)").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            // Same yellow highlight `ForgePaletteView`'s own armed row uses
            //, a real, reported request that scenery placement look and
            // feel like every other placeable type in this build.
            .background(isArmed ? Color.yellow.opacity(0.28) : Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isArmed ? Color.yellow : (placingKey == key ? Color.accentColor : Color.clear), lineWidth: isArmed ? 1.5 : 2)
            )
        }
        .buttonStyle(.plain)
        .disabled(placingKey != nil)
        .help("Click, then click in the viewport, to place a new copy of \(entry.asset.displayName) there")
    }

    @ViewBuilder
    private func thumbnail(key: String, entry: WorkspaceViewModel.SceneryCatalogEntry) -> some View {
        if placingKey == key {
            ProgressView().controlSize(.small)
        } else if let image = cache.thumbnailCache[key] {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if cache.failedThumbnailIDs.contains(key) {
            Image(systemName: "cube.transparent")
                .font(.title2)
                .foregroundStyle(.orange)
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    private func loadThumbnailIfNeeded(key: String, entry: WorkspaceViewModel.SceneryCatalogEntry) {
        guard cache.thumbnailCache[key] == nil, !cache.failedThumbnailIDs.contains(key) else { return }
        let asset = entry.asset
        Task.detached(priority: .userInitiated) {
            let image = await ModelThumbnailRenderer.render(asset, size: 64)
            await MainActor.run {
                if let image {
                    cache.thumbnailCache[key] = image
                } else {
                    cache.failedThumbnailIDs.insert(key)
                }
            }
        }
    }

    /// `cache.didStartLoading` makes this a real no-op on every mode-tab
    /// re-entry after the first, `cache` itself is what actually survives
    /// the tab switch (see `SceneryLoadCache`'s own doc comment); without
    /// it this used to restart all ~130+ levels from zero on every single
    /// visit to this tab, a real reported bug.
    ///
    /// This level loads on its own dedicated `Task`, never queued behind
    /// anything else, a real reported complaint that waiting on 130+
    /// other levels before even *this* one's own scenery showed up
    /// defeated the entire point of "this level first." Every other level
    /// loads across a handful of concurrent lanes (not one long queue)
    /// so what's already resolved keeps appearing without waiting on the
    /// slowest remaining file, plain parallel `Task`s, not a `TaskGroup`,
    /// specifically to avoid the `Sendable`-capture hazards a `TaskGroup`
    /// closing over this View's own `@State`/`ChunkNode`/
    /// `WorkspaceViewModel` would raise.
    private func loadAllLevels() {
        guard !cache.didStartLoading else { return }
        cache.didStartLoading = true
        let sources = workspace.sceneryLevelSources(excluding: nil)
        cache.totalSourceCount = sources.count
        guard !sources.isEmpty else { return }

        // Real bug this fixes: matching by `openFileRoot === destinationSceneryFileRoot`
        // alone only ever recognized a level opened as a genuinely
        // standalone loose file. The much more common real case, a level
        // reached by browsing into a mounted archive/ISO, lives as a
        // *nested child* of the archive's own root, never a top-level
        // `rootNodes` entry itself, so `otherLevelSceneryFileRoots` (which
        // only filters `rootNodes` directly) never matched it; it fell
        // into `sceneryLevelSources`'s generic name-only archive-entry
        // list instead, indistinguishable from any other level and queued
        // behind however many others happened to sort before it. Matching
        // by bare filename catches both shapes uniformly, since
        // `SceneryLevelSource.displayName` is always just the bare
        // filename either way.
        let currentLevelSource = sources.first { isDestinationLevel(named: $0.displayName) }
        let otherSources = sources.filter { !isDestinationLevel(named: $0.displayName) }

        if let currentLevelSource {
            cache.loadTasks.append(Task { await loadOneLevel(currentLevelSource) })
        } else {
            cache.currentLevelStatus = .notFound
        }

        // "Scenery Tab Slowdown/Crash" fix: each lane's `loadOneLevel` does
        // real, heavy CPU work per level -- archive extraction, a full
        // chunk-tree parse, `AssetResolver.buildIndex`, and resolving
        // every distinct model to a complete `ResolvedModelAsset` (mesh +
        // decoded texture pixels) -- and every result stays in `cache
        // .sections` for the rest of this Level Viewer session (see
        // `SceneryLoadCache`'s own doc comment; nothing here ever evicts
        // an entry). A real disc's `sceneryLevelSources` is 100+ levels,
        // so 4 concurrent lanes raced through all of them at once with no
        // bound at all, real, reported crashes, not just sluggishness.
        // Halving peak concurrency directly halves peak memory pressure
        // and CPU contention while this runs; every level still finishes
        // loading eventually (nothing here was removed), it just ramps up
        // less aggressively.
        let laneCount = min(2, max(1, otherSources.count))
        for lane in 0..<laneCount {
            let laneSources = stride(from: lane, to: otherSources.count, by: laneCount).map { otherSources[$0] }
            cache.loadTasks.append(Task {
                for source in laneSources {
                    // See `SceneryLoadCache.loadTasks`'s own doc comment , 
                    // checked between levels (not just relying on
                    // structured-concurrency cancellation propagating
                    // through `loadOneLevel`'s own awaits) so a cancelled
                    // lane stops starting new, heavy per-level work
                    // promptly instead of grinding through everything left
                    // in its queue after the window's already closed.
                    guard !Task.isCancelled else { return }
                    await loadOneLevel(source)
                }
            })
        }
    }

    private func loadOneLevel(_ source: WorkspaceViewModel.SceneryLevelSource) async {
        let isCurrent = isDestinationLevel(named: source.displayName)
        guard let loaded = await workspace.loadingSceneryLevelSource(source) else {
            cache.loadedCount += 1
            if isCurrent { cache.currentLevelStatus = .failed(workspace.lastError ?? "Couldn't load \(source.displayName).") }
            return
        }
        let catalog = await workspace.resolvedSceneryCatalog(sceneryRoot: loaded.sceneryRoot)
        cache.loadedCount += 1
        guard !catalog.isEmpty else {
            if isCurrent { cache.currentLevelStatus = .empty }
            return
        }
        let section = Section(
            id: source.id, displayName: source.displayName,
            isCurrentLevel: isCurrent,
            sceneryRoot: loaded.sceneryRoot, sceneryBytes: loaded.sceneryBytes,
            graphicsRoot: loaded.graphicsRoot, graphicsBytes: loaded.graphicsBytes,
            catalog: catalog
        )
        if section.isCurrentLevel {
            cache.currentLevelStatus = .ready
            cache.sections.insert(section, at: 0)
        } else {
            cache.sections.append(section)
        }
    }

    /// Real bug this fixes: `sceneryRoot === destinationSceneryFileRoot`
    /// (reference identity) only matches when the source came from
    /// `.openFile`, an archive-entry source is freshly parsed each time
    /// (a brand-new `ChunkNode`, never the same object), so it always
    /// failed this check even when it genuinely *is* the destination
    /// level, silently taking the cross-file copy path (and needing
    /// `loadingDestinationGraphics` to independently succeed) instead of
    /// the simpler, always-correct same-file duplicate. Bare-filename
    /// comparison is robust to both shapes.
    ///
    /// Real bug this ALSO fixes (see `LevelDisplayNameMatching`'s own doc
    /// comment): this used to compare `displayName` directly against
    /// `destinationSceneryFileRoot.displayName` with no normalization on
    /// the destination side, so a destination level reached by browsing a
    /// mounted disc/archive (whose `displayName` is a full archive path,
    /// not a bare filename) could never match, producing "Couldn't
    /// identify this level" in Scenery mode.
    private func isDestinationLevel(named displayName: String) -> Bool {
        LevelDisplayNameMatching.isSameLevel(displayName, destinationSceneryFileRoot.displayName)
    }

    /// Regression fix, the real, original bug: clicking a thumbnail used
    /// to immediately compute final file bytes and demand a native save
    /// panel before the object was ever visible. That was fixed by placing
    /// live in the viewport instead, but still immediately, at the
    /// camera's own position, unlike every other placeable type in this
    /// build. This is the second fix on top of that: clicking a thumbnail
    /// now only arms placement (`onArm`, wired to `LevelViewerRenderer.
    /// pendingPlacementScenery`); the actual `spawnScenery`/
    /// `spawnCrossLevelScenery` call happens on the next real viewport
    /// click, exactly like the Forge Palette's own object placement.
    private func arm(section: Section, entry: WorkspaceViewModel.SceneryCatalogEntry, key: String) {
        guard placingKey == nil else { return }
        errorMessage = nil

        if section.isCurrentLevel {
            // Same level: `entry.modelID`/`isSpecial` already resolve
            // here directly (that's what proved this thumbnail placeable
            // in the first place), no geometry copy needed, no async
            // resolve step, arms immediately.
            onArm(key, entry.modelID, entry.isSpecial, entry.asset, nil)
            statusMessage = "Armed \(entry.asset.displayName), click in the viewport to place it, then \"Save Chunk Overrides…\" to write it to disk."
            return
        }

        // Cross-level (borrowing another level's real geometry into this
        // one): only the destination graphics *file* needs resolving before
        // arming, the actual byte copy itself is deferred all the way to
        // save time (see `CrossLevelSceneryGeometrySource`'s own doc
        // comment), so this never computes final file bytes or demands a
        // save location.
        placingKey = key
        Task {
            guard let destinationGraphics = await workspace.loadingDestinationGraphics(for: destinationSceneryFileRoot) else {
                placingKey = nil
                errorMessage = workspace.lastError ?? "Couldn't reach this level's own .rm2 to copy geometry into."
                return
            }
            let source = CrossLevelSceneryGeometrySource(
                sourceModelID: entry.modelID, sourceIsSpecial: entry.isSpecial,
                sourceSceneryFileRoot: section.sceneryRoot, sourceSceneryBytes: section.sceneryBytes,
                sourceGraphicsRoot: section.graphicsRoot, sourceGraphicsBytes: section.graphicsBytes,
                destinationGraphicsRoot: destinationGraphics.graphicsRoot
            )
            placingKey = nil
            onArm(key, entry.modelID, false, entry.asset, source)
            statusMessage = "Armed \(entry.asset.displayName) (borrowed from \(section.displayName)), click in the viewport to place it, then \"Save Chunk Overrides…\" to copy its geometry in and write both files to disk."
        }
    }
}
