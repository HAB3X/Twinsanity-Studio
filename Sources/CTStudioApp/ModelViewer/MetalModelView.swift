import SwiftUI
import MetalKit
import simd
import CTModels

/// Common orbit-camera surface both `ModelViewerRenderer` and
/// `LevelViewerRenderer` implement, so `InteractiveMTKView`/`MetalModelView`
/// can drive either without knowing which one they're holding.
protocol OrbitCameraRenderer: AnyObject, MTKViewDelegate {
    var device: MTLDevice { get }
    var yaw: Float { get set }
    var pitch: Float { get set }
    var distanceMultiplier: Float { get set }
    /// "F to Focus/Frame" (QoL sweep): resets the orbit angle/distance to a
    /// sensible default. A plain reset, not a per-object fitted bounding
    /// calculation, `LevelViewerRenderer` gets the "orbit around whatever's
    /// selected" part of "focus on selection" for free from its own
    /// `orbitTarget` (see that type), since the look-at point already
    /// follows the current selection; this just un-sticks a wildly zoomed
    /// in/out or spun-around camera back to a readable framing.
    func resetView()
}

extension ModelViewerRenderer: OrbitCameraRenderer {}
extension LevelViewerRenderer: OrbitCameraRenderer {}

/// "The Forge Palette" (Part 4C): implemented only by `LevelViewerRenderer`
///, a `mouseDown` while `pendingPlacementObjectID` is armed places a new
/// object instead of orbiting or picking. Checked first in
/// `InteractiveMTKView.mouseDown`, ahead of the gizmo-grab/pick checks,
/// since placement mode takes over the click entirely.
protocol PlacementInteractiveRenderer: OrbitCameraRenderer {
    var pendingPlacementObjectID: UInt16? { get }
    @discardableResult
    func placeObject(at screenPoint: CGPoint, viewSize: CGSize) -> Int?
    /// Scenery's own arm-then-click placement, same shape as
    /// `pendingPlacementObjectID`/`placeObject` above, see
    /// `LevelViewerRenderer.PendingSceneryPlacement`'s own doc comment for
    /// why it needs a richer payload than a plain ID.
    var pendingPlacementScenery: LevelViewerRenderer.PendingSceneryPlacement? { get }
    @discardableResult
    func placeScenery(at screenPoint: CGPoint, viewSize: CGSize) -> Int?
    /// "Spawn Interactive Cortex (Prop)", arm-then-click, same shape as
    /// `pendingPlacementScenery`/`placeScenery` above.
    var pendingPlacementPropSkin: LevelViewerRenderer.PendingPropSkinPlacement? { get }
    @discardableResult
    func placePropSkin(at screenPoint: CGPoint, viewSize: CGSize) -> Int?
}

extension LevelViewerRenderer: PlacementInteractiveRenderer {}

/// "Free Camera System in Chunk Editor": implemented only by
/// `LevelViewerRenderer`, the single-model viewer has no use for a
/// flying camera over one small asset. Checked via `as?` the same way
/// `PlacementInteractiveRenderer` is.
protocol FreeCameraRenderer: OrbitCameraRenderer {
    var isFreeCameraMode: Bool { get set }
    var freeCameraSpeed: Float { get set }
    var freeCameraInputDirection: SIMD3<Float> { get set }
    func rotateFreeCameraLook(yawDelta: Float, pitchDelta: Float)
}

extension LevelViewerRenderer: FreeCameraRenderer {}

/// "Top-Down/Minimap", implemented only by `LevelViewerRenderer`, same
/// reasoning as `FreeCameraRenderer` above. Checked via `as?` from
/// `keyDown` to drive the `T` hotkey without `MetalModelView` needing to
/// know which concrete renderer type it's holding.
protocol TopDownCameraRenderer: OrbitCameraRenderer {
    var isTopDownMode: Bool { get set }
}

extension LevelViewerRenderer: TopDownCameraRenderer {}

/// "AI Path Connector Visualization + In-Viewport Endpoint Picking":
/// implemented only by `LevelViewerRenderer`, same "armed mode takes over
/// the click" shape as `PlacementInteractiveRenderer` above, checked right
/// alongside it in `InteractiveMTKView.mouseDown`.
protocol AIPathEndpointPickingRenderer: OrbitCameraRenderer {
    var pendingAIPathEndpointPick: Bool { get set }
    @discardableResult
    func pickAIPathEndpoint(at point: CGPoint, viewSize: CGSize) -> UInt32?
}

extension LevelViewerRenderer: AIPathEndpointPickingRenderer {}

