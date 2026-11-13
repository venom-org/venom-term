//! Status templates: literal text with `{var[:spec][|fallback]}`
//! variables and optional `[…]` groups, nothing else (no expressions, loops
//! or calls). `parse` checks a template against the closed variable table
//! and reports the byte offset of the first error (`invalid_params.template`);
//! `render` fills it from a caller-supplied `Lookup`. The strftime subset of
//! `clock` is implemented here, so every client formats time the same way.
const std = @import("std");
const tags = @import("tags.zig");
const cells = @import("cells.zig");

/// Rendered output is capped at this many bytes, on a cluster boundary.
pub const max_output = 256;

pub const Var = struct {
    name: []const u8,
    spec: ?[]const u8 = null,
    fallback: ?[]const u8 = null,
};
pub const Node = union(enum) {
    /// Literal text with `{{ }} [[ ]]` already unescaped.
    literal: []const u8,
    variable: Var,
    /// Dropped whole when any variable inside renders empty.
    optional: []const Node,
};
pub const Template = struct { nodes: []const Node };

/// Where a template is used: only rules see `event.*`.
pub const Kind = enum { segment, rule };

pub const Reason = enum {
    unknown_variable,
    bad_spec,
    bad_fallback,
    unbalanced,
    nested_optional,

    pub fn text(self: Reason) []const u8 {
        return switch (self) {
            .unknown_variable => "unknown variable",
            .bad_spec => "bad spec",
            .bad_fallback => "a fallback may not contain '{' or '['",
            .unbalanced => "unbalanced braces or brackets",
            .nested_optional => "optional groups do not nest",
        };
    }
};
/// `invalid_params.template`: what is wrong and the byte offset where.
pub const Failure = struct { offset: usize, reason: Reason };
pub const ParseResult = union(enum) { ok: Template, failed: Failure };

// ------------------------------------------------------------- variables

const fixed = [_][]const u8{
    "session.id",   "session.name", "window.index", "window.name",     "window.id",
    "window.label", "pane.id",      "pane.cwd",     "pane.process",    "pane.command",
    "pane.title",   "pane.program", "pane.label",   "attention.count", "host",
    "user",         "clock",
};

