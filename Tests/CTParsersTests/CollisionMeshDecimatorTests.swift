import XCTest
import simd
@testable import CTParsers

/// "Extremely accurate collision but with way less verts and triangles" , 
/// real, requested trade-off. `CollisionMeshDecimator` uses grid-snap
/// (vertex-clustering) decimation; these tests verify the actual mechanism
/// (vertices merge, degenerate triangles drop, real geometry survives)
/// rather than relying on any one synthetic mesh "happening" to shrink.
final class CollisionMeshDecimatorTests: XCTestCase {
    private typealias Triangle = LevelCollisionRebuilder.MeshTriangle

    func testDecimatingWeldsNearbyVerticesOntoTheSameGridPoint() {
        // Two triangles sharing a "seam" edge, authored as if from a real
        // render mesh with a UV split, same position, separately-indexed
        // originally, but at *exactly* the same spot, well within one grid
        // cell of `cellSize: 1.0`.
        let a = Triangle(v0: SIMD3(0, 0, 0), v1: SIMD3(1.02, 0, 0.01), v2: SIMD3(0, 1, 0))
        let b = Triangle(v0: SIMD3(0.98, 0, -0.02), v1: SIMD3(2, 0, 0), v2: SIMD3(1, 1, 0))
        let result = CollisionMeshDecimator.decimating([a, b], cellSize: 1.0)
        XCTAssertEqual(result.count, 2, "both real triangles should survive a modest grid size")
        // a.v1 and b.v0 are both ~(1, 0, 0) -- within the same 1.0 cell --
        // so they must snap to the exact same point.
        XCTAssertEqual(result[0].v1, result[1].v0, "vertices within the same grid cell must snap to an identical position")
    }

    func testDecimatingDropsTrianglesThatCollapseToZeroArea() {
        // A tiny sliver triangle entirely inside one grid cell -- all three
        // corners snap to the same point and must be dropped, not kept as
        // a degenerate (zero-area) triangle.
        let sliver = Triangle(v0: SIMD3(0.01, 0, 0), v1: SIMD3(0.02, 0.01, 0), v2: SIMD3(0, 0.02, 0.01))
        let result = CollisionMeshDecimator.decimating([sliver], cellSize: 1.0)
        XCTAssertTrue(result.isEmpty, "a triangle smaller than one grid cell must collapse away entirely, not survive degenerate")
    }

    func testDecimatingPreservesTrianglesFarApart() {
        let near = Triangle(v0: SIMD3(0, 0, 0), v1: SIMD3(1, 0, 0), v2: SIMD3(0, 1, 0))
        let far = Triangle(v0: SIMD3(100, 0, 0), v1: SIMD3(101, 0, 0), v2: SIMD3(100, 1, 0))
        let result = CollisionMeshDecimator.decimating([near, far], cellSize: 1.0)
        XCTAssertEqual(result.count, 2, "real, well-separated geometry must never be merged away")
    }

    /// The realistic case: a dense triangle fan (many small triangles
    /// packed into a small area, the way UV-seamed/tessellated real
    /// scenery meshes are authored) should genuinely shrink under
    /// decimation, not just re-snap 1:1.
    func testDecimatingMeaningfullyReducesADenseTriangleFan() {
        var triangles: [Triangle] = []
        let center = SIMD3<Float>(0, 0, 0)
        let segments = 64
        for i in 0..<segments {
            let a1 = Float(i) / Float(segments) * 2 * .pi
            let a2 = Float(i + 1) / Float(segments) * 2 * .pi
            let radius: Float = 1.5
            let p1 = center + SIMD3(radius * cos(a1), 0, radius * sin(a1))
            let p2 = center + SIMD3(radius * cos(a2), 0, radius * sin(a2))
            triangles.append(Triangle(v0: center, v1: p1, v2: p2))
        }
        XCTAssertEqual(triangles.count, 64)
        // A grid cell noticeably larger than the fan's own per-segment
        // spacing (circumference / segments ≈ 0.147) should collapse many
        // adjacent thin wedges together.
        let result = CollisionMeshDecimator.decimating(triangles, cellSize: 0.5)
        XCTAssertLessThan(result.count, 40, "a coarse enough grid must meaningfully cut the triangle count of dense, redundant geometry")
        XCTAssertFalse(result.isEmpty, "must not collapse the whole disc away at a moderate cell size")
    }

    func testDecimatingWithZeroOrInvalidCellSizeReturnsInputUnchanged() {
        let t = Triangle(v0: SIMD3(0, 0, 0), v1: SIMD3(1, 0, 0), v2: SIMD3(0, 1, 0))
        XCTAssertEqual(CollisionMeshDecimator.decimating([t], cellSize: 0).count, 1)
        XCTAssertEqual(CollisionMeshDecimator.decimating([t], cellSize: -1).count, 1)
    }

    func testAdaptiveCellSizeScalesWithObjectExtentAndHasAFloor() {
        let small = CollisionMeshDecimator.adaptiveCellSize(localMin: .zero, localMax: SIMD3(1, 1, 1))
        let large = CollisionMeshDecimator.adaptiveCellSize(localMin: .zero, localMax: SIMD3(100, 100, 100))
        XCTAssertLessThan(small, large, "a bigger object should get a coarser (larger) decimation grid")
        let degenerate = CollisionMeshDecimator.adaptiveCellSize(localMin: .zero, localMax: .zero)
        XCTAssertGreaterThan(degenerate, 0, "a zero-size object must still get a real, positive cell size (the floor), never zero")
    }
}
