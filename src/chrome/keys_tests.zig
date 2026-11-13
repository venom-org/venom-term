//! Key syntax, binding and table parsing, layer precedence and the leader
//! state machine, including the key-table conformance cases at the module level.
const std = @import("std");
const keys = @import("keys.zig");
const Tags = @import("tags.zig").Tags;
const testing = std.testing;
const eq = std.mem.eql;
const parseChord = keys.parseChord;
const parseSequence = keys.parseSequence;

/// A product's local commands, as a client would declare them.
const Local = enum {
    detach,
    focus_next,
    zoom,
    lock,
    clear_selection,
    fn parse(text: []const u8) ?Local {
        return std.meta.stringToEnum(Local, text);
    }
    fn name(l: Local) []const u8 {
        return @tagName(l);
    }
};
fn knownVerb(name: []const u8) bool {
    return eq(u8, name, "pane.popup") or eq(u8, name, "pane.attention") or eq(u8, name, "pane.split");
}
const K = keys.Tables(Local, .{ .parseLocal = Local.parse, .localName = Local.name, .knownVerb = knownVerb });
const builtin_bindings = [_]K.Binding{
    K.binding("d", .{ .local = .detach }),
    K.binding("o", .{ .local = .focus_next }),
    K.binding("z", .{ .local = .zoom }),
    K.binding("L", .{ .local = .lock }),
    K.binding("escape", .{ .local = .clear_selection }),
    K.binding("%", .{ .verb = .{ .name = "pane.split", .args = "{}" } }),
};
const builtin: K.Table = .{ .name = "venomx", .layer = .builtin, .bindings = &builtin_bindings };
/// The leader and timeout these older cases were written against.
const tmux_style: keys.Settings = .{ .leader = parseChord("ctrl+space").?, .unlock = parseChord("ctrl+alt+space").?, .timeout_ms = 2000 };

test "key syntax: chords, sequences, normalization" {
    try testing.expect(parseChord("ctrl+space").?.eql(.{ .cp = ' ', .mods = .{ .ctrl = true } }));
    try testing.expect(parseChord("ctrl+@").?.eql(parseChord("ctrl+space").?));
    try testing.expect(parseChord("alt+shift+left").?.eql(.{ .cp = keys.named_base + 2, .mods = .{ .alt = true, .shift = true } }));
    try testing.expect(parseChord("%").?.eql(.{ .cp = '%' }));
    try testing.expect(parseChord("shift+o").?.eql(parseChord("O").?));
    try testing.expect(parseChord("ctrl++").?.eql(.{ .cp = '+', .mods = .{ .ctrl = true } }));
    try testing.expect(parseChord("+").?.eql(.{ .cp = '+' }));
    try testing.expect(parseChord("PageUp").?.eql(parseChord("page_up").?));
    try testing.expect(parseChord("Escape").?.eql(parseChord("esc").?));
    try testing.expect(parseChord("f12").?.eql(.{ .cp = @backingInt(@import("types").Input.NamedKey.f12) }));
    try testing.expect(parseChord("") == null and parseChord("ctrl+") == null and parseChord("ctrl+ctrl+a") == null and parseChord("hyper+a") == null and parseChord("ab") == null);
    const s = parseSequence("a  ctrl+b %").?;
    try testing.expectEqual(@as(u8, 3), s.len);
    try testing.expect(parseSequence("a b c d e") == null and parseSequence("  ") == null);
    const text = try s.text(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("a ctrl+b %", text);
    const canon = try keys.chordText(testing.allocator, parseChord("shift+alt+Left").?);
    defer testing.allocator.free(canon);
    try testing.expectEqualStrings("alt+shift+left", canon);
    // Legacy and Kitty input of one key compare equal.
    try testing.expect(keys.fromKey('@', .{ .ctrl = true }, null, null).eql(parseChord("ctrl+space").?));
    try testing.expect(keys.fromKey('5', .{ .shift = true }, '%', "%").eql(parseChord("%").?));
    try testing.expect(keys.fromKey('o', .{ .shift = true }, null, null).eql(parseChord("O").?));
    try testing.expect(keys.fromKey(9, .{ .shift = true }, null, null).eql(parseChord("shift+tab").?));
    // `Input.parse` names a control byte; these are keys of their own, and ESC
    // 0x08 is Alt+Backspace.
    try testing.expect(keys.fromKey(0x0d, .{ .alt = true }, null, null).eql(parseChord("alt+enter").?));
    try testing.expect(keys.fromKey(0x09, .{ .alt = true }, null, null).eql(parseChord("alt+tab").?));
    try testing.expect(keys.fromKey(0x08, .{ .alt = true }, null, null).eql(parseChord("alt+backspace").?));
    try testing.expect(keys.fromKey(0x7f, .{ .alt = true }, null, null).eql(parseChord("alt+backspace").?));
    try testing.expect(keys.fromKey(0x1b, .{ .alt = true }, null, null).eql(parseChord("alt+escape").?));
    // The same chord comes out of Kitty's letter and the parser's.
    try testing.expect(keys.fromKey('a', .{ .ctrl = true, .alt = true }, null, null).eql(parseChord("ctrl+alt+a").?));
    try testing.expect(keys.legacyDeliverable(parseChord("ctrl+alt+a").?) and keys.legacyDeliverable(parseChord("ctrl+\\").?));
    for ([_][]const u8{ "ctrl+h", "ctrl+i", "ctrl+m", "ctrl+[", "ctrl+?", "ctrl+alt+h", "ctrl+alt+i", "ctrl+alt+m", "ctrl+alt+[", "ctrl+alt+?" }) |k| {
        try testing.expect(!keys.legacyDeliverable(parseChord(k).?));
    }
    try testing.expect(keys.legacyDeliverable(parseChord("ctrl+space").?) and keys.legacyDeliverable(parseChord("ctrl+b").?) and keys.legacyDeliverable(parseChord("alt+x").?));
    try testing.expect(!keys.legacyDeliverable(parseChord("ctrl+shift+a").?) and !keys.legacyDeliverable(parseChord("super+a").?) and !keys.legacyDeliverable(parseChord("ctrl+1").?));
    try testing.expectEqual(@as(?u8, 0), keys.legacyByte(parseChord("ctrl+space").?));
    try testing.expectEqual(@as(?u8, 2), keys.legacyByte(parseChord("ctrl+b").?));
}

test "bindings: one target, known locals and verbs, whole-element placeholders" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .exec = &.{ "venom", "approve", "--pane", "{pane}" } }, "b")) == .ok);
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .exec = &.{ "venom", "--pane={pane}" } }, "b")) == .failed);
    try testing.expectEqualStrings("placeholder", (try K.parseBinding(x, .{ .key = "a", .exec = &.{ "venom", "x{session}" } }, "b")).failed.reason);
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .exec = &.{"{pane}"} }, "b")) == .failed);
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .exec = &.{} }, "b")) == .failed);
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .local = "zoom" }, "b")) == .ok);
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .local = "rm-rf" }, "b")) == .failed);
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .verb = "pane.popup", .args = "{\"argv\":[\"fzf\"],\"preset\":\"user.picker\"}" }, "b")) == .ok);
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .verb = "pane.nope" }, "b")) == .failed);
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .verb = "pane.attention", .args = "{\"pane\":\"{pane}\",\"clear\":true}" }, "b")) == .ok);
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .verb = "pane.attention", .args = "{\"pane\":\"p{pane}\"}" }, "b")) == .failed);
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .verb = "pane.attention", .args = "[1]" }, "b")) == .failed);
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .local = "zoom", .exec = &.{"x"} }, "b")) == .failed);
    try testing.expect((try K.parseBinding(x, .{ .key = "a", .local = "zoom", .args = "{}" }, "b")) == .failed);
    try testing.expect((try K.parseBinding(x, .{ .key = "", .local = "zoom" }, "b")) == .failed);
    try testing.expect(keys.validName("venom-os") and !keys.validName("Venom") and !keys.validName(""));
}

