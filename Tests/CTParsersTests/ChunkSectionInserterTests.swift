import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers

/// The safety gate for "Backend Requirement: safely inject this new record
/// into the .RM2 file structure without corrupting the chunk" (Part 4D).
/// Builds a small but *real, real-format* nested chunk-section byte buffer
/// by hand, inserts a new record with `ChunkSectionInserter`, and, the
/// part that actually matters, re-parses the result from scratch with the
/// same `RM2Parser` production code uses, rather than inspecting the
/// patched bytes directly. If the structural surgery got an offset or a
/// size field wrong anywhere, this is where it would show up: either the
/// re-parse throws, or something decodes to the wrong data.
final class ChunkSectionInserterTests: XCTestCase {
    private func makeSection(children: [(id: UInt32, bytes: Data)]) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(TwinsMagic.v1)
        writer.writeInt32(Int32(children.count))
        let contentSize = children.reduce(0) { $0 + $1.bytes.count }
        writer.writeUInt32(UInt32(contentSize))
        var offset = 12 + children.count * 12
        for child in children {
            writer.writeUInt32(UInt32(offset))
            writer.writeInt32(Int32(child.bytes.count))
            writer.writeUInt32(child.id)
            offset += child.bytes.count
        }
        for child in children {
            writer.writeBytes(child.bytes)
        }
        return writer.data
    }

    private func findFirst(_ node: ChunkNode, sectionType: SectionType) -> ChunkNode? {
        if node.sectionType == sectionType { return node }
        for child in node.children {
            if let found = findFirst(child, sectionType: sectionType) { return found }
        }
        return nil
    }

    func testInsertingNewInstanceRoundTripsAndPreservesSiblings() throws {
        let originalInstance = WorldPlacementWriter.writeNewInstance(objectID: 3, position: SIMD4<Float>(1, 2, 3, 1), rotationDegrees: .zero)
        let triggerBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])

        // .instance container (Tier 1) -> .objectInstance (subID 6) and
        // .trigger (subID 7) collections (Tier 2), per `RM2Parser.
        // tier1ChildType`. The trigger "record" is deliberately not a real
        // Trigger (just 4 arbitrary bytes), this test isn't exercising
        // WorldPlacementParser, only that this untouched sibling collection
        // survives byte-for-byte when its neighbor grows.
        let objectInstanceCollection = makeSection(children: [(id: 100, bytes: originalInstance)])
        let triggerCollection = makeSection(children: [(id: 200, bytes: triggerBytes)])
        let instanceContainer = makeSection(children: [(id: 6, bytes: objectInstanceCollection), (id: 7, bytes: triggerCollection)])
        // Tier 0: any top-level entry with id 0...7 is the Instance section.
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer)])

        let fileRoot = try RM2Parser.parse(data: fileBytes, fileKind: .rm2, fileName: "synthetic.rm2")
        let objectInstanceNode = try XCTUnwrap(findFirst(fileRoot, sectionType: .objectInstance))
        XCTAssertEqual(objectInstanceNode.children.count, 1, "precondition: fixture decoded as expected before any insertion")

        let newRecord = WorldPlacementWriter.writeNewInstance(objectID: 55, position: SIMD4<Float>(9, 8, 7, 1), rotationDegrees: SIMD3<Float>(0, 90, 0))
        let patched = try XCTUnwrap(ChunkSectionInserter.insertingRecord(id: 101, encoded: newRecord, into: objectInstanceNode, fileRoot: fileRoot, originalFileBytes: fileBytes))

        let reparsedRoot = try RM2Parser.parse(data: patched, fileKind: .rm2, fileName: "synthetic.rm2")
        let reparsedObjectInstance = try XCTUnwrap(findFirst(reparsedRoot, sectionType: .objectInstance))
        XCTAssertEqual(reparsedObjectInstance.children.count, 2)

        guard case .instance(let original)? = reparsedObjectInstance.children.first(where: { $0.recordID == 100 })?.payload else {
            return XCTFail("original instance record didn't survive the insert")
        }
        XCTAssertEqual(original.objectID, 3)
        XCTAssertEqual(original.position, SIMD4<Float>(1, 2, 3, 1))

        guard case .instance(let inserted)? = reparsedObjectInstance.children.first(where: { $0.recordID == 101 })?.payload else {
            return XCTFail("newly inserted instance record didn't decode")
        }
        XCTAssertEqual(inserted.objectID, 55)
        XCTAssertEqual(inserted.position, SIMD4<Float>(9, 8, 7, 1))
        XCTAssertEqual(inserted.rotationDegrees.y, 90, accuracy: 0.5)
        XCTAssertEqual(inserted.refList, -1)
        XCTAssertEqual(inserted.scriptID, -1)

        // The untouched sibling collection must still be exactly where it
        // says it is, byte-for-byte, not just "a Trigger section still
        // exists," but these specific bytes, unshifted and uncorrupted.
        let reparsedTrigger = try XCTUnwrap(findFirst(reparsedRoot, sectionType: .trigger))
        XCTAssertEqual(reparsedTrigger.children.count, 1)
        let triggerLeaf = try XCTUnwrap(reparsedTrigger.children.first)
        XCTAssertEqual(triggerLeaf.recordID, 200)
        let recoveredTriggerBytes = patched.subdata(in: (patched.startIndex + triggerLeaf.fileOffset)..<(patched.startIndex + triggerLeaf.fileOffset + triggerLeaf.byteSize))
        XCTAssertEqual(recoveredTriggerBytes, triggerBytes)
    }

    /// "Save Level Overrides" batches every new placement from one session
    /// into a single save, `insertingRecords` (plural) is what makes that
    /// possible without re-parsing between each insert. Exercised directly
    /// here, not just through the singular wrapper.
    func testInsertingMultipleRecordsInOnePass() throws {
        let objectInstanceCollection = makeSection(children: [])
        let instanceContainer = makeSection(children: [(id: 6, bytes: objectInstanceCollection)])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer)])

        let fileRoot = try RM2Parser.parse(data: fileBytes, fileKind: .rm2, fileName: "synthetic2.rm2")
        let objectInstanceNode = try XCTUnwrap(findFirst(fileRoot, sectionType: .objectInstance))

        let recordA = WorldPlacementWriter.writeNewInstance(objectID: 10, position: SIMD4<Float>(1, 0, 0, 1), rotationDegrees: .zero)
        let recordB = WorldPlacementWriter.writeNewInstance(objectID: 20, position: SIMD4<Float>(2, 0, 0, 1), rotationDegrees: .zero)
        let patched = try XCTUnwrap(ChunkSectionInserter.insertingRecords(
            [(id: 300, encoded: recordA), (id: 301, encoded: recordB)],
            into: objectInstanceNode, fileRoot: fileRoot, originalFileBytes: fileBytes
        ))

        let reparsed = try RM2Parser.parse(data: patched, fileKind: .rm2, fileName: "synthetic2.rm2")
        let reparsedCollection = try XCTUnwrap(findFirst(reparsed, sectionType: .objectInstance))
        XCTAssertEqual(reparsedCollection.children.count, 2)

        guard case .instance(let a)? = reparsedCollection.children.first(where: { $0.recordID == 300 })?.payload else {
            return XCTFail("first batched record didn't decode")
        }
        guard case .instance(let b)? = reparsedCollection.children.first(where: { $0.recordID == 301 })?.payload else {
            return XCTFail("second batched record didn't decode")
        }
        XCTAssertEqual(a.objectID, 10)
        XCTAssertEqual(b.objectID, 20)
    }

    /// "AI Pathfinding & Navmesh Editor" (roadmap 5.1) regression: two
    /// *different*, sibling sections (`.aiPosition` and `.objectInstance`,
    /// both under the same `.instance` container, exactly how real files
    /// lay these out) each growing in the same save. Calling the
    /// single-target `insertingRecords(_:into:...)` twice in a row here
    /// silently corrupted the result (verified while building this): the
    /// second call rebuilt its ancestor chain from the *original* tree's
    /// offsets against a buffer the first call had already grown.
    /// `insertingRecords(intoSections:...)` does one combined rebuild
    /// instead, this pins that both insertions, and the untouched
    /// sibling record in each collection, all survive correctly.
    func testInsertingIntoMultipleSiblingSectionsInOnePass() throws {
        let originalInstance = WorldPlacementWriter.writeNewInstance(objectID: 1, position: SIMD4<Float>(0, 0, 0, 1), rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(id: 100, bytes: originalInstance)])
        let originalWaypoint = WorldPlacementWriter.writeAIPosition(position: SIMD4<Float>(9, 9, 9, 1), rawNodeType: 0)
        let aiPositionCollection = makeSection(children: [(id: 200, bytes: originalWaypoint)])
        let instanceContainer = makeSection(children: [(id: 1, bytes: aiPositionCollection), (id: 6, bytes: objectInstanceCollection)])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer)])

        let fileRoot = try RM2Parser.parse(data: fileBytes, fileKind: .rm2, fileName: "synthetic3.rm2")
        let objectInstanceNode = try XCTUnwrap(findFirst(fileRoot, sectionType: .objectInstance))
        let aiPositionNode = try XCTUnwrap(findFirst(fileRoot, sectionType: .aiPosition))

        let newInstance = WorldPlacementWriter.writeNewInstance(objectID: 77, position: SIMD4<Float>(5, 5, 5, 1), rotationDegrees: .zero)
        let newWaypoint = WorldPlacementWriter.writeAIPosition(position: SIMD4<Float>(6, 6, 6, 1), rawNodeType: 4)
        let patched = try XCTUnwrap(ChunkSectionInserter.insertingRecords(
            intoSections: [
                (objectInstanceNode, [(id: 999, encoded: newInstance)]),
                (aiPositionNode, [(id: 888, encoded: newWaypoint)])
            ],
            fileRoot: fileRoot, originalFileBytes: fileBytes
        ))

        let reparsed = try RM2Parser.parse(data: patched, fileKind: .rm2, fileName: "synthetic3.rm2")

        let reparsedInstances = try XCTUnwrap(findFirst(reparsed, sectionType: .objectInstance))
        XCTAssertEqual(reparsedInstances.children.count, 2)
        guard case .instance(let originalInst)? = reparsedInstances.children.first(where: { $0.recordID == 100 })?.payload else {
            return XCTFail("pre-existing instance didn't survive")
        }
        XCTAssertEqual(originalInst.objectID, 1)
        guard case .instance(let insertedInst)? = reparsedInstances.children.first(where: { $0.recordID == 999 })?.payload else {
            return XCTFail("inserted instance didn't decode")
        }
        XCTAssertEqual(insertedInst.objectID, 77)

        let reparsedWaypoints = try XCTUnwrap(findFirst(reparsed, sectionType: .aiPosition))
        XCTAssertEqual(reparsedWaypoints.children.count, 2)
        guard case .aiPosition(let originalWP)? = reparsedWaypoints.children.first(where: { $0.recordID == 200 })?.payload else {
            return XCTFail("pre-existing waypoint didn't survive")
        }
        XCTAssertEqual(originalWP.position, SIMD4<Float>(9, 9, 9, 1))
        guard case .aiPosition(let insertedWP)? = reparsedWaypoints.children.first(where: { $0.recordID == 888 })?.payload else {
            return XCTFail("inserted waypoint didn't decode")
        }
        XCTAssertEqual(insertedWP.position, SIMD4<Float>(6, 6, 6, 1))
        XCTAssertEqual(insertedWP.rawNodeType, 4)
    }

    func testInsertingIntoUnreachableSectionReturnsNil() {
        let unrelatedRoot = ChunkNode(recordID: 0, sectionType: .null, displayName: "other", byteSize: 0, fileOffset: 0)
        let detachedTarget = ChunkNode(recordID: 1, sectionType: .objectInstance, displayName: "detached", byteSize: 12, fileOffset: 0)
        XCTAssertNil(ChunkSectionInserter.insertingRecord(id: 1, encoded: Data(), into: detachedTarget, fileRoot: unrelatedRoot, originalFileBytes: Data()))
    }

    /// The deletion counterpart to `testInsertingNewInstanceRoundTripsAndPreservesSiblings`
    ///, removes one of two records by ID, re-parses with the real
    /// `RM2Parser`, and confirms the removed ID is really gone while the
    /// surviving record and the untouched sibling section are unaffected.
    func testRemovingRecordRoundTripsAndPreservesSiblings() throws {
        let keepInstance = WorldPlacementWriter.writeNewInstance(objectID: 3, position: SIMD4<Float>(1, 2, 3, 1), rotationDegrees: .zero)
        let removeInstance = WorldPlacementWriter.writeNewInstance(objectID: 55, position: SIMD4<Float>(9, 8, 7, 1), rotationDegrees: .zero)
        let triggerBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let objectInstanceCollection = makeSection(children: [(id: 100, bytes: keepInstance), (id: 101, bytes: removeInstance)])
        let triggerCollection = makeSection(children: [(id: 200, bytes: triggerBytes)])
        let instanceContainer = makeSection(children: [(id: 6, bytes: objectInstanceCollection), (id: 7, bytes: triggerCollection)])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer)])

        let fileRoot = try RM2Parser.parse(data: fileBytes, fileKind: .rm2, fileName: "synthetic4.rm2")
        let objectInstanceNode = try XCTUnwrap(findFirst(fileRoot, sectionType: .objectInstance))
        XCTAssertEqual(objectInstanceNode.children.count, 2, "precondition: fixture decoded as expected before any removal")

        let patched = try XCTUnwrap(ChunkSectionInserter.removingRecord(id: 101, from: objectInstanceNode, fileRoot: fileRoot, originalFileBytes: fileBytes))

        let reparsedRoot = try RM2Parser.parse(data: patched, fileKind: .rm2, fileName: "synthetic4.rm2")
        let reparsedObjectInstance = try XCTUnwrap(findFirst(reparsedRoot, sectionType: .objectInstance))
        XCTAssertEqual(reparsedObjectInstance.children.count, 1)
        XCTAssertNil(reparsedObjectInstance.children.first(where: { $0.recordID == 101 }), "removed record must really be gone")

        guard case .instance(let survivor)? = reparsedObjectInstance.children.first(where: { $0.recordID == 100 })?.payload else {
            return XCTFail("surviving instance record didn't decode")
        }
        XCTAssertEqual(survivor.objectID, 3)
        XCTAssertEqual(survivor.position, SIMD4<Float>(1, 2, 3, 1))

        // The untouched sibling collection must still be exactly where it
        // says it is, byte-for-byte.
        let reparsedTrigger = try XCTUnwrap(findFirst(reparsedRoot, sectionType: .trigger))
        XCTAssertEqual(reparsedTrigger.children.count, 1)
        let triggerLeaf = try XCTUnwrap(reparsedTrigger.children.first)
        XCTAssertEqual(triggerLeaf.recordID, 200)
        let recoveredTriggerBytes = patched.subdata(in: (patched.startIndex + triggerLeaf.fileOffset)..<(patched.startIndex + triggerLeaf.fileOffset + triggerLeaf.byteSize))
        XCTAssertEqual(recoveredTriggerBytes, triggerBytes)
    }

    /// Removing the *last* record in a section must produce a real,
    /// re-parseable, genuinely empty section (RecordCount 0), not a
    /// malformed one.
    func testRemovingLastRecordLeavesAnEmptySection() throws {
        let onlyInstance = WorldPlacementWriter.writeNewInstance(objectID: 9, position: .zero, rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(id: 100, bytes: onlyInstance)])
        let instanceContainer = makeSection(children: [(id: 6, bytes: objectInstanceCollection)])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer)])

        let fileRoot = try RM2Parser.parse(data: fileBytes, fileKind: .rm2, fileName: "synthetic5.rm2")
        let objectInstanceNode = try XCTUnwrap(findFirst(fileRoot, sectionType: .objectInstance))

        let patched = try XCTUnwrap(ChunkSectionInserter.removingRecord(id: 100, from: objectInstanceNode, fileRoot: fileRoot, originalFileBytes: fileBytes))
        let reparsedRoot = try RM2Parser.parse(data: patched, fileKind: .rm2, fileName: "synthetic5.rm2")
        let reparsedObjectInstance = try XCTUnwrap(findFirst(reparsedRoot, sectionType: .objectInstance))
        XCTAssertEqual(reparsedObjectInstance.children.count, 0)
    }

    /// Removing from one section while a sibling section is untouched in
    /// the same save (the general `applyingRecordChanges` path a combined
    /// delete-Instance + add-Trigger save would exercise), verified via the
    /// multi-section entry point directly.
    func testRemovingFromOneSectionAlongsideUntouchedSibling() throws {
        let keepInstance = WorldPlacementWriter.writeNewInstance(objectID: 1, position: .zero, rotationDegrees: .zero)
        let removeInstance = WorldPlacementWriter.writeNewInstance(objectID: 2, position: .zero, rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(id: 100, bytes: keepInstance), (id: 101, bytes: removeInstance)])
        let originalWaypoint = WorldPlacementWriter.writeAIPosition(position: SIMD4<Float>(9, 9, 9, 1), rawNodeType: 0)
        let aiPositionCollection = makeSection(children: [(id: 200, bytes: originalWaypoint)])
        let instanceContainer = makeSection(children: [(id: 1, bytes: aiPositionCollection), (id: 6, bytes: objectInstanceCollection)])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer)])

        let fileRoot = try RM2Parser.parse(data: fileBytes, fileKind: .rm2, fileName: "synthetic6.rm2")
        let objectInstanceNode = try XCTUnwrap(findFirst(fileRoot, sectionType: .objectInstance))

        let patched = try XCTUnwrap(ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: objectInstanceNode, insert: [], removeIDs: [101])],
            fileRoot: fileRoot, originalFileBytes: fileBytes
        ))

        let reparsed = try RM2Parser.parse(data: patched, fileKind: .rm2, fileName: "synthetic6.rm2")
        let reparsedInstances = try XCTUnwrap(findFirst(reparsed, sectionType: .objectInstance))
        XCTAssertEqual(reparsedInstances.children.count, 1)
        XCTAssertEqual(reparsedInstances.children.first?.recordID, 100)

        let reparsedWaypoints = try XCTUnwrap(findFirst(reparsed, sectionType: .aiPosition))
        XCTAssertEqual(reparsedWaypoints.children.count, 1)
        guard case .aiPosition(let originalWP)? = reparsedWaypoints.children.first(where: { $0.recordID == 200 })?.payload else {
            return XCTFail("untouched sibling waypoint didn't survive")
        }
        XCTAssertEqual(originalWP.position, SIMD4<Float>(9, 9, 9, 1))
    }

    /// A single target section can both gain a new record and lose an
    /// existing one in the same save, the exact shape "delete this
    /// Instance, add a new Trigger" would need if both ever targeted the
    /// same collection type.
    func testCombinedInsertAndRemoveInSameSection() throws {
        let keepInstance = WorldPlacementWriter.writeNewInstance(objectID: 1, position: .zero, rotationDegrees: .zero)
        let removeInstance = WorldPlacementWriter.writeNewInstance(objectID: 2, position: .zero, rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(id: 100, bytes: keepInstance), (id: 101, bytes: removeInstance)])
        let instanceContainer = makeSection(children: [(id: 6, bytes: objectInstanceCollection)])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer)])

        let fileRoot = try RM2Parser.parse(data: fileBytes, fileKind: .rm2, fileName: "synthetic7.rm2")
        let objectInstanceNode = try XCTUnwrap(findFirst(fileRoot, sectionType: .objectInstance))

        let newInstance = WorldPlacementWriter.writeNewInstance(objectID: 77, position: SIMD4<Float>(5, 5, 5, 1), rotationDegrees: .zero)
        let patched = try XCTUnwrap(ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: objectInstanceNode, insert: [(id: 999, encoded: newInstance)], removeIDs: [101])],
            fileRoot: fileRoot, originalFileBytes: fileBytes
        ))

        let reparsed = try RM2Parser.parse(data: patched, fileKind: .rm2, fileName: "synthetic7.rm2")
        let reparsedInstances = try XCTUnwrap(findFirst(reparsed, sectionType: .objectInstance))
        XCTAssertEqual(reparsedInstances.children.count, 2)
        XCTAssertNil(reparsedInstances.children.first(where: { $0.recordID == 101 }))
        guard case .instance(let survivor)? = reparsedInstances.children.first(where: { $0.recordID == 100 })?.payload else {
            return XCTFail("surviving instance didn't decode")
        }
        XCTAssertEqual(survivor.objectID, 1)
        guard case .instance(let inserted)? = reparsedInstances.children.first(where: { $0.recordID == 999 })?.payload else {
            return XCTFail("newly inserted instance didn't decode")
        }
        XCTAssertEqual(inserted.objectID, 77)
    }

    func testRemovingNonexistentIDReturnsNilRatherThanSilentlyNoOp() throws {
        let onlyInstance = WorldPlacementWriter.writeNewInstance(objectID: 9, position: .zero, rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(id: 100, bytes: onlyInstance)])
        let instanceContainer = makeSection(children: [(id: 6, bytes: objectInstanceCollection)])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer)])

        let fileRoot = try RM2Parser.parse(data: fileBytes, fileKind: .rm2, fileName: "synthetic8.rm2")
        let objectInstanceNode = try XCTUnwrap(findFirst(fileRoot, sectionType: .objectInstance))

        XCTAssertNil(ChunkSectionInserter.removingRecord(id: 9999, from: objectInstanceNode, fileRoot: fileRoot, originalFileBytes: fileBytes))
    }
}
