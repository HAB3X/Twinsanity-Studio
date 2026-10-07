import Foundation

/// One entry's real, on-disk kind, matches the reference tool's own
/// `MHWorker.Record.Type` values exactly (0/1/2, no named enum in the
/// original either, just documented inline as Mono/Stereo/Reserved).
public enum SoundBankEntryKind: UInt32, Sendable, Codable {
    case mono = 0
    case stereo = 1
    case reserved = 2
}

/// One slot in a `.MH`/`.MB` sound bank. Many real slots are empty
/// (`.reserved`) or share one placeholder offset named "undefined" in the
/// real data (confirmed against `ENGLISH.MH`/`.MB`), not a parse error,
/// a real feature of how these banks are laid out.
public struct SoundBankEntry: Sendable, Identifiable {
    public let index: Int
    public var id: Int { index }
    public var kind: SoundBankEntryKind?
    public var rawKind: UInt32
    public var size: UInt32
    public var offset: UInt32
    public var sampleRateHz: UInt32
    public var skip: UInt32
    /// The 16-byte name embedded in the `.MB` blob itself (only present
    /// for `.mono`/`.stereo` entries, right after the `MSVp` header), real
    /// dialogue-line identifiers on this disc (e.g. "DRC085", "UKA126"),
    /// not this build's own naming.
    public var name: String?
    /// Decoded PCM, `nil` for `.reserved` entries. `.mono` entries carry
    /// mono audio in `sound.pcmSamples`; `.stereo` entries carry the left
    /// channel in `sound.pcmSamples` and the right channel in
    /// `sound.rightChannelSamples` (see `ADPCMDecoder.toPCMStereo`).
    public var sound: SoundEffectAsset?
    /// The real, untouched on-disk bytes at `[offset, offset + size)` in
    /// the owning `.MB` file, captured for `.stereo` entries specifically
    /// so `MBWriter` can still round-trip a bank that merely *contains*
    /// stereo slots by writing this back verbatim. Write-back stays
    /// verbatim-only even though `.stereo` decode is now real: the
    /// reference tool's own stereo re-encoder (`ADPCM.FromPCMStereo`)
    /// indexes out of bounds for any real interleave value and was never
    /// a working feature to port (see `SoundEffectAsset.
    /// rightChannelSamples`'s doc comment). `nil` for `.mono`/`.reserved`
    /// entries, which don't need it (`.mono` re-encodes for real via
    /// `sound`).
    public var rawData: Data?

    public init(index: Int, rawKind: UInt32, size: UInt32, offset: UInt32, sampleRateHz: UInt32, skip: UInt32, name: String?, sound: SoundEffectAsset?, rawData: Data? = nil) {
        self.index = index
        self.rawKind = rawKind
        self.kind = SoundBankEntryKind(rawValue: rawKind)
        self.size = size
        self.offset = offset
        self.sampleRateHz = sampleRateHz
        self.skip = skip
        self.name = name
        self.sound = sound
        self.rawData = rawData
    }
}

/// A decoded `.MH`/`.MB` sound bank pair, ported from the reference
/// tool's own `MHWorker.LoadMH`/`LoadBuffer`. Unlike per-level `SoundEffect`
/// records (nested inside an `.RM2`/`.SM2` file's `Code` section), these are
/// standalone top-level files sitting next to the archive
/// (`MUSIC.MB`/`.MH`, `ENGLISH.MB`/`.MH`, etc.), a separate, global
/// streaming audio system this build didn't open at all before.
public struct SoundBankAsset: Sendable, Identifiable {
    public let id: String
    public var sourceLabel: String
    public var interleave: UInt32
    public var entries: [SoundBankEntry]

    public init(sourceLabel: String, interleave: UInt32, entries: [SoundBankEntry]) {
        self.id = sourceLabel
        self.sourceLabel = sourceLabel
        self.interleave = interleave
        self.entries = entries
    }

    public var decodedCount: Int { entries.filter { $0.sound != nil }.count }
}
