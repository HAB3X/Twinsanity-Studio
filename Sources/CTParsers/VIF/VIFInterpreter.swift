import Foundation
import CTCore

public enum VIFInterpreterError: Error, CustomStringConvertible {
    case truncatedStream
    public var description: String { "VIF microcode stream ended unexpectedly." }
}

/// A from-scratch reimplementation of the PS2 VIF unpack pipeline, scoped to
/// exactly what Twinsanity's `Model`/`Skin`/`BlendSkin` records need: decoding
/// `UNPACK` instructions into VU-memory vector blocks. Ported from
/// `Twinsanity/VIF/VIFInterpreter.cs`.
///
/// Two things worth flagging for anyone cross-referencing the original source:
///
/// 1. Every unpack in `Execute` calls `Unpack(..., fill: false, write: 1, cycle: 1, addr: 0)`
///   , the *actual* VU write address decoded from the VIFcode's immediate field
///    (`addr` below, masked to 9 bits) is never used to place data; it's only
///    recorded into `addressOutput` as metadata. The real destination is always
///    a fresh 1024-slot block written sequentially from index 0. This isn't a
///    simplification on our part, it's what the original interpreter actually
///    does, and `Model`/`Skin` downstream rely on `addressOutput` purely to
///    classify each block's *semantic role* (0x3 = vertex, 0x4 = UV/color,
///    0x5 = normal, 0x6 = emissive), never as a memory offset.
/// 2. The `usn`/unsigned flag is computed as `Byte(immediate & 0x4000)` in the
///    original, masking bit 14 then truncating to a byte always yields 0, so
///    every unpack is effectively treated as signed. That looks like a leftover
///    bug relative to the real VIF spec (bit 9, not bit 14, is `USN`), but since
///    this is the exact logic the reference tool has been extracting real game
///    files with, we preserve it verbatim rather than "fixing" it.
public final class VIFInterpreter {
    private var vifnR: [UInt32] = [0, 0, 0, 0]
    private var vifnC: [UInt32] = [0, 0, 0, 0]
    private var vifnCycle: UInt32 = 0
    private var vifnMode: UInt32 = 0

    /// One entry per executed UNPACK instruction, in program order; each is a
    /// 1024-slot VU memory block (nil where nothing was ever written).
    private(set) var vuMem: [[VIFVector4?]] = []
    /// One entry per `MSCAL` boundary (plus an implicit first group), each
    /// holding the raw VU addresses named by the unpacks executed in that group.
    private(set) var addressOutput: [[UInt16]] = []

    public func getMem() -> [[VIFVector4?]] { vuMem }
    public func getAddressOutput() -> [[UInt16]] { addressOutput }

    /// Entry point mirroring `VIFInterpreter.InterpretCode(byte[])`: every
    /// on-disk VifCode blob is DMA-tag-prefixed (16 bytes: packed QWC in the
    /// low tag, a 64-bit `Extra` field, then `QWC * 16` bytes of actual VIF
    /// microcode). `Extra`'s raw bytes are spliced in as the first 8 bytes of
    /// the executed stream, for the synthetic tags this package builds for
    /// blend-shape blobs, `Extra` *is* a hand-authored VIFcode (see
    /// `BlendSkinParser`).
    public static func interpretCode(_ code: Data) throws -> VIFInterpreter {
        var reader = BinaryCursor(data: code)
        let tagLow = try reader.readUInt64()
        let qwc = Int(tagLow & 0xFFFF)
        let extra = try reader.readUInt64()

        var combined = BinaryWriter()
        combined.writeUInt64(extra)
        let vifBytes = try reader.readBytes(qwc * 0x10)
        combined.writeBytes(vifBytes)

        let interpreter = VIFInterpreter()
        var vifCursor = BinaryCursor(data: combined.data)
        try interpreter.execute(&vifCursor)
        return interpreter
    }

