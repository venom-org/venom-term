//! Key tables, client and daemon side: chord syntax, layered
//! tables with precedence by layer, conflicts and shadows, `when` scoping,
//! placeholders, labels and groups, `keys.prefixes`, the JSON form
//! `keys.list` reports, and the per-client leader/lock/timeout state machine
//! (including sticky groups). No terminal I/O: chords are plain
//! values so every client and the daemon resolve the same way.
//!
//! The client intercepts only the leader (and, in lock mode, the unlock
//! key). Everything bound lives in tables under the leader. Layers, highest
//! first: user config, the defaults file, registered product tables,
//! built-in. Each product supplies its own local commands and built-in
//! table through `Tables(Local, hooks)`.
const std = @import("std");
const tags = @import("tags.zig");
const NamedKey = @import("types").Input.NamedKey;
const Tag = tags.Tag;
const Value = std.json.Value;
const eq = std.mem.eql;

// ------------------------------------------------------------------ chords

pub const Mods = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
};
/// One key with modifiers, normalized so legacy and Kitty input of the same
/// key compare equal: a shifted character is the character itself (`%`,
/// `O`), legacy `ctrl+@` (NUL) is `ctrl+space`, and a legacy control byte is
/// Ctrl plus its key (`fromKey`).
pub const Chord = struct {
    cp: u21,
    mods: Mods = .{},
    pub fn eql(x: Chord, y: Chord) bool {
        return x.cp == y.cp and std.meta.eql(x.mods, y.mods);
    }
    pub fn plain(self: Chord) bool {
        return !self.mods.ctrl and !self.mods.alt and !self.mods.super;
    }
};

/// Named keys past Unicode use venom-term's `Input.NamedKey` values.
pub const named_base: u21 = @backingInt(NamedKey.up);
const Named = struct { name: []const u8, cp: u21 };
const named_keys = blk: {
    var out: []const Named = &.{
        .{ .name = "space", .cp = ' ' },
        .{ .name = "tab", .cp = 9 },
        .{ .name = "enter", .cp = 13 },
        .{ .name = "escape", .cp = 27 },
        .{ .name = "backspace", .cp = 127 },
    };
    const info = @typeInfo(NamedKey).@"enum";
    for (info.field_names, info.field_values) |n, v| {
        if (v >= named_base) out = out ++ &[_]Named{.{ .name = n, .cp = v }};
    }
    break :blk out;
};
const aliases = [_]Named{
    .{ .name = "esc", .cp = 27 },
    .{ .name = "return", .cp = 13 },
    .{ .name = "pageup", .cp = @backingInt(NamedKey.page_up) },
    .{ .name = "pagedown", .cp = @backingInt(NamedKey.page_down) },
    .{ .name = "plus", .cp = '+' },
};

fn namedKey(name: []const u8) ?u21 {
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, name);
    for (named_keys) |n| if (eq(u8, n.name, lower)) return n.cp;
    for (aliases) |n| if (eq(u8, n.name, lower)) return n.cp;
    return null;
}
fn keyName(cp: u21) ?[]const u8 {
    for (named_keys) |n| if (n.cp == cp) return n.name;
    return null;
}

/// Kitty-protocol names joined with `+`: `ctrl+space`, `alt+shift+left`,
/// `%`, `O`, `ctrl++`. Null when the text is not one key.
pub fn parseChord(text: []const u8) ?Chord {
    if (text.len == 0) return null;
    var mods: Mods = .{};
    var key: []const u8 = text;
    if (!eq(u8, text, "+")) {
        const split = if (std.mem.endsWith(u8, text, "++")) text.len - 2 else std.mem.lastIndexOfScalar(u8, text, '+');
        if (split) |at| {
            key = text[at + 1 ..];
            if (at == 0) return null;
            var it = std.mem.splitScalar(u8, text[0..at], '+');
            while (it.next()) |m| {
                const flag: *bool = if (eq(u8, m, "ctrl") or eq(u8, m, "control")) &mods.ctrl else if (eq(u8, m, "alt")) &mods.alt else if (eq(u8, m, "shift")) &mods.shift else if (eq(u8, m, "super")) &mods.super else return null;
                if (flag.*) return null;
                flag.* = true;
            }
        }
    }
    if (key.len == 0) return null;
    var cp: u21 = undefined;
    if (namedKey(key)) |n| {
        cp = n;
    } else {
        const len = std.unicode.utf8ByteSequenceLength(key[0]) catch return null;
        if (len != key.len) return null;
        cp = std.unicode.utf8Decode(key) catch return null;
        if (cp < 0x20 or cp == 0x7f or (cp >= 0x80 and cp < 0xa0)) return null;
    }
    return normalize(.{ .cp = cp, .mods = mods });
}
fn normalize(c: Chord) Chord {
    var out = c;
    // Shift of a letter is the capital letter; Ctrl letters are lowercase.
    if (out.cp < 0x80 and std.ascii.isLower(@intCast(out.cp)) and out.mods.shift and !out.mods.ctrl) {
        out.cp = std.ascii.toUpper(@intCast(out.cp));
        out.mods.shift = false;
    }
    if (out.mods.ctrl and out.cp == '@') out.cp = ' ';
    return out;
}

/// The chord a host key event produced. `shifted` and `text` are the Kitty
/// alternate key and associated text; legacy input reports the character
/// itself. `Input.parse` has already named the legacy control bytes: Ctrl+Space
/// arrives here as `ctrl+@`, and ESC ^A as Ctrl and Alt with `a`. Only ESC 0x08
/// comes as the byte, for the pane's sake: that is Alt+Backspace.
pub fn fromKey(cp: u21, mods: Mods, shifted: ?u21, text: ?[]const u8) Chord {
    var out: Chord = .{ .cp = if (cp == 0x08 and !mods.ctrl) backspace_key.cp else cp, .mods = mods };
    if (mods.shift) {
        if (shifted) |s| {
            out.cp = s;
            out.mods.shift = false;
        } else if (text) |t| if (t.len > 0 and t[0] >= 0x20 and t[0] != 0x7f) {
            const n = std.unicode.utf8ByteSequenceLength(t[0]) catch 0;
            if (n == t.len) if (std.unicode.utf8Decode(t)) |ch| {
                out.cp = ch;
                out.mods.shift = false;
            } else |_| {};
        };
    }
    if (out.mods.ctrl and out.cp == '@') out.cp = ' ';
    return normalize(out);
}

