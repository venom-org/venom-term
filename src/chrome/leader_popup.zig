//! Leader popup, the part with no renderer: what the rows say
//! and when the popup is up. `widgets.leader_popup` draws the result, so a
//! headless client core can test its popup without libvaxis.
const std = @import("std");
const keys = @import("keys.zig");
const NamedKey = @import("types").Input.NamedKey;

/// One row: the keys, a `+` when it is a group, and the label.
pub const Row = struct {
    /// Display text, joined by spaces when bindings share the row (`h ←`).
    keys: []const u8,
    /// More keys follow: draw `+`.
    more: bool = false,
    label: []const u8,
};
/// What one frame of the popup shows.
pub const Model = struct {
    /// The path so far: `venomx › venom › agents`.
    title: []const u8,
    rows: []const Row,
};

/// A chord for a row: chord text, with arrows as glyphs and `escape` as `esc`
/// (`ctrl+←`). Allocates in `a` (an arena).
pub fn keyText(a: std.mem.Allocator, c: keys.Chord) ![]const u8 {
    const glyph: ?[]const u8 = if (c.cp == @backingInt(NamedKey.left))
        "←"
    else if (c.cp == @backingInt(NamedKey.down))
        "↓"
    else if (c.cp == @backingInt(NamedKey.up))
        "↑"
    else if (c.cp == @backingInt(NamedKey.right))
        "→"
    else if (c.cp == 27)
        "esc"
    else
        null;
    const full = try keys.chordText(a, c);
    const short = glyph orelse return full;
    const name = try keys.chordText(a, .{ .cp = c.cp });
    return std.fmt.allocPrint(a, "{s}{s}", .{ full[0 .. full.len - name.len], short });
}

/// Rows from `Router.next` or `Resolved.next`, in table order. Bindings with
/// the same target and label share the first one's row. An `exec` binding's
/// label can be `argv[0]`, which config can make invalid UTF-8; it shows as
/// `�`. Allocates in `a` (an arena).
pub fn rows(a: std.mem.Allocator, nexts: anytype) ![]Row {
    const out = try a.alloc(Row, nexts.len);
    // The first `Next` of each row, for `sameRow`.
    const firsts = try a.alloc(usize, nexts.len);
    var n: usize = 0;
    outer: for (nexts, 0..) |next, i| {
        const text = try keyText(a, next.key);
        for (out[0..n], firsts[0..n]) |*row, first| {
            if (!nexts[first].sameRow(next)) continue;
            row.keys = try std.fmt.allocPrint(a, "{s} {s}", .{ row.keys, text });
            continue :outer;
        }
        const label = if (std.unicode.utf8ValidateSlice(next.label)) next.label else "�";
        out[n] = .{ .keys = text, .more = next.more, .label = label };
        firsts[n] = i;
        n += 1;
    }
    return out[0..n];
}

/// `client › a › b`. `client` names who draws the popup: a product's popup
/// must name the product, so it cannot pass for the client's.
pub fn title(a: std.mem.Allocator, client: []const u8, path: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, client);
    for (path) |part| {
        if (out.items.len > 0) try out.appendSlice(a, " › ");
        try out.appendSlice(a, part);
    }
    return out.items;
}

/// The leader, as `model` needs it. `Router.feed` takes this key at the root
/// before any table sees it, so `next` may not describe what it does.
pub const Leader = struct {
    key: keys.Chord,
    /// The row for the leader pressed at the root, after the tables' rows. What
    /// it does belongs to the client: `send-leader` in venomx, the agent switcher
    /// in venom. Null shows no row.
    label: ?[]const u8 = null,
};

/// This frame's popup from a `*Tables(…).Router`. At the root, a binding on the
/// leader's own key can never run, so it gets no row. Allocates in `a` (an
/// arena).
pub fn model(a: std.mem.Allocator, client: []const u8, router: anytype, leader: Leader) !Model {
    const nexts = try router.next(a);
    var kept: usize = 0;
    for (nexts) |next| {
        if (router.seq.len == 0 and next.key.eql(leader.key)) continue;
        nexts[kept] = next;
        kept += 1;
    }
    const from_tables = try rows(a, nexts[0..kept]);
    var all = from_tables;
    if (leader.label) |label| if (router.seq.len == 0) {
        all = try a.alloc(Row, from_tables.len + 1);
        @memcpy(all[0..from_tables.len], from_tables);
        all[from_tables.len] = .{ .keys = try keyText(a, leader.key), .label = label };
    };
    return .{ .title = try title(a, client, try router.path(a)), .rows = all };
}

