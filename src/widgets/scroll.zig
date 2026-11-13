//! Scroll view over wrapped, styled blocks (the venom
//! transcript). It follows the tail until the user scrolls up, and resumes
//! following when they scroll back to the bottom. Collapsible blocks (tool
//! calls) show a `▸`/`▾` marker and only their first `preview` lines while
//! collapsed; `handleKey` and `handleMouse` report toggles so the product
//! can react (load a body, change density, …). Wrapped lines are cached per
//! block in buffers shared by the whole view, and `assumeUnchanged` lets a
//! caller skip the per-frame key scan (see
//! docs/scroll-cache.md).
const std = @import("std");
const types = @import("types");
const Region = types.Region;
const Surface = @import("../surface.zig").Surface;
const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;
const text = @import("text.zig");
const Span = text.Span;
const keys = @import("keys.zig");
const Key = @import("types").Input.Key;
const Mouse = @import("types").Input.Mouse;
const layout_mod = @import("layout.zig");

pub const Block = struct {
    spans: []const Span,
    collapsible: bool = false,
    collapsed: bool = false,
    /// Lines shown while collapsed.
    preview: u16 = 1,
    /// Left indent of every line, in cells.
    indent: u16 = 0,
    /// The wrap cache re-wraps a block when its spans slice or any span's
    /// text slice (pointer or length) changes, or the width does. Bump this
    /// when you rewrite span bytes in place without changing those slices.
    revision: u32 = 0,
};

pub const Action = union(enum) {
    scrolled,
    /// The selected collapsible block changed.
    selected: usize,
    /// A block was expanded or collapsed.
    toggled: usize,
    /// Every collapsible block was expanded (true) or collapsed (false).
    toggled_all: bool,
};

/// Lines per wheel tick.
pub const wheel_step = 3;

/// One block's range in `ScrollView.wrapped`, and the key it was wrapped for.
const Entry = struct {
    fingerprint: u64 = 0,
    revision: u32 = 0,
    first_line: u32 = 0,
    line_count: u32 = 0,
    /// Wrap width; 0 means the block has no lines in the buffers.
    width: u16 = 0,
};

/// Identifies a block's text by the slices it points at, not its bytes, so
/// checking an unchanged block costs a few word compares.
fn fingerprint(spans: []const Span) u64 {
    var h: std.hash.Wyhash = .init(spans.len);
    h.update(std.mem.asBytes(&@intFromPtr(spans.ptr)));
    for (spans) |s| {
        h.update(std.mem.asBytes(&@intFromPtr(s.text.ptr)));
        h.update(std.mem.asBytes(&s.text.len));
    }
    return h.final();
}

fn wrapWidth(block: Block, width: u16) u16 {
    const gutter: u16 = if (block.collapsible) 2 else 0;
    return @max(width -| block.indent -| gutter, 1);
}

fn isCurrent(e: *const Entry, block: Block, width: u16) bool {
    return e.width == wrapWidth(block, width) and e.revision == block.revision and e.fingerprint == fingerprint(block.spans);
}

/// Visual lines of a wrapped block, given its collapse state.
fn shownLines(e: *const Entry, block: Block) u32 {
    if (block.collapsible and block.collapsed) return @min(e.line_count, @max(block.preview, 1));
    return e.line_count;
}