/// `MTKView` subclass that turns mouse drag into orbit and scroll into zoom.
/// Kept as a thin, dumb input adapter, all the actual camera math lives on
/// the renderer, this just forwards deltas to it.
///
/// Performance fix (audit): input handlers below used to call
/// `needsDisplay = true` after every mutation, a holdover from an earlier
/// on-demand-rendering configuration. `MetalModelView.makeNSView` now runs
/// this view continuously (`isPaused = false`, `enableSetNeedsDisplay =
/// false`, see its own comment for why), in that mode MTKView redraws
/// every frame off its own internal timer and never consults
/// `needsDisplay`, so those calls were confirmed-dead invalidation
/// bookkeeping with no effect on what actually got drawn. Removed rather
/// than left in, since a future reader could otherwise mistake them for
/// live behavior.
final class InteractiveMTKView: MTKView {
    var renderer: OrbitCameraRenderer?
    /// Fired once when a gizmo-arrow drag ends, lets the SwiftUI side
    /// (whose coordinate nudge fields have no other way to observe a plain,
    /// non-`ObservableObject` renderer mutated straight from AppKit mouse
    /// events) resync its display *after* the drag, rather than needing
    /// per-pixel observation of a hot interactive loop.
    var onGizmoDragEnded: (() -> Void)?
    /// Fired once when a gizmo-arrow drag *starts*, lets the SwiftUI side
    /// snapshot the pre-drag position for an Undo step covering the whole
    /// gesture (see `LevelViewerWindow`), rather than one Undo step per
    /// mouse-moved event.
    var onGizmoDragStarted: (() -> Void)?
    /// Fired when the W/E/R hotkeys change `gizmoMode`, the SwiftUI-side
    /// mode picker has no other way to notice a change AppKit's `keyDown`
    /// made directly on the (plain, non-`ObservableObject`) renderer.
    var onGizmoModeChanged: (() -> Void)?
    /// Fired when the T hotkey toggles `TopDownCameraRenderer.isTopDownMode`
    ///, same reasoning as `onGizmoModeChanged`: the SwiftUI-side checkbox
    /// binding has no other way to notice a change `keyDown` made directly
    /// on the renderer. Carries the new value so the SwiftUI side can just
    /// assign it, rather than reading back through the renderer.
    var onTopDownModeChanged: ((Bool) -> Void)?
    /// "Click any rendered element to select it" (Level Editor overhaul):
    /// fired with the picked object's index when a `mouseDown` didn't grab
    /// a gizmo handle but did land on/near a visible object, see
    /// `GizmoInteractiveRenderer.pickObject`.
    var onObjectPicked: ((Int) -> Void)?
    /// "The Forge Palette" (Part 4C): fired with the newly spawned object's
    /// index right after a placement-mode click actually placed something
    ///, lets the SwiftUI side select it and register the matching Undo
    /// step, same reasoning as `onObjectPicked`.
    var onObjectPlaced: ((Int) -> Void)?
    /// Scenery's own arm-then-click placement (see
    /// `LevelViewerRenderer.pendingPlacementScenery`'s doc comment), same
    /// contract as `onObjectPlaced`, fired instead of it when the pending
    /// placement was a scenery item rather than a Forge Palette object.
    var onSceneryPlaced: ((Int) -> Void)?
    /// "Spawn Interactive Cortex (Prop)", arm-then-click (see
    /// `LevelViewerRenderer.pendingPlacementPropSkin`'s doc comment) , 
    /// same contract as `onObjectPlaced`/`onSceneryPlaced`.
    var onPropSkinPlaced: ((Int) -> Void)?
    /// "AI Path Connector Visualization + In-Viewport Endpoint Picking":
    /// fired with the clicked waypoint's real AIPosition ID when
    /// `AIPathEndpointPickingRenderer.pendingAIPathEndpointPick` was armed
    ///, same "arm, click, callback" contract as `onObjectPlaced`.
    var onAIPathEndpointPicked: ((UInt32) -> Void)?
    /// "Double-Click to Focus": fired with the picked object's index when a
    /// `mouseDown` with `clickCount >= 2` lands on/near a visible object , 
    /// checked instead of (not in addition to) `onObjectPicked` for that
    /// click, so a double-click both selects and pulls the camera in
    /// close, rather than firing the plain-select callback first and
    /// fighting over which one "wins."
    var onObjectDoubleClicked: ((Int) -> Void)?
    /// "Esc to Deselect": fired when Escape goes down, lets the SwiftUI
    /// side clear the current selection (and anything else that reads as
    /// "in progress," like an armed placement) the same way clicking empty
    /// space already can, just reachable without aiming at empty viewport.
    var onEscapePressed: (() -> Void)?
    /// "Numbered Hotbar (1-9)": fired with the pressed slot number (1-9)
    /// when a digit key is pressed outside Free Camera mode, lets the
    /// SwiftUI side arm whatever's pinned to that slot for placement, the
    /// same as clicking it in the Forge Palette.
    var onHotbarSlotPressed: ((Int) -> Void)?
    /// "Radial Marking Menu (hold Q)": fired once when Q goes down (view-
    /// point coordinates, same space `mouseMoved`/gizmo hit-testing use) , 
    /// the SwiftUI side owns the actual menu geometry/actions and shows an
    /// overlay centered there.
    var onMarkingMenuBegan: ((CGPoint) -> Void)?
    /// Fired on every mouse-moved event while the marking menu is held , 
    /// the SwiftUI side re-derives which slice is under the cursor from
    /// this and the point `onMarkingMenuBegan` reported.
    var onMarkingMenuMoved: ((CGPoint) -> Void)?
    /// Fired when Q is released, the SwiftUI side executes whatever slice
    /// was last highlighted (if any) and dismisses the overlay.
    var onMarkingMenuEnded: (() -> Void)?
    /// True for the duration of a held Q press, while active, `mouseMoved`
    /// drives the marking menu instead of the normal hover-highlight, and
    /// `mouseDown` is swallowed so a stray click while choosing a slice
    /// can't also grab a gizmo handle or pick an object underneath it.
    private var isMarkingMenuActive = false
    /// Updated on every `mouseMoved`/`mouseDown`/`mouseDragged`, `keyDown`
    /// has no mouse-position of its own, so this is what anchors the
    /// marking menu to wherever the cursor actually is when Q goes down.
    private var lastMouseLocation: CGPoint = .zero
    /// Real, reported complaint: right-click used to commit-and-close on
    /// `rightMouseUp` unconditionally, which meant the menu was only ever
    /// visible for as long as the button stayed physically held down , 
    /// "I don't want to have to hold it... I want it to stay up until I
    /// click elsewhere." `rightMouseDown` stores the press location here;
    /// `rightMouseUp` only commits immediately if the cursor actually
    /// travelled past `markingMenuClickDragThreshold` since then (the
    /// existing power-user "press, drag to a slice, release" gesture stays
    /// exactly as fast as before). A quick click with no real drag instead
    /// leaves the menu open, `mouseDown`/`rightMouseDown` then treat the
    /// *next* click as the commit, whether it lands on a slice or in the
    /// dead zone ("click elsewhere" = a real, existing no-op via
    /// `executeHighlightedMarkingMenuAction`'s own dead-zone guard).
    private var markingMenuPressLocation: CGPoint?
    private static let markingMenuClickDragThreshold: Double = 6