/// When the popup is up. It holds no router: `State.of` reads what it
/// needs, and all times are in the router's clock, in milliseconds.
///
/// - After the leader or a prefix key it comes up `popup_delay_ms` later, or at
///   once for 0. A faster key restarts the wait, so nobody who knows the keys
///   sees it.
/// - Once up it stays up from level to level until leader mode ends, so reading
///   down a tree does not flicker.
/// - It goes down when a sticky group's binding runs, and `?` brings it back at
///   once.
pub const Timer = struct {
    shown: bool = false,
    due: ?i64 = null,
    last: State = .{},

    pub const State = struct {
        /// In leader mode (`Router.pending`).
        pending: bool = false,
        /// `Router.popupHidden`.
        hidden: bool = false,
        /// Keys typed since the leader (`Router.seq.len`).
        level: u8 = 0,

        pub fn of(router: anytype) State {
            return .{ .pending = router.pending(), .hidden = router.popupHidden(), .level = router.seq.len };
        }
    };

    /// Call after anything that can change the router (`feed`, `tick`, `end`,
    /// `lock`, `begin`, `refocus`), and when `nextWake` passes; once per loop
    /// turn before drawing is simplest. Calling it more often changes nothing,
    /// but two keys fed between calls count as one. True when the frame is out of date: what
    /// the popup covered must be drawn again, then the popup if `visible`.
    pub fn sync(self: *Timer, state: State, delay_ms: u32, now: i64) bool {
        const before = self.shown;
        const was = self.last;
        self.last = state;
        if (!state.pending or state.hidden) {
            self.shown = false;
            self.due = null;
            return before;
        }
        const moved = state.level != was.level;
        if (was.pending and was.hidden and !moved) {
            // Only `?` shows a hidden popup without changing the level.
            self.shown = true;
            self.due = null;
        } else if (!self.shown and (!was.pending or was.hidden or moved)) {
            self.due = now +| delay_ms;
        }
        if (self.due) |due| if (now >= due) {
            self.shown = true;
            self.due = null;
        };
        return before != self.shown or (self.shown and moved);
    }
    pub fn visible(self: *const Timer) bool {
        return self.shown;
    }
    /// When `sync` must run again; null when nothing is waiting, so an event
    /// loop need not wake for the popup, open or not.
    pub fn nextWake(self: *const Timer) ?i64 {
        return self.due;
    }
};

// ------------------------------------------------------------------- tests

const testing = std.testing;
const Local = enum {
    focus_left,
    focus_right,
    clear,
    scroll_up,
    scroll_down,

    fn parse(s: []const u8) ?Local {
        return std.meta.stringToEnum(Local, s);
    }
    fn name(l: Local) []const u8 {
        return @tagName(l);
    }
};
const K = keys.Tables(Local, .{ .parseLocal = Local.parse, .localName = Local.name });

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tables: []K.Table,
    router: K.Router,
    settings: keys.Settings,

    fn init(self: *Fixture) !void {
        self.arena = .init(testing.allocator);
        const a = self.arena.allocator();
        const builtin = (try K.parseTable(a, .{
            .name = "venomx",
            .groups = &.{.{ .key = "[", .label = "scroll", .sticky = true }},
            .bind = &.{
                .{ .key = "h", .local = "focus_left", .label = "focus left" },
                .{ .key = "l", .local = "focus_right", .label = "focus right" },
                .{ .key = "left", .local = "focus_left", .label = "focus left" },
                .{ .key = "right", .local = "focus_right", .label = "focus right" },
                .{ .key = "[ j", .local = "scroll_down", .label = "down" },
                .{ .key = "[ k", .local = "scroll_up", .label = "up" },
                .{ .key = "escape", .local = "clear" },
                .{ .key = "x", .exec = &.{"tool\xff"} },
            },
        }, .builtin)).ok;
        const venom = (try K.parseTable(a, .{
            .name = "venom",
            .prefix = "v",
            .label = "venom",
            .groups = &.{.{ .key = "a", .label = "agents" }},
            .bind = &.{
                .{ .key = "a s", .label = "stop", .exec = &.{"venom"} },
                .{ .key = "s", .label = "settings", .verb = "pane.popup" },
            },
        }, .product)).ok;
        self.tables = try a.dupe(K.Table, &.{ builtin, venom });
        self.router = .init(testing.allocator);
        self.settings = .{ .leader = keys.parseChord("ctrl+a").?, .timeout_ms = 0 };
    }
    fn deinit(self: *Fixture) void {
        self.router.deinit();
        self.arena.deinit();
    }
    fn press(self: *Fixture, key: []const u8, now: i64) !void {
        _ = try self.router.feed(self.settings, self.tables, null, keys.parseChord(key).?, now);
    }
};

