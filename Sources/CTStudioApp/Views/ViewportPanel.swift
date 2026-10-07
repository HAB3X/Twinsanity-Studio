import SwiftUI
import SceneKit
import simd
import CTModels

/// "Universal Asset Inspector": the right-hand pane used to be a 3D-only
/// preview that showed nothing at all for anything but a Model/Skin
/// record. It now routes on the selected node's real decoded `payload` , 
/// a live SceneKit preview for meshes (unchanged), the same
/// `TextureInspectorView`/`SoundEffectInspectorView` the rest of the app
/// already uses for images/audio (reused, not duplicated, so there's one
/// texture-decode path and one audio-playback path), a real oriented-box
/// visualization for Triggers/Cameras built from their actual decoded
/// position/rotation/size (the same math `ModelViewerRenderer.
/// triggerContains` uses), and a live hex dump for anything else that has
/// raw bytes but no typed decoder, never a fabricated view for a payload
/// kind this build doesn't actually understand.
struct ViewportPanel: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode?

    var body: some View {
        Group {
            switch node?.payload {
            case .mesh(let mesh):
                SceneKitMeshView(mesh: mesh)
                    .id(node?.id) // rebuild the scene when the selection changes
            case .texture(let texture):
                if let node {
                    ScrollView { TextureInspectorView(node: node, texture: texture).padding() }
                }
            case .soundEffect(let sound):
                if let node {
                    ScrollView { SoundEffectInspectorView(node: node, displayName: node.displayName, sound: sound).padding() }
                }
            case .trigger(let trigger):
                VolumeSceneView(
                    position: SIMD3(trigger.position.x, trigger.position.y, trigger.position.z),
                    rotationQuaternion: trigger.rotationQuaternion,
                    size: SIMD3(trigger.size.x, trigger.size.y, trigger.size.z),
                    color: .red,
                    label: "Trigger #\(trigger.id)"
                )
                .id(node?.id)
            case .camera(let camera):
                VolumeSceneView(
                    position: SIMD3(camera.position.x, camera.position.y, camera.position.z),
                    rotationQuaternion: camera.rotationQuaternion,
                    size: SIMD3(camera.size.x, camera.size.y, camera.size.z),
                    color: .yellow,
                    label: "Camera #\(camera.id)"
                )
                .id(node?.id)
            default:
                if let node, node.byteSize > 0, let bytes = workspace.rawBytes(for: node) {
                    RawBytesPreview(node: node, bytes: bytes)
                } else {
                    ContentUnavailableView(
                        "No Preview",
                        systemImage: "cube.transparent",
                        description: Text("Select a Model, Texture, Sound, Trigger, Camera, or any record with raw bytes to preview it here.")
                    )
                }
            }
        }
        .frame(minWidth: 320)
    }
}

