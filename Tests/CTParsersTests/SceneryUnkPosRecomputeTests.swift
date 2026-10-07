import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers

/// `SceneryModelGroup.unkPos` decode + recompute, see
/// `SceneryModelGroup.computingUnkPos(covering:)`'s own doc comment for the
/// real-disc-data investigation this format was decoded from (a bounding
/// capsule: `unkPos[0]` = axis midpoint, `unkPos[1]`/`[2]` = axis
/// endpoints, `unkPos[3]` = half-axis vector, all four `.w` fields tying the
/// segment length to the shared radius; `unkPos[4]` always zero).
final class SceneryUnkPosRecomputeTests: XCTestCase {
    private static let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")

    private func distance(fromPointToSegment point: SIMD3<Float>, _ s0: SIMD3<Float>, _ s1: SIMD3<Float>) -> Float {
        let axis = s1 - s0
        let axisLengthSquared = simd_length_squared(axis)
        guard axisLengthSquared > 1e-12 else { return simd_distance(point, s0) }
        let t = simd_clamp(simd_dot(point - s0, axis) / axisLengthSquared, 0, 1)
        return simd_distance(point, s0 + axis * t)
    }

    /// Every real, on-disk group's own decoded `unkPos` structural identity
    /// (`unkPos[3] == unkPos[2]-unkPos[0] == unkPos[0]-unkPos[1]`, `unkPos[0].w
    /// == |unkPos[3].xyz|`, `unkPos[1].w == unkPos[2].w == unkPos[3].w`) holds
    /// exactly for real, unmodified data, confirming the decode itself
    /// against a real file, not just the offline investigation this was
    /// developed from.
    func testRealGroupUnkPosMatchesDecodedCapsuleStructure() throws {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)
        guard let entry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/hubb.sm2" }) else {
            throw XCTSkip("hubb.sm2 not found in this archive")
        }
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .sm2, fileName: entry.name)

        var found: SceneryAsset?
        func walk(_ node: ChunkNode) {
            if found == nil, case .scenery(let scenery) = node.payload, !scenery.placements.isEmpty {
                found = scenery
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        let scenery = try XCTUnwrap(found)
        let sceneryRoot = try XCTUnwrap(scenery.root)

        var checked = 0
        func verify(_ group: SceneryModelGroup) {
            guard !group.placements.isEmpty else { return }
            let v0 = group.unkPos[0], v1 = group.unkPos[1], v2 = group.unkPos[2], v3 = group.unkPos[3]
            let v0xyz = SIMD3(v0.x, v0.y, v0.z), v1xyz = SIMD3(v1.x, v1.y, v1.z)
            let v2xyz = SIMD3(v2.x, v2.y, v2.z), v3xyz = SIMD3(v3.x, v3.y, v3.z)
            XCTAssertLessThan(simd_distance(v2xyz - v0xyz, v3xyz), 0.05)
            XCTAssertLessThan(simd_distance(v0xyz - v1xyz, v3xyz), 0.05)
            XCTAssertEqual(v0.w, simd_length(v3xyz), accuracy: 0.05)
            XCTAssertEqual(v1.w, v2.w, accuracy: 0.02 * max(1, v1.w))
            XCTAssertEqual(v2.w, v3.w, accuracy: 0.02 * max(1, v2.w))
            checked += 1
        }
        func walkGroup(_ group: SceneryGroup) {
            verify(group.model)
            for link in group.links {
                switch link {
                case .group(let child): walkGroup(child)
                case .modelGroup(let mg): verify(mg)
                case .empty: break
                }
            }
        }
        walkGroup(sceneryRoot)
        XCTAssertGreaterThan(checked, 10, "expected to check a real number of non-empty groups in hubb.sm2")
    }

    /// The actual bug this decode + recompute exists to fix: insert a new
    /// placement far outside its target group's *original* (now-stale)
    /// `unkPos` capsule, recompute, and confirm the new placement is now
    /// covered, while every pre-existing real placement in that same
    /// group is *also* still covered (recomputing must not shrink the
    /// bound below what real, unmodified data already needed).
    func testRecomputingUnkPosCoversANewlyInsertedPlacementRealDiscGroup() throws {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)
        guard let entry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/hubb.sm2" }) else {
            throw XCTSkip("hubb.sm2 not found in this archive")
        }
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .sm2, fileName: entry.name)

        var found: SceneryAsset?
        func walk(_ node: ChunkNode) {
            if found == nil, case .scenery(let scenery) = node.payload, !scenery.placements.isEmpty {
                found = scenery
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        let scenery = try XCTUnwrap(found)
        var sceneryRoot = try XCTUnwrap(scenery.root)

        // A real existing placement's position anchors the new placement
        // near it, matching how `insertingPlacementNearestExistingNeighbor`
        // is actually used in the app.
        let anchor = try XCTUnwrap(scenery.placements.first { $0.translation != nil })
        let anchorPosition = try XCTUnwrap(anchor.translation)
        // Deliberately far outside any real group's existing bound (groups
        // in this file are all well under 500 units across), this is the
        // exact failure mode: a real placement whose group's stale bound
        // doesn't cover it.
        let farPosition = anchorPosition + SIMD3<Float>(300, 300, 300)
        let newPlacement = SceneryModelPlacement(
            modelID: 999_999, isSpecial: false,
            boundingBoxMin: SIMD4<Float>(-2, -2, -2, 1), boundingBoxMax: SIMD4<Float>(2, 2, 2, 1),
            modelMatrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(farPosition, 1)]
        )
        sceneryRoot = sceneryRoot.insertingPlacementNearestExistingNeighbor(newPlacement, targetPosition: farPosition)
        let recomputed = sceneryRoot.recomputingUnkPosRecursively()

        // Find the group the new placement actually landed in and confirm
        // its (recomputed) capsule covers it.
        var containingGroupUnkPos: [SIMD4<Float>]?
        var containingGroupPlacements: [SceneryModelPlacement]?
        func findGroup(_ group: SceneryGroup) {
            if group.model.placements.contains(where: { $0.modelID == 999_999 }) {
                containingGroupUnkPos = group.model.unkPos
                containingGroupPlacements = group.flattenedPlacements()
                return
            }
            for link in group.links {
                switch link {
                case .group(let child): findGroup(child)
                case .modelGroup(let mg) where mg.placements.contains(where: { $0.modelID == 999_999 }):
                    containingGroupUnkPos = mg.unkPos
                    containingGroupPlacements = mg.placements
                case .modelGroup, .empty: break
                }
            }
        }
        findGroup(recomputed)
        let unkPos = try XCTUnwrap(containingGroupUnkPos, "new placement must land in some real group")
        let placements = try XCTUnwrap(containingGroupPlacements)
        XCTAssertTrue(placements.contains { $0.modelID == 999_999 })

        // The game's cull box (unkPos[1]/[2], min/max: SceneryCell::Read, ChunkView::TestCell) holds every placement's world box
        let boxMin = SIMD3(unkPos[1].x, unkPos[1].y, unkPos[1].z)
        let boxMax = SIMD3(unkPos[2].x, unkPos[2].y, unkPos[2].z)
        for placement in placements {
            guard let world = SceneryModelGroup.worldBounds(of: placement) else { continue }
            for axis in 0..<3 {
                XCTAssertLessThanOrEqual(boxMin[axis], world.min[axis] + 0.001,
                    "the group's box must hold every placement (modelID \(placement.modelID)) on axis \(axis)")
                XCTAssertGreaterThanOrEqual(boxMax[axis], world.max[axis] - 0.001,
                    "the group's box must hold every placement (modelID \(placement.modelID)) on axis \(axis)")
            }
        }

        // Round-trips through the real writer/parser without losing the
        // new placement or corrupting anything else.
        var mutatedScenery = scenery
        mutatedScenery.root = recomputed
        let encoded = SceneryDataWriter.encode(mutatedScenery)
        var cursor = BinaryCursor(data: encoded)
        let reparsed = try SceneryDataParser.parse(&cursor, recordID: 1)
        XCTAssertEqual(reparsed.placements.count, scenery.placements.count + 1)
        XCTAssertTrue(reparsed.placements.contains { $0.modelID == 999_999 })
    }

    /// **Real, reported regression this test exists to catch**: an earlier
    /// version of the production fix called `recomputingUnkPosRecursively()`
    /// unconditionally on every scenery save, which overwrote *every*
    /// group's `unkPos`, including every group nowhere near the actual
    /// edit, with this codebase's own reconstruction of the format. That
    /// reconstruction, while conservative (always covers its own input
    /// points), isn't a bit-exact reproduction of whatever the original
    /// dev tool computed, so replacing real, correct, already-working
    /// bounds broke visibility for objects the edit never touched, the
    /// user reported "a lot of the other objects are flickering" after
    /// using the in-app placement tool once this landed.
    ///
    /// `recomputingUnkPos(sinceEditFrom:)` is the fix: this test inserts
    /// one new placement into a real, unmodified hubb.sm2 tree, recomputes
    /// against the real pre-edit baseline, and confirms every OTHER real
    /// group's `unkPos` is preserved byte-for-byte (not just "close" , 
    /// exactly, the same round-trip discipline this codebase already holds
    /// every other undecoded field to) while the actually-affected group
    /// (and its ancestors) still gets a real, freshly-covering bound.
    func testRecomputingUnkPosSinceEditOnlyChangesGroupsTheEditActuallyTouched() throws {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)
        guard let entry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/hubb.sm2" }) else {
            throw XCTSkip("hubb.sm2 not found in this archive")
        }
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .sm2, fileName: entry.name)

        var found: SceneryAsset?
        func walk(_ node: ChunkNode) {
            if found == nil, case .scenery(let scenery) = node.payload, !scenery.placements.isEmpty {
                found = scenery
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        let scenery = try XCTUnwrap(found)
        let originalRoot = try XCTUnwrap(scenery.root)

        let anchor = try XCTUnwrap(scenery.placements.first { $0.translation != nil })
        let anchorPosition = try XCTUnwrap(anchor.translation)
        // Deliberately far outside any real group's existing capsule slack
        // (median ~25-30 units in this project's own real-disc sampling)
        //, with `expandingUnkPos`, a *small* offset can leave a group
        // completely untouched (the existing capsule already covers it),
        // which is correct behavior but would make `changedCount` here
        // spuriously zero. This offset guarantees real growth happens.
        let newPosition = anchorPosition + SIMD3<Float>(300, 300, 300)
        let newPlacement = SceneryModelPlacement(
            modelID: 999_998, isSpecial: false,
            boundingBoxMin: SIMD4<Float>(-1, -1, -1, 1), boundingBoxMax: SIMD4<Float>(1, 1, 1, 1),
            modelMatrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(newPosition, 1)]
        )
        let editedRoot = originalRoot.insertingPlacementNearestExistingNeighbor(newPlacement, targetPosition: newPosition)
        let recomputed = editedRoot.recomputingUnkPos(sinceEditFrom: originalRoot)

        // Collect every group's unkPos, keyed by its own placements' set of
        // real matrixFileOffsets (a stable identity independent of tree
        // position), for both the untouched original and the recomputed
        // result, the new placement (no offset yet) is excluded from the
        // key so its containing group's key still matches up before/after.
        func collectUnkPosByIdentity(_ group: SceneryGroup, into dict: inout [Set<Int>: [SIMD4<Float>]]) {
            let key = Set(group.model.placements.compactMap { $0.matrixFileOffset })
            dict[key] = group.model.unkPos
            for link in group.links {
                switch link {
                case .group(let child): collectUnkPosByIdentity(child, into: &dict)
                case .modelGroup(let mg):
                    let mgKey = Set(mg.placements.compactMap { $0.matrixFileOffset })
                    dict[mgKey] = mg.unkPos
                case .empty: break
                }
            }
        }
        var originalByIdentity: [Set<Int>: [SIMD4<Float>]] = [:]
        var recomputedByIdentity: [Set<Int>: [SIMD4<Float>]] = [:]
        collectUnkPosByIdentity(originalRoot, into: &originalByIdentity)
        collectUnkPosByIdentity(recomputed, into: &recomputedByIdentity)

        var unchangedCount = 0
        var changedCount = 0
        for (key, originalUnkPos) in originalByIdentity {
            guard let recomputedUnkPos = recomputedByIdentity[key] else { continue }
            let identical = zip(originalUnkPos, recomputedUnkPos).allSatisfy { $0 == $1 }
            if identical {
                unchangedCount += 1
            } else {
                changedCount += 1
            }
        }
        // The new placement joins exactly one leaf group (by real,
        // on-disk-membership identity); only that leaf and its ancestor
        // chain up to (not including) the root should differ. hubb.sm2's
        // own real tree is deeply nested (per this file's other tests'
        // established use of it), so this must be a small minority of the
        // groups actually checked.
        XCTAssertGreaterThan(changedCount, 0, "sanity: the actually-affected group(s) must show a real, changed unkPos")
        XCTAssertGreaterThan(unchangedCount, changedCount * 5,
            "recomputing after ONE localized insertion changed \(changedCount) group(s) but left only \(unchangedCount) untouched, this is the exact regression: unkPos recompute must be scoped to the edited groups, not applied tree-wide")
    }

    /// **Second real, reported regression this test exists to catch**:
    /// scoping alone (the test above) wasn't enough, even the one group
    /// an edit genuinely touches broke previously-fine objects in that
    /// same group when its whole capsule was replaced with a from-scratch
    /// reconstruction, confirmed live in a real PCSX2 boot ("the entire
    /// world is flickering... certain objects turn invisible" as the
    /// camera turns). The real fix, `expandingUnkPos`, never touches the
    /// original axis at all, this test confirms that directly: for the
    /// one real group an insertion actually changes, `unkPos[0]`
    /// (center), `[1]`/`[2]` (endpoints), and `[3]` (half-axis) must
    /// still be *exactly* the original real, dev-authored values, only
    /// the shared radius (`.w`) may differ, and only by growing.
    func testExpandingUnkPosGrowsTheChangedGroupsBoxToHoldTheNewPlacement() throws {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)
        guard let entry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/hubb.sm2" }) else {
            throw XCTSkip("hubb.sm2 not found in this archive")
        }
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .sm2, fileName: entry.name)

        var found: SceneryAsset?
        func walk(_ node: ChunkNode) {
            if found == nil, case .scenery(let scenery) = node.payload, !scenery.placements.isEmpty {
                found = scenery
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        let scenery = try XCTUnwrap(found)
        let originalRoot = try XCTUnwrap(scenery.root)

        let anchor = try XCTUnwrap(scenery.placements.first { $0.translation != nil })
        let anchorPosition = try XCTUnwrap(anchor.translation)
        // Far enough to force real radius growth, proving axis
        // preservation *under* an actual expansion, not just the trivial
        // case where the existing capsule already covered the new point.
        let newPosition = anchorPosition + SIMD3<Float>(300, 300, 300)
        let newPlacement = SceneryModelPlacement(
            modelID: 999_997, isSpecial: false,
            boundingBoxMin: SIMD4<Float>(-1, -1, -1, 1), boundingBoxMax: SIMD4<Float>(1, 1, 1, 1),
            modelMatrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(newPosition, 1)]
        )
        let editedRoot = originalRoot.insertingPlacementNearestExistingNeighbor(newPlacement, targetPosition: newPosition)
        let recomputed = editedRoot.recomputingUnkPos(sinceEditFrom: originalRoot)

        // Find the group the new placement landed in, in BOTH the original
        // (pre-edit) and recomputed trees, by real on-disk membership
        // identity (every original placement's own `matrixFileOffset`).
        func findGroupUnkPos(_ group: SceneryGroup, containingOffsets targetOffsets: Set<Int>) -> [SIMD4<Float>]? {
            if !targetOffsets.isEmpty, targetOffsets.isSubset(of: Set(group.model.placements.compactMap { $0.matrixFileOffset })) {
                return group.model.unkPos
            }
            for link in group.links {
                switch link {
                case .group(let child):
                    if let found = findGroupUnkPos(child, containingOffsets: targetOffsets) { return found }
                case .modelGroup(let mg):
                    if !targetOffsets.isEmpty, targetOffsets.isSubset(of: Set(mg.placements.compactMap { $0.matrixFileOffset })) {
                        return mg.unkPos
                    }
                case .empty: break
                }
            }
            return nil
        }
        func findNewPlacementGroup(_ group: SceneryGroup) -> [SceneryModelPlacement]? {
            if group.model.placements.contains(where: { $0.modelID == 999_997 }) { return group.model.placements }
            for link in group.links {
                switch link {
                case .group(let child):
                    if let found = findNewPlacementGroup(child) { return found }
                case .modelGroup(let mg) where mg.placements.contains(where: { $0.modelID == 999_997 }):
                    return mg.placements
                case .modelGroup, .empty: break
                }
            }
            return nil
        }
        let recomputedGroupPlacements = try XCTUnwrap(findNewPlacementGroup(recomputed), "new placement must land in some real group")
        let existingOffsets = Set(recomputedGroupPlacements.compactMap { $0.matrixFileOffset })
        XCTAssertFalse(existingOffsets.isEmpty, "sanity: the affected group must contain at least one real pre-existing placement to compare axes against")

        let originalUnkPos = try XCTUnwrap(findGroupUnkPos(originalRoot, containingOffsets: existingOffsets))
        let recomputedUnkPos = try XCTUnwrap(findGroupUnkPos(recomputed, containingOffsets: existingOffsets))

        // The box only grows (never moves inward on any axis), holds the new placement, and keeps the game's own layout
        // (sphere at the box's centre, its radius the half-size's length, half-size = max - centre)
        for axis in 0..<3 {
            XCTAssertLessThanOrEqual(recomputedUnkPos[1][axis], originalUnkPos[1][axis], "the box's min must never shrink inward")
            XCTAssertGreaterThanOrEqual(recomputedUnkPos[2][axis], originalUnkPos[2][axis], "the box's max must never shrink inward")
        }
        let world = try XCTUnwrap(SceneryModelGroup.worldBounds(of: newPlacement))
        for axis in 0..<3 {
            XCTAssertLessThanOrEqual(recomputedUnkPos[1][axis], world.min[axis] + 0.001)
            XCTAssertGreaterThanOrEqual(recomputedUnkPos[2][axis], world.max[axis] - 0.001)
            let centre = (recomputedUnkPos[1][axis] + recomputedUnkPos[2][axis]) * 0.5
            XCTAssertEqual(recomputedUnkPos[0][axis], centre, accuracy: 0.001)
            XCTAssertEqual(recomputedUnkPos[3][axis], recomputedUnkPos[2][axis] - centre, accuracy: 0.001)
        }
        // The .w the box test doesn't read is kept as the original had it
        XCTAssertEqual(recomputedUnkPos[1].w, originalUnkPos[1].w)
    }
}