fn validField(f: []const u8) bool {
    if (f.len == 0 or f.len > 64 or !(std.ascii.isAlphabetic(f[0]) or f[0] == '_')) return false;
    for (f) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

/// The closed variable table: fixed names, `pane.tag.<key>` with a valid pane
/// tag key, and for rules `event.type`, `event.resource`, `event.<field>`.
pub fn isVariable(name: []const u8, kind: Kind) bool {
    for (fixed) |f| if (std.mem.eql(u8, f, name)) return true;
    if (std.mem.startsWith(u8, name, "pane.tag.")) return tags.validKey(name["pane.tag.".len..]);
    if (kind == .rule and std.mem.startsWith(u8, name, "event.")) return validField(name["event.".len..]);
    return false;
}

const conversions = "HMSdmYyabp%";
/// A strftime subset: `%H %M %S %d %m %Y %y %a %b %p %%`, any other text literal.
pub fn validClockSpec(spec: []const u8) bool {
    var i: usize = 0;
    while (i < spec.len) : (i += 1) {
        if (spec[i] != '%') continue;
        i += 1;
        if (i == spec.len or std.mem.indexOfScalar(u8, conversions, spec[i]) == null) return false;
    }
    return true;
}

// ----------------------------------------------------------------- parse

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    kind: Kind,
    pos: usize = 0,
    failure: ?Failure = null,

    fn fail(self: *Parser, offset: usize, reason: Reason) error{Invalid} {
        self.failure = .{ .offset = offset, .reason = reason };
        return error.Invalid;
    }

    /// Nodes until end of input, or until `]` when `inside` an optional.
    fn nodes(self: *Parser, inside: bool) error{ Invalid, OutOfMemory }![]const Node {
        var out: std.ArrayList(Node) = .empty;
        var lit: std.ArrayList(u8) = .empty;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            const twice = self.pos + 1 < self.src.len and self.src[self.pos + 1] == c;
            switch (c) {
                '{', '}', '[', ']' => if (twice) {
                    try lit.append(self.a, c);
                    self.pos += 2;
                    continue;
                },
                else => {},
            }
            switch (c) {
                '{' => {
                    if (lit.items.len > 0) try out.append(self.a, .{ .literal = try lit.toOwnedSlice(self.a) });
                    try out.append(self.a, .{ .variable = try self.variable() });
                },
                '[' => {
                    if (inside) return self.fail(self.pos, .nested_optional);
                    if (lit.items.len > 0) try out.append(self.a, .{ .literal = try lit.toOwnedSlice(self.a) });
                    const open = self.pos;
                    self.pos += 1;
                    const inner = try self.nodes(true);
                    if (self.pos >= self.src.len) return self.fail(open, .unbalanced);
                    self.pos += 1; // ']'
                    try out.append(self.a, .{ .optional = inner });
                },
                ']' => {
                    if (!inside) return self.fail(self.pos, .unbalanced);
                    break;
                },
                '}' => return self.fail(self.pos, .unbalanced),
                else => {
                    try lit.append(self.a, c);
                    self.pos += 1;
                },
            }
        }
        if (lit.items.len > 0) try out.append(self.a, .{ .literal = try lit.toOwnedSlice(self.a) });
        return out.toOwnedSlice(self.a);
    }

    fn variable(self: *Parser) error{ Invalid, OutOfMemory }!Var {
        const open = self.pos;
        self.pos += 1;
        const name_start = self.pos;
        while (self.pos < self.src.len and std.mem.indexOfScalar(u8, ":|}", self.src[self.pos]) == null) : (self.pos += 1) {
            if (self.src[self.pos] == '{' or self.src[self.pos] == '[' or self.src[self.pos] == ']') return self.fail(self.pos, .unbalanced);
        }
        if (self.pos >= self.src.len) return self.fail(open, .unbalanced);
        const name = self.src[name_start..self.pos];
        if (!isVariable(name, self.kind)) return self.fail(name_start, .unknown_variable);
        var v: Var = .{ .name = name };
        if (self.src[self.pos] == ':') {
            self.pos += 1;
            const spec_start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '|' and self.src[self.pos] != '}') : (self.pos += 1) {
                if (self.src[self.pos] == '{') return self.fail(self.pos, .unbalanced);
            }
            if (self.pos >= self.src.len) return self.fail(open, .unbalanced);
            const spec = self.src[spec_start..self.pos];
            if (!std.mem.eql(u8, name, "clock") or !validClockSpec(spec)) return self.fail(spec_start, .bad_spec);
            v.spec = spec;
        }
        if (self.src[self.pos] == '|') {
            self.pos += 1;
            const fb_start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '}') : (self.pos += 1) {
                if (self.src[self.pos] == '{' or self.src[self.pos] == '[') return self.fail(self.pos, .bad_fallback);
            }
            if (self.pos >= self.src.len) return self.fail(open, .unbalanced);
            v.fallback = self.src[fb_start..self.pos];
        }
        self.pos += 1; // '}'
        return v;
    }
};

/// Parse and check `source`. Nodes are allocated in `a` (an arena) and
/// borrow `source`.
pub fn parse(a: std.mem.Allocator, source: []const u8, kind: Kind) error{OutOfMemory}!ParseResult {
    var p: Parser = .{ .a = a, .src = source, .kind = kind };
    const nodes = p.nodes(false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return .{ .failed = p.failure.? },
    };
    return .{ .ok = .{ .nodes = nodes } };
}

/// `config check` / `status.rule.set`: the first error, or null.
pub fn check(a: std.mem.Allocator, source: []const u8, kind: Kind) error{OutOfMemory}!?Failure {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    return switch (try parse(arena.allocator(), source, kind)) {
        .ok => null,
        .failed => |f| f,
    };
}

// ----------------------------------------------------------------- clock

/// Broken-down local time for `clock`. The caller applies its time zone.
pub const Clock = struct {
    year: u16,
    /// 1–12
    month: u8,
    /// 1–31
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    /// 0 = Sunday
    weekday: u8,

    /// From Unix seconds plus the local UTC offset in seconds.
    pub fn fromEpoch(seconds: i64, utc_offset: i32) Clock {
        const local: u64 = @intCast(@max(0, seconds + utc_offset));
        const es: std.time.epoch.EpochSeconds = .{ .secs = local };
        const day = es.getEpochDay();
        const yd = day.calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        return .{
            .year = yd.year,
            .month = md.month.numeric(),
            .day = md.day_index + 1,
            .hour = ds.getHoursIntoDay(),
            .minute = ds.getMinutesIntoHour(),
            .second = ds.getSecondsIntoMinute(),
            // 1970-01-01 was a Thursday.
            .weekday = @intCast((day.day + 4) % 7),
        };
    }

    pub fn format(self: Clock, w: *std.Io.Writer, spec: []const u8) std.Io.Writer.Error!void {
        const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        var i: usize = 0;
        while (i < spec.len) : (i += 1) {
            if (spec[i] != '%' or i + 1 == spec.len) {
                try w.writeByte(spec[i]);
                continue;
            }
            i += 1;
            switch (spec[i]) {
                'H' => try w.print("{d:0>2}", .{self.hour}),
                'M' => try w.print("{d:0>2}", .{self.minute}),
                'S' => try w.print("{d:0>2}", .{self.second}),
                'd' => try w.print("{d:0>2}", .{self.day}),
                'm' => try w.print("{d:0>2}", .{self.month}),
                'Y' => try w.print("{d}", .{self.year}),
                'y' => try w.print("{d:0>2}", .{self.year % 100}),
                'a' => try w.writeAll(days[self.weekday % 7]),
                'b' => try w.writeAll(months[(self.month -| 1) % 12]),
                'p' => try w.writeAll(if (self.hour < 12) "AM" else "PM"),
                '%' => try w.writeByte('%'),
                else => |c| try w.print("%{c}", .{c}),
            }
        }
    }
};

