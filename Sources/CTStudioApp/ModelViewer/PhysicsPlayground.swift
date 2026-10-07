import Foundation
import simd

/// "Local Physics & Collision Playground" (roadmap 12.1): a real, local
/// mini-simulation of a bouncing test sphere against a level's actual
/// decoded collision triangles, gravity integration, real sphere-vs-
/// triangle collision detection (closest-point-on-triangle, the standard
/// algorithm from computational geometry: Christer Ericson, "Real-Time
/// Collision Detection", section 5.1.5, a well-known, publicly
/// documented technique, not anything specific to the PS2 Emotion
/// Engine's own physics, which this codebase has no decoded/verified
/// model of), and a simple bounce/friction response.
///
/// Entirely local and offline, no PCSX2/game-runtime connection of any
/// kind, and no claim this matches the original game's actual physics
/// constants (gravity/restitution/friction here are exactly what the
/// roadmap calls for: custom, user-adjustable test values, "slippery
/// ice or bouncy crates", checked against real level geometry, not a
/// recreation of the shipped game's own tuning).
public struct PhysicsPlayground {
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public var radius: Float
    /// Downward acceleration in units/sec². Negative moves the sphere down
    /// (world convention already used throughout this app: +Y is up).
    public var gravity: Float
    /// 0 = fully inelastic (no bounce), 1 = perfectly elastic.
    public var restitution: Float
    /// 0 = frictionless (ice), 1 = the tangential velocity component is
    /// fully cancelled on every contact.
    public var friction: Float

    public init(position: SIMD3<Float>, radius: Float = 0.5, gravity: Float = -9.8, restitution: Float = 0.5, friction: Float = 0.3) {
        self.position = position
        self.velocity = .zero
        self.radius = radius
        self.gravity = gravity
        self.restitution = restitution
        self.friction = friction
    }

    /// Advances the simulation by `deltaTime` seconds: integrates gravity,
    /// moves the sphere, then resolves collision against every real
    /// triangle in `triangles` (each corner already in world space).
    /// Multiple overlapping triangles are each resolved in sequence within
    /// the same step, a standard, if approximate, way to handle
    /// corners/creases without a full contact-manifold solver.
    public mutating func step(deltaTime: Float, against triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]) {
        guard deltaTime > 0 else { return }
        velocity.y += gravity * deltaTime
        position += velocity * deltaTime

        for triangle in triangles {
            resolveCollision(against: triangle)
        }
    }

    private mutating func resolveCollision(against triangle: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) {
        let closest = Self.closestPointOnTriangle(point: position, a: triangle.0, b: triangle.1, c: triangle.2)
        let delta = position - closest
        let distance = simd_length(delta)
        guard distance < radius, distance > 1e-6 else { return }

        let normal = delta / distance
        position += normal * (radius - distance)

        let normalVelocity = simd_dot(velocity, normal)
        guard normalVelocity < 0 else { return } // already separating, nothing to resolve
        let normalComponent = normal * normalVelocity
        let tangentComponent = velocity - normalComponent
        velocity = tangentComponent * (1 - friction) - normalComponent * restitution
    }

    /// Standard closest-point-on-triangle: region-tests the point against
    /// each vertex/edge/face Voronoi region via barycentric coordinates.
    /// Real, well-known computational geometry, verified against known
    /// cases in `PhysicsPlaygroundTests`, not derived from any game-
    /// specific source.
    static func closestPointOnTriangle(point p: SIMD3<Float>, a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a
        let ac = c - a
        let ap = p - a

        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return a }

        let bp = p - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return b }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let v = d1 / (d1 - d3)
            return a + v * ab
        }

        let cp = p - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return c }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let w = d2 / (d2 - d6)
            return a + w * ac
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, (d4 - d3) >= 0, (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return b + w * (c - b)
        }

        let denom = 1 / (va + vb + vc)
        let v = vb * denom
        let w = vc * denom
        return a + ab * v + ac * w
    }
}
