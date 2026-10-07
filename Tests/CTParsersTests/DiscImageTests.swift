import XCTest
@testable import CTParsers

/// "Native ISO & BIN/CUE Disc Image Mounting" (Task 7), builds a real,
/// spec-compliant (ECMA-119) synthetic ISO-9660 image byte-for-byte (the
/// same "construct real bytes, verify the reader round-trips them"
/// discipline every other parser in this package is tested with) and
/// verifies `ISO9660Reader` parses it correctly, both as a plain `.iso`
/// and re-framed as raw `.bin`/`.cue` sectors.
final class DiscImageTests: XCTestCase {
    private static let sectorSize = 2048

    private func bothEndian32(_ v: UInt32) -> [UInt8] {
        let le: [UInt8] = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        return le + le.reversed()
    }

    private func bothEndian16(_ v: UInt16) -> [UInt8] {
        let le: [UInt8] = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
        return le + le.reversed()
    }

    private func directoryRecord(lba: UInt32, size: UInt32, isDirectory: Bool, identifier: [UInt8]) -> [UInt8] {
        var rest: [UInt8] = [0] // Extended Attribute Record length
        rest += bothEndian32(lba)
        rest += bothEndian32(size)
        rest += [UInt8](repeating: 0, count: 7) // recording date/time
        rest.append(isDirectory ? 0x02 : 0x00) // file flags
        rest.append(0) // file unit size
        rest.append(0) // interleave gap size
        rest += bothEndian16(1) // volume sequence number
        rest.append(UInt8(identifier.count)) // LEN_FI
        rest += identifier
        var total = 1 + rest.count // +1 for the LEN_DR byte itself
        if total % 2 != 0 {
            rest.append(0)
            total += 1
        }
        return [UInt8(total)] + rest
    }

