//! Literal plain-text export and hydration tests.
const std = @import("std");
const Vt = @import("vt.zig").Vt;
const Style = @import("vt.zig").Style;
const a = std.testing.allocator;
const unlimited: Vt.PlainLimits = .{ .max_rows = Vt.plain_max_rows, .max_bytes = Vt.plain_max_bytes };

fn expectSamePlain(x: Vt.PlainText, y: Vt.PlainText) !void {
    try std.testing.expectEqual(x.cols, y.cols);
    try std.testing.expectEqual(x.rows, y.rows);
    try std.testing.expectEqual(x.history.len, y.history.len);
    for (x.history, y.history) |l, r| try std.testing.expectEqualStrings(l, r);
    for (x.screen, y.screen) |l, r| try std.testing.expectEqualStrings(l, r);
}
fn exportAll(vt: Vt) !Vt.PlainExport {
    return (try vt.exportPlain(a, unlimited)).?;
}

test "plain: unicode and wide cells round trip with fresh reset state" {
    var src = try Vt.init(a, .{ .cols = 10, .rows = 3, .scrollback_lines = 100 });
    defer src.deinit();
    try src.feed("\x1b[31mold\x1b[0m\r\n界e\xcc\x81\tx\r\n\x1b[1;4mbold\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\\r\n12345678界\r\nlast");
    const out = try exportAll(src);
    defer out.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), out.text.screen.len);
    try std.testing.expectEqual(@as(usize, 2), out.text.history.len);
    try std.testing.expectEqualStrings("old       ", out.text.history[0]);
    try std.testing.expectEqualStrings("界e\xcc\x81     x ", out.text.history[1]);
    try std.testing.expectEqualStrings("boldlink  ", out.text.screen[0]);
    try std.testing.expectEqualStrings("12345678界", out.text.screen[1]);
    try std.testing.expectEqualStrings("last      ", out.text.screen[2]);

    var dst = try Vt.fromPlain(a, out.text, .{ .scrollback_lines = 100 });
    defer dst.deinit();
    const again = try exportAll(dst);
    defer again.deinit(a);
    try expectSamePlain(out.text, again.text);
    try std.testing.expectEqual(Vt.Rows{ .epoch = 1, .oldest = 0, .end = 5, .active = 2 }, dst.rows());
    try std.testing.expectEqual(Vt.Cursor{ .x = 0, .y = 0, .visible = true }, dst.cursor());
    const wide = try dst.readCell(a, 1, 3, 8);
    defer a.free(wide.text);
    try std.testing.expectEqualStrings("界", wide.text);
    try std.testing.expectEqual(@as(u8, 2), wide.width);
    try std.testing.expectEqual(Style{}, wide.style);
    const tail = try dst.readCell(a, 1, 3, 9);
    defer a.free(tail.text);
    try std.testing.expectEqual(@as(u8, 0), tail.width);
    const styled = try dst.readCell(a, 1, 2, 0);
    defer a.free(styled.text);
    try std.testing.expectEqual(Style{}, styled.style);

    // Autowrap is back on, and new output scrolls under the same epoch.
    try dst.feed("\x1b[3;1Habcdefghijklm");
    try std.testing.expectEqual(@as(u64, 1), dst.rows().epoch);
    try std.testing.expectEqual(@as(u64, 6), dst.rows().end);
}

test "plain: short rows pad and the alternate screen is skipped" {
    var dst = try Vt.fromPlain(a, .{ .cols = 4, .rows = 2, .history = &.{"old"}, .screen = &.{ "", "ab" } }, .{});
    defer dst.deinit();
    const out = try exportAll(dst);
    defer out.deinit(a);
    try std.testing.expectEqualStrings("    ", out.text.screen[0]);
    try std.testing.expectEqualStrings("ab  ", out.text.screen[1]);
    try dst.feed("\x1b[?1049hALT");
    const rows = dst.rows();
    const alt = try exportAll(dst);
    defer alt.deinit(a);
    try expectSamePlain(out.text, alt.text);
    // The live Vt stays on the alternate screen, untouched.
    try std.testing.expectEqual(rows, dst.rows());
    const live = try dst.exportRows(a, rows.epoch, rows.active, rows.active + 1);
    defer a.free(live);
    try std.testing.expectEqualStrings("ALT \n", live);
    try dst.feed("!");
    const cell = try dst.readCell(a, dst.rows().epoch, dst.rows().active, 3);
    defer a.free(cell.text);
    try std.testing.expectEqualStrings("!", cell.text);
}

fn exportAlternate(allocator: std.mem.Allocator) !void {
    var vt = try Vt.init(allocator, .{ .cols = 6, .rows = 2 });
    defer vt.deinit();
    try vt.feed("one\r\ntwo\r\nthree\x1b[?1049hvim");
    const out = (try vt.exportPlain(allocator, unlimited)).?;
    out.deinit(allocator);
}
test "plain: alternate-screen export cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(a, exportAlternate, .{});
}

test "plain: export budgets drop oldest history and omit oversized screens" {
    var src = try Vt.init(a, .{ .cols = 4, .rows = 2, .scrollback_lines = 100 });
    defer src.deinit();
    for (0..10) |i| {
        var buf: [16]u8 = undefined;
        try src.feed(try std.fmt.bufPrint(&buf, "r{d:0>2}\r\n", .{i}));
    }
    // 9 history rows (r00..r08), screen "r09 " and blank.
    const by_rows = (try src.exportPlain(a, .{ .max_rows = 5, .max_bytes = 1000 })).?;
    defer by_rows.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), by_rows.text.history.len);
    try std.testing.expectEqualStrings("r06 ", by_rows.text.history[0]);
    try std.testing.expectEqualStrings("r08 ", by_rows.text.history[2]);
    try std.testing.expectEqualStrings("r09 ", by_rows.text.screen[0]);
    const by_bytes = (try src.exportPlain(a, .{ .max_rows = 1000, .max_bytes = 8 + 4 * 2 + 3 })).?;
    defer by_bytes.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), by_bytes.text.history.len);
    try std.testing.expectEqualStrings("r07 ", by_bytes.text.history[0]);
    try std.testing.expectEqual(@as(?Vt.PlainExport, null), try src.exportPlain(a, .{ .max_rows = 1, .max_bytes = 1000 }));
    try std.testing.expectEqual(@as(?Vt.PlainExport, null), try src.exportPlain(a, .{ .max_rows = 1000, .max_bytes = 7 }));
    try std.testing.expectEqual(@as(?Vt.PlainExport, null), try src.exportPlain(a, .{ .max_rows = 0, .max_bytes = 0 }));
    const screen_only = (try src.exportPlain(a, .{ .max_rows = 2, .max_bytes = 8 })).?;
    defer screen_only.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), screen_only.text.history.len);
}

