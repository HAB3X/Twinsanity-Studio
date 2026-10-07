import Foundation
import simd
import CTCore
import CTModels

/// Decodes a `Skin` record (`SectionType.skin`, skinned/weighted geometry) , 
/// ported from `Twinsanity/Items/Graphics/Skin.cs`.
///
/// Unlike rigid `Model` geometry, skin vertex batches hide extra data inside
/// the raw bit pattern of otherwise-float VU lanes: position/UV lanes are
/// signed-int32-reinterpreted-then-scaled (a fixed-point-ish encoding driven
/// by a per-submodel scale vector), and the weight lane packs a joint index
/// (top byte, pre-multiplied by 4 for PS2 VU address granularity) alongside a
/// float bone weight in the same 32 bits, see the inline comments below for
/// exactly which reinterpretation applies where; getting int-vs-float-vs-bits
/// backwards here silently produces a plausible-looking but wrong mesh, so
/// this mirrors `Skin.CalculateData` line for line rather than "simplifying".
public enum SkinParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> MeshAsset {
        let subModelCount = try cursor.readUInt32()
        var submeshes: [MeshSubmesh] = []
        submeshes.reserveCapacity(cursor.safeReserveCount(subModelCount, elementSize: 12)) // materialID + codeSize + vertex amount, minimum

        for _ in 0..<subModelCount {
            let materialID = try cursor.readUInt32()
            let codeSize = Int(try cursor.readInt32())
            _ = try cursor.readInt32() // declared vertex amount; decoded count is authoritative
            let vifCode = try cursor.readBytes(codeSize)

            let interpreter = try VIFInterpreter.interpretCode(vifCode)
            let vertices = decodeVertices(interpreter.getMem())

            // One pass building all four parallel output arrays instead of
            // four separate `.map`s over the same `vertices` array, same
            // per-element transforms, same order, just one traversal instead
            // of four (each of which was allocating its own full-size result
            // array) per submodel.
            var meshVertices: [StaticVertex] = []
            var connectivity: [Bool] = []
            var jointIndices: [SIMD4<UInt16>] = []
            var jointWeights: [SIMD4<Float>] = []
            meshVertices.reserveCapacity(vertices.count)
            connectivity.reserveCapacity(vertices.count)
            jointIndices.reserveCapacity(vertices.count)
            jointWeights.reserveCapacity(vertices.count)
            for v in vertices {
                meshVertices.append(v.vertex)
                connectivity.append(v.conn)
                jointIndices.append(SIMD4(UInt16(clamping: v.jointIndices.x), UInt16(clamping: v.jointIndices.y), UInt16(clamping: v.jointIndices.z), 0))
                jointWeights.append(SIMD4(v.jointWeights.x, v.jointWeights.y, v.jointWeights.z, 0))
            }

            var submesh = MeshSubmesh(
                vertices: meshVertices,
                connectivity: connectivity,
                materialID: materialID,
                jointIndices: jointIndices,
                jointWeights: jointWeights
            )
            applyGeometricNormals(to: &submesh)
            submeshes.append(submesh)
        }

