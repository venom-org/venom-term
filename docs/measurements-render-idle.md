# API v0 rendering and idle measurements

2026-11-06, Linux x86_64, Zig 0.17.0, ReleaseFast. Reproduce from the repo root:

```sh
zig build -Doptimize=ReleaseFast
python3 test/measure_idle.py
```

The probe creates 1 or 32 independent Vt panes at the stated size, each with
one short styled Unicode line and no history. One Surface and VtView draw the
first pane. It presents once, draws/presents the identical frame 100 times
(asserting zero additional bytes), then sleeps for 5 seconds. The Python
harness measures `/proc` CPU ticks and RSS across 3 seconds of that idle
period. There is no frame timer or idle polling. Each process has one thread.

| Pane size | Panes | Process RSS | CPU ticks / 3 s | First draw + present | Unchanged 100 frames |
|---|---:|---:|---:|---:|---:|
| 80×24 | 1 | 4,876 KiB | 0 | 0.219 ms | 0 bytes |
| 80×24 | 32 | 5,964 KiB | 0 | 0.213 ms | 0 bytes |
| 250×80 | 1 | 10,744 KiB | 0 | 1.961 ms | 0 bytes |
| 250×80 | 32 | 11,832 KiB | 0 | 2.003 ms | 0 bytes |

Each first frame emits 57 bytes. The sparse idle-pane RSS slope between 1 and
32 panes is approximately **35 KiB/pane at 80×24** and **35 KiB/pane at
250×80**. Process totals include the executable, shared libraries, one
Surface and renderer, and allocator overhead; the slope is an estimate, not
an exact per-terminal allocation count. These numbers do not measure panes
filled with output/history. See the [Ghostty spike](spikes/libghostty-vt.md)
for 10k-line history and compression costs.

An unchanged `Surface.present` skips libvaxis entirely. Repeated VtView draws
still traverse cells and allocate temporary grapheme buffers; clients should
draw on changes, not on an idle frame timer. The v0 grid-reference reader and
bytewise feed favor row correctness and a small implementation. These first
paint times include both grid extraction and renderer setup, measured with
four probe processes running concurrently, and are not steady-state FPS
claims.

The unit suite additionally replays emitted bytes through an independent Vt
to check Unicode, combining characters, styling, cursor placement and a
subsequent cell update. A separate headless consumer compiles/runs with
`headless=true`; its build rejects registration of the renderer module.
The headless executable's dynamic dependencies are libc and libm only, and
its symbol table has no libvaxis symbols.
