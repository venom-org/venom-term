//! Pane-stream snapshot tests.
const std = @import("std");
const Vt = @import("vt.zig").Vt;
const a = std.testing.allocator;

fn fill(vt: Vt, lines: usize) !void {
    for (0..lines) |i| {
        var buf: [64]u8 = undefined;
        try vt.feed(try std.fmt.bufPrint(&buf, "\x1b[3{d}mline {d:0>5} \xe7\x95\x8c\x1b[0m\r\n", .{ i % 8, i }));
    }
}
fn exportAll(vt: Vt) ![]u8 {
    const r = vt.rows();
    return vt.exportRows(a, r.epoch, r.oldest, r.end);
}
fn expectSameText(x: Vt, y: Vt) !void {
    const left = try exportAll(x);
    defer a.free(left);
    const right = try exportAll(y);
    defer a.free(right);
    try std.testing.expectEqualStrings(left, right);
}
/// Decoder over `prefix`, fed in uneven pieces as SNAPSHOT frames would be.
fn decodePrefix(s: Vt.SnapshotStream, piece: usize) !Vt {
    var dec = try Vt.Decoder.init(a, .{});
    errdefer dec.deinit();
    var at: usize = 0;
    while (at < s.prefix.len) : (at += piece) try dec.feedPrefix(s.prefix[at..@min(at + piece, s.prefix.len)]);
    return dec.ready(s.ready);
}

test "format names carry the ghostty pin" {
    try std.testing.expectEqualStrings("0fa3d577a561", Vt.ghostty_pin);
    try std.testing.expectEqualStrings("ghostty/1@0fa3d577a561", Vt.ghostty_format);
    try std.testing.expectEqualStrings("vt", Vt.vt_format);
}

test "stream: READY metadata and per-chunk row counts match rows()" {
    var src = try Vt.init(a, .{ .cols = 80, .rows = 24, .scrollback_lines = 20_000 });
    defer src.deinit();
    try fill(src, 5000);
    while (try src.compress()) {}
    var s = try src.streamSnapshot(a);
    defer s.deinit(a);
    const r = src.rows();
    try std.testing.expectEqual(r.epoch, s.ready.epoch);
    try std.testing.expectEqual(r.oldest, s.ready.oldest);
    try std.testing.expectEqual(r.active, s.ready.active);
    try std.testing.expect(s.ready.oldest < s.ready.top and s.ready.top <= s.ready.active);
    try std.testing.expectEqual(@as(u16, 80), s.ready.cols);

    var dst = try decodePrefix(s, 7);
    defer dst.deinit();
    try std.testing.expectEqual(Vt.Rows{ .epoch = r.epoch, .oldest = s.ready.top, .end = r.end, .active = r.active }, dst.rows());
    try std.testing.expect(dst.historyPending());

    var expected_end = s.ready.top;
    var labelled: u64 = 0; // rows of all chunks fed so far
    var applied: u64 = 0;
    var chunks: usize = 0;
    while (try s.nextHistory(4096)) |chunk| {
        chunks += 1;
        try std.testing.expectEqual(expected_end, chunk.end_row);
        try std.testing.expect(chunk.bytes.len <= 4096 or chunk.rows > 0);
        const before = labelled;
        labelled += chunk.rows;
        expected_end -= chunk.rows;
        applied += try dst.feedHistory(chunk.bytes);
        // Rows are applied up to one page late (ghostty peeks the next
        // record header), never early, and always land at their labels.
        try std.testing.expect(applied >= before and applied <= labelled);
        try std.testing.expectEqual(s.ready.top - applied, dst.rows().oldest);
        if (chunk.last) {
            try std.testing.expectEqual(labelled, applied);
            try std.testing.expect(!dst.historyPending());
        }
    }
    try std.testing.expect(chunks > 2);
    try std.testing.expectEqual(s.ready.top - r.oldest, labelled);
    try std.testing.expectEqual(r, dst.rows());
    try expectSameText(src, dst);
    const cell = try dst.readCell(a, r.epoch, r.oldest + 3, 11);
    defer a.free(cell.text);
    try std.testing.expectEqualStrings("界", cell.text);
}