test "plain: hydration rejects controls, escapes and bounds" {
    const bad_rows = [_][]const u8{
        "\x1b[31mred", "\x1b]0;title\x07", "\x1b[6n",    "bell\x07",    "cr\r",    "lf\n",
        "tab\t",       "del\x7f",          "c1\xc2\x9b", "nel\xc2\x85", "raw\x9b", "bad\xff",
        "\xc3",        "\xed\xa0\x80",     "\x00",
    };
    for (bad_rows) |row| {
        try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 20, .rows = 1, .history = &.{}, .screen = &.{row} }, .{}));
        try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 20, .rows = 1, .history = &.{row}, .screen = &.{"ok"} }, .{}));
    }
    const one: []const []const u8 = &.{"x"};
    // Shape and dimension bounds.
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 0, .rows = 1, .history = &.{}, .screen = one }, .{}));
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 4, .rows = 0, .history = &.{}, .screen = &.{} }, .{}));
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 4, .rows = 2, .history = &.{}, .screen = one }, .{}));
    // Width: too many cells, a wide cell past the edge, a leading combining mark.
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 4, .rows = 1, .history = &.{}, .screen = &.{"abcde"} }, .{}));
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 4, .rows = 1, .history = &.{}, .screen = &.{"abc界"} }, .{}));
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 4, .rows = 1, .history = &.{ "ok", "abcde" }, .screen = one }, .{}));
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 4, .rows = 1, .history = &.{}, .screen = &.{"\xcc\x81a"} }, .{}));
    // Row, byte and scrollback bounds.
    const hist: []const []const u8 = &.{ "a", "b", "c" };
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 4, .rows = 1, .history = hist, .screen = one }, .{ .max_rows = 3 }));
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 4, .rows = 1, .history = hist, .screen = one }, .{ .max_bytes = 3 }));
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 4, .rows = 1, .history = hist, .screen = one }, .{ .scrollback_lines = 2 }));
    var ok = try Vt.fromPlain(a, .{ .cols = 4, .rows = 1, .history = hist, .screen = one }, .{ .max_rows = 4, .max_bytes = 4, .scrollback_lines = 3 });
    ok.deinit();
}

test "plain: hydration has no callback, query or OSC side effects" {
    const State = struct {
        status: usize = 0,
        prompt: usize = 0,
        reply: usize = 0,
        bell: usize = 0,
        fn bellCb(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.bell += 1;
        }
        fn statusCb(ctx: ?*anyopaque, _: Vt.ProgramStatus) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.status += 1;
        }
        fn promptCb(ctx: ?*anyopaque, _: Vt.SemanticPrompt) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.prompt += 1;
        }
        fn replyCb(ctx: ?*anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.reply += bytes.len;
        }
    };
    var state: State = .{};
    const callbacks: Vt.Callbacks = .{ .context = &state, .write_pty = State.replyCb, .program_status = State.statusCb, .semantic_prompt = State.promptCb, .bell = State.bellCb };
    // Escape-looking text without ESC stays literal.
    const rows: []const []const u8 = &.{ "]7501;state=working", "]133;D;7 [6n [c" };
    var vt = try Vt.fromPlain(a, .{ .cols = 24, .rows = 1, .history = rows[0..1], .screen = rows[1..] }, .{ .callbacks = callbacks });
    defer vt.deinit();
    try std.testing.expectEqual(State{}, state);
    const out = try exportAll(vt);
    defer out.deinit(a);
    try std.testing.expectEqualStrings("]7501;state=working     ", out.text.history[0]);
    try std.testing.expectEqualStrings("]133;D;7 [6n [c         ", out.text.screen[0]);
    // A failed hydration does not fire callbacks either.
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 4, .rows = 1, .history = &.{}, .screen = &.{"\x1b[6n"} }, .{ .callbacks = callbacks }));
    try std.testing.expectEqual(State{}, state);
    // Callbacks are live for new PTY output afterwards.
    try vt.feed("\x1b]7501;state=working\x07\x1b]133;D;7\x07\x1b[6n\x07");
    try std.testing.expectEqual(@as(usize, 1), state.bell);
    try std.testing.expectEqual(@as(usize, 1), state.status);
    try std.testing.expectEqual(@as(usize, 1), state.prompt);
    try std.testing.expect(state.reply > 0);
}

fn hydrateAndExport(allocator: std.mem.Allocator) !void {
    const text: Vt.PlainText = .{ .cols = 6, .rows = 2, .history = &.{ "h界1", "he\xcc\x81" }, .screen = &.{ "screen", "x" } };
    var vt = try Vt.fromPlain(allocator, text, .{});
    defer vt.deinit();
    const out = (try vt.exportPlain(allocator, unlimited)).?;
    out.deinit(allocator);
}
test "plain: hydration and export clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(a, hydrateAndExport, .{});
}

fn hydrated(lines: usize) !Vt {
    const history = try a.alloc([]const u8, lines);
    defer a.free(history);
    const bufs = try a.alloc([16]u8, lines);
    defer a.free(bufs);
    for (history, bufs, 0..) |*row, *buf, i| row.* = try std.fmt.bufPrint(buf, "hist {d:0>5} 界", .{i});
    return Vt.fromPlain(a, .{ .cols = 20, .rows = 4, .history = history, .screen = &.{ "top", "", "mid", "bottom" } }, .{ .scrollback_lines = 20_000 });
}

test "plain: fresh stream snapshot and history backfill after hydration" {
    var src = try hydrated(3000);
    defer src.deinit();
    const expected = try exportAll(src);
    defer expected.deinit(a);
    var s = try src.streamSnapshot(a);
    defer s.deinit(a);
    try std.testing.expectEqual(@as(u64, 1), s.ready.epoch);
    try std.testing.expectEqual(@as(u64, 0), s.ready.oldest);
    try std.testing.expectEqual(@as(u64, 3000), s.ready.active);

    var dec = try Vt.Decoder.init(a, .{});
    errdefer dec.deinit();
    try dec.feedPrefix(s.prefix);
    var dst = try dec.ready(s.ready);
    defer dst.deinit();
    while (try s.nextHistory(4096)) |chunk| _ = try dst.feedHistory(chunk.bytes);
    try std.testing.expect(!dst.historyPending());
    try std.testing.expectEqual(src.rows(), dst.rows());
    const got = try exportAll(dst);
    defer got.deinit(a);
    try expectSamePlain(expected.text, got.text);
}

