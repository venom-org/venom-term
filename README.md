# venom-term

A thin, stable Venom terminal API that wraps **libvaxis** (TUI rendering and input) and **libghostty-vt** (VT emulation). Products use venom-term and never import those libraries directly.

Part of [Venom](https://venom.tools). Status: **alpha**; interfaces may still change. Documentation: [venom.tools](https://venom.tools).

Build from source with the Zig version in `.zigversion` (see [API v0](#api-v0) for the build and test commands), or add it to your project as a Zig package and import its modules.

Licensed under the [MIT License](LICENSE). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Pinned dependencies

Known-good commits, per Zig version.

| Dependency | Zig | Commit | Notes |
|---|---|---|---|
| libghostty-vt (`ghostty-org/ghostty`) | 0.17.0 | **1.0.0** release tarball, tag `vt-1.0.0` = `0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec` (2026-11-06) | Stable C ABI across 1.x; use the C API (`ghostty/vt.h`, `ghostty-vt-static`), not the Zig module. The commit is set in `build.zig` next to the version (the tarball URL has none). See the [libghostty-vt spike](docs/spikes/libghostty-vt.md). |
| libvaxis (`rockorager/libvaxis`) | 0.17.0 | `c1861acc835e42d6874f2b15744f472398fbdfb7` (2026-11-05) | `0.6.0` on `main`; upstream, no patches. Filter the startup phantom F3. See the [libvaxis spike](docs/spikes/libvaxis.md). |

## API v0

See the [API and ownership guide](docs/API.md). Products import `venom-term`
for `Surface`, `Input`, `Vt`, and `VtView`; headless daemons import the separate
`vt` module with the `headless` build option. Both use Venom-owned types.
The presentation-client logic shared by venomx clients (key tables, tags, status
layout) is the headless `chrome` module, also `term.chrome` ([guide](docs/API.md#chrome-shared-presentation-client-logic)).
The venomx pane-stream client is the headless `pane_stream` module, also
`term.pane_stream` ([guide](docs/API.md#pane-stream-client)).

```sh
zig build
zig build test
zig fmt --check .
zig build -Dheadless=true
zig build -Doptimize=ReleaseFast
zig build -Dghostty-optimize=debug  # Debug libghostty-vt (slow; default is ReleaseSafe in Debug builds)
python3 test/measure_idle.py
```

Pane streaming (`streamSnapshot`, `Vt.Decoder`, `feedHistory`,
`vtSnapshot`, and the `ghostty/1@<pin>` format name) is documented in the
[API guide](docs/API.md#streaming-snapshots).
Literal plain-text export and hydration (`exportPlain`, `fromPlain`)
is documented in the [API guide](docs/API.md#literal-plain-text).

The test suite includes a separate headless consumer and replays Surface
output through Vt. CI checks formatting, builds and runs the tests with the Zig version in `.zigversion` on every pull request and push to `main`.
See the [render and idle measurements](docs/measurements-render-idle.md) for rendering/idle cost.
Debug builds compile libghostty-vt as ReleaseSafe, because its Debug integrity
checks make short-line feeds ~3000x slower; see [debug feed throughput](docs/debug-feed-throughput.md).

## Example: widgets

`zig build example-widgets` shows widgets v0: a grouped agent list,
a wrapped transcript with collapsible tool calls, and a multi-line input box,
laid out like the venom main view. Tab or a click moves focus, the wheel
scrolls the pane under the pointer, and Ctrl-C quits. Source:
[examples/widgets.zig](examples/widgets.zig); see the
[API guide](docs/API.md#widgets-v0).
`zig build bench-scroll -Doptimize=ReleaseFast` times the transcript view on
10k blocks; see [the scroll cache notes](docs/scroll-cache.md).

## Example: two PTY panes

`zig build example-panes` runs two shells side by side in bordered panes,
built only on the public API. Ctrl-A o switches focus, Ctrl-A q quits, and
resizing follows the terminal. OSC 7501 and OSC 133 observations are logged
to stderr (`2>panes.log`). Source: [examples/panes.zig](examples/panes.zig).

Measured with `python3 test/measure_panes.py 100000` (ReleaseFast, 200×50,
2026-11-06, Linux x86_64). Details in the [two-pane measurements](docs/measurements-two-panes.md).

| | |
|---|---|
| Idle CPU, two shells at a prompt | 0 ticks over 5 s, no output |
| `cat` of a 7.5 MB file, Enter until end marker is on screen | ≈0.46 s (≈15 MiB/s; bare PTY: 0.036 s) |
| Share of that time spent in `Vt.feed` (bytewise in v0) | ≈93% |
| Frames during that `cat` | 66 frames, 31 ms of draw + present |
| RSS idle / with 10k-line scrollback | 7.3 MiB / 14.9 MiB |
