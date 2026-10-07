import Foundation

/// Median-cut RGBA color quantizer for `TextureWriter.encodePSMT8` --
/// reduces an arbitrary RGBA8 image down to at most 256 colors (PSMT8's
/// palette size), producing both the palette and one 8-bit index per pixel.
/// Standard, well-known algorithm (Heckbert 1982): recursively split the
/// color space into buckets along whichever channel has the widest value
/// range, splitting each bucket at its population-weighted median, until
/// there are as many buckets as the color budget allows; each bucket's
/// population-weighted average becomes one palette entry.
///
/// Colors are packed into a single `UInt32` (not `[UInt8]`/`SIMD4<UInt8>`)
/// as the histogram/cache key throughout -- a plain, fast, unambiguously
/// `Hashable` key, cheaper to hash and compare than a 4-element collection
/// on every histogram/nearest-color lookup.
enum PSMT8Quantizer {
    private static func pack(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> UInt32 {
        UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(a) << 24)
    }

    private static func unpack(_ packed: UInt32) -> [UInt8] {
        [UInt8(packed & 0xFF), UInt8((packed >> 8) & 0xFF), UInt8((packed >> 16) & 0xFF), UInt8((packed >> 24) & 0xFF)]
    }

    /// Every unique RGBA color currently in this bucket, plus how many
    /// pixels share it -- weighting by population (not just unique-color
    /// count) is what keeps a large flat area of the texture from being
    /// treated as "one vote" during both splitting and averaging.
    private struct Bucket {
        var colors: [(packed: UInt32, count: Int)]
        var totalCount: Int { colors.reduce(0) { $0 + $1.count } }

        /// The channel (0=R, 1=G, 2=B, 3=A) with the widest value range
        /// across this bucket -- median-cut always splits along this axis,
        /// the one where a single average color would lose the most
        /// visual distinction.
        var widestChannel: Int {
            var minV = [255, 255, 255, 255]
            var maxV = [0, 0, 0, 0]
            for (packed, _) in colors {
                let c = unpack(packed)
                for ch in 0..<4 {
                    minV[ch] = min(minV[ch], Int(c[ch]))
                    maxV[ch] = max(maxV[ch], Int(c[ch]))
                }
            }
            var widest = 0
            var widestRange = -1
            for ch in 0..<4 {
                let range = maxV[ch] - minV[ch]
                if range > widestRange { widestRange = range; widest = ch }
            }
            return widest
        }

        /// Population-weighted average color, rounded to the nearest
        /// integer per channel -- this bucket's final palette entry once
        /// splitting stops.
        var averageColor: [UInt8] {
            var sum = [0, 0, 0, 0]
            var total = 0
            for (packed, count) in colors {
                let c = unpack(packed)
                for ch in 0..<4 { sum[ch] += Int(c[ch]) * count }
                total += count
            }
            guard total > 0 else { return [0, 0, 0, 0] }
            return sum.map { UInt8(clamping: ($0 + total / 2) / total) }
        }
    }

    /// Reduces `rgba` (a flat `[UInt8]`, 4 bytes/pixel, `pixelCount`
    /// pixels) to at most `maxColors` (256 for PSMT8) palette entries and
    /// one 8-bit index per pixel. `palette.count` can be less than
    /// `maxColors` when the source image genuinely has fewer unique colors
    /// than that -- `TextureWriter.encodePSMT8` pads the remaining CLUT
    /// slots with `[0, 0, 0, 0]`, matching how a real, mostly-flat game
    /// texture's CLUT often doesn't use every one of its 256 real slots.
    static func quantize(rgba: [UInt8], pixelCount: Int, maxColors: Int = 256) -> (palette: [[UInt8]], indices: [UInt8]) {
        guard pixelCount > 0, rgba.count >= pixelCount * 4 else { return ([], []) }

        // Histogram first: every unique color's real pixel count, not just
        // its presence, is what population-weighted splitting/averaging
        // needs below.
        var histogram: [UInt32: Int] = [:]
        histogram.reserveCapacity(min(pixelCount, 65536))
        for i in 0..<pixelCount {
            let o = i * 4
            let packed = pack(rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3])
            histogram[packed, default: 0] += 1
        }

        var buckets = [Bucket(colors: histogram.map { ($0.key, $0.value) })]

        // Always split the bucket with the most unique colors -- the one
        // whose split will most reduce quantization error -- until either
        // the color budget is exhausted or every remaining bucket is down
        // to one color (nothing left worth splitting).
        while buckets.count < maxColors {
            guard let splitIndex = buckets.indices.max(by: { buckets[$0].colors.count < buckets[$1].colors.count }),
                  buckets[splitIndex].colors.count > 1
            else { break }

            var bucket = buckets.remove(at: splitIndex)
            let channel = bucket.widestChannel
            bucket.colors.sort { unpack($0.packed)[channel] < unpack($1.packed)[channel] }

            // Weighted-median split: walk the sorted colors accumulating
            // population until crossing half the bucket's total weight,
            // rather than splitting at the midpoint *array index* -- a flat
            // area (one color, huge count) shouldn't get diluted into
            // whichever half it lands in just because it's one array entry
            // among many rarely-used colors.
            let half = bucket.totalCount / 2
            var running = 0
            var splitAt = bucket.colors.count / 2
            for (i, entry) in bucket.colors.enumerated() {
                running += entry.count
                if running >= half {
                    splitAt = max(1, min(i + 1, bucket.colors.count - 1))
                    break
                }
            }
            buckets.append(Bucket(colors: Array(bucket.colors[..<splitAt])))
            buckets.append(Bucket(colors: Array(bucket.colors[splitAt...])))
        }

        let palette = buckets.map { $0.averageColor }

        // Map every *unique* source color to its nearest palette entry once
        // -- not every pixel individually -- and cache the result. A real
        // texture can be width*height in the tens of thousands while
        // carrying far fewer unique colors, so this is the difference
        // between an O(unique colors * palette size) and an O(pixels *
        // palette size) nearest-neighbor search.
        var nearestIndexCache: [UInt32: UInt8] = [:]
        nearestIndexCache.reserveCapacity(histogram.count)
        func nearestPaletteIndex(for packed: UInt32) -> UInt8 {
            if let cached = nearestIndexCache[packed] { return cached }
            let c = unpack(packed).map { Int($0) }
            var bestIndex = 0
            var bestDistance = Int.max
            for (i, entry) in palette.enumerated() {
                var distance = 0
                for ch in 0..<4 {
                    let d = Int(entry[ch]) - c[ch]
                    distance += d * d
                }
                if distance < bestDistance { bestDistance = distance; bestIndex = i }
            }
            let result = UInt8(clamping: bestIndex)
            nearestIndexCache[packed] = result
            return result
        }

        var indices = [UInt8](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            let o = i * 4
            let packed = pack(rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3])
            indices[i] = nearestPaletteIndex(for: packed)
        }

        return (palette, indices)
    }
}
