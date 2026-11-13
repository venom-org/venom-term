//! Grouped, selectable list with folded groups and one- or two-line rows
//! (the venom agent list).
//!
//! The caller owns the groups and items; the list owns only its cursor and
//! scroll position. `folded` lives on the caller's `Group`, so folding
//! survives regrouping when the caller keeps it.
const std = @import("std");
const types = @import("types");
const Region = types.Region;
const Surface = @import("../surface.zig").Surface;
const Theme = @import("theme.zig").Theme;
const Role = @import("theme.zig").Role;
const text = @import("text.zig");
const Span = text.Span;
const keys = @import("keys.zig");
const Key = @import("types").Input.Key;
const Mouse = @import("types").Input.Mouse;
const layout = @import("layout.zig");

pub const Item = struct {
    /// State glyph (`▲`, `◆`, `●`, …); always paired with a role.
    glyph: []const u8 = "",
    glyph_role: Role = .normal,
    title: []const u8,
    /// Right-aligned on line 1, e.g. the age.
    meta: []const u8 = "",
    /// Line 2: harness, scope, activity…
    detail: []const Span = &.{},
    /// Unread rows are bold.
    bold: bool = false,
};

pub const Group = struct {
    title: []const u8,
    items: []const Item,
    folded: bool = false,
    /// Shown after the title, e.g. `3` or `●1 ◆1 ▲1`.
    summary: []const u8 = "",
};

pub const Selection = union(enum) {
    group: usize,
    item: struct { group: usize, index: usize },
};

pub const Action = union(enum) {
    /// The cursor moved.
    moved,
    /// A group was folded or unfolded.
    toggled: usize,
    /// Enter on an item.
    activated: struct { group: usize, index: usize },
};

