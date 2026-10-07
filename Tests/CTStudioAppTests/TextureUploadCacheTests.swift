import XCTest
import Metal
@testable import CTModels
@testable import CTStudioApp

/// "Massive level rendering" (performance mandate): confirms
/// `TextureUploadCache` actually prevents redundant GPU texture uploads
/// for repeated placements sharing the same real texture ID, the
/// concrete, confirmed bottleneck this cache exists to fix (see its own
/// doc comment in ModelViewerRenderer.swift).
final class TextureUploadCacheTests: XCTestCase {
    private func makeTestTexture(id: UInt32) -> TextureAsset {
        TextureAsset(id: id, width: 2, height: 2, pixelFormat: .psmct32, rgba: [UInt8](repeating: 128, count: 16))
    }

    func testSameTextureIDReusesTheSameMTLTextureWhenCached() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let cache = TextureUploadCache()
        let asset = makeTestTexture(id: 7)

        let first = try XCTUnwrap(ModelViewerRenderer.makeTexture(device: device, asset: asset, cache: cache))
        let second = try XCTUnwrap(ModelViewerRenderer.makeTexture(device: device, asset: asset, cache: cache))

        XCTAssertTrue(first === second, "a second upload of the same real texture ID through a shared cache must reuse the same MTLTexture, not allocate a new one")
    }

    func testDifferentTextureIDsGetDistinctTextures() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let cache = TextureUploadCache()
        let first = try XCTUnwrap(ModelViewerRenderer.makeTexture(device: device, asset: makeTestTexture(id: 1), cache: cache))
        let second = try XCTUnwrap(ModelViewerRenderer.makeTexture(device: device, asset: makeTestTexture(id: 2), cache: cache))
        XCTAssertFalse(first === second, "distinct real texture IDs must never share a cached MTLTexture")
    }

    /// Without a cache (the existing single-object Model Viewer path,
    /// which passes `cache: nil`), behavior is unchanged from before this
    /// fix, every call uploads its own independent texture.
    func testNoCacheMeansNoSharing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestTexture(id: 7)
        let first = try XCTUnwrap(ModelViewerRenderer.makeTexture(device: device, asset: asset))
        let second = try XCTUnwrap(ModelViewerRenderer.makeTexture(device: device, asset: asset))
        XCTAssertFalse(first === second, "with no cache passed, each call must still independently upload, this must not become a hidden always-on global cache")
    }
}
