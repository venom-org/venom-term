const std = @import("std");
const Vt = @import("vt.zig").Vt;
const a = std.testing.allocator;
const Key = Vt.Input.Key;
const Mouse = Vt.Input.Mouse;
fn key(cp: u21) Key {
    return .{ .codepoint = cp, .text = null, .shifted = null, .base_layout = null, .mods = .{}, .action = .press };
}
fn expectKey(vt: Vt, k: Key, expected: []const u8) !void {
    const bytes = try vt.encodeKey(a, k);
    defer a.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}
fn expectMouse(vt: Vt, m: Mouse, expected: []const u8) !void {
    const bytes = try vt.encodeMouse(a, m, .{});
    defer a.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}
test "keys follow live DECCKM and kitty modes, including snapshot restore" {
    var vt = try Vt.init(a, .{});
    defer vt.deinit();
    const up = key(@backingInt(Vt.Input.NamedKey.up));
    try expectKey(vt, up, "\x1b[A");
    try vt.feed("\x1b[?1h\x1b[?2004h");
    try expectKey(vt, up, "\x1bOA");
    try std.testing.expect((try vt.inputModes()).bracketed_paste);
    try vt.feed("\x1b[>11u");
    var k = key('a');
    try expectKey(vt, k, "\x1b[97u");
    k.action = .release;
    try expectKey(vt, k, "\x1b[97;1:3u");
    const snap = try vt.snapshot(a);
    defer snap.deinit(a);
    var restored = try Vt.restore(a, snap, .{});
    defer restored.deinit();
    try expectKey(restored, k, "\x1b[97;1:3u");
    try std.testing.expectEqualDeep(try vt.inputModes(), try restored.inputModes());
    try vt.feed("\x1b[<u\x1b[?1l\x1b[?2004l");
    try expectKey(vt, k, "");
    try expectKey(vt, up, "\x1b[A");
    try std.testing.expect(!(try vt.inputModes()).bracketed_paste);
}
test "mouse modes filter events and encode pane-relative SGR" {
    var vt = try Vt.init(a, .{});
    defer vt.deinit();
    var m: Mouse = .{ .x = 2, .y = 3, .button = .left, .action = .press, .mods = .{} };
    try expectMouse(vt, m, "");
    try vt.feed("\x1b[?1000h\x1b[?1006h");
    try expectMouse(vt, m, "\x1b[<0;3;4M");
    m.action = .drag;
    try expectMouse(vt, m, "");
    try vt.feed("\x1b[?1002h");
    try expectMouse(vt, m, "\x1b[<32;3;4M");
    m.action = .release;
    try expectMouse(vt, m, "\x1b[<0;3;4m");
    m.button = .wheel_up;
    m.action = .press;
    try expectMouse(vt, m, "\x1b[<64;3;4M");
    m.button = .none;
    m.action = .motion;
    try expectMouse(vt, m, "");
    try vt.feed("\x1b[?1003h");
    try expectMouse(vt, m, "\x1b[<35;3;4M");
}
test "legacy text, modifiers, keypad and modifyOtherKeys" {
    var vt = try Vt.init(a, .{});
    defer vt.deinit();
    try expectKey(vt, key('é'), "é");
    var k = key('c');
    k.mods.ctrl = true;
    k.text = "\x03";
    try expectKey(vt, k, "\x03");
    k = key('x');
    k.mods.alt = true;
    try expectKey(vt, k, "\x1bx");
    k = key('a');
    k.mods.shift = true;
    k.shifted = 'A';
    try expectKey(vt, k, "A");
    try vt.feed("\x1b[>4;2m");
    k.mods.ctrl = true;
    try expectKey(vt, k, "\x1b[27;6;65~");
    try vt.feed("\x1b[>4;0m\x1b[?1035l\x1b=");
    k = key('1');
    k.keypad = .one;
    try expectKey(vt, k, "\x1bOq");
    try vt.feed("\x1b>");
    try expectKey(vt, k, "1");
}
test "kitty alternates associated text and repeat" {
    var vt = try Vt.init(a, .{});
    defer vt.deinit();
    try vt.feed("\x1b[>31u");
    var k = key('a');
    k.shifted = 'A';
    k.mods.shift = true;
    try expectKey(vt, k, "\x1b[97:65;2;65u");
    k.action = .repeat;
    try expectKey(vt, k, "\x1b[97:65;2:2;65u");
    k.action = .release;
    try expectKey(vt, k, "\x1b[97:65;2:3u");
}
test "pixel mouse geometry, errors and restored tracking after resize" {
    var vt = try Vt.init(a, .{ .cols = 10, .rows = 10 });
    defer vt.deinit();
    try vt.feed("\x1b[?1000h\x1b[?1016h");
    const m: Mouse = .{ .x = 2, .y = 3, .button = .left, .action = .press, .mods = .{ .ctrl = true, .alt = true, .shift = true } };
    try std.testing.expectError(error.Unavailable, vt.encodeMouse(a, m, .{}));
    const bytes = try vt.encodeMouse(a, m, .{ .cell_width = 8, .cell_height = 16 });
    defer a.free(bytes);
    try std.testing.expectEqualStrings("\x1b[<28;17;49M", bytes);
    const precise = try vt.encodeMouse(a, m, .{ .cell_width = 8, .cell_height = 16, .pixel = .{ .x = 19, .y = 52 } });
    defer a.free(precise);
    try std.testing.expectEqualStrings("\x1b[<28;20;53M", precise);
    try vt.resize(20, 20);
    const snap = try vt.snapshot(a);
    defer snap.deinit(a);
    var restored = try Vt.restore(a, snap, .{});
    defer restored.deinit();
    const again = try restored.encodeMouse(a, m, .{ .cell_width = 8, .cell_height = 16 });
    defer a.free(again);
    try std.testing.expectEqualStrings(bytes, again);
    try vt.feed("\x1bc");
    try std.testing.expect(!(try vt.inputModes()).mouse_tracking);
    var unsupported = key('x');
    unsupported.mods.hyper = true;
    try std.testing.expectError(error.Unavailable, vt.encodeKey(a, unsupported));
}

