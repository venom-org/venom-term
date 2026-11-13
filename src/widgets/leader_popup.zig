//! The leader popup: an overlay at the bottom of a region, with a
//! header and columns of rows. `chrome.leader_popup` says what it shows and
//! when; this draws it. It keeps no state and reads no router.
const std = @import("std");
const types = @import("types");
const chrome = @import("chrome");
const Region = types.Region;
const Surface = @import("../surface.zig").Surface;
const Theme = @import("theme.zig").Theme;
const Role = @import("theme.zig").Role;
const box = @import("box.zig");
const text = @import("text.zig");
const Model = chrome.leader_popup.Model;
const Row = chrome.leader_popup.Row;

pub const Options = struct {
    /// Rows per column before the popup prefers another column. It goes taller
    /// only when the width allows nothing shorter.
    max_rows: u16 = 6,
};

/// Where the popup goes and how it is cut up.
pub const Placement = struct {
    /// Everything the popup covers. A client that patches panes row by row must
    /// not patch under it.
    outer: Region = .{ .width = 0, .height = 0 },
    /// Has a border and header; a region under 3 rows or 6 columns has neither.
    framed: bool = false,
    columns: usize = 0,
    per_column: usize = 0,
    /// How many rows are shown.
    shown: usize = 0,
    /// Not every row fits: the slot after the last one shows `…`.
    truncated: bool = false,
};

const gap = 2;
/// Labels are capped at 40 bytes, but an unlabelled `exec` shows `argv[0]`, and
/// one long path should not take the whole popup.
const max_label = chrome.keys.max_label;

const Column = struct {
    key: usize = 0,
    label: usize = 0,
    more: bool = false,

    fn of(rows: []const Row) Column {
        var c: Column = .{};
        for (rows) |r| {
            c.key = @max(c.key, text.width(r.keys));
            c.label = @max(c.label, @min(text.width(r.label), max_label));
            c.more = c.more or r.more;
        }
        return c;
    }
    /// `h ←  label`, or `a + label` in a column that has a group.
    fn slot(self: Column) usize {
        return if (self.more) 3 else 2;
    }
    fn width(self: Column) usize {
        return self.key + self.slot() + self.label;
    }
};

/// The rows of column `c`.
fn columnRows(rows: []const Row, per: usize, c: usize) []const Row {
    const start = @min(c * per, rows.len);
    return rows[start..@min(start + per, rows.len)];
}
/// Columns of `per` rows, plus the `…` slot when `ellipsis`.
fn contentWidth(rows: []const Row, per: usize, ellipsis: bool) usize {
    var total: usize = 0;
    var c: usize = 0;
    while (c * per < rows.len) : (c += 1) {
        if (c > 0) total += gap;
        const col = Column.of(columnRows(rows, per, c));
        // The `…` sits under this column.
        total += if (ellipsis and c * per + per > rows.len) @max(col.width(), 1) else col.width();
    }
    if (ellipsis and rows.len % per == 0) total += if (c > 0) gap + 1 else 1;
    return total;
}

fn perColumn(count: usize, columns: usize) usize {
    return std.math.divCeil(usize, count, columns) catch unreachable;
}
/// The fewest columns of at most `target` rows. If the width allows fewer than
/// that, as many as fit, which is the shortest it can be. One column always
/// fits, with its labels cut. Null when even that is taller than `room_h`.
fn fit(rows: []const Row, room_w: usize, room_h: usize, target: usize) ?usize {
    var columns = perColumn(rows.len, target);
    while (columns > 1 and contentWidth(rows, perColumn(rows.len, columns), false) > room_w) columns -= 1;
    const per = perColumn(rows.len, columns);
    // Rounding up can leave the last column empty.
    return if (per <= room_h) perColumn(rows.len, per) else null;
}

