import Foundation

/// A decoded `ParticleData` record (`RM2Parser` top-level sub-ID 8) , 
/// ported field-for-field from `Twinsanity/Items/ParticleData.cs`'s
/// `Load`. Field names and behavior comments are the reference tool's
/// own, a genuinely unusual amount of this format *is* named and
/// understood (`Velocity`, `Gravity`, `JibberXFreq`, per-`GenSort`
/// semantics in the reference's own inline comments), not just `Unk`
/// placeholders; kept verbatim rather than paraphrased, since the exact
/// wording is the verified fact here.
///
/// This format is real-number-of-fields-per-record *version-gated*, the
/// reference's own version table names the versions that actually shipped:
/// TWOC proto (9/10), TWOC (11/13/15), Twins Proto (21), Nemo (26),
/// **Twins Demo/some Final PTL files (28)**, **Twins Final/SMBA (30)**,
/// LSW/Narnia (34). Only the two bolded versions are real, shipped Crash
/// Twinsanity data, every other version belongs to a different TT-era
/// game or an internal prototype this codebase has no reference disc for,
/// so (matching this codebase's "only decode what's verified" rule used
/// throughout, e.g. `SoundBankParser`'s stereo-not-attempted stance)
/// `ParticleDataParser` only handles 28 and 30, falling back to `.raw`
/// for anything else rather than guessing at an unverified layout.
public struct ParticleDataAsset: Sendable, Identifiable {
    public let id: UInt32
    public var version: UInt32
    /// "Default.rm2 has a pre-header: 3x (texture ID + material ID), plus a
    /// trailing decal texture/material ID pair after the instance list" , 
    /// real on-disk layout, but this build's model doesn't capture those
    /// extra fields (unlike every other real field here), so `canWriteBack`
    /// is `false` whenever this is `true`: write-back would either drop
    /// real data or have to guess at it, and this codebase never does
    /// either.
    public var isDefault: Bool
    public var particleTypes: [ParticleSystemDefinition]
    public var particleInstances: [ParticleSystemInstance]
    /// The real on-disk instance-count field (`instanceCheck` in the
    /// reference), captured whenever the parser actually read one, `nil`
    /// only when the record ended right after its type definitions (the
    /// parser's own early-return case, `cursor.position == startPosition +
    /// size`), which never has this field at all.
    ///
    /// Kept distinct from `particleInstances.count`: the reference only
    /// populates `particleInstances` when this raw count is nonzero and
    /// `< 65536` (and the record isn't `isDefault`), a `0` or
    /// out-of-range value here is itself real on-disk data (an explicit
    /// "no instances" marker, or something else this build doesn't
    /// interpret), not an artifact to discard. Write-back always emits
    /// this raw value verbatim, never re-derives it from
    /// `particleInstances.count`.
    public var instanceSectionRawCount: UInt32?
    /// Real trailing "Remain" bytes past the last parsed field, up to the
    /// record's declared size, captured (not discarded) so a write-back
    /// round trip never silently drops real on-disk data.
    public var trailingBytes: Data

    public init(id: UInt32, version: UInt32, isDefault: Bool, particleTypes: [ParticleSystemDefinition], particleInstances: [ParticleSystemInstance], instanceSectionRawCount: UInt32?, trailingBytes: Data) {
        self.id = id
        self.version = version
        self.isDefault = isDefault
        self.particleTypes = particleTypes
        self.particleInstances = particleInstances
        self.instanceSectionRawCount = instanceSectionRawCount
        self.trailingBytes = trailingBytes
    }

    /// `false` for `isDefault` records (see above), the only case this
    /// build's write path refuses.
    public var canWriteBack: Bool { !isDefault }
}

/// `ParticleSystemDefinition`, one named particle-effect "recipe" (spawn
/// rate, velocity, gravity, color/alpha/size/rotation gradients, optional
/// ground collision spheres, ...). Ported field-for-field; every doc
/// comment below is transcribed from the reference source's own inline
/// comments, not written fresh for this port.
public struct ParticleSystemDefinition: Sendable {
    public enum GenSort: UInt8, Sendable {
        case normal = 0 // emit from point
        case unk1 = 1
        case unk2 = 2
        case unk3 = 3
        case unk4 = 4
        case unk5 = 5
        case radial = 0x06 // emit from flat sphere
        case radialRotor = 0x07 // emit from rotating sphere
        case spheroid = 0x08
        case bounceY = 0x09
        case bounceXZ = 0x0A
        case improvedRadial = 0x0B
        case starRadial = 0x0C
    }

    public enum TextureFiltering: UInt8, Sendable {
        case additive = 0
        case unknown = 1
        case modulation = 0x02
        case subtractive = 0x03
        case unk4 = 0x04
        case unk5 = 0x05
        case unk6 = 0x06
        case glass = 0x07 // only allowed in GenSort .normal? proto or newer
    }

