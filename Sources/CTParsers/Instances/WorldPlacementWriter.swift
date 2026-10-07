import Foundation
import CTCore
import CTModels

/// Encodes a `PositionMarker` back to its on-disk 16-byte form, the
/// inverse of `WorldPlacementParser.parsePosition`. This is the "Editing
/// GUI" proof of concept's write path: `Position` was chosen as the first
/// record type to round-trip specifically because it's fixed-size (4
/// floats, always 16 bytes in and 16 bytes out), so an edit can be patched
/// straight into a copy of the original file bytes at the record's known
/// offset with no index-table/size recalculation anywhere else in the
/// file, every other decoded record type here is variable-length, which
/// is real, separate work (`ArchiveRepackager`-level offset repacking, not
/// just this one function) left for when this write path grows beyond a
/// single record type.
public enum WorldPlacementWriter {
    public static func writePosition(_ position: PositionMarker) -> Data {
        var writer = BinaryWriter()
        writer.writeFloat32(position.point.x)
        writer.writeFloat32(position.point.y)
        writer.writeFloat32(position.point.z)
        writer.writeFloat32(position.point.w)
        return writer.data
    }

    /// Encodes just `Instance`'s leading 28-byte transform prefix (`position`,
    /// then the six interleaved rotation/COM-rotation `UInt16`s), the exact
    /// inverse of the first six reads in `WorldPlacementParser.parseInstance`,
    /// stopping right before the variable-length `childInstanceIDs` list.
    /// Unlike `writePosition` this is *not* the whole record: `Instance` is
    /// variable-size (three counted ID lists plus three undocumented trailing
    /// lists), so re-encoding the full record would mean recomputing offsets
    /// for everything after it in the file, real, separate work this write
    /// path doesn't do. Patching only this fixed-size, fixed-offset prefix
    /// sidesteps that: a transform edit never changes the record's total
    /// size, so nothing after it moves.
    public static func writeInstanceTransform(position: SIMD4<Float>, rotationRaw: SIMD3<UInt16>, comRotationRaw: SIMD3<UInt16>) -> Data {
        var writer = BinaryWriter()
        writer.writeFloat32(position.x)
        writer.writeFloat32(position.y)
        writer.writeFloat32(position.z)
        writer.writeFloat32(position.w)
        writer.writeUInt16(rotationRaw.x)
        writer.writeUInt16(comRotationRaw.x)
        writer.writeUInt16(rotationRaw.y)
        writer.writeUInt16(comRotationRaw.y)
        writer.writeUInt16(rotationRaw.z)
        writer.writeUInt16(comRotationRaw.z)
        return writer.data
    }

