import OSLog

/// Shared `Logger` instances for the app's `print("DIAG: ...")`-style
/// diagnostics, `OSLog` is near-zero-cost when nothing is listening
/// (unlike `print`, which always pays for string interpolation and a
/// stdout write), and its categories show up filterable in Console.app
/// instead of interleaved in one undifferentiated stream.
public enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "TwinsanityStudio"

    /// Chunk stitching and GPU submesh build diagnostics (dropped scenery
    /// placements, zero-submesh builds).
    public static let rendering = Logger(subsystem: subsystem, category: "rendering")

    /// Sound effect playback diagnostics (decode, `AVAudioPlayer`
    /// construction, transport commands).
    public static let audio = Logger(subsystem: subsystem, category: "audio")

    /// Archive/folder scan diagnostics (per-entry parse failures during a
    /// bulk Models/Textures Hub scan), a scan already tolerates and counts
    /// individual entry failures rather than aborting, but the count alone
    /// doesn't say which entry failed or why.
    public static let scanning = Logger(subsystem: subsystem, category: "scanning")
}
