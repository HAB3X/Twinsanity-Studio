import Foundation
import CTCore
import CTModels

/// Decodes a `Material` record: a name plus one or more `TwinsShader` blocks,
/// each ending in the texture ID it samples. Ported field-for-field from
/// `Twinsanity/Items/Graphics/Material.cs`/`MaterialDemo.cs` and
/// `Twinsanity/TwinsShader.cs`.
///
/// `Material.Load` determines `isMB` from `Parent.Parent.Type ==
/// SectionType.GraphicsMB` and calls `TwinsShader.Read(reader, 0, Demo:
/// false, SMBA: isMB)`; `MaterialDemo.Load` (a distinct record type,
/// `SectionType.MaterialD`, used only inside a `.rm2Demo`/`.sm2Demo` file's
/// `GraphicsD` container) calls `TwinsShader.Read(reader, 0, Demo: true)`
/// instead, `isDemo`/`isMonkeyBall` here are the caller's way of picking
/// the right one; both real, confirmed byte-length differences straight
/// from `TwinsShader.Read`/`GetLength` (`isDemo` removes the 2-byte
/// `UnkFlag3`/`BlobFlag` pair; `isMonkeyBall` adds 2 bytes right before
/// `TextureId` the reference's own author never identified, `// todo
/// somewhere here these 2 bytes`, but the *offset impact* is real and
/// confirmed regardless of what they mean).
public enum MaterialParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32, isDemo: Bool = false, isMonkeyBall: Bool = false) throws -> MaterialInfo {
        _ = try cursor.readUInt64() // Header, always 2
        _ = try cursor.readInt32()  // Unknown, always 2
        let nameLen = Int(try cursor.readInt32())
        let name = try cursor.readASCIIString(length: nameLen)
        let shaderCount = try cursor.readInt32()

        var shaders: [TwinsShaderInfo] = []
        shaders.reserveCapacity(cursor.safeReserveCount(shaderCount, elementSize: 92)) // smallest real TwinsShader block (Demo, non-MB)
        for _ in 0..<max(0, shaderCount) {
            shaders.append(try readShader(&cursor, isDemo: isDemo, isMonkeyBall: isMonkeyBall))
        }
        return MaterialInfo(id: recordID, name: name, shaders: shaders)
    }

    /// Reads one `TwinsShader` block (`TwinsShader.cs:74-149`) and decodes
    /// just `shaderType`/`textureId`, the ~90 bytes of PS2 GS render state
    /// in between (alpha blending, depth test, fog, LOD params, ...) are
    /// read to stay correctly positioned for the *next* shader, and captured
    /// verbatim into `renderStateBytes` so `MaterialWriter` can round-trip
    /// them, but aren't decoded field-by-field since nothing here needs
    /// their individual values yet.
    private static func readShader(_ cursor: inout BinaryCursor, isDemo: Bool, isMonkeyBall: Bool) throws -> TwinsShaderInfo {
        let shaderType = try cursor.readUInt32()
        // Everything from here through the end of the fixed render-state
        // block (i.e. everything up to `textureId`) is captured verbatim
        // into `renderStateBytes` below, not just consumed, see
        // `TwinsShaderInfo`'s doc comment.
        let stateStart = cursor.position

        // Variable-length parameter block, keyed by shader type.
        switch shaderType {
        case 23:
            _ = try cursor.readUInt32()  // IntParam
            _ = try cursor.readFloat32() // FloatParam[0]
            _ = try cursor.readFloat32() // FloatParam[1]
        case 26:
            _ = try cursor.readUInt32()
            for _ in 0..<4 { _ = try cursor.readFloat32() }
        case 16, 17:
            _ = try cursor.readFloat32()
        default:
            break
        }

        // 17 single-byte render-state fields.
        _ = try cursor.readBytes(17)
        // UsePresetAlphaRegSettings (bool)
        _ = try cursor.readBool()
        // SpecOfColA, SpecOfColB, SpecOfAlphaC, SpecOfColD, FixedAlphaValue, TextureFilter
        _ = try cursor.readBytes(6)
        // AlphaCorrectionValue, UnkFlag1, UnkFlag2 (3 bools)
        _ = try cursor.readBytes(3)
        // ZValueDrawingMask
        _ = try cursor.readUInt8()
        // UnkFlag3, BlobFlag (2 bools), real Demo-only omission (`TwinsShader.Read`'s `if (!Demo)`).
        if !isDemo {
            _ = try cursor.readBytes(2)
        }
        // LodParamK, LodParamL
        _ = try cursor.readUInt16()
        _ = try cursor.readUInt16()
        // UnkVector1, UnkVector2, UnkVector3 (16 bytes each)
        _ = try cursor.readBytes(48)
        // Real MonkeyBall-only 2 extra bytes right before TextureId, the
        // reference itself never identified what they encode, only that
        // they're there (`TwinsShader.Read`'s `if (SMBA)`).
        if isMonkeyBall {
            _ = try cursor.readUInt16()
        }

        let stateEnd = cursor.position
        let renderStateBytes = cursor.data[(cursor.data.startIndex + stateStart)..<(cursor.data.startIndex + stateEnd)]

        let textureId = try cursor.readUInt32()
        _ = try cursor.readUInt32() // trailing repeated ShaderType

        return TwinsShaderInfo(shaderType: shaderType, textureId: textureId, renderStateBytes: Data(renderStateBytes))
    }
}
