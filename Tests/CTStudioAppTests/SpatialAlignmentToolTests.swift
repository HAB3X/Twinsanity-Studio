import XCTest
import simd
@testable import CTStudioApp

/// "Align & Distribute", real math tested directly against dummy
/// coordinate arrays, independent of any renderer/SwiftUI state, same
/// reasoning as `DanglingReferenceCheckerTests`.
final class SpatialAlignmentToolTests: XCTestCase {
    private let p1 = SIMD3<Float>(1, 10, 100)
    private let p2 = SIMD3<Float>(5, 20, 200)
    private let p3 = SIMD3<Float>(9, 30, 300)

    // MARK: - Align

    func testAlignMinOnX() {
        let result = SpatialAlignmentTool.align([p1, p2, p3], axis: .x, mode: .min)
        XCTAssertEqual(result.map(\.x), [1, 1, 1])
        // Other axes untouched.
        XCTAssertEqual(result.map(\.y), [10, 20, 30])
        XCTAssertEqual(result.map(\.z), [100, 200, 300])
    }

    func testAlignMaxOnX() {
        let result = SpatialAlignmentTool.align([p1, p2, p3], axis: .x, mode: .max)
        XCTAssertEqual(result.map(\.x), [9, 9, 9])
    }

    func testAlignCenterOnX() {
        let result = SpatialAlignmentTool.align([p1, p2, p3], axis: .x, mode: .center)
        // (1 + 5 + 9) / 3 == 5
        XCTAssertEqual(result.map(\.x), [5, 5, 5])
    }

    func testAlignMinOnY() {
        let result = SpatialAlignmentTool.align([p1, p2, p3], axis: .y, mode: .min)
        XCTAssertEqual(result.map(\.y), [10, 10, 10])
        XCTAssertEqual(result.map(\.x), [1, 5, 9])
    }

    func testAlignMaxOnY() {
        let result = SpatialAlignmentTool.align([p1, p2, p3], axis: .y, mode: .max)
        XCTAssertEqual(result.map(\.y), [30, 30, 30])
    }

    func testAlignCenterOnY() {
        let result = SpatialAlignmentTool.align([p1, p2, p3], axis: .y, mode: .center)
        XCTAssertEqual(result.map(\.y), [20, 20, 20])
    }

    func testAlignMinOnZ() {
        let result = SpatialAlignmentTool.align([p1, p2, p3], axis: .z, mode: .min)
        XCTAssertEqual(result.map(\.z), [100, 100, 100])
    }

    func testAlignMaxOnZ() {
        let result = SpatialAlignmentTool.align([p1, p2, p3], axis: .z, mode: .max)
        XCTAssertEqual(result.map(\.z), [300, 300, 300])
    }

    func testAlignCenterOnZ() {
        let result = SpatialAlignmentTool.align([p1, p2, p3], axis: .z, mode: .center)
        XCTAssertEqual(result.map(\.z), [200, 200, 200])
    }

    func testAlignOnEmptyArrayReturnsEmpty() {
        XCTAssertEqual(SpatialAlignmentTool.align([], axis: .x, mode: .center), [])
    }

    func testAlignSingleItemSnapsToItsOwnValueForEveryMode() {
        let single = [p1]
        for mode in SpatialAlignmentTool.AlignMode.allCases {
            let result = SpatialAlignmentTool.align(single, axis: .x, mode: mode)
            XCTAssertEqual(result, [p1])
        }
    }

    // MARK: - Distribute

    func testDistributeTwoItemsSnapToTheirOwnMinAndMax() {
        // Already the extremes -- distributing 2 items just re-confirms min/max.
        let result = SpatialAlignmentTool.distribute([p1, p2], axis: .x)
        XCTAssertEqual(result[0].x, 1, accuracy: 0.0001)
        XCTAssertEqual(result[1].x, 5, accuracy: 0.0001)
    }

    func testDistributeTwoItemsOutOfOrderStillMapsSmallestToMinLargestToMax() {
        // p2.x (5) > p1.x (1), but passed in reverse order.
        let result = SpatialAlignmentTool.distribute([p2, p1], axis: .x)
        XCTAssertEqual(result[0].x, 5, accuracy: 0.0001) // p2 keeps the max
        XCTAssertEqual(result[1].x, 1, accuracy: 0.0001) // p1 keeps the min
    }

