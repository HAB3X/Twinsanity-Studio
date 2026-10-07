import Foundation
import CTCore
import CTModels

/// "Parity Phase L": write-back for the Xbox `TextureX` "raw uncompressed"
/// case (`textureType == 0` in `TextureXParser`), the DXT5 case
/// (`textureType != 0`) isn't attempted here, same "re-compressing to a
/// block-compressed format is real, separate work this build doesn't guess
/// at" reasoning `TextureWriter`'s own doc comment already gives for
/// PSMT8's GS-swizzled + palette-quantized case.
public enum TextureXWriter {
    public enum TextureXWriteError: Error, LocalizedError {
        case notRawFormat
        case sizeMismatch(expected: Int, actual: Int)

        public var errorDescription: String? {
            switch self {
            case .notRawFormat:
                return "Writing DXT5 TextureX records back to disk isn't supported yet, only the raw-uncompressed variant has a known, verified encode."
            case .sizeMismatch(let expected, let actual):
                return "Expected \(expected) byte(s) of pixel data, got \(actual), the replacement image must resample to the original texture's exact dimensions."
            }
        }
    }

    /// Replays `TextureXParser.parse`'s fixed-field reads through
    /// `textureType` (the last field before pixel data for the raw case) , 
    /// same "re-derive by walking the real reads, don't hardcode a byte
    /// count" reasoning as `TextureWriter.headerLength`. Also returns
    /// `unkBytes2` (needed to know whether the parser's own trailing-
    /// padding skip applies) so callers don't have to re-read it separately.
    private static func headerLengthAndUnkBytes2(of originalRecordBytes: Data) throws -> (headerLength: Int, unkBytes2: [UInt8]) {
        var cursor = BinaryCursor(data: originalRecordBytes)
        _ = try cursor.readInt32() // texSize
        _ = try cursor.readInt32() // unkInt
        _ = try cursor.readInt16() // wLog2
        _ = try cursor.readInt16() // hLog2
        _ = try cursor.readUInt8() // m
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
        _ = try cursor.readUInt32() // textureType
        return (cursor.position, unkBytes2)
    }

    /// Inverse of `TextureXParser`'s raw-pixel decode loop: RGBA8
    /// (`TextureAsset.rgba`'s documented top-down layout) -> on-disk
    /// bottom-up rows of `B, G, R, A` bytes.
    public static func encodeRaw(rgba: [UInt8], width: Int, height: Int) -> Data {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var outIndex = 0
        for y in stride(from: height - 1, through: 0, by: -1) {
            let rowStart = width * y
            for x in 0..<width {
                let src = (rowStart + x) * 4
                out[outIndex] = rgba[src + 2]     // B
                out[outIndex + 1] = rgba[src + 1] // G
                out[outIndex + 2] = rgba[src]     // R
                out[outIndex + 3] = rgba[src + 3] // A
                outIndex += 4
            }
        }
        return Data(out)
    }

    /// Re-encodes `asset`'s current `rgba` into a full replacement for the
    /// original on-disk record. Any bytes after the pixel region (the
    /// parser's own "trailing padding quirk," gated on `unkBytes2[4] !=
    /// 0x84`) are copied verbatim rather than regenerated, so this doesn't
    /// need to reproduce that quirk's exact logic to stay byte-exact for
    /// everything this build doesn't intentionally change.
    public static func replacingPixelData(of asset: TextureAsset, inOriginalRecordBytes originalRecordBytes: Data) throws -> Data {
        guard asset.pixelFormat == .rawRGBA else {
            throw TextureXWriteError.notRawFormat
        }
        let (headerLength, _) = try headerLengthAndUnkBytes2(of: originalRecordBytes)
        let pixelDataLength = asset.width * asset.height * 4
        guard originalRecordBytes.count >= headerLength + pixelDataLength else {
            throw TextureXWriteError.sizeMismatch(expected: headerLength + pixelDataLength, actual: originalRecordBytes.count)
        }
        let encoded = encodeRaw(rgba: asset.rgba, width: asset.width, height: asset.height)
        guard encoded.count == pixelDataLength else {
            throw TextureXWriteError.sizeMismatch(expected: pixelDataLength, actual: encoded.count)
        }
        return originalRecordBytes.prefix(headerLength) + encoded + originalRecordBytes.suffix(from: headerLength + pixelDataLength)
    }
}
