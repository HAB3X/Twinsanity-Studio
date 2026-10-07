import Foundation
import CTCore
import CTModels

/// "Backend Requirement: safely inject this new record into the .RM2 file
/// structure without corrupting the chunk" (Part 4D), the one piece of
/// real structural surgery nothing else in this build attempts.
/// `WorkspaceViewModel.patchedFileBytes(replacing:with:)` and its siblings
/// only ever overwrite an existing, already-sized region in place (safe
/// specifically *because* nothing else in the file has to move); adding a
/// brand-new record instead grows one section, which grows every section
/// enclosing it, all the way up to the file itself.
///
/// The layout this mirrors is ported exactly from `TwinsSection.cs`'s own
/// `Save`/`GetSize` (verified by reading that source, not guessed from the
/// reader alone):
/// ```
/// uint32 Magic
/// int32  RecordCount
/// uint32 ContentSize          // sum of every record's own byte size , 
///                              // NOT the section's total byte size
/// ChunkIndexEntry[RecordCount] // { offset, size, id }, 12 bytes each , 
///                              // offset is relative to this section's own
///                              // Magic, starting right after the index
///                              // table (RecordCount * 12 + 12) and
///                              // incrementing by each record's own Size , 
///                              // tightly packed, no padding between records
/// <record bytes, tightly packed, in the same order as the index table>
/// ```
/// Rather than trying to shift bytes/offsets in place (error-prone once a
/// section's own size, and therefore *every* enclosing section's size , 
/// changes), this reconstructs each level fresh: the target section gets
/// the new record appended and every index offset recomputed from
/// scratch; each ancestor above it gets its one changed child's bytes
/// swapped in and its own index table likewise recomputed from scratch,
/// with every *other* child copied byte-for-byte, verbatim, from the
/// original file at that child's own already-known `(fileOffset,
/// byteSize)`. A sibling this build doesn't touch is never re-encoded,
/// only ever copied, so nothing about it can be silently reinterpreted
/// wrong.
public enum ChunkSectionInserter {
    /// Produces a full replacement for `originalFileBytes` with one new
    /// record `(id, encoded)` appended to `targetSection`. `nil` if
    /// `targetSection` isn't actually reachable from `fileRoot`, if any
    /// section along the way doesn't parse as a valid chunk header, or if
    /// `targetSection` carries trailing bytes beyond what its own index
    /// table accounts for (`.se`-family sound banks' `ExtraData`, this
    /// function doesn't know how to preserve that safely, so it refuses
    /// rather than silently drop it; this build only ever calls it for
    /// `.objectInstance` collections, which don't have any).
    public static func insertingRecord(id: UInt32, encoded: Data, into targetSection: ChunkNode, fileRoot: ChunkNode, originalFileBytes: Data) -> Data? {
        insertingRecords([(id, encoded)], into: targetSection, fileRoot: fileRoot, originalFileBytes: originalFileBytes)
    }

    /// Same as `insertingRecord(id:encoded:into:fileRoot:originalFileBytes:)`,
    /// but appends every record in `records` to `targetSection` in one
    /// pass, the "Save Level Overrides" flow can place several new
    /// objects in one session before saving, and inserting them one at a
    /// time would mean re-parsing the whole file's freshly-patched bytes
    /// between each insert just to get an up-to-date `ChunkNode` tree to
    /// target the next one with. Batching sidesteps that entirely: every
    /// record lands in the same rebuild of `targetSection`, so this only
    /// ever walks up to the file root once.
    public static func insertingRecords(_ records: [(id: UInt32, encoded: Data)], into targetSection: ChunkNode, fileRoot: ChunkNode, originalFileBytes: Data) -> Data? {
        guard !records.isEmpty else { return originalFileBytes }
        guard let path = nodePath(from: fileRoot, to: targetSection) else { return nil }
        guard var rebuiltBytes = rebuildingSection(adding: records, removingIDs: [], sectionNode: targetSection, originalFileBytes: originalFileBytes) else { return nil }
        var rebuiltNode = targetSection

        for ancestor in path.dropLast().reversed() {
            guard let rebuiltAncestorBytes = replacingChild(rebuiltNode, in: ancestor, with: rebuiltBytes, originalFileBytes: originalFileBytes) else { return nil }
            rebuiltBytes = rebuiltAncestorBytes
            rebuiltNode = ancestor
        }
        return rebuiltBytes
    }

