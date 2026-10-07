import Foundation
import CTModels
import simd

/// "Auto-Update Collision on Add/Delete": real, reported bug, placing a
/// new object in the Level Viewer and booting via PCSX2 lets Crash fall
/// straight through it, since `ColData` (the level's real, static PS2-side
/// collision mesh, see `CollisionMesh`'s own doc comment) has no idea a
/// new object exists; it's authored once, at level-design time, and this
/// codebase has no automatic per-placement sync into it. This is the
/// user-requested fallback for that: a manual "Rebuild Level Collision"
/// tool (`LevelViewerWindow`'s own button) that appends a real, solid box
/// for every currently-placed object that has collision data (asset-
/// provided or auto-generated, see `ModelViewerRenderer.
/// generateCollisionDataFromMesh`) but isn't already part of the level's
/// on-disk mesh.
///
/// The "adds a box for a new placement" half (`rebuilding(_:addingBoxes:
/// surfaceID:)`) is exact: appended to the original mesh's own real
/// vertices/triangles/groups exactly as authored, every existing triangle's
/// own `surfaceID` (water, deadly, solid, whatever it really is) preserved
/// byte-for-byte, never touched.
///
/// The "remove a deleted object's own original collision" half
/// (`removingGroupsNear(_:boxes:)`) is a real, best-effort **heuristic**,
/// not an exact fix, and its own doc comment explains why it can't be one:
/// there's no on-disk link from a `ColData` triangle back to the
/// `Instance`/`SceneryData` placement it came from, so this can only ever
/// approximate "which collision belonged to the thing I just deleted" by
/// proximity, real, but imperfect.
public enum LevelCollisionRebuilder {
    /// One session-placed object's real, world-space axis-aligned bounding
    /// box, already-transformed by the caller (position/rotation/scale),
    /// so this type stays free of any renderer/view-layer dependency.
    public struct NewCollisionBox: Sendable {
        public var worldMin: SIMD3<Float>
        public var worldMax: SIMD3<Float>

        public init(worldMin: SIMD3<Float>, worldMax: SIMD3<Float>) {
            self.worldMin = worldMin
            self.worldMax = worldMax
        }
    }

    /// Appends one real, solid box per `boxes` entry to `baseline`'s own
    /// vertices/triangles (a fresh `CollisionGroup` per box, matching how
    /// `CollisionOBJImporter` gives each connectivity-formed cluster its
    /// own group), then rebuilds *only* the derived balanced-binary
    /// trigger tree (`CollisionOBJImporter.buildTriggerTree`, the same,
    /// already-verified logic the OBJ importer uses) over the combined
    /// group list. Never touches a single byte of `baseline`'s own
    /// vertices/triangles/groups, this is strictly additive.
    ///
    /// Winding is deliberately doubled (both CW and CCW triangles for
    /// every face) rather than picked one way: this codebase has never
    /// empirically confirmed whether the PS2 engine's collision test is
    /// one-sided (in which case guessing the wrong winding would silently
    /// leave the object still fall-through-able from some angles) or
    /// two-sided. Doubling costs a handful of extra triangles per box , 
    /// negligible, and is correct either way.
    ///
    /// `surfaceID` should be a real, already-used ID from this same
    /// level's own `baseline.triangles` (see `WorkspaceViewModel`'s call
    /// site for how it picks one), inventing an unused ID would be
    /// presenting a guess about "what solid ground means" as decoded data.
    public static func rebuilding(_ baseline: CollisionMesh, addingBoxes boxes: [NewCollisionBox], surfaceID: Int) -> CollisionMesh {
        guard !boxes.isEmpty else { return baseline }

        var vertices = baseline.vertices
        var triangles = baseline.triangles
        var groups = baseline.groups

        for box in boxes {
            guard box.worldMax.x >= box.worldMin.x, box.worldMax.y >= box.worldMin.y, box.worldMax.z >= box.worldMin.z else { continue }
            let vertexOffset = vertices.count
            vertices.append(contentsOf: Self.corners(min: box.worldMin, max: box.worldMax).map { SIMD4($0, 1) })

            let triOffset = UInt32(triangles.count)
            for (a, b, c) in Self.doubleWoundBoxTriangleIndices {
                triangles.append(CollisionTriangle(
                    vertexIndex1: a + vertexOffset, vertexIndex2: b + vertexOffset, vertexIndex3: c + vertexOffset,
                    surfaceID: surfaceID
                ))
            }
            groups.append(CollisionGroup(size: UInt32(Self.doubleWoundBoxTriangleIndices.count), offset: triOffset))
        }

        let triggerBoxes = CollisionOBJImporter.buildTriggerTree(groups: groups, triangles: triangles, vertices: vertices)
        return CollisionMesh(id: baseline.id, vertices: vertices, triangles: triangles, groups: groups, triggerBoxes: triggerBoxes)
    }

