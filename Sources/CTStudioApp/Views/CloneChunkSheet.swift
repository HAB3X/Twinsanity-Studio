import SwiftUI
import CTModels

/// "Create New Chunks/Levels, Chunk Cloning": see `WorkspaceViewModel.
/// cloningChunk`'s own doc comment for exactly what this can and can't do.
struct CloneChunkSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let sceneryFileRoot: ChunkNode

    @State private var newName = ""
    @State private var isCloning = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Clone as New Chunk").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Duplicates \"\(sceneryFileRoot.displayName)\", and its sibling Instance/Trigger/Camera file, if it has one, as brand-new archive entries under a new name, right in the same disc image. There's no decoded game menu to register a new level in, so this new chunk is reachable via Quick Launch's starting-chunk override or by adding a Chunk Link to it, not from the game's own level select.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("New Name") {
                TextField("e.g. beach_v2", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCloning)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isCloning ? "Cloning…" : "Clone") { clone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCloning || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 460)
    }

    private func clone() {
        errorMessage = nil
        isCloning = true
        Task {
            let result = await workspace.cloningChunk(sceneryFileRoot: sceneryFileRoot, newBaseName: newName)
            isCloning = false
            switch result {
            case .success(let outcome):
                let actorNote = outcome.actorEntryName.map { " and \($0)" } ?? " (no sibling Instance/Trigger/Camera file to clone)"
                workspace.statusMessage = "Cloned to \(outcome.sceneryEntryName)\(actorNote). Reopen the archive to see the new chunk."
                dismiss()
            case .failure(let error):
                errorMessage = "\(error)"
            }
        }
    }
}
