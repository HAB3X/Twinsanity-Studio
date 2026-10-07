import XCTest
@testable import CTParsers

final class ADPCMEncoderTests: XCTestCase {
    func testEmptyInputProducesJustTheTerminatorLine() {
        let encoded = ADPCMEncoder.fromPCMMono([])
        XCTAssertEqual(encoded.count, 16)
        XCTAssertEqual(Array(encoded)[1], 7, "second byte of the sole line must be the end-of-stream flag")
    }

    func testOutputIsAlwaysAWholeNumberOfSixteenByteLines() {
        for sampleCount in [1, 27, 28, 29, 100, 3584, 4000] {
            let pcm = [Int16](repeating: 1000, count: sampleCount)
            let encoded = ADPCMEncoder.fromPCMMono(pcm)
            XCTAssertEqual(encoded.count % 16, 0, "sampleCount=\(sampleCount)")
        }
    }

    func testEncodedStreamEndsWithTheTerminatorLine() {
        let pcm = [Int16](repeating: 500, count: 56)
        let encoded = Array(ADPCMEncoder.fromPCMMono(pcm))
        // `.suffix` preserves the original (non-zero-based) indices, so
        // re-wrap in Array to get a plain 0-based slice to index into.
        let lastLine = Array(encoded.suffix(16))
        XCTAssertEqual(lastLine[1], 7)
        XCTAssertTrue(lastLine.dropFirst(2).allSatisfy { $0 == 0 })
    }

    /// Silence is the one signal this lossy codec must reproduce exactly:
    /// predictor 0 (no history contribution) and factor 0 (no shift) is
    /// always a legal, exact encoding of an all-zero block, and
    /// `findPredict`'s search should land on it since it trivially
    /// minimizes quantization error for a silent block.
    func testSilencePCMRoundTripsExactly() {
        let pcm = [Int16](repeating: 0, count: 28 * 3)
        let encoded = ADPCMEncoder.fromPCMMono(pcm)
        let decoded = ADPCMDecoder.toPCMMono(encoded)
        XCTAssertEqual(decoded, pcm)
    }

    /// Not a lossless codec, this pins "close to the original," not
    /// byte-identical, the same standard a lossy audio round trip should be
    /// held to.
    func testRoundTripStaysCloseToOriginalForARealSignal() {
        let sampleCount = 280
        let pcm: [Int16] = (0..<sampleCount).map { i in
            Int16(Double(Int16.max) * 0.5 * sin(2 * .pi * Double(i) / 32.0))
        }
        let encoded = ADPCMEncoder.fromPCMMono(pcm)
        let decoded = ADPCMDecoder.toPCMMono(encoded)

        XCTAssertEqual(decoded.count, pcm.count)
        var maxError = 0
        for (original, reconstructed) in zip(pcm, decoded) {
            maxError = max(maxError, abs(Int(original) - Int(reconstructed)))
        }
        XCTAssertLessThan(maxError, 2000, "reconstructed samples should stay reasonably close to the original sine wave")
    }

    /// A block spanning the encoder's internal 3584-sample scratch-buffer
    /// boundary must not glitch at the seam, this is real, since the
    /// reference algorithm re-fills a fixed-size buffer in chunks and this
    /// exercises exactly that chunk boundary.
    func testHandlesInputLargerThanTheInternalBufferSize() {
        let pcm = [Int16](repeating: 0, count: 128 * 28 + 100)
        let encoded = ADPCMEncoder.fromPCMMono(pcm)
        let decoded = ADPCMDecoder.toPCMMono(encoded)
        XCTAssertGreaterThanOrEqual(decoded.count, pcm.count)
        XCTAssertTrue(decoded.prefix(pcm.count).allSatisfy { $0 == 0 })
    }
}
