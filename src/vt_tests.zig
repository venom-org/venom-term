const std = @import("std");
const Vt = @import("vt.zig").Vt;
const Color = @import("vt.zig").Color;
const a = std.testing.allocator;
test "snapshot preserves styles unicode and unfinished CSI" {
    var vt = try Vt.init(a, .{ .cols = 12, .rows = 3 });
    defer vt.deinit();
    try vt.feed("\x1b[31m界e\xcc\x81\x1b[3");
    const snap = try vt.snapshot(a);
    defer snap.deinit(a);
    var restored = try Vt.restore(a, snap, .{});
    defer restored.deinit();
    try vt.feed("2mOK");
    try restored.feed("2mOK");
    const before = try vt.exportRows(a, vt.rows().epoch, vt.rows().oldest, vt.rows().end);
    defer a.free(before);
    const after = try restored.exportRows(a, restored.rows().epoch, restored.rows().oldest, restored.rows().end);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    const wide = try restored.readCell(a, restored.rows().epoch, restored.rows().active, 0);
    defer a.free(wide.text);
    try std.testing.expectEqualStrings("界", wide.text);
    try std.testing.expectEqual(@as(u8, 2), wide.width);
    try std.testing.expectEqual(@as(u8, 1), wide.style.fg.index);
}
test "absolute rows survive pruning and reject stale epochs" {
    var vt = try Vt.init(a, .{ .cols = 80, .rows = 3, .scrollback_lines = 5 });
    defer vt.deinit();
    const epoch = vt.rows().epoch;
    for (0..2000) |i| {
        var buf: [32]u8 = undefined;
        try vt.feed(try std.fmt.bufPrint(&buf, "L{d:0>6}\r\n", .{i}));
    }
    const bounds = vt.rows();
    try std.testing.expectEqual(epoch, bounds.epoch);
    try std.testing.expect(bounds.oldest > 0);
    const line = try vt.exportRows(a, bounds.epoch, 1999, 2000);
    defer a.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, "L001999"));
    try std.testing.expectError(error.StaleRows, vt.exportRows(a, epoch, 0, 1));
    try vt.feed("\x1b[3Jmore\r\n");
    try std.testing.expect(vt.rows().epoch > epoch);
    const cleared = vt.rows().epoch;
    try vt.resize(40, 3);
    try std.testing.expect(vt.rows().epoch > cleared);
    try std.testing.expectError(error.StaleRows, vt.exportRows(a, cleared, 0, 1));
}
test "OSC callbacks and query replies across fragmented feeds" {
    const State = struct {
        status: usize = 0,
        prompt: usize = 0,
        reply: usize = 0,
        fn statusCb(ctx: ?*anyopaque, report: Vt.ProgramStatus) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (report.state == .working) self.status += 1;
        }
        fn promptCb(ctx: ?*anyopaque, event: Vt.SemanticPrompt) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (event.kind == .command_end and event.exit_code == 7) self.prompt += 1;
        }
        fn replyCb(ctx: ?*anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.reply += bytes.len;
        }
    };
    var state: State = .{};
    var vt = try Vt.init(a, .{ .callbacks = .{ .context = &state, .write_pty = State.replyCb, .program_status = State.statusCb, .semantic_prompt = State.promptCb } });
    defer vt.deinit();
    for ("\x1b]7501;state=working\x07\x1b]133;D;7\x1b\\\x1b[6n") |byte| try vt.feed(&.{byte});
    try std.testing.expectEqual(@as(usize, 1), state.status);
    try std.testing.expectEqual(@as(usize, 1), state.prompt);
    try std.testing.expect(state.reply > 0);
    try vt.feed("\x1b]7501;garbage\x07\x1b]133;garbage\x07");
    try std.testing.expectEqual(@as(usize, 1), state.status);
    const epoch = vt.rows().epoch;
    try vt.feed("\x1bc");
    try std.testing.expect(vt.rows().epoch > epoch);
}
test "bell fires once per BEL, never for an OSC or DCS terminator" {
    const State = struct {
        bells: usize = 0,
        fn bellCb(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.bells += 1;
        }
    };
    var state: State = .{};
    var vt = try Vt.init(a, .{ .callbacks = .{ .context = &state, .bell = State.bellCb } });
    defer vt.deinit();
    try vt.feed("ding\x07");
    try std.testing.expectEqual(@as(usize, 1), state.bells);
    // BEL as a string terminator, whole and split across feeds.
    try vt.feed("\x1b]0;title\x07\x1b]7501;state=working\x07\x1bPq\x07");
    for ("\x1b]2;t\x07") |byte| try vt.feed(&.{byte});
    try std.testing.expectEqual(@as(usize, 1), state.bells);
    try vt.feed("\x07\x07");
    try std.testing.expectEqual(@as(usize, 3), state.bells);
    // No callback set: a BEL is harmless.
    var quiet = try Vt.init(a, .{});
    defer quiet.deinit();
    try quiet.feed("\x07");
}
test "restore metadata rows compression and alternate screen" {
    var vt = try Vt.init(a, .{ .cols = 12, .rows = 3, .scrollback_lines = 10 });
    defer vt.deinit();
    for (0..1000) |_| try vt.feed("hello\r\n");
    while (try vt.compress()) {}
    const bounds = vt.rows();
    const snap = try vt.snapshot(a);
    defer snap.deinit(a);
    var restored = try Vt.restore(a, snap, .{});
    defer restored.deinit();
    try std.testing.expectEqual(bounds, restored.rows());
    try restored.feed("more\r\n");
    try std.testing.expectEqual(bounds.epoch, restored.rows().epoch);
    try vt.feed("\x1b[?1049h");
    try std.testing.expect(vt.rows().epoch > bounds.epoch);
    try vt.feed("alt\x1b[?1049l");
    try std.testing.expect(vt.rows().epoch > bounds.epoch + 1);
    try std.testing.expectError(error.InvalidValue, vt.resize(0, 3));
}
test "restore tracks subsequent unfinished input and rejects invalid metadata" {
    var vt = try Vt.init(a, .{ .cols = 8, .rows = 2 });
    defer vt.deinit();
    const snap = try vt.snapshot(a);
    defer snap.deinit(a);
    var restored = try Vt.restore(a, snap, .{});
    defer restored.deinit();
    try restored.feed("\x1b[31");
    const again = try restored.snapshot(a);
    defer again.deinit(a);
    var copy = try Vt.restore(a, again, .{});
    defer copy.deinit();
    try copy.feed("mred");
    const cell = try copy.readCell(a, copy.rows().epoch, copy.rows().active, 0);
    defer a.free(cell.text);
    try std.testing.expectEqual(@as(u8, 1), cell.style.fg.index);
    var invalid = snap;
    invalid.oldest = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidSnapshot, Vt.restore(a, invalid, .{}));
}
fn initAndFree(allocator: std.mem.Allocator) !void {
    var vt = try Vt.init(allocator, .{ .cols = 4, .rows = 2 });
    defer vt.deinit();
}
test "VT initialization cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(a, initAndFree, .{});
}

