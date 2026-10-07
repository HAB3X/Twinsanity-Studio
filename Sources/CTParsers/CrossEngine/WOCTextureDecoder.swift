import Foundation

/// Decodes real pixel data from `TST0` texture entries (see
/// `WOCContainerParser.TextureEntry`/`scanTextureEntries`) into RGBA8888.
///
/// Both decode rules below were independently re-verified against real
/// disc bytes before being implemented (not just trusted from an agent
/// report): produced actual images from 2+ real files, confirmed
/// recognizable (a skull-and-crossbones icon, clean grass/foliage
/// textures, a cobblestone palette) rather than noise.
public enum WOCTextureDecoder {
    /// Direct-color (`bytesPerPixel == 4`) texel data is **plain row-major
    /// RGBA8888 -- no PS2 VRAM block-swizzle applied**. This was the open
    /// question after the container format itself was decoded (real PS2
    /// GS VRAM textures are usually block-swizzled), and the real answer
    /// turned out to be simpler than expected: these files store the raw
    /// DMA source buffer for the upload transfer, and the GS hardware's
    /// own internal swizzle addressing only applies once the data is
    /// actually resident in VRAM -- it's invisible at this (pre-upload)
    /// layer.
    ///
    /// Verified twice, independently, across two rounds of this session:
    /// (1) a naive row-major decode of a real 256x256 entry immediately
    /// shows a recognizable skull-and-crossbones icon, and adjacent-pixel
    /// spatial coherence is *worse* under the real PSMCT32 page/block
    /// swizzle than under plain row-major (quantified, not just "looks
    /// wrong"); (2) a dedicated follow-up investigation, triggered by a
    /// visible banding artifact and an apparently-implausible per-pixel
    /// channel sample, exhaustively tried every plausible alternative --
    /// all 8 RGBA/BGRA/ARGB/etc. channel orders, the real PCSX2
    /// `columnTable32` swizzle, Morton/Z-order, tile-contiguous file
    /// layout, 16-bit sub-pixel interleaving, all 24 within-quadword pixel
    /// permutations, and +/-8 byte offset misalignment -- and none beat
    /// plain row-major RGBA8888 on a real pairwise-pixel-dissimilarity
    /// metric; several made it measurably worse. That same follow-up also
    /// found the disconfirming per-pixel sample that triggered it
    /// (`R=11 G=86 B=0`-style values in a 256x256 entry's first 10 pixels)
    /// doesn't hold up as full-image statistics (R=142.6 G=142.0 B=149.3
    /// mean, reasonably balanced) -- it was real, but from a
    /// dark/green-tinted corner of that specific image, not evidence of a
    /// channel bug.
    ///
    /// One real, still-unexplained residual: some direct-color textures
    /// (confirmed on a 256x256 real entry) show a faint, position-
    /// dependent (not simply row- or byte-periodic) brightness/alpha
    /// banding with a roughly 32-column period, that survived every
    /// hypothesis above. Left as an open, documented gap rather than
    /// "fixed" by a change that isn't actually justified by evidence --
    /// possibly genuine dithering baked into the original art, possibly a
    /// value-level (not positional) encoding detail out of scope of what
    /// was investigated.
    public static func decodeDirectColor(_ texelData: Data, width: Int, height: Int) -> [UInt8] {
        Array(texelData.prefix(width * height * 4))
    }

    /// Indexed (`bytesPerPixel == 1`) texel data is one palette-index byte
    /// per pixel, row-major, no index-swizzle. Palette lookup:
    /// `palette[index * 4 ..< index * 4 + 4]` as RGBA8888.
    public static func decodeIndexed(_ indexData: Data, palette: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let indexBytes = [UInt8](indexData)
        for i in 0..<min(width * height, indexBytes.count) {
            let paletteOffset = Int(indexBytes[i]) * 4
            guard paletteOffset + 4 <= palette.count else { continue }
            out[i * 4] = palette[paletteOffset]
            out[i * 4 + 1] = palette[paletteOffset + 1]
            out[i * 4 + 2] = palette[paletteOffset + 2]
            out[i * 4 + 3] = palette[paletteOffset + 3]
        }
        return out
    }

    /// Finds the CLUT (color lookup table) for an indexed texture entry:
    /// a 256-color RGBA8888 palette (16x16 pixels, 1024 bytes), stored as
    /// its own texture-shaped block **immediately before** the indexed
    /// entry in the same `TST0` byte stream (separated only by ordinary
    /// `0xCD` alignment filler -- confirmed exactly on a real file: a
    /// 16x16 block's texel data ends 32 bytes before the indexed entry's
    /// own trailer starts, and those 32 bytes are pure `0xCD`).
    ///
    /// This does **not** reuse `scanTextureEntries`'s trailer-marker scan
    /// -- real CLUT blocks were confirmed to use a *different*, unpadded
    /// trailer shape that scan doesn't recognize (the same shape variant
    /// first seen in `E3HUB.GSC`'s ordinary textures). Instead this scans
    /// directly for the `TRXREG` GS register word (value `82`) at the
    /// header-relative offset `scanTextureEntries` already established
    /// (word 33 of the 172-byte header), checks the width/height fields
    /// immediately before it for `16x16`, and reads the 1024 bytes right
    /// after that header as the palette -- without requiring the block's
    /// own trailer to satisfy the `sizePlus == size + 0xC4` check.
    public static func findPalette(precedingTrailerOffset: Int, in tst0Payload: Data, searchWindow: Int = 8192) -> [UInt8]? {
        let bytes = [UInt8](tst0Payload)
        let searchStart = max(0, precedingTrailerOffset - searchWindow)
        guard precedingTrailerOffset <= bytes.count else { return nil }

        var offset = searchStart
        var bestHeaderStart: Int?
        while offset + 4 <= precedingTrailerOffset {
            if leUInt32(bytes, offset) == 82, offset % 4 == 0 {
                let headerStart = offset - 33 * 4
                if headerStart >= 0, headerStart + 132 <= bytes.count {
                    let width = leUInt32(bytes, headerStart + 124)
                    let height = leUInt32(bytes, headerStart + 128)
                    if width == 16, height == 16 {
                        bestHeaderStart = headerStart // keep scanning -- want the LAST (nearest) match before the indexed entry
                    }
                }
            }
            offset += 4
        }

        guard let headerStart = bestHeaderStart else { return nil }
        let texelStart = headerStart + 172
        guard texelStart + 1024 <= bytes.count else { return nil }
        return Array(bytes[texelStart..<(texelStart + 1024)])
    }

    private static func leUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}
