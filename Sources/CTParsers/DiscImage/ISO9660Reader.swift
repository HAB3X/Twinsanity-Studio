import Foundation
import CTModels

public enum ISO9660Error: Error, Equatable {
    case notAnISO9660Image
}

/// One real entry from a mounted ISO-9660 volume's directory tree , 
/// `lba`/`size` are the record's actual on-disc extent location/length,
/// used by `ISO9660Reader.readFile` to pull the real bytes back out.
public struct ISO9660Entry: Sendable, Identifiable {
    public let id = UUID()
    public var name: String
    public var isDirectory: Bool
    public var lba: UInt32
    public var size: UInt32
    public var children: [ISO9660Entry]
    /// This entry's own directory-record byte offset, absolute within the
    /// flat logical image (`parentDirectoryLBA * 2048 + offsetWithinExtent`)
    ///, for the root entry, the Root Directory Record embedded in the PVD
    /// itself. Used by `ISO9660Writer` to patch a file's LBA/size fields in
    /// place after replacing its contents; not meaningful for anything
    /// else, so no reader call site needs to touch it directly.
    public var directoryRecordAbsoluteOffset: Int

    public init(name: String, isDirectory: Bool, lba: UInt32, size: UInt32, children: [ISO9660Entry] = [], directoryRecordAbsoluteOffset: Int = 0) {
        self.name = name
        self.isDirectory = isDirectory
        self.lba = lba
        self.size = size
        self.children = children
        self.directoryRecordAbsoluteOffset = directoryRecordAbsoluteOffset
    }
}

/// Reads a real ISO-9660 (ECMA-119) volume, the standard, publisher-
/// agnostic CD-ROM filesystem every PS2 disc image uses at its root, not
/// anything specific to Twinsanity. "Native ISO & BIN/CUE Disc Image
/// Mounting" (Task 7), this is what lets a `.iso`/`.bin`+`.cue` be
/// mounted and its real contents (including a real `SYSTEM.CNF`, see
/// `SystemCNFParser`) browsed at all.
///
/// Deliberately narrow: Level 1/2 primary volume descriptor + directory
/// records only, no Rock Ridge/Joliet extensions (a PS2 disc's file tree
/// is plain 8.3-ish ISO-9660, not a Unix/Windows-authored one), and this
/// type itself is read-only, repacking an edited file back into the
/// image in place, patching its directory record's LBA/size (both the
/// LE and BE copies, ECMA-119 7.3.3/7.3.1), is `ISO9660Writer
/// .replacingFile(_:with:in:)`'s job, not this reader's. Real write-back
/// exists and is wired into `WorkspaceViewModel.replacingDiscImage`/
/// `savingPendingLevelViewerEditsToMountedDisc`, `GameLauncher`'s
/// "Save Rebuilt ISO…"/quit-time autosave paths, plain `.iso` only (not
/// raw-sector `.bin`/`.cue`, see `ISO9660Writer`'s own doc comment).
public enum ISO9660Reader {
    private static let sectorSize = 2048
    private static let volumeDescriptorStartSector = 16
    private static let cd001 = Data("CD001".utf8)

    public static func readRootDirectory(from source: any LogicalSectorSource) throws -> ISO9660Entry {
        guard let pvdSectorIndex = findPrimaryVolumeDescriptorSector(in: source), let pvd = source.sector(pvdSectorIndex) else {
            throw ISO9660Error.notAnISO9660Image
        }
        // The Root Directory Record is embedded directly in the PVD at
        // byte offset 156, always exactly 34 bytes (ECMA-119 8.4.24).
        let rootRecord = pvd.subdata(in: (pvd.startIndex + 156)..<(pvd.startIndex + 156 + 34))
        guard let rootLBA = readUInt32LE(rootRecord, at: 2), let rootSize = readUInt32LE(rootRecord, at: 10) else {
            throw ISO9660Error.notAnISO9660Image
        }
        let rootRecordAbsoluteOffset = pvdSectorIndex * sectorSize + 156
        return readDirectory(name: "", lba: rootLBA, size: rootSize, source: source, directoryRecordAbsoluteOffset: rootRecordAbsoluteOffset)
    }

    /// The Primary Volume Descriptor's own Path Table fields (ECMA-119
    /// 8.4.19-8.4.22), real values `ISO9660ImageBuilder` writes but
    /// nothing in this package previously read back. "Image Maker's Path
    /// Tables Verification": without this, the Path Tables `ISO9660ImageBuilder`
    /// writes were only ever checked by eye against the spec, not
    /// independently exercised by any reader, see that type's own doc
    /// comment.
    public struct PrimaryVolumeDescriptorInfo: Sendable {
        public var pathTableByteSize: UInt32
        public var pathTableLBA_L: UInt32
        public var pathTableLBA_M: UInt32
    }

