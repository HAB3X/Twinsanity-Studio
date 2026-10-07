import Foundation

/// One entry from a `.BH` index (`BDArchive.cs:49-52`): a name-length-prefixed
/// path plus an absolute offset/size into the sibling `.BD` data file.
public struct ArchiveEntry: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var offset: UInt32
    public var size: UInt32

    public init(name: String, offset: UInt32, size: UInt32) {
        self.name = name
        self.offset = offset
        self.size = size
    }
}

/// A parsed `.BH`/`.BD` pair's directory listing (index only, file bytes are
/// read from the `.BD` on demand, since archives can be very large).
public struct ArchiveIndex: Sendable {
    public var bhURL: URL
    public var bdURL: URL
    public var entries: [ArchiveEntry]

    public init(bhURL: URL, bdURL: URL, entries: [ArchiveEntry]) {
        self.bhURL = bhURL
        self.bdURL = bdURL
        self.entries = entries
    }
}
