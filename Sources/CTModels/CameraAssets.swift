import Foundation
import simd

/// The 12 known values of `Camera.CameraType1`/`CameraType2`, ported
/// verbatim from the reference tool's `Camera.CameraType` enum
/// (`Twinsanity/Items/Instances/Camera.cs:47-62`). `.none` (3) means "this
/// camera slot is unused" and carries no sub-payload.
public enum CameraKind: UInt32, Sendable {
    case none = 3
    case boss = 0xA19
    case point = 0x1C02
    case line = 0x1C03
    case path = 0x1C04
    case null1C05 = 0x1C05
    case spline = 0x1C06
    case unused1C09 = 0x1C09
    case point2 = 0x1C0B
    case unused1C0C = 0x1C0C
    case line2 = 0x1C0D
    case empty1C0E = 0x1C0E
    case zone = 0x1C0F

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .boss: return "Boss (centers on boss)"
        case .point: return "Point"
        case .line: return "Line"
        case .path: return "Polygonal Path"
        case .null1C05: return "Null (0x1C05)"
        case .spline: return "Spline"
        case .unused1C09: return "Unused (0x1C09)"
        case .point2: return "Point 2"
        case .unused1C0C: return "Unused (0x1C0C)"
        case .line2: return "Line 2"
        case .empty1C0E: return "Empty (0x1C0E)"
        case .zone: return "Zone"
        }
    }
}

// MARK: - Sub-camera payloads
//
// Every field here keeps its reference-tool name (`unkFloat1`, `unkInt`,
// ...) rather than a guessed, friendlier one, the reference tool itself
// never determined what most of these do (see its own `unk`-prefixed
// naming), so inventing more specific names here would just be dressing up
// a guess as a fact.

public struct CameraBoss: Sendable {
    public var unkInt: UInt32
    public var unkFloat1: Float
    public var unkFloat2: Float
    public var unkMatrix1: [SIMD4<Float>] // 4 rows
    public var unkMatrix2: [SIMD4<Float>] // 4 rows
    public var unkVector: SIMD4<Float>
    public var unkByte1: UInt8
    public var unkFloat3: Float
    public var unkFloat4: Float
    public var unkFloat5: Float
    public var unkFloat6: Float
    public var unkByte2: UInt8

    public init(unkInt: UInt32, unkFloat1: Float, unkFloat2: Float, unkMatrix1: [SIMD4<Float>], unkMatrix2: [SIMD4<Float>], unkVector: SIMD4<Float>, unkByte1: UInt8, unkFloat3: Float, unkFloat4: Float, unkFloat5: Float, unkFloat6: Float, unkByte2: UInt8) {
        self.unkInt = unkInt
        self.unkFloat1 = unkFloat1
        self.unkFloat2 = unkFloat2
        self.unkMatrix1 = unkMatrix1
        self.unkMatrix2 = unkMatrix2
        self.unkVector = unkVector
        self.unkByte1 = unkByte1
        self.unkFloat3 = unkFloat3
        self.unkFloat4 = unkFloat4
        self.unkFloat5 = unkFloat5
        self.unkFloat6 = unkFloat6
        self.unkByte2 = unkByte2
    }
}

public struct CameraPoint: Sendable {
    public var unkInt: UInt32
    public var unkFloat1: Float
    public var unkFloat2: Float
    public var unkVector: SIMD4<Float>

    public init(unkInt: UInt32, unkFloat1: Float, unkFloat2: Float, unkVector: SIMD4<Float>) {
        self.unkInt = unkInt
        self.unkFloat1 = unkFloat1
        self.unkFloat2 = unkFloat2
        self.unkVector = unkVector
    }
}

public struct CameraLine: Sendable {
    public var unkInt: UInt32
    public var unkFloat1: Float
    public var unkFloat2: Float
    public var boundingBoxVector1: SIMD4<Float>
    public var boundingBoxVector2: SIMD4<Float>

