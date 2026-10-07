import Foundation
import CTCore
import CTModels

/// Decodes an Xbox `TextureX` record (`SectionType.textureX`), ported from
/// `Twinsanity/Items/Graphics/TextureX.cs`. Shares the same 220-byte header
/// prefix as the PS2 `Texture` up through `unkBytes2`, then diverges into an
/// Xbox-specific tail: a 0x2C-byte header extension, a `TextureType`
/// discriminator (0 = raw uncompressed pixels, nonzero = DXT5), and the pixel
/// data itself.
public enum TextureXParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> TextureAsset {
        _ = try cursor.readInt32() // texSize
        _ = try cursor.readInt32() // unkInt
        let wLog2 = try cursor.readInt16()
        let hLog2 = try cursor.readInt16()
        let m = try cursor.readUInt8()
        _ = try cursor.readUInt8() // format
        _ = try cursor.readUInt8() // destinationFormat
        _ = try cursor.readUInt8() // texColComponent
        _ = try cursor.readUInt8() // unkByte
        _ = try cursor.readUInt8() // textureFun
        _ = try cursor.readBytes(2) // unkBytes
        _ = try cursor.readInt32() // textureBasePointer
        for _ in 0..<6 { _ = try cursor.readInt32() } // mipLevelsTBP
        _ = try cursor.readInt32() // textureBufferWidth
        for _ in 0..<6 { _ = try cursor.readInt32() } // mipLevelsTBW
        _ = try cursor.readInt32() // clutBufferBasePointer
        let unkBytes2 = [UInt8](try cursor.readBytes(8))

        _ = try cursor.readBytes(0x2C) // HeaderAdd
        let textureType = try cursor.readUInt32()

        let width = 1 << Int(wLog2)
        let height = 1 << Int(hLog2)
        // See `TextureParser.maxPlausibleDimension`'s doc comment: a corrupt
        // wLog2/hLog2 can make either of these enormous, and the
        // `width * height` below would trap on overflow rather than throw.
        guard width > 0, height > 0, width <= TextureParser.maxPlausibleDimension, height <= TextureParser.maxPlausibleDimension else {
            throw TextureParseError.implausibleDimensions(width: width, height: height)
        }
        _ = max(0, Int(m) - 1) // mip levels: TextureX carries no decoded mip path in the original tool

        if textureType != 0 {
            let compressed = [UInt8](try cursor.readBytes(width * height))
            let decompressedBGRA = DXTDecompress.decompressDXT5(compressed, width: width, height: height)
            let rgba = flipVerticallyBGRAtoRGBA(decompressedBGRA, width: width, height: height)
            return TextureAsset(id: recordID, width: width, height: height, pixelFormat: .dxt5, rgba: rgba)
        } else {
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            for y in stride(from: height - 1, through: 0, by: -1) {
                let rowStart = width * y
                for x in 0..<width {
                    let px = [UInt8](try cursor.readBytes(4)) // on-disk order: B, G, R, A
                    let dst = (rowStart + x) * 4
                    rgba[dst] = px[2]     // R
                    rgba[dst + 1] = px[1] // G
                    rgba[dst + 2] = px[0] // B
                    rgba[dst + 3] = px[3] // A
                }
            }
            // Trailing padding quirk: when unkBytes2[4] isn't the expected
            // 0x84 marker, extra bytes follow before the next record.
            if unkBytes2.count > 4, unkBytes2[4] != 0x84 {
                let skipCount = max(0, Int(unkBytes2[4]) - 0x84)
                _ = try? cursor.skip(skipCount)
            }
            return TextureAsset(id: recordID, width: width, height: height, pixelFormat: .rawRGBA, rgba: rgba)
        }
    }

    /// `DXTDecompress` output is packed BGRA (little-endian `0xAARRGGBB`
    /// words), top-down. The original places it into `RawData` flipped
    /// vertically; we additionally reorder each pixel's bytes to RGBA to
    /// match `TextureAsset.rgba`'s documented layout.
    private static func flipVerticallyBGRAtoRGBA(_ bgra: [UInt8], width: Int, height: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: bgra.count)
        for y in 0..<height {
            let srcRow = y * width * 4
            let dstRow = (height - 1 - y) * width * 4
            for x in 0..<width {
                let s = srcRow + x * 4
                let d = dstRow + x * 4
                guard s + 3 < bgra.count, d + 3 < rgba.count else { continue }
                rgba[d] = bgra[s + 2]     // R
                rgba[d + 1] = bgra[s + 1] // G
                rgba[d + 2] = bgra[s]     // B
                rgba[d + 3] = bgra[s + 3] // A
            }
        }
        return rgba
    }
}
