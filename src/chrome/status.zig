//! Status line, client side, with its segment sources and
//! layout: segment roles and their glyphs, the `status` config
//! (`.left`/`.center`/`.right` lists, `.unlisted`, `.segments`), the item
//! list a client builds (built-ins, visible shared segments and the
//! client-evaluated `static`, `template` and `group` sources), and the
//! layout with a centre that never overlaps either side. Templates are
//! `template`. Content is shared between clients; layout
//! depends only on each client's width.
const std = @import("std");
const cells_mod = @import("cells.zig");
const tags = @import("tags.zig");
pub const cell_width = cells_mod;
pub const template = @import("status_template.zig");

pub const Side = enum { left, center, right };
pub const Style = enum { normal, muted, accent, ok, warn, @"error" };
/// Attention levels and notification levels.
pub const Level = enum { none, info, warn, urgent };
pub const NotifyLevel = enum { info, warn, urgent };

/// Brand glyph per style, so state never depends on colour alone.
pub fn glyph(style: Style) []const u8 {
    return switch (style) {
        .normal => "",
        .muted => "○",
        .accent => "◆",
        .ok => "●",
        .warn => "▲",
        .@"error" => "✕",
    };
}
pub fn levelStyle(level: Level) Style {
    return switch (level) {
        .none => .normal,
        .info => .accent,
        .warn => .warn,
        .urgent => .@"error",
    };
}
pub fn notifyStyle(level: NotifyLevel) Style {
    return switch (level) {
        .info => .accent,
        .warn => .warn,
        .urgent => .@"error",
    };
}

// ---------------------------------------------------------------- config

/// Click target: a binding target as defined for
/// keys (`.local`, `.verb` with `.args`, or `.exec`).
pub const Click = struct {
    local: ?[]const u8 = null,
    verb: ?[]const u8 = null,
    /// A JSON object written as a string, as for key bindings.
    args: ?[]const u8 = null,
    exec: ?[]const []const u8 = null,
};
/// Rule source. Evaluated by the daemon; carried here so the
/// config type is complete.
pub const Rule = struct {
    pub const Op = enum { eq, ne, prefix };
    pub const Match = struct { key: []const u8 = "", op: Op = .eq, value: []const u8 = "" };
    on: []const []const u8 = &.{},
    match: []const Match = &.{},
    clear_on: []const []const u8 = &.{},
};
/// Exec source. Run by the daemon.
pub const Exec = struct {
    argv: []const []const u8 = &.{},
    every_ms: ?u32 = null,
};
pub const Panes = enum { all, focused };
pub const Source = enum { static, template, rule, exec, group };

/// A `status.segments` entry: slot fields, which override the
/// product's values when set, and at most one source field. An entry with
/// no source is a slot override.
pub const Segment = struct {
    id: []const u8 = "",
    side: ?Side = null,
    priority: ?u8 = null,
    style: ?Style = null,
    when: []const tags.Tag = &.{},
    scope: ?[]const u8 = null,
    show: ?bool = null,
    group: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    click: ?Click = null,
    ttl_ms: ?u32 = null,
    /// `static` source, or a `rule`'s and a templatable built-in's template.
    text: ?[]const u8 = null,
    format: ?[]const u8 = null,
    /// `venomx.panes` only.
    panes: ?Panes = null,
    rule: ?Rule = null,
    exec: ?Exec = null,
    group_of: ?[]const u8 = null,

    /// Number of source fields set. `.format` only counts without a rule,
    /// since a rule renders its own `.format`.
    pub fn sourceCount(self: Segment) usize {
        var n: usize = 0;
        if (self.text != null) n += 1;
        if (self.format != null and self.rule == null) n += 1;
        if (self.rule != null) n += 1;
        if (self.exec != null) n += 1;
        if (self.group_of != null) n += 1;
        return n;
    }
    pub fn source(self: Segment) ?Source {
        if (self.sourceCount() != 1) return null;
        if (self.text != null) return .static;
        if (self.rule != null) return .rule;
        if (self.format != null) return .template;
        if (self.exec != null) return .exec;
        return .group;
    }
};

/// Built-ins, in their default list order.
pub const default_left = [_][]const u8{ "venomx.session", "venomx.nested", "venomx.mode", "venomx.windows", "venomx.panes", "venomx.pane" };
pub const default_right = [_][]const u8{ "venomx.message", "venomx.notify", "venomx.tray", "venomx.attention", "venomx.clock" };

