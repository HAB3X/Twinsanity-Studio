import XCTest
import Metal
import simd
import ImageIO
import UniformTypeIdentifiers
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

final class ModelViewerRendererTests: XCTestCase {
    private func makeTestAsset() -> ResolvedModelAsset {
        let vertices = [
            StaticVertex(position: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 0)),
            StaticVertex(position: SIMD3(1, 0, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(1, 0)),
            StaticVertex(position: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 1))
        ]
        let submesh = MeshSubmesh(vertices: vertices, connectivity: [true, true, true], materialID: 1)
        let mesh = MeshAsset(id: 1, isSkinned: false, submeshes: [submesh])
        let texture = TextureAsset(id: 1, width: 2, height: 2, pixelFormat: .psmct32, rgba: [UInt8](repeating: 200, count: 16))
        let material = ResolvedSubmeshMaterial(materialID: 1, textureID: 1, texture: texture)
        return ResolvedModelAsset(recordID: 1, displayName: "Test Triangle", mesh: mesh, submeshMaterials: [material])
    }

    /// The most important regression test in this file: if the embedded MSL
    /// shader source fails to compile at runtime (typo, unsupported
    /// feature), `ModelViewerRenderer.init` returns `nil`, which is exactly
    /// what a user sees as "the Model Viewer shows a blank screen," with no
    /// error surfaced anywhere. This pins that the pipeline actually builds.
    func testRendererInitializesAndCompilesShaderSuccessfully() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = ModelViewerRenderer(asset: asset)
        XCTAssertNotNil(renderer, "ModelViewerRenderer failed to initialize, likely a shader compile error swallowed by the init? guard chain")
    }

    /// The Euler-degrees<->quaternion conversion behind the Level Viewer's
    /// rotate gizmo and rotation nudge fields (`LevelViewerRenderer.
    /// setSelectedRotation`/`selectedRotationDegrees`) is new, non-trivial
    /// math (XYZ Euler decomposition from a rotation matrix) with a real
    /// failure mode, a wrong axis order or sign flip wouldn't crash, it'd
    /// just silently show the wrong angle in the UI. Round-tripping through
    /// the actual renderer (not a standalone math check) exercises the
    /// exact path the UI uses.
    func testRotationRoundTripsThroughEulerDegrees() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, nil)]))
        renderer.select(index: 0)

        // Deliberately away from 90°-multiple angles, where gimbal lock
        // makes the decomposition genuinely ambiguous (multiple valid
        // Euler triples for the same rotation) rather than just "a hard
        // case this implementation gets slightly wrong."
        let input = SIMD3<Float>(30, 45, 60)
        renderer.setSelectedRotation(eulerDegrees: input)
        let output = try XCTUnwrap(renderer.selectedRotationDegrees)

        XCTAssertEqual(output.x, input.x, accuracy: 0.01)
        XCTAssertEqual(output.y, input.y, accuracy: 0.01)
        XCTAssertEqual(output.z, input.z, accuracy: 0.01)
    }

    func testScaleClampsAwayFromZeroAndNegative() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, nil)]))
        renderer.select(index: 0)

        // A zero/negative scale collapses or flips the mesh in a way
        // that's visually indistinguishable from "nothing renders", the
        // exact class of bug the blank-viewport investigation spent a long
        // time chasing down elsewhere in this renderer, so this is a real
        // regression to guard, not a hypothetical one.
        renderer.setSelectedScale(to: SIMD3(-5, 0, 2))
        let scale = try XCTUnwrap(renderer.selectedScale)
        XCTAssertGreaterThan(scale.x, 0)
        XCTAssertGreaterThan(scale.y, 0)
        XCTAssertEqual(scale.z, 2, accuracy: 0.01)
    }

    func testRendererHandlesEmptyMeshWithoutCrashing() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let mesh = MeshAsset(id: 1, isSkinned: false, submeshes: [])
        let asset = ResolvedModelAsset(recordID: 1, displayName: "Empty", mesh: mesh, submeshMaterials: [])
        let renderer = ModelViewerRenderer(asset: asset)
        XCTAssertNotNil(renderer)
    }

    /// Renders a *real* resolved model from the actual game archive to an
    /// offscreen texture, so the Metal pipeline's actual pixel output is
    /// verified directly rather than inferred from code review. Skips
    /// gracefully (not a failure) when the disc image isn't mounted at the
    /// well-known path, useful locally, inert in any other environment.
    func testRenderRealModelToOffscreenSnapshot() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else {
            throw XCTSkip("Disc image not mounted")
        }
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available")
        }

        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))
        let entryName = "Levels/AltEarth/Hub/alttunl.rm2"
        let entry = try XCTUnwrap(index.entries.first { $0.name == entryName })
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let fileRoot = try RM2Parser.parse(data: data, fileKind: .rm2, fileName: entryName)
        let assetIndex = AssetResolver.buildIndex(fileRoot: fileRoot)
        let rigidModel = try XCTUnwrap(assetIndex.rigidModels[2_623_336_433])
        let resolved = try XCTUnwrap(AssetResolver.resolveRigidModel(rigidModel, displayName: "alttunl rigidModel", index: assetIndex))

        XCTAssertGreaterThan(resolved.mesh.totalVertexCount, 0, "precondition: real mesh should have vertices")
        XCTAssertTrue(resolved.isFullyTextured, "precondition: this specific rigidModel is known to fully resolve textures")

        let renderer = try XCTUnwrap(ModelViewerRenderer(asset: resolved))
        XCTAssertTrue(renderer.hasGeometry, "renderer uploaded zero submeshes despite a non-empty resolved mesh")
        XCTAssertEqual(renderer.submeshCount, resolved.mesh.submeshes.count)

        guard let image = renderer.renderOffscreen(width: 512, height: 512) else {
            return XCTFail("renderOffscreen returned nil")
        }

        // Fail loudly (not just "looks blank") if the frame is a single flat
        // color, that's exactly the "nothing shows up" symptom, distinct
        // from "not blank but wrong."
        let uniqueColorCount = Self.countApproxUniqueColors(image)
        print("DIAG: rendered frame has ~\(uniqueColorCount) distinct sampled colors")
        XCTAssertGreaterThan(uniqueColorCount, 1, "rendered frame appears to be a single flat color, nothing is actually being drawn")

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("model_viewer_snapshot.png")
        if let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print("DIAG: wrote snapshot to \(outputURL.path)")
        }
    }

    /// Same formula as `ModelViewerRenderer.perspectiveMatrix` (`fileprivate`,
    /// so not directly callable from this test target), duplicated here
    /// deliberately rather than widening that access, since what's under
    /// test is `Frustum`'s own plane-extraction math, not this helper.
    private func testPerspectiveMatrix(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovYRadians * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        )
    }

    /// `Frustum` (Part 1, "Seamless Full-Map Rendering") is the new lever
    /// for skipping draw calls on a massive level, a wrong plane (e.g. an
    /// OpenGL-convention near plane under Metal's `[0,1]` NDC z, which
    /// would put it in the wrong place entirely) wouldn't crash, it'd just
    /// silently pop objects in/out of view, exactly the "dropped frames /
    /// broken rendering" failure this feature exists to prevent. A
    /// symmetric 90°-vertical-FOV, aspect-1, near=1/far=100 projection with
    /// an identity view (camera at the world origin looking down -Z) makes
    /// the frustum's shape easy to reason about by hand: at view-space
    /// depth 10, the half-extent in both X and Y is `10 * tan(45°) == 10`.
    func testFrustumCullsPointsOutsideEachPlane() {
        let viewProjection = testPerspectiveMatrix(fovYRadians: .pi / 2, aspect: 1, near: 1, far: 100)
        let frustum = ModelViewerRenderer.Frustum(viewProjection: viewProjection)

        XCTAssertTrue(frustum.intersects(center: SIMD3(0, 0, -10), radius: 1), "center of the view cone must be visible")
        XCTAssertFalse(frustum.intersects(center: SIMD3(50, 0, -10), radius: 1), "far outside the left/right planes must be culled")
        XCTAssertFalse(frustum.intersects(center: SIMD3(0, 50, -10), radius: 1), "far outside the top/bottom planes must be culled")
        XCTAssertFalse(frustum.intersects(center: SIMD3(0, 0, 10), radius: 1), "behind the camera (past the near plane) must be culled")
        XCTAssertFalse(frustum.intersects(center: SIMD3(0, 0, -150), radius: 1), "past the far plane must be culled")
        XCTAssertTrue(frustum.intersects(center: SIMD3(50, 0, -10), radius: 100), "a sphere large enough to bridge back into view must not be culled")
    }

    // MARK: - Collision Mask Alignment

    /// `collisionBoxEdges` must span the real axis-aligned extent of the
    /// input points regardless of their order, 12 edges, min/max on every
    /// axis actually reached.
    func testCollisionBoxEdgesSpansRealExtent() {
        let corners: [SIMD4<Float>] = [
            SIMD4(-1, -2, -3, 1), SIMD4(1, -2, -3, 1), SIMD4(1, 2, -3, 1), SIMD4(-1, 2, -3, 1),
            SIMD4(-1, -2, 3, 1), SIMD4(1, -2, 3, 1), SIMD4(1, 2, 3, 1), SIMD4(-1, 2, 3, 1)
        ]
        let edges = ModelViewerRenderer.collisionBoxEdges(corners: corners)
        XCTAssertEqual(edges.count, 12)
        let allPoints = edges.flatMap { [$0.0, $0.1] }
        XCTAssertEqual(allPoints.map(\.x).min(), -1)
        XCTAssertEqual(allPoints.map(\.x).max(), 1)
        XCTAssertEqual(allPoints.map(\.y).min(), -2)
        XCTAssertEqual(allPoints.map(\.y).max(), 2)
        XCTAssertEqual(allPoints.map(\.z).min(), -3)
        XCTAssertEqual(allPoints.map(\.z).max(), 3)
    }

    func testCollisionBoxEdgesEmptyForNoCorners() {
        XCTAssertTrue(ModelViewerRenderer.collisionBoxEdges(corners: []).isEmpty)
    }

    // MARK: - The Forge Palette (Part 4C)

    /// `spawnInstance` is the backend half of "select an entity, click into
    /// the map, spawn a brand-new instance", this pins that it actually
    /// adds a selectable object and records enough to reconstruct a real
    /// `Instance` record from later (`pendingNewInstances`).
    func testSpawnInstanceAddsSelectableObjectWithPendingRecord() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, nil)]))
        let before = renderer.objectCount

        // `applyPlacementAlignment: false` -- this test is about the exact-
        // position round-trip through `pendingNewInstances`, not "Align
        // While Placing" (see `PlacementAlignmentTests` for that); without
        // it, this renderer's own pre-seeded scenery placement (whose test
        // mesh happens to have a real vertex at Y=1) pulls the requested
        // Y=1 onto a nearby face-to-face candidate instead of landing
        // exactly where asked.
        let newIndex = try XCTUnwrap(renderer.spawnInstance(objectID: 42, at: SIMD3<Float>(5, 1, -3), applyPlacementAlignment: false))

        XCTAssertEqual(renderer.objectCount, before + 1)
        XCTAssertEqual(renderer.selectedObjectIndex, newIndex)
        let pending = renderer.pendingNewInstances
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].objectID, 42)
        // "Coordinate-System Overhaul": `spawnInstance(at:)` takes a world/
        // display-space position (5,1,-3), the same space the viewport
        // shows everything in, but `pendingNewInstances` hands back the
        // *raw* on-disk position ready for `WorldPlacementWriter`, which is
        // the X-mirrored value. Re-decoding (5,1,-3) is what a real load
        // would show for this record once saved.
        XCTAssertEqual(pending[0].position, SIMD3<Float>(-5, 1, -3))
    }

    /// The undo-reachable half: removing a just-placed object must both
    /// shrink the scene and drop it from `pendingNewInstances`, otherwise
    /// "Save" would write a record for something that's no longer even in
    /// the viewport.
    func testRemoveObjectClearsSelectionAndPendingRecord() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, nil)]))
        let before = renderer.objectCount
        let index = try XCTUnwrap(renderer.spawnInstance(objectID: 7, at: .zero))

        renderer.removeObject(at: index)

        XCTAssertEqual(renderer.objectCount, before)
        XCTAssertNil(renderer.selectedObjectIndex)
        XCTAssertTrue(renderer.pendingNewInstances.isEmpty)
    }

    /// Real, reported bug ("mostly visible now, but still flickers right
    /// at the edge/corner of the camera view for a placed object, and
    /// only that object, never real, dev-placed scenery", plus a
    /// separately-reported "weird particles and chunks" visual corruption
    /// near a newly-placed object as the camera moves): every real
    /// `SceneryModelPlacement.boundingBoxMin`/`boundingBoxMax` on the
    /// pristine disc is LOCAL and exactly symmetric, rotated/scaled but
    /// not translated by the placement's own world position, and always
    /// `min == -max` per axis (confirmed against all 25,836 real
    /// placements on the disc, 100% exact match, not just a true local
    /// AABB, a symmetric per-axis extent). `pendingNewScenery` used to
    /// reuse `worldAABBCorners(of:)`, correct for its other real caller,
    /// `ColData` collision removal, but wrong here since it folds in
    /// `object.worldPosition`; a first fix produced a true (possibly
    /// asymmetric) local AABB, still not matching real data for any mesh
    /// whose local bounds aren't centered on its own pivot. This proves
    /// both properties directly: spawning the identical mesh at two wildly
    /// different world positions must produce the exact same
    /// `boundsMin`/`boundsMax` (local, not world), and that pair must
    /// itself be exactly symmetric (`boundsMin == -boundsMax`).
    func testPendingNewSceneryBoundingBoxIsLocalAndSymmetricNotWorldPosition() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let rendererNearOrigin = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, nil)]))
        _ = rendererNearOrigin.spawnScenery(modelID: 100, isSpecial: false, asset: asset, at: SIMD3<Float>(2, 0, 2), applyPlacementAlignment: false)
        let nearBounds = try XCTUnwrap(rendererNearOrigin.pendingNewScenery.first)

        let rendererFarFromOrigin = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, nil)]))
        _ = rendererFarFromOrigin.spawnScenery(modelID: 100, isSpecial: false, asset: asset, at: SIMD3<Float>(500, 10, 300), applyPlacementAlignment: false)
        let farBounds = try XCTUnwrap(rendererFarFromOrigin.pendingNewScenery.first)

        XCTAssertEqual(nearBounds.boundsMin, farBounds.boundsMin, "the placement's own bbox must be local, identical regardless of where in the world it's placed")
        XCTAssertEqual(nearBounds.boundsMax, farBounds.boundsMax, "the placement's own bbox must be local, identical regardless of where in the world it's placed")

        // Real bound sanity: the test mesh's own vertices span roughly
        // (0,0,0) to (1,1,0), the local bbox must stay in that
        // neighborhood, nowhere near the real (500,10,300) world position.
        XCTAssertLessThan(simd_length(farBounds.boundsMin), 5, "bbox must be local (small, near-origin), not offset by the real world position (500,10,300)")
        XCTAssertLessThan(simd_length(farBounds.boundsMax), 5, "bbox must be local (small, near-origin), not offset by the real world position (500,10,300)")

        // Every real placement on the pristine disc is exactly symmetric
        // (min == -max per axis), the test mesh's own local vertices are
        // NOT symmetric around origin ((0,0,0) to (1,1,0)), so this
        // specifically proves the symmetric-extent refinement, not just a
        // coincidence of a already-symmetric test mesh.
        XCTAssertEqual(farBounds.boundsMin, -farBounds.boundsMax, "the real on-disk format always stores a symmetric extent, not a true (possibly asymmetric) local AABB")
    }

    /// A screen-center click's ray passes exactly through the orbit
    /// target (that's what "orbit target" means for a look-at camera), so
    /// with a single placement at the world origin (making both the
    /// orbit target *and* the ground plane sit at `(0, 0, 0)`), a
    /// center-screen click must resolve to exactly the origin. This is the
    /// simplification `worldPositionOnGroundPlane`'s own doc comment
    /// describes (a plane intersection, not a real terrain raycast) , 
    /// verified numerically rather than trusted by inspection, since a
    /// sign error in the unprojection would silently place every object at
    /// the wrong depth.
    func testWorldPositionOnGroundPlaneHitsOrbitTargetAtScreenCenter() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, nil)]))
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        let hit = try XCTUnwrap(renderer.worldPositionOnGroundPlane(at: center, viewSize: viewSize, planeY: 0))

        XCTAssertEqual(hit.x, 0, accuracy: 0.01)
        XCTAssertEqual(hit.y, 0, accuracy: 0.01)
        XCTAssertEqual(hit.z, 0, accuracy: 0.01)
    }

    // MARK: - Top-Down/Minimap

    /// A straight-down view is exactly the case that breaks a naive
    /// `pitch = .pi/2` reuse of the orbit look-at math: `eye - target`
    /// would become parallel to the orbit camera's hardcoded
    /// `up = (0,1,0)`, collapsing `cross(up, z)` in `lookAtMatrix` to zero
    /// and producing a NaN view matrix (a blank/garbage viewport).
    /// `topDownViewProjection` avoids this with an explicit
    /// `up = (0,0,-1)`; verified end-to-end here since a regression back
    /// to the naive approach would silently produce NaNs rather than a
    /// compile error, and a NaN view matrix would make this either fail
    /// the unwrap or return garbage coordinates instead of the real,
    /// finite ground-plane hit at the orbit target.
    func testTopDownModeProducesAFiniteGroundHitAtScreenCenter() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, nil)]))
        renderer.isTopDownMode = true
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        let hit = try XCTUnwrap(renderer.worldPositionOnGroundPlane(at: center, viewSize: viewSize, planeY: 0))

        XCTAssertFalse(hit.x.isNaN)
        XCTAssertFalse(hit.z.isNaN)
        XCTAssertEqual(hit.x, 0, accuracy: 0.01)
        XCTAssertEqual(hit.y, 0, accuracy: 0.01)
        XCTAssertEqual(hit.z, 0, accuracy: 0.01)
    }

    /// Top-Down and Free Camera don't compose (an orthographic straight-
    /// down view plus a flying 6-DOF camera isn't a meaningful state) , 
    /// each toggling on must turn the other off, in both directions.
    func testTopDownModeAndFreeCameraAreMutuallyExclusive() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3<Float>(1, 1, 1), asset, nil)]))

        renderer.isFreeCameraMode = true
        renderer.isTopDownMode = true
        XCTAssertFalse(renderer.isFreeCameraMode)
        XCTAssertTrue(renderer.isTopDownMode)

        renderer.isFreeCameraMode = true
        XCTAssertTrue(renderer.isFreeCameraMode)
        XCTAssertFalse(renderer.isTopDownMode)
    }

    /// Samples a grid of pixels and counts roughly-distinct colors, cheap
    /// proxy for "did anything actually render" without needing exact pixel
    /// matching.
    private static func countApproxUniqueColors(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        let bytesPerPixel = 4
        let bytesPerRow = image.bytesPerRow
        var seen = Set<UInt32>()
        let step = 8
        var y = 0
        while y < image.height {
            var x = 0
            while x < image.width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 3 < data.count else { x += step; continue }
                // `dataProvider.data` returns the raw backing bytes as-is , 
                // it does NOT apply `CGImage`'s `bitmapInfo` reinterpretation,
                // so for a `.bgra8Unorm`-sourced image (every render path in
                // this file, see `ModelViewerRenderer.renderOffscreen`'s own
                // doc comment on `.byteOrder32Little`/`.premultipliedFirst`)
                // these bytes are genuinely B, G, R in that order, not R, G, B.
                // Order doesn't matter for this function's own bucketed
                // uniqueness count, but the names need to say what they
                // actually hold, a future channel-specific assertion built
                // on these locals would otherwise silently check the wrong
                // channel.
                let b = UInt32(data[offset]), g = UInt32(data[offset + 1]), r = UInt32(data[offset + 2])
                // Bucket to tolerate small lighting gradients while still catching "truly flat."
                let bucket = ((r / 16) << 8) | ((g / 16) << 4) | (b / 16)
                seen.insert(bucket)
                x += step
            }
            y += step
        }
        return seen.count
    }

    // MARK: - Hardware Performance Profiler (roadmap 9.4)

    func testVisibleCountsMatchTheSingleTriangleAsset() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let renderer = try XCTUnwrap(ModelViewerRenderer(asset: makeTestAsset()))
        XCTAssertEqual(renderer.visibleTriangleCount, 1)
        XCTAssertEqual(renderer.visibleDrawCallCount, 1)
        XCTAssertGreaterThan(renderer.gpuMemoryBytes, 0, "a real uploaded vertex/index buffer and texture must report nonzero allocated GPU memory")
    }

    func testHidingTheOnlySubmeshZeroesVisibleCountsButNotMemory() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let renderer = try XCTUnwrap(ModelViewerRenderer(asset: makeTestAsset()))
        let memoryBeforeHiding = renderer.gpuMemoryBytes

        renderer.hiddenSubmeshIndices = [0]
        XCTAssertEqual(renderer.visibleTriangleCount, 0, "a hidden submesh must not count toward what's actually drawn")
        XCTAssertEqual(renderer.visibleDrawCallCount, 0)
        XCTAssertEqual(renderer.gpuMemoryBytes, memoryBeforeHiding, "hiding a submesh doesn't free its GPU resources, so memory usage must stay the same")
    }

    // MARK: - AI Path connector visualization + endpoint editing

    private func makeWaypointNode(id: UInt32) -> ChunkNode {
        ChunkNode(recordID: id, sectionType: .aiPosition, displayName: "AIPosition #\(id)", byteSize: 18, fileOffset: 0, payload: nil)
    }

    private func makePathNode(id: UInt32) -> ChunkNode {
        ChunkNode(recordID: id, sectionType: .aiPath, displayName: "AIPath #\(id)", byteSize: 10, fileOffset: 0, payload: nil)
    }

    private func makeAIPathTestRenderer(
        waypoints: [(id: UInt32, position: SIMD3<Float>)],
        paths: [(id: UInt32, args: [UInt16])]
    ) throws -> LevelViewerRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let aiPositions = waypoints.map { (node: makeWaypointNode(id: $0.id), marker: AIPositionMarker(id: $0.id, position: SIMD4($0.position, 1), rawNodeType: 0)) }
        let aiPaths = paths.map { (node: makePathNode(id: $0.id), path: AIPathRecord(id: $0.id, args: $0.args)) }
        return try XCTUnwrap(LevelViewerRenderer(placements: [], aiPositions: aiPositions, aiPaths: aiPaths))
    }

    /// `currentAIPathArgs` must return the real, on-disk args for an
    /// existing path before any edit, the same values `AIPathInspectorView`
    /// would show.
    func testCurrentAIPathArgsReturnsOriginalArgsBeforeAnyEdit() throws {
        let renderer = try makeAIPathTestRenderer(
            waypoints: [(1, SIMD3(0, 0, 0)), (2, SIMD3(5, 0, 0))],
            paths: [(10, [1, 2, 0, 0, 0])]
        )
        XCTAssertEqual(renderer.currentAIPathArgs(id: 10), [1, 2, 0, 0, 0])
    }

    /// `settingAIPathArgs` on an existing path must actually change what
    /// `currentAIPathArgs` reports back, the real edit `applyPickedAIPathEndpoint`
    /// performs.
    func testSettingAIPathArgsUpdatesCurrentArgs() throws {
        let renderer = try makeAIPathTestRenderer(
            waypoints: [(1, SIMD3(0, 0, 0)), (2, SIMD3(5, 0, 0)), (3, SIMD3(0, 5, 0))],
            paths: [(10, [1, 2, 0, 0, 0])]
        )
        renderer.settingAIPathArgs(id: 10, args: [1, 3, 0, 0, 0])
        XCTAssertEqual(renderer.currentAIPathArgs(id: 10), [1, 3, 0, 0, 0])
    }

    /// `settingAIPathArgs` must no-op for an ID this renderer doesn't
    /// recognize as an existing path, real safety against a stale
    /// caller, not silently creating a phantom override entry.
    func testSettingAIPathArgsNoOpsForUnknownID() throws {
        let renderer = try makeAIPathTestRenderer(waypoints: [], paths: [(10, [1, 2, 0, 0, 0])])
        renderer.settingAIPathArgs(id: 999, args: [1, 2, 0, 0, 0])
        XCTAssertNil(renderer.currentAIPathArgs(id: 999))
    }

    /// `settingNewAIPathArgs` mutates a session-added path's own args in
    /// place, the `newAIPaths`-specific counterpart to `settingAIPathArgs`.
    func testSettingNewAIPathArgsUpdatesTheNewPathEntry() throws {
        let renderer = try makeAIPathTestRenderer(waypoints: [], paths: [])
        let newID = renderer.addAIPath(args: [0, 1, 0, 0, 0])
        renderer.settingNewAIPathArgs(id: newID, args: [5, 6, 0, 0, 0])
        XCTAssertEqual(renderer.currentAIPathArgs(id: newID), [5, 6, 0, 0, 0])
    }

    /// `pendingAIPathArgOverrides`, the save-time patch source, must
    /// re-encode *every* existing path (same "every real record, not just
    /// edited ones" convention `pendingLevelOverrides`/
    /// `pendingAIWaypointOverrides` already use), and the encoded bytes
    /// must reflect a live edit, not the stale on-disk value.
    func testPendingAIPathArgOverridesIncludesEveryExistingPathWithLiveArgs() throws {
        let renderer = try makeAIPathTestRenderer(
            waypoints: [(1, SIMD3(0, 0, 0)), (2, SIMD3(5, 0, 0)), (3, SIMD3(0, 5, 0))],
            paths: [(10, [1, 2, 0, 0, 0]), (11, [2, 3, 0, 0, 0])]
        )
        renderer.settingAIPathArgs(id: 10, args: [1, 3, 0, 0, 0])

        let overrides = renderer.pendingAIPathArgOverrides
        XCTAssertEqual(overrides.count, 2, "must include every existing path, not just the one that was edited")
        let editedEncoded = try XCTUnwrap(overrides.first { $0.node.recordID == 10 }?.encoded)
        XCTAssertEqual(editedEncoded, WorldPlacementWriter.writeAIPath([1, 3, 0, 0, 0]))
        let untouchedEncoded = try XCTUnwrap(overrides.first { $0.node.recordID == 11 }?.encoded)
        XCTAssertEqual(untouchedEncoded, WorldPlacementWriter.writeAIPath([2, 3, 0, 0, 0]), "an unedited path must still re-encode its real original args, not a blank/zeroed value")
    }

    /// `aiWaypointDisplayName` resolves a real, loaded waypoint's ID to its
    /// display name, what the AI Paths panel shows next to Start/End
    /// instead of a bare number.
    func testAIWaypointDisplayNameResolvesARealWaypoint() throws {
        let renderer = try makeAIPathTestRenderer(waypoints: [(7, SIMD3(1, 2, 3))], paths: [])
        XCTAssertEqual(renderer.aiWaypointDisplayName(id: 7), "AI Waypoint #7 (Ground)")
    }

    /// An ID that doesn't match any currently-loaded waypoint (a path's
    /// candidate arg that doesn't actually resolve, the exact "candidate,
    /// not confirmed" case `AIPathInspectorView` already documents) must
    /// return `nil`, not fabricate a name.
    func testAIWaypointDisplayNameReturnsNilForAnUnresolvedID() throws {
        let renderer = try makeAIPathTestRenderer(waypoints: [(7, SIMD3(1, 2, 3))], paths: [])
        XCTAssertNil(renderer.aiWaypointDisplayName(id: 999))
    }
}

