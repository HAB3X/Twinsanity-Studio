import XCTest
@testable import CTParsers

final class ADPCMDecoderTests: XCTestCase {
    func testSilentLineDecodesToZeroPCM() {
        // factor=0, predict=0, all nibbles zero -> every sample is exactly 0.
        var line = [UInt8](repeating: 0, count: 16)
        line[1] = 0 // not the end-of-stream/loop-end marker
        let pcm = ADPCMDecoder.toPCMMono(Data(line))

        XCTAssertEqual(pcm.count, 28)
        XCTAssertTrue(pcm.allSatisfy { $0 == 0 })
    }

    func testEndOfStreamFlagStopsDecodingImmediately() {
        var line = [UInt8](repeating: 0xFF, count: 16)
        line[1] = 7 // end-of-stream marker
        let pcm = ADPCMDecoder.toPCMMono(Data(line))
        XCTAssertTrue(pcm.isEmpty)
    }

    func testLoopEndFlagStopsAfterOneLine() {
        var line1 = [UInt8](repeating: 0, count: 16)
        line1[1] = 1 // LoopEnd bit set
        var line2 = [UInt8](repeating: 0, count: 16)
        line2[1] = 0
        let pcm = ADPCMDecoder.toPCMMono(Data(line1 + line2))
        // Only the first (loop-end) line should be decoded.
        XCTAssertEqual(pcm.count, 28)
    }

    func testShorterThanOneLineDecodesToNothing() {
        let pcm = ADPCMDecoder.toPCMMono(Data([0, 0, 0]))
        XCTAssertTrue(pcm.isEmpty)
    }

    /// A single nibble of 1 with factor=0, predict=0 (no history) should
    /// decode to exactly `1 << 12 = 4096`, the standard PS-ADPCM
    /// nibble-to-top-of-word sign-extension, with no predictor contribution
    /// on the very first sample (history starts at zero).
    func testFirstSampleMatchesRawNibbleShift() {
        var line = [UInt8](repeating: 0, count: 16)
        line[0] = 0 // factor=0, predict=0
        line[1] = 0
        line[2] = 0x01 // low nibble = 1 -> first decoded sample
        let pcm = ADPCMDecoder.toPCMMono(Data(line))
        XCTAssertEqual(pcm.first, 4096)
    }

    // MARK: - toPCMStereo

    private func silentLine(flag: UInt8 = 0) -> [UInt8] {
        var line = [UInt8](repeating: 0, count: 16)
        line[1] = flag
        return line
    }

    func testStereoAlternatingBlocksDecodeIntoSeparateChannels() {
        // interleave = 16 (one line per block): L0 R0 L1 R1 L2 R2 laid out
        // back to back, each block's line distinguishable by its factor
        // nibble (byte 0's high nibble = predict, low = factor, using
        // factor alone here, predict 0, so the decoded value is a pure
        // nibble shift with no predictor contribution).
        var lLine = silentLine()
        lLine[0] = 0 // factor 0
        lLine[2] = 0x01 // low nibble 1 -> first L sample = 1 << 12 = 4096
        var rLine = silentLine()
        rLine[0] = 0
        rLine[2] = 0x02 // low nibble 2 -> first R sample = 2 << 12 = 8192

        let data = Data(lLine + rLine)
        let (left, right) = ADPCMDecoder.toPCMStereo(data, interleaveBytes: 16)
        XCTAssertEqual(left.count, 28)
        XCTAssertEqual(right.count, 28)
        XCTAssertEqual(left.first, 4096)
        XCTAssertEqual(right.first, 8192)
    }

    func testStereoBlockInterleaveGroupsMultipleLinesPerChannel() {
        // interleave = 32 (two lines per block): [L,L][R,R], every line in
        // the L block should end up in `left`, every line in the R block in
        // `right`, in original order.
        var l0 = silentLine(); l0[0] = 0; l0[2] = 0x01
        var l1 = silentLine(); l1[0] = 0; l1[2] = 0x03
        var r0 = silentLine(); r0[0] = 0; r0[2] = 0x02
        var r1 = silentLine(); r1[0] = 0; r1[2] = 0x04

        let data = Data(l0 + l1 + r0 + r1)
        let (left, right) = ADPCMDecoder.toPCMStereo(data, interleaveBytes: 32)
        XCTAssertEqual(left.count, 56)
        XCTAssertEqual(right.count, 56)
        XCTAssertEqual(left[0], 1 << 12)
        XCTAssertEqual(left[28], 3 << 12)
        XCTAssertEqual(right[0], 2 << 12)
        XCTAssertEqual(right[28], 4 << 12)
    }

