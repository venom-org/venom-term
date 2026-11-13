//! Pane-stream client tests. `Pane` plays the server's part on a real Vt, so
//! the client decodes real ghostty and vt snapshots and every byte it applies
//! went through the same emulator on both sides.
const std = @import("std");
const ps = @import("pane_stream.zig");
const Vt = @import("vt").Vt;
const PaneStream = ps.PaneStream;
const Kind = ps.Kind;
const a = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const size: ps.Size = .{ .cols = 40, .rows = 4 };
const last: u8 = 1;
const aborted: u8 = 2;

const Pane = struct {
    vt: Vt,
    offset: u64 = 0,

    fn init(cols: u16, rows: u16) !Pane {
        return .{ .vt = try Vt.init(a, .{ .cols = cols, .rows = rows, .scrollback_lines = 20_000 }) };
    }
    fn deinit(self: *Pane) void {
        self.vt.deinit();
    }
    /// The program writes `bytes`; the frame goes to every client.
    fn write(self: *Pane, bytes: []const u8, clients: []const *PaneStream) !void {
        try self.vt.feed(bytes);
        for (clients) |c| try sendPty(c, self.offset, bytes);
        self.offset += bytes.len;
    }
    /// Advance the pane without delivering, as a dropped frame would.
    fn writeUnseen(self: *Pane, bytes: []const u8) !void {
        try self.vt.feed(bytes);
        self.offset += bytes.len;
    }
    fn fill(self: *Pane, lines: usize) !void {
        for (0..lines) |i| {
            var buf: [64]u8 = undefined;
            try self.writeUnseen(try std.fmt.bufPrint(&buf, "\x1b[3{d}mline {d:0>5} \xe7\x95\x8c\x1b[0m\r\n", .{ i % 8, i }));
        }
    }
    fn attached(_: *Pane, c: *PaneStream, format: []const u8, input: bool) !void {
        const json = try std.fmt.allocPrint(a, "{{\"source\":\"venomx/test\",\"pane\":\"p0\",\"mode\":\"{s}\",\"format\":\"{s}\",\"resumed\":false,\"input\":{},\"policy\":\"latest\"}}", .{ @tagName(c.mode), format, input });
        defer a.free(json);
        try c.handle(Kind.attached, json);
    }
    /// SNAPSHOT chunks of `piece` bytes then READY. The caller owns the
    /// result, the source of later SCROLLBACK frames.
    fn snapshot(self: *Pane, c: *PaneStream, snap: u32, piece: usize) !Vt.SnapshotStream {
        var s = try self.vt.streamSnapshot(a);
        errdefer s.deinit(a);
        var at: usize = 0;
        while (at < s.prefix.len) : (at += piece) try sendSnapshot(c, snap, self.offset, s.prefix[at..@min(at + piece, s.prefix.len)]);
        try sendReady(c, snap, self.offset, s.ready);
        return s;
    }
    fn vtSnapshot(self: *Pane, c: *PaneStream, snap: u32) !void {
        const replay = try self.vt.vtSnapshot(a, .{});
        defer replay.deinit(a);
        const r = self.vt.rows();
        const sz = self.vt.size();
        try sendSnapshot(c, snap, self.offset, replay.bytes);
        try sendReady(c, snap, self.offset, .{ .epoch = r.epoch, .oldest = r.oldest, .top = r.oldest, .active = r.active, .cols = sz.cols, .rows = sz.rows });
    }
    fn resize(self: *Pane, cols: u16, rows: u16, c: *PaneStream) !void {
        try self.vt.resize(cols, rows);
        const json = try std.fmt.allocPrint(a, "{{\"offset\":{d},\"cols\":{d},\"rows\":{d}}}", .{ self.offset, cols, rows });
        defer a.free(json);
        try c.handle(Kind.resize, json);
    }
};

