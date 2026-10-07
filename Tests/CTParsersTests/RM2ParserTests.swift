import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class RM2ParserTests: XCTestCase {
    /// A minimal 224-byte PS2 texture header (see `TextureParserTests`) plus
    /// a 1x1 PSMCT32 pixel, sized to fit as a leaf record.
    private func synthesizeTextureRecord() -> Data {
        var w = BinaryWriter()
        let pixelData: [UInt8] = [10, 20, 30, 0] // 1 pixel, alpha=0 -> 0
        w.writeInt32(Int32(224 + pixelData.count)) // texSize
        w.writeInt32(0) // unkInt
        w.writeInt16(0); w.writeInt16(0) // w=h=0 -> 1x1
        w.writeUInt8(1) // m
        w.writeUInt8(0) // format = PSMCT32
        w.writeUInt8(0); w.writeUInt8(1); w.writeUInt8(0); w.writeUInt8(0)
        w.writeBytes([0, 0])
        w.writeInt32(0)
        for _ in 0..<6 { w.writeInt32(0) }
        w.writeInt32(1)
        for _ in 0..<6 { w.writeInt32(0) }
        w.writeInt32(0)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeInt32(0)
        w.writeBytes([0, 0]); w.writeBytes([0, 0])
        w.writeBytes([UInt8](repeating: 0, count: 32))
        w.writeBytes([UInt8](repeating: 0, count: 96))
        w.writeBytes(pixelData)
        return w.data
    }

    /// Wraps `content` as a chunk section with a single indexed sub-item.
    private func synthesizeSection(magic: UInt32 = TwinsMagic.v1, entryID: UInt32, entryContent: Data) -> Data {
        var w = BinaryWriter()
        w.writeUInt32(magic)
        w.writeInt32(1) // record count
        w.writeUInt32(UInt32(entryContent.count)) // content size
        w.writeUInt32(24) // offset: 12-byte section header + 12-byte index entry
        w.writeInt32(Int32(entryContent.count))
        w.writeUInt32(entryID)
        w.writeBytes(entryContent)
        return w.data
    }

    func testFullThreeTierTreeResolvesToADecodedTexture() throws {
        let textureRecord = synthesizeTextureRecord()
        // Tier 2: a "Texture" collection section holding one Texture leaf (ID 3).
        let textureSection = synthesizeSection(entryID: 3, entryContent: textureRecord)
        // Tier 1: a "Graphics" container section whose sub-ID 0 -> Texture collection.
        let graphicsSection = synthesizeSection(entryID: 0, entryContent: textureSection)
        // Tier 0: the file itself, sub-ID 11 -> Graphics container.
        let fileData = synthesizeSection(entryID: 11, entryContent: graphicsSection)

        let root = try RM2Parser.parse(data: fileData, fileKind: .rm2, fileName: "test.RM2")

        XCTAssertEqual(root.children.count, 1)
        let graphicsNode = root.children[0]
        XCTAssertEqual(graphicsNode.sectionType, .graphics)
        XCTAssertEqual(graphicsNode.children.count, 1)

        let textureSectionNode = graphicsNode.children[0]
        XCTAssertEqual(textureSectionNode.sectionType, .texture)
        XCTAssertEqual(textureSectionNode.children.count, 1)

        let textureLeaf = textureSectionNode.children[0]
        XCTAssertEqual(textureLeaf.recordID, 3)
        guard case .texture(let asset) = textureLeaf.payload else {
            return XCTFail("expected a decoded texture payload, got \(String(describing: textureLeaf.payload))")
        }
        XCTAssertEqual(asset.width, 1)
        XCTAssertEqual(asset.height, 1)
        XCTAssertEqual(Array(asset.rgba[0...3]), [10, 20, 30, 0])
    }

    func testUnknownTopLevelIDBecomesRawLeafInsteadOfCrashing() throws {
        let fileData = synthesizeSection(entryID: 99, entryContent: Data([1, 2, 3]))
        let root = try RM2Parser.parse(data: fileData, fileKind: .rm2, fileName: "weird.RM2")
        XCTAssertEqual(root.children.count, 1)
        guard case .raw(let byteCount) = root.children[0].payload else {
            return XCTFail("expected a raw leaf")
        }
        XCTAssertEqual(byteCount, 3)
    }
}