    private func execute(_ reader: inout BinaryCursor) throws {
        while reader.position < reader.count {
            guard reader.remaining >= 4 else { break }
            let word = try reader.readUInt32()
            let vif = VIFCode(word: word)

            if vif.isUnpack {
                let cmd = vif.op
                let vn = (cmd & 0b1100) >> 2
                let vl = (cmd & 0b0011) >> 0
                let amount = vif.amount
                let addr: UInt16 = vif.immediate & 0b1_1111_1111
                // See type-level doc: this mask matches the original tool's
                // (likely buggy, intentionally preserved) bit position.
                let usn: UInt8 = UInt8(truncatingIfNeeded: vif.immediate & 0b0100_0000_0000_0000)
                let wl = UInt8((vifnCycle >> 8) & 0xFF)
                let cl = UInt8((vifnCycle >> 0) & 0xFF)
                let dimensions = UInt32(vn) + 1
                let isFillCycle = wl > cl

                let packetLength: UInt32
                if !isFillCycle {
                    let a = Double(32 >> vl)
                    let b = Double(dimensions)
                    let c = a * b * Double(amount)
                    packetLength = 1 + UInt32(( c / 32.0).rounded(.up))
                } else {
                    let wlInt = Int(wl == 0 ? 1 : wl) // guard div-by-zero; WL=0 is not a valid fill cycle anyway
                    let amountMod = Int(amount) % wlInt
                    let n = UInt32(Int(cl) * (Int(amount) / wlInt) + (amountMod > Int(cl) ? Int(cl) : amountMod))
                    let a = Double(32 >> vl)
                    let b = Double(dimensions)
                    let c = a * b * Double(n)
                    packetLength = 1 + UInt32((c / 32.0).rounded(.up))
                }

                if addressOutput.isEmpty {
                    addressOutput.append([])
                }
                addressOutput[addressOutput.count - 1].append(addr)

                let fmt = VIFPackFormat(rawValue: vl | (vn << 2))

                var vectors: [VIFVector4?] = Array(repeating: nil, count: 1024)
                var tmpStack: [UInt32] = []
                tmpStack.reserveCapacity(max(0, Int(packetLength) - 1))
                for _ in 0..<max(0, Int(packetLength) - 1) {
                    guard reader.remaining >= 4 else { throw VIFInterpreterError.truncatedStream }
                    tmpStack.append(try reader.readUInt32())
                }

                // Preserve index alignment with the original: an unrecognized
                // pack format (vl==3 combos, which VIF never legally encodes)
                // still contributes an (all-nil) VU block, matching the C#
                // switch's no-op-then-append behavior, Model/Skin address
                // downstream blocks positionally, so skipping the append here
                // would desync every later index.
                if let fmt {
                    var zeroAddr: UInt16 = 0
                    unpack(src: tmpStack, dst: &vectors, fmt: fmt, amount: amount, unsigned: usn, fill: false, wl: 1, cl: 1, addr: &zeroAddr)
                }
                vuMem.append(vectors)
            } else {
                switch VIFOpcode(rawValue: vif.op) {
                case .stcycl:
                    vifnCycle = UInt32(vif.immediate)
                case .stmod:
                    vifnMode = UInt32(vif.immediate) & 0b11
                case .mscal, .mscalf:
                    addressOutput.append([])
                case .stmask:
                    _ = try reader.readUInt32()
                case .strow:
                    for i in 0..<4 { vifnR[i] = try reader.readUInt32() }
                case .stcol:
                    for i in 0..<4 { vifnC[i] = try reader.readUInt32() }
                case .direct, .directhl:
                    // Out of scope: GS primitive submission is never present in
                    // the pure-geometry VifCode blobs Model/Skin/BlendSkin store
                    // (confirmed structurally, they're unpack-only streams).
                    // Bail out of this stream rather than mis-parsing GIFtags we
                    // don't need, instead of guessing at payload length.
                    return
                default:
                    break // NOP, OFFSET, BASE, ITOP, MSKPATH3, MARK, FLUSH*, MPG, MSCNT: no state we need
                }
            }
        }
    }