pub const GroupedList = struct {
    /// Index of the selected visible entry (headers count as entries).
    cursor: usize = 0,
    /// First visible entry.
    top: usize = 0,
    /// Lines per item: 1 or 2.
    row_height: u16 = 2,
    /// Height of the last draw, for page keys.
    page: u16 = 10,
    /// Region of the last draw, for mouse hits.
    area: Region = .{ .width = 0, .height = 0 },

    fn entryCount(groups: []const Group) usize {
        var n: usize = 0;
        for (groups) |g| n += 1 + if (g.folded) 0 else g.items.len;
        return n;
    }

    /// Maps a visible entry index to a selection.
    pub fn entry(groups: []const Group, index: usize) ?Selection {
        var i = index;
        for (groups, 0..) |g, gi| {
            if (i == 0) return .{ .group = gi };
            i -= 1;
            if (!g.folded) {
                if (i < g.items.len) return .{ .item = .{ .group = gi, .index = i } };
                i -= g.items.len;
            }
        }
        return null;
    }

    fn indexOf(groups: []const Group, sel: Selection) ?usize {
        var n: usize = 0;
        for (groups, 0..) |g, gi| {
            switch (sel) {
                .group => |sg| if (sg == gi) return n,
                .item => |it| if (it.group == gi) {
                    if (g.folded or it.index >= g.items.len) return null;
                    return n + 1 + it.index;
                },
            }
            n += 1 + if (g.folded) 0 else g.items.len;
        }
        return null;
    }

    pub fn selected(self: *const GroupedList, groups: []const Group) ?Selection {
        return entry(groups, self.cursor);
    }

    /// Selects an entry; a hidden item selects its group's header.
    pub fn select(self: *GroupedList, groups: []const Group, sel: Selection) void {
        if (indexOf(groups, sel)) |i| {
            self.cursor = i;
        } else if (sel == .item) {
            if (indexOf(groups, .{ .group = sel.item.group })) |i| self.cursor = i;
        }
    }

    fn clamp(self: *GroupedList, groups: []const Group) void {
        const n = entryCount(groups);
        if (n == 0) {
            self.cursor = 0;
            self.top = 0;
        } else if (self.cursor >= n) self.cursor = n - 1;
    }

    pub fn moveBy(self: *GroupedList, groups: []const Group, delta: isize) void {
        const n = entryCount(groups);
        if (n == 0) return;
        const c: isize = @intCast(self.cursor);
        self.cursor = @intCast(std.math.clamp(c + delta, 0, @as(isize, @intCast(n - 1))));
    }

    /// Folds or unfolds a group; the cursor stays on the same entry or its header.
    pub fn toggle(self: *GroupedList, groups: []Group, group: usize) void {
        const before = self.selected(groups);
        groups[group].folded = !groups[group].folded;
        if (before) |sel| self.select(groups, sel);
        self.clamp(groups);
    }

    /// Default bindings: ↑/k ↓/j, Home/End, PgUp/PgDn, Enter/Space (fold a
    /// header or activate an item), ←/h (fold, or go to the header), →/l
    /// (unfold). Returns null when the key isn't the list's.
    pub fn handleKey(self: *GroupedList, groups: []Group, key: Key) ?Action {
        self.clamp(groups);
        const page: isize = @max(1, @divFloor(@as(isize, self.page), self.row_height));
        if (keys.named(key, .up) or keys.char(key, 'k')) {
            self.moveBy(groups, -1);
        } else if (keys.named(key, .down) or keys.char(key, 'j')) {
            self.moveBy(groups, 1);
        } else if (keys.named(key, .page_up)) {
            self.moveBy(groups, -page);
        } else if (keys.named(key, .page_down)) {
            self.moveBy(groups, page);
        } else if (keys.named(key, .home)) {
            self.cursor = 0;
        } else if (keys.named(key, .end)) {
            self.cursor = entryCount(groups) -| 1;
        } else if (keys.named(key, .enter) or keys.char(key, ' ')) {
            const sel = self.selected(groups) orelse return null;
            switch (sel) {
                .group => |g| {
                    self.toggle(groups, g);
                    return .{ .toggled = g };
                },
                .item => |it| return .{ .activated = .{ .group = it.group, .index = it.index } },
            }
        } else if (keys.named(key, .left) or keys.char(key, 'h')) {
            const sel = self.selected(groups) orelse return null;
            switch (sel) {
                .group => |g| {
                    if (groups[g].folded) return null;
                    self.toggle(groups, g);
                    return .{ .toggled = g };
                },
                .item => |it| self.select(groups, .{ .group = it.group }),
            }
        } else if (keys.named(key, .right) or keys.char(key, 'l')) {
            const sel = self.selected(groups) orelse return null;
            if (sel != .group or !groups[sel.group].folded) return null;
            self.toggle(groups, sel.group);
            return .{ .toggled = sel.group };
        } else return null;
        return .moved;
    }

    /// The entry drawn at a viewport row of the last draw.
    pub fn entryAt(self: *const GroupedList, groups: []const Group, row: usize) ?usize {
        const n = entryCount(groups);
        var y: usize = 0;
        var i = self.top;
        while (i < n) : (i += 1) {
            y += self.entryHeight(groups, i);
            if (row < y) return i;
        }
        return null;
    }

    /// Mouse bindings over the region of the last draw: the wheel moves
    /// the cursor one entry per tick; a left click on a header selects and
    /// folds or unfolds it, on an item selects it, and on the already
    /// selected item activates it.
    pub fn handleMouse(self: *GroupedList, groups: []Group, mouse: Mouse) ?Action {
        const cell = layout.hit(self.area, mouse.x, mouse.y) orelse return null;
        if (mouse.action != .press) return null;
        self.clamp(groups);
        switch (mouse.button) {
            .wheel_up => self.moveBy(groups, -1),
            .wheel_down => self.moveBy(groups, 1),
            .left => {
                const i = self.entryAt(groups, cell.row) orelse return null;
                const again = i == self.cursor;
                self.cursor = i;
                switch (entry(groups, i).?) {
                    .group => |g| {
                        self.toggle(groups, g);
                        return .{ .toggled = g };
                    },
                    .item => |it| if (again) return .{ .activated = .{ .group = it.group, .index = it.index } },
                }
            },
            else => return null,
        }
        return .moved;
    }

    fn entryHeight(self: *const GroupedList, groups: []const Group, index: usize) usize {
        return switch (entry(groups, index).?) {
            .group => 1,
            .item => @max(1, @min(self.row_height, 2)),
        };
    }

    /// Keeps the cursor visible and the list bottom-aligned when it shrinks.
    fn scroll(self: *GroupedList, groups: []const Group, height: usize) void {
        const n = entryCount(groups);
        if (n == 0) return;
        if (self.top > self.cursor) self.top = self.cursor;
        while (self.top < self.cursor) {
            var rows: usize = 0;
            for (self.top..self.cursor + 1) |i| rows += self.entryHeight(groups, i);
            if (rows <= height) break;
            self.top += 1;
        }
        while (self.top > 0) {
            var rows: usize = 0;
            for (self.top - 1..n) |i| rows += self.entryHeight(groups, i);
            if (rows > height) break;
            self.top -= 1;
        }
    }

    pub fn draw(self: *GroupedList, surface: *Surface, region: Region, groups: []const Group, theme: *const Theme, focused: bool) !void {
        self.page = region.height;
        self.area = region;
        if (region.width == 0 or region.height == 0) return;
        self.clamp(groups);
        self.scroll(groups, region.height);
        const blank = theme.style(.normal);
        const sel_style = theme.style(.selection);
        var y: u16 = region.y;
        const bottom = region.y + region.height;
        var i = self.top;
        const n = entryCount(groups);
        while (i < n and y < bottom) : (i += 1) {
            const is_sel = i == self.cursor;
            const fill = if (is_sel) theme_overlay(blank, sel_style) else blank;
            const opts: text.DrawOptions = .{ .overlay = if (is_sel) sel_style else null, .ellipsis = true, .fill = fill };
            // One-column gutter marks the cursor when the list is focused.
            try surface.put(region.x, y, if (is_sel and focused) .{ .text = "▌", .style = theme.style(.accent) } else .{ .style = fill });
            const x = region.x + 1;
            const w = region.width -| 1;
            switch (entry(groups, i).?) {
                .group => |gi| {
                    const g = groups[gi];
                    const spans = [_]Span{
                        .{ .text = if (g.folded) "▸ " else "▾ ", .role = .muted },
                        .{ .text = g.title, .role = .muted, .style = .{ .bold = true } },
                        .{ .text = if (g.summary.len > 0) "  " else "", .role = .muted },
                        .{ .text = g.summary, .role = .muted },
                    };
                    _ = try text.drawSpans(surface, x, y, w, &spans, theme, opts);
                    y += 1;
                },
                .item => |it| {
                    const item = groups[it.group].items[it.index];
                    const meta_w: u16 = @intCast(@min(text.width(item.meta), w));
                    const title_w = w -| meta_w -| @as(u16, if (meta_w > 0) 1 else 0);
                    const spans = [_]Span{
                        .{ .text = item.glyph, .role = item.glyph_role },
                        .{ .text = if (item.glyph.len > 0) " " else "" },
                        .{ .text = item.title, .style = .{ .bold = item.bold } },
                    };
                    var line_opts = opts;
                    line_opts.fill = fill;
                    _ = try text.drawSpans(surface, x, y, title_w, &spans, theme, line_opts);
                    if (meta_w > 0) {
                        _ = try text.drawText(surface, x + title_w, y, w - title_w - meta_w, "", .normal, theme, .{ .fill = fill });
                        _ = try text.drawText(surface, x + w - meta_w, y, meta_w, item.meta, .muted, theme, opts);
                    }
                    y += 1;
                    if (self.row_height >= 2 and y < bottom) {
                        try surface.put(region.x, y, if (is_sel and focused) .{ .text = "▌", .style = theme.style(.accent) } else .{ .style = fill });
                        var detail: [16]Span = undefined;
                        detail[0] = .{ .text = "  " };
                        const dn = @min(item.detail.len, detail.len - 1);
                        for (item.detail[0..dn], 1..) |s, k| {
                            detail[k] = s;
                            if (s.role == .normal and s.style == null) detail[k].role = .secondary;
                        }
                        _ = try text.drawSpans(surface, x, y, w, detail[0 .. dn + 1], theme, opts);
                        y += 1;
                    }
                },
            }
        }
        if (y < bottom) try surface.clear(.{ .x = region.x, .y = y, .width = region.width, .height = bottom - y }, blank);
    }
};

