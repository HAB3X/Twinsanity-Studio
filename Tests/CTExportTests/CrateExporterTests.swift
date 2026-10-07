import XCTest
@testable import CTExport

final class CrateExporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func unzip(_ crateURL: URL) throws -> URL {
        let destination = tempDir.appendingPathComponent("unzipped-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", crateURL.path, "-d", destination.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return destination
    }

    func testExportSingleFileWritesManifestAndLayer0() throws {
        let crateURL = tempDir.appendingPathComponent("mod.crate")
        let metadata = CrateMetadata(name: "Test Mod", description: "desc", author: "me", version: "1.0", targetGame: "Crash Twinsanity")
        try CrateExporter.export(files: [(relativePath: "level.rm2", data: Data([1, 2, 3]))], metadata: metadata, to: crateURL)

        let unzipped = try unzip(crateURL)
        let manifest = try String(contentsOf: unzipped.appendingPathComponent("modcrateinfo.txt"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("Name=Test Mod"))
        XCTAssertTrue(manifest.contains("Author=me"))

        let layered = try Data(contentsOf: unzipped.appendingPathComponent("layer0/level.rm2"))
        XCTAssertEqual(layered, Data([1, 2, 3]))
    }

    /// "Cross-Object Dependency Packaging" (blueprint 3.2) relies on this
    /// already-existing multi-file capability, a crate with several real
    /// files (mesh, textures, animations) under one asset subfolder, not
    /// just the single edited file blueprint 3.3 originally exercised.
    func testExportMultipleFilesUnderSubfolderAllLandInLayer0() throws {
        let crateURL = tempDir.appendingPathComponent("mod.crate")
        let metadata = CrateMetadata(name: "Asset Bundle", description: "", author: "", version: "1.0", targetGame: "Crash Twinsanity")
        let files: [(relativePath: String, data: Data)] = [
            (relativePath: "Wumpa/Wumpa.obj", data: Data("obj-contents".utf8)),
            (relativePath: "Wumpa/Wumpa.mtl", data: Data("mtl-contents".utf8)),
            (relativePath: "Wumpa/texture_1.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
            (relativePath: "Wumpa/animations/animation_2.json", data: Data("{}".utf8))
        ]
        try CrateExporter.export(files: files, metadata: metadata, to: crateURL)

        let unzipped = try unzip(crateURL)
        for file in files {
            let onDisk = try Data(contentsOf: unzipped.appendingPathComponent("layer0").appendingPathComponent(file.relativePath))
            XCTAssertEqual(onDisk, file.data, "\(file.relativePath) round-tripped incorrectly")
        }
    }
}
