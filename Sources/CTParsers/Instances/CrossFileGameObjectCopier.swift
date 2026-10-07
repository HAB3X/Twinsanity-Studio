import Foundation
import CTCore
import CTModels

/// Copies a skinned character's real `GameObject` (game-logic definition) , 
/// plus the `GraphicsInfo`/`Skin`/`Material`/`Texture` chain it needs to
/// actually render, from one file into another. This is the missing half
/// of "Forge Palette anywhere" (`GlobalObjectResolutionCache`'s own doc
/// comment): that feature lets a user *preview* any object ID on the disc
/// by borrowing another level's real geometry for display only, but never
/// copied anything into the file actually being saved, an Instance
/// pointing at an `objectID` with no `GameObject` record in its own file
/// has nothing for the real game to spawn once booted, even though the
/// editor showed a fully real model. Real, reported bug ("items not
/// appearing when I boot in"), confirmed against the real retail disc:
/// `beach.rm2` (Earth/Hub/Beach) carries zero `GameObject` records for
/// several enemy types the Forge Palette still lets you place there
/// (`GLOBAL_RAT_DARKBROWN`/`GLOBAL_RAT_DARKPURPLE`/`GLOBAL_RAT_GREY`/
/// `GLOBAL_PIG_WILDBOAR`/`GLOBAL_COCKROACH`), and the shared `Default.rm2`
/// fallback doesn't carry them either (`Default.rm2`'s own 30
/// `InstanceTemplate` records are exclusively crates/pickups, see
/// `WorkspaceViewModel.FileRecordBundle.instanceTemplateProperties`'s doc
/// comment).
///
/// Deliberately scoped to the **skinned-character** resolution path only
/// (`GraphicsInfo.skinID` resolving to a real `Skin` mesh), the exact
/// chain `AssetResolver.resolveInstanceObject`'s own `resolveSkeleton`
/// branch uses, and the one that covers every real enemy/AI object this
/// bug was ever reported against (character models are always skinned on
/// this engine; a plain `RigidModel`-via-`modelLinks` prop like a crate
/// almost never needs this path at all, since crates already resolve
/// through `Default.rm2` universally, confirmed empirically, see the doc
/// comment above). The `modelLinks` (multi-part rigid prop) resolution
/// path is real, separate work this doesn't attempt, `throws
/// .notASkinnedCharacter` for that case so a caller can fall back to the
/// existing honest "preview only" warning instead of silently doing
/// nothing.
///
/// Every copied record's real, raw on-disk bytes are used verbatim where
/// this build has no from-scratch writer for the format (`Skin`'s own VIF-
/// encoded vertex data, `Texture`), and the two records this build *does*
/// have a real writer for (`GraphicsInfo` via `SkeletonWriter`, `GameObject`
/// via `GameObjectWriter`) are decoded, mutated, and cleanly re-encoded , 
/// same two-track discipline `CrossFileModelCopier` already established for
/// scenery, generalized here to a structurally different record chain
/// (`Code`'s `Object`/`OGI` collections, not just `Graphics`).
///
/// IDs: the `GameObject` record's own ID is **never** remapped, unlike
/// every other copied record, `objectID` is the exact well-known constant
/// `Instance.objectID` already points at (the Forge-placed Instance this
/// copy exists to back), not an arbitrary sequential number a fresh ID
/// would be safe to reassign. Every other copied record (`GraphicsInfo`/
/// `Skin`/`Material`/`Texture`) gets a fresh destination-local ID, exactly
/// like `CrossFileModelCopier`'s own reasoning: a small sequential ID
/// colliding between two unrelated levels is common, not rare.
///
/// `animIDs` and `scriptIDs` (including `HeaderScript` chains, resolved and
/// remapped recursively by record ID) are copied, see the doc comment on
/// this function's own `animIDs`/`scriptIDs` handling below for exactly how
/// and why. Every `ogiIDs` slot beyond the one actually used, plus
/// `soundIDs`/`objectIDs` (sub-objects) and the optional `linkedIDs`
/// trailing block, are still deliberately dropped rather than copied , 
/// real, disclosed scope limits, not oversights:
/// - Every `ogiIDs` slot but index 0: a Forge-placed Instance always starts
///   with selector `0` (its `unknownUInt32List2` starts empty, see
///   `WorldPlacementWriter.writeNewInstance`'s own doc comment), so only
///   `ogiIDs[0]` is ever actually reachable through a fresh placement;
///   every other slot is set to the real on-disk "no value" sentinel
///   (`65535`) rather than left pointing at a source-file-scoped ID that
///   means nothing in the destination.
/// - `soundIDs`/`objectIDs`/`linkedIDs`: reference *other* record IDs this
///   function doesn't also copy, kept, they'd either dangle or (worse)
///   collide with an unrelated real record already sitting at that same
///   number in the destination file. Even CrateModLoader's own working,
///   shipped randomizer mods special-case sound copying as broken and
///   route around it (`TS_Rand_Enemies.cs`'s own `CachePass` comment:
///   "soundless objects - temporary workaround because sound import/export
///   is broken"), this build doesn't attempt what a decade-old, actively
///   maintained reference tool itself couldn't get right either.
public enum CrossFileGameObjectCopier {
    public struct CopyResult: Sendable {
        public var destinationBytes: Data
    }

    public enum CopyError: Error, LocalizedError {
        case gameObjectNotFound(UInt16)
        case gameObjectAlreadyPresent(UInt16)
        case noUsableOGI(UInt16)
        case notASkinnedCharacter(UInt16)
        case missingCollection(SectionType, file: String)
        case recordNotFound(SectionType, UInt32)
        case insertionFailed

        public var errorDescription: String? {
            switch self {
            case .gameObjectNotFound(let id):
                return "Object #\(id) has no real GameObject record anywhere on this disc, this build only found it as a rendering preview, not real game data."
            case .gameObjectAlreadyPresent(let id):
                return "Object #\(id) already has a real GameObject record in the destination file, nothing to copy."
            case .noUsableOGI(let id):
                return "Object #\(id)'s GameObject record has no usable GraphicsInfo (OGI) entry to copy."
            case .notASkinnedCharacter(let id):
                return "Object #\(id) isn't a skinned character (no resolvable Skin mesh), this build only copies the skinned-character chain, not multi-part rigid props."
            case .missingCollection(let type, let file):
                return "The \(file) file has no \(type) collection this build recognizes."
            case .recordNotFound(let type, let id):
                return "Couldn't find \(type) #\(id), the source file may be missing real data this copy depends on."
            case .insertionFailed:
                return "Internal error: couldn't safely insert the copied records into the destination file's structure."
            }
        }
    }

    /// True when `objectID` already has a real `GameObject` record in
    /// `fileRoot`, callers check this first so a copy is never attempted
    /// (or reported as needed) for an object that's already natively
    /// present, matching `AssetResolver.canResolveObjectID`'s own "this
    /// level's own data first" precedence.
    public static func hasNativeGameObject(objectID: UInt16, in fileRoot: ChunkNode) -> Bool {
        !codeLeaves(in: fileRoot, matching: { if case .gameObject(let g) = $0 { return g.id == UInt32(objectID) } else { return false } }).isEmpty
    }

