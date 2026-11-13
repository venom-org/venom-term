pub const Vt = @import("vt").Vt;
pub const Surface = @import("surface.zig").Surface;
pub const Input = @import("input.zig").Input;
pub const VtView = @import("view.zig").VtView;
pub const widgets = @import("widgets.zig");
pub const theme = @import("theme.zig");
/// Shared presentation-client logic: key tables, tags, status layout (also the
/// headless `chrome` module).
pub const chrome = @import("chrome");
/// venomx pane-stream client (also the headless `pane_stream` module).
pub const pane_stream = @import("pane_stream");
pub const Color = @import("types").Color;
pub const Style = @import("types").Style;
pub const Cell = @import("types").Cell;
pub const Region = @import("types").Region;
test {
    @import("std").testing.refAllDecls(@This());
}

test "headless status widths agree with widget terminal widths" {
    const samples = [_][]const u8{
        "ASCII status",
        "中文",
        "😀",
        "👨‍👩‍👧‍👦",
        "🇩🇪",
        "é",
        "❤️",
        "👍🏽",
        "ＡＢ",
        "● ▲ ✕ ◆ ○",
        "a界😀é",
    };
    for (samples) |sample| {
        try @import("std").testing.expectEqual(widgets.text.width(sample), chrome.status.width(sample));
    }
}

test "chrome.status.width never undercounts a codepoint against widgets.text.width" {
    var cp: u21 = 0x20;
    while (cp <= 0x3ffff) : (cp += 1) {
        if (cp >= 0xd800 and cp <= 0xdfff) continue;
        var buf: [4]u8 = undefined;
        const n = @import("std").unicode.utf8Encode(cp, &buf) catch continue;
        const s = buf[0..n];
        if (chrome.status.width(s) < widgets.text.width(s)) {
            @import("std").debug.print("undercount U+{X}\n", .{cp});
            return error.TestUnexpectedResult;
        }
    }
}

test "chrome.status.width never undercounts emoji sequences against widgets.text.width" {
    const std = @import("std");
    const suffixes = [_][]const u8{ "\u{fe0f}", "\u{1f3fd}", "\u{200d}\u{1f525}" };
    const ranges = [_][2]u21{ .{ 0x203c, 0x3299 }, .{ 0x1f000, 0x1faff } };
    for (ranges) |r| {
        var cp: u21 = r[0];
        while (cp <= r[1]) : (cp += 1) {
            if (cp >= 0xd800 and cp <= 0xdfff) continue;
            if (!chrome.status.cell_width.isEmoji(cp) and !(cp >= 0x2600 and cp <= 0x27bf) and !(cp >= 0x1f000 and cp <= 0x1faff)) continue;
            var buf: [16]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            for (suffixes) |suf| {
                @memcpy(buf[n..][0..suf.len], suf);
                const sq = buf[0 .. n + suf.len];
                if (chrome.status.width(sq) < widgets.text.width(sq)) {
                    std.debug.print("undercount U+{X} + suffix len {d}: {d} < {d}\n", .{ cp, suf.len, chrome.status.width(sq), widgets.text.width(sq) });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}
