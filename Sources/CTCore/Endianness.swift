import Foundation

/// Byte order for a binary stream.
///
/// Historical note: despite Twinsanity shipping on PS2 (MIPS R5900) and Xbox (x86),
/// both platforms are little-endian, and the original C# tool read every structural
/// field with a plain (always-LE) `BinaryReader`, there is no byte-swap layer for
/// RM2/SM2/BD/BH/texture/model/skin/animation data. The only place the original tool
/// ever byte-swaps is legacy VAG audio headers. `BinaryCursor` still supports both
/// orders below so this reader is genuinely endian-aware (and future formats can opt
/// into big-endian), but every parser in this package reads `.little`.
public enum Endianness: Sendable {
    case little
    case big
}

/// Platform a given archive/file was authored for. Distinct from `Endianness` on
/// purpose: the real per-platform difference in Twinsanity's format is data layout
/// (PS2 GS-swizzled paletted textures vs. Xbox DXT5, PS2 VU microcode vs. plain
/// buffers), not byte order.
public enum ConsolePlatform: String, Sendable, CaseIterable {
    case ps2 = "PS2"
    case xbox = "Xbox"
    case psp = "PSP"
    case unknown = "Unknown"
}
