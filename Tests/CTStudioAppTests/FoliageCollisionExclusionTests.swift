import XCTest
@testable import CTModels
@testable import CTStudioApp

/// "On trees the leaves have no collision as it's not needed", real,
/// reported observation, confirmed against the real, hand-authored
/// `ColData` in `hubb.rm2` (measured: ~14-25 triangles per real collision
/// group vs. 70-800 per placed object's full render mesh). No per-submesh
/// semantic tag exists in this format, so `ModelViewerRenderer.
/// isMostlyTransparent` uses a real, measurable proxy instead: foliage/
/// cutout textures are overwhelmingly alpha-transparent where solid
/// geometry is not.
final class FoliageCollisionExclusionTests: XCTestCase {
    private func makeTexture(width: Int, height: Int, alpha: (Int, Int) -> UInt8) -> TextureAsset {
        var rgba: [UInt8] = []
        rgba.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                rgba.append(200); rgba.append(180); rgba.append(120) // RGB (irrelevant here)
                rgba.append(alpha(x, y))
            }
        }
        return TextureAsset(id: 1, width: width, height: height, pixelFormat: .psmct32, rgba: rgba)
    }

    func testFullyOpaqueTextureIsNotExcluded() {
        let texture = makeTexture(width: 16, height: 16) { _, _ in 255 }
        XCTAssertFalse(ModelViewerRenderer.isMostlyTransparent(texture), "an opaque texture (trunk, rock) must stay solid for collision")
    }

    func testMostlyTransparentCutoutTextureIsExcluded() {
        // A checkerboard-ish leaf cutout: most pixels transparent, a
        // minority opaque (the actual leaf shapes).
        let texture = makeTexture(width: 16, height: 16) { x, y in ((x + y) % 3 == 0) ? 255 : 0 }
        XCTAssertTrue(ModelViewerRenderer.isMostlyTransparent(texture), "a mostly-transparent cutout texture (foliage) must be excluded from collision")
    }

    func testTextureWithOnlyAMinorTransparentTrimIsNotExcluded() {
        // A mostly-solid texture with just a thin transparent border --
        // must not be misclassified as foliage.
        let texture = makeTexture(width: 20, height: 20) { x, y in
            (x == 0 || y == 0 || x == 19 || y == 19) ? 0 : 255
        }
        XCTAssertFalse(ModelViewerRenderer.isMostlyTransparent(texture), "a mostly-opaque texture with only a thin transparent trim must not be treated as foliage")
    }

    func testNilOrEmptyTextureIsNotExcluded() {
        XCTAssertFalse(ModelViewerRenderer.isMostlyTransparent(nil), "no texture at all must default to solid, never silently drop real collision")
        let empty = TextureAsset(id: 1, width: 0, height: 0, pixelFormat: .psmct32, rgba: [])
        XCTAssertFalse(ModelViewerRenderer.isMostlyTransparent(empty))
    }
}
