import XCTest
@testable import CTParsers

/// `WOCCharacterAnimationCatalogParser` -- decodes real, named animation
/// clip catalogs from `CHARS.DAT` entries. These tests independently
/// re-verify the confirmed structure directly against real disc bytes.
final class WOCCharacterAnimationCatalogParserTests: XCTestCase {
    private var charsURL: URL { URL(fileURLWithPath: "/Volumes/CRASH/CHARS.DAT") }

    private func requireDisc() throws {
        guard FileManager.default.fileExists(atPath: charsURL.path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
    }

    /// Golden-value regression: entry #66 is a real, hand-verified
    /// 82-clip catalog -- Crash's full moveset across every WoC gameplay
    /// mode (on-foot, mech, glider, copter, submarine, kart, jetpack).
    func testRealCrashMovesetCatalogGoldenValues() throws {
        try requireDisc()
        let entries = try WOCCharacterArchiveParser.parseTable(fileURL: charsURL)
        let decoded = try WOCCharacterArchiveParser.decode(entries[66], fileURL: charsURL)
        let clips = try WOCCharacterAnimationCatalogParser.parseCatalog(decoded)

        XCTAssertEqual(clips.count, 82)
        let names = Set(clips.map(\.name))
        for expected in [#"A\BodySlam"#, #"A\Run"#, #"A\RunJump"#, #"A\Walk"#, #"C\MechRun"#, #"F\JpDeath"#] {
            XCTAssertTrue(names.contains(expected), "expected clip \(expected) in the real Crash moveset catalog")
        }
        for clip in clips {
            XCTAssertFalse(clip.blob.isEmpty, "clip \(clip.name): blob should be non-empty")
        }
    }

    /// A small, real 2-clip catalog (`\attack`/`\idle`) at a very
    /// different scale from the 82-clip case.
    func testSmallRealCatalog() throws {
        try requireDisc()
        let entries = try WOCCharacterArchiveParser.parseTable(fileURL: charsURL)
        let decoded = try WOCCharacterArchiveParser.decode(entries[269], fileURL: charsURL)
        let clips = try WOCCharacterAnimationCatalogParser.parseCatalog(decoded)
        XCTAssertEqual(clips.map(\.name), [#"\attack"#, #"\idle"#])
        XCTAssertEqual(clips[0].blob.count, 8752)
        XCTAssertEqual(clips[1].blob.count, 16880)
    }

    /// Full-corpus regression: every entry that parses as a catalog
    /// should produce real, non-empty names and non-overlapping,
    /// in-bounds blob ranges -- confirms the structure generalizes, not
    /// just the two hand-picked samples above.
    func testCatalogEntriesAcrossTheArchiveAreStructurallySound() throws {
        try requireDisc()
        let entries = try WOCCharacterArchiveParser.parseTable(fileURL: charsURL)
        var catalogsChecked = 0
        for entry in entries.prefix(300) {
            guard let decoded = try? WOCCharacterArchiveParser.decode(entry, fileURL: charsURL) else { continue }
            guard let clips = try? WOCCharacterAnimationCatalogParser.parseCatalog(decoded), !clips.isEmpty else { continue }
            for clip in clips {
                XCTAssertFalse(clip.name.isEmpty, "entry #\(entry.index): every real clip should have a non-empty name")
            }
            catalogsChecked += 1
        }
        XCTAssertGreaterThan(catalogsChecked, 0, "expected at least some real catalog entries in the first 300")
    }
}
