# Spike: libghostty-vt on Zig 0.17

- **Purpose:** input to the pane-stream protocol and to venom-term API v0.
- **Date:** 2026-11-06, Zig 0.17.0, Linux x86_64 (CachyOS), ReleaseFast.
- **Code:** the throwaway spike programs (`spike-c`, `spike-zig`, `spike-zig-c`) are no longer in the tree; every number below came from `spike-c`.

## TL;DR

1. **It works on Zig 0.17.** Ghostty `main` *requires* Zig 0.17.0 (`minimum_zig_version = "0.17.0"`). Both the `ghostty-vt` Zig module and the `ghostty-vt-static` C library build as a normal `zig fetch` dependency, with no patches.
2. **Use the C API**, called from Zig through `addTranslateC`. Its ABI is guarded by goldens and a CI check that only allows additions. The Zig module exposes internals (`Terminal`, `Screen`, `PageList`) with no stability promise.
3. **libghostty-vt already has a snapshot format, and its shape is the one the pane-stream protocol wants:** `TERMINAL → SCREEN+PAGEs → CONTINUATION → READY → HISTORY pages (newest→oldest) → FINISH`. It is CRC-protected, skips unknown records, and decodes incrementally. The restored terminal is renderable at READY, before history arrives. It also restores an unfinished escape sequence. **Recommendation:** the pane stream carries the ghostty snapshot as an opaque payload inside our own framing; it does not invent a grid format. Caveat: snapshot format v1 is explicitly "work in progress, no binary-compatibility guarantee", so peers must run the same pinned libghostty-vt (see risks).
4. **Rows have no stable identity.** Coordinates are relative to the oldest retained row, and scrollback is pruned a whole page at a time (~570 rows at 80 cols). Reflow on resize splits or joins rows. There is no absolute row counter, and the snapshot carries none. venom-term can maintain an absolute row index cheaply with one tracked grid ref. It is exact across 20k lines of pruning, but it is only meaningful within an **epoch** that resets on reflow and on clearing scrollback. The pane stream should address history as `(epoch, absolute_row)`.
5. **Headless: yes.** The library has no renderer, no fonts, no GPU and no threads. The final binary depends only on `libc.so.6`.
6. **Snapshot cost is small.** An 80×24 or 250×80 screen encodes in 2–40 µs, and the READY prefix is 1–185 KB. 10k lines of history take 0.3–1.2 ms to encode and come to 2.3 MB at 80 cols or 7.1 MB at 250 cols raw. The stream compresses about 10× (real output) to 60–180× (repetitive output) with zstd.
7. **Memory per pane at 10k lines:** 6.4 MiB at 80 cols and 20.5 MiB at 250 cols uncompressed (≈ 8.7 bytes per cell). With libghostty's built-in scrollback compression that drops to 0.57 MiB and 0.65 MiB. 32 panes measured 206 MiB, then 18 MiB after compression. venom-term should compress idle panes by default.

## Known-good pin

