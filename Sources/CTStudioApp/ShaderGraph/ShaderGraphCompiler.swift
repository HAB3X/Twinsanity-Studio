import Foundation

/// Compiles a `ShaderGraph` into a real Metal Shading Language fragment
/// function, topologically sorts from the graph's one `.finalColor` node
/// backward, materializing each visited node into a named temporary of
/// its *real, correctly-typed* MSL value (never a blind `float4` cast
/// that would fail to compile), with type mismatches between a node's
/// real output and the port it feeds resolved by an explicit, documented
/// conversion policy (`convert`) rather than left for MSL's own implicit-
/// conversion rules to maybe accept.
///
/// The generated function's signature matches `ModelViewerRenderer.
/// shaderSource`'s `fragment_main` exactly (`VertexOut`, `colorTexture`
/// at `texture(0)`, `textureSampler` at `sampler(0)`, `Uniforms` at
/// `buffer(1)`), a real drop-in fragment stage for the same vertex stage
/// and pipeline descriptor, not a disconnected shader that merely happens
/// to be valid MSL (see `ModelViewerRenderer.applyShaderGraph`).
public enum ShaderGraphCompiler {
    public enum CompileError: Error, Equatable {
        case noFinalColorNode
        case multipleFinalColorNodes
        case cycleDetected
    }

    public static func compile(_ graph: ShaderGraph, functionName: String) throws -> String {
        let finalNodes = graph.nodes.filter { if case .finalColor = $0.kind { return true }; return false }
        guard finalNodes.count <= 1 else { throw CompileError.multipleFinalColorNodes }
        guard let finalNode = finalNodes.first else { throw CompileError.noFinalColorNode }

        var compiler = GraphWalker(graph: graph)
        let resultVar = try compiler.visit(finalNode.id)
        let body = compiler.statements.joined(separator: "\n    ")

        return """
        fragment float4 \(functionName)(VertexOut in [[stage_in]],
                                       texture2d<float> colorTexture [[texture(0)]],
                                       sampler textureSampler [[sampler(0)]],
                                       constant Uniforms &uniforms [[buffer(1)]]) {
            \(body)
            return \(resultVar);
        }
        """
    }

    /// Real, explicit widening/narrowing rules between the fixed value
    /// types this graph works with, this tool's own designed convention
    /// (matching common shader-graph tooling: scalars splat, smaller
    /// vectors pad with 0 except a promoted alpha defaults to 1, larger
    /// vectors truncate their leading components), not a guess about any
    /// external format.
    static func convert(_ expr: String, from: ShaderValueType, to: ShaderValueType) -> String {
        guard from != to else { return expr }
        switch (from, to) {
        case (.float, .float2): return "float2(\(expr))"
        case (.float, .float3): return "float3(\(expr))"
        case (.float, .float4): return "float4(\(expr))"
        case (.float2, .float3): return "float3(\(expr), 0.0)"
        case (.float2, .float4): return "float4(\(expr), 0.0, 0.0)"
        case (.float3, .float4): return "float4(\(expr), 1.0)"
        case (.float3, .float2): return "(\(expr)).xy"
        case (.float4, .float3): return "(\(expr)).xyz"
        case (.float4, .float2): return "(\(expr)).xy"
        case (.float4, .float): return "(\(expr)).x"
        case (.float3, .float): return "(\(expr)).x"
        case (.float2, .float): return "(\(expr)).x"
        default: return expr
        }
    }

    private struct GraphWalker {
        let graph: ShaderGraph
        var statements: [String] = []
        private var resolved: [UUID: (variable: String, type: ShaderValueType)] = [:]
        private var visiting: Set<UUID> = []
        private var nextTemp = 0

        init(graph: ShaderGraph) { self.graph = graph }

