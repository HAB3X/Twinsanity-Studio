import XCTest
import simd
@testable import CTParsers

/// `WOCCharacterSkeletonParser` -- decodes real joint hierarchies from
/// `CHARS.DAT` entries. These tests independently re-verify the
/// confirmed corpus-wide claims directly against real disc bytes: every
/// real skeleton entry decodes to exactly one root and a valid DAG of
/// parent references, with real anatomical joint names.
final class WOCCharacterSkeletonParserTests: XCTestCase {
    private var charsURL: URL { URL(fileURLWithPath: "/Volumes/CRASH/CHARS.DAT") }

    private func requireDisc() throws {
        guard FileManager.default.fileExists(atPath: charsURL.path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
    }

    /// Golden-value regression: entry #71 is a real, hand-verified
    /// 47-joint Crash rig. Pins the exact anatomical chain rather than
    /// just a count.
    func testRealCrashSkeletonGoldenValues() throws {
        try requireDisc()
        let entries = try WOCCharacterArchiveParser.parseTable(fileURL: charsURL)
        let decoded = try WOCCharacterArchiveParser.decode(entries[71], fileURL: charsURL)
        let skeleton = try WOCCharacterSkeletonParser.parseSkeleton(decoded)

        XCTAssertEqual(skeleton.joints.count, 47)
        XCTAssertEqual(skeleton.joints[0].name, "CrashBones")
        XCTAssertEqual(skeleton.joints[0].parentIndex, -1)

        let byName = Dictionary(uniqueKeysWithValues: skeleton.joints.enumerated().map { ($1.name, $0) })
        func parentName(of childName: String) -> String? {
            guard let childIndex = byName[childName] else { return nil }
            let parentIndex = skeleton.joints[childIndex].parentIndex
            guard parentIndex >= 0 else { return nil }
            return skeleton.joints[parentIndex].name
        }
        XCTAssertEqual(parentName(of: "Pelvis"), "CrashBones")
        XCTAssertEqual(parentName(of: "LeftLeg"), "Pelvis")
        XCTAssertEqual(parentName(of: "LeftKnee"), "LeftLeg")
        XCTAssertEqual(parentName(of: "LeftAnkle"), "LeftKnee")
        XCTAssertEqual(parentName(of: "LeftToe"), "LeftAnkle")
        XCTAssertEqual(parentName(of: "RightLeg"), "Pelvis")
        XCTAssertEqual(parentName(of: "UpperTorso"), "Back")
    }

    /// Full-corpus regression: every real skeleton entry in the archive
    /// (found by the confirmed header shape: decompressed offset 4 == 0
    /// and offset 12 == 0) decodes to exactly one root and a valid DAG --
    /// zero exceptions, matching the original investigation's sweep.
    func testEveryRealSkeletonEntryFormsAValidDAG() throws {
        try requireDisc()
        let entries = try WOCCharacterArchiveParser.parseTable(fileURL: charsURL)
        var skeletonsChecked = 0
        for entry in entries {
            guard let decoded = try? WOCCharacterArchiveParser.decode(entry, fileURL: charsURL) else { continue }
            guard let skeleton = try? WOCCharacterSkeletonParser.parseSkeleton(decoded) else { continue }

            var roots = 0
            for (i, joint) in skeleton.joints.enumerated() {
                XCTAssertFalse(joint.name.isEmpty, "entry #\(entry.index) joint \(i): name should resolve to something real")
                if joint.parentIndex == -1 {
                    roots += 1
                } else {
                    XCTAssertGreaterThanOrEqual(joint.parentIndex, 0, "entry #\(entry.index) joint \(i): invalid parent index")
                    XCTAssertLessThan(joint.parentIndex, i, "entry #\(entry.index) joint \(i): parent should be a strictly-earlier joint")
                }
            }
            XCTAssertEqual(roots, 1, "entry #\(entry.index): expected exactly one root joint")
            skeletonsChecked += 1
        }
        XCTAssertEqual(skeletonsChecked, 12, "expected exactly the 12 real skeleton entries confirmed in this archive")
    }

    /// Non-skeleton entries (the overwhelming majority -- mesh/prop
    /// entries and placeholders) should be honestly rejected, not
    /// misdecoded into a garbage "skeleton".
    func testOrdinaryEntryIsNotMisdecodedAsASkeleton() throws {
        try requireDisc()
        let entries = try WOCCharacterArchiveParser.parseTable(fileURL: charsURL)
        let decoded = try WOCCharacterArchiveParser.decode(entries[0], fileURL: charsURL)
        XCTAssertThrowsError(try WOCCharacterSkeletonParser.parseSkeleton(decoded))
    }

    /// Real-bytes re-verification of the `Table A`/`Table B`/`Table C`
    /// `NUJOINTDATA_s`/`T[]`/`INV_WT[]` decode (see
    /// `WOCCharacterSkeletonParser`'s own doc comment for the source
    /// this is grounded in) -- checks the structural invariants a real
    /// affine matrix must have, not just "some floats came out", on the
    /// same real 47-joint Crash rig the golden-value test above uses.
    func testJointMatricesHaveRealAffineStructure() throws {
        try requireDisc()
        let entries = try WOCCharacterArchiveParser.parseTable(fileURL: charsURL)
        let decoded = try WOCCharacterArchiveParser.decode(entries[71], fileURL: charsURL)
        let skeleton = try WOCCharacterSkeletonParser.parseSkeleton(decoded)

        // Row-major, translation in row 3 (this codebase's established WoC
        // matrix convention -- see `WOCObjectInstance.matrix`'s own doc
        // comment): the real affine invariant is column 3 == [0,0,0,1],
        // not row 3 -- row 3's x/y/z *are* the real translation, free to
        // be any value.
        func hasRealAffineColumn(_ m: simd_float4x4) -> Bool {
            let col3 = m[3]
            return abs(col3.x) < 1e-4 && abs(col3.y) < 1e-4 && abs(col3.z) < 1e-4 && abs(col3.w - 1) < 1e-4
        }
        for joint in skeleton.joints {
            XCTAssertTrue(hasRealAffineColumn(joint.restOrientation), "\(joint.name): restOrientation isn't a real affine matrix")
            XCTAssertTrue(hasRealAffineColumn(joint.localBindMatrix), "\(joint.name): localBindMatrix isn't a real affine matrix")
            XCTAssertTrue(hasRealAffineColumn(joint.inverseBindMatrix), "\(joint.name): inverseBindMatrix isn't a real affine matrix")
        }

        // The root's rest orientation is the identity on every real joint
        // sampled during investigation -- re-check it holds for the whole
        // rig, not just the 3 joints spot-checked by hand.
        XCTAssertEqual(skeleton.joints[0].restOrientation, matrix_identity_float4x4)

        // Table C's rotation submatrix is the cumulative world rotation,
        // so it must be a real orthonormal rotation matrix (unit-length
        // rows) for every joint -- a hard structural signal, not
        // something plausible-looking noise would satisfy.
        for joint in skeleton.joints {
            let m = joint.inverseBindMatrix
            for row in 0..<3 {
                let v = SIMD3(m[0][row], m[1][row], m[2][row])
                XCTAssertEqual(simd_length(v), 1, accuracy: 0.01, "\(joint.name): inverseBindMatrix row \(row) isn't unit length")
            }
        }
    }
}
