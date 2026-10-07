import SwiftUI
import AppKit
import CTModels
import CTExport

/// "Cut Content & Orphaned Asset Restorer" (blueprint 2.2): every dangling
/// reference and unreferenced record `AssetResolver.scanForOrphans` has
/// flagged across every scanned file, grouped by why it was flagged.
/// Anything with a live mesh behind it (`modelPreview`/`texturePreview`) is
/// one click from actually being visible again, the whole point of a
/// "restorer" over a plain report.
struct ScrappedContentScannerView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    /// Set when docked into the main window's detail column (see
    /// `DetailColumn`); nil when still presented as a `.sheet`.
    var onClose: (() -> Void)? = nil
    @State private var searchText = ""
    @State private var previewedTexture: TextureAsset?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TextField("Search cut content by name or file…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            content
        }
        .frame(minWidth: 620, minHeight: 560)
        .popover(item: $previewedTexture) { texture in
            TexturePreviewPopover(texture: texture)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scrapped Content Scanner").font(.title2.bold())
                Text("\(filteredOrphans.count) of \(workspace.orphanedContent.count) flagged record(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if workspace.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            }
            Button("Close") { (onClose ?? { dismiss() })() }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if workspace.orphanedContent.isEmpty {
            ContentUnavailableView(
                workspace.isScanning ? "Scanning…" : "No Cut Content Found Yet",
                systemImage: "questionmark.folder",
                description: Text(workspace.isScanning
                    ? "Dangling references and unused geometry/textures will appear here as the scan finds them."
                    : "Load a .BH archive or a .RM2/.SM2 file, scanning starts automatically.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredOrphans.isEmpty {
            ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try a different search."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(OrphanReason.allCases, id: \.self) { reason in
                    let rows = filteredOrphans.filter { $0.reason == reason }
                    if !rows.isEmpty {
                        Section("\(reason.rawValue) (\(rows.count))") {
                            ForEach(rows) { orphan in
                                OrphanRow(orphan: orphan, onSelect: action(for: orphan))
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var filteredOrphans: [OrphanedAsset] {
        workspace.orphanedContent.filter { orphan in
            searchText.isEmpty
                || orphan.displayName.localizedCaseInsensitiveContains(searchText)
                || orphan.sourceLabel.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func action(for orphan: OrphanedAsset) -> (() -> Void)? {
        if let modelPreview = orphan.modelPreview {
            return {
                workspace.modelViewerAsset = modelPreview
                (onClose ?? { dismiss() })()
            }
        }
        if let texture = orphan.texturePreview {
            return { previewedTexture = texture }
        }
        return nil
    }
}

private struct OrphanRow: View {
    let orphan: OrphanedAsset
    let onSelect: (() -> Void)?

    var body: some View {
        let row = HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(orphan.displayName).lineLimit(1)
                Text(orphan.sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if onSelect != nil {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)

        if let onSelect {
            Button(action: onSelect) { row }.buttonStyle(.plain)
        } else {
            row.opacity(0.7)
        }
    }

    private var icon: String {
        switch orphan.reason {
        case .danglingMeshReference, .danglingSkinReference: return "link.badge.plus"
        case .unreferencedGeometry: return "cube.transparent"
        case .unreferencedSkeleton: return "figure.stand.dress.line.vertical.figure"
        case .unreferencedTexture: return "photo.on.rectangle.angled"
        }
    }

    private var iconColor: Color {
        switch orphan.reason {
        case .danglingMeshReference, .danglingSkinReference: return .red
        case .unreferencedGeometry, .unreferencedSkeleton: return .teal
        case .unreferencedTexture: return .purple
        }
    }
}

/// Lightweight standalone preview for an orphaned texture, there's no
/// `ChunkNode` handy here (orphans are reported independently of the tree
/// the sidebar walks), so this decodes straight from the `TextureAsset`
/// rather than reusing `TextureInspectorView`, which is written against a
/// node it can export from.
private struct TexturePreviewPopover: View {
    let texture: TextureAsset

    var body: some View {
        VStack(spacing: 8) {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)
            } else {
                ContentUnavailableView("Format Not Decoded", systemImage: "photo.badge.exclamationmark",
                    description: Text("\(texture.pixelFormat.rawValue.uppercased()) isn't fully decoded by this build."))
                    .frame(width: 256, height: 200)
            }
            Text("\(texture.width) × \(texture.height) · \(texture.pixelFormat.rawValue.uppercased())")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var nsImage: NSImage? {
        guard texture.pixelFormat.isFullyDecoded, let cgImage = try? TextureExporter.cgImage(from: texture, mipLevel: nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
