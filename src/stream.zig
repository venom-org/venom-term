//! Record walker for the pinned libghostty-vt snapshot stream.
//!
//! This is the only place in the ecosystem that reads ghostty snapshot bytes.
//! It walks the fixed record headers and a few plain header fields; it never
//! decodes cells. Everything here is private to venom-term: products see only
//! chunk boundaries and row counts.
const std = @import("std");

/// Snapshot envelope version this build understands (`GHOSTSNP` + u16).
pub const version: u16 = 1;
pub const envelope_len = 10;
pub const header_len = 10;

pub const Tag = enum(u16) {
    terminal = 1,
    screen = 2,
    page = 3,
    history = 4,
    ready = 5,
    finish = 6,
    continuation = 7,
    kitty_image_storage = 8,
    kitty_image_payload = 9,
    kitty_image_page_placements = 10,
    _,
};

pub const Header = struct {
    tag: Tag,
    len: u32,
    /// Offset of the record header in the walked buffer.
    start: usize,
    pub fn payloadStart(self: Header) usize {
        return self.start + header_len;
    }
    pub fn end(self: Header) usize {
        return self.start + header_len + self.len;
    }
};

pub const Error = error{InvalidSnapshot};

/// The header at `at`, or null when fewer than `header_len` bytes remain.
pub fn headerAt(bytes: []const u8, at: usize) ?Header {
    if (bytes.len < at or bytes.len - at < header_len) return null;
    return .{
        .tag = @fromBackingInt(std.mem.readInt(u16, bytes[at..][0..2], .little)),
        .len = std.mem.readInt(u32, bytes[at + 2 ..][0..4], .little),
        .start = at,
    };
}

/// The complete record at `at`, or null when it has not fully arrived.
pub fn recordAt(bytes: []const u8, at: usize) ?Header {
    const h = headerAt(bytes, at) orelse return null;
    if (bytes.len - h.payloadStart() < h.len) return null;
    return h;
}

fn readU16(bytes: []const u8, h: Header, offset: usize) Error!u16 {
    if (h.len < offset + 2) return error.InvalidSnapshot;
    return std.mem.readInt(u16, bytes[h.payloadStart() + offset ..][0..2], .little);
}
fn readU32(bytes: []const u8, h: Header, offset: usize) Error!u32 {
    if (h.len < offset + 4) return error.InvalidSnapshot;
    return std.mem.readInt(u32, bytes[h.payloadStart() + offset ..][0..4], .little);
}

/// Tab stops and palette overrides from a TERMINAL record's variable part:
/// fixed header, tab stops, original palette, override mask, overrides.
pub const TerminalTables = struct {
    cols: u16,
    /// One bit per column, least significant bit first.
    tabstops: []const u8,
    /// One bit per palette index, least significant bit first.
    mask: *const [32]u8,
    /// RGB of each set mask bit, by increasing index.
    overrides: []const u8,

    pub fn overridden(self: TerminalTables, index: u8) bool {
        return self.mask[index / 8] >> @intCast(index % 8) & 1 != 0;
    }
    /// True when the stops are the ones a fresh terminal of this width has:
    /// every 8 columns, except the first and last column.
    pub fn defaultTabstops(self: TerminalTables) bool {
        for (0..self.cols) |col| {
            const set = self.tabstops[col / 8] >> @intCast(col % 8) & 1 != 0;
            if (set != (col > 0 and col % 8 == 0 and col + 1 < self.cols)) return false;
        }
        return true;
    }
};

pub fn terminalTables(bytes: []const u8, h: Header) Error!TerminalTables {
    const fixed_len = 103;
    const cols = try readU16(bytes, h, 0);
    const tab_len = (@as(usize, cols) + 7) / 8;
    const mask_at = fixed_len + tab_len + 256 * 3;
    if (h.len < mask_at + 32) return error.InvalidSnapshot;
    const payload = bytes[h.payloadStart()..h.end()];
    const mask = payload[mask_at..][0..32];
    var count: usize = 0;
    for (mask) |byte| count += @popCount(byte);
    if (payload.len - mask_at - 32 < count * 3) return error.InvalidSnapshot;
    return .{
        .cols = cols,
        .tabstops = payload[fixed_len..][0..tab_len],
        .mask = mask,
        .overrides = payload[mask_at + 32 ..][0 .. count * 3],
    };
}

/// Row count from a PAGE record's plain header (LE u16 at payload byte 2).
pub fn pageRows(bytes: []const u8, h: Header) Error!u16 {
    std.debug.assert(h.tag == .page);
    return readU16(bytes, h, 2);
}

pub fn checkEnvelope(bytes: []const u8) Error!void {
    if (bytes.len < envelope_len) return error.InvalidSnapshot;
    if (!std.mem.eql(u8, bytes[0..8], "GHOSTSNP")) return error.InvalidSnapshot;
    if (std.mem.readInt(u16, bytes[8..10], .little) != version) return error.InvalidSnapshot;
}

/// End offset of the READY record, or null if it has not arrived yet.
/// Fails if a complete prefix is malformed.
pub fn readyEnd(bytes: []const u8) Error!?usize {
    if (bytes.len < envelope_len) return null;
    try checkEnvelope(bytes);
    var at: usize = envelope_len;
    while (recordAt(bytes, at)) |h| : (at = h.end()) {
        switch (h.tag) {
            .ready => return h.end(),
            .finish, .history => return error.InvalidSnapshot,
            else => {},
        }
    }
    return null;
}