    public enum DrawFlags: UInt8, Sendable {
        case afterFog = 0
        case beforeFog = 1
        case glassRelated = 2
        case superEarly = 3
    }

    public var name: String
    public var genRate: Int16 // Multiplier
    public var maxParticleCount: UInt16
    public var unkUShort3: UInt16 // always 0
    public var emitterOverTime: UInt16
    public var emitterOverTimeRandom: UInt16
    public var emitterOffTime: UInt16
    public var emitterOffTimeRandom: UInt16
    public var genSort: UInt8 // raw, see `resolvedGenSort` for the named enum, when the value is one this reference actually defines
    public var unkByte3: UInt8 // always 0, maybe GenCode enum?
    public var textureFilter: UInt8 // raw, see `resolvedTextureFilter`
    public var unkByte5: UInt8 // always 0
    public var unkFloat1: Float // always 25? always 40000 in proto/twoc?
    public var cutOnRadius: Float // distance at which particles start emitting
    public var cutOffRadius: Float // distance at which particles stop emitting
    public var drawCutOff: Float // draw distance
    public var unkFloat5: Float
    public var unkFloat6: Float
    public var velocity: Float // towards instance emit direction
    /// velocity on x axis (both sides). GSort Radial: random start distance from Base Mag.
    public var randomEmitX: Float
    /// velocity on y axis (both sides). GSort Radial: 0–180 random starting point around sphere; Radial Rotor: -90–90 rotation speed of sphere around sphere ((X / 65535) * 360).
    public var randomEmitY: Float
    /// velocity on z axis (both sides). GSort Radial: 0–180 random starting point on angle (top to bottom); Radial Rotor: -90–90 rotation speed of sphere on angle (top to bottom) ((X / 65535) * 360).
    public var randomEmitZ: Float
    /// spawn point on x axis (both sides). GSort Radial: start distance from center of sphere.
    public var randomStartX: Float
    /// spawn point on y axis (both sides). GSort Radial: -180–180 starting point around sphere ((X / 65535) * 360).
    public var randomStartY: Float
    /// spawn point on z axis (both sides). GSort Radial: -180–0 starting point on angle (top to bottom) ((X / 65535) * 360).
    public var randomStartZ: Float
    public var unkFloat8: Float
    public var unkFloat9: Float
    public var unkFloat10: Float
    public var unkFloat11: Float
    public var unkFloat12: Float
    public var unkFloat13: Float
    public var unkFloat14: Float
    public var unkFloat15: Float
    public var unkFloat16: Float
    public var unkFloat17: Float
    public var unkFloat18: Float
    public var unkFloat19: Float
    public var gravity: Float // positive value: particle goes up
    public var particleLifeTime: Float
    public var unkUShort8: UInt16 // usually 0 or 16
    public var unkByte6: UInt8 // usually 0 or 1
    public var unkByte7: UInt8 // usually 1 or 3
    public var unkFloat22: Float // usually 0 or 320
    public var jibberXFreq: Float // particle vibration speed on X axis
    public var jibberXAmp: Float // particle vibration distance on X axis
    public var jibberYFreq: Float // particle vibration speed on Y axis
    public var jibberYAmp: Float // particle vibration distance on Y axis
    public var colorGradient: [SIMD4<Float>] // 8 entries: time 0–1 / RGB 0–255
    public var alphaGradientTime: [Float] // 8 entries
    public var alphaGradientValue: [Float] // 8 entries (0–255); for glass, a distortion gradient instead
    public var distortionX: Float // glass only?
    public var distortionY: Float
    public var minSize: Float
    public var maxSize: Float
    public var sizeWidthTime: [Float] // 8 entries
    public var sizeWidthValue: [Float] // 8 entries
    public var sizeHeightTime: [Float] // 8 entries
    public var sizeHeightValue: [Float] // 8 entries
    public var minRotation: Float
    public var maxRotation: Float
    public var rotationTime: [Float] // 8 entries
    public var rotationValue: [Float] // 8 entries, 32767 == 180deg; (X / 65535) * 360
    public var unkGradient1Time: [Float] // 8 entries
    public var unkGradient1Value: [Float] // 8 entries
    public var unkGradient2Time: [Float] // 8 entries
    public var unkGradient2Value: [Float] // 8 entries
    public var textureStartX: Float
    public var textureStartY: Float
    public var textureEndX: Float
    public var textureEndY: Float
    public var collisionTime: [Float] // 8 entries
    public var collisionValue: [Float] // 8 entries, size of the biggest collision sphere
    /// (0–8). Non-zero creates a hollow sphere from the emit point that
    /// grows per the gradient then resets to the min point; more spheres
    /// create more spheres at halfway size/position of the next bigger
    /// one; collision deals damage and travels toward the emit direction
    /// at `velocity` (ignoring the random emit/start values?).
    public var collisionNumSpheres: UInt8
    public var drawFlag: UInt8 // raw, see `resolvedDrawFlag`
    /// Present only for version 28 (Demo), real on-disk padding, `padAmount * 24` bytes.
    public var padAmount: Int32
    /// The real `padAmount * 24` padding bytes themselves, captured (not
    /// discarded) purely so a write-back round trip never has to guess at
    /// real on-disk bytes it can't otherwise reconstruct. Always empty when
    /// `padAmount == 0`, which is the common case.
    public var padExtraBytes: Data
    /// Present for versions > 0x1B, scales the particles.
    public var scaleFactor: Float
    public var particleGhostsNum: Int16
    public var ghostSeparation: Float
    public var starRadialPoints: Int16 // default 5
    public var starRadiusRatio: Float // default 0.5
    public var rampTime: Float // time to ramp up radial emit shape to full size
    public var texturePage: Int32 // 0–2
    /// Present on disk only for version 30 (Final), for version 28
    /// (Demo) this is a *computed*, not stored, value (see
    /// `ParticleData.cs:769-782`); this port replicates that same
    /// computation for version 28 rather than treating it as real
    /// on-disk data for that version. W is always 0.
    public var unkVec3: SIMD4<Float>