        return MeshAsset(id: recordID, isSkinned: true, submeshes: submeshes)
    }

    /// `Skin`'s own VIF vertex stream has no per-vertex normal batch at all
    /// (only position/UV/color/weights, see this file's own top doc
    /// comment and `decodeVertices` below, which mirrors `Skin.
    /// CalculateData` line for line), unlike rigid `Model` records which
    /// sometimes carry real ones (`ModelParser`'s `fieldsPresent.contains(.
    /// normals)`). Leaving every skin vertex's normal at `.zero` (as this
    /// used to) makes `ModelViewerRenderer`'s lighting fall back to
    /// ambient-only for every skinned character, geometrically correct
    /// but visually flat, with no shading gradient to read facial
    /// contours, folds, or any 3D shape by. This derives real smooth
    /// per-vertex normals from the decoded bind-pose geometry itself
    /// (standard unnormalized-face-normal accumulation, so larger
    /// triangles weigh in proportionally more), purely for display, never
    /// serialized back to the PS2 format (no `SkinWriter` round-trips
    /// `.normal`; skin bytes are always copied verbatim elsewhere in this
    /// codebase), so it can't desync a rebuilt file from its source.
    ///
    /// Winding convention calibrated against a real rigid `Model` that
    /// does carry decoded normals (Cortex's own modelLink face piece,
    /// `l10chasb.rm2` joint 12): `cross(pb - pa, pc - pa)` for each
    /// `(a, b, c)` from `triangleIndices()` agreed with all 28 of that
    /// mesh's real per-vertex normals (0 disagreements).
    private static func applyGeometricNormals(to submesh: inout MeshSubmesh) {
        var accumulated = [SIMD3<Float>](repeating: .zero, count: submesh.vertices.count)
        for (a, b, c) in submesh.triangleIndices() {
            let pa = submesh.vertices[a].position
            let pb = submesh.vertices[b].position
            let pc = submesh.vertices[c].position
            let faceNormal = simd_cross(pb - pa, pc - pa)
            accumulated[a] += faceNormal
            accumulated[b] += faceNormal
            accumulated[c] += faceNormal
        }
        for i in accumulated.indices where simd_length_squared(accumulated[i]) > 0 {
            submesh.vertices[i].normal = simd_normalize(accumulated[i])
        }
    }

    private struct DecodedVertex {
        var vertex: StaticVertex
        var conn: Bool
        var jointIndices: SIMD3<Int>
        var jointWeights: SIMD3<Float>
    }

    private static func decodeVertices(_ data: [[VIFVector4?]]) -> [DecodedVertex] {
        var results: [DecodedVertex] = []
        let vertDataIndex = 3
        var i = 0

        while i < data.count {
            guard let header = data[i].first ?? nil else { break }
            let verts = Int(header.binaryX & 0xFF)
            guard verts > 0, i + 1 < data.count, let fieldsHeader = data[i + 1].first ?? nil else { break }
            let totalComponents = Int(fieldsHeader.binaryX & 0xFF)
            let fields = totalComponents / verts
            guard i + 2 < data.count, let scale = data[i + 2].first ?? nil else { break }

            let batch1Index = i + vertDataIndex       // positions
            let batch2Index = i + vertDataIndex + 1   // UVs
            let batch4Index = i + vertDataIndex + 2   // colors
            let batch3Index = i + vertDataIndex + 3   // weights/joint indices
            guard batch3Index < data.count else { break }

            var positions: [VIFVector4] = []
            var uvs: [VIFVector4] = []
            for j in 0..<verts {
                guard j < data[batch1Index].count, let raw1 = data[batch1Index][j],
                      j < data[batch2Index].count, let raw2 = data[batch2Index][j] else { break }

                // Position/UV lanes are stored as signed-int32 bit patterns
                // (not floats), later scaled into real units.
                var v1 = VIFVector4()
                v1.x = Float(Int32(bitPattern: raw1.binaryX))
                v1.y = Float(Int32(bitPattern: raw1.binaryY))
                v1.z = Float(Int32(bitPattern: raw1.binaryZ))
                v1.w = Float(Int32(bitPattern: raw1.binaryW))
                var v2 = VIFVector4()
                v2.x = Float(Int32(bitPattern: raw2.binaryX))
                v2.y = Float(Int32(bitPattern: raw2.binaryY))
                v2.z = Float(Int32(bitPattern: raw2.binaryZ))
                v2.w = Float(Int32(bitPattern: raw2.binaryW))
                v1 = v1.multiplied(by: scale.x)
                v2 = v2.multiplied(by: scale.y)
                positions.append(v1)
                uvs.append(v2)
            }

            var connections: [Bool] = []
            var jointIdx: [SIMD3<Int>] = []
            var jointWeight: [SIMD3<Float>] = []
            for j in 0..<verts {
                guard j < data[batch3Index].count, var v1 = data[batch3Index][j] else { break }
                let connValue = v1.binaryW & 0xFF00
                connections.append((connValue >> 8) != 128)

                let weightAmount = v1.binaryW & 0xFF
                var weight1: Float = 0, weight2: Float = 0, weight3: Float = 0
                var jointIndex1 = 0, jointIndex2 = 0, jointIndex3 = 0

                if weightAmount > 0 {
                    jointIndex1 = Int((v1.binaryX & 0xFF) / 4)
                    v1.binaryX = v1.binaryX & 0xFFFF_FF00
                    weight1 = v1.x
                }
                if weightAmount > 1 {
                    jointIndex2 = Int((v1.binaryY & 0xFF) / 4)
                    v1.binaryY = v1.binaryY & 0xFFFF_FF00
                    weight2 = v1.y
                }
                if weightAmount > 2 {
                    jointIndex3 = Int((v1.binaryZ & 0xFF) / 4)
                    v1.binaryZ = v1.binaryZ & 0xFFFF_FF00
                    weight3 = v1.z
                }
                jointIdx.append(SIMD3(jointIndex1, jointIndex2, jointIndex3))
                jointWeight.append(SIMD3(weight1, weight2, weight3))
            }

            for j in 0..<verts {
                guard j < positions.count, j < uvs.count, j < connections.count,
                      j < jointIdx.count, j < jointWeight.count,
                      batch4Index < data.count, j < data[batch4Index].count,
                      let colorRaw = data[batch4Index][j] else { break }

                let r = UInt8(clamping: Int(colorRaw.binaryX & 0xFF) + 127)
                let g = UInt8(clamping: Int(colorRaw.binaryY & 0xFF) + 127)
                let b = UInt8(clamping: Int(colorRaw.binaryZ & 0xFF) + 127)
                let a = UInt8(clamping: Int(colorRaw.binaryW & 0xFF) + 127)

                // "Mesh-local X mirror": same fix as `ModelParser` -- ported
                // from `SkinController.LoadMeshData` (`new Vector3(-model.
                // Vertexes[j].X, ...)`), a separate mirror from the
                // placement-level one this codebase already applies.
                let vertex = StaticVertex(
                    position: SIMD3(-positions[j].x, positions[j].y, positions[j].z),
                    normal: .zero,
                    uv: SIMD2(uvs[j].x, uvs[j].y),
                    color: SIMD4(r, g, b, a)
                )
                results.append(DecodedVertex(vertex: vertex, conn: connections[j], jointIndices: jointIdx[j], jointWeights: jointWeight[j]))
            }

            i += fields + 3
        }

        return results
    }
}
