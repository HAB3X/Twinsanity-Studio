import Foundation
import CTCore

/// A type that represents a disc-mounted file entry and its source, used
/// by `ChunkNode.prunedOfRawContent()` to determine whether a node
/// corresponds to a disc-mounted file that should be shown despite not
/// having a recognizable chunk file extension.
public protocol DiscEntrySource: Sendable {
    /// The disc entry (e.g. an `ISO9660Entry`).
    var entry: any Sendable { get }
    /// The logical sector source containing the entry's data.
    var source: any Sendable { get }
}

/// A simple holder for disc entry and source that conforms to DiscEntrySource.
/// Used to store disc-mounted file information in `WorkspaceViewModel.discEntryByNodeID`.
///
/// `entry`/`source` are typed `any Sendable` rather than plain `Any` , 
/// `CTModels` can't import `CTParsers` (module layering: `ChunkNode.
/// prunedOfRawContent` needs to accept a registry of these without
/// knowing the concrete `ISO9660Entry`/`LogicalSectorSource` types), so
/// some form of type erasure at this boundary is unavoidable. `any
/// Sendable` keeps that erasure while still making the `Sendable`
/// conformance above real and compiler-checked: a plain `Any` stored
/// property makes a `Sendable` struct's own conformance unverifiable (the
/// compiler can't prove an arbitrary boxed value is safe to send across
/// an isolation boundary), where `any Sendable` can only ever box a value
/// whose own type already proved it. Both real payloads used today
/// (`ISO9660Entry`, `any LogicalSectorSource`) are already `Sendable`, so
/// this changes no behavior at any call site, `holder.entry as?
/// ISO9660Entry` downcasts the same way from either.
public struct DiscEntryHolder: DiscEntrySource {
    public let entry: any Sendable
    public let source: any Sendable

    public init(entry: any Sendable, source: any Sendable) {
        self.entry = entry
        self.source = source
    }
}

