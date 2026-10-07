import XCTest
@testable import CTModels
@testable import CTStudioApp

/// "Forge Palette anywhere": `GlobalObjectResolutionCache`'s own status-
/// transition bookkeeping, tested independent of any real archive/disc , 
/// the actual disc-wide search it drives (`WorkspaceViewModel.
/// resolvingObjectIDAcrossAllLevels`) is exercised separately against the
/// real archive in `WorkspaceViewModelIntegrationTests`.
@MainActor
final class GlobalObjectResolutionCacheTests: XCTestCase {
    func testStatusForNeverSearchedObjectIDIsNil() {
        let cache = GlobalObjectResolutionCache()
        XCTAssertNil(cache.status(for: 42))
    }

    /// `search` must mark the object as `.searching` synchronously, before
    /// its background `Task` even gets a chance to run, otherwise a palette
    /// row would flash the "confirmed nowhere" placeholder (or nothing at
    /// all) for a moment right after a search starts, instead of the
    /// distinct "still checking" spinner the mandate specifically asks for.
    func testSearchMarksStatusAsSearchingSynchronously() {
        let cache = GlobalObjectResolutionCache()
        let workspace = WorkspaceViewModel()
        cache.search(objectID: 42, workspace: workspace)
        XCTAssertEqual(cache.status(for: 42), .searching)
    }

    /// A workspace with no archives open at all has zero real candidates to
    /// search, this should resolve to "confirmed nowhere" quickly rather
    /// than hang, and is a real (if degenerate) exercise of the same code
    /// path a genuinely-nowhere object ID takes on a real disc.
    func testSearchOnAWorkspaceWithNoArchivesEventuallyConfirmsNowhere() {
        let cache = GlobalObjectResolutionCache()
        let workspace = WorkspaceViewModel()
        cache.search(objectID: 42, workspace: workspace)

        let expectation = expectation(description: "search resolves to confirmedNowhere")
        fulfill(expectation, whenTrue: { cache.status(for: 42) == .confirmedNowhere })
        wait(for: [expectation], timeout: 10)
    }

    /// Calling `search` again for an object ID that's still mid-search must
    /// be a pure no-op, this is what stops a beginner scrolling the palette
    /// up and down from starting a second, redundant disc-wide scan for the
    /// same ID while the first one is still running.
    func testCallingSearchAgainWhileAlreadySearchingIsANoOp() {
        let cache = GlobalObjectResolutionCache()
        let workspace = WorkspaceViewModel()
        cache.search(objectID: 42, workspace: workspace)
        XCTAssertEqual(cache.status(for: 42), .searching)
        cache.search(objectID: 42, workspace: workspace)
        XCTAssertEqual(cache.status(for: 42), .searching)
    }

    /// Calling `search` again once an object ID is already confirmed nowhere
    /// must not flip the status back to `.searching`, a real, permanently-
    /// unresolvable object ID (see `WorkspaceViewModel.
    /// confirmedUnresolvableObjectIDs`'s own doc comment) must never
    /// re-trigger a full disc scan just because its row scrolled back into
    /// view.
    func testCallingSearchAgainAfterConfirmedNowhereIsANoOp() {
        let cache = GlobalObjectResolutionCache()
        let workspace = WorkspaceViewModel()
        cache.search(objectID: 42, workspace: workspace)

        let expectation = expectation(description: "search resolves to confirmedNowhere")
        fulfill(expectation, whenTrue: { cache.status(for: 42) == .confirmedNowhere })
        wait(for: [expectation], timeout: 10)

        cache.search(objectID: 42, workspace: workspace)
        XCTAssertEqual(cache.status(for: 42), .confirmedNowhere)
    }
}

/// Pure lane-assignment logic, the exact round-robin split
/// `resolvingObjectIDAcrossAllLevels`'s bounded-concurrency search uses to
/// divide its candidate level list across a handful of lanes. Tested
/// directly with no workspace or archive at all.
final class WorkspaceViewModelLaneIndicesTests: XCTestCase {
    func testLaneIndicesSplitsRoundRobin() {
        let lanes = WorkspaceViewModel.laneIndices(count: 10, laneCount: 4)
        XCTAssertEqual(lanes.count, 4)
        XCTAssertEqual(lanes[0], [0, 4, 8])
        XCTAssertEqual(lanes[1], [1, 5, 9])
        XCTAssertEqual(lanes[2], [2, 6])
        XCTAssertEqual(lanes[3], [3, 7])
    }

    func testLaneIndicesCoversEveryIndexExactlyOnce() {
        let lanes = WorkspaceViewModel.laneIndices(count: 37, laneCount: 4)
        let all = lanes.flatMap { $0 }.sorted()
        XCTAssertEqual(all, Array(0..<37))
    }

    func testLaneIndicesWithZeroCountReturnsEmpty() {
        XCTAssertTrue(WorkspaceViewModel.laneIndices(count: 0, laneCount: 4).isEmpty)
    }

    func testLaneIndicesWithZeroLaneCountReturnsEmpty() {
        XCTAssertTrue(WorkspaceViewModel.laneIndices(count: 10, laneCount: 0).isEmpty)
    }

    /// Fewer real candidates than the usual 4-lane cap (a small archive, or
    /// only a handful of levels left to check) must still produce exactly
    /// `laneCount` lanes, with the extra ones simply empty, not fewer
    /// lanes, and not a crash from an out-of-range stride.
    func testLaneIndicesWithFewerCandidatesThanLanesLeavesSomeLanesEmpty() {
        let lanes = WorkspaceViewModel.laneIndices(count: 2, laneCount: 4)
        XCTAssertEqual(lanes.count, 4)
        XCTAssertEqual(lanes[0], [0])
        XCTAssertEqual(lanes[1], [1])
        XCTAssertEqual(lanes[2], [])
        XCTAssertEqual(lanes[3], [])
    }
}
