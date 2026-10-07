import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import CTModels

public enum TextureAtlasError: Error, LocalizedError, Equatable {
    case noTextures
    case compositingFailed
    case writeFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .noTextures: return "No textures to pack."
        case .compositingFailed: return "Couldn't composite the atlas image."
        case .writeFailed(let url): return "Failed to write the atlas PNG to \(url.path)."
        }
    }
}

/// One source texture's real placement inside the packed atlas, in pixel
/// coordinates (origin top-left, matching this codebase's existing
/// texture/UV convention, same as `TextureExporter`'s PNG output).
public struct AtlasPlacement: Sendable {
    public let textureID: UInt32
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    /// This placement in normalized 0...1 UV space. A vertex whose
    /// original UV was `(u, v)` against this texture alone remaps to
    /// `origin + (u, v) * size` against the atlas as a whole, the actual
    /// "recalculates the UV coordinates for all corresponding 3D models"
    /// step the roadmap describes, left to the caller to apply against
    /// whichever mesh(es) reference this texture (this type has no
    /// mesh/submesh association of its own to do that automatically).
    public func normalizedUVRect(atlasWidth: Int, atlasHeight: Int) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        (
            SIMD2(Float(x) / Float(atlasWidth), Float(y) / Float(atlasHeight)),
            SIMD2(Float(width) / Float(atlasWidth), Float(height) / Float(atlasHeight))
        )
    }
}

/// "Offline Texture Atlas Packer" (roadmap 12.3): packs multiple decoded
/// textures into one larger atlas image, so a mod carrying many small UI/
/// texture files doesn't blow past the PS2's strict 4MB VRAM budget one
/// separately-padded texture at a time (every individual `MTLTexture`/GS
/// texture allocation rounds up to its own alignment; packing eliminates
/// that per-texture overhead and the draw-call/state-change cost of
/// binding dozens of tiny separate textures).
///
/// Uses a standard shelf-packing algorithm (sort tallest-first, fill each
/// row left-to-right until it doesn't fit, start a new row below), a
/// well-understood, textbook bin-packing approach, not anything specific
/// to Crash Twinsanity's own formats. Not guaranteed optimal (true
/// bin-packing is NP-hard; shelf packing is the standard practical
/// approximation every real texture-atlas tool uses), but always
/// correct, no overlaps, every texture placed.
public enum TextureAtlasPacker {
    /// Computes where every texture lands, no image data touched, so this
    /// can run purely to preview a layout before committing to rendering
    /// the (potentially large) composited image.
    public static func pack(_ textures: [TextureAsset], maxWidth: Int = 2048) -> (atlasWidth: Int, atlasHeight: Int, placements: [AtlasPlacement]) {
        guard !textures.isEmpty else { return (0, 0, []) }
        let sorted = textures.sorted { $0.height > $1.height }

        var placements: [AtlasPlacement] = []
        var shelfY = 0
        var shelfHeight = 0
        var cursorX = 0
        var atlasWidth = 0

        for texture in sorted {
            if cursorX > 0, cursorX + texture.width > maxWidth {
                shelfY += shelfHeight
                cursorX = 0
                shelfHeight = 0
            }
            placements.append(AtlasPlacement(textureID: texture.id, x: cursorX, y: shelfY, width: texture.width, height: texture.height))
            cursorX += texture.width
            atlasWidth = max(atlasWidth, cursorX)
            shelfHeight = max(shelfHeight, texture.height)
        }

        return (atlasWidth, shelfY + shelfHeight, placements)
    }

    /// Composites the real decoded pixels of every texture into one
    /// `CGImage` at the layout `pack` computed.
    public static func renderAtlas(_ textures: [TextureAsset], placements: [AtlasPlacement], atlasWidth: Int, atlasHeight: Int) throws -> CGImage {
        guard atlasWidth > 0, atlasHeight > 0 else { throw TextureAtlasError.noTextures }
        guard let context = CGContext(
            data: nil, width: atlasWidth, height: atlasHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TextureAtlasError.compositingFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: atlasWidth, height: atlasHeight))

        let textureByID = Dictionary(uniqueKeysWithValues: textures.map { ($0.id, $0) })
        for placement in placements {
            guard let texture = textureByID[placement.textureID], let cgImage = try? TextureExporter.cgImage(from: texture) else { continue }
            // CGContext's origin is bottom-left; `placements` are computed
            // top-left (image/UV convention), so the Y needs flipping.
            let flippedY = atlasHeight - placement.y - placement.height
            context.draw(cgImage, in: CGRect(x: placement.x, y: flippedY, width: placement.width, height: placement.height))
        }

        guard let result = context.makeImage() else { throw TextureAtlasError.compositingFailed }
        return result
    }

    /// Packs, composites, and writes the atlas PNG to `url` in one call , 
    /// the placements are still returned so a caller can remap UVs or just
    /// show the layout, even though the pixels are already on disk.
    @discardableResult
    public static func exportAtlas(_ textures: [TextureAsset], to url: URL, maxWidth: Int = 2048) throws -> (atlasWidth: Int, atlasHeight: Int, placements: [AtlasPlacement]) {
        guard !textures.isEmpty else { throw TextureAtlasError.noTextures }
        let layout = pack(textures, maxWidth: maxWidth)
        let image = try renderAtlas(textures, placements: layout.placements, atlasWidth: layout.atlasWidth, atlasHeight: layout.atlasHeight)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw TextureAtlasError.writeFailed(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TextureAtlasError.writeFailed(url)
        }
        return layout
    }
}
