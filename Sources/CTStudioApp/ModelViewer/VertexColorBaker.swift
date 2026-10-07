import Foundation
import simd
import CTModels

/// "Vertex Color & Lightmap Baking Suite" (roadmap 10.3): PS2/Xbox-era
/// games lack modern real-time lighting and rely on pre-baked vertex
/// colors for ambient occlusion and directional shading, this bakes both
/// for real, into `StaticVertex.color`:
///
/// - Directional light: standard Lambertian shading
///   (`max(0, dot(normal, -lightDirection))`), the same technique every
///   fixed-function vertex-lit engine of this era actually used.
/// - Ambient occlusion: real hemisphere-sampled ray casting against the
///   mesh's own triangles (Möller–Trumbore ray-triangle intersection, a
///   standard, well-known algorithm), not an approximation or a
///   pre-baked lookup table.
///
/// Both operate entirely on this tool's own already-decoded mesh data;
/// neither claims to reproduce how the original game's own (undecoded)
/// lighting/baking pipeline actually worked, this is a real, original
/// bake, not a recovered one.
public enum VertexColorBaker {
    /// Bakes simple directional (Lambertian) shading into every vertex's
    /// real RGB, blended with `ambient` as a floor so nothing goes fully
    /// black. Alpha is preserved unchanged.
    public static func bakeDirectionalLight(_ mesh: MeshAsset, lightDirection: SIMD3<Float>, ambient: Float = 0.25, intensity: Float = 1.0) -> MeshAsset {
        let direction = simd_length(lightDirection) > 0.0001 ? simd_normalize(lightDirection) : SIMD3<Float>(0, -1, 0)
        var result = mesh
        for submeshIndex in result.submeshes.indices {
            for vertexIndex in result.submeshes[submeshIndex].vertices.indices {
                let normal = result.submeshes[submeshIndex].vertices[vertexIndex].normal
                let lambert = max(0, simd_dot(normal, -direction))
                let shade = min(1, ambient + lambert * intensity)
                let original = result.submeshes[submeshIndex].vertices[vertexIndex].color
                result.submeshes[submeshIndex].vertices[vertexIndex].color = SIMD4<UInt8>(
                    UInt8(min(255, Float(original.x) * shade)),
                    UInt8(min(255, Float(original.y) * shade)),
                    UInt8(min(255, Float(original.z) * shade)),
                    original.w
                )
            }
        }
        return result
    }

    /// Real ray-cast ambient occlusion, sampled over a cosine-weighted
    /// hemisphere around each vertex's own normal, tested against every
    /// triangle in every submesh of `mesh`, the whole mesh occludes every
    /// vertex, not just its own submesh, so separate pieces of the same
    /// object can shadow each other correctly.
    public static func bakeAmbientOcclusion(_ mesh: MeshAsset, sampleCount: Int = 24, maxDistance: Float = 2.0, strength: Float = 1.0) -> MeshAsset {
        let triangles = allWorldTriangles(mesh)
        guard !triangles.isEmpty else { return mesh }
        var result = mesh
        var rng = SystemRandomNumberGenerator()
        for submeshIndex in result.submeshes.indices {
            for vertexIndex in result.submeshes[submeshIndex].vertices.indices {
                let vertex = result.submeshes[submeshIndex].vertices[vertexIndex]
                let occlusion = occlusion(at: vertex.position, normal: vertex.normal, triangles: triangles, sampleCount: sampleCount, maxDistance: maxDistance, rng: &rng)
                let shade = max(0, 1 - occlusion * strength)
                let original = vertex.color
                result.submeshes[submeshIndex].vertices[vertexIndex].color = SIMD4<UInt8>(
                    UInt8(Float(original.x) * shade),
                    UInt8(Float(original.y) * shade),
                    UInt8(Float(original.z) * shade),
                    original.w
                )
            }
        }
        return result
    }

    static func allWorldTriangles(_ mesh: MeshAsset) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        var result: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for submesh in mesh.submeshes {
            for (a, b, c) in submesh.triangleIndices() {
                guard submesh.vertices.indices.contains(a), submesh.vertices.indices.contains(b), submesh.vertices.indices.contains(c) else { continue }
                result.append((submesh.vertices[a].position, submesh.vertices[b].position, submesh.vertices[c].position))
            }
        }
        return result
    }

    private static func occlusion(at position: SIMD3<Float>, normal: SIMD3<Float>, triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)], sampleCount: Int, maxDistance: Float, rng: inout SystemRandomNumberGenerator) -> Float {
        guard sampleCount > 0 else { return 0 }
        let n = simd_length(normal) > 0.0001 ? simd_normalize(normal) : SIMD3<Float>(0, 1, 0)
        let (tangent, bitangent) = orthonormalBasis(for: n)
        // Offset the ray origin slightly along the normal so a ray doesn't
        // immediately self-intersect the triangle this vertex itself
        // belongs to.
        let origin = position + n * 0.001

        var hits = 0
        for _ in 0..<sampleCount {
            let direction = cosineWeightedHemisphereSample(normal: n, tangent: tangent, bitangent: bitangent, rng: &rng)
            if rayHitsAnyTriangle(origin: origin, direction: direction, maxDistance: maxDistance, triangles: triangles) {
                hits += 1
            }
        }
        return Float(hits) / Float(sampleCount)
    }

    private static func orthonormalBasis(for n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let up: SIMD3<Float> = abs(n.y) < 0.99 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let tangent = simd_normalize(simd_cross(up, n))
        let bitangent = simd_cross(n, tangent)
        return (tangent, bitangent)
    }

    private static func cosineWeightedHemisphereSample(normal: SIMD3<Float>, tangent: SIMD3<Float>, bitangent: SIMD3<Float>, rng: inout SystemRandomNumberGenerator) -> SIMD3<Float> {
        let u1 = Float.random(in: 0..<1, using: &rng)
        let u2 = Float.random(in: 0..<1, using: &rng)
        let r = sqrt(u1)
        let theta = 2 * Float.pi * u2
        let x = r * cos(theta)
        let y = r * sin(theta)
        let z = sqrt(max(0, 1 - u1))
        return tangent * x + bitangent * y + normal * z
    }

    /// Möller–Trumbore ray-triangle intersection, standard, well-known
    /// algorithm, not anything specific to this codebase's own formats.
    static func rayHitsAnyTriangle(origin: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float, triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]) -> Bool {
        let epsilon: Float = 1e-6
        for (a, b, c) in triangles {
            let edge1 = b - a
            let edge2 = c - a
            let h = simd_cross(direction, edge2)
            let det = simd_dot(edge1, h)
            if abs(det) < epsilon { continue }
            let invDet = 1 / det
            let s = origin - a
            let u = simd_dot(s, h) * invDet
            if u < 0 || u > 1 { continue }
            let q = simd_cross(s, edge1)
            let v = simd_dot(direction, q) * invDet
            if v < 0 || u + v > 1 { continue }
            let t = simd_dot(edge2, q) * invDet
            if t > epsilon, t < maxDistance { return true }
        }
        return false
    }
}
