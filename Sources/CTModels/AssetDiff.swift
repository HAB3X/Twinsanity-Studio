import Foundation

/// "Asset Diff & Version Comparison Tool" (blueprint 4.3): a side-by-side
/// comparison of two already-resolved `ResolvedModelAsset`s, e.g. the same
/// object loaded from two different archive scans, or two candidate models
/// that share a name. Built entirely from data this codebase already
/// decodes (vertex/submesh/material/texture counts and IDs); it doesn't
/// attempt a vertex-level or hex-level diff, since that would mean
/// re-deriving byte offsets this build doesn't track per-vertex.
public struct AssetDiffRow: Sendable, Identifiable {
    public let id = UUID()
    public let label: String
    public let leftValue: String
    public let rightValue: String
    public let isDifferent: Bool

    public init(label: String, leftValue: String, rightValue: String, isDifferent: Bool) {
        self.label = label
        self.leftValue = leftValue
        self.rightValue = rightValue
        self.isDifferent = isDifferent
    }
}

public enum AssetDiff {
    /// Builds the comparison rows for two assets. Order-independent set
    /// comparisons (material/texture IDs) rather than positional ones , 
    /// submesh order isn't a meaningful thing to diff on its own since two
    /// otherwise-identical models can legitimately differ in submesh
    /// ordering depending on export order.
    public static func compare(_ left: ResolvedModelAsset, _ right: ResolvedModelAsset) -> [AssetDiffRow] {
        var rows: [AssetDiffRow] = []

        func row(_ label: String, _ l: String, _ r: String) {
            rows.append(AssetDiffRow(label: label, leftValue: l, rightValue: r, isDifferent: l != r))
        }

        row("Record ID", "\(left.recordID)", "\(right.recordID)")
        row("Submeshes", "\(left.mesh.submeshes.count)", "\(right.mesh.submeshes.count)")
        row("Vertices", "\(left.mesh.totalVertexCount)", "\(right.mesh.totalVertexCount)")
        row("Triangles", "\(left.mesh.totalTriangleCount)", "\(right.mesh.totalTriangleCount)")
        row("Rigged", left.skeleton != nil ? "Yes" : "No", right.skeleton != nil ? "Yes" : "No")
        row("Animations", "\(left.availableAnimations.count)", "\(right.availableAnimations.count)")
        row("Fully Textured", left.isFullyTextured ? "Yes" : "No", right.isFullyTextured ? "Yes" : "No")

        let leftMaterials = Set(left.submeshMaterials.compactMap(\.materialID))
        let rightMaterials = Set(right.submeshMaterials.compactMap(\.materialID))
        row("Material IDs", idListString(leftMaterials), idListString(rightMaterials))

        let leftTextures = Set(left.submeshMaterials.compactMap(\.textureID))
        let rightTextures = Set(right.submeshMaterials.compactMap(\.textureID))
        row("Texture IDs", idListString(leftTextures), idListString(rightTextures))

        let leftAnimIDs = Set(left.availableAnimations.map(\.id))
        let rightAnimIDs = Set(right.availableAnimations.map(\.id))
        row("Animation IDs", idListString(leftAnimIDs), idListString(rightAnimIDs))

        return rows
    }

    private static func idListString(_ ids: Set<UInt32>) -> String {
        ids.isEmpty ? ", " : ids.sorted().map(String.init).joined(separator: ", ")
    }
}
