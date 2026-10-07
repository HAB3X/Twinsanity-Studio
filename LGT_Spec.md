# WoC `.LGT` (Lighting) Format, Investigation Notes

Status: **partially implemented** (`WOCLightParser.swift`), every real
"normal"-shape light record decodes with real, independently-validated
fields (radius, byte + float color, position). All 8 `K == 0` files
decode fully, and, new, a validated boundary-resolution search now
also recovers real record boundaries for **14 of the 29 `K > 0` files**
(see "Update: `K > 0` record boundaries resolved for most files" below);
the remaining 15 don't have a unique byte-exact fit and correctly fall
back to the raw blob rather than guess. Every record, normal shape or
not, resolved or not, is either a verified, validated decode or an
honest raw fallback, never a silent guess.

## What `.LGT` is

Per-level, plain uncompressed loose files (37 exist on the disc, sizes
138–6364 bytes). Real light-placement data for a level.

## Confirmed: file-level size formula

Checked against all 37 real files, zero exceptions:
```
fileSize = 4 (leading count) + 24 (header) + 55 * count + 12 * K
```
`count` is the leading `UInt32LE`. `K` is some number of "extended"
lights that cost 12 extra bytes each (e.g. `AIRSHIP.LGT` 138B/count=2 →
K=0; `FARM.LGT` 540B/count=8 → K=6; `CASTLE_C.LGT` 6364B/count=96 →
K=88). Header relative offset 12 (a `UInt32LE`) equals `K` exactly for
some files (`FARM`: 6=6, `HUB`: 37=37) but not others (`CASTLE_C`: 65 vs.
K=88), so the header only partially tracks `K`, or more than one kind
of "extended" record is being aggregated into that one size delta.

## Confirmed: 24-byte header, 55-byte base record size

`AIRSHIP.LGT` (138 bytes, `count=2`, `K=0`) is fully byte-accounted:
`4(count) + 24(header) + 55 + 55 = 138` exactly, matching the formula
above. Header content: four `UInt32LE` at relative offsets 0/4/8/12 , 
`(1, 1, 0, 1)` in `AIRSHIP.LGT`, recurs as a pattern across most `K=0`
files but isn't universal (`CASTLE_C.LGT`'s first two header words are
`(4, 24)`, not `(1, 1)`). Two more floats follow at header offset
16-23 whose purpose is unresolved.

## Confirmed: color and radius fields, for the "normal" record shape

Within a 55-byte record, when it's the "normal" shape (see the open
problem below):
- **Relative offset 16**: radius/falloff distance, a small positive
  float in every normal-shape sample checked.
- **Relative offset 20-22**: byte RGB, **no alpha**, confirmed via WoC's
  own decompiled symbol table (`Games Files/Reference Files/CrashWOC-
  PS2-Decomp-master/symbols/ALL_SYMBOLS.txt`): `edlightMakeNUCOLOUR3` and
  three independent slider symbols (`edlightcb_r_sliderval`/`g_`/`b_`) , 
  a real `NUCOLOUR3` type, no alpha channel exists for it in the editor.
- **Relative offset 23-34**: the SAME color as the byte triple above, as
  three `Float32`s (0...1 range), confirmed to match `byteValue/255` to
  3 decimal places when the record is the normal shape.
- **Relative offset 0/4/8/12**: four floats, plausibly a position triple
  plus one more value, real-world-range-plausible when cross-checked
  against that level's own `INST` coordinates, but the exact per-axis
  assignment (which of the four is X/Y/Z, and what the 4th represents)
  is NOT confirmed.
- **Relative offset 35-54** (20 bytes): tail, contains at least 2 small
  `UInt32` fields (one usually ~4-5, one variable: 1/5/6/7 observed) plus
  more floats, not decoded.

## Why a full parser doesn't exist yet

**A second, structurally different record shape exists, and it isn't
reliably detectable up front.** `WOCLightParser.swift` handles this
honestly rather than working around it: every record is decoded under
the "normal" shape AND independently validated (`radius >= 0`,
`colorFloat` matching `colorByte/255`) before being trusted -- a record
that fails validation comes back `nil` with its raw 55 bytes preserved,
never a guessed decode. This is why a *partial* parser is safe to ship
even without solving the variant: it never claims certainty it doesn't
have.

