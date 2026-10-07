import Foundation
import simd

/// An `AIPosition` record, a single AI waypoint. Ported from
/// `Twinsanity/Items/Instances/AIPosition.cs`. `nodeType` matches that
/// file's own `NodeType` enum (`Ground`/`Air`/`WormPath`/`CortexPoint`) , 
/// real, named values from the reference tool, not a guess.
public struct AIPositionMarker: Sendable, Identifiable, Codable {
    public enum NodeType: UInt16, Sendable, Codable {
        case ground = 0
        case air = 2
        case wormPath = 4
        case cortexPoint = 16

        public var displayName: String {
            switch self {
            case .ground: return "Ground"
            case .air: return "Air"
            case .wormPath: return "Worm Path"
            case .cortexPoint: return "Cortex Point"
            }
        }
    }

    public let id: UInt32
    /// `W` is annotated "node weight?" in the reference tool's own source
    ///, kept verbatim, not resolved into a confirmed meaning.
    public var position: SIMD4<Float>
    /// Raw on-disk value, `nodeType` is `nil` when it doesn't match any
    /// of the reference tool's own named `NodeType` cases (real data may
    /// use values that enum doesn't cover).
    public var rawNodeType: UInt16

    public var nodeType: NodeType? { NodeType(rawValue: rawNodeType) }

    public init(id: UInt32, position: SIMD4<Float>, rawNodeType: UInt16) {
        self.id = id
        self.position = position
        self.rawNodeType = rawNodeType
    }
}

/// An `AIPath` record. Ported from `Twinsanity/Items/Instances/AIPath.cs`
///, 5 raw arguments, no position of its own.
///
/// `AIPathController.GenText()` (the reference tool's tree-node summary)
/// never interprets these beyond printing them as "Argument0".."Argument4",
/// but its own dedicated editor form does: `AIPathEditor.Designer.cs`
/// labels the numeric fields bound to `Arg[0]`/`Arg[1]` "AI Pos 1"/"AI Pos
/// 2" (`label1`/`label2`'s real `Text` values, positioned directly beside
/// `numericUpDown1`/`numericUpDown2` in the form layout, confirmed by
/// reading the `.Designer.cs` file directly, not guessed from field
/// ordering). `Arg[2]`/`Arg[3]`/`Arg[4]` get only generic "Arg 1"/"Arg
/// 2"/"Arg 3" labels there, so this build doesn't claim anything about
/// those beyond "raw argument."
///
/// This is real, citable evidence Arg[0]/Arg[1] are meant as `AIPosition`
/// record IDs (see `startAIPositionID`/`endAIPositionID` below), but it's
/// still just a UI label, not an executed lookup: no code anywhere in the
/// reference tool (`AIPathController`, `AIPathEditor`, `CodeModel`) ever
/// actually resolves these values against the `AIPosition` collection, so
/// this build treats them as *candidate* references, not a confirmed,
/// game-verified connection graph.
public struct AIPathRecord: Sendable, Identifiable, Codable {
    public let id: UInt32
    public var args: [UInt16]

    public init(id: UInt32, args: [UInt16]) {
        self.id = id
        self.args = args
    }

    /// `Arg[0]`, the reference tool's own `AIPathEditor` labels this "AI
    /// Pos 1" (see this type's own doc comment). `nil` only if `args` is
    /// shorter than expected (every real on-disk record has exactly 5).
    public var startAIPositionID: UInt16? { args.indices.contains(0) ? args[0] : nil }
    /// `Arg[1]`, labeled "AI Pos 2" by the same reference-tool editor.
    public var endAIPositionID: UInt16? { args.indices.contains(1) ? args[1] : nil }
}