        /// Returns the variable name holding `nodeID`'s already-materialized
        /// (and now-real-typed) MSL value, visiting/emitting it first if
        /// this is the first time it's been reached from any path.
        mutating func visit(_ nodeID: UUID) throws -> String {
            if let existing = resolved[nodeID] { return existing.variable }
            guard !visiting.contains(nodeID) else { throw CompileError.cycleDetected }
            guard let node = graph.nodes.first(where: { $0.id == nodeID }) else {
                // A dangling connection reference (source node removed
                // from the graph without cleaning up its wires), treat
                // as "not connected" rather than crashing the compile.
                return "float4(0.0)"
            }
            visiting.insert(nodeID)
            defer { visiting.remove(nodeID) }

            let signature = ShaderNodeSignature.signature(for: node.kind)
            var inputExprs: [String] = []
            for (portIndex, expectedType) in signature.inputTypes.enumerated() {
                inputExprs.append(try resolvedInput(forNode: nodeID, portIndex: portIndex, expectedType: expectedType))
            }

            let (rawExpr, outputType) = try expression(for: node.kind, inputs: inputExprs, signature: signature)
            guard let outputType else {
                // .finalColor: no output of its own, its single input *is*
                // the result, no temp to materialize.
                return rawExpr
            }
            let varName = "n\(nextTemp)"
            nextTemp += 1
            statements.append("\(outputType.mslTypeName) \(varName) = \(rawExpr);")
            resolved[nodeID] = (varName, outputType)
            return varName
        }

        /// The expression feeding input port `portIndex` of `nodeID` , 
        /// whatever's wired in, converted to `expectedType`, or a sane
        /// zero/identity default (see per-kind fallback below) when
        /// nothing's connected, so a partially-wired graph still compiles
        /// to something meaningful instead of failing outright.
        private mutating func resolvedInput(forNode nodeID: UUID, portIndex: Int, expectedType: ShaderValueType) throws -> String {
            guard let connection = graph.connections.first(where: { $0.toNodeID == nodeID && $0.toPortIndex == portIndex }) else {
                return Self.defaultLiteral(for: expectedType)
            }
            let sourceVar = try visit(connection.fromNodeID)
            guard let sourceNode = graph.nodes.first(where: { $0.id == connection.fromNodeID }),
                  let sourceType = ShaderNodeSignature.signature(for: sourceNode.kind).outputType
            else {
                return Self.defaultLiteral(for: expectedType)
            }
            return ShaderGraphCompiler.convert(sourceVar, from: sourceType, to: expectedType)
        }

        private static func defaultLiteral(for type: ShaderValueType) -> String {
            switch type {
            case .float: return "0.0"
            case .float2: return "float2(0.0)"
            case .float3: return "float3(0.0)"
            case .float4: return "float4(0.0, 0.0, 0.0, 1.0)"
            }
        }

        private func expression(for kind: ShaderNodeKind, inputs: [String], signature: ShaderNodeSignature) throws -> (String, ShaderValueType?) {
            switch kind {
            case .uv: return ("in.uv", .float2)
            case .vertexColor: return ("in.color", .float4)
            case .worldNormal: return ("in.worldNormal", .float3)
            case .textureSample: return ("colorTexture.sample(textureSampler, \(inputs[0]))", .float4)
            case .constantFloat(let v): return (Self.mslFloat(v), .float)
            case .constantColor(let c):
                return ("float4(\(Self.mslFloat(c.x)), \(Self.mslFloat(c.y)), \(Self.mslFloat(c.z)), \(Self.mslFloat(c.w)))", .float4)
            case .add: return ("(\(inputs[0]) + \(inputs[1]))", .float4)
            case .subtract: return ("(\(inputs[0]) - \(inputs[1]))", .float4)
            case .multiply: return ("(\(inputs[0]) * \(inputs[1]))", .float4)
            case .lerp: return ("mix(\(inputs[0]), \(inputs[1]), \(inputs[2]))", .float4)
            case .saturate: return ("saturate(\(inputs[0]))", .float4)
            case .dotProduct: return ("dot(\(inputs[0]), \(inputs[1]))", .float)
            case .normalizeVec: return ("normalize(\(inputs[0]))", .float3)
            case .uvOffset: return ("(\(inputs[0]) + \(inputs[1]))", .float2)
            case .uvScale: return ("(\(inputs[0]) * \(inputs[1]))", .float2)
            case .finalColor: return (inputs[0], nil)
            }
        }

        private static func mslFloat(_ v: Float) -> String {
            String(format: "%.6f", v)
        }
    }
}