fn theme_overlay(a: types.Style, b: types.Style) types.Style {
    return @import("theme.zig").overlay(a, b);
}

fn testGroups() [3]Group {
    const S = struct {
        const needs = [_]Item{.{ .glyph = "▲", .glyph_role = .warn, .title = "venom-echo conformance", .meta = "1m", .detail = &.{.{ .text = "claude · venom-std · approve: zig build test" }} }};
        const running = [_]Item{
            .{ .glyph = "◆", .glyph_role = .info, .title = "widgets v0", .meta = "4m", .detail = &.{.{ .text = "codex · venom-term" }} },
            .{ .glyph = "◆", .glyph_role = .info, .title = "pane stream", .meta = "9m", .bold = true },
        };
        const settled = [_]Item{.{ .glyph = "●", .glyph_role = .ok, .title = "ux-model", .meta = "2h" }};
    };
    return .{
        .{ .title = "Needs you", .items = &S.needs, .summary = "1" },
        .{ .title = "Running", .items = &S.running },
        .{ .title = "Settled", .items = &S.settled, .folded = true },
    };
}

fn expectRows(surface: *const Surface, rows: []const []const u8) !void {
    const a = std.testing.allocator;
    for (rows, 0..) |want, y| {
        const got = try text.rowText(a, surface, @intCast(y));
        defer a.free(got);
        try std.testing.expectEqualStrings(want, got);
    }
}

