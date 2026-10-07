import XCTest
import AppKit
@testable import CTStudioApp
@testable import CTModels
@testable import CTParsers

/// End-to-end verification of "Cross-Engine Texture Variant": a real
/// Twinsanity crate's own real, working UVs, with a real Wrath of Cortex
/// texture's real pixels substituted in, drives the exact real public
/// pipeline (`WorkspaceViewModel.loadWOCCrateTextureLibrary`,
/// `ResolvedModelAsset.applyingTextureOverride(_:)`) the Inspector's
/// "Cross-Engine Texture Variant" panel uses, against real bytes from
/// both real discs, not synthetic fixtures.
@MainActor
final class CrossEngineTextureVariantEndToEndTests: XCTestCase {
    private static let twinsanityBHPath = "/Volumes/Untitled/CRASH6/CRASH.BH"
    private static let wocCratesGSCPath = "/Volumes/CRASH/STUFF/CRATES.GSC"

    func testRealWoCTextureAppliesCorrectlyToRealTwinsanityCrateUVs() async throws {
        guard FileManager.default.fileExists(atPath: Self.twinsanityBHPath) else {
            throw XCTSkip("Real Twinsanity archive not mounted at \(Self.twinsanityBHPath)")
        }
        guard FileManager.default.fileExists(atPath: Self.wocCratesGSCPath) else {
            throw XCTSkip("Real WoC disc image not mounted at \(Self.wocCratesGSCPath)")
        }

        // Resolve a real Twinsanity crate (BASICCRATE, object #3) from the
        // real shared resource file, the same real chain the crate render
        // work earlier this session used.
        let bhURL = URL(fileURLWithPath: Self.twinsanityBHPath)
        let archiveIndex = try BDArchiveParser.readIndex(bhURL: bhURL)
        let entry = try XCTUnwrap(archiveIndex.entries.first { $0.name == "Startup/Default.rm2" })
        let data = try BDArchiveParser.readEntryData(entry, index: archiveIndex)
        let fileRoot = try RM2Parser.parse(data: data, fileKind: .rm2, fileName: "Default.rm2")

        let index = AssetResolver.buildIndex(fileRoot: fileRoot)
        let basicCrate = try XCTUnwrap(
            AssetResolver.resolveInstanceObject(objectID: 3, instanceSelector: 0, index: index),
            "BASICCRATE (object #3) should resolve to a real object from real Startup/Default.rm2 bytes"
        )
        XCTAssertFalse(basicCrate.mesh.submeshes.isEmpty)
        XCTAssertTrue(basicCrate.isFullyTextured, "the real, un-overridden BASICCRATE should already be fully textured with its own real Twinsanity texture")

        // Load the real WoC crate texture library from real CRATES.GSC
        // bytes -- the exact public WorkspaceViewModel entry point the
        // Inspector's "Load WoC Crate Textures…" button calls.
        let workspace = WorkspaceViewModel()
        workspace.loadWOCCrateTextureLibrary(from: URL(fileURLWithPath: Self.wocCratesGSCPath))
        // Real, reported bug in this *test*, not in `loadWOCCrateTextureLibrary`
        // itself: that function is intentionally fire-and-forget (kicks off a
        // detached `Task` and returns immediately, see its own doc comment)
        // so the UI thread never blocks on RNC-decompressing a multi-megabyte
        // file. Asserting on `wocCrateTextureLibrary` right after calling it,
        // with no wait at all, was a real race, it read the array before the
        // background Task had any chance to populate it, always seeing 0 and
        // then crashing on `wocCrateTextureLibrary[0]` below. Poll for real
        // completion instead, same pattern this codebase's other
        // detached-Task tests already use.
        for _ in 0..<600 where workspace.wocCrateTextureLibrary.isEmpty && workspace.lastError == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(workspace.lastError, "loading real WoC textures should succeed")
        XCTAssertGreaterThan(workspace.wocCrateTextureLibrary.count, 0, "CRATES.GSC should yield real decoded textures")

        // Apply the override -- the exact call the Inspector's picker makes.
        let wocTexture = workspace.wocCrateTextureLibrary[0].texture
        let overridden = basicCrate.applyingTextureOverride(wocTexture)

        // Real structural guarantees: geometry/skeleton/animations
        // untouched, only the texture pixel data changed.
        XCTAssertEqual(overridden.mesh.submeshes.count, basicCrate.mesh.submeshes.count)
        XCTAssertEqual(overridden.recordID, basicCrate.recordID)
        for material in overridden.submeshMaterials {
            XCTAssertEqual(material.texture?.rgba, wocTexture.rgba)
        }
        // Revert (nil override), applied the same way the real UI does --
        // from the pristine `basicCrate`, never from the already-
        // overridden copy (which, by design, no longer has the original
        // texture to go back to) -- must restore every submesh's own
        // original texture exactly.
        let reverted = basicCrate.applyingTextureOverride(nil)
        for (i, material) in reverted.submeshMaterials.enumerated() {
            XCTAssertEqual(material.texture?.rgba, basicCrate.submeshMaterials[i].texture?.rgba)
        }

        // Real visual proof: render the overridden asset and save a PNG,
        // the same offscreen Metal path used elsewhere this session,
        // looked at directly before calling this done.
        guard let renderer = ModelViewerRenderer(asset: overridden), renderer.hasGeometry,
              let cgImage = renderer.renderOffscreen(width: 512, height: 512)
        else {
            XCTFail("expected real drawable geometry for the overridden BASICCRATE")
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        if let pngData = bitmap.representation(using: .png, properties: [:]) {
            let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("cross_engine_texture_variant_render.png")
            try? pngData.write(to: outURL)
        }

        // Also render the ORIGINAL (un-overridden) crate for a real
        // side-by-side comparison.
        if let originalRenderer = ModelViewerRenderer(asset: basicCrate), originalRenderer.hasGeometry,
           let originalImage = originalRenderer.renderOffscreen(width: 512, height: 512) {
            let originalBitmap = NSBitmapImageRep(cgImage: originalImage)
            if let pngData = originalBitmap.representation(using: .png, properties: [:]) {
                let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("cross_engine_texture_variant_original_render.png")
                try? pngData.write(to: outURL)
            }
        }
    }
}
