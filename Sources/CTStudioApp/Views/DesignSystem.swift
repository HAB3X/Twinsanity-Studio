import SwiftUI

/// One place for the numbers and surface treatments the UI overhaul relies
/// on, so spacing / corner radius / card chrome stay consistent instead of
/// being re-guessed at every call site. Deliberately tiny, a shared scale
/// and a couple of view modifiers, not a component framework.
enum DS {
    /// 4-based spacing scale. Use these, not literals.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        /// Cards / modules.
        static let card: CGFloat = 12
        /// Controls sitting inside a card.
        static let control: CGFloat = 6
        /// Large hero surfaces (empty state CTAs).
        static let hero: CGFloat = 14
    }

    enum Icon {
        static let hairline: CGFloat = 0.75
    }
}

extension View {
    /// A distinct raised surface, the treatment that makes a docked panel
    /// read as its own module rather than "the detail pane, restyled".
    func dsCardSurface(cornerRadius: CGFloat = DS.Radius.card) -> some View {
        self
            .background(.background, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator))
    }

    /// Subtle elevation for a floating module. Kept small and rare on
    /// purpose, heavy shadows read as non-native on macOS.
    func dsElevated() -> some View {
        shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    /// Standard leading-aligned section header inside forms / panels.
    func dsSectionHeader() -> some View {
        font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A compact, icon-led panel header with a title and a trailing "back to
/// preview" affordance, shared by every docked module so they all dismiss
/// the same way.
struct DSPanelHeader: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Label("Done", systemImage: "chevron.backward")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help("Close this module and return to the asset preview.")
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(.regularMaterial)
    }
}