fn sendPty(c: *PaneStream, offset: u64, bytes: []const u8) !void {
    const frame = try a.alloc(u8, 8 + bytes.len);
    defer a.free(frame);
    std.mem.writeInt(u64, frame[0..8], offset, .big);
    @memcpy(frame[8..], bytes);
    try c.handle(Kind.pty, frame);
}
fn sendSnapshot(c: *PaneStream, snap: u32, offset: u64, bytes: []const u8) !void {
    const frame = try a.alloc(u8, 12 + bytes.len);
    defer a.free(frame);
    std.mem.writeInt(u32, frame[0..4], snap, .big);
    std.mem.writeInt(u64, frame[4..12], offset, .big);
    @memcpy(frame[12..], bytes);
    try c.handle(Kind.snapshot, frame);
}
fn sendReady(c: *PaneStream, snap: u32, offset: u64, r: Vt.Ready) !void {
    const json = try std.fmt.allocPrint(a, "{{\"snap\":{d},\"offset\":{d},\"epoch\":{d},\"oldest\":{d},\"top\":{d},\"active\":{d},\"cols\":{d},\"rows\":{d}}}", .{ snap, offset, r.epoch, r.oldest, r.top, r.active, r.cols, r.rows });
    defer a.free(json);
    try c.handle(Kind.ready, json);
}
fn sendScrollback(c: *PaneStream, snap: u32, flags: u8, bytes: []const u8) !void {
    const frame = try a.alloc(u8, 21 + bytes.len);
    defer a.free(frame);
    @memset(frame[0..21], 0);
    std.mem.writeInt(u32, frame[0..4], snap, .big);
    frame[20] = flags;
    @memcpy(frame[21..], bytes);
    try c.handle(Kind.scrollback, frame);
}
fn sendResync(c: *PaneStream, snap: u32) !void {
    const json = try std.fmt.allocPrint(a, "{{\"reason\":\"requested\",\"snap\":{d},\"offset\":0}}", .{snap});
    defer a.free(json);
    try c.handle(Kind.resync, json);
}
/// All rows of `vt`, oldest first.
fn text(vt: Vt) ![]u8 {
    const r = vt.rows();
    return vt.exportRows(a, r.epoch, r.oldest, r.end);
}
fn expectSameText(x: Vt, y: Vt) !void {
    const left = try text(x);
    defer a.free(left);
    const right = try text(y);
    defer a.free(right);
    try expectEqualStrings(left, right);
}
/// Both Vts flag the same rows as OSC 133 prompt starts and continuations.
/// Rows are matched from the bottom, so a client holding only the screen
/// compares against the same rows of the source; `min_rows` of them at least.
fn expectSamePrompts(x: Vt, y: Vt, min_rows: u64) !void {
    const rx = x.rows();
    const ry = y.rows();
    const n = ry.end - ry.oldest;
    try expect(n >= min_rows and n <= rx.end - rx.oldest);
    var starts: usize = 0;
    for (0..n) |k| {
        const l = try x.rowPrompt(rx.epoch, rx.end - n + k);
        try expectEqual(l, try y.rowPrompt(ry.epoch, ry.oldest + k));
        if (l == .start) starts += 1;
    }
    try expect(starts > 0);
}
fn promptLines(pane: *Pane, lines: usize) !void {
    for (0..lines) |i| {
        var buf: [96]u8 = undefined;
        // Every 7th line is a prompt (A), every 21st a multi-line one (k=s).
        const mark: []const u8 = if (i % 21 == 0) "\x1b]133;A;k=s\x07" else if (i % 7 == 0) "\x1b]133;A\x07" else "";
        try pane.writeUnseen(try std.fmt.bufPrint(&buf, "{s}line {d:0>5} \xe7\x95\x8c\r\n", .{ mark, i }));
    }
}
fn expectShows(vt: Vt, needle: []const u8) !void {
    const all = try text(vt);
    defer a.free(all);
    try expect(std.mem.indexOf(u8, all, needle) != null);
}
fn clearOutbox(c: *PaneStream) void {
    for (c.outbox.items) |o| o.deinit(a);
    c.outbox.clearRetainingCapacity();
}
fn expectOut(c: *const PaneStream, i: usize, kind: u16, payload: []const u8) !void {
    try expectEqual(kind, c.outbox.items[i].kind);
    try expectEqualStrings(payload, c.outbox.items[i].payload);
}
/// A stream live on a ghostty snapshot of `pane`; `s` keeps its history.
fn liveGhostty(pane: *Pane, c: *PaneStream) !Vt.SnapshotStream {
    try c.attach(null);
    clearOutbox(c);
    try pane.attached(c, Vt.ghostty_format, true);
    return pane.snapshot(c, 1, 1024);
}
fn liveVt(pane: *Pane, c: *PaneStream) !void {
    try c.attach(null);
    clearOutbox(c);
    try pane.attached(c, Vt.vt_format, true);
    try pane.vtSnapshot(c, 1);
}

test "init refuses even stream IDs and empty viewports" {
    try std.testing.expectError(error.InvalidParams, PaneStream.init(a, "p0", 2, size, 0));
    try std.testing.expectError(error.InvalidParams, PaneStream.init(a, "p0", 1, .{ .cols = 0, .rows = 4 }, 0));
}

test "ATTACH says what the client can take" {
    var c = try PaneStream.init(a, "p3", 1, .{ .cols = 80, .rows = 24 }, 10000);
    defer c.deinit();
    try c.attach(null);
    const expected = "{\"pane\":\"p3\",\"mode\":\"emulate\",\"formats\":[\"" ++ Vt.ghostty_format ++ "\",\"vt\"],\"size\":{\"cols\":80,\"rows\":24},\"history\":10000,\"claim\":true}";
    try expectOut(&c, 0, Kind.attach, expected);
    try expectEqual(ps.Phase.attaching, c.phase);
}

test "ATTACH and RESYNC carry the host cell size" {
    var pane = try Pane.init(80, 24);
    defer pane.deinit();
    var c = try PaneStream.init(a, "p3", 1, .{ .cols = 80, .rows = 24 }, 0);
    defer c.deinit();
    // Unknown or half-known sizes are not sent.
    try c.setCell(.{ .width = 9, .height = 0 });
    try expectEqual(@as(?Vt.CellSize, null), c.cell);
    try c.setCell(.{ .width = 9, .height = 18 });
    try c.attach(null);
    try expectOut(&c, 0, Kind.attach, "{\"pane\":\"p3\",\"mode\":\"emulate\",\"formats\":[\"" ++ Vt.ghostty_format ++ "\",\"vt\"],\"size\":{\"cols\":80,\"rows\":24},\"history\":0,\"claim\":true,\"cell\":{\"width\":9,\"height\":18}}");
    clearOutbox(&c);
    try pane.attached(&c, Vt.ghostty_format, true);
    var s = try pane.snapshot(&c, 1, 1024);
    defer s.deinit(a);
    clearOutbox(&c);
    // The same size again sends nothing; a new one asks for a resync.
    try c.setCell(.{ .width = 9, .height = 18 });
    try expectEqual(@as(usize, 0), c.outbox.items.len);
    try c.setCell(.{ .width = 10, .height = 20 });
    try expectOut(&c, 0, Kind.resync, "{\"mode\":\"emulate\",\"formats\":[\"" ++ Vt.ghostty_format ++ "\",\"vt\"],\"history\":0,\"cell\":{\"width\":10,\"height\":20}}");
    try expectEqual(ps.ResyncCause.cell, c.last_resync.?);
}

test "snapshot: a ghostty snapshot paints at READY, then history arrives newest first" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.fill(5000);
    var c = try PaneStream.init(a, "p0", 1, size, 100_000);
    defer c.deinit();
    try c.attach(null);
    try pane.attached(&c, Vt.ghostty_format, true);
    try expectEqual(ps.Phase.snapshot, c.phase);
    try expectEqual(ps.Format.ghostty, c.format);
    // Chunk boundaries mean nothing: cut the prefix in small pieces.
    var s = try pane.snapshot(&c, 1, 97);
    defer s.deinit(a);
    try expectEqual(ps.Phase.live, c.phase);
    try expectEqual(pane.offset, c.offset);
    try expectEqual(ps.Size{ .cols = size.cols, .rows = size.rows }, c.pane_size);
    try expectEqual(s.ready.top, c.vt.?.rows().oldest);
    const first = c.pendingRows().?;
    try expectEqual(s.ready.oldest, first.low);
    try expectEqual(s.ready.top, first.high);
    try expect(first.high > first.low);

    var shrank = false;
    while (try s.nextHistory(4096)) |chunk| {
        const before = c.generation;
        try sendScrollback(&c, 1, if (chunk.last) last else 0, chunk.bytes);
        if (chunk.bytes.len != 0) try expect(c.generation != before);
        if (c.pendingRows()) |now| shrank = shrank or now.high < first.high;
    }
    try expect(shrank);
    try expectEqual(ps.Backfill.done, c.backfill);
    try expectEqual(@as(@TypeOf(c.pendingRows()), null), c.pendingRows());
    try expect(!c.vt.?.historyPending());
    try expectSameText(pane.vt, c.vt.?);
    try expectEqual(pane.vt.rows(), c.vt.?.rows());
}

