import Foundation

/// GS pixel-storage format (`Texture.TexturePixelFormat` in the original tool),
/// plus the Xbox DXT variants which live in a parallel `TextureX` record.
public enum TexturePixelFormat: String, Sendable, CaseIterable, Codable {
    case psmct32, psmct24, psmct16, psmct16s
    case psmt8, psmt4, psmt8h, psmt4hl, psmt4hh
    case psmz32, psmz24, psmz16, psmz16s
    case dxt1, dxt3, dxt5
    case rawRGBA
    case unknown

    /// The original tool only fully decodes PSMCT32 and PSMT8 (everything else
    /// falls through to a raw byte passthrough); DXT1/3/5 are Xbox-only and are
    /// fully decoded there. This mirrors that support matrix.
    public var isFullyDecoded: Bool {
        switch self {
        case .psmct32, .psmt8, .dxt1, .dxt3, .dxt5, .rawRGBA: return true
        default: return false
        }
    }
}

/// A fully decoded texture, ready for `CGImage`/`NSImage` presentation. `rgba`
/// is tightly packed, top-row-first, straight (non-premultiplied) alpha,
/// `width * height * 4` bytes.
public struct TextureAsset: Sendable, Identifiable, Codable {
    public let id: UInt32
    public var width: Int
    public var height: Int
    public var pixelFormat: TexturePixelFormat
    public var rgba: [UInt8]
    /// Successively half-sized mip levels, same pixel layout as `rgba`.
    public var mips: [[UInt8]]

    public init(id: UInt32, width: Int, height: Int, pixelFormat: TexturePixelFormat, rgba: [UInt8], mips: [[UInt8]] = []) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.rgba = rgba
        self.mips = mips
    }

    private enum CodingKeys: String, CodingKey {
        case id, width, height, pixelFormat, rgba, mips
    }

    /// Custom `Codable` rather than the synthesized one: Foundation encodes
    /// a plain `[UInt8]` element-by-element (each byte boxed individually),
    /// which for a full texture (hundreds of KB) is orders of magnitude
    /// slower than encoding the same bytes as `Data`, measured at ~1600x
    /// on a representative texture set. `ScanCache`'s per-archive save
    /// round-trips every texture in the Textures Hub through
    /// `PropertyListEncoder`, so this was turning a real full-disc scan
    /// (hundreds of textures) into a multi-minute encode, well past what
    /// looked like "the scan is just slow." The wire format is otherwise
    /// unchanged in shape (still bytes in, bytes out), only the
    /// intermediate container type changes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt32.self, forKey: .id)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        pixelFormat = try container.decode(TexturePixelFormat.self, forKey: .pixelFormat)
        rgba = [UInt8](try container.decode(Data.self, forKey: .rgba))
        mips = try container.decode([Data].self, forKey: .mips).map { [UInt8]($0) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(pixelFormat, forKey: .pixelFormat)
        try container.encode(Data(rgba), forKey: .rgba)
        try container.encode(mips.map { Data($0) }, forKey: .mips)
    }
}
