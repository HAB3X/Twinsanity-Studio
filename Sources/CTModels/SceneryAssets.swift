import Foundation
import simd

/// One placed scenery model, ported from the reference tool's
/// `SceneryData.ScenerySubModel` (`Twinsanity/Items/SceneryData.cs`).
/// `modelMatrix` is empty when its enclosing `SceneryModelGroup.header`
/// wasn't `0x1613` (the reference tool only reads matrices/IDs under that
/// header, see `LoadSceneryModel`).
public struct SceneryModelPlacement: Sendable {
    public var modelID: UInt32
    public var isSpecial: Bool
    public var boundingBoxMin: SIMD4<Float>
    public var boundingBoxMax: SIMD4<Float>
    /// 4 rows, a full affine transform for this placement.
    public var modelMatrix: [SIMD4<Float>]
    /// Byte offset of this placement's own 4-row `modelMatrix` block,
    /// relative to the enclosing `SceneryData` record's own start (same
    /// convention as `cameraControlPointFileOffset`: combine with the
    /// record's `ChunkNode.fileOffset` for an absolute file position).
    /// `nil` for a placement not parsed from a real record with tracked
    /// offsets (e.g. a hand-built value in a test). This is what makes
    /// "move an existing scenery placement, save" real
    /// (`LevelViewerRenderer.pendingSceneryTransformOverrides` patches just
    /// this 64-byte block in place, without re-encoding the whole
    /// (large, deeply nested) `SceneryData` tree), same "patch just the
    /// known-size field that changed" pattern this codebase already uses
    /// for `Position`/`Instance`/camera control points. It's also this
    /// same field's *identity* that "delete an existing placement" keys
    /// off (`SceneryGroup.removingPlacements`), creating and inserting a
    /// brand-new placement (`LevelViewerRenderer.spawnScenery`) is a
    /// separate mechanism entirely, since a new placement has no real
    /// on-disk offset yet to track.
    public var matrixFileOffset: Int?

    public init(modelID: UInt32, isSpecial: Bool, boundingBoxMin: SIMD4<Float>, boundingBoxMax: SIMD4<Float>, modelMatrix: [SIMD4<Float>], matrixFileOffset: Int? = nil) {
        self.modelID = modelID
        self.isSpecial = isSpecial
        self.boundingBoxMin = boundingBoxMin
        self.boundingBoxMax = boundingBoxMax
        self.modelMatrix = modelMatrix
        self.matrixFileOffset = matrixFileOffset
    }

    /// Row 3 of the matrix is the translation column in every other 4-row
    /// transform this codebase decodes (`Joint.matrix`, `SkinTransform`) , 
    /// used for a first-pass "where is this roughly" placement position
    /// without needing full matrix math wired through the renderer yet.
    public var translation: SIMD3<Float>? {
        guard modelMatrix.count > 3 else { return nil }
        let v = modelMatrix[3]
        return SIMD3(v.x, v.y, v.z)
    }

    /// Decomposes the full 4-row transform into position/rotation/scale.
    ///
    /// **Fourth correction to this function's rotation handling, this one
    /// grounded in reading OpenTK's actual `Vector4`/`Matrix4` operator
    /// source, not hand-tracing/assuming its convention.** Every earlier
    /// attempt (see git history / this file's prior revisions) got as far
    /// as correctly hand-tracing `LoadSceneryModel`'s (`SMViewer.cs`/
    /// `RMViewer.cs`) two-step matrix construction, row assembly with
    /// `row0` negated per-component, then a `Matrix4.CreateScale(-1,1,1)`
    /// post-multiply, and stopped there, since that construction alone
    /// *looks* fully sufficient to derive the answer. It isn't: it only
    /// tells you what bytes end up in OpenTK's `Matrix4`, not how that
    /// matrix actually gets applied to a vertex, and those two things use
    /// *different* row/column conventions in this specific library.
    ///
    /// Working through the construction (verified against the live
    /// `opentk/opentk` 3.x source, not recalled from memory): after both
    /// steps, OpenTK's `modelMatrix` ends up with **columns** equal to the
    /// on-disk rows (`Column0 = row0`, `Column1 = row1`, `Column2 = row2`)
    ///, i.e. numerically the transpose of the on-disk 3×3 block. That's
    /// exactly what the *previous* version of this function built via
    /// `simd_float3x3(columns: (row0, row1, row2))`, and exactly why it
    /// looked so thoroughly verified (it correctly reproduces OpenTK's own
    /// matrix, bit for bit) while still being wrong.
    ///
    /// The missing piece: `SMViewer.cs` transforms each vertex with
    /// `vertexPos *= modelMatrix`, `Vector4 operator*(Vector4, Matrix4)`,
    /// which OpenTK's own source implements as **row-vector** multiply
    /// (`result = vec * mat`, dotting `vec` against `mat`'s *columns*), not
    /// `Matrix4 * Vector4`'s column-vector form (OpenTK ships both, with
    /// different math, the ambiguity a previous version of this comment
    /// correctly flagged as unresolvable from reading only the call site).
    /// simd's `matrix * vector` is always column-vector. Porting a
    /// row-vector transform into a column-vector system needs one more
    /// transpose to compensate, and that transpose exactly cancels the
    /// one already baked into OpenTK's own matrix, leaving the correct
    /// simd matrix equal to **the on-disk 3×3 block, used directly,
    /// unchanged** (working the full vertex transform through by hand:
    /// `world.x = dot(local, row0) - row3.x`, `world.y = dot(local, row1)
    /// + row3.y`, `world.z = dot(local, row2) + row3.z`, i.e. row0/1/2
    /// used as the *rows* of the effective world matrix, not its columns).
    ///
    /// Real-data support: across many real same-model, genuinely-rotated
    /// placement pairs in `beach.sm2`, this formula's edge-alignment rate
    /// is the best of every candidate tried (including the previous,
    /// transpose-based one), see this file's own investigation history.
    /// It is **not** claimed to be the final word on its own; symmetric/
    /// square geometry and 180°-symmetric shapes are structurally blind to
    /// several classes of rotation error (a lesson this function has
    /// already taught twice), so the real confirmation is checking several
    /// different floor/wall placements, not just one, against the live
    /// reference tool.
    ///
    /// Translation (`-row3.x`, unchanged otherwise) was never in question;
    /// every version of this function has agreed on it.
    ///
    /// Scale is each column's length; dividing it out leaves a pure
    /// rotation matrix for `simd_quatf`.
    public var worldTransform: (position: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>)? {
        guard modelMatrix.count > 3 else { return nil }
        let row0 = modelMatrix[0]
        let row1 = modelMatrix[1]
        let row2 = modelMatrix[2]
        let row3 = modelMatrix[3]

        let col0 = SIMD3<Float>(row0.x, row1.x, row2.x)
        let col1 = SIMD3<Float>(row0.y, row1.y, row2.y)
        let col2 = SIMD3<Float>(row0.z, row1.z, row2.z)

        let scaleX = simd_length(col0)
        let scaleY = simd_length(col1)
        let scaleZ = simd_length(col2)

        let rotationMatrix = simd_float3x3(columns: (
            scaleX > 0.0001 ? col0 / scaleX : SIMD3<Float>(1, 0, 0),
            scaleY > 0.0001 ? col1 / scaleY : SIMD3<Float>(0, 1, 0),
            scaleZ > 0.0001 ? col2 / scaleZ : SIMD3<Float>(0, 0, 1)
        ))

        return (SIMD3(-row3.x, row3.y, row3.z), simd_quatf(rotationMatrix), SIMD3(scaleX, scaleY, scaleZ))
    }

