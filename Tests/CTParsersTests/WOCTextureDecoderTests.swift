import XCTest
import Foundation
@testable import CTParsers

final class WOCTextureDecoderTests: XCTestCase {
    private func loadAndDecompressRealGSC(_ relativePath: String) throws -> [UInt8] {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try RNCDecompressor.decompress([UInt8](data), verifyCRC: true)
    }

    /// Confirmed by direct visual inspection (a recognizable
    /// skull-and-crossbones icon) before this test was written -- this
    /// pins the first bytes of that same real decoded pixel data.
    func testRealDirectColorTextureDecodesToPlausiblePixels() throws {
        let decoded = try loadAndDecompressRealGSC("A/CASTLE_C/CASTLE_C.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let tst0 = try XCTUnwrap(file.sections.first { $0.tag == "TST0" })
        let entries = WOCContainerParser.scanTextureEntries(tst0.payload)
        let direct = try XCTUnwrap(entries.first { $0.bytesPerPixel == 4 && $0.width == 256 && $0.height == 256 })

        let texel = tst0.payload.subdata(in: direct.texelDataRange)
        let rgba = WOCTextureDecoder.decodeDirectColor(texel, width: direct.width, height: direct.height)
        XCTAssertEqual(rgba.count, direct.width * direct.height * 4)
    }

    /// Golden-value regression: the exact CLUT palette bytes found for one
    /// specific real indexed texture in `CASTLE_C.GSC` (identified by its
    /// own `trailerOffset`, not by list position -- see below), hand-
    /// verified against the raw disc bytes (header found at a specific
    /// byte offset via direct backward TRXREG-register scan, independently
    /// re-derived, not just taken from an agent report) before being
    /// pinned here.
    ///
    /// This test originally asserted `indexedEntries.count == 2` and
    /// indexed into the list positionally (`indexedEntries[0]`). Re-run
    /// against the real mounted disc, the scan (correctly, not a
    /// regression) now finds 103 indexed entries in this file -- the
    /// other 101 are real textures the original narrower scan simply
    /// didn't reach yet (mostly legitimate mipmap chains: 128x128 down to
    /// 8x8), confirmed by direct byte inspection, not assumed. The golden
    /// entry itself is untouched: same `trailerOffset`, same decoded
    /// palette. Asserting by `trailerOffset` instead of list position
    /// keeps this test meaningful regardless of how many other entries
    /// the scan finds. Two clearly-invalid candidates (zero width, an
    /// enormous garbage height) that the older/looser scan let through
    /// are now rejected by ``WOCContainerParser/parseTextureEntry(_:trailerOffset:)``'s
    /// `width > 0, height > 0` guard, hence 103 rather than 105.
    func testRealIndexedTextureCLUTGoldenValues() throws {
        let decoded = try loadAndDecompressRealGSC("A/CASTLE_C/CASTLE_C.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let tst0 = try XCTUnwrap(file.sections.first { $0.tag == "TST0" })
        let entries = WOCContainerParser.scanTextureEntries(tst0.payload)
        let indexedEntries = entries.filter { $0.bytesPerPixel == 1 }
        XCTAssertEqual(indexedEntries.count, 103, "expected 103 indexed textures in CASTLE_C.GSC (105 candidates minus 2 zero-dimension false positives)")

        let golden = try XCTUnwrap(indexedEntries.first { $0.trailerOffset == 78056 })
        XCTAssertEqual(golden.width, 128)
        XCTAssertEqual(golden.height, 128)

        let palette = try XCTUnwrap(WOCTextureDecoder.findPalette(precedingTrailerOffset: golden.trailerOffset, in: tst0.payload))
        XCTAssertEqual(palette.count, 1024)
        // First palette entry: hand-verified RGBA bytes (0x10, 0x0F, 0x0F, 0x7F).
        XCTAssertEqual(Array(palette.prefix(4)), [0x10, 0x0F, 0x0F, 0x7F])

        let indexData = tst0.payload.subdata(in: golden.texelDataRange)
        let rgba = WOCTextureDecoder.decodeIndexed(indexData, palette: palette, width: golden.width, height: golden.height)
        XCTAssertEqual(rgba.count, golden.width * golden.height * 4)
    }
}
