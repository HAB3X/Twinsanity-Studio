import Foundation
import CTModels

/// Parses a real PS2 disc's `SYSTEM.CNF`, the standard plain-text boot
/// descriptor every PS2 disc places at its ISO root, e.g.:
/// ```
/// BOOT2 = cdrom0:\SLUS_205.54;1
/// VER = 1.00
/// VMODE = NTSC
/// ```
/// Used here purely for real region detection ("Multi-Region & Cross-Game
/// Auto-Patcher," roadmap 1.4), this is standard, publisher-agnostic PS2
/// disc-authoring convention, not anything guessed about Twinsanity
/// specifically. See `GameRegion`'s own doc comment for the serial-prefix
/// mapping this is built on.
public enum SystemCNFParser {
    private static let regionPrefixes: [(prefix: String, region: GameRegion)] = [
        ("SCUS", .ntscU), ("SLUS", .ntscU),
        ("SCES", .pal), ("SLES", .pal),
        ("SCPS", .ntscJ), ("SLPS", .ntscJ), ("SLPM", .ntscJ), ("SCAJ", .ntscJ),
    ]

    public static func parse(contents: String) -> SystemCNFInfo {
        var bootPath: String?
        var videoMode: String?
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<equalsIndex].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "BOOT", "BOOT2": bootPath = String(value)
            case "VMODE": videoMode = value.uppercased()
            default: break
            }
        }
        let serial = bootPath.flatMap(extractSerial)
        let region = resolveRegion(serial: serial, videoMode: videoMode)
        return SystemCNFInfo(bootPath: bootPath, serial: serial, videoMode: videoMode, region: region)
    }

    /// Pulls e.g. `SLUS_205.54` out of `cdrom0:\SLUS_205.54;1`, the
    /// standard `cdrom0:\<SERIAL>;1` boot-path shape every real PS2 disc
    /// uses.
    private static func extractSerial(from bootPath: String) -> String? {
        var candidate = Substring(bootPath)
        if let backslashIndex = candidate.lastIndex(of: "\\") {
            candidate = candidate[candidate.index(after: backslashIndex)...]
        }
        if let semicolonIndex = candidate.firstIndex(of: ";") {
            candidate = candidate[candidate.startIndex..<semicolonIndex]
        }
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolveRegion(serial: String?, videoMode: String?) -> GameRegion {
        if let serial {
            let upper = serial.uppercased()
            if let match = regionPrefixes.first(where: { upper.hasPrefix($0.prefix) }) {
                return match.region
            }
        }
        // VMODE alone can't distinguish NTSC-U from NTSC-J, but a real
        // "PAL" value is unambiguous on its own even with no serial match.
        if videoMode == "PAL" { return .pal }
        return .unknown
    }
}