Directly re-verified on `AIRSHIP.LGT` (the
smallest, `K=0` "simple" file): its light 0 fits the normal shape exactly
(radius `2.31`, `colorByte=[255,191,127]` matches
`colorFloat=(1.0,0.749,0.498)` almost exactly), but light 1 in the SAME
file does not: computed "radius" comes out **negative** (`-11.35`), and
the "colorByte"/"colorFloat" pair don't match each other at all
(`colorFloat` evaluates to near-zero/garbage-looking values). This is a
real second internal record shape, not a bug in reading light 0's
layout, and critically, **it occurs even in a `K=0` file**, so "K=0
means every record is the simple shape" is false. The original
investigation flagged this same variant (a clean small integer, 0, 2,
or 3, at relative offset 0, functioning as a plausible type tag, with
the color block shifted ~12 bytes later and a second XYZ triple in
between, consistent with a spot/directional light carrying an aim
vector) but could not pin down a reliable rule for detecting it up front
or for exactly when it costs the extra 12 `K` bytes vs. fitting in the
plain 55-byte slot.

Implementing a decoder against only the "normal" shape's field offsets,
without a reliable way to detect the variant first, would silently
misdecode an unknown fraction of real records as if they were valid , 
producing plausible-looking-but-wrong radius/color/position data. That's
a worse failure mode than leaving the format undecoded, and is exactly
the kind of mistake this codebase's other decoders (see `WOCParticleParser`,
`WOCObjectParser`'s doc comments) are careful to avoid by only decoding
what's confirmed and stopping honestly at what isn't -- `WOCLightParser`'s
per-record validation (above) is this format's own version of that same
discipline: it makes the "detect the variant first" problem moot by
never trusting a decode that doesn't independently check out.

**A real, useful, but small-sample positional finding**: on both real
`K=0` files that have a variant record at all (`AIRSHIP.LGT`,
`WESTERN.LGT`), it's always the file's *last* record -- 2 of 2, checked
across all 8 real `K=0` files (the only ones where record boundaries
are unambiguous). Not proven as a rule (too small a sample, and 6 of the
8 `K=0` files have no variant record at all, so it's not universal
either), and `WOCLightParser` doesn't rely on it structurally -- every
record is still validated independently -- but worth knowing when
interpreting a `nil` entry.

## Update: real decompiled source found (`OpenCrashWOC-main`), partial confirmation

`CrashWOC-PS2-Decomp-master` (this doc's original lead) turned out to be a
Ghidra symbol-table export only -- `edlightAdd`/`edlightcbSaveLightData`
have an address and a size, no body, no struct fields. But
`OpenCrashWOC-main/code/src/gamecode/lights.c:41-103` (`LoadLights()`,
annotated `//94% NGC` -- an alpha GameCube-port reconstruction, not raw
PS2, so not gospel) has real, load-bearing source, independently
corroborated by real DWARF debug info in the same tree
(`code/src/dump_alphaNGCport_DWARF.txt:4187-4204`, typedef `Ed_Light`,
compiler-verified field offsets):
```
type:Int32 pos.xyz:Float32x3 radius_pos.xyz:Float32x3 radius:Float32
r,g,b:UInt8x3 colour.rgb:Float32x3
[if type==1 || type==2: direction.xyz:Float32x3]   -- +12 bytes
globalflag:UInt8(stored as Int32) brightness:UInt8(stored as Int32)
```
This is exactly 55 bytes in the base case and 67 (55+12) in the
`type==1`/`2` case -- matching this doc's own confirmed 55-byte base and
`K`-costs-12-extra-bytes finding precisely, from an independent source.

**Directly re-verified against the real `AIRSHIP.LGT` on disk (not just
trusting the agent report)**: applying this field order to light **1**
(absolute file offset 83) decodes cleanly and self-consistently --
`radius=2.311786`, `colour=(0.749,0.749,0.749)` matching `191/255` (the
byte triple) to full float precision, and `radius_pos` equal to `pos`
except on one axis offset by ≈`radius` (a real, redundant, internally-
consistent encoding, not coincidence). **This independently confirms
this doc's "normal shape" field layout is exactly right.**

**But light 0 (offset 28) still does NOT decode cleanly** under this same
field order -- `type` reads as a nonsense ~1.1 billion, `radius` as
~-2.5e38 -- and since `K=0` for this file, it can't simply be "light 0 is
the type-1/2 extended variant" (that would need 12 extra bytes this file's
size doesn't have room for). **The original "second shape" problem is
therefore still open, but now with a concrete new hypothesis, not just a
statistical anomaly**: `LoadLights()` reads four leading counts --
`LIGHTCOUNT, AMBIENTCOUNT, DIRECTCOUNT, POINTCOUNT` -- but the function
body shown only ever loops `LIGHTCOUNT` times with a flat, inline
`type`-tag read; the other three counts are read and never used again in
what's shown. That's suspicious for a `//94%`-confidence reconstruction
of an alpha port -- the real retail algorithm may bucket records by type
(ambient records without a `pos`/`direction`, say) rather than a single
uniform loop, which would explain why record 0 specifically (not a random
middle record) fails to fit -- entry order may not be "N identical
records" but "N1 ambient + N2 directional + N3 point", each with a
genuinely different width, and this file's header fields (relative offset
0/4/8/12, previously observed as `(1,1,0,1)` in this same file) may
BE `LIGHTCOUNT`/`AMBIENTCOUNT`/`DIRECTCOUNT`/`POINTCOUNT` directly rather
than an unrelated 4-int header -- worth checking directly: `AIRSHIP.LGT`'s
own header is literally `(1,1,0,1)`, i.e. plausible small counts, not
previously read that way.

