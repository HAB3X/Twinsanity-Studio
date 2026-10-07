import Foundation
import CTParsers
import CTModels

/// A fully-loaded, already-decoded WoC level, ready to hand to a viewer.
/// Loading happens once, off the main actor (`WOCLevelLoader.load`); this
/// type is the plain data snapshot the UI/renderer read from afterward.
///
/// Deliberately thin: it exposes exactly what's actually decoded across
/// this level's `.GSC` (the RNC-compressed container) and its sibling
/// loose files (`.AI`/`.GRA`/`.PAD`/`.ANM`/`.TER`, all uncompressed, same
/// folder, same base filename) rather than a speculative "full level"
/// model. `objects` is real placement data (`INST`); there is no
/// per-object mesh geometry here yet -- see `WOCContainerParser`'s doc
/// comment for why (`OBJ0`'s per-entry boundaries are still unsolved as
/// of this type's introduction). Several categories (sound, cameras,
/// collision, skeletons) aren't represented here at all because they
/// haven't been reverse-engineered yet -- there is no placeholder/fake
/// data standing in for them.
public struct WOCLevelAsset: Identifiable {
    public let id: String
    public let name: String
    public let sourceURL: URL

    public let objectNames: [String]
    public let objects: [WOCObjectInstance]
    /// `OBJ0`'s own leading count -- the number of distinct objects this
    /// level's instances reference. Not necessarily `objects.map(\.objectIndex)`'s
    /// own max+1 in every file (some objects can go unplaced), but it's the
    /// authoritative "how many distinct objects exist" figure.
    public let distinctObjectCount: Int
    public let textures: [WOCDecodedTexture]
    public let sectionTags: [String]
    /// Real per-object mesh geometry, indexed exactly like `OBJ0` itself
    /// (`objects[i].objectIndex` looks up here) -- see `WOCMeshDecoder`'s
    /// doc comment for the confirmed byte layout this is built from
    /// (`WOCContainerParser.parseObjSet`'s exact entry/geo boundaries,
    /// verified on all 58 real files, zero exceptions -- this used to be
    /// a heuristic marker-walk with real gaps on `CASTLE_C.GSC`/
    /// `HUB.GSC`, solved this session). `WOCViewerRenderer` applies each
    /// instance's real, full rotation/scale/translation transform, not
    /// just position. Some geos within a real entry can still produce no
    /// triangles (a likely `dmastream`-shaped payload this codebase
    /// doesn't decode yet, not a bug) -- `WOCViewerRenderer` falls back
    /// to a position marker only for those, not for whole files anymore.
    public let objectMeshes: [MeshAsset]
    /// `MS00`'s own real per-material texture reference (relative offset
    /// 424, confirmed -- see `WOCContainerParser.parseMaterialSet`'s doc
    /// comment), indexed by `MeshSubmesh.materialID`. `objectMeshes`'
    /// submeshes carry a real `materialID` into this array; not yet used
    /// for actual texturing (that needs the still-unconfirmed per-vertex
    /// UV lead -- see `WOCContainerParser.parseObjSetGeoArcs`'s doc
    /// comment), but real and available for material-aware coloring/
    /// inspection today.
    public let materialTextureIDs: [Int]

    /// From the sibling `.AI` file, if present: real enemy/AI entity
    /// spawns with patrol waypoint paths. Fully decoded (see
    /// `WOCAIParser`).
    public let entities: [WOCAIParser.Entity]
    /// From the sibling `.GRA` file, if present: real foliage/grass
    /// scatter placements. Fully decoded (see `WOCGrassParser`).
    public let foliage: [WOCGrassParser.Placement]
    /// From the sibling `.ANM` file, if present AND it fits the confirmed
    /// simple-object-animation template -- real skeletal-animation files
    /// (a different, undecoded format) leave this empty rather than
    /// showing garbage; see `animationFileExistsButUnparsed`.
    public let animations: [WOCAnimationParser.Entry]
    /// `true` when a sibling `.ANM` file exists but didn't fit the
    /// confirmed simple-object-animation template (real skeletal files
    /// like `TOONARMY.ANM`) -- surfaced so the UI can say "present, not
    /// yet decoded" instead of just "none".
    public let animationFileExistsButUnparsed: Bool
    /// From the sibling `.PAD` file, if present: real decoded records --
    /// a confirmed continuously-sampled heading angle plus gated
    /// parameter bytes per record (see `WOCPadParser`'s doc comment for
    /// exactly what's confirmed; what actually consumes this data --
    /// AI patrol, a vehicle rail, a camera path -- is still unresolved).
    public let pathFile: WOCPadParser.File?
    /// From the sibling `.TER` file, if present: confirmed outer framing
    /// only. The bulk of real terrain/collision geometry (the "main
    /// block") is not decoded -- `terrainMainBlockByteCount` says how
    /// much real data is there without pretending to show its content.
    public let terrainMainBlockByteCount: Int?
    public let terrainTailRecordCount: Int?