    /// The exact algebraic inverse of `worldTransform` above, not a fresh
    /// guess at the format, a mechanical reversal of that already-verified
    /// decode (see its own doc comment for the real-data investigation
    /// history behind the row/column convention this must match exactly).
    /// Used by newly-created placements (`LevelViewerRenderer.spawnScenery`)
    /// so a rotated/scaled interactive placement actually saves as
    /// rotated/scaled, not silently flattened to identity the way the
    /// original one-shot `duplicatingSceneryPlacement`/
    /// `placingSceneryFromAnotherLevel` still do.
    public static func composingModelMatrix(position: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) -> [SIMD4<Float>] {
        let rotationMatrix = simd_float3x3(rotation)
        let col0 = rotationMatrix.columns.0 * scale.x
        let col1 = rotationMatrix.columns.1 * scale.y
        let col2 = rotationMatrix.columns.2 * scale.z
        return [
            SIMD4(col0.x, col1.x, col2.x, 0),
            SIMD4(col0.y, col1.y, col2.y, 0),
            SIMD4(col0.z, col1.z, col2.z, 0),
            SIMD4(-position.x, position.y, position.z, 1),
        ]
    }
}

/// A `SceneryModelStruct`, a group of placements sharing one header/type
/// tag, plus the group's own bounding info.
public struct SceneryModelGroup: Sendable {
    public var header: UInt32
    public var placements: [SceneryModelPlacement]
    /// `SceneryModelStruct.UnkPos[5]`, 5 real, always-present `Vector4`s
    /// (`SceneryDataParser`'s own doc comment: "always present, unused by
    /// this reader") trailing every model group regardless of `header`.
    /// Kept so `SceneryDataWriter` can round-trip a group losslessly , 
    /// without this, re-encoding *any* group (even one with no placement
    /// changes) would silently zero 80 real bytes.
    public var unkPos: [SIMD4<Float>]

    public init(header: UInt32, placements: [SceneryModelPlacement], unkPos: [SIMD4<Float>] = Array(repeating: .zero, count: 5)) {
        self.header = header
        self.placements = placements
        self.unkPos = unkPos
    }

    /// Group-level counterpart to `SceneryGroup.removingPlacements`, used
    /// for both a leaf `.modelGroup` link and the root group's own `model`.
    public func removingPlacements(withFileOffsets offsets: Set<Int>) -> SceneryModelGroup {
        guard !offsets.isEmpty else { return self }
        var copy = self
        copy.placements.removeAll { placement in
            guard let offset = placement.matrixFileOffset else { return false }
            return offsets.contains(offset)
        }
        return copy
    }

