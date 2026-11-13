//! The Venom theme: the brand colour tokens
//! (`src/brand/tokens.json`) as typed data, plus helpers that
//! turn them into `Style`s for product chrome. Products draw by role and
//! never hard-code a colour or import a backend colour type.
//!
//! - `Theme` holds every colour role of one brand theme as a `Swatch`: the
//!   exact RGB value from tokens.json and the ANSI colour it falls back to.
//!   The `logo-*` tokens are not roles: they belong to the logo files.
//! - `trve` (dark, the default) and `bone` (light) are the built-ins.
//! - `Edition` picks the product's signal (blood, ember, lichen).
//! - `Chrome` resolves a theme for one edition and one colour `Mode`. It
//!   returns chrome styles and the widgets' role theme (`widgets.Theme`).
//!
//! Without truecolor, each role falls back to the ANSI colour that means the
//! same thing in the brand palette (`ansi-1` red is blood, `ansi-8` is
//! dim output, and so on), not the RGB-nearest entry: by plain distance
//! `muted` would land on cyan and bone's paper on magenta. The ground and
//! the primary text fall back to the terminal's own default colours.
const std = @import("std");
const types = @import("types");
const widgets_theme = @import("widgets/theme.zig");
const Color = types.Color;
const Style = types.Style;

pub const Rgb = [3]u8;

/// One brand colour: its truecolor value and what it becomes without
/// truecolor (`.default`, the terminal's own fg or bg, or an `.index`).
pub const Swatch = struct {
    rgb: Rgb,
    ansi: Color,
};

/// What the terminal can show.
pub const Mode = enum {
    /// The 16 ANSI colours only; roles use `Swatch.ansi`.
    ansi16,
    /// 24-bit colour; roles use `Swatch.rgb`.
    truecolor,

    /// `COLORTERM=truecolor` or `24bit` means truecolor; anything else, or
    /// no `COLORTERM`, means ANSI 16.
    pub fn detect(env: *const std.process.Environ.Map) Mode {
        const value = env.get("COLORTERM") orelse return .ansi16;
        if (std.mem.eql(u8, value, "truecolor") or std.mem.eql(u8, value, "24bit")) return .truecolor;
        return .ansi16;
    }
};

/// One brand theme. Field names are the token names with `_` for `-`; the
/// status roles drop their `status-` prefix.
pub const Theme = struct {
    /// Token theme id: `trve` or `bone`.
    name: []const u8,
    void: Swatch,
    crypt: Swatch,
    grave: Swatch,
    ash: Swatch,
    rule: Swatch,
    rule_strong: Swatch,
    bone: Swatch,
    bone_dim: Swatch,
    muted: Swatch,
    faint: Swatch,
    blood: Swatch,
    on_blood: Swatch,
    ember: Swatch,
    on_ember: Swatch,
    lichen: Swatch,
    on_lichen: Swatch,
    verdigris: Swatch,
    gold: Swatch,
    frost: Swatch,
    /// `status-ok` (= lichen), paired with ●.
    ok: Swatch,
    /// `status-warn` (= gold), paired with ▲.
    warn: Swatch,
    /// `status-danger` (= blood), paired with ✕.
    danger: Swatch,
    /// `status-info` (= frost), paired with ◆.
    info: Swatch,
    /// Keyboard focus ring (= bone).
    focus: Swatch,
    /// `ansi-0` … `ansi-15`: the palette venomx hands to panes. Entry `i`
    /// falls back to ANSI index `i`.
    ansi: [16]Rgb,
};

/// Trve: the dark default theme, pure-black ground.
pub const trve: Theme = withAliases("trve", .{
    .void = sw("#000000", .default),
    .crypt = sw("#0c0908", .default),
    .grave = sw("#211816", idx(0)),
    .ash = sw("#2a2a2a", idx(0)),
    .rule = sw("#3a2f2c", idx(8)),
    .rule_strong = sw("#8a6565", idx(8)),
    .bone = sw("#f1f1f1", .default),
    .bone_dim = sw("#c1c1c1", idx(7)),
    .muted = sw("#8a8a8a", idx(8)),
    .faint = sw("#505050", idx(8)),
    .blood = sw("#fc302e", idx(1)),
    .on_blood = sw("#000000", .default),
    .ember = sw("#e78a43", idx(11)),
    .on_ember = sw("#000000", .default),
    .lichen = sw("#99bbaa", idx(2)),
    .on_lichen = sw("#000000", .default),
    .verdigris = sw("#5f8787", idx(6)),
    .gold = sw("#eecc6c", idx(3)),
    .frost = sw("#7799bb", idx(4)),
}, .{
    "#211816", "#fc302e", "#99bbaa", "#eecc6c", "#7799bb", "#a8a1de", "#5f8787", "#c1c1c1",
    "#505050", "#ff6b5e", "#ddeecc", "#fbcb97", "#a6c1dc", "#c7c1ee", "#8fb3b3", "#f8f7f2",
});

