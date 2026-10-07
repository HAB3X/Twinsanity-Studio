import simd
import CTModels

/// Real, verified skeletal animation binding, ported field-for-field from
/// the reference tool's actual working implementation
/// (`twinsanity-editor-master/TwinsaityEditor/Controllers/AnimationController.cs`'s
/// `GetMainAnimationTransform`, and
/// `twinsanity-editor-master/TwinsaityEditor/Viewers/AnimationViewer.cs`'s
/// `ComputeJointTransform`/`ComputeTposeTransform`/`ComputePoseTransform`),
/// **not** a guess. This supersedes the old `ExperimentalAnimationPose` , 
/// the channel-mapping semantics that file's doc comment said were
/// undocumented ("Real skeletal deformation is blocked on that missing
/// piece") turned out to have a real, working reference implementation
/// sitting in this project's own `twinsanity-editor-master` reference repo
/// the whole time; this is that implementation, cross-checked line-for-line,
/// not invented.
///
/// Coordinate/composition conventions carried over from the reference:
/// - The reference (OpenTK) uses row-vector matrices (`v * A * B` = apply A
///   then B); this port uses simd's column-vector convention throughout
///   (`B * A * v` for the same net effect), matching every other TRS
///   composition already in this codebase (see `LevelViewerRenderer.draw`'s
///   `translation * rotation * scale`).
/// - Every position/rotation the reference reads off disk gets its X (and,
///   for quaternions, W) component negated before use, a real,
///   consistently-applied coordinate-system correction in the reference
///   tool itself, not something this port introduces.
/// - The reference's raw-angle "unwrap" step before building each frame's
///   individual rotation matrix (`Animation.cs`'s `AnimationController.
///   GetMainAnimationTransform`, the `if (diff < -0x8000) rot1 += 0x10000`
///   lines) is mathematically a no-op here: it only ever shifts an angle by
///   an exact multiple of 2π immediately before that angle is used to build
///   a `Matrix3.CreateRotationX/Y/Z`, and rotation matrices are exactly
///   2π-periodic, so it changes nothing about the resulting matrix/
///   quaternion in this codepath, and is omitted rather than ported
///   verbatim for no behavioral difference.
enum AnimationSkeletonBinding {
    /// One joint's decoded local transform at a specific animation frame , 
    /// the direct Swift equivalent of `GetMainAnimationTransform`'s return
    /// tuple, unpacked into named fields instead of a packed `Matrix4`.
    struct LocalPose {
        var translation: SIMD3<Float>
        var scale: SIMD3<Float>
        var rotation: simd_quatf
        var useAddRotation: Bool
        var useParentScale: Bool
    }