test "snapshot: history is limited to what ATTACH asked for" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.fill(5000);
    var c = try PaneStream.init(a, "p0", 1, size, 10);
    defer c.deinit();
    var s = try liveGhostty(&pane, &c);
    defer s.deinit(a);
    try expectEqual(s.ready.top - 10, c.history_floor);
    try expect(c.history_wanted);
    // The server stops early with a plain LAST: nothing is lost.
    try sendScrollback(&c, 1, last, "");
    try expectEqual(ps.Backfill.done, c.backfill);
    try expect(!c.vt.?.historyPending());
}

test "snapshot: a vt snapshot paints and its single empty LAST finishes backfill" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.writeUnseen("\x1b[1mhello\x1b[0m");
    var c = try PaneStream.init(a, "p0", 1, size, 1000);
    defer c.deinit();
    try liveVt(&pane, &c);
    try expectEqual(ps.Format.vt, c.format);
    try expectEqual(pane.offset, c.offset);
    try expectShows(c.vt.?, "hello");
    try expectEqual(ps.Backfill.pending, c.backfill);
    try expect(!c.history_wanted);
    try sendScrollback(&c, 1, last, "");
    try expectEqual(ps.Backfill.done, c.backfill);
}

test "snapshot: READY for a snapshot with no chunk still numbers it" {
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try c.attach(null);
    try c.handle(Kind.attached, "{\"source\":\"venomx/x\",\"format\":\"vt\",\"input\":true}");
    try sendReady(&c, 1, 0, .{ .epoch = 0, .oldest = 0, .top = 0, .active = 0, .cols = 10, .rows = 3 });
    try expectEqual(ps.Phase.live, c.phase);
    try expectEqual(@as(u32, 1), c.snap);
}

test "snapshot: frames out of order are BadFrame" {
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try c.attach(null);
    const bad = std.testing.expectError;
    try bad(error.BadFrame, sendSnapshot(&c, 1, 0, "x"));
    try bad(error.BadFrame, c.handle(Kind.ready, "{\"snap\":1}"));
    try bad(error.BadFrame, sendResync(&c, 1));
    try bad(error.BadFrame, c.handle(0x1ff, ""));
    try bad(error.BadFrame, c.handle(Kind.pty, "short"));
    try bad(error.BadFrame, c.handle(Kind.scrollback, "short"));
    try bad(error.BadFrame, c.handle(Kind.attached, "{\"source\":\"venomx/x\"}"));
    try bad(error.BadFrame, c.handle(Kind.attached, "{\"source\":\"venomx/x\",\"format\":\"ghostty/0@000000000000\"}"));
    try c.handle(Kind.attached, "{\"source\":\"venomx/x\",\"format\":\"vt\"}");
    try bad(error.BadFrame, c.handle(Kind.attached, "{\"source\":\"venomx/x\",\"format\":\"vt\"}"));
    try sendSnapshot(&c, 2, 0, "x");
    // An older number than the one in progress, in a chunk and in READY.
    try bad(error.BadFrame, sendSnapshot(&c, 1, 0, "x"));
    try bad(error.BadFrame, sendReady(&c, 1, 0, .{ .epoch = 0, .oldest = 0, .top = 0, .active = 0, .cols = 10, .rows = 3 }));
    // A snap that doesn't fit the frame header's u32 can't be a real number.
    var fresh = try PaneStream.init(a, "p0", 3, size, 0);
    defer fresh.deinit();
    try fresh.attach(null);
    try fresh.handle(Kind.attached, "{\"source\":\"venomx/x\",\"format\":\"vt\"}");
    try bad(error.BadFrame, fresh.handle(Kind.ready, "{\"snap\":4294967296,\"epoch\":0,\"oldest\":0,\"top\":0,\"active\":0,\"cols\":10,\"rows\":3,\"offset\":0}"));
}

test "snapshot: an undecodable snapshot keeps the screen and asks again" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.writeUnseen("first");
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    var s = try liveGhostty(&pane, &c);
    defer s.deinit(a);
    clearOutbox(&c);
    try sendResync(&c, 2);
    // The prefix is whole, but READY describes a different terminal.
    var again = try pane.vt.streamSnapshot(a);
    defer again.deinit(a);
    try sendSnapshot(&c, 2, pane.offset, again.prefix);
    var wrong = again.ready;
    wrong.cols += 1;
    try sendReady(&c, 2, pane.offset, wrong);
    try expectShows(c.vt.?, "first");
    try expect(c.discarding);
    try expectEqual(ps.ResyncCause.decode, c.last_resync.?);
    try expectEqual(Kind.resync, c.outbox.items[0].kind);
}

test "raw fan-out: every client applies the same bytes, however the frames split them" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.writeUnseen("before\r\n");
    var ghostty = try PaneStream.init(a, "p0", 1, size, 0);
    defer ghostty.deinit();
    var s = try liveGhostty(&pane, &ghostty);
    defer s.deinit(a);
    // A second client with another viewport and format, on another stream.
    var vt_client = try PaneStream.init(a, "p0", 3, .{ .cols = 12, .rows = 2 }, 0);
    defer vt_client.deinit();
    try liveVt(&pane, &vt_client);
    const clients = [_]*PaneStream{ &ghostty, &vt_client };

    // Frame boundaries are arbitrary: inside an escape sequence and
    // inside a UTF-8 character.
    const bytes = "\x1b[31mred\x1b[0m \xe7\x95\x8c done\r\n";
    try pane.write(bytes[0..3], &clients);
    try pane.write(bytes[3..14], &clients);
    try pane.write(bytes[14..], &clients);

    for (clients) |c| {
        try expectEqual(pane.offset, c.offset);
        try expectEqual(@as(u32, 0), c.resyncs);
        try expectEqual(@as(usize, 0), c.outbox.items.len);
        try expectSameText(pane.vt, c.vt.?);
        // The emulator follows the pane's size, not the viewport.
        try expectEqual(pane.vt.size(), c.vt.?.size());
    }
    const cell = try ghostty.vt.?.readCell(a, ghostty.vt.?.rows().epoch, ghostty.vt.?.rows().active + 1, 0);
    defer a.free(cell.text);
    try expectEqualStrings("r", cell.text);
}

