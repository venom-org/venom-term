//! Single- and multi-line text input with a cursor and history.
//!
//! Editing is grapheme-aware. Single-line inputs scroll horizontally;
//! multi-line inputs wrap by cell and scroll vertically. Enter submits;
//! in multi-line mode Shift/Alt+Enter and Ctrl-J insert a newline.
//! Readline-style keys: Ctrl-A/E home/end, Ctrl-B/F left/right, Ctrl-U/K
//! kill to start/end, Ctrl-W and Alt-Backspace delete a word, Alt-B/F and
//! Ctrl-←/→ move by word, ↑/↓ recall history (in multi-line mode only on
//! the first/last line). Pasted text goes through `insert`.
const std = @import("std");
const types = @import("types");
const Region = types.Region;
const Surface = @import("../surface.zig").Surface;
const Theme = @import("theme.zig").Theme;
const Role = @import("theme.zig").Role;
const text = @import("text.zig");
const keys = @import("keys.zig");
const Input = @import("types").Input;
const Key = Input.Key;

pub const Action = enum { edited, moved, submit };

pub const Options = struct {
    multiline: bool = false,
    /// Shown in `faint` while the input is empty.
    placeholder: []const u8 = "",
    /// Drawn in `accent` before the first line, e.g. "› ".
    prompt: []const u8 = "",
    history_limit: usize = 100,
};

