import Foundation
import CTCore
import CTModels

/// "Parity Phase E": full byte-exact re-encode of a `ChunkLinks` record , 
/// ported field-for-field from `ChunkLinks.Save`/`SaveTree`
/// (`Twinsanity/Items/ChunkLinks.cs`). `path.length`, `giHeader`'s implied
/// tree-continuation gate, and each tree node's `blobSize` (`undecodedBlob.
/// count + 320`) are all recomputed from the Swift model's own current
/// string/array contents rather than trusted from any originally-captured
/// value, so this can add/remove links or tree nodes and stay correct, same
/// discipline `ScriptWriter.encode`/`GameObjectWriter.encode` already
/// established. Meant to *replace* the whole on-disk record (via
/// `WorkspaceViewModel.patchedFileBytes(replacingWholeRecord:with:)`), not
/// patch a subrange.
public enum ChunkLinksWriter {
    public static func encode(_ asset: ChunkLinksAsset) -> Data {
        var writer = BinaryWriter()
        writer.writeInt32(Int32(asset.links.count))
        for link in asset.links {
            writer.writeInt32(link.type)
            writer.writeInt32(Int32(link.path.utf8.count))
            writer.writeASCIIString(link.path)
            writer.writeUInt32(link.flags)

            for row in link.objectMatrix { writer.writeVector4(row) }
            for row in link.chunkMatrix { writer.writeVector4(row) }

            if link.flags & 0x80000 != 0, let wall = link.loadWall {
                for row in wall { writer.writeVector4(row) }
            }

            for node in link.treeNodes {
                writer.writeInt32(node.header)
                for value in node.giHeader { writer.writeUInt16(value) }
                writer.writeInt32(Int32(node.undecodedBlob.count) + 320)
                for row in node.loadArea { writer.writeVector4(row) }
                for row in node.areaMatrix { writer.writeVector4(row) }
                for row in node.unknownMatrix { writer.writeVector4(row) }
                writer.writeBytes(node.undecodedBlob)
            }
        }
        return writer.data
    }
}
