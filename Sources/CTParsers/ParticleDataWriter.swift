import Foundation
import CTCore
import CTModels

/// Encodes a `ParticleDataAsset` back to its real on-disk layout, the
/// exact inverse of `ParticleDataParser.parse` (mirrors `Editors/
/// ParticlesEditor.cs` in the reference tool), for versions 28/30 only
/// (the only two `ParticleDataParser` decodes). Refuses `isDefault`
/// records, see `ParticleDataAsset.canWriteBack`'s doc comment, and only
/// produces a byte-identical-length blob (required by `WorkspaceViewModel.
/// patchedFileBytes(replacing:with:)`) when no list (`particleTypes`,
/// `particleInstances`, or any of a definition's 8-entry gradients) has
/// had elements added or removed.
public enum ParticleDataWriter {
    public enum ParticleDataWriteError: Error, CustomStringConvertible {
        case cannotWriteBackDefaultRecord

        public var description: String {
            "This ParticleData record has an on-disk pre-header this build doesn't model (isDefault), refusing to write it back rather than dropping real data."
        }
    }

    public static func write(_ asset: ParticleDataAsset) throws -> Data {
        guard asset.canWriteBack else { throw ParticleDataWriteError.cannotWriteBackDefaultRecord }
        let isFinal = asset.version == 30

        var w = BinaryWriter()
        w.writeUInt32(asset.version)
        w.writeUInt32(UInt32(asset.particleTypes.count))
        for definition in asset.particleTypes {
            writeDefinition(&w, definition, isFinal: isFinal)
        }

        // `instanceSectionRawCount == nil` means the original record ended
        // right after its type definitions (the parser's own early-return
        // case), nothing more to write. Otherwise the raw count is always
        // re-emitted verbatim (not re-derived from `particleInstances.
        // count`): a `0` or out-of-range original value is real on-disk
        // data in its own right, not something to lose on write-back.
        guard let rawCount = asset.instanceSectionRawCount else { return w.data }
        w.writeUInt32(rawCount)
        for instance in asset.particleInstances {
            writeInstance(&w, instance)
        }

        w.writeBytes(asset.trailingBytes)
        return w.data
    }

    private static func writeFixedName(_ w: inout BinaryWriter, _ name: String, length: Int = 16) {
        var bytes = Array(name.utf8.prefix(length))
        if bytes.count < length { bytes.append(0) } // null-terminate, matching the parser's own stop-at-first-null read
        while bytes.count < length { bytes.append(0) }
        w.writeBytes(Array(bytes.prefix(length)))
    }

    private static func writeGradient8(_ w: inout BinaryWriter, time: [Float], value: [Float]) {
        for i in 0..<8 {
            w.writeFloat32(i < time.count ? time[i] : 0)
            w.writeFloat32(i < value.count ? value[i] : 0)
        }
    }