pub const TextInput = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    buf: std.ArrayList(u8) = .empty,
    /// Byte offset, always on a grapheme boundary.
    cursor: usize = 0,
    history: std.ArrayList([]u8) = .empty,
    /// Index into history while recalling; null while editing the draft.
    recall: ?usize = null,
    draft: std.ArrayList(u8) = .empty,
    /// First visible row (multi-line) or column (single-line).
    scroll: usize = 0,

    pub fn init(gpa: std.mem.Allocator, opts: Options) TextInput {
        return .{ .gpa = gpa, .opts = opts };
    }

    pub fn deinit(self: *TextInput) void {
        self.buf.deinit(self.gpa);
        self.draft.deinit(self.gpa);
        for (self.history.items) |h| self.gpa.free(h);
        self.history.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn value(self: *const TextInput) []const u8 {
        return self.buf.items;
    }

    /// Replaces the contents and puts the cursor at the end.
    pub fn setText(self: *TextInput, bytes: []const u8) !void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        try self.insert(bytes);
    }

    pub fn clear(self: *TextInput) void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.scroll = 0;
        self.recall = null;
    }

    /// Inserts text at the cursor. Invalid UTF-8 and control characters are
    /// dropped; in single-line mode newlines and tabs become spaces.
    pub fn insert(self: *TextInput, bytes: []const u8) !void {
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(self.gpa);
        if (!std.unicode.utf8ValidateSlice(bytes)) return;
        var it = std.unicode.Utf8View.initUnchecked(bytes).iterator();
        var prev_cr = false;
        while (it.nextCodepointSlice()) |cp| {
            const c = cp[0];
            const is_cr = cp.len == 1 and c == '\r';
            defer prev_cr = is_cr;
            if (cp.len == 1 and (c == '\n' or c == '\r')) {
                if (c == '\n' and prev_cr) continue;
                try clean.append(self.gpa, if (self.opts.multiline) '\n' else ' ');
            } else if (cp.len == 1 and c == '\t') {
                try clean.append(self.gpa, ' ');
            } else if (cp.len == 1 and (c < 0x20 or c == 0x7f)) {
                continue;
            } else try clean.appendSlice(self.gpa, cp);
        }
        if (clean.items.len == 0) return;
        try self.buf.insertSlice(self.gpa, self.cursor, clean.items);
        self.cursor += clean.items.len;
        self.recall = null;
    }

    fn prevBoundary(self: *const TextInput, pos: usize) usize {
        if (pos == 0) return 0;
        const s = self.buf.items;
        const line_start = if (std.mem.lastIndexOfScalar(u8, s[0..pos], '\n')) |nl| (if (nl + 1 == pos) nl else nl + 1) else 0;
        return text.prevGrapheme(s, line_start, pos);
    }
    fn nextBoundary(self: *const TextInput, pos: usize) usize {
        if (pos >= self.buf.items.len) return self.buf.items.len;
        if (self.buf.items[pos] == '\n') return pos + 1;
        const stop = text.nextGrapheme(self.buf.items, pos);
        // Never swallow a newline into a grapheme.
        if (std.mem.indexOfScalar(u8, self.buf.items[pos..stop], '\n')) |nl| return pos + @max(nl, 1);
        return stop;
    }
    fn lineStart(self: *const TextInput, pos: usize) usize {
        return if (std.mem.lastIndexOfScalar(u8, self.buf.items[0..pos], '\n')) |nl| nl + 1 else 0;
    }
    fn lineEnd(self: *const TextInput, pos: usize) usize {
        return if (std.mem.indexOfScalarPos(u8, self.buf.items, pos, '\n')) |nl| nl else self.buf.items.len;
    }
    fn isWordByte(c: u8) bool {
        return c >= 0x80 or std.ascii.isAlphanumeric(c) or c == '_';
    }
    fn wordLeftPos(self: *const TextInput) usize {
        var p = self.cursor;
        const s = self.buf.items;
        while (p > 0 and !isWordByte(s[p - 1])) p -= 1;
        while (p > 0 and isWordByte(s[p - 1])) p -= 1;
        return p;
    }
    fn wordRightPos(self: *const TextInput) usize {
        var p = self.cursor;
        const s = self.buf.items;
        while (p < s.len and !isWordByte(s[p])) p += 1;
        while (p < s.len and isWordByte(s[p])) p += 1;
        return p;
    }

    fn deleteRange(self: *TextInput, from: usize, to: usize) void {
        if (to <= from) return;
        self.buf.replaceRangeAssumeCapacity(from, to - from, "");
        self.cursor = from;
        self.recall = null;
    }

    pub fn backspace(self: *TextInput) void {
        self.deleteRange(self.prevBoundary(self.cursor), self.cursor);
    }
    pub fn deleteForward(self: *TextInput) void {
        self.deleteRange(self.cursor, self.nextBoundary(self.cursor));
    }
    pub fn deleteWord(self: *TextInput) void {
        self.deleteRange(self.wordLeftPos(), self.cursor);
    }
    pub fn killToStart(self: *TextInput) void {
        self.deleteRange(self.lineStart(self.cursor), self.cursor);
    }
    pub fn killToEnd(self: *TextInput) void {
        const stop = self.lineEnd(self.cursor);
        const c = self.cursor;
        // At the end of a line, Ctrl-K joins the next line.
        self.deleteRange(c, if (stop == c and stop < self.buf.items.len) stop + 1 else stop);
        self.cursor = c;
    }
    pub fn moveLeft(self: *TextInput) void {
        self.cursor = self.prevBoundary(self.cursor);
    }
    pub fn moveRight(self: *TextInput) void {
        self.cursor = self.nextBoundary(self.cursor);
    }
    pub fn moveHome(self: *TextInput) void {
        self.cursor = self.lineStart(self.cursor);
    }
    pub fn moveEnd(self: *TextInput) void {
        self.cursor = self.lineEnd(self.cursor);
    }

    fn column(self: *const TextInput, pos: usize) usize {
        return text.width(self.buf.items[self.lineStart(pos)..pos]);
    }
    fn posAtColumn(self: *const TextInput, line_start: usize, col: usize) usize {
        const le = self.lineEnd(line_start);
        var p = line_start;
        var c: usize = 0;
        while (p < le) {
            const n = self.nextBoundary(p);
            const w = text.width(self.buf.items[p..n]);
            if (c + w > col) break;
            c += w;
            p = n;
        }
        return p;
    }

    /// Moves to the previous logical line, or recalls older history on the
    /// first line. Returns false if nothing changed.
    pub fn moveUp(self: *TextInput) !bool {
        const ls = self.lineStart(self.cursor);
        if (self.opts.multiline and ls > 0) {
            const col = self.column(self.cursor);
            self.cursor = self.posAtColumn(self.lineStart(ls - 1), col);
            return true;
        }
        return self.historyPrev();
    }
    pub fn moveDown(self: *TextInput) !bool {
        const le = self.lineEnd(self.cursor);
        if (self.opts.multiline and le < self.buf.items.len) {
            const col = self.column(self.cursor);
            self.cursor = self.posAtColumn(le + 1, col);
            return true;
        }
        return self.historyNext();
    }

    fn load(self: *TextInput, bytes: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.gpa, bytes);
        self.cursor = bytes.len;
    }

    pub fn historyPrev(self: *TextInput) !bool {
        if (self.history.items.len == 0) return false;
        const idx = if (self.recall) |r| (if (r == 0) return false else r - 1) else blk: {
            self.draft.clearRetainingCapacity();
            try self.draft.appendSlice(self.gpa, self.buf.items);
            break :blk self.history.items.len - 1;
        };
        try self.load(self.history.items[idx]);
        self.recall = idx;
        return true;
    }
    pub fn historyNext(self: *TextInput) !bool {
        const r = self.recall orelse return false;
        if (r + 1 < self.history.items.len) {
            try self.load(self.history.items[r + 1]);
            self.recall = r + 1;
        } else {
            try self.load(self.draft.items);
            self.recall = null;
        }
        return true;
    }

    /// Returns the text (caller frees), adds it to history unless it is
    /// empty or repeats the last entry, and clears the input.
    pub fn submit(self: *TextInput) ![]u8 {
        const out = try self.gpa.dupe(u8, self.buf.items);
        errdefer self.gpa.free(out);
        const last = if (self.history.items.len > 0) self.history.items[self.history.items.len - 1] else null;
        if (out.len > 0 and (last == null or !std.mem.eql(u8, last.?, out))) {
            const entry = try self.gpa.dupe(u8, out);
            errdefer self.gpa.free(entry);
            try self.history.append(self.gpa, entry);
            if (self.history.items.len > @max(self.opts.history_limit, 1)) self.gpa.free(self.history.orderedRemove(0));
        }
        self.clear();
        self.draft.clearRetainingCapacity();
        return out;
    }

    /// Applies a key. Returns null when the key isn't the input's (Tab,
    /// Escape, unbound Ctrl keys), so the caller can route it elsewhere.
    pub fn handleKey(self: *TextInput, key: Key) !?Action {
        if (!keys.pressed(key)) return null;
        const cp = key.codepoint;
        const m = key.mods;
        if (cp == @backingInt(NK.enter)) {
            if (self.opts.multiline and (m.shift or m.alt)) {
                try self.insert("\n");
                return .edited;
            }
            if (m.ctrl or m.alt or m.super) return null;
            return .submit;
        }
        if (self.opts.multiline and keys.ctrl(key, 'j')) {
            try self.insert("\n");
            return .edited;
        }
        if (cp == @backingInt(NK.backspace)) {
            if (m.alt or m.ctrl) self.deleteWord() else self.backspace();
            return .edited;
        }
        if (cp == @backingInt(NK.delete)) {
            self.deleteForward();
            return .edited;
        }
        if (cp == @backingInt(NK.left)) {
            if (m.ctrl or m.alt) self.cursor = self.wordLeftPos() else self.moveLeft();
            return .moved;
        }
        if (cp == @backingInt(NK.right)) {
            if (m.ctrl or m.alt) self.cursor = self.wordRightPos() else self.moveRight();
            return .moved;
        }
        if (cp == @backingInt(NK.home)) {
            self.moveHome();
            return .moved;
        }
        if (cp == @backingInt(NK.end)) {
            self.moveEnd();
            return .moved;
        }
        if (cp == @backingInt(NK.up)) return if (try self.moveUp()) .moved else null;
        if (cp == @backingInt(NK.down)) return if (try self.moveDown()) .moved else null;
        if (m.ctrl and !m.alt) {
            switch (cp) {
                'a' => self.moveHome(),
                'e' => self.moveEnd(),
                'b' => self.moveLeft(),
                'f' => self.moveRight(),
                'u' => self.killToStart(),
                'k' => self.killToEnd(),
                'w' => self.deleteWord(),
                'h' => self.backspace(),
                'd' => self.deleteForward(),
                'p' => return if (try self.historyPrev()) .moved else null,
                'n' => return if (try self.historyNext()) .moved else null,
                else => return null,
            }
            return if (cp == 'a' or cp == 'e' or cp == 'b' or cp == 'f') .moved else .edited;
        }
        if (m.alt and !m.ctrl) {
            switch (cp) {
                'b' => self.cursor = self.wordLeftPos(),
                'f' => self.cursor = self.wordRightPos(),
                'd' => self.deleteRange(self.cursor, self.wordRightPos()),
                else => return null,
            }
            return if (cp == 'd') .edited else .moved;
        }
        if (m.super or m.hyper or m.meta) return null;
        if (cp == @backingInt(NK.tab) or cp == @backingInt(NK.escape)) return null;
        if (key.text) |t| {
            if (t.len > 0) {
                try self.insert(t);
                return .edited;
            }
        }
        // Ctrl+Alt+<key> with no text is a command the input doesn't have.
        if (m.ctrl) return null;
        if (cp >= 0x20 and cp < 0x110000 and cp != 0x7f and !(cp >= 0xd800 and cp <= 0xdfff)) {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch return null;
            try self.insert(buf[0..n]);
            return .edited;
        }
        return null;
    }

    const Row = struct { start: usize, end: usize };
    const Pos = struct { row: usize, col: usize };

    /// Cell-wraps the buffer into rows of `w` columns (multi-line mode).
    /// Returns the cursor's row and column.
    fn rows(self: *const TextInput, gpa: std.mem.Allocator, out: *std.ArrayList(Row), w: usize) !Pos {
        const s = self.buf.items;
        var start: usize = 0;
        var p: usize = 0;
        var col: usize = 0;
        var cur: Pos = .{ .row = 0, .col = 0 };
        var found = false;
        while (true) {
            if (!found and p == self.cursor) {
                if (col >= w) {
                    try out.append(gpa, .{ .start = start, .end = p });
                    start = p;
                    col = 0;
                }
                cur = .{ .row = out.items.len, .col = col };
                found = true;
            }
            if (p >= s.len) break;
            if (s[p] == '\n') {
                try out.append(gpa, .{ .start = start, .end = p });
                p += 1;
                start = p;
                col = 0;
                continue;
            }
            const n = self.nextBoundary(p);
            const gw = text.width(s[p..n]);
            if (col + gw > w and col > 0) {
                try out.append(gpa, .{ .start = start, .end = p });
                start = p;
                col = 0;
                continue;
            }
            col += gw;
            p = n;
        }
        try out.append(gpa, .{ .start = start, .end = s.len });
        return cur;
    }

    fn drawSlice(surface: *Surface, x: u16, y: u16, w: u16, bytes: []const u8, skip_cols: usize, theme: *const Theme) !void {
        var col: usize = 0;
        var cx: u32 = x;
        const right: u32 = @as(u32, x) + w;
        var i: usize = 0;
        const style = theme.style(.normal);
        while (i < bytes.len) {
            const n = text.nextGrapheme(bytes, i);
            const g = bytes[i..n];
            i = n;
            const gw = text.graphemeWidth(g);
            if (gw == 0) continue;
            if (col < skip_cols) {
                // A wide glyph cut by the left edge leaves a blank.
                if (col + gw > skip_cols) {
                    try surface.put(@intCast(cx), y, .{ .style = style });
                    cx += 1;
                }
                col += gw;
                continue;
            }
            if (cx + gw > right) break;
            _ = try text.drawText(surface, @intCast(cx), y, gw, g, .normal, theme, .{});
            cx += gw;
            col += gw;
        }
        while (cx < right) : (cx += 1) try surface.put(@intCast(cx), y, .{ .style = style });
    }

    /// Draws the input and, when focused, places the terminal cursor.
    pub fn draw(self: *TextInput, surface: *Surface, region: Region, theme: *const Theme, focused: bool) !void {
        if (region.width == 0 or region.height == 0) return;
        const pw: u16 = @intCast(@min(text.width(self.opts.prompt), region.width - 1));
        const x = region.x + pw;
        const w = region.width - pw;
        for (0..region.height) |row| {
            const y = region.y + @as(u16, @intCast(row));
            if (pw > 0) {
                if (row == 0) {
                    _ = try text.drawText(surface, region.x, y, pw, self.opts.prompt, .accent, theme, .{ .fill = theme.style(.normal) });
                } else try surface.clear(.{ .x = region.x, .y = y, .width = pw, .height = 1 }, theme.style(.normal));
            }
        }
        var cursor_pos: Surface.Cursor = .{ .x = x, .y = region.y };
        if (self.buf.items.len == 0) {
            self.scroll = 0;
            for (0..region.height) |row| {
                const y = region.y + @as(u16, @intCast(row));
                if (row == 0 and self.opts.placeholder.len > 0) {
                    _ = try text.drawText(surface, x, y, w, self.opts.placeholder, .faint, theme, .{ .ellipsis = true, .fill = theme.style(.normal) });
                } else try surface.clear(.{ .x = x, .y = y, .width = w, .height = 1 }, theme.style(.normal));
            }
        } else if (!self.opts.multiline) {
            const col = text.width(self.buf.items[0..self.cursor]);
            if (col < self.scroll) self.scroll = col;
            if (col >= self.scroll + w) self.scroll = col - w + 1;
            const total = text.width(self.buf.items);
            // Don't leave empty space on the right when text was deleted.
            if (total + 1 < self.scroll + w) self.scroll = (total + 1) -| w;
            try drawSlice(surface, x, region.y, w, self.buf.items, self.scroll, theme);
            for (1..region.height) |row| try surface.clear(.{ .x = x, .y = region.y + @as(u16, @intCast(row)), .width = w, .height = 1 }, theme.style(.normal));
            cursor_pos = .{ .x = x + @as(u16, @intCast(col - self.scroll)), .y = region.y };
        } else {
            var list: std.ArrayList(Row) = .empty;
            defer list.deinit(self.gpa);
            const cur = try self.rows(self.gpa, &list, w);
            if (cur.row < self.scroll) self.scroll = cur.row;
            if (cur.row >= self.scroll + region.height) self.scroll = cur.row + 1 - region.height;
            if (list.items.len < self.scroll + region.height) self.scroll = list.items.len -| region.height;
            for (0..region.height) |row| {
                const y = region.y + @as(u16, @intCast(row));
                const ri = self.scroll + row;
                if (ri < list.items.len) {
                    const r = list.items[ri];
                    try drawSlice(surface, x, y, w, self.buf.items[r.start..r.end], 0, theme);
                } else try surface.clear(.{ .x = x, .y = y, .width = w, .height = 1 }, theme.style(.normal));
            }
            cursor_pos = .{ .x = x + @as(u16, @intCast(@min(cur.col, w - 1))), .y = region.y + @as(u16, @intCast(cur.row - self.scroll)) };
        }
        if (focused) surface.setCursor(cursor_pos);
    }
};

