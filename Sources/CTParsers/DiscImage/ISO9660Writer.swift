import Foundation
import CTModels

public enum ISO9660WriterError: Error, LocalizedError, Equatable {
    /// The entry's declared extent (from its own directory record) or its
    /// own directory-record offset don't fit inside the image bytes
    /// actually supplied, a mismatched/corrupt image, not a real file to
    /// patch.
    case entryOutOfBounds

    public var errorDescription: String? {
        switch self {
        case .entryOutOfBounds: return "This entry's real on-disc location doesn't fit inside the supplied image, it may not be the same image this entry was read from."
        }
    }
}

/// Rebuilds a modified `.iso` image with one file's contents replaced , 
/// the write-back counterpart to `ISO9660Reader`. Deliberately scoped to
/// plain `.iso` images only, not `.bin`/`.cue`: a raw-sector `.bin` image
/// additionally frames every 2048-byte logical sector inside a larger
/// (typically 2352-byte) raw sector with sync/header/ECC/EDC data that
/// would need to be correctly regenerated per sector on write, real,
/// separate work this doesn't attempt. Read a `.bin`/`.cue` pair through
/// `BinCueLogicalSource` as before; only rebuilding one back out isn't
/// supported here.
///
/// Two real strategies, chosen automatically by the new data's size , 
/// standard ISO-9660 doesn't require a file's extent to be contiguous
/// with its own directory record, or with any other file, so neither
/// strategy needs to touch anything beyond the one directory record for
/// the file being replaced:
/// - **Same size or smaller**: patches the file's bytes in place at its
///   existing LBA (zero-padding the rest of its originally-reserved
///   sectors) and updates just the size field in its directory record.
///   No other bytes in the image move.
/// - **Larger**: sector-aligns, then appends fresh sectors onto the true
///   end of the image.
///
/// A real, measured, and far more serious bug this deliberately does
/// *not* do: an earlier version of this reused "gaps", byte ranges the
/// image's own ISO9660 directory tree doesn't reference, found anywhere
/// in the image, on the theory that anything no live file or directory
/// points at must be safe filler. Verified false against a real retail
/// disc: this game's disc carries only ~45 files in its entire ISO9660
/// tree (virtually everything else lives inside the one huge `.BD`
/// archive this very code relocates), and the multi-hundred-thousand-
/// sector byte range between two of those tracked files, that the old gap
/// scan confidently reused for a relocated `.BD`, is not padding:
/// sampling it on the untouched retail disc shows every sector dense with
/// real, non-zero, structured data. Something reads that range by a
/// mechanism this project has no visibility into (almost certainly direct
/// sector access below the ISO9660 layer, bypassing the directory tree
/// the old scan trusted as authoritative), and overwriting it with a
/// relocated archive reproduced, byte for byte, the exact "boots fine
/// through the intro, plays FMV, then TLB-Misses on a null pointer and
/// hangs forever" failure this project's own real-PCSX2 boot tests kept
/// hitting. Reusing space a scan merely *inferred* was unused is
/// therefore never a safe general strategy on a real PS2 disc.
///
/// **"Self-Reclaiming Relocation", the real, separate fix for file
/// bloat.** The gap-scan bug above and this are not the same class of
/// risk, and must not be conflated: a scanned "gap" is a byte range this
/// writer has no history with, reusing it means trusting an *inference*
/// ("nothing in the directory tree points here") that this exact disc
/// already proved wrong. A file's own *current* extent, by contrast, is
/// never an inference, `entry.lba`/`entry.size` are read directly from
/// this exact image's own currently-valid directory record for the exact
/// file about to be replaced, moments before its bytes are overwritten;
/// nothing else in a standards-compliant ISO-9660 tree can legally
/// reference those bytes once this call finishes repointing that one
/// directory record elsewhere. So whenever a file's own current extent
/// happens to be the image's *true tail* (nothing real follows it, the
/// common case after this exact file was itself relocated to the end on
/// a *previous* save, which is exactly what every repeated "edit, then
/// repackage and boot" cycle on this app's own `.BD` archive does), both
/// `replaceInPlace` and `appendAndRelocate` physically shrink the image
/// back to just before that extent *first*, before writing the
/// replacement, turning what used to be "grow forever, one full-size
/// orphaned copy per save" into "the image only ever grows past its
/// current real content once, the first time a file outgrows whatever
/// space happens to already follow it." When a file's current extent is
/// *not* the true tail (something else real still follows it, most
/// often true only on the very first relocation of a given file), this
/// still never touches a single byte beyond that one file's own known
/// extent, falling back to the same append-past-the-end behavior as
/// before: exactly as safe as the gap-scan fix above, just no longer
/// wasteful in the overwhelmingly common repeated-edit case.
public enum ISO9660Writer {
    private static let sectorSize = 2048

