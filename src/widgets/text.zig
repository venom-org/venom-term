//! Styled spans, grapheme widths, word wrapping and clipped line drawing.
//! Grapheme segmentation and widths come from the backend, but no backend
//! type is part of this API.
const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types");
const Surface = @import("../surface.zig").Surface;
const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;
const Role = theme_mod.Role;
const Style = types.Style;

/// A run of text in one theme role. `style`, when set, is overlaid on the
/// role's style (for example `.{ .bold = true }` for unread rows).
pub const Span = struct {
    text: []const u8,
    role: Role = .normal,
    style: ?Style = null,

    pub fn resolve(self: Span, theme: *const Theme) Style {
        const base = theme.style(self.role);
        return if (self.style) |s| theme_mod.overlay(base, s) else base;
    }
};

pub const Kind = enum { glyph, space, newline, skip };

/// End offset of the grapheme that starts at `pos` (`pos < str.len`).
pub fn nextGrapheme(str: []const u8, pos: usize) usize {
    var iter = vaxis.unicode.graphemeIterator(str[pos..]);
    const g = iter.next() orelse return str.len;
    return pos + @max(g.len, 1);
}

/// Start offset of the grapheme that ends at `pos`, scanning from `from`.
pub fn prevGrapheme(str: []const u8, from: usize, pos: usize) usize {
    var i = from;
    var last = from;
    while (i < pos) {
        last = i;
        i = nextGrapheme(str, i);
    }
    return last;
}

pub fn kind(g: []const u8) Kind {
    if (g.len == 0) return .skip;
    if (g[0] == '\n' or (g.len >= 2 and g[0] == '\r' and g[1] == '\n')) return .newline;
    if (g[0] == ' ' or g[0] == '\t') return .space;
    if (g[0] < 0x20 or g[0] == 0x7f) return .skip;
    return .glyph;
}

/// Display width of one grapheme: 0 for control characters, 1 for spaces.
pub fn graphemeWidth(g: []const u8) u16 {
    return switch (kind(g)) {
        .glyph => @intCast(@min(vaxis.gwidth.gwidth(g, .unicode), 2)),
        .space => 1,
        .newline, .skip => 0,
    };
}

/// Display width of a single line of text.
pub fn width(str: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        const end = nextGrapheme(str, i);
        total += graphemeWidth(str[i..end]);
        i = end;
    }
    return total;
}

pub fn spansWidth(spans: []const Span) usize {
    var total: usize = 0;
    for (spans) |s| total += width(s.text);
    return total;
}

/// A byte range of one span.
pub const Segment = struct { span: u32, start: u32, end: u32 };
/// A visual line: `segments[seg_start..seg_end]`, `width` columns.
pub const Line = struct { seg_start: u32, seg_end: u32, width: u16 };

/// Wrapped lines over caller-owned spans. Reuse it between frames.
pub const Wrapped = struct {
    segments: std.ArrayList(Segment) = .empty,
    lines: std.ArrayList(Line) = .empty,

    pub const empty: Wrapped = .{};

    pub fn deinit(self: *Wrapped, gpa: std.mem.Allocator) void {
        self.segments.deinit(gpa);
        self.lines.deinit(gpa);
    }
    pub fn clear(self: *Wrapped) void {
        self.segments.clearRetainingCapacity();
        self.lines.clearRetainingCapacity();
    }
    pub fn lineSegments(self: *const Wrapped, line: Line) []const Segment {
        return self.segments.items[line.seg_start..line.seg_end];
    }
};

const Walker = struct {
    spans: []const Span,
    span: usize = 0,
    byte: usize = 0,

    const G = struct { span: usize, start: usize, end: usize, bytes: []const u8, width: u16, kind: Kind };

    fn peek(self: *Walker) ?G {
        while (self.span < self.spans.len and self.byte >= self.spans[self.span].text.len) {
            self.span += 1;
            self.byte = 0;
        }
        if (self.span >= self.spans.len) return null;
        const str = self.spans[self.span].text;
        const end = nextGrapheme(str, self.byte);
        const bytes = str[self.byte..end];
        return .{ .span = self.span, .start = self.byte, .end = end, .bytes = bytes, .width = graphemeWidth(bytes), .kind = kind(bytes) };
    }
    fn advance(self: *Walker, g: G) void {
        self.span = g.span;
        self.byte = g.end;
    }
};

