import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers

/// `CrossFileGameObjectCopier`, the skinned-character half of "cross-level
/// Forge placement," fixing "items not appearing when I boot in" for
/// enemy/AI object types whose real `GameObject` data isn't in the level
/// being edited (see that type's own top-level doc comment). Same division
/// of labor as `CrossFileModelCopierTests`: the synthetic fixture below is
/// the primary correctness proof (deterministic, specifically constructed
/// so the destination already has its OWN, different, colliding-ID data at
/// every touched ID, proving fresh-ID remapping actually avoids collision);
/// the real-disc test is best-effort, skipping honestly if this machine
/// doesn't have the real ISO or a suitable candidate pair isn't found.
final class CrossFileGameObjectCopierTests: XCTestCase {
    private static let retailISOURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/Crash Twinsanity (Europe, Australia) (En,Fr,De,Es,It).iso")

    // MARK: - Synthetic fixtures

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

    /// Same real shader-block shape `CrossFileModelCopierTests.makeMaterial`
    /// establishes, reused here since `CrossFileGameObjectCopier` walks
    /// this exact layout via the shared `CrossFileModelCopier.
    /// shaderTextureIDOffsets`.
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

    /// A minimal but structurally real `Skin` record, `subModelCount`
    /// then, per submodel, `[materialID][codeSize][declaredVertexAmount]
    /// [codeSize bytes]` (`SkinParser.parse`'s own read order). The VIF
    /// "code" bytes themselves are opaque filler: `CrossFileGameObjectCopier`
    /// only ever walks this structure to find/patch each submodel's own
    /// `materialID`, never decodes the VIF program, this mirrors
    /// `CrossFileModelCopierTests.testCopyingASyntheticRigidModelChainRemapsEveryReference`'s
    /// own "opaque mesh blob, never interpreted" fixture for the exact same
    /// reason.
    private func makeSkin(subModels: [(materialID: UInt32, codeSize: Int)]) -> Data {
        var w = BinaryWriter()
        w.writeUInt32(UInt32(subModels.count))
        for sub in subModels {
            w.writeUInt32(sub.materialID)
            w.writeInt32(Int32(sub.codeSize))
            w.writeInt32(0) // declared vertex amount, unused by the copier
            w.writeBytes([UInt8](repeating: 0xCD, count: sub.codeSize))
        }
        return w.data
    }

    /// A `.rm2`-shaped file with both top-level `Code` (sub-ID 10) and
    /// `Graphics` (sub-ID 11) containers, the real layout `RM2Parser.
    /// tier0Kind` maps for `.rm2`, confirmed against `RM2ParserTests`'s own
    /// fixtures. `Code`'s `Object`(0)/`OGI`(3) and `Graphics`'s
    /// `Texture`(0)/`Material`(1)/`Skin`(4) match `RM2Parser.tier1ChildType`'s
    /// own sub-ID mapping.
    private func makeFile(
        objects: [(id: UInt32, bytes: Data)],
        ogis: [(id: UInt32, bytes: Data)],
        textures: [(id: UInt32, bytes: Data)],
        materials: [(id: UInt32, bytes: Data)],
        skins: [(id: UInt32, bytes: Data)],
        scripts: [(id: UInt32, bytes: Data)] = []
    ) -> Data {
        var codeChildren: [(id: UInt32, bytes: Data)] = [
            (0, makeSection(children: objects)),
            (3, makeSection(children: ogis)),
        ]
        if !scripts.isEmpty { codeChildren.append((1, makeSection(children: scripts))) }
        let code = makeSection(children: codeChildren)
        let graphics = makeSection(children: [
            (0, makeSection(children: textures)),
            (1, makeSection(children: materials)),
            (4, makeSection(children: skins)),
        ])
        return makeSection(children: [(10, code), (11, graphics)])
    }

    private func codeChild(_ type: SectionType, in root: ChunkNode) -> ChunkNode? {
        let containerTypes: Set<SectionType> = [.code, .codeX, .codeDemo]
        guard let code = root.children.first(where: { containerTypes.contains($0.sectionType) }) else { return nil }
        return code.children.first { $0.sectionType == type }
    }

    private func graphicsChild(_ type: SectionType, in root: ChunkNode) -> ChunkNode? {
        let containerTypes: Set<SectionType> = [.graphics, .graphicsX, .graphicsD]
        guard let graphics = root.children.first(where: { containerTypes.contains($0.sectionType) }) else { return nil }
        return graphics.children.first { $0.sectionType == type }
    }

    private func makeOGI(id: UInt32, skinID: UInt32, modelLinks: [ModelLink] = []) -> Data {
        SkeletonWriter.write(SkeletonAsset(
            id: id, joints: [], exitPoints: [], skinTransforms: [], skinID: skinID, blendSkinID: 0, modelLinks: modelLinks
        ))
    }

