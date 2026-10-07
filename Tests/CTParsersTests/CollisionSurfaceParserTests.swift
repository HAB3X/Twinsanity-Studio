import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class CollisionSurfaceParserTests: XCTestCase {
    /// Exact 114-byte layout ported from `CollisionSurface.cs`'s `Load`.
    func testParsesAllFieldsInOrder() throws {
        var w = BinaryWriter()
        w.writeUInt32(0x001FF0F0) // Flags
        w.writeUInt16(42)         // SurfaceID
        w.writeUInt16(1)          // Sound_1
        w.writeUInt16(2)          // Sound_2
        w.writeUInt16(3)          // Particle_1
        w.writeUInt16(4)          // Particle_2
        w.writeUInt16(5)          // Sound_3
        w.writeUInt16(6)          // Sound_4
        w.writeUInt16(7)          // Particle_3
        w.writeUInt16(65535)      // Sound_5 (unassigned)
        w.writeUInt16(65535)      // Sound_6 (unassigned)
        w.writeUInt16(0)          // padding, discarded
        for i in 1...10 { w.writeFloat32(Float(i)) } // UnkFloat1..10
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) // UnkVector
        w.writeFloat32(-1); w.writeFloat32(-2); w.writeFloat32(-3); w.writeFloat32(-4) // UnkBoundingBox1
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3); w.writeFloat32(4) // UnkBoundingBox2

        XCTAssertEqual(w.count, 114)

        var cursor = BinaryCursor(data: w.data)
        let surface = try CollisionSurfaceParser.parse(&cursor, recordID: 9)

        XCTAssertEqual(surface.id, 9)
        XCTAssertEqual(surface.surfaceID, 42)
        XCTAssertEqual(surface.flags, 0x001FF0F0)
        XCTAssertEqual(surface.sound1, 1)
        XCTAssertEqual(surface.particle3, 7)
        XCTAssertEqual(surface.unkFloat1, 1)
        XCTAssertEqual(surface.unkFloat10, 10)
        XCTAssertEqual(surface.unkVector, SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(surface.unkBoundingBox2, SIMD4<Float>(1, 2, 3, 4))
        XCTAssertEqual(cursor.position, w.count)
    }

    func testAssignedIDsFilterOutTheSentinel() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeUInt16(1) // SurfaceID
        w.writeUInt16(100) // Sound_1 assigned
        w.writeUInt16(65535) // Sound_2 unassigned
        w.writeUInt16(65535) // Particle_1 unassigned
        w.writeUInt16(200) // Particle_2 assigned
        w.writeUInt16(65535); w.writeUInt16(65535); w.writeUInt16(65535); w.writeUInt16(65535); w.writeUInt16(65535)
        w.writeUInt16(0) // padding
        for _ in 0..<10 { w.writeFloat32(0) }
        for _ in 0..<12 { w.writeFloat32(0) }

        var cursor = BinaryCursor(data: w.data)
        let surface = try CollisionSurfaceParser.parse(&cursor, recordID: 1)

        XCTAssertEqual(surface.assignedSoundIDs, [100])
        XCTAssertEqual(surface.assignedParticleIDs, [200])
    }

    /// "Collision Property Semantics" (roadmap item 4b): `experimentalFlag`/
    /// `setExperimentalFlag` are plain bit-index get/set over `flags` , 
    /// this only proves that arithmetic is correct, not that any of these
    /// four bits actually mean "Walkable by Player"/etc. in-game (no
    /// reference source confirms that, see `CollisionSurfaceInfo.
    /// ExperimentalFlagBit`'s own doc comment).
    func testExperimentalFlagBitsToggleIndependently() throws {
        var w = BinaryWriter()
        w.writeUInt32(0) // Flags, start with every bit clear
        w.writeUInt16(1)
        for _ in 0..<9 { w.writeUInt16(65535) }
        w.writeUInt16(0)
        for _ in 0..<10 { w.writeFloat32(0) }
        for _ in 0..<12 { w.writeFloat32(0) }

        var cursor = BinaryCursor(data: w.data)
        var surface = try CollisionSurfaceParser.parse(&cursor, recordID: 1)

        XCTAssertFalse(surface.experimentalFlag(.walkableByPlayer))
        XCTAssertFalse(surface.experimentalFlag(.climbable))

        surface.setExperimentalFlag(.walkableByPlayer, true)
        surface.setExperimentalFlag(.dealsDamage, true)
        XCTAssertTrue(surface.experimentalFlag(.walkableByPlayer))
        XCTAssertFalse(surface.experimentalFlag(.walkableByAI))
        XCTAssertTrue(surface.experimentalFlag(.dealsDamage))
        XCTAssertFalse(surface.experimentalFlag(.climbable))
        XCTAssertEqual(surface.flags, 0b0101)

        surface.setExperimentalFlag(.walkableByPlayer, false)
        XCTAssertFalse(surface.experimentalFlag(.walkableByPlayer))
        XCTAssertEqual(surface.flags, 0b0100)
    }

    /// Every entry of `flagNames` is real evidence of absence, not a stand-in
    /// forgotten to fill in, see that property's own doc comment.
    func testFlagNamesAreAllEmptyBecauseNoneAreConfirmed() {
        XCTAssertEqual(CollisionSurfaceInfo.flagNames.count, 32)
        XCTAssertTrue(CollisionSurfaceInfo.flagNames.allSatisfy(\.isEmpty))
    }

    func testWriterRoundTripsExactBytesIncludingPadding() throws {
        var w = BinaryWriter()
        w.writeUInt32(0x001FF0F0)
        w.writeUInt16(42)
        w.writeUInt16(1); w.writeUInt16(2); w.writeUInt16(3); w.writeUInt16(4)
        w.writeUInt16(5); w.writeUInt16(6); w.writeUInt16(7); w.writeUInt16(65535); w.writeUInt16(65535)
        w.writeUInt16(0xBEEF) // real, non-zero padding, must round-trip, not get zeroed
        for i in 1...10 { w.writeFloat32(Float(i)) }
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(-1); w.writeFloat32(-2); w.writeFloat32(-3); w.writeFloat32(-4)
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3); w.writeFloat32(4)

        var cursor = BinaryCursor(data: w.data)
        let surface = try CollisionSurfaceParser.parse(&cursor, recordID: 9)
        let reEncoded = CollisionSurfaceWriter.write(surface)

        XCTAssertEqual(reEncoded, w.data)
    }
}
