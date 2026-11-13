# Two-pane example measurements

`examples/panes.zig` runs two shells side by side using only the public
venom-term API (`Surface`, `Input`, `Vt`, `VtView`). It handles PTYs, raw
mode, `poll` and SIGWINCH through libc. It does not import libvaxis or
libghostty.

```sh
zig build example-panes 2>panes.log         # Ctrl-A o: switch focus, Ctrl-A q: quit
zig build -Doptimize=ReleaseFast
python3 test/measure_panes.py 100000        # Linux; writes a 7.5 MB file to a temp dir
```

## What the example does

- Spawns `$SHELL` (fallback `/bin/sh`) twice with `forkpty` and
  `TERM=xterm-256color`. Each PTY feeds its own `Vt`. Query replies go back
  through `write_pty`.
- Draws two bordered boxes and a status row into one `Surface`. Each pane
  draws through its own `VtView`. The terminal cursor follows the focused
  pane.
- `Input` parses stdin. Ctrl-A is the prefix key; every other key is
  forwarded **as the raw bytes it arrived as**. The outer terminal stays in
  legacy keyboard mode, so those bytes are what the inner shell expects.
  venomx will need a key encoder once it enables the kitty protocol. That is
  out of scope here.
- On SIGWINCH it resizes the Surface, each `Vt`, and each PTY
  (`TIOCSWINSZ`).
- Logs OSC 7501 and OSC 133 callbacks to stderr, one line each, when stderr
  is not the display terminal. The latest one also appears in the status row.
- Never polls on a timer. `poll` blocks with no timeout while nothing is
  dirty. While output streams, frames are coalesced to at most one per 8 ms.
  The PTY is read in chunks of up to 64 KiB.

## Results

2026-11-06, Linux x86_64 (Ryzen 7 9800X3D), Zig 0.17.0, ReleaseFast. Outer
terminal 200×50, so each pane's inner size is 98×47. SHELL=/bin/sh. Three runs
of `test/measure_panes.py 100000`.

| Measurement | Result |
|---|---|
| Idle CPU, both shells at a prompt, 5 s | **0 ticks** (all 3 runs), 0 output bytes |
| Idle CPU after the `cat`, 3 s | **0 ticks** |
| RSS idle / after the `cat` (10k-line scrollback) | 7.3 MiB / 14.9 MiB |
| `cat` of 7.5 MB (100k lines × 75 B) until `CATDONE` is on screen | **0.458–0.473 s** (≈15.4 MiB/s) |
| Same `cat` into a bare PTY, drained, no VT | 0.036–0.037 s |
| Time spent in `Vt.feed` during the `cat` | 425–442 ms (≈93% of the total) |
| Frames / draw+present time / bytes written during the `cat` | 65–67 frames / 30–31 ms / 59–63 KB |
| Resize 200×50 → 120×40 | inner shell's `stty size` reports `37 58` |
| OSC observations | `osc133 … prompt_start` and `osc7501 … state=working progress=40 app="build"` logged |

The harness reads `/proc/<pid>/stat` and `VmRSS` of the example process only;
the shells and `cat` are not counted.

## Findings

- **Idle cost is zero.** No frame timer and no wakeups; this confirms the
  [render and idle measurements](measurements-render-idle.md) in a real interactive loop.
- **Rendering is cheap; feeding is the bottleneck.** Coalesced frames
  needed about 0.47 ms each, and 7.5 MB of output became about 60 KB of screen
  updates. Nearly all the `cat` time is in `Vt.feed`, which v0 deliberately
  runs one byte at a time to keep row addressing correct (see
  [API.md](API.md#vt-headless-terminal)). At ≈15 MiB/s a pane is about 13×
  slower than a bare PTY. That is fine for interactive shells and agents. It
  is the first thing to optimize before venomx stress tests, for example by
  feeding in chunks and observing row changes per chunk.
- The renderer skips cells that are already blank. Probes must not wait on
  text that contains spaces; the harness pipes `stty size` through `tr`.

## Bounded text batches

2026-11-06, same machine, Zig 0.17.0, ReleaseFast, 200×50 outer
terminal and 98×47 panes, SHELL=/bin/sh. Three runs of the same
`python3 test/measure_panes.py 100000` command after batching printable
ASCII at parser ground:

| Measurement | Result |
|---|---|
| `cat` of the same 7.5 MB file until `CATDONE` is on screen | **0.043–0.044 s** (164.0–165.3 MiB/s) |
| Improvement over the original 0.458–0.473 s | **10.4–11.0×** |
| Same `cat` into a bare PTY | 0.036–0.037 s |
| Time in `Vt.feed`, whole probe including commands | 28.2–28.7 ms |
| Idle CPU before / after `cat` | **0 ticks** in 5 s / 3 s, all runs |
| Idle output | **0 bytes**, all runs |
| RSS idle / after `cat` | 7.37–7.39 MiB / 14.96–14.98 MiB |
| Frames / draw+present time, whole probe | 17 / 7.4–7.8 ms |
| Bytes drawn during `cat` | 8.1–8.5 KB |
| Resize / OSC callbacks / exit | `37x58` / OSC 133 and 7501 observed / 0 |

The `stats` timer covers the whole probe, including resize and commands;
`cat_seconds` still measures Enter to the marker reaching the outer screen.
The optimization exceeds the 5× target while leaving the renderer
unchanged. Fewer frames are needed because the output completes sooner.

Text batches contain at most one terminal row's width of printable ASCII.
That bounds wrapping to one row between anchor observations, even when a
feed contains a large unbroken string. Controls, non-ASCII bytes, and bytes
inside unfinished escape sequences retain precise bytewise observation, so
history erasure and screen switches are observed before subsequent output.