test "precedence: user > defaults > product > builtin; same-layer overlaps conflict" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const venom = (try K.parseTable(x, .{ .name = "venom", .prefix = "a", .bind = &.{ .{ .key = "a", .exec = &.{ "venom", "approve" } }, .{ .key = "n", .local = "zoom" } } }, .product)).ok;
    const user_root = (try K.parseTable(x, .{ .name = "mine", .bind = &.{.{ .key = "d", .local = "zoom" }} }, .user)).ok;
    const defaults_sub = (try K.parseTable(x, .{ .name = "distro", .prefix = "a", .bind = &.{.{ .key = "x", .local = "zoom" }} }, .defaults)).ok;
    var r = try K.resolve(x, &.{ builtin, venom, user_root }, null);
    try testing.expectEqual(@as(usize, 0), r.conflicts.len);
    // User `d` shadows built-in detach; venom's sub-table is reachable.
    try testing.expect(r.lookup(&.{parseChord("d").?}).exact.binding.target.local == .zoom);
    try testing.expect(r.lookup(&.{parseChord("a").?}) == .partial);
    try testing.expect(r.lookup(&.{ parseChord("a").?, parseChord("a").? }) == .exact);
    try testing.expectEqual(@as(usize, 1), r.shadowed.len);
    try testing.expectEqualStrings("venomx", r.shadowed[0].table);
    try testing.expectEqualStrings("venom", r.prefixTable(&.{parseChord("a").?}).?.name);
    try testing.expect(r.prefixTable(&.{parseChord("d").?}) == null);
    // A defaults table on the same sub-prefix hides the whole product table.
    r = try K.resolve(x, &.{ builtin, venom, defaults_sub }, null);
    try testing.expect(r.lookup(&.{ parseChord("a").?, parseChord("a").? }) == .none);
    try testing.expectEqual(@as(usize, 2), r.shadowed.len);
    try testing.expectEqualStrings("distro", r.shadowed[0].by);
    try testing.expectEqual(keys.Layer.defaults, r.shadowed[0].by_layer);
    // Same layer: overlapping sequences and equal sub-prefixes or names conflict.
    const one_t = (try K.parseTable(x, .{ .name = "one", .bind = &.{ .{ .key = "g", .local = "zoom" }, .{ .key = "g g", .local = "zoom" } } }, .user)).ok;
    r = try K.resolve(x, &.{one_t}, null);
    try testing.expectEqual(@as(usize, 1), r.conflicts.len);
    try testing.expectEqualStrings("g g", r.conflicts[0].key);
    const two_t = (try K.parseTable(x, .{ .name = "two", .prefix = "a", .bind = &.{.{ .key = "q", .local = "zoom" }} }, .user)).ok;
    const three_t = (try K.parseTable(x, .{ .name = "three", .prefix = "a", .bind = &.{.{ .key = "r", .local = "zoom" }} }, .user)).ok;
    r = try K.resolve(x, &.{ two_t, three_t }, null);
    try testing.expectEqual(@as(usize, 1), r.conflicts.len);
    try testing.expectEqual(keys.Layer.user, r.conflicts[0].layer);
    try testing.expectEqualStrings("a", r.conflicts[0].key);
    const other_venom = (try K.parseTable(x, .{ .name = "venom", .prefix = "b", .bind = &.{} }, .product)).ok;
    r = try K.resolve(x, &.{ venom, other_venom }, null);
    try testing.expectEqual(@as(usize, 1), r.conflicts.len);
    // The same table name in a higher layer replaces the lower one.
    const over = (try K.parseTable(x, .{ .name = "venom", .prefix = "v", .bind = &.{.{ .key = "a", .local = "zoom" }} }, .user)).ok;
    r = try K.resolve(x, &.{ venom, over }, null);
    try testing.expect(r.lookup(&.{ parseChord("a").?, parseChord("a").? }) == .none);
    try testing.expect(r.lookup(&.{ parseChord("v").?, parseChord("a").? }) == .exact);
}

test "JSON round trip of a table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    var table = (try K.parseTable(x, .{ .name = "venom", .prefix = "a", .when = &.{.{ .key = "owner", .value = "venom" }}, .bind = &.{
        .{ .key = "a", .exec = &.{ "venom", "approve", "--pane", "{pane}" } },
        .{ .key = "s", .verb = "pane.attention", .args = "{\"pane\":\"{pane}\",\"clear\":true}" },
        .{ .key = "z", .local = "zoom" },
    } }, .product)).ok;
    table.source = "g9";
    const json = try K.tableJson(x, &table);
    const back = (try K.tableFromJson(x, json)).?;
    try testing.expectEqualStrings("venom", back.name);
    try testing.expectEqual(keys.Layer.product, back.layer);
    try testing.expect(back.prefix.?.eql(parseChord("a").?));
    try testing.expectEqualStrings("{pane}", back.bindings[0].target.exec[3]);
    try testing.expectEqualStrings("pane.attention", back.bindings[1].target.verb.name);
    try testing.expectEqual(Local.zoom, back.bindings[2].target.local);
    try testing.expectEqualStrings("owner", back.when[0].key);
    try testing.expectEqualStrings("g9", back.source.?);
    // Unknown locals, layers and malformed records are not tables.
    var bad = try std.json.parseFromSliceLeaky(std.json.Value, x, "{\"name\":\"t\",\"layer\":\"product\",\"prefix\":\"t\",\"bindings\":[{\"key\":\"a\",\"local\":\"rm-rf\"}]}", .{});
    try testing.expect((try K.tableFromJson(x, bad)) == null);
    bad = try std.json.parseFromSliceLeaky(std.json.Value, x, "{\"name\":\"t\",\"layer\":\"nope\"}", .{});
    try testing.expect((try K.tableFromJson(x, bad)) == null);
    try testing.expect((try K.tableFromJson(x, .{ .integer = 1 })) == null);
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tables: []const K.Table,
    fn init() !Fixture {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const x = arena.allocator();
        const venom = (try K.parseTable(x, .{ .name = "venom", .prefix = "a", .when = &.{.{ .key = "owner", .value = "venom" }}, .bind = &.{
            .{ .key = "a", .exec = &.{ "venom", "approve", "--pane", "{pane}" } },
            .{ .key = "s", .verb = "pane.popup", .args = "{\"preset\":\"venom.settings\",\"argv\":[\"venom\",\"settings\"],\"ticket\":\"{popup_ticket}\"}" },
        } }, .product)).ok;
        const tables = try x.dupe(K.Table, &.{ builtin, venom });
        return .{ .arena = arena, .tables = tables };
    }
    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }
};
fn chord(text: []const u8) keys.Chord {
    return parseChord(text).?;
}

test "only the leader is intercepted; every other key reaches the pane" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    const s = tmux_style;
    // Claude Code's own keys pass unchanged.
    for ([_][]const u8{ "ctrl+b", "shift+tab", "ctrl+c", "escape", "ctrl+r", "ctrl+o", "ctrl+t", "a", "%" }) |k| {
        try testing.expect((try r.feed(s, f.tables, null, chord(k), 0)) == .pass);
    }
    // Leader then leader sends the leader to the pane.
    try testing.expect((try r.feed(s, f.tables, null, chord("ctrl+space"), 0)) == .leader);
    try testing.expectEqualStrings("LEADER", try r.modeText(testing.allocator));
    try testing.expect((try r.feed(s, f.tables, null, chord("ctrl+space"), 0)) == .send_leader);
    try testing.expect(!r.pending());
    // Leader then d runs a local action.
    _ = try r.feed(s, f.tables, null, chord("ctrl+space"), 0);
    try testing.expectEqual(Local.detach, (try r.feed(s, f.tables, null, chord("d"), 0)).run.target.local);
    // An unbound key ends leader mode and reports what was typed.
    _ = try r.feed(s, f.tables, null, chord("ctrl+space"), 0);
    const miss = try r.feed(s, f.tables, null, chord("q"), 0);
    try testing.expect(miss.unbound.slice()[0].eql(chord("q")));
    try testing.expect((try r.feed(s, f.tables, null, chord("q"), 0)) == .pass);
    // Leader times out after timeout_ms without a key.
    _ = try r.feed(s, f.tables, null, chord("ctrl+space"), 0);
    try testing.expect(!r.tick(1999));
    try testing.expect(r.tick(2000));
    try testing.expectEqualStrings("", try r.modeText(testing.allocator));
    try testing.expect((try r.feed(s, f.tables, null, chord("d"), 2001)) == .pass);
    // A custom leader and timeout.
    const custom: keys.Settings = .{ .leader = chord("ctrl+b"), .timeout_ms = 500 };
    try testing.expect((try r.feed(custom, f.tables, null, chord("ctrl+space"), 0)) == .pass);
    try testing.expect((try r.feed(custom, f.tables, null, chord("ctrl+b"), 0)) == .leader);
    try testing.expect(r.tick(500));
}