test "plain: vt replay after hydration reproduces history and screen" {
    var src = try hydrated(50);
    defer src.deinit();
    const expected = try exportAll(src);
    defer expected.deinit(a);
    const replay = try src.vtSnapshot(a, .{ .history = 50 });
    defer replay.deinit(a);
    try std.testing.expectEqual(@as(u64, 50), replay.history_rows);
    try std.testing.expectEqual(@as(usize, 0), replay.unfinished);
    var dst = try Vt.init(a, .{ .cols = 20, .rows = 4, .scrollback_lines = 20_000 });
    defer dst.deinit();
    try dst.feed(replay.bytes);
    const got = try exportAll(dst);
    defer got.deinit(a);
    try expectSamePlain(expected.text, got.text);
    try std.testing.expectEqual(src.cursor(), dst.cursor());
}

fn expectNoControls(row: []const u8) !void {
    var it = (try std.unicode.Utf8View.init(row)).iterator();
    while (it.nextCodepoint()) |cp| try std.testing.expect(!(cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)));
}
/// Pane output, however hostile, must export on both paths with no controls.
fn expectExports(vt: Vt) !Vt.PlainExport {
    const r = vt.rows();
    const all = try vt.exportRows(a, r.epoch, r.oldest, r.end);
    defer a.free(all);
    const out = (try vt.exportPlain(a, unlimited)).?;
    errdefer out.deinit(a);
    var rows = std.mem.splitScalar(u8, all[0 .. all.len - 1], '\n');
    for (out.lines) |line| {
        try expectNoControls(line);
        try std.testing.expectEqualStrings(rows.next().?, line);
    }
    return out;
}

test "plain: a DEL in a cell exports as a space and hydrates" {
    var vt = try Vt.init(a, .{ .cols = 9, .rows = 2, .scrollback_lines = 20 });
    defer vt.deinit();
    // In history and on screen: the row keeps its columns.
    try vt.feed("del\x7f\r\na\x7fb\r\n\x7f\x7f!");
    const out = try expectExports(vt);
    defer out.deinit(a);
    try std.testing.expectEqualStrings("del      ", out.text.history[0]);
    try std.testing.expectEqualStrings("a b      ", out.text.screen[0]);
    try std.testing.expectEqualStrings("  !      ", out.text.screen[1]);
    var dst = try Vt.fromPlain(a, out.text, .{ .scrollback_lines = 20 });
    defer dst.deinit();
    const again = try exportAll(dst);
    defer again.deinit(a);
    try expectSamePlain(out.text, again.text);
}

test "plain: untrusted bytes in cells export and hydrate" {
    const cases = [_]struct { bytes: []const u8, row: []const u8 }{
        .{ .bytes = "\x7f\x1b[3bx", .row = "    x    " }, // REP of a DEL
        .{ .bytes = "\x7f\xcc\x81", .row = " \xcc\x81        " }, // a mark on a DEL
        .{ .bytes = "a\xcc\x81\x7fb", .row = "a\xcc\x81 b      " },
        .{ .bytes = "\x1b(0\x7fq\x1b(B", .row = " \xe2\x94\x80       " }, // DEC charset
        .{ .bytes = "\x1b(A\x7f\x1b(Bx", .row = " x       " },
        .{ .bytes = "\x00\x01\x07\x0e\x0f\x1c\x1fx", .row = "x        " }, // C0 run, not stored
        .{ .bytes = "\xc2\x80\xc2\x85\xc2\x9b\xc2\x9fx", .row = "x        " }, // C1 as UTF-8
        .{ .bytes = "\x90a\x9cx", .row = "\xef\xbf\xbda\xef\xbf\xbdx     " }, // C1 as raw bytes
        .{ .bytes = "\xed\xa0\x80x", .row = "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbdx     " }, // a surrogate
        .{ .bytes = "\xf4\x90\x80\x80x", .row = "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbdx    " }, // past U+10FFFF
        .{ .bytes = "\xff\xfex", .row = "\xef\xbf\xbd\xef\xbf\xbdx      " },
        .{ .bytes = "\xee\x80\x80x", .row = "\xee\x80\x80x       " }, // private use
        .{ .bytes = "\xf4\x8f\xbf\xbfx", .row = "\xf4\x8f\xbf\xbfx       " },
        .{ .bytes = "\xef\xbf\xbex", .row = "\xef\xbf\xbex       " }, // noncharacter
        .{ .bytes = "\x1b]0;\x7f\x07\x1b[\x7fmx", .row = "x        " }, // DEL inside sequences
    };
    for (cases) |case| {
        var vt = try Vt.init(a, .{ .cols = 9, .rows = 2 });
        defer vt.deinit();
        try vt.feed(case.bytes);
        const out = try expectExports(vt);
        defer out.deinit(a);
        try std.testing.expectEqualStrings(case.row, out.text.screen[0]);
        var dst = try Vt.fromPlain(a, out.text, .{});
        defer dst.deinit();
    }
}

test "plain: random hostile output always exports" {
    var prng = std.Random.DefaultPrng.init(45);
    const random = prng.random();
    const atoms = [_][]const u8{ "\x7f", "a", " ", "\xcc\x81", "\xe2\x80\x8d", "\xef\xb8\x8f", "\xef\xb8\x8e", "\xf0\x9f\x91\xa9", "\xf0\x9f\x87\xba", "\xe7\x95\x8c", "\xe2\x8c\x9a", "\xc2\x9b", "\xc2\x85", "\xff", "\xed\xa0\x80", "\xee\x80\x80", "\xe1\x84\x80", "\xe1\x85\xa1", "\x1b[?2027h", "\x1b[?2027l", "\x1b[D", "\x1b[C", "\x1b[3b", "\r", "\n", "\t", "\x08", "\x1b[H", "\x1b[K", "\x1b[1P", "\x1b[2@", "\x1b(0", "\x1b(B", "\x1b[?7l", "\x1b[?7h", "\x1b[?1049h", "\x1b[?1049l", "\x1b[S", "\x1b[T", "\x1b[3;7r", "\x1b[r", "\x1bc" };
    for (0..400) |_| {
        var vt = try Vt.init(a, .{ .cols = 3 + random.uintLessThan(u16, 10), .rows = 3, .scrollback_lines = 50 });
        defer vt.deinit();
        for (0..random.uintLessThan(usize, 60)) |_| try vt.feed(atoms[random.uintLessThan(usize, atoms.len)]);
        // The active screen may be the alternate one, which exportRows reads
        // and exportPlain skips, so these are checked apart.
        const r = vt.rows();
        const all = try vt.exportRows(a, r.epoch, r.oldest, r.end);
        defer a.free(all);
        var rows = std.mem.splitScalar(u8, all[0 .. all.len - 1], '\n');
        while (rows.next()) |row| try expectNoControls(row);
        const out = try exportAll(vt);
        defer out.deinit(a);
        for (out.lines) |line| try expectNoControls(line);
    }
}

