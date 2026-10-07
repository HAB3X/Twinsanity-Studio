# `.sm2` `SceneryData` Format, Investigation Notes

Status: **mostly decoded**. Every field that actually affects rendering or
editing (placement transform, placement bounding box, group-level culling
capsule, tree topology) is confirmed against real disc data and implemented
in `Sources/CTModels/SceneryAssets.swift` / `Sources/CTParsers/Scenery/
SceneryDataParser.swift` / `SceneryDataWriter.swift`. A handful of
per-file header/lighting fields remain open (see "Open" below), none of
them are touched by a normal placement edit, so they're independent of the
scenery-placement work described here.

This file exists so a future agent doesn't have to re-derive any of this
from scratch or re-run the same investigations. See also `[[project_scenery_unkpos_decoded]]`,
`[[project_scenery_placement_bbox_bug]]`, and `[[project_reference_tool_x_mirror_convention]]`
in this project's auto-memory for the session-by-session narrative this
doc consolidates.

## What `SceneryData` is

A per-level record (`Twinsanity/Items/SceneryData.cs` in the reference
tool) holding a level's static scenery placement tree plus its
ambient/directional/point/negative lights. Lives inside `.sm2` files,
134 real ones on the pristine disc. The placement tree is a `SceneryGroup`
,  a recursive structure of `.group` (internal, only child links) and
`.modelGroup` (leaf, holds actual `SceneryModelPlacement`s) links, rooted
at one outermost group that is never itself culled.

## Confirmed: `SceneryModelGroup.header`, pure structural discriminant

`Header == 0x1613` (`SceneryData.cs` lines ~98/402) means "this group has
a `Models` list" (i.e. it's a leaf `.modelGroup`), nothing more. It's not
a rendering/visibility flag and isn't touched by a placement edit. Root
is always written as `0x1613`.

## Confirmed: `SceneryModelPlacement`

- `modelID: UInt32`, `isSpecial: Bool`, straightforward.
- `modelMatrix: [SIMD4<Float>]` (4 rows), full affine transform. **X-mirror
  convention applies**: the reference tool's `LoadSceneryModel` builds the
  matrix from the 4 on-disk rows then post-multiplies
  `Matrix4.CreateScale(-1,1,1)`. Worked through algebraically, the net
  effect is a **plain transpose** of the on-disk 3×3 rotation/scale block
  (no per-component sign flip) plus **negating only the translation's X**.
  `SceneryModelPlacement.composingModelMatrix(position:rotation:scale:)`
  implements this (`SceneryAssets.swift:145`). See
  `[[project_reference_tool_x_mirror_convention]]` for the full,
  code-verified derivation and its four-round correction history, don't
  re-derive this from scratch, and don't trust hand-tracing the reference
  source's arithmetic alone as proof; the only real test is an
  orientation-sensitive one against asymmetric real geometry
  (`AdjacentTileRotationAlignmentTests.swift`).
- `boundingBoxMin`/`boundingBoxMax: SIMD4<Float>`, **local space, exactly
  symmetric per axis** (`min == -max`), confirmed across all 25,836 real
  placements on the pristine disc (100%, zero exceptions). This is a
  conservative "largest absolute corner coordinate, mirrored to both
  sides" extent, not a true (possibly asymmetric) local AABB, and it is
  **completely unrelated in magnitude to the placement's world position**
 , a real, easy-to-get-wrong distinction. `ModelViewerRenderer
  .symmetricLocalExtent(of:)` computes this correctly for a freshly placed
  object; `worldAABBCorners(of:)` (a *different*, correctly still
  world-space function used only by collision generation) must never be
  reused for this field. See "Real bug #2" below.
- `matrixFileOffset: Int?`, byte offset of the placement's own 4-row
  block, used for in-place patch-on-move and delete-by-identity. `nil`
  for a placement with no real on-disk position yet (freshly inserted).

## Corrected by the decomp (2026-10-07): `unkPos` is the scenery cell's box, not a capsule

The game's own code (twinsanity-reversed: `SceneryCell::Read`, `BoundingVolume::Read`, `Volume::Read`, and the cull test
`ChunkView::TestCell` → `CullTestBox(&cell->min)`) reads a group's 5 vectors as:

- `unkPos[0]`: bounding sphere (the box's centre, `.w` the radius = |half-size|)
- `unkPos[1]`: the box's **min** corner; `unkPos[2]`: its **max** corner (the cull test reads their xyz: VU0 tests the box's 8
  corners against the view; a cell out of view skips its contents and every child cell)
- `unkPos[3]`: the half-size (max − centre)
- `unkPos[4]`: not part of the volume: the cell's own 16 bytes that follow it (`lights`), zero in real data