/// "Scene Preview Mode" (roadmap 7.1), real oriented-box containment
/// tested directly, independent of any renderer/GPU state.
final class TriggerContainmentTests: XCTestCase {
    private func makeTrigger(position: SIMD4<Float>, size: SIMD4<Float>, rotationQuaternion: SIMD4<Float> = SIMD4(0, 0, 0, 1)) -> TriggerVolume {
        TriggerVolume(
            id: 1, header: 0, enabledMask: 0, someFloat: 0,
            rotationQuaternion: rotationQuaternion, position: position, size: size,
            instanceIDs: [], arg1: 0, arg2: 0, arg3: 0, arg4: 0
        )
    }

    func testPointInsideAxisAlignedTrigger() {
        let trigger = makeTrigger(position: SIMD4(0, 0, 0, 1), size: SIMD4(4, 4, 4, 1))
        XCTAssertTrue(LevelViewerRenderer.triggerContains(trigger, point: SIMD3(0, 0, 0)))
        XCTAssertTrue(LevelViewerRenderer.triggerContains(trigger, point: SIMD3(1.9, -1.9, 0)))
    }

    func testPointOutsideAxisAlignedTrigger() {
        let trigger = makeTrigger(position: SIMD4(0, 0, 0, 1), size: SIMD4(4, 4, 4, 1))
        XCTAssertFalse(LevelViewerRenderer.triggerContains(trigger, point: SIMD3(3, 0, 0)))
        XCTAssertFalse(LevelViewerRenderer.triggerContains(trigger, point: SIMD3(0, 0, 100)))
    }