test "grouped list renders headers, two-line rows, meta and folded groups" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 30, 9);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    var groups = testGroups();
    var list: GroupedList = .{};
    list.select(&groups, .{ .item = .{ .group = 0, .index = 0 } });
    try list.draw(&surface, .{ .width = 30, .height = 9 }, &groups, &theme, true);
    try expectRows(&surface, &.{
        " ▾ Needs you  1",
        "▌▲ venom-echo conformance   1m",
        "▌  claude · venom-std · appro…",
        " ▾ Running",
        " ◆ widgets v0               4m",
        "   codex · venom-term",
        " ◆ pane stream              9m",
        "",
        " ▸ Settled",
    });
    // Selected rows get the selection fill across the row; unread is bold.
    try std.testing.expectEqual(theme.selection.bg, surface.get(15, 1).?.style.bg);
    try std.testing.expectEqual(theme.warn.fg, surface.get(1, 1).?.style.fg);
    try std.testing.expect(surface.get(3, 6).?.style.bold);
}

test "keys move the cursor, fold and unfold groups, and scroll" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 24, 4);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    var groups = testGroups();
    var list: GroupedList = .{};
    const down = keys.testNamed(.down);
    try std.testing.expectEqual(Action.moved, list.handleKey(&groups, down).?);
    try std.testing.expectEqual(Selection{ .item = .{ .group = 0, .index = 0 } }, list.selected(&groups).?);
    // ← on an item jumps to its header; ← again folds it.
    _ = list.handleKey(&groups, keys.testNamed(.left));
    try std.testing.expectEqual(Selection{ .group = 0 }, list.selected(&groups).?);
    try std.testing.expectEqual(Action{ .toggled = 0 }, list.handleKey(&groups, keys.testNamed(.left)).?);
    try std.testing.expect(groups[0].folded);
    // End selects the folded "Settled" header; Enter unfolds it.
    _ = list.handleKey(&groups, keys.testNamed(.end));
    try std.testing.expectEqual(Selection{ .group = 2 }, list.selected(&groups).?);
    try std.testing.expectEqual(Action{ .toggled = 2 }, list.handleKey(&groups, keys.testNamed(.enter)).?);
    _ = list.handleKey(&groups, down);
    try std.testing.expectEqual(Selection{ .item = .{ .group = 2, .index = 0 } }, list.selected(&groups).?);
    try std.testing.expect(list.handleKey(&groups, keys.testKey('x', .{})) == null);
    // A 4-row viewport scrolls to keep the two-line cursor row visible.
    try list.draw(&surface, .{ .width = 24, .height = 4 }, &groups, &theme, false);
    try expectRows(&surface, &.{ " ▾ Settled", " ● ux-model           2h", "", "" });
    try std.testing.expectEqual(Action{ .activated = .{ .group = 2, .index = 0 } }, list.handleKey(&groups, keys.testNamed(.enter)).?);
    // Home scrolls back up.
    _ = list.handleKey(&groups, keys.testNamed(.home));
    try list.draw(&surface, .{ .width = 24, .height = 4 }, &groups, &theme, false);
    try expectRows(&surface, &.{ " ▸ Needs you  1", " ▾ Running", " ◆ widgets v0         4m", "   codex · venom-term" });
}

test "mouse wheel moves the cursor and clicks select, fold and activate" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 30, 9);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    var groups = testGroups();
    var list: GroupedList = .{};
    const region: Region = .{ .x = 2, .y = 1, .width = 26, .height = 8 };
    try list.draw(&surface, region, &groups, &theme, true);
    // Outside the drawn region nothing happens.
    try std.testing.expect(list.handleMouse(&groups, keys.testMouse(0, 0, .left)) == null);
    try std.testing.expectEqual(Action.moved, list.handleMouse(&groups, keys.testMouse(5, 4, .wheel_down)).?);
    try std.testing.expectEqual(@as(usize, 1), list.cursor);
    _ = list.handleMouse(&groups, keys.testMouse(5, 4, .wheel_up));
    try std.testing.expectEqual(@as(usize, 0), list.cursor);
    // Rows: 0 header, 1-2 item, 3 header, 4-5 item, 6-7 item. Clicking the
    // detail line (row 5) of "widgets v0" selects it; again activates it.
    try std.testing.expectEqual(Action.moved, list.handleMouse(&groups, keys.testMouse(5, 1 + 5, .left)).?);
    try std.testing.expectEqual(Selection{ .item = .{ .group = 1, .index = 0 } }, list.selected(&groups).?);
    try std.testing.expectEqual(Action{ .activated = .{ .group = 1, .index = 0 } }, list.handleMouse(&groups, keys.testMouse(5, 1 + 4, .left)).?);
    // Clicking a header folds it.
    try std.testing.expectEqual(Action{ .toggled = 0 }, list.handleMouse(&groups, keys.testMouse(3, 1, .left)).?);
    try std.testing.expect(groups[0].folded);
    try std.testing.expectEqual(Selection{ .group = 0 }, list.selected(&groups).?);
    // Below the last entry is empty space.
    try list.draw(&surface, region, &groups, &theme, true);
    try std.testing.expect(list.handleMouse(&groups, keys.testMouse(3, 8, .left)) == null);
}
