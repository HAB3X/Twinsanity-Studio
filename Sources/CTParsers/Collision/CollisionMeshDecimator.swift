import simd

/// Reduces a real mesh-triangle set's own vertex/triangle count while
/// keeping its real shape, real, requested trade-off: "extremely accurate
/// collision but with way less verts and triangles," not a box/hull
/// approximation traded for a lower count.
///
/// Uses vertex-clustering decimation (Rossignac & Borrel, 1993): every
/// vertex snaps to the nearest point on a `cellSize`-spaced grid. Vertices
/// that land on the same grid point become byte-identical, so
/// `LevelCollisionRebuilder`'s own per-group exact-position dedup collapses
/// them into one shared vertex with no separate merge step, this is also
/// exactly why two of the render mesh's own vertices at a UV/normal seam
/// (same position, different attributes, so never index-shared originally)
/// collapse into one here even before any real geometric simplification
/// happens. A triangle two of whose three corners snap together is
/// degenerate (zero area) and is dropped.
public enum CollisionMeshDecimator {
    /// `cellSize` is the grid spacing, in world units, larger means more
    /// aggressive reduction (and more shape loss on fine detail). `nil`/
    /// non-positive returns `triangles` unchanged.
    public static func decimating(_ triangles: [LevelCollisionRebuilder.MeshTriangle], cellSize: Float) -> [LevelCollisionRebuilder.MeshTriangle] {
        guard cellSize > 0, cellSize.isFinite else { return triangles }
        func snap(_ p: SIMD3<Float>) -> SIMD3<Float> {
            (p / cellSize).rounded(.toNearestOrAwayFromZero) * cellSize
        }
        var result: [LevelCollisionRebuilder.MeshTriangle] = []
        result.reserveCapacity(triangles.count)
        for t in triangles {
            let a = snap(t.v0), b = snap(t.v1), c = snap(t.v2)
            guard a != b, b != c, a != c else { continue }
            result.append(LevelCollisionRebuilder.MeshTriangle(v0: a, v1: b, v2: c))
        }
        return result
    }

    /// A grid size proportional to an object's own extent, a tiny prop
    /// gets fine decimation (barely changes), a huge merged terrain
    /// cluster gets coarser decimation (needed more). `targetSteps` is
    /// roughly how many grid cells span the object's longest axis;
    /// `minCellSize` is a floor so a degenerate (near-zero-size) object
    /// never produces a zero/near-zero cell size.
    public static func adaptiveCellSize(localMin: SIMD3<Float>, localMax: SIMD3<Float>, targetSteps: Float = 48, minCellSize: Float = 0.02) -> Float {
        let extent = localMax - localMin
        let longestAxis = max(extent.x, extent.y, extent.z)
        guard longestAxis.isFinite, longestAxis > 0 else { return minCellSize }
        return max(longestAxis / targetSteps, minCellSize)
    }
}
