import Foundation

/// Decodes Sony SPU/PS-ADPCM ("VAG") audio, the codec this engine's
/// `SoundEffect` records use. Ported field-for-field from the reference
/// tool's `Twinsanity/ADPCM.cs` (`ToPCMMono`/`LineToPCM`/`SampleToPCM`),
/// itself based on the well-known `vag2wav.c` (bITmASTER/nextvolume,
/// https://github.com/simias/psxsdk). This is a real, working, previously-
/// verified decoder being transcribed, not a reconstruction from format
/// documentation alone.
public enum ADPCMDecoder {
    /// Predictor coefficient pairs, indexed by the 4-bit `predict` nibble.
    /// Only indices 0–4 are ever used by real data; 5–15 are zero exactly
    /// as in the reference table.
    private static let predictorCoefficients: [(Double, Double)] = [
        (0.0, 0.0),
        (60.0 / 64.0, 0.0),
        (115.0 / 64.0, -52.0 / 64.0),
        (98.0 / 64.0, -55.0 / 64.0),
        (122.0 / 64.0, -60.0 / 64.0),
        (0.0, 0.0), (0.0, 0.0), (0.0, 0.0), (0.0, 0.0),
        (0.0, 0.0), (0.0, 0.0), (0.0, 0.0), (0.0, 0.0),
        (0.0, 0.0), (0.0, 0.0), (0.0, 0.0)
    ]

    /// One 4-bit ADPCM nibble -> one 16-bit PCM sample. The nibble is
    /// shifted into the top of a 16-bit word first (`nibble << 12`,
    /// truncated to `Int16`), the standard PS-ADPCM sign-extension trick,
    /// not an arbitrary scale factor.
    private static func sampleToPCM(nibble: Int, factor: Int, predict: Int, s0: inout Double, s1: inout Double) -> Int16 {
        let shifted = Int32(nibble) << 12
        let signExtended = Int32(Int16(truncatingIfNeeded: shifted))
        let sample = signExtended >> Int32(factor)
        let coefficients = predictorCoefficients[predict & 0xF]
        let value = Double(sample) + s0 * coefficients.0 + s1 * coefficients.1
        s1 = s0
        s0 = value
        // `truncatingIfNeeded` used to wrap out-of-range values instead of
        // clamping them -- real PS-ADPCM predictor coefficients run up to
        // ~1.9x, which can overshoot ±32767 on loud transients. Every other
        // real decoder (vgmstream's `psx_decoder.c` reference `clamp16()`
        // included) clamps that sample to 16-bit range rather than wrapping
        // it; wrapping produces audible pops/noise a clamped decode
        // wouldn't have, on exactly the same input.
        let rounded = value.rounded(.toNearestOrEven)
        let clamped = min(max(rounded, Double(Int16.min)), Double(Int16.max))
        return Int16(clamped)
    }

    /// One 16-byte ADPCM "line" (2-byte header + 14 bytes of packed
    /// nibbles) -> 28 PCM samples.
    private static func lineToPCM(_ line: ArraySlice<UInt8>, s0: inout Double, s1: inout Double) -> [Int16] {
        let bytes = Array(line)
        let factor = Int(bytes[0] & 0xF)
        let predict = Int((bytes[0] >> 4) & 0xF)
        var samples: [Int16] = []
        samples.reserveCapacity(28)
        for i in 0..<14 {
            let byte = bytes[i + 2]
            let low = Int(byte & 0xF)
            let high = Int((byte & 0xF0) >> 4)
            samples.append(sampleToPCM(nibble: low, factor: factor, predict: predict, s0: &s0, s1: &s1))
            samples.append(sampleToPCM(nibble: high, factor: factor, predict: predict, s0: &s0, s1: &s1))
        }
        return samples
    }

    /// Decodes mono ADPCM data into 16-bit signed PCM samples. Stops at a
    /// line whose second byte is `7` (end-of-stream marker) or that has the
    /// loop-end flag bit set, both real terminators the reference decoder
    /// honors, not just "ran out of bytes."
    public static func toPCMMono(_ data: Data) -> [Int16] {
        let bytes = Array(data)
        guard bytes.count >= 16 else { return [] }
        var s0 = 0.0, s1 = 0.0
        var pcm: [Int16] = []
        var offset = 0
        while offset + 16 <= bytes.count {
            let line = bytes[offset..<(offset + 16)]
            let flags = line[line.startIndex + 1]
            if flags == 7 { break }
            pcm.append(contentsOf: lineToPCM(line, s0: &s0, s1: &s1))
            if flags & 1 != 0 { break } // SampleLineFlags.LoopEnd
            offset += 16
        }
        return pcm
    }

    /// Decodes dual-channel interleaved ADPCM into separate left/right
    /// 16-bit PCM channels, ported field-for-field from the reference
    /// tool's real, working `Twinsanity.ADPCM.ToPCMStereo` (distinct from,
    /// and more complete than, the stale `MHWorker.cs`/`ADPCM_Demux` call
    /// site that doesn't actually compile against the current `ADPCM`
    /// class, `MHViewer.cs`, the tool's real current sound-bank viewer,
    /// calls this exact function for every `Type == 1` stereo entry).
    ///
    /// Layout: `data` alternates in `interleaveBytes`-sized blocks between
    /// a run of left-channel lines and a run of right-channel lines
    /// (`[L block][R block][L block][R block]...`), each block holding
    /// `interleaveBytes / 16` consecutive 16-byte ADPCM lines. Returns
    /// `(left: [], right: [])` if `data`/`interleaveBytes` aren't valid
    /// multiples of 32/16 respectively, rather than trapping, a bad
    /// bank/entry shouldn't crash the whole browser.
    ///
    /// Termination is intentionally **not** the same bitwise check
    /// `toPCMMono` uses: the reference's own `ToPCMStereo` tests each
    /// line's flag byte for exact equality to `1`, not `flags & 1 != 0` , 
    /// a real, faithfully-preserved discrepancy between the two reference
    /// functions (mono treats any odd flag value as loop-end; stereo only
    /// treats exactly `1`), not a bug introduced by this port.
    public static func toPCMStereo(_ data: Data, interleaveBytes: Int) -> (left: [Int16], right: [Int16]) {
        let bytes = Array(data)
        guard bytes.count % 32 == 0, interleaveBytes > 0, interleaveBytes % 16 == 0 else { return ([], []) }
        let lineCount = bytes.count / 32
        let interleaveLines = interleaveBytes / 16
        var s0L = 0.0, s1L = 0.0
        var s0R = 0.0, s1R = 0.0
        var left: [Int16] = []
        var right: [Int16] = []
        var interleaveAdv = 0
        for i in 0..<lineCount {
            if i % interleaveLines == 0 { interleaveAdv += 1 }
            let lStart = (i + interleaveLines * (interleaveAdv - 1)) * 16
            let rStart = (i + interleaveLines * interleaveAdv) * 16
            guard lStart >= 0, rStart >= 0, lStart + 16 <= bytes.count, rStart + 16 <= bytes.count else { break }
            let lineL = bytes[lStart..<(lStart + 16)]
            let lineR = bytes[rStart..<(rStart + 16)]
            if lineL[lineL.startIndex + 1] == 7 || lineR[lineR.startIndex + 1] == 7 { break }
            left.append(contentsOf: lineToPCM(lineL, s0: &s0L, s1: &s1L))
            right.append(contentsOf: lineToPCM(lineR, s0: &s0R, s1: &s1R))
            if lineL[lineL.startIndex + 1] == 1 || lineR[lineR.startIndex + 1] == 1 { break }
        }
        return (left, right)
    }
}
