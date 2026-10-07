import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// `ModelX`/`SkinX`/`BlendSkinX` are a real, confirmed layout (ported from
/// the reference tool's own working `Load` methods, see `XboxMeshAssets.
/// swift`'s top-of-file doc comment), unlike this codebase's usual
/// "synthesize bytes matching an *assumed, unverified* layout" test
/// pattern for genuinely unreverse-engineered formats. These tests still
/// only exercise synthetic bytes (no real Xbox disc/archive with these
/// section types was available on this machine), they prove the parser
/// reads back exactly what these tests define using that real, cited
/// layout, not that it matches an actual on-disk Twinsanity Xbox file
/// byte-for-byte.
final class XboxMeshParserTests: XCTestCase {
    func testParseModelXReadsRigidVertexBlock() throws {
        var w = BinaryWriter()
        w.writeInt32(1) // subModelCount

        w.writeInt32(2)              // VertexCount
        w.writeUInt32(2 * 0x1C)      // DataSize (redundant, not checked by the parser)
        w.writeUInt32(1)             // GroupCount
        w.writeUInt32(2)             // GroupList[0]

        // Vertex 0
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3)
        w.writeUInt32(0xAABBCCDD)
        w.writeUInt8(10); w.writeUInt8(20); w.writeUInt8(30); w.writeUInt8(40)
        w.writeFloat32(0.5); w.writeFloat32(0.25)
        // Vertex 1
        w.writeFloat32(4); w.writeFloat32(5); w.writeFloat32(6)
        w.writeUInt32(0x11223344)
        w.writeUInt8(50); w.writeUInt8(60); w.writeUInt8(70); w.writeUInt8(80)
        w.writeFloat32(0.75); w.writeFloat32(1.0)

        w.writeUInt32(0) // real trailing zero

        var cursor = BinaryCursor(data: w.data)
        let asset = try XboxMeshParser.parseModelX(&cursor, recordID: 42)

        XCTAssertEqual(asset.id, 42)
        XCTAssertEqual(asset.subModels.count, 1)
        let sub = asset.subModels[0]
        XCTAssertEqual(sub.groupList, [2])
        XCTAssertEqual(sub.vertices.count, 2)
        XCTAssertEqual(sub.vertices[0].position, SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(sub.vertices[0].packedNormalsRaw, 0xAABBCCDD)
        XCTAssertEqual(sub.vertices[0].color, SIMD4<UInt8>(10, 20, 30, 40))
        XCTAssertEqual(sub.vertices[0].uv, SIMD2<Float>(0.5, 0.25))
        XCTAssertEqual(sub.vertices[1].position, SIMD3<Float>(4, 5, 6))
        XCTAssertEqual(sub.vertices[1].uv, SIMD2<Float>(0.75, 1.0))
        XCTAssertEqual(cursor.position, w.data.count)
    }

    func testParseSkinXReadsJointsAndSkinnedVertexBlockWithNoBlendShapes() throws {
        var w = BinaryWriter()
        w.writeInt32(1) // subModelCount

        w.writeUInt32(7)            // MaterialID
        w.writeUInt32(1 * 0x30)     // DataSize (redundant)
        w.writeInt32(1)             // VertexCount
        w.writeUInt32(2)            // GroupJointCount (redundant)
        w.writeUInt32(1)            // GroupCount
        w.writeUInt32(1)            // GroupList[0]
        w.writeUInt32(2)            // JointCountList[0]
        w.writeUInt32(100); w.writeUInt32(200) // GroupJoints[0]

        // One skinned vertex
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3)
        w.writeFloat32(0.5); w.writeFloat32(0.3); w.writeFloat32(0.2)
        w.writeUInt16(1); w.writeUInt16(2); w.writeUInt16(3)
        w.writeUInt16(0) // UnkShort4, confirmed always zero
        w.writeUInt32(0xDEADBEEF)
        w.writeUInt8(1); w.writeUInt8(2); w.writeUInt8(3); w.writeUInt8(4)
        w.writeFloat32(0.1); w.writeFloat32(0.2)

        var cursor = BinaryCursor(data: w.data)
        let asset = try XboxMeshParser.parseSkinX(&cursor, recordID: 5)

        XCTAssertEqual(asset.id, 5)
        XCTAssertEqual(asset.subModels.count, 1)
        let sub = asset.subModels[0]
        XCTAssertEqual(sub.materialID, 7)
        XCTAssertEqual(sub.groupList, [1])
        XCTAssertEqual(sub.groupJoints, [[100, 200]])
        XCTAssertEqual(sub.vertices.count, 1)
        let v = sub.vertices[0]
        XCTAssertEqual(v.position, SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(v.jointWeights, SIMD3<Float>(0.5, 0.3, 0.2))
        XCTAssertEqual(v.jointIndices, SIMD3<UInt16>(1, 2, 3))
        XCTAssertEqual(v.unkShort4, 0)
        XCTAssertEqual(v.packedNormalsRaw, 0xDEADBEEF)
        XCTAssertEqual(v.color, SIMD4<UInt8>(1, 2, 3, 4))
        XCTAssertTrue(v.blendShapeDeltas.isEmpty, "SkinX has no blend shapes at all")
        XCTAssertEqual(cursor.position, w.data.count)
    }