    public static func readPrimaryVolumeDescriptorInfo(from source: any LogicalSectorSource) throws -> PrimaryVolumeDescriptorInfo {
        guard let pvdSectorIndex = findPrimaryVolumeDescriptorSector(in: source), let pvd = source.sector(pvdSectorIndex) else {
            throw ISO9660Error.notAnISO9660Image
        }
        // Path Table Size: byte 132 (both-endian UInt32, LE half used here).
        // Location of Type L Path Table: byte 140 (LE UInt32).
        // Location of the Optional Type L Path Table: byte 144 (unused).
        // Location of Type M Path Table: byte 148 (BE UInt32).
        guard let size = readUInt32LE(pvd, at: 132),
              let lbaL = readUInt32LE(pvd, at: 140),
              let lbaM = readUInt32BE(pvd, at: 148)
        else {
            throw ISO9660Error.notAnISO9660Image
        }
        return PrimaryVolumeDescriptorInfo(pathTableByteSize: size, pathTableLBA_L: lbaL, pathTableLBA_M: lbaM)
    }

    /// One decoded Path Table Record (ECMA-119 8.4.4-8.4.8): a directory's
    /// own name, its parent's 1-based index into this same table, and its
    /// real extent LBA, independent of (and cross-checkable against) the
    /// same directory's own entry in the regular directory-record tree
    /// `readRootDirectory` walks.
    public struct ISO9660PathTableEntry: Sendable {
        public var name: String
        public var parentIndex: UInt16
        public var lba: UInt32
    }

    /// Decodes one whole Path Table (L or M) starting at `lba`, for
    /// `byteSize` real bytes (from `PrimaryVolumeDescriptorInfo.
    /// pathTableByteSize`, the table is sector-padded beyond that, and
    /// nothing in a real image announces how many records precede that
    /// padding).
    public static func readPathTable(from source: any LogicalSectorSource, lba: UInt32, byteSize: UInt32, bigEndian: Bool) -> [ISO9660PathTableEntry] {
        var tableBytes = Data()
        let sectorCount = max(1, Int((Int(byteSize) + sectorSize - 1) / sectorSize))
        for i in 0..<sectorCount {
            guard let sector = source.sector(Int(lba) + i) else { break }
            tableBytes.append(sector)
        }
        var entries: [ISO9660PathTableEntry] = []
        var offset = 0
        while offset + 8 <= Int(byteSize), offset + 8 <= tableBytes.count {
            let nameLength = Int(tableBytes[tableBytes.startIndex + offset])
            guard nameLength > 0, offset + 8 + nameLength <= tableBytes.count else { break }
            let record = tableBytes.subdata(in: (tableBytes.startIndex + offset)..<(tableBytes.startIndex + offset + 8 + nameLength))
            let lbaValue = bigEndian ? readUInt32BE(record, at: 2) : readUInt32LE(record, at: 2)
            let parentValue = bigEndian ? readUInt16BE(record, at: 6) : readUInt16LE(record, at: 6)
            guard let entryLBA = lbaValue, let parentIndex = parentValue else { break }
            let nameBytes = record.subdata(in: (record.startIndex + 8)..<(record.startIndex + 8 + nameLength))
            let name = nameBytes.count == 1 && nameBytes[nameBytes.startIndex] == 0 ? "" : (String(data: nameBytes, encoding: .ascii) ?? "")
            entries.append(ISO9660PathTableEntry(name: name, parentIndex: parentIndex, lba: entryLBA))
            offset += 8 + nameLength + (nameLength % 2 == 0 ? 0 : 1)
        }
        return entries
    }

    /// Extracts `entry`'s real file bytes straight from the volume.
    public static func readFile(_ entry: ISO9660Entry, from source: any LogicalSectorSource) -> Data? {
        guard !entry.isDirectory else { return nil }
        var result = Data()
        // `entry.size` comes straight from the directory record, a
        // corrupt/malformed image could declare a bogus huge size with no
        // real sectors behind it. Cap the up-front reservation at what
        // `source` could possibly contain, so a bad size can't force a
        // multi-gigabyte blind allocation before the per-sector read below
        // (which already returns nil on a genuinely out-of-range sector)
        // gets a chance to fail gracefully.
        let maxPossibleBytes = source.sectorCount * sectorSize
        result.reserveCapacity(min(Int(entry.size), maxPossibleBytes))
        let sectorCount = max(1, Int((Int(entry.size) + sectorSize - 1) / sectorSize))
        for i in 0..<sectorCount {
            guard let sector = source.sector(Int(entry.lba) + i) else { return nil }
            result.append(sector)
        }
        return result.prefix(Int(entry.size))
    }