    /// - Parameters:
    ///   - entry: An `ISO9660Entry` read from `imageData` itself via
    ///     `ISO9660Reader`, its `lba`/`size`/`directoryRecordAbsoluteOffset`
    ///     all have to be real positions inside `imageData`, not a
    ///     different copy of the same disc.
    ///   - newData: The file's replacement contents.
    ///   - imageData: The full, flat, plain-`.iso` image bytes.
    /// - Returns: A new, complete image with the one file replaced.
    public static func replacingFile(_ entry: ISO9660Entry, with newData: Data, in imageData: Data) throws -> Data {
        var image = imageData
        if newData.count <= Int(entry.size) {
            try replaceInPlace(entry, with: newData, in: &image)
        } else {
            try appendAndRelocate(entry, with: newData, in: &image)
        }
        return image
    }

    private static func replaceInPlace(_ entry: ISO9660Entry, with newData: Data, in image: inout Data) throws {
        let byteOffset = Int(entry.lba) * sectorSize
        // The number of sectors originally reserved for this file, the
        // space available to zero-pad into without touching whatever
        // follows.
        let reservedSpan = sectorCount(for: Int(entry.size)) * sectorSize
        guard byteOffset >= 0, byteOffset + reservedSpan <= image.count else {
            throw ISO9660WriterError.entryOutOfBounds
        }

        // "Self-Reclaiming Relocation" (see this file's own top-level doc
        // comment): if this entry's own current extent is the image's real
        // tail, shrink the new reservation down to exactly what the
        // (smaller-or-equal) replacement needs, physically freeing the
        // difference instead of leaving it behind as permanent zero-padded
        // waste. Only possible here at all because `newData.count <=
        // entry.size` is this function's own calling contract
        // (`replacingFile`'s size check), the replacement can only ever
        // need the same span or less, never more.
        let isCurrentTail = byteOffset + reservedSpan == image.count
        let effectiveSpan = isCurrentTail ? sectorCount(for: newData.count) * sectorSize : reservedSpan

        var padded = newData
        padded.append(Data(repeating: 0, count: max(0, effectiveSpan - newData.count)))

        if isCurrentTail, effectiveSpan < reservedSpan {
            // Same real Foundation risk `appendAndRelocate`'s own reclaim
            // step documents (reproduced independently of any ISO9660
            // logic: a shrinking mutation on a buffer whose *total* size
            // is past roughly 2GB can crash `Data.removeSubrange` outright
            //, `replaceSubrange` shrinking a range is the same class of
            // in-place resize, so this takes the same safer path rather
            // than risk it too: build the result from two independently-
            // allocated pieces (the untouched prefix, copied via
            // `subdata(in:)`, plus the new padded content) and reassign,
            // instead of mutating the existing multi-gigabyte buffer in
            // place.
            var result = image.subdata(in: image.startIndex..<(image.startIndex + byteOffset))
            result.append(padded)
            image = result
        } else {
            let range = (image.startIndex + byteOffset)..<(image.startIndex + byteOffset + reservedSpan)
            image.replaceSubrange(range, with: padded)
        }
        try patchDirectoryRecord(at: entry.directoryRecordAbsoluteOffset, lba: entry.lba, size: UInt32(newData.count), in: &image)

        // Only the tail-shrink case actually changes the image's total
        // sector count, the ordinary "reuse the same reserved span"
        // branch above never does, matching the pre-existing behavior this
        // function has always had for a same-size-or-smaller replacement.
        if isCurrentTail, effectiveSpan < reservedSpan {
            patchVolumeSpaceSize(totalSectors: UInt32(image.count / sectorSize), in: &image)
        }
    }

