# Spike: libvaxis on Zig 0.17

- **Purpose:** input to venom-term API v0. Sibling spike: [libghostty-vt](libghostty-vt.md).
- **Date:** 2026-11-06, Zig 0.17.0, Linux x86_64 (CachyOS).
- **Code:** the throwaway spike programs are no longer in the tree; the findings below are what remains of them.

## Decision: **go**

Use upstream libvaxis `main` as a normal `zig fetch` dependency, pinned by commit. No fork, no patch. One upstream bug (phantom F3 at startup, §3) is small enough for venom-term's input layer to filter until upstream fixes it.

## TL;DR

1. **It builds on Zig 0.17 with no changes.** Upstream `main` *targets* 0.17.0 (`minimum_zig_version = "0.17.0"`; the README says so, and 0.18-dev work lives on a `zig-0.18` branch). Upstream's own `zig build test` passes (48/48 steps), all 14 examples build, and so does the C library (`zig build lib`).
2. **The smoke test passes** in a pty harness that plays the terminal: box and text (wide chars, emoji), kitty keyboard protocol (press/repeat/release, alternate keys, associated text), legacy fallback, resize via SIGWINCH and in-band (mode 2048), synchronized output on every frame, clean terminal restore on exit. The rendered screen was checked by replaying vaxis's output through libghostty-vt.
3. **One upstream bug:** on terminals without explicit-width/scaled-text support (all but kitty), vaxis's capability probe leaks two phantom `F3` key presses to the app at startup.
4. **Idle is free:** 0 CPU ticks and 0 bytes written over 3 s idle. RSS about 8 MiB. 3 threads.
5. **Rendering is diff-based and writer-agnostic.** `render()` takes any `*std.Io.Writer`, so it runs headless (into a socket or a pane stream) with no tty. A one-cell change emits 41 bytes. An unchanged frame emits 0 bytes but still costs about 11 ns per cell to diff (23 µs at 80×24, 230 µs at 250×80).

## Known-good pin

