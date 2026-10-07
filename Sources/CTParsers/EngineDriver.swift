import Foundation
import CTCore
import CTModels

/// Identifies one Traveller's Tales-era engine variant this build knows how to
/// read, and what it's capable of for that variant. Lives in `CTParsers`
/// (not `CTModels`, where it started) specifically so it can call the real
/// parsers directly, see `parseArchiveIndex`/`parseChunkFile` below, the
/// "isolate parsers behind the protocol" step that wasn't possible while
/// this type lived in a module `CTParsers` depends *on*, not the reverse.
///
/// Deliberately *not* shipped with here: drivers for Nu2-engine titles,
/// Haven: Call of the King, the early LEGO games, or Crash Nitro Kart. Their
/// chunk layouts, record formats, and endianness conventions would all have
/// to be reverse-engineered from scratch, this repository has no verified
/// reference source for any of them (compare `twinsanity-editor-master`,
/// which *is* a verified reference for Twinsanity itself, and is what every
/// parser in `CTParsers` is grounded in). A driver stubbed out against
/// guessed offsets wouldn't be "multi-engine support", it would silently
/// misparse or crash on real files while claiming to work. When a real
/// reference (community documentation, a decompiled binary, another OSS
/// tool) surfaces for one of those engines, it gets its own
/// `EngineDriver` conformance next to this one; until then, this stays a
/// two-entry registry on purpose.
public protocol EngineDriver: Sendable {
    /// Stable identifier, e.g. `"twinsanity"`, used for display and for
    /// any future per-driver settings/caching, never parsed from file data.
    var id: String { get }
    var displayName: String { get }
    /// Console platforms this driver has verified parsing for.
    var supportedPlatforms: [ConsolePlatform] { get }
    /// File extensions (uppercased, no dot) this driver's archive/level
    /// parsers recognize, e.g. `["RM2", "SM2", "RMX", "SMX"]`.
    var recognizedExtensions: Set<String> { get }
    /// The byte order this driver's structural fields are read as. See
    /// `Endianness`'s doc comment: Twinsanity's own PS2/Xbox split is a
    /// vertex/pixel-layout difference, not a byte-order one, but a future
    /// GameCube-era driver genuinely could differ here.
    var structuralEndianness: Endianness { get }
    /// What actually happens when a file this driver recognizes gets
    /// opened. `WorkspaceViewModel.open(url:)` branches on this instead of
    /// hardcoding a specific driver ID.
    var ingestionCapability: EngineDriverIngestionCapability { get }

    /// Parses a `.BH` archive index through *this* driver. Real dispatch,
    /// not a passthrough with nothing behind it: `WorkspaceViewModel` calls
    /// this instead of `BDArchiveParser.readIndex` directly, so a second
    /// `.mainWorkspaceTree` driver (should a real, verified one ever exist)
    /// only needs its own conformance here, no call-site changes anywhere
    /// else. Throws `EngineDriverError.unsupportedOperation` for a driver
    /// whose `ingestionCapability` isn't `.mainWorkspaceTree`, there's no
    /// archive-index concept for a driver whose files aren't chunk-headered.
    func parseArchiveIndex(bhURL: URL) throws -> ArchiveIndex

    /// Parses one chunk file's bytes through *this* driver, the
    /// `RM2Parser.parse` dispatch counterpart to `parseArchiveIndex`.
    func parseChunkFile(data: Data, fileKind: TwinsFileKind, fileName: String) throws -> ChunkNode
}

public enum EngineDriverError: Error, Equatable, LocalizedError {
    /// A driver whose `ingestionCapability` is `.standaloneOnly` has no
    /// main-tree parsing to dispatch to, asking it to anyway is a real
    /// programmer error at the call site, not a data problem, so this
    /// throws loudly rather than silently returning something empty.
    case unsupportedOperation(driverID: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let driverID):
            return "The \"\(driverID)\" driver doesn't ingest into the main workspace tree."
        }
    }
}

/// What `WorkspaceViewModel.open(url:)` should do with a file a given
/// `EngineDriver` recognizes.
public enum EngineDriverIngestionCapability: Sendable {
    /// This driver's files parse directly into the main sidebar/workspace
    /// tree via this driver's own `parseArchiveIndex`/`parseChunkFile`.
    case mainWorkspaceTree
    /// This driver's files are real and loadable, but only through their
    /// own dedicated panel, not because of an arbitrary restriction, but
    /// because they aren't chunk-headered `ChunkNode` data at all (see
    /// `WrathOfCortexEngineDriver`'s own doc comment), so there's no
    /// sidebar tree shape for them to become part of.
    case standaloneOnly(loadHint: String)
}

