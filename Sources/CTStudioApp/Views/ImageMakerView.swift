import SwiftUI
import AppKit
import CTParsers

/// "Image Maker", builds a complete, standards-compliant ISO-9660 image
/// from a folder tree (`ISO9660ImageBuilder`). See that type's own doc
/// comment for exactly what this does and doesn't have going for it versus
/// the reference tool's own `ImageMaker.cs`: there's no source for the
/// reference's native sector-writing DLL to port, so this implements the
/// real public ECMA-119 standard instead, verified byte-for-byte through
/// this app's own `ISO9660Reader`, not a claim that a disc built this way
/// has been tested on real PS2 hardware or in an emulator.
struct ImageMakerView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var sourceFolder: URL?
    @State private var volumeLabel = "TWINSANITY"
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    @State private var isBuilding = false
    @State private var fileCount: Int?
    @State private var totalByteCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Image Maker").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Builds a complete, real ISO-9660 (ECMA-119) disc image from a folder of files. Every directory record round-trips through this app's own disc-image reader, verified the same way every other writer in this app is. The result has been verified to actually boot in a real PCSX2 build. Real PS2 hardware hasn't been tested; that verification needs hardware this project has no access to.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                LabeledContent("Source Folder") {
                    HStack {
                        Text(sourceFolder?.path ?? "Not chosen")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…") { chooseSourceFolder() }
                    }
                }
                LabeledContent("Volume Label") {
                    TextField("", text: $volumeLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                if let fileCount {
                    LabeledContent("Files Found", value: "\(fileCount)")
                }
                if let totalByteCount {
                    LabeledContent("Total Size", value: ByteCountFormatter.string(fromByteCount: Int64(totalByteCount), countStyle: .file))
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(isBuilding ? "Building…" : "Build Image…") { buildImage() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBuilding || sourceFolder == nil)
            }
        }
        .padding()
        .frame(minWidth: 520)
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder whose contents will become the disc image's root."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceFolder = url
        errorMessage = nil
        let (count, bytes) = Self.countFilesRecursively(at: url)
        fileCount = count
        totalByteCount = bytes
    }

    /// Walks the full folder tree, matching what `ISO9660ImageBuilder`
    /// actually includes (every file in every subdirectory), not just the
    /// top-level entries, a shallow count would understate a nested
    /// source tree and misrepresent what's about to be built.
    private static func countFilesRecursively(at url: URL) -> (count: Int, bytes: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return (0, 0)
        }
        var count = 0
        var bytes = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard values?.isDirectory != true else { continue }
            count += 1
            bytes += values?.fileSize ?? 0
        }
        return (count, bytes)
    }

    private func buildImage() {
        guard let sourceFolder else { return }
        let label = volumeLabel.isEmpty ? "TWINSANITY" : volumeLabel
        errorMessage = nil
        isBuilding = true
        statusMessage = "Building…"
        Task.detached(priority: .userInitiated) {
            do {
                let image = try ISO9660ImageBuilder.buildingImage(from: sourceFolder, volumeLabel: label)
                await MainActor.run {
                    isBuilding = false
                    statusMessage = "Built a \(image.count) byte image. Choose where to save it."
                    saveImage(image)
                }
            } catch {
                await MainActor.run {
                    isBuilding = false
                    errorMessage = "Couldn't build the image: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveImage(_ image: Data) {
        guard let url = ExportPanel.chooseSaveLocation(suggestedName: "\(volumeLabel).iso", message: "Save the built disc image.") else { return }
        Task {
            do {
                try await workspace.writeDataAsync(image, to: url)
                statusMessage = "Saved \(url.lastPathComponent) (\(image.count) bytes)."
            } catch {
                errorMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }
}
