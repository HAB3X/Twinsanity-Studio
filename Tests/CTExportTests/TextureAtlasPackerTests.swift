import XCTest
import CTModels
@testable import CTExport

final class TextureAtlasPackerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func solidTexture(id: UInt32, width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> TextureAsset {
        var rgba: [UInt8] = []
        rgba.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) { rgba += [r, g, b, 255] }
        return TextureAsset(id: id, width: width, height: height, pixelFormat: .psmct32, rgba: rgba)
    }

    func testPackPlacesEveryTextureWithNoOverlaps() {
        let textures = [
            solidTexture(id: 1, width: 64, height: 64, r: 255, g: 0, b: 0),
            solidTexture(id: 2, width: 32, height: 96, r: 0, g: 255, b: 0),
            solidTexture(id: 3, width: 48, height: 48, r: 0, g: 0, b: 255)
        ]
        let layout = TextureAtlasPacker.pack(textures, maxWidth: 2048)
        XCTAssertEqual(layout.placements.count, 3)

        // No two placements overlap.
        for i in 0..<layout.placements.count {
            for j in (i + 1)..<layout.placements.count {
                let a = layout.placements[i], b = layout.placements[j]
                let overlaps = a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
                XCTAssertFalse(overlaps, "placements for texture \(a.textureID) and \(b.textureID) overlap")
            }
        }

        // Every placement fits inside the reported atlas bounds.
        for placement in layout.placements {
            XCTAssertLessThanOrEqual(placement.x + placement.width, layout.atlasWidth)
            XCTAssertLessThanOrEqual(placement.y + placement.height, layout.atlasHeight)
        }
    }

    func testPackWrapsToANewShelfWhenMaxWidthIsExceeded() {
        let textures = [
            solidTexture(id: 1, width: 100, height: 50, r: 255, g: 0, b: 0),
            solidTexture(id: 2, width: 100, height: 50, r: 0, g: 255, b: 0),
            solidTexture(id: 3, width: 100, height: 50, r: 0, g: 0, b: 255)
        ]
        // Only 2 (100+100=200) fit per row at maxWidth 250; the 3rd (which
        // would make 300) must wrap to a new shelf.
        let layout = TextureAtlasPacker.pack(textures, maxWidth: 250)
        XCTAssertGreaterThan(layout.atlasHeight, 50, "a third texture that doesn't fit the first row must start a new shelf below it")
        let distinctYs = Set(layout.placements.map { $0.y })
        XCTAssertEqual(distinctYs.count, 2, "expected exactly 2 shelves (rows) for 3 same-size textures at this maxWidth")
    }

    func testRenderAtlasPreservesRealPixelColorsAtEachPlacement() throws {
        let red = solidTexture(id: 1, width: 4, height: 4, r: 255, g: 0, b: 0)
        let blue = solidTexture(id: 2, width: 4, height: 4, r: 0, g: 0, b: 255)
        let layout = TextureAtlasPacker.pack([red, blue])
        let atlas = try TextureAtlasPacker.renderAtlas([red, blue], placements: layout.placements, atlasWidth: layout.atlasWidth, atlasHeight: layout.atlasHeight)

        guard let data = atlas.dataProvider?.data as Data? else { return XCTFail("no pixel data in composited atlas") }
        let bytesPerRow = atlas.bytesPerRow
        func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = y * bytesPerRow + x * 4
            return (data[data.startIndex + offset], data[data.startIndex + offset + 1], data[data.startIndex + offset + 2])
        }

        for placement in layout.placements {
            let expected: (UInt8, UInt8, UInt8) = placement.textureID == red.id ? (255, 0, 0) : (0, 0, 255)
            // Sample the center of this placement's real region.
            let sample = pixel(x: placement.x + placement.width / 2, y: placement.y + placement.height / 2)
            XCTAssertEqual(sample.0, expected.0, "texture \(placement.textureID) red channel")
            XCTAssertEqual(sample.1, expected.1, "texture \(placement.textureID) green channel")
            XCTAssertEqual(sample.2, expected.2, "texture \(placement.textureID) blue channel")
        }
    }

    func testNormalizedUVRectIsCorrectFraction() {
        let placement = AtlasPlacement(textureID: 1, x: 64, y: 0, width: 64, height: 32)
        let (origin, size) = placement.normalizedUVRect(atlasWidth: 128, atlasHeight: 64)
        XCTAssertEqual(origin.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(origin.y, 0.0, accuracy: 0.0001)
        XCTAssertEqual(size.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(size.y, 0.5, accuracy: 0.0001)
    }

    func testExportAtlasWritesAReadablePNG() throws {
        let textures = [
            solidTexture(id: 1, width: 16, height: 16, r: 255, g: 0, b: 0),
            solidTexture(id: 2, width: 16, height: 16, r: 0, g: 255, b: 0)
        ]
        let url = tempDir.appendingPathComponent("atlas.png")
        let layout = try TextureAtlasPacker.exportAtlas(textures, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(layout.placements.count, 2)
    }

    func testEmptyTextureListThrows() {
        XCTAssertThrowsError(try TextureAtlasPacker.exportAtlas([], to: tempDir.appendingPathComponent("empty.png"))) { error in
            XCTAssertEqual(error as? TextureAtlasError, .noTextures)
        }
    }
}
