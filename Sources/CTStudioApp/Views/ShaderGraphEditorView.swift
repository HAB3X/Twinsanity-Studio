import SwiftUI
import CTModels

/// "Shader Graph Editor" (roadmap 5.4): a real node-based material canvas
/// that compiles to actual MSL (`ShaderGraphCompiler`) and previews live
/// in the Model Viewer's own existing Metal viewport
/// (`ModelViewerRenderer.applyShaderGraph`), not a mockup, an actually
/// working custom fragment shader replacing the default one for this
/// session.
struct ShaderGraphEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let renderer: ModelViewerRenderer

    @State private var graph = ShaderGraph.defaultGraph()
    @State private var selectedNodeID: UUID?
    @State private var dragStartPositions: [UUID: CGPoint] = [:]
    @State private var pendingWireStart: UUID?
    @State private var pendingWireDragPoint: CGPoint?
    @State private var compileMessage: String?
    @State private var compileSucceeded = false

    private static let portRowHeight: CGFloat = 18
    private static let nodeWidth: CGFloat = 170

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                canvas
                Divider()
                inspector
                    .frame(width: 260)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Shader Graph Editor").font(.headline)
                Spacer()
                addNodeMenu
                Button("Reset") { graph = .defaultGraph(); clearCompileState() }
                Button("Compile & Preview") { compile() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Close") { dismiss() }
            }
            if let compileMessage {
                Label(compileMessage, systemImage: compileSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(compileSucceeded ? .green : .red)
            }
        }
        .padding(10)
    }

    private var addNodeMenu: some View {
        Menu("Add Node") {
            ForEach(Self.addableKinds, id: \.displayName) { kind in
                Button(kind.displayName) {
                    graph.nodes.append(ShaderGraphNode(kind: kind, position: CGPoint(x: 300, y: 300)))
                }
            }
        }
    }

    private static let addableKinds: [ShaderNodeKind] = [
        .uv, .vertexColor, .worldNormal, .textureSample,
        .constantFloat(1), .constantColor(SIMD4(1, 1, 1, 1)),
        .add, .subtract, .multiply, .lerp, .saturate, .dotProduct, .normalizeVec,
        .uvOffset, .uvScale,
    ]

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                wiresLayer
                ForEach(graph.nodes) { node in
                    nodeCard(node)
                        .position(node.position)
                        .gesture(dragGesture(for: node))
                        .onTapGesture { selectedNodeID = node.id }
                }
            }
            .coordinateSpace(name: "shaderGraphCanvas")
            .frame(width: max(proxy.size.width, 1200), height: max(proxy.size.height, 800))
        }
    }

    private var wiresLayer: some View {
        Canvas { context, _ in
            for connection in graph.connections {
                guard let from = graph.nodes.first(where: { $0.id == connection.fromNodeID }),
                      let to = graph.nodes.first(where: { $0.id == connection.toNodeID })
                else { continue }
                let start = outputPortPoint(for: from)
                let end = inputPortPoint(for: to, portIndex: connection.toPortIndex)
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(.accentColor.opacity(0.7)), lineWidth: 2)
            }
            if let startID = pendingWireStart, let startNode = graph.nodes.first(where: { $0.id == startID }), let dragPoint = pendingWireDragPoint {
                var path = Path()
                path.move(to: outputPortPoint(for: startNode))
                path.addLine(to: dragPoint)
                context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
        }
        .allowsHitTesting(false)
    }

    private func nodeCard(_ node: ShaderGraphNode) -> some View {
        let signature = ShaderNodeSignature.signature(for: node.kind)
        return VStack(alignment: .leading, spacing: 4) {
            Text(node.kind.displayName).font(.caption.bold())
            ForEach(Array(signature.inputLabels.enumerated()), id: \.offset) { index, label in
                HStack(spacing: 4) {
                    Circle().fill(Color.secondary).frame(width: 8, height: 8)
                        .gesture(inputPortDropTarget(node: node, portIndex: index))
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(height: Self.portRowHeight)
            }
            if signature.outputType != nil {
                HStack {
                    Spacer()
                    Text("out").font(.caption2).foregroundStyle(.secondary)
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        .gesture(outputPortDragGesture(node: node))
                }
                .frame(height: Self.portRowHeight)
            }
        }
        .padding(8)
        .frame(width: Self.nodeWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(nodeColor(node.kind).opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedNodeID == node.id ? Color.accentColor : nodeColor(node.kind).opacity(0.5), lineWidth: selectedNodeID == node.id ? 2 : 1))
    }

    private func nodeColor(_ kind: ShaderNodeKind) -> Color {
        switch kind {
        case .finalColor: return .red
        case .uv, .uvOffset, .uvScale: return .blue
        case .textureSample: return .purple
        case .constantFloat, .constantColor: return .orange
        default: return .green
        }
    }

    private func dragGesture(for node: ShaderGraphNode) -> some Gesture {
        DragGesture(coordinateSpace: .local)
            .onChanged { value in
                let start = dragStartPositions[node.id] ?? node.position
                if dragStartPositions[node.id] == nil { dragStartPositions[node.id] = start }
                guard let index = graph.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                graph.nodes[index].position = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
            }
            .onEnded { _ in dragStartPositions[node.id] = nil }
    }

    private func outputPortDragGesture(node: ShaderGraphNode) -> some Gesture {
        DragGesture(coordinateSpace: .named("shaderGraphCanvas"))
            .onChanged { value in
                pendingWireStart = node.id
                pendingWireDragPoint = value.location
            }
            .onEnded { value in
                defer { pendingWireStart = nil; pendingWireDragPoint = nil }
                guard let target = nearestInputPort(to: value.location) else { return }
                graph.connections.removeAll { $0.toNodeID == target.nodeID && $0.toPortIndex == target.portIndex }
                graph.connections.append(ShaderGraphConnection(fromNodeID: node.id, toNodeID: target.nodeID, toPortIndex: target.portIndex))
            }
    }

    /// Ports themselves don't need their own gesture recognizer beyond
    /// providing a drop target for `outputPortDragGesture`'s own
    /// `nearestInputPort` lookup, an empty gesture here just keeps the
    /// dot from swallowing taps meant for the card underneath it.
    private func inputPortDropTarget(node: ShaderGraphNode, portIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { _ in }
    }

    private func nearestInputPort(to point: CGPoint) -> (nodeID: UUID, portIndex: Int)? {
        let dropRadius: CGFloat = 24
        var best: (nodeID: UUID, portIndex: Int, distance: CGFloat)?
        for node in graph.nodes {
            let signature = ShaderNodeSignature.signature(for: node.kind)
            for portIndex in signature.inputLabels.indices {
                let portPoint = inputPortPoint(for: node, portIndex: portIndex)
                let distance = hypot(portPoint.x - point.x, portPoint.y - point.y)
                if distance < dropRadius, (best == nil || distance < best!.distance) {
                    best = (node.id, portIndex, distance)
                }
            }
        }
        return best.map { (($0.nodeID, $0.portIndex)) }
    }

    private func outputPortPoint(for node: ShaderGraphNode) -> CGPoint {
        CGPoint(x: node.position.x + Self.nodeWidth / 2, y: node.position.y)
    }

    private func inputPortPoint(for node: ShaderGraphNode, portIndex: Int) -> CGPoint {
        let signature = ShaderNodeSignature.signature(for: node.kind)
        let headerHeight: CGFloat = 20
        let yOffsetFromTop = headerHeight + Self.portRowHeight * (CGFloat(portIndex) + 0.5)
        let totalHeight = headerHeight + Self.portRowHeight * CGFloat(signature.inputLabels.count + (signature.outputType != nil ? 1 : 0))
        return CGPoint(x: node.position.x - Self.nodeWidth / 2, y: node.position.y - totalHeight / 2 + yOffsetFromTop)
    }

    @ViewBuilder
    private var inspector: some View {
        if let selectedNodeID, let index = graph.nodes.firstIndex(where: { $0.id == selectedNodeID }) {
            Form {
                Section(graph.nodes[index].kind.displayName) {
                    switch graph.nodes[index].kind {
                    case .constantFloat(let v):
                        Slider(value: Binding(
                            get: { Double(v) },
                            set: { graph.nodes[index].kind = .constantFloat(Float($0)) }
                        ), in: 0...4)
                        Text(String(format: "%.3f", v)).font(.caption).foregroundStyle(.secondary)
                    case .constantColor(let c):
                        ColorPicker("Color", selection: Binding(
                            get: { Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: Double(c.w)) },
                            set: { newColor in
                                let resolved = newColor.resolve(in: EnvironmentValues())
                                graph.nodes[index].kind = .constantColor(SIMD4(Float(resolved.red), Float(resolved.green), Float(resolved.blue), Float(resolved.opacity)))
                            }
                        ))
                    default:
                        Text("This node kind has no editable value. Wire inputs into it from the canvas.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Delete Node", role: .destructive) {
                        graph.connections.removeAll { $0.fromNodeID == selectedNodeID || $0.toNodeID == selectedNodeID }
                        graph.nodes.removeAll { $0.id == selectedNodeID }
                        self.selectedNodeID = nil
                    }
                    .disabled(isFinalColorNode(index))
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Node Selected", systemImage: "point.3.filled.connected.trianglepath.dotted",
                description: Text("Select a node to edit its constant value, or drag from its output dot to another node's input dot to wire it."))
        }
    }

    private func isFinalColorNode(_ index: Int) -> Bool {
        if case .finalColor = graph.nodes[index].kind { return true }
        return false
    }

    private func compile() {
        do {
            let functionName = "fragment_shadergraph_preview"
            let mslSource = try ShaderGraphCompiler.compile(graph, functionName: functionName)
            switch renderer.applyShaderGraph(mslFragmentSource: mslSource, functionName: functionName) {
            case .success:
                compileSucceeded = true
                compileMessage = "Compiled and applied. Close this editor to see the Model Viewer's viewport using this graph."
            case .failure(let error):
                compileSucceeded = false
                compileMessage = "Metal rejected the compiled shader: \(error)"
            }
        } catch {
            compileSucceeded = false
            compileMessage = "Graph error: \(error)"
        }
    }

    private func clearCompileState() {
        renderer.clearShaderGraphOverride()
        compileMessage = nil
    }
}
