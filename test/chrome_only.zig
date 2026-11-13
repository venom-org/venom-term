//! A headless dependent that imports only the `chrome` module (shared
//! presentation-client logic): no Ghostty, no libvaxis.
const std = @import("std");
const chrome = @import("chrome");

pub fn main() !void {
    const c = chrome.keys.parseChord("ctrl+space") orelse return error.Chord;
    if (chrome.keys.legacyByte(c) != 0) return error.Chord;
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const placed = try chrome.status.layout(fba.allocator(), &.{.{ .id = "venomx.session", .text = "[s0]", .side = .left, .priority = 100, .style = .normal }}, 10);
    if (placed.len != 1) return error.Layout;
    var timer: chrome.leader_popup.Timer = .{};
    if (!timer.sync(.{ .pending = true }, 0, 0) or !timer.visible()) return error.Popup;
}