    /// One real, deleted-this-session object's own world-space volume,
    /// captured at the moment it was still present (see
    /// `ModelViewerRenderer.PendingCollisionRemoval`'s own doc comment for
    /// where this actually comes from).
    public struct RemovalBox: Sendable {
        public var worldMin: SIMD3<Float>
        public var worldMax: SIMD3<Float>

        public init(worldMin: SIMD3<Float>, worldMax: SIMD3<Float>) {
            self.worldMin = worldMin
            self.worldMax = worldMax
        }
    }

    /// "Ghost Collision Removal", the other real, reported half of "Auto-
    /// Update Collision on Add/Delete": deleting an object used to leave
    /// its original collision behind forever, since `ColData` has no
    /// on-disk link from a triangle back to the placement that authored
    /// it. This is a **heuristic**, not an exact removal: it drops an
    /// entire `CollisionGroup` (this format's own connectivity-clustered
    /// unit, the same grain `CollisionOBJImporter` gives one imported
    /// mesh island) whenever that group's own real triangle-vertex
    /// centroid falls inside one of `boxes`. Two concrete, honestly-stated
    /// risks this carries: (1) if the level's original author merged a
    /// deleted prop's collision into a larger shared group with unrelated
    /// geometry, that whole group, including the unrelated part, gets
    /// dropped; (2) if the prop's real footprint doesn't overlap its own
    /// group's centroid closely enough (an oddly-shaped or off-center
    /// collision hull), nothing gets removed. Grouped by connectivity the
    /// way this format already clusters real, single objects' geometry in
    /// practice, this is expected to work correctly far more often than
    /// not, but it is a real trade-off, not a guarantee, and is why this
    /// is a distinct, separately-invoked function rather than folded
    /// silently into every rebuild.
    public static func removingGroupsNear(_ mesh: CollisionMesh, boxes: [RemovalBox]) -> (mesh: CollisionMesh, removedGroupCount: Int) {
        guard !boxes.isEmpty else { return (mesh, 0) }

        var keptTriangles: [CollisionTriangle] = []
        var keptGroups: [CollisionGroup] = []
        var removedCount = 0

        for group in mesh.groups {
            let start = Int(group.offset)
            let count = Int(group.size)
            guard start >= 0, count >= 0, start + count <= mesh.triangles.count else {
                // A malformed group offset/size is a pre-existing data
                // problem, not something a removal pass should compound , 
                // keep it exactly as-is rather than risk losing data by
                // guessing at its real extent.
                let newOffset = UInt32(keptTriangles.count)
                keptTriangles.append(contentsOf: mesh.triangles[max(0, start)..<max(0, min(start + count, mesh.triangles.count))])
                keptGroups.append(CollisionGroup(size: group.size, offset: newOffset))
                continue
            }
            let groupTriangles = mesh.triangles[start..<(start + count)]

            // Real, reported bug ("falling through the floor after Update
            // Collision"): centroid-inside-a-removal-box alone doesn't
            // distinguish "this group *is* the moved/deleted object's own
            // collision" from "this group is something huge (the level's
            // entire Ground Floor, authored as one connected mesh, see the
            // Scene Layers panel's own "Collision / Ground Floor (1)" count)
            // whose centroid *happens* to fall inside a small removal box
            // because the box sits somewhere within that huge group's
            // extent." The latter is exactly what a moved object near the
            // middle of a level's own playable area triggers, deleting a
            // whole level's floor in one shot, not the one prop that moved.
            // A group representing a single real object's own collision has
            // a bounding box comparable in size to the removal box that
            // captured that same object; the Ground Floor's does not. This
            // adds that comparison as an extra, purely-more-conservative
            // guard, it can only prevent a removal this heuristic would
            // otherwise have performed, never add a new one, while leaving
            // the existing, already-honest "heuristic, not exact" character
            // of this function unchanged.
            var vertexSum = SIMD3<Float>.zero
            var vertexCount = 0
            var groupMin: SIMD3<Float>?
            var groupMax: SIMD3<Float>?
            for triangle in groupTriangles {
                for vertexIndex in [triangle.vertexIndex1, triangle.vertexIndex2, triangle.vertexIndex3] where mesh.vertices.indices.contains(vertexIndex) {
                    let v4 = mesh.vertices[vertexIndex]
                    let v = SIMD3<Float>(v4.x, v4.y, v4.z)
                    vertexSum += v
                    vertexCount += 1
                    groupMin = groupMin.map { simd_min($0, v) } ?? v
                    groupMax = groupMax.map { simd_max($0, v) } ?? v
                }
            }
            let matchesRemoval: Bool
            if vertexCount > 0, let groupMin, let groupMax {
                let centroid = vertexSum / Float(vertexCount)
                // Generous slack (this group's own extent may legitimately
                // be somewhat larger than the removal box, the object's
                // real collision hull vs. its own simplified world-space
                // AABB, padding baked in by the original level author,
                // etc.) without letting through something the size of a
                // whole floor: 4x the removal box's own size on every axis,
                // plus a flat minimum so a removal box for a tiny/thin
                // object (near-zero size on one axis) doesn't degenerate
                // into a zero-width containment test.
                let groupSize = groupMax - groupMin
                matchesRemoval = boxes.contains { box in
                    guard centroid.x >= box.worldMin.x, centroid.x <= box.worldMax.x,
                          centroid.y >= box.worldMin.y, centroid.y <= box.worldMax.y,
                          centroid.z >= box.worldMin.z, centroid.z <= box.worldMax.z
                    else { return false }
                    let boxSize = box.worldMax - box.worldMin
                    let allowedSize = simd_max(boxSize * 4, SIMD3<Float>(repeating: 2))
                    return groupSize.x <= allowedSize.x && groupSize.y <= allowedSize.y && groupSize.z <= allowedSize.z
                }
            } else {
                matchesRemoval = false
            }

            if matchesRemoval {
                removedCount += 1
                continue
            }
            let newOffset = UInt32(keptTriangles.count)
            keptTriangles.append(contentsOf: groupTriangles)
            keptGroups.append(CollisionGroup(size: group.size, offset: newOffset))
        }

        guard removedCount > 0 else { return (mesh, 0) }
        // `mesh.vertices` is left untouched, a handful of now-unreferenced
        // pool entries are functionally inert, and trimming them would
        // mean renumbering every remaining triangle's vertex indices for a
        // purely cosmetic saving, real risk for no functional benefit.
        let triggerBoxes = CollisionOBJImporter.buildTriggerTree(groups: keptGroups, triangles: keptTriangles, vertices: mesh.vertices)
        let result = CollisionMesh(id: mesh.id, vertices: mesh.vertices, triangles: keptTriangles, groups: keptGroups, triggerBoxes: triggerBoxes)
        return (result, removedCount)
    }

