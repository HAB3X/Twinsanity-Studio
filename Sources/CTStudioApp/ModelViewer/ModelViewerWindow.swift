import SwiftUI
import AppKit
import simd
import CTModels
import CTExport

/// The dedicated Model Viewer: a Metal viewport showing the fully resolved
/// (mesh + textures, and skeleton if rigged) asset on the left, and a
/// sidebar on the right with asset info, animation search/playback, and the
/// unified export action.
struct ModelViewerWindow: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let asset: ResolvedModelAsset

    @State private var renderer: ModelViewerRenderer?
    @State private var showSkeletonOverlay = false
    @State private var showCollisionVolume = false
    /// "Procedural Collision Decimation" (roadmap 4.4), computed on
    /// demand (not on every appear like the real collision-volume overlay
    /// above) since this is real GPU work, not a free lookup into
    /// already-decoded data.
    @State private var showProceduralOBB = false
    @State private var isComputingOBB = false
    @State private var animationSearch = ""
    @State private var selectedAnimation: AnimationAsset?
    @State private var currentFrame: Double = 0
    @State private var playbackTimer: Timer?
    @State private var isPlaying = false
    @State private var hiddenSubmeshIndices: Set<Int> = []
    @State private var isShaderGraphEditorPresented = false
    @State private var isDependencyCrateSheetPresented = false
    @State private var showHardwareProfiler = false

    // MARK: - "Procedural Animation Frame Blending" (roadmap 12.2)
    @State private var isBlendModeActive = false
    @State private var blendAnimationAID: UInt32?
    @State private var blendFrameA: Double = 0
    @State private var blendAnimationBID: UInt32?
    @State private var blendFrameB: Double = 0
    @State private var blendT: Double = 0.5

    // MARK: - "Vertex Color & Lightmap Baking Suite" (roadmap 10.3)
    @State private var isBaking = false
    @State private var aoSampleCount: Double = 24
    @State private var aoMaxDistance: Double = 2.0
    @State private var aoStrength: Double = 1.0
    @State private var lightAmbient: Double = 0.25
    @State private var lightIntensity: Double = 1.0
    /// Non-nil once a bake has been applied, the live-displayed geometry
    /// (`displayedAsset`) swaps to this instead of the original `asset`.
    /// Reset returns to `nil`, restoring the real, unmodified mesh.
    @State private var bakedAsset: ResolvedModelAsset?

    var body: some View {
        HStack(spacing: 0) {
            viewportArea
            Divider()
            sidebar
                .frame(width: 320)
        }
        .frame(minWidth: 900, minHeight: 600)
        // Performance fix (audit): same pattern already applied to the
        // Level Viewer and the WoC viewer, `ModelViewerRenderer.init?`
        // does real, unbounded-with-submesh-count GPU upload work
        // (`buildGPUSubmeshes`) synchronously; `.task` + `Task.detached`
        // moves it off the main actor without blocking window-open input,
        // and is auto-cancelled if the window closes first.
        .task {
            let built = await Task.detached(priority: .userInitiated) {
                ModelViewerRenderer(asset: asset)
            }.value
            guard !Task.isCancelled else { return }
            renderer = built
            updateCollisionVolumeOverlay()
        }
        .onDisappear { stopPlayback() }
        .onChange(of: showSkeletonOverlay) { _, _ in updateAnimationPose() }
        .onChange(of: selectedAnimation?.id) { _, _ in updateAnimationPose() }
        .onChange(of: currentFrame) { _, _ in updateAnimationPose() }
        .onChange(of: showCollisionVolume) { _, _ in updateCollisionVolumeOverlay() }
        .onChange(of: showProceduralOBB) { _, _ in updateProceduralOBBOverlay() }
        .onChange(of: isBlendModeActive) { _, isActive in
            if isActive {
                stopPlayback()
                updateBlendPose()
            } else {
                updateAnimationPose()
            }
        }
        .onChange(of: blendAnimationAID) { _, _ in updateBlendPose() }
        .onChange(of: blendFrameA) { _, _ in updateBlendPose() }
        .onChange(of: blendAnimationBID) { _, _ in updateBlendPose() }
        .onChange(of: blendFrameB) { _, _ in updateBlendPose() }
        .onChange(of: blendT) { _, _ in updateBlendPose() }
        .sheet(isPresented: $isDependencyCrateSheetPresented) {
            CrateExportSheet(
                suggestedName: asset.displayName,
                caption: "\"Cross-Object Dependency Packaging\" (blueprint 3.2): bundles this asset's mesh (OBJ), every resolved texture (PNG), a material map (MTL), and decoded animation data into one real CrateModLoader-installable .crate, the same linked dependencies \"Export Complete Asset\" writes as a loose folder, packaged as a portable mod instead."
            ) { metadata, url in
                Task { await workspace.exportCompleteAssetAsCrate(asset, metadata: metadata, to: url) }
            }
        }
    }

    /// "Collision Mask Alignment": real per-object `GI_CollisionData` boxes
    /// (see `GraphicsInfoCollisionData`'s doc comment), drawn independently
    /// of animation/skeleton-overlay state, a static prop with collision
    /// data but no skeleton joints to animate should still be able to show
    /// its collision volume.
    private func updateCollisionVolumeOverlay() {
        guard showCollisionVolume, let collisionData = asset.skeleton?.collisionData, !collisionData.isEmpty else {
            renderer?.collisionVolumeWorldPositions = []
            return
        }
        renderer?.collisionVolumeWorldPositions = collisionData.flatMap { ModelViewerRenderer.collisionBoxEdges(corners: $0.positions) }
    }

    /// Drives both the actual mesh deformation (`applySkeletalPose`/
    /// `resetToBindPose`, the "Parent Object" itself visibly playing the
    /// animation, per this session's "Parent Object Mandate") and the
    /// optional skeleton line overlay, using the real, verified pose at the
    /// current playback frame (`AnimationSkeletonBinding`), not the old
    /// `ExperimentalAnimationPose` guess. Mesh deformation always runs when
    /// an animation is selected, independent of whether the debug skeleton
    /// overlay is toggled on; the overlay is a visualization aid on top of
    /// that, not a prerequisite for it.
    private func updateAnimationPose() {
        guard !isBlendModeActive else { return } // blend mode owns the pose while active, see updateBlendPose()
        guard let skeleton = asset.skeleton else {
            renderer?.skeletonJointWorldPositions = []
            return
        }
        guard let selectedAnimation else {
            renderer?.resetToBindPose()
            renderer?.skeletonJointWorldPositions = showSkeletonOverlay ? AnimationSkeletonBinding.bindPoseJointSegments(skeleton: skeleton) : []
            return
        }
        let frameIndex = min(selectedAnimation.body.totalFrames - 1, max(0, Int(currentFrame)))
        renderer?.applySkeletalPose(skeleton: skeleton, track: selectedAnimation.body, frameIndex: frameIndex)
        renderer?.skeletonJointWorldPositions = showSkeletonOverlay
            ? AnimationSkeletonBinding.jointSegments(skeleton: skeleton, track: selectedAnimation.body, frameIndex: frameIndex)
            : []
    }

    /// "Procedural Animation Frame Blending" (roadmap 12.2): applies the
    /// real blended pose (`ModelViewerRenderer.applyBlendedSkeletalPose`)
    /// live as any of the blend controls change. No-ops (leaves whatever
    /// pose is currently applied) until both sides have a real animation
    /// and frame chosen, never blends against a fabricated default.
    private func updateBlendPose() {
        guard isBlendModeActive, let skeleton = asset.skeleton,
              let animationA = asset.availableAnimations.first(where: { $0.id == blendAnimationAID }),
              let animationB = asset.availableAnimations.first(where: { $0.id == blendAnimationBID })
        else { return }
        let frameA = min(animationA.body.totalFrames - 1, max(0, Int(blendFrameA)))
        let frameB = min(animationB.body.totalFrames - 1, max(0, Int(blendFrameB)))
        renderer?.applyBlendedSkeletalPose(skeleton: skeleton, trackA: animationA.body, frameA: frameA, trackB: animationB.body, frameB: frameB, t: Float(blendT))
    }

    @ViewBuilder
    private var viewportArea: some View {
        if let renderer {
            if renderer.hasGeometry {
                // `MetalModelView` wraps an `NSViewRepresentable` `MTKView`,
                // which has no intrinsic content size SwiftUI can infer.
                // `maxWidth/maxHeight: .infinity` alone visibly reserves the
                // space (confirmed, the viewport area isn't collapsed) but
                // still isn't a concrete number for a `.sheet()`'s first
                // layout pass to resolve against, and empirically that's
                // enough for the underlying `MTKView`/`CAMetalLayer` to end
                // up not actually driving pixels even though the area looks
                // right. `CompositePreviewView`'s inline preview, which
                // *does* render correctly, gives its own `MetalModelView` a
                // hard `.frame(height: 320)`; a real min alongside the max
                // is the same fix without hardcoding this one to a fixed
                // size.
                ZStack(alignment: .bottomLeading) {
                    MetalModelView(renderer: renderer)
                        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    Text("Drag to orbit · Scroll to zoom")
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                    if showHardwareProfiler {
                        HardwareProfilerHUDView(
                            triangleCount: renderer.visibleTriangleCount,
                            drawCallCount: renderer.visibleDrawCallCount,
                            gpuMemoryBytes: renderer.gpuMemoryBytes
                        )
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The asset resolved (mesh + material lookups all
                // succeeded), but every submesh ended up with zero
                // triangles after upload, surface that plainly instead of
                // showing an indistinguishable-from-broken blank canvas.
                ContentUnavailableView(
                    "No Drawable Geometry",
                    systemImage: "cube.transparent",
                    description: Text("This model resolved (\(asset.mesh.submeshes.count) submesh(es)), but none produced any triangles to draw, the source mesh record may be empty or use an unsupported strip layout.")
                )
            }
        } else {
            ContentUnavailableView("Metal Unavailable", systemImage: "exclamationmark.triangle", description: Text("Couldn't initialize a Metal device on this Mac."))
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(asset.displayName)
                    .font(.title3.bold())
                    .lineLimit(2)

                infoSection
                Divider()
                componentVisibilitySection
                Divider()
                if asset.skeleton != nil {
                    ExperimentalFieldsWarningView()
                    skeletonSection
                    Divider()
                }
                animationSection
                if asset.skeleton != nil, asset.availableAnimations.count >= 1 {
                    Divider()
                    blendSection
                }
                Divider()
                vertexColorBakingSection
                Divider()
                exportSection
            }
            .padding(16)
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Asset Info", systemImage: "info.circle").font(.headline)
            LabeledContent("Submeshes", value: "\(asset.mesh.submeshes.count)")
            LabeledContent("Vertices", value: "\(asset.mesh.totalVertexCount)")
            LabeledContent("Triangles", value: "\(asset.mesh.totalTriangleCount)")
            let texturedCount = asset.submeshMaterials.filter { $0.texture != nil }.count
            LabeledContent("Textured Submeshes", value: "\(texturedCount) / \(asset.submeshMaterials.count)")
            if !asset.isFullyTextured {
                Label("Some submeshes have no resolved texture (missing material/texture link), shown in white.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// "Granular Component Visibility": a checklist of the materials/
    /// textures making up this object, unchecking one hides every submesh
    /// that uses it in the viewport immediately (see
    /// `ModelViewerRenderer.hiddenSubmeshIndices`). Built from the same
    /// `RelationalChain` the inspector's relational-chain panel uses, so
    /// the two stay in agreement about what this object is made of.
    private var componentVisibilitySection: some View {
        let toggleable = RelationalChain(asset: asset).components.filter {
            ($0.kind == .material || $0.kind == .texture) && !$0.submeshIndices.isEmpty
        }
        return VStack(alignment: .leading, spacing: 6) {
            Label("Components", systemImage: "checklist").font(.headline)
            if toggleable.isEmpty {
                Text("No separately toggleable components.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(toggleable) { component in
                    Toggle(component.displayName, isOn: visibilityBinding(for: component))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func visibilityBinding(for component: LinkedComponent) -> Binding<Bool> {
        Binding(
            get: { !component.submeshIndices.contains(where: hiddenSubmeshIndices.contains) },
            set: { isVisible in
                if isVisible {
                    hiddenSubmeshIndices.subtract(component.submeshIndices)
                } else {
                    hiddenSubmeshIndices.formUnion(component.submeshIndices)
                }
                renderer?.hiddenSubmeshIndices = hiddenSubmeshIndices
            }
        )
    }

    private var skeletonSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Skeleton", systemImage: "figure.stand").font(.headline)
            if let skeleton = asset.skeleton {
                LabeledContent("Joints", value: "\(skeleton.joints.count)")
            }
            Toggle("Show Skeleton Overlay".tagged(.experimental), isOn: $showSkeletonOverlay)
                .toggleStyle(.checkbox)
            Text("Bind-pose joint positions are a best-effort visualization, the exact matrix layout isn't fully confirmed. Select an animation below to see an experimental (illustrative, not verified-accurate) animated pose instead.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let collisionData = asset.skeleton?.collisionData, !collisionData.isEmpty {
                Toggle("Show Collision Volume (\(collisionData.count))", isOn: $showCollisionVolume)
                    .toggleStyle(.checkbox)
                Text("Real per-object collision data (GI_CollisionData), decoded and drawn in orange, box extent only; whether the on-disk points are meant as an oriented hull or a plain axis-aligned box isn't confirmed, so this always draws their axis-aligned bounds.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Label("Procedural Collision Decimation", systemImage: "cube.transparent").font(.subheadline.bold())
            Toggle(isComputingOBB ? "Computing…" : "Show Computed OBB (cyan)", isOn: $showProceduralOBB)
                .toggleStyle(.checkbox)
                .disabled(isComputingOBB)
            Text("This tool's own computed oriented bounding box (Metal compute: parallel mean/covariance reduction + principal-axis fit) over this mesh's real vertex positions, not decoded game data, a real algorithm run on this asset's own geometry, tighter than a plain axis-aligned box for anything not already axis-aligned.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()
            Label("Hardware Profiler", systemImage: "speedometer").font(.subheadline.bold())
            Toggle("Show Performance HUD", isOn: $showHardwareProfiler)
                .toggleStyle(.checkbox)
            Text("Real triangle/draw-call counts and real GPU memory usage for this asset, against the PS2 Graphics Synthesizer's and original Xbox's real, documented memory capacities.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()
            Label("Shader Graph", systemImage: "point.3.filled.connected.trianglepath.dotted").font(.subheadline.bold())
            Button {
                isShaderGraphEditorPresented = true
            } label: {
                Label("Open Shader Graph Editor…", systemImage: "slider.horizontal.3")
            }
            .disabled(renderer == nil)
            Text("A real, original node-based material editor, compiles to actual Metal Shading Language and previews live, right here, in this viewport. Not a decoded Twinsanity material format; this tool's own authoring system.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $isShaderGraphEditorPresented) {
            if let renderer {
                ShaderGraphEditorView(renderer: renderer)
            }
        }
    }

    private func updateProceduralOBBOverlay() {
        guard showProceduralOBB else {
            renderer?.proceduralOBBWorldPositions = []
            return
        }
        guard let device = renderer?.device else { return }
        isComputingOBB = true
        let mesh = asset.mesh
        Task.detached(priority: .userInitiated) {
            let obb = CollisionDecimator.computeOrientedBoundingBox(mesh: mesh, device: device)
            await MainActor.run {
                isComputingOBB = false
                guard showProceduralOBB, let obb else {
                    renderer?.proceduralOBBWorldPositions = []
                    return
                }
                renderer?.proceduralOBBWorldPositions = ModelViewerRenderer.orientedBoxEdges(corners: obb.corners)
            }
        }
    }

    private var animationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Animations (\(asset.availableAnimations.count))", systemImage: "play.circle").font(.headline)
            if asset.availableAnimations.isEmpty {
                Text("No animations found in this file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Filter by ID…", text: $animationSearch)
                    .textFieldStyle(.roundedBorder)

                List(filteredAnimations, id: \.id, selection: Binding(
                    get: { selectedAnimation?.id },
                    set: { newID in
                        stopPlayback()
                        selectedAnimation = asset.availableAnimations.first { $0.id == newID }
                        currentFrame = 0
                    }
                )) { animation in
                    HStack {
                        Text("Animation #\(animation.id)")
                        Spacer()
                        Text("\(animation.body.totalFrames)f")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(animation.id)
                }
                .frame(height: 140)
                .listStyle(.bordered)

                if let selectedAnimation, selectedAnimation.body.totalFrames > 1 {
                    playbackControls(for: selectedAnimation)
                }
            }
        }
    }

    private func playbackControls(for animation: AnimationAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    togglePlayback(frameCount: animation.body.totalFrames)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(isPlaying ? "Pause Animation" : "Play Animation")
                Slider(value: $currentFrame, in: 0...Double(animation.body.totalFrames - 1), step: 1)
                Text("\(Int(currentFrame))/\(animation.body.totalFrames - 1)")
                    .font(.caption.monospacedDigit())
                    .frame(width: 50, alignment: .trailing)
            }
            let frameIndex = min(animation.body.totalFrames - 1, max(0, Int(currentFrame)))
            let frame = animation.body.frames[frameIndex]
            Text("Frame \(frameIndex): \(frame.values.count) channel value(s), see the Animation record's own inspector for the full breakdown.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// "Procedural Animation Frame Blending" (roadmap 12.2): a real,
    /// live-previewed blend between two independently chosen animations
    /// (or two points in the same one). Deliberately a live preview only , 
    /// this build has no verified byte-exact `AnimationAsset` writer, so
    /// "bake the blended frames into a new exportable animation" isn't
    /// attempted; the real, demonstrable capability is the interpolation
    /// itself, shown live in the viewport.
    private var blendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isBlendModeActive) {
                Label("Blend Two Animations", systemImage: "square.stack.3d.forward.dottedline")
            }
            .toggleStyle(.checkbox)

            if isBlendModeActive {
                Picker("Animation A", selection: $blendAnimationAID) {
                    Text("None").tag(UInt32?.none)
                    ForEach(asset.availableAnimations, id: \.id) { animation in
                        Text("#\(animation.id) (\(animation.body.totalFrames)f)").tag(UInt32?.some(animation.id))
                    }
                }
                if let animationA = asset.availableAnimations.first(where: { $0.id == blendAnimationAID }), animationA.body.totalFrames > 1 {
                    Slider(value: $blendFrameA, in: 0...Double(animationA.body.totalFrames - 1), step: 1) {
                        Text("Frame A")
                    }
                }

                Picker("Animation B", selection: $blendAnimationBID) {
                    Text("None").tag(UInt32?.none)
                    ForEach(asset.availableAnimations, id: \.id) { animation in
                        Text("#\(animation.id) (\(animation.body.totalFrames)f)").tag(UInt32?.some(animation.id))
                    }
                }
                if let animationB = asset.availableAnimations.first(where: { $0.id == blendAnimationBID }), animationB.body.totalFrames > 1 {
                    Slider(value: $blendFrameB, in: 0...Double(animationB.body.totalFrames - 1), step: 1) {
                        Text("Frame B")
                    }
                }

                LabeledContent("Blend") { Slider(value: $blendT, in: 0...1) }
                Text(String(format: "t = %.2f", blendT))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text("Real per-joint interpolation (translation/scale linear, rotation via quaternion slerp) between the two chosen frames, live in the viewport, turning it off restores normal playback.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "Vertex Color & Lightmap Baking Suite" (roadmap 10.3): bakes real
    /// directional (Lambertian) shading and/or real ray-cast ambient
    /// occlusion (`VertexColorBaker`) into this asset's own vertex colors,
    /// live-previewed by swapping the renderer to a new
    /// `ResolvedModelAsset` carrying the baked mesh. Runs off the main
    /// thread, AO in particular is a real ray-triangle intersection test
    /// per sample per vertex, not instant for a large mesh.
    private var vertexColorBakingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Vertex Color Baking", systemImage: "sun.max").font(.headline)

            Text("Directional Light").font(.caption.bold())
            LabeledContent("Ambient") { Slider(value: $lightAmbient, in: 0...1) }
            LabeledContent("Intensity") { Slider(value: $lightIntensity, in: 0...3) }
            Button("Bake Directional Light") { bakeDirectionalLight() }
                .disabled(isBaking)

            Divider()

            Text("Ambient Occlusion").font(.caption.bold())
            LabeledContent("Samples") { Slider(value: $aoSampleCount, in: 4...64, step: 4) }
            LabeledContent("Max Distance") { Slider(value: $aoMaxDistance, in: 0.1...10) }
            LabeledContent("Strength") { Slider(value: $aoStrength, in: 0...1) }
            Button("Bake Ambient Occlusion") { bakeAmbientOcclusion() }
                .disabled(isBaking)

            if isBaking {
                HStack { ProgressView().controlSize(.small); Text("Baking…").font(.caption).foregroundStyle(.secondary) }
            }
            if bakedAsset != nil {
                Button("Reset to Original Colors") { resetBake() }
            }

            Text("Real, original bakes computed by this tool over its own already-decoded mesh data (standard Lambertian shading; hemisphere-sampled ray-cast occlusion, Möller–Trumbore), not a recovery of the original game's own undecoded baking pipeline. Preview only until exported.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func bakeDirectionalLight() {
        isBaking = true
        let sourceMesh = bakedAsset?.mesh ?? asset.mesh
        let ambient = Float(lightAmbient), intensity = Float(lightIntensity)
        Task.detached(priority: .userInitiated) {
            let baked = VertexColorBaker.bakeDirectionalLight(sourceMesh, lightDirection: SIMD3(-0.4, -1.0, -0.3), ambient: ambient, intensity: intensity)
            await MainActor.run { applyBakedMesh(baked) }
        }
    }

    private func bakeAmbientOcclusion() {
        isBaking = true
        let sourceMesh = bakedAsset?.mesh ?? asset.mesh
        let samples = Int(aoSampleCount), maxDistance = Float(aoMaxDistance), strength = Float(aoStrength)
        Task.detached(priority: .userInitiated) {
            let baked = VertexColorBaker.bakeAmbientOcclusion(sourceMesh, sampleCount: samples, maxDistance: maxDistance, strength: strength)
            await MainActor.run { applyBakedMesh(baked) }
        }
    }

    @MainActor
    private func applyBakedMesh(_ mesh: MeshAsset) {
        var newAsset = bakedAsset ?? asset
        newAsset.mesh = mesh
        bakedAsset = newAsset
        renderer = ModelViewerRenderer(asset: newAsset)
        updateAnimationPose()
        updateCollisionVolumeOverlay()
        isBaking = false
    }

    private func resetBake() {
        bakedAsset = nil
        renderer = ModelViewerRenderer(asset: asset)
        updateAnimationPose()
        updateCollisionVolumeOverlay()
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Export", systemImage: "square.and.arrow.up").font(.headline)
            preFlightCheckView
            Button {
                exportCompleteAsset()
            } label: {
                Label("Export Complete Asset…", systemImage: "shippingbox")
            }
            Text("Bundles the mesh (OBJ), every resolved texture (PNG), a material map (MTL), and decoded animation data into one folder.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isDependencyCrateSheetPresented = true
            } label: {
                Label("Export with Dependencies…", systemImage: "shippingbox.and.arrow.backward")
            }
            Text("Same bundle, packaged as a portable .crate mod instead of a loose folder.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// "Pre-Flight Mod Auditor" (roadmap 9.3): a real summary shown before
    /// export, limited to what this build actually knows for certain , 
    /// texture completeness (`asset.isFullyTextured`, already tracked) and
    /// this asset's real GPU memory footprint against the PS2 Graphics
    /// Synthesizer's real, documented 4MB VRAM budget (the same verified
    /// figure `HardwareProfilerHUDView` compares against). Not a fabricated
    /// "will this soft-lock the game" verdict, this build has no decoded
    /// pointer/dependency graph to actually audit for that.
    private var preFlightCheckView: some View {
        VStack(alignment: .leading, spacing: 4) {
            preFlightRow(
                ok: asset.isFullyTextured,
                okText: "Every submesh has a resolved texture",
                failText: "Some submesh(es) have no resolved texture, would place as untextured in-game"
            )
            if let renderer {
                let budgetBytes = 4 * 1024 * 1024
                let withinBudget = renderer.gpuMemoryBytes <= budgetBytes
                let memoryText = ByteCountFormatter.string(fromByteCount: Int64(renderer.gpuMemoryBytes), countStyle: .memory)
                preFlightRow(
                    ok: withinBudget,
                    okText: "GPU memory (\(memoryText)) fits within the PS2 GS's real 4MB VRAM budget",
                    failText: "GPU memory (\(memoryText)) exceeds the PS2 GS's real 4MB VRAM budget on its own"
                )
            }
        }
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
    }

    private func preFlightRow(ok: Bool, okText: String, failText: String) -> some View {
        Label(ok ? okText : failText, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(ok ? Color.secondary : Color.orange)
    }

    private var filteredAnimations: [AnimationAsset] {
        guard !animationSearch.isEmpty else {
            return asset.availableAnimations.sorted { $0.id < $1.id }
        }
        return asset.availableAnimations
            .filter { String($0.id).contains(animationSearch) }
            .sorted { $0.id < $1.id }
    }

    private func togglePlayback(frameCount: Int) {
        isPlaying.toggle()
        if isPlaying {
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                currentFrame = (currentFrame + 1).truncatingRemainder(dividingBy: Double(max(1, frameCount)))
            }
        } else {
            playbackTimer?.invalidate()
            playbackTimer = nil
        }
    }

    private func stopPlayback() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
    }


    private func exportCompleteAsset() {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this model, its textures, and its animations into.") else { return }
        Task { await workspace.exportCompleteAsset(asset, to: directory) }
    }
}