/// `status` config as a client reads it (`config.get --key status`).
/// Per-segment priorities replace the older `hide` and `priority` keys. The daemon's
/// config schema adds its own checks (rules, exec, grants) on top.
pub const Config = struct {
    pub const Position = enum { top, bottom, off };
    pub const Unlisted = enum { show, hide };
    position: Position = .top,
    left: []const []const u8 = &default_left,
    center: []const []const u8 = &.{},
    right: []const []const u8 = &default_right,
    unlisted: Unlisted = .show,
    segments: []const Segment = &.{},

    /// The config entry for `id`, if any.
    pub fn segment(self: Config, id: []const u8) ?Segment {
        for (self.segments) |s| if (std.mem.eql(u8, s.id, id)) return s;
        return null;
    }
    /// The configured template of a templatable built-in, if any.
    pub fn format(self: Config, id: []const u8) ?[]const u8 {
        return if (self.segment(id)) |s| s.format else null;
    }
    pub const Listed = struct { side: Side, index: u16 };
    /// Where `id` is listed, if it is.
    pub fn listed(self: Config, id: []const u8) ?Listed {
        for ([_]Side{ .left, .center, .right }) |side| {
            for (self.list(side), 0..) |l, i| if (std.mem.eql(u8, l, id)) return .{ .side = side, .index = @intCast(i) };
        }
        return null;
    }
    pub fn list(self: Config, side: Side) []const []const u8 {
        return switch (side) {
            .left => self.left,
            .center => self.center,
            .right => self.right,
        };
    }

    pub const Failure = struct {
        pub const Code = enum { status_layout, segment, template };
        /// `invalid_params.<code>`.
        code: Code,
        /// The segment id at fault.
        id: []const u8,
        /// For `template`: where in its `.format`, and what is wrong.
        template: ?template.Failure = null,
    };
    /// The client-side `config check`: ids listed twice or on two
    /// sides, `user.*` entries without exactly one source, entries with
    /// more than one source, bad group names or icons, and templates.
    pub fn check(self: Config, a: std.mem.Allocator) error{OutOfMemory}!?Failure {
        for ([_]Side{ .left, .center, .right }) |side| for (self.list(side), 0..) |id, i| {
            const at = self.listed(id).?;
            if (at.side != side or at.index != i) return .{ .code = .status_layout, .id = id };
        };
        for (self.segments, 0..) |s, i| {
            for (self.segments[0..i]) |prev| if (std.mem.eql(u8, prev.id, s.id)) return .{ .code = .segment, .id = s.id };
            const n = s.sourceCount();
            if (n > 1 or (n == 0 and std.mem.startsWith(u8, s.id, "user."))) return .{ .code = .segment, .id = s.id };
            if (n == 1 and s.format == null and !std.mem.startsWith(u8, s.id, "user.")) return .{ .code = .segment, .id = s.id };
            if (s.group) |g| if (!validGroup(g)) return .{ .code = .segment, .id = s.id };
            if (s.group_of) |g| if (!validGroup(g)) return .{ .code = .segment, .id = s.id };
            if (s.icon) |icon| if (!validIcon(icon)) return .{ .code = .segment, .id = s.id };
            if (s.priority) |p| if (p > 100) return .{ .code = .segment, .id = s.id };
            if (s.format) |f| {
                if (try template.check(a, f, if (s.rule != null) .rule else .segment)) |t| return .{ .code = .template, .id = s.id, .template = t };
            }
        }
        return null;
    }
};

/// `[a-z][a-z0-9-]{0,31}`.
pub fn validGroup(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or !std.ascii.isLower(name[0])) return false;
    for (name[1..]) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-')) return false;
    return true;
}
/// UTF-8 of at most 2 cells, no controls.
pub fn validIcon(icon: []const u8) bool {
    return tags.validText(icon, 1, 32) and width(icon) <= 2;
}

/// `attention` config. `sticky` keeps attention when a client focuses
/// the pane. `from_bell` lets a BEL, or an OSC 7501 report that moves a
/// record to `blocked`, set `info` attention on a pane without any.
pub const AttentionConfig = struct {
    sticky: bool = false,
    from_bell: bool = true,
    pub fn check(_: AttentionConfig) !void {}
};

// ----------------------------------------------------------------- items

/// One drawable segment. `order` is its index in its side's list; unlisted
/// items (null) follow the listed ones by priority, then id. A group item
/// has `members` (in priority order) and draws them instead of `text`.
pub const Item = struct {
    id: []const u8,
    text: []const u8,
    side: Side,
    priority: u8,
    style: Style,
    order: ?u16 = null,
    members: []const Member = &.{},
};
/// A group member: its `icon`, or its glyphed text when it has none.
pub const Member = struct { id: []const u8, text: []const u8, priority: u8, style: Style };
/// Where a group member landed, for clicks.
pub const Span = struct { id: []const u8, x: u16, width: u16 };
pub const Placed = struct {
    id: []const u8,
    text: []const u8,
    side: Side,
    style: Style,
    x: u16,
    members: []const Span = &.{},
};
pub const separator = " │ ";
pub const separator_width = 3;
pub const member_separator = " ";

/// Display width in terminal cells, keeping combining and emoji clusters whole.
pub fn width(text: []const u8) usize {
    var it: cells_mod.Iterator = .{ .text = text };
    var total: usize = 0;
    while (it.next()) |g| total += g.width;
    return total;
}

/// What a product hands the builder for one segment.
pub const Input = struct {
    id: []const u8,
    text: []const u8 = "",
    side: Side = .right,
    priority: u8 = 50,
    style: Style = .normal,
    /// Drawn inside that group instead of on its own.
    group: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    /// This segment is a group and draws the members of that group.
    group_of: ?[]const u8 = null,
};

