import Foundation

/// Which physical platform an `ExecutablePatcher` offset table targets.
public enum GameExecutablePlatform: String, Sendable, CaseIterable {
    case ps2 = "PS2"
    case xbox = "Xbox"
}

/// A specific Crash Twinsanity executable build, real, verified byte
/// offsets ported from **CrateModLoader**'s own `TS_ChangeStartingChunk`/
/// `TS_ChangeCreditsChunk`/`TS_SwapStartCreditsSpawn`/`TS_StartSpawnCredits`
/// (`CrateModGames/GameSpecific/CrashTS/Mods/*.cs`), not derived or
/// guessed at by this project. Distinct from `GameRegion`: that's a PS2
/// *disc's* region (read from `SYSTEM.CNF`); this is the specific
/// executable build, since NTSC-U alone has two byte-incompatible
/// revisions (original vs. reprint/Greatest Hits) that only differ by one
/// probed byte, not by region.
public enum GameExecutableRevision: String, Sendable, CaseIterable, Identifiable {
    case pal, ntscU, ntscU2, ntscJ, xboxNTSC, xboxPAL

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pal: return "PS2 PAL"
        case .ntscU: return "PS2 NTSC-U"
        case .ntscU2: return "PS2 NTSC-U (2nd print / Greatest Hits)"
        case .ntscJ: return "PS2 NTSC-J"
        case .xboxNTSC: return "Xbox NTSC"
        case .xboxPAL: return "Xbox PAL"
        }
    }

    public var platform: GameExecutablePlatform {
        switch self {
        case .pal, .ntscU, .ntscU2, .ntscJ: return .ps2
        case .xboxNTSC, .xboxPAL: return .xbox
        }
    }

    /// `(byte offset, field length)` of the null-padded starting-chunk
    /// path string, `TS_ChangeStartingChunk`'s `LevelOffs`/`LevelSizes`.
    var startingChunkField: (offset: Int, length: Int) {
        switch self {
        case .pal: return (0x1F6708, 0x17)
        case .ntscU: return (0x1F5E28, 0x17)
        case .ntscU2: return (0x1F63A8, 0x17)
        case .ntscJ: return (0x1F6648, 0x17)
        case .xboxNTSC: return (0x368870, 0x17)
        case .xboxPAL: return (0x368858, 0x17)
        }
    }

    /// `(byte offset, field length)` of the null-padded credits-chunk
    /// path string, `TS_ChangeCreditsChunk`'s `CreditsLevelOffs`/
    /// `CreditsLevelSizes`.
    var creditsChunkField: (offset: Int, length: Int) {
        switch self {
        case .pal: return (0x1F6720, 0x22)
        case .ntscU: return (0x1F5E40, 0x22)
        case .ntscU2: return (0x1F63C0, 0x22)
        case .ntscJ: return (0x1F6660, 0x22)
        case .xboxNTSC: return (0x36888C, 0x1D)
        case .xboxPAL: return (0x368874, 0x1D)
        }
    }

    /// Byte offset of the 4-byte start-level pointer, `TS_SwapStartCreditsSpawn`'s
    /// `StartLevelPathOff`.
    var startSpawnPointerOffset: Int {
        switch self {
        case .pal: return 0x79938
        case .ntscU: return 0x79748
        case .ntscU2: return 0x79820
        case .ntscJ: return 0x79978
        case .xboxNTSC: return 0x265200
        case .xboxPAL: return 0x265110
        }
    }

    /// Byte offset of the 4-byte credits-level pointer, `StartLevelPathOff2`.
    var creditsSpawnPointerOffset: Int {
        switch self {
        case .pal: return 0x79958
        case .ntscU: return 0x79768
        case .ntscU2: return 0x79840
        case .ntscJ: return 0x79998
        case .xboxNTSC: return 0x265230
        case .xboxPAL: return 0x265140
        }
    }

    /// `(byte offset, field length)` of the null-padded "Game Archive"
    /// path string, the reference editor's `EXEPatcher.ExecutablePatchInfo.ArchiveOff`/
    /// `ArchiveSize`, exposed there as the "Patch Game Archive" checkbox.
    /// PS2-only: the reference tool never shipped an Xbox build of this
    /// field, and this project has no independently-verified Xbox offset
    /// for it, so `xboxNTSC`/`xboxPAL` return `nil` rather than guess.
    /// Note: the PS2 NTSC-U/NTSC-U2 disambiguation probe byte used by
    /// `detectNTSCURevision` (`0x1ECB10`) is this exact field's first byte
    /// on the NTSC-U build, the two builds' game-archive filenames happen
    /// to differ in their first character, which is what the probe was
    /// really keying off of.
    public var archiveField: (offset: Int, length: Int)? {
        switch self {
        case .pal: return (0x1ED410, 0x7)
        case .ntscU: return (0x1ECB10, 0x7)
        case .ntscU2: return (0x1ED090, 0x7)
        case .ntscJ: return (0x1ED310, 0x7)
        case .xboxNTSC, .xboxPAL: return nil
        }
    }
}

