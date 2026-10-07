import SwiftUI
import CTCore
import CTParsers

/// Browses `CHARS.DAT`'s real, decoded entry table (see
/// `WOCCharacterArchiveParser`'s doc comment for the confirmed
/// archive/compression layer). Most entry content (mesh geometry,
/// materials) still isn't decoded -- but real joint hierarchies ARE, for
/// the 12 real skeleton definitions (see `WOCCharacterSkeletonParser`),
/// and real named animation-clip catalogs ARE, for entries fitting that
/// template (see `WOCCharacterAnimationCatalogParser` -- clip *names*
/// are real and decoded; each clip's actual keyframe/curve data is not).
/// This view surfaces both as real, browsable trees/lists rather than
/// just byte counts.
struct WOCCharacterArchiveBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let archiveURL: URL

    @State private var entries: [WOCCharacterArchiveParser.Entry] = []
    @State private var isLoadingTable = true
    @State private var loadError: String?
    @State private var embeddedContainerIndices: Set<Int> = []
    @State private var skeletons: [Int: WOCCharacterSkeletonParser.Skeleton] = [:]
    @State private var catalogs: [Int: [WOCCharacterAnimationCatalogParser.Clip]] = [:]
    @State private var isScanningEntries = false
    @State private var selectedSkeletonIndex: Int?
    @State private var selectedCatalogIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("WoC Character Archive")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)
            Divider()

            if isLoadingTable {
                ProgressView("Reading CHARS.DAT's table…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Couldn't Read Archive", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                statusBar
                Divider()
                List(entries) { entry in
                    row(for: entry)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .task { await loadTable() }
        .sheet(item: $selectedSkeletonIndex.mappedToIdentifiable) { wrapped in
            if let skeleton = skeletons[wrapped.value] {
                WOCSkeletonTreeView(index: wrapped.value, skeleton: skeleton)
            }
        }
        .sheet(item: $selectedCatalogIndex.mappedToIdentifiable) { wrapped in
            if let clips = catalogs[wrapped.value] {
                WOCAnimationCatalogView(index: wrapped.value, clips: clips)
            }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(entries.count) real entries -- archive/decompression confirmed (CRC-verified), \(skeletons.count) real joint hierarchies decoded, \(catalogs.count) real named animation-clip catalogs decoded (clip names only -- keyframe curves inside each clip are still undecoded).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isScanningEntries {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning entries for skeletons, animation catalogs, and embedded containers…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for entry: WOCCharacterArchiveParser.Entry) -> some View {
        HStack {
            Text("#\(entry.index)")
                .font(.body.monospaced())
                .frame(width: 56, alignment: .leading)
            Text(entry.unpackedSize.formattedByteCount)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if !entry.isCompressed {
                Text("stored")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if embeddedContainerIndices.contains(entry.index) {
                Text("NU20 mini-container")
                    .font(.caption2.bold())
                    .foregroundStyle(.blue)
            }
            if let skeleton = skeletons[entry.index] {
                Text("\(skeleton.joints[0].name) skeleton (\(skeleton.joints.count) joints)")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
                Spacer()
                Button("View") { selectedSkeletonIndex = entry.index }
                    .buttonStyle(.borderless)
            } else if let clips = catalogs[entry.index] {
                Text("\(clips.count) animation clip\(clips.count == 1 ? "" : "s")")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                Spacer()
                Button("View") { selectedCatalogIndex = entry.index }
                    .buttonStyle(.borderless)
            } else {
                Spacer()
            }
        }
        .contentShape(Rectangle())
    }

    private func loadTable() async {
        do {
            let parsed = try await Task.detached {
                try WOCCharacterArchiveParser.parseTable(fileURL: archiveURL)
            }.value
            entries = parsed
        } catch {
            loadError = "\(error)"
        }
        isLoadingTable = false

        // None of these distinctions (embedded NU20 container, real
        // skeleton, real animation catalog) are in the outer table -- all
        // cost one decode per entry, so this runs after the table itself
        // is already shown rather than blocking the initial view.
        isScanningEntries = true
        let toScan = entries
        let (containers, foundSkeletons, foundCatalogs) = await Task.detached {
            var containerIndices = Set<Int>()
            var skeletonsByIndex: [Int: WOCCharacterSkeletonParser.Skeleton] = [:]
            var catalogsByIndex: [Int: [WOCCharacterAnimationCatalogParser.Clip]] = [:]
            for entry in toScan {
                guard let decoded = try? WOCCharacterArchiveParser.decode(entry, fileURL: archiveURL) else { continue }
                if WOCCharacterArchiveParser.isEmbeddedContainer(decoded) {
                    containerIndices.insert(entry.index)
                }
                if let skeleton = try? WOCCharacterSkeletonParser.parseSkeleton(decoded) {
                    skeletonsByIndex[entry.index] = skeleton
                } else if let clips = try? WOCCharacterAnimationCatalogParser.parseCatalog(decoded), !clips.isEmpty {
                    catalogsByIndex[entry.index] = clips
                }
            }
            return (containerIndices, skeletonsByIndex, catalogsByIndex)
        }.value
        embeddedContainerIndices = containers
        skeletons = foundSkeletons
        catalogs = foundCatalogs
        isScanningEntries = false
    }
}

/// Real, decoded joint hierarchy (see `WOCCharacterSkeletonParser`'s doc
/// comment for exactly how this was confirmed) -- an indented tree built
/// from each joint's real parent index, not a flat list.
private struct WOCSkeletonTreeView: View {
    @Environment(\.dismiss) private var dismiss
    let index: Int
    let skeleton: WOCCharacterSkeletonParser.Skeleton

    private var childrenByParent: [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        for (i, joint) in skeleton.joints.enumerated() where joint.parentIndex >= 0 {
            result[joint.parentIndex, default: []].append(i)
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Entry #\(index): \(skeleton.joints.first?.name ?? "") (\(skeleton.joints.count) joints)")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)
            Divider()
            List {
                if let rootIndex = skeleton.joints.firstIndex(where: { $0.parentIndex == -1 }) {
                    row(for: rootIndex, depth: 0)
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private func row(for jointIndex: Int, depth: Int) -> AnyView {
        AnyView(
            Group {
                Text(String(repeating: "  ", count: depth) + skeleton.joints[jointIndex].name)
                    .font(.body.monospaced())
                ForEach(childrenByParent[jointIndex] ?? [], id: \.self) { childIndex in
                    row(for: childIndex, depth: depth + 1)
                }
            }
        )
    }
}

/// Real, decoded animation clip names for one character (see
/// `WOCCharacterAnimationCatalogParser`'s doc comment) -- each clip's
/// actual keyframe data isn't decoded yet, so this lists real names and
/// real blob sizes, not playable animations.
private struct WOCAnimationCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    let index: Int
    let clips: [WOCCharacterAnimationCatalogParser.Clip]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Entry #\(index): \(clips.count) animation clips")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)
            Divider()
            Text("Clip names are real and decoded; each clip's own keyframe/curve data (the actual motion) isn't reverse-engineered yet -- shown here as a real byte size, not playable animation.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            List(Array(clips.enumerated()), id: \.offset) { _, clip in
                HStack {
                    Text(clip.name)
                        .font(.body.monospaced())
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clip.blob.count), countStyle: .file))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 420, minHeight: 480)
    }
}

/// Bridges a plain `Int?` selection state to SwiftUI's `sheet(item:)`,
/// which needs `Identifiable`.
private struct IdentifiableInt: Identifiable {
    let value: Int
    var id: Int { value }
}

private extension Binding where Value == Int? {
    var mappedToIdentifiable: Binding<IdentifiableInt?> {
        Binding<IdentifiableInt?>(
            get: { self.wrappedValue.map(IdentifiableInt.init) },
            set: { self.wrappedValue = $0?.value }
        )
    }
}
