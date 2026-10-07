import SwiftUI
import AppKit
import CTModels
import CTParsers
import CTExport

/// "Font & Particle Sheets": browses every standalone `.ptc`/`.psm`/`.psf`
/// texture-atlas container opened this session, ports the reference
/// editor's `PTCViewer` (prev/next entry navigation, PNG export) plus the
/// read side of `PSMWorker`'s atlas browsing. Real decode (embedded
/// Texture+Material pairs via `TwinsPTCParser`) and real PNG export
/// (`TextureExporter`, the same path `TextureInspectorView` uses).
///
/// "PSM Editor": write-back for `.ptc`/`.psm` entries (not `.psf` font
/// pages yet) now exists too, reusing the exact same encoders
/// `TextureInspectorView`'s "Replace with Image…" already uses
/// (`TextureWriter`/`TextureXWriter`), the reference's own texture
/// *importer* really was dead code (`TextureImport.cs`'s `btnImport_Click`
/// throws `NotImplementedException` on its first line), but the "from-
/// scratch PS2 texture encoder" this used to say was separate, higher-risk
/// work is exactly what `TextureWriter`'s PSMCT32/PSMT8 encode paths
/// already are, this just wires the same solved lower-level pieces into
/// this container format's own byte layout (`TwinsPTCEntry.
/// textureFileOffset`/`textureRecordByteLength`), no new binary format
/// reverse-engineering needed. `.psm`'s own on-disk shape has no header at
/// all to write (entries are just packed back-to-back, per `TwinsPTCParser
/// .parsePSM`'s own doc comment), so a patch here is exactly the same
/// "replace this one record's bytes in place, save as a new file"
/// operation `TextureInspectorView` already does for chunk-tree textures.
struct PTCSheetsHubView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    /// Set when docked into the main window's detail column (see
    /// `DetailColumn`); nil when still presented as a `.sheet`.
    var onClose: (() -> Void)? = nil
    @State private var selectedSheetID: String?
    @State private var selectedEntryID: UInt32?
    @State private var isReplacingTexture = false
    @State private var replaceError: String?

    private enum SheetRef: Identifiable, Hashable {
        case psm(String)
        case font(String)
        var id: String {
            switch self {
            case .psm(let label): return "psm:\(label)"
            case .font(let label): return "font:\(label)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sheetList
                Divider()
                entryList
                Divider()
                detail
            }
        }
        .frame(minWidth: 880, minHeight: 540)
        .onAppear {
            if selectedSheetID == nil {
                selectedSheetID = (workspace.ptcSheets.first.map { SheetRef.psm($0.sourceLabel) } ?? workspace.fontSheets.first.map { SheetRef.font($0.sourceLabel) })?.id
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Font & Particle Sheets").font(.title2.bold())
                Text("\(workspace.ptcSheets.count) sheet(s), \(workspace.fontSheets.count) font container(s) loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { (onClose ?? { dismiss() })() }
        }
        .padding()
    }

    private var sheetRefs: [SheetRef] {
        workspace.ptcSheets.map { .psm($0.sourceLabel) } + workspace.fontSheets.map { .font($0.sourceLabel) }
    }

    private var sheetList: some View {
        List(sheetRefs, selection: $selectedSheetID) { ref in
            switch ref {
            case .psm(let label):
                let sheet = workspace.ptcSheets.first { $0.sourceLabel == label }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.callout.bold())
                    Text("\(sheet?.entries.count ?? 0) entries").font(.caption2).foregroundStyle(.secondary)
                }
                .tag(ref.id)
            case .font(let label):
                let font = workspace.fontSheets.first { $0.sourceLabel == label }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(label) (font)").font(.callout.bold())
                    Text("\(font?.fontPages.count ?? 0) pages, \(font?.vectors.count ?? 0) vectors").font(.caption2).foregroundStyle(.secondary)
                }
                .tag(ref.id)
            }
        }
        .frame(width: 220)
        .listStyle(.sidebar)
    }

    private var selectedEntries: [TwinsPTCEntry] {
        guard let selectedSheetID else { return [] }
        if let sheet = workspace.ptcSheets.first(where: { SheetRef.psm($0.sourceLabel).id == selectedSheetID }) {
            return sheet.entries
        }
        if let font = workspace.fontSheets.first(where: { SheetRef.font($0.sourceLabel).id == selectedSheetID }) {
            return font.fontPages
        }
        return []
    }

    /// `nil` when the current selection is a `.psf` font sheet (font pages
    /// aren't write-back-enabled yet, see this view's own doc comment) --
    /// only a real `.ptc`/`.psm` sheet carries the `sourceURL` a patch
    /// needs to re-read fresh bytes from.
    private var selectedPSMAsset: TwinsPSMAsset? {
        guard let selectedSheetID else { return nil }
        return workspace.ptcSheets.first { SheetRef.psm($0.sourceLabel).id == selectedSheetID }
    }

    @ViewBuilder
    private var entryList: some View {
        List(selectedEntries, selection: $selectedEntryID) { entry in
            HStack {
                Image(systemName: "photo")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tex #\(entry.texID) / Mat #\(entry.matID)").lineLimit(1)
                    Text("\(entry.texture.width)×\(entry.texture.height) · \(entry.material.name.isEmpty ? "<unnamed>" : entry.material.name)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(entry.texID)
        }
        .frame(width: 280)
        .onChange(of: selectedSheetID) { _, _ in selectedEntryID = selectedEntries.first?.texID }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedEntryID, let entry = selectedEntries.first(where: { $0.texID == selectedEntryID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let nsImage = Self.nsImage(for: entry.texture) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 320, maxHeight: 320)
                            .background(Color(nsColor: .underPageBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    }
                    Form {
                        Section("Texture") {
                            LabeledContent("ID", value: "\(entry.texID)")
                            LabeledContent("Size", value: "\(entry.texture.width) × \(entry.texture.height)")
                            LabeledContent("Format", value: entry.texture.pixelFormat.rawValue)
                        }
                        Section("Material") {
                            LabeledContent("ID", value: "\(entry.matID)")
                            LabeledContent("Name", value: entry.material.name.isEmpty ? "<unnamed>" : entry.material.name)
                            LabeledContent("Shaders", value: "\(entry.material.shaders.count)")
                        }
                    }
                    .formStyle(.grouped)
                    HStack {
                        Button {
                            exportPNG(entry.texture)
                        } label: {
                            Label("Export PNG…", systemImage: "square.and.arrow.up")
                        }
                        if let selectedPSMAsset {
                            Button {
                                presentReplaceImagePanel(entry: entry, in: selectedPSMAsset)
                            } label: {
                                Label(isReplacingTexture ? "Replacing…" : "Replace with Image…", systemImage: "photo.badge.plus")
                            }
                            .disabled(!TextureInspectorView.isReplaceable(entry.texture.pixelFormat) || isReplacingTexture)
                        }
                        Spacer()
                        if isReplacingTexture { ProgressView().controlSize(.small) }
                    }
                    if selectedPSMAsset != nil {
                        Text(TextureInspectorView.isReplaceable(entry.texture.pixelFormat)
                            ? "Resamples an image you pick to this entry's exact \(entry.texture.width) × \(entry.texture.height) and re-encodes it into a real \(entry.texture.pixelFormat.rawValue.uppercased()) record, patched into a saved copy of this \(selectedPSMAsset?.sourceURL.pathExtension.uppercased() ?? "PSM") file. The original file on disk is not modified."
                            : "This entry is \(entry.texture.pixelFormat.rawValue.uppercased()), which has no verified encoder yet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let replaceError {
                        Label(replaceError, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }
            .onChange(of: entry.texID) { _, _ in replaceError = nil }
        } else {
            ContentUnavailableView("No Entry Selected", systemImage: "photo.on.rectangle")
        }
    }

    /// Mirrors `TextureInspectorView.presentReplaceImagePanel`'s exact
    /// decode -> resample -> encode -> patch -> save-as-copy loop, with one
    /// difference: this container has no `ChunkNode` (`workspace.
    /// rawBytes(for:)`/`patchedFileBytes(replacing:with:)` only cover the
    /// chunk-tree formats), so the patch reads fresh bytes from `asset.
    /// sourceURL` directly and splices `entry.textureFileOffset`/
    /// `textureRecordByteLength` itself instead.
    private func presentReplaceImagePanel(entry: TwinsPTCEntry, in asset: TwinsPSMAsset) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a replacement image. It's resampled to this entry's exact \(entry.texture.width) × \(entry.texture.height); the record can't change size."
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        replaceError = nil
        guard let nsImage = NSImage(contentsOf: url),
              let resampled = TextureInspectorView.resampledRGBA(from: nsImage, width: entry.texture.width, height: entry.texture.height)
        else {
            replaceError = "Couldn't read that file as an image."
            return
        }
        let replacement = TextureAsset(id: entry.texture.id, width: entry.texture.width, height: entry.texture.height, pixelFormat: entry.texture.pixelFormat, rgba: resampled)
        let sourceURL = asset.sourceURL
        // Same "keep file I/O off the main actor" discipline as every other
        // save path, a PTC/PSM sheet can be several MB, and this whole-
        // file read used to run synchronously on the main actor before any
        // of the async write path even started, freezing the UI.
        isReplacingTexture = true
        Task {
            do {
                let readTask = Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                }
                var fileBytes = try await readTask.value
                guard entry.textureFileOffset >= 0, entry.textureRecordByteLength >= 0,
                      entry.textureFileOffset + entry.textureRecordByteLength <= fileBytes.count
                else {
                    replaceError = "This entry's recorded byte range no longer matches the file, can't patch safely."
                    isReplacingTexture = false
                    return
                }
                let originalRecordBytes = fileBytes.subdata(in: entry.textureFileOffset..<(entry.textureFileOffset + entry.textureRecordByteLength))
                let newRecordBytes = entry.texture.pixelFormat == .rawRGBA
                    ? try TextureXWriter.replacingPixelData(of: replacement, inOriginalRecordBytes: originalRecordBytes)
                    : try TextureWriter.replacingPixelData(of: replacement, inOriginalRecordBytes: originalRecordBytes)
                fileBytes.replaceSubrange(entry.textureFileOffset..<(entry.textureFileOffset + entry.textureRecordByteLength), with: newRecordBytes)

                guard let saveURL = ExportPanel.chooseSaveLocation(
                    suggestedName: "\(asset.sourceLabel)_edited.\(asset.sourceURL.pathExtension)",
                    message: "Save the edited copy of this file, with this entry's texture replaced. The original file on disk is not modified."
                ) else {
                    isReplacingTexture = false
                    return
                }
                try await workspace.writeDataAsync(fileBytes, to: saveURL)
                workspace.statusMessage = "Saved edited copy to \(saveURL.lastPathComponent) with entry #\(entry.texID)'s texture replaced. The original file was not modified."
            } catch {
                replaceError = error.localizedDescription
            }
            isReplacingTexture = false
        }
    }

    private static func nsImage(for texture: TextureAsset) -> NSImage? {
        guard let cgImage = try? TextureExporter.cgImage(from: texture, mipLevel: nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func exportPNG(_ texture: TextureAsset) {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this texture as a .png file into.") else { return }
        let url = directory.appendingPathComponent("texture_\(texture.id)").appendingPathExtension("png")
        do {
            try TextureExporter.exportPNG(texture, to: url)
            workspace.statusMessage = "Exported \(url.lastPathComponent)."
        } catch {
            workspace.lastError = "Export failed: \(error)"
        }
    }
}
