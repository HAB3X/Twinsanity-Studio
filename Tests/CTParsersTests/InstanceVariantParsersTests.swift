import XCTest
import CTCore
import CTModels
@testable import CTParsers

/// Real, byte-exact round-trip proof for the "MonkeyBall (MB) File-Kind
/// Detection" / "Missing Boilerplate & Type Bindings" backlog items , 
/// every fixture here is hand-built to the exact real layout confirmed
/// against the reference source (`InstanceTemplate.cs`/
/// `InstanceTemplateDemo.cs`/`InstanceDemo.cs`/`InstanceMB.cs`), not
/// guessed at. These formats have no writer (matching every other Instance-
/// family record before them having none either beyond the retail
/// `Instance`), so this proves the *reader* against synthetic bytes built
/// the same way the reference's own `Save` would produce them.
final class InstanceVariantParsersTests: XCTestCase {
    // MARK: - InstanceTemplate

    func testParseInstanceTemplateRealLayout() throws {
        var w = BinaryWriter()
        let name = "Crate"
        w.writeUInt32(UInt32(name.utf8.count))
        w.writeASCIIString(name)
        w.writeUInt16(42) // objectID
        w.writeUInt16(0x1234) // bitfield
        w.writeUInt32(0) // headerInt1 (not 1, so unkShort is skipped)
        w.writeUInt32(7) // headerInt2
        w.writeUInt32(8) // headerInt3
        w.writeBytes([UInt8](repeating: 0xAB, count: 6)) // unkFlags[6]
        w.writeUInt32(99) // properties
        w.writeUInt32(2) // flags.count
        w.writeUInt32(1); w.writeUInt32(2)
        w.writeUInt32(1) // floats.count
        w.writeFloat32(3.5)
        w.writeUInt32(0) // ints.count

        var cursor = BinaryCursor(data: w.data)
        let info = try WorldPlacementParser.parseInstanceTemplate(&cursor, recordID: 5)

        XCTAssertEqual(info.name, "Crate")
        XCTAssertEqual(info.objectID, 42)
        XCTAssertEqual(info.bitfield, 0x1234)
        XCTAssertEqual(info.headerInt1, 0)
        XCTAssertNil(info.unkShort, "unkShort only present when headerInt1 == 1")
        XCTAssertEqual(info.unkFlags, [UInt8](repeating: 0xAB, count: 6))
        XCTAssertEqual(info.properties, 99)
        XCTAssertEqual(info.flags, [1, 2])
        XCTAssertEqual(info.floats, [3.5])
        XCTAssertEqual(info.ints, [])
    }

    func testParseInstanceTemplateWithHeaderInt1EqualsOneReadsUnkShort() throws {
        var w = BinaryWriter()
        w.writeUInt32(0) // empty name
        w.writeUInt16(1)
        w.writeUInt16(0)
        w.writeUInt32(1) // headerInt1 == 1 -> unkShort follows
        w.writeUInt32(0)
        w.writeUInt32(0)
        w.writeUInt16(0xBEEF) // unkShort
        w.writeBytes([UInt8](repeating: 0, count: 6))
        w.writeUInt32(0)
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)

