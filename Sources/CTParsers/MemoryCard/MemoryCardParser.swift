import Foundation
import CTCore
import CTModels

public enum MemoryCardParserError: Error, CustomStringConvertible {
    case tooSmall
    case invalidGeometry

    public var description: String {
        switch self {
        case .tooSmall: return "File is too small to contain a PS2 memory card superblock (340 bytes)."
        case .invalidGeometry: return "Superblock geometry fields (page/cluster sizes, FAT indirection) are internally inconsistent, can't safely walk this card."
        }
    }
}

/// Decodes a PS2 memory card (`.mcr`/`.ps2`) image, "Save State (.mcr /
/// Memory Card) Inspector" (blueprint 7.3). This is the standard,
/// widely-implemented PS2 memory card file system (the same format mymc,
/// PCSX2, and other public tools read), not a Twinsanity-specific format , 
/// unlike the rest of this package, nothing here is grounded in
/// `twinsanity-editor-master`.
///
/// **Cluster addressing has two conventions in play, and mixing them up
/// silently produces plausible-looking garbage rather than an error**, this
/// is the single easiest place to get this format wrong:
/// - The superblock's `ifc_list` (→ `MemoryCardSuperblock.indirectFATClusters`),
///   and the cluster numbers *inside* the indirect-FAT/FAT clusters those
///   entries point to, are **absolute** cluster numbers from the start of
///   the card (cluster 0 = byte 0).
/// - `rootdir_cluster`, every directory entry's own `cluster` field, and
///   every FAT chain-link value are **relative to `alloc_offset`** , 
///   `absoluteCluster = allocOffset + relativeCluster`.
///
/// Verified against two independent public write-ups of this format
/// (ps2savetools.com's structure tables, babyno.top's PS2 memcard-parsing
/// analysis) rather than a single source, since, unlike Twinsanity's
/// formats, verified against the real disc image mounted while this was
/// built, this package has no genuine PS2-written `.mcr` file to test
/// against. `MemoryCardParserTests` pins the byte-level logic with a
/// hand-built synthetic card instead, matching this codebase's existing
/// practice for `VIFInterpreterTests`/`WorldPlacementParserTests`.
public enum MemoryCardParser {
    private static let directoryEntrySize = 512
    private static let superblockSize = 340
    private static let maxDirectoryDepth = 16
    /// Defensive cap on FAT-chain length: a corrupt or maliciously crafted
    /// card could otherwise loop forever if a chain cycles back on itself
    /// (this format has no separate "visited" marker to detect that).
    private static let maxClustersPerChain = 100_000

    public static func parse(data: Data) throws -> MemoryCardAsset {
        guard data.count >= superblockSize else { throw MemoryCardParserError.tooSmall }
        var warnings: [String] = []

        let superblock = try parseSuperblock(data: data)
        guard superblock.pageLength > 0, superblock.pagesPerCluster > 0,
              superblock.clustersPerCard > 0, superblock.clusterSize > 0
        else { throw MemoryCardParserError.invalidGeometry }

        if !superblock.hasExpectedMagic {
            warnings.append("Superblock magic doesn't read \"Sony PS2 Memory Card Format\", parsing anyway, but this may not be a genuine PS2 memory card image.")
        }

        let expectedRawSize = superblock.clusterSize * superblock.clustersPerCard
        if data.count < expectedRawSize {
            warnings.append("File (\(data.count) bytes) is smaller than its own superblock's geometry implies (\(expectedRawSize) bytes), possibly truncated, or a raw ECC dump (528-byte pages) this parser doesn't handle (it assumes plain \(superblock.pageLength)-byte pages, the common PCSX2/mymc dump format).")
        }

        var rootEntries: [MemoryCardEntry] = []
        do {
            rootEntries = try readDirectory(allocRelativeCluster: UInt32(superblock.rootDirCluster), data: data, superblock: superblock, depth: 0)
        } catch {
            warnings.append("Couldn't fully walk the root directory: \(error)")
        }

        return MemoryCardAsset(superblock: superblock, rootEntries: rootEntries, warnings: warnings)
    }

    // MARK: - Superblock

