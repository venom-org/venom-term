# venom-term API v0

Zig 0.17.0. The pins in the README define the backend and snapshot versions.
Products import only venom-term modules and use Venom types. No Ghostty or
libvaxis handle, cell, event, or writer type is required by the public API.
The normal Zig standard-library allocator, I/O, and writer types are shared.

## Build and imports

```zig
const term = b.dependency("venom_term", .{ .target = target, .optimize = optimize });
app.addImport("venom-term", term.module("venom-term"));
```

The full module exports `Surface`, `Input`, `Vt`, `VtView`, `widgets`,
`chrome`, `pane_stream`, `Cell`, `Style`, `Color`, and `Region`. A daemon requests only the headless module:

```zig
const term = b.dependency("venom_term", .{
    .target = target, .optimize = optimize, .headless = true,
});
daemon.addImport("vt", term.module("vt"));
```

`@import("vt").Vt` links the pinned Ghostty C library, with no libvaxis
import, renderer, TTY, or event loop. `zig build -Dheadless=true` builds the
Vt-only smoke binary. `zig build test` runs it and a separate dependent
package that explicitly checks the renderer module was not registered.

## Ownership and execution

`Vt.init(allocator, options)` allocates a terminal. Pair it with `deinit()`.
The allocator also backs Ghostty allocations through a private bridge, so
`std.testing.allocator` checks backend allocation lifetimes in unit tests.
Vt is an owning handle: do not independently deinitialize copies. Its private
implementation stays at a stable address; moving the handle is allowed.

Serialize **all** access to one Vt. It has no worker threads, timers, I/O,
TTY, or automatic scheduling. Separate Vts can run on separate threads.
Call `compress()` when idle; it performs one bounded compression step and
returns whether another step remains. Callers decide when idle work runs.

Surface also owns its cells and renderer. Do not copy it or edit its fields
directly. `Surface.deinit(writer)` frees memory and writes libvaxis terminal
restoration when presentation has been used. Keep the output writer usable
until deinit. Flush the caller's writer as appropriate for the transport.

## Vt: headless terminal

Options select nonzero `cols`/`rows`, approximate `scrollback_lines`
(default 10,000), nonzero `continuation_bytes` (default 1 MiB), and callbacks.
The line limit is approximate because Ghostty prunes whole pages.

- `feed(bytes)` feeds arbitrary PTY chunks, including partial UTF-8 and
  escape sequences. Ghostty validates untrusted VT input.
- `resize(cols, rows)` changes dimensions; zero dimensions fail. An identical
  size is a no-op. Successful dimension changes start a new row epoch.
- `title()` returns the current OSC 0/2 title as a borrowed UTF-8 slice,
  valid until the next mutation of that Vt. It reads metadata directly;
  callers polling titles must not encode snapshots or inspect VT replay.
- `pwd()` returns the last working directory reported by OSC 7 (a raw
  `file://host/path` URI, percent-encoding kept), OSC 9;9 or OSC 1337
  CurrentDir (usually a bare path), stored as the program sent it and not
  decoded. Callers must handle both forms. It is borrowed until the next
  mutation of that Vt (feed, resize, reset), so copy it to keep it. It is null
  when unset or cleared by an empty OSC 7.
- `size()` and `cursor()` return cell dimensions and cursor coordinates and
  visibility. Cursor coordinates are relative to the active area.
- `rows()` returns `{epoch, oldest, end, active}`. The retained interval is
  `[oldest,end)`; `active` is the absolute row of the active area's first row.
- `readCell(allocator, epoch, row, col)` returns a Cell with allocated UTF-8
  text. Free `cell.text` with that allocator. Width 2 is a wide glyph; width
  0 is its continuation. Combining characters remain in the grapheme. It
  never fails on what a pane wrote and never returns a control character: a
  control in a cell reads as a space, keeping its column, and a value UTF-8
  cannot encode reads as U+FFFD, the same as `exportRows`.
- `readCellBuf(&buf, epoch, row, col)` is readCell without allocating: the
  text borrows a caller `Vt.CellBuffer`. It returns null for a grapheme too
  long for the buffer; read that cell with readCell.
- `changes()` returns `{generation, rows}`: for each active row, the
  generation in which it last changed. Rows that moved (scrolling) count as
  changed. It folds libghostty-vt's render-state row damage, creating that
  state on the first call, and consumes the terminal's dirty flags, so
  nothing else may. Any number of views can use it; generations are unique
  across all Vts.
- `exportRows(allocator, epoch, start, end)` exports physical rows in
  `[start,end)` as allocated UTF-8 with a newline after each row. Blank
  columns remain spaces, styles are omitted, and wide tails are skipped.
  Free the returned slice with the same allocator. It does not unwrap lines.
  It reads cells without allocating per cell, so bulk ranges are cheap.
- `screen()` returns `.primary` or `.alternate`: the screen whose rows
  `rows()` and `exportRows` address. The alternate screen (`?1049h`,
  `?1047h`, `?47h`) has no history, so `oldest == active` while it is active.

Absolute physical row addresses stay stable as old pages are pruned.
Pruned rows and wrong epochs return `StaleRows`, rather than substituting
new rows. Full reset, clearing retained history, switching primary/alternate
screens, and dimension changes start a new epoch. Edits that move the anchor
forward also invalidate the epoch conservatively. These are physical grid
addresses, not immutable logical-line identifiers. In-place text edits can
change content at an existing address.

`feed` batches printable ASCII at parser ground, bounded to one row's
width so the tracked anchor survives even a large input. Ground-state CRLF
pairs and non-wrapping printable CRLF lines are bounded row operations too;
horizontal margins disable the line optimization. Other controls, UTF-8,
and unfinished escape sequences are observed byte by byte. Reanchoring
after each chunk distinguishes pruning from history erasure, including
when one feed contains erasure and later output. Cell reads use Ghostty
grid references. Neither path should be polled on a frame timer; draw only
after changes. A future optimized render iterator can preserve the API.

### Snapshots

`snapshot(allocator)` returns an owning `{bytes, epoch, oldest, continuation_bytes}` Snapshot.
Release it with `snapshot.deinit(allocator)`. `Vt.restore(allocator, snapshot,
callbacks)` creates an independent owning Vt and copies/decodes state. It
retains no reference to the Snapshot, so the Snapshot may be freed immediately.
A failed restore leaves the original Vt unchanged.