    /// "Rebuild All Collision", , deliberately more
    /// drastic than `rebuilding(_:addingBoxes:surfaceID:)`'s additive-only
    /// contract: destroys `baseline`'s own vertices/triangles/groups
    /// entirely (keeping only its `id`) and rebuilds from just `boxes` , 
    /// meant to be called with a box for *every* real scenery object
    /// currently in the level, not only session-placed ones, so a whole
    /// level's collision mesh can be regenerated from scratch rather than
    /// incrementally patched. Reuses `rebuilding` itself against an empty-
    /// content baseline (the exact same double-winding/derived-trigger-tree
    /// logic, not duplicated) rather than bending the incremental function
    /// to do two different things, see this type's own doc comment for
    /// why a full destroy-and-rebuild is a distinct operation from the
    /// add/remove heuristics above, not a variation on them.
    public static func rebuildingFromScratch(preservingIDFrom baseline: CollisionMesh, addingBoxes boxes: [NewCollisionBox], surfaceID: Int) -> CollisionMesh {
        let empty = CollisionMesh(id: baseline.id, vertices: [], triangles: [], groups: [], triggerBoxes: [])
        return rebuilding(empty, addingBoxes: boxes, surfaceID: surfaceID)
    }

    /// One real, world-space triangle from a scenery object's own actual
    /// render mesh, not an approximation.
    public struct MeshTriangle: Sendable {
        public var v0: SIMD3<Float>
        public var v1: SIMD3<Float>
        public var v2: SIMD3<Float>