    private func sext(_ n: inout UInt32) {
        if (n & 0x8000) != 0 { n |= 0xFFFF_0000 }
    }
    private func sext8(_ n: inout UInt32) {
        if (n & 0x80) != 0 { n |= 0xFFFF_FF00 }
    }

    private func isInOffsetMode() -> Bool { (vifnMode & 0b01) == 1 }

    private func rowOffset(_ lane: Int) -> UInt32 { isInOffsetMode() ? vifnR[lane] : 0 }

    /// Writes `vec` into `dst[addr]` if `addr` is in range, then advances
    /// `addr`. The original C# writes into a fixed 1024-slot `List<Vector4>`
    /// and would throw past that bound; real game data never does, but we
    /// guard anyway so a malformed/hand-edited file degrades to a dropped
    /// vector instead of a crash.
    private func writeSlot(_ dst: inout [VIFVector4?], _ vec: VIFVector4, _ addr: inout UInt16) {
        if Int(addr) < dst.count { dst[Int(addr)] = vec }
        addr += 1
    }

    private func fill(dst: inout [VIFVector4?], vec: VIFVector4, index: Int, fill doFill: Bool, wl: UInt8, cl: UInt8, addr: inout UInt16) {
        if doFill {
            let didCompleteCycle = cl != 0 && (index + 1) % Int(cl) == 0
            writeSlot(&dst, vec, &addr)
            if didCompleteCycle && wl > cl {
                var fillVec = VIFVector4()
                fillVec.binaryX = vifnR[0]
                fillVec.binaryY = vifnR[1]
                fillVec.binaryZ = vifnR[2]
                fillVec.binaryW = vifnR[3]
                for _ in 0..<Int(wl - cl) {
                    writeSlot(&dst, fillVec, &addr)
                }
            }
            return
        }
        let skipAmount = Int(cl) - Int(wl)
        writeSlot(&dst, vec, &addr)
        if wl != 0 {
            let doSkip = (index + 1) % Int(wl) == 0
            if doSkip {
                addr = UInt16(max(0, Int(addr) + skipAmount))
            }
        }
    }

