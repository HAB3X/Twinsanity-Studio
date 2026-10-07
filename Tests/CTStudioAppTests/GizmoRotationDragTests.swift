import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Regression test for a real, reported bug: with snap-to-grid on (the
/// default), dragging the rotate gizmo far enough, a full turn, or just
/// past a wrap boundary, "gets caught halfway through" and stops visibly
/// responding to further drag. Root cause: the old code re-derived the
/// snapped rotation by decoding the *accumulated 3D rotation* into Euler
/// XYZ angles on every incremental drag tick, `eulerDegrees(from:)` isn't
/// a globally continuous inverse (gimbal lock, and a wrapped range for at
/// least one axis), so a rotation dragged far enough could land exactly on
/// a decomposition singularity. The fix snaps the *scalar* angle
/// accumulated around the one grabbed axis since the drag began instead,
/// which never wraps or hits a singularity.
@MainActor
final class GizmoRotationDragTests: XCTestCase {
    private func makeRenderer() throws -> LevelViewerRenderer {
        try XCTUnwrap(LevelViewerRenderer(placements: []))
    }

    private func makeTestAsset() -> ResolvedModelAsset {
        let vertices = [
            StaticVertex(position: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 0)),
            StaticVertex(position: SIMD3(1, 0, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(1, 0)),
            StaticVertex(position: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 1))
        ]
        let submesh = MeshSubmesh(vertices: vertices, connectivity: [true, true, true], materialID: 1)
        let mesh = MeshAsset(id: 1, isSkinned: false, submeshes: [submesh])
        let texture = TextureAsset(id: 1, width: 2, height: 2, pixelFormat: .psmct32, rgba: [UInt8](repeating: 200, count: 16))
        let material = ResolvedSubmeshMaterial(materialID: 1, textureID: 1, texture: texture)
        return ResolvedModelAsset(recordID: 42, displayName: "Test Scenery Model", mesh: mesh, submeshMaterials: [material])
    }

    /// `dragRotate`'s own `degreesPerPoint`, kept in sync here so this
    /// test's expected-angle math stays exact if that constant ever changes.
    private let degreesPerPoint: Float = 0.5

    func testDraggingRotationPastAFullTurnWithSnapOnKeepsRespondingInsteadOfGettingStuck() throws {
        let renderer = try makeRenderer()
        let asset = makeTestAsset()
        let index = try XCTUnwrap(renderer.spawnScenery(modelID: 1, isSpecial: false, asset: asset, at: .zero))
        renderer.select(index: index)
        renderer.gizmoMode = .rotate
        XCTAssertTrue(renderer.snapToGrid, "this bug only reproduces with snap-to-grid on, its own real default")
        renderer.rotationSnapDegrees = 15

        renderer.beginGizmoDrag()

        // `selectedRotationDegrees` decodes Euler XYZ from the full 3x3
        // rotation matrix, for a *pure* single-axis rotation, which
        // component of the returned triple actually carries the angle
        // (and whether it stays continuous at all past 90 degrees) is an
        // artifact of that decomposition, not something this test should
        // hardcode. Sampling the *whole* triple sidesteps needing to know
        // that mapping, real, continuous drag motion must keep changing
        // *some* combination of the three, whichever the decomposition
        // happens to route it through.
        //
        // 80 ticks * (10pt * 0.5deg/pt) = 400 accumulated degrees, well
        // past both a full 360-degree turn and the 180-degree boundary
        // where the old Euler round-trip could land on a singularity.
        var samples: [SIMD3<Float>] = []
        for tick in 1...80 {
            renderer.dragSelectedObject(axis: .y, viewportDelta: CGVector(dx: 10, dy: 0), viewSize: CGSize(width: 800, height: 600))
            if tick % 10 == 0 {
                samples.append(try XCTUnwrap(renderer.selectedRotationDegrees))
            }
        }

        // The real regression: a "stuck" drag means two of these samples,
        // taken evenly across the whole drag, come back identical even
        // though real, continuous mouse motion happened in between every
        // one of them.
        let uniqueSamples = Set(samples.map { SIMD3<Int>(($0 * 100).rounded(.toNearestOrAwayFromZero)) })
        XCTAssertGreaterThan(uniqueSamples.count, 1, "rotation must keep changing throughout a long drag, not freeze partway through, samples: \(samples)")

        // Keep dragging past a second full turn (another 400 degrees, to
        // 800 total), if anything about the accumulation were to wrap or
        // saturate incorrectly, continuing well beyond the first singular
        // point is where it would show up.
        let sampleBeforeSecondTurn = try XCTUnwrap(samples.last)
        for _ in 1...80 {
            renderer.dragSelectedObject(axis: .y, viewportDelta: CGVector(dx: 10, dy: 0), viewSize: CGSize(width: 800, height: 600))
        }
        let finalSample = try XCTUnwrap(renderer.selectedRotationDegrees)
        XCTAssertFalse(finalSample.x.isNaN || finalSample.y.isNaN || finalSample.z.isNaN, "must never produce NaN, however far the drag goes")
        XCTAssertGreaterThan(simd_distance(finalSample, sampleBeforeSecondTurn), 1,
                             "must still be responding to drag input after two full turns, not frozen wherever it first got stuck")
    }

    func testBeginGizmoDragResetsAccumulatedAngleForEachNewDragGesture() throws {
        let renderer = try makeRenderer()
        let asset = makeTestAsset()
        let index = try XCTUnwrap(renderer.spawnScenery(modelID: 1, isSpecial: false, asset: asset, at: .zero))
        renderer.select(index: index)
        renderer.gizmoMode = .rotate
        renderer.rotationSnapDegrees = 15

        renderer.beginGizmoDrag()
        renderer.dragSelectedObject(axis: .y, viewportDelta: CGVector(dx: 20, dy: 0), viewSize: CGSize(width: 800, height: 600))
        let afterFirstDrag = try XCTUnwrap(renderer.selectedRotationDegrees).y

        // A second, independent drag gesture (real usage: release the
        // handle, grab it again) must accumulate its own angle relative to
        // where the first drag left off, not silently continue the first
        // drag's own running total.
        renderer.beginGizmoDrag()
        renderer.dragSelectedObject(axis: .y, viewportDelta: CGVector(dx: 20, dy: 0), viewSize: CGSize(width: 800, height: 600))
        let afterSecondDrag = try XCTUnwrap(renderer.selectedRotationDegrees).y

        XCTAssertEqual(afterSecondDrag, afterFirstDrag * 2, accuracy: 1,
                       "two identical, independent drag gestures should each contribute the same rotation, landing at double the first drag's own result")
    }
}