/// Decoded payload attached to a leaf `ChunkNode`, when the parser understands
/// that record's contents. Sections (which only hold child records) carry `nil`.
public enum ChunkPayload: Sendable {
    case texture(TextureAsset)
    case mesh(MeshAsset)
    case rigidModel(RigidModelInfo)
    case material(MaterialInfo)
    case skeleton(SkeletonAsset)
    case animation(AnimationAsset)
    case position(PositionMarker)
    case instance(PlacedInstance)
    case trigger(TriggerVolume)
    case camera(PlacedCamera)
    case collision(CollisionMesh)
    case scenery(SceneryAsset)
    case dynamicScenery(DynamicSceneryAsset)
    case soundEffect(SoundEffectAsset)
    /// A Xbox `SoundEffectX` record, structurally decoded but not
    /// PCM-decoded (no confirmed codec, see `SoundEffectXInfo`'s doc
    /// comment). Distinct from `.soundEffect` since it isn't playable the
    /// same way.
    case soundEffectX(SoundEffectXInfo)
    /// An `InstanceTemplate`/`InstanceTemplateDemo` record.
    case instanceTemplate(InstanceTemplateInfo)
    case instanceTemplateDemo(InstanceTemplateDemoInfo)
    /// The Demo/Monkey Ball build's own `Instance` variant, see
    /// `PlacedInstanceDemo`/`PlacedInstanceMB`'s own doc comments.
    case instanceDemo(PlacedInstanceDemo)
    case instanceMB(PlacedInstanceMB)
    /// "Chunk-Based Architecture": a `ChunkLinks` record, the real,
    /// decoded list of neighboring `.SM2`/`.RM2` chunk files this chunk
    /// streams in, plus the boundary geometry that triggers it. See
    /// `ChunkLinksAsset`'s doc comment.
    case chunkLinks(ChunkLinksAsset)
    /// "AI Pathfinding/Navmesh Editor" (roadmap 5.1): a real `AIPosition`
    /// waypoint. See `AIPositionMarker`'s doc comment.
    case aiPosition(AIPositionMarker)
    /// A real `AIPath` record, 5 raw arguments, no position of its own
    /// and no confirmed linkage to any `AIPosition`. See `AIPathRecord`'s
    /// doc comment for why this build doesn't guess at a connection graph.
    case aiPath(AIPathRecord)
    /// A `LodModel` record, see `LodModelInfo`'s doc comment for why this
    /// was the real root cause of scenery objects silently vanishing.
    case lodModel(LodModelInfo)
    /// A `GameObject` record, see `GameObjectInfo`'s own doc comment.
    /// Plumbing (`Instance.objectID` -> this -> a `GraphicsInfo`/mesh),
    /// same reasoning as `.material` below, not a filterable kind of its
    /// own.
    case gameObject(GameObjectInfo)
    /// A `CollisionSurface` record, see `CollisionSurfaceInfo`'s doc
    /// comment. Plumbing cross-referenced *by value* from a `ColData`
    /// triangle's `surfaceID`, not something browsed directly, same
    /// reasoning as `.material`/`.gameObject` above.
    case collisionSurface(CollisionSurfaceInfo)
    /// A `Skydome` record, see `SkydomeInfo`'s doc comment. Typically a
    /// singleton per file (the level's sky mesh reference), not a
    /// filterable collection.
    case skydome(SkydomeInfo)
    /// A `Path` record, see `PathAsset`'s doc comment: a real position
    /// list plus per-point float params, distinct from both `Position`
    /// (one point) and `AIPosition`/`AIPath` (AI waypoints specifically).
    case path(PathAsset)
    /// A `ParticleData` record, see `ParticleDataAsset`'s doc comment.
    /// Typically a singleton per file (the level's particle-effect
    /// library: named recipes plus their world placements), not a
    /// filterable collection, same reasoning as `.skydome`.
    case particleData(ParticleDataAsset)
    /// A `Script`/`ScriptX`/`ScriptDemo` record, the AI condition/state-
    /// machine system. See `ScriptAsset`'s doc comment.
    case script(ScriptAsset)
    /// A `CustomAgent`/`CustomAgentX`/`CustomAgentDemo` record (`CodeModel`
    /// in the reference source), a small "Key"-indexed table of script
    /// references, real, decoded, but not yet wired into any resolution
    /// path this build understands. See `CustomAgentParser`'s doc comment
    /// for the exact on-disk layout.
    case customAgent(CustomAgentRecord)
    /// A `ModelX` record (Xbox static mesh, `SectionType.modelX`), see
    /// `XboxMeshAssets.swift`'s top-of-file doc comment for how confirmed
    /// this real (non-VIF) layout is.
    case xboxModel(XboxModelXAsset)
    /// A `SkinX` record (Xbox skinned mesh, `SectionType.skinX`).
    case xboxSkin(XboxSkinXAsset)
    /// A `BlendSkinX` record (Xbox skinned + morph-target mesh,
    /// `SectionType.blendSkinX`), "Xbox Morphs" (roadmap item 4e).
    case xboxBlendSkin(XboxBlendSkinXAsset)
    /// Understood record kind, but not (yet) decoded into a typed model , 
    /// still browsable/exportable as a hex/raw blob.
    case raw(byteCount: Int)