The "capsule" identities below hold because a box's min and max are also a diagonal through its centre. Growing only `.w`
(the old `expandingUnkPos`) never moved the box, so a placement outside it was culled with its cell by view angle (the
pop-in). `expandingUnkPos` now grows min/max per axis to hold every placement's world box (its local box through its matrix),
for the edited group and every ancestor including the root; untouched groups stay byte for byte. The root's header fields:
`headerUnk1` = the chunk's flags (bit 16 a sky follows, bit 17 lights follow), `headerUnk2` = the colour filter palette,
`headerUnk3` = the root's type (0x160A), `headerUnk4` = an unused byte, `unkVar5` = the root's tree depth (`FindCell`'s depth),
`headerBuffer` = the lights' 1024-byte reference table (present with the lights flag).

## Confirmed: `SceneryModelGroup.unkPos`, group-level bounding capsule

5 `Vector4`s per non-root group, previously round-tripped verbatim by
both this project and the reference tool. Decoded as a **bounding
capsule** (line segment + shared radius) the PS2 engine reads for
group-level coarse visibility/frustum culling:

- `unkPos[0]` = capsule axis midpoint, `.w` = half the axis length
- `unkPos[1]`/`unkPos[2]` = the two axis endpoints, `.w` = shared radius
  (identical in both)
- `unkPos[3]` = half-axis vector, exactly `unkPos[2]-unkPos[0] ==
  unkPos[0]-unkPos[1]`, this identity is what makes the decode
  falsifiable, and it held at **100% across 9,646 real groups** (134
  files)
- `unkPos[4]` = always the zero vector in every real sample

The capsule fully covers every real placement's position *and* mesh
extent (via its own symmetric `boundingBoxMin`/`Max`) in 100% of 7,540
real internal `.group` nodes below the tree's own root, using each leaf's
own placements or, for an internal `.group` node, the *entire*
recursive subtree's placements. **The outermost root is the one
exception**: its `unkPos` follows some other, still-undecoded convention
and must never be recomputed (see "Open: root's `unkPos`" below).

### Real regression #1: recompute must be scoped to the edit, not the whole tree

The first working fix (`SceneryModelGroup.computingUnkPos(covering:)` +
`SceneryGroup.recomputingUnkPosRecursively()`) recomputed **every**
group's capsule on every save, using this project's own from-scratch
2-pass farthest-point reconstruction. Confirmed in a real PCSX2 boot:
this broke visibility for objects nowhere near the actual edit, because
the reconstruction is conservative-but-not-bit-exact vs. the real dev
tool. Fix: `SceneryGroup.recomputingUnkPos(sinceEditFrom:)` diffs the
current tree against a real pre-edit baseline and only touches a group
whose own placements or some descendant's actually differ (by
`matrixFileOffset`/`modelMatrix`/bbox, catches moves too, not just
insert/delete). Every untouched group keeps its exact original bytes.
See `[[feedback_scope_recompute_to_touched_data]]`.

### Real regression #2: even a scoped recompute must preserve the original axis

Scoping alone wasn't enough. Even the *one* group an edit genuinely
touched broke previously-fine objects in that same group when the fix
replaced its capsule wholesale with `computingUnkPos(covering:)`. That
reconstruction numerically covers every real point but has no reason to
pick the same axis/orientation the original dev-tool algorithm did for an
identical point set, and the PS2 engine's culling test almost certainly
checks the capsule's actual geometry against the camera frustum (a real
intersection test), not merely whether it contains the right points.
Confirmed live: "the entire world is popping in and out of visibility...
certain objects turn invisible" as the camera turns, even on a freshly
restored disc (ruling out stale-data as the explanation this time). Real
fix: `SceneryModelGroup.expandingUnkPos(_:toCover:)`, **never touches the
axis** (`unkPos[0]/[1]/[2]/[3]`'s center/endpoints/half-axis vector are
preserved byte-for-byte); only the shared radius is ever grown, and only
just enough to cover whatever the existing axis/radius doesn't already
reach. Returns the input completely untouched when it already covers
everything. This is what `recomputingUnkPos(sinceEditFrom:)` calls for
every changed group now, `computingUnkPos`/`recomputingUnkPosRecursively()`
survive only as a no-baseline fallback and for formula tests, never as
the primary path. See `[[feedback_coverage_isnt_enough_for_geometric_fields]]`
,  **the general lesson**: numerically covering the same points is not
sufficient for a bounding-volume field feeding a real geometric test;
shape/orientation matters too, and only the original dev-authored data
can be trusted to have the right one. Prefer minimal axis-preserving
expansion over from-scratch reconstruction whenever an original value
exists to expand from.

### Ancestor propagation

