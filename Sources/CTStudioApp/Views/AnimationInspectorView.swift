import SwiftUI
import CTModels
import CTParsers

/// Shows decoded animation curve data with frame-scrubbing playback
/// controls, plus real write-back for "Add Frame"/"Delete Frame", ports
/// `Editors/AnimationEditor.cs`'s "Add/Delete Timeline" buttons via
/// `AnimationWriter`. Deliberately does **not** port the reference's own
/// bug there: `btnAddTimeline_Click` constructs a new frame as
/// `new Animation.AnimatedTransform(animation.TotalFrames)`, sizing the
/// new frame's value count from the *frame count*, not
/// `ComponentsUsedPerFrame`, which fills every added frame with the
/// wrong number of values and desyncs every frame after it once saved.
/// This implementation zero-fills the new frame with exactly
/// `componentsPerFrame` values instead, verified round-trip in
/// `AnimationWriterTests`.
///
/// Every other field stays read-only: this intentionally stops at *data*
/// playback (scrubbing through decoded per-frame channel values) rather
/// than driving a skinned mesh in the 3D viewport, turning a frame's raw
/// channel values into a final joint matrix depends on `JointSettings.
/// Flags`/`TransformationChoice` semantics that aren't fully pinned down
/// even in the reference tool (see `AnimationViewer.
/// AnimateSkeletonJointBuffer` in the original source), so rather than
/// guess at a wrong skinning result, this exposes the real decoded values
/// for inspection/export instead.
struct AnimationInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    let node: ChunkNode?
    let animation: AnimationAsset
    @State private var currentFrame: Double = 0
    @State private var isPlaying = false
    @State private var timer: Timer?
    @State private var working: AnimationAsset
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode?, animation: AnimationAsset) {
        self.node = node
        self.animation = animation
        _working = State(initialValue: animation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            trackSection(title: "Body Track", track: working.body, isBody: true)
            if working.facial.totalFrames > 0 || working.facial.componentsPerFrame > 0 {
                Divider()
                trackSection(title: "Facial Track", track: working.facial, isBody: false)
            }
            if let node {
                Divider()
                HStack {
                    Button(isSaving ? "Saving…" : "Save Edited Copy…") { save(node: node) }
                        .disabled(isSaving || working.body.frames.count == animation.body.frames.count && working.facial.frames.count == animation.facial.frames.count)
                    Spacer()
                }
                Text("Add/Delete Frame are real structural edits (this record's on-disk size changes). \"Save Edited Copy…\" writes them; everything else here stays read-only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    /// Zero-filled to exactly `componentsPerFrame` values, see this
    /// view's own top-level doc comment for why that's a deliberate,
    /// verified departure from the reference's own buggy
    /// `btnAddTimeline_Click`, not an oversight.
    private func addFrame(isBody: Bool) {
        currentFrame = 0
        if isBody {
            working.body.frames.append(AnimFrame(values: [Int16](repeating: 0, count: working.body.componentsPerFrame)))
        } else {
            working.facial.frames.append(AnimFrame(values: [Int16](repeating: 0, count: working.facial.componentsPerFrame)))
        }
    }

    /// Removes the *last* frame, matches the reference's own
    /// `btnDeleteTimeline2_Click` (`RemoveAt(Count - 1)`), not an
    /// arbitrary index.
    private func deleteFrame(isBody: Bool) {
        currentFrame = 0
        if isBody {
            guard !working.body.frames.isEmpty else { return }
            working.body.frames.removeLast()
        } else {
            guard !working.facial.frames.isEmpty else { return }
            working.facial.frames.removeLast()
        }
    }

    private func save(node: ChunkNode) {
        let encoded = AnimationWriter.write(working)
        guard let patchedBytes = workspace.patchedFileBytes(replacingWholeRecord: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this animation's frame count changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this animation changed. The original file was not modified."
                isSaving = false
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }

    @ViewBuilder
    private func trackSection(title: String, track: AnimationTrack, isBody: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Form {
                LabeledContent("Joints", value: "\(track.jointSettings.count)")
                LabeledContent("Static Transforms", value: "\(track.staticTransforms.count)")
                LabeledContent("Total Frames", value: "\(track.totalFrames)")
                LabeledContent("Components / Frame", value: "\(track.componentsPerFrame)")
            }
            .formStyle(.grouped)

            if node != nil {
                HStack {
                    Button("Add Frame") { addFrame(isBody: isBody) }
                    Button("Delete Frame", role: .destructive) { deleteFrame(isBody: isBody) }
                        .disabled(track.frames.isEmpty)
                    Spacer()
                }
            }

            if track.totalFrames > 1 {
                HStack {
                    Button {
                        togglePlayback(track: track)
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .accessibilityLabel(isPlaying ? "Pause Playback" : "Play Animation")
                    Slider(value: $currentFrame, in: 0...Double(track.totalFrames - 1), step: 1)
                    Text("\(Int(currentFrame)) / \(track.totalFrames - 1)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                }

                let frameIndex = min(track.totalFrames - 1, max(0, Int(currentFrame)))
                let frame = track.frames[frameIndex]
                DisclosureGroup("Frame \(frameIndex) channel values (\(frame.values.count))") {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 4) {
                            ForEach(Array(frame.values.enumerated()), id: \.offset) { idx, value in
                                Text(String(format: "%.3f", Float(value) / 4096.0))
                                    .font(.system(.caption2, design: .monospaced))
                                    .padding(4)
                                    .background(Color.secondary.opacity(0.08))
                                    .cornerRadius(4)
                                    .help("Channel \(idx): raw \(value)")
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
    }

    private func togglePlayback(track: AnimationTrack) {
        isPlaying.toggle()
        if isPlaying {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                currentFrame = (currentFrame + 1).truncatingRemainder(dividingBy: Double(max(1, track.totalFrames)))
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}