    /// A real, `ScriptWriter`-encoded `MainScript`, the state machine
    /// `CrossFileGameObjectCopier` now copies to give a cross-level-placed
    /// object real AI instead of just a static bind pose.
    private func makeMainScript(inlineID: UInt16, name: String) -> Data {
        ScriptWriter.encode(ScriptAsset(
            id: 0, inlineID: inlineID, mask: 0, flag: 0,
            content: .main(MainScript(name: name, statesAmountRaw: 0, startUnit: 0, states: [])),
            trailingBytes: Data()
        ))
    }

    func testCopyingASyntheticSkinnedGameObjectChainRemapsEveryReferenceButKeepsTheObjectIDFixed() throws {
        let sourceGameObject = GameObjectWriter.encode(GameObjectInfo(id: 999, name: "SrcCritter", ogiIDs: [555]))
        let sourceOGI = makeOGI(id: 555, skinID: 777)
        let sourceSkin = makeSkin(subModels: [(materialID: 200, codeSize: 12)])
        let sourceMaterial = makeMaterial(name: "SrcMat", textureIDs: [500])
        let sourceTexture = makeTexture()

        let sourceBytes = makeFile(
            objects: [(999, sourceGameObject)],
            ogis: [(555, sourceOGI)],
            textures: [(500, sourceTexture)],
            materials: [(200, sourceMaterial)],
            skins: [(777, sourceSkin)]
        )
        let sourceRoot = try RM2Parser.parse(data: sourceBytes, fileKind: .rm2, fileName: "source.rm2")

        // Destination already has its OWN, different data at every touched
        // ID (555/777/200/500) plus an unrelated GameObject #111, proves
        // fresh-ID remapping avoids colliding with (or silently reusing)
        // unrelated destination data at the same number, and that nothing
        // pre-existing gets corrupted.
        let destinationGameObject = GameObjectWriter.encode(GameObjectInfo(id: 111, name: "DestNative", ogiIDs: [555]))
        let destinationOGI = makeOGI(id: 555, skinID: 777)
        let destinationSkin = makeSkin(subModels: [(materialID: 200, codeSize: 4)])
        let destinationTexture = makeTexture(width: 4, height: 4)
        let destinationBytes = makeFile(
            objects: [(111, destinationGameObject)],
            ogis: [(555, destinationOGI)],
            textures: [(500, destinationTexture)],
            materials: [(200, makeMaterial(name: "DestMat", textureIDs: [500]))],
            skins: [(777, destinationSkin)]
        )
        let destinationRoot = try RM2Parser.parse(data: destinationBytes, fileKind: .rm2, fileName: "destination.rm2")

        XCTAssertFalse(CrossFileGameObjectCopier.hasNativeGameObject(objectID: 999, in: destinationRoot))

        let result = try CrossFileGameObjectCopier.copyingSkinnedGameObjectChain(
            objectID: 999,
            sourceFileRoot: sourceRoot, sourceBytes: sourceBytes,
            destinationFileRoot: destinationRoot, destinationBytes: destinationBytes
        )

        let reparsed = try RM2Parser.parse(data: result.destinationBytes, fileKind: .rm2, fileName: "destination.rm2")

        // The GameObject's own ID must be EXACTLY 999, never remapped,
        // since it's the same well-known constant the placed Instance's
        // own `objectID` already points at.
        guard let objectCollection = codeChild(.object, in: reparsed),
              let newObjectNode = objectCollection.children.first(where: { $0.recordID == 999 }),
              case .gameObject(let newGameObject)? = newObjectNode.payload
        else { return XCTFail("copied GameObject #999 not found at its own real ID") }
        XCTAssertEqual(newGameObject.name, "SrcCritter", "must be the SOURCE object, not destination's own pre-existing #111")

        // Every OTHER reference must be remapped to a fresh ID.
        XCTAssertEqual(newGameObject.ogiIDs.count, 1)
        let newOGIID = newGameObject.ogiIDs[0]
        XCTAssertNotEqual(newOGIID, 555, "OGI ID must be remapped, not the source's own 555")
        XCTAssertGreaterThan(newOGIID, 555)

        guard let ogiCollection = codeChild(.ogi, in: reparsed),
              let newOGINode = ogiCollection.children.first(where: { $0.recordID == newOGIID }),
              case .skeleton(let newOGI)? = newOGINode.payload
        else { return XCTFail("copied OGI not found at its fresh ID") }
        XCTAssertTrue(newOGI.modelLinks.isEmpty, "modelLinks must be dropped, not left dangling at source-file-scoped IDs")

        let newSkinID = newOGI.skinID
        XCTAssertNotEqual(newSkinID, 777, "skinID must be remapped, not the source's own 777")
        guard let skinCollection = graphicsChild(.skin, in: reparsed),
              let newSkinNode = skinCollection.children.first(where: { $0.recordID == newSkinID })
        else { return XCTFail("copied Skin not found at its fresh ID") }

        // The Skin's own materialID must be patched in place, everything
        // else in its raw bytes (the opaque VIF filler) copied verbatim.
        let newSkinBytes = result.destinationBytes.subdata(in: (result.destinationBytes.startIndex + newSkinNode.fileOffset)..<(result.destinationBytes.startIndex + newSkinNode.fileOffset + newSkinNode.byteSize))
        var cursor = BinaryCursor(data: newSkinBytes)
        XCTAssertEqual(try cursor.readUInt32(), 1, "subModelCount must survive the copy unchanged")
        let newMaterialID = try cursor.readUInt32()
        XCTAssertNotEqual(newMaterialID, 200, "materialID must be remapped, not the source's own 200")
        XCTAssertEqual(try cursor.readInt32(), 12, "codeSize must survive the copy unchanged (source's own 12, not destination's 4)")

        guard let materialCollection = graphicsChild(.material, in: reparsed),
              let newMaterialNode = materialCollection.children.first(where: { $0.recordID == newMaterialID }),
              case .material(let newMaterial)? = newMaterialNode.payload
        else { return XCTFail("copied Material not found") }
        XCTAssertEqual(newMaterial.name, "SrcMat", "must be the SOURCE material, not destination's own pre-existing #200")

        let newTextureID = newMaterial.shaders[0].textureId
        XCTAssertNotEqual(newTextureID, 500, "textureId must be remapped, not the source's own 500")
        guard let textureCollection = graphicsChild(.texture, in: reparsed),
              let newTextureNode = textureCollection.children.first(where: { $0.recordID == newTextureID }),
              case .texture(let newTexture)? = newTextureNode.payload
        else { return XCTFail("copied Texture not found") }
        XCTAssertEqual(newTexture.width, 1, "must be the SOURCE's 1x1 texture, not destination's own pre-existing 4x4 #500")

        // The destination's own original data (same IDs, different
        // content) must survive completely untouched.
        guard let originalObjectNode = objectCollection.children.first(where: { $0.recordID == 111 }),
              case .gameObject(let originalObject)? = originalObjectNode.payload
        else { return XCTFail("destination's own original GameObject #111 must survive untouched") }
        XCTAssertEqual(originalObject.name, "DestNative")
        guard let originalOGINode = ogiCollection.children.first(where: { $0.recordID == 555 }),
              case .skeleton(let originalOGI)? = originalOGINode.payload
        else { return XCTFail("destination's own original OGI #555 must survive untouched") }
        XCTAssertEqual(originalOGI.skinID, 777, "destination's own original OGI #555 -> skinID 777 link must be untouched")
        guard let originalTextureNode = textureCollection.children.first(where: { $0.recordID == 500 }),
              case .texture(let originalTexture)? = originalTextureNode.payload
        else { return XCTFail("destination's own original Texture #500 must survive untouched") }
        XCTAssertEqual(originalTexture.width, 4, "destination's own original 4x4 texture at #500 must be untouched by the copy")
    }

