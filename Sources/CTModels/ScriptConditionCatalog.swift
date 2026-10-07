import Foundation

/// Real, verified `ScriptCondition` metadata, ported from `Twinsanity.
/// DefaultEnums.ConditionID` and `Twinsanity.Actions.ScriptPerceptAbstract.
/// Args` (`Twinsanity/DefaultEnums.cs`, `Twinsanity/Items/Code/Percepts/
/// ScriptPerceptAbstract.cs`), same reference lineage as
/// `AgentLabCommandCatalog`. `ScriptCondition.vTableIndex` is this table's
/// key, directly analogous to how `AgentLabCommand.commandID` keys
/// `AgentLabCommandCatalog.commandNames`.
///
/// `conditionNames` only includes the reference enum's real, uncommented
/// entries, every commented-out value in `DefaultEnums.ConditionID`
/// (`//IsChargedShot = 579`, `//GlobalProgression = 639`, etc.) is a
/// condition the reference tool's own author didn't consider confirmed,
/// so it's omitted here too, not guessed at.
///
/// `perceptArgumentCategories`: `ScriptPerceptAbstract` also defines a
/// `SupportedTypes` reflection registry meant to hold a concrete decoder
/// per condition (mirroring `Code/Actions/Confirmed/*` for commands), but
/// no `Code/Percepts/Confirmed/*` subclasses exist anywhere in the
/// reference repository, so that registry is always empty at runtime.
/// Only the `Args` dictionary itself (which *kind* of value `Parameter`
/// represents, an actor ID, a message ID, a counter ID, ...) is real,
/// populated data; ported as-is, with no invented per-condition value
/// decoder to match it.
public enum ScriptConditionCatalog {
    public static func conditionName(forID id: UInt16) -> String? {
        conditionNames[id]
    }

    public static func perceptArgumentCategory(forID id: UInt16) -> PerceptArgument? {
        perceptArgumentCategories[id]
    }

    /// `ScriptPerceptAbstract.PerceptArgument`, ported verbatim (same raw values).
    public enum PerceptArgument: Sendable {
        case exitPoint, actor, subtype, message, integerPlus, surface, counter, softFlag
    }

    static let perceptArgumentCategories: [UInt16: PerceptArgument] = [
        40: .exitPoint, 41: .exitPoint, 42: .exitPoint, 43: .exitPoint, 44: .exitPoint,
        46: .actor, 47: .subtype, 51: .message, 11: .integerPlus, 53: .surface,
        55: .exitPoint, 59: .counter, 60: .counter, 67: .softFlag, 69: .integerPlus,
        71: .integerPlus, 553: .exitPoint, 554: .exitPoint, 555: .exitPoint, 556: .exitPoint,
        567: .exitPoint,
    ]

    // MARK: - `DefaultEnums.ConditionID`, ported verbatim (real entries only)

