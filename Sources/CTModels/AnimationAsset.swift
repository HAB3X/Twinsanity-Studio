import Foundation

/// Per-joint indirection into either the static-value pool or the per-frame
/// animated-column pool (`Animation.JointSettings`,
/// `Twinsanity/Items/Code/Animation.cs:139-162`).
public struct AnimJointSettings: Sendable, Codable {
    public var flags: UInt16
    public var transformationChoice: UInt16
    public var transformationIndex: UInt16
    public var animatedTransformIndex: UInt16

    public init(flags: UInt16, transformationChoice: UInt16, transformationIndex: UInt16, animatedTransformIndex: UInt16) {
        self.flags = flags
        self.transformationChoice = transformationChoice
        self.transformationIndex = transformationIndex
        self.animatedTransformIndex = animatedTransformIndex
    }
}

/// A single fixed-point value shared by every frame (a joint that doesn't
/// animate on this channel). Translation/scale decode as Q12 fixed point
/// (`/ 4096`); rotation decodes on a different fixed-point scale mapping the
/// full `int16` range to one full turn (`Animation.Transformation.RotValue`,
/// `Animation.cs:180-186`).
public struct AnimStaticTransform: Sendable, Codable {
    public var stored: Int16

    public init(stored: Int16) {
        self.stored = stored
    }

    public var linearValue: Float { Float(stored) / 4096.0 }
    /// Real, previously-broken bug: `UInt16.max &+ 1` performs *wrapping*
    /// addition within `UInt16` itself (Swift has no automatic integer
    /// promotion the way C#'s `ushort.MaxValue + 1` gets promoted to `int`
    /// before adding), `65535 &+ 1` overflows to `0`, not `65536`,
    /// silently turning this into a division by zero. Any nonzero `stored`
    /// value then produced `±Infinity` radians, and `simd_quatf(angle:
    /// .infinity, ...)`'s `sin`/`cos` of an infinite angle is `NaN` , 
    /// poisoning that joint's rotation, and by extension (through the
    /// parent-chain composition in `AnimationSkeletonBinding.
    /// animatedWorldTransforms`) every one of its descendants too, for
    /// every joint whose rotation channel happened to be in this
    /// "static/frame-invariant" pool rather than the per-frame animated
    /// one, which real data does constantly (a joint that doesn't rotate
    /// on a given clip still gets a `Transformation` entry here, not a
    /// zero). This is likely the actual root cause of "animation playback
    /// distorts/scrunches the model and it doesn't move": a `NaN`-poisoned
    /// pose is identical every frame (`NaN` in, `NaN` out, regardless of
    /// which frame's translation/scale data is otherwise genuinely
    /// varying), reading as "frozen in a broken shape."
    public var rotationRadians: Float {
        (Float(stored) * 16) / (Float(UInt16.max) + 1) * .pi * 2
    }
}

/// One animated frame's flat channel row (`Animation.AnimatedTransform`). Each
/// joint's actual per-frame value is `values[jointSettings.animatedTransformIndex]`.
public struct AnimFrame: Sendable, Codable {
    public var values: [Int16]

    public init(values: [Int16]) {
        self.values = values
    }

    // `index` ultimately traces back to a raw on-disk `animatedTransformIndex`
    // (see this type's own doc comment) -- both current call sites already
    // guard before calling this, but it's public API, so a future caller
    // that doesn't guard gets a safe fallback instead of a crash on a
    // corrupt/truncated animation file.
    public func linearValue(at index: Int) -> Float {
        guard values.indices.contains(index) else { return 0 }
        return Float(values[index]) / 4096.0
    }
}

/// One of the two independent curve sets in an `Animation` record (body,
/// facial), see `Animation.cs:12-22`.
public struct AnimationTrack: Sendable, Codable {
    public var jointSettings: [AnimJointSettings]
    public var staticTransforms: [AnimStaticTransform]
    public var frames: [AnimFrame]
    public var componentsPerFrame: Int
    /// Bits 7–10 of this track's own packer word (`AnimationDataPacker`/
    /// `FacialAnimationDataPacker`), 4 real bits the reference's own
    /// `Animation.Save` deliberately never clears/reassigns (its three
    /// `AnimationDataPacker &= ~(...)` masks cover bits 0–6, 11–21, and
    /// 22–31, leaving exactly these 4 bits carried through from whatever
    /// was loaded). No confirmed meaning, kept purely so a write-back
    /// round-trips byte-exact instead of silently zeroing 4 real bits of
    /// every animation this build ever saves.
    public var reservedPackerBits: UInt32

    public init(jointSettings: [AnimJointSettings], staticTransforms: [AnimStaticTransform], frames: [AnimFrame], componentsPerFrame: Int, reservedPackerBits: UInt32 = 0) {
        self.jointSettings = jointSettings
        self.staticTransforms = staticTransforms
        self.frames = frames
        self.componentsPerFrame = componentsPerFrame
        self.reservedPackerBits = reservedPackerBits
    }

