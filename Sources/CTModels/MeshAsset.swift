import Foundation
import simd

/// One decoded `SubModel`/rigid-skin submesh: a triangle strip of vertices plus
/// a per-vertex connectivity flag (`Conn`) that says whether this vertex extends
/// the strip from its two predecessors or starts a fresh strip.
public struct MeshSubmesh: Sendable, Codable {
    public var vertices: [StaticVertex]
    /// `connectivity[i] == true` means vertex `i` extends the strip from its
    /// two predecessors, i.e. vertices `(i-2, i-1, i)` form a real triangle;
    /// `false` means vertex `i` restarts the strip instead. See
    /// `triangleIndices()` for how this is read (the flag on the *apex*
    /// vertex, not the first vertex, of each candidate triangle).
    public var connectivity: [Bool]
    public var materialID: UInt32?
    /// Per-vertex joint influences, populated only for `Skin` submeshes
    /// (parallel to `vertices`; empty for rigid `Model` submeshes). Up to 3
    /// active joints per vertex, padded to 4 lanes for a clean GPU attribute.
    public var jointIndices: [SIMD4<UInt16>]
    public var jointWeights: [SIMD4<Float>]

    public init(
        vertices: [StaticVertex],
        connectivity: [Bool],
        materialID: UInt32? = nil,
        jointIndices: [SIMD4<UInt16>] = [],
        jointWeights: [SIMD4<Float>] = []
    ) {
        self.vertices = vertices
        self.connectivity = connectivity
        self.materialID = materialID
        self.jointIndices = jointIndices
        self.jointWeights = jointWeights
    }

    public var isSkinned: Bool { !jointWeights.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case positions, normals, uvs, colors, emissives, connectivity, materialID, jointIndices, jointWeights
    }

    /// Custom `Codable`, same reasoning as `TextureAsset`'s: the synthesized
    /// conformance encodes `[StaticVertex]` as an unkeyed container of N
    /// per-vertex keyed containers (each itself wrapping 5 SIMD sub-
    /// containers), real, measured overhead at the scale a full archive
    /// scan's `ScanCache` write hits (tens of thousands of models, some
    /// with thousands of vertices each). Flattening each field into one
    /// contiguous `Data` per submesh and reconstructing `StaticVertex`
    /// values on decode is the same fix shape, just applied to per-vertex
    /// struct fields instead of a texture's raw byte buffer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let positions = try container.decode(Data.self, forKey: .positions).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let normals = try container.decode(Data.self, forKey: .normals).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let uvs = try container.decode(Data.self, forKey: .uvs).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let colors = [UInt8](try container.decode(Data.self, forKey: .colors))
        let emissives = [UInt8](try container.decode(Data.self, forKey: .emissives))