/// Lays out `model` at the bottom-left of `area`. `area` is what the popup may
/// cover: the terminal less any status line.
pub fn place(area: Region, model: Model, opts: Options) Placement {
    if (area.width == 0 or area.height == 0) return .{};
    const framed = area.height >= 3 and area.width >= 6;
    const room_w: usize = if (framed) area.width - 4 else area.width;
    const room_h: usize = if (framed) area.height - 2 else area.height;
    const rows = model.rows;
    var p: Placement = .{ .framed = framed };
    if (rows.len > 0) {
        if (fit(rows, room_w, room_h, @min(@max(opts.max_rows, 1), room_h))) |columns| {
            p.columns = columns;
            p.per_column = perColumn(rows.len, columns);
            p.shown = rows.len;
        } else {
            // Show as many as fit, in order, and use the last slot for `…`.
            p.truncated = true;
            p.per_column = room_h;
            var columns: usize = 1;
            while (true) : (columns += 1) {
                const shown = @min(columns * room_h - 1, rows.len - 1);
                if (columns > 1 and contentWidth(rows[0..shown], room_h, true) > room_w) break;
                p.columns = columns;
                p.shown = shown;
                if (shown == rows.len - 1) break;
            }
        }
    }
    const content = contentWidth(rows[0..p.shown], @max(p.per_column, 1), p.truncated);
    var w = content;
    var h = p.per_column;
    if (framed) {
        w = @max(content + 4, text.width(model.title) + 4);
        h += 2;
    }
    const width: u16 = @intCast(@min(w, area.width));
    const height: u16 = @intCast(@min(h, area.height));
    p.outer = .{ .x = area.x, .y = area.y + area.height - height, .width = width, .height = height };
    return p;
}

/// A wide glyph cut by the popup's edge would leave half a cell: blank the half
/// outside it.
fn repairEdges(surface: *Surface, r: Region) !void {
    for (r.y..@as(usize, r.y) + r.height) |row| {
        const y: u16 = @intCast(row);
        if (r.x > 0) if (surface.get(r.x, y)) |cell| if (cell.width == 0) {
            const head = surface.get(r.x - 1, y).?;
            try surface.put(r.x - 1, y, .{ .style = head.style });
        };
        const after = r.x + r.width;
        if (surface.get(after, y)) |cell| if (cell.width == 0) {
            try surface.put(after, y, .{ .style = cell.style });
        };
    }
}

/// Cells on one row, left to right, clipped at `right`.
const Line = struct {
    surface: *Surface,
    theme: *const Theme,
    x: u16,
    y: u16,
    right: u16,

    fn cell(self: *Line, str: []const u8, role: Role, width: usize) !void {
        const room: u16 = @intCast(@min(width, self.right - self.x));
        _ = try text.drawText(self.surface, self.x, self.y, room, str, role, self.theme, .{ .ellipsis = true, .fill = self.theme.style(.normal) });
        self.x += room;
    }
    fn blank(self: *Line, width: usize) !void {
        try self.cell("", .normal, width);
    }
};

