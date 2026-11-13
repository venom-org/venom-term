//! Input encoding stays behind the headless terminal boundary.
const std = @import("std");
const c = @import("ghostty_c");
const Input = @import("types").Input;
const Error = @import("vt.zig").Error;

fn check(result: c.GhosttyResult) Error!void {
    switch (result) {
        c.GHOSTTY_SUCCESS => {},
        c.GHOSTTY_OUT_OF_MEMORY => return error.OutOfMemory,
        c.GHOSTTY_INVALID_VALUE => return error.InvalidValue,
        c.GHOSTTY_UNSUPPORTED => return error.Unavailable,
        else => return error.Backend,
    }
}

pub const Modes = struct {
    cursor_application: bool,
    keypad_application: bool,
    bracketed_paste: bool,
    mouse_tracking: bool,
    mouse_pixels: bool,
    /// Kitty protocol bits 0..4, as specified by the protocol.
    kitty_flags: u8,
};
fn mode(terminal: c.GhosttyTerminal, number: u16) Error!bool {
    var config: c.GhosttyTerminalModeConfig = .{ .mode = c.ghostty_mode_new(number, false), .value = false };
    try check(c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_MODE, &config));
    return config.value;
}
pub fn modes(terminal: c.GhosttyTerminal, ca: *const c.GhosttyAllocator) Error!Modes {
    var result: Modes = .{
        .cursor_application = try mode(terminal, 1),
        .keypad_application = try mode(terminal, 66),
        .bracketed_paste = try mode(terminal, 2004),
        .mouse_pixels = try effectivePixels(terminal, ca),
        .mouse_tracking = false,
        .kitty_flags = 0,
    };
    try check(c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &result.mouse_tracking));
    try check(c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &result.kitty_flags));
    return result;
}
// The C API exposes DEC mode bits, but Ghostty keeps the effective mouse
// format separately (the last format set/reset wins). Probe its encoder at
// the origin: SGR pixels emits 0;0, while all cell formats use 1;1. Override
// tracking only on this temporary encoder so detection also works when the
// pane has disabled tracking. No terminal state or callbacks are changed.
fn effectivePixels(terminal: c.GhosttyTerminal, ca: *const c.GhosttyAllocator) Error!bool {
    var encoder: c.GhosttyMouseEncoder = null;
    try check(c.ghostty_mouse_encoder_new(ca, &encoder));
    defer c.ghostty_mouse_encoder_free(encoder);
    try check(c.ghostty_mouse_encoder_set_from_terminal(encoder, terminal));
    const normal: c.GhosttyMouseTrackingMode = c.GHOSTTY_MOUSE_TRACKING_NORMAL;
    try check(c.ghostty_mouse_encoder_set(encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_EVENT, &normal));
    const size: c.GhosttyMouseEncoderSize = .{ .size = @sizeOf(c.GhosttyMouseEncoderSize), .screen_width = 1, .screen_height = 1, .cell_width = 1, .cell_height = 1, .padding_top = 0, .padding_bottom = 0, .padding_left = 0, .padding_right = 0 };
    try check(c.ghostty_mouse_encoder_set(encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size));
    var event: c.GhosttyMouseEvent = null;
    try check(c.ghostty_mouse_event_new(ca, &event));
    defer c.ghostty_mouse_event_free(event);
    try check(c.ghostty_mouse_event_set_button(event, c.GHOSTTY_MOUSE_BUTTON_LEFT));
    var bytes: [32]u8 = undefined;
    var written: usize = 0;
    try check(c.ghostty_mouse_encoder_encode(encoder, event, &bytes, bytes.len, &written));
    return std.mem.eql(u8, bytes[0..written], "\x1b[<0;0;0M");
}
fn mods(m: Input.Modifiers) Error!c.GhosttyMods {
    // The pinned backend has no Hyper/Meta modifier representation.
    if (m.hyper or m.meta) return error.Unavailable;
    return @intCast(@as(u16, @intFromBool(m.shift)) * c.GHOSTTY_MODS_SHIFT |
        @as(u16, @intFromBool(m.ctrl)) * c.GHOSTTY_MODS_CTRL |
        @as(u16, @intFromBool(m.alt)) * c.GHOSTTY_MODS_ALT |
        @as(u16, @intFromBool(m.super)) * c.GHOSTTY_MODS_SUPER |
        @as(u16, @intFromBool(m.caps_lock)) * c.GHOSTTY_MODS_CAPS_LOCK |
        @as(u16, @intFromBool(m.num_lock)) * c.GHOSTTY_MODS_NUM_LOCK);
}
fn upper(comptime name: []const u8) *const [name.len]u8 {
    comptime var result: [name.len]u8 = undefined;
    _ = std.ascii.upperString(&result, name);
    return &result;
}
fn physical(cp: u21) c.GhosttyKey {
    inline for (.{ "escape", "enter", "tab", "backspace", "home", "end", "insert", "delete", "page_up", "page_down", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12" }) |name| {
        if (cp == @backingInt(@field(Input.NamedKey, name))) return @field(c, "GHOSTTY_KEY_" ++ upper(name));
    }
    return switch (cp) {
        @backingInt(Input.NamedKey.up) => c.GHOSTTY_KEY_ARROW_UP,
        @backingInt(Input.NamedKey.down) => c.GHOSTTY_KEY_ARROW_DOWN,
        @backingInt(Input.NamedKey.left) => c.GHOSTTY_KEY_ARROW_LEFT,
        @backingInt(Input.NamedKey.right) => c.GHOSTTY_KEY_ARROW_RIGHT,
        'a'...'z' => @as(u32, c.GHOSTTY_KEY_A) + cp - 'a',
        'A'...'Z' => @as(u32, c.GHOSTTY_KEY_A) + cp - 'A',
        '0'...'9' => @as(u32, c.GHOSTTY_KEY_DIGIT_0) + cp - '0',
        ' ' => c.GHOSTTY_KEY_SPACE,
        '`' => c.GHOSTTY_KEY_BACKQUOTE,
        '\\' => c.GHOSTTY_KEY_BACKSLASH,
        '[' => c.GHOSTTY_KEY_BRACKET_LEFT,
        ']' => c.GHOSTTY_KEY_BRACKET_RIGHT,
        ',' => c.GHOSTTY_KEY_COMMA,
        '=' => c.GHOSTTY_KEY_EQUAL,
        '-' => c.GHOSTTY_KEY_MINUS,
        '.' => c.GHOSTTY_KEY_PERIOD,
        '\'' => c.GHOSTTY_KEY_QUOTE,
        ';' => c.GHOSTTY_KEY_SEMICOLON,
        '/' => c.GHOSTTY_KEY_SLASH,
        kitty_pua_first...kitty_pua_last => kittyFunctional(cp),
        else => c.GHOSTTY_KEY_UNIDENTIFIED,
    };
}
/// Kitty keyboard protocol functional keys live in this Private Use Area
/// range. They name keys, never text: a host reporting all keys sends a bare
/// modifier press as e.g. CSI 57442;5u (left Control).
const kitty_pua_first = 57344;
const kitty_pua_last = 63743;
fn isKittyFunctional(cp: u21) bool {
    return cp >= kitty_pua_first and cp <= kitty_pua_last;
}
fn kittyFunctional(cp: u21) c.GhosttyKey {
    return switch (cp) {
        57358 => c.GHOSTTY_KEY_CAPS_LOCK,
        57359 => c.GHOSTTY_KEY_SCROLL_LOCK,
        57360 => c.GHOSTTY_KEY_NUM_LOCK,
        57361 => c.GHOSTTY_KEY_PRINT_SCREEN,
        57362 => c.GHOSTTY_KEY_PAUSE,
        57363 => c.GHOSTTY_KEY_CONTEXT_MENU,
        57376...57388 => @as(u32, c.GHOSTTY_KEY_F13) + cp - 57376, // F13..F25
        57441 => c.GHOSTTY_KEY_SHIFT_LEFT,
        57442 => c.GHOSTTY_KEY_CONTROL_LEFT,
        57443 => c.GHOSTTY_KEY_ALT_LEFT,
        57444 => c.GHOSTTY_KEY_META_LEFT, // Kitty "super" is ghostty/W3C "meta"
        57447 => c.GHOSTTY_KEY_SHIFT_RIGHT,
        57448 => c.GHOSTTY_KEY_CONTROL_RIGHT,
        57449 => c.GHOSTTY_KEY_ALT_RIGHT,
        57450 => c.GHOSTTY_KEY_META_RIGHT,
        // Keypad keys arrive with Key.keypad set; hyper, Kitty meta, ISO
        // level shifts, F26+ and media keys have no backend key and encode
        // to nothing.
        else => c.GHOSTTY_KEY_UNIDENTIFIED,
    };
}
comptime {
    // The F13..F25 arithmetic above relies on contiguous backend values.
    std.debug.assert(c.GHOSTTY_KEY_F25 - c.GHOSTTY_KEY_F13 == 12);
}
pub fn keyBytes(terminal: c.GhosttyTerminal, ca: *const c.GhosttyAllocator, a: std.mem.Allocator, key: Input.Key) Error![]u8 {
    var encoder: c.GhosttyKeyEncoder = null;
    try check(c.ghostty_key_encoder_new(ca, &encoder));
    defer c.ghostty_key_encoder_free(encoder);
    try check(c.ghostty_key_encoder_set_from_terminal(encoder, terminal));
    var event: c.GhosttyKeyEvent = null;
    try check(c.ghostty_key_event_new(ca, &event));
    defer c.ghostty_key_event_free(event);
    try check(c.ghostty_key_event_set_action(event, switch (key.action) {
        .press => c.GHOSTTY_KEY_ACTION_PRESS,
        .release => c.GHOSTTY_KEY_ACTION_RELEASE,
        .repeat => c.GHOSTTY_KEY_ACTION_REPEAT,
    }));
    try check(c.ghostty_key_event_set_mods(event, try mods(key.mods)));
    const pk = if (key.keypad) |kp| keypadPhysical(kp) else physical(key.base_layout orelse key.codepoint);
    try check(c.ghostty_key_event_set_key(event, pk));
    // A Kitty functional key is identified by `pk` alone; passing its PUA
    // codepoint as text would make the backend emit it as a CSI u key.
    const functional = isKittyFunctional(key.codepoint);
    try check(c.ghostty_key_event_set_unshifted_codepoint(event, if (key.codepoint <= 0x10ffff and !functional) key.codepoint else 0));
    var buf: [4]u8 = undefined;
    // Text from a terminal parser can be a C0 byte (e.g. Ctrl-C); the backend
    // needs the pre-Control character and derives the control encoding itself.
    const cp = if (key.mods.shift) key.shifted orelse key.codepoint else key.codepoint;
    const text = if (key.text) |text| blk: {
        if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) break :blk text;
        break :blk "";
    } else "";
    const utf8 = if (text.len != 0) text else if (functional or isKittyFunctional(cp)) "" else if (cp >= 0x20 and cp < 0x7f or cp >= 0xa0 and cp <= 0x10ffff) buf[0 .. std.unicode.utf8Encode(cp, &buf) catch return error.InvalidValue] else "";
    try check(c.ghostty_key_event_set_utf8(event, .{ .ptr = utf8.ptr, .len = utf8.len }));
    // Shift that turned the key into its text (`;` into `:`) is consumed, as
    // a terminal's own keyboard layout reports it. Otherwise the Kitty
    // disambiguate mode sends Shift+; as CSI 59;2u, which nvim reads as `;`.
    if (key.mods.shift and !key.mods.ctrl and !key.mods.alt and !key.mods.super and utf8.len > 0 and shiftMadeText(key.codepoint, utf8))
        try check(c.ghostty_key_event_set_consumed_mods(event, c.GHOSTTY_MODS_SHIFT));
    var needed: usize = 0;
    const result = c.ghostty_key_encoder_encode(encoder, event, null, 0, &needed);
    if (result != c.GHOSTTY_OUT_OF_SPACE) try check(result);
    const bytes = try a.alloc(u8, needed);
    errdefer a.free(bytes);
    try check(c.ghostty_key_encoder_encode(encoder, event, bytes.ptr, bytes.len, &needed));
    return bytes;
}
/// The text is not what the key types unshifted.
fn shiftMadeText(unshifted: u21, utf8: []const u8) bool {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(unshifted, &buf) catch return true;
    return !std.mem.eql(u8, buf[0..n], utf8);
}
fn keypadPhysical(kp: Input.Keypad) c.GhosttyKey {
    return switch (kp) {
        .zero => c.GHOSTTY_KEY_NUMPAD_0,
        .one => c.GHOSTTY_KEY_NUMPAD_1,
        .two => c.GHOSTTY_KEY_NUMPAD_2,
        .three => c.GHOSTTY_KEY_NUMPAD_3,
        .four => c.GHOSTTY_KEY_NUMPAD_4,
        .five => c.GHOSTTY_KEY_NUMPAD_5,
        .six => c.GHOSTTY_KEY_NUMPAD_6,
        .seven => c.GHOSTTY_KEY_NUMPAD_7,
        .eight => c.GHOSTTY_KEY_NUMPAD_8,
        .nine => c.GHOSTTY_KEY_NUMPAD_9,
        .enter => c.GHOSTTY_KEY_NUMPAD_ENTER,
        .decimal => c.GHOSTTY_KEY_NUMPAD_DECIMAL,
        .add => c.GHOSTTY_KEY_NUMPAD_ADD,
        .subtract => c.GHOSTTY_KEY_NUMPAD_SUBTRACT,
        .multiply => c.GHOSTTY_KEY_NUMPAD_MULTIPLY,
        .divide => c.GHOSTTY_KEY_NUMPAD_DIVIDE,
        .equal => c.GHOSTTY_KEY_NUMPAD_EQUAL,
    };
}

