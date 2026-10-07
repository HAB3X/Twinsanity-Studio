import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class TextureWriterTests: XCTestCase {
    /// Mirrors `TextureParserTests.synthesizeHeader`, a syntactically
    /// valid 224-byte PS2 texture record header followed by pixel data.
    private func synthesizeRecord(width: Int, height: Int, format: UInt8, pixelData: [UInt8]) -> Data {
        var w = BinaryWriter()
        let texSize = Int32(224 + pixelData.count)
        w.writeInt32(texSize)
        w.writeInt32(0)
        w.writeInt16(Int16(log2(Double(width))))
        w.writeInt16(Int16(log2(Double(height))))
        w.writeUInt8(1)
        w.writeUInt8(format)
        w.writeUInt8(format)
        w.writeUInt8(1)
        w.writeUInt8(0)
        w.writeUInt8(0)
        w.writeBytes([0, 0])
        w.writeInt32(0)
        for _ in 0..<6 { w.writeInt32(0) }
        w.writeInt32(Int32(width))
        for _ in 0..<6 { w.writeInt32(0) }
        w.writeInt32(0)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0)
        w.writeInt32(0)
        w.writeBytes([0, 0])
        w.writeBytes([0, 0])
        w.writeBytes([UInt8](repeating: 0, count: 32))
        var vifBlock = [UInt8](repeating: 0, count: 96)
        withUnsafeBytes(of: Int32(width).littleEndian) { vifBlock.replaceSubrange(48..<52, with: $0) }
        withUnsafeBytes(of: Int32(height).littleEndian) { vifBlock.replaceSubrange(52..<56, with: $0) }
        w.writeBytes(vifBlock)
        w.writeBytes(pixelData)
        return w.data
    }

    func testEncodePSMCT32IsExactInverseOfDecode() throws {
        // Alpha values kept within the true 7-bit GS range (0...127): 128 is
        // an out-of-range edge `decodePSMCT32` itself clamps to 255, which
        // `encodePSMCT32` can't invert back to 128, see
        // testAlpha128IsALossyClampEdgeNotARoundTripBug below.
        let originalPixels: [UInt8] = [
            255, 0, 0, 127,
            0, 255, 0, 64,
            10, 20, 30, 0,
            1, 2, 3, 100
        ]
        let record = synthesizeRecord(width: 2, height: 2, format: 0b000000, pixelData: originalPixels)
        var cursor = BinaryCursor(data: record)
        let decoded = try TextureParser.parse(&cursor, recordID: 42)

        let rebuilt = try TextureWriter.replacingPixelData(of: decoded, inOriginalRecordBytes: record)
        XCTAssertEqual(rebuilt, record, "Re-encoding the untouched decode should reproduce the original record byte-for-byte.")

        var reparseCursor = BinaryCursor(data: rebuilt)
        let redecoded = try TextureParser.parse(&reparseCursor, recordID: 42)
        XCTAssertEqual(redecoded.rgba, decoded.rgba)
    }

    func testReplacingPixelDataPreservesHeaderAndChangesOnlyPixels() throws {
        let originalPixels: [UInt8] = [255, 255, 255, 128, 0, 0, 0, 128]
        let record = synthesizeRecord(width: 2, height: 1, format: 0b000000, pixelData: originalPixels)
        var cursor = BinaryCursor(data: record)
        var decoded = try TextureParser.parse(&cursor, recordID: 1)

        // Replace with solid blue, fully opaque.
        decoded.rgba = [0, 0, 255, 255, 0, 0, 255, 255]
        let rebuilt = try TextureWriter.replacingPixelData(of: decoded, inOriginalRecordBytes: record)

        XCTAssertEqual(rebuilt.count, record.count)
        XCTAssertEqual(rebuilt.prefix(228), record.prefix(228), "Header bytes must be untouched.")

        var reparseCursor = BinaryCursor(data: rebuilt)
        let redecoded = try TextureParser.parse(&reparseCursor, recordID: 1)
        XCTAssertEqual(Array(redecoded.rgba[0...3]), [0, 0, 255, 254]) // 255 -> 127 (>>1) -> 254 (<<1)
    }

    /// `decodePSMCT32` treats raw alpha 128 as an out-of-true-7-bit-range
    /// edge case, clamping `128 << 1` down to 255 instead of overflowing , 
    /// `encodePSMCT32` can only invert values that decode *without*
    /// clamping (0...127 -> 0...254 even), so re-encoding a decoded 255
    /// always yields 127, not the original 128. This is a pre-existing
    /// quirk of the decoder this codebase already ships (not something the
    /// encoder introduces), documented here so it doesn't look like a
    /// round-trip regression later.
    func testAlpha128IsALossyClampEdgeNotARoundTripBug() throws {
        let record = synthesizeRecord(width: 1, height: 1, format: 0b000000, pixelData: [10, 20, 30, 128])
        var cursor = BinaryCursor(data: record)
        let decoded = try TextureParser.parse(&cursor, recordID: 1)
        XCTAssertEqual(decoded.rgba, [10, 20, 30, 255])

        let rebuilt = try TextureWriter.replacingPixelData(of: decoded, inOriginalRecordBytes: record)
        XCTAssertEqual(Array(rebuilt.suffix(4)), [10, 20, 30, 127], "127, not the original 128, see doc comment.")
    }

    /// `.psmt8` used to be the case this checked (before `encodePSMT8`
    /// existed, every non-PSMCT32 format threw `.unsupportedFormat`) , 
    /// now that it has a real, verified encode (`TextureWriterPSMT8Tests`),
    /// this checks a format that's still genuinely unimplemented instead,
    /// same as `TextureWriterPSMT8Tests.testUnsupportedFormatStillThrows`.
    func testUnsupportedFormatThrows() {
        let asset = TextureAsset(id: 1, width: 1, height: 1, pixelFormat: .psmct16, rgba: [0, 0, 0, 255])
        XCTAssertThrowsError(try TextureWriter.replacingPixelData(of: asset, inOriginalRecordBytes: Data(repeating: 0, count: 228))) { error in
            XCTAssertTrue(error is TextureWriter.TextureWriteError)
        }
    }

    func testMismatchedDimensionsThrows() {
        // Original record has 8 bytes of pixel data (2x1 RGBA), asset has only 4.
        let record = synthesizeRecord(width: 2, height: 1, format: 0b000000, pixelData: [1, 2, 3, 4, 5, 6, 7, 8])
        let asset = TextureAsset(id: 1, width: 1, height: 1, pixelFormat: .psmct32, rgba: [1, 2, 3, 4])
        XCTAssertThrowsError(try TextureWriter.replacingPixelData(of: asset, inOriginalRecordBytes: record))
    }
}