    private static func parseSuperblock(data: Data) throws -> MemoryCardSuperblock {
        var cursor = BinaryCursor(data: data)
        let magic = try cursor.readASCIIString(length: 28).trimmingNulls()
        let version = try cursor.readASCIIString(length: 12).trimmingNulls()
        let pageLength = try cursor.readUInt16()
        let pagesPerCluster = try cursor.readUInt16()
        let pagesPerBlock = try cursor.readUInt16()
        _ = try cursor.readUInt16() // reserved (0xFF00 in a genuine card)
        let clustersPerCard = try cursor.readUInt32()
        let allocOffset = try cursor.readUInt32()
        let allocEnd = try cursor.readUInt32()
        let rootDirCluster = try cursor.readUInt32()
        let backupBlock1 = try cursor.readUInt32()
        let backupBlock2 = try cursor.readUInt32()

        try cursor.seek(to: 0x50)
        var ifcList: [UInt32] = []
        ifcList.reserveCapacity(32)
        for _ in 0..<32 { ifcList.append(try cursor.readUInt32()) }

        try cursor.seek(to: 0x150)
        let cardType = try cursor.readUInt8()
        let cardFlags = try cursor.readUInt8()

        return MemoryCardSuperblock(
            magic: magic,
            version: version,
            pageLength: Int(pageLength),
            pagesPerCluster: Int(pagesPerCluster),
            pagesPerBlock: Int(pagesPerBlock),
            clustersPerCard: Int(clustersPerCard),
            allocOffset: Int(allocOffset),
            allocEnd: Int(allocEnd),
            rootDirCluster: Int(rootDirCluster),
            backupBlock1: Int(backupBlock1),
            backupBlock2: Int(backupBlock2),
            indirectFATClusters: ifcList,
            cardType: Int(cardType),
            cardFlags: Int(cardFlags)
        )
    }

    // MARK: - Cluster access

    /// Reads one `clusterSize`-byte cluster at an **absolute** cluster
    /// number, see this type's doc comment for when that applies.
    private static func readAbsoluteCluster(_ clusterNumber: Int, data: Data, superblock: MemoryCardSuperblock) throws -> Data {
        let clusterSize = superblock.clusterSize
        // `clusterNumber` traces back to raw on-disk fields (directory
        // entries, FAT/indirect-FAT tables) with no validation against the
        // card's real geometry -- a corrupt `.mcr`/`.ps2` file can make this
        // product overflow `Int`, which traps rather than throwing. Using
        // `multipliedReportingOverflow` keeps that a catchable parse error
        // like every other malformed-geometry case here.
        let (byteOffset, overflowed) = clusterNumber.multipliedReportingOverflow(by: clusterSize)
        guard !overflowed, byteOffset >= 0, byteOffset + clusterSize <= data.count else {
            throw MemoryCardParserError.invalidGeometry
        }
        return data.subdata(in: (data.startIndex + byteOffset)..<(data.startIndex + byteOffset + clusterSize))
    }

    /// Reads one cluster at an `alloc_offset`-relative cluster number, see
    /// this type's doc comment for when that applies.
    private static func readAllocRelativeCluster(_ clusterNumber: UInt32, data: Data, superblock: MemoryCardSuperblock) throws -> Data {
        // Both operands are widened to `Int` before adding -- `allocOffset`
        // and `clusterNumber` are each independently untrusted, disk-derived
        // values, and adding them as `UInt32` (as this used to) traps if
        // their sum overflows 32 bits instead of surfacing a parse error.
        try readAbsoluteCluster(superblock.allocOffset + Int(clusterNumber), data: data, superblock: superblock)
    }

    /// Resolves the FAT entry for an `alloc_offset`-relative cluster index
    /// via the format's two-level indirect scheme: `ifc_list[dblIndirectIndex]`
    /// names an absolute indirect-FAT cluster; its `indirectOffset`'th
    /// 32-bit entry names an absolute FAT cluster; that FAT cluster's
    /// `fatOffset`'th 32-bit entry is the actual value, either the next
    /// cluster in the chain (alloc-relative, high bit set) or `0xFFFFFFFF`
    /// for end-of-chain.
    private static func fatEntry(for allocRelativeClusterIndex: UInt32, data: Data, superblock: MemoryCardSuperblock) throws -> UInt32 {
        let entriesPerCluster = UInt32(superblock.clusterSize / 4)
        guard entriesPerCluster > 0 else { throw MemoryCardParserError.invalidGeometry }

        let fatOffset = allocRelativeClusterIndex % entriesPerCluster
        let indirectIndex = allocRelativeClusterIndex / entriesPerCluster
        let indirectOffset = indirectIndex % entriesPerCluster
        let dblIndirectIndex = Int(indirectIndex / entriesPerCluster)

        guard dblIndirectIndex >= 0, dblIndirectIndex < superblock.indirectFATClusters.count else {
            throw MemoryCardParserError.invalidGeometry
        }
        let indirectFATCluster = try readAbsoluteCluster(Int(superblock.indirectFATClusters[dblIndirectIndex]), data: data, superblock: superblock)
        var indirectCursor = BinaryCursor(data: indirectFATCluster, startPosition: Int(indirectOffset) * 4)
        let fatClusterNumber = try indirectCursor.readUInt32()

        let fatCluster = try readAbsoluteCluster(Int(fatClusterNumber), data: data, superblock: superblock)
        var fatCursor = BinaryCursor(data: fatCluster, startPosition: Int(fatOffset) * 4)
        return try fatCursor.readUInt32()
    }