/// Bone: the light theme, tuned separately (warm paper, dried-blood ink).
/// Its ANSI fallbacks assume a light terminal with a conventional palette.
pub const bone: Theme = withAliases("bone", .{
    .void = sw("#f3f2f2", .default),
    .crypt = sw("#ebe7e6", .default),
    .grave = sw("#e5d6d7", idx(7)),
    .ash = sw("#d6cbcb", idx(7)),
    .rule = sw("#c9b8b9", idx(8)),
    .rule_strong = sw("#7a5c5d", idx(8)),
    .bone = sw("#211212", .default),
    .bone_dim = sw("#4a3434", .default),
    .muted = sw("#6c5151", idx(8)),
    .faint = sw("#a08c8c", idx(7)),
    .blood = sw("#ae0200", idx(1)),
    .on_blood = sw("#ffffff", .default),
    .ember = sw("#8a3f0e", idx(3)),
    .on_ember = sw("#ffffff", .default),
    .lichen = sw("#375a4c", idx(2)),
    .on_lichen = sw("#ffffff", .default),
    .verdigris = sw("#325c4f", idx(6)),
    .gold = sw("#6e5612", idx(3)),
    .frost = sw("#2f5d8f", idx(4)),
}, .{
    "#211212", "#ae0200", "#3f6656", "#6e5612", "#3a6ea5", "#5d4f8f", "#325c4f", "#4a3434",
    "#6c5151", "#c4302b", "#4b6b3f", "#9a4a12", "#2f5b8a", "#756482", "#2a7070", "#211212",
});

/// The built-in themes, by token theme id.
pub const builtins = [_]*const Theme{ &trve, &bone };

