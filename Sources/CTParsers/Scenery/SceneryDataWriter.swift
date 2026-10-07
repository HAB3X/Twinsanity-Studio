import Foundation
import CTCore
import CTModels

/// Real write-back for `SceneryData`, both the narrow, fixed-offset
/// `modelMatrix` patch (`writeModelMatrix`, unchanged) and now a
/// **complete** record encoder (`encode`) capable of a full re-encode with
/// a genuinely different placement count, real insertion into the nested
/// `SceneryGroup`/`SceneryModelGroup` tree, ported field-for-field from
/// `SceneryData.cs`'s own `Save`/`SaveScenery`/`SaveSceneryModel` (every
/// field this format has, not just placements, see `SceneryAsset`'s own
/// doc comments for why `headerUnk1`/`headerUnk2`/`headerUnk3`/
/// `headerUnk4`/`headerBuffer`/`unkVar5`/`SceneryModelGroup.unkPos`/every
/// light's full field set all had to be captured first: none of them were
/// modeled before this, and a full re-encode that dropped any of them
/// would have silently zeroed real on-disk data).
public enum SceneryDataWriter {
    /// Encodes exactly the 64 bytes `SceneryDataParser.parseSceneryModelGroup`
    /// reads for one placement's `modelMatrix` (4 rows of `Vector4`,
    /// x/y/z/w each as `Float32`) -- the exact inverse of that read, so
    /// this can patch straight into `matrixFileOffset` with no other byte
    /// in the file moving.
    public static func writeModelMatrix(_ matrix: [SIMD4<Float>]) -> Data {
        var writer = BinaryWriter()
        for row in matrix {
            writer.writeFloat32(row.x)
            writer.writeFloat32(row.y)
            writer.writeFloat32(row.z)
            writer.writeFloat32(row.w)
        }
        return writer.data
    }

    /// Full record encode, the exact inverse of `SceneryDataParser.parse`.
    public static func encode(_ asset: SceneryAsset) -> Data {
        var w = BinaryWriter()
        w.writeUInt32(asset.headerUnk1)
        let nameBytes = Array(asset.chunkName.utf8)
        w.writeUInt32(UInt32(nameBytes.count))
        w.writeBytes(nameBytes)
        w.writeUInt32(asset.headerUnk2)
        if asset.isMonkeyBall {
            w.writeUInt8(0); w.writeUInt8(0); w.writeUInt8(0)
        }
        w.writeUInt32(asset.headerUnk3)
        w.writeUInt8(asset.headerUnk4)

        if asset.headerUnk1 & 0x10000 != 0 {
            w.writeUInt32(asset.skydomeID ?? 0)
        }

        if asset.headerUnk1 & 0x20000 != 0 {
            var buffer = asset.headerBuffer ?? Data()
            if buffer.count != 0x400 {
                buffer = Data(buffer.prefix(0x400))
                buffer.append(Data(repeating: 0, count: max(0, 0x400 - buffer.count)))
            }
            w.writeBytes(buffer)

            let ambientCount = UInt32(asset.ambientLights.count)
            let directionalCount = UInt32(asset.directionalLights.count)
            let pointCount = UInt32(asset.pointLights.count)
            let negativeCount = UInt32(asset.negativeLights.count)
            w.writeUInt32(ambientCount + directionalCount + pointCount + negativeCount)
            w.writeUInt32(ambientCount)
            w.writeUInt32(directionalCount)
            w.writeUInt32(pointCount)
            w.writeUInt32(negativeCount)

            for light in asset.ambientLights {
                writeBaseLight(light, into: &w)
            }
            for light in asset.directionalLights {
                writeBaseLight(light, into: &w)
                w.writeVector4(light.vector3)
                w.writeUInt16(light.unkShort)
            }
            for light in asset.pointLights {
                writeBaseLight(light, into: &w)
                w.writeUInt16(light.unkShort)
            }
            for light in asset.negativeLights {
                writeBaseLight(light, into: &w)
                w.writeVector4(light.vector3)
                w.writeFloat32(light.unkFloat1)
                w.writeFloat32(light.unkFloat2)
                w.writeUInt32(light.unkUInt1)
                w.writeUInt32(light.unkUInt2)
                w.writeUInt16(light.unkUShort1)
                w.writeUInt16(light.unkUShort2)
            }
        }

        if asset.headerUnk3 == 0x160A, let root = asset.root {
            w.writeUInt32(asset.unkVar5 ?? 0)
            writeSceneryGroup(root, into: &w)
        }

        return w.data
    }

    private static func writeBaseLight(_ light: SceneryLight, into w: inout BinaryWriter) {
        w.writeUInt32(light.flagsRaw)
        w.writeFloat32(light.radius)
        w.writeFloat32(light.colorR)
        w.writeFloat32(light.colorG)
        w.writeFloat32(light.colorB)
        w.writeFloat32(light.colorUnk)
        w.writeVector4(light.position)
        w.writeVector4(light.vector1)
        w.writeVector4(light.vector2)
    }

    /// Ported from `SaveScenery`: this group's own model, then all 8 child
    /// type tags (re-derived fresh from `links`' own case, `0x1605` for
    /// `.modelGroup`, `0x1600` for `.group`, `3` for `.empty`, matching
    /// the reference's own `SaveScenery`, which likewise never stores a
    /// separate "original tag" field and always re-derives it the same
    /// way on save), then each non-empty child's content in order.
    private static func writeSceneryGroup(_ group: SceneryGroup, into w: inout BinaryWriter) {
        writeSceneryModelGroup(group.model, into: &w)
        for link in group.links {
            switch link {
            case .modelGroup: w.writeInt32(0x1605)
            case .group: w.writeInt32(0x1600)
            case .empty: w.writeInt32(3)
            }
        }
        for link in group.links {
            switch link {
            case .modelGroup(let childGroup): writeSceneryModelGroup(childGroup, into: &w)
            case .group(let childGroup): writeSceneryGroup(childGroup, into: &w)
            case .empty: break
            }
        }
    }

    /// Ported from `SaveSceneryModel`: `modelCount` is *derived* from
    /// `placements`, scanning from index 0 until the first `isSpecial`
    /// entry (matching the reference exactly, see `SceneryModelPlacement.
    /// isSpecial`'s own doc comment on why the list must stay partitioned
    /// non-special-then-special for this to round-trip correctly).
    private static func writeSceneryModelGroup(_ group: SceneryModelGroup, into w: inout BinaryWriter) {
        w.writeUInt32(group.header)
        if group.header == 0x1613 {
            var modelCount: Int16 = 0
            for placement in group.placements {
                if placement.isSpecial { break }
                modelCount += 1
            }
            let specialModelCount = Int16(group.placements.count) - modelCount
            w.writeInt16(modelCount)
            w.writeInt16(specialModelCount)

            if !group.placements.isEmpty {
                for placement in group.placements {
                    w.writeVector4(placement.boundingBoxMin)
                    w.writeVector4(placement.boundingBoxMax)
                }
                for placement in group.placements {
                    w.writeUInt32(placement.modelID)
                }
                for placement in group.placements {
                    for row in placement.modelMatrix {
                        w.writeVector4(row)
                    }
                }
            }
        }
        for vector in group.unkPos {
            w.writeVector4(vector)
        }
    }
}
