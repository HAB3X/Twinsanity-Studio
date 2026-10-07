import XCTest
import simd
@testable import CTStudioApp

final class PhysicsPlaygroundTests: XCTestCase {
    // MARK: - closestPointOnTriangle

    private let flatFloor: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = (
        SIMD3(-10, 0, -10), SIMD3(10, 0, -10), SIMD3(0, 0, 10)
    )

    func testClosestPointDirectlyAboveTriangleIsTheProjection() {
        let point = SIMD3<Float>(0, 5, 0)
        let closest = PhysicsPlayground.closestPointOnTriangle(point: point, a: flatFloor.0, b: flatFloor.1, c: flatFloor.2)
        XCTAssertEqual(closest.x, 0, accuracy: 0.01)
        XCTAssertEqual(closest.y, 0, accuracy: 0.01)
        XCTAssertEqual(closest.z, 0, accuracy: 0.01)
    }

    func testClosestPointBeyondAVertexIsThatVertex() {
        // Far past vertex `a` = (-10, 0, -10).
        let point = SIMD3<Float>(-100, 0, -100)
        let closest = PhysicsPlayground.closestPointOnTriangle(point: point, a: flatFloor.0, b: flatFloor.1, c: flatFloor.2)
        XCTAssertEqual(closest, flatFloor.0)
    }

    func testClosestPointOnASimpleRightTriangleEdge() {
        // Right triangle at the origin; point is off to the side of the
        // edge from (0,0,0) to (1,0,0), same Y/Z as that edge (no Z offset
        // pulling it toward the third vertex).
        let a = SIMD3<Float>(0, 0, 0)
        let b = SIMD3<Float>(1, 0, 0)
        let c = SIMD3<Float>(0, 0, 1)
        let point = SIMD3<Float>(0.5, 0, -1)
        let closest = PhysicsPlayground.closestPointOnTriangle(point: point, a: a, b: b, c: c)
        XCTAssertEqual(closest.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(closest.y, 0, accuracy: 0.01)
        XCTAssertEqual(closest.z, 0, accuracy: 0.01)
    }

    // MARK: - Simulation

    func testBallDroppedOntoFlatFloorSettlesAtRestingHeight() {
        var ball = PhysicsPlayground(position: SIMD3(0, 5, 0), radius: 0.5, gravity: -9.8, restitution: 0.3, friction: 0.5)
        for _ in 0..<2000 {
            ball.step(deltaTime: 1.0 / 60.0, against: [flatFloor])
        }
        // Low restitution + friction should have the ball settled at
        // (radius above the floor) with near-zero velocity, not still
        // falling or bouncing indefinitely.
        XCTAssertEqual(ball.position.y, 0.5, accuracy: 0.05)
        XCTAssertLessThan(simd_length(ball.velocity), 0.5)
    }

    func testHigherRestitutionBouncesHigherThanLowerRestitution() {
        func peakHeightAfterFirstBounce(restitution: Float) -> Float {
            var ball = PhysicsPlayground(position: SIMD3(0, 5, 0), radius: 0.5, gravity: -9.8, restitution: restitution, friction: 0)
            var hasBounced = false
            var peak: Float = 0
            for _ in 0..<600 {
                ball.step(deltaTime: 1.0 / 60.0, against: [flatFloor])
                if ball.position.y <= 0.51, ball.velocity.y > 0 { hasBounced = true }
                if hasBounced { peak = max(peak, ball.position.y) }
            }
            return peak
        }
        let lowBounce = peakHeightAfterFirstBounce(restitution: 0.2)
        let highBounce = peakHeightAfterFirstBounce(restitution: 0.9)
        XCTAssertGreaterThan(highBounce, lowBounce, "a higher restitution must produce a higher bounce than a lower one, all else equal")
    }

    func testCollisionOnlyResolvesWhenMovingIntoTheSurface() {
        // A ball already moving away from the floor, resting exactly at
        // the surface, must not have its velocity altered, otherwise a
        // ball that just bounced would get re-clamped on the very next
        // step before it has a chance to actually separate.
        var ball = PhysicsPlayground(position: SIMD3(0, 0.5, 0), radius: 0.5, gravity: 0, restitution: 0.5, friction: 0)
        ball.velocity = SIMD3(0, 3, 0)
        let velocityBefore = ball.velocity
        ball.step(deltaTime: 1.0 / 600.0, against: [flatFloor]) // tiny dt so position barely moves
        XCTAssertEqual(ball.velocity.y, velocityBefore.y, accuracy: 0.01)
    }

    func testZeroGravityAndNoObstaclesMovesInAStraightLine() {
        var ball = PhysicsPlayground(position: .zero, radius: 0.5, gravity: 0, restitution: 1, friction: 0)
        ball.velocity = SIMD3(1, 0, 0)
        for _ in 0..<60 {
            ball.step(deltaTime: 1.0 / 60.0, against: [])
        }
        XCTAssertEqual(ball.position.x, 1.0, accuracy: 0.01)
        XCTAssertEqual(ball.position.y, 0, accuracy: 0.0001)
        XCTAssertEqual(ball.position.z, 0, accuracy: 0.0001)
    }
}