/// Look up a built-in theme by its id (`trve`, `bone`).
pub fn byName(name: []const u8) ?*const Theme {
    for (builtins) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// The product whose signal colours focus, active state and the session
/// block. One edition per screen.
pub const Edition = enum {
    /// The orchestrator: blood.
    venom,
    /// The multiplexer: ember.
    venomx,
    /// The bundle: lichen.
    venom_os,

    pub fn signal(self: Edition, t: *const Theme) Swatch {
        return switch (self) {
            .venom => t.blood,
            .venomx => t.ember,
            .venom_os => t.lichen,
        };
    }

    /// Text and icons on a fill of the signal.
    pub fn onSignal(self: Edition, t: *const Theme) Swatch {
        return switch (self) {
            .venom => t.on_blood,
            .venomx => t.on_ember,
            .venom_os => t.on_lichen,
        };
    }
};

/// A status always pairs a colour with a glyph, so it survives colour
/// blindness and monochrome terminals.
pub const Status = enum {
    ok,
    warn,
    danger,
    info,
    idle,

    pub fn glyph(self: Status) []const u8 {
        return switch (self) {
            .ok => "●",
            .warn => "▲",
            .danger => "✕",
            .info => "◆",
            .idle => "○",
        };
    }

    pub fn swatch(self: Status, t: *const Theme) Swatch {
        return switch (self) {
            .ok => t.ok,
            .warn => t.warn,
            .danger => t.danger,
            .info => t.info,
            .idle => t.muted,
        };
    }
};

/// A status glyph and the style to draw it in.
pub const Mark = struct { glyph: []const u8, style: Style };

/// A theme resolved for one edition and colour mode. Cheap to copy.
pub const Chrome = struct {
    theme: *const Theme = &trve,
    edition: Edition = .venom,
    mode: Mode = .ansi16,

    pub fn color(self: Chrome, s: Swatch) Color {
        return switch (self.mode) {
            .truecolor => .{ .rgb = s.rgb },
            .ansi16 => s.ansi,
        };
    }

    /// ANSI palette entry `i` (0–15).
    pub fn ansi(self: Chrome, i: u4) Color {
        return switch (self.mode) {
            .truecolor => .{ .rgb = self.theme.ansi[i] },
            .ansi16 => .{ .index = i },
        };
    }

    pub fn signal(self: Chrome) Color {
        return self.color(self.edition.signal(self.theme));
    }

    /// The ground: `void`. The terminal's own background without truecolor.
    pub fn background(self: Chrome) Color {
        return self.color(self.theme.void);
    }

    /// The primary text: `bone`. The terminal's own foreground without truecolor.
    pub fn foreground(self: Chrome) Color {
        return self.color(self.theme.bone);
    }

    /// Text in `s` on the ground.
    pub fn text(self: Chrome, s: Swatch) Style {
        return .{ .fg = self.color(s) };
    }

    /// A fill of `ground` with `on` text. Without truecolor a coloured fill
    /// is drawn as reverse video, so the text takes the terminal's own
    /// background (black in a dark terminal, paper in a light one), which
    /// is what the `on-` tokens are.
    pub fn fill(self: Chrome, ground: Swatch, on: Swatch) Style {
        if (self.mode == .ansi16 and ground.ansi != .default)
            return .{ .fg = ground.ansi, .reverse = true };
        return .{ .fg = self.color(on), .bg = self.color(ground) };
    }

    /// The focused pane border: the edition signal.
    pub fn focusedBorder(self: Chrome) Style {
        return .{ .fg = self.signal() };
    }

    /// Inactive pane borders and hairlines: `rule`.
    pub fn inactiveBorder(self: Chrome) Style {
        return self.text(self.theme.rule);
    }

    /// The status bar: `bone-dim` on `grave`.
    pub fn statusBar(self: Chrome) Style {
        return .{ .fg = self.color(self.theme.bone_dim), .bg = self.color(self.theme.grave) };
    }

    /// The status bar's session block: `on-<signal>` on the signal, bold
    /// (the `label` type style).
    pub fn sessionBlock(self: Chrome) Style {
        var s = self.fill(self.edition.signal(self.theme), self.edition.onSignal(self.theme));
        s.bold = true;
        return s;
    }

    /// Labels, timestamps, group headers: `muted`.
    pub fn mutedText(self: Chrome) Style {
        return self.text(self.theme.muted);
    }

    /// Disabled text: `faint`, dimmed as well when only ANSI colours exist.
    pub fn faintText(self: Chrome) Style {
        var s = self.text(self.theme.faint);
        s.dim = self.mode == .ansi16;
        return s;
    }

    pub fn statusMark(self: Chrome, status: Status) Mark {
        return .{ .glyph = status.glyph(), .style = self.text(status.swatch(self.theme)) };
    }

    /// The widgets' role theme in this chrome.
    pub fn widgets(self: Chrome) widgets_theme.Theme {
        const t = self.theme;
        var accent = self.text(self.edition.signal(t));
        accent.bold = true;
        var title_focus = self.text(t.bone);
        title_focus.bold = true;
        return .{
            .normal = self.text(t.bone),
            .secondary = self.text(t.bone_dim),
            .muted = self.mutedText(),
            .faint = self.faintText(),
            .accent = accent,
            .ok = self.text(t.ok),
            .warn = self.text(t.warn),
            .err = self.text(t.danger),
            .info = self.text(t.info),
            .border = self.inactiveBorder(),
            .border_focus = self.focusedBorder(),
            .title = self.text(t.bone_dim),
            .title_focus = title_focus,
            .selection = .{ .bg = self.color(t.grave) },
        };
    }
};

fn idx(comptime i: u8) Color {
    return .{ .index = i };
}

fn hex(comptime s: []const u8) Rgb {
    if (s.len != 7 or s[0] != '#') @compileError("colour must be #rrggbb: " ++ s);
    var out: Rgb = undefined;
    for (&out, 0..) |*byte, i| byte.* = nibble(s[1 + 2 * i]) << 4 | nibble(s[2 + 2 * i]);
    return out;
}

fn nibble(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => @compileError("colour must be lowercase hex"),
    };
}

fn sw(comptime s: []const u8, comptime ansi_fallback: Color) Swatch {
    return .{ .rgb = hex(s), .ansi = ansi_fallback };
}

/// The theme's own (non-alias) colour tokens.
const Base = struct {
    void: Swatch,
    crypt: Swatch,
    grave: Swatch,
    ash: Swatch,
    rule: Swatch,
    rule_strong: Swatch,
    bone: Swatch,
    bone_dim: Swatch,
    muted: Swatch,
    faint: Swatch,
    blood: Swatch,
    on_blood: Swatch,
    ember: Swatch,
    on_ember: Swatch,
    lichen: Swatch,
    on_lichen: Swatch,
    verdigris: Swatch,
    gold: Swatch,
    frost: Swatch,
};