    /// Non-nil for the duration of a drag that grabbed a gizmo arrow on
    /// `mouseDown`, while set, `mouseDragged` moves the selected object
    /// along that axis instead of orbiting the camera.
    private var draggingGizmoAxis: GizmoAxis?
    /// "Broken Gizmos" fix: the cursor's own view-point location as of the
    /// last gizmo-drag event. `NSEvent.deltaX`/`deltaY` (used directly
    /// before this fix) are the *raw, unaccelerated hardware* mouse
    /// deltas, under macOS's pointer-acceleration curve (or on a
    /// trackpad) those numbers don't match how far the cursor actually
    /// moved on screen, so a gizmo driven straight from them visibly
    /// drifts out of alignment with the cursor mid-drag, exactly the
    /// "not smooth, not perfectly aligned with the camera" symptom. This
    /// tracks the real cursor position instead, `convert(event.
    /// locationInWindow, from: nil)`, the same call `mouseDown` already
    /// uses for its (already-correct) gizmo hit test, and diffs
    /// consecutive events, so the gizmo tracks the cursor 1:1 regardless
    /// of acceleration/input device.
    private var lastGizmoDragLocation: CGPoint?

    /// "Free Camera System": currently-held WASD/EQ keys, tracked across
    /// `keyDown`/`keyUp` rather than acted on per-keystroke, so holding a
    /// key produces continuous movement (integrated once per frame in
    /// the renderer's own `draw(in:)`) instead of one discrete nudge per
    /// key-repeat event.
    private var heldMovementKeys: Set<String> = []

    override var acceptsFirstResponder: Bool { true }

