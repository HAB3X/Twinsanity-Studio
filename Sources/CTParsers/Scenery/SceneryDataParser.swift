import Foundation
import CTCore
import CTModels

/// Decodes a `SceneryData` record, ported from
/// `Twinsanity/Items/SceneryData.cs`. Like `ColData`, this is a top-level
/// (tier 0) raw entry in `.SM2` files (subID 0), not a chunk-headered
/// section, see `RM2Parser.tier0Kind`'s `sm2` case.
public enum SceneryDataParser {
    private static let hasSkydomeFlag: UInt32 = 0x10000
    private static let hasLightsFlag: UInt32 = 0x20000
    private static let hasSceneryTreeMarker: UInt32 = 0x160A
    private static let nestedGroupTypeTag: Int32 = 0x1600
    private static let leafModelGroupTypeTag: Int32 = 0x1605
    private static let modelGroupWithPlacementsHeader: UInt32 = 0x1613

    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> SceneryAsset {
        let headerUnk1 = try cursor.readUInt32()
        let chunkNameLength = try cursor.readUInt32()
        let chunkName = try cursor.readASCIIString(length: Int(chunkNameLength))
        let headerUnk2 = try cursor.readUInt32()
        // `IsMonkeyBall` in the reference tool is set by the *caller* before
        // parsing (based on which file kind this scenery record came from),
        // not read from the stream, this package doesn't currently
        // distinguish an MB scenery variant at the dispatch level, so this
        // always takes the non-MonkeyBall (no 3-byte skip) path. Stored on
        // the result so a round-trip write knows to keep skipping it (it
        // will always decode `false` here, but the field exists so a
        // future MB-aware caller has somewhere real to put `true`).
        let isMonkeyBall = false
        let headerUnk3 = try cursor.readUInt32()
        let headerUnk4 = try cursor.readUInt8()

        var skydomeID: UInt32?
        if headerUnk1 & hasSkydomeFlag != 0 {
            skydomeID = try cursor.readUInt32()
        }

        var headerBuffer: Data?
        var ambientLights: [SceneryLight] = []
        var directionalLights: [SceneryLight] = []
        var pointLights: [SceneryLight] = []
        var negativeLights: [SceneryLight] = []

        if headerUnk1 & hasLightsFlag != 0 {
            headerBuffer = try cursor.readBytes(0x400)
            _ = try cursor.readUInt32() // LightsNum, redundant total, recomputed by the writer
            let ambientCount = try cursor.readUInt32()
            let directionalCount = try cursor.readUInt32()
            let pointCount = try cursor.readUInt32()
            let negativeCount = try cursor.readUInt32()

            for _ in 0..<ambientCount {
                ambientLights.append(try parseBaseLight(&cursor))
            }
            for _ in 0..<directionalCount {
                var light = try parseBaseLight(&cursor)
                light.vector3 = try cursor.readVector4()
                light.unkShort = try cursor.readUInt16()
                directionalLights.append(light)
            }
            for _ in 0..<pointCount {
                var light = try parseBaseLight(&cursor)
                light.unkShort = try cursor.readUInt16()
                pointLights.append(light)
            }
            for _ in 0..<negativeCount {
                var light = try parseBaseLight(&cursor)
                light.vector3 = try cursor.readVector4()
                light.unkFloat1 = try cursor.readFloat32()
                light.unkFloat2 = try cursor.readFloat32()
                light.unkUInt1 = try cursor.readUInt32()
                light.unkUInt2 = try cursor.readUInt32()
                light.unkUShort1 = try cursor.readUInt16()
                light.unkUShort2 = try cursor.readUInt16()
                negativeLights.append(light)
            }
        }

        var unkVar5: UInt32?
        var root: SceneryGroup?
        if headerUnk3 == hasSceneryTreeMarker {
            unkVar5 = try cursor.readUInt32()
            root = try parseSceneryGroup(&cursor)
        }

        return SceneryAsset(
            id: recordID,
            headerUnk1: headerUnk1,
            chunkName: chunkName,
            headerUnk2: headerUnk2,
            headerUnk3: headerUnk3,
            headerUnk4: headerUnk4,
            isMonkeyBall: isMonkeyBall,
            skydomeID: skydomeID,
            headerBuffer: headerBuffer,
            ambientLights: ambientLights,
            directionalLights: directionalLights,
            pointLights: pointLights,
            negativeLights: negativeLights,
            unkVar5: unkVar5,
            root: root
        )
    }

