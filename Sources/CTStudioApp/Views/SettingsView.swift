import SwiftUI

/// "New Settings Window": a real macOS Settings/Preferences window (⌘,),
/// wired via SwiftUI's `Settings` scene in `CTStudioApp`, that scene
/// builder is what gives this the standard `App Name` -> `Settings…` menu
/// item and ⌘, keyboard shortcut automatically, no manual command wiring
/// needed.
struct SettingsView: View {
    @Environment(WorkspaceViewModel.self) private var workspace

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .environment(workspace)
        .frame(width: 460, height: 340)
    }
}

private struct GeneralSettingsTab: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @State private var isChoosingDirectory = false

    var body: some View {
        @Bindable var workspace = workspace
        return Form {
            Section {
                Toggle("Show Raw / Undecoded Files", isOn: $workspace.showRawFiles)
                Text("Off by default (Smart File Filtering): the sidebar tree hides undecoded records and any folder that only contains them. Turn this on to see everything, including files this build hasn't decoded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Developer Mode")
            }

            Section {
                HStack {
                    if let url = workspace.masterDirectoryURL {
                        Text(url.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Not set")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…") { chooseDirectory() }
                    if workspace.masterDirectoryURL != nil {
                        Button("Clear") { workspace.masterDirectoryURL = nil }
                    }
                }
                Text("The folder Twinsanity Studio treats as your game files' home. Shown as a one-click \"Open Master Directory\" option whenever the workspace is empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Master Directory")
            }

            Section {
                Button("Clear Recent Files") { workspace.clearRecentFiles() }
                    .disabled(workspace.recentFileURLs.isEmpty)
            } header: {
                Text("Quality of Life")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the master directory for your game files."
        if panel.runModal() == .OK, let url = panel.urls.first {
            workspace.masterDirectoryURL = url
        }
    }
}

private struct AppearanceSettingsTab: View {
    @Environment(WorkspaceViewModel.self) private var workspace

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 10)]

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(WorkspaceViewModel.AccentColorChoice.allCases) { choice in
                        Button {
                            workspace.accentColorChoice = choice
                        } label: {
                            Circle()
                                .fill(choice.color)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if workspace.accentColorChoice == choice {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(choice.displayName)
                    }
                }
                .padding(.vertical, 4)
                Text("Tints buttons and controls throughout the app. This is an in-app tint, not a change to your Mac's system-wide accent color. Only System Settings controls that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Accent Color")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Twinsanity Studio")
                .font(.title2.bold())
            Text("Version v1")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Created by Habex")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
                .padding(.vertical, 4)
            Text("A native macOS asset editor, level builder, and modding toolkit for Crash Twinsanity and related Traveller's Tales-era titles.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
