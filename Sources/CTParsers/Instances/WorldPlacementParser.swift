import Foundation
import CTCore
import CTModels

/// Thrown for a `Camera` sub-payload type code this package doesn't
/// recognize, `Camera.ReadCamera`'s reference-tool equivalent throws
/// `NotImplementedException` in the same situation, so this mirrors that
/// rather than guessing at an unknown layout.
public enum WorldPlacementParserError: Error, CustomStringConvertible {
    case unknownCameraSubtype(UInt32)

    public var description: String {
        switch self {
        case .unknownCameraSubtype(let type):
            return "Unrecognized Camera sub-payload type 0x\(String(type, radix: 16))."
        }
    }
}

/// Decodes `Position`/`Instance`/`Trigger`/`Camera` leaf records, the
/// `Instance` container's sub-ID-3/6/7/8 collections (see
/// `RM2Parser.tier1ChildType`). Ported 1:1 (including on-disk redundant
/// count fields and `Camera`'s polymorphic sub-payloads) from
/// `Twinsanity/Items/Instances/{Position,Instance,Trigger,Camera}.cs`.
public enum WorldPlacementParser {
    public static func parsePosition(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> PositionMarker {
        PositionMarker(id: recordID, point: try cursor.readVector4())
    }

    public static func parseInstance(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> PlacedInstance {
        let position = try cursor.readVector4()
        let rotX = try cursor.readUInt16()
        let comRotX = try cursor.readUInt16()
        let rotY = try cursor.readUInt16()
        let comRotY = try cursor.readUInt16()
        let rotZ = try cursor.readUInt16()
        let comRotZ = try cursor.readUInt16()

        let (childInstanceIDs, someNum1) = try readCountedUInt16List(&cursor)
        let (childPositionIDs, someNum2) = try readCountedUInt16List(&cursor)
        let (childPathIDs, someNum3) = try readCountedUInt16List(&cursor)

        let objectIDFileOffset = cursor.position
        let objectID = try cursor.readUInt16()
        let refList = try cursor.readInt16()
        let scriptID = try cursor.readInt16()
        _ = try cursor.readUInt32() // PHeader, redundant packed count of the three unknown lists below, recomputed on save
        let flagsFileOffset = cursor.position
        let flags = try cursor.readUInt32()

        // Each list is a single `int32` count immediately followed by its
        // elements (unlike the triple-`int32`-prefixed ID lists above), so
        // the element-0 offset is exactly 4 bytes past where the list read
        // starts, captured here, once, rather than re-deriving it from
        // `cursor.position` after the fact.
        let unknownUInt32ListFileOffset = cursor.position + 4
        let unknownUInt32List = try readUInt32List(&cursor)
        let unknownFloatListFileOffset = cursor.position + 4
        let unknownFloatList = try readFloatList(&cursor)
        let unknownUInt32List2FileOffset = cursor.position + 4
        let unknownUInt32List2 = try readUInt32List(&cursor)

        return PlacedInstance(
            id: recordID,
            position: position,
            rotationRaw: SIMD3(rotX, rotY, rotZ),
            comRotationRaw: SIMD3(comRotX, comRotY, comRotZ),
            childInstanceIDs: childInstanceIDs,
            childPositionIDs: childPositionIDs,
            childPathIDs: childPathIDs,
            someNum1: someNum1,
            someNum2: someNum2,
            someNum3: someNum3,
            objectID: objectID,
            refList: refList,
            scriptID: scriptID,
            flags: flags,
            unknownUInt32List: unknownUInt32List,
            unknownFloatList: unknownFloatList,
            unknownUInt32List2: unknownUInt32List2,
            objectIDFileOffset: objectIDFileOffset,
            flagsFileOffset: flagsFileOffset,
            unknownUInt32ListFileOffset: unknownUInt32ListFileOffset,
            unknownFloatListFileOffset: unknownFloatListFileOffset,
            unknownUInt32List2FileOffset: unknownUInt32List2FileOffset
        )
    }

    public static func parseTrigger(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> TriggerVolume {
        let header = try cursor.readUInt32()
        let enabledMask = try cursor.readUInt32()
        let someFloat = try cursor.readFloat32()
        let rotationQuaternion = try cursor.readVector4()
        let position = try cursor.readVector4()
        let size = try cursor.readVector4()

        // `Trigger.SectionHead`, the same real, independent third field
        // `Instance.SomeNum1/2/3` is (see that property's own doc comment) , 
        // captured into `TriggerVolume.sectionHead` so a full round-trip
        // (once one exists) has real saved data to write back rather than
        // a rediscovered default.
        let (instanceIDs, sectionHead) = try readCountedUInt16List(&cursor)

        let argsFileOffset = cursor.position
        let arg1 = try cursor.readUInt16()
        let arg2 = try cursor.readUInt16()
        let arg3 = try cursor.readUInt16()
        let arg4 = try cursor.readUInt16()

        return TriggerVolume(
            id: recordID,
            header: header,
            enabledMask: enabledMask,
            someFloat: someFloat,
            rotationQuaternion: rotationQuaternion,
            position: position,
            size: size,
            instanceIDs: instanceIDs,
            sectionHead: sectionHead,
            arg1: arg1,
            arg2: arg2,
            arg3: arg3,
            arg4: arg4,
            argsFileOffset: argsFileOffset
        )
    }

    /// `isDemo`: whether this record was found under `.cameraDemo` rather
    /// than `.camera`, the Demo layout omits `UnkShort` and `UnkByte`
    /// entirely (`Camera.cs`'s `ParentType != SectionType.CameraDemo`
    /// guards on `Save`/`Load`).
    public static func parseCamera(_ cursor: inout BinaryCursor, recordID: UInt32, isDemo: Bool) throws -> PlacedCamera {
        let header = try cursor.readUInt32()
        let enabledMask = try cursor.readUInt32()
        let someFloat = try cursor.readFloat32()
        let rotationQuaternion = try cursor.readVector4()
        let position = try cursor.readVector4()
        let size = try cursor.readVector4()
        // Same `SectionHead` capture as `parseTrigger`'s own `instanceIDs`
        // above, `Camera` shares `Trigger`'s identical header shape.
        let (instanceIDs, sectionHead) = try readCountedUInt16List(&cursor)

        let fixedFieldsFileOffset = cursor.position
        let camHeader = try cursor.readUInt32()
        let unkShort: UInt16? = isDemo ? nil : try cursor.readUInt16()
        let unkFloat1 = try cursor.readFloat32()
        let unkCoords1 = try cursor.readVector4()
        let unkCoords2 = try cursor.readVector4()
        let unkFloat2 = try cursor.readFloat32()
        let unkFloat3 = try cursor.readFloat32()
        let unkUInt1 = try cursor.readUInt32()
        let unkUInt2 = try cursor.readUInt32()
        let unkUInt3 = try cursor.readUInt32()
        let unkUInt4 = try cursor.readUInt32()
        let unkInt5 = try cursor.readInt32()
        let unkInt6 = try cursor.readInt32()
        let unkFloat4 = try cursor.readFloat32()
        let unkFloat5 = try cursor.readFloat32()
        let unkFloat6 = try cursor.readFloat32()
        let unkFloat7 = try cursor.readFloat32()
        let unkUInt7 = try cursor.readUInt32()
        let unkInt8 = try cursor.readInt32()
        let unkUInt9 = try cursor.readUInt32()
        let unkFloat8 = try cursor.readFloat32()
        let cameraType1Raw = try cursor.readUInt32()
        let cameraType2Raw = try cursor.readUInt32()
        let unkByte: UInt8? = isDemo ? nil : try cursor.readUInt8()

        let subtype1FileOffset = cursor.position
        let subtype1 = cameraType1Raw != CameraKind.none.rawValue ? try parseCameraSubtype(&cursor, type: cameraType1Raw) : nil
        let subtype2FileOffset = cursor.position
        let subtype2 = cameraType2Raw != CameraKind.none.rawValue ? try parseCameraSubtype(&cursor, type: cameraType2Raw) : nil

        return PlacedCamera(
            id: recordID,
            header: header,
            enabledMask: enabledMask,
            someFloat: someFloat,
            rotationQuaternion: rotationQuaternion,
            position: position,
            size: size,
            instanceIDs: instanceIDs,
            sectionHead: sectionHead,
            camHeader: camHeader,
            unkShort: unkShort,
            unkFloat1: unkFloat1,
            unkCoords1: unkCoords1,
            unkCoords2: unkCoords2,
            unkFloat2: unkFloat2,
            unkFloat3: unkFloat3,
            unkUInt1: unkUInt1,
            unkUInt2: unkUInt2,
            unkUInt3: unkUInt3,
            unkUInt4: unkUInt4,
            unkInt5: unkInt5,
            unkInt6: unkInt6,
            unkFloat4: unkFloat4,
            unkFloat5: unkFloat5,
            unkFloat6: unkFloat6,
            unkFloat7: unkFloat7,
            unkUInt7: unkUInt7,
            unkInt8: unkInt8,
            unkUInt9: unkUInt9,
            unkFloat8: unkFloat8,
            cameraType1: CameraKind(rawValue: cameraType1Raw) ?? .none,
            cameraType2: CameraKind(rawValue: cameraType2Raw) ?? .none,
            unkByte: unkByte,
            subtype1: subtype1,
            subtype2: subtype2,
            fixedFieldsFileOffset: fixedFieldsFileOffset,
            subtype1FileOffset: subtype1FileOffset,
            subtype2FileOffset: subtype2FileOffset
        )
    }

    /// Ported from `Camera.ReadCamera` (`Camera.cs:367-535`).
    private static func parseCameraSubtype(_ cursor: inout BinaryCursor, type: UInt32) throws -> CameraSubtype {
        switch type {
        case 0xA19:
            let unkInt = try cursor.readUInt32()
            let unkFloat1 = try cursor.readFloat32()
            let unkFloat2 = try cursor.readFloat32()
            var matrix1: [SIMD4<Float>] = []
            for _ in 0..<4 { matrix1.append(try cursor.readVector4()) }
            var matrix2: [SIMD4<Float>] = []
            for _ in 0..<4 { matrix2.append(try cursor.readVector4()) }
            let vector = try cursor.readVector4()
            let byte1 = try cursor.readUInt8()
            let f3 = try cursor.readFloat32()
            let f4 = try cursor.readFloat32()
            let f5 = try cursor.readFloat32()
            let f6 = try cursor.readFloat32()
            let byte2 = try cursor.readUInt8()
            return .boss(CameraBoss(unkInt: unkInt, unkFloat1: unkFloat1, unkFloat2: unkFloat2, unkMatrix1: matrix1, unkMatrix2: matrix2, unkVector: vector, unkByte1: byte1, unkFloat3: f3, unkFloat4: f4, unkFloat5: f5, unkFloat6: f6, unkByte2: byte2))

        case 0x1C02:
            let unkInt = try cursor.readUInt32()
            let f1 = try cursor.readFloat32()
            let f2 = try cursor.readFloat32()
            let v = try cursor.readVector4()
            return .point(CameraPoint(unkInt: unkInt, unkFloat1: f1, unkFloat2: f2, unkVector: v))

        case 0x1C03:
            let unkInt = try cursor.readUInt32()
            let f1 = try cursor.readFloat32()
            let f2 = try cursor.readFloat32()
            let bb1 = try cursor.readVector4()
            let bb2 = try cursor.readVector4()
            return .line(CameraLine(unkInt: unkInt, unkFloat1: f1, unkFloat2: f2, boundingBoxVector1: bb1, boundingBoxVector2: bb2))

        case 0x1C04:
            let unkInt = try cursor.readUInt32()
            let f1 = try cursor.readFloat32()
            let f2 = try cursor.readFloat32()
            let vectorCount = try cursor.readUInt32()
            var vectors: [SIMD4<Float>] = []
            var offsets: [Int] = []
            for _ in 0..<vectorCount {
                offsets.append(cursor.position)
                vectors.append(try cursor.readVector4())
            }
            let unkInt2 = try cursor.readInt32()
            let trailing = try cursor.readBytes(max(0, Int(unkInt2)) * 8)
            return .path(CameraPath(unkInt: unkInt, unkFloat1: f1, unkFloat2: f2, unkVectors: vectors, trailingData: trailing, controlPointFileOffsets: offsets))

        case 0x1C05:
            return .null1C05

        case 0x1C06:
            let unkInt = try cursor.readInt32()
            let f1 = try cursor.readFloat32()
            let f2 = try cursor.readFloat32()
            let segCount = try cursor.readUInt32()
            let f3 = try cursor.readFloat32()
            var vectors: [SIMD4<Float>] = []
            var offsets: [Int] = []
            // Real bug fix: `segCount` is a real `UInt32` read straight
            // from an untrusted record -- `(segCount + 1) * 2` traps on
            // Swift integer overflow near `UInt32.max`, and a trap isn't a
            // thrown error, so `RM2Parser`'s own "corrupt record degrades
            // to raw/hex, doesn't take down the app" fallback can't catch
            // it. Every other count in this file is widened to `Int`
            // first; this one was missed.
            for _ in 0..<((Int(segCount) + 1) * 2) {
                offsets.append(cursor.position)
                vectors.append(try cursor.readVector4())
            }
            let trailing = try cursor.readBytes(Int(segCount) * 8)
            let unkShort = try cursor.readUInt16()
            return .spline(CameraSpline(unkInt: unkInt, unkFloat1: f1, unkFloat2: f2, segmentCount: segCount, unkFloat3: f3, unkVectors: vectors, trailingData: trailing, unkShort: unkShort, controlPointFileOffsets: offsets))

        case 0x1C09:
            let unkInt = try cursor.readUInt32()
            let f1 = try cursor.readFloat32()
            let f2 = try cursor.readFloat32()
            return .unused1C09(CameraMinor(unkInt: unkInt, unkFloat1: f1, unkFloat2: f2))

        case 0x1C0B:
            let unkInt = try cursor.readUInt32()
            let f1 = try cursor.readFloat32()
            let f2 = try cursor.readFloat32()
            let v = try cursor.readVector4()
            let f3 = try cursor.readFloat32()
            let b = try cursor.readUInt8()
            return .point2(CameraPoint2(unkInt: unkInt, unkFloat1: f1, unkFloat2: f2, unkVector: v, unkFloat3: f3, unkByte: b))

        case 0x1C0C:
            let b1 = try cursor.readUInt8()
            let b2 = try cursor.readUInt8()
            let b3 = try cursor.readUInt8()
            let b4 = try cursor.readUInt8()
            return .unused1C0C(CameraFourBytes(byte1: b1, byte2: b2, byte3: b3, byte4: b4))

        case 0x1C0D:
            let unkInt = try cursor.readUInt32()
            let f1 = try cursor.readFloat32()
            let f2 = try cursor.readFloat32()
            let bb1 = try cursor.readVector4()
            let bb2 = try cursor.readVector4()
            let f3 = try cursor.readFloat32()
            let f4 = try cursor.readFloat32()
            return .line2(CameraLine2(unkInt: unkInt, unkFloat1: f1, unkFloat2: f2, boundingBoxVector1: bb1, boundingBoxVector2: bb2, unkFloat3: f3, unkFloat4: f4))

        case 0x1C0E:
            return .empty1C0E

        case 0x1C0F:
            var d1v: [SIMD4<Float>] = []
            for _ in 0..<4 { d1v.append(try cursor.readVector4()) }
            let d1i1 = try cursor.readUInt32()
            let d1i2 = try cursor.readUInt32()
            let d1pad = try cursor.readUInt64()
            var d2v: [SIMD4<Float>] = []
            for _ in 0..<4 { d2v.append(try cursor.readVector4()) }
            let d2i1 = try cursor.readUInt32()
            let d2i2 = try cursor.readUInt32()
            let d2pad = try cursor.readUInt64()
            return .zone(CameraZone(data1Vectors: d1v, data1UnkInt1: d1i1, data1UnkInt2: d1i2, data1Padding: d1pad, data2Vectors: d2v, data2UnkInt1: d2i1, data2UnkInt2: d2i2, data2Padding: d2pad))

        default:
            throw WorldPlacementParserError.unknownCameraSubtype(type)
        }
    }

    /// Reads an ID list in the shape shared by `Instance`'s three lists and
    /// `Trigger`'s single list: `int32 count` written twice back-to-back
    /// (the reference tool reads both but only keeps the second), then one
    /// more `int32` field ("SomeNum" on `Instance`, "SectionHead" on
    /// `Trigger`, same byte layout, different label), then `count` `uint16`s.
    /// Returns the decoded values *and* the real `SomeNum`/`SectionHead`
    /// `int32` (`Instance.SomeNum1`/`2`/`3` in the reference), genuinely
    /// independent, saved data, not derived from the list's own count.
    /// `WorldPlacementWriter.writeInstance` needs it back verbatim to
    /// round-trip a full record safely.
    private static func readCountedUInt16List(_ cursor: inout BinaryCursor) throws -> (values: [UInt16], someNum: Int32) {
        _ = try cursor.readInt32() // duplicate count
        let count = try cursor.readInt32()
        let someNum = try cursor.readInt32()
        var values: [UInt16] = []
        values.reserveCapacity(cursor.safeReserveCount(count, elementSize: 2))
        for _ in 0..<max(0, count) {
            values.append(try cursor.readUInt16())
        }
        return (values, someNum)
    }

    private static func readUInt32List(_ cursor: inout BinaryCursor) throws -> [UInt32] {
        let count = try cursor.readInt32()
        var values: [UInt32] = []
        values.reserveCapacity(cursor.safeReserveCount(count, elementSize: 4))
        for _ in 0..<max(0, count) {
            values.append(try cursor.readUInt32())
        }
        return values
    }

    private static func readFloatList(_ cursor: inout BinaryCursor) throws -> [Float] {
        let count = try cursor.readInt32()
        var values: [Float] = []
        values.reserveCapacity(cursor.safeReserveCount(count, elementSize: 4))
        for _ in 0..<max(0, count) {
            values.append(try cursor.readFloat32())
        }
        return values
    }

    /// Decodes an `InstanceTemplate` record, ported field-for-field from
    /// `Twinsanity/Items/Instances/InstanceTemplate.cs`.
    public static func parseInstanceTemplate(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> InstanceTemplateInfo {
        let nameLen = Int(try cursor.readUInt32())
        let name = try cursor.readASCIIString(length: nameLen)
        let objectID = try cursor.readUInt16()
        let bitfield = try cursor.readUInt16()
        let headerInt1 = try cursor.readUInt32()
        let headerInt2 = try cursor.readUInt32()
        let headerInt3 = try cursor.readUInt32()
        let unkShort: UInt16? = headerInt1 == 1 ? try cursor.readUInt16() : nil
        let unkFlags = Array(try cursor.readBytes(6))
        let properties = try cursor.readUInt32()
        let flags = try readUInt32List(&cursor)
        let floats = try readFloatList(&cursor)
        let ints = try readUInt32List(&cursor)
        return InstanceTemplateInfo(
            id: recordID, name: name, objectID: objectID, bitfield: bitfield,
            headerInt1: headerInt1, headerInt2: headerInt2, headerInt3: headerInt3, unkShort: unkShort,
            unkFlags: unkFlags, properties: properties, flags: flags, floats: floats, ints: ints
        )
    }

    /// Decodes an `InstanceTemplateDemo` record, ported field-for-field
    /// from `Twinsanity/Items/Instances/InstanceTemplateDemo.cs`. Same
    /// shape as retail except a 2-byte (not 6-byte) `unkFlags`, and the
    /// three trailing lists share one packed byte-count header instead of
    /// each carrying its own `Int32` count.
    public static func parseInstanceTemplateDemo(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> InstanceTemplateDemoInfo {
        let nameLen = Int(try cursor.readUInt32())
        let name = try cursor.readASCIIString(length: nameLen)
        let objectID = try cursor.readUInt16()
        let bitfield = try cursor.readUInt16()
        let headerInt1 = try cursor.readUInt32()
        let headerInt2 = try cursor.readUInt32()
        let headerInt3 = try cursor.readUInt32()
        let unkShort: UInt16? = headerInt1 == 1 ? try cursor.readUInt16() : nil
        let unkFlags = Array(try cursor.readBytes(2))
        let flagsCount = try cursor.readUInt8()
        let floatsCount = try cursor.readUInt8()
        let intsCount = try cursor.readUInt8()
        _ = try cursor.readUInt8() // padding
        let properties = try cursor.readUInt32()
        var flags: [UInt32] = []
        for _ in 0..<flagsCount { flags.append(try cursor.readUInt32()) }
        var floats: [Float] = []
        for _ in 0..<floatsCount { floats.append(try cursor.readFloat32()) }
        var ints: [UInt32] = []
        for _ in 0..<intsCount { ints.append(try cursor.readUInt32()) }
        return InstanceTemplateDemoInfo(
            id: recordID, name: name, objectID: objectID, bitfield: bitfield,
            headerInt1: headerInt1, headerInt2: headerInt2, headerInt3: headerInt3, unkShort: unkShort,
            unkFlags: unkFlags, properties: properties, flags: flags, floats: floats, ints: ints
        )
    }

    /// Decodes the Demo build's `Instance` record, same transform/child-
    /// ID-list header as retail (`parseInstance`), then a real layout
    /// difference ported from `Twinsanity/Items/Instances/InstanceDemo.cs`:
    /// `refList`/`scriptID` collapse into one `afterObjectID`, and the
    /// three trailing lists share one packed byte-count header.
    public static func parseInstanceDemo(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> PlacedInstanceDemo {
        let position = try cursor.readVector4()
        let rotX = try cursor.readUInt16()
        let comRotX = try cursor.readUInt16()
        let rotY = try cursor.readUInt16()
        let comRotY = try cursor.readUInt16()
        let rotZ = try cursor.readUInt16()
        let comRotZ = try cursor.readUInt16()

        let (childInstanceIDs, someNum1) = try readCountedUInt16List(&cursor)
        let (childPositionIDs, someNum2) = try readCountedUInt16List(&cursor)
        let (childPathIDs, someNum3) = try readCountedUInt16List(&cursor)

        let objectID = try cursor.readUInt16()
        let afterObjectID = try cursor.readUInt32()

        let flagsCount = try cursor.readUInt8()
        let floatsCount = try cursor.readUInt8()
        let intsCount = try cursor.readUInt8()
        _ = try cursor.readUInt8() // padding
        let flags = try cursor.readUInt32()
        var unknownUInt32List: [UInt32] = []
        for _ in 0..<flagsCount { unknownUInt32List.append(try cursor.readUInt32()) }
        var unknownFloatList: [Float] = []
        for _ in 0..<floatsCount { unknownFloatList.append(try cursor.readFloat32()) }
        var unknownUInt32List2: [UInt32] = []
        for _ in 0..<intsCount { unknownUInt32List2.append(try cursor.readUInt32()) }

        return PlacedInstanceDemo(
            id: recordID, position: position, rotationRaw: SIMD3(rotX, rotY, rotZ), comRotationRaw: SIMD3(comRotX, comRotY, comRotZ),
            childInstanceIDs: childInstanceIDs, childPositionIDs: childPositionIDs, childPathIDs: childPathIDs,
            someNum1: someNum1, someNum2: someNum2, someNum3: someNum3,
            objectID: objectID, afterObjectID: afterObjectID, flags: flags,
            unknownUInt32List: unknownUInt32List, unknownFloatList: unknownFloatList, unknownUInt32List2: unknownUInt32List2
        )
    }

    /// Decodes the Monkey Ball build's `Instance` record, same header as
    /// retail through `scriptID`, then a genuinely opaque tail preserved
    /// verbatim for round-trip. Ported from
    /// `Twinsanity/Items/Instances/InstanceMB.cs`, whose own `Load` does
    /// the same (its attempt at decoding the tail is commented out in the
    /// reference itself, not a gap unique to this port). `size` is the
    /// record's own total byte length, needed to know how many tail bytes
    /// remain after the decoded header.
    public static func parseInstanceMB(_ cursor: inout BinaryCursor, recordID: UInt32, size: Int) throws -> PlacedInstanceMB {
        let position = try cursor.readVector4()
        let rotX = try cursor.readUInt16()
        let comRotX = try cursor.readUInt16()
        let rotY = try cursor.readUInt16()
        let comRotY = try cursor.readUInt16()
        let rotZ = try cursor.readUInt16()
        let comRotZ = try cursor.readUInt16()

        let (childInstanceIDs, someNum1) = try readCountedUInt16List(&cursor)
        let (childPositionIDs, someNum2) = try readCountedUInt16List(&cursor)
        let (childPathIDs, someNum3) = try readCountedUInt16List(&cursor)

        let objectID = try cursor.readUInt16()
        let refList = try cursor.readInt16()
        let scriptID = try cursor.readInt16()

        let remainingLength = max(0, size - cursor.position)
        let remainingTailBytes = try cursor.readBytes(remainingLength)

        return PlacedInstanceMB(
            id: recordID, position: position, rotationRaw: SIMD3(rotX, rotY, rotZ), comRotationRaw: SIMD3(comRotX, comRotY, comRotZ),
            childInstanceIDs: childInstanceIDs, childPositionIDs: childPositionIDs, childPathIDs: childPathIDs,
            someNum1: someNum1, someNum2: someNum2, someNum3: someNum3,
            objectID: objectID, refList: refList, scriptID: scriptID, remainingTailBytes: remainingTailBytes
        )
    }
}