pub const ScrollView = struct {
    /// First visible line; null follows the tail.
    top: ?usize = null,
    /// The selected collapsible block, the target of toggle keys.
    selected: ?usize = null,
    /// Height of the last draw, for page keys.
    page: u16 = 10,
    /// Region of the last draw, for mouse hits.
    area: Region = .{ .width = 0, .height = 0 },
    reveal: bool = false,
    /// Per-block wrap cache, parallel to the blocks of the last layout.
    entries: std.ArrayList(Entry) = .empty,
    /// The lines and segments of every block; `entries` holds the ranges.
    wrapped: text.Wrapped = .empty,
    /// First visual line of each block, then the total line count.
    starts: std.ArrayList(u32) = .empty,
    /// Blocks wrapped so far; unchanged blocks are never re-wrapped.
    wraps: u64 = 0,
    /// Block keys compared so far; `assumeUnchanged` keeps this flat.
    scans: u64 = 0,
    /// Lines and segments in `wrapped` that no entry points at any more.
    garbage_lines: usize = 0,
    garbage_segments: usize = 0,
    /// Pending `assumeUnchanged` promise, for the next layout only.
    promise: ?usize = null,
    /// `toggle` and `handleKey` changed this block; it overrides a promise.
    dirty_from: usize = std.math.maxInt(usize),
    /// Width of the last layout, and how many of its blocks are laid out
    /// (fewer than it was given if it failed).
    laid_width: u16 = 0,
    laid_blocks: usize = 0,

    pub fn deinit(self: *ScrollView, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
        self.wrapped.deinit(gpa);
        self.starts.deinit(gpa);
        self.* = undefined;
    }

    pub fn following(self: *const ScrollView) bool {
        return self.top == null;
    }
    pub fn follow(self: *ScrollView) void {
        self.top = null;
    }

    /// Promises that blocks `0..prefix` are unchanged since the last layout,
    /// so the next layout, and only that one, skips them: no key compare and
    /// no prefix sum, which makes a tail draw O(new blocks). "Unchanged" means
    /// every `Block` field and every byte the spans point at, so
    /// `assumeUnchanged(old_len)` after appending, and
    /// `assumeUnchanged(len - 1)` while the last block streams.
    ///
    /// It is optional and one-shot: a layout with no promise compares every
    /// key, so forgetting this costs time and never shows stale lines. Calling
    /// it twice keeps the smaller prefix. A width change, `toggle` and
    /// `handleKey` override it. `setAll` can't (it has no view), so don't
    /// promise past a block it changed. A broken promise panics in Debug and
    /// ReleaseSafe; in ReleaseFast it draws stale lines or reads out of bounds.
    pub fn assumeUnchanged(self: *ScrollView, prefix: usize) void {
        self.promise = @min(self.promise orelse prefix, prefix);
    }

    /// How many leading blocks the next layout may skip; clears the hints.
    fn takeHint(self: *ScrollView, blocks: usize, width: u16) usize {
        const promised = self.promise orelse 0;
        const dirty = self.dirty_from;
        self.promise = null;
        self.dirty_from = std.math.maxInt(usize);
        if (width != self.laid_width) return 0;
        return @min(promised, dirty, blocks, self.laid_blocks);
    }

    /// The first block in `0..keep` that an `assumeUnchanged` got wrong.
    fn brokenPromise(self: *const ScrollView, blocks: []const Block, width: u16, keep: usize) ?usize {
        for (blocks[0..keep], self.entries.items[0..keep], 0..) |block, *e, i| {
            if (!isCurrent(e, block, width)) return i;
            if (self.starts.items[i + 1] - self.starts.items[i] != shownLines(e, block)) return i;
        }
        return null;
    }

    /// Lays `blocks` out for `width` columns. `draw` calls it; call it
    /// directly to query `lineCount` or `blockAt` without drawing. Only
    /// blocks that are new or changed since the last call (see
    /// `Block.revision`), or all of them after a width change, are
    /// re-wrapped; the rest costs a key compare and an add per block, unless
    /// `assumeUnchanged` skips them.
    pub fn layout(self: *ScrollView, gpa: std.mem.Allocator, blocks: []const Block, width: u16) !void {
        const keep = self.takeHint(blocks.len, width);
        if (std.debug.runtime_safety) if (self.brokenPromise(blocks, width, keep)) |i|
            std.debug.panic("ScrollView.assumeUnchanged({d}): block {d} changed", .{ keep, i });
        self.laid_width = width;
        self.laid_blocks = keep;

        while (self.entries.items.len > blocks.len) {
            const e = &self.entries.items[self.entries.items.len - 1];
            if (e.width != 0) self.release(e);
            self.entries.items.len -= 1;
        }
        try self.entries.appendNTimes(gpa, .{}, blocks.len - self.entries.items.len);
        try self.starts.resize(gpa, blocks.len + 1);

        // Up to the first stale block, one pass does it all. Most frames end here.
        var total: u32 = if (keep > 0) self.starts.items[keep] else 0;
        var clean = keep;
        while (clean < blocks.len and isCurrent(&self.entries.items[clean], blocks[clean], width)) : (clean += 1) {
            self.starts.items[clean] = total;
            total += shownLines(&self.entries.items[clean], blocks[clean]);
        }
        self.scans += blocks.len - keep;
        if (clean < blocks.len) {
            // Last block first: a run of stale blocks at the end of the
            // buffers (a resize, a streaming tail) frees its space as it goes.
            var i = blocks.len;
            while (i > clean) {
                i -= 1;
                const e = &self.entries.items[i];
                if (e.width != 0 and !isCurrent(e, blocks[i], width)) self.release(e);
            }
            try self.compactIfWorthIt(gpa);
            for (blocks[clean..], self.entries.items[clean..], self.starts.items[clean..blocks.len]) |block, *e, *start| {
                if (e.width == 0) try self.wrapBlock(gpa, e, block, width);
                start.* = total;
                total += shownLines(e, block);
            }
        }
        self.starts.items[blocks.len] = total;
        self.laid_blocks = blocks.len;
    }

    fn wrapBlock(self: *ScrollView, gpa: std.mem.Allocator, e: *Entry, block: Block, width: u16) !void {
        const lines = &self.wrapped.lines;
        const segments = &self.wrapped.segments;
        const first_line = lines.items.len;
        const first_segment = segments.items.len;
        errdefer {
            lines.items.len = first_line;
            segments.items.len = first_segment;
        }
        const w = wrapWidth(block, width);
        try text.wrap(gpa, &self.wrapped, block.spans, w);
        e.* = .{
            .fingerprint = fingerprint(block.spans),
            .revision = block.revision,
            .first_line = @intCast(first_line),
            .line_count = @intCast(lines.items.len - first_line),
            .width = w,
        };
        self.wraps += 1;
    }

    /// Takes a block's lines out of the buffers. At their end the space is
    /// reused right away; elsewhere it waits for `compactIfWorthIt`.
    fn release(self: *ScrollView, e: *Entry) void {
        const lines = self.wrapped.lines.items[e.first_line..][0..e.line_count];
        const first_segment = lines[0].seg_start;
        const end_segment = lines[lines.len - 1].seg_end;
        if (e.first_line + e.line_count == self.wrapped.lines.items.len) {
            self.wrapped.lines.items.len = e.first_line;
            self.wrapped.segments.items.len = first_segment;
        } else {
            self.garbage_lines += lines.len;
            self.garbage_segments += end_segment - first_segment;
        }
        e.* = .{};
    }

    /// Rewrites the buffers once more of them is garbage than live data, so
    /// the copy is paid for by the wraps that made the garbage and the buffers
    /// stay within about twice the live size however often blocks are edited.
    fn compactIfWorthIt(self: *ScrollView, gpa: std.mem.Allocator) !void {
        const live_lines = self.wrapped.lines.items.len - self.garbage_lines;
        const live_segments = self.wrapped.segments.items.len - self.garbage_segments;
        if (self.garbage_lines + self.garbage_segments <= live_lines + live_segments) return;
        var out: text.Wrapped = .empty;
        errdefer out.deinit(gpa);
        try out.lines.ensureTotalCapacityPrecise(gpa, live_lines);
        try out.segments.ensureTotalCapacityPrecise(gpa, live_segments);
        for (self.entries.items) |*e| {
            if (e.width == 0) continue;
            const lines = self.wrapped.lines.items[e.first_line..][0..e.line_count];
            const old = lines[0].seg_start;
            const new: u32 = @intCast(out.segments.items.len);
            e.first_line = @intCast(out.lines.items.len);
            out.segments.appendSliceAssumeCapacity(self.wrapped.segments.items[old..lines[lines.len - 1].seg_end]);
            for (lines) |line| out.lines.appendAssumeCapacity(.{
                .seg_start = line.seg_start - old + new,
                .seg_end = line.seg_end - old + new,
                .width = line.width,
            });
        }
        self.wrapped.deinit(gpa);
        self.wrapped = out;
        self.garbage_lines = 0;
        self.garbage_segments = 0;
    }

    /// Visual lines from the last layout.
    pub fn lineCount(self: *const ScrollView) usize {
        return if (self.starts.items.len == 0) 0 else self.starts.items[self.starts.items.len - 1];
    }

    /// The block that holds visual line `line` (`line < lineCount()`).
    fn blockOfLine(self: *const ScrollView, line: usize) usize {
        // Last block whose start is <= line; blocks have at least one line.
        const starts = self.starts.items[0 .. self.starts.items.len - 1];
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] <= line) lo = mid else hi = mid;
        }
        return lo;
    }

    /// The block shown at a viewport row of the last draw (for mouse hits).
    pub fn blockAt(self: *const ScrollView, row: usize) ?usize {
        const i = self.effectiveTop() + row;
        if (i >= self.lineCount()) return null;
        return self.blockOfLine(i);
    }

    fn maxTop(self: *const ScrollView) usize {
        return self.lineCount() -| self.page;
    }
    fn effectiveTop(self: *const ScrollView) usize {
        return @min(self.top orelse self.maxTop(), self.maxTop());
    }

    /// Scrolls by lines; reaching the bottom resumes following.
    pub fn scrollBy(self: *ScrollView, delta: isize) void {
        const cur: isize = @intCast(self.effectiveTop());
        const max: isize = @intCast(self.maxTop());
        const next = std.math.clamp(cur + delta, 0, max);
        self.top = if (next >= max) null else @intCast(next);
    }

    pub fn toggle(self: *ScrollView, blocks: []Block, index: usize) void {
        if (index >= blocks.len or !blocks[index].collapsible) return;
        blocks[index].collapsed = !blocks[index].collapsed;
        self.dirty_from = @min(self.dirty_from, index);
        self.selected = index;
        self.reveal = true;
    }

    pub fn setAll(blocks: []Block, expanded: bool) void {
        for (blocks) |*b| if (b.collapsible) {
            b.collapsed = !expanded;
        };
    }

    /// Selects the next (dir > 0) or previous collapsible block.
    pub fn selectNext(self: *ScrollView, blocks: []const Block, dir: isize) ?usize {
        if (blocks.len == 0) return null;
        var i: isize = if (self.selected) |s| @intCast(@min(s, blocks.len - 1)) else if (dir > 0) -1 else @intCast(blocks.len);
        while (true) {
            i += if (dir > 0) 1 else -1;
            if (i < 0 or i >= @as(isize, @intCast(blocks.len))) return null;
            if (blocks[@intCast(i)].collapsible) {
                self.selected = @intCast(i);
                self.reveal = true;
                return self.selected;
            }
        }
    }

    /// Default bindings: ↑/k ↓/j by line, PgUp/PgDn, Home (top), End
    /// (follow), n/p select the next/previous collapsible block,
    /// Enter/Space toggles it, E/C expand or collapse all.
    pub fn handleKey(self: *ScrollView, blocks: []Block, key: Key) ?Action {
        const page: isize = @max(1, @as(isize, self.page) - 1);
        if (keys.named(key, .up) or keys.char(key, 'k')) {
            self.scrollBy(-1);
        } else if (keys.named(key, .down) or keys.char(key, 'j')) {
            self.scrollBy(1);
        } else if (keys.named(key, .page_up)) {
            self.scrollBy(-page);
        } else if (keys.named(key, .page_down)) {
            self.scrollBy(page);
        } else if (keys.named(key, .home)) {
            self.top = 0;
        } else if (keys.named(key, .end)) {
            self.follow();
        } else if (keys.char(key, 'n')) {
            return .{ .selected = self.selectNext(blocks, 1) orelse return null };
        } else if (keys.char(key, 'p')) {
            return .{ .selected = self.selectNext(blocks, -1) orelse return null };
        } else if (keys.named(key, .enter) or keys.char(key, ' ')) {
            const s = self.selected orelse return null;
            if (s >= blocks.len or !blocks[s].collapsible) return null;
            self.toggle(blocks, s);
            return .{ .toggled = s };
        } else if (keys.char(key, 'E') or keys.char(key, 'C')) {
            const expand = keys.char(key, 'E');
            setAll(blocks, expand);
            self.dirty_from = 0;
            return .{ .toggled_all = expand };
        } else return null;
        return .scrolled;
    }

    /// Mouse bindings over the region of the last draw: the wheel scrolls
    /// by `wheel_step` lines; a left click on a collapsible block's first
    /// line toggles it, and on its other lines selects it.
    pub fn handleMouse(self: *ScrollView, blocks: []Block, mouse: Mouse) ?Action {
        const cell = layout_mod.hit(self.area, mouse.x, mouse.y) orelse return null;
        switch (mouse.button) {
            .wheel_up, .wheel_down => {
                if (mouse.action != .press) return null;
                self.scrollBy(if (mouse.button == .wheel_up) -wheel_step else wheel_step);
                return .scrolled;
            },
            .left => {
                if (mouse.action != .press) return null;
                const line = self.effectiveTop() + cell.row;
                const b = self.blockAt(cell.row) orelse return null;
                if (b >= blocks.len or !blocks[b].collapsible) return null;
                if (line == self.starts.items[b]) {
                    self.toggle(blocks, b);
                    return .{ .toggled = b };
                }
                self.selected = b;
                return .{ .selected = b };
            },
            else => return null,
        }
    }

    pub fn draw(self: *ScrollView, gpa: std.mem.Allocator, surface: *Surface, region: Region, blocks: []const Block, theme: *const Theme, focused: bool) !void {
        self.page = region.height;
        self.area = region;
        if (region.width == 0 or region.height == 0) {
            // No layout to spend it on, and it must not reach a later frame.
            self.promise = null;
            return;
        }
        try self.layout(gpa, blocks, region.width);
        if (self.selected) |s| if (s >= blocks.len) {
            self.selected = null;
        };
        // Bring a newly selected or toggled block into view.
        if (self.reveal) {
            self.reveal = false;
            if (self.selected) |s| {
                const f = self.starts.items[s];
                const last = self.starts.items[s + 1] - 1;
                const top = self.effectiveTop();
                if (f < top) {
                    self.top = f;
                } else if (last >= top + region.height) {
                    self.top = @min(f, last + 1 - region.height);
                }
                if (self.top != null and self.top.? >= self.maxTop()) self.top = null;
            }
        }
        if (self.top) |t| if (t >= self.maxTop()) {
            self.top = null;
        };
        const top = self.effectiveTop();
        const total = self.lineCount();
        const blank = theme.style(.normal);
        const sel_style = theme.style(.selection);
        var bi: usize = if (top < total) self.blockOfLine(top) else 0;
        for (0..region.height) |row| {
            const y: u16 = region.y + @as(u16, @intCast(row));
            const vi = top + row;
            if (vi >= total) {
                try surface.clear(.{ .x = region.x, .y = y, .width = region.width, .height = 1 }, blank);
                continue;
            }
            while (vi >= self.starts.items[bi + 1]) bi += 1;
            const block = blocks[bi];
            const entry = &self.entries.items[bi];
            const k = vi - self.starts.items[bi];
            const first = k == 0;
            const is_sel = self.selected != null and self.selected.? == bi;
            const overlay: ?types.Style = if (is_sel and focused and first) sel_style else null;
            const fill = if (overlay) |o| theme_mod.overlay(blank, o) else blank;
            var x = region.x;
            const right = region.x + region.width;
            for (0..@min(block.indent, region.width)) |_| {
                try surface.put(x, y, .{ .style = fill });
                x += 1;
            }
            if (block.collapsible and x < right) {
                const marker: []const u8 = if (!first) "  " else if (block.collapsed) "▸ " else "▾ ";
                x += try text.drawText(surface, x, y, right - x, marker, if (is_sel) .accent else .muted, theme, .{ .overlay = overlay });
            }
            if (x < right)
                _ = try text.drawLine(surface, x, y, right - x, block.spans, &self.wrapped, self.wrapped.lines.items[entry.first_line + k], theme, .{ .overlay = overlay, .fill = fill });
        }
    }
};

