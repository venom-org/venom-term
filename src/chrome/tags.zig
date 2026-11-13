//! Pane tags: the syntax both the daemon and every presentation
//! client check, an owned tag map, and `when` matching for segments, key
//! tables and presets.
const std = @import("std");
const Value = std.json.Value;
const eq = std.mem.eql;

pub const max_tags = 16;
/// One `key = value` pair. The wire format has no map type, so a tag map
/// is an array of pairs on the wire, sorted by key.
pub const Tag = struct { key: []const u8, value: []const u8 };

/// `[a-z][a-z0-9_.-]{0,31}`
pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 32 or !std.ascii.isLower(key[0])) return false;
    for (key[1..]) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '.' or ch == '-')) return false;
    return true;
}
/// UTF-8 of `min`..`max` bytes with no C0/C1 control characters or DEL.
pub fn validText(text: []const u8, min: usize, max: usize) bool {
    if (text.len < min or text.len > max) return false;
    const view = std.unicode.Utf8View.init(text) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return false;
    return true;
}
pub fn validValue(value: []const u8) bool {
    return validText(value, 1, 128);
}

/// True when every `when` pair is in `have` with the same value. An empty
/// filter always matches.
pub fn matches(have: []const Tag, when: []const Tag) bool {
    for (when) |w| {
        const v = for (have) |t| {
            if (eq(u8, t.key, w.key)) break t.value;
        } else return false;
        if (!eq(u8, v, w.value)) return false;
    }
    return true;
}

const matchAll = matches;

/// An owned tag map, sorted by key.
pub const Tags = struct {
    items: std.ArrayList(Tag) = .empty,

    pub fn deinit(self: *Tags, a: std.mem.Allocator) void {
        for (self.items.items) |t| {
            a.free(t.key);
            a.free(t.value);
        }
        self.items.deinit(a);
        self.* = .{};
    }
    pub fn slice(self: *const Tags) []const Tag {
        return self.items.items;
    }
    pub fn len(self: *const Tags) usize {
        return self.items.items.len;
    }
    pub fn get(self: *const Tags, key: []const u8) ?[]const u8 {
        for (self.items.items) |t| if (eq(u8, t.key, key)) return t.value;
        return null;
    }
    pub fn put(self: *Tags, a: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        for (self.items.items) |*t| if (eq(u8, t.key, key)) {
            const v = try a.dupe(u8, value);
            a.free(t.value);
            t.value = v;
            return;
        };
        var at: usize = 0;
        while (at < self.items.items.len and std.mem.lessThan(u8, self.items.items[at].key, key)) at += 1;
        try self.items.ensureUnusedCapacity(a, 1);
        const k = try a.dupe(u8, key);
        errdefer a.free(k);
        const v = try a.dupe(u8, value);
        self.items.insertAssumeCapacity(at, .{ .key = k, .value = v });
    }
    pub fn remove(self: *Tags, a: std.mem.Allocator, key: []const u8) void {
        for (self.items.items, 0..) |t, i| if (eq(u8, t.key, key)) {
            a.free(t.key);
            a.free(t.value);
            _ = self.items.orderedRemove(i);
            return;
        };
    }
    pub fn clone(self: *const Tags, a: std.mem.Allocator) !Tags {
        var out: Tags = .{};
        errdefer out.deinit(a);
        for (self.items.items) |t| try out.put(a, t.key, t.value);
        return out;
    }
    pub fn same(self: *const Tags, other: *const Tags) bool {
        if (self.items.items.len != other.items.items.len) return false;
        for (self.items.items, other.items.items) |x, y| if (!eq(u8, x.key, y.key) or !eq(u8, x.value, y.value)) return false;
        return true;
    }
    /// True when every `when` pair is present with the same value.
    pub fn matches(self: *const Tags, when: []const Tag) bool {
        return matchAll(self.items.items, when);
    }
    /// Reads either wire shape: the snapshot's `[{"key":…,"value":…}]` list
    /// or an object `{"role":"agent"}` (CLI params, documented examples). `null`
    /// is the empty map.
    pub fn fromValue(a: std.mem.Allocator, v: Value) !Tags {
        var out: Tags = .{};
        errdefer out.deinit(a);
        switch (v) {
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |e| {
                    if (e.value_ptr.* != .string) return error.BadEvent;
                    try out.put(a, e.key_ptr.*, e.value_ptr.string);
                }
            },
            .array => |list| for (list.items) |item| {
                if (item != .object) return error.BadEvent;
                const k = item.object.get("key") orelse return error.BadEvent;
                const val = item.object.get("value") orelse return error.BadEvent;
                if (k != .string or val != .string) return error.BadEvent;
                try out.put(a, k.string, val.string);
            },
            .null => {},
            else => return error.BadEvent,
        }
        return out;
    }
};

const testing = std.testing;
test "tag syntax" {
    try testing.expect(validKey("role") and validKey("a.b-c_9") and !validKey("Role") and !validKey("9a") and !validKey(&@as([33]u8, @splat('a'))));
    try testing.expect(validValue("thread-7") and !validValue("") and !validValue("a\x1bb") and !validValue("\xc2\x85") and !validValue(&@as([129]u8, @splat('x'))));
}
test "tags stay sorted, read both wire shapes and match filters" {
    const a = testing.allocator;
    var tags: Tags = .{};
    defer tags.deinit(a);
    try tags.put(a, "role", "agent");
    try tags.put(a, "group", "g1");
    try tags.put(a, "role", "shell");
    try testing.expectEqualStrings("group", tags.slice()[0].key);
    try testing.expectEqualStrings("shell", tags.get("role").?);
    try testing.expect(tags.matches(&.{.{ .key = "role", .value = "shell" }}));
    try testing.expect(!tags.matches(&.{.{ .key = "role", .value = "agent" }}));
    try testing.expect(tags.matches(&.{}));
    tags.remove(a, "group");
    try testing.expectEqual(@as(usize, 1), tags.len());

    var parsed = try std.json.parseFromSlice(Value, a, "[{\"key\":\"owner\",\"value\":\"venom\"},{\"key\":\"role\",\"value\":\"agent\"}]", .{});
    defer parsed.deinit();
    var have = try Tags.fromValue(a, parsed.value);
    defer have.deinit(a);
    var w = try std.json.parseFromSlice(Value, a, "{\"owner\":\"venom\"}", .{});
    defer w.deinit();
    var when = try Tags.fromValue(a, w.value);
    defer when.deinit(a);
    try testing.expect(have.matches(when.slice()));
    try when.put(a, "owner", "venom-os");
    try testing.expect(!have.matches(when.slice()));
    var copy = try have.clone(a);
    defer copy.deinit(a);
    try testing.expect(copy.same(&have));
    try testing.expectError(error.BadEvent, Tags.fromValue(a, .{ .integer = 1 }));
}
