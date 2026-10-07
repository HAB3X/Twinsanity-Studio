import Foundation
import CoreGraphics
import CTCore
import CTModels

/// This app's own flat container format for stashing a fully decoded
/// `TextureAsset` (arbitrary width/height/pixel format/RGBA bytes) inside a
/// real CrateModLoader `.crate`'s `modassets/` folder (see `CrateExporter.
/// export`'s `modAssets` parameter, and `ModLoaderGlobals.
/// ModAssetsFolderName`, verified real, lowercase folder name, for what
/// that folder itself is).
///
/// This is deliberately **not** an attempt at the real on-disk PS2 GS
/// texture record format (`TextureParser`/`TextureWriter`'s own PSMCT32/
/// PSMT8 layout, GS block-swizzling, CLUT palette, a header carrying
/// fields like `textureBufferWidth`/`clutBufferBasePointer`). Building one
/// of those requires the *target* record's own original header bytes
/// (`TextureWriter`'s private `fixedHeaderFields(of:)`), which simply don't
/// exist for a texture that's only ever lived as a decoded, in-memory
/// `TextureAsset`, e.g. a real Wrath of Cortex texture, already decoded by
/// `WOCTextureDecoder` from an entirely different engine's own on-disk
/// format before it ever reaches this file (see `ResolvedModelAsset.
/// applyingTextureOverride`'s own doc comment for the "Cross-Engine Texture
/// Variant" feature this exists to support). CrateModLoader's own real
/// precedent for a bundled external-resource asset
/// (`CrateModAPI/ModProperties/ModProp_TextureFile.cs`) doesn't store a raw
/// GS record either, it hands the *decoded* `Bitmap` to `ResourceToFile`,
/// which saves a `.png`; this format follows that same "store the decoded
/// image, not a target-specific on-disk record" idea, just as a flat custom
/// container instead of PNG (a lossless straight-RGBA round trip needs no
/// compression, and every field `TextureAsset` actually carries, including
/// its own `pixelFormat` label, round-trips exactly, which a plain PNG
/// wouldn't preserve on its own).
///
/// Layout (all multi-byte fields little-endian, via `BinaryWriter`/
/// `BinaryCursor`, same convention every other binary format in this
/// codebase uses):
/// ```
/// "TSTX"             4 bytes  magic
/// version            1 byte   currently 1
/// width              4 bytes  UInt32
/// height             4 bytes  UInt32
/// pixelFormatLength  1 byte   UInt8 (UTF-8 byte count of the name below)
/// pixelFormatName    N bytes  UTF-8, e.g. "psmt8" (TexturePixelFormat.rawValue)
/// rgbaLength         4 bytes  UInt32
/// rgbaBytes          N bytes  straight (non-premultiplied) RGBA8, top-row-first
/// ```
/// Mips aren't carried, a texture override only ever needs to replace the
/// base level a submesh actually samples for preview/install, and
/// `applyingTextureOverride` itself never touches mips either.
public enum ModAssetTexture {
    private static let magic: [UInt8] = Array("TSTX".utf8)
    private static let formatVersion: UInt8 = 1

    public enum DecodeError: Error, LocalizedError {
        case truncated
        case badMagic
        case unsupportedVersion(UInt8)
        case unknownPixelFormat(String)
        case rgbaLengthMismatch(expected: Int, actual: Int)

        public var errorDescription: String? {
            switch self {
            case .truncated: return "This ModAssets texture file is truncated, fewer bytes than its own header fields require."
            case .badMagic: return "This isn't a ModAssets texture file (missing the \"TSTX\" magic)."
            case .unsupportedVersion(let v): return "This ModAssets texture file is version \(v), which this build doesn't understand (only version 1 is supported)."
            case .unknownPixelFormat(let name): return "This ModAssets texture file declares pixel format \"\(name)\", which this build doesn't recognize."
            case .rgbaLengthMismatch(let expected, let actual): return "This ModAssets texture file's declared width/height implies \(expected) RGBA byte(s), but it actually carries \(actual)."
            }
        }
    }

    /// Encodes `texture` into this format's real byte layout (see this
    /// type's own doc comment).
    public static func serialize(_ texture: TextureAsset) -> Data {
        var writer = BinaryWriter()
        writer.writeBytes(magic)
        writer.writeUInt8(formatVersion)
        writer.writeUInt32(UInt32(texture.width))
        writer.writeUInt32(UInt32(texture.height))
        let formatNameBytes = Array(texture.pixelFormat.rawValue.utf8)
        writer.writeUInt8(UInt8(formatNameBytes.count))
        writer.writeBytes(formatNameBytes)
        writer.writeUInt32(UInt32(texture.rgba.count))
        writer.writeBytes(texture.rgba)
        return writer.data
    }

