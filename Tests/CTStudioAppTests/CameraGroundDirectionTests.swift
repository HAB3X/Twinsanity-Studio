import XCTest
import simd
@testable import CTStudioApp

/// Real, reported bug: the left/right movement-arrow HUD (and WASD ground
/// strafing) had `cameraGroundRight()`/`freeCameraRight()` computing the
/// mathematically wrong cross-product order (`up × forward` instead of
/// `forward × up`), which flips the sign of "right" for every yaw. Ground
/// truth this pins against: `LevelViewerRenderer` itself already hardcodes
/// `forward = (0,0,-1), right = (1,0,0)` for top-down mode
/// (`cameraGroundForward`/`cameraGroundRight`'s own top-down branches) --
/// orbit mode's own `cameraGroundForward()` at `yaw == 0` evaluates to that
/// exact same `(0,0,-1)`, so orbit's own `right` at `yaw == 0` must match
/// top-down's `(1,0,0)` to be internally consistent with this same file's
/// own stated convention.
@MainActor
final class CameraGroundDirectionTests: XCTestCase {
    private func makeRenderer() throws -> LevelViewerRenderer {
        try XCTUnwrap(LevelViewerRenderer(placements: []))
    }

    func testOrbitModeGroundRightAtZeroYawMatchesTopDownModesOwnHardcodedRight() throws {
        let renderer = try makeRenderer()
        renderer.yaw = 0
        XCTAssertFalse(renderer.isTopDownMode)
        let orbitRight = renderer.cameraGroundRight()
        let orbitForward = renderer.cameraGroundForward()

        renderer.isTopDownMode = true
        let topDownRight = renderer.cameraGroundRight()
        let topDownForward = renderer.cameraGroundForward()

        XCTAssertLessThan(simd_distance(orbitForward, topDownForward), 0.0001, "sanity check: orbit's own forward at yaw=0 must already match top-down's hardcoded forward for this test to mean anything")
        XCTAssertLessThan(simd_distance(orbitRight, topDownRight), 0.0001, "orbit mode's ground-right at yaw=0 must match top-down mode's own hardcoded (1,0,0), got \(orbitRight)")
    }

    /// `right` must always be perpendicular to `forward` (both flattened to
    /// the ground plane) at any yaw, not just the one pinned value above --
    /// this catches a fix that got the *magnitude* right but the rotation
    /// direction (which way `right` sweeps as `yaw` increases) still wrong.
    func testOrbitModeGroundRightStaysPerpendicularToForwardAcrossYaw() throws {
        let renderer = try makeRenderer()
        for yawDegrees: Float in stride(from: 0, to: 360, by: 30) {
            renderer.yaw = yawDegrees * .pi / 180
            let forward = renderer.cameraGroundForward()
            let right = renderer.cameraGroundRight()
            XCTAssertEqual(simd_dot(forward, right), 0, accuracy: 0.0001, "forward/right must stay perpendicular at yaw=\(yawDegrees)°")
            // Right-handed, Y-up: rotating `forward` by -90° about Y must
            // give `right`, the actual rotation-direction check `dot`
            // alone can't catch (dot==0 is also true for the wrong sign of
            // right, i.e. "left").
            let rotatedForwardMinus90 = SIMD3<Float>(
                forward.x * cos(-Float.pi / 2) + forward.z * sin(-Float.pi / 2),
                0,
                -forward.x * sin(-Float.pi / 2) + forward.z * cos(-Float.pi / 2)
            )
            XCTAssertLessThan(simd_distance(rotatedForwardMinus90, right), 0.001, "right must be forward rotated -90° about Y at yaw=\(yawDegrees)°, got right=\(right) vs expected=\(rotatedForwardMinus90)")
        }
    }
}