fn typeText(input: *TextInput, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const n = text.nextGrapheme(s, i);
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        var k = keys.testKey(std.unicode.utf8Decode(s[i .. i + len]) catch '?', .{});
        k.text = s[i..n];
        _ = try input.handleKey(k);
        i = n;
    }
}

const NK = Input.NamedKey;

test "single-line editing, graphemes, words and history" {
    const a = std.testing.allocator;
    var in = TextInput.init(a, .{});
    defer in.deinit();
    try typeText(&in, "hello wörld e\xcc\x81");
    try std.testing.expectEqualStrings("hello wörld e\xcc\x81", in.buf.items);
    _ = try in.handleKey(keys.testNamed(.backspace)); // whole é
    try std.testing.expectEqualStrings("hello wörld ", in.buf.items);
    _ = try in.handleKey(keys.testKey('w', .{ .ctrl = true }));
    try std.testing.expectEqualStrings("hello ", in.buf.items);
    _ = try in.handleKey(keys.testKey('a', .{ .ctrl = true }));
    try typeText(&in, "> ");
    _ = try in.handleKey(keys.testNamed(.end));
    try in.insert("x\ny");
    try std.testing.expectEqualStrings("> hello x y", in.buf.items);
    try std.testing.expectEqual(Action.submit, (try in.handleKey(keys.testNamed(.enter))).?);
    const first = try in.submit();
    defer a.free(first);
    try std.testing.expectEqualStrings("> hello x y", first);
    try in.setText("second");
    const second = try in.submit();
    defer a.free(second);
    try typeText(&in, "draft");
    try std.testing.expectEqual(Action.moved, (try in.handleKey(keys.testNamed(.up))).?);
    try std.testing.expectEqualStrings("second", in.buf.items);
    _ = try in.handleKey(keys.testNamed(.up));
    try std.testing.expectEqualStrings("> hello x y", in.buf.items);
    try std.testing.expect((try in.handleKey(keys.testNamed(.up))) == null);
    _ = try in.handleKey(keys.testNamed(.down));
    _ = try in.handleKey(keys.testNamed(.down));
    try std.testing.expectEqualStrings("draft", in.buf.items);
    try std.testing.expect((try in.handleKey(keys.testNamed(.tab))) == null);
}

