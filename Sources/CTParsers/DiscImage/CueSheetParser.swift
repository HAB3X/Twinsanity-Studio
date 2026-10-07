import Foundation

/// The raw-sector framing a `.bin` track uses, real, standard CD-ROM
/// sector layouts (Yellow Book / CDROM-XA), not anything Twinsanity- or
/// PS2-specific:
/// - `mode1_2352`: 12-byte sync + 4-byte header + 2048 user data + 4 EDC +
///   8 reserved + 276 ECC = 2352 bytes; user data starts at offset 16.
/// - `mode2Form1_2352`: 12-byte sync + 4-byte header + 8-byte subheader +
///   2048 user data + 4 EDC + 276 ECC = 2352 bytes; user data starts at
///   offset 24. The common "raw" rip mode for PS1/PS2 CD-XA discs.
/// - `raw2048`: the `.bin` is already flat 2048-byte logical sectors with
///   no sync/header framing at all (some rippers write this directly).
public enum DiscSectorFraming: Sendable, Equatable {
    case mode1_2352
    case mode2Form1_2352
    case raw2048

    var rawSectorSize: Int {
        switch self {
        case .mode1_2352, .mode2Form1_2352: return 2352
        case .raw2048: return 2048
        }
    }

    var dataOffset: Int {
        switch self {
        case .mode1_2352: return 16
        case .mode2Form1_2352: return 24
        case .raw2048: return 0
        }
    }
}

public struct CueSheetInfo: Sendable, Equatable {
    public let binFileName: String
    public let framing: DiscSectorFraming

    public init(binFileName: String, framing: DiscSectorFraming) {
        self.binFileName = binFileName
        self.framing = framing
    }
}

/// Parses a real `.cue` sheet, the standard plain-text track descriptor
/// that accompanies a raw `.bin` CD image, e.g.:
/// ```
/// FILE "Crash Twinsanity.bin" BINARY
///   TRACK 01 MODE2/2352
///     INDEX 01 00:00:00
/// ```
/// Only the first `FILE`/`TRACK` pair (track 1, always the data track on a
/// PS2 game disc) is used, later tracks on a multi-track disc are audio
/// or otherwise irrelevant to mounting the filesystem.
public enum CueSheetParser {
    public enum ParseError: Error, Equatable {
        case missingFileLine
        case missingTrackLine
        case unsupportedTrackMode(String)
    }

    public static func parse(contents: String) throws -> CueSheetInfo {
        var binFileName: String?
        var modeString: String?
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if binFileName == nil, line.uppercased().hasPrefix("FILE ") {
                binFileName = extractQuoted(line)
            } else if modeString == nil, line.uppercased().hasPrefix("TRACK ") {
                modeString = line.split(separator: " ").last.map(String.init)
            }
        }
        guard let binFileName else { throw ParseError.missingFileLine }
        guard let modeString else { throw ParseError.missingTrackLine }
        let framing: DiscSectorFraming
        switch modeString.uppercased() {
        case "MODE1/2352": framing = .mode1_2352
        case "MODE2/2352": framing = .mode2Form1_2352
        case "MODE1/2048", "MODE2/2048": framing = .raw2048
        default: throw ParseError.unsupportedTrackMode(modeString)
        }
        return CueSheetInfo(binFileName: binFileName, framing: framing)
    }

    private static func extractQuoted(_ line: String) -> String? {
        guard let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first != last else { return nil }
        return String(line[line.index(after: first)..<last])
    }
}

/// A `.bin`'s raw sectors, viewed through a real `DiscSectorFraming` as a
/// flat sequence of logical 2048-byte sectors, the `BinCueLogicalSource`
/// counterpart to `PlainISOSource`, so `ISO9660Reader` never has to know
/// which kind of image it's reading.
public struct BinCueLogicalSource: LogicalSectorSource {
    private let binData: Data
    private let framing: DiscSectorFraming

    public init(binData: Data, framing: DiscSectorFraming) {
        self.binData = binData
        self.framing = framing
    }

    public var sectorCount: Int { binData.count / framing.rawSectorSize }

    public func sector(_ index: Int) -> Data? {
        guard index >= 0 else { return nil }
        let rawStart = index * framing.rawSectorSize
        let dataStart = rawStart + framing.dataOffset
        guard dataStart >= 0, dataStart + 2048 <= binData.count else { return nil }
        return binData.subdata(in: (binData.startIndex + dataStart)..<(binData.startIndex + dataStart + 2048))
    }
}
