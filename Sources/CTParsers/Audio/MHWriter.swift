import Foundation
import CTCore
import CTModels

/// Encodes a `SoundBankAsset` back to `.MH` (header) data, the write-back
/// half of `SoundBankProcessor`. Ported field-for-field from the reference
/// tool's real, working `MHWorker.SaveMH` function, verified against real
/// game data to ensure identical byte layouts.
///
/// This enables complete round-trip support: parse → modify → rebuild
/// music and sound banks for game modding and custom audio replacement.
public enum MHWriter {
    /// Encodes a sound bank asset into `.MH` binary format.
    ///
    /// - Parameters:
    ///   - asset: The sound bank to encode
    ///   - interleave: Stereo interleave block size (use asset's existing value or 0 for mono-only banks)
    /// - Returns: Binary `.MH` Data ready to be written to disk
    /// - Throws: EncodingError if the asset cannot be properly encoded
    public static func encode(_ asset: SoundBankAsset, interleave: UInt32? = nil) throws -> Data {
        // Use provided interleave or fall back to asset's existing value
        let finalInterleave = interleave ?? asset.interleave

        // Header: soundCount (uint32) + interleave (uint32)
        var data = Data()
        data.append(littleEndian: UInt32(asset.entries.count))
        data.append(littleEndian: finalInterleave)

        // Write entries
        for entry in asset.entries {
            // kind (as raw uint32)
            data.append(littleEndian: entry.rawKind)
            // size
            data.append(littleEndian: entry.size)
            // offset (into .MB)
            data.append(littleEndian: entry.offset)
            // sampleRateHz
            data.append(littleEndian: entry.sampleRateHz)
            // skip
            data.append(littleEndian: entry.skip)
        }

        return data
    }
}

/// Extension to add littleEndian appending to Data (mirroring SoundEffectInspectorView)
public extension Data {
    mutating func append(littleEndian value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(littleEndian value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}