test "batched text preserves bytewise rows through large writes and erasure" {
    for ([_]u16{ 2, 8, 80 }) |cols| {
        for ([_]usize{ 0, 5, 100 }) |scrollback| {
            var vt = try Vt.init(a, .{ .cols = cols, .rows = 3, .scrollback_lines = scrollback });
            defer vt.deinit();
            var reference = try Vt.init(a, .{ .cols = cols, .rows = 3, .scrollback_lines = scrollback });
            defer reference.deinit();
            // Both long wrapping text and explicit line breaks must preserve
            // absolute addresses while pruning many pages in a single feed.
            const output = comptime blk: {
                const line = "abcdefghijklmnopqrstuvwxyz0123456789\r\n";
                var buf: [line.len * 60]u8 = undefined;
                for (0..60) |i| @memcpy(buf[i * line.len ..][0..line.len], line);
                break :blk buf;
            };
            // SGR-heavy rows: styles join the bounded run, so the run may
            // end on SGR, start with it, or hold no printable byte at all.
            const styled = comptime blk: {
                const line = "\x1b[38;5;196m\x1b[1mab\x1b[0mcd\x1b[38:2::1:2:3mefghij\x1b[2m\x1b[0m\r\n\x1b[7m\x1b[0m\r\n";
                var buf: [line.len * 40]u8 = undefined;
                for (0..40) |i| @memcpy(buf[i * line.len ..][0..line.len], line);
                break :blk buf;
            };
            for ([_][]const u8{
                &output,
                &styled,
                // Not SGR: a private prefix, an intermediate, a bare ESC [m
                // split from its final byte across feeds.
                "ab\x1b[>4;1mcd\x1b[1 qef\x1b[m\x1b[",
                "31mgh\x1b[0m\r\n",
                // Regrow past the original row count after clearing history:
                // observing only the final row count would miss the erasure.
                "\x1b[3J" ++ output,
                "\x1b[?1049halt\x1b[?1049l" ++ output,
                "\x1bc" ++ output,
                "\x1b[31mred\x1b[0m界e\xcc\x81\x1b[3",
                "2mgreen\xf0\x9f",
            }) |input| {
                const prior = vt.rows();
                try vt.feed(input);
                for (input) |byte| try reference.feed(&.{byte});
                const bounds = vt.rows();
                try std.testing.expectEqual(reference.rows(), bounds);
                const actual = try vt.exportRows(a, bounds.epoch, bounds.oldest, bounds.end);
                defer a.free(actual);
                const expected = try reference.exportRows(a, bounds.epoch, bounds.oldest, bounds.end);
                defer a.free(expected);
                try std.testing.expectEqualStrings(expected, actual);
                const replay = try vt.vtSnapshot(a, .{});
                defer replay.deinit(a);
                const expected_replay = try reference.vtSnapshot(a, .{});
                defer expected_replay.deinit(a);
                try std.testing.expectEqual(expected_replay.unfinished, replay.unfinished);
                try std.testing.expectEqualStrings(expected_replay.bytes, replay.bytes);
                if (bounds.epoch != prior.epoch or bounds.oldest > prior.oldest)
                    try std.testing.expectError(error.StaleRows, vt.exportRows(a, prior.epoch, prior.oldest, prior.oldest + 1));
            }
        }
    }
}

