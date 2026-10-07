import Foundation
import CTCore
import CTModels

/// Builds the full chunk tree for an `.RM2`/`.SM2` (and their Xbox/Demo
/// variants) file, ported from `Twinsanity/TwinsFile.cs` +
/// `Twinsanity/TwinsSection.cs`.
///
/// The format is a uniform 3-tier chunk structure once you separate it from
/// the original's positional-offset bookkeeping (see `ChunkHeader`'s doc
/// comment for why `indexStartPosition + entry.offset` works identically at
/// every tier, top level included):
///
/// - **Tier 0** (the file itself): dispatches each top-level index entry's ID
///   to either a Tier 1 container section (`Instance`/`Code`/`Graphics` and
///   their Demo/Xbox variants) or a handful of raw leaf record kinds
///   (`ParticleData`, `ColData`, `SceneryData`, `DynamicSceneryData`,
///   `ChunkLinks`) that are *not* chunk-headered at all.
/// - **Tier 1** (a container section): its own index entries each name a
///   *new* Tier 2 collection section (e.g. `Graphics` sub-ID 0 -> a `Texture`
///   collection section), chosen by sub-ID and by whether the enclosing file
///   is PS2/Xbox/Demo.
/// - **Tier 2** (a collection section, e.g. `Texture`, `Model`, `Animation`):
///   every one of its index entries is a leaf record of that section's own
///   kind, sub-ID here is just that record's own ID within the collection,
///   not a further type dispatch.
public enum RM2Parser {
    public enum ParseError: Error, CustomStringConvertible {
        case unsupportedFileType
        public var description: String { "Unsupported or undetected RM2/SM2 file type." }
    }

    public static func parse(data: Data, fileKind: TwinsFileKind, fileName: String) throws -> ChunkNode {
        let root = ChunkNode(recordID: 0, sectionType: .null, displayName: fileName, byteSize: data.count, fileOffset: 0)
        var cursor = BinaryCursor(data: data)
        let header = try ChunkHeaderReader.readHeader(from: &cursor)

        for entry in header.entries {
            let absoluteOffset = header.indexStartPosition + Int(entry.offset)
            // Real, reported bug ("place an object via the Forge Palette,
            // Quick Launch, it never appears"): this used to silently
            // `continue`, dropping the entry from `root.children`
            // entirely, whenever `buildTopLevelNode` failed to parse it.
            // `ChunkSectionInserter` explicitly relies on every section's
            // `children` array corresponding 1:1, in order, with its own
            // on-disk index table (`header.entries`), a dropped entry
            // breaks that invariant for this file's *entire* remaining
            // lifetime, silently corrupting any later structural insert/
            // remove that has to walk back up through this node as an
            // ancestor (each of *its* siblings' rebuilt index entries
            // shifts by one, misattributing offsets/sizes/ids to the wrong
            // neighbor) even though the insertion itself reports success.
            // Every *other* failure path in this parser (`buildSectionNode`
            // itself, `decodeTopLevelRawLeaf`) already falls back to a
            // `.raw` placeholder rather than dropping the entry, this
            // matches that same, already-established pattern instead of
            // being the one silent exception to it.
            let node = (try? buildTopLevelNode(data: data, entry: entry, absoluteOffset: absoluteOffset, fileKind: fileKind))
                ?? ChunkNode(recordID: entry.id, sectionType: .null, displayName: "Unknown #\(entry.id)", byteSize: max(0, Int(entry.size)), fileOffset: absoluteOffset, payload: .raw(byteCount: max(0, Int(entry.size))))
            root.children.append(node)
        }
        return root
    }

    // MARK: - Tier 0

    private enum Tier0Kind {
        case section(SectionType)
        case rawLeaf(String)
    }

