//! Two shells in PTYs, rendered side by side through venom-term only.
//!
//!   zig build example-panes                 run it (2>panes.log keeps OSC logs)
//!   Ctrl-A o / Ctrl-A Tab                   switch the focused pane
//!   Ctrl-A q                                quit
//!   Ctrl-A Ctrl-A                           send a literal Ctrl-A
//!
//! OSC 7501 and OSC 133 observations are logged to stderr, one line each,
//! unless stderr is the display terminal; the latest one is always shown in
//! the status line. On exit a `stats` line goes to stderr.
//!
//! The example uses only the public venom-term API (Surface, Input, Vt,
//! VtView) plus libc for the PTYs, raw mode, poll and SIGWINCH. There is no
//! frame timer: poll blocks indefinitely when nothing changed.
const std = @import("std");
const term = @import("venom-term");
const posix = std.posix;

extern "c" fn forkpty(master: *c_int, name: ?[*]u8, termp: ?*const posix.termios, winp: ?*const posix.winsize) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Minimum interval between frames while output is streaming.
const frame_ns: i96 = 8 * std.time.ns_per_ms;
const ctrl_a = 0x01;

const Box = struct { outer: term.Region, inner: term.Region };

const Pane = struct {
    app: *App,
    name: []const u8,
    vt: term.Vt = undefined,
    view: term.VtView = .{},
    fd: posix.fd_t = -1,
    pid: posix.pid_t = -1,
    alive: bool = false,
    dirty: bool = true,
    box: Box = undefined,
    fed_bytes: u64 = 0,
    feed_ns: i96 = 0,
};

const App = struct {
    io: std.Io,
    panes: [2]Pane = undefined,
    focus: usize = 0,
    log_stderr: bool,
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    status_dirty: bool = true,
    frames: u64 = 0,
    render_ns: i96 = 0,
    presented_bytes: u64 = 0,

    fn note(self: *App, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        if (self.log_stderr) {
            writeAll(posix.STDERR_FILENO, line);
            writeAll(posix.STDERR_FILENO, "\n");
        }
        // The status line is one row, so keep only printable ASCII there.
        var n: usize = 0;
        for (line) |ch| {
            if (n == self.status_buf.len) break;
            self.status_buf[n] = if (ch >= 0x20 and ch < 0x7f) ch else '?';
            n += 1;
        }
        self.status_len = n;
        self.status_dirty = true;
    }
};

fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n < 0) {
            if (std.c.errno(n) == .INTR or std.c.errno(n) == .AGAIN) continue;
            return;
        }
        rest = rest[@intCast(n)..];
    }
}

// ------------------------------------------------------------ Vt callbacks

fn onWritePty(ctx: ?*anyopaque, bytes: []const u8) void {
    const pane: *Pane = @ptrCast(@alignCast(ctx.?));
    if (pane.alive) writeAll(pane.fd, bytes);
}

fn onProgramStatus(ctx: ?*anyopaque, r: term.Vt.ProgramStatus) void {
    const pane: *Pane = @ptrCast(@alignCast(ctx.?));
    pane.app.note("osc7501 pane={s} state={t} kind={t} progress={?d} id=\"{f}\" app=\"{f}\" title=\"{f}\" message=\"{f}\"", .{
        pane.name, r.state, r.kind, r.progress, std.zig.fmtString(r.id), std.zig.fmtString(r.app), std.zig.fmtString(r.title), std.zig.fmtString(r.message),
    });
}

fn onSemanticPrompt(ctx: ?*anyopaque, e: term.Vt.SemanticPrompt) void {
    const pane: *Pane = @ptrCast(@alignCast(ctx.?));
    pane.app.note("osc133 pane={s} kind={t} prompt={t} exit={?d} command=\"{f}\" message=\"{f}\"", .{
        pane.name, e.kind, e.prompt, e.exit_code, std.zig.fmtString(e.command), std.zig.fmtString(e.message),
    });
}

// ------------------------------------------------------------ terminal setup

var winch_pipe: [2]posix.fd_t = .{ -1, -1 };

fn onWinch(_: posix.SIG) callconv(.c) void {
    const byte = [_]u8{1};
    _ = std.c.write(winch_pipe[1], &byte, 1);
}

