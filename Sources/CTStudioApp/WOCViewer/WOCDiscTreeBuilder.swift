import Foundation
import simd
import CTModels
import CTParsers

/// Converts an already-loaded `WOCLevelAsset` (or, for the sound archive,
/// a `WOCSoundParser.Entry` table) into a real `ChunkNode` tree -- the
/// same `ChunkNode`/`ChunkPayload` types the original Twinsanity sidebar
/// tree (`CRASH.BH`, etc.) already uses, so a WoC file mounted from a
/// disc image browses with the same structure: expandable folders, real
/// per-record leaves, and the existing payload-specific inspector/preview
/// views (`TextureInspectorView`, `PositionInspectorView`,
/// `SoundEffectInspectorView`) for free.
///
/// Deliberately reuses existing `ChunkPayload` cases only where the value
/// genuinely fits that case's own contract -- `.texture` for real decoded
/// RGBA pixels, `.soundEffect` for real decoded PCM, `.position` for a
/// real, bare 3D point -- rather than stuffing WoC-specific data (like an
/// `INST` record's `objectIndex`, which has no Twinsanity `Instance`
/// equivalent) into a Twinsanity-shaped payload it doesn't actually
/// match. Where no existing payload type fits honestly, records surface
/// as `.raw` leaves instead (still real, still hex-previewable, just not
/// pretending to a richer decode that hasn't happened) -- e.g. `.ANM`
/// entries, `.PAD` records, and `.TER`'s still-opaque main block.
enum WOCDiscTreeBuilder {
    /// Builds the replacement node for a mounted `.GSC` level file once
    /// clicked -- see `WorkspaceViewModel.expandWOCLevelEntry`, which
    /// extracts the real `.GSC` bytes (and any real sibling `.AI`/`.GRA`/
    /// `.ANM`/`.PAD`/`.TER` bytes found in the same disc directory) and
    /// calls this. Writes those bytes to a real temp directory and runs
    /// them through the exact same `WOCLevelLoader.load` pipeline
    /// `WOCWorkspace` already uses for a real mounted folder -- no
    /// separate ISO-aware parsing logic to keep in sync.
    /// Returns both the browsable `ChunkNode` tree and the `WOCLevelAsset`
    /// it was built from -- callers that only need the tree can ignore the
    /// second value, but `WorkspaceViewModel` keeps it (keyed by the
    /// returned node's own `id`) so `WOCCompositeResolver` has the real
    /// `objectMeshes`/`materialTextureIDs` reference chain to search later,
    /// which nothing about the `ChunkNode` tree alone carries.
    static func buildLevelNode(
        recordID: UInt32,
        displayName: String,
        byteSize: Int,
        fileOffset: Int,
        gscData: Data,
        siblingData: [String: Data],
        levelName: String
    ) throws -> (node: ChunkNode, asset: WOCLevelAsset) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let base = tempDir.appendingPathComponent(levelName)
        let gscURL = base.appendingPathExtension("GSC")
        try gscData.write(to: gscURL)
        for (ext, data) in siblingData {
            try data.write(to: base.appendingPathExtension(ext))
        }
        let asset = try WOCLevelLoader.load(gscURL: gscURL, name: levelName)
        let builtNode = node(from: asset, recordID: recordID, displayName: displayName, byteSize: byteSize, fileOffset: fileOffset)
        return (builtNode, asset)
    }

    private static func node(from asset: WOCLevelAsset, recordID: UInt32, displayName: String, byteSize: Int, fileOffset: Int) -> ChunkNode {
        var children: [ChunkNode] = []

        if !asset.objects.isEmpty {
            let objectChildren = asset.objects.map { object -> ChunkNode in
                ChunkNode(
                    recordID: UInt32(object.id), sectionType: .null,
                    displayName: "Object #\(object.objectIndex)", byteSize: 16, fileOffset: 0,
                    payload: .position(PositionMarker(id: UInt32(object.id), point: point(object.worldPosition)))
                )
            }
            children.append(folder("Placed Objects (\(objectChildren.count))", objectChildren))
        }

        if !asset.textures.isEmpty {
            let textureChildren = asset.textures.map { texture -> ChunkNode in
                let label = "Texture \(texture.width)x\(texture.height)\(texture.usedPalette ? " (indexed)" : "")"
                let payload: ChunkPayload = texture.rgba.isEmpty
                    ? .raw(byteCount: 0)
                    : .texture(TextureAsset(id: UInt32(texture.id), width: texture.width, height: texture.height, pixelFormat: .rawRGBA, rgba: texture.rgba))
                return ChunkNode(recordID: UInt32(texture.id), sectionType: .null, displayName: label, byteSize: texture.rgba.count, fileOffset: 0, payload: payload)
            }
            children.append(folder("Textures (\(textureChildren.count))", textureChildren))
        }

        if !asset.entities.isEmpty {
            let entityChildren = asset.entities.enumerated().map { index, entity -> ChunkNode in
                let waypointChildren = entity.waypoints.enumerated().map { waypointIndex, waypoint -> ChunkNode in
                    ChunkNode(
                        recordID: UInt32(waypointIndex), sectionType: .null,
                        displayName: "Waypoint \(waypointIndex)", byteSize: 12, fileOffset: 0,
                        payload: .position(PositionMarker(id: UInt32(waypointIndex), point: point(waypoint)))
                    )
                }
                return ChunkNode(recordID: UInt32(index), sectionType: .null, displayName: entity.name, byteSize: 0, fileOffset: 0, children: waypointChildren)
            }
            children.append(folder("AI / Entities (\(entityChildren.count))", entityChildren))
        }

        if !asset.foliage.isEmpty {
            let foliageChildren = asset.foliage.enumerated().map { index, placement -> ChunkNode in
                ChunkNode(
                    recordID: UInt32(index), sectionType: .null,
                    displayName: "\(placement.name) (value: \(placement.value))", byteSize: 0, fileOffset: 0,
                    payload: .position(PositionMarker(id: UInt32(index), point: point(placement.position)))
                )
            }
            children.append(folder("Scenery / Foliage (\(foliageChildren.count))", foliageChildren))
        }

        if asset.animationFileExistsButUnparsed {
            children.append(ChunkNode(
                recordID: 0, sectionType: .null,
                displayName: "Animations (present, skeletal format not yet decoded)", byteSize: 0, fileOffset: 0,
                payload: .raw(byteCount: 0)
            ))
        } else if !asset.animations.isEmpty {
            let animationChildren = asset.animations.enumerated().map { index, entry -> ChunkNode in
                ChunkNode(
                    recordID: UInt32(index), sectionType: .null,
                    displayName: "\(entry.name) (flag \(entry.flag), \(entry.subEntries.count) sub-entries)", byteSize: 0, fileOffset: 0,
                    payload: .raw(byteCount: 0)
                )
            }
            children.append(folder("Animations (\(animationChildren.count))", animationChildren))
        }

        if let pathFile = asset.pathFile {
            children.append(ChunkNode(
                recordID: 0, sectionType: .null,
                displayName: "Paths (\(pathFile.records.count) records, heading angle + parameter bytes decoded)", byteSize: 0, fileOffset: 0,
                payload: .raw(byteCount: 0)
            ))
        }

        if let mainBlockByteCount = asset.terrainMainBlockByteCount, let tailRecordCount = asset.terrainTailRecordCount {
            children.append(ChunkNode(
                recordID: 0, sectionType: .null,
                displayName: "Terrain (\(mainBlockByteCount) opaque bytes, \(tailRecordCount) tail records)",
                byteSize: mainBlockByteCount, fileOffset: 0,
                payload: .raw(byteCount: mainBlockByteCount)
            ))
        }

        return ChunkNode(recordID: recordID, sectionType: .null, displayName: displayName, byteSize: byteSize, fileOffset: fileOffset, children: children)
    }

    private static func folder(_ name: String, _ children: [ChunkNode]) -> ChunkNode {
        ChunkNode(recordID: 0, sectionType: .null, displayName: name, byteSize: 0, fileOffset: 0, children: children)
    }

    private static func point(_ v: SIMD3<Float>) -> SIMD4<Float> {
        SIMD4(v.x, v.y, v.z, 1)
    }
}
