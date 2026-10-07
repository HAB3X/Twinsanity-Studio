import Foundation
import CoreGraphics
import simd

/// "Shader Graph Editor" (roadmap 5.4), a real, original node-based
/// material authoring model. Every node kind here is this tool's own
/// invented vocabulary (not a reverse-engineered Twinsanity format, the
/// game's own material/shader system isn't decoded and isn't what this
/// compiles to), compiled to real Metal Shading Language that plugs
/// directly into `ModelViewerRenderer`'s existing `VertexOut`/`Uniforms`
/// struct layout and `fragment_main`'s texture(0)/sampler(0)/buffer(1)
/// binding convention (see `ShaderGraphCompiler`).
public enum ShaderValueType: String, Sendable, CaseIterable {
    case float, float2, float3, float4

    var mslTypeName: String { rawValue }
}

/// Every node's real MSL semantics live in `ShaderGraphCompiler`; this
/// case set is the vocabulary a graph can be built from. Associated
/// values only on the two literal-constant cases, every other case's
/// behavior is fixed, driven entirely by its connected inputs.
public enum ShaderNodeKind: Sendable, Equatable {
    case uv
    case vertexColor
    case worldNormal
    case textureSample
    case constantFloat(Float)
    case constantColor(SIMD4<Float>)
    case add
    case subtract
    case multiply
    case lerp
    case saturate
    case dotProduct
    case normalizeVec
    case uvOffset
    case uvScale
    case finalColor

    public var displayName: String {
        switch self {
        case .uv: return "UV"
        case .vertexColor: return "Vertex Color"
        case .worldNormal: return "World Normal"
        case .textureSample: return "Sample Texture"
        case .constantFloat: return "Float"
        case .constantColor: return "Color"
        case .add: return "Add"
        case .subtract: return "Subtract"
        case .multiply: return "Multiply"
        case .lerp: return "Lerp"
        case .saturate: return "Saturate"
        case .dotProduct: return "Dot Product"
        case .normalizeVec: return "Normalize"
        case .uvOffset: return "UV Offset"
        case .uvScale: return "UV Scale"
        case .finalColor: return "Final Color (Output)"
        }
    }
}

/// One node's real input-port shape, arity, per-port expected type (used
/// to auto-convert whatever's actually connected, see
/// `ShaderGraphCompiler.convert`), and this node's own output type
/// (`nil` only for `.finalColor`, the graph's one terminal/output node).
public struct ShaderNodeSignature {
    public let inputTypes: [ShaderValueType]
    public let inputLabels: [String]
    public let outputType: ShaderValueType?

    public static func signature(for kind: ShaderNodeKind) -> ShaderNodeSignature {
        switch kind {
        case .uv: return .init(inputTypes: [], inputLabels: [], outputType: .float2)
        case .vertexColor: return .init(inputTypes: [], inputLabels: [], outputType: .float4)
        case .worldNormal: return .init(inputTypes: [], inputLabels: [], outputType: .float3)
        case .textureSample: return .init(inputTypes: [.float2], inputLabels: ["UV"], outputType: .float4)
        case .constantFloat: return .init(inputTypes: [], inputLabels: [], outputType: .float)
        case .constantColor: return .init(inputTypes: [], inputLabels: [], outputType: .float4)
        case .add: return .init(inputTypes: [.float4, .float4], inputLabels: ["A", "B"], outputType: .float4)
        case .subtract: return .init(inputTypes: [.float4, .float4], inputLabels: ["A", "B"], outputType: .float4)
        case .multiply: return .init(inputTypes: [.float4, .float4], inputLabels: ["A", "B"], outputType: .float4)
        case .lerp: return .init(inputTypes: [.float4, .float4, .float4], inputLabels: ["A", "B", "T"], outputType: .float4)
        case .saturate: return .init(inputTypes: [.float4], inputLabels: ["In"], outputType: .float4)
        case .dotProduct: return .init(inputTypes: [.float3, .float3], inputLabels: ["A", "B"], outputType: .float)
        case .normalizeVec: return .init(inputTypes: [.float3], inputLabels: ["In"], outputType: .float3)
        case .uvOffset: return .init(inputTypes: [.float2, .float2], inputLabels: ["UV", "Offset"], outputType: .float2)
        case .uvScale: return .init(inputTypes: [.float2, .float2], inputLabels: ["UV", "Scale"], outputType: .float2)
        case .finalColor: return .init(inputTypes: [.float4], inputLabels: ["Color"], outputType: nil)
        }
    }
}

public struct ShaderGraphNode: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var kind: ShaderNodeKind
    /// Canvas layout position, the compiler ignores this entirely; it's
    /// purely for `ShaderGraphEditorView`.
    public var position: CGPoint

    public init(id: UUID = UUID(), kind: ShaderNodeKind, position: CGPoint = .zero) {
        self.id = id
        self.kind = kind
        self.position = position
    }
}

/// One wire: `fromNode`'s (single) output feeding `toNode`'s input at
/// `toPortIndex`. A port can have at most one incoming connection , 
/// wiring a second one to the same port replaces the first, matching how
/// every real node-graph tool (Unity Shader Graph, Blender's shader
/// editor, Unreal Material Editor) treats a single input socket.
public struct ShaderGraphConnection: Sendable, Hashable {
    public var fromNodeID: UUID
    public var toNodeID: UUID
    public var toPortIndex: Int

    public init(fromNodeID: UUID, toNodeID: UUID, toPortIndex: Int) {
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.toPortIndex = toPortIndex
    }
}

public struct ShaderGraph: Sendable {
    public var nodes: [ShaderGraphNode]
    public var connections: [ShaderGraphConnection]

    public init(nodes: [ShaderGraphNode] = [], connections: [ShaderGraphConnection] = []) {
        self.nodes = nodes
        self.connections = connections
    }

    /// A starting graph every new Shader Graph Editor session opens
    /// with, a real, minimal, already-valid material (samples the
    /// bound texture, multiplies by vertex color, straight to output) so
    /// "Compile & Preview" produces something meaningful before the user
    /// has wired anything themselves.
    public static func defaultGraph() -> ShaderGraph {
        let uv = ShaderGraphNode(kind: .uv, position: CGPoint(x: 40, y: 40))
        let sample = ShaderGraphNode(kind: .textureSample, position: CGPoint(x: 220, y: 40))
        let color = ShaderGraphNode(kind: .vertexColor, position: CGPoint(x: 220, y: 160))
        let multiply = ShaderGraphNode(kind: .multiply, position: CGPoint(x: 420, y: 100))
        let final = ShaderGraphNode(kind: .finalColor, position: CGPoint(x: 620, y: 100))
        return ShaderGraph(
            nodes: [uv, sample, color, multiply, final],
            connections: [
                ShaderGraphConnection(fromNodeID: uv.id, toNodeID: sample.id, toPortIndex: 0),
                ShaderGraphConnection(fromNodeID: sample.id, toNodeID: multiply.id, toPortIndex: 0),
                ShaderGraphConnection(fromNodeID: color.id, toNodeID: multiply.id, toPortIndex: 1),
                ShaderGraphConnection(fromNodeID: multiply.id, toNodeID: final.id, toPortIndex: 0),
            ]
        )
    }
}