    private static func writeDefinition(_ w: inout BinaryWriter, _ d: ParticleSystemDefinition, isFinal: Bool) {
        writeFixedName(&w, d.name)
        w.writeInt16(d.genRate)
        w.writeUInt16(d.maxParticleCount)
        w.writeUInt16(d.unkUShort3)
        w.writeUInt16(d.emitterOverTime)
        w.writeUInt16(d.emitterOverTimeRandom)
        w.writeUInt16(d.emitterOffTime)
        w.writeUInt16(d.emitterOffTimeRandom)
        w.writeUInt8(d.genSort)
        w.writeUInt8(d.unkByte3)
        w.writeUInt8(d.textureFilter)
        w.writeUInt8(d.unkByte5)
        w.writeFloat32(d.unkFloat1)
        w.writeFloat32(d.cutOnRadius)
        w.writeFloat32(d.cutOffRadius)
        w.writeFloat32(d.drawCutOff)
        w.writeFloat32(d.unkFloat5)
        w.writeFloat32(d.unkFloat6)
        w.writeFloat32(d.velocity)
        w.writeFloat32(d.randomEmitX)
        w.writeFloat32(d.randomEmitY)
        w.writeFloat32(d.randomEmitZ)
        w.writeFloat32(d.randomStartX)
        w.writeFloat32(d.randomStartY)
        w.writeFloat32(d.randomStartZ)
        for f in [d.unkFloat8, d.unkFloat9, d.unkFloat10, d.unkFloat11, d.unkFloat12, d.unkFloat13,
                  d.unkFloat14, d.unkFloat15, d.unkFloat16, d.unkFloat17, d.unkFloat18, d.unkFloat19] {
            w.writeFloat32(f)
        }
        w.writeFloat32(d.gravity)
        w.writeFloat32(d.particleLifeTime)
        w.writeUInt16(d.unkUShort8)
        w.writeUInt8(d.unkByte6)
        w.writeUInt8(d.unkByte7)
        w.writeFloat32(d.unkFloat22)
        w.writeFloat32(d.jibberXFreq)
        w.writeFloat32(d.jibberXAmp)
        w.writeFloat32(d.jibberYFreq)
        w.writeFloat32(d.jibberYAmp)

        for entry in d.colorGradient { w.writeVector4(entry) }
        writeGradient8(&w, time: d.alphaGradientTime, value: d.alphaGradientValue)

        w.writeFloat32(d.distortionX)
        w.writeFloat32(d.distortionY)
        w.writeFloat32(d.minSize)
        w.writeFloat32(d.maxSize)
        writeGradient8(&w, time: d.sizeWidthTime, value: d.sizeWidthValue)
        writeGradient8(&w, time: d.sizeHeightTime, value: d.sizeHeightValue)
        w.writeFloat32(d.minRotation)
        w.writeFloat32(d.maxRotation)
        writeGradient8(&w, time: d.rotationTime, value: d.rotationValue)
        writeGradient8(&w, time: d.unkGradient1Time, value: d.unkGradient1Value)
        writeGradient8(&w, time: d.unkGradient2Time, value: d.unkGradient2Value)
        w.writeFloat32(d.textureStartX)
        w.writeFloat32(d.textureStartY)
        w.writeFloat32(d.textureEndX)
        w.writeFloat32(d.textureEndY)
        writeGradient8(&w, time: d.collisionTime, value: d.collisionValue)
        w.writeUInt8(d.collisionNumSpheres)
        w.writeUInt8(d.drawFlag)

        if !isFinal {
            w.writeInt32(d.padAmount)
            w.writeBytes(d.padExtraBytes)
        }

        w.writeInt32(Int32(d.particleGhostsNum))
        w.writeFloat32(d.ghostSeparation)
        w.writeInt32(Int32(d.starRadialPoints))
        w.writeFloat32(d.starRadiusRatio)
        w.writeFloat32(d.rampTime)
        w.writeInt32(d.texturePage)
        w.writeFloat32(d.scaleFactor)

        if isFinal {
            w.writeVector4(d.unkVec3) // version 28 never stores this on disk, it's computed at parse time, so nothing to write back for it.
        }
    }

    private static func writeInstance(_ w: inout BinaryWriter, _ instance: ParticleSystemInstance) {
        w.writeFloat32(instance.position.x)
        w.writeFloat32(instance.position.y)
        w.writeFloat32(instance.position.z) // W is a hardcoded 1 on read, never stored on disk.
        w.writeInt16(instance.gravityRotX)
        w.writeInt16(instance.gravityRotY)
        w.writeInt16(instance.emitRotX)
        w.writeInt16(instance.emitRotY)
        w.writeInt16(instance.unkShort5)
        w.writeUInt32(instance.offset)
        writeFixedName(&w, instance.name)
        w.writeInt32(instance.switchType)
        w.writeInt32(instance.switchID)
        w.writeFloat32(instance.switchValue)
        w.writeInt16(instance.unkShort6)
        w.writeInt16(instance.unkShort7)
        w.writeFloat32(instance.planeOffset)
        w.writeFloat32(instance.bounceFactor)
        w.writeInt16(instance.groupID)
    }
}
