pub const Color = union(enum) { default, index: u8, rgb: [3]u8 };
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    ul: Color = .default,
    underline: enum(u3) { off, single, double, curly, dotted, dashed } = .off,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    blink: bool = false,
    reverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
};
/// A borrowed grapheme; Surface.put copies it. width=0 is a wide-cell tail.
pub const Cell = struct { text: []const u8 = " ", width: u8 = 1, style: Style = .{} };
pub const Region = struct { x: u16 = 0, y: u16 = 0, width: u16, height: u16 };

pub const Input = @import("input_types.zig");

/// The cursor shape a program asked for with DECSCUSR (`CSI Ps SP q`).
pub const CursorShape = struct {
    kind: Kind = .default,
    blink: bool = false,
    /// `.default`: the program never set a shape, or reset it with `CSI 0 q`.
    /// A presenter then leaves the host terminal's own cursor.
    pub const Kind = enum { default, block, underline, bar };
};