    private static func appendAndRelocate(_ entry: ISO9660Entry, with newData: Data, in image: inout Data) throws {
        let paddedSize = sectorCount(for: newData.count) * sectorSize
        var padded = newData
        padded.append(Data(repeating: 0, count: paddedSize - newData.count))

        // "Self-Reclaiming Relocation" (see this file's own top-level doc
        // comment): if this entry's own current extent is the image's real
        // tail, physically free it *before* appending, this never touches
        // any byte range beyond the one this exact entry's own directory
        // record currently claims, moments before that record gets
        // repointed elsewhere by `patchDirectoryRecord` below. When it
        // isn't the tail (something else real still follows it), this is a
        // no-op and behavior is unchanged from the plain append-past-the-
        // end this writer has always done.
        let oldByteOffset = Int(entry.lba) * sectorSize
        let oldReservedSpan = sectorCount(for: Int(entry.size)) * sectorSize
        if oldByteOffset >= 0, oldByteOffset + oldReservedSpan == image.count {
            // Real, measured Foundation issue (not a bug in this project's
            // own logic): `Data.removeSubrange` on a buffer whose *total*
            // size is past roughly 2GB can crash outright (reproduced with
            // a minimal, ISO9660-free repro: a plain `Data(repeating:count:)`
            // buffer around 2.8GB, `removeSubrange` on a large trailing
            // range, SIGTRAP, every time). `subdata(in:)`, building a
            // fresh, independently-allocated `Data` for just the retained
            // prefix, then reassigning `image` to it, performs the exact
            // same logical truncation without ever calling the crashing
            // API, confirmed against that same repro (same buffer size,
            // completes in well under a second). This matters here
            // specifically because it's the code path a real ~900MB `.BD`
            // archive on a ~3GB disc image actually exercises the moment
            // its own prior relocation makes it eligible for reclaiming.
            image = image.subdata(in: image.startIndex..<(image.startIndex + oldByteOffset))
        }

        // Sector-align, then append fresh sectors onto the true end of the
        // image, see this file's own top-level doc comment for why this
        // never reuses any *other* byte range.
        let paddingToAlign = (sectorSize - (image.count % sectorSize)) % sectorSize
        if paddingToAlign > 0 { image.append(Data(repeating: 0, count: paddingToAlign)) }
        let newLBA = UInt32(image.count / sectorSize)
        image.append(padded)

        try patchDirectoryRecord(at: entry.directoryRecordAbsoluteOffset, lba: newLBA, size: UInt32(newData.count), in: &image)

        // A real, measured bug: appending (or, now, reclaiming-then-
        // appending) grows or shrinks the image relative to whatever the
        // Primary Volume Descriptor's own "Volume Space Size" field
        // (ECMA-119 8.4.8) declared at read time, every earlier write path
        // here only ever patched the one file's own directory record, never
        // the PVD. On a real archive-replacement rebuild (any edit that
        // changes the repackaged `.BD`'s total byte size, effectively
        // every real "launch with my edits" use of `GameLaunchPlan.
        // archiveReplacements`, since the replaced archive is almost never
        // byte-identical in length to the original), the relocated data
        // would otherwise land entirely *beyond* the volume's own
        // previously-declared extent (or, after reclaiming, inside a now-
        // smaller image the old declared size overstates). Either mismatch
        // risks a real ISO-9660 reader (and very plausibly the PS2's own
        // low-level CDVD driver, which this project has no way to inspect
        // the source of) treating reads against the wrong declared extent
        // as invalid, at best undefined behavior, at worst exactly the
        // kind of erratic, repeated-retry I/O stalling that would look
        // like "the game loads at 2fps" after booting a rebuilt disc.
        // Keeping this field in sync with the image's real total size on
        // every relocation is required by the spec regardless.
        patchVolumeSpaceSize(totalSectors: UInt32(image.count / sectorSize), in: &image)
    }

    /// Overwrites the Primary Volume Descriptor's Volume Space Size field
    /// (ECMA-119 8.4.8, PVD byte offset 80, both-endian `UInt32`, same
    /// dual LE/BE convention as every other multi-byte field here) with the
    /// image's current real total sector count. The PVD is always the
    /// sector immediately after the 16-sector system area on every disc
    /// this writer has ever produced or patched (`ISO9660Reader`'s own
    /// `volumeDescriptorStartSector` makes the same assumption when
    /// *reading*), scanned for defensively anyway, the same bounded
    /// CD001-magic/type-1 walk `ISO9660Reader.findPrimaryVolumeDescriptorSector`
    /// uses, rather than hardcoding sector 16, in case some disc genuinely
    /// carries other volume descriptors before it. A no-op (not a throw) if
    /// no PVD is found, this runs from inside an append that already
    /// succeeded; failing to keep a secondary bookkeeping field in sync
    /// shouldn't turn an otherwise-valid patch into a hard error.
    private static func patchVolumeSpaceSize(totalSectors: UInt32, in image: inout Data) {
        var sectorIndex = 16
        while sectorIndex < 16 + 32 {
            let base = sectorIndex * sectorSize
            guard base + sectorSize <= image.count else { return }
            let idOffset = image.startIndex + base + 1
            guard idOffset + 5 <= image.endIndex, image[idOffset..<(idOffset + 5)] == cd001Magic else { return }
            let type = image[image.startIndex + base]
            if type == 1 {
                writeBothEndianUInt32(totalSectors, at: image.startIndex + base + 80, in: &image)
                return
            }
            if type == 255 { return } // Volume Descriptor Set Terminator, no PVD found
            sectorIndex += 1
        }
    }

    private static let cd001Magic = Data("CD001".utf8)

    private static func sectorCount(for byteCount: Int) -> Int {
        max(1, (byteCount + sectorSize - 1) / sectorSize)
    }