test "raw fan-out: PTY before READY isn't applied and a client's Vt never answers" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try c.attach(null);
    try pane.attached(&c, Vt.vt_format, true);
    clearOutbox(&c);
    try pane.write("too early", &.{&c});
    try expect(c.vt == null);
    try pane.vtSnapshot(&c, 1);
    // DA1 and DSR: the server's Vt answered them; no INPUT here.
    try pane.write("\x1b[c\x1b[6n", &.{&c});
    try expectEqual(@as(usize, 0), c.outbox.items.len);
}

test "resync: a gap resyncs only that stream and keeps its screen until READY" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.writeUnseen("start\r\n");
    var lagging = try PaneStream.init(a, "p0", 1, size, 500);
    defer lagging.deinit();
    var s1 = try liveGhostty(&pane, &lagging);
    defer s1.deinit(a);
    var healthy = try PaneStream.init(a, "p0", 3, size, 0);
    defer healthy.deinit();
    try liveVt(&pane, &healthy);

    try pane.write("seen\r\n", &.{ &lagging, &healthy });
    try pane.writeUnseen("lost\r\n");
    // The lost bytes reach only the healthy client.
    try sendPty(&healthy, pane.offset - 6, "lost\r\n");
    try pane.write("after\r\n", &.{ &lagging, &healthy });

    try expect(lagging.discarding);
    try expectEqual(ps.ResyncCause.gap, lagging.last_resync.?);
    try expectEqual(@as(u32, 1), lagging.resyncs);
    try expectOut(&lagging, 0, Kind.resync, "{\"mode\":\"emulate\",\"formats\":[\"" ++ Vt.ghostty_format ++ "\",\"vt\"],\"history\":500}");
    try expectEqual(@as(u32, 0), healthy.resyncs);
    try expectSameText(pane.vt, healthy.vt.?);

    // While a resync is out, nothing else asks and PTY stays discarded.
    const applied = lagging.offset;
    try pane.write("more\r\n", &.{ &lagging, &healthy });
    try expectEqual(@as(usize, 1), lagging.outbox.items.len);
    try expectEqual(applied, lagging.offset);

    // The old screen stays up through RESYNC and SNAPSHOT.
    try sendResync(&lagging, 2);
    try expect(!lagging.discarding);
    try expectEqual(ps.Phase.snapshot, lagging.phase);
    try expectShows(lagging.vt.?, "seen");
    var s2 = try pane.vt.streamSnapshot(a);
    defer s2.deinit(a);
    try sendSnapshot(&lagging, 2, pane.offset, s2.prefix);
    try expectShows(lagging.vt.?, "seen");
    try sendReady(&lagging, 2, pane.offset, s2.ready);

    // READY replaces the emulator; the next PTY starts at READY.offset.
    try expectEqual(ps.Phase.live, lagging.phase);
    try expectEqual(pane.offset, lagging.offset);
    try expectShows(lagging.vt.?, "lost");
    try pane.write("caught up", &.{ &lagging, &healthy });
    try expectShows(lagging.vt.?, "caught up");
    try expectEqual(@as(u32, 1), lagging.resyncs);
}

test "resync: frames of an earlier snapshot in flight are dropped while waiting" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try liveVt(&pane, &c);
    try sendPty(&c, pane.offset + 5, "gap");
    try expect(c.discarding);
    try sendSnapshot(&c, 1, 0, "stale");
    try sendReady(&c, 1, 0, .{ .epoch = 0, .oldest = 0, .top = 0, .active = 0, .cols = 10, .rows = 3 });
    try expect(c.discarding);
    try expectEqual(pane.vt.size(), c.vt.?.size());
}

test "resync: an overlap resyncs too" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.writeUnseen("abc");
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try liveVt(&pane, &c);
    try sendPty(&c, pane.offset - 1, "c");
    try expect(c.discarding);
    try expectEqual(pane.offset, c.offset);
}

test "resync: an overflow from the server abandons old backfill, and late chunks are ignored" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.fill(5000);
    var c = try PaneStream.init(a, "p0", 1, size, 100_000);
    defer c.deinit();
    var s1 = try liveGhostty(&pane, &c);
    defer s1.deinit(a);
    const chunk = (try s1.nextHistory(4096)).?;
    try sendScrollback(&c, 1, 0, chunk.bytes);
    try c.handle(Kind.resync, "{\"reason\":\"overflow\",\"snap\":2,\"offset\":1}");
    try expect(!c.vt.?.historyPending());
    try expectEqual(ps.Backfill.none, c.backfill);
    const next = (try s1.nextHistory(4096)).?;
    try sendScrollback(&c, 1, 0, next.bytes);
    try expect(!c.vt.?.historyPending());
    try expectEqual(@as(usize, 0), c.outbox.items.len);
    var s2 = try pane.snapshot(&c, 2, 1024);
    defer s2.deinit(a);
    try expectEqual(ps.Phase.live, c.phase);
    try expectEqual(ps.Backfill.pending, c.backfill);
}

