import XCTest
@testable import CTParsers
@testable import CTModels

final class SystemCNFParserTests: XCTestCase {
    func testParsesNTSCUSerialFromRealBootLine() {
        let contents = """
        BOOT2 = cdrom0:\\SLUS_205.54;1
        VER = 1.00
        VMODE = NTSC
        """
        let info = SystemCNFParser.parse(contents: contents)
        XCTAssertEqual(info.serial, "SLUS_205.54")
        XCTAssertEqual(info.region, .ntscU)
        XCTAssertEqual(info.videoMode, "NTSC")
        XCTAssertEqual(info.bootPath, "cdrom0:\\SLUS_205.54;1")
    }

    func testParsesPALSerial() {
        let contents = "BOOT2 = cdrom0:\\SLES_531.12;1\nVMODE = PAL\n"
        let info = SystemCNFParser.parse(contents: contents)
        XCTAssertEqual(info.region, .pal)
    }

    func testParsesJapaneseSerial() {
        let contents = "BOOT2 = cdrom0:\\SLPS_251.01;1\nVMODE = NTSC\n"
        let info = SystemCNFParser.parse(contents: contents)
        XCTAssertEqual(info.region, .ntscJ)
    }

    /// A malformed/empty SYSTEM.CNF must resolve to `.unknown`, never a
    /// guessed default region.
    func testMissingBootLineIsUnknownNotGuessed() {
        let info = SystemCNFParser.parse(contents: "VER = 1.00\n")
        XCTAssertNil(info.serial)
        XCTAssertEqual(info.region, .unknown)
    }

    /// VMODE alone (no recognized serial prefix) still confirms PAL , 
    /// a real, if partial, signal shouldn't be discarded just because the
    /// serial prefix table didn't match.
    func testUnrecognizedSerialFallsBackToVideoModeForPAL() {
        let info = SystemCNFParser.parse(contents: "BOOT2 = cdrom0:\\XXXX_000.00;1\nVMODE = PAL\n")
        XCTAssertEqual(info.region, .pal)
    }
}