    /// "Hover highlight" (Level Editor overhaul, Phase 3): a plain
    /// `NSView` gets no `mouseMoved` events at all until something asks
    /// its window to deliver them, `acceptsMouseMovedEvents` alone isn't
    /// enough either without a tracking area, since AppKit only routes
    /// `mouseMoved` to views actually inside one.
    private var hoverTrackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    /// See `GizmoInteractiveRenderer.hoverObject`'s doc comment, this is
    /// purely a visual side effect on the renderer, no SwiftUI callback
    /// needed the way `onObjectPicked`/`onObjectPlaced` are for clicks,
    /// since nothing outside the 3D view needs to know what's hovered.
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouseLocation = point
        if isMarkingMenuActive {
            onMarkingMenuMoved?(point)
            return
        }
        guard let gizmoRenderer = renderer as? GizmoInteractiveRenderer else {
            super.mouseMoved(with: event)
            return
        }
        gizmoRenderer.hoverObject(at: point, viewSize: bounds.size)
    }

    /// Clicking away from this view (or the window losing key focus)
    /// doesn't reliably deliver `keyUp` for whatever WASD/EQ keys were
    /// down at the time, without this, a held key could get "stuck,"
    /// leaving the free camera drifting indefinitely after focus moves
    /// elsewhere.
    override func resignFirstResponder() -> Bool {
        if !heldMovementKeys.isEmpty {
            heldMovementKeys.removeAll()
            updateFreeCameraInputDirection()
        }
        // "Radial Marking Menu": losing focus mid-hold shouldn't leave the
        // overlay stuck open forever with no key left to release (same
        // reasoning as the held-movement-keys reset above) -- same
        // "commit whatever's currently highlighted" path a normal Q
        // release takes, since there's no dedicated "cancel without
        // acting" signal and this is a rare edge case (losing focus while
        // mid-gesture), not the common dismissal path.
        if isMarkingMenuActive {
            isMarkingMenuActive = false
            markingMenuPressLocation = nil
            onMarkingMenuEnded?()
        }
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        // "Radial Marking Menu": once it's open, whether via a held Q or a
        // right-click that hasn't committed yet (see
        // `markingMenuPressLocation`'s doc comment), a left-click doesn't
        // fall through to normal gizmo-grab/picking underneath the overlay.
        // If the menu is just pinned open waiting for a second click, this
        // *is* that click: commit whatever's currently highlighted (a slice,
        // or nothing at all in the dead zone, "click elsewhere" to
        // dismiss) and close it, the same outcome a drag-then-release
        // already produces.
        if isMarkingMenuActive {
            isMarkingMenuActive = false
            markingMenuPressLocation = nil
            onMarkingMenuEnded?()
            return
        }
        draggingGizmoAxis = nil
        let point = convert(event.locationInWindow, from: nil)
        lastMouseLocation = point

        // "The Forge Palette" / "Scenery placement, arm-then-click": an
        // armed placement (object or scenery) takes over the click entirely
        //, no gizmo grab, no orbit, no picking, just "put the new thing
        // here."
        if let placementRenderer = renderer as? PlacementInteractiveRenderer {
            if placementRenderer.pendingPlacementObjectID != nil {
                if let newIndex = placementRenderer.placeObject(at: point, viewSize: bounds.size) {
                    onObjectPlaced?(newIndex)
                }
                return
            }
            if placementRenderer.pendingPlacementScenery != nil {
                if let newIndex = placementRenderer.placeScenery(at: point, viewSize: bounds.size) {
                    onSceneryPlaced?(newIndex)
                }
                return
            }
            if placementRenderer.pendingPlacementPropSkin != nil {
                if let newIndex = placementRenderer.placePropSkin(at: point, viewSize: bounds.size) {
                    onPropSkinPlaced?(newIndex)
                }
                return
            }
        }

        // "AI Path Connector Visualization + In-Viewport Endpoint Picking":
        // same "armed mode takes over the click" shape as the placement
        // check above, a miss (clicked empty space or a non-waypoint
        // object) still consumes the click and stays armed, rather than
        // falling through to normal picking and silently selecting
        // whatever was actually under the cursor.
        if let endpointPickingRenderer = renderer as? AIPathEndpointPickingRenderer, endpointPickingRenderer.pendingAIPathEndpointPick {
            if let pickedID = endpointPickingRenderer.pickAIPathEndpoint(at: point, viewSize: bounds.size) {
                onAIPathEndpointPicked?(pickedID)
            }
            return
        }

        guard let gizmoRenderer = renderer as? GizmoInteractiveRenderer else { return }
        // Regression fix: a double-click's second click very often lands
        // right on the selected object's own gizmo (its handles originate
        // at the object's screen position), grabbing that handle here
        // used to start a drag instead of ever reaching the double-click
        // branch below, silently defeating "Double-Click to Focus" for
        // exactly the common case of double-clicking near an object's own
        // center. A double-click's intent is unambiguous ("focus on
        // this"), so it skips the gizmo-grab check entirely rather than
        // racing it.
        if event.clickCount < 2 {
            draggingGizmoAxis = gizmoRenderer.gizmoAxis(at: point, viewSize: bounds.size)
            if draggingGizmoAxis != nil {
                lastGizmoDragLocation = point
                onGizmoDragStarted?()
                return
            }
        }
        // No gizmo handle grabbed (or this is a double-click, which never
        // grabs one), try picking whatever's under the click instead, so
        // clicking an object directly selects it even before its own
        // gizmo exists (or for select-only layers like triggers).
        if let picked = gizmoRenderer.pickObject(at: point, viewSize: bounds.size) {
            if event.clickCount >= 2 {
                onObjectDoubleClicked?(picked)
            } else {
                onObjectPicked?(picked)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = draggingGizmoAxis != nil
        draggingGizmoAxis = nil
        lastGizmoDragLocation = nil
        if wasDragging { onGizmoDragEnded?() }
    }

    /// "F to Focus/Frame" plus W/E/R gizmo-mode switching (QoL sweep) , 
    /// the standard 3D-tool convention for translate/rotate/scale. While
    /// the Free Camera is active, WASD/EQ mean movement instead, the two
    /// schemes share letters (W/E already meant translate/rotate mode),
    /// so free-camera mode takes over those keys entirely rather than
    /// trying to make one keystroke serve two conflicting purposes.
    /// "Keyboard nudging" (QoL): Left/Right/Up/Down move the selection
    /// relative to the camera's own current facing, Up/Down along
    /// whichever way the camera is actually looking (flattened to the
    /// ground plane), Left/Right along its perpendicular, via
    /// `GizmoInteractiveRenderer.cameraGroundForward`/`cameraGroundRight`,
    /// so "up" always means "away from me" regardless of how the camera
    /// has orbited. Real, reported complaint about the previous fixed-
    /// world-X/Z scheme: it only felt right at the camera's default
    /// facing and got confusing the moment the camera moved. Holding
    /// Shift swaps Down/Up to move along world Y instead (kept absolute,
    /// not camera-relative, a tilted camera's own "local up" isn't a
    /// meaningful direction for adjusting height), so all three axes stay
    /// keyboard-reachable without a separate mode. Uses `keyCode` (not
    /// `charactersIgnoringModifiers`,
    /// which arrow keys don't map to ordinary characters through), the
    /// standard macOS virtual key codes for the arrow cluster.
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124
    private static let downArrowKeyCode: UInt16 = 125
    private static let upArrowKeyCode: UInt16 = 126
    /// "Esc to Deselect".
    private static let escapeKeyCode: UInt16 = 53

    /// Skipped while the marking menu is mid-hold, that gesture already
    /// has its own dedicated dismissal (releasing Q), and firing a
    /// deselect out from under it would be a confusing second thing
    /// happening on the same keystroke.
    private func handleEscapeKeyDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == Self.escapeKeyCode, !isMarkingMenuActive else { return false }
        onEscapePressed?()
        return true
    }

    private func handleArrowKeyNudge(_ event: NSEvent) -> Bool {
        guard let gizmoRenderer = renderer as? GizmoInteractiveRenderer else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let forward = gizmoRenderer.cameraGroundForward()
        let right = gizmoRenderer.cameraGroundRight()
        let direction: SIMD3<Float>
        switch event.keyCode {
        case Self.leftArrowKeyCode: direction = -right
        case Self.rightArrowKeyCode: direction = right
        case Self.upArrowKeyCode: direction = shift ? SIMD3(0, 1, 0) : forward
        case Self.downArrowKeyCode: direction = shift ? SIMD3(0, -1, 0) : -forward
        default: return false
        }
        // Reuses the exact same "snapshot before, register undo after"
        // pair the SwiftUI side already wires up for gizmo drags, see
        // `LevelViewerWindow`'s `onGizmoDragStarted`/`onGizmoDragEnded`,
        // which read generically off whatever's currently selected rather
        // than anything drag-specific, so they work unchanged here too.
        onGizmoDragStarted?()
        gizmoRenderer.nudgeSelectedPosition(worldDirection: direction)
        onGizmoDragEnded?()
        return true
    }

    /// "Numbered Hotbar (1-9)": digit keys arm whatever's pinned to that
    /// slot, same as clicking it in the Forge Palette, gated off during
    /// Free Camera flight (no placement UI to arm while flying) and to
    /// levels only (`PlacementInteractiveRenderer`; the standalone model
    /// viewer has no palette/hotbar concept).
    private func handleHotbarKeyPress(_ event: NSEvent) -> Bool {
        guard renderer is PlacementInteractiveRenderer else { return false }
        if let freeCameraRenderer = renderer as? FreeCameraRenderer, freeCameraRenderer.isFreeCameraMode { return false }
        guard let key = event.charactersIgnoringModifiers, key.count == 1, let digit = Int(key), (1...9).contains(digit) else { return false }
        onHotbarSlotPressed?(digit)
        return true
    }

    /// "Radial Marking Menu (hold Q)": gated off during Free Camera flight,
    /// where Q already means descend, the two never conflict since
    /// free-camera mode's own `keyDown` branch (below) returns before this
    /// runs. Repeats are swallowed (the menu is already open, nothing to
    /// re-trigger); `isARepeat` on the very first press is always false so
    /// this still fires normally on a real key-down.
    private func handleMarkingMenuKeyDown(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "q" else { return false }
        if let freeCameraRenderer = renderer as? FreeCameraRenderer, freeCameraRenderer.isFreeCameraMode { return false }
        guard !event.isARepeat else { return true }
        isMarkingMenuActive = true
        onMarkingMenuBegan?(lastMouseLocation)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleEscapeKeyDown(event) { return }
        if handleArrowKeyNudge(event) { return }
        if handleHotbarKeyPress(event) { return }
        if handleMarkingMenuKeyDown(event) { return }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        if let freeCameraRenderer = renderer as? FreeCameraRenderer, freeCameraRenderer.isFreeCameraMode {
            switch key {
            case "w", "a", "s", "d", "e", "q":
                if !event.isARepeat { heldMovementKeys.insert(key) }
                updateFreeCameraInputDirection()
                return
            case "f":
                renderer?.resetView()
                return
            default:
                break
            }
        }

        var changedMode = false
        switch key {
        case "f":
            renderer?.resetView()
        case "w" where renderer is GizmoInteractiveRenderer:
            (renderer as? GizmoInteractiveRenderer)?.gizmoMode = .translate
            changedMode = true
        case "e" where renderer is GizmoInteractiveRenderer:
            (renderer as? GizmoInteractiveRenderer)?.gizmoMode = .rotate
            changedMode = true
        case "r" where renderer is GizmoInteractiveRenderer:
            (renderer as? GizmoInteractiveRenderer)?.gizmoMode = .scale
            changedMode = true
        case "t" where renderer is TopDownCameraRenderer:
            if let topDownRenderer = renderer as? TopDownCameraRenderer {
                topDownRenderer.isTopDownMode.toggle()
                onTopDownModeChanged?(topDownRenderer.isTopDownMode)
            }
        default:
            super.keyDown(with: event)
            return
        }
        if changedMode { onGizmoModeChanged?() }
    }

    override func keyUp(with event: NSEvent) {
        if isMarkingMenuActive, event.charactersIgnoringModifiers?.lowercased() == "q" {
            isMarkingMenuActive = false
            onMarkingMenuEnded?()
            return
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), heldMovementKeys.remove(key) != nil else {
            super.keyUp(with: event)
            return
        }
        updateFreeCameraInputDirection()
    }

    private func updateFreeCameraInputDirection() {
        guard let freeCameraRenderer = renderer as? FreeCameraRenderer else { return }
        var direction = SIMD3<Float>(0, 0, 0)
        if heldMovementKeys.contains("w") { direction.z += 1 }
        if heldMovementKeys.contains("s") { direction.z -= 1 }
        if heldMovementKeys.contains("d") { direction.x += 1 }
        if heldMovementKeys.contains("a") { direction.x -= 1 }
        if heldMovementKeys.contains("e") { direction.y += 1 }
        if heldMovementKeys.contains("q") { direction.y -= 1 }
        freeCameraRenderer.freeCameraInputDirection = direction
    }

    /// Right-click-drag look, the Free Camera's own rotation input,
    /// entirely separate from `mouseDragged`'s left-click orbit/gizmo
    /// handling below (which keeps working unchanged; while free-camera
    /// mode is on, `currentViewProjection` simply ignores the orbit
    /// `yaw`/`pitch` it would otherwise mutate).
    ///
    /// Outside Free Camera mode, right-click has no competing use, so it
    /// opens the same Radial Marking Menu "hold Q" does, same overlay,
    /// same actions, same `executeHighlightedMarkingMenuAction` on
    /// release, just a different way in. Fixes a real reported bug: this
    /// used to fall through to `super.rightMouseDown`/etc, which (this
    /// view sets no `menu`) made right-click a silent no-op, the most
    /// common place a user would go looking for Cut/Copy/Paste/Inspect.
    override func rightMouseDown(with event: NSEvent) {
        guard let freeCameraRenderer = renderer as? FreeCameraRenderer, freeCameraRenderer.isFreeCameraMode else {
            let point = convert(event.locationInWindow, from: nil)
            lastMouseLocation = point
            // A right-click while the menu is already pinned open (see
            // `markingMenuPressLocation`) is the "click elsewhere"/"click a
            // slice" commit, not a request to re-anchor the menu at a new
            // center.
            if isMarkingMenuActive {
                isMarkingMenuActive = false
                markingMenuPressLocation = nil
                onMarkingMenuEnded?()
                return
            }
            isMarkingMenuActive = true
            markingMenuPressLocation = point
            onMarkingMenuBegan?(point)
            return
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let freeCameraRenderer = renderer as? FreeCameraRenderer, freeCameraRenderer.isFreeCameraMode else {
            guard isMarkingMenuActive else { return }
            let point = convert(event.locationInWindow, from: nil)
            lastMouseLocation = point
            onMarkingMenuMoved?(point)
            return
        }
        freeCameraRenderer.rotateFreeCameraLook(yawDelta: Float(event.deltaX) * 0.01, pitchDelta: -Float(event.deltaY) * 0.01)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let freeCameraRenderer = renderer as? FreeCameraRenderer, freeCameraRenderer.isFreeCameraMode else {
            guard isMarkingMenuActive else { return }
            let point = convert(event.locationInWindow, from: nil)
            let travelled = markingMenuPressLocation.map { hypot(Double(point.x - $0.x), Double(point.y - $0.y)) } ?? .infinity
            // A real press-drag-then-release still commits immediately, same
            // as before, only a quick click with no real drag leaves the
            // menu pinned open for a follow-up click (see
            // `markingMenuPressLocation`'s doc comment).
            guard travelled > Self.markingMenuClickDragThreshold else { return }
            isMarkingMenuActive = false
            markingMenuPressLocation = nil
            onMarkingMenuEnded?()
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let renderer else { return }
        if let axis = draggingGizmoAxis, let gizmoRenderer = renderer as? GizmoInteractiveRenderer {
            // See `lastGizmoDragLocation`'s doc comment: real cursor-point
            // deltas, not raw hardware `event.deltaX/deltaY`, sign
            // convention kept identical to what `event.deltaX/deltaY`
            // would have provided (dx positive = right, dy positive =
            // down) so every downstream gizmo-math sign/negation
            // (`axisProjectedWorldDelta`'s `-viewportDelta.dy`, etc.)
            // stays correct unchanged.
            let point = convert(event.locationInWindow, from: nil)
            let previous = lastGizmoDragLocation ?? point
            let viewportDelta = CGVector(dx: point.x - previous.x, dy: previous.y - point.y)
            lastGizmoDragLocation = point
            gizmoRenderer.dragSelectedObject(axis: axis, viewportDelta: viewportDelta, viewSize: bounds.size)
            return
        }
        renderer.yaw += Float(event.deltaX) * 0.01
        renderer.pitch += Float(event.deltaY) * 0.01
    }

    override func scrollWheel(with event: NSEvent) {
        guard let renderer else { return }
        // "Adjustable movement speeds (Scroll Wheel speed adjustment)":
        // while flying, the scroll wheel means "how fast do WASD move me,"
        // not "zoom", there's no orbit distance to zoom while free-camera
        // mode is active anyway.
        if let freeCameraRenderer = renderer as? FreeCameraRenderer, freeCameraRenderer.isFreeCameraMode {
            let delta = Float(event.scrollingDeltaY) * 0.5
            freeCameraRenderer.freeCameraSpeed = max(1, min(500, freeCameraRenderer.freeCameraSpeed - delta))
            return
        }
        let delta = Float(event.scrollingDeltaY) * 0.01
        renderer.distanceMultiplier -= delta
    }
}

struct MetalModelView: NSViewRepresentable {
    let renderer: OrbitCameraRenderer
    var onGizmoDragEnded: (() -> Void)?
    var onGizmoDragStarted: (() -> Void)?
    var onGizmoModeChanged: (() -> Void)?
    var onTopDownModeChanged: ((Bool) -> Void)?
    var onObjectPicked: ((Int) -> Void)?
    var onObjectPlaced: ((Int) -> Void)?
    var onSceneryPlaced: ((Int) -> Void)?
    var onPropSkinPlaced: ((Int) -> Void)?
    var onAIPathEndpointPicked: ((UInt32) -> Void)?
    var onObjectDoubleClicked: ((Int) -> Void)?
    var onEscapePressed: (() -> Void)?
    var onHotbarSlotPressed: ((Int) -> Void)?
    var onMarkingMenuBegan: ((CGPoint) -> Void)?
    var onMarkingMenuMoved: ((CGPoint) -> Void)?
    var onMarkingMenuEnded: (() -> Void)?
    /// "Hold to Move" smoothness fix: hands the just-created view out once
    /// so a caller can temporarily raise `preferredFramesPerSecond` for the
    /// duration of an active continuous-move drag, see
    /// `LevelViewerWindow.beginningContinuousMoveHighFrameRate`'s own doc
    /// comment for why this has to be scoped to that exact window rather
    /// than raising the view's baseline rate globally.
    var onViewReady: ((InteractiveMTKView) -> Void)?

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: renderer.device)
        view.renderer = renderer
        view.onGizmoDragEnded = onGizmoDragEnded
        view.onGizmoDragStarted = onGizmoDragStarted
        view.onGizmoModeChanged = onGizmoModeChanged
        view.onTopDownModeChanged = onTopDownModeChanged
        view.onObjectPicked = onObjectPicked
        view.onObjectPlaced = onObjectPlaced
        view.onSceneryPlaced = onSceneryPlaced
        view.onPropSkinPlaced = onPropSkinPlaced
        view.onAIPathEndpointPicked = onAIPathEndpointPicked
        view.onObjectDoubleClicked = onObjectDoubleClicked
        view.onEscapePressed = onEscapePressed
        view.onHotbarSlotPressed = onHotbarSlotPressed
        view.onMarkingMenuBegan = onMarkingMenuBegan
        view.onMarkingMenuMoved = onMarkingMenuMoved
        view.onMarkingMenuEnded = onMarkingMenuEnded
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0.07, 0.07, 0.09, 1)
        // Continuous, throttled rendering. This was briefly switched to
        // pure on-demand rendering (isPaused = true + enableSetNeedsDisplay,
        // redrawing only on setNeedsDisplay()) to cut idle GPU cost, but
        // that makes the very first frame depend on `needsDisplay = true`
        // landing *after* this view is actually attached to a window with
        // a non-zero drawable size, which isn't guaranteed to happen before
        // AppKit would otherwise have drawn it, and produced a viewport
        // that stayed blank until some other event forced a redraw. A
        // low-but-nonzero frame rate keeps the original idle-cost win
        // (throttled well below a full 60fps loop) without depending on
        // exact invalidation timing, the display link will always paint
        // the first frame and every frame after, whether or not a
        // setNeedsDisplay() call actually landed.
        //
        // Reverted a same-session attempt to raise this to 60: `WorkspaceViewModel.
        // levelViewerOpenGeneration`'s own doc comment documents real,
        // captured evidence that "the continuously-running 20fps render
        // loop" is one of the two things overlapping `openLevelViewer`
        // calls contend with for the main actor during the exact multi-
        // second stalls under active investigation right now, tripling
        // this loop's frequency while that contention bug is still live
        // risks making it worse, not better. Revisit raising this only
        // after that contention is actually fixed and confirmed gone.
        view.preferredFramesPerSecond = 20
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        onViewReady?(view)
        return view
    }

    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        // The composite preview swaps in a freshly-uploaded renderer per
        // asset (see `CompositePreviewView`) while reusing this same
        // underlying `NSView`, without re-pointing `renderer`/`delegate`
        // here, the view would keep drawing whatever asset it first showed.
        if nsView.renderer !== renderer {
            nsView.renderer = renderer
            nsView.delegate = renderer
        }
        nsView.onGizmoDragEnded = onGizmoDragEnded
        nsView.onGizmoDragStarted = onGizmoDragStarted
        nsView.onGizmoModeChanged = onGizmoModeChanged
        nsView.onTopDownModeChanged = onTopDownModeChanged
        nsView.onObjectPicked = onObjectPicked
        nsView.onObjectPlaced = onObjectPlaced
        nsView.onSceneryPlaced = onSceneryPlaced
        nsView.onPropSkinPlaced = onPropSkinPlaced
        nsView.onAIPathEndpointPicked = onAIPathEndpointPicked
        nsView.onObjectDoubleClicked = onObjectDoubleClicked
        nsView.onEscapePressed = onEscapePressed
        nsView.onHotbarSlotPressed = onHotbarSlotPressed
        nsView.onMarkingMenuBegan = onMarkingMenuBegan
        nsView.onMarkingMenuMoved = onMarkingMenuMoved
        nsView.onMarkingMenuEnded = onMarkingMenuEnded
    }
}
