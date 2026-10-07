import Foundation
import Metal
import simd
import CTModels

/// "Procedural Collision Decimation" (roadmap 4.4), generates an oriented
/// bounding box (OBB) around an arbitrary mesh's real vertex positions, a
/// genuinely tighter "optimized" collision hull than a plain axis-aligned
/// box for anything not already axis-aligned. Unlike the AgentLab shell
/// (4.2) or the AI Pathfinding shell (5.1), this isn't blocked on any
/// undecoded game format, it operates purely on this build's own already-
/// resolved mesh vertex data, so it's a real, working algorithm rather than
/// a placeholder shell.
///
/// The mean/covariance reduction (the expensive, embarrassingly-parallel
/// part for a mesh with thousands of vertices) runs as two Metal compute
/// kernels with a standard grid-stride-plus-threadgroup-tree-reduction
/// pattern. The final 3x3 symmetric eigendecomposition (classical Jacobi
/// rotation) and the min/max axis projection run on the CPU, both O(1)
/// and O(n) respectively, neither expensive enough to justify their own
/// GPU round-trip.
public enum CollisionDecimator {
    public struct OrientedBoundingBox {
        public let center: SIMD3<Float>
        /// Orthonormal principal axes, largest-variance first.
        public let axes: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
        public let halfExtents: SIMD3<Float>

