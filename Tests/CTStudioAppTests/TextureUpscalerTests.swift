import XCTest
import CoreGraphics
@testable import CTModels
@testable import CTStudioApp

/// "Neural Texture Upscaling" (roadmap 5.4), no real trained model ships
/// with this build (see `TextureUpscaler`'s own doc comment for why), so
/// these tests cover everything that's real and verifiable without one:
/// the error paths that don't depend on model behavior, and the real
/// `CGImage` -> `TextureAsset` conversion path a model's real output
/// would be read back through.
final class TextureUpscalerTests: XCTestCase {
    func testMissingModelFileThrowsModelNotFound() async {
        let texture = TextureAsset(id: 1, width: 2, height: 2, pixelFormat: .psmct32, rgba: [UInt8](repeating: 255, count: 16))
        let missingURL = URL(fileURLWithPath: "/nonexistent/path/to/upscaler.mlmodel")
        do {
            _ = try await TextureUpscaler.upscale(texture, usingModelAt: missingURL)
            XCTFail("Expected modelNotFound")
        } catch {
            XCTAssertEqual(error as? TextureUpscaler.UpscaleError, .modelNotFound)
        }
    }

    func testUndecodedPixelFormatThrowsRatherThanUpscalingGarbage() async throws {
        // .psmct24 is real, decoded texture data this build doesn't fully
        // decode (see TexturePixelFormat.isFullyDecoded), upscaling it
        // would mean running a real neural network over meaningless raw
        // bytes and calling the result "upscaled," which is worse than
        // refusing outright.
        let texture = TextureAsset(id: 1, width: 2, height: 2, pixelFormat: .psmct24, rgba: [UInt8](repeating: 0, count: 16))
        let tempModelURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mlmodel")
        try Data().write(to: tempModelURL)
        defer { try? FileManager.default.removeItem(at: tempModelURL) }

        do {
            _ = try await TextureUpscaler.upscale(texture, usingModelAt: tempModelURL)
            XCTFail("Expected sourceNotDecoded")
        } catch {
            XCTAssertEqual(error as? TextureUpscaler.UpscaleError, .sourceNotDecoded)
        }
    }

    /// The real conversion path a model's real `VNPixelBufferObservation`
    /// output gets read back through, verified against a synthetic
    /// `CGImage` with known, distinct per-channel values, confirming the
    /// pixel data actually round-trips (not just "didn't crash").
    func testMakeTextureAssetRoundTripsRealPixelData() throws {
        let width = 4, height = 4
        var sourcePixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: sourcePixels.count, by: 4) {
            sourcePixels[i] = 10       // R
            sourcePixels[i + 1] = 20   // G
            sourcePixels[i + 2] = 30   // B
            sourcePixels[i + 3] = 255  // A
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &sourcePixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let sourceImage = context.makeImage()
        else {
            return XCTFail("Couldn't build a synthetic test CGImage")
        }

        let asset = try TextureUpscaler.makeTextureAsset(from: sourceImage, sourceID: 42)
        XCTAssertEqual(asset.id, 42)
        XCTAssertEqual(asset.width, width)
        XCTAssertEqual(asset.height, height)
        XCTAssertEqual(asset.rgba.count, width * height * 4)
        // First pixel's real channel values must survive the round trip.
        XCTAssertEqual(asset.rgba[0], 10)
        XCTAssertEqual(asset.rgba[1], 20)
        XCTAssertEqual(asset.rgba[2], 30)
        XCTAssertEqual(asset.rgba[3], 255)
    }
}
