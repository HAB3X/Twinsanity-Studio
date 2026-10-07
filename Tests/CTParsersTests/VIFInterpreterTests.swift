import XCTest
@testable import CTCore
@testable import CTParsers

final class VIFInterpreterTests: XCTestCase {
    /// Hand-assembles a minimal VIF program, `STCYCL(WL=1,CL=1)` then
    /// `UNPACK V4_32` of two known vectors, wrapped in the DMA-tag prefix
    /// `VIFInterpreter.interpretCode` expects (see its doc comment), and
    /// verifies the decoded VU memory block matches exactly. This is the
    /// most mechanically risky piece of the whole port (hand-translated
    /// bit-packing across ~13 unpack format cases), so pinning at least one
    /// concrete instruction stream end-to-end matters more here than almost
    /// anywhere else in the suite.
    func testUnpackV4_32DecodesExactFloatBitPatterns() throws {
        let vectorA: [Float] = [1.0, 2.0, 3.0, 4.0]
        let vectorB: [Float] = [-1.5, 0.0, 100.25, -0.5]

        var program = BinaryWriter()
        // STCYCL: CMD=0x01, amount=0, immediate = (WL<<8)|CL = 0x0101
        program.writeUInt32(0x0100_0101)
        // UNPACK V4_32 (op 0x6C = 0x60 | vn(3)<<2 | vl(0)), amount=2, addr=0
        program.writeUInt32(0x6C02_0000)
        for v in vectorA { program.writeFloat32(v) }
        for v in vectorB { program.writeFloat32(v) }
        // Pad to a whole number of quadwords (16 bytes): 40 bytes so far -> +8 bytes of NOP.
        program.writeUInt32(0x0000_0000)
        program.writeUInt32(0x0000_0000)
        XCTAssertEqual(program.count % 16, 0, "test program must be quadword-aligned")
        let qwc = UInt16(program.count / 16)

        var full = BinaryWriter()
        full.writeUInt16(qwc) // DMATag low bits: QWC in bits [0:16)
        full.writeUInt16(0)
        full.writeUInt32(0)   // remaining DMATag low fields, unused here
        full.writeUInt64(0)   // DMATag Extra: two NOP words, spliced in first by the interpreter
        full.writeBytes(program.data)

        let interpreter = try VIFInterpreter.interpretCode(full.data)
        let mem = interpreter.getMem()

        guard let block = mem.first(where: { $0.compactMap { $0 }.count == 2 }) else {
            return XCTFail("expected exactly one VU block with 2 decoded vectors")
        }
        guard let v0 = block[0], let v1 = block[1] else {
            return XCTFail("decoded vectors should not be nil")
        }
        XCTAssertEqual([v0.x, v0.y, v0.z, v0.w], vectorA)
        XCTAssertEqual([v1.x, v1.y, v1.z, v1.w], vectorB)
    }

    func testEmptyProgramProducesNoBlocks() throws {
        var full = BinaryWriter()
        full.writeUInt64(0) // QWC = 0
        full.writeUInt64(0) // Extra = 0 (two NOPs)
        let interpreter = try VIFInterpreter.interpretCode(full.data)
        XCTAssertTrue(interpreter.getMem().isEmpty)
    }
}