    public init(
        name: String, genRate: Int16, maxParticleCount: UInt16, unkUShort3: UInt16,
        emitterOverTime: UInt16, emitterOverTimeRandom: UInt16, emitterOffTime: UInt16, emitterOffTimeRandom: UInt16,
        genSort: UInt8, unkByte3: UInt8, textureFilter: UInt8, unkByte5: UInt8, unkFloat1: Float,
        cutOnRadius: Float, cutOffRadius: Float, drawCutOff: Float, unkFloat5: Float, unkFloat6: Float,
        velocity: Float, randomEmitX: Float, randomEmitY: Float, randomEmitZ: Float,
        randomStartX: Float, randomStartY: Float, randomStartZ: Float,
        unkFloat8: Float, unkFloat9: Float, unkFloat10: Float, unkFloat11: Float, unkFloat12: Float, unkFloat13: Float,
        unkFloat14: Float, unkFloat15: Float, unkFloat16: Float, unkFloat17: Float, unkFloat18: Float, unkFloat19: Float,
        gravity: Float, particleLifeTime: Float, unkUShort8: UInt16, unkByte6: UInt8, unkByte7: UInt8, unkFloat22: Float,
        jibberXFreq: Float, jibberXAmp: Float, jibberYFreq: Float, jibberYAmp: Float,
        colorGradient: [SIMD4<Float>], alphaGradientTime: [Float], alphaGradientValue: [Float],
        distortionX: Float, distortionY: Float, minSize: Float, maxSize: Float,
        sizeWidthTime: [Float], sizeWidthValue: [Float], sizeHeightTime: [Float], sizeHeightValue: [Float],
        minRotation: Float, maxRotation: Float, rotationTime: [Float], rotationValue: [Float],
        unkGradient1Time: [Float], unkGradient1Value: [Float], unkGradient2Time: [Float], unkGradient2Value: [Float],
        textureStartX: Float, textureStartY: Float, textureEndX: Float, textureEndY: Float,
        collisionTime: [Float], collisionValue: [Float], collisionNumSpheres: UInt8, drawFlag: UInt8,
        padAmount: Int32, padExtraBytes: Data, scaleFactor: Float, particleGhostsNum: Int16, ghostSeparation: Float,
        starRadialPoints: Int16, starRadiusRatio: Float, rampTime: Float, texturePage: Int32, unkVec3: SIMD4<Float>
    ) {
        self.name = name
        self.genRate = genRate
        self.maxParticleCount = maxParticleCount
        self.unkUShort3 = unkUShort3
        self.emitterOverTime = emitterOverTime
        self.emitterOverTimeRandom = emitterOverTimeRandom
        self.emitterOffTime = emitterOffTime
        self.emitterOffTimeRandom = emitterOffTimeRandom
        self.genSort = genSort
        self.unkByte3 = unkByte3
        self.textureFilter = textureFilter
        self.unkByte5 = unkByte5
        self.unkFloat1 = unkFloat1
        self.cutOnRadius = cutOnRadius
        self.cutOffRadius = cutOffRadius
        self.drawCutOff = drawCutOff
        self.unkFloat5 = unkFloat5
        self.unkFloat6 = unkFloat6
        self.velocity = velocity
        self.randomEmitX = randomEmitX
        self.randomEmitY = randomEmitY
        self.randomEmitZ = randomEmitZ
        self.randomStartX = randomStartX
        self.randomStartY = randomStartY
        self.randomStartZ = randomStartZ
        self.unkFloat8 = unkFloat8
        self.unkFloat9 = unkFloat9
        self.unkFloat10 = unkFloat10
        self.unkFloat11 = unkFloat11
        self.unkFloat12 = unkFloat12
        self.unkFloat13 = unkFloat13
        self.unkFloat14 = unkFloat14
        self.unkFloat15 = unkFloat15
        self.unkFloat16 = unkFloat16
        self.unkFloat17 = unkFloat17
        self.unkFloat18 = unkFloat18
        self.unkFloat19 = unkFloat19
        self.gravity = gravity
        self.particleLifeTime = particleLifeTime
        self.unkUShort8 = unkUShort8
        self.unkByte6 = unkByte6
        self.unkByte7 = unkByte7
        self.unkFloat22 = unkFloat22
        self.jibberXFreq = jibberXFreq
        self.jibberXAmp = jibberXAmp
        self.jibberYFreq = jibberYFreq
        self.jibberYAmp = jibberYAmp
        self.colorGradient = colorGradient
        self.alphaGradientTime = alphaGradientTime
        self.alphaGradientValue = alphaGradientValue
        self.distortionX = distortionX
        self.distortionY = distortionY
        self.minSize = minSize
        self.maxSize = maxSize
        self.sizeWidthTime = sizeWidthTime
        self.sizeWidthValue = sizeWidthValue
        self.sizeHeightTime = sizeHeightTime
        self.sizeHeightValue = sizeHeightValue
        self.minRotation = minRotation
        self.maxRotation = maxRotation
        self.rotationTime = rotationTime
        self.rotationValue = rotationValue
        self.unkGradient1Time = unkGradient1Time
        self.unkGradient1Value = unkGradient1Value
        self.unkGradient2Time = unkGradient2Time
        self.unkGradient2Value = unkGradient2Value
        self.textureStartX = textureStartX
        self.textureStartY = textureStartY
        self.textureEndX = textureEndX
        self.textureEndY = textureEndY
        self.collisionTime = collisionTime
        self.collisionValue = collisionValue
        self.collisionNumSpheres = collisionNumSpheres
        self.drawFlag = drawFlag
        self.padAmount = padAmount
        self.padExtraBytes = padExtraBytes
        self.scaleFactor = scaleFactor
        self.particleGhostsNum = particleGhostsNum
        self.ghostSeparation = ghostSeparation
        self.starRadialPoints = starRadialPoints
        self.starRadiusRatio = starRadiusRatio
        self.rampTime = rampTime
        self.texturePage = texturePage
        self.unkVec3 = unkVec3
    }

