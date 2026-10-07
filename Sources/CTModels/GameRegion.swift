import Foundation

/// "Multi-Region & Cross-Game Auto-Patcher" (roadmap 1.4), a real PS2
/// disc's distribution region, detected from real on-disc metadata
/// (`SystemCNFParser`), never guessed from a filename or assumed. Uses
/// Sony's own regional serial-prefix convention (SCUS/SLUS = North
/// America, SCES/SLES = Europe, SCPS/SLPS/SLPM/SCAJ = Japan), standard,
/// publisher-agnostic PS2 industry knowledge documented across the
/// PS2 homebrew/emulation community (e.g. how PCSX2 itself identifies a
/// disc), not anything specific to, or guessed about, Twinsanity.
public enum GameRegion: String, Sendable, CaseIterable, Codable {
    case ntscU = "NTSC-U"
    case pal = "PAL"
    case ntscJ = "NTSC-J"
    case unknown = "Unknown"

    public var displayName: String { rawValue }
}

/// The real, standard fields `SYSTEM.CNF` (every PS2 disc's boot
/// descriptor, at the ISO root) carries, plus the `GameRegion` resolved
/// from them. `serial`/`videoMode`/`bootPath` are `nil` only when
/// `SYSTEM.CNF` itself didn't contain that real line, never a fabricated
/// placeholder standing in for missing data.
public struct SystemCNFInfo: Sendable, Equatable, Codable {
    public let bootPath: String?
    public let serial: String?
    public let videoMode: String?
    public let region: GameRegion

    public init(bootPath: String?, serial: String?, videoMode: String?, region: GameRegion) {
        self.bootPath = bootPath
        self.serial = serial
        self.videoMode = videoMode
        self.region = region
    }
}

/// Whether this build's existing parsers (`TwinsanityEngineDriver` and
/// friends) have any *known, verified* reason to need region-specific
/// adjustment for a given `GameRegion`. As of this build: none. Every
/// parser in `CTParsers` reads a plain, unconditional little-endian
/// stream (see `Endianness`'s own doc comment) with no region branch
/// anywhere, nothing in this codebase's real, tested history (against
/// the one real disc this project has ever verified against) has ever
/// shown RM2/SM2/BD/BH structure to differ by region. So this registry
/// doesn't ship a byte-offset patch table for any region, there's
/// nothing confirmed to patch. What it *does* give the rest of the app is
/// an honest place to hang a real fix if one is ever actually found and
/// verified (mirroring `EngineDriver`'s own "only add an entry once
/// there's a real, verified reason" rule), and a straight answer to "has
/// this build actually been checked against this specific region" rather
/// than a silent assumption either way.
public enum RegionCompatibilityRegistry {
    /// `true` for every region today, for the reason in this type's own
    /// doc comment: no confirmed region-specific structural difference
    /// exists to gate on. This is a statement of "nothing's known to be
    /// broken," not "this has been tested against a real disc of every
    /// region", only whichever single disc this project's own
    /// disc-gated tests run against has ever actually been checked.
    public static func hasNoKnownStructuralDifferences(for region: GameRegion) -> Bool {
        true
    }
}
