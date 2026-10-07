import Foundation
import CTCore
import CTModels

/// Decodes a `ParticleData` record, ported field-for-field from
/// `Twinsanity/Items/ParticleData.cs`'s `Load`, restricted to the two
/// versions that are real, shipped Crash Twinsanity data per the
/// reference's own version table: **28** (Demo/some Final PTL files) and
/// **30** (Final/SMBA). Every other version in that table (TWOC 9–15,
/// Twins Proto 21, Nemo 26, LSW/Narnia 34) belongs to a different
/// TT-engine game or an internal prototype build this codebase has no
/// verified reference disc for, `parse` throws `unsupportedVersion`
/// for those rather than guessing at a layout, same discipline as
/// `TextureParser`'s PSMCT32/PSMT8-only decode.
///
/// `isMonkeyBall` (a real branch in the reference `Load`, gating 6 extra
/// leading `uint32` IDs) is never exercised here, this package's
/// `EngineDriver` only ever calls this for Crash Twinsanity files.
public enum ParticleDataParser {
    public enum ParticleDataParseError: Error, CustomStringConvertible {
        case unsupportedVersion(UInt32)
        case negativeRemainder

        public var description: String {
            switch self {
            case .unsupportedVersion(let version):
                return "ParticleData version \(version) isn't Crash Twinsanity's Demo (28) or Final (30) format, not decoded."
            case .negativeRemainder:
                return "ParticleData record ran past its own declared size while parsing, likely a truncated or corrupt record."
            }
        }
    }