    func testDistributeThreeItemsEvenlySpacesTheMiddleOne() {
        let result = SpatialAlignmentTool.distribute([p1, p2, p3], axis: .x)
        // x values 1, 5, 9 are already evenly spaced and already sorted.
        XCTAssertEqual(result.map(\.x), [1, 5, 9])
    }

    func testDistributeThreeItemsOutOfOrderPreservesRankNotArrayPosition() {
        // Positions passed out of axis-order: middle, min, max.
        let middle = SIMD3<Float>(50, 0, 0)
        let low = SIMD3<Float>(0, 0, 0)
        let high = SIMD3<Float>(100, 0, 0)
        let result = SpatialAlignmentTool.distribute([middle, low, high], axis: .x)
        // Ranks by x: low(0) < middle(50) < high(100) -> new values 0, 50, 100
        // assigned back to each item's own array slot by its rank.
        XCTAssertEqual(result[0].x, 50, accuracy: 0.0001) // middle stays in the middle
        XCTAssertEqual(result[1].x, 0, accuracy: 0.0001)  // low keeps the min
        XCTAssertEqual(result[2].x, 100, accuracy: 0.0001) // high keeps the max
    }

    func testDistributeFiveItemsEvenSpacing() {
        let items = (0..<5).map { SIMD3<Float>(Float($0) * 10, 0, 0) } // 0, 10, 20, 30, 40 -- already even
        let result = SpatialAlignmentTool.distribute(items, axis: .x)
        XCTAssertEqual(result.map(\.x), [0, 10, 20, 30, 40])
    }

    func testDistributeFiveUnevenItemsSpreadsEvenlyByRank() {
        // Same 5 items, unevenly spaced (0, 1, 2, 3, 100) -- should redistribute
        // to 0, 25, 50, 75, 100 by rank, ignoring the original spacing.
        let items: [SIMD3<Float>] = [0, 1, 2, 3, 100].map { SIMD3<Float>(Float($0), 0, 0) }
        let result = SpatialAlignmentTool.distribute(items, axis: .x)
        XCTAssertEqual(result.map(\.x), [0, 25, 50, 75, 100])
    }

    func testDistributeSingleItemIsUnchanged() {
        let result = SpatialAlignmentTool.distribute([p2], axis: .y)
        XCTAssertEqual(result, [p2])
    }

    func testDistributeEmptyArrayReturnsEmpty() {
        XCTAssertEqual(SpatialAlignmentTool.distribute([], axis: .z), [])
    }

    /// All items already at the same position on the target axis -- must
    /// not divide by zero or produce NaN, and should leave every item at
    /// that shared value.
    func testDistributeAllItemsAtSamePositionDoesNotProduceNaN() {
        let same = Array(repeating: SIMD3<Float>(7, 7, 7), count: 4)
        let result = SpatialAlignmentTool.distribute(same, axis: .x)
        for value in result.map(\.x) {
            XCTAssertFalse(value.isNaN)
            XCTAssertEqual(value, 7, accuracy: 0.0001)
        }
    }

    func testAlignAllItemsAtSamePositionDoesNotProduceNaN() {
        let same = Array(repeating: SIMD3<Float>(3, 3, 3), count: 3)
        for mode in SpatialAlignmentTool.AlignMode.allCases {
            let result = SpatialAlignmentTool.align(same, axis: .y, mode: mode)
            for value in result.map(\.y) {
                XCTAssertFalse(value.isNaN)
                XCTAssertEqual(value, 3, accuracy: 0.0001)
            }
        }
    }

    /// Distributing preserves each item's non-target axes untouched.
    func testDistributePreservesOtherAxes() {
        let result = SpatialAlignmentTool.distribute([p1, p2, p3], axis: .x)
        XCTAssertEqual(result.map(\.y), [10, 20, 30])
        XCTAssertEqual(result.map(\.z), [100, 200, 300])
    }
}
