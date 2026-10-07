import SwiftUI
import AVFoundation
import CTCore
import CTParsers

/// Browses real, decoded clips from WoC's centralized `SFX.DAT` archive
/// (see `WOCSoundParser`'s doc comment for the confirmed container/codec
/// format). The archive has no per-clip names -- every entry is a real
/// clip, addressed only by its index into the archive's own table -- so
/// this is a flat, index-ordered list rather than a named/categorized
/// browser.
struct WOCSoundBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let archiveURL: URL

    @State private var entries: [WOCSoundParser.Entry] = []
    @State private var isLoadingTable = true
    @State private var loadError: String?

    @State private var decodingIndex: Int?
    @State private var playingIndex: Int?
    @State private var decodeError: String?
    @State private var player: AVAudioPlayer?
    @State private var playerDelegate: PlaybackEndDelegate?

    @State private var musicTracks: [WOCSoundParser.MusicTrack]?
    @State private var isLoadingMusic = false
    @State private var musicLoadError: String?
    @State private var playingMusicTrackID: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("WoC Sound Browser")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)
            Divider()

            if isLoadingTable {
                ProgressView("Reading SFX.DAT's table…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Couldn't Read Archive", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                statusBar
                musicSection
                Divider()
                List(entries) { entry in
                    row(for: entry)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 560)
        .task { await loadTable() }
        .onDisappear { player?.stop() }
    }

    private var statusBar: some View {
        Text("\(entries.count) real clips decoded from PS-ADPCM (\"VAGp\") audio, centralized in one archive shared by every level -- no per-level sound files exist.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Real background-music tracks are just unusually large entries in
    /// this same archive, each one's left/right stereo channel stored as
    /// two consecutive table entries (see `WOCSoundParser.MusicTrack`'s
    /// doc comment for how this was confirmed). Finding them costs one
    /// small extra read per archive entry, so it's opt-in rather than
    /// paid on every browser open.
    @ViewBuilder
    private var musicSection: some View {
        Divider()
        if let musicTracks {
            if musicTracks.isEmpty {
                Text("No music tracks found in this archive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Music Tracks (\(musicTracks.count))")
                        .font(.caption.bold())
                    ForEach(musicTracks) { track in
                        HStack {
                            Text("#\(track.left.index)/\(track.right.index)")
                                .font(.caption.monospaced())
                            Spacer()
                            Text((track.left.size + track.right.size).formattedByteCount)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Button {
                                toggleMusic(track)
                            } label: {
                                Image(systemName: playingMusicTrackID == track.id ? "stop.fill" : "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(playingMusicTrackID == track.id ? "Stop Music Track" : "Play Music Track")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        } else {
            HStack {
                if isLoadingMusic {
                    ProgressView().controlSize(.small)
                    Text("Scanning for music tracks…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Find Music Tracks") {
                        Task { await loadMusicTracks() }
                    }
                    .font(.caption)
                    if let musicLoadError {
                        Text(musicLoadError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func loadMusicTracks() async {
        isLoadingMusic = true
        musicLoadError = nil
        let capturedEntries = entries
        do {
            let tracks = try await Task.detached {
                try WOCSoundParser.findMusicTracks(in: capturedEntries, fileURL: archiveURL)
            }.value
            musicTracks = tracks
        } catch {
            musicLoadError = "\(error)"
        }
        isLoadingMusic = false
    }

    private func toggleMusic(_ track: WOCSoundParser.MusicTrack) {
        if playingMusicTrackID == track.id {
            player?.stop()
            playingMusicTrackID = nil
            return
        }
        player?.stop()
        playingIndex = nil
        playingMusicTrackID = nil
        Task {
            do {
                let (left, right) = try await Task.detached {
                    let left = try WOCSoundParser.decode(track.left, fileURL: archiveURL)
                    let right = try WOCSoundParser.decode(track.right, fileURL: archiveURL)
                    return (left, right)
                }.value
                let wav = WAVEncoder.encodeStereo(left: left.samples, right: right.samples, sampleRateHz: UInt16(clamping: left.sampleRate))
                let newPlayer = try AVAudioPlayer(data: wav)
                let delegate = PlaybackEndDelegate { playingMusicTrackID = nil }
                newPlayer.delegate = delegate
                playerDelegate = delegate
                player = newPlayer
                newPlayer.prepareToPlay()
                if newPlayer.play() {
                    playingMusicTrackID = track.id
                }
            } catch {
                musicLoadError = "Couldn't decode track #\(track.left.index)/\(track.right.index): \(error)"
            }
        }
    }

    private func row(for entry: WOCSoundParser.Entry) -> some View {
        HStack {
            Text("#\(entry.index)")
                .font(.body.monospaced())
                .frame(width: 56, alignment: .leading)
            Text(entry.size.formattedByteCount)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            if decodingIndex == entry.index {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    toggle(entry)
                } label: {
                    Image(systemName: playingIndex == entry.index ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(playingIndex == entry.index ? "Stop Sound" : "Play Sound")
            }
        }
        .contentShape(Rectangle())
    }

    private func loadTable() async {
        do {
            let parsed = try await Task.detached {
                try WOCSoundParser.parseTable(fileURL: archiveURL)
            }.value
            entries = parsed
        } catch {
            loadError = "\(error)"
        }
        isLoadingTable = false
    }

    private func toggle(_ entry: WOCSoundParser.Entry) {
        if playingIndex == entry.index {
            player?.stop()
            playingIndex = nil
            return
        }
        player?.stop()
        playingIndex = nil
        playingMusicTrackID = nil
        decodeError = nil
        decodingIndex = entry.index
        Task {
            do {
                let clip = try await Task.detached {
                    try WOCSoundParser.decode(entry, fileURL: archiveURL)
                }.value
                decodingIndex = nil
                guard !clip.samples.isEmpty else {
                    decodeError = "Entry #\(entry.index) decoded to zero samples."
                    return
                }
                let wav = WAVEncoder.encode(pcm: clip.samples, sampleRateHz: UInt16(clamping: clip.sampleRate))
                let newPlayer = try AVAudioPlayer(data: wav)
                let delegate = PlaybackEndDelegate { playingIndex = nil }
                newPlayer.delegate = delegate
                playerDelegate = delegate
                player = newPlayer
                newPlayer.prepareToPlay()
                if newPlayer.play() {
                    playingIndex = entry.index
                }
            } catch {
                decodingIndex = nil
                decodeError = "Couldn't decode entry #\(entry.index): \(error)"
            }
        }
    }
}