| | |
|---|---|
| Repo | `github.com/ghostty-org/ghostty` |
| Commit | `16f5674dc3eaeee9575d2b729255f2fe0993ece3` (main, 2026-11-06T10:15:03Z) |
| App / lib version | `1.4.1-dev` / libghostty-vt `0.1.0-dev` (no `vt-*` release tag exists yet) |
| Zig | 0.17.0 (ghostty's own minimum) |
| Zig package hash | `ghostty-1.4.1-dev-5UdBCwFUmgWquUMcWR-DEz69PiIofNx_es9ow-zIGQ6q` |
| Artifacts used | module `ghostty-vt`; static lib `ghostty-vt-static` (+ simdutf, highway, libc++ linked statically) |

Also recorded in the repo README.

## 1. Building on Zig 0.17: Zig module vs C API

```zig
// build.zig.zon: zig fetch --save=ghostty https://github.com/ghostty-org/ghostty/archive/<commit>.tar.gz
const dep = b.dependency("ghostty", .{ .target = target, .optimize = optimize });
mod.addImport("ghostty-vt", dep.module("ghostty-vt"));        // Zig module
mod.linkLibrary(dep.artifact("ghostty-vt-static"));            // C library
const tc = b.addTranslateC(.{ .root_source_file = dep.path("include/ghostty/vt.h"), ... });
tc.addIncludePath(dep.path("include")); tc.defineCMacro("GHOSTTY_STATIC", "");
```

All three spike executables build and pass: `spike-zig` (Zig module), `spike-c` (C) and `spike-zig-c` (C API through translate-c). A cold build takes about 36 s. A stripped binary is 2.4 MB.

| | Zig module `ghostty-vt` | C API `libghostty-vt` |
|---|---|---|
| Stability | Internal Zig types. Fields and signatures change freely, and we use `t.screens.active.cursor` directly. | ABI goldens (`src/terminal/c/abi/`). `test-lib-vt-abi` fails CI on any change that isn't an addition. Opaque handles and sized structs. |
| Leaking types | Easy to leak `Terminal`/`Pin`/`Page` into our API. | Opaque handles. Wrapping them is natural, so this meets the "don't leak libghostty types" rule. |
| Features | Everything | Everything we need: terminal, stream, snapshot, grid refs, tracked refs, formatter, render state, key/mouse encode, compression, memory usage |
| Zig ergonomics | Native | translate-c output plus a thin wrapper. Error codes, not error unions. |

**Decision for venom-term:** wrap the C API. Keep a Zig-module escape hatch only if we hit a feature the C API lacks. None came up in this spike.

## 2. Smoke test: PTY capture → grid, cursor, scrollback → snapshot → restore

The input is three real PTY captures (`testdata/*.pty`, recorded through a real pty with `record.py`). Before the capture, the test writes a prefix that sets the title, pwd (OSC 7), bracketed paste, SGR mouse with button tracking, focus events and kitty keyboard flags. Bytes are fed in 37-byte chunks, so sequences and UTF-8 straddle writes. The snapshot is taken **while the parser is in the middle of a CSI sequence**. The rest of the capture is then fed to both the source and the restored terminal, and the two are compared.

| Capture | Size at snapshot | Snapshot | Identical after rest of stream |
|---|---|---|---|
| `shell-mixed.pty`: `ls --color -la`, `git log --stat`, OSC 0/7, combining chars, CJK, emoji | 80×24, 209 scrollback rows | 62.7 KB | **yes** |
| same, at 250×80 | 128 scrollback rows | 63.1 KB | **yes** |
| `top-altscreen.pty`: `top`, CUP-heavy, hidden cursor, pending wrap | 80×24 | 4.2 KB | **yes** |
| `vim-altscreen.pty`: `vim`, alternate screen active | 80×24 alt | 2.4 KB | **yes** |

"Identical" means equal cursor x/y, pending-wrap flag, cursor visibility, active screen, cols/rows, total and scrollback rows, title, pwd, modes 2004/1006/1004/DECCKM, mouse tracking, kitty keyboard flags, the full plain-text dump including scrollback, and the full styled VT dump. The Zig-module path (`spike-zig`) also round-trips: identical plain text and cursor. It reports no leaks in Debug.

Reading things back:
- **Grid:** use `ghostty_terminal_grid_ref(point)` + `ghostty_grid_ref_cell/row/style/graphemes`, or the `render_state` row/cell iterators for a renderer with dirty tracking.
- **Cursor:** `TERMINAL_DATA_CURSOR_X/Y/PENDING_WRAP/VISIBLE`.
- **Scrollback:** `TOTAL_ROWS`, `SCROLLBACK_ROWS` and `SCROLLBAR`. `POINT_TAG_SCREEN`/`HISTORY` address rows in history.

One gotcha: snapshots need `TERMINAL_OPT_CONTINUATION_MAX_BYTES` set **before** input. Without it, encoding a terminal whose parser is not at ground fails with `INVALID_VALUE`. venom-term must turn it on when it creates every pane.

## 3. Cost of one emulator per pane (10k lines of scrollback)

`SCROLLBACK_MAX_LINES = 10000`, `MAX_BYTES = unlimited`. The table shows memory from `TERMINAL_DATA_MEMORY_USAGE` (resident bytes), before and after `ghostty_terminal_compress(FULL)`.

| Pane | Content | Scrollback rows held | Resident | Pages | Resident, compressed |
|---|---|---|---|---|---|
| 80×24 | empty | 0 | 0.38 MiB | 1 | 0.38 MiB |
| 80×24 | plain text | 9,428 | 6.44 MiB | 17 | 0.51 MiB |
| 80×24 | styled (`ls --color`-like) | 9,428 | 6.44 MiB | 17 | 0.57 MiB |
| 250×80 | plain text | 9,816 | 20.46 MiB | 54 | 0.58 MiB |
| 250×80 | styled | 9,816 | 20.46 MiB | 54 | 0.65 MiB |
| **32 panes** 80×24 styled | | 10k each | 206 MiB (RSS +188 MiB) | | **18 MiB** (RSS +12 MiB) |

- Uncompressed memory is set by page *capacity*, not content: about 8.7 bytes per cell. So it scales with cols × scrollback lines, and styling costs nothing extra.
- Compression is built in (`compress(INCREMENTAL)` for idle callbacks, `FULL` for one pass). History is decompressed transparently when it is accessed. The ratio is about 11× for 80-col output and about 30× for 250-col output.
- The line limit prunes **whole pages**, so retained scrollback oscillates below the limit: 9,428 of 10,000 at 80 cols. The header comment says "almost always higher"; in our runs it was lower. The UI should treat the limit as approximate.
- The library spawns no threads (no `pthread_create` import), so an idle pane uses zero CPU. Rendering cost belongs to libvaxis (see the [libvaxis spike](libvaxis.md)).

## 4. Pane-stream questions

### 4.1 Does libghostty-vt expose a state serialization we can use as the snapshot wire format?

**Yes.** `ghostty_snapshot_encode` / `_encode_buf` / `_encode_alloc` and `ghostty_snapshot_decoder_{new,new_buf,set,ready,next,decode,get}`. A formal Kaitai description is at `src/terminal/snapshot/snapshot.ksy`.

What it carries:
- **TERMINAL:** cols/rows, pixel size, scrolling region, active screen, tab stops, palette and overrides, pwd, title, mouse event/format, modify-other-keys, cursor defaults and more.
- **SCREEN:** cursor, saved cursor, cursor hyperlink and pen; per screen, so the alternate screen is included.
- **PAGE:** self-contained cells, styles, hyperlinks, graphemes.
- **Kitty images**, as optional records.
- **CONTINUATION:** the bytes of an unfinished escape sequence or UTF-8 codepoint, so the restored parser resumes mid-sequence.

What it leaves out by design: selection, viewport position, dirty state, native page IDs.

Its structure already matches what the pane stream calls *snapshot / ready*:
- **READY marker:** the decoder returns a live, renderable terminal from `decoder_ready()` before any history. The client paints, then calls `decoder_next()` once per history page. **The terminal may be rendered, resized and fed live PTY bytes between `next()` calls.** That is exactly "snapshot, then live raw PTY fan-out, with history backfilled".
- **History newest → oldest**, so pages are prepended as they arrive. `HISTORY_ROWS_PRIMARY` gives the full extent at READY, so the scrollbar is correct immediately.
- Every record is framed (`tag u16, len u32, crc32c u32`). Unknown tags are skipped after a CRC check, so additions are forward-compatible.
- Bytes after FINISH are not consumed, so the snapshot can sit inside a larger stream.

What it is **not**: in ghostty's own words, it is "NOT a full transport-ready format... for multiplexers". It has no sequence numbers, no pane ID, no notion of "live bytes from offset N", and "transports that deliver live PTY data before history finishes must multiplex that data outside this ordered snapshot record sequence."

**Recommendation for the pane stream:**
- Define our own framing (pane ID, stream sequence or byte offset, message kinds `snapshot-chunk`, `ready`, `pty`, `history-chunk`, `resync`).
- Carry the ghostty snapshot bytes **opaquely**, split at record boundaries. Send READY first, then interleave live `pty` frames with history chunks. The client's decoder consumes snapshot chunks while live bytes go to `vt_write` on the same terminal, which the decoder explicitly allows.
- **Version negotiation:** snapshot format v1 has no compatibility guarantee yet. The handshake must exchange the snapshot envelope version (`GHOSTSNP` + u16) and the libghostty-vt build (`build_info.h`). If they don't match, use a fallback: replay a VT dump from `ghostty_formatter` (`FORMAT_VT` gives a styled dump of the screen and scrollback), or refuse. venom-term pins one ghostty commit for the whole ecosystem, so mismatches only happen across venom versions.
- Do **not** expose ghostty record types in our API beyond "opaque, versioned blob with READY/FINISH". This keeps the "no libghostty types in the public API" rule.

### 4.2 Do rows have stable identities, so history chunks can be addressed by absolute row?

**No, not natively.** Measured (`spike-c rows`):

- **Coordinates are relative to the oldest retained row.** `POINT_TAG_SCREEN` y=0 is the oldest row still held. With a 1,000-line limit, after 5,000 lines y=0 had moved from `L000000` to `L004011`.
- **Pruning drops whole pages:** 7 prunes of 573 rows each, at 80 cols. So "first retained row" jumps in steps of hundreds, not one row at a time.
- **No absolute counter exists.** `PageList.total_rows` is the current count. `page_serial` is a page *generation* that changes on reuse and reflow; it is not a row ID. The snapshot has no absolute offset either: the restored terminal's y=0 is just the oldest row it got.
- **Tracked grid refs follow content.** A tracked ref on `L004971` moved from SCREEN y 960 to y 387 after 400 more lines and still pointed at `L004971`. Once its page was pruned, `has_value` became false.

**Cheap way to derive absolute rows (validated):** venom-term keeps **one** `GhosttyTrackedGridRef` anchored on the first active row, together with that row's absolute index. After each `vt_write`, the anchor's new SCREEN y gives `abs(y=0) = anchor_abs − anchor_y`; then re-anchor. Over 20,000 lines written in 2,858 separate writes, with pruning throughout, this had **0 mismatches and 0 lost anchors**. It costs one `tracked_grid_ref_point` and one `tracked_grid_ref_set` per write. The anchor is only lost if a single write pushes more than the whole scrollback through, so the pane reader should cap its chunk size well below the scrollback size, or bump the epoch when the anchor is lost.

**Where absolute numbering stops making sense:**
- **Resize with reflow** splits or joins soft-wrapped rows. Going from 80 to 40 cols, `total_rows` went from 625 to 725. The anchor survived, but the rows above it changed, so the derived index no longer described the same rows.
- **Clearing scrollback** (`CSI 3 J`) drops history: `total_rows` became 24. RIS (`reset`) very likely does the same; that was not measured.
- **Snapshot restore** keeps the rows themselves but no offset.

**Recommendation for the pane stream:** address history as `(epoch, absolute_row)`. venom-term owns both values:
- `absolute_row` comes from the anchor technique above.
- `epoch` increments on any column resize that reflows, on scrollback clear or RIS, and when the anchor is lost.
- The snapshot header (our framing) carries `(epoch, abs_row_of_oldest_row)`, so a client can turn a restored terminal's SCREEN y into absolute rows.
- History requests for an older epoch get a `resync` instead of rows.

Prefer **logical lines** (unwrapped) if agents need content addresses that survive resize. That is a separate, text-level index, and it should not live in the pane stream.

### 4.3 Does it run headless, with no renderer linked?

**Yes.** libghostty-vt is only the terminal state machine. It has no renderer, font, GPU, windowing or event-loop code. The static `spike-c` binary's dynamic dependencies are only `libc.so.6` (C++ deps simdutf, highway and libc++ are linked statically; `-Dsimd=false` would even remove libc). Its undefined symbols are all plain libc: malloc, mmap/madvise/mremap, `shm_open`, file I/O. There are no pthreads.

- The optional render helper (`render.h`: `render_state`, row/cell iterators with dirty flags) is plain data for *our* renderer (libvaxis), not a renderer.
- Query replies (DA, DSR, XTVERSION…) are callbacks (`TERMINAL_OPT_WRITE_PTY` etc.). Headless panes must wire `WRITE_PTY` so programs that ask the terminal questions still get answers; otherwise they are dropped silently.

### 4.4 How long does a snapshot take, and how big is it, for 80×24 and 250×80?

The table shows medians of 25 runs (9 for the 10k rows), ReleaseFast, on one core. "To READY" is the byte offset where READY ends, which is what a client needs before it can paint.

| Screen | Content | Total | To READY | Encode | Decode to READY | Decode all |
|---|---|---|---|---|---|---|
| 80×24 | empty | 1.2 KB | 1.1 KB | 2 µs | 12 µs | 12 µs |
| 80×24 | full alt-screen TUI frame, styled | 6.8 KB | 6.8 KB | 4 µs | 31 µs | 31 µs |
| 80×24 | real capture (479 rows) | 122 KB | 122 KB | 36 µs | 147 µs | 147 µs |
| 80×24 | capture + 10k history | 2.33 MB | 40 KB | 343 µs | 48 µs | 2.2 ms |
| 250×80 | empty | 1.3 KB | 1.3 KB | 4 µs | 19 µs | 19 µs |
| 250×80 | full alt-screen TUI frame, styled | 58 KB | 58 KB | 12 µs | 77 µs | 77 µs |
| 250×80 | real capture | 123 KB | 67 KB | 33 µs | 106 µs | 181 µs |
| 250×80 | capture + 10k history | 7.13 MB | 185 KB | 1.0 ms | 178 µs | 6.5 ms |

Wire size with general-purpose compression:

| Snapshot | Raw | zstd -3 | gzip -6 |
|---|---|---|---|
| real capture, 80×24 | 122 KB | 12.0 KB | 11.6 KB |
| real capture, 250×80 | 123 KB | 12.1 KB | 11.6 KB |
| 10k history, 80×24 (synthetic, repetitive) | 2.33 MB | 26.6 KB | 65.6 KB |
| 10k history, 250×80 (synthetic, repetitive) | 7.13 MB | 39.6 KB | 109 KB |
| *for reference: the raw PTY capture itself* | 36.6 KB | 6.6 KB | |

What this means for the pane stream:
- **The READY prefix is sized in pages, not screens.** SCREEN sends the *complete* pages covering the active area, including any history that shares a page with it. So READY ranges from about 1 KB to one or two pages (≤ ~120 KB at 80 cols, ≤ ~185 KB at 250 cols), whatever the screen size. Time to first paint stays under about 0.2 ms of decode.
- **Encoding is fast enough to do on demand** (≤ 1.2 ms even with 10k lines at 250 cols), so there is no need to cache snapshots. But encoding needs exclusive access to the terminal: do it on the pane's own thread, between `vt_write`s. Encoding compressed history costs about 1.3–1.8× more because pages are decompressed on read.
- **Raw snapshots are about 3× the PTY bytes** for real output, and much more for big history, because cells are fixed width. **Compress the transport** (zstd per stream) for anything off-host, at least the history chunks. Local Unix-socket attach can stay raw.
- A client decoding history should set `SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY`, so 10k lines of history never sit uncompressed in its memory.

## 5. API surface venom-term needs

We wrap these in venom-term's own types (`vt.Pane`, `vt.Snapshot`, …). No ghostty type crosses the public API.

**Lifecycle and config**
- `ghostty_terminal_new`, `_free`, `_reset`, `_resize(cols, rows, cell_w_px, cell_h_px)`
- `ghostty_terminal_set`: `SCROLLBACK_MAX_LINES`/`_BYTES`, `CONTINUATION_MAX_BYTES` (**always on**), `COLOR_*`/`PALETTE`, `DEFAULT_CURSOR_*`, `KITTY_IMAGE_STORAGE_LIMIT`, `USERDATA`

**Input from the PTY**
- `ghostty_terminal_vt_write`
- `ghostty_terminal_vt_write_until(boundaries)`: lets venomx/venom stop at OSC/APC boundaries. Needed for OSC 7501 / OSC 133 awareness without a second parser.
- Callbacks: `WRITE_PTY` (query replies), `BELL`, `TITLE_CHANGED`, `PWD_CHANGED`, `CLIPBOARD_WRITE`/`_READ` (behind capability grants), `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT`, `SEMANTIC_PROMPT`, `UNKNOWN_SEQUENCE` (for venom's own OSC 7501), `RENDER_HOLD` (synchronized output)

**State queries** (`ghostty_terminal_get` / `_get_multi`)
- `COLS`, `ROWS`, `CURSOR_*`, `ACTIVE_SCREEN`, `TITLE`, `PWD`, `MODE`, `MOUSE_TRACKING`, `KITTY_KEYBOARD_FLAGS`
- `TOTAL_ROWS`, `SCROLLBACK_ROWS`, `SCROLLBAR`, `VT_GROUND`, `CURSOR_AT_PROMPT`, `MEMORY_USAGE`

**Grid and rendering**
- `ghostty_render_state_*` (update, row/cell iterators, dirty rows) feeding libvaxis
- `ghostty_terminal_grid_ref` + `ghostty_grid_ref_{cell,row,style,graphemes,hyperlink_uri}`, `ghostty_cell_get`, `ghostty_row_get`
- `ghostty_terminal_scroll_viewport`

**Row identity**
- `ghostty_terminal_grid_ref_track`, `ghostty_tracked_grid_ref_{point,set,has_value,free}` (the absolute-row anchor, §4.2)

**Snapshots**
- `ghostty_snapshot_encode` (to a `GhosttyWriter`, so it streams straight into the pane-stream framing), `_encode_alloc`
- `ghostty_snapshot_decoder_new` (with a `GhosttyReader`), `_set(COMPRESS_HISTORY, MAX_CONTINUATION_BYTES)`, `_ready`, `_next`, `_get(SOURCE_OFFSET, HISTORY_ROWS_*, PROGRESS_*)`, `_free`

**Memory**
- `ghostty_terminal_compress(INCREMENTAL)` on idle, `_compression_activity`

**Text extraction** (agents, `pane read --json`, fallback replay)
- `ghostty_formatter_terminal_new` / `_set(EMIT=PLAIN|VT, UNWRAP, TRIM, SELECTION)` / `_format_alloc`

**Input encoding** (keys and mouse sent to the PTY)
- `key_encode` / `mouse_encode` / `focus` / `paste`, so encoding follows the pane's live modes (kitty keyboard, DECCKM, SGR mouse, bracketed paste)

**Search and selection** (later): `search.h`, `selection.h`.

## 6. Risks and follow-ups

- **Snapshot format v1 is unstable** ("work in progress… no binary-compatibility guarantee"). Mitigations: one ecosystem-wide ghostty pin in venom-term; a version handshake in the pane stream; a formatter-VT replay fallback. Revisit when ghostty tags `vt-0.1.0`.
- **libghostty-vt is unreleased** (`0.1.0-dev`, no tags). We track `main`, so pin bumps need a re-run of this spike's checks. Follow-up: turn the spike into venom-term tests (snapshot round-trip, mid-sequence continuation, anchor drift) once the venom-term API lands.
- **Pruning granularity:** the scrollback limit is approximate (page-sized steps). Expose the setting as "about N lines".
- **Headless query replies:** without `WRITE_PTY`, programs that query the terminal can stall or misbehave. venom-term must wire it.
- **Exclusive access during encode:** the ghostty API is not thread-safe per terminal. The venom-term pane must own its terminal on one thread and serve snapshots from there.
