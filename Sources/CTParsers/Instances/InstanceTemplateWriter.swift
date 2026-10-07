import Foundation
import CTCore
import CTModels

/// Byte-exact encoders for `InstanceTemplateInfo`/`InstanceTemplateDemoInfo`
///, the write-back half of `WorldPlacementParser.parseInstanceTemplate`/
/// `parseInstanceTemplateDemo`, mirroring each field-for-field in the exact
/// same order those parsers read them, including the demo build's packed
/// byte-count header and 2-byte (not 6-byte) `unkFlags`.
public enum InstanceTemplateWriter {
    public static func encode(_ template: InstanceTemplateInfo) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(UInt32(template.name.utf8.count))
        writer.writeASCIIString(template.name)
        writer.writeUInt16(template.objectID)
        writer.writeUInt16(template.bitfield)
        writer.writeUInt32(template.headerInt1)
        writer.writeUInt32(template.headerInt2)
        writer.writeUInt32(template.headerInt3)
        if template.headerInt1 == 1, let unkShort = template.unkShort {
            writer.writeUInt16(unkShort)
        }
        writer.writeBytes(paddedOrTruncated(template.unkFlags, to: 6))
        writer.writeUInt32(template.properties)
        writeUInt32List(&writer, template.flags)
        writeFloatList(&writer, template.floats)
        writeUInt32List(&writer, template.ints)
        return writer.data
    }

    public static func encode(_ template: InstanceTemplateDemoInfo) -> Data {
        // The demo build's single-byte counts can't represent more than
        // 255 entries, a real format ceiling. Truncating the lists
        // themselves (not just clamping the reported count) keeps the
        // declared count and the actual written element count in sync;
        // reporting a smaller count while still writing every element
        // would leave trailing bytes the parser never consumes, corrupting
        // whatever record follows this one in the same section.
        let flags = Array(template.flags.prefix(255))
        let floats = Array(template.floats.prefix(255))
        let ints = Array(template.ints.prefix(255))

        var writer = BinaryWriter()
        writer.writeUInt32(UInt32(template.name.utf8.count))
        writer.writeASCIIString(template.name)
        writer.writeUInt16(template.objectID)
        writer.writeUInt16(template.bitfield)
        writer.writeUInt32(template.headerInt1)
        writer.writeUInt32(template.headerInt2)
        writer.writeUInt32(template.headerInt3)
        if template.headerInt1 == 1, let unkShort = template.unkShort {
            writer.writeUInt16(unkShort)
        }
        writer.writeBytes(paddedOrTruncated(template.unkFlags, to: 2))
        writer.writeUInt8(UInt8(flags.count))
        writer.writeUInt8(UInt8(floats.count))
        writer.writeUInt8(UInt8(ints.count))
        writer.writeUInt8(0) // padding, matches parseInstanceTemplateDemo's own discarded read
        writer.writeUInt32(template.properties)
        for value in flags { writer.writeUInt32(value) }
        for value in floats { writer.writeFloat32(value) }
        for value in ints { writer.writeUInt32(value) }
        return writer.data
    }

    private static func writeUInt32List(_ writer: inout BinaryWriter, _ values: [UInt32]) {
        writer.writeInt32(Int32(values.count))
        for value in values { writer.writeUInt32(value) }
    }

    private static func writeFloatList(_ writer: inout BinaryWriter, _ values: [Float]) {
        writer.writeInt32(Int32(values.count))
        for value in values { writer.writeFloat32(value) }
    }

    /// `unkFlags` is a fixed-size field (6 bytes retail, 2 bytes demo) , 
    /// pads a too-short array with zeros or truncates a too-long one so an
    /// edited copy always writes exactly `count` bytes regardless of
    /// whatever length the in-memory array happens to be.
    private static func paddedOrTruncated(_ bytes: [UInt8], to count: Int) -> [UInt8] {
        if bytes.count == count { return bytes }
        if bytes.count > count { return Array(bytes.prefix(count)) }
        return bytes + Array(repeating: 0, count: count - bytes.count)
    }
}