    /// Coarse category used for type-based filtering (e.g. "show me every
    /// animation in the archive"), distinct from `SectionType`, which
    /// distinguishes many more format-level record kinds than a user
    /// browsing by *asset kind* cares about. Materials are deliberately not
    /// a filterable kind of their own, they're plumbing (mesh -> material
    /// -> texture), not something a user browses for directly.
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case texture = "Textures"
        case model = "Models"
        case skeleton = "Skeletons"
        case animation = "Animations"
        case instance = "Entities"
        case trigger = "Triggers"
        case camera = "Cameras"
        case collision = "Collision"
        case soundEffect = "Audio"
        case chunkLinks = "Chunk Links"
        case aiWaypoint = "AI Waypoints"
        case scenery = "Scenery"
        case path = "Paths"
        public var id: String { rawValue }
    }

    public var kind: Kind? {
        switch self {
        case .texture: return .texture
        case .mesh, .rigidModel, .xboxModel, .xboxSkin, .xboxBlendSkin: return .model
        case .skeleton: return .skeleton
        case .animation: return .animation
        case .instance, .instanceDemo, .instanceMB: return .instance
        case .trigger: return .trigger
        case .camera: return .camera
        case .collision: return .collision
        case .soundEffect, .soundEffectX: return .soundEffect
        case .chunkLinks: return .chunkLinks
        case .aiPosition, .aiPath: return .aiWaypoint
        case .scenery, .dynamicScenery: return .scenery
        case .path: return .path
        case .material, .position, .gameObject, .lodModel, .collisionSurface, .skydome, .particleData, .script, .raw,
             .instanceTemplate, .instanceTemplateDemo, .customAgent:
            return nil
        }
    }
}

/// A node in the RM2/SM2 chunk tree, used directly by the sidebar's
/// `OutlineGroup` and by the search/filter model. Reference type: these trees
/// can have thousands of nodes for a full level, and SwiftUI's `OutlineGroup`
/// performs far better walking identity-stable class instances than diffing
/// deeply nested value-type arrays on every render.
///
/// `@unchecked Sendable`: a tree is built single-threaded inside one parse
/// call (see `RM2Parser`/`WorkspaceViewModel.scanAllArchives`'s parse
/// task), never mutated concurrently from more than one task while being
/// built, and behaves like an immutable value once handed across a task/
/// actor boundary -- *as long as the receiver got its own copy*.
/// `rootNodes`' live trees keep getting mutated in place afterward on the
/// main actor (`expandArchiveEntry`'s lazy-load replacement,
/// `applyBulkScan`'s post-scan update), so any code that looks up a node
/// still reachable from `rootNodes` and hands *that same reference* to a
/// background `Task` is not actually safe, it's an unsynchronized
/// concurrent read/write race on a reference type, the compiler just can't
/// see it because of this very annotation. Use `deepCopy()` to take a real,
/// independent snapshot before crossing into a background `Task` whenever
/// the live tree could still be mutated on the main actor while that task
/// runs (see `WorkspaceViewModel.resolvedLevelPlacements`/
/// `resolvedInstanceAssets` for the pattern).
public final class ChunkNode: Identifiable, @unchecked Sendable {
    /// Was `let id = UUID()` (always freshly minted), see `filtered(matching:)`/
    /// `filtered(byKind:)`'s doc comments for why that was a real, user-facing
    /// bug: it's now a settable-at-init identity so a filtered *view* of an
    /// existing node can preserve that node's real identity instead of
    /// inventing a new one every time the filter re-runs.
    public let id: UUID
    public var recordID: UInt32
    public var sectionType: SectionType
    public var displayName: String
    public var byteSize: Int
    public var children: [ChunkNode]
    public var payload: ChunkPayload?
    /// Absolute byte offset of this record's data in the originating file, kept
    /// for the inspector's "jump to hex" affordance and for re-injection.
    public var fileOffset: Int
    /// A generic escape hatch alongside `looksLikeChunkFileName`'s
    /// extension-based check in `prunedOfRawContent` below: a real record
    /// this build knows exists and can lazily decode on selection, but
    /// whose display name carries no recognizable file extension to key
    /// off of (e.g. one numbered clip inside a mounted sound archive, not
    /// a file in its own right). Without this, "Smart File Filtering"'s
    /// default pruning would hide such a node before it could ever be
    /// clicked to trigger its own lazy load -- the same "unexpanded but
    /// real" carve-out the extension check already makes for an unparsed
    /// `.RM2`/`.GSC` file, generalized past "has a file extension."
    /// `false` for every ordinary node.
    public var isLazyLoadable: Bool