    /// Copies `objectID`'s complete skinned-character chain from
    /// `sourceFileRoot` into `destinationFileRoot`'s own real data, one
    /// single atomic multi-section insert (`ChunkSectionInserter.
    /// applyingRecordChanges`), so nothing about this can leave the
    /// destination file with some of the chain committed and the rest not.
    /// A thin wrapper over `resolvingSkinnedGameObjectInsertions` for
    /// standalone use (this type's own tests); `WorkspaceViewModel` calls
    /// that lower-level function directly instead, so a save placing
    /// several *different* missing objects at once folds every one of
    /// their insertions into the *same* atomic rebuild the Instance/
    /// Trigger/Camera/AIPosition/AIPath edits already go through, see
    /// that function's own doc comment for why a separate
    /// `ChunkSectionInserter` call per object would be unsafe.
    public static func copyingSkinnedGameObjectChain(
        objectID: UInt16,
        sourceFileRoot: ChunkNode,
        sourceBytes: Data,
        destinationFileRoot: ChunkNode,
        destinationBytes: Data
    ) throws -> CopyResult {
        let resolved = try resolvingSkinnedGameObjectInsertions(
            objectID: objectID, sourceFileRoot: sourceFileRoot, sourceBytes: sourceBytes, destinationFileRoot: destinationFileRoot
        )
        guard let result = ChunkSectionInserter.applyingRecordChanges(intoSections: resolved.targets.map { (section: $0.section, insert: $0.insert, removeIDs: []) }, fileRoot: destinationFileRoot, originalFileBytes: destinationBytes) else {
            throw CopyError.insertionFailed
        }
        return CopyResult(destinationBytes: result)
    }