/// Collects a client's status items: the product's built-ins and shared
/// segments (`add`, `addSegment`), plus the config's own `user.*` static,
/// template and group sources (`addConfigured`). `items` applies the
/// config's slot overrides, `.show`, the lists and `.unlisted`, fills
/// groups and drops empty ones, and prefixes each text by its style's
/// glyph. Allocates in `a` (an arena).
pub const Builder = struct {
    a: std.mem.Allocator,
    config: Config = .{},
    /// Ids that `toggle-segment` flipped on this client.
    toggled: []const []const u8 = &.{},
    /// The tags of the client's focused pane, for a config entry's `.when`;
    /// null while no pane is focused, which hides it.
    focused_tags: ?[]const tags.Tag = null,
    out: std.ArrayList(Input) = .empty,

    pub fn add(self: *Builder, id: []const u8, text: []const u8, side: Side, priority: u8, style: Style) !void {
        try self.addSegment(.{ .id = id, .text = text, .side = side, .priority = priority, .style = style });
    }
    pub fn addSegment(self: *Builder, in: Input) !void {
        try self.out.append(self.a, in);
    }
    /// Add the config's `user.*` entries with a `static`, `template` or
    /// `group` source. Templates render through `lookup`; one that doesn't
    /// parse is skipped (`Config.check` reports it).
    pub fn addConfigured(self: *Builder, lookup: template.Lookup) !void {
        for (self.config.segments) |s| {
            if (!std.mem.startsWith(u8, s.id, "user.")) continue;
            const src = s.source() orelse continue;
            const in: Input = .{ .id = s.id, .side = s.side orelse .right, .priority = s.priority orelse 50, .style = s.style orelse .normal };
            switch (src) {
                .static => try self.addSegment(withText(in, s.text.?)),
                .template => if (try template.renderSource(self.a, s.format.?, .segment, lookup)) |t| try self.addSegment(withText(in, t)),
                .group => {
                    var g = in;
                    g.group_of = s.group_of;
                    try self.addSegment(g);
                },
                .rule, .exec => {},
            }
        }
    }
    fn withText(in: Input, text: []const u8) Input {
        var out = in;
        out.text = text;
        return out;
    }

    fn visible(self: *const Builder, id: []const u8, show: bool) bool {
        var v = show;
        for (self.toggled) |t| if (std.mem.eql(u8, t, id)) {
            v = !v;
        };
        return v;
    }
    /// A config entry's `.when` holds on the focused pane; true without one.
    /// A toggle never shows a segment its `.when` hides.
    fn whenHolds(self: *const Builder, id: []const u8) bool {
        const s = self.config.segment(id) orelse return true;
        if (s.when.len == 0) return true;
        return tags.matches(self.focused_tags orelse return false, s.when);
    }
    fn glyphed(self: *const Builder, text: []const u8, style: Style) ![]const u8 {
        const g = glyph(style);
        return if (g.len > 0) try std.fmt.allocPrint(self.a, "{s} {s}", .{ g, text }) else text;
    }

    /// The resolved item list, in the order added.
    pub fn items(self: *const Builder) ![]Item {
        // Apply the config's slot overrides first.
        const resolved = try self.a.alloc(Input, self.out.items.len);
        const shown = try self.a.alloc(bool, self.out.items.len);
        for (self.out.items, resolved, shown) |in, *r, *v| {
            r.* = in;
            v.* = true;
            if (self.config.segment(in.id)) |s| {
                if (s.side) |x| r.side = x;
                if (s.priority) |x| r.priority = x;
                if (s.style) |x| r.style = x;
                if (s.group) |x| r.group = x;
                if (s.icon) |x| r.icon = x;
                if (s.show) |x| v.* = x;
            }
            v.* = self.visible(in.id, v.*) and self.whenHolds(in.id);
        }
        var out: std.ArrayList(Item) = .empty;
        for (resolved, shown) |r, v| {
            if (!v or r.group != null) continue;
            var item: Item = .{ .id = r.id, .text = "", .side = r.side, .priority = r.priority, .style = r.style };
            if (self.config.listed(r.id)) |at| {
                item.side = at.side;
                item.order = at.index;
            } else if (self.config.unlisted == .hide) continue;
            if (r.group_of) |name| {
                var members: std.ArrayList(Member) = .empty;
                for (resolved, shown) |m, mv| {
                    if (!mv or m.group == null or !std.mem.eql(u8, m.group.?, name)) continue;
                    const text = if (m.icon) |icon| icon else if (m.text.len > 0) try self.glyphed(m.text, m.style) else continue;
                    try members.append(self.a, .{ .id = m.id, .text = text, .priority = m.priority, .style = m.style });
                }
                if (members.items.len == 0) continue;
                std.mem.sort(Member, members.items, {}, memberLess);
                item.members = members.items;
                item.text = try joinMembers(self.a, members.items);
            } else {
                if (r.text.len == 0) continue;
                item.text = try self.glyphed(r.text, r.style);
            }
            try out.append(self.a, item);
        }
        return out.items;
    }
};