    public init(
        id: UUID = UUID(),
        recordID: UInt32,
        sectionType: SectionType,
        displayName: String,
        byteSize: Int,
        fileOffset: Int,
        children: [ChunkNode] = [],
        payload: ChunkPayload? = nil,
        isLazyLoadable: Bool = false
    ) {
        self.id = id
        self.recordID = recordID
        self.sectionType = sectionType
        self.displayName = displayName
        self.byteSize = byteSize
        self.fileOffset = fileOffset
        self.children = children
        self.payload = payload
        self.isLazyLoadable = isLazyLoadable
    }

    public var isLeaf: Bool { children.isEmpty }

    /// A fully independent copy of this node and every descendant, new
    /// `ChunkNode` instances throughout, sharing no reference with `self`
    /// or any of its children. Unlike `filtered(matching:)`/`filtered(byKind:)`,
    /// which reuse the original `children` array by reference whenever a
    /// node matches itself, this recreates every node in the subtree.
    ///
    /// Needed because this type's own `@unchecked Sendable` doc comment
    /// above asserts a tree "behaves like an immutable value" once handed
    /// across an actor boundary, true only as long as nothing still holds
    /// a *live* reference to the same nodes back on the main actor. Async
    /// resolvers that look up a file's root via `findFileRoot` and hand it
    /// straight to a background `Task` were doing exactly that: the same
    /// root (and its `children` array) can still be mutated in place on
    /// the main actor (`expandArchiveEntry`'s lazy-load replacement,
    /// `applyBulkScan`'s post-scan update) while the background task is
    /// mid-read, an unsynchronized concurrent read/write race on a
    /// reference type. Deep-copying the subtree once, synchronously,
    /// before handing it to the background task closes that gap, the
    /// copy can never be touched by a later main-actor mutation of the
    /// live tree, because it shares no node with it.
    public func deepCopy() -> ChunkNode {
        ChunkNode(
            id: id,
            recordID: recordID,
            sectionType: sectionType,
            displayName: displayName,
            byteSize: byteSize,
            fileOffset: fileOffset,
            children: children.map { $0.deepCopy() },
            payload: payload,
            isLazyLoadable: isLazyLoadable
        )
    }

    /// Depth-first search across this node and its descendants for nodes whose
    /// display name or section type contains `query` (case-insensitive).
    ///
    /// Returns a *view* over the matching subset, not a copy with a new
    /// identity, critically, `id: self.id` below. This used to omit `id:`,
    /// which let the synthesized `ChunkNode(id: UUID())` default mint a
    /// fresh random UUID for every filtered node, on every single
    /// evaluation of this (uncached, computed-property-backed) filter. In
    /// the sidebar, clicking a filtered row round-trips through exactly two
    /// separate evaluations of `filteredRootNodes` (once to tag the row
    /// when the `List` renders, once again inside the selection
    /// `Binding`'s `set` to look the clicked id back up), with fresh IDs
    /// each time, the id captured by the click could never match anything
    /// in the freshly-recomputed tree, `findNode` always returned `nil`,
    /// and `select(nil)` silently wiped the entire selection. Every click
    /// on a filtered item looked like it "closed all the files." Preserving
    /// the real underlying node's `id` here makes a filtered node's
    /// identity stable across every re-evaluation, exactly like the
    /// unfiltered tree's already was.
    public func filtered(matching query: String) -> ChunkNode? {
        guard !query.isEmpty else { return self }
        let matchesSelf = displayName.localizedCaseInsensitiveContains(query)
            || sectionType.rawValue.localizedCaseInsensitiveContains(query)
            || String(recordID).contains(query)
        let matchingChildren = children.compactMap { $0.filtered(matching: query) }
        guard matchesSelf || !matchingChildren.isEmpty else { return nil }
        let node = ChunkNode(
            id: id,
            recordID: recordID,
            sectionType: sectionType,
            displayName: displayName,
            byteSize: byteSize,
            fileOffset: fileOffset,
            children: matchesSelf ? children : matchingChildren,
            payload: payload,
            isLazyLoadable: isLazyLoadable
        )
        return node
    }