/// Both cell readers agree, return no controls and read as `exportRows` renders
/// the row, whatever the pane wrote.
fn expectCellsMatchExport(vt: Vt) !void {
    const r = vt.rows();
    const all = try vt.exportRows(a, r.epoch, r.oldest, r.end);
    defer a.free(all);
    var rows = std.mem.splitScalar(u8, all[0 .. all.len - 1], '\n');
    var buf: Vt.CellBuffer = undefined;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    for (r.oldest..r.end) |row| {
        line.clearRetainingCapacity();
        for (0..vt.size().cols) |col| {
            const cell = try vt.readCell(a, r.epoch, row, @intCast(col));
            defer a.free(cell.text);
            try expectNoControls(cell.text);
            if (try vt.readCellBuf(&buf, r.epoch, row, @intCast(col))) |borrowed| {
                try std.testing.expectEqualStrings(cell.text, borrowed.text);
                try std.testing.expectEqual(cell.width, borrowed.width);
            }
            if (cell.width != 0) try line.appendSlice(a, cell.text);
        }
        try std.testing.expectEqualStrings(rows.next().?, line.items);
    }
}

test "cells: a DEL reads as a space that keeps its column" {
    var vt = try Vt.init(a, .{ .cols = 9, .rows = 2 });
    defer vt.deinit();
    try vt.feed("a\x7fb");
    const r = vt.rows();
    const owned = try vt.readCell(a, r.epoch, r.active, 1);
    defer a.free(owned.text);
    try std.testing.expectEqualStrings(" ", owned.text);
    try std.testing.expectEqual(@as(u8, 1), owned.width);
    var buf: Vt.CellBuffer = undefined;
    const borrowed = (try vt.readCellBuf(&buf, r.epoch, r.active, 1)).?;
    try std.testing.expectEqualStrings(" ", borrowed.text);
    try std.testing.expectEqual(@as(u8, 1), borrowed.width);
    const next = (try vt.readCellBuf(&buf, r.epoch, r.active, 2)).?;
    try std.testing.expectEqualStrings("b", next.text);
}

test "cells: a DEL under a grapheme too long for readCellBuf" {
    const marks = "\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81\xcc\x81";
    var vt = try Vt.init(a, .{ .cols = 4, .rows = 1 });
    defer vt.deinit();
    try vt.feed("\x7f" ++ marks);
    const r = vt.rows();
    var buf: Vt.CellBuffer = undefined;
    try std.testing.expect(try vt.readCellBuf(&buf, r.epoch, r.active, 0) == null);
    const cell = try vt.readCell(a, r.epoch, r.active, 0);
    defer a.free(cell.text);
    try std.testing.expectEqualStrings(" " ++ marks, cell.text);
    try std.testing.expectEqual(@as(u8, 1), cell.width);
}

test "cells: untrusted bytes read as they export" {
    const cases = [_][]const u8{
        "del\x7f\r\na\x7fb\r\n\x7f\x7f!",
        "\x7f\x1b[3bx", // REP of a DEL
        "\x7f\xcc\x81", // a mark on a DEL
        "\x1b(0\x7fq\x1b(B", // DEC charset
        "\x00\x01\x07\x1fx",
        "\xc2\x80\xc2\x9fx",
        "\x90a\x9cx",
        "\xed\xa0\x80x", // a surrogate
        "\xf4\x90\x80\x80x", // past U+10FFFF
        "\xff\xfex",
        "\xee\x80\x80\xf4\x8f\xbf\xbf", // private use
    };
    for (cases) |bytes| {
        var vt = try Vt.init(a, .{ .cols = 9, .rows = 3, .scrollback_lines = 20 });
        defer vt.deinit();
        try vt.feed(bytes);
        try expectCellsMatchExport(vt);
    }
}

test "cells: random hostile output always reads" {
    var prng = std.Random.DefaultPrng.init(51);
    const random = prng.random();
    const atoms = [_][]const u8{ "\x7f", "\x7f", "a", " ", "\xcc\x81", "\xe2\x80\x8d", "\xef\xb8\x8f", "\xef\xb8\x8e", "\xf0\x9f\x91\xa9", "\xf0\x9f\x87\xba", "\xe7\x95\x8c", "\xc2\x9b", "\xc2\x85", "\xff", "\xed\xa0\x80", "\xee\x80\x80", "\x1b[?2027h", "\x1b[?2027l", "\x1b[D", "\x1b[C", "\x1b[3b", "\r", "\n", "\t", "\x08", "\x1b[H", "\x1b[K", "\x1b[1P", "\x1b[2@", "\x1b(0", "\x1b(B", "\x1b[?7l", "\x1b[?7h", "\x1b[?1049h", "\x1b[?1049l", "\x1bc" };
    for (0..400) |_| {
        var vt = try Vt.init(a, .{ .cols = 3 + random.uintLessThan(u16, 10), .rows = 3, .scrollback_lines = 50 });
        defer vt.deinit();
        for (0..random.uintLessThan(usize, 60)) |_| try vt.feed(atoms[random.uintLessThan(usize, atoms.len)]);
        try expectCellsMatchExport(vt);
    }
}