    /// **Decoded, real-data-confirmed format for `unkPos`**, a "bounding
    /// capsule" (a line segment plus one shared radius) covering every real
    /// placement `covering` describes:
    ///
    /// - `unkPos[0]` = capsule axis midpoint, `.w` = half the axis length
    ///   (`simd_length` of `unkPos[3]`'s xyz)
    /// - `unkPos[1]`/`unkPos[2]` = the two axis endpoints, `.w` = the
    ///   capsule radius (identical in both, and in `unkPos[3].w`)
    /// - `unkPos[3]` = the half-axis vector (`unkPos[2]-unkPos[0]` ==
    ///   `unkPos[0]-unkPos[1]`, exactly, by construction), `.w` = radius
    /// - `unkPos[4]` = always the zero vector in every real group sampled
    ///
    /// Confirmed against 9,646 real, dev-authored `SceneryModelGroup`
    /// records pulled from the pristine reference disc (134 real `.sm2`
    /// files): the `v3 == v2-v0 == v0-v1` identity holds exactly (float
    /// precision) in 100% of them, and the resulting capsule (using each
    /// leaf `.modelGroup`'s own placements, or, for an internal `.group`
    /// node's own `model`, that node's *entire* subtree, own placements
    /// plus every descendant link's, recursively) fully covers every real
    /// placement's position *and* mesh extent (via each placement's own
    /// `boundingBoxMin`/`Max`) in 100% of the 7,540 real internal `.group`
    /// nodes below the tree's own root, the only exceptions found were the
    /// outermost tree root's own `model.unkPos`, which follows some other,
    /// still-undecoded convention (real root-level values routinely miss
    /// covering even their own tiny direct placement list by hundreds of
    /// units), consistent with real placements inserted straight into the
    /// root elsewhere in this codebase never needing a bound maintained for
    /// them. **Do not call this for the tree's own root group**, leave its
    /// `unkPos` round-tripped untouched, the same way this codebase already
    /// does for every field it hasn't decoded.
    ///
    /// This is the PS2 engine's own group-level coarse culling bound: real,
    /// on-disk data always carries generous slack over the minimum needed
    /// (median ~25–30 units in the sampled data), so this recomputation
    /// doesn't try to reproduce the exact original algorithm bit-for-bit , 
    /// it picks the same two-pass farthest-point axis (the classic
    /// Ritter-style bounding approach, which naturally reproduces the same
    /// "midpoint + symmetric endpoints" shape real data has), then expands
    /// the radius to the real, exact minimum needed to cover every point
    /// plus a small fixed safety margin, never *tighter* than what's
    /// actually needed, which is what matters for fixing a mechanism this
    /// codebase now has real evidence gates real-game visibility.
    public static func computingUnkPos(covering placements: [SceneryModelPlacement]) -> [SIMD4<Float>] {
        guard let box = worldBounds(of: placements) else {
            return Array(repeating: .zero, count: 5)
        }
        return unkPos(min: box.min, max: box.max, widths: nil)
    }

