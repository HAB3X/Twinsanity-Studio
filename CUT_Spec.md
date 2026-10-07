# WoC `.CUT` (Cutscene) Format, Investigation Notes

Status: **implemented** (`WOCCutsceneParser.swift`), a validated
sequential shape-scanner (not the pointer-graph walker originally
sketched below; see the parser's own doc comment for why) achieves
byte-exact, zero-gap coverage on all 3 fully-mapped files and parses the
entire real 18-file `.CUT` corpus without throwing. See
`WOCCutsceneParserTests.swift` for golden-value regression tests. Three
files (`BLACK.CUT`, `CORRIDOR.CUT`, `STATION.CUT`) have been mapped by
hand as the ground truth this decoder is verified against. `BLACK.CUT` and
`CORRIDOR.CUT` are complete, gap-free, field-level byte-verified maps.
`STATION.CUT` (12,125 bytes, ~12-17x bigger) was first mapped at the
**region level** only (every byte assigned to a region, verified
programmatically to sum to exactly 12,125 bytes with zero gaps/overlaps),
with field-level detail limited to the shared/reused regions, its six
large per-node "zone" interiors (11,776 of the 12,125 bytes) were accounted
for as regions but not field-mapped. **A follow-up session has now pushed
all six zones to real, byte-exact field-level maps**, every one of the
11,776 zone-interior bytes is placed to a specific field, not just a region;
see "STATION.CUT zone interiors: field-level decode" below for the full
breakdown, the newly-confirmed "dense frame-channel array" shape that
recurs identically in all six zones, and an explicit test-and-reject of the
hypothesis that zones reuse `CORRIDOR.CUT`'s 112-byte periodic track-node
shape (they don't, a different, simpler, and even more regular shape is
used instead). `STATION.CUT` is now field-mapped end-to-end with zero
unplaced bytes; a handful of fields still have their *purpose* only
inferred from strong circumstantial/numerical evidence rather than proven
outright (each flagged individually below, in keeping with this document's
existing confidence-labeling convention). The previously load-bearing
blocker, the track-header `count`-to-pointer-count arithmetic disagreement
between `BLACK.CUT` and `CORRIDOR.CUT`, is now **resolved with real
cross-file evidence**, not a guess: see "Track-header list length: resolved
with a 3rd file" below. This makes a decoder implementable in the sense
described there, though several fields still have placed-but-unexplained
bytes, see "Why this isn't a parser yet".

## What `.CUT` is

Per-level, plain uncompressed loose files (18 exist on the disc, sizes
695 bytes to ~1.5MB). Names/strings found inside small samples
(`lower_ring`, `top_ring`, `station1`, `CSCoco_group`, `BigPurra_group`)
cross-reference sibling `.GHG` files byte-for-byte in the same folder
(`CSCOCO.GHG`, `BIGPURRA.GHG`), real evidence this is scripted-sequence
data (camera/prop movement) referencing named actor rigs stored
separately, not dialogue and not an opcode/command script (no
opcode/command-ID structure was found anywhere, ruled out as an
AgentLab-style format).

Small files (under a few KB) are pure scene-graph data. The largest files
(hundreds of KB to 1.5MB) were previously guessed to "almost certainly
carry embedded video/audio payloads" -- **that guess is now corrected by
real evidence, see "Large files (100KB+): not video/audio" below.**

## Confirmed: the pointer scheme

Every `.CUT` file uses **self-relative pointers**: a `UInt32LE` field
whose high 16 bits are a constant specific to that one file (e.g.
`0x5302` in `BLACK.CUT`, `0x29D6` in `CORRIDOR.CUT`) and whose low 16
bits are a real, valid byte offset within the file. Confirmed by finding
every field matching `(value >> 16) == fileConstant` and checking the low
16 bits land in-range, 24 such fields in `BLACK.CUT`, 42 in
`CORRIDOR.CUT`, forming a real reachable graph rooted at file offset 4.
(Re-derived independently for `CORRIDOR.CUT` in a follow-up session:
confirmed `0x29D6` and 42 fields exactly, matching this note.)

**List-terminator idiom**: a pointer whose low 16 bits equal (or land
just past, rounded to the next 16-byte boundary) the file's own total
size acts as an end-of-list sentinel. Confirmed in both `BLACK.CUT` and
`CORRIDOR.CUT`.

**Address aliasing, confirmed and pervasive**: pointers routinely target
the *middle* of an already-mapped structure rather than a fresh record
start, e.g. one pointer lands on row 2 of a transform block whose row 0
is reached by a different pointer elsewhere; another lands on just the
last float of a Vec4 that's also reached whole by a separate pointer.
This looks like the addressing scheme is genuinely byte/element-level,
not record-level, **a linear "walk records front to back" parser will
not work for this format; it needs a graph walker starting from the root
pointer.**

## Confirmed: shapes reused from elsewhere in this codebase

- **Root record** (32 bytes, offset 0x00): `kind:u32(=1)`,
  `ptr→0x20`, `duration:f32` (58.0 in `BLACK.CUT`, 200.0 in
  `CORRIDOR.CUT`), a sentinel/reserved slot, `ptr→root transform`, two
  `f32` zeros, `ptr` into a second sub-block. Identical shape in both
  files checked.
- **4×4 transform block** (64 bytes): row-major, translation in row 3,
  `w == 1.0`, the exact same shape already confirmed for
  `WOCContainerParser.Instance.matrix` (see that file). Found at least
  twice per file, in separately-headered node records, current evidence
  leans toward "one transform per node," not a per-node keyframe curve
  (checked: the float runs near a transform that aren't the transform
  itself don't normalize as quaternions, `sqrt(x²+y²+z²+w²)` ranged
  0.84–59.0, nowhere near 1.0, so a compact quaternion-keyframe reading
  is ruled out for those specific runs).
- **"Track" header** (12 bytes): `duration:f32`, `u16`, `u16`,
  `count:u32`. Found twice in `BLACK.CUT` at offsets 0xA0 and 0x1C0, both
  times followed by exactly `count + 1` pointer-tagged fields rather than
  `count`, seen identically in two places in the same file, so this
  looks like a real convention (a fixed extra trailing pointer after a
  genuinely `count`-long array), not a fluke. **Now cross-checked against
  two more files** (`CORRIDOR.CUT`, `STATION.CUT`), the `count+1` rule
  holds for *some* instances and not others, and the split is now
  understood: see "Track-header list length: resolved with a 3rd file"
  below.
- **Named asset/effect reference**: a node record (16 bytes) with 3
  pointers, one of which resolves to a null-terminated ASCII name (e.g.
  `"STARS2\0"`) immediately followed by 7 `float32` tuning parameters , 
  a particle/effect reference with real parameters, not a rig node.
- **Trailing string pool**: in `STATION.CUT`, a pointer resolves exactly
  to a packed, null-terminated string table sitting at the very end of
  the file (`"lower_ring\0top_ring\0station1\0"`).
- **Dense frame-channel array (16 bytes/entry)**, newly confirmed in a
  follow-up session, found byte-identical in **all six** of `STATION.CUT`'s
  large zones (see "STATION.CUT zone interiors" below): a run of exactly
  110 consecutive 16-byte entries `f32 frameIndex(1..110), f32=1.0
  (constant, exhaustively verified, 550/550 entries across all 6 zones
  match with zero exceptions), f32 valueX(t), f32 valueY(t)`, followed by a
  16-byte "closer" entry `f32=111.0, u32=0x1BC72204 (a fixed constant,
  byte-identical across all 6 zones), f32=(duplicate of the previous
  entry's valueX), f32=0.0`. `110` exactly matches the root record's own
  `duration=110.0`, and `111` matches the `dur=111.0` field seen in the two
  "secondary" track headers elsewhere in the file, real, decisive
  cross-referencing evidence this is a baked one-sample-per-frame animation
  curve, not coincidental data.

## Complete byte-accounting: `BLACK.CUT` only

`/Volumes/CRASH/LEVELS/B/INTRO2/BLACK.CUT`, 695 bytes. Every byte has
been assigned to a specific field, verified programmatically to sum to
exactly 695 bytes with zero gaps and zero overlaps. Byte *placement* is
high-confidence throughout; a handful of ranges have their bytes placed
but their semantic *purpose* still only guessed at (noted below).

| Offset | Len | Contents | Confidence |
|---|---|---|---|
| 0x000–0x01F | 32 | Root record: kind=1, ptr→0x020, f32 dur=58.0, ptr-sentinel→0x2D0, ptr→0x050(xform1), f32=0, f32=0, ptr→0x160(mid-xform2) | High |
| 0x020–0x02F | 16 | Zero padding/reserved | High (value), low (purpose) |
| 0x030–0x03F | 16 | Node B header: kind=1, ptr→0x070, ptr→0x0C0, ptr→0x130 | High |
| 0x040–0x04F | 16 | Reserved, non-zero (`00 00 FF×9 00×5`), mirrors 0x020's slot but filled differently | Bytes high, purpose low |
| 0x050–0x08F | 64 | Transform #1: identity rotation, translation (0,0,-0.843991,1.0) | High |
| 0x090–0x09F | 16 | u32=1, then 12 zero bytes | Medium |
| 0x0A0–0x0AB | 12 | Track header #1: f32 dur=58.0, u16=1, u16=9, u32 count=2 | High |
| 0x0AC–0x0B7 | 12 | 3 pointers (count+1 list): →0x0E0, →0x110, →0x120 | High |
| 0x0B8–0x0BF | 8 | u32=1, f32=0 | Medium |
| 0x0C0–0x0DF | 32 | Two Vec4s: (0,0,0.843991,0), (0,0,1,1) | Bytes high, semantics medium |
| 0x0E0–0x10F | 48 | Record C: f32=1.0, ptr→0x160, u32=0, ptr→0x13C, 32B zero | High |
| 0x110–0x11F | 16 | Record D: u32=1, ptr→0x140, ptr→0x150, f32=0 | High |
| 0x120–0x12F | 16 | Vec4: (0, 0.843991, 0, 0) | High |
| 0x130–0x13F | 16 | Vec4: (0,1,1,1) | High |
| 0x140–0x147 | 8 | 2 pointers: →0x170, →sentinel 0x2C0 | High |
| 0x148–0x14F | 8 | `01 01 00 00`, u32=9 | Low |
| 0x150–0x18F | 64 | Transform #2: identity rotation, translation (0,0,0.968515,1.0) | High |
| 0x190–0x19F | 16 | f32×4: (0, 0, -0.0, 3.028125) | Medium |
| 0x1A0–0x1A3 | 4 | ptr→0x1E0 | High |
| 0x1A4–0x1B3 | 16 | u32=0, u32=8, f32=0.017241 (**= 1/58**, matches the 58.0 duration seen elsewhere), u32=0 | Medium |
| 0x1B4–0x1BF | 12 | f32 dur=59.0, u32=0, u32=2 | Low |
| 0x1C0–0x1CB | 12 | Track header #2: f32 dur=59.0, u16=1, u16=8, u32 count=2 | High |
| 0x1CC–0x1D7 | 12 | 3 pointers (count+1 list): →0x200, →0x220, →0x230 | High |
| 0x1D8–0x1DF | 8 | Zero | High |
| 0x1E0–0x1FF | 32 | 24B zero, ptr→0x240, f32=1.0 | Bytes high, semantics medium |
| 0x200–0x21F | 32 | u32=0, u16(0,1), u32=8, 16B zero | Medium |
| 0x220–0x22F | 16 | STARS2 node record: ptr→0x2B0("STARS2"), ptr→0x2A0, ptr→0x250(mid-block alias), u32=0 | High |
| 0x230–0x29F | 112 | STARS2 parameter blob (7 Vec4s): includes known params 0.2, 3.0, 5.0, 0.05, 3.0, -0.15, 25.0 plus 0.030303, -0.070755, and recurring 58.0/59.0 | Bytes high, full field semantics not exhaustive |
| 0x2A0–0x2AF | 16 | u32=1, u16(1,255), 8B zero | Medium |
| 0x2B0–0x2B6 | 7 | ASCII `"STARS2\0"` | High |

## Complete byte-accounting: `CORRIDOR.CUT`

`/Volumes/CRASH/LEVELS/B/INTRO2/CORRIDOR.CUT`, 976 bytes. Every byte
assigned to a specific field, verified programmatically to sum to exactly
976 bytes with zero gaps and zero overlaps. Pointer constant confirmed as
`0x29D6` (42 pointer-tagged fields found, matching the prior session's
count exactly). Root transform's translation is
`(-10.105168, 0.027334, -0.719901, 1.0)` with a **real, non-identity**
rotation matrix, matches the value predicted before re-derivation and
confirms the transform-block shape holds even when the content (identity
vs. real rotation) differs from `BLACK.CUT`.

| Offset | Len | Contents | Confidence |
|---|---|---|---|
| 0x000–0x01F | 32 | Root record: kind=1, ptr→0x020, f32 dur=200.0, u32=0 (zero, no sentinel ptr here, unlike `BLACK.CUT`), ptr→0x050 (root xform), f32=0, f32=0, u32=0 (zero, no sub-block ptr here, unlike `BLACK.CUT`) | High |
| 0x020–0x02F | 16 | Zero padding/reserved, identical role to `BLACK.CUT` | High (value), low (purpose) |
| 0x030–0x03F | 16 | Node B header: kind=1, ptr→0x070, ptr→0x0C0, ptr-sentinel→0x3D0 (=EOF, exact) | High |
| 0x040–0x04F | 16 | Reserved non-zero blob, **byte-for-byte identical** to `BLACK.CUT`'s blob at the same offset (`00 00 FF×9 00×5`), cross-file confirmation this is a fixed constant, not per-file data | High (bytes, now cross-file confirmed), low (purpose) |
| 0x050–0x08F | 64 | Root transform: real (non-identity) rotation + translation (-10.105168, 0.027334, -0.719901, 1.0) | High |
| 0x090–0x09F | 16 | u32=1, then 12 zero bytes, same shape as `BLACK.CUT`'s analogous field | High (bytes), medium (purpose) |
| 0x0A0–0x0AB | 12 | Track header #1: f32 dur=200.0 (global dur), u16=1, u16=9, u32 count=7, the `(1,9)` u16 pair is byte-identical to `BLACK.CUT`'s Track header #1 | High |
| 0x0AC–0x0D7 | 44 | 11 pointers: 4 "fixed-position" (→0x0E0 Record C, →0x110 Record D, →0x120 quad#1, →0x11C alias into Record D's own body) followed by 7 "counted" (→0x134 alias into quad#2, →0x130 quad#2, →0x1A0, →0x210, →0x280, →0x2F0, →0x360, the 5 periodic node units below). The trailing 7 exactly match `count`; **not** `count+1`. See "Track-header list length" below. | High (bytes), medium (rule) |
| 0x0D8–0x0DF | 8 | f32=1.0, f32=1.0 (`BLACK.CUT`'s analogous slot holds u32=1, f32=0, different values, same 8-byte size class) | Medium |
| 0x0E0–0x10F | 48 | Record C: f32=1.0, u32=1, u32=0, ptr→0x118 (alias into Record D), u32=0x01010101, u32=257, ptr→0x300, u32=1, u32=1, ptr→0x130, u32=0, u32=0, different internal field layout from `BLACK.CUT`'s Record C, same 48-byte size class/role | High (bytes), low (purpose) |
| 0x110–0x11F | 16 | Record D: **four** pointers →0x180, →0x170, →0x140, →0x148 (`BLACK.CUT`'s Record D is u32=1, ptr, ptr, f32=0, a real shape difference, not just values) | High |
| 0x120–0x12F | 16 | Channel-quad #1: (1.0, 0.012658, -10.105168, 0.005487), 3rd float duplicates the root transform's X-translation | High (bytes), medium (purpose) |
| 0x130–0x13F | 16 | Channel-quad #2: (80.0, 0.008333, -9.584925, 0.011274) | High (bytes), medium (purpose) |
| 0x140–0x14F | 16 | Channel-quad #3: (200.0, 0, -7.861617, 0.021710), first float matches the global duration. **Not present** in `BLACK.CUT`'s analogous region (`BLACK.CUT` goes straight to Transform #2 at this point), a real extra field | High (bytes), medium (purpose) |
| 0x150–0x15F | 16 | Int-list quad: u16 pairs (0,1)(1,2)(2,2)(2,0), a pattern absent anywhere in `BLACK.CUT`'s map; recurs (with minor variants) 6 more times later in this same file | High (bytes), low (purpose) |
| 0x160–0x38F | 560 | Five repeating 112-byte "track node" units at 0x160, 0x1D0, 0x240, 0x2B0, 0x320, see breakdown below. This entire periodic structure is absent from `BLACK.CUT`; it's the main reason `CORRIDOR.CUT` is bigger (more nodes/tracks, not a differently-shaped format) | High (bytes/periodicity), medium (purpose) |
| 0x390–0x3CF | 64 | Final (6th, truncated-by-EOF) unit: same 48-byte header shape, but its first pointer-array slot is u32=2 (a real count, not the 1.0/80.0 filler value seen in the other five units), followed by u32=1, ptr→0x3DC (past EOF), ptr→0x3E0 (past EOF), both are end-of-list sentinels, then u32=0, then a 16-byte partial channel-quad-shaped tail cut off by the file boundary: f32=0.719894, f32=80.0, uninterpreted u32=0x1BC819A0 (looks like leftover/non-zeroed data, not text), f32=-0.040676 | High (bytes), medium (purpose) |

**Breakdown of the repeating 112-byte "track node" unit** (5 full instances
at 0x160/0x1D0/0x240/0x2B0/0x320, byte-shape confirmed identical at every
instance):

| Sub-offset | Len | Contents |
|---|---|---|
| +0x00 | 28 | Fixed header: u32=1, u32=0, u32=0x8000, u32=0, u32=0, u32=0, u32=0x80, byte-identical across all 5 instances |
| +0x1C | 20 | 5-slot pointer array. Slot count actually *used* as real pointers varies per instance (5, 3, 3, 3, 3 respectively), unused slots hold filler values (seen: 1.0f, 80.0f, u32=1, u32=2), never zero. This is real, confirmed per-instance variation, not noise |
| +0x30 | 16 | Channel-quad "A": f32≈1.0, f32≈0.012658 (constant across all 5), f32, f32 |
| +0x40 | 16 | Channel-quad "B": f32=80.0 (constant), f32≈0.008333 (constant), f32, f32 |
| +0x50 | 16 | Channel-quad "C": f32=200.0 (constant = global duration), f32=0 (constant), f32, f32 |
| +0x60 | 16 | Int-list quad: u16 pairs (0,1)(1,2)(2,2)(2,0) in 4 of 5 instances; the 5th and 6th (truncated) instances show minor variation in the last pair |

No string pool and no named asset/effect reference (the `STARS2`-style
16-byte-header + 112-byte-parameter-blob + name string pattern from
`BLACK.CUT`) were found anywhere in `CORRIDOR.CUT`, a targeted scan for
printable-ASCII runs found only coincidental bytes from recurring float
constants (e.g. `0x3C4F6475` = 0.012658f prints as `"udO<"`), no real
strings. This pattern from `BLACK.CUT` does **not** generalize to every
`.CUT` file; `CORRIDOR.CUT` appears to be pure transform/animation-channel
data with no named-asset references.

### Track-header list length: `count+1` does not generalize

`BLACK.CUT`'s two track headers were each followed by exactly `count + 1`
pointers, with no unaccounted-for pointers before or after. `CORRIDOR.CUT`
breaks that formula: its one track header has `count = 7`, but is followed
by **11** pointers, not 8. Splitting those 11 by target-shape (4 pointers
land on fixed always-present structures, Record C, Record D, and two
values inside/adjacent to them, while the remaining 7 land exactly on the
7 "track node" pointers: the two 16-byte channel-quads at 0x130/0x134 plus
the 5 periodic 112-byte nodes) makes `count` (not `count + 1`) match the
back 7 exactly. But this can't be fully disambiguated against `BLACK.CUT`,
whose small track headers (count=2, 3 total pointers) are equally
consistent with "0 fixed + count+1" or "1 fixed + count", both single
samples are compatible with more than one rule. **Honest conclusion: the
`count`-to-pointer-count relationship is real and reproducible in shape
(a header, then a run of pointers) but its exact arithmetic is still
unresolved after 2 files**, do not hard-code `count+1` in a decoder.

*(Superseded below, a 3rd file, `STATION.CUT`, resolves this. Left
in place as the honest record of the 2-file state.)*

## Complete byte-accounting: `STATION.CUT` (region-level)

`/Volumes/CRASH/LEVELS/B/INTRO2/STATION.CUT`, 12,125 bytes (~12-17x bigger
than the first two files). Pointer constant confirmed as `0x297A` (77
pointer-tagged fields found). The shared/reused shapes from `BLACK.CUT`/
`CORRIDOR.CUT`, root record, zero-padding block, Node B header, the
`0x040` reserved constant, 4×4 transform, `u32=1`+12-zero block, 12-byte
track header, Record C (48B), Record D (16B), 16-byte channel-quads, all
confirmed present again, byte-for-byte-identical in shape (and in one case,
the `0x040` reserved blob, **byte-for-byte identical in value too**, now
confirmed 3/3 files). What's new: past offset 0x140 the file is dominated
by **six large periodic "zone" regions** (1824-2544 bytes each, 11,776
bytes total), each terminated by a distinctive 16-byte all-bits-set
sentinel (`FF×13, 0x7F, 0x00, 0x00`), the same *role* as `CORRIDOR.CUT`'s
periodic 112-byte "track node" array (a repeating per-node/per-channel
region), just at a much larger per-unit size reflecting richer per-node
data. Verified programmatically: the region table below sums to exactly
12,125 bytes with zero gaps and zero overlaps.

| Offset | Len | Contents | Confidence |
|---|---|---|---|
| 0x000–0x01F | 32 | Root record: kind=1, ptr→0x020, f32 dur=110.0, ptr→0x2F60 (a **real** pointer here, unlike `CORRIDOR.CUT`'s zero, closer to `BLACK.CUT`'s populated sentinel slot, but landing well inside the file, not near EOF), ptr→0x050 (root xform), ptr→0x2A0 (a pointer where `BLACK.CUT`/`CORRIDOR.CUT` hold an `f32` zero, a genuine 3rd variant of this dword's population), f32=0, f32=0 | High (bytes), medium (which dwords are pointers vs. zero varies per file, the 8-dword skeleton itself is confirmed, its exact population is not) |
| 0x020–0x02F | 16 | Zero padding/reserved, same role, 3rd file confirming it | High |
| 0x030–0x03F | 16 | Node B header: kind=1, ptr→0x070, ptr→0x0C0, ptr→0x280, **3 real pointers**, matching `BLACK.CUT`'s shape (not `CORRIDOR.CUT`'s sentinel-in-3rd-slot variant) | High |
| 0x040–0x04F | 16 | Reserved blob `00 00 FF×9 00×5`, **byte-for-byte identical** to both other files; now confirmed 3/3, the strongest constant in this format | High |
| 0x050–0x08F | 64 | Root transform: real non-identity rotation, translation (34.833, -3.738, -36.755, 1.0) | High |
| 0x090–0x09F | 16 | u32=1, then 12 zero bytes, identical shape/value to both other files, 3/3 confirmed | High |
| 0x0A0–0x0AB | 12 | **Root/fan-out track header**: f32 dur=110.0 (matches root record's dur), u16=(1,9) (identical pair to `BLACK.CUT` header #1 and `CORRIDOR.CUT`'s only header), u32 count=4 | High |
| 0x0AC–0x0CB | 32 | 8 pointers: →0x0E0 (Record C), →0x110 (Record D), →0x120 (quad#1), →0x110 (**exact duplicate** of the 2nd pointer, a variant of `CORRIDOR.CUT`'s "alias into Record D's body," here aliasing to Record D's own start instead of mid-body), then 4 "counted" pointers →0x128, →0x130, →0x1B0, →0x200, count(4) matches the last 4 exactly, same "4 fixed + count" rule as `CORRIDOR.CUT`. See resolved discussion below | High (bytes), high (rule, see below) |
| 0x0CC–0x0DF | 20 | f32≈245.038, f32≈-1350.03 (a recurring 8-byte constant pair, also found again at 0x248), then u32=0, f32=1.0, f32=1.0 | Bytes high, purpose low |
| 0x0E0–0x10F | 48 | Record C: f32=1.0, u32=0, u32=0, ptr→0x228, packed bytes `00 01 01 01`, u32=0, ptr→0x100, u32=0, u32=1, ptr→0x310, u32=1, u32=0, complex non-zero internal layout, matching `CORRIDOR.CUT`'s Record C variant, not `BLACK.CUT`'s mostly-zero one | High (bytes), low (field purposes) |
| 0x110–0x11F | 16 | Record D: **four** pointers →0x1A0, →0x190, →0x140, →0x438, matches `CORRIDOR.CUT`'s 4-pointer Record D shape, not `BLACK.CUT`'s `[u32=1,ptr,ptr,f32=0]` shape | High |
| 0x120–0x12F | 16 | Channel-quad #1: (0.0, 0.011236, 34.853, -0.020620) | High (bytes), medium (purpose) |
| 0x130–0x13F | 16 | Channel-quad #2: (89.0, 1.0, 33.018, -0.020620) | High (bytes), medium (purpose) |
| 0x140–0xB2F | 2544 | **Zone 1**: now fully field-mapped (session 4), 3 sparse milestone-keyframe tables, 3 "Record-C-like" 48-byte blocks, a chain of **3 confirmed 64-byte rotation transforms** linked by 28-byte connector records, the already-known secondary track header at 0x3A0 (dur=111.0, u16=(1,9), count=4, 5 trailing pointers) → local Record C (0x3E0) / Record D (0x410), then a 110-entry dense frame-channel array + closer + tail, terminated at 0xB20 by the sentinel, see "STATION.CUT zone interiors" below | High (byte placement, all sub-shapes), medium (some field purposes) |
| 0xB30–0x124F | 1824 | **Zone 2**: now fully field-mapped (session 4), 16-byte chain header (3 pointers + trailing scalar) + 110-entry dense frame-channel array + 16-byte closer + 16-byte tail + sentinel at 0x1240; one header pointer targets 0x1970, i.e. **into Zone 4** (cross-zone chain link), see "STATION.CUT zone interiors" below | High (byte placement, exhaustively verified), medium (field purposes) |
| 0x1250–0x196F | 1824 | **Zone 3**: now fully field-mapped (session 4), same template as Zone 2 (16-byte chain header + 110-entry array + closer + tail), terminated at 0x1960 by the sentinel; its lead-in record at 0x1250 was previously discussed under Zone 2's row (marker-boundary convention, see caveat below), now fully decoded either way, see "STATION.CUT zone interiors" below | High (byte placement, exhaustively verified), medium (field purposes) |
| 0x1970–0x20FF | 1936 | **Zone 4**: now fully field-mapped (session 4), the already-known secondary track header at 0x1970 (dur=111.0, u16=(1,9), count=4, 5 trailing pointers, pointed to explicitly by a pointer at 0x1254) → local Record C (0x19B0) / Record D (0x19E0, fanning out to Zones 5 and 6), then a 110-entry dense frame-channel array + closer + tail, terminated at 0x20F0 by the sentinel, see "STATION.CUT zone interiors" below | High (byte placement, exhaustively verified), medium (field purposes) |
| 0x2100–0x281F | 1824 | **Zone 5**: now fully field-mapped (session 4), same template as Zone 2/3 (16-byte chain header + 110-entry array + closer + tail), terminated at 0x2810 by the sentinel, see "STATION.CUT zone interiors" below | High (byte placement, exhaustively verified), medium (field purposes) |
| 0x2820–0x2F3F | 1824 | **Zone 6**: now fully field-mapped (session 4), same template, but its chain header's first two pointers target the **trailing string pool**, i.e. it's the terminal link in the zone chain; terminated at 0x2F30 by the sentinel, see "STATION.CUT zone interiors" below | High (byte placement, exhaustively verified), medium (field purposes) |
| 0x2F40–0x2F5C | 29 | Trailing string pool: `"lower_ring\0top_ring\0station1\0"`, the exact pool already referenced (but not located byte-for-byte) in the "Confirmed" section above | High |

Caveat on the zone table: the "6 zones bounded by the FF-sentinel" division
is a real, verified partition of the bytes (boundaries found by an exact
16-byte pattern search, not inferred), but zone *content* attribution near
each boundary (e.g., whether a lead-in record belongs to the zone before
or after its sentinel) is a modeling choice, not independently confirmed , 
flagged medium confidence for that reason. *(Historical note: this
paragraph originally continued by saying the zone interiors were not
field-mapped. A follow-up session has since field-mapped all six, see
directly below.)*

## STATION.CUT zone interiors: field-level decode (all six zones)

A follow-up session pushed all six zones from region-level to real
field-level byte accounting, using the same method that worked for the
rest of the file: follow every `(value>>16)==0x297A` pointer, and look for
recurring shapes already confirmed elsewhere in this file. The interiors
turned out to be **much more regular than the rest of the format**, once
the one new repeating primitive below was identified, all six zones
(11,776 bytes) fell out mechanically, with **zero unplaced bytes** and
**zero byte-shape exceptions**, verified programmatically.

**Explicit test-and-reject of the `CORRIDOR.CUT`-reuse hypothesis**: before
finding the real shape, the leading hypothesis (based on zones playing the
analogous "per-node periodic region" role that `CORRIDOR.CUT`'s 112-byte
track-node array plays) was that each zone interior would periodically
repeat that exact 112-byte unit (28-byte fixed header + 20-byte pointer
array + 3×16-byte channel-quads + 16-byte int-list quad). **This is
false.** No 112-byte periodicity, no `u32=1,u32=0,u32=0x8000,...,u32=0x80`
28-byte header, and no 20-byte pointer array of that shape appear anywhere
in any of the six zone interiors, a targeted byte-for-byte search for that
exact 28-byte constant found zero matches outside the file's already-known
occurrences (there are none inside `STATION.CUT` at all; that shape appears
to be `CORRIDOR.CUT`-specific). Instead, the zones use a **different, new,
and considerably simpler** repeating primitive, described next.

### The dense frame-channel array (new confirmed shape, 16 bytes/entry)

Found identically in **all six** zones: a run of exactly **110** consecutive
16-byte entries, immediately followed by a 16-byte "closer" entry, a
16-byte "tail" entry, and the already-known 16-byte sentinel.

| Sub-part | Len | Contents |
|---|---|---|
| Entry *n* (n=1..110) | 16 | `f32 frameIndex` (=`n`, exactly), `f32=1.0` (constant), `f32 valueX(t)`, `f32 valueY(t)` |
| Closer | 16 | `f32=111.0`, `u32=0x1BC72204` (fixed constant, byte-identical in all 6 zones), `f32` = exact duplicate of entry 110's `valueX`, `f32=0.0` |
| Tail | 16 | 4×`u16` = `(0, 32, 64, 96)` (fixed constant, byte-identical in all 6 zones), `f32 param1`, `f32 param2` (real per-zone data, see table below, except Zones 1 and 4 which hold `FLT_MAX` (`0x7F7FFFFF`) in both slots, evidently a "no value" sentinel) |
| Sentinel | 16 | `FF×13, 0x7F, 0x00, 0x00` (already known) |

Verification was exhaustive, not sampled: a script checked all 110 entries
in each of the 6 zones (550 entries total) for `frameIndex == n` and
`f32@+4 == 1.0` exactly, **0 mismatches out of 550**. `110` is the root
record's own `f32 duration=110.0` (offset 0x8), the array is a real
one-sample-per-frame bake of the whole cutscene's duration, not an
arbitrary count. `111` (the closer's frame index) matches the `dur=111.0`
field seen in *both* of the file's "secondary" track headers (0x3A0 and
0x1970), a second, independent piece of cross-referencing evidence that
`111 == duration + 1` is a real, load-bearing convention in this format,
consistent with the already-established `count+1` pointer-list rule.

Per-zone tail params and closer/last-entry values (all confirmed by direct
read, not inferred):

| Zone | Last valueX (entry 110 = closer) | Tail param1 | Tail param2 |
|---|---|---|---|
| 1 | 2.961434 | `FLT_MAX` | `FLT_MAX` |
| 2 | -0.487262 | 69.0 | 1.0 |
| 3 | -2.842437 | 0.002770 | 2.953913 |
| 4 | 0.236568 | `FLT_MAX` | `FLT_MAX` |
| 5 | 0.829059 | 69.0 | 1.0 |
| 6 | 0.389997 | 0.001890 | 0.230693 |

The pairing (1,4 share `FLT_MAX`; 2,5 share the literal `69.0`/`1.0`; 3,6
share small nonzero values) lines up exactly with the structural pairing
found below (Zone 1 fans out to Zones 2 and 3; Zone 4 fans out to Zones 5
and 6), real, corroborating evidence for that pairing, not a coincidence.

### Zone 2, full field map (0xB30–0x124F, 1824 bytes, 100% placed)

| Offset | Len | Contents | Confidence |
|---|---|---|---|
| 0xB30–0xB3F | 16 | Chain header: ptr→0x1260 (Zone 3 array row 1), ptr→0x1250 (Zone 3 header), ptr→0xB60 (self-alias, own array row 3), `u32=0` | High |
| 0xB40–0x121F | 1760 | Dense frame-channel array, 110 entries (see shape above) | High |
| 0x1220–0x122F | 16 | Closer: `111.0, 0x1BC72204, -0.487262 (=entry110's valueX), 0.0` | High |
| 0x1230–0x123F | 16 | Tail: `(0,32,64,96)`, `69.0`, `1.0` | High (bytes), medium (purpose) |
| 0x1240–0x124F | 16 | Sentinel | High |

### Zone 3, full field map (0x1250–0x196F, 1824 bytes, 100% placed)

| Offset | Len | Contents | Confidence |
|---|---|---|---|
| 0x1250–0x125F | 16 | Chain header: ptr→0x1980 (Zone 4 array row 1), ptr→0x1970 (Zone 4 header/secondary track header), ptr→0x1280 (self-alias, own array row 3), `f32=1.0` | High |
| 0x1260–0x193F | 1760 | Dense frame-channel array, 110 entries | High |
| 0x1940–0x194F | 16 | Closer: `111.0, 0x1BC72204, -2.842437, 0.0` | High |
| 0x1950–0x195F | 16 | Tail: `(0,32,64,96)`, `0.002770`, `2.953913` | High (bytes), medium (purpose) |
| 0x1960–0x196F | 16 | Sentinel | High |

### Zone 4, full field map (0x1970–0x20FF, 1936 bytes, 100% placed)

This zone's first 128 bytes were already documented (secondary track
header + local Record C/D); this session confirmed their exact internal
layout and found the dense frame-channel array that follows.

| Offset | Len | Contents | Confidence |
|---|---|---|---|
| 0x1970–0x197B | 12 | Secondary track header: `f32 dur=111.0, u16=1, u16=9, u32 count=4` | High |
| 0x197C–0x198F | 20 | 5 pointers (`count+1`): →0x19B0, →0x19E0, →0x19F0, →0x19E0 (dup), →0x19F8 | High |
| 0x1990–0x199B | 12 | Zero | High |
| 0x199C–0x19A7 | 12 | 3 pointers: →0x1A00, →0x2120 (Zone 5 interior), →0x2840 (Zone 6 interior) | High |
| 0x19A8–0x19AF | 8 | `f32=1.0, f32=1.0` | Medium |
| 0x19B0–0x19DF | 48 | Record C: `f32=1.0, u32=0, u32=0, ptr→0x20C8` (mid-array alias, row 110's valueX field, a real address-aliasing case), packed bytes `00 00 00 01 01 01 00 00`, `ptr→0x1900` (Zone 3 interior), `u32=0, u32=9, ptr→0x2780` (Zone 5 interior), `u32=1, u32=0` | High (bytes), low (purpose) |
| 0x19E0–0x19EF | 16 | Record D (4-pointer variant): →0x2110 (Zone 5 array row 1), →0x2100 (Zone 5 header), →0x1A10 (self-alias, own array row 3), →0x2E38 (Zone 6 interior, mid-array alias) | High |
| 0x19F0–0x20CF | 1760 | Dense frame-channel array, 110 entries | High |
| 0x20D0–0x20DF | 16 | Closer: `111.0, 0x1BC72204, 0.236568, 0.0` | High |
| 0x20E0–0x20EF | 16 | Tail: `(0,32,64,96)`, `FLT_MAX`, `FLT_MAX` | High |
| 0x20F0–0x20FF | 16 | Sentinel | High |

Zone 4's Record D fans out to **both** Zone 5 and Zone 6, real evidence
that Zone 4 is the "node" for a pair of channel zones, exactly mirroring
Zone 1's relationship to Zones 2 and 3 (below).

### Zone 5, full field map (0x2100–0x281F, 1824 bytes, 100% placed)

| Offset | Len | Contents | Confidence |
|---|---|---|---|
| 0x2100–0x210F | 16 | Chain header: ptr→0x2830 (Zone 6 array row 1), ptr→0x2820 (Zone 6 header), ptr→0x2130 (self-alias, own array row 3), `u32=0` | High |
| 0x2110–0x27EF | 1760 | Dense frame-channel array, 110 entries | High |
| 0x27F0–0x27FF | 16 | Closer: `111.0, 0x1BC72204, 0.829059, 0.0` | High |
| 0x2800–0x280F | 16 | Tail: `(0,32,64,96)`, `69.0`, `1.0` | High (bytes), medium (purpose) |
| 0x2810–0x281F | 16 | Sentinel | High |

### Zone 6, full field map (0x2820–0x2F3F, 1824 bytes, 100% placed)

| Offset | Len | Contents | Confidence |
|---|---|---|---|
| 0x2820–0x282F | 16 | Chain header: ptr→0x2F50 (trailing string pool, mid-string), ptr→0x2F40 (string pool start, the file's very last structure), ptr→0x2850 (self-alias, own array row 3), `f32=1.0` | High |
| 0x2830–0x2F0F | 1760 | Dense frame-channel array, 110 entries | High |
| 0x2F10–0x2F1F | 16 | Closer: `111.0, 0x1BC72204, 0.389997, 0.0` | High |
| 0x2F20–0x2F2F | 16 | Tail: `(0,32,64,96)`, `0.001890`, `0.230693` | High (bytes), medium (purpose) |
| 0x2F30–0x2F3F | 16 | Sentinel | High |

Zone 6 is the terminal zone in the chain, its header's first two
pointers, which in every other zone target the *next* zone's array-row-1
and header, instead target the trailing string pool (the last structure in
the file). The `+0x10`/`+0x00` arithmetic still holds exactly (`0x2F50 =
0x2F40+0x10`), it just no longer lands on a zone; it happens to land 5
bytes into `"top_ring"` inside the pool. This looks like fixed-offset
boilerplate applied uniformly regardless of what's actually there at the
terminal link, not a meaningful reference to that specific string byte.

### Zone 1, full field map (0x140–0xB2F, 2544 bytes, 100% placed)

The most structurally rich zone: besides its already-known secondary track
header and local Record C/D, it opens with three sparse
milestone-keyframe tables and contains a chain of three confirmed 64-byte
rotation-transform blocks, the same transform shape already established
elsewhere in this file and in `BLACK.CUT`/`CORRIDOR.CUT` (row-major, real
rotation, translation row with `w==1.0`), reused here for what looks like
rotation keyframes with zero translation delta.

**Correction (implementation session)**: this table originally listed
`0x140`–`0x16F` as a standalone 3-entry "sparse milestone table A" and
`0x120`/`0x130` (in the root-level table above) as two separate
"channel-quads", and explicitly flagged the relationship between them as
an open question in "Suggested next steps" below ("worth specifically
re-checking whether ... the same ... primitive"). Direct byte
verification during decoder implementation confirms they are **not**
separate: `0x120`–`0x16F` (80 bytes) is one continuous 5-entry sparse
milestone table, frames `0.0, 89.0, 90.0, 97.0, 110.0`, weights `1/89,
1/1, 1/7, 1/13, 0` (terminal), matching the reciprocal-delta formula with
zero exceptions across all 4 non-terminal transitions. The former
"channel-quad #1" (`0x120`) and "channel-quad #2" (`0x130`) are simply
this table's first two entries. The row below is kept for the historical
per-16-byte breakdown but the real record boundary is `0x120`, not
`0x140`.

| Offset | Len | Contents | Confidence |
|---|---|---|---|
| 0x120–0x16F | 80 | Sparse milestone table A (corrected boundary, see above), 5 entries: `(0.0, 1/89, 34.8534, -0.02062)`, `(89.0, 1.0, 33.018, -0.02062)`, `(90.0, 1/7, 33.018215, 0.0)`, `(97.0, 1/13, 33.018215, 0.0)`, `(110.0, 0.0, 33.018215, 0.0)`, see "Sparse milestone tables" below | High (bytes), high (interpolation-weight formula, verified) |
| 0x170–0x19F | 48 | "Record-C-like" block #1: mixed `u16` pairs/counts, 1 embedded pointer (→0x1A8, mid-table-B alias) at +0xC, then 3 more pointers at the block's tail (→0x1F0, →0x1E0, →0x1C0) + `u32=0` | High (bytes/pointer positions), low (non-pointer field purposes) |
| 0x1A0–0x1BF | 32 | Sparse milestone table B, 2 entries: `(1.0, 1/109, -3.7377, -0.000132)`, `(110.0, 0.0, -3.752045, -0.000132)` | High (bytes), high (interpolation-weight formula, verified) |
| 0x1C0–0x1EF | 48 | "Record-C-like" block #2: `u16` pairs/counts, then 3 pointers (→0x270, →0x260, →0x210) + trailing `f32=0.011236` (=1/89, the same reciprocal-weight convention as the milestone tables, not zero like block #1) | High (bytes/pointer positions), low (non-pointer field purposes) |
| 0x1F0–0x23F | 80 | Sparse milestone table C, 5 entries: `(0.0, 1/89, 36.7727, -0.017925)`, `(89.0, 1.0, 35.1774, -0.017925)`, `(90.0, 1/7, 35.1774, 0.0)`, `(97.0, 1/13, 35.1774, 0.0)`, `(110.0, 0.0, 35.1774, 0.0)` | High (bytes), high (interpolation-weight formula, verified) |
| 0x240–0x26F | 48 | "Record-C-like" block #3: `u16` pairs/counts, `f32=245.038, f32=-1350.03` (the same recurring constant pair already noted at 0x0CC), then 2 pointers (→0x28C, →0x290) + `f32=1.0` | High (bytes/pointer positions), low (non-pointer field purposes) |
| 0x270–0x27F | 16 | Channel-quad reprise: `(0.0, 0.011236, -0.02062, 34.8534)`, same 4 numbers (reordered) as the root-level channel-quad #1 at 0x120 | High (bytes), low (purpose) |
| 0x280–0x287 | 8 | Mini lead-in: `ptr→0x2A8, u32=3` | Medium |
| 0x288–0x2C7 | 64 | **Transform A** (confirmed shape): rotation rows `(0.977574, 0.2039, -0.052657)`, `(-0.209774, 0.964845, -0.158332)`, `(0.018522, 0.165827, 0.985981)`, translation row `(0.0, 0.0, -0.0, 1.0)` | High |
| 0x2C8–0x2E3 | 28 | Connector #1: `u32=1, u32=0, u32=0, ptr→0x3C0, u32=0, u32=0x03629DC8 (fixed constant, recurs at 0x338/0x394), u32=1` | High (bytes), low (purpose) |
| 0x2E4–0x323 | 64 | **Transform B**: rotation rows `(0.97767, 0.209059, -0.021347)`, `(-0.209774, 0.964845, -0.158332)` (**identical middle row to Transform A**, consistent with rotation about a near-fixed axis across nearby keyframes), `(-0.012504, 0.159274, 0.987155)`, translation row `(0.0, 0.0, -0.0, 1.0)` | High |
| 0x324–0x33F | 28 | Connector #2: `u32=12, u32=0, u32=0, ptr→0x1990` (**Zone 4's lead-in**, a real cross-zone reference), `u32=0, u32=0x03629DC8, u32=1` | High (bytes), low (purpose) |
| 0x340–0x37F | 64 | **Transform C**: rotation rows `(0.977738, 0.207789, -0.029178)`, `(-0.209774, 0.964845, -0.158332)` (same middle row again), `(-0.004748, 0.160928, 0.986955)`, translation row `(0.0, 0.0, -0.0, 1.0)` | High |
| 0x380–0x39F | 32 | Tail connector: `u32=21, u32=0, u32=0, u32=0, u32=0, u32=0x03629DC8, u32=1, ptr→0x3C8` | High (bytes), low (purpose) |
| 0x3A0–0x3AB | 12 | Secondary track header (already known): `f32 dur=111.0, u16=1, u16=9, u32 count=4` | High |
| 0x3AC–0x3BF | 20 | 5 pointers (`count+1`, already known) | High |
| 0x3C0–0x3CF | 16 | `u32=0, u32=0, u32=0, ptr→0x430` (self-alias into own array row 2) | High |
| 0x3D0–0x3DF | 16 | 2 cross-zone pointers (→0xB50 Zone 2 interior, →0x1270 Zone 3 interior) + `f32=1.0, f32=1.0` | High |
| 0x3E0–0x40F | 48 | Record C (already known, local to Zone 1) | High (bytes), low (purpose) |
| 0x410–0x41F | 16 | Record D (4-pointer variant, already known): →0xB40 (Zone 2 array row 1), →0xB30 (Zone 2 header), →0x440 (self-alias, own array row 3), →0x1868 (Zone 3 interior) | High |
| 0x420–0xAFF | 1760 | Dense frame-channel array, 110 entries | High |
| 0xB00–0xB0F | 16 | Closer: `111.0, 0x1BC72204, 2.961434, 0.0` | High |
| 0xB10–0xB1F | 16 | Tail: `(0,32,64,96)`, `FLT_MAX`, `FLT_MAX` | High |
| 0xB20–0xB2F | 16 | Sentinel | High |

Byte accounting for Zone 1 was verified to sum to exactly 2544 with zero
gaps and zero overlaps, matching its region-table range exactly.

Zone 1's Record D fans out to **both** Zone 2 and Zone 3, mirroring Zone
4's fan-out to Zones 5 and 6 exactly. Combined with the shared tail-param
pairing noted above, this gives a coherent structural model for the whole
back half of the file: **two "node" zones (1 and 4), each carrying its own
rotation-transform keyframe chain and a secondary track header, each
fanning out via its Record D to two "pure channel" zones** (1→{2,3},
4→{5,6}) that hold only dense per-frame value curves with no header
structure of their own beyond the 16-byte chain link.

### Sparse milestone tables and reciprocal-delta interpolation weights (Zone 1)

The three tables at 0x140, 0x1A0, and 0x1F0 share a shape distinct from
the dense frame-channel array: instead of one entry per frame, they hold
only a handful of entries at *milestone* frame numbers (`{90, 97, 110}`,
`{1, 110}`, `{0, 89, 90, 97, 110}`), each `16 bytes: f32 milestoneFrame,
f32 weight, f32 valueX, f32 valueY`. The `weight` field is not constant
like the dense array's, it was hypothesized and then numerically verified
to equal **`1.0 / (nextMilestoneFrame - thisMilestoneFrame)`** for every
non-terminal entry, checked against all 6 qualifying rows across the 3
tables with **zero mismatches** (e.g. table C: frame 0→89, delta 89,
weight 1/89=0.011236 ✓; frame 89→90, delta 1, weight 1/1=1.0 ✓; frame
90→97, delta 7, weight 1/7=0.142857 ✓; frame 97→110, delta 13, weight
1/13=0.076923 ✓). The terminal entry of each table always has `weight=0.0`.
This reads as a genuine sparse/held keyframe channel with an explicit
per-segment interpolation-rate field, distinct from (but the same 16-byte
size class as) the dense per-frame array, high confidence on the formula,
medium confidence on which specific animated property (position component,
rotation component, etc.) each of the three tables drives.

**Partial answer on "which property" (table B only, real numeric
match)**: `STATION.CUT`'s root transform translation is `(34.833,
-3.738, -36.755, 1.0)` (see the root region table above). Table B's
`valueX` column is `-3.7377` (frame 1) settling to `-3.752045` (frame
110), matching the root transform's own **Y** translation (`-3.738`) to
within `0.015`, both ends. This is a real, checked correlation (not
approximate to the point of coincidence, the match is far tighter than
tables A/C get to any component of the root translation) and reads as
table B being this node's Y-position channel, essentially static across
the animation. Tables A and C do **not** get an equally clean match to
any single root-translation component: both hover in the `33`–`37` range
(loosely near the root's X, `34.833`) but neither is a tight match, and
neither is anywhere near the root's Z (`-36.755`). Whatever A and C
individually represent is still open, they may be two different
objects' X-coordinates (e.g. a camera and a look-at target sharing a
neighborhood) rather than a clean X/Z pair for one node, since a clean
X/Z pairing would need one of them near `-36.755` and neither is.

### Cross-zone addressing patterns (new, confirmed)

- **Chain-header arithmetic is fixed, not per-zone data.** In every zone
  that has the simple 16-byte "chain header" (Zones 2, 3, 5, 6), the first
  pointer targets `nextZoneStart + 0x10` (the next zone's array row 1), the
  second targets `nextZoneStart + 0x00` (the next zone's own header/array
  start), and the third targets `ownZoneStart + 0x30` (this zone's own
  array row 3), verified identical in all 4 instances. This holds even at
  the chain's terminal link (Zone 6 → string pool), where the pointers
  still resolve to `stringPoolStart+0x10`/`+0x00` even though nothing
  meaningful lives at the `+0x10` offset there.
- **The `0x1BC72204` closer constant** is byte-identical across all six
  zones (Zones 1–6), making it a confirmed fixed format constant rather
  than leftover/uninitialized memory, unlike the *similar-looking but not
  identical* `0x1BC819A0` value flagged as "leftover, not text" in
  `CORRIDOR.CUT`'s truncated final track-node unit. The two values share a
  suspicious `0x1BC7`/`0x1BC8` high-byte pattern across files but are not
  byte-identical, so a direct link between them is not established, flagged
  as an open question, not a fact.
- **The `0x03629DC8` connector constant** recurs 3 times, byte-identical,
  inside Zone 1's three 28/32-byte "connector" records between its chained
  transforms (0x2DC, 0x338, 0x394), a second confirmed fixed constant,
  independent of the closer constant above.

### Track-header list length: resolved with a 3rd file

`STATION.CUT` contains **three** real instances of the 12-byte track
header shape (found by an exhaustive scan of every 4-byte-aligned offset
in the file for `u16 pair == (1,9)` immediately following a plausible
`f32` duration, this is exhaustive, not a sample: no other instance of
this exact header exists anywhere in the file). All three instances share
the **identical** `(u16,u16)=(1,9)` pair and the **identical** `count=4`,
yet split cleanly into two different pointer-count outcomes:

| File | Header offset | Role | count | actual trailing ptrs | delta |
|---|---|---|---|---|---|
| `BLACK.CUT` | 0x0A0 | only node in the file | 2 | 3 | **+1** |
| `BLACK.CUT` | 0x1C0 | only node in the file | 2 | 3 | **+1** |
| `CORRIDOR.CUT` | 0x0A0 | root/fan-out (feeds 5 periodic nodes) | 7 | 11 | **+4** |
| `STATION.CUT` | 0x0A0 | root/fan-out (feeds the 6 zones) | 4 | 8 | **+4** |
| `STATION.CUT` | 0x03A0 | per-node, inside Zone 1 | 4 | 5 | **+1** |
| `STATION.CUT` | 0x1970 | per-node, inside Zone 4 | 4 | 5 | **+1** |

This is decisive, real evidence, not a guess: **the delta is determined by
the header's structural role, not by `count` or by the header's own bytes**
(`STATION.CUT`'s three headers are byte-identical in their `(u16,u16)` and
`count` fields and still split 4/1/1). Two roles, confirmed with zero
exceptions across 6 total instances in 3 files:

- **Root/fan-out track header**: found exactly once per file, always
  reached *positionally* (immediately after the fixed prologue: root
  record → zero-padding → Node B header → root transform → `u32=1`+12-zero
  block), never targeted by any pointer. Its trailing pointers =
  **4 fixed** (→Record C, →Record D, →quad#1, →an alias back into Record
  D, the exact alias target varies: `CORRIDOR.CUT` aliases to
  Record D + 0xC, `STATION.CUT` aliases to Record D + 0x0, i.e. an exact
  duplicate of the 2nd pointer) followed by **`count`** further pointers,
  one per fanned-out node/channel. Confirmed identically in `CORRIDOR.CUT`
  (count=7 → 11) and `STATION.CUT` (count=4 → 8), 2/2 files that have
  this kind of header agree exactly.
- **Per-node/secondary track header**: found once per animated node,
  reached either positionally (after that node's own local lead-in
  structure, as in `STATION.CUT` Zone 1's header at 0x3A0) or via a direct
  pointer from elsewhere (as in `STATION.CUT` Zone 4's header at 0x1970,
  pointed to explicitly by the pointer at 0x1254). Its trailing pointers =
  **`count + 1`**. Confirmed in `BLACK.CUT` (both headers) and
  `STATION.CUT` (both secondary headers), 4/4 instances across 2 files
  agree exactly.

**Why this isn't a contradiction with the old 2-file finding**:
`CORRIDOR.CUT`'s single header and `BLACK.CUT`'s two headers were never
testing the same rule, `CORRIDOR.CUT`'s happened to be the root/fan-out
variant, `BLACK.CUT`'s were both the per-node variant. `BLACK.CUT` (695
bytes, apparently a single-node file) simply has no periodic multi-node
array to fan out to, so it never exercises the root/fan-out header shape
at all, its lone track header goes straight to the per-node form. This
isn't fully airtight (a root/fan-out header with `count=1` would be
byte-indistinguishable from a per-node header with `count=1` using only
this rule, role, not count, is still the real discriminant, and role
currently has to be inferred from parse order: is this the file's *first*
track header, reached without following any pointer?), but it is a real,
falsifiable, cross-file-confirmed pattern with zero counterexamples in 6
instances across 3 files, which is a meaningfully stronger evidentiary bar
than the 2-file state this section previously described.

**Practical takeaway for a decoder**: when parsing the fixed positional
prologue and encountering the *first* track header (the one reached
without following a pointer), read `4 + count` trailing pointers. Every
subsequent track header encountered while walking the graph (reached via
pointer or positionally after a node's own lead-in) should read
`count + 1` trailing pointers. This is implementable, parse order tells
you which rule applies, no header-byte heuristic is needed.

## Side-by-side comparison: `BLACK.CUT` vs. `CORRIDOR.CUT`

**Identical in shape (confirmed cross-file):**
- Self-relative pointer scheme (`(value>>16)==fileConstant`, low 16 bits
  = in-range offset), same mechanism, different per-file constant.
- List-terminator idiom (pointer whose low 16 bits land at/past EOF) , 
  confirmed in both, though `CORRIDOR.CUT`'s two sentinels (`0x3DC`,
  `0x3E0`) overshoot EOF by 12 and 16 bytes rather than landing exactly on
  it, so "rounds to a 16-byte boundary" is not quite right either, both
  are just "past EOF," full stop.
- Zero-padding block at 0x020 (16 bytes).
- The reserved blob at 0x040, **byte-for-byte identical**, the strongest
  single piece of cross-file evidence in this investigation: this 16-byte
  sequence is a genuine fixed constant, not incidentally-similar per-file
  data.
- 4×4 transform block (64 bytes, row-major, translation in row 3, w=1.0)
 , same shape confirmed with *different* content: `BLACK.CUT`'s is
  identity rotation, `CORRIDOR.CUT`'s is a real non-identity rotation , 
  good evidence the shape, not just the zero-filled special case, holds.
- 12-byte track header (`f32 dur, u16, u16, u32 count`), same shape, and
  `CORRIDOR.CUT`'s `(u16,u16)=(1,9)` is literally identical to
  `BLACK.CUT`'s Track header #1.
- Root record's 32-byte, 8-dword skeleton (kind/ptr/dur/slot/ptr/f32/f32/
  slot), same positions and field *types*, but not the same population
  (see differences).

**Real, confirmed differences (not just "bigger"):**
- Root record: `BLACK.CUT` populates the 4th dword as a sentinel pointer
  and the 8th dword as a pointer to a second sub-block; `CORRIDOR.CUT`
  leaves both zero. `CORRIDOR.CUT` apparently has no second root-level
  sub-block.
- Node B header's 3rd field: a real pointer to further structure in
  `BLACK.CUT`, an end-of-list sentinel in `CORRIDOR.CUT`.
- Record C and Record D reuse the same *size classes* (48 and 16 bytes)
  in both files but have **different internal field layouts** (different
  pointer counts and positions), these are not fixed formats, they're
  count/context-dependent chunks that happen to share a size class.
- `CORRIDOR.CUT` has a third channel-quad (0x140, prefix 200.0) that
  `BLACK.CUT`'s analogous region does not have.
- The big structural difference: `CORRIDOR.CUT` has a **periodic run of
  five (plus one truncated) 112-byte "track node" units** (0x160–0x3CF,
  600 of the file's 976 bytes) that has no counterpart anywhere in
  `BLACK.CUT`. This, not a different record vocabulary, is why
  `CORRIDOR.CUT` has 42 pointers against `BLACK.CUT`'s 24: one track
  header fanning out into many more same-shaped nodes, not new record
  types.
- `BLACK.CUT` has a named `STARS2` effect reference (16-byte header + 112-
  byte parameter blob + null-terminated name). `CORRIDOR.CUT` has **no**
  named asset/effect reference and **no** string pool anywhere in the
  file, this pattern is confirmed present in at least one `.CUT` file
  and confirmed absent in another; it's optional/content-dependent, not
  universal.

## Why this isn't a parser yet

1. **Three files now have byte-accounting, and all three are field-level
   gap-free.** `BLACK.CUT` and `CORRIDOR.CUT` were already field-level
   gap-free; a follow-up session pushed `STATION.CUT` from region-level to
   field-level as well, all six of its large per-node zones (11,776 of its
   12,125 bytes) are now decoded field-by-field with zero unplaced bytes
   (see "STATION.CUT zone interiors: field-level decode" above). The
   track-header list-length arithmetic that blocked this before is resolved
   with real cross-file evidence (see "Track-header list length: resolved
   with a 3rd file" above), that specific blocker is gone. What remains
   before this codebase's own "confirmed" bar (see `WOCAIParser.swift`'s
   doc comment: "confirmed by exact byte consumption") is fully met is
   narrower now: a number of individual fields have their *byte placement*
   fully confirmed but their *semantic purpose* only inferred from strong
   circumstantial/numerical evidence (e.g. the "Record-C-like" blocks'
   non-pointer fields in Zone 1, the exact meaning of the two `f32` tail
   params per zone, which physical animated property each of Zone 1's three
   sparse milestone tables drives). None of these are placement gaps, they
   are purpose gaps on fields whose bytes are fully accounted for. A 4th
   file would still strengthen confidence on the purpose questions.
2. **It's a graph, not a pure record stream, but not a pure graph
   either.** Several structures (the root record's own dwords, the
   zero-padding block, Node B's header) are reached purely positionally
   (nothing points at file offset 0x030 in either file, it's read
   because it immediately follows the 16-byte padding block, not because
   a pointer names it). The variable/large content (transforms, track
   nodes, effect blobs) *is* reached by pointer-following, with confirmed
   address-aliasing (pointers landing mid-structure). A real decoder needs
   a **hybrid**: a small fixed positional prologue, then a pointer-
   following graph walker for everything reachable from it, not a purely
   linear scanner and not a purely address-driven graph walk either.
3. **Several fields are "bytes placed, purpose guessed"** across all three
   files, `STATION.CUT`'s zone interiors included. Implementing against a
   guessed purpose (rather than an open/undecoded field) risks presenting a
   wrong interpretation as settled fact, exactly what this codebase's
   decoders elsewhere are careful never to do (see `SpecRecord`'s own doc
   comment for the pattern: expose confirmed fields typed, leave the rest
   raw and explicitly flagged as open).

## Decoder design sketch (not implemented, for a future session)

1. **Constant derivation**: read the dword at file offset 4; its high 16
   bits are this file's pointer constant. (Confirmed convention in both
   files, offset 4 is always the root record's 2nd dword, always a valid
   pointer.)
2. **Fixed positional prologue** (confirmed identical across both files,
   read without following any pointer):
   - 0x000–0x01F: root record (32 bytes, 8 dwords).
   - 0x020–0x02F: zero-padding block (16 bytes).
   - 0x030–0x03F: Node B header (16 bytes), reached positionally, not by
     pointer.
3. **Graph walk from there**, following every dword matching
   `(value >> 16) == fileConstant` and `(value & 0xFFFF) < fileSize`:
   - Maintain a **visited-offsets** set keyed by exact byte offset (not
     record start), since aliasing means two different pointers can
     legitimately target different bytes inside the same record.
   - Maintain a separate **record-start** map (offset → inferred type) so
     a second pointer landing mid-record can be resolved as "byte N into
     record X" rather than misread as a new record.
   - A pointer whose target's low 16 bits are ≥ file size is a
     terminator/no-op, not a decode error.
4. **Record-type dispatch cannot be pure byte-sniffing.** A 16-byte
   channel-quad (`f32, f32, f32, f32`) and the first 16 bytes of a 12-byte
   track header padded to 16 are not reliably distinguishable by content
   alone (both are 4 arbitrary-looking dwords). Dispatch must primarily
   use **which field pointed here** (the referencing record's own type +
   slot index tells you what's expected at the target) with byte-shape
   validation (size-class match, known-constant recognition like the
   `0x40` reserved blob or the `(1,0,0x8000,0,...,0x80)` 28-byte node
   header) as a secondary check, not the primary signal.
5. **List vs. single record**: detected two ways so far, and a decoder
   should support both rather than assuming one: (a) an explicit
   `u32 count` in a preceding track header, now resolved (see
   "Track-header list length: resolved with a 3rd file" above): the
   *first* track header reached in the graph (positionally, before any
   pointer is followed) takes `4 + count`; every subsequent one takes
   `count + 1`; (b) scanning a run of consecutive pointer-tagged dwords
   starting right after a known anchor until hitting either a non-pointer
   value or an EOF-sentinel; (c) **new**: a run of exactly `floor(duration)`
   consecutive 16-byte entries matching `f32 frameIndex==n, f32==1.0, f32,
   f32` for `n=1..floor(duration)`, terminated by a fixed-shape 16-byte
   closer (`f32=floor(duration)+1, u32=0x1BC72204, f32=dup-of-last-entry,
   f32=0.0`) then a fixed-shape 16-byte tail (`u16×4=(0,32,64,96)`, 2 free
   `f32` params) then the already-known 16-byte sentinel, confirmed
   byte-identical in all six of `STATION.CUT`'s zones (see "STATION.CUT
   zone interiors" above); a decoder can detect this shape directly by its
   fixed closer/tail constants rather than needing a preceding count field.
6. **New: sparse milestone-keyframe list**, found in `STATION.CUT` Zone 1.
   Same 16-byte entry size as the dense array above, but entries are not
   consecutive frame numbers, each entry is `f32 milestoneFrame, f32
   weight, f32 valueX, f32 valueY` where `weight == 1.0 /
   (nextEntry.milestoneFrame - thisEntry.milestoneFrame)` for every
   non-terminal entry and `weight == 0.0` for the last. A decoder can
   validate a candidate run against this formula to confirm it found a real
   instance rather than arbitrary floats, see "Sparse milestone tables and
   reciprocal-delta interpolation weights" above.

## Is the decoder in this sketch now safely implementable?

**Yes, with caveats.** Confidence in the record vocabulary and the
graph-walk algorithm is now high enough to trust a Swift implementation of
the *byte-placement* layer, i.e. an implementation that walks the pointer
graph, correctly consumes every byte of every record type documented in
this file (root record, zero-padding, Node B header, 4×4 transform, `u32=1`
+12-zero block, both track-header roles with their now-resolved pointer
counts, Record C/D in all their observed variants, 16-byte channel-quads,
the dense frame-channel array + closer + tail + sentinel, the sparse
milestone table, the 28-byte connector, `CORRIDOR.CUT`'s 112-byte periodic
track-node unit, the `STARS2`-style named-asset blob, and the trailing
string pool), and produces a typed node/graph structure with **zero
leftover/unaccounted bytes** on all three files this document covers. That
placement-level confidence is now backed by exhaustive, programmatic,
zero-exception verification (550/550 dense-array entries, 6/6 milestone
interpolation weights, 3/3 files' track-header pointer counts, byte-exact
region sums on every file), not sampling.

**What such an implementation would still need to handle honestly**: several
fields have confirmed placement but only inferred purpose (see point 3
above and the "purpose: low/medium" flags throughout this document), a
correct decoder should expose those as raw/untyped bytes (following this
codebase's own `SpecRecord` convention) rather than presenting a guessed
interpretation as fact. Concretely: the non-pointer fields inside Zone 1's
"Record-C-like" 48-byte blocks, the exact meaning of the two free `f32`
tail params per zone (real data in 4 of 6 zones, `FLT_MAX` sentinel in the
other 2), which physical property each of Zone 1's three sparse milestone
tables actually drives, and the handful of already-known-but-unexplained
fields in `BLACK.CUT`/`CORRIDOR.CUT`'s own tables (e.g. `BLACK.CUT`
0x148–0x14F, `CORRIDOR.CUT`'s `0x01010101`/`257` field in Record C), all of
these should decode as typed-but-opaque/raw fields, not as claimed
semantics. The largest files on disc (hundreds of KB–1.5MB) are no longer
completely uninvestigated -- see "Large files (100KB+): not video/audio"
below for a real, evidence-based characterization (not a full decode);
nothing else in this document should be assumed to generalize to those
without checking.

## Large files (100KB+): not video/audio

This document previously guessed the largest `.CUT` files "almost
certainly carry embedded video/audio payloads." Direct investigation of
`SUNNY.CUT` (118,225 bytes -- the smallest file in this size class)
refutes that guess with real evidence, though it does **not** achieve a
full decode.

`WOCCutsceneParser` recognizes only 1.2% of `SUNNY.CUT` (1,377 of 118,225
bytes) under the shapes confirmed from `BLACK.CUT`/`CORRIDOR.CUT`/
`STATION.CUT` -- its opening ~0x2E0 (740) bytes follow a recognizable
pattern (multiple transforms and channel-quads in sequence, several
Record C/D pairs, a chain header, several sparse milestone tables), but a
different arrangement than any of the three fully-mapped files, and it
falls into large unrecognized regions well before reaching 1% of the way
through the file. The four largest unrecognized regions checked (18,432
to 42,480 bytes each) are **not** consistent with compressed or encoded
video/audio:

- **Shannon entropy 5.5-5.9 bits/byte** across all four regions checked
  (would be close to 8.0 -- indistinguishable from random -- for
  genuinely compressed or encrypted data).
- **Byte `0x00` dominates every region** (26-31% of all bytes) -- real
  compressed/encoded streams don't have one byte value that dominant.
- **The next-most-common bytes are exactly what real `Float32` data
  produces**: `0x3F`/`0x40`/`0x42`/`0x43`/`0xBF` (consistent with IEEE754
  high bytes for values in the roughly 0.5-256 magnitude range, both
  signs) recur far more often than chance would predict from a uniform
  byte distribution.
- **A real periodic structure was found by hand** in the first checked
  region (offset `0x30B1`): a repeating ~16-byte-aligned pattern where
  sub-offset+2 is consistently `0x43` (matching a real `Float32` high
  byte, not noise), followed shortly after by a clean ascending `UInt16`
  sequence (`1, 1, 1, 4, 5, 8, 13, 14, 16, 20, 25, 26, 31, ...`) --
  plausibly frame/keyframe indices, structurally similar in spirit to
  (but not byte-identical to, and not yet matched against) the already-
  confirmed dense/sparse frame-channel array shapes.

**Conclusion**: the large files are real, uncompressed, float-heavy
*scene/animation* data -- almost certainly more nodes, transforms, and
channel data of the same kind already confirmed in `STATION.CUT` -- not
embedded video/audio. This corrects the earlier guess with real evidence.

## Update: the periodic pattern was a real, already-confirmed shape --
## just capped too low

Follow-up directly on the periodic pattern flagged above confirms it
byte-for-byte: the region starting at `0x3190` in `SUNNY.CUT` is a real
`SparseMilestoneTable` (the same confirmed 16-byte-entry, reciprocal-
delta-weight shape from `STATION.CUT` Zone 1) -- **34 real entries**,
verified by hand (`frame=1.0→117.0→120.0→126.0→139.0→171.0→176.0→186.0
→...→442.0→448.0`, every single transition matching `weight ==
1/(nextFrame-frame)` exactly, e.g. `120-117=3, weight=1/3=0.333` ✓,
`126-120=6, weight=1/6=0.1666` ✓, `448-442=6, weight=1/6=0.1666` ✓). The
earlier-flagged ascending `UInt16` sequence was a **misreading of this
same region at the wrong byte alignment**, not a separate structure.

The real blocker was `WOCCutsceneParser.trySparseMilestoneTable`'s own
hardcoded entry cap of 16 -- added to prevent an O(n^2) performance
blowup, but set from the largest table seen in `STATION.CUT` (5 entries)
without evidence it would generalize to larger files. It didn't: a real
34-entry table exists in even the *smallest* large `.CUT` file. Fixed by
validating the reciprocal-delta formula **incrementally** (between each
newly-read entry and the one before it, rather than collecting a batch
first) -- this keeps the O(n^2) risk closed (a non-matching candidate
still bails after 2 entries, same as before) while safely raising the
cap to 4096. Verified no regression on the 3 fully-mapped files (all 18
`WOCCutsceneParserTests` still pass, byte-exact) and a real improvement
on `SUNNY.CUT`: recognized bytes roughly tripled (1.2% → 3.4%), 17 real
sparse milestone tables now found (up to 28 entries each) where
previously only a handful of small ones were.

**Revised takeaway**: large `.CUT` files are not a different format --
they're the same confirmed shape vocabulary (transforms, Record C/D,
sparse/dense frame-channel arrays, chain headers) at a larger scale than
any of the 3 hand-mapped files exercised, with at least one of this
decoder's own detectors (the sparse milestone table) having been
under-provisioned for that scale. A future session should re-check
whether the dense frame-channel array detector (currently capped at 256
entries, chosen from `STATION.CUT`'s confirmed 110-entry maximum) has
the same problem, and continue widening detector coverage on large files
rather than assuming new record types are needed.

## Suggested next steps for a future session

- The track-header arithmetic blocker is resolved (3 files, 6 instances,
  zero exceptions, see above). Implement the hybrid positional-prologue +
  pointer-graph-walker sketched above, producing a real node tree/graph
  rather than a flat record list; use the `4+count` / `count+1` split by
  parse order as described in point 5 above.
- `STATION.CUT`'s six per-node "zones" are now fully field-mapped (see
  "STATION.CUT zone interiors: field-level decode" above), this specific
  gap is closed. What's left is *purpose*, not *placement*: the
  non-pointer fields inside Zone 1's "Record-C-like" blocks, the two free
  `f32` tail params per zone, and which animated property each sparse
  milestone table drives are all still open semantic questions on
  byte-accounted-for fields.
- A 4th file (a different size class again, and ideally one *without* a
  string pool, to further test which patterns are universal vs.
  content-dependent) would still strengthen confidence before calling any
  of this "confirmed" by this codebase's own bar. Specifically worth
  checking: does the dense frame-channel array's entry count always equal
  `floor(duration)`, or was `110` a coincidence of this one file picking a
  whole-number-ish duration? Does the `0x1BC72204` closer constant recur in
  other files, or is it `STATION.CUT`-specific?
- The "channel-quad" triple (prefixes 1.0 / 80.0 / 200.0, with 0.012658
  and 0.008333 recurring as small near-constant seconds fields) and the
  `(0,1)(1,2)(2,2)(2,0)` int-list quad found throughout `CORRIDOR.CUT`'s
  periodic track-node region are new, reproducible patterns with no
  semantic reading yet. Given `STATION.CUT`'s root-level channel-quad #2
  (0x130, prefix `89.0`) turned out to fit the sparse-milestone-table
  reciprocal-delta formula exactly when read alongside its neighbors, it's
  worth specifically re-checking whether `CORRIDOR.CUT`'s channel-quad
  triple and int-list quad are actually the *same* two primitives
  documented here (dense frame-channel array / sparse milestone table)
  rather than distinct shapes, this was not re-checked in this session and
  is a real open question, not a claim.
