const std = @import("std");
const vaxis = @import("vaxis");
/// Parser for caller-buffered input. No upstream type crosses the API.
pub const Input = struct {
    storage: [@sizeOf(vaxis.Parser)]u8 align(@alignOf(vaxis.Parser)) = @splat(0),
    probing: bool = false,
    pub const Modifiers = @import("types").Input.Modifiers;
    pub const Keypad = @import("types").Input.Keypad;
    pub const Key = @import("types").Input.Key;
    pub const NamedKey = @import("types").Input.NamedKey;
    pub const Mouse = @import("types").Input.Mouse;
    pub const Event = union(enum) {
        key: Key,
        mouse: Mouse,
        mouse_leave,
        focus: bool,
        paste_start,
        paste_end,
        resize: struct { cols: u16, rows: u16, pixel_width: u16, pixel_height: u16 },
    };
    pub const Result = struct { consumed: usize, event: ?Event };
    pub fn beginProbe(self: *Input) void {
        self.probing = true;
    }
    pub fn endProbe(self: *Input) void {
        self.probing = false;
    }
    /// Empty/incomplete input consumes zero bytes. Retain the suffix and retry.
    /// A lone ESC is emitted immediately; callers apply their own ESC timeout.
    /// Key text is borrowed until the next parse or caller-buffer mutation.
    pub fn parse(self: *Input, bytes: []const u8) !Result {
        if (bytes.len == 0) return .{ .consumed = 0, .event = null };
        if (legacyControl(bytes)) |control| return control;
        if (bytes[0] >= 0xc0) {
            const needed = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return error.InvalidUTF8;
            if (bytes.len < needed) return .{ .consumed = 0, .event = null };
        }
        const parser: *vaxis.Parser = @ptrCast(@alignCast(&self.storage));
        const result = try parser.parse(bytes, null);
        const ev = result.event orelse return .{ .consumed = result.n, .event = null };
        const event: ?Event = switch (ev) {
            .cap_da1 => blk: {
                self.endProbe();
                break :blk null;
            },
            .key_press, .key_release => |k| blk: {
                if (self.probing and ev == .key_press and k.codepoint == vaxis.Key.f3 and @as(u8, @bitCast(k.mods)) == 0) break :blk null;
                break :blk .{ .key = .{ .codepoint = normalizeKey(k.codepoint), .text = k.text, .shifted = k.shifted_codepoint, .base_layout = k.base_layout_codepoint, .mods = .{ .shift = k.mods.shift, .alt = k.mods.alt, .ctrl = k.mods.ctrl, .super = k.mods.super, .hyper = k.mods.hyper, .meta = k.mods.meta, .caps_lock = k.mods.caps_lock, .num_lock = k.mods.num_lock }, .keypad = keypad(k.codepoint), .action = if (ev == .key_release) .release else if (isRepeat(bytes[0..result.n])) .repeat else .press } };
            },
            .mouse => |m| .{ .mouse = .{ .x = m.col, .y = m.row, .button = switch (m.button) {
                .left => .left,
                .middle => .middle,
                .right => .right,
                .none => .none,
                .wheel_up => .wheel_up,
                .wheel_down => .wheel_down,
                .wheel_left => .wheel_left,
                .wheel_right => .wheel_right,
                else => .extra,
            }, .action = @fromBackingInt(@intCast(@backingInt(m.type))), .mods = .{ .shift = m.mods.shift, .alt = m.mods.alt, .ctrl = m.mods.ctrl } } },
            .mouse_leave => .mouse_leave,
            .focus_in => .{ .focus = true },
            .focus_out => .{ .focus = false },
            .paste_start => .paste_start,
            .paste_end => .paste_end,
            .winsize => |s| .{ .resize = .{ .cols = s.cols, .rows = s.rows, .pixel_width = s.x_pixel, .pixel_height = s.y_pixel } },
            else => null,
        };
        return .{ .consumed = result.n, .event = event };
    }
};
// Upstream reports Ctrl+\\ Ctrl+] Ctrl+^ Ctrl+_ as a bare control codepoint and
// the ESC-prefixed control bytes of Ctrl+Alt+<key> as Alt with that byte, which
// are no key: a pane's encoder drops some of them and misnames the rest for a
// Kitty pane, and a table can't match them. Report what was pressed. Backspace
// (0x08), Tab, Enter and Escape are themselves; upstream names all but ESC 0x08,
// which stays as it came so that a legacy pane gets the host's byte (`fromKey`
// reads it as Alt+Backspace).
fn legacyControl(bytes: []const u8) ?Input.Result {
    const alt = bytes[0] == 0x1b;
    if (alt and bytes.len == 1) return null;
    const byte = if (alt) bytes[1] else bytes[0];
    const name: u21 = switch (byte) {
        0x00 => if (alt) ' ' else return null,
        0x01...0x07, 0x0a...0x0c, 0x0e...0x1a => if (alt) byte + @as(u21, 0x60) else return null,
        0x1c...0x1f => byte + @as(u21, 0x40),
        else => return null,
    };
    const key: Input.Key = .{ .codepoint = name, .text = null, .shifted = null, .base_layout = null, .mods = .{ .ctrl = true, .alt = alt }, .action = .press };
    return .{ .consumed = if (alt) 2 else 1, .event = .{ .key = key } };
}
// Upstream currently folds Kitty repeats into key_press. Recover the event
// subtype from the modifier parameter of the already parsed CSI key event.
fn isRepeat(bytes: []const u8) bool {
    if (bytes.len < 3 or !std.mem.startsWith(u8, bytes, "\x1b[")) return false;
    var params = std.mem.splitScalar(u8, bytes[2 .. bytes.len - 1], ';');
    _ = params.next();
    const modifier = params.next() orelse return false;
    const colon = std.mem.indexOfScalar(u8, modifier, ':') orelse return false;
    return std.mem.eql(u8, modifier[colon + 1 ..], "2");
}
const keypad_names = .{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "enter", "decimal", "add", "subtract", "multiply", "divide", "equal" };
const keypad_values = .{ Input.Keypad.zero, Input.Keypad.one, Input.Keypad.two, Input.Keypad.three, Input.Keypad.four, Input.Keypad.five, Input.Keypad.six, Input.Keypad.seven, Input.Keypad.eight, Input.Keypad.nine, Input.Keypad.enter, Input.Keypad.decimal, Input.Keypad.add, Input.Keypad.subtract, Input.Keypad.multiply, Input.Keypad.divide, Input.Keypad.equal };
const keypad_codepoints = .{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 13, '.', '+', '-', '*', '/', '=' };
fn keypad(cp: u21) ?Input.Keypad {
    inline for (keypad_names, keypad_values) |name, value| {
        if (cp == @field(vaxis.Key, "kp_" ++ name)) return value;
    }
    return null;
}
fn normalizeKey(cp: u21) u21 {
    inline for (keypad_names, keypad_codepoints) |name, value| {
        if (cp == @field(vaxis.Key, "kp_" ++ name)) return value;
    }
    inline for (.{ "escape", "enter", "tab", "backspace", "up", "down", "left", "right", "home", "end", "insert", "delete", "page_up", "page_down", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12" }) |name| {
        if (cp == @field(vaxis.Key, name)) return @backingInt(@field(Input.NamedKey, name));
    }
    // Other backend function keys are intentionally unrepresented in v0.
    return if (cp <= 0x10ffff) cp else 0xfffd;
}
test "input keys mouse and startup CPR filter" {
    var input: Input = .{};
    input.beginProbe();
    try std.testing.expectEqual(@as(?Input.Event, null), (try input.parse("\x1b[1;1R")).event);
    input.endProbe();
    const key = (try input.parse("\x1b[1;1R")).event.?.key;
    try std.testing.expectEqual(@backingInt(Input.NamedKey.f3), key.codepoint);
    const ctrl = (try input.parse("\x01")).event.?.key;
    try std.testing.expect(ctrl.mods.ctrl);
    const mouse = (try input.parse("\x1b[<0;3;4M")).event.?.mouse;
    try std.testing.expectEqual(@as(i16, 2), mouse.x);
    try std.testing.expectEqual(@as(i16, 3), mouse.y);
    try std.testing.expectEqual(@as(usize, 0), (try input.parse("\x1b[<0;")).consumed);
}

test "normalized kitty repeats and keypad identity reach the headless encoder" {
    var input: Input = .{};
    const repeat = (try input.parse("\x1b[97;1:2u")).event.?.key;
    try std.testing.expectEqual(.repeat, repeat.action);
    const kp = (try input.parse("\x1b[57400u")).event.?.key;
    try std.testing.expectEqual(Input.Keypad.one, kp.keypad.?);
    try std.testing.expectEqual(@as(u21, '1'), kp.codepoint);
    var vt = try @import("vt").Vt.init(std.testing.allocator, .{});
    defer vt.deinit();
    try vt.feed("\x1b[?1035l\x1b=");
    const bytes = try vt.encodeKey(std.testing.allocator, kp);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("\x1bOq", bytes);
}

test "a bare modifier from a report-all-keys host encodes to nothing for a legacy pane" {
    var input: Input = .{};
    const ctrl = (try input.parse("\x1b[57442;5u")).event.?.key;
    var vt = try @import("vt").Vt.init(std.testing.allocator, .{});
    defer vt.deinit();
    const bytes = try vt.encodeKey(std.testing.allocator, ctrl);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("", bytes);
}

test "legacy bytes through the parser come back as the chord exactly when legacyDeliverable says so" {
    const keys = @import("chrome").keys;
    const names = "abcdefghijklmnopqrstuvwxyz@[\\]^_?";
    for (names) |name| {
        const byte: u8 = if (name == '?') 0x7f else name & 0x1f;
        for ([_]bool{ false, true }) |alt| {
            const sent: []const u8 = if (alt) &.{ 0x1b, byte } else &.{byte};
            var input: Input = .{};
            const k = (try input.parse(sent)).event.?.key;
            const got = keys.fromKey(k.codepoint, .{ .ctrl = k.mods.ctrl, .alt = k.mods.alt, .shift = k.mods.shift, .super = k.mods.super }, k.shifted, k.text);
            var want: keys.Chord = keys.parseChord(&.{ 'c', 't', 'r', 'l', '+', name }).?;
            want.mods.alt = alt;
            std.testing.expectEqual(keys.legacyDeliverable(want), got.eql(want)) catch |err| {
                std.debug.print("ctrl{s}+{c}: got cp={d} ctrl={} alt={}\n", .{ if (alt) "+alt" else "", name, got.cp, got.mods.ctrl, got.mods.alt });
                return err;
            };
        }
    }
    // Alt+Enter, Alt+Tab and Alt+Backspace stay themselves.
    var input: Input = .{};
    for ([_][]const u8{ "\x1b\x0d", "\x1b\x09", "\x1b\x08", "\x1b\x7f", "\x1b\x01" }, [_][]const u8{ "alt+enter", "alt+tab", "alt+backspace", "alt+backspace", "ctrl+alt+a" }) |sent, name| {
        const k = (try input.parse(sent)).event.?.key;
        try std.testing.expect(keys.fromKey(k.codepoint, .{ .ctrl = k.mods.ctrl, .alt = k.mods.alt, .shift = k.mods.shift, .super = k.mods.super }, k.shifted, k.text).eql(keys.parseChord(name).?));
    }
}

test "legacy control bytes reach a legacy pane unchanged and a Kitty pane as the key" {
    const cases = [_]struct { sent: []const u8, chord: []const u8, kitty: []const u8 }{
        .{ .sent = "\x1c", .chord = "ctrl+\\", .kitty = "\x1b[92;5u" },
        .{ .sent = "\x1d", .chord = "ctrl+]", .kitty = "\x1b[93;5u" },
        .{ .sent = "\x1e", .chord = "ctrl+^", .kitty = "\x1b[94;5u" },
        .{ .sent = "\x1f", .chord = "ctrl+_", .kitty = "\x1b[95;5u" },
        .{ .sent = "\x1b\x00", .chord = "ctrl+alt+space", .kitty = "\x1b[32;7u" },
        .{ .sent = "\x1b\x01", .chord = "ctrl+alt+a", .kitty = "\x1b[97;7u" },
        .{ .sent = "\x1b\x1a", .chord = "ctrl+alt+z", .kitty = "\x1b[122;7u" },
        .{ .sent = "\x1b\x1c", .chord = "ctrl+alt+\\", .kitty = "\x1b[92;7u" },
    };
    const keys = @import("chrome").keys;
    const a = std.testing.allocator;
    for (cases) |case| {
        var input: Input = .{};
        const r = try input.parse(case.sent);
        try std.testing.expectEqual(case.sent.len, r.consumed);
        const k = r.event.?.key;
        try std.testing.expect(k.mods.ctrl);
        try std.testing.expectEqual(@as(?[]const u8, null), k.text);
        try std.testing.expect(keys.fromKey(k.codepoint, .{ .ctrl = k.mods.ctrl, .alt = k.mods.alt, .shift = k.mods.shift, .super = k.mods.super }, k.shifted, k.text).eql(keys.parseChord(case.chord).?));
        var vt = try @import("vt").Vt.init(a, .{});
        defer vt.deinit();
        const legacy = try vt.encodeKey(a, k);
        defer a.free(legacy);
        try std.testing.expectEqualStrings(case.sent, legacy);
        try vt.feed("\x1b[>1u");
        const kitty = try vt.encodeKey(a, k);
        defer a.free(kitty);
        try std.testing.expectEqualStrings(case.kitty, kitty);
    }
}

test "every legacy control byte reaches a legacy pane unchanged, with or without ESC" {
    const a = std.testing.allocator;
    var vt = try @import("vt").Vt.init(a, .{});
    defer vt.deinit();
    var byte: u8 = 0;
    while (byte <= 0x7f) : (byte += 1) {
        if (byte >= 0x20 and byte < 0x7f) continue;
        // Bare 0x08 is the Backspace key, which sends DEL.
        const pairs = [_][]const u8{ if (byte == 0x1b or byte == 0x08) "" else &.{byte}, &.{ 0x1b, byte } };
        for (pairs) |sent| {
            if (sent.len == 0) continue;
            var input: Input = .{};
            const bytes = try vt.encodeKey(a, (try input.parse(sent)).event.?.key);
            defer a.free(bytes);
            try std.testing.expectEqualStrings(sent, bytes);
        }
    }
}

test "a control byte after other input and a Kitty report keep their own meaning" {
    var input: Input = .{};
    // A lone ESC stays for the caller's timeout; CSI and SS3 are not Alt+key.
    try std.testing.expectEqual(@backingInt(Input.NamedKey.escape), (try input.parse("\x1b")).event.?.key.codepoint);
    try std.testing.expectEqual(@backingInt(Input.NamedKey.up), (try input.parse("\x1b[A")).event.?.key.codepoint);
    const r = try input.parse("\x1c\x1d");
    try std.testing.expectEqual(@as(usize, 1), r.consumed);
    try std.testing.expectEqual(@as(u21, '\\'), r.event.?.key.codepoint);
    const kitty = (try input.parse("\x1b[92;5u")).event.?.key;
    try std.testing.expectEqual(@as(u21, '\\'), kitty.codepoint);
    try std.testing.expect(kitty.mods.ctrl);
    // Kitty release of the same key is still a release.
    try std.testing.expectEqual(.release, (try input.parse("\x1b[92;5:3u")).event.?.key.action);
}

test "a non-Latin Kitty key carries its Latin base" {
    var input: Input = .{};
    const k = (try input.parse("\x1b[945::97;5u")).event.?.key;
    try std.testing.expectEqual(@as(u21, 945), k.codepoint);
    try std.testing.expectEqual(@as(?u21, 'a'), k.base_layout);
    try std.testing.expect(k.mods.ctrl);
}