    /// Generalizes `insertingRecords(_:into:fileRoot:originalFileBytes:)` to
    /// several *different* target sections in one pass, "AI Pathfinding &
    /// Navmesh Editor" (roadmap 5.1) needed this alongside "Backend
    /// Requirement: safely inject this new record" (Part 4D) once a single
    /// save could add both a new `Instance` and a new `AIPosition` in one
    /// go, and those two collections are siblings under the same
    /// `.instance` container: calling the single-target version twice in a
    /// row, each rebuilding its own ancestor chain from the *original*
    /// tree's offsets against a byte buffer the *other* call had already
    /// grown, desyncs the moment either insertion changes any shared
    /// ancestor's size. This does one single top-down rebuild instead:
    /// every directly-targeted section gets its own new bytes; every
    /// ancestor of any targeted section is rebuilt from its *real*
    /// children, substituting only whichever of those children actually
    /// changed; everything else is copied verbatim from the original
    /// file, so no node's offset is ever read against bytes it wasn't
    /// computed from.
    public static func insertingRecords(
        intoSections targets: [(section: ChunkNode, records: [(id: UInt32, encoded: Data)])],
        fileRoot: ChunkNode,
        originalFileBytes: Data
    ) -> Data? {
        applyingRecordChanges(
            intoSections: targets.map { (section: $0.section, insert: $0.records, removeIDs: []) },
            fileRoot: fileRoot,
            originalFileBytes: originalFileBytes
        )
    }

    /// Removes the single record `id` from `targetSection`, the deletion
    /// counterpart to `insertingRecord`. `nil` under the same refuse-rather-
    /// than-guess conditions `insertingRecord` already has, plus: `id`
    /// isn't actually present in `targetSection`'s own index table (a stale
    /// caller shouldn't silently no-op and claim success on data that was
    /// never there).
    public static func removingRecord(id: UInt32, from targetSection: ChunkNode, fileRoot: ChunkNode, originalFileBytes: Data) -> Data? {
        removingRecords([id], from: targetSection, fileRoot: fileRoot, originalFileBytes: originalFileBytes)
    }

    /// Batched form of `removingRecord`, same "one rebuild, not N sequential
    /// ones" reasoning `insertingRecords(_:into:...)` already documents.
    public static func removingRecords(_ ids: [UInt32], from targetSection: ChunkNode, fileRoot: ChunkNode, originalFileBytes: Data) -> Data? {
        applyingRecordChanges(
            intoSections: [(section: targetSection, insert: [], removeIDs: ids)],
            fileRoot: fileRoot,
            originalFileBytes: originalFileBytes
        )
    }