test "title metadata observes OSC 0/2, fragments and reset without snapshots" {
    var vt = try Vt.init(a, .{});
    defer vt.deinit();
    try std.testing.expectEqualStrings("", try vt.title());
    try vt.feed("\x1b]2;shared λ");
    try std.testing.expectEqualStrings("", try vt.title());
    try vt.feed("\x07");
    try std.testing.expectEqualStrings("shared λ", try vt.title());
    try vt.feed("\x1b]0;renamed\x1b\\");
    try std.testing.expectEqualStrings("renamed", try vt.title());
    try vt.feed("\x1bc");
    try std.testing.expectEqualStrings("", try vt.title());
}

test "pwd metadata preserves the last OSC 7 URI without decoding" {
    var vt = try Vt.init(a, .{});
    defer vt.deinit();
    try std.testing.expectEqual(null, try vt.pwd());
    try vt.feed("\x1b]7;file://host/tmp/x\x1b\\");
    try std.testing.expectEqualStrings("file://host/tmp/x", (try vt.pwd()).?);
    try vt.feed("\x1b]7;file://host/tmp/a%20b\x1b\\");
    try std.testing.expectEqualStrings("file://host/tmp/a%20b", (try vt.pwd()).?);
    try vt.feed("\x1b]7;\x1b\\");
    try std.testing.expectEqual(null, try vt.pwd());
    try vt.feed("\x1b]9;9;/home/u/proj\x1b\\");
    try std.testing.expectEqualStrings("/home/u/proj", (try vt.pwd()).?);
    try vt.feed("\x1b]1337;CurrentDir=/srv/app\x07");
    try std.testing.expectEqualStrings("/srv/app", (try vt.pwd()).?);
}