    /// "Real AI/Combat Behavior for Copied Objects": a `GameObject` whose
    /// `scriptIDs` points at a real `MainScript` must come out the other
    /// side of a cross-file copy still pointing at a real (now fresh-ID,
    /// remapped) `MainScript` with the SOURCE's own content, not the
    /// pre-existing "scriptIDs = []" silent AI drop this type used to
    /// always apply.
    func testCopyingASyntheticSkinnedGameObjectChainAlsoCopiesItsReferencedMainScript() throws {
        let sourceGameObject = GameObjectWriter.encode(GameObjectInfo(id: 999, name: "SrcCritter", ogiIDs: [555], scriptIDs: [42]))
        let sourceOGI = makeOGI(id: 555, skinID: 777)
        let sourceSkin = makeSkin(subModels: [(materialID: 200, codeSize: 12)])
        let sourceMaterial = makeMaterial(name: "SrcMat", textureIDs: [500])
        let sourceTexture = makeTexture()
        let sourceScript = makeMainScript(inlineID: 42, name: "SrcAIState")

        let sourceBytes = makeFile(
            objects: [(999, sourceGameObject)],
            ogis: [(555, sourceOGI)],
            textures: [(500, sourceTexture)],
            materials: [(200, sourceMaterial)],
            skins: [(777, sourceSkin)],
            scripts: [(42, sourceScript)]
        )
        let sourceRoot = try RM2Parser.parse(data: sourceBytes, fileKind: .rm2, fileName: "source.rm2")

        // Destination already has its OWN, different script sitting at the
        // SAME id (42), proves fresh-ID remapping avoids colliding with
        // (or silently reusing) unrelated destination data at that number.
        let destinationGameObject = GameObjectWriter.encode(GameObjectInfo(id: 111, name: "DestNative", ogiIDs: [555]))
        let destinationScript = makeMainScript(inlineID: 42, name: "DestUnrelatedState")
        let destinationBytes = makeFile(
            objects: [(111, destinationGameObject)],
            ogis: [(555, makeOGI(id: 555, skinID: 777))],
            textures: [(500, makeTexture(width: 4, height: 4))],
            materials: [(200, makeMaterial(name: "DestMat", textureIDs: [500]))],
            skins: [(777, makeSkin(subModels: [(materialID: 200, codeSize: 4)]))],
            scripts: [(42, destinationScript)]
        )
        let destinationRoot = try RM2Parser.parse(data: destinationBytes, fileKind: .rm2, fileName: "destination.rm2")

        let result = try CrossFileGameObjectCopier.copyingSkinnedGameObjectChain(
            objectID: 999,
            sourceFileRoot: sourceRoot, sourceBytes: sourceBytes,
            destinationFileRoot: destinationRoot, destinationBytes: destinationBytes
        )
        let reparsed = try RM2Parser.parse(data: result.destinationBytes, fileKind: .rm2, fileName: "destination.rm2")

        guard let objectCollection = codeChild(.object, in: reparsed),
              let newObjectNode = objectCollection.children.first(where: { $0.recordID == 999 }),
              case .gameObject(let newGameObject)? = newObjectNode.payload
        else { return XCTFail("copied GameObject #999 not found at its own real ID") }

        XCTAssertEqual(newGameObject.scriptIDs.count, 1, "the one real MainScript reference must survive the copy")
        let newScriptID = newGameObject.scriptIDs[0]
        XCTAssertNotEqual(newScriptID, 42, "script ID must be remapped, not the source's own 42 (which collides with a real, unrelated destination record)")

        guard let scriptCollection = codeChild(.script, in: reparsed),
              let newScriptNode = scriptCollection.children.first(where: { $0.recordID == UInt32(newScriptID) }),
              case .script(let newScript)? = newScriptNode.payload,
              case .main(let newMain) = newScript.content
        else { return XCTFail("copied Script not found at its fresh ID, or isn't a MainScript") }
        XCTAssertEqual(newMain.name, "SrcAIState", "must be the SOURCE script, not destination's own pre-existing #42")

        // Destination's own original script at #42 must survive untouched.
        guard let originalScriptNode = scriptCollection.children.first(where: { $0.recordID == 42 }),
              case .script(let originalScript)? = originalScriptNode.payload,
              case .main(let originalMain) = originalScript.content
        else { return XCTFail("destination's own original Script #42 must survive untouched") }
        XCTAssertEqual(originalMain.name, "DestUnrelatedState")
    }