public enum ExecutablePatcherError: Error, CustomStringConvertible {
    case pathTooLong(maxLength: Int)
    case fileTooSmall(requiredOffset: Int, actualSize: Int)
    case fieldNotSupported(fieldName: String, revision: GameExecutableRevision)

    public var description: String {
        switch self {
        case .pathTooLong(let maxLength):
            return "Chunk path is too long, this executable build's field only fits \(maxLength) bytes."
        case .fileTooSmall(let requiredOffset, let actualSize):
            return "This file is too small to be the executable this revision expects (needs at least \(requiredOffset) bytes, got \(actualSize))."
        case .fieldNotSupported(let fieldName, let revision):
            return "\(fieldName) has no verified offset for \(revision.displayName), the reference tool never shipped this field for that build."
        }
    }
}

/// Direct byte patches to the Crash Twinsanity boot executable itself
/// (`default.xbe` on Xbox, the PS2 `SLUS`/`SLES`/`SLPS` binary), distinct
/// from every other writer in this codebase, which patches RM/SM chunk
/// files. Every offset/field-length/probe-byte here is copied verbatim
/// from CrateModLoader's own real, working mod source (see
/// `GameExecutableRevision`'s doc comment), this project has not
/// independently reverse-engineered the executable.
public enum ExecutablePatcher {
    /// Real byte-probe disambiguation between the two NTSC-U builds , 
    /// ported verbatim from CrateModLoader's own `Twins_Common.GetEXE`:
    /// the byte at `0x1ECB10` is ASCII `'C'` in the original NTSC-U build
    /// and something else in the NTSC-U2 (2nd print/Greatest Hits) build.
    /// Returns `nil` if the file is too small to contain that probe byte
    /// at all (not a PS2 NTSC-U executable of either revision).
    public static func detectNTSCURevision(exeData: Data) -> GameExecutableRevision? {
        let probeOffset = exeData.startIndex + 0x1ECB10
        guard probeOffset < exeData.endIndex else { return nil }
        return exeData[probeOffset] == UInt8(ascii: "C") ? .ntscU : .ntscU2
    }

    private static func writingPath(_ path: String, offset: Int, length: Int, into exeData: Data) throws -> Data {
        let asciiBytes = Array(path.utf8)
        guard asciiBytes.count <= length else { throw ExecutablePatcherError.pathTooLong(maxLength: length) }
        let start = exeData.startIndex + offset
        let end = start + length
        guard end <= exeData.endIndex else {
            throw ExecutablePatcherError.fileTooSmall(requiredOffset: offset + length, actualSize: exeData.count)
        }
        var patched = exeData
        // Zero the whole field first, then write the ASCII bytes over the
        // front of it, the exact two-pass behavior of the reference's
        // own `ModPass` (`while position < end { Write(0) }`, then
        // `Write(levelName[i])` from the field's start), not just a
        // same-effect rewrite.
        var field = [UInt8](repeating: 0, count: length)
        for (index, byte) in asciiBytes.enumerated() { field[index] = byte }
        patched.replaceSubrange(start..<end, with: field)
        return patched
    }

