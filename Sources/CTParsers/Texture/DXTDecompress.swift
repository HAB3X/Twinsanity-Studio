import Foundation

/// Standalone BC1/BC2/BC3 (DXT1/DXT3/DXT5) block decompressors, ported from
/// `Twinsanity/Items/Graphics/TextureX.cs`. Output is a flat top-down
/// `width * height * 4` byte buffer, one packed little-endian BGRA8888 word
/// per pixel (i.e. byte order `[B, G, R, A]`), matching the original's
/// `Buffer.BlockCopy` of a `uint[]` (`0xAARRGGBB` on a little-endian host)
/// straight into a byte array. Only DXT5 is actually reachable from
/// `TextureXParser` (Xbox textures always use it when compressed), but all
/// three are ported for parity with the reference tool's public API.
///
/// One deliberate deviation throughout: the original's `colors`/`alphas`
/// scratch arrays are allocated once outside the per-block loop and only
/// partially reassigned each iteration, so branches the DXT spec defines as
/// "0" (transparent black in DXT1/DXT3's 3-color mode, alpha 0 in DXT5's
/// 6-step mode) actually read back whatever the *previous* block left there.
/// We reset those slots to their spec-defined value explicitly instead of
/// reproducing that cross-block staleness.
public enum DXTDecompress {
    public static func decompressDXT1(_ input: [UInt8], width: Int, height: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width * height * 4)
        var offset = 0
        let bcw = (width + 3) / 4
        let bch = (height + 3) / 4
        let clenLast = (width + 3) % 4 + 1
        var buffer = [UInt32](repeating: 0, count: 16)
        var colors = [Int32](repeating: 0, count: 4)