pub const MouseGeometry = struct {
    /// Actual cell dimensions are required for SGR pixel mode. With cell-only
    /// host reports, the top-left pixel of the cell is reported.
    cell_width: ?u16 = null,
    cell_height: ?u16 = null,
    /// Optional precise zero-based pane-relative pixel position.
    pixel: ?struct { x: u32, y: u32 } = null,
};
pub fn mouseBytes(terminal: c.GhosttyTerminal, ca: *const c.GhosttyAllocator, a: std.mem.Allocator, mouse: Input.Mouse, geometry: MouseGeometry) Error![]u8 {
    if (mouse.x < 0 or mouse.y < 0) return error.InvalidValue;
    const current = try modes(terminal, ca);
    if (!current.mouse_tracking) return a.alloc(u8, 0);
    if (mouse.button == .extra) return error.Unavailable;
    const width: u32 = geometry.cell_width orelse if (current.mouse_pixels) return error.Unavailable else 1;
    const height: u32 = geometry.cell_height orelse if (current.mouse_pixels) return error.Unavailable else 1;
    if (width == 0 or height == 0) return error.InvalidValue;
    var encoder: c.GhosttyMouseEncoder = null;
    try check(c.ghostty_mouse_encoder_new(ca, &encoder));
    defer c.ghostty_mouse_encoder_free(encoder);
    try check(c.ghostty_mouse_encoder_set_from_terminal(encoder, terminal));
    var cols: u16 = 0;
    var rows: u16 = 0;
    try check(c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_COLS, &cols));
    try check(c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_ROWS, &rows));
    if (mouse.x >= cols or mouse.y >= rows) return error.InvalidValue;
    const size: c.GhosttyMouseEncoderSize = .{ .size = @sizeOf(c.GhosttyMouseEncoderSize), .screen_width = cols * width, .screen_height = rows * height, .cell_width = width, .cell_height = height, .padding_top = 0, .padding_bottom = 0, .padding_left = 0, .padding_right = 0 };
    try check(c.ghostty_mouse_encoder_set(encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size));
    const dragging = mouse.action == .drag;
    try check(c.ghostty_mouse_encoder_set(encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &dragging));
    var event: c.GhosttyMouseEvent = null;
    try check(c.ghostty_mouse_event_new(ca, &event));
    defer c.ghostty_mouse_event_free(event);
    try check(c.ghostty_mouse_event_set_action(event, switch (mouse.action) {
        .press => c.GHOSTTY_MOUSE_ACTION_PRESS,
        .release => c.GHOSTTY_MOUSE_ACTION_RELEASE,
        .motion, .drag => c.GHOSTTY_MOUSE_ACTION_MOTION,
    }));
    if (mouse.button != .none) try check(c.ghostty_mouse_event_set_button(event, switch (mouse.button) {
        .left => c.GHOSTTY_MOUSE_BUTTON_LEFT,
        .middle => c.GHOSTTY_MOUSE_BUTTON_MIDDLE,
        .right => c.GHOSTTY_MOUSE_BUTTON_RIGHT,
        .wheel_up => c.GHOSTTY_MOUSE_BUTTON_FOUR,
        .wheel_down => c.GHOSTTY_MOUSE_BUTTON_FIVE,
        .wheel_left => c.GHOSTTY_MOUSE_BUTTON_SIX,
        .wheel_right => c.GHOSTTY_MOUSE_BUTTON_SEVEN,
        else => unreachable,
    }));
    try check(c.ghostty_mouse_event_set_mods(event, try mods(mouse.mods)));
    const x = if (geometry.pixel) |p| p.x else @as(u32, @intCast(mouse.x)) * width;
    const y = if (geometry.pixel) |p| p.y else @as(u32, @intCast(mouse.y)) * height;
    if (x >= size.screen_width or y >= size.screen_height) return error.InvalidValue;
    try check(c.ghostty_mouse_event_set_position(event, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) }));
    // Motion deduplication is disabled, so the sizing pass is side-effect free.
    var needed: usize = 0;
    const result = c.ghostty_mouse_encoder_encode(encoder, event, null, 0, &needed);
    if (result != c.GHOSTTY_OUT_OF_SPACE) try check(result);
    const bytes = try a.alloc(u8, needed);
    errdefer a.free(bytes);
    try check(c.ghostty_mouse_encoder_encode(encoder, event, bytes.ptr, bytes.len, &needed));
    if (current.mouse_pixels and needed != 0) {
        // The pinned backend emits zero-based SGR pixel ordinates. Xterm's
        // wire coordinates are one-based, just like its SGR cell format.
        // Keep backend tracking/button filtering, then correct only ordinates.
        const separator = std.mem.indexOfScalar(u8, bytes, ';') orelse return error.Backend;
        const corrected = try std.fmt.allocPrint(a, "{s};{d};{d}{c}", .{ bytes[0..separator], x + 1, y + 1, bytes[needed - 1] });
        a.free(bytes);
        return corrected;
    }
    return bytes;
}
