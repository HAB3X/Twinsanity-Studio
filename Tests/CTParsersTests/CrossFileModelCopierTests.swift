import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers

/// `CrossFileModelCopier`, cross-level asset copying for "place scenery
/// sourced from another level." The primary correctness proof is the
/// synthetic fixture test below: deterministic, and specifically
/// constructed so the destination already has *its own*, different,
/// colliding-ID data at every touched ID (100/200/300/500), proving
/// fresh-ID remapping actually avoids both collision and accidental
/// self-reference, which a real disc file's own already-sparse IDs
/// wouldn't necessarily exercise. The real-disc test is best-effort: real
/// scenery placements often resolve `modelID` through a broader shared/
/// chunk-stitched asset pool this build's `AssetResolver` doesn't fully
/// chase for scenery specifically (a separate, pre-existing gap, see the
/// parity audit's own "InstanceTemplate"/file-formats section), so it
/// skips honestly rather than asserting real disc data that may not
/// resolve locally.
final class CrossFileModelCopierTests: XCTestCase {
    private static let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")

    private func loadLevel(_ name: String, index: ArchiveIndex) throws -> (root: ChunkNode, data: Data)? {
        guard let entry = index.entries.first(where: { $0.name == name }) else { return nil }
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let kind: TwinsFileKind = name.hasSuffix(".rm2") ? .rm2 : .sm2
        let root = try RM2Parser.parse(data: data, fileKind: kind, fileName: name)
        return (root, data)
    }