const Builder = struct {
    gpa: std.mem.Allocator,
    spans: []const Span,
    out: *Wrapped,
    seg_start: u32,
    col: u16 = 0,

    fn emit(self: *Builder, g: Walker.G) !void {
        const segs = &self.out.segments;
        if (segs.items.len > self.seg_start) {
            const last = &segs.items[segs.items.len - 1];
            if (last.span == g.span and last.end == g.start) {
                last.end = @intCast(g.end);
                self.col += g.width;
                return;
            }
        }
        try segs.append(self.gpa, .{ .span = @intCast(g.span), .start = @intCast(g.start), .end = @intCast(g.end) });
        self.col += g.width;
    }
    /// Drops spaces at the end of the line, before a soft break.
    fn trimTrailing(self: *Builder) void {
        const segs = &self.out.segments;
        while (segs.items.len > self.seg_start) {
            const last = &segs.items[segs.items.len - 1];
            const str = self.spans[last.span].text;
            while (last.end > last.start and (str[last.end - 1] == ' ' or str[last.end - 1] == '\t')) {
                last.end -= 1;
                self.col -= 1;
            }
            if (last.end > last.start) return;
            segs.items.len -= 1;
        }
    }
    fn finish(self: *Builder) !void {
        try self.out.lines.append(self.gpa, .{ .seg_start = self.seg_start, .seg_end = @intCast(self.out.segments.items.len), .width = self.col });
        self.seg_start = @intCast(self.out.segments.items.len);
        self.col = 0;
    }
};

/// Word-wraps `spans` to `max_width` columns and appends the lines to `out`.
/// Newlines break hard; spaces at a soft break are dropped; words wider
/// than the line break between graphemes. Empty input yields one empty line,
/// whatever `out` already holds.
pub fn wrap(gpa: std.mem.Allocator, out: *Wrapped, spans: []const Span, max_width: u16) !void {
    const w = @max(max_width, 1);
    const first_line = out.lines.items.len;
    var walker: Walker = .{ .spans = spans };
    var b: Builder = .{ .gpa = gpa, .spans = spans, .out = out, .seg_start = @intCast(out.segments.items.len) };
    var soft = false; // the current line started at a soft break
    while (walker.peek()) |g| {
        switch (g.kind) {
            .newline => {
                walker.advance(g);
                try b.finish();
                soft = false;
            },
            .skip => walker.advance(g),
            .space => {
                walker.advance(g);
                if (b.col == 0 and soft) continue;
                if (b.col + 1 > w) {
                    try b.finish();
                    soft = true;
                    continue;
                }
                try b.emit(g);
            },
            .glyph => {
                // Measure the word that starts here.
                var probe = walker;
                var ww: usize = 0;
                while (probe.peek()) |p| {
                    if (p.kind == .space or p.kind == .newline) break;
                    ww += p.width;
                    probe.advance(p);
                }
                if (b.col > 0 and b.col + ww > w and ww <= w) {
                    b.trimTrailing();
                    try b.finish();
                    soft = true;
                }
                // Emit the word, breaking it if it is wider than a line.
                while (walker.peek()) |p| {
                    if (p.kind == .space or p.kind == .newline) break;
                    walker.advance(p);
                    if (p.kind == .skip) continue;
                    if (b.col > 0 and b.col + p.width > w) {
                        try b.finish();
                        soft = true;
                    }
                    try b.emit(p);
                }
            },
        }
    }
    if (b.col > 0 or out.lines.items.len == first_line or out.segments.items.len > b.seg_start or endsWithNewline(spans))
        try b.finish();
}

fn endsWithNewline(spans: []const Span) bool {
    var i = spans.len;
    while (i > 0) {
        i -= 1;
        const t = spans[i].text;
        if (t.len == 0) continue;
        return t[t.len - 1] == '\n';
    }
    return false;
}

/// Draws one grapheme cell; returns the columns used (0 if it didn't fit).
fn putGrapheme(surface: *Surface, x: u32, y: u16, right: u32, g: []const u8, style: Style) !u16 {
    const k = kind(g);
    if (k == .skip or k == .newline) return 0;
    const gw = graphemeWidth(g);
    if (gw == 0) return 0;
    if (x + gw > right) return 0;
    const glyph = if (k == .space) " " else g;
    try surface.put(@intCast(x), y, .{ .text = glyph, .width = @intCast(gw), .style = style });
    if (gw == 2) try surface.put(@intCast(x + 1), y, .{ .text = "", .width = 0, .style = style });
    return gw;
}

