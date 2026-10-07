import XCTest
import CTModels

final class MeshGeometryTests: XCTestCase {
    /// Pins the triangle-strip decode exactly as re-derived from
    /// `Model.ToPLY`'s face-*counting* loop (`Model.cs:303`,
    /// `Vertexes[f + 2].Conn`) rather than its inconsistent face-*writing*
    /// loop three lines later (`Model.cs:341`, `Vertexes[i].Conn`, the two
    /// loops in the reference tool disagree with each other): the
    /// connectivity flag on the *apex* vertex `i+2` gates candidate
    /// triangle `(i, i+1, i+2)`, and the first two indices swap on odd `i`.
    func testTriangleIndicesMatchReferenceWindingOrder() {
        let vertices = (0..<6).map { StaticVertex(position: SIMD3(Float($0), 0, 0)) }
        // Apex flags (index 2 onward) alternate true/true/false/true; the
        // first two entries are never read as an apex and are set false to
        // make that explicit.
        let submesh = MeshSubmesh(vertices: vertices, connectivity: [false, false, true, true, false, true])
        let triangles = submesh.triangleIndices()

        // i=0 (even), apex conn[2]=true: (0, 1, 2).
        // i=1 (odd), apex conn[3]=true: swap -> (2, 1, 3).
        // i=2 (even), apex conn[4]=false: skipped.
        // i=3 (odd), apex conn[5]=true: swap -> (4, 3, 5).
        XCTAssertEqual(triangles.count, 3)
        XCTAssertEqual(triangles[0].0, 0); XCTAssertEqual(triangles[0].1, 1); XCTAssertEqual(triangles[0].2, 2)
        XCTAssertEqual(triangles[1].0, 2); XCTAssertEqual(triangles[1].1, 1); XCTAssertEqual(triangles[1].2, 3)
        XCTAssertEqual(triangles[2].0, 4); XCTAssertEqual(triangles[2].1, 3); XCTAssertEqual(triangles[2].2, 5)
    }

    func testDisconnectedVerticesProduceNoTriangles() {
        let vertices = (0..<4).map { StaticVertex(position: SIMD3(Float($0), 0, 0)) }
        let submesh = MeshSubmesh(vertices: vertices, connectivity: [false, false, false, false])
        XCTAssertTrue(submesh.triangleIndices().isEmpty)
    }

    func testFewerThanThreeVerticesProducesNoTriangles() {
        let submesh = MeshSubmesh(vertices: [StaticVertex(position: .zero), StaticVertex(position: .zero)], connectivity: [true, true])
        XCTAssertTrue(submesh.triangleIndices().isEmpty)
    }

    /// `triangleCount` exists purely so stat labels (re-evaluated on every
    /// SwiftUI body pass, including every animation-playback frame) don't
    /// have to allocate and immediately discard the full triangle-tuple
    /// array just to read its length, it must always agree with the real
    /// thing's count.
    func testTriangleCountMatchesTriangleIndicesCount() {
        let vertices = (0..<6).map { StaticVertex(position: SIMD3(Float($0), 0, 0)) }
        let submesh = MeshSubmesh(vertices: vertices, connectivity: [false, false, true, true, false, true])
        XCTAssertEqual(submesh.triangleCount, submesh.triangleIndices().count)

        let empty = MeshSubmesh(vertices: [StaticVertex(position: .zero), StaticVertex(position: .zero)], connectivity: [true, true])
        XCTAssertEqual(empty.triangleCount, empty.triangleIndices().count)
    }
}