    /// Encodes the leading 60-byte prefix `Trigger` and `Camera` records
    /// share byte-for-byte, `header`/`enabledMask`/`someFloat`/
    /// `rotationQuaternion`/`position`/`size`, in that order, the exact
    /// inverse of the first six reads in `WorldPlacementParser.parseTrigger`
    /// (and, separately, `parseCamera`, whose first six reads are
    /// identical; see `PlacedCamera`'s own doc comment: "same Header/
    /// Enabled/Coords/Instances shape as Trigger"). Both records go
    /// variable-length immediately after this (a counted `instanceIDs`
    /// list, then, for `Camera` only, many more fields and an optional
    /// polymorphic sub-payload), so same reasoning as `writeInstanceTransform`:
    /// this patches only the fixed-size, fixed-offset prefix, never the
    /// record's total size.
    /// "Backend Requirement: safely inject this new record" (Part 4D) , 
    /// encodes a **complete**, brand-new `Instance` record, not just the
    /// transform prefix `writeInstanceTransform` patches into an existing
    /// one. Field order matches `Instance.cs`'s `Save` exactly (verified
    /// against `WorldPlacementParser.parseInstance`'s matching `Load`
    /// order); every field this build has no reason to give a specific
    /// value to uses the *reference class's own default-constructor
    /// values* (`SomeNum1/2/3 = 10`, `RefList = -1`, `ScriptID = -1`,
    /// `UnkI321 = []`, `UnkI322 = [1]`, `UnkI323 = [0, 0]`), real defaults
    /// a freshly-`new Instance()`'d record in the reference tool actually
    /// has, not invented placeholder data. No child Instance/Position/Path
    /// IDs: a newly placed object starts with no scripted relationships to
    /// anything else in the level. Takes no record ID, unlike every field
    /// encoded below, the ID lives in the *enclosing section's* index-table
    /// entry (see `ChunkSectionInserter`), not inside the record's own
    /// bytes.
    ///
    /// `flags` is the one field this deliberately does *not* default to
    /// the reference class's own bare-constructor value (`0x6`), real,
    /// reported bug: a freshly-placed Instance with that value never
    /// actually renders/spawns in real gameplay (only in this project's own
    /// editor, which doesn't care), even though the record itself is
    /// byte-correct and present. `0x6` is genuinely just the reference
    /// editor's *blank starting point* for a human to fill in through its
    /// own property grid before saving, CrateModLoader's own working
    /// crate-randomizer mod (`TS_Rand_Crates.cs`, real, in-the-wild,
    /// verified-working) never leaves a real crate at that value; it always
    /// assigns a real, type-specific one on every single object it touches
    /// (`0x811E` for `BASICCRATE`/`WOODENSPRINGCRATE`/`AKUAKUCRATE`/
    /// `MULTIPLEHITCRATE`/`SURPRISECRATE`/`TNTCRATE`/`NITROCRATE`, the
    /// single most common value across every crate type it randomizes,
    /// and the default here), confirming `0x6` was never meant to reach a
    /// real disc. The ideal fix would look up the placed `objectID`'s own
    /// real `InstanceTemplate` record (`InstanceTemplateInfo.properties`
    /// carries exactly this value per-type, see `TS_Rand_Enemies.cs`'s
    /// own `instance.Flags = template.Properties`) and use that instead of
    /// one shared value for every object type; this project has no such
    /// lookup wired from a placement callsite to that record yet, so this
    /// takes the same fallback CrateModLoader's own data shows working for
    /// the overwhelming majority of real crate types, rather than shipping
    /// the known-broken reference default while that real fix is pending.
    public static func writeNewInstance(objectID: UInt16, position: SIMD4<Float>, rotationDegrees: SIMD3<Float>, flags: UInt32 = 0x811E, pathIDs: [UInt16] = [], scriptID: Int16 = -1) -> Data {
        var writer = BinaryWriter()
        writer.writeFloat32(position.x)
        writer.writeFloat32(position.y)
        writer.writeFloat32(position.z)
        writer.writeFloat32(position.w)

        let rotX = PlacedInstance.rawAngle(fromDegrees: rotationDegrees.x)
        let rotY = PlacedInstance.rawAngle(fromDegrees: rotationDegrees.y)
        let rotZ = PlacedInstance.rawAngle(fromDegrees: rotationDegrees.z)
        writer.writeUInt16(rotX)
        writer.writeUInt16(0) // COMRotX, no COM offset for a fresh placement
        writer.writeUInt16(rotY)
        writer.writeUInt16(0) // COMRotY
        writer.writeUInt16(rotZ)
        writer.writeUInt16(0) // COMRotZ

        // Three counted ID lists (InstanceIDs/PositionIDs/PathIDs), each
        // [count, count (written twice, per Instance.cs's own Save), SomeNum, values...].
        // InstanceIDs/PositionIDs stay empty for a fresh placement (no
        // scripted child-instance/position relationships to invent);
        // PathIDs carries `pathIDs`, "Set AI Path on a Newly-Placed AI"
        //, the only one of the three this build
        // has a real UI for assigning. SomeNum defaults to 10 either way,
        // matching the reference's own "object placed at runtime" fallback
        // template (`InstancesNum`/`PathsNum`/`PositionsNum` all `10` , 
        // see `WorldPlacementWriter.writeNewInstance`'s own doc comment on
        // `flags` for where that reference fallback comes from).
        writer.writeInt32(0)
        writer.writeInt32(0)
        writer.writeInt32(10)
        writer.writeInt32(0)
        writer.writeInt32(0)
        writer.writeInt32(10)
        writer.writeInt32(Int32(pathIDs.count))
        writer.writeInt32(Int32(pathIDs.count))
        writer.writeInt32(10)
        for id in pathIDs { writer.writeUInt16(id) }

        writer.writeUInt16(objectID)
        writer.writeInt16(-1) // RefList
        // "Real AI/Combat Behavior for Forge-Placed Objects": same "ideal
        // fix" gap this function's own doc comment already describes for
        // `flags`, now closed for `ScriptID` too, a fresh placement of an
        // object type that already has a real Instance elsewhere in this
        // level should reuse *that* Instance's own real `scriptID` (its
        // shared AI state machine), not silently start with no script
        // attached at all. `-1` (no script) stays the honest default when
        // no such placement exists to borrow one from, same "no guess
        // dressed up as data" posture as `flags`'s own `0x811E` fallback.
        writer.writeInt16(scriptID)
        // PHeader: (byte)UnkI321.Count | (UnkI322.Count << 8) | (UnkI323.Count << 16)
        // = 0 | (1 << 8) | (2 << 16), matching the UnkI322/UnkI323 defaults below.
        writer.writeUInt32(0x0002_0100)
        writer.writeUInt32(flags) // Flags, see this function's own doc comment

        writer.writeInt32(0) // UnkI321.Count, empty
        writer.writeInt32(1) // UnkI322.Count
        writer.writeFloat32(1) // UnkI322[0], reference default
        writer.writeInt32(2) // UnkI323.Count
        writer.writeUInt32(0) // UnkI323[0]
        writer.writeUInt32(0) // UnkI323[1]

        return writer.data
    }

