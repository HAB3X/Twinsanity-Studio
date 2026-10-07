import SwiftUI
import simd
import CTModels

/// "Collision Mesh & Trigger Overlays" (blueprint 4.1): a dedicated Metal
/// viewport for a level's `ColData` collision mesh, rendered as a blue
/// wireframe, reusing the same orbit camera and line-drawing pipeline
/// `ModelViewerRenderer` already built for the skeleton overlay, just fed
/// collision triangle edges instead of joint segments.
struct CollisionViewerWindow: View {
    let mesh: CollisionMesh

    @State private var renderer: ModelViewerRenderer?
    @State private var colorBySurface = false

    // MARK: - "Local Physics & Collision Playground" (roadmap 12.1)
    @State private var physicsBall: PhysicsPlayground?
    @State private var physicsTimer: Timer?
    @State private var gravity: Double = -9.8
    @State private var restitution: Double = 0.5
    @State private var friction: Double = 0.3
    @State private var ballRadius: Double = 0.5
    /// Computed once from the mesh's own real vertex positions, not
    /// re-derived every physics step.
    @State private var worldTriangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
    @State private var dropPoint: SIMD3<Float> = .zero

    var body: some View {
        HStack(spacing: 0) {
            viewportArea
            Divider()
            sidebar
                .frame(width: 280)
        }
        .frame(minWidth: 820, minHeight: 560)
        // Performance fix (audit): same off-main renderer-build pattern as
        // the other GPU viewer windows. `computeWorldTrianglesAndDropPoint`
        // only reads `mesh` (a plain value type), not `renderer`, so it
        // stays on `.onAppear` and doesn't need to wait for the build.
        .onAppear { computeWorldTrianglesAndDropPoint() }
        .task {
            let built = await Task.detached(priority: .userInitiated) {
                ModelViewerRenderer(collisionMesh: mesh)
            }.value
            guard !Task.isCancelled else { return }
            renderer = built
        }
        .onChange(of: colorBySurface) { _, newValue in
            renderer?.collisionColorMode = newValue ? .bySurfaceID : .solid
        }
        .onDisappear { stopPhysics() }
    }

    /// Real triangle positions straight from the mesh's own decoded
    /// vertices/indices, the exact same geometry the wireframe overlay
    /// draws, so "drop a ball" is always testing against what's actually
    /// on screen. `dropPoint` starts centered above the mesh's real
    /// bounding box, high enough to fall onto it rather than through
    /// empty space to one side.
    private func computeWorldTrianglesAndDropPoint() {
        worldTriangles = mesh.triangles.compactMap { triangle in
            guard mesh.vertices.indices.contains(triangle.vertexIndex1),
                  mesh.vertices.indices.contains(triangle.vertexIndex2),
                  mesh.vertices.indices.contains(triangle.vertexIndex3)
            else { return nil }
            let v1 = mesh.vertices[triangle.vertexIndex1], v2 = mesh.vertices[triangle.vertexIndex2], v3 = mesh.vertices[triangle.vertexIndex3]
            return (SIMD3(v1.x, v1.y, v1.z), SIMD3(v2.x, v2.y, v2.z), SIMD3(v3.x, v3.y, v3.z))
        }
        guard !mesh.vertices.isEmpty else { return }
        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices {
            let p = SIMD3(v.x, v.y, v.z)
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let center = (minP + maxP) / 2
        dropPoint = SIMD3(center.x, maxP.y + (maxP.y - minP.y) * 0.5 + 1, center.z)
    }

    private func dropBall() {
        stopPhysics()
        var ball = PhysicsPlayground(position: dropPoint, radius: Float(ballRadius))
        ball.gravity = Float(gravity)
        ball.restitution = Float(restitution)
        ball.friction = Float(friction)
        physicsBall = ball
        updateBallOverlay()
        physicsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            guard physicsBall != nil else { return }
            physicsBall?.step(deltaTime: 1.0 / 60.0, against: worldTriangles)
            updateBallOverlay()
        }
    }

    private func stopPhysics() {
        physicsTimer?.invalidate()
        physicsTimer = nil
        physicsBall = nil
        renderer?.physicsBallWorldPositions = []
    }

