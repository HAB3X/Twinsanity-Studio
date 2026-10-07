import Foundation
import CTCore
import CTModels

/// Copies a `RigidModel` (mesh + its materials + their textures) from one
/// file's `Graphics` section into another's, the missing piece for
/// "place a scenery object sourced from a different level," since a
/// `SceneryModelPlacement.modelID` is a file-local number (level A's
/// model #12 means nothing in level B's own `GraphicsAssetIndex`).
///
/// Every copied record's real, raw on-disk bytes are used verbatim (never
/// re-encoded through a from-scratch writer this codebase doesn't have for
/// `RigidModel`/`Material`/`Texture`/`Model`), always assigned a **fresh**
/// ID in the destination (never reusing the source's own number, even if
/// that number happens to be free in the destination too), with the small
/// number of *internal* cross-references those formats carry
/// (`RigidModel.materialIDs`/`meshID`, `TwinsShader.textureId` inside each
/// copied `Material`) patched in place to point at the fresh copies , 
/// verified against the reference's own `RigidModel.FillPackage`/
/// `Material.FillPackage` (`Twinsanity/Items/Graphics/RigidModel.cs`/
/// `Material.cs`), which walk the exact same dependency closure for
/// CrateModLoader's mod-packaging, though that code reuses the *same* ID
/// across files rather than remapping, always assigning fresh IDs here
/// instead avoids that approach's real collision risk (two different
/// levels' assets sharing a small sequential ID number is common, not
/// rare) at the cost of never de-duplicating a re-placed object across
/// multiple placements.
///
/// One deliberate simplification: if the source placement was `isSpecial`
/// (reached its `RigidModel` through a `LodModel` indirection , 
/// `SceneryModelPlacement.isSpecial`'s own doc comment), this resolves
/// straight to the concrete `RigidModel` those LOD levels bottom out at
/// and creates the new placement as **non-special**, pointing at it
/// directly, a real, working object, just always at full detail rather
/// than LOD-switching. Copying a `LodModel` wrapper too is real, separate
/// work this doesn't attempt.
public enum CrossFileModelCopier {
    public struct CopyResult: Sendable {
        public var destinationBytes: Data
        /// The fresh `RigidModel` ID in the *destination* file, use this
        /// (with `isSpecial: false`) for the new `SceneryModelPlacement`.
        public var rigidModelID: UInt32
    }

    public enum CopyError: Error, LocalizedError {
        case missingGraphicsCollection(SectionType, file: String)
        case recordNotFound(SectionType, UInt32)
        case lodModelDidNotResolve(UInt32)
        case insertionFailed

        public var errorDescription: String? {
            switch self {
            case .missingGraphicsCollection(let type, let file):
                return "The \(file) file has no \(type) collection this build recognizes."
            case .recordNotFound(let type, let id):
                return "Couldn't find \(type) #\(id), the source file may be missing real data this placement depends on."
            case .lodModelDidNotResolve(let id):
                return "LodModel #\(id)'s alternate RigidModel IDs didn't resolve to any real RigidModel in the source file."
            case .insertionFailed:
                return "Internal error: couldn't safely insert the copied records into the destination file's structure."
            }
        }
    }

    /// Copies everything needed to render `modelID` (a real
    /// `SceneryModelPlacement.modelID`/`isSpecial` pair from `sourceFileRoot`)
    /// into `destinationFileRoot`'s own `Graphics` collections. Neither
    /// input file's bytes are modified in place, `destinationBytes` is
    /// the destination file's *current* bytes (already-open working copy,
    /// same convention as every other insertion in this app), and the
    /// result is a brand-new complete replacement for it.
    public static func copyingRigidModelChain(
        modelID: UInt32,
        isSpecial: Bool,
        sourceFileRoot: ChunkNode,
        sourceBytes: Data,
        destinationFileRoot: ChunkNode,
        destinationBytes: Data
    ) throws -> CopyResult {
        let resolved = try resolvingRigidModelInsertions(
            modelID: modelID, isSpecial: isSpecial, sourceFileRoot: sourceFileRoot, sourceBytes: sourceBytes, destinationFileRoot: destinationFileRoot
        )
        guard let result = ChunkSectionInserter.applyingRecordChanges(intoSections: resolved.targets.map { (section: $0.section, insert: $0.insert, removeIDs: []) }, fileRoot: destinationFileRoot, originalFileBytes: destinationBytes) else {
            throw CopyError.insertionFailed
        }
        return CopyResult(destinationBytes: result, rigidModelID: resolved.rigidModelID)
    }