    /// `BlendSkinX` shares `SkinX`'s exact submodel/vertex layout, then
    /// appends a blend-shape-major, vertex-minor delta block, ported from
    /// `BlendSkinX.cs.Load`'s own nested loop order.
    func testParseBlendSkinXReadsPerVertexBlendShapeDeltas() throws {
        var w = BinaryWriter()
        w.writeInt32(1)  // subModelCount
        w.writeUInt32(2) // BlendShapeCount

        w.writeUInt32(3)        // MaterialID
        w.writeUInt32(2 * 0x30) // DataSize (redundant)
        w.writeInt32(2)         // VertexCount
        w.writeUInt32(0)        // GroupJointCount (redundant)
        w.writeUInt32(0)        // GroupCount, no groups for this test

        // Two skinned vertices (base pose)
        for i in 0..<2 {
            let base = Float(i)
            w.writeFloat32(base); w.writeFloat32(base); w.writeFloat32(base)
            w.writeFloat32(1); w.writeFloat32(0); w.writeFloat32(0)
            w.writeUInt16(0); w.writeUInt16(0); w.writeUInt16(0)
            w.writeUInt16(0)
            w.writeUInt32(0)
            w.writeUInt8(255); w.writeUInt8(255); w.writeUInt8(255); w.writeUInt8(255)
            w.writeFloat32(0); w.writeFloat32(0)
        }

        // Blend shape 0 deltas (vertex 0, vertex 1)
        w.writeFloat32(0.1); w.writeFloat32(0.2); w.writeFloat32(0.3)
        w.writeFloat32(1.1); w.writeFloat32(1.2); w.writeFloat32(1.3)
        // Blend shape 1 deltas (vertex 0, vertex 1)
        w.writeFloat32(-0.1); w.writeFloat32(-0.2); w.writeFloat32(-0.3)
        w.writeFloat32(-1.1); w.writeFloat32(-1.2); w.writeFloat32(-1.3)

        var cursor = BinaryCursor(data: w.data)
        let asset = try XboxMeshParser.parseBlendSkinX(&cursor, recordID: 9)

        XCTAssertEqual(asset.id, 9)
        XCTAssertEqual(asset.blendShapeCount, 2)
        XCTAssertEqual(asset.subModels.count, 1)
        let vertices = asset.subModels[0].vertices
        XCTAssertEqual(vertices.count, 2)

        XCTAssertEqual(vertices[0].blendShapeDeltas.count, 2)
        XCTAssertEqual(vertices[0].blendShapeDeltas[0], SIMD3<Float>(0.1, 0.2, 0.3), accuracy: 0.0001)
        XCTAssertEqual(vertices[0].blendShapeDeltas[1], SIMD3<Float>(-0.1, -0.2, -0.3), accuracy: 0.0001)

        XCTAssertEqual(vertices[1].blendShapeDeltas.count, 2)
        XCTAssertEqual(vertices[1].blendShapeDeltas[0], SIMD3<Float>(1.1, 1.2, 1.3), accuracy: 0.0001)
        XCTAssertEqual(vertices[1].blendShapeDeltas[1], SIMD3<Float>(-1.1, -1.2, -1.3), accuracy: 0.0001)

        XCTAssertEqual(cursor.position, w.data.count)
    }

    func testParseModelXWithZeroSubModelsConsumesExactlyFourBytes() throws {
        var w = BinaryWriter()
        w.writeInt32(0)
        var cursor = BinaryCursor(data: w.data)
        let asset = try XboxMeshParser.parseModelX(&cursor, recordID: 1)
        XCTAssertTrue(asset.subModels.isEmpty)
        XCTAssertEqual(cursor.position, 4)
    }

    /// A truncated record throws (via `BinaryCursor`'s own bounds checks)
    /// rather than silently returning a partial/garbage mesh, "fail
    /// closed," matching this codebase's usual discipline for genuinely
    /// unverified data, kept here even though this specific layout is real.
    func testParseModelXThrowsOnTruncatedData() throws {
        var w = BinaryWriter()
        w.writeInt32(1)   // subModelCount
        w.writeInt32(5)   // VertexCount, claims 5 vertices
        w.writeUInt32(5 * 0x1C)
        w.writeUInt32(0)  // GroupCount
        // ...but no vertex bytes follow at all.
        var cursor = BinaryCursor(data: w.data)
        XCTAssertThrowsError(try XboxMeshParser.parseModelX(&cursor, recordID: 1))
    }
}

private func XCTAssertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
}