Snapshots preserve styles, screens, history, cursor, terminal modes, and an
unfinished parser continuation. Continuation tracking is enabled before the
first input. If a sequence exceeds the configured continuation limit,
encoding can fail; callers must retry at a later usable boundary.

The bytes are an opaque, **unstable**, pinned Ghostty snapshot format.
The epoch, oldest-row and continuation-limit metadata must travel alongside
the bytes. Restore retains continuation tracking and compresses decoded history.
For streaming to clients use the pane-stream API below. There is no persistent
on-disk format. Only restore snapshots from a trusted peer using the same pin.
Do not use this decoder as an unrestricted upload endpoint.

### Streaming snapshots

This is the API behind venomx's pane stream (`SNAPSHOT`, `READY`,
`SCROLLBACK`). venom-term is the only code that reads ghostty snapshot bytes;
products see byte chunks plus row labels.

**Format names.** `Vt.ghostty_format` is the snapshot format name, e.g.
`ghostty/1@0fa3d577a561`: the envelope version and the first 12 hex digits of
the ghostty commit of the pinned libghostty-vt release (`Vt.ghostty_pin`;
1.0.0 is tag `vt-1.0.0`, set as `ghostty_commit` in `build.zig`). Snapshot
bytes are not covered by libghostty-vt's 1.x C ABI promise, so the commit,
not the release version, names the format. It is
derived at build time, so bumping the pin renames the format and mixed
builds fall back to `Vt.vt_format` (`"vt"`). Offer the ghostty format only
when the names match exactly.