/// Canonical text: modifiers in the order `ctrl+alt+shift+super`, named
/// keys by their venom-term name (`escape`, `page_up`).
pub fn formatChord(w: *std.Io.Writer, c: Chord) !void {
    if (c.mods.ctrl) try w.writeAll("ctrl+");
    if (c.mods.alt) try w.writeAll("alt+");
    if (c.mods.shift) try w.writeAll("shift+");
    if (c.mods.super) try w.writeAll("super+");
    if (keyName(c.cp)) |n| return w.writeAll(n);
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(c.cp, &buf) catch return w.writeAll("?");
    try w.writeAll(buf[0..n]);
}
pub fn chordText(a: std.mem.Allocator, c: Chord) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    formatChord(&out.writer, c) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// A binding's key sequence plus its table's sub-prefix.
pub const max_sequence = 4;
pub const Sequence = struct {
    keys: [max_sequence + 1]Chord = undefined,
    len: u8 = 0,
    pub fn slice(self: *const Sequence) []const Chord {
        return self.keys[0..self.len];
    }
    pub fn push(self: *Sequence, c: Chord) bool {
        if (self.len >= self.keys.len) return false;
        self.keys[self.len] = c;
        self.len += 1;
        return true;
    }
    /// One sequence is a prefix of (or equal to) the other: both cannot be
    /// reachable at once.
    pub fn overlaps(self: *const Sequence, other: *const Sequence) bool {
        const n = @min(self.len, other.len);
        for (self.keys[0..n], other.keys[0..n]) |x, y| if (!x.eql(y)) return false;
        return true;
    }
    pub fn startsWith(self: *const Sequence, head: []const Chord) bool {
        if (head.len > self.len) return false;
        for (self.keys[0..head.len], head) |x, y| if (!x.eql(y)) return false;
        return true;
    }
    pub fn format(self: *const Sequence, w: *std.Io.Writer) !void {
        for (self.slice(), 0..) |c, i| {
            if (i > 0) try w.writeAll(" ");
            try formatChord(w, c);
        }
    }
    pub fn text(self: *const Sequence, a: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();
        self.format(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
};
/// Keys separated by spaces, 1–4 of them.
pub fn parseSequence(text: []const u8) ?Sequence {
    var out: Sequence = .{};
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |part| {
        if (out.len >= max_sequence) return null;
        _ = out.push(parseChord(part) orelse return null);
    }
    return if (out.len == 0) null else out;
}

// --------------------------------------------------------- legacy delivery

/// Whether a terminal without the Kitty keyboard protocol can send this
/// chord at all (doctor reports a leader that needs Kitty). True for a Ctrl
/// chord exactly when `Input.parse` and `fromKey` get the same chord back from
/// those bytes: the bytes of `ctrl+h`, `ctrl+i`, `ctrl+m`, `ctrl+[` and `ctrl+?`
/// are Backspace, Tab, Enter, Escape and Backspace.
pub fn legacyDeliverable(c: Chord) bool {
    if (c.mods.super) return false;
    var base = c;
    base.mods.alt = false; // Alt is an ESC prefix in legacy input.
    if (base.mods.ctrl and base.mods.shift) return false;
    if (base.mods.ctrl) {
        if (base.cp == ' ') return true;
        return switch (base.cp) {
            'h', 'i', 'm' => false,
            'a'...'g', 'j'...'l', 'n'...'z', '\\', ']', '^', '_' => true,
            else => false,
        };
    }
    if (base.mods.shift) return base.cp == 9 or base.cp >= named_base;
    return true;
}
/// The single byte a legacy terminal sends for a Ctrl chord (raw attach).
pub fn legacyByte(c: Chord) ?u8 {
    if (!c.mods.ctrl or c.mods.alt or c.mods.shift or c.mods.super) return null;
    if (c.cp == ' ') return 0;
    if (c.cp >= 'a' and c.cp <= 'z') return @intCast(c.cp - 'a' + 1);
    if (c.cp >= '[' and c.cp <= '_') return @intCast(c.cp - '[' + 0x1b);
    return null;
}

// ------------------------------------------------------------ placeholders

/// `{pane}`, `{window}`, `{session}` of the focused pane and the client's
/// `{popup_ticket}`. Substituted as whole argv elements (and whole
/// JSON string values of verb args) only.
pub const placeholders = [_][]const u8{ "{pane}", "{window}", "{session}", "{popup_ticket}" };
pub const Placeholder = enum(u2) { pane, window, session, popup_ticket };
pub fn placeholder(text: []const u8) ?usize {
    for (placeholders, 0..) |p, i| if (eq(u8, text, p)) return i;
    return null;
}
/// A placeholder spliced into a longer string is refused, never expanded.
pub fn spliced(text: []const u8) bool {
    if (placeholder(text) != null) return false;
    for (placeholders) |p| if (std.mem.indexOf(u8, text, p) != null) return true;
    return false;
}
/// Any string in a JSON value is `spliced`.
pub fn splicedValue(v: Value) bool {
    return switch (v) {
        .string => |s| spliced(s),
        .array => |arr| for (arr.items) |x| {
            if (splicedValue(x)) break true;
        } else false,
        .object => |o| blk: {
            var it = o.iterator();
            while (it.next()) |e| if (splicedValue(e.value_ptr.*)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Placeholder values known to a client; a missing value is substituted as
/// the empty string. Clients that report missing values instead classify
/// elements with `placeholder` themselves.
pub const Placeholders = struct {
    pane: []const u8 = "",
    window: []const u8 = "",
    session: []const u8 = "",
    popup_ticket: []const u8 = "",

    pub fn lookup(self: Placeholders, s: []const u8) ?[]const u8 {
        const i = placeholder(s) orelse return null;
        return switch (@as(Placeholder, @fromBackingInt(@intCast(i)))) {
            .pane => self.pane,
            .window => self.window,
            .session => self.session,
            .popup_ticket => self.popup_ticket,
        };
    }
    /// Substitute whole argv elements only; `x{pane}` stays literal.
    pub fn argv(self: Placeholders, a: std.mem.Allocator, in: []const []const u8) ![]const []const u8 {
        const out = try a.alloc([]const u8, in.len);
        for (in, out) |x, *o| o.* = self.lookup(x) orelse x;
        return out;
    }
    /// Substitute whole JSON string values of verb args (JSON object text),
    /// recursively. Allocates in `a` (an arena).
    pub fn args(self: Placeholders, a: std.mem.Allocator, text: []const u8) !Value {
        var v = try std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always });
        self.walk(&v);
        return v;
    }
    fn walk(self: Placeholders, v: *Value) void {
        switch (v.*) {
            .string => |s| if (self.lookup(s)) |r| {
                v.* = .{ .string = r };
            },
            .array => |*l| for (l.items) |*x| self.walk(x),
            .object => |*o| {
                var it = o.iterator();
                while (it.next()) |e| self.walk(e.value_ptr);
            },
            else => {},
        }
    }
    pub fn needsTicket(argv_in: []const []const u8) bool {
        for (argv_in) |x| if (eq(u8, x, placeholders[3])) return true;
        return false;
    }
};

// ----------------------------------------------------------------- tables

/// Precedence, lowest first.
pub const Layer = enum { builtin, product, defaults, user };
pub const max_bindings = 64;

/// Valid table names: a principal namespace (`[a-z][a-z0-9-]{0,31}`).
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or !std.ascii.isLower(name[0])) return false;
    for (name[1..]) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
    return true;
}

pub const Failure = struct { param: []const u8, reason: []const u8 };
pub fn ParseResult(comptime T: type) type {
    return union(enum) { ok: T, failed: Failure };
}

/// What a binding may be. A ZON or JSON binding record.
pub const BindingConfig = struct {
    key: []const u8 = "",
    local: ?[]const u8 = null,
    verb: ?[]const u8 = null,
    /// The verb schema's wire format and ZON have no open map type, so params of a
    /// `.verb` target are a JSON object written as a string.
    args: ?[]const u8 = null,
    exec: ?[]const []const u8 = null,
    /// What the popup shows; without one, the local action, verb or `argv[0]`.
    label: ?[]const u8 = null,
};
/// `.groups` entry: names an inner prefix of a table. `key` is relative
/// to the table's prefix, and the group's keys come from the bindings under
/// it.
pub const GroupConfig = struct {
    key: []const u8 = "",
    label: []const u8 = "",
    /// Stay in the group after a binding runs, until `esc`.
    sticky: bool = false,
};
/// `keys.tables` entry. `when` is a list of `{ .key, .value }` pairs (no map
/// type in format 1, as for `status.priority`).
pub const TableConfig = struct {
    name: []const u8 = "",
    prefix: ?[]const u8 = null,
    /// Names the sub-prefix in the popup; without one, the table's name.
    label: ?[]const u8 = null,
    when: []const Tag = &.{},
    groups: []const GroupConfig = &.{},
    bind: []const BindingConfig = &.{},
};
/// Labels: 1–40 bytes of UTF-8 with no control characters.
pub const max_label = 40;
pub fn validLabel(text: []const u8) bool {
    return tags.validText(text, 1, max_label);
}
/// A parsed `.groups` entry.
pub const Group = struct {
    /// The key text as written, relative to the table's prefix.
    key: []const u8,
    seq: Sequence,
    label: []const u8,
    sticky: bool = false,
};
/// A built-in group, checked at compile time.
pub fn group(comptime key: []const u8, comptime label: []const u8, comptime sticky: bool) Group {
    if (label.len == 0 or label.len > max_label) @compileError("bad built-in group label: " ++ label);
    return .{ .key = key, .seq = parseSequence(key) orelse @compileError("bad built-in group key: " ++ key), .label = label, .sticky = sticky };
}

/// `esc` cancels and `backspace` goes up one level in leader mode.
const esc_key: Chord = .{ .cp = 27 };
const backspace_key: Chord = .{ .cp = 127 };
/// `?` shows a sticky group's popup again.
const help_key: Chord = .{ .cp = '?' };
/// Keys that leader mode takes for itself, so no binding could ever run:
/// `backspace` anywhere, and `esc` before the last key.
fn unreachableSequence(seq: *const Sequence) bool {
    for (seq.slice(), 0..) |c, i| {
        if (c.eql(backspace_key) or (c.eql(esc_key) and i + 1 < seq.len)) return true;
    }
    return false;
}
fn sameChords(x: []const Chord, y: []const Chord) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!p.eql(q)) return false;
    return true;
}