    private func updateBallOverlay() {
        guard let physicsBall else { return }
        renderer?.physicsBallWorldPositions = ModelViewerRenderer.sphereEdges(center: physicsBall.position, radius: physicsBall.radius)
    }

    @ViewBuilder
    private var viewportArea: some View {
        if let renderer {
            if renderer.hasCollisionWireframe {
                // See `ModelViewerWindow`'s matching comment, a `maxWidth/
                // maxHeight: .infinity`-only frame isn't a concrete enough
                // size for a `.sheet()`'s first layout pass to reliably
                // drive the underlying `MTKView`'s `CAMetalLayer` from; a
                // real minimum alongside it is.
                ZStack(alignment: .bottomLeading) {
                    MetalModelView(renderer: renderer)
                        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    Text("Drag to orbit · Scroll to zoom")
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Collision Geometry",
                    systemImage: "square.grid.3x1.below.line.grid.1x2",
                    description: Text("This record has no vertices/triangles to draw.")
                )
            }
        } else {
            ContentUnavailableView("Metal Unavailable", systemImage: "exclamationmark.triangle", description: Text("Couldn't initialize a Metal device on this Mac."))
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Collision Mesh #\(mesh.id)")
                    .font(.title3.bold())

                Form {
                    LabeledContent("Triangles", value: "\(mesh.triangles.count)")
                    LabeledContent("Vertices", value: "\(mesh.vertices.count)")
                    LabeledContent("Spatial Groups", value: "\(mesh.groups.count)")
                    LabeledContent("Trigger Boxes", value: "\(mesh.triggerBoxes.count)")
                }
                .formStyle(.grouped)

                Toggle("Color by Surface ID", isOn: $colorBySurface)
                    .toggleStyle(.checkbox)

                if colorBySurface {
                    surfaceLegend
                }

                Text(colorBySurface
                     ? "Each color is one raw, decoded surfaceID from the collision data, not a semantic category like \"deadly\" or \"solid.\" That classification lives in the undecoded CollisionSurface/Object records this build doesn't have a verified mapping for; coloring by the real ID still makes distinct physical-material regions visible without guessing at what they mean."
                     : "Every triangle edge is drawn, shared edges between adjacent triangles overlap rather than being deduplicated.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()
                physicsPlaygroundSection
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var surfaceLegend: some View {
        let ids = renderer?.collisionSurfaceIDs ?? []
        VStack(alignment: .leading, spacing: 4) {
            Text("Surface IDs (\(ids.count))")
                .font(.caption.bold())
            ForEach(ids.prefix(24), id: \.self) { surfaceID in
                HStack(spacing: 6) {
                    let c = ModelViewerRenderer.color(forSurfaceID: surfaceID)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
                        .frame(width: 12, height: 12)
                    Text("#\(surfaceID)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if ids.count > 24 {
                Text("+ \(ids.count - 24) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// "Local Physics & Collision Playground" (roadmap 12.1): drops a real
    /// simulated sphere and steps it against this mesh's own real
    /// triangles at 60Hz, live. Gravity/restitution/friction are exactly
    /// what the roadmap calls for, user-adjustable test values ("slippery
    /// ice or bouncy crates"), not a recreation of the shipped game's own
    /// physics tuning, which this codebase has no decoded/verified model
    /// of.
    private var physicsPlaygroundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Physics Playground", systemImage: "circle.circle").font(.subheadline.bold())

            LabeledContent("Gravity") { Slider(value: $gravity, in: -30...0) }
            LabeledContent("Restitution") { Slider(value: $restitution, in: 0...1) }
            LabeledContent("Friction") { Slider(value: $friction, in: 0...1) }
            LabeledContent("Ball Radius") { Slider(value: $ballRadius, in: 0.1...5) }

            if let physicsBall {
                Text("y = \(String(format: "%.2f", physicsBall.position.y))  |  speed = \(String(format: "%.2f", simd_length(physicsBall.velocity)))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Drop Ball") { dropBall() }
                    .disabled(worldTriangles.isEmpty)
                if physicsBall != nil {
                    Button("Stop") { stopPhysics() }
                }
            }

            Text("A real local simulation (gravity + sphere-vs-triangle collision) against this mesh's own real geometry, entirely offline, not connected to any emulator, and not a claim this matches the original game's own physics tuning.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
