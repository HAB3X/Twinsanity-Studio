import Foundation
import CTCore
import CTModels

/// Thrown when a texture record's decoded `width`/`height` (`1 <<
/// wLog2`/`1 << hLog2`, straight off disk) are too large to be a real PS2/
/// Xbox texture, see `TextureParser.parse`'s guard for why this exists.
public enum TextureParseError: Error, CustomStringConvertible {
    case implausibleDimensions(width: Int, height: Int)

    public var description: String {
        switch self {
        case .implausibleDimensions(let width, let height):
            return "Texture dimensions \(width)×\(height) exceed any plausible real PS2/Xbox texture size, this record is likely corrupt or truncated."
        }
    }
}

/// Decodes a PS2 `Texture` record (`SectionType.texture`), ported from
/// `Twinsanity/Items/Graphics/Texture.cs`. Only `PSMCT32` (raw RGBA) and
/// `PSMT8` (8bpp paletted, GS block-swizzled) are fully decoded, matching the
/// original tool exactly; every other GS pixel format falls back to a raw
/// byte passthrough there too, so we do the same rather than guessing at an
/// unimplemented format's layout.
public enum TextureParser {
    /// No real PS2 or Xbox game texture is anywhere near this size (PS2 GS
    /// hardware itself can't address a texture much larger than 1024 per
    /// side), this is purely a corrupt-input guard, generous enough to
    /// never reject a real texture. `width`/`height` are `1 << wLog2`/
    /// `1 << hLog2` computed straight from two `Int16`s read off disk, so a
    /// corrupt or truncated record can make either one enormous; the `<<`
    /// itself can't crash (Swift's shift is well-defined for any shift
    /// amount), but a later `width * height` easily can, Swift's `*`
    /// traps on overflow rather than throwing. Checked immediately after
    /// computing them and before any multiplication touches them.
    static let maxPlausibleDimension = 8192
    /// GS pixel-format codes (`Texture.TexturePixelFormat`).
    private enum GSFormat: UInt8 {
        case psmct32 = 0b000000
        case psmct24 = 0b000001
        case psmct16 = 0b000010
        case psmct16s = 0b001010
        case psmt8 = 0b010011
        case psmt4 = 0b010100
        case psmt8h = 0b011011
        case psmt4hl = 0b100100
        case psmt4hh = 0b101100
        case psmz32 = 0b110000
        case psmz24 = 0b110001
        case psmz16 = 0b110010
        case psmz16s = 0b111010