    /// Reads the shared `LightBase` shape: `Flags`(4 raw bytes) + `Radius`
    /// + `Color_R/G/B/Unk` + `Position` + `Vector1` + `Vector2`. Per-kind
    /// extra fields (`vector3`/`unkShort`/etc.) are filled in by the
    /// caller afterward, see each call site above.
    private static func parseBaseLight(_ cursor: inout BinaryCursor) throws -> SceneryLight {
        let flagsBytes = try cursor.readBytes(4)
        let flagsRaw = flagsBytes.enumerated().reduce(UInt32(0)) { acc, entry in acc | (UInt32(entry.element) << (8 * entry.offset)) }
        let radius = try cursor.readFloat32()
        let r = try cursor.readFloat32()
        let g = try cursor.readFloat32()
        let b = try cursor.readFloat32()
        let colorUnk = try cursor.readFloat32()
        let position = try cursor.readVector4()
        let vector1 = try cursor.readVector4()
        let vector2 = try cursor.readVector4()
        return SceneryLight(flagsRaw: flagsRaw, radius: radius, colorR: r, colorG: g, colorB: b, colorUnk: colorUnk, position: position, vector1: vector1, vector2: vector2)
    }

    /// Ported from `LoadScenery`: this group's own model, then all 8 child
    /// type tags read up front, then each child's content in order.
    private static func parseSceneryGroup(_ cursor: inout BinaryCursor) throws -> SceneryGroup {
        let model = try parseSceneryModelGroup(&cursor)

        var typeTags: [Int32] = []
        typeTags.reserveCapacity(8)
        for _ in 0..<8 {
            typeTags.append(try cursor.readInt32())
        }

        var links: [SceneryLink] = []
        links.reserveCapacity(8)
        for tag in typeTags {
            switch tag {
            case nestedGroupTypeTag:
                links.append(.group(try parseSceneryGroup(&cursor)))
            case leafModelGroupTypeTag:
                links.append(.modelGroup(try parseSceneryModelGroup(&cursor)))
            default:
                links.append(.empty)
            }
        }

        return SceneryGroup(model: model, links: links)
    }

    /// Ported from `LoadSceneryModel`: placements + matrices only under
    /// header `0x1613`; the trailing 5-vector block is always present.
    private static func parseSceneryModelGroup(_ cursor: inout BinaryCursor) throws -> SceneryModelGroup {
        let header = try cursor.readUInt32()
        var placements: [SceneryModelPlacement] = []

        if header == modelGroupWithPlacementsHeader {
            let modelCount = Int(try cursor.readUInt16())
            let specialModelCount = Int(try cursor.readUInt16())
            let total = modelCount + specialModelCount

            if total > 0 {
                var boxes: [(SIMD4<Float>, SIMD4<Float>)] = []
                boxes.reserveCapacity(total)
                for _ in 0..<total {
                    let boxMin = try cursor.readVector4()
                    let boxMax = try cursor.readVector4()
                    boxes.append((boxMin, boxMax))
                }
                var modelIDs: [UInt32] = []
                modelIDs.reserveCapacity(total)
                for _ in 0..<total {
                    modelIDs.append(try cursor.readUInt32())
                }
                var matrices: [[SIMD4<Float>]] = []
                var matrixOffsets: [Int] = []
                matrices.reserveCapacity(total)
                matrixOffsets.reserveCapacity(total)
                for _ in 0..<total {
                    matrixOffsets.append(cursor.position)
                    var rows: [SIMD4<Float>] = []
                    rows.reserveCapacity(4)
                    for _ in 0..<4 { rows.append(try cursor.readVector4()) }
                    matrices.append(rows)
                }
                for i in 0..<total {
                    placements.append(SceneryModelPlacement(
                        modelID: modelIDs[i],
                        isSpecial: i > modelCount - 1,
                        boundingBoxMin: boxes[i].0,
                        boundingBoxMax: boxes[i].1,
                        modelMatrix: matrices[i],
                        matrixFileOffset: matrixOffsets[i]
                    ))
                }
            }
        }

        var unkPos: [SIMD4<Float>] = []
        unkPos.reserveCapacity(5)
        for _ in 0..<5 { unkPos.append(try cursor.readVector4()) } // UnkPos[5], always present

        return SceneryModelGroup(header: header, placements: placements, unkPos: unkPos)
    }
}
