//! Widgets v0 driven by keys and the mouse, on the public venom-term API only.
//!
//!   zig build example-widgets        run it
//!   Tab / Shift-Tab                  move focus: agents → transcript → input
//!   agents:     ↑↓ j k, ← → fold, Enter fold or open an agent
//!   transcript: ↑↓ j k PgUp PgDn Home End, n/p select a tool call,
//!               Enter toggle it, E/C expand or collapse all
//!   input:      type, Enter send, Alt/Shift-Enter or Ctrl-J newline, ↑↓ history
//!   mouse:      click a pane to focus it; wheel scrolls the pane under the
//!               pointer; click an agent to select it (again to open), a
//!               group header to fold it, a tool call's header to toggle it
//!   Ctrl-C / Ctrl-Q                  quit
//!
//! Layout: the agent list on the
//! left, the transcript with its input box on the right, a status line.
//! `App` holds no terminal state, so the tests at the bottom drive it with
//! raw key and SGR mouse bytes and read the rendered Surface.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;
const posix = std.posix;

const Pane = enum { agents, transcript, input };

const agents_needs = [_]w.list.Item{
    .{ .glyph = "▲", .glyph_role = .warn, .title = "venom-echo conformance", .meta = "1m", .detail = &.{ .{ .text = "claude · venom-std · 2 sub · " }, .{ .text = "approve: zig build test", .role = .warn } } },
    .{ .glyph = "✕", .glyph_role = .err, .title = "wasm target", .meta = "12m", .detail = &.{.{ .text = "codex · venom-std · zig build exited 1" }} },
};
const agents_running = [_]w.list.Item{
    .{ .glyph = "◆", .glyph_role = .info, .title = "widgets v0", .meta = "4m", .detail = &.{.{ .text = "claude · venom-term · editing src/widgets" }} },
    .{ .glyph = "◆", .glyph_role = .info, .title = "pane stream snapshots", .meta = "9m", .detail = &.{.{ .text = "opencode · venomx · running tests" }} },
};
const agents_settled = [_]w.list.Item{
    .{ .glyph = "●", .glyph_role = .ok, .title = "venom UX model", .meta = "2h", .bold = true, .detail = &.{.{ .text = "claude · venom · unread" }} },
    .{ .glyph = "●", .glyph_role = .ok, .title = "zig 0.17 pin", .meta = "1d", .detail = &.{.{ .text = "codex · venom-std" }} },
};

