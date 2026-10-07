import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers

/// `MemoryCardParser` has no real PS2-written `.mcr` sample to validate
/// against (unlike this package's Twinsanity parsers, checked against the
/// actual mounted game disc, see `WorkspaceViewModelIntegrationTests`), so
/// this pins the byte-level FAT/directory-walk logic against a hand-built
/// synthetic card instead, the same approach `VIFInterpreterTests` and
/// `WorldPlacementParserTests` already use for tricky bit-level logic.
///
/// Synthetic card layout (1024-byte clusters, 8 clusters total = 8192 bytes):
/// - cluster 0: superblock
/// - cluster 1: indirect FAT cluster (ifc_list[0] points here)
/// - cluster 2: FAT cluster
/// - cluster 3 (alloc-relative 0): root directory, entries 0–1 (self, "..")
/// - cluster 4 (alloc-relative 1): root directory, entry 2 (the one real file)
/// - cluster 5 (alloc-relative 2): that file's data
final class MemoryCardParserTests: XCTestCase {
    private let clusterSize = 1024
    private let allocOffset: UInt32 = 3

    func testParsesSuperblockGeometry() throws {
        let card = try MemoryCardParser.parse(data: buildSyntheticCard())
        XCTAssertTrue(card.superblock.hasExpectedMagic)
        XCTAssertEqual(card.superblock.pageLength, 512)
        XCTAssertEqual(card.superblock.pagesPerCluster, 2)
        XCTAssertEqual(card.superblock.clusterSize, 1024)
        XCTAssertEqual(card.superblock.allocOffset, Int(allocOffset))
        XCTAssertEqual(card.superblock.clustersPerCard, 8)
    }

    func testWalksRootDirectoryAndFindsFile() throws {
        let card = try MemoryCardParser.parse(data: buildSyntheticCard())
        XCTAssertEqual(card.rootEntries.count, 1, "expected exactly one real entry past the '.'/'..' placeholders")
        let file = try XCTUnwrap(card.rootEntries.first)
        XCTAssertEqual(file.name, "TEST.BIN")
        XCTAssertTrue(file.isFile)
        XCTAssertFalse(file.isDirectory)
        XCTAssertTrue(file.exists)
        XCTAssertEqual(file.sizeOrEntryCount, 11)
        XCTAssertTrue(file.children.isEmpty)
    }

    func testDecodesTimestamp() throws {
        let card = try MemoryCardParser.parse(data: buildSyntheticCard())
        let file = try XCTUnwrap(card.rootEntries.first)
        XCTAssertEqual(file.modified.year, 2004)
        XCTAssertEqual(file.modified.month, 9)
        XCTAssertEqual(file.modified.day, 2)
    }

    func testTooSmallFileThrows() {
        XCTAssertThrowsError(try MemoryCardParser.parse(data: Data(repeating: 0, count: 16)))
    }

    // MARK: - Synthetic fixture construction