    /// Encodes a **complete, arbitrary** `Instance` record, every field
    /// exactly as `instance` carries it, including the three child ID
    /// lists, their real `someNum1`/`2`/`3` values, and the three
    /// undocumented trailing lists. The general form `writeNewInstance`
    /// isn't: that one only ever produces a fresh, empty placement.
    /// `PHeader` is always recomputed from the live list counts here (byte
    /// `unknownUInt32List.count` | `unknownFloatList.count << 8` |
    /// `unknownUInt32List2.count << 16`), matching `Instance.Save`'s own
    /// unconditional recompute, never trusted from whatever was on disk
    /// before, same "decoded but never trusted by the writer" discipline
    /// `GameObjectWriter`/`SupportType1`'s own derived-header fields use.
    /// Field order matches `Instance.cs`'s `Save` exactly (same order
    /// `WorldPlacementParser.parseInstance`'s `Load` reads), and every
    /// counted list clamps its `UInt8`/byte-sized derived count the same
    /// way the reference's own implicit `(byte)` casts would overflow , 
    /// callers are expected to keep `unknownUInt32List`/`unknownFloatList`/
    /// `unknownUInt32List2` under 256 elements each, the same practical
    /// ceiling the reference tool itself is bound by.
    public static func writeInstance(_ instance: PlacedInstance) -> Data {
        var writer = BinaryWriter()
        writer.writeFloat32(instance.position.x)
        writer.writeFloat32(instance.position.y)
        writer.writeFloat32(instance.position.z)
        writer.writeFloat32(instance.position.w)
        writer.writeUInt16(instance.rotationRaw.x)
        writer.writeUInt16(instance.comRotationRaw.x)
        writer.writeUInt16(instance.rotationRaw.y)
        writer.writeUInt16(instance.comRotationRaw.y)
        writer.writeUInt16(instance.rotationRaw.z)
        writer.writeUInt16(instance.comRotationRaw.z)

        func writeCountedList(_ values: [UInt16], someNum: Int32) {
            writer.writeInt32(Int32(values.count))
            writer.writeInt32(Int32(values.count))
            writer.writeInt32(someNum)
            for value in values { writer.writeUInt16(value) }
        }
        writeCountedList(instance.childInstanceIDs, someNum: instance.someNum1)
        writeCountedList(instance.childPositionIDs, someNum: instance.someNum2)
        writeCountedList(instance.childPathIDs, someNum: instance.someNum3)

        writer.writeUInt16(instance.objectID)
        writer.writeInt16(instance.refList)
        writer.writeInt16(instance.scriptID)

        let pHeader = UInt32(UInt8(clamping: instance.unknownUInt32List.count))
            | (UInt32(instance.unknownFloatList.count) << 8)
            | (UInt32(instance.unknownUInt32List2.count) << 16)
        writer.writeUInt32(pHeader)
        writer.writeUInt32(instance.flags)

        writer.writeInt32(Int32(instance.unknownUInt32List.count))
        for value in instance.unknownUInt32List { writer.writeUInt32(value) }
        writer.writeInt32(Int32(instance.unknownFloatList.count))
        for value in instance.unknownFloatList { writer.writeFloat32(value) }
        writer.writeInt32(Int32(instance.unknownUInt32List2.count))
        for value in instance.unknownUInt32List2 { writer.writeUInt32(value) }

        return writer.data
    }