fn expectRows(surface: *const Surface, rows: []const []const u8) !void {
    const a = std.testing.allocator;
    for (rows, 0..) |want, y| {
        const got = try text.rowText(a, surface, @intCast(y));
        defer a.free(got);
        try std.testing.expectEqualStrings(want, got);
    }
}

test "scroll view wraps blocks, follows the tail and collapses blocks" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 16, 4);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    var blocks = [_]Block{
        .{ .spans = &.{.{ .text = "fix the frame codec please" }} },
        .{ .spans = &.{ .{ .text = "Bash", .role = .accent }, .{ .text = " zig build\nerror: Frame\nexit 1" } }, .collapsible = true, .collapsed = true },
        .{ .spans = &.{.{ .text = "done", .role = .ok }}, .indent = 2 },
    };
    var view: ScrollView = .{};
    defer view.deinit(a);
    const region: Region = .{ .width = 16, .height = 4 };
    try view.draw(a, &surface, region, &blocks, &theme, true);
    // 2 + 1 (collapsed) + 1 lines: everything fits.
    try expectRows(&surface, &.{ "fix the frame", "codec please", "▸ Bash zig build", "  done" });
    try std.testing.expectEqual(@as(usize, 4), view.lineCount());

    // Select and expand the tool call: following keeps the tail visible.
    try std.testing.expectEqual(Action{ .selected = 1 }, view.handleKey(&blocks, keys.testKey('n', .{})).?);
    try std.testing.expectEqual(Action{ .toggled = 1 }, view.handleKey(&blocks, keys.testNamed(.enter)).?);
    try view.draw(a, &surface, region, &blocks, &theme, true);
    try std.testing.expectEqual(@as(usize, 6), view.lineCount());
    try expectRows(&surface, &.{ "▾ Bash zig build", "  error: Frame", "  exit 1", "  done" });
    try std.testing.expectEqual(theme.selection.bg, surface.get(10, 0).?.style.bg);
    try std.testing.expectEqual(@as(?usize, 1), view.blockAt(0));

    // Scrolling up stops following; new output doesn't move the view.
    _ = view.handleKey(&blocks, keys.testNamed(.up));
    try std.testing.expect(!view.following());
    var more: [blocks.len + 1]Block = undefined;
    @memcpy(more[0..blocks.len], &blocks);
    more[blocks.len] = .{ .spans = &.{.{ .text = "more" }} };
    try view.draw(a, &surface, region, &more, &theme, true);
    try expectRows(&surface, &.{ "codec please", "▾ Bash zig build", "  error: Frame", "  exit 1" });
    // Scrolling back down to the bottom resumes following.
    view.page = 4;
    _ = view.handleKey(&blocks, keys.testNamed(.page_down));
    try std.testing.expect(view.following());
    _ = view.handleKey(&blocks, keys.testNamed(.home));
    try view.draw(a, &surface, region, &blocks, &theme, false);
    try expectRows(&surface, &.{ "fix the frame", "codec please", "▾ Bash zig build", "  error: Frame" });
    // C collapses every collapsible block.
    try std.testing.expectEqual(Action{ .toggled_all = false }, view.handleKey(&blocks, keys.testKey('C', .{ .shift = true })).?);
    try std.testing.expect(blocks[1].collapsed);
}

