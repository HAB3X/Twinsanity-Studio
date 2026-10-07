import Foundation

/// Chunk-kind discriminator, ported 1:1 from the original `SectionType` enum
/// (`Twinsanity/TwinsSection.cs`). This is *not* stored on disk, see the doc
/// comment on ``ChunkDispatch`` for why. Keeping the exact original ordering /
/// naming makes it trivial to cross-reference against the C# source and any
/// existing community documentation of the format.
public enum SectionType: String, Sendable, CaseIterable, Codable {
    case null
    case graphics, graphicsX, graphicsD, graphicsMB
    case code, codeDemo, codeX, codeMB
    case instance, instanceDemo, instanceMB
    case sceneryMB
    case particleData
    case unknown

    case texture, textureX, textureP
    case material, materialD
    case model, modelX, modelP
    case rigidModel
    case skin, skinX
    case blendSkin, blendSkinX
    case mesh
    case lodModel, lodModelMB
    case skydome

    case object, objectDemo, objectMB
    case script, scriptX, scriptDemo, scriptMB
    case animation
    case ogi, graphicsInfo, graphicsInfoMB, graphicsInfoP
    case customAgent, customAgentX, customAgentDemo
    case se, xboxSE, mbSE
    case seEng, xboxSEEng
    case seFre, xboxSEFre
    case seGer, xboxSEGer
    case seSpa, xboxSESpa
    case seIta, xboxSEIta
    case seJpn, xboxSEJpn

    case instanceTemplate, instanceTemplateDemo, instanceTemplateMB
    case aiPosition
    case aiPath
    case position
    case path
    case collisionSurface
    case objectInstance, objectInstanceDemo, objectInstanceMB
    case trigger
    case camera, cameraDemo
}

/// Which top-level container a `TwinsFile` was parsed as. Determines the
/// top-level sub-item ID -> section dispatch table (see `RM2Parser`/`SM2Parser`).
public enum TwinsFileKind: Sendable {
    case rm2
    case rm2Demo
    case rmx
    case rm2MB
    case sm2
    case sm2Demo
    case smx
    case sm2MB
}

/// A single index entry from a chunk header's index table: `TwinsSubInfo` in the
/// original source. Every `TwinsFile`/`TwinsSection` starts with:
/// ```
/// uint32 Magic          (0x00010001 or 0x00010003)
/// int32  RecordCount
/// uint32 ContentSize
/// ChunkIndexEntry[RecordCount]   // 12 bytes each
/// ```
public struct ChunkIndexEntry: Sendable, Equatable {
    /// Offset of this record's data. Absolute from file start at the top
    /// (`TwinsFile`) level; relative to the *enclosing section's* magic-number
    /// position for any nested `TwinsSection`.
    public var offset: UInt32
    public var size: Int32
    public var id: UInt32

    public init(offset: UInt32, size: Int32, id: UInt32) {
        self.offset = offset
        self.size = size
        self.id = id
    }
}

public enum TwinsChunkError: Error, CustomStringConvertible {
    case badMagic(found: UInt32, position: Int)
    case truncatedIndex(expectedCount: Int)
    case unsupportedFileType(String)

    public var description: String {
        switch self {
        case .badMagic(let found, let position):
            return String(format: "Chunk magic mismatch at byte %d: found 0x%08X, expected 0x00010001 or 0x00010003.", position, found)
        case .truncatedIndex(let expectedCount):
            return "Chunk index table is truncated; expected \(expectedCount) entries."
        case .unsupportedFileType(let name):
            return "Unsupported file type: \(name)."
        }
    }
}

public enum TwinsMagic {
    /// Standard chunk-section magic.
    public static let v1: UInt32 = 0x0001_0001
    /// Alternate magic accepted for nested sections in some records.
    public static let v2: UInt32 = 0x0001_0003
}