    /// Overwrites the LBA (record bytes 2-9) and size (bytes 10-17)
    /// fields of one directory record in place, both fields are stored
    /// twice, little-endian then big-endian (ECMA-119 7.3.3/7.3.1), so
    /// both copies get written, not just the little-endian half
    /// `ISO9660Reader` reads.
    private static func patchDirectoryRecord(at offset: Int, lba: UInt32, size: UInt32, in image: inout Data) throws {
        guard offset >= 0, offset + 34 <= image.count else { throw ISO9660WriterError.entryOutOfBounds }
        let base = image.startIndex + offset
        writeBothEndianUInt32(lba, at: base + 2, in: &image)
        writeBothEndianUInt32(size, at: base + 10, in: &image)
    }

    private static func writeBothEndianUInt32(_ value: UInt32, at offset: Int, in image: inout Data) {
        let le: [UInt8] = [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        for (i, byte) in le.enumerated() { image[offset + i] = byte }
        for (i, byte) in le.reversed().enumerated() { image[offset + 4 + i] = byte }
    }
}

// MARK: - Building a brand-new image from a directory tree

/// Builds a complete, standards-compliant ISO-9660 (ECMA-119) image from a
/// directory tree, "Image Maker," the one piece of the reference tool
/// this project's own reverse-engineering couldn't reach: `ImageMaker.cs`
/// is a thin UI shell over `Externals/PS2ImageMaker/PS2ImageMaker.cs`,
/// which is itself only a P/Invoke shim around a native `PS2ImageMaker.dll`
/// whose source isn't in the reference repository at all, there is
/// nothing to port the real sector-writing algorithm from. Rather than
/// fabricate a PS2-specific boot-sector format with no source to verify it
/// against (the one thing this project's own culture refuses to do, see
/// every "confirmed vs. hypothesis" doc comment elsewhere in this
/// package), this instead implements the real, public ECMA-119 standard
/// PS2 discs are built on: Primary Volume Descriptor, Path Tables (L and
/// M), and a real recursive directory tree, the part of "building a
/// bootable-shaped disc" this project *can* verify, byte-for-byte, against
/// a public spec and its own `ISO9660Reader`.
///
/// **What "verified" means here, honestly**: every directory record this
/// writes round-trips exactly through this package's own `ISO9660Reader`
/// (same discipline as every other writer in this codebase), proven by
/// `ISO9660WriterBuildImageTests`. The Path Tables (real CD-ROM drivers/
/// BIOS implementations generally walk directory records directly and
/// treat the path table as an optional lookup optimization, not a
/// requirement, so a disc missing this verification could still browse
/// and boot fine) are now also independently exercised: `ISO9660Reader.
/// readPathTable`/`readPrimaryVolumeDescriptorInfo` decode both the Type L
/// and Type M tables back out, and `ISO9660ImageBuilderTests` cross-checks
/// every entry's name/parent-chain/LBA against the same directories'
/// own, separately-verified directory records, not just that the two
/// tables agree with each other, but that they agree with the actual disc
/// layout. A disc built this way has been verified to actually **boot** in
/// a real PCSX2 build (`ImageMakerBootVerificationTests`, real staged
/// retail files, real PCSX2 process, asserting on PCSX2's own log for a
/// correctly-resolved boot path, the real retail boot ELF's CRC, IOP
/// module registration, and accumulated play time). Real PS2 hardware is
/// still unverified, that's the one thing this project has never had
/// access to.
public enum ISO9660ImageBuilder {
    private static let sectorSize = 2048

    private final class DirNode {
        let name: String
        var files: [(name: String, url: URL, size: Int)] = []
        var subdirectories: [DirNode] = []
        weak var parent: DirNode?
        var lba: UInt32 = 0
        var extentSize: UInt32 = 0
        var pathTableIndex: UInt16 = 1
        init(name: String, parent: DirNode?) {
            self.name = name
            self.parent = parent
        }
    }

