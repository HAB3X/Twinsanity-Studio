import XCTest
import Foundation
@testable import CTParsers

/// `WOCCameraPathParser` -- decodes WoC `.VIS`/`.POO` files. These tests
/// independently re-verify the confirmed structure directly against
/// real disc bytes: the string-table location algorithm and the real
/// `weecam_*` camera-path names.
final class WOCCameraPathParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Golden-value regression: hand-verified against the real disc
    /// bytes directly (not just trusting an investigation report) --
    /// `CASTLE.VIS`'s string-count field sits at byte offset 660, with 6
    /// real camera path names immediately after.
    func testRealCastleVISGoldenValues() throws {
        let data = try loadReal("A/CASTLE/CASTLE.VIS")
        let file = try WOCCameraPathParser.parse(data)
        XCTAssertEqual(file.nodeCount, 9)
        XCTAssertEqual(file.cameraPathNames, [
            "weecam_mid_00", "weecam_in_bonus", "weecam_out_bonus",
            "weecam_mid_bonus", "weecam_mid_death", "weecam_in_death",
        ])
    }

    /// Golden-value regression for the node/point-list decode: hand-
    /// verified against the real disc bytes. `CASTLE.VIS` has 9 real
    /// nodes (more than its 6 real names -- nodes 0-3 share name index 0,
    /// a single multi-segment path built from 4 separate point lists),
    /// node 0 has exactly 4 points (`headerB`), and the index table's
    /// byte accounting checks out cleanly for this file so every node
    /// gets a real `nameIndex`.
    func testRealCastleVISNodeGoldenValues() throws {
        let data = try loadReal("A/CASTLE/CASTLE.VIS")
        let file = try WOCCameraPathParser.parse(data)
        XCTAssertEqual(file.nodes.count, 9)
        XCTAssertEqual(file.nodes[0].points.count, 4)
        XCTAssertEqual(file.nodes.map(\.nameIndex), [0, 0, 0, 0, 1, 2, 3, 4, 5])
        for node in file.nodes {
            XCTAssertFalse(node.points.isEmpty, "every real node should have real points")
            for p in node.points {
                XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite)
            }
        }
    }

    /// `TOONARMY.VIS` is the one real file whose index table doesn't
    /// byte-account cleanly -- its nodes should still carry real points,
    /// just with `nameIndex` (and the other index-table fields) nil
    /// throughout, an honest partial result rather than guessed data.
    func testTOONARMYNodesHaveRealPointsButNoIndexTable() throws {
        let data = try loadReal("A/TSUNAMI/TOONARMY.VIS")
        let file = try WOCCameraPathParser.parse(data)
        XCTAssertEqual(file.nodes.count, Int(file.nodeCount))
        XCTAssertFalse(file.nodes.isEmpty)
        for node in file.nodes {
            XCTAssertFalse(node.points.isEmpty)
            XCTAssertNil(node.nameIndex)
            XCTAssertNil(node.selfIndex)
        }
    }

    /// `WEST_A.POO` is confirmed to be the exact same format under a
    /// different extension.
    func testWestAPOOUsesTheSameFormat() throws {
        let data = try loadReal("A/WEST_A/WEST_A.POO")
        let file = try WOCCameraPathParser.parse(data)
        XCTAssertEqual(file.cameraPathNames, ["weecam_mid_00"])
    }

    /// Full-corpus regression: every real `.VIS` file on the disc should
    /// parse cleanly with real, non-empty camera path names -- matching
    /// the investigation's headline "15/15 files, zero exceptions"
    /// result, including `TOONARMY.VIS` which doesn't fit the uniform
    /// index-table width other files do (this parser doesn't depend on
    /// that width, so it isn't affected). Also checks the node/point-list
    /// decode: `nodes.count == nodeCount`, every node has real points,
    /// and (on the 13 of 14 files whose index table byte-accounts
    /// cleanly) every node's `nameIndex` is a valid index into that same
    /// file's own `cameraPathNames`.
    func testEveryRealVISFileParsesWithRealCameraPathNames() throws {
        let samples = [
            "A/CASTLE/CASTLE.VIS", "A/CASTLE_C/CASTLE_C.VIS", "A/DROID/DROID.VIS",
            "A/EARTH_R/EARTH.VIS", "A/FIREBALL/BALLSOF.VIS", "A/FIRE_R/FIRE_R.VIS",
            "A/GARDEN/GARDEN.VIS", "A/JUNGLE_R/JUNGLE.VIS", "A/SNOW_M/SNOW.VIS",
            "A/TSUNAMI/TOONARMY.VIS", "A/VOLCANO/VOLCANO.VIS", "A/WATER_R/WATER.VIS",
            "A/WESTERN/WEATHER.VIS", "A/WESTERN/WESTERN.VIS",
        ]
        var checked = 0
        for relativePath in samples {
            let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let file = try WOCCameraPathParser.parse(data)
            XCTAssertFalse(file.cameraPathNames.isEmpty, "\(relativePath): expected real camera path names")
            for name in file.cameraPathNames {
                XCTAssertTrue(name.hasPrefix("weecam"), "\(relativePath): expected a real weecam_* name, got \(name)")
            }

            XCTAssertEqual(file.nodes.count, Int(file.nodeCount), "\(relativePath): nodes.count should match nodeCount")
            for node in file.nodes {
                XCTAssertFalse(node.points.isEmpty, "\(relativePath): every real node should have real points")
                if let nameIndex = node.nameIndex {
                    XCTAssertTrue(nameIndex >= 0 && nameIndex < file.cameraPathNames.count, "\(relativePath): nameIndex out of bounds")
                }
            }
            checked += 1
        }
        guard checked > 0 else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
    }

    /// `selfIndex` is really a sort rank, not a self-reference: within
    /// most groups of nodes sharing one `nameIndex`, sorting by
    /// `selfIndex` ascending also sorts `unknownFieldC`/`unknownFieldD`
    /// ascending. Confirmed on 14 of 19 real multi-node groups across 13
    /// real files (this test's own re-count, independent of that
    /// investigation) -- the other 5 break in a structured way (a
    /// monotonic "head" sub-sequence plus a separate later one), not
    /// randomly, consistent with some names covering multiple
    /// disconnected path segments rather than refuting the sort-rank
    /// reading. This test asserts the real majority (at least 2 of every
    /// 3 real multi-node groups checked are exactly monotonic) rather
    /// than every single group, since a handful are honestly still
    /// unexplained -- see `WOCCameraPathParser`'s own doc comment.
    func testSelfIndexIsASortRankByFieldCForMostGroups() throws {
        let samples = [
            "A/CASTLE/CASTLE.VIS", "A/CASTLE_C/CASTLE_C.VIS", "A/DROID/DROID.VIS",
            "A/EARTH_R/EARTH.VIS", "A/GARDEN/GARDEN.VIS", "A/VOLCANO/VOLCANO.VIS",
            "A/FIREBALL/BALLSOF.VIS", "A/FIRE_R/FIRE_R.VIS", "A/SNOW_M/SNOW.VIS",
            "A/JUNGLE_R/JUNGLE.VIS", "A/WATER_R/WATER.VIS", "A/WESTERN/WEATHER.VIS",
            "A/WESTERN/WESTERN.VIS",
        ]
        var groupsChecked = 0
        var groupsMonotonic = 0
        var foundEarthRTenNodeGroup = false
        for relativePath in samples {
            let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let file = try WOCCameraPathParser.parse(data)
            guard file.nodes.allSatisfy({ $0.selfIndex != nil }) else { continue }

            var byName: [Int: [(rank: Int32, fieldC: Int32, fieldD: Int32)]] = [:]
            for node in file.nodes {
                guard let nameIndex = node.nameIndex, let rank = node.selfIndex,
                      let c = node.unknownFieldC, let d = node.unknownFieldD else { continue }
                byName[nameIndex, default: []].append((rank, c, d))
            }
            for (_, group) in byName where group.count > 1 {
                let sorted = group.sorted { $0.rank < $1.rank }
                let cs = sorted.map(\.fieldC)
                let ds = sorted.map(\.fieldD)
                let cMonotonic = zip(cs, cs.dropFirst()).allSatisfy { $0 <= $1 }
                let dMonotonic = zip(ds, ds.dropFirst()).allSatisfy { $0 <= $1 }
                if cMonotonic && dMonotonic {
                    groupsMonotonic += 1
                    // ranks must also be a real permutation, not a
                    // no-op identity mapping, to prove this is a genuine
                    // sort and not coincidental already-sorted data.
                    if relativePath == "A/EARTH_R/EARTH.VIS", group.count == 10 {
                        foundEarthRTenNodeGroup = true
                        let ranksInFileOrder = group.map(\.rank)
                        XCTAssertNotEqual(ranksInFileOrder, ranksInFileOrder.sorted(), "EARTH.VIS's 10-node group should be a real permutation")
                    }
                }
                groupsChecked += 1
            }
        }
        XCTAssertGreaterThan(groupsChecked, 0, "expected at least some real multi-node groups to check")
        XCTAssertTrue(foundEarthRTenNodeGroup, "expected to find EARTH.VIS's known 10-node group")
        XCTAssertGreaterThanOrEqual(Double(groupsMonotonic) / Double(groupsChecked), 2.0 / 3.0, "expected most real groups to be exactly monotonic under this sort")
    }
}
