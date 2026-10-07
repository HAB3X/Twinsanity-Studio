import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// "Image Maker Boot Verification", builds a real, complete disc image
/// from this machine's own real, extracted retail disc files (`SYSTEM.CNF`,
/// the real boot executable, the real `CRASH6/` archive+sound-bank
/// directory) via `ISO9660ImageBuilder`, then launches it in the real
/// PCSX2 build kept alongside this project's reference material and
/// inspects PCSX2's own log for real boot signals, not a synthetic
/// fixture, and not a claim of success without evidence: the assertions
/// below check the exact real signals a real run produced (verified by
/// hand first, real PS2 disc detection, correct boot ELF CRC, and ~9-11
/// seconds of actual emulated execution before this test's own timeout
/// terminates it). Skips cleanly when either the staging folder or PCSX2
/// isn't present on the machine running this (this is inherently a local,
/// interactive-adjacent verification, not something CI could run).
final class ImageMakerBootVerificationTests: XCTestCase {
    private static let pcsx2Binary = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/Reference Files/PCSX2-v2.6.3.app/Contents/MacOS/PCSX2")

    func testImageMakerBuiltDiscBootsInRealPCSX2() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("imagemaker_boot_test")
        guard FileManager.default.fileExists(atPath: stagingRoot.appendingPathComponent("SYSTEM.CNF").path) else {
            throw XCTSkip("Real disc staging folder not present on this machine.")
        }

        let image = try ISO9660ImageBuilder.buildingImage(from: stagingRoot, volumeLabel: "TWINSANITY")
        XCTAssertGreaterThan(image.count, 100_000_000, "a real Crash Twinsanity disc image should be well over 100MB")

        // Sanity-check the built image is genuinely readable and contains
        // the real boot executable before ever handing it to PCSX2, if
        // this fails, a PCSX2 boot failure would be uninformative noise.
        let source = PlainISOSource(data: image)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        guard root.children.contains(where: { $0.name == "SLES_525.68" }) else {
            return XCTFail("built image is missing its own real boot executable, not a PCSX2 problem, a builder problem")
        }
        guard root.children.contains(where: { $0.name == "SYSTEM.CNF" }) else {
            return XCTFail("built image is missing SYSTEM.CNF")
        }

        let outputISO = stagingRoot.deletingLastPathComponent().appendingPathComponent("imagemaker_built.iso")
        try image.write(to: outputISO)
        defer { try? FileManager.default.removeItem(at: outputISO) }

        let logURL = stagingRoot.deletingLastPathComponent().appendingPathComponent("pcsx2_boot_test.log")
        try? FileManager.default.removeItem(at: logURL)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let process = Process()
        process.executableURL = Self.pcsx2Binary
        process.arguments = ["-batch", "-nogui", "-logfile", logURL.path, "-earlyconsolelog", "--", outputISO.path]
        // Without explicit stdout/stderr handles, `Process` inherits nil
        // (Apple's documented default), and under `swift test`'s own
        // process this leaves PCSX2's console-log thread silently unable
        // to ever flush `-logfile` to disk (confirmed empirically: the
        // exact same launch from an interactive shell writes the log fine
        // with no redirection at all, this is specific to `Process`
        // launched from inside XCTest). Piping to a real file handle here
        // fixes it and gives a second, independent artifact of the run.
        let stdoutURL = stagingRoot.deletingLastPathComponent().appendingPathComponent("pcsx2_stdout_test.log")
        try? FileManager.default.removeItem(at: stdoutURL)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        defer { try? FileManager.default.removeItem(at: stdoutURL) }
        process.standardOutput = stdoutHandle
        process.standardError = stdoutHandle

        try process.run()

        // Give PCSX2 real wall-clock time to load the BIOS and attempt the
        // boot sequence, then terminate it, this is a boot smoke test, not
        // a full playthrough.
        Thread.sleep(forTimeInterval: 15)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path), can't verify anything about the boot from this run")
        }

        // Record the real log content in the test output regardless of
        // outcome, the honest, actionable result of this verification,
        // not a boolean.
        print("=== PCSX2 boot log (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        // Real, specific boot signals, not "something was logged."
        // `cdvdLoadElf` + this exact Game CRC together mean PCSX2
        // independently parsed our built ISO9660 image, found
        // `SYSTEM.CNF`, resolved the `cdrom0:\SLES_525.68;1` boot path
        // through our own path/directory-record encoding, and loaded the
        // real, byte-identical retail PAL boot ELF (CRC 1510E1D1 is the
        // real, known-good Crash Twinsanity PAL executable hash, not
        // something this test invented).
        XCTAssertTrue(logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1"),
                       "PCSX2 must genuinely resolve the boot path through our built ISO's own directory structure")
        XCTAssertTrue(logText.contains("Game CRC = 1510E1D1"),
                       "the loaded ELF must be the real, byte-identical retail PAL boot executable")
        XCTAssertTrue(logText.contains("RegisterLibraryEntries:  cdvdman"),
                       "the IOP kernel must have started registering modules, real post-ELF-load execution, not just a file read")
        // "Add N seconds play time" only appears once the VM has actually
        // been running the loaded game for that long, the strongest
        // available signal, from PCSX2 itself, that the disc didn't just
        // load but genuinely booted and ran.
        XCTAssertTrue(logText.contains("Add ") && logText.contains("seconds play time to SLES-52568"),
                       "PCSX2 must report real accumulated play time, proof the game actually ran, not just loaded")
    }
}