    /// Builds a complete image containing every regular file under
    /// `sourceDirectory`, preserving its subfolder structure. `volumeLabel`
    /// fills the Primary Volume Descriptor's Volume Identifier (space-
    /// padded/truncated to 32 d-characters, the real ECMA-119 field width).
    public static func buildingImage(from sourceDirectory: URL, volumeLabel: String) throws -> Data {
        let root = try scanDirectory(sourceDirectory, name: "", parent: nil)
        let allDirs = breadthFirst(root)
        for (index, dir) in allDirs.enumerated() { dir.pathTableIndex = UInt16(index + 1) }

        // Pass 1: every directory's own extent size, depends only on its
        // children's names (record lengths), never on any LBA, so this is
        // safe to compute before any LBA is assigned.
        for dir in allDirs { dir.extentSize = UInt32(directoryExtentByteSize(dir)) }

        // Pass 2: lay out the volume, system area, PVD, terminator, both
        // path tables (each padded to a whole number of sectors), every
        // directory extent (parent before children, matching
        // `allDirs`' breadth-first order), then every file's data,
        // sequentially. Nothing here depends on file *contents*, only
        // sizes, so file bytes are read lazily in the final byte-emission
        // pass below, not held in memory all at once.
        var nextLBA: UInt32 = 18 // sectors 0-15 system area, 16 PVD, 17 terminator
        let pathTableEntries = allDirs.map { PathTableEntry(name: $0 === root ? "\0" : $0.name, parentIndex: ($0.parent.map { $0.pathTableIndex } ?? 1)) }
        let pathTableByteSize = pathTableEntries.reduce(0) { $0 + pathTableRecordSize(nameLength: $1.name == "\0" ? 1 : $1.name.utf8.count) }
        let pathTableSectorCount = sectorCount(for: pathTableByteSize)
        let pathTableLBA_L = nextLBA
        nextLBA += UInt32(pathTableSectorCount)
        let pathTableLBA_M = nextLBA
        nextLBA += UInt32(pathTableSectorCount)

        for dir in allDirs {
            dir.lba = nextLBA
            nextLBA += UInt32(sectorCount(for: Int(dir.extentSize)))
        }
        var fileLayout: [(dir: DirNode, name: String, url: URL, lba: UInt32, size: Int)] = []
        var fileLBAs: [ObjectIdentifier: [String: UInt32]] = [:]
        for dir in allDirs {
            for file in dir.files {
                fileLayout.append((dir, file.name, file.url, nextLBA, file.size))
                fileLBAs[ObjectIdentifier(dir), default: [:]][file.name] = nextLBA
                nextLBA += UInt32(sectorCount(for: file.size))
            }
        }
        let totalSectors = nextLBA

        // Pass 3: emit every byte, now that every LBA is known.
        var image = Data(repeating: 0, count: Int(totalSectors) * sectorSize)
        writePrimaryVolumeDescriptor(
            into: &image, volumeLabel: volumeLabel, totalSectors: totalSectors,
            rootLBA: root.lba, rootSize: root.extentSize,
            pathTableSize: UInt32(pathTableByteSize), pathTableLBA_L: pathTableLBA_L, pathTableLBA_M: pathTableLBA_M
        )
        writeVolumeDescriptorSetTerminator(into: &image)
        writePathTable(entries: pathTableEntries, dirs: allDirs, bigEndian: false, at: Int(pathTableLBA_L) * sectorSize, into: &image)
        writePathTable(entries: pathTableEntries, dirs: allDirs, bigEndian: true, at: Int(pathTableLBA_M) * sectorSize, into: &image)
        for dir in allDirs {
            writeDirectoryExtent(dir, fileLBAs: fileLBAs, into: &image)
        }
        for entry in fileLayout {
            let data = (try? Data(contentsOf: entry.url)) ?? Data()
            let start = Int(entry.lba) * sectorSize
            image.replaceSubrange((image.startIndex + start)..<(image.startIndex + start + data.count), with: data)
        }
        return image
    }

    // MARK: - Directory scan

    private static func scanDirectory(_ url: URL, name: String, parent: DirNode?) throws -> DirNode {
        let node = DirNode(name: name, parent: parent)
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
            .sorted { $0.lastPathComponent.uppercased() < $1.lastPathComponent.uppercased() }
        for childURL in contents {
            let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                node.subdirectories.append(try scanDirectory(childURL, name: childURL.lastPathComponent.uppercased(), parent: node))
            } else {
                let size = (try? childURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                node.files.append((childURL.lastPathComponent.uppercased(), childURL, size))
            }
        }
        return node
    }

    /// Breadth-first, root first, the real ECMA-119 9.4 path-table
    /// ordering requirement ("for each level... in ascending order," each
    /// parent's own record preceding every one of its children's).
    private static func breadthFirst(_ root: DirNode) -> [DirNode] {
        var result: [DirNode] = []
        var queue = [root]
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            result.append(dir)
            queue.append(contentsOf: dir.subdirectories)
        }
        return result
    }

    private static func sectorCount(for byteCount: Int) -> Int {
        max(1, (byteCount + sectorSize - 1) / sectorSize)
    }

    // MARK: - Directory records