    /// A placement's world-space axis-aligned box, in the game's own (on-disk) space: its local box (`boundingBoxMin`/`Max`,
    /// symmetric) taken through its 4-row matrix, as the game's own per-mesh cull test does (`SceneryMeshes::DrawCulled` tests
    /// the local box under the placement's matrix). Rows 0-2 are the basis, row 3 the translation (row-vector convention).
    public static func worldBounds(of placement: SceneryModelPlacement) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard placement.modelMatrix.count > 3 else { return nil }
        let r0 = placement.modelMatrix[0], r1 = placement.modelMatrix[1], r2 = placement.modelMatrix[2]
        let t = SIMD3<Float>(placement.modelMatrix[3].x, placement.modelMatrix[3].y, placement.modelMatrix[3].z)
        let lo = SIMD3<Float>(placement.boundingBoxMin.x, placement.boundingBoxMin.y, placement.boundingBoxMin.z)
        let hi = SIMD3<Float>(placement.boundingBoxMax.x, placement.boundingBoxMax.y, placement.boundingBoxMax.z)
        let centre = (lo + hi) * 0.5
        let half = simd_abs(hi - lo) * 0.5
        let a0 = SIMD3<Float>(r0.x, r0.y, r0.z), a1 = SIMD3<Float>(r1.x, r1.y, r1.z), a2 = SIMD3<Float>(r2.x, r2.y, r2.z)
        let worldCentre = t + a0 * centre.x + a1 * centre.y + a2 * centre.z
        let worldHalf = simd_abs(a0) * half.x + simd_abs(a1) * half.y + simd_abs(a2) * half.z
        return (worldCentre - worldHalf, worldCentre + worldHalf)
    }

    /// The world-space box every placement's box fits in (nil: none has a position)
    public static func worldBounds(of placements: [SceneryModelPlacement]) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var result: (min: SIMD3<Float>, max: SIMD3<Float>)?
        for placement in placements {
            guard let box = worldBounds(of: placement) else { continue }
            if let current = result {
                result = (simd_min(current.min, box.min), simd_max(current.max, box.max))
            } else {
                result = box
            }
        }
        return result
    }

    /// The 5 vectors the game reads for a group (the scenery cell's `BoundingVolume` then 16 bytes of its own): the bounding
    /// sphere (centre, `.w` its radius: the half-size's length), the box's min and max corners, the half-size, and the cell's
    /// 16 bytes (zero). `widths` keeps an existing group's `.w` on the min, max and half-size vectors (the game's box test reads
    /// the corners' xyz only); nil uses the sphere's radius, as real groups' are close to.
    static func unkPos(min lo: SIMD3<Float>, max hi: SIMD3<Float>, widths: (Float, Float, Float)?, fifth: SIMD4<Float> = .zero) -> [SIMD4<Float>] {
        let centre = (lo + hi) * 0.5
        let half = hi - centre
        let radius = simd_length(half)
        let w = widths ?? (radius, radius, radius)
        return [SIMD4(centre, radius), SIMD4(lo, w.0), SIMD4(hi, w.1), SIMD4(half, w.2), fifth]
    }

    /// Recomputes this leaf group's own `unkPos` from its current
    /// `placements`, see `computingUnkPos(covering:)`'s own doc comment
    /// for the decoded format and the real-data confirmation behind it.
    /// **Not used by any production save path**, real hardware testing
    /// found that replacing a group's whole capsule (even with one that
    /// numerically "covers" the same points) is a real regression; see
    /// `expandingUnkPos(_:toCover:)`'s own doc comment for what production
    /// actually uses instead. Kept only as a fallback for a group with no
    /// real prior `unkPos` to expand from at all (a brand-new group).
    public func recomputingUnkPos() -> SceneryModelGroup {
        var copy = self
        copy.unkPos = SceneryModelGroup.computingUnkPos(covering: placements)
        return copy
    }

    /// **What production actually uses to keep `unkPos` correct after a
    /// real edit.** A real, reported regression (found live, in a real
    /// PCSX2 boot) with the *first* approach here , 
    /// `computingUnkPos(covering:)`, a from-scratch reconstruction, is
    /// why this exists: even when correctly *scoped* to only the groups an
    /// edit actually touched, and even when the reconstruction numerically
    /// "covers" every real placement's position, replacing a group's whole
    /// capsule broke visibility for objects in that group that were
    /// working *before* the edit, "the entire world is flickering...
    /// certain objects turn invisible" as the camera turns, the same
    /// symptom class this whole investigation started from. The most
    /// likely real explanation: the PS2 engine's own culling test almost
    /// certainly checks this capsule's actual shape/orientation against
    /// the camera frustum (a real geometric intersection test), not merely
    /// whether it happens to contain the right points, so a same-
    /// coverage-but-differently-oriented reconstruction (this project's
    /// own 2-pass farthest-point axis search has no reason to pick the
    /// *same* axis the original dev tool's own algorithm did, even for an
    /// identical point set) can genuinely fail that real intersection test
    /// from angles the *original* capsule's own real orientation would
    /// have passed.
    ///
    /// This function never touches the axis at all: `existing`'s
    /// `unkPos[0]`/`[1]`/`[2]`/`[3]` (center, both endpoints, half-axis
    /// vector) are preserved *exactly*, the real, dev-authored orientation
    /// is never second-guessed. Only the shared radius (`.w` on
    /// `unkPos[1]`/`[2]`/`[3]`) is ever grown, and only just enough to also
    /// cover every real placement in `placements` that the *existing*
    /// axis/radius doesn't already cover, checking every current
    /// placement (not just a newly-added one) against the *unchanged*
    /// axis correctly handles both a brand-new placement and an existing
    /// one that moved outside the old radius, with no need to separately
    /// identify which placements are "new" vs "moved" vs "unchanged".
    /// Returns `existing` completely untouched (byte-for-byte, not just
    /// numerically equal) whenever it already covers everything, the
    /// overwhelmingly common case for a group nowhere near the actual
    /// edit, and even likely for the group that *was* edited if the
    /// existing capsule already had real slack.
    public static func expandingUnkPos(_ existing: [SIMD4<Float>], toCover placements: [SceneryModelPlacement]) -> [SIMD4<Float>] {
        guard existing.count == 5 else {
            return computingUnkPos(covering: placements)
        }
        // What the game actually reads (twinsanity-reversed: SceneryCell::Read → BoundingVolume::Read, the cull test
        // ChunkView::TestCell → CullTestBox(&cell->min), VU0 testing the min/max box's corners): unkPos[1]/[2] are the cell's
        // axis-aligned box. A placement outside it is culled with the whole cell by view angle, whatever `.w` says, so the box
        // itself grows, per axis, just enough to hold every placement's world box. A box already holding them all is returned
        // untouched, byte for byte.
        guard let needed = worldBounds(of: placements) else { return existing }
        let oldMin = SIMD3<Float>(existing[1].x, existing[1].y, existing[1].z)
        let oldMax = SIMD3<Float>(existing[2].x, existing[2].y, existing[2].z)
        let margin: Float = 0.05
        var newMin = oldMin
        var newMax = oldMax
        var grew = false
        for axis in 0..<3 {
            if needed.min[axis] < oldMin[axis] {
                newMin[axis] = needed.min[axis] - margin
                grew = true
            }
            if needed.max[axis] > oldMax[axis] {
                newMax[axis] = needed.max[axis] + margin
                grew = true
            }
        }
        guard grew else { return existing }
        return unkPos(min: newMin, max: newMax, widths: (existing[1].w, existing[2].w, existing[3].w), fifth: existing[4])
    }

    /// Instance-method convenience for `expandingUnkPos(_:toCover:)` , 
    /// expands this group's own `unkPos` to cover `placements` (typically
    /// `self.placements`, this group's own current membership).
    public func expandingUnkPos(toCover placements: [SceneryModelPlacement]) -> SceneryModelGroup {
        var copy = self
        copy.unkPos = SceneryModelGroup.expandingUnkPos(unkPos, toCover: placements)
        return copy
    }

    /// Whether two placement lists represent a *real* content difference , 
    /// used by `SceneryGroup.recomputingUnkPos(sinceEditFrom:)` to scope
    /// `unkPos` recomputation to only the groups a real edit actually
    /// touched. A different count is always a difference (an insertion or
    /// removal); same-count lists are compared element-wise by
    /// `matrixFileOffset` where both sides have one (an existing, on-disk
    /// placement whose offset changing would mean the tree itself
    /// reordered, treated as a difference to be safe), and by full
    /// content otherwise (a freshly-inserted placement has no offset yet,
    /// so it always registers as a difference here, which is exactly the
    /// "this group changed" signal insertion needs), this also catches a
    /// *moved* placement (same offset, different `modelMatrix`), which a
    /// bare count comparison would miss entirely.
    public static func placementsDiffer(_ lhs: [SceneryModelPlacement], _ rhs: [SceneryModelPlacement]) -> Bool {
        guard lhs.count == rhs.count else { return true }
        for (a, b) in zip(lhs, rhs) {
            if a.matrixFileOffset != b.matrixFileOffset { return true }
            if a.modelID != b.modelID || a.isSpecial != b.isSpecial { return true }
            if a.modelMatrix != b.modelMatrix { return true }
            if a.boundingBoxMin != b.boundingBoxMin || a.boundingBoxMax != b.boundingBoxMax { return true }
        }
        return false
    }
}

/// A node in the recursive scenery placement tree (`SceneryStruct`), up to
/// 8 child links, each either a nested group, a leaf model group, or empty,
/// selected by a type tag read just ahead of the link contents
/// (`LoadScenery`: `0x1600` = nested group, `0x1605` = leaf model group,
/// anything else = empty).
public indirect enum SceneryLink: Sendable {
    case group(SceneryGroup)
    case modelGroup(SceneryModelGroup)
    case empty
}

public struct SceneryGroup: Sendable {
    public var model: SceneryModelGroup
    public var links: [SceneryLink]