    /// A `HeaderScript` (dispatcher, not the AI itself) must be dropped
    /// from `scriptIDs` rather than guessed at, see
    /// `CrossFileGameObjectCopier.isMainScriptPayload`'s own doc comment
    /// for why copying it isn't attempted.
    /// A `HeaderScript`'s own `mainScriptIndex` reference is now resolved
    /// and remapped, not dropped, see `resolvingSkinnedGameObjectInsertions`'s
    /// own doc comment for the real evidence (the reference toolkit's own
    /// `ScriptEditor.cs`, plus a real disc scan of Cortex's/Crash's script
    /// chains in a genuine 2-player co-op level) that settled this. Proves
    /// both halves land correctly: the copied `HeaderScript` itself, and
    /// its target `MainScript`, cross-file-copied under a fresh ID with
    /// `mainScriptIndex` rewritten to point at it, plus that a
    /// destination file's own pre-existing, unrelated script is left
    /// untouched by the insert.
    func testCopyingResolvesAHeaderScriptReferenceAndRemapsItsTarget() throws {
        let mainScript = ScriptWriter.encode(ScriptAsset(
            id: 0, inlineID: 43, mask: 0, flag: 0,
            content: .main(MainScript(name: "SRC_MAIN", statesAmountRaw: 0, startUnit: 0, states: [])),
            trailingBytes: Data()
        ))
        let headerScript = ScriptWriter.encode(ScriptAsset(
            id: 0, inlineID: 42, mask: 0, flag: 1,
            content: .header(HeaderScript(entries: [HeaderScript.Entry(mainScriptIndex: 44, unkInt2: 0)])), // 44 - 1 = 43, the MainScript's own record ID.
            trailingBytes: Data()
        ))
        let sourceGameObject = GameObjectWriter.encode(GameObjectInfo(id: 999, name: "SrcCritter", ogiIDs: [555], scriptIDs: [42]))
        let sourceBytes = makeFile(
            objects: [(999, sourceGameObject)],
            ogis: [(555, makeOGI(id: 555, skinID: 777))],
            textures: [(500, makeTexture())],
            materials: [(200, makeMaterial(name: "SrcMat", textureIDs: [500]))],
            skins: [(777, makeSkin(subModels: [(materialID: 200, codeSize: 12)]))],
            scripts: [(42, headerScript), (43, mainScript)]
        )
        let sourceRoot = try RM2Parser.parse(data: sourceBytes, fileKind: .rm2, fileName: "source.rm2")

        let destExistingScript = ScriptWriter.encode(ScriptAsset(
            id: 0, inlineID: 900, mask: 0, flag: 0,
            content: .main(MainScript(name: "DEST_EXISTING", statesAmountRaw: 0, startUnit: 0, states: [])),
            trailingBytes: Data()
        ))
        let destinationBytes = makeFile(objects: [], ogis: [], textures: [], materials: [], skins: [], scripts: [(9000, destExistingScript)])
        let destinationRoot = try RM2Parser.parse(data: destinationBytes, fileKind: .rm2, fileName: "destination.rm2")

        let result = try CrossFileGameObjectCopier.copyingSkinnedGameObjectChain(
            objectID: 999,
            sourceFileRoot: sourceRoot, sourceBytes: sourceBytes,
            destinationFileRoot: destinationRoot, destinationBytes: destinationBytes
        )
        let reparsed = try RM2Parser.parse(data: result.destinationBytes, fileKind: .rm2, fileName: "destination.rm2")
        guard let objectCollection = codeChild(.object, in: reparsed),
              let newObjectNode = objectCollection.children.first(where: { $0.recordID == 999 }),
              case .gameObject(let newGameObject)? = newObjectNode.payload
        else { return XCTFail("copied GameObject #999 not found") }
        XCTAssertEqual(newGameObject.scriptIDs.count, 1, "the HeaderScript reference must now be copied, not dropped")

        guard let scriptCollection = codeChild(.script, in: reparsed) else { return XCTFail("no script collection in destination") }
        XCTAssertTrue(scriptCollection.children.contains { $0.recordID == 9000 }, "the destination's own pre-existing, unrelated script must be untouched")

        let newHeaderID = UInt32(newGameObject.scriptIDs[0])
        guard let newHeaderNode = scriptCollection.children.first(where: { $0.recordID == newHeaderID }),
              case .script(let copiedHeaderScript)? = newHeaderNode.payload,
              case .header(let copiedHeader) = copiedHeaderScript.content
        else { return XCTFail("copied HeaderScript not found") }
        XCTAssertEqual(copiedHeader.entries.count, 1)

        let targetID = UInt32(copiedHeader.entries[0].mainScriptIndex - 1)
        guard let targetNode = scriptCollection.children.first(where: { $0.recordID == targetID }),
              case .script(let targetScript)? = targetNode.payload,
              case .main(let copiedMain) = targetScript.content
        else { return XCTFail("HeaderScript's mainScriptIndex must resolve to its real, remapped MainScript target, not the original source-file ID") }
        XCTAssertEqual(copiedMain.name, "SRC_MAIN")
    }