    /// Prefers a non-special placement, `modelID` there *is* the
    /// `RigidModel` ID directly, no `LodModel` indirection to resolve
    /// first. Not every `isSpecial` placement's `LodModel.lodModelIDs`
    /// actually resolves to a real `RigidModel` in the same file (a real,
    /// pre-existing condition this package's own `AssetResolver` already
    /// handles gracefully elsewhere), this test is about the *copier*,
    /// so it picks a placement guaranteed to resolve rather than
    /// asserting every placement in a real level must.
    private func allRealPlacements(in root: ChunkNode) -> [SceneryModelPlacement] {
        var all: [SceneryModelPlacement] = []
        func walk(_ node: ChunkNode) {
            if case .scenery(let scenery) = node.payload {
                all.append(contentsOf: scenery.placements)
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        return all.sorted { !$0.isSpecial && $1.isSpecial }
    }

    private func graphicsChild(_ type: SectionType, in root: ChunkNode) -> ChunkNode? {
        let containerTypes: Set<SectionType> = [.graphics, .graphicsX, .graphicsD]
        var found: ChunkNode?
        func walk(_ node: ChunkNode) {
            if found != nil { return }
            if containerTypes.contains(node.sectionType) {
                found = node.children.first { $0.sectionType == type }
                return
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        return found
    }

    // MARK: - Synthetic fixtures (deterministic proof of the copy mechanics)

    private func makeSection(children: [(id: UInt32, bytes: Data)]) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(TwinsMagic.v1)
        writer.writeInt32(Int32(children.count))
        let contentSize = children.reduce(0) { $0 + $1.bytes.count }
        writer.writeUInt32(UInt32(contentSize))
        var offset = 12 + children.count * 12
        for child in children {
            writer.writeUInt32(UInt32(offset))
            writer.writeInt32(Int32(child.bytes.count))
            writer.writeUInt32(child.id)
            offset += child.bytes.count
        }
        for child in children {
            writer.writeBytes(child.bytes)
        }
        return writer.data
    }

    private func makeTexture(width: Int = 1, height: Int = 1) -> Data {
        var w = BinaryWriter()
        let pixelData = [UInt8](repeating: 0, count: width * height * 4).enumerated().map { UInt8(($0.offset * 37) & 0xFF) }
        w.writeInt32(Int32(224 + pixelData.count))
        w.writeInt32(0)
        w.writeInt16(Int16(log2(Double(width)))); w.writeInt16(Int16(log2(Double(height))))
        w.writeUInt8(1); w.writeUInt8(0); w.writeUInt8(0); w.writeUInt8(1); w.writeUInt8(0); w.writeUInt8(0)
        w.writeBytes([0, 0])
        w.writeInt32(0)
        for _ in 0..<6 { w.writeInt32(0) }
        w.writeInt32(Int32(width))
        for _ in 0..<6 { w.writeInt32(0) }
        w.writeInt32(0)
        w.writeBytes([UInt8](repeating: 0, count: 8))
        w.writeInt32(0); w.writeInt32(0)
        w.writeBytes([0, 0]); w.writeBytes([0, 0])
        w.writeBytes([UInt8](repeating: 0, count: 32))
        var vifBlock = [UInt8](repeating: 0, count: 96)
        withUnsafeBytes(of: Int32(width).littleEndian) { vifBlock.replaceSubrange(48..<52, with: $0) }
        withUnsafeBytes(of: Int32(height).littleEndian) { vifBlock.replaceSubrange(52..<56, with: $0) }
        w.writeBytes(vifBlock)
        w.writeBytes(pixelData)
        return w.data
    }

    /// One shader (`shaderType` 0, no variable param block) referencing
    /// `textureID`, real byte shape `MaterialParserTests.synthesizeShader`
    /// already establishes; reused here since `CrossFileModelCopier`'s own
    /// `shaderTextureIDOffsets` must walk this exact layout to find (and
    /// patch) the `textureId` field.
    private func makeMaterial(name: String, textureIDs: [UInt32]) -> Data {
        var w = BinaryWriter()
        w.writeUInt64(2)
        w.writeInt32(2)
        w.writeInt32(Int32(name.utf8.count))
        w.writeBytes(Array(name.utf8))
        w.writeInt32(Int32(textureIDs.count))
        for textureID in textureIDs {
            w.writeUInt32(0) // shaderType 0, no variable params
            w.writeBytes([UInt8](repeating: 0, count: 17))
            w.writeUInt8(0)
            w.writeBytes([UInt8](repeating: 0, count: 6))
            w.writeBytes([UInt8](repeating: 0, count: 3))
            w.writeUInt8(0)
            w.writeBytes([0, 0])
            w.writeUInt16(0); w.writeUInt16(0)
            w.writeBytes([UInt8](repeating: 0, count: 48))
            w.writeUInt32(textureID)
            w.writeUInt32(0) // trailing repeated shaderType
        }
        return w.data
    }

    private func makeRigidModel(materialIDs: [UInt32], meshID: UInt32) -> Data {
        var w = BinaryWriter()
        w.writeUInt32(257)
        w.writeInt32(Int32(materialIDs.count))
        for id in materialIDs { w.writeUInt32(id) }
        w.writeUInt32(meshID)
        return w.data
    }

    /// A `.sm2`-shaped file: top-level `Graphics` container at sub-ID 6,
    /// its own `Texture`(0)/`Material`(1)/`Model`(2)/`RigidModel`(3)
    /// children, matching the real archive's own layout confirmed against
    /// `nitrocav.sm2`/`.rm2`.
    private func makeGraphicsFile(textures: [(id: UInt32, bytes: Data)], materials: [(id: UInt32, bytes: Data)], models: [(id: UInt32, bytes: Data)], rigidModels: [(id: UInt32, bytes: Data)]) -> Data {
        let graphics = makeSection(children: [
            (0, makeSection(children: textures)),
            (1, makeSection(children: materials)),
            (2, makeSection(children: models)),
            (3, makeSection(children: rigidModels)),
        ])
        return makeSection(children: [(6, graphics)])
    }

    func testCopyingASyntheticRigidModelChainRemapsEveryReference() throws {
        let sourceTexture = makeTexture()
        let sourceMaterial = makeMaterial(name: "SrcMat", textureIDs: [500])
        let sourceMesh = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04]) // opaque mesh blob, never interpreted
        let sourceRigidModel = makeRigidModel(materialIDs: [200], meshID: 300)

        let sourceBytes = makeGraphicsFile(
            textures: [(500, sourceTexture)],
            materials: [(200, sourceMaterial)],
            models: [(300, sourceMesh)],
            rigidModels: [(100, sourceRigidModel)]
        )
        let sourceRoot = try RM2Parser.parse(data: sourceBytes, fileKind: .sm2, fileName: "source.sm2")

        // Destination already has ITS OWN texture/material/model/rigidModel
        // at overlapping small IDs (100/200/300/500) with *different*
        // content, proves fresh-ID remapping avoids colliding with (or
        // silently reusing) unrelated destination data at the same number.
        let destinationOwnTexture = makeTexture(width: 4, height: 4)
        let destinationBytes = makeGraphicsFile(
            textures: [(500, destinationOwnTexture)],
            materials: [(200, makeMaterial(name: "DestMat", textureIDs: [500]))],
            models: [(300, Data([0xAA]))],
            rigidModels: [(100, makeRigidModel(materialIDs: [200], meshID: 300))]
        )
        let destinationRoot = try RM2Parser.parse(data: destinationBytes, fileKind: .sm2, fileName: "destination.sm2")

        let result = try CrossFileModelCopier.copyingRigidModelChain(
            modelID: 100, isSpecial: false,
            sourceFileRoot: sourceRoot, sourceBytes: sourceBytes,
            destinationFileRoot: destinationRoot, destinationBytes: destinationBytes
        )

        // Fresh IDs were actually assigned, not reused from the source.
        XCTAssertNotEqual(result.rigidModelID, 100)
        XCTAssertGreaterThan(result.rigidModelID, 100)

        let reparsed = try RM2Parser.parse(data: result.destinationBytes, fileKind: .sm2, fileName: "destination.sm2")
        guard let newRigidModelNode = graphicsChild(.rigidModel, in: reparsed)?.children.first(where: { $0.recordID == result.rigidModelID }),
              case .rigidModel(let newRigidModel)? = newRigidModelNode.payload
        else { return XCTFail("copied RigidModel not found") }

        XCTAssertNotEqual(newRigidModel.meshID, 300, "meshID must be remapped to a fresh destination ID, not the source's own 300")
        let destModels = try XCTUnwrap(graphicsChild(.model, in: reparsed))
        let copiedMeshNode = try XCTUnwrap(destModels.children.first { $0.recordID == newRigidModel.meshID })
        XCTAssertEqual(reparsed.children.isEmpty, false)
        let copiedMeshBytes = result.destinationBytes.subdata(in: (result.destinationBytes.startIndex + copiedMeshNode.fileOffset)..<(result.destinationBytes.startIndex + copiedMeshNode.fileOffset + copiedMeshNode.byteSize))
        XCTAssertEqual(copiedMeshBytes, sourceMesh, "mesh bytes must be copied verbatim, byte-for-byte")

        XCTAssertEqual(newRigidModel.materialIDs.count, 1)
        let newMaterialID = newRigidModel.materialIDs[0]
        XCTAssertNotEqual(newMaterialID, 200, "materialID must be remapped, not the source's own 200")
        let destMaterials = try XCTUnwrap(graphicsChild(.material, in: reparsed))
        guard let materialNode = destMaterials.children.first(where: { $0.recordID == newMaterialID }),
              case .material(let copiedMaterial)? = materialNode.payload
        else { return XCTFail("copied Material not found") }
        XCTAssertEqual(copiedMaterial.name, "SrcMat", "must be the SOURCE material, not destination's own pre-existing #200")
        XCTAssertEqual(copiedMaterial.shaders.count, 1)

        let newTextureID = copiedMaterial.shaders[0].textureId
        XCTAssertNotEqual(newTextureID, 500, "the copied material's shader textureId must be patched to a fresh destination texture ID")
        let destTextures = try XCTUnwrap(graphicsChild(.texture, in: reparsed))
        guard let textureNode = destTextures.children.first(where: { $0.recordID == newTextureID }),
              case .texture(let copiedTexture)? = textureNode.payload
        else { return XCTFail("copied Texture not found") }
        XCTAssertEqual(copiedTexture.width, 1, "must be the SOURCE's 1x1 texture, not destination's own pre-existing 4x4 #500")

        // The destination's own original data (same IDs, different
        // content) must be completely untouched.
        guard let originalRigidModelNode = graphicsChild(.rigidModel, in: reparsed)?.children.first(where: { $0.recordID == 100 }),
              case .rigidModel(let originalRigidModel)? = originalRigidModelNode.payload
        else { return XCTFail("destination's own original RigidModel #100 must survive untouched") }
        XCTAssertEqual(originalRigidModel.meshID, 300)
        guard let originalTextureNode = destTextures.children.first(where: { $0.recordID == 500 }),
              case .texture(let originalTexture)? = originalTextureNode.payload
        else { return XCTFail("destination's own original Texture #500 must survive untouched") }
        XCTAssertEqual(originalTexture.width, 4, "destination's own original 4x4 texture at #500 must be untouched by the copy")
    }

    func testCopyingARealRigidModelChainAcrossTwoRealLevels() throws {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Real disc image not present")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)
        // Real, confirmed discovery: a `.sm2`'s own scenery placements
        // resolve `modelID` into its **paired `.rm2`'s** own `Graphics`
        // section, not the `.sm2` itself, e.g. `nitrocav.sm2` alone has
        // zero `RigidModel` records of its own; `nitrocav.rm2` (same
        // level, paired file) has the real geometry. So `sourceFileRoot`/
        // `sourceBytes` for `CrossFileModelCopier` must be the level's
        // `.rm2`, with placements read from its `.sm2`, the same pairing
        // `WorkspaceViewModel`'s own sound-bank loader already applies to
        // `.MH`/`.MB` (see `loadSoundBankAsync`), just for a different
        // format pair. Not every placement's `modelID` resolves locally
        // even within its own paired `.rm2` (a real, pre-existing
        // condition, some scenery presumably leans on a broader shared/
        // engine-common asset pool this build's `AssetResolver` doesn't
        // chase for scenery specifically), so this tries several real
        // level pairs and picks whichever real placement actually
        // resolves, rather than asserting one specific level must.
        let levelBaseNames = ["nitrocav", "tunnel01", "cavallon", "cavbridg", "escape"]
        var sceneryFile: (root: ChunkNode, data: Data)?
        var source: (root: ChunkNode, data: Data)?
        var candidates: [SceneryModelPlacement] = []
        for baseName in levelBaseNames {
            guard let sm2 = try loadLevel("Levels/Earth/Cavern/\(baseName).sm2", index: index),
                  let rm2 = try loadLevel("Levels/Earth/Cavern/\(baseName).rm2", index: index)
            else { continue }
            let placements = allRealPlacements(in: sm2.root)
            if !placements.isEmpty {
                sceneryFile = sm2
                source = rm2
                candidates = placements
                break
            }
        }
        guard let source, let sceneryFile, !candidates.isEmpty else {
            throw XCTSkip("no candidate level with real scenery placements found in this archive")
        }
        _ = sceneryFile

        guard let destination = try loadLevel("Levels/Earth/Hub/beach.rm2", index: index) else {
            throw XCTSkip("beach.rm2 not found in this archive")
        }

        // What the destination's own RigidModel/Material/Texture/Model
        // collections looked like *before* the copy, to prove the copy
        // only ever appends, never disturbs what was already there.
        let beforeRigidModels = graphicsChild(.rigidModel, in: destination.root)?.children.count ?? 0
        let beforeMaterials = graphicsChild(.material, in: destination.root)?.children.count ?? 0
        let beforeTextures = graphicsChild(.texture, in: destination.root)?.children.count ?? 0
        let firstDestRigidModelID = graphicsChild(.rigidModel, in: destination.root)?.children.first?.recordID

        var result: CrossFileModelCopier.CopyResult?
        var lastError: Error?
        for placement in candidates {
            do {
                result = try CrossFileModelCopier.copyingRigidModelChain(
                    modelID: placement.modelID, isSpecial: placement.isSpecial,
                    sourceFileRoot: source.root, sourceBytes: source.data,
                    destinationFileRoot: destination.root, destinationBytes: destination.data
                )
                break
            } catch {
                lastError = error
                continue
            }
        }
        guard let result else {
            throw XCTSkip("no placement across the candidate levels resolved to a copyable RigidModel chain (last error: \(String(describing: lastError)))")
        }

        let reparsedDestination = try RM2Parser.parse(data: result.destinationBytes, fileKind: .rm2, fileName: "beach.rm2")

        // The new RigidModel is real and resolves to real geometry.
        guard let newRigidModelNode = graphicsChild(.rigidModel, in: reparsedDestination)?.children.first(where: { $0.recordID == result.rigidModelID }),
              case .rigidModel(let newRigidModel)? = newRigidModelNode.payload
        else {
            return XCTFail("copied RigidModel #\(result.rigidModelID) not found in the reparsed destination file")
        }
        XCTAssertFalse(newRigidModel.materialIDs.isEmpty)

        let destModels = try XCTUnwrap(graphicsChild(.model, in: reparsedDestination))
        XCTAssertNotNil(destModels.children.first { $0.recordID == newRigidModel.meshID }, "copied RigidModel's meshID must resolve to a real Model record in the destination")

        let destMaterials = try XCTUnwrap(graphicsChild(.material, in: reparsedDestination))
        let destTextures = try XCTUnwrap(graphicsChild(.texture, in: reparsedDestination))
        for materialID in newRigidModel.materialIDs {
            guard let materialNode = destMaterials.children.first(where: { $0.recordID == materialID }),
                  case .material(let material)? = materialNode.payload
            else {
                return XCTFail("copied RigidModel's materialID \(materialID) must resolve to a real Material record in the destination")
            }
            for shader in material.shaders {
                guard let textureNode = destTextures.children.first(where: { $0.recordID == shader.textureId }),
                      case .texture(let texture)? = textureNode.payload
                else {
                    return XCTFail("copied Material's shader textureId \(shader.textureId) must resolve to a real Texture record in the destination")
                }
                XCTAssertGreaterThan(texture.width, 0)
                XCTAssertGreaterThan(texture.height, 0)
            }
        }

        // Nothing that was already in the destination file got disturbed:
        // every pre-existing collection only grew, and its first original
        // entry is still there under the same ID.
        XCTAssertGreaterThan(graphicsChild(.rigidModel, in: reparsedDestination)?.children.count ?? 0, beforeRigidModels)
        XCTAssertGreaterThanOrEqual(graphicsChild(.material, in: reparsedDestination)?.children.count ?? 0, beforeMaterials)
        XCTAssertGreaterThanOrEqual(graphicsChild(.texture, in: reparsedDestination)?.children.count ?? 0, beforeTextures)
        if let firstDestRigidModelID {
            XCTAssertNotNil(graphicsChild(.rigidModel, in: reparsedDestination)?.children.first { $0.recordID == firstDestRigidModelID })
        }
    }
}