    func testPointRespectsRealWorldOffset() {
        let trigger = makeTrigger(position: SIMD4(10, 20, 30, 1), size: SIMD4(2, 2, 2, 1))
        XCTAssertTrue(LevelViewerRenderer.triggerContains(trigger, point: SIMD3(10, 20, 30)))
        XCTAssertFalse(LevelViewerRenderer.triggerContains(trigger, point: SIMD3(0, 0, 0)))
    }

    /// A point that's outside the trigger's *axis-aligned* extent from its
    /// center, but inside once the trigger's real 90°-around-Y rotation is
    /// correctly undone first (a box 6 long on X, 1 on Z, rotated 90°
    /// around Y, becomes 1 long on X and 6 on Z in world space).
    func testPointRespectsRealRotation() {
        let rotation90AroundY = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        let trigger = makeTrigger(
            position: SIMD4(0, 0, 0, 1),
            size: SIMD4(6, 2, 1, 1),
            rotationQuaternion: SIMD4(rotation90AroundY.vector.x, rotation90AroundY.vector.y, rotation90AroundY.vector.z, rotation90AroundY.vector.w)
        )
        // World-space: this point is far along Z, just barely off X, only
        // inside if the box's long axis actually rotated with it.
        XCTAssertTrue(LevelViewerRenderer.triggerContains(trigger, point: SIMD3(0.4, 0, 2.9)))
        XCTAssertFalse(LevelViewerRenderer.triggerContains(trigger, point: SIMD3(2.9, 0, 0.4)))
    }

}