test "CRLF batches match bytewise state at wraps, margins and one-row pruning" {
    for ([_]u16{ 1, 3 }) |rows| {
        for ([_][]const u8{ "", "\x1b[?7l", "\x1b[?69h\x1b[2;4s", "\x1b[1;2r\x1b[?6h" }) |setup| {
            var vt = try Vt.init(a, .{ .cols = 5, .rows = rows, .scrollback_lines = 0 });
            defer vt.deinit();
            var reference = try Vt.init(a, .{ .cols = 5, .rows = rows, .scrollback_lines = 0 });
            defer reference.deinit();
            try vt.feed(setup);
            try reference.feed(setup);
            for ([_][]const u8{
                "12345", // Pending wrap before the next batch.
                "a\r\nb\r\n12345\r\n\r\n123456789\r\n",
                "123\x1b[?69h\x1b[2;4sabcd\r\nefgh\r\n\x1b[?69lxyz\r\n",
                "\x1bc12345\r\n12345\r\n12\r\n",
            }) |input| {
                try vt.feed(input);
                for (input) |byte| try reference.feed(&.{byte});
                try std.testing.expectEqual(reference.rows(), vt.rows());
                const snap = try vt.vtSnapshot(a, .{});
                defer snap.deinit(a);
                const expected = try reference.vtSnapshot(a, .{});
                defer expected.deinit(a);
                try std.testing.expectEqualStrings(expected.bytes, snap.bytes);
            }
        }
    }
}
/// The previous `exportRows`, cell by cell through `readCell`.
fn exportByCells(vt: Vt, epoch: u64, start: u64, end: u64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    for (start..end) |row| {
        for (0..vt.size().cols) |col| {
            const cell = try vt.readCell(a, epoch, row, @intCast(col));
            defer a.free(cell.text);
            if (cell.width != 0) try out.writer.writeAll(cell.text);
        }
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}
test "exportRows matches cell-by-cell rendering" {
    var vt = try Vt.init(a, .{ .cols = 9, .rows = 4, .scrollback_lines = 100 });
    defer vt.deinit();
    // Wide, combining, ZWJ emoji, a wide char that cannot fit at the end of
    // a row (spacer head), a wrapped line, blank rows, tab and styles.
    try vt.feed("界e\xcc\x81\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb\r\n12345678漢字\r\n\r\nlong wrapped line here\r\n\ta\x1b[31mred\x1b[0m\r\n");
    for (0..12) |i| {
        var buf: [16]u8 = undefined;
        try vt.feed(try std.fmt.bufPrint(&buf, "h{d}\r\n", .{i}));
    }
    const r = vt.rows();
    try std.testing.expect(r.active > r.oldest);
    const expected = try exportByCells(vt, r.epoch, r.oldest, r.end);
    defer a.free(expected);
    const actual = try vt.exportRows(a, r.epoch, r.oldest, r.end);
    defer a.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    const empty = try vt.exportRows(a, r.epoch, r.end, r.end);
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.InvalidValue, vt.exportRows(a, r.epoch, r.active + 1, r.active));
    try std.testing.expectError(error.StaleRows, vt.exportRows(a, r.epoch, r.oldest, r.end + 1));
    try std.testing.expectError(error.StaleRows, vt.exportRows(a, r.epoch + 1, r.oldest, r.end));
}
test "screen reports the active screen" {
    var vt = try Vt.init(a, .{ .cols = 10, .rows = 3, .scrollback_lines = 100 });
    defer vt.deinit();
    try vt.feed("1\r\n2\r\n3\r\n4\r\n5");
    try std.testing.expectEqual(Vt.Screen.primary, vt.screen());
    try std.testing.expect(vt.rows().oldest < vt.rows().active);
    inline for (.{ "\x1b[?1049h", "\x1b[?1047h", "\x1b[?47h" }, .{ "\x1b[?1049l", "\x1b[?1047l", "\x1b[?47l" }) |enter, leave| {
        const before = vt.rows().epoch;
        try vt.feed(enter);
        try std.testing.expectEqual(Vt.Screen.alternate, vt.screen());
        try std.testing.expect(vt.rows().epoch != before);
        try std.testing.expectEqual(vt.rows().oldest, vt.rows().active);
        try vt.feed("x\r\ny\r\nz\r\nw");
        try std.testing.expectEqual(vt.rows().oldest, vt.rows().active);
        try vt.feed(leave);
        try std.testing.expectEqual(Vt.Screen.primary, vt.screen());
    }
}

