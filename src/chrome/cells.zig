//! Small, headless cell iterator for status text (which never holds controls).
//! Covers combining/variation marks, emoji modifiers, flags and emoji ZWJ
//! sequences; this is deliberately not a general Unicode segmentation API.
//! Limit: never undercounts a single codepoint versus vaxis (checked over
//! U+0020..U+3FFFF), but zero-width marks outside the listed ranges (Thai,
//! Indic and other combining scripts) are counted as 1 cell. Decomposed
//! (NFD) Hangul jamo sequences are measured per jamo, not per syllable.
const std = @import("std");

const Range = struct { u21, u21 };
fn contains(cp: u21, ranges: []const Range) bool {
    for (ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return false;
}

fn extending(cp: u21) bool {
    if (cp >= 0x1f3fb and cp <= 0x1f3ff) return true;
    return contains(cp, &.{
        .{ 0x0300, 0x036f },   .{ 0x0483, 0x0489 },   .{ 0x0591, 0x05bd },
        .{ 0x05bf, 0x05bf },   .{ 0x05c1, 0x05c2 },   .{ 0x05c4, 0x05c5 },
        .{ 0x05c7, 0x05c7 },   .{ 0x0610, 0x061a },   .{ 0x064b, 0x065f },
        .{ 0x0670, 0x0670 },   .{ 0x06d6, 0x06dc },   .{ 0x06df, 0x06e4 },
        .{ 0x06e7, 0x06e8 },   .{ 0x06ea, 0x06ed },   .{ 0x1ab0, 0x1ace },
        .{ 0x1dc0, 0x1dff },   .{ 0x20d0, 0x20f0 },   .{ 0x302a, 0x302d },
        .{ 0x3099, 0x309a },   .{ 0xfe00, 0xfe0f },   .{ 0xfe20, 0xfe2f },
        .{ 0xe0020, 0xe007f }, .{ 0xe0100, 0xe01ef },
    });
}

fn baseWidth(cp: u21) usize {
    if (extending(cp) or cp == 0x200d) return 0;
    if (cp == '\t') return 1;
    if (cp < 0x20 or cp == 0x7f) return 0;
    // East Asian wide/fullwidth blocks and default emoji presentation.
    return if (contains(cp, &.{
        .{ 0x1100, 0x115f },   .{ 0x231a, 0x231b },   .{ 0x2329, 0x232a },
        .{ 0x23e9, 0x23ec },   .{ 0x23f0, 0x23f0 },   .{ 0x23f3, 0x23f3 },
        .{ 0x25fd, 0x25fe },   .{ 0x2614, 0x2615 },   .{ 0x2648, 0x2653 },
        .{ 0x267f, 0x267f },   .{ 0x2693, 0x2693 },   .{ 0x26a1, 0x26a1 },
        .{ 0x26aa, 0x26ab },   .{ 0x26bd, 0x26be },   .{ 0x26c4, 0x26c5 },
        .{ 0x26ce, 0x26ce },   .{ 0x26d4, 0x26d4 },   .{ 0x26ea, 0x26ea },
        .{ 0x26f2, 0x26f3 },   .{ 0x26f5, 0x26f5 },   .{ 0x26fa, 0x26fa },
        .{ 0x26fd, 0x26fd },   .{ 0x2705, 0x2705 },   .{ 0x270a, 0x270b },
        .{ 0x2728, 0x2728 },   .{ 0x274c, 0x274c },   .{ 0x274e, 0x274e },
        .{ 0x2753, 0x2755 },   .{ 0x2757, 0x2757 },   .{ 0x2795, 0x2797 },
        .{ 0x27b0, 0x27b0 },   .{ 0x27bf, 0x27bf },   .{ 0x2b1b, 0x2b1c },
        .{ 0x2630, 0x2637 },   .{ 0x268a, 0x268f },   .{ 0x2b50, 0x2b50 },
        .{ 0x2b55, 0x2b55 },   .{ 0x2e80, 0x303e },   .{ 0x3040, 0xa4cf },
        .{ 0xa960, 0xa97c },   .{ 0xac00, 0xd7a3 },   .{ 0xf900, 0xfaff },
        .{ 0xfe10, 0xfe19 },   .{ 0xfe30, 0xfe6f },   .{ 0xff01, 0xff60 },
        .{ 0xffe0, 0xffe6 },   .{ 0x16fe0, 0x191d2 }, .{ 0x1aff0, 0x1b2ff },
        .{ 0x1d300, 0x1d376 }, .{ 0x1f004, 0x1f004 }, .{ 0x1f0cf, 0x1f0cf },
        .{ 0x1f18e, 0x1f18e }, .{ 0x1f1ae, 0x1f1ae }, .{ 0x1f191, 0x1f19a },
        .{ 0x1f1e6, 0x1f1ff }, .{ 0x1f200, 0x1f202 }, .{ 0x1f210, 0x1f23b },
        .{ 0x1f240, 0x1f248 }, .{ 0x1f250, 0x1f251 }, .{ 0x1f260, 0x1f265 },
        .{ 0x1f300, 0x1f320 }, .{ 0x1f32d, 0x1f335 }, .{ 0x1f337, 0x1f37c },
        .{ 0x1f37e, 0x1f393 }, .{ 0x1f3a0, 0x1f3ca }, .{ 0x1f3cf, 0x1f3d3 },
        .{ 0x1f3e0, 0x1f3f0 }, .{ 0x1f3f4, 0x1f3f4 }, .{ 0x1f3f8, 0x1f43e },
        .{ 0x1f440, 0x1f440 }, .{ 0x1f442, 0x1f4fc }, .{ 0x1f4ff, 0x1f53d },
        .{ 0x1f54b, 0x1f54e }, .{ 0x1f550, 0x1f567 }, .{ 0x1f57a, 0x1f57a },
        .{ 0x1f595, 0x1f596 }, .{ 0x1f5a4, 0x1f5a4 }, .{ 0x1f5fb, 0x1f64f },
        .{ 0x1f680, 0x1f6c5 }, .{ 0x1f6cc, 0x1f6cc }, .{ 0x1f6d0, 0x1f6d2 },
        .{ 0x1f6d5, 0x1f6d9 }, .{ 0x1f6dc, 0x1f6df }, .{ 0x1f6eb, 0x1f6ec },
        .{ 0x1f6f4, 0x1f6fc }, .{ 0x1f7da, 0x1f7da }, .{ 0x1f7e0, 0x1f7eb },
        .{ 0x1f7f0, 0x1f7f0 }, .{ 0x1f900, 0x1f9ff }, .{ 0x1fa70, 0x1faff },
        .{ 0x20000, 0x3fffd },
    })) 2 else 1;
}

/// Emoji_Modifier_Base: only these take a skin-tone modifier.
fn modifierBase(cp: u21) bool {
    return contains(cp, &.{
        .{ 0x261d, 0x261d },   .{ 0x26f9, 0x26f9 },   .{ 0x270a, 0x270d },   .{ 0x1f385, 0x1f385 },
        .{ 0x1f3c2, 0x1f3c4 }, .{ 0x1f3c7, 0x1f3c7 }, .{ 0x1f3ca, 0x1f3cc }, .{ 0x1f442, 0x1f443 },
        .{ 0x1f446, 0x1f450 }, .{ 0x1f466, 0x1f478 }, .{ 0x1f47c, 0x1f47c }, .{ 0x1f481, 0x1f483 },
        .{ 0x1f485, 0x1f487 }, .{ 0x1f48f, 0x1f48f }, .{ 0x1f491, 0x1f491 }, .{ 0x1f4aa, 0x1f4aa },
        .{ 0x1f574, 0x1f575 }, .{ 0x1f57a, 0x1f57a }, .{ 0x1f590, 0x1f590 }, .{ 0x1f595, 0x1f596 },
        .{ 0x1f645, 0x1f647 }, .{ 0x1f64b, 0x1f64f }, .{ 0x1f6a3, 0x1f6a3 }, .{ 0x1f6b4, 0x1f6b6 },
        .{ 0x1f6c0, 0x1f6c0 }, .{ 0x1f6cc, 0x1f6cc }, .{ 0x1f90c, 0x1f90c }, .{ 0x1f90f, 0x1f90f },
        .{ 0x1f918, 0x1f91f }, .{ 0x1f926, 0x1f926 }, .{ 0x1f930, 0x1f939 }, .{ 0x1f93c, 0x1f93e },
        .{ 0x1f977, 0x1f977 }, .{ 0x1f9b5, 0x1f9b6 }, .{ 0x1f9b8, 0x1f9b9 }, .{ 0x1f9bb, 0x1f9bb },
        .{ 0x1f9cd, 0x1f9cf }, .{ 0x1f9d1, 0x1f9dd }, .{ 0x1fac3, 0x1fac5 }, .{ 0x1faf0, 0x1faf8 },
    });
}

fn joinable(cp: u21, vs16: bool) bool {
    if (cp >= 0x1f000 and cp < 0x1f300 and !contains(cp, &.{ .{ 0x1f004, 0x1f004 }, .{ 0x1f0cf, 0x1f0cf }, .{ 0x1f18e, 0x1f18e }, .{ 0x1f191, 0x1f19a } })) return false;
    // Wide but not pictographic (old symbols, arrows) in the emoji blocks.
    if (contains(cp, &.{ .{ 0x1f7da, 0x1f7da }, .{ 0x1f900, 0x1f90b }, .{ 0x1f93b, 0x1f93b }, .{ 0x1f946, 0x1f946 } })) return false;
    return isEmoji(cp) and (vs16 or baseWidth(cp) == 2);
}

pub fn isEmoji(cp: u21) bool {
    return (cp >= 0x1f000 and cp <= 0x1faff) or contains(cp, &.{
        .{ 0x203c, 0x203c }, .{ 0x2049, 0x2049 }, .{ 0x2122, 0x2122 }, .{ 0x2139, 0x2139 },
        .{ 0x2194, 0x2199 }, .{ 0x21a9, 0x21aa }, .{ 0x231a, 0x231b }, .{ 0x2328, 0x2328 },
        .{ 0x23cf, 0x23cf }, .{ 0x23e9, 0x23f3 }, .{ 0x23f8, 0x23fa }, .{ 0x24c2, 0x24c2 },
        .{ 0x25aa, 0x25ab }, .{ 0x25b6, 0x25b6 }, .{ 0x25c0, 0x25c0 }, .{ 0x25fb, 0x25fe },

        .{ 0x2600, 0x2604 }, .{ 0x260e, 0x260e }, .{ 0x2611, 0x2611 }, .{ 0x2614, 0x2615 },
        .{ 0x2618, 0x2618 }, .{ 0x261d, 0x261d }, .{ 0x2620, 0x2620 }, .{ 0x2622, 0x2623 },
        .{ 0x2626, 0x2626 }, .{ 0x262a, 0x262a }, .{ 0x262e, 0x262f }, .{ 0x2638, 0x263a },
        .{ 0x2640, 0x2640 }, .{ 0x2642, 0x2642 }, .{ 0x2648, 0x2653 }, .{ 0x265f, 0x2660 },
        .{ 0x2663, 0x2663 }, .{ 0x2665, 0x2666 }, .{ 0x2668, 0x2668 }, .{ 0x267b, 0x267b },
        .{ 0x267e, 0x267f }, .{ 0x2692, 0x2697 }, .{ 0x2699, 0x2699 }, .{ 0x269b, 0x269c },
        .{ 0x26a0, 0x26a1 }, .{ 0x26a7, 0x26a7 }, .{ 0x26aa, 0x26ab }, .{ 0x26b0, 0x26b1 },
        .{ 0x26bd, 0x26be }, .{ 0x26c4, 0x26c5 }, .{ 0x26c8, 0x26c8 }, .{ 0x26ce, 0x26cf },
        .{ 0x26d1, 0x26d1 }, .{ 0x26d3, 0x26d4 }, .{ 0x26e9, 0x26ea }, .{ 0x26f0, 0x26f5 },
        .{ 0x26f7, 0x26fa }, .{ 0x26fd, 0x26fd }, .{ 0x2702, 0x2702 }, .{ 0x2705, 0x2705 },
        .{ 0x2708, 0x270d }, .{ 0x270f, 0x270f }, .{ 0x2712, 0x2712 }, .{ 0x2714, 0x2714 },
        .{ 0x2716, 0x2716 }, .{ 0x271d, 0x271d }, .{ 0x2721, 0x2721 }, .{ 0x2728, 0x2728 },
        .{ 0x2733, 0x2734 }, .{ 0x2744, 0x2744 }, .{ 0x2747, 0x2747 }, .{ 0x274c, 0x274c },
        .{ 0x274e, 0x274e }, .{ 0x2753, 0x2755 }, .{ 0x2757, 0x2757 }, .{ 0x2763, 0x2767 },
        .{ 0x27a1, 0x27a1 }, .{ 0x27b0, 0x27b0 }, .{ 0x27bf, 0x27bf }, .{ 0x2795, 0x2797 },
        .{ 0x2934, 0x2935 }, .{ 0x2b05, 0x2b55 }, .{ 0x3030, 0x3030 }, .{ 0x303d, 0x303d },
        .{ 0x3297, 0x3297 }, .{ 0x3299, 0x3299 },
    });
}

pub const Cluster = struct {
    text: []const u8,
    width: usize,
    /// The cluster is one byte that is not valid UTF-8 (counted as U+FFFD).
    invalid: bool = false,
};
pub const Iterator = struct {
    text: []const u8,
    pos: usize = 0,

    fn peek(self: *const Iterator) struct { cp: u21, len: usize, ok: bool } {
        const len = std.unicode.utf8ByteSequenceLength(self.text[self.pos]) catch return .{ .cp = 0xfffd, .len = 1, .ok = false };
        if (self.pos + len > self.text.len) return .{ .cp = 0xfffd, .len = 1, .ok = false };
        const cp = std.unicode.utf8Decode(self.text[self.pos..][0..len]) catch return .{ .cp = 0xfffd, .len = 1, .ok = false };
        return .{ .cp = cp, .len = len, .ok = true };
    }

    pub fn next(self: *Iterator) ?Cluster {
        if (self.pos == self.text.len) return null;
        const start = self.pos;
        const first = self.peek();
        self.pos += first.len;
        if (!first.ok) return .{ .text = self.text[start..self.pos], .width = 1, .invalid = true };
        // A modifier or VS16 with nothing to attach to is a 2-cell glyph.
        var w: usize = if (first.cp == 0xfe0e) 1 else if (first.cp == 0xfe0f or (first.cp >= 0x1f3fb and first.cp <= 0x1f3ff)) 2 else baseWidth(first.cp);
        var regional = first.cp >= 0x1f1e6 and first.cp <= 0x1f1ff;
        // ZWJ joins only after an emoji that is wide by itself or got VS16;
        // vaxis splits after other pictographs, and so must we or we undercount.
        var last_emoji = joinable(first.cp, false);
        var last_cp = first.cp;
        var last_base = modifierBase(first.cp);
        var joined = false;
        while (self.pos < self.text.len) {
            const p = self.peek();
            if (!p.ok) break;
            if (joined) {
                // Only an emoji after ZWJ continues the sequence.
                if (!isEmoji(p.cp)) break;
                w = 2;
                joined = false;
                last_emoji = joinable(p.cp, false);
                last_cp = p.cp;
                last_base = modifierBase(p.cp);
            } else if (p.cp >= 0x1f3fb and p.cp <= 0x1f3ff) {
                // A skin tone attaches only to a modifier base; otherwise it
                // starts its own 2-cell cluster, as in vaxis.
                if (!last_base) break;
                w = 2;
                last_base = false;
            } else if (extending(p.cp)) {
                if (p.cp == 0xfe0f) {
                    w = 2;
                    last_emoji = joinable(last_cp, true);
                }
            } else if (p.cp == 0x200d) {
                joined = last_emoji;
            } else if (regional and p.cp >= 0x1f1e6 and p.cp <= 0x1f1ff) {
                w = 2;
                regional = false;
            } else break;
            self.pos += p.len;
        }
        return .{ .text = self.text[start..self.pos], .width = w };
    }
};

const testing = std.testing;
fn cellsOf(text: []const u8) usize {
    var it: Iterator = .{ .text = text };
    var total: usize = 0;
    while (it.next()) |g| total += g.width;
    return total;
}
test "more wide ranges" {
    for ([_]u21{ 0x1f7e0, 0x1f7eb, 0x1f7f0, 0x1f7da, 0x1f6d9, 0x1f1ae, 0x1f260, 0x1f265, 0x2630, 0x2637, 0x268a, 0x268f, 0x18e00, 0x191d2, 0x1d300, 0x1d376, 0x302e, 0x302f }) |cp| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try testing.expectEqual(@as(usize, 2), cellsOf(buf[0..n]));
    }
    try testing.expectEqual(@as(usize, 5), cellsOf("🟢 ok"));
}
test "invalid utf-8 consumes one byte as one cell" {
    try testing.expectEqual(@as(usize, 4), cellsOf("\xE4abc"));
    try testing.expectEqual(@as(usize, 1), cellsOf("\xff"));
    try testing.expectEqual(@as(usize, 2), cellsOf("a\xe4"));
    var it: Iterator = .{ .text = "\xff" };
    try testing.expect(it.next().?.invalid);
}
test "standalone modifier and VS16 are two cells" {
    try testing.expectEqual(@as(usize, 2), cellsOf("\u{1f3fd}"));
    try testing.expectEqual(@as(usize, 2), cellsOf("\u{fe0f}"));
    try testing.expectEqual(@as(usize, 2), cellsOf("👍🏽"));
}
test "ZWJ joins only emoji" {
    try testing.expectEqual(@as(usize, 2), cellsOf("a\u{200d}b"));
    try testing.expectEqual(@as(usize, 2), cellsOf("👨\u{200d}👩\u{200d}👧\u{200d}👦"));
    try testing.expectEqual(@as(usize, 3), cellsOf("👨\u{200d}b"));
}