    /// One directory's own extent size in bytes: "." + ".." + every child
    /// (subdirectory or file) as its own directory record, each padded to
    /// even length, with records never allowed to span a sector boundary
    /// (ECMA-119 6.8.1.2), the running byte offset jumps to the next
    /// sector boundary whenever a record wouldn't otherwise fit, same as
    /// `ISO9660Reader.readDirectory`'s own zero-padding-skip logic on the
    /// read side.
    /// ECMA-119 6.8.2.1: every record in a directory (subdirectories and
    /// files together, not directories-then-files) shall be sorted
    /// ascending by File Identifier, merged and sorted here rather than
    /// emitted as two separate blocks.
    private static func sortedChildNames(_ dir: DirNode) -> [(name: String, isDirectory: Bool)] {
        let dirNames = dir.subdirectories.map { (name: $0.name, isDirectory: true) }
        let fileNames = dir.files.map { (name: $0.name + ";1", isDirectory: false) }
        return (dirNames + fileNames).sorted { $0.name < $1.name }
    }

    private static func directoryExtentByteSize(_ dir: DirNode) -> Int {
        var offset = 0
        func place(_ recordSize: Int) {
            if offset % sectorSize != 0, (offset % sectorSize) + recordSize > sectorSize {
                offset = ((offset / sectorSize) + 1) * sectorSize
            }
            offset += recordSize
        }
        place(directoryRecordSize(nameLength: 1)) // "."
        place(directoryRecordSize(nameLength: 1)) // ".."
        for child in sortedChildNames(dir) { place(directoryRecordSize(nameLength: child.name.utf8.count)) }
        return sectorCount(for: offset) * sectorSize
    }

    private static func directoryRecordSize(nameLength: Int) -> Int {
        let base = 33 + nameLength
        return base + (base % 2 == 0 ? 0 : 1) // pad to even total length
    }

    private static func writeDirectoryExtent(_ dir: DirNode, fileLBAs: [ObjectIdentifier: [String: UInt32]], into image: inout Data) {
        let base = Int(dir.lba) * sectorSize
        var offset = 0
        func place(_ record: Data) {
            if offset % sectorSize != 0, (offset % sectorSize) + record.count > sectorSize {
                offset = ((offset / sectorSize) + 1) * sectorSize
            }
            image.replaceSubrange((image.startIndex + base + offset)..<(image.startIndex + base + offset + record.count), with: record)
            offset += record.count
        }
        let parentLBA = dir.parent?.lba ?? dir.lba
        let parentSize = dir.parent?.extentSize ?? dir.extentSize
        place(directoryRecord(identifierByte: 0x00, lba: dir.lba, size: dir.extentSize, isDirectory: true)) // "."
        place(directoryRecord(identifierByte: 0x01, lba: parentLBA, size: parentSize, isDirectory: true)) // ".."
        // Real bug fix: `scanDirectory` uppercases every name (ISO9660's
        // own real naming convention) with no collision check, two real
        // source files differing only by case (a legitimate, if unusual,
        // possibility on a case-sensitive volume, or from content
        // extracted out of an archive that itself had such a collision)
        // would both uppercase to the same name and trap the old
        // `Dictionary(uniqueKeysWithValues:)` here outright. `reduce(into:)`
        // with first-wins on a real duplicate can't crash the same way , 
        // the entry that sorted first (`scanDirectory`'s own
        // case-insensitive sort) simply wins, matching normal case-
        // insensitive-filesystem "one of these two names" semantics
        // instead of refusing to build the disc image at all.
        let subsByName = dir.subdirectories.reduce(into: [String: DirNode]()) { result, sub in
            if result[sub.name] == nil { result[sub.name] = sub }
        }
        let filesByName = dir.files.reduce(into: [String: (name: String, url: URL, size: Int)]()) { result, file in
            if result[file.name] == nil { result[file.name] = file }
        }
        for child in sortedChildNames(dir) {
            if child.isDirectory, let sub = subsByName[child.name] {
                place(directoryRecord(name: sub.name, lba: sub.lba, size: sub.extentSize, isDirectory: true))
            } else if !child.isDirectory {
                let baseName = String(child.name.dropLast(2)) // strip the ";1" version suffix back off
                if let file = filesByName[baseName] {
                    let lba = fileLBAs[ObjectIdentifier(dir)]?[file.name] ?? 0
                    place(directoryRecord(name: child.name, lba: lba, size: UInt32(file.size), isDirectory: false))
                }
            }
        }
    }

    private static func directoryRecord(identifierByte: UInt8, lba: UInt32, size: UInt32, isDirectory: Bool) -> Data {
        directoryRecord(nameBytes: [identifierByte], lba: lba, size: size, isDirectory: isDirectory)
    }

    private static func directoryRecord(name: String, lba: UInt32, size: UInt32, isDirectory: Bool) -> Data {
        directoryRecord(nameBytes: Array(name.utf8), lba: lba, size: size, isDirectory: isDirectory)
    }