    public var resolvedGenSort: GenSort? { GenSort(rawValue: genSort) }
    public var resolvedTextureFilter: TextureFiltering? { TextureFiltering(rawValue: textureFilter) }
    public var resolvedDrawFlag: DrawFlags? { DrawFlags(rawValue: drawFlag) }
}

/// `ParticleSystemInstance`, one placement of a named `ParticleSystemDefinition` in the world.
public struct ParticleSystemInstance: Sendable {
    public var position: SIMD4<Float>
    public var gravityRotX: Int16
    public var gravityRotY: Int16
    public var emitRotX: Int16
    public var emitRotY: Int16
    public var unkShort5: Int16
    public var offset: UInt32
    public var name: String
    public var switchType: Int32 // 0 = none, 1 = global switch
    public var switchID: Int32 // default -1, range -1...128
    public var switchValue: Float // 0.0...20.0
    public var unkShort6: Int16
    public var unkShort7: Int16
    public var planeOffset: Float // -28.0...28.0
    public var bounceFactor: Float // 0.0...2.0, default 0.9
    public var groupID: Int16 // 0...32

    public init(
        position: SIMD4<Float>, gravityRotX: Int16, gravityRotY: Int16, emitRotX: Int16, emitRotY: Int16,
        unkShort5: Int16, offset: UInt32, name: String, switchType: Int32, switchID: Int32, switchValue: Float,
        unkShort6: Int16, unkShort7: Int16, planeOffset: Float, bounceFactor: Float, groupID: Int16
    ) {
        self.position = position
        self.gravityRotX = gravityRotX
        self.gravityRotY = gravityRotY
        self.emitRotX = emitRotX
        self.emitRotY = emitRotY
        self.unkShort5 = unkShort5
        self.offset = offset
        self.name = name
        self.switchType = switchType
        self.switchID = switchID
        self.switchValue = switchValue
        self.unkShort6 = unkShort6
        self.unkShort7 = unkShort7
        self.planeOffset = planeOffset
        self.bounceFactor = bounceFactor
        self.groupID = groupID
    }
}