/// Draws the popup over whatever is in `area`, and returns what it covered:
/// the same as `place(…).outer`. Outside that it only blanks a wide glyph its
/// edge cuts. It hides the terminal cursor if that was under it. To take the
/// popup away, a client draws the covered panes again.
pub fn draw(surface: *Surface, area: Region, theme: *const Theme, model: Model, opts: Options) !Region {
    const p = place(area, model, opts);
    if (p.outer.width == 0 or p.outer.height == 0) return p.outer;
    try repairEdges(surface, p.outer);
    if (surface.cursor) |c| {
        const o = p.outer;
        if (c.x >= o.x and c.x < o.x + o.width and c.y >= o.y and c.y < o.y + o.height) surface.setCursor(null);
    }
    const inner = if (p.framed) try box.draw(surface, p.outer, theme, .{ .title = model.title }) else p.outer;
    // Each cell is written once: a cell that does not change adds no damage, so
    // redrawing an unchanged popup presents nothing.
    const pad: u16 = @intFromBool(p.framed);
    const right = inner.x + inner.width - pad;
    const shown = model.rows[0..p.shown];
    var x = inner.x + pad;
    for (0..p.columns) |c| {
        const rows = columnRows(shown, p.per_column, c);
        const col = Column.of(rows);
        const col_width = @max(col.width(), 1);
        const lead: usize = if (c > 0) gap else 0;
        for (0..inner.height) |row_at| {
            var line: Line = .{ .surface = surface, .theme = theme, .x = x, .y = inner.y + @as(u16, @intCast(row_at)), .right = right };
            try line.blank(lead);
            if (row_at < rows.len) {
                const r = rows[row_at];
                try line.cell(r.keys, .accent, col.key);
                if (r.more) {
                    try line.cell(" + ", .muted, col.slot());
                } else try line.blank(col.slot());
                try line.cell(r.label, .normal, col.label);
            } else if (p.truncated and c * p.per_column + row_at == shown.len) {
                try line.cell("…", .muted, col_width);
            } else try line.blank(col_width);
        }
        x += @intCast(@min(lead + col_width, right - x));
    }
    // The padding, and whatever a wider header leaves over.
    for (0..inner.height) |row_at| {
        const y = inner.y + @as(u16, @intCast(row_at));
        var left: Line = .{ .surface = surface, .theme = theme, .x = inner.x, .y = y, .right = inner.x + pad };
        try left.blank(pad);
        var rest: Line = .{ .surface = surface, .theme = theme, .x = x, .y = y, .right = inner.x + inner.width };
        try rest.blank(rest.right - x);
    }
    return p.outer;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;
const a_test = testing.allocator;

fn expectLines(surface: *const Surface, want: []const []const u8) !void {
    for (want, 0..) |w, y| {
        const got = try text.rowText(a_test, surface, @intCast(y));
        defer a_test.free(got);
        try testing.expectEqualStrings(w, got);
    }
}

const example_rows = [_]Row{
    .{ .keys = "a", .more = true, .label = "agents" },
    .{ .keys = "w", .more = true, .label = "workspaces" },
    .{ .keys = "v", .more = true, .label = "splits" },
    .{ .keys = "i", .label = "inbox" },
    .{ .keys = "s", .label = "settings" },
    .{ .keys = "u", .label = "usage" },
    .{ .keys = "d", .label = "diff" },
};

const Screen = struct {
    surface: Surface,
    discard: std.Io.Writer.Discarding,

    fn init(w: u16, h: u16) !Screen {
        return .{ .surface = try Surface.init(a_test, w, h), .discard = .init(&.{}) };
    }
    fn deinit(self: *Screen) void {
        self.surface.deinit(&self.discard.writer);
    }
    fn draw(self: *Screen, area: Region, model: Model) !Region {
        const theme: Theme = .default;
        return leaderDraw(&self.surface, area, &theme, model, .{});
    }
};
const leaderDraw = draw;

test "layout: the example popup, at the bottom of the region" {
    var s = try Screen.init(40, 9);
    defer s.deinit();
    const area: Region = .{ .width = 40, .height = 9 };
    const outer = try s.draw(area, .{ .title = "venomx › venom", .rows = &example_rows });
    try testing.expectEqual(Region{ .x = 0, .y = 3, .width = 31, .height = 6 }, outer);
    try expectLines(&s.surface, &.{
        "",
        "",
        "",
        "╭ venomx › venom ─────────────╮",
        "│ a + agents      s  settings │",
        "│ w + workspaces  u  usage    │",
        "│ v + splits      d  diff     │",
        "│ i   inbox                   │",
        "╰─────────────────────────────╯",
    });
    const theme: Theme = .default;
    try testing.expectEqual(theme.accent.fg, s.surface.get(2, 4).?.style.fg);
    try testing.expectEqual(theme.muted.fg, s.surface.get(4, 4).?.style.fg);
}

test "layout: a merged row, a title wider than the rows, and no rows" {
    var s = try Screen.init(30, 3);
    defer s.deinit();
    _ = try s.draw(.{ .width = 30, .height = 3 }, .{ .title = "x", .rows = &.{.{ .keys = "h ←", .label = "focus left" }} });
    try expectLines(&s.surface, &.{ "╭ x ──────────────╮", "│ h ←  focus left │", "╰─────────────────╯" });

    var t = try Screen.init(30, 3);
    defer t.deinit();
    const wide = try t.draw(.{ .width = 30, .height = 3 }, .{ .title = "a long header here", .rows = &.{.{ .keys = "q", .label = "x" }} });
    try testing.expectEqual(@as(u16, 22), wide.width);
    try expectLines(&t.surface, &.{ "╭ a long header here ╮", "│ q  x               │", "╰────────────────────╯" });

    var e = try Screen.init(30, 3);
    defer e.deinit();
    const empty = try e.draw(.{ .width = 30, .height = 3 }, .{ .title = "venomx", .rows = &.{} });
    try testing.expectEqual(Region{ .x = 0, .y = 1, .width = 10, .height = 2 }, empty);
    try expectLines(&e.surface, &.{ "", "╭ venomx ╮", "╰────────╯" });
}

test "layout: it prefers a column over passing max_rows, and goes taller only as far as the width needs" {
    const model: Model = .{ .title = "t", .rows = &example_rows };
    const roomy = place(.{ .width = 80, .height = 24 }, model, .{ .max_rows = 2 });
    try testing.expectEqual(@as(usize, 4), roomy.columns);
    try testing.expectEqual(@as(usize, 2), roomy.per_column);
    // 7 rows at 20 wide fit neither 2 columns of 4 nor more: one tall column.
    const narrow = place(.{ .width = 20, .height = 24 }, model, .{});
    try testing.expectEqual(@as(usize, 1), narrow.columns);
    try testing.expectEqual(@as(usize, 7), narrow.per_column);
    try testing.expect(!narrow.truncated);
    // 30 rows that fit 4 columns of 8, not one column of 30.
    var many: [30]Row = undefined;
    for (&many) |*r| r.* = .{ .keys = "k", .more = true, .label = "focus the next pane" };
    const tall = place(.{ .width = 104, .height = 40 }, .{ .title = "t", .rows = &many }, .{});
    try testing.expectEqual(@as(usize, 4), tall.columns);
    try testing.expectEqual(@as(usize, 8), tall.per_column);
}

test "truncation: too few rows shows what fits and ends with …" {
    var s = try Screen.init(14, 5);
    defer s.deinit();
    const area: Region = .{ .width = 14, .height = 5 };
    const model: Model = .{ .title = "t", .rows = &example_rows };
    const p = place(area, model, .{});
    try testing.expect(p.truncated);
    try testing.expectEqual(@as(usize, 2), p.shown);
    _ = try s.draw(area, model);
    try expectLines(&s.surface, &.{
        "╭ t ─────────╮",
        "│ a + agents │",
        "│ w + works… │",
        "│ …          │",
        "╰────────────╯",
    });
}

test "truncation: a wide short region uses more columns before it cuts" {
    const model: Model = .{ .title = "t", .rows = &example_rows };
    const fits = place(.{ .width = 90, .height = 3 }, model, .{});
    try testing.expect(!fits.truncated);
    try testing.expectEqual(@as(usize, 7), fits.columns);

    var n = try Screen.init(36, 3);
    defer n.deinit();
    _ = try n.draw(.{ .width = 36, .height = 3 }, model);
    try expectLines(&n.surface, &.{
        "╭ t ────────────────────────────╮",
        "│ a + agents  w + workspaces  … │",
        "╰───────────────────────────────╯",
    });
}

test "truncation: under 3 rows there is no frame, and one row still ends with …" {
    var s = try Screen.init(20, 2);
    defer s.deinit();
    const model: Model = .{ .title = "t", .rows = &example_rows };
    const outer = try s.draw(.{ .y = 1, .width = 20, .height = 1 }, model);
    try testing.expectEqual(@as(u16, 1), outer.y);
    try expectLines(&s.surface, &.{ "", "a + agents  …" });

    var tiny = try Screen.init(2, 1);
    defer tiny.deinit();
    _ = try tiny.draw(.{ .width = 2, .height = 1 }, model);
    try expectLines(&tiny.surface, &.{"…"});

    const none = try tiny.draw(.{ .width = 0, .height = 0 }, model);
    try testing.expectEqual(@as(u16, 0), none.height);
}

test "truncation: a wide label is cut on a whole glyph" {
    const model: Model = .{ .title = "t", .rows = &.{.{ .keys = "a", .more = true, .label = "界面设置" }} };
    // Room for the whole label, then for 5 and for 4 of its 8 columns.
    for ([_]struct { w: u16, row: []const u8 }{
        .{ .w = 16, .row = "│ a + 界面设置 │" },
        .{ .w = 13, .row = "│ a + 界面… │" },
        .{ .w = 12, .row = "│ a + 界…  │" },
    }) |c| {
        var s = try Screen.init(c.w, 3);
        defer s.deinit();
        const area: Region = .{ .width = c.w, .height = 3 };
        _ = try s.draw(area, model);
        const row = try text.rowText(a_test, &s.surface, 1);
        defer a_test.free(row);
        try testing.expectEqualStrings(c.row, row);
        // Every wide head has its tail, and every tail its head.
        for (0..c.w - 1) |x| {
            const cell = s.surface.get(@intCast(x), 1).?;
            const after = s.surface.get(@intCast(x + 1), 1).?;
            try testing.expectEqual(cell.width == 2, after.width == 0);
        }
        s.surface.damage = null;
        _ = try s.draw(area, model);
        try testing.expectEqual(@as(?Region, null), s.surface.damage);
    }
}

test "a long unlabelled target is capped, not the whole popup" {
    const long = "/usr/local/libexec/a/very/long/path/to/some/tool/with/a/long/name";
    const p = place(.{ .width = 200, .height = 20 }, .{ .title = "t", .rows = &.{.{ .keys = "x", .label = long }} }, .{});
    try testing.expectEqual(@as(u16, 1 + 2 + max_label + 4), p.outer.width);
}

test "overlay: only its own cells change, and it hides a cursor under it" {
    var s = try Screen.init(30, 6);
    defer s.deinit();
    const style: types.Style = .{ .bold = true };
    for (0..6) |y| try s.surface.text(.{ .y = @intCast(y), .width = 30, .height = 1 }, "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123", style);
    s.surface.setCursor(.{ .x = 2, .y = 5 });
    s.surface.damage = null;
    const outer = try s.draw(.{ .width = 30, .height = 6 }, .{ .title = "t", .rows = &.{.{ .keys = "q", .label = "quit" }} });
    try testing.expectEqual(Region{ .x = 0, .y = 3, .width = 11, .height = 3 }, outer);
    try testing.expectEqual(@as(?Surface.Cursor, null), s.surface.cursor);
    try expectLines(&s.surface, &.{
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123",
        "╭ t ──────╮LMNOPQRSTUVWXYZ0123",
        "│ q  quit │LMNOPQRSTUVWXYZ0123",
        "╰─────────╯LMNOPQRSTUVWXYZ0123",
    });
    const d = s.surface.damage.?;
    try testing.expect(d.y >= outer.y and d.x + d.width <= outer.x + outer.width);

    // A cursor outside stays.
    s.surface.setCursor(.{ .x = 20, .y = 5 });
    _ = try s.draw(.{ .width = 30, .height = 6 }, .{ .title = "t", .rows = &.{.{ .keys = "q", .label = "quit" }} });
    try testing.expect(s.surface.cursor != null);
}

test "overlay: a wide glyph cut by an edge leaves no half cell" {
    var s = try Screen.init(20, 3);
    defer s.deinit();
    const wide = "界界界界界界界界界界";
    for (0..3) |y| try s.surface.text(.{ .y = @intCast(y), .width = 20, .height = 1 }, wide, .{});
    // Starts at an odd column and ends at an odd one, so both edges cut a glyph.
    _ = try s.draw(.{ .x = 3, .width = 17, .height = 3 }, .{ .title = "t", .rows = &.{.{ .keys = "q", .label = "quit" }} });
    for (0..3) |y| {
        var x: u16 = 0;
        while (x + 1 < 20) : (x += 1) {
            const cell = s.surface.get(x, @intCast(y)).?;
            const after = s.surface.get(x + 1, @intCast(y)).?;
            try testing.expectEqual(cell.width == 2, after.width == 0);
        }
    }
    try testing.expectEqualStrings(" ", s.surface.get(2, 0).?.text);
}

test "redrawing an unchanged popup adds no damage" {
    var s = try Screen.init(40, 9);
    defer s.deinit();
    const area: Region = .{ .width = 40, .height = 9 };
    const model: Model = .{ .title = "venomx › venom", .rows = &example_rows };
    _ = try s.draw(area, model);
    s.surface.damage = null;
    _ = try s.draw(area, model);
    try testing.expectEqual(@as(?Region, null), s.surface.damage);

    // Likewise when cut, and unframed.
    _ = try s.draw(.{ .width = 14, .height = 5 }, model);
    s.surface.damage = null;
    _ = try s.draw(.{ .width = 14, .height = 5 }, model);
    try testing.expectEqual(@as(?Region, null), s.surface.damage);
    _ = try s.draw(.{ .width = 14, .height = 1 }, model);
    s.surface.damage = null;
    _ = try s.draw(.{ .width = 14, .height = 1 }, model);
    try testing.expectEqual(@as(?Region, null), s.surface.damage);
}

test "model to frame: the real router's rows draw" {
    const Local = enum {
        left,
        fn parse(_: []const u8) ?@This() {
            return .left;
        }
        fn name(_: @This()) []const u8 {
            return "left";
        }
    };
    const K = chrome.keys.Tables(Local, .{ .parseLocal = Local.parse, .localName = Local.name });
    var arena: std.heap.ArenaAllocator = .init(a_test);
    defer arena.deinit();
    const a = arena.allocator();
    const table = (try K.parseTable(a, .{
        .name = "venomx",
        .bind = &.{
            .{ .key = "h", .local = "left", .label = "focus left" },
            .{ .key = "left", .local = "left", .label = "focus left" },
        },
    }, .builtin)).ok;
    const tables = [_]K.Table{table};
    var router: K.Router = .init(a_test);
    defer router.deinit();
    const settings: chrome.keys.Settings = .{ .leader = chrome.keys.parseChord("ctrl+a").?, .timeout_ms = 0 };
    _ = try router.feed(settings, &tables, null, settings.leader, 0);
    const model = try chrome.leader_popup.model(a, "venomx", &router, .{ .key = settings.leader });
    var s = try Screen.init(30, 3);
    defer s.deinit();
    _ = try s.draw(.{ .width = 30, .height = 3 }, model);
    try expectLines(&s.surface, &.{ "╭ venomx ─────────╮", "│ h ←  focus left │", "╰─────────────────╯" });
}