    /// `Animation.cs:139-162`'s `JointSettings.TransformationChoice`: bit
    /// *clear* means "read this channel from the per-frame animated pool"
    /// (advancing that joint's own animated-column cursor), bit *set* means
    /// "read a single static value that applies to every frame" (advancing
    /// the shared static-transform-pool cursor instead). Two independent
    /// cursors, each only advancing for the channels that actually consume
    /// from that specific pool, ported exactly from
    /// `AnimationController.GetMainAnimationTransform`'s `transformIndex`/
    /// `currentFrameTransformIndex` bookkeeping.
    static func localPose(track: AnimationTrack, jointIndex: Int, frame frameIndex: Int) -> LocalPose? {
        guard track.jointSettings.indices.contains(jointIndex), track.frames.indices.contains(frameIndex) else { return nil }
        let settings = track.jointSettings[jointIndex]
        let choice = settings.transformationChoice
        let frame = track.frames[frameIndex]

        var staticCursor = Int(settings.transformationIndex)
        var animatedCursor = Int(settings.animatedTransformIndex)

        func isAnimated(_ bit: Int) -> Bool { (choice >> bit) & 0x1 == 0 }

        var translation = SIMD3<Float>.zero
        for axis in 0..<3 {
            if isAnimated(axis), animatedCursor < frame.values.count {
                translation[axis] = frame.linearValue(at: animatedCursor)
                animatedCursor += 1
            } else if staticCursor < track.staticTransforms.count {
                translation[axis] = track.staticTransforms[staticCursor].linearValue
                staticCursor += 1
            }
        }

        var eulerRadians = SIMD3<Float>.zero
        for axis in 0..<3 {
            let bit = 3 + axis
            if isAnimated(bit), animatedCursor < frame.values.count {
                // `GetPureOffset(...) * 16`, then the raw-int16-range ->
                // radians scale, see `Animation.Transformation.RotValue`.
                let raw = Float(frame.values[animatedCursor]) * 16
                eulerRadians[axis] = raw / 65536 * 2 * .pi
                animatedCursor += 1
            } else if staticCursor < track.staticTransforms.count {
                eulerRadians[axis] = track.staticTransforms[staticCursor].rotationRadians
                staticCursor += 1
            }
        }

        var scale = SIMD3<Float>(1, 1, 1)
        for axis in 0..<3 {
            let bit = 6 + axis
            if isAnimated(bit), animatedCursor < frame.values.count {
                scale[axis] = frame.linearValue(at: animatedCursor)
                animatedCursor += 1
            } else if staticCursor < track.staticTransforms.count {
                scale[axis] = track.staticTransforms[staticCursor].linearValue
                staticCursor += 1
            }
        }

        translation.x = -translation.x // reference's consistent X-axis flip
        let rotation = quaternion(fromEulerRadians: eulerRadians)
        let useAddRotation = (settings.flags >> 0xC) & 0x1 != 0
        let useParentScale = (settings.flags >> 0xD) & 0x1 != 0
        return LocalPose(translation: translation, scale: scale, rotation: rotation, useAddRotation: useAddRotation, useParentScale: useParentScale)
    }

    /// `rotX * rotY * rotZ` in the reference's row-vector `Matrix3`
    /// convention ("apply rotX first, then rotY, then rotZ") is `qz * qy * qx`
    /// under simd's column-vector quaternion convention, same derivation
    /// already used by `LevelViewerRenderer`'s own `quaternion(fromEulerDegrees:)`.
    private static func quaternion(fromEulerRadians radians: SIMD3<Float>) -> simd_quatf {
        let qx = simd_quatf(angle: radians.x, axis: SIMD3(1, 0, 0))
        let qy = simd_quatf(angle: radians.y, axis: SIMD3(0, 1, 0))
        let qz = simd_quatf(angle: radians.z, axis: SIMD3(0, 0, 1))
        return qz * qy * qx
    }

