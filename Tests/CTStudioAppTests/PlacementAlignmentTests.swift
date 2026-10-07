import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// "Align While Placing": placing a brand-new
/// object used to land exactly on the raw ground/collision raycast hit
/// with no alignment help at all, unlike dragging an *existing* object
/// (which already had magnet snap). This exercises the new placement-time
/// entry point (`LevelViewerRenderer.magnetSnappedPlacementPosition`, wired
/// into `spawnInstance`/`spawnScenery`/`spawnCrossLevelScenery`/
/// `addObject`) directly through `spawnInstance`, matching this file
/// family's own `SpawnAndDeleteTests` setup.
@MainActor
final class PlacementAlignmentTests: XCTestCase {
    private func makeRenderer() throws -> LevelViewerRenderer {
        try XCTUnwrap(LevelViewerRenderer(placements: []))
    }

    func testPlacingNearAnUnrelatedExistingObjectSnapsToItWhenNothingIsSelected() throws {
        let renderer = try makeRenderer()
        let existingIndex = try XCTUnwrap(renderer.spawnInstance(objectID: 3, at: SIMD3<Float>(10, 0, 0)))
        renderer.select(index: nil) // nothing selected -- falls back to nearest-of-any.

        // Close to the existing object's X (within magnetSnapThreshold)
        // but not exactly on it.
        let newIndex = try XCTUnwrap(renderer.spawnInstance(objectID: 3, at: SIMD3<Float>(10.3, 5, 5)))
        XCTAssertNotEqual(existingIndex, newIndex)
        let placed = try XCTUnwrap(renderer.newInstanceInfo(at: newIndex))
        XCTAssertEqual(placed.worldPosition.x, 10, accuracy: 0.0001, "with nothing selected, a new placement near an existing object should snap to it")
    }

    func testPlacingFarFromEverythingPassesThroughUnchanged() throws {
        let renderer = try makeRenderer()
        _ = try XCTUnwrap(renderer.spawnInstance(objectID: 3, at: SIMD3<Float>(1000, 0, 0)))
        renderer.select(index: nil)

        let target = SIMD3<Float>(0, 0, 0)
        let newIndex = try XCTUnwrap(renderer.spawnInstance(objectID: 3, at: target))
        let placed = try XCTUnwrap(renderer.newInstanceInfo(at: newIndex))
        XCTAssertEqual(placed.worldPosition, target, "far outside magnetSnapThreshold of anything -- should not snap")
    }

    /// The real, requested distinction: "select an item [to align to] or
    /// have it align to the nearest item." With a specific object
    /// selected, placement must align to *that* object even when a closer,
    /// unselected decoy exists nearby the actual placement point.
    func testPlacingWithAnObjectSelectedAlignsToThatObjectNotACloserDecoy() throws {
        let renderer = try makeRenderer()
        let chosenIndex = try XCTUnwrap(renderer.spawnInstance(objectID: 3, at: SIMD3<Float>(0, 0, 0)))
        _ = try XCTUnwrap(renderer.spawnInstance(objectID: 3, at: SIMD3<Float>(100, 0, 0))) // decoy, far from `chosen`
        renderer.select(index: chosenIndex) // explicit choice: align to THIS one.

        // Placed right next to the decoy (well within threshold of it),
        // but nowhere near the selected object's own X.
        let newIndex = try XCTUnwrap(renderer.spawnInstance(objectID: 3, at: SIMD3<Float>(100.05, 8, 8)))
        let placed = try XCTUnwrap(renderer.newInstanceInfo(at: newIndex))
        XCTAssertEqual(placed.worldPosition.x, 100.05, accuracy: 0.0001,
                        "with an object explicitly selected, placement must only ever consider that object -- not silently snap to a closer, unselected decoy")
    }

    func testMagnetSnapDisabledNeverSnapsPlacementEitherWay() throws {
        let renderer = try makeRenderer()
        renderer.magnetSnapEnabled = false
        let existingIndex = try XCTUnwrap(renderer.spawnInstance(objectID: 3, at: SIMD3<Float>(10, 0, 0)))
        renderer.select(index: existingIndex)

        let target = SIMD3<Float>(10.05, 0, 0)
        let newIndex = try XCTUnwrap(renderer.spawnInstance(objectID: 3, at: target))
        let placed = try XCTUnwrap(renderer.newInstanceInfo(at: newIndex))
        XCTAssertEqual(placed.worldPosition, target, "magnetSnapEnabled = false must disable placement-time alignment too, not just drag-time")
    }
}