pub const App = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    theme: w.Theme = .default,
    focus: w.FocusRing = .{ .count = 3, .index = 2 },
    groups: [3]w.list.Group = .{
        .{ .title = "Needs you", .items = &agents_needs, .summary = "2" },
        .{ .title = "Running", .items = &agents_running, .summary = "2" },
        .{ .title = "Settled", .items = &agents_settled, .summary = "2", .folded = true },
    },
    list: w.GroupedList = .{},
    blocks: std.ArrayList(w.Block) = .empty,
    view: w.ScrollView = .{},
    input: w.TextInput,
    open: []const u8 = "widgets v0",
    status: []const u8 = "",
    quit: bool = false,
    /// Outer box of each pane in focus-ring order, from the last draw.
    panes: [3]term.Region = @splat(.{ .width = 0, .height = 0 }),

    pub fn init(gpa: std.mem.Allocator) !App {
        var app: App = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .input = .init(gpa, .{ .multiline = true, .prompt = "› ", .placeholder = "Message the agent  (Enter send · Alt-Enter newline)" }),
        };
        errdefer app.deinit();
        try app.blocks.appendSlice(gpa, &.{
            .{ .spans = &.{ .{ .text = "you  ", .role = .accent }, .{ .text = "Add widgets for the venom TUI: a grouped agent list, a wrapped transcript and an input box. Keep them headless-testable." } } },
            .{ .spans = &.{ .{ .text = "Explored", .role = .info }, .{ .text = "  6 reads · 2 searches · 1 list", .role = .muted } }, .collapsible = true, .collapsed = true },
            .{ .spans = &.{ .{ .text = "Edit", .role = .info }, .{ .text = "      src/widgets/list.zig  " }, .{ .text = "+212", .role = .ok }, .{ .text = " " }, .{ .text = "−0", .role = .err }, .{ .text = "\n+ pub const GroupedList = struct {\n+     cursor: usize = 0,\n+     top: usize = 0,", .role = .secondary } }, .collapsible = true, .collapsed = true },
            .{ .spans = &.{ .{ .text = "Bash", .role = .info }, .{ .text = "      zig build test  " }, .{ .text = "exit 1 · 2.0s", .role = .err }, .{ .text = "\nsrc/widgets/text.zig:357:38: error: expected 'the quick', found 'the quick '", .role = .err } }, .collapsible = true, .collapsed = false },
            .{ .spans = &.{.{ .text = "The wrap kept a trailing space before a soft break. I now trim it, and every test passes." }} },
        });
        return app;
    }

    pub fn deinit(self: *App) void {
        self.input.deinit();
        self.view.deinit(self.gpa);
        self.blocks.deinit(self.gpa);
        self.arena.deinit();
    }

    fn pane(self: *const App) Pane {
        return switch (self.focus.index) {
            0 => .agents,
            1 => .transcript,
            else => .input,
        };
    }

    fn send(self: *App) !void {
        const msg = try self.input.submit();
        defer self.gpa.free(msg);
        if (std.mem.trim(u8, msg, " \n").len == 0) return;
        const a = self.arena.allocator();
        const you = try a.dupe(w.Span, &.{ .{ .text = "you  ", .role = .accent }, .{ .text = try a.dupe(u8, msg) } });
        const reply = try a.dupe(w.Span, &.{ .{ .text = "Bash", .role = .info }, .{ .text = "      echo  " }, .{ .text = "exit 0 · 0.1s", .role = .ok }, .{ .text = try std.fmt.allocPrint(a, "\n{s}", .{msg}), .role = .secondary } });
        try self.blocks.append(self.gpa, .{ .spans = you });
        try self.blocks.append(self.gpa, .{ .spans = reply, .collapsible = true, .collapsed = true });
        self.view.follow();
        self.status = "sent";
    }

    fn onList(self: *App, action: w.list.Action) void {
        switch (action) {
            .activated => |it| {
                self.open = self.groups[it.group].items[it.index].title;
                self.status = "opened agent";
                self.focus.set(2);
            },
            .toggled => self.status = "folded group",
            .moved => self.status = "moved",
        }
    }

    fn onView(self: *App, action: w.scroll.Action) void {
        self.status = switch (action) {
            .toggled => "toggled block",
            .toggled_all => |e| if (e) "expanded all" else "collapsed all",
            .selected => "selected block",
            .scrolled => if (self.view.following()) "following" else "scrolled",
        };
    }

    pub fn handleKey(self: *App, key: term.Input.Key) !void {
        if (key.action == .release) return;
        if (w.keys.ctrl(key, 'c') or w.keys.ctrl(key, 'q')) {
            self.quit = true;
            return;
        }
        switch (self.pane()) {
            .agents => if (self.list.handleKey(&self.groups, key)) |action| return self.onList(action),
            .transcript => if (self.view.handleKey(self.blocks.items, key)) |action| return self.onView(action),
            .input => if (try self.input.handleKey(key)) |action| {
                if (action == .submit) try self.send();
                return;
            },
        }
        _ = self.focus.handleKey(key);
    }

    /// A click focuses the pane under the pointer, then the widget there
    /// gets the event; the wheel scrolls whichever pane is under it.
    pub fn handleMouse(self: *App, mouse: term.Input.Mouse) void {
        _ = self.focus.handleMouse(mouse, &self.panes);
        if (self.list.handleMouse(&self.groups, mouse)) |action| return self.onList(action);
        if (self.view.handleMouse(self.blocks.items, mouse)) |action| return self.onView(action);
    }

    pub fn draw(self: *App, surface: *term.Surface) !void {
        const screen: term.Region = .{ .width = surface.width, .height = surface.height };
        const main_status = w.layout.stacked(screen, .{ .fixed = 1 });
        const cols = w.layout.sideBySide(main_status[0], .{ .percent = 34 });
        const right = w.layout.stacked(cols[1], .{ .fixed = 5 });
        const t = &self.theme;
        self.panes = .{ cols[0], right[0], right[1] };

        const list_inner = try w.box.draw(surface, cols[0], t, .{ .title = "Agents", .badge = "6", .focused = self.focus.is(0) });
        try self.list.draw(surface, list_inner, &self.groups, t, self.focus.is(0));

        var badge_buf: [32]u8 = undefined;
        const badge = if (self.view.following()) "tail" else std.fmt.bufPrint(&badge_buf, "line {d}", .{(self.view.top orelse 0) + 1}) catch "";
        const view_inner = try w.box.draw(surface, right[0], t, .{ .title = self.open, .badge = badge, .focused = self.focus.is(1) });
        try self.view.draw(self.gpa, surface, view_inner, self.blocks.items, t, self.focus.is(1));

        const input_inner = try w.box.draw(surface, right[1], t, .{ .title = "plan · opus", .badge = "62% · 124k / 200k", .focused = self.focus.is(2) });
        surface.setCursor(null);
        try self.input.draw(surface, input_inner, t, self.focus.is(2));

        const status = main_status[1];
        const fill = t.style(.selection);
        const names = [_][]const u8{ "agents", "transcript", "input" };
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, " ▲ 1 needs you  ·  focus: {s}  ·  Tab focus  ^C quit  ·  {s}", .{ names[self.focus.index], self.status }) catch "";
        _ = try w.text.drawSpans(surface, status.x, status.y, status.width, &.{.{ .text = line }}, t, .{ .overlay = fill, .ellipsis = true, .fill = fill });
    }
};

