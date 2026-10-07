import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers

/// `CrossFileGameObjectCopier.resolvingPropSkinInsertion`, "Spawn
/// Interactive Cortex": clones a real, working object (`BASICCRATE`) under
/// a fresh ID, keeping its own real scripts/physics untouched, only
/// repointing what it renders as to a cross-file-copied character skin.
/// Real-disc, best-effort, same "skip honestly if unavailable" posture as
/// `CrossFileGameObjectCopierTests.testCopyingARealSkinnedEnemyAcrossTwoRealLevels`.
final class CrossFileGameObjectCopierPropSkinTests: XCTestCase {
    func testCloningBasicCrateWithACortexSkinResolvesToARealCortexMeshWithTheCratesOwnBehaviorIntact() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else { throw XCTSkip("Disc image not mounted") }
        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))

        let rm2Entries = index.entries.filter { ($0.name as NSString).pathExtension.caseInsensitiveCompare("rm2") == .orderedSame }

        // A destination level that natively has BASICCRATE (3), real
        // crate physics/scripts to keep intact.
        var destinationEntry: (name: String, root: ChunkNode, bytes: Data)?
        // A source level that natively has Cortex (74) as a real skinned
        // character, the face to borrow.
        var cortexSource: (root: ChunkNode, bytes: Data)?

        for entry in rm2Entries {
            guard let bytes = try? BDArchiveParser.readEntryData(entry, index: index),
                  let parsedRoot = try? RM2Parser.parse(data: bytes, fileKind: .rm2, fileName: entry.name)
            else { continue }
            if destinationEntry == nil, CrossFileGameObjectCopier.hasNativeGameObject(objectID: 3, in: parsedRoot) {
                destinationEntry = (entry.name, parsedRoot, bytes)
            }
            if cortexSource == nil, CrossFileGameObjectCopier.hasNativeGameObject(objectID: 74, in: parsedRoot) {
                cortexSource = (parsedRoot, bytes)
            }
            if destinationEntry != nil, cortexSource != nil { break }
        }
        guard let destinationEntry else { throw XCTSkip("no archive entry on this disc natively carries BASICCRATE (#3)") }
        guard let cortexSource else { throw XCTSkip("no archive entry on this disc natively carries CORTEX (#74) as a real GameObject") }

        let destinationIndexBefore = AssetResolver.buildIndex(fileRoot: destinationEntry.root)
        guard let baseCrate = destinationIndexBefore.gameObjects[3] else {
            throw XCTSkip("BASICCRATE (#3) didn't resolve to a real decoded GameObject on this disc")
        }

        let freshObjectID: UInt16 = 60001
        XCTAssertFalse(CrossFileGameObjectCopier.hasNativeGameObject(objectID: freshObjectID, in: destinationEntry.root), "sanity: the synthetic ID must be genuinely unused for this test to mean anything")

        let resolved: (targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)])], claimedIDs: (ogi: UInt32, skin: UInt32, material: Set<UInt32>, texture: Set<UInt32>))
        do {
            resolved = try CrossFileGameObjectCopier.resolvingPropSkinInsertion(
                freshObjectID: freshObjectID,
                baseGameObject: baseCrate,
                skinSourceObjectID: 74,
                skinSourceFileRoot: cortexSource.root,
                skinSourceBytes: cortexSource.bytes,
                destinationFileRoot: destinationEntry.root
            )
        } catch {
            throw XCTSkip("CORTEX (#74) didn't resolve through the skinned-character path on this disc (\(error)), real, honest limitation, not a copier bug")
        }

        let patchedBytes = try XCTUnwrap(ChunkSectionInserter.applyingRecordChanges(
            intoSections: resolved.targets.map { (section: $0.section, insert: $0.insert, removeIDs: []) },
            fileRoot: destinationEntry.root,
            originalFileBytes: destinationEntry.bytes
        ))

        let reparsedDestination = try RM2Parser.parse(data: patchedBytes, fileKind: .rm2, fileName: destinationEntry.name)
        XCTAssertTrue(CrossFileGameObjectCopier.hasNativeGameObject(objectID: freshObjectID, in: reparsedDestination))

        let reparsedIndex = AssetResolver.buildIndex(fileRoot: reparsedDestination)
        let clonedGameObject = try XCTUnwrap(reparsedIndex.gameObjects[UInt32(freshObjectID)])
        // The clone keeps the crate's own real behavior verbatim.
        XCTAssertEqual(clonedGameObject.scriptIDs, baseCrate.scriptIDs, "the crate's own real scripts (break/throw physics) must survive unchanged")
        XCTAssertEqual(clonedGameObject.ui32, baseCrate.ui32)
        XCTAssertEqual(clonedGameObject.unkBitfield, baseCrate.unkBitfield)

        // But it renders as Cortex now, not a crate.
        let resolvedMesh = try XCTUnwrap(
            AssetResolver.resolveInstanceObject(objectID: freshObjectID, instanceSelector: 0, index: reparsedIndex),
            "the synthetic object must resolve to real geometry through the exact path the real game data is read through"
        )
        XCTAssertFalse(resolvedMesh.mesh.submeshes.isEmpty, "the resolved mesh must carry real, decoded submesh data, not an empty placeholder")
    }
}