`recomputingUnkPos(sinceEditFrom:)` walks *every* ancestor level of a
changed leaf, not just the leaf itself, an internal `.group` node whose
descendant changed gets its own capsule expanded (via the same
axis-preserving `expandingUnkPos`, over its full recursive subtree) too.
Verified directly in code (`SceneryAssets.swift` around line 700) and by
a real-disc audit (below), this is not a currently-open risk.

## Real bug #2 (separate from `unkPos`): placement's own bbox was world-space

`SceneryModelPlacement.boundingBoxMin`/`Max` (the placement's *own* box,
not the group capsule) was being written in world-space
(`position ± meshExtent`) instead of local+symmetric for every
newly-placed/duplicated/cross-level-placed object , 
`LevelViewerRenderer.pendingNewScenery` reused `worldAABBCorners(of:)`
(correct for its *other* real caller, `ColData` collision removal, which
genuinely wants world-space) instead of a local, untranslated extent.
Fixed via `localAABBCorners(of:)` (rotated/scaled, not translated) +
`symmetricLocalExtent(of:)` (max absolute corner per axis, mirrored) in
`ModelViewerRenderer.swift`. Three placement-construction call sites in
`WorkspaceViewModel.swift` had the identical mistake via a hardcoded
`position ± 1` placeholder and were fixed the same way. Commit `08ce059`
on `perf-audit-implementation`, landed **2026-08-29 13:56 (Sydney)**.

## Flicker investigation, final diagnosis (2026-08-29)

The user-reported "placed scenery pops in/out of visibility depending on
camera angle" bug was chased through both real regressions above, then
persisted ("flickering so much now") even after both landed. A full
audit of real data, the user's actual live test disc (134 `.sm2` files,
7,540 groups, 87,816 placements: **zero capsule coverage failures**), a
simulated production place→save→place→save→move→save sequence (**zero
failures**), and the user's directly-edited `beach_edited.sm2` (**zero
failures**), found the capsule/bbox systems are provably clean
everywhere checkable. The user then confirmed the flicker was happening
**only on objects they placed themselves, never on untouched vanilla
scenery**, which rules out anything systemic and points at
placement-specific data.

Isolating the one real user-placed object in `beach_edited.sm2` (modelID
`6670778`) found its bbox baked in as `bboxMin=(10.12,102.30,-451.08)` /
`bboxMax=(12.12,104.30,-449.08)`, literally `position ± 1` in
world-space, the exact shape of "Real bug #2" above. `beach_edited.sm2`
was last saved **2026-08-22**, a full week before the bbox fix
(`08ce059`, 2026-08-29 13:56) landed. **Conclusion: the flicker on that
object is stale pre-fix data, not a live bug**, fixing the code doesn't
retroactively repair bytes already written before the fix existed. The
open action item is for the user to re-place the object fresh with a
current build and re-test; if it still flickers after a genuinely fresh
placement, the regression list above needs revisiting or there's a third,
still-undiscovered mechanism.

**Verification boundary, still true:** headless PCSX2 boots
(`-batch -nogui`) prove data/boot stability (real play time, no
CPU-trap/corruption log signature) but render no video, nothing in this
project can automatically confirm a flicker fix *visually*. That still
needs a real windowed PCSX2 session. See
`[[project_flicker_visual_confirmation_pending]]`.

## Open: `SceneryAsset` per-file header/lighting fields

None of these are written or read by a normal scenery placement edit , 
they're per-file data untouched by insert/delete/move. Listed here so a
future decode pass doesn't have to rediscover the current state.

- **`headerUnk1`**: confirmed. Only 4 raw values occur across all 134
  real files (`0`, `0x10000`, `0x20000`, `0x30000`), exactly the two
  known gate bits (skydome, headerBuffer/lights), no other bit is ever
  set in real shipped data.
- **`headerUnk3`**: confirmed. Always exactly `0x160A` across all 134
  real files (gates whether `root`/`unkVar5` are present at all).
- **`headerUnk4`**: almost fully resolved. `0` in 133/134 files; one real
  outlier (`=1`, a 189-placement/10-light level) with no distinguishing
  pattern found from a single sample.
- **`headerUnk2`**: open. Real, mostly-region-correlated categorical
  field, `AltEarth` levels are 100% value `0` (26/26 across all 4
  sub-areas), `Earth/Cavern` is 11/12 value `1`, `Ice/SlipSlide` is 7/7
  value `2`, but `Ice/Hub` splits across 3 values and `Ice/HighSeas`
  across 2, so it's not a clean one-value-per-world/sub-area mapping.
  Plausibly a skybox/tileset/music-zone ID. No exact formula found.
