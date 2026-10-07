import Foundation

/// Standard Sony PS-ADPCM ("VAG") decoder -- a publicly documented,
/// widely-implemented PS1/PS2 audio codec, not something reverse
/// engineered from these files specifically. 16-byte blocks, 4-bit
/// samples, 28 samples/block, 5 fixed predictor-coefficient pairs.
public enum WOCADPCMDecoder {
    private static let f0: [Double] = [0.0, 60.0 / 64.0, 115.0 / 64.0, 98.0 / 64.0, 122.0 / 64.0]
    private static let f1: [Double] = [0.0, 0.0, -52.0 / 64.0, -55.0 / 64.0, -60.0 / 64.0]

    public static func decode(_ data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        var out: [Int16] = []
        out.reserveCapacity((bytes.count / 16) * 28)

        var hist1 = 0.0
        var hist2 = 0.0

        var offset = 0
        while offset + 16 <= bytes.count {
            let predictorIndex = Int(bytes[offset] >> 4)
            let shift = Int(bytes[offset] & 0xF)
            let flag = bytes[offset + 1]
            guard predictorIndex < f0.count else { offset += 16; continue }
            if flag == 7 { break } // standard VAG end-of-stream marker

            for i in 0..<28 {
                let byteIndex = offset + 2 + i / 2
                let raw = bytes[byteIndex]
                let nibble = (i % 2 == 0) ? (raw & 0xF) : (raw >> 4)
                let signExtended = Int16(bitPattern: UInt16(nibble) << 12) >> shift
                let predicted = Double(signExtended) + f0[predictorIndex] * hist1 + f1[predictorIndex] * hist2
                let clamped = max(-32768.0, min(32767.0, predicted))
                hist2 = hist1
                hist1 = clamped
                out.append(Int16(clamped.rounded()))
            }
            offset += 16
        }
        return out
    }
}
