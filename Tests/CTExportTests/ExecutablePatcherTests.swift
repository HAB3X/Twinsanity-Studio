import XCTest
@testable import CTExport

/// Cross-checks `ExecutablePatcher` against CrateModLoader's own real
/// offset tables and patch behavior, same discipline as
/// `GameplayModCatalogTests`, since a typo in one of these offsets would
/// silently corrupt someone's game executable.
final class ExecutablePatcherTests: XCTestCase {
    private func makeFakeExe(size: Int) -> Data {
        Data(repeating: 0xAA, count: size)
    }

    func testDetectNTSCURevisionByProbeByte() {
        var exe = makeFakeExe(size: 0x1ECB20)
        exe[0x1ECB10] = UInt8(ascii: "C")
        XCTAssertEqual(ExecutablePatcher.detectNTSCURevision(exeData: exe), .ntscU)

        var exe2 = makeFakeExe(size: 0x1ECB20)
        exe2[0x1ECB10] = UInt8(ascii: "X")
        XCTAssertEqual(ExecutablePatcher.detectNTSCURevision(exeData: exe2), .ntscU2)
    }

    func testDetectNTSCURevisionReturnsNilWhenTooSmall() {
        let exe = makeFakeExe(size: 100)
        XCTAssertNil(ExecutablePatcher.detectNTSCURevision(exeData: exe))
    }

    func testStartingChunkPathRoundTripsThroughWriter() throws {
        let exe = makeFakeExe(size: 0x400000)
        let patched = try ExecutablePatcher.writingStartingChunkPath("earth\\hub\\beach", revision: .pal, into: exe)
        let readBack = ExecutablePatcher.readStartingChunkPath(revision: .pal, from: patched)
        XCTAssertEqual(readBack, "earth\\hub\\beach")
    }

    /// The reference zero-fills the whole field before writing, a
    /// shorter new path must fully overwrite a longer old one, not leave
    /// old trailing bytes behind.
    func testWritingShorterPathClearsOldTrailingBytes() throws {
        let exe = makeFakeExe(size: 0x400000)
        let withLongPath = try ExecutablePatcher.writingStartingChunkPath("altearth\\core\\treasure", revision: .pal, into: exe)
        let withShortPath = try ExecutablePatcher.writingStartingChunkPath("earth\\hub", revision: .pal, into: withLongPath)
        XCTAssertEqual(ExecutablePatcher.readStartingChunkPath(revision: .pal, from: withShortPath), "earth\\hub")
    }

    func testStartingChunkPathTooLongThrows() throws {
        let exe = makeFakeExe(size: 0x400000)
        let tooLong = String(repeating: "x", count: 40) // field is 0x17 = 23 bytes
        XCTAssertThrowsError(try ExecutablePatcher.writingStartingChunkPath(tooLong, revision: .pal, into: exe)) { error in
            guard case ExecutablePatcherError.pathTooLong(let maxLength) = error else {
                return XCTFail("Expected .pathTooLong, got \(error)")
            }
            XCTAssertEqual(maxLength, 0x17)
        }
    }

    func testCreditsChunkPathRoundTripsThroughWriter() throws {
        let exe = makeFakeExe(size: 0x400000)
        let patched = try ExecutablePatcher.writingCreditsChunkPath("earth\\hub\\credits", revision: .xboxNTSC, into: exe)
        XCTAssertEqual(ExecutablePatcher.readCreditsChunkPath(revision: .xboxNTSC, from: patched), "earth\\hub\\credits")
    }

    /// Patching the starting-chunk field must never touch the (separate,
    /// non-overlapping) credits-chunk field.
    func testStartingAndCreditsFieldsAreIndependent() throws {
        let exe = makeFakeExe(size: 0x400000)
        var patched = try ExecutablePatcher.writingStartingChunkPath("earth\\hub\\beach", revision: .ntscJ, into: exe)
        patched = try ExecutablePatcher.writingCreditsChunkPath("earth\\hub\\credits", revision: .ntscJ, into: patched)
        XCTAssertEqual(ExecutablePatcher.readStartingChunkPath(revision: .ntscJ, from: patched), "earth\\hub\\beach")
        XCTAssertEqual(ExecutablePatcher.readCreditsChunkPath(revision: .ntscJ, from: patched), "earth\\hub\\credits")
    }

    func testSwapStartAndCreditsSpawnExchangesThePointers() throws {
        var exe = makeFakeExe(size: 0x300000)
        let startOffset = GameExecutableRevision.xboxPAL.startSpawnPointerOffset
        let creditsOffset = GameExecutableRevision.xboxPAL.creditsSpawnPointerOffset
        exe.replaceSubrange(startOffset..<(startOffset + 4), with: [0x11, 0x22, 0x33, 0x44])
        exe.replaceSubrange(creditsOffset..<(creditsOffset + 4), with: [0xAA, 0xBB, 0xCC, 0xDD])

        let swapped = try ExecutablePatcher.swappingStartAndCreditsSpawn(revision: .xboxPAL, in: exe)

        XCTAssertEqual(Array(swapped[startOffset..<(startOffset + 4)]), [0xAA, 0xBB, 0xCC, 0xDD])
        XCTAssertEqual(Array(swapped[creditsOffset..<(creditsOffset + 4)]), [0x11, 0x22, 0x33, 0x44])
    }

