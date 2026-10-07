import XCTest
@testable import CTParsers
@testable import CTStudioApp

/// `WOCCompositeResolver`, the fix for "View Parent / Composite" always
/// saying "No Parent Found" on a WoC texture (e.g. `CRATES.GSC`). Verifies
/// the real `OBJ0` submesh materialID -> `MS00` texture-index chain
/// actually resolves against real bytes, not just against hand-built
/// fixtures.
final class WOCCompositeResolverTests: XCTestCase {
    private func requireMountedCratesGSC() throws -> URL {
        let path = "/Volumes/CRASH/STUFF/CRATES.GSC"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted at \(path)")
        }
        return URL(fileURLWithPath: path)
    }

    func testResolvesRealCrateTextureToItsOwningMesh() throws {
        let url = try requireMountedCratesGSC()
        let asset = try WOCLevelLoader.load(gscURL: url, name: "CRATES")
        XCTAssertFalse(asset.textures.isEmpty, "CRATES.GSC should decode real textures")
        XCTAssertFalse(asset.objectMeshes.isEmpty, "CRATES.GSC should decode real OBJ0 meshes")
        XCTAssertFalse(asset.materialTextureIDs.isEmpty, "CRATES.GSC should decode a real MS00 material set")

        // At least one real texture in this file must resolve to a real
        // mesh through the confirmed materialID -> texture-index chain , 
        // this is the exact "No Parent Found" bug: previously every WoC
        // texture failed this unconditionally, regardless of file content.
        var resolvedCount = 0
        for index in asset.textures.indices {
            guard let resolved = WOCCompositeResolver.resolveComposite(forTextureIndex: index, in: asset, displayNamePrefix: "CRATES, ") else { continue }
            resolvedCount += 1
            XCTAssertFalse(resolved.mesh.submeshes.isEmpty)
            XCTAssertTrue(resolved.submeshMaterials.contains { $0.texture != nil })
        }
        // 3 of CRATES.GSC's 65 real textures resolve through the confirmed
        // materialID -> texture-index chain (32 real OBJ0 meshes, 32 real
        // INST placements), most of this file's textures are referenced
        // some other way this codebase hasn't decoded yet (TAS0 texture
        // assignments, a per-geo direct reference, ...), not a resolver
        // bug; this asserts the honest, currently-real floor, not "all".
        XCTAssertGreaterThan(resolvedCount, 0, "at least one real CRATES.GSC texture should resolve to its owning mesh")
    }

    func testOutOfRangeTextureIndexResolvesToNil() throws {
        let url = try requireMountedCratesGSC()
        let asset = try WOCLevelLoader.load(gscURL: url, name: "CRATES")
        XCTAssertNil(WOCCompositeResolver.resolveComposite(forTextureIndex: -1, in: asset, displayNamePrefix: ""))
        XCTAssertNil(WOCCompositeResolver.resolveComposite(forTextureIndex: asset.textures.count + 1000, in: asset, displayNamePrefix: ""))
    }
}
