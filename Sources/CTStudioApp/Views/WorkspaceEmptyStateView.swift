import SwiftUI
import UniformTypeIdentifiers

/// Full-window first-launch surface, shown *instead of* the 3-column split
/// while nothing is loaded. Replaces what used to be three stacked
/// `ContentUnavailableView`s (empty sidebar + "No Selection" + "No Preview")
/// with one guided, drop-enabled screen: three primary calls to action, a
/// recent-projects list, every other open path one menu away, and a drop
/// zone that ingests through the same path as the real window.
struct WorkspaceEmptyStateView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @State private var isDropTargeted = false

    private var actions: SourceActions { SourceActions(workspace: workspace) }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.xl) {
                header

                HStack(spacing: DS.Space.md) {
                    CTAButton(title: "Open Folder",
                              subtitle: "A game dump or LEVELS folder",
                              systemImage: "folder.fill", tint: .accentColor) {
                        actions.chooseFolderOrFile()
                    }
                    CTAButton(title: "Mount Game Disc",
                              subtitle: ".iso or .bin/.cue image",
                              systemImage: "opticaldiscdrive.fill", tint: .indigo) {
                        actions.mountDiscImage()
                    }
                    CTAButton(title: "Open Memory Card",
                              subtitle: ".mcr / .ps2 save file",
                              systemImage: "mediastick", tint: .teal) {
                        actions.openMemoryCard()
                    }
                }
                .frame(maxWidth: 660)

                if !workspace.recentFileURLs.isEmpty {
                    recentList
                }

                Menu("More ways to open…") {
                    SourceMenuItems()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                dropZone
            }
            .padding(DS.Space.xxl)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            WorkspaceDropHandler.load(providers) { workspace.open(urls: $0) }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    private var header: some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.tint)
            Text("Twinsanity Studio")
                .font(.largeTitle.bold())
            Text("Open a project to start browsing chunks, models, textures, and levels.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, DS.Space.lg)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Recent Projects").dsSectionHeader()
            ForEach(workspace.recentFileURLs.prefix(5), id: \.path) { url in
                Button {
                    workspace.open(url: url)
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, DS.Space.xxs + 1)
                    .padding(.horizontal, DS.Space.xs)
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: DS.Radius.control))
            }
        }
        .frame(maxWidth: 660, alignment: .leading)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: DS.Radius.hero)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            .frame(maxWidth: 660, minHeight: 96)
            .overlay {
                Label(isDropTargeted ? "Release to open"
                                     : "or drop a .BH/.BD, .RM2/.SM2, a disc image, or a folder",
                      systemImage: "square.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            .background(
                isDropTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: DS.Radius.hero)
            )
    }
}

private struct CTAButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 26))
                    .foregroundStyle(tint)
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 128)
            .padding(DS.Space.sm)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .strokeBorder(hovering ? tint : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