    public init(model: SceneryModelGroup, links: [SceneryLink]) {
        self.model = model
        self.links = links
    }

    /// Flattens the whole recursive tree into every placement with an
    /// actual transform, what a level-assembly viewport actually needs to
    /// draw, without the caller having to walk the tree itself.
    public func flattenedPlacements() -> [SceneryModelPlacement] {
        var result = model.placements
        for link in links {
            switch link {
            case .group(let child): result.append(contentsOf: child.flattenedPlacements())
            case .modelGroup(let group): result.append(contentsOf: group.placements)
            case .empty: break
            }
        }
        return result
    }

    /// "Real Delete for Existing Scenery": recursively removes every
    /// placement, wherever it lives in the nested group tree, not just
    /// this group's own `model.placements`, whose `matrixFileOffset` is
    /// in `offsets`. `matrixFileOffset` is already a real, unique byte
    /// position per on-disk placement (see its own doc comment), so a
    /// plain depth-first filter by that offset finds exactly the right
    /// placement with no separate path/index scheme needed, the same way
    /// `flattenedPlacements()` above needs no path to *read* every
    /// placement.
    public func removingPlacements(withFileOffsets offsets: Set<Int>) -> SceneryGroup {
        guard !offsets.isEmpty else { return self }
        var copy = self
        copy.model = model.removingPlacements(withFileOffsets: offsets)
        copy.links = links.map { link in
            switch link {
            case .group(let child): return .group(child.removingPlacements(withFileOffsets: offsets))
            case .modelGroup(let group): return .modelGroup(group.removingPlacements(withFileOffsets: offsets))
            case .empty: return .empty
            }
        }
        return copy
    }

    /// Real, reported bug ("place scenery, it pops in and out of view
    /// depending purely on camera angle, even far from anything special
    /// like water, even with correct per-object collision and a correct
    /// bounding box") that a brand-new placement always went straight into
    /// the *tree's own top-level root* (`model.placements`), regardless of
    /// where in the level it actually is, every real, dev-authored
    /// placement, by contrast, is distributed into this tree's real nested
    /// `.group`/`.modelGroup` structure. Every group here also carries 5
    /// real `Vector4`s (`SceneryModelGroup.unkPos`) this project has never
    /// decoded and only ever round-trips unchanged, the shape a group-
    /// level coarse visibility/culling bound would take, and a very
    /// plausible real explanation for "an object placed outside whatever
    /// volume its group's own stale bound claims to cover flickers based on
    /// where the camera is," independent of the object's own real position.
    ///
    /// Rather than *guess* at what `unkPos` means and risk writing
    /// something actively wrong into data this project has never verified,
    /// this takes the safer path: find the real, on-disk placement nearest
    /// `targetPosition` anywhere in the tree, and insert the new placement
    /// into that *same* node instead of always the root, so a fresh
    /// placement inherits whatever real grouping its closest actual
    /// neighbor already has, rather than being the one placement in the
    /// entire level sitting in the wrong part of the tree. Falls back to
    /// the previous, always-root behavior when the tree has no existing,
    /// real (non-session-placed) placement anywhere to compare against.
    public func insertingPlacementNearestExistingNeighbor(_ newPlacement: SceneryModelPlacement, targetPosition: SIMD3<Float>) -> SceneryGroup {
        func nearestOffset(in group: SceneryGroup) -> (distance: Float, offset: Int)? {
            func considerAll(_ placements: [SceneryModelPlacement]) -> (Float, Int)? {
                var best: (Float, Int)?
                for placement in placements {
                    guard let t = placement.translation, let offset = placement.matrixFileOffset else { continue }
                    let d = simd_distance(t, targetPosition)
                    if best == nil || d < best!.0 { best = (d, offset) }
                }
                return best
            }
            var best = considerAll(group.model.placements)
            for link in group.links {
                let childBest: (Float, Int)?
                switch link {
                case .group(let child): childBest = nearestOffset(in: child)
                case .modelGroup(let modelGroup): childBest = considerAll(modelGroup.placements)
                case .empty: childBest = nil
                }
                if let c = childBest, best == nil || c.0 < best!.0 { best = c }
            }
            return best
        }
        func inserting(offset targetOffset: Int, into group: SceneryGroup) -> SceneryGroup {
            var copy = group
            if copy.model.placements.contains(where: { $0.matrixFileOffset == targetOffset }) {
                let insertIndex = copy.model.placements.firstIndex(where: { $0.isSpecial }) ?? copy.model.placements.count
                copy.model.placements.insert(newPlacement, at: insertIndex)
                return copy
            }
            copy.links = copy.links.map { link in
                switch link {
                case .group(let child): return .group(inserting(offset: targetOffset, into: child))
                case .modelGroup(var modelGroup):
                    guard modelGroup.placements.contains(where: { $0.matrixFileOffset == targetOffset }) else { return .modelGroup(modelGroup) }
                    let insertIndex = modelGroup.placements.firstIndex(where: { $0.isSpecial }) ?? modelGroup.placements.count
                    modelGroup.placements.insert(newPlacement, at: insertIndex)
                    return .modelGroup(modelGroup)
                case .empty: return .empty
                }
            }
            return copy
        }
        guard let nearest = nearestOffset(in: self) else {
            var copy = self
            let insertIndex = copy.model.placements.firstIndex(where: { $0.isSpecial }) ?? copy.model.placements.count
            copy.model.placements.insert(newPlacement, at: insertIndex)
            return copy
        }
        return inserting(offset: nearest.offset, into: self)
    }