test "stream: live feed between history chunks, then resize aborts" {
    var src = try Vt.init(a, .{ .cols = 40, .rows = 10, .scrollback_lines = 20_000 });
    defer src.deinit();
    try fill(src, 2000);
    var s = try src.streamSnapshot(a);
    defer s.deinit(a);
    var dst = try decodePrefix(s, 1000);
    defer dst.deinit();
    var n: usize = 0;
    while (try s.nextHistory(2048)) |chunk| : (n += 1) {
        _ = try dst.feedHistory(chunk.bytes);
        var buf: [32]u8 = undefined;
        const live = try std.fmt.bufPrint(&buf, "live {d}\r\n", .{n});
        try src.feed(live);
        try dst.feed(live);
    }
    try std.testing.expectEqual(src.rows(), dst.rows());
    try expectSameText(src, dst);

    // An epoch change stops backfill; the rows already restored stay valid.
    var s2 = try src.streamSnapshot(a);
    defer s2.deinit(a);
    var dst2 = try decodePrefix(s2, 64);
    defer dst2.deinit();
    const first = (try s2.nextHistory(2048)).?;
    _ = try dst2.feedHistory(first.bytes);
    try dst2.resize(30, 10);
    try std.testing.expectError(error.StaleRows, dst2.feedHistory((try s2.nextHistory(2048)).?.bytes));
    try std.testing.expect(!dst2.historyPending());
    try std.testing.expectError(error.InvalidValue, dst2.feedHistory("x"));
}

test "stream: alternate screen, no history, and abandon" {
    var src = try Vt.init(a, .{ .cols = 20, .rows = 4 });
    defer src.deinit();
    try fill(src, 50);
    try src.feed("\x1b[?1049halt screen");
    var s = try src.streamSnapshot(a);
    defer s.deinit(a);
    // Alternate screen has no scrollback: primary history pages carry 0 rows.
    try std.testing.expectEqual(s.ready.oldest, s.ready.top);
    var dst = try decodePrefix(s, 3);
    defer dst.deinit();
    try std.testing.expectEqual(src.rows(), dst.rows());
    var rows: u64 = 0;
    while (try s.nextHistory(1 << 20)) |chunk| rows += try dst.feedHistory(chunk.bytes);
    try std.testing.expectEqual(@as(u64, 0), rows);
    try dst.feed("\x1b[?1049l");
    try src.feed("\x1b[?1049l");
    try expectSameText(src, dst);

    var empty = try Vt.init(a, .{ .cols = 20, .rows = 4 });
    defer empty.deinit();
    var s2 = try empty.streamSnapshot(a);
    defer s2.deinit(a);
    try std.testing.expectEqual(s2.ready.oldest, s2.ready.top);
    const only = (try s2.nextHistory(1024)).?;
    try std.testing.expect(only.last and only.rows == 0);
    try std.testing.expectEqual(@as(?Vt.HistoryChunk, null), try s2.nextHistory(1024));
    var dst2 = try decodePrefix(s2, 100);
    defer dst2.deinit();
    dst2.abandonHistory();
    try std.testing.expect(!dst2.historyPending());
}

test "stream decoder rejects malformed input" {
    var src = try Vt.init(a, .{ .cols = 20, .rows = 4 });
    defer src.deinit();
    try fill(src, 30);
    var s = try src.streamSnapshot(a);
    defer s.deinit(a);
    {
        var dec = try Vt.Decoder.init(a, .{});
        defer dec.deinit();
        try dec.feedPrefix(s.prefix[0 .. s.prefix.len - 1]);
        try std.testing.expectError(error.InvalidSnapshot, dec.ready(s.ready));
    }
    {
        var dec = try Vt.Decoder.init(a, .{});
        defer dec.deinit();
        try dec.feedPrefix(s.prefix);
        var meta = s.ready;
        meta.active += 1;
        try std.testing.expectError(error.InvalidSnapshot, dec.ready(meta));
    }
    {
        var dec = try Vt.Decoder.init(a, .{});
        defer dec.deinit();
        try dec.feedPrefix(s.prefix);
        try dec.feedPrefix("trailing");
        try std.testing.expectError(error.InvalidSnapshot, dec.ready(s.ready));
    }
}

fn replayInto(replay: Vt.VtReplay, cols: u16, rows: u16) !Vt {
    var vt = try Vt.init(a, .{ .cols = cols, .rows = rows });
    errdefer vt.deinit();
    try vt.feed(replay.bytes);
    return vt;
}