/// Facts about one complete encoded snapshot that the stream API needs.
pub const Layout = struct {
    /// Offset just past READY: the `SNAPSHOT` prefix is `bytes[0..prefix_end]`.
    prefix_end: usize,
    /// Screen key (0 primary, 1 alternate) of the active screen.
    active_key: u16,
    /// Rows of the active screen carried before READY (active area plus any
    /// resident history overlap in the first page).
    prefix_rows: u64,
    /// Rows of the active screen's history pages after READY.
    history_rows: u64,
    /// TERMINAL and active SCREEN records, for fields the `vt` replay needs.
    terminal: Header,
    active_screen: Header,
};

pub fn layout(bytes: []const u8) Error!Layout {
    try checkEnvelope(bytes);
    var at: usize = envelope_len;
    var active_key: ?u16 = null;
    var terminal: ?Header = null;
    var screen_key: ?u16 = null;
    var active_screen: ?Header = null;
    var pages_left: u32 = 0;
    var prefix_rows: u64 = 0;
    var history_rows: u64 = 0;
    var prefix_end: ?usize = null;
    while (true) {
        const h = recordAt(bytes, at) orelse return error.InvalidSnapshot;
        at = h.end();
        switch (h.tag) {
            .terminal => {
                active_key = try readU16(bytes, h, 21);
                terminal = h;
            },
            .screen, .history => {
                if (pages_left != 0) return error.InvalidSnapshot;
                if ((h.tag == .screen) != (prefix_end == null)) return error.InvalidSnapshot;
                screen_key = try readU16(bytes, h, 0);
                pages_left = if (h.tag == .screen) try readU16(bytes, h, 2) else try readU32(bytes, h, 2);
                if (h.tag == .screen and screen_key == active_key) active_screen = h;
            },
            .page => {
                if (pages_left == 0) return error.InvalidSnapshot;
                pages_left -= 1;
                if (screen_key != null and screen_key == active_key) {
                    const n = try pageRows(bytes, h);
                    if (prefix_end == null) prefix_rows += n else history_rows += n;
                }
            },
            .ready => {
                if (prefix_end != null or pages_left != 0) return error.InvalidSnapshot;
                prefix_end = at;
            },
            .finish => break,
            else => {},
        }
    }
    return .{
        .prefix_end = prefix_end orelse return error.InvalidSnapshot,
        .active_key = active_key orelse return error.InvalidSnapshot,
        .prefix_rows = prefix_rows,
        .history_rows = history_rows,
        .terminal = terminal orelse return error.InvalidSnapshot,
        .active_screen = active_screen orelse return error.InvalidSnapshot,
    };
}

/// Splits the history part of a complete snapshot into record-aligned chunks.
pub const Chunker = struct {
    bytes: []const u8,
    at: usize,
    active_key: u16,
    screen_key: ?u16 = null,
    end_row: u64,
    done: bool = false,

    pub const Chunk = struct { bytes: []const u8, end_row: u64, rows: u32, last: bool };

    /// The next chunk of at most `max_bytes` bytes, or of one record when a
    /// single record is larger. A PAGE stays together with its placements.
    pub fn next(self: *Chunker, max_bytes: usize) Error!?Chunk {
        if (self.done) return null;
        const start = self.at;
        var rows: u64 = 0;
        var last = false;
        while (true) {
            const h = recordAt(self.bytes, self.at) orelse return error.InvalidSnapshot;
            const taken = self.at > start;
            if (taken and h.tag != .kitty_image_page_placements and h.end() - start > max_bytes) break;
            switch (h.tag) {
                .history => self.screen_key = try readU16(self.bytes, h, 0),
                .page => if (self.screen_key == self.active_key) {
                    rows += try pageRows(self.bytes, h);
                },
                else => {},
            }
            self.at = h.end();
            if (h.tag == .finish) {
                last = true;
                break;
            }
        }
        self.done = last;
        const end_row = self.end_row;
        if (rows > end_row or rows > std.math.maxInt(u32)) return error.InvalidSnapshot;
        self.end_row -= rows;
        return .{ .bytes = self.bytes[start..self.at], .end_row = end_row, .rows = @intCast(rows), .last = last };
    }
};

/// Length of the next decoder step at `bytes[0..]` that can run without
/// starving the ghostty decoder, or null if more bytes are needed.
///
/// ghostty's `decoder_next` applies one PAGE (plus its placements) or one
/// image payload, or validates FINISH. After a PAGE it reads the following
/// record header to look for placements, so that header must already be
/// present; if it is a placements record, the whole record must be.
/// The returned length is where the decoder's next step starts.
pub fn nextStep(bytes: []const u8) ?usize {
    var at: usize = 0;
    while (recordAt(bytes, at)) |h| {
        switch (h.tag) {
            .page => {
                const following = headerAt(bytes, h.end()) orelse return null;
                if (following.tag != .kitty_image_page_placements) return h.end();
                const placements = recordAt(bytes, h.end()) orelse return null;
                return placements.end();
            },
            .kitty_image_payload, .finish => return h.end(),
            else => at = h.end(),
        }
    }
    return null;
}

test "headers need complete bytes" {
    var buf: [header_len + 2]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], @backingInt(Tag.page), .little);
    std.mem.writeInt(u32, buf[2..6], 3, .little);
    try std.testing.expectEqual(@as(?Header, null), headerAt(buf[0..9], 0));
    try std.testing.expect(headerAt(&buf, 0) != null);
    try std.testing.expectEqual(@as(?Header, null), recordAt(&buf, 0));
    try std.testing.expectEqual(@as(?usize, null), try readyEnd("GHOST"));
    try std.testing.expectError(error.InvalidSnapshot, readyEnd("NOTGHOST\x01\x00"));
}