fn memberLess(_: void, x: Member, y: Member) bool {
    if (x.priority != y.priority) return x.priority > y.priority;
    return std.mem.lessThan(u8, x.id, y.id);
}
fn joinMembers(a: std.mem.Allocator, members: []const Member) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (members, 0..) |m, i| {
        if (i > 0) try out.appendSlice(a, member_separator);
        try out.appendSlice(a, m.text);
    }
    return out.items;
}

// ---------------------------------------------------------------- layout

fn priorityLess(_: void, x: Item, y: Item) bool {
    if (x.priority != y.priority) return x.priority > y.priority;
    return std.mem.lessThan(u8, x.id, y.id);
}
fn drawLess(_: void, x: Placing, y: Placing) bool {
    if (x.item.side != y.item.side) return @backingInt(x.item.side) < @backingInt(y.item.side);
    const xo = x.item.order orelse std.math.maxInt(u16);
    const yo = y.item.order orelse std.math.maxInt(u16);
    if (xo != yo) return xo < yo;
    return priorityLess({}, x.item, y.item);
}
const Placing = struct { item: Item, text: []const u8, members: usize };

/// Width needed by sides of widths `w` and counts `n`: one blank column
/// between neighbouring non-empty sides.
fn need(w: [3]usize, n: [3]usize) usize {
    var sides: usize = 0;
    for (n) |c| if (c > 0) {
        sides += 1;
    };
    return w[0] + w[1] + w[2] + (sides -| 1);
}

fn truncate(a: std.mem.Allocator, text: []const u8, room: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it: cells_mod.Iterator = .{ .text = text };
    var n: usize = 0;
    while (it.next()) |g| {
        if (n + g.width + 1 > room) break;
        try out.appendSlice(a, g.text);
        n += g.width;
    }
    try out.appendSlice(a, "…");
    return out.items;
}

/// Decide what fits by priority (then id) across all three
/// sides together, dropping the lowest first. A group first drops its
/// lowest-priority members. Only the first segment that doesn't fit
/// may be kept, truncated with `…`; everything of lower priority is
/// dropped. Each side draws in list order (unlisted after, by priority):
/// left from column 0, right flush with the last column, and the centre
/// at the middle, pushed sideways just enough to keep one blank column
/// from either side. Text is allocated in `a` (an arena); the result is
/// left, centre, then right, each in drawing order.
pub fn layout(a: std.mem.Allocator, input: []const Item, cols: u16) ![]Placed {
    const sorted = try a.dupe(Item, input);
    std.mem.sort(Item, sorted, {}, priorityLess);
    var kept: std.ArrayList(Placing) = .empty;
    var w = [3]usize{ 0, 0, 0 };
    var n = [3]usize{ 0, 0, 0 };
    outer: for (sorted) |item| {
        if (item.text.len == 0 and item.members.len == 0) continue;
        const s = @backingInt(item.side);
        const sep: usize = if (n[s] > 0) separator_width else 0;
        var count = item.members.len;
        while (true) {
            const text = if (item.members.len > 0) try joinMembers(a, item.members[0..count]) else item.text;
            var tw = w;
            var tn = n;
            tw[s] += sep + width(text);
            tn[s] += 1;
            if (need(tw, tn) <= cols) {
                try kept.append(a, .{ .item = item, .text = text, .members = count });
                w = tw;
                n = tn;
                continue :outer;
            }
            if (count <= 1) {
                tw[s] -= width(text);
                const room = @as(usize, cols) -| need(tw, tn);
                if (room >= 2) {
                    const cut = try truncate(a, text, room);
                    try kept.append(a, .{ .item = item, .text = cut, .members = count });
                    w[s] += sep + width(cut);
                    n[s] += 1;
                }
                break :outer;
            }
            count -= 1;
        }
    }
    std.mem.sort(Placing, kept.items, {}, drawLess);
    const placed = try a.alloc(Placed, kept.items.len);
    var x = [3]usize{ 0, 0, @as(usize, cols) -| w[2] };
    {
        const lo: usize = if (n[0] > 0) w[0] + 1 else 0;
        const hi: usize = @as(usize, cols) -| (w[1] + if (n[2] > 0) w[2] + 1 else 0);
        x[1] = std.math.clamp((@as(usize, cols) -| w[1]) / 2, lo, @max(lo, hi));
    }
    var first = [3]bool{ true, true, true };
    for (kept.items, placed) |k, *p| {
        const s = @backingInt(k.item.side);
        if (!first[s]) x[s] += separator_width;
        first[s] = false;
        p.* = .{ .id = k.item.id, .text = k.text, .side = k.item.side, .style = k.item.style, .x = @intCast(x[s]) };
        if (k.members > 0) p.members = try spans(a, k.item.members[0..k.members], x[s], x[s] + width(k.text));
        x[s] += width(k.text);
    }
    return placed;
}

fn spans(a: std.mem.Allocator, members: []const Member, start: usize, end: usize) ![]const Span {
    var out: std.ArrayList(Span) = .empty;
    var x = start;
    for (members) |m| {
        if (x >= end) break;
        const mw = @min(width(m.text), end - x);
        try out.append(a, .{ .id = m.id, .x = @intCast(x), .width = @intCast(mw) });
        x += mw + member_separator.len;
    }
    return out.items;
}