fn makeRaw(fd: posix.fd_t) !posix.termios {
    const state = try posix.tcgetattr(fd);
    var raw = state;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;
    raw.cc[@backingInt(posix.V.MIN)] = 1;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
    try posix.tcsetattr(fd, .FLUSH, raw);
    return state;
}

fn ioctlRequest(comptime value: anytype) c_int {
    return @bitCast(@as(u32, @intCast(value)));
}

fn windowSize(fd: posix.fd_t) struct { cols: u16, rows: u16 } {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(fd, ioctlRequest(posix.T.IOCGWINSZ), @intFromPtr(&ws)) != 0 or ws.col == 0 or ws.row == 0)
        return .{ .cols = 80, .rows = 24 };
    return .{ .cols = ws.col, .rows = ws.row };
}

fn setPtySize(fd: posix.fd_t, inner: term.Region) void {
    const ws: posix.winsize = .{ .row = inner.height, .col = inner.width, .xpixel = 0, .ypixel = 0 };
    _ = std.c.ioctl(fd, ioctlRequest(posix.T.IOCSWINSZ), @intFromPtr(&ws));
}

/// Two bordered boxes side by side above a one-row status line.
fn layout(cols: u16, rows: u16, index: usize) Box {
    const height = @max(rows, 4) - 1;
    const left = @max(cols / 2, 3);
    const x: u16 = if (index == 0) 0 else left;
    const width: u16 = if (index == 0) left else @max(cols -| left, 3);
    const outer: term.Region = .{ .x = x, .y = 0, .width = width, .height = height };
    return .{ .outer = outer, .inner = .{ .x = x + 1, .y = 1, .width = width - 2, .height = @max(height, 3) - 2 } };
}

fn spawn(pane: *Pane, shell: [:0]const u8) !void {
    const ws: posix.winsize = .{ .row = pane.box.inner.height, .col = pane.box.inner.width, .xpixel = 0, .ypixel = 0 };
    var master: c_int = -1;
    const pid = forkpty(&master, null, null, &ws);
    if (pid < 0) return error.ForkPtyFailed;
    if (pid == 0) {
        _ = setenv("TERM", "xterm-256color", 1);
        const argv = [_:null]?[*:0]const u8{shell.ptr};
        _ = execvp(shell.ptr, &argv);
        std.c._exit(127);
    }
    pane.fd = master;
    pane.pid = pid;
    pane.alive = true;
}

// ------------------------------------------------------------ drawing

fn drawBorder(surface: *term.Surface, pane: *const Pane, focused: bool) !void {
    const r = pane.box.outer;
    const style: term.Style = if (focused) .{ .fg = .{ .index = 2 }, .bold = true } else .{ .fg = .{ .index = 8 } };
    const right = r.x + r.width - 1;
    const bottom = r.y + r.height - 1;
    for (r.x..right + 1) |x| {
        const top_glyph = if (x == r.x) "┌" else if (x == right) "┐" else "─";
        const bottom_glyph = if (x == r.x) "└" else if (x == right) "┘" else "─";
        try surface.put(@intCast(x), r.y, .{ .text = top_glyph, .style = style });
        try surface.put(@intCast(x), bottom, .{ .text = bottom_glyph, .style = style });
    }
    for (r.y + 1..bottom) |y| {
        try surface.put(r.x, @intCast(y), .{ .text = "│", .style = style });
        try surface.put(right, @intCast(y), .{ .text = "│", .style = style });
    }
    var title: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&title, " {s}{s} ", .{ pane.name, if (pane.alive) "" else " [exited]" }) catch " ? ";
    try surface.text(.{ .x = r.x + 2, .y = r.y, .width = r.width -| 4, .height = 1 }, label, style);
}

fn drawStatus(surface: *term.Surface, app: *const App) !void {
    const y = surface.height - 1;
    const style: term.Style = .{ .reverse = true };
    try surface.clear(.{ .y = y, .width = surface.width, .height = 1 }, style);
    var buf: [384]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, " focus: {s} | ^A o switch  ^A q quit | {s}", .{
        app.panes[app.focus].name, app.status_buf[0..app.status_len],
    }) catch buf[0..];
    try surface.text(.{ .y = y, .width = surface.width, .height = 1 }, line, style);
}

