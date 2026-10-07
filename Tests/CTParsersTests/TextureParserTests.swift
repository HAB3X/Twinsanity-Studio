import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class TextureParserTests: XCTestCase {
    /// Builds a syntactically valid 224-byte PS2 texture header (every field
    /// present in on-disk order) followed by `pixelData`, matching
    /// `Texture.Load`'s exact field layout.
    private func synthesizeHeader(width: Int, height: Int, mipCount: Int, format: UInt8, textureBufferWidth: Int32, clutBufferBasePointer: Int32, mipTBP: [Int32] = Array(repeating: 0, count: 6), mipTBW: [Int32] = Array(repeating: 0, count: 6), rrw: Int32, rrh: Int32, pixelData: [UInt8]) -> Data {
        var w = BinaryWriter()
        let texSize = Int32(224 + pixelData.count)
        w.writeInt32(texSize)
        w.writeInt32(0) // unkInt
        w.writeInt16(Int16(log2(Double(width)))) // w (log2)
        w.writeInt16(Int16(log2(Double(height)))) // h (log2)
        w.writeUInt8(UInt8(mipCount + 1)) // m
        w.writeUInt8(format)
        w.writeUInt8(format) // destinationFormat
        w.writeUInt8(1) // texColComponent (RGBA)
        w.writeUInt8(0) // unkByte
        w.writeUInt8(0) // textureFun
        w.writeBytes([0, 0]) // unkBytes
        w.writeInt32(0) // textureBasePointer
        for v in mipTBP { w.writeInt32(v) }
        w.writeInt32(textureBufferWidth)
        for v in mipTBW { w.writeInt32(v) }
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

    func testPSMCT32FullDecodeAndAlphaWidening() throws {
        // 2x1 texture, two solid pixels: opaque red, half-alpha green.
        // GS alpha is 7-bit (0...128); the decoder doubles it into 0...255.
        let pixelData: [UInt8] = [
            255, 0, 0, 128,   // R,G,B, alpha(7-bit)=128 -> 256 clamped to 255
            0, 255, 0, 64     // alpha(7-bit)=64 -> 128
        ]
        let data = synthesizeHeader(width: 2, height: 1, mipCount: 0, format: 0b000000, textureBufferWidth: 1, clutBufferBasePointer: 0, rrw: 2, rrh: 1, pixelData: pixelData)
        var cursor = BinaryCursor(data: data)
        let texture = try TextureParser.parse(&cursor, recordID: 7)

        XCTAssertEqual(texture.id, 7)
        XCTAssertEqual(texture.width, 2)
        XCTAssertEqual(texture.height, 1)
        XCTAssertEqual(texture.pixelFormat, .psmct32)
        XCTAssertEqual(Array(texture.rgba[0...3]), [255, 0, 0, 255])
        XCTAssertEqual(Array(texture.rgba[4...7]), [0, 255, 0, 128])
    }

    func testPSMT8SwizzleAddressingRoundTrips() {
        // EzSwizzle is internal, this exercises the ported PSMT8 address LUTs
        // directly (write via PSMT8 addressing, read back via the same
        // addressing) to guard against transcription errors in the tables,
        // independent of the full bus-transfer/palette-colocation dance
        // TextureParser performs for real on-disk data.
        let width = 32, height = 32
        let indexes = (0..<(width * height)).map { UInt8($0 % 251) }
        let ez = EzSwizzle()
        ez.cleanGs()
        ez.writeTexPSMT8(dbp: 0, dbwIn: 2, dsax: 0, dsay: 0, rrw: width, rrh: height, data: indexes)

        var readBack = [UInt8](repeating: 0, count: width * height)
        ez.readTexPSMT8(dbp: 0, dbwIn: 2, dsax: 0, dsay: 0, rrw: width, rrh: height, into: &readBack)

        XCTAssertEqual(readBack, indexes)
    }

    func testPSMCT32SwizzleAddressingRoundTrips() {
        let width = 16, height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<pixels.count { pixels[i] = UInt8((i * 7) % 256) }
        let ez = EzSwizzle()
        ez.cleanGs()
        ez.writeTexPSMCT32(dbp: 0, dbw: 1, dsax: 0, dsay: 0, rrw: width, rrh: height, data: pixels)

        var readBack = [UInt8](repeating: 0, count: pixels.count)
        ez.readTexPSMCT32(dbp: 0, dbw: 1, dsax: 0, dsay: 0, rrw: width, rrh: height, into: &readBack)

        XCTAssertEqual(readBack, pixels)
    }

    /// A corrupt/truncated record could carry a huge `wLog2`/`hLog2` (they're
    /// just two `Int16`s off disk), `width`/`height` (`1 << wLog2`) are
    /// themselves safe to compute (Swift's `<<` never traps), but a later
    /// `width * height` easily overflows `Int`, and Swift's `*` traps
    /// (crashes) on overflow rather than throwing. This must throw a normal,
    /// catchable error instead of crashing the process.
    func testImplausiblyLargeDimensionsThrowInsteadOfCrashing() {
        let data = synthesizeHeader(width: 1 << 20, height: 1 << 20, mipCount: 0, format: 0b000000, textureBufferWidth: 1, clutBufferBasePointer: 0, rrw: 2, rrh: 2, pixelData: [])
        var cursor = BinaryCursor(data: data)
        XCTAssertThrowsError(try TextureParser.parse(&cursor, recordID: 1)) { error in
            guard case TextureParseError.implausibleDimensions = error else {
                return XCTFail("expected implausibleDimensions, got \(error)")
            }
        }
    }

    func testUnsupportedFormatFallsBackToRawPassthrough() throws {
        let pixelData: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        // PSMCT16 (0b000010) is not fully decoded by this build, matching the reference tool.
        let data = synthesizeHeader(width: 2, height: 1, mipCount: 0, format: 0b000010, textureBufferWidth: 1, clutBufferBasePointer: 0, rrw: 2, rrh: 1, pixelData: pixelData)
        var cursor = BinaryCursor(data: data)
        let texture = try TextureParser.parse(&cursor, recordID: 1)
        XCTAssertEqual(texture.pixelFormat, .psmct16)
        XCTAssertFalse(texture.pixelFormat.isFullyDecoded)
    }
}
