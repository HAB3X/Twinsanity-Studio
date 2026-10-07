import Foundation

/// PS2 Graphics Synthesizer local-memory block-swizzle simulator, ported from
/// `Twinsanity/EzSwizzle.cs`. The PS2 GS never stores texture data as a plain
/// row-major buffer, it addresses a simulated 4 MiB local memory in
/// hardware-defined 32x32(ish) "page/block/column" tiles whose layout differs
/// per pixel format (PSMCT32, PSMT8, ...). To decode a texture you have to:
/// 1. Write the on-disk bytes into simulated GS memory using the *source*
///    format's addressing (`writeTexPSMCT32`, Twinsanity always transfers
///    swizzled texture data as raw PSMCT32 words over the bus).
/// 2. Read it back out using the *target* format's addressing
///    (`readTexPSMT8`), the actual un-swizzle happens purely as a side effect
///    of the two addressing functions disagreeing about where a given (x, y)
///    texel lives.
///
/// Only the PSMCT32 and PSMT8 address tables are ported, those are the only
/// two formats `Texture.Load` in the original tool ever fully decodes;
/// everything else falls back to a raw-bytes passthrough there too (see
/// `TextureParser`).
final class EzSwizzle {
    private var gs = [UInt8](repeating: 0, count: 1024 * 1024 * 4)

    // MARK: - Address LUTs (verbatim from EzSwizzle.cs)