test "resync: S→C RESYNC can renumber below ours after a resume, and revoke the writer role" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try liveVt(&pane, &c);
    try sendResync(&c, 2);
    try pane.vtSnapshot(&c, 2);
    try sendResync(&c, 3);
    try pane.vtSnapshot(&c, 3);
    try expectEqual(@as(u32, 3), c.snap);
    try c.reattach(5);
    try c.handle(Kind.attached, "{\"source\":\"venomx/test\",\"format\":\"vt\",\"resumed\":true,\"offset\":0,\"input\":true}");
    try expectEqual(ps.Phase.live, c.phase);
    // The server's numbering restarted with the resume: its next is 1.
    try c.handle(Kind.resync, "{\"reason\":\"requested\",\"snap\":1,\"offset\":0,\"input\":false}");
    try pane.vtSnapshot(&c, 1);
    try expectEqual(ps.Phase.live, c.phase);
    try expectEqual(@as(u32, 1), c.snap);
    try expect(!c.writer);
    try c.input("no");
    try expectEqual(@as(usize, 1), c.outbox.items.len);
    try std.testing.expectError(error.BadFrame, c.handle(Kind.resync, "{\"snap\":0}"));
}

test "resume: reattach asks for the applied offset, and an unfinished backfill is lost" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.fill(5000);
    var c = try PaneStream.init(a, "p0", 1, size, 100_000);
    defer c.deinit();
    var s = try liveGhostty(&pane, &c);
    defer s.deinit(a);
    try c.input("stale");
    try c.reattach(3);
    try expectEqual(@as(u32, 3), c.id);
    try expectEqual(@as(usize, 1), c.outbox.items.len);
    try expect(std.mem.indexOf(u8, c.outbox.items[0].payload, "\"resume\":{\"source\":\"venomx/test\",\"offset\":") != null);
    try std.testing.expectError(error.BadFrame, c.handle(Kind.attached, "{\"source\":\"venomx/test\",\"format\":\"ghostty/1@0\",\"resumed\":true,\"offset\":0}"));
    const json = try std.fmt.allocPrint(a, "{{\"source\":\"venomx/test\",\"format\":\"{s}\",\"resumed\":true,\"offset\":{d},\"input\":true}}", .{ Vt.ghostty_format, pane.offset });
    defer a.free(json);
    try c.handle(Kind.attached, json);
    try expectEqual(ps.Phase.live, c.phase);
    try expectEqual(ps.Backfill.aborted, c.backfill);
    try expect(!c.vt.?.historyPending());
    try pane.write("resumed", &.{&c});
    try expectShows(c.vt.?, "resumed");
}

test "resume: a wrong offset is BadFrame; a refused resume takes a snapshot" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.writeUnseen("abc");
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try liveVt(&pane, &c);
    try c.reattach(3);
    try std.testing.expectError(error.BadFrame, c.handle(Kind.attached, "{\"source\":\"venomx/test\",\"format\":\"vt\",\"resumed\":true,\"offset\":1}"));
    try pane.attached(&c, Vt.vt_format, true);
    try expectEqual(ps.Phase.snapshot, c.phase);
    try pane.vtSnapshot(&c, 1);
    try expectEqual(ps.Phase.live, c.phase);
    try expectShows(c.vt.?, "abc");
}

test "resume: reattach before a snapshot arrived doesn't ask to resume" {
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try c.attach(null);
    try c.reattach(3);
    try expect(std.mem.indexOf(u8, c.outbox.items[0].payload, "resume") == null);
}

test "backfill recovery: waits until nothing changes, and doesn't claim the pane's size" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.fill(5000);
    var c = try PaneStream.init(a, "p0", 1, size, 100_000);
    defer c.deinit();
    var s = try liveGhostty(&pane, &c);
    defer s.deinit(a);
    try c.recoverBackfill(0);
    try expectEqual(@as(?i64, null), c.recoveryDeadline());
    try sendScrollback(&c, 1, last | aborted, "");
    try expectEqual(ps.Backfill.aborted, c.backfill);
    try expectEqual(@as(?i64, null), c.recoveryDeadline());
    clearOutbox(&c);
    try c.recoverBackfill(1000);
    try expectEqual(@as(?i64, 1000 + ps.backfill_settle_ms), c.recoveryDeadline());
    // A new size restarts the wait.
    try pane.resize(50, 6, &c);
    try c.recoverBackfill(1100);
    try expectEqual(@as(?i64, 1100 + ps.backfill_settle_ms), c.recoveryDeadline());
    try c.recoverBackfill(1100 + ps.backfill_settle_ms - 1);
    try expectEqual(@as(usize, 0), c.outbox.items.len);
    try c.recoverBackfill(1100 + ps.backfill_settle_ms);
    try expectEqual(ps.ResyncCause.backfill, c.last_resync.?);
    try expect(c.recovering);
    try expect(std.mem.indexOf(u8, c.outbox.items[0].payload, "\"claim\":false") != null);
    // One RESYNC only, then READY ends the recovery.
    try c.recoverBackfill(2000);
    try expectEqual(@as(u32, 1), c.resyncs);
    try sendResync(&c, 2);
    var s2 = try pane.snapshot(&c, 2, 1024);
    defer s2.deinit(a);
    try expect(!c.recovering);
    try expectEqual(ps.Backfill.pending, c.backfill);
}

test "backfill recovery: a local epoch change stops backfill, and the abort after it changes nothing" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.fill(5000);
    var c = try PaneStream.init(a, "p0", 1, size, 100_000);
    defer c.deinit();
    var s = try liveGhostty(&pane, &c);
    defer s.deinit(a);
    const chunk = (try s.nextHistory(4096)).?;
    try pane.resize(30, 4, &c);
    try sendScrollback(&c, 1, 0, chunk.bytes);
    try expectEqual(ps.Backfill.aborted, c.backfill);
    try expect(!c.vt.?.historyPending());
    try sendScrollback(&c, 1, last | aborted, "");
    try expectEqual(ps.Backfill.aborted, c.backfill);
}

test "backfill recovery: never for a stream with no history to lose" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.fill(5000);
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    var s = try liveGhostty(&pane, &c);
    defer s.deinit(a);
    clearOutbox(&c);
    try sendScrollback(&c, 1, last | aborted, "");
    try c.recoverBackfill(0);
    try c.recoverBackfill(10_000);
    try expectEqual(@as(usize, 0), c.outbox.items.len);
    try expectEqual(@as(?i64, null), c.recoveryDeadline());
}

