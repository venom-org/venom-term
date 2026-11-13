# `exportPlain` cost

A durable session-restore checkpoint with `terminal_text = .plain` calls `Vt.exportPlain` on
the venomx reactor, so its time is a stall for the whole daemon. For one
200-column pane with 99,864 rows it took about 4.4 s in ReleaseFast.

## Cause

`appendRow` read every cell through `ghostty_terminal_grid_ref`, which finds
the page again on each call, plus two more FFI calls per cell.

## Fix

`exportPlain` now asks ghostty's plain formatter for 1024 rows at a time, which
walks pages directly. The formatter's text is not quite a row: it drops blank
cells at the end of a row, blank rows at the end of the output, and spacer
cells. A row of printable ASCII has no wide cell, so padding it with spaces to
`cols` gives the old output.

Any other row still goes through `appendRow`, so its bytes don't change and it
costs what it did before. That includes a row holding a DEL, which `appendRow`
renders as a space.

## Results

ReleaseFast, on a shared machine with load average 7 to 55. "New" and "base"
ran alternately. All hashes of the exported rows match between the two builds.
Exports keep 83,886 rows (83,468 for `mixed`): at 200 bytes a row, the 16 MiB
budget clips the oldest history.

`zig build -Doptimize=ReleaseFast -Dheadless=true`, then `plain-bench <load>`.
The ranges are the medians of three rounds; trials are 3 (base) and 7 (new) per
round.

| Load | Base wall, ms | New wall, ms | Base CPU, ms | New CPU, ms |
|---|---|---|---|---|
| `ascii`: 167 `x` per row | 4448 to 14477 | 44 to 70 | 4441 to 5037 | 44 |
| `short`: 40 `x` per row | 4325 to 6395 | 16 to 28 | 4318 to 5019 | 16 to 26 |
| `mixed`: one wide character per row | 4774 to 12094 | 4791 to 13996 | 4766 to 4974 | 4773 to 5004 |

venomx `test/checkpoint_bench.py`, two runs of 5 trials per build, 16 MiB:

| Build | Longest ping per trial, s | Median checkpoint, s |
|---|---|---|
| Base | 4.637 to 16.804 | 5.578, 16.097 |
| New | 0.052 to 0.185 | 0.770, 1.209 |

The longest ping covers the whole reactor stall of a checkpoint, of which the
export is one part. The checkpoint file was 17,197,447 bytes in every trial of
both builds.

Rows with any non-ASCII text still cost about 4.8 s of CPU when every row has
some. [Non-ASCII rows](plain-export-non-ascii.md) fixes that.
