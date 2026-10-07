import XCTest
@testable import CTStudioApp

/// "Radial Marking Menu (hold Q)": `LevelViewerWindow.markingMenuSliceIndex`
/// converts a cursor point (AppKit y-up view space) into a slice index,
/// clockwise from straight up -- the same convention `markingMenuOverlay`'s
/// drawing loop uses to position each slice on screen. A mismatch between
/// the two (e.g. one going clockwise, the other counter-clockwise) would
/// make the highlighted slice visually disagree with where the cursor
/// actually is -- exactly the class of sign/direction bug this session hit
/// repeatedly with scenery rotation, so this gets a real test rather than
/// trusting the derivation by eye.
final class MarkingMenuSliceIndexTests: XCTestCase {
    private let center = CGPoint(x: 100, y: 100)

    func testPointsDirectlyAboveCenterSelectSliceZero() {
        // AppKit is y-up, so "above" the center is a larger Y value.
        let above = CGPoint(x: 100, y: 150)
        XCTAssertEqual(LevelViewerWindow.markingMenuSliceIndex(center: center, current: above, sliceCount: 4), 0)
    }

    func testGoingClockwiseFromUpVisitsSlicesInOrderForFourSlices() {
        // 4 slices, 90° each, centered at up/right/down/left in that
        // clockwise order -- matches markingMenuOverlay's own
        // `angle = -pi/2 + index * sliceAngle` layout exactly.
        let up = CGPoint(x: 100, y: 150)      // AppKit +y = up
        let right = CGPoint(x: 150, y: 100)
        let down = CGPoint(x: 100, y: 50)     // AppKit -y = down
        let left = CGPoint(x: 50, y: 100)

        XCTAssertEqual(LevelViewerWindow.markingMenuSliceIndex(center: center, current: up, sliceCount: 4), 0)
        XCTAssertEqual(LevelViewerWindow.markingMenuSliceIndex(center: center, current: right, sliceCount: 4), 1)
        XCTAssertEqual(LevelViewerWindow.markingMenuSliceIndex(center: center, current: down, sliceCount: 4), 2)
        XCTAssertEqual(LevelViewerWindow.markingMenuSliceIndex(center: center, current: left, sliceCount: 4), 3)
    }

    func testWithinDeadZoneReturnsNil() {
        let barelyMoved = CGPoint(x: 105, y: 102)
        XCTAssertNil(LevelViewerWindow.markingMenuSliceIndex(center: center, current: barelyMoved, sliceCount: 4))
    }

    func testExactlyAtCenterReturnsNil() {
        XCTAssertNil(LevelViewerWindow.markingMenuSliceIndex(center: center, current: center, sliceCount: 4))
    }

    func testJustOutsideTheDeadZoneReturnsANonNilSlice() {
        let justOutside = CGPoint(x: 100, y: 100 + 14.5)
        XCTAssertNotNil(LevelViewerWindow.markingMenuSliceIndex(center: center, current: justOutside, sliceCount: 4, deadZoneRadius: 14))
    }

    /// A point just past the boundary between two adjacent slices should
    /// land in the *next* one, not the previous -- catches an off-by-one
    /// in the slice-boundary shift.
    func testAPointJustPastASliceBoundaryLandsInTheNextSlice() {
        // With 4 slices, the boundary between slice 0 (up) and slice 1
        // (right) is at 45° clockwise from up. A point just past that
        // (50°) should read as slice 1, not slice 0.
        let angleFromUpDegrees = 50.0
        let radians = angleFromUpDegrees * .pi / 180
        // Clockwise from up in AppKit y-up space: x = sin, y = cos (both scaled by radius).
        let point = CGPoint(x: center.x + 100 * sin(radians), y: center.y + 100 * cos(radians))
        XCTAssertEqual(LevelViewerWindow.markingMenuSliceIndex(center: center, current: point, sliceCount: 4), 1)
    }

    func testWorksForNonFourSliceCounts() {
        // 3 slices: up, 120° clockwise, 240° clockwise.
        let up = CGPoint(x: 100, y: 200)
        XCTAssertEqual(LevelViewerWindow.markingMenuSliceIndex(center: center, current: up, sliceCount: 3), 0)
    }
}