        /// The 8 real corners of this box, in the fixed order
        /// `ModelViewerRenderer.orientedBoxEdges` expects.
        public var corners: [SIMD3<Float>] {
            let signs: [SIMD3<Float>] = [
                SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
                SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)
            ]
            return signs.map { sign in
                center
                    + axes.0 * (sign.x * halfExtents.x)
                    + axes.1 * (sign.y * halfExtents.y)
                    + axes.2 * (sign.z * halfExtents.z)
            }
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void obb_reduce_mean(const device packed_float3* positions [[buffer(0)]],
                                 constant uint& vertexCount [[buffer(1)]],
                                 device packed_float3* partialSums [[buffer(2)]],
                                 uint tid [[thread_position_in_threadgroup]],
                                 uint tgSize [[threads_per_threadgroup]],
                                 uint tgid [[threadgroup_position_in_grid]],
                                 uint gid [[thread_position_in_grid]],
                                 uint gridSize [[threads_per_grid]]) {
        threadgroup float3 shared_sum[256];
        float3 sum = float3(0);
        for (uint i = gid; i < vertexCount; i += gridSize) {
            sum += float3(positions[i]);
        }
        shared_sum[tid] = sum;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = tgSize / 2; stride > 0; stride >>= 1) {
            if (tid < stride) {
                shared_sum[tid] += shared_sum[tid + stride];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (tid == 0) {
            partialSums[tgid] = packed_float3(shared_sum[0]);
        }
    }

    kernel void obb_reduce_covariance(const device packed_float3* positions [[buffer(0)]],
                                       constant uint& vertexCount [[buffer(1)]],
                                       constant packed_float3& mean [[buffer(2)]],
                                       device packed_float3* partialCovXXXYXZ [[buffer(3)]],
                                       device packed_float3* partialCovYYYZZZ [[buffer(4)]],
                                       uint tid [[thread_position_in_threadgroup]],
                                       uint tgSize [[threads_per_threadgroup]],
                                       uint tgid [[threadgroup_position_in_grid]],
                                       uint gid [[thread_position_in_grid]],
                                       uint gridSize [[threads_per_grid]]) {
        threadgroup float3 shared1[256];
        threadgroup float3 shared2[256];
        float3 sum1 = float3(0);
        float3 sum2 = float3(0);
        float3 m = float3(mean);
        for (uint i = gid; i < vertexCount; i += gridSize) {
            float3 d = float3(positions[i]) - m;
            sum1 += float3(d.x * d.x, d.x * d.y, d.x * d.z);
            sum2 += float3(d.y * d.y, d.y * d.z, d.z * d.z);
        }
        shared1[tid] = sum1;
        shared2[tid] = sum2;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = tgSize / 2; stride > 0; stride >>= 1) {
            if (tid < stride) {
                shared1[tid] += shared1[tid + stride];
                shared2[tid] += shared2[tid + stride];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (tid == 0) {
            partialCovXXXYXZ[tgid] = packed_float3(shared1[0]);
            partialCovYYYZZZ[tgid] = packed_float3(shared2[0]);
        }
    }
    """

    private static let threadgroupSize = 256

    /// Tightly-packed 3-float transfer type (12-byte stride, no padding) , 
    /// matches MSL's `packed_float3` exactly. Swift's own `SIMD3<Float>`
    /// has a 16-byte *stride* (padded for vector-register alignment, even
    /// though its *size* is 12), so uploading `[SIMD3<Float>]` directly as
    /// raw bytes to a `packed_float3*` buffer silently misaligns every
    /// element after the first, a real bug caught by
    /// `CollisionDecimatorTests` (a diagonal-covariance input came back
    /// with rotated, wrong axes) before this type existed.
    private struct PackedFloat3 {
        var x: Float
        var y: Float
        var z: Float
        init(_ v: SIMD3<Float>) { x = v.x; y = v.y; z = v.z }
        var simd: SIMD3<Float> { SIMD3(x, y, z) }
    }

    /// `nil` if the mesh has no vertices or the Metal pipeline can't be
    /// built (e.g. running where no GPU is available), never a fabricated
    /// zero-size box.
    public static func computeOrientedBoundingBox(mesh: MeshAsset, device: MTLDevice) -> OrientedBoundingBox? {
        let positions: [SIMD3<Float>] = mesh.submeshes.flatMap { $0.vertices.map(\.position) }
        guard !positions.isEmpty else { return nil }
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let meanFn = library.makeFunction(name: "obb_reduce_mean"),
              let covFn = library.makeFunction(name: "obb_reduce_covariance"),
              let meanPipeline = try? device.makeComputePipelineState(function: meanFn),
              let covPipeline = try? device.makeComputePipelineState(function: covFn),
              let queue = device.makeCommandQueue()
        else { return nil }

        let vertexCount = positions.count
        let packedPositions = positions.map(PackedFloat3.init)
        guard let positionBuffer = device.makeBuffer(bytes: packedPositions, length: vertexCount * MemoryLayout<PackedFloat3>.stride, options: .storageModeShared) else { return nil }
        var count = UInt32(vertexCount)
        let threadgroupCount = min(64, max(1, (vertexCount + threadgroupSize - 1) / threadgroupSize))

        guard let meanPartials = device.makeBuffer(length: threadgroupCount * MemoryLayout<PackedFloat3>.stride, options: .storageModeShared) else { return nil }
        guard let commandBuffer1 = queue.makeCommandBuffer(), let encoder1 = commandBuffer1.makeComputeCommandEncoder() else { return nil }
        encoder1.setComputePipelineState(meanPipeline)
        encoder1.setBuffer(positionBuffer, offset: 0, index: 0)
        encoder1.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder1.setBuffer(meanPartials, offset: 0, index: 2)
        encoder1.dispatchThreadgroups(MTLSize(width: threadgroupCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: threadgroupSize, height: 1, depth: 1))
        encoder1.endEncoding()
        commandBuffer1.commit()
        commandBuffer1.waitUntilCompleted()

        let meanPartialPointer = meanPartials.contents().bindMemory(to: PackedFloat3.self, capacity: threadgroupCount)
        var meanSum = SIMD3<Float>.zero
        for i in 0..<threadgroupCount { meanSum += meanPartialPointer[i].simd }
        let mean = meanSum / Float(vertexCount)

        guard let covPartials1 = device.makeBuffer(length: threadgroupCount * MemoryLayout<PackedFloat3>.stride, options: .storageModeShared),
              let covPartials2 = device.makeBuffer(length: threadgroupCount * MemoryLayout<PackedFloat3>.stride, options: .storageModeShared)
        else { return nil }
        var meanForKernel = PackedFloat3(mean)
        guard let commandBuffer2 = queue.makeCommandBuffer(), let encoder2 = commandBuffer2.makeComputeCommandEncoder() else { return nil }
        encoder2.setComputePipelineState(covPipeline)
        encoder2.setBuffer(positionBuffer, offset: 0, index: 0)
        encoder2.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder2.setBytes(&meanForKernel, length: MemoryLayout<PackedFloat3>.stride, index: 2)
        encoder2.setBuffer(covPartials1, offset: 0, index: 3)
        encoder2.setBuffer(covPartials2, offset: 0, index: 4)
        encoder2.dispatchThreadgroups(MTLSize(width: threadgroupCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: threadgroupSize, height: 1, depth: 1))
        encoder2.endEncoding()
        commandBuffer2.commit()
        commandBuffer2.waitUntilCompleted()

        let cov1Pointer = covPartials1.contents().bindMemory(to: PackedFloat3.self, capacity: threadgroupCount)
        let cov2Pointer = covPartials2.contents().bindMemory(to: PackedFloat3.self, capacity: threadgroupCount)
        var covSum1 = SIMD3<Float>.zero // xx, xy, xz
        var covSum2 = SIMD3<Float>.zero // yy, yz, zz
        for i in 0..<threadgroupCount {
            covSum1 += cov1Pointer[i].simd
            covSum2 += cov2Pointer[i].simd
        }
        let n = Float(vertexCount)
        let covariance = simd_float3x3(
            SIMD3(covSum1.x / n, covSum1.y / n, covSum1.z / n),
            SIMD3(covSum1.y / n, covSum2.x / n, covSum2.y / n),
            SIMD3(covSum1.z / n, covSum2.y / n, covSum2.z / n)
        )

        let axes = jacobiEigenvectors(of: covariance)

        var minProj = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxProj = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for position in positions {
            let d = position - mean
            let projection = SIMD3(simd_dot(d, axes.0), simd_dot(d, axes.1), simd_dot(d, axes.2))
            minProj = simd_min(minProj, projection)
            maxProj = simd_max(maxProj, projection)
        }
        let center = mean + axes.0 * ((minProj.x + maxProj.x) / 2) + axes.1 * ((minProj.y + maxProj.y) / 2) + axes.2 * ((minProj.z + maxProj.z) / 2)
        let halfExtents = (maxProj - minProj) / 2

        return OrientedBoundingBox(center: center, axes: axes, halfExtents: SIMD3(max(halfExtents.x, 0.001), max(halfExtents.y, 0.001), max(halfExtents.z, 0.001)))
    }

    /// Classical Jacobi eigenvalue algorithm for a symmetric 3x3 matrix , 
    /// standard, well-understood, converges in well under 50 sweeps for a
    /// matrix this small. Returns the 3 eigenvectors as columns, sorted by
    /// descending eigenvalue (largest-variance axis first) so `axes.0` is
    /// always the OBB's "long" axis.
    static func jacobiEigenvectors(of matrix: simd_float3x3) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        var a = matrix
        var v = matrix_identity_float3x3

        for _ in 0..<50 {
            var (p, q) = (0, 1)
            var maxOffDiag: Float = abs(a[1, 0])
            if abs(a[2, 0]) > maxOffDiag { maxOffDiag = abs(a[2, 0]); (p, q) = (0, 2) }
            if abs(a[2, 1]) > maxOffDiag { maxOffDiag = abs(a[2, 1]); (p, q) = (1, 2) }
            if maxOffDiag < 1e-9 { break }

            let app = a[p, p], aqq = a[q, q], apq = a[p, q]
            let theta = (aqq - app) / (2 * apq)
            let t = (theta >= 0 ? Float(1) : Float(-1)) / (abs(theta) + sqrt(theta * theta + 1))
            let c = 1 / sqrt(t * t + 1)
            let s = t * c

            // `simd_float3x3`'s `[column, row]` subscript is transposed
            // relative to conventional `A[row, col]` math notation, to set
            // conventional A[p,q]=s / A[q,p]=-s (the standard Jacobi
            // rotation form paired with the theta/t/s/c derivation above),
            // the simd calls are `[q, p]`/`[p, q]` respectively, not the
            // other way around. Verified by `CollisionDecimatorTests`
            // (a naive `[p, q] = s` here silently inflates every recovered
            // extent instead of throwing, this was caught by comparing
            // against a known rotated box, not by inspection).
            var rotation = matrix_identity_float3x3
            rotation[p, p] = c; rotation[q, q] = c
            rotation[q, p] = s; rotation[p, q] = -s

            a = rotation.transpose * a * rotation
            v = v * rotation
        }

        let eigenvalues = [a[0, 0], a[1, 1], a[2, 2]]
        let order = [0, 1, 2].sorted { eigenvalues[$0] > eigenvalues[$1] }
        let columns = [v.columns.0, v.columns.1, v.columns.2]
        return (
            simd_normalize(columns[order[0]]),
            simd_normalize(columns[order[1]]),
            simd_normalize(columns[order[2]])
        )
    }
}
