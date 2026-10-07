import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// "Parity Phase L": `TextureXWriter.replacingPixelData`, byte-exact
/// round-trip of an unmodified raw-uncompressed `TextureX` record, plus a
/// real pixel-value change that survives a reparse.
final class TextureXWriterTests: XCTestCase {
    /// Builds a minimal, well-formed raw-uncompressed `TextureX` record:
    /// a 2×2 texture, matching `TextureXParser.parse`'s exact field order.
    private func makeRecordBytes(pixels: [[UInt8]]) -> Data {
        var w = BinaryWriter()
        w.writeInt32(0) // texSize
        w.writeInt32(0) // unkInt
        w.writeInt16(1) // wLog2 -> width 2
        w.writeInt16(1) // hLog2 -> height 2
        w.writeUInt8(1) // m
        w.writeUInt8(0) // format
        w.writeUInt8(0) // destinationFormat
        w.writeUInt8(0) // texColComponent
        w.writeUInt8(0) // unkByte
        w.writeUInt8(0) // textureFun
        w.writeBytes([UInt8](repeating: 0, count: 2)) // unkBytes
        w.writeInt32(0) // textureBasePointer
        for _ in 0..<6 { w.writeInt32(0) } // mipLevelsTBP
        w.writeInt32(0) // textureBufferWidth
        for _ in 0..<6 { w.writeInt32(0) } // mipLevelsTBW
        w.writeInt32(0) // clutBufferBasePointer
        w.writeBytes([0, 0, 0, 0, 0x84, 0, 0, 0]) // unkBytes2, [4] == 0x84, no trailing-padding quirk
        w.writeBytes([UInt8](repeating: 0, count: 0x2C)) // HeaderAdd
        w.writeUInt32(0) // textureType == 0 -> raw uncompressed

        // Pixel data: bottom-up rows of on-disk B,G,R,A, `pixels` is
        // given top-down RGBA per `TextureAsset.rgba`'s own convention,
        // so this writes them in the parser's expected on-disk order.
        for y in stride(from: 1, through: 0, by: -1) {
            for x in 0..<2 {
                let rgba = pixels[y * 2 + x]
                w.writeUInt8(rgba[2]) // B
                w.writeUInt8(rgba[1]) // G
                w.writeUInt8(rgba[0]) // R
                w.writeUInt8(rgba[3]) // A
            }
        }
        return w.data
    }

    private let samplePixels: [[UInt8]] = [
        [255, 0, 0, 255], [0, 255, 0, 255],
        [0, 0, 255, 255], [255, 255, 0, 128]
    ]

    func testUnmodifiedRawTextureEncodeRoundTripsByteExact() throws {
        let originalBytes = makeRecordBytes(pixels: samplePixels)
        var cursor = BinaryCursor(data: originalBytes)
        let texture = try TextureXParser.parse(&cursor, recordID: 1)
        XCTAssertEqual(texture.pixelFormat, .rawRGBA)
        XCTAssertEqual(texture.width, 2)
        XCTAssertEqual(texture.height, 2)

        let encoded = try TextureXWriter.replacingPixelData(of: texture, inOriginalRecordBytes: originalBytes)
        XCTAssertEqual([UInt8](encoded), [UInt8](originalBytes))
    }

    func testReplacedPixelsReparseCorrectly() throws {
        let originalBytes = makeRecordBytes(pixels: samplePixels)
        var cursor = BinaryCursor(data: originalBytes)
        let texture = try TextureXParser.parse(&cursor, recordID: 1)

        var newRGBA = texture.rgba
        // Overwrite the whole 2x2 image to solid white.
        for i in stride(from: 0, to: newRGBA.count, by: 4) {
            newRGBA[i] = 255; newRGBA[i + 1] = 255; newRGBA[i + 2] = 255; newRGBA[i + 3] = 255
        }
        let replacement = TextureAsset(id: texture.id, width: texture.width, height: texture.height, pixelFormat: .rawRGBA, rgba: newRGBA)
        let encoded = try TextureXWriter.replacingPixelData(of: replacement, inOriginalRecordBytes: originalBytes)
        XCTAssertEqual(encoded.count, originalBytes.count)

        var reparseCursor = BinaryCursor(data: encoded)
        let reparsed = try TextureXParser.parse(&reparseCursor, recordID: 1)
        XCTAssertEqual(reparsed.rgba, newRGBA)
    }
}