test "vt replay reproduces screen, history, styles, cursor and terminal state" {
    var src = try Vt.init(a, .{ .cols = 20, .rows = 5 });
    defer src.deinit();
    try fill(src, 12);
    try src.feed("\x1b]2;my title\x07\x1b]8;;https://x.test\x07link\x1b]8;;\x07 \x1b[1;4:3mbold\x1b[0m e\xcc\x81");
    try src.feed("\x1b[6 q\x1b[?2004h\x1b[?1006h\x1b[?1002h\x1b[?1h\x1b[>4;2m\x1b]11;rgb:10/20/30\x07");
    try src.feed("\x1b[2;3H\x1b7\x1b[2;4r\x1b[4;7H\x1b[38;2;1;2;3m");
    const replay = try src.vtSnapshot(a, .{ .history = 3 });
    defer replay.deinit(a);
    try std.testing.expectEqual(@as(u64, 3), replay.history_rows);
    try std.testing.expectEqual(@as(usize, 0), replay.unfinished);
    var dst = try replayInto(replay, 20, 5);
    defer dst.deinit();

    const r = src.rows();
    const d = dst.rows();
    try std.testing.expectEqual(@as(u64, 3), d.active - d.oldest);
    const want = try src.exportRows(a, r.epoch, r.active - 3, r.end);
    defer a.free(want);
    const got = try dst.exportRows(a, d.epoch, d.oldest, d.end);
    defer a.free(got);
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(src.cursor(), dst.cursor());
    const bold = try dst.readCell(a, d.epoch, d.active + 4, 5);
    defer a.free(bold.text);
    try std.testing.expect(bold.style.bold and bold.style.underline == .curly);
    // Everything the replay captures (modes, title, colours, shape, region,
    // pen) round-trips: replaying the copy yields the same bytes.
    const again = try dst.vtSnapshot(a, .{});
    defer again.deinit(a);
    const plain = try src.vtSnapshot(a, .{});
    defer plain.deinit(a);
    try std.testing.expectEqualStrings(plain.bytes, again.bytes);
    try std.testing.expect(std.mem.indexOf(u8, plain.bytes, "\x1b]2;my title") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.bytes, "\x1b[6 q") != null);
    // Saved cursor (DECSC) survives: restoring it lands where it was saved.
    try src.feed("\x1b8");
    try dst.feed("\x1b8");
    try std.testing.expectEqual(src.cursor(), dst.cursor());
}

test "vt replay with the alternate screen active keeps the primary screen" {
    var src = try Vt.init(a, .{ .cols = 16, .rows = 4 });
    defer src.deinit();
    try fill(src, 6);
    try src.feed("prompt$ ");
    try src.feed("\x1b[?1049h\x1b[2;2Hfull\x1b[7mscreen");
    const replay = try src.vtSnapshot(a, .{ .history = 2 });
    defer replay.deinit(a);
    try std.testing.expectEqual(@as(u64, 2), replay.history_rows);
    var dst = try replayInto(replay, 16, 4);
    defer dst.deinit();
    try std.testing.expectEqual(src.cursor(), dst.cursor());
    const alt_src = try exportAll(src);
    defer a.free(alt_src);
    const alt_dst = try exportAll(dst);
    defer a.free(alt_dst);
    try std.testing.expectEqualStrings(alt_src, alt_dst);
    try src.feed("\x1b[?1049l");
    try dst.feed("\x1b[?1049l");
    const r = src.rows();
    const d = dst.rows();
    const want = try src.exportRows(a, r.epoch, r.active - 2, r.end);
    defer a.free(want);
    const got = try dst.exportRows(a, d.epoch, d.oldest, d.end);
    defer a.free(got);
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(src.cursor(), dst.cursor());
}

test "vt replay is labelled at the last ground state" {
    var src = try Vt.init(a, .{ .cols = 20, .rows = 3 });
    defer src.deinit();
    try src.feed("abc\x1b[3");
    var replay = try src.vtSnapshot(a, .{});
    try std.testing.expectEqual(@as(usize, 3), replay.unfinished);
    replay.deinit(a);
    try src.feed("1mX\xe7\x95");
    replay = try src.vtSnapshot(a, .{});
    try std.testing.expectEqual(@as(usize, 2), replay.unfinished);
    // Replaying, then the unfinished bytes and what follows, matches.
    var dst = try replayInto(replay, 20, 3);
    defer dst.deinit();
    replay.deinit(a);
    try src.feed("\x8c!");
    try dst.feed("\xe7\x95\x8c!");
    try expectSameText(src, dst);
    try std.testing.expectEqual(src.cursor(), dst.cursor());
    replay = try src.vtSnapshot(a, .{});
    defer replay.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), replay.unfinished);
}