test "scroll view re-wraps on resize" {
    const a = std.testing.allocator;
    var view: ScrollView = .{};
    defer view.deinit(a);
    const blocks = [_]Block{.{ .spans = &.{.{ .text = "alpha beta gamma delta" }} }};
    try view.layout(a, &blocks, 30);
    try std.testing.expectEqual(@as(usize, 1), view.lineCount());
    try view.layout(a, &blocks, 6);
    try std.testing.expectEqual(@as(usize, 4), view.lineCount());
}

test "layout re-wraps only new, changed or resized blocks" {
    const a = std.testing.allocator;
    var view: ScrollView = .{};
    defer view.deinit(a);
    var bufs: [3][16]u8 = undefined;
    var spans: [3][1]Span = undefined;
    var blocks: [3]Block = undefined;
    for (0..3) |i| {
        const t = try std.fmt.bufPrint(&bufs[i], "block {d} words", .{i});
        spans[i] = .{.{ .text = t }};
        blocks[i] = .{ .spans = &spans[i] };
    }
    try view.layout(a, blocks[0..2], 8);
    try std.testing.expectEqual(@as(u64, 2), view.wraps);
    try std.testing.expectEqual(@as(usize, 4), view.lineCount());
    // Unchanged blocks are not re-wrapped; an appended one is.
    try view.layout(a, blocks[0..2], 8);
    try std.testing.expectEqual(@as(u64, 2), view.wraps);
    try view.layout(a, blocks[0..3], 8);
    try std.testing.expectEqual(@as(u64, 3), view.wraps);
    try std.testing.expectEqual(@as(usize, 6), view.lineCount());
    // A span whose text slice grows (streaming) is re-wrapped by itself.
    spans[1][0].text = "block 1 words and more";
    try view.layout(a, &blocks, 8);
    try std.testing.expectEqual(@as(u64, 4), view.wraps);
    try std.testing.expectEqual(@as(usize, 7), view.lineCount());
    try std.testing.expectEqual(@as(?usize, 1), view.blockAt(4));
    // Same slices with rewritten bytes need a revision bump.
    @memcpy(bufs[0][0..5], "xxxxx");
    try view.layout(a, &blocks, 8);
    try std.testing.expectEqual(@as(u64, 4), view.wraps);
    blocks[0].revision += 1;
    try view.layout(a, &blocks, 8);
    try std.testing.expectEqual(@as(u64, 5), view.wraps);
    // Collapsing changes the line count without re-wrapping.
    blocks[2].collapsible = true;
    blocks[2].collapsed = true;
    try view.layout(a, &blocks, 10);
    // Width 10: blocks 0 and 1 re-wrap; block 2's new 2-cell gutter keeps
    // its wrap width at 8, so its lines are reused.
    try std.testing.expectEqual(@as(u64, 7), view.wraps);
    const before = view.wraps;
    blocks[2].collapsed = false;
    try view.layout(a, &blocks, 10);
    try std.testing.expectEqual(before, view.wraps);
    // Fewer blocks drop their cache entries.
    try view.layout(a, blocks[0..1], 10);
    try std.testing.expectEqual(@as(usize, 1), view.entries.items.len);
    try view.layout(a, &.{}, 10);
    try std.testing.expectEqual(@as(usize, 0), view.lineCount());
    try std.testing.expect(view.blockAt(0) == null);
}

