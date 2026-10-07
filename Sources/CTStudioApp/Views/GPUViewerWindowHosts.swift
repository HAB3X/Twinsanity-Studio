import SwiftUI
import CTModels

/// Hosts for the three GPU-heavy viewers (Model/Collision/Level), each
/// backed by a real `Window` scene (see `CTStudioApp`) instead of a
/// `.sheet()`. This is a direct response to the blank-viewport
/// investigation: every Swift-side diagnostic (GPU upload, drawable size,
/// `draw(in:)` actually presenting a committed frame, vertex/texture alpha)
/// came back healthy, which narrows the remaining suspects to something in
/// how macOS composites an `MTKView`'s `CAMetalLayer` specifically within a
/// `.sheet()`'s window, a real, if unconfirmed, class of quirk. A `Window`
/// scene is a completely different AppKit window-hosting path, so this
/// sidesteps that whole class of bug if that's what this is, rather than
/// adding another layer of guesswork on top of the existing diagnostics.
///
/// `workspace`'s existing `modelViewerAsset`/`collisionViewerMesh`/
/// `levelViewerContext` stay the single source of truth exactly as they
/// were for the `.sheet()` versions, every call site that sets them
/// (`ModelsHubView`, `SidebarView`, `RelationalChainView`, ...) is
/// unchanged; only `ContentView` (which already centrally coordinates every
/// presentation) needed to change, opening the matching `Window` when one
/// of these transitions from `nil` to non-`nil`.
struct ModelViewerWindowHost: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let asset = workspace.modelViewerAsset {
                // Same staleness class this file's `LevelViewerWindowHost`
                // fixes for the identical reason: without `.id(asset.id)`,
                // switching straight from one model to another while this
                // window is already open reuses the existing view instance
                // (same type, same tree position) instead of getting a
                // fresh one, so `ModelViewerWindow`'s `@State private var
                // renderer` -- built once in `.onAppear` -- keeps
                // rendering whatever model was open first.
                ModelViewerWindow(asset: asset)
                    .id(asset.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { workspace.modelViewerAsset = nil }
                        }
                    }
            } else {
                Color.clear
            }
        }
        // Covers both our own Close button (which nils the state directly)
        // and the window's standard red-traffic-light close (which only
        // tears down this view, so this is the one place that can catch
        // that and keep `workspace` in sync either way).
        .onDisappear { workspace.modelViewerAsset = nil }
        .onChange(of: workspace.modelViewerAsset == nil) { _, isNil in
            if isNil { dismissWindow(id: GPUViewerWindowID.model) }
        }
    }
}

struct CollisionViewerWindowHost: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let mesh = workspace.collisionViewerMesh {
                // Same staleness class this file's `LevelViewerWindowHost`
                // fixes for the identical reason -- see that comment.
                CollisionViewerWindow(mesh: mesh)
                    .id(mesh.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { workspace.collisionViewerMesh = nil }
                        }
                    }
            } else {
                Color.clear
            }
        }
        .onDisappear { workspace.collisionViewerMesh = nil }
        .onChange(of: workspace.collisionViewerMesh == nil) { _, isNil in
            if isNil { dismissWindow(id: GPUViewerWindowID.collision) }
        }
    }
}

struct LevelViewerWindowHost: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let context = workspace.levelViewerContext {
                // Real bug this fixes: opening a *second* level while the
                // Chunk Viewer window is already open (e.g. clicking
                // straight from one level's sidebar entry to another,
                // without closing the window first) reassigns
                // `workspace.levelViewerContext` directly -- no nil in
                // between, so `.onDisappear`/`dismissWindow` never fire.
                // Without `.id(context.id)`, SwiftUI sees the *same*
                // `LevelViewerWindow` type at the same position in the tree
                // and treats this as an update to the existing view
                // instance, not a fresh one -- its `@State private var
                // renderer` (built once in `.onAppear`, which only runs on
                // a view's first appearance) keeps whatever was loaded for
                // the *first* level, even though `context` itself (a plain
                // `let`, so its own value is always current) has already
                // moved on to the new level's real data. The sidebar's
                // counts/labels read `context` directly, so they'd show
                // the new level correctly while the actual 3D scene/
                // renderer kept rendering the old one's objects -- exactly
                // the "50/50 chance depending on whether I opened this
                // level fresh or came from another one" a user would
                // experience. `LevelViewerContext.id` is a fresh UUID per
                // construction; keying identity on it forces a genuinely
                // new `LevelViewerWindow` (and a fresh `.onAppear` renderer
                // build) every time the context actually changes.
                LevelViewerWindow(context: context)
                    .id(context.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { workspace.levelViewerContext = nil }
                        }
                    }
            } else {
                Color.clear
            }
        }
        .onDisappear { workspace.levelViewerContext = nil }
        .onChange(of: workspace.levelViewerContext == nil) { _, isNil in
            if isNil { dismissWindow(id: GPUViewerWindowID.level) }
        }
    }
}

enum GPUViewerWindowID {
    static let model = "model-viewer"
    static let collision = "collision-viewer"
    static let level = "level-viewer"
}