        var cursor = BinaryCursor(data: w.data)
        let info = try WorldPlacementParser.parseInstanceTemplate(&cursor, recordID: 1)
        XCTAssertEqual(info.unkShort, 0xBEEF)
    }

    // MARK: - InstanceTemplateDemo

    func testParseInstanceTemplateDemoRealLayout() throws {
        var w = BinaryWriter()
        let name = "Fruit"
        w.writeUInt32(UInt32(name.utf8.count))
        w.writeASCIIString(name)
        w.writeUInt16(7)
        w.writeUInt16(0)
        w.writeUInt32(0) // headerInt1 != 1
        w.writeUInt32(0)
        w.writeUInt32(0)
        w.writeBytes([0x11, 0x22]) // unkFlags[2]
        w.writeUInt8(2) // flagsCount
        w.writeUInt8(1) // floatsCount
        w.writeUInt8(0) // intsCount
        w.writeUInt8(0) // padding
        w.writeUInt32(55) // properties
        w.writeUInt32(10); w.writeUInt32(20) // flags
        w.writeFloat32(1.25) // floats

        var cursor = BinaryCursor(data: w.data)
        let info = try WorldPlacementParser.parseInstanceTemplateDemo(&cursor, recordID: 2)
        XCTAssertEqual(info.name, "Fruit")
        XCTAssertEqual(info.unkFlags, [0x11, 0x22])
        XCTAssertEqual(info.properties, 55)
        XCTAssertEqual(info.flags, [10, 20])
        XCTAssertEqual(info.floats, [1.25])
        XCTAssertEqual(info.ints, [])
    }

    // MARK: - InstanceDemo

    func testParseInstanceDemoRealLayout() throws {
        var w = BinaryWriter()
        w.writeVector4(SIMD4(1, 2, 3, 1))
        w.writeUInt16(10); w.writeUInt16(11) // rotX, comRotX
        w.writeUInt16(20); w.writeUInt16(21) // rotY, comRotY
        w.writeUInt16(30); w.writeUInt16(31) // rotZ, comRotZ
        // Three counted ID lists, real triple-int32 header (count, count, someNum)
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10) // childInstanceIDs empty, someNum1=10
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(20) // childPositionIDs empty, someNum2=20
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(30) // childPathIDs empty, someNum3=30
        w.writeUInt16(99) // objectID
        w.writeUInt32(0xDEADBEEF) // afterObjectID
        w.writeUInt8(1) // flagsCount
        w.writeUInt8(0) // floatsCount
        w.writeUInt8(1) // intsCount
        w.writeUInt8(0) // padding
        w.writeUInt32(6) // flags (the real Flags field, default 0x6)
        w.writeUInt32(777) // the one UnkI321 entry
        w.writeUInt32(888) // the one UnkI323 entry

        var cursor = BinaryCursor(data: w.data)
        let info = try WorldPlacementParser.parseInstanceDemo(&cursor, recordID: 3)
        XCTAssertEqual(info.position, SIMD4(1, 2, 3, 1))
        XCTAssertEqual(info.someNum1, 10)
        XCTAssertEqual(info.someNum2, 20)
        XCTAssertEqual(info.someNum3, 30)
        XCTAssertEqual(info.objectID, 99)
        XCTAssertEqual(info.afterObjectID, 0xDEADBEEF)
        XCTAssertEqual(info.flags, 6)
        XCTAssertEqual(info.unknownUInt32List, [777])
        XCTAssertEqual(info.unknownFloatList, [])
        XCTAssertEqual(info.unknownUInt32List2, [888])
    }

    // MARK: - InstanceMB

    func testParseInstanceMBPreservesOpaqueTailByteExact() throws {
        var w = BinaryWriter()
        w.writeVector4(SIMD4(4, 5, 6, 1))
        w.writeUInt16(1); w.writeUInt16(2)
        w.writeUInt16(3); w.writeUInt16(4)
        w.writeUInt16(5); w.writeUInt16(6)
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0)
        w.writeUInt16(123) // objectID
        w.writeInt16(-1) // refList
        w.writeInt16(-1) // scriptID
        let tail: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02]
        w.writeBytes(tail)

        var cursor = BinaryCursor(data: w.data)
        let info = try WorldPlacementParser.parseInstanceMB(&cursor, recordID: 4, size: w.data.count)
        XCTAssertEqual(info.objectID, 123)
        XCTAssertEqual(info.refList, -1)
        XCTAssertEqual(info.scriptID, -1)
        XCTAssertEqual(Array(info.remainingTailBytes), tail, "the opaque tail must round-trip byte-exact, since nothing here claims to understand its structure")
    }

    // MARK: - MaterialDemo / MonkeyBall shader layout

    /// Builds one synthetic `TwinsShader` block matching `TwinsShader.Read`'s
    /// real byte layout, varying only the two real length differences this
    /// backlog item is about: `isDemo` drops the `UnkFlag3`/`BlobFlag` pair,
    /// `isMonkeyBall` adds 2 bytes right before `TextureId`.
    private func writeSyntheticShader(_ w: inout BinaryWriter, textureId: UInt32, isDemo: Bool, isMonkeyBall: Bool) {
        w.writeUInt32(0) // shaderType 0 -> no variable param block
        w.writeBytes([UInt8](repeating: 0, count: 17)) // 17 single-byte fields
        w.writeUInt8(0) // UsePresetAlphaRegSettings
        w.writeBytes([UInt8](repeating: 0, count: 6))
        w.writeBytes([UInt8](repeating: 0, count: 3))
        w.writeUInt8(0) // ZValueDrawingMask
        if !isDemo {
            w.writeBytes([0, 0]) // UnkFlag3, BlobFlag
        }
        w.writeUInt16(0) // LodParamK
        w.writeUInt16(0) // LodParamL
        w.writeBytes([UInt8](repeating: 0, count: 48)) // 3 vectors
        if isMonkeyBall {
            w.writeUInt16(0xFFFF) // the real, unidentified MB-only 2 bytes
        }
        w.writeUInt32(textureId)
        w.writeUInt32(0) // trailing repeated shaderType
    }

    private func writeSyntheticMaterial(name: String, textureId: UInt32, isDemo: Bool, isMonkeyBall: Bool) -> Data {
        var w = BinaryWriter()
        w.writeUInt64(2) // Header
        w.writeInt32(2) // Unknown
        w.writeInt32(Int32(name.utf8.count))
        w.writeASCIIString(name)
        w.writeInt32(1) // shaderCount
        writeSyntheticShader(&w, textureId: textureId, isDemo: isDemo, isMonkeyBall: isMonkeyBall)
        return w.data
    }

    func testMaterialParserRetailLayout() throws {
        let data = writeSyntheticMaterial(name: "Wood", textureId: 42, isDemo: false, isMonkeyBall: false)
        var cursor = BinaryCursor(data: data)
        let info = try MaterialParser.parse(&cursor, recordID: 1)
        XCTAssertEqual(info.name, "Wood")
        XCTAssertEqual(info.primaryTextureID, 42)
    }

    func testMaterialParserDemoLayoutIsTwoBytesShorterAndStillResolvesRealTextureId() throws {
        let data = writeSyntheticMaterial(name: "Wood", textureId: 42, isDemo: true, isMonkeyBall: false)
        var cursor = BinaryCursor(data: data)
        let info = try MaterialParser.parse(&cursor, recordID: 1, isDemo: true)
        XCTAssertEqual(info.primaryTextureID, 42)

        // Reading the same Demo bytes as retail must NOT resolve the real
        // texture ID (proving the 2-byte difference is real, not a no-op) , 
        // it either throws or drifts onto the wrong field entirely.
        var wrongCursor = BinaryCursor(data: data)
        if let wrongInfo = try? MaterialParser.parse(&wrongCursor, recordID: 1, isDemo: false) {
            XCTAssertNotEqual(wrongInfo.primaryTextureID, 42, "reading Demo bytes as retail must not silently agree on the real texture ID")
        }
    }

    func testMaterialParserMonkeyBallLayoutResolvesRealTextureIdPastTheExtraTwoBytes() throws {
        let data = writeSyntheticMaterial(name: "Wood", textureId: 42, isDemo: false, isMonkeyBall: true)
        var cursor = BinaryCursor(data: data)
        let info = try MaterialParser.parse(&cursor, recordID: 1, isMonkeyBall: true)
        XCTAssertEqual(info.primaryTextureID, 42)

        var wrongCursor = BinaryCursor(data: data)
        if let wrongInfo = try? MaterialParser.parse(&wrongCursor, recordID: 1, isMonkeyBall: false) {
            XCTAssertNotEqual(wrongInfo.primaryTextureID, 42, "reading MonkeyBall bytes without the extra 2 bytes must not silently agree on the real texture ID")
        }
    }

    // MARK: - SoundEffectX / SoundEffectMB

    func testSoundEffectXParserRealLayout() throws {
        var w = BinaryWriter()
        w.writeUInt32(3) // confirmed-always-3
        w.writeUInt32(22050) // Freq
        w.writeBytes([UInt8](repeating: 0, count: 20)) // HeaderStatic1
        w.writeUInt32(22050) // Freq again
        w.writeUInt32(44100) // Freq * 2
        w.writeBytes([UInt8](repeating: 0, count: 28)) // HeaderStatic2
        let sound: [UInt8] = [1, 2, 3, 4, 5]
        w.writeInt32(Int32(sound.count + 4)) // SoundSize field (real data length + 4)
        w.writeInt32(-1) // UnkInt
        w.writeBytes(sound)
        w.writeInt32(Int32(sound.count + 4)) // repeated
        w.writeUInt32(0) // trailing zero

        var cursor = BinaryCursor(data: w.data)
        let info = try SoundEffectXParser.parse(&cursor, recordID: 9)
        XCTAssertEqual(info.frequencyHz, 22050)
        XCTAssertEqual(info.unknownInt, -1)
        XCTAssertEqual(Array(info.soundData), sound)
    }

    func testSoundEffectMBHeaderParsesDirectFrequencyNoLookupTable() throws {
        var w = BinaryWriter()
        w.writeUInt32(0) // Head
        w.writeUInt32(37800) // FreqReal, a real Hz value with no entry in the retail FreqFac lookup table at all
        w.writeUInt32(100) // SoundSize
        w.writeUInt32(0) // SoundOffset
        var cursor = BinaryCursor(data: w.data)
        let record = try SoundEffectParser.parseHeaderMB(&cursor, recordID: 1)
        XCTAssertEqual(record.frequencyHz, 37800, "FreqReal is the direct Hz value, unlike retail's FreqFac code")
        XCTAssertEqual(record.soundSize, 100)
    }

    func testSoundEffectMBResolveSlicesRealExtraData() throws {
        let extraData = Data([0, 0, 0, 0] + [10, 20, 30, 40])
        let record = SoundEffectParser.RawRecordMB(recordID: 1, frequencyHz: 8000, soundSize: 4, soundOffset: 4)
        let asset = SoundEffectParser.resolveMB(record, extraData: extraData, extraDataAbsoluteFileOffset: 1000)
        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.sampleRateHz, 8000)
        XCTAssertEqual(asset?.sourceAudioByteRange?.offset, 1004)
        XCTAssertEqual(asset?.sourceAudioByteRange?.length, 4)
    }
}