/// The rows of primary-screen history and screen, as the cell-by-cell
/// `exportRows` renders them, must equal the export under `limits`.
fn expectExportMatchesCells(vt: Vt, limits: Vt.PlainLimits) !void {
    const r = vt.rows();
    const all = try vt.exportRows(a, r.epoch, r.oldest, r.end);
    defer a.free(all);
    var rows: std.ArrayList([]const u8) = .empty;
    defer rows.deinit(a);
    var it = std.mem.splitScalar(u8, all[0 .. all.len - 1], '\n');
    while (it.next()) |row| try rows.append(a, row);
    const screen = vt.size().rows;
    try std.testing.expectEqual(@as(usize, @intCast(r.end - r.oldest)), rows.items.len);
    const out = (try vt.exportPlain(a, limits)) orelse return error.TestUnexpectedResult;
    defer out.deinit(a);
    // The budget keeps the screen, then the newest history that fits.
    var bytes: usize = 0;
    for (rows.items[rows.items.len - screen ..]) |row| bytes += row.len;
    var kept: usize = 0;
    const above = rows.items.len - screen;
    while (kept < above and screen + kept < limits.max_rows) : (kept += 1) {
        bytes += rows.items[above - 1 - kept].len;
        if (bytes > limits.max_bytes) break;
    }
    try std.testing.expectEqual(kept + screen, out.lines.len);
    for (rows.items[above - kept ..], out.lines) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(kept, out.text.history.len);
    try std.testing.expectEqual(@as(usize, screen), out.text.screen.len);
}

test "plain: export equals cell-by-cell rows across cell kinds" {
    var vt = try Vt.init(a, .{ .cols = 9, .rows = 4, .scrollback_lines = 200 });
    defer vt.deinit();
    const cases = [_][]const u8{
        "", // all blank
        "abc\r\n",
        "   \r\n", // literal spaces only
        "ab   \r\n", // literal trailing spaces
        "   ab\r\n",
        "\x1b[3Cab\r\n", // blank cells before text, never written
        "a\x1b[3Cb\r\n",
        "\x1b[41m\x1b[K\x1b[0m\r\n", // cells with only a background
        "x\x1b[42m\x1b[3X\x1b[0m\x1b[4Cy\r\n",
        "123456789\r\n", // exactly full
        "123456789overflow\r\n", // autowrap
        "12345678界\r\n", // spacer head at the end of an ASCII row
        "界\r\n", // wide cell and its tail
        "12345678\x1b[0K界\r\n",
        "e\xcc\x81\r\n", // combining mark
        "\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb\r\n", // ZWJ emoji
        "\x1b[?2027h1\xef\xb8\x8f\x1b[?2027l\r\n", // VS16 makes ASCII wide
        "\x1b(0qqq\x1b(B\r\n", // DEC line drawing maps ASCII out of ASCII
        "\tx\r\n",
        "\x1b[1;4;31mstyled\x1b[0m\r\n",
        "\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\\r\n",
        "abc\x1b[2D\x1b[1P\r\n", // deleted cell
        "\x1b[3bab\x1b[3b\r\n",
        "tilde~\r\n",
        "del\x7f\r\n", // DEL: takes a column, renders as a space
        "a\x7fb\r\n",
        "\x7f\x7f\r\n",
        "12345678\x7f\r\n", // full row ending in a DEL
        "\x7f\x1b[3bx\r\n", // REP of a DEL
        "\x7f\xcc\x81\r\n", // a mark on a DEL
        // Rows that need `contentEnd`.
        "界界界界\r\n", // ends on a tail, one column blank
        "a界界界界\r\n", // full, ends on a tail
        "1234567界\r\n", // full, wide cell in the last two columns
        "界x\x1b[K\r\n",
        "界 \r\n", // a literal space after the wide cell
        "界\x1b[4C \r\n", // ends in a literal space past a gap
        "界\x1b[4Cé\r\n",
        "\x1b[8C\xc3\xa9\r\n", // last column only
        "\xc3\xa9\x1b[41m\x1b[K\x1b[0m\r\n", // then background-only cells
        "\xe7\x95\x8c\x1b[42m\x1b[3X\x1b[0m\r\n",
        "\xe2\x94\x82 box \xe2\x94\x82\r\n", // narrow, not ASCII
        "\x1b(0qqqqqqqqq\x1b(B\r\n", // full row of DEC line drawing
        "e\xcc\x81\xcc\x82\xcc\x83\xcc\x84x\r\n", // marks: fewer columns than codepoints
        "\xcc\x81a\r\n", // a leading mark, on the blank row start
        "\xe2\x80\x8d\r\n", // a lone ZWJ, attached to nothing
        // Rows wider or narrower than the codepoint widths say.
        "\x1b[?2027h\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb\x1b[?2027l\r\n",
        "\x1b[?2027h\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbbab\x1b[?2027l\r\n",
        "\x1b[?2027h\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\x1b[?2027l\r\n", // a flag
        "\x1b[?2027h\xe2\x8c\x9a\xef\xb8\x8e\x1b[?2027l\r\n", // VS15 narrows a wide base
        "\x1b[?2027h#\xef\xb8\x8f\xe2\x83\xa3\x1b[?2027l\r\n", // keycap
        "\xe1\x84\x80\xe1\x85\xa1\r\n", // Hangul jamo
        // The formatter's text used as is, and rendered otherwise.
        "\xc2\x85x\r\n", // C1 in the input is not printed
        "界\x7f\r\n", // a DEL and a wide cell
        "\x1b]8;;http://x\x1b\\界link\x1b]8;;\x1b\\\r\n",
        "\x1b[31m界\x1b[0m\r\n",
        "\xef\xbf\xbd\r\n",
    };
    for (cases) |bytes| {
        try vt.feed(bytes);
        try expectExportMatchesCells(vt, unlimited);
    }
    // Rows after a resize, narrower and wider.
    try vt.resize(14, 3);
    try expectExportMatchesCells(vt, unlimited);
    try vt.resize(5, 6);
    try expectExportMatchesCells(vt, unlimited);
}