    /// From the `.GSC`'s own `TAS0` section, if present: real texture
    /// indices this level uses, cross-confirmed against `textures` (every
    /// index is a valid index into that array in every real file
    /// checked). See `WOCContainerParser.parseTextureAssignments`'s doc
    /// comment for exactly what is and isn't confirmed about the
    /// per-entry-to-index mapping.
    public let textureAssignments: WOCContainerParser.TextureAssignmentSet?
    /// From the sibling `.PTL` file, if present AND it fits the
    /// confirmed fixed-839-byte "simple" record template: real particle
    /// effect definitions (name, lifetime, rotation range, max size --
    /// see `WOCParticleParser`'s doc comment for exactly which fields are
    /// confirmed). Complex variable-length `.PTL` files (a different,
    /// undecoded record shape) leave this empty; see
    /// `particleFileExistsButUnparsed`.
    public let particleEffects: [WOCParticleParser.ParticleRecord]
    public let particleFileExistsButUnparsed: Bool
    /// From the sibling `.CPT` file, if present AND it fits the same
    /// confirmed record template `.PTL` uses (no trailer, unlike
    /// `.PTL`'s 4-byte one -- see `WOCParticleParser`'s doc comment).
    public let checkpointEffects: [WOCParticleParser.ParticleRecord]
    public let checkpointFileExistsButUnparsed: Bool
    /// From the sibling `.OBJ` file, if present: real interactive object
    /// placements (levers, pistons, hammers, gates, ...). A resync scan
    /// recovers every declared object on the full real corpus checked
    /// (373/373 across 16 files) -- `interactiveObjects.count` can still
    /// fall short of `interactiveObjectDeclaredCount` on a truncated or
    /// corrupt file, an honest partial result rather than an error; see
    /// `WOCObjectParser`'s doc comment. Each object's own type-specific
    /// tail data (named actuator-state sub-blocks, effect references)
    /// isn't decoded at the field level yet -- exposed raw in
    /// `paramBlock`/skipped over, not guessed at.
    public let interactiveObjects: [WOCObjectParser.ObjectRecord]
    public let interactiveObjectDeclaredCount: Int
    /// From the sibling `.VIS` file, if present: real named cinematic
    /// camera path entry points (`weecam_*`) -- despite the `.VIS`
    /// extension, this is NOT a visibility system; see
    /// `WOCCameraPathParser`'s doc comment. The underlying node/path
    /// graph isn't decoded at the field level yet, only the real names.
    public let cameraPathNames: [String]

    public var textureCount: Int { textures.count }
}

/// One real, decoded texture (see `WOCTextureDecoder`) -- RGBA8888, raw
/// bytes rather than a platform image type, so this model stays usable
/// off the main actor; `WOCViewerWindow` builds the actual `CGImage` at
/// display time.
public struct WOCDecodedTexture: Identifiable {
    public let id: Int
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
    /// `true` for indexed (paletted) textures whose CLUT was found and
    /// applied; `false` for direct-color textures (no palette needed) or
    /// indexed textures whose CLUT search failed (`rgba` is empty in that
    /// failure case, not fabricated placeholder pixels).
    public let usedPalette: Bool
}

/// One placed object instance (`INST`), reduced to what a viewer needs:
/// world position and which distinct object it is. `WOCContainerParser.Instance`
/// carries the full 4x4 matrix and still-unresolved tail fields; a viewer
/// only needs the translation for a point-cloud/marker render.
public struct WOCObjectInstance: Identifiable {
    public typealias MatrixTuple = (Float, Float, Float, Float,
                                     Float, Float, Float, Float,
                                     Float, Float, Float, Float,
                                     Float, Float, Float, Float)

    public let id: Int
    public let objectIndex: UInt32
    public let worldPosition: SIMD3<Float>
    /// The instance's real, confirmed row-major 4x4 transform (see
    /// `WOCContainerParser.Instance.matrix`'s own doc comment --
    /// translation lives in row 3, `(tx, ty, tz, 1.0)`, same values as
    /// `worldPosition`). Carried through separately from `worldPosition`
    /// so renderers can apply the real rotation/scale instead of just
    /// translating.
    public let matrix: MatrixTuple
}

