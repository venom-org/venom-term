//! Leader popup cost: first draw, redraws of an unchanged popup
//! over panes that did not change, and the timer's wakeups while it is open.
//! Args: rows width height (default 30 120 40).
const std = @import("std");
const term = @import("venom-term");
const popup = term.chrome.leader_popup;
const widget = term.widgets.leader_popup;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const count: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 30;
    const width: u16 = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 120;
    const height: u16 = if (args.len > 3) try std.fmt.parseInt(u16, args[3], 10) else 40;

    const a = init.arena.allocator();
    const rows = try a.alloc(popup.Row, count);
    for (rows, 0..) |*r, i| r.* = .{ .keys = try std.fmt.allocPrint(a, "k{d}", .{i}), .more = i % 4 == 0, .label = "focus the next pane" };
    const model: popup.Model = .{ .title = "venomx › venom › agents", .rows = rows };
    const area: term.Region = .{ .width = width, .height = height };
    const theme: term.widgets.Theme = .default;

    var out: std.Io.Writer.Allocating = .init(init.gpa);
    defer out.deinit();
    var surface = try term.Surface.init(init.gpa, width, height);
    defer surface.deinit(&out.writer);
    try surface.clear(area, .{});
    try surface.present(init.io, init.environ_map, &out.writer);
    const before = out.written().len;

    var start = std.Io.Timestamp.now(init.io, .awake);
    const covered = try widget.draw(&surface, area, &theme, model, .{});
    try surface.present(init.io, init.environ_map, &out.writer);
    const first_ns = start.durationTo(std.Io.Timestamp.now(init.io, .awake)).toNanoseconds();
    const first_bytes = out.written().len - before;

    const redraws = 1000;
    const settled = out.written().len;
    start = std.Io.Timestamp.now(init.io, .awake);
    for (0..redraws) |_| {
        _ = try widget.draw(&surface, area, &theme, model, .{});
        try surface.present(init.io, init.environ_map, &out.writer);
    }
    const redraw_ns = start.durationTo(std.Io.Timestamp.now(init.io, .awake)).toNanoseconds();
    if (out.written().len != settled) return error.IdleOutput;

    // Open and waiting for a key, nothing asks an event loop to wake.
    var timer: popup.Timer = .{};
    _ = timer.sync(.{ .pending = true }, 200, 0);
    _ = timer.sync(.{ .pending = true }, 200, 200);
    if (!timer.visible() or timer.nextWake() != null) return error.IdleWake;

    std.debug.print("rows={d} size={d}x{d} popup={d}x{d} first_ns={d} first_bytes={d} redraw_ns={d} unchanged_{d}_bytes=0 open_wakes=0\n", .{ count, width, height, covered.width, covered.height, first_ns, first_bytes, @divTrunc(redraw_ns, redraws), redraws });
}
