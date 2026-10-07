import XCTest
@testable import CTModels

/// Regression test for "Critical Filter Bug Fix": clicking a filtered
/// sidebar row used to deselect everything instead of opening the clicked
/// asset. Root cause was `ChunkNode.filtered(matching:)`/`filtered(byKind:)`
/// minting a fresh random `UUID()` for every filtered node on every call , 
/// since `WorkspaceViewModel.filteredRootNodes` is an uncached computed
/// property, the id a click captured when the sidebar rendered never
/// matched the id produced by the *next* evaluation of the same filter
/// inside the selection handler. This tests the fix directly at the source
/// (`ChunkNode` itself), independent of any SwiftUI/AppKit plumbing.
final class ChunkNodeFilterTests: XCTestCase {
    private func makeTree() -> ChunkNode {
        let texture = ChunkNode(recordID: 1, sectionType: .texture, displayName: "Texture #1", byteSize: 100, fileOffset: 0, payload: nil)
        let meshAsset = MeshAsset(id: 2, isSkinned: false, submeshes: [])
        let mesh = ChunkNode(recordID: 2, sectionType: .mesh, displayName: "Mesh #2", byteSize: 200, fileOffset: 100, payload: .mesh(meshAsset))
        let root = ChunkNode(recordID: 0, sectionType: .null, displayName: "Root", byteSize: 0, fileOffset: 0, children: [texture, mesh])
        return root
    }

    /// The exact bug scenario: filter, then look up a node's id in the
    /// filtered tree, then, simulating the sidebar's `List(selection:)`
    /// evaluating `filteredRootNodes` a *second*, independent time inside
    /// its selection `Binding`'s `set` closure, filter again from
    /// scratch and confirm the same id still resolves to the same
    /// underlying node.
    func testFilteredMatchingPreservesIdentityAcrossRepeatedCalls() throws {
        let root = makeTree()
        let originalTextureID = root.children[0].id

        let firstFilterPass = try XCTUnwrap(root.filtered(matching: "Texture"))
        let idSeenBySidebar = try XCTUnwrap(firstFilterPass.children.first).id
        XCTAssertEqual(idSeenBySidebar, originalTextureID, "a filtered node must keep the real node's identity, not invent a new one")

        // Re-run the filter from scratch (a fresh `filteredRootNodes`
        // evaluation, exactly like the selection Binding's `set` triggers).
        let secondFilterPass = try XCTUnwrap(root.filtered(matching: "Texture"))
        let idSeenOnClick = try XCTUnwrap(secondFilterPass.children.first).id

        XCTAssertEqual(idSeenBySidebar, idSeenOnClick, "the same id must resolve across independent filter evaluations, or a click can never find its own node")
    }

    func testFilteredByKindPreservesIdentityAcrossRepeatedCalls() throws {
        let root = makeTree()
        let originalMeshID = root.children[1].id

        let firstFilterPass = try XCTUnwrap(root.filtered(byKind: .model))
        let secondFilterPass = try XCTUnwrap(root.filtered(byKind: .model))

        let idFromFirst = try XCTUnwrap(firstFilterPass.children.first).id
        let idFromSecond = try XCTUnwrap(secondFilterPass.children.first).id

        XCTAssertEqual(idFromFirst, originalMeshID)
        XCTAssertEqual(idFromFirst, idFromSecond)
    }

    /// The unfiltered root itself (`filtered(matching: "")`) already
    /// preserved identity via its `guard !query.isEmpty else { return self }`
    /// short-circuit, this just pins that the fix didn't disturb that path.
    func testEmptyQueryReturnsSameInstance() {
        let root = makeTree()
        XCTAssertTrue(root.filtered(matching: "") === root)
    }

    // MARK: - "Smart File Filtering"

    func testPrunedOfRawContentDropsUndecodedLeafAndKeepsDecodedOne() throws {
        let root = makeTree() // texture: payload nil (raw/undecoded); mesh: real .mesh payload
        let pruned = try XCTUnwrap(root.prunedOfRawContent())
        XCTAssertEqual(pruned.children.count, 1)
        XCTAssertEqual(pruned.children.first?.id, root.children[1].id, "the decoded mesh leaf should survive; the undecoded texture leaf should not")
    }

    func testPrunedOfRawContentDropsFolderThatOnlyContainsRawContent() {
        let rawOnly1 = ChunkNode(recordID: 1, sectionType: .texture, displayName: "Raw #1", byteSize: 10, fileOffset: 0, payload: nil)
        let rawOnly2 = ChunkNode(recordID: 2, sectionType: .texture, displayName: "Raw #2", byteSize: 10, fileOffset: 10, payload: .raw(byteCount: 10))
        let deadEndFolder = ChunkNode(recordID: 0, sectionType: .null, displayName: "DeadEnd", byteSize: 0, fileOffset: 0, children: [rawOnly1, rawOnly2])
        let root = ChunkNode(recordID: 0, sectionType: .null, displayName: "Root", byteSize: 0, fileOffset: 0, children: [deadEndFolder])

        XCTAssertNil(root.prunedOfRawContent(), "a folder containing only raw/undecoded leaves should itself disappear, not just its children")
    }

    /// The critical edge case: an *unexpanded* archive entry (`.RM2` inside
    /// a `.BH`, not yet parsed) is indistinguishable from a genuinely
    /// uninteresting leaf by shape alone (`children.isEmpty`,
    /// `payload == nil`), the only thing that tells them apart is that
    /// this one is a real file with a chunk-like name and a non-zero size,
    /// still waiting for its own "Parse" click. Pruning it away would hide
    /// every unscanned archive's entire contents behind Smart Filtering.
    func testPrunedOfRawContentKeepsUnexpandedArchiveEntries() throws {
        let unexpanded = ChunkNode(recordID: 0, sectionType: .null, displayName: "Levels/AltEarth/Hub/alttunl.rm2", byteSize: 45000, fileOffset: 0, payload: nil)
        let archiveRoot = ChunkNode(recordID: 0, sectionType: .null, displayName: "CRASH.BH (1 files)", byteSize: 0, fileOffset: 0, children: [unexpanded])

        let pruned = try XCTUnwrap(archiveRoot.prunedOfRawContent())
        XCTAssertEqual(pruned.children.count, 1)
        XCTAssertEqual(pruned.children.first?.id, unexpanded.id)
        XCTAssertEqual(pruned.children.first?.displayName, "Levels/AltEarth/Hub/alttunl.rm2")
    }

    func testPrunedOfRawContentPreservesIdentityOfSurvivingContainer() throws {
        let root = makeTree()
        let pruned = try XCTUnwrap(root.prunedOfRawContent())
        XCTAssertEqual(pruned.id, root.id, "a surviving container node must keep the original's identity too, not just its leaves")
    }
}