    private static let supportedVersions: Set<UInt32> = [28, 30]

    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32, size: Int) throws -> ParticleDataAsset {
        let startPosition = cursor.position

        let firstValue = try cursor.readUInt32()
        let version: UInt32
        let isDefault: Bool
        if firstValue > 0xFF {
            // "Default.rm2 has some pre-header data: 3x (texture ID +
            // material ID)", the first field isn't really a version at
            // all in this case, it's the first texture ID (a large,
            // hash-like resource ID, hence > 0xFF). Real version follows
            // 5 more uint32s later.
            isDefault = true
            _ = try cursor.readUInt32() // ParticleMaterialID_1
            _ = try cursor.readUInt32() // ParticleTextureID_2
            _ = try cursor.readUInt32() // ParticleMaterialID_2
            _ = try cursor.readUInt32() // ParticleTextureID_3
            _ = try cursor.readUInt32() // ParticleMaterialID_3
            version = try cursor.readUInt32()
        } else {
            isDefault = false
            version = firstValue
        }

        guard supportedVersions.contains(version) else {
            throw ParticleDataParseError.unsupportedVersion(version)
        }
        let isFinal = version == 30 // vs. version 28 (Demo), see the two real per-version byte-layout differences below.

        let particleTypeCount = try cursor.readUInt32()
        var particleTypes: [ParticleSystemDefinition] = []
        particleTypes.reserveCapacity(cursor.safeReserveCount(particleTypeCount, elementSize: 690))
        for _ in 0..<particleTypeCount {
            particleTypes.append(try parseDefinition(&cursor, isFinal: isFinal))
        }

        // "if (reader.BaseStream.Position == start_pos + DataSize) return" , 
        // a record with only type definitions and no instance data at all
        // is real and valid, not truncated.
        if cursor.position == startPosition + size {
            return ParticleDataAsset(id: recordID, version: version, isDefault: isDefault, particleTypes: particleTypes, particleInstances: [], instanceSectionRawCount: nil, trailingBytes: Data())
        }

        let instanceCheck = try cursor.readUInt32()
        var particleInstances: [ParticleSystemInstance] = []
        if !isDefault, instanceCheck != 0, instanceCheck < 65536 {
            particleInstances.reserveCapacity(cursor.safeReserveCount(instanceCheck, elementSize: 60))
            for _ in 0..<instanceCheck {
                particleInstances.append(try parseInstance(&cursor))
            }
        }

        if isDefault {
            _ = try cursor.readUInt32() // DecalTextureID == instanceCheck's slot when isDefault; real value is instanceCheck itself in the reference
            _ = try cursor.readUInt32() // DecalMaterialID
        }

        let remainBytes = (startPosition + size) - cursor.position
        guard remainBytes >= 0 else { throw ParticleDataParseError.negativeRemainder }
        let trailingBytes = remainBytes > 0 ? try cursor.readBytes(remainBytes) : Data()

        return ParticleDataAsset(
            id: recordID, version: version, isDefault: isDefault, particleTypes: particleTypes, particleInstances: particleInstances,
            instanceSectionRawCount: instanceCheck, trailingBytes: trailingBytes
        )
    }

    /// Fixed-width (16-byte) null-terminated name field, ported from the
    /// reference's own read loop: stop at the first null, but always
    /// consume exactly `length` bytes total (skipping whatever's after
    /// the null), same as a non-null-terminated 16-char field would.
    private static func readFixedName(_ cursor: inout BinaryCursor, length: Int = 16) throws -> String {
        var bytes: [UInt8] = []
        var consumed = 0
        while consumed < length {
            let byte = try cursor.readUInt8()
            consumed += 1
            if byte == 0 {
                let remaining = length - consumed
                if remaining > 0 { _ = try cursor.readBytes(remaining) }
                break
            }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func readGradient8(_ cursor: inout BinaryCursor) throws -> (time: [Float], value: [Float]) {
        var time: [Float] = []
        var value: [Float] = []
        time.reserveCapacity(8)
        value.reserveCapacity(8)
        for _ in 0..<8 {
            time.append(try cursor.readFloat32())
            value.append(try cursor.readFloat32())
        }
        return (time, value)
    }

    private static func parseDefinition(_ cursor: inout BinaryCursor, isFinal: Bool) throws -> ParticleSystemDefinition {
        let name = try readFixedName(&cursor)
        let genRate = try cursor.readInt16()
        let maxParticleCount = try cursor.readUInt16()
        let unkUShort3 = try cursor.readUInt16()
        let emitterOverTime = try cursor.readUInt16()
        let emitterOverTimeRandom = try cursor.readUInt16()
        let emitterOffTime = try cursor.readUInt16()
        let emitterOffTimeRandom = try cursor.readUInt16()
        let genSort = try cursor.readUInt8()
        let unkByte3 = try cursor.readUInt8()
        let textureFilter = try cursor.readUInt8()
        let unkByte5 = try cursor.readUInt8()
        let unkFloat1 = try cursor.readFloat32()
        // Version >= 0x6, always true for 28/30.
        let cutOnRadius = try cursor.readFloat32()
        let cutOffRadius = try cursor.readFloat32()
        // Version >= 0xA, always true.
        let drawCutOff = try cursor.readFloat32()
        // "Version <= 0x16 || == 0x20" is always false for 28/30 -> the reference's `else` (real read) always applies.
        let unkFloat5 = try cursor.readFloat32()
        let unkFloat6 = try cursor.readFloat32()
        // Version < 0x7, always false, no skip.
        let velocity = try cursor.readFloat32()
        let randomEmitX = try cursor.readFloat32()
        let randomEmitY = try cursor.readFloat32()
        let randomEmitZ = try cursor.readFloat32()
        // Version < 0x12, always false, no padding.
        let randomStartX = try cursor.readFloat32()
        let randomStartY = try cursor.readFloat32()
        let randomStartZ = try cursor.readFloat32()
        // Version < 0x12, always false, no padding.
        let unkFloat8 = try cursor.readFloat32()
        let unkFloat9 = try cursor.readFloat32()
        let unkFloat10 = try cursor.readFloat32()
        let unkFloat11 = try cursor.readFloat32()
        let unkFloat12 = try cursor.readFloat32()
        let unkFloat13 = try cursor.readFloat32()
        let unkFloat14 = try cursor.readFloat32()
        let unkFloat15 = try cursor.readFloat32()
        let unkFloat16 = try cursor.readFloat32()
        let unkFloat17 = try cursor.readFloat32()
        let unkFloat18 = try cursor.readFloat32()
        let unkFloat19 = try cursor.readFloat32()
        let gravity = try cursor.readFloat32()
        let particleLifeTime = try cursor.readFloat32()
        let unkUShort8 = try cursor.readUInt16()
        let unkByte6 = try cursor.readUInt8()
        let unkByte7 = try cursor.readUInt8()
        let unkFloat22 = try cursor.readFloat32()
        let jibberXFreq = try cursor.readFloat32()
        let jibberXAmp = try cursor.readFloat32()
        let jibberYFreq = try cursor.readFloat32()
        let jibberYAmp = try cursor.readFloat32()

        var colorGradient: [SIMD4<Float>] = []
        colorGradient.reserveCapacity(8)
        for _ in 0..<8 { colorGradient.append(try cursor.readVector4()) }
        let alphaGradient = try readGradient8(&cursor)

        // Version >= 0x15, always true.
        let distortionX = try cursor.readFloat32()
        let distortionY = try cursor.readFloat32()
        let minSize = try cursor.readFloat32()
        let maxSize = try cursor.readFloat32()
        let sizeWidth = try readGradient8(&cursor)
        let sizeHeight = try readGradient8(&cursor)
        let minRotation = try cursor.readFloat32()
        let maxRotation = try cursor.readFloat32()
        let rotation = try readGradient8(&cursor)
        let unkGradient1 = try readGradient8(&cursor)
        let unkGradient2 = try readGradient8(&cursor)
        let textureStartX = try cursor.readFloat32()
        let textureStartY = try cursor.readFloat32()
        let textureEndX = try cursor.readFloat32()
        let textureEndY = try cursor.readFloat32()
        // Version >= 0x3, always true.
        let collision = try readGradient8(&cursor)
        let collisionNumSpheres = try cursor.readUInt8()
        // Version >= 0x11, always true.
        let drawFlag = try cursor.readUInt8()

        // "Version > 0x16 && != 0x20" is always true for 28/30; only its
        // *inner* "Version < 0x1D" (29) branch differs between them , 
        // true only for version 28 (Demo), meaning only version 28
        // records carry this padding on disk at all.
        var padAmount: Int32 = 0
        var padExtraBytes = Data()
        if !isFinal {
            padAmount = try cursor.readInt32()
            padExtraBytes = try cursor.readBytes(Int(padAmount) * 24)
        }

        // Version >= 0xB && <= 0x15 (TWOC/Proto sound attachments) , 
        // always false for 28/30, never present.

        // Version >= 0x10, always true; "== 0x20" always false -> the
        // reference's Int32-then-truncate-to-Int16 path always applies.
        let particleGhostsNum = Int16(truncatingIfNeeded: try cursor.readInt32())
        let ghostSeparation = try cursor.readFloat32()

        // Version >= 0x19 && != 0x20, always true.
        let starRadialPoints = Int16(truncatingIfNeeded: try cursor.readInt32())
        let starRadiusRatio = try cursor.readFloat32()

        // Version >= 0x1A && != 0x20, always true.
        let rampTime = try cursor.readFloat32()

        // Version != 0x20, always true; both inner Version>0x1A/0x1B
        // checks are always true for 28/30.
        let texturePage = try cursor.readInt32()
        let scaleFactor = try cursor.readFloat32()

        // Version >= 0x1E (30), real on-disk data only for the Final
        // build; version 28 (Demo) never stores this, and the reference
        // instead *computes* it here (see `ParticleData.cs:769-782`).
        let unkVec3: SIMD4<Float>
        if isFinal {
            unkVec3 = try cursor.readVector4()
        } else if genSort == ParticleSystemDefinition.GenSort.normal.rawValue {
            let f1 = maxSize * 0.0001
            let x = ((velocity + randomEmitX) * particleLifeTime + randomStartX + f1) * 0.75
            let y = ((velocity + randomEmitY) * particleLifeTime + randomStartY + f1) * 0.75
            let z = ((velocity + randomEmitZ) * particleLifeTime + randomStartZ + f1) * 0.75
            unkVec3 = SIMD4(x, y, z, 0)
        } else {
            unkVec3 = SIMD4(10, 10, 10, 0)
        }

        return ParticleSystemDefinition(
            name: name, genRate: genRate, maxParticleCount: maxParticleCount, unkUShort3: unkUShort3,
            emitterOverTime: emitterOverTime, emitterOverTimeRandom: emitterOverTimeRandom,
            emitterOffTime: emitterOffTime, emitterOffTimeRandom: emitterOffTimeRandom,
            genSort: genSort, unkByte3: unkByte3, textureFilter: textureFilter, unkByte5: unkByte5, unkFloat1: unkFloat1,
            cutOnRadius: cutOnRadius, cutOffRadius: cutOffRadius, drawCutOff: drawCutOff, unkFloat5: unkFloat5, unkFloat6: unkFloat6,
            velocity: velocity, randomEmitX: randomEmitX, randomEmitY: randomEmitY, randomEmitZ: randomEmitZ,
            randomStartX: randomStartX, randomStartY: randomStartY, randomStartZ: randomStartZ,
            unkFloat8: unkFloat8, unkFloat9: unkFloat9, unkFloat10: unkFloat10, unkFloat11: unkFloat11, unkFloat12: unkFloat12, unkFloat13: unkFloat13,
            unkFloat14: unkFloat14, unkFloat15: unkFloat15, unkFloat16: unkFloat16, unkFloat17: unkFloat17, unkFloat18: unkFloat18, unkFloat19: unkFloat19,
            gravity: gravity, particleLifeTime: particleLifeTime, unkUShort8: unkUShort8, unkByte6: unkByte6, unkByte7: unkByte7, unkFloat22: unkFloat22,
            jibberXFreq: jibberXFreq, jibberXAmp: jibberXAmp, jibberYFreq: jibberYFreq, jibberYAmp: jibberYAmp,
            colorGradient: colorGradient, alphaGradientTime: alphaGradient.time, alphaGradientValue: alphaGradient.value,
            distortionX: distortionX, distortionY: distortionY, minSize: minSize, maxSize: maxSize,
            sizeWidthTime: sizeWidth.time, sizeWidthValue: sizeWidth.value, sizeHeightTime: sizeHeight.time, sizeHeightValue: sizeHeight.value,
            minRotation: minRotation, maxRotation: maxRotation, rotationTime: rotation.time, rotationValue: rotation.value,
            unkGradient1Time: unkGradient1.time, unkGradient1Value: unkGradient1.value, unkGradient2Time: unkGradient2.time, unkGradient2Value: unkGradient2.value,
            textureStartX: textureStartX, textureStartY: textureStartY, textureEndX: textureEndX, textureEndY: textureEndY,
            collisionTime: collision.time, collisionValue: collision.value, collisionNumSpheres: collisionNumSpheres, drawFlag: drawFlag,
            padAmount: padAmount, padExtraBytes: padExtraBytes, scaleFactor: scaleFactor, particleGhostsNum: particleGhostsNum, ghostSeparation: ghostSeparation,
            starRadialPoints: starRadialPoints, starRadiusRatio: starRadiusRatio, rampTime: rampTime, texturePage: texturePage, unkVec3: unkVec3
        )
    }

    private static func parseInstance(_ cursor: inout BinaryCursor) throws -> ParticleSystemInstance {
        let px = try cursor.readFloat32()
        let py = try cursor.readFloat32()
        let pz = try cursor.readFloat32()
        let position = SIMD4<Float>(px, py, pz, 1) // W is a hardcoded 1 in the reference, never read from disk.
        // Version >= 0x7, always true for 28/30.
        let gravityRotX = try cursor.readInt16()
        let gravityRotY = try cursor.readInt16()
        let emitRotX = try cursor.readInt16()
        let emitRotY = try cursor.readInt16()
        // Version >= 0x16, always true.
        let unkShort5 = try cursor.readInt16()
        // Version >= 0x08, always true.
        let offset = try cursor.readUInt32()
        let name = try readFixedName(&cursor)
        // Version >= 0x9, always true.
        let switchType = try cursor.readInt32()
        let switchID = try cursor.readInt32()
        let switchValue = try cursor.readFloat32()
        // Version >= 0xC, always true.
        let unkShort6 = try cursor.readInt16()
        let unkShort7 = try cursor.readInt16()
        let planeOffset = try cursor.readFloat32()
        // Version >= 0xD, always true.
        let bounceFactor = try cursor.readFloat32()
        // Version >= 0xF, always true.
        let groupID = try cursor.readInt16()

        return ParticleSystemInstance(
            position: position, gravityRotX: gravityRotX, gravityRotY: gravityRotY, emitRotX: emitRotX, emitRotY: emitRotY,
            unkShort5: unkShort5, offset: offset, name: name, switchType: switchType, switchID: switchID, switchValue: switchValue,
            unkShort6: unkShort6, unkShort7: unkShort7, planeOffset: planeOffset, bounceFactor: bounceFactor, groupID: groupID
        )
    }
}
