import Foundation

/// One `TwinsShader` entry within a `Material`, the PS2 GS render-state
/// block that, critically, ends with the texture ID this shader samples from
/// (`Twinsanity/TwinsShader.cs:147`). This is the actual link between a mesh
/// submesh's material and its texture; everything else in the original
/// 90+-byte render-state block (alpha blending mode, depth test, fog, LOD
/// params, ...) is real GS state but not needed to answer "which texture
/// does this submesh use," so only `shaderType`/`textureId` are modeled.
///
/// `renderStateBytes` is that same 90+-byte block, kept verbatim rather than
/// decoded, the variable-length parameter block keyed by `shaderType`, plus
/// every fixed and `isDemo`/`isMonkeyBall`-conditional render-state field
/// `MaterialParser.readShader` walks past on the way to `textureId`. Captured
/// (not thrown away) purely so `MaterialWriter` can reproduce a shader block
/// byte-for-byte after `name`/`textureId` are edited, without inventing
/// values for any of the fields this codebase hasn't decoded. Editing
/// `shaderType` here is unsupported: the captured bytes were only ever
/// validated against the original `shaderType`'s parameter-block length.
public struct TwinsShaderInfo: Sendable {
    public var shaderType: UInt32
    public var textureId: UInt32
    public var renderStateBytes: Data

    public init(shaderType: UInt32, textureId: UInt32, renderStateBytes: Data = Data()) {
        self.shaderType = shaderType
        self.textureId = textureId
        self.renderStateBytes = renderStateBytes
    }
}

/// A decoded `Material` record: a name plus one or more shaders, each
/// pointing at a texture. `primaryTextureID` is the first shader's texture , 
/// the common case is exactly one shader per material.
public struct MaterialInfo: Sendable, Identifiable {
    public let id: UInt32
    public var name: String
    public var shaders: [TwinsShaderInfo]

    public init(id: UInt32, name: String, shaders: [TwinsShaderInfo]) {
        self.id = id
        self.name = name
        self.shaders = shaders
    }

    public var primaryTextureID: UInt32? { shaders.first?.textureId }
}
