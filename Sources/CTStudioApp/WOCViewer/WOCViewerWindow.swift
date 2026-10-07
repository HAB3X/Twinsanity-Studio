import SwiftUI
import CoreGraphics
import CTParsers

enum WOCViewerTab: String, CaseIterable, Identifiable {
    case objects = "Placed Objects"
    case textures = "Textures"
    case entities = "AI / Entities"
    case scenery = "Scenery"
    case animations = "Animations"
    case paths = "Paths"
    case terrain = "Terrain"
    case effects = "Effects"
    case interactive = "Interactive Objects"
    var id: String { rawValue }
}

struct WOCViewerWindow: View {
    let asset: WOCLevelAsset

    @State private var renderer: WOCViewerRenderer?
    @State private var tab: WOCViewerTab = .objects

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(WOCViewerTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()

            switch tab {
            case .objects:
                HStack(spacing: 0) {
                    viewportArea
                    Divider()
                    objectSidebar
                        .frame(width: 300)
                }
            case .textures:
                WOCTextureGalleryView(textures: asset.textures)
            case .entities:
                WOCEntityListView(entities: asset.entities)
            case .scenery:
                WOCFoliageListView(foliage: asset.foliage)
            case .animations:
                WOCAnimationListView(animations: asset.animations, fileExistsButUnparsed: asset.animationFileExistsButUnparsed)
            case .paths:
                WOCPathInfoView(pathFile: asset.pathFile)
            case .terrain:
                WOCTerrainInfoView(mainBlockByteCount: asset.terrainMainBlockByteCount, tailRecordCount: asset.terrainTailRecordCount)
            case .effects:
                WOCParticleEffectsView(
                    particleEffects: asset.particleEffects,
                    particleFileExistsButUnparsed: asset.particleFileExistsButUnparsed,
                    checkpointEffects: asset.checkpointEffects,
                    checkpointFileExistsButUnparsed: asset.checkpointFileExistsButUnparsed
                )
            case .interactive:
                WOCInteractiveObjectsView(objects: asset.interactiveObjects, declaredCount: asset.interactiveObjectDeclaredCount)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        // Performance fix (audit): mirrors the identical fix already
        // applied to `LevelViewerWindow` for the same reason, building
        // this renderer runs the same shape of unbounded, per-placement
        // CPU work (`upload(objects:...)`'s own doc comment: "drawn per
        // placed object") synchronously in `.onAppear` used to block all
        // input for however long a WoC level's whole placement count took
        // to upload. `.task` (not `.onAppear` + a bare `Task {}`) so this
        // is automatically cancelled if the window closes before it
        // finishes; the actual GPU work runs in `Task.detached` since
        // `WOCViewerRenderer.init?` is a plain synchronous initializer with
        // no main-actor affinity, same reasoning as the Level Viewer fix.
        .task {
            let objects = asset.objects
            let distinctObjectCount = asset.distinctObjectCount
            let objectMeshes = asset.objectMeshes
            let materialTextureIDs = asset.materialTextureIDs
            let built = await Task.detached(priority: .userInitiated) {
                WOCViewerRenderer(objects: objects, objectCount: distinctObjectCount, objectMeshes: objectMeshes, materialTextureIDs: materialTextureIDs)
            }.value
            guard !Task.isCancelled else { return }
            renderer = built
        }
    }

    @ViewBuilder
    private var viewportArea: some View {
        if let renderer {
            if asset.objects.isEmpty {
                ContentUnavailableView(
                    "No Placed Objects",
                    systemImage: "square.dashed",
                    description: Text("This level's INST section decoded to zero instances.")
                )
            } else {
                ZStack(alignment: .bottomLeading) {
                    MetalModelView(renderer: renderer)
                        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    Text("Drag to orbit · Scroll to zoom")
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("Metal Unavailable", systemImage: "exclamationmark.triangle", description: Text("Couldn't initialize a Metal device on this Mac."))
        }
    }

    private var objectSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(asset.name)
                    .font(.title3.bold())

                Form {
                    LabeledContent("Placed Objects", value: "\(asset.objects.count)")
                    LabeledContent("Distinct Objects", value: "\(asset.distinctObjectCount)")
                    LabeledContent("Named Entries", value: "\(asset.objectNames.count)")
                    LabeledContent("Textures", value: "\(asset.textureCount)")
                    LabeledContent("AI Entities", value: "\(asset.entities.count)")
                    LabeledContent("Foliage", value: "\(asset.foliage.count)")
                    LabeledContent("Animations", value: asset.animationFileExistsButUnparsed ? "present, undecoded" : "\(asset.animations.count)")
                    LabeledContent("Path Records", value: asset.pathFile.map { "\($0.records.count)" } ?? "none")
                    LabeledContent("Terrain", value: asset.terrainMainBlockByteCount.map { "\($0) bytes" } ?? "none")
                    LabeledContent("Texture Assignments", value: asset.textureAssignments.map { "\($0.textureIndices.count) indices" } ?? "none")
                    LabeledContent("Particle Effects", value: asset.particleFileExistsButUnparsed ? "present, undecoded" : "\(asset.particleEffects.count)")
                    LabeledContent("Checkpoint Effects", value: asset.checkpointFileExistsButUnparsed ? "present, undecoded" : "\(asset.checkpointEffects.count)")
                    LabeledContent("Interactive Objects", value: "\(asset.interactiveObjects.count) of \(asset.interactiveObjectDeclaredCount) declared")
                    LabeledContent("Camera Paths", value: asset.cameraPathNames.isEmpty ? "none" : "\(asset.cameraPathNames.count)")
                    LabeledContent("Sections", value: asset.sectionTags.joined(separator: ", "))
                }
                .formStyle(.grouped)

                statusNote

                if !asset.objectNames.isEmpty {
                    Divider()
                    Text("Name Table (\(asset.objectNames.count))")
                        .font(.subheadline.bold())
                    ForEach(Array(asset.objectNames.prefix(60).enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if asset.objectNames.count > 60 {
                        Text("+ \(asset.objectNames.count - 60) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !asset.cameraPathNames.isEmpty {
                    Divider()
                    Text("Camera Paths (\(asset.cameraPathNames.count))")
                        .font(.subheadline.bold())
                    Text("Real, named cinematic camera path entry points (from the sibling .VIS file) -- despite the extension, this is not a visibility system. The underlying path graph itself isn't decoded yet, just these names.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(Array(asset.cameraPathNames.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }

    private var statusNote: some View {
        Text("Each point is one real, decoded placed-object position and world transform (WoC's INST section), color-coded by which distinct object it is. This is not yet real mesh geometry, WoC's per-object mesh boundaries (inside its OBJ0 section) aren't decoded yet, so there's no reliable per-object shape to draw. What's shown here is real, correctly-positioned data, just points rather than final meshes.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// The actual UI surface for real texture decoding: every texture found in
/// the level's `TST0` section, decoded to real RGBA pixels
/// (`WOCTextureDecoder`) and shown as an image, not just a byte count in a
/// stats panel.
private struct WOCTextureGalleryView: View {
    let textures: [WOCDecodedTexture]

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12)]

    var body: some View {
        if textures.isEmpty {
            ContentUnavailableView("No Textures", systemImage: "photo.on.rectangle.angled", description: Text("This level's TST0 section decoded to zero textures."))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(textures) { texture in
                        WOCTextureCard(texture: texture)
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct WOCTextureCard: View {
    let texture: WOCDecodedTexture

    var body: some View {
        VStack(spacing: 4) {
            if let cgImage = texture.cgImage {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .background(Color(white: 0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ZStack {
                    Color(white: 0.15)
                    Image(systemName: "questionmark.square.dashed")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text("\(texture.width)×\(texture.height)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if texture.usedPalette {
                Text("indexed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// From the sibling `.AI` file: real enemy/AI entity spawns with their
/// patrol waypoint counts (see `WOCAIParser`).
private struct WOCEntityListView: View {
    let entities: [WOCAIParser.Entity]

    var body: some View {
        if entities.isEmpty {
            ContentUnavailableView("No AI Entities", systemImage: "figure.walk", description: Text("This level has no sibling .AI file, or it decoded to zero entities."))
        } else {
            List(Array(entities.enumerated()), id: \.offset) { _, entity in
                HStack {
                    Text(entity.name)
                        .font(.body.monospaced())
                    Spacer()
                    Text("\(entity.waypoints.count) waypoint\(entity.waypoints.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// From the sibling `.GRA` file: real foliage/grass scatter placements
/// (see `WOCGrassParser`).
private struct WOCFoliageListView: View {
    let foliage: [WOCGrassParser.Placement]

    var body: some View {
        if foliage.isEmpty {
            ContentUnavailableView("No Scenery/Foliage", systemImage: "leaf", description: Text("This level has no sibling .GRA file, or it decoded to zero placements."))
        } else {
            List(Array(foliage.enumerated()), id: \.offset) { _, placement in
                HStack {
                    Text(placement.name)
                        .font(.body.monospaced())
                    Spacer()
                    Text(String(format: "(%.1f, %.1f, %.1f)", placement.position.x, placement.position.y, placement.position.z))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// From the sibling `.ANM` file: real simple-object-animation entries
/// (see `WOCAnimationParser`). Skeletal-animation files, a different and
/// still-undecoded format, are surfaced honestly rather than shown as
/// garbage entries.
private struct WOCAnimationListView: View {
    let animations: [WOCAnimationParser.Entry]
    let fileExistsButUnparsed: Bool

    var body: some View {
        if fileExistsButUnparsed {
            ContentUnavailableView(
                "Animation Format Not Yet Decoded",
                systemImage: "figure.run.circle",
                description: Text("This level has a sibling .ANM file, but it's a skeletal-animation format (like TOONARMY.ANM) that isn't decoded yet, not the simple object-animation format that is.")
            )
        } else if animations.isEmpty {
            ContentUnavailableView("No Animations", systemImage: "play.rectangle", description: Text("This level has no sibling .ANM file, or it decoded to zero entries."))
        } else {
            List(Array(animations.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body.monospaced())
                    Text("flag \(entry.flag) · \(entry.subEntries.count) sub-entr\(entry.subEntries.count == 1 ? "y" : "ies")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// From the sibling `.PAD` file: real decoded per-record fields (see
/// `WOCPadParser`'s doc comment) -- a confirmed continuously-sampled
/// heading angle plus gated parameter bytes. What actually consumes this
/// data (AI patrol, a vehicle rail, a camera path) is still unresolved,
/// so this shows real decoded values, not an interpreted path graph.
private struct WOCPathInfoView: View {
    let pathFile: WOCPadParser.File?

    var body: some View {
        if let pathFile {
            VStack(spacing: 12) {
                Form {
                    LabeledContent("Records", value: "\(pathFile.records.count)")
                    LabeledContent("Magic", value: "\(pathFile.magic)")
                    LabeledContent("Angle Range", value: angleRangeText)
                    LabeledContent("Records Using Parameter Bytes", value: "\(activeParameterRecordCount)")
                }
                .formStyle(.grouped)
                .frame(maxWidth: 420)
                Text("This level's .PAD records decode to a confirmed continuously-sampled heading angle plus up to four gated parameter bytes (plausibly speed/curvature-type values) per record -- real, decoded fields, but what actually consumes this path data (AI patrol, a vehicle rail, a camera path) isn't confirmed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Path Data", systemImage: "point.topleft.down.curvedto.point.bottomright.up", description: Text("This level has no sibling .PAD file."))
        }
    }

    private var angleRangeText: String {
        guard let pathFile, !pathFile.records.isEmpty else { return "n/a" }
        let angles = pathFile.records.map(\.angleDegrees)
        return String(format: "%.0f°...%.0f°", angles.min() ?? 0, angles.max() ?? 0)
    }

    private var activeParameterRecordCount: Int {
        pathFile?.records.filter { $0.parameterBytes.b9 != 0 || $0.parameterBytes.b10 != 0 || $0.parameterBytes.b11 != 0 || $0.parameterBytes.b13 != 0 }.count ?? 0
    }
}

/// From the sibling `.TER` file: confirmed outer framing only, the bulk
/// of real terrain/collision geometry (the "main block") is not decoded
/// yet, so this shows how much real data is there without pretending to
/// show its content (see `WOCTerrainParser`).
private struct WOCTerrainInfoView: View {
    let mainBlockByteCount: Int?
    let tailRecordCount: Int?

    var body: some View {
        if let mainBlockByteCount, let tailRecordCount {
            VStack(spacing: 12) {
                Form {
                    LabeledContent("Main Block", value: "\(mainBlockByteCount) bytes")
                    LabeledContent("Tail Records", value: "\(tailRecordCount)")
                }
                .formStyle(.grouped)
                .frame(maxWidth: 420)
                Text("This level's .TER outer framing is decoded, but the main block's internal terrain geometry isn't reverse-engineered yet, these are real byte/record counts, not interpreted terrain data.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Terrain Data", systemImage: "mountain.2", description: Text("This level has no sibling .TER file."))
        }
    }
}

/// From the sibling `.PTL`/`.CPT` files: real particle effect / checkpoint
/// effect definitions, but only the handful of fields with real
/// cross-file evidence are shown (see `WOCParticleParser`'s doc comment
/// for exactly what's confirmed vs. still undecoded in each 839-byte
/// record).
private struct WOCParticleEffectsView: View {
    let particleEffects: [WOCParticleParser.ParticleRecord]
    let particleFileExistsButUnparsed: Bool
    let checkpointEffects: [WOCParticleParser.ParticleRecord]
    let checkpointFileExistsButUnparsed: Bool

    var body: some View {
        if particleEffects.isEmpty && checkpointEffects.isEmpty && !particleFileExistsButUnparsed && !checkpointFileExistsButUnparsed {
            ContentUnavailableView("No Effects", systemImage: "sparkles", description: Text("This level has no sibling .PTL or .CPT file, or they decoded to zero records."))
        } else {
            List {
                if particleFileExistsButUnparsed {
                    Section("Particle Effects (.PTL)") {
                        Text("Present, but this file uses the complex variable-length record format that isn't decoded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !particleEffects.isEmpty {
                    Section("Particle Effects (.PTL)") {
                        ForEach(Array(particleEffects.enumerated()), id: \.offset) { _, record in
                            WOCParticleRecordRow(record: record)
                        }
                    }
                }
                if checkpointFileExistsButUnparsed {
                    Section("Checkpoint Effects (.CPT)") {
                        Text("Present, but this file uses the complex variable-length record format that isn't decoded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !checkpointEffects.isEmpty {
                    Section("Checkpoint Effects (.CPT)") {
                        ForEach(Array(checkpointEffects.enumerated()), id: \.offset) { _, record in
                            WOCParticleRecordRow(record: record)
                        }
                    }
                }
            }
        }
    }
}

private struct WOCParticleRecordRow: View {
    let record: WOCParticleParser.ParticleRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.name)
                .font(.body.monospaced())
            Text(String(
                format: "lifetime %.2fs · rotation %.0f°...%.0f° · size %.0f×%.0f",
                record.lifetimeSeconds, record.minRotationDegrees, record.maxRotationDegrees,
                record.maxSizeWidth, record.maxSizeHeight
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// From the sibling `.OBJ` file: real interactive object placements
/// (levers, pistons, hammers, gates, ...). `objects.count` can be less
/// than `declaredCount` on files with object types whose type-specific
/// tail data isn't decoded yet, see `WOCObjectParser`'s doc comment.
private struct WOCInteractiveObjectsView: View {
    let objects: [WOCObjectParser.ObjectRecord]
    let declaredCount: Int

    var body: some View {
        if objects.isEmpty {
            ContentUnavailableView("No Interactive Objects", systemImage: "gearshape.2", description: Text("This level has no sibling .OBJ file, or it decoded to zero objects."))
        } else {
            VStack(spacing: 0) {
                if objects.count < declaredCount {
                    Text("Showing \(objects.count) of \(declaredCount) declared objects, the file appears truncated or corrupt past this point (see WOCObjectParser).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                    Divider()
                }
                List(Array(objects.enumerated()), id: \.offset) { _, object in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(object.name)
                            .font(.body.monospaced())
                        Text("\(object.placements.count) placement\(object.placements.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private extension WOCDecodedTexture {
    /// Builds a real `CGImage` from the decoded RGBA bytes. `nil` when
    /// decoding genuinely failed (e.g. an indexed texture whose CLUT
    /// couldn't be found, `rgba` is empty in that case, not fabricated
    /// pixels) rather than ever showing a placeholder image as if it were
    /// real data.
    ///
    /// Alpha scaling: PS2 GS alpha is a 7-bit channel (0...0x80 represents
    /// 0.0...1.0 in the hardware's own blending equations, not the 8-bit
    /// 0...255 a `CGImage` expects), real, standard, publicly documented
    /// PS2 hardware behavior, not something reverse-engineered from these
    /// files specifically. Values are doubled and clamped to convert.
    var cgImage: CGImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        var scaled = rgba
        for i in stride(from: 3, to: scaled.count, by: 4) {
            scaled[i] = UInt8(min(255, Int(scaled[i]) * 2))
        }
        guard let provider = CGDataProvider(data: Data(scaled) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
