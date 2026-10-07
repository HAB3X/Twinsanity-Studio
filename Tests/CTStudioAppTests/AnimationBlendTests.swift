import XCTest
import simd
@testable import CTModels
@testable import CTStudioApp

/// Verifies `AnimationSkeletonBinding.blendedWorldTransforms`/
/// `blendedSkinningMatrices` (roadmap 12.2), real per-joint
/// translation/scale lerp + rotation slerp between two independently
/// chosen (track, frame) points.
final class AnimationBlendTests: XCTestCase {
    /// A minimal single-joint skeleton, same shape
    /// `AnimationSkeletonBindingTests` already uses, an identity bind pose
    /// so the joint's *animated* world transform equals its local one
    /// directly (nothing else composing in).
    private func makeSingleJointSkeleton() -> SkeletonAsset {
        let identityMatrix: [SIMD4<Float>] = [
            .zero, // [0] bind translation = 0
            .zero,
            SIMD4(0, 0, 0, 1), // [2] identity rotation
            .zero,
            SIMD4(0, 0, 0, 1), // [4] identity add-rotation
        ]
        let joint = Joint(reactJointID: 0, jointIndex: 0, parentJointIndex: 0, childJointAmount: 0, childJointAmount2: 0, matrix: identityMatrix)
        return SkeletonAsset(id: 1, joints: [joint], exitPoints: [], skinTransforms: [], skinID: 0, blendSkinID: 0, modelLinks: [])
    }

    /// All-animated-channel track (same convention as `AnimationSkeletonBindingTests`)
    /// with a single frame whose translation is `(x, y, z)`, everything else
    /// zero/identity.
    private func makeTrack(translation: SIMD3<Float>) -> AnimationTrack {
        let settings = AnimJointSettings(flags: 0, transformationChoice: 0, transformationIndex: 0, animatedTransformIndex: 0)
        // Reference values are stored /4096 and X is negated on read, so
        // negate here up front to land on the exact requested translation.
        let x = Int16(-translation.x * 4096)
        let y = Int16(translation.y * 4096)
        let z = Int16(translation.z * 4096)
        let frame = AnimFrame(values: [x, y, z, 0, 0, 0, 4096, 4096, 4096])
        return AnimationTrack(jointSettings: [settings], staticTransforms: [], frames: [frame], componentsPerFrame: 9)
    }

    func testBlendAtZeroMatchesPoseAExactly() {
        let skeleton = makeSingleJointSkeleton()
        let trackA = makeTrack(translation: SIMD3(1, 2, 3))
        let trackB = makeTrack(translation: SIMD3(5, 6, 7))

        let transforms = AnimationSkeletonBinding.blendedWorldTransforms(skeleton: skeleton, trackA: trackA, frameA: 0, trackB: trackB, frameB: 0, t: 0)
        let world = try! XCTUnwrap(transforms[0])
        XCTAssertEqual(world.columns.3.x, 1, accuracy: 0.001)
        XCTAssertEqual(world.columns.3.y, 2, accuracy: 0.001)
        XCTAssertEqual(world.columns.3.z, 3, accuracy: 0.001)
    }

    func testBlendAtOneMatchesPoseBExactly() {
        let skeleton = makeSingleJointSkeleton()
        let trackA = makeTrack(translation: SIMD3(1, 2, 3))
        let trackB = makeTrack(translation: SIMD3(5, 6, 7))

        let transforms = AnimationSkeletonBinding.blendedWorldTransforms(skeleton: skeleton, trackA: trackA, frameA: 0, trackB: trackB, frameB: 0, t: 1)
        let world = try! XCTUnwrap(transforms[0])
        XCTAssertEqual(world.columns.3.x, 5, accuracy: 0.001)
        XCTAssertEqual(world.columns.3.y, 6, accuracy: 0.001)
        XCTAssertEqual(world.columns.3.z, 7, accuracy: 0.001)
    }

    func testBlendAtHalfIsTheMidpoint() {
        let skeleton = makeSingleJointSkeleton()
        let trackA = makeTrack(translation: SIMD3(0, 0, 0))
        let trackB = makeTrack(translation: SIMD3(4, 5, 6))

        let transforms = AnimationSkeletonBinding.blendedWorldTransforms(skeleton: skeleton, trackA: trackA, frameA: 0, trackB: trackB, frameB: 0, t: 0.5)
        let world = try! XCTUnwrap(transforms[0])
        XCTAssertEqual(world.columns.3.x, 2, accuracy: 0.001)
        XCTAssertEqual(world.columns.3.y, 2.5, accuracy: 0.001)
        XCTAssertEqual(world.columns.3.z, 3, accuracy: 0.001)
    }

    func testBlendFactorIsClampedToZeroOneRange() {
        let skeleton = makeSingleJointSkeleton()
        let trackA = makeTrack(translation: SIMD3(0, 0, 0))
        let trackB = makeTrack(translation: SIMD3(6, 0, 0))

        let belowZero = AnimationSkeletonBinding.blendedWorldTransforms(skeleton: skeleton, trackA: trackA, frameA: 0, trackB: trackB, frameB: 0, t: -5)
        let aboveOne = AnimationSkeletonBinding.blendedWorldTransforms(skeleton: skeleton, trackA: trackA, frameA: 0, trackB: trackB, frameB: 0, t: 5)
        XCTAssertEqual(try! XCTUnwrap(belowZero[0]).columns.3.x, 0, accuracy: 0.001)
        XCTAssertEqual(try! XCTUnwrap(aboveOne[0]).columns.3.x, 6, accuracy: 0.001)
    }

    /// Blending between two 90°-apart rotations at the midpoint should
    /// land at 45°, a real slerp check, not just "some value between."
    func testRotationBlendsViaSlerpNotLinearInterpolation() {
        let skeleton = makeSingleJointSkeleton()
        let settingsA = AnimJointSettings(flags: 0, transformationChoice: 0, transformationIndex: 0, animatedTransformIndex: 0)
        // rotX raw values chosen so pose A = 0 rad, pose B = pi/2 rad about X (raw*16/65536*2pi = angle).
        let rawForAngle: (Float) -> Int16 = { angle in Int16(angle / (2 * .pi) * 65536 / 16) }
        let frameA = AnimFrame(values: [0, 0, 0, rawForAngle(0), 0, 0, 4096, 4096, 4096])
        let frameB = AnimFrame(values: [0, 0, 0, rawForAngle(.pi / 2), 0, 0, 4096, 4096, 4096])
        let trackA = AnimationTrack(jointSettings: [settingsA], staticTransforms: [], frames: [frameA], componentsPerFrame: 9)
        let trackB = AnimationTrack(jointSettings: [settingsA], staticTransforms: [], frames: [frameB], componentsPerFrame: 9)

        let transforms = AnimationSkeletonBinding.blendedWorldTransforms(skeleton: skeleton, trackA: trackA, frameA: 0, trackB: trackB, frameB: 0, t: 0.5)
        let world = try! XCTUnwrap(transforms[0])
        // A 45° rotation about X sends +Y to (0, cos45, sin45) ~ (0, 0.707, 0.707).
        let rotatedY = SIMD3<Float>(world.columns.1.x, world.columns.1.y, world.columns.1.z)
        XCTAssertEqual(rotatedY.y, 0.707, accuracy: 0.01)
        XCTAssertEqual(rotatedY.z, 0.707, accuracy: 0.01)
    }
}