    /// Decodes this format's real byte layout back into a `TextureAsset`.
    /// `id` isn't part of the on-disk format (a bundled override texture
    /// has no meaningful record ID of its own, the *target* texture's ID
    /// is what the crate's settings key already names), so the returned
    /// asset's `id` is always `0`; callers that need a specific ID (e.g.
    /// to match it against the record being overridden) should build a
    /// fresh `TextureAsset` copying this one's `width`/`height`/
    /// `pixelFormat`/`rgba` with the ID they actually need.
    public static func deserialize(_ data: Data) throws -> TextureAsset {
        var cursor = BinaryCursor(data: data)
        let readMagic = try cursor.readBytes(magic.count)
        guard [UInt8](readMagic) == magic else { throw DecodeError.badMagic }
        let version = try cursor.readUInt8()
        guard version == formatVersion else { throw DecodeError.unsupportedVersion(version) }
        let width = Int(try cursor.readUInt32())
        let height = Int(try cursor.readUInt32())
        let formatNameLength = Int(try cursor.readUInt8())
        let formatName = try cursor.readASCIIString(length: formatNameLength)
        guard let pixelFormat = TexturePixelFormat(rawValue: formatName) else {
            throw DecodeError.unknownPixelFormat(formatName)
        }
        let rgbaLength = Int(try cursor.readUInt32())
        let rgba = [UInt8](try cursor.readBytes(rgbaLength))
        guard rgba.count == width * height * 4 else {
            throw DecodeError.rgbaLengthMismatch(expected: width * height * 4, actual: rgba.count)
        }
        return TextureAsset(id: 0, width: width, height: height, pixelFormat: pixelFormat, rgba: rgba)
    }

    /// Resamples `texture`'s base-level RGBA to exactly `width` x `height`
    ///, needed because the on-disk GS record this format's decoded output
    /// eventually gets re-encoded into (`TextureWriter.replacingPixelData`)
    /// can't change size, but a bundled override texture (e.g. a real WoC
    /// texture, decoded at whatever resolution *that* engine's own asset
    /// happened to be) has no reason to already match the *target*
    /// Twinsanity texture's own dimensions.
    ///
    /// Draws through a real `CGContext`, the same "resample via Core
    /// Graphics" technique `TextureUpscaler`/`TextureInspectorView`'s own
    /// "Replace with Image…" already use for this exact problem (resampling
    /// an arbitrary source image to an exact target size), reused here
    /// rather than a second, independent scaling implementation.
    /// `CGContext` only supports premultiplied alpha for an 8bpc RGBA
    /// destination, so this un-premultiplies the drawn result back to the
    /// straight alpha `TextureAsset.rgba` itself promises (see its own doc
    /// comment) before returning it. Returns `texture.rgba` unchanged (already
    /// the right size, or CoreGraphics failed closed) when nothing needs to move.
    public static func resizedRGBA(_ texture: TextureAsset, toWidth width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0 else { return texture.rgba }
        guard texture.width != width || texture.height != height else { return texture.rgba }
        guard let sourceImage = try? TextureExporter.cgImage(from: texture) else { return texture.rgba }

        // A raw, explicitly-owned allocation rather than backing the
        // context with a Swift array's own storage: `CGContext(data:)`
        // holds and writes through that pointer for the context's entire
        // lifetime (every `draw` call, not just this one), which a
        // `withUnsafeMutableBytes` closure's pointer can't safely outlive.
        let byteCount = width * height * 4
        let rawBuffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<UInt8>.alignment)
        defer { rawBuffer.deallocate() }
        rawBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: rawBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return texture.rgba }
        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var buffer = [UInt8](UnsafeRawBufferPointer(start: rawBuffer, count: byteCount))
        var i = 0
        while i + 3 < buffer.count {
            let a = Int(buffer[i + 3])
            if a > 0, a < 255 {
                buffer[i] = UInt8(clamping: (Int(buffer[i]) * 255) / a)
                buffer[i + 1] = UInt8(clamping: (Int(buffer[i + 1]) * 255) / a)
                buffer[i + 2] = UInt8(clamping: (Int(buffer[i + 2]) * 255) / a)
            }
            i += 4
        }
        return buffer
    }
}