    /// Depth-first search across this node and its descendants for nodes
    /// whose decoded payload matches `kind` (e.g. every `Animation` record
    /// anywhere under this node, no matter how deep). Ancestors of a match
    /// are kept so the result is still a navigable tree, not a flat list.
    /// See `filtered(matching:)`'s doc comment, `id: self.id` here fixes
    /// the exact same identity bug for the type-filter picker.
    public func filtered(byKind kind: ChunkPayload.Kind) -> ChunkNode? {
        let matchesSelf = payload?.kind == kind
        let matchingChildren = children.compactMap { $0.filtered(byKind: kind) }
        guard matchesSelf || !matchingChildren.isEmpty else { return nil }
        return ChunkNode(
            id: id,
            recordID: recordID,
            sectionType: sectionType,
            displayName: displayName,
            byteSize: byteSize,
            fileOffset: fileOffset,
            children: matchesSelf ? children : matchingChildren,
            payload: payload,
            isLazyLoadable: isLazyLoadable
        )
    }

    /// "Smart File Filtering": recursively drops undecoded/raw leaves
    /// (payload `.none`/`.raw`) and any container whose entire subtree
    /// pruned away, the "hide folders that only contain raw files" half of
    /// the same feature. `nil` means "this whole node is uninteresting,
    /// drop it"; a non-`nil` result always preserves `id: self.id` on every
    /// surviving node, same reasoning as `filtered(matching:)`'s own doc
    /// comment: a filtered *view* must keep the real node's identity, or
    /// sidebar selection breaks exactly like it did before that fix.
    ///
    /// - Parameter discEntryRegistry: Registry of disc-mounted files that
    ///   should be shown despite not having recognizable chunk file
    ///   extensions. Used to prevent disc image contents from being filtered
    ///   out as "raw" content.
    public func prunedOfRawContent(discEntryRegistry: [UUID: any DiscEntrySource]? = nil) -> ChunkNode? {
        guard !children.isEmpty else {
            // An unexpanded archive entry (`.RM2`/`.SM2`/etc. sitting inside
            // a `.BH` archive, not yet parsed) looks identical to a genuinely
            // uninteresting leaf at this point, no children, `payload ==
            // nil`, but it's the exact opposite: it's a real file the user
            // can still click "Parse" on (see `WorkspaceViewModel.
            // isExpandableArchiveEntry`), and every archive starts with
            // hundreds of these before scanning finishes. Pruning it away
            // would hide the entire unscanned tree, not just raw junk.
            if payload == nil, byteSize > 0, (Self.looksLikeChunkFileName(displayName) || isLazyLoadable) {
                return self
            }
            switch payload {
            case .none, .raw: return nil
            default: return self
            }
        }
        let keptChildren = children.compactMap { $0.prunedOfRawContent(discEntryRegistry: discEntryRegistry) }
        guard !keptChildren.isEmpty else { return nil }
        return ChunkNode(
            id: id,
            recordID: recordID,
            sectionType: sectionType,
            displayName: displayName,
            byteSize: byteSize,
            fileOffset: fileOffset,
            children: keptChildren,
            payload: payload,
            isLazyLoadable: isLazyLoadable
        )
    }

    /// Same "does this filename look like a chunk file" check
    /// `WorkspaceViewModel`/`WorkspaceAutoDetector` each already make their
    /// own way (extension-based, no magic-number peek needed at this
    /// layer), small enough, and different enough in what each caller
    /// already has on hand, that sharing one implementation across module
    /// boundaries wasn't worth it; this one only needs a display name.
    private static func looksLikeChunkFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.uppercased()
        if ["RM2", "SM2", "RMX", "SMX", "GSC"].contains(ext) { return true }
        // WoC's centralized sound archives -- not chunk-headered like the
        // rest of this list, but the same "real file, not yet expanded"
        // shape applies once mounted from a disc image (see
        // `WorkspaceViewModel.expandWOCSoundArchive`).
        let upper = name.uppercased()
        return upper == "SFX.DAT" || upper == "ATS.DAT"
    }
}
