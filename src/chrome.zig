//! Presentation-client logic shared by every venomx client
//! (`venomx attach`, venom-desk): pane tags and `when` matching, key tables
//! with the leader/lock state machine, the status-line layout, and the
//! environment of `exec` binding children. Pure and headless: no daemon
//! calls, no TTY, no renderer. Importable as the module `chrome` (also in
//! `-Dheadless=true` builds) and as `venom-term`'s `chrome`.
pub const tags = @import("chrome/tags.zig");
pub const keys = @import("chrome/keys.zig");
pub const leader_popup = @import("chrome/leader_popup.zig");
pub const status = @import("chrome/status.zig");
pub const exec_env = @import("chrome/exec_env.zig");
pub const Tag = tags.Tag;
pub const Tags = tags.Tags;

test {
    @import("std").testing.refAllDecls(@This());
    _ = tags;
    _ = keys;
    _ = leader_popup;
    _ = status;
    _ = exec_env;
}
