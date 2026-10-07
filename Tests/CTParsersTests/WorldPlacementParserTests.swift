import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class WorldPlacementParserTests: XCTestCase {
    func testParsePosition() throws {
        var w = BinaryWriter()
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3); w.writeFloat32(1)

        var cursor = BinaryCursor(data: w.data)
        let position = try WorldPlacementParser.parsePosition(&cursor, recordID: 5)

        XCTAssertEqual(position.id, 5)
        XCTAssertEqual(position.point, SIMD4<Float>(1, 2, 3, 1))
    }

    /// The "Editing GUI" write path's core correctness guarantee: encoding
    /// a decoded (and possibly edited) `PositionMarker` must produce
    /// exactly the same 16-byte shape the parser reads, so patching it back
    /// into a copy of the original file at the record's known offset never
    /// shifts anything after it.
    func testPositionRoundTripsThroughWriter() throws {
        let original = PositionMarker(id: 9, point: SIMD4<Float>(1.5, -2.25, 3.75, 1))
        let encoded = WorldPlacementWriter.writePosition(original)

        XCTAssertEqual(encoded.count, 16)

        var cursor = BinaryCursor(data: encoded)
        let decoded = try WorldPlacementParser.parsePosition(&cursor, recordID: original.id)

        XCTAssertEqual(decoded.point, original.point)
        XCTAssertEqual(cursor.position, 16)
    }

    /// Empty-lists case should read exactly 90 bytes, matching the
    /// reference tool's `Instance.GetSize()` base constant
    /// (`Twinsanity/Items/Instances/Instance.cs:127`), which was written
    /// independently of the read path and so is a useful cross-check.
    func testParseInstanceEmptyListsConsumesExactly90Bytes() throws {
        var w = BinaryWriter()
        w.writeFloat32(10); w.writeFloat32(20); w.writeFloat32(30); w.writeFloat32(1) // Pos
        w.writeUInt16(1000); w.writeUInt16(11) // RotX, COMRotX
        w.writeUInt16(2000); w.writeUInt16(22) // RotY, COMRotY
        w.writeUInt16(3000); w.writeUInt16(33) // RotZ, COMRotZ
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10) // InstanceIDs: dup count, count, SomeNum1
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10) // PositionIDs
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10) // PathIDs
        w.writeUInt16(7)    // ObjectID
        w.writeInt16(-1)    // RefList
        w.writeInt16(-1)    // ScriptID
        w.writeUInt32(0)    // PHeader
        w.writeUInt32(0x6)  // Flags
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0) // three empty unknown lists

        XCTAssertEqual(w.count, 90)

        var cursor = BinaryCursor(data: w.data)
        let instance = try WorldPlacementParser.parseInstance(&cursor, recordID: 3)

        XCTAssertEqual(instance.position, SIMD4<Float>(10, 20, 30, 1))
        XCTAssertEqual(instance.rotationRaw, SIMD3<UInt16>(1000, 2000, 3000))
        XCTAssertEqual(instance.comRotationRaw, SIMD3<UInt16>(11, 22, 33))
        XCTAssertEqual(instance.objectID, 7)
        XCTAssertEqual(instance.refList, -1)
        XCTAssertEqual(instance.scriptID, -1)
        XCTAssertEqual(instance.flags, 0x6)
        XCTAssertTrue(instance.childInstanceIDs.isEmpty)
        XCTAssertTrue(instance.childPositionIDs.isEmpty)
        XCTAssertTrue(instance.childPathIDs.isEmpty)
        XCTAssertEqual(cursor.position, w.count)
    }

    func testParseInstancePopulatedIDLists() throws {
        var w = BinaryWriter()
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeUInt16(0); w.writeUInt16(0)
        w.writeUInt16(0); w.writeUInt16(0)
        w.writeUInt16(0); w.writeUInt16(0)

        w.writeInt32(2); w.writeInt32(2); w.writeInt32(10)
        w.writeUInt16(101); w.writeUInt16(102)

        w.writeInt32(1); w.writeInt32(1); w.writeInt32(10)
        w.writeUInt16(201)

        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10)

        w.writeUInt16(42)
        w.writeInt16(5)
        w.writeInt16(9)
        w.writeUInt32(0)
        w.writeUInt32(0)
        w.writeInt32(1); w.writeUInt32(0xDEAD_BEEF)
        w.writeInt32(1); w.writeFloat32(1.5)
        w.writeInt32(2); w.writeUInt32(1); w.writeUInt32(2)

        var cursor = BinaryCursor(data: w.data)
        let instance = try WorldPlacementParser.parseInstance(&cursor, recordID: 1)

        XCTAssertEqual(instance.childInstanceIDs, [101, 102])
        XCTAssertEqual(instance.childPositionIDs, [201])
        XCTAssertEqual(instance.childPathIDs, [])
        XCTAssertEqual(instance.objectID, 42)
        XCTAssertEqual(instance.refList, 5)
        XCTAssertEqual(instance.scriptID, 9)
        XCTAssertEqual(instance.unknownUInt32List, [0xDEAD_BEEF])
        XCTAssertEqual(instance.unknownFloatList, [1.5])
        XCTAssertEqual(instance.unknownUInt32List2, [1, 2])
        XCTAssertEqual(cursor.position, w.count)

        // "Recipe Book" (roadmap 6.4) write-back: objectIDFileOffset must
        // point at the real bytes, and writeInstanceObjectID's 2 bytes
        // patched there must round-trip a reassigned objectID while
        // leaving every other field (including the child ID lists right
        // before it) untouched.
        var probe = BinaryCursor(data: w.data)
        _ = try probe.seek(to: instance.objectIDFileOffset)
        XCTAssertEqual(try probe.readUInt16(), 42)

        var patched = w.data
        let offset = instance.objectIDFileOffset
        patched.replaceSubrange(offset..<(offset + 2), with: WorldPlacementWriter.writeInstanceObjectID(777))
        var reparseCursor = BinaryCursor(data: patched)
        let reparsed = try WorldPlacementParser.parseInstance(&reparseCursor, recordID: 1)
        XCTAssertEqual(reparsed.objectID, 777)
        XCTAssertEqual(reparsed.childInstanceIDs, [101, 102])
        XCTAssertEqual(reparsed.refList, 5)
        XCTAssertEqual(patched.count, w.count)
    }

    /// `someNum1`/`2`/`3` (`Instance.SomeNum1`/`2`/`3`, real independent
    /// data, not derived from the list it sits next to) must decode as the
    /// real on-disk value, not the list's own count, uses a value that
    /// deliberately differs from both the reference's `= 10` default and
    /// each list's own element count, so a bug that confused this field
    /// with count/duplicate-count would be caught.
    func testParseInstanceCapturesRealSomeNumValues() throws {
        var w = BinaryWriter()
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeUInt16(0); w.writeUInt16(0)
        w.writeUInt16(0); w.writeUInt16(0)
        w.writeUInt16(0); w.writeUInt16(0)

        w.writeInt32(1); w.writeInt32(1); w.writeInt32(777) // someNum1 = 777
        w.writeUInt16(101)
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(888) // someNum2 = 888
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(999) // someNum3 = 999

        w.writeUInt16(1); w.writeInt16(-1); w.writeInt16(-1)
        w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)

        var cursor = BinaryCursor(data: w.data)
        let instance = try WorldPlacementParser.parseInstance(&cursor, recordID: 1)
        XCTAssertEqual(instance.someNum1, 777)
        XCTAssertEqual(instance.someNum2, 888)
        XCTAssertEqual(instance.someNum3, 999)
    }

    /// "Real Flags for Forge-Placed Objects" + "Set AI Path on a Newly-
    /// Placed AI": `writeNewInstance`'s two newer parameters
    /// (`flags`/`pathIDs`) must round-trip through the real parser exactly
    /// like every other field this encoder already covered, a real,
    /// non-default `flags` value (not the `0x811E` default, so a bug that
    /// silently ignored the parameter wouldn't coincidentally still pass)
    /// and a non-empty `pathIDs` list landing in `childPathIDs`, not
    /// `childInstanceIDs`/`childPositionIDs` (the two other counted lists
    /// this same record carries).
    func testWriteNewInstanceRoundTripsFlagsAndPathIDs() throws {
        let encoded = WorldPlacementWriter.writeNewInstance(
            objectID: 218,
            position: SIMD4<Float>(10, 20, 30, 1),
            rotationDegrees: .zero,
            flags: 0x188B2E,
            pathIDs: [5, 9]
        )
        var cursor = BinaryCursor(data: encoded)
        let instance = try WorldPlacementParser.parseInstance(&cursor, recordID: 1)
        XCTAssertEqual(instance.objectID, 218)
        XCTAssertEqual(instance.flags, 0x188B2E)
        XCTAssertEqual(instance.childPathIDs, [5, 9])
        XCTAssertTrue(instance.childInstanceIDs.isEmpty)
        XCTAssertTrue(instance.childPositionIDs.isEmpty)
        XCTAssertEqual(instance.someNum1, 10)
        XCTAssertEqual(instance.someNum2, 10)
        XCTAssertEqual(instance.someNum3, 10)
        XCTAssertEqual(cursor.position, encoded.count)
    }

    /// The no-`pathIDs`-passed case (every pre-existing call site) must
    /// still produce the exact same empty-PathIDs record it always did , 
    /// confirms adding the new parameter didn't change existing behavior
    /// for callers that don't pass it.
    func testWriteNewInstanceDefaultsToEmptyPathIDs() throws {
        let encoded = WorldPlacementWriter.writeNewInstance(objectID: 3, position: .zero, rotationDegrees: .zero)
        var cursor = BinaryCursor(data: encoded)
        let instance = try WorldPlacementParser.parseInstance(&cursor, recordID: 1)
        XCTAssertTrue(instance.childPathIDs.isEmpty)
        XCTAssertEqual(instance.flags, 0x811E)
    }

    /// `WorldPlacementWriter.writeInstance`, the general, arbitrary-field
    /// encoder `InstanceInspectorView`'s full-record editing depends on , 
    /// must round-trip `parse(write(parse(x))) == parse(x)` byte-exactly,
    /// including `someNum1`/`2`/`3` and every list.
    func testWriteInstanceRoundTripsExactly() throws {
        var w = BinaryWriter()
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3); w.writeFloat32(1)
        w.writeUInt16(10); w.writeUInt16(20)
        w.writeUInt16(30); w.writeUInt16(40)
        w.writeUInt16(50); w.writeUInt16(60)

        w.writeInt32(2); w.writeInt32(2); w.writeInt32(777)
        w.writeUInt16(101); w.writeUInt16(102)
        w.writeInt32(1); w.writeInt32(1); w.writeInt32(888)
        w.writeUInt16(201)
        w.writeInt32(1); w.writeInt32(1); w.writeInt32(999)
        w.writeUInt16(301)

        w.writeUInt16(42); w.writeInt16(5); w.writeInt16(9)
        w.writeUInt32(0x02_01_01) // PHeader: 1 | (1 << 8) | (2 << 16), matches the three list counts below
        w.writeUInt32(0x6)
        w.writeInt32(1); w.writeUInt32(0xDEAD_BEEF)
        w.writeInt32(1); w.writeFloat32(1.5)
        w.writeInt32(2); w.writeUInt32(1); w.writeUInt32(2)

        var cursor = BinaryCursor(data: w.data)
        let instance = try WorldPlacementParser.parseInstance(&cursor, recordID: 1)

        let reEncoded = WorldPlacementWriter.writeInstance(instance)
        XCTAssertEqual(reEncoded, w.data, "re-encoding an unmodified parse must reproduce the original bytes exactly")

        var reCursor = BinaryCursor(data: reEncoded)
        let reparsed = try WorldPlacementParser.parseInstance(&reCursor, recordID: 1)
        XCTAssertEqual(reparsed.someNum1, 777)
        XCTAssertEqual(reparsed.someNum2, 888)
        XCTAssertEqual(reparsed.someNum3, 999)
        XCTAssertEqual(reparsed.childInstanceIDs, [101, 102])
        XCTAssertEqual(reparsed.childPositionIDs, [201])
        XCTAssertEqual(reparsed.childPathIDs, [301])
        XCTAssertEqual(reparsed.unknownUInt32List, [0xDEAD_BEEF])
        XCTAssertEqual(reparsed.unknownFloatList, [1.5])
        XCTAssertEqual(reparsed.unknownUInt32List2, [1, 2])
    }

    /// Adding a new element to a list must grow the record correctly and
    /// keep every later field (crucially, `objectID`/`refList`/`scriptID`
    /// which come right after the ID lists) at its new, shifted offset , 
    /// exercising `InstanceInspectorView`'s "Add" buttons through the real
    /// writer, not just a same-shape round-trip.
    func testWriteInstanceReflectsAnAddedChildID() throws {
        let original = PlacedInstance(
            id: 1, position: SIMD4<Float>(0, 0, 0, 1), rotationRaw: .zero, comRotationRaw: .zero,
            childInstanceIDs: [101], childPositionIDs: [], childPathIDs: [],
            someNum1: 10, someNum2: 10, someNum3: 10,
            objectID: 42, refList: -1, scriptID: -1, flags: 6,
            unknownUInt32List: [], unknownFloatList: [1], unknownUInt32List2: [0, 0]
        )
        var grown = original
        grown.childInstanceIDs.append(102)
        let encoded = WorldPlacementWriter.writeInstance(grown)

        var cursor = BinaryCursor(data: encoded)
        let reparsed = try WorldPlacementParser.parseInstance(&cursor, recordID: 1)
        XCTAssertEqual(reparsed.childInstanceIDs, [101, 102])
        XCTAssertEqual(reparsed.objectID, 42, "objectID must decode correctly from its new, shifted offset after the list grew")
        XCTAssertEqual(cursor.position, encoded.count, "the writer must not leave trailing/missing bytes")
    }

    /// "Instance Flags" write-back: `flagsFileOffset` must point at the
    /// real bytes (4 later than `objectIDFileOffset`, past RefList,
    /// ScriptID, and PHeader), and `writeInstanceFlags`'s 4 bytes patched
    /// there must round-trip a changed flags value while leaving every
    /// other field untouched.
    func testInstanceFlagsFileOffsetRoundTripsThroughWriter() throws {
        var w = BinaryWriter()
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeUInt16(0); w.writeUInt16(0)
        w.writeUInt16(0); w.writeUInt16(0)
        w.writeUInt16(0); w.writeUInt16(0)
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10) // childInstanceIDs, empty
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10) // childPositionIDs, empty
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10) // childPathIDs, empty
        w.writeUInt16(42) // objectID
        w.writeInt16(5)   // refList
        w.writeInt16(9)   // scriptID
        w.writeUInt32(0)  // PHeader
        w.writeUInt32(0x0000_0007) // flags: bits 0,1,2 set
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0) // three empty unknown lists

        var cursor = BinaryCursor(data: w.data)
        let instance = try WorldPlacementParser.parseInstance(&cursor, recordID: 1)

        XCTAssertEqual(instance.flags, 0x7)
        XCTAssertEqual(instance.flagsFileOffset, instance.objectIDFileOffset + 10) // objectID(2) + refList(2) + scriptID(2) + PHeader(4)

        var probe = BinaryCursor(data: w.data)
        _ = try probe.seek(to: instance.flagsFileOffset)
        XCTAssertEqual(try probe.readUInt32(), 0x7)

        var patched = w.data
        let offset = instance.flagsFileOffset
        patched.replaceSubrange(offset..<(offset + 4), with: WorldPlacementWriter.writeInstanceFlags(0x8000_0001))
        var reparseCursor = BinaryCursor(data: patched)
        let reparsed = try WorldPlacementParser.parseInstance(&reparseCursor, recordID: 1)
        XCTAssertEqual(reparsed.flags, 0x8000_0001)
        XCTAssertEqual(reparsed.objectID, 42) // untouched
        XCTAssertEqual(patched.count, w.count)
    }

    /// Zero-instance case should read exactly 80 bytes, matching
    /// `Trigger.GetSize()`'s base constant (`Trigger.cs:270`).
    /// "Gameplay Mods" (see `GameplayModCatalog`) write-back: each unknown
    /// list's captured element-0 offset must point at its real first
    /// element, and a single-element patch there must round-trip while
    /// leaving every other element (and the other two lists) untouched.
    func testInstanceUnknownListElementOffsetsRoundTripThroughWriter() throws {
        var w = BinaryWriter()
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeUInt16(0); w.writeUInt16(0)
        w.writeUInt16(0); w.writeUInt16(0)
        w.writeUInt16(0); w.writeUInt16(0)
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10)
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10)
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10)
        w.writeUInt16(42)
        w.writeInt16(-1)
        w.writeInt16(-1)
        w.writeUInt32(0)
        w.writeUInt32(0x6)
        w.writeInt32(2); w.writeUInt32(100); w.writeUInt32(200) // unknownUInt32List (UnkI321)
        w.writeInt32(3); w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3) // unknownFloatList (UnkI322)
        w.writeInt32(2); w.writeUInt32(0); w.writeUInt32(0) // unknownUInt32List2 (UnkI323)

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let instance = try WorldPlacementParser.parseInstance(&cursor, recordID: 1)

        XCTAssertEqual(instance.unknownUInt32List, [100, 200])
        XCTAssertEqual(instance.unknownFloatList, [1, 2, 3])
        XCTAssertEqual(instance.unknownUInt32List2, [0, 0])

        // Every captured offset must point at its list's real element 0.
        var probe = BinaryCursor(data: originalBytes)
        _ = try probe.seek(to: instance.unknownUInt32ListFileOffset)
        XCTAssertEqual(try probe.readUInt32(), 100)
        probe = BinaryCursor(data: originalBytes)
        _ = try probe.seek(to: instance.unknownFloatListFileOffset)
        XCTAssertEqual(try probe.readFloat32(), 1)
        probe = BinaryCursor(data: originalBytes)
        _ = try probe.seek(to: instance.unknownUInt32List2FileOffset)
        XCTAssertEqual(try probe.readUInt32(), 0)

        // Patch UnkI322[1] (index 1, the middle float) and confirm only
        // that one element changed.
        var patched = originalBytes
        let elementOffset = instance.unknownFloatListFileOffset + 1 * 4
        patched.replaceSubrange(elementOffset..<(elementOffset + 4), with: WorldPlacementWriter.writeInstanceUnknownFloatElement(72.951))
        var reparseCursor = BinaryCursor(data: patched)
        let reparsed = try WorldPlacementParser.parseInstance(&reparseCursor, recordID: 1)
        XCTAssertEqual(reparsed.unknownFloatList, [1, 72.951, 3])
        XCTAssertEqual(reparsed.unknownUInt32List, [100, 200]) // untouched
        XCTAssertEqual(reparsed.unknownUInt32List2, [0, 0]) // untouched
        XCTAssertEqual(patched.count, originalBytes.count)
    }

    func testParseTriggerConsumesExactly80BytesWithNoInstances() throws {
        var w = BinaryWriter()
        w.writeUInt32(50)   // Header
        w.writeUInt32(1)    // Enabled
        w.writeFloat32(0.3) // SomeFloat
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) // rotation quaternion
        w.writeFloat32(5); w.writeFloat32(6); w.writeFloat32(7); w.writeFloat32(1) // position
        w.writeFloat32(2); w.writeFloat32(2); w.writeFloat32(2); w.writeFloat32(1) // size
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10) // dup count, count, SectionHead
        w.writeUInt16(1); w.writeUInt16(2); w.writeUInt16(3); w.writeUInt16(4) // Arg1..4

        XCTAssertEqual(w.count, 80)

        var cursor = BinaryCursor(data: w.data)
        let trigger = try WorldPlacementParser.parseTrigger(&cursor, recordID: 9)

        XCTAssertEqual(trigger.header, 50)
        XCTAssertEqual(trigger.enabledMask, 1)
        XCTAssertEqual(trigger.someFloat, 0.3, accuracy: 0.0001)
        XCTAssertEqual(trigger.rotationQuaternion, SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(trigger.position, SIMD4<Float>(5, 6, 7, 1))
        XCTAssertEqual(trigger.size, SIMD4<Float>(2, 2, 2, 1))
        XCTAssertTrue(trigger.instanceIDs.isEmpty)
        XCTAssertEqual(trigger.sectionHead, 10)
        XCTAssertEqual(trigger.arg1, 1)
        XCTAssertEqual(trigger.arg2, 2)
        XCTAssertEqual(trigger.arg3, 3)
        XCTAssertEqual(trigger.arg4, 4)
        XCTAssertEqual(trigger.rotationAngleDegrees, 0, accuracy: 0.01)
        XCTAssertEqual(cursor.position, w.count)
    }

    /// `Trigger.SectionHead` is real, independently-loaded data (same role
    /// as `Instance.SomeNum1/2/3`), this proves the parser captures its
    /// actual on-disk value rather than silently discarding it in favor of
    /// the `= 10` default every other fixture here happens to use.
    func testParseTriggerCapturesRealSectionHeadValue() throws {
        var w = BinaryWriter()
        w.writeUInt32(50); w.writeUInt32(1); w.writeFloat32(0.3)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(5); w.writeFloat32(6); w.writeFloat32(7); w.writeFloat32(1)
        w.writeFloat32(2); w.writeFloat32(2); w.writeFloat32(2); w.writeFloat32(1)
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(7) // dup count, count, SectionHead = 7 (not the usual 10)
        w.writeUInt16(0); w.writeUInt16(0); w.writeUInt16(0); w.writeUInt16(0)

        var cursor = BinaryCursor(data: w.data)
        let trigger = try WorldPlacementParser.parseTrigger(&cursor, recordID: 9)
        XCTAssertEqual(trigger.sectionHead, 7)
    }

    /// "Make Trigger/Camera inspectors writable": `writeTriggerOrCameraPrefix`'s
    /// output, followed by whatever `parseTrigger` expects next (the
    /// variable-length tail), must parse back out to exactly the edited
    /// header/enabledMask/someFloat/rotation/position/size, proving the
    /// prefix writer's field order/widths genuinely match the parser's,
    /// not just "looks right by inspection."
    func testTriggerPrefixRoundTripsThroughWriter() throws {
        let encodedPrefix = WorldPlacementWriter.writeTriggerOrCameraPrefix(
            header: 42,
            enabledMask: 0b101,
            someFloat: 1.25,
            rotationQuaternion: SIMD4<Float>(0, 0.7071, 0, 0.7071),
            position: SIMD4<Float>(10, -20, 30, 1),
            size: SIMD4<Float>(2, 3, 4, 1)
        )
        XCTAssertEqual(encodedPrefix.count, 60)

        var w = BinaryWriter()
        w.writeBytes(encodedPrefix)
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10) // empty instanceIDs list
        w.writeUInt16(1); w.writeUInt16(2); w.writeUInt16(3); w.writeUInt16(4) // Arg1..4

        var cursor = BinaryCursor(data: w.data)
        let trigger = try WorldPlacementParser.parseTrigger(&cursor, recordID: 1)

        XCTAssertEqual(trigger.header, 42)
        XCTAssertEqual(trigger.enabledMask, 0b101)
        XCTAssertEqual(trigger.someFloat, 1.25, accuracy: 0.0001)
        XCTAssertEqual(trigger.rotationQuaternion, SIMD4<Float>(0, 0.7071, 0, 0.7071))
        XCTAssertEqual(trigger.position, SIMD4<Float>(10, -20, 30, 1))
        XCTAssertEqual(trigger.size, SIMD4<Float>(2, 3, 4, 1))
        XCTAssertEqual(cursor.position, w.count)
    }

    /// "Backend Requirement: safely inject this new record" (Part 4D)
    /// extended to Trigger, a complete `writeNewTrigger` output decodes
    /// back through the real parser to exactly the reference tool's own
    /// `new Trigger()` default field values (`Trigger.cs`'s property
    /// initializers), not just the shared 60-byte prefix.
    func testWriteNewTriggerRoundTripsThroughParserWithReferenceDefaults() throws {
        let encoded = WorldPlacementWriter.writeNewTrigger(position: SIMD4<Float>(5, 6, 7, 1))
        var cursor = BinaryCursor(data: encoded)
        let trigger = try WorldPlacementParser.parseTrigger(&cursor, recordID: 42)

        XCTAssertEqual(trigger.header, 50)
        XCTAssertEqual(trigger.enabledMask, 1)
        XCTAssertEqual(trigger.someFloat, 0.3, accuracy: 0.0001)
        XCTAssertEqual(trigger.rotationQuaternion, SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(trigger.position, SIMD4<Float>(5, 6, 7, 1))
        XCTAssertEqual(trigger.size, SIMD4<Float>(1, 1, 1, 1))
        XCTAssertTrue(trigger.instanceIDs.isEmpty)
        XCTAssertEqual(trigger.arg1, 0)
        XCTAssertEqual(trigger.arg2, 0)
        XCTAssertEqual(trigger.arg3, 0)
        XCTAssertEqual(trigger.arg4, 0)
        XCTAssertEqual(cursor.position, encoded.count)
    }

    func testParseTriggerWithInstances() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeUInt32(0b111)
        w.writeFloat32(0)
        // 180-degree rotation about an arbitrary axis: w == cos(90°) == 0.
        w.writeFloat32(1); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(1); w.writeFloat32(1); w.writeFloat32(1); w.writeFloat32(1)
        w.writeInt32(3); w.writeInt32(3); w.writeUInt32(10)
        w.writeUInt16(11); w.writeUInt16(22); w.writeUInt16(33)
        w.writeUInt16(0); w.writeUInt16(0); w.writeUInt16(0); w.writeUInt16(0)

        var cursor = BinaryCursor(data: w.data)
        let trigger = try WorldPlacementParser.parseTrigger(&cursor, recordID: 2)

        XCTAssertEqual(trigger.instanceIDs, [11, 22, 33])
        XCTAssertEqual(trigger.rotationAngleDegrees, 180, accuracy: 0.01)
        XCTAssertEqual(cursor.position, w.count)
    }

    /// "Trigger Arguments" write-back: `argsFileOffset` must point at the
    /// real bytes right after the (real, 3-element) `instanceIDs` list,
    /// and `writeTriggerArguments`'s 8 bytes patched there must round-trip
    /// changed values while leaving the rest of the record untouched.
    func testTriggerArgsFileOffsetRoundTripsThroughWriter() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeUInt32(0b111)
        w.writeFloat32(0)
        w.writeFloat32(1); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(1); w.writeFloat32(1); w.writeFloat32(1); w.writeFloat32(1)
        w.writeInt32(3); w.writeInt32(3); w.writeUInt32(10)
        w.writeUInt16(11); w.writeUInt16(22); w.writeUInt16(33)
        w.writeUInt16(1); w.writeUInt16(2); w.writeUInt16(3); w.writeUInt16(4)

        var cursor = BinaryCursor(data: w.data)
        let trigger = try WorldPlacementParser.parseTrigger(&cursor, recordID: 2)
        XCTAssertEqual(trigger.arg1, 1)
        XCTAssertEqual(trigger.arg2, 2)
        XCTAssertEqual(trigger.arg3, 3)
        XCTAssertEqual(trigger.arg4, 4)

        var probe = BinaryCursor(data: w.data)
        _ = try probe.seek(to: trigger.argsFileOffset)
        XCTAssertEqual(try probe.readUInt16(), 1)

        var patched = w.data
        let offset = trigger.argsFileOffset
        patched.replaceSubrange(offset..<(offset + 8), with: WorldPlacementWriter.writeTriggerArguments(100, 200, 300, 400))
        var reparseCursor = BinaryCursor(data: patched)
        let reparsed = try WorldPlacementParser.parseTrigger(&reparseCursor, recordID: 2)
        XCTAssertEqual(reparsed.arg1, 100)
        XCTAssertEqual(reparsed.arg2, 200)
        XCTAssertEqual(reparsed.arg3, 300)
        XCTAssertEqual(reparsed.arg4, 400)
        XCTAssertEqual(reparsed.instanceIDs, [11, 22, 33]) // untouched
        XCTAssertEqual(patched.count, w.count)
    }

    /// Empty-instances, non-Demo, both slots `.none` (3) case should read
    /// exactly 187 bytes, independently cross-checked by hand against
    /// `Camera.GetSize()`'s formula (`Camera.cs:723-803`), which the
    /// reference tool's *write* path derives with no relation to how this
    /// read path was transcribed.
    func testParseCameraNoneSlotsConsumesExactly187BytesNonDemo() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)   // Header
        w.writeUInt32(1)   // Enabled
        w.writeFloat32(0.3) // SomeFloat
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) } // Coords
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10) // dup count, count, SectionHead
        w.writeUInt32(0xCAFE) // CamHeader
        w.writeUInt16(7)      // UnkShort (non-Demo)
        w.writeFloat32(1)     // UnkFloat1
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) // UnkCoords1
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) // UnkCoords2
        w.writeFloat32(0); w.writeFloat32(0) // UnkFloat2, UnkFloat3
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0) // UnkUInt1..4
        w.writeInt32(0); w.writeInt32(0) // UnkInt5, UnkInt6
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0) // UnkFloat4..7
        w.writeUInt32(0)  // UnkUInt7
        w.writeInt32(0)   // UnkInt8
        w.writeUInt32(0)  // UnkUInt9
        w.writeFloat32(0) // UnkFloat8
        w.writeUInt32(3)  // CameraType1 = none
        w.writeUInt32(3)  // CameraType2 = none
        w.writeUInt8(9)   // UnkByte (non-Demo)

        XCTAssertEqual(w.count, 187)

        var cursor = BinaryCursor(data: w.data)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 4, isDemo: false)

        XCTAssertEqual(camera.camHeader, 0xCAFE)
        XCTAssertEqual(camera.sectionHead, 10)
        XCTAssertEqual(camera.unkShort, 7)
        XCTAssertEqual(camera.unkByte, 9)
        XCTAssertEqual(camera.cameraType1, .none)
        XCTAssertEqual(camera.cameraType2, .none)
        XCTAssertNil(camera.subtype1)
        XCTAssertNil(camera.subtype2)
        XCTAssertEqual(cursor.position, w.count)
    }

    /// Same real-value capture as `testParseTriggerCapturesRealSectionHeadValue`,
    /// for `Camera.SectionHead`, `Camera` shares `Trigger`'s identical
    /// header shape, so this is the same field at the same relative offset.
    func testParseCameraCapturesRealSectionHeadValue() throws {
        var w = BinaryWriter()
        w.writeUInt32(0); w.writeUInt32(1); w.writeFloat32(0.3)
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(42) // SectionHead = 42
        w.writeUInt32(0); w.writeUInt16(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeInt32(0); w.writeUInt32(0); w.writeFloat32(0)
        w.writeUInt32(3); w.writeUInt32(3)
        w.writeUInt8(0)

        var cursor = BinaryCursor(data: w.data)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 4, isDemo: false)
        XCTAssertEqual(camera.sectionHead, 42)
    }

    /// "Parity Phase F": `PlacedCamera.fixedFieldsFileOffset` +
    /// `WorldPlacementWriter.writeCameraFixedFields`, captures the real
    /// offset of `camHeader` (right after the shared Trigger-shape prefix
    /// `writeTriggerOrCameraPrefix` already patches) and round-trips a
    /// same-size patch across the whole fixed block up to (not including)
    /// `cameraType1`, leaving that and the sub-payload untouched.
    func testCameraFixedFieldsOffsetRoundTripsThroughWriter() throws {
        var w = BinaryWriter()
        w.writeUInt32(0); w.writeUInt32(1); w.writeFloat32(0.3)
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10)
        w.writeUInt32(0xCAFE) // CamHeader
        w.writeUInt16(7)      // UnkShort
        w.writeFloat32(1)     // UnkFloat1
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeInt32(0); w.writeUInt32(0); w.writeFloat32(0)
        w.writeUInt32(3); w.writeUInt32(3) // CameraType1/2 = none
        w.writeUInt8(9) // UnkByte

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 20, isDemo: false)

        var probe = BinaryCursor(data: originalBytes)
        _ = try probe.seek(to: camera.fixedFieldsFileOffset)
        XCTAssertEqual(try probe.readUInt32(), 0xCAFE)

        var edited = camera
        edited.camHeader = 0xBEEF
        edited.unkFloat1 = 42.5
        edited.unkUInt7 = 99
        let encoded = WorldPlacementWriter.writeCameraFixedFields(edited, isDemo: false)

        var patched = originalBytes
        let offset = camera.fixedFieldsFileOffset
        patched.replaceSubrange(offset..<(offset + encoded.count), with: encoded)
        var reparseCursor = BinaryCursor(data: patched)
        let reparsed = try WorldPlacementParser.parseCamera(&reparseCursor, recordID: 20, isDemo: false)

        XCTAssertEqual(reparsed.camHeader, 0xBEEF)
        XCTAssertEqual(reparsed.unkFloat1, 42.5)
        XCTAssertEqual(reparsed.unkUInt7, 99)
        XCTAssertEqual(reparsed.cameraType1, .none, "the field right after the patched block must be untouched")
        XCTAssertEqual(reparsed.unkByte, 9, "the field at the very end must be untouched")
        XCTAssertEqual(patched.count, originalBytes.count)
    }

    func testParseCameraDemoOmitsUnkShortAndUnkByte() throws {
        var w = BinaryWriter()
        w.writeUInt32(0); w.writeUInt32(1); w.writeFloat32(0.3)
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10)
        w.writeUInt32(0) // CamHeader
        // No UnkShort for Demo.
        w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeInt32(0); w.writeUInt32(0); w.writeFloat32(0)
        w.writeUInt32(3); w.writeUInt32(3)
        // No UnkByte for Demo.

        var cursor = BinaryCursor(data: w.data)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 1, isDemo: true)

        XCTAssertNil(camera.unkShort)
        XCTAssertNil(camera.unkByte)
        XCTAssertEqual(cursor.position, w.count)
    }

    /// "Backend Requirement: safely inject this new record" (Part 4D)
    /// extended to Camera, a complete `writeNewCamera` output decodes back
    /// through the real parser to exactly `Camera.cs`'s own `new Camera()`
    /// default field values, both slots reading back as `.none` (so no
    /// polymorphic sub-payload is ever touched), non-Demo variant.
    func testWriteNewCameraRoundTripsThroughParserWithReferenceDefaults() throws {
        let encoded = WorldPlacementWriter.writeNewCamera(position: SIMD4<Float>(1, 2, 3, 1), isDemo: false)
        var cursor = BinaryCursor(data: encoded)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 7, isDemo: false)

        XCTAssertEqual(camera.header, 1_310_720)
        XCTAssertEqual(camera.enabledMask, 1)
        XCTAssertEqual(camera.someFloat, 0.3, accuracy: 0.0001)
        XCTAssertEqual(camera.rotationQuaternion, SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(camera.position, SIMD4<Float>(1, 2, 3, 1))
        XCTAssertEqual(camera.size, SIMD4<Float>(1, 1, 1, 1))
        XCTAssertTrue(camera.instanceIDs.isEmpty)
        XCTAssertEqual(camera.camHeader, 0)
        XCTAssertEqual(camera.unkShort, 0)
        XCTAssertEqual(camera.unkFloat1, 1)
        XCTAssertEqual(camera.unkCoords1, SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(camera.unkCoords2, SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(camera.unkByte, 0)
        XCTAssertEqual(camera.cameraType1, .none)
        XCTAssertEqual(camera.cameraType2, .none)
        XCTAssertNil(camera.subtype1)
        XCTAssertNil(camera.subtype2)
        XCTAssertEqual(cursor.position, encoded.count)
    }

    /// Same as above, Demo variant, confirms `writeNewCamera(isDemo: true)`
    /// correctly omits `UnkShort`/`UnkByte` the same way `Camera.cs`'s own
    /// `Save` does under `ParentType == SectionType.CameraDemo`.
    func testWriteNewCameraDemoOmitsUnkShortAndUnkByte() throws {
        let encoded = WorldPlacementWriter.writeNewCamera(position: .zero, isDemo: true)
        var cursor = BinaryCursor(data: encoded)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 8, isDemo: true)

        XCTAssertNil(camera.unkShort)
        XCTAssertNil(camera.unkByte)
        XCTAssertEqual(camera.cameraType1, .none)
        XCTAssertEqual(cursor.position, encoded.count)
    }

    /// Point (0x1C02) is the simplest sub-camera with an actual payload , 
    /// a good spot-check that slot dispatch and trailing-field parsing work.
    func testParseCameraWithPointSubtype() throws {
        var w = BinaryWriter()
        w.writeUInt32(0); w.writeUInt32(1); w.writeFloat32(0.3)
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10)
        w.writeUInt32(0)
        w.writeUInt16(0)
        w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeInt32(0); w.writeUInt32(0); w.writeFloat32(0)
        w.writeUInt32(0x1C02) // CameraType1 = point
        w.writeUInt32(3)      // CameraType2 = none
        w.writeUInt8(0)
        // Point payload:
        w.writeUInt32(99)
        w.writeFloat32(1.5)
        w.writeFloat32(2.5)
        w.writeFloat32(10); w.writeFloat32(20); w.writeFloat32(30); w.writeFloat32(1)

        var cursor = BinaryCursor(data: w.data)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 2, isDemo: false)

        XCTAssertEqual(camera.cameraType1, .point)
        guard case .point(let point) = camera.subtype1 else {
            return XCTFail("Expected a .point subtype")
        }
        XCTAssertEqual(point.unkInt, 99)
        XCTAssertEqual(point.unkFloat1, 1.5, accuracy: 0.0001)
        XCTAssertEqual(point.unkVector, SIMD4<Float>(10, 20, 30, 1))
        XCTAssertNil(camera.subtype2)
        XCTAssertEqual(cursor.position, w.count)
    }

    /// "Spline & Camera Path Persistence" (roadmap 6.3), the real
    /// correctness guarantee the write path depends on: each control
    /// point's `controlPointFileOffsets[i]` must point at the exact byte
    /// offset `WorldPlacementParser` itself read that vector from, so that
    /// patching `WorldPlacementWriter.writeCameraControlPoint`'s 16 bytes
    /// in at that offset, and nothing else, round-trips a moved control
    /// point while leaving every other byte in the record (including the
    /// *other* control point and the trailing data) untouched.
    func testCameraPathControlPointOffsetsRoundTripAWriteBack() throws {
        var w = BinaryWriter()
        w.writeUInt32(0); w.writeUInt32(1); w.writeFloat32(0.3)
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10)
        w.writeUInt32(0)
        w.writeUInt16(0)
        w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeInt32(0); w.writeUInt32(0); w.writeFloat32(0)
        w.writeUInt32(0x1C04) // CameraType1 = path
        w.writeUInt32(3)      // CameraType2 = none
        w.writeUInt8(0)
        // Path payload: unkInt, f1, f2, vectorCount=2, 2 control points, unkInt2=0 (no trailing data).
        w.writeUInt32(7)
        w.writeFloat32(1.25)
        w.writeFloat32(2.5)
        w.writeUInt32(2)
        w.writeFloat32(10); w.writeFloat32(20); w.writeFloat32(30); w.writeFloat32(1) // point 0
        w.writeFloat32(40); w.writeFloat32(50); w.writeFloat32(60); w.writeFloat32(1) // point 1
        w.writeInt32(0)

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 9, isDemo: false)

        guard case .path(let path) = camera.subtype1 else {
            return XCTFail("Expected a .path subtype")
        }
        XCTAssertEqual(path.unkVectors, [SIMD4<Float>(10, 20, 30, 1), SIMD4<Float>(40, 50, 60, 1)])
        XCTAssertEqual(path.controlPointFileOffsets.count, 2)

        // The recorded offset for point 0 must land exactly on point 0's
        // real bytes, reading a fresh Vector4 straight from the original
        // buffer at that offset must reproduce the parsed value exactly.
        for (index, offset) in path.controlPointFileOffsets.enumerated() {
            var probe = BinaryCursor(data: originalBytes)
            _ = try probe.seek(to: offset)
            XCTAssertEqual(try probe.readVector4(), path.unkVectors[index], "control point \(index) offset didn't point at its own bytes")
        }

        // Move point 0 and patch just its 16 bytes into a copy of the file.
        let movedPoint0 = SIMD4<Float>(111, 222, 333, 1)
        var patched = originalBytes
        let offset0 = path.controlPointFileOffsets[0]
        patched.replaceSubrange(offset0..<(offset0 + 16), with: WorldPlacementWriter.writeCameraControlPoint(movedPoint0))

        var reparseCursor = BinaryCursor(data: patched)
        let reparsedCamera = try WorldPlacementParser.parseCamera(&reparseCursor, recordID: 9, isDemo: false)
        guard case .path(let reparsedPath) = reparsedCamera.subtype1 else {
            return XCTFail("Expected a .path subtype after patch")
        }
        XCTAssertEqual(reparsedPath.unkVectors[0], movedPoint0)
        // Everything else, the other control point, unkInt/f1/f2, must be
        // completely untouched by a patch scoped to just one point's bytes.
        XCTAssertEqual(reparsedPath.unkVectors[1], SIMD4<Float>(40, 50, 60, 1))
        XCTAssertEqual(reparsedPath.unkInt, 7)
        XCTAssertEqual(reparsedPath.unkFloat1, 1.25, accuracy: 0.0001)
        XCTAssertEqual(patched.count, originalBytes.count)
    }

    /// The real 187-byte fixed block every `Camera` record's sub-payload
    /// sits after (non-Demo), factored out so the round-trip tests below
    /// can each supply just their own payload bytes rather than repeating
    /// this fixture 12 times.
    private func fixedCameraPrefixBytes(cameraType1: UInt32, cameraType2: UInt32 = CameraKind.none.rawValue) -> BinaryWriter {
        var w = BinaryWriter()
        w.writeUInt32(0); w.writeUInt32(1); w.writeFloat32(0.3)
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10)
        w.writeUInt32(0)
        w.writeUInt16(0)
        w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeInt32(0); w.writeUInt32(0); w.writeFloat32(0)
        w.writeUInt32(cameraType1)
        w.writeUInt32(cameraType2)
        w.writeUInt8(0)
        return w
    }

    /// `WorldPlacementWriter.writeCameraSubtype` is the inverse of
    /// `parseCameraSubtype` for every real `CameraKind` payload, this
    /// proves it byte-for-byte for all 10 payload-carrying variants that
    /// aren't already covered by `testParseCameraWithPointSubtype`/
    /// `testCameraPathControlPointOffsetsRoundTripAWriteBack`, plus that
    /// `subtype1FileOffset` genuinely points at the payload's own first
    /// byte (not just "some" offset that happens to work for `.point`).
    func testWriteCameraSubtypeRoundTripsEveryPayloadCarryingVariant() throws {
        var payload = BinaryWriter() // .boss (0xA19)
        payload.writeUInt32(11)
        payload.writeFloat32(1.5); payload.writeFloat32(2.5)
        for _ in 0..<4 { payload.writeFloat32(1); payload.writeFloat32(2); payload.writeFloat32(3); payload.writeFloat32(4) }
        for _ in 0..<4 { payload.writeFloat32(5); payload.writeFloat32(6); payload.writeFloat32(7); payload.writeFloat32(8) }
        payload.writeFloat32(9); payload.writeFloat32(10); payload.writeFloat32(11); payload.writeFloat32(12)
        payload.writeUInt8(77)
        payload.writeFloat32(3); payload.writeFloat32(4); payload.writeFloat32(5); payload.writeFloat32(6)
        payload.writeUInt8(88)
        try assertCameraSubtypeRoundTrips(type: 0xA19, payload: payload)

        var line = BinaryWriter() // .line (0x1C03)
        line.writeUInt32(3); line.writeFloat32(1); line.writeFloat32(2)
        line.writeFloat32(1); line.writeFloat32(1); line.writeFloat32(1); line.writeFloat32(1)
        line.writeFloat32(2); line.writeFloat32(2); line.writeFloat32(2); line.writeFloat32(1)
        try assertCameraSubtypeRoundTrips(type: 0x1C03, payload: line)

        let null1C05 = BinaryWriter() // .null1C05 (0x1C05), genuinely zero bytes
        try assertCameraSubtypeRoundTrips(type: 0x1C05, payload: null1C05)

        var spline = BinaryWriter() // .spline (0x1C06)
        spline.writeInt32(4); spline.writeFloat32(1); spline.writeFloat32(2)
        spline.writeUInt32(1) // segmentCount
        spline.writeFloat32(3)
        for _ in 0..<4 { spline.writeFloat32(1); spline.writeFloat32(2); spline.writeFloat32(3); spline.writeFloat32(1) } // (1+1)*2 = 4 vectors
        spline.writeBytes(Data(repeating: 0xAB, count: 8)) // segmentCount * 8 trailing bytes
        spline.writeUInt16(42)
        try assertCameraSubtypeRoundTrips(type: 0x1C06, payload: spline)

        var unused1C09 = BinaryWriter() // .unused1C09 (0x1C09)
        unused1C09.writeUInt32(5); unused1C09.writeFloat32(1); unused1C09.writeFloat32(2)
        try assertCameraSubtypeRoundTrips(type: 0x1C09, payload: unused1C09)

        var point2 = BinaryWriter() // .point2 (0x1C0B)
        point2.writeUInt32(6); point2.writeFloat32(1); point2.writeFloat32(2)
        point2.writeFloat32(1); point2.writeFloat32(2); point2.writeFloat32(3); point2.writeFloat32(1)
        point2.writeFloat32(9); point2.writeUInt8(1)
        try assertCameraSubtypeRoundTrips(type: 0x1C0B, payload: point2)

        var unused1C0C = BinaryWriter() // .unused1C0C (0x1C0C)
        unused1C0C.writeUInt8(1); unused1C0C.writeUInt8(2); unused1C0C.writeUInt8(3); unused1C0C.writeUInt8(4)
        try assertCameraSubtypeRoundTrips(type: 0x1C0C, payload: unused1C0C)

        var line2 = BinaryWriter() // .line2 (0x1C0D)
        line2.writeUInt32(7); line2.writeFloat32(1); line2.writeFloat32(2)
        line2.writeFloat32(1); line2.writeFloat32(1); line2.writeFloat32(1); line2.writeFloat32(1)
        line2.writeFloat32(2); line2.writeFloat32(2); line2.writeFloat32(2); line2.writeFloat32(1)
        line2.writeFloat32(3); line2.writeFloat32(4)
        try assertCameraSubtypeRoundTrips(type: 0x1C0D, payload: line2)

        let empty1C0E = BinaryWriter() // .empty1C0E (0x1C0E), genuinely zero bytes
        try assertCameraSubtypeRoundTrips(type: 0x1C0E, payload: empty1C0E)

        var zone = BinaryWriter() // .zone (0x1C0F)
        for _ in 0..<4 { zone.writeFloat32(1); zone.writeFloat32(2); zone.writeFloat32(3); zone.writeFloat32(1) }
        zone.writeUInt32(1); zone.writeUInt32(2); zone.writeUInt64(0xDEADBEEF)
        for _ in 0..<4 { zone.writeFloat32(4); zone.writeFloat32(5); zone.writeFloat32(6); zone.writeFloat32(1) }
        zone.writeUInt32(3); zone.writeUInt32(4); zone.writeUInt64(0xCAFEBABE)
        try assertCameraSubtypeRoundTrips(type: 0x1C0F, payload: zone)
    }

    private func assertCameraSubtypeRoundTrips(type: UInt32, payload: BinaryWriter, file: StaticString = #filePath, line: UInt = #line) throws {
        var full = fixedCameraPrefixBytes(cameraType1: type)
        full.writeBytes(payload.data)

        var cursor = BinaryCursor(data: full.data)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 1, isDemo: false)
        XCTAssertEqual(cursor.position, full.count, "parser didn't consume exactly the fixed block + payload for type 0x\(String(type, radix: 16))", file: file, line: line)

        guard let subtype1 = camera.subtype1 else {
            return XCTFail("Expected a decoded subtype1 for type 0x\(String(type, radix: 16))", file: file, line: line)
        }

        // `subtype1FileOffset` must land exactly on the payload's own first
        // byte, reproduce the payload bytes straight from the original
        // buffer at that offset, independent of `writeCameraSubtype`.
        let rangeFromOffset = full.data.subdata(in: camera.subtype1FileOffset..<full.count)
        XCTAssertEqual(rangeFromOffset, payload.data, "subtype1FileOffset didn't point at the real payload bytes for type 0x\(String(type, radix: 16))", file: file, line: line)

        let reEncoded = WorldPlacementWriter.writeCameraSubtype(subtype1)
        XCTAssertEqual(reEncoded, payload.data, "writeCameraSubtype didn't reproduce the original payload bytes for type 0x\(String(type, radix: 16))", file: file, line: line)
    }

    /// Both slots filled, `subtype2FileOffset` must land exactly where
    /// slot 1's *actual* variable-length payload ends (not some fixed
    /// guess), and patching slot 2's payload in place via
    /// `writeCameraSubtype` must leave slot 1 completely untouched. Uses
    /// `.point` (fixed 16-byte payload) for slot 1 and `.line` for slot 2
    /// so the two are distinguishable in the patched output.
    func testSubtype2FileOffsetAccountsForSubtype1AndPatchesIndependently() throws {
        var full = fixedCameraPrefixBytes(cameraType1: 0x1C02, cameraType2: 0x1C03) // point, line
        // Slot 1 payload: .point
        full.writeUInt32(1); full.writeFloat32(1); full.writeFloat32(2)
        full.writeFloat32(10); full.writeFloat32(20); full.writeFloat32(30); full.writeFloat32(1)
        // Slot 2 payload: .line
        full.writeUInt32(2); full.writeFloat32(3); full.writeFloat32(4)
        full.writeFloat32(1); full.writeFloat32(1); full.writeFloat32(1); full.writeFloat32(1)
        full.writeFloat32(2); full.writeFloat32(2); full.writeFloat32(2); full.writeFloat32(1)

        let originalBytes = full.data
        var cursor = BinaryCursor(data: originalBytes)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 1, isDemo: false)
        XCTAssertEqual(cursor.position, originalBytes.count)

        guard case .point = camera.subtype1 else { return XCTFail("Expected .point in slot 1") }
        guard case .line(let originalLine) = camera.subtype2 else { return XCTFail("Expected .line in slot 2") }
        // Slot 1 (.point) is unkInt(4) + unkFloat1(4) + unkFloat2(4) + vector(16) = 28 bytes; slot 2 must start exactly there.
        XCTAssertEqual(camera.subtype2FileOffset, camera.subtype1FileOffset + 28)

        var editedLine = originalLine
        editedLine.unkInt = 999
        var patched = originalBytes
        let encoded = WorldPlacementWriter.writeCameraSubtype(.line(editedLine))
        patched.replaceSubrange(camera.subtype2FileOffset..<(camera.subtype2FileOffset + encoded.count), with: encoded)
        XCTAssertEqual(patched.count, originalBytes.count)

        var reparseCursor = BinaryCursor(data: patched)
        let reparsed = try WorldPlacementParser.parseCamera(&reparseCursor, recordID: 1, isDemo: false)
        guard case .point(let point) = reparsed.subtype1 else { return XCTFail("Expected .point in slot 1 after patch") }
        XCTAssertEqual(point.unkInt, 1, "slot 1 must be untouched by a patch scoped to slot 2")
        guard case .line(let line) = reparsed.subtype2 else { return XCTFail("Expected .line in slot 2 after patch") }
        XCTAssertEqual(line.unkInt, 999)
    }

    func testParseCameraUnknownSubtypeThrows() throws {
        var w = BinaryWriter()
        w.writeUInt32(0); w.writeUInt32(1); w.writeFloat32(0.3)
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10)
        w.writeUInt32(0)
        w.writeUInt16(0)
        w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeInt32(0); w.writeUInt32(0); w.writeFloat32(0)
        w.writeUInt32(0xDEAD) // unrecognized type code
        w.writeUInt32(3)
        w.writeUInt8(0)

        var cursor = BinaryCursor(data: w.data)
        XCTAssertThrowsError(try WorldPlacementParser.parseCamera(&cursor, recordID: 3, isDemo: false)) { error in
            guard case WorldPlacementParserError.unknownCameraSubtype(let type) = error else {
                return XCTFail("Expected .unknownCameraSubtype, got \(error)")
            }
            XCTAssertEqual(type, 0xDEAD)
        }
    }
}
