import Foundation

/// Encodes 16-bit mono PCM back to Sony SPU/PS-ADPCM ("VAG"), the write-back
/// half of `ADPCMDecoder`. Ported field-for-field from the reference tool's
/// `Twinsanity/ADPCM.cs`'s `FromPCMMono`/`FindPredict`/`PackSamples`, itself
/// based on the well-known `wav2vag.c` (bITmASTER/nextvolume,
/// https://github.com/simias/psxsdk). This is a real, working, previously-
/// verified encoder being transcribed, not a reconstruction from format
/// documentation alone, same standard this package holds every other
/// parser/writer to.
///
/// One deliberate addition beyond the reference: `PackSamples`'s final
/// `Int32` cast (`(int)(((int)ds + 0x800) & 0xfffff000)`) is unchecked in
/// C#, an out-of-range double there is implementation-defined, not a
/// crash. Swift's `Int32(_:)` traps on a double outside `Int32`'s range, so
/// this clamps `ds` first; for the realistic PCM/factor ranges this
/// algorithm ever actually produces, the clamp is never hit; it's a safety
/// net against degenerate/synthetic input, not a behavioral change from the
/// reference.
public enum ADPCMEncoder {
    /// Same predictor coefficient table as `ADPCMDecoder`, duplicated
    /// rather than shared: the two directions are independent, verified
    /// ports of two independent reference functions, and keeping them
    /// textually separate makes each one individually diffable against its
    /// own reference source.
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

    private static let samplesPerLine = 28
    private static let bufferSize = 128 * 28

    /// Encodes `pcm` (16-bit mono samples) to on-disk ADPCM bytes: a
    /// sequence of 16-byte lines (1 header byte + 1 flags byte + 14 bytes
    /// of packed 4-bit nibbles), terminated by one more 16-byte line with
    /// the end-of-stream flag (`flags == 7`), exactly what
    /// `ADPCMDecoder.toPCMMono` expects to read back.
    public static func fromPCMMono(_ pcm: [Int16]) -> Data {
        var predict = 0, factor = 0
        // Predictor continuity state carried *across* 28-sample blocks
        // (mirrors the reference's `_s_1`/`_s_2` instance fields, reset
        // once per `FromPCMMono` call, this function's own scope already
        // gives that same one-call lifetime, so plain locals suffice).
        var carriedS1 = 0.0, carriedS2 = 0.0

        var samplesRemaining = pcm.count
        var readOffset = 0
        var vag: [UInt8] = []
        vag.reserveCapacity((pcm.count / samplesPerLine + 2) * 16)

        var wave = [Int16](repeating: 0, count: bufferSize)
        var doubleSamples = [Double](repeating: 0, count: samplesPerLine)
        var quantizedSamples = [Int16](repeating: 0, count: samplesPerLine)

        while samplesRemaining > 0 {
            let chunkSize = min(samplesRemaining, bufferSize)
            for i in 0..<chunkSize {
                wave[i] = pcm[readOffset + i]
            }
            readOffset += chunkSize

            var lineCount = chunkSize / samplesPerLine
            let remainder = chunkSize % samplesPerLine
            if remainder != 0 {
                for j in remainder..<samplesPerLine {
                    wave[samplesPerLine * lineCount + j] = 0
                }
                lineCount += 1
            }

            for line in 0..<lineCount {
                findPredict(wave, offset: line * samplesPerLine, into: &doubleSamples, predict: &predict, factor: &factor, s1: &carriedS1, s2: &carriedS2)
                packSamples(doubleSamples, into: &quantizedSamples, predict: predict, factor: factor)

                vag.append(UInt8(truncatingIfNeeded: (predict << 4) | factor))
                vag.append(0)
                var k = 0
                while k < samplesPerLine {
                    let hi = (Int(quantizedSamples[k + 1]) >> 8) & 0xF0
                    let lo = (Int(quantizedSamples[k]) >> 12) & 0xF
                    vag.append(UInt8(truncatingIfNeeded: hi | lo))
                    k += 2
                }
            }
            samplesRemaining -= chunkSize
        }

        vag.append(UInt8(truncatingIfNeeded: (predict << 4) | factor))
        vag.append(7) // SampleLineFlags.LoopEnd's own value, doubling as the decoder's end-of-stream marker.
        vag.append(contentsOf: [UInt8](repeating: 0, count: 14))
        return Data(vag)
    }