test "rowPrompt flags OSC 133 A rows, scrollback included, and prev/next walk them" {
    var vt = try Vt.init(a, .{ .cols = 20, .rows = 3, .scrollback_lines = 100 });
    defer vt.deinit();
    // Plain output first: no prompts anywhere.
    try vt.feed("zero\r\n");
    const e = vt.rows().epoch;
    try std.testing.expectEqual(@as(?u64, null), try vt.prevPromptRow(e, vt.rows().end));
    try std.testing.expectEqual(@as(?u64, null), try vt.nextPromptRow(e, vt.rows().oldest));
    // Prompts on absolute rows 1 and 4; row 5 is a continuation.
    try vt.feed("\x1b]133;A\x07$ \x1b]133;B\x07one\r\n\x1b]133;C\x07out\r\nout\r\n\x1b]133;A\x07$ \x1b]133;B\x07two\r\n\x1b]133;C\x07\x1b]133;A;k=s\x07> more\r\ntail\r\n");
    const b = vt.rows();
    try std.testing.expectEqual(e, b.epoch);
    try std.testing.expect(b.oldest > 0 or b.end > 5);
    try std.testing.expectEqual(Vt.RowPrompt.none, try vt.rowPrompt(e, b.oldest));
    try std.testing.expectEqual(Vt.RowPrompt.start, try vt.rowPrompt(e, 1));
    try std.testing.expectEqual(Vt.RowPrompt.none, try vt.rowPrompt(e, 2));
    try std.testing.expectEqual(Vt.RowPrompt.start, try vt.rowPrompt(e, 4));
    try std.testing.expectEqual(Vt.RowPrompt.continuation, try vt.rowPrompt(e, 5));
    // Rows 1 and 4 are in scrollback by now (3-row screen).
    try std.testing.expect(b.active > 4);
    // Edges: nothing before the first, nothing after the last.
    try std.testing.expectEqual(@as(?u64, null), try vt.prevPromptRow(e, 1));
    try std.testing.expectEqual(@as(?u64, 1), try vt.prevPromptRow(e, 2));
    try std.testing.expectEqual(@as(?u64, 4), try vt.prevPromptRow(e, 5));
    try std.testing.expectEqual(@as(?u64, 4), try vt.prevPromptRow(e, b.end));
    try std.testing.expectEqual(@as(?u64, 1), try vt.nextPromptRow(e, 0));
    try std.testing.expectEqual(@as(?u64, 4), try vt.nextPromptRow(e, 1));
    try std.testing.expectEqual(@as(?u64, null), try vt.nextPromptRow(e, 4));
    try std.testing.expectEqual(@as(?u64, null), try vt.nextPromptRow(e, b.end));
    try std.testing.expectError(error.StaleRows, vt.rowPrompt(e + 1, 1));
    try std.testing.expectError(error.StaleRows, vt.rowPrompt(e, b.end));
    try std.testing.expectError(error.StaleRows, vt.prevPromptRow(e, b.end + 1));
}

test "vtSnapshot with history keeps the OSC 133 flag on the same rows" {
    var src = try Vt.init(a, .{ .cols = 20, .rows = 3, .scrollback_lines = 100 });
    defer src.deinit();
    for (0..30) |i| {
        var buf: [64]u8 = undefined;
        const mark: []const u8 = if (i % 5 == 0) "\x1b]133;A\x07" else if (i % 11 == 0) "\x1b]133;A;k=s\x07" else "";
        try src.feed(try std.fmt.bufPrint(&buf, "{s}row {d}\r\n", .{ mark, i }));
    }
    const replay = try src.vtSnapshot(a, .{ .history = 1000 });
    defer replay.deinit(a);
    var dst = try Vt.init(a, .{ .cols = 20, .rows = 3, .scrollback_lines = 100 });
    defer dst.deinit();
    try dst.feed(replay.bytes);
    const rs = src.rows();
    const rd = dst.rows();
    try std.testing.expectEqual(rs.end - rs.oldest, rd.end - rd.oldest);
    var starts: usize = 0;
    for (0..rs.end - rs.oldest) |k| {
        const want = try src.rowPrompt(rs.epoch, rs.oldest + k);
        try std.testing.expectEqual(want, try dst.rowPrompt(rd.epoch, rd.oldest + k));
        if (want == .start) starts += 1;
    }
    try std.testing.expect(starts > 3);
}

