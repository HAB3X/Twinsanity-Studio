import XCTest
import AppKit
@testable import CTStudioApp
@testable import CTModels

/// End-to-end repro/fix verification for the "No Parent Found" bug on a
/// WoC texture (e.g. `CRATES.GSC`), drives the exact same *public*
/// `WorkspaceViewModel` surface the real UI does: `mountDiscImage(url:)`
/// (what "Mount Disc Image…" calls), `select(_:)` (what a sidebar click
/// calls), and `resolveComposite(for:)` (what the "View Parent /
/// Composite" toggle calls), no shortcuts through internal/private
/// plumbing, so a pass here means the actual reported bug is actually
/// fixed, not just that the underlying resolver logic works in isolation
/// (see `WOCCompositeResolverTests` for that narrower check).
@MainActor
final class WOCTextureParentResolutionEndToEndTests: XCTestCase {
    private static let isoPath = "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/Crash Bandicoot - The Wrath of Cortex (Europe) (EnFrDeEsItNl) (v1/Crash Bandicoot - The Wrath of Cortex (Europe) (En,Fr,De,Es,It,Nl) (v1.03) [ISO9660].iso"

    func testCratesGSCTextureResolvesItsParentThroughTheRealPublicPipeline() async throws {
        guard FileManager.default.fileExists(atPath: Self.isoPath) else {
            throw XCTSkip("Real Wrath of Cortex ISO not present at \(Self.isoPath)")
        }
        let workspace = WorkspaceViewModel()
        workspace.mountDiscImage(url: URL(fileURLWithPath: Self.isoPath))
        XCTAssertNil(workspace.lastError, "mounting the real WoC ISO should succeed")

        guard let cratesNode = Self.findNode(named: "CRATES.GSC", in: workspace.rootNodes) else {
            throw XCTSkip("CRATES.GSC not found in this disc image's tree")
        }

        // Same call a sidebar click makes, kicks off the real async
        // WOCDiscTreeBuilder expansion internally.
        workspace.select(cratesNode)

        var expanded: ChunkNode?
        for _ in 0..<600 {
            if let selected = workspace.selectedNode,
               selected.children.contains(where: { $0.displayName.hasPrefix("Textures (") }) {
                expanded = selected
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let expandedNode = try XCTUnwrap(expanded, "CRATES.GSC should finish expanding into a real tree within 60s")

        let texturesFolder = try XCTUnwrap(
            expandedNode.children.first { $0.displayName.hasPrefix("Textures (") },
            "expanded CRATES.GSC tree should have a Textures folder"
        )
        XCTAssertFalse(texturesFolder.children.isEmpty, "CRATES.GSC should decode real texture leaves")

        var resolvedCount = 0
        var firstResolved: ResolvedModelAsset?
        for textureNode in texturesFolder.children {
            if let resolved = workspace.resolveComposite(for: textureNode) {
                resolvedCount += 1
                if firstResolved == nil { firstResolved = resolved }
            }
        }
        XCTAssertGreaterThan(
            resolvedCount, 0,
            "at least one real CRATES.GSC texture should resolve its parent through the exact call InspectorView's \"View Parent / Composite\" toggle makes"
        )

        // Real visual proof, not just a boolean: the exact offscreen Metal
        // path `CompositePreviewView`/`ModelThumbnailRenderer` uses,
        // rendering the first real resolved object to a PNG on disk so it
        // can actually be looked at.
        if let firstResolved,
           let renderer = ModelViewerRenderer(asset: firstResolved), renderer.hasGeometry,
           let cgImage = renderer.renderOffscreen(width: 512, height: 512) {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if let pngData = bitmap.representation(using: .png, properties: [:]) {
                let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("woc_crate_parent_render.png")
                try? pngData.write(to: outURL)
            }
        }
    }

    private static func findNode(named name: String, in nodes: [ChunkNode]) -> ChunkNode? {
        for node in nodes {
            if node.displayName == name { return node }
            if let found = findNode(named: name, in: node.children) { return found }
        }
        return nil
    }
}
