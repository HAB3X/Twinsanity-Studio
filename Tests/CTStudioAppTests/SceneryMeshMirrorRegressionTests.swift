import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Regression for a real, confirmed bug found this session: `ModelParser`/
/// `SkinParser` decoded raw mesh vertex/normal X straight off the VIF
/// stream, with no mirror -- but the reference tool's own mesh loader
/// (`ModelController.LoadMeshData`/`SkinController.LoadMeshData`) negates
/// each vertex's *local* X (and its normal's X) as a separate step from
/// any placement-level mirroring:
/// ```csharp
/// vtx.Add(new Vertex(new Vector3(-model.Vertexes[j].X, model.Vertexes[j].Y, model.Vertexes[j].Z), ...
/// ```
/// This is a *different* mirror from the already-established placement-
/// level one (`SceneryModelPlacement.worldTransform`,
/// `ModelViewerRenderer.mirroredWorldPosition`): it flips the mesh's own
/// local shape before any placement transform is even applied.
///
/// The bug was invisible on every symmetric mesh this codebase's earlier
/// real-data regressions happened to exercise (a square floor tile
/// mirrored under X looks identical) -- it only shows up on genuinely
/// asymmetric geometry, exactly the "curved tunnel segment" case a user
/// directly reported after comparing against the live reference tool:
/// real cave-tunnel scenery pieces (`Levels/Earth/Cavern/tunnel01.sm2`)
/// that sat at the right position with the right yaw, but curved the
/// *opposite* direction from their neighbor, so a whole winding corridor
/// read as scattered, disconnected segments -- confirmed by rendering the
/// real level offscreen through the actual production pipeline before and
/// after this fix (see git history around this file's introduction).
///
/// A same-mesh nearest-vertex-anywhere check (the technique that caught
/// the earlier placement-rotation bugs) is *not* sensitive to this one:
/// mirroring keeps every vertex within roughly the same bounding volume,
/// so "is some vertex close to some other vertex" barely changes. Even a
/// "is this mesh symmetric under X" check isn't reliable here -- this
/// tube's local *cross-section* is bilaterally symmetric (so that specific
/// check is invariant to the mirror either way) even though its *curve
/// trajectory* isn't, which is exactly the property that actually breaks
/// when the mirror is missing. The one technique that verified sensitive
/// against this exact bug this session (confirmed by reverting the fix
/// and watching it fail, then restoring it and watching it pass) is a
/// real, hand-verified golden vertex value below.
@MainActor
final class SceneryMeshMirrorRegressionTests: XCTestCase {
    private static let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")
    /// The real curved tube segment from this session's investigation --
    /// asymmetric under X (confirmed below), placed repeatedly along
    /// tunnel01's winding corridor, exactly the shape a missing mesh-local
    /// mirror bends the wrong way.
    private static let curvedTubeModelID: UInt32 = 2964649357

    private func resolveTubeMesh() throws -> ResolvedModelAsset {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Real disc image not present")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)
        guard let smEntry = index.entries.first(where: { $0.name == "Levels/Earth/Cavern/tunnel01.sm2" }) else {
            throw XCTSkip("tunnel01.sm2 not found")
        }
        let smRoot = try RM2Parser.parse(data: try BDArchiveParser.readEntryData(smEntry, index: index), fileKind: .sm2, fileName: smEntry.name)
        let assetIndex = AssetResolver.buildIndex(fileRoot: smRoot)
        guard let resolved = AssetResolver.resolveModelID(Self.curvedTubeModelID, displayName: "tube", index: assetIndex) else {
            throw XCTSkip("curved tube modelID not present in this archive snapshot")
        }
        return resolved
    }

    /// A real, hand-verified vertex from the curved tube mesh's first
    /// submesh -- with the mesh-local X mirror applied, its X is
    /// *positive* (`0.1128`); without the mirror (the bug this regresses),
    /// decoding this exact archive produces `-0.1128` instead. Real
    /// archive data, not synthetic -- if the on-disk bytes for this model
    /// ever change, this test needs re-deriving against the new data, same
    /// as any other golden-value test in this codebase.
    func testFirstVertexOfRealCurvedTubeMeshHasTheMirroredXSign() throws {
        let resolved = try resolveTubeMesh()
        let firstSubmesh = try XCTUnwrap(resolved.mesh.submeshes.first)
        let vertex = try XCTUnwrap(firstSubmesh.vertices.first)
        XCTAssertEqual(vertex.position.x, 0.11279303, accuracy: 0.0001)
        XCTAssertEqual(vertex.position.y, 0.72026914, accuracy: 0.0001)
        XCTAssertEqual(vertex.position.z, 0.46804047, accuracy: 0.0001)
    }
}
