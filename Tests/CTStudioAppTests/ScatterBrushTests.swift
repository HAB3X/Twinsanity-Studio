import XCTest
import simd
@testable import CTModels
@testable import CTStudioApp

/// "Procedural Brush" (roadmap 8.6), scattering through the real
/// spawn+write-back pipeline, not a purely visual copy.
@MainActor
final class ScatterBrushTests: XCTestCase {
    private func makeRenderer() throws -> LevelViewerRenderer {
        try XCTUnwrap(LevelViewerRenderer(placements: []))
    }

    func testScatterAroundAFreshlyPlacedActorSpawnsRealNewInstances() throws {
        let renderer = try makeRenderer()
        guard let originalIndex = renderer.spawnInstance(objectID: 42, at: SIMD3<Float>(5, 0, 5)) else {
            return XCTFail("spawnInstance failed, asset resolution unavailable in this test environment")
        }
        let countBefore = renderer.objectCount

        let newIndices = renderer.scatterAroundSelected(count: 6, radius: 3)
        XCTAssertEqual(newIndices.count, 6)
        XCTAssertEqual(renderer.objectCount, countBefore + 6)

        for index in newIndices {
            let info = try XCTUnwrap(renderer.newInstanceInfo(at: index))
            XCTAssertEqual(info.objectID, 42, "every scattered copy must carry the same real objectID as the original")
            let distance = simd_distance(info.worldPosition, SIMD3<Float>(5, 0, 5))
            XCTAssertLessThanOrEqual(distance, 3.01, "every scattered copy must land within the requested radius")
        }
        XCTAssertNotEqual(originalIndex, newIndices.first)
    }

    /// A brush that always drops every copy in an identical spot would be
    /// useless for set-dressing, this pins that real randomization is
    /// actually happening, not a fixed offset repeated N times.
    func testScatteredCopiesLandAtDistinctPositions() throws {
        let renderer = try makeRenderer()
        guard renderer.spawnInstance(objectID: 7, at: .zero) != nil else {
            return XCTFail("spawnInstance failed, asset resolution unavailable in this test environment")
        }
        let newIndices = renderer.scatterAroundSelected(count: 10, radius: 5)
        let positions = newIndices.compactMap { renderer.newInstanceInfo(at: $0)?.worldPosition }
        let distinctPositions = Set(positions.map { "\($0.x),\($0.z)" })
        XCTAssertGreaterThan(distinctPositions.count, 1, "10 random scatter points landing on the exact same spot is not a real random distribution")
    }

    func testScatterWithNoSelectionIsANoOp() throws {
        let renderer = try makeRenderer()
        XCTAssertEqual(renderer.scatterAroundSelected(count: 5, radius: 3), [])
    }

    func testScatterOfAnAIWaypointIsANoOp() throws {
        // AI waypoints have no real "set-dressing" spawn semantics the
        // roadmap asks for here, only Instance placements (.actors) do.
        let renderer = try makeRenderer()
        guard renderer.spawnAIWaypoint(at: SIMD3<Float>(1, 2, 3), rawNodeType: 0) != nil else {
            return XCTFail("spawnAIWaypoint failed")
        }
        XCTAssertEqual(renderer.scatterAroundSelected(count: 5, radius: 3), [])
    }

    func testZeroCountOrZeroRadiusIsANoOp() throws {
        let renderer = try makeRenderer()
        guard renderer.spawnInstance(objectID: 42, at: .zero) != nil else {
            return XCTFail("spawnInstance failed, asset resolution unavailable in this test environment")
        }
        XCTAssertEqual(renderer.scatterAroundSelected(count: 0, radius: 5), [])
        XCTAssertEqual(renderer.scatterAroundSelected(count: 5, radius: 0), [])
    }
}
