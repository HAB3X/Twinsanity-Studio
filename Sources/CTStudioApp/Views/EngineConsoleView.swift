import SwiftUI
import CTModels

/// "Real-Time Engine Console" (blueprint 7.5): a collapsible drawer of real
/// app events (load/scan/export/error messages, see `WorkspaceViewModel`'s
/// `statusMessage`/`lastError` `didSet`s), newest first. `ContentView` docks
/// this along the bottom of the window, toggled from the toolbar.
struct EngineConsoleView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Binding var isExpanded: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider()
                log
            }
        }
        .background(.bar)
    }

    private var header: some View {
        HStack {
            Image(systemName: "terminal")
            Text("Engine Console")
                .font(.caption.bold())
            if !workspace.engineLog.isEmpty {
                Text("(\(workspace.engineLog.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isExpanded, !workspace.engineLog.isEmpty {
                Button("Clear") { workspace.clearEngineLog() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isExpanded ? "Collapse Engine Console" : "Expand Engine Console")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }
    }

    @ViewBuilder
    private var log: some View {
        if workspace.engineLog.isEmpty {
            Text("No events yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(workspace.engineLog.reversed()) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.timeFormatter.string(from: entry.timestamp))
                                .foregroundStyle(.tertiary)
                            Text(entry.message)
                                .foregroundStyle(entry.isError ? Color.red : Color.primary)
                                .textSelection(.enabled)
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                }
                .padding(8)
            }
            .frame(height: 160)
        }
    }
}
