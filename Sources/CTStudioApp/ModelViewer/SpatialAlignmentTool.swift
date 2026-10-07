import simd

/// "Align & Distribute": pure position math for the Level Viewer's batch
/// position edit (`LevelViewerWindow`'s Align/Distribute menu, wired
/// through `LevelViewerRenderer.setPositions`). Operates on plain
/// `SIMD3<Float>`, the same representation `LevelViewerRenderer.
/// GPULevelObject.worldPosition` already uses for every live position edit
/// in this app (gizmo drag, nudge fields, `setSelectedPosition`), not
/// `PlacedInstance.position`'s `SIMD4<Float>`: every existing transform-edit
/// path in this codebase already drops the `w` component before touching a
/// position in memory and only reattaches the record's original `w`
/// (`GPULevelObject.originalPositionW`) at encode time
/// (`LevelViewerRenderer.pendingLevelOverrides`), so matching that same
/// split here, rather than threading a `w` this logic never reads or
/// writes, avoids a value this tool would otherwise have to either fake
/// or ignore.
///
/// No SwiftUI/AppKit dependency, no renderer/document access, a free
/// function over arrays, directly unit-testable (`SpatialAlignmentToolTests`).
enum SpatialAlignmentTool {
    enum Axis: CaseIterable {
        case x, y, z
    }

    enum AlignMode: CaseIterable {
        case min, max, center
    }

    /// Snaps every position's value on `axis` to the min, max, or average
    /// ("center") value across the whole input set; the other two axes are
    /// left untouched. Order-preserving: `result[i]` corresponds to
    /// `positions[i]`.
    static func align(_ positions: [SIMD3<Float>], axis: Axis, mode: AlignMode) -> [SIMD3<Float>] {
        guard !positions.isEmpty else { return positions }
        let values = positions.map { component(of: $0, axis: axis) }
        let target: Float
        switch mode {
        case .min: target = values.min()!
        case .max: target = values.max()!
        case .center: target = values.reduce(0, +) / Float(values.count)
        }
        return positions.map { setting(component: target, axis: axis, on: $0) }
    }

    /// Evenly spaces every position between the two current extremes (min
    /// and max value) on `axis`, preserving each item's existing relative
    /// order along that axis, the item currently smallest on `axis` lands
    /// on the new minimum, the current largest lands on the new maximum
    /// (both unchanged in this case), and everything else is interpolated
    /// by rank in between. Order-preserving in the same sense as `align`:
    /// `result[i]` is item `i`'s *new* position, not resorted, only the
    /// *value* assigned to each item follows its rank, not its array index.
    ///
    /// A single item, or every item already sharing the same value on
    /// `axis`, is returned unchanged rather than divided-by-zero into NaN:
    /// with one item there's nothing to spread between, and with a
    /// zero-width span every rank's interpolated value collapses back to
    /// that same shared value anyway (`min + 0 * t == min`), so the only
    /// real hazard is the `count - 1 == 0` denominator for a single item,
    /// guarded explicitly below.
    static func distribute(_ positions: [SIMD3<Float>], axis: Axis) -> [SIMD3<Float>] {
        guard positions.count > 1 else { return positions }
        let values = positions.map { component(of: $0, axis: axis) }
        let minValue = values.min()!
        let maxValue = values.max()!
        let rankOrder = positions.indices.sorted { lhs, rhs in
            values[lhs] != values[rhs] ? values[lhs] < values[rhs] : lhs < rhs
        }
        let span = maxValue - minValue
        let lastRank = Float(positions.count - 1)
        var result = positions
        for (rank, originalIndex) in rankOrder.enumerated() {
            let t = Float(rank) / lastRank
            result[originalIndex] = setting(component: minValue + span * t, axis: axis, on: positions[originalIndex])
        }
        return result
    }

    private static func component(of position: SIMD3<Float>, axis: Axis) -> Float {
        switch axis {
        case .x: return position.x
        case .y: return position.y
        case .z: return position.z
        }
    }

    private static func setting(component value: Float, axis: Axis, on position: SIMD3<Float>) -> SIMD3<Float> {
        var result = position
        switch axis {
        case .x: result.x = value
        case .y: result.y = value
        case .z: result.z = value
        }
        return result
    }
}
