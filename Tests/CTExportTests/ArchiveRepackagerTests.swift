import XCTest
import CTCore
import CTModels
import CTParsers
@testable import CTExport

final class ArchiveRepackagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeSyntheticArchive(entries: [(name: String, bytes: [UInt8])]) throws -> ArchiveIndex {
        let bhURL = tempDir.appendingPathComponent("orig.BH")
        let bdURL = tempDir.appendingPathComponent("orig.BD")
        var bh = BinaryWriter()
        bh.writeInt32(0x501)
        var bd = Data()
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            bh.writeInt32(Int32(nameBytes.count))
            bh.writeBytes(nameBytes)
            bh.writeUInt32(UInt32(bd.count))
            bh.writeUInt32(UInt32(entry.bytes.count))
            bd.append(contentsOf: entry.bytes)
        }
        try bh.data.write(to: bhURL)
        try bd.write(to: bdURL)
        return try BDArchiveParser.readIndex(bhURL: bhURL)
    }

    func testReplacesNamedEntryAndPreservesOthersUnchanged() throws {
        let index = try writeSyntheticArchive(entries: [
            ("keep.txt", Array("original".utf8)),
            ("swap.txt", Array("old-data".utf8))
        ])

        let newBH = tempDir.appendingPathComponent("out.BH")
        let newBD = tempDir.appendingPathComponent("out.BD")
        try ArchiveRepackager.repackage(
            index: index,
            replacements: ["swap.txt": Data("NEW-DATA!!".utf8)],
            outputBH: newBH,
            outputBD: newBD
        )

        let rebuilt = try BDArchiveParser.readIndex(bhURL: newBH)
        XCTAssertEqual(rebuilt.entries.count, 2)

        let keep = try XCTUnwrap(rebuilt.entries.first { $0.name == "keep.txt" })
        XCTAssertEqual(String(data: try BDArchiveParser.readEntryData(keep, index: rebuilt), encoding: .utf8), "original")

        let swap = try XCTUnwrap(rebuilt.entries.first { $0.name == "swap.txt" })
        XCTAssertEqual(String(data: try BDArchiveParser.readEntryData(swap, index: rebuilt), encoding: .utf8), "NEW-DATA!!")
    }

    func testAppendsNewEntriesNotPresentInOriginal() throws {
        let index = try writeSyntheticArchive(entries: [("a.txt", Array("a".utf8))])
        let newBH = tempDir.appendingPathComponent("out2.BH")
        let newBD = tempDir.appendingPathComponent("out2.BD")
        try ArchiveRepackager.repackage(index: index, replacements: ["b.txt": Data("b".utf8)], outputBH: newBH, outputBD: newBD)

        let rebuilt = try BDArchiveParser.readIndex(bhURL: newBH)
        XCTAssertEqual(Set(rebuilt.entries.map(\.name)), ["a.txt", "b.txt"])
    }

    func testRefusesToOverwriteExistingOutput() throws {
        let index = try writeSyntheticArchive(entries: [("a.txt", [1])])
        let newBH = tempDir.appendingPathComponent("out3.BH")
        let newBD = tempDir.appendingPathComponent("out3.BD")
        try Data().write(to: newBH)
        XCTAssertThrowsError(try ArchiveRepackager.repackage(index: index, replacements: [:], outputBH: newBH, outputBD: newBD))
    }

    /// Regression test for a real, measured bug: a real retail disc's raw
    /// `.BH` bytes use `\` as the path separator (verified directly against
    /// a real disc, "Startup\Fonts\Crash_Euro.psf"), but `BDArchiveParser
    /// .readIndex` normalizes every name to `/` for this app's own internal
    /// use. Writing that normalized `entry.name` straight back to disk
    /// silently corrupted every single entry's separator (not just the
    /// edited one -- *every* entry gets rewritten by `repackage`), on any
    /// archive edit at all. The real, reported symptom this caused: the
    /// edited disc booted, and its own data read back correctly through
    /// this project's own tools (which only ever see the normalized name),
    /// but the actual game hung partway through loading in real PCSX2 --
    /// consistent with the game's own runtime archive lookups failing to
    /// match a forward-slash name.
    func testWritesRealDiscBackslashSeparatorsNotTheInMemoryNormalizedForm() throws {
        // `writeSyntheticArchive` writes this name's raw bytes verbatim (no
        // normalization on write -- only `BDArchiveParser.readIndex` does
        // that), so a backslash-separated name here really does put `\` on
        // disk, matching a real archive's own raw bytes exactly.
        let index = try writeSyntheticArchive(entries: [
            ("Levels\\Earth\\Hub\\beach.rm2", Array("original".utf8)),
        ])
        // Sanity: `BDArchiveParser` really did normalize it in memory --
        // this is the exact shape every real call site in this app sees.
        XCTAssertEqual(index.entries.first?.name, "Levels/Earth/Hub/beach.rm2")

        let newBH = tempDir.appendingPathComponent("out4.BH")
        let newBD = tempDir.appendingPathComponent("out4.BD")
        // Replaced by its own *normalized* name, exactly like every real
        // call site does (`GameLaunchPlan.archiveReplacements` keys are
        // matched against `entry.name`, the normalized form).
        try ArchiveRepackager.repackage(
            index: index,
            replacements: ["Levels/Earth/Hub/beach.rm2": Data("edited".utf8)],
            outputBH: newBH, outputBD: newBD
        )

        // Read the *raw* bytes straight off disk, bypassing
        // `BDArchiveParser`'s own normalization, to check what was
        // actually written -- this is what a real game's own archive
        // reader would see.
        let rawBH = try Data(contentsOf: newBH)
        let rawString = String(decoding: rawBH, as: UTF8.self)
        XCTAssertTrue(rawString.contains("Levels\\Earth\\Hub\\beach.rm2"),
                      "the repackaged .BH's raw on-disk bytes must use the real disc's own backslash separator, not this app's internal forward-slash normalization -- raw bytes: \(rawString)")
        XCTAssertFalse(rawString.contains("Levels/Earth/Hub/beach.rm2"),
                       "the repackaged .BH must not contain the normalized forward-slash form anywhere in its raw on-disk name bytes")
    }
}
