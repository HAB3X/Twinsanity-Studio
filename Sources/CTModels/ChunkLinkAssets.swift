import Foundation
import simd

/// One node of a `ChunkLink`'s optional load-zone chain (`LinkTree` in the
/// reference tool's `ChunkLinks.cs`), real per-boundary geometry describing
/// the volume that triggers streaming the adjoining chunk in. Present only
/// when the owning `ChunkLink.type` has bit 0 set.
///
/// `undecodedBlob` mirrors the reference tool exactly: even
/// `ChunkLinksController`'s own `GenText()` only ever prints the 11-value
/// `giHeader`, never interprets the trailing blob, so this build keeps it
/// as opaque bytes rather than guessing a shape for it.
public struct ChunkLinkTreeNode: Sendable, Codable {
    /// Raw "does another node follow" gate read for *this* node, the next
    /// `ReadTree` call in the reference tool is gated on this value, not on
    /// a separate boolean, so it's kept verbatim for round-tripping.
    public var header: Int32
    public var giHeader: [UInt16]
    /// The load-trigger volume itself, 8 points, same shape as a
    /// `GI_CollisionData` corner block (see `ModelViewerRenderer.
    /// collisionBoxEdges`, which this can reuse as-is).
    public var loadArea: [SIMD4<Float>]
    public var areaMatrix: [SIMD4<Float>]
    public var unknownMatrix: [SIMD4<Float>]
    public var undecodedBlob: Data

    public init(header: Int32, giHeader: [UInt16], loadArea: [SIMD4<Float>], areaMatrix: [SIMD4<Float>], unknownMatrix: [SIMD4<Float>], undecodedBlob: Data) {
        self.header = header
        self.giHeader = giHeader
        self.loadArea = loadArea
        self.areaMatrix = areaMatrix
        self.unknownMatrix = unknownMatrix
        self.undecodedBlob = undecodedBlob
    }
}

/// One adjoining-chunk reference (`ChunkLink` in the reference tool's
/// `ChunkLinks.cs`), `path` names the neighboring `.SM2`/`.RM2` chunk file,
/// `chunkMatrix` is that neighbor's placement transform in this chunk's own
/// coordinate space, and `loadWall` (when present) is the literal boundary
/// quad the reference tool's own field calls a "load wall." Ported field-for
/// -field from real, decoded `ChunkLinks` records, not a guess at a chunk-
/// streaming model, an actual one present in the game's own data.
public struct ChunkLink: Sendable, Identifiable, Codable {
    public let id: Int
    public var type: Int32
    /// Labeled "Directory" by the reference tool's own `ChunkLinksController.
    /// GenText()`, the neighboring chunk file this link points at.
    public var path: String
    public var flags: UInt32
    /// 4-row matrix (see `SkinTransform`'s doc comment for the same
    /// row-array convention already used elsewhere in this codebase) , 
    /// this link's own placement within its owning chunk.
    public var objectMatrix: [SIMD4<Float>]
    /// 4-row matrix aligning the neighboring chunk file into this chunk's
    /// coordinate space.
    public var chunkMatrix: [SIMD4<Float>]
    /// The boundary quad (4 corners), present only when `flags & 0x80000`
    /// is set.
    public var loadWall: [SIMD4<Float>]?
    /// Flattened `LinkTree` chain, empty when `type & 0x1 == 0`.
    public var treeNodes: [ChunkLinkTreeNode]

    public var hasTree: Bool { (type & 0x1) != 0 }
    public var hasWall: Bool { (flags & 0x80000) != 0 }

    public init(id: Int, type: Int32, path: String, flags: UInt32, objectMatrix: [SIMD4<Float>], chunkMatrix: [SIMD4<Float>], loadWall: [SIMD4<Float>]?, treeNodes: [ChunkLinkTreeNode]) {
        self.id = id
        self.type = type
        self.path = path
        self.flags = flags
        self.objectMatrix = objectMatrix
        self.chunkMatrix = chunkMatrix
        self.loadWall = loadWall
        self.treeNodes = treeNodes
    }
}

/// The full `ChunkLinks` record, every neighboring-chunk reference declared
/// by one `.SM2` file. Ported from `Twinsanity/Items/ChunkLinks.cs`.
public struct ChunkLinksAsset: Sendable, Identifiable, Codable {
    public let id: UInt32
    public var links: [ChunkLink]

    public init(id: UInt32, links: [ChunkLink]) {
        self.id = id
        self.links = links
    }
}