        var modelFormat: TexturePixelFormat {
            switch self {
            case .psmct32: return .psmct32
            case .psmct24: return .psmct24
            case .psmct16: return .psmct16
            case .psmct16s: return .psmct16s
            case .psmt8: return .psmt8
            case .psmt4: return .psmt4
            case .psmt8h: return .psmt8h
            case .psmt4hl: return .psmt4hl
            case .psmt4hh: return .psmt4hh
            case .psmz32: return .psmz32
            case .psmz24: return .psmz24
            case .psmz16: return .psmz16
            case .psmz16s: return .psmz16s
            }
        }
    }

    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> TextureAsset {
        let texSize = Int(try cursor.readInt32())
        _ = try cursor.readInt32() // unkInt
        let wLog2 = try cursor.readInt16()
        let hLog2 = try cursor.readInt16()
        let m = try cursor.readUInt8()
        let format = try cursor.readUInt8()
        _ = try cursor.readUInt8() // destinationFormat
        _ = try cursor.readUInt8() // texColComponent
        _ = try cursor.readUInt8() // unkByte
        _ = try cursor.readUInt8() // textureFun
        _ = try cursor.readBytes(2) // unkBytes
        _ = try cursor.readInt32() // textureBasePointer
        var mipLevelsTBP = [Int](repeating: 0, count: 6)
        for i in 0..<6 { mipLevelsTBP[i] = Int(try cursor.readInt32()) }
        let textureBufferWidth = Int(try cursor.readInt32())
        var mipLevelsTBW = [Int](repeating: 0, count: 6)
        for i in 0..<6 { mipLevelsTBW[i] = Int(try cursor.readInt32()) }
        let clutBufferBasePointer = Int(try cursor.readInt32())
        _ = try cursor.readBytes(8) // unkBytes2
        _ = try cursor.readInt32() // reserved: vifCodeBlock index
        _ = try cursor.readInt32() // reserved: unknown pointer
        _ = try cursor.readBytes(2) // unkBytes3
        _ = try cursor.readBytes(2) // reserved
        _ = try cursor.readBytes(32) // unusedMetadata
        let vifBlock = try cursor.readBytes(96)

        // RRW/RRH (GS transfer-rectangle width/height) live at byte offset
        // 48/52 within the 96-byte VIF setup block.
        var vifCursor = BinaryCursor(data: vifBlock)
        try vifCursor.skip(48)
        let rrw = Int(try vifCursor.readInt32())
        let rrh = Int(try vifCursor.readInt32())
        // Real bug fix: `rrw`/`rrh` feed straight into `EzSwizzle`'s write
        // loop, unlike `width`/`height` below which already get this same
        // upper-bound plausibility check. `EzSwizzle` itself already
        // guards the *lower* end (`rrw > 0, rrh > 0` before it loops at
        // all, so a real, legitimate zero here, this codebase's own test
        // fixtures use an all-zero VIF block, safely no-ops, same as
        // before this fix) -- it never guarded the *upper* end. A corrupt/
        // crafted record with a huge value here made that loop run
        // billions of iterations with no crash and no error -- the app
        // just hung on file open. Only capping the upper bound, not
        // requiring positivity, preserves every previously-valid record
        // (including a legitimately unset/zero transfer rectangle) while
        // still closing the actual hang.
        guard rrw <= maxPlausibleDimension, rrh <= maxPlausibleDimension else {
            throw TextureParseError.implausibleDimensions(width: rrw, height: rrh)
        }

        let width = 1 << Int(wLog2)
        let height = 1 << Int(hLog2)
        guard width > 0, height > 0, width <= maxPlausibleDimension, height <= maxPlausibleDimension else {
            throw TextureParseError.implausibleDimensions(width: width, height: height)
        }
        let mipLevels = max(0, Int(m) - 1)
        let pixelDataLength = max(0, texSize - 224)
        let gsFormat = GSFormat(rawValue: format)

        switch gsFormat {
        case .psmct32:
            let imageData = [UInt8](try cursor.readBytes(pixelDataLength))
            let rgba = decodePSMCT32(imageData)
            return TextureAsset(id: recordID, width: width, height: height, pixelFormat: .psmct32, rgba: rgba)

        case .psmt8:
            let imageData = [UInt8](try cursor.readBytes(pixelDataLength))

            // One EzSwizzle instance, one populated GS memory: the base
            // texture *and* every mip level live in the same swizzled
            // PSMCT32 upload, addressed at different TBP/TBW offsets, mips
            // must be read back from the same simulated memory the base
            // level was written into, not a fresh empty buffer.
            let ez = EzSwizzle()
            ez.cleanGs()
            ez.writeTexPSMCT32(dbp: 0, dbw: 1, dsax: 0, dsay: 0, rrw: rrw, rrh: rrh, data: imageData)

            var indexes = [UInt8](repeating: 0, count: width * height)
            ez.readTexPSMT8(dbp: 0, dbwIn: textureBufferWidth, dsax: 0, dsay: 0, rrw: width, rrh: height, into: &indexes)
            let palette = decodePalette(using: ez, clutBufferBasePointer: clutBufferBasePointer)
            flip(&indexes, width: width, height: height)
            let rgba = applyPalette(indexes, palette: palette)

            var mips: [[UInt8]] = []
            // `mipLevelsTBP`/`mipLevelsTBW` are fixed 6-slot arrays (the GS
            // mip chain never carries more), but `m` is an arbitrary on-disk
            // byte -- a corrupt/hand-modded texture record with `m >= 8` on
            // a large enough base texture would otherwise index past slot 5
            // before `mipWidth`/`mipHeight` ever hits 0 and crashes the app
            // on file open.
            for level in 0..<min(mipLevels, mipLevelsTBP.count) {
                let mipWidth = width / (1 << (level + 1))
                let mipHeight = height / (1 << (level + 1))
                guard mipWidth > 0, mipHeight > 0 else { break }
                var mipIndexes = [UInt8](repeating: 0, count: mipWidth * mipHeight)
                ez.readTexPSMT8(dbp: mipLevelsTBP[level], dbwIn: mipLevelsTBW[level], dsax: 0, dsay: 0, rrw: mipWidth, rrh: mipHeight, into: &mipIndexes)
                flip(&mipIndexes, width: mipWidth, height: mipHeight)
                mips.append(applyPalette(mipIndexes, palette: palette))
            }
            return TextureAsset(id: recordID, width: width, height: height, pixelFormat: .psmt8, rgba: rgba, mips: mips)

        default:
            _ = try cursor.readBytes(pixelDataLength) // raw passthrough, undecoded (matches original tool)
            return TextureAsset(
                id: recordID, width: width, height: height,
                pixelFormat: gsFormat?.modelFormat ?? .unknown,
                rgba: [UInt8](repeating: 0, count: width * height * 4)
            )
        }
    }

