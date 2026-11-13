//! Theme roles for widgets.
//! Widgets never take raw colours; they ask the theme for a role. The
//! colours come from the Venom theme (`theme.zig`).
const std = @import("std");
const types = @import("types");
const Style = types.Style;

pub const Role = enum {
    /// Primary text (`bone`).
    normal,
    /// Secondary text (`bone-dim`).
    secondary,
    /// Labels, timestamps, group headers (`muted`).
    muted,
    /// Disabled text and placeholders (`faint`).
    faint,
    /// The product's signal: focus, active state, prompt.
    accent,
    ok,
    warn,
    err,
    info,
    /// Inactive borders (`rule`).
    border,
    /// Focused borders (the signal).
    border_focus,
    title,
    title_focus,
    /// Selected rows (`grave`); usually only a background.
    selection,
};

/// Build one with `theme.Chrome.widgets()` (src/theme.zig), which maps
/// these roles onto the brand theme, edition and colour mode.
pub const Theme = struct {
    normal: Style,
    secondary: Style,
    muted: Style,
    faint: Style,
    accent: Style,
    ok: Style,
    warn: Style,
    err: Style,
    info: Style,
    border: Style,
    border_focus: Style,
    title: Style,
    title_focus: Style,
    selection: Style,

    /// The default theme: `trve`, venom edition, ANSI 16 colours, so the
    /// terminal (or venomx's `.theme` ZON) decides the actual colours.
    pub const default: Theme = (@import("../theme.zig").Chrome{}).widgets();

    pub fn style(self: *const Theme, role: Role) Style {
        return switch (role) {
            inline else => |r| @field(self, @tagName(r)),
        };
    }
};

/// `top` over `base`: colours that are not `.default` and set flags win.
pub fn overlay(base: Style, top: Style) Style {
    var out = base;
    if (top.fg != .default) out.fg = top.fg;
    if (top.bg != .default) out.bg = top.bg;
    if (top.ul != .default) out.ul = top.ul;
    if (top.underline != .off) out.underline = top.underline;
    inline for (.{ "bold", "dim", "italic", "blink", "reverse", "invisible", "strikethrough" }) |flag| {
        if (@field(top, flag)) @field(out, flag) = true;
    }
    return out;
}

test "roles resolve and overlay keeps the base colour" {
    const theme: Theme = .default;
    try std.testing.expectEqual(types.Color{ .index = 1 }, theme.style(.accent).fg);
    const sel = overlay(theme.style(.ok), theme.style(.selection));
    try std.testing.expectEqual(types.Color{ .index = 2 }, sel.fg);
    try std.testing.expectEqual(types.Color{ .index = 0 }, sel.bg);
}
