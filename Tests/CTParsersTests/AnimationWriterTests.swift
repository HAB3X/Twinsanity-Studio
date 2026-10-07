import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// `AnimationWriter`, the write-back half of `AnimationParser`, ported
/// from `Twinsanity/Items/Code/Animation.cs`'s real `Save`. Every test
/// here proves `parse(write(parse(x))) == parse(x)`, the same discipline
/// every other writer in this package is held to.
final class AnimationWriterTests: XCTestCase {
    private func buildRecord(bitfield: UInt32, bodyPacker: UInt32, bodyFrames: [[Int16]], jointCount: Int, staticCount: Int) -> Data {
        var w = BinaryWriter()
        w.writeUInt32(bitfield)
        w.writeUInt32(bodyPacker)
        w.writeUInt16(UInt16(bodyFrames.count))
        for _ in 0..<jointCount {
            w.writeUInt16(0x0001); w.writeUInt16(0x0002); w.writeUInt16(0x0003); w.writeUInt16(0x0004)
        }
        for _ in 0..<staticCount {
            w.writeInt16(4096)
        }
        for frame in bodyFrames {
            for value in frame { w.writeInt16(value) }
        }
        // Empty facial track.
        w.writeUInt32(0)
        w.writeUInt16(0)
        return w.data
    }

    func testRoundTripsExactlyForASimpleRecord() throws {
        let bodyPacker: UInt32 = 1 | (2 << 0xA) | (2 << 0x16) // joints=1, staticRaw=2 (count=1), components=2
        let data = buildRecord(bitfield: 0xDEADBEEF, bodyPacker: bodyPacker, bodyFrames: [[100, 200], [300, 400]], jointCount: 1, staticCount: 1)
        var cursor = BinaryCursor(data: data)
        let parsed = try AnimationParser.parse(&cursor, recordID: 1)

        let reEncoded = AnimationWriter.write(parsed)
        XCTAssertEqual(reEncoded, data, "re-encoding an unmodified parse must reproduce the original bytes exactly")

        var reCursor = BinaryCursor(data: reEncoded)
        let reparsed = try AnimationParser.parse(&reCursor, recordID: 1)
        XCTAssertEqual(reparsed.bitfield, 0xDEADBEEF)
        XCTAssertEqual(reparsed.body.frames.map(\.values), [[100, 200], [300, 400]])
    }

    /// The real, load-bearing case: bits 7–10 of the packer word are never
    /// touched by the reference's own `Animation.Save` (its three clear
    /// masks leave a 4-bit gap between the joint-count field and the
    /// static-transform-count field), a naive re-pack from just
    /// jointCount/transformCount/componentsPerFrame would silently zero
    /// them. Uses `0b1101 = 13` (nonzero, and not all-1s, so both a stray
    /// zero-fill and a stray all-ones bug would be caught).
    func testReservedPackerBitsSurviveARoundTrip() throws {
        let reservedBits: UInt32 = 0b1101
        let bodyPacker: UInt32 = 1 | (reservedBits << 7) | (2 << 0xA) | (2 << 0x16)
        let data = buildRecord(bitfield: 0, bodyPacker: bodyPacker, bodyFrames: [[1, 2]], jointCount: 1, staticCount: 1)
        var cursor = BinaryCursor(data: data)
        let parsed = try AnimationParser.parse(&cursor, recordID: 1)
        XCTAssertEqual(parsed.body.reservedPackerBits, reservedBits)

        let reEncoded = AnimationWriter.write(parsed)
        XCTAssertEqual(reEncoded, data)
    }

    /// "Add Timeline"/"Delete Timeline" (`AnimationInspectorView`'s Add/
    /// Delete Frame): appending a zero-filled frame must produce a record
    /// that reparses with the new frame count and componentsPerFrame-sized
    /// zero values, not the reference's own `AnimatedTransform(TotalFrames)`
    /// bug, which sizes a new frame using the *frame count* instead of
    /// components-per-frame (a real, unfixed defect in `Animation.cs`'s
    /// `AnimatedTransform` constructor call site in `btnAddTimeline_Click`
    ///, deliberately not ported, see `AnimationInspectorView`'s own doc
    /// comment).
    func testAppendingAZeroFilledFrameGrowsTheRecordCorrectly() throws {
        let bodyPacker: UInt32 = 0 | (0 << 0xA) | (3 << 0x16) // 0 joints, 0 static, 3 components/frame
        let data = buildRecord(bitfield: 0, bodyPacker: bodyPacker, bodyFrames: [[1, 2, 3]], jointCount: 0, staticCount: 0)
        var cursor = BinaryCursor(data: data)
        var parsed = try AnimationParser.parse(&cursor, recordID: 1)
        XCTAssertEqual(parsed.body.componentsPerFrame, 3)

        parsed.body.frames.append(AnimFrame(values: [Int16](repeating: 0, count: parsed.body.componentsPerFrame)))
        let grown = AnimationWriter.write(parsed)

        var growCursor = BinaryCursor(data: grown)
        let reparsed = try AnimationParser.parse(&growCursor, recordID: 1)
        XCTAssertEqual(reparsed.body.totalFrames, 2)
        XCTAssertEqual(reparsed.body.frames[0].values, [1, 2, 3])
        XCTAssertEqual(reparsed.body.frames[1].values, [0, 0, 0])
    }

    func testDeletingTheLastFrameShrinksTheRecordCorrectly() throws {
        let bodyPacker: UInt32 = 0 | (0 << 0xA) | (2 << 0x16)
        let data = buildRecord(bitfield: 0, bodyPacker: bodyPacker, bodyFrames: [[1, 2], [3, 4]], jointCount: 0, staticCount: 0)
        var cursor = BinaryCursor(data: data)
        var parsed = try AnimationParser.parse(&cursor, recordID: 1)

        parsed.body.frames.removeLast()
        let shrunk = AnimationWriter.write(parsed)

        var shrinkCursor = BinaryCursor(data: shrunk)
        let reparsed = try AnimationParser.parse(&shrinkCursor, recordID: 1)
        XCTAssertEqual(reparsed.body.totalFrames, 1)
        XCTAssertEqual(reparsed.body.frames[0].values, [1, 2])
    }
}