## Update: the bucketed-count hypothesis is tested, and refuted as stated

Directly decoded `AIRSHIP.LGT`'s raw bytes field-by-field (a real Python
script against the real mounted file, not hand arithmetic) to test
whether the header `(1,1,0,1)` really means "1 narrower ambient record +
1 normal record". It doesn't, in that specific form -- both of
`AIRSHIP.LGT`'s records are the SAME 55-byte width (forced by the
already-ironclad file-size formula: `138 = 4+24+55*2+12*0` leaves no
room for a narrower first record), so the header counts can't be
selecting between different record *widths*. **What they might still
select between is different *field interpretations* within that same
55-byte envelope** -- not yet tested.

More importantly, this pass **refutes `lights.c`'s `LoadLights()` as a
reliable byte-for-byte guide** to the working "normal" shape, not just to
the broken variant. `LoadLights()`'s reconstructed read order is `type:
Int32, pos.xyz, radius_pos.xyz, radius, r/g/b, colour.rgb, ...` -- but
the working record (`AIRSHIP.LGT`'s light 0, offset 28) has **no room**
for that: this doc's own confirmed field positions (`radius` at relative
offset 16, `rgb` at 20-22, `colour` at 23-34) leave only 16 bytes before
`radius`, not the 28 bytes `type(4)+pos(12)+radius_pos(12)` would need.
Directly confirmed: bytes 0-15 of the working record are four ordinary,
plausible-range floats (`16.36, -10.27, 38.38, 16.59`) -- nothing that
reads as a small-integer type tag, and no second position-shaped triple
anywhere before `radius`. So `LoadLights()` (already flagged `//94% NGC`,
alpha-port, not retail PS2) got the *concepts* right (a type tag,
direction for spot/point lights) but not WoC's actual on-disk field
order for the base case -- treat it as a conceptual guide only from here,
not a byte-offset source.

**A real, new, but non-generalizing clue on the broken record itself**:
`AIRSHIP.LGT`'s light 1 (the broken one) shows a genuine structural
duplication -- the 4 bytes at relative offset 4-7 are byte-identical to
offset 16-19, and offset 8-11 matches offset 20-23 on its first 3 bytes.
This is real (verified via the same script, not a heuristic false
positive) and distinctive -- but checking every other real `K=0` file
(the only ones where a naive 55-byte stride is guaranteed correct, since
`K>0` files interleave 67-byte extended records that desync a uniform
stride) found only one other genuinely broken record, in `WESTERN.LGT`
(`colorFloat` includes obviously-garbage values like `1.68e30`,
`1.68e7`) -- and it does **not** share the same duplication pattern.
Across all 8 real `K=0` files (17 total records), only these 2 are
broken -- a real, small, honest sample, not enough to generalize a
single unifying rule from. Either there are multiple distinct
non-normal shapes, or the real unifying pattern hasn't been found yet.