test "tag-scoped product tables are active only on matching panes" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const s = tmux_style;
    const shell: Tags = .{};
    var agent: Tags = .{};
    defer agent.deinit(testing.allocator);
    try agent.put(testing.allocator, "owner", "venom");
    // On a shell pane `a` after the leader is unbound.
    _ = try r.feed(s, f.tables, .matching(&shell), chord("ctrl+space"), 0);
    for (try r.next(x)) |n| try testing.expect(!n.key.eql(chord("a")));
    try testing.expect((try r.feed(s, f.tables, .matching(&shell), chord("a"), 0)) == .unbound);
    // On the agent pane which-key offers the table, then its keys.
    _ = try r.feed(s, f.tables, .matching(&agent), chord("ctrl+space"), 0);
    var saw_table = false;
    for (try r.next(x)) |n| saw_table = saw_table or (n.key.eql(chord("a")) and n.more and eq(u8, n.entry.table.name, "venom"));
    try testing.expect(saw_table);
    try testing.expect((try r.feed(s, f.tables, .matching(&agent), chord("a"), 0)) == .partial);
    try testing.expectEqualStrings("venom", r.table().?.name);
    try testing.expectEqualStrings("LEADER venom", try r.modeText(x));
    const hints = try r.next(x);
    try testing.expectEqual(@as(usize, 2), hints.len);
    try testing.expect(!hints[0].more);
    const run = try r.feed(s, f.tables, .matching(&agent), chord("a"), 0);
    const argv = try (keys.Placeholders{ .pane = "p4" }).argv(x, run.run.target.exec);
    try testing.expectEqualStrings("p4", argv[3]);
    // Activity is fixed when the leader is pressed: typing does not change it,
    // only `refocus` does (see below).
    _ = try r.feed(s, f.tables, .matching(&agent), chord("ctrl+space"), 0);
    try testing.expect((try r.feed(s, f.tables, .matching(&shell), chord("a"), 0)) == .partial);
    r.end();
}

test "refocus: the sequence goes on with the new pane's tables" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const s = tmux_style;
    const shell: Tags = .{};
    var agent: Tags = .{};
    defer agent.deinit(testing.allocator);
    try agent.put(testing.allocator, "owner", "venom");
    // Outside leader mode it does nothing, and the lock stays.
    try testing.expect(!try r.refocus(f.tables, .matching(&agent)));
    try testing.expect(!r.pending());
    r.lock();
    try testing.expect(!try r.refocus(f.tables, .matching(&agent)));
    try testing.expect(r.locked());
    try testing.expect((try r.feed(s, f.tables, null, chord("ctrl+alt+space"), 0)) == .unlocked);
    // The leader on a shell pane, then focus comes to the agent: the rows and
    // the next key are the agent's, and the deadline is not restarted.
    _ = try r.feed(s, f.tables, .matching(&shell), chord("ctrl+space"), 100);
    for (try r.next(x)) |n| try testing.expect(!n.key.eql(chord("a")));
    try testing.expect(!try r.refocus(f.tables, .matching(&agent)));
    try testing.expect(r.pending());
    try testing.expectEqual(@as(?i64, 2100), r.nextDeadline());
    var offered = false;
    for (try r.next(x)) |n| offered = offered or n.key.eql(chord("a"));
    try testing.expect(offered);
    try testing.expect((try r.feed(s, f.tables, .matching(&shell), chord("a"), 200)) == .partial);
    try testing.expectEqualStrings("venom", r.table().?.name);
    // Inside the table, focus to another agent pane: the same keys still lead
    // somewhere, so it goes on.
    try testing.expect(!try r.refocus(f.tables, .matching(&agent)));
    try testing.expectEqualStrings("LEADER venom", try r.modeText(x));
    try testing.expect((try r.feed(s, f.tables, .matching(&shell), chord("a"), 300)) == .run);
    try testing.expect(!r.pending());
    // Focus to a shell pane inside the table: the keys no longer resolve, so
    // leader mode ends and the next key is an ordinary key again.
    _ = try r.feed(s, f.tables, .matching(&agent), chord("ctrl+space"), 0);
    _ = try r.feed(s, f.tables, .matching(&agent), chord("a"), 0);
    try testing.expect(try r.refocus(f.tables, .matching(&shell)));
    try testing.expect(!r.pending() and r.table() == null);
    try testing.expect((try r.feed(s, f.tables, .matching(&shell), chord("a"), 0)) == .pass);
    // At the root nothing was typed, so it never cancels, even with no tables.
    _ = try r.feed(s, f.tables, .matching(&agent), chord("ctrl+space"), 0);
    try testing.expect(!try r.refocus(&.{}, null));
    try testing.expect(r.pending());
    r.end();
}

test "refocus: typed keys that are now a binding cancel, and do not run it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const on_agent = (try K.parseTable(x, .{
        .name = "a",
        .prefix = "t",
        .when = &.{.{ .key = "owner", .value = "venom" }},
        .bind = &.{.{ .key = "h", .local = "zoom" }},
    }, .product)).ok;
    // `t` is a prefix on the agent pane and a binding on the shell pane.
    const root_shell = (try K.parseTable(x, .{
        .name = "s",
        .when = &.{.{ .key = "owner", .value = "shell" }},
        .bind = &.{.{ .key = "t", .local = "detach" }},
    }, .user)).ok;
    const tables = [_]K.Table{ on_agent, root_shell };
    var agent: Tags = .{};
    defer agent.deinit(testing.allocator);
    try agent.put(testing.allocator, "owner", "venom");
    var shell: Tags = .{};
    defer shell.deinit(testing.allocator);
    try shell.put(testing.allocator, "owner", "shell");
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    _ = try r.feed(default_settings, &tables, .matching(&agent), chord("ctrl+a"), 0);
    try testing.expect((try r.feed(default_settings, &tables, .matching(&agent), chord("t"), 0)) == .partial);
    try testing.expect(try r.refocus(&tables, .matching(&shell)));
    try testing.expect(!r.pending());
}

test "refocus: a sticky group stays while its table does, popup still hidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const scoped = (try K.parseTable(x, .{
        .name = "t",
        .prefix = "t",
        .when = &.{.{ .key = "owner", .value = "venom" }},
        .groups = &.{.{ .key = "r", .label = "resize", .sticky = true }},
        .bind = &.{.{ .key = "r h", .local = "zoom" }},
    }, .product)).ok;
    const tables = [_]K.Table{ root, scoped };
    const s = default_settings;
    const shell: Tags = .{};
    var agent: Tags = .{};
    defer agent.deinit(testing.allocator);
    try agent.put(testing.allocator, "owner", "venom");
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    // A sticky group of a table that is always active survives any move.
    _ = try r.feed(s, &tables, .matching(&agent), chord("ctrl+a"), 0);
    _ = try r.feed(s, &tables, .matching(&agent), chord("["), 0);
    _ = try r.feed(s, &tables, .matching(&agent), chord("j"), 0);
    try testing.expect(r.popupHidden());
    try testing.expect(!try r.refocus(&tables, .matching(&shell)));
    try testing.expectEqualStrings("scroll", r.stickyGroup().?.label);
    try testing.expect(r.popupHidden());
    try testing.expectEqual(Local.focus_next, (try r.feed(s, &tables, .matching(&shell), chord("j"), 0)).run.target.local);
    r.end();
    // One of a scoped table goes on while the pane matches, and cancels when
    // it does not.
    _ = try r.feed(s, &tables, .matching(&agent), chord("ctrl+a"), 0);
    _ = try r.feed(s, &tables, .matching(&agent), chord("t"), 0);
    _ = try r.feed(s, &tables, .matching(&agent), chord("r"), 0);
    try testing.expectEqual(Local.zoom, (try r.feed(s, &tables, .matching(&agent), chord("h"), 0)).run.target.local);
    try testing.expect(!try r.refocus(&tables, .matching(&agent)));
    try testing.expectEqualStrings("resize", r.stickyGroup().?.label);
    try testing.expect(r.popupHidden());
    try testing.expect(try r.refocus(&tables, .matching(&shell)));
    try testing.expect(!r.pending() and r.stickyGroup() == null and !r.popupHidden());
}

