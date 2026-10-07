import XCTest
@testable import CTParsers

/// `WOCCutsceneParser` -- decodes WoC `.CUT` files. See `CUT_Spec.md` for
/// the full investigation history and this decoder's design rationale
/// (a validated sequential shape-scanner, not a pointer-graph walker --
/// the spec's own byte tables for all 3 mapped files are strictly
/// sequential/gap-free, so that's what this decoder exploits).
final class WOCCutsceneParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Verifies the decoder's regions are contiguous, non-overlapping, and
    /// sum to exactly the file's byte count -- the same bar `CUT_Spec.md`
    /// itself uses ("verified programmatically to sum to exactly N bytes
    /// with zero gaps and zero overlaps").
    private func assertGapFreeCoverage(_ file: WOCCutsceneParser.File, line: UInt = #line) {
        var expected = 0
        for region in file.regions {
            XCTAssertEqual(region.offset, expected, "gap or overlap before offset \(region.offset)", line: line)
            expected = region.offset + region.length
        }
        XCTAssertEqual(expected, file.byteCount, "regions do not cover the whole file", line: line)
    }

    private func node(_ file: WOCCutsceneParser.File, at offset: Int) -> WOCCutsceneParser.Node? {
        file.regions.first(where: { $0.offset == offset })?.node
    }

    // MARK: BLACK.CUT -- byte-exact against CUT_Spec.md's own table

    func testBlackCutGapFreeCoverage() throws {
        let data = try loadReal("B/INTRO2/BLACK.CUT")
        let file = try WOCCutsceneParser.parse(data)
        XCTAssertEqual(file.byteCount, 695)
        XCTAssertEqual(file.pointerConstant, 0x5302)
        assertGapFreeCoverage(file)
    }

    func testBlackCutRootRecordAndPrologue() throws {
        let data = try loadReal("B/INTRO2/BLACK.CUT")
        let file = try WOCCutsceneParser.parse(data)

        guard case let .rootRecord(kind, ptr0, duration, _, rootTransformPtr, slot5, slot6, _)? = node(file, at: 0) else {
            return XCTFail("expected rootRecord at offset 0")
        }
        XCTAssertEqual(kind, 1)
        XCTAssertEqual(ptr0, 0x20)
        XCTAssertEqual(duration, 58.0)
        XCTAssertEqual(rootTransformPtr, 0x50)
        XCTAssertEqual(slot5, 0)
        XCTAssertEqual(slot6, 0)

        guard case .zeroPadding? = node(file, at: 0x20) else { return XCTFail("expected zeroPadding at 0x20") }

        guard case let .nodeBHeader(kind, ptrA, ptrB, _)? = node(file, at: 0x30) else {
            return XCTFail("expected nodeBHeader at 0x30")
        }
        XCTAssertEqual(kind, 1)
        XCTAssertEqual(ptrA, 0x70)
        XCTAssertEqual(ptrB, 0xC0)

        guard case .reservedBlob? = node(file, at: 0x40) else { return XCTFail("expected reservedBlob at 0x40") }
        // Confirmed cross-file constant: 00 00 FF*9 00*5.
        XCTAssertEqual(data[0x40], 0x00)
        XCTAssertEqual(data[0x41], 0x00)
        for i in 0x42...0x4A { XCTAssertEqual(data[i], 0xFF, "byte \(i)") }
        for i in 0x4B...0x4F { XCTAssertEqual(data[i], 0x00, "byte \(i)") }
    }

    func testBlackCutRootTransform() throws {
        let data = try loadReal("B/INTRO2/BLACK.CUT")
        let file = try WOCCutsceneParser.parse(data)
        guard case let .transform(t)? = node(file, at: 0x50) else { return XCTFail("expected transform at 0x50") }
        let tr = t.translation
        XCTAssertEqual(tr.0, 0, accuracy: 0.0001)
        XCTAssertEqual(tr.1, 0, accuracy: 0.0001)
        XCTAssertEqual(tr.2, -0.843991, accuracy: 0.0001)
        // Identity rotation per CUT_Spec.md.
        XCTAssertEqual(t.matrix.0, 1, accuracy: 0.0001)
        XCTAssertEqual(t.matrix.5, 1, accuracy: 0.0001)
        XCTAssertEqual(t.matrix.10, 1, accuracy: 0.0001)
    }

    func testBlackCutTrackHeaders() throws {
        let data = try loadReal("B/INTRO2/BLACK.CUT")
        let file = try WOCCutsceneParser.parse(data)

        guard case let .trackHeader(h1)? = node(file, at: 0xA0) else { return XCTFail("expected trackHeader at 0xA0") }
        XCTAssertEqual(h1.duration, 58.0)
        XCTAssertEqual(h1.u16A, 1)
        XCTAssertEqual(h1.u16B, 9)
        XCTAssertEqual(h1.count, 2)
        // count+1 = 3 pointers, per CUT_Spec.md's confirmed table.
        XCTAssertEqual(h1.pointers.count, 3)
        XCTAssertEqual(h1.pointers[0], 0xE0)
        XCTAssertEqual(h1.pointers[1], 0x110)
        XCTAssertEqual(h1.pointers[2], 0x120)

        guard case let .trackHeader(h2)? = node(file, at: 0x1C0) else { return XCTFail("expected trackHeader at 0x1C0") }
        XCTAssertEqual(h2.duration, 59.0)
        XCTAssertEqual(h2.u16A, 1)
        XCTAssertEqual(h2.u16B, 8)
        XCTAssertEqual(h2.count, 2)
        XCTAssertEqual(h2.pointers.count, 3)
        XCTAssertEqual(h2.pointers[0], 0x200)
        XCTAssertEqual(h2.pointers[1], 0x220)
        XCTAssertEqual(h2.pointers[2], 0x230)
    }

    func testBlackCutRecordCAndD() throws {
        let data = try loadReal("B/INTRO2/BLACK.CUT")
        let file = try WOCCutsceneParser.parse(data)

        guard case let .recordC(rc)? = node(file, at: 0xE0) else { return XCTFail("expected recordC at 0xE0") }
        XCTAssertEqual(rc.leadingFloat, 1.0)
        XCTAssertEqual(rc.raw.count, 48)

        guard case let .recordD(rd)? = node(file, at: 0x110) else { return XCTFail("expected recordD at 0x110") }
        guard case let .twoPointer(u32, ptrA, ptrB, trailingFloat) = rd else {
            return XCTFail("expected twoPointer RecordD variant in BLACK.CUT")
        }
        XCTAssertEqual(u32, 1)
        XCTAssertEqual(ptrA, 0x140)
        XCTAssertEqual(ptrB, 0x150)
        XCTAssertEqual(trailingFloat, 0)
    }

    func testBlackCutStarsNamedAssetReferenceAndName() throws {
        let data = try loadReal("B/INTRO2/BLACK.CUT")
        let file = try WOCCutsceneParser.parse(data)

        guard case let .namedAssetReference(ref)? = node(file, at: 0x220) else {
            return XCTFail("expected namedAssetReference at 0x220")
        }
        XCTAssertEqual(ref.headerPtrA, 0x2B0)
        XCTAssertEqual(ref.headerPtrB, 0x2A0)
        XCTAssertEqual(ref.parameters.count, 28)
        // Known real params per CUT_Spec.md: 0.2, 3.0, 5.0, 0.05, 3.0, -0.15, 25.0 recur in the blob.
        XCTAssertTrue(ref.parameters.contains(where: { abs($0 - 0.2) < 0.0001 }))
        XCTAssertTrue(ref.parameters.contains(where: { abs($0 - 25.0) < 0.0001 }))

        guard case let .name(str)? = node(file, at: 0x2B0) else { return XCTFail("expected name at 0x2B0") }
        XCTAssertEqual(str, "STARS2")
    }

    // MARK: CORRIDOR.CUT -- byte-exact against CUT_Spec.md's own table

    func testCorridorCutGapFreeCoverage() throws {
        let data = try loadReal("B/INTRO2/CORRIDOR.CUT")
        let file = try WOCCutsceneParser.parse(data)
        XCTAssertEqual(file.byteCount, 976)
        XCTAssertEqual(file.pointerConstant, 0x29D6)
        assertGapFreeCoverage(file)
    }

    func testCorridorCutRootTransformIsNonIdentity() throws {
        let data = try loadReal("B/INTRO2/CORRIDOR.CUT")
        let file = try WOCCutsceneParser.parse(data)
        guard case let .transform(t)? = node(file, at: 0x50) else { return XCTFail("expected transform at 0x50") }
        let tr = t.translation
        XCTAssertEqual(tr.0, -10.105168, accuracy: 0.001)
        XCTAssertEqual(tr.1, 0.027334, accuracy: 0.001)
        XCTAssertEqual(tr.2, -0.719901, accuracy: 0.001)
    }

    func testCorridorCutRootFanOutTrackHeader() throws {
        let data = try loadReal("B/INTRO2/CORRIDOR.CUT")
        let file = try WOCCutsceneParser.parse(data)
        guard case let .trackHeader(h)? = node(file, at: 0xA0) else { return XCTFail("expected trackHeader at 0xA0") }
        XCTAssertEqual(h.duration, 200.0)
        XCTAssertEqual(h.u16A, 1)
        XCTAssertEqual(h.u16B, 9)
        XCTAssertEqual(h.count, 7)
        // count+4 = 11 pointers, per CUT_Spec.md's confirmed "root/fan-out" formula.
        XCTAssertEqual(h.pointers.count, 11)
        XCTAssertEqual(h.pointers[0], 0xE0)
        XCTAssertEqual(h.pointers[1], 0x110)
    }

    func testCorridorCutRecordDIsFourPointerVariant() throws {
        let data = try loadReal("B/INTRO2/CORRIDOR.CUT")
        let file = try WOCCutsceneParser.parse(data)
        guard case let .recordD(rd)? = node(file, at: 0x110) else { return XCTFail("expected recordD at 0x110") }
        guard case let .fourPointer(ptrs) = rd else {
            return XCTFail("expected fourPointer RecordD variant in CORRIDOR.CUT")
        }
        XCTAssertEqual(ptrs.count, 4)
        XCTAssertEqual(ptrs[0], 0x180)
        XCTAssertEqual(ptrs[1], 0x170)
        XCTAssertEqual(ptrs[2], 0x140)
        XCTAssertEqual(ptrs[3], 0x148)
    }

    func testCorridorCutPeriodicTrackNodeUnits() throws {
        let data = try loadReal("B/INTRO2/CORRIDOR.CUT")
        let file = try WOCCutsceneParser.parse(data)
        // 5 full 112-byte units at 0x160, 0x1D0, 0x240, 0x2B0, 0x320, per CUT_Spec.md.
        for offset in [0x160, 0x1D0, 0x240, 0x2B0, 0x320] {
            guard case let .trackNodeUnit112(unit)? = node(file, at: offset) else {
                return XCTFail("expected trackNodeUnit112 at \(String(offset, radix: 16))")
            }
            XCTAssertEqual(unit.raw.count, 112)
        }
        // 6th (truncated by EOF) instance at 0x390 -- 64 bytes only.
        guard case let .trackNodeUnit112(finalUnit)? = node(file, at: 0x390) else {
            return XCTFail("expected truncated trackNodeUnit112 at 0x390")
        }
        XCTAssertEqual(finalUnit.raw.count, 64)
    }

    // MARK: STATION.CUT -- region-level coverage + spot-check strong shapes

    func testStationCutGapFreeCoverage() throws {
        let data = try loadReal("B/INTRO2/STATION.CUT")
        let file = try WOCCutsceneParser.parse(data)
        XCTAssertEqual(file.byteCount, 12125)
        XCTAssertEqual(file.pointerConstant, 0x297A)
        assertGapFreeCoverage(file)
    }

    func testStationCutRootFanOutTrackHeaderFeedsFourZones() throws {
        let data = try loadReal("B/INTRO2/STATION.CUT")
        let file = try WOCCutsceneParser.parse(data)
        guard case let .trackHeader(h)? = node(file, at: 0xA0) else { return XCTFail("expected trackHeader at 0xA0") }
        XCTAssertEqual(h.duration, 110.0)
        XCTAssertEqual(h.count, 4)
        // count+4 = 8 pointers, per CUT_Spec.md.
        XCTAssertEqual(h.pointers.count, 8)
    }

    func testStationCutSixSentinelsFound() throws {
        let data = try loadReal("B/INTRO2/STATION.CUT")
        let file = try WOCCutsceneParser.parse(data)
        // The sentinel isn't its own region -- `tryDenseFrameChannelArray`
        // consumes it as the last 16 bytes of the array's own match (same
        // treatment as the closer/tail), so each array's own end offset
        // should land exactly on a known zone-boundary sentinel.
        let arrayEndOffsets = file.regions.compactMap { region -> Int? in
            if case .denseFrameChannelArray = region.node { return region.offset + region.length }
            return nil
        }
        // Zone boundaries per CUT_Spec.md: 0xB20, 0x1240, 0x1960, 0x20F0, 0x2810, 0x2F30 (sentinel start) + 16 (sentinel length).
        let expectedEnds = [0xB20, 0x1240, 0x1960, 0x20F0, 0x2810, 0x2F30].map { $0 + 16 }
        XCTAssertEqual(Set(arrayEndOffsets), Set(expectedEnds))
    }

    func testStationCutDenseFrameChannelArraysInAllSixZones() throws {
        let data = try loadReal("B/INTRO2/STATION.CUT")
        let file = try WOCCutsceneParser.parse(data)
        let arrays = file.regions.compactMap { region -> WOCCutsceneParser.DenseFrameChannelArray? in
            if case let .denseFrameChannelArray(a) = region.node { return a }
            return nil
        }
        XCTAssertEqual(arrays.count, 6, "expected exactly 6 dense frame-channel arrays, one per zone")
        for array in arrays {
            XCTAssertEqual(array.entries.count, 110)
            XCTAssertEqual(array.entries.first?.frameIndex, 1)
            XCTAssertEqual(array.entries.last?.frameIndex, 110)
        }
        // Known-real closer valueX per zone from CUT_Spec.md's own table.
        let closerValues = arrays.map { $0.closerValueX }.sorted()
        let expected: [Float] = [-2.842437, -0.487262, 0.236568, 0.389997, 0.829059, 2.961434].sorted()
        for (a, b) in zip(closerValues, expected) {
            XCTAssertEqual(a, b, accuracy: 0.0001)
        }
    }

    /// `CUT_Spec.md` originally documented `0x120`/`0x130` as two
    /// standalone "channel-quads" and a separate 3-entry "sparse
    /// milestone table A" starting at `0x140` -- and explicitly flagged
    /// this boundary as an open question in its own "Suggested next
    /// steps" ("worth specifically re-checking whether ... the same ...
    /// primitive"). Direct byte inspection (`xxd`) confirms they're not
    /// separate: `0x120`-`0x16F` is one continuous 5-entry sparse
    /// milestone table -- frames `0.0, 89.0, 90.0, 97.0, 110.0`, weights
    /// `1/89, 1/1, 1/7, 1/13, 0` (terminal), matching the reciprocal-delta
    /// formula with zero exceptions across all 4 non-terminal transitions.
    /// The former "channel-quad #1/#2" values are just this table's first
    /// two entries. This resolves the doc's own open question.
    func testStationCutSparseMilestoneTablesInZoneOne() throws {
        let data = try loadReal("B/INTRO2/STATION.CUT")
        let file = try WOCCutsceneParser.parse(data)
        guard case let .sparseMilestoneTable(a)? = node(file, at: 0x120) else {
            return XCTFail("expected sparseMilestoneTable at 0x120 (extended table absorbing the former 'channel-quad #1/#2')")
        }
        XCTAssertEqual(a.count, 5)
        let expectedFrames: [Float] = [0.0, 89.0, 90.0, 97.0, 110.0]
        for (entry, expectedFrame) in zip(a, expectedFrames) {
            XCTAssertEqual(entry.milestoneFrame, expectedFrame, accuracy: 0.001)
        }
        XCTAssertEqual(a[0].weight, 1.0 / 89.0, accuracy: 0.0001)
        XCTAssertEqual(a[1].weight, 1.0, accuracy: 0.0001)
        XCTAssertEqual(a[2].weight, 1.0 / 7.0, accuracy: 0.0001)
        XCTAssertEqual(a[3].weight, 1.0 / 13.0, accuracy: 0.0001)
        XCTAssertEqual(a[4].weight, 0)

        guard case let .sparseMilestoneTable(b)? = node(file, at: 0x1A0) else {
            return XCTFail("expected sparseMilestoneTable at 0x1A0")
        }
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(b[0].milestoneFrame, 1.0)
        XCTAssertEqual(b[0].weight, 1.0 / 109.0, accuracy: 0.0001)

        guard case let .sparseMilestoneTable(c)? = node(file, at: 0x1F0) else {
            return XCTFail("expected sparseMilestoneTable at 0x1F0")
        }
        XCTAssertEqual(c.count, 5)
        XCTAssertEqual(c[0].milestoneFrame, 0.0)
        XCTAssertEqual(c[0].weight, 1.0 / 89.0, accuracy: 0.0001)
        XCTAssertEqual(c[4].weight, 0)
    }

    func testStationCutStringPoolAtEOF() throws {
        let data = try loadReal("B/INTRO2/STATION.CUT")
        let file = try WOCCutsceneParser.parse(data)
        let names = file.regions.compactMap { region -> String? in
            if case let .name(s) = region.node { return s }
            return nil
        }
        XCTAssertEqual(names, ["lower_ring", "top_ring", "station1"])
    }

    // MARK: Full-corpus smoke test

    func testEveryRealCUTFileParsesWithoutThrowingAndCoversAllBytes() throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: "/Volumes/CRASH/LEVELS") else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        var allCUT: [String] = []
        for case let p as String in enumerator where p.uppercased().hasSuffix(".CUT") {
            allCUT.append(p)
        }
        guard !allCUT.isEmpty else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }

        var checked = 0
        var totalBytes = 0
        var unrecognizedBytes = 0
        for relativePath in allCUT.sorted() {
            let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let file = try WOCCutsceneParser.parse(data)
            assertGapFreeCoverage(file)
            totalBytes += file.byteCount
            for region in file.regions {
                if case .unrecognized = region.node { unrecognizedBytes += region.length }
            }
            checked += 1
        }
        XCTAssertEqual(checked, allCUT.count)
        XCTAssertGreaterThan(checked, 10, "expected close to the full real 18-file corpus")
        // Not a correctness assertion -- just surfaces real coverage for visibility.
        print("WOCCutsceneParser: \(checked) files, \(totalBytes) total bytes, \(unrecognizedBytes) unrecognized (\(String(format: "%.1f", Double(unrecognizedBytes) / Double(totalBytes) * 100))%)")
    }
}
