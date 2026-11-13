const std = @import("std");
const term = @import("venom-term");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const count: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 1;
    const width: u16 = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 80;
    const height: u16 = if (args.len > 3) try std.fmt.parseInt(u16, args[3], 10) else 24;
    const panes = try init.gpa.alloc(term.Vt, count);
    defer init.gpa.free(panes);
    var n: usize = 0;
    defer for (panes[0..n]) |*pane| pane.deinit();
    for (panes) |*pane| {
        pane.* = try term.Vt.init(init.gpa, .{ .cols = width, .rows = height });
        n += 1;
        try pane.feed("\x1b[31mhello 界 e\xcc\x81\x1b[0m");
    }
    var out: std.Io.Writer.Allocating = .init(init.gpa);
    defer out.deinit();
    var surface = try term.Surface.init(init.gpa, width, height);
    defer surface.deinit(&out.writer);
    var view: term.VtView = .{};
    const start = std.Io.Timestamp.now(init.io, .awake);
    try view.draw(panes[0], &surface, .{ .width = width, .height = height });
    try surface.present(init.io, init.environ_map, &out.writer);
    const first_bytes = out.written().len;
    const elapsed = start.durationTo(std.Io.Timestamp.now(init.io, .awake)).toNanoseconds();
    for (0..100) |_| {
        try view.draw(panes[0], &surface, .{ .width = width, .height = height });
        try surface.present(init.io, init.environ_map, &out.writer);
    }
    if (out.written().len != first_bytes) return error.IdleOutput;
    std.debug.print("panes={d} size={d}x{d} first_bytes={d} first_ns={d} unchanged_100_bytes=0 idle_ready\n", .{ count, width, height, first_bytes, elapsed });
    try std.Io.sleep(init.io, .fromSeconds(5), .awake);
}
