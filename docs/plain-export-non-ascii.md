# `exportPlain` cost of non-ASCII rows

After the [first `exportPlain` fix](plain-export-cost.md), a row of printable ASCII came from the
plain formatter, and any other row was read cell by cell at about 55 µs for 200
columns. A pane whose scrollback is mostly non-ASCII still stalled the reactor
for about 4 s on a checkpoint.

## Fix

A row is the formatter's text plus one space per cell after the last text. Only
that count was missing, because the formatter drops those cells and a line's
width can't be read from its text alone: mode 2027 and the pane's history decide
how a cluster was laid out.

`PlainReader.contentEnd` finds the column where the text stops:

1. Guess it, by summing `ghostty_unicode_codepoint_width` over the line.
2. Check the guess. One formatter call on the row from that column on must write
   nothing, and the cell before it must hold text or the tail of a wide cell.
3. If the guess was wrong, bisect with the same formatter call.

The guess only sets the cost, never the answer: the tests still pass with it
forced to column 1 or to the last column. The search is sound because "the row
holds text from column x on" is monotonic in x. A selection that starts on a
wide cell's tail includes the wide cell, and blank cells at the end of a row
format to nothing.

Grid refs are not reused or edited, so `grid_ref.h`'s read-only rule holds.

A line holding a control character (rendered as a space) or anything that does
not decode (rendered as U+FFFD) still goes through `appendRow`. Those rows keep
the old cost of about 55 µs, including a row holding a DEL.

## Results

ReleaseFast on a shared machine with load average 3 to 4. Base and new ran
alternately for three rounds, with 3 trials per round for base and 7 for new. The
figures are the range of the round medians, in CPU ms. All hashes of the exported
rows match between the two builds.

`zig build -Doptimize=ReleaseFast -Dheadless=true`, then `plain-bench <load>`.

| Load | Rows kept | Base CPU, ms | New CPU, ms | New, µs a row |
|---|---|---|---|---|
| `ascii`: 167 `x` per row | 83,886 | 27 to 28 | 24 to 25 | 0.3 |
| `short`: 40 `x` per row | 83,886 | 18 | 16 to 17 | 0.2 |
| `mixed`: one wide character per row | 83,468 | 4131 to 4150 | 186 to 188 | 2.2 |
| `cjk`: 60 wide characters per row | 64,527 | 4006 to 4039 | 170 to 171 | 2.6 |
| `box`: full row of box drawing | 27,962 | 2226 to 2235 | 45 | 1.6 |
| `zwj`: ZWJ emoji under mode 2027 | 44,151 | 2910 to 2945 | 703 to 708 | 16 |

`mixed` meets the target of under 250 ms. In `zwj` every guess is wrong,
so every row bisects. That is the cost of a pane full of such rows: still about
4x the old speed, but a stall of about 0.7 s for this load.
