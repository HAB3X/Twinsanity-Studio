import Foundation
import simd

/// "Cross-Engine Chunk Stitcher" (roadmap 5.3): real, decoded data from
/// *Crash Twinsanity: The Wrath of Cortex*, a different TT-engine game
/// with an entirely different on-disk format from this build's own
/// `.RM2`/`.SM2`/`.BH`/`.BD`.
///
/// **Real source, real verification** (this replaces an earlier version
/// ported from CrateModLoader's community `TWOC_File_CRT.cs`, which was
/// explicitly never checked against real WoC bytes since no WoC disc was
/// available at the time): `OpenCrashWOC-main/code/src/gamecode/crate.c`'s
/// `ReadCrateData` (a real decompiled/DWARF-cross-checked source for this
/// exact engine) gives a completely different structure than the ported
/// version had -- re-verified directly against real bytes before being
/// trusted, not just adopted from source: `WESTERN.CRT` (86 groups, 211
/// crates) and `VOLCANO.CRT` (real second sample) both decode with **zero
/// leftover bytes** (the whole file consumes exactly) and **zero
/// implausible values** (every position finite and in-range) end to end.
/// Real structural corroboration beyond just "it parses": every group's
/// own `origin` exactly equals its first crate's own `position` (the
/// natural relationship for an anchor point), multi-crate groups show
/// small, sensible position deltas between consecutive crates (real
/// stacking/placement patterns), and adjacency (`neighborUp`/`Down`/etc)
/// values are real in-range crate indices forming plausible links, not
/// noise.
public enum WOCCrateType: UInt8, Sendable, Codable {
    case null = 255
    case wireframe = 0
    case blank = 1
    case life = 2
    case aku = 3
    case bounce = 4
    case pickup = 5
    case fruit = 6
    case checkpoint = 7
    case slot = 8
    case tnt = 9
    case time1 = 10
    case time2 = 11
    case time3 = 12
    case ironBounce = 13
    case ironSwitch = 14
    case steel = 15
    case nitro = 16
    case nitroSwitch = 17
    case proximity = 18
    case reinforced = 19
    case invisibility = 20
}

/// One crate, from `ReadCrateData`'s real per-crate read (`crate.c`,
/// `Crate[iVar7]`). Field names/types match the real source; a few
/// fields are real and present but not independently understood beyond
/// what their own name suggests -- kept, not discarded, same "preserve
/// real bytes, don't guess their meaning" discipline as this build's own
/// `PlacedInstance.unknownUInt32List` fields.
public struct WOCCrate: Sendable, Codable {
    /// The real per-crate world position (`Crate.pos0`).
    public var position: SIMD3<Float>
    /// Real, present (`Crate.shadow`) -- a single float per crate,
    /// plausibly a cached ground-shadow projection height, not
    /// independently confirmed.
    public var shadow: Float
    /// Real, present (`Crate.dx/dy/dz`) -- a small per-crate integer
    /// delta, real and structured (small values, often `(0,0,0)` for a
    /// group's first/only crate) but its exact use isn't independently
    /// confirmed beyond "a real, present per-axis offset".
    public var delta: SIMD3<Int16>
    public var type: WOCCrateType?
    public var rawType: UInt8
    /// Real, present (`Crate.type2/3/4`, only read when the file's own
    /// `version > 2`; `255` otherwise) -- meaning beyond "additional real
    /// type/variant bytes" not independently confirmed.
    public var type2: UInt8
    public var type3: UInt8
    public var type4: UInt8
    /// Real box-adjacency links (`Crate.iU/iD/iN/iS/iE/iW` -- up/down/
    /// north/south/east/west) -- an index into this same file's flat
    /// crate list, or `-1` for "no neighbor in that direction". Verified
    /// against real bytes: these form real, in-range, plausible links
    /// (not noise) on every sample checked.
    public var neighborUp: Int16
    public var neighborDown: Int16
    public var neighborNorth: Int16
    public var neighborSouth: Int16
    public var neighborEast: Int16
    public var neighborWest: Int16
    /// Real (`Crate.trigger`, only read when the file's own `version > 3`;
    /// `-1` otherwise) -- an index into this level's trigger system, or
    /// `-1` for none.
    public var triggerIndex: Int16

    public init(
        position: SIMD3<Float>, shadow: Float, delta: SIMD3<Int16>,
        rawType: UInt8, type2: UInt8, type3: UInt8, type4: UInt8,
        neighborUp: Int16, neighborDown: Int16, neighborNorth: Int16,
        neighborSouth: Int16, neighborEast: Int16, neighborWest: Int16,
        triggerIndex: Int16
    ) {
        self.position = position
        self.shadow = shadow
        self.delta = delta
        self.rawType = rawType
        self.type = WOCCrateType(rawValue: rawType)
        self.type2 = type2
        self.type3 = type3
        self.type4 = type4
        self.neighborUp = neighborUp
        self.neighborDown = neighborDown
        self.neighborNorth = neighborNorth
        self.neighborSouth = neighborSouth
        self.neighborEast = neighborEast
        self.neighborWest = neighborWest
        self.triggerIndex = triggerIndex
    }
}

/// A real crate group (`CrateGroup_s` in the source) -- `origin`/`angle`
/// are the group's own real fields; `crates` is this group's own real
/// slice of the file's flat crate list (`Crate[iCrate..<iCrate+nCrates]`
/// in the source, already sliced out here so callers don't need to
/// track the flat-array indexing scheme themselves).
public struct WOCCrateGroup: Sendable, Codable {
    public var origin: SIMD3<Float>
    /// Real, present -- a `UInt16` angle value (units/convention not
    /// independently confirmed: could be a raw 16-bit fraction-of-a-turn
    /// encoding, matching this codebase's own established WoC-adjacent
    /// `PlacedInstance.rotationRaw` convention, but not verified here).
    public var angle: UInt16
    public var crates: [WOCCrate]

    public init(origin: SIMD3<Float>, angle: UInt16, crates: [WOCCrate]) {
        self.origin = origin
        self.angle = angle
        self.crates = crates
    }
}

/// A decoded `.CRT` (crate positions) file.
public struct WOCCrateFile: Sendable, Codable {
    /// Real file version (confirmed range `0...5` across the format's
    /// own version-gated fields -- see `WrathOfCortexParser.parseCrateFile`).
    public var version: Int32
    public var groups: [WOCCrateGroup]

    public init(version: Int32, groups: [WOCCrateGroup]) {
        self.version = version
        self.groups = groups
    }

    public var totalCrateCount: Int { groups.reduce(0) { $0 + $1.crates.count } }
}

/// A decoded `.WMP` (Wumpa fruit positions) file -- a flat list of
/// points. Real source (`OpenCrashWOC-main/code/src/gamecode/game.c`'s
/// `LoadWumpa`) confirms this build's existing structure exactly
/// (`int32 count` + `count * Vector3`, real max 256 in the original
/// engine's own fixed-size array -- not enforced here since this is a
/// decoder, not the runtime, and a real file could in principle have
/// more).
public struct WOCWumpaFile: Sendable, Codable {
    public var positions: [SIMD3<Float>]

    public init(positions: [SIMD3<Float>]) {
        self.positions = positions
    }
}
