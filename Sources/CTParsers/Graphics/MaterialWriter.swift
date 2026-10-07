import Foundation
import CTCore
import CTModels

/// Encodes a `MaterialInfo` back to its real on-disk layout, the exact
/// inverse of `MaterialParser.parse`, ported field-for-field from
/// `Twinsanity/Items/Graphics/Material.cs`/`MaterialDemo.cs` and
/// `Twinsanity/TwinsShader.cs` (see `MaterialParser`'s own doc comment for
/// the `isDemo`/`isMonkeyBall` byte-length caveats).
///
/// The leading `Header`/`Unknown` fields (`MaterialParser.parse`'s `Header,
/// always 2` / `Unknown, always 2`) are written back as those same constants
///, the parser only ever discards them because every real on-disk value
/// observed is 2, exactly like `ColDataWriter`'s `someNumber`.
///
/// Each `TwinsShaderInfo.renderStateBytes` blob, the variable-length
/// parameter block plus fixed render-state fields between `shaderType` and
/// `textureId`, is written back verbatim, not re-derived: this codebase has
/// never decoded those ~90 bytes field-by-field (see `TwinsShaderInfo`'s doc
/// comment), so reproducing them exactly is the only way to avoid inventing
/// values for fields nobody has confirmed. This means editing `shaderType`
/// on an existing shader is unsupported (its captured `renderStateBytes`
/// would no longer match the parameter-block length the new type implies);
/// only `name` and `textureId` are safe to change.
///
/// Variable-length: `name` can change length, so the emitted byte count can
/// legitimately differ from the decoded record's original size, use
/// `WorkspaceViewModel.patchedFileBytes(replacingWholeRecord:with:)` for
/// this, not the fixed-size `patchedFileBytes(replacing:with:)`.
public enum MaterialWriter {
    public static func write(_ material: MaterialInfo) -> Data {
        var w = BinaryWriter()
        w.writeUInt64(2) // Header, always 2, see MaterialParser.parse
        w.writeInt32(2)  // Unknown, always 2, see MaterialParser.parse
        w.writeInt32(Int32(material.name.utf8.count))
        w.writeASCIIString(material.name)
        w.writeInt32(Int32(material.shaders.count))
        for shader in material.shaders {
            w.writeUInt32(shader.shaderType)
            w.writeBytes(shader.renderStateBytes)
            w.writeUInt32(shader.textureId)
            w.writeUInt32(shader.shaderType) // trailing repeated ShaderType
        }
        return w.data
    }
}