/// `keys` scalars, parsed. A client sets these from its config: `leader`,
/// `unlock` and `timeout_ms` still default to the values before the key-table change
/// of 2026-11-08 (`ctrl+space`, `ctrl+alt+space`, 2000), not to the new defaults
/// (`ctrl+a`, `ctrl+alt+a`, 0), because venomx and venom-desk read them until `keys.list`
/// answers.
pub const Settings = struct {
    leader: Chord = parseChord("ctrl+space").?,
    unlock: Chord = parseChord("ctrl+alt+space").?,
    /// How long after a key the popup appears; 0 shows it at once.
    popup_delay_ms: u32 = 200,
    /// How long leader mode waits for a key; 0 waits forever.
    timeout_ms: u32 = 2000,
};

// ---------------------------------------------------------- keys.prefixes

/// `keys.prefixes` entry: moves a table to another sub-prefix without
/// restating its bindings.
pub const PrefixConfig = struct {
    name: []const u8 = "",
    prefix: []const u8 = "",
};
pub const Prefix = struct { name: []const u8, prefix: Chord };
/// One layer's `keys.prefixes`. A name given twice in a layer is an error.
pub fn parsePrefixes(a: std.mem.Allocator, config: []const PrefixConfig) !ParseResult([]const Prefix) {
    const out = try a.alloc(Prefix, config.len);
    for (config, out, 0..) |c, *dst, i| {
        if (!validName(c.name)) return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "prefixes.{d}.name", .{i}), .reason = "name" } };
        for (config[0..i]) |before| if (eq(u8, before.name, c.name)) return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "prefixes.{d}.name", .{i}), .reason = "duplicate" } };
        const prefix = parseChord(c.prefix) orelse return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "prefixes.{d}.prefix", .{i}), .reason = "key" } };
        if (prefix.eql(esc_key) or prefix.eql(backspace_key)) return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "prefixes.{d}.prefix", .{i}), .reason = "reserved" } };
        dst.* = .{ .name = try a.dupe(u8, c.name), .prefix = prefix };
    }
    return .{ .ok = out };
}
/// The two layers as one list: the user's entry wins for the same name.
pub fn mergePrefixes(a: std.mem.Allocator, defaults: []const Prefix, user: []const Prefix) ![]const Prefix {
    var out: std.ArrayList(Prefix) = .empty;
    try out.appendSlice(a, user);
    outer: for (defaults) |d| {
        for (user) |u| if (eq(u8, u.name, d.name)) continue :outer;
        try out.append(a, d);
    }
    return out.items;
}
/// The prefix a table named `name` registered with `registered` really has:
/// a move applies only to a table that has a sub-prefix, so a table bound
/// right after the leader stays there.
pub fn effectivePrefix(moves: []const Prefix, name: []const u8, registered: ?Chord) ?Chord {
    if (registered == null) return null;
    for (moves) |m| if (eq(u8, m.name, name)) return m.prefix;
    return registered;
}