test "refocus: a prefix that is sticky on one pane and plain on the next brings the popup back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const on_agent = (try K.parseTable(x, .{
        .name = "a",
        .prefix = "t",
        .when = &.{.{ .key = "owner", .value = "venom" }},
        .groups = &.{.{ .key = "r", .label = "resize", .sticky = true }},
        .bind = &.{.{ .key = "r h", .local = "zoom" }},
    }, .product)).ok;
    const on_shell = (try K.parseTable(x, .{
        .name = "s",
        .prefix = "t",
        .when = &.{.{ .key = "owner", .value = "shell" }},
        .groups = &.{.{ .key = "r", .label = "rows" }},
        .bind = &.{.{ .key = "r h", .local = "detach" }},
    }, .product)).ok;
    const tables = [_]K.Table{ on_agent, on_shell };
    const s = default_settings;
    var agent: Tags = .{};
    defer agent.deinit(testing.allocator);
    try agent.put(testing.allocator, "owner", "venom");
    var shell: Tags = .{};
    defer shell.deinit(testing.allocator);
    try shell.put(testing.allocator, "owner", "shell");
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    _ = try r.feed(s, &tables, .matching(&agent), chord("ctrl+a"), 0);
    _ = try r.feed(s, &tables, .matching(&agent), chord("t"), 0);
    _ = try r.feed(s, &tables, .matching(&agent), chord("r"), 0);
    _ = try r.feed(s, &tables, .matching(&agent), chord("h"), 0);
    try testing.expect(r.popupHidden() and r.stickyGroup() != null);
    try testing.expect(!try r.refocus(&tables, .matching(&shell)));
    try testing.expect(r.pending() and r.stickyGroup() == null);
    try testing.expect(!r.popupHidden());
    try testing.expectEqual(Local.detach, (try r.feed(s, &tables, .matching(&shell), chord("h"), 0)).run.target.local);
    try testing.expect(!r.pending());
}

test "lock mode passes every key, the leader too, until unlock" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    const s = tmux_style;
    _ = try r.feed(s, f.tables, null, chord("ctrl+space"), 0);
    const l = try r.feed(s, f.tables, null, chord("L"), 0);
    try testing.expectEqual(Local.lock, l.run.target.local);
    // The client runs its lock command.
    r.lock();
    try testing.expect(r.locked());
    try testing.expectEqualStrings("LOCK", try r.modeText(testing.allocator));
    try testing.expect((try r.feed(s, f.tables, null, chord("ctrl+space"), 0)) == .pass);
    try testing.expect(!r.tick(1_000_000));
    try testing.expect((try r.feed(s, f.tables, null, chord("ctrl+alt+space"), 0)) == .unlocked);
    try testing.expect((try r.feed(s, f.tables, null, chord("ctrl+space"), 0)) == .leader);
    // More keys than any sequence ends leader mode.
    for (0..keys.max_sequence) |_| _ = try r.feed(s, f.tables, .{ .ctx = &f, .f = struct {
        fn all(_: *const anyopaque, _: []const @import("tags.zig").Tag) bool {
            return true;
        }
    }.all }, chord("a"), 0);
    try testing.expect(!r.pending());
}

test "chordOf falls back to the Latin base key on a non-Latin layout" {
    const bindings = comptime [_]K.Binding{
        K.binding("d", .{ .local = .detach }),
        K.binding("D", .{ .local = .zoom }),
        K.binding("δ", .{ .local = .focus_next }),
    };
    const table: K.Table = .{ .name = "venomx", .layer = .builtin, .bindings = &bindings };
    const tables = [_]K.Table{table};
    const alpha = 945; // Greek alpha, on the Latin `a` key.
    const delta = 948; // Greek delta, on the Latin `d` key.
    const ctrl: keys.Mods = .{ .ctrl = true };
    const s: keys.Settings = .{ .leader = chord("ctrl+a"), .unlock = chord("ctrl+alt+a"), .timeout_ms = 2000 };
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    // CSI 945::97;5u is the leader; without a base key it stays the letter.
    try testing.expect(r.chordOf(s, alpha, ctrl, null, null, 'a').eql(s.leader));
    try testing.expect(r.chordOf(s, alpha, ctrl, null, null, null).eql(.{ .cp = alpha, .mods = ctrl }));
    // The unlock key too, and in lock mode.
    r.lock();
    const unlock = r.chordOf(s, alpha, .{ .ctrl = true, .alt = true }, null, null, 'a');
    try testing.expect((try r.feed(s, &tables, null, unlock, 0)) == .unlocked);
    // A non-ASCII base and a key already in ASCII stay what they are.
    try testing.expect(r.chordOf(s, alpha, ctrl, null, null, 0x3b1).eql(.{ .cp = alpha, .mods = ctrl }));
    try testing.expect(r.chordOf(s, 'b', ctrl, null, null, 'a').eql(chord("ctrl+b")));
    try testing.expect(r.chordOf(s, @backingInt(@import("types").Input.NamedKey.up), ctrl, null, null, 'a').eql(chord("ctrl+up")));
    // Shift goes with the base key: `D` from the Greek layout's capital.
    try testing.expect(r.chordOf(s, delta, .{ .shift = true }, 916, null, 'd').eql(chord("D")));
    // The character itself wins when it is the leader or the unlock key.
    const greek_leader: keys.Settings = .{ .leader = .{ .cp = alpha, .mods = ctrl }, .unlock = .{ .cp = alpha, .mods = .{ .ctrl = true, .alt = true } }, .timeout_ms = 2000 };
    try testing.expect(r.chordOf(greek_leader, alpha, ctrl, null, null, 'a').eql(greek_leader.leader));
    try testing.expect(r.chordOf(greek_leader, alpha, .{ .ctrl = true, .alt = true }, null, null, 'a').eql(greek_leader.unlock));
    // Outside leader mode a binding's own character is not looked at.
    try testing.expect(r.chordOf(s, delta, .{}, null, null, 'd').eql(chord("d")));
    // In leader mode a binding at this level keeps its character, and any
    // other key falls back: `δ` runs its binding, and `α` on `a` is unbound `a`.
    try testing.expect((try r.feed(s, &tables, null, r.chordOf(s, alpha, ctrl, null, null, 'a'), 0)) == .leader);
    try testing.expectEqual(Local.focus_next, (try r.feed(s, &tables, null, r.chordOf(s, delta, .{}, null, null, 'd'), 0)).run.target.local);
    try testing.expect((try r.feed(s, &tables, null, r.chordOf(s, alpha, ctrl, null, null, 'a'), 0)) == .leader);
    try testing.expect(r.chordOf(s, alpha, .{}, null, null, 'a').eql(chord("a")));
    // A Latin binding is reached from a layout that has no such character bound.
    const no_delta = [_]K.Table{.{ .name = "venomx", .layer = .builtin, .bindings = bindings[0..2] }};
    r.end();
    _ = try r.feed(s, &no_delta, null, s.leader, 0);
    try testing.expectEqual(Local.detach, (try r.feed(s, &no_delta, null, r.chordOf(s, delta, .{}, null, null, 'd'), 0)).run.target.local);
}

test "conflicts in a layer are reported; higher layers shadow lower ones" {
    var f = try Fixture.init();
    defer f.deinit();
    const x = f.arena.allocator();
    const other = (try K.parseTable(x, .{ .name = "other", .prefix = "a", .bind = &.{.{ .key = "x", .local = "zoom" }} }, .product)).ok;
    var r = try K.resolve(x, &.{ f.tables[0], f.tables[1], other }, null);
    try testing.expectEqual(@as(usize, 1), r.conflicts.len);
    try testing.expectEqual(keys.Layer.product, r.conflicts[0].layer);
    try testing.expectEqualStrings("venom", r.conflicts[0].tables[0]);
    try testing.expectEqualStrings("other", r.conflicts[0].tables[1]);
    const override = (try K.parseTable(x, .{ .name = "venom-override", .prefix = "a", .bind = &.{} }, .user)).ok;
    r = try K.resolve(x, &.{ f.tables[0], f.tables[1], override }, null);
    try testing.expectEqual(@as(usize, 0), r.conflicts.len);
    try testing.expectEqual(@as(usize, 2), r.shadowed.len);
    for (r.shadowed) |sh| {
        try testing.expectEqualStrings("venom", sh.table);
        try testing.expectEqual(keys.Layer.user, sh.by_layer);
    }
    try testing.expect(r.lookup(&.{chord("a")}) == .none);
}

test "placeholders are whole argv elements and whole JSON strings (the token scrub is the client's exec environment)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p: keys.Placeholders = .{ .pane = "p4", .session = "s0", .popup_ticket = "tk1" };
    const argv = try p.argv(a, &.{ "venom", "approve", "--pane", "{pane}", "x{pane}", "{session}", "{window}" });
    try testing.expectEqualStrings("p4", argv[3]);
    try testing.expectEqualStrings("x{pane}", argv[4]);
    try testing.expectEqualStrings("s0", argv[5]);
    try testing.expectEqualStrings("", argv[6]);
    const v = try p.args(a, "{\"ticket\":\"{popup_ticket}\",\"argv\":[\"venom\",\"{pane}\"],\"note\":\"in {pane}\"}");
    try testing.expectEqualStrings("tk1", v.object.get("ticket").?.string);
    try testing.expectEqualStrings("p4", v.object.get("argv").?.array.items[1].string);
    try testing.expectEqualStrings("in {pane}", v.object.get("note").?.string);
    try testing.expect(keys.Placeholders.needsTicket(&.{ "venom", "{popup_ticket}" }));
    try testing.expect(!keys.Placeholders.needsTicket(&.{"venom"}));
    try testing.expectEqual(@as(?usize, 0), keys.placeholder("{pane}"));
    try testing.expect(keys.spliced("x{pane}") and !keys.spliced("{pane}") and !keys.spliced("pane"));
}

