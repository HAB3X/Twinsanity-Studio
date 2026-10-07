import Foundation

/// Decompressor for RNC ProPack ("Rob Northen Compression") streams.
///
/// Real WoC disc files (`.GSC`, and likely others) begin with an `RNC\x02`
/// signature, confirmed against real bytes read directly off the mounted
/// PS2 disc image, not assumed. This is a direct, faithful port of the
/// decompiled reference decoder at `Games Files/Reference Files/
/// TravellersTalesPSXCollisionViewer-master/util/RAWfiles/RAWenc/RNC.c`
/// ("RNC ProPackED v1.8 [by Lab 313]", itself a decompilation of the
/// original Rob Northen Computing tool), every bit-read order, table, and
/// branch below mirrors that source line for line; nothing here is guessed.
///
/// The only intentional simplification versus the C source: the original
/// uses a fixed-size circular window buffer (with an explicit flush-and-wrap
/// step in `write_decoded_byte`) purely as a memory-bound implementation
/// detail. Since Swift can just grow the output array, back-references are
/// resolved directly as `output[output.count - offset]`, this produces
/// byte-identical output to the windowed version, just without replicating
/// its buffer-management bookkeeping.
public enum RNCDecompressor {
    public enum RNCError: Error, Equatable {
        case tooShort
        case badSignature
        case unsupportedMethod(UInt32)
        case truncatedInput
        case packedCRCMismatch(expected: UInt16, actual: UInt16)
        case unpackedCRCMismatch(expected: UInt16, actual: UInt16)
        case encryptionKeyRequired
        case corruptMatchOffset
    }

    public struct Header {
        public let method: UInt32
        public let unpackedSize: UInt32
        public let packedSize: UInt32
        public let unpackedCRC: UInt16
        public let packedCRC: UInt16
    }

    private static let headerSize = 18

