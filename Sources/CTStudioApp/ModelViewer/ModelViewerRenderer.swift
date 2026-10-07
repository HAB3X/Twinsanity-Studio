import Metal
import MetalKit
import CoreGraphics
import QuartzCore
import simd
import CTCore
import CTModels
import CTParsers

/// Tightly-packed, GPU-ready vertex layout: 12 sequential `Float`s (48
/// bytes), no `SIMD3<Float>` fields. This matters, `SIMD3<Float>` has a
/// 16-byte Swift *stride* (not 12), so a buffer of `StaticVertex` values
/// uploaded directly to the GPU would silently misalign every attribute
/// after the first. Building a flat scalar struct sidesteps that entirely:
/// what you see here is exactly what's in the `MTLBuffer`.
struct ModelVertexGPU {
    var px, py, pz: Float
    var nx, ny, nz: Float
    var u, v: Float
    var r, g, b, a: Float
}

/// One submesh's GPU resources: its own vertex/index buffers (submeshes
/// have independent vertex streams, since each can use a different
/// triangle-strip connectivity pattern) and its resolved texture, if any.
/// Not `private`, `skinVertices(submesh:skinningMatrices:)` below takes
/// this type directly, and a synthetic-weight regression test (the
/// "totalWeight renormalization" fix) needs to construct one without going
/// through a full skeleton/animation-track pipeline.
struct GPUSubmesh {
    /// Index into the source `ResolvedModelAsset.mesh.submeshes`, *not*
    /// necessarily this array's own index, since submeshes with no
    /// vertices are skipped during upload and would otherwise shift
    /// everything after them out of alignment with
    /// `ModelViewerRenderer.hiddenSubmeshIndices`.
    let originalIndex: Int
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let texture: MTLTexture
    /// Bind-space (unanimated) vertex data, retained alongside the GPU
    /// buffer so real skeletal animation (`AnimationSkeletonBinding`) can
    /// re-skin *from bind pose* every frame, never from the previous
    /// frame's already-deformed result, which would compound error. Empty
    /// for non-skinned submeshes (rigid scenery/props, and the Level
    /// Viewer's placeholder markers), which never need re-skinning.
    let bindVertices: [StaticVertex]
    let jointIndices: [SIMD4<UInt16>]
    let jointWeights: [SIMD4<Float>]
    /// Real, requested collision refinement: comparing this project's own
    /// generated collision against the game's real, hand-authored `ColData`
    /// showed real collision groups running far leaner than any scenery
    /// object's own render mesh (measured against `hubb.rm2`: ~14-25
    /// triangles per real group vs. 70-800 per placed object's visual
    /// mesh), and real, reported user observation confirms why: "on trees
    /// the leaves have no collision as it's not needed." There's no
    /// per-submesh semantic tag ("this is foliage") anywhere in this
    /// format, but there's a real, checkable proxy already decoded for
    /// every texture: foliage/cutout textures are overwhelmingly alpha-
    /// transparent where solid geometry (trunks, rock) is not. Computed
    /// once at upload time (`ModelViewerRenderer.isMostlyTransparent`)
    /// from the submesh's own real resolved texture, so
    /// `LevelViewerWindow.worldMeshTriangles` can skip exactly the
    /// submeshes this heuristic flags as foliage without re-deriving it
    /// per collision rebuild.
    // Real Swift memberwise-init gotcha (same fix as `GPULevelObject.
    // assetCollisionData`'s own doc comment): a `let` with a fixed default
    // expression is pre-initialized and excluded from the synthesized
    // memberwise init entirely, silently making every existing call site
    // that doesn't pass it always get `false` regardless of intent. `var`
    // keeps it a real, settable init parameter.
    var excludeFromCollision: Bool = false
}

/// Thread-safe, `UInt32`-keyed cache with simple FIFO eviction once
/// `maxEntries` is hit (`nil` means unbounded). Shared by `TextureUploadCache`
/// and `MeshUploadCache` below, which used to each hand-roll an identical
/// copy of this exact logic (found in code review), a generic type here
/// means a future change to the eviction policy (e.g. true LRU instead of
/// FIFO) only needs to happen once.
///
/// Real, confirmed data race (found in code review, before it ever
/// shipped): `LevelViewerRenderer.init?`, the only thing that ever calls
/// `store`/`value(for:)` on either of the two caches below, moved from
/// guaranteed-serial main-actor execution to running inside `Task.detached`
/// (`LevelViewerWindow`'s `.task`, so it doesn't block input on open).
/// `Task.detached` is genuinely unstructured: cancelling the `.task` that
/// spawned it does *not* stop it, so switching levels quickly
/// (`LevelViewerWindowHost`'s `.id(context.id)` tears down the old window
/// and starts a new one immediately) can leave two of these builds running
/// concurrently on different threads, both racing to `store`/read the
/// exact same `ModelViewerGPUContext.shared` cache instance, an
/// unsynchronized `Dictionary` mutation from multiple threads, undefined
/// behavior that can corrupt the cache or trip a Swift exclusivity-access
/// crash. The lock here fixes this unconditionally for every instance
/// (persistent or per-upload) rather than only guarding the one call site
/// that happens to be multi-threaded today, the safer, more general fix
/// per this project's own "special cases bolted onto shared infrastructure
/// aren't deep enough" standard. Uncontended-lock overhead is negligible
/// next to the GPU work each call already does.
final class BoundedGPUCache<Value> {
    private var values: [UInt32: Value] = [:]
    /// Performance fix (audit): this used to be plain insertion order , 
    /// strict FIFO eviction, so a hot asset reused constantly could still
    /// get evicted ahead of one inserted more recently but never touched
    /// again. Now genuine access order: every read *and* every write moves
    /// an id to the most-recently-used end via `bump`, so eviction always
    /// drops the least-recently-*used* entry, not just the oldest-*inserted*
    /// one. `firstIndex(of:)`/`remove(at:)` are O(n), which is fine at this
    /// cache's real scale (bounded to `maxEntries`, typically ≤256), no
    /// need for a doubly-linked-list LRU here.
    private var accessOrder: [UInt32] = []
    private let maxEntries: Int?
    private let lock = NSLock()

    init(maxEntries: Int? = nil) {
        self.maxEntries = maxEntries
    }

    private func bump(_ id: UInt32) {
        if let index = accessOrder.firstIndex(of: id) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(id)
    }

    func value(for id: UInt32) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[id] else { return nil }
        bump(id)
        return value
    }

    func store(_ value: Value, for id: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        bump(id)
        values[id] = value
        if let maxEntries, accessOrder.count > maxEntries {
            values.removeValue(forKey: accessOrder.removeFirst())
        }
    }
}

/// A real, confirmed fix for "massive level rendering" (performance
/// mandate): a `SceneryData`/`Instance` collection can carry
/// hundreds/thousands of placements, and, before this, every single
/// one independently re-uploaded and re-copied its own `MTLTexture` even
/// when many placements share the exact same underlying texture (the
/// overwhelmingly common case: dozens of identical crate/prop/enemy
/// placements). Scoped to *one* `upload()` call by default (constructed
/// fresh each time a level loads, `maxEntries: nil`), `TextureAsset.id`
/// is a per-file on-disk record ID, not a globally unique one (see
/// `ResolvedModelAsset.id`'s own doc comment on exactly this), so caching
/// by that ID across *different* files would risk silently reusing the
/// wrong texture. Within one file's own resolved placements it's a
/// completely safe, meaningful win: they all came from the same
/// `GraphicsAssetIndex`, so the same ID really is the same real texture.
///
/// `maxEntries`, when set, makes this class also usable as a *persistent*,
/// cross-level cache for the one case that's actually safe, see
/// `ModelViewerGPUContext.sharedDefaultAssetTextureCache`'s own doc
/// comment, with `BoundedGPUCache`'s simple FIFO eviction once the bound
/// is hit, a real cap rather than trusting real Default.rm2 data (small
/// and fixed today) to stay that way forever.
final class TextureUploadCache {
    private let storage: BoundedGPUCache<MTLTexture>

    init(maxEntries: Int? = nil) {
        storage = BoundedGPUCache(maxEntries: maxEntries)
    }

    func texture(for id: UInt32) -> MTLTexture? { storage.value(for: id) }
    func store(_ texture: MTLTexture, for id: UInt32) { storage.store(texture, for: id) }
}

/// Real, reported performance bug: every one of a level's placements
/// independently rebuilt its own vertex/index `MTLBuffer`s via
/// `buildGPUSubmeshes`, even when many placements reference the exact
/// same underlying static mesh, the overwhelmingly common case for
/// scenery (dozens of identical tree/rock/prop placements scattered
/// across a level) and for plenty of Instance placements too (repeated
/// crates, platforms). GPU vertex/index buffers hold *local*-space mesh
/// geometry; the per-object world transform is applied separately, per
/// draw call, via `Uniforms.modelMatrix` (see `encodeScene`), so
/// multiple static placements of the same model can safely share one set
/// of GPU buffers, each still drawn at its own `worldPosition`/
/// `rotation`/`scale`.
///
/// Deliberately gated to `asset.skeleton == nil` at every call site, a
/// *skinned* mesh's vertex buffer is rewritten in place every frame with
/// its current animation pose (`GPULevelObject.writeVertices`, used by
/// `debugAllSkinnedVertexPositions`/the skinning update path). Sharing a
/// buffer across multiple placements of an animated model would make
/// them all show one shared pose, or worse, race, the instant more
/// than one of them animated independently. Restricting this cache to
/// unambiguously static (unskinned) meshes avoids that risk entirely
/// rather than trying to detect it after the fact.
///
/// Scoped to one `upload()` call by default (`maxEntries: nil`), same
/// reasoning as `TextureUploadCache`'s own doc comment: `recordID` is a
/// per-file on-disk ID, safe to key on only within the placements of the
/// single file this cache was built for. `maxEntries`, when set, allows
/// the same persistent, cross-level, bounded use as `TextureUploadCache` , 
/// see `ModelViewerGPUContext.sharedDefaultAssetMeshCache`'s own doc comment.
final class MeshUploadCache {
    struct Entry {
        var submeshes: [GPUSubmesh]
        var localBoundsMin: SIMD3<Float>
        var localBoundsMax: SIMD3<Float>
        var boundingRadius: Float
    }
    private let storage: BoundedGPUCache<Entry>

    init(maxEntries: Int? = nil) {
        storage = BoundedGPUCache(maxEntries: maxEntries)
    }

    func entry(for recordID: UInt32) -> Entry? { storage.value(for: recordID) }
    func store(_ entry: Entry, for recordID: UInt32) { storage.store(entry, for: recordID) }
}

/// Matches the Metal shader's `Uniforms` struct byte-for-byte:
/// `simd_float4x4` is already MSL-`float4x4`-compatible (column-major, 64
/// bytes), and `SIMD3<Float>` as the last field naturally gets the same
/// 16-byte stride MSL gives a trailing `float3` in a constant-buffer struct
///, no manual padding needed on either side.
private struct Uniforms {
    var modelViewProjection: simd_float4x4
    var modelMatrix: simd_float4x4
    var lightDirection: SIMD3<Float>
}

/// Device-level Metal state shared by every `ModelViewerRenderer` instance:
/// the compiled shader library, both pipeline states, depth/sampler state,
/// and the 1×1 fallback texture. None of this depends on which asset is
/// being shown, but building it means compiling MSL source and linking a
/// pipeline, tens of milliseconds of real work. The old `init?` rebuilt
/// all of it from scratch per asset, which was invisible when the Model
/// Viewer opened once per session; it stopped being invisible once the
/// composite preview (`CompositePreviewView`) started creating a fresh
/// `ModelViewerRenderer` on every single sidebar click. Built once, lazily,
/// on first use, and reused for the process's lifetime.
private final class ModelViewerGPUContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let linePipelineState: MTLRenderPipelineState?
    let collisionLinePipelineState: MTLRenderPipelineState?
    let collisionLineColoredPipelineState: MTLRenderPipelineState?
    /// "Chunk-Based Architecture" (Part 2): fills a translucent quad , 
    /// the real boundary "load wall" geometry decoded from `ChunkLinks` , 
    /// using the same interleaved position+color vertex layout as
    /// `collisionLineColoredPipelineState`, just drawn as triangles at a
    /// low, see-through alpha instead of lines.
    let translucentQuadPipelineState: MTLRenderPipelineState?
    /// The level's real, decoded collision mesh (`ColData`), the
    /// reference tool's own default-on ground floor (`RMViewer.cs`:
    /// `collisions = true` in its constructor, drawn as solid lit
    /// triangles), never previously rendered anywhere in this Level
    /// Viewer. Same interleaved position+color vertex layout as
    /// `collisionLineColoredPipelineState`'s wireframe, drawn *filled* and
    /// *opaque* (full alpha, depth-write enabled via the ordinary
    /// `depthState`) instead of translucent, this is the level's actual
    /// ground, not an overlay, so it needs to correctly occlude/be
    /// occluded like any other solid geometry.
    let collisionFillPipelineState: MTLRenderPipelineState?
    let depthState: MTLDepthStencilState
    /// Same depth comparison as `depthState` but no depth *write*, a
    /// translucent overlay quad shouldn't occlude whatever draws after it
    /// in the same frame, only be correctly occluded by opaque geometry
    /// already in the depth buffer.
    let translucentDepthState: MTLDepthStencilState
    let samplerState: MTLSamplerState
    let fallbackTexture: MTLTexture

    /// "No Cross-Level GPU Cache" fix: persistent, process-wide GPU caches
    /// for geometry/textures resolved through the shared `Startup/Default.rm2`
    /// fallback index, see `LevelViewerContext.resolvedFromSharedDefault`'s
    /// doc comment for exactly why this one case (crates, Wumpa, other
    /// common pickups defined once and reused across every level) is safe
    /// to cache by `recordID` alone across *different* renderer instances,
    /// unlike `TextureUploadCache`/`MeshUploadCache`'s normal per-upload
    /// scope. Lives on `ModelViewerGPUContext.shared` (one instance for the
    /// process's whole lifetime, same as the pipeline states above) rather
    /// than on any one `LevelViewerRenderer`, so it actually survives
    /// across closing/reopening a level or switching between levels , 
    /// before this, `Default.rm2`'s crate/pickup geometry and textures were
    /// re-decoded and re-uploaded to the GPU from scratch on *every single*
    /// level open, even though the underlying data never changes for the
    /// whole session. Bounded (128 entries each) even though real
    /// `Default.rm2` data is small and fixed today (~30 records), see
    /// `TextureUploadCache`/`MeshUploadCache`'s own doc comments on the
    /// FIFO eviction this bound triggers.
    let sharedDefaultAssetTextureCache = TextureUploadCache(maxEntries: 128)
    let sharedDefaultAssetMeshCache = MeshUploadCache(maxEntries: 128)

    static let shared: ModelViewerGPUContext? = ModelViewerGPUContext()

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue

        guard let library = try? device.makeLibrary(source: ModelViewerRenderer.shaderSource, options: nil) else {
            return nil
        }
        let vertexFunction = library.makeFunction(name: "vertex_main")
        let fragmentFunction = library.makeFunction(name: "fragment_main")

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.stride * 3
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = MemoryLayout<Float>.stride * 6
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .float4
        vertexDescriptor.attributes[3].offset = MemoryLayout<Float>.stride * 8
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<ModelVertexGPU>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            return nil
        }
        self.pipelineState = pipelineState

        if let lineVertexFn = library.makeFunction(name: "vertex_line"), let lineFragmentFn = library.makeFunction(name: "fragment_line") {
            let lineDescriptor = MTLRenderPipelineDescriptor()
            lineDescriptor.vertexFunction = lineVertexFn
            lineDescriptor.fragmentFunction = lineFragmentFn
            lineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            lineDescriptor.depthAttachmentPixelFormat = .depth32Float
            linePipelineState = try? device.makeRenderPipelineState(descriptor: lineDescriptor)
        } else {
            linePipelineState = nil
        }

        if let lineVertexFn = library.makeFunction(name: "vertex_line"), let collisionFragmentFn = library.makeFunction(name: "fragment_line_collision") {
            let collisionLineDescriptor = MTLRenderPipelineDescriptor()
            collisionLineDescriptor.vertexFunction = lineVertexFn
            collisionLineDescriptor.fragmentFunction = collisionFragmentFn
            collisionLineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            collisionLineDescriptor.colorAttachments[0].isBlendingEnabled = true
            collisionLineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            collisionLineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            collisionLineDescriptor.depthAttachmentPixelFormat = .depth32Float
            collisionLinePipelineState = try? device.makeRenderPipelineState(descriptor: collisionLineDescriptor)
        } else {
            collisionLinePipelineState = nil
        }

        if let colorLineVertexFn = library.makeFunction(name: "vertex_line_colored"), let colorLineFragmentFn = library.makeFunction(name: "fragment_line_colored") {
            let coloredDescriptor = MTLRenderPipelineDescriptor()
            coloredDescriptor.vertexFunction = colorLineVertexFn
            coloredDescriptor.fragmentFunction = colorLineFragmentFn
            coloredDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            coloredDescriptor.colorAttachments[0].isBlendingEnabled = true
            coloredDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            coloredDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            coloredDescriptor.depthAttachmentPixelFormat = .depth32Float
            collisionLineColoredPipelineState = try? device.makeRenderPipelineState(descriptor: coloredDescriptor)
        } else {
            collisionLineColoredPipelineState = nil
        }

        if let colorLineVertexFn = library.makeFunction(name: "vertex_line_colored"), let translucentFragmentFn = library.makeFunction(name: "fragment_translucent_quad") {
            let translucentDescriptor = MTLRenderPipelineDescriptor()
            translucentDescriptor.vertexFunction = colorLineVertexFn
            translucentDescriptor.fragmentFunction = translucentFragmentFn
            translucentDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            translucentDescriptor.colorAttachments[0].isBlendingEnabled = true
            translucentDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            translucentDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            translucentDescriptor.depthAttachmentPixelFormat = .depth32Float
            translucentQuadPipelineState = try? device.makeRenderPipelineState(descriptor: translucentDescriptor)
        } else {
            translucentQuadPipelineState = nil
        }

        if let colorLineVertexFn = library.makeFunction(name: "vertex_line_colored"), let fillFragmentFn = library.makeFunction(name: "fragment_collision_fill") {
            let fillDescriptor = MTLRenderPipelineDescriptor()
            fillDescriptor.vertexFunction = colorLineVertexFn
            fillDescriptor.fragmentFunction = fillFragmentFn
            fillDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            fillDescriptor.depthAttachmentPixelFormat = .depth32Float
            collisionFillPipelineState = try? device.makeRenderPipelineState(descriptor: fillDescriptor)
        } else {
            collisionFillPipelineState = nil
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        self.depthState = depthState

        let translucentDepthDescriptor = MTLDepthStencilDescriptor()
        translucentDepthDescriptor.depthCompareFunction = .less
        translucentDepthDescriptor.isDepthWriteEnabled = false
        guard let translucentDepthState = device.makeDepthStencilState(descriptor: translucentDepthDescriptor) else { return nil }
        self.translucentDepthState = translucentDepthState

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.samplerState = samplerState

        guard let fallback = ModelViewerRenderer.makeSolidTexture(device: device, rgba: (255, 255, 255, 255)) else { return nil }
        self.fallbackTexture = fallback
    }
}

/// How the Collision Viewer colors wireframe edges (blueprint 4.1,
/// "Collision Mesh & Trigger Overlays"). `bySurfaceID` distinguishes raw
/// `CollisionTriangle.surfaceID` values from each other visually, it is
/// deliberately *not* the blueprint's literal "Red = Death, Green = Trigger,
/// Blue = Solid" scheme, because this codebase has no verified mapping from
/// a surface ID to that kind of semantic category (the undecoded
/// `CollisionSurface` record and `Object`/`Script` layer are where that
/// classification would actually live, see `CollisionTriangle`'s doc
/// comment). Coloring by the real, decoded ID is still genuinely useful
/// (it makes distinct physical-material regions visually obvious) without
/// asserting something unverified.
public enum CollisionColorMode: Sendable {
    case solid
    case bySurfaceID
}

/// Drives the Model Viewer's `MTKView`: uploads a `ResolvedModelAsset`'s
/// geometry and textures to the GPU once, then renders it every frame with
/// simple directional + ambient lighting and an orbit camera.
///
/// Deliberately renders the mesh in its bind pose only, see
/// `AnimationPlaybackController` for why animation playback here drives a
/// skeleton joint visualization rather than deforming these vertices.
final class ModelViewerRenderer: NSObject, MTKViewDelegate {
    private let context: ModelViewerGPUContext
    var device: MTLDevice { context.device }

    /// "Shader Graph Editor" (roadmap 5.4): when set, the main mesh draw
    /// uses this pipeline instead of `context.pipelineState`, an
    /// instance-level override, never touching the shared singleton other
    /// renderer instances (Model Hub thumbnails, Level Viewer previews,
    /// ...) still draw with. `applyShaderGraph` builds this from real
    /// compiled MSL; `clearShaderGraphOverride` reverts to the default.
    private var customPipelineState: MTLRenderPipelineState?

    enum ShaderGraphApplyError: Error {
        case compileFailed(String)
        case functionNotFound
        case pipelineCreationFailed
    }

    /// Compiles `mslFragmentSource` (real MSL emitted by
    /// `ShaderGraphCompiler.compile`) alongside the base shader library's
    /// existing `vertex_main`/struct declarations, builds a real pipeline
    /// state reusing the exact same vertex descriptor/blend/pixel-format
    /// setup `ModelViewerGPUContext`'s default pipeline uses, and swaps it
    /// in for this renderer instance's main mesh draw.
    func applyShaderGraph(mslFragmentSource: String, functionName: String) -> Result<Void, ShaderGraphApplyError> {
        let combinedSource = Self.shaderSource + "\n" + mslFragmentSource
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: combinedSource, options: nil)
        } catch {
            return .failure(.compileFailed(error.localizedDescription))
        }
        guard let vertexFn = library.makeFunction(name: "vertex_main"), let fragmentFn = library.makeFunction(name: functionName) else {
            return .failure(.functionNotFound)
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.stride * 3
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = MemoryLayout<Float>.stride * 6
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .float4
        vertexDescriptor.attributes[3].offset = MemoryLayout<Float>.stride * 8
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<ModelVertexGPU>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFn
        pipelineDescriptor.fragmentFunction = fragmentFn
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        guard let newPipeline = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            return .failure(.pipelineCreationFailed)
        }
        customPipelineState = newPipeline
        return .success(())
    }

    func clearShaderGraphOverride() {
        customPipelineState = nil
    }

    private var submeshes: [GPUSubmesh] = []
    private var boundsCenter: SIMD3<Float> = .zero
    private var boundsRadius: Float = 1

    /// Camera orbit state, driven by `InteractiveMTKView`'s mouse handling.
    var yaw: Float = .pi * 0.25
    var pitch: Float = .pi * 0.15
    /// "Zoom Clamp": floored so a fast/large scroll delta
    /// (`InteractiveMTKView.scrollWheel` subtracts its raw delta with no
    /// clamp of its own) can't drive this to zero or negative.
    /// `orbitEyeWorldPosition` places the eye at `target + boundsRadius *
    /// distanceMultiplier` along the orbit direction, a negative
    /// multiplier doesn't stop at the target, it flips the eye through to
    /// the opposite side of it in one frame, which is exactly the
    /// reported "zooming in too far/fast sends me through the map"
    /// symptom (the camera teleports past whatever it was orbiting, not a
    /// gradual clip).
    ///
    /// Regression fix: the floor used to be a fixed *multiplier* value , 
    /// but the same multiplier corresponds to a wildly different absolute
    /// distance depending on `boundsRadius`, so for a large scene it
    /// silently overrode `focusOnSelected`'s own much smaller, deliberate
    /// multiplier when framing a small object closely, defeating "Double-
    /// Click to Focus" for exactly the case it exists for. The floor is
    /// now expressed as a minimum *absolute* world-space distance instead
    /// (`minAbsoluteDistance`), converted to whatever multiplier
    /// currently corresponds to it for this scene's own `boundsRadius` , 
    /// so it still stops a runaway scroll from crossing through the
    /// target, without capping how close a deliberate, small-object focus
    /// can get.
    var distanceMultiplier: Float = 2.4 {
        // Guarded, not an unconditional `max()` reassignment: Swift fires
        // `didSet` again on every assignment regardless of whether the
        // value actually changed, so an unconditional self-reassignment
        // here would recurse forever the moment the floor is hit. Only
        // writing back when actually out of range terminates after one
        // extra call (the second firing sees the already-clamped value
        // and takes this branch's `false` path).
        didSet {
            let floor = Self.minDistanceMultiplier(forBoundsRadius: boundsRadius)
            if distanceMultiplier < floor { distanceMultiplier = floor }
        }
    }
    /// The zoom floor's real, scene-scale-independent quantity, see
    /// `distanceMultiplier`'s own doc comment.
    static let minAbsoluteDistance: Float = 0.5
    static func minDistanceMultiplier(forBoundsRadius boundsRadius: Float) -> Float {
        boundsRadius > 0.0001 ? minAbsoluteDistance / boundsRadius : 0.05
    }

    /// Optional skeleton overlay, drawn as connected line segments between
    /// joints. Set by `AnimationPlaybackController` as playback advances.
    ///
    /// `didSet` rebuilds `skeletonLineBuffer` right here, once, instead of
    /// `draw(in:)` calling `device.makeBuffer` from scratch on every single
    /// rendered frame (this view renders continuously at 20 fps, see
    /// `MetalModelView`, regardless of whether this array actually changed
    /// since the last frame). Scrubbing an animation still rebuilds the
    /// buffer exactly as often as the joint positions actually change; it's
    /// the ~20/sec redundant rebuilds *between* scrub events that this cuts.
    var skeletonJointWorldPositions: [(SIMD3<Float>, SIMD3<Float>)] = [] {
        didSet { skeletonLineBuffer = Self.makeLineBuffer(device: device, segments: skeletonJointWorldPositions) }
    }
    private var skeletonLineBuffer: MTLBuffer?

    /// "Collision Mask Alignment": the real per-object `GI_CollisionData`
    /// box(es) for the currently-shown asset (`ResolvedModelAsset.skeleton?
    /// .collisionData`), drawn as orange wireframe boxes in the *same*
    /// model-space transform as the mesh itself, since these corner
    /// points are already stored in the object's own local/bind space
    /// (verified against real data: they come out as clean ± min/max
    /// triples, e.g. exactly `±0.6` on every axis), no separate alignment
    /// transform is needed here at all; drawing them through the model's
    /// own `modelViewProjection` uniform *is* the correct alignment.
    var collisionVolumeWorldPositions: [(SIMD3<Float>, SIMD3<Float>)] = [] {
        didSet {
            collisionVolumeLineBuffer = Self.makeColoredLineBuffer(
                device: device, segments: collisionVolumeWorldPositions,
                colors: [SIMD3<Float>](repeating: SIMD3(0.95, 0.6, 0.1), count: collisionVolumeWorldPositions.count)
            )
        }
    }
    private var collisionVolumeLineBuffer: MTLBuffer?

    /// "Procedural Collision Decimation" (roadmap 4.4): the real, computed
    /// oriented bounding box from `CollisionDecimator`, drawn as a cyan
    /// wireframe in the same model-space transform as the mesh (same
    /// reasoning as `collisionVolumeWorldPositions` above, no separate
    /// alignment needed, the corners are already in the mesh's own local
    /// space). Distinct color/buffer from the real `GI_CollisionData`
    /// overlay so a user can tell "decoded from the game" apart from
    /// "computed by this tool" at a glance.
    var proceduralOBBWorldPositions: [(SIMD3<Float>, SIMD3<Float>)] = [] {
        didSet {
            proceduralOBBLineBuffer = Self.makeColoredLineBuffer(
                device: device, segments: proceduralOBBWorldPositions,
                colors: [SIMD3<Float>](repeating: SIMD3(0.3, 0.85, 0.95), count: proceduralOBBWorldPositions.count)
            )
        }
    }
    private var proceduralOBBLineBuffer: MTLBuffer?

    /// "Local Physics & Collision Playground" (roadmap 12.1): a wireframe
    /// sphere (three orthogonal circles) at `PhysicsPlayground`'s current
    /// world-space ball position, drawn with the same colored-line
    /// machinery as `collisionVolumeWorldPositions`/`proceduralOBBWorldPositions`
    /// above, the ball is a real, locally-simulated object, not decoded
    /// game data or a computed analysis result, so it gets its own color
    /// to stay visually distinct from both.
    var physicsBallWorldPositions: [(SIMD3<Float>, SIMD3<Float>)] = [] {
        didSet {
            physicsBallLineBuffer = Self.makeColoredLineBuffer(
                device: device, segments: physicsBallWorldPositions,
                colors: [SIMD3<Float>](repeating: SIMD3(1.0, 0.9, 0.2), count: physicsBallWorldPositions.count)
            )
        }
    }
    private var physicsBallLineBuffer: MTLBuffer?

    /// "Granular Component Visibility": submesh indices (matching
    /// `ResolvedModelAsset.mesh.submeshes`/`.submeshMaterials`) to skip
    /// during the draw pass. Indices, not identity, because that's the
    /// granularity a submesh actually exists at on the GPU side, there's
    /// no separate "hide this texture" primitive, just "don't draw the
    /// submesh(es) that use it" (see `ComponentVisibilityView`).
    var hiddenSubmeshIndices: Set<Int> = []

    /// "Target Hardware Performance Profiler" (roadmap 9.4): the real
    /// triangle count this frame actually draws, summed straight from
    /// each currently-visible submesh's real index count (`indexCount / 3`,
    /// since every submesh is drawn as a plain triangle list), not a
    /// separate counter threaded through `encode(...)`. Derived, not
    /// tracked, so it can never drift from what the render loop actually
    /// does.
    var visibleTriangleCount: Int {
        submeshes.reduce(0) { hiddenSubmeshIndices.contains($1.originalIndex) ? $0 : $0 + $1.indexCount / 3 }
    }

    /// One draw call per visible submesh, `encode(...)`'s real draw loop,
    /// mirrored here rather than counted inside it.
    var visibleDrawCallCount: Int {
        submeshes.reduce(0) { hiddenSubmeshIndices.contains($1.originalIndex) ? $0 : $0 + 1 }
    }

    /// The real GPU memory Metal itself reports for every buffer/texture
    /// this asset currently has uploaded (`MTLResource.allocatedSize` , 
    /// the actual allocated size, not a computed estimate from vertex/
    /// pixel counts that could drift from reality under padding/alignment
    /// the GPU driver applies). Includes hidden submeshes too: their GPU
    /// resources stay allocated even while not drawn.
    var gpuMemoryBytes: Int {
        submeshes.reduce(0) { $0 + $1.vertexBuffer.allocatedSize + $1.indexBuffer.allocatedSize + $1.texture.allocatedSize }
    }

    /// Collision wireframe edges (blue), set when this renderer was built
    /// from a `CollisionMesh` rather than a `ResolvedModelAsset`. Drawn with
    /// the same line pipeline machinery as the skeleton overlay, just a
    /// separate pipeline state so the two don't fight over fragment color.
    private var collisionEdgeWorldPositions: [(SIMD3<Float>, SIMD3<Float>)] = []
    /// One color per entry in `collisionEdgeWorldPositions`, derived from
    /// that edge's triangle's raw `surfaceID` (see `CollisionColorMode`'s
    /// doc comment for why this is the raw ID, not an invented semantic
    /// category like "deadly"/"solid").
    private var collisionEdgeColors: [SIMD3<Float>] = []
    public var collisionColorMode: CollisionColorMode = .solid
    /// Both buffers below are built once in `upload(collisionMesh:)` and
    /// reused for the mesh's whole lifetime, collision geometry never
    /// changes after load (unlike the skeleton overlay), so rebuilding
    /// either from scratch every frame (the previous behavior) bought
    /// nothing; `collisionColorMode` just picks which cached buffer
    /// `draw(in:)` binds.
    private var collisionLineBuffer: MTLBuffer?
    private var collisionLineColoredBuffer: MTLBuffer?
    /// Every distinct raw `surfaceID` found in the currently loaded
    /// collision mesh, in first-seen order, backs the legend in
    /// `CollisionViewerWindow`.
    public private(set) var collisionSurfaceIDs: [Int] = []

    init?(asset: ResolvedModelAsset) {
        guard let context = ModelViewerGPUContext.shared else { return nil }
        self.context = context
        super.init()
        upload(asset: asset)
    }

    /// Wireframe-only path for "Collision Viewing": no textured submeshes,
    /// just every collision triangle's three edges drawn as lines, with the
    /// orbit camera framed from the collision mesh's own vertex bounds
    /// rather than a `ResolvedModelAsset`'s. Shared edges between adjacent
    /// triangles aren't deduplicated, each triangle contributes its own 3
    /// edges, which draws every internal edge twice; visually harmless
    /// (identical overlapping line segments) and far simpler than an
    /// edge-adjacency pass, which isn't needed for a first working overlay.
    init?(collisionMesh: CollisionMesh) {
        guard let context = ModelViewerGPUContext.shared else { return nil }
        self.context = context
        super.init()
        upload(collisionMesh: collisionMesh)
    }

    private func upload(collisionMesh: CollisionMesh) {
        guard !collisionMesh.vertices.isEmpty else { return }
        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var edges: [(SIMD3<Float>, SIMD3<Float>)] = []
        var colors: [SIMD3<Float>] = []
        edges.reserveCapacity(collisionMesh.triangles.count * 3)
        colors.reserveCapacity(collisionMesh.triangles.count * 3)
        var seenSurfaceIDs: [Int] = []
        var seenSurfaceIDSet: Set<Int> = []

        // "Coordinate-System Overhaul": the reference tool's `LoadColTree`
        // (`RMViewer.cs`) negates every raw vertex's X (`v.X = -v.X;`)
        // before rendering, the same world-space X mirror `LoadSceneryModel`
        // applies to scenery and `LoadInstances` applies to every instance/
        // trigger/camera position. `CollisionMesh.vertices` themselves stay
        // raw (there's a real write-back path, `ColDataWriter.write`, used
        // by `ColDataEditorSheet`, that round-trips them byte-identical to
        // disk), so the mirror is applied here, at the render boundary, not
        // baked into the decoded struct.
        func point(_ index: Int) -> SIMD3<Float>? {
            guard collisionMesh.vertices.indices.contains(index) else { return nil }
            let v = collisionMesh.vertices[index]
            return SIMD3(-v.x, v.y, v.z)
        }

        for triangle in collisionMesh.triangles {
            guard let a = point(triangle.vertexIndex1),
                  let b = point(triangle.vertexIndex2),
                  let c = point(triangle.vertexIndex3) else { continue }
            edges.append((a, b))
            edges.append((b, c))
            edges.append((c, a))
            let color = Self.color(forSurfaceID: triangle.surfaceID)
            colors.append(contentsOf: [color, color, color])
            if seenSurfaceIDSet.insert(triangle.surfaceID).inserted {
                seenSurfaceIDs.append(triangle.surfaceID)
            }
        }

        for v in collisionMesh.vertices {
            let p = SIMD3(-v.x, v.y, v.z)
            minBound = simd_min(minBound, p)
            maxBound = simd_max(maxBound, p)
        }

        collisionEdgeWorldPositions = edges
        collisionEdgeColors = colors
        collisionSurfaceIDs = seenSurfaceIDs
        collisionLineBuffer = Self.makeLineBuffer(device: device, segments: edges)
        collisionLineColoredBuffer = Self.makeColoredLineBuffer(device: device, segments: edges, colors: colors)
        if minBound.x <= maxBound.x {
            boundsCenter = (minBound + maxBound) / 2
            let extent = maxBound - minBound
            boundsRadius = max(max(extent.x, extent.y), max(extent.z, 1))
        }
    }

    /// Shared by the skeleton overlay and the solid-color collision
    /// wireframe: `count * 2` `packed_float3` positions (one pair per
    /// segment), matching `vertex_line`'s expected buffer layout exactly.
    private static func makeLineBuffer(device: MTLDevice, segments: [(SIMD3<Float>, SIMD3<Float>)]) -> MTLBuffer? {
        guard !segments.isEmpty else { return nil }
        var floats: [Float] = []
        floats.reserveCapacity(segments.count * 6)
        for (a, b) in segments {
            floats.append(contentsOf: [a.x, a.y, a.z, b.x, b.y, b.z])
        }
        return device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    /// Interleaved position+color buffer for the by-surface-ID collision
    /// wireframe, matching `vertex_line_colored`'s `LineVertexColorIn`
    /// layout (`packed_float3` position, `packed_float3` color, back to
    /// back, see that shader's doc comment).
    /// "Collision Mask Alignment": box-edge line segments spanning the
    /// axis-aligned bounds of `corners`, not assuming any particular
    /// ordering of the input points (verified against real data as clean
    /// ± min/max triples, but not a confirmed corner-winding order), just
    /// their overall extent, which is exactly what "a box that encapsulates
    /// this" needs regardless of how the 8 points happen to be ordered on
    /// disk.
    static func collisionBoxEdges(corners: [SIMD4<Float>]) -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard !corners.isEmpty else { return [] }
        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for c in corners {
            let p = SIMD3(c.x, c.y, c.z)
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let c000 = SIMD3(minP.x, minP.y, minP.z), c100 = SIMD3(maxP.x, minP.y, minP.z)
        let c010 = SIMD3(minP.x, maxP.y, minP.z), c110 = SIMD3(maxP.x, maxP.y, minP.z)
        let c001 = SIMD3(minP.x, minP.y, maxP.z), c101 = SIMD3(maxP.x, minP.y, maxP.z)
        let c011 = SIMD3(minP.x, maxP.y, maxP.z), c111 = SIMD3(maxP.x, maxP.y, maxP.z)
        return [
            (c000, c100), (c100, c110), (c110, c010), (c010, c000),
            (c001, c101), (c101, c111), (c111, c011), (c011, c001),
            (c000, c001), (c100, c101), (c110, c111), (c010, c011)
        ]
    }

    /// "Procedural Collision Decimation" (roadmap 4.4): the 12 edges of a
    /// real, computed oriented bounding box, unlike `collisionBoxEdges`,
    /// this draws the box's *actual* oriented corners directly (no
    /// re-AABB'ing), since `CollisionDecimator`'s corners are already the
    /// real box this tool computed, not on-disk points of unconfirmed
    /// ordering.
    static func orientedBoxEdges(corners: [SIMD3<Float>]) -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard corners.count == 8 else { return [] }
        return [
            (corners[0], corners[1]), (corners[1], corners[2]), (corners[2], corners[3]), (corners[3], corners[0]),
            (corners[4], corners[5]), (corners[5], corners[6]), (corners[6], corners[7]), (corners[7], corners[4]),
            (corners[0], corners[4]), (corners[1], corners[5]), (corners[2], corners[6]), (corners[3], corners[7])
        ]
    }

    /// "Local Physics & Collision Playground" (roadmap 12.1): three
    /// orthogonal circles (XY/XZ/YZ planes) approximating a wireframe
    /// sphere at `center`, the standard, cheap way to visualize a sphere
    /// with line-list geometry (no filled-sphere pipeline needed).
    static func sphereEdges(center: SIMD3<Float>, radius: Float, segments: Int = 24) -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard radius > 0, segments >= 3 else { return [] }
        var result: [(SIMD3<Float>, SIMD3<Float>)] = []
        result.reserveCapacity(segments * 3)
        for i in 0..<segments {
            let angle1 = 2 * Float.pi * Float(i) / Float(segments)
            let angle2 = 2 * Float.pi * Float(i + 1) / Float(segments)
            let (s1, c1) = (sin(angle1), cos(angle1))
            let (s2, c2) = (sin(angle2), cos(angle2))
            result.append((center + radius * SIMD3(c1, s1, 0), center + radius * SIMD3(c2, s2, 0))) // XY
            result.append((center + radius * SIMD3(c1, 0, s1), center + radius * SIMD3(c2, 0, s2))) // XZ
            result.append((center + radius * SIMD3(0, c1, s1), center + radius * SIMD3(0, c2, s2))) // YZ
        }
        return result
    }

    private static func makeColoredLineBuffer(device: MTLDevice, segments: [(SIMD3<Float>, SIMD3<Float>)], colors: [SIMD3<Float>]) -> MTLBuffer? {
        guard !segments.isEmpty, segments.count == colors.count else { return nil }
        var floats: [Float] = []
        floats.reserveCapacity(segments.count * 12)
        for (index, edge) in segments.enumerated() {
            let color = colors[index]
            floats.append(contentsOf: [edge.0.x, edge.0.y, edge.0.z, color.x, color.y, color.z])
            floats.append(contentsOf: [edge.1.x, edge.1.y, edge.1.z, color.x, color.y, color.z])
        }
        return device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    /// "Automatic Collision Generation": creates a basic oriented bounding box (OBB)
    /// collision volume from a mesh's vertices when the asset lacks existing collision data.
    /// This ensures objects have collision volumes for gameplay even when the original
    /// asset doesn't provide them.
    /// - Parameter mesh: The mesh to generate collision data from
    /// - Parameter device: The Metal device to use for computation
    /// - Returns: An array containing the generated collision data, or empty if generation failed
    static func generateCollisionDataFromMesh(mesh: MeshAsset, device: MTLDevice) -> [GraphicsInfoCollisionData] {
        // Use the existing CollisionDecimator to compute an OBB from the mesh
        guard let obb = CollisionDecimator.computeOrientedBoundingBox(mesh: mesh, device: device) else {
            return [] // Return empty if we can't compute the OBB
        }

        // Convert the OBB corners to the format expected by GraphicsInfoCollisionData
        // The positions should be in the object's local space (which they already are from CollisionDecimator)
        let obbCorners = obb.corners

        // Create a minimal GraphicsInfoCollisionData header that represents an OBB
        // Based on the reference tool's interpretation, we need at least:
        // - header[0] = 8 (number of positions)
        // - followed by the 8 corner positions as Vector4 (w=1.0 for positions)
        // - minimal rawBlobRemainder (can be empty for basic OBB)

        let header: [UInt16] = [8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] // 8 positions, rest zeroed for minimal valid header
        let positions: [SIMD4<Float>] = obbCorners.map { SIMD4($0.x, $0.y, $0.z, 1.0) }

        return [GraphicsInfoCollisionData(header: header, positions: positions, rawBlobRemainder: Data())]
    }

    /// Real, reported bug ("moved objects and scenery, pressed Update
    /// Collision, nothing changed" / "placed scenery has no collision, I
    /// phase through it"): every *existing*, already-on-disk scenery and
    /// Instance placement loaded a level with `generatedCollisionData: []`
    /// hardcoded (Instances) or simply omitted, defaulting to `[]`
    /// (Scenery), never calling `generateCollisionDataFromMesh` the way a
    /// freshly session-*placed* object does. `computingRebuiltCollisionRecord`
    /// silently skips any object whose `collisionData` is empty (`guard
    /// !collisionData.isEmpty else { continue }`), for both the automatic
    /// "new object" addition path *and* the opt-in "moved object" sync
    /// path, so this wasn't a heuristic being wrong, it was every real,
    /// already-placed object never having any collision data to add or
    /// relocate at all.
    ///
    /// This is the same real fallback `generateCollisionDataFromMesh`
    /// already establishes for a *newly*-placed object, just computed
    /// without that function's expensive per-call Metal shader compile +
    /// GPU compute-and-sync round trip (`CollisionDecimator.
    /// computeOrientedBoundingBox`, real, measured cost, fine for the one
    /// object a placement click spawns, not for the few hundred existing
    /// placements a real level loads at once, which is exactly the
    /// "freeze on open" bug class this same session already fixed more
    /// than once elsewhere). `Self.localBounds(of:)` is already computed
    /// for *every* placement during level load regardless (pure CPU
    /// vertex min/max, no GPU work), this just reuses that instead of
    /// computing a tighter oriented box. The two aren't equivalent in
    /// general (an axis-aligned local box is looser than a true OBB for a
    /// mesh that isn't itself axis-aligned in local space), but every real
    /// consumer of this data (`computingRebuiltCollisionRecord`'s
    /// `worldBoxes`, the "Show Collision Volume" overlay) immediately
    /// transforms these 8 corners to world space and reduces them to an
    /// axis-aligned world-space box anyway, so the only real difference
    /// is a possibly-slightly-larger box, never a wrong position, and
    /// never a missing one.
    static func collisionDataFromLocalBounds(min: SIMD3<Float>, max: SIMD3<Float>) -> [GraphicsInfoCollisionData] {
        guard max.x >= min.x, max.y >= min.y, max.z >= min.z else { return [] }
        let header: [UInt16] = [8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let positions: [SIMD4<Float>] = [
            SIMD4(min.x, min.y, min.z, 1), SIMD4(max.x, min.y, min.z, 1),
            SIMD4(min.x, max.y, min.z, 1), SIMD4(max.x, max.y, min.z, 1),
            SIMD4(min.x, min.y, max.z, 1), SIMD4(max.x, min.y, max.z, 1),
            SIMD4(min.x, max.y, max.z, 1), SIMD4(max.x, max.y, max.z, 1),
        ]
        return [GraphicsInfoCollisionData(header: header, positions: positions, rawBlobRemainder: Data())]
    }

    /// "Hug the mesh, not just its bounding box", real, reported feedback:
    /// a single AABB around a tall, irregular object (a totem, a thin
    /// pillar with a wide base) is a bad fit, the box's own empty corners
    /// read as solid ground the object's real silhouette never occupies.
    ///
    /// Adaptive, not a fixed slice count: this is a real PS2 game, every
    /// extra box is real triangle/vertex budget spent on every single
    /// scenery object in a level, and real, reported feedback is explicit
    /// that most scenery genuinely *is* one simple object and should stay
    /// exactly one box. Starts at one box (the whole mesh's own tight
    /// AABB) and only adds another horizontal Y-slice while doing so
    /// meaningfully tightens the total fit (>8% less wasted volume than
    /// the previous slice count), a boxy rock stays a single box; a
    /// genuinely tapering totem/pillar earns more, up to `maxSliceCount`,
    /// only as far as it keeps paying for itself. Every real consumer of
    /// this data already treats each `GraphicsInfoCollisionData` entry as
    /// one independent box (`collisionDataFromLocalBounds`'s own doc
    /// comment), so returning several here needs no change anywhere
    /// downstream.
    ///
    /// Falls back to `collisionDataFromLocalBounds`'s single-box behavior
    /// for a mesh with no real Y extent (flat/degenerate), a real, if
    /// imperfect, fallback beats silently returning nothing.
    static func collisionDataHuggingMesh(mesh: MeshAsset, maxSliceCount: Int = 6) -> [GraphicsInfoCollisionData] {
        var vertices: [SIMD3<Float>] = []
        for submesh in mesh.submeshes {
            for vertex in submesh.vertices { vertices.append(vertex.position) }
        }
        guard !vertices.isEmpty else { return [] }

        var wholeMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var wholeMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in vertices { wholeMin = simd_min(wholeMin, v); wholeMax = simd_max(wholeMax, v) }
        let minY = wholeMin.y, maxY = wholeMax.y
        guard minY.isFinite, maxY.isFinite, maxY > minY else {
            return collisionDataFromLocalBounds(min: wholeMin, max: wholeMax)
        }

        func boxesAndVolume(forSliceCount sliceCount: Int) -> (boxes: [(min: SIMD3<Float>, max: SIMD3<Float>)], volume: Float) {
            guard sliceCount > 1 else {
                let size = wholeMax - wholeMin
                return ([(wholeMin, wholeMax)], size.x * size.y * size.z)
            }
            let sliceHeight = (maxY - minY) / Float(sliceCount)
            var boxes: [(min: SIMD3<Float>, max: SIMD3<Float>)] = []
            var totalVolume: Float = 0
            for i in 0..<sliceCount {
                let bandMin = minY + Float(i) * sliceHeight
                let bandMax = i == sliceCount - 1 ? maxY : bandMin + sliceHeight
                var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                var foundAny = false
                for v in vertices where v.y >= bandMin && v.y <= bandMax {
                    foundAny = true
                    minP = simd_min(minP, v)
                    maxP = simd_max(maxP, v)
                }
                guard foundAny else { continue }
                boxes.append((minP, maxP))
                let size = maxP - minP
                totalVolume += size.x * size.y * size.z
            }
            return (boxes, totalVolume)
        }

        var best = boxesAndVolume(forSliceCount: 1)
        if maxSliceCount > 1 {
            for sliceCount in 2...maxSliceCount {
                let candidate = boxesAndVolume(forSliceCount: sliceCount)
                guard candidate.volume > 0, best.volume > 0 else { break }
                let improvement = 1 - (candidate.volume / best.volume)
                guard improvement > 0.08 else { break } // diminishing returns
                best = candidate
            }
        }

        var results: [GraphicsInfoCollisionData] = []
        for box in best.boxes {
            results.append(contentsOf: collisionDataFromLocalBounds(min: box.min, max: box.max))
        }
        return results.isEmpty ? collisionDataFromLocalBounds(min: wholeMin, max: wholeMax) : results
    }

    /// "Model Viewer & Animation Playback": deforms every skinned submesh's
    /// GPU vertex buffer *in place* (no reallocation, same reasoning as
    /// `skeletonJointWorldPositions`'s own doc comment) to the real,
    /// verified pose at `frameIndex`, see `AnimationSkeletonBinding`'s doc
    /// comment for where this math actually comes from. Always re-skins
    /// from each submesh's own retained bind-space vertices
    /// (`GPUSubmesh.bindVertices`), never from whatever the buffer
    /// currently holds, so scrubbing back and forth never compounds error.
    /// A submesh with no joint weight data (rigid, non-skinned) is left
    /// completely untouched, its buffer was already correct at upload and
    /// nothing here has any basis to change it.
    func applySkeletalPose(skeleton: SkeletonAsset, track: AnimationTrack, frameIndex: Int) {
        let skinning = AnimationSkeletonBinding.skinningMatrices(skeleton: skeleton, track: track, frame: frameIndex)
        for submesh in submeshes {
            guard !submesh.jointWeights.isEmpty else { continue }
            Self.skinVertices(submesh: submesh, skinningMatrices: skinning)
        }
    }

    /// "Procedural Animation Frame Blending" (roadmap 12.2), same
    /// deformation path as `applySkeletalPose`, fed
    /// `AnimationSkeletonBinding.blendedSkinningMatrices` instead of a
    /// single (track, frame) pair. `trackB`/`frameB` can be a different
    /// point in the same clip or an entirely different animation.
    func applyBlendedSkeletalPose(skeleton: SkeletonAsset, trackA: AnimationTrack, frameA: Int, trackB: AnimationTrack, frameB: Int, t: Float) {
        let skinning = AnimationSkeletonBinding.blendedSkinningMatrices(skeleton: skeleton, trackA: trackA, frameA: frameA, trackB: trackB, frameB: frameB, t: t)
        for submesh in submeshes {
            guard !submesh.jointWeights.isEmpty else { continue }
            Self.skinVertices(submesh: submesh, skinningMatrices: skinning)
        }
    }

    /// Restores every skinned submesh to its original bind-pose geometry , 
    /// called when animation playback stops/resets, or no animation is
    /// selected.
    func resetToBindPose() {
        for submesh in submeshes {
            guard !submesh.jointWeights.isEmpty else { continue }
            Self.writeVertices(submesh.bindVertices, into: submesh.vertexBuffer)
        }
    }

    /// Reads back every vertex position of the first skinned submesh
    /// directly from GPU memory, used by `RealDiscDiagnosticTests` to
    /// verify skeletal deformation actually reaches the vertex buffer
    /// (not just that `AnimationSkeletonBinding` computes different
    /// matrices per frame, which a rendering/write-back bug could still
    /// leave invisible, see that fix's own commit for how this caught
    /// exactly that).
    func debugAllSkinnedVertexPositions() -> [SIMD3<Float>] {
        guard let submesh = submeshes.first(where: { !$0.jointWeights.isEmpty }) else { return [] }
        let stride = MemoryLayout<ModelVertexGPU>.stride
        let vertexCount = submesh.vertexBuffer.length / stride
        let ptr = submesh.vertexBuffer.contents().bindMemory(to: ModelVertexGPU.self, capacity: vertexCount)
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(vertexCount)
        for i in 0..<vertexCount {
            let v = ptr[i]
            result.append(SIMD3(v.px, v.py, v.pz))
        }
        return result
    }

    /// Weighted-blend skinning: each vertex's position/normal is the sum of
    /// up to 4 joint influences (`StaticVertex.color`'s parallel
    /// `jointIndices`/`jointWeights`, "up to 3 active joints per vertex,
    /// padded to 4 lanes," see `MeshSubmesh`'s own doc comment), each joint
    /// contributing `weight * (skinningMatrix * bindSpacePosition)`. Normals
    /// use the same matrix's upper-left 3x3 (rotation/scale, no
    /// translation), the standard real-time-skinning approximation; it
    /// doesn't correct for non-uniform-scale shearing, which no renderer in
    /// this codebase claims to handle anywhere else either.
    // Not `private`, see `GPUSubmesh`'s own doc comment for why: a
    // synthetic regression test needs to call this directly with a
    // hand-built submesh and a deliberately incomplete `skinningMatrices`
    // dictionary, without standing up a full skeleton/animation pipeline.
    static func skinVertices(submesh: GPUSubmesh, skinningMatrices: [UInt32: simd_float4x4]) {
        var gpuVertices: [ModelVertexGPU] = []
        gpuVertices.reserveCapacity(submesh.bindVertices.count)
        for (i, v) in submesh.bindVertices.enumerated() {
            var skinnedPosition = SIMD3<Float>.zero
            var skinnedNormal = SIMD3<Float>.zero
            // "Animation Player" fix: whether *any* lane actually found a
            // weighted joint influence, the only correct signal for "did
            // real skinning happen here." The blended normal's own
            // magnitude used to stand in for this, but `SkinParser` never
            // decodes real per-vertex normals for skin meshes (they're
            // hard-coded to `.zero` there, a separate, pre-existing gap),
            // so `rotationScale * v.normal` is always the zero vector
            // regardless of whether position skinning succeeded. That made
            // this check misfire 100% of the time for every skinned
            // character, silently discarding the correctly-computed
            // `skinnedPosition` and reverting every vertex back to bind
            // pose every frame, animations decoded and computed correct,
            // per-joint-varying matrices, but nothing ever visibly moved.
            var totalWeight: Float = 0
            if i < submesh.jointIndices.count, i < submesh.jointWeights.count {
                let indices = submesh.jointIndices[i]
                let weights = submesh.jointWeights[i]
                for lane in 0..<4 {
                    let weight = weights[lane]
                    guard weight > 0 else { continue }
                    guard let matrix = skinningMatrices[UInt32(indices[lane])] else { continue }
                    let pos4 = matrix * SIMD4(v.position, 1)
                    skinnedPosition += weight * SIMD3(pos4.x, pos4.y, pos4.z)
                    let rotationScale = simd_float3x3(
                        SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                        SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                        SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
                    )
                    skinnedNormal += weight * (rotationScale * v.normal)
                    totalWeight += weight
                }
            }
            if totalWeight < 0.0001 {
                // No real joint influence found for this vertex (missing
                // weights, or every referenced joint fell outside this
                // frame's skinning matrices), leave it exactly at bind
                // pose rather than collapsing it to the origin.
                skinnedPosition = v.position
                skinnedNormal = v.normal
            } else {
                // Linear blend skinning is a weighted *average*, not a
                // weighted sum: divide by the weight actually applied
                // rather than assuming it already summed to 1. Source
                // weights normally do sum to ~1, so this is a no-op in the
                // common case, but `skinningMatrices` is a
                // `[UInt32: simd_float4x4]` dictionary, and any lane whose
                // joint index has no entry (an unresolved/out-of-range
                // joint for this frame) gets silently skipped by the
                // `guard let matrix = ...` above, leaving `totalWeight`
                // short of 1 for that vertex specifically. Without this
                // divide, that vertex's position is scaled down toward the
                // coordinate origin by exactly the missing fraction , 
                // every affected vertex pulled toward (0,0,0), which is
                // the "model scrunches into a ball" symptom.
                skinnedPosition /= totalWeight
                if simd_length(skinnedNormal) > 0.0001 {
                    skinnedNormal = simd_normalize(skinnedNormal)
                }
                // Defense in depth against a NaN/Inf skinning matrix (e.g.
                // a joint whose real on-disk bind-pose data is degenerate
                //, see `AnimationSkeletonBinding.safeQuaternion`'s doc
                // comment for the specific case this was found from):
                // `totalWeight` being valid only proves a joint *weight*
                // was found, not that the matrix it was multiplied through
                // produced a finite result. Without this, one bad joint's
                // NaN silently reaches the GPU buffer and the entire mesh
                // renders as nothing, for every vertex weighted anywhere
                // in its subtree, not just the one joint that's actually
                // broken.
                if !skinnedPosition.x.isFinite || !skinnedPosition.y.isFinite || !skinnedPosition.z.isFinite {
                    skinnedPosition = v.position
                    skinnedNormal = v.normal
                }
            }
            // else: real influence found (skinnedPosition is valid), but
            // the blended normal came out ~zero because the source
            // normals are unpopulated for this format, leave
            // `skinnedNormal` at `.zero` rather than fabricating one;
            // lighting on skinned characters is a known, separate gap,
            // not something this fix invents a value for.
            gpuVertices.append(ModelVertexGPU(
                px: skinnedPosition.x, py: skinnedPosition.y, pz: skinnedPosition.z,
                nx: skinnedNormal.x, ny: skinnedNormal.y, nz: skinnedNormal.z,
                u: v.uv.x, v: v.uv.y,
                r: Float(v.color.x) / 255.0, g: Float(v.color.y) / 255.0,
                b: Float(v.color.z) / 255.0, a: Float(v.color.w) / 255.0
            ))
        }
        Self.writeVertices(gpuVertices, into: submesh.vertexBuffer)
    }

    private static func writeVertices(_ vertices: [StaticVertex], into buffer: MTLBuffer) {
        let gpuVertices = vertices.map {
            ModelVertexGPU(
                px: $0.position.x, py: $0.position.y, pz: $0.position.z,
                nx: $0.normal.x, ny: $0.normal.y, nz: $0.normal.z,
                u: $0.uv.x, v: $0.uv.y,
                r: Float($0.color.x) / 255.0, g: Float($0.color.y) / 255.0,
                b: Float($0.color.z) / 255.0, a: Float($0.color.w) / 255.0
            )
        }
        writeVertices(gpuVertices, into: buffer)
    }

    private static func writeVertices(_ gpuVertices: [ModelVertexGPU], into buffer: MTLBuffer) {
        guard !gpuVertices.isEmpty, buffer.length >= gpuVertices.count * MemoryLayout<ModelVertexGPU>.stride else { return }
        gpuVertices.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: raw.count)
        }
    }

    private func upload(asset: ResolvedModelAsset) {
        let built = Self.buildGPUSubmeshes(mesh: asset.mesh, submeshMaterials: asset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture)
        submeshes = built.submeshes
        let minBound = built.minBound
        let maxBound = built.maxBound
        if minBound.x <= maxBound.x {
            boundsCenter = (minBound + maxBound) / 2
            let extent = maxBound - minBound
            boundsRadius = max(max(extent.x, extent.y), max(extent.z, 1))
        }
    }

    /// Shared by `ModelViewerRenderer.upload(asset:)` and
    /// `LevelViewerRenderer` (which uploads many objects, each needing the
    /// exact same per-submesh vertex/index/texture upload), one GPU-upload
    /// implementation instead of two copies that could drift apart.
    fileprivate static func buildGPUSubmeshes(mesh: MeshAsset, submeshMaterials: [ResolvedSubmeshMaterial], device: MTLDevice, fallbackTexture: MTLTexture, textureCache: TextureUploadCache? = nil) -> (submeshes: [GPUSubmesh], minBound: SIMD3<Float>, maxBound: SIMD3<Float>) {
        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var gpuSubmeshes: [GPUSubmesh] = []

        for (index, submesh) in mesh.submeshes.enumerated() {
            guard !submesh.vertices.isEmpty else { continue }
            var gpuVertices: [ModelVertexGPU] = []
            gpuVertices.reserveCapacity(submesh.vertices.count)
            for v in submesh.vertices {
                minBound = simd_min(minBound, v.position)
                maxBound = simd_max(maxBound, v.position)
                gpuVertices.append(ModelVertexGPU(
                    px: v.position.x, py: v.position.y, pz: v.position.z,
                    nx: v.normal.x, ny: v.normal.y, nz: v.normal.z,
                    u: v.uv.x, v: v.uv.y,
                    r: Float(v.color.x) / 255.0, g: Float(v.color.y) / 255.0,
                    b: Float(v.color.z) / 255.0, a: Float(v.color.w) / 255.0
                ))
            }

            var indices: [UInt32] = []
            for (a, b, c) in submesh.triangleIndices() {
                indices.append(UInt32(a)); indices.append(UInt32(b)); indices.append(UInt32(c))
            }
            guard !indices.isEmpty,
                  let vertexBuffer = device.makeBuffer(bytes: gpuVertices, length: gpuVertices.count * MemoryLayout<ModelVertexGPU>.stride, options: .storageModeShared),
                  let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
            else { continue }

            let resolvedTexture = index < submeshMaterials.count ? submeshMaterials[index].texture : nil
            let texture: MTLTexture
            if let resolvedTexture, let uploaded = makeTexture(device: device, asset: resolvedTexture, cache: textureCache) {
                texture = uploaded
            } else {
                texture = fallbackTexture
            }

            gpuSubmeshes.append(GPUSubmesh(
                originalIndex: index, vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, indexCount: indices.count, texture: texture,
                bindVertices: submesh.vertices, jointIndices: submesh.jointIndices, jointWeights: submesh.jointWeights,
                excludeFromCollision: isMostlyTransparent(resolvedTexture)
            ))
        }

        return (gpuSubmeshes, minBound, maxBound)
    }

    /// "Leaves have no collision, it's not needed", real, reported
    /// observation confirmed against the real, hand-authored `ColData` in
    /// `hubb.rm2`. No per-submesh semantic tag exists anywhere in this
    /// format to say "this is foliage," but there's a real, measurable
    /// proxy already decoded for every texture: a foliage/cutout texture
    /// is overwhelmingly alpha-transparent (the "holes" between leaves)
    /// where solid geometry (trunks, rock, stone) is not. Samples every
    /// 4th pixel (still hundreds of samples for any real in-game texture,
    /// and this only runs once per submesh at upload time, not per frame)
    /// rather than every single one, real, disclosed trade-off: a texture
    /// with heavy transparency for a non-foliage reason (a decal, a broken
    /// window) would also get excluded here, since this is a shape proxy,
    /// not true semantic understanding.
    static func isMostlyTransparent(_ texture: TextureAsset?, alphaThreshold: UInt8 = 200, transparentFraction: Float = 0.3) -> Bool {
        guard let texture, texture.rgba.count >= 4 else { return false }
        var transparentCount = 0
        var sampledCount = 0
        var i = 3 // alpha is the 4th byte of each RGBA pixel
        while i < texture.rgba.count {
            sampledCount += 1
            if texture.rgba[i] < alphaThreshold { transparentCount += 1 }
            i += 16 // every 4th pixel (4 bytes/pixel * 4)
        }
        guard sampledCount > 0 else { return false }
        return Float(transparentCount) / Float(sampledCount) > transparentFraction
    }

    /// Internal (not `fileprivate`) so `@testable import` can verify the
    /// cache-reuse behavior directly (`TextureUploadCacheTests`).
    static func makeTexture(device: MTLDevice, asset: TextureAsset, cache: TextureUploadCache? = nil) -> MTLTexture? {
        if let cache, let cached = cache.texture(for: asset.id) { return cached }
        guard asset.width > 0, asset.height > 0, asset.rgba.count >= asset.width * asset.height * 4 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: asset.width, height: asset.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        // Real, reported performance bug: every texture uploaded with a
        // single mip level, even though `TextureAsset.mips` (see its own
        // doc comment: "successively half-sized mip levels, same pixel
        // layout as `rgba`") already carries real, decoded minified data
        // straight from the parser, it was parsed, then silently
        // discarded at upload. Sampling a full-resolution, un-mipmapped
        // texture for geometry viewed at a distance or an oblique angle is
        // a genuine, steady-state GPU cost (texture-cache thrashing) that
        // costs the same every single frame regardless of what the user
        // does, a level with hundreds of placements viewed from a normal
        // orbit distance pays this on every one of them, every frame.
        // `mipmapLevelCount` is set to exactly how many real levels this
        // asset actually decoded, not Metal's full auto chain down to
        // 1x1, uploading only real data and letting Metal clamp sampling
        // to the smallest level actually present is correct and avoids
        // ever reading uninitialized texture memory.
        let mipCount = 1 + asset.mips.count
        if mipCount > 1 {
            descriptor.mipmapLevelCount = mipCount
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        asset.rgba.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, asset.width, asset.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: asset.width * 4
            )
        }
        var mipWidth = asset.width
        var mipHeight = asset.height
        for (level, mipData) in asset.mips.enumerated() {
            mipWidth = max(1, mipWidth / 2)
            mipHeight = max(1, mipHeight / 2)
            guard mipData.count >= mipWidth * mipHeight * 4 else { break }
            mipData.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, mipWidth, mipHeight),
                    mipmapLevel: level + 1,
                    withBytes: base,
                    bytesPerRow: mipWidth * 4
                )
            }
        }
        cache?.store(texture, for: asset.id)
        return texture
    }

    fileprivate static func makeSolidTexture(device: MTLDevice, rgba: (UInt8, UInt8, UInt8, UInt8)) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pixel: [UInt8] = [rgba.0, rgba.1, rgba.2, rgba.3]
        pixel.withUnsafeBytes { ptr in
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: 4)
        }
        return texture
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = context.commandQueue.makeCommandBuffer()
        else { return }

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        encode(descriptor: descriptor, commandBuffer: commandBuffer, aspect: aspect)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Renders one frame to an offscreen texture and reads it back as a
    /// `CGImage`, used by `debugSnapshot()` to let the pipeline be verified
    /// without an on-screen window (e.g. from a test), and reusable for any
    /// future thumbnail/export-preview feature.
    func renderOffscreen(width: Int, height: Int) -> CGImage? {
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared
        guard let colorTexture = device.makeTexture(descriptor: colorDescriptor) else { return nil }

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthDescriptor) else { return nil }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = colorTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.07, 0.07, 0.09, 1)
        passDescriptor.depthAttachment.texture = depthTexture
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .dontCare
        passDescriptor.depthAttachment.clearDepth = 1.0

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return nil }
        encode(descriptor: passDescriptor, commandBuffer: commandBuffer, aspect: Float(width) / Float(height))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixelBytes = [UInt8](repeating: 0, count: width * height * 4)
        pixelBytes.withUnsafeMutableBytes { ptr in
            colorTexture.getBytes(ptr.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        // Real, reported performance concern: this used to copy every pixel
        // a second time through a scalar Swift loop just to swap B<->R
        // (BGRA, from the `.bgra8Unorm` texture, into RGBA for `CGImage`) , 
        // real cost for a 256x256+ thumbnail, and it scales with W*H.
        // `CGImage` can consume the BGRA bytes directly, unswapped: on a
        // little-endian machine, `.byteOrder32Little` + `.premultipliedFirst`
        // together tell CoreGraphics the in-memory byte order is B,G,R,A , 
        // exactly what the texture already produced, so this is a correct
        // reinterpretation, not a lossy shortcut.
        guard let provider = CGDataProvider(data: Data(pixelBytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private func encode(descriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer, aspect: Float) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let projection = Self.perspectiveMatrix(fovYRadians: .pi / 4, aspect: aspect, near: 0.01, far: boundsRadius * 20 + 10)
        let distance = boundsRadius * distanceMultiplier
        let eye = SIMD3<Float>(
            boundsCenter.x + distance * cos(pitch) * sin(yaw),
            boundsCenter.y + distance * sin(pitch),
            boundsCenter.z + distance * cos(pitch) * cos(yaw)
        )
        let view4x4 = Self.lookAtMatrix(eye: eye, center: boundsCenter, up: SIMD3<Float>(0, 1, 0))
        let model = matrix_identity_float4x4
        var uniforms = Uniforms(
            modelViewProjection: projection * view4x4 * model,
            modelMatrix: model,
            lightDirection: normalize(SIMD3<Float>(-0.4, -1.0, -0.3))
        )

        encoder.setRenderPipelineState(customPipelineState ?? context.pipelineState)
        encoder.setDepthStencilState(context.depthState)
        encoder.setFragmentSamplerState(context.samplerState, index: 0)

        for submesh in submeshes where !hiddenSubmeshIndices.contains(submesh.originalIndex) {
            encoder.setVertexBuffer(submesh.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(submesh.texture, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: submesh.indexCount, indexType: .uint32, indexBuffer: submesh.indexBuffer, indexBufferOffset: 0)
        }

        // Every buffer bound below is built once (in `upload`/the
        // `skeletonJointWorldPositions` `didSet`) and reused here, this
        // view redraws continuously at 20 fps (`MetalModelView`), and
        // `device.makeBuffer` from scratch on every single frame for data
        // that's usually unchanged since the last frame was pure waste.
        if let linePipelineState = context.linePipelineState, let lineBuffer = skeletonLineBuffer, !skeletonJointWorldPositions.isEmpty {
            encoder.setRenderPipelineState(linePipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: skeletonJointWorldPositions.count * 2)
        }

        // "Collision Mask Alignment", same colored-line pipeline the
        // by-surface-ID collision viewer and the Level Viewer's gizmo/
        // trigger overlays already share; drawn through this asset's own
        // (identity) model transform, same as every other overlay here.
        if let coloredPipelineState = context.collisionLineColoredPipelineState, let lineBuffer = collisionVolumeLineBuffer, !collisionVolumeWorldPositions.isEmpty {
            encoder.setRenderPipelineState(coloredPipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: collisionVolumeWorldPositions.count * 2)
        }

        // "Procedural Collision Decimation" (roadmap 4.4), same colored-
        // line pipeline, cyan instead of orange so it reads as distinct
        // from the real, decoded `GI_CollisionData` overlay above.
        if let coloredPipelineState = context.collisionLineColoredPipelineState, let lineBuffer = proceduralOBBLineBuffer, !proceduralOBBWorldPositions.isEmpty {
            encoder.setRenderPipelineState(coloredPipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: proceduralOBBWorldPositions.count * 2)
        }

        // "Local Physics & Collision Playground" (roadmap 12.1), same
        // colored-line pipeline, yellow so the live-simulated ball reads
        // as distinct from both the decoded `GI_CollisionData` overlay and
        // the computed OBB.
        if let coloredPipelineState = context.collisionLineColoredPipelineState, let lineBuffer = physicsBallLineBuffer, !physicsBallWorldPositions.isEmpty {
            encoder.setRenderPipelineState(coloredPipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: physicsBallWorldPositions.count * 2)
        }

        if collisionColorMode == .bySurfaceID, let coloredPipelineState = context.collisionLineColoredPipelineState, let lineBuffer = collisionLineColoredBuffer, !collisionEdgeWorldPositions.isEmpty {
            encoder.setRenderPipelineState(coloredPipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: collisionEdgeWorldPositions.count * 2)
        } else if let collisionLinePipelineState = context.collisionLinePipelineState, let lineBuffer = collisionLineBuffer, !collisionEdgeWorldPositions.isEmpty {
            encoder.setRenderPipelineState(collisionLinePipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: collisionEdgeWorldPositions.count * 2)
        }

        encoder.endEncoding()
    }

    /// `submeshCount`/`hasGeometry`: cheap introspection for diagnostics and
    /// for the sidebar/hub to show "no geometry" instead of opening a
    /// guaranteed-blank viewer.
    var submeshCount: Int { submeshes.count }
    var hasGeometry: Bool { !submeshes.isEmpty }
    var hasCollisionWireframe: Bool { !collisionEdgeWorldPositions.isEmpty }

    /// "F to Focus/Frame", back to the same angle/distance this renderer
    /// starts a session at.
    func resetView() {
        yaw = .pi * 0.25
        pitch = .pi * 0.15
        distanceMultiplier = 2.4
    }

    /// "Coordinate-System Overhaul": the reference tool's viewers negate
    /// world-space X for every coordinate they load, scenery (via
    /// `SceneryModelPlacement.worldTransform`, already handled), collision
    /// vertices (`LoadColTree`'s `v.X = -v.X`, already handled in
    /// `upload(collisionMesh:)`/`rebuildCollisionFillBuffer`), and every
    /// Instance/Trigger/Camera/AIPosition/ChunkLink-wall position
    /// (`LoadInstances`/`LoadPositions`'s `pos.X = -pos.X`). This is that
    /// same mirror, applied at the render boundary, raw decoded positions
    /// stay untouched (so save/write-back keeps working unchanged); this
    /// is what converts one to the other. Self-inverse (applying it twice
    /// returns the original), so it's also what a write-back call site
    /// needs to convert an edited *world* position back to *raw* before
    /// encoding.
    static func mirroredWorldPosition(_ raw: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(-raw.x, raw.y, raw.z)
    }

    /// Deterministic, stable color for a raw collision `surfaceID`, golden-
    /// ratio hue stepping so adjacent IDs land far apart on the color wheel
    /// rather than as a monotonic gradient (which would make neighboring
    /// surface IDs look confusingly similar). This is *not* a claim about
    /// what a surface ID means (see `CollisionTriangle.surfaceID`'s doc
    /// comment, that mapping to "deadly"/"solid"/etc. isn't decoded), only
    /// a way to tell different raw IDs apart visually. `nonisolated` and
    /// `static` so the `CollisionViewerWindow` legend can compute the exact
    /// same colors without holding a live renderer.
    public static func color(forSurfaceID surfaceID: Int) -> SIMD3<Float> {
        let goldenRatioConjugate: Double = 0.6180339887498949
        // `UInt(bitPattern:)` sidesteps sign entirely (a negative surfaceID
        // is unexpected but not impossible for an undecoded raw field), and
        // the explicit `.truncatingRemainder` + `+ 1 % 1` clamp guarantees
        // `hue` lands in [0, 1) before it ever reaches `hsvToRGB`, where a
        // negative value would otherwise produce an out-of-range `i % 6`.
        let bucket = UInt(bitPattern: surfaceID) % 1000
        var hue = (Double(bucket) / 1000.0 * goldenRatioConjugate).truncatingRemainder(dividingBy: 1.0)
        if hue < 0 { hue += 1 }
        return hsvToRGB(h: hue, s: 0.62, v: 0.95)
    }

    /// Same per-surface-ID hue stepping as `color(forSurfaceID:)`, still
    /// deterministic and still distinguishes different real surface IDs
    /// from each other, but at much lower saturation/value. `color(
    /// forSurfaceID:)`'s bold, maximally-saturated palette is a deliberate
    /// choice for the wireframe/legend use case (thin colored *lines*
    /// over other geometry, where standing out is the whole point); a
    /// same-saturation *solid, opaque floor filling the entire screen* is
    /// a completely different visual weight, real-world testing this
    /// session showed it reads as a dominating, garish red/orange wash
    /// rather than ground. This format has no decoded per-vertex normals
    /// to light the fill and naturally shade it toward something more
    /// terrain-like, so the fix is a muted palette at the color-selection
    /// step instead.
    static func mutedColor(forSurfaceID surfaceID: Int) -> SIMD3<Float> {
        let goldenRatioConjugate: Double = 0.6180339887498949
        let bucket = UInt(bitPattern: surfaceID) % 1000
        var hue = (Double(bucket) / 1000.0 * goldenRatioConjugate).truncatingRemainder(dividingBy: 1.0)
        if hue < 0 { hue += 1 }
        return hsvToRGB(h: hue, s: 0.22, v: 0.5)
    }

    private static func hsvToRGB(h: Double, s: Double, v: Double) -> SIMD3<Float> {
        let i = Int(h * 6)
        let f = h * 6 - Double(i)
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        let rgb: (Double, Double, Double)
        switch i % 6 {
        case 0: rgb = (v, t, p)
        case 1: rgb = (q, v, p)
        case 2: rgb = (p, v, t)
        case 3: rgb = (p, q, v)
        case 4: rgb = (t, p, v)
        default: rgb = (v, p, q)
        }
        return SIMD3(Float(rgb.0), Float(rgb.1), Float(rgb.2))
    }

    // MARK: - Matrix helpers (simd has no built-in perspective/lookAt)

    fileprivate static func perspectiveMatrix(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovYRadians * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        )
    }

    /// Symmetric orthographic projection, built with the exact same Metal
    /// `[0, 1]`-z NDC convention as `perspectiveMatrix` above (verified the
    /// same way: view-space `vz = -near` maps to `clip.z/w = 0`, `vz =
    /// -far` maps to `clip.z/w = 1`) so `Frustum`, `project()`, and the
    /// collision-mesh unprojection all keep working unmodified under an
    /// orthographic camera, none of them assume a converging eye point,
    /// they all consume `viewProjection` generically.
    fileprivate static func orthographicMatrix(halfWidth: Float, halfHeight: Float, near: Float, far: Float) -> simd_float4x4 {
        let sx = 1 / halfWidth
        let sy = 1 / halfHeight
        let sz = 1 / (near - far)
        let tz = near / (near - far)
        return simd_float4x4(
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(0, 0, sz, 0),
            SIMD4<Float>(0, 0, tz, 1)
        )
    }

    fileprivate static func lookAtMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye - center)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return simd_float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        )
    }

    // MARK: - Frustum culling ("Seamless Full-Map Rendering", Part 1)

    /// The 6 view-frustum planes, extracted straight from a view-projection
    /// matrix via the standard Gribb/Hartmann trick: each plane is one row
    /// of `M` (combined with the clip-space condition it encodes), and a
    /// point's signed distance to it falls out of `plane . (x, y, z, 1)`
    /// divided by the plane normal's length. Built specifically for this
    /// codebase's own `perspectiveMatrix`/`currentViewProjection` convention
    ///, column-vector (`clip = M * v`) and Metal's `[0, 1]` NDC z range
    /// (verified against `perspectiveMatrix`'s own construction: `vz =
    /// -near` maps to `clip.z/w = 0`, `vz = -far` maps to `clip.z/w = 1`) , 
    /// not a generic OpenGL `[-1, 1]`-z formula, which would put the near
    /// plane in the wrong place under Metal's convention.
    struct Frustum {
        /// Each plane as `(A, B, C, D)` with the *outward normal already
        /// normalized*, a point is on the inside (visible) half-space when
        /// `A*x + B*y + C*z + D >= 0`, and that dot product is directly a
        /// true signed distance once the normal is unit length, which is
        /// what makes the sphere test below just a `>= -radius` compare.
        private let planes: [SIMD4<Float>]

        init(viewProjection m: simd_float4x4) {
            func row(_ i: Int) -> SIMD4<Float> {
                SIMD4(m.columns.0[i], m.columns.1[i], m.columns.2[i], m.columns.3[i])
            }
            let r0 = row(0), r1 = row(1), r2 = row(2), r3 = row(3)
            // Left/right/bottom/top: standard `r3 ± r0`/`r3 ± r1`, unaffected
            // by the NDC z-range convention. Near/far are Metal-specific:
            // `clip.z >= 0` *is* the near plane directly (not `r3 + r2`,
            // which is the OpenGL `[-1,1]`-z formula), and `clip.w - clip.z
            // >= 0` is the far plane, same as OpenGL.
            let raw = [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2]
            planes = raw.map { plane in
                let normalLength = simd_length(SIMD3(plane.x, plane.y, plane.z))
                return normalLength > 0.0001 ? plane / normalLength : plane
            }
        }

        /// Conservative sphere-vs-frustum test: `false` only when the sphere
        /// is provably entirely outside at least one plane. May return
        /// `true` for some spheres that are actually just outside a corner
        /// (the classic false-positive every plane-based frustum test
        /// shares), acceptable here since the failure mode of a
        /// false-positive is "draw one extra object," not the "object
        /// visibly pops in" a false *negative* would cause.
        func intersects(center: SIMD3<Float>, radius: Float) -> Bool {
            for plane in planes {
                let distance = plane.x * center.x + plane.y * center.y + plane.z * center.z + plane.w
                if distance < -radius { return false }
            }
            return true
        }
    }

    // MARK: - Shader source

    fileprivate static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float2 uv [[attribute(2)]];
        float4 color [[attribute(3)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float3 worldNormal;
        float2 uv;
        float4 color;
    };

    struct Uniforms {
        float4x4 modelViewProjection;
        float4x4 modelMatrix;
        float3 lightDirection;
    };

    vertex VertexOut vertex_main(VertexIn in [[stage_in]], constant Uniforms &uniforms [[buffer(1)]]) {
        VertexOut out;
        out.position = uniforms.modelViewProjection * float4(in.position, 1.0);
        out.worldNormal = normalize((uniforms.modelMatrix * float4(in.normal, 0.0)).xyz);
        out.uv = in.uv;
        out.color = in.color;
        return out;
    }

    fragment float4 fragment_main(VertexOut in [[stage_in]],
                                   texture2d<float> colorTexture [[texture(0)]],
                                   sampler textureSampler [[sampler(0)]],
                                   constant Uniforms &uniforms [[buffer(1)]]) {
        float4 texColor = colorTexture.sample(textureSampler, in.uv);
        // Skinned vertices don't currently decode a real normal (SkinParser
        // leaves it zero, the Skin format's own per-vertex normal isn't
        // wired up yet); normalize()-ing a zero vector is undefined, so
        // treat a degenerate normal as "ambient only" instead of feeding it
        // into the dot product. `abs(dot(...))` rather than `max(...,0)`:
        // there's no back-face culling in this viewer (both sides of thin
        // geometry are visible), so lighting both faces of a surface keeps
        // the back side from reading as flat-black, appropriate for an
        // inspection tool where seeing the geometry matters more than
        // single-sided physical lighting accuracy.
        float normalLength = length(in.worldNormal);
        float diffuse = normalLength > 0.0001 ? abs(dot(in.worldNormal / normalLength, normalize(-uniforms.lightDirection))) : 0.0;
        float lighting = min(0.6 + diffuse * 0.5, 1.0);
        float3 base = texColor.rgb * in.color.rgb;
        return float4(base * lighting, texColor.a * in.color.a);
    }

    struct LineOut {
        float4 position [[position]];
    };

    vertex LineOut vertex_line(uint vertexID [[vertex_id]],
                                const device packed_float3 *positions [[buffer(0)]],
                                constant Uniforms &uniforms [[buffer(1)]]) {
        LineOut out;
        out.position = uniforms.modelViewProjection * float4(positions[vertexID], 1.0);
        return out;
    }

    fragment float4 fragment_line(LineOut in [[stage_in]]) {
        return float4(1.0, 0.65, 0.0, 1.0);
    }

    fragment float4 fragment_line_collision(LineOut in [[stage_in]]) {
        return float4(0.25, 0.7, 1.0, 0.9);
    }

    struct LineVertexColorIn {
        packed_float3 position;
        packed_float3 color;
    };

    struct LineColorOut {
        float4 position [[position]];
        float4 color;
    };

    vertex LineColorOut vertex_line_colored(uint vertexID [[vertex_id]],
                                             const device LineVertexColorIn *vertices [[buffer(0)]],
                                             constant Uniforms &uniforms [[buffer(1)]]) {
        LineColorOut out;
        out.position = uniforms.modelViewProjection * float4(vertices[vertexID].position, 1.0);
        out.color = float4(vertices[vertexID].color, 0.9);
        return out;
    }

    fragment float4 fragment_line_colored(LineColorOut in [[stage_in]]) {
        return in.color;
    }

    fragment float4 fragment_translucent_quad(LineColorOut in [[stage_in]]) {
        return float4(in.color.rgb, 0.28);
    }

    fragment float4 fragment_collision_fill(LineColorOut in [[stage_in]]) {
        return float4(in.color.rgb, 1.0);
    }
    """
}

/// One resolved scenery placement, uploaded once and drawn every frame at
/// its own world position. `worldPosition`/`rotation`/`scale` are `var` , 
/// the Forge-style transform gizmo (blueprint 6.1) mutates them directly;
/// everything else about an uploaded object (its GPU geometry) never
/// changes after upload.
/// "Level Editor Overhaul": which of the "Scene Layers" checkbox panel's
/// four groups an object belongs to, drives both draw-time visibility
/// filtering and the "Geometry Only"/"Fully Populated" mode preset.
enum SceneLayer: CaseIterable, Hashable {
    case collision, scenery, actors, triggers, cameras, chunkBoundaries, linkedChunks, aiWaypoints, crossEngine

    var displayName: String {
        switch self {
        case .collision: return "Collision / Ground Floor"
        case .scenery: return "Scenery / Terrain"
        case .actors: return "Actors / Entities"
        case .triggers: return "Trigger Volumes & Death Planes"
        case .cameras: return "Camera Splines"
        case .chunkBoundaries: return "Chunk Boundaries"
        case .linkedChunks: return "Loaded Neighboring Chunks"
        case .aiWaypoints: return "AI Waypoints"
        case .crossEngine: return "Cross-Engine Data (Wrath of Cortex)"
        }
    }
}

struct GPULevelObject {
    var worldPosition: SIMD3<Float>
    var rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    var scale: SIMD3<Float> = SIMD3(1, 1, 1)
    let displayName: String
    /// Empty for trigger/camera markers, those draw as line wireframes
    /// (see `overlayLineBuffer`) instead of a solid mesh, but still
    /// participate in `objects` so selection/picking/the sidebar list work
    /// identically across every layer.
    let submeshes: [GPUSubmesh]
    let layer: SceneLayer
    /// Local-space bounding-sphere radius (distance from this object's own
    /// origin to its farthest vertex), rotation-invariant by construction,
    /// so `LevelViewerRenderer.draw(in:)`'s frustum cull can test it
    /// directly against `worldPosition` without needing the object's
    /// current rotation, only its (interactively editable) `scale`.
    /// "Seamless Full-Map Rendering" (Part 1).
    var boundingRadius: Float = 1
    /// "Magnet Snap, Stacking": local-space (unscaled, unrotated) axis-
    /// aligned bounding box, real vertex extents, not the bounding
    /// *sphere* above, which has no per-axis shape and can't tell "this
    /// crate is 2 units tall" from "this crate is 2 units wide." Lets
    /// `LevelViewerRenderer.magnetSnappedPosition` offer a real face-to-
    /// face snap (this object's bottom flush against another's top, not
    /// just their centers aligned) so two boxes actually stack instead of
    /// floating apart or interpenetrating unless they happen to be the
    /// same size. Defaults to a generic unit cube for marker layers
    /// (trigger/camera/AI waypoint/spline point) that have no real mesh , 
    /// close enough to their own drawn wireframe box for a sensible snap,
    /// and magnet snap is scoped to actual dragging, never rendering.
    var localBoundsMin: SIMD3<Float> = SIMD3(-0.5, -0.5, -0.5)
    var localBoundsMax: SIMD3<Float> = SIMD3(0.5, 0.5, 0.5)
    /// "Direct .RM2 Write-Back": non-nil only for placeholder `Instance`
    /// markers (see `LevelViewerContext.instanceMarkers`), the on-disk
    /// record this object's transform patches back into on save. `nil` for
    /// ordinary scenery placements and Models-Hub-dropped objects, neither
    /// of which have a verified write path.
    var sourceNode: ChunkNode?
    /// The record's on-disk W component and COM-rotation, preserved
    /// unedited, the gizmo only ever touches XYZ position and the primary
    /// rotation, so these need to survive round-trip to re-encode a valid
    /// 28-byte transform prefix on save.
    var originalPositionW: Float = 0
    var comRotationRaw: SIMD3<UInt16> = .zero
    /// "The Forge Palette" (Part 4C): non-nil only for an object placed
    /// this session via the palette (not yet a real record in the file) , 
    /// `objectID` is what a brand-new `Instance` record for it needs, and
    /// `syntheticInstanceID` is a locally-generated ID that doesn't collide
    /// with any real `Instance` already in this level (see
    /// `LevelViewerRenderer.spawnInstance`'s doc comment). `sourceNode`
    /// stays `nil` for these, there is no on-disk record yet to point at.
    var newInstanceObjectID: UInt16?
    var syntheticInstanceID: UInt32?
    /// "Set AI Path on a Newly-Placed AI": the
    /// right click and set its pathing." Non-nil (well, non-empty) only
    /// when the user has assigned one or more real `AIPath` IDs to this
    /// session-placed Instance via the marking menu's "Set AI Path" slice , 
    /// scoped to session-placed objects (`newInstanceObjectID != nil`) only,
    /// deliberately not extended to an already-real, on-disk Instance yet:
    /// `PlacedInstance.childPathIDs` sits inside `Instance`'s own
    /// variable-length record, and this codebase has no "resize an
    /// existing record safely, without breaking whatever else in the file
    /// references its ID" write path built or verified yet (unlike a
    /// brand-new record, which `ChunkSectionInserter` already inserts
    /// cleanly with a fresh ID nothing else references yet).
    var pendingPathIDs: [UInt16] = []
    /// "AI Pathfinding & Navmesh Editor" (roadmap 5.1): non-nil only for a
    /// waypoint added this session via `spawnAIWaypoint`, the raw
    /// `AIPosition.Num`/node-type value to encode on save, mirroring
    /// `newInstanceObjectID`'s role but for a distinct record type/layer
    /// (`.aiWaypoints`, not `.actors`), so `pendingLevelOverrides`'s
    /// `.actors`-only guard can't accidentally pick these up.
    var newAIWaypointRawNodeType: UInt16?
    var syntheticAIPositionID: UInt32?
    /// The real, on-disk `AIPosition.Num` value for an *existing* waypoint
    /// (`sourceNode != nil`), preserved so a drag-save re-encodes with the
    /// waypoint's real node type instead of clobbering it with a default.
    /// `nil` for anything that isn't a real, loaded waypoint.
    var originalAIWaypointRawNodeType: UInt16?
    /// "Spline & Camera Path Persistence" (roadmap 6.3): non-nil only for a
    /// Camera Path/Spline control-point marker (not the camera's own box
    /// marker, which shares the `.cameras` layer but leaves this `nil`) , 
    /// the control point's byte offset relative to the owning Camera
    /// record (`sourceNode`), captured at parse time
    /// (`CameraPath`/`CameraSpline.controlPointFileOffsets`). Lets
    /// `pendingCameraControlPointOverrides` patch a dragged point straight
    /// into the file at `sourceNode.fileOffset + this` without touching
    /// anything else in the variable-length Camera record.
    var cameraControlPointFileOffset: Int?
    /// "Add Trigger"/"Add Camera": non-nil only for a Trigger/Camera
    /// placed this session via `spawnTrigger`/`spawnCamera`, a locally-
    /// generated ID that doesn't collide with any real Trigger/Camera
    /// already in this level, mirroring `syntheticInstanceID`/
    /// `syntheticAIPositionID`'s role for their own record types. `nil`
    /// for a real, on-disk Trigger/Camera (those use `sourceNode`
    /// instead, there is no on-disk record yet to point at for these).
    var syntheticTriggerID: UInt32?
    var syntheticCameraID: UInt32?
    /// "Interactive Scenery Placement": non-nil only for a scenery object
    /// placed this session via `spawnScenery`, mirrors
    /// `newInstanceObjectID`/`syntheticInstanceID`'s role but for
    /// `.scenery`, so a new placement appears immediately in the
    /// viewport (real geometry, gizmo-movable, undo-able) instead of the
    /// old one-shot "compute patched bytes, immediately prompt a save
    /// panel" flow. `nil` for scenery loaded from the level's own file , 
    /// those still have no write path (no way to locate *which* array
    /// element on disk a given placement is), only newly-placed ones do.
    var newSceneryModelID: UInt32?
    var newSceneryIsSpecial: Bool?
    var syntheticSceneryID: UInt32?
    /// The resolved asset a session-placed scenery object was spawned
    /// from, kept around (it's a cheap `Sendable` value, not a
    /// duplicated GPU buffer) so both `duplicateSelectedObject`'s
    /// `.scenery` case and `registerSceneryPlacementUndo`'s redo step can
    /// call `spawnScenery`/`spawnCrossLevelScenery` again without needing
    /// to re-resolve geometry from `newSceneryModelID` alone (unlike
    /// `spawnInstance`, there is no `AssetResolver` lookup that goes
    /// from a scenery model ID back to a `ResolvedModelAsset`). `nil`
    /// for every other layer.
    var newSceneryAsset: ResolvedModelAsset?

    /// Generated collision data for objects that lack it, populated
    /// automatically when an object is placed and has no existing
    /// collision data in its skeleton. This ensures objects have
    /// collision volumes for gameplay even when the original asset
    /// lacks them.
    var generatedCollisionData: [GraphicsInfoCollisionData] = []
    // Real Swift memberwise-init gotcha: a `let` property with a fixed
    // default expression is treated as pre-initialized and *excluded*
    // from the synthesized memberwise init entirely, every call site
    // below that explicitly passes `assetCollisionData:` failed to
    // compile with "extra argument" until this became `var` (matching
    // `generatedCollisionData` just above), which keeps it a real,
    // settable init parameter.
    var assetCollisionData: [GraphicsInfoCollisionData] = []
    /// "Live Cross-Level Scenery Placement": non-nil only for a session-
    /// placed scenery object whose real geometry doesn't exist in *this*
    /// destination file yet (a model borrowed from another level's
    /// Scenery tab entry), `newSceneryModelID` for one of these is a
    /// session-local placeholder, not a real destination RigidModel ID;
    /// the actual cross-file copy (`CrossFileModelCopier`) only happens
    /// once, at save time, using the source info carried here. Deferring
    /// the real file-level copy to save time (instead of committing it
    /// the instant the object is placed) matches every other pending
    /// edit in this app, committing bytes mid-session while `rootNodes`'
    /// own tree for that file stays unrefreshed would leave any *later*
    /// edit to the same file operating against stale node offsets.
    var pendingCrossLevelGeometrySource: CrossLevelSceneryGeometrySource?
    /// "Real Delete for Existing Scenery": non-nil only for a scenery
    /// object loaded from this level's *own* real `SceneryData` tree
    /// (`SceneryModelPlacement.matrixFileOffset`, threaded straight
    /// through from `WorkspaceViewModel.resolvedLevelPlacements`, see
    /// that field's own doc comment for why it's already a real, unique
    /// per-placement identity, no separate tree-path scheme needed). `nil`
    /// for a session-placed scenery object (those use `newSceneryModelID`
    /// instead) and for a stitched neighbor chunk's scenery
    /// (`stitchChunk` deliberately never sets this, see
    /// `WorkspaceViewModel.loadChunkLinkPlacements`'s own doc comment on
    /// why a *different* file's byte offset can't be treated as deletable
    /// from this one).
    var sceneryMatrixFileOffset: Int?
    /// "Cross-Level Forge Placement": non-nil only for a session-placed
    /// Instance (`newInstanceObjectID != nil`) whose `objectID` didn't
    /// resolve through this level's own data or the shared `Default.rm2`
    ///, only through `globalObjectFallbacks`'s cross-level preview search
    /// (see `LevelViewerRenderer.canResolveNativelyObjectID`'s own doc
    /// comment). Captured once, at placement time, from whichever other
    /// level's file that preview search actually found, the byte-level
    /// counterpart `CrossFileGameObjectCopier` needs at save time to make
    /// the placement real, not just a borrowed preview. `nil` for any
    /// object that already resolves natively (the overwhelmingly common
    /// case, nothing needs copying) and for every non-Instance layer.
    var pendingCrossLevelGameObjectSource: CrossLevelGameObjectSource?
    /// "Spawn Interactive Cortex (Prop)": non-nil only for a session-placed
    /// Instance whose `newInstanceObjectID` is a freshly synthesized ID
    /// with no real on-disk `GameObject` anywhere yet, the save-time
    /// counterpart `CrossFileGameObjectCopier.resolvingPropSkinInsertion`
    /// needs to actually create that record. See `PropSkinSpawnSource`'s
    /// own doc comment for why this is a separate field from
    /// `pendingCrossLevelGameObjectSource` rather than reusing it.
    var pendingPropSkinSpawnSource: PropSkinSpawnSource?
    /// The CPU-side asset `spawnInteractiveCortexProp` resolved this
    /// object's GPU submeshes from, kept alongside
    /// `pendingPropSkinSpawnSource` purely so undo/redo
    /// (`propSkinPlacementInfo`) can rebuild the same submeshes again on
    /// redo without needing to re-resolve Cortex's skin a second time.
    var pendingPropSkinAsset: ResolvedModelAsset?
}

/// "Cross-Level Forge Placement": everything a save-time
/// `CrossFileGameObjectCopier.copyingSkinnedGameObjectChain` call needs to
/// actually copy a borrowed enemy/AI object's real game data into the
/// destination file, captured once, at placement time, from whichever
/// other level's file `WorkspaceViewModel.resolvingObjectIDAcrossAllLevels`
/// already resolved it from, so save time never needs to re-search or
/// re-parse the source level at all. Mirrors `CrossLevelSceneryGeometrySource`'s
/// own role, simplified: a GameObject's destination is always the same
/// file real Instance records for this level already go into (no separate
/// "scenery file vs. graphics file" ambiguity scenery placement has).
public struct CrossLevelGameObjectSource {
    public var objectID: UInt16
    public var sourceFileRoot: ChunkNode
    public var sourceBytes: Data

    public init(objectID: UInt16, sourceFileRoot: ChunkNode, sourceBytes: Data) {
        self.objectID = objectID
        self.sourceFileRoot = sourceFileRoot
        self.sourceBytes = sourceBytes
    }
}

/// "Spawn Interactive Cortex (Prop)": everything a save-time
/// `CrossFileGameObjectCopier.resolvingPropSkinInsertion` call needs , 
/// `baseGameObject` is a real, working object already native to this
/// level (`BASICCRATE`, its own real break/throw physics kept verbatim),
/// `freshObjectID` the new synthetic ID it's cloned under, and
/// `skinSourceObjectID`/`skinSourceFileRoot`/`skinSourceBytes` the
/// character (Cortex) whose skinned mesh gets cross-file-copied in and
/// substituted for the crate's own model. See that function's own doc
/// comment for why this needs a dedicated source type rather than reusing
/// `CrossLevelGameObjectSource`, that one always keeps the *source*
/// object's own scripts/behavior, which here would mean Cortex's own (or
/// no) AI, not the crate's real physics.
public struct PropSkinSpawnSource {
    public var freshObjectID: UInt16
    public var baseGameObject: GameObjectInfo
    public var skinSourceObjectID: UInt16
    public var skinSourceFileRoot: ChunkNode
    public var skinSourceBytes: Data

    public init(freshObjectID: UInt16, baseGameObject: GameObjectInfo, skinSourceObjectID: UInt16, skinSourceFileRoot: ChunkNode, skinSourceBytes: Data) {
        self.freshObjectID = freshObjectID
        self.baseGameObject = baseGameObject
        self.skinSourceObjectID = skinSourceObjectID
        self.skinSourceFileRoot = skinSourceFileRoot
        self.skinSourceBytes = skinSourceBytes
    }
}

/// "Live Cross-Level Scenery Placement": everything a save-time
/// `CrossFileModelCopier.copyingRigidModelChain` call needs to actually
/// copy a borrowed model's geometry into the destination file, captured
/// once, at placement time, from the Scenery tab's already-loaded source
/// section, so save time never needs to re-fetch or re-parse the source
/// level at all.
public struct CrossLevelSceneryGeometrySource {
    public var sourceModelID: UInt32
    public var sourceIsSpecial: Bool
    public var sourceSceneryFileRoot: ChunkNode
    public var sourceSceneryBytes: Data
    public var sourceGraphicsRoot: ChunkNode
    public var sourceGraphicsBytes: Data
    /// Which file the copied geometry lands in, resolved once at
    /// placement time (`WorkspaceViewModel.loadingDestinationGraphics`),
    /// but only ever used at *save* time to identify which of the
    /// session's own two tracked files (the level's primary file or its
    /// scenery file) owns it; `patchedFileBytes` always re-parses that
    /// file's own current bytes fresh rather than trusting this node's
    /// offsets directly, since they can go stale between placement and
    /// save the same way every other pending edit in this app can.
    public var destinationGraphicsRoot: ChunkNode

    public init(sourceModelID: UInt32, sourceIsSpecial: Bool, sourceSceneryFileRoot: ChunkNode, sourceSceneryBytes: Data, sourceGraphicsRoot: ChunkNode, sourceGraphicsBytes: Data, destinationGraphicsRoot: ChunkNode) {
        self.sourceModelID = sourceModelID
        self.sourceIsSpecial = sourceIsSpecial
        self.sourceSceneryFileRoot = sourceSceneryFileRoot
        self.sourceSceneryBytes = sourceSceneryBytes
        self.sourceGraphicsRoot = sourceGraphicsRoot
        self.sourceGraphicsBytes = sourceGraphicsBytes
        self.destinationGraphicsRoot = destinationGraphicsRoot
    }
}

/// Which transform the gizmo currently edits, the W/E/R hotkeys switch
/// this, same as most 3D DCC tools' own convention.
enum GizmoMode: CaseIterable {
    case translate, rotate, scale
}

/// One gizmo axis (blueprint 6.1). `CaseIterable` order is also draw order
/// for the gizmo's three arrows/rings.
enum GizmoAxis: CaseIterable {
    case x, y, z

    var unitVector: SIMD3<Float> {
        switch self {
        case .x: return SIMD3(1, 0, 0)
        case .y: return SIMD3(0, 1, 0)
        case .z: return SIMD3(0, 0, 1)
        }
    }

    /// Matches the conventional red/green/blue axis-color scheme (also
    /// reused as-is by most 3D DCC tools' own gizmos), not anything
    /// Twinsanity-specific.
    var color: SIMD3<Float> {
        switch self {
        case .x: return SIMD3(0.95, 0.25, 0.25)
        case .y: return SIMD3(0.3, 0.9, 0.3)
        case .z: return SIMD3(0.3, 0.55, 0.95)
        }
    }

    /// Two unit vectors spanning the plane perpendicular to this axis , 
    /// the plane a rotation ring around this axis actually lies in (e.g.
    /// the ring for rotating *around* X lies flat *in* the YZ plane).
    var planeBasis: (u: SIMD3<Float>, v: SIMD3<Float>) {
        switch self {
        case .x: return (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        case .y: return (SIMD3(1, 0, 0), SIMD3(0, 0, 1))
        case .z: return (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        }
    }
}

/// Shared by any renderer that draws a "Forge-style" transform gizmo on a
/// selected object and lets the user drag one of its handles, today just
/// `LevelViewerRenderer`. `InteractiveMTKView` checks for this conformance
/// to decide whether a `mouseDown` should try to grab a gizmo handle before
/// falling back to its normal orbit-drag behavior, and reads/writes
/// `gizmoMode` directly for the W/E/R hotkeys.
protocol GizmoInteractiveRenderer: OrbitCameraRenderer {
    var gizmoMode: GizmoMode { get set }
    /// Screen-space (AppKit view-point coordinates, `viewSize` = that same
    /// view's `bounds.size`) hit test against the current selection's
    /// gizmo handles for the current `gizmoMode`. `nil` if nothing is
    /// selected or the point isn't close enough to any handle.
    func gizmoAxis(at point: CGPoint, viewSize: CGSize) -> GizmoAxis?
    /// Applies `viewportDelta` (raw `NSEvent.deltaX`/`deltaY`, points) to
    /// the current selection along `axis`, interpreted per `gizmoMode`
    /// (move/rotate/scale), snapping to the configured grid if enabled.
    func dragSelectedObject(axis: GizmoAxis, viewportDelta: CGVector, viewSize: CGSize)
    /// Marks the start of one continuous gizmo-handle drag gesture, lets
    /// a rotate drag track the total angle dragged around its one axis
    /// from a real starting point, instead of re-deriving it by decoding
    /// the accumulated 3D rotation through Euler angles on every
    /// incremental tick (see the concrete implementation's own doc
    /// comment on `dragRotate` for the real bug that caused: rotating
    /// with snap-to-grid on got stuck partway around instead of
    /// completing a full turn). Called at the start of every gizmo drag,
    /// translate/scale included, even though only rotate currently uses
    /// it, cheap, and keeps this a single "a drag just began" signal
    /// every gizmo mode can rely on later.
    func beginGizmoDrag()
    /// "Click any rendered element to select it" (Level Editor overhaul):
    /// screen-space closest-point object pick, checked when a `mouseDown`
    /// didn't already grab a gizmo handle. Projects every currently-visible
    /// object's world position through the same view/projection matrix the
    /// frame was drawn with and returns the nearest one within a small
    /// pixel radius, not true ray/mesh intersection, but exact-shape
    /// picking would need per-object collision geometry this build doesn't
    /// have for placeholder markers anyway, and closest-projected-point is
    /// the same category of screen-space technique this file's gizmo hit
    /// test already uses. `nil` if nothing visible is close enough.
    func pickObject(at point: CGPoint, viewSize: CGSize) -> Int?
    /// "Hover highlight" (Level Editor overhaul, Phase 3): the same
    /// screen-space closest-point test `pickObject` uses, but called from
    /// `mouseMoved`, every frame the cursor moves, not just on click , 
    /// and with no selection side effect. Updates the renderer's own
    /// hover-outline buffer as a side effect so `draw(in:)` can draw it;
    /// the return value just lets a caller avoid redundant work.
    @discardableResult
    func hoverObject(at point: CGPoint, viewSize: CGSize) -> Int?
    /// "Keyboard nudging" (QoL): moves the current selection one step
    /// along a world-space axis, arrow keys for forward/back/left/right,
    /// a modifier for world Y, as an alternative to grabbing a gizmo
    /// handle with the mouse. `worldDirection` is a unit-ish axis vector
    /// (e.g. `(1,0,0)`); the actual step size is the renderer's own grid
    /// size when snap-to-grid is on, or a small fixed default otherwise , 
    /// the same convention a gizmo drag already snaps to. No-op with
    /// nothing selected.
    func nudgeSelectedPosition(worldDirection: SIMD3<Float>)
    /// "Hold to Move" HUD toggle: moves the current selection continuously
    /// along `worldDirection` at a fixed speed (units/second), scaled by
    /// however much real time elapsed since the last tick, smooth,
    /// analog-feeling movement for as long as a HUD button (or key) stays
    /// held, instead of `nudgeSelectedPosition`'s fixed per-press step.
    /// Deliberately ignores snap-to-grid mid-hold (the same way a gizmo
    /// drag doesn't jump between grid points while dragging, only lands on
    /// one at release), a real, reported request: the fixed-step HUD
    /// buttons felt too coarse for fine positioning. No-op with nothing
    /// selected.
    func nudgeSelectedPositionContinuous(worldDirection: SIMD3<Float>, deltaSeconds: TimeInterval)
    /// Camera-relative ground axes for keyboard nudging, "forward" is
    /// the horizontal direction the camera is currently facing (or, in
    /// orbit mode, facing *toward*, see the concrete implementation's own
    /// doc comment for why that's the opposite sign of the eye-offset
    /// formula), "right" its perpendicular, both flattened to the Y=0
    /// plane so pressing Up/Down doesn't push a nudged object underground
    /// or into the sky just because the camera happens to be angled up or
    /// down. Real, reported request: fixed world-X/Z arrow nudging felt
    /// wrong the moment the camera had orbited away from its default
    /// facing, "up" no longer meant "away from me."
    func cameraGroundForward() -> SIMD3<Float>
    func cameraGroundRight() -> SIMD3<Float>
}

/// "Scenery/Level Assembly": draws every resolved placement from a
/// `SceneryAsset` in one scene, each positioned/oriented/scaled from its
/// own world-space transform. Shares `ModelViewerGPUContext`/`GPUSubmesh`
/// upload logic with `ModelViewerRenderer`, the only real difference is
/// drawing many objects with per-object model matrices instead of one
/// object at identity.
///
/// Rotation/scale come from `SceneryModelPlacement.worldTransform`, which
/// decomposes the on-disk 4-row matrix using the reference tool's own
/// working 3D viewer construction (`RMViewer.cs`/`SMViewer.cs`
/// `LoadScenery`), not guessed or independently derived.
final class LevelViewerRenderer: NSObject, MTKViewDelegate {
    private let context: ModelViewerGPUContext
    var device: MTLDevice { context.device }
    /// Exposed so a caller can build `GPULevelObject`s off-main via
    /// `buildingStitchedChunkObjects`/`buildingStitchedChunkActorObjects`
    /// (both `static`, no `self`) without needing to reach into the
    /// otherwise-private `context`, see those functions' own doc comment.
    var fallbackTexture: MTLTexture { context.fallbackTexture }

    // Performance fix ("Chunk Viewer extremely laggy", still-reported after
    // the earlier LazyVStack fix, see `objectSummaries`'s own doc comment
    // for why that fix alone wasn't enough): invalidates the
    // `objectSummaries` cache below whenever `objects` actually changes , 
    // including an in-place element mutation like `objects[i].worldPosition
    // = ...` during a live gizmo drag, which Swift treats as a whole-array
    // set through the subscript, so this can't go stale.
    private var objects: [GPULevelObject] = [] {
        didSet { objectSummariesCache = nil }
    }
    private var objectSummariesCache: [(index: Int, displayName: String, worldPosition: SIMD3<Float>, layer: SceneLayer)]?
    private var boundsCenter: SIMD3<Float> = .zero
    private var boundsRadius: Float = 10

    var yaw: Float = .pi * 0.25
    var pitch: Float = .pi * 0.3
    /// "Zoom Clamp", see `ModelViewerRenderer.distanceMultiplier`'s own
    /// doc comment for the full reasoning (same fix, same class of bug,
    /// duplicated here because this is a genuinely separate renderer/
    /// property, not a shared base class).
    var distanceMultiplier: Float = 1.4 {
        didSet {
            let floor = ModelViewerRenderer.minDistanceMultiplier(forBoundsRadius: boundsRadius)
            if distanceMultiplier < floor { distanceMultiplier = floor }
        }
    }

    // MARK: - Forge-style selection & gizmo (blueprint 6.1)

    private(set) var selectedObjectIndex: Int?
    /// The currently-selected object's real layer, lets a caller (e.g.
    /// the "Procedural Brush" scatter UI) show/hide layer-specific
    /// controls without needing `objects` itself exposed.
    var selectedObjectLayer: SceneLayer? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        return objects[selectedObjectIndex].layer
    }
    var snapToGrid = true
    var gridSize: Float = 1.0
    /// "Vertex Magnet-Snapping": while translating, snap the dragged axis
    /// to align with the nearest *other* placement's same-axis coordinate
    /// when within `magnetSnapThreshold`, catches the common "slide this
    /// piece until it lines up with its neighbor" case even when the
    /// neighbor's spacing isn't a clean multiple of `gridSize`. Scoped to
    /// placement origins, not full per-polygon mesh vertices (searching
    /// every visible object's whole resolved mesh on every drag frame
    /// isn't practical at level scale); on by default, applied after grid
    /// snap so an exact neighbor match wins over a merely grid-aligned one.
    var magnetSnapEnabled = true
    var magnetSnapThreshold: Float = 0.75
    /// "Cull Back Faces" (opt-in, `LevelViewerWindow`'s own toggle), off
    /// by default. See the fragment shader's own doc comment for why this
    /// viewer has always drawn both faces (thin/single-sided geometry like
    /// foliage/decals staying visible from any angle matters more here
    /// than physically-accurate single-sided lighting), this doesn't
    /// change that default, it just lets a user opt into roughly halving
    /// per-frame fragment work when they'd rather have the FPS.
    var cullBackFaces = false
    /// Rotation snap step, in degrees, the rotate-mode equivalent of
    /// `gridSize`, gated by the same `snapToGrid` toggle.
    var rotationSnapDegrees: Float = 15.0
    var gizmoMode: GizmoMode = .translate { didSet { rebuildGizmoBuffer() } }
    private var gizmoBuffer: MTLBuffer?

    /// `boundsRadius`-relative, not a fixed world size, a gizmo sized for
    /// a small level would be invisible in a huge one and vice versa.
    private var gizmoArmLength: Float { max(boundsRadius * 0.12, 0.5) }

    /// "Level Editor Overhaul": every layer visible by default, the mode
    /// toggle/checkbox panel narrows this down, never the initial state.
    var layerVisibility: Set<SceneLayer> = Set(SceneLayer.allCases) {
        didSet {
            rebuildOverlayBuffer()
            // A layer hidden while its object is mid-hover shouldn't leave
            // a stale outline around something no longer visible.
            if let hoveredObjectIndex, objects.indices.contains(hoveredObjectIndex), !layerVisibility.contains(objects[hoveredObjectIndex].layer) {
                self.hoveredObjectIndex = nil
            }
        }
    }
    /// "Scene Preview Mode" (roadmap 7.1): real `Trigger.id`s the camera is
    /// currently "inside" per `triggerContains`, see that function's doc
    /// comment. Empty (the default) when preview mode is off.
    var activeTriggerIDs: Set<UInt32> = [] {
        didSet { rebuildOverlayBuffer() }
    }
    /// "Collision Volume Overlay": world-space line-segment endpoints for
    /// every object's collision box (asset-provided or auto-generated , 
    /// see `ModelViewerRenderer.generateCollisionDataFromMesh`), folded
    /// into `overlayLineBuffer` alongside trigger/camera/AI wireframes
    /// whenever `LevelViewerWindow`'s "Show Collision Volume" toggle is on.
    var collisionVolumeWorldPositions: [(SIMD3<Float>, SIMD3<Float>)] = [] {
        didSet { rebuildOverlayBuffer() }
    }
    /// "Crate Detonation Chains": draws a line from every real `Instance`
    /// with a non-empty `childInstanceIDs` to each of its real chain
    /// targets, confirmed, by directly scanning the real disc, to be
    /// exclusively used by `DETONATOR_CRATE` (TNT/exclamation-style
    /// detonators) pointing at `NITROCRATE`/`TNTCRATE` targets (65 real
    /// examples checked across 40+ levels, every single target resolving
    /// to one of those two object types, never anything else). Not a
    /// guess at the field's meaning: `PlacedInstance.childInstanceIDs`
    /// already exists, decoded and independently editable via
    /// `InstanceInspectorView`'s "Child Instances" section, this only
    /// visualizes what's already real, on-disk data.
    var showCrateChains = false {
        didSet { rebuildOverlayBuffer() }
    }
    private static let activeTriggerColor = SIMD3<Float>(1.0, 0.25, 0.15)
    private var overlayLineBuffer: MTLBuffer?
    private var overlayLineVertexCount = 0
    /// "Hover highlight" (Level Editor overhaul, Phase 3): whatever object
    /// `hoverObject(at:viewSize:)` last found under the cursor, tracked
    /// separately from `selectedObjectIndex`, hover follows the mouse
    /// continuously, selection only changes on click. Kept in its own tiny
    /// buffer (`hoverLineBuffer`) rather than folded into `overlayLineBuffer`
    /// since this one rebuilds on every mouse-moved event, not just on
    /// selection/edit changes.
    private(set) var hoveredObjectIndex: Int? {
        didSet {
            guard oldValue != hoveredObjectIndex else { return }
            rebuildHoverBuffer()
        }
    }
    private var hoverLineBuffer: MTLBuffer?
    private var hoverLineVertexCount = 0
    /// Testability hook, mirrors `hasCollisionFill`.
    var hasHoverOutline: Bool { hoverLineBuffer != nil && hoverLineVertexCount > 0 }
    /// "Selection outline": a dedicated wireframe box around whichever
    /// object `selectedObjectIndex` names, independent of whether its
    /// gizmo happens to be visible on screen. The gizmo alone used to be
    /// the only visual sign of what's selected, fine when it's on
    /// screen and readable, but a large or distant object's gizmo can be
    /// tiny or clipped, leaving no visible cue that anything is selected
    /// at all. Same wireframe-box approach as `hoverLineBuffer` (see
    /// `rebuildHoverBuffer`'s doc comment), a distinct amber color so it
    /// never reads as the (white) hover cue or a gizmo axis.
    private var selectionLineBuffer: MTLBuffer?
    private var selectionLineVertexCount = 0
    private static let selectionOutlineColor = SIMD3<Float>(1.0, 0.8, 0.2)
    /// Testability hook, mirrors `hasHoverOutline`.
    var hasSelectionOutline: Bool { selectionLineBuffer != nil && selectionLineVertexCount > 0 }
    /// "Chunk-Based Architecture" (Part 2): the translucent fill for every
    /// visible boundary wall, separate from `overlayLineBuffer` because
    /// it draws as triangles through `translucentQuadPipelineState`, not
    /// lines through `collisionLineColoredPipelineState`.
    private var chunkWallTriangleBuffer: MTLBuffer?
    private var chunkWallTriangleVertexCount = 0
    /// The level's real collision mesh, filled and opaque, see
    /// `ModelViewerGPUContext.collisionFillPipelineState`'s doc comment
    /// for why this is the actual fix for "scenery looks scattered with
    /// massive gaps": the reference tool renders this by default as the
    /// level's real ground, with decorative scenery *off* by default: this
    /// build's Level Viewer never rendered it at all, so what showed was
    /// only the sparse decorative props with nothing connecting them.
    /// Built once at upload time (unlike `overlayLineBuffer`, this doesn't
    /// depend on any runtime-changing state like active-trigger
    /// highlighting), gated at draw time by `layerVisibility.contains(.collision)`.
    private var collisionFillBuffer: MTLBuffer?
    /// Not `private`: "Rebuild All Collision"'s post-save overlay refresh
    /// (`refreshingCollisionFillBuffer(with:)` below) needs a way for
    /// `LevelViewerWindow`/tests to confirm the GPU-bound fill buffer
    /// actually changed, not just that the rebuild function returned
    /// something, see this app's own established discipline of verifying
    /// a UI-visible effect actually took place rather than trusting the
    /// data pipeline alone.
    var collisionFillVertexCount = 0
    /// "Drop-to-Floor Placement": the same real, mirrored collision
    /// triangles `rebuildCollisionFillBuffer` uploads to the GPU, kept
    /// around CPU-side too so `placeObject` can raycast against the
    /// level's actual walkable surface instead of an assumed flat ground
    /// plane. Empty for scenery-only `.sm2` levels with no `ColData`, same
    /// "nothing to draw/hit" posture as the fill buffer itself. Not
    /// `private` for the same reason as `collisionFillVertexCount` above.
    var collisionTriangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []

    /// Builds one combined interleaved position+color triangle buffer from
    /// every real `CollisionMesh` this level's file (and, when loaded, its
    /// sibling actor file) carries, `ColData` only lives in `.RM2` files
    /// (confirmed: `SMViewer.cs` has no ColData handling at all), so a
    /// scenery-only `.sm2` node passes an empty array here and this is a
    /// no-op, same "nothing to draw" posture the rest of this renderer
    /// already has for absent data. Flat-colored by `surfaceID`
    /// (`ModelViewerRenderer.color(forSurfaceID:)`, the same stable
    /// palette the standalone Collision Viewer's wireframe already uses)
    /// rather than lit, this format's collision vertices carry no decoded
    /// normals to light with, and a flat-colored floor still reads clearly
    /// as solid ground.
    ///
    /// Real, previously-undiscovered gap this task's own instructions
    /// specifically warned about verifying: this was only ever called once,
    /// at renderer construction (`init`), nothing refreshed the "Collision
    /// / Ground Floor" overlay after any later collision-affecting save
    /// (not just "Rebuild All Collision", the pre-existing "Update
    /// Collision for Moved Objects" save had the exact same staleness gap,
    /// just never surfaced because nothing before this exercised it right
    /// after a save with the layer visible). `refreshingCollisionFillBuffer
    /// (with:)` below is the fix: a non-`private` entry point a save's own
    /// completion handler can call with the freshly rebuilt mesh(es), so
    /// toggling the layer back on (or leaving it on) actually shows what
    /// was just written, not the stale mesh from when the Level Viewer
    /// first opened.
    func rebuildCollisionFillBuffer(meshes: [CollisionMesh]) {
        var floats: [Float] = []
        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for mesh in meshes {
            for triangle in mesh.triangles {
                guard triangle.vertexIndex1 < mesh.vertices.count,
                      triangle.vertexIndex2 < mesh.vertices.count,
                      triangle.vertexIndex3 < mesh.vertices.count
                else { continue }
                let color = ModelViewerRenderer.mutedColor(forSurfaceID: triangle.surfaceID)
                var worldVerts: [SIMD3<Float>] = []
                for index in [triangle.vertexIndex1, triangle.vertexIndex2, triangle.vertexIndex3] {
                    // "Coordinate-System Overhaul", see the matching
                    // comment in `upload(collisionMesh:)`: same raw-vertex
                    // X mirror, applied here too so the Level Viewer's
                    // floor fill lines up with scenery/instances instead of
                    // drifting from the standalone Collision Viewer.
                    let v = mesh.vertices[index]
                    let world = SIMD3<Float>(-v.x, v.y, v.z)
                    worldVerts.append(world)
                    floats.append(contentsOf: [world.x, world.y, world.z, color.x, color.y, color.z])
                }
                triangles.append((worldVerts[0], worldVerts[1], worldVerts[2]))
            }
        }
        collisionTriangles = triangles
        guard !floats.isEmpty else {
            collisionFillBuffer = nil
            collisionFillVertexCount = 0
            return
        }
        collisionFillVertexCount = floats.count / 6
        collisionFillBuffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    /// Named entry point for refreshing the "Collision / Ground Floor"
    /// overlay after a save that actually changed the collision mesh (see
    /// `rebuildCollisionFillBuffer`'s own doc comment for the staleness gap
    /// this exists to close), a thin, clearly-named wrapper rather than
    /// exposing the "build it the first time" name at call sites that are
    /// conceptually doing something different ("refresh the already-built
    /// one after the fact").
    func refreshingCollisionFillBuffer(with meshes: [CollisionMesh]) {
        rebuildCollisionFillBuffer(meshes: meshes)
    }

    /// Möller–Trumbore ray/triangle intersection, standard, well-known
    /// algorithm (not a guess), used by "Drop-to-Floor Placement" to find
    /// where a placement ray actually hits the level's real collision
    /// geometry. Returns the intersection distance along `direction`
    /// (`nil` if the ray misses the triangle or hits behind the origin).
    private static func rayTriangleIntersection(origin: SIMD3<Float>, direction: SIMD3<Float>, v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>) -> Float? {
        let epsilon: Float = 1e-6
        let edge1 = v1 - v0
        let edge2 = v2 - v0
        let pvec = simd_cross(direction, edge2)
        let det = simd_dot(edge1, pvec)
        guard abs(det) > epsilon else { return nil }
        let invDet = 1 / det
        let tvec = origin - v0
        let u = simd_dot(tvec, pvec) * invDet
        guard u >= 0, u <= 1 else { return nil }
        let qvec = simd_cross(tvec, edge1)
        let v = simd_dot(direction, qvec) * invDet
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(edge2, qvec) * invDet
        guard t > epsilon else { return nil }
        return t
    }

    /// "Drop-to-Floor Placement": casts the same screen-space ray
    /// `worldPositionOnGroundPlane` unprojects, but against the level's
    /// real, decoded collision triangles instead of an assumed flat plane
    ///, the closest hit (smallest `t`) wins, so placing on a raised
    /// platform lands on the platform, not the ground beneath it. `nil`
    /// when there's no collision data for this level or the ray hits
    /// nothing (e.g. aimed at open sky), letting the caller fall back to
    /// the ground-plane heuristic.
    func worldPositionOnCollisionMesh(at screenPoint: CGPoint, viewSize: CGSize) -> SIMD3<Float>? {
        guard !collisionTriangles.isEmpty else { return nil }
        let viewProjection = currentViewProjection(viewSize: viewSize)
        let inverse = viewProjection.inverse
        let ndcX = Float(screenPoint.x / max(viewSize.width, 1)) * 2 - 1
        let ndcY = Float(screenPoint.y / max(viewSize.height, 1)) * 2 - 1

        func unproject(ndcZ: Float) -> SIMD3<Float>? {
            let clip = inverse * SIMD4<Float>(ndcX, ndcY, ndcZ, 1)
            guard abs(clip.w) > 0.0001 else { return nil }
            return SIMD3(clip.x, clip.y, clip.z) / clip.w
        }
        guard let nearPoint = unproject(ndcZ: 0), let farPoint = unproject(ndcZ: 1) else { return nil }
        let direction = farPoint - nearPoint

        var closestT: Float?
        for (v0, v1, v2) in collisionTriangles {
            guard let t = LevelViewerRenderer.rayTriangleIntersection(origin: nearPoint, direction: direction, v0: v0, v1: v1, v2: v2) else { continue }
            if closestT == nil || t < closestT! { closestT = t }
        }
        guard let t = closestT else { return nil }
        return nearPoint + direction * t
    }

    /// - Parameters:
    ///   - placements: each resolved object's world position
    ///     (translation-only, see the type doc comment) paired with its
    ///     fully textured mesh.
    ///   - instanceMarkers: "Direct .RM2 Write-Back", every `Instance`
    ///     record from the same file, drawn as a placeholder cube (see
    ///     `LevelViewerContext.instanceMarkers`'s doc comment for why not a
    ///     real mesh) but fully selectable/gizmo-editable/save-able like
    ///     any other object.
    ///   - triggers/cameras: "Level Editor Overhaul", every `Trigger`/
    ///     `Camera` record from the same file. Both draw as an oriented
    ///     line wireframe box (`overlayLineBuffer`), not a solid mesh , 
    ///     their real, decoded position/size/rotation, just no gizmo
    ///     write-back (unlike Instance markers, this build has no
    ///     byte-exact encoder for either record type yet). Still fully
    ///     selectable, so clicking one opens its real inspector.
    /// "The Forge Palette" (Part 4C): the same `GraphicsAssetIndex` used to
    /// resolve every existing `Instance`, kept around so a *newly placed*
    /// object (which has no `Instance` record to resolve from yet) can
    /// still get real geometry via `AssetResolver.resolveInstanceObject`
    /// instead of always falling back to the amber marker, a freshly
    /// dropped crate should look like a crate immediately, not just once
    /// the file round-trips through a save/reload.
    private var assetIndex: GraphicsAssetIndex = GraphicsAssetIndex()
    /// "No More Placeholder Squares": the same shared `Startup/Default.rm2`
    /// index `WorkspaceViewModel.resolvedInstanceAssets` already falls
    /// back to for existing Instance markers, kept here too so a
    /// *newly placed* shared object (e.g. dropping a `BASICCRATE` from
    /// the Forge Palette) also resolves to its real mesh immediately,
    /// not just after a save/reload round-trip through the level's own
    /// file. See `AssetResolver.resolveInstanceObject`'s doc comment for
    /// where this data actually comes from.
    private var defaultAssetIndex: GraphicsAssetIndex = GraphicsAssetIndex()
    /// "Global Thumbnails": mirrors `WorkspaceViewModel.globalObjectThumbnails`
    /// (kept in sync by `LevelViewerWindow`, which owns the `workspace`
    /// reference this renderer deliberately doesn't have), every object
    /// this *session* has resolved successfully in some *other* level.
    /// Checked only after this level's own `assetIndex`/`defaultAssetIndex`
    /// both fail, by `canResolveObjectID`/`resolvedAsset(forObjectID:)`
    /// *and* `spawnInstance` alike, so what the Forge Palette's thumbnail
    /// promises and what actually gets placed always agree, a thumbnail
    /// sourced from elsewhere in the workspace is never a "looks
    /// available, places as an amber cube anyway" trap.
    var globalObjectFallbacks: [UInt16: ResolvedModelAsset] = [:]
    /// "Cross-Level Forge Placement": the byte-level counterpart to
    /// `globalObjectFallbacks`, kept in sync by `LevelViewerWindow`
    /// alongside it (same source, `workspace.globalObjectGameObjectSources`).
    /// `spawnInstance` records the matching entry onto a newly-placed
    /// object's own `pendingCrossLevelGameObjectSource` whenever it resolves
    /// through this map rather than `assetIndex`/`defaultAssetIndex`, so a
    /// save can actually copy the real data in later, see
    /// `CrossLevelGameObjectSource`'s own doc comment.
    var globalObjectGameObjectSources: [UInt16: CrossLevelGameObjectSource] = [:]
    /// Every synthetic ID handed out this session for a placed-but-unsaved
    /// object, one higher than the highest real `Instance.id` seen at
    /// upload time, see `spawnInstance`'s doc comment.
    private var nextSyntheticInstanceID: UInt32 = 1
    /// "Unrestricted Chunk Free-Edit Mode": real `Instance.objectID`,
    /// keyed by that instance's `ChunkNode.id`, populated once at
    /// `upload()` time, read by `duplicateSelectedObject` so it can spawn
    /// a copy of an *existing* placement without threading the full
    /// `PlacedInstance` through `GPULevelObject` just for this one use.
    private var instanceObjectIDByNodeID: [UUID: UInt16] = [:]
    /// Same idea as `nextSyntheticInstanceID`, for waypoints added this
    /// session via `spawnAIWaypoint`, a separate counter/namespace since
    /// `AIPosition` and `Instance` record IDs are independent (see
    /// `ResolvedModelAsset.id`'s own doc comment for the same "these are
    /// different on-disk ID spaces" reasoning).
    private var nextSyntheticAIPositionID: UInt32 = 1
    /// Same idea as `nextSyntheticAIPositionID`, for Triggers/Cameras
    /// added this session via `spawnTrigger`/`spawnCamera`, "Add
    /// Trigger"/"Add Camera" closing the parity gap the original editor's
    /// `Menu_AddNew` has for these two record types (not just Instances/
    /// AI-waypoints).
    private var nextSyntheticTriggerID: UInt32 = 1
    private var nextSyntheticCameraID: UInt32 = 1
    /// "Interactive Scenery Placement": scenery placements have no on-disk
    /// `id` field at all (`SceneryModelPlacement` is just an array element,
    /// see its own doc comment), unlike every other synthetic-ID counter
    /// here, this exists purely as an internal per-session bookkeeping key
    /// for `GPULevelObject.syntheticSceneryID`, not to avoid colliding with
    /// a real on-disk ID space that doesn't exist.
    private var nextSyntheticSceneryID: UInt32 = 1
    /// Same idea as `nextSyntheticTriggerID`/`nextSyntheticCameraID`, for
    /// `AIPathRecord`s added this session. Unlike every other placeable
    /// type here, `AIPathRecord` has no spatial position of its own (just
    /// `id` + 5 raw `UInt16` args, see its own doc comment), so it can
    /// never be a `GPULevelObject` and can't ride `objects`/`canDelete`/
    /// `deleteObject` the way Instance/Trigger/Camera/AIWaypoint do.
    /// Tracked as its own small pair of arrays instead, mirrored into the
    /// save pipeline the same way (`pendingNewAIPaths`/
    /// `pendingRemovedAIPathIDs`).
    private var nextSyntheticAIPathID: UInt32 = 1
    private(set) var newAIPaths: [(id: UInt32, args: [UInt16])] = []
    private(set) var removedAIPathIDs: Set<UInt32> = []
    /// Whether the destination `.camera` collection is the Demo layout , 
    /// `WorldPlacementWriter.writeNewCamera(isDemo:)` needs to match it
    /// (`Camera.cs`'s own `ParentType == SectionType.CameraDemo` check
    /// omits `UnkShort`/`UnkByte` entirely). Set from `WorkspaceViewModel.
    /// cameraCollectionIsDemo(inSameFileAs:)` at construction time;
    /// `false` (non-Demo) when there's no existing Camera collection to
    /// match yet, the same "no collection to add into" case `spawnCamera`
    /// can't do anything about until the level already has at least one
    /// real Camera, matching `cameraCollectionNode`'s own limitation.
    private let isDemoCameraCollection: Bool
    /// "Move an Existing Scenery Placement, Save": the one `ChunkNode`
    /// every real on-disk scenery placement's `sceneryMatrixFileOffset` is
    /// relative to (`SceneryModelPlacement.matrixFileOffset`'s own doc
    /// comment, "relative to the enclosing SceneryData record's own
    /// start"), unlike Instance/Trigger/Camera, a scenery placement has
    /// no `ChunkNode` of its own (it's one array element inside this
    /// single shared record), so this is threaded in once at construction
    /// instead of per-object like `GPULevelObject.sourceNode`. `nil` for
    /// any session (standalone Model Viewer, tests with no real context)
    /// that never had a real scenery file to begin with , 
    /// `pendingSceneryTransformOverrides` is simply empty in that case.
    private let sceneryFileNode: ChunkNode?

    init?(
        placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)],
        sceneryFileNode: ChunkNode? = nil,
        instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)] = [],
        resolvedInstanceAssets: [UUID: ResolvedModelAsset] = [:],
        resolvedFromSharedDefault: Set<UUID> = [],
        assetIndex: GraphicsAssetIndex = GraphicsAssetIndex(),
        defaultAssetIndex: GraphicsAssetIndex = GraphicsAssetIndex(),
        triggers: [(node: ChunkNode, trigger: TriggerVolume)] = [],
        cameras: [(node: ChunkNode, camera: PlacedCamera)] = [],
        chunkLinks: [(node: ChunkNode, link: ChunkLink)] = [],
        aiPositions: [(node: ChunkNode, marker: AIPositionMarker)] = [],
        aiPaths: [(node: ChunkNode, path: AIPathRecord)] = [],
        collisionMeshes: [CollisionMesh] = [],
        isDemoCameraCollection: Bool = false
    ) {
        guard let context = ModelViewerGPUContext.shared else { return nil }
        self.context = context
        self.assetIndex = assetIndex
        self.defaultAssetIndex = defaultAssetIndex
        self.isDemoCameraCollection = isDemoCameraCollection
        self.sceneryFileNode = sceneryFileNode
        super.init()
        nextSyntheticAIPathID = (aiPaths.map(\.path.id).max() ?? 0) + 1
        self.aiPaths = aiPaths
        // `reduce(into:)` first-wins rather than `Dictionary(uniqueKeysWithValues:)`
        //, a real .RM2 with a duplicate AIPath ID (malformed source data,
        // not expected but not this code's place to trap on) shouldn't crash
        // the whole Level Viewer on open.
        liveAIPathArgs = aiPaths.reduce(into: [:]) { result, entry in
            if result[entry.path.id] == nil { result[entry.path.id] = entry.path.args }
        }
        nextSyntheticInstanceID = (instanceMarkers.map(\.instance.id).max() ?? 0) + 1
        nextSyntheticAIPositionID = (aiPositions.map(\.marker.id).max() ?? 0) + 1
        nextSyntheticTriggerID = (triggers.map(\.trigger.id).max() ?? 0) + 1
        nextSyntheticCameraID = (cameras.map(\.camera.id).max() ?? 0) + 1
        upload(placements: placements, instanceMarkers: instanceMarkers, resolvedInstanceAssets: resolvedInstanceAssets, resolvedFromSharedDefault: resolvedFromSharedDefault, triggers: triggers, cameras: cameras, chunkLinks: chunkLinks, aiPositions: aiPositions)
        rebuildCollisionFillBuffer(meshes: collisionMeshes)
    }

    private func upload(
        placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)],
        instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)],
        resolvedInstanceAssets: [UUID: ResolvedModelAsset],
        resolvedFromSharedDefault: Set<UUID> = [],
        triggers: [(node: ChunkNode, trigger: TriggerVolume)],
        cameras: [(node: ChunkNode, camera: PlacedCamera)],
        chunkLinks: [(node: ChunkNode, link: ChunkLink)],
        aiPositions: [(node: ChunkNode, marker: AIPositionMarker)]
    ) {
        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var levelObjects: [GPULevelObject] = []
        levelObjects.reserveCapacity(placements.count + instanceMarkers.count + triggers.count + cameras.count)
        // "Massive level rendering" (performance mandate): one texture
        // cache shared across every placement built in this single
        // upload() call, see TextureUploadCache's own doc comment for why
        // this is scoped per-file/per-call rather than a persistent
        // cross-file cache.
        let textureCache = TextureUploadCache()
        // See `MeshUploadCache`'s own doc comment: shares GPU vertex/index
        // buffers across placements of the same *static* (unskinned) mesh.
        let meshCache = MeshUploadCache()

        // Real, reported bug (severe): one bad coordinate, NaN or
        // infinite, e.g. from a still-unverified field in the Instance/
        // Trigger/Camera decode path, which had never actually run against
        // real data before the sibling-lookup fix that lets it reach the
        // Level Viewer at all, silently poisoned `minBound`/`maxBound` via
        // `simd_min`/`simd_max` (IEEE 754 min/max with a NaN operand is
        // itself NaN or unspecified). That NaN flows straight into
        // `boundsCenter`/`boundsRadius` below, then into the orbit camera's
        // eye position (`orbitEyeWorldPosition`) and every view/projection
        // matrix built from it, a NaN camera transform draws nothing at
        // all, anywhere, including scenery placements that resolved and
        // uploaded perfectly fine. A level that always rendered its terrain
        // before could go instantly to a fully black viewport the moment
        // its Instance/Trigger/Camera data first became reachable, with
        // only unrelated small on-screen UI (wireframe markers built from
        // the *same* bad records, plus the gizmo) still visible. Skipping a
        // non-finite point here keeps that one record from taking down the
        // camera for the whole level; the record itself may still be
        // individually mispositioned, which is a separate, real bug in
        // whichever decoder produced it.
        func expandBounds(_ p: SIMD3<Float>) {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return }
            minBound = simd_min(minBound, p)
            maxBound = simd_max(maxBound, p)
        }

        // Performance fix (audit): this loop (and the instance-marker loop
        // below it) calls `buildGPUSubmeshes`, `device.makeBuffer`/
        // `makeTexture`, once per unique asset in the level, and the whole
        // `upload()` call runs inside `Task.detached` (see the `.task` in
        // `LevelViewerWindow.swift`), a single continuous closure body.
        // Unlike a GCD queue, Swift's Task executor never drains an
        // autorelease pool mid-body on its own, so every Objective-C/Metal
        // autoreleased temporary created across the *entire* level's worth
        // of asset builds used to accumulate until this whole function
        // returned. `autoreleasepool` per iteration drains them every
        // object instead.
        for (worldPosition, rotation, scale, asset, matrixFileOffset) in placements {
            autoreleasepool {
            let meshEntry: MeshUploadCache.Entry?
            // Only static (unskinned) meshes are safe to share across
            // placements, see `MeshUploadCache`'s own doc comment.
            if asset.skeleton == nil, let cached = meshCache.entry(for: asset.recordID) {
                meshEntry = cached
            } else {
                let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: asset.mesh, submeshMaterials: asset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture, textureCache: textureCache)
                if built.submeshes.isEmpty {
                    meshEntry = nil
                } else {
                    let localBounds = Self.localBounds(of: asset.mesh)
                    let fresh = MeshUploadCache.Entry(submeshes: built.submeshes, localBoundsMin: localBounds.min, localBoundsMax: localBounds.max, boundingRadius: Self.boundingRadius(of: asset.mesh))
                    if asset.skeleton == nil {
                        meshCache.store(fresh, for: asset.recordID)
                    }
                    meshEntry = fresh
                }
            }
            guard let meshEntry else { return }
            // See `ModelViewerRenderer.collisionDataFromLocalBounds`'s own
            // doc comment, real bug: this existing, already-on-disk
            // scenery placement used to get no collision data at all,
            // silently skipped by both the automatic "new object" and the
            // opt-in "moved object" collision-sync passes.
            let sceneryAssetCollisionData = asset.skeleton?.collisionData ?? []
            let sceneryGeneratedCollisionData = sceneryAssetCollisionData.isEmpty
                ? ModelViewerRenderer.collisionDataHuggingMesh(mesh: asset.mesh)
                : []
            levelObjects.append(GPULevelObject(worldPosition: worldPosition, rotation: rotation, scale: scale, displayName: asset.displayName, submeshes: meshEntry.submeshes, layer: .scenery, boundingRadius: meshEntry.boundingRadius, localBoundsMin: meshEntry.localBoundsMin, localBoundsMax: meshEntry.localBoundsMax, generatedCollisionData: sceneryGeneratedCollisionData, assetCollisionData: sceneryAssetCollisionData, sceneryMatrixFileOffset: matrixFileOffset))
            // Bounds are tracked from placement position, not local mesh
            // extent, for a whole-level view, "where objects are" matters
            // far more than any one object's own size.
            expandBounds(worldPosition)
            }
        }

        let markerMesh = Self.makeMarkerCubeAsset()
        let markerBuilt = ModelViewerRenderer.buildGPUSubmeshes(mesh: markerMesh.mesh, submeshMaterials: [markerMesh.material], device: device, fallbackTexture: context.fallbackTexture, textureCache: textureCache)
        let markerRadius = Self.boundingRadius(of: markerMesh.mesh)
        for (node, instance) in instanceMarkers {
            autoreleasepool {
            // "Unrestricted Chunk Free-Edit Mode": remembered so
            // `duplicateSelectedObject` can look up a real, existing
            // Instance's own objectID by its node identity, without
            // needing to thread `PlacedInstance` itself through
            // `GPULevelObject` just for this one use.
            instanceObjectIDByNodeID[node.id] = instance.objectID
            let worldPosition = ModelViewerRenderer.mirroredWorldPosition(SIMD3(instance.position.x, instance.position.y, instance.position.z))
            // "Comprehensive Instance Population" (Part 4B): real geometry
            // when this build could resolve one (GameObject -> GraphicsInfo
            // -> skinned mesh or rigid model-link parts), the amber
            // placeholder cube otherwise, never a fabricated stand-in.
            var submeshes = markerBuilt.submeshes
            var boundingRadius = markerRadius
            // See `ModelViewerRenderer.collisionDataFromLocalBounds`'s own
            // doc comment, defaults match the marker cube's own extent
            // (`GPULevelObject.localBoundsMin`/`Max`'s own default) so an
            // unresolved Instance (still the amber placeholder) at least
            // gets a small, honest collision box instead of none at all;
            // overwritten below with the real asset's own bounds whenever
            // one resolves.
            var localBoundsMin = SIMD3<Float>(-0.5, -0.5, -0.5)
            var localBoundsMax = SIMD3<Float>(0.5, 0.5, 0.5)
            // Set only when a real asset resolves below, `collisionDataHuggingMesh`
            // needs the real per-vertex mesh, which only exists inside that
            // scope; the unresolved-placeholder case below still falls back
            // to a single box from the marker cube's own small extent.
            var resolvedMeshForCollision: MeshAsset?
            if let resolvedAsset = resolvedInstanceAssets[node.id] {
                // "No Cross-Level GPU Cache" fix: this marker's geometry
                // resolved through the shared, process-wide `Default.rm2`
                // fallback (real crates/pickups/Wumpa reused across every
                // level), route it through the persistent, cross-level
                // cache on `context` instead of this call's own per-upload
                // `meshCache`/`textureCache`, so the GPU work is only ever
                // done once per *process*, not once per level open. See
                // `ModelViewerGPUContext.sharedDefaultAssetMeshCache`'s own
                // doc comment for why `recordID` alone is a safe key here
                // specifically (unlike the level's own resolved assets,
                // which stay on the per-upload caches below, unchanged).
                let usesSharedCache = resolvedFromSharedDefault.contains(node.id)
                let meshLookupCache = usesSharedCache ? context.sharedDefaultAssetMeshCache : meshCache
                let textureBuildCache = usesSharedCache ? context.sharedDefaultAssetTextureCache : textureCache
                // Same static-mesh sharing as the scenery placements loop
                // above, see `MeshUploadCache`'s own doc comment. A real
                // win here too: repeated Instance placements (crates,
                // platforms) are common, and every skinned/animated one is
                // still excluded by the `skeleton == nil` gate.
                if resolvedAsset.skeleton == nil, let cached = meshLookupCache.entry(for: resolvedAsset.recordID) {
                    submeshes = cached.submeshes
                    boundingRadius = cached.boundingRadius
                    localBoundsMin = cached.localBoundsMin
                    localBoundsMax = cached.localBoundsMax
                } else {
                    let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: resolvedAsset.mesh, submeshMaterials: resolvedAsset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture, textureCache: textureBuildCache)
                    if !built.submeshes.isEmpty {
                        submeshes = built.submeshes
                        boundingRadius = Self.boundingRadius(of: resolvedAsset.mesh)
                        let localBounds = Self.localBounds(of: resolvedAsset.mesh)
                        localBoundsMin = localBounds.min
                        localBoundsMax = localBounds.max
                        if resolvedAsset.skeleton == nil {
                            meshLookupCache.store(MeshUploadCache.Entry(submeshes: submeshes, localBoundsMin: localBounds.min, localBoundsMax: localBounds.max, boundingRadius: boundingRadius), for: resolvedAsset.recordID)
                        }
                    }
                }
                // Real mesh available regardless of which branch above ran
                // (cache hit or fresh build), `resolvedAsset` itself is
                // this whole block's binding.
                resolvedMeshForCollision = resolvedAsset.mesh
            }
            guard !submeshes.isEmpty else { return }
            let instanceRotation = Self.quaternion(fromEulerDegrees: instance.rotationDegrees)
            // See `ModelViewerRenderer.collisionDataFromLocalBounds`'s own
            // doc comment, real bug: this existing, already-on-disk
            // Instance used to get no collision data at all (`[]`
            // hardcoded), silently skipped by both the automatic "new
            // object" and the opt-in "moved object" collision-sync passes.
            // See `collisionDataHuggingMesh`'s own doc comment for why a
            // resolved real asset gets a multi-box hug instead of one loose
            // AABB; the unresolved-placeholder case (`resolvedMeshForCollision
            // == nil`) keeps the single small box matching the marker
            // cube's own extent.
            let instanceAssetCollisionData = resolvedInstanceAssets[node.id]?.skeleton?.collisionData ?? []
            let instanceGeneratedCollisionData = instanceAssetCollisionData.isEmpty
                ? (resolvedMeshForCollision.map { ModelViewerRenderer.collisionDataHuggingMesh(mesh: $0) } ?? ModelViewerRenderer.collisionDataFromLocalBounds(min: localBoundsMin, max: localBoundsMax))
                : []
            levelObjects.append(GPULevelObject(
                worldPosition: worldPosition,
                rotation: instanceRotation,
                displayName: "Instance #\(instance.id) (Object \(instance.objectID))",
                submeshes: submeshes,
                layer: .actors,
                boundingRadius: boundingRadius,
                sourceNode: node,
                originalPositionW: instance.position.w,
                comRotationRaw: instance.comRotationRaw,
                generatedCollisionData: instanceGeneratedCollisionData,
                assetCollisionData: instanceAssetCollisionData
            ))
            expandBounds(worldPosition)
            }
        }

        for (node, trigger) in triggers {
            let worldPosition = ModelViewerRenderer.mirroredWorldPosition(SIMD3(trigger.position.x, trigger.position.y, trigger.position.z))
            levelObjects.append(GPULevelObject(
                worldPosition: worldPosition,
                rotation: simd_quatf(vector: trigger.rotationQuaternion),
                displayName: "Trigger #\(trigger.id)",
                submeshes: [],
                layer: .triggers,
                sourceNode: node,
                generatedCollisionData: [],
                assetCollisionData: []
            ))
            expandBounds(worldPosition)
        }

        for (node, camera) in cameras {
            let worldPosition = ModelViewerRenderer.mirroredWorldPosition(SIMD3(camera.position.x, camera.position.y, camera.position.z))
            levelObjects.append(GPULevelObject(
                worldPosition: worldPosition,
                rotation: simd_quatf(vector: camera.rotationQuaternion),
                displayName: "Camera #\(camera.id) (\(camera.cameraType1.displayName))",
                submeshes: [],
                layer: .cameras,
                sourceNode: node,
                generatedCollisionData: [],
                assetCollisionData: []
            ))
            expandBounds(worldPosition)
            // "Spline & Camera Path Persistence" (roadmap 6.3): each real
            // control point gets its own selectable, draggable marker, and
            //, where its exact on-disk offset was captured at parse time
            // (`cameraControlPointFileOffset`), a real save path: dragging
            // it and saving patches just that point's 16 bytes at
            // `node.fileOffset + cameraControlPointFileOffset`, leaving the
            // rest of this variable-length Camera record untouched (see
            // `pendingCameraControlPointOverrides`). `sourceNode` is the
            // *camera's* node (a control point isn't a record of its own),
            // matching how `originalAIWaypointRawNodeType` etc. key off
            // their owning record.
            for (pointIndex, point) in Self.splineControlPoints(for: camera).enumerated() {
                let pointPosition = ModelViewerRenderer.mirroredWorldPosition(SIMD3(point.vector.x, point.vector.y, point.vector.z))
                levelObjects.append(GPULevelObject(
                    worldPosition: pointPosition,
                    displayName: "Camera #\(camera.id) control point \(pointIndex)",
                    submeshes: [],
                    layer: .cameras,
                    sourceNode: point.fileOffset != nil ? node : nil,
                    originalPositionW: point.vector.w,
                    cameraControlPointFileOffset: point.fileOffset,
                    generatedCollisionData: [],
                    assetCollisionData: []
                ))
                expandBounds(pointPosition)
            }
        }

        // "Chunk-Based Architecture" (Part 2): a selectable marker at each
        // real boundary wall's centroid, same treatment as trigger/camera
        // markers above, the wall's actual quad geometry draws separately
        // via `rebuildOverlayBuffer`'s translucent-plane pass.
        for (node, link) in chunkLinks {
            guard let wall = link.loadWall, !wall.isEmpty else { continue }
            let rawCentroid = wall.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.x, $1.y, $1.z) } / Float(wall.count)
            let centroid = ModelViewerRenderer.mirroredWorldPosition(rawCentroid)
            levelObjects.append(GPULevelObject(
                worldPosition: centroid,
                displayName: "Chunk Link #\(link.id): \(link.path)",
                submeshes: [],
                layer: .chunkBoundaries,
                sourceNode: node,
                generatedCollisionData: [],
                assetCollisionData: []
            ))
            expandBounds(centroid)
        }

        // "AI Pathfinding/Navmesh Editor" (roadmap 5.1): a selectable,
        // draggable marker per real `AIPosition` waypoint, same treatment
        // as trigger/camera markers (empty submeshes, drawn as a small
        // wireframe box by `rebuildOverlayBuffer`). Draggable via the same
        // generic gizmo every other object uses; deliberately excluded from
        // `pendingLevelOverrides` itself (`.actors`-only guard) since that
        // encodes `Instance` records, not `AIPosition` ones, a moved
        // waypoint's own byte-exact re-encode is `pendingAIWaypointOverrides`
        // below, via the real `WorldPlacementWriter.writeAIPosition`.
        for (node, marker) in aiPositions {
            let worldPosition = ModelViewerRenderer.mirroredWorldPosition(SIMD3(marker.position.x, marker.position.y, marker.position.z))
            levelObjects.append(GPULevelObject(
                worldPosition: worldPosition,
                displayName: "AI Waypoint #\(marker.id) (\(marker.nodeType?.displayName ?? "type \(marker.rawNodeType)"))",
                submeshes: [],
                layer: .aiWaypoints,
                sourceNode: node,
                originalPositionW: marker.position.w,
                originalAIWaypointRawNodeType: marker.rawNodeType
            ))
            expandBounds(worldPosition)
        }

        objects = levelObjects
        self.triggers = triggers
        self.cameras = cameras
        self.chunkLinks = chunkLinks
        self.aiPositions = aiPositions
        if minBound.x <= maxBound.x {
            boundsCenter = (minBound + maxBound) / 2
            let extent = maxBound - minBound
            boundsRadius = max(max(extent.x, extent.y), max(extent.z, 10))
        }
        rebuildOverlayBuffer()
        rebuildAIPathLineBuffer()
    }

    /// Kept alongside `objects` purely to rebuild `overlayLineBuffer` when
    /// layer visibility toggles, the wireframes themselves aren't part of
    /// the indexed-triangle `objects` draw path (see `GPULevelObject.
    /// submeshes`'s doc comment), so they need their own source data to
    /// redraw from.
    private var triggers: [(node: ChunkNode, trigger: TriggerVolume)] = []
    private var cameras: [(node: ChunkNode, camera: PlacedCamera)] = []
    /// "Chunk-Based Architecture" (Part 2): every real `ChunkLink` in the
    /// currently loaded chunk, kept alongside `objects` for the same reason
    /// `triggers`/`cameras` are, `rebuildOverlayBuffer` needs the raw
    /// source data to redraw wall wireframes/fills when the layer toggles.
    private(set) var chunkLinks: [(node: ChunkNode, link: ChunkLink)] = []
    /// "AI Pathfinding/Navmesh Editor" (roadmap 5.1): every real
    /// `AIPosition` waypoint in the currently loaded chunk, same
    /// `rebuildOverlayBuffer` reasoning as `triggers`/`cameras` above.
    private(set) var aiPositions: [(node: ChunkNode, marker: AIPositionMarker)] = []
    /// "AI Path Connector Visualization + In-Viewport Endpoint Picking":
    /// every real, on-disk `AIPath` in the currently loaded chunk. Unlike
    /// `aiPositions`, `AIPath` has no spatial position of its own, it's
    /// just two `AIPosition` IDs (`args[0]`/`args[1]`), so there's no
    /// `GPULevelObject` counterpart to drag; `liveAIPathArgs` (below) is
    /// this type's own equivalent of `objects[i].worldPosition`.
    private(set) var aiPaths: [(node: ChunkNode, path: AIPathRecord)] = []
    /// Live, possibly-edited args for every *existing* AI Path this
    /// session, keyed by real path ID, seeded from `aiPaths` at load time,
    /// mutated in place by `settingAIPathArgs`. Kept separate from
    /// `aiPaths` itself (rather than mutating that array directly) so
    /// `aiPaths` stays a stable, honest record of "what's really on disk,"
    /// matching every other `private(set)` original-data property here.
    private var liveAIPathArgs: [UInt32: [UInt16]] = [:]

    /// Control points for whichever of a camera's two sub-payload slots
    /// actually has spline/path data, `nil`-safe: most cameras have
    /// neither, in which case this returns an empty path and only the
    /// camera's own box marker draws. Paired with each point's real
    /// record-relative file offset (`nil` only if `controlPointFileOffsets`
    /// somehow came up short of `unkVectors`, which parsing never actually
    /// produces, defensive, not expected) so a dragged point can be
    /// patched back to its exact byte offset on save.
    private static func splineControlPoints(for camera: PlacedCamera) -> [(vector: SIMD4<Float>, fileOffset: Int?)] {
        for subtype in [camera.subtype1, camera.subtype2] {
            switch subtype {
            case .spline(let spline):
                return spline.unkVectors.enumerated().map { index, v in (v, spline.controlPointFileOffsets.indices.contains(index) ? spline.controlPointFileOffsets[index] : nil) }
            case .path(let path):
                return path.unkVectors.enumerated().map { index, v in (v, path.controlPointFileOffsets.indices.contains(index) ? path.controlPointFileOffsets[index] : nil) }
            default: continue
            }
        }
        return []
    }

    /// "Scene Preview Mode" (roadmap 7.1), real oriented-box containment:
    /// `point` transformed into the trigger's own local space (undo its
    /// real decoded rotation, then its real decoded position), tested
    /// against its real decoded half-extents. The same oriented box
    /// `appendBox` already draws as this trigger's wireframe, this just
    /// asks "is this point inside the box actually being drawn," nothing
    /// about trigger *semantics* (this format has no decoded "on enter"
    /// callback this build could hook into either way).
    static func triggerContains(_ trigger: TriggerVolume, point: SIMD3<Float>) -> Bool {
        let position = SIMD3(trigger.position.x, trigger.position.y, trigger.position.z)
        let rotation = simd_quatf(vector: trigger.rotationQuaternion)
        let localPoint = rotation.inverse.act(point - position)
        let halfExtents = SIMD3(max(trigger.size.x, 0.1), max(trigger.size.y, 0.1), max(trigger.size.z, 0.1)) / 2
        return abs(localPoint.x) <= halfExtents.x && abs(localPoint.y) <= halfExtents.y && abs(localPoint.z) <= halfExtents.z
    }

    /// Recomputes `activeTriggerIDs` from `cameraEyeWorldPosition` against
    /// every real trigger, call this periodically while "Scene Preview
    /// Mode" is on (`LevelViewerWindow` drives this from a timer, the same
    /// pattern the Animation Sandbox's own playback timer already uses).
    func updateActiveTriggers() {
        let eye = cameraEyeWorldPosition
        let newActive = Set(triggers.compactMap { Self.triggerContains($0.trigger, point: eye) ? $0.trigger.id : nil })
        // `activeTriggerIDs`'s `didSet` rebuilds the whole overlay buffer
        // (every trigger/camera/spline/AI waypoint/chunk wall, two fresh
        // `MTLBuffer` allocations), this is called 10x/second by Scene
        // Preview Mode's timer, so skipping the assignment when nothing
        // actually changed avoids that full rebuild on every tick the
        // camera doesn't cross a trigger boundary.
        guard newActive != activeTriggerIDs else { return }
        activeTriggerIDs = newActive
    }

    /// Rebuilds the line-primitive vertex buffer for trigger/camera
    /// wireframe boxes plus camera spline paths, everything in
    /// `overlayLineBuffer`, drawn through the same `collisionLineColoredPipelineState`
    /// the gizmo already uses (`LineVertexColorIn`: interleaved position +
    /// color). Skipped entirely for a hidden layer, both to save the (tiny)
    /// rebuild cost and so a hidden trigger/camera can't still be picked
    /// via `pickObject`, which only scans `objects`, layer-gating that
    /// list is `pickObject`'s job, this buffer is purely visual.
    private func rebuildOverlayBuffer() {
        var floats: [Float] = []
        func appendVertex(_ position: SIMD3<Float>, _ color: SIMD3<Float>) {
            floats.append(contentsOf: [position.x, position.y, position.z, color.x, color.y, color.z])
        }
        func appendBox(position: SIMD3<Float>, size: SIMD3<Float>, rotation: simd_quatf, color: SIMD3<Float>) {
            let half = size / 2
            let localCorners: [SIMD3<Float>] = [
                SIMD3(-half.x, -half.y, -half.z), SIMD3(half.x, -half.y, -half.z),
                SIMD3(half.x, half.y, -half.z), SIMD3(-half.x, half.y, -half.z),
                SIMD3(-half.x, -half.y, half.z), SIMD3(half.x, -half.y, half.z),
                SIMD3(half.x, half.y, half.z), SIMD3(-half.x, half.y, half.z)
            ]
            let corners = localCorners.map { position + rotation.act($0) }
            let edges: [(Int, Int)] = [
                (0, 1), (1, 2), (2, 3), (3, 0),
                (4, 5), (5, 6), (6, 7), (7, 4),
                (0, 4), (1, 5), (2, 6), (3, 7)
            ]
            for (a, b) in edges {
                appendVertex(corners[a], color)
                appendVertex(corners[b], color)
            }
        }

        // Roadmap 4.1 asks for a 3-color Red=Death/Green=Trigger/Blue=Solid
        // scheme. Green is real: every wireframe box here genuinely *is* a
        // `Trigger` record, a verified category, not a guess. Splitting
        // further into "death" vs. other triggers is not: `TriggerVolume`'s
        // `arg1`-`arg4`/`enabledMask`/`header` carry no decoded meaning
        // anywhere in this codebase (see `ModelViewerRenderer.color(forSurfaceID:)`'s
        // own doc comment for the identical situation with collision
        // surface IDs), inventing a "this bit pattern means deadly" rule
        // would be presenting a guess as decoded data. "Solid" isn't a
        // trigger-layer concept at all; that's what the Collision layer's
        // own (already real, already surface-ID-based) coloring covers.
        let triggerColor = SIMD3<Float>(0.35, 0.9, 0.4)
        let cameraColor = SIMD3<Float>(0.3, 0.85, 0.95)
        let splineColor = SIMD3<Float>(0.85, 0.35, 0.95)

        if layerVisibility.contains(.triggers) {
            for (_, trigger) in triggers {
                let position = ModelViewerRenderer.mirroredWorldPosition(SIMD3(trigger.position.x, trigger.position.y, trigger.position.z))
                let size = SIMD3(max(trigger.size.x, 0.1), max(trigger.size.y, 0.1), max(trigger.size.z, 0.1))
                // "Scene Preview Mode" (roadmap 7.1): a real, live geometric
                // containment test, see `cameraEyeWorldPosition`'s doc
                // comment for the "orbit camera as proxy" honesty note , 
                // against this trigger's real decoded oriented box, not a
                // fabricated "the player touched this" event.
                let color = activeTriggerIDs.contains(trigger.id) ? Self.activeTriggerColor : triggerColor
                appendBox(position: position, size: size, rotation: simd_quatf(vector: trigger.rotationQuaternion), color: color)
            }
        }
        if layerVisibility.contains(.cameras) {
            for (_, camera) in cameras {
                let position = ModelViewerRenderer.mirroredWorldPosition(SIMD3(camera.position.x, camera.position.y, camera.position.z))
                let size = SIMD3(max(camera.size.x, 0.1), max(camera.size.y, 0.1), max(camera.size.z, 0.1))
                appendBox(position: position, size: size, rotation: simd_quatf(vector: camera.rotationQuaternion), color: cameraColor)
                let controlPoints = Self.splineControlPoints(for: camera).map { ModelViewerRenderer.mirroredWorldPosition(SIMD3($0.vector.x, $0.vector.y, $0.vector.z)) }
                // "Interactive Spline & Camera Path Visualizer" (roadmap
                // 6.3): a small marker box at every real control point,
                // not just the connecting polyline, this is what actually
                // makes each point visually distinguishable and clickable
                // (`pickObject` targets `objects`, which now has one entry
                // per control point too, added alongside this in `upload`).
                for point in controlPoints {
                    appendBox(position: point, size: SIMD3(repeating: 0.3), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), color: splineColor)
                }
                guard controlPoints.count >= 2 else { continue }
                for i in 0..<(controlPoints.count - 1) {
                    appendVertex(controlPoints[i], splineColor)
                    appendVertex(controlPoints[i + 1], splineColor)
                }
            }
        }

        // "AI Pathfinding/Navmesh Editor" (roadmap 5.1): a small fixed-size
        // wireframe box per real `AIPosition` waypoint, `AIPosition` has
        // no size/rotation of its own (just a point + the `Num`/node-type
        // field), so unlike trigger/camera boxes this one's a fixed visual
        // marker, not decoded extent.
        let aiWaypointColor = SIMD3<Float>(0.4, 0.9, 0.65)
        if layerVisibility.contains(.aiWaypoints) {
            for (_, marker) in aiPositions {
                let position = ModelViewerRenderer.mirroredWorldPosition(SIMD3(marker.position.x, marker.position.y, marker.position.z))
                appendBox(position: position, size: SIMD3(repeating: 0.35), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), color: aiWaypointColor)
            }
        }

        // "Chunk-Based Architecture" (Part 2): the real "load wall" quad
        // from each `ChunkLink` that has one, an outline here (for
        // visibility from any angle, including edge-on) plus a filled
        // translucent quad below (`chunkWallTriangleBuffer`) for the
        // "translucent plane" the mandate asks for.
        //
        // A real, user-reported bug lived here: this used to be gold/tan
        // (0.95, 0.75, 0.2), close enough to sandy/rock terrain tones that
        // a load wall (a genuinely flat quad standing vertically *by
        // design*, it marks a streaming boundary, not terrain) read as
        // broken scenery rather than an editor overlay, especially with
        // this layer visible by default (see `layerVisibility`'s own doc
        // comment). Every other overlay marker in this renderer
        // (triggers, cameras, AI waypoints, spline points) already uses a
        // saturated, distinctly non-terrain hue for exactly this reason , 
        // this one didn't, and it was the one that looked like a bug.
        let wallColor = SIMD3<Float>(0.95, 0.15, 0.85)
        var wallFloats: [Float] = []
        func appendWallVertex(_ position: SIMD3<Float>, _ color: SIMD3<Float>) {
            wallFloats.append(contentsOf: [position.x, position.y, position.z, color.x, color.y, color.z])
        }
        if layerVisibility.contains(.chunkBoundaries) {
            for (_, link) in chunkLinks {
                guard let wall = link.loadWall, wall.count == 4 else { continue }
                let corners = wall.map { ModelViewerRenderer.mirroredWorldPosition(SIMD3($0.x, $0.y, $0.z)) }
                appendVertex(corners[0], wallColor); appendVertex(corners[1], wallColor)
                appendVertex(corners[1], wallColor); appendVertex(corners[2], wallColor)
                appendVertex(corners[2], wallColor); appendVertex(corners[3], wallColor)
                appendVertex(corners[3], wallColor); appendVertex(corners[0], wallColor)
                // Two triangles (0,1,2) and (0,2,3) covering the quad , 
                // corner winding/order is exactly as decoded, unconfirmed
                // against a real renderer, so both faces draw (see the
                // `.none` cull mode set around this buffer's draw call).
                appendWallVertex(corners[0], wallColor); appendWallVertex(corners[1], wallColor); appendWallVertex(corners[2], wallColor)
                appendWallVertex(corners[0], wallColor); appendWallVertex(corners[2], wallColor); appendWallVertex(corners[3], wallColor)
            }
        }

        if wallFloats.isEmpty {
            chunkWallTriangleBuffer = nil
            chunkWallTriangleVertexCount = 0
        } else {
            chunkWallTriangleVertexCount = wallFloats.count / 6
            chunkWallTriangleBuffer = device.makeBuffer(bytes: wallFloats, length: wallFloats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
        }

        // "Collision Volume Overlay": `collisionVolumeWorldPositions` is
        // already a flat list of world-space line-segment endpoint pairs
        // (`updateCollisionVolumeOverlay`/`ModelViewerRenderer.
        // collisionBoxEdges` build it that way), so each pair appends
        // straight in without another `appendBox` decomposition.
        let collisionVolumeColor = SIMD3<Float>(1.0, 0.6, 0.1)
        for (start, end) in collisionVolumeWorldPositions {
            appendVertex(start, collisionVolumeColor)
            appendVertex(end, collisionVolumeColor)
        }

        // "Crate Detonation Chains", see `showCrateChains`'s own doc
        // comment. Reads `childInstanceIDs` straight off each object's real
        // `PlacedInstance` payload (via `sourceNode`, the same field
        // `InstanceInspectorView` already edits) rather than a separate
        // stored copy, so the overlay can never drift out of sync with
        // what would actually be saved. Only real *placed* Instances
        // participate as a source (`sourceNode` is nil for a
        // session-placed-but-unsaved object, which has no chain data of
        // its own yet) or as a target (matched by the target's real,
        // on-disk `Instance.id`, a session-placed object has no such ID
        // to be linked to until it's saved).
        if showCrateChains {
            var instancePositionByID: [UInt32: SIMD3<Float>] = [:]
            var chainSources: [(worldPosition: SIMD3<Float>, childInstanceIDs: [UInt16])] = []
            for object in objects where object.layer == .actors {
                guard let sourceNode = object.sourceNode, case .instance(let placed)? = sourceNode.payload else { continue }
                instancePositionByID[placed.id] = object.worldPosition
                if !placed.childInstanceIDs.isEmpty {
                    chainSources.append((object.worldPosition, placed.childInstanceIDs))
                }
            }
            let chainColor = SIMD3<Float>(1.0, 0.3, 0.05)
            for source in chainSources {
                for childID in source.childInstanceIDs {
                    guard let targetPosition = instancePositionByID[UInt32(childID)] else { continue }
                    appendVertex(source.worldPosition, chainColor)
                    appendVertex(targetPosition, chainColor)
                }
            }
        }

        guard !floats.isEmpty else {
            overlayLineBuffer = nil
            overlayLineVertexCount = 0
            return
        }
        overlayLineVertexCount = floats.count / 6
        overlayLineBuffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    /// A small procedural cube (0.8 world units per side) plus a solid
    /// amber texture, standing in for an `Instance` record's real geometry
    /// (see `LevelViewerContext.instanceMarkers`'s doc comment for why: no
    /// verified `objectID` -> mesh mapping exists in this build). Built as
    /// 12 independent triangles, not a shared-vertex indexed cube, the
    /// `MeshSubmesh.connectivity`/`triangleIndices()` triangle-strip scheme
    /// this pipeline's mesh format uses reads a sliding window of 3
    /// consecutive vertices per candidate triangle, so restarting the strip
    /// after every triangle (`connectivity = [false, false, true]` per
    /// triple) is what turns it into 12 disconnected triangles instead of a
    /// connected strip. `addTriangle`'s odd/even vertex swap exists purely
    /// to counteract `triangleIndices()`'s own alternating-winding rule for
    /// strips (`ModelViewerRenderer.swift`'s `MeshSubmesh.triangleIndices`
    /// doc comment), without it, every other face here would be wound
    /// backwards and get backface-culled.
    private static func makeMarkerCubeAsset() -> (mesh: MeshAsset, material: ResolvedSubmeshMaterial) {
        let half: Float = 0.4
        var vertices: [StaticVertex] = []
        var connectivity: [Bool] = []

        func addTriangle(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, normal: SIMD3<Float>) {
            let i = vertices.count
            let odd = (i & 1) == 1
            let ordered: [SIMD3<Float>] = odd ? [p1, p0, p2] : [p0, p1, p2]
            for p in ordered {
                vertices.append(StaticVertex(position: p, normal: normal, uv: SIMD2(0.5, 0.5)))
            }
            connectivity.append(false)
            connectivity.append(false)
            connectivity.append(true)
        }

        let c: [SIMD3<Float>] = [
            SIMD3(-half, -half, -half), SIMD3(half, -half, -half), SIMD3(half, half, -half), SIMD3(-half, half, -half),
            SIMD3(-half, -half, half), SIMD3(half, -half, half), SIMD3(half, half, half), SIMD3(-half, half, half)
        ]
        let faces: [(a: Int, b: Int, c: Int, d: Int, normal: SIMD3<Float>)] = [
            (0, 1, 2, 3, SIMD3(0, 0, -1)),
            (5, 4, 7, 6, SIMD3(0, 0, 1)),
            (4, 0, 3, 7, SIMD3(-1, 0, 0)),
            (1, 5, 6, 2, SIMD3(1, 0, 0)),
            (3, 2, 6, 7, SIMD3(0, 1, 0)),
            (4, 5, 1, 0, SIMD3(0, -1, 0))
        ]
        for face in faces {
            addTriangle(c[face.a], c[face.b], c[face.c], normal: face.normal)
            addTriangle(c[face.a], c[face.c], c[face.d], normal: face.normal)
        }

        let submesh = MeshSubmesh(vertices: vertices, connectivity: connectivity)
        let mesh = MeshAsset(id: 0, isSkinned: false, submeshes: [submesh])
        let texture = TextureAsset(id: 0, width: 1, height: 1, pixelFormat: .rawRGBA, rgba: [255, 149, 0, 255])
        return (mesh, ResolvedSubmeshMaterial(texture: texture))
    }

    /// "Save Level Overrides": the current position/rotation of every
    /// Instance marker, re-encoded and paired with the `ChunkNode` it
    /// patches into, ready to hand straight to `WorkspaceViewModel.
    /// patchedFileBytes(applyingPrefixPatches:)`. Includes every marker,
    /// not just ones that moved: writing an unchanged transform back is a
    /// harmless no-op patch, and skipping "unchanged" ones would need exact
    /// float-equality tracking against the original decode for no real
    /// benefit.
    var pendingLevelOverrides: [(node: ChunkNode, encoded: Data)] {
        objects.compactMap { object in
            // `.actors` only: triggers/cameras also carry a `sourceNode`
            // (for click-to-inspect), but `writeInstanceTransform` encodes
            // an `Instance` record's byte layout specifically, applying it
            // to a Trigger/Camera node would silently corrupt that record.
            guard object.layer == .actors, let node = object.sourceNode else { return nil }
            let degrees = Self.eulerDegrees(from: object.rotation)
            let rotationRaw = SIMD3(
                PlacedInstance.rawAngle(fromDegrees: degrees.x),
                PlacedInstance.rawAngle(fromDegrees: degrees.y),
                PlacedInstance.rawAngle(fromDegrees: degrees.z)
            )
            // "Coordinate-System Overhaul": `object.worldPosition` is the
            // mirrored *display* position (see `mirroredWorldPosition`'s
            // doc comment), un-mirror (self-inverse) back to raw before
            // encoding, or a dragged Instance would save at the wrong X.
            let rawPosition = ModelViewerRenderer.mirroredWorldPosition(object.worldPosition)
            let position = SIMD4(rawPosition.x, rawPosition.y, rawPosition.z, object.originalPositionW)
            let encoded = WorldPlacementWriter.writeInstanceTransform(position: position, rotationRaw: rotationRaw, comRotationRaw: object.comRotationRaw)
            return (node, encoded)
        }
    }

    var hasGeometry: Bool { !objects.isEmpty }
    var objectCount: Int { objects.count }
    /// Exposed for Level Viewer collision visualization
    var levelObjects: [GPULevelObject] { objects }
    /// Whether a real collision floor was built from `collisionMeshes` at
    /// construction time, see `collisionFillBuffer`'s own doc comment.
    /// Exposed for testing without making the buffer itself public.
    var hasCollisionFill: Bool { collisionFillBuffer != nil && collisionFillVertexCount > 0 }
    var collisionFillTriangleCount: Int { collisionFillVertexCount / 3 }

    /// Backs the Level Viewer sidebar's object list and the coordinate
    /// nudge fields, index-paired with the internal `objects` array so
    /// `select(index:)`/`setSelectedPosition(to:)`/`setPositions(_:)` can
    /// address the same entries directly. `layer` lets the sidebar (e.g.
    /// the Align/Distribute selection) tell an Instance apart from a
    /// Trigger/Camera/waypoint without reaching into `objects` itself.
    ///
    /// Performance fix ("Chunk Viewer extremely laggy," still reported
    /// after `objectList`'s own `LazyVStack` fix): that fix only stopped
    /// SwiftUI from eagerly *laying out* every row, this `.enumerated()
    /// .map` itself, an O(objects.count) allocation of a fresh tuple array,
    /// still ran on every single access. `LevelViewerWindow.body` sits on
    /// one monolithic view with ~50 `@State` properties (see that type's
    /// own doc comments), so *any* of them changing, typing in the
    /// unrelated search field, moving the marking-menu cursor, toggling a
    /// completely different panel, re-evaluates `objectList`, which reads
    /// this every time. For a real hub-scale level (hundreds to low
    /// thousands of placements) that's real, repeated, wasted allocation
    /// on every keystroke and mouse move, not just when the object list
    /// itself actually changes. Cached here instead, invalidated by
    /// `objects`'s own `didSet`, the fix belongs at the actual data
    /// source, not by trying to memoize inside the SwiftUI layer above it.
    var objectSummaries: [(index: Int, displayName: String, worldPosition: SIMD3<Float>, layer: SceneLayer)] {
        if let objectSummariesCache { return objectSummariesCache }
        let result = objects.enumerated().map { ($0.offset, $0.element.displayName, $0.element.worldPosition, $0.element.layer) }
        objectSummariesCache = result
        return result
    }

    var selectedPosition: SIMD3<Float>? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        return objects[selectedObjectIndex].worldPosition
    }

    /// Euler-angle degrees, decomposed from the object's quaternion in
    /// XYZ order, quaternions are what actually drive the model matrix
    /// (composable, no gimbal-lock surprises mid-drag), but Euler degrees
    /// are what a nudge-field UI should show; nobody edits a rotation by
    /// typing quaternion components directly.
    var selectedRotationDegrees: SIMD3<Float>? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        return Self.eulerDegrees(from: objects[selectedObjectIndex].rotation)
    }

    var selectedScale: SIMD3<Float>? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        return objects[selectedObjectIndex].scale
    }

    /// "Level Editor Overhaul": the `ChunkNode` behind whatever's currently
    /// selected, `nil` for scenery placements and Models-Hub-dropped
    /// props (neither has one), non-`nil` for Instance/Trigger/Camera
    /// markers. Lets the SwiftUI side route to the right real inspector
    /// (`node.payload` already carries which kind it is) without this
    /// renderer needing to know anything about SwiftUI views.
    var selectedSourceNode: ChunkNode? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        return objects[selectedObjectIndex].sourceNode
    }

    func select(index: Int?) {
        selectedObjectIndex = index.flatMap { objects.indices.contains($0) ? $0 : nil }
        rebuildGizmoBuffer()
        rebuildSelectionBuffer()
        // Selecting the object currently under the cursor already gets a
        // gizmo and a selection outline, the separate (white) hover
        // outline would be visual redundancy on top of those.
        if hoveredObjectIndex == selectedObjectIndex { rebuildHoverBuffer() }
    }

    /// "Level Events" panel: selects whichever object was built from
    /// `node` (identity, not value, comparison, `ChunkNode` is a
    /// reference type) so clicking an event row both highlights it in the
    /// sidebar and (via `orbitTarget` already following the selection)
    /// snaps the camera to it. Returns whether a match was found, `node`
    /// could in principle belong to a layer that's currently hidden and
    /// therefore still present in `objects` but intentionally not
    /// selectable via viewport picking; selecting it programmatically from
    /// the events list is fine either way.
    @discardableResult
    func selectByNode(_ node: ChunkNode) -> Bool {
        guard let index = objects.firstIndex(where: { $0.sourceNode === node }) else { return false }
        select(index: index)
        return true
    }

    /// Direct position edit, the sidebar's X/Y/Z nudge fields go through
    /// this, same as a gizmo drag does at the end of `dragSelectedObject`.
    func setSelectedPosition(to newPosition: SIMD3<Float>) {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return }
        objects[selectedObjectIndex].worldPosition = newPosition
        rebuildGizmoBuffer()
        rebuildSelectionBuffer()
    }

    /// "Align & Distribute" (`SpatialAlignmentTool`'s real write-back path):
    /// sets several objects' `worldPosition` in one pass, unlike
    /// `setSelectedPosition` which only ever touches `selectedObjectIndex`.
    /// Rebuilds the shared GPU buffers once for the whole batch rather than
    /// once per object. Silently skips any index outside `objects.indices`
    /// (defensive only, callers build `updates` from this renderer's own
    /// live `objectSummaries`, so a stale index shouldn't occur in
    /// practice).
    func setPositions(_ updates: [(index: Int, position: SIMD3<Float>)]) {
        for update in updates where objects.indices.contains(update.index) {
            objects[update.index].worldPosition = update.position
        }
        rebuildGizmoBuffer()
        rebuildSelectionBuffer()
    }

    /// A full position/rotation/scale snapshot for one object, the batch-
    /// script counterpart to `selectedPosition`/`selectedRotationDegrees`/
    /// `selectedScale`, but for any index rather than only the current
    /// selection (`applyBatchScript`/`setTransforms` need to read and
    /// restore several objects' transforms at once).
    struct ObjectTransform: Equatable {
        var position: SIMD3<Float>
        var rotationDegrees: SIMD3<Float>
        var scale: SIMD3<Float>
    }

    func transform(at index: Int) -> ObjectTransform? {
        guard objects.indices.contains(index) else { return nil }
        let object = objects[index]
        return ObjectTransform(position: object.worldPosition, rotationDegrees: Self.eulerDegrees(from: object.rotation), scale: object.scale)
    }

    /// The batch-script counterpart to `setPositions`, restoring a full
    /// transform (not just position) per index, what `applyBatchScript`'s
    /// undo/redo actually replays.
    func setTransforms(_ updates: [(index: Int, transform: ObjectTransform)]) {
        for update in updates where objects.indices.contains(update.index) {
            objects[update.index].worldPosition = update.transform.position
            objects[update.index].rotation = Self.quaternion(fromEulerDegrees: update.transform.rotationDegrees)
            let clamped = SIMD3(max(update.transform.scale.x, 0.01), max(update.transform.scale.y, 0.01), max(update.transform.scale.z, 0.01))
            objects[update.index].scale = clamped
        }
        rebuildGizmoBuffer()
        rebuildSelectionBuffer()
    }

    /// "Batch Editing, Scripting", real, requested extension of the
    /// earlier "Select All Matching" / "Batch Delete" batch-editing pair:
    /// a short, ordered sequence of transform operations applied to every
    /// object in `indices` in one pass, instead of hand-editing each
    /// object's fields one at a time. Deliberately a small, fixed set of
    /// operation kinds (translate/rotate-around-Y/uniform-scale) rather
    /// than an arbitrary programming language, that would be a much
    /// larger, separately-scoped undertaking for a level editor whose
    /// actual batch-editing needs are "nudge/rotate/resize a group of
    /// props together," not general scripting. Returns the real
    /// before/after transform for every touched object so the caller can
    /// register one combined undo step for the whole script run, same
    /// shape as `registerAlignmentUndo`.
    enum BatchScriptOperation: Equatable {
        case translate(SIMD3<Float>)
        case rotateY(degrees: Float)
        case scaleUniform(factor: Float)
    }

    @discardableResult
    func applyBatchScript(_ operations: [BatchScriptOperation], to indices: Set<Int>) -> [(index: Int, before: ObjectTransform, after: ObjectTransform)] {
        var results: [(index: Int, before: ObjectTransform, after: ObjectTransform)] = []
        for index in indices.sorted() where objects.indices.contains(index) {
            guard let before = transform(at: index) else { continue }
            var current = before
            for operation in operations {
                switch operation {
                case .translate(let delta):
                    current.position += delta
                case .rotateY(let degrees):
                    current.rotationDegrees.y += degrees
                case .scaleUniform(let factor):
                    let clampedFactor = max(factor, 0.01)
                    current.scale *= clampedFactor
                }
            }
            results.append((index, before, current))
        }
        setTransforms(results.map { ($0.index, $0.after) })
        return results
    }

    /// "Keyboard nudging" (QoL): moves the selection one step along a
    /// world-space axis, see `GizmoInteractiveRenderer.
    /// nudgeSelectedPosition`'s own doc comment. Step size matches
    /// whatever a gizmo drag would snap to (`gridSize` with snap on),
    /// falling back to a small fixed step with snap off, so nudging feels
    /// consistent with dragging rather than like a separate, finer-grained
    /// tool.
    func nudgeSelectedPosition(worldDirection: SIMD3<Float>) {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return }
        let step = snapToGrid ? gridSize : 0.25
        objects[selectedObjectIndex].worldPosition += worldDirection * step
        rebuildGizmoBuffer()
        rebuildSelectionBuffer()
    }

    /// Units/second for "Hold to Move", chosen to roughly match a
    /// snap-to-grid nudge's own default `gridSize` in about a second of
    /// holding, so switching between the two modes doesn't feel like a
    /// wildly different scale of motion.
    private static let continuousMoveSpeed: Float = 4

    func nudgeSelectedPositionContinuous(worldDirection: SIMD3<Float>, deltaSeconds: TimeInterval) {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return }
        objects[selectedObjectIndex].worldPosition += worldDirection * Self.continuousMoveSpeed * Float(deltaSeconds)
        rebuildGizmoBuffer()
        rebuildSelectionBuffer()
    }

    func setSelectedRotation(eulerDegrees: SIMD3<Float>) {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return }
        objects[selectedObjectIndex].rotation = Self.quaternion(fromEulerDegrees: eulerDegrees)
        rebuildGizmoBuffer()
        rebuildSelectionBuffer()
    }

    func setSelectedScale(to newScale: SIMD3<Float>) {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return }
        // A zero or negative scale collapses/flips the mesh in a way
        // that's indistinguishable from "the model disappeared", the
        // exact class of bug the earlier blank-viewport investigation
        // spent a long time chasing, so this is guarded explicitly rather
        // than trusting every caller (nudge-field typos included) to
        // avoid it.
        let clamped = SIMD3(max(newScale.x, 0.01), max(newScale.y, 0.01), max(newScale.z, 0.01))
        objects[selectedObjectIndex].scale = clamped
        rebuildGizmoBuffer()
        rebuildSelectionBuffer()
    }

    private static func eulerDegrees(from quaternion: simd_quatf) -> SIMD3<Float> {
        let m = simd_float3x3(quaternion)
        let sy = sqrt(m.columns.0.x * m.columns.0.x + m.columns.0.y * m.columns.0.y)
        let singular = sy < 1e-6
        let x: Float, y: Float, z: Float
        if !singular {
            x = atan2(m.columns.1.z, m.columns.2.z)
            y = atan2(-m.columns.0.z, sy)
            z = atan2(m.columns.0.y, m.columns.0.x)
        } else {
            x = atan2(-m.columns.2.y, m.columns.1.y)
            y = atan2(-m.columns.0.z, sy)
            z = 0
        }
        let toDegrees: Float = 180 / .pi
        return SIMD3(x * toDegrees, y * toDegrees, z * toDegrees)
    }

    /// The radius of the smallest sphere centered on the object's own local
    /// origin that contains every vertex, rotation-invariant (distance
    /// from origin doesn't change under rotation), so this is computed once
    /// at upload time and reused as-is at every orientation. "Seamless
    /// Full-Map Rendering" (Part 1): feeds the frustum cull's per-object
    /// sphere test.
    private static func boundingRadius(of mesh: MeshAsset) -> Float {
        var maxDistanceSquared: Float = 0
        for submesh in mesh.submeshes {
            for vertex in submesh.vertices {
                maxDistanceSquared = max(maxDistanceSquared, simd_length_squared(vertex.position))
            }
        }
        return max(sqrt(maxDistanceSquared), 0.01)
    }

    /// "Magnet Snap, Stacking": a real, per-axis local-space AABB, same
    /// vertex source as `boundingRadius(of:)` above but keeping min/max on
    /// each axis instead of collapsing to one scalar distance, see
    /// `GPULevelObject.localBoundsMin`/`.localBoundsMax`'s own doc comment
    /// for why the sphere alone can't drive a face-to-face snap.
    /// "Placed/Moved Scenery Disappears at Certain Camera Angles, In the
    /// Real Game, Not Just This Editor": real, reported bug, confirmed in
    /// an actual PCSX2 boot (so a fix purely in this app's own preview
    /// renderer, see `Frustum`'s depth-bias companion fix, can't reach
    /// it; the real PS2 GPU has no equivalent "render this slightly closer
    /// to camera without moving it" trick). A freshly-placed object
    /// commonly lands sitting exactly (or almost exactly) coplanar with
    /// the level's own ground, and two coplanar surfaces are the classic
    /// cause of angle-dependent depth-test flicker on real hardware, same
    /// underlying phenomenon as the editor-only version of this bug , 
    /// original, disc-authored placements apparently already carry a real
    /// gap from the ground that avoids it. A small, constant upward
    /// clearance applied only at the moment a *brand-new* placement lands
    /// (never to an object's on-disk, disc-authored position, and never
    /// retroactively to anything already placed) is a real, disclosed
    /// best-effort height, not a value independently confirmed against
    /// real disc data the way most of this project's constants are , 
    /// small enough that it shouldn't be visible as "floating," large
    /// enough to clear the coincidental-overlap range this bug needs.
    static let placementGroundClearance: Float = 0.15

    static func localBounds(of mesh: MeshAsset) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for submesh in mesh.submeshes {
            for vertex in submesh.vertices {
                minP = simd_min(minP, vertex.position)
                maxP = simd_max(maxP, vertex.position)
            }
        }
        guard minP.x <= maxP.x else { return (SIMD3(-0.5, -0.5, -0.5), SIMD3(0.5, 0.5, 0.5)) }
        return (minP, maxP)
    }

    private static func quaternion(fromEulerDegrees degrees: SIMD3<Float>) -> simd_quatf {
        let toRadians: Float = .pi / 180
        let r = degrees * toRadians
        let qx = simd_quatf(angle: r.x, axis: SIMD3(1, 0, 0))
        let qy = simd_quatf(angle: r.y, axis: SIMD3(0, 1, 0))
        let qz = simd_quatf(angle: r.z, axis: SIMD3(0, 0, 1))
        return qz * qy * qx
    }

    /// "Drag-and-Drop Asset Palette" (blueprint 6.2): appends a new
    /// in-session placement at `boundsCenter` (the level's own visual
    /// center, as good a default drop point as any without a real 3D
    /// cursor/raycast-to-ground target) and selects it immediately so its
    /// gizmo is ready to drag into place. Deliberately does **not**
    /// recompute `boundsCenter`/`boundsRadius`/the camera framing, that
    /// would jump the camera every time an object is added, which reads as
    /// the viewport "jumping" rather than as a natural drop.
    @discardableResult
    func addObject(asset: ResolvedModelAsset) -> Int? {
        let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: asset.mesh, submeshMaterials: asset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture)
        guard !built.submeshes.isEmpty else { return nil }
        let localBounds = Self.localBounds(of: asset.mesh)
        let snappedPosition = magnetSnappedPlacementPosition(boundsCenter, localBoundsMin: localBounds.min, localBoundsMax: localBounds.max, scale: SIMD3(1, 1, 1))
        objects.append(GPULevelObject(worldPosition: snappedPosition, displayName: asset.displayName, submeshes: built.submeshes, layer: .actors, boundingRadius: Self.boundingRadius(of: asset.mesh), localBoundsMin: localBounds.min, localBoundsMax: localBounds.max))
        let newIndex = objects.count - 1
        select(index: newIndex)
        return newIndex
    }

    /// "Chunk-Based Architecture" (Part 2): appends a neighboring chunk's
    /// already-resolved scenery placements, offset by `worldOffset` (the
    /// requesting `ChunkLink.chunkMatrix`'s translation row; only that
    /// link's own translation is applied, each placement's own rotation/
    /// scale still comes from its own decoded transform), into this same
    /// viewport as a distinct, independently toggleable `.linkedChunks`
    /// layer. Same "don't recenter the camera" convention as `addObject`:
    /// loading a neighbor in for context shouldn't yank the view away from
    /// what the user was already looking at.
    /// Appends objects a caller already built off-main via
    /// `buildingStitchedChunkObjects`/`buildingStitchedChunkActorObjects` , 
    /// the one piece of this whole stitch operation that still has to run
    /// on whatever thread owns `objects` (the main actor, in practice: it
    /// has no synchronization of its own and `draw(in:)` reads it
    /// concurrently on the render loop). Cheap, no GPU work, just an
    /// array append, so keeping it main-actor-only costs nothing.
    func appendingStitchedObjects(_ built: [GPULevelObject]) {
        objects.append(contentsOf: built)
    }

    func stitchChunk(placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)], worldOffset: SIMD3<Float>) -> Int {
        let (built, failedBuildCount) = Self.buildingStitchedChunkObjects(placements: placements, worldOffset: worldOffset, device: device, fallbackTexture: context.fallbackTexture)
        objects.append(contentsOf: built)
        // "Chunk Stitching Rendering Bug": pairs with the diagnostic in
        // `WorkspaceViewModel.loadChunkLinkPlacements`, that one flags
        // placements dropped before reaching here (bad transform/unresolved
        // modelID); this one flags placements that *did* resolve to a real
        // mesh but produced zero GPU submeshes once built (e.g. every
        // submesh's material/texture failed to bind). Distinguishing the
        // two matters: the first points at `AssetResolver`, the second at
        // `buildGPUSubmeshes`.
        if failedBuildCount > 0 {
            AppLog.rendering.debug("stitchChunk, \(failedBuildCount) of \(placements.count) resolved placements built zero GPU submeshes, dropped before rendering")
        }
        return built.count
    }

    /// Real, reported performance bug (code review): this used to run
    /// entirely inline inside `stitchChunk`, on whatever thread called
    /// it, for real "Load & Stitch" usage that's the main actor
    /// (`LevelViewerWindow.loadAndStitch`'s `Task { }`), so stitching a
    /// neighbor chunk with hundreds of placements reproduced the exact
    /// main-actor-blocking freeze the `.task`/`Task.detached` fix for
    /// *initial* level open eliminated, just triggered by a different
    /// action. Split out as a pure `static` function (no `self`, doesn't
    /// touch `objects` at all) specifically so a caller can run the
    /// expensive `buildGPUSubmeshes` work off-main via `Task.detached` and
    /// only append the *already-built* results back on whatever thread
    /// owns `objects` (today: always the main actor, `objects` has no
    /// synchronization of its own, so appending to it must stay serialized
    /// with `draw(in:)`'s concurrent reads, unlike the pure GPU-object
    /// construction here, which touches no renderer state).
    static func buildingStitchedChunkObjects(
        placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset, matrixFileOffset: Int?)],
        worldOffset: SIMD3<Float>,
        device: MTLDevice,
        fallbackTexture: MTLTexture
    ) -> (objects: [GPULevelObject], failedBuildCount: Int) {
        var built: [GPULevelObject] = []
        built.reserveCapacity(placements.count)
        var failedBuildCount = 0
        // Same autoreleasepool fix as `upload(placements:...)`'s own loops
        //, this also runs inside `Task.detached` (see `LevelViewerWindow.
        // loadAndStitch`), same single-continuous-closure-body concern.
        for (worldPosition, rotation, scale, asset, _) in placements {
            autoreleasepool {
            let submeshes = ModelViewerRenderer.buildGPUSubmeshes(mesh: asset.mesh, submeshMaterials: asset.submeshMaterials, device: device, fallbackTexture: fallbackTexture)
            guard !submeshes.submeshes.isEmpty else { failedBuildCount += 1; return }
            built.append(GPULevelObject(
                worldPosition: worldPosition + worldOffset,
                rotation: rotation,
                scale: scale,
                displayName: asset.displayName,
                submeshes: submeshes.submeshes,
                layer: .linkedChunks,
                boundingRadius: Self.boundingRadius(of: asset.mesh)
            ))
            }
        }
        return (built, failedBuildCount)
    }

    /// "Chunk Stitching Rendering Bug": the actual missing feature behind
    /// the report -- see `WorkspaceViewModel.loadChunkLinkActors`'s doc
    /// comment. Uploads a stitched neighbor's real Instance/Trigger/
    /// Camera/AIPosition records the same way `upload(...)` does for the
    /// primary chunk's own, offset by the same `worldOffset` `stitchChunk`
    /// already applies to scenery. Every object here is read-only
    /// (`sourceNode` stays `nil` on `GPULevelObject`, its default) --
    /// these nodes come from a standalone-parsed tree with no tracked
    /// write-back path, unlike the primary chunk's own markers.
    func stitchChunkActors(
        instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)],
        resolvedInstanceAssets: [UUID: ResolvedModelAsset],
        triggers: [(node: ChunkNode, trigger: TriggerVolume)],
        cameras: [(node: ChunkNode, camera: PlacedCamera)],
        aiPositions: [(node: ChunkNode, marker: AIPositionMarker)],
        worldOffset: SIMD3<Float>
    ) -> Int {
        let built = Self.buildingStitchedChunkActorObjects(
            instanceMarkers: instanceMarkers, resolvedInstanceAssets: resolvedInstanceAssets,
            triggers: triggers, cameras: cameras, aiPositions: aiPositions,
            worldOffset: worldOffset, device: device, fallbackTexture: context.fallbackTexture
        )
        objects.append(contentsOf: built)
        return built.count
    }

    /// Same off-main-safe split as `buildingStitchedChunkObjects` above,
    /// same reason, see that function's own doc comment.
    static func buildingStitchedChunkActorObjects(
        instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)],
        resolvedInstanceAssets: [UUID: ResolvedModelAsset],
        triggers: [(node: ChunkNode, trigger: TriggerVolume)],
        cameras: [(node: ChunkNode, camera: PlacedCamera)],
        aiPositions: [(node: ChunkNode, marker: AIPositionMarker)],
        worldOffset: SIMD3<Float>,
        device: MTLDevice,
        fallbackTexture: MTLTexture
    ) -> [GPULevelObject] {
        var built: [GPULevelObject] = []
        built.reserveCapacity(instanceMarkers.count + triggers.count + cameras.count + aiPositions.count)
        let markerMesh = Self.makeMarkerCubeAsset()
        let markerBuilt = ModelViewerRenderer.buildGPUSubmeshes(mesh: markerMesh.mesh, submeshMaterials: [markerMesh.material], device: device, fallbackTexture: fallbackTexture)
        let markerRadius = Self.boundingRadius(of: markerMesh.mesh)

        for (node, instance) in instanceMarkers {
            autoreleasepool {
            let worldPosition = ModelViewerRenderer.mirroredWorldPosition(SIMD3(instance.position.x, instance.position.y, instance.position.z)) + worldOffset
            var submeshes = markerBuilt.submeshes
            var boundingRadius = markerRadius
            if let resolvedAsset = resolvedInstanceAssets[node.id] {
                let resolvedBuilt = ModelViewerRenderer.buildGPUSubmeshes(mesh: resolvedAsset.mesh, submeshMaterials: resolvedAsset.submeshMaterials, device: device, fallbackTexture: fallbackTexture)
                if !resolvedBuilt.submeshes.isEmpty {
                    submeshes = resolvedBuilt.submeshes
                    boundingRadius = Self.boundingRadius(of: resolvedAsset.mesh)
                }
            }
            guard !submeshes.isEmpty else { return }
            built.append(GPULevelObject(
                worldPosition: worldPosition,
                rotation: Self.quaternion(fromEulerDegrees: instance.rotationDegrees),
                displayName: "Instance #\(instance.id) (Object \(instance.objectID))",
                submeshes: submeshes,
                layer: .linkedChunks,
                boundingRadius: boundingRadius
            ))
            }
        }

        for (_, trigger) in triggers {
            let worldPosition = ModelViewerRenderer.mirroredWorldPosition(SIMD3(trigger.position.x, trigger.position.y, trigger.position.z)) + worldOffset
            built.append(GPULevelObject(
                worldPosition: worldPosition,
                rotation: simd_quatf(vector: trigger.rotationQuaternion),
                displayName: "Trigger #\(trigger.id)",
                submeshes: [],
                layer: .linkedChunks
            ))
        }

        for (_, camera) in cameras {
            let worldPosition = ModelViewerRenderer.mirroredWorldPosition(SIMD3(camera.position.x, camera.position.y, camera.position.z)) + worldOffset
            built.append(GPULevelObject(
                worldPosition: worldPosition,
                rotation: simd_quatf(vector: camera.rotationQuaternion),
                displayName: "Camera #\(camera.id) (\(camera.cameraType1.displayName))",
                submeshes: [],
                layer: .linkedChunks
            ))
        }

        for (_, marker) in aiPositions {
            let worldPosition = ModelViewerRenderer.mirroredWorldPosition(SIMD3(marker.position.x, marker.position.y, marker.position.z)) + worldOffset
            built.append(GPULevelObject(
                worldPosition: worldPosition,
                displayName: "AI Waypoint #\(marker.id) (\(marker.nodeType?.displayName ?? "type \(marker.rawNodeType)"))",
                submeshes: [],
                layer: .linkedChunks
            ))
        }

        return built
    }

    /// "No More Placeholder Squares for Cross-Engine Data": WoC's own
    /// `.CRT`/`.WMP` files only ever decode real crate/wumpa *positions*
    /// (see `WrathOfCortexEngineDriver`'s own doc comment), there's no
    /// decoded WoC model/mesh format in this codebase at all, and no
    /// verified reference source to build one from, so the *exact* WoC
    /// geometry genuinely can't be shown. What CAN be shown honestly: a
    /// real, fully-decoded Twinsanity crate/wumpa model (`BASICCRATE`/
    /// `REDWUMPA`, `DefaultObjectID`'s IDs 3/1) as a recognizable stand-in
    /// at the real WoC-decoded position, clearly not a claim that this is
    /// the exact WoC asset (the colored wireframe marker `stitchCrossEngineData`
    /// already draws around every cross-engine object stays layered on
    /// top for exactly that reason: it's the "this one's borrowed, not
    /// native" cue, unchanged by this fix). Resolved once and reused
    /// across every crate/wumpa this renderer ever stitches in, same
    /// "resolve once, reuse the GPU submeshes" shape `spawnInstance`'s own
    /// `markerMesh` uses. `nil` means "not attempted yet"; an empty array
    /// means "attempted and failed" (no Default.rm2/no Twinsanity data
    /// open at all), cached either way so a failed resolve isn't retried
    /// on every single stitched neighbor.
    private var cachedWoCCrateStandInSubmeshes: [GPUSubmesh]??
    private var cachedWoCWumpaStandInSubmeshes: [GPUSubmesh]??

    private func standInSubmeshes(forObjectID objectID: UInt16, cache: inout [GPUSubmesh]??) -> [GPUSubmesh] {
        if let cache { return cache ?? [] }
        guard let resolved = AssetResolver.resolveInstanceObject(objectID: objectID, instanceSelector: 0, index: assetIndex, defaultIndex: defaultAssetIndex),
              !resolved.mesh.submeshes.isEmpty
        else {
            cache = .some(nil)
            return []
        }
        let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: resolved.mesh, submeshMaterials: resolved.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture).submeshes
        cache = .some(built)
        return built
    }

    /// "Cross-Engine Chunk Stitcher" (roadmap 5.3): plots real *Wrath of
    /// Cortex* crate/wumpa positions, a genuinely different TT-engine
    /// game's data, real-bytes-verified (see `WOCCrateFile`'s doc
    /// comment), as small colored wireframe markers in this same
    /// viewport, `worldOffset` letting the caller place them next to (not
    /// on top of) the currently loaded Twinsanity chunk. No `sourceNode`
    /// (these don't come from an `.RM2`/`.SM2` tree at all), so they're
    /// visible/toggleable but not click-to-inspect.
    func stitchCrossEngineData(crates: [SIMD3<Float>], wumpas: [SIMD3<Float>], worldOffset: SIMD3<Float>) {
        // See `standInSubmeshes(forObjectID:cache:)`'s own doc comment , 
        // real Twinsanity crate/wumpa geometry stands in for WoC's own
        // still-undecoded models.
        let crateSubmeshes = standInSubmeshes(forObjectID: 3, cache: &cachedWoCCrateStandInSubmeshes)
        let wumpaSubmeshes = standInSubmeshes(forObjectID: 1, cache: &cachedWoCWumpaStandInSubmeshes)
        for position in crates {
            objects.append(GPULevelObject(worldPosition: position + worldOffset, displayName: "WoC Crate", submeshes: crateSubmeshes, layer: .crossEngine))
        }
        for position in wumpas {
            objects.append(GPULevelObject(worldPosition: position + worldOffset, displayName: "WoC Wumpa", submeshes: wumpaSubmeshes, layer: .crossEngine))
        }
        crossEngineMarkerPositions.append(contentsOf: crates.map { ($0 + worldOffset, Self.woCCrateColor) })
        crossEngineMarkerPositions.append(contentsOf: wumpas.map { ($0 + worldOffset, Self.woCWumpaColor) })
        rebuildCrossEngineBuffer()
    }

    private static let woCCrateColor = SIMD3<Float>(0.95, 0.45, 0.15)
    private static let woCWumpaColor = SIMD3<Float>(0.95, 0.85, 0.2)
    private var crossEngineMarkerPositions: [(SIMD3<Float>, SIMD3<Float>)] = []
    private var crossEngineLineBuffer: MTLBuffer?
    private var crossEngineLineVertexCount = 0

    private func rebuildCrossEngineBuffer() {
        var floats: [Float] = []
        func appendVertex(_ position: SIMD3<Float>, _ color: SIMD3<Float>) {
            floats.append(contentsOf: [position.x, position.y, position.z, color.x, color.y, color.z])
        }
        for (position, color) in crossEngineMarkerPositions {
            let half: Float = 0.25
            let corners: [SIMD3<Float>] = [
                position + SIMD3(-half, -half, -half), position + SIMD3(half, -half, -half),
                position + SIMD3(half, half, -half), position + SIMD3(-half, half, -half),
                position + SIMD3(-half, -half, half), position + SIMD3(half, -half, half),
                position + SIMD3(half, half, half), position + SIMD3(-half, half, half)
            ]
            let edges: [(Int, Int)] = [
                (0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)
            ]
            for (a, b) in edges { appendVertex(corners[a], color); appendVertex(corners[b], color) }
        }
        guard !floats.isEmpty else {
            crossEngineLineBuffer = nil
            crossEngineLineVertexCount = 0
            return
        }
        crossEngineLineVertexCount = floats.count / 6
        crossEngineLineBuffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    // MARK: - The Forge Palette: new-item placement (Part 4C)

    /// "I must be able to select an entity from this directory, click into
    /// the 3D map, and spawn a brand-new instance of that object", set
    /// non-nil to arm placement mode (the next viewport click places this
    /// object instead of orbiting/picking; see `InteractiveMTKView.
    /// mouseDown`), `nil` to cancel it without placing anything.
    var pendingPlacementObjectID: UInt16?

    /// Resolves `objectID` to real geometry through the same
    /// `AssetResolver.resolveInstanceObject` chain every existing
    /// `Instance` already goes through (falling back to the amber marker
    /// cube when it doesn't resolve, same "colored bounding-box proxy"
    /// rule as everywhere else), places it at `worldPosition`, and assigns
    /// it a synthetic `Instance` ID that doesn't collide with any real one
    /// already in this level (`nextSyntheticInstanceID`, seeded one past
    /// the highest real ID at load and incremented on every spawn, even
    /// across undo/redo, so a redone spawn never accidentally reuses an ID
    /// a *different* still-live placement claimed in between). Selects the
    /// new object immediately, same as `addObject`, so its gizmo is ready.
    /// Whether `objectID` would resolve to real geometry through the same
    /// chain `spawnInstance` uses (this level's own `assetIndex`, falling
    /// back to the shared `Default.rm2` `defaultAssetIndex`), checked
    /// without touching the GPU. The Forge Palette lists every object ID in
    /// the whole game (`DefaultObjectID.names` isn't scoped per-level,
    /// since no per-level roster is decoded anywhere in this build), so
    /// picking an ID this level's data genuinely has no geometry for is a
    /// legitimate, expected outcome, not a resolver bug, this lets the
    /// palette say so upfront instead of the user only finding out after
    /// already placing an amber placeholder cube.
    func canResolveObjectID(_ objectID: UInt16) -> Bool {
        if let resolved = AssetResolver.resolveInstanceObject(objectID: objectID, instanceSelector: 0, index: assetIndex, defaultIndex: defaultAssetIndex), !resolved.mesh.submeshes.isEmpty {
            return true
        }
        return globalObjectFallbacks[objectID] != nil
    }

    /// "Honest Forge Palette Preview", real, reported confusion: an object
    /// that only resolves through `globalObjectFallbacks` (`canResolveObjectID`
    /// returning `true` because *some other level's* real geometry was
    /// found for preview purposes, "Forge Palette anywhere") renders a
    /// completely real thumbnail and a completely real placed object in
    /// *this* editor session, with nothing distinguishing it from an object
    /// whose data actually lives in the file being saved. But that borrowed
    /// geometry is never copied into this level's own file, only this
    /// level's own `assetIndex`, or the always-shipped shared `Default.rm2`
    /// `defaultAssetIndex`, are real data this session's own save actually
    /// writes. An object that resolves *only* through the cross-level
    /// fallback looks identical to a real placement in this editor but has
    /// no real `GameObject` record for the actual game to spawn at all once
    /// booted, this distinguishes that case so the palette can say so
    /// before the user places it, not after it silently fails to appear.
    func canResolveNativelyObjectID(_ objectID: UInt16) -> Bool {
        guard let resolved = AssetResolver.resolveInstanceObject(objectID: objectID, instanceSelector: 0, index: assetIndex, defaultIndex: defaultAssetIndex) else { return false }
        return !resolved.mesh.submeshes.isEmpty
    }

    /// "Drag-and-Drop Asset Palette & Tray" (roadmap 6.2): the same real
    /// resolve `canResolveObjectID` already checks, but returning the
    /// actual `ResolvedModelAsset` instead of a `Bool`, this is what
    /// `ForgePaletteView` feeds to `ModelThumbnailRenderer` for a real
    /// offscreen 3D thumbnail per entry, not a fabricated preview.
    func resolvedAsset(forObjectID objectID: UInt16) -> ResolvedModelAsset? {
        if let resolved = AssetResolver.resolveInstanceObject(objectID: objectID, instanceSelector: 0, index: assetIndex, defaultIndex: defaultAssetIndex),
           !resolved.mesh.submeshes.isEmpty {
            return resolved
        }
        return globalObjectFallbacks[objectID]
    }

    /// "Spawn Interactive Cortex (Prop)": this level's own real, native
    /// `GameObject` record for `objectID`, `nil` when it only resolves via
    /// `Default.rm2`/a cross-level fallback (the base for a prop-skin clone
    /// must be a record `CrossFileGameObjectCopier.resolvingPropSkinInsertion`
    /// can find under this exact `objectID` in the destination file, since
    /// that's the "already native" check it makes first).
    func nativeGameObject(forObjectID objectID: UInt16) -> GameObjectInfo? {
        assetIndex.gameObjects[UInt32(objectID)]
    }

    /// "Spawn Interactive Cortex (Prop)": the lowest `objectID` this
    /// level's own file doesn't already use for a real `GameObject` , 
    /// same "scan every real existing ID, one past the max" discipline
    /// `CrossFileGameObjectCopier` already uses for OGI/Skin/Material/
    /// Texture IDs, applied here to the one namespace it never needs to
    /// touch itself (that function's callers always reuse a real,
    /// already-known `objectID`). Floored at `60000`, comfortably above
    /// every real ID this build has ever decoded from retail disc data , 
    /// so a fresh synthetic ID reads as obviously synthetic rather than
    /// landing in a range a future real patch might actually use.
    func freshSyntheticObjectID() -> UInt16 {
        let highestReal = assetIndex.gameObjects.keys.max() ?? 0
        return UInt16(max(60000, min(UInt32(UInt16.max), highestReal + 1)))
    }

    @discardableResult
    func spawnInstance(objectID: UInt16, at worldPosition: SIMD3<Float>, applyPlacementAlignment: Bool = true) -> Int? {
        let markerMesh = Self.makeMarkerCubeAsset()
        var submeshes = ModelViewerRenderer.buildGPUSubmeshes(mesh: markerMesh.mesh, submeshMaterials: [markerMesh.material], device: device, fallbackTexture: context.fallbackTexture).submeshes
        var radius = Self.boundingRadius(of: markerMesh.mesh)
        var localBounds = Self.localBounds(of: markerMesh.mesh)
        var displayName = "New Object #\(objectID)"
        var generatedCollisionData: [GraphicsInfoCollisionData] = []
        // Real, reported bug: this was a hard-coded `let ... = []`, never
        // actually populated from `resolved.skeleton?.collisionData` below
        //, so even a resolved asset with real, decoded asset-provided
        // collision (a skinned character with its own `GraphicsInfo`
        // collision hull) had it silently discarded, same underlying class
        // of bug as `spawnScenery`'s own fix just above (see its doc
        // comment): the real condition for generating a fallback is "no
        // asset-provided collision data exists," not "no skeleton exists."
        var assetCollisionData: [GraphicsInfoCollisionData] = []
        // "Cross-Level Forge Placement": records the real byte-level source
        // whenever resolution falls all the way through to
        // `globalObjectFallbacks`, the same condition, checked the same
        // way `canResolveNativelyObjectID` does, that means this
        // placement's geometry is only a borrowed preview until a save
        // actually copies the real data in. `nil` (the common case: this
        // level's own data or `Default.rm2` resolved it) needs no copy at
        // save time at all.
        var crossLevelGameObjectSource: CrossLevelGameObjectSource?
        // "Global Thumbnails": fall back to an object resolved elsewhere
        // in the workspace this session (`globalObjectFallbacks`) only
        // after this level's own data comes up empty, keeps this in
        // lockstep with `canResolveObjectID`/`resolvedAsset(forObjectID:)`
        // so a thumbnail that looked available actually places as real
        // geometry, not a silent downgrade to the amber placeholder.
        let nativelyResolved = AssetResolver.resolveInstanceObject(objectID: objectID, instanceSelector: 0, index: assetIndex, defaultIndex: defaultAssetIndex)
        if let resolved = nativelyResolved ?? globalObjectFallbacks[objectID] {
            let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: resolved.mesh, submeshMaterials: resolved.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture)
            if !built.submeshes.isEmpty {
                submeshes = built.submeshes
                radius = Self.boundingRadius(of: resolved.mesh)
                localBounds = Self.localBounds(of: resolved.mesh)
                displayName = resolved.displayName
                assetCollisionData = resolved.skeleton?.collisionData ?? []
                if assetCollisionData.isEmpty {
                    // See `spawnScenery`'s own doc comment on this exact fix
                    //, the fallible GPU-based `generateCollisionDataFromMesh`
                    // replaced by the reliable, CPU-only, mesh-hugging
                    // `collisionDataHuggingMesh`, for the identical real
                    // "no collision at all" bug on a fresh Forge Palette
                    // Instance placement.
                    generatedCollisionData = ModelViewerRenderer.collisionDataHuggingMesh(mesh: resolved.mesh)
                }
                if nativelyResolved == nil {
                    crossLevelGameObjectSource = globalObjectGameObjectSources[objectID]
                }
            }
        }
        guard !submeshes.isEmpty else { return nil }

        // "Align While Placing" only applies to a genuinely new placement
        // (Forge Palette/scenery-tab click, drag-and-drop), Duplicate,
        // Paste, and undo/redo replay all call this with an intentional,
        // already-decided position (a small visible offset from the
        // source so the copy doesn't render exactly on top of it, or the
        // exact position an undone action is being restored to) that must
        // land exactly where asked, not get silently pulled back onto a
        // nearby object.
        let snappedWorldPosition = applyPlacementAlignment
            ? magnetSnappedPlacementPosition(worldPosition, localBoundsMin: localBounds.min, localBoundsMax: localBounds.max, scale: SIMD3(1, 1, 1))
            : worldPosition
        let syntheticID = nextSyntheticInstanceID
        nextSyntheticInstanceID += 1
        objects.append(GPULevelObject(
            worldPosition: snappedWorldPosition,
            displayName: displayName,
            submeshes: submeshes,
            layer: .actors,
            boundingRadius: radius,
            localBoundsMin: localBounds.min,
            localBoundsMax: localBounds.max,
            newInstanceObjectID: objectID,
            syntheticInstanceID: syntheticID,
            generatedCollisionData: generatedCollisionData,
            assetCollisionData: assetCollisionData,
            pendingCrossLevelGameObjectSource: crossLevelGameObjectSource
        ))
        let newIndex = objects.count - 1
        select(index: newIndex)
        return newIndex
    }

    /// `LevelViewerWindow`'s placement-undo registration needs to snapshot
    /// what a just-placed object *was* (its `objectID` and where it ended
    /// up) without this renderer exposing its private `objects` array
    /// wholesale, this is that one narrow read.
    func newInstanceInfo(at index: Int) -> (objectID: UInt16, worldPosition: SIMD3<Float>)? {
        guard objects.indices.contains(index), let objectID = objects[index].newInstanceObjectID else { return nil }
        return (objectID, objects[index].worldPosition)
    }

    /// "Spawn Interactive Cortex (Prop)" undo/redo: `newInstanceInfo`'s
    /// `(objectID, worldPosition)` isn't enough to redo a prop-skin
    /// placement, `spawnInstance(objectID:)` resolves geometry through
    /// the normal `AssetResolver` path, which has nothing for a freshly
    /// synthesized `objectID` with no real on-disk `GameObject` anywhere
    /// yet (that's exactly what makes it "pending", see
    /// `PropSkinSpawnSource`'s own doc comment). Needs its own source/
    /// skin/position triple so redo can call `spawnInteractiveCortexProp`
    /// again instead, `GPULevelObject.pendingPropSkinAsset` carries the
    /// CPU-side `ResolvedModelAsset` alongside `pendingPropSkinSpawnSource`
    /// for exactly this, same "keep the asset around for redo" role
    /// `newSceneryAsset` already has for scenery placements.
    func propSkinPlacementInfo(at index: Int) -> (source: PropSkinSpawnSource, skinAsset: ResolvedModelAsset, worldPosition: SIMD3<Float>)? {
        guard objects.indices.contains(index),
              let source = objects[index].pendingPropSkinSpawnSource,
              let skinAsset = objects[index].pendingPropSkinAsset
        else { return nil }
        return (source, skinAsset, objects[index].worldPosition)
    }

    /// "Batch Editing, Select All Matching", real, requested missing
    /// feature: the real object type ID for the Instance at `index`,
    /// whether it's a same-session placement or a real, on-disk one, same
    /// "new ID, or look up the real one from its source node" resolution
    /// `duplicateSelectedObject`/`scatterAroundSelected` already use, just
    /// exposed as its own narrow read so a caller can group objects by
    /// type without needing this renderer's private `objects` array.
    func instanceObjectID(at index: Int) -> UInt16? {
        guard objects.indices.contains(index), objects[index].layer == .actors else { return nil }
        let object = objects[index]
        return object.newInstanceObjectID ?? object.sourceNode.flatMap { instanceObjectIDByNodeID[$0.id] }
    }

    /// "Interactive Scenery Placement", real spawn+write-back for a
    /// scenery model, the same pattern `spawnInstance` gives the Forge
    /// Palette, closing the gap that used to make the Scenery tab
    /// immediately compute patched bytes and demand a save-location panel
    /// on every single click with no way to see the object first, adjust
    /// it, or place more than one before saving. `asset` comes straight
    /// from the Scenery tab's own already-resolved catalog entry
    /// (`WorkspaceViewModel.SceneryCatalogEntry.asset`), no re-resolution
    /// needed here, unlike `spawnInstance`'s `AssetResolver` lookup.
    @discardableResult
    func spawnScenery(modelID: UInt32, isSpecial: Bool, asset: ResolvedModelAsset, at worldPosition: SIMD3<Float>, applyPlacementAlignment: Bool = true) -> Int? {
        let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: asset.mesh, submeshMaterials: asset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture)
        guard !built.submeshes.isEmpty else { return nil }

        let syntheticID = nextSyntheticSceneryID
        nextSyntheticSceneryID += 1
        var generatedCollisionData: [GraphicsInfoCollisionData] = []
        let assetCollisionData: [GraphicsInfoCollisionData] = asset.skeleton?.collisionData ?? []
        let localBounds = Self.localBounds(of: asset.mesh)
        // Real, reported bug ("I place scenery and there's no collision on
        // any of it"): this used to call `generateCollisionDataFromMesh`
        //, a real Metal shader compile + GPU compute round trip
        // (`CollisionDecimator.computeOrientedBoundingBox`) that can, and
        // for some real meshes does, silently return `nil`/empty with no
        // error at all, leaving this object with zero collision data,
        // full stop (`assetCollisionData` is also empty for a plain,
        // non-skeletal `RigidModel`, the overwhelming majority of real
        // scenery). `collisionDataHuggingMesh` is the reliable, pure-CPU
        // fallback this project's own later fix for *existing*, already-
        // on-disk scenery/Instance placements already established
        // specifically *because* the GPU path isn't reliable enough to run
        // at level-load scale (see that function's own doc comment) , 
        // and, per real, reported feedback, hugs the mesh's real
        // silhouette with several boxes instead of one loose AABB
        // (`localBounds` was already being computed here regardless, for
        // the placement-alignment call two lines below, and still is , 
        // `magnetSnappedPlacementPosition` genuinely only needs the plain
        // bounds).
        if assetCollisionData.isEmpty {
            generatedCollisionData = ModelViewerRenderer.collisionDataHuggingMesh(mesh: asset.mesh)
        }
        // See `spawnInstance`'s own doc comment on `applyPlacementAlignment`.
        var snappedWorldPosition = applyPlacementAlignment
            ? magnetSnappedPlacementPosition(worldPosition, localBoundsMin: localBounds.min, localBoundsMax: localBounds.max, scale: SIMD3(1, 1, 1))
            : worldPosition
        // See `placementGroundClearance`'s own doc comment.
        if applyPlacementAlignment { snappedWorldPosition.y += Self.placementGroundClearance }
        objects.append(GPULevelObject(
            worldPosition: snappedWorldPosition,
            displayName: asset.displayName,
            submeshes: built.submeshes,
            layer: .scenery,
            boundingRadius: Self.boundingRadius(of: asset.mesh),
            localBoundsMin: localBounds.min,
            localBoundsMax: localBounds.max,
            newSceneryModelID: modelID,
            newSceneryIsSpecial: isSpecial,
            syntheticSceneryID: syntheticID,
            newSceneryAsset: asset,
            generatedCollisionData: generatedCollisionData,
            assetCollisionData: assetCollisionData
        ))
        let newIndex = objects.count - 1
        select(index: newIndex)
        return newIndex
    }

    /// "Live Cross-Level Scenery Placement": same real spawn+select as
    /// `spawnScenery`, for a model borrowed from another level whose
    /// geometry doesn't exist in this destination file yet. `asset` is
    /// still the Scenery tab's own already-resolved entry (rendering
    /// needs no source-file awareness at all, a mesh looks the same
    /// regardless of which file its RigidModel record eventually lands
    /// in), but the *real* modelID isn't known until the geometry is
    /// actually copied at save time, so `newSceneryModelID` here is a
    /// session-local placeholder (`source.sourceModelID`, never written
    /// to disk directly, `pendingNewScenery` excludes any object with a
    /// non-nil `pendingCrossLevelGeometrySource`).
    @discardableResult
    func spawnCrossLevelScenery(source: CrossLevelSceneryGeometrySource, asset: ResolvedModelAsset, at worldPosition: SIMD3<Float>, applyPlacementAlignment: Bool = true) -> Int? {
        let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: asset.mesh, submeshMaterials: asset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture)
        guard !built.submeshes.isEmpty else { return nil }

        let syntheticID = nextSyntheticSceneryID
        nextSyntheticSceneryID += 1
        // See `spawnScenery`'s own doc comment on this exact fix: the real
        // condition is "no asset-provided collision data exists," not
        // "no skeleton exists", a plain, non-skeletal `RigidModel` must
        // still get generated collision. Uses `collisionDataHuggingMesh`
        // (reliable, CPU-only, and hugs the real silhouette with several
        // boxes rather than one loose AABB), not the fallible GPU-based
        // `generateCollisionDataFromMesh`, see `spawnScenery`'s own doc
        // comment on that fix, for the identical real bug on this
        // cross-level placement path.
        let assetCollisionData: [GraphicsInfoCollisionData] = asset.skeleton?.collisionData ?? []
        var generatedCollisionData: [GraphicsInfoCollisionData] = []
        let localBounds = Self.localBounds(of: asset.mesh)
        if assetCollisionData.isEmpty {
            generatedCollisionData = ModelViewerRenderer.collisionDataHuggingMesh(mesh: asset.mesh)
        }
        // See `spawnInstance`'s own doc comment on `applyPlacementAlignment`.
        var snappedWorldPosition = applyPlacementAlignment
            ? magnetSnappedPlacementPosition(worldPosition, localBoundsMin: localBounds.min, localBoundsMax: localBounds.max, scale: SIMD3(1, 1, 1))
            : worldPosition
        // See `placementGroundClearance`'s own doc comment.
        if applyPlacementAlignment { snappedWorldPosition.y += Self.placementGroundClearance }
        objects.append(GPULevelObject(
            worldPosition: snappedWorldPosition,
            displayName: asset.displayName,
            submeshes: built.submeshes,
            layer: .scenery,
            boundingRadius: Self.boundingRadius(of: asset.mesh),
            localBoundsMin: localBounds.min,
            localBoundsMax: localBounds.max,
            newSceneryModelID: source.sourceModelID,
            newSceneryIsSpecial: false,
            syntheticSceneryID: syntheticID,
            newSceneryAsset: asset,
            generatedCollisionData: generatedCollisionData,
            assetCollisionData: assetCollisionData,
            pendingCrossLevelGeometrySource: source
        ))
        let newIndex = objects.count - 1
        select(index: newIndex)
        return newIndex
    }

    /// "Spawn Interactive Cortex (Prop)": places a real, working `Instance`
    /// under a freshly synthesized `objectID`, visually Cortex's own
    /// skinned mesh (`skinAsset`, already resolved by the caller from
    /// `source.skinSourceFileRoot`/`skinSourceBytes`, static bind pose,
    /// same disclosed limitation every cross-file `GameObject` copy this
    /// build produces has), behaviorally `source.baseGameObject`'s own
    /// real crate scripts/physics (`BASICCRATE`, untouched), see
    /// `PropSkinSpawnSource`'s own doc comment for why this needs its own
    /// spawn path rather than `spawnInstance`'s real-`objectID` resolution.
    func spawnInteractiveCortexProp(source: PropSkinSpawnSource, skinAsset: ResolvedModelAsset, at worldPosition: SIMD3<Float>? = nil, applyPlacementAlignment: Bool = true) -> Int? {
        let built = ModelViewerRenderer.buildGPUSubmeshes(mesh: skinAsset.mesh, submeshMaterials: skinAsset.submeshMaterials, device: device, fallbackTexture: context.fallbackTexture)
        guard !built.submeshes.isEmpty else { return nil }

        let worldPosition = worldPosition ?? boundsCenter
        let localBounds = Self.localBounds(of: skinAsset.mesh)
        let assetCollisionData: [GraphicsInfoCollisionData] = skinAsset.skeleton?.collisionData ?? []
        var generatedCollisionData: [GraphicsInfoCollisionData] = []
        if assetCollisionData.isEmpty {
            generatedCollisionData = ModelViewerRenderer.collisionDataHuggingMesh(mesh: skinAsset.mesh)
        }
        var snappedWorldPosition = applyPlacementAlignment
            ? magnetSnappedPlacementPosition(worldPosition, localBoundsMin: localBounds.min, localBoundsMax: localBounds.max, scale: SIMD3(1, 1, 1))
            : worldPosition
        if applyPlacementAlignment { snappedWorldPosition.y += Self.placementGroundClearance }

        let syntheticID = nextSyntheticInstanceID
        nextSyntheticInstanceID += 1
        objects.append(GPULevelObject(
            worldPosition: snappedWorldPosition,
            displayName: "Interactive Cortex (Prop)",
            submeshes: built.submeshes,
            layer: .actors,
            boundingRadius: Self.boundingRadius(of: skinAsset.mesh),
            localBoundsMin: localBounds.min,
            localBoundsMax: localBounds.max,
            newInstanceObjectID: source.freshObjectID,
            syntheticInstanceID: syntheticID,
            generatedCollisionData: generatedCollisionData,
            assetCollisionData: assetCollisionData,
            pendingPropSkinSpawnSource: source,
            pendingPropSkinAsset: skinAsset
        ))
        let newIndex = objects.count - 1
        select(index: newIndex)
        return newIndex
    }

    /// Whether `duplicateSelectedObject` could actually do anything for
    /// the object at `index` right now, lets the UI disable/explain the
    /// Duplicate button up front instead of the action silently no-oping.
    func canDuplicate(at index: Int) -> Bool {
        guard objects.indices.contains(index) else { return false }
        let object = objects[index]
        switch object.layer {
        case .actors:
            return object.newInstanceObjectID != nil || (object.sourceNode.flatMap { instanceObjectIDByNodeID[$0.id] } != nil)
        case .aiWaypoints:
            return true
        case .triggers, .cameras:
            return object.cameraControlPointFileOffset == nil
        case .scenery:
            return object.newSceneryModelID != nil
        default:
            return false
        }
    }

    /// "Unrestricted Chunk Free-Edit Mode": duplicate the selected object
    /// a short offset from its current position, through the exact same
    /// real spawn+write-back pipeline `spawnInstance`/`spawnAIWaypoint`/
    /// `spawnTrigger`/`spawnCamera`/`spawnScenery` already give the Forge
    /// Palette/"Add Trigger"/"Add Camera"/Scenery tab, the duplicate
    /// becomes a real new record on save, not a purely visual copy nobody
    /// can persist. A scenery object loaded from the level's own file
    /// still has no write path of any kind (long-standing, unchanged by
    /// this) and isn't offered, `nil`, not a fabricated copy that would
    /// silently vanish on save, but one placed this session via
    /// `spawnScenery` duplicates the same as any other session placement.
    ///
    /// Trigger/Camera duplicates spawn with the reference tool's own
    /// default size/rotation (same as a fresh "Add Trigger"/"Add Camera"),
    /// not an exact copy of the source's real dimensions, this build
    /// doesn't thread a selected Trigger/Camera's `size`/`rotationQuaternion`
    /// into `GPULevelObject`, only its position. Still a real, useful
    /// duplicate (a new record of the same kind, positioned nearby, fully
    /// editable before saving), just not a byte-exact clone.
    ///
    /// A session-placed scenery object now has a real write path
    /// (`spawnScenery`/`pendingNewScenery`), but duplicating one still
    /// returns `nil` here, not attempted as part of that change, only
    /// placement itself.
    @discardableResult
    func duplicateSelectedObject() -> Int? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        let object = objects[selectedObjectIndex]
        let offsetPosition = object.worldPosition + SIMD3<Float>(1, 0, 1)
        switch object.layer {
        case .actors:
            let objectID = object.newInstanceObjectID ?? object.sourceNode.flatMap { instanceObjectIDByNodeID[$0.id] }
            guard let objectID else { return nil }
            return spawnInstance(objectID: objectID, at: offsetPosition, applyPlacementAlignment: false)
        case .aiWaypoints:
            let rawNodeType = object.newAIWaypointRawNodeType ?? object.originalAIWaypointRawNodeType ?? 0
            return spawnAIWaypoint(at: offsetPosition, rawNodeType: rawNodeType)
        case .triggers:
            guard object.cameraControlPointFileOffset == nil else { return nil }
            return spawnTrigger(at: offsetPosition)
        case .cameras:
            guard object.cameraControlPointFileOffset == nil else { return nil }
            return spawnCamera(at: offsetPosition)
        case .scenery:
            guard let asset = object.newSceneryAsset else { return nil }
            // A cross-level placement's own `newSceneryModelID` is a
            // session-local placeholder, not real, duplicate it the
            // same way it was originally placed (another pending
            // cross-level copy), not via `spawnScenery`, which would
            // treat that placeholder as if it already resolved here.
            if let crossLevelSource = object.pendingCrossLevelGeometrySource {
                return spawnCrossLevelScenery(source: crossLevelSource, asset: asset, at: offsetPosition, applyPlacementAlignment: false)
            }
            guard let modelID = object.newSceneryModelID, let isSpecial = object.newSceneryIsSpecial else { return nil }
            return spawnScenery(modelID: modelID, isSpecial: isSpecial, asset: asset, at: offsetPosition, applyPlacementAlignment: false)
        default:
            return nil
        }
    }

    /// Marking menu "Copy"/"Cut"/"Paste": the same per-layer identity this
    /// object would need to be spawned fresh, deliberately *not* a raw
    /// array index, since `objects` reorders under delete/insert (a copied
    /// index could silently point at a different object, or nothing, by
    /// the time Paste runs) and *not* a stored `GPULevelObject` value
    /// either (unlike `RemovedObjectSnapshot`, which is fine reinserting
    /// the exact removed value because there is by definition no other
    /// copy of that value's `sourceNode` still in the scene, Copy doesn't
    /// remove anything, so reinserting the raw value would leave two
    /// objects referencing one real on-disk record). A value snapshot of
    /// "what would `duplicateSelectedObject` need to spawn this again,"
    /// so Paste can just call the same spawn primitives.
    struct ObjectClipboardEntry {
        fileprivate let layer: SceneLayer
        fileprivate let instanceObjectID: UInt16?
        fileprivate let aiWaypointRawNodeType: UInt16?
        fileprivate let sceneryModelID: UInt32?
        fileprivate let sceneryIsSpecial: Bool?
        fileprivate let sceneryAsset: ResolvedModelAsset?
        fileprivate let worldPosition: SIMD3<Float>
    }

    /// Non-destructive "Copy", same per-layer eligibility and identity
    /// lookup as `duplicateSelectedObject`, just packaged as a value that
    /// outlives the current selection instead of acting immediately.
    func copyObject(at index: Int) -> ObjectClipboardEntry? {
        guard objects.indices.contains(index) else { return nil }
        let object = objects[index]
        switch object.layer {
        case .actors:
            guard let objectID = object.newInstanceObjectID ?? object.sourceNode.flatMap({ instanceObjectIDByNodeID[$0.id] }) else { return nil }
            return ObjectClipboardEntry(layer: .actors, instanceObjectID: objectID, aiWaypointRawNodeType: nil, sceneryModelID: nil, sceneryIsSpecial: nil, sceneryAsset: nil, worldPosition: object.worldPosition)
        case .aiWaypoints:
            let rawNodeType = object.newAIWaypointRawNodeType ?? object.originalAIWaypointRawNodeType ?? 0
            return ObjectClipboardEntry(layer: .aiWaypoints, instanceObjectID: nil, aiWaypointRawNodeType: rawNodeType, sceneryModelID: nil, sceneryIsSpecial: nil, sceneryAsset: nil, worldPosition: object.worldPosition)
        case .triggers:
            guard object.cameraControlPointFileOffset == nil else { return nil }
            return ObjectClipboardEntry(layer: .triggers, instanceObjectID: nil, aiWaypointRawNodeType: nil, sceneryModelID: nil, sceneryIsSpecial: nil, sceneryAsset: nil, worldPosition: object.worldPosition)
        case .cameras:
            guard object.cameraControlPointFileOffset == nil else { return nil }
            return ObjectClipboardEntry(layer: .cameras, instanceObjectID: nil, aiWaypointRawNodeType: nil, sceneryModelID: nil, sceneryIsSpecial: nil, sceneryAsset: nil, worldPosition: object.worldPosition)
        case .scenery:
            guard let modelID = object.newSceneryModelID, let isSpecial = object.newSceneryIsSpecial, let asset = object.newSceneryAsset else { return nil }
            return ObjectClipboardEntry(layer: .scenery, instanceObjectID: nil, aiWaypointRawNodeType: nil, sceneryModelID: modelID, sceneryIsSpecial: isSpecial, sceneryAsset: asset, worldPosition: object.worldPosition)
        default:
            return nil
        }
    }

    /// "Paste", spawns a brand-new, independent object from a clipboard
    /// entry through the exact same spawn primitives `duplicateSelectedObject`
    /// uses, at the same "short offset from where it was copied" position
    /// (there's no cursor-to-world raycast wired up for the marking menu,
    /// so Paste doesn't try to drop the object under the cursor, same
    /// honest limitation `duplicateSelectedObject` already has).
    @discardableResult
    func pasteObject(_ entry: ObjectClipboardEntry) -> Int? {
        let position = entry.worldPosition + SIMD3<Float>(1, 0, 1)
        switch entry.layer {
        case .actors:
            guard let objectID = entry.instanceObjectID else { return nil }
            return spawnInstance(objectID: objectID, at: position, applyPlacementAlignment: false)
        case .aiWaypoints:
            return spawnAIWaypoint(at: position, rawNodeType: entry.aiWaypointRawNodeType ?? 0)
        case .triggers:
            return spawnTrigger(at: position)
        case .cameras:
            return spawnCamera(at: position)
        case .scenery:
            guard let modelID = entry.sceneryModelID, let isSpecial = entry.sceneryIsSpecial, let asset = entry.sceneryAsset else { return nil }
            return spawnScenery(modelID: modelID, isSpecial: isSpecial, asset: asset, at: position, applyPlacementAlignment: false)
        default:
            return nil
        }
    }

    /// "Procedural Brush" (roadmap 8.6, the real half; the script-to-English half isn't attempted): scatters
    /// `count` more copies of the selected Instance placement's real
    /// objectID at randomized positions within `radius` of it (each with
    /// an independent random Y-axis rotation for natural variation),
    /// through the exact same real `spawnInstance` pipeline
    /// `duplicateSelectedObject` already uses, every scattered copy is a
    /// real new `Instance` record on save, not a purely visual copy. Only
    /// `.actors` has a real spawn primitive to scatter through (same
    /// reasoning as `duplicateSelectedObject`'s own layer check); any
    /// other layer returns an empty array rather than a fabricated one.
    @discardableResult
    func scatterAroundSelected(count: Int, radius: Float) -> [Int] {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex), count > 0, radius > 0 else { return [] }
        let object = objects[selectedObjectIndex]
        guard object.layer == .actors else { return [] }
        let objectID = object.newInstanceObjectID ?? object.sourceNode.flatMap { instanceObjectIDByNodeID[$0.id] }
        guard let objectID else { return [] }

        var newIndices: [Int] = []
        for _ in 0..<count {
            let angle = Float.random(in: 0..<(2 * .pi))
            let distance = Float.random(in: 0...radius)
            let offset = SIMD3<Float>(cos(angle) * distance, 0, sin(angle) * distance)
            guard let newIndex = spawnInstance(objectID: objectID, at: object.worldPosition + offset, applyPlacementAlignment: false) else { continue }
            objects[newIndex].rotation = simd_quatf(angle: Float.random(in: 0..<(2 * .pi)), axis: SIMD3(0, 1, 0))
            newIndices.append(newIndex)
        }
        if let lastIndex = newIndices.last { select(index: lastIndex) }
        return newIndices
    }

    /// "AI Pathfinding & Navmesh Editor" (roadmap 5.1): appends a brand-new
    /// waypoint marker at `worldPosition` (defaulting to the level's own
    /// visual center, same "as good a default drop point as any" reasoning
    /// as `addObject`'s own doc comment) with a synthetic `AIPosition` ID
    /// (namespaced separately from `spawnInstance`'s, see
    /// `nextSyntheticAIPositionID`'s doc comment), selects it immediately.
    /// `rawNodeType` defaults to `0` (`AIPositionMarker.NodeType.ground`)
    ///, the most common real value, not a guess dressed up as a default;
    /// still fully editable before saving.
    @discardableResult
    func spawnAIWaypoint(at worldPosition: SIMD3<Float>? = nil, rawNodeType: UInt16 = 0) -> Int? {
        let worldPosition = worldPosition ?? boundsCenter
        let syntheticID = nextSyntheticAIPositionID
        nextSyntheticAIPositionID += 1
        objects.append(GPULevelObject(
            worldPosition: worldPosition,
            displayName: "New AI Waypoint #\(syntheticID)",
            submeshes: [],
            layer: .aiWaypoints,
            newAIWaypointRawNodeType: rawNodeType,
            syntheticAIPositionID: syntheticID
        ))
        let newIndex = objects.count - 1
        select(index: newIndex)
        return newIndex
    }

    /// "Add Trigger": appends a brand-new Trigger marker at `worldPosition`
    /// (defaulting to the level's own visual center) with a synthetic ID , 
    /// closes the parity gap the original editor's `Menu_AddNew` has for
    /// Trigger records (not just Instances/AI-waypoints). Renders exactly
    /// like an existing Trigger, an empty-submesh, `.triggers`-layer
    /// wireframe box the draw loop already builds for every Trigger,
    /// selected/editable/movable the same way.
    @discardableResult
    func spawnTrigger(at worldPosition: SIMD3<Float>? = nil) -> Int? {
        let worldPosition = worldPosition ?? boundsCenter
        let syntheticID = nextSyntheticTriggerID
        nextSyntheticTriggerID += 1
        objects.append(GPULevelObject(
            worldPosition: worldPosition,
            displayName: "New Trigger #\(syntheticID)",
            submeshes: [],
            layer: .triggers,
            syntheticTriggerID: syntheticID
        ))
        let newIndex = objects.count - 1
        select(index: newIndex)
        return newIndex
    }

    /// "Add Camera": same role as `spawnTrigger`, for Camera records.
    @discardableResult
    func spawnCamera(at worldPosition: SIMD3<Float>? = nil) -> Int? {
        let worldPosition = worldPosition ?? boundsCenter
        let syntheticID = nextSyntheticCameraID
        nextSyntheticCameraID += 1
        objects.append(GPULevelObject(
            worldPosition: worldPosition,
            displayName: "New Camera #\(syntheticID)",
            submeshes: [],
            layer: .cameras,
            syntheticCameraID: syntheticID
        ))
        let newIndex = objects.count - 1
        select(index: newIndex)
        return newIndex
    }

    /// Same role as `newInstanceInfo`, for `spawnTrigger`'s undo path.
    func newTriggerInfo(at index: Int) -> SIMD3<Float>? {
        guard objects.indices.contains(index), objects[index].syntheticTriggerID != nil else { return nil }
        return objects[index].worldPosition
    }

    /// Same role as `newInstanceInfo`, for `spawnCamera`'s undo path.
    func newCameraInfo(at index: Int) -> SIMD3<Float>? {
        guard objects.indices.contains(index), objects[index].syntheticCameraID != nil else { return nil }
        return objects[index].worldPosition
    }

    /// Same role as `newInstanceInfo`, for `spawnScenery`'s undo path , 
    /// `newSceneryAsset` (added alongside `newSceneryModelID`/
    /// `newSceneryIsSpecial` specifically for this) is what a redo needs
    /// to call `spawnScenery` again without re-resolving anything.
    func newSceneryInfo(at index: Int) -> (modelID: UInt32, isSpecial: Bool, asset: ResolvedModelAsset, worldPosition: SIMD3<Float>, crossLevelSource: CrossLevelSceneryGeometrySource?)? {
        guard objects.indices.contains(index),
              let modelID = objects[index].newSceneryModelID,
              let isSpecial = objects[index].newSceneryIsSpecial,
              let asset = objects[index].newSceneryAsset
        else { return nil }
        return (modelID, isSpecial, asset, objects[index].worldPosition, objects[index].pendingCrossLevelGeometrySource)
    }

    /// Opaque snapshot of a just-removed object, letting `LevelViewerWindow`'s
    /// undo registration restore it exactly via `restoreObject(_:at:)`
    /// without this file needing to expose `GPULevelObject` itself outside
    /// its own translation unit, same "rebuild from a stable value, not a
    /// captured reference" posture `registerPlacementUndo` already uses,
    /// just carrying the whole removed value instead of primitive fields
    /// (a `GPULevelObject` is a plain value type, trivially safe to hold
    /// onto and reinsert later, submeshes included, with no reconstruction
    /// needed).
    struct RemovedObjectSnapshot {
        fileprivate let object: GPULevelObject
        fileprivate let wasRealRecord: Bool
    }

    /// Whether `deleteObject(at:)` would do anything for the object at
    /// `index` right now, mirrors `canDuplicate(at:)`'s "let the UI
    /// disable/explain the button up front" role. True for every
    /// Instance/Trigger/Camera/AI-waypoint, whether a real on-disk record
    /// or something placed this session, the original editor's
    /// `ItemController` gives every record type universal Remove, and this
    /// build's "delete" now genuinely persists for all four (see
    /// `ChunkSectionInserter.removingRecord`). Also true for scenery , 
    /// either a session placement (`newSceneryModelID`) or a real, on-disk
    /// one from this level's own file (`sceneryMatrixFileOffset`, real
    /// removal via `SceneryGroup.removingPlacements`); still false for a
    /// stitched neighbor chunk's scenery (no `sceneryMatrixFileOffset` , 
    /// wrong file to remove from), cross-engine markers, and a camera's
    /// own spline/path control-point markers, deleting a control point
    /// isn't "delete this camera," and inserting/removing individual
    /// control points still isn't supported, only moving an existing one.
    func canDelete(at index: Int) -> Bool {
        guard objects.indices.contains(index) else { return false }
        let object = objects[index]
        guard object.cameraControlPointFileOffset == nil else { return false }
        switch object.layer {
        case .actors, .aiWaypoints, .triggers, .cameras:
            return true
        case .scenery:
            return object.newSceneryModelID != nil || object.sceneryMatrixFileOffset != nil
        default:
            return false
        }
    }

    /// Removes the object at `index`, returning a snapshot `restoreObject`
    /// can use to put it back exactly. When the removed object came from
    /// a real, on-disk record (not a same-session placement), its record
    /// ID is also recorded in `removedRealRecordIDs` so `saveLevelOverrides()`
    /// can pass it through to `ChunkSectionInserter.removingRecord`, a
    /// same-session placement being deleted needs no such tracking, it
    /// simply never appears in `pendingNew*` at save time.
    @discardableResult
    func deleteObject(at index: Int) -> RemovedObjectSnapshot? {
        guard canDelete(at: index) else { return nil }
        let object = objects[index]
        let isSessionPlacement = object.newInstanceObjectID != nil || object.newAIWaypointRawNodeType != nil || object.syntheticTriggerID != nil || object.syntheticCameraID != nil
        let wasRealRecord = !isSessionPlacement && object.sourceNode != nil
        if wasRealRecord, let node = object.sourceNode {
            removedRealRecordIDs.append((layer: object.layer, id: node.recordID))
        }
        // Scenery has no `ChunkNode`/`sourceNode` to key off, real
        // placements are just array entries, identified by their own
        // unique `sceneryMatrixFileOffset` instead (see `GPULevelObject
        // .sceneryMatrixFileOffset`'s own doc comment).
        if let sceneryOffset = object.sceneryMatrixFileOffset {
            removedRealSceneryOffsets.append(sceneryOffset)
        }
        // "Ghost Collision Removal", real, reported bug: deleting a real,
        // on-disk object left its original collision behind in `ColData`
        // forever, since there's no on-disk link from a collision triangle
        // back to the placement that authored it. This can't be solved
        // exactly (see `LevelCollisionRebuilder.removingGroupsNear`'s own
        // doc comment for why), but capturing the deleted object's own
        // real world-space volume *here*, at the one moment its true
        // extent is still known, is what makes a real best-effort
        // proximity-based removal possible at all, undone by
        // `restoreObject` below the same way `removedRealRecordIDs`/
        // `removedRealSceneryOffsets` already are.
        if wasRealRecord || object.sceneryMatrixFileOffset != nil {
            let corners = Self.worldAABBCorners(of: object)
            if var minP = corners.first {
                var maxP = minP
                for corner in corners.dropFirst() { minP = simd_min(minP, corner); maxP = simd_max(maxP, corner) }
                pendingCollisionRemovals.append(PendingCollisionRemoval(
                    recordID: wasRealRecord ? object.sourceNode?.recordID : nil,
                    sceneryOffset: object.sceneryMatrixFileOffset,
                    layer: object.layer,
                    worldMin: minP, worldMax: maxP
                ))
            }
        }
        removeObject(at: index)
        return RemovedObjectSnapshot(object: object, wasRealRecord: wasRealRecord)
    }

    /// One real, deleted-this-session object's own world-space volume,
    /// captured at delete time, the input `rebuildLevelCollision()` feeds
    /// to `LevelCollisionRebuilder.removingGroupsNear`.
    struct PendingCollisionRemoval {
        var recordID: UInt32?
        var sceneryOffset: Int?
        var layer: SceneLayer
        var worldMin: SIMD3<Float>
        var worldMax: SIMD3<Float>
    }
    private(set) var pendingCollisionRemovals: [PendingCollisionRemoval] = []

    /// "Rebuild All Collision": deliberately
    /// opt-in (default `false`, never automatic, an earlier *automatic*
    /// collision-sync feature shipped and caused a real, confirmed
    /// regression: a corrupted disc that black-screened in real PCSX2).
    /// Destroys the level's *entire* on-disk collision mesh and regenerates
    /// it from scratch using every real scenery object's own actual
    /// geometry. `LevelViewerWindow.computingRebuiltCollisionRecord` reads
    /// this flag and it's this renderer's own responsibility (via that
    /// button's own action) to clear it back to `false` once consumed, so
    /// a full rebuild can never silently leak into a later, unrelated save.
    var rebuildAllCollisionRequested = false

    /// "Play As" (Advanced panel): a real, verified alternate playable
    /// character (see `PlayableCharacterOption`'s own doc comment) to
    /// replace whichever character currently occupies `GameObject` id 0 , 
    /// `nil` means no swap, the level's own original character stays as-is.
    /// Non-`nil` only while pending confirmation/save, same "this renderer's
    /// own responsibility to clear it once consumed" discipline as
    /// `rebuildAllCollisionRequested` above.
    var pendingPlayerCharacterSwap: PlayableCharacterOption?

    /// "Rebuild Collision for This Object", the per-object counterpart to
    /// `rebuildAllCollisionRequested` above: non-`nil` only while a single
    /// object's collision rebuild (via the marking menu) is pending
    /// confirmation/save, holding that object's index into `levelObjects`.
    /// Same reset-after-consumption contract as the two flags above.
    var rebuildCollisionRequestedForObjectIndex: Int?

    /// "Real Flags for Forge-Placed Objects": real `InstanceTemplate.
    /// properties` values for this level, keyed by `objectID`, set once
    /// from `LevelViewerContext.instanceTemplatePropertiesByObjectID` when
    /// this renderer is constructed (`LevelViewerWindow`'s own `.onAppear`).
    /// `computingPendingOverridePatch` reads this per newly-placed object
    /// instead of using one hardcoded flags value for every object type.
    var instanceTemplatePropertiesByObjectID: [UInt16: UInt32] = [:]

    /// "Real AI/Combat Behavior for Forge-Placed Objects": the first real,
    /// non-"no script" `scriptID` this level's own already-real Instance
    /// records carry, keyed by `objectID`, set once from
    /// `LevelViewerContext.instanceScriptIDByObjectID` the same way
    /// `instanceTemplatePropertiesByObjectID` is. `computingPendingOverridePatch`
    /// reads this per newly-placed object so a fresh placement of a type
    /// that already has a working AI script elsewhere in this level starts
    /// with that same script attached instead of none at all.
    var instanceScriptIDByObjectID: [UInt16: Int16] = [:]

    /// Same world-space corner computation `rebuildLevelCollision`'s own
    /// gathering loop uses for a *new* object's collision box, reused here
    /// for a *deleted* one's, real local bounds, scaled, rotated, then
    /// translated to this object's actual world position.
    private static func worldAABBCorners(of object: GPULevelObject) -> [SIMD3<Float>] {
        let half = (object.localBoundsMax - object.localBoundsMin) / 2 * object.scale
        let center = (object.localBoundsMax + object.localBoundsMin) / 2 * object.scale
        var corners: [SIMD3<Float>] = []
        for sx in [Float(-1), 1] {
            for sy in [Float(-1), 1] {
                for sz in [Float(-1), 1] {
                    let local = center + SIMD3(half.x * sx, half.y * sy, half.z * sz)
                    let display = object.rotation.act(local) + object.worldPosition
                    // Real, reported bug: `object.worldPosition` (and every
                    // scenery vertex) is in this editor's mirrored *display*
                    // space, but real on-disk `ColData`, what
                    // `PendingCollisionRemoval`'s `worldMin`/`worldMax`
                    // ultimately search against via `removingGroupsNear` , 
                    // stores raw, unmirrored coordinates (empirically
                    // confirmed against this game's own real `beach.rm2`;
                    // see `LevelViewerWindow.rawColDataPosition`'s own doc
                    // comment for the measured evidence). Without this,
                    // "Ghost Collision Removal" searches at the mirror
                    // image of where an object's own real collision
                    // actually is and never finds it.
                    corners.append(SIMD3(-display.x, display.y, display.z))
                }
            }
        }
        return corners
    }

    /// **Real, reported bug** ("mostly visible now, but still flickers
    /// right at the edge/corner of the camera view for a placed object,
    /// and only that object, never real, dev-placed scenery"): every
    /// real `SceneryModelPlacement.boundingBoxMin`/`boundingBoxMax` on the
    /// pristine disc is **local**, rotated/scaled but *not* translated by
    /// the placement's own world position, symmetric around origin
    /// (empirically confirmed: a real placement at world position
    /// `(105.6, 5.1, 13.2)` carries a bbox of exactly `(-9.1,-16.3,-9.1)`
    /// to `(9.1,16.3,9.1)`, `min == -max` exactly, completely unrelated
    /// in magnitude to the real position). `pendingNewScenery` was reusing
    /// `worldAABBCorners(of:)` for this field, which, correctly, for its
    /// *other* real caller, `ColData` collision removal, adds
    /// `object.worldPosition` into every corner. For a scenery placement
    /// far from the level's own local origin, that silently wrote a wildly
    /// wrong bounding box (offset by the object's own real position, not
    /// centered on it) into the one on-disk field a per-object frustum/
    /// clip test would read, a large-radius, badly-mislocated box behaves
    /// correctly enough that the object still renders across most of the
    /// screen (the group-level `unkPos` capsule bound decides *whether to
    /// draw the group at all*; this decides finer per-object clipping),
    /// but fails right at the frustum boundary, which is exactly where a
    /// per-object clip test actually gets exercised. Same rotation/scale
    /// math as `worldAABBCorners(of:)`, just without the final
    /// `+ object.worldPosition` translation, and without needing that
    /// function's own X-mirror correction either, this bbox is written
    /// directly into `SceneryModelPlacement.boundingBoxMin`/`Max`, in the
    /// same coordinate convention every other real, on-disk placement's
    /// bbox already uses (confirmed local/symmetric, not display-mirrored,
    /// from the real sample above).
    private static func localAABBCorners(of object: GPULevelObject) -> [SIMD3<Float>] {
        let half = (object.localBoundsMax - object.localBoundsMin) / 2 * object.scale
        let center = (object.localBoundsMax + object.localBoundsMin) / 2 * object.scale
        var corners: [SIMD3<Float>] = []
        for sx in [Float(-1), 1] {
            for sy in [Float(-1), 1] {
                for sz in [Float(-1), 1] {
                    let local = center + SIMD3(half.x * sx, half.y * sy, half.z * sz)
                    corners.append(object.rotation.act(local))
                }
            }
        }
        return corners
    }

    /// **Second refinement to the same bug** `localAABBCorners(of:)`'s own
    /// doc comment documents, the first fix (a true local min/max AABB)
    /// was still subtly wrong. Checked directly against every single real
    /// placement on the pristine disc (25,836 of them, every `.sm2` file):
    /// **100% have an exactly symmetric bbox** (`boundingBoxMin ==
    /// -boundingBoxMax`, to float precision), not just objects whose true
    /// local geometry happens to be centered on its own pivot, all of
    /// them, without exception. The real on-disk format doesn't store a
    /// true local AABB at all; it stores a symmetric per-axis extent (the
    /// largest absolute corner coordinate on each axis, mirrored to both
    /// sides), the same "isotropic conservative radius" shape this
    /// project's own `SceneryModelGroup.expandingUnkPos` already uses for
    /// a *different* field. A true (possibly asymmetric) local AABB from
    /// `localAABBCorners(of:)` is closer to correct than the original
    /// world-space bug, but still deviates from what every real, working
    /// placement actually stores for any mesh whose local bounds aren't
    /// already centered on its own origin (e.g. a prop with its pivot at
    /// its base), real, reported symptom this specifically may explain:
    /// "weird particles and chunks" rendering near a newly-placed object
    /// as the camera moves, on top of the edge-of-screen flicker the first
    /// fix already covered. Likely a downstream system (an LOD/streaming
    /// bound, a spatial hash) reads this field with the same "symmetric
    /// extent" assumption baked in and misbehaves on a genuinely
    /// asymmetric box, not just a badly-clipped one.
    private static func symmetricLocalExtent(of object: GPULevelObject) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var extent = SIMD3<Float>(repeating: 0)
        for corner in localAABBCorners(of: object) {
            extent = SIMD3(max(extent.x, abs(corner.x)), max(extent.y, abs(corner.y)), max(extent.z, abs(corner.z)))
        }
        return (-extent, extent)
    }

    /// The undo counterpart to `deleteObject`, re-inserts the removed
    /// object exactly as it was, at (as close as still possible to) its
    /// original index, and un-marks it for on-disk removal if it was a
    /// real record.
    func restoreObject(_ snapshot: RemovedObjectSnapshot, at index: Int) {
        let insertIndex = min(max(0, index), objects.count)
        objects.insert(snapshot.object, at: insertIndex)
        if snapshot.wasRealRecord, let node = snapshot.object.sourceNode,
           let removeAt = removedRealRecordIDs.firstIndex(where: { $0.layer == snapshot.object.layer && $0.id == node.recordID }) {
            removedRealRecordIDs.remove(at: removeAt)
        }
        if let sceneryOffset = snapshot.object.sceneryMatrixFileOffset,
           let removeAt = removedRealSceneryOffsets.firstIndex(of: sceneryOffset) {
            removedRealSceneryOffsets.remove(at: removeAt)
        }
        // Undo the `pendingCollisionRemovals` capture too, the object is
        // real and present again, so its original collision (if a rebuild
        // ever actually removes it) must stop being a removal candidate.
        pendingCollisionRemovals.removeAll { removal in
            (snapshot.wasRealRecord && removal.recordID != nil && removal.recordID == snapshot.object.sourceNode?.recordID)
                || (removal.sceneryOffset != nil && removal.sceneryOffset == snapshot.object.sceneryMatrixFileOffset)
        }
        select(index: insertIndex)
    }

    /// Every real, on-disk record deleted this session, by layer, the
    /// deletion counterpart to `pendingNewInstances`/etc. `saveLevelOverrides()`
    /// reads these into `WorkspaceViewModel.patchedFileBytes`'s
    /// `removingInstanceIDs`/`removingTriggerIDs`/`removingCameraIDs`/
    /// `removingAIPositionIDs` parameters.
    private var removedRealRecordIDs: [(layer: SceneLayer, id: UInt32)] = []
    var pendingRemovedInstanceIDs: [UInt32] { removedRealRecordIDs.filter { $0.layer == .actors }.map(\.id) }
    var pendingRemovedTriggerIDs: [UInt32] { removedRealRecordIDs.filter { $0.layer == .triggers }.map(\.id) }
    var pendingRemovedCameraIDs: [UInt32] { removedRealRecordIDs.filter { $0.layer == .cameras }.map(\.id) }
    var pendingRemovedAIPositionIDs: [UInt32] { removedRealRecordIDs.filter { $0.layer == .aiWaypoints }.map(\.id) }

    /// Every real, on-disk scenery placement deleted this session, by its
    /// own `matrixFileOffset`, the scenery counterpart to
    /// `removedRealRecordIDs`, keyed by that offset instead of a
    /// `(layer, recordID)` pair since scenery has no `ChunkNode` of its
    /// own to key off. `saveLevelOverrides()` reads this into
    /// `WorkspaceViewModel.patchedFileBytes`'s `removingSceneryOffsets`
    /// parameter.
    private var removedRealSceneryOffsets: [Int] = []
    var pendingRemovedSceneryOffsets: [Int] { removedRealSceneryOffsets }

    /// Every Trigger placed this session via `spawnTrigger`, ready to hand
    /// to `WorkspaceViewModel.patchedFileBytes`'s `insertingNewTriggers` , 
    /// the Trigger counterpart to `pendingNewInstances`.
    var pendingNewTriggers: [(id: UInt32, encoded: Data)] {
        objects.compactMap { object in
            guard let syntheticID = object.syntheticTriggerID else { return nil }
            // "Coordinate-System Overhaul": un-mirror back to raw before
            // encoding, see `pendingLevelOverrides`'s matching comment.
            let encoded = WorldPlacementWriter.writeNewTrigger(position: SIMD4(ModelViewerRenderer.mirroredWorldPosition(object.worldPosition), 1))
            return (syntheticID, encoded)
        }
    }

    /// Every Camera placed this session via `spawnCamera`, ready to hand
    /// to `WorkspaceViewModel.patchedFileBytes`'s `insertingNewCameras`.
    var pendingNewCameras: [(id: UInt32, encoded: Data)] {
        objects.compactMap { object in
            guard let syntheticID = object.syntheticCameraID else { return nil }
            let encoded = WorldPlacementWriter.writeNewCamera(position: SIMD4(ModelViewerRenderer.mirroredWorldPosition(object.worldPosition), 1), isDemo: isDemoCameraCollection)
            return (syntheticID, encoded)
        }
    }

    /// Same role as `newInstanceInfo`, for `spawnAIWaypoint`'s undo path.
    func newAIWaypointInfo(at index: Int) -> (rawNodeType: UInt16, worldPosition: SIMD3<Float>)? {
        guard objects.indices.contains(index), let rawNodeType = objects[index].newAIWaypointRawNodeType else { return nil }
        return (rawNodeType, objects[index].worldPosition)
    }

    /// The undo/redo-reachable counterpart to `spawnInstance`, removes
    /// whatever object currently sits at `index`. Callers (`LevelViewerWindow`'s
    /// undo registration) are responsible for only ever calling this with an
    /// index that's still valid for the current `objects` array; same
    /// bounds-check-and-no-op-if-stale posture as `select(index:)`.
    func removeObject(at index: Int) {
        guard objects.indices.contains(index) else { return }
        objects.remove(at: index)
        if selectedObjectIndex == index {
            select(index: nil)
        } else if let selectedObjectIndex, selectedObjectIndex > index {
            select(index: selectedObjectIndex - 1)
        }
        // Explicit, not relying on `select(index:)` above to piggyback
        // this the way `rebuildSelectionBuffer()` does elsewhere, neither
        // branch above runs when removing an object *before* the current
        // selection (or when nothing's selected at all), which would
        // silently leave an AI Path's connector line pointing at a
        // waypoint that no longer exists.
        rebuildAIPathLineBuffer()
    }

    /// "Backend Requirement: calculate the XYZ position", every object
    /// placed via the palette that hasn't been saved yet, ready to hand to
    /// a real record-injection writer. Position/rotation/scale come
    /// straight off the live `GPULevelObject`, same as `pendingLevelOverrides`.
    var pendingNewInstances: [(objectID: UInt16, syntheticID: UInt32, position: SIMD3<Float>, rotationDegrees: SIMD3<Float>, pathIDs: [UInt16])] {
        objects.compactMap { object in
            guard let objectID = object.newInstanceObjectID, let syntheticID = object.syntheticInstanceID else { return nil }
            // "Coordinate-System Overhaul": `position` here feeds straight
            // into `WorldPlacementWriter.writeNewInstance` at the call site
            // (`LevelViewerWindow.saveLevelOverrides`) with no further
            // conversion, so it has to already be raw/on-disk space.
            return (objectID, syntheticID, ModelViewerRenderer.mirroredWorldPosition(object.worldPosition), Self.eulerDegrees(from: object.rotation), object.pendingPathIDs)
        }
    }

    /// "Set AI Path on a Newly-Placed AI": the real `AIPath` IDs currently
    /// assigned to a session-placed object at `index`, or `nil` if `index`
    /// isn't a session-placed Instance at all (the marking menu's own
    /// `isEnabled` gate, see `GPULevelObject.pendingPathIDs`'s doc comment
    /// for why this is scoped to session-placed objects only).
    func pendingPathIDs(forObjectAt index: Int) -> [UInt16]? {
        guard objects.indices.contains(index), objects[index].newInstanceObjectID != nil else { return nil }
        return objects[index].pendingPathIDs
    }

    /// Sets which real `AIPath` IDs a session-placed object at `index`
    /// should reference, a no-op if `index` isn't a session-placed
    /// Instance (same guard as `pendingPathIDs(forObjectAt:)`).
    func setPendingPathIDs(_ ids: [UInt16], forObjectAt index: Int) {
        guard objects.indices.contains(index), objects[index].newInstanceObjectID != nil else { return }
        objects[index].pendingPathIDs = ids
    }

    /// "Interactive Scenery Placement": every scenery object placed this
    /// session, ready for `WorkspaceViewModel` to fold into one batch
    /// mutation of the level's `SceneryData` tree. Raw transform
    /// components, not pre-encoded bytes or a built `SceneryModelPlacement`
    ///, unlike every `pendingNew*` sibling above, a scenery placement
    /// isn't its own chunk-tree record `ChunkSectionInserter` can insert;
    /// it's one array element inside a single large, already-decoded tree,
    /// so the actual `SceneryModelPlacement` (bounding box included) has to
    /// be built where that tree is in scope, not here.
    ///
    /// `object.worldPosition` is passed through unmirrored, deliberately , 
    /// unlike `pendingNewInstances`/etc (which build their own raw matrix
    /// by hand and so need `mirroredWorldPosition` to convert world->raw
    /// themselves), `SceneryModelPlacement.composingModelMatrix` already
    /// *is* that world->raw conversion (see its own doc comment: the exact
    /// algebraic inverse of `worldTransform`, which decodes raw->world by
    /// negating X). Mirroring here too was a real bug caught by
    /// `ScenerPlacementArchiveRegressionTests
    /// .testInsertingNewSceneryThroughLiveViewportPlacementPathRoundTripsOnArchiveBrowsedLevel`
    /// against real `beach.sm2` data, double-negated X, so every
    /// live-placed scenery object would have saved mirrored to the wrong
    /// side of the level.
    /// `boundsMin`/`boundsMax`: real, reported bug, "phases in and out of
    /// reality" for placed scenery, plus placed objects vanishing entirely
    /// in-game. Every new `SceneryModelPlacement` used to get a hardcoded
    /// `position ± 1` unit placeholder box (`WorkspaceViewModel.
    /// patchedFileBytes`'s `insertingNewScenery` loop) regardless of the
    /// real model's actual size, any placed object bigger than ~2 units in
    /// any dimension shipped a bounding box far smaller than its own mesh.
    /// Real per-object bounds were already being computed for the
    /// *separate* ColData collision rebuild right here in this same
    /// renderer (`worldAABBCorners(of:)`, used by `rebuildLevelCollision`'s
    /// gathering loop), this thread the same real, rotated/scaled/
    /// translated world-space AABB through to the *scenery placement's own*
    /// bounding box too, instead of computing it twice with two different
    /// (one fake) answers.
    var pendingNewScenery: [(modelID: UInt32, isSpecial: Bool, position: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>)] {
        objects.compactMap { object in
            // Excludes a cross-level placement, its `newSceneryModelID`
            // is a source-file-scoped placeholder, meaningless as a
            // destination modelID; `pendingCrossLevelScenery` below
            // handles those, real geometry copy included.
            guard let modelID = object.newSceneryModelID, let isSpecial = object.newSceneryIsSpecial, object.pendingCrossLevelGeometrySource == nil else { return nil }
            let (boundsMin, boundsMax) = Self.symmetricLocalExtent(of: object)
            return (modelID, isSpecial, object.worldPosition, object.rotation, object.scale, boundsMin, boundsMax)
        }
    }

    /// "Live Cross-Level Scenery Placement": every scenery object placed
    /// this session whose real geometry still needs to be copied from
    /// another level into this destination file, the real, on-disk
    /// write for these needs a `CrossFileModelCopier.copyingRigidModelChain`
    /// call *and* a placement insert, both deferred to save time (see
    /// `CrossLevelSceneryGeometrySource`'s own doc comment for why).
    ///
    /// `object.worldPosition` is passed through unmirrored, same as
    /// `pendingNewScenery` right above and for the same reason , 
    /// `SceneryModelPlacement.composingModelMatrix` already *is* the
    /// world->raw conversion (it negates X itself), so mirroring here too
    /// would double-negate it.
    var pendingCrossLevelScenery: [(source: CrossLevelSceneryGeometrySource, position: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>)] {
        objects.compactMap { object in
            guard let source = object.pendingCrossLevelGeometrySource else { return nil }
            return (source, object.worldPosition, object.rotation, object.scale)
        }
    }

    /// "Cross-Level Forge Placement": every session-placed Instance whose
    /// real `GameObject` data still needs copying in at save time, see
    /// `CrossLevelGameObjectSource`'s own doc comment. Deduplicated by
    /// `objectID` (`Dictionary` keyed by it, values-only result): placing
    /// the *same* missing object more than once this session only needs
    /// its chain copied once, not once per placement.
    var pendingCrossLevelGameObjects: [CrossLevelGameObjectSource] {
        var byObjectID: [UInt16: CrossLevelGameObjectSource] = [:]
        for object in objects {
            guard let source = object.pendingCrossLevelGameObjectSource else { continue }
            byObjectID[source.objectID] = source
        }
        return Array(byObjectID.values)
    }

    /// "Spawn Interactive Cortex (Prop)": every session-placed prop-skin
    /// spawn whose synthetic `GameObject` still needs creating at save
    /// time, see `PropSkinSpawnSource`'s own doc comment. Deduplicated by
    /// `freshObjectID`, same reasoning as `pendingCrossLevelGameObjects`.
    var pendingPropSkinSpawns: [PropSkinSpawnSource] {
        var byFreshObjectID: [UInt16: PropSkinSpawnSource] = [:]
        for object in objects {
            guard let source = object.pendingPropSkinSpawnSource else { continue }
            byFreshObjectID[source.freshObjectID] = source
        }
        return Array(byFreshObjectID.values)
    }

    /// "AI Pathfinding & Navmesh Editor" (roadmap 5.1): the current
    /// position of every *existing, real* AI waypoint marker, re-encoded
    /// and paired with the `ChunkNode` it patches into, the waypoint
    /// counterpart to `pendingLevelOverrides`. `.aiWaypoints`-layer only,
    /// same reasoning as `pendingLevelOverrides`'s own `.actors`-only
    /// guard: applying an `AIPosition` encode to any other record type
    /// would corrupt it.
    var pendingAIWaypointOverrides: [(node: ChunkNode, encoded: Data)] {
        objects.compactMap { object in
            guard object.layer == .aiWaypoints, let node = object.sourceNode,
                  let rawNodeType = object.originalAIWaypointRawNodeType
            else { return nil }
            let rawPosition = ModelViewerRenderer.mirroredWorldPosition(object.worldPosition)
            let position = SIMD4(rawPosition.x, rawPosition.y, rawPosition.z, object.originalPositionW)
            let encoded = WorldPlacementWriter.writeAIPosition(position: position, rawNodeType: rawNodeType)
            return (node, encoded)
        }
    }

    /// "Spline & Camera Path Persistence" (roadmap 6.3): the current
    /// position of every real, on-disk Camera Path/Spline control point,
    /// paired with the owning Camera `ChunkNode` and the exact absolute
    /// file offset (`node.fileOffset + cameraControlPointFileOffset`) this
    /// one point's 16 bytes patch into, deliberately not keyed by
    /// `.cameras`-layer alone (that also matches each camera's own box
    /// marker, which has no `cameraControlPointFileOffset` and would
    /// otherwise get misencoded as a control point).
    var pendingCameraControlPointOverrides: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] {
        objects.compactMap { object in
            guard object.layer == .cameras, let node = object.sourceNode,
                  let relativeOffset = object.cameraControlPointFileOffset
            else { return nil }
            let rawPosition = ModelViewerRenderer.mirroredWorldPosition(object.worldPosition)
            let vector = SIMD4(rawPosition.x, rawPosition.y, rawPosition.z, object.originalPositionW)
            let encoded = WorldPlacementWriter.writeCameraControlPoint(vector)
            return (node, node.fileOffset + relativeOffset, encoded)
        }
    }

    /// "Move an Existing Scenery Placement, Save": the current transform
    /// of every real, on-disk scenery object, patched straight into its
    /// own 64-byte `modelMatrix` block via `sceneryMatrixFileOffset` +
    /// `sceneryFileNode.fileOffset`, same "always re-encode the live
    /// value" convention `pendingLevelOverrides`/
    /// `pendingCameraControlPointOverrides` already use (every real
    /// on-disk scenery object patches on every save, not just ones that
    /// actually moved; re-writing an unchanged transform is a harmless
    /// no-op). `SceneryModelPlacement.composingModelMatrix` already
    /// applies the same X-mirror `pendingNewScenery` relies on internally
    /// (see its own doc comment, "the exact algebraic inverse of
    /// `worldTransform`"), so `object.worldPosition` (the mirrored
    /// *display* value) goes in directly, no separate un-mirror step
    /// needed here. Empty when `sceneryFileNode` is `nil` (no real
    /// scenery file this session ever had to begin with).
    var pendingSceneryTransformOverrides: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] {
        guard let sceneryFileNode else { return [] }
        return objects.compactMap { object in
            guard object.layer == .scenery, let relativeOffset = object.sceneryMatrixFileOffset else { return nil }
            let matrix = SceneryModelPlacement.composingModelMatrix(position: object.worldPosition, rotation: object.rotation, scale: object.scale)
            let encoded = SceneryDataWriter.writeModelMatrix(matrix)
            return (sceneryFileNode, sceneryFileNode.fileOffset + relativeOffset, encoded)
        }
    }

    /// Every waypoint placed this session via `spawnAIWaypoint`, ready to
    /// hand to `WorkspaceViewModel.patchedFileBytes(applyingPrefixPatches:
    /// insertingNewAIPositions:levelNode:)`, the waypoint counterpart to
    /// `pendingNewInstances`.
    var pendingNewAIPositions: [(id: UInt32, encoded: Data)] {
        objects.compactMap { object in
            guard let rawNodeType = object.newAIWaypointRawNodeType, let syntheticID = object.syntheticAIPositionID else { return nil }
            let encoded = WorldPlacementWriter.writeAIPosition(position: SIMD4(ModelViewerRenderer.mirroredWorldPosition(object.worldPosition), 1), rawNodeType: rawNodeType)
            return (syntheticID, encoded)
        }
    }

    /// Adds a new `AIPathRecord` to this session (not written to disk
    /// until save), `args` defaults to a plausible-shaped record (a
    /// start/end waypoint pair of 0/1, matching whatever the reference
    /// tool's own `AIPathEditor` would show as the first two real
    /// `AIPosition` IDs in a level; the caller/UI is expected to let the
    /// user actually pick real waypoint IDs afterward via the same edit
    /// form `AIPathInspectorView` already has). `explicitID` lets undo's
    /// redo step re-add a path under its *original* synthetic ID rather
    /// than minting a new one, keeping undo/redo symmetric, see
    /// `LevelViewerWindow.registerAIPathAddUndo`.
    @discardableResult
    func addAIPath(args: [UInt16] = [0, 1, 0, 0, 0], explicitID: UInt32? = nil) -> UInt32 {
        let id = explicitID ?? nextSyntheticAIPathID
        if explicitID == nil { nextSyntheticAIPathID += 1 }
        newAIPaths.append((id, args))
        rebuildAIPathLineBuffer()
        return id
    }

    /// Removes an AI Path from this session's effective set, a
    /// session-added one (from `addAIPath`) is dropped outright; a real,
    /// on-disk one is marked removed (its bytes are dropped from the
    /// section at save time via `pendingRemovedAIPathIDs`). Either way,
    /// `id`'s original `args` aren't needed here to undo the removal
    /// (unlike a `GPULevelObject` delete, which snapshots position/
    /// rotation/scale), the caller already knows them, since AIPath has
    /// no live 3D state this renderer tracks independently.
    func removeAIPath(id: UInt32) {
        if let index = newAIPaths.firstIndex(where: { $0.id == id }) {
            newAIPaths.remove(at: index)
        } else {
            removedAIPathIDs.insert(id)
        }
        rebuildAIPathLineBuffer()
    }

    /// Undoes `removeAIPath(id:)` for a *real*, on-disk path (one that was
    /// never in `newAIPaths` to begin with), just un-marks it removed;
    /// the original record data still lives in the level's own file/
    /// context, this renderer never needed to snapshot it.
    func restoreAIPath(id: UInt32) {
        removedAIPathIDs.remove(id)
        rebuildAIPathLineBuffer()
    }

    /// Every `AIPathRecord` added this session, ready to hand to
    /// `WorkspaceViewModel.patchedFileBytes(insertingNewAIPaths:
    /// removingAIPathIDs:levelNode:)`, the AI-path counterpart to
    /// `pendingNewAIPositions`.
    var pendingNewAIPaths: [(id: UInt32, encoded: Data)] {
        newAIPaths.map { ($0.id, WorldPlacementWriter.writeAIPath($0.args)) }
    }
    var pendingRemovedAIPathIDs: [UInt32] { Array(removedAIPathIDs) }

    /// The real, current args for an AI Path this session, `liveAIPathArgs`
    /// (an existing, on-disk path) if it's been edited or just seeded at
    /// load; falls back to `newAIPaths` for a session-added one. `nil` only
    /// if `id` matches neither, a stale caller, not a real path.
    func currentAIPathArgs(id: UInt32) -> [UInt16]? {
        liveAIPathArgs[id] ?? newAIPaths.first { $0.id == id }?.args
    }

    /// Edits an *existing*, on-disk AI Path's args in place, the
    /// `AIPathRecord` counterpart to `setSelectedPosition`/`setPositions`
    /// for spatial types. No-ops for an `id` this renderer doesn't
    /// recognize as an existing path (use `settingNewAIPathArgs` for a
    /// session-added one instead, the two are stored differently, since
    /// only an existing path patches in place via `pendingAIPathArgOverrides`
    /// below).
    func settingAIPathArgs(id: UInt32, args: [UInt16]) {
        guard liveAIPathArgs[id] != nil else { return }
        liveAIPathArgs[id] = args
        rebuildAIPathLineBuffer()
    }

    /// Same as `settingAIPathArgs`, for a path still only in `newAIPaths`
    /// (not yet a real on-disk record), mutates its args in place rather
    /// than remove-then-re-add, so its position in the list (and any
    /// picked-endpoint UI mid-edit) doesn't jump around.
    func settingNewAIPathArgs(id: UInt32, args: [UInt16]) {
        guard let index = newAIPaths.firstIndex(where: { $0.id == id }) else { return }
        newAIPaths[index].args = args
        rebuildAIPathLineBuffer()
    }

    /// The current args for *every* existing AI Path, re-encoded and paired
    /// with the `ChunkNode` it patches into, the AIPath counterpart to
    /// `pendingLevelOverrides`/`pendingAIWaypointOverrides`. Same "every
    /// real record, not just edited ones" convention those two already use
    /// (`AIPathRecord` is a small fixed-size record, see
    /// `WorldPlacementParser.parseInstanceTemplate`'s sibling parser for
    /// the general shape, so re-writing an unchanged one is a harmless
    /// no-op patch, same reasoning `pendingLevelOverrides`'s own doc
    /// comment gives).
    var pendingAIPathArgOverrides: [(node: ChunkNode, encoded: Data)] {
        aiPaths.compactMap { node, path in
            guard let currentArgs = liveAIPathArgs[path.id] else { return nil }
            return (node, WorldPlacementWriter.writeAIPath(currentArgs))
        }
    }

    // MARK: - AI Path connector-line visualization

    private var aiPathLineBuffer: MTLBuffer?
    private var aiPathLineVertexCount = 0
    private static let aiPathLineColor = SIMD3<Float>(0.95, 0.6, 0.15)

    /// Every currently-loaded `.aiWaypoints`-layer object's real AIPosition
    /// ID (existing: `sourceNode.recordID`; session-added: `syntheticAIPositionID`)
    /// mapped to its *live* world position, reads straight off `objects`,
    /// the same source of truth `rebuildSelectionBuffer` already uses for a
    /// dragged object's current position, not the static `aiPositions`
    /// array `rebuildOverlayBuffer` bakes from (which doesn't track a
    /// drag, a real, pre-existing limitation of that separate overlay
    /// pass, not something this new buffer should inherit).
    private func liveAIWaypointPositionsByID() -> [UInt32: SIMD3<Float>] {
        var result: [UInt32: SIMD3<Float>] = [:]
        for object in objects where object.layer == .aiWaypoints {
            if let id = object.sourceNode?.recordID {
                result[id] = object.worldPosition
            } else if let id = object.syntheticAIPositionID {
                result[id] = object.worldPosition
            }
        }
        return result
    }

    /// Rebuilds the connecting-line buffer for every AI Path whose two
    /// waypoint args both currently resolve to a real, loaded AIPosition , 
    /// a path whose args don't resolve (an unconfirmed/broken reference,
    /// or one edited to point at a nonexistent ID) simply draws no line,
    /// same "don't fabricate a connection that isn't real" honesty
    /// `AIPathInspectorView`'s own "candidate, not confirmed" wording
    /// already commits to. Called after upload, after any AI waypoint
    /// drag, and after any AI Path add/remove/arg edit, see each call
    /// site for why.
    func rebuildAIPathLineBuffer() {
        // Real, reported performance bug: this is piggybacked onto every
        // one of `rebuildSelectionBuffer`'s 10+ call sites (see that
        // function's own doc comment), including every single mouse-move
        // tick of an unrelated scenery/instance drag, so a level with no
        // AI Path records at all (most non-hub levels) still paid a full
        // `liveAIWaypointPositionsByID()` scan of every loaded object on
        // every drag delta, purely to build an empty buffer it already had.
        // Bailing out before that scan when there's nothing to draw a line
        // for is exactly equivalent (an empty `aiPaths`/`newAIPaths` can
        // never produce a resolvable path either way).
        guard !aiPaths.isEmpty || !newAIPaths.isEmpty else {
            if aiPathLineBuffer != nil { aiPathLineBuffer = nil }
            aiPathLineVertexCount = 0
            return
        }
        let positionsByID = liveAIWaypointPositionsByID()
        var floats: [Float] = []
        func appendVertex(_ position: SIMD3<Float>) {
            floats.append(contentsOf: [position.x, position.y, position.z, Self.aiPathLineColor.x, Self.aiPathLineColor.y, Self.aiPathLineColor.z])
        }
        func appendPathIfResolvable(_ args: [UInt16]) {
            guard args.indices.contains(0), args.indices.contains(1),
                  let start = positionsByID[UInt32(args[0])], let end = positionsByID[UInt32(args[1])]
            else { return }
            appendVertex(start)
            appendVertex(end)
        }
        for (_, path) in aiPaths where !removedAIPathIDs.contains(path.id) {
            appendPathIfResolvable(liveAIPathArgs[path.id] ?? path.args)
        }
        for entry in newAIPaths {
            appendPathIfResolvable(entry.args)
        }
        guard !floats.isEmpty else {
            aiPathLineBuffer = nil
            aiPathLineVertexCount = 0
            return
        }
        aiPathLineVertexCount = floats.count / 6
        aiPathLineBuffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    /// Unprojects a screen point through the inverse view-projection at two
    /// depths (Metal NDC `z = 0`/near and `z = 1`/far, see `Frustum`'s own
    /// doc comment for why this build's near/far convention isn't the
    /// generic OpenGL one) to get a world-space ray, then intersects it
    /// with a horizontal plane at `planeY`. This is a deliberate
    /// simplification, a real "click on the ground" needs a ray/mesh hit
    /// test against the actual scenery geometry, which this build doesn't
    /// have collision data wired up for in the Level Viewer, not a claim
    /// that clicking always lands exactly on visible terrain. `nil` when
    /// the click is aimed away from the plane entirely (e.g. straight up).
    func worldPositionOnGroundPlane(at screenPoint: CGPoint, viewSize: CGSize, planeY: Float) -> SIMD3<Float>? {
        let viewProjection = currentViewProjection(viewSize: viewSize)
        let inverse = viewProjection.inverse
        let ndcX = Float(screenPoint.x / max(viewSize.width, 1)) * 2 - 1
        let ndcY = Float(screenPoint.y / max(viewSize.height, 1)) * 2 - 1

        func unproject(ndcZ: Float) -> SIMD3<Float>? {
            let clip = inverse * SIMD4<Float>(ndcX, ndcY, ndcZ, 1)
            guard abs(clip.w) > 0.0001 else { return nil }
            return SIMD3(clip.x, clip.y, clip.z) / clip.w
        }
        guard let nearPoint = unproject(ndcZ: 0), let farPoint = unproject(ndcZ: 1) else { return nil }
        let direction = farPoint - nearPoint
        guard abs(direction.y) > 0.0001 else { return nil }

        let t = (planeY - nearPoint.y) / direction.y
        guard t > 0 else { return nil }
        return nearPoint + direction * t
    }

    /// "The Forge Palette" + "Drop-to-Floor Placement": a `mouseDown` in
    /// placement mode (armed via `pendingPlacementObjectID`) first tries a
    /// real ray hit against the level's actual collision mesh, so a new
    /// object lands on the real walkable surface (a raised platform, not
    /// the ground below it), falling back to the flat ground-plane
    /// heuristic only when there's no collision data or the ray hits
    /// nothing, same "no per-object size data to do better" reasoning
    /// `expandBounds` already uses for scenery bounds. Either way, spawns
    /// the object there and disarms placement mode (one shot per palette
    /// click, matching how dragging one item from the Models Hub places
    /// exactly one object).
    @discardableResult
    func placeObject(at screenPoint: CGPoint, viewSize: CGSize) -> Int? {
        guard let objectID = pendingPlacementObjectID else { return nil }
        guard let worldPosition = worldPositionOnCollisionMesh(at: screenPoint, viewSize: viewSize)
            ?? worldPositionOnGroundPlane(at: screenPoint, viewSize: viewSize, planeY: boundsCenter.y)
        else { return nil }
        pendingPlacementObjectID = nil
        return spawnInstance(objectID: objectID, at: worldPosition)
    }

    /// Everything one armed Scenery-tab entry needs to actually spawn once
    /// the viewport is clicked, mirrors `pendingPlacementObjectID`'s own
    /// shape, just carrying the richer payload Scenery placement needs
    /// (there's no "resolve by ID" indirection for scenery the way
    /// `spawnInstance` has via `AssetResolver`; the caller's own
    /// already-resolved catalog entry is the only source of this data).
    struct PendingSceneryPlacement {
        let modelID: UInt32
        let isSpecial: Bool
        let asset: ResolvedModelAsset
        let crossLevelSource: CrossLevelSceneryGeometrySource?
    }

    /// "Scenery placement, arm-then-click", a real, reported request: the
    /// Scenery tab used to place its new copy immediately at the camera's
    /// own position the instant a thumbnail was clicked, unlike every other
    /// placeable type in this build (Forge Palette objects, Instance/
    /// Trigger/Camera "Add" buttons), which all arm-then-click. Set non-nil
    /// to arm placement mode, the next viewport click places it via
    /// `placeScenery(at:viewSize:)`, same real collision-mesh-first raycast
    /// `placeObject` already uses, `nil` to cancel without placing
    /// anything.
    var pendingPlacementScenery: PendingSceneryPlacement?

    @discardableResult
    func placeScenery(at screenPoint: CGPoint, viewSize: CGSize) -> Int? {
        guard let pending = pendingPlacementScenery else { return nil }
        guard let worldPosition = worldPositionOnCollisionMesh(at: screenPoint, viewSize: viewSize)
            ?? worldPositionOnGroundPlane(at: screenPoint, viewSize: viewSize, planeY: boundsCenter.y)
        else { return nil }
        pendingPlacementScenery = nil
        if let crossLevelSource = pending.crossLevelSource {
            return spawnCrossLevelScenery(source: crossLevelSource, asset: pending.asset, at: worldPosition)
        }
        return spawnScenery(modelID: pending.modelID, isSpecial: pending.isSpecial, asset: pending.asset, at: worldPosition)
    }

    /// "Spawn Interactive Cortex (Prop)", arm-then-click, same real,
    /// reported complaint `pendingPlacementScenery`'s own doc comment
    /// describes for the Scenery tab ("place immediately at the camera's
    /// own position" was never what any other placeable type in this
    /// build does): this used to spawn straight at `boundsCenter` with no
    /// say in where. Mirrors `PendingSceneryPlacement`'s own "richer
    /// payload than a plain ID" shape, `source`/`skinAsset` are exactly
    /// what `spawnInteractiveCortexProp` needs.
    struct PendingPropSkinPlacement {
        let source: PropSkinSpawnSource
        let skinAsset: ResolvedModelAsset
    }

    var pendingPlacementPropSkin: PendingPropSkinPlacement?

    @discardableResult
    func placePropSkin(at screenPoint: CGPoint, viewSize: CGSize) -> Int? {
        guard let pending = pendingPlacementPropSkin else { return nil }
        guard let worldPosition = worldPositionOnCollisionMesh(at: screenPoint, viewSize: viewSize)
            ?? worldPositionOnGroundPlane(at: screenPoint, viewSize: viewSize, planeY: boundsCenter.y)
        else { return nil }
        pendingPlacementPropSkin = nil
        return spawnInteractiveCortexProp(source: pending.source, skinAsset: pending.skinAsset, at: worldPosition)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// The exact camera math `draw(in:)` uses, factored out so the gizmo
    /// hit test and drag math (`gizmoAxis(at:viewSize:)`,
    /// `dragSelectedObject`) project between world and screen space with
    /// the identical matrix the current frame was actually drawn with , 
    /// any drift between the two would make the gizmo arrows visually not
    /// match where clicks/drags actually register.
    /// "F to Focus/Frame": the orbit look-at point is the selected object's
    /// position when there is one, falling back to the whole level's
    /// bounds center otherwise, selecting something re-centers the camera
    /// on it automatically, without needing a separate "frame selection"
    /// action. `boundsRadius`/`boundsCenter` themselves stay level-wide
    /// (they also drive the far clip plane and the gizmo's arm length), so
    /// this only changes *where the camera looks*, not the scene's overall
    /// scale.
    private var orbitTarget: SIMD3<Float> { selectedPosition ?? boundsCenter }

    /// Shared with the LOD screen-size cull in `encodeScene` below, so its
    /// pixel-threshold math always matches the FOV this frame was actually
    /// projected with rather than an independently-hardcoded copy.
    private static let fovYRadians: Float = .pi / 4

    private func currentViewProjection(viewSize: CGSize) -> simd_float4x4 {
        let aspect = Float(viewSize.width / max(viewSize.height, 1))
        if isTopDownMode {
            return topDownViewProjection(aspect: aspect)
        }
        let projection = ModelViewerRenderer.perspectiveMatrix(fovYRadians: Self.fovYRadians, aspect: aspect, near: 0.05, far: boundsRadius * 20 + 50)
        let view4x4: simd_float4x4
        if isFreeCameraMode {
            view4x4 = ModelViewerRenderer.lookAtMatrix(eye: freeCameraPosition, center: freeCameraPosition + freeCameraForward(), up: SIMD3<Float>(0, 1, 0))
        } else {
            view4x4 = ModelViewerRenderer.lookAtMatrix(eye: orbitEyeWorldPosition, center: orbitTarget, up: SIMD3<Float>(0, 1, 0))
        }
        return projection * view4x4
    }

    /// Straight-down orthographic "minimap" view. Deliberately does *not*
    /// reuse the orbit `lookAtMatrix` call with `pitch` snapped to `.pi/2`
    ///, at exactly straight-down, `eye - target` is parallel to the
    /// hardcoded `up = (0,1,0)` orbit uses, so `cross(up, z)` in
    /// `lookAtMatrix` collapses to zero and `normalize` produces NaNs (a
    /// blank/garbage viewport). Using an explicit `up = (0,0,-1)` (screen
    /// "up" faces world -Z) keeps `up` and the look direction perpendicular
    /// by construction. "Zoom" reuses `distanceMultiplier`, scrolling
    /// scales the orthographic half-extents the same lever that scales
    /// orbit distance, rather than moving the eye (which wouldn't change
    /// apparent size under an orthographic projection).
    private func topDownViewProjection(aspect: Float) -> simd_float4x4 {
        let target = orbitTarget
        let distance = max(boundsRadius * distanceMultiplier, 1)
        let eye = target + SIMD3<Float>(0, distance, 0)
        let view4x4 = ModelViewerRenderer.lookAtMatrix(eye: eye, center: target, up: SIMD3<Float>(0, 0, -1))
        let halfHeight = distance
        let halfWidth = halfHeight * aspect
        let projection = ModelViewerRenderer.orthographicMatrix(
            halfWidth: halfWidth,
            halfHeight: halfHeight,
            near: 0.05,
            far: distance + boundsRadius * 2 + 50
        )
        return projection * view4x4
    }

    /// Camera eye position for whichever mode is actually active, mirrors
    /// the same `isFreeCameraMode` branch `currentViewProjection` takes,
    /// factored out separately rather than widening that function's return
    /// type (11 call sites) since only the on-screen/offscreen draw paths
    /// need the eye position, for the LOD distance cull in `encodeScene`.
    private var currentCameraEyeWorldPosition: SIMD3<Float> {
        isFreeCameraMode ? freeCameraPosition : orbitEyeWorldPosition
    }

    private var orbitEyeWorldPosition: SIMD3<Float> {
        let distance = boundsRadius * distanceMultiplier
        let target = orbitTarget
        return SIMD3<Float>(
            target.x + distance * cos(pitch) * sin(yaw),
            target.y + distance * sin(pitch),
            target.z + distance * cos(pitch) * cos(yaw)
        )
    }

    /// "Active Chunk & Asset Preview Engine" (roadmap 7.1), the current
    /// camera's real world-space eye position: the orbit formula, or the
    /// free camera's own tracked position when that mode is active.
    /// Exposed so "Scene Preview Mode" can test it against real decoded
    /// Trigger volumes as a free-look "where is the camera standing"
    /// proxy, an honest simplification (this is a camera, not a
    /// first-person player controller/physics body) stated as such in the
    /// Level Viewer's own UI, not dressed up as gameplay.
    var cameraEyeWorldPosition: SIMD3<Float> {
        if isFreeCameraMode { return freeCameraPosition }
        if isTopDownMode { return orbitTarget + SIMD3<Float>(0, max(boundsRadius * distanceMultiplier, 1), 0) }
        return orbitEyeWorldPosition
    }

    /// "F to Focus/Frame", resets angle/distance to a sensible default;
    /// combined with `orbitTarget` above, pressing F while something's
    /// selected reads as "frame the selected object."
    func resetView() {
        yaw = .pi * 0.25
        pitch = .pi * 0.3
        distanceMultiplier = 1.4
    }

    /// "Double-Click to Focus": pulls the camera in to nicely frame
    /// whatever's currently selected. `orbitTarget` already re-centers on
    /// the selection for free (see its own doc comment), but
    /// `distanceMultiplier` alone doesn't get you *close*, it scales off
    /// the whole scene's `boundsRadius`, not the selected object's own
    /// size, so double-clicking a small crate in a huge level would
    /// otherwise leave the camera exactly as far away as before, just
    /// centered on a different point. This converts a desired absolute
    /// framing distance (proportional to the target's own
    /// `boundingRadius`) back into that same boundsRadius-relative unit,
    /// so the object actually fills the frame regardless of how big the
    /// rest of the level is. No-op with nothing selected.
    func focusOnSelected() {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex), boundsRadius > 0.0001 else { return }
        let desiredDistance = max(objects[selectedObjectIndex].boundingRadius * 3.5, 1.5)
        distanceMultiplier = desiredDistance / boundsRadius
    }

    // MARK: - Free Camera ("Free Camera System in Chunk Editor")

    /// A real, independent 6-DOF flying camera, distinct from the orbit
    /// camera above (`yaw`/`pitch`/`distanceMultiplier` orbit a fixed
    /// target; this one has its own world position and looks wherever
    /// it's pointed, with no target to orbit around). Off by default.
    /// Entering the mode starts from wherever the orbit camera currently
    /// is/looks, derived from the real orbit eye and look-at direction , 
    /// not reset to the origin, so toggling it on never jump-cuts the
    /// view.
    var isFreeCameraMode = false {
        didSet {
            guard isFreeCameraMode, !oldValue else { return }
            isTopDownMode = false
            let eye = orbitEyeWorldPosition
            freeCameraPosition = eye
            let lookDirection = simd_normalize(orbitTarget - eye)
            freeCameraPitch = asin(max(-1, min(1, lookDirection.y)))
            freeCameraYaw = atan2(lookDirection.x, lookDirection.z)
            freeCameraVelocity = .zero
        }
    }

    /// "Top-Down/Minimap", snaps to the orthographic straight-down view
    /// built by `topDownViewProjection`. Mutually exclusive with the free
    /// camera (each turns the other off); orbiting the normal perspective
    /// camera while this is on just doesn't apply, so `yaw`/`pitch` keep
    /// their last values underneath and are restored automatically when
    /// this is toggled back off.
    var isTopDownMode = false {
        didSet {
            guard isTopDownMode, !oldValue else { return }
            isFreeCameraMode = false
        }
    }
    private var freeCameraPosition: SIMD3<Float> = .zero
    private var freeCameraYaw: Float = 0
    private var freeCameraPitch: Float = 0
    /// Units/second, real "adjustable movement speed" (Scroll Wheel),
    /// clamped to a sane range by whatever adjusts it.
    var freeCameraSpeed: Float = 20
    /// Smoothed current velocity, world-space, accelerated toward the
    /// requested input direction and decayed back toward zero each frame
    /// in `updateFreeCameraMovement`, the "smooth velocity damping" the
    /// mandate asks for instead of an instant on/off snap.
    private var freeCameraVelocity: SIMD3<Float> = .zero
    /// Local-space (x = right/left from A/D, y = up/down from E/Q,
    /// z = forward/back from W/S) input vector, set from currently-held
    /// keys on every `keyDown`/`keyUp`, consumed once per frame in
    /// `draw(in:)` so movement is continuous and frame-rate independent,
    /// not one discrete step per keystroke.
    var freeCameraInputDirection: SIMD3<Float> = .zero
    private var lastFrameTimestamp: CFTimeInterval?

    private func freeCameraForward() -> SIMD3<Float> {
        SIMD3(cos(freeCameraPitch) * sin(freeCameraYaw), sin(freeCameraPitch), cos(freeCameraPitch) * cos(freeCameraYaw))
    }
    /// Real, reported bug ("the left and right movement arrows are
    /// inverted"): this used to compute `up × forward` instead of
    /// `forward × up`, confirmed backwards against this same file's own
    /// internally-consistent ground truth: top-down mode hardcodes
    /// `forward = (0,0,-1), right = (1,0,0)`, and `forward × up` for that
    /// exact `forward` gives `(1,0,0)`, matching it exactly; `up × forward`
    /// gives `(-1,0,0)`, the wrong sign, which is what this used to
    /// return.
    private func freeCameraRight() -> SIMD3<Float> {
        SIMD3(-cos(freeCameraYaw), 0, sin(freeCameraYaw))
    }

    /// See `GizmoInteractiveRenderer.cameraGroundForward`'s own doc
    /// comment. Top-down mode's screen orientation is fixed (`up =
    /// (0,0,-1)`, independent of `yaw`, see `topDownViewProjection`),
    /// so it gets its own fixed pair rather than trying to derive one
    /// from a camera that's looking straight down (no horizontal
    /// component to a purely-vertical look direction).
    func cameraGroundForward() -> SIMD3<Float> {
        if isTopDownMode { return SIMD3(0, 0, -1) }
        if isFreeCameraMode { return SIMD3(sin(freeCameraYaw), 0, cos(freeCameraYaw)) }
        // Orbit mode: `orbitEyeWorldPosition` places the eye *away* from
        // `orbitTarget` along `(sin(yaw), _, cos(yaw))` (scaled by
        // `distance * cos(pitch)`, always non-negative), the camera
        // looks the opposite way, back toward the target, so its own
        // forward is the negation of that same formula.
        return SIMD3(-sin(yaw), 0, -cos(yaw))
    }
    func cameraGroundRight() -> SIMD3<Float> {
        if isTopDownMode { return SIMD3(1, 0, 0) }
        if isFreeCameraMode { return freeCameraRight() }
        // Real, reported bug ("the left and right movement arrows are
        // inverted"), see `freeCameraRight`'s own doc comment for the
        // full derivation. At `yaw == 0`, this branch's own `forward`
        // (`cameraGroundForward`, just above) is exactly `(0,0,-1)` , 
        // identical to top-down mode's own hardcoded forward, so its
        // `right` at `yaw == 0` must match top-down's own hardcoded
        // `(1,0,0)` to be internally consistent. The old formula
        // (`(-cos(yaw), 0, sin(yaw))`) gave `(-1,0,0)` there instead , 
        // confirmed backwards.
        return SIMD3(cos(yaw), 0, -sin(yaw))
    }

    /// Right-click-drag look, real, continuous yaw/pitch, clamped so the
    /// camera can't flip past straight up/down.
    func rotateFreeCameraLook(yawDelta: Float, pitchDelta: Float) {
        freeCameraYaw += yawDelta
        freeCameraPitch = max(-1.5, min(1.5, freeCameraPitch + pitchDelta))
    }

    /// Integrates one frame of free-camera movement. No collision, the
    /// mandate explicitly asks for zero-collision flight, matching this
    /// build's real physics gap (there's no collision-response system to
    /// stop against anyway, so this isn't cutting a corner, it's the only
    /// honest behavior available).
    /// Internal (not `private`) so `@testable import` can drive this with
    /// an explicit, deterministic `deltaTime` instead of depending on
    /// real wall-clock timing through `draw(in:)`.
    func updateFreeCameraMovement(deltaTime: Float) {
        guard isFreeCameraMode else { return }
        let clampedDT = min(max(deltaTime, 0), 1.0 / 15.0) // guards a huge dt after a stall/pause
        let worldInputDirection = freeCameraRight() * freeCameraInputDirection.x
            + SIMD3<Float>(0, 1, 0) * freeCameraInputDirection.y
            + freeCameraForward() * freeCameraInputDirection.z
        let targetVelocity = (simd_length(worldInputDirection) > 0.0001 ? simd_normalize(worldInputDirection) : .zero) * freeCameraSpeed
        let accelerationRate: Float = 8.0
        freeCameraVelocity += (targetVelocity - freeCameraVelocity) * min(1, accelerationRate * clampedDT)
        freeCameraPosition += freeCameraVelocity * clampedDT
    }

    // TEMPORARY perf-diagnostic instrumentation, real, reported bug: the
    // Level Viewer is "borderline unusable... not responsive at all",
    // continuously, not just at load (already measured and fixed
    // separately, see `WorkspaceViewModel.openLevelViewer`). Tracks a
    // rolling window of real inter-frame gaps and CPU-side encode time so
    // the next session pins down whether frames are genuinely slow to
    // *build* (a render-loop cost) versus something else on the main
    // thread stealing time between frames (a SwiftUI/main-actor cost this
    // renderer has no visibility into). Printed every 5 frames (lowered
    // from an original 60, at severely degraded fps, 60 frames could take
    // 30+ seconds to accumulate, longer than a reasonable test window,
    // which is exactly why an earlier test round saw zero output at all).
    // ~3s at
    // target 20fps) rather than every frame, to avoid flooding stderr.
    // Remove once the dominant cost is identified and fixed.
    private var perfFrameCount = 0
    private var perfEncodeTimeAccumulated: Double = 0
    private var perfInterFrameTimeAccumulated: Double = 0
    private var perfWindowStart: CFAbsoluteTime?
    /// Objects the LOD screen-size cull (see `encodeScene`) skipped the
    /// draw call for, summed across the current perf-logging window , 
    /// surfaces the cull's actual effect in the existing `[LevelViewerPerf]`
    /// log line instead of being an invisible internal detail.
    private var perfLODCulledAccumulated: Int = 0

    func draw(in view: MTKView) {
        // Real elapsed time since the previous frame, free-camera speed
        // is expressed in units/second, so this has to be measured, not
        // assumed from `preferredFramesPerSecond` (which is a request to
        // the display link, not a guarantee).
        let now = CACurrentMediaTime()
        let deltaTime = lastFrameTimestamp.map { Float(now - $0) } ?? 0
        lastFrameTimestamp = now
        updateFreeCameraMovement(deltaTime: deltaTime)

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let wallNow = CFAbsoluteTimeGetCurrent()
        if let perfWindowStart {
            perfInterFrameTimeAccumulated += wallNow - perfWindowStart
        }
        perfWindowStart = wallNow

        let encodeStart = CFAbsoluteTimeGetCurrent()
        let viewProjection = currentViewProjection(viewSize: view.bounds.size)
        encodeScene(encoder: encoder, viewProjection: viewProjection, cameraEyeWorldPosition: currentCameraEyeWorldPosition, viewportHeightPixels: Float(view.drawableSize.height))
        perfEncodeTimeAccumulated += CFAbsoluteTimeGetCurrent() - encodeStart

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        perfFrameCount += 1
        if perfFrameCount >= 5 {
            let visibleCount = objects.filter { layerVisibility.contains($0.layer) }.count
            let avgEncodeMS = (perfEncodeTimeAccumulated / Double(perfFrameCount)) * 1000
            let avgInterFrameMS = (perfInterFrameTimeAccumulated / Double(max(perfFrameCount - 1, 1))) * 1000
            let effectiveFPS = avgInterFrameMS > 0 ? 1000.0 / avgInterFrameMS : 0
            let avgLODCulled = Double(perfLODCulledAccumulated) / Double(perfFrameCount)
            AppLog.rendering.debug("[LevelViewerPerf] draw(in:) over last \(self.perfFrameCount) frames, objects: \(self.objects.count) (\(visibleCount) visible, avg \(String(format: "%.1f", avgLODCulled)) LOD-culled/frame), avg encode: \(String(format: "%.2f", avgEncodeMS))ms, avg inter-frame gap: \(String(format: "%.2f", avgInterFrameMS))ms (effective \(String(format: "%.1f", effectiveFPS)) fps)")
            perfFrameCount = 0
            perfEncodeTimeAccumulated = 0
            perfInterFrameTimeAccumulated = 0
            perfLODCulledAccumulated = 0
        }
    }

    /// Renders one frame of the level to an offscreen texture and reads it
    /// back as a `CGImage`, the `LevelViewerRenderer` counterpart to
    /// `ModelViewerRenderer.renderOffscreen`, added so the real rendering
    /// pipeline (same `worldTransform`/mesh/material code the interactive
    /// app uses) can be inspected from outside an on-screen window, e.g.
    /// while debugging a specific level's geometry without driving the
    /// full interactive app.
    func renderOffscreen(width: Int, height: Int) -> CGImage? {
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared
        guard let colorTexture = device.makeTexture(descriptor: colorDescriptor) else { return nil }

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthDescriptor) else { return nil }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = colorTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.07, 0.07, 0.09, 1)
        passDescriptor.depthAttachment.texture = depthTexture
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .dontCare
        passDescriptor.depthAttachment.clearDepth = 1.0

        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return nil }

        let viewProjection = currentViewProjection(viewSize: CGSize(width: width, height: height))
        encodeScene(encoder: encoder, viewProjection: viewProjection, cameraEyeWorldPosition: currentCameraEyeWorldPosition, viewportHeightPixels: Float(height))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixelBytes = [UInt8](repeating: 0, count: width * height * 4)
        pixelBytes.withUnsafeMutableBytes { ptr in
            colorTexture.getBytes(ptr.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        // Same fix as `ModelViewerRenderer.renderOffscreen`'s identical
        // code, see its own doc comment: `CGImage` can consume the
        // `.bgra8Unorm` texture's bytes directly via `.byteOrder32Little` +
        // `.premultipliedFirst`, no scalar per-pixel B<->R swap loop needed.
        guard let providerRef = CGDataProvider(data: Data(pixelBytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
            provider: providerRef, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Below this projected screen-space diameter (in physical pixels), an
    /// object's draw call is skipped by the LOD cull in `encodeScene`, see
    /// that cull site's own comment. Deliberately tiny: this only ever
    /// discards genuinely sub-pixel detail, never anything a person could
    /// actually tell apart from being drawn.
    private static let lodMinPixelDiameter: Float = 2.0

    /// Shared by `draw(in:)` and `renderOffscreen(width:height:)`, every
    /// pass this renderer draws, factored out so an offscreen render is
    /// pixel-for-pixel the same pipeline the interactive view uses, not a
    /// parallel reimplementation that could drift from it.
    private func encodeScene(encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4, cameraEyeWorldPosition: SIMD3<Float>, viewportHeightPixels: Float) {
        let lightDirection = normalize(SIMD3<Float>(-0.4, -1.0, -0.3))

        encoder.setRenderPipelineState(context.pipelineState)
        encoder.setDepthStencilState(context.depthState)
        encoder.setFragmentSamplerState(context.samplerState, index: 0)
        // "Cull Back Faces" (opt-in, off by default), see `cullBackFaces`'s
        // own doc comment. Explicit either way rather than relying on the
        // encoder's default (`.none`, matching this viewer's long-standing
        // behavior) so this pass's cull state never depends on whatever an
        // earlier pass in the same frame happened to leave set.
        encoder.setCullMode(cullBackFaces ? .back : .none)
        // Real, reported bug ("scenery I've placed/moved disappears
        // depending on camera angle, while it's still centered in view, but
        // only for objects I've touched, untouched original scenery never
        // does this"): a placed or moved object commonly lands sitting
        // exactly (or almost exactly) coplanar with the level's own ground/
        // collision-fill mesh, drawn in a separate pass below at its own
        // true depth. Two coplanar surfaces are the textbook cause of
        // angle-dependent depth-test flicker, which one "wins" at a given
        // pixel becomes a coin flip that depends on floating-point rounding
        // in the depth interpolation, which itself depends on view angle;
        // original, disc-authored scenery placements apparently already
        // carry small enough real position differences from the ground to
        // avoid this, but nothing this app computes for a fresh placement
        // or a drag currently guarantees that gap. A small constant+slope-
        // scaled depth bias, pushing every regular object's fragments
        // very slightly toward the camera in depth-buffer terms only,
        // never touching its actual world position/what gets saved to
        // disk, is the standard fix for exactly this class of artifact.
        // Reset back to zero before the ground/collision-fill pass below
        // (and every other pass after it) so the bias doesn't leak into
        // passes it was never meant to affect.
        encoder.setDepthBias(-2, slopeScale: -2, clamp: -1.0 / 4096)

        // "Seamless Full-Map Rendering" (Part 1): one frustum per frame,
        // reused for every object's cull test below, a massive level can
        // have hundreds of scenery/actor placements, and skipping the
        // uniform upload + draw call entirely for whatever's behind the
        // camera or well outside the view cone is the direct lever for
        // flying a free-cam around it without dropping frames.
        let frustum = ModelViewerRenderer.Frustum(viewProjection: viewProjection)

        // Performance fix (audit): many scenery placements in the same
        // level reuse the exact same uploaded mesh/texture (e.g. a
        // repeated prop), and even within one multi-submesh object,
        // consecutive submeshes often share a texture atlas, re-binding
        // an unchanged vertex buffer or texture to the encoder is pure
        // redundant state-setting the GPU driver has to re-validate for
        // no behavioral difference. Tracked by identity (`===`) across the
        // whole loop below, not reset per-object, since the win applies
        // equally whether the repeat is within one object's submeshes or
        // across two consecutive objects that happen to share an asset.
        var lastBoundVertexBuffer: MTLBuffer?
        var lastBoundTexture: MTLTexture?

        // Performance fix (audit, "no LOD system" finding): a large open
        // level can place hundreds of scenery/actor objects, and every one
        // used to get a full vertex-buffer bind + draw call regardless of
        // how far away it was, even an object so distant it projects to a
        // fraction of a screen pixel. This does NOT remove anything from
        // the level's actual data: `objects`, the inspector list, and
        // selection/editing all see every object exactly as before, this
        // only skips the *draw call this frame* for an object whose
        // on-screen footprint is smaller than `lodMinPixelDiameter`, the
        // same kind of decision the frustum cull just above already makes
        // for objects that aren't on screen at all. Disabled in Top-Down
        // mode: that projection is orthographic (no perspective
        // foreshortening, so the angular-size math below doesn't apply)
        // and is deliberately a "see everything at once" overview.
        let lodAngularSizeCutoff: Float = isTopDownMode || viewportHeightPixels <= 0
            ? -1 // negative angular size never triggers the cull below
            : Self.lodMinPixelDiameter * tan(Self.fovYRadians / 2) / viewportHeightPixels
        var lodCulledCount = 0

        // Performance fix (audit, "no draw-call batching" finding): a level
        // typically places many copies of the same handful of scenery
        // meshes (crates, foliage, rocks, ...) scattered around the map in
        // arbitrary placement order, so drawing `objects` in their natural
        // order mostly defeats the redundant-state-bind skip above, two
        // objects sharing a mesh/texture are rarely adjacent in the draw
        // sequence. True GPU instancing (one draw call for every copy of a
        // mesh via a per-instance transform buffer) would need a new
        // vertex-shader contract across every pipeline this renderer uses
        //, out of scope for a bind-skipping fix. Sorting the objects that
        // survive frustum/LOD culling by their first submesh's vertex-
        // buffer identity gets most of the same win without touching the
        // shaders: same-mesh objects become consecutive draws, so the
        // `lastBoundVertexBuffer`/`lastBoundTexture` skip above actually
        // fires for them instead of only ever matching by coincidence.
        // Purely a draw-*order* change, `objects` itself, and everything
        // that indexes into it (picking, selection, the inspector list),
        // is untouched.
        struct SortableVisibleObject {
            let sortKey: ObjectIdentifier?
            let object: GPULevelObject
        }
        var visibleObjects: [SortableVisibleObject] = []
        visibleObjects.reserveCapacity(objects.count)

        for object in objects where layerVisibility.contains(object.layer) {
            let maxScale = max(object.scale.x, max(object.scale.y, object.scale.z))
            guard frustum.intersects(center: object.worldPosition, radius: object.boundingRadius * maxScale) else { continue }
            if lodAngularSizeCutoff >= 0 {
                let distance = simd_length(object.worldPosition - cameraEyeWorldPosition)
                let objectRadius = object.boundingRadius * maxScale
                if distance > 0, objectRadius < lodAngularSizeCutoff * distance {
                    lodCulledCount += 1
                    continue
                }
            }
            let sortKey = object.submeshes.first.map { ObjectIdentifier($0.vertexBuffer) }
            visibleObjects.append(SortableVisibleObject(sortKey: sortKey, object: object))
        }

        visibleObjects.sort { lhs, rhs in
            switch (lhs.sortKey, rhs.sortKey) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (l?, r?): return l < r
            }
        }

        for entry in visibleObjects {
            let object = entry.object
            // T * R * S: scale and rotate the local mesh first, then place
            // the result at the object's world position, the standard
            // TRS composition order (reversed relative to how it reads
            // left-to-right, since these matrices apply right-to-left).
            let model = simd_float4x4(translation: object.worldPosition)
                * simd_float4x4(object.rotation)
                * simd_float4x4(diagonal: SIMD4(object.scale.x, object.scale.y, object.scale.z, 1))
            // `uniforms` is identical for every submesh of this object (same
            // model/view/projection, same light), hoisted out of the
            // per-submesh loop below instead of re-uploaded via
            // `setVertexBytes`/`setFragmentBytes` on every single submesh,
            // which was pure redundant state-setting overhead for any
            // multi-submesh object (real, measured concern at "thousands of
            // submeshes" scale for a hub-sized level).
            var uniforms = Uniforms(modelViewProjection: viewProjection * model, modelMatrix: model, lightDirection: lightDirection)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            for submesh in object.submeshes {
                if lastBoundVertexBuffer !== submesh.vertexBuffer {
                    encoder.setVertexBuffer(submesh.vertexBuffer, offset: 0, index: 0)
                    lastBoundVertexBuffer = submesh.vertexBuffer
                }
                if lastBoundTexture !== submesh.texture {
                    encoder.setFragmentTexture(submesh.texture, index: 0)
                    lastBoundTexture = submesh.texture
                }
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: submesh.indexCount, indexType: .uint32, indexBuffer: submesh.indexBuffer, indexBufferOffset: 0)
            }
        }
        perfLODCulledAccumulated += lodCulledCount

        // Performance fix (audit): the collision-fill pass and the colored-
        // line pass just below it each used to build and upload their own,
        // separately-constructed `Uniforms`, but both are the exact same
        // value (this frame's `viewProjection`, an identity model matrix,
        // the one shared light direction). Computed and bound once, here,
        // unconditionally (so it's correctly set regardless of which of
        // the two independently-gated blocks below actually runs), Metal
        // doesn't invalidate a bound vertex-bytes buffer just because
        // `setRenderPipelineState` changes to a different pipeline, so one
        // bind at index 1 serves both passes.
        var identityUniforms = Uniforms(modelViewProjection: viewProjection, modelMatrix: matrix_identity_float4x4, lightDirection: lightDirection)
        encoder.setVertexBytes(&identityUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

        // "Collision / Ground Floor": the level's real, solid ground , 
        // drawn as part of the opaque pass (own pipeline/depth state, cull
        // off since the real triangle winding isn't independently
        // confirmed, same posture the chunk-wall fill below already takes)
        // so it correctly occludes/is occluded by everything else in the
        // scene, not layered on afterward like the translucent overlays.
        // Depth bias is dynamic encoder state, not tied to the pipeline
        // object, it doesn't reset itself just because `setRenderPipelineState`
        // switches below, so every pass from here on (the real ground the
        // object bias above exists to correctly lose to, plus every
        // wireframe/overlay pass after it) explicitly goes back to zero.
        encoder.setDepthBias(0, slopeScale: 0, clamp: 0)

        if layerVisibility.contains(.collision), let fillPipeline = context.collisionFillPipelineState, let collisionFillBuffer, collisionFillVertexCount > 0 {
            encoder.setRenderPipelineState(fillPipeline)
            encoder.setDepthStencilState(context.depthState)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(collisionFillBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: collisionFillVertexCount)
        }

        if let coloredPipeline = context.collisionLineColoredPipelineState {
            encoder.setRenderPipelineState(coloredPipeline)
            // "Level Editor Overhaul": trigger/camera wireframes, same line
            // pipeline and vertex layout as the gizmo below, both are
            // interleaved position+color buffers, so they share one setup.
            if let overlayLineBuffer {
                encoder.setVertexBuffer(overlayLineBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: overlayLineVertexCount)
            }
            if let gizmoBuffer {
                encoder.setVertexBuffer(gizmoBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gizmoVertexCount)
            }
            // "Cross-Engine Chunk Stitcher" (roadmap 5.3).
            if layerVisibility.contains(.crossEngine), let crossEngineLineBuffer, crossEngineLineVertexCount > 0 {
                encoder.setVertexBuffer(crossEngineLineBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: crossEngineLineVertexCount)
            }
            // "AI Path Connector Visualization": gated on `.aiWaypoints`
            // same as the waypoint markers themselves, a line to a marker
            // that's currently hidden would read as a rendering bug, not a
            // deliberate choice.
            if layerVisibility.contains(.aiWaypoints), let aiPathLineBuffer, aiPathLineVertexCount > 0 {
                encoder.setVertexBuffer(aiPathLineBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: aiPathLineVertexCount)
            }
            // "Hover highlight" (Level Editor overhaul, Phase 3).
            if let hoverLineBuffer, hoverLineVertexCount > 0 {
                encoder.setVertexBuffer(hoverLineBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: hoverLineVertexCount)
            }
            // "Selection outline": drawn every frame the selection is
            // non-nil, independent of the gizmo, see
            // `rebuildSelectionBuffer`'s doc comment.
            if let selectionLineBuffer, selectionLineVertexCount > 0 {
                encoder.setVertexBuffer(selectionLineBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: selectionLineVertexCount)
            }
        }

        // "Chunk-Based Architecture" (Part 2): the translucent boundary-
        // wall fill, drawn last (after opaque geometry and wireframes) with
        // depth write disabled so it doesn't corrupt the depth buffer for
        // anything drawn after it, and with culling off since the real
        // corner winding of a decoded `loadWall` quad isn't independently
        // confirmed.
        if let translucentPipeline = context.translucentQuadPipelineState, let chunkWallTriangleBuffer, chunkWallTriangleVertexCount > 0 {
            var uniforms = Uniforms(modelViewProjection: viewProjection, modelMatrix: matrix_identity_float4x4, lightDirection: lightDirection)
            encoder.setRenderPipelineState(translucentPipeline)
            encoder.setDepthStencilState(context.translucentDepthState)
            encoder.setCullMode(.none)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setVertexBuffer(chunkWallTriangleBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: chunkWallTriangleVertexCount)
        }
    }

    // MARK: - Gizmo geometry, hit-testing, and dragging (blueprint 6.1)

    private var gizmoVertexCount = 0

    /// Builds the gizmo's line geometry, one shaft plus a small two-line
    /// arrowhead per axis, as an interleaved position+color buffer
    /// (`vertex_line_colored`'s `LineVertexColorIn` layout, the same one
    /// `ModelViewerRenderer`'s by-surface-ID collision wireframe uses).
    /// Rebuilt only on selection change or an actual position edit, not
    /// per-frame, same caching rationale as `ModelViewerRenderer`'s own
    /// line buffers.
    private func rebuildGizmoBuffer() {
        // Triggers/cameras are select-and-inspect only, no gizmo, since
        // this build has no verified byte-exact encoder for either record
        // type (see `pendingLevelOverrides`'s guard). Showing a draggable
        // gizmo on one anyway would let it *look* editable while any drag
        // silently vanishes on save.
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex),
              objects[selectedObjectIndex].layer == .scenery || objects[selectedObjectIndex].layer == .actors
        else {
            gizmoBuffer = nil
            gizmoVertexCount = 0
            return
        }
        let origin = objects[selectedObjectIndex].worldPosition
        let armLength = gizmoArmLength

        var floats: [Float] = []
        func appendVertex(_ position: SIMD3<Float>, _ color: SIMD3<Float>) {
            floats.append(contentsOf: [position.x, position.y, position.z, color.x, color.y, color.z])
        }

        switch gizmoMode {
        case .translate, .scale:
            // Scale mode reuses the exact same arrow geometry as
            // translate, a real cube/box tip to distinguish them
            // visually is more line-pipeline complexity than the
            // distinction is worth; the sidebar's mode picker (and the
            // fields it drives) already make it unambiguous which one is
            // active.
            let headSize = armLength * 0.18
            for axis in GizmoAxis.allCases {
                let tip = origin + axis.unitVector * armLength
                appendVertex(origin, axis.color)
                appendVertex(tip, axis.color)

                // A tiny 2-line "V" arrowhead, angled back from the tip
                // along one other axis, enough to read as a direction
                // marker without needing a real cone mesh in a line-only
                // pipeline.
                let others = GizmoAxis.allCases.filter { $0.unitVector != axis.unitVector }
                for other in others.prefix(1) {
                    let back = tip - axis.unitVector * headSize
                    appendVertex(tip, axis.color)
                    appendVertex(back + other.unitVector * headSize, axis.color)
                    appendVertex(tip, axis.color)
                    appendVertex(back - other.unitVector * headSize, axis.color)
                }
            }

        case .rotate:
            // Three rings, one per axis, each drawn flat in that axis's
            // own perpendicular plane (see `GizmoAxis.planeBasis`) , 
            // approximated as `ringSegments` short line segments rather
            // than a real curved primitive, same "good enough for a line
            // pipeline" approach as the arrowheads above.
            let ringSegments = Self.gizmoRingSegments
            for axis in GizmoAxis.allCases {
                let (u, v) = axis.planeBasis
                for i in 0..<ringSegments {
                    let theta0 = Float(i) / Float(ringSegments) * 2 * .pi
                    let theta1 = Float(i + 1) / Float(ringSegments) * 2 * .pi
                    let p0 = origin + armLength * (cos(theta0) * u + sin(theta0) * v)
                    let p1 = origin + armLength * (cos(theta1) * u + sin(theta1) * v)
                    appendVertex(p0, axis.color)
                    appendVertex(p1, axis.color)
                }
            }
        }

        gizmoVertexCount = floats.count / 6
        gizmoBuffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    private static let gizmoRingSegments = 48

    private static func project(_ worldPosition: SIMD3<Float>, viewProjection: simd_float4x4, viewSize: CGSize) -> CGPoint? {
        let clip = viewProjection * SIMD4<Float>(worldPosition, 1)
        guard clip.w > 0.0001 else { return nil }
        let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
        // NDC is x-right/y-up in Metal, same handedness as an *unflipped*
        // AppKit view's own point space (origin bottom-left, y up), no
        // flip needed to go from one to the other, unlike a flipped view or
        // a top-left-origin UI coordinate system.
        return CGPoint(x: (Double(ndc.x) * 0.5 + 0.5) * viewSize.width, y: (Double(ndc.y) * 0.5 + 0.5) * viewSize.height)
    }

    private static func distance(from point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0.0001 else {
            return hypot(point.x - a.x, point.y - a.y)
        }
        let t = max(0, min(1, ((point.x - a.x) * abx + (point.y - a.y) * aby) / lengthSquared))
        let projX = a.x + t * abx, projY = a.y + t * aby
        return hypot(point.x - projX, point.y - projY)
    }

    /// `viewSize` is the `NSView.bounds.size` of whatever's calling this
    /// (points, not backing pixels), deliberately the same unit as
    /// `NSEvent`'s own coordinates, so no Retina-scale conversion is needed
    /// anywhere in this hit test.
    func gizmoAxis(at point: CGPoint, viewSize: CGSize) -> GizmoAxis? {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return nil }
        let origin = objects[selectedObjectIndex].worldPosition
        let viewProjection = currentViewProjection(viewSize: viewSize)

        switch gizmoMode {
        case .translate, .scale:
            guard let originScreen = Self.project(origin, viewProjection: viewProjection, viewSize: viewSize) else { return nil }
            var best: (axis: GizmoAxis, distance: CGFloat)?
            for axis in GizmoAxis.allCases {
                let tip = origin + axis.unitVector * gizmoArmLength
                guard let tipScreen = Self.project(tip, viewProjection: viewProjection, viewSize: viewSize) else { continue }
                let d = Self.distance(from: point, toSegmentFrom: originScreen, to: tipScreen)
                // "Easier to click" (QoL): widened from 14pt, a thin 3D
                // arrow is a genuinely small target, and this is a pure
                // hit-test tolerance with no visual change, so widening it
                // doesn't make the gizmo look different, just more forgiving.
                if d < 22, (best == nil || d < best!.distance) {
                    best = (axis, d)
                }
            }
            return best?.axis

        case .rotate:
            var best: (axis: GizmoAxis, distance: CGFloat)?
            for axis in GizmoAxis.allCases {
                let (u, v) = axis.planeBasis
                var previousScreen: CGPoint?
                for i in 0...Self.gizmoRingSegments {
                    let theta = Float(i) / Float(Self.gizmoRingSegments) * 2 * .pi
                    let p = origin + gizmoArmLength * (cos(theta) * u + sin(theta) * v)
                    guard let screen = Self.project(p, viewProjection: viewProjection, viewSize: viewSize) else {
                        previousScreen = nil
                        continue
                    }
                    if let previousScreen {
                        let d = Self.distance(from: point, toSegmentFrom: previousScreen, to: screen)
                        // "Easier to click" (QoL): widened from 10pt, see
                        // the matching comment on the translate/scale case.
                        if d < 16, (best == nil || d < best!.distance) {
                            best = (axis, d)
                        }
                    }
                    previousScreen = screen
                }
            }
            return best?.axis
        }
    }

    /// "Click any rendered element to select it" (Level Editor overhaul):
    /// see `GizmoInteractiveRenderer.pickObject`'s doc comment for the
    /// technique. Only considers objects on a currently-visible layer, so a
    /// hidden trigger/camera/actor can't be selected by clicking through
    /// where it used to be.
    func pickObject(at point: CGPoint, viewSize: CGSize) -> Int? {
        let viewProjection = currentViewProjection(viewSize: viewSize)
        var best: (index: Int, distance: CGFloat)?
        for (index, object) in objects.enumerated() where layerVisibility.contains(object.layer) {
            guard let screen = Self.project(object.worldPosition, viewProjection: viewProjection, viewSize: viewSize) else { continue }
            let d = hypot(point.x - screen.x, point.y - screen.y)
            if d < 22, (best == nil || d < best!.distance) {
                best = (index, d)
            }
        }
        return best?.index
    }

    /// "AI Path Connector Visualization + In-Viewport Endpoint Picking":
    /// when `pendingAIPathEndpointPick` is armed, `InteractiveMTKView.mouseDown`
    /// calls this instead of `pickObject`, identical closest-projected-
    /// point test, restricted to `.aiWaypoints`-layer objects, returning
    /// the clicked waypoint's real AIPosition ID (what an `AIPath`'s own
    /// `args[0]`/`args[1]` actually reference) rather than an `objects`
    /// index, since the caller needs the ID to write into a path's args,
    /// not a renderer-internal array position.
    var pendingAIPathEndpointPick = false

    /// Resolves a candidate AIPosition ID (an AI Path's `args[0]`/`args[1]`)
    /// against every currently-loaded `.aiWaypoints` object, for UI display
    ///, `nil` means honestly "doesn't resolve to anything real right now,"
    /// same "candidate, not confirmed" posture as `AIPathInspectorView`'s
    /// own wording.
    func aiWaypointDisplayName(id: UInt32) -> String? {
        objects.first { object in
            object.layer == .aiWaypoints && (object.sourceNode?.recordID == id || object.syntheticAIPositionID == id)
        }?.displayName
    }

    @discardableResult
    func pickAIPathEndpoint(at point: CGPoint, viewSize: CGSize) -> UInt32? {
        let viewProjection = currentViewProjection(viewSize: viewSize)
        var best: (id: UInt32, distance: CGFloat)?
        for object in objects where object.layer == .aiWaypoints {
            guard let id = object.sourceNode?.recordID ?? object.syntheticAIPositionID,
                  let screen = Self.project(object.worldPosition, viewProjection: viewProjection, viewSize: viewSize)
            else { continue }
            let d = hypot(point.x - screen.x, point.y - screen.y)
            if d < 22, (best == nil || d < best!.distance) {
                best = (id, d)
            }
        }
        return best?.id
    }

    /// "Hover highlight" (Level Editor overhaul, Phase 3): identical
    /// closest-projected-point test to `pickObject`, called from
    /// `mouseMoved` on every cursor move rather than from `mouseDown` , 
    /// updates `hoveredObjectIndex` (which rebuilds the outline buffer via
    /// its own `didSet`) instead of changing selection.
    @discardableResult
    func hoverObject(at point: CGPoint, viewSize: CGSize) -> Int? {
        let viewProjection = currentViewProjection(viewSize: viewSize)
        var best: (index: Int, distance: CGFloat)?
        for (index, object) in objects.enumerated() where layerVisibility.contains(object.layer) {
            guard let screen = Self.project(object.worldPosition, viewProjection: viewProjection, viewSize: viewSize) else { continue }
            let d = hypot(point.x - screen.x, point.y - screen.y)
            if d < 22, (best == nil || d < best!.distance) {
                best = (index, d)
            }
        }
        hoveredObjectIndex = best?.index
        return hoveredObjectIndex
    }

    /// Rebuilds `hoverLineBuffer`, a single axis-aligned wireframe box
    /// sized from the hovered object's `boundingRadius` (a sphere radius,
    /// not an oriented extent, so unlike `rebuildOverlayBuffer`'s
    /// trigger/camera boxes this one doesn't rotate with the object;
    /// adequate for "something is here," which is all a hover cue needs
    /// to convey). Cleared entirely when nothing's hovered, or when the
    /// hovered object is already the selection (already has a gizmo , 
    /// drawing both would be redundant).
    private func rebuildHoverBuffer() {
        guard let hoveredObjectIndex, objects.indices.contains(hoveredObjectIndex), hoveredObjectIndex != selectedObjectIndex else {
            hoverLineBuffer = nil
            hoverLineVertexCount = 0
            return
        }
        let object = objects[hoveredObjectIndex]
        let hoverColor = SIMD3<Float>(0.95, 0.95, 0.95)
        let half = SIMD3<Float>(repeating: max(object.boundingRadius, 0.15))
        var floats: [Float] = []
        func appendVertex(_ position: SIMD3<Float>, _ color: SIMD3<Float>) {
            floats.append(contentsOf: [position.x, position.y, position.z, color.x, color.y, color.z])
        }
        let localCorners: [SIMD3<Float>] = [
            SIMD3(-half.x, -half.y, -half.z), SIMD3(half.x, -half.y, -half.z),
            SIMD3(half.x, half.y, -half.z), SIMD3(-half.x, half.y, -half.z),
            SIMD3(-half.x, -half.y, half.z), SIMD3(half.x, -half.y, half.z),
            SIMD3(half.x, half.y, half.z), SIMD3(-half.x, half.y, half.z)
        ]
        let corners = localCorners.map { object.worldPosition + $0 }
        let edges: [(Int, Int)] = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7)
        ]
        for (a, b) in edges {
            appendVertex(corners[a], hoverColor)
            appendVertex(corners[b], hoverColor)
        }
        hoverLineVertexCount = floats.count / 6
        hoverLineBuffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    /// Rebuilds `selectionLineBuffer`, same axis-aligned wireframe-box
    /// shape as `rebuildHoverBuffer`, around `selectedObjectIndex` instead
    /// of `hoveredObjectIndex`, in `selectionOutlineColor`. Called from
    /// `select(index:)` and every direct transform setter (`setSelected
    /// Position`/`nudgeSelectedPosition`/`setSelectedRotation`/
    /// `setSelectedScale`), same call sites that already call
    /// `rebuildGizmoBuffer()`, so the outline tracks the selection exactly
    /// as tightly as the gizmo does.
    private func rebuildSelectionBuffer() {
        // Piggybacked here rather than added to each of this function's
        // 10+ call sites individually, every drag-delta tick (and every
        // direct transform setter) already calls this, so an AI Waypoint
        // drag's connecting lines stay live without needing its own
        // parallel set of call sites to keep in sync. Runs even when
        // nothing is selected (before the early-return below) since a
        // path's lines still need to reflect whatever just got deselected.
        //
        // Performance fix ("Chunk Viewer extremely laggy" during any
        // object drag, real, reported regression): `rebuildAIPathLineBuffer()`
        // used to run *unconditionally* right here, on every single call
        // site of this function, including every mouse-move tick of an
        // entirely unrelated scenery/instance/trigger/camera drag, not
        // just an actual AI Waypoint one. Dragging is single-selection
        // (only `objects[selectedObjectIndex]` ever moves during one
        // drag), and AI path connector lines only depend on
        // `.aiWaypoints`-layer object positions (`liveAIWaypointPositionsByID`)
        //, so a drag of anything else can never change what that buffer
        // should contain. `rebuildAIPathLineBuffer` itself does a full
        // `objects` scan plus a fresh `device.makeBuffer` call every time
        // it actually runs (see its own doc comment), real, repeated,
        // wasted GPU-buffer churn on every tick of a completely unrelated
        // drag for any level with real AI Path data. Skipped now unless
        // the selected object actually is a waypoint, or nothing's
        // selected (the rare deselect case, not a per-tick hot path , 
        // where this stays unconditional exactly as before).
        let selectedObjectIsWaypoint = selectedObjectIndex.map { objects.indices.contains($0) && objects[$0].layer == .aiWaypoints } ?? true
        if selectedObjectIsWaypoint {
            rebuildAIPathLineBuffer()
        }
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else {
            selectionLineBuffer = nil
            selectionLineVertexCount = 0
            return
        }
        let object = objects[selectedObjectIndex]
        let half = SIMD3<Float>(repeating: max(object.boundingRadius, 0.15))
        var floats: [Float] = []
        func appendVertex(_ position: SIMD3<Float>, _ color: SIMD3<Float>) {
            floats.append(contentsOf: [position.x, position.y, position.z, color.x, color.y, color.z])
        }
        let localCorners: [SIMD3<Float>] = [
            SIMD3(-half.x, -half.y, -half.z), SIMD3(half.x, -half.y, -half.z),
            SIMD3(half.x, half.y, -half.z), SIMD3(-half.x, half.y, -half.z),
            SIMD3(-half.x, -half.y, half.z), SIMD3(half.x, -half.y, half.z),
            SIMD3(half.x, half.y, half.z), SIMD3(-half.x, half.y, half.z)
        ]
        let corners = localCorners.map { object.worldPosition + $0 }
        let edges: [(Int, Int)] = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7)
        ]
        for (a, b) in edges {
            appendVertex(corners[a], Self.selectionOutlineColor)
            appendVertex(corners[b], Self.selectionOutlineColor)
        }
        selectionLineVertexCount = floats.count / 6
        selectionLineBuffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    /// Standard screen-space axis-constrained drag: project the selected
    /// object's origin and the grabbed axis's tip into screen space, take
    /// the mouse's raw delta, and scalar-project it onto that screen-space
    /// axis direction to get "how far along the arrow did the mouse move"
    ///, then convert that back into world units using the known
    /// world-length/screen-length ratio of the same arrow. Shared by
    /// translate and scale drags; rotate uses a different (simpler)
    /// technique, see `dragRotate`.
    private static func axisProjectedWorldDelta(viewportDelta: CGVector, originScreen: CGPoint, tipScreen: CGPoint, armLength: Float) -> Float? {
        let axisScreenX = tipScreen.x - originScreen.x
        let axisScreenY = tipScreen.y - originScreen.y
        let axisScreenLength = hypot(axisScreenX, axisScreenY)
        guard axisScreenLength > 0.5 else { return nil }

        // `event.deltaY` is positive for *downward* mouse motion (matching
        // this file's existing orbit-drag code, `renderer.pitch += deltaY *
        // 0.01`), while `project(...)`'s screen space is y-up, so `dy` is
        // negated before use. This (and the overall drag feel) is derived
        // from the documented Metal NDC/AppKit coordinate conventions, not
        // verified interactively, there's no way to drive a real
        // mouse-drag gesture from this build environment, so test the
        // actual feel by hand.
        let mouseX = viewportDelta.dx
        let mouseY = -viewportDelta.dy
        let projectedLength = (mouseX * axisScreenX + mouseY * axisScreenY) / axisScreenLength
        let worldPerScreenPoint = Double(armLength) / Double(axisScreenLength)
        return Float(projectedLength * worldPerScreenPoint)
    }

    func dragSelectedObject(axis: GizmoAxis, viewportDelta: CGVector, viewSize: CGSize) {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else { return }
        switch gizmoMode {
        case .translate: dragTranslate(axis: axis, viewportDelta: viewportDelta, viewSize: viewSize, index: selectedObjectIndex)
        case .scale: dragScale(axis: axis, viewportDelta: viewportDelta, viewSize: viewSize, index: selectedObjectIndex)
        case .rotate: dragRotate(axis: axis, viewportDelta: viewportDelta, index: selectedObjectIndex)
        }
    }

    /// See `beginGizmoDrag`'s own protocol doc comment, and `dragRotate`'s
    /// for why a rotate drag specifically needs these.
    private var rotationDragStartRotation: simd_quatf?
    private var rotationDragAccumulatedRadians: Float = 0

    func beginGizmoDrag() {
        guard let selectedObjectIndex, objects.indices.contains(selectedObjectIndex) else {
            rotationDragStartRotation = nil
            return
        }
        rotationDragStartRotation = objects[selectedObjectIndex].rotation
        rotationDragAccumulatedRadians = 0
    }

    private func dragTranslate(axis: GizmoAxis, viewportDelta: CGVector, viewSize: CGSize, index: Int) {
        let origin = objects[index].worldPosition
        let viewProjection = currentViewProjection(viewSize: viewSize)
        guard let originScreen = Self.project(origin, viewProjection: viewProjection, viewSize: viewSize),
              let tipScreen = Self.project(origin + axis.unitVector * gizmoArmLength, viewProjection: viewProjection, viewSize: viewSize),
              let worldDelta = Self.axisProjectedWorldDelta(viewportDelta: viewportDelta, originScreen: originScreen, tipScreen: tipScreen, armLength: gizmoArmLength)
        else { return }

        var newPosition = origin + axis.unitVector * worldDelta
        if snapToGrid, gridSize > 0.0001 {
            func snap(_ value: Float) -> Float { (value / gridSize).rounded() * gridSize }
            switch axis {
            case .x: newPosition.x = snap(newPosition.x)
            case .y: newPosition.y = snap(newPosition.y)
            case .z: newPosition.z = snap(newPosition.z)
            }
        }
        if magnetSnapEnabled {
            newPosition = magnetSnappedPosition(newPosition, excluding: index, axis: axis)
        }
        objects[index].worldPosition = newPosition
        rebuildGizmoBuffer()
        rebuildSelectionBuffer()
    }

    /// See `magnetSnapEnabled`'s doc comment. Linear scan over `objects` , 
    /// fine at the level sizes this build handles (hundreds of placements),
    /// and only runs once per drag-mouse-move event, not once per frame.
    /// Not `private` so tests can exercise the snap math directly, without
    /// needing to reproduce `dragTranslate`'s screen-space projection math
    /// to land on an exact world-space delta, same reasoning as
    /// `hasCollisionFill`'s own "exposed for testing" doc comment.
    ///
    /// "Magnet Snap, Stacking": alongside the original center-to-center
    /// match (two objects lining up at the same coordinate), also offers
    /// *face-to-face* candidates, this object's near face flush against
    /// the neighbor's far face on this axis, using each object's own real
    /// local-space AABB (`GPULevelObject.localBoundsMin`/`.localBoundsMax`,
    /// scaled) rather than assuming every object is the same size. This is
    /// what actually lets two boxes *stack* (one sitting flush on top of
    /// another, dragged on the Y axis) or *connect side by side* (dragged
    /// on X/Z) instead of only ever aligning their centers, which either
    /// leaves a gap or makes them interpenetrate unless both happen to
    /// share the exact same extent on that axis. All three candidates
    /// (center, face-above, face-below) compete on equal footing, whichever
    /// lands closest to where the object was actually dragged wins, so a
    /// small drag toward a neighbor's side still yields the natural result.
    func magnetSnappedPosition(_ position: SIMD3<Float>, excluding index: Int, axis: GizmoAxis) -> SIMD3<Float> {
        let draggedHalfExtent = objects.indices.contains(index) ? Self.halfExtent(of: objects[index], axis: axis) : 0
        return magnetSnapping(position, excludingIndex: index, candidateIndices: nil, draggedHalfExtent: draggedHalfExtent, axis: axis)
    }

    /// "Align While Placing": the drag-time snap
    /// above only ever ran once an object already existed and was being
    /// moved; a brand-new placement (Forge Palette click, Scenery tab
    /// click, drag-and-drop) landed exactly on the raw ground/collision
    /// raycast hit with no alignment help at all, so lining a new object
    /// up with its neighbors meant placing it roughly right and then
    /// nudging it into place by hand afterward. This runs the same
    /// center/face-to-face snap logic *before* the object is ever added to
    /// `objects`, using its own real local bounds/scale (not yet available
    /// as a `GPULevelObject` to read them from, since it doesn't exist
    /// yet) computed by the caller from its about-to-be-placed asset.
    ///
    /// "Select an item or have it align to the nearest item", when an
    /// existing object is currently selected at the moment a new one is
    /// placed, that's treated as the user's own explicit choice of what to
    /// align to: only *that* object is considered, even if something else
    /// is closer. With nothing selected, falls back to nearest-of-any , 
    /// the same behavior dragging an existing object already has. Gated by
    /// `magnetSnapEnabled`, the same toggle drag-time snapping already
    /// uses, rather than a second one, one switch governs "does this
    /// editor line things up for me" everywhere it applies.
    func magnetSnappedPlacementPosition(_ position: SIMD3<Float>, localBoundsMin: SIMD3<Float>, localBoundsMax: SIMD3<Float>, scale: SIMD3<Float>) -> SIMD3<Float> {
        guard magnetSnapEnabled else { return position }
        let candidateIndices: [Int]? = selectedObjectIndex.map { [$0] }
        var result = position
        for axis in GizmoAxis.allCases {
            let draggedHalfExtent = Self.halfExtent(localMin: localBoundsMin, localMax: localBoundsMax, scale: scale, axis: axis)
            result = magnetSnapping(result, excludingIndex: nil, candidateIndices: candidateIndices, draggedHalfExtent: draggedHalfExtent, axis: axis)
        }
        return result
    }

    /// Shared core both `magnetSnappedPosition` (dragging an existing
    /// object, one axis at a time, always considers every other object)
    /// and `magnetSnappedPlacementPosition` (a not-yet-placed object, all
    /// three axes, optionally restricted to one specifically-selected
    /// candidate) build on. `candidateIndices: nil` means "every object in
    /// `objects` except `excludingIndex`"; a non-`nil` list restricts to
    /// exactly those indices (still honoring `excludingIndex`, though in
    /// practice the two callers never combine a real `excludingIndex` with
    /// a real `candidateIndices` at once).
    private func magnetSnapping(_ position: SIMD3<Float>, excludingIndex: Int?, candidateIndices: [Int]?, draggedHalfExtent: Float, axis: GizmoAxis) -> SIMD3<Float> {
        let currentAxisValue = Self.axisComponent(position, axis: axis)
        var best: (distance: Float, value: Float)?
        func consider(_ candidateValue: Float) {
            let distance = abs(currentAxisValue - candidateValue)
            guard distance < magnetSnapThreshold else { return }
            if best == nil || distance < best!.distance {
                best = (distance, candidateValue)
            }
        }
        let indicesToCheck = candidateIndices ?? Array(objects.indices)
        for otherIndex in indicesToCheck where otherIndex != excludingIndex && objects.indices.contains(otherIndex) {
            let other = objects[otherIndex]
            let otherAxisValue = Self.axisComponent(other.worldPosition, axis: axis)
            consider(otherAxisValue)
            let otherHalfExtent = Self.halfExtent(of: other, axis: axis)
            consider(otherAxisValue + otherHalfExtent + draggedHalfExtent)
            consider(otherAxisValue - otherHalfExtent - draggedHalfExtent)
        }
        guard let best else { return position }
        return Self.settingAxisComponent(position, axis: axis, to: best.value)
    }

    private nonisolated static func axisComponent(_ v: SIMD3<Float>, axis: GizmoAxis) -> Float {
        switch axis {
        case .x: return v.x
        case .y: return v.y
        case .z: return v.z
        }
    }

    private nonisolated static func settingAxisComponent(_ v: SIMD3<Float>, axis: GizmoAxis, to value: Float) -> SIMD3<Float> {
        var result = v
        switch axis {
        case .x: result.x = value
        case .y: result.y = value
        case .z: result.z = value
        }
        return result
    }

    /// Half this object's real extent on `axis`, in world units, its
    /// local AABB half-width scaled by the object's own (interactively
    /// editable) `scale`. Ignores rotation entirely: an axis-aligned local
    /// box under a non-axis-aligned rotation no longer has a clean "face"
    /// on a world axis at all, and every placeable object in this editor
    /// starts unrotated by default, so this stays correct for the common
    /// "stack straight up" / "line up side by side" case this feature
    /// targets without pulling in full oriented-box math.
    private nonisolated static func halfExtent(of object: GPULevelObject, axis: GizmoAxis) -> Float {
        halfExtent(localMin: object.localBoundsMin, localMax: object.localBoundsMax, scale: object.scale, axis: axis)
    }

    private nonisolated static func halfExtent(localMin: SIMD3<Float>, localMax: SIMD3<Float>, scale: SIMD3<Float>, axis: GizmoAxis) -> Float {
        let extent: Float
        let axisScale: Float
        switch axis {
        case .x: extent = localMax.x - localMin.x; axisScale = scale.x
        case .y: extent = localMax.y - localMin.y; axisScale = scale.y
        case .z: extent = localMax.z - localMin.z; axisScale = scale.z
        }
        return max(extent, 0) / 2 * abs(axisScale)
    }

    /// Same screen-space axis-projection technique as `dragTranslate`, but
    /// the resulting world-space delta is interpreted as a *fraction of
    /// the gizmo's own arm length* added to the current scale on that axis
    ///, dragging the full visible length of the arrow roughly doubles the
    /// scale, which reads as a reasonably proportional "how far I dragged
    /// maps to how much bigger it got" feel without needing a separate
    /// calibration constant.
    private func dragScale(axis: GizmoAxis, viewportDelta: CGVector, viewSize: CGSize, index: Int) {
        let origin = objects[index].worldPosition
        let viewProjection = currentViewProjection(viewSize: viewSize)
        guard let originScreen = Self.project(origin, viewProjection: viewProjection, viewSize: viewSize),
              let tipScreen = Self.project(origin + axis.unitVector * gizmoArmLength, viewProjection: viewProjection, viewSize: viewSize),
              let worldDelta = Self.axisProjectedWorldDelta(viewportDelta: viewportDelta, originScreen: originScreen, tipScreen: tipScreen, armLength: gizmoArmLength)
        else { return }

        let scaleDelta = worldDelta / gizmoArmLength
        var newScale = objects[index].scale
        switch axis {
        case .x: newScale.x += scaleDelta
        case .y: newScale.y += scaleDelta
        case .z: newScale.z += scaleDelta
        }
        if snapToGrid, gridSize > 0.0001 {
            func snap(_ value: Float) -> Float { (value / gridSize).rounded() * gridSize }
            switch axis {
            case .x: newScale.x = snap(newScale.x)
            case .y: newScale.y = snap(newScale.y)
            case .z: newScale.z = snap(newScale.z)
            }
        }
        // Same reasoning as `setSelectedScale`'s clamp: a zero/negative
        // scale is visually indistinguishable from "nothing renders."
        objects[index].scale = SIMD3(max(newScale.x, 0.01), max(newScale.y, 0.01), max(newScale.z, 0.01))
        rebuildGizmoBuffer()
        rebuildSelectionBuffer()
    }

    /// Deliberately simpler than translate/scale: rather than computing
    /// the exact angle swept around a screen-projected ring (a circle in
    /// world space becomes an ellipse in screen space under perspective,
    /// and the angle math to invert that correctly is real extra
    /// complexity), horizontal mouse motion directly drives rotation
    /// speed around the grabbed axis, the same simplified "drag to spin"
    /// interaction most lightweight in-house gizmos actually use.
    ///
    /// Real, reported bug this fixes: with snap-to-grid on, this used to
    /// re-derive the snap by decoding the *accumulated 3D rotation* into
    /// Euler XYZ angles on every incremental drag tick, then re-composing
    /// a quaternion from the snapped result, `eulerDegrees(from:)` isn't
    /// a globally continuous inverse (gimbal lock, and a wrapped range for
    /// at least one axis), so a rotation dragged far enough (a full turn,
    /// or just past a wrap boundary) could land exactly on a
    /// decomposition singularity and stop visibly responding to further
    /// drag, "gets caught halfway through." Snapping the *scalar* angle
    /// accumulated around this one grabbed axis since the drag began
    /// (`rotationDragAccumulatedRadians`, reset once per drag by
    /// `beginGizmoDrag`) instead avoids the round-trip entirely, a
    /// running sum never wraps or hits a singularity, so it composes onto
    /// `rotationDragStartRotation` cleanly no matter how far the drag goes.
    private func dragRotate(axis: GizmoAxis, viewportDelta: CGVector, index: Int) {
        let degreesPerPoint: Float = 0.5
        let deltaRadians = Float(viewportDelta.dx) * degreesPerPoint * .pi / 180

        if snapToGrid, rotationSnapDegrees > 0.0001, let startRotation = rotationDragStartRotation {
            rotationDragAccumulatedRadians += deltaRadians
            let accumulatedDegrees = rotationDragAccumulatedRadians * 180 / .pi
            let snappedDegrees = (accumulatedDegrees / rotationSnapDegrees).rounded() * rotationSnapDegrees
            let snappedRotation = simd_quatf(angle: snappedDegrees * .pi / 180, axis: axis.unitVector)
            objects[index].rotation = simd_normalize(snappedRotation * startRotation)
        } else {
            let deltaRotation = simd_quatf(angle: deltaRadians, axis: axis.unitVector)
            objects[index].rotation = simd_normalize(deltaRotation * objects[index].rotation)
        }
        rebuildGizmoBuffer()
        rebuildSelectionBuffer()
    }
}

extension LevelViewerRenderer: GizmoInteractiveRenderer {}

// Was `private`, widened to file-default (internal) so `AnimationSkeletonBinding`
// (a separate file needing the exact same TRS-composition helper) can reuse
// it instead of a second, possibly-diverging copy.
extension simd_float4x4 {
    init(translation: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
    }
}