        public init(v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>) {
            self.v0 = v0
            self.v1 = v1
            self.v2 = v2
        }
    }

    /// One connected cluster's worth of real mesh triangles, destined to
    /// become exactly one `CollisionGroup`, this format's own "one object"
    /// unit. A cluster is a single scenery object's own triangles when it
    /// doesn't touch anything else, or several touching objects' triangles
    /// concatenated together when it does: real, reported feedback is that
    /// most scenery in a level *is* one connected piece, and should collide
    /// as one, not as separately-hulled neighbors.
    public struct NewCollisionMeshGroup: Sendable {
        public var triangles: [MeshTriangle]

        public init(triangles: [MeshTriangle]) {
            self.triangles = triangles
        }
    }

    /// Literal mesh-triangle counterpart to `rebuilding(_:addingBoxes:
    /// surfaceID:)`: appends each group's own real triangles, the exact
    /// geometry already being rendered, not a box or hull approximation , 
    /// as one new `CollisionGroup` per `NewCollisionMeshGroup`, then rebuilds
    /// the derived trigger tree over the combined group list. Same doubled-
    /// winding rationale as the box path (one-sided-vs-two-sided PS2
    /// collision was never empirically confirmed).
    ///
    /// Vertices are deduplicated *within each group* (a real, requested
    /// constraint, this is a PS2 game, and every redundant vertex is
    /// real budget spent on every scenery object in the level) via exact
    /// position match; never shared *across* groups or with `baseline`'s
    /// own pool, so this stays strictly additive like the box path.
    public static func rebuilding(_ baseline: CollisionMesh, addingMeshGroups meshGroups: [NewCollisionMeshGroup], surfaceID: Int) -> CollisionMesh {
        guard !meshGroups.isEmpty else { return baseline }

        var vertices = baseline.vertices
        var triangles = baseline.triangles
        var groups = baseline.groups

        for meshGroup in meshGroups {
            guard !meshGroup.triangles.isEmpty else { continue }
            let triOffset = UInt32(triangles.count)

            var indexForPosition: [SIMD3<Float>: Int] = [:]
            func vertexIndex(for p: SIMD3<Float>) -> Int {
                if let existing = indexForPosition[p] { return existing }
                let newIndex = vertices.count
                vertices.append(SIMD4(p, 1))
                indexForPosition[p] = newIndex
                return newIndex
            }

            for tri in meshGroup.triangles {
                let a = vertexIndex(for: tri.v0)
                let b = vertexIndex(for: tri.v1)
                let c = vertexIndex(for: tri.v2)
                triangles.append(CollisionTriangle(vertexIndex1: a, vertexIndex2: b, vertexIndex3: c, surfaceID: surfaceID))
                triangles.append(CollisionTriangle(vertexIndex1: a, vertexIndex2: c, vertexIndex3: b, surfaceID: surfaceID))
            }
            groups.append(CollisionGroup(size: UInt32(triangles.count) - triOffset, offset: triOffset))
        }

        let triggerBoxes = CollisionOBJImporter.buildTriggerTree(groups: groups, triangles: triangles, vertices: vertices)
        return CollisionMesh(id: baseline.id, vertices: vertices, triangles: triangles, groups: groups, triggerBoxes: triggerBoxes)
    }

