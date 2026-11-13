const std = @import("std");
const Vt = @import("vt").Vt;
const Surface = @import("surface.zig").Surface;
const Region = @import("types").Region;
/// A viewport belongs to one client. Drawing never scrolls the shared Vt.
pub const VtView = struct {
    top: ?u64 = null,
    epoch: u64 = 0,
    /// What the last following draw left on the surface, for drawChanged.
    last: ?Last = null,
    const Last = struct { vt: *anyopaque, region: Region, epoch: u64, cols: u16, rows: u16, generation: u64 };
    pub fn follow(self: *VtView) void {
        self.top = null;
    }
    pub fn scrollTo(self: *VtView, vt: Vt, row: u64) !void {
        const bounds = vt.rows();
        if (row < bounds.oldest or row >= bounds.end) return error.StaleRows;
        self.top = row;
        self.epoch = bounds.epoch;
    }
    /// Draws every row of the region. A following draw calls
    /// `vt.changes()`, which consumes libghostty-vt's dirty flags, so
    /// nothing else may consume them on a Vt that is drawn.
    pub fn draw(self: *VtView, vt: Vt, surface: *Surface, region: Region) !void {
        const bounds = vt.rows();
        if (self.epoch != bounds.epoch or (self.top != null and self.top.? < bounds.oldest)) self.follow();
        self.epoch = bounds.epoch;
        self.last = null;
        // Taken before drawing: a later change has a greater generation.
        const generation = if (self.top == null) (try vt.changes()).generation else 0;
        const top = self.top orelse bounds.active;
        for (0..clipped(surface, region).height) |y| try drawRow(vt, surface, region, bounds, top + y, @intCast(y));
        if (self.top == null) self.last = .{ .vt = vt.impl, .region = region, .epoch = bounds.epoch, .cols = vt.size().cols, .rows = vt.size().rows, .generation = generation };
    }
    /// Like draw, but when this view's previous draw followed the active
    /// area of the same Vt, epoch, size and region, rewrites only the rows
    /// that changed since. The caller guarantees the surface region still
    /// holds that previous draw.
    pub fn drawChanged(self: *VtView, vt: Vt, surface: *Surface, region: Region) !void {
        const bounds = vt.rows();
        const size = vt.size();
        const last = self.last orelse return self.draw(vt, surface, region);
        if (self.top != null or self.epoch != bounds.epoch or last.vt != vt.impl or last.epoch != bounds.epoch or
            last.cols != size.cols or last.rows != size.rows or !std.meta.eql(last.region, region))
            return self.draw(vt, surface, region);
        const changed = try vt.changes();
        const height = @min(clipped(surface, region).height, changed.rows.len);
        for (changed.rows[0..height], 0..) |gen, y| {
            if (gen > last.generation) try drawRow(vt, surface, region, bounds, bounds.active + y, @intCast(y));
        }
        self.last.?.generation = changed.generation;
    }
    fn clipped(surface: *const Surface, region: Region) struct { width: u32, height: u32 } {
        return .{
            .width = @min(@as(u32, region.x) + region.width, surface.width) - @min(region.x, surface.width),
            .height = @min(@as(u32, region.y) + region.height, surface.height) - @min(region.y, surface.height),
        };
    }
    fn drawRow(vt: Vt, surface: *Surface, region: Region, bounds: Vt.Rows, row: u64, y: u16) !void {
        const width = clipped(surface, region).width;
        const dy: u16 = region.y + y;
        var buf: Vt.CellBuffer = undefined;
        for (0..width) |x| {
            const dx: u16 = @intCast(@as(u32, region.x) + x);
            if (row >= bounds.end or x >= vt.size().cols) {
                try surface.put(dx, dy, .{});
                continue;
            }
            var owned: ?[]const u8 = null;
            defer if (owned) |t| surface.allocator.free(t);
            const cell = try vt.readCellBuf(&buf, bounds.epoch, row, @intCast(x)) orelse blk: {
                const full = try vt.readCell(surface.allocator, bounds.epoch, row, @intCast(x));
                owned = full.text;
                break :blk full;
            };
            if ((cell.width == 2 and x + 1 >= width) or (cell.width == 0 and x == 0)) {
                try surface.put(dx, dy, .{ .style = cell.style });
            } else try surface.put(dx, dy, cell);
        }
    }
};
test "clients have independent viewports" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var vt = try Vt.init(a, .{ .cols = 4, .rows = 2 });
    defer vt.deinit();
    try vt.feed("one\r\ntwo\r\nthree\r\n");
    var surface = try Surface.init(a, 8, 2);
    defer surface.deinit(&out.writer);
    var first: VtView = .{};
    var second: VtView = .{};
    try first.scrollTo(vt, 0);
    try first.draw(vt, &surface, .{ .width = 4, .height = 2 });
    try second.draw(vt, &surface, .{ .x = 4, .width = 4, .height = 2 });
    try std.testing.expectEqualStrings("o", surface.get(0, 0).?.text);
    try std.testing.expect(!std.mem.eql(u8, surface.get(0, 0).?.text, surface.get(4, 0).?.text));
    try std.testing.expectEqual(@as(?u64, 0), first.top);
    try std.testing.expectEqual(@as(?u64, null), second.top);
}
fn expectSameAsFullDraw(vt: Vt, surface: *const Surface, region: Region) !void {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var fresh = try Surface.init(a, surface.width, surface.height);
    defer fresh.deinit(&out.writer);
    var view: VtView = .{};
    try view.draw(vt, &fresh, region);
    for (region.y..region.y + region.height) |y| for (region.x..region.x + region.width) |x| {
        const want = fresh.get(@intCast(x), @intCast(y)).?;
        const got = surface.get(@intCast(x), @intCast(y)).?;
        try std.testing.expectEqualStrings(want.text, got.text);
        try std.testing.expect(std.meta.eql(want.style, got.style));
    };
}
test "drawChanged rewrites only changed rows, including moved rows, across views" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var vt = try Vt.init(a, .{ .cols = 6, .rows = 4 });
    defer vt.deinit();
    try vt.feed("one\r\ntwo\r\n$ ");
    var surface = try Surface.init(a, 12, 4);
    defer surface.deinit(&out.writer);
    const left: Region = .{ .width = 6, .height = 4 };
    const right: Region = .{ .x = 6, .width = 6, .height = 4 };
    var first: VtView = .{};
    var second: VtView = .{};
    try first.drawChanged(vt, &surface, left);
    try second.drawChanged(vt, &surface, right);
    // Nothing changed: nothing is rewritten.
    surface.damage = null;
    try first.drawChanged(vt, &surface, left);
    try second.drawChanged(vt, &surface, right);
    try std.testing.expectEqual(@as(?Region, null), surface.damage);
    // A typed key changes one row; each view rewrites only that row.
    try vt.feed("x");
    try first.drawChanged(vt, &surface, left);
    try std.testing.expectEqual(Region{ .x = 2, .y = 2, .width = 1, .height = 1 }, surface.damage.?);
    try second.drawChanged(vt, &surface, right);
    try std.testing.expectEqual(@as(u16, 1), surface.damage.?.height);
    try expectSameAsFullDraw(vt, &surface, left);
    try std.testing.expectEqualStrings("x", surface.get(8, 2).?.text);
    // Scrolling moves every row without dirtying it: all are rewritten.
    try vt.feed("\r\nthree\r\nfour\r\n");
    surface.damage = null;
    try first.drawChanged(vt, &surface, left);
    try std.testing.expect(surface.damage.?.height >= 3);
    try expectSameAsFullDraw(vt, &surface, left);
    try second.drawChanged(vt, &surface, right);
    try expectSameAsFullDraw(vt, &surface, right);
    // A resize starts a new epoch: a full draw.
    try vt.resize(5, 4);
    try first.drawChanged(vt, &surface, left);
    try expectSameAsFullDraw(vt, &surface, left);
    // A scrolled view draws in full and does not take the fast path.
    try first.scrollTo(vt, vt.rows().oldest);
    try first.drawChanged(vt, &surface, left);
    try std.testing.expect(first.last == null);
}
test "readCellBuf matches readCell and leaves long graphemes to readCell" {
    const a = std.testing.allocator;
    var vt = try Vt.init(a, .{ .cols = 8, .rows = 2 });
    defer vt.deinit();
    try vt.feed("界e\xcc\x81 ");
    const r = vt.rows();
    var buf: Vt.CellBuffer = undefined;
    for (0..4) |x| {
        const owned = try vt.readCell(a, r.epoch, r.active, @intCast(x));
        defer a.free(owned.text);
        const borrowed = (try vt.readCellBuf(&buf, r.epoch, r.active, @intCast(x))).?;
        try std.testing.expectEqualStrings(owned.text, borrowed.text);
        try std.testing.expectEqual(owned.width, borrowed.width);
    }
}
test "a DEL in pane output draws as a space and never reaches the host" {
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var vt = try Vt.init(a, .{ .cols = 4, .rows = 1 });
    defer vt.deinit();
    try vt.feed("a\x7fb");
    var surface = try Surface.init(a, 4, 1);
    defer surface.deinit(&out.writer);
    var view: VtView = .{};
    try view.draw(vt, &surface, .{ .width = 4, .height = 1 });
    try std.testing.expectEqualStrings(" ", surface.get(1, 0).?.text);
    try surface.present(std.testing.io, &env, &out.writer);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.written(), 0x7f) == null);
}
