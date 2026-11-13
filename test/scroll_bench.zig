//! ScrollView render cost for a long transcript.
//!
//!   zig build bench-scroll -Doptimize=ReleaseFast [-- blocks width height]
//!
//! Builds a transcript of `blocks` blocks (default 10000; every fifth one a
//! collapsed tool call), then times: the first draw, a steady redraw at the
//! tail, appending one block and drawing, toggling one block and drawing,
//! the last block streaming, and a resize. The middle cases run twice, with
//! no hint and with `assumeUnchanged`. Results are in
//! docs/scroll-cache.md.
const std = @import("std");
const term = @import("venom-term");
const w = term.widgets;

const words = [_][]const u8{ "the", "frame", "codec", "rejects", "a", "zero-length", "payload", "because", "src/proto/frame.zig", "checks", "len", "before", "reading", "header", "bytes", "so", "we", "return", "error.Short", "early" };

fn makeSpans(a: std.mem.Allocator, i: usize) ![]const w.Span {
    var buf: std.ArrayList(u8) = .empty;
    const n = 8 + (i * 7) % 40;
    for (0..n) |k| {
        if (k > 0) try buf.append(a, if ((i + k) % 17 == 0) '\n' else ' ');
        try buf.appendSlice(a, words[(i * 3 + k) % words.len]);
    }
    if (i % 5 == 0) return a.dupe(w.Span, &.{ .{ .text = "Bash", .role = .info }, .{ .text = "  zig build test\n" }, .{ .text = buf.items, .role = .secondary } });
    return a.dupe(w.Span, &.{ .{ .text = "agent  ", .role = .accent }, .{ .text = buf.items } });
}

fn makeBlock(a: std.mem.Allocator, i: usize) !w.Block {
    return .{ .spans = try makeSpans(a, i), .collapsible = i % 5 == 0, .collapsed = i % 5 == 0, .preview = 1 };
}

fn wraps(view: *const w.ScrollView) ?u64 {
    return if (@hasField(w.ScrollView, "wraps")) view.wraps else null;
}

/// Bytes the view holds for wrapped lines and its line index.
fn heldBytes(view: *const w.ScrollView) usize {
    return view.entries.capacity * @sizeOf(@TypeOf(view.entries.items[0])) +
        view.wrapped.segments.capacity * @sizeOf(w.text.Segment) + view.wrapped.lines.capacity * @sizeOf(w.text.Line) +
        view.starts.capacity * @sizeOf(u32);
}

fn report(name: []const u8, ns: u64, reps: usize, view: *const w.ScrollView, before: ?u64) void {
    const per: u64 = ns / @max(reps, 1);
    if (wraps(view)) |after| {
        std.debug.print("{s:<14} {d:>10} ns/draw  {d:>6} block wraps/draw\n", .{ name, per, (after - before.?) / @max(reps, 1) });
    } else {
        std.debug.print("{s:<14} {d:>10} ns/draw\n", .{ name, per });
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const count: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 10_000;
    const width: u16 = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 100;
    const height: u16 = if (args.len > 3) try std.fmt.parseInt(u16, args[3], 10) else 40;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var blocks: std.ArrayList(w.Block) = .empty;
    defer blocks.deinit(gpa);
    for (0..count) |i| try blocks.append(gpa, try makeBlock(a, i));

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var surface = try term.Surface.init(gpa, width + 20, height);
    defer surface.deinit(&discard.writer);
    var view: w.ScrollView = .{};
    defer view.deinit(gpa);
    const theme: w.Theme = .default;
    var region: term.Region = .{ .width = width, .height = height };

    const now = struct {
        fn f(i: std.Io) std.Io.Timestamp {
            return std.Io.Timestamp.now(i, .awake);
        }
    }.f;
    const since = struct {
        fn f(i: std.Io, t: std.Io.Timestamp) u64 {
            return @intCast(t.durationTo(std.Io.Timestamp.now(i, .awake)).toNanoseconds());
        }
    }.f;

    std.debug.print("blocks={d} width={d} height={d}\n", .{ count, width, height });
    var w0 = wraps(&view);
    var t = now(io);
    try view.draw(gpa, &surface, region, blocks.items, &theme, true);
    report("first draw", since(io, t), 1, &view, w0);
    std.debug.print("{s:<14} {d:>10} visual lines, {d} KiB held\n", .{ "", view.lineCount(), heldBytes(&view) / 1024 });

    const reps = 200;
    // `hinted` passes `assumeUnchanged` as a product that knows what changed would.
    for ([_]bool{ false, true }) |hinted| {
        std.debug.print("{s}\n", .{if (hinted) "with assumeUnchanged:" else "no hint:"});
        w0 = wraps(&view);
        t = now(io);
        for (0..reps) |_| {
            if (hinted) view.assumeUnchanged(blocks.items.len);
            try view.draw(gpa, &surface, region, blocks.items, &theme, true);
        }
        report("tail redraw", since(io, t), reps, &view, w0);

        w0 = wraps(&view);
        var total: u64 = 0;
        for (0..reps) |_| {
            const old = blocks.items.len;
            try blocks.append(gpa, try makeBlock(a, old));
            t = now(io);
            if (hinted) view.assumeUnchanged(old);
            try view.draw(gpa, &surface, region, blocks.items, &theme, true);
            total += since(io, t);
        }
        report("append + draw", total, reps, &view, w0);

        w0 = wraps(&view);
        total = 0;
        for (0..reps) |_| {
            // Expand or collapse a tool call near the tail.
            const idx = blocks.items.len - 5 - (blocks.items.len - 5) % 5;
            view.toggle(blocks.items, idx);
            t = now(io);
            if (hinted) view.assumeUnchanged(blocks.items.len);
            try view.draw(gpa, &surface, region, blocks.items, &theme, true);
            total += since(io, t);
        }
        report("toggle + draw", total, reps, &view, w0);

        // The last block grows a word at a time, its text slice getting longer.
        const stream = try a.alloc(u8, (reps + 1) * 6);
        @memset(stream, ' ');
        for (0..reps + 1) |k| @memcpy(stream[k * 6 ..][0..5], "words");
        try blocks.append(gpa, .{ .spans = try a.dupe(w.Span, &.{.{ .text = stream[0..5] }}) });
        try view.draw(gpa, &surface, region, blocks.items, &theme, true);
        const last: []w.Span = @constCast(blocks.items[blocks.items.len - 1].spans);
        w0 = wraps(&view);
        total = 0;
        for (0..reps) |k| {
            last[0].text = stream[0 .. (k + 1) * 6 + 5];
            t = now(io);
            if (hinted) view.assumeUnchanged(blocks.items.len - 1);
            try view.draw(gpa, &surface, region, blocks.items, &theme, true);
            total += since(io, t);
        }
        report("stream + draw", total, reps, &view, w0);
    }
    std.debug.print("{s:<14} {d:>10} KiB held\n", .{ "after edits", heldBytes(&view) / 1024 });

    w0 = wraps(&view);
    region.width = width + 20;
    t = now(io);
    try view.draw(gpa, &surface, region, blocks.items, &theme, true);
    report("resize", since(io, t), 1, &view, w0);
    std.debug.print("{s:<14} {d:>10} KiB held\n", .{ "after resize", heldBytes(&view) / 1024 });
}