    private func unpack(src: [UInt32], dst: inout [VIFVector4?], fmt: VIFPackFormat, amount: UInt8, unsigned: UInt8, fill doFill: Bool, wl: UInt8, cl: UInt8, addr: inout UInt16) {
        var srcIdx = 0
        switch fmt {
        case .s32:
            for i in 0..<Int(amount) where i < src.count {
                var v = VIFVector4()
                v.binaryX = src[i] &+ rowOffset(0)
                v.binaryY = src[i] &+ rowOffset(1)
                v.binaryZ = src[i] &+ rowOffset(2)
                v.binaryW = src[i] &+ rowOffset(3)
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
            }
        case .s16:
            for i in 0..<Int(amount) {
                let mask: UInt32 = (i % 2 == 0) ? 0x0000_FFFF : 0xFFFF_0000
                guard srcIdx < src.count else { break }
                var w1 = src[srcIdx] & mask
                if i % 2 != 0 { w1 >>= 16; srcIdx += 1 }
                if unsigned == 0 { sext(&w1) }
                var v = VIFVector4()
                v.binaryX = w1 &+ rowOffset(0)
                v.binaryY = w1 &+ rowOffset(1)
                v.binaryZ = w1 &+ rowOffset(2)
                v.binaryW = w1 &+ rowOffset(3)
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
            }
        case .s8:
            for i in 0..<Int(amount) {
                var mask: UInt32 = 0x0000_00FF
                var shift = 0
                switch i % 4 {
                case 1: mask = 0x0000_FF00; shift = 8
                case 2: mask = 0x00FF_0000; shift = 16
                case 3: mask = 0xFF00_0000; shift = 24
                default: break
                }
                guard srcIdx < src.count else { break }
                var w1 = (src[srcIdx] & mask) >> shift
                if unsigned == 0 { sext8(&w1) }
                var v = VIFVector4()
                v.binaryX = w1 &+ rowOffset(0)
                v.binaryY = w1 &+ rowOffset(1)
                v.binaryZ = w1 &+ rowOffset(2)
                v.binaryW = w1 &+ rowOffset(3)
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
                if i % 4 == 3 { srcIdx += 1 }
            }
        case .v2_32:
            for i in 0..<(src.count / 2) {
                var v = VIFVector4()
                v.binaryX = src[i * 2 + 0] &+ rowOffset(0)
                v.binaryY = src[i * 2 + 1] &+ rowOffset(1)
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
            }
        case .v2_16:
            for i in 0..<src.count {
                var w1 = src[i] & 0x0000_FFFF
                var w2 = (src[i] & 0xFFFF_0000) >> 16
                if unsigned == 0 { sext(&w1); sext(&w2) }
                var v = VIFVector4()
                v.binaryX = w1 &+ rowOffset(0)
                v.binaryY = w2 &+ rowOffset(1)
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
            }
        case .v2_8:
            for i in 0..<Int(amount) {
                var mask0: UInt32 = 0x0000_00FF
                var mask1: UInt32 = 0x0000_FF00
                var shift0 = 0, shift1 = 8
                if i % 2 != 0 {
                    mask0 = 0x00FF_0000; mask1 = 0xFF00_0000
                    shift0 = 16; shift1 = 24
                }
                guard srcIdx < src.count else { break }
                var w1 = (src[srcIdx] & mask0) >> shift0
                var w2 = (src[srcIdx] & mask1) >> shift1
                if unsigned == 0 { sext8(&w1); sext8(&w2) }
                var v = VIFVector4()
                v.binaryX = w1 &+ rowOffset(0)
                v.binaryY = w2 &+ rowOffset(1)
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
                if i % 2 != 0 { srcIdx += 1 }
            }
        case .v3_32:
            for i in 0..<(src.count / 3) {
                var v = VIFVector4()
                v.binaryX = src[i * 3 + 0] &+ rowOffset(0)
                v.binaryY = src[i * 3 + 1] &+ rowOffset(1)
                v.binaryZ = src[i * 3 + 2] &+ rowOffset(2)
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
            }
        case .v3_16:
            for i in 0..<Int(amount) {
                var mask0: UInt32 = 0x0000_FFFF, mask1: UInt32 = 0xFFFF_0000
                var shift0 = 0, shift1 = 16
                if i % 2 != 0 {
                    mask0 = 0xFFFF_0000; mask1 = 0x0000_FFFF
                    shift0 = 16; shift1 = 0
                }
                guard srcIdx < src.count else { break }
                var w1 = (src[srcIdx] & mask0) >> shift0
                if i % 2 != 0 { srcIdx += 1 }
                guard srcIdx < src.count else { break }
                var w2 = (src[srcIdx] & mask1) >> shift1
                if i % 2 == 0 { srcIdx += 1 }
                guard srcIdx < src.count else { break }
                var w3 = (src[srcIdx] & mask0) >> shift0
                if i % 2 != 0 { srcIdx += 1 }
                if unsigned == 0 { sext(&w1); sext(&w2); sext(&w3) }
                var v = VIFVector4()
                v.binaryX = w1 &+ rowOffset(0)
                v.binaryY = w2 &+ rowOffset(1)
                v.binaryZ = w3 &+ rowOffset(2)
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
            }
        case .v3_8:
            for i in 0..<Int(amount) {
                var mask: [UInt32] = [0x0000_00FF, 0x0000_FF00, 0x00FF_0000]
                var shift: [Int] = [0, 8, 16]
                var incIdx = [false, false, false]
                switch i % 4 {
                case 1:
                    mask = [0xFF00_0000, 0x0000_00FF, 0x0000_FF00]
                    shift = [24, 0, 8]
                    incIdx[0] = true
                case 2:
                    mask = [0x00FF_0000, 0xFF00_0000, 0x0000_00FF]
                    shift = [16, 24, 0]
                    incIdx[1] = true
                case 3:
                    mask = [0x0000_FF00, 0x00FF_0000, 0xFF00_0000]
                    shift = [8, 16, 24]
                    incIdx[2] = true
                default: break
                }
                guard srcIdx < src.count else { break }
                var w1 = (src[srcIdx] & mask[0]) >> shift[0]
                if incIdx[0] { srcIdx += 1 }
                guard srcIdx < src.count else { break }
                var w2 = (src[srcIdx] & mask[1]) >> shift[1]
                if incIdx[1] { srcIdx += 1 }
                guard srcIdx < src.count else { break }
                var w3 = (src[srcIdx] & mask[2]) >> shift[2]
                if incIdx[2] { srcIdx += 1 }
                if unsigned == 0 { sext8(&w1); sext8(&w2); sext8(&w3) }
                var v = VIFVector4()
                v.binaryX = w1 &+ rowOffset(0)
                v.binaryY = w2 &+ rowOffset(1)
                v.binaryZ = w3 &+ rowOffset(2)
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
            }
        case .v4_32:
            for i in 0..<(src.count / 4) {
                var v = VIFVector4()
                v.binaryX = src[i * 4 + 0] &+ rowOffset(0)
                v.binaryY = src[i * 4 + 1] &+ rowOffset(1)
                v.binaryZ = src[i * 4 + 2] &+ rowOffset(2)
                v.binaryW = src[i * 4 + 3] &+ rowOffset(3)
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
            }
        case .v4_16:
            for i in 0..<(src.count / 2) {
                var w1 = src[i * 2] & 0x0000_FFFF
                var w2 = (src[i * 2] & 0xFFFF_0000) >> 16
                var w3 = src[i * 2 + 1] & 0x0000_FFFF
                var w4 = (src[i * 2 + 1] & 0xFFFF_0000) >> 16
                if unsigned == 0 { sext(&w1); sext(&w2); sext(&w3); sext(&w4) }
                var v = VIFVector4()
                v.binaryX = w1 &+ rowOffset(0)
                v.binaryY = w2 &+ rowOffset(1)
                v.binaryZ = w3 &+ rowOffset(2)
                v.binaryW = w4 &+ rowOffset(3)
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
            }
        case .v4_8:
            for i in 0..<src.count {
                var w1 = src[i] & 0x0000_00FF
                var w2 = (src[i] & 0x0000_FF00) >> 8
                var w3 = (src[i] & 0x00FF_0000) >> 16
                var w4 = (src[i] & 0xFF00_0000) >> 24
                if unsigned == 0 { sext8(&w1); sext8(&w2); sext8(&w3); sext8(&w4) }
                var v = VIFVector4()
                v.binaryX = w1 &+ rowOffset(0)
                v.binaryY = w2 &+ rowOffset(1)
                v.binaryZ = w3 &+ rowOffset(2)
                v.binaryW = w4 &+ rowOffset(3)
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
            }
        case .v4_5:
            for i in 0..<Int(amount) {
                let mask: UInt32 = (i % 2 == 0) ? 0x0000_FFFF : 0xFFFF_0000
                guard srcIdx < src.count else { break }
                var rgba = src[srcIdx] & mask
                if i % 2 != 0 { rgba >>= 16; srcIdx += 1 }
                let r = UInt8((rgba & 0b11111) << 3)
                let g = UInt8(((rgba & (0b11111 << 5)) >> 5) << 3)
                let b = UInt8(((rgba & (0b11111 << 10)) >> 10) << 3)
                let a = UInt8(((rgba & (0b1 << 15)) >> 15) << 7)
                var v = VIFVector4()
                v.x = Float(r) / 255.0
                v.y = Float(g) / 255.0
                v.z = Float(b) / 255.0
                v.w = Float(a) / 255.0
                fill(dst: &dst, vec: v, index: i, fill: doFill, wl: wl, cl: cl, addr: &addr)
            }
        }
    }
}