// ------------------------------------------------- labels, groups, sticky

/// The documented `keys` defaults, as a client's config gives them.
const default_settings: keys.Settings = .{ .leader = parseChord("ctrl+a").?, .unlock = parseChord("ctrl+alt+a").?, .timeout_ms = 0 };
/// A tree that exercises labels, groups and `escape`: a product table under `v` with a labelled
/// group, and a built-in table with a sticky `[` group at the root.
const scroll_bindings = blk: {
    @setEvalBranchQuota(100_000);
    break :blk [_]K.Binding{
        K.labeled("[ j", .{ .local = .focus_next }, "down"),
        K.labeled("[ down", .{ .local = .focus_next }, "down"),
        K.labeled("[ k", .{ .local = .zoom }, "up"),
        K.labeled("h", .{ .local = .focus_next }, "focus left"),
        K.labeled("left", .{ .local = .focus_next }, "focus left"),
        K.binding("d", .{ .local = .detach }),
        K.binding("escape", .{ .local = .clear_selection }),
        K.binding("y z", .{ .local = .zoom }),
    };
};
const scroll_groups = [_]keys.Group{keys.group("[", "scroll", true)};
const root: K.Table = .{ .name = "venomx", .layer = .builtin, .groups = &scroll_groups, .bindings = &scroll_bindings };
fn venomTable(x: std.mem.Allocator) !K.Table {
    return (try K.parseTable(x, .{
        .name = "venom",
        .prefix = "v",
        .label = "venom agents",
        .groups = &.{.{ .key = "a", .label = "agents" }},
        .bind = &.{
            .{ .key = "a s", .label = "stop", .exec = &.{ "venom", "agent", "stop", "--pane", "{pane}" } },
            .{ .key = "s", .label = "settings", .verb = "pane.popup" },
            .{ .key = "u", .exec = &.{ "venom", "usage" } },
            .{ .key = "x", .verb = "pane.split" },
            .{ .key = "z", .local = "zoom" },
        },
    }, .product)).ok;
}
fn press(r: *K.Router, s: keys.Settings, tables: []const K.Table, text: []const u8) !K.Router.Outcome {
    return r.feed(s, tables, null, chord(text), 0);
}
fn rowLabel(rows: []const K.Next, key: []const u8) []const u8 {
    for (rows) |n| if (n.key.eql(chord(key))) return n.label;
    return "";
}
fn rowOf(rows: []const K.Next, key: []const u8) K.Next {
    for (rows) |n| if (n.key.eql(chord(key))) return n;
    unreachable;
}

test "labels and groups: validated on parse, and a group needs a binding under it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const t = try venomTable(x);
    try testing.expectEqualStrings("venom agents", t.label.?);
    try testing.expectEqualStrings("agents", t.groups[0].label);
    try testing.expect(!t.groups[0].sticky and t.groups[0].seq.keys[0].eql(chord("a")));
    try testing.expectEqualStrings("stop", t.bindings[0].label.?);
    try testing.expect(t.bindings[2].label == null);

    const longest = "x234567890123456789012345678901234567890"[0..keys.max_label];
    const long = longest ++ "x";
    try testing.expect(keys.validLabel(longest) and keys.validLabel("focus ←"));
    try testing.expect(!keys.validLabel("") and !keys.validLabel(long) and !keys.validLabel("a\nb") and !keys.validLabel("a\x1b[0m") and !keys.validLabel("\xff"));
    const one = &[_]keys.BindingConfig{.{ .key = "a s", .local = "zoom" }};
    const fails = [_]struct { keys.TableConfig, []const u8, []const u8 }{
        .{ .{ .name = "t", .label = "", .bind = one }, "label", "label" },
        .{ .{ .name = "t", .label = long, .bind = one }, "label", "label" },
        .{ .{ .name = "t", .bind = &.{.{ .key = "a", .label = "a\tb", .local = "zoom" }} }, "bindings.0.label", "label" },
        .{ .{ .name = "t", .groups = &.{.{ .key = "a" }}, .bind = one }, "groups.0.label", "label" },
        .{ .{ .name = "t", .groups = &.{.{ .key = "", .label = "x" }}, .bind = one }, "groups.0.key", "key" },
        // Nothing under it, or the group's own key is the binding.
        .{ .{ .name = "t", .groups = &.{.{ .key = "b", .label = "x" }}, .bind = one }, "groups.0.key", "group" },
        .{ .{ .name = "t", .groups = &.{.{ .key = "a s", .label = "x" }}, .bind = one }, "groups.0.key", "group" },
        .{ .{ .name = "t", .groups = &.{ .{ .key = "a", .label = "x" }, .{ .key = "a", .label = "y" } }, .bind = one }, "groups.1.key", "duplicate" },
        // Leader mode takes these keys first, so the binding could never run.
        .{ .{ .name = "t", .bind = &.{.{ .key = "backspace", .local = "zoom" }} }, "bindings.0.key", "reserved" },
        .{ .{ .name = "t", .bind = &.{.{ .key = "a backspace", .local = "zoom" }} }, "bindings.0.key", "reserved" },
        .{ .{ .name = "t", .bind = &.{.{ .key = "escape a", .local = "zoom" }} }, "bindings.0.key", "reserved" },
        .{ .{ .name = "t", .prefix = "esc", .bind = one }, "prefix", "reserved" },
        .{ .{ .name = "t", .prefix = "backspace", .bind = one }, "prefix", "reserved" },
    };
    for (fails) |f| {
        const got = (try K.parseTable(x, f[0], .user)).failed;
        try testing.expectEqualStrings(f[1], got.param);
        try testing.expectEqualStrings(f[2], got.reason);
    }
    // `escape` as a last key stays bindable (it clears the selection).
    try testing.expect((try K.parseTable(x, .{ .name = "t", .bind = &.{.{ .key = "a escape", .local = "zoom" }} }, .user)) == .ok);
}

test "labels and groups survive the keys.list JSON form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const t = (try K.parseTable(x, .{
        .name = "venom",
        .prefix = "v",
        .label = "agents and more",
        .groups = &.{ .{ .key = "a", .label = "agents" }, .{ .key = "r", .label = "resize", .sticky = true } },
        .bind = &.{ .{ .key = "a s", .label = "stop", .local = "zoom" }, .{ .key = "r h", .local = "zoom" } },
    }, .product)).ok;
    const json = try K.tableJson(x, &t);
    const back = (try K.tableFromJson(x, json)).?;
    try testing.expectEqualStrings("agents and more", back.label.?);
    try testing.expectEqualStrings("stop", back.bindings[0].label.?);
    try testing.expect(back.bindings[1].label == null);
    try testing.expectEqual(@as(usize, 2), back.groups.len);
    try testing.expectEqualStrings("agents", back.groups[0].label);
    try testing.expect(!back.groups[0].sticky and back.groups[1].sticky);
    // A table with neither reports neither.
    const plain = try K.tableJson(x, &builtin);
    try testing.expect(plain.object.get("label") == null and plain.object.get("groups") == null);
    try testing.expect(plain.object.get("bindings").?.array.items[0].object.get("label") == null);
    // Wrong shapes are not tables.
    for ([_][]const u8{
        "{\"name\":\"t\",\"layer\":\"product\",\"label\":1}",
        "{\"name\":\"t\",\"layer\":\"product\",\"groups\":{}}",
        "{\"name\":\"t\",\"layer\":\"product\",\"groups\":[{\"key\":\"a\"}]}",
        "{\"name\":\"t\",\"layer\":\"product\",\"groups\":[{\"key\":\"a\",\"label\":\"x\",\"sticky\":1}]}",
        "{\"name\":\"t\",\"layer\":\"product\",\"bindings\":[{\"key\":\"a\",\"local\":\"zoom\",\"label\":1}]}",
    }) |text| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, x, text, .{});
        try testing.expect((try K.tableFromJson(x, v)) == null);
    }
}