test "plain: export equals cell-by-cell rows when a pane changes mode 2027 between rows" {
    // Which guess `contentEnd` tries first follows the last row, so rows that
    // want each guess come in runs and one at a time. DEL rows use the same
    // path, with their text rewritten.
    const zwj = "\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb";
    const flag = "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8";
    const rows = [_][]const u8{
        "\x1b[?2027h" ++ zwj ++ zwj ++ "\r\n",
        zwj ++ "\r\n",
        flag ++ "x\r\n",
        "\x1b[?2027l" ++ zwj ++ "\r\n",
        zwj ++ zwj ++ "\r\n",
        "\x1b[?2027h" ++ flag ++ "\r\n",
        "\x1b[?2027l" ++ flag ++ "\r\n",
        "\x1b[?2027h" ++ zwj ++ "\x7f" ++ zwj ++ "\r\n", // both at once
        "\x7f" ++ zwj ++ "\x7f\r\n",
        "\x7f\r\n", // guesses agree and are right
        "\x1b[?2027l\x7f\xcc\x81\r\n",
        zwj ++ "\x7f" ++ zwj ++ "\r\n",
        // 2027 changes midway, so neither guess is right.
        "\x1b[?2027h" ++ zwj ++ "\x1b[?2027l" ++ zwj ++ "\r\n",
        "\x1b[?2027h" ++ zwj ++ "\x1b[?2027l" ++ zwj ++ "\x7f\x1b[?2027h\r\n",
        "\x1b[?2027h" ++ zwj ++ "\x1b[3C" ++ zwj ++ "\r\n", // a gap
        "\x1b[41m" ++ zwj ++ "\x1b[K\x1b[0m\r\n", // background past the text
        zwj ++ zwj ++ zwj ++ zwj ++ zwj ++ zwj ++ zwj ++ zwj ++ "\r\n", // reaches the last column
        "\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\r\n", // a full row of DEL
        "\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f" ++ zwj ++ "\r\n", // spacer head at the end
    };
    var vt = try Vt.init(a, .{ .cols = 16, .rows = 4, .scrollback_lines = 200 });
    defer vt.deinit();
    for (rows) |row| {
        try vt.feed(row);
        try expectExportMatchesCells(vt, unlimited);
    }
    // A row with more codepoints than the cluster guess measures, in history
    // of a pane that wants that guess.
    var long = try Vt.init(a, .{ .cols = 16, .rows = 2, .scrollback_lines = 20 });
    defer long.deinit();
    try long.feed("\x1b[?2027h" ++ zwj ++ "\r\n" ++ zwj);
    for (0..1100) |_| try long.feed("\xcc\x81");
    try long.feed("\r\n" ++ zwj ++ "\r\n");
    try expectExportMatchesCells(long, unlimited);
}

test "plain: export equals cell-by-cell rows in runs that share a column guess" {
    const zwj = "\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb";
    // Neighbours whose guess is the same but whose text ends elsewhere.
    const rows = [_][]const u8{
        "\xc3\xa9\r\n", // right
        "\xc3\xa9\r\n",
        "\x1b[?2027h1\xef\xb8\x8f\x1b[?2027l\r\n", // too low, and the probe starts on a wide tail
        "\xc3\xa9\r\n",
        "\xe7\x95\x8c\xe7\x95\x8c\r\n", // 4 columns, right
        zwj ++ "\r\n", // 4 columns with 2027 off, right
        "\x1b[?2027h" ++ zwj ++ "\x1b[?2027l\r\n", // too high: 2 columns
        "\xe7\x95\x8c\x7f\x7f\r\n", // 4 columns, with controls
        "\x7f\x7f\xc3\xa9\x7f\r\n",
        "\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\x1b[41m\x1b[K\x1b[0m\r\n", // background past the text
        "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\r\n",
        "\r\n", // a blank row splits a run
        "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\r\n",
        "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\r\n",
        "abcd\r\n", // ASCII splits one too
        "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\r\n",
    };
    var vt = try Vt.init(a, .{ .cols = 9, .rows = 4, .scrollback_lines = 100 });
    defer vt.deinit();
    for (rows) |row| {
        try vt.feed(row);
        try expectExportMatchesCells(vt, unlimited);
    }
    // Too much text for a rectangle to report: a run whose guess is low.
    var wide = try Vt.init(a, .{ .cols = 400, .rows = 2, .scrollback_lines = 200 });
    defer wide.deinit();
    for (0..100) |_| {
        try wide.feed("\x1b[?2027h");
        for (0..150) |_| try wide.feed("1\xef\xb8\x8f");
        try wide.feed("\x1b[?2027l\r\n");
    }
    try expectExportMatchesCells(wide, unlimited);
}

test "plain: a run with text past its guess, across pages, keeps its rows apart" {
    // A rectangle that starts past column 0 drops the newlines between pages,
    // so its lines say nothing about which row they came from. These rows all
    // guess column 2 (a sum of widths), the VS16 ones really end at 3, and the
    // pages are small enough at this width for a chunk to cross several.
    var vt = try Vt.init(a, .{ .cols = 200, .rows = 3, .scrollback_lines = 20000 });
    defer vt.deinit();
    try vt.feed("\x1b[?2027h");
    for (0..3000) |i| try vt.feed(if (i % 20 == 19) "1\xef\xb8\x8fa\r\n" else "\xc3\xa9a\r\n");
    for (0..4) |_| try vt.feed("\xc3\xa9a\r\n");
    try expectExportMatchesCells(vt, unlimited);
}

test "plain: a spacer head in a run keeps the rows after it apart" {
    // A rectangle starting on a spacer head skips that row without a newline.
    // Every row here guesses column 8, which is where the spacer head is.
    var vt = try Vt.init(a, .{ .cols = 9, .rows = 8, .scrollback_lines = 100 });
    defer vt.deinit();
    try vt.feed("\x1b[?2027h");
    try vt.feed("\xc3\xa9aaaaaaa\xe7\x95\x8c"); // the wide cell wraps to the next row
    try vt.feed("\r\x1b[K"); // which is then cleared
    try vt.feed("1\xef\xb8\x8faaaaaa\xc3\xa9\r\n"); // text in column 8, past the guess
    try vt.feed("\xc3\xa9aaaaaaa\r\n");
    try vt.feed("\xc3\xa9aaaaaaa\r\n");
    try expectExportMatchesCells(vt, unlimited);
}

