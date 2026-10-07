import SwiftUI
import CTModels

/// "Save State (.mcr / Memory Card) Inspector" (blueprint 7.3): browses a
/// decoded PS2 memory card's directory tree (each top-level entry is
/// normally one game's save, an `icon.sys` plus its data files) and shows
/// per-entry metadata. Read-only, writing back a modified card (deleting a
/// save, editing its file bytes and re-threading the FAT/directory chain
/// correctly) is real scope beyond browsing, and isn't attempted here.
struct MemoryCardInspectorWindow: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let asset: MemoryCardAsset

    @State private var selection: MemoryCardEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                tree
                    .frame(width: 300)
                Divider()
                detail
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Memory Card").font(.title2.bold())
                Text("\(asset.superblock.clustersPerCard * asset.superblock.clusterSize / 1024) KB · \(flatEntryCount) save file/folder(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
        }
        .padding()
    }

    private var flatEntryCount: Int {
        func count(_ entries: [MemoryCardEntry]) -> Int {
            entries.reduce(0) { $0 + 1 + count($1.children) }
        }
        return count(asset.rootEntries)
    }

    private var tree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !asset.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(asset.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }

                if asset.rootEntries.isEmpty {
                    ContentUnavailableView("No Saves Found", systemImage: "externaldrive", description: Text("This card's root directory decoded with no entries."))
                } else {
                    ForEach(asset.rootEntries) { entry in
                        EntryRow(entry: entry, depth: 0, selection: $selection)
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let entry = findEntry(selection, in: asset.rootEntries) {
            Form {
                Section("Identity") {
                    LabeledContent("Name", value: entry.name)
                    LabeledContent("Type", value: entry.isDirectory ? "Directory (save folder)" : "File")
                }
                Section("Attributes") {
                    LabeledContent(entry.isDirectory ? "Entries" : "Size", value: entry.isDirectory ? "\(entry.sizeOrEntryCount)" : ByteCountFormatter.string(fromByteCount: Int64(entry.sizeOrEntryCount), countStyle: .file))
                    LabeledContent("Protected", value: entry.isProtected ? "Yes" : "No")
                    LabeledContent("Hidden", value: entry.isHidden ? "Yes" : "No")
                    LabeledContent("PS1 Format", value: entry.isPSXFormat ? "Yes" : "No")
                }
                Section("Timestamps (JST)") {
                    LabeledContent("Created", value: dateString(entry.created))
                    LabeledContent("Modified", value: dateString(entry.modified))
                }
                Section("Raw") {
                    LabeledContent("Mode", value: "0x\(String(entry.mode, radix: 16))")
                    LabeledContent("First Cluster", value: "\(entry.cluster) (alloc-relative)")
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a Save", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func findEntry(_ id: MemoryCardEntry.ID, in entries: [MemoryCardEntry]) -> MemoryCardEntry? {
        for entry in entries {
            if entry.id == id { return entry }
            if let found = findEntry(id, in: entry.children) { return found }
        }
        return nil
    }

    private func dateString(_ timestamp: MemoryCardTimestamp) -> String {
        guard let date = timestamp.date else { return "N/A" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

private struct EntryRow: View {
    let entry: MemoryCardEntry
    let depth: Int
    @Binding var selection: MemoryCardEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                selection = entry.id
            } label: {
                HStack {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(entry.isDirectory ? .yellow : .secondary)
                    Text(entry.name)
                        .lineLimit(1)
                    Spacer()
                    if entry.isProtected {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, CGFloat(depth) * 14)
                .contentShape(Rectangle())
                .background(selection == entry.id ? Color.accentColor.opacity(0.15) : Color.clear)
            }
            .buttonStyle(.plain)

            ForEach(entry.children) { child in
                EntryRow(entry: child, depth: depth + 1, selection: $selection)
            }
        }
    }
}
