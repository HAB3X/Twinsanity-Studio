import Foundation
import CTModels
import simd

/// "Parity Phase I": imports a Wavefront `.obj` mesh into a real `ColData`
/// collision mesh, ported from `Workers/CollisionImporter.cs`'s OBJ
/// loader, connectivity-grouping algorithm, and balanced binary trigger-
/// tree builder. Pure, file-I/O-free, and fully unit-testable; the
/// UI-facing file-picker/save flow lives in `ColDataEditorSheet`'s "Import
/// Collision Mesh from OBJ" section.
///
/// Faithfully ported, including two real reference quirks worth calling
/// out explicitly rather than silently "fixing":
/// - The per-face grouping loop's own `maxPolysPerGroup` check
///   (`model.groups[grp].Size >= numericUpDown1.Value`) reads a field that
///   is only ever populated *after* this loop finishes (`GenerateGroupOff`)
///  , so it always compares against 0 and can never actually fire. A
///   connectivity-formed group is never split mid-formation; only
///   `mergeGroups`'s separate (real) triangle-count check enforces the
///   limit, and only for *merging* two already-formed groups. Ported by
///   simply omitting the dead branch.
/// - `mergeGroups`'s own vertex-overlap check tests a group's first and
///   third vertex (`Vert1`/`Vert3`) but never the second (`Vert2` is
///   checked as `Vert3` a second time instead), a real copy-paste bug in
///   the reference. Preserved here.
///
/// One deliberate deviation: the reference's own bounding-box accumulation
/// (`TriggerRecalculate`) uses "is this coordinate exactly `0`, meaning
/// uninitialized?" as its first-iteration sentinel, a real bug that
/// silently produces a wrong (too-small) box for any triangle whose true
/// extent includes exactly `0` on some axis. That's a pure derived-value
/// computation with no on-disk format implications (unlike the two quirks
/// above, which affect which *groups* files, a real interoperability
/// concern), so this port uses a correct `.greatestFiniteMagnitude`
/// min/max accumulator instead, an imported mesh's trigger boxes are
/// strictly more correct this way, with no downside.
public enum CollisionOBJImporter {
    /// One `.obj` file's parsed result: real vertex positions and its
    /// triangles already partitioned into connectivity groups (each an
    /// ordered list of local, 0-based vertex-index triangles).
    public struct ParsedOBJModel: Sendable {
        public var vertices: [SIMD4<Float>]
        public var groups: [[(v1: Int, v2: Int, v3: Int)]]

        public init(vertices: [SIMD4<Float>], groups: [[(v1: Int, v2: Int, v3: Int)]]) {
            self.vertices = vertices
            self.groups = groups
        }

        public var vertexCount: Int { vertices.count }
        public var triangleCount: Int { groups.reduce(0) { $0 + $1.count } }
    }

    /// Parses `text` as a Wavefront OBJ (`v x y z` / `f v1 v2 v3` lines
    /// only, normals, UVs, and non-triangular faces are ignored, matching
    /// the reference's own `str[1].Split('/')[0]`-only face parsing, which
    /// silently assumes pre-triangulated input). `x` is negated on read , 
    /// the reference's own `-float.Parse(str[1]...)`, converting from an
    /// OBJ exporter's/viewer's world-space convention into this game's raw
    /// on-disk one, the same X-mirror this codebase applies consistently
    /// at every other render/import boundary.
    public static func parseOBJ(_ text: String, maxPolysPerGroup: Int) -> ParsedOBJModel {
        var vertices: [SIMD4<Float>] = []
        var groups: [[(Int, Int, Int)]] = []
        var vertGroups: [Int: Int] = [:]

        func discardGroup(_ grp: Int) {
            vertGroups = vertGroups.filter { $0.value != grp }
        }
        func vertexIndex(_ token: Substring) -> Int? {
            guard let first = token.split(separator: "/").first, let i = Int(first) else { return nil }
            return i - 1
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard let tag = parts.first else { continue }
            if tag == "v", parts.count >= 4,
               let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                vertices.append(SIMD4(-x, y, z, 1))
            } else if tag == "f", parts.count >= 4,
                      let v1 = vertexIndex(parts[1]), let v2 = vertexIndex(parts[2]), let v3 = vertexIndex(parts[3]) {
                if let existing = vertGroups[v1] ?? vertGroups[v2] ?? vertGroups[v3] {
                    let grp = existing
                    if vertGroups[v1] == nil { vertGroups[v1] = grp }
                    if vertGroups[v2] == nil { vertGroups[v2] = grp }
                    if vertGroups[v3] == nil { vertGroups[v3] = grp }
                    groups[grp].append((v1, v2, v3))
                } else {
                    let grp = groups.count
                    groups.append([(v1, v2, v3)])
                    vertGroups[v1] = grp; vertGroups[v2] = grp; vertGroups[v3] = grp
                    _ = discardGroup // referenced to document intent; only called from the dead branch this port omits
                }
            }
        }