    private static func tier0Kind(fileKind: TwinsFileKind, subID: UInt32) -> Tier0Kind {
        switch fileKind {
        case .rm2, .rm2Demo, .rmx, .rm2MB:
            switch subID {
            case 0...7:
                switch fileKind {
                case .rm2Demo: return .section(.instanceDemo)
                case .rm2MB: return .section(.instanceMB)
                default: return .section(.instance)
                }
            case 8: return .rawLeaf("ParticleData")
            case 9: return .rawLeaf("ColData")
            case 10:
                switch fileKind {
                case .rm2Demo: return .section(.codeDemo)
                case .rmx: return .section(.codeX)
                case .rm2MB: return .section(.codeMB)
                default: return .section(.code)
                }
            case 11:
                switch fileKind {
                case .rmx: return .section(.graphicsX)
                case .rm2Demo: return .section(.graphicsD)
                case .rm2MB: return .section(.graphicsMB)
                default: return .section(.graphics)
                }
            default: return .rawLeaf("Unknown")
            }
        case .sm2, .sm2Demo, .smx, .sm2MB:
            switch subID {
            case 6:
                switch fileKind {
                case .smx: return .section(.graphicsX)
                case .sm2Demo: return .section(.graphicsD)
                case .sm2MB: return .section(.graphicsMB)
                default: return .section(.graphics)
                }
            case 5: return .rawLeaf("ChunkLinks")
            // `SceneryData`'s real Monkey Ball byte layout isn't in this
            // project's reference material, routed through the same raw
            // leaf as retail/Demo/Xbox rather than guessing a distinct
            // format `SectionType.sceneryMB` might imply. `sceneryMB`
            // stays reachable for future work but unused here.
            case 0: return .rawLeaf("SceneryData")
            case 4: return .rawLeaf("DynamicSceneryData")
            default: return .rawLeaf("Unknown")
            }
        }
    }

    private static func buildTopLevelNode(data: Data, entry: ChunkIndexEntry, absoluteOffset: Int, fileKind: TwinsFileKind) throws -> ChunkNode {
        switch tier0Kind(fileKind: fileKind, subID: entry.id) {
        case .section(let sectionType):
            return try buildSectionNode(data: data, sectionType: sectionType, absoluteOffset: absoluteOffset, size: Int(entry.size), recordID: entry.id, level: 1, fileKind: fileKind)
        case .rawLeaf(let name):
            let byteSize = max(0, Int(entry.size))
            let displayName = "\(name) #\(entry.id)"
            let payload = decodeTopLevelRawLeaf(name: name, data: data, absoluteOffset: absoluteOffset, byteSize: byteSize, recordID: entry.id)
                ?? .raw(byteCount: byteSize)
            return ChunkNode(
                recordID: entry.id, sectionType: .null, displayName: displayName,
                byteSize: byteSize, fileOffset: absoluteOffset, payload: payload
            )
        }
    }

    /// A handful of top-level (tier 0) "raw leaf" entries (see
    /// `tier0Kind`) aren't actually opaque, `ColData`, `SceneryData`, and
    /// `DynamicSceneryData` each have a fully-specified format of their
    /// own, just not one that fits the chunk-headered section machinery
    /// every other record goes through. `nil` (falling back to `.raw`)
    /// covers both "this name isn't one of those" and "decoding failed."
    private static func decodeTopLevelRawLeaf(name: String, data: Data, absoluteOffset: Int, byteSize: Int, recordID: UInt32) -> ChunkPayload? {
        guard absoluteOffset >= 0, absoluteOffset + byteSize <= data.count else { return nil }
        // Performance fix (audit): `data[range]` (COW slice, shares the
        // parent buffer's storage) instead of `data.subdata(in:)` (hard
        // copy), the whole app opens files with `.mappedIfSafe`
        // specifically so the OS keeps them memory-mapped rather than
        // resident, and `subdata` was defeating that at every single node
        // of the tree. Safe here specifically because `leafData` only
        // feeds a transient `BinaryCursor` consumed and discarded before
        // this function returns, nothing here escapes into a long-lived
        // payload (contrast `extractSectionExtraData` below, which
        // deliberately keeps `subdata`'s real copy for exactly that reason).
        let leafData = data[(data.startIndex + absoluteOffset)..<(data.startIndex + absoluteOffset + byteSize)]
        var cursor = BinaryCursor(data: leafData)
        switch name {
        case "ColData":
            return (try? ColDataParser.parse(&cursor, recordID: recordID, size: byteSize)).map(ChunkPayload.collision)
        case "SceneryData":
            return (try? SceneryDataParser.parse(&cursor, recordID: recordID)).map(ChunkPayload.scenery)
        case "DynamicSceneryData":
            return (try? DynamicSceneryDataParser.parse(&cursor, recordID: recordID)).map(ChunkPayload.dynamicScenery)
        case "ChunkLinks":
            return (try? ChunkLinksParser.parse(&cursor, recordID: recordID)).map(ChunkPayload.chunkLinks)
        case "ParticleData":
            return (try? ParticleDataParser.parse(&cursor, recordID: recordID, size: byteSize)).map(ChunkPayload.particleData)
        default:
            return nil
        }
    }