/// The segment (or group member) drawn at column `col`, for clicks.
pub fn hit(placed: []const Placed, col: u16) ?[]const u8 {
    for (placed) |p| {
        if (col < p.x or col >= p.x + width(p.text)) continue;
        for (p.members) |m| if (col >= m.x and col < m.x + m.width) return m.id;
        return if (p.members.len > 0) null else p.id;
    }
    return null;
}

/// The status line as plain text, `cols` cells wide (no styles): what a
/// user reads, for headless checks and text renderers. Separators sit two
/// columns before each segment after the first of its side.
pub fn render(a: std.mem.Allocator, placed: []const Placed, cols: u16) ![]u8 {
    const cells = try a.alloc([]const u8, cols);
    @memset(cells, " ");
    var started = [3]bool{ false, false, false };
    for (placed) |p| {
        const side = @backingInt(p.side);
        if (started[side] and p.x >= 2 and p.x - 2 < cols) cells[p.x - 2] = "│";
        started[side] = true;
        var it: cells_mod.Iterator = .{ .text = p.text };
        var col: usize = p.x;
        while (it.next()) |g| {
            if (g.width == 0) continue;
            const shown = if (g.invalid) "\u{fffd}" else g.text;
            if (col + g.width > cols) break;
            cells[col] = shown;
            if (g.width == 2) cells[col + 1] = "";
            col += g.width;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (cells) |c| try out.appendSlice(a, c);
    return out.items;
}

const testing = std.testing;
test "layout keeps the highest priorities and truncates only the last placed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = [_]Item{
        .{ .id = "venomx.session", .text = "[s0]", .side = .left, .priority = 100, .style = .normal },
        .{ .id = "venomx.clock", .text = "14:02", .side = .right, .priority = 10, .style = .normal },
        .{ .id = "venom.agents", .text = "▲ 2 running · 1 waiting", .side = .right, .priority = 50, .style = .warn },
        .{ .id = "venomx.windows", .text = "w0* w1", .side = .left, .priority = 90, .style = .normal },
    };
    const wide = try layout(a, &input, 80);
    try testing.expectEqual(@as(usize, 4), wide.len);
    // Right side in priority order, flush right: agents then clock.
    try testing.expectEqualStrings("venom.agents", wide[2].id);
    try testing.expectEqual(@as(u16, 80 - 5 - 3 - 23), wide[2].x);
    try testing.expectEqual(@as(u16, 75), wide[3].x);
    try testing.expectEqual(@as(u16, 7), wide[1].x);
    // 30 columns: session, windows, then agents truncated; the clock is dropped.
    const narrow = try layout(a, &input, 30);
    try testing.expectEqual(@as(usize, 3), narrow.len);
    try testing.expect(std.mem.endsWith(u8, narrow[2].text, "…"));
    try testing.expectEqual(@as(usize, 30 - (4 + 3 + 6) - 1), width(narrow[2].text));
    const line = try render(a, wide, 80);
    try testing.expectEqual(@as(usize, 80), width(line));
    try testing.expect(std.mem.startsWith(u8, line, "[s0] │ w0* w1"));
    try testing.expect(std.mem.endsWith(u8, line, "▲ 2 running · 1 waiting │ 14:02"));
    // Too narrow for anything: nothing placed, nothing out of range.
    try testing.expectEqual(@as(usize, 0), (try layout(a, &input, 1)).len);
}

test "wide status segments occupy disjoint cells on either side" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Side{ .left, .right }) |side| {
        const input = [_]Item{
            .{ .id = "cjk", .text = "中文", .side = .left, .priority = 100, .style = .normal },
            .{ .id = "emoji", .text = "😀👨‍👩‍👧‍👦", .side = side, .priority = 90, .style = .normal },
        };
        const placed = try layout(a, &input, 12);
        try testing.expectEqual(@as(usize, 2), placed.len);
        try testing.expectEqual(@as(usize, 4), width(placed[0].text));
        try testing.expectEqual(@as(usize, 4), width(placed[1].text));
        try testing.expect(placed[0].x + width(placed[0].text) < placed[1].x);
        try testing.expect(placed[1].x + width(placed[1].text) <= 12);
        const line = try render(a, placed, 12);
        try testing.expectEqual(@as(usize, 12), width(line));
        try testing.expect(std.mem.indexOf(u8, line, input[1].text) != null);
    }
}