    private static func directoryRecord(nameBytes: [UInt8], lba: UInt32, size: UInt32, isDirectory: Bool) -> Data {
        var record = Data(count: directoryRecordSize(nameLength: nameBytes.count))
        record[record.startIndex] = UInt8(record.count)
        record[record.startIndex + 1] = 0 // extended attribute record length
        writeBothEndianUInt32Data(lba, at: 2, in: &record)
        writeBothEndianUInt32Data(size, at: 10, in: &record)
        writeRecordingDateTime(at: 18, in: &record)
        record[record.startIndex + 25] = isDirectory ? 0x02 : 0x00
        record[record.startIndex + 26] = 0 // file unit size
        record[record.startIndex + 27] = 0 // interleave gap size
        writeBothEndianUInt16Data(1, at: 28, in: &record) // volume sequence number
        record[record.startIndex + 32] = UInt8(nameBytes.count)
        for (i, byte) in nameBytes.enumerated() { record[record.startIndex + 33 + i] = byte }
        return record
    }

    // MARK: - Path tables

    private struct PathTableEntry { let name: String; let parentIndex: UInt16 }

    private static func pathTableRecordSize(nameLength: Int) -> Int {
        8 + nameLength + (nameLength % 2 == 0 ? 0 : 1)
    }

    private static func writePathTable(entries: [PathTableEntry], dirs: [DirNode], bigEndian: Bool, at byteOffset: Int, into image: inout Data) {
        var offset = byteOffset
        for (entry, dir) in zip(entries, dirs) {
            let nameBytes: [UInt8] = entry.name == "\0" ? [0] : Array(entry.name.utf8)
            let recordSize = pathTableRecordSize(nameLength: nameBytes.count)
            var record = Data(count: recordSize)
            record[record.startIndex] = UInt8(nameBytes.count)
            record[record.startIndex + 1] = 0 // extended attribute record length
            if bigEndian {
                writeUInt32BE(dir.lba, at: 2, in: &record)
                writeUInt16BE(entry.parentIndex, at: 6, in: &record)
            } else {
                writeUInt32LE(dir.lba, at: 2, in: &record)
                writeUInt16LE(entry.parentIndex, at: 6, in: &record)
            }
            for (i, byte) in nameBytes.enumerated() { record[record.startIndex + 8 + i] = byte }
            image.replaceSubrange((image.startIndex + offset)..<(image.startIndex + offset + record.count), with: record)
            offset += recordSize
        }
    }

    // MARK: - Primary Volume Descriptor

    private static func writePrimaryVolumeDescriptor(into image: inout Data, volumeLabel: String, totalSectors: UInt32, rootLBA: UInt32, rootSize: UInt32, pathTableSize: UInt32, pathTableLBA_L: UInt32, pathTableLBA_M: UInt32) {
        let base = 16 * sectorSize
        var pvd = Data(count: sectorSize)
        pvd[pvd.startIndex] = 1 // type: Primary Volume Descriptor
        for (i, byte) in Array("CD001".utf8).enumerated() { pvd[pvd.startIndex + 1 + i] = byte }
        pvd[pvd.startIndex + 6] = 1 // version
        writeDChars("", length: 32, at: 8, in: &pvd) // system identifier
        writeDChars(volumeLabel, length: 32, at: 40, in: &pvd)
        writeBothEndianUInt32Data(totalSectors, at: 80, in: &pvd)
        writeBothEndianUInt16Data(1, at: 120, in: &pvd) // volume set size
        writeBothEndianUInt16Data(1, at: 124, in: &pvd) // volume sequence number
        writeBothEndianUInt16Data(UInt16(sectorSize), at: 128, in: &pvd)
        writeBothEndianUInt32Data(pathTableSize, at: 132, in: &pvd)
        writeUInt32LE(pathTableLBA_L, at: 140, in: &pvd)
        writeUInt32LE(0, at: 144, in: &pvd) // optional 2nd Type-L path table, unused
        writeUInt32BE(pathTableLBA_M, at: 148, in: &pvd)
        writeUInt32BE(0, at: 152, in: &pvd) // optional 2nd Type-M path table, unused
        let rootRecord = directoryRecord(identifierByte: 0x00, lba: rootLBA, size: rootSize, isDirectory: true)
        pvd.replaceSubrange((pvd.startIndex + 156)..<(pvd.startIndex + 156 + rootRecord.count), with: rootRecord)
        writeDChars("", length: 128, at: 190, in: &pvd) // volume set identifier
        writeDChars("", length: 128, at: 318, in: &pvd) // publisher identifier
        writeDChars("", length: 128, at: 446, in: &pvd) // data preparer identifier
        writeDChars("", length: 128, at: 574, in: &pvd) // application identifier
        writeVolumeTimestamp(at: 813, in: &pvd) // creation
        writeVolumeTimestamp(at: 830, in: &pvd) // modification
        writeUnspecifiedVolumeTimestamp(at: 847, in: &pvd) // expiration, not specified
        writeVolumeTimestamp(at: 864, in: &pvd) // effective
        pvd[pvd.startIndex + 881] = 1 // file structure version
        image.replaceSubrange((image.startIndex + base)..<(image.startIndex + base + sectorSize), with: pvd)
    }

