import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Every "bring data into the workspace" entry point, in one place.
///
/// `ContentView` previously carried four near-identical `NSOpenPanel`
/// configs inline (`presentOpenPanel`, `presentDiscImageOpenPanel`,
/// `presentMemoryCardOpenPanel`, `presentMonkeyBallOpenPanel`) and the
/// toolbar/menu-bar/empty-state all reached for their own copy. This is the
/// single implementation the unified source menu, the first-launch empty
/// state, and the `File` menu all call.
@MainActor
struct SourceActions {
    let workspace: WorkspaceViewModel

    func chooseFolderOrFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose a .BH archive, .RM2/.SM2 file, or a folder to scan."
        panel.prompt = "Open"
        if panel.runModal() == .OK { workspace.open(urls: panel.urls) }
    }

    func mountDiscImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a disc image: .iso, or .bin/.cue (pick either file, its match is found automatically alongside it)."
        panel.prompt = "Mount"
        if panel.runModal() == .OK, let url = panel.urls.first { workspace.mountDiscImage(url: url) }
    }

    func openMemoryCard() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a PS2 memory card image (.mcr/.ps2/.mc2)."
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.urls.first { workspace.openMemoryCard(url: url) }
    }

    func openAsMonkeyBall() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ["RM2", "SM2"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a Super Monkey Ball Adventure .RM2/.SM2 file."
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.urls.first { workspace.openAsMonkeyBall(url: url) }
    }

    func openMasterDirectory() {
        guard let url = workspace.masterDirectoryURL else { return }
        workspace.open(url: url)
    }
}
