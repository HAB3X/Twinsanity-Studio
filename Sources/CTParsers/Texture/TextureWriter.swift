import Foundation
import CTCore
import CTModels

/// Encodes a `TextureAsset` back to its on-disk pixel-data bytes, the
/// write-back half of `TextureParser`'s decode, needed for "Asset Swap &
/// Quick-Test: Recipe Book" (blueprint 6.4)'s sprite-sheet/texture-replace
/// feature (see `RecipeBookView`'s doc comment for why that was blocked
/// until this existed: nothing in `CTParsers`/`CTExport` wrote a texture
/// record back to its on-disk compressed form).
///
/// PSMCT32 and PSMT8 are supported.
///
/// PSMCT32 is a flat, unswizzled byte passthrough (no GS block-swizzling,
/// no CLUT/palette), `decodePSMCT32` is genuinely just "copy RGB, widen
/// GS's 7-bit alpha to 8-bit," so its inverse is an exact, verifiable
/// round trip.
///
/// PSMT8 needs real color quantization (`PSMT8Quantizer`, median-cut) to
/// re-populate a palette from an arbitrary replacement image, plus
/// re-swizzling the resulting indices and palette back through `EzSwizzle`
/// (the same block-address tables `TextureParser.parse`'s decode already
/// uses, run in reverse), `encodePSMT8` below does both, inverting every
/// step `TextureParser.parse`'s `.psmt8` branch takes: `PSMT8Quantizer`
/// undoes `applyPalette`, `TextureParser.flip`/`TextureParser.swapPalette`
/// (both self-inverse, reused directly rather than reimplemented) undo the
/// post-read mirror and CSM1 interleave, and `EzSwizzle.writeTexPSMT8`/
/// `writeTexPSMCT32`/`readTexPSMCT32` undo the GS addressing round trip
/// `readTexPSMT8`/`decodePalette` did to decode it.
///
/// Every other GS format isn't attempted here, this build has no verified
/// encode for them, same "real, not guessed-at" posture as everywhere else
/// in this project.
public enum TextureWriter {
    public enum TextureWriteError: Error, LocalizedError {
        case unsupportedFormat(TexturePixelFormat)
        case sizeMismatch(expected: Int, actual: Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let format):
                return "Writing \(format.rawValue.uppercased()) textures back to disk isn't supported yet, only PSMCT32 and PSMT8 have a known, verified encode."
            case .sizeMismatch(let expected, let actual):
                return "Expected \(expected) byte(s) of pixel data, got \(actual), the replacement image must resample to the original texture's exact dimensions."
            }
        }
    }

    /// Every fixed field `TextureParser.parse`'s `.psmt8` branch needs but
    /// doesn't retain on `TextureAsset` itself, plus where the header ends
    ///, gathered by one function so `encodePSMT8` can invert that branch
    /// exactly, field for field, without a second copy of the read
    /// sequence drifting out of sync with the first.
    private struct FixedHeaderFields {
        let headerLength: Int
        let pixelDataLength: Int
        let width: Int
        let height: Int
        let textureBufferWidth: Int
        let clutBufferBasePointer: Int
        /// GS transfer-rectangle width/height, from the VIF setup block , 
        /// see `TextureParser.parse`'s own doc comment on `rrw`/`rrh`: the
        /// actual upload rectangle, which can differ from the logical
        /// `width`/`height` due to GS block-alignment padding, so this has
        /// to come from the real header, not be re-derived from
        /// `width`/`height`.
        let rrw: Int
        let rrh: Int
    }

    /// Replays `TextureParser.parse`'s exact fixed-field read sequence (texSize
    /// through the 96-byte VIF block, every field it reads but doesn't retain
    /// on `TextureAsset`) purely to find where the header ends and pixel data
    /// begins, and returns that cursor position. Deliberately not a hardcoded
    /// constant: this format's own `texSize` field excludes its own 4 bytes
    /// (so "pixel data starts at byte 224", `pixelDataLength = texSize - 224`
    /// in `TextureParser`, is relative to *that* convention, not to this
    /// record's true byte 0), and re-deriving the real offset by walking the
    /// same fields the parser does can't drift out of sync with it the way a
    /// second hardcoded number could.
    private static func fixedHeaderFields(of originalRecordBytes: Data) throws -> FixedHeaderFields {
        var cursor = BinaryCursor(data: originalRecordBytes)
        let texSize = Int(try cursor.readInt32())
        _ = try cursor.readInt32() // unkInt
        let wLog2 = try cursor.readInt16()
        let hLog2 = try cursor.readInt16()
        _ = try cursor.readUInt8() // m
        _ = try cursor.readUInt8() // format
        _ = try cursor.readUInt8() // destinationFormat
        _ = try cursor.readUInt8() // texColComponent
        _ = try cursor.readUInt8() // unkByte
        _ = try cursor.readUInt8() // textureFun
        _ = try cursor.readBytes(2) // unkBytes
        _ = try cursor.readInt32() // textureBasePointer
        for _ in 0..<6 { _ = try cursor.readInt32() } // mipLevelsTBP
        let textureBufferWidth = Int(try cursor.readInt32())
        for _ in 0..<6 { _ = try cursor.readInt32() } // mipLevelsTBW
        let clutBufferBasePointer = Int(try cursor.readInt32())
        _ = try cursor.readBytes(8) // unkBytes2
        _ = try cursor.readInt32() // reserved: vifCodeBlock index
        _ = try cursor.readInt32() // reserved: unknown pointer
        _ = try cursor.readBytes(2) // unkBytes3
        _ = try cursor.readBytes(2) // reserved
        _ = try cursor.readBytes(32) // unusedMetadata
        let vifBlock = try cursor.readBytes(96)

        var vifCursor = BinaryCursor(data: vifBlock)
        try vifCursor.skip(48)
        let rrw = Int(try vifCursor.readInt32())
        let rrh = Int(try vifCursor.readInt32())

        return FixedHeaderFields(
            headerLength: cursor.position,
            pixelDataLength: max(0, texSize - 224),
            width: 1 << Int(wLog2),
            height: 1 << Int(hLog2),
            textureBufferWidth: textureBufferWidth,
            clutBufferBasePointer: clutBufferBasePointer,
            rrw: rrw,
            rrh: rrh
        )
    }

    /// Inverse of `TextureParser.decodePSMCT32`: RGBA8 -> raw GS PSMCT32
    /// bytes. The decode widens GS's 7-bit alpha (0...128) to 8-bit
    /// (`<< 1`); this narrows it back (`>> 1`), an exact round trip for
    /// every alpha value the decode can itself produce.
    public static func encodePSMCT32(rgba: [UInt8]) -> Data {
        var out = [UInt8](repeating: 0, count: rgba.count)
        var i = 0
        while i + 3 < rgba.count {
            out[i] = rgba[i]
            out[i + 1] = rgba[i + 1]
            out[i + 2] = rgba[i + 2]
            out[i + 3] = UInt8(clamping: Int(rgba[i + 3]) >> 1)
            i += 4
        }
        return Data(out)
    }

    /// Inverse of `TextureParser.parse`'s `.psmt8` branch: RGBA8 -> raw,
    /// GS-block-swizzled on-disk bytes, palette included. Every step
    /// undoes the matching decode step, in reverse order:
    /// 1. `PSMT8Quantizer.quantize` reduces `rgba` to <=256 colors + one
    ///    index per pixel, the inverse of `applyPalette`.
    /// 2. `TextureParser.flip` (self-inverse) undoes the post-read mirror.
    /// 3. `EzSwizzle.writeTexPSMT8` writes the indices into simulated GS
    ///    memory using PSMT8 addressing, the inverse of `readTexPSMT8`.
    /// 4. The palette is padded to a full 256 entries, re-interleaved into
    ///    CSM1 storage order (`TextureParser.swapPalette`, self-inverse),
    ///    alpha narrowed back to GS's 7-bit range, and written into the
    ///    *same* simulated GS memory at `clutBufferBasePointer` via
    ///    `EzSwizzle.writeTexPSMCT32`, the inverse of `decodePalette`.
    ///    This works because the decode path never treated the index data
    ///    and the palette as separate buffers: both are just different
    ///    GS-address views into the one on-disk byte blob, and step 3/4
    ///    write into that same simulated memory for exactly that reason.
    /// 5. `EzSwizzle.readTexPSMCT32` reads the *combined* memory back out
    ///    using PSMCT32 addressing across the real `rrw`x`rrh` transfer
    ///    rectangle, the inverse of `writeTexPSMCT32`, and the actual
    ///    on-disk byte layout `TextureParser.parse` originally read via
    ///    `readBytes(pixelDataLength)`.
    private static func encodePSMT8(rgba: [UInt8], fields: FixedHeaderFields) -> Data {
        let (palette, indices) = PSMT8Quantizer.quantize(rgba: rgba, pixelCount: fields.width * fields.height)

        var flippedIndices = indices
        TextureParser.flip(&flippedIndices, width: fields.width, height: fields.height)

        let ez = EzSwizzle()
        ez.cleanGs()
        ez.writeTexPSMT8(dbp: 0, dbwIn: fields.textureBufferWidth, dsax: 0, dsay: 0, rrw: fields.width, rrh: fields.height, data: flippedIndices)

        var paletteForStorage = palette
        while paletteForStorage.count < 256 { paletteForStorage.append([0, 0, 0, 0]) }
        TextureParser.swapPalette(&paletteForStorage)
        var clutRaw = [UInt8](repeating: 0, count: 256 * 4)
        for (i, color) in paletteForStorage.enumerated() {
            clutRaw[i * 4] = color[0]
            clutRaw[i * 4 + 1] = color[1]
            clutRaw[i * 4 + 2] = color[2]
            clutRaw[i * 4 + 3] = UInt8(clamping: Int(color[3]) >> 1)
        }
        ez.writeTexPSMCT32(dbp: fields.clutBufferBasePointer, dbw: 1, dsax: 0, dsay: 0, rrw: 16, rrh: 16, data: clutRaw)

        var imageData = [UInt8](repeating: 0, count: fields.pixelDataLength)
        ez.readTexPSMCT32(dbp: 0, dbw: 1, dsax: 0, dsay: 0, rrw: fields.rrw, rrh: fields.rrh, into: &imageData)
        return Data(imageData)
    }

    /// Re-encodes `asset`'s current base-level `rgba` (mips aren't written
    /// back) into a full replacement for the original on-disk record:
    /// `originalRecordBytes`'s header bytes are copied verbatim, everything
    /// after is replaced with freshly encoded pixel data. Fails closed , 
    /// rather than silently truncating/padding, if `asset` isn't PSMCT32
    /// or PSMT8, or if the encoded pixel data isn't exactly the same
    /// length as what it's replacing, so this can never change a record's
    /// total size (this codebase's write paths never do).
    public static func replacingPixelData(of asset: TextureAsset, inOriginalRecordBytes originalRecordBytes: Data) throws -> Data {
        guard asset.pixelFormat == .psmct32 || asset.pixelFormat == .psmt8 else {
            throw TextureWriteError.unsupportedFormat(asset.pixelFormat)
        }
        let fields = try fixedHeaderFields(of: originalRecordBytes)
        guard originalRecordBytes.count >= fields.headerLength else {
            throw TextureWriteError.sizeMismatch(expected: fields.headerLength, actual: originalRecordBytes.count)
        }
        let expectedPixelLength = originalRecordBytes.count - fields.headerLength
        let encoded = asset.pixelFormat == .psmct32
            ? encodePSMCT32(rgba: asset.rgba)
            : encodePSMT8(rgba: asset.rgba, fields: fields)
        guard encoded.count == expectedPixelLength else {
            throw TextureWriteError.sizeMismatch(expected: expectedPixelLength, actual: encoded.count)
        }
        return originalRecordBytes.prefix(fields.headerLength) + encoded
    }
}
