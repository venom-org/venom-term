//! Widgets v0 for product TUIs: layout, boxes, a grouped list, a
//! wrapped scroll view, text input and focus routing. Every widget draws
//! into a `Surface` and takes `Input.Key`s (and `Input.Mouse` events), so it runs headless in tests;
//! no backend type crosses this API.
pub const theme = @import("widgets/theme.zig");
pub const Theme = theme.Theme;
pub const Role = theme.Role;
pub const layout = @import("widgets/layout.zig");
pub const box = @import("widgets/box.zig");
pub const Border = box.Border;
pub const text = @import("widgets/text.zig");
pub const Span = text.Span;
pub const keys = @import("widgets/keys.zig");
pub const FocusRing = keys.FocusRing;
pub const list = @import("widgets/list.zig");
pub const GroupedList = list.GroupedList;
pub const scroll = @import("widgets/scroll.zig");
pub const ScrollView = scroll.ScrollView;
pub const Block = scroll.Block;
pub const input = @import("widgets/input.zig");
pub const TextInput = input.TextInput;
pub const leader_popup = @import("widgets/leader_popup.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = theme;
    _ = layout;
    _ = box;
    _ = text;
    _ = keys;
    _ = list;
    _ = scroll;
    _ = input;
    _ = leader_popup;
}