test "Ctrl+Alt with a key is no text; with text, as AltGr can send it, it is" {
    var input = TextInput.init(std.testing.allocator, .{});
    defer input.deinit();
    const key = keys.testKey('c', .{ .ctrl = true, .alt = true });
    try std.testing.expectEqual(@as(?Action, null), try input.handleKey(key));
    try std.testing.expectEqualStrings("", input.buf.items);
    var altgr = key;
    altgr.text = "@";
    _ = try input.handleKey(altgr);
    try std.testing.expectEqualStrings("@", input.buf.items);
}

test "single-line input scrolls horizontally and places the cursor" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 10, 1);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    var in = TextInput.init(a, .{ .prompt = "› ", .placeholder = "Message the agent" });
    defer in.deinit();
    try in.draw(&surface, .{ .width = 10, .height = 1 }, &theme, true);
    var row = try text.rowText(a, &surface, 0);
    try std.testing.expectEqualStrings("› Message…", row);
    a.free(row);
    try std.testing.expect(surface.get(2, 0).?.style.dim);
    try in.setText("abcdefghijkl");
    try in.draw(&surface, .{ .width = 10, .height = 1 }, &theme, true);
    row = try text.rowText(a, &surface, 0);
    try std.testing.expectEqualStrings("› fghijkl", row);
    a.free(row);
    try std.testing.expectEqual(Surface.Cursor{ .x = 9, .y = 0 }, surface.cursor.?);
    _ = try in.handleKey(keys.testNamed(.home));
    try in.draw(&surface, .{ .width = 10, .height = 1 }, &theme, true);
    row = try text.rowText(a, &surface, 0);
    try std.testing.expectEqualStrings("› abcdefgh", row);
    a.free(row);
    try std.testing.expectEqual(Surface.Cursor{ .x = 2, .y = 0 }, surface.cursor.?);
}