test "truncation keeps clusters whole and right aligns their actual width" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const samples = [_][]const u8{ "界界界", "😀😀😀", "👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦", "🇩🇪🇩🇪🇩🇪", "❤️❤️❤️", "éééééé" };
    for (samples) |sample| {
        for (2..6) |room| {
            const input = [_]Item{.{ .id = "wide", .text = sample, .side = .right, .priority = 50, .style = .normal }};
            const placed = try layout(a, &input, @intCast(room));
            try testing.expectEqual(@as(usize, 1), placed.len);
            const p = placed[0];
            try testing.expect(width(p.text) <= room);
            try testing.expectEqual(room, p.x + width(p.text));
            try testing.expect(std.mem.endsWith(u8, p.text, "…"));
            const prefix = p.text[0 .. p.text.len - "…".len];
            var it: cells_mod.Iterator = .{ .text = sample };
            while (it.pos < prefix.len) _ = it.next();
            try testing.expectEqual(prefix.len, it.pos);
            try testing.expectEqualStrings(sample[0..it.pos], prefix);
            try testing.expectEqual(room, width(try render(a, placed, @intCast(room))));
        }
    }
}

test "render substitutes invalid bytes and keeps a wide glyph at the last column whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_]Placed{.{ .id = "x", .text = "a\xffb", .side = .left, .style = .normal, .x = 0 }};
    try testing.expectEqualStrings("a\u{fffd}b ", try render(a, &bad, 4));
    // A 2-cell glyph whose second cell is the last column fits; one that would overflow is dropped.
    const fits = [_]Placed{.{ .id = "x", .text = "中", .side = .right, .style = .normal, .x = 2 }};
    const line = try render(a, &fits, 4);
    try testing.expectEqualStrings("  中", line);
    try testing.expectEqual(@as(usize, 4), width(line));
    const over = [_]Placed{.{ .id = "x", .text = "中", .side = .right, .style = .normal, .x = 3 }};
    try testing.expectEqualStrings("    ", try render(a, &over, 4));
}

fn find(placed: []const Placed, id: []const u8) ?Placed {
    for (placed) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

test "builder applies lists, unlisted, show, slot overrides, toggles and glyphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const config: Config = .{
        .left = &.{ "venomx.windows", "venomx.session" },
        .center = &.{"venomx.clock"},
        .right = &.{},
        .segments = &.{
            .{ .id = "venomx.attention", .show = false },
            .{ .id = "user.all", .priority = 70, .side = .left },
            .{ .id = "venom.agents", .style = .warn },
        },
    };
    var b: Builder = .{ .a = arena.allocator(), .config = config, .toggled = &.{"venomx.session"} };
    try b.add("venomx.session", "s0", .left, 100, .normal);
    try b.add("venomx.windows", "1:shell", .left, 90, .normal);
    try b.add("venomx.clock", "14:02", .right, 10, .normal);
    try b.add("venomx.mode", "", .left, 95, .accent);
    try b.add("user.all", "all", .right, 50, .ok);
    try b.add("venom.agents", "2 running", .right, 50, .normal);
    try b.add("venomx.attention", "1 attention", .right, 80, .warn);
    const out = try b.items();
    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expectEqualStrings("venomx.windows", out[0].id);
    try testing.expectEqual(@as(?u16, 0), out[0].order);
    try testing.expectEqual(Side.center, out[1].side);
    try testing.expectEqualStrings("● all", out[2].text);
    try testing.expectEqual(@as(u8, 70), out[2].priority);
    try testing.expectEqual(Side.left, out[2].side);
    try testing.expectEqual(@as(?u16, null), out[2].order);
    try testing.expectEqualStrings("▲ 2 running", out[3].text);

    // `.unlisted = .hide`: only listed ids are drawn.
    var hidden = config;
    hidden.unlisted = .hide;
    b.config = hidden;
    b.toggled = &.{};
    const listed = try b.items();
    try testing.expectEqual(@as(usize, 3), listed.len);
    try testing.expectEqual(@as(?Config.Listed, .{ .side = .left, .index = 1 }), hidden.listed("venomx.session"));
    try testing.expectEqual(Style.@"error", levelStyle(.urgent));
    try testing.expectEqual(Style.accent, notifyStyle(.info));
}

test "a config .when hides a segment unless the focused pane has its tags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const prod: []const tags.Tag = &.{.{ .key = "env", .value = "prod" }};
    const config: Config = .{ .segments = &.{
        .{ .id = "user.prod", .text = "PROD", .when = prod },
        .{ .id = "venomx.clock", .when = prod },
    } };
    var b: Builder = .{ .a = arena.allocator(), .config = config };
    try b.addConfigured(.{});
    try b.add("venomx.clock", "14:02", .right, 10, .normal);
    try b.add("venomx.session", "s0", .left, 100, .normal);

    // No focused pane: both `.when` entries are hidden, the rest is drawn.
    try testing.expectEqual(@as(usize, 1), (try b.items()).len);
    // A focused pane without the tag, then with it among others.
    b.focused_tags = &.{.{ .key = "env", .value = "dev" }};
    try testing.expectEqual(@as(usize, 1), (try b.items()).len);
    b.focused_tags = &.{ .{ .key = "owner", .value = "user" }, .{ .key = "env", .value = "prod" } };
    const shown = try b.items();
    try testing.expectEqual(@as(usize, 3), shown.len);
    try testing.expect(hasItem(shown, "user.prod"));
    try testing.expect(hasItem(shown, "venomx.clock"));
    // A toggle cannot show what `.when` hides.
    b.focused_tags = &.{};
    b.toggled = &.{"user.prod"};
    try testing.expect(!hasItem(try b.items(), "user.prod"));
}

