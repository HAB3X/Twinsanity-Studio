import Foundation

/// A raw 128-bit VU register: 4 binary (bit-reinterpreted) float lanes.
/// Ported from `Twinsanity/VIF/Vector4.cs`. Kept distinct from `SIMD4<Float>`
/// because VIF unpack routinely writes *integer* bit patterns into a lane
/// (joint index / packed weight / raw byte) that only becomes a meaningful
/// float after later `Multiply`/masking steps, exactly mirroring the C#
/// `SetBinaryX`/`GetBinaryX` bit-reinterpretation helpers keeps that two-phase
/// decode (used heavily by `Skin`) unambiguous.
public struct VIFVector4: Equatable {
    public var x: Float = 0
    public var y: Float = 0
    public var z: Float = 0
    public var w: Float = 0

    public init() {}
    public init(_ x: Float, _ y: Float, _ z: Float, _ w: Float) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }
    public init(copy other: VIFVector4) {
        self = other
    }

    public var binaryX: UInt32 {
        get { x.bitPattern }
        set { x = Float(bitPattern: newValue) }
    }
    public var binaryY: UInt32 {
        get { y.bitPattern }
        set { y = Float(bitPattern: newValue) }
    }
    public var binaryZ: UInt32 {
        get { z.bitPattern }
        set { z = Float(bitPattern: newValue) }
    }
    public var binaryW: UInt32 {
        get { w.bitPattern }
        set { w = Float(bitPattern: newValue) }
    }

    public func multiplied(by value: Float) -> VIFVector4 {
        VIFVector4(x * value, y * value, z * value, w * value)
    }
}

/// VIF unpack source format (`Twinsanity.VIF.PackFormat`). The low nibble packs
/// `vl` (component width) in bits [0:1] and `vn` (dimension - 1) in bits [2:3].
public enum VIFPackFormat: UInt8 {
    case s32 = 0b0000
    case s16 = 0b0001
    case s8 = 0b0010
    case v2_32 = 0b0100
    case v2_16 = 0b0101
    case v2_8 = 0b0110
    case v3_32 = 0b1000
    case v3_16 = 0b1001
    case v3_8 = 0b1010
    case v4_32 = 0b1100
    case v4_16 = 0b1101
    case v4_8 = 0b1110
    case v4_5 = 0b1111
}

/// Non-unpack VIFcode opcodes actually branched on by the interpreter
/// (`Twinsanity.VIF.VIFCodeEnum`).
public enum VIFOpcode: UInt8 {
    case nop = 0b0000000
    case stcycl = 0b0000001
    case offset = 0b0000010
    case base = 0b0000011
    case itop = 0b0000100
    case stmod = 0b0000101
    case mskpath3 = 0b0000110
    case mark = 0b0000111
    case flushe = 0b0010000
    case flush = 0b0010001
    case flusha = 0b0010011
    case mscal = 0b0010100
    case mscnt = 0b0010111
    case mscalf = 0b0010101
    case stmask = 0b0100000
    case strow = 0b0110000
    case stcol = 0b0110001
    case mpg = 0b1001010
    case direct = 0b1010000
    case directhl = 0b1010001
    // Not a discrete opcode value: unpack is the whole 0x60...0x7F range,
    // tested with `op & 0x60 == 0x60` (see `VIFCode.isUnpack`).
    case unpackMarker = 0b1100000
}

/// A single 32-bit VIFcode word: `[8-bit CMD | 8-bit Amount | 16-bit Immediate]`.
public struct VIFCode {
    public var interrupt: Bool
    public var op: UInt8       // full 7-bit opcode; for UNPACK this also encodes vn/vl/m
    public var amount: UInt8
    public var immediate: UInt16

    public init(word: UInt32) {
        let cmd = UInt8((word & 0xFF00_0000) >> 24)
        amount = UInt8((word & 0x00FF_0000) >> 16)
        immediate = UInt16((word & 0x0000_FFFF) >> 0)
        op = cmd & 0b0111_1111
        interrupt = (cmd & 0b1000_0000) != 0
    }

    public var isUnpack: Bool { (op & 0x60) == 0x60 }
}