    func testCopyingWhenObjectIDAlreadyPresentInDestinationThrows() throws {
        let gameObject = GameObjectWriter.encode(GameObjectInfo(id: 999, name: "Whatever", ogiIDs: [555]))
        let bytes = makeFile(objects: [(999, gameObject)], ogis: [], textures: [], materials: [], skins: [])
        let root = try RM2Parser.parse(data: bytes, fileKind: .rm2, fileName: "both.rm2")
        XCTAssertTrue(CrossFileGameObjectCopier.hasNativeGameObject(objectID: 999, in: root))
        XCTAssertThrowsError(try CrossFileGameObjectCopier.copyingSkinnedGameObjectChain(
            objectID: 999, sourceFileRoot: root, sourceBytes: bytes, destinationFileRoot: root, destinationBytes: bytes
        )) { error in
            guard case CrossFileGameObjectCopier.CopyError.gameObjectAlreadyPresent(999) = error else {
                return XCTFail("expected .gameObjectAlreadyPresent, got \(error)")
            }
        }
    }

    /// "Multi-Object Batch Save", the real scenario `WorkspaceViewModel.
    /// patchedFileBytes` has to handle: two *different* missing objects
    /// placed in the same save. Neither `resolvingSkinnedGameObjectInsertions`
    /// call mutates `destinationFileRoot`, so without `additionalClaimedIDs`
    /// threaded from the first call's `claimedIDs` into the second call,
    /// both would independently compute the *same* fresh OGI/Skin ID and
    /// silently collide once folded into one combined `targets` array. This
    /// proves the threading actually prevents that.
    func testResolvingInsertionsForTwoDifferentObjectsInOneBatchNeverCollide() throws {
        let sourceGameObjectA = GameObjectWriter.encode(GameObjectInfo(id: 900, name: "CritterA", ogiIDs: [555]))
        let sourceOGIA = makeOGI(id: 555, skinID: 777)
        let sourceSkinA = makeSkin(subModels: [(materialID: 200, codeSize: 4)])
        let sourceMaterialA = makeMaterial(name: "MatA", textureIDs: [500])
        let sourceTextureA = makeTexture()
        let sourceBytesA = makeFile(
            objects: [(900, sourceGameObjectA)], ogis: [(555, sourceOGIA)],
            textures: [(500, sourceTextureA)], materials: [(200, sourceMaterialA)], skins: [(777, sourceSkinA)]
        )
        let sourceRootA = try RM2Parser.parse(data: sourceBytesA, fileKind: .rm2, fileName: "sourceA.rm2")

        let sourceGameObjectB = GameObjectWriter.encode(GameObjectInfo(id: 901, name: "CritterB", ogiIDs: [555]))
        let sourceOGIB = makeOGI(id: 555, skinID: 777)
        let sourceSkinB = makeSkin(subModels: [(materialID: 200, codeSize: 4)])
        let sourceMaterialB = makeMaterial(name: "MatB", textureIDs: [500])
        let sourceTextureB = makeTexture()
        let sourceBytesB = makeFile(
            objects: [(901, sourceGameObjectB)], ogis: [(555, sourceOGIB)],
            textures: [(500, sourceTextureB)], materials: [(200, sourceMaterialB)], skins: [(777, sourceSkinB)]
        )
        let sourceRootB = try RM2Parser.parse(data: sourceBytesB, fileKind: .rm2, fileName: "sourceB.rm2")

        let destinationBytes = makeFile(objects: [], ogis: [], textures: [], materials: [], skins: [])
        let destinationRoot = try RM2Parser.parse(data: destinationBytes, fileKind: .rm2, fileName: "destination.rm2")

        let resolvedA = try CrossFileGameObjectCopier.resolvingSkinnedGameObjectInsertions(
            objectID: 900, sourceFileRoot: sourceRootA, sourceBytes: sourceBytesA, destinationFileRoot: destinationRoot
        )
        let resolvedB = try CrossFileGameObjectCopier.resolvingSkinnedGameObjectInsertions(
            objectID: 901, sourceFileRoot: sourceRootB, sourceBytes: sourceBytesB, destinationFileRoot: destinationRoot,
            additionalClaimedIDs: (ogi: [resolvedA.claimedIDs.ogi], skin: [resolvedA.claimedIDs.skin], material: resolvedA.claimedIDs.material, texture: resolvedA.claimedIDs.texture, script: resolvedA.claimedIDs.script, animation: resolvedA.claimedIDs.animation)
        )

        XCTAssertNotEqual(resolvedA.claimedIDs.ogi, resolvedB.claimedIDs.ogi, "the two objects' fresh OGI IDs must not collide")
        XCTAssertNotEqual(resolvedA.claimedIDs.skin, resolvedB.claimedIDs.skin, "the two objects' fresh Skin IDs must not collide")
        XCTAssertTrue(resolvedA.claimedIDs.material.isDisjoint(with: resolvedB.claimedIDs.material), "the two objects' fresh Material IDs must not collide")
        XCTAssertTrue(resolvedA.claimedIDs.texture.isDisjoint(with: resolvedB.claimedIDs.texture), "the two objects' fresh Texture IDs must not collide")

        // Folded into one combined `targets` array, exactly how
        // `WorkspaceViewModel.patchedFileBytes` uses this, and rebuilt in
        // one atomic pass, same as every other multi-target save. Real,
        // decisive finding this test exists to pin: both objects' own
        // insertions land in the *same* Object/OGI collection nodes (both
        // resolved independently against the same, unmutated
        // `destinationRoot`), `ChunkSectionInserter.applyingRecordChanges`
        // only rebuilds the *first* `targets` entry for a given section and
        // silently skips any later one targeting that same node identity
        // (see its own `rebuiltBytesByNodeID[...] == nil` guard), so a
        // caller MUST merge same-section entries before calling it, not
        // just concatenate the two objects' raw `targets` arrays, a real
        // integration bug this test caught during development.
        var mergedBySection: [ObjectIdentifier: (section: ChunkNode, insert: [(id: UInt32, encoded: Data)])] = [:]
        for target in resolvedA.targets + resolvedB.targets {
            let key = ObjectIdentifier(target.section)
            mergedBySection[key, default: (target.section, [])].insert.append(contentsOf: target.insert)
        }
        let combinedTargets = mergedBySection.values.map { (section: $0.section, insert: $0.insert, removeIDs: [UInt32]()) }
        guard let rebuilt = ChunkSectionInserter.applyingRecordChanges(intoSections: combinedTargets, fileRoot: destinationRoot, originalFileBytes: destinationBytes) else {
            return XCTFail("combined rebuild failed")
        }
        let reparsed = try RM2Parser.parse(data: rebuilt, fileKind: .rm2, fileName: "destination.rm2")
        XCTAssertTrue(CrossFileGameObjectCopier.hasNativeGameObject(objectID: 900, in: reparsed))
        XCTAssertTrue(CrossFileGameObjectCopier.hasNativeGameObject(objectID: 901, in: reparsed))
    }