    // MARK: - Tier 1 (containers) / Tier 2 (collections)

    private static let containerTypes: Set<SectionType> = [.graphics, .graphicsX, .graphicsD, .graphicsMB, .instance, .instanceDemo, .instanceMB, .code, .codeX, .codeDemo, .codeMB]

    private static func tier1ChildType(parent: SectionType, subID: UInt32) -> SectionType? {
        switch parent {
        case .graphics, .graphicsX, .graphicsD, .graphicsMB:
            switch subID {
            case 0: return parent == .graphicsX ? .textureX : .texture
            case 1: return parent == .graphicsD ? .materialD : .material
            case 2: return parent == .graphicsX ? .modelX : .model
            case 3: return .rigidModel
            case 4: return parent == .graphicsX ? .skinX : .skin
            case 5: return parent == .graphicsX ? .blendSkinX : .blendSkin
            case 6: return .mesh
            // No distinct `.lodModelMB` byte layout is confirmed against
            // real Monkey Ball data yet, but the `SectionType` already
            // exists, tagging it here at least keeps it distinguishable
            // in the tree instead of silently reading as plain `.lodModel`.
            case 7: return parent == .graphicsMB ? .lodModelMB : .lodModel
            case 8: return .skydome
            default: return nil
            }
        case .instance, .instanceDemo, .instanceMB:
            switch subID {
            case 0:
                switch parent {
                case .instanceDemo: return .instanceTemplateDemo
                case .instanceMB: return .instanceTemplateMB
                default: return .instanceTemplate
                }
            case 1: return .aiPosition
            case 2: return .aiPath
            case 3: return .position
            case 4: return .path
            case 5: return .collisionSurface
            case 6:
                switch parent {
                case .instanceDemo: return .objectInstanceDemo
                case .instanceMB: return .objectInstanceMB
                default: return .objectInstance
                }
            case 7: return .trigger
            // No confirmed `CameraMB` variant exists in this project's
            // reference material, retail `Camera`'s layout is the least-
            // wrong default (matches `agentLabPlatform`'s own MB->PS2 fallback).
            case 8: return parent == .instanceDemo ? .cameraDemo : .camera
            default: return nil
            }
        case .code, .codeX, .codeDemo, .codeMB:
            switch subID {
            case 0:
                switch parent {
                case .codeDemo: return .objectDemo
                case .codeMB: return .objectMB
                default: return .object
                }
            case 1:
                switch parent {
                case .codeX: return .scriptX
                case .codeDemo: return .scriptDemo
                case .codeMB: return .scriptMB
                default: return .script
                }
            case 2: return .animation
            case 3:
                // `.ogi` (retail/Demo/MB all share `GraphicsInfo.cs`'s own
                // structural layout per the reference's `GameObject.Load`
                // platform check, only Xbox diverges) still routes
                // through `.ogi`'s own decoder; `.graphicsInfoMB` is left
                // reachable for a future MB-specific reader, not wired to
                // one yet since none of this project's reference material
                // shows it actually differs from `.ogi`.
                return .ogi
            case 4: return parent == .codeX ? .customAgentX : (parent == .codeDemo ? .customAgentDemo : .customAgent)
            case 6:
                switch parent {
                case .codeX: return .xboxSE
                case .codeMB: return .mbSE
                default: return .se
                }
            case 7: return parent == .codeX ? .xboxSEEng : .seEng
            case 8: return parent == .codeX ? .xboxSEFre : .seFre
            case 9: return parent == .codeX ? .xboxSEGer : .seGer
            case 10: return parent == .codeX ? .xboxSESpa : .seSpa
            case 11: return parent == .codeX ? .xboxSEIta : .seIta
            case 12: return parent == .codeX ? .xboxSEJpn : .seJpn
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Builds a node for a chunk-headered section at `absoluteOffset` (either
    /// a Tier 1 container or a Tier 2 collection, both look identical
    /// structurally; only what we *do* with their children differs).
    private static func buildSectionNode(data: Data, sectionType: SectionType, absoluteOffset: Int, size: Int, recordID: UInt32, level: Int, fileKind: TwinsFileKind) throws -> ChunkNode {
        guard size >= 12, absoluteOffset >= 0, absoluteOffset + size <= data.count else {
            return ChunkNode(recordID: recordID, sectionType: sectionType, displayName: "\(sectionType.rawValue) #\(recordID)", byteSize: max(0, size), fileOffset: absoluteOffset, payload: .raw(byteCount: max(0, size)))
        }
        // Same fix, same transient-only safety reasoning as
        // `decodeTopLevelRawLeaf` above.
        let sectionData = data[(data.startIndex + absoluteOffset)..<(data.startIndex + absoluteOffset + size)]
        var sectionCursor = BinaryCursor(data: sectionData)

        guard let header = try? ChunkHeaderReader.readHeader(from: &sectionCursor) else {
            return ChunkNode(recordID: recordID, sectionType: sectionType, displayName: "\(sectionType.rawValue) #\(recordID)", byteSize: size, fileOffset: absoluteOffset, payload: .raw(byteCount: size))
        }

        let node = ChunkNode(recordID: recordID, sectionType: sectionType, displayName: "\(sectionType.rawValue) #\(recordID)", byteSize: size, fileOffset: absoluteOffset)

        // `SoundEffect` records under a `.se`-family collection store their
        // actual audio bytes not in their own record, but in this
        // *enclosing section's* trailing "extra data", everything past
        // the last indexed sub-item (ported from `TwinsSection.Load`'s own
        // `extra_begin`/`ExtraData` handling). Computed once per section,
        // not per record.
        let soundExtraData: (data: Data, absoluteStart: Int)? = soundEffectSectionTypes.contains(sectionType)
            ? extractSectionExtraData(data: data, header: header, absoluteOffset: absoluteOffset, size: size)
            : nil

        for entry in header.entries {
            let childLocalOffset = header.indexStartPosition + Int(entry.offset)
            let childAbsoluteOffset = absoluteOffset + childLocalOffset
            let childSize = max(0, Int(entry.size))

            if containerTypes.contains(sectionType), let childType = tier1ChildType(parent: sectionType, subID: entry.id) {
                // Same real, reported bug as `RM2Parser.parse`'s own fix
                // just above (see that one's doc comment for the exact
                // corruption this caused), a recognized child type whose
                // own `buildSectionNode` call throws used to be silently
                // dropped instead of appended, breaking `node.children`'s
                // 1:1 correspondence with `header.entries` for *this*
                // container too. Falls back to the same `.raw`/`.unknown`
                // placeholder the sibling "unrecognized sub-ID" branch just
                // below already uses, instead of being the one path that
                // drops the entry outright.
                let childNode = (try? buildSectionNode(data: data, sectionType: childType, absoluteOffset: childAbsoluteOffset, size: childSize, recordID: entry.id, level: level + 1, fileKind: fileKind))
                    ?? ChunkNode(recordID: entry.id, sectionType: .unknown, displayName: "Unknown #\(entry.id)", byteSize: childSize, fileOffset: childAbsoluteOffset, payload: .raw(byteCount: childSize))
                node.children.append(childNode)
            } else if containerTypes.contains(sectionType) {
                // Sub-ID didn't match a known child type under this container:
                // keep it browsable as a raw leaf rather than dropping it.
                node.children.append(ChunkNode(recordID: entry.id, sectionType: .unknown, displayName: "Unknown #\(entry.id)", byteSize: childSize, fileOffset: childAbsoluteOffset, payload: .raw(byteCount: childSize)))
            } else if let soundExtraData {
                node.children.append(buildSoundEffectLeafNode(data: data, extraData: soundExtraData.data, extraDataAbsoluteFileOffset: soundExtraData.absoluteStart, sectionType: sectionType, absoluteOffset: childAbsoluteOffset, size: childSize, recordID: entry.id))
            } else {
                // Tier 2 collection: every child is a leaf record of `sectionType`.
                node.children.append(buildLeafNode(data: data, sectionType: sectionType, absoluteOffset: childAbsoluteOffset, size: childSize, recordID: entry.id, fileKind: fileKind))
            }
        }
        return node
    }

    /// PS2 `.se`-family sound-bank sections only, `.xboxSE*`/`.mbSE` use a
    /// different, unverified record layout (`SoundEffectX.cs`/
    /// `SoundEffectMB.cs` in the reference tool), so they're deliberately
    /// left undecoded rather than guessed at.
    /// `.xboxSE` is deliberately excluded, its real bytes are embedded
    /// directly in each record (see `SoundEffectXParser`), not indexed
    /// into this shared "extra data" scheme the way every PS2 (retail and
    /// `.mbSE`) `SoundEffect` variant is.
    private static let soundEffectSectionTypes: Set<SectionType> = [.se, .seEng, .seFre, .seGer, .seSpa, .seIta, .seJpn, .mbSE]

    /// Ported from `TwinsSection.Load`'s `extra_begin`/`ExtraData`
    /// computation: the section's bytes from just past the furthest
    /// (offset + size) of any indexed sub-item, to the section's own end.
    /// Returns the blob's own absolute file offset alongside its bytes , 
    /// `buildSoundEffectLeafNode` needs that to give each `SoundEffect`'s
    /// resolved asset a real, absolute, patchable file location for its
    /// audio bytes (see `SoundEffectAsset.sourceAudioByteRange`), not just
    /// the in-memory `Data` this used to hand back alone.
    private static func extractSectionExtraData(data: Data, header: ChunkHeader, absoluteOffset: Int, size: Int) -> (data: Data, absoluteStart: Int)? {
        let extraBeginLocal = max(12, header.entries.map { Int($0.offset) + max(0, Int($0.size)) }.max() ?? 12)
        let start = absoluteOffset + extraBeginLocal
        let length = size - extraBeginLocal
        guard length > 0, start >= 0, start + length <= data.count else { return nil }
        // Deliberately still `subdata(in:)` (a real, independent copy), NOT
        // the COW-slice fix applied elsewhere in this file: this blob is
        // embedded directly into the long-lived `SoundEffectAsset` payload
        // (see this function's own doc comment), a `ChunkNode` payload
        // that survives for the whole session. A slice here would keep the
        // *entire* parent file's buffer resident for as long as any one
        // decoded sound effect is retained, which could be worse than the
        // cost this fix is meant to remove, especially for a heap-extracted
        // (non-memory-mapped) archive entry. Copying just this one sound's
        // own bytes, once, is the correct tradeoff for something retained
        // this long, unlike every other `subdata` call in this file,
        // which only ever fed a transient, immediately-discarded cursor.
        return (data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + length)), start)
    }

    private static func buildSoundEffectLeafNode(data: Data, extraData: Data, extraDataAbsoluteFileOffset: Int, sectionType: SectionType, absoluteOffset: Int, size: Int, recordID: UInt32) -> ChunkNode {
        let displayName = "\(sectionType.rawValue) #\(recordID)"
        guard absoluteOffset >= 0, size >= 0, absoluteOffset + size <= data.count else {
            return ChunkNode(recordID: recordID, sectionType: sectionType, displayName: displayName, byteSize: max(0, size), fileOffset: absoluteOffset, payload: .raw(byteCount: max(0, size)))
        }
        // Same transient-only fix as `decodeTopLevelRawLeaf`, this cursor
        // is consumed below and discarded; only `extraData` (already a
        // real copy, passed in from `extractSectionExtraData`) survives.
        let leafData = data[(data.startIndex + absoluteOffset)..<(data.startIndex + absoluteOffset + size)]
        var cursor = BinaryCursor(data: leafData)
        // `.mbSE`'s real header is 16 bytes (`SoundEffectMB.cs`), not
        // retail's 22, a distinct parse, same shared extra-data resolve.
        let asset: SoundEffectAsset?
        if sectionType == .mbSE {
            asset = (try? SoundEffectParser.parseHeaderMB(&cursor, recordID: recordID))
                .flatMap { SoundEffectParser.resolveMB($0, extraData: extraData, extraDataAbsoluteFileOffset: extraDataAbsoluteFileOffset) }
        } else {
            asset = (try? SoundEffectParser.parseHeader(&cursor, recordID: recordID))
                .flatMap { SoundEffectParser.resolve($0, extraData: extraData, extraDataAbsoluteFileOffset: extraDataAbsoluteFileOffset) }
        }
        guard let asset else {
            return ChunkNode(recordID: recordID, sectionType: sectionType, displayName: displayName, byteSize: size, fileOffset: absoluteOffset, payload: .raw(byteCount: size))
        }
        return ChunkNode(recordID: recordID, sectionType: sectionType, displayName: displayName, byteSize: size, fileOffset: absoluteOffset, payload: .soundEffect(asset))
    }

    // MARK: - Tier 2 leaves

    private static func buildLeafNode(data: Data, sectionType: SectionType, absoluteOffset: Int, size: Int, recordID: UInt32, fileKind: TwinsFileKind) -> ChunkNode {
        let displayName = "\(sectionType.rawValue) #\(recordID)"
        guard absoluteOffset >= 0, size >= 0, absoluteOffset + size <= data.count else {
            return ChunkNode(recordID: recordID, sectionType: sectionType, displayName: displayName, byteSize: max(0, size), fileOffset: absoluteOffset, payload: .raw(byteCount: max(0, size)))
        }
        // Same transient-only fix, `decodeLeafPayload` below always
        // materializes fully-decoded value types (arrays of parsed floats/
        // bytes) into `payload`, never a live reference back into
        // `leafData` itself, so nothing here escapes this function retaining
        // a slice of the parent buffer.
        let leafData = data[(data.startIndex + absoluteOffset)..<(data.startIndex + absoluteOffset + size)]
        var cursor = BinaryCursor(data: leafData)
        let payload = decodeLeafPayload(sectionType: sectionType, cursor: &cursor, size: size, recordID: recordID, fileKind: fileKind)
        return ChunkNode(recordID: recordID, sectionType: sectionType, displayName: displayName, byteSize: size, fileOffset: absoluteOffset, payload: payload)
    }

    /// PS2/Xbox/Demo, derived once per file from `fileKind` -- `GameObject`
    /// records carry no platform tag of their own on disk (there's no
    /// `.objectX` `SectionType`, only `.object`/`.objectDemo`), so this is
    /// the Swift equivalent of the reference `GameObject.Load`'s own
    /// `ParentType == SectionType.ScriptX`/`ScriptDemo` check -- a single
    /// file is always one platform variant throughout, so checking the
    /// file-wide kind is equivalent to (and simpler than) re-deriving a
    /// per-record parent-section check.
    private static func agentLabPlatform(for fileKind: TwinsFileKind) -> AgentLabPlatformVariant {
        switch fileKind {
        case .rmx, .smx: return .xbox
        case .rm2Demo, .sm2Demo: return .demo
        // Matches the reference `GameObject.Load`'s own real platform
        // check, which only branches on Xbox/Demo, Monkey Ball is PS2
        // hardware and gets no separate branch there, so PS2 is its real
        // layout too, not a guess.
        case .rm2, .sm2, .rm2MB, .sm2MB: return .ps2
        }
    }

    /// Decodes a leaf record's payload where this package understands the
    /// format, and falls back to a raw/undecoded payload everywhere else , 
    /// including formats this package deliberately does not attempt (Xbox
    /// `Model`/`Skin` use a different, non-VIF vertex encoding; `BlendSkin`
    /// morph-target blobs).
    private static func decodeLeafPayload(sectionType: SectionType, cursor: inout BinaryCursor, size: Int, recordID: UInt32, fileKind: TwinsFileKind) -> ChunkPayload {
        do {
            switch sectionType {
            case .texture:
                return .texture(try TextureParser.parse(&cursor, recordID: recordID))
            case .textureX:
                return .texture(try TextureXParser.parse(&cursor, recordID: recordID))
            case .model:
                return .mesh(try ModelParser.parse(&cursor, recordID: recordID))
            case .skin:
                return .mesh(try SkinParser.parse(&cursor, recordID: recordID))
            case .rigidModel, .mesh:
                return .rigidModel(try RigidModelParser.parse(&cursor, recordID: recordID))
            case .material:
                let isMB = fileKind == .rm2MB || fileKind == .sm2MB
                return .material(try MaterialParser.parse(&cursor, recordID: recordID, isMonkeyBall: isMB))
            case .materialD:
                return .material(try MaterialParser.parse(&cursor, recordID: recordID, isDemo: true))
            case .ogi:
                return .skeleton(try GraphicsInfoParser.parse(&cursor, recordID: recordID))
            case .object, .objectDemo:
                return .gameObject(try GameObjectParser.parse(&cursor, recordID: recordID, platform: agentLabPlatform(for: fileKind)))
            case .animation:
                return .animation(try AnimationParser.parse(&cursor, recordID: recordID))
            case .position:
                return .position(try WorldPlacementParser.parsePosition(&cursor, recordID: recordID))
            case .objectInstance:
                return .instance(try WorldPlacementParser.parseInstance(&cursor, recordID: recordID))
            case .objectInstanceDemo:
                return .instanceDemo(try WorldPlacementParser.parseInstanceDemo(&cursor, recordID: recordID))
            case .objectInstanceMB:
                return .instanceMB(try WorldPlacementParser.parseInstanceMB(&cursor, recordID: recordID, size: size))
            case .instanceTemplate:
                return .instanceTemplate(try WorldPlacementParser.parseInstanceTemplate(&cursor, recordID: recordID))
            case .instanceTemplateDemo:
                return .instanceTemplateDemo(try WorldPlacementParser.parseInstanceTemplateDemo(&cursor, recordID: recordID))
            case .trigger:
                return .trigger(try WorldPlacementParser.parseTrigger(&cursor, recordID: recordID))
            case .camera:
                return .camera(try WorldPlacementParser.parseCamera(&cursor, recordID: recordID, isDemo: false))
            case .cameraDemo:
                return .camera(try WorldPlacementParser.parseCamera(&cursor, recordID: recordID, isDemo: true))
            case .aiPosition:
                return .aiPosition(try AINavigationParser.parseAIPosition(&cursor, recordID: recordID))
            case .aiPath:
                return .aiPath(try AINavigationParser.parseAIPath(&cursor, recordID: recordID))
            case .lodModel:
                return .lodModel(try LodModelParser.parse(&cursor, recordID: recordID))
            case .collisionSurface:
                return .collisionSurface(try CollisionSurfaceParser.parse(&cursor, recordID: recordID))
            case .skydome:
                return .skydome(try SkydomeParser.parse(&cursor, recordID: recordID))
            case .path:
                return .path(try PathParser.parse(&cursor, recordID: recordID))
            case .script:
                return .script(try ScriptParser.parse(&cursor, recordID: recordID, size: size, platform: .ps2))
            case .scriptX:
                return .script(try ScriptParser.parse(&cursor, recordID: recordID, size: size, platform: .xbox))
            case .scriptDemo:
                return .script(try ScriptParser.parse(&cursor, recordID: recordID, size: size, platform: .demo))
            case .customAgent:
                return .customAgent(try CustomAgentParser.parse(&cursor, recordID: recordID, platform: .ps2))
            case .customAgentX:
                return .customAgent(try CustomAgentParser.parse(&cursor, recordID: recordID, platform: .xbox))
            case .customAgentDemo:
                return .customAgent(try CustomAgentParser.parse(&cursor, recordID: recordID, platform: .demo))
            case .xboxSE:
                return .soundEffectX(try SoundEffectXParser.parse(&cursor, recordID: recordID))
            case .modelX:
                return .xboxModel(try XboxMeshParser.parseModelX(&cursor, recordID: recordID))
            case .skinX:
                return .xboxSkin(try XboxMeshParser.parseSkinX(&cursor, recordID: recordID))
            case .blendSkinX:
                return .xboxBlendSkin(try XboxMeshParser.parseBlendSkinX(&cursor, recordID: recordID))
            default:
                return .raw(byteCount: size)
            }
        } catch {
            return .raw(byteCount: size)
        }
    }
}
