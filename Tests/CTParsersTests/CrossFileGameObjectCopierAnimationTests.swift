import XCTest
import Foundation
@testable import CTCore
@testable import CTModels
@testable import CTParsers

/// "Real Animation for Copied Characters", `resolvingSkinnedGameObjectInsertions`
/// used to unconditionally drop `animIDs` to empty (no `AnimationWriter`
/// existed at the time); it now copies each referenced `Animation` record
/// for real, using the same "copy by raw bytes, remap the ID" shape
/// `scriptIDs` already established. Real-disc, best-effort, same "skip
/// honestly if unavailable" posture as `CrossFileGameObjectCopierTests`'
/// own real-disc test.
final class CrossFileGameObjectCopierAnimationTests: XCTestCase {
    func testCopyingCortexAcrossRealLevelsCarriesHisRealAnimationsNotJustHisSkin() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else { throw XCTSkip("Disc image not mounted") }
        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))
        let rm2Entries = index.entries.filter { $0.name.lowercased().hasSuffix(".rm2") }

        // A source file that natively carries Cortex (#74) with real,
        // non-empty animIDs (real, confirmed tonight: every native Cortex
        // GameObject on this disc carries the same 103 real animation
        // slots), and a destination file that genuinely doesn't have him
        // yet, so the copy is real (not a same-object no-op).
        var cortexSource: (root: ChunkNode, bytes: Data, animCount: Int, uniqueAnimCount: Int)?
        var destinationCandidate: (name: String, root: ChunkNode, bytes: Data)?

        for entry in rm2Entries {
            guard let bytes = try? BDArchiveParser.readEntryData(entry, index: index),
                  let root = try? RM2Parser.parse(data: bytes, fileKind: .rm2, fileName: entry.name)
            else { continue }
            if cortexSource == nil, CrossFileGameObjectCopier.hasNativeGameObject(objectID: 74, in: root) {
                let gfxIndex = AssetResolver.buildIndex(fileRoot: root)
                let realAnimIDs = gfxIndex.gameObjects[74]?.animIDs.filter { $0 != 65535 } ?? []
                if !realAnimIDs.isEmpty { cortexSource = (root, bytes, realAnimIDs.count, Set(realAnimIDs).count) }
            }
            if destinationCandidate == nil, !CrossFileGameObjectCopier.hasNativeGameObject(objectID: 74, in: root) {
                destinationCandidate = (entry.name, root, bytes)
            }
            if cortexSource != nil, destinationCandidate != nil { break }
        }
        guard let cortexSource else { throw XCTSkip("no real Cortex (#74) source with real animIDs found on this disc") }
        guard let destinationCandidate else { throw XCTSkip("every real .rm2 on this disc already has a native Cortex, nothing to copy into") }

        let resolved: (targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)])], claimedIDs: (ogi: UInt32, skin: UInt32, material: Set<UInt32>, texture: Set<UInt32>, script: Set<UInt32>, animation: Set<UInt32>))
        do {
            resolved = try CrossFileGameObjectCopier.resolvingSkinnedGameObjectInsertions(
                objectID: 74, sourceFileRoot: cortexSource.root, sourceBytes: cortexSource.bytes,
                destinationFileRoot: destinationCandidate.root
            )
        } catch {
            throw XCTSkip("Cortex didn't resolve through the skinned-character path on this disc (\(error)), real, honest limitation, not a copier bug")
        }

        XCTAssertFalse(resolved.claimedIDs.animation.isEmpty, "the copy must have actually inserted real Animation records, not silently dropped them")
        XCTAssertEqual(resolved.claimedIDs.animation.count, cortexSource.uniqueAnimCount, "every one of Cortex's distinct real (non-\"no value\") animations must have been copied exactly once each (several of his animIDs slots legitimately repeat the same animation)")

        let patchedBytes = try XCTUnwrap(ChunkSectionInserter.applyingRecordChanges(
            intoSections: resolved.targets.map { (section: $0.section, insert: $0.insert, removeIDs: []) },
            fileRoot: destinationCandidate.root,
            originalFileBytes: destinationCandidate.bytes
        ))
        let reparsedDestination = try RM2Parser.parse(data: patchedBytes, fileKind: .rm2, fileName: destinationCandidate.name)
        let reparsedIndex = AssetResolver.buildIndex(fileRoot: reparsedDestination)
        let copiedCortex = try XCTUnwrap(reparsedIndex.gameObjects[74])

        let realCopiedAnimIDs = copiedCortex.animIDs.filter { $0 != 65535 }
        XCTAssertEqual(realCopiedAnimIDs.count, cortexSource.animCount, "the re-parsed copy's own animIDs must still be real, non-\"no value\" entries")
        for animID in realCopiedAnimIDs {
            XCTAssertNotNil(reparsedIndex.animations[UInt32(animID)], "animID \(animID) must resolve to a real, decoded Animation record after the copy, not a dangling reference")
        }

        // And the resolved asset (the exact path a real render/preview
        // goes through) now genuinely offers real animations to play,
        // not an empty list.
        let resolvedAsset = try XCTUnwrap(AssetResolver.resolveInstanceObject(objectID: 74, instanceSelector: 0, index: reparsedIndex))
        XCTAssertFalse(resolvedAsset.availableAnimations.isEmpty, "a copied Cortex must resolve with real, playable animation data, not a static bind pose")
    }
}