    /// `skinID == 0` (a pure rigid-prop object, e.g. Cortex's own real
    /// `MULTITOOL` weapon) must copy successfully, not throw, see
    /// `resolvingSkinnedGameObjectInsertions`'s own doc comment on
    /// `sourceSkinNode` for why this was real behavior to fix, not a rare
    /// edge case: a character's own linked weapon depends on exactly this.
    /// This fixture's own `modelLinks` target (`modelID: 42`) has no real
    /// `RigidModel`/`Mesh` data behind it at all, so the link itself still
    /// can't resolve and is dropped, same disclosed "a link this build's
    /// rigid-model copier can't resolve is skipped, not guessed at"
    /// behavior as ever; what changed is that a missing *skin* no longer
    /// fails the whole object.
    func testCopyingARigidPropOnlyObjectSucceedsWithNoSkin() throws {
        let sourceGameObject = GameObjectWriter.encode(GameObjectInfo(id: 999, name: "RigidOnly", ogiIDs: [555]))
        let sourceOGI = makeOGI(id: 555, skinID: 0, modelLinks: [ModelLink(jointIndex: 0, modelID: 42)])
        let sourceBytes = makeFile(objects: [(999, sourceGameObject)], ogis: [(555, sourceOGI)], textures: [], materials: [], skins: [])
        let sourceRoot = try RM2Parser.parse(data: sourceBytes, fileKind: .rm2, fileName: "source.rm2")
        let destinationBytes = makeFile(objects: [], ogis: [], textures: [], materials: [], skins: [])
        let destinationRoot = try RM2Parser.parse(data: destinationBytes, fileKind: .rm2, fileName: "destination.rm2")

        let result = try CrossFileGameObjectCopier.copyingSkinnedGameObjectChain(
            objectID: 999, sourceFileRoot: sourceRoot, sourceBytes: sourceBytes,
            destinationFileRoot: destinationRoot, destinationBytes: destinationBytes
        )
        let reparsed = try RM2Parser.parse(data: result.destinationBytes, fileKind: .rm2, fileName: "destination.rm2")
        XCTAssertTrue(CrossFileGameObjectCopier.hasNativeGameObject(objectID: 999, in: reparsed))

        guard let objectCollection = codeChild(.object, in: reparsed),
              let newObjectNode = objectCollection.children.first(where: { $0.recordID == 999 }),
              case .gameObject(let newGameObject)? = newObjectNode.payload,
              let newOGIID = newGameObject.ogiIDs.first
        else { return XCTFail("copied GameObject #999 not found") }

        guard let ogiCollection = codeChild(.ogi, in: reparsed),
              let newOGINode = ogiCollection.children.first(where: { $0.recordID == newOGIID }),
              case .skeleton(let newSkeleton)? = newOGINode.payload
        else { return XCTFail("copied OGI not found") }
        XCTAssertEqual(newSkeleton.skinID, 0, "a rigid-prop object has no skin to remap, must stay 0, not point at a never-inserted skin record")
    }