- **`unkVar5`**: open, size-tier hypothesis only. Tree-depth was
  disproven by a real counterexample (`cavrnend.sm2`: flat tree, depth 1,
  yet `unkVar5=4`). Best replacement: a 3-threshold bucketing of the
  root's own confirmed capsule radius (`unkPos[0].w`) gives 125/134 (93%)
  exact matches; ~9 stubborn outliers remain with no further pattern
  found (log-scale thresholds, monotonic transforms, no improvement).
  Reads as a coarse level size/complexity tier (plausibly LOD/streaming
  related), not nailed to an exact formula.
- **Root's own `unkPos`**: open, partially decoded. `unkPos[0] =
  (0,0,0,radius)` where `radius` is a sphere-from-origin covering the
  whole tree, confirmed, 48/49 real files. `unkPos[1]/[2]/[3]` (a
  symmetric-half-extent AABB shape) do **not** match scenery placements
  alone, collision mesh alone, or their union, tested decisively across
  all 134 real level pairs, 0/134 within 5% relative error for any of the
  three (combined mean error ~79%). Whatever drives this remains
  genuinely unknown; there's no evidence root's bound is even used for
  per-object culling. **Do not implement a root recompute**, no
  confirmed formula for 3 of its 5 vectors.
- **`headerBuffer`**: open (leading portion only). Fixed 1024-byte opaque
  block, gated by `headerUnk1 & 0x20000`. ~71% of real files show a
  byte-identical 16-byte template anchored on `0xCCCCCCCC` (the canonical
  MSVC/x86 uninitialized-memory fill pattern) plus a `0x7F7F7F77`-repeat
  filler run before it in the buffer's trailing portion, strong evidence
  this is a reused, only-partially-overwritten scratch buffer in the
  original export tool. The **leading, non-filler portion is still
  undeciphered**, float32, uint32, and count-correlation (light/
  placement counts, skydomeID) interpretations were all tested and ruled
  out.
- **`SceneryLight.colorUnk`** (all kinds): confirmed always exactly `0.0`
  across all 686 real lights, unused/reserved.
- **Point light `unkShort`**: open. Confirmed real (not filler) , 
  3-valued (`{0,1,2}`), stable per same-preset light group within a file.
  No correlate found. `flagsRaw` ruled out as an explanation (constant
  `0x102` on every real point light).
- **Directional light `unkShort`**: ruled out as meaningful, full
  `UInt16` range used, no proportionality to radius, one file shows a
  near-arithmetic run consistent with uninitialized memory rather than
  authored data.
- **Point/ambient light `vector1`/`vector2`**: partially confirmed.
  Exactly `vector1 = position - c`, `vector2 = position + c` for a
  per-light constant `c`, confirmed via exact subtraction, same
  "symmetric pair around a center" shape as the scenery capsule.
  `vector2 - vector1` is a round, uniform-per-axis magnitude (200–20000)
  that loosely tracks the light's own `radius` but isn't a clean multiple
  (ratio 66–216, non-monotonic), likely a coarse quantized
  culling/influence bound, exact quantization rule not found.
- **Negative light `unkFloat1`/`unkFloat2` + `unkUInt1`/`unkUInt2`**:
  **confirmed** as spotlight inner/outer cone half-angles, encoded twice
  redundantly (floats as `cos(angle)`, ints as 17-bit/16-bit binary angle
  fractions), cross-validated against each other to sub-unit precision
  across all 3 distinct real angle configs on the disc (n=11 raw
  instances, small but the dual-encoding agreement is strong evidence).
- **Negative light `unkUShort1`/`unkUShort2`**: always `0` across all 11
  samples, likely unused, sample too small to fully confirm.

## Methodology worth reusing

For any other undecoded field in this project: mount the pristine
reference ISO read-only (`hdiutil attach -readonly`), write a throwaway
XCTest (this codebase's convention: `ZZScratch*.swift` in the relevant
`Tests/` target, deleted once data is extracted) to dump the field plus
its real context across every real level file, then analyze numerically
(Python, or inline Swift) for an *exact* algebraic identity before
trusting any interpretation, e.g. the `unkPos[3] == unkPos[2]-unkPos[0]
== unkPos[0]-unkPos[1]` identity holding at 100% across 9,646 real groups
is what made the capsule a confirmed decode rather than a guess. A
headless real PCSX2 boot (`-batch -nogui -logfile ... -earlyconsolelog`)
can confirm data/boot stability via log signals (disc detect, module
registration, real play time, absence of "EE: Unrecognized"/trap
exceptions) but **cannot** confirm anything visual, there is no
automated visual-verification tooling in this project. Never trust a
"coverage" check (does the reconstructed volume contain the right
points?) as sufficient for a field feeding a real geometric test , 
orientation/shape matters too; see `[[feedback_coverage_isnt_enough_for_geometric_fields]]`.
