import Foundation
import CTCore
import CTModels

/// Decodes a `SoundEffect` record, ported from
/// `Twinsanity/Items/Code/SoundEffect.cs`. Unlike every other leaf record
/// type this package decodes, a `SoundEffect`'s actual audio bytes aren't
/// inside its own 22-byte record: `soundOffset`/`soundSize` index into the
/// *enclosing section's* trailing "extra data" region (everything past the
/// last indexed sub-item, see `RM2Parser`'s dedicated `.se`-family
/// wiring), so decoding happens in two steps: read the small header record,
/// then resolve it against that shared blob.
public enum SoundEffectParser {
    public struct RawRecord: Sendable {
        public var recordID: UInt32
        public var freqFac: UInt8
        public var soundSize: UInt32
        public var soundOffset: UInt32
    }

    /// The 22-byte `SoundEffect` header: `Head`(4) + `UnkFlag`(1) +
    /// `FreqFac`(1) + `Param1..4`(2 each) + `SoundSize`(4) + `SoundOffset`(4).
    public static func parseHeader(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> RawRecord {
        _ = try cursor.readUInt32() // Head
        _ = try cursor.readUInt8()  // UnkFlag
        let freqFac = try cursor.readUInt8()
        _ = try cursor.readUInt16() // Param1
        _ = try cursor.readUInt16() // Param2
        _ = try cursor.readUInt16() // Param3
        _ = try cursor.readUInt16() // Param4
        let soundSize = try cursor.readUInt32()
        let soundOffset = try cursor.readUInt32()
        return RawRecord(recordID: recordID, freqFac: freqFac, soundSize: soundSize, soundOffset: soundOffset)
    }

    /// `FreqFac` -> real sample rate, ported from `SoundEffect.GetFreq`.
    /// Any value not in this table is one the reference tool itself
    /// rejects (`throw new ArgumentException`) rather than approximates , 
    /// mirrored here by returning `nil` instead of guessing a rate.
    public static func sampleRate(forFreqFac freqFac: UInt8) -> UInt16? {
        switch freqFac {
        case 0x2: return 8000
        case 0x3: return 10000
        case 0x4: return 11025
        case 0x5: return 16000
        case 0x6: return 18000
        case 0x7: return 22050
        case 0xA: return 32000
        case 0xE: return 44100
        case 0x10: return 48000
        default: return nil
        }
    }

    /// Slices this record's ADPCM bytes out of the enclosing section's
    /// extra-data blob and decodes them.
    ///
    /// - Parameter extraDataAbsoluteFileOffset: `extraData`'s own absolute
    ///   byte offset in the file it came from, when known, lets the
    ///   result carry `sourceAudioByteRange` (absolute file offset +
    ///   length of *this sound's own* slice within that blob) for
    ///   "Replace with Audio…" write-back. `nil` for a caller that only
    ///   has `extraData` in memory with no file position to relate it to
    ///   (e.g. a synthetic/test blob).
    public static func resolve(_ record: RawRecord, extraData: Data, extraDataAbsoluteFileOffset: Int? = nil) -> SoundEffectAsset? {
        guard let freq = sampleRate(forFreqFac: record.freqFac) else { return nil }
        let start = Int(record.soundOffset)
        let length = Int(record.soundSize)
        guard start >= 0, length >= 0, start + length <= extraData.count else { return nil }
        let soundBytes = extraData.subdata(in: (extraData.startIndex + start)..<(extraData.startIndex + start + length))
        let pcm = ADPCMDecoder.toPCMMono(soundBytes)
        let byteRange = extraDataAbsoluteFileOffset.map { (offset: $0 + start, length: length) }
        return SoundEffectAsset(id: record.recordID, sampleRateHz: freq, pcmSamples: pcm, sourceAudioByteRange: byteRange)
    }

    /// The Monkey Ball build's `SoundEffect` (`SoundEffectMB.cs`,
    /// `SectionType.mbSE`), a distinct, simpler 16-byte header
    /// (`Head`(4) + `FreqReal`(4) + `SoundSize`(4) + `SoundOffset`(4))
    /// sharing the same enclosing-section "extra data" audio-storage
    /// scheme as retail. Unlike retail's `FreqFac` byte code, `FreqReal`
    /// is already the real sample rate directly, no lookup table.
    public struct RawRecordMB: Sendable {
        public var recordID: UInt32
        public var frequencyHz: UInt16
        public var soundSize: UInt32
        public var soundOffset: UInt32
    }

    public static func parseHeaderMB(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> RawRecordMB {
        _ = try cursor.readUInt32() // Head
        let frequencyHz = UInt16(truncatingIfNeeded: try cursor.readUInt32()) // FreqReal
        let soundSize = try cursor.readUInt32()
        let soundOffset = try cursor.readUInt32()
        return RawRecordMB(recordID: recordID, frequencyHz: frequencyHz, soundSize: soundSize, soundOffset: soundOffset)
    }

    /// Same real slice-and-decode as `resolve(_:extraData:...)`, `SoundEffectMB`
    /// inherits `SoundEffect` in the reference (`class SoundEffectMB :
    /// SoundEffect`) and only overrides the header fields, not the audio
    /// codec, so the same real `ADPCMDecoder` this project already ported
    /// for retail applies here too.
    public static func resolveMB(_ record: RawRecordMB, extraData: Data, extraDataAbsoluteFileOffset: Int? = nil) -> SoundEffectAsset? {
        let start = Int(record.soundOffset)
        let length = Int(record.soundSize)
        guard start >= 0, length >= 0, start + length <= extraData.count else { return nil }
        let soundBytes = extraData.subdata(in: (extraData.startIndex + start)..<(extraData.startIndex + start + length))
        let pcm = ADPCMDecoder.toPCMMono(soundBytes)
        let byteRange = extraDataAbsoluteFileOffset.map { (offset: $0 + start, length: length) }
        return SoundEffectAsset(id: record.recordID, sampleRateHz: record.frequencyHz, pcmSamples: pcm, sourceAudioByteRange: byteRange)
    }
}

/// Decodes a `SoundEffectX` record (`SoundEffectX.cs`, Xbox-only,
/// `SectionType.xboxSE`), self-contained (the real sound bytes are
/// embedded directly in the record, not indexed into a shared "extra
/// data" blob the way every PS2 `.se`-family record is), so this is a
/// single-pass decode, not the header-then-resolve split
/// `SoundEffectParser` needs.
public enum SoundEffectXParser {
    /// Real, confirmed-static header blocks from `SoundEffectX.cs` , 
    /// consumed here (not modeled field-by-field) since the reference
    /// itself never assigns them individual meaning beyond "confirmed
    /// static."
    private static let headerStatic1ByteCount = 20
    private static let headerStatic2ByteCount = 28

    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> SoundEffectXInfo {
        _ = try cursor.readUInt32() // Confirmed always 3
        let frequencyHz = UInt16(truncatingIfNeeded: try cursor.readUInt32())
        _ = try cursor.readBytes(headerStatic1ByteCount + headerStatic2ByteCount + 8) // HeaderStatic1, Freq again, Freq*2, HeaderStatic2
        let soundSize = Int(try cursor.readInt32()) - 4
        let unknownInt = try cursor.readInt32()
        guard soundSize >= 0 else {
            throw BinaryCursorError.outOfBounds(requested: soundSize, position: cursor.position, available: 0)
        }
        let soundData = try cursor.readBytes(soundSize)
        _ = try cursor.readBytes(8) // SoundSize again, then zero
        return SoundEffectXInfo(id: recordID, frequencyHz: frequencyHz, unknownInt: unknownInt, soundData: soundData)
    }
}
