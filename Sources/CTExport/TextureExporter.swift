import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CTModels

public enum TextureExportError: Error, CustomStringConvertible {
    case imageCreationFailed
    case destinationCreationFailed(URL)
    case writeFailed(URL)
    case invalidMipLevel(Int)

    public var description: String {
        switch self {
        case .imageCreationFailed: return "Could not create a CGImage from the decoded texture data."
        case .destinationCreationFailed(let url): return "Could not create a PNG destination at \(url.path)."
        case .writeFailed(let url): return "Failed to write PNG data to \(url.path)."
        case .invalidMipLevel(let level): return "Texture has no mip level \(level)."
        }
    }
}

/// Converts decoded ``TextureAsset`` pixel data to `CGImage`/PNG, and one
/// click exports every mip level alongside the base texture.
public enum TextureExporter {
    /// Builds a `CGImage` for the base level or, if `mipLevel` is given, for
    /// that mip. `TextureAsset.rgba`/`.mips` are already straight-alpha,
    /// top-row-first RGBA8, a direct, no-copy `CGDataProvider` wrap.
    public static func cgImage(from asset: TextureAsset, mipLevel: Int? = nil) throws -> CGImage {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        if let mipLevel {
            guard mipLevel >= 0, mipLevel < asset.mips.count else {
                throw TextureExportError.invalidMipLevel(mipLevel)
            }
            pixels = asset.mips[mipLevel]
            let divisor = 1 << (mipLevel + 1)
            width = max(1, asset.width / divisor)
            height = max(1, asset.height / divisor)
        } else {
            pixels = asset.rgba
            width = asset.width
            height = asset.height
        }

        guard width > 0, height > 0, pixels.count >= width * height * 4 else {
            throw TextureExportError.imageCreationFailed
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            throw TextureExportError.imageCreationFailed
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw TextureExportError.imageCreationFailed
        }
        return image
    }

    /// Exports the base texture to `url` as PNG.
    public static func exportPNG(_ asset: TextureAsset, to url: URL) throws {
        try writePNG(cgImage(from: asset), to: url)
    }

    /// Same base-texture PNG encoding `exportPNG` writes to disk, returned
    /// as in-memory `Data` instead, used by callers (like "Export with
    /// Dependencies") that bundle it alongside other in-memory files rather
    /// than writing a loose file to a folder.
    public static func pngData(_ asset: TextureAsset) throws -> Data {
        try pngData(cgImage(from: asset))
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw TextureExportError.imageCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TextureExportError.imageCreationFailed
        }
        return data as Data
    }

    /// One-click export: base texture + every mip level, named
    /// `<baseName>.png`, `<baseName>_mip1.png`, `<baseName>_mip2.png`, ...
    /// into `directory`.
    @discardableResult
    public static func exportAllLevels(_ asset: TextureAsset, baseName: String, to directory: URL) throws -> [URL] {
        var written: [URL] = []
        let baseURL = directory.appendingPathComponent(baseName).appendingPathExtension("png")
        try exportPNG(asset, to: baseURL)
        written.append(baseURL)

        for level in asset.mips.indices {
            let mipURL = directory.appendingPathComponent("\(baseName)_mip\(level + 1)").appendingPathExtension("png")
            try writePNG(try cgImage(from: asset, mipLevel: level), to: mipURL)
            written.append(mipURL)
        }
        return written
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw TextureExportError.destinationCreationFailed(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TextureExportError.writeFailed(url)
        }
    }
}