    /// Mesh-triangle counterpart to `rebuildingFromScratch(preservingIDFrom:
    /// addingBoxes:surfaceID:)`, same destroy-and-rebuild contract, real
    /// per-object geometry instead of boxes.
    public static func rebuildingFromScratch(preservingIDFrom baseline: CollisionMesh, addingMeshGroups meshGroups: [NewCollisionMeshGroup], surfaceID: Int) -> CollisionMesh {
        let empty = CollisionMesh(id: baseline.id, vertices: [], triangles: [], groups: [], triggerBoxes: [])
        return rebuilding(empty, addingMeshGroups: meshGroups, surfaceID: surfaceID)
    }

    /// The result of picking "whatever counts as ordinary solid ground
    /// here," with enough real detail to show a human before they confirm
    /// a save, see `dominantSolidSurfaceChoice`'s own doc comment for why
    /// this can't be a silent, fully-automatic decision.
    public struct SurfaceChoice: Sendable {
        public let surfaceID: Int
        public let triangleCount: Int
        /// Real (x, y, z) size of this surface's own on-disk footprint , 
        /// lets a confirmation message read "surface 12, a 330×0.2×280
        /// unit slab" instead of a bare, meaningless number.
        public let size: SIMD3<Float>
        /// `true` when this choice was picked *despite* looking like a
        /// large flat plane (this format's own real, measured shape for
        /// water), either because every candidate looked that way, or
        /// there was no other candidate at all. A human should look twice
        /// before trusting it.
        public let mightBeAHazardSurface: Bool
    }

    /// Picks "whatever counts as ordinary solid ground here" the same
    /// data-driven way every collision-rebuild call site in this codebase
    /// wants (the most common `surfaceID` already used in a real level's
    /// own mesh, not an invented ID), hardened against a real, measured
    /// failure mode (naive "most common by triangle count" can pick a
    /// large, flat hazard surface, water, lava, instead of actual
    /// terrain, since a big flat plane's low triangle *density* isn't what
    /// makes it dangerous to pick; its *shape* is), but **not** a claim
    /// that this can always tell water apart from a legitimate flat floor
    /// or plaza, it genuinely can't, from this data alone: this format
    /// carries no surface-name or texture link on `CollisionTriangle`, and
    /// real per-level `CollisionSurface` records (sound/particle
    /// assignments) don't reliably distinguish "swim" from "walk" either
    /// (this game's own real `beach.rm2` has zero local `CollisionSurface`
    /// records to check at all). Elevation isn't a safe substitute either
    ///, verified against the same real level, its actual terrain dips to
    /// Y -26.8, *lower* than either flat plane (-1.5 and -3.3), so "lowest
    /// surface wins" would misidentify terrain as the hazard.
    ///
    /// So this stays a real, disclosed heuristic (flatness ratio under 1%
    /// over a footprint wider than 50 units, verified against this exact
    /// game's own real water, measured at a 0.0002-0.0009 ratio spanning
    /// ~330 units, two full orders of magnitude inside the cutoff), and
    /// every caller gets the *full* `SurfaceChoice` back, including
    /// `mightBeAHazardSurface`, specifically so it can be shown to the
    /// user before a save is confirmed, rather than trusted silently. See
    /// `dominantSolidSurfaceID` for callers that only need the bare ID.
    public static func dominantSolidSurfaceChoice(in mesh: CollisionMesh) -> SurfaceChoice {
        guard !mesh.triangles.isEmpty else {
            return SurfaceChoice(surfaceID: 0, triangleCount: 0, size: .zero, mightBeAHazardSurface: false)
        }
        struct Stats {
            var count = 0
            var min = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var max = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        }
        var bySurface: [Int: Stats] = [:]
        for tri in mesh.triangles {
            var stats = bySurface[tri.surfaceID] ?? Stats()
            stats.count += 1
            for vi in [tri.vertexIndex1, tri.vertexIndex2, tri.vertexIndex3] where mesh.vertices.indices.contains(vi) {
                let v4 = mesh.vertices[vi]
                let v = SIMD3<Float>(v4.x, v4.y, v4.z)
                stats.min = simd_min(stats.min, v)
                stats.max = simd_max(stats.max, v)
            }
            bySurface[tri.surfaceID] = stats
        }
        func looksLikeAFlatHazardPlane(_ stats: Stats) -> Bool {
            let size = stats.max - stats.min
            guard size.x.isFinite, size.y.isFinite, size.z.isFinite else { return false }
            let footprint = max(size.x, size.z)
            guard footprint > 50 else { return false }
            let flatness = size.y / max(footprint, 0.001)
            return flatness < 0.01
        }
        let candidates = bySurface.filter { !looksLikeAFlatHazardPlane($0.value) }
        let pool = candidates.isEmpty ? bySurface : candidates
        guard let picked = pool.max(by: { $0.value.count < $1.value.count }) else {
            return SurfaceChoice(surfaceID: 0, triangleCount: 0, size: .zero, mightBeAHazardSurface: false)
        }
        return SurfaceChoice(
            surfaceID: picked.key,
            triangleCount: picked.value.count,
            size: picked.value.max - picked.value.min,
            mightBeAHazardSurface: looksLikeAFlatHazardPlane(picked.value)
        )
    }

