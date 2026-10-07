import Foundation

/// "Pre-save validation", the pure scanning logic behind
/// `LevelViewerWindow.danglingReferenceWarnings()`, pulled out as a free
/// function operating on plain tuples (not `PlacedInstance`/`TriggerVolume`/
/// etc directly) so it's unit-testable without instantiating a SwiftUI
/// `View`, this codebase has no existing pattern for that, and this logic
/// is new enough (four separate reference-field scans, several ID-width
/// casts) that a silently-wrong warning message is a real risk worth
/// guarding with a real test, not just eyeballing the call site.
enum DanglingReferenceChecker {
    /// Scans every real cross-record ID reference this codebase has
    /// confirmed (Trigger/Camera -> Instance, Instance -> child Instance , 
    /// see each type's own doc comment in `WorldPlacementAssets.swift`/
    /// `CameraAssets.swift`) plus one the reference tool's editor labels
    /// but never resolves (`AIPathRecord.startAIPositionID`/
    /// `endAIPositionID` -> AIPosition, worded as a heads-up below, not a
    /// fact) against a set of IDs about to be removed, and returns one
    /// human-readable warning per surviving record that still points at
    /// something being deleted.
    static func warnings(
        triggers: [(id: UInt32, instanceIDs: [UInt16])],
        cameras: [(id: UInt32, instanceIDs: [UInt16])],
        instances: [(id: UInt32, childInstanceIDs: [UInt16])],
        aiPaths: [(id: UInt32, startAIPositionID: UInt16?, endAIPositionID: UInt16?)],
        removedInstanceIDs: Set<UInt32>,
        removedTriggerIDs: Set<UInt32>,
        removedCameraIDs: Set<UInt32>,
        removedAIPositionIDs: Set<UInt32>
    ) -> [String] {
        var warnings: [String] = []

        for trigger in triggers where !removedTriggerIDs.contains(trigger.id) {
            let dangling = trigger.instanceIDs.filter { removedInstanceIDs.contains(UInt32($0)) }
            if !dangling.isEmpty {
                warnings.append("Trigger #\(trigger.id) references deleted Instance(s) \(dangling.map(String.init).joined(separator: ", ")).")
            }
        }

        for camera in cameras where !removedCameraIDs.contains(camera.id) {
            let dangling = camera.instanceIDs.filter { removedInstanceIDs.contains(UInt32($0)) }
            if !dangling.isEmpty {
                warnings.append("Camera #\(camera.id) references deleted Instance(s) \(dangling.map(String.init).joined(separator: ", ")).")
            }
        }

        for instance in instances where !removedInstanceIDs.contains(instance.id) {
            let dangling = instance.childInstanceIDs.filter { removedInstanceIDs.contains(UInt32($0)) }
            if !dangling.isEmpty {
                warnings.append("Instance #\(instance.id) references deleted child Instance(s) \(dangling.map(String.init).joined(separator: ", ")).")
            }
        }

        for path in aiPaths {
            let dangling = [path.startAIPositionID, path.endAIPositionID]
                .compactMap { $0 }
                .filter { removedAIPositionIDs.contains(UInt32($0)) }
            if !dangling.isEmpty {
                warnings.append("AIPath #\(path.id) references deleted AIPosition(s) \(dangling.map(String.init).joined(separator: ", ")), unconfirmed reference, may be a false positive.")
            }
        }

        return warnings
    }

    /// "Cross-Reference Validation, Unresolvable References": a real
    /// extension of `warnings(...)` above. That function only catches a
    /// reference broken *by this session's own pending deletions*, it
    /// says nothing about a reference that was already broken before this
    /// session ever opened the level (bad source data, a reference tool
    /// that wrote an ID for a record that was itself later removed by
    /// some other means, or simply a level built with a genuine data
    /// error). This checks every one of the same real cross-record
    /// references against the *full* set of IDs that currently exist in
    /// the level at all, independent of anything being deleted right now,
    /// so a pre-existing dangling reference surfaces too instead of only
    /// ever being discovered later as a broken reference in-game.
    static func unresolvedReferenceWarnings(
        triggers: [(id: UInt32, instanceIDs: [UInt16])],
        cameras: [(id: UInt32, instanceIDs: [UInt16])],
        instances: [(id: UInt32, childInstanceIDs: [UInt16])],
        aiPaths: [(id: UInt32, startAIPositionID: UInt16?, endAIPositionID: UInt16?)],
        existingInstanceIDs: Set<UInt32>,
        existingAIPositionIDs: Set<UInt32>
    ) -> [String] {
        var warnings: [String] = []

        for trigger in triggers {
            let unresolved = trigger.instanceIDs.filter { !existingInstanceIDs.contains(UInt32($0)) }
            if !unresolved.isEmpty {
                warnings.append("Trigger #\(trigger.id) references Instance(s) \(unresolved.map(String.init).joined(separator: ", ")) that don't exist in this level.")
            }
        }

        for camera in cameras {
            let unresolved = camera.instanceIDs.filter { !existingInstanceIDs.contains(UInt32($0)) }
            if !unresolved.isEmpty {
                warnings.append("Camera #\(camera.id) references Instance(s) \(unresolved.map(String.init).joined(separator: ", ")) that don't exist in this level.")
            }
        }

        for instance in instances {
            let unresolved = instance.childInstanceIDs.filter { !existingInstanceIDs.contains(UInt32($0)) }
            if !unresolved.isEmpty {
                warnings.append("Instance #\(instance.id) references child Instance(s) \(unresolved.map(String.init).joined(separator: ", ")) that don't exist in this level.")
            }
        }

        for path in aiPaths {
            let unresolved = [path.startAIPositionID, path.endAIPositionID]
                .compactMap { $0 }
                .filter { !existingAIPositionIDs.contains(UInt32($0)) }
            if !unresolved.isEmpty {
                warnings.append("AIPath #\(path.id) references AIPosition(s) \(unresolved.map(String.init).joined(separator: ", ")) that don't exist in this level, unconfirmed reference, may be a false positive.")
            }
        }

        return warnings
    }
}