| | |
|---|---|
| Repo | `github.com/rockorager/libvaxis` |
| Commit | `c1861acc835e42d6874f2b15744f472398fbdfb7` (main, committed 2026-11-05) |
| Version | `0.6.0` (`build.zig.zon`) |
| Zig | 0.17.0 (libvaxis's own minimum) |
| Zig package hash | `vaxis-0.6.0-BWNV_GQaDQAz9DPyb2245fA-MbFe1MtOMwVQ08z9-v50` |
| Dependencies | `uucode` only (lazy). The previous commit dropped `zigimg`: vaxis no longer decodes images. |

Also recorded in the repo README.

Cross-check: our ghostty pin itself depends on libvaxis at `0620b34`, three commits older, and on the **same** `uucode` commit (`1fb73433…`, same package hash). Zig dedupes the package. The tables differ, though: each builds `uucode` with its own field list. If binary size matters, vaxis supports `-Dexternal_uucode=true` so venom-term can hand both libraries one `uucode` module.

The stale `zig-0.17` branch (last commit 2026-10-12) is not the 0.17 line. Pin `main`.

## 1. Building on Zig 0.17

```zig
// build.zig.zon: zig fetch --save=vaxis https://github.com/rockorager/libvaxis/archive/<commit>.tar.gz
const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
mod.addImport("vaxis", vaxis.module("vaxis"));
```

| Check | Result |
|---|---|
| Upstream `zig build test` | 48/48 steps pass (Zig tests, C API tests, C examples) |
| Upstream examples (`-Dexample=…`, all 14) | all build |
| Upstream C library (`zig build lib`) | `libvaxis.a`, `libvaxis.so`, `vaxis.h`. The C API covers the **input parser only**. |
| Spike as a consumer (`zig fetch` dependency) | builds in Debug and ReleaseFast, no patches |
| Spike binary, ReleaseFast | static, no libc, 1.0 MB stripped |
| Debug run (DebugAllocator) | no leaks reported, smoke and bench |

The API is already on Zig 0.17's `std.Io`: `vaxis.init(io, gpa, environ_map, opts)`, `Tty.init(io, buf)`, `Loop(Event).init(io, &tty, &vx)`, and everything writes to `*std.Io.Writer`. No adapter is needed.

## 2. Smoke test

`spike-vaxis smoke` enters the alt screen, probes the terminal, asks for kitty flags with event reporting on, and on every event draws a rounded box with a header (size, frame count, kitty on or off), a Unicode line (`héllo wörld │ 日本語 │ 🐍`) and the last 8 events. `testdata/harness.py` runs it in a real pty and acts as the terminal:

- answers the probes like a terminal would: `CSI ? u` (kitty keyboard, unless `--legacy`), CPR, DA1, and `CSI 48;…t` for mode 2048 (with `--inband`);
- sends keys, resizes the pty from 80×24 to 120×40, idles for 3 s, then quits with `q`;
- checks the spike's event log and the synchronized-output framing, and replays the captured output through **libghostty-vt** (`vt-dump`) to check the screen and the terminal modes.

All four modes pass: kitty or legacy keys, crossed with SIGWINCH or in-band resize.

### Render a box and text

The final frame, as libghostty-vt sees it, at 120×40 after the resize (excerpt):

```
╭──────────────────────────────────────────────────────────────────────────╮
│venom-term spike  120x40  frame 14  resizes 2  kitty=true                 │
│unicode: héllo wörld │ 日本語 │ 🐍                                        │
│q or ctrl-c quits                                                         │
│                                                                          │
│press cp=97 shifted=65 base=null text=A mods=S                            │
│press cp=1081 shifted=null base=113 text=null mods=C                      │
```

Gotcha that the spike hit: **a `Cell` borrows its grapheme bytes; it doesn't copy them.** Text formatted into a stack buffer that goes out of scope before `render()` comes out as garbage. venom-term's draw API must own the text until render, for example in a per-frame arena.

### Kitty keyboard protocol

vaxis probes with `CSI ? u`, and when the terminal answers it pushes the requested flags (`CSI > 31 u` here: disambiguate, report events, alternate keys, all keys as escapes, associated text). On exit it pops them again. libghostty-vt confirms flags 31 during the run and 0 after exit.

| Sent (kitty, flags 31) | Event vaxis delivers |
|---|---|
| `CSI 97;;97u` (a) | press cp=97 text=a |
| `CSI 97;1:2;97u` (a, repeat) | press cp=97 text=a: **repeat looks like a press**; `Key` has no repeat flag |
| `CSI 97;1:3u` (a, release) | `key_release` cp=97 |
| `CSI 97;5u` (ctrl+a) | press cp=97 mods=C |
| `CSI 97:65;2;65u` (shift+a) | press cp=97 shifted=65 text=A mods=S |
| `CSI 1081::113;5u` (ctrl+й, Russian layout) | press cp=1081 base=113 mods=C: `base_layout_codepoint` works for shortcuts |
| `CSI 27u` (Esc) | press cp=27, with no ESC-prefix ambiguity |
| `CSI 1;5A`, `CSI 15~` | ctrl+up, F5 |
| `CSI 233;;233u` (é) | press cp=233 text=é |

Without kitty support (`--legacy`), vaxis falls back cleanly. `a`, `^A`, `A` (no Shift reported: legacy can't), a lone ESC, ctrl+up, F5 and UTF-8 `é` all decode as expected, and it never pushes kitty flags.

### Resize

- **SIGWINCH:** `Loop.installResizeHandler()` must be called explicitly. Without it, only the initial size arrives. A dedicated signal thread turns the signal into a `winsize` event.
- **In-band (mode 2048):** vaxis always sends `CSI ? 2048 h`. As soon as one `CSI 48;…t` report arrives, it switches to in-band and drops its SIGWINCH handler, so there is no duplicate event. The harness checked this.
- `vx.resize()` reallocates both screens and forces a full redraw on the next frame.

### Synchronized output

Every frame that writes anything is wrapped in `CSI ? 2026 h … CSI ? 2026 l` (14 of 14 frames; never nested). vaxis does this **unconditionally**: it doesn't query mode 2026, it relies on terminals ignoring unknown modes. libghostty-vt reports sync off at the end of the run, so there was no dangling begin. A frame with nothing to draw writes nothing at all, not even the sync pair.

## 3. Upstream bug: phantom F3 at startup

`queryTerminal()` probes explicit width (OSC 66) and scaled text by moving home, writing a probe, and asking for the cursor position (CPR, `CSI 6n`). The reply `CSI 1;col R` is parsed as an F3 key with modifiers. The loop swallows it only when the column moved, which reads as Shift+F3 or Alt+F3. A terminal that **doesn't** support the feature replies `CSI 1;1 R`, and vaxis posts it to the app as a plain **F3 press**: two of them, one per probe. Kitty supports both features, so the bug only shows in other terminals (ghostty, foot, alacritty, …). The harness reproduces it in all four modes.

- **Upstream:** worth an issue or a small PR. While `queries_done` is false, the loop should also swallow a modifier-free F3 that arrives as `CSI 1;1 R`. The parser can't tell it from a real F3 pressed during the probe, but that window lasts under a second.
- **venom-term:** filter it in our input layer: drop F3 presses with no modifiers that arrive before the DA1 reply ends the probe. Or call `queryTerminalSend` ourselves and consume the CPRs.

This is the only reason the decision isn't a plain "go". It doesn't need a fork or a patch.

## 4. Cost

**Idle** (harness, 3 s with no input): 0 CPU ticks, 0 bytes written, RSS about 8 MiB (Debug build, which includes the spike's buffers), 3 threads (main, input reader through `io.concurrent`, SIGWINCH signal thread). Rendering only happens on events, so an idle venom-term surface costs nothing.

**Render** (`spike-vaxis bench`, ReleaseFast, headless into a byte-counting writer, mean of 200):

| Screen | Content | First frame | Unchanged | One cell changed | Every cell changed |
|---|---|---|---|---|---|
| 80×24 | plain | 2.1 KB, 41 µs | 0 B, 24 µs | 41 B, 22 µs | 2.0 KB, 36 µs |
| 80×24 | styled (16 colors, bold) | 14.4 KB, 51 µs | 0 B, 22 µs | 41 B, 22 µs | 14.4 KB, 48 µs |
| 250×80 | plain | 21.8 KB, 389 µs | 0 B, 232 µs | 41 B, 233 µs | 20.3 KB, 376 µs |
| 250×80 | styled | 149 KB, 522 µs | 0 B, 230 µs | 41 B, 230 µs | 149 KB, 516 µs |

- **Output is minimal:** only changed cells are written, and the cursor moves between runs. Styled output is about 7× plain, because SGR is re-emitted per cell when styles alternate.
- **CPU scales with screen area, not with change.** Each `render()` diffs every cell (about 11 ns per cell), even when nothing changed. That is negligible at 60 fps for one screen, but venom-term should **skip `render()` when nothing was drawn** instead of rendering on a timer.
- **Memory per surface:** about 136 B per cell for the front screen plus 104 B per cell for the back screen: 0.45 MB at 80×24 and 4.8 MB at 250×80. This is one surface per *client terminal*, not per pane: panes are libghostty-vt grids blitted into one vaxis screen.

## 5. What this means for venom-term API v0

What we wrap, and what must not leak (`Vaxis`, `Window`, `Cell`, `Key`, `Loop`, `Tty` are libvaxis types):

- **Surface:** wraps `Vaxis` + `Window`. Draw calls copy text into a per-frame arena (the borrowing gotcha above). `present()` calls `render()` only when something was drawn.
- **Output to any writer:** `render(*std.Io.Writer)` works with no tty, so the same surface can serve a local terminal or a remote venomx client socket.
- **Input:** our own `Key` type mapped from `vaxis.Key`: codepoint, text, shifted, base-layout, mods, press or release. Filter the phantom F3. Note that repeats are indistinguishable from presses.
- **Tty is process-global:** `Tty.init` always opens `/dev/tty`, and it keeps `global_tty`, a signal pipe and a signal thread in module globals. That means one tty per process. That suits the venomx client and the venom TUI. A headless daemon doesn't need a `Tty`: it renders to a writer and feeds input to `vaxis.Parser` directly.
- **Resize:** always call `installResizeHandler()`. In-band takes over automatically where it's supported.
- **No libvaxis VT widget:** libvaxis ships its own terminal emulator widget (`examples/vt.zig`). We don't use it: panes are libghostty-vt.
- **Images:** vaxis no longer decodes images. If we need them, the kitty graphics transmit path remains, with decoding left to the caller.

## 6. Risks and follow-ups

- **Phantom F3**: file it upstream; until then, filter in venom-term.
- **Tracking `main`:** libvaxis has no 0.17 release tag; `0.6.0` is the version string on `main`. Each pin bump should re-check startup input and render cost.
- **Zig 0.18:** upstream already does that work on the `zig-0.18` branch, so a future Zig bump should be a pin change, not a port.
- **Not covered here:** mouse, bracketed paste, kitty graphics, Windows. None of them blocks the venom-term API.
- **Real terminals:** the harness plays a correct kitty-protocol terminal, and libghostty-vt checks the output. It is still worth a by-hand run of `spike-vaxis smoke` in ghostty, kitty and foot before venom-term relies on it.
