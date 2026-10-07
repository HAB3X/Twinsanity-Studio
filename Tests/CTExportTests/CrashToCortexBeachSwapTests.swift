import XCTest
import Foundation
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTExport

/// Real, requested task: replace Crash with Cortex, his own real
/// skin/scripts/animations/weapon, cross-file-copied in wherever a level
/// doesn't already carry him natively, on Beach and its connected chunks,
/// then boot the patched disc directly into Beach.
///
/// Targets `GameObject` id **0** in place, not a new id, see
/// `CrossFileGameObjectCopier.resolvingPlayerCharacterReplacement`'s own
/// doc comment for the real, evidence-based reasoning (a disc-wide scan
/// found every real, non-cutscene playable Crash rig sitting at id 0
/// across 91 independent level files, strong evidence the PS2 engine's own
/// Player-1 input binds to whatever occupies that id, not to which
/// `Instance` references a given object number). This needs **no**
/// `Instance` edits at all: every real Crash `Instance` on this disc
/// already points at id 0, so once that id's own content is Cortex,
/// existing placements just work.
///
/// "Connected chunks" walks the real `ChunkLinks` graph starting from
/// Beach's own `.sm2`, exactly the load-streaming data the game itself
/// uses to know which neighboring chunk files can be reached without a
/// full level reload.
final class CrashToCortexBeachSwapTests: XCTestCase {
    private static let cortexObjectID: UInt16 = 74
    private static let crashObjectID: UInt16 = 0

