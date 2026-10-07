import XCTest
@testable import CTStudioApp

/// Real, requested extension of the earlier warn-and-override-only risky
/// scenery-count gate: past a second, higher, confirmed-broken threshold,
/// Quick Launch is now hard-blocked rather than merely warned about, see
/// `SceneryPlacementCountGate`'s own doc comment for the real PCSX2
/// evidence behind both thresholds.
final class SceneryPlacementCountGateTests: XCTestCase {
    private let warnThreshold = 8000
    private let hardBlockThreshold = 10000

    func testBelowWarnThresholdAllows() {
        let decision = SceneryPlacementCountGate.decision(count: 100, warnThreshold: warnThreshold, hardBlockThreshold: hardBlockThreshold)
        XCTAssertEqual(decision, .allow)
    }

    func testAtWarnThresholdWarnsRatherThanBlocks() {
        let decision = SceneryPlacementCountGate.decision(count: warnThreshold, warnThreshold: warnThreshold, hardBlockThreshold: hardBlockThreshold)
        guard case .warn = decision else { return XCTFail("expected .warn at the warn threshold, got \(decision)") }
    }

    func testJustBelowHardBlockThresholdStillWarns() {
        let decision = SceneryPlacementCountGate.decision(count: hardBlockThreshold - 1, warnThreshold: warnThreshold, hardBlockThreshold: hardBlockThreshold)
        guard case .warn = decision else { return XCTFail("expected .warn just under the hard-block threshold, got \(decision)") }
    }

    func testAtHardBlockThresholdBlocksRatherThanWarns() {
        let decision = SceneryPlacementCountGate.decision(count: hardBlockThreshold, warnThreshold: warnThreshold, hardBlockThreshold: hardBlockThreshold)
        guard case .block = decision else { return XCTFail("expected .block at the hard-block threshold, got \(decision)") }
    }

    func testWellAboveHardBlockThresholdStillBlocks() {
        let decision = SceneryPlacementCountGate.decision(count: hardBlockThreshold * 2, warnThreshold: warnThreshold, hardBlockThreshold: hardBlockThreshold)
        guard case .block = decision else { return XCTFail("expected .block well above the hard-block threshold, got \(decision)") }
    }

    /// The block message must be real and specific enough to act on , 
    /// carrying the actual count, not a generic "too many objects" string.
    func testBlockMessageMentionsTheActualCount() {
        let decision = SceneryPlacementCountGate.decision(count: 12345, warnThreshold: warnThreshold, hardBlockThreshold: hardBlockThreshold)
        guard case .block(let message) = decision else { return XCTFail("expected .block") }
        XCTAssertTrue(message.contains("12345"), "the block message should mention the real placement count")
    }
}