test "a replay taken at an idle prompt behaves like the source for live output" {
    var src = try Vt.init(a, .{ .cols = 10, .rows = 5 });
    defer src.deinit();
    try src.feed("old\r\n\x1b]133;A\x07$ \x1b]133;B\x07");
    const replay = try src.vtSnapshot(a, .{ .history = 100 });
    defer replay.deinit(a);
    var dst = try Vt.init(a, .{ .cols = 10, .rows = 5 });
    defer dst.deinit();
    try dst.feed(replay.bytes);
    const live = "0123456789abcdef\r\nline2\r\n";
    try src.feed(live);
    try dst.feed(live);
    const rs = src.rows();
    const rd = dst.rows();
    try std.testing.expectEqual(rs.end - rs.oldest, rd.end - rd.oldest);
    var flagged: usize = 0;
    for (0..rs.end - rs.oldest) |k| {
        const want = try src.rowPrompt(rs.epoch, rs.oldest + k);
        try std.testing.expectEqual(want, try dst.rowPrompt(rd.epoch, rd.oldest + k));
        if (want != .none) flagged += 1;
    }
    try std.testing.expect(flagged >= 2);
}

test "vtSnapshot keeps a blank prompt row flagged" {
    var src = try Vt.init(a, .{ .cols = 10, .rows = 3, .scrollback_lines = 100 });
    defer src.deinit();
    try src.feed("x\r\n\x1b]133;A\x07abc\x1b]133;C\x07\r\x1b[2K\nout\r\nmore\r\n");
    const replay = try src.vtSnapshot(a, .{ .history = 100 });
    defer replay.deinit(a);
    var dst = try Vt.init(a, .{ .cols = 10, .rows = 3, .scrollback_lines = 100 });
    defer dst.deinit();
    try dst.feed(replay.bytes);
    const rs = src.rows();
    const rd = dst.rows();
    try std.testing.expectEqual(rs.end - rs.oldest, rd.end - rd.oldest);
    try std.testing.expectEqual(Vt.RowPrompt.start, try src.rowPrompt(rs.epoch, rs.oldest + 1));
    for (0..rs.end - rs.oldest) |k| {
        try std.testing.expectEqual(try src.rowPrompt(rs.epoch, rs.oldest + k), try dst.rowPrompt(rd.epoch, rd.oldest + k));
    }
}

test "cursorShape follows DECSCUSR, and default means the program set none" {
    var vt = try Vt.init(a, .{ .cols = 10, .rows = 3 });
    defer vt.deinit();
    const S = Vt.CursorShape;
    try std.testing.expectEqual(S{}, try vt.cursorShape());
    const cases = [_]struct { []const u8, S }{
        .{ "\x1b[1 q", .{ .kind = .block, .blink = true } },
        .{ "\x1b[2 q", .{ .kind = .block } },
        .{ "\x1b[3 q", .{ .kind = .underline, .blink = true } },
        .{ "\x1b[4 q", .{ .kind = .underline } },
        .{ "\x1b[5 q", .{ .kind = .bar, .blink = true } },
        .{ "\x1b[6 q", .{ .kind = .bar } },
        .{ "\x1b[0 q", .{} },
        .{ "\x1b[6 q\x1b[ q", .{} },
        .{ "\x1b[6 q\x1bc", .{} },
    };
    for (cases) |case| {
        try vt.feed(case[0]);
        try std.testing.expectEqual(case[1], try vt.cursorShape());
    }
    // Reading the shape folds row damage; the rows still count as changed.
    var fresh = try Vt.init(a, .{ .cols = 10, .rows = 3 });
    defer fresh.deinit();
    _ = try fresh.changes();
    try fresh.feed("x\x1b[6 q");
    try std.testing.expectEqual(S{ .kind = .bar }, try fresh.cursorShape());
    const ch = try fresh.changes();
    try std.testing.expect(ch.rows[0] == ch.generation);
}

