//! Boxes: borders and titles in theme roles (the shared chrome border styles).
const std = @import("std");
const types = @import("types");
const Region = types.Region;
const Surface = @import("../surface.zig").Surface;
const Theme = @import("theme.zig").Theme;
const Role = @import("theme.zig").Role;
const text = @import("text.zig");

pub const Border = enum { none, single, rounded, heavy };

const Glyphs = struct { tl: []const u8, tr: []const u8, bl: []const u8, br: []const u8, h: []const u8, v: []const u8 };

fn glyphs(border: Border) Glyphs {
    return switch (border) {
        .none => unreachable,
        .single => .{ .tl = "┌", .tr = "┐", .bl = "└", .br = "┘", .h = "─", .v = "│" },
        .rounded => .{ .tl = "╭", .tr = "╮", .bl = "╰", .br = "╯", .h = "─", .v = "│" },
        .heavy => .{ .tl = "┏", .tr = "┓", .bl = "┗", .br = "┛", .h = "━", .v = "┃" },
    };
}

pub const Options = struct {
    border: Border = .rounded,
    title: []const u8 = "",
    /// Right-aligned text in the top border, e.g. a count or a mode.
    badge: []const u8 = "",
    focused: bool = false,
    /// Overrides the border role (`border` / `border_focus`), e.g. `warn`
    /// for an attention marker.
    role: ?Role = null,
    /// Blanks the inner region.
    clear: bool = false,
};

/// Draws a box and returns its inner region. With `.none` the title (if
/// any) takes the first row. A region too small for a border gets no
/// border and an empty inner region.
pub fn draw(surface: *Surface, region: Region, theme: *const Theme, opts: Options) !Region {
    if (opts.border == .none) {
        var inner = region;
        if (opts.title.len > 0 and region.height > 0) {
            _ = try text.drawText(surface, region.x, region.y, region.width, opts.title, if (opts.focused) .title_focus else .title, theme, .{ .ellipsis = true, .fill = theme.style(.normal) });
            inner.y += 1;
            inner.height -= 1;
        }
        if (opts.clear) try surface.clear(inner, theme.style(.normal));
        return inner;
    }
    if (region.width < 2 or region.height < 2) return .{ .x = region.x, .y = region.y, .width = 0, .height = 0 };
    const g = glyphs(opts.border);
    const style = theme.style(opts.role orelse if (opts.focused) .border_focus else .border);
    const right = region.x + region.width - 1;
    const bottom = region.y + region.height - 1;
    // Title and badge first, then the border around them: each cell is
    // written once, so redrawing an unchanged box adds no damage.
    var badge_x: u16 = right;
    if (opts.badge.len > 0 and region.width > 6) {
        const bw: u16 = @intCast(@min(text.width(opts.badge) + 2, region.width - 4));
        badge_x = right - bw;
        try surface.put(badge_x, region.y, .{ .text = " ", .style = style });
        _ = try text.drawText(surface, badge_x + 1, region.y, bw - 2, opts.badge, .muted, theme, .{ .ellipsis = true, .fill = style });
        try surface.put(right - 1, region.y, .{ .text = " ", .style = style });
    }
    // Title: "─ title ─", keeping one border cell on each side.
    var title_end: u16 = region.x + 1;
    if (opts.title.len > 0 and badge_x > region.x + 4) {
        const room = badge_x - region.x - 3;
        const title_role: Role = if (opts.focused) .title_focus else .title;
        try surface.put(region.x + 1, region.y, .{ .text = " ", .style = style });
        const used = try text.drawText(surface, region.x + 2, region.y, room, opts.title, title_role, theme, .{ .ellipsis = true });
        try surface.put(region.x + 2 + used, region.y, .{ .text = " ", .style = style });
        title_end = region.x + 3 + used;
    }
    for (region.x..@as(usize, right) + 1) |x| {
        const bottom_glyph = if (x == region.x) g.bl else if (x == right) g.br else g.h;
        try surface.put(@intCast(x), bottom, .{ .text = bottom_glyph, .style = style });
        const in_title = x > region.x and x < title_end;
        const in_badge = x >= badge_x and x < right;
        if (in_title or in_badge) continue;
        const top_glyph = if (x == region.x) g.tl else if (x == right) g.tr else g.h;
        try surface.put(@intCast(x), region.y, .{ .text = top_glyph, .style = style });
    }
    for (region.y + 1..bottom) |y| {
        try surface.put(region.x, @intCast(y), .{ .text = g.v, .style = style });
        try surface.put(right, @intCast(y), .{ .text = g.v, .style = style });
    }
    const inner: Region = .{ .x = region.x + 1, .y = region.y + 1, .width = region.width - 2, .height = region.height - 2 };
    if (opts.clear) try surface.clear(inner, theme.style(.normal));
    return inner;
}

test "box draws borders, title and badge, and returns the inner region" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 20, 4);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    const inner = try draw(&surface, .{ .width = 20, .height = 4 }, &theme, .{ .title = "Agents", .badge = "3", .focused = true });
    try std.testing.expectEqual(Region{ .x = 1, .y = 1, .width = 18, .height = 2 }, inner);
    const rows = .{ "╭ Agents ─────── 3 ╮", "│                  │", "│                  │", "╰──────────────────╯" };
    inline for (rows, 0..) |want, y| {
        const got = try text.rowText(a, &surface, y);
        defer a.free(got);
        try std.testing.expectEqualStrings(std.mem.trimEnd(u8, want, " "), got);
    }
    try std.testing.expectEqual(theme.border_focus.fg, surface.get(0, 0).?.style.fg);
    try std.testing.expect(surface.get(2, 0).?.style.bold);

    // A long title is ellipsized; heavy borders and tiny regions work.
    _ = try draw(&surface, .{ .width = 10, .height = 3 }, &theme, .{ .border = .heavy, .title = "transcript of agent" });
    const top = try text.rowText(a, &surface, 0);
    defer a.free(top);
    try std.testing.expectEqualStrings("┏ trans… ┓────── 3 ╮", top);
    const none = try draw(&surface, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, &theme, .{});
    try std.testing.expectEqual(@as(u16, 0), none.width);
}

test "redrawing an unchanged box adds no damage" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 20, 4);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    const opts: Options = .{ .title = "Agents", .badge = "3" };
    _ = try draw(&surface, .{ .width = 20, .height = 4 }, &theme, opts);
    surface.damage = null;
    _ = try draw(&surface, .{ .width = 20, .height = 4 }, &theme, opts);
    try std.testing.expectEqual(@as(?Region, null), surface.damage);
}