test "scroll view draws the tail of a long transcript without re-wrapping it" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 20, 3);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var blocks: std.ArrayList(Block) = .empty;
    defer blocks.deinit(a);
    for (0..10_000) |i| {
        const t = try std.fmt.allocPrint(arena.allocator(), "line {d}", .{i});
        try blocks.append(a, .{ .spans = try arena.allocator().dupe(Span, &.{.{ .text = t }}) });
    }
    var view: ScrollView = .{};
    defer view.deinit(a);
    const region: Region = .{ .width = 20, .height = 3 };
    try view.draw(a, &surface, region, blocks.items, &theme, false);
    try std.testing.expectEqual(@as(u64, 10_000), view.wraps);
    try expectRows(&surface, &.{ "line 9997", "line 9998", "line 9999" });
    try view.draw(a, &surface, region, blocks.items, &theme, false);
    try std.testing.expectEqual(@as(u64, 10_000), view.wraps);
    try blocks.append(a, .{ .spans = &.{.{ .text = "line 10000" }} });
    try view.draw(a, &surface, region, blocks.items, &theme, false);
    try std.testing.expectEqual(@as(u64, 10_001), view.wraps);
    try expectRows(&surface, &.{ "line 9998", "line 9999", "line 10000" });
}

/// Fails unless the view holds exactly what a fresh wrap of `blocks` gives.
fn expectFresh(view: *const ScrollView, blocks: []const Block, width: u16) !void {
    const a = std.testing.allocator;
    try std.testing.expectEqual(blocks.len, view.entries.items.len);
    var total: u32 = 0;
    for (blocks, view.entries.items, 0..) |block, e, i| {
        var fresh: text.Wrapped = .empty;
        defer fresh.deinit(a);
        try text.wrap(a, &fresh, block.spans, wrapWidth(block, width));
        const lines = view.wrapped.lines.items[e.first_line..][0..e.line_count];
        try std.testing.expectEqual(fresh.lines.items.len, lines.len);
        for (fresh.lines.items, lines) |want, got| {
            try std.testing.expectEqual(want.width, got.width);
            try std.testing.expectEqualSlices(text.Segment, fresh.lineSegments(want), view.wrapped.lineSegments(got));
        }
        try std.testing.expectEqual(total, view.starts.items[i]);
        total += shownLines(&e, block);
    }
    try std.testing.expectEqual(@as(usize, total), view.lineCount());
}

