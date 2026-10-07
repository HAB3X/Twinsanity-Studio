import XCTest
@testable import CTStudioApp

/// "Pre-save validation", real oriented-set logic tested directly,
/// independent of any renderer/SwiftUI state, same reasoning as
/// `TriggerContainmentTests` in `ModelViewerRendererTests.swift`.
final class DanglingReferenceCheckerTests: XCTestCase {
    func testTriggerReferencingADeletedInstanceWarns() {
        let warnings = DanglingReferenceChecker.warnings(
            triggers: [(id: 1, instanceIDs: [42])],
            cameras: [],
            instances: [],
            aiPaths: [],
            removedInstanceIDs: [42],
            removedTriggerIDs: [],
            removedCameraIDs: [],
            removedAIPositionIDs: []
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("Trigger #1"))
        XCTAssertTrue(warnings[0].contains("42"))
    }

    func testCameraReferencingADeletedInstanceWarns() {
        let warnings = DanglingReferenceChecker.warnings(
            triggers: [],
            cameras: [(id: 5, instanceIDs: [7, 8])],
            instances: [],
            aiPaths: [],
            removedInstanceIDs: [8],
            removedTriggerIDs: [],
            removedCameraIDs: [],
            removedAIPositionIDs: []
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("Camera #5"))
        XCTAssertTrue(warnings[0].contains("8"))
    }

    func testInstanceReferencingADeletedChildInstanceWarns() {
        let warnings = DanglingReferenceChecker.warnings(
            triggers: [],
            cameras: [],
            instances: [(id: 10, childInstanceIDs: [11])],
            aiPaths: [],
            removedInstanceIDs: [11],
            removedTriggerIDs: [],
            removedCameraIDs: [],
            removedAIPositionIDs: []
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("Instance #10"))
    }

    /// The one unconfirmed edge, worded as a heads-up, not a fact.
    func testAIPathReferencingADeletedAIPositionWarnsWithUnconfirmedCaveat() {
        let warnings = DanglingReferenceChecker.warnings(
            triggers: [],
            cameras: [],
            instances: [],
            aiPaths: [(id: 3, startAIPositionID: 99, endAIPositionID: nil)],
            removedInstanceIDs: [],
            removedTriggerIDs: [],
            removedCameraIDs: [],
            removedAIPositionIDs: [99]
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("AIPath #3"))
        XCTAssertTrue(warnings[0].lowercased().contains("unconfirmed"))
    }

    /// A record that's itself being deleted this session doesn't need its
    /// own dangling-reference warning, it won't survive to reference
    /// anything.
    func testATriggerThatIsItselfBeingDeletedIsSkipped() {
        let warnings = DanglingReferenceChecker.warnings(
            triggers: [(id: 1, instanceIDs: [42])],
            cameras: [],
            instances: [],
            aiPaths: [],
            removedInstanceIDs: [42],
            removedTriggerIDs: [1],
            removedCameraIDs: [],
            removedAIPositionIDs: []
        )
        XCTAssertTrue(warnings.isEmpty)
    }

    func testNoWarningsWhenNothingReferencesARemovedID() {
        let warnings = DanglingReferenceChecker.warnings(
            triggers: [(id: 1, instanceIDs: [42])],
            cameras: [(id: 2, instanceIDs: [43])],
            instances: [(id: 3, childInstanceIDs: [44])],
            aiPaths: [(id: 4, startAIPositionID: 45, endAIPositionID: 46)],
            removedInstanceIDs: [999],
            removedTriggerIDs: [],
            removedCameraIDs: [],
            removedAIPositionIDs: [999]
        )
        XCTAssertTrue(warnings.isEmpty)
    }

    func testMultipleDanglingReferencesOnOneRecordAreAllListed() {
        let warnings = DanglingReferenceChecker.warnings(
            triggers: [(id: 1, instanceIDs: [42, 43, 44])],
            cameras: [],
            instances: [],
            aiPaths: [],
            removedInstanceIDs: [42, 44],
            removedTriggerIDs: [],
            removedCameraIDs: [],
            removedAIPositionIDs: []
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("42"))
        XCTAssertTrue(warnings[0].contains("44"))
        XCTAssertFalse(warnings[0].contains("43"))
    }

    // MARK: - unresolvedReferenceWarnings ("Cross-Reference Validation, Unresolvable References")

    /// The real, distinguishing case `warnings(...)` above can never
    /// catch: a reference to an ID that was *already* missing, with no
    /// deletion involved this session at all.
    func testTriggerReferencingAnIDThatNeverExistedWarns() {
        let warnings = DanglingReferenceChecker.unresolvedReferenceWarnings(
            triggers: [(id: 1, instanceIDs: [42])],
            cameras: [],
            instances: [],
            aiPaths: [],
            existingInstanceIDs: [1, 2, 3], // 42 was never among them
            existingAIPositionIDs: []
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("Trigger #1"))
        XCTAssertTrue(warnings[0].contains("42"))
    }

    func testCameraReferencingAnExistingInstanceDoesNotWarn() {
        let warnings = DanglingReferenceChecker.unresolvedReferenceWarnings(
            triggers: [],
            cameras: [(id: 5, instanceIDs: [7])],
            instances: [],
            aiPaths: [],
            existingInstanceIDs: [7],
            existingAIPositionIDs: []
        )
        XCTAssertTrue(warnings.isEmpty)
    }

    func testInstanceReferencingAMissingChildInstanceWarns() {
        let warnings = DanglingReferenceChecker.unresolvedReferenceWarnings(
            triggers: [],
            cameras: [],
            instances: [(id: 10, childInstanceIDs: [11])],
            aiPaths: [],
            existingInstanceIDs: [10], // 11 doesn't exist
            existingAIPositionIDs: []
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("Instance #10"))
        XCTAssertTrue(warnings[0].contains("11"))
    }

    func testAIPathReferencingAMissingAIPositionWarnsWithUnconfirmedCaveat() {
        let warnings = DanglingReferenceChecker.unresolvedReferenceWarnings(
            triggers: [],
            cameras: [],
            instances: [],
            aiPaths: [(id: 3, startAIPositionID: 99, endAIPositionID: nil)],
            existingInstanceIDs: [],
            existingAIPositionIDs: [] // 99 doesn't exist
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("AIPath #3"))
        XCTAssertTrue(warnings[0].lowercased().contains("unconfirmed"))
    }

    func testUnresolvedReferenceWarningsMentionsDontExistNotDeleted() {
        // Wording matters: this is a distinct failure mode from `warnings`'
        // "references deleted X" phrasing, it should read as "never
        // existed," not imply this session's editing caused it.
        let warnings = DanglingReferenceChecker.unresolvedReferenceWarnings(
            triggers: [(id: 1, instanceIDs: [42])],
            cameras: [],
            instances: [],
            aiPaths: [],
            existingInstanceIDs: [],
            existingAIPositionIDs: []
        )
        XCTAssertTrue(warnings[0].contains("don't exist"))
    }
}