test "backfill recovery: waits until the alternate screen is left" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.fill(5000);
    var c = try PaneStream.init(a, "p0", 1, size, 100_000);
    defer c.deinit();
    var s = try liveGhostty(&pane, &c);
    defer s.deinit(a);
    clearOutbox(&c);
    try sendScrollback(&c, 1, last | aborted, "");
    try pane.write("\x1b[?1049h", &.{&c});
    try c.recoverBackfill(0);
    try c.recoverBackfill(10_000);
    try expectEqual(@as(usize, 0), c.outbox.items.len);
    try pane.write("\x1b[?1049l", &.{&c});
    try c.recoverBackfill(20_000);
    try c.recoverBackfill(20_000 + ps.backfill_settle_ms);
    try expectEqual(ps.ResyncCause.backfill, c.last_resync.?);
}

test "resize: applied at its offset; a mismatch resyncs instead" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try liveVt(&pane, &c);
    try pane.write("abc", &.{&c});
    try pane.resize(60, 8, &c);
    try expectEqual(ps.Size{ .cols = 60, .rows = 8 }, c.pane_size);
    try expectEqual(pane.vt.size(), c.vt.?.size());
    try expect(c.discarding == false);
    try c.handle(Kind.resize, "{\"offset\":1,\"cols\":70,\"rows\":8}");
    try expectEqual(ps.ResyncCause.resize_offset, c.last_resync.?);
    try std.testing.expectEqual(pane.vt.size(), c.vt.?.size());
    // While a resync is out only the size is recorded.
    try c.handle(Kind.resize, "{\"offset\":99,\"cols\":70,\"rows\":9}");
    try expectEqual(ps.Size{ .cols = 70, .rows = 9 }, c.pane_size);
    try std.testing.expectError(error.BadFrame, c.handle(Kind.resize, "{\"cols\":0,\"rows\":9}"));
}

test "roles: only a writer sends INPUT and reports its viewport" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    var watcher = try PaneStream.init(a, "p0", 1, size, 0);
    defer watcher.deinit();
    try watcher.attach(null);
    clearOutbox(&watcher);
    try pane.attached(&watcher, Vt.vt_format, false);
    try pane.vtSnapshot(&watcher, 1);
    try watcher.input("x");
    try watcher.viewport(.{ .cols = 99, .rows = 9 });
    try expectEqual(@as(usize, 0), watcher.outbox.items.len);

    var writer = try PaneStream.init(a, "p0", 3, size, 0);
    defer writer.deinit();
    try writer.attach(null);
    clearOutbox(&writer);
    // Before ATTACHED nothing goes out, but a changed viewport is reported then.
    try writer.input("early");
    try writer.viewport(.{ .cols = 50, .rows = 5 });
    try expectEqual(@as(usize, 0), writer.outbox.items.len);
    try pane.attached(&writer, Vt.vt_format, true);
    try expectOut(&writer, 0, Kind.resize, "{\"cols\":50,\"rows\":5}");
    clearOutbox(&writer);
    try writer.viewport(.{ .cols = 50, .rows = 5 });
    try writer.viewport(.{ .cols = 0, .rows = 5 });
    try writer.input("");
    try expectEqual(@as(usize, 0), writer.outbox.items.len);
    try writer.input("ls\r");
    try expectOut(&writer, 0, Kind.input, "ls\r");
    try expectEqual(ps.Size{ .cols = 50, .rows = 5 }, writer.size);
}

test "end of stream: EXIT leaves it open, CLOSE and ERROR end it" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try liveVt(&pane, &c);
    try c.handle(Kind.exit, "{\"offset\":0,\"signal\":\"SIGKILL\"}");
    try expectEqualStrings("SIGKILL", c.exit.?.signal);
    try c.handle(Kind.exit, "{\"offset\":0,\"exit_code\":3}");
    try expectEqual(@as(u8, 3), c.exit.?.code);
    try expectEqual(ps.Phase.live, c.phase);
    try std.testing.expectError(error.BadFrame, c.handle(Kind.exit, "{\"exit_code\":300}"));
    try c.handle(Kind.close, "{\"reason\":\"pane_removed\"}");
    try expectEqual(ps.Phase.closed, c.phase);
    try expectEqualStrings("pane_removed", c.closed.?);
    // Nothing happens to a closed stream, not even for a bad frame.
    try c.handle(0x1ff, "");
    try c.input("x");
    try c.detach();
    try expectEqual(@as(usize, 0), c.outbox.items.len);

    var refused = try PaneStream.init(a, "p9", 3, size, 0);
    defer refused.deinit();
    try refused.attach(null);
    try refused.handle(Kind.err, "{\"code\":\"not_found.pane\"}");
    try expectEqualStrings("not_found.pane", refused.closed.?);

    var unreadable = try PaneStream.init(a, "p9", 5, size, 0);
    defer unreadable.deinit();
    try unreadable.handle(Kind.err, "not json");
    try expectEqualStrings("error", unreadable.closed.?);
}

test "detach queues CLOSE and closes locally" {
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try c.attach(null);
    clearOutbox(&c);
    try c.detach();
    try expectOut(&c, 0, Kind.close, "{}");
    try expectEqualStrings("detached", c.closed.?);
}

test "flush: a failing send leaves the unsent frames owned once" {
    var s = try PaneStream.init(a, "p1", 3, size, 0);
    defer s.deinit();
    try s.attach(null);
    try s.detach();
    try expectEqual(@as(usize, 2), s.outbox.items.len);
    const Sink = struct {
        sent: usize = 0,
        fail_at: usize,
        fn send(self: *@This(), id: u32, o: ps.Out) anyerror!void {
            try expectEqual(@as(u32, 3), id);
            if (self.sent == self.fail_at) return error.SlowReader;
            _ = o;
            self.sent += 1;
        }
    };
    // The first frame goes out, the second fails: only the second stays.
    var sink: Sink = .{ .fail_at = 1 };
    try std.testing.expectError(error.SlowReader, s.flush(&sink, Sink.send));
    try expectEqual(@as(usize, 1), s.outbox.items.len);
    try expectEqual(@as(u16, Kind.close), s.outbox.items[0].kind);
    // A retry sends the rest; nothing is freed twice or leaked (deinit).
    var ok: Sink = .{ .fail_at = 99 };
    try s.flush(&ok, Sink.send);
    try expectEqual(@as(usize, 1), ok.sent);
    try expectEqual(@as(usize, 0), s.outbox.items.len);
}