pub const DrawOptions = struct {
    /// Overlaid on every span style (for example a selection background).
    overlay: ?Style = null,
    /// Ends with `…` when the text doesn't fit.
    ellipsis: bool = false,
    /// Fills the rest of `max_width` with blanks in this style.
    fill: ?Style = null,
};

fn applyOverlay(style: Style, opts: DrawOptions) Style {
    return if (opts.overlay) |o| theme_mod.overlay(style, o) else style;
}

/// Draws spans on one row from `x`, clipped to `max_width` columns.
/// Newlines are not interpreted. Returns the columns used.
pub fn drawSpans(surface: *Surface, x: u16, y: u16, max_width: u16, spans: []const Span, theme: *const Theme, opts: DrawOptions) !u16 {
    if (y >= surface.height) return 0;
    const right: u32 = @min(@as(u32, x) + max_width, surface.width);
    const total = spansWidth(spans);
    const truncate = opts.ellipsis and total > max_width and max_width > 0;
    const limit: u32 = if (truncate) right - 1 else right;
    var col: u32 = x;
    outer: for (spans) |span| {
        const style = applyOverlay(span.resolve(theme), opts);
        var i: usize = 0;
        while (i < span.text.len) {
            const end = nextGrapheme(span.text, i);
            const g = span.text[i..end];
            i = end;
            const gw = graphemeWidth(g);
            if (gw == 0) continue;
            if (col + gw > limit) break :outer;
            col += try putGrapheme(surface, col, y, limit, g, style);
        }
    }
    if (truncate) {
        const style = applyOverlay(if (spans.len > 0) spans[spans.len - 1].resolve(theme) else theme.style(.normal), opts);
        if (col < right) {
            try surface.put(@intCast(col), y, .{ .text = "…", .style = style });
            col += 1;
        }
    }
    if (opts.fill) |fill| while (col < right) : (col += 1) {
        try surface.put(@intCast(col), y, .{ .style = fill });
    };
    return @intCast(col - x);
}

/// Draws a single string in a role; see `drawSpans`.
pub fn drawText(surface: *Surface, x: u16, y: u16, max_width: u16, str: []const u8, role: Role, theme: *const Theme, opts: DrawOptions) !u16 {
    return drawSpans(surface, x, y, max_width, &.{.{ .text = str, .role = role }}, theme, opts);
}

/// Draws one wrapped line produced by `wrap` over the same spans.
pub fn drawLine(surface: *Surface, x: u16, y: u16, max_width: u16, spans: []const Span, wrapped: *const Wrapped, line: Line, theme: *const Theme, opts: DrawOptions) !u16 {
    if (y >= surface.height) return 0;
    const right: u32 = @min(@as(u32, x) + max_width, surface.width);
    var col: u32 = x;
    outer: for (wrapped.lineSegments(line)) |seg| {
        const span = spans[seg.span];
        const style = applyOverlay(span.resolve(theme), opts);
        const str = span.text[0..seg.end];
        var i: usize = seg.start;
        while (i < str.len) {
            const end = nextGrapheme(str, i);
            const g = str[i..end];
            i = end;
            const gw = graphemeWidth(g);
            if (gw == 0) continue;
            if (col + gw > right) break :outer;
            col += try putGrapheme(surface, col, y, right, g, style);
        }
    }
    if (opts.fill) |fill| while (col < right) : (col += 1) {
        try surface.put(@intCast(col), y, .{ .style = fill });
    };
    return @intCast(col - x);
}

/// Test helper: the text of one surface row, wide tails skipped, trailing
/// blanks trimmed. Caller frees.
pub fn rowText(gpa: std.mem.Allocator, surface: *const Surface, y: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..surface.width) |x| {
        const cell = surface.get(@intCast(x), y).?;
        if (cell.width == 0) continue;
        try out.appendSlice(gpa, if (cell.text.len == 0) " " else cell.text);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

fn lineString(gpa: std.mem.Allocator, spans: []const Span, w: *const Wrapped, line: Line) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (w.lineSegments(line)) |seg| try out.appendSlice(gpa, spans[seg.span].text[seg.start..seg.end]);
    return out.toOwnedSlice(gpa);
}

