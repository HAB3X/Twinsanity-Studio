import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// `ISO9660ImageBuilder`, builds a real ECMA-119 image from a directory
/// tree from scratch ("Image Maker" parity, see that type's own doc
/// comment for exactly what is and isn't independently verified here).
/// Every test round-trips the built image back through this package's own
/// `ISO9660Reader`, the same discipline every other writer in this
/// codebase is held to.
final class ISO9660ImageBuilderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func readBack(_ image: Data) throws -> ISO9660Entry {
        try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: image))
    }

    func testFlatDirectoryRoundTrips() throws {
        try Data("hello".utf8).write(to: tempDir.appendingPathComponent("A.TXT"))
        try Data("world!!".utf8).write(to: tempDir.appendingPathComponent("B.TXT"))

        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "TWINSANITY")
        XCTAssertEqual(image.count % 2048, 0, "a real ISO-9660 image is always a whole number of sectors")

        let root = try readBack(image)
        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(root.children.count, 2)

        let a = try XCTUnwrap(root.children.first { $0.name == "A.TXT" })
        XCTAssertFalse(a.isDirectory)
        let source = PlainISOSource(data: image)
        XCTAssertEqual(ISO9660Reader.readFile(a, from: source), Data("hello".utf8))

        let b = try XCTUnwrap(root.children.first { $0.name == "B.TXT" })
        XCTAssertEqual(ISO9660Reader.readFile(b, from: source), Data("world!!".utf8))
    }

    func testNestedDirectoriesRoundTrip() throws {
        let sub = tempDir.appendingPathComponent("EARTH")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let subsub = sub.appendingPathComponent("HUB")
        try FileManager.default.createDirectory(at: subsub, withIntermediateDirectories: true)
        try Data("beach level".utf8).write(to: subsub.appendingPathComponent("BEACH.RM2"))
        try Data("root file".utf8).write(to: tempDir.appendingPathComponent("SYSTEM.CNF"))

        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "TEST")
        let root = try readBack(image)

        XCTAssertEqual(root.children.count, 2) // EARTH/ and SYSTEM.CNF
        let earth = try XCTUnwrap(root.children.first { $0.name == "EARTH" })
        XCTAssertTrue(earth.isDirectory)
        let hub = try XCTUnwrap(earth.children.first { $0.name == "HUB" })
        XCTAssertTrue(hub.isDirectory)
        let beach = try XCTUnwrap(hub.children.first { $0.name == "BEACH.RM2" })
        XCTAssertFalse(beach.isDirectory)

        let source = PlainISOSource(data: image)
        XCTAssertEqual(ISO9660Reader.readFile(beach, from: source), Data("beach level".utf8))

        let systemCNF = try XCTUnwrap(root.children.first { $0.name == "SYSTEM.CNF" })
        XCTAssertEqual(ISO9660Reader.readFile(systemCNF, from: source), Data("root file".utf8))
    }

    /// A file whose contents span more than one 2048-byte sector, proves
    /// `sectorCount(for:)`/file-extent placement handles multi-sector
    /// files, not just tiny fixtures.
    func testMultiSectorFileRoundTrips() throws {
        var bigData = Data()
        for i in 0..<5000 { bigData.append(UInt8(i % 256)) } // ~2.4 sectors
        try bigData.write(to: tempDir.appendingPathComponent("BIG.BIN"))

        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "TEST")
        let root = try readBack(image)
        let big = try XCTUnwrap(root.children.first { $0.name == "BIG.BIN" })
        XCTAssertEqual(ISO9660Reader.readFile(big, from: PlainISOSource(data: image)), bigData)
    }

    /// A directory with enough children that its own extent spans more
    /// than one sector, exercises the "don't split a directory record
    /// across a sector boundary" placement logic on both the size-
    /// computation pass and the byte-emission pass.
    func testManyFilesForceMultiSectorDirectoryExtent() throws {
        var expectedNames: Set<String> = []
        for i in 0..<120 {
            let name = "FILE\(String(format: "%03d", i)).TXT"
            try Data("contents \(i)".utf8).write(to: tempDir.appendingPathComponent(name))
            expectedNames.insert(name)
        }

        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "MANY")
        let root = try readBack(image)
        XCTAssertEqual(root.children.count, 120)
        XCTAssertEqual(Set(root.children.map(\.name)), expectedNames)

        let source = PlainISOSource(data: image)
        let file50 = try XCTUnwrap(root.children.first { $0.name == "FILE050.TXT" })
        XCTAssertEqual(ISO9660Reader.readFile(file50, from: source), Data("contents 50".utf8))
    }

    func testEmptyDirectoryProducesAValidReadableImage() throws {
        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "EMPTY")
        let root = try readBack(image)
        XCTAssertTrue(root.isDirectory)
        XCTAssertTrue(root.children.isEmpty)
    }

    /// The Primary Volume Descriptor's own Volume Identifier field must
    /// actually carry the label the caller asked for, a real, directly
    /// checkable field this test reads straight from the image bytes
    /// (offset 40, 32 bytes, ECMA-119 8.4.14), since `ISO9660Reader`
    /// itself never surfaces this field.
    func testVolumeLabelIsWrittenToThePrimaryVolumeDescriptor() throws {
        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "MYDISC")
        let pvdStart = 16 * 2048
        let volumeID = image.subdata(in: (image.startIndex + pvdStart + 40)..<(image.startIndex + pvdStart + 40 + 6))
        XCTAssertEqual(String(data: volumeID, encoding: .ascii), "MYDISC")
    }

    /// Real bug fix: `ISO9660ImageBuilder` uppercases every file/directory
    /// name (`scanDirectory`'s own real ISO-9660 naming convention) with
    /// no collision check on the way in. Two genuinely distinct source
    /// filenames that happen to uppercase to the same string, reproduced
    /// here portably via German "ß", which `String.uppercased()` maps to
    /// "SS" regardless of filesystem case-sensitivity, so this isn't
    /// relying on any particular volume's case-folding behavior, used to
    /// trap the old `Dictionary(uniqueKeysWithValues:)` in
    /// `writeDirectoryExtent` outright. The fixed `reduce(into:)`
    /// first-wins logic must instead silently keep just one of the two and
    /// still produce a valid, readable image.
    func testCollidingUppercasedFilenamesDoNotCrashAndProduceAValidImage() throws {
        try Data("one".utf8).write(to: tempDir.appendingPathComponent("straße.txt"))
        try Data("two".utf8).write(to: tempDir.appendingPathComponent("strasse.txt"))

        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "COLLIDE")
        let root = try readBack(image)

        // Both source files uppercase to the identical ISO name
        // "STRASSE.TXT", first-wins collapses them to exactly one entry,
        // not a crash and not two records silently sharing one slot.
        XCTAssertEqual(root.children.count, 1)
        let survivor = try XCTUnwrap(root.children.first { $0.name == "STRASSE.TXT" })
        let contents = ISO9660Reader.readFile(survivor, from: PlainISOSource(data: image))
        XCTAssertTrue(contents == Data("one".utf8) || contents == Data("two".utf8))
    }

    // MARK: - Path Tables ("Image Maker's Path Tables Verification")

    /// Real, independent verification of the Path Tables, previously
    /// unexercised by any reader in this codebase (see `ISO9660ImageBuilder`'s
    /// own doc comment). Builds a real 3-level directory tree, decodes both
    /// the Type L and Type M Path Tables via the new `ISO9660Reader.
    /// readPathTable`, and cross-checks every entry against the same
    /// directories' own directory-record LBAs (`readRootDirectory`'s own,
    /// already-verified tree), not just checking the two tables agree
    /// with each other, but that they agree with the *actual* disc layout.
    func testPathTablesMatchTheRealDirectoryTreeAndBothEndiannessesAgree() throws {
        let sub = tempDir.appendingPathComponent("EARTH")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let subsub = sub.appendingPathComponent("HUB")
        try FileManager.default.createDirectory(at: subsub, withIntermediateDirectories: true)
        try Data("beach level".utf8).write(to: subsub.appendingPathComponent("BEACH.RM2"))
        try Data("root file".utf8).write(to: tempDir.appendingPathComponent("SYSTEM.CNF"))

        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "PATHTEST")
        let source = PlainISOSource(data: image)
        let root = try readBack(image)
        let earth = try XCTUnwrap(root.children.first { $0.name == "EARTH" })
        let hub = try XCTUnwrap(earth.children.first { $0.name == "HUB" })

        let pvdInfo = try ISO9660Reader.readPrimaryVolumeDescriptorInfo(from: source)
        XCTAssertGreaterThan(pvdInfo.pathTableByteSize, 0)
        XCTAssertNotEqual(pvdInfo.pathTableLBA_L, pvdInfo.pathTableLBA_M, "the two tables must live at different LBAs, not overlap")

        let tableL = ISO9660Reader.readPathTable(from: source, lba: pvdInfo.pathTableLBA_L, byteSize: pvdInfo.pathTableByteSize, bigEndian: false)
        let tableM = ISO9660Reader.readPathTable(from: source, lba: pvdInfo.pathTableLBA_M, byteSize: pvdInfo.pathTableByteSize, bigEndian: true)

        // Real directory count: root, EARTH, HUB, three Path Table Records.
        XCTAssertEqual(tableL.count, 3)
        XCTAssertEqual(tableM.count, 3)

        // The defining property of a correct dual-encoded Path Table pair:
        // decoding each with its own real endianness must produce
        // identical logical values, proving `writeUInt32BE`/`writeUInt16BE`
        // aren't silently writing little-endian bytes twice (a real,
        // catchable bug this specific check exists for).
        for (l, m) in zip(tableL, tableM) {
            XCTAssertEqual(l.name, m.name)
            XCTAssertEqual(l.parentIndex, m.parentIndex)
            XCTAssertEqual(l.lba, m.lba)
        }

        // Root entry: real ECMA-119 convention is an empty/NUL name, parent
        // index 1 (points at itself), and its LBA must match the exact
        // same root the independently-verified directory-record reader found.
        let rootEntry = try XCTUnwrap(tableL.first)
        XCTAssertEqual(rootEntry.name, "")
        XCTAssertEqual(rootEntry.parentIndex, 1)
        XCTAssertEqual(rootEntry.lba, root.lba)

        // EARTH: real name, parent index 1 (its parent, root, is table index 1).
        let earthEntry = try XCTUnwrap(tableL.first { $0.name == "EARTH" })
        XCTAssertEqual(earthEntry.parentIndex, 1)
        XCTAssertEqual(earthEntry.lba, earth.lba, "the Path Table's LBA for EARTH must match its own real directory record's LBA")

        // HUB: its parent index must resolve back to EARTH's own 1-based
        // table position, the real parent-child chain the Path Table
        // exists to encode, not just "some" value.
        let earthTableIndex = UInt16((tableL.firstIndex { $0.name == "EARTH" } ?? -1) + 1)
        let hubEntry = try XCTUnwrap(tableL.first { $0.name == "HUB" })
        XCTAssertEqual(hubEntry.parentIndex, earthTableIndex)
        XCTAssertEqual(hubEntry.lba, hub.lba)
    }

    /// A path table's records are sorted by ECMA-119 rule (parent
    /// directory number, then name), this only has real, independent
    /// meaning to check once there's more than one directory at the same
    /// level to potentially mis-order.
    func testPathTableOrdersSiblingsByParentThenName() throws {
        for name in ["ZEBRA", "APPLE", "MANGO"] {
            try FileManager.default.createDirectory(at: tempDir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "SORTED")
        let source = PlainISOSource(data: image)
        let pvdInfo = try ISO9660Reader.readPrimaryVolumeDescriptorInfo(from: source)
        let table = ISO9660Reader.readPathTable(from: source, lba: pvdInfo.pathTableLBA_L, byteSize: pvdInfo.pathTableByteSize, bigEndian: false)
        let siblingNames = table.dropFirst().map(\.name) // drop the root entry
        XCTAssertEqual(siblingNames, siblingNames.sorted(), "ECMA-119 8.6.2's own ordering rule: same-parent entries in ascending name order")
    }
}
