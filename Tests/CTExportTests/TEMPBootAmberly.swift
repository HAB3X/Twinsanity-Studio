import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTExport

/// TEMP: boot directly into the Madame Amberly boss fight
/// (Levels/school/Madame/amberly.rm2) -- a level where Cortex is already
/// the sole real playable character natively, no data patch needed. Its
/// own real path is too long for the boot executable's 23-byte starting-
/// chunk field, so its bytes are substituted into the short-path "beach.rm2"
/// archive slot instead (content is unmodified, just relocated), with
/// "beach" set as the starting chunk. Uses `buildingFresh` (documented as
/// the more reliable, independently-boot-verified rebuild path) instead of
/// the in-place `building`/`rebuildingAndVerifying`, since that path's own
/// docs flag a real "black screen"/crash-on-boot risk this session just
/// hit.
final class TEMPBootAmberly: XCTestCase {
    func testBootAmberlyAsBeach() throws {
        let isoURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/Crash Twinsanity (Europe, Australia) (En,Fr,De,Es,It) copy 2.iso")
        guard FileManager.default.fileExists(atPath: isoURL.path) else { throw XCTSkip("ISO not found") }
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else { throw XCTSkip("Disc not mounted") }

        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))
        guard let amberlyEntry = index.entries.first(where: { $0.name == "Levels/school/Madame/amberly.rm2" }) else {
            throw XCTSkip("amberly.rm2 not found")
        }
        let amberlyBytes = try BDArchiveParser.readEntryData(amberlyEntry, index: index)
        print("amberly.rm2: \(amberlyBytes.count) bytes")

        // Does it have its own paired scenery file? If so, that needs
        // substituting into beach.sm2's slot too.
        let amberlySceneryEntry = index.entries.first(where: { $0.name == "Levels/school/Madame/amberly.sm2" })
        print("amberly.sm2 exists: \(amberlySceneryEntry != nil)")

        var replacements: [String: Data] = ["beach.rm2": amberlyBytes]
        if let sceneryEntry = amberlySceneryEntry {
            let sceneryBytes = try BDArchiveParser.readEntryData(sceneryEntry, index: index)
            replacements["beach.sm2"] = sceneryBytes
            print("also substituting beach.sm2 with amberly.sm2 (\(sceneryBytes.count) bytes)")
        }

        let plan = GameLaunchPlan(startingChunkBaseName: "beach", archiveReplacements: replacements)
        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("BootAmberlyScratch", isDirectory: true)
        try? FileManager.default.removeItem(at: scratchDir)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        let built = try GameLauncher.buildingFresh(isoURL: isoURL, plan: plan, scratchDirectory: scratchDir)
        print("built fresh ISO: \(built.count) bytes")

        let outISO = scratchDir.appendingPathComponent("amberly_boot.iso")
        try GameLauncher.writingVerified(built, to: outISO)
        print("wrote patched ISO to \(outISO.path)")

        let pcsx2URL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/Reference Files/PCSX2-v2.6.3.app")
        try GameLauncher.launching(pcsx2AppURL: pcsx2URL, isoURL: outISO)
        print("launched PCSX2 with patched ISO")
    }
}