    func testStereoStopsOnEitherChannelsEndOfStreamFlag() {
        let lLine = silentLine(flag: 7) // end-of-stream on L
        let rLine = silentLine(flag: 0)
        let data = Data(lLine + rLine)
        let (left, right) = ADPCMDecoder.toPCMStereo(data, interleaveBytes: 16)
        XCTAssertTrue(left.isEmpty)
        XCTAssertTrue(right.isEmpty)
    }

    /// Real, preserved discrepancy vs. `toPCMMono`: stereo termination
    /// checks the flag byte for exact equality to `1`, not a bitwise `& 1`
    ///, flag value `3` (bits 0 and 1 both set) must NOT stop stereo
    /// decoding early, even though it would trip `toPCMMono`'s bitwise
    /// check.
    func testStereoTerminationIsExactEqualityNotBitwise() {
        var lLine = silentLine(flag: 3) // LoopEnd | Unknown, not exactly 1
        var rLine = silentLine(flag: 0)
        var lLine2 = silentLine(flag: 0)
        var rLine2 = silentLine(flag: 0)
        lLine[0] = 0; lLine2[0] = 0
        let data = Data(lLine + rLine + lLine2 + rLine2)
        let (left, right) = ADPCMDecoder.toPCMStereo(data, interleaveBytes: 16)
        // Both line-pairs decode (flag 3 doesn't terminate stereo decode).
        XCTAssertEqual(left.count, 56)
        XCTAssertEqual(right.count, 56)
    }

    func testStereoTerminatesOnExactFlagValueOne() {
        var lLine = silentLine(flag: 1)
        var rLine = silentLine(flag: 0)
        var lLine2 = silentLine(flag: 0)
        var rLine2 = silentLine(flag: 0)
        lLine[0] = 0; lLine2[0] = 0
        let data = Data(lLine + rLine + lLine2 + rLine2)
        let (left, right) = ADPCMDecoder.toPCMStereo(data, interleaveBytes: 16)
        // First line-pair decodes, then stops (L's flag is exactly 1).
        XCTAssertEqual(left.count, 28)
        XCTAssertEqual(right.count, 28)
    }

    /// A sustained loud nibble (7, the max positive 4-bit value) through
    /// predict=4's amplifying coefficients (122/64, -60/64) overshoots
    /// Int16 range by the second sample -- a real, reachable case on loud
    /// game audio, not a synthetic edge case. The correct decode of the
    /// second sample is exactly `Int16.max` (83328, clamped); the old
    /// `truncatingIfNeeded` bug wrapped that same raw value to `17792`
    /// instead -- a real, audible difference, not a no-op check.
    func testLoudPredictorOvershootClampsRatherThanWraps() {
        var line = [UInt8](repeating: 0x77, count: 16) // every nibble = 7
        line[0] = 0x40 // predict=4, factor=0
        line[1] = 0 // not a terminator
        let pcm = ADPCMDecoder.toPCMMono(Data(line))
        XCTAssertEqual(pcm.count, 28)
        XCTAssertEqual(pcm[0], 28672, "first sample has no predictor history yet, so it's unaffected by the clamp fix -- confirms the fixture itself is set up as expected")
        XCTAssertEqual(pcm[1], Int16.max, "raw predictor math for this sample is exactly 83328, which must clamp to Int16.max, not wrap to 17792")
    }

    func testStereoRejectsInvalidSizeAndInterleaveRatherThanTrapping() {
        XCTAssertEqual(ADPCMDecoder.toPCMStereo(Data([0, 0, 0]), interleaveBytes: 16).left, [])
        XCTAssertEqual(ADPCMDecoder.toPCMStereo(Data(repeating: 0, count: 32), interleaveBytes: 0).left, [])
        XCTAssertEqual(ADPCMDecoder.toPCMStereo(Data(repeating: 0, count: 32), interleaveBytes: 5).left, [])
    }
}