test "multi-line input wraps, moves between lines and scrolls" {
    const a = std.testing.allocator;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try Surface.init(a, 6, 2);
    defer surface.deinit(&discard.writer);
    const theme: Theme = .default;
    var in = TextInput.init(a, .{ .multiline = true });
    defer in.deinit();
    try typeText(&in, "abcdefgh");
    var shift_enter = keys.testNamed(.enter);
    shift_enter.mods.shift = true;
    try std.testing.expectEqual(Action.edited, (try in.handleKey(shift_enter)).?);
    try typeText(&in, "xy");
    try std.testing.expectEqualStrings("abcdefgh\nxy", in.buf.items);
    try in.draw(&surface, .{ .width = 6, .height = 2 }, &theme, true);
    // Rows: "abcdef" "gh" "xy"; the cursor row is visible.
    var r0 = try text.rowText(a, &surface, 0);
    var r1 = try text.rowText(a, &surface, 1);
    try std.testing.expectEqualStrings("gh", r0);
    try std.testing.expectEqualStrings("xy", r1);
    a.free(r0);
    a.free(r1);
    try std.testing.expectEqual(Surface.Cursor{ .x = 2, .y = 1 }, surface.cursor.?);
    // ↑ moves to the previous logical line at the same column.
    _ = try in.handleKey(keys.testNamed(.up));
    try std.testing.expectEqual(@as(usize, 2), in.cursor);
    try in.draw(&surface, .{ .width = 6, .height = 2 }, &theme, true);
    r0 = try text.rowText(a, &surface, 0);
    r1 = try text.rowText(a, &surface, 1);
    try std.testing.expectEqualStrings("abcdef", r0);
    try std.testing.expectEqualStrings("gh", r1);
    a.free(r0);
    a.free(r1);
    try std.testing.expectEqual(Surface.Cursor{ .x = 2, .y = 0 }, surface.cursor.?);
    // Ctrl-K at the end of a line joins the next one.
    _ = try in.handleKey(keys.testKey('e', .{ .ctrl = true }));
    _ = try in.handleKey(keys.testKey('k', .{ .ctrl = true }));
    try std.testing.expectEqualStrings("abcdefghxy", in.buf.items);
}
