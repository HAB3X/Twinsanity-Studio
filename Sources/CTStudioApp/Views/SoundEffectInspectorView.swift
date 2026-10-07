import SwiftUI
import AVFoundation
import CTCore
import CTModels
import CTParsers

/// Wraps decoded mono 16-bit PCM into an in-memory WAV container, the
/// simplest way to hand it to `AVAudioPlayer`, which wants a recognized
/// container format rather than raw samples. Header layout matches the
/// reference tool's own `MHWorker.WriteHeader` (standard 44-byte
/// RIFF/WAVE/fmt /data layout, PCM format 1).
enum WAVEncoder {
    static func encode(pcm: [Int16], sampleRateHz: UInt16) -> Data {
        var data = Data()
        let dataByteCount = UInt32(pcm.count * 2)
        let byteRate = UInt32(sampleRateHz) * 1 * 2
        let blockAlign: UInt16 = 2

        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36) + dataByteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16)) // fmt chunk size
        data.append(littleEndian: UInt16(1))  // PCM
        data.append(littleEndian: UInt16(1))  // mono
        data.append(littleEndian: UInt32(sampleRateHz))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: UInt16(16)) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: dataByteCount)
        for sample in pcm {
            data.append(littleEndian: UInt16(bitPattern: sample))
        }
        return data
    }

    /// Interleaves two independently-decoded mono channels (e.g. a real
    /// `WOCSoundParser.MusicTrack`'s left/right entries) into one stereo
    /// WAV. Truncates to the shorter channel if lengths differ slightly
    /// rather than padding with fabricated silence.
    static func encodeStereo(left: [Int16], right: [Int16], sampleRateHz: UInt16) -> Data {
        var data = Data()
        let frameCount = min(left.count, right.count)
        let dataByteCount = UInt32(frameCount * 4)
        let byteRate = UInt32(sampleRateHz) * 2 * 2
        let blockAlign: UInt16 = 4

        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36) + dataByteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))  // PCM
        data.append(littleEndian: UInt16(2))  // stereo
        data.append(littleEndian: UInt32(sampleRateHz))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: dataByteCount)
        for i in 0..<frameCount {
            data.append(littleEndian: UInt16(bitPattern: left[i]))
            data.append(littleEndian: UInt16(bitPattern: right[i]))
        }
        return data
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func append(littleEndian value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

/// "Sound Playback": decoded `SoundEffect` audio, with a waveform preview,
/// play/stop, and WAV export.
struct SoundEffectInspectorView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    /// `nil` for a standalone sound-bank entry (`SoundBanksHubView`), that
    /// path has no `ChunkNode`/enclosing chunk section at all, so "Replace
    /// with Audio…" (which needs both) is unavailable there. Non-`nil` for
    /// a per-level `SoundEffect` record, where it's also this view's only
    /// use for a `ChunkNode` beyond the plain display name below.
    let node: ChunkNode?
    /// Just a label for diagnostics/export filenames.
    let displayName: String
    let sound: SoundEffectAsset

    @State private var player: AVAudioPlayer?
    @State private var playerDelegate: PlaybackEndDelegate?
    @State private var isPlaying = false
    @State private var isImporting = false
    @State private var importError: String?

    // MARK: - "Dynamic Audio Injector & Loop Master" (roadmap 8.2): loop preview
    /// This format has no decoded/verified loop-point metadata this build
    /// has found, these are a real, tool-side playback aid for testing
    /// where a *replacement* clip should loop before committing to it via
    /// "Replace with Audio…", not a claim about the original game's own
    /// (undecoded) loop points.
    @State private var loopPreviewEnabled = false
    @State private var loopStartFraction: Double = 0
    @State private var loopEndFraction: Double = 1
    @State private var loopMonitorTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            waveform
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))

            Form {
                LabeledContent("Sample Rate", value: "\(sound.sampleRateHz) Hz")
                LabeledContent("Channels", value: sound.rightChannelSamples != nil ? "Stereo" : "Mono")
                LabeledContent("Samples", value: "\(sound.pcmSamples.count)")
                LabeledContent("Duration", value: String(format: "%.2fs", sound.durationSeconds))
            }
            .formStyle(.grouped)

            HStack {
                Button {
                    togglePlayback()
                } label: {
                    Label(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill")
                }
                .disabled(sound.pcmSamples.isEmpty)
                Button {
                    exportWAV()
                } label: {
                    Label("Export WAV…", systemImage: "square.and.arrow.up")
                }
                .disabled(sound.pcmSamples.isEmpty)
                Spacer()
            }

            if sound.pcmSamples.isEmpty {
                Label("Decoded to zero samples. Either genuinely empty, or this record's FreqFac wasn't a recognized sample rate.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !sound.pcmSamples.isEmpty {
                Divider()
                Toggle("Loop Preview", isOn: $loopPreviewEnabled)
                    .toggleStyle(.checkbox)
                if loopPreviewEnabled {
                    LabeledContent("Loop Start") { Slider(value: $loopStartFraction, in: 0...loopEndFraction) }
                    LabeledContent("Loop End") { Slider(value: $loopEndFraction, in: loopStartFraction...1) }
                    Text(String(format: "%.2fs – %.2fs of %.2fs", loopStartFraction * sound.durationSeconds, loopEndFraction * sound.durationSeconds, sound.durationSeconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("A real, tool-side playback loop for testing where a *replacement* clip should loop before committing to it. This format has no decoded loop-point metadata this build has found, so this isn't a claim about the original game's own loop points.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let node, sound.sourceAudioByteRange != nil {
                Divider()
                HStack {
                    Button {
                        presentReplaceAudioPanel(node: node)
                    } label: {
                        Label(isImporting ? "Importing…" : "Replace with Audio…", systemImage: "waveform.badge.plus")
                    }
                    .disabled(isImporting)
                    Spacer()
                    if isImporting { ProgressView().controlSize(.small) }
                }
                Text("\"Sound Import\": re-encodes an audio file you pick to this sound's own \(sound.sampleRateHz) Hz mono ADPCM and saves an edited copy. The original file on disk is not modified. The replacement must encode to no more bytes than the original slot had room for; a longer clip is refused rather than truncated.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let importError {
                    Label(importError, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onDisappear {
            player?.stop()
            stopLoopMonitor()
        }
    }

    private var waveform: some View {
        Canvas { context, size in
            guard !sound.pcmSamples.isEmpty else { return }
            let midY = size.height / 2
            let bucketCount = max(1, Int(size.width))
            let samplesPerBucket = max(1, sound.pcmSamples.count / bucketCount)
            var path = Path()
            for bucket in 0..<bucketCount {
                let start = bucket * samplesPerBucket
                guard start < sound.pcmSamples.count else { break }
                let end = min(start + samplesPerBucket, sound.pcmSamples.count)
                var peak: Int16 = 0
                for i in start..<end {
                    peak = max(peak, abs(sound.pcmSamples[i] == Int16.min ? Int16.max : sound.pcmSamples[i]))
                }
                let amplitude = CGFloat(peak) / CGFloat(Int16.max) * midY
                let x = CGFloat(bucket)
                path.move(to: CGPoint(x: x, y: midY - amplitude))
                path.addLine(to: CGPoint(x: x, y: midY + amplitude))
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1)
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player?.stop()
            stopLoopMonitor()
            isPlaying = false
            return
        }
        // Belt-and-suspenders beyond the button's own `.disabled(sound.
        // pcmSamples.isEmpty)`: AVAudioPlayer's failure mode for genuinely
        // degenerate audio data isn't guaranteed to be a catchable Swift
        // `Error` (some AVFoundation validation failures surface as an
        // uncatchable Objective-C exception instead), refusing to even
        // attempt construction for zero-sample audio removes that path
        // entirely rather than hoping `try?` catches it.
        guard !sound.pcmSamples.isEmpty else {
            workspace.lastError = "This sound decoded to zero samples. Nothing to play."
            return
        }
        let wav = wavData()
        AppLog.audio.debug("Audio selected \"\(displayName)\", \(sound.pcmSamples.count) samples @ \(sound.sampleRateHz) Hz\(sound.rightChannelSamples != nil ? " (stereo)" : ""), \(wav.count) byte WAV container")
        let newPlayer: AVAudioPlayer
        do {
            // `try?` here used to swallow the real reason construction
            // failed (unsupported format, corrupt container, ...), surface
            // it for real instead of a generic "couldn't create a player."
            newPlayer = try AVAudioPlayer(data: wav)
        } catch {
            AppLog.audio.error("AVAudioPlayer(data:) threw: \(error)")
            workspace.lastError = "Couldn't create an audio player for this sound: \(error.localizedDescription)"
            return
        }
        AppLog.audio.debug("Audio buffer loaded, format=\(newPlayer.format), duration=\(newPlayer.duration)s, channels=\(newPlayer.numberOfChannels)")
        let delegate = PlaybackEndDelegate { isPlaying = false }
        newPlayer.delegate = delegate
        playerDelegate = delegate
        player = newPlayer
        newPlayer.prepareToPlay()
        let started = newPlayer.play()
        AppLog.audio.debug("Audio play command sent, accepted=\(started)")
        if !started {
            workspace.lastError = "AVAudioPlayer.play() returned false. Playback didn't start (check system output device/volume)."
        }
        isPlaying = started
        if started, loopPreviewEnabled {
            newPlayer.numberOfLoops = -1 // safety net in case the loop range reaches the very end of the clip
            newPlayer.currentTime = loopStartFraction * newPlayer.duration
            startLoopMonitor()
        }
    }

    /// Polls `player.currentTime` at 20Hz and seeks back to the real loop
    /// start the moment it crosses the real loop end, `AVAudioPlayer` has
    /// no native "loop this sub-range" API, only "loop the whole clip."
    private func startLoopMonitor() {
        stopLoopMonitor()
        loopMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            guard let player, isPlaying, loopPreviewEnabled else { return }
            let loopEndTime = loopEndFraction * player.duration
            if player.currentTime >= loopEndTime {
                player.currentTime = loopStartFraction * player.duration
            }
        }
    }

    private func stopLoopMonitor() {
        loopMonitorTimer?.invalidate()
        loopMonitorTimer = nil
    }

    /// `WAVEncoder.encodeStereo` when `rightChannelSamples` is present
    /// (a decoded `.stereo` sound-bank entry), the plain mono `.encode`
    /// otherwise, every per-level `SoundEffect` record is mono-only, so
    /// this only ever branches for bank entries.
    private func wavData() -> Data {
        if let right = sound.rightChannelSamples {
            return WAVEncoder.encodeStereo(left: sound.pcmSamples, right: right, sampleRateHz: sound.sampleRateHz)
        }
        return WAVEncoder.encode(pcm: sound.pcmSamples, sampleRateHz: sound.sampleRateHz)
    }

    private func exportWAV() {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this sound as a .wav file into.") else { return }
        let wav = wavData()
        let name = displayName.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "#", with: "")
        let url = directory.appendingPathComponent(name).appendingPathExtension("wav")
        do {
            try wav.write(to: url)
            workspace.statusMessage = "Exported \(url.lastPathComponent)."
        } catch {
            workspace.lastError = "Export failed: \(error)"
        }
    }

    /// "Sound Import", the write-back half of Sound Playback: decode ->
    /// edit (here, "edit" means "the user picked a whole replacement
    /// clip") -> encode -> patch -> save-as-copy, the same loop every
    /// other write path in this app uses. Resamples the picked file to
    /// this sound's own sample rate (it can't change, that's the
    /// record's own `FreqFac` field, a different byte range this write
    /// path doesn't touch) via `AVAudioConverter`, same reasoning as
    /// `TextureInspectorView`'s "Replace with Image…" resampling to the
    /// original texture's exact dimensions.
    private func presentReplaceAudioPanel(node: ChunkNode) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a replacement audio file. It's resampled to this sound's exact \(sound.sampleRateHz) Hz mono; the on-disk record's sample rate can't change."
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        importError = nil
        isImporting = true
        Task {
            do {
                let pcm = try Self.loadMonoPCM(from: url, targetSampleRateHz: Double(sound.sampleRateHz))
                let encoded = ADPCMEncoder.fromPCMMono(pcm)
                guard let patchedBytes = workspace.replaceSoundEffectAudio(node: node, encodedADPCM: encoded) else {
                    isImporting = false
                    return // workspace.lastError already set
                }
                guard let saveURL = ExportPanel.chooseSaveLocation(
                    suggestedName: "\(node.displayName)_edited.rm2",
                    message: "Save the edited copy of this file, with this sound replaced. The original file on disk is not modified."
                ) else {
                    isImporting = false
                    return
                }
                try await workspace.writeDataAsync(patchedBytes, to: saveURL)
                workspace.statusMessage = "Saved edited copy to \(saveURL.lastPathComponent) with this sound replaced. The original file was not modified."
            } catch {
                importError = error.localizedDescription
            }
            isImporting = false
        }
    }

    private enum AudioImportError: LocalizedError {
        case conversionFailed
        var errorDescription: String? { "Couldn't decode or resample that file. Check that it's a valid audio file." }
    }

    /// Reads `url` and converts it to 16-bit mono PCM at `targetSampleRateHz`,
    /// via a one-shot `AVAudioConverter` pull (the whole source file is
    /// already loaded into one buffer, so the pull callback supplies it
    /// exactly once and reports no more data after).
    /// Not `private`: "Parity Phase K" reuses this for sound-*bank* entries
    /// too (`SoundBanksHubView`'s "Replace with Audio… (repacks bank)"),
    /// which has no `ChunkNode` to route through this view's own
    /// `presentReplaceAudioPanel`, same resample-to-the-slot's-real-
    /// sample-rate reasoning, just landing in a whole-bank `MBWriter`/
    /// `MHWriter` repack instead of a single record patch.
    static func loadMonoPCM(from url: URL, targetSampleRateHz: Double) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRateHz, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length))
        else {
            throw AudioImportError.conversionFailed
        }
        try file.read(into: sourceBuffer)

        let outputCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * (targetSampleRateHz / sourceFormat.sampleRate) + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw AudioImportError.conversionFailed
        }

        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError { throw conversionError }
        guard let channelData = outputBuffer.int16ChannelData else { throw AudioImportError.conversionFailed }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}

/// Flips the Play/Stop button back to "Play" when a clip finishes on its
/// own, without this, the button silently stayed stuck on "Stop" after
/// playback ended naturally instead of via the button itself.
final class PlaybackEndDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [onFinish] in onFinish() }
    }
}
