import SwiftUI
import CTModels

/// The center panel: dispatches to a payload-specific inspector, or a plain
/// hex/metadata view for records this package hasn't modeled yet.
struct InspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode?
    @State private var showComposite = false
    /// Cached, not recomputed in `body`: `resolveComposite` mints a fresh
    /// `ResolvedModelAsset` (fresh `UUID`, by design, see that type's own
    /// doc comment) on every call, and `body` re-evaluates on *any*
    /// `@Published` change anywhere in `workspace` (this view holds it as
    /// an `@EnvironmentObject`), not just when `node` changes. Computing
    /// this inline in `compositeContent` used to hand `CompositePreviewView`
    /// a new asset identity on every unrelated workspace update, which
    /// tore down and rebuilt its GPU renderer in a loop for as long as the
    /// composite toggle was on, expensive on its own, and (observed
    /// directly, via the diagnostic logging added for the blank-viewport
    /// investigation) severe enough to visibly interfere with a
    /// `ModelViewerWindow` sheet open at the same time.
    @State private var resolvedComposite: ResolvedModelAsset?
    /// "Memory-Mapped Hex Engine" (roadmap 5.2): the docked `HexQuickView`
    /// split pane's toggle. Available for every node (unlike the composite
    /// toggle, which only some payload kinds support), raw bytes exist for
    /// any record.
    @State private var showHexQuickView = false
    /// Cached the same way `resolvedComposite` is (see that property's own
    /// doc comment): `workspace.rawBytes(for:)` copies this node's full
    /// byte range, and recomputing it inline in `body` would re-copy on
    /// every unrelated `@Published` change anywhere in `workspace`, not
    /// just when the selected node or the toggle actually changes.
    @State private var hexQuickViewBytes = Data()
    /// "IDEditor" (generic, any record type), see `IDEditorSheet`'s own
    /// doc comment.
    @State private var isChangingID = false

    var body: some View {
        Group {
            if let node {
                HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ExperimentalFieldsWarningView()
                        HStack {
                            header(for: node)
                            Spacer()
                            if workspace.canReplaceDiscFile(node) {
                                Button {
                                    replaceDiscFile(node)
                                } label: {
                                    Label("Replace in Disc Image…", systemImage: "opticaldiscdrive")
                                }
                                .help("Saves a new .iso with this file replaced. Doesn't modify the mounted image.")
                            }
                            Toggle(isOn: $showHexQuickView) {
                                Label("Hex Quick View", systemImage: "number.square")
                            }
                            .toggleStyle(.button)
                            .help("Shows this record's raw bytes read-only; edit via \"Open Full Hex Editor…\" inside it.")
                            Button {
                                isChangingID = true
                            } label: {
                                Label("Change ID…", systemImage: "number")
                            }
                            .disabled(!workspace.canSaveEdits(for: node))
                            .help("Reassigns this record's ID within its containing section.")
                        }
                        if Self.isCompositeEligible(node.payload) {
                            Toggle(isOn: $showComposite) {
                                Label("View Parent / Composite", systemImage: "arrow.triangle.branch")
                            }
                            .toggleStyle(.switch)
                            RelationalChainView(node: node)
                        }
                        Divider()
                        if showComposite, Self.isCompositeEligible(node.payload) {
                            compositeContent
                        } else {
                            // Real bug fix: without an identity tied to
                            // `node.id`, selecting a second node that hits
                            // the *same* switch case (e.g. Animation ->
                            // Animation) reuses the same view instance , 
                            // any `@State` an inspector seeded once from
                            // its own `init` (several do: `working` in
                            // `AnimationInspectorView`/`SkeletonInspectorView`,
                            // `selectedMip`/`upscaledTexture` in
                            // `TextureInspectorView`) silently kept showing
                            // the *first* node's data. Concretely: this let
                            // "Save" write one Animation/Skeleton record's
                            // bytes into a different, currently-selected
                            // one. One `.id()` here fixes it for every
                            // case, present and future, rather than
                            // patching each inspector's own state reset
                            // individually.
                            Group {
                                switch node.payload {
                            case .texture(let texture):
                                TextureInspectorView(node: node, texture: texture)
                            case .mesh(let mesh):
                                MeshInspectorView(node: node, mesh: mesh)
                            case .rigidModel(let info):
                                RigidModelInspectorView(node: node, info: info)
                            case .material(let material):
                                MaterialInspectorView(node: node, material: material)
                            case .skeleton(let skeleton):
                                SkeletonInspectorView(node: node, skeleton: skeleton)
                            case .animation(let animation):
                                AnimationInspectorView(node: node, animation: animation)
                            case .position(let position):
                                PositionInspectorView(node: node, position: position)
                            case .instance(let instance):
                                InstanceInspectorView(node: node, instance: instance)
                            case .trigger(let trigger):
                                TriggerInspectorView(node: node, trigger: trigger)
                            case .camera(let camera):
                                CameraInspectorView(node: node, camera: camera)
                            case .collision(let mesh):
                                CollisionInspectorView(node: node, mesh: mesh)
                            case .scenery(let scenery):
                                SceneryInspectorView(node: node, scenery: scenery)
                            case .dynamicScenery(let dynamicScenery):
                                DynamicSceneryInspectorView(scenery: dynamicScenery)
                            case .soundEffect(let sound):
                                SoundEffectInspectorView(node: node, displayName: node.displayName, sound: sound)
                            case .gameObject(let gameObject):
                                GameObjectInspectorView(node: node, gameObject: gameObject)
                            case .chunkLinks(let chunkLinks):
                                ChunkLinksInspectorView(node: node, chunkLinks: chunkLinks)
                            case .aiPosition(let marker):
                                AIPositionInspectorView(node: node, marker: marker)
                            case .aiPath(let path):
                                AIPathInspectorView(node: node, path: path)
                            case .lodModel(let lodModel):
                                LodModelInspectorView(node: node, lodModel: lodModel)
                            case .collisionSurface(let surface):
                                CollisionSurfaceInspectorView(node: node, surface: surface)
                            case .skydome(let skydome):
                                SkydomeInspectorView(node: node, skydome: skydome)
                            case .path(let path):
                                PathInspectorView(node: node, path: path)
                            case .particleData(let particleData):
                                ParticleDataInspectorView(node: node, particleData: particleData)
                            case .script(let script):
                                ScriptInspectorView(node: node, script: script)
                            case .instanceTemplate(let template):
                                InstanceTemplateInspectorView(node: node, template: template)
                            case .instanceTemplateDemo(let template):
                                InstanceTemplateDemoInspectorView(node: node, template: template)
                            case .soundEffectX, .instanceDemo, .instanceMB,
                                 .xboxModel, .xboxSkin, .xboxBlendSkin, .customAgent:
                                // Real, decoded models (see `WorldPlacementAssets.swift`/
                                // `SoundEffectAsset.swift`/`XboxMeshAssets.swift`'s own doc
                                // comments), no dedicated editor UI yet, so these fall back
                                // to the same raw/hex browsing every other record has, rather
                                // than blocking on building bespoke inspector views for
                                // formats this rare.
                                RawInspectorView(node: node)
                            case .raw, .none:
                                RawInspectorView(node: node)
                            }
                            }
                            .id(node.id)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: node.id) { _, _ in
                    // Lazy load (matches the `SceneryLoadCache` posture
                    // elsewhere in this app): a node selection alone used to
                    // eagerly call the expensive `resolveComposite` here , 
                    // rebuilding the whole file's Graphics/Code index and
                    // resolving full geometry/textures, for *every*
                    // composite-eligible node browsed in the sidebar, even
                    // though the result is only ever shown after the user
                    // explicitly flips "View Parent / Composite" on. Just
                    // drop the stale value on selection change; the actual
                    // resolve now only happens in the `showComposite`
                    // `onChange` below, when a view that needs it
                    // (`compositeContent`/`CompositePreviewView`) is about
                    // to actually appear.
                    showComposite = false
                    resolvedComposite = nil
                    updateHexQuickViewBytes(for: node)
                }
                .onChange(of: showComposite) { _, isOn in
                    if isOn { updateResolvedComposite(for: node) }
                }
                .onChange(of: showHexQuickView) { _, isShown in
                    if isShown { updateHexQuickViewBytes(for: node) }
                }
                .onAppear {
                    if showComposite { updateResolvedComposite(for: node) }
                    updateHexQuickViewBytes(for: node)
                }
                if showHexQuickView {
                    HexQuickView(bytes: hexQuickViewBytes) { workspace.hexViewerNode = node }
                        .frame(minWidth: 260, idealWidth: 320)
                }
                }
                .sheet(isPresented: $isChangingID) {
                    IDEditorSheet(node: node)
                }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.left",
                    description: Text("Select a chunk, texture, model, or animation from the sidebar.")
                )
            }
        }
    }

    /// Cheap payload-kind check for whether the toggle should even appear , 
    /// deliberately *not* calling `resolveComposite` here, since that walks
    /// and rebuilds the whole file's Graphics/Code index and this runs on
    /// every render of every selected node, composite-eligible or not.
    private static func isCompositeEligible(_ payload: ChunkPayload?) -> Bool {
        switch payload {
        case .texture, .mesh, .material, .animation, .rigidModel, .skeleton: return true
        case .position, .instance, .trigger, .camera, .collision, .scenery, .dynamicScenery, .soundEffect, .soundEffectX, .gameObject, .chunkLinks, .aiPosition, .aiPath, .lodModel, .collisionSurface, .skydome, .path, .particleData, .script, .raw, .instanceTemplate, .instanceTemplateDemo, .instanceDemo, .instanceMB, .xboxModel, .xboxSkin, .xboxBlendSkin, .customAgent, .none: return false
        }
    }

    /// Only actually calls the expensive `resolveComposite` (rebuilds the
    /// whole file's Graphics/Code index) for payload kinds the composite
    /// toggle can even apply to, same guard `isCompositeEligible` already
    /// uses for whether to show the toggle at all, now also covering
    /// whether to eagerly resolve it.
    private func updateResolvedComposite(for node: ChunkNode) {
        resolvedComposite = Self.isCompositeEligible(node.payload) ? workspace.resolveComposite(for: node) : nil
    }

    /// Only actually copies bytes (`workspace.rawBytes(for:)`) while the
    /// `HexQuickView` pane is on screen, same "don't do the expensive part
    /// unless it's actually showing" posture as `updateResolvedComposite`.
    private func updateHexQuickViewBytes(for node: ChunkNode) {
        hexQuickViewBytes = showHexQuickView ? (workspace.rawBytes(for: node) ?? Data()) : Data()
    }

    /// "ISO/ROM Rebuild" (roadmap 7): pick a replacement file from disk,
    /// rebuild the disc image with it in place of `node`'s real contents
    /// (`WorkspaceViewModel.replacingDiscImage`), then save the complete
    /// new `.iso`. The originally-mounted image on disk is never touched , 
    /// every step here works on in-memory copies until the final save.
    private func replaceDiscFile(_ node: ChunkNode) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.message = "Choose the replacement file for \(node.displayName)."
        guard openPanel.runModal() == .OK, let sourceURL = openPanel.url else { return }
        guard let destinationURL = ExportPanel.chooseSaveLocation(
            suggestedName: "modified.iso",
            message: "Save the rebuilt disc image with \(node.displayName) replaced. The originally mounted image is not modified."
        ) else { return }
        // Both the replacement file's own read and the re-read + rebuild
        // (`replacingDiscImage`) and the final write can each touch a disc
        // image hundreds of MB to several GB, same "keep large data work
        // off the main actor" discipline as every other save path in this
        // app (`writeDataAsync` itself, plus the `isSaving` toggle it
        // drives, which the toolbar's global spinner already reads). Real
        // bug this fixes: the replacement file's own read used to run
        // synchronously on the main actor before this Task even started,
        // freezing the whole UI for however long that read took.
        Task {
            let readTask = Task.detached(priority: .userInitiated) {
                try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            }
            guard let newData = try? await readTask.value else {
                workspace.lastError = "Couldn't read \(sourceURL.lastPathComponent)."
                return
            }
            guard let newImage = await workspace.replacingDiscImage(afterReplacing: node, with: newData) else { return }
            do {
                try await workspace.writeDataAsync(newImage, to: destinationURL)
                workspace.statusMessage = "Saved rebuilt disc image to \(destinationURL.lastPathComponent) with \(node.displayName) replaced."
            } catch {
                workspace.lastError = "Couldn't save the rebuilt disc image: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private var compositeContent: some View {
        if let resolvedComposite {
            CompositePreviewView(asset: resolvedComposite)
        } else {
            ContentUnavailableView(
                "No Parent Found",
                systemImage: "questionmark.circle",
                description: Text("Nothing in this file currently references this record. It may be orphaned. Check the Scrapped Content Scanner.")
            )
        }
    }

    private func header(for node: ChunkNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(node.displayName)
                .font(.title2.bold())
            HStack(spacing: 12) {
                Label(node.sectionType.rawValue, systemImage: "tag")
                Label("\(node.byteSize) bytes", systemImage: "shippingbox")
                Label("offset 0x\(String(node.fileOffset, radix: 16))", systemImage: "number")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct RigidModelInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let info: RigidModelInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                LabeledContent("Header", value: "0x\(String(info.header, radix: 16))")
                LabeledContent("Mesh ID", value: "\(info.meshID)")
                LabeledContent("Material Count", value: "\(info.materialIDs.count)")
                if !info.materialIDs.isEmpty {
                    DisclosureGroup("Material IDs") {
                        ForEach(info.materialIDs, id: \.self) { id in
                            Text("#\(id)").font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Button {
                workspace.openModelViewer(for: node)
            } label: {
                Label("Open in Model Viewer", systemImage: "cube.fill")
            }
        }
    }
}

/// "Comprehensive Instance Population" (Part 4B): a read-only view of the
/// `GameObject` record an `Instance.objectID` resolves through on its way
/// to real geometry, see `GameObjectInfo`'s own doc comment for why only
/// the `OGIs` list is decoded (name + OGI links only, not the script
/// bytecode tail this codebase doesn't decode anywhere else either).
struct GameObjectInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode
    let gameObject: GameObjectInfo
    @State private var showEditor = false

    var body: some View {
        Form {
            Section {
                Button("Edit GameObject…") { showEditor = true }
                    .disabled(!workspace.canSaveEdits(for: node))
            }
            LabeledContent("Name", value: gameObject.name)
            LabeledContent("Object ID", value: "\(gameObject.id)")
            if let type = gameObject.resolvedObjectType {
                LabeledContent("Object Type", value: String(describing: type))
            }
            if let mobile = gameObject.resolvedMobileType {
                LabeledContent("Mobile Type", value: String(describing: mobile))
            }
            LabeledContent("Script Commands", value: "\(gameObject.scriptCommands.count)")
            if !gameObject.ogiIDs.isEmpty {
                DisclosureGroup("Graphics Info Links (\(gameObject.ogiIDs.count))") {
                    ForEach(Array(gameObject.ogiIDs.enumerated()), id: \.offset) { index, ogiID in
                        LabeledContent("[\(index)]", value: ogiID == 65535 ? "none" : "#\(ogiID)")
                    }
                }
            }
            if gameObject.instanceProperties != nil {
                LabeledContent("Instance Properties", value: "present")
            }
            if let linked = gameObject.linkedIDs {
                let counts: [Int] = [linked.objects.count, linked.ogis.count, linked.anims.count, linked.codeModels.count, linked.scripts.count, linked.unk.count, linked.sounds.count]
                let total: Int = counts.reduce(0, +)
                LabeledContent("Linked Resource IDs", value: "\(total) total")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showEditor) {
            GameObjectEditorSheet(node: node, gameObject: gameObject)
        }
    }
}

struct RawInspectorView: View {
    let node: ChunkNode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if node.children.isEmpty {
                Label("Not decoded by this build. Browsable as raw bytes only.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(node.children.count) child record(s). Select one to inspect it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