    public static func isRNCStream(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0] == 0x52 && bytes[1] == 0x4E && bytes[2] == 0x43
    }

    public static func readHeader(_ bytes: [UInt8]) throws -> Header {
        guard bytes.count >= headerSize else { throw RNCError.tooShort }
        guard bytes[0] == 0x52, bytes[1] == 0x4E, bytes[2] == 0x43 else { throw RNCError.badSignature }
        let method = UInt32(bytes[3]) & 3
        let unpackedSize = beUInt32(bytes, 4)
        let packedSize = beUInt32(bytes, 8)
        let unpackedCRC = beUInt16(bytes, 12)
        let packedCRC = beUInt16(bytes, 14)
        return Header(method: method, unpackedSize: unpackedSize, packedSize: packedSize, unpackedCRC: unpackedCRC, packedCRC: packedCRC)
    }

    /// Decompresses a full RNC stream (18-byte header + packed payload).
    /// Verifies both the packed-data CRC (before decoding) and the
    /// unpacked-data CRC (after decoding) against the values in the header , 
    /// these are the same checks the original tool performs, and give a
    /// hard, self-contained pass/fail signal that the port is bit-exact.
    public static func decompress(_ bytes: [UInt8], verifyCRC: Bool = true) throws -> [UInt8] {
        let header = try readHeader(bytes)
        guard header.method == 1 || header.method == 2 else { throw RNCError.unsupportedMethod(header.method) }
        guard bytes.count >= headerSize + Int(header.packedSize) else { throw RNCError.truncatedInput }

        if verifyCRC {
            let actualPackedCRC = crcBlock(bytes, from: headerSize, count: Int(header.packedSize))
            guard actualPackedCRC == header.packedCRC else {
                throw RNCError.packedCRCMismatch(expected: header.packedCRC, actual: actualPackedCRC)
            }
        }

        let state = DecodeState(input: bytes, startOffset: headerSize, unpackedSize: header.unpackedSize, method: header.method)
        try state.run()

        if verifyCRC {
            guard state.unpackedCRCReal == header.unpackedCRC else {
                throw RNCError.unpackedCRCMismatch(expected: header.unpackedCRC, actual: state.unpackedCRCReal)
            }
        }

        return state.output
    }

    // MARK: - Big-endian reads

    private static func beUInt16(_ b: [UInt8], _ o: Int) -> UInt16 {
        (UInt16(b[o]) << 8) | UInt16(b[o + 1])
    }

    private static func beUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(beUInt16(b, o)) << 16) | UInt32(beUInt16(b, o + 2))
    }

    // MARK: - CRC-16 (RNC's table, reflected, ported verbatim from RNC.c)

    static let crcTable: [UInt16] = [
        0x0000, 0xC0C1, 0xC181, 0x0140, 0xC301, 0x03C0, 0x0280, 0xC241,
        0xC601, 0x06C0, 0x0780, 0xC741, 0x0500, 0xC5C1, 0xC481, 0x0440,
        0xCC01, 0x0CC0, 0x0D80, 0xCD41, 0x0F00, 0xCFC1, 0xCE81, 0x0E40,
        0x0A00, 0xCAC1, 0xCB81, 0x0B40, 0xC901, 0x09C0, 0x0880, 0xC841,
        0xD801, 0x18C0, 0x1980, 0xD941, 0x1B00, 0xDBC1, 0xDA81, 0x1A40,
        0x1E00, 0xDEC1, 0xDF81, 0x1F40, 0xDD01, 0x1DC0, 0x1C80, 0xDC41,
        0x1400, 0xD4C1, 0xD581, 0x1540, 0xD701, 0x17C0, 0x1680, 0xD641,
        0xD201, 0x12C0, 0x1380, 0xD341, 0x1100, 0xD1C1, 0xD081, 0x1040,
        0xF001, 0x30C0, 0x3180, 0xF141, 0x3300, 0xF3C1, 0xF281, 0x3240,
        0x3600, 0xF6C1, 0xF781, 0x3740, 0xF501, 0x35C0, 0x3480, 0xF441,
        0x3C00, 0xFCC1, 0xFD81, 0x3D40, 0xFF01, 0x3FC0, 0x3E80, 0xFE41,
        0xFA01, 0x3AC0, 0x3B80, 0xFB41, 0x3900, 0xF9C1, 0xF881, 0x3840,
        0x2800, 0xE8C1, 0xE981, 0x2940, 0xEB01, 0x2BC0, 0x2A80, 0xEA41,
        0xEE01, 0x2EC0, 0x2F80, 0xEF41, 0x2D00, 0xEDC1, 0xEC81, 0x2C40,
        0xE401, 0x24C0, 0x2580, 0xE541, 0x2700, 0xE7C1, 0xE681, 0x2640,
        0x2200, 0xE2C1, 0xE381, 0x2340, 0xE101, 0x21C0, 0x2080, 0xE041,
        0xA001, 0x60C0, 0x6180, 0xA141, 0x6300, 0xA3C1, 0xA281, 0x6240,
        0x6600, 0xA6C1, 0xA781, 0x6740, 0xA501, 0x65C0, 0x6480, 0xA441,
        0x6C00, 0xACC1, 0xAD81, 0x6D40, 0xAF01, 0x6FC0, 0x6E80, 0xAE41,
        0xAA01, 0x6AC0, 0x6B80, 0xAB41, 0x6900, 0xA9C1, 0xA881, 0x6840,
        0x7800, 0xB8C1, 0xB981, 0x7940, 0xBB01, 0x7BC0, 0x7A80, 0xBA41,
        0xBE01, 0x7EC0, 0x7F80, 0xBF41, 0x7D00, 0xBDC1, 0xBC81, 0x7C40,
        0xB401, 0x74C0, 0x7580, 0xB541, 0x7700, 0xB7C1, 0xB681, 0x7640,
        0x7200, 0xB2C1, 0xB381, 0x7340, 0xB101, 0x71C0, 0x7080, 0xB041,
        0x5000, 0x90C1, 0x9181, 0x5140, 0x9301, 0x53C0, 0x5280, 0x9241,
        0x9601, 0x56C0, 0x5780, 0x9741, 0x5500, 0x95C1, 0x9481, 0x5440,
        0x9C01, 0x5CC0, 0x5D80, 0x9D41, 0x5F00, 0x9FC1, 0x9E81, 0x5E40,
        0x5A00, 0x9AC1, 0x9B81, 0x5B40, 0x9901, 0x59C0, 0x5880, 0x9841,
        0x8801, 0x48C0, 0x4980, 0x8941, 0x4B00, 0x8BC1, 0x8A81, 0x4A40,
        0x4E00, 0x8EC1, 0x8F81, 0x4F40, 0x8D01, 0x4DC0, 0x4C80, 0x8C41,
        0x4400, 0x84C1, 0x8581, 0x4540, 0x8701, 0x47C0, 0x4680, 0x8641,
        0x8201, 0x42C0, 0x4380, 0x8341, 0x4100, 0x81C1, 0x8081, 0x4040,
    ]

    private static func crcBlock(_ bytes: [UInt8], from offset: Int, count: Int) -> UInt16 {
        var crc: UInt16 = 0
        for i in 0..<count {
            let b = bytes[offset + i]
            crc ^= UInt16(b)
            crc = (crc >> 8) ^ crcTable[Int(crc & 0xFF)]
        }
        return crc
    }

    private static func rorW(_ x: UInt16) -> UInt16 {
        (x & 1) != 0 ? (0x8000 | (x >> 1)) : (x >> 1)
    }

    // MARK: - Huffman table (method 1)

    private struct HuffEntry {
        var count: UInt32 = 0        // l1: frequency during construction (unused on decode)
        var code: UInt32 = 0         // l3: canonical code value
        var bitDepth: UInt16 = 0
    }

    private static let matchCountBitsTable: [UInt16] = [0x00, 0x0E, 0x08, 0x0A, 0x012, 0x013, 0x016]
    private static let matchCountBitsCountTable: [Int] = [0, 4, 4, 4, 5, 5, 5]
    private static let matchOffsetBitsTable: [UInt16] = [0x00, 0x06, 0x08, 0x09, 0x15, 0x17, 0x1D, 0x1F, 0x28, 0x29, 0x2C, 0x2D, 0x38, 0x39, 0x3C, 0x3D]
    private static let matchOffsetBitsCountTable: [Int] = [1, 3, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6]

    /// Mutable decode state, mirrors `vars_t` in the C source, minus the
    /// fields that only mattered for the fixed-size circular window (see
    /// the type's doc comment).
    private final class DecodeState {
        let input: [UInt8]
        var inputOffset: Int
        let unpackedSize: UInt32
        let method: UInt32

        var output: [UInt8] = []
        var processedSize: UInt32 = 0
        var unpackedCRCReal: UInt16 = 0

        var bitBuffer: UInt32 = 0
        var bitCount: Int = 0

        var encKey: UInt16 = 0
        var matchCount: UInt32 = 0
        var matchOffset: UInt32 = 0

        var rawTable = [HuffEntry](repeating: HuffEntry(), count: 16)
        var lenTable = [HuffEntry](repeating: HuffEntry(), count: 16)
        var posTable = [HuffEntry](repeating: HuffEntry(), count: 16)

        init(input: [UInt8], startOffset: Int, unpackedSize: UInt32, method: UInt32) {
            self.input = input
            self.inputOffset = startOffset
            self.unpackedSize = unpackedSize
            self.method = method
            output.reserveCapacity(Int(unpackedSize))
        }

        func run() throws {
            // "no lock" bit, then "encrypted" bit -- see do_unpack_data.
            _ = try inputBits(1)
            if try inputBits(1) != 0 {
                throw RNCError.encryptionKeyRequired
            }
            if method == 1 {
                try unpackMethod1()
            } else {
                try unpackMethod2()
            }
        }

        // MARK: byte / bit input

        func readSourceByte() throws -> UInt8 {
            guard inputOffset < input.count else { throw RNCError.truncatedInput }
            let b = input[inputOffset]
            inputOffset += 1
            return b
        }

        func peekByte(_ aheadBy: Int) -> UInt8 {
            let idx = inputOffset + aheadBy
            return (idx >= 0 && idx < input.count) ? input[idx] : 0
        }

        func inputBits(_ count: Int) throws -> UInt32 {
            method == 2 ? try inputBitsM2(count) : try inputBitsM1(count)
        }

        func inputBitsM2(_ count: Int) throws -> UInt32 {
            var bits: UInt32 = 0
            var n = count
            while n > 0 {
                if bitCount == 0 {
                    bitBuffer = UInt32(try readSourceByte())
                    bitCount = 8
                }
                bits <<= 1
                if bitBuffer & 0x80 != 0 { bits |= 1 }
                bitBuffer = (bitBuffer << 1) & 0xFF
                bitCount -= 1
                n -= 1
            }
            return bits
        }

        func inputBitsM1(_ count: Int) throws -> UInt32 {
            var bits: UInt32 = 0
            var prevBit: UInt32 = 1
            var n = count
            while n > 0 {
                if bitCount == 0 {
                    let b1 = try readSourceByte()
                    let b2 = try readSourceByte()
                    let peek0 = peekByte(0)
                    let peek1 = peekByte(1)
                    bitBuffer = (UInt32(peek1) << 24) | (UInt32(peek0) << 16) | (UInt32(b2) << 8) | UInt32(b1)
                    bitCount = 16
                }
                if bitBuffer & 1 != 0 { bits |= prevBit }
                bitBuffer >>= 1
                prevBit <<= 1
                bitCount -= 1
                n -= 1
            }
            return bits
        }

        func writeDecodedByte(_ b: UInt8) {
            output.append(b)
            let idx = Int((unpackedCRCReal ^ UInt16(b)) & 0xFF)
            unpackedCRCReal = RNCDecompressor.crcTable[idx] ^ (unpackedCRCReal >> 8)
        }

        func copyMatch() throws {
            var count = matchCount
            let offset = Int(matchOffset)
            // `matchOffset` comes straight off the compressed bitstream with
            // no bound relative to how much output exists yet -- a
            // corrupted stream (that still happens to pass the packed-CRC
            // check) could reference before the start of output, which
            // would otherwise index `output` out of bounds.
            guard offset > 0, offset <= output.count else { throw RNCError.corruptMatchOffset }
            while count > 0 {
                writeDecodedByte(output[output.count - offset])
                count -= 1
            }
        }

        // MARK: method 2 (simple bit-tree, no Huffman tables)

        func decodeMatchCountM2() throws {
            matchCount = (try inputBitsM2(1)) + 4
            if try inputBitsM2(1) != 0 {
                matchCount = ((matchCount - 1) << 1) + (try inputBitsM2(1))
            }
        }

        func decodeMatchOffsetM2() throws {
            matchOffset = 0
            if try inputBitsM2(1) != 0 {
                matchOffset = try inputBitsM2(1)
                if try inputBitsM2(1) != 0 {
                    matchOffset = ((matchOffset << 1) | (try inputBitsM2(1))) | 4
                    if try inputBitsM2(1) == 0 {
                        matchOffset = (matchOffset << 1) | (try inputBitsM2(1))
                    }
                } else if matchOffset == 0 {
                    matchOffset = (try inputBitsM2(1)) + 2
                }
            }
            matchOffset = ((matchOffset << 8) | UInt32(try readSourceByte())) + 1
        }

        func unpackMethod2() throws {
            while processedSize < unpackedSize {
                outer: while true {
                    if try inputBitsM2(1) == 0 {
                        let b = try readSourceByte()
                        writeDecodedByte(b ^ UInt8(truncatingIfNeeded: encKey))
                        encKey = RNCDecompressor.rorW(encKey)
                        processedSize += 1
                    } else if try inputBitsM2(1) != 0 {
                        if try inputBitsM2(1) != 0 {
                            if try inputBitsM2(1) != 0 {
                                let byte = try readSourceByte()
                                matchCount = UInt32(byte) + 8
                                if matchCount == 8 {
                                    _ = try inputBitsM2(1)
                                    break outer
                                }
                            } else {
                                matchCount = 3
                            }
                            try decodeMatchOffsetM2()
                        } else {
                            matchCount = 2
                            matchOffset = UInt32(try readSourceByte()) + 1
                        }
                        processedSize += matchCount
                        try copyMatch()
                    } else {
                        try decodeMatchCountM2()
                        if matchCount != 9 {
                            try decodeMatchOffsetM2()
                            processedSize += matchCount
                            try copyMatch()
                        } else {
                            let dataLength = (try inputBitsM2(4)) * 4 + 12
                            processedSize += dataLength
                            var remaining = dataLength
                            while remaining > 0 {
                                let b = try readSourceByte()
                                writeDecodedByte((UInt8(truncatingIfNeeded: encKey) ^ b))
                                remaining -= 1
                            }
                            encKey = RNCDecompressor.rorW(encKey)
                        }
                    }
                }
            }
        }

        // MARK: method 1 (Huffman + LZ77)

        func clearTable(_ table: inout [HuffEntry]) {
            for i in table.indices { table[i] = HuffEntry() }
        }

        func inverseBits(_ value: UInt32, _ count: Int) -> UInt32 {
            var v = value
            var i: UInt32 = 0
            var n = count
            while n > 0 {
                i <<= 1
                if v & 1 != 0 { i |= 1 }
                v >>= 1
                n -= 1
            }
            return i
        }

        func assignCanonicalCodes(_ table: inout [HuffEntry], count: Int) {
            var val: UInt32 = 0
            var div: UInt32 = 0x8000_0000
            var bits = 1
            while bits <= 16 {
                var i = 0
                while true {
                    if i >= count {
                        bits += 1
                        div >>= 1
                        break
                    }
                    if table[i].bitDepth == UInt16(bits) {
                        table[i].code = inverseBits(val / div, bits)
                        val += div
                    }
                    i += 1
                }
            }
        }

        func makeHuffTable(_ table: inout [HuffEntry]) throws {
            clearTable(&table)
            var leafNodes = Int(try inputBitsM1(5))
            if leafNodes > 0 {
                if leafNodes > 16 { leafNodes = 16 }
                for i in 0..<leafNodes {
                    table[i].bitDepth = UInt16(try inputBitsM1(4))
                }
                assignCanonicalCodes(&table, count: leafNodes)
            }
        }

        func decodeTableData(_ table: [HuffEntry]) throws -> UInt32 {
            var i = 0
            while true {
                if table[i].bitDepth != 0 {
                    let mask: UInt32 = (1 << table[i].bitDepth) - 1
                    if table[i].code == (bitBuffer & mask) {
                        _ = try inputBitsM1(Int(table[i].bitDepth))
                        if i < 2 { return UInt32(i) }
                        return (try inputBitsM1(i - 1)) | (UInt32(1) << (i - 1))
                    }
                }
                i += 1
                if i >= table.count { throw RNCError.truncatedInput }
            }
        }

        func unpackMethod1() throws {
            while processedSize < unpackedSize {
                try makeHuffTable(&rawTable)
                try makeHuffTable(&lenTable)
                try makeHuffTable(&posTable)

                var subchunks = try inputBitsM1(16)

                while subchunks > 0 {
                    subchunks -= 1
                    let dataLength = try decodeTableData(rawTable)
                    processedSize += dataLength

                    if dataLength > 0 {
                        var remaining = dataLength
                        while remaining > 0 {
                            let b = try readSourceByte()
                            writeDecodedByte((UInt8(truncatingIfNeeded: encKey) ^ b))
                            remaining -= 1
                        }
                        encKey = RNCDecompressor.rorW(encKey)

                        // Re-sync the peek-ahead bit buffer against the
                        // now-advanced cursor (mirrors the C source's direct
                        // re-read of `pack_block_start[0..2]` after a literal
                        // run -- those bytes were consumed via
                        // `read_source_byte` rather than the bit reader
                        // above, so the bit reader's look-ahead needs to be
                        // rebuilt from the new position; `[0]`/`[1]`/`[2]`
                        // there are forward peeks from the already-advanced
                        // cursor, not backward ones).
                        let p0 = peekByte(0), p1 = peekByte(1), p2 = peekByte(2)
                        bitBuffer = ((UInt32(p2) << 16) | (UInt32(p1) << 8) | UInt32(p0)) << UInt32(bitCount) | (bitBuffer & ((1 << UInt32(bitCount)) - 1))
                    }

                    if subchunks > 0 {
                        matchOffset = (try decodeTableData(lenTable)) + 1
                        matchCount = (try decodeTableData(posTable)) + 2
                        processedSize += matchCount
                        try copyMatch()
                    }
                }
            }
        }
    }
}