    public init(unkInt: UInt32, unkFloat1: Float, unkFloat2: Float, boundingBoxVector1: SIMD4<Float>, boundingBoxVector2: SIMD4<Float>) {
        self.unkInt = unkInt
        self.unkFloat1 = unkFloat1
        self.unkFloat2 = unkFloat2
        self.boundingBoxVector1 = boundingBoxVector1
        self.boundingBoxVector2 = boundingBoxVector2
    }
}

/// A polygonal chain camera path, `unkVectors` are the path's control
/// points. `trailingData` is `unkInt2 * 8` further undecoded bytes the
/// reference tool reads/writes as an opaque blob without interpreting.
public struct CameraPath: Sendable {
    public var unkInt: UInt32
    public var unkFloat1: Float
    public var unkFloat2: Float
    public var unkVectors: [SIMD4<Float>]
    public var trailingData: Data
    /// Byte offset of each `unkVectors[i]`'s first byte, relative to this
    /// `Camera` record's own start (i.e. directly addable to the owning
    /// `ChunkNode.fileOffset` for an absolute file offset), captured
    /// during parse (`WorldPlacementParser.parseCameraSubtype`) since a
    /// control point's position within the record depends on which
    /// sub-camera slot it's in and everything variable-length before it.
    /// Lets a dragged control point be patched straight into the file at
    /// its exact offset without re-encoding the rest of this
    /// variable-length record (see `WorldPlacementWriter.
    /// writeCameraControlPoint`).
    public var controlPointFileOffsets: [Int]

    public init(unkInt: UInt32, unkFloat1: Float, unkFloat2: Float, unkVectors: [SIMD4<Float>], trailingData: Data, controlPointFileOffsets: [Int] = []) {
        self.unkInt = unkInt
        self.unkFloat1 = unkFloat1
        self.unkFloat2 = unkFloat2
        self.unkVectors = unkVectors
        self.trailingData = trailingData
        self.controlPointFileOffsets = controlPointFileOffsets
    }
}

/// A spline camera path, `unkVectors` are `(segmentCount + 1) * 2` control
/// points. `trailingData` is `segmentCount * 8` further undecoded bytes.
public struct CameraSpline: Sendable {
    public var unkInt: Int32
    public var unkFloat1: Float
    public var unkFloat2: Float
    public var segmentCount: UInt32
    public var unkFloat3: Float
    public var unkVectors: [SIMD4<Float>]
    public var trailingData: Data
    public var unkShort: UInt16
    /// Same role as `CameraPath.controlPointFileOffsets`, one absolute-
    /// within-record byte offset per `unkVectors[i]`.
    public var controlPointFileOffsets: [Int]

    public init(unkInt: Int32, unkFloat1: Float, unkFloat2: Float, segmentCount: UInt32, unkFloat3: Float, unkVectors: [SIMD4<Float>], trailingData: Data, unkShort: UInt16, controlPointFileOffsets: [Int] = []) {
        self.unkInt = unkInt
        self.unkFloat1 = unkFloat1
        self.unkFloat2 = unkFloat2
        self.segmentCount = segmentCount
        self.unkFloat3 = unkFloat3
        self.unkVectors = unkVectors
        self.trailingData = trailingData
        self.unkShort = unkShort
        self.controlPointFileOffsets = controlPointFileOffsets
    }
}

/// Shared 3-field shape used by the 0x1C09 sub-camera, the reference tool
/// marks this type "unused, spits errors" and doesn't name its fields
/// beyond `unkInt`/`unkFloat1`/`unkFloat2`.
public struct CameraMinor: Sendable {
    public var unkInt: UInt32
    public var unkFloat1: Float
    public var unkFloat2: Float

    public init(unkInt: UInt32, unkFloat1: Float, unkFloat2: Float) {
        self.unkInt = unkInt
        self.unkFloat1 = unkFloat1
        self.unkFloat2 = unkFloat2
    }
}

