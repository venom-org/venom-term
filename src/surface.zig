const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types");
const Cell = types.Cell;
const Region = types.Region;
const Style = types.Style;

pub const Surface = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    cells: []Cell,
    damage: ?Region,
    backend: ?*anyopaque = null,
    cursor: ?Cursor = null,
    /// The cursor changed since the last present; no cell did.
    cursor_moved: bool = false,
    /// What `.default` colours present as; see `setDefaults`.
    defaults: Defaults = .{},
    pub const Cursor = struct { x: u16, y: u16, shape: types.CursorShape = .{} };
    /// `.default` leaves a colour to the terminal.
    pub const Defaults = struct { fg: types.Color = .default, bg: types.Color = .default };

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Surface {
        if (width == 0 or height == 0) return error.InvalidSize;
        const cells = try allocator.alloc(Cell, @as(usize, width) * height);
        @memset(cells, .{ .text = "" });
        return .{ .allocator = allocator, .width = width, .height = height, .cells = cells, .damage = .{ .width = width, .height = height } };
    }
    /// Releases memory and writes terminal restoration if present() was used.
    pub fn deinit(self: *Surface, writer: *std.Io.Writer) void {
        if (self.backend) |ptr| {
            const vx: *vaxis.Vaxis = @ptrCast(@alignCast(ptr));
            vx.deinit(self.allocator, writer);
            self.allocator.destroy(vx);
        }
        for (self.cells) |cell| self.allocator.free(cell.text);
        self.allocator.free(self.cells);
        self.* = undefined;
    }
    pub fn get(self: *const Surface, x: u16, y: u16) ?Cell {
        if (x >= self.width or y >= self.height) return null;
        return self.cells[@as(usize, y) * self.width + x];
    }
    /// Copies text. Coordinates outside the surface are clipped.
    /// A width-2 cell must be followed by a width-0 continuation cell.
    pub fn put(self: *Surface, x: u16, y: u16, cell: Cell) !void {
        if (x >= self.width or y >= self.height) return;
        if (cell.width > 2 or !std.unicode.utf8ValidateSlice(cell.text)) return error.InvalidCell;
        const i = @as(usize, y) * self.width + x;
        const old = self.cells[i];
        if (old.width == cell.width and std.meta.eql(old.style, cell.style) and std.mem.eql(u8, old.text, cell.text)) return;
        const owned = try self.allocator.dupe(u8, cell.text);
        self.allocator.free(old.text);
        self.cells[i] = .{ .text = owned, .width = cell.width, .style = cell.style };
        self.mark(.{ .x = x, .y = y, .width = 1, .height = 1 });
    }
    pub fn setCursor(self: *Surface, cursor: ?Cursor) void {
        if (std.meta.eql(self.cursor, cursor)) return;
        self.cursor = cursor;
        self.cursor_moved = true;
    }
    /// Colours for cells whose fg or bg is `.default`, so a product can own its
    /// ground on any terminal. Applied at present time: stored cells keep
    /// `.default`, so text drawn with no bg, and VT cells, need no extra style.
    /// Set both: the terminal's default fg is chosen for its own bg.
    pub fn setDefaults(self: *Surface, defaults: Defaults) void {
        if (std.meta.eql(self.defaults, defaults)) return;
        self.defaults = defaults;
        self.damage = .{ .width = self.width, .height = self.height };
    }
    fn mark(self: *Surface, r: Region) void {
        if (self.damage) |d| {
            const x = @min(d.x, r.x);
            const y = @min(d.y, r.y);
            self.damage = .{ .x = x, .y = y, .width = @max(d.x + d.width, r.x + r.width) - x, .height = @max(d.y + d.height, r.y + r.height) - y };
        } else self.damage = r;
    }
    pub fn clear(self: *Surface, region: Region, style: Style) !void {
        const right = @min(@as(u32, region.x) + region.width, self.width);
        const bottom = @min(@as(u32, region.y) + region.height, self.height);
        for (@min(region.y, self.height)..bottom) |y| for (@min(region.x, self.width)..right) |x| {
            try self.put(@intCast(x), @intCast(y), .{ .style = style });
        };
    }
    pub fn resize(self: *Surface, width: u16, height: u16) !void {
        if (width == self.width and height == self.height) return;
        var next = try Surface.init(self.allocator, width, height);
        errdefer {
            for (next.cells) |cell| self.allocator.free(cell.text);
            self.allocator.free(next.cells);
        }
        for (0..@min(height, self.height)) |y| for (0..@min(width, self.width)) |x| {
            try next.put(@intCast(x), @intCast(y), self.get(@intCast(x), @intCast(y)).?);
        };
        for (self.cells) |cell| self.allocator.free(cell.text);
        self.allocator.free(self.cells);
        next.backend = self.backend;
        next.cursor = self.cursor;
        next.cursor_moved = true;
        next.defaults = self.defaults;
        self.* = next;
    }
    /// Writes one line, grapheme-aware, clipping complete glyphs at the region edge.
    pub fn text(self: *Surface, region: Region, value: []const u8, style: Style) !void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidCell;
        var iter = vaxis.unicode.graphemeIterator(value);
        var x: u32 = region.x;
        const right = @min(@as(u32, region.x) + region.width, self.width);
        if (region.height == 0 or region.y >= self.height) return;
        while (iter.next()) |g| {
            const grapheme = g.bytes(value);
            if (std.mem.indexOfAny(u8, grapheme, "\r\n\x1b") != null) return error.InvalidCell;
            const width: u8 = @intCast(vaxis.gwidth.gwidth(grapheme, .unicode));
            if (width == 0) continue;
            if (x + width > right) break;
            try self.put(@intCast(x), region.y, .{ .text = grapheme, .width = width, .style = style });
            if (width == 2) try self.put(@intCast(x + 1), region.y, .{ .text = "", .width = 0, .style = style });
            x += width;
        }
    }
    /// Headless writer presentation; no /dev/tty or threads are opened.
    /// io and environment are needed on the first call only.
    pub fn present(self: *Surface, io: std.Io, env: *std.process.Environ.Map, writer: *std.Io.Writer) !void {
        if (self.damage == null and !self.cursor_moved) return;
        const vx: *vaxis.Vaxis = if (self.backend) |ptr| @ptrCast(@alignCast(ptr)) else blk: {
            const ptr = try self.allocator.create(vaxis.Vaxis);
            errdefer self.allocator.destroy(ptr);
            ptr.* = try vaxis.init(io, self.allocator, env, .{});
            self.backend = ptr;
            break :blk ptr;
        };
        // vaxis keeps the cells it was given, so only damage is rewritten.
        var d = self.damage orelse Region{ .width = 0, .height = 0 };
        if (vx.window().width != self.width or vx.window().height != self.height) {
            try vx.resize(self.allocator, writer, .{ .cols = self.width, .rows = self.height, .x_pixel = 0, .y_pixel = 0 });
            d = .{ .width = self.width, .height = self.height };
        }
        const win = vx.window();
        win.hideCursor();
        // A hidden cursor gets the host's default shape back.
        win.setCursorShape(.default);
        if (self.cursor) |pos| {
            if (pos.x < self.width and pos.y < self.height) {
                win.showCursor(pos.x, pos.y);
                win.setCursorShape(vaxisShape(pos.shape));
            }
        }
        for (d.y..@min(@as(u32, d.y) + d.height, self.height)) |y| for (d.x..@min(@as(u32, d.x) + d.width, self.width)) |x| {
            const cell = self.cells[y * self.width + x];
            win.writeCell(@intCast(x), @intCast(y), .{
                .char = .{ .grapheme = if (cell.text.len == 0) " " else cell.text, .width = cell.width },
                .style = .{ .fg = toColor(if (cell.style.fg == .default) self.defaults.fg else cell.style.fg), .bg = toColor(if (cell.style.bg == .default) self.defaults.bg else cell.style.bg), .ul = toColor(cell.style.ul), .ul_style = @fromBackingInt(@intCast(@backingInt(cell.style.underline))), .bold = cell.style.bold, .dim = cell.style.dim, .italic = cell.style.italic, .blink = cell.style.blink, .reverse = cell.style.reverse, .invisible = cell.style.invisible, .strikethrough = cell.style.strikethrough },
            });
        };
        vx.render(writer) catch |err| {
            vx.queueRefresh();
            return err;
        };
        self.damage = null;
        self.cursor_moved = false;
    }
};
/// vaxis writes DECSCUSR with the enum's value, once per change.
fn vaxisShape(shape: types.CursorShape) vaxis.Cell.CursorShape {
    return switch (shape.kind) {
        .default => .default,
        .block => if (shape.blink) .block_blink else .block,
        .underline => if (shape.blink) .underline_blink else .underline,
        .bar => if (shape.blink) .beam_blink else .beam,
    };
}
fn toColor(color: types.Color) vaxis.Color {
    return switch (color) {
        .default => .default,
        .index => |i| .{ .index = i },
        .rgb => |rgb| .{ .rgb = rgb },
    };
}
test "surface owns strings and clips damage" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try Surface.init(a, 4, 2);
    defer surface.deinit(&out.writer);
    surface.damage = null;
    var buf = [_]u8{'a'};
    try surface.put(1, 1, .{ .text = &buf });
    buf[0] = 'z';
    try std.testing.expectEqualStrings("a", surface.get(1, 1).?.text);
    try std.testing.expectEqual(@as(u16, 1), surface.damage.?.width);
    try surface.clear(.{ .x = 3, .y = 1, .width = 65535, .height = 65535 }, .{});
    try surface.resize(2, 2);
    try std.testing.expectEqualStrings("a", surface.get(1, 1).?.text);
}
test "writer output replays Unicode styles and damage through headless VT" {
    const Vt = @import("vt").Vt;
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try Surface.init(a, 12, 3);
    defer surface.deinit(&out.writer);
    try surface.text(.{ .width = 12, .height = 1 }, "界e\xcc\x81", .{ .fg = .{ .index = 1 }, .bold = true });
    surface.setCursor(.{ .x = 3, .y = 1 });
    try surface.present(std.testing.io, &env, &out.writer);
    const first = out.written().len;
    try surface.present(std.testing.io, &env, &out.writer);
    try std.testing.expectEqual(first, out.written().len);
    var vt = try Vt.init(a, .{ .cols = 12, .rows = 3 });
    defer vt.deinit();
    try vt.feed("\x1b[3;1Hdirty\x1b[H");
    try vt.feed(out.written());
    const cell = try vt.readCell(a, vt.rows().epoch, vt.rows().active, 0);
    defer a.free(cell.text);
    try std.testing.expectEqualStrings("界", cell.text);
    try std.testing.expect(cell.style.bold);
    const blank = try vt.readCell(a, vt.rows().epoch, vt.rows().active + 2, 0);
    defer a.free(blank.text);
    try std.testing.expectEqualStrings(" ", blank.text);
    try std.testing.expect(vt.cursor().visible);
    try std.testing.expectEqual(@as(u16, 3), vt.cursor().x);
    try surface.put(0, 1, .{ .text = "x" });
    try surface.present(std.testing.io, &env, &out.writer);
    try std.testing.expect(out.written().len > first);
    try vt.feed(out.written()[first..]);
    const changed = try vt.readCell(a, vt.rows().epoch, vt.rows().active + 1, 0);
    defer a.free(changed.text);
    try std.testing.expectEqualStrings("x", changed.text);
    try surface.resize(20, 5);
    try surface.present(std.testing.io, &env, &out.writer);
}
test "the cursor shape reaches the host once per change, and a hidden cursor gets the host's default" {
    const Vt = @import("vt").Vt;
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try Surface.init(a, 8, 2);
    defer surface.deinit(&out.writer);
    var host = try Vt.init(a, .{ .cols = 8, .rows = 2 });
    defer host.deinit();
    const steps = [_]struct { ?Surface.Cursor, types.CursorShape }{
        .{ .{ .x = 1, .y = 0, .shape = .{ .kind = .bar } }, .{ .kind = .bar } },
        .{ .{ .x = 2, .y = 0, .shape = .{ .kind = .bar } }, .{ .kind = .bar } },
        .{ .{ .x = 2, .y = 0, .shape = .{ .kind = .block, .blink = true } }, .{ .kind = .block, .blink = true } },
        .{ .{ .x = 2, .y = 0, .shape = .{ .kind = .underline } }, .{ .kind = .underline } },
        .{ null, .{} },
        .{ .{ .x = 0, .y = 1 }, .{} },
    };
    for (steps) |step| {
        surface.setCursor(step[0]);
        const before = out.written().len;
        try surface.present(std.testing.io, &env, &out.writer);
        try host.feed(out.written()[before..]);
        try std.testing.expectEqual(step[1], try host.cursorShape());
    }
    // Only the move: no DECSCUSR is written again.
    surface.setCursor(.{ .x = 1, .y = 1 });
    const before = out.written().len;
    try surface.present(std.testing.io, &env, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written()[before..], " q") == null);
}
test "default colours present on default-coloured cells only, and leave the cells alone" {
    const Vt = @import("vt").Vt;
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try Surface.init(a, 4, 1);
    defer surface.deinit(&out.writer);
    try surface.put(0, 0, .{ .text = "a", .width = 1 });
    try surface.put(1, 0, .{ .text = "b", .width = 1, .style = .{ .fg = .{ .rgb = .{ 9, 9, 9 } }, .bg = .{ .rgb = .{ 8, 8, 8 } } } });
    surface.setDefaults(.{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .bg = .{ .rgb = .{ 4, 5, 6 } } });
    try surface.present(std.testing.io, &env, &out.writer);
    try std.testing.expectEqual(types.Color.default, surface.get(0, 0).?.style.bg);
    var vt = try Vt.init(a, .{ .cols = 4, .rows = 1 });
    defer vt.deinit();
    try vt.feed(out.written());
    const row = vt.rows().active;
    const expectCell = struct {
        fn at(v: *Vt, al: std.mem.Allocator, r: u64, x: u16, fg: types.Color, bg: types.Color) !void {
            const cell = try v.readCell(al, v.rows().epoch, r, x);
            defer al.free(cell.text);
            try std.testing.expectEqual(fg, cell.style.fg);
            try std.testing.expectEqual(bg, cell.style.bg);
        }
    }.at;
    try expectCell(&vt, a, row, 0, .{ .rgb = .{ 1, 2, 3 } }, .{ .rgb = .{ 4, 5, 6 } });
    try expectCell(&vt, a, row, 1, .{ .rgb = .{ 9, 9, 9 } }, .{ .rgb = .{ 8, 8, 8 } });
    // An empty cell gets the ground too, and it survives a resize.
    try expectCell(&vt, a, row, 3, .{ .rgb = .{ 1, 2, 3 } }, .{ .rgb = .{ 4, 5, 6 } });
    try surface.resize(5, 1);
    try std.testing.expectEqual(types.Color{ .rgb = .{ 4, 5, 6 } }, surface.defaults.bg);
    // Changing them redraws every cell, with no cell having changed.
    try surface.present(std.testing.io, &env, &out.writer);
    surface.setDefaults(.{ .fg = .{ .rgb = .{ 1, 2, 3 } }, .bg = .{ .rgb = .{ 7, 7, 7 } } });
    try std.testing.expectEqual(@as(u16, 5), surface.damage.?.width);
    const before = out.written().len;
    try surface.present(std.testing.io, &env, &out.writer);
    try vt.resize(5, 1);
    try vt.feed(out.written()[before..]);
    try expectCell(&vt, a, vt.rows().active, 3, .{ .rgb = .{ 1, 2, 3 } }, .{ .rgb = .{ 7, 7, 7 } });
}
test "without default colours a surface leaves them to the terminal" {
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try Surface.init(a, 4, 1);
    defer surface.deinit(&out.writer);
    try surface.put(0, 0, .{ .text = "a", .width = 1 });
    surface.setDefaults(.{});
    try surface.present(std.testing.io, &env, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "48;2") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "38;2") == null);
}
test "failed presentation retains damage and redraws on retry" {
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try Surface.init(a, 8, 2);
    defer surface.deinit(&out.writer);
    try surface.text(.{ .width = 8, .height = 1 }, "first", .{});
    try surface.present(std.testing.io, &env, &out.writer);
    try surface.put(0, 0, .{ .text = "z" });
    var failed: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, surface.present(std.testing.io, &env, &failed));
    try std.testing.expect(surface.damage != null);
    const before = out.written().len;
    try surface.present(std.testing.io, &env, &out.writer);
    try std.testing.expectEqual(@as(?Region, null), surface.damage);
    try std.testing.expect(out.written().len > before);
}
