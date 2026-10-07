import Foundation
import CTCore
import CTModels

/// Encodes audio data back to `.MB` (bank/data) format, the write-back
/// half of `SoundBankProcessor`. Ported field-for-field from the reference
/// tool's real, working `MHWorker.SaveMB` function, verified against real
/// game data to ensure identical byte layouts.
///
/// `.mono` entries are genuinely re-encoded from `entry.sound`'s PCM.
/// `.stereo` entries are written back verbatim from `entry.rawData`, this
/// build has no stereo ADPCM demux/re-encode (see `SoundBankEntry.sound`'s
/// doc comment), so a bank that merely *contains* untouched stereo slots
/// can still round-trip honestly, by copying bytes rather than fabricating
/// or discarding them.
public enum MBWriter {
    /// Real, fixed size of the MSVp header written before every `.mono`
    /// entry's ADPCM payload: magic(4) + version(4) + unused(4) + size(4)
    /// + sampleRate(4) + 3×unused(4 each=12) + name(16) = 48.
    private static let monoHeaderSize: UInt32 = 48

    /// Encodes sound bank entries into `.MB` binary format.
    ///
    /// - Parameters:
    ///   - entries: The sound bank entries to encode (`.mono` needs `sound`; `.stereo` needs `rawData`)
    ///   - interleave: Stereo interleave block size (0 for mono-only banks)
    /// - Returns: The binary `.MB` `Data` ready to be written to disk, and a corrected copy of
    ///   `entries` whose `offset`/`size` reflect the *real* layout just written, not necessarily
    ///   what the input entries said, since a re-encoded `.mono` entry's actual ADPCM byte count
    ///   can differ from its pre-edit `size`. Pass these corrected entries (not the originals) to
    ///   `MHWriter.encode`, the `.MH` file's own offset/size table must describe this exact
    ///   `.MB` output, or every entry after the first mismatch points at the wrong place.
    /// - Throws: `MBWriterError.missingAudioData` if a `.mono` entry has no `sound`, or a `.stereo` entry has no `rawData`
    public static func encode(_ entries: [SoundBankEntry], interleave: UInt32 = 0) throws -> (data: Data, entries: [SoundBankEntry]) {
        var data = Data()
        var correctedEntries: [SoundBankEntry] = []
        correctedEntries.reserveCapacity(entries.count)

        // Track current offset for MH cross-reference
        var currentOffset: UInt32 = 0

        for entry in entries {
            let kind = SoundBankEntryKind(rawValue: entry.rawKind)
            let entryStartOffset = currentOffset

            switch kind {
            case .stereo:
                // No MSVp header for stereo, raw interleaved ADPCM sits
                // directly at `offset` (see `SoundBankParser`'s own layout
                // doc comment). This build has no stereo demux/re-encode
                // (see `SoundBankEntry.sound`'s doc comment), so the only
                // honest way to write a stereo slot back is verbatim, from
                // the real bytes `SoundBankParser` captured into
                // `rawData`, never synthesized.
                guard let rawData = entry.rawData else {
                    throw MBWriterError.missingAudioData(index: entry.index)
                }
                data.append(rawData)
                currentOffset += UInt32(rawData.count)
                if interleave > 0 {
                    let paddedSize = ((rawData.count + Int(interleave) - 1) / Int(interleave)) * Int(interleave)
                    let paddingNeeded = paddedSize - rawData.count
                    if paddingNeeded > 0 {
                        data.append(contentsOf: [UInt8](repeating: 0, count: paddingNeeded))
                        currentOffset += UInt32(paddingNeeded)
                    }
                }
                var correctedStereo = entry
                correctedStereo.offset = entryStartOffset
                correctedStereo.size = UInt32(rawData.count) // real payload size, not counting alignment padding
                correctedEntries.append(correctedStereo)

            case .mono:
                guard let sound = entry.sound else {
                    throw MBWriterError.missingAudioData(index: entry.index)
                }

                // Audio data - PCM needs to be encoded to ADPCM first.
                // Encoded before the header below (rather than after, as a
                // separate step) so the header's size field below reflects
                // the real encoded byte count, not the pre-edit
                // `entry.size`, those two can legitimately differ (ADPCM
                // encoding nuances, or the PCM itself having been edited to
                // a different sample count), and a stale header size would
                // otherwise desync from the payload actually written.
                let adpcmData = ADPCMEncoder.fromPCMMono(sound.pcmSamples)

                // Write MSVp header
                data.append(contentsOf: Array("MSVp".utf8)) // magic
                data.append(contentsOf: [0, 0, 0, 1])       // version = 1
                data.append(contentsOf: [0, 0, 0, 0])       // unused

                // Size field (big-endian, redundant with MH size), the
                // real, just-computed encoded byte count. Extracted
                // MSB-first directly from the plain value: calling
                // `.bigEndian` first and *then* extracting MSB-first is a
                // double byte-swap that silently writes little-endian
                // bytes instead (confirmed against `SoundBankParser.
                // decodeMonoEntry`, which reads this exact field, and the
                // sample rate below, genuinely MSB-first per its own
                // doc comment, "confirmed against real data").
                let sizeField = UInt32(adpcmData.count)
                data.append(contentsOf: [
                    UInt8((sizeField >> 24) & 0xFF),
                    UInt8((sizeField >> 16) & 0xFF),
                    UInt8((sizeField >> 8) & 0xFF),
                    UInt8(sizeField & 0xFF)
                ])

                // Sample rate (big-endian), same direct-extraction fix.
                let sampleRateBE = UInt32(sound.sampleRateHz)
                data.append(contentsOf: [
                    UInt8((sampleRateBE >> 24) & 0xFF),
                    UInt8((sampleRateBE >> 16) & 0xFF),
                    UInt8((sampleRateBE >> 8) & 0xFF),
                    UInt8(sampleRateBE & 0xFF)
                ])

                // Three unused uint32 fields
                data.append(contentsOf: [0, 0, 0, 0])
                data.append(contentsOf: [0, 0, 0, 0])
                data.append(contentsOf: [0, 0, 0, 0])

                // Name (16 bytes, null-padded)
                var nameBytes = [UInt8](repeating: 0, count: 16)
                if let name = entry.name {
                    let nameData = Array(name.utf8.prefix(15)) // Leave room for null terminator
                    for i in 0..<min(nameData.count, 15) {
                        nameBytes[i] = nameData[i]
                    }
                }
                data.append(contentsOf: nameBytes)

                data.append(contentsOf: adpcmData)

                // Update offset for next entry, the fixed 48-byte MSVp
                // header plus the real ADPCM payload. Missing the header
                // bytes here was a real, previously-silent bug: `data`
                // itself was always correct (it really does append the
                // header), but `currentOffset`, the only source of the
                // "real layout" this function now returns for `MHWriter`
                // to consume, was undercounting every entry by 48 bytes,
                // which would have desynced every offset after the first.
                currentOffset += monoHeaderSize + UInt32(adpcmData.count)

                var correctedMono = entry
                correctedMono.offset = entryStartOffset
                correctedMono.size = UInt32(adpcmData.count)
                correctedEntries.append(correctedMono)

            case .reserved, .none:
                // Reserved entries have no data in .MB file, passed
                // through unchanged so the corrected array still has one
                // entry per input entry, same order.
                correctedEntries.append(entry)
            }
        }

        return (data, correctedEntries)
    }
}

/// Encoding errors specific to MBWriter
public enum MBWriterError: LocalizedError {
    case missingAudioData(index: Int)
    case audioEncodingFailed
    case invalidInterleave

    public var errorDescription: String? {
        switch self {
        case .missingAudioData(let index):
            return "Entry at index \(index) is mono/stereo but has no sound/rawData to encode"
        case .audioEncodingFailed:
            return "Failed to encode PCM audio to ADPCM format"
        case .invalidInterleave:
            return "Invalid interleave value for stereo audio encoding"
        }
    }
}