    // MARK: - Directories

    /// Walks one directory's full cluster chain (via the FAT), concatenates
    /// every 512-byte `DirEntry` across every cluster in order, then
    /// interprets that flat list per the format's own convention: entry 0
    /// is the directory's own self-entry (its `length` field holds the
    /// *total* entry count for this directory, including itself and the
    /// `..` placeholder that always follows it at entry 1), real children
    /// start at entry 2.
    private static func readDirectory(allocRelativeCluster: UInt32, data: Data, superblock: MemoryCardSuperblock, depth: Int) throws -> [MemoryCardEntry] {
        guard depth < maxDirectoryDepth else { return [] }

        var entryBlocks: [Data] = []
        var currentCluster: UInt32? = allocRelativeCluster
        var visited = 0
        while let cluster = currentCluster, visited < maxClustersPerChain {
            visited += 1
            let clusterData = try readAllocRelativeCluster(cluster, data: data, superblock: superblock)
            var offset = 0
            while offset + directoryEntrySize <= clusterData.count {
                entryBlocks.append(clusterData.subdata(in: (clusterData.startIndex + offset)..<(clusterData.startIndex + offset + directoryEntrySize)))
                offset += directoryEntrySize
            }
            let fat = try fatEntry(for: cluster, data: data, superblock: superblock)
            currentCluster = (fat == 0xFFFF_FFFF || fat & 0x8000_0000 == 0) ? nil : (fat & 0x7FFF_FFFF)
        }

        guard !entryBlocks.isEmpty else { return [] }
        let selfEntry = try parseEntry(entryBlocks[0])
        let declaredCount = max(2, selfEntry.sizeOrEntryCount)
        let usableCount = min(declaredCount, entryBlocks.count)
        guard usableCount > 2 else { return [] }

        var results: [MemoryCardEntry] = []
        results.reserveCapacity(usableCount - 2)
        for index in 2..<usableCount {
            var entry = try parseEntry(entryBlocks[index])
            guard entry.exists else { continue }
            if entry.isDirectory {
                entry.children = (try? readDirectory(allocRelativeCluster: entry.cluster, data: data, superblock: superblock, depth: depth + 1)) ?? []
            }
            results.append(entry)
        }
        return results
    }

    private static func parseEntry(_ bytes: Data) throws -> MemoryCardEntry {
        var cursor = BinaryCursor(data: bytes)
        let mode = try cursor.readUInt16()
        _ = try cursor.readUInt16() // padding to 0x04
        let length = try cursor.readUInt32()
        let created = try readTimestamp(&cursor)
        let cluster = try cursor.readUInt32()
        _ = try cursor.readUInt32() // parent dir_entry index, not currently surfaced
        let modified = try readTimestamp(&cursor)
        let attributes = try cursor.readUInt32()
        try cursor.seek(to: 0x40)
        let name = try cursor.readCString(maxLength: 32)

        return MemoryCardEntry(mode: mode, length: length, created: created, cluster: cluster, modified: modified, attributes: attributes, name: name, children: [])
    }

    private static func readTimestamp(_ cursor: inout BinaryCursor) throws -> MemoryCardTimestamp {
        _ = try cursor.readUInt8() // unused
        let second = try cursor.readUInt8()
        let minute = try cursor.readUInt8()
        let hour = try cursor.readUInt8()
        let day = try cursor.readUInt8()
        let month = try cursor.readUInt8()
        let year = try cursor.readUInt16()
        return MemoryCardTimestamp(second: Int(second), minute: Int(minute), hour: Int(hour), day: Int(day), month: Int(month), year: Int(year))
    }
}

private extension String {
    func trimmingNulls() -> String {
        if let nullIndex = firstIndex(of: "\0") { return String(self[startIndex..<nullIndex]) }
        return self
    }
}
