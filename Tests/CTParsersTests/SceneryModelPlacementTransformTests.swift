import XCTest
import simd
@testable import CTModels

/// Verifies `SceneryModelPlacement.worldTransform`'s decomposition against
/// hand-built matrices, independent of any GUI/visual check, which this
/// build can't automate.
///
/// `makeMatrix` builds the 4 on-disk rows as the algebraic inverse of
/// `worldTransform`'s own (corrected) formula, real, verified round-trip
/// coverage, but round-tripping through inverse formulas of the *same*
/// relationship can't by itself catch a *systematic* error shared by both
/// directions (this file's own history: several earlier versions of both
/// `worldTransform` and this exact helper independently made matching
/// mistakes, up to and including a formula that reproduced OpenTK's own
/// internal matrix bit-for-bit by hand trace and was still wrong, because
/// hand-tracing the matrix *construction* doesn't tell you which row/
/// column convention the vertex *transform* actually uses, every test
/// here passed anyway, every time).
/// `testNinetyDegreeYRotationMatchesHandComputedRawBytes` and
/// `testNinetyDegreeZRotationWithNonUniformScaleMatchesHandComputedRawBytes`
/// below exist specifically to close that gap: both build their input from
/// literal numbers hand-derived directly from the *current* (corrected)
/// formula, with no shared helper and no `simd_quatf`/`simd_float3x3`
/// construction on the input side at all. Note this makes these two tests
/// *not* independent of `worldTransform`'s own formula in the way earlier
/// versions of this doc comment claimed, after multiple rounds of a
/// self-consistent-but-wrong formula surviving hand-derived tests aimed at
/// the *previous* formula, that claim of independence wasn't actually
/// delivering what it promised. The real, load-bearing check against
/// getting this wrong again lives in `AdjacentTileRotationAlignmentTests`
/// and `CoordinateSystemRegressionTests` (real archive data, real mesh
/// geometry, checking actual edge alignment between real neighboring
/// placements), those don't depend on any assumption about which
/// direction is "correct," only on whether real geometry actually
/// connects, which is a property no self-consistent wrong formula can
/// fake (though even those have blind spots: symmetric/180°-symmetric
/// shapes can pass under a wrong formula too, see `worldTransform`'s own
/// doc comment).
final class SceneryModelPlacementTransformTests: XCTestCase {
    /// Builds the 4 on-disk rows from a known rotation/scale/translation,
    /// using the inverse of `SceneryModelPlacement.worldTransform`'s
    /// (corrected) formula: `worldTransform` uses the on-disk 3×3 block
    /// directly as the world rotation/scale matrix's *rows* (`col_j` reads
    /// component `j` down all three on-disk rows), and position as
    /// `(-row3.x, row3.y, row3.z)`. Inverting: `row_i = (basis.columns.0[i],
    /// basis.columns.1[i], basis.columns.2[i])` for i=0,1,2 (i.e. `row_i`
    /// is the rotation/scale matrix's `i`-th *row*, not column), and `row3
    /// = (-translation.x, translation.y, translation.z)`.
    /// Delegates to the real, public `SceneryModelPlacement.modelMatrix` , 
    /// this file's own hand-derived inverse formula, now promoted to a
    /// real API `LevelViewerRenderer.spawnScenery` uses so a newly-placed,
    /// rotated/scaled object actually saves that way instead of silently
    /// flattening to identity. Delegating here (rather than keeping a
    /// second, separately-maintained copy of the same formula) means every
    /// test below doubles as a check on that real function too.
    private func makeMatrix(rotation: simd_quatf, scale: SIMD3<Float>, translation: SIMD3<Float>) -> [SIMD4<Float>] {
        SceneryModelPlacement.composingModelMatrix(position: translation, rotation: rotation, scale: scale)
    }

    private func placement(matrix: [SIMD4<Float>]) -> SceneryModelPlacement {
        SceneryModelPlacement(modelID: 1, isSpecial: false, boundingBoxMin: .zero, boundingBoxMax: .zero, modelMatrix: matrix)
    }