test "next returns labels and group names; path names what was typed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const tables = [_]K.Table{ root, try venomTable(x) };
    const r = try K.resolve(x, &tables, null);
    const top = try r.next(x, &.{});
    // A table's sub-prefix by its label, a group by its label, sticky flagged.
    try testing.expectEqualStrings("venom agents", rowLabel(top, "v"));
    try testing.expect(rowOf(top, "v").more and !rowOf(top, "v").sticky);
    try testing.expectEqualStrings("scroll", rowLabel(top, "["));
    try testing.expect(rowOf(top, "[").more and rowOf(top, "[").sticky);
    // A binding by label, else its local action; an unnamed prefix is `…`.
    try testing.expectEqualStrings("focus left", rowLabel(top, "h"));
    try testing.expectEqualStrings("detach", rowLabel(top, "d"));
    try testing.expectEqualStrings("…", rowLabel(top, "y"));
    try testing.expect(rowOf(top, "y").more);
    // Inside the table: a group row, a label, then the verb and `argv[0]`.
    const inner = try r.next(x, &.{chord("v")});
    try testing.expectEqualStrings("agents", rowLabel(inner, "a"));
    try testing.expect(rowOf(inner, "a").more);
    try testing.expectEqualStrings("settings", rowLabel(inner, "s"));
    try testing.expectEqualStrings("venom", rowLabel(inner, "u"));
    try testing.expectEqualStrings("pane.split", rowLabel(inner, "x"));
    try testing.expectEqualStrings("zoom", rowLabel(inner, "z"));
    try testing.expectEqualStrings("stop", rowLabel(try r.next(x, &.{ chord("v"), chord("a") }), "s"));
    // A table with no label is named by its name.
    const bare = (try K.parseTable(x, .{ .name = "mine", .prefix = "m", .bind = &.{.{ .key = "a", .local = "zoom" }} }, .user)).ok;
    try testing.expectEqualStrings("mine", rowLabel(try (try K.resolve(x, &.{bare}, null)).next(x, &.{}), "m"));
    // Same target and label share a row; a different label or target does not.
    try testing.expect(rowOf(top, "h").sameRow(rowOf(top, "left")));
    try testing.expect(!rowOf(top, "h").sameRow(rowOf(top, "d")));
    try testing.expect(!rowOf(top, "h").sameRow(rowOf(top, "[")));
    // The popup header, by table and group label.
    const header = try r.path(x, &.{ chord("v"), chord("a") });
    try testing.expectEqual(@as(usize, 2), header.len);
    try testing.expectEqualStrings("venom agents", header[0]);
    try testing.expectEqualStrings("agents", header[1]);
    try testing.expectEqualStrings("y", (try r.path(x, &.{chord("y")}))[0]);
    try testing.expectEqual(@as(usize, 0), (try r.path(x, &.{})).len);
    // A shadowed table's group is gone with its bindings.
    const hides = (try K.parseTable(x, .{ .name = "mine", .prefix = "v", .bind = &.{.{ .key = "a b", .local = "zoom" }} }, .user)).ok;
    const hidden = try K.resolve(x, &.{ tables[1], hides }, null);
    try testing.expectEqualStrings("mine", rowLabel(try hidden.next(x, &.{}), "v"));
    try testing.expectEqualStrings("…", rowLabel(try hidden.next(x, &.{chord("v")}), "a"));
}

test "timeout_ms = 0 never times out; a non-zero one still does" {
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    const tables = [_]K.Table{root};
    const s = default_settings;
    try testing.expect((try r.feed(s, &tables, null, chord("ctrl+a"), 0)) == .leader);
    try testing.expect(r.nextDeadline() == null);
    try testing.expect(!r.tick(std.math.maxInt(i64) - 1));
    try testing.expect(r.pending());
    try testing.expect((try r.feed(s, &tables, null, chord("y"), 5)) == .partial);
    try testing.expect(!r.tick(std.math.maxInt(i64) - 1));
    try testing.expect(r.pending());
    r.end();
    const short: keys.Settings = .{ .leader = default_settings.leader, .timeout_ms = 100 };
    _ = try r.feed(short, &tables, null, chord("ctrl+a"), 0);
    try testing.expectEqual(@as(?i64, 100), r.nextDeadline());
    _ = try r.feed(short, &tables, null, chord("y"), 50);
    try testing.expectEqual(@as(?i64, 150), r.nextDeadline());
    try testing.expect(!r.tick(149) and r.tick(150));
    try testing.expect(r.nextDeadline() == null);
}

test "esc cancels at any level; a bound escape runs as it does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tables = [_]K.Table{ root, try venomTable(arena.allocator()) };
    const s = default_settings;
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    // Bound at the root: leader mode ends and the binding runs.
    _ = try press(&r, s, &tables, "ctrl+a");
    try testing.expectEqual(Local.clear_selection, (try press(&r, s, &tables, "esc")).run.target.local);
    try testing.expect(!r.pending());
    // Not bound in a sub-prefix: cancelled, and nothing reaches the pane.
    _ = try press(&r, s, &tables, "ctrl+a");
    _ = try press(&r, s, &tables, "v");
    const out = try press(&r, s, &tables, "esc");
    try testing.expect(out == .unbound and out.unbound.slice()[1].eql(chord("esc")));
    try testing.expect(!r.pending());
    try testing.expect((try press(&r, s, &tables, "x")) == .pass);
    // Without a binding at the root either.
    const bare = [_]K.Table{builtinWithoutEscape};
    _ = try press(&r, s, &bare, "ctrl+a");
    try testing.expect((try press(&r, s, &bare, "esc")) == .unbound);
    try testing.expect(!r.pending());
}
const no_escape_bindings = [_]K.Binding{K.binding("d", .{ .local = .detach })};
const builtinWithoutEscape: K.Table = .{ .name = "venomx", .layer = .builtin, .bindings = &no_escape_bindings };

test "backspace goes up one level, and out from the root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const tables = [_]K.Table{ root, try venomTable(x) };
    const s = default_settings;
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    _ = try press(&r, s, &tables, "ctrl+a");
    _ = try press(&r, s, &tables, "v");
    _ = try press(&r, s, &tables, "a");
    try testing.expectEqualStrings("stop", rowLabel(try r.next(x), "s"));
    try testing.expectEqualStrings("agents", (try r.path(x))[1]);
    // Up to the table: its keys are offered again, and they still work.
    try testing.expect((try press(&r, s, &tables, "backspace")) == .partial);
    try testing.expectEqual(@as(u8, 1), r.seq.len);
    try testing.expectEqualStrings("settings", rowLabel(try r.next(x), "s"));
    try testing.expectEqualStrings("LEADER venom", try r.modeText(x));
    // Up to the root, then out.
    try testing.expect((try press(&r, s, &tables, "backspace")) == .leader);
    try testing.expectEqual(@as(u8, 0), r.seq.len);
    try testing.expect(r.pending());
    try testing.expectEqualStrings("LEADER", try r.modeText(x));
    const out = try press(&r, s, &tables, "backspace");
    try testing.expect(out == .unbound and out.unbound.slice()[0].eql(chord("backspace")));
    try testing.expect(!r.pending());
    // It also refreshes a non-zero timeout.
    const short: keys.Settings = .{ .leader = default_settings.leader, .timeout_ms = 100 };
    _ = try r.feed(short, &tables, null, chord("ctrl+a"), 0);
    _ = try r.feed(short, &tables, null, chord("v"), 50);
    _ = try r.feed(short, &tables, null, chord("backspace"), 120);
    try testing.expectEqual(@as(?i64, 220), r.nextDeadline());
    r.end();
}

test "an unbound key cancels, is swallowed, and runs nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tables = [_]K.Table{ root, try venomTable(arena.allocator()) };
    const s = default_settings;
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    for ([_][]const []const u8{ &.{"q"}, &.{ "v", "q" }, &.{ "v", "a", "q" } }) |typed| {
        _ = try press(&r, s, &tables, "ctrl+a");
        var out: K.Router.Outcome = .pass;
        for (typed) |k| out = try press(&r, s, &tables, k);
        // Swallowed: not `pass`, and it reports what was typed.
        try testing.expect(out == .unbound);
        try testing.expectEqual(typed.len, out.unbound.len);
        try testing.expect(!r.pending());
        // The next key is an ordinary key again.
        try testing.expect((try press(&r, s, &tables, "q")) == .pass);
    }
    // `?` is unbound outside a sticky group too.
    _ = try press(&r, s, &tables, "ctrl+a");
    try testing.expect((try press(&r, s, &tables, "?")) == .unbound);
}