test "host query colors do not recolor snapshots and program overrides win" {
    const Replies = struct {
        bytes: std.ArrayList(u8) = .empty,
        fn write(ctx: ?*anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.bytes.appendSlice(std.testing.allocator, bytes) catch @panic("OOM");
        }
    };
    const gpa = std.testing.allocator;
    var replies: Replies = .{};
    defer replies.bytes.deinit(gpa);
    var vt = try Vt.init(gpa, .{ .callbacks = .{ .context = &replies, .write_pty = Replies.write } });
    defer vt.deinit();
    try vt.feed("hello");
    const before = try vt.snapshot(gpa);
    defer before.deinit(gpa);
    vt.setQueryColors(.{ .fg = .{ 0x11, 0x22, 0x33 }, .bg = .{ 0x44, 0x55, 0x66 }, .cursor = .{ 0x77, 0x88, 0x99 } });
    try vt.feed("\x1b]10;?\x07\x1b]11;?\x07\x1b]12;?\x07");
    try std.testing.expect(std.mem.indexOf(u8, replies.bytes.items, "1111/2222/3333") != null);
    try std.testing.expect(std.mem.indexOf(u8, replies.bytes.items, "4444/5555/6666") != null);
    try std.testing.expect(std.mem.indexOf(u8, replies.bytes.items, "7777/8888/9999") != null);
    const after = try vt.snapshot(gpa);
    defer after.deinit(gpa);
    try std.testing.expectEqualSlices(u8, before.bytes, after.bytes);
    replies.bytes.clearRetainingCapacity();
    try vt.feed("\x1b]10;#abcdef\x07\x1b]10;?\x07");
    try std.testing.expect(std.mem.indexOf(u8, replies.bytes.items, "abab/cdcd/efef") != null);
    replies.bytes.clearRetainingCapacity();
    try vt.feed("\x1b]110\x07\x1b]10;?\x07");
    try std.testing.expect(std.mem.indexOf(u8, replies.bytes.items, "1111/2222/3333") != null);
    vt.setQueryColors(.{});
    replies.bytes.clearRetainingCapacity();
    try vt.feed("\x1b]10;?\x07");
    try std.testing.expect(std.mem.indexOf(u8, replies.bytes.items, "1111/2222/3333") == null);
}

fn expectNoHostTables(replay: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, replay, "\x1b]4;") == null);
    try std.testing.expect(std.mem.indexOf(u8, replay, "\x1b[3g") == null);
    try std.testing.expect(std.mem.indexOf(u8, replay, "\x1bH") == null);
}

test "vt replay leaves a palette and tab stops the program never set" {
    var src = try Vt.init(a, .{ .cols = 83, .rows = 3 });
    defer src.deinit();
    try src.feed("\x1b[31mred\x1b[0m\r\nplain\ttab");
    const replay = try src.vtSnapshot(a, .{});
    defer replay.deinit(a);
    try expectNoHostTables(replay.bytes);
    var dst = try replayInto(replay, 83, 3);
    defer dst.deinit();
    try expectSameText(src, dst);
    try std.testing.expectEqual(src.cursor(), dst.cursor());
}

test "vt replay without tab stops still dumps from the top left" {
    var src = try Vt.init(a, .{ .cols = 20, .rows = 4 });
    defer src.deinit();
    // The replay moves the cursor to set the saved one, before the dump.
    try src.feed("one\r\ntwo\x1b[3;5H\x1b7\x1b[2;2H");
    var replay = try src.vtSnapshot(a, .{});
    try expectNoHostTables(replay.bytes);
    var dst = try replayInto(replay, 20, 4);
    defer dst.deinit();
    replay.deinit(a);
    try expectSameText(src, dst);
    try std.testing.expectEqual(src.cursor(), dst.cursor());
    try src.feed("\x1b8");
    try dst.feed("\x1b8");
    try std.testing.expectEqual(src.cursor(), dst.cursor());
    // On the alternate screen the home has to come after `?1049h`, and the
    // primary screen's cursor has to survive it.
    try src.feed("\x1b[?1049h\x1b[2;3Halt");
    replay = try src.vtSnapshot(a, .{});
    try expectNoHostTables(replay.bytes);
    var alt = try replayInto(replay, 20, 4);
    defer alt.deinit();
    replay.deinit(a);
    try expectSameText(src, alt);
    try std.testing.expectEqual(src.cursor(), alt.cursor());
    try src.feed("\x1b[?1049l");
    try alt.feed("\x1b[?1049l");
    try expectSameText(src, alt);
    try std.testing.expectEqual(src.cursor(), alt.cursor());
}