test "plain: export equals cell-by-cell rows on random runs of similar rows" {
    var prng = std.Random.DefaultPrng.init(57);
    const random = prng.random();
    const atoms = [_][]const u8{ "\x7f", "a", " ", "\xc3\xa9", "\xcc\x81", "\xe2\x80\x8d", "\xef\xb8\x8f", "\xef\xb8\x8e", "1", "\xf0\x9f\x91\xa9", "\xf0\x9f\x87\xba", "\xe7\x95\x8c", "\xe2\x94\x80", "\x1b[?2027h", "\x1b[?2027l", "\x1b[C", "\x1b[3C", "\x1b[41m\x1b[K\x1b[0m", "\x1b[1P", "\x1b[2@" };
    for (0..1500) |_| {
        var vt = try Vt.init(a, .{ .cols = 1 + random.uintLessThan(u16, 24), .rows = 3, .scrollback_lines = 60 });
        defer vt.deinit();
        for (0..random.uintLessThan(usize, 12)) |_| {
            var row: [8][]const u8 = undefined;
            const len = random.uintLessThan(usize, row.len);
            for (row[0..len]) |*atom| atom.* = atoms[random.uintLessThan(usize, atoms.len)];
            for (0..1 + random.uintLessThan(usize, 6)) |_| {
                for (row[0..len]) |atom| try vt.feed(atom);
                // Now and then, one atom more makes a row that nearly matches.
                if (random.uintLessThan(u8, 4) == 0) try vt.feed(atoms[random.uintLessThan(usize, atoms.len)]);
                try vt.feed("\r\n");
            }
        }
        try expectExportMatchesCells(vt, unlimited);
        try vt.resize(1 + random.uintLessThan(u16, 24), 3);
        try expectExportMatchesCells(vt, unlimited);
    }
}

test "plain: export equals cell-by-cell rows across chunks and budgets" {
    // Blank runs, ASCII and wide rows on both sides of chunk and page edges.
    var vt = try Vt.init(a, .{ .cols = 40, .rows = 1500, .scrollback_lines = 8000 });
    defer vt.deinit();
    var prng = std.Random.DefaultPrng.init(24);
    const random = prng.random();
    const pieces = [_][]const u8{ "plain words", "界", "e\xcc\x81", " ", "\x1b[5C", "\x1b[41m\x1b[K\x1b[0m", "\t", "\x1b[31mred\x1b[0m", "0123456789012345678901234567890123456789012", "a\x7fb" };
    for (0..6000) |_| {
        const roll = random.uintLessThan(u8, 100);
        if (roll < 2) {
            // A blank run longer than a chunk.
            for (0..random.uintLessThan(usize, 1200)) |_| try vt.feed("\r\n");
            continue;
        }
        if (roll < 40) {
            try vt.feed("\r\n");
            continue;
        }
        for (0..random.uintLessThan(usize, 4)) |_| try vt.feed(pieces[random.uintLessThan(usize, pieces.len)]);
        try vt.feed("\r\n");
    }
    try std.testing.expect(vt.rows().active - vt.rows().oldest > 1024);
    try expectExportMatchesCells(vt, unlimited);
    // Limits landing inside, and exactly at, a chunk of history.
    try expectExportMatchesCells(vt, .{ .max_rows = 1500, .max_bytes = Vt.plain_max_bytes });
    try expectExportMatchesCells(vt, .{ .max_rows = 1500 + 1024, .max_bytes = Vt.plain_max_bytes });
    try expectExportMatchesCells(vt, .{ .max_rows = 1500 + 1500, .max_bytes = Vt.plain_max_bytes });
    try expectExportMatchesCells(vt, .{ .max_rows = Vt.plain_max_rows, .max_bytes = 2 * 1500 * 40 + 7 });
    // The primary screen under an alternate screen exports the same rows.
    const before = try exportAll(vt);
    defer before.deinit(a);
    try vt.feed("\x1b[?1049hALT");
    const under = try exportAll(vt);
    defer under.deinit(a);
    try expectSamePlain(before.text, under.text);
}

test "plain: export equals cell-by-cell rows on random non-ASCII output" {
    var prng = std.Random.DefaultPrng.init(44);
    const random = prng.random();
    // Everything that moves text between cells, but no alternate screen:
    // `exportRows` reads the active screen and `exportPlain` the primary one.
    const atoms = [_][]const u8{ "\x7f", "a", "a", " ", " ", "\xcc\x81", "\xe2\x80\x8d", "\xef\xb8\x8f", "\xef\xb8\x8e", "\xf0\x9f\x91\xa9", "\xf0\x9f\x87\xba", "\xe7\x95\x8c", "\xe7\x95\x8c", "\xe2\x8c\x9a", "\xe2\x94\x80", "\xc2\x85", "\xff", "\xe1\x84\x80", "\xe1\x85\xa1", "\x1b[?2027h", "\x1b[?2027l", "\x1b[D", "\x1b[C", "\x1b[3C", "\x1b[3b", "\r\n", "\r\n", "\t", "\x08", "\x1b[H", "\x1b[K", "\x1b[1K", "\x1b[2X", "\x1b[1P", "\x1b[2@", "\x1b(0q", "\x1b(B", "\x1b[?7l", "\x1b[?7h", "\x1b[S", "\x1b[T", "\x1b[41m", "\x1b[0m" };
    for (0..1500) |_| {
        var vt = try Vt.init(a, .{ .cols = 1 + random.uintLessThan(u16, 24), .rows = 3, .scrollback_lines = 50 });
        defer vt.deinit();
        for (0..random.uintLessThan(usize, 120)) |_| try vt.feed(atoms[random.uintLessThan(usize, atoms.len)]);
        try expectExportMatchesCells(vt, unlimited);
        // Rows change width when reflowed, including wide cells at the margin.
        try vt.resize(1 + random.uintLessThan(u16, 24), 3);
        try expectExportMatchesCells(vt, unlimited);
    }
}

/// Whatever `exportPlain` returns must hydrate, and so must what it
/// exports from the result. With `exact`, it must come back as the same text.
/// Without it, a row may have been laid out in a way no single mode rebuilds
/// (2027 switched midway, or clusters written apart); such a row is cut at the
/// last column, so it must come back as a non-empty start of itself.
fn expectRoundTrips(vt: Vt, exact: bool) !void {
    const out = try exportAll(vt);
    defer out.deinit(a);
    var dst = try Vt.fromPlain(a, out.text, .{});
    defer dst.deinit();
    const again = try exportAll(dst);
    defer again.deinit(a);
    if (exact) {
        try expectSamePlain(out.text, again.text);
    } else {
        try std.testing.expectEqual(out.lines.len, again.lines.len);
        for (out.lines, again.lines) |l, r| {
            const want = std.mem.trimEnd(u8, l, " ");
            const got = std.mem.trimEnd(u8, r, " ");
            // The first character survives, whatever happens to the rest.
            const first = std.unicode.utf8ByteSequenceLength(if (want.len > 0) want[0] else 'a') catch 1;
            try std.testing.expect(std.mem.startsWith(u8, got, want[0..@min(first, want.len)]));
        }
    }
    var third = try Vt.fromPlain(a, again.text, .{});
    third.deinit();
}

