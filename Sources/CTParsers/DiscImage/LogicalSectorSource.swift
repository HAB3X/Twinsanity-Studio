import Foundation

/// A random-access source of fixed 2048-byte logical (ISO-9660) sectors , 
/// the seam `ISO9660Reader` reads through, so it never has to know whether
/// the bytes underneath came from a plain `.iso` file or a raw-sector
/// `.bin`/`.cue` pair (`BinCueLogicalSource`). "Native ISO & BIN/CUE Disc
/// Image Mounting" (Task 7).
public protocol LogicalSectorSource: Sendable {
    var sectorCount: Int { get }
    /// Returns exactly 2048 bytes, or `nil` if `index` is out of range.
    func sector(_ index: Int) -> Data?
}

/// The plain case: a `.iso` file's bytes already *are* a flat sequence of
/// 2048-byte logical sectors, no raw sync/header/ECC framing to strip.
public struct PlainISOSource: LogicalSectorSource {
    public static let sectorSize = 2048
    private let data: Data

    public init(data: Data) {
        self.data = data
    }

    public var sectorCount: Int { data.count / Self.sectorSize }

    public func sector(_ index: Int) -> Data? {
        let start = index * Self.sectorSize
        guard index >= 0, start + Self.sectorSize <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + Self.sectorSize))
    }
}