public enum WOCLevelLoader {
    /// Decompresses (when needed) and decodes every currently-understood
    /// section of a real `.GSC` file, plus every sibling loose file this
    /// codebase currently understands (looked up by swapping the
    /// extension on the same URL -- these are real, separate files on
    /// disk, not embedded in the `.GSC`). Synchronous and potentially
    /// slow (RNC decompression of a multi-megabyte file) -- callers
    /// should run this off the main actor.
    public static func load(gscURL: URL, name: String) throws -> WOCLevelAsset {
        let raw = try Data(contentsOf: gscURL)
        let bytes = [UInt8](raw)
        // A minority of real .GSC files (confirmed directly against real
        // disc bytes: `CORAL_C/CORAL.GSC`, `SNOW_B/SPACE_B.GSC`, and
        // others found in a disc-wide survey -- 6 of 60 real files) carry
        // no RNC compression at all: they're already a raw `NU20`
        // container. Decompress only when the RNC signature is actually
        // present; otherwise hand the raw bytes straight to
        // WOCContainerParser.parse, which throws its own `.badMagic` if
        // the file turns out not to be a real NU20 container either.
        let containerBytes = RNCDecompressor.isRNCStream(bytes) ? try RNCDecompressor.decompress(bytes, verifyCRC: true) : bytes
        let file = try WOCContainerParser.parse(containerBytes)

        var objectNames: [String] = []
        if let ntbl = file.sections.first(where: { $0.tag == "NTBL" }) {
            objectNames = (try? WOCContainerParser.parseNameTable(ntbl.payload))?.names ?? []
        }

        var objects: [WOCObjectInstance] = []
        if let inst = file.sections.first(where: { $0.tag == "INST" }) {
            let instances = (try? WOCContainerParser.parseInstances(inst.payload)) ?? []
            objects = instances.enumerated().map { index, instance in
                WOCObjectInstance(id: index, objectIndex: instance.objectIndex, worldPosition: instance.translation, matrix: instance.matrix)
            }
        }

        let materialRecords = file.sections.first(where: { $0.tag == "MS00" })
            .flatMap { try? WOCContainerParser.parseMaterialSet($0.payload) }?.records ?? []
        // relative offset 424 in each real 464-byte MS00 record -- see
        // parseMaterialSet's own doc comment for how this was confirmed.
        let materialTextureIDs: [Int] = materialRecords.map { record in
            let bytes = [UInt8](record)
            guard bytes.count >= 428 else { return -1 }
            let raw = UInt32(bytes[424]) | (UInt32(bytes[425]) << 8) | (UInt32(bytes[426]) << 16) | (UInt32(bytes[427]) << 24)
            return Int(Int32(bitPattern: raw))
        }

        var distinctObjectCount = 0
        var objectMeshes: [MeshAsset] = []
        if let obj0 = file.sections.first(where: { $0.tag == "OBJ0" }) {
            distinctObjectCount = (try? WOCContainerParser.leadingCount(obj0.payload)) ?? 0
            objectMeshes = WOCMeshDecoder.buildEntryMeshes(objectPayload: obj0.payload, materialCount: materialRecords.count) ?? []
        }

        var textures: [WOCDecodedTexture] = []
        if let tst0 = file.sections.first(where: { $0.tag == "TST0" }) {
            let entries = WOCContainerParser.scanTextureEntries(tst0.payload)
            for (index, entry) in entries.enumerated() {
                let texel = tst0.payload.subdata(in: entry.texelDataRange)
                if entry.bytesPerPixel == 4 {
                    let rgba = WOCTextureDecoder.decodeDirectColor(texel, width: entry.width, height: entry.height)
                    textures.append(WOCDecodedTexture(id: index, width: entry.width, height: entry.height, rgba: rgba, usedPalette: false))
                } else if let palette = WOCTextureDecoder.findPalette(precedingTrailerOffset: entry.trailerOffset, in: tst0.payload) {
                    let rgba = WOCTextureDecoder.decodeIndexed(texel, palette: palette, width: entry.width, height: entry.height)
                    textures.append(WOCDecodedTexture(id: index, width: entry.width, height: entry.height, rgba: rgba, usedPalette: true))
                } else {
                    // Real, honest failure case: an indexed texture whose
                    // CLUT couldn't be located -- no fabricated pixels.
                    textures.append(WOCDecodedTexture(id: index, width: entry.width, height: entry.height, rgba: [], usedPalette: false))
                }
            }
        }

        var textureAssignments: WOCContainerParser.TextureAssignmentSet?
        if let tas0 = file.sections.first(where: { $0.tag == "TAS0" }) {
            textureAssignments = try? WOCContainerParser.parseTextureAssignments(tas0.payload)
        }

        let baseURL = gscURL.deletingPathExtension()

        var entities: [WOCAIParser.Entity] = []
        if let aiData = try? Data(contentsOf: baseURL.appendingPathExtension("AI")) {
            entities = (try? WOCAIParser.parse(aiData)) ?? []
        }

        var foliage: [WOCGrassParser.Placement] = []
        if let graData = try? Data(contentsOf: baseURL.appendingPathExtension("GRA")) {
            foliage = (try? WOCGrassParser.parse(graData)) ?? []
        }

        var animations: [WOCAnimationParser.Entry] = []
        var animationFileExistsButUnparsed = false
        if let anmData = try? Data(contentsOf: baseURL.appendingPathExtension("ANM")) {
            if let parsed = try? WOCAnimationParser.parse(anmData) {
                animations = parsed
            } else {
                animationFileExistsButUnparsed = true
            }
        }

        var pathFile: WOCPadParser.File?
        if let padData = try? Data(contentsOf: baseURL.appendingPathExtension("PAD")) {
            pathFile = try? WOCPadParser.parse(padData)
        }

        var terrainMainBlockByteCount: Int?
        var terrainTailRecordCount: Int?
        if let terData = try? Data(contentsOf: baseURL.appendingPathExtension("TER")) {
            if let parsed = try? WOCTerrainParser.parse(terData) {
                terrainMainBlockByteCount = parsed.mainBlock.count
                terrainTailRecordCount = parsed.tailRecords.count
            }
        }

        var particleEffects: [WOCParticleParser.ParticleRecord] = []
        var particleFileExistsButUnparsed = false
        if let ptlData = try? Data(contentsOf: baseURL.appendingPathExtension("PTL")) {
            if let parsed = try? WOCParticleParser.parse(ptlData) {
                particleEffects = parsed.records
            } else {
                particleFileExistsButUnparsed = true
            }
        }

        var checkpointEffects: [WOCParticleParser.ParticleRecord] = []
        var checkpointFileExistsButUnparsed = false
        if let cptData = try? Data(contentsOf: baseURL.appendingPathExtension("CPT")) {
            if let parsed = try? WOCParticleParser.parse(cptData) {
                checkpointEffects = parsed.records
            } else {
                checkpointFileExistsButUnparsed = true
            }
        }

        var interactiveObjects: [WOCObjectParser.ObjectRecord] = []
        var interactiveObjectDeclaredCount = 0
        if let objData = try? Data(contentsOf: baseURL.appendingPathExtension("OBJ")) {
            if let parsed = try? WOCObjectParser.parseObjects(objData) {
                interactiveObjects = parsed.objects
                interactiveObjectDeclaredCount = parsed.declaredCount
            }
        }

        var cameraPathNames: [String] = []
        if let visData = try? Data(contentsOf: baseURL.appendingPathExtension("VIS")) {
            cameraPathNames = (try? WOCCameraPathParser.parse(visData))?.cameraPathNames ?? []
        }

        return WOCLevelAsset(
            id: gscURL.path,
            name: name,
            sourceURL: gscURL,
            objectNames: objectNames,
            objects: objects,
            distinctObjectCount: distinctObjectCount,
            textures: textures,
            sectionTags: file.sections.map(\.tag),
            objectMeshes: objectMeshes,
            materialTextureIDs: materialTextureIDs,
            entities: entities,
            foliage: foliage,
            animations: animations,
            animationFileExistsButUnparsed: animationFileExistsButUnparsed,
            pathFile: pathFile,
            terrainMainBlockByteCount: terrainMainBlockByteCount,
            terrainTailRecordCount: terrainTailRecordCount,
            textureAssignments: textureAssignments,
            particleEffects: particleEffects,
            particleFileExistsButUnparsed: particleFileExistsButUnparsed,
            checkpointEffects: checkpointEffects,
            checkpointFileExistsButUnparsed: checkpointFileExistsButUnparsed,
            interactiveObjects: interactiveObjects,
            interactiveObjectDeclaredCount: interactiveObjectDeclaredCount,
            cameraPathNames: cameraPathNames
        )
    }
}
