import XCTest
import simd
@testable import CTModels
@testable import CTStudioApp

/// Verifies `AnimationSkeletonBinding.localPose`, the ported (not guessed)
/// `AnimationController.GetMainAnimationTransform` channel-selection logic , 
/// against hand-computed expected values, independent of any real disc
/// data. Precise math like this (cursor bookkeeping across two independent
/// pools, coordinate negation, angle scaling) is exactly the kind of thing
/// that looks right by inspection but is wrong in a subtle, hard-to-notice
/// way, so this pins concrete numbers rather than just "it doesn't crash."
final class AnimationSkeletonBindingTests: XCTestCase {
    /// `transformationChoice = 0` means every one of the 9 channels is bit
    /// *clear*, i.e. every channel reads from the animated pool, the
    /// simplest case to hand-verify.
    func testLocalPoseAllAnimatedChannels() throws {
        let settings = AnimJointSettings(flags: 0, transformationChoice: 0, transformationIndex: 0, animatedTransformIndex: 0)
        // translateX=4096(=1.0, negated->-1.0), Y=8192(=2.0), Z=12288(=3.0),
        // rotX raw=1024 -> 1024*16/65536*2π = 0.25*2π = π/2, rotY=rotZ=0,
        // scaleX=4096(=1.0), scaleY=8192(=2.0), scaleZ=4096(=1.0).
        let frame = AnimFrame(values: [4096, 8192, 12288, 1024, 0, 0, 4096, 8192, 4096])
        let track = AnimationTrack(jointSettings: [settings], staticTransforms: [], frames: [frame], componentsPerFrame: 9)

        let pose = try XCTUnwrap(AnimationSkeletonBinding.localPose(track: track, jointIndex: 0, frame: 0))

        XCTAssertEqual(pose.translation.x, -1, accuracy: 0.0001, "translateX must be negated (reference's consistent X-axis flip)")
        XCTAssertEqual(pose.translation.y, 2, accuracy: 0.0001, "Y must not be negated")
        XCTAssertEqual(pose.translation.z, 3, accuracy: 0.0001, "Z must not be negated")
        XCTAssertEqual(pose.scale.x, 1, accuracy: 0.0001)
        XCTAssertEqual(pose.scale.y, 2, accuracy: 0.0001)
        XCTAssertEqual(pose.scale.z, 1, accuracy: 0.0001)
        // A 90° rotation about X should send +Y to +Z.
        let rotatedY = pose.rotation.act(SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(rotatedY.x, 0, accuracy: 0.001)
        XCTAssertEqual(rotatedY.y, 0, accuracy: 0.001)
        XCTAssertEqual(rotatedY.z, 1, accuracy: 0.001)
        XCTAssertFalse(pose.useAddRotation)
        XCTAssertFalse(pose.useParentScale)
    }

    /// `transformationChoice` with every bit set means every channel is
    /// static, read once from `staticTransforms`, never touching the
    /// per-frame animated pool at all (so a single-element `frames[0].values`
    /// array, or even an empty one, must not be read out of bounds).
    func testLocalPoseAllStaticChannels() throws {
        let allStaticBits: UInt16 = 0b1_1111_1111 // bits 0-8 set
        let settings = AnimJointSettings(flags: 0, transformationChoice: allStaticBits, transformationIndex: 0, animatedTransformIndex: 0)
        let staticValues: [AnimStaticTransform] = [
            AnimStaticTransform(stored: 4096), AnimStaticTransform(stored: 8192), AnimStaticTransform(stored: 12288), // translate
            AnimStaticTransform(stored: 0), AnimStaticTransform(stored: 0), AnimStaticTransform(stored: 0), // rotation (0 rad each)
            AnimStaticTransform(stored: 4096), AnimStaticTransform(stored: 4096), AnimStaticTransform(stored: 4096), // scale
        ]
        let frame = AnimFrame(values: [])
        let track = AnimationTrack(jointSettings: [settings], staticTransforms: staticValues, frames: [frame], componentsPerFrame: 0)

        let pose = try XCTUnwrap(AnimationSkeletonBinding.localPose(track: track, jointIndex: 0, frame: 0))

        XCTAssertEqual(pose.translation.x, -1, accuracy: 0.0001)
        XCTAssertEqual(pose.translation.y, 2, accuracy: 0.0001)
        XCTAssertEqual(pose.translation.z, 3, accuracy: 0.0001)
        XCTAssertEqual(pose.scale.x, 1, accuracy: 0.0001)
        XCTAssertEqual(pose.scale.y, 1, accuracy: 0.0001)
        XCTAssertEqual(pose.scale.z, 1, accuracy: 0.0001)
    }

    /// `Flags` bits 0xC/0xD select `useAddRotation`/`useParentScale` , 
    /// confirmed against the reference's own `(Flags >> 0xC & 0x1) != 0`
    /// (`AnimationController.GetMainAnimationTransform`) and
    /// `(Flags >> 0xD & 0x1) != 0` (`AnimationViewer.ComputeJointTransform`).
    func testFlagBitsSelectAddRotationAndParentScale() throws {
        let bothSet: UInt16 = (1 << 0xC) | (1 << 0xD)
        let settings = AnimJointSettings(flags: bothSet, transformationChoice: 0, transformationIndex: 0, animatedTransformIndex: 0)
        let frame = AnimFrame(values: [0, 0, 0, 0, 0, 0, 4096, 4096, 4096])
        let track = AnimationTrack(jointSettings: [settings], staticTransforms: [], frames: [frame], componentsPerFrame: 9)

        let pose = try XCTUnwrap(AnimationSkeletonBinding.localPose(track: track, jointIndex: 0, frame: 0))
        XCTAssertTrue(pose.useAddRotation)
        XCTAssertTrue(pose.useParentScale)
    }

    /// A skeleton with only a root joint: its bind-pose and animated world
    /// transforms should both just be that one joint's own local transform
    /// (no parent to compose with), the simplest possible sanity check
    /// that the recursive tree walk doesn't do something unexpected for
    /// the base case.
    func testSingleJointSkeletonWorldTransformMatchesLocalTransform() throws {
        // matrix[0] = bind translation (X negated on read), matrix[2] = bind rotation (identity here).
        let matrix: [SIMD4<Float>] = [
            SIMD4(5, 0, 0, 1), // [0] translation source: stored X=5 -> read back negated as -5
            .zero,
            SIMD4(0, 0, 0, 1), // [2] identity quaternion (x=0,y=0,z=0,w=1)
            .zero,
            SIMD4(0, 0, 0, 1), // [4] identity add-rotation
        ]
        let joint = Joint(reactJointID: 0, jointIndex: 0, parentJointIndex: 0, childJointAmount: 0, childJointAmount2: 0, matrix: matrix)
        let skeleton = SkeletonAsset(id: 1, joints: [joint], exitPoints: [], skinTransforms: [], skinID: 0, blendSkinID: 0, modelLinks: [])

        let bindPose = AnimationSkeletonBinding.bindPoseWorldTransforms(skeleton: skeleton)
        let transform = try XCTUnwrap(bindPose[0])
        XCTAssertEqual(transform.columns.3.x, -5, accuracy: 0.0001, "translation X must be negated on read, matching every other coordinate flip in this port")
    }

    /// Regression for a real, confirmed bug: a joint whose raw on-disk
    /// rotation row (`matrix[2]`) is the zero vector, observed in a real
    /// character (`Levels/Earth/Cavern/cavent.rm2`, skeleton id 0) , 
    /// used to build a zero-length (non-normalized) quaternion, whose
    /// matrix is singular. `bindPoseWorldTransforms` composes every joint's
    /// world transform through its parent chain, so that one degenerate
    /// root joint poisoned its child's world transform too, and
    /// `skinningMatrices`' unconditional `.inverse` turned "singular" into
    /// NaN for both joints, the entire mesh rendered as nothing the
    /// instant any animation was selected, regardless of which one (bind
    /// pose is computed before any per-frame data is even consulted).
    func testDegenerateRootJointRotationDoesNotProduceNaN() throws {
        let degenerateRoot = Joint(reactJointID: 0, jointIndex: 0, parentJointIndex: 0, childJointAmount: 1, childJointAmount2: 0, matrix: [
            SIMD4(0, 0, 0, 1), // [0] translation
            .zero,
            .zero,              // [2] degenerate rotation row, the bug
            .zero,
            SIMD4(0, 0, 0, 1), // [4] add-rotation
        ])
        let child = Joint(reactJointID: 1, jointIndex: 1, parentJointIndex: 0, childJointAmount: 0, childJointAmount2: 0, matrix: [
            SIMD4(3, 0, 0, 1), // [0] translation (X negated on read -> -3)
            .zero,
            SIMD4(0, 0, 0, 1), // [2] identity quaternion, real, valid data
            .zero,
            SIMD4(0, 0, 0, 1), // [4] add-rotation
        ])
        let skeleton = SkeletonAsset(id: 1, joints: [degenerateRoot, child], exitPoints: [], skinTransforms: [], skinID: 0, blendSkinID: 0, modelLinks: [])

        let bindPose = AnimationSkeletonBinding.bindPoseWorldTransforms(skeleton: skeleton)
        let rootTransform = try XCTUnwrap(bindPose[0])
        let childTransform = try XCTUnwrap(bindPose[1])

        for column in [rootTransform.columns.0, rootTransform.columns.1, rootTransform.columns.2, rootTransform.columns.3] {
            XCTAssertTrue(column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite, "degenerate root joint must fall back to identity rotation, not propagate NaN")
        }
        for column in [childTransform.columns.0, childTransform.columns.1, childTransform.columns.2, childTransform.columns.3] {
            XCTAssertTrue(column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite, "child of a degenerate joint must not inherit NaN through the parent chain")
        }

        // The real, load-bearing check: skinningMatrices (which calls
        // `.inverse` unconditionally on the bind pose) must also stay
        // finite for both joints, this is the exact computation that
        // reached the GPU buffer as NaN before the fix.
        let track = AnimationTrack(jointSettings: [], staticTransforms: [], frames: [AnimFrame(values: [])], componentsPerFrame: 0)
        let skinning = AnimationSkeletonBinding.skinningMatrices(skeleton: skeleton, track: track, frame: 0)
        for (_, matrix) in skinning {
            for column in [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3] {
                XCTAssertTrue(column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite, "skinning matrix must be finite even when the bind pose had a degenerate joint")
            }
        }
    }
}