    private static let block32: [Int] = [
        0, 1, 4, 5, 16, 17, 20, 21,
        2, 3, 6, 7, 18, 19, 22, 23,
        8, 9, 12, 13, 24, 25, 28, 29,
        10, 11, 14, 15, 26, 27, 30, 31
    ]
    private static let columnWord32: [Int] = [
        0, 1, 4, 5, 8, 9, 12, 13,
        2, 3, 6, 7, 10, 11, 14, 15
    ]
    private static let block8: [Int] = [
        0, 1, 4, 5, 16, 17, 20, 21,
        2, 3, 6, 7, 18, 19, 22, 23,
        8, 9, 12, 13, 24, 25, 28, 29,
        10, 11, 14, 15, 26, 27, 30, 31
    ]
    private static let columnWord8: [[Int]] = [
        [
            0, 1, 4, 5, 8, 9, 12, 13, 0, 1, 4, 5, 8, 9, 12, 13,
            2, 3, 6, 7, 10, 11, 14, 15, 2, 3, 6, 7, 10, 11, 14, 15,
            8, 9, 12, 13, 0, 1, 4, 5, 8, 9, 12, 13, 0, 1, 4, 5,
            10, 11, 14, 15, 2, 3, 6, 7, 10, 11, 14, 15, 2, 3, 6, 7
        ],
        [
            8, 9, 12, 13, 0, 1, 4, 5, 8, 9, 12, 13, 0, 1, 4, 5,
            10, 11, 14, 15, 2, 3, 6, 7, 10, 11, 14, 15, 2, 3, 6, 7,
            0, 1, 4, 5, 8, 9, 12, 13, 0, 1, 4, 5, 8, 9, 12, 13,
            2, 3, 6, 7, 10, 11, 14, 15, 2, 3, 6, 7, 10, 11, 14, 15
        ]
    ]
    private static let columnByte8: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2,
        0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2,
        1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 3, 3, 3,
        1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 3, 3, 3
    ]

    /// Zeroes the existing 4 MiB buffer in place rather than allocating and
    /// zero-filling a brand-new array, every real call site (`TextureParser`)
    /// constructs a fresh `EzSwizzle()` (whose stored-property initializer
    /// already zero-fills `gs` once) and calls `cleanGs()` immediately after,
    /// which used to mean *two* full 4 MiB allocate-and-zero passes per
    /// texture for no behavioral difference, one of them entirely discarded
    /// before a single byte was written. Zeroing in place still leaves `gs`
    /// correctly zeroed for any future caller that reuses one instance across
    /// multiple textures, it just no longer pays for a second allocation to
    /// get there.
    func cleanGs() {
        gs.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) }
    }

    /// Writes `data` into simulated GS memory using PSMCT32 addressing.
    ///
    /// Uses raw pointers instead of `gs[i]`/`data[i]` Array subscripting in
    /// the per-pixel inner loop: an `Array`'s subscript setter re-checks
    /// exclusive/unique ownership of its storage on every single element
    /// write (real, measurable overhead across the hundreds of thousands of
    /// byte accesses one full-size texture's swizzle/unswizzle pass makes),
    /// even though `gs`/`data` are never shared here. The bounds checks in
    /// the `guard` above each copy are preserved exactly as before, this
    /// changes *how* an in-bounds byte gets copied, not which bytes do.
    func writeTexPSMCT32(dbp: Int, dbw: Int, dsax: Int, dsay: Int, rrw: Int, rrh: Int, data: [UInt8]) {
        let startBlockPos = dbp * 64
        guard rrw > 0, rrh > 0 else { return }

        var src = 0
        data.withUnsafeBufferPointer { srcBuf in
            gs.withUnsafeMutableBufferPointer { gsBuf in
                for y in dsay..<(dsay + rrh) {
                    for x in dsax..<(dsax + rrw) {
                        let pageX = x / 64
                        let pageY = y / 32
                        let page = pageX + pageY * dbw

                        let px = x - (pageX * 64)
                        let py = y - (pageY * 32)

                        let blockX = px / 8
                        let blockY = py / 8
                        let block = Self.block32[blockX + blockY * 8]

                        let bx = px - blockX * 8
                        let by = py - blockY * 8

                        let column = by / 2
                        let cx = bx
                        let cy = by - column * 2
                        let cw = Self.columnWord32[cx + cy * 8]

                        let dst = startBlockPos + page * 2048 + block * 64 + column * 16 + cw
                        guard src + 4 <= srcBuf.count, dst >= 0, 4 * dst + 3 < gsBuf.count else { src += 4; continue }
                        for i in 0..<4 { gsBuf[4 * dst + i] = srcBuf[src + i] }
                        src += 4
                    }
                }
            }
        }
    }

    /// Reads simulated GS memory back out using PSMCT32 addressing.
    func readTexPSMCT32(dbp: Int, dbw: Int, dsax: Int, dsay: Int, rrw: Int, rrh: Int, into data: inout [UInt8]) {
        let startBlockPos = dbp * 64
        guard rrw > 0, rrh > 0 else { return }

        var src = 0
        data.withUnsafeMutableBufferPointer { dstBuf in
            gs.withUnsafeBufferPointer { gsBuf in
                for y in dsay..<(dsay + rrh) {
                    for x in dsax..<(dsax + rrw) {
                        let pageX = x / 64
                        let pageY = y / 32
                        let page = pageX + pageY * dbw

                        let px = x - (pageX * 64)
                        let py = y - (pageY * 32)

                        let blockX = px / 8
                        let blockY = py / 8
                        let block = Self.block32[blockX + blockY * 8]

                        let bx = px - blockX * 8
                        let by = py - blockY * 8

                        let column = by / 2
                        let cx = bx
                        let cy = by - column * 2
                        let cw = Self.columnWord32[cx + cy * 8]

                        let dst = startBlockPos + page * 2048 + block * 64 + column * 16 + cw
                        guard src + 4 <= dstBuf.count, dst >= 0, 4 * dst + 3 < gsBuf.count else { src += 4; continue }
                        for i in 0..<4 { dstBuf[src + i] = gsBuf[4 * dst + i] }
                        src += 4
                    }
                }
            }
        }
    }

    /// Writes `data` into simulated GS memory using PSMT8 addressing.
    func writeTexPSMT8(dbp: Int, dbwIn: Int, dsax: Int, dsay: Int, rrw: Int, rrh: Int, data: [UInt8]) {
        let dbw = dbwIn >> 1
        let startBlockPos = dbp * 64
        guard rrw > 0, rrh > 0 else { return }

        var src = 0
        data.withUnsafeBufferPointer { srcBuf in
            gs.withUnsafeMutableBufferPointer { gsBuf in
                for y in dsay..<(dsay + rrh) {
                    for x in dsax..<(dsax + rrw) {
                        let pageX = x / 128
                        let pageY = y / 64
                        let page = pageX + pageY * dbw

                        let px = x - (pageX * 128)
                        let py = y - (pageY * 64)

                        let blockX = px / 16
                        let blockY = py / 16
                        let block = Self.block8[blockX + blockY * 8]

                        let bx = px - blockX * 16
                        let by = py - blockY * 16

                        let column = by / 4
                        let cx = bx
                        let cy = by - column * 4
                        let cw = Self.columnWord8[column & 1][cx + cy * 16]
                        let cb = Self.columnByte8[cx + cy * 16]

                        let dst = startBlockPos + page * 2048 + block * 64 + column * 16 + cw
                        guard src < srcBuf.count, dst >= 0, 4 * dst + cb < gsBuf.count else { src += 1; continue }
                        gsBuf[4 * dst + cb] = srcBuf[src]
                        src += 1
                    }
                }
            }
        }
    }

    /// Reads simulated GS memory back out using PSMT8 addressing, this is
    /// where the actual un-swizzle happens for indexed textures.
    func readTexPSMT8(dbp: Int, dbwIn: Int, dsax: Int, dsay: Int, rrw: Int, rrh: Int, into data: inout [UInt8]) {
        let dbw = dbwIn >> 1
        let startBlockPos = dbp * 64
        guard rrw > 0, rrh > 0 else { return }

        var src = 0
        data.withUnsafeMutableBufferPointer { dstBuf in
            gs.withUnsafeBufferPointer { gsBuf in
                for y in dsay..<(dsay + rrh) {
                    for x in dsax..<(dsax + rrw) {
                        let pageX = x / 128
                        let pageY = y / 64
                        let page = pageX + pageY * dbw

                        let px = x - (pageX * 128)
                        let py = y - (pageY * 64)

                        let blockX = px / 16
                        let blockY = py / 16
                        let block = Self.block8[blockX + blockY * 8]

                        let bx = px - blockX * 16
                        let by = py - blockY * 16

                        let column = by / 4
                        let cx = bx
                        let cy = by - column * 4
                        let cw = Self.columnWord8[column & 1][cx + cy * 16]
                        let cb = Self.columnByte8[cx + cy * 16]

                        let dst = startBlockPos + page * 2048 + block * 64 + column * 16 + cw
                        guard src < dstBuf.count, dst >= 0, 4 * dst + cb < gsBuf.count else { src += 1; continue }
                        dstBuf[src] = gsBuf[4 * dst + cb]
                        src += 1
                    }
                }
            }
        }
    }
}
