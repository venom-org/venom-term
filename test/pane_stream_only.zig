//! A headless dependent that imports only the `pane_stream` module: the
//! pane-stream client with no libvaxis, wired to nothing but its own frames.
const std = @import("std");
const ps = @import("pane_stream");

pub fn main() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    var s = try ps.PaneStream.init(dbg.allocator(), "p0", 1, .{ .cols = 10, .rows = 3 }, 0);
    defer s.deinit();
    try s.attach(null);
    try s.handle(ps.Kind.attached, "{\"source\":\"venomx/x\",\"format\":\"vt\",\"input\":false}");
    try s.handle(ps.Kind.ready, "{\"snap\":1,\"epoch\":0,\"oldest\":0,\"top\":0,\"active\":0,\"cols\":10,\"rows\":3,\"offset\":0}");
    if (s.phase != .live or s.vt == null) return error.NotLive;
}
