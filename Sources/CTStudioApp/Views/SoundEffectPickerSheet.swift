import SwiftUI
import AVFoundation
import CTModels
import CTParsers

/// "Sound-to-Entity Mapping UI" (roadmap item 4d): turns a bare numeric
/// sound-ID field (`GameObjectInfo.soundIDs`, `CollisionSurfaceInfo.
/// sound1`..`sound6`) into a real picker over every `SoundEffect` this
/// file actually decodes, instead of a text field the user has to guess a
/// number into. Reuses `WorkspaceViewModel.soundEffectRecords(inSameFileAs:)`
/// (already backing the Level Audio panel) for the real list, and
/// `WAVEncoder`/`AVAudioPlayer` (already used by `SoundEffectInspectorView`'s
/// "Play" button) for the inline preview, no new playback mechanism.
///
/// No decoded `SoundEffectAsset` carries a name, this format has none
/// (see that type's own doc comment), so each row is identified by its
/// real numeric ID plus its real, decoded duration/sample rate, not an
/// invented label. This project's reference material has no confirmed
/// sound *category* field either, so this picker doesn't group or filter
/// by one, every real sound in the file, in one flat list, is itself the
/// actual improvement being asked for.
struct SoundEffectPickerSheet: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    /// When true, a "(none)" row is offered that hands back `65535`, the
    /// real on-disk "no sound assigned" sentinel this format already uses
    /// elsewhere (`CollisionSurfaceInfo.sound1`, etc.), not a made-up value.
    var allowsNone: Bool = false
    let onSelect: (UInt16) -> Void

    @State private var playingID: UInt32?
    @State private var player: AVAudioPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose a Sound Effect").font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }
            }
            Text("Every real, decoded SoundEffect record in this file, identified by ID since this format has no sound names.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            let sounds = workspace.soundEffectRecords(inSameFileAs: node)
            if sounds.isEmpty {
                Text("No decoded SoundEffect records found in this file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    if allowsNone {
                        Button {
                            onSelect(65535)
                            dismiss()
                        } label: {
                            Text("(none, clears this slot)").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(sounds, id: \.node.id) { entry in
                        HStack {
                            Button {
                                onSelect(UInt16(clamping: entry.sound.id))
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sound #\(entry.sound.id)").font(.body.monospaced())
                                    Text(rowSubtitle(for: entry.sound))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button {
                                togglePreview(entry.sound)
                            } label: {
                                Image(systemName: playingID == entry.sound.id ? "stop.fill" : "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(entry.sound.pcmSamples.isEmpty)
                            .accessibilityLabel(playingID == entry.sound.id ? "Stop Preview" : "Play Preview")
                        }
                    }
                }
                .frame(minHeight: 260)
            }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 340)
        .onDisappear {
            player?.stop()
        }
    }

    private func rowSubtitle(for sound: SoundEffectAsset) -> String {
        let channels = sound.rightChannelSamples != nil ? "stereo" : "mono"
        return String(format: "%.2fs · %d Hz · %@", sound.durationSeconds, sound.sampleRateHz, channels)
    }

    private func togglePreview(_ sound: SoundEffectAsset) {
        if playingID == sound.id {
            player?.stop()
            playingID = nil
            return
        }
        guard !sound.pcmSamples.isEmpty else { return }
        let wav = sound.rightChannelSamples.map {
            WAVEncoder.encodeStereo(left: sound.pcmSamples, right: $0, sampleRateHz: sound.sampleRateHz)
        } ?? WAVEncoder.encode(pcm: sound.pcmSamples, sampleRateHz: sound.sampleRateHz)
        guard let newPlayer = try? AVAudioPlayer(data: wav) else { return }
        player = newPlayer
        newPlayer.prepareToPlay()
        newPlayer.play()
        playingID = sound.id
    }
}
