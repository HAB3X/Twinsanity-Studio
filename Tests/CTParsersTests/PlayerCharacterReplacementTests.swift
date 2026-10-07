import XCTest
import Foundation
@testable import CTCore
@testable import CTModels
@testable import CTParsers

/// `CrossFileGameObjectCopier.resolvingPlayerCharacterReplacement` against
/// real disc data: replacing Beach's own GameObject id 0 (Crash) with
/// Cortex's real playable rig from `l10chasb.rm2`, in place -- no Instance
/// changes needed, since Beach's existing Crash Instance already points at
/// id 0. Proves the id-0 replacement itself, and that at least one of
/// Cortex's real `linkedIDs.objects` (his weapon, `MULTITOOL`) gets copied
/// in alongside him.
final class PlayerCharacterReplacementTests: XCTestCase {
    func testReplacingBeachCrashWithCortexInPlaceCarriesHisWeapon() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else { throw XCTSkip("Disc not mounted") }
        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))

        func entry(named bareName: String) -> ArchiveEntry? {
            index.entries.first { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare(bareName) == .orderedSame }
        }
        guard let cortexEntry = entry(named: "l10chasb.rm2") else { throw XCTSkip("l10chasb.rm2 not found") }
        guard let beachEntry = entry(named: "beach.rm2") else { throw XCTSkip("beach.rm2 not found") }

        let cortexBytes = try BDArchiveParser.readEntryData(cortexEntry, index: index)
        let cortexRoot = try RM2Parser.parse(data: cortexBytes, fileKind: .rm2, fileName: cortexEntry.name)
        let beachBytes = try BDArchiveParser.readEntryData(beachEntry, index: index)
        let beachRoot = try RM2Parser.parse(data: beachBytes, fileKind: .rm2, fileName: beachEntry.name)

        XCTAssertTrue(CrossFileGameObjectCopier.hasNativeGameObject(objectID: 0, in: beachRoot), "Beach must already have a real GameObject 0 (Crash) for this to be a real replacement, not an insert")
        XCTAssertFalse(CrossFileGameObjectCopier.hasNativeGameObject(objectID: 74, in: beachRoot), "Beach must not already carry Cortex natively")

        let resolved = try CrossFileGameObjectCopier.resolvingPlayerCharacterReplacement(
            replacingObjectID: 0, withRealCharacter: 74,
            sourceFileRoot: cortexRoot, sourceBytes: cortexBytes,
            destinationFileRoot: beachRoot
        )
        XCTAssertFalse(resolved.targets.isEmpty)

        guard let inserted = ChunkSectionInserter.applyingRecordChanges(
            intoSections: resolved.targets, fileRoot: beachRoot, originalFileBytes: beachBytes
        ) else { return XCTFail("insertion failed") }

        let reparsed = try RM2Parser.parse(data: inserted, fileKind: .rm2, fileName: "beach.rm2")
        var gameObjects: [UInt32: GameObjectInfo] = [:]
        func walk(_ node: ChunkNode) {
            if case .gameObject(let g) = node.payload { gameObjects[node.recordID] = g }
            for c in node.children { walk(c) }
        }
        walk(reparsed)

        guard let replaced = gameObjects[0] else { return XCTFail("GameObject id 0 missing after replacement") }
        XCTAssertTrue(replaced.name.uppercased().contains("CORTEX"), "GameObject id 0 must now be Cortex's own real data, got name=\(replaced.name)")
        XCTAssertGreaterThan(replaced.animIDs.filter { $0 != 65535 }.count, 20, "the replaced object 0 must carry Cortex's own real animations, not a stub")

        // No stray GameObject left behind at id 74 -- the source ID was
        // only ever a temporary landing spot, fully redirected to 0.
        XCTAssertNil(gameObjects[74], "no leftover GameObject should remain at id 74")

        // Cortex's real weapon must copy in -- `MULTITOOL` (id 27) is a
        // pure rigid-prop GameObject (skinID == 0, geometry entirely via
        // modelLinks), which `resolvingSkinnedGameObjectInsertions` now
        // handles instead of silently dropping.
        XCTAssertTrue(resolved.copiedLinkedObjectIDs.contains(27) || gameObjects[27] != nil, "Cortex's own MULTITOOL weapon (id 27) should copy in as a rigid prop")
        for copiedID in resolved.copiedLinkedObjectIDs {
            XCTAssertNotNil(gameObjects[UInt32(copiedID)], "linked object #\(copiedID) reported copied but not actually present after re-parse")
        }
        print("copiedLinkedObjectIDs=\(resolved.copiedLinkedObjectIDs)")
    }
}