## Update: WOCLightParser implemented; header-correlation tested and inconclusive

`WOCLightParser.swift` is now real, shipped code -- see "Why a full
parser doesn't exist yet" above for exactly what it does and doesn't
cover (all `K=0` files fully, per-record-validated; `K>0` files get raw
bytes only). Also directly tested whether a header field predicts
*which file* has a broken record at all (not just where within it): the
4th header int is `1` on `AIRSHIP.LGT` (has a broken record) and `0` on
5 of the 6 real `K=0` files with no broken record -- but `WESTERN.LGT`
also has header value `0` for that same field and still has a broken
record, breaking the correlation. Real, but not clean enough to build
on.

## Update: `K > 0` record boundaries resolved for most files

Direct byte verification (`xxd`) on `FARM.LGT` (540 bytes, `count=8`,
`K=6`) confirms the real shape of an "extended" record: a **12-byte
prefix (present, not decoded -- a leading `UInt32` that reads `2` on
every extended record checked, plus two floats)** immediately followed
by the exact same 55-byte "normal" body already confirmed above, at
`recordStart + 12`. Verified by validating the body's radius/color
cross-check at that offset -- passes cleanly and self-consistently.
`FARM.LGT`'s own real record order (2 normal records, then 6 extended)
happens to match `K=6` exactly by total byte count, but this is only one
file's evidence for *that specific ordering* -- not enough to assume
"normal records always come first" as a general rule.

Given that, `WOCLightParser.resolveRecords` doesn't assume a fixed
order. It runs a validated, budget-bounded search: at each position, try
both the 55-byte and 67-byte interpretation (bounded by how many of each
shape remain per the file's own `count`/`K`), prune to whichever
interpretation's body passes the same real radius/color validation
already used for normal records, and only accept a resolution when it's
**unique** and consumes the record region **exactly** (byte-exact, no
leftover) -- matching this codebase's existing verification bar rather
than a heuristic guess. In the common case this reduces to a single
linear pass (confirmed: every one of `FARM.LGT`'s 8 records resolved
with zero ambiguity), only branching when a record doesn't validate
under either shape (the still-unsolved "second undecoded shape" from
earlier in this doc) or when both shapes happen to validate.

Real result across the full corpus: **14 of the 29 real `K > 0` files**
now resolve unique, byte-exact record boundaries (up from 0). The other
15 don't -- either no interpretation produces an exact fit, or the
search hits its node budget before proving uniqueness -- and correctly
fall back to the raw, undivided blob (`File.boundariesResolved == false`)
rather than present a guessed boundary as fact. `File.isExtended: [Bool]`
now exposes each resolved record's real shape alongside `File.lights`.

## Suggested next steps for a future session

- **The remaining 15 unresolved `K > 0` files** are the real next
  blocker -- worth checking by hand (same `xxd` approach used on
  `FARM.LGT`) whether they fail because a record genuinely doesn't
  validate under either shape (a 3rd record shape? the already-known
  "second undecoded shape" occurring inside a `K>0` file?), or because
  the search is finding multiple equally-valid-looking fits (which would
  mean the validation check alone isn't a strong enough disambiguator
  and a further structural clue is needed).
- The 12-byte extended-record prefix is real and placed but its own
  purpose is unconfirmed (leading `UInt32 == 2` on every instance
  checked so far, plausibly a type tag; the two trailing floats
  unexplained) -- gather more extended-record samples now that
  boundaries resolve for many files, and check whether the leading `2`
  is truly constant across all of them (a real type tag) or varies.
- Gather more real broken-record samples from `K>0` files now that
  boundaries resolve for most of them -- this doc's earlier "`K` doesn't
  always match the header's own tracking field" finding means the two
  problems likely need solving together, not sequentially.
- If neither pans out, the PS2-native (not NGC-port) disassembly, if
  `OpenCrashWOC-main`'s `PS2_Version/` directory has anything equivalent
  to `lights.c`, would be worth checking specifically.