    func testIdentityDecomposesToIdentity() throws {
        let matrix = makeMatrix(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3(1, 1, 1), translation: .zero)
        let transform = try XCTUnwrap(placement(matrix: matrix).worldTransform)
        XCTAssertEqual(transform.position, .zero, accuracy: 0.0001)
        XCTAssertEqual(transform.scale, SIMD3(1, 1, 1), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3(1, 0, 0)), SIMD3(1, 0, 0), accuracy: 0.0001)
    }

    func testTranslationOnlyPreservesPosition() throws {
        let expectedPosition = SIMD3<Float>(12.5, -4, 100)
        let matrix = makeMatrix(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3(1, 1, 1), translation: expectedPosition)
        let transform = try XCTUnwrap(placement(matrix: matrix).worldTransform)
        XCTAssertEqual(transform.position, expectedPosition, accuracy: 0.0001)
    }

    func testNonUniformScaleRecovered() throws {
        let expectedScale = SIMD3<Float>(2, 3, 4)
        let matrix = makeMatrix(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: expectedScale, translation: .zero)
        let transform = try XCTUnwrap(placement(matrix: matrix).worldTransform)
        XCTAssertEqual(transform.scale, expectedScale, accuracy: 0.0001)
    }

    /// The direct real-world motivation: a beach tile rotated 90° about Y
    /// must decode to a rotation that actually rotates a forward vector,
    /// not identity. Compared by rotating test vectors rather than
    /// comparing quaternion components directly, since `q` and `-q`
    /// represent the same rotation.
    func testNinetyDegreeYRotationRecovered() throws {
        let expectedRotation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        let matrix = makeMatrix(rotation: expectedRotation, scale: SIMD3(1, 1, 1), translation: .zero)
        let transform = try XCTUnwrap(placement(matrix: matrix).worldTransform)

        let probe = SIMD3<Float>(1, 0, 0)
        XCTAssertEqual(transform.rotation.act(probe), expectedRotation.act(probe), accuracy: 0.0001)
        let probe2 = SIMD3<Float>(0, 0, 1)
        XCTAssertEqual(transform.rotation.act(probe2), expectedRotation.act(probe2), accuracy: 0.0001)
    }

    func testCombinedRotationScaleTranslation() throws {
        let expectedRotation = simd_quatf(angle: .pi / 3, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.2)))
        let expectedScale = SIMD3<Float>(1.5, 0.75, 2.25)
        let expectedPosition = SIMD3<Float>(-50, 10, 300)
        let matrix = makeMatrix(rotation: expectedRotation, scale: expectedScale, translation: expectedPosition)
        let transform = try XCTUnwrap(placement(matrix: matrix).worldTransform)

        XCTAssertEqual(transform.position, expectedPosition, accuracy: 0.0001)
        XCTAssertEqual(transform.scale, expectedScale, accuracy: 0.0005)
        let probe = SIMD3<Float>(0.4, -0.6, 0.8)
        XCTAssertEqual(transform.rotation.act(probe), expectedRotation.act(probe), accuracy: 0.001)
    }

    /// Hand-derived directly from the *current* formula (on-disk 3×3 block
    /// used directly as the world matrix's rows, not its columns), see
    /// this file's own top-level doc comment for why this is no longer
    /// claimed to be independent of `worldTransform` itself. A 90°
    /// rotation about Y with uniform scale 2 sends local +X to world
    /// (0,0,-2), +Y to (0,2,0), +Z to (2,0,0) (standard right-handed
    /// convention, verified by hand), at world position (5,6,7). Scaled
    /// rotation columns: col0=(0,0,-2), col1=(0,2,0), col2=(2,0,0).
    /// `worldTransform` reads `col_j[i]` as `row_i[j]`, so `row0 =
    /// (col0.x, col1.x, col2.x) = (0,0,2)`, `row1 = (col0.y, col1.y,
    /// col2.y) = (0,2,0)`, `row2 = (col0.z, col1.z, col2.z) = (-2,0,0)`,
    /// and position `(5,6,7) = (-row3.x, row3.y, row3.z)` gives `row3 =
    /// (-5,6,7)`.
    func testNinetyDegreeYRotationMatchesHandComputedRawBytes() throws {
        let row0 = SIMD4<Float>(0, 0, 2, 0)
        let row1 = SIMD4<Float>(0, 2, 0, 0)
        let row2 = SIMD4<Float>(-2, 0, 0, 0)
        let row3 = SIMD4<Float>(-5, 6, 7, 1)
        let transform = try XCTUnwrap(placement(matrix: [row0, row1, row2, row3]).worldTransform)

        XCTAssertEqual(transform.position, SIMD3(5, 6, 7), accuracy: 0.0001)
        XCTAssertEqual(transform.scale, SIMD3(2, 2, 2), accuracy: 0.0001)
        // Direction only, scale divided out by simd_quatf acting on a unit vector.
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(1, 0, 0)), SIMD3<Float>(0, 0, -1), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(0, 1, 0)), SIMD3<Float>(0, 1, 0), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(0, 0, 1)), SIMD3<Float>(1, 0, 0), accuracy: 0.0001)
    }

    /// Second, independent-of-the-*first*-test hand-derivation, different
    /// axis (Z, not Y) and non-uniform scale, to catch a bug that only
    /// shows up when rotation and non-uniform scale interact (the test
    /// above uses uniform scale, which can't distinguish a correct
    /// per-column scale recovery from an accidentally-uniform one).
    ///
    /// A 90° rotation about Z with scale (3,1,1) applied in local space
    /// before rotation: local +X (scaled to length 3) rotates to world
    /// (0,3,0); local +Y (length 1) rotates to world (-1,0,0); local +Z
    /// (length 1, unaffected by a Z-axis rotation) stays world (0,0,1).
    /// Translation zero, kept separate from the rotation/scale check above.
    /// Scaled rotation columns: col0=(0,3,0), col1=(-1,0,0), col2=(0,0,1).
    /// `row0 = (col0.x, col1.x, col2.x) = (0,-1,0)`, `row1 = (col0.y,
    /// col1.y, col2.y) = (3,0,0)`, `row2 = (col0.z, col1.z, col2.z) =
    /// (0,0,1)`.
    func testNinetyDegreeZRotationWithNonUniformScaleMatchesHandComputedRawBytes() throws {
        let row0 = SIMD4<Float>(0, -1, 0, 0)
        let row1 = SIMD4<Float>(3, 0, 0, 0)
        let row2 = SIMD4<Float>(0, 0, 1, 0)
        let row3 = SIMD4<Float>(0, 0, 0, 1)
        let transform = try XCTUnwrap(placement(matrix: [row0, row1, row2, row3]).worldTransform)

        XCTAssertEqual(transform.position, .zero, accuracy: 0.0001)
        XCTAssertEqual(transform.scale, SIMD3(3, 1, 1), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(1, 0, 0)), SIMD3<Float>(0, 1, 0), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(0, 1, 0)), SIMD3<Float>(-1, 0, 0), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(0, 0, 1)), SIMD3<Float>(0, 0, 1), accuracy: 0.0001)
    }

    func testNilWhenMatrixTooShort() {
        let sparse = placement(matrix: [SIMD4<Float>(1, 0, 0, 0)])
        XCTAssertNil(sparse.worldTransform)
    }
}

private func XCTAssertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
}