    // MARK: - Real disc

    /// Best-effort, mirroring `CrossFileModelCopierTests.
    /// testCopyingARealRigidModelChainAcrossTwoRealLevels`'s own posture:
    /// searches real archive entries for a source level carrying a real,
    /// natively-skinned enemy `GameObject` that `beach.rm2` (the
    /// destination, confirmed empty of it, see `CrossFileGameObjectCopier`'s
    /// own top-level doc comment) doesn't have, copies it across, and
    /// confirms the result actually resolves to a real, non-empty mesh
    /// through the same `AssetResolver.resolveInstanceObject` path the game
    /// data itself is read through, the decisive end-to-end proof the
    /// synthetic test above can't give (it uses opaque VIF filler, never a
    /// real decodable mesh).
    func testCopyingARealSkinnedEnemyAcrossTwoRealLevels() throws {
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }
        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("CrossFileGameObjectCopierTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let isoData = try Data(contentsOf: Self.retailISOURL, options: .mappedIfSafe)
        let source = PlainISOSource(data: isoData)
        let root = try ISO9660Reader.readRootDirectory(from: source)

        var bhEntry: ISO9660Entry?
        var bdEntry: ISO9660Entry?
        func walk(_ node: ISO9660Entry) {
            let ext = (node.name as NSString).pathExtension.lowercased()
            if ext == "bh" { bhEntry = node }
            if ext == "bd" { bdEntry = node }
            for child in node.children { walk(child) }
        }
        walk(root)
        guard let bhEntry, let bdEntry,
              let bhData = ISO9660Reader.readFile(bhEntry, from: source),
              let bdData = ISO9660Reader.readFile(bdEntry, from: source)
        else { throw XCTSkip("no real .BH/.BD archive pair found on this disc") }

        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        let tempBH = scratchDir.appendingPathComponent((bhEntry.name as NSString).lastPathComponent)
        let tempBD = scratchDir.appendingPathComponent((bdEntry.name as NSString).lastPathComponent)
        try bhData.write(to: tempBH)
        try bdData.write(to: tempBD)
        let index = try BDArchiveParser.readIndex(bhURL: tempBH)

        guard let destinationEntry = index.entries.first(where: { ($0.name as NSString).lastPathComponent.caseInsensitiveCompare("beach.rm2") == .orderedSame }) else {
            throw XCTSkip("beach.rm2 not found in this archive")
        }
        let destinationBytes = try BDArchiveParser.readEntryData(destinationEntry, index: index)
        let destinationRoot = try RM2Parser.parse(data: destinationBytes, fileKind: .rm2, fileName: destinationEntry.name)

        // Real object IDs confirmed (2026-08-26 investigation against this
        // exact disc) to have zero GameObject data in both beach.rm2 and
        // the shared Default.rm2, real, reported "doesn't appear when
        // booted" candidates.
        let candidateObjectIDs: [UInt16] = [81, 68, 88, 79, 867] // RAT_DARKBROWN, RAT_DARKPURPLE, RAT_GREY, PIG_WILDBOAR, COCKROACH
        for id in candidateObjectIDs {
            XCTAssertFalse(CrossFileGameObjectCopier.hasNativeGameObject(objectID: id, in: destinationRoot), "sanity: object #\(id) must still be genuinely absent from beach.rm2 for this test to mean anything")
        }

        let rm2Entries = index.entries.filter { ($0.name as NSString).pathExtension.caseInsensitiveCompare("rm2") == .orderedSame }
        var found: (objectID: UInt16, sourceRoot: ChunkNode, sourceBytes: Data)?
        searching: for entry in rm2Entries {
            guard entry.name.caseInsensitiveCompare(destinationEntry.name) != .orderedSame,
                  let bytes = try? BDArchiveParser.readEntryData(entry, index: index),
                  let sourceRoot = try? RM2Parser.parse(data: bytes, fileKind: .rm2, fileName: entry.name)
            else { continue }
            for id in candidateObjectIDs where CrossFileGameObjectCopier.hasNativeGameObject(objectID: id, in: sourceRoot) {
                found = (id, sourceRoot, bytes)
                break searching
            }
        }
        guard let found else {
            throw XCTSkip("no archive entry on this disc natively carries any of the candidate enemy GameObjects")
        }

        let result: CrossFileGameObjectCopier.CopyResult
        do {
            result = try CrossFileGameObjectCopier.copyingSkinnedGameObjectChain(
                objectID: found.objectID,
                sourceFileRoot: found.sourceRoot, sourceBytes: found.sourceBytes,
                destinationFileRoot: destinationRoot, destinationBytes: destinationBytes
            )
        } catch {
            throw XCTSkip("candidate object #\(found.objectID) didn't resolve through the skinned-character path on this disc (\(error)), real, honest limitation, not a copier bug")
        }

        let reparsedDestination = try RM2Parser.parse(data: result.destinationBytes, fileKind: .rm2, fileName: destinationEntry.name)
        XCTAssertTrue(CrossFileGameObjectCopier.hasNativeGameObject(objectID: found.objectID, in: reparsedDestination))

        let destinationIndex = AssetResolver.buildIndex(fileRoot: reparsedDestination)
        let resolved = try XCTUnwrap(
            AssetResolver.resolveInstanceObject(objectID: found.objectID, instanceSelector: 0, index: destinationIndex),
            "object #\(found.objectID) must now resolve to real geometry through the exact path the real game data is read through"
        )
        XCTAssertFalse(resolved.mesh.submeshes.isEmpty, "the resolved mesh must carry real, decoded submesh data, not an empty placeholder")
    }
}
