import XCTest
@testable import CTModels
@testable import CTParsers

/// Cross-checks `GameplayModCatalog`'s patch closures against the exact
/// values CrateModLoader's own mod source uses, so a typo in porting one
/// of those magic constants (`72.951`, `0x188B2E`, an array index) fails
/// a test instead of silently shipping a wrong patch.
final class GameplayModCatalogTests: XCTestCase {
    private func makeInstance(objectID: UInt16, flags: UInt32 = 0, floats: [Float] = [], uint32s: [UInt32] = [], uint32s2: [UInt32] = []) -> PlacedInstance {
        PlacedInstance(
            id: 1,
            position: .zero,
            rotationRaw: .zero,
            comRotationRaw: .zero,
            childInstanceIDs: [],
            childPositionIDs: [],
            childPathIDs: [],
            objectID: objectID,
            refList: -1,
            scriptID: -1,
            flags: flags,
            unknownUInt32List: uint32s,
            unknownFloatList: floats,
            unknownUInt32List2: uint32s2
        )
    }

    func testClassicHealthSetsUnkI323Index2On4CharacterIDs() {
        let mod = GameplayModCatalog.allMods.first { $0.id == "classicHealth" }!
        for objectID: UInt16 in [KnownObjectID.crash, KnownObjectID.cortex, KnownObjectID.nina, KnownObjectID.mechabandicoot] {
            let instance = makeInstance(objectID: objectID, uint32s2: [0, 0, 0])
            let patch = mod.patch(instance)
            XCTAssertEqual(patch?.uint32List2Elements.map { $0.index }, [2])
            XCTAssertEqual(patch?.uint32List2Elements.first?.value, 1)
        }
    }

    func testClassicHealthSkipsShortList() {
        let mod = GameplayModCatalog.allMods.first { $0.id == "classicHealth" }!
        let instance = makeInstance(objectID: KnownObjectID.crash, uint32s2: [0, 0]) // count == 2, index 2 out of bounds
        XCTAssertNil(mod.patch(instance))
    }

    func testCortexDoubleJumpUsesRealArcConstants() {
        let mod = GameplayModCatalog.allMods.first { $0.id == "cortexDoubleJump" }!
        var floats = [Float](repeating: 0, count: 56)
        let instance = makeInstance(objectID: KnownObjectID.cortex, floats: floats)
        let patch = mod.patch(instance)!
        let byIndex = Dictionary(uniqueKeysWithValues: patch.floatListElements)
        XCTAssertEqual(byIndex[20], 16)      // DoubleJumpHeight
        XCTAssertEqual(byIndex[21], 64)      // DoubleJumpUnk22
        XCTAssertEqual(byIndex[22] ?? 0, 72.951, accuracy: 0.0001) // DoubleJumpArcUnk
        floats.removeAll()
    }

    func testNinaDoubleJumpMatchesCortexValues() {
        let mod = GameplayModCatalog.allMods.first { $0.id == "ninaDoubleJump" }!
        let instance = makeInstance(objectID: KnownObjectID.nina, floats: [Float](repeating: 0, count: 56))
        let patch = mod.patch(instance)!
        let byIndex = Dictionary(uniqueKeysWithValues: patch.floatListElements)
        XCTAssertEqual(byIndex[22] ?? 0, 72.951, accuracy: 0.0001)
    }

    func testCortexDoubleJumpDoesNotMatchNina() {
        let mod = GameplayModCatalog.allMods.first { $0.id == "cortexDoubleJump" }!
        XCTAssertFalse(mod.matchesObjectIDs.contains(KnownObjectID.nina))
    }

    func testClassicSlideJumpSetsUnkI321Index8To0x10000() {
        let mod = GameplayModCatalog.allMods.first { $0.id == "classicSlideJump" }!
        let instance = makeInstance(objectID: KnownObjectID.crash, uint32s: [UInt32](repeating: 0, count: 9))
        let patch = mod.patch(instance)!
        XCTAssertEqual(patch.uint32ListElements.first?.index, 8)
        XCTAssertEqual(patch.uint32ListElements.first?.value, 0x10000)
    }

    func testFlyingKickUsesRealTimingConstants() {
        let mod = GameplayModCatalog.allMods.first { $0.id == "flyingKick" }!
        let instance = makeInstance(objectID: KnownObjectID.crash, floats: [Float](repeating: 0, count: 56))
        let patch = mod.patch(instance)!
        let byIndex = Dictionary(uniqueKeysWithValues: patch.floatListElements)
        XCTAssertEqual(byIndex[34] ?? 0, 0.15, accuracy: 0.0001) // FlyingKickHangTime
        XCTAssertEqual(byIndex[35], 50)                     // FlyingKickForwardSpeed
        XCTAssertEqual(byIndex[36], 10)                     // FlyingKickGravity
    }

    func testEnableHiddenEnemiesClearsDisableObjectBitOnBat() {
        let mod = GameplayModCatalog.allMods.first { $0.id == "enableHiddenEnemies" }!
        let instance = makeInstance(objectID: KnownObjectID.globalBatDarkpurple, flags: 0xC000_0010)
        let patch = mod.patch(instance)!
        XCTAssertEqual(patch.flags, 0x0000_0010)
    }

    func testEnableHiddenEnemiesSkipsBatAlreadyEnabled() {
        let mod = GameplayModCatalog.allMods.first { $0.id == "enableHiddenEnemies" }!
        let instance = makeInstance(objectID: KnownObjectID.globalBatDarkpurple, flags: 0x10)
        XCTAssertNil(mod.patch(instance))
    }

    func testEnableHiddenEnemiesForcesFrogensteinFlagValue() {
        let mod = GameplayModCatalog.allMods.first { $0.id == "enableHiddenEnemies" }!
        let instance = makeInstance(objectID: KnownObjectID.schoolFrogenstein, flags: 0)
        let patch = mod.patch(instance)!
        XCTAssertEqual(patch.flags, 0x0018_8B2E)
    }

    func testEveryModHasNonEmptyMatchSet() {
        for mod in GameplayModCatalog.allMods {
            XCTAssertFalse(mod.matchesObjectIDs.isEmpty, "\(mod.id) declares no matching objectIDs")
        }
    }
}