fn placeCursor(surface: *term.Surface, app: *const App) void {
    const pane = &app.panes[app.focus];
    const cur = pane.vt.cursor();
    const inner = pane.box.inner;
    if (!pane.alive or !cur.visible or pane.view.top != null or cur.x >= inner.width or cur.y >= inner.height) {
        surface.setCursor(null);
    } else surface.setCursor(.{ .x = inner.x + cur.x, .y = inner.y + cur.y });
}

// ------------------------------------------------------------ main

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (!try std.Io.File.stdin().isTty(io) or !try std.Io.File.stdout().isTty(io)) {
        std.debug.print("example-panes needs a terminal on stdin and stdout\n", .{});
        return error.NotATerminal;
    }
    const shell = try init.arena.allocator().dupeSentinel(u8, init.environ_map.get("SHELL") orelse "/bin/sh", 0);

    var app: App = .{ .io = io, .log_stderr = !try std.Io.File.stderr().isTty(io) };
    app.panes = .{ .{ .app = &app, .name = "left" }, .{ .app = &app, .name = "right" } };

    const size = windowSize(posix.STDOUT_FILENO);
    var surface = try term.Surface.init(gpa, size.cols, size.rows);
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;

    var vts: usize = 0;
    defer for (app.panes[0..vts]) |*pane| pane.vt.deinit();
    for (&app.panes, 0..) |*pane, i| {
        pane.box = layout(size.cols, size.rows, i);
        pane.vt = try term.Vt.init(gpa, .{
            .cols = pane.box.inner.width,
            .rows = pane.box.inner.height,
            .callbacks = .{ .context = pane, .write_pty = onWritePty, .program_status = onProgramStatus, .semantic_prompt = onSemanticPrompt },
        });
        vts += 1;
    }
    defer for (&app.panes) |*pane| {
        if (pane.alive) {
            _ = std.c.kill(pane.pid, .HUP);
            _ = std.c.waitpid(pane.pid, null, 0);
        }
        if (pane.fd >= 0) _ = std.c.close(pane.fd);
    };
    for (&app.panes) |*pane| try spawn(pane, shell);

    if (std.c.pipe2(&winch_pipe, .{ .NONBLOCK = true, .CLOEXEC = true }) != 0) return error.PipeFailed;
    var act: posix.Sigaction = .{ .handler = .{ .handler = onWinch }, .mask = posix.sigemptyset(), .flags = posix.SA.RESTART };
    posix.sigaction(.WINCH, &act, null);

    const saved = try makeRaw(posix.STDIN_FILENO);
    // Alternate screen; everything else (cursor, sync output) is the Surface's.
    try out.writeAll("\x1b[?1049h");
    defer {
        surface.deinit(out);
        out.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, saved) catch {};
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "stats frames={d} render_ms={d:.3} presented_bytes={d} left_fed={d} left_feed_ms={d:.3} right_fed={d} right_feed_ms={d:.3}\n", .{
            app.frames,               ms(app.render_ns),        app.presented_bytes,
            app.panes[0].fed_bytes,   ms(app.panes[0].feed_ns), app.panes[1].fed_bytes,
            ms(app.panes[1].feed_ns),
        }) catch "stats unavailable\n";
        writeAll(posix.STDERR_FILENO, line);
    }
    try run(gpa, &app, &surface, init.environ_map, out);
}

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn run(gpa: std.mem.Allocator, app: *App, surface: *term.Surface, env: *std.process.Environ.Map, out: *std.Io.Writer) !void {
    const io = app.io;
    var input: term.Input = .{};
    var in_buf: [4096]u8 = undefined;
    var in_len: usize = 0;
    var prefix = false;
    var full = true;
    var next_frame: i96 = 0;
    var read_buf: [64 * 1024]u8 = undefined;
    var frame: std.Io.Writer.Allocating = .init(gpa);
    defer frame.deinit();
    var fds = [_]posix.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = winch_pipe[0], .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = app.panes[0].fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = app.panes[1].fd, .events = posix.POLL.IN, .revents = 0 },
    };
    while (true) {
        const dirty = full or app.status_dirty or app.panes[0].dirty or app.panes[1].dirty;
        const timeout: i32 = if (!dirty) -1 else @intCast(@max(0, @divFloor(next_frame - now(io) + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        _ = try posix.poll(&fds, timeout);

        if (fds[1].revents != 0) {
            var drain: [64]u8 = undefined;
            while (std.c.read(winch_pipe[0], &drain, drain.len) > 0) {}
            const size = windowSize(posix.STDOUT_FILENO);
            try surface.resize(size.cols, size.rows);
            for (&app.panes, 0..) |*pane, i| {
                pane.box = layout(size.cols, size.rows, i);
                try pane.vt.resize(pane.box.inner.width, pane.box.inner.height);
                if (pane.alive) setPtySize(pane.fd, pane.box.inner);
            }
            full = true;
        }

        if (fds[0].revents != 0) {
            const n = std.c.read(posix.STDIN_FILENO, in_buf[in_len..].ptr, in_buf.len - in_len);
            if (n <= 0) return;
            in_len += @intCast(n);
            while (in_len > 0) {
                const bytes = in_buf[0..in_len];
                const result = input.parse(bytes) catch {
                    // Invalid input: discard one byte to make progress.
                    std.mem.copyForwards(u8, &in_buf, in_buf[1..in_len]);
                    in_len -= 1;
                    continue;
                };
                if (result.consumed == 0) break;
                const raw = bytes[0..result.consumed];
                const key: ?term.Input.Key = if (result.event) |ev| switch (ev) {
                    .key => |k| if (k.action == .press) k else null,
                    else => null,
                } else null;
                if (prefix) {
                    prefix = false;
                    if (key) |k| {
                        if (k.codepoint == 'q') return;
                        if (k.codepoint == 'o' or k.codepoint == @backingInt(term.Input.NamedKey.tab)) {
                            app.focus = 1 - app.focus;
                            full = true;
                        } else if (k.codepoint == 'a' and k.mods.ctrl) {
                            const pane = &app.panes[app.focus];
                            if (pane.alive) writeAll(pane.fd, &.{ctrl_a});
                        }
                    }
                } else if (key != null and key.?.codepoint == 'a' and key.?.mods.ctrl) {
                    prefix = true;
                } else {
                    // Without kitty keyboard mode, the outer terminal's legacy bytes
                    // are what the inner shell expects, so forward them unchanged.
                    const pane = &app.panes[app.focus];
                    if (pane.alive) writeAll(pane.fd, raw);
                }
                std.mem.copyForwards(u8, &in_buf, in_buf[result.consumed..in_len]);
                in_len -= result.consumed;
            }
            // A full buffer of an incomplete sequence can never complete: drop it.
            if (in_len == in_buf.len) in_len = 0;
        }

        for (&app.panes, fds[2..]) |*pane, *pfd| {
            if (pfd.revents == 0) continue;
            const n = std.c.read(pane.fd, &read_buf, read_buf.len);
            if (n <= 0) {
                if (n < 0 and (std.c.errno(n) == .INTR or std.c.errno(n) == .AGAIN)) continue;
                pane.alive = false;
                _ = std.c.waitpid(pane.pid, null, 0);
                pfd.fd = -1;
                app.note("pane={s} exited", .{pane.name});
                full = true;
                continue;
            }
            const start = now(io);
            try pane.vt.feed(read_buf[0..@intCast(n)]);
            pane.feed_ns += now(io) - start;
            pane.fed_bytes += @intCast(n);
            pane.dirty = true;
        }
        if (!app.panes[0].alive and !app.panes[1].alive) return;

        const t = now(io);
        if (t < next_frame) continue;
        if (!(full or app.status_dirty or app.panes[0].dirty or app.panes[1].dirty)) continue;
        if (full) {
            for (&app.panes, 0..) |*pane, i| {
                try drawBorder(surface, pane, i == app.focus);
                pane.dirty = true;
            }
            app.status_dirty = true;
            full = false;
        }
        for (&app.panes) |*pane| if (pane.dirty) {
            try pane.view.draw(pane.vt, surface, pane.box.inner);
            pane.dirty = false;
        };
        if (app.status_dirty) {
            try drawStatus(surface, app);
            app.status_dirty = false;
        }
        placeCursor(surface, app);
        // Present into a reusable frame buffer: exact byte counts, one write per frame.
        frame.clearRetainingCapacity();
        try surface.present(io, env, &frame.writer);
        app.presented_bytes += frame.written().len;
        try out.writeAll(frame.written());
        try out.flush();
        app.frames += 1;
        const done = now(io);
        app.render_ns += done - t;
        next_frame = done + frame_ns;
    }
}
