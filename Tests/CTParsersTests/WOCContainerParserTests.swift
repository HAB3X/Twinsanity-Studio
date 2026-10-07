import XCTest
import Foundation
@testable import CTParsers

final class WOCContainerParserTests: XCTestCase {
    private func synthSection(tag: String, payload: [UInt8]) -> [UInt8] {
        var bytes = Array(tag.utf8)
        let length = UInt32(8 + payload.count)
        bytes.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        bytes.append(contentsOf: payload)
        return bytes
    }

    func testParsesSyntheticSectionChain() throws {
        var bytes = Array("NU20".utf8)
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(0xFFFFFFFF).littleEndian) { Array($0) }) // negatedByteCount, unchecked
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(6).littleEndian) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
        bytes.append(contentsOf: synthSection(tag: "AAA0", payload: [1, 2, 3, 4]))
        bytes.append(contentsOf: synthSection(tag: "BBB0", payload: [5, 6]))

        let file = try WOCContainerParser.parse(bytes)
        XCTAssertEqual(file.formatVersion, 6)
        XCTAssertEqual(file.reserved, 0)
        XCTAssertEqual(file.sections.count, 2)
        XCTAssertEqual(file.sections[0].tag, "AAA0")
        XCTAssertEqual([UInt8](file.sections[0].payload), [1, 2, 3, 4])
        XCTAssertEqual(file.sections[1].tag, "BBB0")
        XCTAssertEqual([UInt8](file.sections[1].payload), [5, 6])
    }

    func testStopsChainAtNonTagBytesRatherThanThrowing() throws {
        var bytes = Array("NU20".utf8)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 12))
        bytes.append(contentsOf: synthSection(tag: "AAA0", payload: [1]))
        bytes.append(contentsOf: [0x00, 0x01, 0x02, 0x03, 0x00, 0x00, 0x00, 0x00]) // not a valid 4-char ASCII tag, but a full 8 bytes

        let file = try WOCContainerParser.parse(bytes)
        XCTAssertEqual(file.sections.count, 1)
    }

    func testRejectsBadMagic() {
        let bytes = Array("XXXX".utf8) + [UInt8](repeating: 0, count: 12)
        XCTAssertThrowsError(try WOCContainerParser.parse(bytes)) { error in
            XCTAssertEqual(error as? WOCContainerParser.ParseError, .badMagic)
        }
    }

    func testParsesNameTablePayload() throws {
        let names = "target_red\0target_red_a\0cannon\0".utf8.map { $0 }
        var payload = withUnsafeBytes(of: UInt32(names.count).littleEndian) { Array($0) }
        payload.append(contentsOf: names)
        payload.append(contentsOf: [0xAA, 0xBB, 0xCC]) // unparsed trailer

        let (parsedNames, trailer) = try WOCContainerParser.parseNameTable(Data(payload))
        XCTAssertEqual(parsedNames, ["target_red", "target_red_a", "cannon"])
        XCTAssertEqual([UInt8](trailer), [0xAA, 0xBB, 0xCC])
    }

    // MARK: - Real WoC disc data

    /// Real WoC .GSC files, decompressed via `RNCDecompressor`, walked as a
    /// real-data regression for `WOCContainerParser`: confirms the section
    /// chain accounts for exactly 100% of the decompressed byte count with
    /// no gaps, and that `NTBL`'s declared string-blob length matches its
    /// actual decoded names -- both were verified by hand against a real
    /// disc image before being written as fixed test assertions (see
    /// `WOCContainerParser`'s doc comment for how these were derived).
    private static let discLevelsRoot = "/Volumes/CRASH/LEVELS"

    private func loadAndDecompressRealGSC(_ relativePath: String) throws -> [UInt8] {
        let path = "\(Self.discLevelsRoot)/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted at \(Self.discLevelsRoot) -- mount Games Files/PS2 FILES/Crash Bandicoot - The Wrath of Cortex .../*[ISO9660].iso via `hdiutil attach` to run this test")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try RNCDecompressor.decompress([UInt8](data), verifyCRC: true)
    }

    func testRealAirshipGSCSectionChainCoversWholeFile() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)

        XCTAssertEqual(file.formatVersion, 6)
        XCTAssertEqual(file.reserved, 0)
        XCTAssertEqual(file.negatedByteCount, UInt32((UInt64(0x1_0000_0000) - UInt64(decoded.count)) & 0xFFFF_FFFF))

        let tags = file.sections.map(\.tag)
        XCTAssertEqual(tags, ["NTBL", "TST0", "MS00", "OBJ0", "INST", "SPEC", "SST0"])

        let consumed = 16 + file.sections.reduce(0) { $0 + Int($1.length) }
        XCTAssertEqual(consumed, decoded.count, "section chain should account for every byte of the decompressed file")
    }

    func testRealAirshipGSCNameTable() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let ntbl = try XCTUnwrap(file.sections.first { $0.tag == "NTBL" })
        let (names, _) = try WOCContainerParser.parseNameTable(ntbl.payload)
        XCTAssertEqual(names, ["target_red", "target_red_a", "target_white", "target_white_a", "cannon"])
    }

    func testRealMS00RecordWidthIsConsistentAcrossLevels() throws {
        let samples: [(path: String, expectedCount: Int)] = [
            ("A/AIRSHIP/AIRSHIP.GSC", 57),
            ("A/FARM/FARM.GSC", 69),
            ("A/CASTLE_C/CASTLE_C.GSC", 89),
        ]
        for sample in samples {
            let decoded = try loadAndDecompressRealGSC(sample.path)
            let file = try WOCContainerParser.parse(decoded)
            let ms00 = try XCTUnwrap(file.sections.first { $0.tag == "MS00" }, "no MS00 in \(sample.path)")
            let (records, width) = try WOCContainerParser.parseMaterialSet(ms00.payload)
            XCTAssertEqual(records.count, sample.expectedCount, "record count for \(sample.path)")
            XCTAssertEqual(width, 464, "record width for \(sample.path)")
        }
    }

    /// `MS00`'s one confirmed field: a real texture-ID reference at
    /// relative offset 424, verified against real files with very
    /// different texture counts -- every real record's value is a valid
    /// index into that same file's own real texture list, and the set of
    /// values used isn't constant (a real per-material reference, not a
    /// coincidental always-in-bounds field).
    func testRealMS00TextureIDField() throws {
        let samples = ["A/AIRSHIP/AIRSHIP.GSC", "A/DROID/DROID.GSC", "A/FARM/FARM.GSC", "A/VOLCANO/VOLCANO.GSC"]
        var checked = 0
        for relativePath in samples {
            let decoded = try loadAndDecompressRealGSC(relativePath)
            let file = try WOCContainerParser.parse(decoded)
            guard let ms00 = file.sections.first(where: { $0.tag == "MS00" }),
                  let tst0 = file.sections.first(where: { $0.tag == "TST0" }) else { continue }
            let textureCount = WOCContainerParser.scanTextureEntries(tst0.payload).count
            let (records, _) = try WOCContainerParser.parseMaterialSet(ms00.payload)

            var tids = Set<Int32>()
            for record in records {
                let bytes = [UInt8](record)
                let tid = Int32(bitPattern: UInt32(bytes[424]) | (UInt32(bytes[425]) << 8) | (UInt32(bytes[426]) << 16) | (UInt32(bytes[427]) << 24))
                XCTAssertTrue(tid >= 0 && Int(tid) < textureCount, "\(relativePath): tid \(tid) out of bounds for \(textureCount) real textures")
                tids.insert(tid)
            }
            XCTAssertGreaterThan(tids.count, 1, "\(relativePath): expected real per-material texture references, not a constant value")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "expected at least one real sample file to be checked")
    }

    func testRealINSTInstancesHavePlausibleTransforms() throws {
        let samples: [(path: String, expectedCount: Int)] = [
            ("A/AIRSHIP/AIRSHIP.GSC", 41),
            ("A/FARM/FARM.GSC", 523),
        ]
        for sample in samples {
            let decoded = try loadAndDecompressRealGSC(sample.path)
            let file = try WOCContainerParser.parse(decoded)
            let inst = try XCTUnwrap(file.sections.first { $0.tag == "INST" }, "no INST in \(sample.path)")
            let instances = try WOCContainerParser.parseInstances(inst.payload)
            XCTAssertEqual(instances.count, sample.expectedCount, "instance count for \(sample.path)")
            for (i, instance) in instances.enumerated() {
                XCTAssertEqual(instance.matrix.15, 1.0, "homogeneous w should be 1.0 for instance \(i) in \(sample.path)")
                XCTAssertEqual(instance.unknownTail2, 0, "unknownTail2 for \(sample.path) instance \(i)")
            }
            // unknownTail1 is NOT always zero (verified: don't assert it is) --
            // it's zero for the vast majority of real instances but a real
            // minority carry a nonzero, pointer-shaped value.
        }
    }

    /// The definitive real-data test for `Instance.objectIndex`: a broad
    /// sweep (see `WOCContainerParser`'s doc comment) found that an
    /// earlier, narrower 2-file check had accidentally verified the WRONG
    /// property (that this field equals the instance's own array
    /// position) -- true only because those 2 small files happen to place
    /// every object exactly once. `CASTLE_A.GSC` is a real file with heavy
    /// prop reuse (2111 instances, only 408 distinct objects) where the
    /// old property is false for the overwhelming majority of instances,
    /// but the real property -- every value is a valid `OBJ0` index, and
    /// the set of distinct values is exactly `0..<OBJ0.count` -- still
    /// holds exactly.
    func testRealINSTObjectIndexIsExactlyTheOBJ0IndexRange() throws {
        let samples = ["A/AIRSHIP/AIRSHIP.GSC", "A/FARM/FARM.GSC", "A/CASTLE_A/CASTLE_A.GSC"]
        for path in samples {
            let decoded = try loadAndDecompressRealGSC(path)
            let file = try WOCContainerParser.parse(decoded)
            let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" }, "no OBJ0 in \(path)")
            let obj0Count = try WOCContainerParser.leadingCount(obj0.payload)
            let inst = try XCTUnwrap(file.sections.first { $0.tag == "INST" }, "no INST in \(path)")
            let instances = try WOCContainerParser.parseInstances(inst.payload)

            let distinctIndices = Set(instances.map(\.objectIndex))
            XCTAssertEqual(distinctIndices, Set(0..<UInt32(obj0Count)), "objectIndex values should exactly cover 0..<OBJ0.count for \(path)")
            XCTAssertTrue(instances.allSatisfy { $0.objectIndex < UInt32(obj0Count) }, "no objectIndex should be out of OBJ0's bounds for \(path)")
        }
    }

    /// Golden-value regression for `parseVertexQuadwords`: the first few
    /// quadwords of `OBJ0`'s first entry in the real `AIRSHIP.GSC`,
    /// hand-derived from the raw disc bytes (see `WOCContainerParser`'s
    /// doc comment for how this region was found and visually confirmed
    /// to be a real curved-surface vertex strip, not noise).
    func testRealOBJ0FirstEntryVertexQuadwords() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" })

        // Entry 0 starts right after OBJ0's own count(u32)+pad(u32) header;
        // its vertex-quadword block was found to start at byte 168 within
        // the entry (i.e. byte offset 8 + 168 = 176 into OBJ0's payload).
        let quadwords = try WOCContainerParser.parseVertexQuadwords(obj0.payload, byteOffset: 8 + 168, count: 3)

        XCTAssertEqual(quadwords.count, 3)
        XCTAssertEqual(quadwords[0].position.x, 0.08512221, accuracy: 0.0001)
        XCTAssertEqual(quadwords[0].position.y, -0.09876884, accuracy: 0.0001)
        XCTAssertEqual(quadwords[0].position.z, 0.09516593, accuracy: 0.0001)
        XCTAssertEqual(quadwords[1].position.x, 0.08734421, accuracy: 0.0001)
        XCTAssertEqual(quadwords[1].position.y, -0.09876884, accuracy: 0.0001)
        XCTAssertEqual(quadwords[1].position.z, 0.09080503, accuracy: 0.0001)
        XCTAssertEqual(quadwords[2].position.x, 0.07061075, accuracy: 0.0001)
        XCTAssertEqual(quadwords[2].position.y, -0.09510566, accuracy: 0.0001)
        XCTAssertEqual(quadwords[2].position.z, 0.09045087, accuracy: 0.0001)
    }

    func testRealIABLRecordWidthIsConsistentAcrossLevels() throws {
        let samples: [(path: String, expectedCount: Int)] = [
            ("A/FARM/FARM.GSC", 21),
            ("A/CASTLE_C/CASTLE_C.GSC", 163),
        ]
        for sample in samples {
            let decoded = try loadAndDecompressRealGSC(sample.path)
            let file = try WOCContainerParser.parse(decoded)
            let iabl = try XCTUnwrap(file.sections.first { $0.tag == "IABL" }, "no IABL in \(sample.path)")
            let records = try WOCContainerParser.parseAttributeBlock(iabl.payload)
            XCTAssertEqual(records.count, sample.expectedCount, "record count for \(sample.path)")
            for record in records {
                XCTAssertEqual(record.rawBytes.count, 96, "record width for \(sample.path)")
            }
        }
    }

    /// Independently re-verified (not just trusting the agent report that
    /// found this) on `DROID.GSC`: `ALIB`'s zero-sentinel record and
    /// `IABL`'s alibIndex cross-reference agree exactly -- the one ALIB
    /// index no IABL record ever points at is exactly the one ALIB record
    /// with a zero-offset (empty) sentinel.
    func testRealALIBZeroSentinelMatchesIABLUnreferencedIndex() throws {
        let path = "A/DROID/DROID.GSC"
        let decoded = try loadAndDecompressRealGSC(path)
        let file = try WOCContainerParser.parse(decoded)
        let alib = try XCTUnwrap(file.sections.first { $0.tag == "ALIB" })
        let iabl = try XCTUnwrap(file.sections.first { $0.tag == "IABL" })

        let alibRecords = try WOCContainerParser.parseAttributeLibrary(alib.payload)
        let iablRecords = try WOCContainerParser.parseAttributeBlock(iabl.payload)

        XCTAssertEqual(alibRecords.count, 10)
        let emptyIndices = Set(alibRecords.enumerated().filter { $0.element.isEmpty }.map { $0.offset })
        XCTAssertEqual(emptyIndices, [6])

        for record in iablRecords {
            XCTAssertLessThan(Int(record.alibIndex), alibRecords.count, "IABL alibIndex should be in-bounds")
        }
        let referenced = Set(iablRecords.map { Int($0.alibIndex) })
        let unreferenced = Set(0..<alibRecords.count).subtracting(referenced)
        XCTAssertEqual(unreferenced, emptyIndices, "ALIB's empty-sentinel records should exactly match IABL's unreferenced indices")
    }

    /// Confirmed by an independent spot-check before shipping (this
    /// project's discipline: verify even agent-reported findings): `SPEC`
    /// is a curated, strictly-ascending pointer-list into `INST`, and each
    /// `SPEC` record's transform matrix is byte-for-byte identical to the
    /// `INST` record it references.
    func testRealSPECReferencesINSTWithByteIdenticalMatrices() throws {
        let samples = ["A/AIRSHIP/AIRSHIP.GSC", "A/FARM/FARM.GSC", "A/JUNGLE_A/JUNGLE_A.GSC"]
        for path in samples {
            let decoded = try loadAndDecompressRealGSC(path)
            let file = try WOCContainerParser.parse(decoded)
            let spec = try XCTUnwrap(file.sections.first { $0.tag == "SPEC" }, "no SPEC in \(path)")
            let inst = try XCTUnwrap(file.sections.first { $0.tag == "INST" }, "no INST in \(path)")
            let specRecords = try WOCContainerParser.parseSpecRecords(spec.payload)
            let instances = try WOCContainerParser.parseInstances(inst.payload)
            XCTAssertFalse(specRecords.isEmpty, "expected nonempty SPEC in \(path)")

            var previousIndex: Int64 = -1
            for record in specRecords {
                let refIndex = Int(record.referencedInstanceIndex)
                XCTAssertGreaterThan(Int64(refIndex), previousIndex, "SPEC referencedInstanceIndex should be strictly increasing in \(path)")
                previousIndex = Int64(refIndex)
                XCTAssertLessThan(refIndex, instances.count, "SPEC should reference a valid INST index in \(path)")
                let referenced = instances[refIndex]
                XCTAssertTrue(matricesEqual(record.matrix, referenced.matrix), "SPEC record's matrix should byte-match INST[\(refIndex)] in \(path)")
            }
        }
    }

    private func matricesEqual(
        _ a: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float),
        _ b: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)
    ) -> Bool {
        let epsilon: Float = 1e-5
        return abs(a.0 - b.0) < epsilon &&
               abs(a.1 - b.1) < epsilon &&
               abs(a.2 - b.2) < epsilon &&
               abs(a.3 - b.3) < epsilon &&
               abs(a.4 - b.4) < epsilon &&
               abs(a.5 - b.5) < epsilon &&
               abs(a.6 - b.6) < epsilon &&
               abs(a.7 - b.7) < epsilon &&
               abs(a.8 - b.8) < epsilon &&
               abs(a.9 - b.9) < epsilon &&
               abs(a.10 - b.10) < epsilon &&
               abs(a.11 - b.11) < epsilon &&
               abs(a.12 - b.12) < epsilon &&
               abs(a.13 - b.13) < epsilon &&
               abs(a.14 - b.14) < epsilon &&
               abs(a.15 - b.15) < epsilon
    }

    /// `TST0` turned out to be a completely different kind of structure
    /// from every other section: a serialized PS2 Graphics Synthesizer
    /// texture-upload command stream, not a record table. This pins the
    /// first real texture entry found in `AIRSHIP.GSC` by the scan.
    func testRealTST0FirstTextureEntry() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let tst0 = try XCTUnwrap(file.sections.first { $0.tag == "TST0" })
        let entries = WOCContainerParser.scanTextureEntries(tst0.payload)

        // The scan is a heuristic (documented as such), not guaranteed to
        // find every texture the section's leading count field declares --
        // but every entry it DOES find must be internally consistent.
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            XCTAssertGreaterThan(entry.width, 0)
            XCTAssertGreaterThan(entry.height, 0)
            XCTAssertEqual(entry.texelDataRange.count, entry.width * entry.height * entry.bytesPerPixel)
        }

        let first = entries[0]
        XCTAssertEqual(first.width, 128)
        XCTAssertEqual(first.height, 64)
        XCTAssertEqual(first.bytesPerPixel, 4)
        XCTAssertEqual(first.texelDataRange.count, 32768)
    }

    /// `SST0` is always the last section (a footer). Confirmed here: its
    /// outer blob-length field correctly splits the payload, and in
    /// files that have the 12-byte trailer variant, the trailer's last
    /// field echoes this section's own outer container length back.
    func testRealSST0FooterEchoesOwnSectionLength() throws {
        let decoded = try loadAndDecompressRealGSC("A/FARM/FARM.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let sst0 = try XCTUnwrap(file.sections.first { $0.tag == "SST0" })
        let (_, _, trailer) = try WOCContainerParser.parseFooterHeader(sst0.payload)
        XCTAssertEqual(trailer.count, 12)
        let echoedLength = trailer.suffix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(echoedLength, sst0.length, "SST0 trailer should echo its own section length")
    }

    /// Real-data regression for `obj0ChunkLength`: walking AIRSHIP.GSC's
    /// entire OBJ0 payload with the confirmed `chunkLength == lengthField
    /// + 128` formula, locating each chunk by scanning forward for the
    /// recurring `0x6C010056` marker, consumes the payload EXACTLY --
    /// 222 chunks, zero drift. (This exact naive-scan walk is known NOT
    /// to be safe on other files -- see `obj0ChunkLength`'s doc comment --
    /// so this test intentionally only covers the one file where it's
    /// confirmed clean, rather than a broader sweep that would fail.)
    /// The validated `walkOBJ0Chunks` covers AIRSHIP.GSC exactly and gets
    /// very close (>99.9%) on other real files of similar (homogeneous
    /// chunk-header) shape -- unlike the naive marker scan this replaced,
    /// which diverged catastrophically on files with heterogeneous chunk
    /// headers (see `walkOBJ0Chunks`'s doc comment for that story).
    /// `CASTLE_C.GSC`/`HUB.GSC` are exactly that heterogeneous case and
    /// are deliberately NOT included here -- see
    /// `WOCOBJ0GroupingTests.testHeterogeneousFilesReturnPartialButRealGrouping`
    /// for their honest (low, partial) coverage instead.
    func testRealOBJ0ChunkWalkCoversMultipleFilesNearlyExactly() throws {
        let samples: [(path: String, expectedChunks: Int, minCoverageFraction: Double)] = [
            ("A/AIRSHIP/AIRSHIP.GSC", 222, 1.0),
            ("A/FARM/FARM.GSC", 745, 0.999),
        ]
        for sample in samples {
            let decoded = try loadAndDecompressRealGSC(sample.path)
            let file = try WOCContainerParser.parse(decoded)
            let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" })
            let chunks = WOCContainerParser.walkOBJ0Chunks(obj0.payload)
            XCTAssertEqual(chunks.count, sample.expectedChunks, "chunk count for \(sample.path)")
            let covered = chunks.reduce(0) { $0 + $1.length }
            let fraction = Double(8 + covered) / Double(obj0.payload.count)
            XCTAssertGreaterThanOrEqual(fraction, sample.minCoverageFraction, "coverage fraction for \(sample.path)")
        }
    }

    func testRealCastleCGSCSectionChainCoversWholeFile() throws {
        let decoded = try loadAndDecompressRealGSC("A/CASTLE_C/CASTLE_C.GSC")
        let file = try WOCContainerParser.parse(decoded)

        // CASTLE_C additionally has TAS0 and IABL/ALIB, absent from AIRSHIP --
        // confirming the section set genuinely varies per level rather than
        // AIRSHIP's chain being the universal one.
        let tags = file.sections.map(\.tag)
        XCTAssertEqual(tags, ["NTBL", "TST0", "MS00", "TAS0", "OBJ0", "INST", "IABL", "ALIB", "SPEC", "SST0"])

        let consumed = 16 + file.sections.reduce(0) { $0 + Int($1.length) }
        XCTAssertEqual(consumed, decoded.count)
    }

    /// End-to-end regression: decompress a real WoC level and decode every
    /// section this module currently understands, checking that they
    /// agree with each other exactly where they're supposed to (NTBL
    /// names, MS00/IABL/INST/SPEC record counts, the INST<->OBJ0 index
    /// relationship, SPEC<->INST matrix identity, and a real texture).
    /// This is the safety net for the whole pipeline: if any single piece
    /// regresses, this test is the one most likely to catch it, since it
    /// exercises them all together against one real file rather than in
    /// isolation.
    func testRealAirshipGSCFullPipelineIsInternallyConsistent() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)
        XCTAssertEqual(file.sections.map(\.tag), ["NTBL", "TST0", "MS00", "OBJ0", "INST", "SPEC", "SST0"])

        let ntbl = try XCTUnwrap(file.sections.first { $0.tag == "NTBL" })
        let (names, _) = try WOCContainerParser.parseNameTable(ntbl.payload)
        XCTAssertEqual(names, ["target_red", "target_red_a", "target_white", "target_white_a", "cannon"])

        let ms00 = try XCTUnwrap(file.sections.first { $0.tag == "MS00" })
        let (ms00Records, ms00Width) = try WOCContainerParser.parseMaterialSet(ms00.payload)
        XCTAssertEqual(ms00Records.count, 57)
        XCTAssertEqual(ms00Width, 464)

        let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" })
        let obj0Count = try WOCContainerParser.leadingCount(obj0.payload)
        XCTAssertEqual(obj0Count, 41)

        let inst = try XCTUnwrap(file.sections.first { $0.tag == "INST" })
        let instances = try WOCContainerParser.parseInstances(inst.payload)
        XCTAssertEqual(instances.count, 41)
        XCTAssertEqual(Set(instances.map(\.objectIndex)), Set(0..<UInt32(obj0Count)))

        let spec = try XCTUnwrap(file.sections.first { $0.tag == "SPEC" })
        let specRecords = try WOCContainerParser.parseSpecRecords(spec.payload)
        XCTAssertEqual(specRecords.count, 5)
        for record in specRecords {
            let referenced = instances[Int(record.referencedInstanceIndex)]
            XCTAssertTrue(matricesEqual(record.matrix, referenced.matrix))
        }

        let tst0 = try XCTUnwrap(file.sections.first { $0.tag == "TST0" })
        let textures = WOCContainerParser.scanTextureEntries(tst0.payload)
        XCTAssertFalse(textures.isEmpty)
        XCTAssertEqual(textures[0].width, 128)
        XCTAssertEqual(textures[0].height, 64)
    }

    /// Analyzes SPEC unknown tails across multiple files to determine their purpose.
    func testAnalyzeSpecUnknownTails() throws {
        let testFiles = [
            ("A/AIRSHIP/AIRSHIP.GSC", "Airship"),
            ("A/FARM/FARM.GSC", "Farm"),
            ("A/CASTLE_C/CASTLE_C.GSC", "Castle_C"),
            ("A/JUNGLE_A/JUNGLE_A.GSC", "Jungle_A"),
            ("A/DROID/DROID.GSC", "Droid")
        ]

        print("\n=== SPEC Unknown Fields Analysis ===\n")

        for (filePath, displayName) in testFiles {
            do {
                print("Processing \(displayName): \(filePath)")

                let decoded = try loadAndDecompressRealGSC(filePath)
                let file = try WOCContainerParser.parse(decoded)

                guard let specSection = file.sections.first(where: { $0.tag == "SPEC" }) else {
                    print("  No SPEC section found\n")
                    continue
                }

                let specRecords = try WOCContainerParser.parseSpecRecords(specSection.payload)
                print("  Found \(specRecords.count) SPEC records")

                if specRecords.isEmpty {
                    print()
                    continue
                }

                // Analyze unknownTail3 and unknownTail4
                var tail3Values: [UInt32] = []
                var tail4Values: [UInt32] = []

                for record in specRecords {
                    tail3Values.append(record.unknownTail3)
                    tail4Values.append(record.unknownTail4)
                }

                // Statistics for unknownTail3
                let tail3Min = tail3Values.min() ?? 0
                let tail3Max = tail3Values.max() ?? 0
                let tail3Range = tail3Max - tail3Min

                // Statistics for unknownTail4
                let tail4Min = tail4Values.min() ?? 0
                let tail4Max = tail4Values.max() ?? 0
                let tail4Range = tail4Max - tail4Min

                print("  unknownTail3:")
                print("    Min: 0x\(String(format: "%08x", tail3Min)) (\(tail3Min))")
                print("    Max: 0x\(String(format: "%08x", tail3Max)) (\(tail3Max))")
                print("    Range: 0x\(String(format: "%08x", tail3Range)) (\(tail3Range))")

                // Check if values are in the suspected heap pointer range
                let heapRangeStart: UInt32 = 0x32900000  // ~329M
                let heapRangeEnd: UInt32 = 0x33040000    // ~330.4M
                let tail3InHeap = tail3Values.filter { $0 >= heapRangeStart && $0 <= heapRangeEnd }.count
                let tail4InHeap = tail4Values.filter { $0 >= heapRangeStart && $0 <= heapRangeEnd }.count

                print("    Values in heap range (0x32900000-0x33040000): \(tail3InHeap)/\(specRecords.count)")
                print("    Percentage: \(String(format: "%.1f%%", Double(tail3InHeap) / Double(specRecords.count) * 100))")

                print("  unknownTail4:")
                print("    Min: 0x\(String(format: "%08x", tail4Min)) (\(tail4Min))")
                print("    Max: 0x\(String(format: "%08x", tail4Max)) (\(tail4Max))")
                print("    Range: 0x\(String(format: "%08x", tail4Range)) (\(tail4Range))")
                print("    Values in heap range: \(tail4InHeap)/\(specRecords.count)")
                print("    Percentage: \(String(format: "%.1f%%", Double(tail4InHeap) / Double(specRecords.count) * 100))")

                // Check for patterns or sequences
                print("  unknownTail3 sequence analysis:")
                if specRecords.count > 1 {
                    var tail3Diffs: [Int32] = []
                    for i in 1..<specRecords.count {
                        let diff = Int32(bitPattern: specRecords[i].unknownTail3 &- specRecords[i-1].unknownTail3)
                        tail3Diffs.append(diff)
                    }
                    if let minDiff = tail3Diffs.min(), let maxDiff = tail3Diffs.max() {
                        print("    Differences between consecutive values: min=\(minDiff), max=\(maxDiff)")
                    }
                }

                print()
            } catch {
                print("  Error processing \(filePath): \(error)\n")
            }
        }

        print("=== Analysis Complete ===\n")
    }
    
    /// Also analyze what the values might represent if not heap pointers
    func testAnalyzeSpecAlternativeInterpretations() throws {
        print("\n=== Alternative Interpretations ===\n")

        // Let's look at a specific file in detail
        do {
            let decoded = try loadAndDecompressRealGSC("A/FARM/FARM.GSC")
            let file = try WOCContainerParser.parse(decoded)

            guard let specSection = file.sections.first(where: { $0.tag == "SPEC" }) else {
                print("No SPEC section in FARM.GSC")
                return
            }

            let specRecords = try WOCContainerParser.parseSpecRecords(specSection.payload)
            let instSection = try XCTUnwrap(file.sections.first { $0.tag == "INST" }, "no INST")
            let instances = try WOCContainerParser.parseInstances(instSection.payload)

            print("FARM.GSC SPEC Records Detailed Analysis:")
            print("Record  Index  RefID  Matrix[12-14] (translation)  unknownTail3     unknownTail4")
            print("--------------------------------------------------------------------------------")

            for (i, record) in specRecords.enumerated().prefix(10) {
                let translation = record.translation
                let refIndex = Int(record.referencedInstanceIndex)
                let refInstance = instances[refIndex]

                print(String(format: "%4d    %4d    %4d    [%6.2f,%6.2f,%6.2f]    0x%08x (%10d)  0x%08x (%10d)",
                           i, refIndex,
                           translation.x, translation.y, translation.z,
                           record.unknownTail3, Int32(bitPattern: record.unknownTail3),
                           record.unknownTail4, Int32(bitPattern: record.unknownTail4)))
            }

            if specRecords.count > 10 {
                print("... and \(specRecords.count - 10) more records")
            }

        } catch {
            print("Error in detailed analysis: \(error)")
        }
    }
}
