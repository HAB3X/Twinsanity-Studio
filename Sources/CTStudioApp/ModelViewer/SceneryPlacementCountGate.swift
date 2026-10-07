import Foundation

/// The pure decision logic behind `LevelViewerWindow.confirmingRiskyPlacementCount`
///, real PCSX2 boot testing (`ScenerySpamBootTests`) found two distinct
/// zones past a level's scenery placement count: a "risky, but not always
/// broken" zone starting around 8,000, and a "confirmed broken every
/// time" zone at 10,000, where every independent boot showed the same
/// corruption signature (a dense, continuous cascade of "EE: Unrecognized
/// COP0/FPU op" traps right after the loading FMVs). `warn` still lets
/// the user override; `block` doesn't, since past that point "Launch
/// Anyway" isn't a real choice.
enum SceneryPlacementCountGate {
    enum Decision: Equatable {
        case allow
        case warn(message: String)
        case block(message: String)
    }

    static func decision(count: Int, warnThreshold: Int, hardBlockThreshold: Int) -> Decision {
        if count >= hardBlockThreshold {
            return .block(message: "This level has \(count) scenery placements, at or above \(hardBlockThreshold), real PCSX2 testing consistently found this level's collision/scenery data overrunning a fixed-size buffer, hanging forever right after the loading screen every time. That isn't a risk worth overriding, so Quick Launch is blocked here, remove some placements first.")
        }
        if count >= warnThreshold {
            return .warn(message: "This level has \(count) scenery placements. Real PCSX2 testing found that past roughly \(warnThreshold), this level's collision/scenery data starts overrunning a fixed-size buffer, the game hangs forever right after the loading screen instead of crashing outright. Launch anyway?")
        }
        return .allow
    }
}
