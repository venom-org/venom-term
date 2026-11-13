//! The client-side environment rules for `exec` key binding
//! targets, shared by every venomx client (`venomx attach`, venom-desk) so
//! their children get the same environment: the client's own, minus the
//! venomx token and principal and any entry whose value
//! carries a credential under the credential table below.
//!
//! The token-shaped pattern and the credential table live here (not in
//! venomx) so both clients import one implementation; the venomx daemon's
//! pane spawn environment re-exports them. Pure: no I/O, `std` only.
const std = @import("std");
const eq = std.mem.eql;

/// One match of the venom token-shaped pattern
/// `vnt1\.[a-z][a-z0-9-]{0,31}\.(owner|unknown|g[1-9][0-9]*)\.[A-Za-z0-9_-]{43}`.
pub const Token = struct { start: usize, end: usize, tool: []const u8, owner: bool };

fn secretChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
}

fn matchAt(s: []const u8, i: usize) ?Token {
    if (!std.mem.startsWith(u8, s[i..], "vnt1.")) return null;
    var j = i + 5;
    const tool_start = j;
    if (j >= s.len or !std.ascii.isLower(s[j])) return null;
    j += 1;
    while (j < s.len and (std.ascii.isLower(s[j]) or std.ascii.isDigit(s[j]) or s[j] == '-')) j += 1;
    if (j - tool_start > 32 or j >= s.len or s[j] != '.') return null;
    const tool = s[tool_start..j];
    j += 1;
    var owner = false;
    if (std.mem.startsWith(u8, s[j..], "owner.")) {
        owner = true;
        j += 5;
    } else if (std.mem.startsWith(u8, s[j..], "unknown.")) {
        j += 7;
    } else {
        if (j + 1 >= s.len or s[j] != 'g' or s[j + 1] < '1' or s[j + 1] > '9') return null;
        j += 2;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
        if (j >= s.len or s[j] != '.') return null;
    }
    j += 1;
    if (s.len < j + 43) return null;
    for (s[j .. j + 43]) |ch| if (!secretChar(ch)) return null;
    return .{ .start = i, .end = j + 43, .tool = tool, .owner = owner };
}

/// The first token-shaped substring at or after `from`.
pub fn findToken(s: []const u8, from: usize) ?Token {
    var i = from;
    while (std.mem.indexOfPos(u8, s, i, "vnt1.")) |at| {
        if (matchAt(s, at)) |t| return t;
        i = at + 1;
    }
    return null;
}

pub fn containsToken(s: []const u8) bool {
    return findToken(s, 0) != null;
}

/// `<TOOL>_TOKEN` for a tool name: upper-cased, `-` replaced by `_`.
fn toolVariable(name: []const u8, tool: []const u8) bool {
    if (name.len != tool.len + "_TOKEN".len or !std.mem.endsWith(u8, name, "_TOKEN")) return false;
    for (tool, name[0..tool.len]) |t, n| {
        const want: u8 = if (t == '-') '_' else std.ascii.toUpper(t);
        if (n != want) return false;
    }
    return true;
}

/// Credential table for one explicit `env` entry.
pub fn credential(name: []const u8, value: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, name, "_TOKEN") and eq(u8, value, "@owner")) return "owner_credential";
    var count: usize = 0;
    var first: ?Token = null;
    var venomx = false;
    var from: usize = 0;
    while (findToken(value, from)) |t| {
        if (t.owner) return "owner_credential";
        venomx = venomx or eq(u8, t.tool, "venomx");
        if (first == null) first = t;
        count += 1;
        from = t.start + 1;
    }
    if (venomx) return "credential";
    const t = first orelse return null;
    if (count == 1 and t.start == 0 and t.end == value.len and toolVariable(name, t.tool)) return null;
    return "credential";
}

/// Whether an environment entry (`NAME=value`) is withheld from an exec
/// child: an entry without `=`, `VENOMX_TOKEN`, `VENOMX_PRINCIPAL`, and any
/// entry whose value `credential` flags.
pub fn withheld(entry: []const u8) bool {
    const equal = std.mem.indexOfScalar(u8, entry, '=') orelse return true;
    const name = entry[0..equal];
    if (eq(u8, name, "VENOMX_TOKEN") or eq(u8, name, "VENOMX_PRINCIPAL")) return true;
    return credential(name, entry[equal + 1 ..]) != null;
}