test "layout keeps every block's own lines in the shared buffers, empty ones too" {
    const a = std.testing.allocator;
    var view: ScrollView = .{};
    defer view.deinit(a);
    const blocks = [_]Block{
        .{ .spans = &.{.{ .text = "alpha beta gamma" }} },
        .{ .spans = &.{} },
        .{ .spans = &.{.{ .text = "" }} },
        .{ .spans = &.{.{ .text = "\x1b" }} },
        .{ .spans = &.{.{ .text = "tail\n" }} },
    };
    try view.layout(a, &blocks, 6);
    try expectFresh(&view, &blocks, 6);
    // 3 + one empty line each + "tail" and the empty line after its newline.
    try std.testing.expectEqual(@as(usize, 8), view.lineCount());
    try std.testing.expectEqual(@as(?usize, 1), view.blockAt(3));
    try std.testing.expectEqual(@as(?usize, 3), view.blockAt(5));
    try std.testing.expectEqual(@as(?usize, 4), view.blockAt(6));
}

test "with no hint, an edit to an early block is seen and later blocks shift" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 12, 3);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    var buf = "first".*;
    var spans = [_]Span{.{ .text = &buf }};
    var blocks = [_]Block{
        .{ .spans = &spans },
        .{ .spans = &.{.{ .text = "second" }} },
        .{ .spans = &.{.{ .text = "third" }} },
    };
    var view: ScrollView = .{};
    defer view.deinit(a);
    const region: Region = .{ .width = 12, .height = 3 };
    try view.draw(a, &surface, region, &blocks, &theme, false);
    try expectRows(&surface, &.{ "first", "second", "third" });

    // Same slices, new bytes: the revision bump alone must bring it back.
    @memcpy(&buf, "FIRST");
    blocks[0].revision += 1;
    try view.draw(a, &surface, region, &blocks, &theme, false);
    try expectRows(&surface, &.{ "FIRST", "second", "third" });
    try std.testing.expectEqual(@as(u64, 4), view.wraps);

    // A longer first block moves everything after it, in the lines and the
    // index, though its new lines sit after the others in the buffers.
    spans[0].text = "one two three four";
    try view.draw(a, &surface, region, &blocks, &theme, false);
    try std.testing.expectEqual(@as(usize, 4), view.lineCount());
    try std.testing.expectEqual(@as(u32, 2), view.starts.items[1]);
    try expectRows(&surface, &.{ "three four", "second", "third" });
    try expectFresh(&view, &blocks, 12);
}

test "assumeUnchanged makes a tail layout cost only the new blocks" {
    const a = std.testing.allocator;
    var view: ScrollView = .{};
    defer view.deinit(a);
    var blocks: [100]Block = @splat(.{ .spans = &.{.{ .text = "some words to wrap" }} });
    try view.layout(a, blocks[0..90], 8);
    try std.testing.expectEqual(@as(u64, 90), view.scans);
    // A steady redraw looks at nothing.
    view.assumeUnchanged(90);
    try view.layout(a, blocks[0..90], 8);
    try std.testing.expectEqual(@as(u64, 90), view.scans);
    try std.testing.expectEqual(@as(u64, 90), view.wraps);
    // An append looks at the new blocks only.
    view.assumeUnchanged(90);
    try view.layout(a, blocks[0..95], 8);
    try std.testing.expectEqual(@as(u64, 95), view.scans);
    try std.testing.expectEqual(@as(u64, 95), view.wraps);
    try expectFresh(&view, blocks[0..95], 8);
    // A streaming last block re-wraps in place, leaving no garbage.
    blocks[94].spans = &.{.{ .text = "some words to wrap and then some more" }};
    view.assumeUnchanged(94);
    try view.layout(a, blocks[0..95], 8);
    try std.testing.expectEqual(@as(u64, 96), view.scans);
    try std.testing.expectEqual(@as(usize, 0), view.garbage_lines);
    try expectFresh(&view, blocks[0..95], 8);
}

test "assumeUnchanged is one-shot, so the next layout sees an edit" {
    const a = std.testing.allocator;
    var view: ScrollView = .{};
    defer view.deinit(a);
    var blocks = [_]Block{ .{ .spans = &.{.{ .text = "one" }} }, .{ .spans = &.{.{ .text = "two" }} } };
    try view.layout(a, &blocks, 20);
    view.assumeUnchanged(2);
    try view.layout(a, &blocks, 20);
    blocks[0].spans = &.{.{ .text = "one\nand a new line" }};
    try view.layout(a, &blocks, 20);
    try std.testing.expectEqual(@as(usize, 3), view.lineCount());
    try expectFresh(&view, &blocks, 20);
}