test "a sticky group stays active after a binding, until esc" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const tables = [_]K.Table{root};
    const s = default_settings;
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    _ = try press(&r, s, &tables, "ctrl+a");
    try testing.expect(r.stickyGroup() == null);
    try testing.expect((try press(&r, s, &tables, "[")) == .partial);
    try testing.expectEqualStrings("scroll", r.stickyGroup().?.label);
    try testing.expectEqualStrings("LEADER scroll", try r.modeText(x));
    try testing.expect(!r.popupHidden());
    // Every binding runs and leaves the client in the group, popup hidden.
    for ([_]struct { []const u8, Local }{ .{ "j", .focus_next }, .{ "k", .zoom }, .{ "down", .focus_next }, .{ "j", .focus_next } }) |step| {
        const out = try press(&r, s, &tables, step[0]);
        try testing.expectEqual(step[1], out.run.target.local);
        try testing.expect(r.pending() and r.popupHidden());
        try testing.expectEqualStrings("scroll", r.stickyGroup().?.label);
        try testing.expectEqualStrings("LEADER scroll", try r.modeText(x));
        try testing.expectEqual(@as(u8, 1), r.seq.len);
    }
    // `?` shows the popup again, and the group is still there.
    try testing.expect((try press(&r, s, &tables, "?")) == .partial);
    try testing.expect(!r.popupHidden() and r.stickyGroup() != null);
    try testing.expectEqualStrings("down", rowLabel(try r.next(x), "j"));
    // And the next binding hides it again.
    _ = try press(&r, s, &tables, "j");
    try testing.expect(r.popupHidden());
    // `esc` ends it. No `[ escape` is bound, so it is a plain cancel.
    try testing.expect((try press(&r, s, &tables, "esc")) == .unbound);
    try testing.expect(!r.pending() and r.stickyGroup() == null and !r.popupHidden());
    try testing.expect((try press(&r, s, &tables, "j")) == .pass);
    // `backspace` leaves the group for the level above, and shows the popup.
    _ = try press(&r, s, &tables, "ctrl+a");
    _ = try press(&r, s, &tables, "[");
    _ = try press(&r, s, &tables, "j");
    try testing.expect((try press(&r, s, &tables, "backspace")) == .leader);
    try testing.expect(r.pending() and r.stickyGroup() == null and !r.popupHidden());
    // An unbound key still cancels there, swallowed.
    _ = try press(&r, s, &tables, "[");
    _ = try press(&r, s, &tables, "j");
    try testing.expect((try press(&r, s, &tables, "q")) == .unbound);
    try testing.expect(!r.pending());
    // A binding outside any sticky group still ends leader mode.
    _ = try press(&r, s, &tables, "ctrl+a");
    try testing.expectEqual(Local.detach, (try press(&r, s, &tables, "d")).run.target.local);
    try testing.expect(!r.pending());
    // A non-zero timeout restarts on each binding, and ends the group.
    const short: keys.Settings = .{ .leader = default_settings.leader, .timeout_ms = 100 };
    _ = try r.feed(short, &tables, null, chord("ctrl+a"), 0);
    _ = try r.feed(short, &tables, null, chord("["), 0);
    _ = try r.feed(short, &tables, null, chord("j"), 90);
    try testing.expect(!r.tick(189) and r.tick(190));
    try testing.expect(r.stickyGroup() == null);
}

test "a sticky group inside a table returns to its innermost sticky level" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const table = (try K.parseTable(x, .{
        .name = "t",
        .prefix = "t",
        .groups = &.{ .{ .key = "r", .label = "resize", .sticky = true }, .{ .key = "r f", .label = "fine" } },
        .bind = &.{ .{ .key = "r h", .local = "zoom" }, .{ .key = "r f h", .local = "focus_next" }, .{ .key = "q", .local = "detach" } },
    }, .product)).ok;
    const tables = [_]K.Table{table};
    const s = default_settings;
    var r = K.Router.init(testing.allocator);
    defer r.deinit();
    _ = try press(&r, s, &tables, "ctrl+a");
    _ = try press(&r, s, &tables, "t");
    try testing.expectEqualStrings("LEADER t", try r.modeText(x));
    _ = try press(&r, s, &tables, "r");
    try testing.expectEqualStrings("LEADER resize", try r.modeText(x));
    // A non-sticky group inside: its binding returns to the sticky level.
    try testing.expect((try press(&r, s, &tables, "f")) == .partial);
    try testing.expect(r.stickyGroup() == null and !r.popupHidden());
    try testing.expectEqual(Local.focus_next, (try press(&r, s, &tables, "h")).run.target.local);
    try testing.expectEqual(@as(u8, 2), r.seq.len);
    try testing.expectEqualStrings("resize", r.stickyGroup().?.label);
    try testing.expect((try press(&r, s, &tables, "f")) == .partial);
    try testing.expect(!r.popupHidden());
    r.end();
    // The table's other bindings do not stick.
    _ = try press(&r, s, &tables, "ctrl+a");
    _ = try press(&r, s, &tables, "t");
    try testing.expectEqual(Local.detach, (try press(&r, s, &tables, "q")).run.target.local);
    try testing.expect(!r.pending());
}

// ----------------------------------------------------------- keys.prefixes

test "keys.prefixes: parse, the user wins per name, and only sub-prefixed tables move" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const user = (try keys.parsePrefixes(x, &.{.{ .name = "venom", .prefix = "a" }})).ok;
    const defaults = (try keys.parsePrefixes(x, &.{ .{ .name = "venom", .prefix = "b" }, .{ .name = "venom-os", .prefix = "O" } })).ok;
    const moves = try keys.mergePrefixes(x, defaults, user);
    try testing.expectEqual(@as(usize, 2), moves.len);
    try testing.expect(keys.effectivePrefix(moves, "venom", chord("v")).?.eql(chord("a")));
    try testing.expect(keys.effectivePrefix(moves, "venom-os", chord("o")).?.eql(chord("O")));
    // Not named: as registered. No sub-prefix: stays right after the leader.
    try testing.expect(keys.effectivePrefix(moves, "other", chord("x")).?.eql(chord("x")));
    try testing.expect(keys.effectivePrefix(moves, "venom", null) == null);
    // Defaults alone apply, and an empty list moves nothing.
    try testing.expect(keys.effectivePrefix(try keys.mergePrefixes(x, defaults, &.{}), "venom", chord("v")).?.eql(chord("b")));
    try testing.expect(keys.effectivePrefix(&.{}, "venom", chord("v")).?.eql(chord("v")));
    // Bad entries name the entry.
    const fails = [_]struct { []const keys.PrefixConfig, []const u8, []const u8 }{
        .{ &.{.{ .name = "Bad", .prefix = "a" }}, "prefixes.0.name", "name" },
        .{ &.{.{ .name = "venom", .prefix = "hyper+a" }}, "prefixes.0.prefix", "key" },
        .{ &.{.{ .name = "venom" }}, "prefixes.0.prefix", "key" },
        .{ &.{.{ .name = "venom", .prefix = "backspace" }}, "prefixes.0.prefix", "reserved" },
        .{ &.{.{ .name = "venom", .prefix = "esc" }}, "prefixes.0.prefix", "reserved" },
        .{ &.{ .{ .name = "venom", .prefix = "a" }, .{ .name = "venom", .prefix = "b" } }, "prefixes.1.name", "duplicate" },
    };
    for (fails) |f| {
        const got = (try keys.parsePrefixes(x, f[0])).failed;
        try testing.expectEqualStrings(f[1], got.param);
        try testing.expectEqualStrings(f[2], got.reason);
    }
}

test "keys.prefixes is read from a config layer, with labels and groups" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const layer = (try keys.parseLayerConfig(x,
        \\.{
        \\    .status = .{ .position = .top },
        \\    .keys = .{
        \\        .leader = "ctrl+a",
        \\        .prefixes = .{ .{ .name = "venom", .prefix = "a" } },
        \\        .tables = .{ .{
        \\            .name = "mine",
        \\            .prefix = "m",
        \\            .label = "my keys",
        \\            .groups = .{ .{ .key = "r", .label = "resize", .sticky = true } },
        \\            .bind = .{ .{ .key = "r h", .label = "left", .local = "zoom" } },
        \\        } },
        \\    },
        \\}
    )).ok;
    try testing.expectEqualStrings("ctrl+a", layer.leader.?);
    const moves = (try keys.parsePrefixes(x, layer.prefixes)).ok;
    try testing.expect(moves[0].prefix.eql(chord("a")));
    const t = (try K.parseTable(x, layer.tables[0], .user)).ok;
    try testing.expectEqualStrings("my keys", t.label.?);
    try testing.expect(t.groups[0].sticky);
    try testing.expectEqualStrings("left", t.bindings[0].label.?);
    // A file with no `keys`, and one that is not a config.
    try testing.expectEqual(@as(usize, 0), (try keys.parseLayerConfig(x, ".{}")).ok.prefixes.len);
    try testing.expectError(error.Unreadable, keys.parseLayerConfig(x, ".{ .keys = 1 }"));
}

