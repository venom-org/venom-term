//! Backend-independent input values shared by parser and headless encoder.
pub const Modifiers = packed struct { shift: bool = false, alt: bool = false, ctrl: bool = false, super: bool = false, hyper: bool = false, meta: bool = false, caps_lock: bool = false, num_lock: bool = false };
pub const Key = struct {
    codepoint: u21,
    text: ?[]const u8,
    shifted: ?u21,
    base_layout: ?u21,
    mods: Modifiers,
    action: enum { press, release, repeat },
    /// Physical keypad identity, only when supplied by the frontend.
    keypad: ?Keypad = null,
};
// Venom's named-key values, independent of backend representation.
pub const NamedKey = enum(u21) { escape = 27, enter = 13, tab = 9, backspace = 127, up = 0x110000, down, left, right, home, end, insert, delete, page_up, page_down, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12 };
pub const Mouse = struct {
    x: i16,
    y: i16,
    button: enum { left, middle, right, none, wheel_up, wheel_down, wheel_right, wheel_left, extra },
    action: enum { press, release, motion, drag },
    mods: Modifiers,
};

pub const Keypad = enum { zero, one, two, three, four, five, six, seven, eight, nine, enter, decimal, add, subtract, multiply, divide, equal };