/// The primary driver this build has: real dispatch to `BDArchiveParser`/
/// `RM2Parser` (and, transitively through the `ChunkNode` tree those
/// produce, every leaf-record parser in `CTParsers`, `TextureParser`/
/// `TextureXParser`, `ModelParser`/`SkinParser`, `GraphicsInfoParser`/
/// `AnimationParser`, ...).
public struct TwinsanityEngineDriver: EngineDriver {
    public let id = "twinsanity"
    public let displayName = "Crash Twinsanity"
    public let supportedPlatforms: [ConsolePlatform] = [.ps2, .xbox]
    public let recognizedExtensions: Set<String> = ["RM2", "SM2", "RMX", "SMX"]
    public let structuralEndianness: Endianness = .little
    public let ingestionCapability: EngineDriverIngestionCapability = .mainWorkspaceTree

    public init() {}

    public func parseArchiveIndex(bhURL: URL) throws -> ArchiveIndex {
        try BDArchiveParser.readIndex(bhURL: bhURL)
    }

    public func parseChunkFile(data: Data, fileKind: TwinsFileKind, fileName: String) throws -> ChunkNode {
        try RM2Parser.parse(data: data, fileKind: fileKind, fileName: fileName)
    }
}

/// "Modular TT Engine Cross-Compatibility & Chunk Stitcher" (roadmap 5.3):
/// the second real driver, *Crash Twinsanity: The Wrath of Cortex*'s
/// `.CRT` (crate positions) and `.WMP` (Wumpa fruit positions) files,
/// backed by `WrathOfCortexParser`. Its `.CRT` decode is grounded in real
/// decompiled engine source (`OpenCrashWOC-main`'s `crate.c`) and
/// independently re-verified against real disc bytes, see
/// `WOCCrateFile`'s own doc comment for exactly what was checked. Scoped
/// honestly: `supportedPlatforms` is PS2 only, this source tree is a
/// GameCube alpha port, so field order/relationships are high confidence
/// but exact byte offsets for anything beyond `.CRT`/`.WMP` aren't
/// assumed to carry over untested.
///
/// Its own `.CRT`/`.WMP` parsing is real (`WrathOfCortexParser.
/// parseCrateFile`/`parseWumpaFile`, called directly from the Chunk
/// Viewer's "Cross-Engine Data" panel) but isn't `ChunkNode`-based, so
/// there's no `parseArchiveIndex`/`parseChunkFile` dispatch to offer here , 
/// both throw rather than pretend to a main-tree ingestion path that
/// doesn't exist for this format. Building "entities, models, and terrain
/// chunks... converted, re-indexed, and stitched" beyond that would need a
/// decoded WoC model/terrain/entity format this codebase has never had , 
/// only crate/wumpa *positions* are verified, so that's not attempted
/// here either.
public struct WrathOfCortexEngineDriver: EngineDriver {
    public let id = "wrath-of-cortex"
    public let displayName = "Crash Twinsanity: The Wrath of Cortex"
    public let supportedPlatforms: [ConsolePlatform] = [.ps2]
    public let recognizedExtensions: Set<String> = ["CRT", "WMP"]
    public let structuralEndianness: Endianness = .little
    public let ingestionCapability: EngineDriverIngestionCapability = .standaloneOnly(
        loadHint: "open a Chunk Viewer and use its \"Cross-Engine Data\" panel's \"Load Wrath of Cortex File…\" button instead."
    )

    public init() {}

    public func parseArchiveIndex(bhURL: URL) throws -> ArchiveIndex {
        throw EngineDriverError.unsupportedOperation(driverID: id)
    }

    public func parseChunkFile(data: Data, fileKind: TwinsFileKind, fileName: String) throws -> ChunkNode {
        throw EngineDriverError.unsupportedOperation(driverID: id)
    }
}

/// Every engine driver this build ships. See `EngineDriver`'s doc comment
/// for why an entry only ever gets added here once a real, verified format
/// spec exists, never a guess dressed up as support.
public enum EngineDriverRegistry {
    public static let all: [any EngineDriver] = [TwinsanityEngineDriver(), WrathOfCortexEngineDriver()]

    public static func driver(forExtension ext: String) -> (any EngineDriver)? {
        let upper = ext.uppercased()
        return all.first { $0.recognizedExtensions.contains(upper) }
    }
}