/// A host for a raw stream: what the terminal would have been sent.
const Host = struct {
    begins: usize = 0,
    bytes: std.ArrayList(u8) = .empty,
    clipboard: bool = false,
    fail: bool = false,

    fn passthrough(self: *Host) ps.Passthrough {
        return .{ .ctx = self, .begin = begin, .feed = feed };
    }
    fn begin(ctx: *anyopaque) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.begins += 1;
        self.bytes.clearRetainingCapacity();
    }
    fn feed(ctx: *anyopaque, bytes: []const u8, clipboard: bool) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.HostGone;
        self.clipboard = clipboard;
        try self.bytes.appendSlice(a, bytes);
    }
};
fn rawAttach(c: *PaneStream, host: *Host) !void {
    c.mode = .raw;
    c.formats = &.{.vt};
    c.passthrough = host.passthrough();
    try c.attach(null);
}

test "raw passthrough: replay and live bytes go to the host, with no Vt" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.writeUnseen("hello");
    var host: Host = .{};
    defer host.bytes.deinit(a);
    var c = try PaneStream.init(a, "p0", 1, size, 100);
    defer c.deinit();
    try rawAttach(&c, &host);
    try expectOut(&c, 0, Kind.attach, "{\"pane\":\"p0\",\"mode\":\"raw\",\"formats\":[\"vt\"],\"size\":{\"cols\":40,\"rows\":4},\"history\":100,\"claim\":true}");
    try pane.attached(&c, Vt.vt_format, true);
    try pane.vtSnapshot(&c, 1);
    try expectEqual(@as(usize, 1), host.begins);
    try expect(std.mem.indexOf(u8, host.bytes.items, "hello") != null);
    host.bytes.clearRetainingCapacity();
    try pane.write("\x1b[31mlive", &.{&c});
    try expectEqualStrings("\x1b[31mlive", host.bytes.items);
    try expect(c.vt == null);
    // A raw stream's only SCROLLBACK is the empty LAST.
    try std.testing.expectError(error.BadFrame, sendScrollback(&c, 1, 0, "x"));
    try sendScrollback(&c, 1, last, "");
    try expectEqual(ps.Backfill.done, c.backfill);
    // A resume keeps the host's screen: no second `begin`.
    try c.reattach(3);
    try expect(std.mem.indexOf(u8, c.outbox.items[c.outbox.items.len - 1].payload, "\"resume\"") != null);
    const json = try std.fmt.allocPrint(a, "{{\"source\":\"venomx/test\",\"mode\":\"raw\",\"format\":\"vt\",\"resumed\":true,\"offset\":{d},\"input\":true}}", .{pane.offset});
    defer a.free(json);
    try c.handle(Kind.attached, json);
    try expectEqual(ps.Phase.live, c.phase);
    try expectEqual(@as(usize, 1), host.begins);
    // A failing host surfaces to the caller, with the bytes not applied.
    host.fail = true;
    const before = c.offset;
    try std.testing.expectError(error.HostGone, pane.write("x", &.{&c}));
    try expectEqual(before, c.offset);
}

test "raw passthrough: format and mode must match, and a raw stream needs a host" {
    var host: Host = .{};
    defer host.bytes.deinit(a);
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try rawAttach(&c, &host);
    try std.testing.expectError(error.BadFrame, c.handle(Kind.attached, "{\"source\":\"venomx/x\",\"mode\":\"emulate\",\"format\":\"vt\"}"));
    try std.testing.expectError(error.BadFrame, c.handle(Kind.attached, "{\"source\":\"venomx/x\",\"mode\":\"raw\",\"format\":\"" ++ Vt.ghostty_format ++ "\"}"));
    c.passthrough = null;
    try c.handle(Kind.attached, "{\"source\":\"venomx/x\",\"mode\":\"raw\",\"format\":\"vt\",\"input\":true}");
    try std.testing.expectError(error.NoPassthrough, sendReady(&c, 1, 0, .{ .epoch = 0, .oldest = 0, .top = 0, .active = 0, .cols = size.cols, .rows = size.rows }));
}

test "raw passthrough: the clipboard follows the writer role and the server's policy" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    var host: Host = .{};
    defer host.bytes.deinit(a);
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try rawAttach(&c, &host);
    try c.handle(Kind.attached, "{\"source\":\"venomx/x\",\"mode\":\"raw\",\"format\":\"vt\",\"input\":true,\"raw_clipboard\":\"external\"}");
    try pane.vtSnapshot(&c, 1);
    try pane.write("a", &.{&c});
    try expect(host.clipboard);
    try c.handle(Kind.resync, "{\"snap\":2,\"input\":true,\"raw_clipboard\":\"off\"}");
    try pane.vtSnapshot(&c, 2);
    try pane.write("b", &.{&c});
    try expect(!host.clipboard);
    try c.handle(Kind.resync, "{\"snap\":3,\"input\":true,\"raw_clipboard\":\"external\"}");
    try pane.vtSnapshot(&c, 3);
    try pane.write("c", &.{&c});
    try expect(host.clipboard);
    // Losing the write grant ends it, whatever the policy says.
    try c.handle(Kind.resync, "{\"snap\":4,\"input\":false}");
    try pane.vtSnapshot(&c, 4);
    try pane.write("d", &.{&c});
    try expect(!host.clipboard);
}

test "raw passthrough: a size mismatch falls back to emulating on a vt snapshot" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.writeUnseen("hello");
    var host: Host = .{};
    defer host.bytes.deinit(a);
    var c = try PaneStream.init(a, "p0", 1, size, 0);
    defer c.deinit();
    try rawAttach(&c, &host);
    clearOutbox(&c);
    try pane.attached(&c, Vt.vt_format, true);
    try pane.vtSnapshot(&c, 1);
    host.bytes.clearRetainingCapacity();

    // The viewport leaves the pane's size: stop writing to the host.
    try c.viewport(.{ .cols = 30, .rows = 4 });
    try expectEqual(ps.Mode.emulate, c.mode);
    try expectEqual(ps.ResyncCause.size, c.last_resync.?);
    try expectOut(&c, 0, Kind.resize, "{\"cols\":30,\"rows\":4}");
    try expectOut(&c, 1, Kind.resync, "{\"mode\":\"emulate\",\"formats\":[\"vt\"],\"history\":0}");
    try pane.write(" world", &.{&c});
    try expectEqual(@as(usize, 0), host.bytes.items.len);
    try sendResync(&c, 2);
    try pane.vtSnapshot(&c, 2);
    try expectEqual(ps.Format.vt, c.format);
    try expectShows(c.vt.?, "hello world");
    try expectEqual(@as(usize, 0), host.bytes.items.len);
}