/// Fills the alias roles the way tokens.json defines them.
fn withAliases(comptime name: []const u8, comptime base: Base, comptime palette: [16][]const u8) Theme {
    var t: Theme = undefined;
    t.name = name;
    for (@typeInfo(Base).@"struct".field_names) |n| @field(t, n) = @field(base, n);
    t.ok = base.lichen;
    t.warn = base.gold;
    t.danger = base.blood;
    t.info = base.frost;
    t.focus = base.bone;
    for (palette, 0..) |s, i| t.ansi[i] = hex(s);
    return t;
}

// ---------------------------------------------------------------- tests

/// tokens.json colours that are deliberately not `Theme` roles. The brand
/// book keeps them to the logo files (the bright signals stay in the
/// UI), and its terminal mark uses `ansi-7` and the edition's colour instead.
/// Listed by name, not by `logo-` prefix, so a new token still needs a
/// decision.
const logo_only_tokens = [_][]const u8{ "logo-ink", "logo-venom", "logo-venomx", "logo-venom-os" };

fn isLogoOnly(name: []const u8) bool {
    for (logo_only_tokens) |logo| if (std.mem.eql(u8, name, logo)) return true;
    return false;
}

/// The built-in RGB value for a tokens.json colour token name, or null when
/// the theme has no such role.
fn builtinValue(t: *const Theme, name: []const u8) ?Rgb {
    if (std.mem.startsWith(u8, name, "ansi-")) {
        const i = std.fmt.parseInt(u4, name["ansi-".len..], 10) catch return null;
        return t.ansi[i];
    }
    if (std.mem.startsWith(u8, name, "signal-")) {
        const product = name["signal-".len..];
        inline for (@typeInfo(Edition).@"enum".field_names) |n| {
            var buf: [n.len]u8 = undefined;
            _ = std.mem.replace(u8, n, "_", "-", &buf);
            if (std.mem.eql(u8, product, &buf)) return @field(Edition, n).signal(t).rgb;
        }
        return null;
    }
    const role = if (std.mem.startsWith(u8, name, "status-")) name["status-".len..] else name;
    const info = @typeInfo(Theme).@"struct";
    inline for (info.field_names, info.field_types) |n, T| {
        if (T != Swatch) continue;
        var buf: [n.len]u8 = undefined;
        _ = std.mem.replace(u8, n, "_", "-", &buf);
        if (std.mem.eql(u8, role, &buf)) return @field(t, n).rgb;
    }
    return null;
}

fn parseHex(s: []const u8) !Rgb {
    if (s.len != 7 or s[0] != '#') return error.BadColour;
    return .{
        try std.fmt.parseInt(u8, s[1..3], 16),
        try std.fmt.parseInt(u8, s[3..5], 16),
        try std.fmt.parseInt(u8, s[5..7], 16),
    };
}

/// A token's value in one theme, following `{alias}` references.
fn tokenValue(tokens: []const std.json.Value, name: []const u8, theme_id: []const u8, depth: u8) !Rgb {
    if (depth > 4) return error.AliasLoop;
    for (tokens) |tok| {
        if (!std.mem.eql(u8, tok.object.get("name").?.string, name)) continue;
        const v = tok.object.get("value").?.object.get(theme_id).?.string;
        if (v.len > 2 and v[0] == '{' and v[v.len - 1] == '}') return tokenValue(tokens, v[1 .. v.len - 1], theme_id, depth + 1);
        return parseHex(v);
    }
    return error.UnknownToken;
}

test "built-in themes match brand/tokens.json" {
    const a = std.testing.allocator;
    const bytes = @embedFile("brand/tokens.json");
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const color = parsed.value.object.get("color").?.object;
    const tokens = color.get("tokens").?.array.items;
    const themes = color.get("themes").?.array.items;
    try std.testing.expectEqual(builtins.len, themes.len);
    var checked: usize = 0;
    var logo_only: usize = 0;
    for (themes) |th| {
        const id = th.object.get("id").?.string;
        const t = byName(id) orelse {
            std.debug.print("tokens.json theme '{s}' has no built-in\n", .{id});
            return error.MissingTheme;
        };
        for (tokens) |tok| {
            const name = tok.object.get("name").?.string;
            const want = try tokenValue(tokens, name, id, 0);
            if (isLogoOnly(name)) {
                logo_only += 1;
                continue;
            }
            const got = builtinValue(t, name) orelse {
                std.debug.print("tokens.json colour '{s}' has no role in theme.Theme\n", .{name});
                return error.MissingRole;
            };
            if (!std.mem.eql(u8, &want, &got)) {
                std.debug.print("{s}.{s}: built-in #{x:0>2}{x:0>2}{x:0>2}, tokens.json #{x:0>2}{x:0>2}{x:0>2}\n", .{ id, name, got[0], got[1], got[2], want[0], want[1], want[2] });
                return error.TokenMismatch;
            }
            checked += 1;
        }
    }
    try std.testing.expect(checked >= builtins.len * (16 + 19 + 4 + 1 + 3));
    // The exemption list must not outlive the tokens it names.
    try std.testing.expectEqual(builtins.len * logo_only_tokens.len, logo_only);
}