test "rows merge the same target and label, in table order" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.press("ctrl+a", 0);
    const a = f.arena.allocator();
    const m = try model(a, "venomx", &f.router, .{ .key = f.settings.leader, .label = "send-leader" });
    try testing.expectEqualStrings("venomx", m.title);
    // Precedence order, so the product's table comes before the built-in one.
    const want = [_]Row{
        .{ .keys = "v", .more = true, .label = "venom" },
        .{ .keys = "h ←", .label = "focus left" },
        .{ .keys = "l →", .label = "focus right" },
        .{ .keys = "[", .more = true, .label = "scroll" },
        .{ .keys = "esc", .label = "clear" },
        .{ .keys = "x", .label = "�" },
        .{ .keys = "ctrl+a", .label = "send-leader" },
    };
    try testing.expectEqual(want.len, m.rows.len);
    for (want, m.rows) |w, got| {
        try testing.expectEqualStrings(w.keys, got.keys);
        try testing.expectEqualStrings(w.label, got.label);
        try testing.expectEqual(w.more, got.more);
    }
}

test "model below the root: the path, and no leader row" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.press("ctrl+a", 0);
    try f.press("v", 0);
    try f.press("a", 0);
    const a = f.arena.allocator();
    const m = try model(a, "venomx", &f.router, .{ .key = f.settings.leader, .label = "send-leader" });
    try testing.expectEqualStrings("venomx › venom › agents", m.title);
    try testing.expectEqual(@as(usize, 1), m.rows.len);
    try testing.expectEqualStrings("stop", m.rows[0].label);
}

test "model: a binding on the leader's key has no row at the root, and does below it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    // `x` is bound at the root and `s` inside `v`.
    f.settings.leader = keys.parseChord("x").?;
    try f.press("x", 0);
    try testing.expect(f.router.pending());
    const root = try model(a, "venomx", &f.router, .{ .key = f.settings.leader });
    for (root.rows) |r| try testing.expect(!std.mem.eql(u8, r.keys, "x"));
    try testing.expectEqual(@as(usize, 5), root.rows.len);
    // The label brings back a row, which says what the key really does.
    const labelled = try model(a, "venomx", &f.router, .{ .key = f.settings.leader, .label = "send-leader" });
    try testing.expectEqualStrings("x", labelled.rows[labelled.rows.len - 1].keys);
    try testing.expectEqualStrings("send-leader", labelled.rows[labelled.rows.len - 1].label);
    // Only the root is intercepted.
    try f.press("v", 0);
    const inner = try model(a, "venomx", &f.router, .{ .key = keys.parseChord("s").? });
    try testing.expectEqualStrings("s", inner.rows[1].keys);
}

test "keyText keeps modifiers and shortens arrows and escape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][2][]const u8{
        .{ "up", "↑" },
        .{ "down", "↓" },
        .{ "ctrl+left", "ctrl+←" },
        .{ "alt+shift+right", "alt+shift+→" },
        .{ "esc", "esc" },
        .{ "page_up", "page_up" },
        .{ "%", "%" },
    }) |c| try testing.expectEqualStrings(c[1], try keyText(a, keys.parseChord(c[0]).?));
}

/// `Timer.sync` from the router, as a client calls it.
fn step(t: *Timer, f: *Fixture, now: i64) bool {
    return t.sync(.of(&f.router), f.settings.popup_delay_ms, now);
}

test "delay: the popup comes up after popup_delay_ms and needs no other wake" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var t: Timer = .{};
    try testing.expect(!step(&t, &f, 0));
    try testing.expectEqual(@as(?i64, null), t.nextWake());
    try f.press("ctrl+a", 1000);
    try testing.expect(!step(&t, &f, 1000));
    try testing.expect(!t.visible());
    try testing.expectEqual(@as(?i64, 1200), t.nextWake());
    // Early wakes change nothing.
    try testing.expect(!step(&t, &f, 1199));
    try testing.expectEqual(@as(?i64, 1200), t.nextWake());
    try testing.expect(step(&t, &f, 1200));
    try testing.expect(t.visible());
    try testing.expectEqual(@as(?i64, null), t.nextWake());
    // Open with no key: no more wakes, and nothing out of date.
    try testing.expect(!step(&t, &f, 99999));
    try testing.expect(t.visible());
}

test "delay: a faster key skips the popup" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var t: Timer = .{};
    try f.press("ctrl+a", 0);
    _ = step(&t, &f, 0);
    // A prefix key restarts the wait.
    try f.press("v", 150);
    try testing.expect(!step(&t, &f, 150));
    try testing.expectEqual(@as(?i64, 350), t.nextWake());
    // A binding ends leader mode before it is due.
    try f.press("s", 300);
    try testing.expect(!step(&t, &f, 300));
    try testing.expect(!t.visible());
    try testing.expectEqual(@as(?i64, null), t.nextWake());
    try testing.expect(!step(&t, &f, 1000));
    try testing.expect(!t.visible());
}

