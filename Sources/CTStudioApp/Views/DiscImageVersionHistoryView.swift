import SwiftUI

/// Browse/restore UI for `WorkspaceViewModel.listDiscImageVersions(for:)` , 
/// the "full version history" this session's earlier single-backup-per-
/// session safety net grew into. Every in-place save keeps a timestamped
/// copy of the disc image as it was *before* that save (see
/// `WorkspaceViewModel.backingUpMountedDiscImageIfNeeded`'s own doc
/// comment); this is where the user actually gets back to one.
struct DiscImageVersionHistoryView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let discImageURL: URL

    @State private var versions: [WorkspaceViewModel.DiscImageVersion] = []
    @State private var pendingRestore: WorkspaceViewModel.DiscImageVersion?
    @State private var errorMessage: String?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Version History").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("\(discImageURL.lastPathComponent), up to the last \(WorkspaceViewModel.maxVersionsPerDiscImage) in-place saves are kept, oldest pruned automatically. Restoring a version backs up what's currently on disk first, so this is never a one-way trip.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if versions.isEmpty {
                Text("No saved versions yet, this list fills in after the first in-place save.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                List(versions) { version in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.displayFormatter.string(from: version.createdAt))
                                .font(.callout)
                            Text(Self.byteFormatter.string(fromByteCount: Int64(version.byteSize)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore…") { pendingRestore = version }
                    }
                }
                .frame(minHeight: 220)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 340)
        .onAppear { refresh() }
        .alert(
            "Restore this version?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
        ) {
            Button("Restore", role: .destructive) {
                if let pendingRestore { restore(pendingRestore) }
                self.pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("This replaces the current disc image with the chosen version. The current disc image is itself saved as a new version first, so you can always come back.")
        }
    }

    private func refresh() {
        versions = workspace.listDiscImageVersions(for: discImageURL)
    }

    private func restore(_ version: WorkspaceViewModel.DiscImageVersion) {
        do {
            try workspace.restoringDiscImageVersion(version, to: discImageURL)
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }
}