test "vt replay writes the palette entries a program set, and no others" {
    var src = try Vt.init(a, .{ .cols = 20, .rows = 3 });
    defer src.deinit();
    // Entry 7 is set to the built-in default's value, and still counts: the
    // host's entry 7 can differ. Entry 9 is set and then reset.
    try src.feed("\x1b]4;1;rgb:12/34/56\x07\x1b]4;200;#abcdef\x1b\\\x1b]4;7;rgb:c5/c8/c6\x07\x1b]4;9;red\x07\x1b]104;9\x07x");
    var replay = try src.vtSnapshot(a, .{});
    defer replay.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, replay.bytes, "\x1b]4;"));
    for ([_][]const u8{ "\x1b]4;1;rgb:12/34/56\x1b\\", "\x1b]4;7;rgb:c5/c8/c6\x1b\\", "\x1b]4;200;rgb:ab/cd/ef\x1b\\" }) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, replay.bytes, entry) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, replay.bytes, "\x1b[3g") == null);
    // It survives a replay, and a restore from a ghostty snapshot.
    var dst = try replayInto(replay, 20, 3);
    defer dst.deinit();
    const again = try dst.vtSnapshot(a, .{});
    defer again.deinit(a);
    try std.testing.expectEqualStrings(replay.bytes, again.bytes);
    const snap = try src.snapshot(a);
    defer snap.deinit(a);
    var restored = try Vt.restore(a, snap, .{});
    defer restored.deinit();
    const from_restored = try restored.vtSnapshot(a, .{});
    defer from_restored.deinit(a);
    try std.testing.expectEqualStrings(replay.bytes, from_restored.bytes);
    // Resetting them all takes them out again.
    try src.feed("\x1b]104\x07");
    replay.deinit(a);
    replay = try src.vtSnapshot(a, .{});
    try expectNoHostTables(replay.bytes);
    // So does RIS, for the palette and the tab stops.
    try src.feed("\x1b]4;1;rgb:12/34/56\x07\x1b[3g\x1bc");
    replay.deinit(a);
    replay = try src.vtSnapshot(a, .{});
    try expectNoHostTables(replay.bytes);
}

test "vt replay writes tab stops only when a program changed them" {
    var src = try Vt.init(a, .{ .cols = 30, .rows = 3 });
    defer src.deinit();
    const stops = "\x1b[3g\x1b[6G\x1bH\x1b[21G\x1bH\x1b[H";
    try src.feed("\x1b[3g\x1b[6G\x1bH\x1b[21G\x1bH\x1b[1;1Habc");
    var replay = try src.vtSnapshot(a, .{});
    try std.testing.expect(std.mem.indexOf(u8, replay.bytes, stops) != null);
    try std.testing.expect(std.mem.indexOf(u8, replay.bytes, "\x1b]4;") == null);
    // They arrive: a tab from column 1 goes to the first program stop.
    var dst = try replayInto(replay, 30, 3);
    defer dst.deinit();
    replay.deinit(a);
    try dst.feed("\r\t");
    try std.testing.expectEqual(@as(u16, 5), dst.cursor().x);
    try dst.feed("\t");
    try std.testing.expectEqual(@as(u16, 20), dst.cursor().x);
    // Clearing one stop alone is a change too.
    var one = try Vt.init(a, .{ .cols = 30, .rows = 3 });
    defer one.deinit();
    try one.feed("\x1b[1;9H\x1b[g\x1b[H");
    replay = try one.vtSnapshot(a, .{});
    try std.testing.expect(std.mem.indexOf(u8, replay.bytes, "\x1b[3g") != null);
    replay.deinit(a);
    // Back to the default stops: nothing to replay, here and after a width
    // change, which resets them.
    try src.feed("\x1b[?5W");
    replay = try src.vtSnapshot(a, .{});
    try expectNoHostTables(replay.bytes);
    replay.deinit(a);
    try one.resize(40, 3);
    replay = try one.vtSnapshot(a, .{});
    defer replay.deinit(a);
    try expectNoHostTables(replay.bytes);
}
