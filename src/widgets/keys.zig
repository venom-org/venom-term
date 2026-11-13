//! Key matching helpers and focus routing between widgets.
const std = @import("std");
const Input = @import("types").Input;
const Key = Input.Key;
const NamedKey = Input.NamedKey;
const Mouse = Input.Mouse;
const Region = @import("types").Region;
const layout = @import("layout.zig");

/// A press or auto-repeat; releases are ignored by every widget.
pub fn pressed(key: Key) bool {
    return key.action != .release;
}

fn noCommandMods(key: Key) bool {
    return !key.mods.ctrl and !key.mods.alt and !key.mods.super and !key.mods.hyper and !key.mods.meta;
}

/// A named key (arrows, enter, tab, …) with no modifiers.
pub fn named(key: Key, name: NamedKey) bool {
    return pressed(key) and key.codepoint == @backingInt(name) and noCommandMods(key) and !key.mods.shift;
}

/// A named key with any modifiers.
pub fn namedAny(key: Key, name: NamedKey) bool {
    return pressed(key) and key.codepoint == @backingInt(name);
}

/// A plain character key (shift allowed, as for `E`).
pub fn char(key: Key, cp: u21) bool {
    if (!pressed(key) or !noCommandMods(key)) return false;
    if (key.codepoint == cp) return true;
    // Kitty reports `E` as `e` + shift with a shifted codepoint.
    return key.mods.shift and key.shifted != null and key.shifted.? == cp;
}

/// Ctrl + a letter, as the legacy parser reports it (`ctrl` + lowercase).
pub fn ctrl(key: Key, cp: u21) bool {
    return pressed(key) and key.mods.ctrl and !key.mods.alt and key.codepoint == cp;
}

/// Alt + a key.
pub fn alt(key: Key, cp: u21) bool {
    return pressed(key) and key.mods.alt and !key.mods.ctrl and key.codepoint == cp;
}

/// Focus among `count` widgets in a fixed order. Tab moves forward and
/// Shift-Tab back; products may also call `next`/`prev`/`set` from their
/// own bindings. Focus is per client and never broadcast.
pub const FocusRing = struct {
    count: usize,
    index: usize = 0,

    pub fn next(self: *FocusRing) void {
        if (self.count == 0) return;
        self.index = (self.index + 1) % self.count;
    }
    pub fn prev(self: *FocusRing) void {
        if (self.count == 0) return;
        self.index = (self.index + self.count - 1) % self.count;
    }
    pub fn set(self: *FocusRing, index: usize) void {
        if (index < self.count) self.index = index;
    }
    pub fn is(self: FocusRing, index: usize) bool {
        return self.index == index;
    }
    /// Handles Tab / Shift-Tab. Returns true when focus moved.
    pub fn handleKey(self: *FocusRing, key: Key) bool {
        if (!pressed(key) or key.codepoint != @backingInt(NamedKey.tab) or !noCommandMods(key)) return false;
        if (key.mods.shift) self.prev() else self.next();
        return true;
    }
    /// Click to focus: a left press inside `regions[i]` (one per widget, in
    /// ring order, as last drawn) focuses widget `i`. Returns the index hit,
    /// so the product can pass the click on to that widget.
    pub fn handleMouse(self: *FocusRing, mouse: Mouse, regions: []const Region) ?usize {
        if (mouse.button != .left or mouse.action != .press) return null;
        for (regions[0..@min(regions.len, self.count)], 0..) |r, i| {
            if (layout.hit(r, mouse.x, mouse.y) != null) {
                self.index = i;
                return i;
            }
        }
        return null;
    }
};

pub fn testKey(cp: u21, mods: Input.Modifiers) Key {
    return .{ .codepoint = cp, .text = null, .shifted = null, .base_layout = null, .mods = mods, .action = .press };
}

pub fn testNamed(name: NamedKey) Key {
    return testKey(@backingInt(name), .{});
}

pub fn testMouse(x: i16, y: i16, button: @FieldType(Mouse, "button")) Mouse {
    return .{ .x = x, .y = y, .button = button, .action = .press, .mods = .{} };
}

test "focus ring cycles with tab and shift-tab" {
    var ring: FocusRing = .{ .count = 3 };
    try std.testing.expect(ring.handleKey(testNamed(.tab)));
    try std.testing.expect(ring.is(1));
    try std.testing.expect(ring.handleKey(testKey(@backingInt(NamedKey.tab), .{ .shift = true })));
    try std.testing.expect(ring.handleKey(testKey(@backingInt(NamedKey.tab), .{ .shift = true })));
    try std.testing.expect(ring.is(2));
    try std.testing.expect(!ring.handleKey(testKey('a', .{})));
    try std.testing.expect(!ring.handleKey(testKey(@backingInt(NamedKey.tab), .{ .ctrl = true })));
    var release = testNamed(.tab);
    release.action = .release;
    try std.testing.expect(!ring.handleKey(release));
    try std.testing.expect(char(testKey('j', .{}), 'j'));
    try std.testing.expect(!char(testKey('j', .{ .ctrl = true }), 'j'));
    try std.testing.expect(ctrl(testKey('a', .{ .ctrl = true }), 'a'));
}

test "focus ring focuses the clicked region" {
    var ring: FocusRing = .{ .count = 2 };
    const regions = [_]Region{ .{ .width = 10, .height = 5 }, .{ .x = 10, .width = 10, .height = 5 } };
    try std.testing.expectEqual(@as(?usize, 1), ring.handleMouse(testMouse(12, 3, .left), &regions));
    try std.testing.expect(ring.is(1));
    try std.testing.expect(ring.handleMouse(testMouse(12, 3, .wheel_up), &regions) == null);
    var release = testMouse(2, 2, .left);
    release.action = .release;
    try std.testing.expect(ring.handleMouse(release, &regions) == null);
    try std.testing.expect(ring.handleMouse(testMouse(30, 3, .left), &regions) == null);
    try std.testing.expectEqual(@as(?usize, 0), ring.handleMouse(testMouse(0, 0, .left), &regions));
    try std.testing.expect(ring.is(0));
}
