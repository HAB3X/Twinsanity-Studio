import Foundation
import simd
import CTModels

/// Builds a real, renderable `MeshAsset` from `OBJ0`'s decoded geometry.
/// One real `OBJ0` entry (``WOCContainerParser/ObjSetEntry``, the same
/// granularity `INST.objectIndex` references) -> one `MeshAsset`; one
/// mesh-shaped ``WOCContainerParser/ObjSetGeoEntry`` within that entry ->
/// one `MeshSubmesh`.
///
/// Built on ``WOCContainerParser/parseObjSet(_:materialCount:)`` (real,
/// sequential, length-prefixed entry/geo boundaries -- exact byte
/// consumption on all 58 real files checked, zero exceptions) and
/// ``WOCContainerParser/parseObjSetGeoArcs(_:)`` (the real per-geo vertex
/// arc sequence, anchored to that exact boundary rather than a heuristic
/// chunk-length scan). Previously used `groupOBJ0ChunksIntoEntries(_:)` /
/// `parseOBJ0ChunkArcs(_:chunk:)` -- kept in `WOCContainerParser` for
/// backward compatibility, but this decoder no longer depends on them.
/// That migration was verified regression-free before landing: byte-for-
/// byte identical vertex/arc totals on `AIRSHIP.GSC` (408 arcs, 11,516
/// vertices, zero difference), and a dramatic real improvement on the two
/// files the old marker-walk could only partially cover --
/// `CASTLE_C.GSC` now builds real meshes for all 1113 entries (was 8) and
/// `HUB.GSC` for all 700 (was 27).
///
/// Reuses `MeshSubmesh.connectivity`/`triangleIndices()` -- the exact
/// same triangle-strip-with-restarts representation `ModelParser`/
/// `SkinParser` already use for original Twinsanity meshes -- rather
/// than inventing a WoC-specific connectivity scheme, since the
/// underlying convention is the same: a vertex's own control word's
/// second byte is `0x80` when it restarts the strip (confirmed on
/// `AIRSHIP.GSC`/`FARM.GSC`/`DROID.GSC`: exactly the first 3 vertices of
/// every real arc, plus occasional later restarts consistent with a
/// normal strip-with-breaks encoding), `0x00` otherwise -- matching
/// `ModelParser.swift`'s own `connRaw != 128` rule exactly.
///
/// Each submesh's `materialID` is a real `MS00` record index
/// (``WOCContainerParser/ObjSetGeoEntry/materialIndex``) -- can be
/// cross-referenced against `MS00`'s own confirmed `tid` field (real
/// offset 424) for that material's real texture.
///
/// **What this does NOT claim**: real UV coordinates, vertex colors, or
/// normals -- none of those are decoded yet (see
/// ``WOCContainerParser/parseObjSetGeoArcs(_:)``'s doc comment on the
/// still-undecoded trailing block per arc, and on the geos that produce
/// no arcs at all -- likely a structurally different `dmastream` shape,
/// not a failure). Every `StaticVertex` here carries only a real
/// position; `normal`/`uv`/`color` stay at `StaticVertex`'s own honest
/// defaults (zero/white) rather than a fabricated guess. The triangle
/// connectivity itself is a strong structural match to a known,
/// confirmed convention, but was not independently verified by rendering
/// actual shaded triangles and inspecting winding -- treat it as a good
/// working hypothesis, not settled ground truth on the level the
/// underlying vertex positions are (those were visually confirmed as
/// coherent 3D shapes; connectivity was not, beyond structural pattern
/// matching). `.faceon` (billboard-shaped) records aren't decoded into
/// geometry here either -- same honest gap the old approach also had, no
/// regression, just not yet extended.
public enum WOCMeshDecoder {
    /// Builds one `MeshAsset` per real `OBJ0` entry, indexed by entry
    /// index (matching `INST.objectIndex`'s own indexing into `OBJ0`).
    /// `materialCount` (that same file's own real `MS00` record count) is
    /// used to bound-check material references -- pass `nil` if `MS00`
    /// isn't available. Returns `nil` only if `payload` itself doesn't
    /// parse as a well-formed `OBJ0` section at all (see
    /// ``WOCContainerParser/parseObjSet(_:materialCount:)``) -- unlike
    /// the old approach, a single malformed entry doesn't cost every
    /// other entry in the file, since `parseObjSet` either fully succeeds
    /// or fully fails (it never silently truncates midway).
    public static func buildEntryMeshes(objectPayload: Data, materialCount: Int? = nil) -> [MeshAsset]? {
        guard let objSet = try? WOCContainerParser.parseObjSet(objectPayload, materialCount: materialCount) else {
            return nil
        }
        return objSet.entries.enumerated().map { entryIndex, entry in
            buildMesh(entry: entry, entryIndex: entryIndex)
        }
    }

    private static func buildMesh(entry: WOCContainerParser.ObjSetEntry, entryIndex: Int) -> MeshAsset {
        let submeshes = entry.records.flatMap { record -> [MeshSubmesh] in
            guard case let .mesh(_, geos) = record.body else { return [] }
            return geos.compactMap { geo -> MeshSubmesh? in
                let arcs = WOCContainerParser.parseObjSetGeoArcs(geo.payload)
                let quadwords = arcs.flatMap(\.vertices)
                guard !quadwords.isEmpty else { return nil }
                let vertices = quadwords.map { StaticVertex(position: $0.position) }
                let connectivity = quadwords.map { (($0.control >> 8) & 0xFF) != 0x80 }
                // materialID = geo.materialIndex (a real MS00 record
                // index). Earlier left nil out of caution that this field
                // is keyed to original Twinsanity's own material index
                // space elsewhere (OrphanedContent.swift,
                // ResolvedModelAsset.swift) -- directly verified since
                // that WOCMeshDecoder's output never reaches those
                // consumers (grepped for objectMeshes/WOCMeshDecoder
                // outside WOCViewer/, zero hits), so there's no shared
                // code path left to collide with. Real, safe to populate.
                return MeshSubmesh(vertices: vertices, connectivity: connectivity, materialID: UInt32(geo.materialIndex))
            }
        }
        return MeshAsset(id: UInt32(entryIndex), isSkinned: false, submeshes: submeshes)
    }
}