test "effective mouse format follows the last format change rather than stale DEC bits" {
    var vt = try Vt.init(a, .{});
    defer vt.deinit();
    const m: Mouse = .{ .x = 0, .y = 0, .button = .left, .action = .press, .mods = .{} };
    try vt.feed("\x1b[?1000h\x1b[?1016h");
    try std.testing.expect((try vt.inputModes()).mouse_pixels);
    try vt.feed("\x1b[?1006h");
    try std.testing.expect(!(try vt.inputModes()).mouse_pixels);
    try expectMouse(vt, m, "\x1b[<0;1;1M");
    try vt.feed("\x1b[?1016h\x1b[?1006l");
    try std.testing.expect(!(try vt.inputModes()).mouse_pixels);
    try expectMouse(vt, m, "\x1b[M !!");
}
test "legacy mouse formats, invalid coordinates and pixel boundary" {
    var vt = try Vt.init(a, .{ .cols = 10, .rows = 10 });
    defer vt.deinit();
    var m: Mouse = .{ .x = 2, .y = 3, .button = .left, .action = .press, .mods = .{} };
    try vt.feed("\x1b[?9h");
    try expectMouse(vt, m, "\x1b[M #$");
    m.action = .release;
    try expectMouse(vt, m, "");
    try vt.feed("\x1b[?1000h\x1b[?1015h");
    m.action = .press;
    try expectMouse(vt, m, "\x1b[32;3;4M");
    try vt.feed("\x1b[?1005h");
    try expectMouse(vt, m, "\x1b[M #$");
    m.x = -1;
    try std.testing.expectError(error.InvalidValue, vt.encodeMouse(a, m, .{}));
    m.x = 10;
    try std.testing.expectError(error.InvalidValue, vt.encodeMouse(a, m, .{}));
    m.x = 9;
    m.y = 9;
    try vt.feed("\x1b[?1016h");
    const bytes = try vt.encodeMouse(a, m, .{ .cell_width = 8, .cell_height = 16, .pixel = .{ .x = 79, .y = 159 } });
    defer a.free(bytes);
    try std.testing.expectEqualStrings("\x1b[<0;80;160M", bytes);
}
fn encodeWithFailures(allocator: std.mem.Allocator) !void {
    var vt = try Vt.init(allocator, .{});
    defer vt.deinit();
    const k = try vt.encodeKey(allocator, key('x'));
    defer allocator.free(k);
    try vt.feed("\x1b[?1000h\x1b[?1016h");
    const m: Mouse = .{ .x = 0, .y = 0, .button = .left, .action = .press, .mods = .{} };
    const bytes = try vt.encodeMouse(allocator, m, .{ .cell_width = 8, .cell_height = 16 });
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("\x1b[<0;1;1M", bytes);
}
test "encoding frees temporary backend objects and results on allocation failure" {
    try std.testing.checkAllAllocationFailures(a, encodeWithFailures, .{});
}
test "kitty functional keys never leak as text into legacy panes" {
    var vt = try Vt.init(a, .{});
    defer vt.deinit();
    // A host reporting all keys sends a bare left Control as CSI 57442;5u.
    var ctrl = key(57442);
    ctrl.mods.ctrl = true;
    try expectKey(vt, ctrl, "");
    ctrl.action = .release;
    try expectKey(vt, ctrl, "");
    for ([_]u21{ 57441, 57443, 57444, 57445, 57446, 57447, 57448, 57449, 57450, 57451, 57452, 57453, 57454, 57358, 57360, 57428, 57440 }) |cp| {
        try expectKey(vt, key(cp), "");
    }
    // Requested by the pane: report all keys (flag 8) and event types (2).
    try vt.feed("\x1b[>10u");
    ctrl.action = .press;
    try expectKey(vt, ctrl, "\x1b[57442;5u");
    ctrl.action = .release;
    try expectKey(vt, ctrl, "\x1b[57442;5:3u");
    var shift = key(57447);
    shift.mods.shift = true;
    try expectKey(vt, shift, "\x1b[57447;2u");
    try expectKey(vt, key(57376), "\x1b[57376u"); // F13
    // Disambiguate only: modifier keys stay silent.
    try vt.feed("\x1b[<u\x1b[>1u");
    ctrl.action = .press;
    try expectKey(vt, ctrl, "");
}