        mergeGroups(&groups, maxPolysPerGroup: maxPolysPerGroup)
        return ParsedOBJModel(vertices: vertices, groups: groups.filter { !$0.isEmpty })
    }

    /// Ported from `CheckMergeGroups`: merges group `j` into an earlier
    /// group `i` when their combined triangle count still fits
    /// `maxPolysPerGroup` and they share a vertex, see this type's own
    /// doc comment for the real `Vert2`-never-checked quirk preserved here.
    static func mergeGroups(_ groups: inout [[(Int, Int, Int)]], maxPolysPerGroup: Int) {
        var groupsToDelete = Set<Int>()
        for i in 0..<groups.count {
            if groupsToDelete.contains(i) { continue }
            var verts = Set<Int>()
            for tri in groups[i] { verts.insert(tri.0); verts.insert(tri.1); verts.insert(tri.2) }
            guard i + 1 < groups.count else { continue }
            for j in (i + 1)..<groups.count {
                if groups[i].count + groups[j].count > maxPolysPerGroup { continue }
                var merged = false
                for tri in groups[j] where verts.contains(tri.0) || verts.contains(tri.2) {
                    merged = true
                    break
                }
                if merged {
                    groups[i].append(contentsOf: groups[j])
                    groupsToDelete.insert(j)
                }
            }
        }
        for index in groupsToDelete.sorted(by: >) {
            groups.remove(at: index)
        }
    }

    /// Concatenates every staged model (each with its own assigned
    /// `surfaceID`) into one `CollisionMesh`, vertex/triangle indices and
    /// group offsets shifted to a shared flat pool, matching `button3_
    /// Click`'s own concatenation order, then builds the balanced binary
    /// trigger tree over the combined groups.
    public static func buildCombinedMesh(id: UInt32, models: [(model: ParsedOBJModel, surfaceID: Int)]) -> CollisionMesh {
        var allVertices: [SIMD4<Float>] = []
        var allTriangles: [CollisionTriangle] = []
        var allGroups: [CollisionGroup] = []

        for (model, surfaceID) in models {
            let vertexOffset = allVertices.count
            allVertices.append(contentsOf: model.vertices)
            for group in model.groups {
                let triOffset = UInt32(allTriangles.count)
                for tri in group {
                    allTriangles.append(CollisionTriangle(
                        vertexIndex1: tri.v1 + vertexOffset,
                        vertexIndex2: tri.v2 + vertexOffset,
                        vertexIndex3: tri.v3 + vertexOffset,
                        surfaceID: surfaceID
                    ))
                }
                allGroups.append(CollisionGroup(size: UInt32(group.count), offset: triOffset))
            }
        }

        let triggerBoxes = buildTriggerTree(groups: allGroups, triangles: allTriangles, vertices: allVertices)
        return CollisionMesh(id: id, vertices: allVertices, triangles: allTriangles, groups: allGroups, triggerBoxes: triggerBoxes)
    }

    // MARK: - Balanced binary trigger tree
    //
    // Ported from `button3_Click`'s `ExpandLevel`/`ExpandEngings` (tree
    // shape) + `CalcIDs`/`Tree2Trigger` (index assignment). Re-derived as
    // a plain recursive tree build + preorder numbering rather than a
    // transliteration of the reference's own `TreeView`/string-`Name`-
    // based state machine, verified equivalent by hand: `CalcIDs`' own
    // `Node.Nodes[1].Text = leftChildID + GetNodeCount(leftChild) + 1`
    // (where `GetNodeCount` *excludes* the node itself, per .NET's own
    // `TreeNode.GetNodeCount` semantics) reduces exactly to "each node's
    // ID is its 0-based position in a preorder (root, then left subtree,
    // then right subtree) traversal", the same layout a segment-tree/
    // Cartesian-tree array embedding uses.

    private indirect enum TreeNode {
        case leaf(groupIndex: Int)
        case branch(TreeNode, TreeNode)
    }

    /// `ExpandLevel` (run `floor(log2(groupCount))` times, doubling every
    /// leaf into two) then `ExpandEngings` (expands the first `groupCount
    /// - 2^x` leaves, in preorder order, one more time), builds a
    /// complete binary tree with exactly `groupCount` leaves.
    private static func buildTree(groupCount: Int) -> TreeNode {
        guard groupCount > 1 else { return .leaf(groupIndex: 0) }

        func expandAll(_ node: TreeNode) -> TreeNode {
            switch node {
            case .leaf: return .branch(.leaf(groupIndex: -1), .leaf(groupIndex: -1))
            case .branch(let l, let r): return .branch(expandAll(l), expandAll(r))
            }
        }
        var tree: TreeNode = .leaf(groupIndex: -1)
        let x = Int(log2(Double(groupCount)))
        for _ in 0..<x { tree = expandAll(tree) }

        var remaining = groupCount - (1 << x)
        func expandFirst(_ node: TreeNode) -> TreeNode {
            guard remaining > 0 else { return node }
            switch node {
            case .leaf:
                remaining -= 1
                return .branch(.leaf(groupIndex: -1), .leaf(groupIndex: -1))
            case .branch(let l, let r):
                return .branch(expandFirst(l), expandFirst(r))
            }
        }
        tree = expandFirst(tree)

        var nextGroupIndex = 0
        func assignGroupIndices(_ node: TreeNode) -> TreeNode {
            switch node {
            case .leaf:
                let idx = nextGroupIndex
                nextGroupIndex += 1
                return .leaf(groupIndex: idx)
            case .branch(let l, let r):
                return .branch(assignGroupIndices(l), assignGroupIndices(r))
            }
        }
        return assignGroupIndices(tree)
    }

    private struct FlatNode {
        var isLeaf: Bool
        var groupIndex: Int
        var leftID: Int
        var rightID: Int
    }

    /// Flattens the tree via preorder traversal (assigning each node's
    /// array index as its trigger ID, see this section's own doc
    /// comment), then fills every trigger's AABB: a leaf's box is the
    /// union of its group's real triangle vertex positions
    /// (`flag1`/`flag2` both encode `-(groupIndex + 1)`, so `-flag1 - 1`
    /// recovers the group index, matching `TriggerRecalculate`'s own
    /// `Groups[-Triggers[index].Flag1 - 1]`); an internal node's box is
    /// the union of its two children's boxes (`flag1`/`flag2` there are
    /// real trigger-array indices instead).
    /// Not `private`, "Auto-Update Collision on Add/Delete" reuses this
    /// directly to rebuild just the trigger tree over a combined group
    /// list (original level geometry's own groups, untouched, plus fresh
    /// groups for session-placed objects), without needing to route
    /// already-grouped original geometry back through `buildCombinedMesh`'s
    /// single-surfaceID-per-model OBJ-import path, which would collapse
    /// every original triangle's real, individually-authored `surfaceID`
    /// down to one shared value and silently discard the level's own
    /// per-triangle surface variety (water/deadly/solid, etc.).
    static func buildTriggerTree(groups: [CollisionGroup], triangles: [CollisionTriangle], vertices: [SIMD4<Float>]) -> [CollisionTriggerBox] {
        guard !groups.isEmpty else { return [] }
        let tree = buildTree(groupCount: groups.count)

        var flat: [FlatNode] = []
        @discardableResult
        func preorder(_ node: TreeNode) -> Int {
            let myID = flat.count
            switch node {
            case .leaf(let groupIndex):
                flat.append(FlatNode(isLeaf: true, groupIndex: groupIndex, leftID: -1, rightID: -1))
            case .branch(let l, let r):
                flat.append(FlatNode(isLeaf: false, groupIndex: -1, leftID: -1, rightID: -1))
                let leftID = preorder(l)
                let rightID = preorder(r)
                flat[myID].leftID = leftID
                flat[myID].rightID = rightID
            }
            return myID
        }
        preorder(tree)

        var boxes = [CollisionTriggerBox?](repeating: nil, count: flat.count)
        func computeBox(_ id: Int) -> CollisionTriggerBox {
            if let existing = boxes[id] { return existing }
            let node = flat[id]
            let box: CollisionTriggerBox
            if node.isLeaf {
                let group = groups[node.groupIndex]
                var minV = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var maxV = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                let start = Int(group.offset), count = Int(group.size)
                for i in start..<(start + count) {
                    let tri = triangles[i]
                    for vi in [tri.vertexIndex1, tri.vertexIndex2, tri.vertexIndex3] {
                        let v = vertices[vi]
                        minV = simd_min(minV, SIMD3(v.x, v.y, v.z))
                        maxV = simd_max(maxV, SIMD3(v.x, v.y, v.z))
                    }
                }
                let encodedGroup = Int32(-(node.groupIndex + 1))
                box = CollisionTriggerBox(min: minV, flag1: encodedGroup, max: maxV, flag2: encodedGroup)
            } else {
                let l = computeBox(node.leftID)
                let r = computeBox(node.rightID)
                box = CollisionTriggerBox(min: simd_min(l.min, r.min), flag1: Int32(node.leftID), max: simd_max(l.max, r.max), flag2: Int32(node.rightID))
            }
            boxes[id] = box
            return box
        }
        for id in 0..<flat.count { _ = computeBox(id) }
        return (0..<flat.count).map { boxes[$0]! }
    }
}
