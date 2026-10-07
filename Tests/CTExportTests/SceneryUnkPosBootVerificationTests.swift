import XCTest
import simd
import CTCore
import CTExport
import CTParsers
import CTModels

/// Real-PCSX2-boot counterpart to `SceneryUnkPosRecomputeTests` (which
/// proves the recompute's real-disc-data coverage math in isolation, no
/// emulator involved). This test drives the *exact* production insertion
/// path `WorkspaceViewModel.patchedFileBytes(insertingNewScenery:)` uses , 
/// `SceneryGroup.insertingPlacementNearestExistingNeighbor` (nested-group
/// placement, not a blind root append) followed by
/// `SceneryGroup.recomputingUnkPosRecursively()` (the new group-level
/// culling-bound fix), then boots the resulting disc image in a real,
/// unmodified PCSX2, the same way every other edit shape in
/// `GameLauncherBootVerificationTests` is verified.
///
/// This can only prove the fixed data is *stable* (real module
/// registration, real accumulated play time, no corruption signature) , 
/// same limitation every other headless (`-batch -nogui`) boot test in this
/// codebase has: PCSX2 renders nothing in this mode, so no automated check
/// here can confirm the actual camera-angle-dependent flicker is visually
/// gone. That confirmation needs a real, windowed PCSX2 session, see this
/// test's own doc comment on what it does and doesn't prove.
final class SceneryUnkPosBootVerificationTests: XCTestCase {
    private static let pcsx2Binary = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/Reference Files/PCSX2-v2.6.3.app/Contents/MacOS/PCSX2")
    private static let retailISOURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/Crash Twinsanity (Europe, Australia) (En,Fr,De,Es,It).iso")

    func testInsertingSceneryViaNearestNeighborWithRecomputedUnkPosBootsInRealPCSX2() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("SceneryUnkPosBootVerificationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let isoData = try Data(contentsOf: Self.retailISOURL, options: .mappedIfSafe)
        let source = PlainISOSource(data: isoData)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        guard let (bhEntry, bdEntry) = Self.locateArchivePair(in: root) else {
            return XCTFail("no real .BH/.BD archive pair found on this disc")
        }
        guard let bhData = ISO9660Reader.readFile(bhEntry, from: source), let bdData = ISO9660Reader.readFile(bdEntry, from: source) else {
            return XCTFail("couldn't read the real archive pair back from the disc")
        }
        let readbackDir = scratchDir.appendingPathComponent("readback")
        try FileManager.default.createDirectory(at: readbackDir, withIntermediateDirectories: true)
        let tempBH = readbackDir.appendingPathComponent((bhEntry.name as NSString).lastPathComponent)
        let tempBD = readbackDir.appendingPathComponent((bdEntry.name as NSString).lastPathComponent)
        try bhData.write(to: tempBH)
        try bdData.write(to: tempBD)
        let index = try BDArchiveParser.readIndex(bhURL: tempBH)
        guard let beachSceneryEntry = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.sm2") == .orderedSame }) else {
            return XCTFail("beach.sm2 not found in this disc's real archive index")
        }
        let beachSceneryBytes = try BDArchiveParser.readEntryData(beachSceneryEntry, index: index)
        let beachSceneryRoot = try RM2Parser.parse(data: beachSceneryBytes, fileKind: .sm2, fileName: "beach.sm2")

        func findScenery(_ node: ChunkNode) -> ChunkNode? {
            if case .scenery = node.payload { return node }
            for child in node.children {
                if let found = findScenery(child) { return found }
            }
            return nil
        }
        guard let sceneryNode = findScenery(beachSceneryRoot), case .scenery(let sceneryAsset)? = sceneryNode.payload, let originalRoot = sceneryAsset.root else {
            return XCTFail("beach.sm2 has no real, decoded SceneryData tree, can't exercise this edit shape")
        }
        let originalPlacementCount = sceneryAsset.placements.count
        XCTAssertGreaterThan(originalPlacementCount, 0, "sanity: beach.sm2 must have at least one real existing placement")
        let templatePlacement = try XCTUnwrap(sceneryAsset.placements.first { !$0.isSpecial && $0.translation != nil })
        let anchorPosition = try XCTUnwrap(templatePlacement.translation)