    /// Searches predictors 0...4 for whichever keeps this 28-sample block's
    /// filtered values smallest (least quantization error), picks a shift
    /// `factor` from the winning predictor's peak magnitude, and fills
    /// `doubleSamples` with that predictor's filtered output, ported from
    /// `FindPredict`. `s1`/`s2` are the continuity state carried in from
    /// the previous block and updated in place for the next one.
    private static func findPredict(_ samples: [Int16], offset: Int, into doubleSamples: inout [Double], predict: inout Int, factor: inout Int, s1: inout Double, s2: inout Double) {
        var max = [Double](repeating: 0, count: 5)
        var buffer = [[Double]](repeating: [Double](repeating: 0, count: 5), count: samplesPerLine)
        var min = 1e10
        var runningS1 = 0.0, runningS2 = 0.0

        for i in 0..<5 {
            max[i] = 0.0
            runningS1 = s1
            runningS2 = s2
            for j in 0..<samplesPerLine {
                var s0 = Double(samples[j + offset])
                if s0 > 30719.0 { s0 = 30719.0 }
                else if s0 < -30719.0 { s0 = -30719.0 }
                let ds = s0 + runningS1 * predictorCoefficients[i].0 + runningS2 * predictorCoefficients[i].1
                buffer[j][i] = ds
                if abs(ds) > max[i] { max[i] = abs(ds) }
                runningS2 = runningS1
                runningS1 = s0
            }
            if max[i] < min {
                min = max[i]
                predict = i
            }
            if min <= 7 {
                predict = 0
                break
            }
        }
        s1 = runningS1
        s2 = runningS2
        for i in 0..<samplesPerLine {
            doubleSamples[i] = buffer[i][predict]
        }

        let min2 = Int(min)
        var mask = 0x4000
        factor = 0
        while factor < 12 {
            if (mask & (min2 + (mask >> 3))) != 0 { break }
            factor += 1
            mask >>= 1
        }
    }

    /// Quantizes `doubleSamples` into the 4-bit nibbles `fromPCMMono`
    /// packs two-per-byte, ported from `PackSamples`. `s1`/`s2` here are
    /// deliberately *not* carried across calls (reset to 0 every call),
    /// matching the reference's own function-local `s_1`/`s_2`, distinct
    /// from `findPredict`'s carried continuity state.
    private static func packSamples(_ doubleSamples: [Double], into quantized: inout [Int16], predict: Int, factor: Int) {
        var s1 = 0.0, s2 = 0.0
        for i in 0..<samplesPerLine {
            let s0 = doubleSamples[i] + s1 * predictorCoefficients[predict].0 + s2 * predictorCoefficients[predict].1
            let ds = s0 * Double(1 << factor)
            let clampedForConversion = min(max(ds, Double(Int32.min)), Double(Int32.max))
            let rawInt = Int32(clampedForConversion)
            // Pure 32-bit wrapping add + mask, matching the reference's
            // `(int)(((int)ds + 0x800) & 0xfffff000)` bit-for-bit, doing
            // this in a wider integer type first would zero-extend a
            // negative `rawInt` instead of preserving its two's-complement
            // sign bits through the mask, corrupting every negative sample.
            let biased = rawInt &+ 0x800
            let masked = biased & Int32(bitPattern: 0xFFFF_F000)
            let di = min(max(masked, Int32(Int16.min)), Int32(Int16.max))
            quantized[i] = Int16(di)
            let shiftedBack = di >> Int32(factor)
            s2 = s1
            s1 = Double(shiftedBack) - s0
        }
    }
}