test "status glyphs pair a colour with a glyph" {
    const glyphs = [_][]const u8{ "●", "▲", "✕", "◆", "○" };
    const fallback = [_]u8{ 2, 3, 1, 4, 8 };
    for (std.enums.values(Status), glyphs, fallback) |status, g, i| {
        const plain = (Chrome{}).statusMark(status);
        try std.testing.expectEqualStrings(g, plain.glyph);
        try std.testing.expectEqual(Color{ .index = i }, plain.style.fg);
        const rgb = (Chrome{ .mode = .truecolor }).statusMark(status);
        try std.testing.expectEqualStrings(g, rgb.glyph);
        try std.testing.expectEqual(Color{ .rgb = status.swatch(&trve).rgb }, rgb.style.fg);
    }
    try std.testing.expectEqual(Color{ .rgb = .{ 0x99, 0xbb, 0xaa } }, (Chrome{ .mode = .truecolor }).statusMark(.ok).style.fg);
    try std.testing.expectEqual(Color{ .rgb = .{ 0x37, 0x5a, 0x4c } }, (Chrome{ .theme = &bone, .mode = .truecolor }).statusMark(.ok).style.fg);
}

test "without truecolor every role falls back to an ANSI colour" {
    for (builtins) |t| {
        for (std.enums.values(Edition)) |e| {
            const c: Chrome = .{ .theme = t, .edition = e, .mode = .ansi16 };
            const info = @typeInfo(Theme).@"struct";
            inline for (info.field_names, info.field_types) |n, T| {
                if (T == Swatch) try std.testing.expect(c.color(@field(t, n)) != .rgb);
            }
            for (0..16) |i| try std.testing.expectEqual(Color{ .index = @intCast(i) }, c.ansi(@intCast(i)));
            inline for (.{ "focusedBorder", "inactiveBorder", "statusBar", "sessionBlock", "mutedText", "faintText" }) |helper| {
                const s = @field(Chrome, helper)(c);
                try std.testing.expect(s.fg != .rgb and s.bg != .rgb);
            }
            const w = c.widgets();
            inline for (@typeInfo(widgets_theme.Theme).@"struct".field_names) |n| {
                try std.testing.expect(@field(w, n).fg != .rgb and @field(w, n).bg != .rgb);
            }
        }
    }
    const venomx: Chrome = .{ .edition = .venomx };
    try std.testing.expectEqual(Style{ .fg = .{ .index = 11 } }, venomx.focusedBorder());
    try std.testing.expectEqual(Style{ .fg = .{ .index = 8 } }, venomx.inactiveBorder());
    try std.testing.expectEqual(Style{ .fg = .{ .index = 7 }, .bg = .{ .index = 0 } }, venomx.statusBar());
    // A signal fill is reverse video, so the text is the terminal's ground.
    try std.testing.expectEqual(Style{ .fg = .{ .index = 11 }, .reverse = true, .bold = true }, venomx.sessionBlock());
    try std.testing.expectEqual(Style{ .fg = .{ .index = 8 }, .dim = true }, venomx.faintText());
    // The ground and the primary text keep the terminal's own colours.
    try std.testing.expectEqual(Color.default, venomx.color(trve.void));
    try std.testing.expectEqual(Color.default, venomx.color(trve.bone));
}

