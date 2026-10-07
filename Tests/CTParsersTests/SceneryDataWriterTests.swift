import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers

/// "Scenery Placement" (editing an *existing* placement, not creating a
/// new one -- see `SceneryModelPlacement.matrixFileOffset`'s doc comment
/// for the scope this stops at). Real round-trip test against a real
/// disc file, matching this codebase's established writer discipline:
/// `parse(write(parse(x))) == parse(x)`.
final class SceneryDataWriterTests: XCTestCase {
    private static let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")

    func testWriteModelMatrixRoundTripsThroughParserOnRealFile() throws {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Real disc image not present")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)
        guard let entry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/hubb.sm2" }) else {
            throw XCTSkip("hubb.sm2 not found in this archive")
        }
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .sm2, fileName: entry.name)

        var sceneryNode: ChunkNode?
        var found: SceneryAsset?
        func walk(_ node: ChunkNode) {
            if found == nil, case .scenery(let scenery) = node.payload, !scenery.placements.isEmpty {
                found = scenery
                sceneryNode = node
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        let scenery = try XCTUnwrap(found, "expected a real SceneryData with placements in hubb.sm2")
        let node = try XCTUnwrap(sceneryNode)
        let placement = try XCTUnwrap(scenery.placements.first { $0.matrixFileOffset != nil })
        let matrixOffset = try XCTUnwrap(placement.matrixFileOffset)

        // A deliberately different, real, hand-chosen matrix -- not just
        // re-writing the same bytes back (which would trivially "round
        // trip" even with a byte-order bug).
        let editedMatrix: [SIMD4<Float>] = [
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(42.5, -17.25, 8.0, 1),
        ]
        let encoded = SceneryDataWriter.writeModelMatrix(editedMatrix)
        XCTAssertEqual(encoded.count, 64, "4 rows * 4 floats * 4 bytes")

        // Patch just those 64 bytes into a full copy of the record's own
        // bytes, at the record-relative offset the parser captured, then
        // re-parse the WHOLE record through the real parser -- proving
        // the offset is correct, not just that encode/decode round-trip
        // in isolation.
        var recordBytes = data.subdata(in: (data.startIndex + node.fileOffset)..<(data.startIndex + node.fileOffset + node.byteSize))
        recordBytes.replaceSubrange(matrixOffset..<(matrixOffset + 64), with: encoded)

        var cursor = BinaryCursor(data: recordBytes)
        let reparsed = try SceneryDataParser.parse(&cursor, recordID: node.recordID)
        let reparsedPlacement = try XCTUnwrap(reparsed.placements.first { $0.matrixFileOffset == matrixOffset })

        for i in 0..<4 {
            XCTAssertEqual(reparsedPlacement.modelMatrix[i].x, editedMatrix[i].x, accuracy: 0.0001)
            XCTAssertEqual(reparsedPlacement.modelMatrix[i].y, editedMatrix[i].y, accuracy: 0.0001)
            XCTAssertEqual(reparsedPlacement.modelMatrix[i].z, editedMatrix[i].z, accuracy: 0.0001)
            XCTAssertEqual(reparsedPlacement.modelMatrix[i].w, editedMatrix[i].w, accuracy: 0.0001)
        }

        // Every *other* placement's matrix must be untouched -- proves
        // the patch didn't shift or corrupt anything else in the record.
        for original in scenery.placements where original.matrixFileOffset != matrixOffset {
            guard let otherOffset = original.matrixFileOffset,
                  let reparsedOther = reparsed.placements.first(where: { $0.matrixFileOffset == otherOffset })
            else { continue }
            XCTAssertEqual(reparsedOther.modelMatrix, original.modelMatrix, "unrelated placement's matrix must be byte-identical after the patch")
        }
    }

    /// The real, load-bearing proof for `SceneryDataWriter.encode`: parsing
    /// a genuine, real `SceneryData` record from an actual disc file (with
    /// real lights, a real nested tree, real placements) and re-encoding
    /// it unmodified must reproduce the *exact original bytes*, not just
    /// "decodes to the same values." Byte-exact is the real bar every
    /// other full-record writer in this codebase is held to, and it's the
    /// only way to be confident no field (light extras, `unkPos`, header
    /// bytes) got silently dropped or reordered in this port.
    func testEncodeUnmodifiedRealSceneryDataIsByteExact() throws {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Real disc image not present")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)
        guard let entry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/hubb.sm2" }) else {
            throw XCTSkip("hubb.sm2 not found in this archive")
        }
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .sm2, fileName: entry.name)

        var sceneryNode: ChunkNode?
        var found: SceneryAsset?
        func walk(_ node: ChunkNode) {
            if found == nil, case .scenery(let scenery) = node.payload, !scenery.placements.isEmpty {
                found = scenery
                sceneryNode = node
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        let scenery = try XCTUnwrap(found)
        let node = try XCTUnwrap(sceneryNode)
        let originalRecordBytes = data.subdata(in: (data.startIndex + node.fileOffset)..<(data.startIndex + node.fileOffset + node.byteSize))

        let reEncoded = SceneryDataWriter.encode(scenery)
        XCTAssertEqual(reEncoded, originalRecordBytes, "re-encoding an unmodified real SceneryData record must reproduce its original bytes exactly")
    }

    /// Real insertion: appending one new non-special placement to the
    /// root's own model group must grow the record by exactly 100 bytes
    /// (32 bbox + 4 modelID + 64 matrix, `SceneryData.cs`'s own
    /// `CountSceneryModel`) and every *original* placement must still
    /// decode identically afterward.
    func testAppendingANewPlacementGrowsTheRecordAndPreservesExistingPlacements() throws {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Real disc image not present")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)
        guard let entry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/hubb.sm2" }) else {
            throw XCTSkip("hubb.sm2 not found in this archive")
        }
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .sm2, fileName: entry.name)

        var found: SceneryAsset?
        func walk(_ node: ChunkNode) {
            if found == nil, case .scenery(let scenery) = node.payload, !scenery.placements.isEmpty {
                found = scenery
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        var scenery = try XCTUnwrap(found)
        let originalRoot = try XCTUnwrap(scenery.root)
        let originalPlacementCount = originalRoot.model.placements.count
        let originalFlattenedCount = scenery.placements.count

        let newPlacement = SceneryModelPlacement(
            modelID: 999_999, isSpecial: false,
            boundingBoxMin: SIMD4<Float>(-1, -1, -1, 1), boundingBoxMax: SIMD4<Float>(1, 1, 1, 1),
            modelMatrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(50, 60, 70, 1)]
        )
        // Insert *before* any existing special placement, not a blind
        // append, `writeSceneryModelGroup` derives `modelCount` by
        // scanning for the first `isSpecial`, so a non-special placement
        // landing after a special one would be silently miscounted as
        // special too on the next save. This is the same invariant real
        // insertion logic must respect.
        var newRoot = originalRoot
        let insertIndex = newRoot.model.placements.firstIndex(where: { $0.isSpecial }) ?? newRoot.model.placements.count
        newRoot.model.placements.insert(newPlacement, at: insertIndex)
        // A group whose `header` wasn't already `0x1613` writes *no*
        // placement data at all regardless of what's in `placements` , 
        // `writeSceneryModelGroup`'s own header gate, matching
        // `SaveSceneryModel`'s exactly. Real insertion logic must set this
        // too when adding the first placement to a previously-empty group
        // (this fixture's root group had zero placements of its own , 
        // real ones live in its nested leaf groups).
        newRoot.model.header = 0x1613
        scenery.root = newRoot

        let grown = SceneryDataWriter.encode(scenery)
        var cursor = BinaryCursor(data: grown)
        let reparsed = try SceneryDataParser.parse(&cursor, recordID: 1)

        XCTAssertEqual(reparsed.root?.model.placements.count, originalPlacementCount + 1)
        XCTAssertEqual(reparsed.placements.count, originalFlattenedCount + 1)
        guard let appended = reparsed.root?.model.placements.first(where: { $0.modelID == 999_999 }) else {
            return XCTFail("appended placement missing after re-parse")
        }
        XCTAssertFalse(appended.isSpecial)
        XCTAssertEqual(appended.translation, SIMD3<Float>(50, 60, 70))

        // Every original placement in the root's own model group must
        // still decode identically (same modelID/translation/isSpecial),
        // as a set, proves the insertion didn't disturb or lose anything
        // already there, independent of exact index shift.
        let reparsedOthers = reparsed.root!.model.placements.filter { $0.modelID != 999_999 }
        XCTAssertEqual(reparsedOthers.count, originalRoot.model.placements.count)
        for originalPlacement in originalRoot.model.placements {
            XCTAssertTrue(reparsedOthers.contains { $0.modelID == originalPlacement.modelID && $0.isSpecial == originalPlacement.isSpecial && $0.translation == originalPlacement.translation },
                           "original placement (modelID \(originalPlacement.modelID)) must survive the insertion unchanged")
        }
    }

    /// "Real Delete for Existing Scenery", the removal counterpart to
    /// `testAppendingANewPlacementGrowsTheRecordAndPreservesExistingPlacements`.
    /// Removes one real placement by its own `matrixFileOffset`, found via
    /// `scenery.placements` (the *flattened* list, which per that test's own
    /// comment mostly lives in nested leaf groups for this fixture, not the
    /// root's own `model.placements`), so this genuinely exercises
    /// `SceneryGroup.removingPlacements`'s recursive tree walk, not just a
    /// same-as-root-level filter.
    func testRemovingAnExistingPlacementByFileOffsetShrinksTheRecordAndPreservesEverythingElse() throws {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Real disc image not present")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)
        guard let entry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/hubb.sm2" }) else {
            throw XCTSkip("hubb.sm2 not found in this archive")
        }
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .sm2, fileName: entry.name)

        var found: SceneryAsset?
        func walk(_ node: ChunkNode) {
            if found == nil, case .scenery(let scenery) = node.payload, !scenery.placements.isEmpty {
                found = scenery
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        var scenery = try XCTUnwrap(found)
        let originalFlattenedCount = scenery.placements.count
        let target = try XCTUnwrap(scenery.placements.first { $0.matrixFileOffset != nil })
        let targetOffset = try XCTUnwrap(target.matrixFileOffset)
        let survivors = scenery.placements.filter { $0.matrixFileOffset != targetOffset }
        let originalRoot = try XCTUnwrap(scenery.root)

        scenery.root = originalRoot.removingPlacements(withFileOffsets: [targetOffset])

        let shrunk = SceneryDataWriter.encode(scenery)
        var cursor = BinaryCursor(data: shrunk)
        let reparsed = try SceneryDataParser.parse(&cursor, recordID: 1)

        XCTAssertEqual(reparsed.placements.count, originalFlattenedCount - 1, "exactly the one targeted placement must be gone, nothing else")
        XCTAssertFalse(
            reparsed.placements.contains { $0.modelID == target.modelID && $0.translation == target.translation },
            "the removed placement's own (modelID, position) must no longer appear anywhere in the re-parsed tree"
        )
        for survivor in survivors {
            XCTAssertTrue(
                reparsed.placements.contains { $0.modelID == survivor.modelID && $0.isSpecial == survivor.isSpecial && $0.translation == survivor.translation },
                "surviving placement (modelID \(survivor.modelID)) must decode identically after an unrelated removal elsewhere in the tree"
            )
        }
    }
}
