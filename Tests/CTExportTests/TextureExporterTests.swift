import XCTest
import CTModels
@testable import CTExport

final class TextureExporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeAsset() -> TextureAsset {
        // 2x2 checkerboard, straight alpha.
        let rgba: [UInt8] = [
            255, 0, 0, 255,   0, 255, 0, 255,
            0, 0, 255, 255,   255, 255, 0, 128
        ]
        return TextureAsset(id: 1, width: 2, height: 2, pixelFormat: .psmct32, rgba: rgba)
    }

    func testCGImageHasExpectedDimensions() throws {
        let image = try TextureExporter.cgImage(from: makeAsset())
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
    }

    func testExportPNGWritesAReadableFile() throws {
        let url = tempDir.appendingPathComponent("test.png")
        try TextureExporter.exportPNG(makeAsset(), to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 8)
        // PNG magic bytes.
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    func testExportAllLevelsWritesBasePlusMips() throws {
        var asset = makeAsset()
        asset.mips = [[128, 128, 128, 255]] // 1x1 mip
        let written = try TextureExporter.exportAllLevels(asset, baseName: "tex", to: tempDir)
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testInvalidMipLevelThrows() {
        XCTAssertThrowsError(try TextureExporter.cgImage(from: makeAsset(), mipLevel: 0))
    }

    func testPNGDataMatchesExportPNGBytes() throws {
        let url = tempDir.appendingPathComponent("test.png")
        try TextureExporter.exportPNG(makeAsset(), to: url)
        let fromDisk = try Data(contentsOf: url)

        let inMemory = try TextureExporter.pngData(makeAsset())
        XCTAssertEqual(inMemory, fromDisk)
    }
}