    private func makeSector(_ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count <= Self.sectorSize)
        return bytes + [UInt8](repeating: 0, count: Self.sectorSize - bytes.count)
    }

    /// A real, minimal but spec-compliant ISO-9660 image:
    /// sectors 0-15 reserved, 16 = PVD, 17 = terminator, 18 = root
    /// directory (., .., TEST.TXT;1, SUBDIR), 19 = SUBDIR's own directory
    /// (., .., NESTED.TXT;1), 20 = TEST.TXT's real content, 21 =
    /// NESTED.TXT's real content.
    private func buildSyntheticISOSectors() -> [[UInt8]] {
        let testContent = Array("Hello, ISO 9660!".utf8)
        let nestedContent = Array("Nested file content.".utf8)

        var sectors: [[UInt8]] = (0..<22).map { _ in makeSector([]) }

        var pvd: [UInt8] = [1] // type = Primary Volume Descriptor
        pvd += Array("CD001".utf8)
        pvd.append(1) // version
        pvd = pvd + [UInt8](repeating: 0, count: 156 - pvd.count)
        pvd += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        sectors[16] = makeSector(pvd)

        var terminator: [UInt8] = [255]
        terminator += Array("CD001".utf8)
        terminator.append(1)
        sectors[17] = makeSector(terminator)

        var root: [UInt8] = []
        root += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        root += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [1])
        root += directoryRecord(lba: 20, size: UInt32(testContent.count), isDirectory: false, identifier: Array("TEST.TXT;1".utf8))
        root += directoryRecord(lba: 19, size: UInt32(Self.sectorSize), isDirectory: true, identifier: Array("SUBDIR".utf8))
        sectors[18] = makeSector(root)

        var subdir: [UInt8] = []
        subdir += directoryRecord(lba: 19, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        subdir += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [1])
        subdir += directoryRecord(lba: 21, size: UInt32(nestedContent.count), isDirectory: false, identifier: Array("NESTED.TXT;1".utf8))
        sectors[19] = makeSector(subdir)

        sectors[20] = makeSector(testContent)
        sectors[21] = makeSector(nestedContent)

        return sectors
    }

    func testReadsRootDirectoryFromPlainISOImage() throws {
        let sectors = buildSyntheticISOSectors()
        let flatData = Data(sectors.flatMap { $0 })
        let source = PlainISOSource(data: flatData)

        let root = try ISO9660Reader.readRootDirectory(from: source)
        let names = Set(root.children.map(\.name))
        XCTAssertEqual(names, ["TEST.TXT", "SUBDIR"], "'.' and '..' must be skipped, and the real ;1 version suffix stripped")

        guard let testFile = root.children.first(where: { $0.name == "TEST.TXT" }) else {
            return XCTFail("TEST.TXT missing")
        }
        XCTAssertFalse(testFile.isDirectory)
        let content = ISO9660Reader.readFile(testFile, from: source)
        XCTAssertEqual(content.map { String(data: $0, encoding: .utf8) }, "Hello, ISO 9660!")

        guard let subdir = root.children.first(where: { $0.name == "SUBDIR" }) else {
            return XCTFail("SUBDIR missing")
        }
        XCTAssertTrue(subdir.isDirectory)
        XCTAssertEqual(subdir.children.map(\.name), ["NESTED.TXT"])
        let nestedContent = ISO9660Reader.readFile(subdir.children[0], from: source)
        XCTAssertEqual(nestedContent.map { String(data: $0, encoding: .utf8) }, "Nested file content.")
    }

    /// Same real logical content, re-framed as raw MODE1/2352 `.bin`
    /// sectors (arbitrary non-zero sync/header/ECC bytes surrounding each
    /// real 2048-byte payload, to prove the reader only ever looks at the
    /// real user-data offset and ignores the rest), proves the whole
    /// real CueSheetParser -> BinCueLogicalSource -> ISO9660Reader
    /// pipeline round-trips identically to the plain-.iso path.
    func testReadsSameImageThroughBinCueMode1Framing() throws {
        let logicalSectors = buildSyntheticISOSectors()
        var rawBin: [UInt8] = []
        for sector in logicalSectors {
            rawBin += [UInt8](repeating: 0xAA, count: 16) // sync + header stand-in
            rawBin += sector
            rawBin += [UInt8](repeating: 0xBB, count: 2352 - 16 - Self.sectorSize) // EDC/zero/ECC stand-in
        }
        let binData = Data(rawBin)

        let cue = try CueSheetParser.parse(contents: "FILE \"disc.bin\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n")
        XCTAssertEqual(cue.binFileName, "disc.bin")
        XCTAssertEqual(cue.framing, .mode1_2352)

        let source = BinCueLogicalSource(binData: binData, framing: cue.framing)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        guard let testFile = root.children.first(where: { $0.name == "TEST.TXT" }) else {
            return XCTFail("TEST.TXT missing through bin/cue framing")
        }
        let content = ISO9660Reader.readFile(testFile, from: source)
        XCTAssertEqual(content.map { String(data: $0, encoding: .utf8) }, "Hello, ISO 9660!")
    }

    func testCueParserRejectsUnsupportedTrackMode() {
        XCTAssertThrowsError(try CueSheetParser.parse(contents: "FILE \"disc.bin\" BINARY\nTRACK 01 MODE2/2336\n")) { error in
            XCTAssertEqual(error as? CueSheetParser.ParseError, .unsupportedTrackMode("MODE2/2336"))
        }
    }

    func testCueParserRequiresAFileLine() {
        XCTAssertThrowsError(try CueSheetParser.parse(contents: "TRACK 01 MODE1/2352\n")) { error in
            XCTAssertEqual(error as? CueSheetParser.ParseError, .missingFileLine)
        }
    }

    func testNonISOImageThrowsRatherThanReturningAnEmptyTree() {
        let garbage = Data(repeating: 0x42, count: 22 * Self.sectorSize)
        XCTAssertThrowsError(try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: garbage))) { error in
            XCTAssertEqual(error as? ISO9660Error, .notAnISO9660Image)
        }
    }

    // MARK: - ISO9660Writer

    func testReplaceFileInPlaceSameSizeUpdatesContentOnly() throws {
        let sectors = buildSyntheticISOSectors()
        let originalImage = Data(sectors.flatMap { $0 })
        let root = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: originalImage))
        guard let testFile = root.children.first(where: { $0.name == "TEST.TXT" }) else { return XCTFail("TEST.TXT missing") }
        XCTAssertEqual(testFile.lba, 20)

        let replacement = Data("Goodbye ISO 9660".utf8)  // same length as "Hello, ISO 9660!" (16 bytes)
        XCTAssertEqual(replacement.count, 16)
        let newImage = try ISO9660Writer.replacingFile(testFile, with: replacement, in: originalImage)
        XCTAssertEqual(newImage.count, originalImage.count, "in-place same-size replacement must not change the image's total length")

        let newRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: newImage))
        let newTestFile = try XCTUnwrap(newRoot.children.first(where: { $0.name == "TEST.TXT" }))
        XCTAssertEqual(newTestFile.lba, 20, "same-size replacement must not relocate the file")
        XCTAssertEqual(ISO9660Reader.readFile(newTestFile, from: PlainISOSource(data: newImage)), replacement)

        // The sibling directory (SUBDIR/NESTED.TXT) must be completely untouched.
        let subdir = try XCTUnwrap(newRoot.children.first(where: { $0.name == "SUBDIR" }))
        let nested = try XCTUnwrap(subdir.children.first(where: { $0.name == "NESTED.TXT" }))
        XCTAssertEqual(ISO9660Reader.readFile(nested, from: PlainISOSource(data: newImage)).map { String(data: $0, encoding: .utf8) }, "Nested file content.")
    }

    func testReplaceFileInPlaceSmallerPadsAndShrinksSizeField() throws {
        let sectors = buildSyntheticISOSectors()
        let originalImage = Data(sectors.flatMap { $0 })
        let root = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: originalImage))
        let testFile = try XCTUnwrap(root.children.first(where: { $0.name == "TEST.TXT" }))

        let replacement = Data("Hi".utf8)
        let newImage = try ISO9660Writer.replacingFile(testFile, with: replacement, in: originalImage)
        XCTAssertEqual(newImage.count, originalImage.count, "still fits inside the originally-reserved single sector")

        let newRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: newImage))
        let newTestFile = try XCTUnwrap(newRoot.children.first(where: { $0.name == "TEST.TXT" }))
        XCTAssertEqual(newTestFile.size, 2, "the directory record's size field must shrink to the real new content length, not the zero-padded sector size")
        XCTAssertEqual(ISO9660Reader.readFile(newTestFile, from: PlainISOSource(data: newImage)), replacement)
    }

    func testReplaceFileLargerAppendsPastEndAndRelocates() throws {
        let sectors = buildSyntheticISOSectors()
        let originalImage = Data(sectors.flatMap { $0 })
        let root = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: originalImage))
        let testFile = try XCTUnwrap(root.children.first(where: { $0.name == "TEST.TXT" }))

        // Larger than the single sector TEST.TXT originally occupied.
        let replacement = Data(repeating: 0x58, count: Self.sectorSize + 500)
        let newImage = try ISO9660Writer.replacingFile(testFile, with: replacement, in: originalImage)
        XCTAssertGreaterThan(newImage.count, originalImage.count, "must grow the image to fit the relocated file")

        let newRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: newImage))
        let newTestFile = try XCTUnwrap(newRoot.children.first(where: { $0.name == "TEST.TXT" }))
        XCTAssertGreaterThanOrEqual(newTestFile.lba, 22, "must relocate past the original image's own sectors")
        XCTAssertEqual(newTestFile.size, UInt32(replacement.count))
        XCTAssertEqual(ISO9660Reader.readFile(newTestFile, from: PlainISOSource(data: newImage)), replacement)

        // The sibling directory (SUBDIR/NESTED.TXT, at the old LBAs) must still read correctly.
        let subdir = try XCTUnwrap(newRoot.children.first(where: { $0.name == "SUBDIR" }))
        let nested = try XCTUnwrap(subdir.children.first(where: { $0.name == "NESTED.TXT" }))
        XCTAssertEqual(ISO9660Reader.readFile(nested, from: PlainISOSource(data: newImage)).map { String(data: $0, encoding: .utf8) }, "Nested file content.")
    }

    /// Regression test for a real bug: relocating a file past the end of
    /// the image (the "larger" path above) grew the image's real byte
    /// count without ever updating the Primary Volume Descriptor's own
    /// "Volume Space Size" field (ECMA-119 8.4.8, PVD offset 80,
    /// both-endian `UInt32`), leaving a rebuilt disc whose declared volume
    /// size was smaller than its real content. Measured against a real
    /// retail PAL disc, this left the game's actual level/asset data
    /// sitting in disc space the volume descriptor itself claimed didn't
    /// exist.
    func testReplaceFileLargerKeepsVolumeSpaceSizeInSyncWithTheRelocatedImage() throws {
        let sectors = buildSyntheticISOSectors()
        let originalImage = Data(sectors.flatMap { $0 })
        let root = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: originalImage))
        let testFile = try XCTUnwrap(root.children.first(where: { $0.name == "TEST.TXT" }))

        let replacement = Data(repeating: 0x58, count: Self.sectorSize + 500)
        let newImage = try ISO9660Writer.replacingFile(testFile, with: replacement, in: originalImage)
        XCTAssertEqual(newImage.count % Self.sectorSize, 0, "a relocated image must stay sector-aligned")

        let pvdBase = newImage.startIndex + 16 * Self.sectorSize
        let leBytes = Array(newImage[(pvdBase + 80)..<(pvdBase + 84)])
        let declaredVolumeSpaceSize = leBytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
        XCTAssertEqual(Int(declaredVolumeSpaceSize), newImage.count / Self.sectorSize,
                       "the PVD's own declared Volume Space Size must cover the image's real total size after relocation, not the pre-relocation original size")
        // The big-endian copy (ECMA-119 7.3.1's own dual-endian convention) must be kept in sync too.
        let beBytes = Array(newImage[(pvdBase + 84)..<(pvdBase + 88)])
        let declaredVolumeSpaceSizeBE = beBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(declaredVolumeSpaceSizeBE, declaredVolumeSpaceSize)
    }

    /// Regression test for a real, measured, and far more serious bug: an
    /// earlier version of this writer reused a relocated file's *previous*
    /// location for a later relocation, on the theory that any byte range
    /// the image's own ISO9660 directory tree doesn't reference must be
    /// safe filler. Verified false against a real retail disc, this
    /// game's disc carries only a few dozen files in its entire ISO9660
    /// tree, and a huge byte range between two of those tracked files that
    /// the old gap scan confidently reused for a relocated archive turned
    /// out to be dense with real, non-zero, structured data something
    /// reads by a mechanism outside the ISO9660 layer entirely (see this
    /// file's own top-level doc comment). Reusing space this writer didn't
    /// itself just vacate is therefore never safe in general: this
    /// confirms a *second* relocation still appends past the true end of
    /// the image rather than reusing the first relocation's now-orphaned
    /// slot, even though that slot would fit.
    func testReplaceFileLargerAlwaysAppendsEvenWhenAnEarlierRelocationLeftAReusableGap() throws {
        let sectors = buildSyntheticISOSectors()
        let originalImage = Data(sectors.flatMap { $0 })
        let root = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: originalImage))
        let testFile = try XCTUnwrap(root.children.first(where: { $0.name == "TEST.TXT" }))

        // First relocation: nothing orphaned yet, so this must append to
        // the true end, same as testReplaceFileLargerAppendsPastEndAndRelocates.
        let firstReplacement = Data(repeating: 0x58, count: Self.sectorSize + 500)
        let afterFirst = try ISO9660Writer.replacingFile(testFile, with: firstReplacement, in: originalImage)
        XCTAssertGreaterThan(afterFirst.count, originalImage.count, "sanity: the first relocation has nothing to reuse yet")

        // Second relocation: NESTED.TXT (21 real bytes, 1 reserved sector,
        // originally at TEST.TXT's own old LBA + 1) grows to something that
        // would fit, once sector-padded, in exactly the one orphaned sector
        // TEST.TXT's *original* location left behind, but must not land
        // there.
        let afterFirstRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: afterFirst))
        let subdir = try XCTUnwrap(afterFirstRoot.children.first(where: { $0.name == "SUBDIR" }))
        let nestedFile = try XCTUnwrap(subdir.children.first(where: { $0.name == "NESTED.TXT" }))
        let secondReplacement = Data(repeating: 0x59, count: 500)
        let afterSecond = try ISO9660Writer.replacingFile(nestedFile, with: secondReplacement, in: afterFirst)

        XCTAssertGreaterThan(afterSecond.count, afterFirst.count, "the second relocation must append past the true end, never reuse TEST.TXT's own orphaned original slot")

        let finalRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: afterSecond))
        let finalNested = try XCTUnwrap(finalRoot.children.first(where: { $0.name == "SUBDIR" })?.children.first(where: { $0.name == "NESTED.TXT" }))
        XCTAssertNotEqual(finalNested.lba, testFile.lba, "must not have landed at TEST.TXT's own original LBA, that space is never provably safe to reuse")
        XCTAssertEqual(ISO9660Reader.readFile(finalNested, from: PlainISOSource(data: afterSecond)), secondReplacement)

        // Everything else must still read back correctly.
        let finalTestFile = try XCTUnwrap(finalRoot.children.first(where: { $0.name == "TEST.TXT" }))
        XCTAssertEqual(ISO9660Reader.readFile(finalTestFile, from: PlainISOSource(data: afterSecond)), firstReplacement)
    }

    /// "Self-Reclaiming Relocation", the real fix for "every repackage and
    /// boot, the file gets 1-2GB bigger": relocating the *same* file a
    /// *second* time, when its own first relocation left it sitting at the
    /// image's real tail (exactly what happens across repeated "edit, then
    /// repackage and boot" cycles against this app's own giant `.BD`
    /// archive), must reclaim that space instead of appending yet another
    /// full copy on top of it. This is the direct regression test for the
    /// reported bug.
    func testReplaceFileLargerASecondTimeReclaimsItsOwnPriorTailRelocationInsteadOfGrowingAgain() throws {
        let sectors = buildSyntheticISOSectors()
        let originalImage = Data(sectors.flatMap { $0 })
        let root = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: originalImage))
        let testFile = try XCTUnwrap(root.children.first(where: { $0.name == "TEST.TXT" }))

        // First relocation: TEST.TXT (originally 1 sector at LBA 20, with
        // NESTED.TXT's own content immediately after it at LBA 21, *not*
        // the tail) grows past a single sector. Must append past the true
        // end, same as the existing `testReplaceFileLargerAppendsPastEndAndRelocates`.
        let firstReplacement = Data(repeating: 0x58, count: Self.sectorSize + 500) // 2 sectors
        let afterFirst = try ISO9660Writer.replacingFile(testFile, with: firstReplacement, in: originalImage)
        XCTAssertGreaterThan(afterFirst.count, originalImage.count, "sanity: nothing to reclaim yet on the first relocation")
        let afterFirstRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: afterFirst))
        let testFileAfterFirst = try XCTUnwrap(afterFirstRoot.children.first(where: { $0.name == "TEST.TXT" }))
        XCTAssertEqual(Int(testFileAfterFirst.lba) * Self.sectorSize + 2 * Self.sectorSize, afterFirst.count,
                       "sanity: the first relocation's own 2-sector copy must now genuinely be the image's real tail")

        // Second relocation of the *same* file (now sitting at the tail):
        // grows again, by a similar, real-world-sized amount. Must reclaim
        // its own prior copy's space rather than leaving it as a dead,
        // permanently orphaned copy and appending a third location.
        let secondReplacement = Data(repeating: 0x59, count: 2 * Self.sectorSize + 200) // 3 sectors
        let afterSecond = try ISO9660Writer.replacingFile(testFileAfterFirst, with: secondReplacement, in: afterFirst)

        // The image must have grown by roughly the *net* new content
        // (3 sectors - 2 reclaimed sectors = 1 sector), never by the full
        // new copy stacked on top of the still-live old one (which would
        // mean the image grew by the *first* relocation's own 2-sector
        // span too, on top of the second's own 3).
        let netGrowth = afterSecond.count - afterFirst.count
        XCTAssertEqual(netGrowth, Self.sectorSize, "must grow by exactly the net new sector needed (3 new - 2 reclaimed), not by appending a whole new copy on top of the still-orphaned first one")

        let finalRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: afterSecond))
        let finalTestFile = try XCTUnwrap(finalRoot.children.first(where: { $0.name == "TEST.TXT" }))
        XCTAssertEqual(finalTestFile.lba, testFileAfterFirst.lba, "reclaiming its own prior tail slot means the file lands back at (not past) its immediately-prior LBA")
        XCTAssertEqual(ISO9660Reader.readFile(finalTestFile, from: PlainISOSource(data: afterSecond)), secondReplacement)

        // Every other real file must still read back correctly, nothing
        // about reclaiming TEST.TXT's own space should ever touch SUBDIR/NESTED.TXT.
        let subdir = try XCTUnwrap(finalRoot.children.first(where: { $0.name == "SUBDIR" }))
        let nested = try XCTUnwrap(subdir.children.first(where: { $0.name == "NESTED.TXT" }))
        XCTAssertEqual(ISO9660Reader.readFile(nested, from: PlainISOSource(data: afterSecond)).map { String(data: $0, encoding: .utf8) }, "Nested file content.")

        // PVD Volume Space Size must still cover the image's real total size.
        let pvdBase = afterSecond.startIndex + 16 * Self.sectorSize
        let leBytes = Array(afterSecond[(pvdBase + 80)..<(pvdBase + 84)])
        let declaredVolumeSpaceSize = leBytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
        XCTAssertEqual(Int(declaredVolumeSpaceSize), afterSecond.count / Self.sectorSize)
    }

    /// Across *several* repeated relocations of the same file (simulating
    /// several real "edit, then repackage and boot" cycles in a row, each
    /// producing a slightly different-sized replacement, the real,
    /// reported workflow), the image must never grow by more than the
    /// *largest single* replacement ever needed, proving growth is bounded
    /// rather than compounding once the file has settled at the tail.
    func testReplaceFileRepeatedRelocationsNeverCompoundBeyondTheLargestSingleReplacement() throws {
        let sectors = buildSyntheticISOSectors()
        let originalImage = Data(sectors.flatMap { $0 })
        var currentImage = originalImage
        var currentRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: currentImage))
        var currentEntry = try XCTUnwrap(currentRoot.children.first(where: { $0.name == "TEST.TXT" }))

        // Sizes fluctuate the way real repeated level edits do, sometimes
        // bigger, sometimes smaller, never monotonically growing.
        let replacementSizes = [3000, 5000, 2000, 6000, 4000, 7000]
        for size in replacementSizes {
            let replacement = Data(repeating: 0x5A, count: size)
            currentImage = try ISO9660Writer.replacingFile(currentEntry, with: replacement, in: currentImage)
            currentRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: currentImage))
            currentEntry = try XCTUnwrap(currentRoot.children.first(where: { $0.name == "TEST.TXT" }))
            XCTAssertEqual(ISO9660Reader.readFile(currentEntry, from: PlainISOSource(data: currentImage))?.count, size)
        }

        // The image's total growth over the *original* must be bounded by
        // the largest single replacement this loop ever wrote (7000 bytes,
        // 4 sectors) plus a small constant slack for sector alignment/the
        // very first relocation's own one-time cost, never anywhere close
        // to the *sum* of every replacement's own size, which unbounded
        // compounding would produce.
        let totalGrowth = currentImage.count - originalImage.count
        let largestReplacementSectors = 4 // 7000 bytes -> ceil(7000/2048) = 4 sectors
        XCTAssertLessThanOrEqual(totalGrowth, (largestReplacementSectors + 2) * Self.sectorSize,
                                  "repeated relocations of the same file must not compound, growth must stay bounded by roughly the largest single replacement, not the sum of every replacement ever written")
    }

    /// Symmetric to the growth-side fix: shrinking a file that's already
    /// sitting at the image's real tail must physically shrink the image,
    /// not leave the difference behind as permanent zero-padded waste.
    func testReplaceFileShrinkingAtTheTailPhysicallyShrinksTheImage() throws {
        let sectors = buildSyntheticISOSectors()
        let originalImage = Data(sectors.flatMap { $0 })
        let root = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: originalImage))
        let testFile = try XCTUnwrap(root.children.first(where: { $0.name == "TEST.TXT" }))

        // First, relocate TEST.TXT to a real 3-sector reservation at the tail.
        let bigReplacement = Data(repeating: 0x58, count: 2 * Self.sectorSize + 500)
        let afterGrow = try ISO9660Writer.replacingFile(testFile, with: bigReplacement, in: originalImage)
        let rootAfterGrow = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: afterGrow))
        let entryAfterGrow = try XCTUnwrap(rootAfterGrow.children.first(where: { $0.name == "TEST.TXT" }))

        // Now shrink it down to something that fits in 1 sector.
        let smallReplacement = Data("tiny".utf8)
        let afterShrink = try ISO9660Writer.replacingFile(entryAfterGrow, with: smallReplacement, in: afterGrow)

        XCTAssertLessThan(afterShrink.count, afterGrow.count, "shrinking a file sitting at the real tail must physically shrink the image, not just zero-pad the difference")
        XCTAssertEqual(afterShrink.count % Self.sectorSize, 0, "must stay sector-aligned")

        let finalRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: afterShrink))
        let finalEntry = try XCTUnwrap(finalRoot.children.first(where: { $0.name == "TEST.TXT" }))
        XCTAssertEqual(finalEntry.lba, entryAfterGrow.lba, "an in-place shrink never relocates, same LBA as before")
        XCTAssertEqual(ISO9660Reader.readFile(finalEntry, from: PlainISOSource(data: afterShrink)), smallReplacement)

        // PVD must reflect the smaller real size.
        let pvdBase = afterShrink.startIndex + 16 * Self.sectorSize
        let leBytes = Array(afterShrink[(pvdBase + 80)..<(pvdBase + 84)])
        let declaredVolumeSpaceSize = leBytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
        XCTAssertEqual(Int(declaredVolumeSpaceSize), afterShrink.count / Self.sectorSize)
    }

    func testReplaceFileThrowsWhenEntryDoesntFitTheSuppliedImage() {
        let bogusEntry = ISO9660Entry(name: "GHOST.TXT", isDirectory: false, lba: 999, size: 4, directoryRecordAbsoluteOffset: 999_999)
        let tinyImage = Data(repeating: 0, count: Self.sectorSize)
        XCTAssertThrowsError(try ISO9660Writer.replacingFile(bogusEntry, with: Data("x".utf8), in: tinyImage)) { error in
            XCTAssertEqual(error as? ISO9660WriterError, .entryOutOfBounds)
        }
    }
}
