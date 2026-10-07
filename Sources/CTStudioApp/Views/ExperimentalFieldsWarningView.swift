import SwiftUI

/// A one-time onboarding note for every screen that shows `ConfidenceTag`-marked
/// fields (the short "(experimental, unconfirmed)"-style parenthetical tags , 
/// see `ConfidenceTag.swift`'s own doc comment for the full vocabulary and its
/// real call sites: `ModelViewerWindow`, `LodModelInspectorView`,
/// `WorldPlacementInspectorViews` (Instance/Trigger/Camera inspectors, shown
/// both from the sidebar's `InspectorView` and from the Level Viewer's own
/// selection inspector), `CollisionSurfaceEditorSheet`, `GameObjectEditorSheet`).
///
/// Deliberately a dismissible banner, not an `.alert`/sheet, unlike
/// `DanglingReferenceChecker`'s confirmation (which gates an irreversible
/// disk write), this is background context the user should see once, not a
/// decision that should block interaction with the rest of the screen.
///
/// Scope: **once per install**, not once per view. All call sites bind the
/// same `@AppStorage` key below, so dismissing it on any one screen (Level
/// Viewer, Model Viewer, sidebar Inspector, etc) dismisses it everywhere , 
/// it's the same underlying caveat repeated at every `ConfidenceTag` site,
/// not a separate warning per screen, and re-showing it screen-by-screen
/// would just be nagging. If a future call site wants its own independent
/// dismissal, give it its own key rather than changing this one's meaning.
struct ExperimentalFieldsWarningView: View {
    @AppStorage("com.twinsanitystudio.hasDismissedExperimentalFieldsWarning")
    private var hasDismissed = false

    var body: some View {
        if !hasDismissed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "flask")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Some fields on this screen are tagged \u{201c}(experimental, unconfirmed)\u{201d}.")
                        .font(.callout.bold())
                    Text("Their meaning hasn't been confirmed against any reference source. Editing them may produce level data that doesn't behave as expected in-game.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    hasDismissed = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss Warning")
                .help("Dismisses this warning everywhere, for good.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .transition(.opacity)
        }
    }
}