test "raw passthrough: a mismatch at READY falls back before any host byte" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    var host: Host = .{};
    defer host.bytes.deinit(a);
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 80, .rows = 24 }, 0);
    defer c.deinit();
    try rawAttach(&c, &host);
    try pane.attached(&c, Vt.vt_format, true);
    try pane.vtSnapshot(&c, 1);
    try expectEqual(ps.Mode.emulate, c.mode);
    try expect(c.discarding);
    try expectEqual(@as(usize, 0), host.begins);
    try expectEqual(@as(usize, 0), host.bytes.items.len);
}

/// Feed every remaining history chunk of `s` to `c` and finish with LAST.
fn drainHistory(c: *PaneStream, snap: u32, s: *Vt.SnapshotStream) !void {
    while (try s.nextHistory(4096)) |chunk| try sendScrollback(c, snap, 0, chunk.bytes);
    try sendScrollback(c, snap, last, "");
}

test "backfill recovery: a snapshot taken on the alternate screen asks once for history after leaving it" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.fill(5000);
    try pane.writeUnseen("\x1b[?1049h");
    var c = try PaneStream.init(a, "p0", 1, size, 100_000);
    defer c.deinit();
    var s = try liveGhostty(&pane, &c);
    defer s.deinit(a);
    try expectEqual(Vt.Screen.alternate, c.vt.?.screen());
    // The server has no primary rows to send; the backfill just ends.
    try sendScrollback(&c, 1, last, "");
    clearOutbox(&c);
    try c.recoverBackfill(0);
    try c.recoverBackfill(10_000);
    try expectEqual(@as(usize, 0), c.outbox.items.len);
    try expectEqual(@as(?i64, null), c.recoveryDeadline());
    try pane.write("\x1b[?1049l", &.{&c});
    try c.recoverBackfill(20_000);
    try expectEqual(@as(?i64, 20_000 + ps.backfill_settle_ms), c.recoveryDeadline());
    try c.recoverBackfill(20_000 + ps.backfill_settle_ms);
    try expectEqual(@as(u32, 1), c.resyncs);
    try expectEqual(ps.ResyncCause.backfill, c.last_resync.?);
    // No second RESYNC while the first is out.
    try c.recoverBackfill(30_000);
    try c.recoverBackfill(40_000);
    try expectEqual(@as(u32, 1), c.resyncs);
    try expectEqual(@as(usize, 1), c.outbox.items.len);
    try sendResync(&c, 2);
    var s2 = try pane.snapshot(&c, 2, 1024);
    defer s2.deinit(a);
    try drainHistory(&c, 2, &s2);
    try expectEqual(ps.Backfill.done, c.backfill);
    try expectSameText(c.vt.?, pane.vt);
    // History is whole: nothing more to ask for.
    try c.recoverBackfill(50_000);
    try c.recoverBackfill(60_000);
    try expectEqual(@as(u32, 1), c.resyncs);
}

test "backfill recovery: a recovery snapshot taken on the alternate screen recovers again after leaving it" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try pane.fill(5000);
    var c = try PaneStream.init(a, "p0", 1, size, 100_000);
    defer c.deinit();
    var s = try liveGhostty(&pane, &c);
    defer s.deinit(a);
    try sendScrollback(&c, 1, last | aborted, "");
    clearOutbox(&c);
    try c.recoverBackfill(0);
    try c.recoverBackfill(ps.backfill_settle_ms);
    try expectEqual(@as(u32, 1), c.resyncs);
    // The program enters the alternate screen while the RESYNC is in flight:
    // its PTY is discarded and the snapshot that answers is taken there.
    try pane.write("\x1b[?1049h", &.{&c});
    try sendResync(&c, 2);
    var s2 = try pane.snapshot(&c, 2, 1024);
    defer s2.deinit(a);
    try sendScrollback(&c, 2, last, "");
    try expect(!c.recovering);
    try c.recoverBackfill(10_000);
    try c.recoverBackfill(20_000);
    try expectEqual(@as(u32, 1), c.resyncs);
    try pane.write("\x1b[?1049l", &.{&c});
    try c.recoverBackfill(30_000);
    try c.recoverBackfill(30_000 + ps.backfill_settle_ms);
    try expectEqual(@as(u32, 2), c.resyncs);
    try sendResync(&c, 3);
    var s3 = try pane.snapshot(&c, 3, 1024);
    defer s3.deinit(a);
    try drainHistory(&c, 3, &s3);
    try expectSameText(c.vt.?, pane.vt);
}

test "prompt rows: a ghostty snapshot plus history replay flags the same rows" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try promptLines(&pane, 3000);
    var c = try PaneStream.init(a, "p0", 1, size, 100_000);
    defer c.deinit();
    try c.attach(null);
    try pane.attached(&c, Vt.ghostty_format, true);
    var s = try pane.snapshot(&c, 1, 97);
    defer s.deinit(a);
    while (try s.nextHistory(4096)) |chunk| try sendScrollback(&c, 1, if (chunk.last) last else 0, chunk.bytes);
    try expectEqual(ps.Backfill.done, c.backfill);
    try expectEqual(pane.vt.rows(), c.vt.?.rows());
    try expectSamePrompts(pane.vt, c.vt.?, 3000);
}

test "prompt rows: a vt snapshot keeps the flag on the same rows" {
    var pane = try Pane.init(size.cols, size.rows);
    defer pane.deinit();
    try promptLines(&pane, 60);
    try pane.writeUnseen("\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x07out\r\n\x1b]133;A\x07$ ");
    var c = try PaneStream.init(a, "p0", 1, size, 1000);
    defer c.deinit();
    try liveVt(&pane, &c);
    // The vt snapshot carries the screen; history is not part of it here.
    try expectSamePrompts(pane.vt, c.vt.?, 4);
}