test "Shift that made the text is consumed, so a disambiguate pane gets the text" {
    var vt = try Vt.init(a, .{});
    defer vt.deinit();
    const Case = struct { cp: u21, shifted: u21, text: ?[]const u8 };
    const cases = [_]Case{
        .{ .cp = ';', .shifted = ':', .text = ":" },
        .{ .cp = ';', .shifted = ':', .text = null },
        .{ .cp = '5', .shifted = '%', .text = "%" },
        .{ .cp = 'a', .shifted = 'A', .text = "A" },
    };
    const want = [_][]const u8{ ":", ":", "%", "A" };
    // Disambiguate only (nvim's CSI >1u), and with alternate keys too.
    for ([_][]const u8{ "\x1b[>1u", "\x1b[=5u" }) |flags| {
        try vt.feed(flags);
        for (cases, want) |case, w| {
            var k = key(case.cp);
            k.shifted = case.shifted;
            k.text = case.text;
            k.mods.shift = true;
            try expectKey(vt, k, w);
        }
    }
    // Report all keys still reports Shift and the alternate.
    try vt.feed("\x1b[=13u");
    var k = key(';');
    k.shifted = ':';
    k.text = ":";
    k.mods.shift = true;
    try expectKey(vt, k, "\x1b[59:58;2u");
    // Ctrl+Shift is a chord, not text: Shift stays reported.
    try vt.feed("\x1b[=1u");
    var chord = key('a');
    chord.shifted = 'A';
    chord.mods = .{ .shift = true, .ctrl = true };
    try expectKey(vt, chord, "\x1b[97;6u");
    // Legacy panes are unchanged.
    try vt.feed("\x1b[=0u");
    try expectKey(vt, k, ":");
}