fn expectWrap(spans: []const Span, w: u16, expected: []const []const u8) !void {
    const a = std.testing.allocator;
    var wrapped: Wrapped = .empty;
    defer wrapped.deinit(a);
    try wrap(a, &wrapped, spans, w);
    var got: std.ArrayList([]u8) = .empty;
    defer {
        for (got.items) |s| a.free(s);
        got.deinit(a);
    }
    for (wrapped.lines.items) |line| {
        const s = try lineString(a, spans, &wrapped, line);
        try got.append(a, s);
        try std.testing.expect(line.width <= w);
        try std.testing.expectEqual(width(s), line.width);
    }
    if (got.items.len != expected.len) {
        std.debug.print("got {d} lines:\n", .{got.items.len});
        for (got.items) |s| std.debug.print("  '{s}'\n", .{s});
        return error.TestExpectedEqual;
    }
    for (expected, got.items) |e, g| try std.testing.expectEqualStrings(e, g);
}

test "word wrap breaks at spaces, drops break spaces and splits long words" {
    try expectWrap(&.{.{ .text = "the quick brown fox" }}, 10, &.{ "the quick", "brown fox" });
    try expectWrap(&.{.{ .text = "abcdefghij klm" }}, 4, &.{ "abcd", "efgh", "ij", "klm" });
    try expectWrap(&.{.{ .text = "one\n\ntwo" }}, 10, &.{ "one", "", "two" });
    try expectWrap(&.{.{ .text = "" }}, 5, &.{""});
    try expectWrap(&.{.{ .text = "end\n" }}, 5, &.{ "end", "" });
    try expectWrap(&.{.{ .text = "a  b" }}, 10, &.{"a  b"});
}

test "wrap crosses spans and keeps wide graphemes whole" {
    // "Edit" + " frame.zig": the word "frame.zig" is split across spans.
    try expectWrap(&.{ .{ .text = "Edit fra", .role = .accent }, .{ .text = "me.zig" } }, 9, &.{ "Edit", "frame.zig" });
    try expectWrap(&.{.{ .text = "界界界" }}, 5, &.{ "界界", "界" });
    try expectWrap(&.{.{ .text = "e\xcc\x81e\xcc\x81e\xcc\x81" }}, 2, &.{ "e\xcc\x81e\xcc\x81", "e\xcc\x81" });
    try expectWrap(&.{.{ .text = "a\x1bb\tc" }}, 10, &.{"ab\tc"});
}

test "wrap appends: empty input gives one line after earlier lines too" {
    const a = std.testing.allocator;
    var wrapped: Wrapped = .empty;
    defer wrapped.deinit(a);
    try wrap(a, &wrapped, &.{.{ .text = "one" }}, 5);
    try wrap(a, &wrapped, &.{.{ .text = "" }}, 5);
    try wrap(a, &wrapped, &.{}, 5);
    try wrap(a, &wrapped, &.{.{ .text = "two three" }}, 5);
    try std.testing.expectEqual(@as(usize, 5), wrapped.lines.items.len);
    try std.testing.expectEqual(@as(usize, 0), wrapped.lineSegments(wrapped.lines.items[1]).len);
    try std.testing.expectEqual(@as(usize, 0), wrapped.lineSegments(wrapped.lines.items[2]).len);
    try std.testing.expectEqual(@as(u16, 3), wrapped.lines.items[3].width);
    try std.testing.expectEqual(@as(u16, 5), wrapped.lines.items[4].width);
}

test "drawSpans clips, ellipsizes and fills" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 10, 2);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    const used = try drawText(&surface, 1, 0, 6, "hello world", .normal, &theme, .{ .ellipsis = true });
    try std.testing.expectEqual(@as(u16, 6), used);
    const row = try rowText(a, &surface, 0);
    defer a.free(row);
    try std.testing.expectEqualStrings(" hello…", row);
    _ = try drawText(&surface, 0, 1, 3, "a界b", .accent, &theme, .{ .overlay = theme.style(.selection) });
    _ = try drawText(&surface, 5, 1, 4, "z", .normal, &theme, .{ .fill = theme.style(.selection) });
    const row1 = try rowText(a, &surface, 1);
    defer a.free(row1);
    try std.testing.expectEqualStrings("a界  z", row1);
    try std.testing.expectEqual(types.Color{ .index = 1 }, surface.get(1, 1).?.style.fg);
    try std.testing.expectEqual(types.Color{ .index = 0 }, surface.get(1, 1).?.style.bg);
    try std.testing.expectEqual(types.Color{ .index = 0 }, surface.get(8, 1).?.style.bg);
    try std.testing.expectEqual(types.Color.default, surface.get(9, 1).?.style.bg);
}