    /// Recomputes every real group-level culling bound below this node
    /// (see `SceneryModelGroup.computingUnkPos(covering:)`'s own doc
    /// comment for the decoded format and its real-data confirmation) , 
    /// call this once, on the tree's own root, after any edit that changes
    /// which placements live where (insert, delete, or move into a
    /// different group), so a group's `unkPos` never goes stale relative to
    /// its current real membership. **Real-game visibility bug this fixes:**
    /// a placement whose group's `unkPos` doesn't cover it can fail the PS2
    /// engine's own coarse culling test depending on camera angle, even
    /// though the placement's own position/collision/model data are all
    /// otherwise correct, exactly the "pops in and out of existence
    /// depending purely on camera angle" symptom this was written to fix.
    ///
    /// Every leaf `.modelGroup` and every internal `.group` node's own
    /// `model` gets recomputed from its real, current placements (a leaf
    /// from just its own; an internal node's `model` from its *entire*
    /// subtree, own placements plus every descendant link's), **except
    /// the tree's own outermost root**, whose `model.unkPos` is left
    /// untouched: real, on-disk root-level values don't follow this same
    /// covering relationship at all (see `computingUnkPos`'s doc comment),
    /// so there's no confirmed formula to recompute it *to*, and nothing
    /// in this codebase's placement paths relies on the root's own bound
    /// covering anything (new placements that intentionally join the root
    /// directly, e.g. cross-level scenery, do so on the documented
    /// assumption no group-level bound needs maintaining for them).
    /// **Prefer `recomputingUnkPos(sinceEditFrom:)` over this** whenever a
    /// real pre-edit baseline is available (every real save site has one , 
    /// see that function's own doc comment for why this whole-tree version
    /// was a real, reported regression when used as the *only* recompute
    /// path: it overwrites every group's `unkPos`, including ones this
    /// edit never touched, with this codebase's own reconstruction of the
    /// format, real-disc testing found that reconstruction isn't a
    /// bit-exact match for every real group (~99.3%, not 100%), so
    /// previously-fine objects in *untouched* groups could newly fail the
    /// PS2 engine's own culling test. This blind version remains useful
    /// when no baseline exists at all (a brand-new tree with no prior
    /// on-disk state) and for tests that want to validate the capsule
    /// formula itself against real data, independent of edit-scoping.
    public func recomputingUnkPosRecursively() -> SceneryGroup {
        recomputingUnkPos(isRoot: true)
    }

    private func recomputingUnkPos(isRoot: Bool) -> SceneryGroup {
        var copy = self
        copy.links = links.map { link in
            switch link {
            case .group(let child): return .group(child.recomputingUnkPos(isRoot: false))
            case .modelGroup(let modelGroup): return .modelGroup(modelGroup.recomputingUnkPos())
            case .empty: return .empty
            }
        }
        if !isRoot {
            // The *whole subtree*, own placements plus every descendant
            // link's, not just this node's own `model.placements` (real
            // dev-authored internal `.group` nodes very often keep their
            // own `model.placements` empty, with every real placement
            // living in nested leaf groups instead; the group-level bound
            // still has to cover them, confirmed against real disc data).
            copy.model.unkPos = SceneryModelGroup.computingUnkPos(covering: copy.flattenedPlacements())
        }
        return copy
    }

    /// **What production actually calls.** Two real, reported regressions
    /// went into this function's current shape, each caught live by a real
    /// PCSX2 boot after the previous version looked correct in every
    /// offline test:
    ///
    /// 1. The first version (`recomputingUnkPosRecursively()`, called
    ///    unconditionally on every save) recomputed *every* group's
    ///    `unkPos`, including ones the edit never touched, this function
    ///    fixes that by scoping to only groups whose own placements, or
    ///    some descendant's, actually differ from `original` (the tree as
    ///    decoded immediately before this edit). Every untouched group's
    ///    real, dev-authored `unkPos` bytes are preserved exactly, byte for
    ///    byte.
    /// 2. Scoping alone wasn't enough: even for the one group an edit
    ///    genuinely touched, replacing its whole capsule with a from-
    ///    scratch reconstruction (`computingUnkPos(covering:)`) broke
    ///    visibility for objects in that same group that were fine before
    ///   , see `expandingUnkPos(_:toCover:)`'s own doc comment for why.
    ///    This function now calls that instead: every changed group's
    ///    *original* axis/orientation is preserved exactly, only the
    ///    shared radius ever grows.
    ///
    /// `original` must have the *same tree topology* as `self` (same
    /// number of links at every level, in the same order), true for any
    /// real edit this codebase makes, since insert/remove/move only ever
    /// change a placement *array* somewhere in the tree, never the tree's
    /// own shape. A topology mismatch (shouldn't happen for a real edit)
    /// falls back to leaving that mismatched subtree's own `unkPos`
    /// untouched, rather than guessing.
    ///
    /// Placement identity for the diff is `matrixFileOffset` where present
    /// (an existing, on-disk placement), a placement lacking one (freshly
    /// inserted this edit, no offset yet) always counts as a difference,
    /// which is exactly the "this group changed" signal insertion needs.
    /// A *moved* placement (same offset, different `modelMatrix`) is also
    /// caught this way, and `expandingUnkPos` correctly handles it without
    /// needing to know which placements specifically moved: it checks
    /// every current placement in a changed group against that group's
    /// *original* axis, growing the radius only for whichever ones the
    /// original doesn't already cover.
    public func recomputingUnkPos(sinceEditFrom original: SceneryGroup) -> SceneryGroup {
        recomputingUnkPos(sinceEditFrom: original, isRoot: true)
    }