    private static func findPrimaryVolumeDescriptorSector(in source: any LogicalSectorSource) -> Int? {
        var index = volumeDescriptorStartSector
        // Real bound: the Volume Descriptor Set is always terminated
        // (type 255) well within a few sectors on every real disc; this
        // just keeps a malformed image from spinning forever.
        while index < volumeDescriptorStartSector + 32 {
            guard let sector = source.sector(index) else { return nil }
            let type = sector[sector.startIndex]
            let identifier = sector.subdata(in: (sector.startIndex + 1)..<(sector.startIndex + 6))
            guard identifier == cd001 else { return nil }
            if type == 1 { return index }
            if type == 255 { return nil } // Volume Descriptor Set Terminator
            index += 1
        }
        return nil
    }

    private static func readDirectory(name: String, lba: UInt32, size: UInt32, source: any LogicalSectorSource, directoryRecordAbsoluteOffset: Int) -> ISO9660Entry {
        var extent = Data()
        let sectorCount = max(1, Int((Int(size) + sectorSize - 1) / sectorSize))
        for i in 0..<sectorCount {
            guard let sector = source.sector(Int(lba) + i) else { break }
            extent.append(sector)
        }

        var children: [ISO9660Entry] = []
        var offset = 0
        while offset < extent.count {
            let recordLength = Int(extent[extent.startIndex + offset])
            guard recordLength > 0 else {
                // Zero padding runs to the next sector boundary within a
                // multi-sector directory extent, skip straight to it
                // rather than stepping one zero byte at a time.
                let nextBoundary = ((offset / sectorSize) + 1) * sectorSize
                guard nextBoundary > offset, nextBoundary <= extent.count else { break }
                offset = nextBoundary
                continue
            }
            guard offset + recordLength <= extent.count else { break }
            let record = extent.subdata(in: (extent.startIndex + offset)..<(extent.startIndex + offset + recordLength))
            let recordAbsoluteOffset = Int(lba) * sectorSize + offset
            offset += recordLength

            guard record.count >= 33 else { continue }
            let fileIDLength = Int(record[record.startIndex + 32])
            guard record.count >= 33 + fileIDLength else { continue }
            let fileIDBytes = record.subdata(in: (record.startIndex + 33)..<(record.startIndex + 33 + fileIDLength))
            // Identifier byte 0x00 is "." (self), 0x01 is ".." (parent) , 
            // real ECMA-119 special entries every directory carries,
            // skipped here rather than shown as regular children.
            if fileIDLength == 1, let first = fileIDBytes.first, first == 0 || first == 1 { continue }

            guard let entryLBA = readUInt32LE(record, at: 2), let entrySize = readUInt32LE(record, at: 10) else { continue }
            let flags = record[record.startIndex + 25]
            let isDirectory = (flags & 0x02) != 0
            var entryName = String(data: fileIDBytes, encoding: .ascii) ?? ""
            // Regular (non-directory) identifiers carry a standard
            // ";<version>" suffix (ECMA-119 7.5.1), stripped for display
            // and extension matching, same as every real ISO-9660 browser.
            if !isDirectory, let semicolonIndex = entryName.firstIndex(of: ";") {
                entryName = String(entryName[entryName.startIndex..<semicolonIndex])
            }

            if isDirectory {
                children.append(readDirectory(name: entryName, lba: entryLBA, size: entrySize, source: source, directoryRecordAbsoluteOffset: recordAbsoluteOffset))
            } else {
                children.append(ISO9660Entry(name: entryName, isDirectory: false, lba: entryLBA, size: entrySize, directoryRecordAbsoluteOffset: recordAbsoluteOffset))
            }
        }
        return ISO9660Entry(name: name, isDirectory: true, lba: lba, size: size, children: children, directoryRecordAbsoluteOffset: directoryRecordAbsoluteOffset)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        return UInt32(data[base]) | (UInt32(data[base + 1]) << 8) | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16) | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        let base = data.startIndex + offset
        return (UInt16(data[base]) << 8) | UInt16(data[base + 1])
    }
}
