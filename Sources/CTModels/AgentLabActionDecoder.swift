import Foundation

/// Named-argument decode for the commands `github.com/Smartkin/
/// twinsanity-editor` (MIT licensed) has a real, actively-registered
/// `[ActionID(...)]` action class for, under `Code/Actions/Confirmed/`.
/// Ported field-for-field from each class's own `Load(Script.MainScript.
/// ScriptCommand)`, see the doc comment on each case below for exactly
/// which source file it mirrors.
///
/// Deliberately *not* ported: `NowGoBackCollidableAction`, its own
/// `[ActionID]` attribute is commented out in the reference source (`//
/// [ActionID(DefaultEnums.CommandID.NowGoBackCollidable)]`), meaning the
/// reference tool itself never dispatches to it via its
/// `GetSupported()` reflection scan. Porting it as if it were live would be
/// less accurate than the reference tool, not more.
public enum AgentLabActionDecoder {
    /// Decodes `rawArguments` for `commandID`, when this build has a
    /// verified reference implementation for it. Returns `nil`, never a
    /// guess, for every other command, including ones with a real
    /// `commandName` from `AgentLabCommandCatalog`: knowing a command's name
    /// doesn't mean this build knows its argument layout.
    public static func decode(commandID: UInt16, arguments: [UInt32]) -> AgentLabDecodedAction? {
        guard let known = AgentLabCommandCatalog.KnownCommandID(rawValue: commandID) else { return nil }
        switch known {
        case .addAmmo: // AddAmmoAction.Load: AmmoToAdd = (int)args[0]
            guard let a0 = arguments.first else { return nil }
            return .addAmmo(Int32(bitPattern: a0))

        case .addGem: // AddGemAction.Load: Gem = (GemType)args[0]
            guard let a0 = arguments.first, let gem = AgentLabGemType(rawValue: a0) else { return nil }
            return .addGem(gem)

        case .addLives, .addLivesDuplicate, .addLivesDuplicate2: // AddLivesAction.Load
            guard let a0 = arguments.first else { return nil }
            return .addLives(Int32(bitPattern: a0))

        case .caPickUpWumpa: // AddWumpaAction.Load
            guard let a0 = arguments.first else { return nil }
            return .addWumpa(Int32(bitPattern: a0))

        case .cutsceneStart: // CutsceneStartAction.Load: FadeDuration = BitConverter.ToSingle(args[0])
            guard let a0 = arguments.first else { return nil }
            return .cutsceneStart(fadeDuration: Float(bitPattern: a0))

        case .cutsceneEnd: // CutsceneEndAction.Load
            guard let a0 = arguments.first else { return nil }
            return .cutsceneEnd(fadeDuration: Float(bitPattern: a0))

        case .bossModeDamage: // DamageBossAction.Load
            guard let a0 = arguments.first else { return nil }
            return .damageBoss(Int32(bitPattern: a0))

        case .bottomTextHide: // HideBottomTextAction.Load
            guard let a0 = arguments.first else { return nil }
            return .hideBottomText(fadeDuration: Float(bitPattern: a0))

        case .whackawormProgress: // ProgressWhackawormAction.Load
            guard let a0 = arguments.first else { return nil }
            return .progressWhackaworm(Int32(bitPattern: a0))

        case .reduceHitPoints: // ReduceHitPointsAction.Load
            guard let a0 = arguments.first else { return nil }
            return .reduceHitPoints(Int32(bitPattern: a0))

        case .setBehaviourPriority:
            // SetBehaviourPriorityAction.Load: Priority = (byte)args[0] , 
            // Save encodes `0xCDCDCD00 + Priority` (upper 3 bytes are
            // padding, never real data), so Load only ever needs the low
            // byte, matching the reference exactly.
            guard let a0 = arguments.first else { return nil }
            return .setBehaviourPriority(UInt8(truncatingIfNeeded: a0))

        case .setHitPoints: // SetHitPointsAction.Load
            guard let a0 = arguments.first else { return nil }
            return .setHitPoints(Int32(bitPattern: a0))

        case .bottomTextShow: // ShowBottomTextAction.Load
            guard let a0 = arguments.first else { return nil }
            return .showBottomText(fadeDuration: Float(bitPattern: a0))
        }
    }
}