public struct CameraPoint2: Sendable {
    public var unkInt: UInt32
    public var unkFloat1: Float
    public var unkFloat2: Float
    public var unkVector: SIMD4<Float>
    public var unkFloat3: Float
    public var unkByte: UInt8

    public init(unkInt: UInt32, unkFloat1: Float, unkFloat2: Float, unkVector: SIMD4<Float>, unkFloat3: Float, unkByte: UInt8) {
        self.unkInt = unkInt
        self.unkFloat1 = unkFloat1
        self.unkFloat2 = unkFloat2
        self.unkVector = unkVector
        self.unkFloat3 = unkFloat3
        self.unkByte = unkByte
    }
}

/// The 0x1C0C sub-camera's entire payload is 4 raw bytes, the reference
/// tool marks it "unused, fixed angle or distance from player?" and never
/// interprets them further.
public struct CameraFourBytes: Sendable {
    public var byte1: UInt8
    public var byte2: UInt8
    public var byte3: UInt8
    public var byte4: UInt8

    public init(byte1: UInt8, byte2: UInt8, byte3: UInt8, byte4: UInt8) {
        self.byte1 = byte1
        self.byte2 = byte2
        self.byte3 = byte3
        self.byte4 = byte4
    }
}

public struct CameraLine2: Sendable {
    public var unkInt: UInt32
    public var unkFloat1: Float
    public var unkFloat2: Float
    public var boundingBoxVector1: SIMD4<Float>
    public var boundingBoxVector2: SIMD4<Float>
    public var unkFloat3: Float
    public var unkFloat4: Float

    public init(unkInt: UInt32, unkFloat1: Float, unkFloat2: Float, boundingBoxVector1: SIMD4<Float>, boundingBoxVector2: SIMD4<Float>, unkFloat3: Float, unkFloat4: Float) {
        self.unkInt = unkInt
        self.unkFloat1 = unkFloat1
        self.unkFloat2 = unkFloat2
        self.boundingBoxVector1 = boundingBoxVector1
        self.boundingBoxVector2 = boundingBoxVector2
        self.unkFloat3 = unkFloat3
        self.unkFloat4 = unkFloat4
    }
}

public struct CameraZone: Sendable {
    public var data1Vectors: [SIMD4<Float>] // 4
    public var data1UnkInt1: UInt32
    public var data1UnkInt2: UInt32
    public var data1Padding: UInt64
    public var data2Vectors: [SIMD4<Float>] // 4
    public var data2UnkInt1: UInt32
    public var data2UnkInt2: UInt32
    public var data2Padding: UInt64

    public init(data1Vectors: [SIMD4<Float>], data1UnkInt1: UInt32, data1UnkInt2: UInt32, data1Padding: UInt64, data2Vectors: [SIMD4<Float>], data2UnkInt1: UInt32, data2UnkInt2: UInt32, data2Padding: UInt64) {
        self.data1Vectors = data1Vectors
        self.data1UnkInt1 = data1UnkInt1
        self.data1UnkInt2 = data1UnkInt2
        self.data1Padding = data1Padding
        self.data2Vectors = data2Vectors
        self.data2UnkInt1 = data2UnkInt1
        self.data2UnkInt2 = data2UnkInt2
        self.data2Padding = data2Padding
    }
}

/// The polymorphic sub-camera payload selected by `CameraKind`, Swift's
/// enum-with-associated-values replaces the reference tool's
/// `object[] Cameras` + runtime type switch (`Camera.cs`'s `ReadCamera`/
/// `WriteCamera`) with something the compiler can actually check.
public enum CameraSubtype: Sendable {
    case boss(CameraBoss)
    case point(CameraPoint)
    case line(CameraLine)
    case path(CameraPath)
    case null1C05
    case spline(CameraSpline)
    case unused1C09(CameraMinor)
    case point2(CameraPoint2)
    case unused1C0C(CameraFourBytes)
    case line2(CameraLine2)
    case empty1C0E
    case zone(CameraZone)