// ---------------------------------------------------------------- render

/// Supplies variable values. `get` returns null or "" for an empty
/// variable; `clock` is formatted here from `clock_now`.
pub const Lookup = struct {
    ctx: ?*const anyopaque = null,
    get: *const fn (ctx: ?*const anyopaque, name: []const u8) ?[]const u8 = none,
    clock_now: ?Clock = null,

    fn none(_: ?*const anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }
};
/// A name/value pair for `pairs`.
pub const Pair = struct { []const u8, []const u8 };
/// A lookup over a fixed list of pairs (tests, simple callers).
pub fn pairs(list: *const []const Pair, clock_now: ?Clock) Lookup {
    return .{ .ctx = @ptrCast(list), .get = struct {
        fn get(ctx: ?*const anyopaque, name: []const u8) ?[]const u8 {
            const l: *const []const Pair = @ptrCast(@alignCast(ctx.?));
            for (l.*) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
            return null;
        }
    }.get, .clock_now = clock_now };
}

fn value(a: std.mem.Allocator, v: Var, lookup: Lookup) ![]const u8 {
    var got: []const u8 = "";
    if (std.mem.eql(u8, v.name, "clock")) {
        if (lookup.clock_now) |c| {
            var w: std.Io.Writer.Allocating = .init(a);
            c.format(&w.writer, v.spec orelse "%H:%M") catch return error.OutOfMemory;
            got = w.written();
        }
    } else got = lookup.get(lookup.ctx, v.name) orelse "";
    return if (got.len == 0) v.fallback orelse "" else got;
}

/// True for C0, DEL, C1 and the bidi controls (the same cleaning pane titles get).
fn removed(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or cp == 0x061c or cp == 0x200e or cp == 0x200f or
        (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069);
}

/// Remove control and bidi characters, replace invalid UTF-8 with U+FFFD,
/// and cap at `max_output` bytes without splitting a cluster.
pub fn clean(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it: cells.Iterator = .{ .text = text };
    while (it.next()) |g| {
        var piece: std.ArrayList(u8) = .empty;
        if (g.invalid) try piece.appendSlice(a, "\u{fffd}") else {
            const view = std.unicode.Utf8View.initUnchecked(g.text);
            var cps = view.iterator();
            while (cps.nextCodepointSlice()) |s| {
                const cp = std.unicode.utf8Decode(s) catch unreachable;
                if (!removed(cp)) try piece.appendSlice(a, s);
            }
        }
        if (out.items.len + piece.items.len > max_output) break;
        try out.appendSlice(a, piece.items);
    }
    return out.items;
}

/// Render a parsed template. The result is cleaned and capped; an
/// empty result means the segment is not drawn. Allocates in `a` (an arena).
pub fn render(a: std.mem.Allocator, t: Template, lookup: Lookup) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (t.nodes) |n| switch (n) {
        .literal => |l| try out.appendSlice(a, l),
        .variable => |v| try out.appendSlice(a, try value(a, v, lookup)),
        .optional => |inner| {
            var part: std.ArrayList(u8) = .empty;
            const keep = for (inner) |m| switch (m) {
                .literal => |l| try part.appendSlice(a, l),
                .variable => |v| {
                    const got = try value(a, v, lookup);
                    if (got.len == 0) break false;
                    try part.appendSlice(a, got);
                },
                .optional => unreachable,
            } else true;
            if (keep) try out.appendSlice(a, part.items);
        },
    };
    return clean(a, out.items);
}