/// The `keys` member of one config file, parsed alone: the
/// caller reads the defaults file and the user file and keeps their layers
/// apart. Lists every `keys` config field, because `parseLayerConfig` rejects any
/// other name; a scalar is null when this file does not set it.
pub const LayerConfig = struct {
    leader: ?[]const u8 = null,
    unlock: ?[]const u8 = null,
    popup_delay_ms: ?u32 = null,
    timeout_ms: ?u32 = null,
    tables: []const TableConfig = &.{},
    prefixes: []const PrefixConfig = &.{},
};
/// A field name that is not known anywhere under `keys` fails with its path as
/// `param` and `unknown_field` as `reason` (`keys.tables.0.lable`), for a
/// caller's `config check` to report; other top-level sections belong to the
/// product and are not looked at.
/// `error.Unreadable` when the bytes are not ZON, or `keys` has the wrong
/// shape. Allocates in `a` (an arena).
pub fn parseLayerConfig(a: std.mem.Allocator, bytes: []const u8) error{ OutOfMemory, Unreadable }!ParseResult(LayerConfig) {
    const File = struct { keys: LayerConfig = .{} };
    const src = try a.dupeSentinel(u8, bytes, 0);
    // `ignore_unknown_fields` is all or nothing, and it has to stay on for the
    // sibling sections, so the names under `keys` are checked first.
    const ast = try std.zig.Ast.parse(a, src, .{ .mode = .zon });
    if (ast.errors.len != 0) return error.Unreadable;
    const zoir = try std.zig.ZonGen.generate(a, ast, .{});
    if (zoir.hasCompileErrors()) return error.Unreadable;
    switch (std.zig.Zoir.Node.Index.root.get(&zoir)) {
        .struct_literal => |file| for (file.names, 0..) |name, i| {
            if (!eq(u8, name.get(&zoir), "keys")) continue;
            if (try unknownField(a, LayerConfig, &zoir, file.vals.at(@intCast(i)), "keys")) |param| return .{ .failed = .{ .param = param, .reason = "unknown_field" } };
        },
        else => {},
    }
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const parsed = std.zon.parse.fromSlice(File, .{ .gpa = a, .arena = a, .source = src, .diagnostics = &diagnostics, .ignore_unknown_fields = true }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Unreadable;
    return .{ .ok = parsed.keys };
}
/// The path of the first field under `node` that `T` does not have. A value of
/// the wrong shape is not reported here: the typed parse fails on it.
fn unknownField(a: std.mem.Allocator, comptime T: type, zoir: *const std.zig.Zoir, node: std.zig.Zoir.Node.Index, path: []const u8) error{OutOfMemory}!?[]const u8 {
    switch (@typeInfo(T)) {
        .optional => |o| return unknownField(a, o.child, zoir, node, path),
        .pointer => |p| {
            if (p.child == u8) return null;
            const items = switch (node.get(zoir)) {
                .array_literal => |x| x,
                else => return null,
            };
            for (0..items.len) |i| {
                const at = try std.fmt.allocPrint(a, "{s}.{d}", .{ path, i });
                if (try unknownField(a, p.child, zoir, items.at(@intCast(i)), at)) |found| return found;
            }
        },
        .@"struct" => |s| {
            const lit = switch (node.get(zoir)) {
                .struct_literal => |x| x,
                else => return null,
            };
            names: for (lit.names, 0..) |n, i| {
                const name = n.get(zoir);
                const at = try std.fmt.allocPrint(a, "{s}.{s}", .{ path, name });
                inline for (s.field_names, s.field_types) |field, F| if (eq(u8, name, field)) {
                    if (try unknownField(a, F, zoir, lit.vals.at(@intCast(i)), at)) |found| return found;
                    continue :names;
                };
                return at;
            }
        },
        else => {},
    }
    return null;
}

/// Table activity for `when`; null treats every table as active (reports).
pub const Active = struct {
    ctx: *const anyopaque,
    f: *const fn (*const anyopaque, []const Tag) bool,
    /// Tables whose `when` the focused pane's tags match. An empty filter is
    /// active on any pane (and with no pane focused).
    pub fn matching(t: *const tags.Tags) Active {
        return .{ .ctx = t, .f = struct {
            fn f(ctx: *const anyopaque, when: []const Tag) bool {
                const have: *const tags.Tags = @ptrCast(@alignCast(ctx));
                return have.matches(when);
            }
        }.f };
    }
};

/// What a product plugs into `Tables`: how its local commands are named.
/// `knownVerb` checks `.verb` targets against the product's verb schema;
/// a client that does not know the daemon's schema accepts any name.
pub fn Hooks(comptime Local: type) type {
    return struct {
        parseLocal: *const fn ([]const u8) ?Local,
        localName: *const fn (Local) []const u8,
        knownVerb: *const fn ([]const u8) bool = anyVerb,
    };
}
fn anyVerb(name: []const u8) bool {
    return name.len > 0;
}

/// Tables, resolution and the leader state machine over a product's
/// `Local` command type.
pub fn Tables(comptime Local: type, comptime hooks: Hooks(Local)) type {
    return struct {
        pub const Target = union(enum) {
            local: Local,
            /// A schema verb with its params as JSON object text.
            verb: struct { name: []const u8, args: []const u8 },
            /// An argv the client runs with no shell and no venomx token.
            exec: []const []const u8,

            pub fn eql(x: Target, y: Target) bool {
                return switch (x) {
                    .local => |l| y == .local and std.meta.eql(l, y.local),
                    .verb => |v| y == .verb and eq(u8, v.name, y.verb.name) and eq(u8, v.args, y.verb.args),
                    .exec => |argv| y == .exec and argv.len == y.exec.len and for (argv, y.exec) |p, q| {
                        if (!eq(u8, p, q)) break false;
                    } else true,
                };
            }
            /// What the popup shows for a binding with no label.
            pub fn name(self: Target) []const u8 {
                return switch (self) {
                    .local => |l| hooks.localName(l),
                    .verb => |v| v.name,
                    .exec => |argv| argv[0],
                };
            }
        };
        pub const Binding = struct {
            /// The key text as written.
            key: []const u8,
            seq: Sequence,
            target: Target,
            label: ?[]const u8 = null,

            /// The label, or what stands in for a missing one.
            pub fn text(self: *const Binding) []const u8 {
                return self.label orelse self.target.name();
            }
        };
        pub const Table = struct {
            name: []const u8,
            layer: Layer,
            /// The sub-prefix key; null binds right after the leader.
            prefix: ?Chord = null,
            /// Names the sub-prefix in the popup; null shows `name`.
            label: ?[]const u8 = null,
            when: []const Tag = &.{},
            /// Named inner prefixes, relative to `prefix`.
            groups: []const Group = &.{},
            bindings: []const Binding,
            /// Registering principal (product layer).
            source: ?[]const u8 = null,
        };

        /// A built-in binding, checked at compile time.
        pub fn binding(comptime key: []const u8, comptime target: Target) Binding {
            return .{ .key = key, .seq = parseSequence(key) orelse @compileError("bad built-in key: " ++ key), .target = target };
        }
        /// A built-in binding with a popup label.
        pub fn labeled(comptime key: []const u8, comptime target: Target, comptime label: []const u8) Binding {
            if (label.len == 0 or label.len > max_label) @compileError("bad built-in label: " ++ label);
            var b = binding(key, target);
            b.label = label;
            return b;
        }

        pub fn parseBinding(a: std.mem.Allocator, b: BindingConfig, param: []const u8) !ParseResult(Binding) {
            const seq = parseSequence(b.key) orelse return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "{s}.key", .{param}), .reason = "key" } };
            if (unreachableSequence(&seq)) return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "{s}.key", .{param}), .reason = "reserved" } };
            if (b.label) |l| if (!validLabel(l)) return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "{s}.label", .{param}), .reason = "label" } };
            const given = @as(u8, @intFromBool(b.local != null)) + @intFromBool(b.verb != null) + @intFromBool(b.exec != null);
            if (given != 1 or (b.args != null and b.verb == null)) return .{ .failed = .{ .param = param, .reason = "target" } };
            var target: Target = undefined;
            if (b.local) |name| {
                target = .{ .local = hooks.parseLocal(name) orelse return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "{s}.local", .{param}), .reason = "local" } } };
            } else if (b.verb) |name| {
                if (!hooks.knownVerb(name)) return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "{s}.verb", .{param}), .reason = "verb" } };
                const args = b.args orelse "{}";
                const parsed = std.json.parseFromSliceLeaky(Value, a, args, .{}) catch return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "{s}.args", .{param}), .reason = "args" } };
                if (parsed != .object or splicedValue(parsed)) return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "{s}.args", .{param}), .reason = "args" } };
                target = .{ .verb = .{ .name = try a.dupe(u8, name), .args = try a.dupe(u8, args) } };
            } else {
                const argv = b.exec.?;
                if (argv.len == 0 or argv.len > 64) return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "{s}.exec", .{param}), .reason = "exec" } };
                const out = try a.alloc([]const u8, argv.len);
                for (argv, out, 0..) |arg, *dst, i| {
                    const bad = arg.len == 0 or arg.len > 4096 or std.mem.indexOfScalar(u8, arg, 0) != null or (i == 0 and placeholder(arg) != null);
                    if (bad or spliced(arg)) return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "{s}.exec.{d}", .{ param, i }), .reason = if (bad) "exec" else "placeholder" } };
                    dst.* = try a.dupe(u8, arg);
                }
                target = .{ .exec = out };
            }
            return .{ .ok = .{ .key = try a.dupe(u8, b.key), .seq = seq, .target = target, .label = if (b.label) |l| try a.dupe(u8, l) else null } };
        }

        pub fn parseTable(a: std.mem.Allocator, t: TableConfig, layer: Layer) !ParseResult(Table) {
            if (!validName(t.name)) return .{ .failed = .{ .param = "name", .reason = "name" } };
            const prefix: ?Chord = if (t.prefix) |p| parseChord(p) orelse return .{ .failed = .{ .param = "prefix", .reason = "key" } } else null;
            if (prefix) |p| if (p.eql(esc_key) or p.eql(backspace_key)) return .{ .failed = .{ .param = "prefix", .reason = "reserved" } };
            if (t.label) |l| if (!validLabel(l)) return .{ .failed = .{ .param = "label", .reason = "label" } };
            if (t.when.len > tags.max_tags) return .{ .failed = .{ .param = "when", .reason = "count" } };
            for (t.when) |w| if (!tags.validKey(w.key) or !tags.validValue(w.value)) return .{ .failed = .{ .param = "when", .reason = "tag" } };
            if (t.bind.len > max_bindings) return .{ .failed = .{ .param = "bindings", .reason = "count" } };
            const out = try a.alloc(Binding, t.bind.len);
            for (t.bind, out, 0..) |b, *dst, i| {
                switch (try parseBinding(a, b, try std.fmt.allocPrint(a, "bindings.{d}", .{i}))) {
                    .ok => |x| dst.* = x,
                    .failed => |f| return .{ .failed = f },
                }
            }
            const when = try a.alloc(Tag, t.when.len);
            for (t.when, when) |w, *dst| dst.* = .{ .key = try a.dupe(u8, w.key), .value = try a.dupe(u8, w.value) };
            if (t.groups.len > max_bindings) return .{ .failed = .{ .param = "groups", .reason = "count" } };
            const groups = try a.alloc(Group, t.groups.len);
            for (t.groups, groups, 0..) |g, *dst, i| {
                switch (try parseGroup(a, g, out, groups[0..i], i)) {
                    .ok => |x| dst.* = x,
                    .failed => |f| return .{ .failed = f },
                }
            }
            return .{ .ok = .{ .name = try a.dupe(u8, t.name), .layer = layer, .prefix = prefix, .label = if (t.label) |l| try a.dupe(u8, l) else null, .when = when, .groups = groups, .bindings = out } };
        }
        /// A group names an inner prefix, so it needs a binding under it, and
        /// a key is never both a binding and a prefix.
        fn parseGroup(a: std.mem.Allocator, g: GroupConfig, bindings: []const Binding, before: []const Group, i: usize) !ParseResult(Group) {
            const seq = parseSequence(g.key) orelse return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "groups.{d}.key", .{i}), .reason = "key" } };
            if (!validLabel(g.label)) return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "groups.{d}.label", .{i}), .reason = "label" } };
            const inner = for (bindings) |b| {
                if (b.seq.len > seq.len and b.seq.startsWith(seq.slice())) break true;
            } else false;
            for (before) |x| if (sameChords(x.seq.slice(), seq.slice())) return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "groups.{d}.key", .{i}), .reason = "duplicate" } };
            if (!inner) return .{ .failed = .{ .param = try std.fmt.allocPrint(a, "groups.{d}.key", .{i}), .reason = "group" } };
            return .{ .ok = .{ .key = try a.dupe(u8, g.key), .seq = seq, .label = try a.dupe(u8, g.label), .sticky = g.sticky } };
        }

        /// The tables with `keys.prefixes` applied, for `resolve` and
        /// `tableJson`. Run it on the current tables each time they change:
        /// the moves are config, not table state, so they survive a
        /// registrar replacing a table. Allocates the list in `a`; the rest
        /// stays shared with `tables`.
        pub fn applyPrefixes(a: std.mem.Allocator, tables: []const Table, moves: []const Prefix) ![]Table {
            const out = try a.dupe(Table, tables);
            for (out) |*t| t.prefix = effectivePrefix(moves, t.name, t.prefix);
            return out;
        }

        // ---------------------------------------------------------- resolution

        pub const Entry = struct {
            seq: Sequence,
            binding: *const Binding,
            table: *const Table,
        };
        /// Two bindings of one layer that cannot both be reached.
        pub const Conflict = struct { layer: Layer, key: []const u8, tables: [2][]const u8 };
        /// A binding hidden by a higher layer.
        pub const Shadow = struct { key: []const u8, table: []const u8, layer: Layer, by: []const u8, by_layer: Layer };
        /// One key that may follow a pending sequence: one row of the leader
        /// popup, with everything it needs to draw it.
        pub const Next = struct {
            key: Chord,
            /// The first entry (in precedence order) reached through it.
            entry: *const Entry,
            /// More keys follow before a binding runs: a `+` row.
            more: bool,
            /// A binding's label (or its local action, verb or `argv[0]`). For
            /// a `more` row: the group's label, the label or name of the table
            /// it opens, or `…` for an inner prefix no group names.
            label: []const u8,
            /// A `more` row that opens a sticky group.
            sticky: bool = false,

            /// Bindings with the same target and label share one row.
            pub fn sameRow(x: Next, y: Next) bool {
                if (x.more or y.more or !eq(u8, x.label, y.label)) return false;
                return x.entry.binding.target.eql(y.entry.binding.target);
            }
        };
        pub const Resolved = struct {
            entries: []const Entry = &.{},
            conflicts: []const Conflict = &.{},
            shadowed: []const Shadow = &.{},

            pub const Match = union(enum) { none, partial, exact: *const Entry };
            pub fn lookup(self: *const Resolved, keys: []const Chord) Match {
                var partial = false;
                for (self.entries) |*e| if (e.seq.startsWith(keys)) {
                    if (e.seq.len == keys.len) return .{ .exact = e };
                    partial = true;
                };
                return if (partial) .partial else .none;
            }
            /// The distinct keys that may follow `pending`, in entry order.
            pub fn next(self: *const Resolved, a: std.mem.Allocator, pending: []const Chord) ![]Next {
                var out: std.ArrayList(Next) = .empty;
                for (self.entries) |*e| {
                    if (e.seq.len <= pending.len or !e.seq.startsWith(pending)) continue;
                    const key = e.seq.keys[pending.len];
                    const dup = for (out.items) |x| {
                        if (x.key.eql(key)) break true;
                    } else false;
                    if (dup) continue;
                    const more = e.seq.len > pending.len + 1;
                    var row: Next = .{ .key = key, .entry = e, .more = more, .label = e.binding.text() };
                    if (more) {
                        const inner: Sequence = blk: {
                            var s = e.seq;
                            s.len = @intCast(pending.len + 1);
                            break :blk s;
                        };
                        row.label = self.prefixLabel(inner.slice()) orelse "…";
                        if (self.group(inner.slice())) |g| row.sticky = g.sticky;
                    }
                    try out.append(a, row);
                }
                return out.items;
            }
            /// The group named by these keys, in the active tables.
            pub fn group(self: *const Resolved, keys: []const Chord) ?*const Group {
                for (self.entries) |*e| {
                    if (!e.seq.startsWith(keys)) continue;
                    const head: usize = @intFromBool(e.table.prefix != null);
                    if (keys.len <= head) continue;
                    for (e.table.groups) |*g| if (sameChords(g.seq.slice(), keys[head..])) return g;
                }
                return null;
            }
            /// A table's label or name for its prefix key, else the group's
            /// label. Null for an inner prefix no group names.
            fn prefixLabel(self: *const Resolved, keys: []const Chord) ?[]const u8 {
                if (keys.len == 1) for (self.entries) |e| {
                    const p = e.table.prefix orelse continue;
                    if (p.eql(keys[0])) return e.table.label orelse e.table.name;
                };
                return if (self.group(keys)) |g| g.label else null;
            }
            /// Popup header: one name per key typed, by table and group
            /// label. A key no table or group names shows as itself. The
            /// client puts its own name in front. Allocates in `a`.
            pub fn path(self: *const Resolved, a: std.mem.Allocator, pending: []const Chord) ![]const []const u8 {
                const out = try a.alloc([]const u8, pending.len);
                for (out, 0..) |*dst, i| dst.* = self.prefixLabel(pending[0 .. i + 1]) orelse try chordText(a, pending[i]);
                return out;
            }
            /// The table whose sub-prefix `pending` is inside, if any.
            pub fn prefixTable(self: *const Resolved, pending: []const Chord) ?*const Table {
                if (pending.len == 0) return null;
                for (self.entries) |e| if (e.table.prefix != null and e.seq.startsWith(pending)) return e.table;
                return null;
            }
        };

        /// Layer precedence. A higher layer wins for the same table name, the
        /// same sub-prefix, and any binding whose sequence overlaps (one is a
        /// prefix of the other). Within a layer such overlaps are conflicts;
        /// the first one (in table order) is kept. Inactive tables (`when`)
        /// take no part. Allocates into `a` (an arena); entries point into
        /// `tables`.
        pub fn resolve(a: std.mem.Allocator, tables: []const Table, active: ?Active) !Resolved {
            var conflicts: std.ArrayList(Conflict) = .empty;
            var shadowed: std.ArrayList(Shadow) = .empty;
            // Highest layer first; table order within a layer.
            const order = try a.alloc(*const Table, tables.len);
            for (tables, order) |*t, *o| o.* = t;
            std.mem.sort(*const Table, order, {}, struct {
                fn gt(_: void, x: *const Table, y: *const Table) bool {
                    return @backingInt(x.layer) > @backingInt(y.layer);
                }
            }.gt);
            var kept: std.ArrayList(*const Table) = .empty;
            outer: for (order) |t| {
                if (active) |act| if (!act.f(act.ctx, t.when)) continue;
                for (kept.items) |k| {
                    const same_name = eq(u8, k.name, t.name);
                    const same_prefix = t.prefix != null and k.prefix != null and k.prefix.?.eql(t.prefix.?);
                    if (!same_name and !same_prefix) continue;
                    if (k.layer == t.layer) {
                        try conflicts.append(a, .{ .layer = t.layer, .key = if (t.prefix) |p| try chordText(a, p) else "", .tables = .{ k.name, t.name } });
                    } else for (t.bindings) |*b| {
                        try shadowed.append(a, .{ .key = try fullText(a, t, b), .table = t.name, .layer = t.layer, .by = k.name, .by_layer = k.layer });
                    }
                    continue :outer;
                }
                try kept.append(a, t);
            }
            var entries: std.ArrayList(Entry) = .empty;
            for (kept.items) |t| for (t.bindings) |*b| {
                var seq: Sequence = .{};
                if (t.prefix) |p| _ = seq.push(p);
                for (b.seq.slice()) |c| _ = seq.push(c);
                const e: Entry = .{ .seq = seq, .binding = b, .table = t };
                const winner = for (entries.items) |*w| {
                    if (w.seq.overlaps(&e.seq)) break w;
                } else null;
                if (winner) |w| {
                    if (w.table.layer == t.layer) {
                        try conflicts.append(a, .{ .layer = t.layer, .key = try seq.text(a), .tables = .{ w.table.name, t.name } });
                    } else try shadowed.append(a, .{ .key = try seq.text(a), .table = t.name, .layer = t.layer, .by = w.table.name, .by_layer = w.table.layer });
                    continue;
                }
                try entries.append(a, e);
            };
            return .{ .entries = entries.items, .conflicts = conflicts.items, .shadowed = shadowed.items };
        }
        fn fullText(a: std.mem.Allocator, t: *const Table, b: *const Binding) ![]u8 {
            if (t.prefix) |p| return std.fmt.allocPrint(a, "{s} {s}", .{ try chordText(a, p), b.key });
            return a.dupe(u8, b.key);
        }

        // ----------------------------------------------------------- JSON form

        /// One table as `keys.list` reports it and clients read it back.
        pub fn tableJson(a: std.mem.Allocator, t: *const Table) !Value {
            var bindings: std.json.Array = .init(a);
            for (t.bindings) |b| {
                var o: std.json.ObjectMap = .empty;
                try o.put(a, "key", .{ .string = b.key });
                if (b.label) |l| try o.put(a, "label", .{ .string = l });
                switch (b.target) {
                    .local => |c| try o.put(a, "local", .{ .string = hooks.localName(c) }),
                    .verb => |v| {
                        try o.put(a, "verb", .{ .string = v.name });
                        try o.put(a, "args", .{ .string = v.args });
                    },
                    .exec => |argv| {
                        var arr: std.json.Array = .init(a);
                        for (argv) |x| try arr.append(.{ .string = x });
                        try o.put(a, "exec", .{ .array = arr });
                    },
                }
                try bindings.append(.{ .object = o });
            }
            var when: std.json.Array = .init(a);
            for (t.when) |w| {
                var o: std.json.ObjectMap = .empty;
                try o.put(a, "key", .{ .string = w.key });
                try o.put(a, "value", .{ .string = w.value });
                try when.append(.{ .object = o });
            }
            var o: std.json.ObjectMap = .empty;
            try o.put(a, "name", .{ .string = t.name });
            try o.put(a, "layer", .{ .string = @tagName(t.layer) });
            if (t.prefix) |p| try o.put(a, "prefix", .{ .string = try chordText(a, p) });
            if (t.label) |l| try o.put(a, "label", .{ .string = l });
            try o.put(a, "when", .{ .array = when });
            if (t.groups.len > 0) {
                var groups: std.json.Array = .init(a);
                for (t.groups) |g| {
                    var go: std.json.ObjectMap = .empty;
                    try go.put(a, "key", .{ .string = g.key });
                    try go.put(a, "label", .{ .string = g.label });
                    if (g.sticky) try go.put(a, "sticky", .{ .bool = true });
                    try groups.append(.{ .object = go });
                }
                try o.put(a, "groups", .{ .array = groups });
            }
            try o.put(a, "bindings", .{ .array = bindings });
            if (t.source) |s| try o.put(a, "source", .{ .string = s });
            return .{ .object = o };
        }
        /// A table record from JSON into `a`; null when it is not a valid
        /// table (unknown layer, local command or verb, bad key, …).
        pub fn tableFromJson(a: std.mem.Allocator, v: Value) !?Table {
            if (v != .object) return null;
            const o = v.object;
            const layer = std.meta.stringToEnum(Layer, str(o.get("layer")) orelse return null) orelse return null;
            var t: TableConfig = .{ .name = str(o.get("name")) orelse return null, .prefix = str(o.get("prefix")) };
            if (o.get("label")) |l| t.label = if (l == .string) l.string else return null;
            if (o.get("when")) |w| t.when = (try tagsFromJson(a, w)) orelse return null;
            if (o.get("groups")) |g| t.groups = (try groupConfigsFromJson(a, g)) orelse return null;
            const items = if (o.get("bindings")) |b| (if (b == .array) b.array.items else return null) else &.{};
            const bind = try a.alloc(BindingConfig, items.len);
            for (items, bind) |item, *dst| dst.* = (try bindingConfigFromJson(a, item)) orelse return null;
            t.bind = bind;
            var out = switch (try parseTable(a, t, layer)) {
                .ok => |x| x,
                .failed => return null,
            };
            if (str(o.get("source"))) |s| out.source = try a.dupe(u8, s);
            return out;
        }

        // ------------------------------------------------------- leader state

        /// Per-client key state: normal, leader (with the
        /// keys typed after it and the tables active when it was pressed, or
        /// at the last `refocus`), or locked. Only the leader is intercepted in normal mode and only
        /// the unlock key in lock mode; every other key passes.
        ///
        /// In leader mode every key is swallowed. `esc` always ends it; a
        /// binding for `escape` at the current level runs as it does, which
        /// is how a client clears its selection. `backspace` goes up
        /// one level, and out of leader mode from the root. An unbound key
        /// ends it. A sticky group's binding runs without leaving the group.
        pub const Router = struct {
            pub const Mode = enum { normal, leader, locked };
            pub const Outcome = union(enum) {
                /// Not intercepted: send the key to the focused pane.
                pass,
                /// At the root of leader mode: the leader was pressed, or
                /// `backspace` came back up.
                leader,
                /// Inside a sequence or sub-prefix: more keys follow.
                partial,
                /// Leader twice: send the leader key itself to the pane.
                send_leader,
                /// A binding matched. It points into the tables given to
                /// `feed`. Leader mode ended, unless the binding is in a
                /// sticky group: `pending` tells which.
                run: *const Binding,
                /// Lock mode ended.
                unlocked,
                /// Leader mode was cancelled and the key swallowed: an unbound
                /// key, `esc`, or `backspace` at the root. Holds what was typed,
                /// that key last.
                unbound: Sequence,
                /// More keys than any binding has; leader mode ended.
                overflow,
            };

            gpa: std.mem.Allocator,
            mode: Mode = .normal,
            arena: ?std.heap.ArenaAllocator = null,
            resolved: Resolved = .{},
            seq: Sequence = .{},
            deadline: i64 = no_deadline,
            popup_hidden: bool = false,

            /// `deadline` while `keys.timeout_ms` is 0: no timeout.
            pub const no_deadline = std.math.maxInt(i64);
            fn deadlineAfter(settings: Settings, now: i64) i64 {
                return if (settings.timeout_ms == 0) no_deadline else now + settings.timeout_ms;
            }

            pub fn init(gpa: std.mem.Allocator) Router {
                return .{ .gpa = gpa };
            }
            pub fn deinit(self: *Router) void {
                self.end();
            }
            /// The chord to `feed` for a host key; the arguments are `fromKey`'s
            /// and the key's Kitty base-layout key. On a non-Latin layout a Kitty
            /// host reports the layout's character with the Latin key as its base
            /// (`CSI 945::97;5u`), and tables are in Latin: fall back to the base,
            /// unless the character itself is the leader, the unlock key or a
            /// binding at this level. The pane still gets the key as it came.
            pub fn chordOf(self: *const Router, settings: Settings, cp: u21, mods: Mods, shifted: ?u21, text: ?[]const u8, base_layout: ?u21) Chord {
                const exact = fromKey(cp, mods, shifted, text);
                const base = base_layout orelse return exact;
                if (cp < 0x80 or cp >= named_base or base >= 0x80) return exact;
                if (exact.eql(settings.leader) or exact.eql(settings.unlock)) return exact;
                if (self.pending()) {
                    var typed = self.seq;
                    if (typed.push(exact) and self.resolved.lookup(typed.slice()) != .none) return exact;
                }
                return fromKey(base, mods, null, null);
            }
            /// One key. `tables` must outlive leader mode; `active` is read
            /// when the leader is pressed, and after that only by `refocus`.
            pub fn feed(self: *Router, settings: Settings, tables: []const Table, active: ?Active, ch: Chord, now: i64) !Outcome {
                switch (self.mode) {
                    .locked => {
                        if (!ch.eql(settings.unlock)) return .pass;
                        self.mode = .normal;
                        return .unlocked;
                    },
                    .normal => {
                        if (!ch.eql(settings.leader)) return .pass;
                        try self.begin(tables, active, deadlineAfter(settings, now));
                        return .leader;
                    },
                    .leader => {},
                }
                if (self.seq.len == 0 and ch.eql(settings.leader)) {
                    self.end();
                    return .send_leader;
                }
                if (ch.eql(esc_key)) return self.cancel(ch);
                if (ch.eql(backspace_key)) {
                    if (self.seq.len == 0) return self.cancel(ch);
                    self.seq.len -= 1;
                    self.popup_hidden = false;
                    self.deadline = deadlineAfter(settings, now);
                    return if (self.seq.len == 0) .leader else .partial;
                }
                if (!self.seq.push(ch)) {
                    self.end();
                    return .overflow;
                }
                switch (self.resolved.lookup(self.seq.slice())) {
                    .exact => |e| {
                        const b = e.binding;
                        if (self.stickyLevel()) |level| {
                            self.seq.len = level;
                            self.popup_hidden = true;
                            self.deadline = deadlineAfter(settings, now);
                        } else self.end();
                        return .{ .run = b };
                    },
                    .partial => {
                        self.popup_hidden = false;
                        self.deadline = deadlineAfter(settings, now);
                        return .partial;
                    },
                    .none => {
                        self.seq.len -= 1;
                        if (ch.eql(help_key) and self.stickyGroup() != null) {
                            self.popup_hidden = false;
                            self.deadline = deadlineAfter(settings, now);
                            return .partial;
                        }
                        return self.cancel(ch);
                    },
                }
            }
            /// End leader mode on `ch`, which is not part of `seq` yet. A
            /// bound `escape` still runs.
            fn cancel(self: *Router, ch: Chord) Outcome {
                var typed = self.seq;
                _ = typed.push(ch);
                // The entry lives in the arena `end` frees; the binding does not.
                const bound: ?*const Binding = switch (self.resolved.lookup(typed.slice())) {
                    .exact => |e| e.binding,
                    else => null,
                };
                self.end();
                if (ch.eql(esc_key)) if (bound) |b| return .{ .run = b };
                return .{ .unbound = typed };
            }
            /// How many of the typed keys lead to the innermost sticky group
            /// around the binding they reach, if any.
            fn stickyLevel(self: *const Router) ?u8 {
                var n = self.seq.len - 1;
                while (n > 0) : (n -= 1) {
                    if (self.resolved.group(self.seq.keys[0..n])) |g| if (g.sticky) return n;
                }
                return null;
            }
            /// Enter leader mode with the tables active now.
            pub fn begin(self: *Router, tables: []const Table, active: ?Active, deadline: i64) !void {
                self.end();
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                errdefer arena.deinit();
                self.resolved = try resolve(arena.allocator(), tables, active);
                self.arena = arena;
                self.mode = .leader;
                self.deadline = deadline;
            }
            /// The client's focus moved during leader mode. Resolves
            /// `tables` again for `active`, the new pane's. Leader mode goes on
            /// if the typed keys still lead somewhere, and ends if they do not.
            /// Nothing runs and the deadline stays: this is not a key. A popup a
            /// sticky group hid stays hidden while the keys are still in one. True when it just ended leader mode; a client redraws
            /// either way, since the popup's rows can change.
            pub fn refocus(self: *Router, tables: []const Table, active: ?Active) !bool {
                if (self.mode != .leader) return false;
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                errdefer arena.deinit();
                const resolved = try resolve(arena.allocator(), tables, active);
                if (self.seq.len > 0 and resolved.lookup(self.seq.slice()) != .partial) {
                    arena.deinit();
                    self.end();
                    return true;
                }
                if (self.arena) |*x| x.deinit();
                self.arena = arena;
                self.resolved = resolved;
                // Only a sticky group keeps its popup down: the same prefix can
                // be plain on the new pane, where nothing else would bring it up.
                if (self.stickyGroup() == null) self.popup_hidden = false;
                return false;
            }
            /// Leave leader mode (lock mode is kept).
            pub fn end(self: *Router) void {
                if (self.arena) |*x| x.deinit();
                self.arena = null;
                self.resolved = .{};
                self.seq = .{};
                self.popup_hidden = false;
                self.deadline = no_deadline;
                if (self.mode == .leader) self.mode = .normal;
            }
            /// Lock mode: pass every key until the unlock key.
            pub fn lock(self: *Router) void {
                self.end();
                self.mode = .locked;
            }
            /// Leader mode ends after `timeout_ms` without a key, and never
            /// when that is 0. True when it just ended.
            pub fn tick(self: *Router, now: i64) bool {
                if (self.mode != .leader or now < self.deadline) return false;
                self.end();
                return true;
            }
            pub fn pending(self: *const Router) bool {
                return self.mode == .leader;
            }
            pub fn locked(self: *const Router) bool {
                return self.mode == .locked;
            }
            /// The table whose sub-prefix is pending.
            pub fn table(self: *const Router) ?*const Table {
                return if (self.mode == .leader) self.resolved.prefixTable(self.seq.slice()) else null;
            }
            /// The sticky group the client is in, if any.
            pub fn stickyGroup(self: *const Router) ?*const Group {
                if (self.mode != .leader) return null;
                const g = self.resolved.group(self.seq.slice()) orelse return null;
                return if (g.sticky) g else null;
            }
            /// A sticky group's popup stays hidden after a binding runs,
            /// until `?` (or another level) shows it.
            pub fn popupHidden(self: *const Router) bool {
                return self.popup_hidden;
            }
            /// When `tick` next ends leader mode; null when nothing will. A
            /// client's event loop need not wake for it otherwise.
            pub fn nextDeadline(self: *const Router) ?i64 {
                return if (self.mode != .leader or self.deadline == no_deadline) null else self.deadline;
            }
            /// `venomx.mode` text: empty, `LOCK`, `LEADER`,
            /// `LEADER <table>` inside a sub-prefix, or `LEADER <group>` in a
            /// sticky group. Allocated in `a` when it names one.
            pub fn modeText(self: *const Router, a: std.mem.Allocator) ![]const u8 {
                return switch (self.mode) {
                    .normal => "",
                    .locked => "LOCK",
                    .leader => if (self.stickyGroup()) |g|
                        std.fmt.allocPrint(a, "LEADER {s}", .{g.label})
                    else if (self.table()) |t|
                        std.fmt.allocPrint(a, "LEADER {s}", .{t.name})
                    else
                        "LEADER",
                };
            }
            /// Which-key: the next keys after what was typed.
            pub fn next(self: *const Router, a: std.mem.Allocator) ![]Next {
                return self.resolved.next(a, self.seq.slice());
            }
            /// The popup header for what was typed (`Resolved.path`).
            pub fn path(self: *const Router, a: std.mem.Allocator) ![]const []const u8 {
                return self.resolved.path(a, self.seq.slice());
            }
        };
    };
}

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}
/// `[{key, value}]` pairs (borrowed from `v`); null when malformed.
pub fn tagsFromJson(a: std.mem.Allocator, v: Value) !?[]Tag {
    if (v != .array) return null;
    const out = try a.alloc(Tag, v.array.items.len);
    for (v.array.items, out) |item, *dst| {
        if (item != .object) return null;
        dst.* = .{ .key = str(item.object.get("key")) orelse return null, .value = str(item.object.get("value")) orelse return null };
    }
    return out;
}
/// One binding record (borrowed from `v`); null when malformed.
pub fn bindingConfigFromJson(a: std.mem.Allocator, v: Value) !?BindingConfig {
    if (v != .object) return null;
    const o = v.object;
    var b: BindingConfig = .{ .key = str(o.get("key")) orelse return null, .local = str(o.get("local")), .verb = str(o.get("verb")), .args = str(o.get("args")) };
    if (o.get("label")) |l| b.label = if (l == .string) l.string else return null;
    if (o.get("exec")) |e| {
        if (e != .array) return null;
        const argv = try a.alloc([]const u8, e.array.items.len);
        for (e.array.items, argv) |x, *dst| dst.* = if (x == .string) x.string else return null;
        b.exec = argv;
    }
    return b;
}

/// `[{key, label, sticky?}]` group records (borrowed from `v`); null when
/// malformed.
pub fn groupConfigsFromJson(a: std.mem.Allocator, v: Value) !?[]GroupConfig {
    if (v != .array) return null;
    const out = try a.alloc(GroupConfig, v.array.items.len);
    for (v.array.items, out) |item, *dst| {
        if (item != .object) return null;
        const o = item.object;
        dst.* = .{ .key = str(o.get("key")) orelse return null, .label = str(o.get("label")) orelse return null };
        if (o.get("sticky")) |s| dst.sticky = if (s == .bool) s.bool else return null;
    }
    return out;
}

test {
    _ = @import("keys_tests.zig");
}
