import SwiftUI
import AppKit
import CTModels
import CTParsers
import CTExport

struct TextureInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let texture: TextureAsset
    @State private var selectedMip: Int = -1 // -1 = base level
    @State private var upscaledTexture: TextureAsset?
    @State private var isUpscaling = false
    @State private var upscaleError: String?
    @State private var isReplacingTexture = false
    @State private var replaceError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let upscaledTexture {
                upscaledPreview(upscaledTexture)
            } else if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 320)
                    .background(checkerboard)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            } else {
                ContentUnavailableView("Format Not Decoded", systemImage: "photo.badge.exclamationmark",
                    description: Text("\(texture.pixelFormat.rawValue.uppercased()) isn't fully decoded by this build. Only the raw record is available."))
                    .frame(height: 200)
            }

            Form {
                LabeledContent("Dimensions", value: "\(texture.width) × \(texture.height)")
                Picker("Pixel Format", selection: .constant(texture.pixelFormat)) {
                    Text(texture.pixelFormat.rawValue.uppercased()).tag(texture.pixelFormat)
                }
                .disabled(true)
                if !texture.mips.isEmpty {
                    Picker("Preview Level", selection: $selectedMip) {
                        Text("Base (\(texture.width)×\(texture.height))").tag(-1)
                        ForEach(texture.mips.indices, id: \.self) { level in
                            let divisor = 1 << (level + 1)
                            Text("Mip \(level + 1) (\(texture.width / divisor)×\(texture.height / divisor))").tag(level)
                        }
                    }
                }
                LabeledContent("Fully Decoded", value: texture.pixelFormat.isFullyDecoded ? "Yes" : "No")
            }
            .formStyle(.grouped)

            HStack {
                Button {
                    exportPNG()
                } label: {
                    Label("Export PNG…", systemImage: "square.and.arrow.up")
                }
                .disabled(!texture.pixelFormat.isFullyDecoded)
                Button {
                    presentUpscaleModelPanel()
                } label: {
                    Label(isUpscaling ? "Upscaling…" : "Upscale with CoreML Model…", systemImage: "sparkles")
                }
                .disabled(!texture.pixelFormat.isFullyDecoded || isUpscaling)
                if upscaledTexture != nil {
                    Button("Revert to Original") { upscaledTexture = nil }
                        .buttonStyle(.borderless)
                }
                Spacer()
                if isUpscaling { ProgressView().controlSize(.small) }
            }
            if let upscaleError {
                Label(upscaleError, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack {
                Button {
                    presentReplaceImagePanel()
                } label: {
                    Label(isReplacingTexture ? "Replacing…" : "Replace with Image…", systemImage: "photo.badge.plus")
                }
                .disabled(!Self.isReplaceable(texture.pixelFormat) || isReplacingTexture)
                Spacer()
                if isReplacingTexture { ProgressView().controlSize(.small) }
            }
            Text(Self.isReplaceable(texture.pixelFormat)
                ? "\"Asset Swap & Quick-Test: Recipe Book\" (blueprint 6.4) texture replace: resamples an image you pick to this texture's exact \(texture.width) × \(texture.height) and re-encodes it into a real \(texture.pixelFormat.rawValue.uppercased()) record, then saves an edited copy. The original file on disk is not modified."
                : "Only PSMCT32/PSMT8 (PS2 raw RGBA / 8-bit indexed) and raw-uncompressed TextureX (Xbox) textures can be replaced. This is \(texture.pixelFormat.rawValue.uppercased()), which has no verified encoder yet (re-compressing to DXT5 is real, separate work this build doesn't guess at).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let replaceError {
                Label(replaceError, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// "Asset Swap & Quick-Test: Recipe Book" (blueprint 6.4) sprite/texture
    /// replace, the same decode -> edit -> encode -> patch -> save-as-copy
    /// loop `PositionInspectorView`/`InstanceInspectorView` established,
    /// with `TextureWriter.replacingPixelData` standing in for
    /// `WorldPlacementWriter`.
    private func presentReplaceImagePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a replacement image. It's resampled to this texture's exact \(texture.width) × \(texture.height); the on-disk record can't change size."
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        replaceError = nil
        guard let nsImage = NSImage(contentsOf: url),
              let resampled = Self.resampledRGBA(from: nsImage, width: texture.width, height: texture.height)
        else {
            replaceError = "Couldn't read that file as an image."
            return
        }
        let replacement = TextureAsset(id: texture.id, width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat, rgba: resampled)
        guard let originalRecordBytes = workspace.rawBytes(for: node) else {
            replaceError = "Couldn't read this texture's original on-disk bytes. This record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return
        }
        do {
            let newRecordBytes = texture.pixelFormat == .rawRGBA
                ? try TextureXWriter.replacingPixelData(of: replacement, inOriginalRecordBytes: originalRecordBytes)
                : try TextureWriter.replacingPixelData(of: replacement, inOriginalRecordBytes: originalRecordBytes)
            guard let patchedBytes = workspace.patchedFileBytes(replacing: node, with: newRecordBytes) else {
                replaceError = "Couldn't patch this texture back into its file."
                return
            }
            guard let saveURL = ExportPanel.chooseSaveLocation(
                suggestedName: "\(node.displayName)_edited.rm2",
                message: "Save the edited copy of this file, with this texture replaced. The original file on disk is not modified."
            ) else { return }
            isReplacingTexture = true
            Task {
                do {
                    try await workspace.writeDataAsync(patchedBytes, to: saveURL)
                    workspace.statusMessage = "Saved edited copy to \(saveURL.lastPathComponent) with this texture replaced. The original file was not modified."
                } catch {
                    workspace.lastError = "Save failed: \(error)"
                }
                isReplacingTexture = false
            }
        } catch {
            replaceError = error.localizedDescription
        }
    }

    /// Resamples `image` to exactly `width` × `height` RGBA8, same
    /// CGContext-into-a-pinned-buffer technique as
    /// `TextureUpscaler.makeTextureAsset`, reused here rather than
    /// diverging on a second pixel-extraction path, just parameterized by
    /// a target size decoupled from the source image's own dimensions
    /// (this always needs to land on the original texture's exact size,
    /// never the picked image's).
    /// "Parity Phase L": which pixel formats have a verified, byte-exact
    /// encoder to replace back into, PS2 PSMCT32/PSMT8 (`TextureWriter`,
    /// the latter via `PSMT8Quantizer`'s median-cut palette generation) and
    /// Xbox raw-uncompressed `TextureX` (`TextureXWriter`). DXT5 isn't
    /// included; see the button's own caption for why.
    /// Not `private` -- `PTCSheetsHubView` reuses this same support matrix
    /// for `.ptc`/`.psm` entries.
    static func isReplaceable(_ format: TexturePixelFormat) -> Bool {
        format == .psmct32 || format == .psmt8 || format == .rawRGBA
    }

    /// Not `private` -- `PTCSheetsHubView`'s own texture replace flow
    /// (`.ptc`/`.psm` entries) reuses this exact resample step rather than
    /// duplicating it.
    static func resampledRGBA(from image: NSImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        var proposedRect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var didDraw = false
        rgba.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            didDraw = true
        }
        return didDraw ? rgba : nil
    }

    /// "Neural Texture Upscaling" (roadmap 5.4): real result of a real
    /// user-supplied model, shown alongside, never in place of, until the
    /// user explicitly reverts, the real decoded original, so it's never
    /// ambiguous which one is actually on disk versus model output.
    private func upscaledPreview(_ upscaled: TextureAsset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cgImage = try? TextureExporter.cgImage(from: upscaled, mipLevel: nil) {
                Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 320)
                    .background(checkerboard)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
            Text("Upscaled: \(upscaled.width) × \(upscaled.height) (from \(texture.width) × \(texture.height)). This is output from the model you selected, not decoded game data.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                exportUpscaledPNG(upscaled)
            } label: {
                Label("Export Upscaled PNG…", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func presentUpscaleModelPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a real CoreML model (.mlmodel/.mlmodelc) trained for image super-resolution. No model ships with this build."
        guard panel.runModal() == .OK, let modelURL = panel.urls.first else { return }
        upscaleError = nil
        isUpscaling = true
        Task {
            do {
                let result = try await TextureUpscaler.upscale(texture, usingModelAt: modelURL)
                upscaledTexture = result
            } catch {
                upscaleError = error.localizedDescription
            }
            isUpscaling = false
        }
    }

    private func exportUpscaledPNG(_ upscaled: TextureAsset) {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export the upscaled texture into.") else { return }
        Task { await workspace.exportTexturePNG(upscaled, suggestedName: node.displayName.replacingOccurrences(of: " ", with: "_") + "_upscaled", to: directory) }
    }

    private var nsImage: NSImage? {
        guard texture.pixelFormat.isFullyDecoded else { return nil }
        let mip = selectedMip >= 0 ? selectedMip : nil
        guard let cgImage = try? TextureExporter.cgImage(from: texture, mipLevel: mip) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let tile: CGFloat = 8
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = row
                while x < size.width {
                    let isDark = col.isMultiple(of: 2)
                    context.fill(Path(CGRect(x: x, y: y, width: tile, height: tile)), with: .color(isDark ? Color(nsColor: .quaternaryLabelColor) : .clear))
                    x += tile
                    col += 1
                }
                y += tile
                row += 1
            }
        }
    }

    private func exportPNG() {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this texture (and its mip levels) into.") else { return }
        Task { await workspace.exportTexturePNG(texture, suggestedName: node.displayName.replacingOccurrences(of: " ", with: "_"), to: directory) }
    }
}