test "the cursor shape survives a snapshot restore and a VT replay" {
    const S = Vt.CursorShape;
    for ([_]struct { []const u8, S }{ .{ "", .{} }, .{ "\x1b[6 q", .{ .kind = .bar } }, .{ "\x1b[3 q", .{ .kind = .underline, .blink = true } } }) |case| {
        var vt = try Vt.init(a, .{ .cols = 10, .rows = 3 });
        defer vt.deinit();
        try vt.feed(case[0]);
        const snap = try vt.snapshot(a);
        defer snap.deinit(a);
        var restored = try Vt.restore(a, snap, .{});
        defer restored.deinit();
        try std.testing.expectEqual(case[1], try restored.cursorShape());
        const replay = try vt.vtSnapshot(a, .{});
        defer replay.deinit(a);
        var dst = try Vt.init(a, .{ .cols = 10, .rows = 3 });
        defer dst.deinit();
        try dst.feed(replay.bytes);
        try std.testing.expectEqual(case[1], try dst.cursorShape());
    }
}
test "an erased cell keeps its background colour" {
    var vt = try Vt.init(a, .{ .cols = 8, .rows = 3 });
    defer vt.deinit();
    // EL under a palette background, ECH under an RGB one, ED after a reset.
    try vt.feed("\x1b[48;5;236mab\x1b[K\r\n\x1b[48;2;40;41;42m\x1b[3X\x1b[0m\r\n\x1b[44m\x1b[J");
    const r = vt.rows();
    const cases = .{
        .{ 0, 0, Color{ .index = 236 } },
        .{ 0, 7, Color{ .index = 236 } },
        .{ 1, 2, Color{ .rgb = .{ 40, 41, 42 } } },
        .{ 1, 3, Color.default },
        .{ 2, 5, Color{ .index = 4 } },
    };
    var buf: Vt.CellBuffer = undefined;
    inline for (cases) |case| {
        const cell = try vt.readCell(a, r.epoch, r.active + case[0], case[1]);
        defer a.free(cell.text);
        try std.testing.expectEqual(case[2], cell.style.bg);
        const borrowed = (try vt.readCellBuf(&buf, r.epoch, r.active + case[0], case[1])).?;
        try std.testing.expectEqual(case[2], borrowed.style.bg);
    }
}

test "syncOutput follows DEC mode 2026" {
    var vt = try Vt.init(a, .{ .cols = 10, .rows = 3 });
    defer vt.deinit();
    try std.testing.expect(!try vt.syncOutput());
    try vt.feed("\x1b[?2026h");
    try std.testing.expect(try vt.syncOutput());
    try vt.feed("frame\x1b[?2026l");
    try std.testing.expect(!try vt.syncOutput());
    try vt.feed("\x1b[?2026h\x1bc");
    try std.testing.expect(!try vt.syncOutput());
}