    /// Every record this type's `objectID` copy needs, as ready-to-insert
    /// `(section, records)` targets, the same shape `WorkspaceViewModel.
    /// patchedFileBytes`'s own `Instance`/`Trigger`/`Camera`/`AIPosition`/
    /// `AIPath` insertions already accumulate into one combined `targets`
    /// array before the single, atomic `ChunkSectionInserter.
    /// applyingRecordChanges` call that actually rebuilds the file, this
    /// function computes the records, it never calls that rebuild itself,
    /// so a caller handling several pending cross-level objects in one save
    /// can fold every one of their insertions into that same atomic call
    /// instead of each doing its own separate (and, threaded together,
    /// unsafe, see `ChunkSectionInserter`'s own doc comment on why
    /// sequential single-target rebuilds against a shared ancestor corrupt
    /// the result) rebuild.
    ///
    /// `additionalClaimedIDs` exists for exactly that multi-object case:
    /// this function's own fresh-ID assignment only ever looks at
    /// `destinationFileRoot`'s *real, on-disk* existing records, it has no
    /// way to know a *sibling* call earlier in the same batch already
    /// claimed some fresh ID for a different object's own OGI/Skin/
    /// Material/Texture, since neither call actually mutates
    /// `destinationFileRoot` (both compute *insertions* against the same
    /// unmodified tree, deferred to one shared rebuild afterward). A caller
    /// processing multiple objects threads each call's own `claimedIDs`
    /// result into the *next* call's `additionalClaimedIDs`, so IDs never
    /// collide across objects in the same batch even though neither
    /// touches the real tree in between.
    public static func resolvingSkinnedGameObjectInsertions(
        objectID: UInt16,
        sourceFileRoot: ChunkNode,
        sourceBytes: Data,
        destinationFileRoot: ChunkNode,
        additionalClaimedIDs: (ogi: Set<UInt32>, skin: Set<UInt32>, material: Set<UInt32>, texture: Set<UInt32>, script: Set<UInt32>, animation: Set<UInt32>) = ([], [], [], [], [], [])
    ) throws -> (targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)])], claimedIDs: (ogi: UInt32, skin: UInt32, material: Set<UInt32>, texture: Set<UInt32>, script: Set<UInt32>, animation: Set<UInt32>)) {
        guard !hasNativeGameObject(objectID: objectID, in: destinationFileRoot) else {
            throw CopyError.gameObjectAlreadyPresent(objectID)
        }

        let sourceGameObjectLeaves = codeLeaves(in: sourceFileRoot, matching: isGameObjectPayload)
        guard let gameObjectNode = sourceGameObjectLeaves.first(where: { if case .gameObject(let g) = $0.leaf.payload { return g.id == UInt32(objectID) } else { return false } })?.leaf,
              case .gameObject(let gameObject)? = gameObjectNode.payload
        else { throw CopyError.gameObjectNotFound(objectID) }

        let noValue: UInt32 = 65535
        guard !gameObject.ogiIDs.isEmpty, gameObject.ogiIDs[0] != noValue else { throw CopyError.noUsableOGI(objectID) }
        let sourceOGIID = gameObject.ogiIDs[0]

        let sourceOGILeaves = codeLeaves(in: sourceFileRoot, matching: isSkeletonPayload)
        guard let ogiNode = sourceOGILeaves.first(where: { $0.leaf.recordID == sourceOGIID })?.leaf,
              case .skeleton(let skeleton)? = ogiNode.payload
        else { throw CopyError.recordNotFound(.ogi, sourceOGIID) }

        // Looked up by structural `sectionType`, not decoded `.mesh`
        // payload, this function only ever copies a Skin's raw bytes
        // verbatim (never re-interprets its VIF-encoded vertex data, see
        // `skinMaterialIDOffsets` below), so a real Skin record this
        // build's own `SkinParser` can't fully decode (real, possible , 
        // this format has exotic real-disc variants elsewhere) is still a
        // perfectly safe, correct thing to copy; requiring a successful
        // decode here would refuse a copy this function is fully capable
        // of doing right.
        //
        // `skinID == 0` is real, not a guessed-away edge case, confirmed
        // against real disc data: Cortex's own weapon (`MULTITOOL`, a real
        // `linkedIDs.objects` entry, referenced by his own real script
        // chain) is a *pure rigid prop* GameObject: `skinID == 0`, geometry
        // entirely via `modelLinks` (already copied below regardless of
        // skin presence). Throwing `.notASkinnedCharacter` here for that
        // case, the original behavior, silently dropped every non-
        // skinned linked object a character depends on, which is exactly
        // how a real, requested "give him his weapon too" copy came up
        // empty. `objectID` itself is still required to have *some* usable
        // OGI (checked above), only the skin *within* that OGI is now
        // optional.
        let sourceSkinLeaves = graphicsLeavesBySectionType(in: sourceFileRoot, types: [.skin, .skinX])
        let sourceSkinNode: ChunkNode? = skeleton.skinID == 0 ? nil : sourceSkinLeaves.first(where: { $0.leaf.recordID == skeleton.skinID })?.leaf
        if skeleton.skinID != 0, sourceSkinNode == nil {
            throw CopyError.recordNotFound(.skin, skeleton.skinID) // a real, non-zero skinID this build can't actually find, dropped, not guessed at.
        }

        let sourceMaterialLeaves = CrossFileModelCopier.graphicsLeaves(in: sourceFileRoot, matching: isMaterialPayload)
        let sourceTextureLeaves = CrossFileModelCopier.graphicsLeaves(in: sourceFileRoot, matching: isTexturePayload)

        let destOGILeaves = codeLeaves(in: destinationFileRoot, matching: isSkeletonPayload)
        let destObjectLeaves = codeLeaves(in: destinationFileRoot, matching: isGameObjectPayload)
        let destSkinLeaves = graphicsLeavesBySectionType(in: destinationFileRoot, types: [.skin, .skinX])
        let destMaterialLeaves = CrossFileModelCopier.graphicsLeaves(in: destinationFileRoot, matching: isMaterialPayload)
        let destTextureLeaves = CrossFileModelCopier.graphicsLeaves(in: destinationFileRoot, matching: isTexturePayload)

        guard let destOGICollection = CrossFileModelCopier.mostPopulousCollection(of: destOGILeaves) ?? codeCollection(.ogi, in: destinationFileRoot) else {
            throw CopyError.missingCollection(.ogi, file: "destination")
        }
        guard let destObjectCollection = CrossFileModelCopier.mostPopulousCollection(of: destObjectLeaves) ?? codeCollection(.object, in: destinationFileRoot) else {
            throw CopyError.missingCollection(.object, file: "destination")
        }
        // Only actually required when there's a real skin to insert, a
        // rigid-prop-only object (like Cortex's own `MULTITOOL` weapon,
        // `skinID == 0`, see `sourceSkinNode`'s own doc comment above)
        // needs no destination skin collection to exist at all.
        let destSkinCollection: ChunkNode? = sourceSkinNode == nil ? nil : (CrossFileModelCopier.mostPopulousCollection(of: destSkinLeaves) ?? CrossFileModelCopier.graphicsCollection(.skin, in: destinationFileRoot))
        if sourceSkinNode != nil, destSkinCollection == nil {
            throw CopyError.missingCollection(.skin, file: "destination")
        }
        guard let destMaterialCollection = CrossFileModelCopier.mostPopulousCollection(of: destMaterialLeaves) ?? CrossFileModelCopier.graphicsCollection(.material, in: destinationFileRoot) else {
            throw CopyError.missingCollection(.material, file: "destination")
        }
        guard let destTextureCollection = CrossFileModelCopier.mostPopulousCollection(of: destTextureLeaves) ?? CrossFileModelCopier.graphicsCollection(.texture, in: destinationFileRoot) else {
            throw CopyError.missingCollection(.texture, file: "destination")
        }

        var nextTextureID = max(destTextureLeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.texture.max() ?? 0) + 1
        var nextMaterialID = max(destMaterialLeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.material.max() ?? 0) + 1
        // Only actually allocated/used when `sourceSkinNode != nil` below , 
        // computed unconditionally is harmless (a fresh ID nothing ever
        // references costs nothing) and keeps this simpler than threading
        // an `Optional` through every later use site.
        let newSkinID = max(destSkinLeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.skin.max() ?? 0) + 1
        let newOGIID = max(destOGILeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.ogi.max() ?? 0) + 1

        // Walk the Skin's own raw bytes for each submodel's embedded
        // materialID (`SkinParser.parse`'s own read order: subModelCount,
        // then per submodel `[materialID][codeSize][declaredVertexAmount]
        // [codeSize bytes of VIF code]`), never decodes the VIF code
        // itself, only skips over it via `codeSize`. Empty when this
        // object has no skin at all (a pure rigid prop like `MULTITOOL`) , 
        // the loop below then does nothing, same as it always did for an
        // object with a skin but zero real submodels.
        var skinBytes = sourceSkinNode.map { CrossFileModelCopier.rawBytes(of: $0, in: sourceBytes) } ?? Data()
        let materialOffsets = sourceSkinNode == nil ? [] : try Self.skinMaterialIDOffsets(in: skinBytes)

        var textureInserts: [(id: UInt32, encoded: Data)] = []
        var materialInserts: [(id: UInt32, encoded: Data)] = []
        var materialIDRemap: [UInt32: UInt32] = [:]
        var textureIDRemap: [UInt32: UInt32] = [:]

        for entry in materialOffsets where materialIDRemap[entry.materialID] == nil {
            guard let materialNode = sourceMaterialLeaves.first(where: { $0.leaf.recordID == entry.materialID })?.leaf else {
                throw CopyError.recordNotFound(.material, entry.materialID)
            }
            var materialBytes = CrossFileModelCopier.rawBytes(of: materialNode, in: sourceBytes)
            let shaderOffsets = try CrossFileModelCopier.shaderTextureIDOffsets(in: materialBytes)
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
                    textureInserts.append((newTextureID, CrossFileModelCopier.rawBytes(of: textureNode, in: sourceBytes)))
                    textureIDRemap[shader.textureID] = newTextureID
                }
                CrossFileModelCopier.writeUInt32LE(newTextureID, at: shader.offset, in: &materialBytes)
            }
            let newMaterialID = nextMaterialID
            nextMaterialID += 1
            materialInserts.append((newMaterialID, materialBytes))
            materialIDRemap[entry.materialID] = newMaterialID
        }

        for entry in materialOffsets {
            guard let remapped = materialIDRemap[entry.materialID] else { continue }
            CrossFileModelCopier.writeUInt32LE(remapped, at: entry.offset, in: &skinBytes)
        }

        // "Everything Related to a Copied Character": `modelLinks` used to
        // be unconditionally dropped ("real but rare", real, but wrong:
        // this is exactly how this engine attaches a rigid sub-model (a
        // head, in Cortex's own real case, confirmed the hard way, via a
        // real PCSX2 boot showing his copied body with no face) to a
        // specific joint alongside the main skinned mesh, not a rare
        // edge case for a skinned character at all. Each link's own
        // `modelID` gets the exact same real, working cross-file copy
        // `CrossFileModelCopier.resolvingRigidModelInsertions` already
        // does for scenery, full material/texture/mesh chain included , 
        // threading this function's own already-claimed material/texture
        // IDs in (and threading each link's own claims into the next, for
        // a character with more than one) so neither copy can collide
        // with the other's fresh IDs.
        var copiedModelLinks: [ModelLink] = []
        var modelLinkTargets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)])] = []
        var claimedMaterial = Set(materialInserts.map(\.id))
        var claimedTexture = Set(textureInserts.map(\.id))
        var claimedMesh: Set<UInt32> = []
        var claimedRigidModel: Set<UInt32> = []
        for link in skeleton.modelLinks {
            do {
                let resolvedLink = try CrossFileModelCopier.resolvingRigidModelInsertions(
                    modelID: link.modelID, isSpecial: false, sourceFileRoot: sourceFileRoot, sourceBytes: sourceBytes,
                    destinationFileRoot: destinationFileRoot,
                    additionalClaimedIDs: (claimedMaterial, claimedTexture, claimedMesh, claimedRigidModel)
                )
                claimedMaterial.formUnion(resolvedLink.claimedIDs.material)
                claimedTexture.formUnion(resolvedLink.claimedIDs.texture)
                claimedMesh.insert(resolvedLink.claimedIDs.mesh)
                claimedRigidModel.insert(resolvedLink.claimedIDs.rigidModel)
                modelLinkTargets.append(contentsOf: resolvedLink.targets)
                copiedModelLinks.append(ModelLink(jointIndex: link.jointIndex, modelID: resolvedLink.rigidModelID))
            } catch {
                continue // real, disclosed limitation, a link this build's rigid-model copier can't resolve is dropped, not guessed at.
            }
        }

        // `GraphicsInfo`/`skeleton` copy: `skinID` remapped, `modelLinks`
        // remapped to their own real cross-file copies above (empty when
        // the source genuinely has none, or none of them resolved).
        var copiedSkeleton = skeleton
        copiedSkeleton.skinID = sourceSkinNode == nil ? 0 : newSkinID
        copiedSkeleton.modelLinks = copiedModelLinks
        let ogiBytes = SkeletonWriter.write(copiedSkeleton)

        // "Real Player Control / AI Behavior for Copied Objects": `scriptIDs`
        // used to be unconditionally dropped, then copied `MainScript`
        // records only, `HeaderScript` records (`entries[].mainScriptIndex`
        // pointing at another Script record) were dropped outright, since
        // this build had no verified evidence that field was a chunk record
        // ID versus a collection-relative position. An earlier attempt at
        // the "position within this GameObject's own scriptIDs list, needs
        // no remapping" hypothesis caused a real PCSX2 boot crash, but that
        // was the WRONG guess, not proof HeaderScript can't be copied
        // safely. The real reference source settles it:
        // `TwinsaityEditor/Editors/ScriptEditor.cs`'s own
        // `createScriptToolStripMenuItem_Click` allocates two fresh *chunk
        // record IDs* (`id1`/`id2`) and builds `new Script.
        // HeaderScript((int)id2)`, whose constructor does `pair.
        // mainScriptIndex = id + 1`, for a `MainScript` it creates
        // separately under `id2`. A real disc scan of every HeaderScript in
        // both Crash's and Cortex's own script chains in `l10chasb.rm2`
        // (where both are genuinely playable) confirms it end to end:
        // `mainScriptIndex - 1` resolves to a real Script record in that
        // same file by exact record ID, every single time, and Cortex's own
        // chain contains real, working `SetPlayerInput` (command 521) calls
        // reached exactly that way (`COM_CORTEX_LINKED_STANDING_JUMP`/
        // `RUNNING_JUMP`). So it's a genuine record-ID reference needing the
        // same copy-and-remap treatment as every other one this function
        // already handles (`ogiIDs`, `scriptIDs` themselves, `animIDs`) , 
        // this time actually remapped, which is exactly what the crashing
        // attempt didn't do (it copied `mainScriptIndex` verbatim, so it
        // pointed at whatever unrelated record already occupied that number
        // in the destination file).
        //
        // `copyScriptRecord` is recursive because a `HeaderScript`'s own
        // target could in principle be another `HeaderScript` (never
        // observed in practice, but the format doesn't rule it out) , 
        // `scriptIDRemap` is populated for a source ID *before* recursing
        // into its own targets, so even a malformed cyclic chain terminates
        // instead of looping. A target this build can't resolve (a
        // genuinely missing record) leaves that one alternative disabled
        // (`mainScriptIndex = 0`, the same "no value" shape real
        // HeaderScripts already carry for their own unused alternative
        // slots) rather than guessed at. `MainScript` records still copy by
        // raw bytes, unchanged, no internal field there needs patching.
        let sourceScriptLeaves = codeLeaves(in: sourceFileRoot, matching: isScriptPayload)
        let destScriptLeaves = codeLeaves(in: destinationFileRoot, matching: isScriptPayload)
        var nextScriptID = max(destScriptLeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.script.max() ?? 0) + 1
        var scriptInserts: [(id: UInt32, encoded: Data)] = []
        var scriptIDRemap: [UInt32: UInt32] = [:]

        func copyScriptRecord(sourceID: UInt32) -> UInt32? {
            if let already = scriptIDRemap[sourceID] { return already }
            guard let scriptNode = sourceScriptLeaves.first(where: { $0.leaf.recordID == sourceID })?.leaf,
                  case .script(let script)? = scriptNode.payload
            else { return nil } // genuinely missing, dropped, not guessed at.
            let newID = nextScriptID
            nextScriptID += 1
            scriptIDRemap[sourceID] = newID // reserved before recursing, breaks any cycle safely.
            switch script.content {
            case .main:
                scriptInserts.append((newID, CrossFileModelCopier.rawBytes(of: scriptNode, in: sourceBytes)))
            case .header(let header):
                let remappedEntries = header.entries.map { entry -> HeaderScript.Entry in
                    guard entry.mainScriptIndex >= 1, let newTarget = copyScriptRecord(sourceID: UInt32(entry.mainScriptIndex - 1)) else {
                        return HeaderScript.Entry(mainScriptIndex: 0, unkInt2: entry.unkInt2)
                    }
                    return HeaderScript.Entry(mainScriptIndex: Int32(newTarget) + 1, unkInt2: entry.unkInt2)
                }
                let newHeader = HeaderScript(entries: remappedEntries, entriesFileOffset: header.entriesFileOffset)
                let newScript = ScriptAsset(id: newID, inlineID: script.inlineID, mask: script.mask, flag: script.flag, content: .header(newHeader), trailingBytes: script.trailingBytes)
                scriptInserts.append((newID, ScriptWriter.encode(newScript)))
            }
            return newID
        }

        var copiedScriptIDs: [UInt16] = []
        for sourceScriptID in gameObject.scriptIDs {
            guard let newID = copyScriptRecord(sourceID: UInt32(sourceScriptID)) else {
                continue // sentinel (65535) or genuinely missing record, dropped, not guessed at.
            }
            copiedScriptIDs.append(UInt16(truncatingIfNeeded: newID))
        }
        // "His Weapon VFX/SFX, Not Just His Skin": `linkedIDs.codeModels`
        // (`CustomAgent`/`CodeModel` records), a real, dev-authored,
        // per-key table of particle/sound-effect commands
        // (`CA_DoParticle`/`CA_DoSound`/`CA_AddTrail`/`CA_CreateDamage`).
        // Confirmed against real disc data: Cortex's own 4 real
        // `CodeModel` records are his weapon's visual/audio effects (a
        // "Key -> animation" dispatcher was the first hypothesis; real
        // data ruled that out, every command inside is a particle/sound/
        // damage-number effect, not an animation reference). Each entry's
        // own `scriptID` is a reference into the same Script/Code
        // collection `scriptIDs` above already resolves, so it gets the
        // exact same `copyScriptRecord` treatment, reused directly since
        // it's already in scope here.
        var codeModelInserts: [(id: UInt32, encoded: Data)] = []
        if let linkedIDs = gameObject.linkedIDs, !linkedIDs.codeModels.isEmpty {
            let sourceCodeModelLeaves = codeLeaves(in: sourceFileRoot, matching: isCustomAgentPayload)
            let destCodeModelLeaves = codeLeaves(in: destinationFileRoot, matching: isCustomAgentPayload)
            var nextCodeModelID = (destCodeModelLeaves.map(\.leaf.recordID).max() ?? 0) + 1
            for sourceCodeModelID in linkedIDs.codeModels {
                guard let node = sourceCodeModelLeaves.first(where: { $0.leaf.recordID == UInt32(sourceCodeModelID) })?.leaf,
                      case .customAgent(let record)? = node.payload
                else { continue } // genuinely missing, dropped, not guessed at.
                let remappedEntries = record.entries.map { entry -> AgentLabScriptEntry in
                    guard entry.scriptID != UInt16(truncatingIfNeeded: noValue), let newScriptID = copyScriptRecord(sourceID: UInt32(entry.scriptID)) else {
                        return entry
                    }
                    return AgentLabScriptEntry(scriptID: UInt16(truncatingIfNeeded: newScriptID), commands: entry.commands)
                }
                let newCodeModelID = nextCodeModelID
                nextCodeModelID += 1
                let newRecord = CustomAgentRecord(recordID: newCodeModelID, headerRaw: record.headerRaw, entries: remappedEntries, finalCommands: record.finalCommands)
                codeModelInserts.append((newCodeModelID, CustomAgentWriter.encode(newRecord)))
            }
        }
        var destCodeModelCollection: ChunkNode?
        if !codeModelInserts.isEmpty {
            guard let collection = CrossFileModelCopier.mostPopulousCollection(of: codeLeaves(in: destinationFileRoot, matching: isCustomAgentPayload)) ?? codeCollection(.customAgent, in: destinationFileRoot) else {
                throw CopyError.missingCollection(.customAgent, file: "destination")
            }
            destCodeModelCollection = collection
        }

        var destScriptCollection: ChunkNode?
        if !scriptInserts.isEmpty {
            guard let collection = CrossFileModelCopier.mostPopulousCollection(of: destScriptLeaves) ?? codeCollection(.script, in: destinationFileRoot) else {
                throw CopyError.missingCollection(.script, file: "destination")
            }
            destScriptCollection = collection
        }

        // "Real Animation for Copied Characters": `animIDs` used to be
        // unconditionally dropped to empty, real, but only because this
        // type had no writer for the `Animation` format at the time. A
        // real, verified one now exists (`AnimationParser`/`AnimationWriter`,
        // ported from `Animation.cs`'s own `Load`/`Save`, ID referenced
        // purely through the chunk index table with no internal field
        // needing a patch, same "copy by raw bytes, remap the ID" shape
        // `scriptIDs` right above already established, not the "copy a
        // decode+re-encode round trip" shape `GameObject`/`GraphicsInfo`
        // need). `65535` (`noValue`) slots are preserved as-is rather than
        // looked up, a source `GameObject` legitimately leaves most of
        // its own `animIDs` slots unused.
        let sourceAnimationLeaves = codeLeaves(in: sourceFileRoot, matching: isAnimationPayload)
        let destAnimationLeaves = codeLeaves(in: destinationFileRoot, matching: isAnimationPayload)
        var nextAnimationID = max(destAnimationLeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.animation.max() ?? 0) + 1
        var animationInserts: [(id: UInt32, encoded: Data)] = []
        var animationIDRemap: [UInt16: UInt16] = [:]
        var copiedAnimIDs: [UInt16] = []
        for sourceAnimID in gameObject.animIDs {
            if sourceAnimID == UInt16(truncatingIfNeeded: noValue) {
                copiedAnimIDs.append(sourceAnimID)
                continue
            }
            if let already = animationIDRemap[sourceAnimID] {
                copiedAnimIDs.append(already)
                continue
            }
            guard let animationLeaf = sourceAnimationLeaves.first(where: { $0.leaf.recordID == UInt32(sourceAnimID) })?.leaf,
                  case .animation(let animation)? = animationLeaf.payload
            else {
                copiedAnimIDs.append(UInt16(truncatingIfNeeded: noValue)) // genuinely missing, dropped to "no value," not guessed at.
                continue
            }
            let newAnimID = UInt16(truncatingIfNeeded: nextAnimationID)
            nextAnimationID += 1
            animationInserts.append((UInt32(newAnimID), AnimationWriter.write(animation)))
            animationIDRemap[sourceAnimID] = newAnimID
            copiedAnimIDs.append(newAnimID)
        }
        var destAnimationCollection: ChunkNode?
        if !animationInserts.isEmpty {
            guard let collection = CrossFileModelCopier.mostPopulousCollection(of: destAnimationLeaves) ?? codeCollection(.animation, in: destinationFileRoot) else {
                throw CopyError.missingCollection(.animation, file: "destination")
            }
            destAnimationCollection = collection
        }

        // `GameObject` copy: same ID (a well-known constant, not a fresh
        // one, see this type's own top-level doc comment), `ogiIDs`
        // rebuilt to the same length as the source (preserving index
        // positions a *different*, already-real Instance elsewhere might
        // rely on) but pointing only at the one OGI actually copied , 
        // index 0 gets the real new ID, every other slot the on-disk "no
        // value" sentinel rather than a source-file-scoped ID that means
        // nothing here.
        var copiedGameObject = gameObject
        copiedGameObject.ogiIDs = gameObject.ogiIDs.indices.map { $0 == 0 ? newOGIID : noValue }
        copiedGameObject.animIDs = copiedAnimIDs
        copiedGameObject.scriptIDs = copiedScriptIDs
        copiedGameObject.objectIDs = []
        copiedGameObject.soundIDs = []
        copiedGameObject.linkedIDs = nil
        copiedGameObject.unkBitfield &= ~UInt32(0x4000_0000) // clears `hasResources`, matching `linkedIDs = nil` above
        let gameObjectBytes = GameObjectWriter.encode(copiedGameObject)

        // Merged by section identity, not just appended, `modelLinkTargets`
        // resolves its own Material/Texture destination collections
        // independently, and they're very likely the exact same
        // `ChunkNode`s this function's own `destMaterialCollection`/
        // `destTextureCollection` already point at. `ChunkSectionInserter.
        // applyingRecordChanges` only ever rebuilds the *first* `targets`
        // entry for a given section (see its own doc comment), so two
        // entries targeting that same node would silently drop one's
        // inserts rather than combining them.
        var mergedBySection: [ObjectIdentifier: (section: ChunkNode, insert: [(id: UInt32, encoded: Data)])] = [:]
        func addTarget(_ section: ChunkNode, _ insert: [(id: UInt32, encoded: Data)]) {
            guard !insert.isEmpty else { return }
            let key = ObjectIdentifier(section)
            mergedBySection[key, default: (section, [])].insert.append(contentsOf: insert)
        }
        addTarget(destTextureCollection, textureInserts)
        addTarget(destMaterialCollection, materialInserts)
        if let destScriptCollection { addTarget(destScriptCollection, scriptInserts) }
        if let destAnimationCollection { addTarget(destAnimationCollection, animationInserts) }
        if let destCodeModelCollection { addTarget(destCodeModelCollection, codeModelInserts) }
        if sourceSkinNode != nil, let destSkinCollection { addTarget(destSkinCollection, [(newSkinID, skinBytes)]) }
        addTarget(destOGICollection, [(newOGIID, ogiBytes)])
        addTarget(destObjectCollection, [(UInt32(objectID), gameObjectBytes)])
        for target in modelLinkTargets { addTarget(target.section, target.insert) }
        let targets = Array(mergedBySection.values)

        return (targets, (newOGIID, newSkinID, Set(materialInserts.map(\.id)).union(claimedMaterial), Set(textureInserts.map(\.id)).union(claimedTexture), Set(scriptInserts.map(\.id)), Set(animationInserts.map(\.id))))
    }

    /// "A Real Playable Character, Not Just A Skin": replaces whichever
    /// `GameObject` already occupies `targetObjectID` in
    /// `destinationFileRoot` with a full cross-file copy of
    /// `sourceObjectID`'s own real character rig from `sourceFileRoot` , 
    /// the exact same chain `resolvingSkinnedGameObjectInsertions` already
    /// copies (skin/skeleton/materials/textures/scripts/animations/
    /// modelLinks), just written under `targetObjectID` instead of a fresh
    /// one, plus every one of that character's own `linkedIDs.objects`
    /// (a real, dev-authored dependency manifest, see
    /// `GameObjectInfo.LinkedIDs`'s own doc comment, not a guess at what
    /// else it needs) copied in as its own separate object, best-effort.
    ///
    /// `targetObjectID`, not a fresh ID, is the deliberate, evidence-based
    /// choice here: a real disc scan (91 separate, independently-numbered
    /// level files) found every real, non-cutscene playable Crash rig
    /// sitting at `GameObject` id 0, strong, direct evidence the PS2
    /// engine's own Player-1 input binds to whatever occupies id 0, not to
    /// which `Instance` happens to reference a given object ID. An earlier
    /// attempt at "add the new character as a *new* object, repoint the
    /// level's Crash `Instance` at it" (this file's own git history) left
    /// the new character fully rendered but completely inert, no
    /// movement, no animation, exactly what this theory predicts: id 0
    /// (the real input target) was left as orphaned Crash data with no
    /// `Instance` pointing at it anymore, while the swapped-in character
    /// was just an ordinary, uncontrolled world object at a different ID.
    /// Overwriting id 0's own content directly needs no `Instance` changes
    /// at all, whatever `Instance`(s) already reference the level's
    /// existing player slot keep working completely unmodified.
    ///
    /// `linkedIDs.ogis`/`.anims`/`.scripts` beyond what `scriptIDs`/
    /// `animIDs`/`ogiIDs[0]` already reach are deliberately NOT separately
    /// walked here, real, disclosed scope limit, not an oversight: a
    /// freshly-repointed `Instance` always renders `ogiIDs[0]` (see
    /// `resolvingSkinnedGameObjectInsertions`'s own doc comment on why
    /// every other `ogiIDs` slot is dropped there too), and every real
    /// animation this build has confirmed against real disc data is
    /// already reachable through `animIDs` alone. `linkedIDs.objects`
    /// entries this build can't resolve a usable *skinned*-character chain
    /// for (a plain rigid prop, or a pure logic/trigger marker like
    /// `MAM_BEAM_START`) are skipped individually, not guessed at, this
    /// function doesn't yet attempt the separate rigid-model-only
    /// resolution path `CrossFileModelCopier` covers for scenery.
    public static func resolvingPlayerCharacterReplacement(
        replacingObjectID targetObjectID: UInt16,
        withRealCharacter sourceObjectID: UInt16,
        sourceFileRoot: ChunkNode,
        sourceBytes: Data,
        destinationFileRoot: ChunkNode
    ) throws -> (targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)], removeIDs: [UInt32])], copiedLinkedObjectIDs: Set<UInt16>) {
        let resolved = try resolvingSkinnedGameObjectInsertions(
            objectID: sourceObjectID, sourceFileRoot: sourceFileRoot, sourceBytes: sourceBytes, destinationFileRoot: destinationFileRoot
        )

        // Redirect the copied `GameObject`'s own chunk-index ID from
        // `sourceObjectID` (a temporary landing spot , 
        // `resolvingSkinnedGameObjectInsertions` itself has no notion of
        // "already present, replace it") to `targetObjectID`, with a
        // matching `removeIDs` so `ChunkSectionInserter` replaces the old
        // occupant instead of leaving both present under colliding IDs.
        // `GameObjectWriter.encode`'s output never embeds this object's own
        // chunk-index ID anywhere in its bytes (that ID lives purely in the
        // containing section's index table, confirmed against
        // `GameObject.Save` in the reference source never writing one), so
        // the *encoded bytes* are reused completely unchanged; only which
        // ID they land under differs.
        var targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)], removeIDs: [UInt32])] = []
        for target in resolved.targets {
            var insert = target.insert
            var removeIDs: [UInt32] = []
            if let index = insert.firstIndex(where: { $0.id == UInt32(sourceObjectID) }) {
                let encoded = insert[index].encoded
                insert.remove(at: index)
                insert.append((UInt32(targetObjectID), encoded))
                removeIDs = [UInt32(targetObjectID)]
            }
            targets.append((target.section, insert, removeIDs))
        }

        // "Leave Nothing Out": each of `sourceObjectID`'s own
        // `linkedIDs.objects` gets its own best-effort skinned-character
        // copy under its OWN id (never `targetObjectID`, only the player
        // character itself takes over that slot), threading claimed IDs
        // across every call the same way `WorkspaceViewModel`'s own
        // multi-object batch save already has to (see
        // `testResolvingInsertionsForTwoDifferentObjectsInOneBatchNeverCollide`)
        // so two independently-resolved objects in this same pass can never
        // collide on a freshly-allocated ID.
        var copiedLinkedObjectIDs: Set<UInt16> = []
        if case .gameObject(let sourceGameObject)? = codeLeaves(in: sourceFileRoot, matching: isGameObjectPayload)
            .first(where: { if case .gameObject(let g) = $0.leaf.payload { return g.id == UInt32(sourceObjectID) } else { return false } })?.leaf.payload,
           let linkedIDs = sourceGameObject.linkedIDs {
            var claimedOGI: Set<UInt32> = [resolved.claimedIDs.ogi]
            var claimedSkin: Set<UInt32> = [resolved.claimedIDs.skin]
            var claimedMaterial = resolved.claimedIDs.material
            var claimedTexture = resolved.claimedIDs.texture
            var claimedScript = resolved.claimedIDs.script
            var claimedAnimation = resolved.claimedIDs.animation
            var mergedBySection: [ObjectIdentifier: (section: ChunkNode, insert: [(id: UInt32, encoded: Data)])] = [:]

            for linkedObjectID16 in Set(linkedIDs.objects) {
                guard linkedObjectID16 != sourceObjectID, linkedObjectID16 != targetObjectID, linkedObjectID16 != 65535 else { continue }
                guard !hasNativeGameObject(objectID: linkedObjectID16, in: destinationFileRoot) else { continue }
                guard let linkedResolved = try? resolvingSkinnedGameObjectInsertions(
                    objectID: linkedObjectID16, sourceFileRoot: sourceFileRoot, sourceBytes: sourceBytes, destinationFileRoot: destinationFileRoot,
                    additionalClaimedIDs: (claimedOGI, claimedSkin, claimedMaterial, claimedTexture, claimedScript, claimedAnimation)
                ) else { continue }
                copiedLinkedObjectIDs.insert(linkedObjectID16)
                claimedOGI.insert(linkedResolved.claimedIDs.ogi)
                claimedSkin.insert(linkedResolved.claimedIDs.skin)
                claimedMaterial.formUnion(linkedResolved.claimedIDs.material)
                claimedTexture.formUnion(linkedResolved.claimedIDs.texture)
                claimedScript.formUnion(linkedResolved.claimedIDs.script)
                claimedAnimation.formUnion(linkedResolved.claimedIDs.animation)
                for target in linkedResolved.targets {
                    let key = ObjectIdentifier(target.section)
                    mergedBySection[key, default: (target.section, [])].insert.append(contentsOf: target.insert)
                }
            }

            // Fold the linked-object inserts into `targets`, keyed by the
            // same section identity, same "never split one section across
            // two `targets` entries" reasoning `resolvingSkinnedGameObjectInsertions`
            // itself already documents.
            targets = targets.map { existing in
                guard let extra = mergedBySection[ObjectIdentifier(existing.section)], !extra.insert.isEmpty else { return existing }
                return (existing.section, existing.insert + extra.insert, existing.removeIDs)
            }
            let alreadyTargetedSections = Set(targets.map { ObjectIdentifier($0.section) })
            for (key, value) in mergedBySection where !value.insert.isEmpty && !alreadyTargetedSections.contains(key) {
                targets.append((value.section, value.insert, []))
            }
        }

        return (targets, copiedLinkedObjectIDs)
    }

    /// "Spawn Interactive Prop with a Borrowed Skin": builds the insertions
    /// for a *synthetic* `GameObject`, `baseGameObject` (a real, working
    /// object already native to `destinationFileRoot`, e.g. `BASICCRATE`)
    /// cloned under a fresh `freshObjectID`, with only its `ogiIDs[0]`
    /// repointed at `skinSourceObjectID`'s own real skinned-character chain
    /// (skeleton/skin/materials/textures), cross-file-copied in exactly the
    /// way `resolvingSkinnedGameObjectInsertions` copies it for its own,
    /// unmodified-GameObject case.
    ///
    /// Exists because that function always keeps the *source* object's own
    /// `scriptIDs`/`animIDs`/behavior, right for "this enemy type doesn't
    /// exist in this level yet," wrong for "I want this level's own real
    /// crate physics wearing a different character's face": a copy of
    /// Cortex's own `GameObject` here would carry no scripts (dropped,
    /// same disclosed limitation as ever) and render in a static bind
    /// pose with no crate-style break/throw behavior at all. Cloning the
    /// *crate's* own real, working `GameObject` and only swapping what it
    /// renders as keeps that real physics intact.
    ///
    /// Static bind pose only, same as any cross-file `GameObject` copy
    /// this build produces, `baseGameObject.animIDs` stays whatever the
    /// caller passed in (typically the real crate's own, since crates
    /// don't animate to begin with, so this costs nothing extra here).
    public static func resolvingPropSkinInsertion(
        freshObjectID: UInt16,
        baseGameObject: GameObjectInfo,
        skinSourceObjectID: UInt16,
        skinSourceFileRoot: ChunkNode,
        skinSourceBytes: Data,
        destinationFileRoot: ChunkNode,
        additionalClaimedIDs: (ogi: Set<UInt32>, skin: Set<UInt32>, material: Set<UInt32>, texture: Set<UInt32>) = ([], [], [], [])
    ) throws -> (targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)])], claimedIDs: (ogi: UInt32, skin: UInt32, material: Set<UInt32>, texture: Set<UInt32>)) {
        guard !hasNativeGameObject(objectID: freshObjectID, in: destinationFileRoot) else {
            throw CopyError.gameObjectAlreadyPresent(freshObjectID)
        }

        let sourceGameObjectLeaves = codeLeaves(in: skinSourceFileRoot, matching: isGameObjectPayload)
        guard let gameObjectNode = sourceGameObjectLeaves.first(where: { if case .gameObject(let g) = $0.leaf.payload { return g.id == UInt32(skinSourceObjectID) } else { return false } })?.leaf,
              case .gameObject(let sourceGameObject)? = gameObjectNode.payload
        else { throw CopyError.gameObjectNotFound(skinSourceObjectID) }

        let noValue: UInt32 = 65535
        guard !sourceGameObject.ogiIDs.isEmpty, sourceGameObject.ogiIDs[0] != noValue else { throw CopyError.noUsableOGI(skinSourceObjectID) }
        let sourceOGIID = sourceGameObject.ogiIDs[0]

        let sourceOGILeaves = codeLeaves(in: skinSourceFileRoot, matching: isSkeletonPayload)
        guard let ogiNode = sourceOGILeaves.first(where: { $0.leaf.recordID == sourceOGIID })?.leaf,
              case .skeleton(let skeleton)? = ogiNode.payload
        else { throw CopyError.recordNotFound(.ogi, sourceOGIID) }

        let sourceSkinLeaves = graphicsLeavesBySectionType(in: skinSourceFileRoot, types: [.skin, .skinX])
        guard skeleton.skinID != 0, let skinNode = sourceSkinLeaves.first(where: { $0.leaf.recordID == skeleton.skinID })?.leaf
        else { throw CopyError.notASkinnedCharacter(skinSourceObjectID) }

        let sourceMaterialLeaves = CrossFileModelCopier.graphicsLeaves(in: skinSourceFileRoot, matching: isMaterialPayload)
        let sourceTextureLeaves = CrossFileModelCopier.graphicsLeaves(in: skinSourceFileRoot, matching: isTexturePayload)

        let destOGILeaves = codeLeaves(in: destinationFileRoot, matching: isSkeletonPayload)
        let destObjectLeaves = codeLeaves(in: destinationFileRoot, matching: isGameObjectPayload)
        let destSkinLeaves = graphicsLeavesBySectionType(in: destinationFileRoot, types: [.skin, .skinX])
        let destMaterialLeaves = CrossFileModelCopier.graphicsLeaves(in: destinationFileRoot, matching: isMaterialPayload)
        let destTextureLeaves = CrossFileModelCopier.graphicsLeaves(in: destinationFileRoot, matching: isTexturePayload)

        guard let destOGICollection = CrossFileModelCopier.mostPopulousCollection(of: destOGILeaves) ?? codeCollection(.ogi, in: destinationFileRoot) else {
            throw CopyError.missingCollection(.ogi, file: "destination")
        }
        guard let destObjectCollection = CrossFileModelCopier.mostPopulousCollection(of: destObjectLeaves) ?? codeCollection(.object, in: destinationFileRoot) else {
            throw CopyError.missingCollection(.object, file: "destination")
        }
        guard let destSkinCollection = CrossFileModelCopier.mostPopulousCollection(of: destSkinLeaves) ?? CrossFileModelCopier.graphicsCollection(.skin, in: destinationFileRoot) else {
            throw CopyError.missingCollection(.skin, file: "destination")
        }
        guard let destMaterialCollection = CrossFileModelCopier.mostPopulousCollection(of: destMaterialLeaves) ?? CrossFileModelCopier.graphicsCollection(.material, in: destinationFileRoot) else {
            throw CopyError.missingCollection(.material, file: "destination")
        }
        guard let destTextureCollection = CrossFileModelCopier.mostPopulousCollection(of: destTextureLeaves) ?? CrossFileModelCopier.graphicsCollection(.texture, in: destinationFileRoot) else {
            throw CopyError.missingCollection(.texture, file: "destination")
        }

        var nextTextureID = max(destTextureLeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.texture.max() ?? 0) + 1
        var nextMaterialID = max(destMaterialLeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.material.max() ?? 0) + 1
        let newSkinID = max(destSkinLeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.skin.max() ?? 0) + 1
        let newOGIID = max(destOGILeaves.map(\.leaf.recordID).max() ?? 0, additionalClaimedIDs.ogi.max() ?? 0) + 1

        var skinBytes = CrossFileModelCopier.rawBytes(of: skinNode, in: skinSourceBytes)
        let materialOffsets = try Self.skinMaterialIDOffsets(in: skinBytes)

        var textureInserts: [(id: UInt32, encoded: Data)] = []
        var materialInserts: [(id: UInt32, encoded: Data)] = []
        var materialIDRemap: [UInt32: UInt32] = [:]
        var textureIDRemap: [UInt32: UInt32] = [:]

        for entry in materialOffsets where materialIDRemap[entry.materialID] == nil {
            guard let materialNode = sourceMaterialLeaves.first(where: { $0.leaf.recordID == entry.materialID })?.leaf else {
                throw CopyError.recordNotFound(.material, entry.materialID)
            }
            var materialBytes = CrossFileModelCopier.rawBytes(of: materialNode, in: skinSourceBytes)
            let shaderOffsets = try CrossFileModelCopier.shaderTextureIDOffsets(in: materialBytes)
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
                    textureInserts.append((newTextureID, CrossFileModelCopier.rawBytes(of: textureNode, in: skinSourceBytes)))
                    textureIDRemap[shader.textureID] = newTextureID
                }
                CrossFileModelCopier.writeUInt32LE(newTextureID, at: shader.offset, in: &materialBytes)
            }
            let newMaterialID = nextMaterialID
            nextMaterialID += 1
            materialInserts.append((newMaterialID, materialBytes))
            materialIDRemap[entry.materialID] = newMaterialID
        }

        for entry in materialOffsets {
            guard let remapped = materialIDRemap[entry.materialID] else { continue }
            CrossFileModelCopier.writeUInt32LE(remapped, at: entry.offset, in: &skinBytes)
        }

        var copiedSkeleton = skeleton
        copiedSkeleton.skinID = newSkinID
        copiedSkeleton.modelLinks = []
        let ogiBytes = SkeletonWriter.write(copiedSkeleton)

        // The clone: `baseGameObject`'s own real fields (scripts, anim
        // selectors, ui32, instance properties, script commands, its
        // whole working behavior) untouched, `id` and `ogiIDs` the only
        // two things that differ from it.
        let clonedGameObject = GameObjectInfo(
            id: UInt32(freshObjectID),
            name: baseGameObject.name,
            ogiIDs: baseGameObject.ogiIDs.indices.map { $0 == 0 ? newOGIID : noValue },
            unkBitfield: baseGameObject.unkBitfield,
            ui32: baseGameObject.ui32,
            animIDs: baseGameObject.animIDs,
            scriptIDs: baseGameObject.scriptIDs,
            objectIDs: baseGameObject.objectIDs,
            soundIDs: baseGameObject.soundIDs,
            instanceProperties: baseGameObject.instanceProperties,
            linkedIDs: baseGameObject.linkedIDs,
            scriptCommands: baseGameObject.scriptCommands
        )
        let gameObjectBytes = GameObjectWriter.encode(clonedGameObject)

        var targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)])] = []
        if !textureInserts.isEmpty { targets.append((destTextureCollection, textureInserts)) }
        if !materialInserts.isEmpty { targets.append((destMaterialCollection, materialInserts)) }
        targets.append((destSkinCollection, [(newSkinID, skinBytes)]))
        targets.append((destOGICollection, [(newOGIID, ogiBytes)]))
        targets.append((destObjectCollection, [(UInt32(freshObjectID), gameObjectBytes)]))

        return (targets, (newOGIID, newSkinID, Set(materialInserts.map(\.id)), Set(textureInserts.map(\.id))))
    }

    // MARK: - Helpers

    private static let codeContainerTypes: Set<SectionType> = [.code, .codeX, .codeDemo]

    /// The `Code` container's own equivalent of `CrossFileModelCopier.
    /// graphicsLeaves`, every leaf anywhere under `.code`/`.codeX`/
    /// `.codeDemo` whose decoded payload satisfies `predicate`, searched
    /// across every one of its tier-2 collections rather than trusting a
    /// specific collection's own `sectionType` tag, same "don't trust the
    /// tag" reasoning `graphicsLeaves`'s own doc comment documents for the
    /// Graphics side.
    private static func codeLeaves(in fileRoot: ChunkNode, matching predicate: (ChunkPayload) -> Bool) -> [(collection: ChunkNode, leaf: ChunkNode)] {
        guard let code = fileRoot.children.first(where: { codeContainerTypes.contains($0.sectionType) }) else { return [] }
        var results: [(collection: ChunkNode, leaf: ChunkNode)] = []
        for collection in code.children {
            for leaf in collection.children {
                guard let payload = leaf.payload, predicate(payload) else { continue }
                results.append((collection, leaf))
            }
        }
        return results
    }

    /// `Code` counterpart to `CrossFileModelCopier.graphicsCollection` , 
    /// same "only a fallback when a file genuinely has zero existing
    /// leaves of this type" reasoning.
    private static func codeCollection(_ type: SectionType, in fileRoot: ChunkNode) -> ChunkNode? {
        guard let code = fileRoot.children.first(where: { codeContainerTypes.contains($0.sectionType) }) else { return nil }
        return code.children.first { $0.sectionType == type }
    }

    private static func isGameObjectPayload(_ payload: ChunkPayload) -> Bool {
        if case .gameObject = payload { return true }
        return false
    }

    private static func isSkeletonPayload(_ payload: ChunkPayload) -> Bool {
        if case .skeleton = payload { return true }
        return false
    }

    /// Any `Script` record, both `MainScript` and `HeaderScript` content,
    /// since `resolvingSkinnedGameObjectInsertions`'s own script-copying
    /// block now resolves `HeaderScript` targets recursively by record ID
    /// rather than filtering them out (see that block's own doc comment).
    private static func isScriptPayload(_ payload: ChunkPayload) -> Bool {
        if case .script = payload { return true }
        return false
    }

    private static func isAnimationPayload(_ payload: ChunkPayload) -> Bool {
        if case .animation = payload { return true }
        return false
    }

    private static func isCustomAgentPayload(_ payload: ChunkPayload) -> Bool {
        if case .customAgent = payload { return true }
        return false
    }

    /// Every leaf anywhere under the Graphics container whose own
    /// structural `sectionType` is one of `types`, deliberately payload-
    /// independent (unlike `CrossFileModelCopier.graphicsLeaves`), since a
    /// Skin record is copied by raw bytes regardless of whether this
    /// build's own `SkinParser` could fully decode it (see this function's
    /// own call site's doc comment).
    private static func graphicsLeavesBySectionType(in fileRoot: ChunkNode, types: Set<SectionType>) -> [(collection: ChunkNode, leaf: ChunkNode)] {
        let containerTypes: Set<SectionType> = [.graphics, .graphicsX, .graphicsD]
        guard let graphics = fileRoot.children.first(where: { containerTypes.contains($0.sectionType) }) else { return [] }
        var results: [(collection: ChunkNode, leaf: ChunkNode)] = []
        for collection in graphics.children {
            for leaf in collection.children where types.contains(leaf.sectionType) {
                results.append((collection, leaf))
            }
        }
        return results
    }

    private static func isMaterialPayload(_ payload: ChunkPayload) -> Bool {
        if case .material = payload { return true }
        return false
    }

    private static func isTexturePayload(_ payload: ChunkPayload) -> Bool {
        if case .texture = payload { return true }
        return false
    }

    /// See this function's own call site above for the exact on-disk
    /// layout this walks (`SkinParser.parse`'s own read order).
    private static func skinMaterialIDOffsets(in skinBytes: Data) throws -> [(offset: Int, materialID: UInt32)] {
        var cursor = BinaryCursor(data: skinBytes)
        let subModelCount = try cursor.readUInt32()
        var results: [(offset: Int, materialID: UInt32)] = []
        results.reserveCapacity(Int(subModelCount))
        for _ in 0..<subModelCount {
            let materialIDOffset = cursor.position
            let materialID = try cursor.readUInt32()
            let codeSize = Int(try cursor.readInt32())
            _ = try cursor.readInt32() // declared vertex amount, decoded count is authoritative, not needed here
            _ = try cursor.readBytes(codeSize)
            results.append((materialIDOffset, materialID))
        }
        return results
    }
}