    /// Same contract as `copyingRigidModelChain`, but returns ready-to-
    /// insert `(section, insert)` targets instead of applying them , 
    /// mirrors `CrossFileGameObjectCopier.resolvingSkinnedGameObjectInsertions`'s
    /// own split from its `copyingSkinnedGameObjectChain` wrapper, for the
    /// identical reason: a caller folding several different copies (e.g. a
    /// skinned character's own skeleton *and* one of its `ModelLink`
    /// rigid attachments) into one save needs every insertion in the same
    /// atomic `ChunkSectionInserter` rebuild, not sequential separate ones
    /// (see that function's own doc comment on why sequential rebuilds
    /// against a shared ancestor desync). `additionalClaimedIDs` exists
    /// for the identical multi-object-batch reason that function's own
    /// parameter does.
    public static func resolvingRigidModelInsertions(
        modelID: UInt32,
        isSpecial: Bool,
        sourceFileRoot: ChunkNode,
        sourceBytes: Data,
        destinationFileRoot: ChunkNode,
        additionalClaimedIDs: (material: Set<UInt32>, texture: Set<UInt32>, mesh: Set<UInt32>, rigidModel: Set<UInt32>) = ([], [], [], [])
    ) throws -> (targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)])], rigidModelID: UInt32, claimedIDs: (material: Set<UInt32>, texture: Set<UInt32>, mesh: UInt32, rigidModel: UInt32)) {
        let sourceRigidModelLeaves = graphicsLeaves(in: sourceFileRoot, matching: isRigidModelPayload)
        guard !sourceRigidModelLeaves.isEmpty else { throw CopyError.missingGraphicsCollection(.rigidModel, file: "source") }
        let sourceMaterialLeaves = graphicsLeaves(in: sourceFileRoot, matching: isMaterialPayload)
        guard !sourceMaterialLeaves.isEmpty else { throw CopyError.missingGraphicsCollection(.material, file: "source") }
        let sourceTextureLeaves = graphicsLeaves(in: sourceFileRoot, matching: isTexturePayload)
        guard !sourceTextureLeaves.isEmpty else { throw CopyError.missingGraphicsCollection(.texture, file: "source") }
        let sourceMeshLeaves = graphicsLeaves(in: sourceFileRoot, matching: isNonSkinnedMeshPayload)
        guard !sourceMeshLeaves.isEmpty else { throw CopyError.missingGraphicsCollection(.model, file: "source") }

        let destRigidModelLeaves = graphicsLeaves(in: destinationFileRoot, matching: isRigidModelPayload)
        let destMaterialLeaves = graphicsLeaves(in: destinationFileRoot, matching: isMaterialPayload)
        let destTextureLeaves = graphicsLeaves(in: destinationFileRoot, matching: isTexturePayload)
        let destMeshLeaves = graphicsLeaves(in: destinationFileRoot, matching: isNonSkinnedMeshPayload)

        guard let destRigidModels = mostPopulousCollection(of: destRigidModelLeaves) ?? graphicsCollection(.rigidModel, in: destinationFileRoot) else {
            throw CopyError.missingGraphicsCollection(.rigidModel, file: "destination")
        }
        guard let destMaterials = mostPopulousCollection(of: destMaterialLeaves) ?? graphicsCollection(.material, in: destinationFileRoot) else {
            throw CopyError.missingGraphicsCollection(.material, file: "destination")
        }
        guard let destTextures = mostPopulousCollection(of: destTextureLeaves) ?? graphicsCollection(.texture, in: destinationFileRoot) else {
            throw CopyError.missingGraphicsCollection(.texture, file: "destination")
        }
        guard let destModels = mostPopulousCollection(of: destMeshLeaves) ?? graphicsCollection(.model, in: destinationFileRoot) else {
            throw CopyError.missingGraphicsCollection(.model, file: "destination")
        }

        // Resolve `modelID` down to a real, concrete RigidModel ID , 
        // `AssetResolver.resolveModelID`'s own logic (isSpecial -> LodModel
        // indirection), reimplemented locally since that function is
        // decode-oriented (returns a `ResolvedModelAsset`) where this needs
        // the real record *ID* to locate its raw bytes. Must recurse the
        // same way `resolveModelID` does: a LodModel's own `lodModelIDs`
        // aren't guaranteed to be RigidModel IDs directly, one entry can
        // itself be another LodModel one level further down the chain.
        // Depth-capped at 4, matching `resolveModelID`'s own bound, since
        // the format has no structural guarantee against a malformed cycle.
        //
        // Real disc evidence this needed a payload-based lookup, not a
        // sectionType-tagged one (see `Levels/Earth/Totem/l03beach.sm2`,
        // modelID 46204230, isSpecial): the tier-2 collection whose own
        // `sectionType` is literally `.rigidModel` has *zero* children in
        // that file, while `AssetResolver.buildIndex` (which aggregates
        // every leaf under every tier-2 collection by the leaf's own
        // decoded *payload* type, not by which collection it's nested
        // under) finds 85 real `.rigidModel`-payloaded leaves elsewhere in
        // the same `.graphics` container. `graphicsLeaves` below replicates
        // that exact traversal for node-based lookups (needed to reach a
        // record's raw bytes to copy, not just its decoded value), fixing
        // the gap `testPlacingSceneryFromAnotherArchiveBrowsedLevelRoundTrips`
        // (`RealDiscDiagnosticTests.swift`) used to pin as a known failure.
        var realRigidModelID = modelID
        if isSpecial {
            let sourceLodModelLeaves = graphicsLeaves(in: sourceFileRoot, matching: isLodModelPayload)
            guard let resolved = Self.resolvingRigidModelID(forLodModelID: modelID, rigidModelLeaves: sourceRigidModelLeaves, lodModelLeaves: sourceLodModelLeaves) else {
                throw CopyError.lodModelDidNotResolve(modelID)
            }
            realRigidModelID = resolved
        }

        guard let rigidModelNode = sourceRigidModelLeaves.first(where: { $0.leaf.recordID == realRigidModelID })?.leaf,
              case .rigidModel(let rigidModelInfo)? = rigidModelNode.payload
        else { throw CopyError.recordNotFound(.rigidModel, realRigidModelID) }

        var nextTextureID = max(destTextureLeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.texture.max() ?? 0) + 1
        var nextMaterialID = max(destMaterialLeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.material.max() ?? 0) + 1
        let newRigidModelID = max(destRigidModelLeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.rigidModel.max() ?? 0) + 1
        let newMeshID = max(destMeshLeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.mesh.max() ?? 0) + 1

        guard let meshSourceNode = sourceMeshLeaves.first(where: { $0.leaf.recordID == rigidModelInfo.meshID })?.leaf else {
            throw CopyError.recordNotFound(.model, rigidModelInfo.meshID)
        }
        let modelInserts: [(id: UInt32, encoded: Data)] = [(newMeshID, rawBytes(of: meshSourceNode, in: sourceBytes))]

        var textureInserts: [(id: UInt32, encoded: Data)] = []
        var materialInserts: [(id: UInt32, encoded: Data)] = []
        var materialIDRemap: [UInt32: UInt32] = [:]
        var textureIDRemap: [UInt32: UInt32] = [:]

        for materialID in rigidModelInfo.materialIDs where materialIDRemap[materialID] == nil {
            guard let materialNode = sourceMaterialLeaves.first(where: { $0.leaf.recordID == materialID })?.leaf else {
                throw CopyError.recordNotFound(.material, materialID)
            }
            var materialBytes = rawBytes(of: materialNode, in: sourceBytes)
            let shaderOffsets = try shaderTextureIDOffsets(in: materialBytes)
            for shader in shaderOffsets {
                let newTextureID: UInt32
                if let already = textureIDRemap[shader.textureID] {
                    newTextureID = already
                } else {
                    guard let textureNode = sourceTextureLeaves.first(where: { $0.leaf.recordID == shader.textureID })?.leaf else {
                        throw CopyError.recordNotFound(.texture, shader.textureID)
                    }
                    newTextureID = nextTextureID
                    nextTextureID += 1
                    textureInserts.append((newTextureID, rawBytes(of: textureNode, in: sourceBytes)))
                    textureIDRemap[shader.textureID] = newTextureID
                }
                writeUInt32LE(newTextureID, at: shader.offset, in: &materialBytes)
            }
            let newMaterialID = nextMaterialID
            nextMaterialID += 1
            materialInserts.append((newMaterialID, materialBytes))
            materialIDRemap[materialID] = newMaterialID
        }

        var rigidModelBytes = rawBytes(of: rigidModelNode, in: sourceBytes)
        // `RigidModel`'s own fixed layout (`RigidModel.cs`'s `Save`):
        // header(4) + count(4) + materialIDs[count*4] + meshID(4), every
        // offset is derivable from the count field itself, no separately-
        // tracked offsets needed (unlike `Material`'s variable-length
        // shader blocks above).
        for (index, materialID) in rigidModelInfo.materialIDs.enumerated() {
            guard let remapped = materialIDRemap[materialID] else { continue }
            writeUInt32LE(remapped, at: 8 + index * 4, in: &rigidModelBytes)
        }
        writeUInt32LE(newMeshID, at: 8 + rigidModelInfo.materialIDs.count * 4, in: &rigidModelBytes)

        var targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)])] = []
        if !textureInserts.isEmpty { targets.append((destTextures, textureInserts)) }
        if !materialInserts.isEmpty { targets.append((destMaterials, materialInserts)) }
        targets.append((destModels, modelInserts))
        targets.append((destRigidModels, [(newRigidModelID, rigidModelBytes)]))

        return (targets, newRigidModelID, (Set(materialInserts.map(\.id)), Set(textureInserts.map(\.id)), newMeshID, newRigidModelID))
    }

    // MARK: - Helpers

    /// Not `private`: `CrossFileGameObjectCopier` reuses this exact raw-byte
    /// extraction for its own record types (Skin/GraphicsInfo/GameObject),
    /// same "never re-encode from scratch, copy real on-disk bytes verbatim"
    /// discipline this file's own top-level doc comment establishes.
    static func rawBytes(of node: ChunkNode, in bytes: Data) -> Data {
        bytes.subdata(in: (bytes.startIndex + node.fileOffset)..<(bytes.startIndex + node.fileOffset + node.byteSize))
    }

    /// Recursive LOD-chain walk, mirroring `AssetResolver.resolveModelID`'s
    /// own algorithm exactly (isSpecial -> LodModel indirection, first
    /// `lodModelIDs` candidate that resolves, recursing when a candidate is
    /// itself another LodModel rather than a RigidModel) but returning the
    /// real record *ID* instead of a decoded `ResolvedModelAsset`, since
    /// this caller needs it to locate the RigidModel's raw bytes to copy.
    private static func resolvingRigidModelID(forLodModelID lodModelID: UInt32, rigidModelLeaves: [(collection: ChunkNode, leaf: ChunkNode)], lodModelLeaves: [(collection: ChunkNode, leaf: ChunkNode)], depth: Int = 0) -> UInt32? {
        guard depth < 4,
              let lodNode = lodModelLeaves.first(where: { $0.leaf.recordID == lodModelID })?.leaf,
              case .lodModel(let lodInfo)? = lodNode.payload
        else { return nil }
        for candidateID in lodInfo.lodModelIDs {
            if rigidModelLeaves.contains(where: { $0.leaf.recordID == candidateID }) {
                return candidateID
            }
            if let resolved = resolvingRigidModelID(forLodModelID: candidateID, rigidModelLeaves: rigidModelLeaves, lodModelLeaves: lodModelLeaves, depth: depth + 1) {
                return resolved
            }
        }
        return nil
    }

    /// The `.graphics`/`.graphicsX`/`.graphicsD` container's child whose
    /// own `sectionType` is `type`, the collection node
    /// `ChunkSectionInserter` targets to add a new record. Kept only as a
    /// fallback for a file that (unlike every real one seen so far) has
    /// literally zero existing leaves of a given payload type anywhere , 
    /// `graphicsLeaves`/`mostPopulousCollection` below are the primary
    /// lookup path.
    /// Not `private`: `CrossFileGameObjectCopier` reuses this fallback
    /// lookup too, same reasoning as `rawBytes` above.
    static func graphicsCollection(_ type: SectionType, in fileRoot: ChunkNode) -> ChunkNode? {
        let containerTypes: Set<SectionType> = [.graphics, .graphicsX, .graphicsD]
        func walk(_ node: ChunkNode) -> ChunkNode? {
            if containerTypes.contains(node.sectionType) {
                return node.children.first { $0.sectionType == type }
            }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// Every leaf anywhere under the `.graphics`/`.graphicsX`/`.graphicsD`
    /// container whose own *decoded payload* satisfies `predicate`,
    /// together with the tier-2 collection node it's actually nested
    /// under, the same traversal `AssetResolver.buildIndex` already uses
    /// (aggregate by each leaf's own payload type, not by the collection's
    /// `sectionType` tag), which real data proved doesn't always agree
    /// with a naive "the one child whose own sectionType matches" lookup:
    /// a file can tag a tier-2 collection `.rigidModel` while leaving it
    /// empty, with the real `.rigidModel`-payloaded leaves living inside
    /// some other, differently-tagged (or untyped) collection instead.
    /// Not `private`: `CrossFileGameObjectCopier` reuses this exact
    /// traversal for its own Graphics-side lookups (Skin/Material/Texture)
    ///, same reasoning as `rawBytes` above. That copier also needs the
    /// `Code`-side equivalent (GameObject/GraphicsInfo/Animation), which it
    /// implements itself since those live under a structurally different
    /// top-level container.
    static func graphicsLeaves(in fileRoot: ChunkNode, matching predicate: (ChunkPayload) -> Bool) -> [(collection: ChunkNode, leaf: ChunkNode)] {
        let containerTypes: Set<SectionType> = [.graphics, .graphicsX, .graphicsD]
        guard let graphics = fileRoot.children.first(where: { containerTypes.contains($0.sectionType) }) else { return [] }
        var results: [(collection: ChunkNode, leaf: ChunkNode)] = []
        for collection in graphics.children {
            for leaf in collection.children {
                guard let payload = leaf.payload, predicate(payload) else { continue }
                results.append((collection, leaf))
            }
        }
        return results
    }

    /// Of every collection `leaves` are spread across, the one holding the
    /// most of them, where new same-type records get inserted, on the
    /// reasoning that "wherever most of this file's real records of this
    /// type already live" is a more representative home than an arbitrary
    /// first match, and structurally safe regardless: a decode-side reader
    /// aggregates leaves by payload type across every tier-2 collection
    /// (see `graphicsLeaves`'s own doc comment), not by which one a given
    /// leaf happens to sit in, so any collection under the same `.graphics`
    /// container is a valid landing spot. `nil` when `leaves` is empty , 
    /// the file has no existing record of this type at all to anchor to.
    /// Not `private`: `CrossFileGameObjectCopier` reuses this too, same
    /// reasoning as `rawBytes` above.
    static func mostPopulousCollection(of leaves: [(collection: ChunkNode, leaf: ChunkNode)]) -> ChunkNode? {
        var counts: [UUID: (node: ChunkNode, count: Int)] = [:]
        for (collection, _) in leaves {
            counts[collection.id, default: (collection, 0)].count += 1
        }
        return counts.values.max(by: { $0.count < $1.count })?.node
    }

    private static func isRigidModelPayload(_ payload: ChunkPayload) -> Bool {
        if case .rigidModel = payload { return true }
        return false
    }

    private static func isMaterialPayload(_ payload: ChunkPayload) -> Bool {
        if case .material = payload { return true }
        return false
    }

    private static func isTexturePayload(_ payload: ChunkPayload) -> Bool {
        if case .texture = payload { return true }
        return false
    }

    private static func isLodModelPayload(_ payload: ChunkPayload) -> Bool {
        if case .lodModel = payload { return true }
        return false
    }

    /// `SectionType.model`'s real payload, a non-skinned `.mesh` (see
    /// `AssetResolver.buildIndex`'s own `case .mesh(let mesh): if
    /// mesh.isSkinned { skins } else { models }` split); a skinned mesh
    /// belongs to a `Skin` record instead, never a `RigidModel.meshID`.
    private static func isNonSkinnedMeshPayload(_ payload: ChunkPayload) -> Bool {
        if case .mesh(let mesh) = payload { return !mesh.isSkinned }
        return false
    }

    /// Walks a real, already-valid `Material` record's own bytes exactly
    /// like `MaterialParser.readShader` does (shaderType-keyed variable
    /// param block, then the fixed render-state fields), but records each
    /// shader's `textureId` absolute byte offset instead of building a
    /// `TwinsShaderInfo`, this is the one field inside a raw-copied
    /// `Material` that must be patched to point at the freshly-copied
    /// texture instead of the source file's own texture ID.
    /// Not `private`: `CrossFileGameObjectCopier` reuses this exact
    /// Material-shader-block walk for its own Skin-sourced materials, the
    /// on-disk `Material` layout doesn't differ by which mesh type
    /// references it, so the same offset scan applies unchanged.
    static func shaderTextureIDOffsets(in materialBytes: Data) throws -> [(offset: Int, textureID: UInt32)] {
        var cursor = BinaryCursor(data: materialBytes)
        _ = try cursor.readUInt64() // Header
        _ = try cursor.readInt32()  // Unknown
        let nameLen = Int(try cursor.readInt32())
        _ = try cursor.readBytes(nameLen)
        let shaderCount = try cursor.readInt32()

        var results: [(offset: Int, textureID: UInt32)] = []
        for _ in 0..<max(0, shaderCount) {
            let shaderType = try cursor.readUInt32()
            switch shaderType {
            case 23:
                _ = try cursor.readUInt32()
                _ = try cursor.readFloat32()
                _ = try cursor.readFloat32()
            case 26:
                _ = try cursor.readUInt32()
                for _ in 0..<4 { _ = try cursor.readFloat32() }
            case 16, 17:
                _ = try cursor.readFloat32()
            default:
                break
            }
            _ = try cursor.readBytes(17)
            _ = try cursor.readBool()
            _ = try cursor.readBytes(6)
            _ = try cursor.readBytes(3)
            _ = try cursor.readUInt8()
            _ = try cursor.readBytes(2)
            _ = try cursor.readUInt16()
            _ = try cursor.readUInt16()
            _ = try cursor.readBytes(48)

            let textureIDOffset = cursor.position
            let textureID = try cursor.readUInt32()
            _ = try cursor.readUInt32() // trailing repeated ShaderType
            results.append((textureIDOffset, textureID))
        }
        return results
    }

    /// Not `private`: `CrossFileGameObjectCopier` reuses this too, same
    /// reasoning as `rawBytes` above.
    static func writeUInt32LE(_ value: UInt32, at offset: Int, in data: inout Data) {
        let base = data.startIndex + offset
        data[base] = UInt8(value & 0xFF)
        data[base + 1] = UInt8((value >> 8) & 0xFF)
        data[base + 2] = UInt8((value >> 16) & 0xFF)
        data[base + 3] = UInt8((value >> 24) & 0xFF)
    }
}