fn hasItem(items: []const Item, id: []const u8) bool {
    for (items) |i| if (std.mem.eql(u8, i.id, id)) return true;
    return false;
}

test "the default lists put the built-ins in their documented order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Builder = .{ .a = a };
    try b.add("venomx.clock", "14:02", .right, 10, .normal);
    try b.add("venomx.message", "hi", .right, 99, .normal);
    try b.add("venomx.windows", "1:shell", .left, 90, .normal);
    try b.add("venomx.session", "work", .left, 100, .normal);
    try b.add("venom.agents", "agents", .right, 70, .normal);
    const line = try render(a, try layout(a, try b.items(), 60), 60);
    try testing.expect(std.mem.startsWith(u8, line, "work │ 1:shell "));
    try testing.expect(std.mem.endsWith(u8, line, "hi │ 14:02 │ agents"));
}

test "pushed tray members draw as icons inside venomx.tray" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Builder = .{ .a = a };
    try b.add("venomx.session", "work", .left, 100, .normal);
    try b.addSegment(.{ .id = "venomx.tray", .group_of = "tray", .priority = 60 });
    try b.addSegment(.{ .id = "venom-os.wifi", .text = "wifi", .icon = "📶", .group = "tray", .priority = 40 });
    try b.addSegment(.{ .id = "user.battery", .text = "81%", .group = "tray", .priority = 50, .style = .ok });
    const items = try b.items();
    try testing.expectEqual(@as(usize, 2), items.len);
    const tray = items[1];
    try testing.expectEqualStrings("venomx.tray", tray.id);
    try testing.expectEqualStrings("● 81% 📶", tray.text);
    const placed = try layout(a, items, 40);
    const p = find(placed, "venomx.tray").?;
    try testing.expectEqual(@as(usize, 2), p.members.len);
    try testing.expectEqualStrings("user.battery", hit(placed, p.x).?);
    try testing.expectEqualStrings("venom-os.wifi", hit(placed, p.x + 6).?);
    try testing.expectEqual(@as(?[]const u8, null), hit(placed, p.x + 5));
    try testing.expectEqualStrings("venomx.session", hit(placed, 0).?);
    // Short line: the group drops its lowest-priority member before itself.
    const short = try layout(a, items, 12);
    try testing.expectEqualStrings("● 81%", find(short, "venomx.tray").?.text);
    // Both members cleared: the tray is not drawn.
    var empty: Builder = .{ .a = a };
    try empty.addSegment(.{ .id = "venomx.tray", .group_of = "tray", .priority = 60 });
    try empty.addSegment(.{ .id = "venom-os.wifi", .text = "", .group = "tray" });
    try testing.expectEqual(@as(usize, 0), (try empty.items()).len);
    // A config override can move a segment into a group, and define a group.
    var moved: Builder = .{ .a = a, .config = .{ .segments = &.{
        .{ .id = "venom.agents", .group = "sys", .icon = "A" },
        .{ .id = "user.sys", .group_of = "sys", .side = .left },
        .{ .id = "user.host", .text = "devbox", .priority = 20 },
        .{ .id = "user.where", .format = "{host}[@{user}]" },
    } } };
    const pairs: []const template.Pair = &.{.{ "host", "devbox" }};
    try moved.addConfigured(template.pairs(&pairs, null));
    try moved.add("venom.agents", "2 running", .right, 70, .normal);
    const m = try moved.items();
    try testing.expectEqual(@as(usize, 3), m.len);
    try testing.expectEqualStrings("A", m[0].text);
    try testing.expectEqualStrings("devbox", m[1].text);
    try testing.expectEqualStrings("devbox", m[2].text);
}