    private static func decodePSMCT32(_ imageData: [UInt8]) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: imageData.count)
        var i = 0
        while i + 3 < imageData.count {
            rgba[i] = imageData[i]
            rgba[i + 1] = imageData[i + 1]
            rgba[i + 2] = imageData[i + 2]
            rgba[i + 3] = UInt8(clamping: Int(imageData[i + 3]) << 1) // GS alpha is 7-bit (0...128) -> 0...255
            i += 4
        }
        return rgba
    }

    /// `SwapPalette`, undoes PS2 CSM1 palette storage, which interleaves
    /// 8-entry blocks within each 32-entry group (`Texture.cs:378-389`).
    /// Self-inverse (a set of disjoint element swaps, applied twice is a
    /// no-op) -- `TextureWriter.encodePSMT8` reuses this exact function to
    /// re-interleave an encoded palette back into CSM1 storage order, same
    /// reasoning as why that's correct rather than needing a separate
    /// "unswap." Not `private` for exactly that reuse.
    static func swapPalette(_ palette: inout [[UInt8]]) {
        for i in 0..<8 {
            for j in stride(from: 8 + i * 32, to: 16 + i * 32, by: 1) {
                guard j + 8 < palette.count else { continue }
                palette.swapAt(j, j + 8)
            }
        }
    }

    private static func decodePalette(using ez: EzSwizzle, clutBufferBasePointer: Int) -> [[UInt8]] {
        var raw = [UInt8](repeating: 0, count: 256 * 4)
        ez.readTexPSMCT32(dbp: clutBufferBasePointer, dbw: 1, dsax: 0, dsay: 0, rrw: 16, rrh: 16, into: &raw)
        var palette: [[UInt8]] = []
        palette.reserveCapacity(256)
        var i = 0
        while i + 3 < raw.count {
            let a = UInt8(clamping: Int(raw[i + 3]) << 1)
            palette.append([raw[i], raw[i + 1], raw[i + 2], a])
            i += 4
        }
        swapPalette(&palette)
        return palette
    }

    private static func applyPalette(_ indexes: [UInt8], palette: [[UInt8]]) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: indexes.count * 4)
        for (i, idx) in indexes.enumerated() {
            let color = Int(idx) < palette.count ? palette[Int(idx)] : [0, 0, 0, 0]
            rgba[i * 4] = color[0]
            rgba[i * 4 + 1] = color[1]
            rgba[i * 4 + 2] = color[2]
            rgba[i * 4 + 3] = color[3]
        }
        return rgba
    }

    /// Vertical mirror, applied to `indexes` in place -- self-inverse for
    /// the same reason `swapPalette` is (row-pair swaps, applied twice is a
    /// no-op). Not `private` so `TextureWriter.encodePSMT8` can apply it
    /// before writing, undoing the mirror this applies after reading.
    static func flip(_ indexes: inout [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        for y in 0..<(height / 2) {
            for x in 0..<width {
                let a = y * width + x
                let b = (height - y - 1) * width + x
                guard a < indexes.count, b < indexes.count else { continue }
                indexes.swapAt(a, b)
            }
        }
    }

}