    private static func writeVolumeDescriptorSetTerminator(into image: inout Data) {
        let base = 17 * sectorSize
        var terminator = Data(count: sectorSize)
        terminator[terminator.startIndex] = 255
        for (i, byte) in Array("CD001".utf8).enumerated() { terminator[terminator.startIndex + 1 + i] = byte }
        terminator[terminator.startIndex + 6] = 1
        image.replaceSubrange((image.startIndex + base)..<(image.startIndex + base + sectorSize), with: terminator)
    }

    // MARK: - Field encoding helpers

    private static func writeDChars(_ string: String, length: Int, at offset: Int, in data: inout Data) {
        var bytes = Array(string.uppercased().utf8.prefix(length))
        while bytes.count < length { bytes.append(0x20) } // space-padded, ECMA-119 7.4.1
        for (i, byte) in bytes.enumerated() { data[data.startIndex + offset + i] = byte }
    }

    /// ECMA-119 8.4.26.1: 16 ASCII digit characters (`YYYYMMDDHHMMSSCC`)
    /// plus a signed GMT-offset byte, all zero digits for "not specified."
    private static func writeUnspecifiedVolumeTimestamp(at offset: Int, in data: inout Data) {
        for i in 0..<16 { data[data.startIndex + offset + i] = UInt8(ascii: "0") }
        data[data.startIndex + offset + 16] = 0
    }

    private static func writeVolumeTimestamp(at offset: Int, in data: inout Data) {
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let text = String(format: "%04d%02d%02d%02d%02d%02d00", components.year ?? 1970, components.month ?? 1, components.day ?? 1, components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
        for (i, byte) in Array(text.utf8).enumerated() { data[data.startIndex + offset + i] = byte }
        data[data.startIndex + offset + 16] = 0 // GMT offset: 0 = UTC
    }

    private static func writeRecordingDateTime(at offset: Int, in record: inout Data) {
        // ECMA-119 9.1.5: 7 raw bytes (year-1900, month, day, hour, minute,
        // second, GMT offset in 15-min intervals), a *different* encoding
        // from the PVD's 17-ASCII-digit timestamps above.
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        record[record.startIndex + offset] = UInt8(clamping: (components.year ?? 1970) - 1900)
        record[record.startIndex + offset + 1] = UInt8(clamping: components.month ?? 1)
        record[record.startIndex + offset + 2] = UInt8(clamping: components.day ?? 1)
        record[record.startIndex + offset + 3] = UInt8(clamping: components.hour ?? 0)
        record[record.startIndex + offset + 4] = UInt8(clamping: components.minute ?? 0)
        record[record.startIndex + offset + 5] = UInt8(clamping: components.second ?? 0)
        record[record.startIndex + offset + 6] = 0
    }

    private static func writeUInt32LE(_ value: UInt32, at offset: Int, in data: inout Data) {
        data[data.startIndex + offset] = UInt8(value & 0xFF)
        data[data.startIndex + offset + 1] = UInt8((value >> 8) & 0xFF)
        data[data.startIndex + offset + 2] = UInt8((value >> 16) & 0xFF)
        data[data.startIndex + offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func writeUInt32BE(_ value: UInt32, at offset: Int, in data: inout Data) {
        data[data.startIndex + offset] = UInt8((value >> 24) & 0xFF)
        data[data.startIndex + offset + 1] = UInt8((value >> 16) & 0xFF)
        data[data.startIndex + offset + 2] = UInt8((value >> 8) & 0xFF)
        data[data.startIndex + offset + 3] = UInt8(value & 0xFF)
    }

    private static func writeUInt16LE(_ value: UInt16, at offset: Int, in data: inout Data) {
        data[data.startIndex + offset] = UInt8(value & 0xFF)
        data[data.startIndex + offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func writeUInt16BE(_ value: UInt16, at offset: Int, in data: inout Data) {
        data[data.startIndex + offset] = UInt8((value >> 8) & 0xFF)
        data[data.startIndex + offset + 1] = UInt8(value & 0xFF)
    }

    private static func writeBothEndianUInt32Data(_ value: UInt32, at offset: Int, in data: inout Data) {
        writeUInt32LE(value, at: offset, in: &data)
        writeUInt32BE(value, at: offset + 4, in: &data)
    }

    private static func writeBothEndianUInt16Data(_ value: UInt16, at offset: Int, in data: inout Data) {
        writeUInt16LE(value, at: offset, in: &data)
        writeUInt16BE(value, at: offset + 2, in: &data)
    }
}
