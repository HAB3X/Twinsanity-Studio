import Foundation

/// "Play As", a real, verified alternate playable character, ready to
/// replace whichever character currently occupies `GameObject` id 0 (the
/// engine's own reserved Player-1 slot, see `CrossFileGameObjectCopier.
/// resolvingPlayerCharacterReplacement`'s own doc comment for the real disc
/// evidence behind that). Each entry here isn't just "a character with this
/// name", it's a specific, real disc file this build confirmed carries
/// that character's own *rich*, genuinely-playable rig (many real OGI
/// variants, real scripts, real animations, a populated `linkedIDs`
/// dependency manifest), as opposed to a thin generic-NPC cameo of the same
/// character elsewhere on the disc. Picking the wrong source file (a
/// cameo instead of the real rig) is exactly what left an earlier attempt
/// at this feature fully rendered but completely inert.
public struct PlayableCharacterOption: Sendable, Identifiable, Hashable {
    public let id: UInt16
    public let displayName: String
    /// Bare filename (no path) of the real disc file this build found
    /// carrying this character's own rich, playable `GameObject`, resolved
    /// against the mounted disc's archive index at apply time, the same way
    /// every other cross-level source in this app already is.
    public let sourceFileBaseName: String

    public init(id: UInt16, displayName: String, sourceFileBaseName: String) {
        self.id = id
        self.displayName = displayName
        self.sourceFileBaseName = sourceFileBaseName
    }

    /// The default, no replacement, the level's own original character
    /// stays exactly as it is. Not a real disc source (never resolved).
    public static let crash = PlayableCharacterOption(id: 0, displayName: "Crash (Default)", sourceFileBaseName: "")

    /// `|L10chasB|act_CORTEX` in `l10chasb.rm2`, a real 2-player co-op
    /// level where Cortex is genuinely playable: 89 non-sentinel `ogiIDs`,
    /// 61 real scripts, 85 real animations (vs. a generic NPC Cortex
    /// elsewhere on the disc, which carries just 1/111/103 mostly-sentinel
    /// slots of the same fields), confirmed by direct comparison against
    /// real disc data this session.
    ///
    /// This rig's own real skin + both `modelLinks` genuinely render with a
    /// peaked cap, a dark hood/balaclava covering the whole head, and a
    /// striped collar over an "N"-monogrammed top, confirmed by rendering
    /// real animation frames offscreen (`ModelViewerRenderer.
    /// renderOffscreen`, see `SkinParser.applyGeometricNormals`'s doc
    /// comment for why that render only became legible once real per-vertex
    /// normals existed to shade it by) and inspecting the actual texture
    /// data (one real, shared 128×128 `AC1_lambert11` material across the
    /// skin body and both modelLinks, a genuine art-side shared atlas, not
    /// a resolution bug: `materialID`→`textureID` resolution in
    /// `AssetResolver` correctly reflects what this file's own Material
    /// records say). In short: "no face" on this specific source rig is
    /// real, intentional AltEarth/RockSlide chase-level disguise costume
    /// data (a hood), not a decode/render bug, don't re-chase it as one.
    public static let cortex = PlayableCharacterOption(id: 74, displayName: "Cortex", sourceFileBaseName: "l10chasb.rm2")

    /// `act_NINA`, confirmed identical (51 non-sentinel `ogiIDs`, 39
    /// scripts, 48 animations, real `linkedIDs`) across every one of her
    /// own real playable appearances found this session (the School
    /// Rooftop bus-chase sequence and its neighboring rooms, plus the
    /// AltEarth Core levels), `buschase.rm2` picked as the canonical
    /// source since it's the sequence she's actually driven by the player
    /// in, not a cutscene-only room.
    public static let nina = PlayableCharacterOption(id: 347, displayName: "Nina", sourceFileBaseName: "buschase.rm2")

    /// Every option, in menu order, `crash` first as the always-available
    /// "no swap" default.
    public static let all: [PlayableCharacterOption] = [.crash, .cortex, .nina]
}
