# Authoritative VT throughput

venomx's first raw-attach benchmark spent roughly a second of daemon CPU
on an 8 MiB transfer. The product polled pane titles by encoding a full VT
snapshot after every PTY read. That serializes retained history and formats
the screen even when the title is unchanged.

`Vt.title()` now reads the title metadata directly. Its slice is borrowed
until the next mutation. The product compares and copies it when publishing
a title change; it no longer parses an OSC from a screen replay.

The feed path also avoids screen/reset queries for ground-state text and
CR/LF, which cannot change screens or erase history. CRLF pairs are one
operation. A printable line followed by CRLF is one operation when it cannot
wrap and left/right margins are disabled. Cursor and pending-wrap checks
establish the first such line in a feed; later CRLF lines establish their own
column-zero starting state. Unsafe controls, partial UTF-8 and partial escapes
retain exact observation. The tracked row anchor is still checked after each
bounded row operation. Anchor placement uses active-area coordinates for the
same first active row, avoiding a full-history coordinate lookup.

## Reproduce

Keep the release install separate from default Debug builds:

```sh
zig build -Dheadless=true -Doptimize=ReleaseFast --prefix zig-out/release
zig-out/release/bin/feed-bench 100 8388608 snapshot 30
zig-out/release/bin/feed-bench 100 8388608 title 30
zig-out/release/bin/feed-bench 284 8388608 snapshot 69
zig-out/release/bin/feed-bench 284 8388608 title 69
```

The benchmark generates 79 printable bytes plus CRLF per line, feeds 16 KiB
chunks, and polls the selected metadata after each feed. `none` measures
feeding alone. An optional final repeat count runs several passes through
the same terminal, useful for profiling steady-state behavior. There is no
socket, PTY, renderer or product callback.

## Measurements

2026-11-07; Ryzen 7 9800X3D, Linux 7.3.1, Zig 0.17.0, ReleaseFast;
8,388,608 bytes; three runs per configuration:

| Size | Snapshot polling | Direct title polling | Ratio of medians |
|---|---:|---:|---:|
| 100 × 30 | 235.0–249.0 ms | 17.64–18.28 ms | 13.2× |
| 284 × 69 | 332.7–337.4 ms | 36.13–37.85 ms | 9.0× |

Before the feed changes, the same 100 × 30 workload with direct title polling
needed 29.2 ms. The optimized feed/title path measures 18.1 ms, about 1.6×
faster. Product throughput also depends on ring copies, scheduling, transport,
tokenization and the host terminal; these numbers alone do not establish
venomx's 10% end-to-end budget for raw attach.

Two debugger samples of the ReleaseFast steady-state workload (100 passes,
interrupted after two seconds) landed in Ghostty's `printSliceStoreRun`,
called through `printSliceAscii`. These samples identify remaining backend
cell writing; they do not quantify its percentage of total time. Optimizing
or replacing the pinned Ghostty backend is outside this wrapper change.

## Correctness checks

Tests compare complete VT replays and row metadata with bytewise feeding
through pending wraps, CRLF, horizontal and vertical margins, disabled wrapping,
resets, one-row terminals and zero retained scrollback. Existing erasure,
pruning, Unicode, snapshot, callback and allocation-failure tests remain in
the suite. The title test covers empty state, OSC 0/2, split sequences,
Unicode and reset. No renderer, worker or idle polling was added.