    public var totalFrames: Int { frames.count }

    private enum CodingKeys: String, CodingKey {
        case jointSettings, staticTransforms, frameValues, componentsPerFrame, reservedPackerBits
    }

    /// Custom `Codable`, same reasoning and pattern as `MeshSubmesh`'s (see
    /// that type's own doc comment): the synthesized conformance wraps
    /// every one of potentially hundreds of `AnimFrame`s, each itself an
    /// unkeyed container of dozens of `Int16` channel values, in its own
    /// container, and `jointSettings`/`staticTransforms` get the same
    /// per-element treatment. At full-archive-scan scale, with every
    /// resolved skinned character redundantly carrying a full copy of
    /// *every* animation in its file (`ResolvedModelAsset.
    /// availableAnimations`), this reproduced the exact "ScanCache balloons
    /// to gigabytes, decoding it back hangs the app" incident a first
    /// Codable-bloat fix (`MeshSubmesh`'s joint weights) had already fixed
    /// once for a different field, a second, larger instance of the same
    /// root cause, not a new bug. `frames` flattens to one `Data` blob of
    /// `frameCount * componentsPerFrame` `Int16` values (row-major, one
    /// frame's values contiguous) since every frame has exactly
    /// `componentsPerFrame` values; frame count is recovered from the
    /// blob's own byte length on decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        componentsPerFrame = try container.decode(Int.self, forKey: .componentsPerFrame)
        reservedPackerBits = try container.decode(UInt32.self, forKey: .reservedPackerBits)

        let jointSettingsRaw = try container.decode(Data.self, forKey: .jointSettings).withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        var decodedJointSettings: [AnimJointSettings] = []
        decodedJointSettings.reserveCapacity(jointSettingsRaw.count / 4)
        for i in 0..<(jointSettingsRaw.count / 4) {
            decodedJointSettings.append(AnimJointSettings(
                flags: jointSettingsRaw[i * 4],
                transformationChoice: jointSettingsRaw[i * 4 + 1],
                transformationIndex: jointSettingsRaw[i * 4 + 2],
                animatedTransformIndex: jointSettingsRaw[i * 4 + 3]
            ))
        }
        jointSettings = decodedJointSettings

        let staticRaw = try container.decode(Data.self, forKey: .staticTransforms).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        staticTransforms = staticRaw.map { AnimStaticTransform(stored: $0) }

        let frameValuesRaw = try container.decode(Data.self, forKey: .frameValues).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        var decodedFrames: [AnimFrame] = []
        if componentsPerFrame > 0 {
            decodedFrames.reserveCapacity(frameValuesRaw.count / componentsPerFrame)
            var index = 0
            while index + componentsPerFrame <= frameValuesRaw.count {
                decodedFrames.append(AnimFrame(values: Array(frameValuesRaw[index..<(index + componentsPerFrame)])))
                index += componentsPerFrame
            }
        }
        frames = decodedFrames
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(componentsPerFrame, forKey: .componentsPerFrame)
        try container.encode(reservedPackerBits, forKey: .reservedPackerBits)

        var jointSettingsFlat: [UInt16] = []
        jointSettingsFlat.reserveCapacity(jointSettings.count * 4)
        for j in jointSettings { jointSettingsFlat.append(contentsOf: [j.flags, j.transformationChoice, j.transformationIndex, j.animatedTransformIndex]) }
        try container.encode(jointSettingsFlat.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .jointSettings)

        let staticFlat = staticTransforms.map(\.stored)
        try container.encode(staticFlat.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .staticTransforms)

        var frameValuesFlat: [Int16] = []
        frameValuesFlat.reserveCapacity(frames.count * componentsPerFrame)
        for frame in frames { frameValuesFlat.append(contentsOf: frame.values) }
        try container.encode(frameValuesFlat.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .frameValues)
    }
}

/// A fully decoded `Animation` record: body + facial tracks.
public struct AnimationAsset: Sendable, Identifiable, Codable {
    public let id: UInt32
    /// The record's real leading 4-byte field (`Animation.Bitfield`), no
    /// confirmed meaning anywhere in the reference tool either (written
    /// back verbatim there, never interpreted), kept here purely so
    /// `AnimationWriter` can round-trip it instead of zeroing it.
    public var bitfield: UInt32
    public var body: AnimationTrack
    public var facial: AnimationTrack

    public init(id: UInt32, bitfield: UInt32 = 0, body: AnimationTrack, facial: AnimationTrack) {
        self.id = id
        self.bitfield = bitfield
        self.body = body
        self.facial = facial
    }
}