    private func buildSyntheticCard() -> Data {
        var bytes = [UInt8](repeating: 0, count: clusterSize * 8)

        // --- Superblock (cluster 0) ---
        setASCII("Sony PS2 Memory Card Format", at: 0x00, width: 28, in: &bytes)
        setASCII("1.2.0.0", at: 0x1C, width: 12, in: &bytes)
        setUInt16(512, at: 0x28, in: &bytes)          // page_len
        setUInt16(2, at: 0x2A, in: &bytes)             // pages_per_cluster
        setUInt16(16, at: 0x2C, in: &bytes)            // pages_per_block
        setUInt32(8, at: 0x30, in: &bytes)             // clusters_per_card
        setUInt32(allocOffset, at: 0x34, in: &bytes)   // alloc_offset
        setUInt32(7, at: 0x38, in: &bytes)             // alloc_end
        setUInt32(0, at: 0x3C, in: &bytes)             // rootdir_cluster (alloc-relative)
        setUInt32(0xFFFF_FFFF, at: 0x40, in: &bytes)   // backup_block1 (unused by this parser)
        setUInt32(0xFFFF_FFFF, at: 0x44, in: &bytes)   // backup_block2
        setUInt32(1, at: 0x50, in: &bytes)             // ifc_list[0] = absolute cluster 1
        setUInt8(2, at: 0x150, in: &bytes)             // card_type
        setUInt8(0x2B, at: 0x151, in: &bytes)          // card_flags

        // --- Indirect FAT cluster (absolute cluster 1) ---
        setUInt32(2, at: clusterOffset(1) + 0, in: &bytes) // -> FAT cluster is absolute cluster 2

        // --- FAT cluster (absolute cluster 2) ---
        // alloc-relative cluster 0 (root dir, part 1) -> next is alloc-relative 1
        setUInt32(0x8000_0001, at: clusterOffset(2) + 0 * 4, in: &bytes)
        // alloc-relative cluster 1 (root dir, part 2) -> end of chain
        setUInt32(0xFFFF_FFFF, at: clusterOffset(2) + 1 * 4, in: &bytes)
        // alloc-relative cluster 2 (file data) -> end of chain
        setUInt32(0xFFFF_FFFF, at: clusterOffset(2) + 2 * 4, in: &bytes)

        // --- Root directory, part 1 (absolute cluster 3 = alloc-relative 0) ---
        let rootPart1 = clusterOffset(3)
        // Entry 0: self-entry, mode = EXISTS|DIRECTORY, length = 3 total entries.
        setUInt16(0x8020, at: rootPart1 + 0x00, in: &bytes)
        setUInt32(3, at: rootPart1 + 0x04, in: &bytes)
        setASCII(".", at: rootPart1 + 0x40, width: 32, in: &bytes)
        // Entry 1: ".." placeholder.
        setUInt16(0x8020, at: rootPart1 + 512 + 0x00, in: &bytes)
        setASCII("..", at: rootPart1 + 512 + 0x40, width: 32, in: &bytes)

        // --- Root directory, part 2 (absolute cluster 4 = alloc-relative 1) ---
        let rootPart2 = clusterOffset(4)
        // Entry 2: the one real file, mode = EXISTS|FILE, length = 11 bytes,
        // cluster = 2 (alloc-relative), modified = 2004-09-02 12:34:56 JST.
        setUInt16(0x8010, at: rootPart2 + 0x00, in: &bytes)
        setUInt32(11, at: rootPart2 + 0x04, in: &bytes)
        setUInt32(2, at: rootPart2 + 0x10, in: &bytes)
        setUInt8(56, at: rootPart2 + 0x19, in: &bytes)  // modified.sec (0x18 unused + 1)
        setUInt8(34, at: rootPart2 + 0x1A, in: &bytes)  // modified.min
        setUInt8(12, at: rootPart2 + 0x1B, in: &bytes)  // modified.hour
        setUInt8(2, at: rootPart2 + 0x1C, in: &bytes)   // modified.day
        setUInt8(9, at: rootPart2 + 0x1D, in: &bytes)   // modified.month
        setUInt16(2004, at: rootPart2 + 0x1E, in: &bytes) // modified.year
        setASCII("TEST.BIN", at: rootPart2 + 0x40, width: 32, in: &bytes)

        // --- File data (absolute cluster 5 = alloc-relative 2) ---
        setASCII("hello world", at: clusterOffset(5), width: 11, in: &bytes)

        return Data(bytes)
    }

    private func clusterOffset(_ absoluteCluster: Int) -> Int { absoluteCluster * clusterSize }

    private func setASCII(_ string: String, at offset: Int, width: Int, in bytes: inout [UInt8]) {
        let scalars = Array(string.utf8.prefix(width))
        for (i, b) in scalars.enumerated() { bytes[offset + i] = b }
    }

    private func setUInt8(_ value: UInt8, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = value
    }

    private func setUInt16(_ value: UInt16, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func setUInt32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
}
