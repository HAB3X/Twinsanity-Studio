import Foundation
import CTCore
import CTModels

/// Decodes a `.MH`/`.MB` sound bank pair, ported from the reference
/// tool's real, working `MHWorker.LoadMH`/`LoadBuffer` (`TwinsaityEditor/
/// Workers/MHWorker.cs`), not reconstructed from format documentation.
/// Verified against every real bank on the mounted disc before trusting
/// this layout: `MUSIC`/`ENGLISH`/`FRENCH`/`GERMAN`/`ITALIAN`/`SPANISH`
/// all report exactly 143 real entries, real embedded names
/// ("DRC085", "UKA126", ...), and matching sample rates between the `.MH`
/// index and the `.MB`-embedded header for every mono entry checked.
///
/// Layout:
/// ```
/// .MH:
///   uint32 soundCount
///   uint32 interleave
///   Entry[soundCount]:
///     uint32 kind       // 0=mono, 1=stereo, 2=reserved (empty)
///     uint32 size
///     uint32 offset     // into .MB
///     uint32 sampleRateHz
///     uint32 skip
///
/// .MB, at a mono/stereo entry's `offset` (mono only, stereo entries have
/// no header, just raw interleaved ADPCM at `offset` directly):
///   char[4]  "MSVp" magic
///   byte[4]  version
///   uint32   (unused)
///   uint32   size - 48, big-endian (redundant with the .MH `size` field)
///   uint32   sampleRateHz, big-endian
///   uint32[3] (unused)
///   char[16] name, null-padded
///   <ADPCM data, `size` bytes>
/// ```
public enum SoundBankParser {
    /// Stereo entries are real (62/143 in the real `MUSIC` bank) and now
    /// decoded via `ADPCMDecoder.toPCMStereo`, splitting the interleaved
    /// byte stream by this bank's own `interleave` block size, the
    /// reference tool's real `ADPCM.ToPCMStereo` (see that function's own
    /// doc comment for why it's ported from there and not from the
    /// `MHWorker.cs`/`ADPCM_Demux` call site, which is stale/non-compiling
    /// code). Write-back stays verbatim-only (`rawData`), see
    /// `SoundEffectAsset.rightChannelSamples`'s doc comment.
    public static func parse(mhData: Data, mbData: Data, sourceLabel: String) throws -> SoundBankAsset {
        var cursor = BinaryCursor(data: mhData)
        let count = try cursor.readUInt32()
        let interleave = try cursor.readUInt32()

        var entries: [SoundBankEntry] = []
        entries.reserveCapacity(cursor.safeReserveCount(count, elementSize: 20)) // 5 x uint32 minimum per entry
        for index in 0..<Int(count) {
            let rawKind = try cursor.readUInt32()
            let size = try cursor.readUInt32()
            let offset = try cursor.readUInt32()
            let mhSampleRate = try cursor.readUInt32()
            let skip = try cursor.readUInt32()

            guard let kind = SoundBankEntryKind(rawValue: rawKind) else {
                entries.append(SoundBankEntry(index: index, rawKind: rawKind, size: size, offset: offset, sampleRateHz: mhSampleRate, skip: skip, name: nil, sound: nil))
                continue
            }

            switch kind {
            case .reserved:
                entries.append(SoundBankEntry(index: index, rawKind: rawKind, size: size, offset: offset, sampleRateHz: mhSampleRate, skip: skip, name: nil, sound: nil))
            case .mono:
                let (name, sampleRateHz, sound) = decodeMonoEntry(mbData: mbData, offset: offset, size: size, fallbackSampleRateHz: mhSampleRate)
                entries.append(SoundBankEntry(index: index, rawKind: rawKind, size: size, offset: offset, sampleRateHz: sampleRateHz, skip: skip, name: name, sound: sound))
            case .stereo:
                // No MSVp header for stereo, raw interleaved ADPCM sits
                // directly at `offset` (see this type's own layout doc
                // comment). `rawData` is always captured verbatim
                // regardless of decode success, so `MBWriter` can still
                // round-trip a bank that merely *contains* stereo slots , 
                // see `SoundBankEntry.rawData`.
                let rawData = Self.rawBytes(in: mbData, offset: offset, size: size)
                let sound = rawData.map { data -> SoundEffectAsset in
                    let (left, right) = ADPCMDecoder.toPCMStereo(data, interleaveBytes: Int(interleave))
                    return SoundEffectAsset(id: offset, sampleRateHz: UInt16(clamping: mhSampleRate), pcmSamples: left, rightChannelSamples: right)
                }
                entries.append(SoundBankEntry(index: index, rawKind: rawKind, size: size, offset: offset, sampleRateHz: mhSampleRate, skip: skip, name: "Stereo", sound: sound, rawData: rawData))
            }
        }

        return SoundBankAsset(sourceLabel: sourceLabel, interleave: interleave, entries: entries)
    }