        let vertexCount = positions.count / 3
        var decodedVertices: [StaticVertex] = []
        decodedVertices.reserveCapacity(vertexCount)
        for i in 0..<vertexCount {
            decodedVertices.append(StaticVertex(
                position: SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]),
                normal: SIMD3(normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2]),
                uv: SIMD2(uvs[i * 2], uvs[i * 2 + 1]),
                color: SIMD4(colors[i * 4], colors[i * 4 + 1], colors[i * 4 + 2], colors[i * 4 + 3]),
                emissive: SIMD4(emissives[i * 4], emissives[i * 4 + 1], emissives[i * 4 + 2], emissives[i * 4 + 3])
            ))
        }
        vertices = decodedVertices
        connectivity = [UInt8](try container.decode(Data.self, forKey: .connectivity)).map { $0 != 0 }
        materialID = try container.decodeIfPresent(UInt32.self, forKey: .materialID)

        // Same flattened-`Data` fix as `vertices` above, missed the first
        // time through: the naive synthesized `Codable` for `[SIMD4<UInt16>]`/
        // `[SIMD4<Float>]` wraps every single element in its own container,
        // and at full-archive-scan scale (every skinned model's joint
        // influences) that's what actually bloated a real `ScanCache` write
        // to 2.3GB and made loading it back hang for minutes, not a
        // hypothetical, a real reproduction against the full disc image.
        let jointIndexRaw = try container.decode(Data.self, forKey: .jointIndices).withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        var decodedJointIndices: [SIMD4<UInt16>] = []
        decodedJointIndices.reserveCapacity(jointIndexRaw.count / 4)
        for i in 0..<(jointIndexRaw.count / 4) {
            decodedJointIndices.append(SIMD4(jointIndexRaw[i * 4], jointIndexRaw[i * 4 + 1], jointIndexRaw[i * 4 + 2], jointIndexRaw[i * 4 + 3]))
        }
        jointIndices = decodedJointIndices

        let jointWeightRaw = try container.decode(Data.self, forKey: .jointWeights).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var decodedJointWeights: [SIMD4<Float>] = []
        decodedJointWeights.reserveCapacity(jointWeightRaw.count / 4)
        for i in 0..<(jointWeightRaw.count / 4) {
            decodedJointWeights.append(SIMD4(jointWeightRaw[i * 4], jointWeightRaw[i * 4 + 1], jointWeightRaw[i * 4 + 2], jointWeightRaw[i * 4 + 3]))
        }
        jointWeights = decodedJointWeights
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var positions: [Float] = []
        var normals: [Float] = []
        var uvs: [Float] = []
        var colors: [UInt8] = []
        var emissives: [UInt8] = []
        positions.reserveCapacity(vertices.count * 3)
        normals.reserveCapacity(vertices.count * 3)
        uvs.reserveCapacity(vertices.count * 2)
        colors.reserveCapacity(vertices.count * 4)
        emissives.reserveCapacity(vertices.count * 4)
        for v in vertices {
            positions.append(contentsOf: [v.position.x, v.position.y, v.position.z])
            normals.append(contentsOf: [v.normal.x, v.normal.y, v.normal.z])
            uvs.append(contentsOf: [v.uv.x, v.uv.y])
            colors.append(contentsOf: [v.color.x, v.color.y, v.color.z, v.color.w])
            emissives.append(contentsOf: [v.emissive.x, v.emissive.y, v.emissive.z, v.emissive.w])
        }
        try container.encode(positions.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .positions)
        try container.encode(normals.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .normals)
        try container.encode(uvs.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .uvs)
        try container.encode(Data(colors), forKey: .colors)
        try container.encode(Data(emissives), forKey: .emissives)
        try container.encode(Data(connectivity.map { $0 ? UInt8(1) : UInt8(0) }), forKey: .connectivity)
        try container.encodeIfPresent(materialID, forKey: .materialID)

        var jointIndexFlat: [UInt16] = []
        jointIndexFlat.reserveCapacity(jointIndices.count * 4)
        for j in jointIndices { jointIndexFlat.append(contentsOf: [j.x, j.y, j.z, j.w]) }
        try container.encode(jointIndexFlat.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .jointIndices)

        var jointWeightFlat: [Float] = []
        jointWeightFlat.reserveCapacity(jointWeights.count * 4)
        for w in jointWeights { jointWeightFlat.append(contentsOf: [w.x, w.y, w.z, w.w]) }
        try container.encode(jointWeightFlat.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .jointWeights)
    }

    /// Triangle index list (into `vertices`), ready for an `MTLBuffer` index
    /// buffer or an OBJ `f` line. Winding-order swap ported from
    /// `Model.ToPLY`'s face-writing loop (`Twinsanity/Items/Graphics/
    /// Model.cs:339-345`): the strip alternates winding, so only the first
    /// two indices swap on odd `i`, and `i+2` is always the newest/apex vertex.
    ///
    /// Which vertex's `Conn` flag gates triangle `(i, i+1, i+2)` is where
    /// `ToPLY` disagrees with itself: its face-*counting* loop three lines
    /// above the one this was ported from tests `Vertexes[f+2].Conn`
    /// (`Model.cs:303`), not `Vertexes[f].Conn`, i.e. the header's face
    /// count and the actual emitted faces are computed from two different
    /// index conventions in the reference tool itself. `i+2` is also the
    /// only one of the two that makes sense as a strip-restart flag: a
    /// restart flag naturally belongs to the vertex that would need two
    /// predecessors to complete a triangle (the newest one), not to a
    /// vertex that's about to *start* a fresh strip. Using `connectivity[i]`
    /// here (as this used to) shows up as stray triangles bridging across
    /// every strip restart, vertices from unrelated parts of the mesh
    /// stitched together, which is exactly the crisscrossed/torn look a
    /// wrong texture would show even though the UVs themselves decode
    /// correctly.
    public func triangleIndices() -> [(Int, Int, Int)] {
        guard vertices.count >= 3 else { return [] }
        var triangles: [(Int, Int, Int)] = []
        triangles.reserveCapacity(vertices.count)
        for i in 0..<(vertices.count - 2) {
            let apex = i + 2
            guard apex < connectivity.count, connectivity[apex] else { continue }
            let odd = (i & 1) == 1
            let a = odd ? i + 1 : i
            let b = odd ? i : i + 1
            triangles.append((a, b, apex))
        }
        return triangles
    }

    /// Same count `triangleIndices().count` would produce, without
    /// allocating the actual `[(Int, Int, Int)]` array, for callers (stat
    /// labels, diff summaries) that only ever want the number. Those labels
    /// live in SwiftUI view bodies that re-evaluate on every unrelated
    /// state change (e.g. once per animation-playback frame, 30/sec), so
    /// building and immediately discarding a full triangle-tuple array
    /// purely to read `.count` was real, avoidable per-frame allocation.
    public var triangleCount: Int {
        guard vertices.count >= 3 else { return 0 }
        var count = 0
        for i in 0..<(vertices.count - 2) where i + 2 < connectivity.count && connectivity[i + 2] {
            count += 1
        }
        return count
    }
}

/// A fully decoded `Model` (rigid) or `Skin` (skinned) geometry record.
public struct MeshAsset: Sendable, Identifiable, Codable {
    public let id: UInt32
    public var isSkinned: Bool
    public var submeshes: [MeshSubmesh]

    public init(id: UInt32, isSkinned: Bool, submeshes: [MeshSubmesh]) {
        self.id = id
        self.isSkinned = isSkinned
        self.submeshes = submeshes
    }

    public var totalVertexCount: Int { submeshes.reduce(0) { $0 + $1.vertices.count } }
    public var totalTriangleCount: Int { submeshes.reduce(0) { $0 + $1.triangleCount } }
}

/// Decoded `RigidModel` record: links a set of materials and a `Mesh`/`Model`
/// record together (`Twinsanity/Items/Graphics/RigidModel.cs`).
public struct RigidModelInfo: Sendable {
    public let id: UInt32
    public var header: UInt32
    public var materialIDs: [UInt32]
    public var meshID: UInt32

    public init(id: UInt32, header: UInt32, materialIDs: [UInt32], meshID: UInt32) {
        self.id = id
        self.header = header
        self.materialIDs = materialIDs
        self.meshID = meshID
    }
}