test "plain: last-column marks and mode 2027 widths hydrate" {
    const cases = [_][]const u8{
        "aaaaaaaaa\xcc\x81", // combining mark after a full row
        "\x1b[8Ca\xe1\x85\xa1", // Hangul vowel in the last column
        "\x1b[8Ca\xe2\x80\x8d", // ZWJ in the last column
        "\x1b[?2027h\xf0\x9f\x87\xba\xf0\x9f\x87\xb8", // flag
        "\x1b[?2027h\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa9", // ZWJ emoji
        "\x1b[?2027h1\xef\xb8\x8f",
        "\x1b[?2027h\xe2\x8c\x9a\xef\xb8\x8e",
        "\x1b[?2027haaaaaaa\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa9",
    };
    for (cases) |bytes| {
        var vt = try Vt.init(a, .{ .cols = 9, .rows = 2 });
        defer vt.deinit();
        try vt.feed(bytes);
        try expectRoundTrips(vt, true);
    }
}

test "plain: every export of random hostile output hydrates" {
    var prng = std.Random.DefaultPrng.init(50);
    const random = prng.random();
    const atoms = [_][]const u8{ "a", "a", "a", " ", "\xcc\x81", "\xe2\x80\x8d", "\xef\xb8\x8f", "\xef\xb8\x8e", "\xf0\x9f\x91\xa9", "\xf0\x9f\x87\xba", "\xf0\x9f\x87\xb8", "\xe7\x95\x8c", "\xe2\x8c\x9a", "\xe1\x84\x80", "\xe1\x85\xa1", "\xe1\x86\xa8", "1", "\x7f", "\xee\x80\x80", "\x1b[?2027h", "\x1b[?2027l", "\x1b[D", "\x1b[C", "\x1b[8C", "\x1b[3b", "\r", "\n", "\x08", "\x1b[H", "\x1b[K", "\x1b[1P", "\x1b[2@", "\x1b[?7l", "\x1b[?7h", "\x1b[?1049h", "\x1b[?1049l", "\x1bc" };
    for (0..6000) |_| {
        var vt = try Vt.init(a, .{ .cols = 3 + random.uintLessThan(u16, 10), .rows = 3, .scrollback_lines = 50 });
        defer vt.deinit();
        for (0..random.uintLessThan(usize, 60)) |_| try vt.feed(atoms[random.uintLessThan(usize, atoms.len)]);
        // Mode 2027 is on by default, and text from it is not exact: marks
        // and regional indicators written apart can read as one cluster.
        try expectRoundTrips(vt, false);
    }
}

test "plain: a last-column row at the bottom of a screen with history hydrates" {
    // The row that needs autowrap on is the last one: no row follows to clear
    // its pending wrap, and the probe terminal is not the real one.
    var src = try Vt.init(a, .{ .cols = 9, .rows = 3, .scrollback_lines = 100 });
    defer src.deinit();
    try src.feed("one\r\ntwo\r\naaaaaaaaa\xcc\x81\r\nbbbbbbbbb\xcc\x81\r\nccccccccc\xe2\x80\x8d");
    const out = try exportAll(src);
    defer out.deinit(a);
    try std.testing.expect(out.text.history.len >= 2);
    try std.testing.expectEqualStrings("ccccccccc\xe2\x80\x8d", out.text.screen[2]);
    var dst = try Vt.fromPlain(a, out.text, .{});
    defer dst.deinit();
    const again = try exportAll(dst);
    defer again.deinit(a);
    try expectSamePlain(out.text, again.text);
    try std.testing.expectEqual(Vt.Cursor{ .x = 0, .y = 0, .visible = true }, dst.cursor());
    // Writing after hydration behaves: autowrap is on and nothing is pending.
    try dst.feed("\x1b[3;1H\x1b[2Kxyz");
    const after = try exportAll(dst);
    defer after.deinit(a);
    try std.testing.expectEqualStrings("xyz      ", after.text.screen[2]);
}

test "plain: rows no pane could export stay rejected" {
    // Flags that cannot fit under either layout of mode 2027 (9 cells at least
    // each way in 5 columns).
    const flags = "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\xf0\x9f\x87\xba\xf0\x9f\x87\xb8";
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 5, .rows = 1, .history = &.{}, .screen = &.{flags} }, .{}));
}

test "plain: the cut of a mixed-mode row is reported and bounded by cols" {
    // A flag, a Hangul vowel and an emoji, found by fuzzing a pane that
    // switched mode 2027 midway: no single mode reads it back, and with 2027
    // on it is exactly 7 cells wide.
    const row = "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\xe1\x85\xa1\xf0\x9f\x91\xa9   ";
    const ok = try Vt.fromPlainReport(a, .{ .cols = 7, .rows = 1, .history = &.{}, .screen = &.{row} }, .{});
    var vt = ok.vt;
    defer vt.deinit();
    try std.testing.expectEqual(@as(usize, 1), ok.cut_rows);
    const out = try exportAll(vt);
    defer out.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, out.text.screen[0], "\xf0\x9f\x87\xba"));
    // The same text in history and on the screen counts twice.
    var two = try Vt.fromPlainReport(a, .{ .cols = 7, .rows = 1, .history = &.{row}, .screen = &.{row} }, .{});
    defer two.vt.deinit();
    try std.testing.expectEqual(@as(usize, 2), two.cut_rows);
    // Exact text reports no cut, and fromPlain still returns just the Vt.
    var plain = try Vt.fromPlainReport(a, .{ .cols = 7, .rows = 1, .history = &.{}, .screen = &.{"abc"} }, .{});
    defer plain.vt.deinit();
    try std.testing.expectEqual(@as(usize, 0), plain.cut_rows);
    var same = try Vt.fromPlain(a, .{ .cols = 7, .rows = 1, .history = &.{}, .screen = &.{row} }, .{});
    same.deinit();
    // One cell narrower or two, the 2027-on layout no longer fits: rejected.
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 6, .rows = 1, .history = &.{}, .screen = &.{row} }, .{}));
    try std.testing.expectError(error.InvalidValue, Vt.fromPlain(a, .{ .cols = 5, .rows = 1, .history = &.{}, .screen = &.{row} }, .{}));
}