    /// `nil` if `[offset, offset + size)` doesn't actually fit inside
    /// `mbData`, same "a bad slot doesn't crash the whole bank" posture
    /// as `decodeMonoEntry`'s own bounds check.
    private static func rawBytes(in mbData: Data, offset: UInt32, size: UInt32) -> Data? {
        let start = Int(offset)
        guard start >= 0, size > 0 else { return nil }
        let end = start + Int(size)
        guard start <= mbData.count, end <= mbData.count else { return nil }
        return mbData.subdata(in: (mbData.startIndex + start)..<(mbData.startIndex + end))
    }

    /// `nil` name/sound (sample rate falls back to the `.MH` value) if the
    /// offset/size don't actually fit inside `mbData`, a real possibility
    /// this format allows for (some slots are placeholders), never crashes
    /// the whole bank over one bad entry.
    private static func decodeMonoEntry(mbData: Data, offset: UInt32, size: UInt32, fallbackSampleRateHz: UInt32) -> (name: String?, sampleRateHz: UInt32, sound: SoundEffectAsset?) {
        let headerStart = Int(offset)
        guard headerStart >= 0, headerStart + 48 <= mbData.count else {
            return (nil, fallbackSampleRateHz, nil)
        }

        // Big-endian sample rate at offset+16, the one field in this
        // otherwise little-endian PS2 format that isn't, confirmed against
        // real data (matches the `.MH`-stored value exactly in every
        // sample checked).
        guard let sampleRateAtHeader: UInt32 = try? {
            var c = BinaryCursor(data: mbData, startPosition: headerStart + 16)
            let bytes = try c.readBytes(4)
            return UInt32(bytes[bytes.startIndex]) << 24 | UInt32(bytes[bytes.startIndex + 1]) << 16 | UInt32(bytes[bytes.startIndex + 2]) << 8 | UInt32(bytes[bytes.startIndex + 3])
        }() else { return (nil, fallbackSampleRateHz, nil) }

        let name: String? = {
            guard let nameBytes = try? { () -> Data in
                var c = BinaryCursor(data: mbData, startPosition: headerStart + 32)
                return try c.readBytes(16)
            }() else { return nil }
            let trimmed = nameBytes.prefix { $0 != 0 }
            return String(bytes: trimmed, encoding: .ascii)
        }()

        let adpcmStart = headerStart + 48
        let adpcmEnd = adpcmStart + Int(size)
        guard adpcmStart <= mbData.count else {
            return (name, sampleRateAtHeader, nil)
        }
        let clampedEnd = min(adpcmEnd, mbData.count)
        guard clampedEnd > adpcmStart else {
            return (name, sampleRateAtHeader, SoundEffectAsset(id: UInt32(0), sampleRateHz: UInt16(clamping: sampleRateAtHeader), pcmSamples: []))
        }
        let adpcmData = mbData.subdata(in: (mbData.startIndex + adpcmStart)..<(mbData.startIndex + clampedEnd))
        let pcm = ADPCMDecoder.toPCMMono(adpcmData)
        let sound = SoundEffectAsset(id: UInt32(offset), sampleRateHz: UInt16(clamping: sampleRateAtHeader), pcmSamples: pcm)
        return (name, sampleRateAtHeader, sound)
    }
}