/// A real oriented box built from a Trigger or Camera record's actual
/// decoded `position`/`rotationQuaternion`/`size`, the same fields (and
/// the same "size is full extents, halve for the box" convention)
/// `ModelViewerRenderer.triggerContains` already uses for real geometric
/// containment testing. This is a decoded-data visualization, not a claim
/// about what a Camera's `size` field represents semantically (e.g. a view
/// frustum), that meaning isn't confirmed anywhere in the reference
/// source, so the box is labeled by record kind/ID only.
struct VolumeSceneView: NSViewRepresentable {
    let position: SIMD3<Float>
    let rotationQuaternion: SIMD4<Float>
    let size: SIMD3<Float>
    let color: NSColor
    let label: String

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = NSColor.controlBackgroundColor
        view.scene = buildScene()
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        nsView.scene = buildScene()
    }

    private func buildScene() -> SCNScene {
        let scene = SCNScene()
        let extents = SIMD3(max(size.x, 0.1), max(size.y, 0.1), max(size.z, 0.1))

        let box = SCNBox(width: CGFloat(extents.x), height: CGFloat(extents.y), length: CGFloat(extents.z), chamferRadius: 0)
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(0.35)
        material.isDoubleSided = true
        box.materials = [material]
        let boxNode = SCNNode(geometry: box)
        let q = simd_quatf(vector: rotationQuaternion)
        boxNode.simdOrientation = q
        scene.rootNode.addChildNode(boxNode)

        let axes = SCNNode()
        axes.addChildNode(axisLine(to: SCNVector3(extents.x, 0, 0), color: .systemRed))
        axes.addChildNode(axisLine(to: SCNVector3(0, extents.y, 0), color: .systemGreen))
        axes.addChildNode(axisLine(to: SCNVector3(0, 0, extents.z), color: .systemBlue))
        scene.rootNode.addChildNode(axes)

        let radius = max(extents.x, extents.y, extents.z, 1)
        let camera = SCNCamera()
        camera.zFar = Double(radius) * 20
        camera.zNear = 0.01
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, radius * 0.8, radius * 2.2)
        cameraNode.look(at: SCNVector3.init(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        return scene
    }

    private func axisLine(to end: SCNVector3, color: NSColor) -> SCNNode {
        let indices: [Int32] = [0, 1]
        let vertices: [SCNVector3] = [SCNVector3Zero, end]
        let source = SCNGeometrySource(vertices: vertices)
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(data: indexData, primitiveType: .line, primitiveCount: 1, bytesPerIndex: MemoryLayout<Int32>.size)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}

/// Read-only inline hex preview for any node this build has no typed
/// decoder for, real bytes at the record's real file offset, same source
/// `HexViewerWindow`'s full editable grid reads from, just capped to a
/// bounded prefix here since this is a glance-at-it preview, not the
/// editor. "Open Full Hex Editor…" hands off to that exact editable view
/// for anything beyond a quick look.
struct RawBytesPreview: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let bytes: Data

    private static let previewByteLimit = 2048
    private static let bytesPerRow = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(node.displayName).font(.headline)
                Spacer()
                Text("\(bytes.count) byte(s)").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(hexDump)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            if bytes.count > Self.previewByteLimit {
                Text("Showing the first \(Self.previewByteLimit) of \(bytes.count) bytes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button {
                workspace.hexViewerNode = node
            } label: {
                Label("Open Full Hex Editor…", systemImage: "number")
            }
        }
        .padding()
    }

    private var hexDump: String {
        let prefix = bytes.prefix(Self.previewByteLimit)
        var lines: [String] = []
        var row: [UInt8] = []
        row.reserveCapacity(Self.bytesPerRow)
        for (offset, byte) in prefix.enumerated() {
            row.append(byte)
            if row.count == Self.bytesPerRow || offset == prefix.count - 1 {
                let rowStart = offset - row.count + 1
                var hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
                if hex.count < Self.bytesPerRow * 3 - 1 { hex += String(repeating: " ", count: Self.bytesPerRow * 3 - 1 - hex.count) }
                let ascii = String(row.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
                lines.append(String(format: "%06X", rowStart) + "  " + hex + "  " + ascii)
                row.removeAll(keepingCapacity: true)
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct SceneKitMeshView: NSViewRepresentable {
    let mesh: MeshAsset

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = NSColor.controlBackgroundColor
        view.scene = MeshSceneBuilder.buildScene(for: mesh)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        nsView.scene = MeshSceneBuilder.buildScene(for: mesh)
    }
}

enum MeshSceneBuilder {
    static func buildScene(for mesh: MeshAsset) -> SCNScene {
        let scene = SCNScene()
        let root = SCNNode()

        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for submesh in mesh.submeshes {
            guard !submesh.vertices.isEmpty else { continue }
            let node = SCNNode(geometry: geometry(for: submesh))
            root.addChildNode(node)
            for v in submesh.vertices {
                minBound = simd_min(minBound, v.position)
                maxBound = simd_max(maxBound, v.position)
            }
        }
        scene.rootNode.addChildNode(root)

        let center = (minBound + maxBound) / 2
        let extent = maxBound - minBound
        let radius = max(extent.x, max(extent.y, extent.z), 1)
        root.position = SCNVector3(-center.x, -center.y, -center.z)

        let camera = SCNCamera()
        camera.zFar = Double(radius) * 20
        camera.zNear = 0.01
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, radius * 0.6, radius * 1.8)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        return scene
    }

    private static func geometry(for submesh: MeshSubmesh) -> SCNGeometry {
        let vertexCount = submesh.vertices.count

        var positions = [SCNVector3](); positions.reserveCapacity(vertexCount)
        var normals = [SCNVector3](); normals.reserveCapacity(vertexCount)
        var uvs = [CGPoint](); uvs.reserveCapacity(vertexCount)
        var colors = [SCNVector4](); colors.reserveCapacity(vertexCount)

        for v in submesh.vertices {
            positions.append(SCNVector3(v.position.x, v.position.y, v.position.z))
            normals.append(SCNVector3(v.normal.x, v.normal.y, v.normal.z))
            uvs.append(CGPoint(x: CGFloat(v.uv.x), y: CGFloat(v.uv.y)))
            colors.append(SCNVector4(Float(v.color.x) / 255.0, Float(v.color.y) / 255.0, Float(v.color.z) / 255.0, Float(v.color.w) / 255.0))
        }

        let positionSource = SCNGeometrySource(vertices: positions)
        let normalSource = SCNGeometrySource(normals: normals)
        let uvSource = SCNGeometrySource(textureCoordinates: uvs)
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SCNVector4>.stride)
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SCNVector4>.stride
        )

        let triangles = submesh.triangleIndices()
        var indices: [Int32] = []
        indices.reserveCapacity(triangles.count * 3)
        for (a, b, c) in triangles {
            guard a < vertexCount, b < vertexCount, c < vertexCount else { continue }
            indices.append(Int32(a)); indices.append(Int32(b)); indices.append(Int32(c))
        }
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geometry = SCNGeometry(sources: [positionSource, normalSource, uvSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.white
        material.isDoubleSided = true
        material.lightingModel = .physicallyBased
        geometry.materials = [material]
        return geometry
    }
}
