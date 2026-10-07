import simd

/// A single rigid (non-skinned) vertex, laid out to drop straight into a Metal
/// vertex buffer (`MTLVertexDescriptor` with float3/float3/float2/uchar4/uchar4
/// attributes at the offsets below, no repacking needed at draw time).
public struct StaticVertex: Sendable, Equatable, Codable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var uv: SIMD2<Float>
    public var color: SIMD4<UInt8>      // RGBA, straight alpha (0...255)
    public var emissive: SIMD4<UInt8>   // RGBA, straight alpha (0...255)

    public init(
        position: SIMD3<Float>,
        normal: SIMD3<Float> = .zero,
        uv: SIMD2<Float> = .zero,
        color: SIMD4<UInt8> = SIMD4<UInt8>(255, 255, 255, 255),
        emissive: SIMD4<UInt8> = .zero
    ) {
        self.position = position
        self.normal = normal
        self.uv = uv
        self.color = color
        self.emissive = emissive
    }
}