// ------------------------------------------------------------ terminal

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

fn windowSize(fd: posix.fd_t) struct { cols: u16, rows: u16 } {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const req: c_int = @bitCast(@as(u32, @intCast(posix.T.IOCGWINSZ)));
    if (std.c.ioctl(fd, req, @intFromPtr(&ws)) != 0 or ws.col == 0 or ws.row == 0) return .{ .cols = 80, .rows = 24 };
    return .{ .cols = ws.col, .rows = ws.row };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (!try std.Io.File.stdin().isTty(io) or !try std.Io.File.stdout().isTty(io)) {
        std.debug.print("example-widgets needs a terminal on stdin and stdout\n", .{});
        return error.NotATerminal;
    }
    var app = try App.init(gpa);
    defer app.deinit();
    const size = windowSize(posix.STDOUT_FILENO);
    var surface = try term.Surface.init(gpa, size.cols, size.rows);
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;

    if (std.c.pipe2(&winch_pipe, .{ .NONBLOCK = true, .CLOEXEC = true }) != 0) return error.PipeFailed;
    var act: posix.Sigaction = .{ .handler = .{ .handler = onWinch }, .mask = posix.sigemptyset(), .flags = posix.SA.RESTART };
    posix.sigaction(.WINCH, &act, null);

    const saved = try makeRaw(posix.STDIN_FILENO);
    // Alternate screen, then button and wheel mouse reports in SGR form.
    try out.writeAll("\x1b[?1049h\x1b[?1000h\x1b[?1006h");
    defer {
        surface.deinit(out);
        out.writeAll("\x1b[?1006l\x1b[?1000l\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, saved) catch {};
    }

    var input: term.Input = .{};
    var in_buf: [4096]u8 = undefined;
    var in_len: usize = 0;
    var fds = [_]posix.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = winch_pipe[0], .events = posix.POLL.IN, .revents = 0 },
    };
    while (!app.quit) {
        try app.draw(&surface);
        try surface.present(io, init.environ_map, out);
        try out.flush();
        _ = try posix.poll(&fds, -1);
        if (fds[1].revents != 0) {
            var drain: [64]u8 = undefined;
            while (std.c.read(winch_pipe[0], &drain, drain.len) > 0) {}
            const s = windowSize(posix.STDOUT_FILENO);
            try surface.resize(s.cols, s.rows);
        }
        if (fds[0].revents != 0) {
            const n = std.c.read(posix.STDIN_FILENO, in_buf[in_len..].ptr, in_buf.len - in_len);
            if (n <= 0) return;
            in_len += @intCast(n);
            in_len = try feed(&app, &input, in_buf[0..in_len]);
            if (in_len == in_buf.len) in_len = 0;
        }
    }
}

