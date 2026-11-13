const std = @import("std");
const Vt = @import("vt").Vt;
pub fn main(init: std.process.Init) !void {
    var vt = try Vt.init(init.gpa, .{});
    defer vt.deinit();
    try vt.feed("\x1b[?1h");
    const encoded = try vt.encodeKey(init.gpa, .{ .codepoint = @backingInt(Vt.Input.NamedKey.up), .text = null, .shifted = null, .base_layout = null, .mods = .{}, .action = .press });
    defer init.gpa.free(encoded);
    if (!std.mem.eql(u8, encoded, "\x1bOA")) return error.BadKeyEncoding;
    try vt.feed("headless\x1b[31");
    const snap = try vt.snapshot(init.gpa);
    defer snap.deinit(init.gpa);
    var copy = try Vt.restore(init.gpa, snap, .{});
    defer copy.deinit();
    try copy.feed("m works");
    const text = try copy.exportRows(init.gpa, copy.rows().epoch, copy.rows().active, copy.rows().active + 1);
    defer init.gpa.free(text);
    if (!std.mem.startsWith(u8, text, "headless works")) return error.BadRestore;
}