test "a snapshot taken mid-frame restores with synchronized output on" {
    var vt = try Vt.init(a, .{ .cols = 10, .rows = 3 });
    defer vt.deinit();
    try vt.feed("\x1b[?2026hhalf");
    const snap = try vt.snapshot(a);
    defer snap.deinit(a);
    var restored = try Vt.restore(a, snap, .{});
    defer restored.deinit();
    try std.testing.expect(try restored.syncOutput());
}
const Replies = struct {
    buf: std.ArrayList(u8) = .empty,
    fn cb(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.buf.appendSlice(a, bytes) catch unreachable;
    }
    fn take(self: *@This(), vt: Vt, query: []const u8) ![]const u8 {
        self.buf.clearRetainingCapacity();
        try vt.feed(query);
        return self.buf.items;
    }
};
fn graphemeMode(vt: Vt, r: *Replies) ![]const u8 {
    return r.take(vt, "\x1b[?2027$p");
}
test "grapheme clustering is on: a Devanagari conjunct is two cells wide" {
    var r: Replies = .{};
    defer r.buf.deinit(a);
    var vt = try Vt.init(a, .{ .cols = 10, .rows = 2, .callbacks = .{ .context = &r, .write_pty = Replies.cb } });
    defer vt.deinit();
    try std.testing.expectEqualStrings("\x1b[?2027;1$y", try graphemeMode(vt, &r));
    try vt.feed("क्षि");
    try std.testing.expectEqual(@as(u16, 2), vt.cursor().x);
    // RIS keeps it on.
    try vt.feed("\x1bc");
    try std.testing.expectEqualStrings("\x1b[?2027;1$y", try graphemeMode(vt, &r));
}
test "mode 2027 survives snapshot and restore, on and off" {
    var r: Replies = .{};
    defer r.buf.deinit(a);
    for ([_]bool{ true, false }) |on| {
        var vt = try Vt.init(a, .{ .cols = 10, .rows = 2 });
        defer vt.deinit();
        if (!on) try vt.feed("\x1b[?2027l");
        const snap = try vt.snapshot(a);
        defer snap.deinit(a);
        var restored = try Vt.restore(a, snap, .{ .context = &r, .write_pty = Replies.cb });
        defer restored.deinit();
        try std.testing.expectEqualStrings(if (on) "\x1b[?2027;1$y" else "\x1b[?2027;2$y", try graphemeMode(restored, &r));
        try restored.feed("क्षि");
        try std.testing.expectEqual(@as(u16, if (on) 2 else 3), restored.cursor().x);
        // The reset default is still on after restore.
        try restored.feed("\x1bc");
        try std.testing.expectEqualStrings("\x1b[?2027;1$y", try graphemeMode(restored, &r));
    }
}
test "query replies: DA1 advertises OSC 52, XTVERSION, TN, color scheme" {
    var r: Replies = .{};
    defer r.buf.deinit(a);
    var vt = try Vt.init(a, .{ .callbacks = .{ .context = &r, .write_pty = Replies.cb } });
    defer vt.deinit();
    try std.testing.expectEqualStrings("\x1b[?62;22;52c", try r.take(vt, "\x1b[c"));
    try std.testing.expectEqualStrings("\x1b[>1;0;0c", try r.take(vt, "\x1b[>c"));
    try std.testing.expectEqualStrings("", try r.take(vt, "\x1b[?996n"));
    try std.testing.expectEqualStrings("", try r.take(vt, "\x1bP+q544e\x1b\\"));
    try vt.setReplies(.{ .xtversion = "venomx 1.2.3", .terminfo_name = "xterm-256color", .color_scheme = .dark });
    try std.testing.expectEqualStrings("\x1bP>|venomx 1.2.3\x1b\\", try r.take(vt, "\x1b[>q"));
    try std.testing.expectEqualStrings("\x1b[?997;1n", try r.take(vt, "\x1b[?996n"));
    const tn = try r.take(vt, "\x1bP+q544e\x1b\\");
    // "xterm-256color" in hex.
    try std.testing.expectEqualStrings("\x1bP1+r544E=787465726D2D323536636F6C6F72\x1b\\", tn);
    try std.testing.expectError(error.InvalidValue, vt.setReplies(.{ .xtversion = &@as([65]u8, @splat('x')) }));
}
test "cell size answers XTWINOPS and survives resize" {
    var r: Replies = .{};
    defer r.buf.deinit(a);
    var vt = try Vt.init(a, .{ .cols = 80, .rows = 24, .cell = .{ .width = 10, .height = 20 }, .callbacks = .{ .context = &r, .write_pty = Replies.cb } });
    defer vt.deinit();
    try std.testing.expectEqualStrings("\x1b[4;480;800t", try r.take(vt, "\x1b[14t"));
    try std.testing.expectEqualStrings("\x1b[6;20;10t", try r.take(vt, "\x1b[16t"));
    try std.testing.expectEqualStrings("\x1b[8;24;80t", try r.take(vt, "\x1b[18t"));
    try vt.resize(100, 30);
    try std.testing.expectEqualStrings("\x1b[4;600;1000t", try r.take(vt, "\x1b[14t"));
    const epoch = vt.rows().epoch;
    try vt.feed("keep");
    try vt.setCellSize(.{ .width = 8, .height = 16 });
    try std.testing.expectEqual(epoch, vt.rows().epoch);
    try std.testing.expectEqual(@as(u16, 4), vt.cursor().x);
    try std.testing.expectEqualStrings("\x1b[6;16;8t", try r.take(vt, "\x1b[16t"));
    try std.testing.expectEqual(Vt.CellSize{ .width = 8, .height = 16 }, vt.cellSize());
}