test "a width change overrides assumeUnchanged" {
    const a = std.testing.allocator;
    var view: ScrollView = .{};
    defer view.deinit(a);
    const blocks = [_]Block{
        .{ .spans = &.{.{ .text = "alpha beta gamma delta" }} },
        .{ .spans = &.{.{ .text = "epsilon zeta" }}, .indent = 2 },
    };
    try view.layout(a, &blocks, 30);
    try std.testing.expectEqual(@as(usize, 2), view.lineCount());
    view.assumeUnchanged(2);
    try view.layout(a, &blocks, 6);
    try std.testing.expectEqual(@as(u64, 4), view.wraps);
    try expectFresh(&view, &blocks, 6);
    // And back: the promise is about the blocks, not this width.
    view.assumeUnchanged(2);
    try view.layout(a, &blocks, 30);
    try std.testing.expectEqual(@as(usize, 2), view.lineCount());
    try expectFresh(&view, &blocks, 30);
}

test "toggles override assumeUnchanged, whichever came first" {
    const a = std.testing.allocator;
    var view: ScrollView = .{};
    defer view.deinit(a);
    var blocks = [_]Block{
        .{ .spans = &.{.{ .text = "one\ntwo\nthree" }}, .collapsible = true },
        .{ .spans = &.{.{ .text = "four" }} },
        .{ .spans = &.{.{ .text = "five\nsix\nseven" }}, .collapsible = true },
    };
    try view.layout(a, &blocks, 20);
    try std.testing.expectEqual(@as(usize, 7), view.lineCount());
    // A promise, then a toggle.
    view.assumeUnchanged(3);
    view.toggle(&blocks, 0);
    try view.layout(a, &blocks, 20);
    try std.testing.expectEqual(@as(usize, 5), view.lineCount());
    try std.testing.expectEqual(@as(u32, 1), view.starts.items[1]);
    // A toggle, then a promise.
    view.toggle(&blocks, 2);
    view.assumeUnchanged(3);
    try view.layout(a, &blocks, 20);
    try std.testing.expectEqual(@as(usize, 3), view.lineCount());
    // `C` from handleKey collapses everything through `setAll`.
    blocks[0].collapsed = false;
    try view.layout(a, &blocks, 20);
    view.assumeUnchanged(3);
    try std.testing.expectEqual(Action{ .toggled_all = false }, view.handleKey(&blocks, keys.testKey('C', .{ .shift = true })).?);
    try view.layout(a, &blocks, 20);
    try std.testing.expectEqual(@as(usize, 3), view.lineCount());
    try expectFresh(&view, &blocks, 20);
}

test "assumeUnchanged handles odd prefixes and a draw with nothing to lay out" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 12, 2);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    var blocks = [_]Block{
        .{ .spans = &.{.{ .text = "one" }} },
        .{ .spans = &.{.{ .text = "two" }} },
        .{ .spans = &.{.{ .text = "three" }} },
    };
    var view: ScrollView = .{};
    defer view.deinit(a);
    // Before any layout, past the end, and over fewer blocks.
    view.assumeUnchanged(100);
    try view.layout(a, &blocks, 20);
    try std.testing.expectEqual(@as(u64, 3), view.wraps);
    view.assumeUnchanged(100);
    try view.layout(a, blocks[0..2], 20);
    try std.testing.expectEqual(@as(usize, 2), view.lineCount());
    try std.testing.expectEqual(@as(usize, 2), view.entries.items.len);
    view.assumeUnchanged(2);
    try view.layout(a, &blocks, 20);
    try std.testing.expectEqual(@as(usize, 3), view.lineCount());
    // Calling it twice keeps the smaller prefix.
    blocks[1].spans = &.{.{ .text = "two\nlines" }};
    view.assumeUnchanged(1);
    view.assumeUnchanged(3);
    try view.layout(a, &blocks, 20);
    try expectFresh(&view, &blocks, 20);
    // A zero-size draw lays nothing out, and its promise dies with it.
    const scans = view.scans;
    view.assumeUnchanged(3);
    try view.draw(a, &surface, .{ .width = 0, .height = 2 }, &blocks, &theme, false);
    blocks[0].spans = &.{.{ .text = "ONE" }};
    try view.draw(a, &surface, .{ .width = 20, .height = 2 }, &blocks, &theme, false);
    try std.testing.expectEqual(scans + 3, view.scans);
    try expectFresh(&view, &blocks, 20);
}

test "brokenPromise finds the block a caller lied about" {
    const a = std.testing.allocator;
    var view: ScrollView = .{};
    defer view.deinit(a);
    var blocks = [_]Block{
        .{ .spans = &.{.{ .text = "one\ntwo" }} },
        .{ .spans = &.{.{ .text = "three\nfour" }}, .collapsible = true },
        .{ .spans = &.{.{ .text = "five" }} },
    };
    try view.layout(a, &blocks, 20);
    try std.testing.expect(view.brokenPromise(&blocks, 20, 3) == null);
    // A changed revision, spans slice, or collapse state each show up.
    blocks[1].revision += 1;
    try std.testing.expectEqual(@as(?usize, 1), view.brokenPromise(&blocks, 20, 3));
    try std.testing.expect(view.brokenPromise(&blocks, 20, 1) == null);
    blocks[1].revision -= 1;
    blocks[0].spans = &.{.{ .text = "replaced" }};
    try std.testing.expectEqual(@as(?usize, 0), view.brokenPromise(&blocks, 20, 3));
    try view.layout(a, &blocks, 20);
    blocks[1].collapsed = true;
    try std.testing.expectEqual(@as(?usize, 1), view.brokenPromise(&blocks, 20, 3));
}