test "truecolor uses the exact brand RGB" {
    const c: Chrome = .{ .theme = &trve, .edition = .venomx, .mode = .truecolor };
    try std.testing.expectEqual(Style{ .fg = .{ .rgb = .{ 0xe7, 0x8a, 0x43 } } }, c.focusedBorder());
    try std.testing.expectEqual(Style{ .fg = .{ .rgb = .{ 0x3a, 0x2f, 0x2c } } }, c.inactiveBorder());
    try std.testing.expectEqual(Style{ .fg = .{ .rgb = .{ 0xc1, 0xc1, 0xc1 } }, .bg = .{ .rgb = .{ 0x21, 0x18, 0x16 } } }, c.statusBar());
    try std.testing.expectEqual(Style{ .fg = .{ .rgb = .{ 0, 0, 0 } }, .bg = .{ .rgb = .{ 0xe7, 0x8a, 0x43 } }, .bold = true }, c.sessionBlock());
    try std.testing.expectEqual(Style{ .fg = .{ .rgb = .{ 0x8a, 0x8a, 0x8a } } }, c.mutedText());
    try std.testing.expectEqual(Style{ .fg = .{ .rgb = .{ 0x50, 0x50, 0x50 } } }, c.faintText());
    try std.testing.expectEqual(Color{ .rgb = .{ 0xf8, 0xf7, 0xf2 } }, c.ansi(15));
    const light: Chrome = .{ .theme = &bone, .edition = .venom_os, .mode = .truecolor };
    try std.testing.expectEqual(Style{ .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } }, .bg = .{ .rgb = .{ 0x37, 0x5a, 0x4c } }, .bold = true }, light.sessionBlock());
}

test "background and foreground are void and bone, or the terminal's own without truecolor" {
    const dark: Chrome = .{ .mode = .truecolor };
    try std.testing.expectEqual(Color{ .rgb = .{ 0, 0, 0 } }, dark.background());
    try std.testing.expectEqual(Color{ .rgb = .{ 0xf1, 0xf1, 0xf1 } }, dark.foreground());
    const light: Chrome = .{ .theme = &bone, .mode = .truecolor };
    try std.testing.expectEqual(Color{ .rgb = .{ 0xf3, 0xf2, 0xf2 } }, light.background());
    try std.testing.expectEqual(Color{ .rgb = .{ 0x21, 0x12, 0x12 } }, light.foreground());
    try std.testing.expectEqual(Color.default, (Chrome{}).background());
    try std.testing.expectEqual(Color.default, (Chrome{}).foreground());
}

test "editions map to their signal and on- colour" {
    try std.testing.expectEqual(trve.blood, Edition.venom.signal(&trve));
    try std.testing.expectEqual(trve.ember, Edition.venomx.signal(&trve));
    try std.testing.expectEqual(bone.lichen, Edition.venom_os.signal(&bone));
    try std.testing.expectEqual(bone.on_ember, Edition.venomx.onSignal(&bone));
    try std.testing.expectEqual(&trve, byName("trve").?);
    try std.testing.expectEqual(&bone, byName("bone").?);
    try std.testing.expectEqual(@as(?*const Theme, null), byName("navy"));
}

test "colour mode comes from COLORTERM" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(Mode.ansi16, Mode.detect(&env));
    try env.put("COLORTERM", "truecolor");
    try std.testing.expectEqual(Mode.truecolor, Mode.detect(&env));
    try env.put("COLORTERM", "24bit");
    try std.testing.expectEqual(Mode.truecolor, Mode.detect(&env));
    try env.put("COLORTERM", "yes");
    try std.testing.expectEqual(Mode.ansi16, Mode.detect(&env));
}

test "the widgets' default theme is trve, venom edition, ANSI 16" {
    // The ANSI-index roles widgets v0 shipped with.
    const v0: widgets_theme.Theme = .{
        .normal = .{},
        .secondary = .{ .fg = .{ .index = 7 } },
        .muted = .{ .fg = .{ .index = 8 } },
        .faint = .{ .fg = .{ .index = 8 }, .dim = true },
        .accent = .{ .fg = .{ .index = 1 }, .bold = true },
        .ok = .{ .fg = .{ .index = 2 } },
        .warn = .{ .fg = .{ .index = 3 } },
        .err = .{ .fg = .{ .index = 1 } },
        .info = .{ .fg = .{ .index = 4 } },
        .border = .{ .fg = .{ .index = 8 } },
        .border_focus = .{ .fg = .{ .index = 1 } },
        .title = .{ .fg = .{ .index = 7 } },
        .title_focus = .{ .bold = true },
        .selection = .{ .bg = .{ .index = 0 } },
    };
    try std.testing.expectEqualDeep(v0, widgets_theme.Theme.default);
    try std.testing.expectEqualDeep(v0, (Chrome{}).widgets());
}
