import SwiftUI
import CTModels

/// "Deep Hierarchy & Linked Asset Resolution": shows the selected node's
/// parent composite object and every component that composite is built
/// from, each clickable to jump the sidebar selection straight to it.
struct RelationalChainView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    @State private var isExpanded = true
    /// Cached, not recomputed in `body`, `relationalChain(for:)` walks and
    /// rebuilds the whole file's Graphics/Code index (see
    /// `InspectorView.resolvedComposite`'s matching doc comment for why
    /// that's expensive to do on every `body` evaluation rather than only
    /// when `node` actually changes).
    @State private var cachedChain: RelationalChain?

    var body: some View {
        Group {
            if let chain = cachedChain {
                chainContent(chain)
            } else {
                EmptyView()
            }
        }
        .onAppear { cachedChain = workspace.relationalChain(for: node) }
        .onChange(of: node.id) { _, _ in cachedChain = workspace.relationalChain(for: node) }
    }

    @ViewBuilder
    private func chainContent(_ chain: RelationalChain) -> some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.circle")
                        .foregroundStyle(.secondary)
                    Text("Parent: \(chain.parentDisplayName)")
                        .font(.callout.bold())
                }
                .padding(.top, 4)

                ForEach(groupedComponents(chain), id: \.kind) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.kind.rawValue + "s")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(group.items) { component in
                            Button {
                                workspace.selectComponent(component)
                            } label: {
                                HStack {
                                    Image(systemName: icon(for: component.kind))
                                        .frame(width: 16)
                                    Text(component.displayName)
                                    Spacer()
                                    if component.recordID == node.recordID {
                                        Text("selected")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(component.recordID == node.recordID ? .primary : Color.accentColor)
                        }
                    }
                }
            }
            .padding(.leading, 4)
        } label: {
            Label("Relational Chain", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
        }
    }

    private struct ComponentGroup {
        let kind: LinkedComponent.Kind
        let items: [LinkedComponent]
    }

    /// Groups by kind in a fixed, sensible reading order rather than
    /// however `RelationalChain.components` happens to be ordered.
    private func groupedComponents(_ chain: RelationalChain) -> [ComponentGroup] {
        let order: [LinkedComponent.Kind] = [.mesh, .skeleton, .material, .texture, .animation]
        return order.compactMap { kind in
            let items = chain.components.filter { $0.kind == kind }
            return items.isEmpty ? nil : ComponentGroup(kind: kind, items: items)
        }
    }

    private func icon(for kind: LinkedComponent.Kind) -> String {
        switch kind {
        case .mesh: return "cube"
        case .material: return "paintpalette"
        case .texture: return "photo"
        case .skeleton: return "figure.stand"
        case .animation: return "play.circle"
        }
    }
}
