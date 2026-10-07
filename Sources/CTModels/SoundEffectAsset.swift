import Foundation

/// A decoded `SoundEffect` record (`SectionType.se`/`.seEng`/etc.), mono,
/// 16-bit PCM already decoded from the on-disk PS-ADPCM data (see
/// `ADPCMDecoder`), ready to hand straight to `AVAudioPCMBuffer`.
public struct SoundEffectAsset: Sendable, Identifiable {
    public let id: UInt32
    public var sampleRateHz: UInt16
    /// Mono audio, or the left channel of a stereo pair when
    /// `rightChannelSamples` is non-`nil` (see that property's doc
    /// comment), same frame count as `rightChannelSamples` whenever both
    /// are present.
    public var pcmSamples: [Int16]
    /// Non-`nil` only for a real dual-channel sound bank entry decoded via
    /// `ADPCMDecoder.toPCMStereo` (a `.MH`/`.MB` sound-bank `.stereo`
    /// slot, every per-level `SoundEffect` record is mono-only, so this
    /// is always `nil` there). No `SoundEffectAsset` write-back path
    /// re-encodes a stereo pair back to ADPCM: the reference tool's own
    /// stereo encoder (`ADPCM.FromPCMStereo`) indexes out of bounds for
    /// any real interleave value and was never a working feature to port
    ///, see `SoundBankEntry.sound`'s doc comment for how stereo entries
    /// still round-trip on write (verbatim, via `SoundBankEntry.rawData`).
    public var rightChannelSamples: [Int16]?
    /// Absolute file offset and byte length of this sound's real ADPCM
    /// bytes, *not* within this record's own `ChunkNode.byteSize` (a
    /// `SoundEffect` record is just a 22-byte header; the audio itself
    /// lives in the *enclosing section's* trailing "extra data" blob, see
    /// `RM2Parser`'s `.se`-family wiring). `nil` for a `SoundEffectAsset`
    /// resolved from a standalone `.MH`/`.MB` sound bank instead of a
    /// per-level record, that path has no enclosing chunk section for
    /// this offset to be relative to. Populated only by
    /// `SoundEffectParser.resolve`, so "Replace with Audio…" write-back
    /// knows exactly which bytes to patch without re-deriving this from
    /// the section's index table a second time.
    public var sourceAudioByteRange: (offset: Int, length: Int)?

    public init(id: UInt32, sampleRateHz: UInt16, pcmSamples: [Int16], rightChannelSamples: [Int16]? = nil, sourceAudioByteRange: (offset: Int, length: Int)? = nil) {
        self.id = id
        self.sampleRateHz = sampleRateHz
        self.pcmSamples = pcmSamples
        self.rightChannelSamples = rightChannelSamples
        self.sourceAudioByteRange = sourceAudioByteRange
    }

    public var durationSeconds: Double {
        sampleRateHz > 0 ? Double(pcmSamples.count) / Double(sampleRateHz) : 0
    }
}

/// A decoded `SoundEffectX` record (`SectionType.xboxSE`, Xbox-only) , 
/// structurally decoded (frequency, the real static Xbox WAV-container
/// header fields, the raw sound bytes) but *not* PCM-decoded: unlike the
/// PS2 `SoundEffect` family, the reference's own `SoundEffectX.cs` never
/// documents `SoundData`'s codec, only its real container layout (`//
/// Confirmed static` header blocks, `SoundData.Length + 4` framing).
/// Claiming a specific codec here without that confirmation would be a
/// guess this project's own discipline doesn't make elsewhere.
public struct SoundEffectXInfo: Sendable, Identifiable {
    public let id: UInt32
    public var frequencyHz: UInt16
    /// `UnkInt` in the reference, "sometimes SoundSize again, sometimes
    /// 0, sometimes negative," per `SoundEffectX.cs`'s own comment.
    public var unknownInt: Int32
    public var soundData: Data

    public init(id: UInt32, frequencyHz: UInt16, unknownInt: Int32, soundData: Data) {
        self.id = id
        self.frequencyHz = frequencyHz
        self.unknownInt = unknownInt
        self.soundData = soundData
    }
}