        // The real bug scenario: a new placement dropped near a real
        // existing one, far enough from that existing group's own
        // (pre-edit) `unkPos` capsule that leaving it stale would leave
        // the new object outside it, exactly `insertingPlacementNearestExistingNeighbor`'s
        // own doc comment. Same production call this project's Scenery-tab
        // placement tool actually makes (`WorkspaceViewModel.patchedFileBytes(insertingNewScenery:)`).
        let newPosition = anchorPosition + SIMD3<Float>(15, 2, 15)
        let matrix = SceneryModelPlacement.composingModelMatrix(position: newPosition, rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), scale: SIMD3<Float>(1, 1, 1))
        let boundingPosition = SIMD4<Float>(newPosition, 1)
        let newPlacement = SceneryModelPlacement(
            modelID: templatePlacement.modelID, isSpecial: false,
            boundingBoxMin: boundingPosition - SIMD4<Float>(1, 1, 1, 0), boundingBoxMax: boundingPosition + SIMD4<Float>(1, 1, 1, 0),
            modelMatrix: matrix
        )
        var mutatedRoot = originalRoot.insertingPlacementNearestExistingNeighbor(newPlacement, targetPosition: newPosition)
        mutatedRoot.model.header = 0x1613
        // The scoped recompute production actually uses, see
        // `SceneryGroup.recomputingUnkPos(sinceEditFrom:)`'s own doc
        // comment for why the earlier, unconditional `recomputingUnkPosRecursively()`
        // call here was a real, reported regression (overwrote every real
        // group's `unkPos`, not just the touched one).
        mutatedRoot = mutatedRoot.recomputingUnkPos(sinceEditFrom: originalRoot)

        var mutatedScenery = sceneryAsset
        mutatedScenery.root = mutatedRoot
        let encodedScenery = SceneryDataWriter.encode(mutatedScenery)

        guard let modifiedBeachSceneryBytes = ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: beachSceneryRoot, insert: [(sceneryNode.recordID, encodedScenery)], removeIDs: [sceneryNode.recordID])],
            fileRoot: beachSceneryRoot, originalFileBytes: beachSceneryBytes
        ) else {
            return XCTFail("ChunkSectionInserter failed to splice the re-encoded SceneryData back in, a builder-side failure, not a PCSX2/emulator one")
        }
        XCTAssertNotEqual(modifiedBeachSceneryBytes, beachSceneryBytes, "sanity: the patch must have actually changed something")

        let plan = GameLaunchPlan(startingChunkBaseName: "beach", archiveReplacements: ["beach.sm2": modifiedBeachSceneryBytes])
        let built = try GameLauncher.building(isoURL: Self.retailISOURL, plan: plan, scratchDirectory: scratchDir)
        XCTAssertEqual(built.count % 2048, 0, "a real disc image is always a whole number of 2048-byte sectors")

        // Pre-flight, independent readback: confirm the built image really
        // carries one more real, decodable placement, AND that its
        // containing group's `unkPos` really does cover it (the same
        // coverage check `SceneryUnkPosRecomputeTests` already validated
        // against unmodified real disc data), before ever handing this to
        // PCSX2.
        let builtSource = PlainISOSource(data: built)
        let builtRoot = try ISO9660Reader.readRootDirectory(from: builtSource)
        guard let (builtBH, builtBD) = Self.locateArchivePair(in: builtRoot),
              let builtBHData = ISO9660Reader.readFile(builtBH, from: builtSource),
              let builtBDData = ISO9660Reader.readFile(builtBD, from: builtSource)
        else {
            return XCTFail("couldn't read the built image's own archive pair back")
        }
        let builtReadbackDir = scratchDir.appendingPathComponent("built-readback")
        try FileManager.default.createDirectory(at: builtReadbackDir, withIntermediateDirectories: true)
        let builtTempBH = builtReadbackDir.appendingPathComponent((builtBH.name as NSString).lastPathComponent)
        let builtTempBD = builtReadbackDir.appendingPathComponent((builtBD.name as NSString).lastPathComponent)
        try builtBHData.write(to: builtTempBH)
        try builtBDData.write(to: builtTempBD)
        let builtIndex = try BDArchiveParser.readIndex(bhURL: builtTempBH)
        guard let builtBeachSceneryEntry = builtIndex.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.sm2") == .orderedSame }) else {
            return XCTFail("beach.sm2 missing from the built image's own archive index")
        }
        let builtBeachSceneryBytes = try BDArchiveParser.readEntryData(builtBeachSceneryEntry, index: builtIndex)
        let reparsedBeachSceneryRoot = try RM2Parser.parse(data: builtBeachSceneryBytes, fileKind: .sm2, fileName: "beach.sm2")
        guard let reparsedSceneryNode = findScenery(reparsedBeachSceneryRoot), case .scenery(let reparsedAsset)? = reparsedSceneryNode.payload, let reparsedTreeRoot = reparsedAsset.root else {
            return XCTFail("the built image's own beach.sm2 no longer has a decodable SceneryData tree at all")
        }
        XCTAssertEqual(reparsedAsset.placements.count, originalPlacementCount + 1, "the built image handed to PCSX2 must actually carry one real, decodable new placement more than the original")

        // Real, reported regression this specific check exists to catch:
        // an earlier version of the production fix recomputed `unkPos` for
        // *every* group unconditionally, overwriting real, correct,
        // dev-authored bounds for groups this edit never touched, which
        // broke visibility for objects nowhere near the actual insertion.
        // Confirm, on the exact bytes handed to PCSX2 below, that the vast
        // majority of real groups kept their original `unkPos` untouched.
        func collectUnkPosByIdentity(_ group: SceneryGroup, into dict: inout [Set<Int>: [SIMD4<Float>]]) {
            dict[Set(group.model.placements.compactMap { $0.matrixFileOffset })] = group.model.unkPos
            for link in group.links {
                switch link {
                case .group(let child): collectUnkPosByIdentity(child, into: &dict)
                case .modelGroup(let mg): dict[Set(mg.placements.compactMap { $0.matrixFileOffset })] = mg.unkPos
                case .empty: break
                }
            }
        }
        var originalByIdentity: [Set<Int>: [SIMD4<Float>]] = [:]
        var builtByIdentity: [Set<Int>: [SIMD4<Float>]] = [:]
        collectUnkPosByIdentity(originalRoot, into: &originalByIdentity)
        collectUnkPosByIdentity(reparsedTreeRoot, into: &builtByIdentity)
        var unchangedCount = 0
        var changedCount = 0
        for (key, originalUnkPos) in originalByIdentity {
            guard let builtUnkPos = builtByIdentity[key] else { continue }
            if zip(originalUnkPos, builtUnkPos).allSatisfy({ $0 == $1 }) { unchangedCount += 1 } else { changedCount += 1 }
        }
        XCTAssertGreaterThan(unchangedCount, changedCount * 5,
            "one localized insertion changed \(changedCount) group(s)' unkPos but left only \(unchangedCount) untouched in the actual bytes handed to PCSX2, the exact regression: recompute must be scoped, not tree-wide")

        // `composingModelMatrix` writes `-position.x` into the matrix's own
        // translation row (the same real-disc X-mirror convention every
        // placement's `modelMatrix` uses, see `SceneryModelPlacement.worldTransform`'s
        // own doc comment); `translation` reads that row back raw, so the
        // real on-disk value to match against is the mirrored position, not
        // `newPosition` itself.
        let expectedOnDiskTranslation = SIMD3<Float>(-newPosition.x, newPosition.y, newPosition.z)
        var containingUnkPos: [SIMD4<Float>]?
        var containingPlacements: [SceneryModelPlacement]?
        func findContaining(_ group: SceneryGroup) {
            if group.model.placements.contains(where: { $0.translation.map { simd_distance($0, expectedOnDiskTranslation) < 0.01 } ?? false }) {
                containingUnkPos = group.model.unkPos
                containingPlacements = group.flattenedPlacements()
                return
            }
            for link in group.links {
                switch link {
                case .group(let child): findContaining(child)
                case .modelGroup(let mg) where mg.placements.contains(where: { $0.translation.map { simd_distance($0, expectedOnDiskTranslation) < 0.01 } ?? false }):
                    containingUnkPos = mg.unkPos
                    containingPlacements = mg.placements
                case .modelGroup, .empty: break
                }
            }
        }
        findContaining(reparsedTreeRoot)
        let unkPos = try XCTUnwrap(containingUnkPos, "the re-parsed built image must show the new placement inside some real group")
        let placements = try XCTUnwrap(containingPlacements)
        let v1 = SIMD3(unkPos[1].x, unkPos[1].y, unkPos[1].z)
        let v2 = SIMD3(unkPos[2].x, unkPos[2].y, unkPos[2].z)
        let radius = unkPos[1].w
        func distance(fromPointToSegment point: SIMD3<Float>, _ s0: SIMD3<Float>, _ s1: SIMD3<Float>) -> Float {
            let axis = s1 - s0
            let axisLengthSquared = simd_length_squared(axis)
            guard axisLengthSquared > 1e-12 else { return simd_distance(point, s0) }
            let t = simd_clamp(simd_dot(point - s0, axis) / axisLengthSquared, 0, 1)
            return simd_distance(point, s0 + axis * t)
        }
        for placement in placements {
            guard let position = placement.translation else { continue }
            let cornerAbs = SIMD3<Float>(
                max(abs(placement.boundingBoxMin.x), abs(placement.boundingBoxMax.x)),
                max(abs(placement.boundingBoxMin.y), abs(placement.boundingBoxMax.y)),
                max(abs(placement.boundingBoxMin.z), abs(placement.boundingBoxMax.z))
            )
            let localRadius = simd_length(cornerAbs)
            let d = distance(fromPointToSegment: position, v1, v2)
            XCTAssertLessThanOrEqual(d + localRadius, radius + 0.1,
                "the built image's own re-parsed group must have a real, recomputed `unkPos` that covers every one of its placements, this is the actual fix under test, confirmed on the exact bytes handed to PCSX2 below, not just in-memory Swift values")
        }

        let outputISO = scratchDir.appendingPathComponent("unkpos_fix_boot_test.iso")
        try built.write(to: outputISO)

        let logURL = scratchDir.appendingPathComponent("pcsx2_boot_test.log")
        try? FileManager.default.removeItem(at: logURL)

        let process = Process()
        process.executableURL = Self.pcsx2Binary
        process.arguments = ["-batch", "-nogui", "-logfile", logURL.path, "-earlyconsolelog", "--", outputISO.path]
        let stdoutURL = scratchDir.appendingPathComponent("pcsx2_stdout_test.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        process.standardOutput = stdoutHandle
        process.standardError = stdoutHandle

        try process.run()
        Thread.sleep(forTimeInterval: 90)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path), can't verify anything about this boot")
        }

        print("=== PCSX2 boot log for unkPos-fix new-scenery-insertion (\"beach.sm2\") image (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        let unrecognizedOpCount = logText.components(separatedBy: "EE: Unrecognized").count - 1
        XCTAssertTrue(logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1"),
                       "PCSX2 must genuinely resolve the boot path through our built image's own directory structure")
        XCTAssertTrue(logText.contains("RegisterLibraryEntries:  cdvdman"),
                       "the IOP kernel must have started registering modules, real post-ELF-load execution, not just a file read")
        XCTAssertTrue(logText.contains("Add ") && logText.contains("seconds play time to SLES-52568"),
                       "PCSX2 must report real accumulated play time, a hang here would mean the recomputed unkPos data itself destabilized the boot")
        XCTAssertLessThan(unrecognizedOpCount, 20, "PCSX2's EE core should not be trapping on unrecognized opcodes, real evidence the recomputed unkPos bytes corrupted something PCSX2 reads")
        XCTAssertFalse(logText.contains("Trap exception"), "PCSX2 reported a real CPU trap exception with the recomputed unkPos data present")
    }

    private static func locateArchivePair(in root: ISO9660Entry) -> (bh: ISO9660Entry, bd: ISO9660Entry)? {
        func walk(_ node: ISO9660Entry) -> (bh: ISO9660Entry, bd: ISO9660Entry)? {
            if let bh = node.children.first(where: { !$0.isDirectory && $0.name.uppercased().hasSuffix(".BH") }) {
                let base = (bh.name as NSString).deletingPathExtension
                if let bd = node.children.first(where: { !$0.isDirectory && (($0.name as NSString).deletingPathExtension).caseInsensitiveCompare(base) == .orderedSame && $0.name.uppercased().hasSuffix(".BD") }) {
                    return (bh, bd)
                }
            }
            for child in node.children where child.isDirectory {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(root)
    }
}