    /// Encodes a complete `AIPosition` record, the exact inverse of
    /// `AINavigationParser.parseAIPosition`. Fixed-size (18 bytes: `Pos`
    /// then `Num`, matching `AIPosition.cs`'s own `GetSize() => 18`
    /// exactly), so, like `writePosition`, this can patch straight into
    /// an existing record's offset with no other offset in the file
    /// needing to move, and works equally well for encoding a brand-new
    /// record to insert (`ChunkSectionInserter` doesn't care that this
    /// record type wasn't its original use case; the section-header/index
    /// layout it rebuilds is the same for every collection).
    public static func writeAIPosition(position: SIMD4<Float>, rawNodeType: UInt16) -> Data {
        var writer = BinaryWriter()
        writer.writeFloat32(position.x)
        writer.writeFloat32(position.y)
        writer.writeFloat32(position.z)
        writer.writeFloat32(position.w)
        writer.writeUInt16(rawNodeType)
        return writer.data
    }

    /// Encodes a complete `AIPath` record, the exact inverse of
    /// `AINavigationParser.parseAIPath`. Fixed-size (10 bytes: 5 real
    /// `UInt16` args, matching `AIPath.cs`'s own `GetSize() => 10`
    /// exactly), same "patch in place or insert fresh" versatility
    /// `writeAIPosition` has. `args` must have exactly 5 elements, the
    /// reference's own `Arg` is a fixed `ushort[5]`, never a variable-
    /// length list, so a caller passing anything else is a programmer
    /// error, not a real on-disk possibility to guess at.
    public static func writeAIPath(_ args: [UInt16]) -> Data {
        precondition(args.count == 5, "AIPath.Arg is always exactly 5 elements")
        var writer = BinaryWriter()
        for value in args { writer.writeUInt16(value) }
        return writer.data
    }

