import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Regression tests for a real, reported bug class found in a consistency
/// sweep: `load(_:)`'s `.archiveIndex` case already guards against
/// reopening an already-open `.BH` (piling up duplicate "CRASH.BH (697
/// files)" trees was a real, severe reported bug), but two sibling entry
/// points that also append a new top-level root, a directly-opened loose
/// `.RM2`/`.SM2` (`applyLooseLevelFileResults`) and "Open as Monkey Ball"
/// (`openAsMonkeyBall`), had no equivalent guard at all. This pins that
/// reopening either now reuses the existing root instead of duplicating it.
@MainActor
final class DuplicateOpenPreventionTests: XCTestCase {
    private func makeSection(children: [(id: UInt32, bytes: Data)]) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(TwinsMagic.v1)
        writer.writeInt32(Int32(children.count))
        let contentSize = children.reduce(0) { $0 + $1.bytes.count }
        writer.writeUInt32(UInt32(contentSize))
        var offset = 12 + children.count * 12
        for child in children {
            writer.writeUInt32(UInt32(offset))
            writer.writeInt32(Int32(child.bytes.count))
            writer.writeUInt32(child.id)
            offset += child.bytes.count
        }
        for child in children {
            writer.writeBytes(child.bytes)
        }
        return writer.data
    }

    private func makeMinimalRM2Bytes() -> Data {
        let emptyCode = makeSection(children: [])
        return makeSection(children: [(0, makeSection(children: [])), (10, emptyCode)])
    }

    /// Same short, fixed-delay wait `DiscImageSidebarMergeTests` uses for
    /// this exact kind of "async load, then assert" case, `open(url:)`'s
    /// loose-file path always dispatches to a background `Task.detached`.
    private func waitForBackgroundLoad() async {
        let expectation = expectation(description: "background load completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 5)
    }

    func testReopeningTheSameLooseRM2FileDoesNotDuplicateTheRoot() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicateOpenPreventionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("beach.rm2")
        try makeMinimalRM2Bytes().write(to: fileURL)

        let workspace = WorkspaceViewModel()
        workspace.open(url: fileURL)
        await waitForBackgroundLoad()
        XCTAssertEqual(workspace.rootNodes.count, 1, "the first open should produce exactly one root")

        workspace.open(url: fileURL)
        await waitForBackgroundLoad()
        XCTAssertEqual(workspace.rootNodes.count, 1, "reopening the same already-open loose file must not duplicate the root")
    }

    func testReopeningTheSameFileAsMonkeyBallDoesNotDuplicateTheRoot() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicateOpenPreventionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("track.rm2")
        try makeMinimalRM2Bytes().write(to: fileURL)

        let workspace = WorkspaceViewModel()
        workspace.openAsMonkeyBall(url: fileURL)
        await waitForBackgroundLoad()
        XCTAssertEqual(workspace.rootNodes.count, 1, "the first Monkey Ball open should produce exactly one root")

        workspace.openAsMonkeyBall(url: fileURL)
        await waitForBackgroundLoad()
        XCTAssertEqual(workspace.rootNodes.count, 1, "reopening the same file as Monkey Ball again must not duplicate the root")
    }
}
