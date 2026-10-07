import XCTest
import simd
@testable import CTModels

/// `SceneryGroup.insertingPlacementNearestExistingNeighbor`, real, reported
/// bug: a freshly-placed scenery object always went straight into the
/// tree's own top-level root, regardless of where in the level it actually
/// is, bypassing whatever real, dev-authored spatial grouping every real
/// placement nearby already has. See that method's own doc comment for the
/// full reasoning (undecoded `SceneryModelGroup.unkPos` group-level bounds
/// data this project has never verified the meaning of).
final class SceneryGroupInsertionTests: XCTestCase {
    private func makePlacement(x: Float, fileOffset: Int?, isSpecial: Bool = false) -> SceneryModelPlacement {
        // Row 3 is the translation column (`SceneryModelPlacement.translation`'s
        // own doc comment), identity rotation/scale in the other three rows.
        let matrix: [SIMD4<Float>] = [
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(x, 0, 0, 1),
        ]
        return SceneryModelPlacement(
            modelID: 1, isSpecial: isSpecial,
            boundingBoxMin: SIMD4(x - 1, -1, -1, 1), boundingBoxMax: SIMD4(x + 1, 1, 1, 1),
            modelMatrix: matrix, matrixFileOffset: fileOffset
        )
    }

    /// A root with one direct placement far away (x=1000), and one nested
    /// child group with a placement close to where the new object will
    /// land (x=0), the real, structural shape a level's real, spatially-
    /// partitioned scenery tree has.
    private func makeTwoGroupTree() -> SceneryGroup {
        let rootPlacement = makePlacement(x: 1000, fileOffset: 1)
        let childPlacement = makePlacement(x: 0, fileOffset: 2)
        let childGroup = SceneryGroup(model: SceneryModelGroup(header: 0x1613, placements: [childPlacement]), links: [])
        return SceneryGroup(model: SceneryModelGroup(header: 0x1613, placements: [rootPlacement]), links: [.group(childGroup)])
    }

    func testNewPlacementLandsInTheNestedGroupOfItsNearestRealNeighbor() throws {
        let tree = makeTwoGroupTree()
        let newPlacement = makePlacement(x: 1, fileOffset: nil) // fileOffset irrelevant for a not-yet-saved placement
        let result = tree.insertingPlacementNearestExistingNeighbor(newPlacement, targetPosition: SIMD3(1, 0, 0))

        // Must NOT have been dumped into the root's own direct list.
        XCTAssertEqual(result.model.placements.count, 1, "root's own direct placements must be untouched, the new one belongs in the nested group near its real neighbor")
        XCTAssertEqual(result.model.placements.first?.modelMatrix.count, 4)

        // Must have landed in the nested child group instead.
        guard case .group(let child)? = result.links.first else {
            return XCTFail("expected the child .group link to survive")
        }
        XCTAssertEqual(child.model.placements.count, 2, "the nested group nearest the new placement's real position must have gained it")
        XCTAssertTrue(child.model.placements.contains { $0.translation == SIMD3<Float>(1, 0, 0) }, "the new placement's own real position must be preserved")

        // Nothing lost anywhere in the tree.
        XCTAssertEqual(result.flattenedPlacements().count, 3, "every placement (2 real + 1 new) must still be reachable")
    }

    func testNewPlacementLandsAtRootWhenItsNearestRealNeighborIsThere() throws {
        let tree = makeTwoGroupTree()
        let newPlacement = makePlacement(x: 999, fileOffset: nil)
        let result = tree.insertingPlacementNearestExistingNeighbor(newPlacement, targetPosition: SIMD3(999, 0, 0))

        XCTAssertEqual(result.model.placements.count, 2, "nearest real neighbor (x=1000) lives at the root, so the new placement belongs there too")
        guard case .group(let child)? = result.links.first else {
            return XCTFail("expected the child .group link to survive")
        }
        XCTAssertEqual(child.model.placements.count, 1, "the unrelated nested group must be untouched")
        XCTAssertEqual(result.flattenedPlacements().count, 3)
    }

    /// A `.modelGroup` link (a leaf collection, not a further-nested
    /// `.group`) must be searched and inserted into the same way.
    func testNewPlacementLandsInAModelGroupLeafWhenThatsTheNearestNeighbor() throws {
        let rootPlacement = makePlacement(x: 1000, fileOffset: 1)
        let leafPlacement = makePlacement(x: 0, fileOffset: 2)
        let leafGroup = SceneryModelGroup(header: 0x1613, placements: [leafPlacement])
        let tree = SceneryGroup(model: SceneryModelGroup(header: 0x1613, placements: [rootPlacement]), links: [.modelGroup(leafGroup)])

        let newPlacement = makePlacement(x: 1, fileOffset: nil)
        let result = tree.insertingPlacementNearestExistingNeighbor(newPlacement, targetPosition: SIMD3(1, 0, 0))

        XCTAssertEqual(result.model.placements.count, 1, "root untouched")
        guard case .modelGroup(let leaf)? = result.links.first else {
            return XCTFail("expected the .modelGroup link to survive")
        }
        XCTAssertEqual(leaf.placements.count, 2, "the modelGroup leaf nearest the new placement must have gained it")
        XCTAssertEqual(result.flattenedPlacements().count, 3)
    }

    /// An empty tree (no real placement anywhere to compare against) must
    /// still succeed, falls back to the same always-root behavior this
    /// project used before this fix existed, rather than losing the
    /// placement or crashing.
    func testFallsBackToRootWhenTreeHasNoExistingPlacementAtAll() throws {
        let emptyTree = SceneryGroup(model: SceneryModelGroup(header: 0x1613, placements: []), links: [])
        let newPlacement = makePlacement(x: 5, fileOffset: nil)
        let result = emptyTree.insertingPlacementNearestExistingNeighbor(newPlacement, targetPosition: SIMD3(5, 0, 0))
        XCTAssertEqual(result.model.placements.count, 1)
        XCTAssertEqual(result.flattenedPlacements().count, 1)
    }
}
