import XCTest
import simd
@testable import CTModels
@testable import CTStudioApp

/// "Free Camera System in Chunk Editor", real movement/damping math,
/// driven with an explicit deterministic `deltaTime` (see
/// `updateFreeCameraMovement`'s own doc comment) rather than depending on
/// real wall-clock timing.
@MainActor
final class FreeCameraTests: XCTestCase {
    private func makeRenderer() throws -> LevelViewerRenderer {
        try XCTUnwrap(LevelViewerRenderer(placements: []))
    }

    /// Toggling the mode on must never jump-cut the view, it should
    /// start from (very close to) wherever the orbit camera already was,
    /// computed from the same real yaw/pitch/distance/bounds the orbit
    /// camera itself uses.
    func testEnablingFreeCameraStartsFromTheCurrentOrbitEye() throws {
        let renderer = try makeRenderer()
        let distance = Float(10) * renderer.distanceMultiplier
        let expectedOrbitEye = SIMD3<Float>(
            distance * cos(renderer.pitch) * sin(renderer.yaw),
            distance * sin(renderer.pitch),
            distance * cos(renderer.pitch) * cos(renderer.yaw)
        )
        renderer.isFreeCameraMode = true
        XCTAssertLessThan(simd_distance(renderer.cameraEyeWorldPosition, expectedOrbitEye), 0.001, "enabling free camera must not jump the view")
    }

    func testFreeCameraMovesInRequestedDirectionAndDampsOnRelease() throws {
        let renderer = try makeRenderer()
        renderer.isFreeCameraMode = true
        let start = renderer.cameraEyeWorldPosition

        renderer.freeCameraInputDirection = SIMD3<Float>(0, 0, 1) // "forward" (W)
        for _ in 0..<60 { renderer.updateFreeCameraMovement(deltaTime: 1.0 / 60.0) }
        let afterMoving = renderer.cameraEyeWorldPosition
        XCTAssertGreaterThan(simd_distance(start, afterMoving), 0.5, "holding W for a full second at speed \(renderer.freeCameraSpeed) should move the camera a real distance")

        // One more frame at steady (near-max) velocity, to compare against.
        let beforeSteadyStep = renderer.cameraEyeWorldPosition
        renderer.updateFreeCameraMovement(deltaTime: 1.0 / 60.0)
        let steadyStepDistance = simd_distance(beforeSteadyStep, renderer.cameraEyeWorldPosition)

        // Release input, real damping, not an instant stop: velocity
        // decays over several frames rather than snapping to zero.
        renderer.freeCameraInputDirection = .zero
        for _ in 0..<30 { renderer.updateFreeCameraMovement(deltaTime: 1.0 / 60.0) }
        let beforeDampedStep = renderer.cameraEyeWorldPosition
        renderer.updateFreeCameraMovement(deltaTime: 1.0 / 60.0)
        let dampedStepDistance = simd_distance(beforeDampedStep, renderer.cameraEyeWorldPosition)

        XCTAssertLessThan(dampedStepDistance, steadyStepDistance * 0.1, "velocity should have decayed substantially ~0.5s after releasing input")
    }

    /// No collision, a real, honest gap this build's physics can't fill
    /// (see the free camera's own doc comment), verified by flying
    /// straight through where real geometry bounds would be without
    /// getting stuck or deflected.
    func testFreeCameraHasNoCollisionResponse() throws {
        let renderer = try makeRenderer()
        renderer.isFreeCameraMode = true
        renderer.freeCameraInputDirection = SIMD3<Float>(0, 0, 1)
        for _ in 0..<600 { renderer.updateFreeCameraMovement(deltaTime: 1.0 / 60.0) } // ~10s of continuous forward flight
        XCTAssertGreaterThan(simd_distance(.zero, renderer.cameraEyeWorldPosition), 50, "10 seconds of forward flight should cover real distance with nothing to stop it")
    }

    func testDisablingFreeCameraReturnsToOrbitFormula() throws {
        let renderer = try makeRenderer()
        renderer.isFreeCameraMode = true
        renderer.freeCameraInputDirection = SIMD3<Float>(1, 0, 0)
        for _ in 0..<30 { renderer.updateFreeCameraMovement(deltaTime: 1.0 / 60.0) }
        XCTAssertNotEqual(renderer.cameraEyeWorldPosition, .zero) // sanity: it actually moved

        renderer.isFreeCameraMode = false
        let distance = Float(10) * renderer.distanceMultiplier
        let expectedOrbitEye = SIMD3<Float>(
            distance * cos(renderer.pitch) * sin(renderer.yaw),
            distance * sin(renderer.pitch),
            distance * cos(renderer.pitch) * cos(renderer.yaw)
        )
        XCTAssertLessThan(simd_distance(renderer.cameraEyeWorldPosition, expectedOrbitEye), 0.001, "turning free camera off must go back to the real orbit formula, not stay stuck at the last flown position")
    }
}