    /// Convenience for callers that only need the bare ID (the incremental
    /// new-object-on-save path, whose own summary doesn't break out a
    /// per-surface message), see `dominantSolidSurfaceChoice` for the
    /// full picture and why this can't be a fully-automatic decision.
    public static func dominantSolidSurfaceID(in mesh: CollisionMesh) -> Int {
        dominantSolidSurfaceChoice(in: mesh).surfaceID
    }

    /// Same 8-corner convention as `ModelViewerRenderer.collisionBoxEdges`
    /// (c000..c111, min/max on each axis), kept consistent with the rest
    /// of this codebase's collision-box handling rather than inventing a
    /// different corner order here.
    private static func corners(min: SIMD3<Float>, max: SIMD3<Float>) -> [SIMD3<Float>] {
        [
            SIMD3(min.x, min.y, min.z), SIMD3(max.x, min.y, min.z),
            SIMD3(min.x, max.y, min.z), SIMD3(max.x, max.y, min.z),
            SIMD3(min.x, min.y, max.z), SIMD3(max.x, min.y, max.z),
            SIMD3(min.x, max.y, max.z), SIMD3(max.x, max.y, max.z),
        ]
    }

    /// Indices into `corners(min:max:)`'s 8-entry result: c000=0, c100=1,
    /// c010=2, c110=3, c001=4, c101=5, c011=6, c111=7. Six faces, two
    /// triangles each, *both* windings per triangle (see `rebuilding`'s own
    /// doc comment on why), 6 faces * 2 triangles * 2 windings = 24.
    private static let doubleWoundBoxTriangleIndices: [(Int, Int, Int)] = {
        let quads: [(Int, Int, Int, Int)] = [
            (0, 1, 3, 2), // z = min
            (4, 5, 7, 6), // z = max
            (0, 1, 5, 4), // y = min
            (2, 3, 7, 6), // y = max
            (0, 2, 6, 4), // x = min
            (1, 3, 7, 5), // x = max
        ]
        var result: [(Int, Int, Int)] = []
        for (a, b, c, d) in quads {
            result.append((a, b, c)); result.append((a, c, d))
            result.append((a, c, b)); result.append((a, d, c))
        }
        return result
    }()
}