/// Parses `bytes` into key events for the app; returns the bytes left over
/// (an incomplete sequence), moved to the front of the buffer.
fn feed(app: *App, input: *term.Input, bytes: []u8) !usize {
    var rest: usize = 0;
    var len = bytes.len;
    while (rest < len) {
        const result = input.parse(bytes[rest..len]) catch {
            rest += 1;
            continue;
        };
        if (result.consumed == 0) break;
        if (result.event) |ev| switch (ev) {
            .key => |k| try app.handleKey(k),
            .mouse => |m| app.handleMouse(m),
            else => {},
        };
        rest += result.consumed;
    }
    std.mem.copyForwards(u8, bytes, bytes[rest..len]);
    len -= rest;
    return len;
}

// ------------------------------------------------------------ headless tests

fn expectRowContains(surface: *const term.Surface, y: u16, needle: []const u8) !void {
    const row = try w.text.rowText(std.testing.allocator, surface, y);
    defer std.testing.allocator.free(row);
    if (std.mem.indexOf(u8, row, needle) == null) {
        std.debug.print("row {d}: '{s}' lacks '{s}'\n", .{ y, row, needle });
        return error.TestExpectedEqual;
    }
}

fn findRow(surface: *const term.Surface, needle: []const u8) !?u16 {
    for (0..surface.height) |y| {
        const row = try w.text.rowText(std.testing.allocator, surface, @intCast(y));
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, needle) != null) return @intCast(y);
    }
    return null;
}

/// Feeds an SGR mouse report for 0-based cell (x, y); `code` is the SGR
/// button (0 left, 64 wheel up, 65 wheel down).
fn click(app: *App, input: *term.Input, code: u8, x: u16, y: u16) !void {
    var buf: [32]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}M", .{ code, x + 1, y + 1 });
    try press(app, input, bytes);
}

fn press(app: *App, input: *term.Input, bytes: []const u8) !void {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..bytes.len], bytes);
    try std.testing.expectEqual(@as(usize, 0), try feed(app, input, buf[0..bytes.len]));
}

test "example app renders a grouped list, a scroll view and an input box driven by keys" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try term.Surface.init(a, 90, 14);
    defer surface.deinit(&discard.writer);
    var app = try App.init(a);
    defer app.deinit();
    var input: term.Input = .{};

    try app.draw(&surface);
    try expectRowContains(&surface, 0, "Agents");
    try expectRowContains(&surface, 1, "▾ Needs you  2");
    try expectRowContains(&surface, 2, "▲ venom-echo conformance");
    try expectRowContains(&surface, 3, "claude · venom-std");
    try std.testing.expect(try findRow(&surface, "▸ Settled  2") != null);
    try std.testing.expect(try findRow(&surface, "▾ Bash      zig build test  exit 1") != null);
    try std.testing.expect(try findRow(&surface, "Message the agent") != null);
    try expectRowContains(&surface, 13, "focus: input");
    // The input is focused and owns the terminal cursor.
    try std.testing.expect(surface.cursor != null);

    // Type a prompt and send it: the transcript follows the tail.
    try press(&app, &input, "hello widgets\r");
    try app.draw(&surface);
    try std.testing.expect(try findRow(&surface, "you  hello widgets") != null);
    try std.testing.expect(try findRow(&surface, "▸ Bash      echo  exit 0") != null);
    try std.testing.expect(try findRow(&surface, "Message the agent") != null);
    // ↑ recalls history.
    try press(&app, &input, "\x1b[A");
    try std.testing.expectEqualStrings("hello widgets", app.input.value());

    // Tab wraps to the agent list; j moves, Enter on a folded header unfolds.
    try press(&app, &input, "\x15\t");
    try std.testing.expect(app.focus.is(0));
    try press(&app, &input, "\x1b[F\r");
    try std.testing.expect(!app.groups[2].folded);
    // j selects the first settled agent; the list scrolls to show it.
    try press(&app, &input, "j");
    try app.draw(&surface);
    try std.testing.expect(try findRow(&surface, "venom UX model") != null);
    // Open an agent: its title heads the transcript and focus moves to input.
    try press(&app, &input, "\r");
    try std.testing.expectEqualStrings("venom UX model", app.open);
    try std.testing.expect(app.focus.is(2));
    try app.draw(&surface);
    try expectRowContains(&surface, 0, "venom UX model");

    // Shift-Tab to the transcript; scroll up leaves tail mode, End returns.
    try press(&app, &input, "\x1b[Z");
    try std.testing.expect(app.focus.is(1));
    try press(&app, &input, "kk");
    try std.testing.expect(!app.view.following());
    try app.draw(&surface);
    try expectRowContains(&surface, 0, "line ");
    try press(&app, &input, "\x1b[F");
    try std.testing.expect(app.view.following());
    // E expands every tool call.
    try press(&app, &input, "E");
    try std.testing.expect(!app.blocks.items[1].collapsed);

    try press(&app, &input, "\x03");
    try std.testing.expect(app.quit);
}