    static let conditionNames: [UInt16: String] = [
        0: "Next", 1: "IsCollidable", 2: "Else", 3: "Random", 4: "IsVisible", 5: "TimeInUnit", 6: "IsInExternalScript", 7:
        "AnimationFinished", 8: "IsPathComplete", 9: "MeToInitPosSqrDist", 10: "MeToFocusSqrDist", 11: "CurrentKey", 12:
        "IsLoadZoneStateSet", 13: "GotRoute", 14: "GotKeys", 15: "HitUnloadedZone", 16: "RouteLength", 17: "RouteCost", 18:
        "PosAlongEdge", 19: "PosAcrossEdge", 20: "InsideEdgeStartNode", 21: "InsideEdgeEndNode", 22: "MeFacingFocus", 23:
        "FocusFacingMe", 24: "ClearLineOfSightToFocus", 25: "FocusAgentCanSeeMe", 26: "CanSeeFocus", 27: "MeFacingRouteNode", 28:
        "ClearLineOfSightToRouteNode", 29: "HeightAboveFocus", 30: "AgentHitAvoidee", 31: "MeToAvoideeSqrDist", 32:
        "CommandDestToAvoideeSqrDist", 33: "CommandDestHitsAvoidee", 34: "CommandPathNearAvoidee", 35: "MeFacingCamera", 36:
        "CameraFacingMe", 37: "InCameraFrustrum", 38: "ClearLineOfSightToCamera", 39: "CameraCanSeeMe", 40: "HeadLookingAtFocus", 41:
        "HeadCanSeeFocus", 42: "HeadLookingAtRouteNode", 43: "FocusHeadLookingAtMe", 44: "FocusHeadCanSeeMe", 45: "GotAnyFocus", 46:
        "FocusActorEquals", 47: "ActorSubtypeEquals", 48: "AttachedToAnAgent", 49: "GotAttachedObject", 50: "GotAnyUserMessage", 51:
        "GotUserMessageEquals", 52: "CurrentKeyEquals", 53: "TouchingTerrain", 54: "TouchingAnyAgent", 55: "GotAttachmentOnExit", 56:
        "GotFocusObject", 57: "GotFocusPosition", 58: "GetAnimationTimeRemaining", 59: "CounterValue", 60: "CounterValueEqualsThreshold",
        61: "IsResting", 62: "SqrMoveSpeed", 63: "FocusHasAttachment", 64: "LostAllAttachments", 65: "IsBusy", 66: "FocusIsBusy", 67:
        "SoftFlagSet", 68: "MeToCurrentKeySqrDist", 69: "MeToKeySqrDist", 70: "SpeedTowardsNextKey", 71: "SpeedTowardsKey", 72:
        "BoxAboveIsOverlapped", 73: "GotLinkedObject", 74: "XCycle", 75: "YCycle", 76: "ZCycle", 88: "DistanceToTarget", 123:
        "DistanceToTarget_Duplicate", 129: "SubtypeOfPercept128_1", 130: "SubtypeOfPercept128_2", 131: "SubtypeOfPercept128_3", 512:
        "PlayerHitPoints", 513: "Difficulty", 514: "PlayerIsCrouching", 515: "PlayerIsGrounded", 516: "PlayerIsInvincible", 517:
        "MeToPlayerSqrDist", 518: "AgentIsOnGround", 519: "CrateHasRedWumpa", 520: "AgentWasTouched", 521: "AgentWasSpun", 522:
        "AgentWasKneeDropped", 523: "AgentWasSlid", 524: "AgentHitPoints", 525: "CanMoveForwards", 526: "CanMoveBackwards", 527:
        "CanStrafeLeft", 528: "CanStrafeRight", 529: "CanJumpForwards", 530: "CanFall", 531: "WillHitLowWall", 532: "WillHitWall", 533:
        "WillRunOffCliff", 534: "AgentWasAttacked", 535: "AgentWasJumpedOn", 536: "AgentWasWalkedInto", 537: "AgentWasHeadbutted", 538:
        "PlayerToMyFocusSqrDist", 539: "WumpaNeededForPayGate", 540: "MeFacingPlayer", 541: "PlayerFacingMe", 542:
        "ClearLineOfSightToPlayer", 543: "CanSeePlayer", 544: "PlayerCanSeeMe", 545: "NodeTraffic", 546: "NodeIsAirborne", 547:
        "EdgeNeedsJump", 548: "EdgeNeedsFlying", 549: "EdgeTraversable", 550: "EdgeNeedsLongJump", 551: "EdgeNeedsHighJump", 552:
        "HeightAbovePlayer", 553: "HeadLookingAtPlayer", 554: "HeadCanSeePlayer", 555: "PlayerHeadLookingAtMe", 556:
        "PlayerHeadCanSeeMe", 557: "PlayerIsMoving", 558: "PlayerIsWalking", 559: "PlayerIsRunning", 560: "PlayerIsCrawling", 561:
        "PlayerIsFalling", 562: "PlayerIsCoOpLinked", 563: "PlayerHoldingMultiTool", 564: "PlayerIsSlamming", 565: "PlayerIsSpinning",
        566: "PlayerIsJumping", 567: "HeadCanSeePlayerUnblocked", 568: "AmIHarmful", 629: "DemoHubMusicFlag",
    ]
}