/// The child environment for a client whose environment is a slice of
/// `NAME=value` strings: `parent` minus `withheld` entries, in order. The
/// strings borrow `parent`; the slice is owned by `a`.
pub fn childEnviron(a: std.mem.Allocator, parent: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    for (parent) |entry| if (!withheld(entry)) try out.append(a, entry);
    return out.toOwnedSlice(a);
}

const testing = std.testing;
fn rep(comptime n: usize, comptime ch: []const u8) *const [n]u8 {
    const frozen = comptime blk: {
        const out: [n]u8 = @splat(ch[0]);
        break :blk out;
    };
    return &frozen;
}
const fake = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"; // 43 secret chars

test "token-shaped substrings follow the token pattern" {
    try testing.expect(containsToken("vnt1.venom.g7." ++ fake));
    try testing.expect(containsToken("x vnt1.venom-desk.owner." ++ fake ++ " y"));
    try testing.expect(containsToken("vnt1.venomx.unknown." ++ fake));
    try testing.expect(!containsToken("vnt1.venom.g0." ++ fake));
    try testing.expect(!containsToken("vnt1.Venom.g1." ++ fake));
    try testing.expect(!containsToken("vnt1.venom.g1." ++ fake[0..42]));
    try testing.expect(!containsToken("vnt1." ++ rep(33, "a") ++ ".g1." ++ fake));
    try testing.expect(containsToken("vnt1." ++ rep(32, "a") ++ ".g1." ++ fake));
    // A failed partial match does not hide a later real one.
    try testing.expect(containsToken("vnt1.vnt1.venom.g2." ++ fake));
}

test "credential table" {
    const venom = "vnt1.venom.g7." ++ fake;
    try testing.expect(credential("GITHUB_TOKEN", "canary") == null);
    try testing.expect(credential("VENOM_TOKEN", venom) == null);
    try testing.expect(credential("VENOM_DESK_TOKEN", "vnt1.venom-desk.g2." ++ fake) == null);
    try testing.expect(credential("VENOM_PRINCIPAL", "g7") == null);
    try testing.expectEqualStrings("owner_credential", credential("VENOM_TOKEN", "@owner").?);
    try testing.expect(credential("NOTE", "@owner") == null);
    try testing.expectEqualStrings("owner_credential", credential("VENOM_TOKEN", "vnt1.venom.owner." ++ fake).?);
    try testing.expectEqualStrings("owner_credential", credential("NOTE", "prefix vnt1.venom-desk.owner." ++ fake).?);
    try testing.expectEqualStrings("credential", credential("OTHER", "vnt1.venomx.g3." ++ fake).?);
    try testing.expectEqualStrings("credential", credential("VENOM_DESK_TOKEN", venom).?);
    try testing.expectEqualStrings("credential", credential("VENOM_TOKEN", venom ++ " trailing").?);
    try testing.expectEqualStrings("credential", credential("VENOM_TOKEN", venom ++ venom).?);
}

test "exec children: no venomx token, principal or credential" {
    try testing.expect(withheld("VENOMX_TOKEN=@owner"));
    try testing.expect(withheld("VENOMX_TOKEN="));
    try testing.expect(withheld("VENOMX_PRINCIPAL=g3"));
    try testing.expect(withheld("OTHER_TOKEN=@owner"));
    try testing.expect(withheld("NOTE=prefix vnt1.venomx.g7." ++ fake));
    try testing.expect(withheld("VENOM_TOKEN=vnt1.venom.owner." ++ fake));
    try testing.expect(withheld("NOEQUALS"));
    try testing.expect(!withheld("HOME=/home/x"));
    try testing.expect(!withheld("VENOMX_PANE=p3"));
    try testing.expect(!withheld("VENOMX_SOCKET=/run/venomx.sock"));
    // A tool's own token under its own variable stays: the child calls
    // that tool under its rules.
    try testing.expect(!withheld("VENOM_TOKEN=vnt1.venom.g7." ++ fake));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const env = try childEnviron(arena.allocator(), &.{ "HOME=/h", "VENOMX_TOKEN=vnt1.venomx.g1." ++ fake, "VENOMX_PRINCIPAL=g1", "NOTE=x vnt1.venomx.g1." ++ fake, "VENOMX_PANE=p1", "PATH=/bin" });
    try testing.expectEqual(@as(usize, 3), env.len);
    try testing.expectEqualStrings("HOME=/h", env[0]);
    try testing.expectEqualStrings("VENOMX_PANE=p1", env[1]);
    try testing.expectEqualStrings("PATH=/bin", env[2]);
}