    /// Encodes an `Instance`'s `objectID` back to its on-disk 2-byte form
    ///, "Recipe Book" (roadmap 6.4) character/prop swap: reassigning
    /// which real `GameObject`/`RigidModel` an existing placement resolves
    /// to, patched at `PlacedInstance.objectIDFileOffset` the same way a
    /// moved camera control point patches its own offset. Never changes
    /// the record's size (`UInt16` in, `UInt16` out), so, like every
    /// other patch in this file, nothing else in the file needs to move.
    public static func writeInstanceObjectID(_ objectID: UInt16) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt16(objectID)
        return writer.data
    }

    /// Encodes an `Instance`'s `flags` back to its on-disk 4-byte form , 
    /// the "Instance Flags" checkbox editor's write-back, patched at
    /// `PlacedInstance.flagsFileOffset` the same way `writeInstanceObjectID`
    /// patches its own offset. Never changes the record's size (`UInt32`
    /// in, `UInt32` out).
    public static func writeInstanceFlags(_ flags: UInt32) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(flags)
        return writer.data
    }

    /// Encodes `Trigger`'s four `arg1...arg4` values back to their
    /// on-disk 8-byte form, patched at `TriggerVolume.argsFileOffset`.
    /// No verified per-argument names exist for these (unlike
    /// `PlacedInstance.flags`), so this is a raw round trip only, same
    /// discipline as `AgentLabWriter`.
    public static func writeTriggerArguments(_ arg1: UInt16, _ arg2: UInt16, _ arg3: UInt16, _ arg4: UInt16) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt16(arg1)
        writer.writeUInt16(arg2)
        writer.writeUInt16(arg3)
        writer.writeUInt16(arg4)
        return writer.data
    }

    /// Encodes one Camera Path/Spline control point (`CameraPath.unkVectors`/
    /// `CameraSpline.unkVectors`) back to its on-disk 16-byte form, the
    /// exact inverse of `BinaryCursor.readVector4` at the offset captured
    /// in `controlPointFileOffsets` during parse. A dragged control point
    /// never changes the record's total size (same value in, same value
    /// out, just different bits), so, like `writePosition`, this patches
    /// straight into a copy of the file at the point's exact absolute
    /// offset (`ChunkNode.fileOffset + controlPointFileOffsets[i]`) with
    /// nothing else in the file needing to move.
    /// "Parity Phase F": encodes the fixed-size block of `Camera`-specific
    /// scalar fields between the shared Trigger-shape prefix and the
    /// polymorphic `cameraType1`/`cameraType2`/sub-payload, `camHeader`
    /// through `unkFloat8`, in `WorldPlacementParser.parseCamera`'s exact
    /// read order, respecting `isDemo`'s `unkShort` omission the same way
    /// that parser does. Meant to be patched at `PlacedCamera.
    /// fixedFieldsFileOffset`; never touches `cameraType1`/`cameraType2`
    /// or either sub-payload, so the block is always the same size as what
    /// it replaces.
    public static func writeCameraFixedFields(_ camera: PlacedCamera, isDemo: Bool) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(camera.camHeader)
        if !isDemo, let unkShort = camera.unkShort {
            writer.writeUInt16(unkShort)
        }
        writer.writeFloat32(camera.unkFloat1)
        writer.writeVector4(camera.unkCoords1)
        writer.writeVector4(camera.unkCoords2)
        writer.writeFloat32(camera.unkFloat2)
        writer.writeFloat32(camera.unkFloat3)
        writer.writeUInt32(camera.unkUInt1)
        writer.writeUInt32(camera.unkUInt2)
        writer.writeUInt32(camera.unkUInt3)
        writer.writeUInt32(camera.unkUInt4)
        writer.writeInt32(camera.unkInt5)
        writer.writeInt32(camera.unkInt6)
        writer.writeFloat32(camera.unkFloat4)
        writer.writeFloat32(camera.unkFloat5)
        writer.writeFloat32(camera.unkFloat6)
        writer.writeFloat32(camera.unkFloat7)
        writer.writeUInt32(camera.unkUInt7)
        writer.writeInt32(camera.unkInt8)
        writer.writeUInt32(camera.unkUInt9)
        writer.writeFloat32(camera.unkFloat8)
        return writer.data
    }

    public static func writeCameraControlPoint(_ vector: SIMD4<Float>) -> Data {
        var writer = BinaryWriter()
        writer.writeFloat32(vector.x)
        writer.writeFloat32(vector.y)
        writer.writeFloat32(vector.z)
        writer.writeFloat32(vector.w)
        return writer.data
    }

    /// Encodes a whole `CameraSubtype` payload back to its exact on-disk
    /// form, the inverse of `WorldPlacementParser.parseCameraSubtype`,
    /// field-for-field in the same order that function reads them. Meant
    /// to be patched at `PlacedCamera.subtype1FileOffset`/
    /// `subtype2FileOffset`.
    ///
    /// `.path`/`.spline` re-encode their `unkVectors`/`trailingData`
    /// verbatim from the struct (never re-derived from a count a caller
    /// could change), same "no restructuring" boundary
    /// `writeCameraFixedFields`'s own doc comment draws for the
    /// `cameraType1`/`cameraType2` fields themselves: editing which
    /// control points exist is `writeCameraControlPoint`'s job (one
    /// same-size point at a time), not this function's. As long as the
    /// caller only edits a subtype's own scalar fields, this always
    /// produces exactly as many bytes as the slot originally occupied,
    /// making it safe to patch in place without touching anything after it
    /// (the other subtype slot, `Instances`, or the next record).
    public static func writeCameraSubtype(_ subtype: CameraSubtype) -> Data {
        var writer = BinaryWriter()
        switch subtype {
        case .boss(let boss):
            writer.writeUInt32(boss.unkInt)
            writer.writeFloat32(boss.unkFloat1)
            writer.writeFloat32(boss.unkFloat2)
            for row in boss.unkMatrix1 { writer.writeVector4(row) }
            for row in boss.unkMatrix2 { writer.writeVector4(row) }
            writer.writeVector4(boss.unkVector)
            writer.writeUInt8(boss.unkByte1)
            writer.writeFloat32(boss.unkFloat3)
            writer.writeFloat32(boss.unkFloat4)
            writer.writeFloat32(boss.unkFloat5)
            writer.writeFloat32(boss.unkFloat6)
            writer.writeUInt8(boss.unkByte2)

        case .point(let point):
            writer.writeUInt32(point.unkInt)
            writer.writeFloat32(point.unkFloat1)
            writer.writeFloat32(point.unkFloat2)
            writer.writeVector4(point.unkVector)

        case .line(let line):
            writer.writeUInt32(line.unkInt)
            writer.writeFloat32(line.unkFloat1)
            writer.writeFloat32(line.unkFloat2)
            writer.writeVector4(line.boundingBoxVector1)
            writer.writeVector4(line.boundingBoxVector2)

        case .path(let path):
            writer.writeUInt32(path.unkInt)
            writer.writeFloat32(path.unkFloat1)
            writer.writeFloat32(path.unkFloat2)
            writer.writeUInt32(UInt32(path.unkVectors.count))
            for vector in path.unkVectors { writer.writeVector4(vector) }
            writer.writeInt32(Int32(path.trailingData.count / 8))
            writer.writeBytes(path.trailingData)

        case .null1C05:
            break

        case .spline(let spline):
            writer.writeInt32(spline.unkInt)
            writer.writeFloat32(spline.unkFloat1)
            writer.writeFloat32(spline.unkFloat2)
            writer.writeUInt32(spline.segmentCount)
            writer.writeFloat32(spline.unkFloat3)
            for vector in spline.unkVectors { writer.writeVector4(vector) }
            writer.writeBytes(spline.trailingData)
            writer.writeUInt16(spline.unkShort)

        case .unused1C09(let minor):
            writer.writeUInt32(minor.unkInt)
            writer.writeFloat32(minor.unkFloat1)
            writer.writeFloat32(minor.unkFloat2)

        case .point2(let point2):
            writer.writeUInt32(point2.unkInt)
            writer.writeFloat32(point2.unkFloat1)
            writer.writeFloat32(point2.unkFloat2)
            writer.writeVector4(point2.unkVector)
            writer.writeFloat32(point2.unkFloat3)
            writer.writeUInt8(point2.unkByte)

        case .unused1C0C(let bytes):
            writer.writeUInt8(bytes.byte1)
            writer.writeUInt8(bytes.byte2)
            writer.writeUInt8(bytes.byte3)
            writer.writeUInt8(bytes.byte4)

        case .line2(let line2):
            writer.writeUInt32(line2.unkInt)
            writer.writeFloat32(line2.unkFloat1)
            writer.writeFloat32(line2.unkFloat2)
            writer.writeVector4(line2.boundingBoxVector1)
            writer.writeVector4(line2.boundingBoxVector2)
            writer.writeFloat32(line2.unkFloat3)
            writer.writeFloat32(line2.unkFloat4)

        case .empty1C0E:
            break

        case .zone(let zone):
            for row in zone.data1Vectors { writer.writeVector4(row) }
            writer.writeUInt32(zone.data1UnkInt1)
            writer.writeUInt32(zone.data1UnkInt2)
            writer.writeUInt64(zone.data1Padding)
            for row in zone.data2Vectors { writer.writeVector4(row) }
            writer.writeUInt32(zone.data2UnkInt1)
            writer.writeUInt32(zone.data2UnkInt2)
            writer.writeUInt64(zone.data2Padding)
        }
        return writer.data
    }

    /// Encodes a single element of `Instance.unknownFloatList` (`UnkI322`)
    /// back to its on-disk 4-byte form, "Gameplay Mods" (see
    /// `GameplayModCatalog`) write-back, patched at
    /// `PlacedInstance.unknownFloatListFileOffset + index * 4`. Never
    /// changes the record's size (one `Float32` in, one out).
    public static func writeInstanceUnknownFloatElement(_ value: Float) -> Data {
        var writer = BinaryWriter()
        writer.writeFloat32(value)
        return writer.data
    }

    /// Encodes a single element of `Instance.unknownUInt32List`/
    /// `unknownUInt32List2` (`UnkI321`/`UnkI323`) back to its on-disk
    /// 4-byte form, same reasoning as `writeInstanceUnknownFloatElement`,
    /// patched at `unknownUInt32ListFileOffset`/`unknownUInt32List2FileOffset
    /// + index * 4`.
    public static func writeInstanceUnknownUInt32Element(_ value: UInt32) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(value)
        return writer.data
    }

    /// "Backend Requirement: safely inject this new record" (Part 4D),
    /// extended to `Trigger`, a complete, brand-new `Trigger` record,
    /// field order and defaults verified directly against `Trigger.cs`'s
    /// own `Save()`/property-initializer values (`Header = 50`, `Enabled =
    /// 1`, `SomeFloat = 0.3`, `Coords = [rot(0,0,0,1), pos(0,0,0,1),
    /// size(1,1,1,1)]`, `SectionHead = 10`, empty `Instances`, `Arg1..4 =
    /// 0`), real defaults a freshly-`new Trigger()`'d record actually has,
    /// not invented placeholder data. `position`/`size`/`rotationQuaternion`
    /// are the only fields a caller has reason to set immediately (matching
    /// where a click-to-place puts it), everything else uses the reference
    /// default. No record ID, same reasoning as `writeNewInstance`, the ID
    /// lives in the enclosing section's index-table entry.
    public static func writeNewTrigger(position: SIMD4<Float>, size: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1), rotationQuaternion: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)) -> Data {
        var writer = BinaryWriter()
        writer.writeBytes(writeTriggerOrCameraPrefix(header: 50, enabledMask: 1, someFloat: 0.3, rotationQuaternion: rotationQuaternion, position: position, size: size))
        // Instances: count written twice (empty), then SectionHead.
        writer.writeInt32(0)
        writer.writeInt32(0)
        writer.writeUInt32(10)
        // Arg1...Arg4, reference default (unset ushorts = 0).
        writer.writeUInt16(0)
        writer.writeUInt16(0)
        writer.writeUInt16(0)
        writer.writeUInt16(0)
        return writer.data
    }

    /// "Backend Requirement: safely inject this new record" (Part 4D),
    /// extended to `Camera`, a complete, brand-new `Camera` record, field
    /// order and defaults verified directly against `Camera.cs`'s own
    /// `Save()`/property-initializer values. Sharing `Trigger`'s
    /// `Header`/`Enabled`/`Coords`/`SectionHead` defaults isn't a
    /// coincidence, both use the identical `Pos[3]` rot/pos/size shape
    /// (see `writeTriggerOrCameraPrefix`'s own doc comment), but `Camera`
    /// has its own separate default `Header = 1310720`.
    ///
    /// `cameraType1`/`cameraType2` default to `3` ("None," matching
    /// `Camera.cs`'s own default), a fresh Camera has neither sub-payload
    /// slot filled, so `Camera.Save`'s `WriteCamera` branch never runs and
    /// this encoder never needs to touch any of the twelve polymorphic
    /// `Camera_*` sub-payload shapes `parseCameraSubtype` decodes. Every
    /// other `Unk*` field is the reference's own zero/default-valued
    /// property (`UnkFloat1 = 1`, `UnkCoords1`/`UnkCoords2 = (0,0,0,1)`,
    /// everything else `0`), not invented.
    ///
    /// `isDemo` mirrors `WorldPlacementParser.parseCamera`'s own parameter:
    /// `Camera.cs`'s `Save`/`Load` omit `UnkShort`/`UnkByte` entirely when
    /// `ParentType == SectionType.CameraDemo`, pass the same value the
    /// destination collection's section type implies, not a guess.
    public static func writeNewCamera(position: SIMD4<Float>, size: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1), rotationQuaternion: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1), isDemo: Bool = false) -> Data {
        var writer = BinaryWriter()
        writer.writeBytes(writeTriggerOrCameraPrefix(header: 1_310_720, enabledMask: 1, someFloat: 0.3, rotationQuaternion: rotationQuaternion, position: position, size: size))
        // Instances: count written twice (empty), then SectionHead.
        writer.writeInt32(0)
        writer.writeInt32(0)
        writer.writeUInt32(10)

        writer.writeUInt32(0) // CamHeader
        if !isDemo {
            writer.writeUInt16(0) // UnkShort
        }
        writer.writeFloat32(1) // UnkFloat1
        writer.writeVector4(SIMD4<Float>(0, 0, 0, 1)) // UnkCoords1
        writer.writeVector4(SIMD4<Float>(0, 0, 0, 1)) // UnkCoords2
        writer.writeFloat32(0) // UnkFloat2
        writer.writeFloat32(0) // UnkFloat3
        writer.writeUInt32(0) // UnkUInt1
        writer.writeUInt32(0) // UnkUInt2
        writer.writeUInt32(0) // UnkUInt3
        writer.writeUInt32(0) // UnkUInt4
        writer.writeInt32(0) // UnkInt5
        writer.writeInt32(0) // UnkInt6
        writer.writeFloat32(0) // UnkFloat4
        writer.writeFloat32(0) // UnkFloat5
        writer.writeFloat32(0) // UnkFloat6
        writer.writeFloat32(0) // UnkFloat7
        writer.writeUInt32(0) // UnkUInt7
        writer.writeInt32(0) // UnkInt8
        writer.writeUInt32(0) // UnkUInt9
        writer.writeFloat32(0) // UnkFloat8

        writer.writeUInt32(3) // CameraType1, None
        writer.writeUInt32(3) // CameraType2, None

        if !isDemo {
            writer.writeUInt8(0) // UnkByte
        }
        // CameraType1/2 == 3 ("None"), no polymorphic sub-payload to write.

        return writer.data
    }

    public static func writeTriggerOrCameraPrefix(header: UInt32, enabledMask: UInt32, someFloat: Float, rotationQuaternion: SIMD4<Float>, position: SIMD4<Float>, size: SIMD4<Float>) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(header)
        writer.writeUInt32(enabledMask)
        writer.writeFloat32(someFloat)
        writer.writeFloat32(rotationQuaternion.x)
        writer.writeFloat32(rotationQuaternion.y)
        writer.writeFloat32(rotationQuaternion.z)
        writer.writeFloat32(rotationQuaternion.w)
        writer.writeFloat32(position.x)
        writer.writeFloat32(position.y)
        writer.writeFloat32(position.z)
        writer.writeFloat32(position.w)
        writer.writeFloat32(size.x)
        writer.writeFloat32(size.y)
        writer.writeFloat32(size.z)
        writer.writeFloat32(size.w)
        return writer.data
    }
}