test "re-wrapping is bounded: resizes reuse the buffers and edits get compacted" {
    const a = std.testing.allocator;
    var view: ScrollView = .{};
    defer view.deinit(a);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var blocks: [64]Block = undefined;
    for (&blocks, 0..) |*b, i| {
        const t = try std.fmt.allocPrint(arena.allocator(), "block {d} has a few words to wrap", .{i});
        b.* = .{ .spans = try arena.allocator().dupe(Span, &.{.{ .text = t }}) };
    }
    try view.layout(a, &blocks, 12);
    // A resize re-wraps everything over the old space, not after it.
    try view.layout(a, &blocks, 20);
    try view.layout(a, &blocks, 12);
    try std.testing.expectEqual(@as(usize, 0), view.garbage_lines);
    const packed_lines = view.wrapped.lines.items.len;
    const packed_segments = view.wrapped.segments.items.len;
    try expectFresh(&view, &blocks, 12);

    // Bump every block's revision a few at a time, from the front, so each
    // new copy lands after blocks that are still live.
    for (0..200) |round| {
        for (0..7) |k| blocks[(round * 7 + k) % blocks.len].revision += 1;
        try view.layout(a, &blocks, 12);
        try expectFresh(&view, &blocks, 12);
        try std.testing.expect(view.garbage_lines + view.garbage_segments <= view.wrapped.lines.items.len + view.wrapped.segments.items.len);
        try std.testing.expect(view.wrapped.lines.items.len <= 2 * packed_lines + 8 * 7);
        try std.testing.expect(view.wrapped.segments.items.len <= 2 * packed_segments + 8 * 7);
    }

    // Replacing the whole transcript with a shorter one needs no copy.
    try view.layout(a, blocks[0..1], 12);
    blocks[0].revision += 1;
    try view.layout(a, blocks[0..1], 12);
    try expectFresh(&view, blocks[0..1], 12);
    try view.layout(a, &.{}, 12);
    try std.testing.expectEqual(@as(usize, 0), view.wrapped.lines.items.len);
    try std.testing.expectEqual(@as(usize, 0), view.garbage_lines);
}

test "layout stays correct after an allocation fails at any point" {
    const a = std.testing.allocator;
    var blocks = [_]Block{
        .{ .spans = &.{.{ .text = "alpha beta gamma delta" }} },
        .{ .spans = &.{.{ .text = "epsilon zeta eta theta" }}, .collapsible = true, .collapsed = true },
        .{ .spans = &.{.{ .text = "iota kappa lambda" }}, .indent = 2 },
    };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var view: ScrollView = .{};
        defer view.deinit(a);
        var failing: std.testing.FailingAllocator = .init(a, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        var failed = false;
        // A first layout, an edit with a promise, a resize, more edits.
        view.layout(fa, blocks[0..2], 10) catch {
            failed = true;
        };
        blocks[0].revision += 1;
        view.assumeUnchanged(0);
        view.layout(fa, &blocks, 10) catch {
            failed = true;
        };
        view.layout(fa, &blocks, 7) catch {
            failed = true;
        };
        // Early blocks re-wrapped behind a live one: this one compacts.
        blocks[0].revision += 1;
        blocks[1].revision += 1;
        view.layout(fa, &blocks, 7) catch {
            failed = true;
        };
        // Whatever failed, a layout that can allocate puts everything right,
        // and a promise is only honored for what was laid out.
        view.assumeUnchanged(blocks.len);
        try view.layout(a, &blocks, 7);
        try expectFresh(&view, &blocks, 7);
        try view.layout(a, &blocks, 11);
        try expectFresh(&view, &blocks, 11);
        if (!failed) break;
    }
    try std.testing.expect(fail_index > 3);
}

test "mouse wheel scrolls and clicks toggle or select blocks" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 20, 6);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    var blocks = [_]Block{
        .{ .spans = &.{.{ .text = "one\ntwo\nthree\nfour" }} },
        .{ .spans = &.{.{ .text = "Bash x\nout 1\nout 2" }}, .collapsible = true, .collapsed = false },
        .{ .spans = &.{.{ .text = "done" }} },
    };
    var view: ScrollView = .{};
    defer view.deinit(a);
    const region: Region = .{ .x = 1, .y = 1, .width = 18, .height = 4 };
    try view.draw(a, &surface, region, &blocks, &theme, true);
    // 8 lines, 4 rows: the tail is "▾ Bash x" .. "done" at rows 0-3.
    try std.testing.expect(view.handleMouse(&blocks, keys.testMouse(0, 0, .wheel_up)) == null);
    try std.testing.expectEqual(Action.scrolled, view.handleMouse(&blocks, keys.testMouse(5, 2, .wheel_up)).?);
    try std.testing.expect(!view.following());
    try std.testing.expectEqual(@as(?usize, 1), view.top);
    try std.testing.expectEqual(Action.scrolled, view.handleMouse(&blocks, keys.testMouse(5, 2, .wheel_down)).?);
    try std.testing.expect(view.following());
    // A click on a body line selects; on the header line toggles.
    try std.testing.expectEqual(Action{ .selected = 1 }, view.handleMouse(&blocks, keys.testMouse(4, 1 + 1, .left)).?);
    try std.testing.expectEqual(Action{ .toggled = 1 }, view.handleMouse(&blocks, keys.testMouse(4, 1 + 0, .left)).?);
    try std.testing.expect(blocks[1].collapsed);
    try view.draw(a, &surface, region, &blocks, &theme, true);
    try std.testing.expectEqual(@as(usize, 6), view.lineCount());
    // Plain blocks ignore clicks.
    try std.testing.expect(view.handleMouse(&blocks, keys.testMouse(4, 1 + 3, .left)) == null);
}
