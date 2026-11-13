# ScrollView wrap cache

In widgets v0, `ScrollView.draw` re-wrapped every block on every
frame, so a long venom transcript cost O(transcript) per frame even when
nothing changed. The view now keeps the wrapped lines of each block and
re-wraps a block only when its key changes. A second change then packed those lines into
shared buffers and added a caller hint that skips the per-frame pass.

## Design

- **Cache key per block:** the wrap width (after indent and gutter), a
  fingerprint of the slices the block points at (the `spans` slice and each
  span's text pointer and length), and `Block.revision`. A new spans slice,
  or a span whose text grows while streaming, is caught by the fingerprint.
  A product that rewrites span bytes in place, keeping the same slices,
  bumps `revision`.
- **Line index:** `starts[i]` is the first visual line of block `i`, and the
  last entry is the total. `blockAt` and the draw loop find the first block
  on screen by binary search, then walk forward, so a draw touches only the
  visible lines.
- **Storage:** every block's lines and segments live in one
  `text.Wrapped` per view, and an entry holds the block's key and its range.
  A re-wrapped block goes to the end of the buffers. If its old lines were
  already at the end (a streaming tail, or a resize, which releases from the
  last block backwards) their space is reused at once. Otherwise they become
  garbage, and the buffers are rewritten once there is more garbage than live
  data, so repeated edits to early blocks can't grow them without bound.
- **Per frame:** with no hint, one pass over the blocks that compares keys and
  rebuilds the prefix sums. That pass is O(blocks), but it is a few word
  compares and an add per block and never wraps text. Collapsing or expanding
  a block changes its line count without re-wrapping it. A width change
  re-wraps every block whose wrap width changed.
- **Caller hint:** `assumeUnchanged(prefix)` promises that blocks
  `0..prefix` are unchanged since the last layout, and the next layout starts
  at `prefix`. It is what makes a tail draw O(new blocks); see below.
- `ScrollView.wraps` counts the blocks wrapped so far, and `scans` the block
  keys compared. Tests use them to check that unchanged blocks are never
  re-wrapped, and that a hinted layout doesn't look at the prefix.

## The hint can't make a caller stale by omission

The failure to design against is a stale cache after an edit in the middle of
a transcript. A sticky mode (`markDirty(from)` plus "append-only") fails that
way: a caller that forgets one `markDirty` draws old lines. So the hint is the
other way round:

- **It is a one-shot promise.** It applies to the next layout only. No call
  means a full key compare, so forgetting it costs time and nothing else.
- **What the view can see overrides it.** A width change, `toggle` and
  `handleKey` (`E`/`C`) take effect whichever came first. `setAll` has no view
  to tell, so its callers must not promise past a block it changed.
- **A zero-size draw drops it**, so it can't reach a later frame.
- **A broken promise panics in Debug and ReleaseSafe**, where the layout checks
  the whole prefix anyway. In ReleaseFast it is trusted: it can draw stale
  lines, or read out of bounds if a span list shrank.

## Benchmark

`zig build bench-scroll -Doptimize=ReleaseFast [-- blocks width height]`
(default: 10000 blocks, 100x40). It is not part of `zig build test`. The
transcript has 10000 blocks of 8 to 47 words, and every fifth block is a
collapsed tool call, for 30957 visual lines. Each row below is the average of
200 draws, except the first draw and the resize, which are one draw each.
Measured on 2026-11-07 on an AMD Ryzen 7 9800X3D, both runs on the same machine; "before" is the
same bench built against the previous implementation.

| Case | Before | After | Blocks wrapped per draw (after) |
|---|---:|---:|---:|
| First draw | 50.1 ms | 51.1 ms | 10000 |
| Redraw at the tail, nothing changed | 49.6 ms | 0.148 ms | 0 |
| Append one block, draw | 53.1 ms | 0.176 ms | 1 |
| Toggle one block near the tail, draw | 50.7 ms | 0.164 ms | 0 |
| Resize (width 100 to 120) | 50.6 ms | 51.0 ms | 10200 |

A steady tail redraw is about 335x cheaper. What is left (about 0.15 ms for
10000 blocks) is the key-compare pass plus drawing 40 rows.

**Memory:** this cache held 3574 KiB for this transcript, up from 1606 KiB,
mostly from the capacity rounding of each block's own lists. Packed buffers removed
that; see below.

## Packed buffers and the hint

Measured on 2026-11-09 on an AMD Ryzen 7 9800X3D, in ReleaseFast, with the
10000-block transcript above. The columns compare the previous implementation and this
change, built side by side and run alternately three times; each cell is the
median of the three runs. Each row is the average of 200 draws, except the
first draw and the resize, which are one draw each.

| Case | Before | After, no hint | After, `assumeUnchanged` |
|---|---:|---:|---:|
| Held memory after the first draw | 3574 KiB | 1577 KiB | 1577 KiB |
| First draw | 51.6 ms | 57.0 ms | - |
| Redraw at the tail, nothing changed | 0.154 ms | 0.158 ms | 0.075 ms |
| Append one block, draw | 0.181 ms | 0.187 ms | 0.091 ms |
| Toggle one block near the tail, draw | 0.166 ms | 0.175 ms | 0.082 ms |
| The last block streams, draw | not measured | 0.187 ms | 0.093 ms |
| Resize (width 100 to 120) | 51.2 ms | 57.7 ms | - |

Held memory is 1.8% under the pre-cache baseline of 1606 KiB, which is the
target (within about 10%). It stays at 1577 KiB after the edits and the resize
in the bench, because the resize re-wraps over the old space.

The tail redraw no longer depends on the block count once the hint is used. One
run per size (`zig build bench-scroll -Doptimize=ReleaseFast -- <blocks>`); the
"before" column is one run of the previous implementation:

| Blocks | Held, before | Held, after | Tail redraw, before | After, no hint | After, `assumeUnchanged` |
|---:|---:|---:|---:|---:|---:|
| 1000 | 357 KiB | 168 KiB | 0.078 ms | 0.080 ms | 0.078 ms |
| 10000 | 3574 KiB | 1577 KiB | 0.147 ms | 0.155 ms | 0.075 ms |
| 100000 | 35742 KiB | 15183 KiB | 0.914 ms | 0.962 ms | 0.074 ms |

What is left, about 0.075 ms, is drawing 40 rows of text plus one binary search
for the first visible block, which is O(log blocks) and doesn't show here.

**Costs:** with no hint a steady frame is within about 5% of before, near the
noise between runs. A first draw and a resize are about 10% slower (5 to 6 ms
for 10000 blocks). The wrap code itself didn't change apart from one comparison,
and the time is mostly grapheme measuring in a profile, so the cause is not
established. Both are one-off events, not per-frame costs.

Debug builds are about 10 to 100x slower (`zig build bench-scroll`: about
2.7 ms for a tail redraw and 1.3 s for the first draw), as expected for an
unoptimized build.
