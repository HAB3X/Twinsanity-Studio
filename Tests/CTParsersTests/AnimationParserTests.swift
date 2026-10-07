import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class AnimationParserTests: XCTestCase {
    func testParsesBodyTrackAndSkipsEmptyFacialTrack() throws {
        var w = BinaryWriter()

        // Leading `Bitfield: UInt32` (`Animation.cs:12,78`), read once,
        // before the body track's own packer, and never repeated for the
        // facial track. Its value is opaque/unused by this parser; any
        // value proves it's being consumed rather than shifting every
        // following field 4 bytes early.
        w.writeUInt32(0xDEADBEEF)

        // Body packer: joints=1 (bits[0:7)), transformations=1 i.e. raw*2=2
        // (bits[10:22)), componentsPerFrame=2 (bits[22:32)).
        let joints: UInt32 = 1
        let transformationsRaw: UInt32 = 2 // encodes `transformations * 2`
        let componentsPerFrame: UInt32 = 2
        let bodyPacker = joints | (transformationsRaw << 0xA) | (componentsPerFrame << 0x16)
        w.writeUInt32(bodyPacker)
        w.writeUInt16(3) // totalFrames

        // JointSettings[1]
        w.writeUInt16(0x0001); w.writeUInt16(0x0002); w.writeUInt16(0x0003); w.writeUInt16(0x0004)
        // StaticTransforms[1]
        w.writeInt16(4096) // -> linearValue 1.0
        // AnimatedTransforms[3], 2 components each
        w.writeInt16(100); w.writeInt16(200)
        w.writeInt16(300); w.writeInt16(400)
        w.writeInt16(-4096); w.writeInt16(0)

        // Facial: packer=0, totalFrames=0 -> dataSize computes to 0, no further bytes read.
        w.writeUInt32(0)
        w.writeUInt16(0)

        var cursor = BinaryCursor(data: w.data)
        let animation = try AnimationParser.parse(&cursor, recordID: 9)

        XCTAssertEqual(animation.body.jointSettings.count, 1)
        XCTAssertEqual(animation.body.jointSettings[0].animatedTransformIndex, 0x0004)
        XCTAssertEqual(animation.body.staticTransforms.count, 1)
        XCTAssertEqual(animation.body.staticTransforms[0].linearValue, 1.0, accuracy: 0.0001)
        XCTAssertEqual(animation.body.totalFrames, 3)
        XCTAssertEqual(animation.body.componentsPerFrame, 2)
        XCTAssertEqual(animation.body.frames[0].values, [100, 200])
        XCTAssertEqual(animation.body.frames[2].linearValue(at: 0), -1.0, accuracy: 0.0001)

        XCTAssertEqual(animation.facial.totalFrames, 0)
        XCTAssertTrue(animation.facial.jointSettings.isEmpty)
    }
}

/// Regression for a real, confirmed bug: `AnimStaticTransform.rotationRadians`
/// divided by `Float(UInt16.max &+ 1)`, Swift's `&+` wraps *within*
/// `UInt16` (no automatic promotion to a wider type the way C#'s
/// `ushort.MaxValue + 1` gets promoted to `int`), so `65535 &+ 1` silently
/// overflowed to `0`, turning every nonzero static rotation value into a
/// division by zero. `simd_quatf(angle: .infinity, ...)`'s `sin`/`cos` of
/// an infinite angle is NaN, poisoning that joint's rotation and, through
/// `AnimationSkeletonBinding`'s parent-chain composition, every one of its
/// descendants too, for any joint whose rotation channel happened to be in
/// the static/frame-invariant pool rather than the per-frame animated one
/// (which real game data does constantly). This was very likely the actual
/// root cause of "animation playback distorts the model and it doesn't
/// move": a NaN-poisoned pose looks identical every frame regardless of
/// which frame's otherwise-genuinely-varying data feeds it.
final class AnimStaticTransformRotationTests: XCTestCase {
    func testRotationRadiansIsFiniteForNonzeroStoredValue() {
        // A real, plausible on-disk value, not zero (which would have
        // masked the bug: 0/anything is still 0, not Infinity).
        let transform = AnimStaticTransform(stored: 1024)
        XCTAssertTrue(transform.rotationRadians.isFinite, "rotationRadians must never be Infinity/NaN for a normal stored value")
    }

    func testRotationRadiansMatchesHandComputedValue() {
        // (1024 * 16) / 65536 * 2π = 0.25 * 2π = π/2, same fixed-point
        // scale already verified for the per-frame animated path
        // (AnimationSkeletonBindingTests.testLocalPoseAllAnimatedChannels
        // uses the identical raw value or 90°).
        let transform = AnimStaticTransform(stored: 1024)
        XCTAssertEqual(transform.rotationRadians, .pi / 2, accuracy: 0.0001)
    }

    func testRotationRadiansAtFullRangeStillFinite() {
        // The exact boundary value that exposed the bug: Int16.max is the
        // largest magnitude `stored` can hold, maximizing the numerator
        // and therefore how far a division-by-zero bug would diverge.
        let transform = AnimStaticTransform(stored: Int16.max)
        XCTAssertTrue(transform.rotationRadians.isFinite)
        let negative = AnimStaticTransform(stored: Int16.min)
        XCTAssertTrue(negative.rotationRadians.isFinite)
    }
}