    private func recomputingUnkPos(sinceEditFrom original: SceneryGroup, isRoot: Bool) -> SceneryGroup {
        var copy = self
        var anyDescendantChanged = false
        if links.count == original.links.count {
            copy.links = zip(links, original.links).map { link, originalLink -> SceneryLink in
                switch (link, originalLink) {
                case (.group(let child), .group(let originalChild)):
                    if SceneryModelGroup.placementsDiffer(child.flattenedPlacements(), originalChild.flattenedPlacements()) {
                        anyDescendantChanged = true
                        return .group(child.recomputingUnkPos(sinceEditFrom: originalChild, isRoot: false))
                    }
                    return .group(child)
                case (.modelGroup(let modelGroup), .modelGroup(let originalModelGroup)):
                    if SceneryModelGroup.placementsDiffer(modelGroup.placements, originalModelGroup.placements) {
                        anyDescendantChanged = true
                        var expanded = modelGroup
                        expanded.unkPos = SceneryModelGroup.expandingUnkPos(originalModelGroup.unkPos, toCover: modelGroup.placements)
                        return .modelGroup(expanded)
                    }
                    return .modelGroup(modelGroup)
                case (.empty, .empty):
                    return link
                default:
                    // Topology mismatch, shouldn't happen for a real
                    // edit (see this function's own doc comment). Leave
                    // this link exactly as it already is rather than guess.
                    return link
                }
            }
        }
        let ownChanged = SceneryModelGroup.placementsDiffer(model.placements, original.model.placements)
        if ownChanged || anyDescendantChanged {
            // The root too: the game tests the root cell's box like any other (SceneryTree::Render), and one that doesn't hold a
            // new placement hides the whole tree's drawing of it from some angles. Only ever grown, never recomputed (its own
            // convention isn't the placements' bounds), so an untouched root stays byte for byte as it was
            copy.model.unkPos = SceneryModelGroup.expandingUnkPos(original.model.unkPos, toCover: copy.flattenedPlacements())
        }
        return copy
    }
}

/// A single light entry, every one of `SceneryData`'s 4 light kinds
/// (`LightAmbient`/`LightDirectional`/`LightPoint`/`LightNegative`, each a
/// subclass of the reference's own `LightBase` in `SceneryData.cs`) shares
/// this one flat shape now, superset of every kind's fields, which of the
/// extra fields (`vector3`/`unkShort`/`unkFloat1`/`2`/`unkUInt1`/`2`/
/// `unkUShort1`/`2`) actually get written back out is determined purely by
/// *which array* a light is stored in (`SceneryAsset.directionalLights`
/// writes `vector3`+`unkShort`, `.pointLights` writes only `unkShort`,
/// `.negativeLights` writes `vector3` plus all 6 remaining unk fields,
/// `.ambientLights` writes none of them), see `SceneryDataWriter`.
/// Real fields kept for round-tripping even though nothing in this pass
/// renders lighting from level data yet.
public struct SceneryLight: Sendable {
    public var flagsRaw: UInt32
    public var radius: Float
    public var colorR: Float
    public var colorG: Float
    public var colorB: Float
    public var colorUnk: Float
    public var position: SIMD4<Float>
    public var vector1: SIMD4<Float>
    public var vector2: SIMD4<Float>
    /// Directional/Negative only.
    public var vector3: SIMD4<Float>
    /// Directional/Point only.
    public var unkShort: UInt16
    /// Negative only.
    public var unkFloat1: Float
    public var unkFloat2: Float
    public var unkUInt1: UInt32
    public var unkUInt2: UInt32
    public var unkUShort1: UInt16
    public var unkUShort2: UInt16

    public init(
        flagsRaw: UInt32 = 0, radius: Float, colorR: Float, colorG: Float, colorB: Float, colorUnk: Float = 0,
        position: SIMD4<Float>, vector1: SIMD4<Float> = .zero, vector2: SIMD4<Float> = .zero,
        vector3: SIMD4<Float> = .zero, unkShort: UInt16 = 0,
        unkFloat1: Float = 0, unkFloat2: Float = 0, unkUInt1: UInt32 = 0, unkUInt2: UInt32 = 0,
        unkUShort1: UInt16 = 0, unkUShort2: UInt16 = 0
    ) {
        self.flagsRaw = flagsRaw
        self.radius = radius
        self.colorR = colorR
        self.colorG = colorG
        self.colorB = colorB
        self.colorUnk = colorUnk
        self.position = position
        self.vector1 = vector1
        self.vector2 = vector2
        self.vector3 = vector3
        self.unkShort = unkShort
        self.unkFloat1 = unkFloat1
        self.unkFloat2 = unkFloat2
        self.unkUInt1 = unkUInt1
        self.unkUInt2 = unkUInt2
        self.unkUShort1 = unkUShort1
        self.unkUShort2 = unkUShort2
    }

    /// Convenience view for existing display code, real `Color_R/G/B`
    /// packed into one vector, same as this type exposed before it grew
    /// the rest of its real fields.
    public var color: SIMD3<Float> {
        get { SIMD3(colorR, colorG, colorB) }
        set { colorR = newValue.x; colorG = newValue.y; colorB = newValue.z }
    }
}

/// A decoded `SceneryData` record (`Twinsanity/Items/SceneryData.cs`), a
/// whole level's static scenery placement tree, plus its ambient/
/// directional/point/negative lights.
public struct SceneryAsset: Sendable, Identifiable {
    public let id: UInt32
    /// Real opaque bitfield (`HeaderUnk1`), bit `0x10000` gates
    /// `skydomeID`, bit `0x20000` gates `headerBuffer`/lights. Kept as the
    /// real raw value (not just those two derived bools) since unknown
    /// other bits may be set in real data and must round-trip untouched.
    public var headerUnk1: UInt32
    public var chunkName: String
    public var headerUnk2: UInt32
    /// `HeaderUnk3`, gates whether `root`/`unkVar5` are present at all
    /// (`== 0x160A`). Kept raw for the same reason as `headerUnk1`.
    public var headerUnk3: UInt32
    public var headerUnk4: UInt8
    /// Whether this record's own file is a MonkeyBall-variant build , 
    /// gates 3 extra zero bytes right after `headerUnk2` on both read and
    /// write (`SceneryData.cs`'s own `IsMonkeyBall`, set by the *caller*
    /// before parsing based on which file kind this came from). This
    /// package doesn't currently distinguish that file kind at the
    /// dispatch level (see `SceneryDataParser`'s own doc comment), so this
    /// is always `false` for anything actually parsed by this build.
    public var isMonkeyBall: Bool
    public var skydomeID: UInt32?
    /// `HeaderBuffer`: the lights' 1024-byte reference table (`ChunkLights::references`), present when the lights follow
    /// (`headerUnk1 & 0x20000`). See `lightReferences` and the other named accessors below.
    public var headerBuffer: Data?
    public var ambientLights: [SceneryLight]
    public var directionalLights: [SceneryLight]
    public var pointLights: [SceneryLight]
    public var negativeLights: [SceneryLight]
    /// Present only alongside `root` (both gated by `headerUnk3 == 0x160A`).
    public var unkVar5: UInt32?
    /// `nil` when this record's `HeaderUnk3 != 0x160A`, the reference
    /// tool leaves the whole tree unset in that case too.
    public var root: SceneryGroup?

