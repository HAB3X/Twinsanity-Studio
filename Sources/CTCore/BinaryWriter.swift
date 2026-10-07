import Foundation
import simd

/// A minimal append-only binary writer, mirroring the subset of `BinaryCursor`'s
/// primitives that the export/repackaging pipeline needs (BD/BH index rebuilding,
/// raw passthrough of unmodified chunk bytes).
public struct BinaryWriter {
    public private(set) var data = Data()
    public let endianness: Endianness

    public init(endianness: Endianness = .little) {
        self.endianness = endianness
    }

    public var count: Int { data.count }

    public mutating func writeBytes(_ bytes: Data) { data.append(bytes) }
    public mutating func writeBytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }

    private mutating func writeUnsigned<T: UnsignedInteger & FixedWidthInteger>(_ value: T) {
        let byteCount = T.bitWidth / 8
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var v = value
        switch endianness {
        case .little:
            for i in 0..<byteCount {
                bytes[i] = UInt8(truncatingIfNeeded: v)
                v >>= 8
            }
        case .big:
            for i in stride(from: byteCount - 1, through: 0, by: -1) {
                bytes[i] = UInt8(truncatingIfNeeded: v)
                v >>= 8
            }
        }
        data.append(contentsOf: bytes)
    }

    public mutating func writeUInt8(_ v: UInt8) { writeUnsigned(v) }
    public mutating func writeUInt16(_ v: UInt16) { writeUnsigned(v) }
    public mutating func writeUInt32(_ v: UInt32) { writeUnsigned(v) }
    public mutating func writeUInt64(_ v: UInt64) { writeUnsigned(v) }

    public mutating func writeInt8(_ v: Int8) { writeUnsigned(UInt8(bitPattern: v)) }
    public mutating func writeInt16(_ v: Int16) { writeUnsigned(UInt16(bitPattern: v)) }
    public mutating func writeInt32(_ v: Int32) { writeUnsigned(UInt32(bitPattern: v)) }
    public mutating func writeInt64(_ v: Int64) { writeUnsigned(UInt64(bitPattern: v)) }

    public mutating func writeFloat32(_ v: Float) { writeUnsigned(v.bitPattern) }
    public mutating func writeFloat64(_ v: Double) { writeUnsigned(v.bitPattern) }

    public mutating func writeASCIIString(_ s: String, appendNullTerminator: Bool = false) {
        data.append(contentsOf: Array(s.utf8))
        if appendNullTerminator { data.append(0) }
    }

    // MARK: - Vectors (mirrors `BinaryCursor.readVector4`/`readVector3`)

    public mutating func writeVector4(_ v: SIMD4<Float>) {
        writeFloat32(v.x); writeFloat32(v.y); writeFloat32(v.z); writeFloat32(v.w)
    }

    public mutating func writeVector3(_ v: SIMD3<Float>) {
        writeFloat32(v.x); writeFloat32(v.y); writeFloat32(v.z)
    }
}