    func testCopyCreditsSpawnToStartLeavesCreditsPointerUnchanged() throws {
        var exe = makeFakeExe(size: 0x300000)
        let startOffset = GameExecutableRevision.pal.startSpawnPointerOffset
        let creditsOffset = GameExecutableRevision.pal.creditsSpawnPointerOffset
        exe.replaceSubrange(startOffset..<(startOffset + 4), with: [0x11, 0x22, 0x33, 0x44])
        exe.replaceSubrange(creditsOffset..<(creditsOffset + 4), with: [0xAA, 0xBB, 0xCC, 0xDD])

        let copied = try ExecutablePatcher.copyingCreditsSpawnToStart(revision: .pal, in: exe)

        XCTAssertEqual(Array(copied[startOffset..<(startOffset + 4)]), [0xAA, 0xBB, 0xCC, 0xDD])
        XCTAssertEqual(Array(copied[creditsOffset..<(creditsOffset + 4)]), [0xAA, 0xBB, 0xCC, 0xDD]) // unchanged
    }

    func testFileTooSmallThrowsRatherThanCrashing() {
        let tinyExe = Data(repeating: 0, count: 10)
        XCTAssertThrowsError(try ExecutablePatcher.writingStartingChunkPath("earth", revision: .pal, into: tinyExe))
        XCTAssertNil(ExecutablePatcher.readStartingChunkPath(revision: .pal, from: tinyExe))
    }

    /// Every revision's four offsets must be distinct, a copy/paste
    /// error that aliased two revisions to the same offset would corrupt
    /// whichever one wasn't intended.
    func testAllRevisionOffsetsAreDistinctPerField() {
        let startingOffsets = GameExecutableRevision.allCases.map { $0.startingChunkField.offset }
        XCTAssertEqual(Set(startingOffsets).count, startingOffsets.count)
        let creditsOffsets = GameExecutableRevision.allCases.map { $0.creditsChunkField.offset }
        XCTAssertEqual(Set(creditsOffsets).count, creditsOffsets.count)
        let startSpawnOffsets = GameExecutableRevision.allCases.map { $0.startSpawnPointerOffset }
        XCTAssertEqual(Set(startSpawnOffsets).count, startSpawnOffsets.count)
    }

    func testGameArchivePathRoundTripsThroughWriter() throws {
        let exe = makeFakeExe(size: 0x400000)
        let patched = try ExecutablePatcher.writingGameArchivePath("MAIN.BD", revision: .ntscU2, into: exe)
        XCTAssertEqual(ExecutablePatcher.readGameArchivePath(revision: .ntscU2, from: patched), "MAIN.BD")
    }

    /// The archive field's offset happens to be the same byte the NTSC-U
    /// probe reads, writing the archive field must still leave that
    /// probe-relevant byte correctly reflecting whatever was written.
    func testGameArchiveFieldOverlapsNTSCUProbeByteCorrectly() throws {
        let exe = makeFakeExe(size: 0x400000)
        let patched = try ExecutablePatcher.writingGameArchivePath("CRASH.B", revision: .ntscU, into: exe)
        XCTAssertEqual(patched[0x1ECB10], UInt8(ascii: "C"))
    }

    func testGameArchiveFieldNotSupportedOnXbox() {
        XCTAssertNil(GameExecutableRevision.xboxNTSC.archiveField)
        XCTAssertNil(GameExecutableRevision.xboxPAL.archiveField)
        let exe = makeFakeExe(size: 0x400000)
        XCTAssertNil(ExecutablePatcher.readGameArchivePath(revision: .xboxNTSC, from: exe))
        XCTAssertThrowsError(try ExecutablePatcher.writingGameArchivePath("MAIN.BD", revision: .xboxNTSC, into: exe)) { error in
            guard case ExecutablePatcherError.fieldNotSupported(let fieldName, let revision) = error else {
                return XCTFail("Expected .fieldNotSupported, got \(error)")
            }
            XCTAssertEqual(fieldName, "Game Archive")
            XCTAssertEqual(revision, .xboxNTSC)
        }
    }

    /// Archive and starting-chunk fields must never alias for any revision
    ///, a copy/paste error here would corrupt one field while patching
    /// the other.
    func testArchiveAndStartingChunkFieldsAreDistinct() {
        for revision in GameExecutableRevision.allCases {
            guard let archive = revision.archiveField else { continue }
            let level = revision.startingChunkField
            let archiveRange = archive.offset..<(archive.offset + archive.length)
            let levelRange = level.offset..<(level.offset + level.length)
            XCTAssertTrue(archiveRange.upperBound <= levelRange.lowerBound || levelRange.upperBound <= archiveRange.lowerBound,
                           "\(revision) archive field overlaps starting-chunk field")
        }
    }

    func testPlatformMapping() {
        XCTAssertEqual(GameExecutableRevision.pal.platform, .ps2)
        XCTAssertEqual(GameExecutableRevision.ntscU.platform, .ps2)
        XCTAssertEqual(GameExecutableRevision.ntscU2.platform, .ps2)
        XCTAssertEqual(GameExecutableRevision.ntscJ.platform, .ps2)
        XCTAssertEqual(GameExecutableRevision.xboxNTSC.platform, .xbox)
        XCTAssertEqual(GameExecutableRevision.xboxPAL.platform, .xbox)
    }
}
