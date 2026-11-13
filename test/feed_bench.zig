//! Headless feed benchmark. No PTY, socket, renderer or product callbacks.
const std = @import("std");
const Vt = @import("vt").Vt;
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cols = if (args.len > 1) try std.fmt.parseInt(u16, args[1], 10) else 100;
    const count = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 1048576;
    const rows = if (args.len > 4) try std.fmt.parseInt(u16, args[4], 10) else 30;
    var vt = try Vt.init(init.gpa, .{ .cols = cols, .rows = rows });
    defer vt.deinit();
    const data = try init.gpa.alloc(u8, count);
    defer init.gpa.free(data);
    // Pattern (arg 6): `crlf` (default) writes 79 'x' + CRLF lines; `yes`
    // writes `yes FLOOD` output (6-byte LF-only lines; see docs/debug-feed-throughput.md).
    const pattern = if (args.len > 6) args[6] else "crlf";
    if (std.mem.eql(u8, pattern, "yes")) {
        for (data, 0..) |*b, i| b.* = "FLOOD\n"[i % 6];
    } else if (std.mem.eql(u8, pattern, "crlf")) {
        for (data, 0..) |*b, i| b.* = switch (i % 81) {
            79 => '\r',
            80 => '\n',
            else => 'x',
        };
    } else return error.InvalidPattern;
    const metadata = if (args.len > 3) args[3] else "none";
    const start = std.Io.Timestamp.now(init.io, .awake);
    const repeats = if (args.len > 5) try std.fmt.parseInt(usize, args[5], 10) else 1;
    for (0..repeats) |_| {
        var at: usize = 0;
        while (at < data.len) {
            const n = @min(16384, data.len - at);
            try vt.feed(data[at..][0..n]);
            if (std.mem.eql(u8, metadata, "snapshot")) {
                const replay = try vt.vtSnapshot(init.gpa, .{ .history = 0 });
                replay.deinit(init.gpa);
            } else if (std.mem.eql(u8, metadata, "title")) {
                std.mem.doNotOptimizeAway(try vt.title());
            }
            at += n;
        }
    }
    const ns = start.durationTo(std.Io.Timestamp.now(init.io, .awake)).toNanoseconds();
    std.debug.print("cols={d} bytes={d} metadata={s} pattern={s} feed_ns={d}\n", .{ cols, count * repeats, metadata, pattern, ns });
}