    func testReplacingCrashWithCortexOnBeachAndConnectedChunksAndBooting() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else { throw XCTSkip("Disc image not mounted") }
        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))

        func entry(named bareName: String) -> ArchiveEntry? {
            index.entries.first { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare(bareName) == .orderedSame }
        }
        func parse(_ e: ArchiveEntry) throws -> (root: ChunkNode, bytes: Data) {
            let bytes = try BDArchiveParser.readEntryData(e, index: index)
            let root = try RM2Parser.parse(data: bytes, fileKind: Self.fileKind(for: e.name), fileName: e.name)
            return (root, bytes)
        }

        guard let beachSM = entry(named: "beach.sm2") else { throw XCTSkip("beach.sm2 not found on this disc") }
        let (beachSMRoot, _) = try parse(beachSM)
        _ = beachSMRoot

        // BFS the real ChunkLinks graph from Beach.
        var visited: Set<String> = ["beach"]
        var queue: [String] = ["beach"]
        var chunkLinkSummary: [String: [String]] = [:]
        while !queue.isEmpty {
            let baseName = queue.removeFirst()
            guard let smEntry = entry(named: "\(baseName).sm2"), let (smRoot, _) = try? parse(smEntry) else { continue }
            let links = Self.chunkLinks(in: smRoot)
            let neighborBaseNames = links.map { (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() }
            chunkLinkSummary[baseName] = neighborBaseNames
            for neighbor in neighborBaseNames where !visited.contains(neighbor) {
                visited.insert(neighbor)
                queue.append(neighbor)
            }
        }
        print("CONNECTED CHUNKS FROM BEACH: \(visited.sorted())")
        for (chunk, neighbors) in chunkLinkSummary.sorted(by: { $0.key < $1.key }) {
            print("  \(chunk) -> \(neighbors)")
        }

        // The REAL playable co-op Cortex rig, not the generic NPC one:
        // real disc investigation found `l10chasb.rm2`'s own Cortex
        // GameObject is named "|L10chasB|act_CORTEX" (matching Crash's
        // own "|L10chasB|act_CRASH2" naming) with 89 real non-sentinel
        // ogiIDs -- a rich, Crash-like multi-skeleton-variant structure,
        // versus the generic NPC Cortex's mere 1. This is what the
        // game's own real 2-player co-op actually controls.
        guard let cortexSourceEntry = entry(named: "l10chasb.rm2") else { throw XCTSkip("l10chasb.rm2 (real playable Cortex source) not found") }
        let (cortexSourceRoot, cortexSourceBytes) = try parse(cortexSourceEntry)
        guard CrossFileGameObjectCopier.hasNativeGameObject(objectID: Self.cortexObjectID, in: cortexSourceRoot) else {
            throw XCTSkip("l10chasb.rm2 no longer carries a native Cortex on this disc")
        }

        var archiveReplacements: [String: Data] = [:]
        var filesTouched: [String] = []
        var totalLinkedObjectsCopied = 0

        for baseName in visited.sorted() {
            guard let rmEntry = entry(named: "\(baseName).rm2") else { continue } // scenery-only chunk, no actor file
            guard let (root, bytes) = try? parse(rmEntry) else { continue }

            // Only a file that already has a real GameObject 0 (a player
            // slot, on this file's own convention) has anything to
            // replace -- a chunk with no id 0 at all has no Crash to begin
            // with, nothing to swap.
            guard CrossFileGameObjectCopier.hasNativeGameObject(objectID: Self.crashObjectID, in: root) else {
                print("  [\(baseName)] no GameObject 0 (Crash) here -- nothing to replace")
                continue
            }
            guard !CrossFileGameObjectCopier.hasNativeGameObject(objectID: Self.cortexObjectID, in: root) else {
                print("  [\(baseName)] already has Cortex natively at #74 -- leaving id 0 as-is rather than guessing which is the real player slot")
                continue
            }

            do {
                let resolved = try CrossFileGameObjectCopier.resolvingPlayerCharacterReplacement(
                    replacingObjectID: Self.crashObjectID, withRealCharacter: Self.cortexObjectID,
                    sourceFileRoot: cortexSourceRoot, sourceBytes: cortexSourceBytes,
                    destinationFileRoot: root
                )
                guard let patched = ChunkSectionInserter.applyingRecordChanges(
                    intoSections: resolved.targets, fileRoot: root, originalFileBytes: bytes
                ) else {
                    print("  [\(baseName)] replacement insertion failed -- skipping this chunk")
                    continue
                }
                print("  [\(baseName)] replaced GameObject 0 (Crash) in place with Cortex's real rig -- linked objects copied: \(resolved.copiedLinkedObjectIDs.sorted())")
                totalLinkedObjectsCopied += resolved.copiedLinkedObjectIDs.count
                archiveReplacements[(rmEntry.name as NSString).lastPathComponent] = patched
                filesTouched.append(baseName)
            } catch {
                print("  [\(baseName)] couldn't replace Crash with Cortex (\(error)) -- leaving this chunk untouched")
                continue
            }
        }

        print("TOTAL: \(filesTouched.count) file(s) had GameObject 0 replaced in place, \(totalLinkedObjectsCopied) linked object(s) copied along the way: \(filesTouched.sorted())")
        guard !filesTouched.isEmpty else {
            throw XCTSkip("no file with a native GameObject 0 (Crash) found on Beach or its connected chunks -- nothing to boot")
        }

        // Build a real, verified, patched copy of the disc -- never the
        // original ISO file itself.
        let realISOPath = "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/Crash Twinsanity (Europe, Australia) (En,Fr,De,Es,It) copy 2.iso"
        guard FileManager.default.fileExists(atPath: realISOPath) else { throw XCTSkip("Real retail ISO not present at \(realISOPath)") }
        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("CrashToCortexBeachSwap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let plan = GameLaunchPlan(startingChunkBaseName: "beach", archiveReplacements: archiveReplacements)
        let result = try GameLauncher.rebuildingAndVerifying(isoURL: URL(fileURLWithPath: realISOPath), plan: plan, scratchDirectory: scratchDir)
        print("REBUILD DIAGNOSTICS: \(result.diagnostics)")
        XCTAssertFalse(result.exceedsSizeGrowthThreshold(), "patched disc grew more than expected, refusing to treat this as safe")

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("CrashTwinsanity-CortexOnBeach.iso")
        try? FileManager.default.removeItem(at: outputURL)
        try GameLauncher.writingVerified(result.data, to: outputURL)
        print("PATCHED ISO WRITTEN TO: \(outputURL.path)")

        guard ProcessInfo.processInfo.environment["CT_SKIP_PCSX2_LAUNCH"] == nil else {
            print("CT_SKIP_PCSX2_LAUNCH set, not launching PCSX2, patched ISO is ready at \(outputURL.path)")
            return
        }
        let pcsx2URL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/Reference Files/PCSX2-v2.6.3.app")
        if FileManager.default.fileExists(atPath: pcsx2URL.path) {
            try GameLauncher.launching(pcsx2AppURL: pcsx2URL, isoURL: outputURL)
            print("LAUNCHED PCSX2 WITH THE PATCHED DISC")
        } else {
            print("PCSX2 not found at expected path, patched ISO is ready at \(outputURL.path), launch it manually")
        }
    }

    private static func fileKind(for entryName: String) -> TwinsFileKind {
        switch (entryName as NSString).pathExtension.uppercased() {
        case "RMX": return .rmx
        case "SMX": return .smx
        case "SM2": return .sm2
        default: return .rm2
        }
    }

    private static func chunkLinks(in root: ChunkNode) -> [ChunkLink] {
        if case .chunkLinks(let asset) = root.payload { return asset.links }
        for child in root.children {
            let found = chunkLinks(in: child)
            if !found.isEmpty { return found }
        }
        return []
    }
}