    /// The fully general form: any number of target sections, each with its
    /// own records to insert *and* IDs to remove, applied as a single top-
    /// down rebuild, the same desync hazard `insertingRecords(intoSections:
    /// ...)`'s doc comment describes applies equally to "insert into a
    /// section and separately remove from it in two passes," and doubly so
    /// when an insert and a removal target sections that share an ancestor
    /// (e.g. deleting an Instance while adding a new Trigger in the same
    /// "Save Chunk Overrides", `Instance` and `Trigger` collections are
    /// both direct children of the same `.instance` container). One rebuild
    /// per targeted section (both its removals and insertions folded into
    /// the same re-tiling pass, so `Delete` never runs as a separate
    /// pretend-empty insert that a following real insert could desync
    /// against), then one top-down ancestor walk substituting only the
    /// sections that actually changed.
    public static func applyingRecordChanges(
        intoSections targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)], removeIDs: [UInt32])],
        fileRoot: ChunkNode,
        originalFileBytes: Data
    ) -> Data? {
        let activeTargets = targets.filter { !$0.insert.isEmpty || !$0.removeIDs.isEmpty }
        guard !activeTargets.isEmpty else { return originalFileBytes }

        var targetsByNodeID: [ObjectIdentifier: (insert: [(id: UInt32, encoded: Data)], removeIDs: [UInt32])] = [:]
        for target in activeTargets {
            guard targetsByNodeID[ObjectIdentifier(target.section)] == nil else { continue }
            targetsByNodeID[ObjectIdentifier(target.section)] = (target.insert, target.removeIDs)
        }

        // Real, reported bug ("place an object via the Forge Palette, Quick
        // Launch, it never appears"): a node can be *both* a direct target
        // (e.g. a whole-record ColData replacement, whose own containing
        // section is `fileRoot` itself, confirmed against real disc data)
        // *and* an ancestor of a completely different, separately-targeted
        // descendant (e.g. a new Instance appended several tiers down,
        // inside `fileRoot`'s own Instance container). This used to check
        // "is `node` itself a direct target?" *first* and return
        // immediately if so, meaning the instant `fileRoot` matched a
        // direct target, its whole rebuild came from re-tiling its *own*
        // index table against nothing but `originalFileBytes`, without ever
        // recursing into its children to see whether any of *them* also had
        // pending structural changes. The nested Instance insertion was
        // computed successfully into its own correct bytes and then
        // silently discarded, this function still reported success (a
        // real `Data` came back, genuinely larger than the original by the
        // ColData record's own size delta), so nothing about the save
        // itself ever surfaced an error; the object just never made it into
        // the file. Every session-placed object with real collision data
        // triggers an automatic ColData rebuild (see `WorkspaceViewModel
        // .computingRebuiltCollisionRecord`'s own doc comment, "part of
        // *every* save this function already produces"), so this wasn't an
        // edge case: it silently ate the placement on effectively every
        // real save. Fixed by always recursing into `node.children` first,
        // regardless of whether `node` itself is also a direct target , 
        // whichever child(ren) come back changed are threaded in as
        // `childOverridesByID` for `rebuildingSection` to substitute at
        // that same pass, so a node's own add/remove and a descendant's
        // separately-computed change always compose instead of one
        // silently winning.
        func rebuild(_ node: ChunkNode) -> Data? {
            var childOverridesByID: [UInt32: Data] = [:]
            for child in node.children {
                if let result = rebuild(child) {
                    childOverridesByID[child.recordID] = result
                }
            }
            let ownTarget = targetsByNodeID[ObjectIdentifier(node)]
            guard ownTarget != nil || !childOverridesByID.isEmpty else { return nil }
            return rebuildingSection(
                adding: ownTarget?.insert ?? [],
                removingIDs: Set(ownTarget?.removeIDs ?? []),
                sectionNode: node,
                originalFileBytes: originalFileBytes,
                childOverridesByID: childOverridesByID
            )
        }

        return rebuild(fileRoot)
    }

    /// The node-identity path from `root` down to `target`, root first,
    /// `target` last, `ChunkNode` is a reference type, so `===` identity
    /// is exact, no risk of matching an equal-looking sibling instead.
    private static func nodePath(from root: ChunkNode, to target: ChunkNode) -> [ChunkNode]? {
        if root === target { return [root] }
        for child in root.children {
            if let subPath = nodePath(from: child, to: target) {
                return [root] + subPath
            }
        }
        return nil
    }

    private static func sliceBytes(_ data: Data, offset: Int, size: Int) -> Data? {
        guard offset >= 0, size >= 0, offset + size <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + size))
    }

    /// Rebuilds `sectionNode`'s own on-disk span with every ID in
    /// `removingIDs` dropped and every record in `adding` appended, in that
    /// order, kept records (everything not in `removingIDs`) keep their
    /// original relative order, matching `TwinsSection.RemoveItem`'s own
    /// "shift the rest down" behavior rather than reordering anything.
    /// `removingIDs: []` reduces this to exactly what the old
    /// `appendingRecords` did (pure append); `adding: []` reduces it to a
    /// pure removal.
    /// `childOverridesByID`: for a KEPT entry (not being removed, no new
    /// insert), substitute this recordID's own bytes with the given `Data`
    /// instead of copying its raw slice verbatim from `originalFileBytes` , 
    /// the mechanism that lets a node which is *itself* a direct add/remove
    /// target (e.g. a whole-record ColData replacement) *also* correctly
    /// fold in a descendant's separately-computed structural change (e.g. a
    /// new Instance appended several tiers below), instead of one silently
    /// overwriting the other, see `applyingRecordChanges`'s own doc
    /// comment for the real, reported bug this fixes. Empty (the default)
    /// reduces this to exactly the old behavior: every kept entry copied
    /// verbatim.
    private static func rebuildingSection(adding records: [(id: UInt32, encoded: Data)], removingIDs: Set<UInt32>, sectionNode: ChunkNode, originalFileBytes: Data, childOverridesByID: [UInt32: Data] = [:]) -> Data? {
        guard sectionNode.byteSize >= 12,
              let sectionBytes = sliceBytes(originalFileBytes, offset: sectionNode.fileOffset, size: sectionNode.byteSize)
        else { return nil }
        var cursor = BinaryCursor(data: sectionBytes)
        guard let header = try? ChunkHeaderReader.readHeader(from: &cursor) else { return nil }

        let oldHeaderIndexLength = 12 + header.entries.count * 12
        guard let oldDataArea = sliceBytes(sectionBytes, offset: oldHeaderIndexLength, size: sectionBytes.count - oldHeaderIndexLength) else { return nil }
        // Every entry's own size must exactly tile the data area with
        // nothing left over, see this type's own doc comment on why a
        // mismatch (trailing `ExtraData`) means "refuse," not "guess."
        let declaredDataLength = header.entries.reduce(0) { $0 + Int($1.size) }
        guard declaredDataLength == oldDataArea.count else { return nil }

        // Refuse rather than silently no-op if asked to remove an ID that
        // isn't actually present, a stale caller shouldn't read back
        // success on a deletion that never happened.
        let presentIDs = Set(header.entries.map { $0.id })
        guard removingIDs.isSubset(of: presentIDs) else { return nil }

        var keptEntries: [(id: UInt32, bytes: Data)] = []
        keptEntries.reserveCapacity(header.entries.count - removingIDs.count)
        for entry in header.entries where !removingIDs.contains(entry.id) {
            if let override = childOverridesByID[entry.id] {
                keptEntries.append((entry.id, override))
                continue
            }
            let relativeOffset = Int(entry.offset) - oldHeaderIndexLength
            guard let bytes = sliceBytes(oldDataArea, offset: relativeOffset, size: Int(entry.size)) else { return nil }
            keptEntries.append((entry.id, bytes))
        }

        let newRecordCount = keptEntries.count + records.count
        let newHeaderIndexLength = 12 + newRecordCount * 12
        let keptDataLength = keptEntries.reduce(0) { $0 + $1.bytes.count }
        let newRecordsTotalSize = records.reduce(0) { $0 + $1.encoded.count }

        var writer = BinaryWriter()
        writer.writeUInt32(header.magic)
        writer.writeInt32(Int32(newRecordCount))
        writer.writeUInt32(UInt32(keptDataLength + newRecordsTotalSize))

        var runningOffset = newHeaderIndexLength
        for entry in keptEntries {
            writer.writeUInt32(UInt32(runningOffset))
            writer.writeInt32(Int32(entry.bytes.count))
            writer.writeUInt32(entry.id)
            runningOffset += entry.bytes.count
        }
        for record in records {
            writer.writeUInt32(UInt32(runningOffset))
            writer.writeInt32(Int32(record.encoded.count))
            writer.writeUInt32(record.id)
            runningOffset += record.encoded.count
        }

        for entry in keptEntries {
            writer.writeBytes(entry.bytes)
        }
        for record in records {
            writer.writeBytes(record.encoded)
        }
        return writer.data
    }

    /// Rebuilds `ancestor`'s own on-disk span with whichever child matches
    /// `childNode`'s identity replaced by `newChildBytes`; every other
    /// child is copied verbatim from `originalFileBytes` at its own
    /// already-known `(fileOffset, byteSize)`. Thin wrapper over
    /// `replacingChildren`, the general form `insertingRecords(
    /// intoSections:fileRoot:originalFileBytes:)` needs, since more than
    /// one of `ancestor`'s children can change at once when two different
    /// target sections share this same parent.
    private static func replacingChild(_ childNode: ChunkNode, in ancestor: ChunkNode, with newChildBytes: Data, originalFileBytes: Data) -> Data? {
        let overrides = ancestor.children.map { $0 === childNode ? newChildBytes : nil }
        return replacingChildren(ancestor, newChildBytes: overrides, originalFileBytes: originalFileBytes)
    }

    /// Rebuilds `node`'s own on-disk span with `newChildBytes[i]` (when
    /// non-nil) substituted for the on-disk bytes of `node.children[i]`;
    /// every `nil` entry is copied verbatim from `originalFileBytes` at
    /// that child's own already-known `(fileOffset, byteSize)`. The whole
    /// span is re-tiled tightly-packed from scratch either way, matching
    /// the reference writer's own layout exactly (see this type's
    /// top-level doc comment), not merely "shifted" from the old one.
    private static func replacingChildren(_ node: ChunkNode, newChildBytes: [Data?], originalFileBytes: Data) -> Data? {
        guard node.byteSize >= 12,
              let nodeBytes = sliceBytes(originalFileBytes, offset: node.fileOffset, size: node.byteSize)
        else { return nil }
        var cursor = BinaryCursor(data: nodeBytes)
        guard let header = try? ChunkHeaderReader.readHeader(from: &cursor) else { return nil }
        // The decoded tree's children and this section's own index table
        // must correspond 1:1, in order, true by construction for every
        // section kind this build actually calls this on (see the doc
        // comment above), checked rather than assumed so a parser edge
        // case fails this save instead of silently misattributing bytes.
        guard header.entries.count == node.children.count, header.entries.count == newChildBytes.count else { return nil }

        var childSlices: [Data] = []
        var childIDs: [UInt32] = []
        for (index, entry) in header.entries.enumerated() {
            if let override = newChildBytes[index] {
                childSlices.append(override)
            } else {
                guard let slice = sliceBytes(nodeBytes, offset: Int(entry.offset), size: Int(entry.size)) else { return nil }
                childSlices.append(slice)
            }
            childIDs.append(entry.id)
        }

        var writer = BinaryWriter()
        writer.writeUInt32(header.magic)
        writer.writeInt32(Int32(childSlices.count))
        writer.writeUInt32(UInt32(childSlices.reduce(0) { $0 + $1.count }))

        let headerIndexLength = 12 + childSlices.count * 12
        var runningOffset = headerIndexLength
        for (slice, id) in zip(childSlices, childIDs) {
            writer.writeUInt32(UInt32(runningOffset))
            writer.writeInt32(Int32(slice.count))
            writer.writeUInt32(id)
            runningOffset += slice.count
        }
        for slice in childSlices {
            writer.writeBytes(slice)
        }
        return writer.data
    }
}
