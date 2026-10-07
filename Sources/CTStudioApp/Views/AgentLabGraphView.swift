import SwiftUI
import CTCore
import CTModels
import CTParsers

/// "AgentLab Visual Node Graph" (roadmap 4.2, Part 3 of the Chunk-Based
/// Editor mandate), a drag-and-drop canvas over a file's real `CustomAgent`
/// records.
///
/// What's real here: every node corresponds to an actual `CustomAgent` leaf
/// record in the currently open file (real `recordID`, real `byteSize`),
/// and each card's action chain is a *real, byte-accurate decode* of that
/// record's on-disk `CodeModel` bytecode, see `CustomAgentParser`'s doc
/// comment for the verified reference source (`github.com/Smartkin/
/// twinsanity-editor`, MIT licensed) this decoder is ported from. Every
/// command boundary, command ID, and command name shown is real, not
/// inferred from context.
///
/// What's still honest-shell: the *semantic meaning* of a command's raw
/// arguments is only decoded for the ~14 commands this build has a verified
/// reference `Load()` for (`AgentLabActionDecoder`), every other command
/// still shows its real name and real raw `uint32` arguments, just without
/// invented field names. And condition/percept data (what *triggers* an
/// action chain) isn't part of this record format at all, `CodeModel`'s
/// own on-disk layout only stores action chains, never `ScriptCondition`
/// data, so there's no percept-scoring graph to draw here even in
/// principle; the connector wires below remain the user's own
/// organizational notes, not decoded engine data.
struct AgentLabGraphView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let sectionNode: ChunkNode

    @State private var nodePositions: [UUID: CGPoint] = [:]
    @State private var dragStartPositions: [UUID: CGPoint] = [:]
    @State private var selectedNode: ChunkNode?
    /// "Snap-to-connect wires", real UI, honestly scoped: these are the
    /// user's *own* organizational links between nodes (grouping, call-out
    /// notes, whatever the user means by connecting two agents), not a
    /// decoded Percept -> Action data/call flow, this build has no parser
    /// for that (see this view's own top-level doc comment). Session-only,
    /// same as node positions, no on-disk format exists to save either
    /// into.
    @State private var connections: Set<AgentConnection> = []
    @State private var pendingConnectionStart: UUID?
    @State private var pendingConnectionDragPoint: CGPoint?
    /// Non-`nil` presents the argument-editor sheet for one command in one
    /// specific agent record, both are needed together since
    /// `AgentLabCommand.fileOffset` is only meaningful relative to its own
    /// owning record's `ChunkNode`.
    @State private var editingCommand: (node: ChunkNode, command: AgentLabCommand)?

    private struct AgentConnection: Hashable {
        let a: UUID
        let b: UUID
        init(_ x: UUID, _ y: UUID) {
            // Normalized so a<->b and b<->a are the same connection.
            if x.uuidString < y.uuidString { a = x; b = y } else { a = y; b = x }
        }
    }

    private var agentNodes: [ChunkNode] { sectionNode.children }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                canvas
                if let selectedNode {
                    Divider()
                    inspector(for: selectedNode)
                        .frame(width: 260)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { layoutNodesIfNeeded() }
        .sheet(item: Binding(
            get: { editingCommand.map { EditingCommandRef(node: $0.node, command: $0.command) } },
            set: { newValue in editingCommand = newValue.map { ($0.node, $0.command) } }
        )) { ref in
            AgentLabArgumentEditorSheet(node: ref.node, command: ref.command)
        }
    }

    /// `Identifiable` wrapper so `editingCommand`'s tuple can drive
    /// `.sheet(item:)`, a plain `(node: ChunkNode, command: AgentLabCommand)`
    /// tuple isn't `Identifiable` on its own.
    private struct EditingCommandRef: Identifiable {
        let node: ChunkNode
        let command: AgentLabCommand
        var id: UUID { command.id }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("AgentLab Graph: \(sectionNode.displayName)").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("\(agentNodes.count) real CustomAgent record(s) from this file, each decoded from its actual on-disk bytecode (see this view's own doc comment for the verified reference source). Drag a card to rearrange it; drag from a card's connector dot (bottom-right) to another card to link them. Those links are your own organizational notes, not decoded engine data.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: max(proxy.size.width, canvasContentSize.width), height: max(proxy.size.height, canvasContentSize.height))
                    connectionsLayer
                    ForEach(agentNodes) { node in
                        agentCard(node)
                            .position(nodePositions[node.id] ?? .zero)
                            .gesture(dragGesture(for: node))
                    }
                }
                .coordinateSpace(name: "agentLabCanvas")
            }
            .background(Self.gridBackground)
        }
    }

    /// Every user-drawn connection, plus a live preview line while a
    /// connector-drag is in progress. Drawn *behind* the node cards (see
    /// `canvas`'s ZStack order) so cards remain fully clickable/draggable
    /// on top.
    private var connectionsLayer: some View {
        Canvas { context, _ in
            for connection in connections {
                guard let start = nodePositions[connection.a], let end = nodePositions[connection.b] else { continue }
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(.purple.opacity(0.6)), lineWidth: 2)
            }
            if let startID = pendingConnectionStart, let start = nodePositions[startID], let end = pendingConnectionDragPoint {
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(.purple), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
        }
        .allowsHitTesting(false)
        .overlay(alignment: .topLeading) {
            ForEach(Array(connections), id: \.self) { connection in
                if let start = nodePositions[connection.a], let end = nodePositions[connection.b] {
                    let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                    Button {
                        connections.remove(connection)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .background(Circle().fill(.background))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove Connection")
                    .position(midpoint)
                }
            }
        }
    }

    private var canvasContentSize: CGSize {
        let maxX = nodePositions.values.map(\.x).max() ?? 400
        let maxY = nodePositions.values.map(\.y).max() ?? 400
        return CGSize(width: maxX + 200, height: maxY + 160)
    }

    private func agentCard(_ node: ChunkNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.purple)
                Text("Agent #\(node.recordID)").font(.caption.bold())
                Spacer()
            }
            Text("\(node.byteSize) bytes")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(cardSummary(for: node))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Spacer()
                Circle()
                    .fill(pendingConnectionStart == node.id ? Color.purple : Color.purple.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
                    .gesture(connectorDragGesture(from: node))
                    .help("Drag to another card to link them (your own note, not decoded data)")
            }
        }
        .padding(8)
        .frame(width: 180, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.purple.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedNode?.id == node.id ? Color.purple : Color.purple.opacity(0.4), lineWidth: selectedNode?.id == node.id ? 2 : 1))
        .onTapGesture { selectedNode = node }
    }

    private func dragGesture(for node: ChunkNode) -> some Gesture {
        DragGesture(coordinateSpace: .local)
            .onChanged { value in
                let start = dragStartPositions[node.id] ?? nodePositions[node.id] ?? .zero
                if dragStartPositions[node.id] == nil { dragStartPositions[node.id] = start }
                nodePositions[node.id] = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
            }
            .onEnded { _ in dragStartPositions[node.id] = nil }
    }

    /// Drag from a card's connector dot to another card to link them.
    /// Uses the shared named coordinate space (`agentLabCanvas`) so
    /// `value.location` lands in the same space `nodePositions` is
    /// already stored in, regardless of how deep the connector dot sits
    /// inside the card's own view hierarchy.
    private func connectorDragGesture(from node: ChunkNode) -> some Gesture {
        DragGesture(coordinateSpace: .named("agentLabCanvas"))
            .onChanged { value in
                pendingConnectionStart = node.id
                pendingConnectionDragPoint = value.location
            }
            .onEnded { value in
                defer {
                    pendingConnectionStart = nil
                    pendingConnectionDragPoint = nil
                }
                guard let target = nearestNode(to: value.location, excluding: node.id), target != node.id else { return }
                connections.insert(AgentConnection(node.id, target))
            }
    }

    /// The nearest node to `point` within a generous drop radius, lets a
    /// connector drag land anywhere on the target card, not just its exact
    /// center.
    private func nearestNode(to point: CGPoint, excluding: UUID) -> UUID? {
        let dropRadius: CGFloat = 100
        var best: (id: UUID, distance: CGFloat)?
        for node in agentNodes where node.id != excluding {
            guard let position = nodePositions[node.id] else { continue }
            let distance = hypot(position.x - point.x, position.y - point.y)
            if distance < dropRadius, (best == nil || distance < best!.distance) {
                best = (node.id, distance)
            }
        }
        return best?.id
    }

    /// `.customAgent` -> PS2, `.customAgentX` -> Xbox, `.customAgentDemo` ->
    /// Demo, mirrors `CodeModel.Load`'s own `ParentType` check exactly (see
    /// `CustomAgentParser`'s doc comment). Any other `sectionType` can't
    /// reach this view (gated by `SidebarView.customAgentSectionTypes`), so
    /// PS2 is a safe, never-exercised default rather than a real guess.
    private func platformVariant(for node: ChunkNode) -> AgentLabPlatformVariant {
        switch node.sectionType {
        case .customAgentX: return .xbox
        case .customAgentDemo: return .demo
        default: return .ps2
        }
    }

    private func decodedRecord(for node: ChunkNode) -> CustomAgentRecord? {
        guard let bytes = workspace.rawBytes(for: node), !bytes.isEmpty else { return nil }
        var cursor = BinaryCursor(data: bytes)
        return try? CustomAgentParser.parse(&cursor, recordID: node.recordID, platform: platformVariant(for: node))
    }

    private func cardSummary(for node: ChunkNode) -> String {
        guard let record = decodedRecord(for: node) else { return "(couldn't decode, see hex)" }
        let allCommands = record.entries.flatMap(\.commands) + record.finalCommands
        guard let first = allCommands.first else { return "\(record.entries.count) slot(s), no commands" }
        let firstLabel = first.commandName ?? "#\(first.commandID)"
        let suffix = allCommands.count > 1 ? " (+\(allCommands.count - 1) more)" : ""
        return "\(firstLabel)\(suffix)"
    }

    @ViewBuilder
    private func inspector(for node: ChunkNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent #\(node.recordID)").font(.headline)
            LabeledContent("Byte Size", value: "\(node.byteSize)")
            LabeledContent("File Offset", value: "0x\(String(node.fileOffset, radix: 16))")
            Divider()
            if let record = decodedRecord(for: node) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(record.entries.enumerated()), id: \.offset) { index, entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Slot \(index): script ID \(entry.scriptID)").font(.caption.bold())
                                if entry.commands.isEmpty {
                                    Text("(no commands)").font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    ForEach(entry.commands) { commandRow($0, node: node) }
                                }
                            }
                        }
                        if !record.finalCommands.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Trailing chain").font(.caption.bold())
                                ForEach(record.finalCommands) { commandRow($0, node: node) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Couldn't decode this record's bytecode. See raw bytes in the hex editor.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("View in Hex Editor…") { workspace.hexViewerNode = node }
        }
        .padding(12)
    }

    private func commandRow(_ command: AgentLabCommand, node: ChunkNode) -> some View {
        Button {
            editingCommand = (node, command)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(command.commandName ?? "Command #\(command.commandID)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(command.commandName == nil ? .secondary : .primary)
                    if !command.rawArguments.isEmpty {
                        Image(systemName: "pencil.circle").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let decoded = command.decoded {
                    Text(describeDecoded(decoded))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.purple)
                } else if !command.rawArguments.isEmpty {
                    Text("args: " + command.rawArguments.map { "0x\(String($0, radix: 16))" }.joined(separator: ", "))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(command.rawArguments.isEmpty)
        .padding(.leading, 8)
    }

    private func describeDecoded(_ decoded: AgentLabDecodedAction) -> String {
        switch decoded {
        case .addAmmo(let v): return "AmmoToAdd = \(v)"
        case .addGem(let gem): return "Gem = \(gem)"
        case .addLives(let v): return "LivesToAdd = \(v)"
        case .addWumpa(let v): return "WumpaToAdd = \(v)"
        case .cutsceneStart(let d): return "FadeDuration = \(d)"
        case .cutsceneEnd(let d): return "FadeDuration = \(d)"
        case .damageBoss(let v): return "DamageAdd = \(v)"
        case .hideBottomText(let d): return "FadeDuration = \(d)"
        case .progressWhackaworm(let v): return "WormCounterAdd = \(v)"
        case .reduceHitPoints(let v): return "Damage = \(v)"
        case .setBehaviourPriority(let v): return "Priority = \(v)"
        case .setHitPoints(let v): return "HitPoints = \(v)"
        case .showBottomText(let d): return "FadeDuration = \(d)"
        }
    }

    /// Simple grid layout, 4 columns, generous spacing, no attempt at a
    /// force-directed/topological layout since there's no real edge data
    /// to lay out around (see this view's own doc comment).
    private func layoutNodesIfNeeded() {
        guard nodePositions.isEmpty else { return }
        let columns = 4
        let spacingX: CGFloat = 220
        let spacingY: CGFloat = 130
        for (index, node) in agentNodes.enumerated() {
            let column = index % columns
            let row = index / columns
            nodePositions[node.id] = CGPoint(x: 120 + CGFloat(column) * spacingX, y: 80 + CGFloat(row) * spacingY)
        }
    }

    private static var gridBackground: some View {
        Canvas { context, size in
            let spacing: CGFloat = 24
            var x: CGFloat = 0
            while x < size.width {
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.secondary.opacity(0.08)))
                x += spacing
            }
            var y: CGFloat = 0
            while y < size.height {
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(.secondary.opacity(0.08)))
                y += spacing
            }
        }
    }
}