    private static func readingPath(offset: Int, length: Int, from exeData: Data) -> String? {
        let start = exeData.startIndex + offset
        let end = start + length
        guard end <= exeData.endIndex else { return nil }
        let field = exeData[start..<end]
        let trimmed = field.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// "Change Starting Chunk" (`TS_ChangeStartingChunk`), real value,
    /// straight from the executable's own bytes.
    public static func readStartingChunkPath(revision: GameExecutableRevision, from exeData: Data) -> String? {
        let field = revision.startingChunkField
        return readingPath(offset: field.offset, length: field.length, from: exeData)
    }

    public static func writingStartingChunkPath(_ path: String, revision: GameExecutableRevision, into exeData: Data) throws -> Data {
        let field = revision.startingChunkField
        return try writingPath(path, offset: field.offset, length: field.length, into: exeData)
    }

    /// "Change Credits Chunk" (`TS_ChangeCreditsChunk`).
    public static func readCreditsChunkPath(revision: GameExecutableRevision, from exeData: Data) -> String? {
        let field = revision.creditsChunkField
        return readingPath(offset: field.offset, length: field.length, from: exeData)
    }

    public static func writingCreditsChunkPath(_ path: String, revision: GameExecutableRevision, into exeData: Data) throws -> Data {
        let field = revision.creditsChunkField
        return try writingPath(path, offset: field.offset, length: field.length, into: exeData)
    }

    /// "Patch Game Archive" (`EXEPatcher`'s `ArchiveOff`/`ArchiveSize`) , 
    /// the boot archive filename (e.g. the `.BD`/`.BH` pair name) the
    /// executable loads at startup. PS2-only, see `archiveField`.
    public static func readGameArchivePath(revision: GameExecutableRevision, from exeData: Data) -> String? {
        guard let field = revision.archiveField else { return nil }
        return readingPath(offset: field.offset, length: field.length, from: exeData)
    }

    public static func writingGameArchivePath(_ path: String, revision: GameExecutableRevision, into exeData: Data) throws -> Data {
        guard let field = revision.archiveField else {
            throw ExecutablePatcherError.fieldNotSupported(fieldName: "Game Archive", revision: revision)
        }
        return try writingPath(path, offset: field.offset, length: field.length, into: exeData)
    }

    private static func readUInt32LE(at offset: Int, from data: Data) throws -> UInt32 {
        let start = data.startIndex + offset
        let end = start + 4
        guard end <= data.endIndex else { throw ExecutablePatcherError.fileTooSmall(requiredOffset: offset + 4, actualSize: data.count) }
        let bytes = data[start..<end]
        return bytes.enumerated().reduce(UInt32(0)) { acc, entry in acc | (UInt32(entry.element) << (8 * entry.offset)) }
    }

    private static func writingUInt32LE(_ value: UInt32, at offset: Int, into data: Data) throws -> Data {
        let start = data.startIndex + offset
        let end = start + 4
        guard end <= data.endIndex else { throw ExecutablePatcherError.fileTooSmall(requiredOffset: offset + 4, actualSize: data.count) }
        var patched = data
        let bytes: [UInt8] = (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
        patched.replaceSubrange(start..<end, with: bytes)
        return patched
    }

    /// "Swap Start/Credits Spawn" (`TS_SwapStartCreditsSpawn`), swaps the
    /// two 4-byte level-path pointers in place, so the game boots into
    /// what was the credits chunk and vice versa.
    public static func swappingStartAndCreditsSpawn(revision: GameExecutableRevision, in exeData: Data) throws -> Data {
        let startPointer = try readUInt32LE(at: revision.startSpawnPointerOffset, from: exeData)
        let creditsPointer = try readUInt32LE(at: revision.creditsSpawnPointerOffset, from: exeData)
        var patched = try writingUInt32LE(creditsPointer, at: revision.startSpawnPointerOffset, into: exeData)
        patched = try writingUInt32LE(startPointer, at: revision.creditsSpawnPointerOffset, into: patched)
        return patched
    }

    /// "Start Spawn = Credits" (`TS_StartSpawnCredits`), one-directional:
    /// copies the credits-level pointer over the start-level pointer,
    /// without touching the credits pointer itself (unlike the swap
    /// above). Ported exactly, CrateModLoader's own `TS_StartSpawnCredits`
    /// reads `StartLevelPathOff2` twice (its own doc comment on
    /// `TS_Props_Misc.StartingChunk` notwithstanding) and writes it only to
    /// `StartLevelPathOff`.
    public static func copyingCreditsSpawnToStart(revision: GameExecutableRevision, in exeData: Data) throws -> Data {
        let creditsPointer = try readUInt32LE(at: revision.creditsSpawnPointerOffset, from: exeData)
        return try writingUInt32LE(creditsPointer, at: revision.startSpawnPointerOffset, into: exeData)
    }
}
