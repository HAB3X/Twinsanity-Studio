import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class TextureWriterPSMT8Tests: XCTestCase {
    /// Mirrors `TextureParserTests.synthesizeHeader`, a syntactically
    /// valid 224-byte PS2 texture record header followed by pixel data.
    /// `pixelData`'s actual content doesn't matter for these tests: it's
    /// only ever used to size the record correctly before
    /// `TextureWriter.replacingPixelData` overwrites it entirely.
    private func synthesizeHeader(width: Int, height: Int, format: UInt8, textureBufferWidth: Int32, clutBufferBasePointer: Int32, rrw: Int32, rrh: Int32, pixelData: [UInt8]) -> Data {
        var w = BinaryWriter()
        let texSize = Int32(224 + pixelData.count)
        w.writeInt32(texSize)
        w.writeInt32(0) // unkInt
        w.writeInt16(Int16(log2(Double(width))))
        w.writeInt16(Int16(log2(Double(height))))
        w.writeUInt8(1) // m
        w.writeUInt8(format)
        w.writeUInt8(format) // destinationFormat
        w.writeUInt8(1) // texColComponent
        w.writeUInt8(0) // unkByte
        w.writeUInt8(0) // textureFun
        w.writeBytes([0, 0]) // unkBytes
        w.writeInt32(0) // textureBasePointer
        for _ in 0..<6 { w.writeInt32(0) } // mipLevelsTBP
        w.writeInt32(textureBufferWidth)
        for _ in 0..<6 { w.writeInt32(0) } // mipLevelsTBW
        w.writeInt32(clutBufferBasePointer)
        w.writeBytes([UInt8](repeating: 0, count: 8)) // unkBytes2
        w.writeInt32(0) // reserved
        w.writeInt32(0) // reserved
        w.writeBytes([0, 0]) // unkBytes3
        w.writeBytes([0, 0]) // reserved
        w.writeBytes([UInt8](repeating: 0, count: 32)) // unusedMetadata
        var vifBlock = [UInt8](repeating: 0, count: 96)
        withUnsafeBytes(of: rrw.littleEndian) { vifBlock.replaceSubrange(48..<52, with: $0) }
        withUnsafeBytes(of: rrh.littleEndian) { vifBlock.replaceSubrange(52..<56, with: $0) }
        w.writeBytes(vifBlock)
        w.writeBytes(pixelData)
        return w.data
    }

    private static let psmt8Format: UInt8 = 0b010011

    /// `pixelDataLength` for a PSMCT32-addressed rectangle of `rrw`x`rrh`
    /// texels, the same convention `TextureParser.parse` reads
    /// (`texSize - 224`) and `encodePSMT8` writes back out via
    /// `readTexPSMCT32`.
    private func pixelDataLength(rrw: Int, rrh: Int) -> Int { rrw * rrh * 4 }

    /// A real texture with genuinely few unique colors (well under 256)
    /// should round-trip through quantize -> swizzle -> unswizzle ->
    /// palette-apply losslessly, no color in the source image should be
    /// perceptibly different after a full encode/decode cycle, since
    /// median-cut never needs to merge two colors together when the color
    /// budget isn't exceeded.
    func testFewColorImageRoundTripsLosslesslyThroughEncodeAndDecode() throws {
        let width = 16, height = 16
        // Four solid, distinct colors in a 2x2-quadrant pattern -- a
        // simple, real "sprite with flat color regions" shape, not
        // synthetic noise. Alpha values are all even: the GS hardware
        // only stores 7 bits of alpha (`decodePSMCT32`/`decodePalette`
        // widen it `<< 1`), so an odd 8-bit alpha is physically
        // unrepresentable and can never round-trip exactly -- not
        // something any encoder can fix, and not a value a real decoded
        // texture could ever contain in the first place (every real
        // `TextureAsset.rgba` this app produces already only has even
        // alpha for exactly this reason).
        let colors: [[UInt8]] = [
            [255, 0, 0, 254],
            [0, 255, 0, 254],
            [0, 0, 255, 200],
            [255, 255, 0, 0]
        ]
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let quadrant = (x < width / 2 ? 0 : 1) + (y < height / 2 ? 0 : 2)
                let o = (y * width + x) * 4
                let c = colors[quadrant]
                rgba[o] = c[0]; rgba[o + 1] = c[1]; rgba[o + 2] = c[2]; rgba[o + 3] = c[3]
            }
        }

        // `rrw`/`rrh` (the real GS transfer rectangle) has to be padded up
        // to at least one full PSMCT32 page height (32 texels) beyond the
        // logical `width`/`height` -- not just match them -- for
        // `clutBufferBasePointer` to land somewhere the transfer
        // rectangle's own swizzle addressing can actually reach. A real
        // Twinsanity texture header always has this padding (see
        // `TextureWriter.FixedHeaderFields.rrw`'s own doc comment on why
        // it's tracked separately from `width`/`height`); a fixture that
        // sets `rrw`/`rrh` equal to the logical size describes a texture
        // whose own declared CLUT position is physically unreachable, not
        // a real encode bug -- `clutBufferBasePointer: 8` needs `rrh` past
        // block-row 2 (y >= 16) to be inside the addressable footprint at
        // all, and this test's fixture (`rrh: height` = 16) put it right
        // at that boundary, one row short.
        let rrh: Int32 = 32
        let originalLength = pixelDataLength(rrw: width, rrh: Int(rrh))
        let record = synthesizeHeader(
            width: width, height: height, format: Self.psmt8Format,
            textureBufferWidth: 2, clutBufferBasePointer: 8,
            rrw: Int32(width), rrh: rrh,
            pixelData: [UInt8](repeating: 0, count: originalLength)
        )

        var cursor = BinaryCursor(data: record)
        var asset = try TextureParser.parse(&cursor, recordID: 7)
        XCTAssertEqual(asset.pixelFormat, .psmt8)
        asset.rgba = rgba

        let rebuilt = try TextureWriter.replacingPixelData(of: asset, inOriginalRecordBytes: record)
        XCTAssertEqual(rebuilt.count, record.count, "encodePSMT8 must reproduce exactly the same pixel-data length, never resize the record.")
        XCTAssertEqual(rebuilt.prefix(224), record.prefix(224), "Header bytes must be untouched.")

        var reparseCursor = BinaryCursor(data: rebuilt)
        let redecoded = try TextureParser.parse(&reparseCursor, recordID: 7)
        XCTAssertEqual(redecoded.rgba, rgba, "A <=256-color image must round-trip through quantize/swizzle/unswizzle without any color loss.")
    }

    /// A single solid color is the simplest possible real case -- every
    /// pixel maps to the same one palette entry.
    func testSolidColorImageRoundTripsExactly() throws {
        let width = 8, height = 8
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            // Alpha 254, not 255 -- see the doc comment on
            // `testFewColorImageRoundTripsLosslesslyThroughEncodeAndDecode`'s
            // `colors` array for why an odd alpha can never round-trip
            // through the GS's real 7-bit alpha storage.
            rgba[i * 4] = 128; rgba[i * 4 + 1] = 64; rgba[i * 4 + 2] = 200; rgba[i * 4 + 3] = 254
        }

        // Same real GS-addressing constraint as the fixture note in
        // `testFewColorImageRoundTripsLosslesslyThroughEncodeAndDecode`
        // above -- `rrh` has to be padded past the CLUT's own
        // block-swizzle footprint, not just match the logical `height`.
        let rrh: Int32 = 32
        let originalLength = pixelDataLength(rrw: width, rrh: Int(rrh))
        let record = synthesizeHeader(
            width: width, height: height, format: Self.psmt8Format,
            textureBufferWidth: 2, clutBufferBasePointer: 8,
            rrw: Int32(width), rrh: rrh,
            pixelData: [UInt8](repeating: 0, count: originalLength)
        )

        var cursor = BinaryCursor(data: record)
        var asset = try TextureParser.parse(&cursor, recordID: 3)
        asset.rgba = rgba

        let rebuilt = try TextureWriter.replacingPixelData(of: asset, inOriginalRecordBytes: record)
        var reparseCursor = BinaryCursor(data: rebuilt)
        let redecoded = try TextureParser.parse(&reparseCursor, recordID: 3)
        XCTAssertEqual(redecoded.rgba, rgba)
    }

    /// `PSMT8Quantizer` on its own, without any GS swizzling involved --
    /// confirms the quantizer's own contract (<=256 colors in, <=256
    /// palette entries out, every pixel's nearest color is itself when the
    /// color budget isn't exceeded) independent of the texture-format
    /// plumbing around it.
    func testQuantizerReturnsExactPaletteWhenUnderBudget() {
        let pixelColors: [[UInt8]] = [[10, 20, 30, 255], [200, 100, 50, 128], [0, 0, 0, 0]]
        var rgba: [UInt8] = []
        for c in pixelColors { rgba.append(contentsOf: c) }
        for c in pixelColors.reversed() { rgba.append(contentsOf: c) } // 6 pixels, 3 unique colors

        let (palette, indices) = PSMT8Quantizer.quantize(rgba: rgba, pixelCount: 6)
        XCTAssertEqual(palette.count, 3)
        XCTAssertEqual(indices.count, 6)
        for (i, index) in indices.enumerated() {
            let expectedColor = pixelColors[i < 3 ? i : 5 - i]
            XCTAssertEqual(palette[Int(index)], expectedColor)
        }
    }

    func testUnsupportedFormatStillThrows() {
        let record = synthesizeHeader(width: 2, height: 2, format: 0b000010, textureBufferWidth: 1, clutBufferBasePointer: 0, rrw: 2, rrh: 2, pixelData: [UInt8](repeating: 0, count: 16))
        let asset = TextureAsset(id: 1, width: 2, height: 2, pixelFormat: .psmct16, rgba: [UInt8](repeating: 0, count: 16))
        XCTAssertThrowsError(try TextureWriter.replacingPixelData(of: asset, inOriginalRecordBytes: record)) { error in
            XCTAssertTrue(error is TextureWriter.TextureWriteError)
        }
    }
}