/// Parse and render in one step; an invalid template renders as null.
pub fn renderSource(a: std.mem.Allocator, source: []const u8, kind: Kind, lookup: Lookup) !?[]const u8 {
    return switch (try parse(a, source, kind)) {
        .ok => |t| try render(a, t, lookup),
        .failed => null,
    };
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

fn expectRender(want: []const u8, source: []const u8, values: []const Pair) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const list = values;
    const got = try renderSource(arena.allocator(), source, .rule, pairs(&list, null));
    try testing.expectEqualStrings(want, got.?);
}
fn expectFailure(source: []const u8, kind: Kind, offset: usize, reason: Reason) !void {
    const f = (try check(testing.allocator, source, kind)) orelse return error.TestExpectedFailure;
    try testing.expectEqual(reason, f.reason);
    try testing.expectEqual(offset, f.offset);
}

test "an optional group drops whole when a variable inside is empty" {
    try expectRender("~/src", "{pane.cwd}[ › {pane.process}]", &.{.{ "pane.cwd", "~/src" }});
    try expectRender("~/src", "{pane.cwd}[ › {pane.process}]", &.{ .{ "pane.cwd", "~/src" }, .{ "pane.process", "" } });
    try expectRender("~/src › nvim", "{pane.cwd}[ › {pane.process}]", &.{ .{ "pane.cwd", "~/src" }, .{ "pane.process", "nvim" } });
    // A literal-only group always shows; a fallback keeps a group.
    try expectRender("(x)", "[(x)]", &.{});
    try expectRender("[-]", "[[[{pane.tag.branch|-}]]]", &.{});
}

test "an unknown variable fails with its offset" {
    try expectFailure("ok {pane.nope}", .segment, 4, .unknown_variable);
    // event.* only in rules.
    try expectFailure("{event.exit_code}", .segment, 1, .unknown_variable);
    try testing.expectEqual(@as(?Failure, null), try check(testing.allocator, "{event.command} {event.exit_code}", .rule));
    try expectFailure("{pane.tag.Bad}", .segment, 1, .unknown_variable);
}

test "template syntax errors name the offset" {
    try expectFailure("a } b", .segment, 2, .unbalanced);
    try expectFailure("a ] b", .segment, 2, .unbalanced);
    try expectFailure("x [ {host}", .segment, 2, .unbalanced);
    try expectFailure("{host", .segment, 0, .unbalanced);
    try expectFailure("[a [b]]", .segment, 3, .nested_optional);
    try expectFailure("{host:%H}", .segment, 6, .bad_spec);
    try expectFailure("{clock:%Q}", .segment, 7, .bad_spec);
    try expectFailure("{host|a[b}", .segment, 7, .bad_fallback);
    try expectFailure("{ho{st}", .segment, 3, .unbalanced);
}

test "escapes, fallbacks and the tag variable" {
    try expectRender("{a} [b]", "{{a}} [[b]]", &.{});
    try expectRender("-", "{pane.tag.branch|-}", &.{});
    try expectRender("main", "{pane.tag.branch|-}", &.{.{ "pane.tag.branch", "main" }});
    try expectRender("", "{pane.tag.branch|}", &.{});
    try expectRender("cargo 101", "{event.command} {event.exit_code}", &.{ .{ "event.command", "cargo" }, .{ "event.exit_code", "101" } });
}

test "clock: strftime subset, default spec and epoch conversion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 2026-11-12 14:02:05 UTC is a Thursday.
    const c = Clock.fromEpoch(1794492125, 0);
    try testing.expectEqual(@as(u16, 2026), c.year);
    try testing.expectEqual(@as(u8, 4), c.weekday);
    const none: []const Pair = &.{};
    try testing.expectEqualStrings("14:02", (try renderSource(a, "{clock}", .segment, pairs(&none, c))).?);
    try testing.expectEqualStrings("Thu 12 14:02", (try renderSource(a, "{clock:%a %d %H:%M}", .segment, pairs(&none, c))).?);
    try testing.expectEqualStrings("2026-11-12 05 PM % Nov 26", (try renderSource(a, "{clock:%Y-%m-%d %S %p %% %b %y}", .segment, pairs(&none, c))).?);
    // A UTC offset moves the day.
    try testing.expectEqual(@as(u8, 13), Clock.fromEpoch(1794492125, 11 * 3600).day);
    // No clock supplied: the fallback.
    try testing.expectEqualStrings("--", (try renderSource(a, "{clock|--}", .segment, pairs(&none, null))).?);
}

test "output is cleaned of controls and capped at 256 bytes on a cluster boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("ab\u{fffd}c", try clean(a, "a\x1b\u{202e}b\xff\u{85}c\x7f"));
    const long = "界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界"; // 300 bytes
    const capped = try clean(a, long);
    try testing.expectEqual(@as(usize, 255), capped.len);
    try testing.expect(std.unicode.utf8ValidateSlice(capped));
}
