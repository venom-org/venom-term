# `exportPlain` cost of DEL and ZWJ rows

After the [non-ASCII fix](plain-export-non-ascii.md), most rows cost about 2 µs, but two
kinds stayed slow. A row holding a DEL went through the cell-by-cell `appendRow`
at about 52 µs, and pane output controls that. A row of ZWJ emoji under mode 2027
always missed the column guess and bisected, at about 16 µs.

## Changes

**Control characters.** A cell holding a DEL is text like any other, so
`contentEnd` works on it. The line is copied with each control character rewritten
to the space it renders as (`appendControlsAsSpaces`). A C1 character takes 2 bytes
and becomes 1. Only a line that does not decode still needs `appendRow`.

**A second guess.** `clusterColumns` sums `ghostty_unicode_grapheme_width`, which
models mode 2027 on. The reader tries the guess that last won first, so a pane full
of such rows doesn't pay for a miss on every row.

**Checking runs of rows at once.** The first two changes weren't enough for `zwj`:
it stayed at 3.7 µs a row with a right first guess. `perf` put about 64% of the time
in `PageList.pin`, `Selection.order` and `pointFromPin`. A formatter call with a
selection walks the page list from the top about six times: once per grid ref, and
four times because `topLeft` and `bottomRight` each call `order`. So `load` now
scans the whole chunk, and `runBlankFrom` checks each run of neighbouring rows with
the same guess using one rectangle selection.

## Why a rectangle only counts when it is empty

The first version of this read the rectangle's output line by line, taking an empty
line to mean that row was blank. That corrupted exports, and neither the differential
tests nor the bench hashes noticed. A review of the formatter found it. Past column
0, the formatter's lines do not line up with rows:

- It drops the blank-row state it carries between pages, so no newline is written
  there.
- A row whose rectangle starts on a spacer head is skipped without a newline.

Later rows shifted up, so a row with text past the guess could read another row's
empty line and be cut short. Both cases now have a regression test, and both tests
failed against that version.

So the only answer used is that the whole rectangle wrote nothing, which needs no
alignment. Any text sends the whole run to the per-row probe, which formats that row
alone. A failed probe also just leaves its rows to the per-row probe, because `load`
reaches rows the byte budget may never keep.

## Checks

The guesses and the rectangle are meant to set only the cost, and the differential
tests compare against the cell-by-cell `exportRows`. Breaking the code on purpose:

| Change | Tests |
|---|---|
| Rectangle always reports blank | 5 fail |
| Controls not rewritten | 10 fail |
| Rectangle read line by line (the first version) | 2 fail |
| First guess forced to column 1 | all pass |
| First guess forced to the last column | all pass |
| Clusters always tried first | all pass |
| Run probing off | all pass |

The last four pass because they change only the cost. This shows what these tests
catch, not that the code is correct: the first version passed the tests of its day.

## Results

ReleaseFast on a shared machine with load average about 3.5. Base and new ran
alternately for three rounds, with 3 trials per round for base and 7 for new. The
figures are the range of the round medians, in CPU ms. All hashes of the exported
rows match between the two builds on all nine loads.

`zig build -Doptimize=ReleaseFast -Dheadless=true`, then `plain-bench <load>`.

| Load | Rows kept | Base CPU, ms | New CPU, ms | New, µs a row |
|---|---|---|---|---|
| `ascii`: 167 `x` per row | 83,886 | 26 | 25 to 26 | 0.3 |
| `short`: 40 `x` per row | 83,886 | 17 | 16 to 17 | 0.2 |
| `mixed`: one wide character per row | 83,468 | 191 to 192 | 79 to 82 | 1.0 |
| `del`: one DEL per row | 83,886 | 4343 to 4433 | 80 | 1.0 |
| `cjk`: 60 wide characters per row | 64,527 | 172 to 181 | 56 to 60 | 0.9 |
| `box`: full row of box drawing | 27,962 | 46 | 50 | 1.8 |
| `zwj`: ZWJ emoji under mode 2027 | 44,151 | 703 to 718 | 77 to 79 | 1.8 |
| `delvar`: `del`, length varies by row | 83,886 | 4112 to 4180 | 200 to 201 | 2.4 |
| `zwjvar`: `zwj`, length varies by row | 47,527 | 713 to 715 | 169 to 171 | 3.6 |

`del` and `zwj` meet the target of under 3 µs a row.

## Limits

**Uniform rows are the best case.** `del`, `mixed`, `cjk` and `zwj` give every row
the same guess, so one rectangle covers them. `delvar` and `zwjvar` vary each row's
length so that no two neighbours share a guess, and so show the cost without runs.
`delvar` is still under 3 µs. `zwjvar` is not, at 3.6 µs, about 4x faster than base.
The remaining cost there is the page-list walks, which libghostty-vt's API gives no
way to skip: a grid ref must not be edited to move along a row.

**One row with text past the guess gives up the whole run.** That row can be an
ordinary VS16 emoji in the chunk before the guess flips, or a row that switched mode
2027 midway. The run then costs what it did without run probing, plus one rectangle.
That rectangle runs twice if its text overflows the 512-byte buffer, because the
formatter counts what did not fit; the API can't stop it. It is bounded per run.

**`box` got a little slower**, about 0.1 µs a row, because `load` now plans every
line of a chunk first. Chunks also get planned past where the byte budget stops the
export, by at most one chunk.

**A pane that switches mode 2027 pays once per switch**, with a miss on the rows
that follow until the guess flips. `load` picks the first guess for a whole chunk,
so a flip takes effect on the next chunk. Rows in the current chunk still reach the
right answer through the second guess.