    /// One joint's bind-pose local translation/rotation plus its optional
    /// "additional rotation," read straight from the skeleton's own decoded
    /// data, `Joint.matrix[0]` (translation, X negated), `matrix[2]`
    /// (rotation quaternion, X and W negated), `matrix[4]` (add-rotation
    /// quaternion, X and W negated). These specific row indices/meanings
    /// come from `AnimationViewer.ComputeTposeTransform` and
    /// `ComputeJointTransform`'s `useAddRot` branch, confirmed against
    /// working reference code, not the earlier best-effort guess (`matrix[3]`)
    /// this file replaces.
    private static func bindPoseLocal(_ joint: Joint) -> (translation: SIMD3<Float>, rotation: simd_quatf, addRotation: simd_quatf) {
        guard joint.matrix.count > 4 else { return (.zero, simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))) }
        let translationRow = joint.matrix[0]
        let translation = SIMD3<Float>(-translationRow.x, translationRow.y, translationRow.z)
        let rotationRow = joint.matrix[2]
        let rotation = Self.safeQuaternion(x: -rotationRow.x, y: rotationRow.y, z: rotationRow.z, w: -rotationRow.w)
        let addRow = joint.matrix[4]
        let addRotation = Self.safeQuaternion(x: -addRow.x, y: addRow.y, z: addRow.z, w: -addRow.w)
        return (translation, rotation, addRotation)
    }

    /// Real game data has been observed to carry a joint whose raw on-disk
    /// rotation row is the zero vector (an unused/auxiliary joint slot,
    /// never meaningfully authored), confirmed against a real character
    /// (`Levels/Earth/Cavern/cavent.rm2`, skeleton id 0) that otherwise
    /// renders correctly. `simd_quatf(vector:)` doesn't normalize, so a
    /// near-zero input builds a near-zero-length quaternion; the matrix
    /// built from it is singular, and, since `bindPoseWorldTransforms`
    /// composes every joint's world transform through its parent chain , 
    /// that one joint's singular matrix poisons every descendant's world
    /// transform too, and `skinningMatrices`' unconditional `bind.inverse`
    /// turns "singular" into "every component NaN" for the whole affected
    /// subtree: the entire mesh renders as nothing the instant any
    /// animation is selected (bind pose is computed before any per-frame
    /// animation data is even consulted, so this doesn't depend on which
    /// animation or frame). The reference tool's own `ComputeTposeTransform`
    /// has the identical unconditional `Matrix4.Invert()` with no
    /// validity check, this isn't a convention the Swift port dropped,
    /// it's a gap the reference never needed to close for whichever
    /// characters its own authors happened to test. Falling back to
    /// identity for a degenerate row keeps that one joint (and, more
    /// importantly, everything under it) at its parent's transform instead
    /// of NaN, not byte-perfect for a joint the format never gave usable
    /// data for, but it keeps the rest of a real, mostly-valid skeleton
    /// visible instead of blanking the whole model.
    private static func safeQuaternion(x: Float, y: Float, z: Float, w: Float) -> simd_quatf {
        let raw = SIMD4<Float>(x, y, z, w)
        guard simd_length(raw) > 0.0001 else { return simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)) }
        return simd_quatf(vector: raw)
    }

    /// Every joint's bind-pose world transform, `ComputeTposeTransform`'s
    /// recursive walk, ported. `parent * local` (column-vector convention)
    /// replicates the reference's `localTransform * parentTransform`
    /// (row-vector convention), "apply this joint's own local transform,
    /// then whatever got it from world space to its parent."
    static func bindPoseWorldTransforms(skeleton: SkeletonAsset) -> [UInt32: simd_float4x4] {
        var result: [UInt32: simd_float4x4] = [:]
        func walk(_ node: SkeletonTreeNode, parentTransform: simd_float4x4) {
            let local = bindPoseLocal(node.joint)
            let localTransform = simd_float4x4(translation: local.translation) * simd_float4x4(local.rotation)
            let worldTransform = parentTransform * localTransform
            result[node.joint.jointIndex] = worldTransform
            for child in node.children { walk(child, parentTransform: worldTransform) }
        }
        guard let root = skeleton.buildTree() else { return result }
        walk(root, parentTransform: matrix_identity_float4x4)
        return result
    }

    /// Every joint's *animated* world transform (plus the accumulated world
    /// scale each joint's `useParentScale` needs) at `frameIndex` , 
    /// `ComputeJointTransform`'s recursive walk, ported.
    static func animatedWorldTransforms(skeleton: SkeletonAsset, track: AnimationTrack, frame frameIndex: Int) -> [UInt32: simd_float4x4] {
        var result: [UInt32: simd_float4x4] = [:]
        func walk(_ node: SkeletonTreeNode, parentTransform: simd_float4x4, parentScale: SIMD3<Float>) {
            let jointIndex = Int(node.joint.jointIndex)
            guard let pose = localPose(track: track, jointIndex: jointIndex, frame: frameIndex) else {
                // No animation data for this joint (a joint the animation
                // doesn't drive), fall back to its bind-pose local
                // transform so the rest of the hierarchy still composes
                // sensibly, rather than collapsing to identity.
                let local = bindPoseLocal(node.joint)
                let localTransform = simd_float4x4(translation: local.translation) * simd_float4x4(local.rotation)
                let worldTransform = parentTransform * localTransform
                result[node.joint.jointIndex] = worldTransform
                for child in node.children { walk(child, parentTransform: worldTransform, parentScale: parentScale) }
                return
            }

            var rotation = pose.rotation
            if pose.useAddRotation {
                let addRotation = bindPoseLocal(node.joint).addRotation
                rotation = addRotation * pose.rotation
            }
            var scale = pose.scale
            if pose.useParentScale {
                scale = SIMD3(scale.x / max(parentScale.x, 0.0001), scale.y / max(parentScale.y, 0.0001), scale.z / max(parentScale.z, 0.0001))
            }

            let localTransform = simd_float4x4(translation: pose.translation) * simd_float4x4(rotation) * simd_float4x4(diagonal: SIMD4(scale.x, scale.y, scale.z, 1))
            let worldTransform = parentTransform * localTransform
            result[node.joint.jointIndex] = worldTransform
            for child in node.children { walk(child, parentTransform: worldTransform, parentScale: pose.scale) }
        }
        guard let root = skeleton.buildTree() else { return result }
        walk(root, parentTransform: matrix_identity_float4x4, parentScale: SIMD3(1, 1, 1))
        return result
    }

    /// "Procedural Animation Frame Blending" (roadmap 12.2): every joint's
    /// *blended* world transform between two independently-chosen
    /// `(track, frame)` points, the same two points can be adjacent
    /// frames of one clip (smoothing a choppy loop) or frames from two
    /// completely different animations (blending a run cycle into a
    /// custom attack). Mirrors `animatedWorldTransforms`'s exact hierarchy
    /// walk and `useAddRotation`/`useParentScale` handling; the only
    /// difference is that each joint's `LocalPose` is itself a blend of
    /// the two sides (translation/scale linearly interpolated, rotation
    /// via quaternion slerp, the standard way to interpolate rotations
    /// without the axis-flip artifacts linear interpolation would cause)
    /// before being composed into a local transform. `t=0` is pose A,
    /// `t=1` is pose B. A joint missing from one side's track (but present
    /// in the other) uses whichever side actually has it, not a
    /// fabricated blend against a value that doesn't exist.
    static func blendedWorldTransforms(
        skeleton: SkeletonAsset,
        trackA: AnimationTrack, frameA: Int,
        trackB: AnimationTrack, frameB: Int,
        t: Float
    ) -> [UInt32: simd_float4x4] {
        let clampedT = min(max(t, 0), 1)
        var result: [UInt32: simd_float4x4] = [:]
        func walk(_ node: SkeletonTreeNode, parentTransform: simd_float4x4, parentScale: SIMD3<Float>) {
            let jointIndex = Int(node.joint.jointIndex)
            let poseA = localPose(track: trackA, jointIndex: jointIndex, frame: frameA)
            let poseB = localPose(track: trackB, jointIndex: jointIndex, frame: frameB)

            let blended: LocalPose
            switch (poseA, poseB) {
            case let (.some(a), .some(b)):
                blended = LocalPose(
                    translation: a.translation + (b.translation - a.translation) * clampedT,
                    scale: a.scale + (b.scale - a.scale) * clampedT,
                    rotation: simd_slerp(a.rotation, b.rotation, clampedT),
                    useAddRotation: clampedT < 0.5 ? a.useAddRotation : b.useAddRotation,
                    useParentScale: clampedT < 0.5 ? a.useParentScale : b.useParentScale
                )
            case let (.some(a), .none):
                blended = a
            case let (.none, .some(b)):
                blended = b
            case (.none, .none):
                let local = bindPoseLocal(node.joint)
                let localTransform = simd_float4x4(translation: local.translation) * simd_float4x4(local.rotation)
                let worldTransform = parentTransform * localTransform
                result[node.joint.jointIndex] = worldTransform
                for child in node.children { walk(child, parentTransform: worldTransform, parentScale: parentScale) }
                return
            }

            var rotation = blended.rotation
            if blended.useAddRotation {
                let addRotation = bindPoseLocal(node.joint).addRotation
                rotation = addRotation * blended.rotation
            }
            var scale = blended.scale
            if blended.useParentScale {
                scale = SIMD3(scale.x / max(parentScale.x, 0.0001), scale.y / max(parentScale.y, 0.0001), scale.z / max(parentScale.z, 0.0001))
            }

            let localTransform = simd_float4x4(translation: blended.translation) * simd_float4x4(rotation) * simd_float4x4(diagonal: SIMD4(scale.x, scale.y, scale.z, 1))
            let worldTransform = parentTransform * localTransform
            result[node.joint.jointIndex] = worldTransform
            for child in node.children { walk(child, parentTransform: worldTransform, parentScale: blended.scale) }
        }
        guard let root = skeleton.buildTree() else { return result }
        walk(root, parentTransform: matrix_identity_float4x4, parentScale: SIMD3(1, 1, 1))
        return result
    }

    /// Blended counterpart to `skinningMatrices`, see
    /// `blendedWorldTransforms`'s doc comment.
    static func blendedSkinningMatrices(
        skeleton: SkeletonAsset,
        trackA: AnimationTrack, frameA: Int,
        trackB: AnimationTrack, frameB: Int,
        t: Float
    ) -> [UInt32: simd_float4x4] {
        let bindPose = bindPoseWorldTransforms(skeleton: skeleton)
        let animated = blendedWorldTransforms(skeleton: skeleton, trackA: trackA, frameA: frameA, trackB: trackB, frameB: frameB, t: t)
        var result: [UInt32: simd_float4x4] = [:]
        for (jointIndex, bind) in bindPose {
            guard let animatedTransform = animated[jointIndex] else { continue }
            result[jointIndex] = animatedTransform * bind.inverse
        }
        return result
    }

    /// Final per-joint GPU skinning matrices at `frameIndex` , 
    /// `ComputePoseTransform`'s `inverseBindPose * animatedWorldTransform`,
    /// ported: transforms a bind-space vertex into this joint's own local
    /// space (undoing the bind pose), then back out into world space via
    /// the joint's *animated* world transform. A vertex weighted 100% to
    /// one joint that hasn't moved from bind pose gets the identity matrix
    /// out of this, by construction.
    static func skinningMatrices(skeleton: SkeletonAsset, track: AnimationTrack, frame frameIndex: Int) -> [UInt32: simd_float4x4] {
        let bindPose = bindPoseWorldTransforms(skeleton: skeleton)
        let animated = animatedWorldTransforms(skeleton: skeleton, track: track, frame: frameIndex)
        var result: [UInt32: simd_float4x4] = [:]
        for (jointIndex, bind) in bindPose {
            guard let animatedTransform = animated[jointIndex] else { continue }
            result[jointIndex] = animatedTransform * bind.inverse
        }
        return result
    }

    /// World-space joint positions (translation column of each joint's
    /// animated world transform) connected parent-to-child, the skeleton
    /// wireframe overlay's data source. Real now (derived from the same
    /// verified transforms `skinningMatrices` uses), not the old
    /// experimental per-axis nudge.
    static func jointSegments(skeleton: SkeletonAsset, track: AnimationTrack, frameIndex: Int) -> [(SIMD3<Float>, SIMD3<Float>)] {
        let transforms = animatedWorldTransforms(skeleton: skeleton, track: track, frame: frameIndex)
        guard let root = skeleton.buildTree() else { return [] }
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        func worldPosition(_ node: SkeletonTreeNode) -> SIMD3<Float> {
            guard let t = transforms[node.joint.jointIndex] else { return .zero }
            return SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }
        func walk(_ node: SkeletonTreeNode) {
            let selfPos = worldPosition(node)
            for child in node.children {
                segments.append((selfPos, worldPosition(child)))
                walk(child)
            }
        }
        walk(root)
        return segments
    }

    /// Bind-pose equivalent of `jointSegments`, for when no animation is
    /// selected, real bind-pose hierarchy positions (`bindPoseWorldTransforms`),
    /// not the old `matrix[3]`-as-local-offset guess.
    static func bindPoseJointSegments(skeleton: SkeletonAsset) -> [(SIMD3<Float>, SIMD3<Float>)] {
        let transforms = bindPoseWorldTransforms(skeleton: skeleton)
        guard let root = skeleton.buildTree() else { return [] }
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        func worldPosition(_ node: SkeletonTreeNode) -> SIMD3<Float> {
            guard let t = transforms[node.joint.jointIndex] else { return .zero }
            return SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }
        func walk(_ node: SkeletonTreeNode) {
            let selfPos = worldPosition(node)
            for child in node.children {
                segments.append((selfPos, worldPosition(child)))
                walk(child)
            }
        }
        walk(root)
        return segments
    }
}