    public init(
        id: UInt32, headerUnk1: UInt32 = 0, chunkName: String, headerUnk2: UInt32 = 0, headerUnk3: UInt32 = 0x160A,
        headerUnk4: UInt8 = 0, isMonkeyBall: Bool = false, skydomeID: UInt32?, headerBuffer: Data? = nil,
        ambientLights: [SceneryLight], directionalLights: [SceneryLight], pointLights: [SceneryLight], negativeLights: [SceneryLight],
        unkVar5: UInt32? = nil, root: SceneryGroup?
    ) {
        self.id = id
        self.headerUnk1 = headerUnk1
        self.chunkName = chunkName
        self.headerUnk2 = headerUnk2
        self.headerUnk3 = headerUnk3
        self.headerUnk4 = headerUnk4
        self.isMonkeyBall = isMonkeyBall
        self.skydomeID = skydomeID
        self.headerBuffer = headerBuffer
        self.ambientLights = ambientLights
        self.directionalLights = directionalLights
        self.pointLights = pointLights
        self.negativeLights = negativeLights
        self.unkVar5 = unkVar5
        self.root = root
    }

    public var placements: [SceneryModelPlacement] { root?.flattenedPlacements() ?? [] }
}

/// One `DynamicSceneryData` entry (`Twinsanity/Items/DynamicSceneryData.cs`)
///, a movable/animated scenery piece (elevators, rotating platforms, ...).
/// Only its *resting* placement is exposed: `worldPosition`/
/// `worldRotation` are the reference tool's own reconciliation of "static
/// value if this channel doesn't animate, else the first keyframe", full
/// per-frame motion curves aren't modeled, since nothing renders scenery
/// animation yet (see `DynamicSceneryDataParser` for exactly what's parsed
/// vs. discarded to reach this).
public struct DynamicSceneryPlacement: Sendable {
    public var modelID: UInt32
    public var boundingBoxMin: SIMD4<Float>
    public var boundingBoxMax: SIMD4<Float>
    public var worldPosition: SIMD3<Float>
    public var worldRotation: SIMD4<Float>

    public init(modelID: UInt32, boundingBoxMin: SIMD4<Float>, boundingBoxMax: SIMD4<Float>, worldPosition: SIMD3<Float>, worldRotation: SIMD4<Float>) {
        self.modelID = modelID
        self.boundingBoxMin = boundingBoxMin
        self.boundingBoxMax = boundingBoxMax
        self.worldPosition = worldPosition
        self.worldRotation = worldRotation
    }
}

public struct DynamicSceneryAsset: Sendable, Identifiable {
    public let id: UInt32
    public var placements: [DynamicSceneryPlacement]

    public init(id: UInt32, placements: [DynamicSceneryPlacement]) {
        self.id = id
        self.placements = placements
    }
}

// MARK: - The header fields by what the game reads them as
// (twinsanity-reversed: ReadScenery, src/game/scenery.cpp; SceneryRoot::Read; ReadSceneryLights, src/game/lights.cpp). The raw
// names stay for round-tripping; these name what each one is.
extension SceneryAsset {
    /// `headerUnk1`: the chunk's flags word (`ChunkFlags`): bit 16 a sky follows (`skydomeID`), bit 17 the lights follow
    /// (`headerBuffer` and the light lists). The low 16 bits are the game's own draw stamp at run time.
    public var chunkFlags: UInt32 {
        get { headerUnk1 }
        set { headerUnk1 = newValue }
    }
    public var hasSky: Bool { headerUnk1 & 0x10000 != 0 }
    public var hasLights: Bool { headerUnk1 & 0x20000 != 0 }
    /// `headerUnk2`: the chunk's colour filter palette (`ChunkData::colourFilterPalette`)
    public var colourFilterPalette: UInt32 {
        get { headerUnk2 }
        set { headerUnk2 = newValue }
    }
    /// `headerUnk3`: the scenery root's type ID (`SceneryRoot::TypeId`, 0x160A); any other value means no tree
    public var rootTypeID: UInt32 {
        get { headerUnk3 }
        set { headerUnk3 = newValue }
    }
    /// `headerUnk4`: a byte the game reads and never uses (`ChunkData::unusedByte`)
    public var unusedByte: UInt8 {
        get { headerUnk4 }
        set { headerUnk4 = newValue }
    }
    /// `unkVar5`: the scenery tree's depth (`SceneryRoot::treeDepth`, what `FindCell` descends to when placing instances in
    /// cells)
    public var treeDepth: UInt32? {
        get { unkVar5 }
        set { unkVar5 = newValue }
    }
    /// `headerBuffer`: the lights' reference table (`ChunkLights::references`, 1024 bytes, read first when the lights follow)
    public var lightReferences: Data? {
        get { headerBuffer }
        set { headerBuffer = newValue }
    }
}
