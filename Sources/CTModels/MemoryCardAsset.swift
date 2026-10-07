import Foundation

/// A decoded PS2 memory card (`.mcr`/`.ps2`) superblock, the fixed-location,
/// fixed-format 340-byte header every card starts with. Field layout per the
/// standard, widely-implemented PS2 memory card file system (used by mymc,
/// PCSX2, and others), this is a documented console-platform format, not a
/// Twinsanity-specific one, and is unrelated to the rest of this package.
public struct MemoryCardSuperblock: Sendable {
    public var magic: String
    public var version: String
    public var pageLength: Int
    public var pagesPerCluster: Int
    public var pagesPerBlock: Int
    public var clustersPerCard: Int
    public var allocOffset: Int
    public var allocEnd: Int
    public var rootDirCluster: Int
    public var backupBlock1: Int
    public var backupBlock2: Int
    /// Absolute (card-relative, NOT `allocOffset`-relative) cluster numbers
    /// of the indirect FAT clusters, see `MemoryCardParser`'s doc comment
    /// on cluster addressing for why this distinction matters.
    public var indirectFATClusters: [UInt32]
    public var cardType: Int
    public var cardFlags: Int

    public init(
        magic: String, version: String, pageLength: Int, pagesPerCluster: Int, pagesPerBlock: Int,
        clustersPerCard: Int, allocOffset: Int, allocEnd: Int, rootDirCluster: Int,
        backupBlock1: Int, backupBlock2: Int, indirectFATClusters: [UInt32], cardType: Int, cardFlags: Int
    ) {
        self.magic = magic
        self.version = version
        self.pageLength = pageLength
        self.pagesPerCluster = pagesPerCluster
        self.pagesPerBlock = pagesPerBlock
        self.clustersPerCard = clustersPerCard
        self.allocOffset = allocOffset
        self.allocEnd = allocEnd
        self.rootDirCluster = rootDirCluster
        self.backupBlock1 = backupBlock1
        self.backupBlock2 = backupBlock2
        self.indirectFATClusters = indirectFATClusters
        self.cardType = cardType
        self.cardFlags = cardFlags
    }

    public var clusterSize: Int { pageLength * pagesPerCluster }

    /// `true` when `magic` matches the expected "Sony PS2 Memory Card
    /// Format" string, checked, but (matching this package's existing
    /// tolerance for `BDArchiveParser`'s `.BH` magic) not required to
    /// proceed, since a hand-crafted or third-party-tool card could
    /// legitimately vary here.
    public var hasExpectedMagic: Bool { magic.hasPrefix("Sony PS2 Memory Card Format") }
}

/// One 8-byte PS2 memory card timestamp (`created`/`modified` on a
/// `MemoryCardEntry`). Stored as separate BCD-free byte fields, not a Unix
/// timestamp, and always in JST (UTC+9) per the format's own convention.
public struct MemoryCardTimestamp: Sendable {
    public var second: Int
    public var minute: Int
    public var hour: Int
    public var day: Int
    public var month: Int
    public var year: Int

    public init(second: Int, minute: Int, hour: Int, day: Int, month: Int, year: Int) {
        self.second = second
        self.minute = minute
        self.hour = hour
        self.day = day
        self.month = month
        self.year = year
    }

    /// `nil` for an all-zero/unset timestamp rather than a bogus 1st-century date.
    public var date: Date? {
        guard year > 0 else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return Calendar(identifier: .gregorian).date(from: components)
    }
}

/// One PS2 memory card directory entry, a file, a directory, or (for the
/// first two children of every directory) the `.`/`..` placeholders. Ported
/// field-for-field from the documented 512-byte `DirEntry` structure.
public struct MemoryCardEntry: Sendable, Identifiable {
    public let id = UUID()
    public var mode: UInt16
    public var length: UInt32
    public var created: MemoryCardTimestamp
    public var cluster: UInt32
    public var modified: MemoryCardTimestamp
    public var attributes: UInt32
    public var name: String
    /// Populated only for directories, after recursively walking their own
    /// cluster chain, empty (not nil) for a file, or for a directory this
    /// parser chose not to descend into (see `MemoryCardParser`'s recursion
    /// guard).
    public var children: [MemoryCardEntry]

    public init(mode: UInt16, length: UInt32, created: MemoryCardTimestamp, cluster: UInt32, modified: MemoryCardTimestamp, attributes: UInt32, name: String, children: [MemoryCardEntry]) {
        self.mode = mode
        self.length = length
        self.created = created
        self.cluster = cluster
        self.modified = modified
        self.attributes = attributes
        self.name = name
        self.children = children
    }

    public var exists: Bool { mode & 0x8000 != 0 }
    public var isDirectory: Bool { mode & 0x0020 != 0 }
    public var isFile: Bool { mode & 0x0010 != 0 }
    public var isProtected: Bool { mode & 0x0008 != 0 }
    public var isHidden: Bool { mode & 0x2000 != 0 }
    public var isPSXFormat: Bool { mode & 0x1000 != 0 }
    /// File size in bytes for a file; for a directory, the PS2 format
    /// repurposes this field as a directory entry count instead, see
    /// `MemoryCardParser`'s directory-walk doc comment.
    public var sizeOrEntryCount: Int { Int(length) }
}

/// A fully decoded PS2 memory card image, rooted at its directory tree.
public struct MemoryCardAsset: Sendable {
    public var superblock: MemoryCardSuperblock
    public var rootEntries: [MemoryCardEntry]
    /// Non-fatal issues found while parsing (e.g. a directory whose cluster
    /// chain didn't terminate cleanly), surfaced in the UI rather than
    /// silently dropped or thrown, matching how `RM2Parser` degrades
    /// unrecognized sections to a raw/undecoded payload instead of failing
    /// the whole file.
    public var warnings: [String]

    public init(superblock: MemoryCardSuperblock, rootEntries: [MemoryCardEntry], warnings: [String]) {
        self.superblock = superblock
        self.rootEntries = rootEntries
        self.warnings = warnings
    }
}