**Encode (server).** `vt.streamSnapshot(allocator)` returns an owning
`SnapshotStream`; release it with `deinit(allocator)`. It is taken at once
(call it between feeds, on the pane's thread) and does not change as the Vt
moves on.

- `prefix`: the opaque bytes up to and including ghostty's READY record.
  Send them as `SNAPSHOT` chunks split anywhere.
- `ready`: `{epoch, oldest, top, active, cols, rows}` for the `READY` frame.
  `top` is the absolute row of the first row in the prefix (the active area
  plus any history sharing its first page). History is `[oldest, top)`.
- `nextHistory(max_bytes)` returns the next `HistoryChunk` `{bytes, end_row,
  rows, last}` or null after the last one. Chunks are split at record
  boundaries, newest first. Each covers absolute rows
  `[end_row - rows, end_row)`: the first has `end_row = top`, each next one
  `end_row` = previous `end_row - rows`. `bytes` borrows the stream. A chunk
  holds whole records up to `max_bytes`; one record larger than that comes
  alone, so `max_bytes` is a target, not a cap. The stream always ends with
  a `last` chunk (it carries FINISH and may have zero rows).
- Row counts come from each PAGE record's plain header without decoding
  cells, and only pages of the active screen count. With the alternate
  screen active, primary-screen history still flows (so the client can
  restore it) but carries 0 rows, and `top == oldest`.
- To honour `ATTACH.history`, stop calling `nextHistory` once `end_row`
  reaches the limit and send `LAST`. If the epoch changes mid-backfill, stop
  and send `LAST|ABORTED`.

**Decode (emulating client).**

```zig
var dec = try Vt.Decoder.init(gpa, .{}); // no write_pty: an emulating client never answers terminal queries
errdefer dec.deinit();
try dec.feedPrefix(snapshot_chunk);      // for each SNAPSHOT frame
var vt = try dec.ready(ready_frame);     // consumes dec; paint now
_ = try vt.feedHistory(scrollback_bytes); // for each SCROLLBACK frame
```

`Decoder.ready(meta)` checks that the prefix ends exactly at READY and
matches `meta`, then returns a live Vt whose `rows()` is
`{epoch, oldest = top, end, active}`. On success the decoder belongs to the
Vt; on failure the caller still owns it and must `deinit()` it.
`feed()` and `resize()` work between history chunks.

`vt.feedHistory(bytes)` returns the rows it added above the screen;
`rows().oldest` drops by the same amount, so the rows sit exactly at their
chunk labels. ghostty peeks at the record after a page before applying it,
so the final page of a chunk is applied when the next chunk arrives. After
the `last` chunk every row is applied, `rows()` equals the server's at
snapshot time (plus live output), and `historyPending()` is false. After an
epoch change, such as a resize, `feedHistory` returns `StaleRows` and stops.
`abandonHistory()` stops on `ABORTED` or on a `LAST` that came early. In both
cases the rows already restored stay. `Vt.deinit` frees any pending
decoder.

**`vt` replay (raw clients, pin mismatch).** `vt.vtSnapshot(allocator,
.{ .history = n })` returns an owning `VtReplay` `{bytes, unfinished,
history_rows}`. Write `bytes` to a freshly reset terminal of the pane's
size. It restores:

- the screen text with styles, wide characters, graphemes and OSC 8 links;
- the OSC 133 prompt rows (A at the start of each prompt row, `k=c` for a
  continuation, C after it), so `rowPrompt` on the replayed terminal agrees
  with the source; it is per row, not per cell;
- up to `n` primary history rows written first, oldest first, so they
  scroll into the host's scrollback;
- with the alternate screen active, the primary screen first and then
  `?1049h` and the alternate screen;
- cursor position, visibility, pending wrap and DECSCUSR shape, and the
  saved cursor (primary screen only);
- modes, including mouse, bracketed paste, focus and synchronized output;
- kitty keyboard flags and modifyOtherKeys;
- scrolling region, the title (OSC 2) and cwd (OSC 7);
- tab stops, OSC 4 palette entries and OSC 10/11/12 colours, but only the ones
  the program changed. A raw client forwards `bytes` to the user's terminal,
  which keeps its own values for everything else.

Kitty graphics are omitted.

`unfinished` is the number of input bytes since the parser was last at
ground (an incomplete escape sequence or UTF-8 character). The replay shows
the state before those bytes, so label it with pane offset
`current - unfinished` and start the first `PTY` frame there. One
known gap: a C0 control inside an unfinished sequence has already run, and
it runs again when those bytes are replayed. To keep this count, `feed()`
asks ghostty whether it is at ground after any byte that is not printable
ASCII at ground.

### Literal plain text

For durable archives, `Vt.PlainText` holds literal cell text: `cols`, `rows`,
`history` (oldest first) and `screen` (exactly `rows` rows). Each string is
one physical row of UTF-8 cell text, with no styles, controls, CR/LF or
width-zero continuation cells, rendered like `pane.capture` (blank cells and
tab stops are spaces). It is format-independent: no ghostty snapshot bytes.
`exportPlain` and `exportRows` never fail on what a pane wrote: the emulator
stores a DEL from the PTY in a cell, and a control character in a cell renders
as a space, keeping its column. A cell value UTF-8 cannot encode renders as
U+FFFD.

`vt.exportPlain(allocator, .{ .max_rows, .max_bytes })` exports the primary
screen and its history. While a full-screen program has the alternate screen
active, that screen is skipped and the primary screen underneath (with the
shell's history) is exported from a scratch copy; the live Vt is not
changed. Restore hydrates the primary screen, and the alternate screen is
transient program UI. Rows and bytes count screen and history together;
history is clipped by dropping its oldest rows first. It returns null (text
omitted) when a limit is zero or the screen alone does not fit. Free the
result with `deinit(allocator)`.

A row of printable ASCII costs about 0.3 µs to export and other text about
2 µs, or about 16 µs when clusters such as ZWJ emoji make its width hard to
guess. A row holding a DEL is read cell by cell at about 55 µs for 200 columns.
See [exportPlain cost](plain-export-cost.md) and [non-ASCII rows](plain-export-non-ascii.md).

`Vt.fromPlain(allocator, text, options)` creates a fresh reset Vt of that
size with the rows as literal cells: default styles, primary screen, cursor
home, autowrap on, row epoch 1 with `oldest = 0`. Before allocating anything
it rejects (`InvalidValue`) invalid UTF-8, any C0, DEL or C1 character (so
ESC, CR, LF and TAB too), a wrong screen row count, and inputs over
`max_rows`/`max_bytes` (capped at `plain_max_rows` = 100000 and
`plain_max_bytes` = 16 MiB) or with more history than `scrollback_lines`.
The wrapper then writes only the re-encoded printable characters, plus its
own line moves with autowrap off, so saved text cannot form an escape
sequence, query reply or OSC observation. Each row must read back
identically; a row too wide for `cols` or starting with a combining mark is
rejected. `options.callbacks` is installed only after hydration succeeds.
A failure frees everything. Streaming snapshots, history backfill and `vt`
replay of a hydrated Vt work as for any other Vt.


### Callbacks

`Options.callbacks` (or the callbacks passed to restore) contains a context
pointer and optional functions. Callbacks run synchronously during feed.
All strings are borrowed only for the callback duration; copy to retain.
Callbacks must not reenter any API on the same Vt.

- `write_pty(context, bytes)` carries terminal query replies in stream order.
  Wire this to the pane's serialized PTY writer so terminal queries work.
- `program_status(context, report)` receives validated OSC 7501 observations:
  state, kind, optional progress, id, app, title, message. `failed` represents
  the protocol's `error` state; `clear` requests record removal.
- `semantic_prompt(context, event)` receives OSC 133 prompt/input/output/end
  steps, prompt kind, optional exit code, decoded command and error message.
- `rowPrompt(epoch, row)` returns `none`, `start` (an OSC 133 A row) or
  `continuation` for any absolute row in `rows()`, scrollback included.
  `prevPromptRow(epoch, row)` / `nextPromptRow(epoch, row)` return the nearest
  `start` row strictly above / below `row`, or null. A client `Vt` built from a
  `ghostty/1` snapshot plus history, or from a `vt` replay, flags the same rows
  as the source. Each call walks to its row, so scanning a long
  history is linear per call.
- `bell(context)` fires once per BEL (0x07) in program output. A BEL that
  terminates an OSC or DCS string is not a bell. Plain-text hydration and
  snapshot restore never ring it.

Malformed supported sequences do not produce reports. Observations grant no
capability and never invoke a verb. The product owns record lifetime, event
conversion, grants, and JSON escaping. Clipboard and desktop effects are not
registered. Restoring a snapshot installs the supplied local callbacks; it
does not replay historical OSC observations.

## Surface: cells and writer presentation

`Surface.init(allocator, width, height)` creates an owned cell grid.
`put(x,y,cell)` copies text; `get(x,y)` borrows a cell until mutation/deinit.
`Cell` has text, width and Style. `Color` is default, palette index, or RGB.
Style supports foreground/background/underline colors, underline variants,
bold, dim, italic, blink, reverse, invisible and strikethrough.

`Region` is `{x,y,width,height}` in cells. `clear(region,style)` clips to the
surface. `text(region,value,style)` draws a single UTF-8 line by grapheme,
clips whole glyphs at the right edge, and owns its bytes. It does not wrap.
The low-level put API expects one grapheme per cell and consistent widths:
a wide head must have a following width-0 tail. Use text or VtView for
automatic placement. Regions can be used directly for pane composition;
border/list widgets are deferred until a consumer needs them.

`resize` preserves the overlapping rectangle and damages the full new grid.
`damage` is the union of changed cells, or null. `setCursor(?{x,y})` selects
the visible cursor; null hides it. A cursor change damages no cells but still
makes the next present run. Only the client decides which pane owns the
terminal cursor.

`present(io, environment_map, writer)` lazily creates the private libvaxis
renderer and writes a diff to any `*std.Io.Writer`. It never opens `/dev/tty`.
An unchanged surface skips rendering entirely and emits zero bytes. Only
the damaged rectangle is rewritten into the renderer, so a one-cell change
costs one cell. Damage is cleared after successful presentation. The renderer emits synchronized
output framing. Use one Surface per client terminal and compose all pane
regions into it. The caller owns raw mode, alternate screen, capability
negotiation, input buffering, resize events, and transport lifecycle.

## Input: normalized events

An `Input = .{}` parses caller-buffered bytes. `parse(bytes)` returns
`{consumed,event}`. Keep any unconsumed suffix and append more bytes. Empty
or incomplete input consumes zero bytes. Invalid UTF-8 can return an error;
the caller must discard invalid input to make progress. A lone ESC emits
immediately: apply the terminal's ESC timeout before parsing it if needed.

Key text borrows the caller's input or private parser scratch until the next
parse. Key fields include codepoint, optional text/shifted/base-layout
codepoints, modifiers, and press/release. Named navigation/F1–F12 keys have
Venom-owned values in `Input.NamedKey`; compare using `@backingInt`.
The pinned backend cannot distinguish repeat from press. Other backend
function keys are outside v0's named-key set.

Mouse events contain zero-based cell coordinates, action, button, and
modifiers. Focus, mouse leave, bracketed paste boundaries, and in-band resize
are normalized too. Capability reports are consumed internally. OSC clipboard
paste is ignored; callers own bracketed-paste text assembly.

Call `beginProbe()` before sending startup probes; the DA1 reply ends probing,
or call `endProbe()` explicitly on timeout. During this interval unmodified
F3 presses are discarded to filter the CPR ambiguity found in the [libvaxis spike](spikes/libvaxis.md). Real
F3 presses in the probe window can also be discarded. Afterwards F3 works.

## VtView: per-client viewport

A `VtView = .{}` follows the active area's top row. `scrollTo(vt,absolute_row)`
sets a fixed top row in that terminal's current epoch; `follow()` resumes
following. `draw(vt,surface,region)` copies visible cells and styles into the
region, clearing uncovered cells and clipping incomplete wide glyphs.
`drawChanged(vt,surface,region)` is the incremental form: when the
view's previous draw followed the active area of the same Vt, epoch, size
and region, it rewrites only the rows `Vt.changes()` reports changed since;
otherwise it draws in full. The caller guarantees the region on the surface
still holds that previous draw (nothing was drawn over it since).
Both `draw` and `drawChanged` call `Vt.changes()`, so nothing else may
consume libghostty-vt's dirty flags (for example its render state) on a Vt
that a VtView draws.

Two clients can draw the same Vt with independent scroll positions. Drawing
never changes Ghostty's shared viewport or dimensions. Epoch changes or
pruning past a fixed top row resume follow mode. The product owns selection,
scroll gestures, pane geometry, cursor mapping, and resize authority.

### Host color query defaults

`Vt.setQueryColors(.{ .fg = ?[3]u8, .bg = ?[3]u8, .cursor = ?[3]u8 })`
sets local host RGB defaults for OSC 10/11/12 query replies. Null components
use the terminal's own defaults. Program-set OSC colors take precedence;
OSC 110/111/112 resets return queries to the host defaults. The values are
copied, so the caller retains no storage or callback lifetime obligation.
Serialize this call with other Vt access. It emits nothing.

Host defaults are installed only during `feed` and restored before it
returns. They do not recolor cells or alter snapshots or VT replay output.
Application OSC overrides remain terminal state and are serialized normally.
Query defaults are local policy and are not restored from a snapshot; set
them separately on a restored terminal if needed. Clients without a
`write_pty` callback still produce no replies.

## Pane-stream client

`pane_stream.PaneStream` is the client side of a venomx pane stream: the
handshake, snapshot decoding, `PTY` contiguity, resync, resume, backfill and
its recovery, and the size and input rules. It owns the pane's `Vt`, and a
program that shows a pane draws that `Vt`. It uses only the `vt` module, so a
headless program can have it too:

```zig
const term = b.dependency("venom_term", .{ .target = target, .optimize = optimize });
app.addImport("pane_stream", term.module("pane_stream")); // or term.pane_stream
```

Take `vt` and `pane_stream` from the same `b.dependency` result, or `Vt` is two
different types.

**No transport.** It never touches a socket. Give every S→C frame of the stream
to `handle(kind, payload)`, and send what collects in `outbox`:

```zig
var s = try PaneStream.init(gpa, "p3", stream_id, .{ .cols = 80, .rows = 24 }, history);
defer s.deinit();
try s.attach(null);
// for each frame received on stream_id:
s.handle(frame.kind, frame.payload) catch |err| switch (err) {
    error.OutOfMemory => return err,
    else => try s.requestResync(.decode), // or end the stream
};
// after each batch, once the connection can take more:
try s.flush(conn, sendFrame); // fn (@TypeOf(conn), u32, pane_stream.Out) anyerror!void
try s.recoverBackfill(now_ms);
if (s.generation != drawn) redraw(s.vt); // null until the first READY
```

`flush` removes each frame before freeing it, so if `send` fails the stream
still owns exactly the frames not yet sent. `Kind` holds the frame numbers
(`Kind.err` and `Kind.close` are the wire protocol's core frames), and `capability` is
the `HELLO` capability string, `venomx.pane_stream`. The caller checks that it
was negotiated and picks the odd stream IDs.

**Calls.**

- `attach(resume)`, `reattach(new_id)`: `reattach` is for a new connection. It
  drops the unsent frames and asks to resume when the stream was live, keeping
  the `Vt`. The server's answer decides: `resumed: true` continues, and
  `resumed: false` is a normal snapshot.
- `input(bytes)`: queues `INPUT`, already encoded (see
  [Pane input encoding](#pane-input-encoding)). It is dropped unless
  `writer` is true and the stream is past `ATTACHED`.
- `viewport(size)`: queues `RESIZE` for a writer whose viewport changed. A
  viewport that changes during the handshake is reported after `ATTACHED`.
- `requestResync(cause)`: asks for a fresh snapshot. The screen stays until the
  next `READY`, and a second request while one is out does nothing.
- `recoverBackfill(now_ms)`: call it once per transport turn. After history was
  lost it sends one `RESYNC` with `claim: false`, once the epoch and both sizes
  have held still for `backfill_settle_ms`, and never on the alternate screen.
  `recoveryDeadline()` says when it must run next.
- `pendingRows()`: the rows `[low, high)` still expected as `SCROLLBACK`, to
  draw as loading.
- `detach()`: queues `CLOSE` and closes locally, with `closed` = `"detached"`.

**State to read.** `phase`, `vt`, `writer`, `pane_size`, `backfill`, `exit`,
`closed` (the `CLOSE` reason or the `ERROR` code), `offset`, `resyncs`,
`last_resync`, `recovering` and `generation`. The fields `history`, `claim`,
`formats`, `mode` and `passthrough` are set before `attach`.

**Raw passthrough.** A single-pane client can make the host terminal the
emulator: set `mode = .raw`, `formats = &.{.vt}` and a `Passthrough`
before `attach`. The stream then calls `begin` before each snapshot replay and
`feed(bytes, clipboard)` for replay and `PTY` bytes, and it creates no `Vt`. The
required output filter is the caller's, behind `feed`, as are host modes and
restoring the terminal on exit. If the pane's size and the viewport differ, the
stream falls back to emulating on a `vt` snapshot; `mode` tells you when
it has. An emulating stream never calls a `Passthrough`, and a raw stream
without one fails with `error.NoPassthrough`.

## Widgets v0

`term.widgets` holds the building blocks for product TUIs (venom, later
venom-desk), so products never draw with libvaxis themselves. Every widget
draws into a `Surface` region and takes `Input.Key`s (and, where it makes
sense, `Input.Mouse` events); none touches a TTY, so
tests render into a Surface and read cells back (`widgets.text.rowText`).
Widgets keep only view state (cursor, scroll); the caller owns the data.

| Piece | What it does |
|---|---|
| `Theme`, `Role` | Styles by role (`normal`, `secondary`, `muted`, `faint`, `accent`, `ok`, `warn`, `err`, `info`, `border`, `border_focus`, `title`, `title_focus`, `selection`). Build one with `theme.Chrome.widgets()` (see [Theme](#theme)); `Theme.default` is `trve`, venom edition, ANSI 16, so the terminal or venomx theme picks the colours. Products may replace any field. |
| `layout` | `split(region, .horizontal \| .vertical, constraints, out)` with `fixed`, `percent` and weighted `fill` parts; `splitN`, `sideBySide`, `stacked`, `inset`; `hit(region, x, y)` maps a screen cell, such as a mouse position, into a region. |
| `box.draw` | `none`, `single`, `rounded`, `heavy` borders (the shared chrome border styles), a title, a right-aligned badge, focus and role override; returns the inner region. |
| `text` | `Span` (text + role + optional style), grapheme widths, `wrap` (word wrap across spans; hard newlines; long words split by grapheme), `drawSpans`/`drawText` with ellipsis, overlay and fill. |
| `GroupedList` | Groups with fold state and one- or two-line items (glyph + role, title, right meta, detail line; bold for unread), as the venom agent list shows them. Keys: ↑↓ j k, Home/End, PgUp/PgDn, Enter/Space, ← → h l. `handleKey` returns `moved`, `toggled` or `activated`. `handleMouse`: the wheel moves the cursor, a click selects a row, clicking the selected item again activates it, and clicking a header folds it. `entryAt(groups, row)` maps a row to an entry. |
| `ScrollView` | Wrapped `Block`s with follow-the-tail (scrolling up stops it, reaching the bottom resumes it), collapsible blocks with `▸`/`▾` and a preview, `n`/`p` select, Enter toggles, `E`/`C` all (the venom transcript view). `handleKey` returns `scrolled`, `selected`, `toggled` or `toggled_all` as the product's hook; `blockAt(row)` maps a row back to its block. `handleMouse`: the wheel scrolls `wheel_step` lines, a click on a collapsible block's first line toggles it, and a click on its other lines selects it. |
| `TextInput` | Single- or multi-line, grapheme-aware editing, readline keys, history with draft restore, prompt and placeholder, horizontal or vertical scroll, terminal cursor placement. `handleKey` returns `edited`, `moved` or `submit`; `submit()` returns the text and records history. |
| `leader_popup` | The leader popup: `place` and `draw`. See [Leader popup](#leader-popup). |
| `FocusRing`, `keys` | Tab/Shift-Tab focus between widgets, `handleMouse(mouse, regions)` for click-to-focus (it returns the index hit), and key matchers (`named`, `char`, `ctrl`, `alt`). Widgets return null for keys they don't use, so a product routes: focused widget first, then its own bindings, then the ring. |

Mouse handlers hit-test against the region of the widget's last draw (`area`), so draw before routing events, and they ignore events outside it. A product can offer every event to each widget, or route by `layout.hit(region, x, y)`.

`ScrollView` caches wrapped lines per block ([design](scroll-cache.md)) and re-wraps a block only when its width, its spans slice, a span's text slice or `Block.revision` changes. Bump `revision` after rewriting span bytes in place. `wraps` counts block wraps and `scans` block key compares. Each frame compares every block's key, which is O(blocks). A product that knows only the tail changed can call `assumeUnchanged(prefix)` before the draw, promising that blocks `0..prefix` are unchanged since the last layout, and the frame then costs O(new blocks). The promise is optional and lasts for one layout, so leaving it out is always correct. A width change, `toggle` and `handleKey` override it; `setAll` can't, so don't promise past a block it changed. A broken promise panics in Debug and ReleaseSafe, and in ReleaseFast can draw stale lines or read out of bounds. See `docs/scroll-cache.md` for the design and the 10k-block benchmark (`zig build bench-scroll`). The view owns the cache: call `deinit(gpa)`. `TextInput.init(gpa, opts)` pairs with `deinit()`.
`zig build example-widgets` runs the demo in `examples/widgets.zig`; its
`App` is also driven headlessly by raw key and SGR mouse bytes in `zig build test`.

## Chrome: shared presentation-client logic

`chrome` is what every venomx presentation client (`venomx attach`,
venom-desk) runs the same way: pane tags and `when` matching, key tables
and the leader state machine, the status-line layout, and the environment
of `exec` binding children. It is pure and
headless (no daemon calls, no TTY, no renderer), so it is a separate module
that also builds with `-Dheadless=true`, and `venom-term` re-exports it as
`term.chrome`:

```zig
const term = b.dependency("venom_term", .{ .target = target, .optimize = optimize, .headless = true });
client.addImport("term_chrome", term.module("chrome"));
```

| Piece | What it does |
|---|---|
| `tags` | `Tag`, the owned sorted `Tags` map (`put`, `get`, `remove`, `clone`, `same`, `matches(when)`, `fromValue` for both wire shapes), `validKey`, `validValue`, `validText`, `max_tags`. |
| `keys` chords | `Chord`, `parseChord` (Kitty names: `ctrl+space`, `alt+shift+left`, `%`, `ctrl++`), `fromKey` (an `Input.Key` with legacy and Kitty input compared equal; `Input.parse` has already made ESC ^A Ctrl+Alt+`a`), `formatChord`/`chordText`, `Sequence`/`parseSequence` (1–4 keys), `legacyDeliverable` (true for a Ctrl chord exactly when `fromKey` gets it back from its bytes, so not `ctrl+h`, `ctrl+i`, `ctrl+m`, `ctrl+[`, `ctrl+?`), `legacyByte`. Named keys use `Input.NamedKey` values. |
| `keys` placeholders | `placeholders`, `placeholder`, `spliced`/`splicedValue` (a placeholder inside a longer string is refused), and `Placeholders` (whole-element substitution in argv and verb args). |
| `keys` config | `BindingConfig`, `GroupConfig`, `TableConfig`, `PrefixConfig` (the ZON and JSON records), `Settings` (the parsed scalars `leader`, `unlock`, `popup_delay_ms`, `timeout_ms`; a client sets them from its config, because the first, second and last still default to `ctrl+space`, `ctrl+alt+space` and 2000), `LayerConfig` and `parseLayerConfig` (the `keys` member of one config file, for each of the defaults and user layers; a field name unknown anywhere under `keys` fails with `reason` `unknown_field` and its path as `param`, such as `keys.tables.0.lable`, and other top-level sections are ignored), `validLabel` (1–40 bytes, no control characters), `Group`, `group` (a compile-time built-in group). |
| `keys.prefixes` | `parsePrefixes` (one layer's entries; a repeated name fails), `mergePrefixes(defaults, user)` (the user's entry wins per name), `effectivePrefix(moves, name, registered)`. A table with no sub-prefix never moves. |
| `keys.Tables(Local, hooks)` | A product's tables over its own local commands: `Target` (`local`, `verb` + JSON args, `exec` argv; `eql`, `name`), `Binding` (`label`, `text()`), `Table` (`label`, `groups`), `binding` and `labeled` (compile-time built-ins), `parseBinding`, `parseTable`, `applyPrefixes`, `resolve` (user > defaults > product > builtin by name, sub-prefix and overlapping sequence; same-layer `conflicts`, cross-layer `shadowed`; `when` through an `Active`), `Resolved.lookup`/`next`/`group`/`path`/`prefixTable`, `tableJson`/`tableFromJson` (the `keys.list` form, with labels and groups), `groupConfigsFromJson`. `hooks` names locals and checks verbs. |
| `keys.Tables(…).Router` | Per-client leader, lock and timeout: `feed(settings, tables, active, chord, now)` returns `pass`, `leader`, `partial`, `send_leader`, `run`, `unlocked`, `unbound` or `overflow`; `chordOf(settings, cp, mods, shifted, text, base_layout)` is the chord to feed for a host key: `fromKey`, falling back to an ASCII Kitty base-layout key for a non-ASCII character unless that character is the leader, the unlock key or a binding at this level; `lock`, `tick`, `nextDeadline`, `end`, `modeText` (`LEADER`, `LEADER <table>`, `LEADER <group>` in a sticky group, `LOCK`), `next` and `path` for the popup, `stickyGroup`, `popupHidden`. |
| `leader_popup` | What the popup shows and when: `Row`, `Model`, `rows`, `keyText`, `title`, `model`, `Leader`, `Timer`. See [Leader popup](#leader-popup). |
| `status` | `Side` (`left`, `center`, `right`), `Style`, `Level`, `NotifyLevel`, `glyph`, `levelStyle`, `notifyStyle`, `AttentionConfig`. Status-bar config: `Config` (`position`, `left`/`center`/`right` lists defaulting to `default_left`/`default_right`, `unlisted`, `segments`; `segment(id)`, `format(id)`, `listed(id)`, and `check`, which reports `status_layout`, `segment` or `template` with the template's offset), `Segment` (slot fields, plus one source: `text`, `format` (with `panes`), `rule`, `exec`, `group_of`), `Click`, `Rule`, `Exec`, `validGroup`, `validIcon`. `Builder` (`config`, client `toggled` ids; `add`/`addSegment` take product segments with optional `group`, `icon`, `group_of`; `addConfigured(lookup)` adds the config's `user.*` static, template and group sources; `items()` applies slot overrides, `.show`, the lists, `.unlisted`, glyphs, and fills groups, dropping empty ones). `layout` (drops by priority across all three sides together, groups drop their lowest-priority members first, only the first item that doesn't fit is truncated with `…`; sides draw in list order, the centre at the middle and pushed sideways to keep one blank column from either side), `hit(placed, col)` (segment or group member under a click), and `render` (plain text). |
| `status.template` | Status templates: `parse(a, source, kind)` → `ok: Template` or `failed: Failure{offset, reason}` (`invalid_params.template`), `check`, `isVariable(name, kind)` (the closed table; `event.*` only for `kind = .rule`), `render(a, template, lookup)` and `renderSource` (output cleaned of C0, DEL, C1 and bidi controls and capped at 256 bytes), `Lookup` (caller-supplied `get(name)` plus `clock_now`), `pairs`, `Clock` (`fromEpoch(seconds, utc_offset)`, `format` with `%H %M %S %d %m %Y %y %a %b %p %%`), `clean`. |
| `exec_env` | The environment of a key binding's `exec` child: `withheld(entry)` (no `=`, `VENOMX_TOKEN`, `VENOMX_PRINCIPAL`, or a value `credential` flags) and `childEnviron` (a `NAME=value` slice minus withheld entries). Also the token-shaped pattern (`Token`, `findToken`, `containsToken`) and credential table (`credential(name, value)` → `"credential"`, `"owner_credential"` or null), which the venomx daemon re-exports for its spawn environment. |

### Labels, groups and the next-keys lookup

Tables and bindings take `.label`, and a table takes `.groups` to name its
inner prefixes. A group's `.key` is relative to the table's prefix, its `.label`
is required, and it must have a binding under it. `parseTable` rejects a bad
label, a group with nothing under it, a repeated group and a key leader mode
would take first (`backspace` anywhere, `esc` before the last key).

```zig
const t = try K.parseTable(a, .{
    .name = "venom",
    .prefix = "v",
    .label = "venom",
    .groups = &.{.{ .key = "a", .label = "agents" }},
    .bind = &.{
        .{ .key = "a s", .label = "stop", .exec = &.{ "venom", "agent", "stop", "--pane", "{pane}" } },
        .{ .key = "s", .label = "settings", .verb = "pane.popup" },
    },
}, .product);
```

`Router.next` and `Resolved.next` return one `Next` per key, so a popup draws
from it with no further lookup:

| `Next` field | Meaning |
|---|---|
| `key` | The chord (`chordText` prints it) |
| `more` | More keys follow: draw `+` |
| `label` | A binding's label, else its local action, verb or `argv[0]`. A `more` row has the group's label, the table's label or name, or `…` for an inner prefix no group names |
| `sticky` | A `more` row that opens a sticky group |
| `entry` | The first entry reached, with its table and binding |
| `sameRow(other)` | Same target and label, so they share a row (`h ←  focus left`) |

`Router.path` gives the header, one name per key typed, and the client puts its
own name in front (`venomx › venom › agents`).

### Leader mode

In leader mode every key is swallowed, and `feed` never returns `pass`.

| Key | What happens | `feed` returns |
|---|---|---|
| A bound key | Runs; leader mode ends, unless a sticky group holds it | `run` |
| An inner prefix | Goes down a level | `partial` |
| `esc` | Leader mode ends, from any level and from a sticky group. A binding for `escape` at this level runs as it ends, which is how a client clears its selection | `unbound`, or `run` if bound |
| `backspace` | Up one level; out of leader mode from the root | `partial`, `leader` at the root, `unbound` from the root |
| An unbound key | Leader mode ends, also in a sticky group | `unbound` |
| The leader, at the root | Sends the leader to the pane | `send_leader` |
| `?`, unbound, in a sticky group | Shows the popup again; the client stays there | `partial` |

- **`unbound` means cancelled.** It holds what was typed, that key last, and
  needs no message: the key only has to be swallowed.
- **`timeout_ms = 0` means no timeout.** `tick` never ends leader mode and
  `nextDeadline` is null, so an event loop need not wake for it. A non-zero value
  restarts on every key, sticky bindings included.
- **Sticky groups.** After `run`, `pending()` stays true, `stickyGroup()` names
  the group, `modeText` is `LEADER <group>`, and `popupHidden()` is true until
  `?` or a move to another level. A binding in a plain group nested inside a
  sticky one returns to the sticky level. The binding pointer stays valid for as
  long as the tables do; end the router before replacing them.

`popup_delay_ms` is in `Settings` for the popup's `Timer`, and the router does
not read it.

### Leader popup

`venomx attach`, venom and venom-desk draw the same popup. It has two halves:
`chrome.leader_popup` is headless and says what it shows and when, and
`widgets.leader_popup` draws that on a `Surface`.

```zig
const popup = term.chrome.leader_popup;
var timer: popup.Timer = .{};

// After anything that can change the router (`feed`, `tick`, `end`, `lock`,
// `begin`), and when `timer.nextWake()` passes. Once per loop turn before drawing
// is simplest:
_ = router.tick(now);
const out_of_date = timer.sync(.of(&router), settings.popup_delay_ms, now);

// In the event loop, wake for the earliest of these. Both are null when nothing
// is waiting, so an open popup costs no wakeups.
const wake = [_]?i64{ timer.nextWake(), router.nextDeadline() };

// In the frame, after the panes and from a per-frame arena:
if (timer.visible()) {
    const model = try popup.model(arena, "venomx", &router, .{ .key = settings.leader, .label = "send-leader" });
    const covered = try term.widgets.leader_popup.draw(&surface, pane_area, &theme, model, .{});
}
```

**When it is up (`Timer`).** Times are the router's clock, in milliseconds.

| What happens | Popup |
|---|---|
| The leader or a prefix key, popup down | Up `popup_delay_ms` later; at once for 0. Another key first restarts the wait or ends it, so it is never drawn |
| A prefix key or `backspace`, popup up | Stays up, showing the new level at once, so reading down a tree does not flicker |
| A sticky group's binding runs | Down, and it stays down for later bindings |
| `?` in a sticky group, popup hidden | Up at once, with no delay. During the first wait, `?` changes nothing and the wait finishes |
| `backspace` out of a hidden sticky group | Up after the delay |
| Leader mode ends, by a key, `tick`, `end` or `lock` | Down, at the next `sync` |

A `Timer` holds no router, so it learns of a change only through `sync`. Leader
mode can end with no key (`tick` on `keys.timeout_ms`, `end` on a keymap reload);
without a `sync` the frame would still draw the popup while keys go to the pane.
Extra calls change nothing, and it reads only the router's state. It returns true when the frame is out of date: draw again what the popup covered
(a smaller or absent popup uncovers cells), then the popup if `visible()`.

**What it says (`model`).** `Model` has `title` and `rows`, built from
`Router.next` and `Router.path`, so `rows` keeps their order: key-table precedence,
and table order within a table.

- **Header.** `client › table › group`. `client` is who draws it, so a product's
  popup names the product and can't pass for the client's.
- **Rows.** `Row` has `keys`, `more` (draw `+`) and `label`. Bindings with the
  same target and label share the first one's row (`h ←  focus left`). `keyText`
  shows arrows as glyphs and `escape` as `esc`, and keeps modifiers (`ctrl+←`).
- **A bound `escape` is a row like any other** (`esc  clear-selection`), because
  it does run. To leave one out, filter the `Next` slice and call `rows`.
- **The leader's own row.** `Router.feed` handles the leader at the root without
  a binding, so a binding on the leader's key can't run there and `model` gives it
  no row. What the key does belongs to the client: `Leader.label` adds a row after
  the tables' rows at the root (`send-leader` in venomx, the switcher in venom),
  and null adds none.

Headless cores can test `Model` and `Timer` through the `chrome` module.

**How it draws (`widgets.leader_popup`).** `draw(surface, area, theme, model,
opts)` draws at the bottom-left of `area` and returns the region it covered.
Pass the terminal less any status line. `place(area, model, opts)` returns the
same layout with no drawing, for a client that must know what is covered before
it patches panes row by row.

- **Size.** The box fits its content and header, up to `area`. It uses the fewest
  columns of at most `opts.max_rows` rows (default 6). If the width doesn't allow
  that many, it uses as many as fit and goes taller.
- **Too small.** The rows that fit, in order, then `…` in the last slot. One
  column always fits: its labels are cut with `…`. Under 3 rows or 6 columns there
  is no border or header. A label takes at most 40 columns, which matters for an
  unlabelled `exec` showing a long `argv[0]`.
- **Overlay.** It takes no focus and changes no pane. It hides the terminal cursor
  if that is under the popup, and blanks a wide glyph its edge cuts. `VtView`'s
  `drawChanged` needs an untouched region, so draw covered panes in full.
- **Cost.** Drawing happens only in a client's frame, and redrawing an unchanged
  popup adds no damage, so `present` writes nothing. `zig build bench-popup
  -Doptimize=ReleaseFast` measures it.

### Moving a prefix

`keys.prefixes` is config, not table state, so apply it to the current tables
whenever they change, and a move survives a registrar replacing the table:

```zig
const defaults = (try keys.parseLayerConfig(arena, defaults_bytes)).ok; // `config check` reports `.failed`
const user = (try keys.parseLayerConfig(arena, user_bytes)).ok;
const moves = try keys.mergePrefixes(arena, (try keys.parsePrefixes(arena, defaults.prefixes)).ok, (try keys.parsePrefixes(arena, user.prefixes)).ok);
const tables = try K.applyPrefixes(arena, registered_and_config_tables, moves);
const resolved = try K.resolve(arena, tables, active); // table precedence on the moved prefix
const reported = try K.tableJson(arena, &tables[i]); // `keys.list` reports the effective prefix
```

Tests cover the key-table conformance cases at the module level, including the
exec environment (`exec_env`): no venomx token or principal, and no
credential-looking value. They also cover each behaviour above, including a
prefix moved by `keys.prefixes` surviving a replaced table.

## Theme

`term.theme` holds the brand colour tokens (`src/brand/tokens.json`) as typed data, so products draw chrome by role and never hard-code a colour.

```zig
const theme = term.theme;
const chrome: theme.Chrome = .{ .theme = &theme.trve, .edition = .venomx, .mode = theme.Mode.detect(env) };
try surface.text(bar, " main ", chrome.sessionBlock());
const mark = chrome.statusMark(.warn); // "▲" in gold
const roles = chrome.widgets(); // widgets.Theme for box, list, scroll, input
```

| Name | Meaning |
|---|---|
| `Theme` | One brand theme: `void`, `crypt`, `grave`, `ash`, `rule`, `rule_strong`, `bone`, `bone_dim`, `muted`, `faint`, the signals and their `on_` colours (`blood`, `ember`, `lichen`), `verdigris`, `gold`, `frost`, the status roles `ok`, `warn`, `danger`, `info`, `focus`, and `ansi: [16]Rgb`. Each role is a `Swatch`: its exact RGB and its ANSI fallback. |
| `trve`, `bone`, `byName` | The built-ins: `trve` (dark, default) and `bone` (light). A test compares them with `src/brand/tokens.json`. The logo-only tokens (`logo-ink`, `logo-venom`, `logo-venomx`, `logo-venom-os`) have no role, on purpose: they are for the logo files only. |
| `Edition` | `venom` (blood), `venomx` (ember), `venom_os` (lichen): `signal(theme)` and `onSignal(theme)`. |
| `Mode` | `ansi16` or `truecolor`; `Mode.detect(env)` reads `COLORTERM` (`truecolor` or `24bit`). RGB is used only in `truecolor`. |
| `Status`, `Mark` | `ok` ●, `warn` ▲, `danger` ✕, `info` ◆, `idle` ○ (muted). `chrome.statusMark(status)` returns the glyph and its style. |
| `Chrome` | A theme resolved for an edition and a mode: `color(swatch)`, `ansi(i)`, `signal()`, `text(swatch)`, `fill(ground, on)`, `focusedBorder()`, `inactiveBorder()`, `statusBar()`, `sessionBlock()`, `mutedText()`, `faintText()`, `statusMark(status)`, `widgets()`. |

Without truecolor, a role falls back to the ANSI colour with the same meaning in the brand palette (red is blood, bright black is dim output), not the RGB-nearest entry, which would put `muted` on cyan. The ground and the primary text keep the terminal's default colours, and a coloured fill such as the session block is drawn as reverse video, so its text takes the terminal's background, as the `on-` tokens intend. `bone`'s fallbacks assume a light terminal with a conventional palette.

## Pane input encoding

The headless `Vt` now accepts the same backend-independent key and mouse
values as the host `Input` parser. `Vt.Input.Key`, `Mouse`, `Modifiers`,
`NamedKey`, and `Keypad` are shared with the full module's `Input` aliases.

- `inputModes()` reads current `cursor_application`, `keypad_application`,
  `bracketed_paste`, `mouse_tracking`, `mouse_pixels`, and `kitty_flags`
  from the emulator. Kitty flags use the protocol's bits 0–4. The effective
  mouse pixel format is queried through a temporary backend encoder because
  the C mode getter exposes DEC bits, which can differ from the active format
  after competing format changes. This uses Vt's allocator and changes no
  emulator state.
- `encodeKey(allocator, key)` returns owned PTY input bytes for the current
  legacy/DECCKM, keypad, modifyOtherKeys, or kitty keyboard state. Press,
  release and repeat actions are supported; releases are suppressed unless
  the pane's kitty flags request them. Named keys use `Input.NamedKey`.
- `encodeMouse(allocator, mouse, geometry)` filters events using the current
  tracking mode and encodes its selected X10, UTF-8, SGR, URXVT or SGR pixel
  format. Coordinates are zero-based **pane-relative cells**, after the
  caller subtracts its pane rectangle. `.drag` means a button is held;
  `.motion` means no button is held. The caller handles focus, force-local
  selection, scrolling and motion deduplication. Vt retains no mouse state.

Free every returned slice with the supplied allocator, even when empty.
Temporary backend objects use Vt's allocator and are freed before return.
These APIs do not write PTY bytes, invoke `write_pty`, or change terminal
modes. A caller sends the result as INPUT only when it has the write role.
Modes follow live output, resize, reset and snapshot restoration; clients
must not maintain a second escape-sequence parser for pane modes.

The client enables bracketed paste on the host, collects paste as literal
bytes, and adds `CSI 200 ~` / `CSI 201 ~` only when `bracketed_paste` is true.
Paste content must bypass keybindings and key encoding.

`MouseGeometry` defaults suffice for cell formats. Pixel mode requires
nonzero `cell_width` and `cell_height`; otherwise encoding returns
`Unavailable`. Optional `.pixel = .{ .x, .y }` supplies a precise zero-based
pane pixel position. Cell-only host reports use the cell's top-left pixel.
The wrapper corrects the pinned backend's pixel ordinates to one-based wire
coordinates. Negative or out-of-pane cell/pixel coordinates and zero cell dimensions
return `InvalidValue`; subtract borders before calling.

`Key.text` is borrowed for the duration of encoding. Its printable UTF-8 is
preserved, including associated kitty text. C0 parser text is replaced by
the logical codepoint so the encoder derives Ctrl bytes. `shifted` supplies
shifted text when no printable text exists. An ASCII `base_layout` supplies
the corresponding physical key for kitty alternate codes. Optional `keypad`
records explicit keypad identity; the parser preserves supported kitty
keypad digits/operators and repeat events. Legacy host bytes do not reveal
physical keypad identity or distinguish repeat from press, so these are
never guessed. Host keyboard protocol negotiation remains the client's job.

The pinned backend cannot represent Hyper/Meta modifiers; these return
`Unavailable` rather than dropping the modifier. Arbitrary non-ASCII
physical layout identities, standalone shifted alternates without Shift,
modifier-side identity, and named keys beyond `NamedKey`/`Keypad` cannot be
recovered through this API. An unidentified mouse `.extra` button also
returns `Unavailable`. Frontends requiring those details need a richer
normalized event/backend mapping.