    public var kind: CameraKind {
        switch self {
        case .boss: return .boss
        case .point: return .point
        case .line: return .line
        case .path: return .path
        case .null1C05: return .null1C05
        case .spline: return .spline
        case .unused1C09: return .unused1C09
        case .point2: return .point2
        case .unused1C0C: return .unused1C0C
        case .line2: return .line2
        case .empty1C0E: return .empty1C0E
        case .zone: return .zone
        }
    }
}

/// A placed camera (`Camera` record, `SectionType.camera`/`.cameraDemo`) , 
/// an oriented trigger-shaped volume (same `Header`/`Enabled`/`Coords`/
/// `Instances` shape as `Trigger`) plus up to two polymorphic sub-camera
/// behaviors. Ported from `Twinsanity/Items/Instances/Camera.cs`.
public struct PlacedCamera: Sendable, Identifiable {
    public let id: UInt32
    public var header: UInt32
    public var enabledMask: UInt32
    public var someFloat: Float
    public var rotationQuaternion: SIMD4<Float>
    public var position: SIMD4<Float>
    public var size: SIMD4<Float>
    public var instanceIDs: [UInt16]
    /// The real `int32` immediately after `instanceIDs`' own duplicated
    /// count (`Camera.SectionHead` in the reference, same byte layout
    /// and role as `TriggerVolume.sectionHead`, since `Camera` shares
    /// `Trigger`'s identical `Header`/`Enabled`/`Coords`/`Instances`
    /// header shape). Default matches the reference's own `= 10` field
    /// initializer and `WorldPlacementWriter.writeNewCamera`'s hardcoded
    /// default.
    public var sectionHead: Int32

    public var camHeader: UInt32
    /// `nil` when parsed from a `.cameraDemo` record, the Demo layout
    /// omits this field entirely (`Camera.cs:316-323`).
    public var unkShort: UInt16?
    public var unkFloat1: Float
    public var unkCoords1: SIMD4<Float>
    public var unkCoords2: SIMD4<Float>
    public var unkFloat2: Float
    public var unkFloat3: Float
    public var unkUInt1: UInt32
    public var unkUInt2: UInt32
    public var unkUInt3: UInt32
    public var unkUInt4: UInt32
    public var unkInt5: Int32
    public var unkInt6: Int32
    public var unkFloat4: Float
    public var unkFloat5: Float
    public var unkFloat6: Float
    public var unkFloat7: Float
    public var unkUInt7: UInt32
    public var unkInt8: Int32
    public var unkUInt9: UInt32
    public var unkFloat8: Float
    public var cameraType1: CameraKind
    public var cameraType2: CameraKind
    /// `nil` when parsed from a `.cameraDemo` record (`Camera.cs:348-355`).
    public var unkByte: UInt8?
    public var subtype1: CameraSubtype?
    public var subtype2: CameraSubtype?
    /// Byte offset of `camHeader` (the first field after the shared
    /// Trigger-shape prefix `WorldPlacementWriter.writeTriggerOrCameraPrefix`
    /// already patches), relative to this `Camera` record's own start.
    /// Every field from `camHeader` through `unkFloat8` is fixed-size and
    /// strictly sequential (branching only on `isDemo`'s `unkShort`
    /// presence) right up to the polymorphic `cameraType1`/`cameraType2`/
    /// sub-payload, "Parity Phase F", so this one offset is enough for
    /// `WorldPlacementWriter.writeCameraFixedFields` to patch that whole
    /// block in one same-size write, same "capture once, patch in place"
    /// discipline as `ScriptCondition.fileOffset`. Changing which
    /// `CameraKind` a slot uses isn't covered, that would reshape the
    /// trailing variable-length sub-payload, real, separate structural
    /// work this pass doesn't attempt.
    public var fixedFieldsFileOffset: Int
    /// Byte offset of `subtype1`'s own first byte (right after `unkByte`/
    /// `cameraType2`), relative to this `Camera` record's own start , 
    /// captured during parse the same way `fixedFieldsFileOffset` is, so
    /// `WorldPlacementWriter.writeCameraSubtype` can patch a slot's whole
    /// payload in place. `nil`-payload slots (`cameraType1 == .none`)
    /// still get a real offset here (where a payload *would* start) even
    /// though there's nothing to patch there.
    public var subtype1FileOffset: Int
    /// Same role as `subtype1FileOffset`, for `subtype2`, its own start
    /// is wherever `subtype1`'s payload (if any) ends.
    public var subtype2FileOffset: Int