test "config check names a typo anywhere under keys; sibling sections stay the product's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    for ([_]struct { []const u8, []const u8 }{
        .{ ".{ .keys = .{ .prefixs = .{} } }", "keys.prefixs" },
        .{ ".{ .keys = .{ .leaderr = \"ctrl+a\" } }", "keys.leaderr" },
        .{ ".{ .keys = .{ .prefixes = .{ .{ .name = \"venom\", .prefx = \"a\" } } } }", "keys.prefixes.0.prefx" },
        .{ ".{ .keys = .{ .tables = .{ .{ .name = \"a\" }, .{ .name = \"b\", .lable = \"x\" } } } }", "keys.tables.1.lable" },
        .{ ".{ .keys = .{ .tables = .{ .{ .name = \"a\", .bind = .{ .{ .key = \"z\", .lable = \"x\" } } } } } }", "keys.tables.0.bind.0.lable" },
        .{ ".{ .keys = .{ .tables = .{ .{ .name = \"a\", .groups = .{ .{ .key = \"s\", .stickey = true } } } } } }", "keys.tables.0.groups.0.stickey" },
        .{ ".{ .keys = .{ .tables = .{ .{ .name = \"a\", .when = .{ .{ .key = \"k\", .val = \"v\" } } } } } }", "keys.tables.0.when.0.val" },
    }) |case| {
        const failed = (try keys.parseLayerConfig(x, case[0])).failed;
        try testing.expectEqualStrings(case[1], failed.param);
        try testing.expectEqualStrings("unknown_field", failed.reason);
    }
    // Other sections are not this parser's to judge, typos and all.
    try testing.expectEqual(@as(usize, 0), (try keys.parseLayerConfig(x, ".{ .statuss = 1, .floats = .{ .anything = true } }")).ok.tables.len);
    // A known field of the wrong type is unreadable, not unknown.
    try testing.expectError(error.Unreadable, keys.parseLayerConfig(x, ".{ .keys = .{ .tables = 1 } }"));
    try testing.expectError(error.Unreadable, keys.parseLayerConfig(x, ".{ .keys = .{ .leader = 1 } }"));
    try testing.expectError(error.Unreadable, keys.parseLayerConfig(x, ".{ .keys = "));
}

test "config check takes every keys config field and the configs products ship" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const scalars = (try keys.parseLayerConfig(x,
        \\.{ .keys = .{ .leader = "ctrl+a", .unlock = "ctrl+alt+a", .popup_delay_ms = 200, .timeout_ms = 0, .tables = .{}, .prefixes = .{} } }
    )).ok;
    try testing.expectEqualStrings("ctrl+alt+a", scalars.unlock.?);
    try testing.expectEqual(@as(?u32, 200), scalars.popup_delay_ms);
    try testing.expectEqual(@as(?u32, 0), scalars.timeout_ms);
    // Unset scalars stay null, so a caller can tell this layer did not set them.
    try testing.expectEqual(@as(?[]const u8, null), (try keys.parseLayerConfig(x, ".{ .keys = .{} }")).ok.leader);
    // The shape of venom-os's defaults.zon and of the sample in venomx's README.
    const shipped = (try keys.parseLayerConfig(x,
        \\.{
        \\    .daemon = .{ .interactive_start = false },
        \\    .floats = .{ .presets = .{ .@"venom-os.settings" = .{ .width = "80%", .anchor = .center } } },
        \\    .keys = .{
        \\        .leader = "ctrl+a",
        \\        .tables = .{
        \\            .{ .name = "venom-os", .prefix = "g", .bind = .{
        \\                .{ .key = "g", .verb = "window.create", .args = "{\"name\":\"lazygit\"}" },
        \\            } },
        \\            .{ .name = "mine", .prefix = "m", .label = "mine", .when = .{ .{ .key = "role", .value = "agent" } }, .groups = .{
        \\                .{ .key = "s", .label = "size", .sticky = true },
        \\            }, .bind = .{
        \\                .{ .key = "z", .label = "zoom it", .local = "zoom" },
        \\                .{ .key = "x", .exec = .{ "lazygit", "-p", "{cwd}" } },
        \\            } },
        \\        },
        \\        .prefixes = .{ .{ .name = "venom", .prefix = "a" } },
        \\    },
        \\}
    )).ok;
    try testing.expectEqual(@as(usize, 2), shipped.tables.len);
    try testing.expectEqual(@as(usize, 1), shipped.prefixes.len);
}

test "a prefix moved by keys.prefixes survives the product replacing its table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const moves = (try keys.parsePrefixes(x, &.{.{ .name = "venom", .prefix = "a" }})).ok;
    const first = (try K.parseTable(x, .{ .name = "venom", .prefix = "v", .bind = &.{.{ .key = "s", .local = "zoom" }} }, .product)).ok;
    var effective = try K.applyPrefixes(x, &.{ root, first }, moves);
    var r = try K.resolve(x, effective, null);
    try testing.expect(r.lookup(&.{ chord("a"), chord("s") }) == .exact);
    try testing.expect(r.lookup(&.{ chord("v"), chord("s") }) == .none);
    // `keys.list` reports the effective prefix.
    try testing.expectEqualStrings("a", (try K.tableJson(x, &effective[1])).object.get("prefix").?.string);
    // The built-in table has no sub-prefix, so a move would not take it.
    try testing.expect(effective[0].prefix == null);
    // The originals are untouched.
    try testing.expect(first.prefix.?.eql(chord("v")));

    // The product registers again: the whole table is replaced, the move stays.
    const second = (try K.parseTable(x, .{ .name = "venom", .prefix = "v", .bind = &.{.{ .key = "n", .label = "new", .local = "zoom" }} }, .product)).ok;
    effective = try K.applyPrefixes(x, &.{ root, second }, moves);
    r = try K.resolve(x, effective, null);
    try testing.expect(r.lookup(&.{ chord("a"), chord("n") }) == .exact);
    try testing.expect(r.lookup(&.{ chord("a"), chord("s") }) == .none);
    try testing.expect(r.lookup(&.{ chord("v"), chord("n") }) == .none);
    try testing.expectEqualStrings("a", (try K.tableJson(x, &effective[1])).object.get("prefix").?.string);
    try testing.expectEqualStrings("venom", r.prefixTable(&.{chord("a")}).?.name);
    try testing.expectEqualStrings("venom", rowLabel(try r.next(x, &.{}), "a"));
    // The JSON a client reads back still has the moved prefix.
    const back = (try K.tableFromJson(x, try K.tableJson(x, &effective[1]))).?;
    try testing.expect(back.prefix.?.eql(chord("a")));
}

test "layer precedence applies to a moved prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const moves = (try keys.parsePrefixes(x, &.{.{ .name = "venom", .prefix = "m" }})).ok;
    const venom = (try K.parseTable(x, .{ .name = "venom", .prefix = "v", .bind = &.{.{ .key = "s", .local = "zoom" }} }, .product)).ok;
    // A user table on the moved prefix wins, and the shadow is reported.
    const mine = (try K.parseTable(x, .{ .name = "mine", .prefix = "m", .bind = &.{.{ .key = "x", .local = "zoom" }} }, .user)).ok;
    var r = try K.resolve(x, try K.applyPrefixes(x, &.{ venom, mine }, moves), null);
    try testing.expect(r.lookup(&.{ chord("m"), chord("x") }) == .exact);
    try testing.expect(r.lookup(&.{ chord("m"), chord("s") }) == .none);
    try testing.expectEqual(@as(usize, 1), r.shadowed.len);
    try testing.expectEqualStrings("m s", r.shadowed[0].key);
    try testing.expectEqualStrings("mine", r.shadowed[0].by);
    // Another product on that prefix is a same-layer conflict.
    const other = (try K.parseTable(x, .{ .name = "other", .prefix = "m", .bind = &.{.{ .key = "y", .local = "zoom" }} }, .product)).ok;
    r = try K.resolve(x, try K.applyPrefixes(x, &.{ venom, other }, moves), null);
    try testing.expectEqual(@as(usize, 1), r.conflicts.len);
    try testing.expectEqualStrings("m", r.conflicts[0].key);
    // A move onto a built-in's key shadows the built-in, and says so.
    const onto = (try keys.parsePrefixes(x, &.{.{ .name = "venom", .prefix = "d" }})).ok;
    r = try K.resolve(x, try K.applyPrefixes(x, &.{ root, venom }, onto), null);
    try testing.expect(r.lookup(&.{ chord("d"), chord("s") }) == .exact);
    try testing.expectEqual(@as(usize, 1), r.shadowed.len);
    try testing.expectEqualStrings("venomx", r.shadowed[0].table);
}