test "example app supports wheel scroll and click to focus, select and toggle" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try term.Surface.init(a, 90, 14);
    defer surface.deinit(&discard.writer);
    var app = try App.init(a);
    defer app.deinit();
    var input: term.Input = .{};
    try app.draw(&surface);
    try std.testing.expect(app.focus.is(2));

    // Wheel over the transcript scrolls it without moving focus.
    const view = app.view.area;
    try click(&app, &input, 64, view.x + 2, view.y + 1);
    try std.testing.expect(!app.view.following());
    try std.testing.expect(app.focus.is(2));
    try click(&app, &input, 65, view.x + 2, view.y + 1);
    try std.testing.expect(app.view.following());

    // Clicking the "Bash" tool call's header focuses the transcript and
    // collapses the block.
    const bash = (try findRow(&surface, "▾ Bash      zig build test")).?;
    try click(&app, &input, 0, view.x + 3, bash);
    try std.testing.expect(app.focus.is(1));
    try std.testing.expect(app.blocks.items[3].collapsed);
    try std.testing.expectEqualStrings("toggled block", app.status);
    try app.draw(&surface);
    try std.testing.expect(try findRow(&surface, "▸ Bash      zig build test") != null);

    // Clicking an agent focuses the list and selects it; again opens it.
    const wasm = (try findRow(&surface, "✕ wasm target")).?;
    try click(&app, &input, 0, 3, wasm);
    try std.testing.expect(app.focus.is(0));
    try std.testing.expectEqual(w.list.Selection{ .item = .{ .group = 0, .index = 1 } }, app.list.selected(&app.groups).?);
    try app.draw(&surface);
    try click(&app, &input, 0, 3, wasm);
    try std.testing.expectEqualStrings("wasm target", app.open);
    try std.testing.expect(app.focus.is(2));
    // Wheel over the list moves its cursor; a click on a header folds it.
    try app.draw(&surface);
    try click(&app, &input, 65, 3, wasm);
    try std.testing.expectEqual(w.list.Selection{ .group = 1 }, app.list.selected(&app.groups).?);
    try click(&app, &input, 0, 3, app.list.area.y);
    try std.testing.expect(app.groups[0].folded);
    // A click in the input box focuses it; releases are ignored.
    try press(&app, &input, "\x1b[<0;2;2m");
    try click(&app, &input, 0, app.panes[2].x + 4, app.panes[2].y + 2);
    try std.testing.expect(app.focus.is(2));
}

test "example layout reflows on resize" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try term.Surface.init(a, 120, 30);
    defer surface.deinit(&discard.writer);
    var app = try App.init(a);
    defer app.deinit();
    try app.draw(&surface);
    try surface.resize(50, 12);
    try app.draw(&surface);
    try expectRowContains(&surface, 0, "Agents");
    try expectRowContains(&surface, 11, "focus: input");
    try surface.resize(8, 3);
    try app.draw(&surface);
}