    public init(
        id: UInt32,
        header: UInt32,
        enabledMask: UInt32,
        someFloat: Float,
        rotationQuaternion: SIMD4<Float>,
        position: SIMD4<Float>,
        size: SIMD4<Float>,
        instanceIDs: [UInt16],
        sectionHead: Int32 = 10,
        camHeader: UInt32,
        unkShort: UInt16?,
        unkFloat1: Float,
        unkCoords1: SIMD4<Float>,
        unkCoords2: SIMD4<Float>,
        unkFloat2: Float,
        unkFloat3: Float,
        unkUInt1: UInt32,
        unkUInt2: UInt32,
        unkUInt3: UInt32,
        unkUInt4: UInt32,
        unkInt5: Int32,
        unkInt6: Int32,
        unkFloat4: Float,
        unkFloat5: Float,
        unkFloat6: Float,
        unkFloat7: Float,
        unkUInt7: UInt32,
        unkInt8: Int32,
        unkUInt9: UInt32,
        unkFloat8: Float,
        cameraType1: CameraKind,
        cameraType2: CameraKind,
        unkByte: UInt8?,
        subtype1: CameraSubtype?,
        subtype2: CameraSubtype?,
        fixedFieldsFileOffset: Int = 0,
        subtype1FileOffset: Int = 0,
        subtype2FileOffset: Int = 0
    ) {
        self.id = id
        self.header = header
        self.enabledMask = enabledMask
        self.someFloat = someFloat
        self.rotationQuaternion = rotationQuaternion
        self.position = position
        self.size = size
        self.instanceIDs = instanceIDs
        self.sectionHead = sectionHead
        self.camHeader = camHeader
        self.unkShort = unkShort
        self.unkFloat1 = unkFloat1
        self.unkCoords1 = unkCoords1
        self.unkCoords2 = unkCoords2
        self.unkFloat2 = unkFloat2
        self.unkFloat3 = unkFloat3
        self.unkUInt1 = unkUInt1
        self.unkUInt2 = unkUInt2
        self.unkUInt3 = unkUInt3
        self.unkUInt4 = unkUInt4
        self.unkInt5 = unkInt5
        self.unkInt6 = unkInt6
        self.unkFloat4 = unkFloat4
        self.unkFloat5 = unkFloat5
        self.unkFloat6 = unkFloat6
        self.unkFloat7 = unkFloat7
        self.unkUInt7 = unkUInt7
        self.unkInt8 = unkInt8
        self.unkUInt9 = unkUInt9
        self.unkFloat8 = unkFloat8
        self.cameraType1 = cameraType1
        self.cameraType2 = cameraType2
        self.unkByte = unkByte
        self.subtype1 = subtype1
        self.subtype2 = subtype2
        self.fixedFieldsFileOffset = fixedFieldsFileOffset
        self.subtype1FileOffset = subtype1FileOffset
        self.subtype2FileOffset = subtype2FileOffset
    }

    /// Rotation angle in degrees, same `2 * acos(w)` decode as
    /// `TriggerVolume.rotationAngleDegrees`, since `Camera` shares the
    /// identical `Header`/`Enabled`/`Coords`/`Instances` header shape.
    public var rotationAngleDegrees: Float {
        2 * acos(min(1, max(-1, rotationQuaternion.w))) * 180 / .pi
    }
}