test "on 80 columns all three sides drop together and the centre never overlaps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = [_]Item{
        .{ .id = "l.a", .text = "left-one", .side = .left, .priority = 100, .style = .normal, .order = 0 },
        .{ .id = "l.b", .text = "a-long-left-segment-text", .side = .left, .priority = 30, .style = .normal, .order = 1 },
        .{ .id = "c.a", .text = "Thu 12 14:02", .side = .center, .priority = 90, .style = .normal, .order = 0 },
        .{ .id = "c.b", .text = "centre-extra", .side = .center, .priority = 20, .style = .normal, .order = 1 },
        .{ .id = "r.a", .text = "right-one", .side = .right, .priority = 95, .style = .normal, .order = 0 },
        .{ .id = "r.b", .text = "a-long-right-segment-text", .side = .right, .priority = 40, .style = .normal, .order = 1 },
    };
    for ([_]u16{ 200, 80, 60, 40, 30, 20 }) |cols| {
        const placed = try layout(a, &input, cols);
        // Kept ids are always the highest priorities, whatever their side.
        var kept_min: u8 = 255;
        for (placed) |p| {
            for (input) |i| if (std.mem.eql(u8, i.id, p.id)) {
                kept_min = @min(kept_min, i.priority);
            };
        }
        for (input) |i| if (i.priority > kept_min) try testing.expect(find(placed, i.id) != null);
        // Segments occupy disjoint cells, with a blank column between sides.
        for (placed, 0..) |p, i| {
            try testing.expect(p.x + width(p.text) <= cols);
            for (placed[i + 1 ..]) |q| {
                const gap: usize = if (p.side == q.side) 0 else 1;
                try testing.expect(p.x + width(p.text) + gap <= q.x or q.x + width(q.text) + gap <= p.x);
            }
        }
        try testing.expectEqual(@as(usize, cols), width(try render(a, placed, cols)));
    }
    // 80 columns: the lowest of each side go first: c.b (20), l.b (30) truncated.
    const at80 = try layout(a, &input, 80);
    try testing.expect(find(at80, "c.b") == null);
    try testing.expect(find(at80, "r.b") != null);
    try testing.expect(std.mem.endsWith(u8, find(at80, "l.b").?.text, "…"));
    // With room the centre sits at the middle.
    const wide = try layout(a, input[2..3], 80);
    try testing.expectEqual(@as(u16, (80 - 12) / 2), wide[0].x);
    // A long left side pushes the centre right, one blank column after it.
    const pushed = [_]Item{
        .{ .id = "l", .text = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", .side = .left, .priority = 100, .style = .normal },
        .{ .id = "c", .text = "centre", .side = .center, .priority = 90, .style = .normal },
        .{ .id = "r", .text = "right", .side = .right, .priority = 80, .style = .normal },
    };
    const p = try layout(a, &pushed, 80);
    try testing.expectEqual(@as(u16, 41), find(p, "c").?.x);
    try testing.expectEqual(@as(u16, 75), find(p, "r").?.x);
    const line = try render(a, p, 80);
    try testing.expect(std.mem.indexOf(u8, line, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++ " centre") != null);
}

test "config check: layout duplicates, sources and templates" {
    const ok: Config = .{ .segments = &.{
        .{ .id = "venomx.clock", .format = "{clock:%a %H:%M}" },
        .{ .id = "user.host", .text = "devbox" },
        .{ .id = "user.failed", .rule = .{ .on = &.{"command.finished"} }, .format = "{event.command} {event.exit_code}" },
        .{ .id = "venom.agents", .priority = 70 },
    } };
    try testing.expectEqual(@as(?Config.Failure, null), try ok.check(testing.allocator));
    const twice: Config = .{ .left = &.{ "venomx.session", "venomx.clock" }, .right = &.{"venomx.clock"} };
    try testing.expectEqual(Config.Failure.Code.status_layout, (try twice.check(testing.allocator)).?.code);
    const no_source: Config = .{ .segments = &.{.{ .id = "user.x", .priority = 3 }} };
    try testing.expectEqual(Config.Failure.Code.segment, (try no_source.check(testing.allocator)).?.code);
    const two: Config = .{ .segments = &.{.{ .id = "user.x", .text = "a", .format = "b" }} };
    try testing.expectEqual(Config.Failure.Code.segment, (try two.check(testing.allocator)).?.code);
    const foreign: Config = .{ .segments = &.{.{ .id = "venom.x", .text = "a" }} };
    try testing.expectEqual(Config.Failure.Code.segment, (try foreign.check(testing.allocator)).?.code);
    const icon: Config = .{ .segments = &.{.{ .id = "venom.x", .icon = "abc" }} };
    try testing.expectEqual(Config.Failure.Code.segment, (try icon.check(testing.allocator)).?.code);
    const bad: Config = .{ .segments = &.{.{ .id = "user.x", .format = "{pane.nope}" }} };
    const f = (try bad.check(testing.allocator)).?;
    try testing.expectEqual(Config.Failure.Code.template, f.code);
    try testing.expectEqual(template.Reason.unknown_variable, f.template.?.reason);
    try testing.expectEqual(@as(usize, 1), f.template.?.offset);
}

test "status config parses from ZON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\.{ .position = .bottom, .left = .{ "venomx.session" }, .center = .{ "venomx.clock" }, .right = .{ "venomx.tray" }, .unlisted = .hide,
        \\   .segments = .{ .{ .id = "venomx.clock", .format = "{clock:%a %d %H:%M}" },
        \\                  .{ .id = "user.battery", .exec = .{ .argv = .{ "bat", "--short" }, .every_ms = 30000 }, .group = "tray" },
        \\                  .{ .id = "venom.agents", .priority = 70, .click = .{ .verb = "pane.popup", .args = "{}" } } } }
    ;
    const a = arena.allocator();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const c = try std.zon.parse.fromSlice(Config, .{ .gpa = a, .arena = a, .source = source, .diagnostics = &diagnostics });
    try testing.expectEqual(Config.Position.bottom, c.position);
    try testing.expectEqual(@as(usize, 1), c.right.len);
    try testing.expectEqualStrings("{clock:%a %d %H:%M}", c.format("venomx.clock").?);
    try testing.expectEqual(Source.exec, c.segment("user.battery").?.source().?);
    try testing.expectEqual(@as(?Config.Failure, null), try c.check(testing.allocator));
}
