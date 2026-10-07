import Foundation
import CTCore
import CTModels

/// Decodes a `ChunkLinks` record, ported field-for-field from
/// `Twinsanity/Items/ChunkLinks.cs`'s `Load`/`ReadTree`. This is the format's
/// real chunk-streaming model: each `ChunkLink` names a neighboring chunk
/// file (`path`), the transform that aligns it into this chunk's coordinate
/// space (`chunkMatrix`), and optionally the boundary geometry that triggers
/// loading it (`loadWall`, a "load wall" quad; `treeNodes`, a chain of
/// `loadArea` volumes).
///
/// Layout:
/// ```
/// int32 linkCount
/// ChunkLink[linkCount]:
///   int32 type
///   int32 pathLength; char[pathLength] path
///   uint32 flags
///   Pos objectMatrix[4]
///   Pos chunkMatrix[4]
///   if flags & 0x80000: Pos loadWall[4]
///   LinkTree (present only while `gate & 0x1 != 0`, chained via each
///     node's own `header` field as the next gate):
///     int32 header
///     uint16 giHeader[11]
///     int32 blobSize
///     Pos loadArea[8]
///     Pos areaMatrix[6]
///     Pos unknownMatrix[6]
///     byte[blobSize - 320] undecoded blob
/// ```
public enum ChunkLinksParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> ChunkLinksAsset {
        let count = Int(try cursor.readInt32())
        var links: [ChunkLink] = []
        // Minimum real on-disk size of one ChunkLink (type + pathLength +
        // empty path + flags + objectMatrix + chunkMatrix, before any
        // optional loadWall/tree data), a conservative lower bound so a
        // corrupt/crafted `count` can't force a huge blind allocation.
        links.reserveCapacity(cursor.safeReserveCount(count, elementSize: 140))

        for index in 0..<max(0, count) {
            let type = try cursor.readInt32()
            let pathLength = Int(try cursor.readInt32())
            let path = try cursor.readASCIIString(length: pathLength)
            let flags = try cursor.readUInt32()

            var objectMatrix: [SIMD4<Float>] = []
            objectMatrix.reserveCapacity(4)
            for _ in 0..<4 { objectMatrix.append(try cursor.readVector4()) }

            var chunkMatrix: [SIMD4<Float>] = []
            chunkMatrix.reserveCapacity(4)
            for _ in 0..<4 { chunkMatrix.append(try cursor.readVector4()) }

            var loadWall: [SIMD4<Float>]?
            if (flags & 0x80000) != 0 {
                var wall: [SIMD4<Float>] = []
                wall.reserveCapacity(4)
                for _ in 0..<4 { wall.append(try cursor.readVector4()) }
                loadWall = wall
            }

            var treeNodes: [ChunkLinkTreeNode] = []
            var gate = type
            while (gate & 0x1) != 0 {
                let header = try cursor.readInt32()
                var giHeader: [UInt16] = []
                giHeader.reserveCapacity(11)
                for _ in 0..<11 { giHeader.append(try cursor.readUInt16()) }
                let blobSize = Int(try cursor.readInt32())

                var loadArea: [SIMD4<Float>] = []
                loadArea.reserveCapacity(8)
                for _ in 0..<8 { loadArea.append(try cursor.readVector4()) }

                var areaMatrix: [SIMD4<Float>] = []
                areaMatrix.reserveCapacity(6)
                for _ in 0..<6 { areaMatrix.append(try cursor.readVector4()) }

                var unknownMatrix: [SIMD4<Float>] = []
                unknownMatrix.reserveCapacity(6)
                for _ in 0..<6 { unknownMatrix.append(try cursor.readVector4()) }

                // 320 = (8 + 6 + 6) Pos entries just read (16 bytes each) , 
                // the reference tool's own `blobSize - 320`.
                let remainder = max(0, blobSize - 320)
                let blob = try cursor.readBytes(remainder)

                treeNodes.append(ChunkLinkTreeNode(
                    header: header, giHeader: giHeader, loadArea: loadArea,
                    areaMatrix: areaMatrix, unknownMatrix: unknownMatrix, undecodedBlob: blob
                ))
                gate = header
            }

            links.append(ChunkLink(
                id: index, type: type, path: path, flags: flags,
                objectMatrix: objectMatrix, chunkMatrix: chunkMatrix,
                loadWall: loadWall, treeNodes: treeNodes
            ))
        }

        return ChunkLinksAsset(id: recordID, links: links)
    }
}
