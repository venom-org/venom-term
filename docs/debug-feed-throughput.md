# Debug feed throughput

In a Debug build, `Vt.feed` of `yes FLOOD` output (6-byte LF lines) cost
about 180 µs per byte. ReleaseSafe handled the same stream about 3700x
faster.

## Cause

Building only libghostty-vt in Debug (`-Dghostty-optimize=debug`) reproduces
the slowdown, and building only libghostty-vt optimized removes it. The
venom-term wrapper's per-control-byte observation path is not the cost.
Ghostty enables `slow_runtime_safety` in Debug, which runs full page
integrity checks (`Page.verifyIntegrity`, `Screen.assertIntegrity`) on page
mutations. Every line scrolls, so short lines hit those checks constantly.

## Fix

`build.zig` builds the ghostty dependency with `.safe` (ReleaseSafe) when the
build is `.debug`. Otherwise ghostty uses the build's own mode. venom-term's
own code and its dependents keep the requested mode and Debug safety.
Dependents such as venomx get this automatically through
`b.dependency("venom_term", ...)`. To debug inside ghostty itself, pass
`-Dghostty-optimize=debug` (or any other mode).

## Reproduce

```sh
zig build -Dheadless=true --prefix zig-out/debug
zig build -Dheadless=true -Doptimize=ReleaseSafe --prefix zig-out/release
zig build -Dheadless=true -Dghostty-optimize=debug --prefix zig-out/ghdebug
zig-out/debug/bin/feed-bench 100 20480 none 30 1 yes
zig-out/debug/bin/feed-bench 100 1048576 none 30 1 crlf
```

The sixth argument chooses the pattern: `yes` writes `FLOOD\n` repeatedly, and
`crlf` (the default) writes 79 printable bytes plus CRLF.

## Measurements

Zig 0.17.0, x86_64 Linux, 100x30, `none` metadata, one pass:

| Build | `yes` 20 KiB | `yes` 1 MiB | `crlf` 1 MiB |
|---|---|---|---|
| Debug, ghostty Debug (before) | 3.70 s | not run (~3 min) | 13.33 s |
| Debug, ghostty ReleaseSafe (after) | 1.24 ms | 68.4 ms | 5.36 ms |
| ReleaseSafe | 1.00 ms | 60.6 ms | 3.74 ms |

After the fix, Debug runs within 1.5x of ReleaseSafe; the target was 10x.