test "delay: 0 shows it at once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.settings.popup_delay_ms = 0;
    var t: Timer = .{};
    try f.press("ctrl+a", 5);
    try testing.expect(step(&t, &f, 5));
    try testing.expect(t.visible());
    try testing.expectEqual(@as(?i64, null), t.nextWake());
}

test "open, it stays up across levels and goes when leader mode ends" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var t: Timer = .{};
    try f.press("ctrl+a", 0);
    _ = step(&t, &f, 0);
    try testing.expect(step(&t, &f, 200));
    // Down and back up: out of date each time, never hidden, no new wait.
    try f.press("v", 500);
    try testing.expect(step(&t, &f, 500));
    try testing.expect(t.visible());
    try testing.expectEqual(@as(?i64, null), t.nextWake());
    try f.press("backspace", 600);
    try testing.expect(step(&t, &f, 600));
    try testing.expect(t.visible());
    try f.press("esc", 700);
    try testing.expect(step(&t, &f, 700));
    try testing.expect(!t.visible());
    // The next leader waits again.
    try f.press("ctrl+a", 800);
    try testing.expect(!step(&t, &f, 800));
    try testing.expectEqual(@as(?i64, 1000), t.nextWake());
}

test "leader mode ended without a key: the next sync takes the popup down" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.settings.timeout_ms = 1000;
    var t: Timer = .{};
    try f.press("ctrl+a", 0);
    _ = step(&t, &f, 0);
    try testing.expect(step(&t, &f, 200));
    try testing.expect(t.visible());

    // `tick`: the timeout, which no key caused.
    try testing.expect(!f.router.tick(999));
    try testing.expect(!step(&t, &f, 999));
    try testing.expect(t.visible());
    try testing.expect(f.router.tick(1000));
    try testing.expect(step(&t, &f, 1000));
    try testing.expect(!t.visible());
    try testing.expectEqual(@as(?i64, null), t.nextWake());

    // `end`: a client leaving leader mode, say on a keymap reload.
    try f.press("ctrl+a", 2000);
    _ = step(&t, &f, 2000);
    try testing.expect(step(&t, &f, 2200));
    f.router.end();
    try testing.expect(step(&t, &f, 2300));
    try testing.expect(!t.visible());

    // `lock`, with the wait still running: it never comes up.
    try f.press("ctrl+a", 3000);
    _ = step(&t, &f, 3000);
    f.router.lock();
    try testing.expect(!step(&t, &f, 3100));
    try testing.expectEqual(@as(?i64, null), t.nextWake());
    try testing.expect(!step(&t, &f, 3300));
    try testing.expect(!t.visible());
}

test "sticky group: hides after a binding, `?` shows it at once, another binding hides it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var t: Timer = .{};
    try f.press("ctrl+a", 0);
    _ = step(&t, &f, 0);
    try f.press("[", 10);
    _ = step(&t, &f, 10);
    try testing.expect(step(&t, &f, 210));
    try testing.expect(t.visible());

    try f.press("j", 300);
    try testing.expect(step(&t, &f, 300));
    try testing.expect(!t.visible());
    try testing.expectEqual(@as(?i64, null), t.nextWake());
    try f.press("k", 400);
    try testing.expect(!step(&t, &f, 400));
    try testing.expect(!t.visible());

    try f.press("?", 500);
    try testing.expect(step(&t, &f, 500));
    try testing.expect(t.visible());
    // Calling again is not another `?`.
    try testing.expect(!step(&t, &f, 501));

    try f.press("j", 600);
    try testing.expect(step(&t, &f, 600));
    try testing.expect(!t.visible());

    // Hidden, then up a level: an ordinary wait.
    try f.press("backspace", 700);
    try testing.expect(!step(&t, &f, 700));
    try testing.expect(!t.visible());
    try testing.expectEqual(@as(?i64, 900), t.nextWake());
}

test "sticky group: a binding before the delay cancels the wait" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var t: Timer = .{};
    try f.press("ctrl+a", 0);
    _ = step(&t, &f, 0);
    try f.press("[", 10);
    _ = step(&t, &f, 10);
    try f.press("j", 20);
    _ = step(&t, &f, 20);
    try testing.expectEqual(@as(?i64, null), t.nextWake());
    try testing.expect(!step(&t, &f, 500));
    try testing.expect(!t.visible());
}