        for t in 0..<bch {
            for s in 0..<bcw {
                defer { offset += 8 }
                guard offset + 8 <= input.count else { continue }
                let q0 = Int(input[offset]) | (Int(input[offset + 1]) << 8)
                let q1 = Int(input[offset + 2]) | (Int(input[offset + 3]) << 8)
                let (r0, g0, b0) = rgb565(q0)
                let (r1, g1, b1) = rgb565(q1)
                colors[0] = tColor(r0, g0, b0, 255)
                colors[1] = tColor(r1, g1, b1, 255)
                if q0 > q1 {
                    colors[2] = tColor((r0 * 2 + r1) / 3, (g0 * 2 + g1) / 3, (b0 * 2 + b1) / 3, 255)
                    colors[3] = tColor((r0 + r1 * 2) / 3, (g0 + g1 * 2) / 3, (b0 + b1 * 2) / 3, 255)
                } else {
                    colors[2] = tColor((r0 + r1) / 2, (g0 + g1) / 2, (b0 + b1) / 2, 255)
                    colors[3] = 0
                }

                var d = readUInt32LE(input, offset + 4)
                for i in 0..<16 {
                    buffer[i] = UInt32(bitPattern: colors[Int(d & 3)])
                    d >>= 2
                }

                let clen = (s < bcw - 1 ? 4 : clenLast) * 4
                var y = t * 4
                for i in 0..<4 where y < height {
                    blockCopy(buffer, srcWordOffset: i * 4, into: &output, destByteOffset: (y * width + s * 4) * 4, byteCount: clen)
                    y += 1
                }
            }
        }
        return output
    }

    public static func decompressDXT3(_ input: [UInt8], width: Int, height: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width * height * 4)
        var offset = 0
        let bcw = (width + 3) / 4
        let bch = (height + 3) / 4
        let clenLast = (width + 3) % 4 + 1
        var buffer = [UInt32](repeating: 0, count: 16)
        var colors = [Int32](repeating: 0, count: 4)
        var alphas = [Int32](repeating: 0, count: 16)

        for t in 0..<bch {
            for s in 0..<bcw {
                defer { offset += 16 }
                guard offset + 16 <= input.count else { continue }
                for i in 0..<4 {
                    let alpha = Int(input[offset + i * 2]) | (Int(input[offset + i * 2 + 1]) << 8)
                    alphas[i * 4 + 0] = Int32((((alpha >> 0) & 0xF) * 0x11) << 24)
                    alphas[i * 4 + 1] = Int32((((alpha >> 4) & 0xF) * 0x11) << 24)
                    alphas[i * 4 + 2] = Int32((((alpha >> 8) & 0xF) * 0x11) << 24)
                    alphas[i * 4 + 3] = Int32((((alpha >> 12) & 0xF) * 0x11) << 24)
                }

                let q0 = Int(input[offset + 8]) | (Int(input[offset + 9]) << 8)
                let q1 = Int(input[offset + 10]) | (Int(input[offset + 11]) << 8)
                let (r0, g0, b0) = rgb565(q0)
                let (r1, g1, b1) = rgb565(q1)
                colors[0] = tColor(r0, g0, b0, 0)
                colors[1] = tColor(r1, g1, b1, 0)
                if q0 > q1 {
                    colors[2] = tColor((r0 * 2 + r1) / 3, (g0 * 2 + g1) / 3, (b0 * 2 + b1) / 3, 0)
                    colors[3] = tColor((r0 + r1 * 2) / 3, (g0 + g1 * 2) / 3, (b0 + b1 * 2) / 3, 0)
                } else {
                    colors[2] = tColor((r0 + r1) / 2, (g0 + g1) / 2, (b0 + b1) / 2, 0)
                    colors[3] = 0
                }

                var d = readUInt32LE(input, offset + 12)
                for i in 0..<16 {
                    buffer[i] = UInt32(bitPattern: colors[Int(d & 3)] | alphas[i])
                    d >>= 2
                }

                let clen = (s < bcw - 1 ? 4 : clenLast) * 4
                var y = t * 4
                for i in 0..<4 where y < height {
                    blockCopy(buffer, srcWordOffset: i * 4, into: &output, destByteOffset: (y * width + s * 4) * 4, byteCount: clen)
                    y += 1
                }
            }
        }
        return output
    }

    public static func decompressDXT5(_ input: [UInt8], width: Int, height: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width * height * 4)
        var offset = 0
        let bcw = (width + 3) / 4
        let bch = (height + 3) / 4
        let clenLast = (width + 3) % 4 + 1
        var buffer = [UInt32](repeating: 0, count: 16)
        var colors = [Int32](repeating: 0, count: 4)
        var alphas = [Int32](repeating: 0, count: 8)

        for t in 0..<bch {
            for s in 0..<bcw {
                defer { offset += 16 }
                guard offset + 16 <= input.count else { continue }
                alphas[0] = Int32(input[offset])
                alphas[1] = Int32(input[offset + 1])
                if alphas[0] > alphas[1] {
                    alphas[2] = (alphas[0] * 6 + alphas[1]) / 7
                    alphas[3] = (alphas[0] * 5 + alphas[1] * 2) / 7
                    alphas[4] = (alphas[0] * 4 + alphas[1] * 3) / 7
                    alphas[5] = (alphas[0] * 3 + alphas[1] * 4) / 7
                    alphas[6] = (alphas[0] * 2 + alphas[1] * 5) / 7
                    alphas[7] = (alphas[0] + alphas[1] * 6) / 7
                } else {
                    alphas[2] = (alphas[0] * 4 + alphas[1]) / 5
                    alphas[3] = (alphas[0] * 3 + alphas[1] * 2) / 5
                    alphas[4] = (alphas[0] * 2 + alphas[1] * 3) / 5
                    alphas[5] = (alphas[0] + alphas[1] * 4) / 5
                    // BC3/DXT5 spec: the 6-value gradient mode has exactly two
                    // fixed extra entries, 0 and 255. The original C# only
                    // assigns alphas[7] = 255 here and leaves alphas[6] at
                    // whatever it held from the *previous* block (the array is
                    // allocated once outside the block loop), almost always 0
                    // in practice but not guaranteed. We assign it explicitly
                    // per spec rather than reproduce that latent staleness.
                    alphas[6] = 0
                    alphas[7] = 255
                }
                for i in 0..<8 { alphas[i] <<= 24 }

                let q0 = Int(input[offset + 8]) | (Int(input[offset + 9]) << 8)
                let q1 = Int(input[offset + 10]) | (Int(input[offset + 11]) << 8)
                let (r0, g0, b0) = rgb565(q0)
                let (r1, g1, b1) = rgb565(q1)
                colors[0] = tColor(r0, g0, b0, 0)
                colors[1] = tColor(r1, g1, b1, 0)
                if q0 > q1 {
                    colors[2] = tColor((r0 * 2 + r1) / 3, (g0 * 2 + g1) / 3, (b0 * 2 + b1) / 3, 0)
                    colors[3] = tColor((r0 + r1 * 2) / 3, (g0 + g1 * 2) / 3, (b0 + b1 * 2) / 3, 0)
                } else {
                    colors[2] = tColor((r0 + r1) / 2, (g0 + g1) / 2, (b0 + b1) / 2, 0)
                    colors[3] = 0
                }

                var da = readUInt64LE(input, offset) >> 16
                var dc = readUInt32LE(input, offset + 12)
                for i in 0..<16 {
                    buffer[i] = UInt32(bitPattern: alphas[Int(da & 7)] | colors[Int(dc & 3)])
                    da >>= 3
                    dc >>= 2
                }

                let clen = (s < bcw - 1 ? 4 : clenLast) * 4
                var y = t * 4
                for i in 0..<4 where y < height {
                    blockCopy(buffer, srcWordOffset: i * 4, into: &output, destByteOffset: (y * width + s * 4) * 4, byteCount: clen)
                    y += 1
                }
            }
        }
        return output
    }

    // MARK: - Helpers

    private static func rgb565(_ c: Int) -> (r: Int, g: Int, b: Int) {
        var r = (c & 0xF800) >> 8
        var g = (c & 0x07E0) >> 3
        var b = (c & 0x001F) << 3
        r |= r >> 5
        g |= g >> 6
        b |= b >> 5
        return (r, g, b)
    }

    private static func tColor(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> Int32 {
        Int32(truncatingIfNeeded: (r << 16) | (g << 8) | b | (a << 24))
    }

    private static func readUInt32LE(_ data: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64LE(_ data: [UInt8], _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            value = (value << 8) | UInt64(data[offset + i])
        }
        return value
    }

    /// Copies 4 packed `UInt32` words (`srcWordOffset ..< srcWordOffset+4`) as
    /// raw little-endian bytes into `output`, mirroring `Buffer.BlockCopy`
    /// from a `uint[]` source.
    private static func blockCopy(_ buffer: [UInt32], srcWordOffset: Int, into output: inout [UInt8], destByteOffset: Int, byteCount: Int) {
        var written = 0
        var wordIndex = srcWordOffset
        while written < byteCount, wordIndex < buffer.count {
            let word = buffer[wordIndex]
            let bytes: [UInt8] = [
                UInt8(truncatingIfNeeded: word),
                UInt8(truncatingIfNeeded: word >> 8),
                UInt8(truncatingIfNeeded: word >> 16),
                UInt8(truncatingIfNeeded: word >> 24)
            ]
            for b in bytes {
                guard written < byteCount, destByteOffset + written < output.count else { break }
                output[destByteOffset + written] = b
                written += 1
            }
            wordIndex += 1
        }
    }
}
