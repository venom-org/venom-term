//! Headless terminal API. This module has no renderer dependency.
const std = @import("std");
const c = @import("ghostty_c");
const types = @import("types");
const stream = @import("stream.zig");
const build_options = @import("build_options");
pub const Cell = types.Cell;
pub const Style = types.Style;
pub const Color = types.Color;
pub const Error = error{ OutOfMemory, InvalidValue, Unavailable, StaleRows, InvalidSnapshot, Backend };
const pin: []const u8 = build_options.ghostty_commit[0..12];
comptime {
    // The header must be the libghostty-vt release pinned in build.zig.zon.
    if (!std.mem.eql(u8, c.GHOSTTY_VT_VERSION, build_options.ghostty_version))
        @compileError("ghostty/vt.h is libghostty-vt " ++ c.GHOSTTY_VT_VERSION ++ ", expected " ++ build_options.ghostty_version);
}
fn check(r: c.GhosttyResult) Error!void {
    switch (r) {
        c.GHOSTTY_SUCCESS => {},
        c.GHOSTTY_OUT_OF_MEMORY => return error.OutOfMemory,
        c.GHOSTTY_INVALID_VALUE => return error.InvalidValue,
        c.GHOSTTY_NO_VALUE => return error.Unavailable,
        else => return error.Backend,
    }
}

pub const Vt = struct {
    // The implementation is private, stable in memory, and owns all callbacks.
    impl: *anyopaque,
    pub const Input = types.Input;
    pub const InputModes = @import("input_encode.zig").Modes;
    pub const MouseGeometry = @import("input_encode.zig").MouseGeometry;

    /// Current emulator state, including modes restored from snapshots.
    pub fn inputModes(self: Vt) Error!InputModes {
        return @import("input_encode.zig").modes(self.state().terminal, &self.state().ca);
    }
    /// Owns the returned bytes, including an empty slice for suppressed events.
    pub fn encodeKey(self: Vt, allocator: std.mem.Allocator, key: Input.Key) Error![]u8 {
        return @import("input_encode.zig").keyBytes(self.state().terminal, &self.state().ca, allocator, key);
    }
    /// Mouse coordinates are zero-based pane cells. Pixel mode requires geometry.
    /// No client-local motion deduplication or button state is retained by Vt.
    pub fn encodeMouse(self: Vt, allocator: std.mem.Allocator, mouse: Input.Mouse, geometry: MouseGeometry) Error![]u8 {
        return @import("input_encode.zig").mouseBytes(self.state().terminal, &self.state().ca, allocator, mouse, geometry);
    }

    pub const Options = struct {
        cols: u16 = 80,
        rows: u16 = 24,
        scrollback_lines: usize = 10_000,
        continuation_bytes: usize = 1024 * 1024,
        callbacks: Callbacks = .{},
        replies: Replies = .{},
        /// One cell's size in pixels, for XTWINOPS size reports and the
        /// terminal's pixel size. Zero when unknown.
        cell: CellSize = .{},
    };
    pub const CellSize = struct { width: u32 = 0, height: u32 = 0 };
    /// What the terminal says about itself when a program asks. Local to
    /// this Vt like `QueryColors`: never serialized, so set it again after
    /// `restore` or `Decoder.ready`.
    pub const Replies = struct {
        /// XTVERSION (`CSI > q`) answer, e.g. "venomx 0.1.0". At most 64
        /// bytes. Empty answers libghostty's default.
        xtversion: []const u8 = "",
        /// XTGETTCAP `TN` answer: the terminfo name programs run under, the
        /// `TERM` the embedder sets. At most 128 bytes. Empty: no answer.
        terminfo_name: []const u8 = "",
        /// `CSI ? 996 n` answer. Null ignores the query.
        color_scheme: ?ColorScheme = null,
    };
    pub const ColorScheme = enum { light, dark };
    /// Grapheme clustering (DEC mode 2027) is on in a new Vt and after RIS,
    /// as in the ghostty app: without it, conjuncts in Brahmic scripts
    /// advance the cursor by each codepoint's width instead of the cluster's.
    pub const grapheme_clustering_default = true;
    pub const ProgramStatus = struct {
        state: enum { idle, working, done, blocked, failed, clear },
        kind: enum { none, permission, question, auth },
        progress: ?u8,
        id: []const u8,
        app: []const u8,
        title: []const u8,
        message: []const u8,
    };
    pub const SemanticPrompt = struct {
        kind: enum { prompt_start, input_start, output_start, command_end },
        prompt: enum { primary, right, continuation, secondary },
        exit_code: ?i32,
        command: []const u8,
        message: []const u8,
    };
    /// Host theme used only while answering OSC 10/11/12 queries. Null
    /// components use the terminal's configured defaults. Application OSC
    /// overrides take precedence. These values are local, never serialized.
    pub const QueryColors = struct {
        fg: ?[3]u8 = null,
        bg: ?[3]u8 = null,
        cursor: ?[3]u8 = null,
    };
    /// Current OSC 0/2 title, borrowed until the next mutation of this Vt.
    /// Reading metadata never encodes a snapshot or walks terminal cells.
    pub fn title(self: Vt) Error![]const u8 {
        var value: c.GhosttyString = undefined;
        try check(c.ghostty_terminal_get(self.state().terminal, c.GHOSTTY_TERMINAL_DATA_TITLE, &value));
        return if (value.len == 0) "" else value.ptr[0..value.len];
    }

    /// Last working directory reported by OSC 7 (a raw file://host/path URI,
    /// percent-encoding kept), OSC 9;9 or OSC 1337 CurrentDir (usually a bare
    /// path), stored as the program sent it and not decoded. Callers must
    /// handle both forms. Borrowed until the next mutation of this Vt (feed,
    /// resize, reset), so copy it to keep it. Null when unset or cleared by an
    /// empty OSC 7.
    pub fn pwd(self: Vt) Error!?[]const u8 {
        var value: c.GhosttyString = undefined;
        try check(c.ghostty_terminal_get(self.state().terminal, c.GHOSTTY_TERMINAL_DATA_PWD, &value));
        return if (value.len == 0) null else value.ptr[0..value.len];
    }

    pub fn setQueryColors(self: Vt, colors: QueryColors) void {
        self.state().query_colors = colors;
    }
    pub fn setReplies(self: Vt, replies: Replies) Error!void {
        try self.state().setReplies(replies);
    }
    /// Sets one cell's pixel size without changing the grid. Programs see it
    /// in XTWINOPS size reports and mode 2048 reports.
    pub fn setCellSize(self: Vt, cell: CellSize) Error!void {
        const p = self.state();
        if (std.meta.eql(p.cell, cell)) return;
        p.cell = cell;
        const sz = self.size();
        try check(c.ghostty_terminal_resize(p.terminal, sz.cols, sz.rows, cell.width, cell.height));
    }
    pub fn cellSize(self: Vt) CellSize {
        return self.state().cell;
    }

    pub const Callbacks = struct {
        context: ?*anyopaque = null,
        write_pty: ?*const fn (?*anyopaque, []const u8) void = null,
        program_status: ?*const fn (?*anyopaque, ProgramStatus) void = null,
        semantic_prompt: ?*const fn (?*anyopaque, SemanticPrompt) void = null,
        /// A BEL (0x07) in program output. A BEL that terminates an OSC or
        /// DCS string is not a bell, and hydration never rings it.
        bell: ?*const fn (?*anyopaque) void = null,
    };
    pub const Rows = struct { epoch: u64, oldest: u64, end: u64, active: u64 };
    pub const Size = struct { cols: u16, rows: u16 };
    pub const Cursor = struct { x: u16, y: u16, visible: bool };
    /// Owns bytes allocated with the allocator passed to snapshot().
    pub const Snapshot = struct {
        bytes: []u8,
        continuation_bytes: usize,
        epoch: u64,
        oldest: u64,
        pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
        }
    };

    /// First 12 hex digits of the ghostty commit of the pinned libghostty-vt release.
    pub const ghostty_pin: []const u8 = pin;
    /// Pane-stream format name of `streamSnapshot()` bytes, e.g. `ghostty/1@0fa3d577a561`.
    pub const ghostty_format: []const u8 = std.fmt.comptimePrint("ghostty/{d}@{s}", .{ stream.version, pin });
    /// Pane-stream name of the format produced by `vtSnapshot()`.
    pub const vt_format: []const u8 = "vt";

    /// Pane-stream `READY` row metadata for a streamed snapshot.
    pub const Ready = struct {
        /// Row-address epoch of `oldest`, `top` and `active`.
        epoch: u64,
        /// Absolute row of the oldest retained row of the active screen.
        oldest: u64,
        /// Absolute row of the first row carried by the prefix. History rows
        /// `[oldest, top)` follow as history chunks.
        top: u64,
        /// Absolute row of the active area's first row.
        active: u64,
        cols: u16,
        rows: u16,
    };

    /// One record-aligned piece of history, newest first. `bytes` borrows the
    /// SnapshotStream. It covers absolute rows `[end_row - rows, end_row)`.
    pub const HistoryChunk = struct {
        bytes: []const u8,
        end_row: u64,
        rows: u32,
        /// The snapshot ends with this chunk.
        last: bool,
    };

    /// A snapshot split for pane streaming. Owns its bytes; immutable
    /// once taken, so the Vt may keep changing while it is sent.
    pub const SnapshotStream = struct {
        /// Opaque `ghostty_format` bytes up to and including READY: the
        /// payload of the `SNAPSHOT` frames (split them however you like).
        prefix: []const u8,
        ready: Ready,
        // Private.
        bytes: []u8,
        chunker: stream.Chunker,

        /// The next history chunk of at most `max_bytes` bytes (a single
        /// record larger than that is returned alone), or null when done.
        /// Every stream ends with a chunk whose `last` is true; it may have
        /// zero rows.
        pub fn nextHistory(self: *SnapshotStream, max_bytes: usize) Error!?HistoryChunk {
            const chunk = (try self.chunker.next(max_bytes)) orelse return null;
            return .{ .bytes = chunk.bytes, .end_row = chunk.end_row, .rows = chunk.rows, .last = chunk.last };
        }
        pub fn deinit(self: *SnapshotStream, allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
            self.* = undefined;
        }
    };

    /// Pane-stream `vt` snapshot: VT bytes for a freshly reset terminal of the
    /// pane's size. Owns `bytes`.
    pub const VtReplay = struct {
        bytes: []u8,
        /// Bytes of an unfinished escape sequence or UTF-8 character at the
        /// end of the fed input. The replay is as of the ground state before
        /// them: label it with offset `current - unfinished`.
        unfinished: usize,
        /// History rows placed before the screen dump, oldest first.
        history_rows: u64,
        pub fn deinit(self: VtReplay, allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
        }
    };
    pub const VtReplayOptions = struct {
        /// Maximum primary-screen history rows to put before the screen.
        history: u64 = 0,
    };

    pub const DecoderOptions = struct {
        continuation_bytes: usize = 1024 * 1024,
        /// Local callbacks for the Vt. Emulating clients leave `write_pty`
        /// unset: only the daemon's Vt answers terminal queries.
        callbacks: Callbacks = .{},
    };
    /// Incremental receiver of a streamed `ghostty_format` snapshot.
    /// Feed the `SNAPSHOT` prefix bytes, then call `ready()` with the
    /// `READY` metadata to get a live Vt. History chunks then go to
    /// `Vt.feedHistory()`.
    pub const Decoder = struct {
        impl: *anyopaque,
        pub fn init(allocator: std.mem.Allocator, options: DecoderOptions) Error!Decoder {
            if (options.continuation_bytes == 0) return error.InvalidValue;
            const p = try allocator.create(Impl);
            p.* = .{ .allocator = allocator, .callbacks = options.callbacks };
            p.ca = .{ .ctx = p, .vtable = &allocator_vtable };
            errdefer allocator.destroy(p);
            const h = try allocator.create(History);
            h.* = .{ .vt = p, .continuation_bytes = options.continuation_bytes };
            return .{ .impl = h };
        }
        fn history(self: Decoder) *History {
            return @ptrCast(@alignCast(self.impl));
        }
        /// Frees a decoder that has not produced a Vt.
        pub fn deinit(self: *Decoder) void {
            const h = self.history();
            const allocator = h.vt.allocator;
            allocator.destroy(h.vt);
            h.deinit(allocator);
            self.* = undefined;
        }
        /// Appends `SNAPSHOT` chunk bytes; chunk boundaries do not matter.
        pub fn feedPrefix(self: Decoder, bytes: []const u8) Error!void {
            const h = self.history();
            try h.buf.appendSlice(h.vt.allocator, bytes);
        }
        /// Decodes the prefix and returns the live Vt, positioned at `meta`'s
        /// row addresses. Consumes the decoder on success: do not deinit it.
        /// On failure the decoder stays owned by the caller.
        pub fn ready(self: *Decoder, meta: Ready) Error!Vt {
            const h = self.history();
            const p = h.vt;
            const end = (try stream.readyEnd(h.buf.items)) orelse return error.InvalidSnapshot;
            if (end != h.buf.items.len or meta.epoch == 0 or meta.top > meta.active or meta.oldest > meta.top) return error.InvalidSnapshot;
            const reader: c.GhosttyReader = .{ .read = History.read, .userdata = h };
            try check(c.ghostty_snapshot_decoder_new(&p.ca, &h.decoder, reader));
            const enabled = true;
            try check(c.ghostty_snapshot_decoder_set(h.decoder, c.GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &h.continuation_bytes));
            try check(c.ghostty_snapshot_decoder_set(h.decoder, c.GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &enabled));
            try check(c.ghostty_snapshot_decoder_set(h.decoder, c.GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, &enabled));
            check(c.ghostty_snapshot_decoder_ready(h.decoder, &p.terminal)) catch |err| {
                c.ghostty_snapshot_decoder_free(h.decoder);
                h.decoder = null;
                h.read_pos = 0;
                return err;
            };
            errdefer {
                c.ghostty_snapshot_decoder_free(h.decoder);
                h.decoder = null;
                h.read_pos = 0;
                c.ghostty_terminal_free(p.terminal);
                p.terminal = null;
            }
            const vt: Vt = .{ .impl = p };
            const total = p.get(usize, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS);
            const sz = vt.size();
            if (h.read_pos != end or sz.cols != meta.cols or sz.rows != meta.rows or meta.active + sz.rows - meta.top != total) return error.InvalidSnapshot;
            p.epoch = meta.epoch;
            p.oldest = meta.top;
            p.since_ground = if (p.get(bool, c.GHOSTTY_TERMINAL_DATA_VT_GROUND)) 0 else continuationLen(p.terminal);
            try p.restoreModeDefaults();
            try p.installCallbacks();
            try p.reanchor();
            h.epoch = meta.epoch;
            h.step_pos = end;
            h.compact(0);
            p.history = h;
            self.* = undefined;
            return vt;
        }
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) Error!Vt {
        if (options.cols == 0 or options.rows == 0 or options.continuation_bytes == 0) return error.InvalidValue;
        const p = try allocator.create(Impl);
        p.* = .{ .allocator = allocator, .callbacks = options.callbacks };
        p.ca = .{ .ctx = p, .vtable = &allocator_vtable };
        errdefer allocator.destroy(p);
        try check(c.ghostty_terminal_new(&p.ca, &p.terminal, options.cols, options.rows));
        errdefer c.ghostty_terminal_free(p.terminal);
        try check(c.ghostty_terminal_set(p.terminal, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &options.scrollback_lines));
        const unlimited: usize = std.math.maxInt(usize);
        try check(c.ghostty_terminal_set(p.terminal, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &unlimited));
        try check(c.ghostty_terminal_set(p.terminal, c.GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &options.continuation_bytes));
        // DECSCUSR cannot ask for a hollow block, so as the default shape it
        // marks a cursor the program never shaped (see `cursorShape`).
        const unshaped: c.GhosttyCursorStyle = c.GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW;
        try check(c.ghostty_terminal_set(p.terminal, c.GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &unshaped));
        const graphemes: c.GhosttyTerminalModeConfig = .{ .mode = c.GHOSTTY_MODE_GRAPHEME_CLUSTER, .value = grapheme_clustering_default };
        try check(c.ghostty_terminal_set(p.terminal, c.GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemes));
        try p.setReplies(options.replies);
        if (options.cell.width != 0 or options.cell.height != 0) {
            p.cell = options.cell;
            try check(c.ghostty_terminal_resize(p.terminal, options.cols, options.rows, options.cell.width, options.cell.height));
        }
        try p.installCallbacks();
        try p.reanchor();
        return .{ .impl = p };
    }
    pub fn deinit(self: *Vt) void {
        const p = self.state();
        p.endHistory();
        c.ghostty_render_state_row_iterator_free(p.render_rows);
        c.ghostty_render_state_free(p.render);
        p.allocator.free(p.row_gen);
        p.allocator.free(p.row_ids);
        c.ghostty_tracked_grid_ref_free(p.anchor);
        c.ghostty_terminal_free(p.terminal);
        const allocator = p.allocator;
        allocator.destroy(p);
        self.* = undefined;
    }
    fn state(self: Vt) *Impl {
        return @ptrCast(@alignCast(self.impl));
    }
    pub fn size(self: Vt) Size {
        return .{ .cols = self.state().get(u16, c.GHOSTTY_TERMINAL_DATA_COLS), .rows = self.state().get(u16, c.GHOSTTY_TERMINAL_DATA_ROWS) };
    }
    pub const CursorShape = types.CursorShape;
    /// The program's cursor shape. Folds row damage like `changes`, which
    /// it shares the terminal's dirty state with.
    pub fn cursorShape(self: Vt) Error!CursorShape {
        const p = self.state();
        try p.syncChanges();
        var style: c.GhosttyCursorStyle = c.GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW;
        try check(c.ghostty_render_state_get(p.render, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style));
        var blink = false;
        try check(c.ghostty_render_state_get(p.render, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blink));
        return switch (style) {
            c.GHOSTTY_CURSOR_STYLE_BAR => .{ .kind = .bar, .blink = blink },
            c.GHOSTTY_CURSOR_STYLE_BLOCK => .{ .kind = .block, .blink = blink },
            c.GHOSTTY_CURSOR_STYLE_UNDERLINE => .{ .kind = .underline, .blink = blink },
            else => .{},
        };
    }
    /// Whether the program has synchronized output on (DEC mode 2026): it is
    /// partway through a frame, so a renderer should hold the pane's last
    /// drawn picture until the mode turns off.
    pub fn syncOutput(self: Vt) Error!bool {
        var mode: c.GhosttyTerminalModeConfig = .{ .mode = c.GHOSTTY_MODE_SYNCHRONIZED_OUTPUT, .value = false };
        try check(c.ghostty_terminal_get(self.state().terminal, c.GHOSTTY_TERMINAL_DATA_MODE, &mode));
        return mode.value;
    }
    pub fn cursor(self: Vt) Cursor {
        const p = self.state();
        return .{ .x = p.get(u16, c.GHOSTTY_TERMINAL_DATA_CURSOR_X), .y = p.get(u16, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y), .visible = p.get(bool, c.GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE) };
    }
    pub fn rows(self: Vt) Rows {
        const p = self.state();
        const total = p.get(usize, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS);
        return .{ .epoch = p.epoch, .oldest = p.oldest, .end = p.oldest + total, .active = p.oldest + total - self.size().rows };
    }
    /// Synchronous. Callback strings are borrowed only during the callback.
    /// No callback may reenter this Vt. All access to a Vt must be serialized.
    pub fn feed(self: Vt, bytes: []const u8) Error!void {
        const p = self.state();
        // Ghostty separates embedder defaults from program OSC overrides.
        // Install host defaults only during feed, then restore the render
        // defaults before any caller can read cells or encode a snapshot.
        const host_colors = !std.meta.eql(p.query_colors, Vt.QueryColors{});
        const original = if (host_colors) p.queryDefaults() else undefined;
        defer if (host_colors) p.restoreDefaults(original);
        if (host_colors) try p.applyQueryDefaults();
        // Printable ASCII and complete SGR sequences at ground cannot erase
        // history or switch screens. Bound each run to one row's width of
        // printable bytes (SGR moves no cursor): even a huge write cannot
        // scroll the tracked active-row anchor away before we observe it.
        // Controls, UTF-8 and other or unfinished escape sequences retain
        // bytewise observation.
        const cols = self.size().cols;
        var at: usize = 0;
        var line_start = false;
        var margin_mode: ?bool = null;
        while (at < bytes.len) {
            var end = at + 1;
            const byte = bytes[at];
            const text = p.since_ground == 0 and (isPrintable(byte) or sgrLen(bytes[at..]) != 0);
            var printed: usize = 0;
            if (text) {
                end = at;
                while (end < bytes.len) {
                    if (isPrintable(bytes[end])) {
                        if (printed == cols) break;
                        printed += 1;
                        end += 1;
                    } else {
                        const n = sgrLen(bytes[end..]);
                        if (n == 0) break;
                        end += n;
                    }
                }
            }
            var whole_line = false;
            if (text and end + 1 < bytes.len and bytes[end] == '\r' and bytes[end + 1] == '\n') {
                if (margin_mode == null) {
                    var mode: c.GhosttyTerminalModeConfig = .{ .mode = c.GHOSTTY_MODE_ENABLE_LEFT_AND_RIGHT_MARGIN, .value = false };
                    try check(c.ghostty_terminal_get(p.terminal, c.GHOSTTY_TERMINAL_DATA_MODE, &mode));
                    margin_mode = mode.value;
                }
                // A line that cannot wrap, followed by CRLF, advances at
                // most one row. CR clears a pending wrap at the last column.
                // Horizontal margins use the conservative path instead.
                if (!margin_mode.? and (line_start or
                    (@as(usize, p.get(u16, c.GHOSTTY_TERMINAL_DATA_CURSOR_X)) + printed <= cols and
                        !p.get(bool, c.GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP))))
                {
                    end += 2;
                    whole_line = true;
                }
            }
            // CRLF at ground advances at most one row, just like a bounded
            // printable run. Neither case can erase history or change screens.
            const line_break = p.since_ground == 0 and byte == '\r' and end < bytes.len and bytes[end] == '\n';
            if (line_break) end += 1;
            line_start = whole_line;
            const safe = text or line_break or (p.since_ground == 0 and (byte == '\r' or byte == '\n'));
            const chunk = bytes[at..end];
            at = end;
            const before = if (!safe) p.get(usize, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS) else undefined;
            const active_screen = if (!safe) p.get(c.GhosttyTerminalScreen, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN) else undefined;
            c.ghostty_terminal_vt_write(p.terminal, chunk.ptr, chunk.len);
            // Count raw bytes since the parser was last at ground, so a `vt`
            // replay can be labelled at a ground offset. Printable ASCII
            // from ground stays at ground without asking.
            if (safe) {} else if (p.get(bool, c.GHOSTTY_TERMINAL_DATA_VT_GROUND)) {
                p.since_ground = 0;
            } else p.since_ground += 1;
            var invalidated = false;
            if (!safe) {
                margin_mode = null;
                const after = p.get(usize, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS);
                invalidated = p.reset_seen or active_screen != p.get(c.GhosttyTerminalScreen, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN) or (after < before and byte == 'J');
            }
            var coord: c.GhosttyPointCoordinate = undefined;
            if (invalidated or c.ghostty_tracked_grid_ref_point(p.anchor, c.GHOSTTY_POINT_TAG_SCREEN, &coord) != c.GHOSTTY_SUCCESS or coord.y > p.anchor_abs - p.oldest) {
                p.newEpoch();
            } else {
                p.oldest = p.anchor_abs - coord.y;
            }
            try p.reanchor();
        }
    }
    fn isPrintable(byte: u8) bool {
        return byte >= 0x20 and byte < 0x7f;
    }
    /// Length of a complete SGR sequence (`ESC [` params `m`, params only
    /// digits, `;` and `:`) at the start of `bytes`, or 0. A private prefix,
    /// an intermediate or a split sequence is not SGR here.
    fn sgrLen(bytes: []const u8) usize {
        if (bytes.len < 3 or bytes[0] != 0x1b or bytes[1] != '[') return 0;
        var i: usize = 2;
        while (i < bytes.len) : (i += 1) switch (bytes[i]) {
            '0'...'9', ';', ':' => {},
            'm' => return i + 1,
            else => return 0,
        };
        return 0;
    }
    pub fn resize(self: Vt, cols: u16, height: u16) Error!void {
        if (cols == 0 or height == 0) return error.InvalidValue;
        const old = self.size();
        if (old.cols == cols and old.rows == height) return;
        try check(c.ghostty_terminal_resize(self.state().terminal, cols, height, self.state().cell.width, self.state().cell.height));
        self.state().newEpoch();
        try self.state().reanchor();
    }
    /// One bounded idle step. Returns true when more work remains.
    pub fn compress(self: Vt) Error!bool {
        var result: c.GhosttyTerminalCompressionResult = undefined;
        try check(c.ghostty_terminal_compress(self.state().terminal, c.GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL, &result));
        return result == c.GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING;
    }
    pub fn snapshot(self: Vt, allocator: std.mem.Allocator) Error!Snapshot {
        const p = self.state();
        return .{ .bytes = try p.encode(allocator), .epoch = p.epoch, .oldest = p.oldest, .continuation_bytes = p.get(usize, c.GHOSTTY_TERMINAL_DATA_CONTINUATION_MAX_BYTES) };
    }
    /// Creates an independent terminal. Callback configuration is local, never restored.
    pub fn restore(allocator: std.mem.Allocator, snap: Snapshot, callbacks: Callbacks) Error!Vt {
        const p = try allocator.create(Impl);
        p.* = .{ .allocator = allocator, .callbacks = callbacks, .epoch = snap.epoch, .oldest = snap.oldest };
        p.ca = .{ .ctx = p, .vtable = &allocator_vtable };
        errdefer allocator.destroy(p);
        var decoder: c.GhosttySnapshotDecoder = null;
        try check(c.ghostty_snapshot_decoder_new_buf(&p.ca, &decoder, snap.bytes.ptr, snap.bytes.len));
        defer c.ghostty_snapshot_decoder_free(decoder);
        if (snap.continuation_bytes == 0) return error.InvalidSnapshot;
        const enabled = true;
        try check(c.ghostty_snapshot_decoder_set(decoder, c.GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &snap.continuation_bytes));
        try check(c.ghostty_snapshot_decoder_set(decoder, c.GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &enabled));
        try check(c.ghostty_snapshot_decoder_set(decoder, c.GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, &enabled));
        try check(c.ghostty_snapshot_decoder_decode(decoder, &p.terminal));
        errdefer c.ghostty_terminal_free(p.terminal);
        const total = p.get(usize, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS);
        if (snap.epoch == 0 or snap.oldest > std.math.maxInt(u64) - total) return error.InvalidSnapshot;
        p.since_ground = if (p.get(bool, c.GHOSTTY_TERMINAL_DATA_VT_GROUND)) 0 else continuationLen(p.terminal);
        try p.restoreModeDefaults();
        try p.installCallbacks();
        try p.reanchor();
        return .{ .impl = p };
    }
    /// Takes a `ghostty_format` snapshot split for streaming:
    /// the prefix through READY, its row metadata, and history chunks with
    /// absolute row labels. Call it between feeds; the result is independent
    /// of later changes to this Vt.
    pub fn streamSnapshot(self: Vt, allocator: std.mem.Allocator) Error!SnapshotStream {
        const p = self.state();
        const bytes = try p.encode(allocator);
        errdefer allocator.free(bytes);
        const lay = try stream.layout(bytes);
        const r = self.rows();
        const sz = self.size();
        // The pages of the active screen must account for exactly the rows
        // the Vt addresses; anything else means the pinned format drifted.
        if (lay.prefix_rows > r.end - r.oldest or lay.prefix_rows < sz.rows or lay.prefix_rows + lay.history_rows != r.end - r.oldest) return error.Backend;
        const top = r.end - lay.prefix_rows;
        return .{
            .prefix = bytes[0..lay.prefix_end],
            .ready = .{ .epoch = r.epoch, .oldest = r.oldest, .top = top, .active = r.active, .cols = sz.cols, .rows = sz.rows },
            .bytes = bytes,
            .chunker = .{ .bytes = bytes, .at = lay.prefix_end, .active_key = lay.active_key, .end_row = top },
        };
    }

    /// Applies one history chunk of the snapshot this Vt was decoded from
    /// (`Decoder.ready`). Returns the rows of the active screen added to its
    /// top; `rows().oldest` moves down by that amount. A page whose record
    /// ends a chunk is applied once the next chunk (or FINISH) arrives,
    /// because ghostty must see the following record header first; after the
    /// `last` chunk every row is applied. Call between `feed()`/`resize()`.
    /// After an epoch change (resize, clear, reset, screen switch) the rest
    /// of the history no longer fits: returns `StaleRows` and stops.
    pub fn feedHistory(self: Vt, bytes: []const u8) Error!u64 {
        const p = self.state();
        const h = p.history orelse return error.InvalidValue;
        errdefer p.endHistory();
        if (h.epoch != p.epoch) return error.StaleRows;
        try h.buf.appendSlice(p.allocator, bytes);
        var applied: u64 = 0;
        while (stream.nextStep(h.buf.items[h.step_pos..])) |n| {
            const before = p.get(usize, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS);
            const result = c.ghostty_snapshot_decoder_next(h.decoder);
            if (result == c.GHOSTTY_NO_VALUE) {
                p.endHistory();
                return applied;
            }
            try check(result);
            h.step_pos += n;
            const added = p.get(usize, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS) - before;
            if (added > p.oldest) return error.InvalidSnapshot;
            p.oldest -= added;
            applied += added;
        }
        h.compact(@min(h.step_pos, h.read_pos));
        return applied;
    }
    /// True while a streamed snapshot's history is still being received.
    pub fn historyPending(self: Vt) bool {
        return self.state().history != null;
    }
    /// Stops receiving history (for example on `SCROLLBACK` with ABORTED,
    /// or a LAST chunk that ended early). Rows already applied stay.
    pub fn abandonHistory(self: Vt) void {
        self.state().endHistory();
    }

    /// Builds the pane-stream `vt` snapshot: VT bytes that reproduce this
    /// terminal on a freshly reset terminal of the same size.
    /// It restores both screens' text with styles, wide characters,
    /// graphemes and hyperlinks; cursor position, visibility, shape and
    /// pending wrap; the saved cursor (primary screen); modes, mouse and
    /// keyboard protocols, scrolling region, title and cwd; and the tab stops,
    /// palette entries and OSC 10/11/12 colours the program changed. A raw
    /// client forwards these bytes to the user's terminal, so state still at
    /// its default is left out: that terminal keeps its own. Kitty
    /// graphics are omitted. OSC 133 marks are replayed per row, not per
    /// cell: `rowPrompt` agrees with the source; a prompt row reads
    /// as prompt cells in full.
    pub fn vtSnapshot(self: Vt, allocator: std.mem.Allocator, options: VtReplayOptions) Error!VtReplay {
        const p = self.state();
        const snap = try p.encode(allocator);
        defer allocator.free(snap);
        const lay = try stream.layout(snap);
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;
        var history_rows: u64 = 0;
        if (lay.active_key == c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE) {
            // Dump the primary screen first from a scratch copy switched back
            // to it; entering the alternate screen below saves its cursor.
            var scratch: c.GhosttyTerminal = null;
            var decoder: c.GhosttySnapshotDecoder = null;
            try check(c.ghostty_snapshot_decoder_new_buf(&p.ca, &decoder, snap.ptr, snap.len));
            defer c.ghostty_snapshot_decoder_free(decoder);
            try check(c.ghostty_snapshot_decoder_decode(decoder, &scratch));
            defer c.ghostty_terminal_free(scratch);
            // CAN returns the parser to ground (any stray output lands on the
            // alternate screen, which is not dumped here).
            c.ghostty_terminal_vt_write(scratch, "\x18\x1b[?1049l", 9);
            if (getData(c.GhosttyTerminalScreen, scratch, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN) != c.GHOSTTY_TERMINAL_SCREEN_PRIMARY) return error.Backend;
            history_rows = try formatScreen(p, scratch, w, null, options.history, c.GHOSTTY_FORMATTER_EXTRA_CURSOR, false);
            w.writeAll("\x1b[0m\x1b]8;;\x1b\\") catch return error.OutOfMemory;
        } else if (savedCursor(snap, lay)) |saved| {
            w.print("\x1b[{d};{d}H\x1b7", .{ saved.y + 1, saved.x + 1 }) catch return error.OutOfMemory;
        }
        const tables = try stream.terminalTables(snap, lay.terminal);
        try writeTerminalState(p, snap, lay, tables, w);
        const main_history = if (lay.active_key == c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE) 0 else options.history;
        const extras = c.GHOSTTY_FORMATTER_EXTRAS_ALL & ~@as(c.GhosttyFormatterExtras, c.GHOSTTY_FORMATTER_EXTRA_PALETTE);
        var marked = false;
        history_rows += try formatScreen(p, p.terminal, w, &marked, main_history, extras, tables.defaultTabstops());
        if (lay.active_key != c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE) try writeCursorSemantic(p, snap, lay, marked, w);
        return .{ .bytes = out.toOwnedSlice() catch return error.OutOfMemory, .unfinished = p.since_ground, .history_rows = history_rows };
    }

    /// Literal plain terminal text: one string per physical
    /// row, without styles, controls, CR/LF or width-zero continuation
    /// cells. Strings are borrowed from whoever built the value.
    pub const PlainText = struct {
        cols: u16,
        rows: u16,
        /// Rows above the screen, oldest first.
        history: []const []const u8,
        /// Exactly `rows` rows, top first.
        screen: []const []const u8,
    };
    /// Budget of `exportPlain`. Rows and bytes count screen and history
    /// together; bytes count row text only. Zero disables export.
    pub const PlainLimits = struct { max_rows: usize, max_bytes: usize };
    /// Owns the rows of an exported `PlainText`.
    pub const PlainExport = struct {
        text: PlainText,
        bytes: []u8,
        lines: [][]const u8,
        pub fn deinit(self: PlainExport, allocator: std.mem.Allocator) void {
            allocator.free(self.lines);
            allocator.free(self.bytes);
        }
    };
    /// Hard reader bounds for durable session restore (text rows and bytes per pane).
    pub const plain_max_rows: usize = 100_000;
    pub const plain_max_bytes: usize = 16 * 1024 * 1024;
    pub const PlainOptions = struct {
        scrollback_lines: usize = 10_000,
        continuation_bytes: usize = 1024 * 1024,
        /// Installed only after hydration; nothing fires while hydrating.
        callbacks: Callbacks = .{},
        max_rows: usize = plain_max_rows,
        max_bytes: usize = plain_max_bytes,
    };

    /// Exports the primary screen (exactly `rows` rows) and its history as
    /// plain text, as `pane.capture` renders cells. While the alternate
    /// screen is active it is skipped: the primary screen underneath is
    /// exported, and the live Vt is not changed. History is clipped to
    /// the budget by dropping the oldest rows first. Returns null when the
    /// budget is zero or the screen alone does not fit (text omitted).
    pub fn exportPlain(self: Vt, allocator: std.mem.Allocator, limits: PlainLimits) Error!?PlainExport {
        const p = self.state();
        const sz = self.size();
        if (limits.max_rows < sz.rows or limits.max_bytes == 0) return null;
        // With the alternate screen active, read the primary screen from a
        // scratch copy switched back to it (as vtSnapshot does): restore
        // hydrates the primary screen, and only it has history.
        var terminal = p.terminal;
        var scratch: c.GhosttyTerminal = null;
        defer if (scratch != null) c.ghostty_terminal_free(scratch);
        if (p.get(c.GhosttyTerminalScreen, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN) == c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE) {
            const snap = try p.encode(allocator);
            defer allocator.free(snap);
            var decoder: c.GhosttySnapshotDecoder = null;
            try check(c.ghostty_snapshot_decoder_new_buf(&p.ca, &decoder, snap.ptr, snap.len));
            defer c.ghostty_snapshot_decoder_free(decoder);
            try check(c.ghostty_snapshot_decoder_decode(decoder, &scratch));
            // CAN returns the parser to ground; the bytes are the wrapper's own.
            c.ghostty_terminal_vt_write(scratch, "\x18\x1b[?1049l", 9);
            if (getData(c.GhosttyTerminalScreen, scratch, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN) != c.GHOSTTY_TERMINAL_SCREEN_PRIMARY) return error.Backend;
            terminal = scratch;
        }
        const total = getData(usize, terminal, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS);
        const above = total - sz.rows;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        // Row end offsets: screen rows top first, then history newest first.
        var ends: std.ArrayList(usize) = .empty;
        defer ends.deinit(allocator);
        try ends.ensureTotalCapacity(allocator, @min(limits.max_rows, total));
        var reader = try PlainReader.init(&p.ca, terminal, sz.cols);
        defer reader.deinit();
        for (0..sz.rows) |i| {
            const y = above + i;
            if (!reader.has(y)) try reader.load(y, @min(plain_chunk_rows, total - y));
            try reader.append(allocator, &buf, y);
            if (buf.items.len > limits.max_bytes) return null;
            ends.appendAssumeCapacity(buf.items.len);
        }
        var kept: usize = 0;
        while (kept < above and sz.rows + kept < limits.max_rows) : (kept += 1) {
            const mark = buf.items.len;
            const y = above - 1 - kept;
            if (!reader.has(y)) {
                const count = @min(plain_chunk_rows, y + 1, limits.max_rows - sz.rows - kept);
                try reader.load(y + 1 - count, count);
            }
            try reader.append(allocator, &buf, y);
            if (buf.items.len > limits.max_bytes) {
                buf.shrinkRetainingCapacity(mark);
                break;
            }
            ends.appendAssumeCapacity(buf.items.len);
        }
        const lines = try allocator.alloc([]const u8, sz.rows + kept);
        errdefer allocator.free(lines);
        const bytes = try buf.toOwnedSlice(allocator);
        const slice = struct {
            fn at(b: []const u8, e: []const usize, i: usize) []const u8 {
                return b[if (i == 0) 0 else e[i - 1]..e[i]];
            }
        }.at;
        for (0..kept) |k| lines[k] = slice(bytes, ends.items, sz.rows + kept - 1 - k);
        for (0..sz.rows) |i| lines[kept + i] = slice(bytes, ends.items, i);
        return .{ .bytes = bytes, .lines = lines, .text = .{ .cols = sz.cols, .rows = sz.rows, .history = lines[0..kept], .screen = lines[kept..] } };
    }

    /// Creates a fresh reset Vt at `text`'s size holding its rows as
    /// literal cells: history in scrollback, default styles, primary
    /// screen, cursor home, new row epoch. Every row is validated before
    /// anything is allocated: UTF-8 without C0, DEL or C1 characters, and
    /// within the row/byte/scrollback bounds. Only the decoded printable
    /// characters reach the emulator (plus line moves the wrapper adds), so
    /// saved text can never form an escape sequence, query or OSC. A row
    /// that does not read back identically (too wide, or a leading
    /// combining mark) is rejected, with one exception: a row that
    /// a pane laid out with mode 2027 switched midway is kept, cut at the
    /// last column, under the exact rule documented at `hydrateRow`
    /// (`fromPlainReport` says how many rows that happened to). Everything
    /// `exportPlain` returns hydrates. Errors leave nothing allocated.
    pub fn fromPlain(allocator: std.mem.Allocator, text: PlainText, options: PlainOptions) Error!Vt {
        return (try fromPlainReport(allocator, text, options)).vt;
    }
    /// What `fromPlainReport` made.
    pub const PlainHydrated = struct {
        vt: Vt,
        /// Rows (history and screen) that were kept cut at the last column
        /// because no single layout rebuilt them: the text is not exactly the
        /// pane's. Zero for text from a pane that never switched mode 2027
        /// midway row.
        cut_rows: usize,
    };
    /// `fromPlain`, also reporting how many rows were cut.
    pub fn fromPlainReport(allocator: std.mem.Allocator, text: PlainText, options: PlainOptions) Error!PlainHydrated {
        try validatePlain(text, options);
        var vt = try Vt.init(allocator, .{ .cols = text.cols, .rows = text.rows, .scrollback_lines = options.scrollback_lines, .continuation_bytes = options.continuation_bytes });
        errdefer vt.deinit();
        const p = vt.state();
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(allocator);
        var probes: HydrateProbes = .{ .allocator = allocator, .cols = text.cols };
        defer probes.deinit();
        var cut_rows: usize = 0;
        for (0..text.history.len + text.rows) |i| {
            const row = if (i < text.history.len) text.history[i] else text.screen[i - text.history.len];
            if (i > 0) c.ghostty_terminal_vt_write(p.terminal, "\r\n", 2);
            if (try hydrateRow(p, &probes, &scratch, row, text.cols, text.rows)) cut_rows += 1;
        }
        // Back to the defaults a reset Vt has.
        c.ghostty_terminal_vt_write(p.terminal, if (grapheme_clustering_default) "\x1b[?2027h" else "\x1b[?2027l", 8);
        c.ghostty_terminal_vt_write(p.terminal, "\x1b[?7h\x1b[H", 8);
        if (p.get(usize, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS) != text.history.len + text.rows) return error.InvalidValue;
        p.epoch = 1;
        p.oldest = 0;
        p.reset_seen = false;
        p.since_ground = 0;
        try p.reanchor();
        p.callbacks = options.callbacks;
        return .{ .vt = vt, .cut_rows = cut_rows };
    }

    /// Returns owned UTF-8 for [start,end), including newline after each physical row.
    pub fn exportRows(self: Vt, allocator: std.mem.Allocator, epoch: u64, start: u64, end: u64) Error![]u8 {
        const bounds = self.rows();
        if (epoch != bounds.epoch or start < bounds.oldest or end > bounds.end) return error.StaleRows;
        if (end < start) return error.InvalidValue;
        // Allocation-free per cell (the `exportPlain` path), so bulk range
        // reads stay cheap.
        const terminal = self.state().terminal;
        const cols = self.size().cols;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.ensureTotalCapacity(allocator, @intCast((end - start) * (@as(u64, cols) + 1)));
        for (start..end) |row| {
            try appendRow(terminal, allocator, &out, cols, @intCast(row - bounds.oldest));
            try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
    }
    pub const Screen = enum { primary, alternate };
    /// The screen currently active: `alternate` while a full-screen program
    /// holds it (`?1049h`, `?1047h` or `?47h`). Its rows have no history.
    pub fn screen(self: Vt) Screen {
        return if (self.state().get(c.GhosttyTerminalScreen, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN) == c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE) .alternate else .primary;
    }
    /// Returns one cell with owned text. Free cell.text with allocator. The
    /// text is as `plainCodepoint` renders it: never a control character.
    pub fn readCell(self: Vt, allocator: std.mem.Allocator, epoch: u64, row: u64, col: u16) Error!Cell {
        var buf: CellBuffer = undefined;
        if (try self.readCellBuf(&buf, epoch, row, col)) |cell| {
            return .{ .text = try allocator.dupe(u8, cell.text), .width = cell.width, .style = cell.style };
        }
        // A grapheme too long for the buffer: size it exactly.
        const ref = try self.gridRef(epoch, row, col);
        var count: usize = 0;
        const result = c.ghostty_grid_ref_graphemes(&ref, null, 0, &count);
        if (result != c.GHOSTTY_OUT_OF_SPACE) try check(result);
        const cps = try allocator.alloc(u32, count);
        defer allocator.free(cps);
        try check(c.ghostty_grid_ref_graphemes(&ref, cps.ptr, count, &count));
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        for (cps) |cp| {
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(plainCodepoint(cp), &utf8) catch unreachable;
            out.writer.writeAll(utf8[0..n]) catch return error.OutOfMemory;
        }
        const meta = try cellMeta(&ref);
        return .{ .text = out.toOwnedSlice() catch return error.OutOfMemory, .width = meta.width, .style = meta.style };
    }
    /// Text storage for readCellBuf.
    pub const CellBuffer = [64]u8;
    /// readCell without allocating: the text borrows `buf`. Null when the
    /// cell's grapheme does not fit `buf` (use readCell for that cell).
    pub fn readCellBuf(self: Vt, buf: *CellBuffer, epoch: u64, row: u64, col: u16) Error!?Cell {
        const ref = try self.gridRef(epoch, row, col);
        var cps: [16]u32 = undefined;
        var count: usize = 0;
        const result = c.ghostty_grid_ref_graphemes(&ref, &cps, cps.len, &count);
        if (result == c.GHOSTTY_OUT_OF_SPACE) return null;
        try check(result);
        const meta = try cellMeta(&ref);
        var len: usize = 0;
        for (cps[0..count]) |cp| {
            if (len + 4 > buf.len) return null;
            len += std.unicode.utf8Encode(plainCodepoint(cp), buf[len..][0..4]) catch unreachable;
        }
        if (count == 0 and meta.width != 0) {
            buf[0] = ' ';
            len = 1;
        }
        return .{ .text = buf[0..len], .width = meta.width, .style = meta.style };
    }
    /// OSC 133 state of a row (libghostty's per-row semantic prompt flag).
    pub const RowPrompt = enum {
        /// No prompt cells.
        none,
        /// A prompt start: the row OSC 133 A marked (a primary prompt line).
        start,
        /// A prompt continuation line (OSC 133 A with `k=c`/`k=s`).
        continuation,
    };
    /// The OSC 133 flag of absolute row `row`, scrollback included.
    /// `StaleRows` for another epoch or a row outside `rows()`.
    pub fn rowPrompt(self: Vt, epoch: u64, row: u64) Error!RowPrompt {
        const ref = try self.gridRef(epoch, row, 0);
        return refPrompt(&ref);
    }
    /// The nearest prompt start (`.start` row) strictly above `row`, or null.
    /// `row` may be any absolute row in `rows()`, or `rows().end` to search
    /// from the bottom.
    pub fn prevPromptRow(self: Vt, epoch: u64, row: u64) Error!?u64 {
        const b = self.rows();
        if (epoch != b.epoch or row < b.oldest or row > b.end) return error.StaleRows;
        var r = row;
        while (r > b.oldest) {
            r -= 1;
            if (try self.rowPrompt(epoch, r) == .start) return r;
        }
        return null;
    }
    /// The nearest prompt start strictly below `row`, or null. `row` may be
    /// any absolute row in `rows()`.
    pub fn nextPromptRow(self: Vt, epoch: u64, row: u64) Error!?u64 {
        const b = self.rows();
        if (epoch != b.epoch or row < b.oldest or row > b.end) return error.StaleRows;
        var r = row + 1;
        while (r < b.end) : (r += 1) {
            if (try self.rowPrompt(epoch, r) == .start) return r;
        }
        return null;
    }
    fn gridRef(self: Vt, epoch: u64, row: u64, col: u16) Error!c.GhosttyGridRef {
        const bounds = self.rows();
        if (epoch != bounds.epoch or row < bounds.oldest or row >= bounds.end) return error.StaleRows;
        if (col >= self.size().cols) return error.InvalidValue;
        var ref: c.GhosttyGridRef = std.mem.zeroes(c.GhosttyGridRef);
        // An ACTIVE point is found from the active area; a SCREEN point
        // walks retained history from its oldest page.
        const pt: c.GhosttyPoint = if (row >= bounds.active)
            .{ .tag = c.GHOSTTY_POINT_TAG_ACTIVE, .value = .{ .coordinate = .{ .x = col, .y = @intCast(row - bounds.active) } } }
        else
            point(col, @intCast(row - bounds.oldest));
        try check(c.ghostty_terminal_grid_ref(self.state().terminal, pt, &ref));
        return ref;
    }
    /// Active-area rows changed since a view last drew them.
    pub const Changes = struct {
        /// The generation of this answer. A row changed after a draw that
        /// recorded generation g when its entry is greater than g.
        generation: u64,
        /// One entry per active row: the generation it last changed in.
        /// Borrowed until the next call.
        rows: []const u64,
    };
    /// Folds libghostty-vt's row damage into per-row generations, so any
    /// number of views can ask. Rows that moved (scrolling) count as
    /// changed. The first call creates the render state and reports every
    /// row. It consumes the terminal's dirty state: nothing else may, and
    /// VtView.draw, drawChanged and cursorShape always call it. On error the next call
    /// reports every row changed.
    pub fn changes(self: Vt) Error!Changes {
        const p = self.state();
        try p.syncChanges();
        return .{ .generation = p.generation, .rows = p.row_gen };
    }
};
fn cellMeta(ref: *const c.GhosttyGridRef) Error!struct { width: u8, style: Style } {
    var raw: c.GhosttyCell = undefined;
    try check(c.ghostty_grid_ref_cell(ref, &raw));
    var wide: c.GhosttyCellWide = 0;
    try check(c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, &wide));
    var style: c.GhosttyStyle = undefined;
    try check(c.ghostty_grid_ref_style(ref, &style));
    const tail = wide == c.GHOSTTY_CELL_WIDE_SPACER_TAIL;
    return .{ .width = if (tail) 0 else if (wide == c.GHOSTTY_CELL_WIDE_WIDE) 2 else 1, .style = .{
        .fg = color(style.fg_color),
        .bg = try cellBg(raw) orelse color(style.bg_color),
        .ul = color(style.underline_color),
        .underline = @fromBackingInt(@intCast(@min(5, (style.flags >> 8) & 7))),
        .bold = style.flags & 1 != 0,
        .italic = style.flags & 2 != 0,
        .dim = style.flags & 4 != 0,
        .blink = style.flags & 8 != 0,
        .reverse = style.flags & 16 != 0,
        .invisible = style.flags & 32 != 0,
        .strikethrough = style.flags & 64 != 0,
    } };
}
/// A cell erased (EL, ECH, ED, ...) under a background-only SGR
/// holds no text and no style: libghostty-vt keeps the colour on the cell
/// itself, tagged by its content, and the style reads as default.
fn cellBg(raw: c.GhosttyCell) Error!?Color {
    var tag: c.GhosttyCellContentTag = c.GHOSTTY_CELL_CONTENT_CODEPOINT;
    try check(c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_CONTENT_TAG, &tag));
    switch (tag) {
        c.GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE => {
            var index: c.GhosttyColorPaletteIndex = 0;
            try check(c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_COLOR_PALETTE, &index));
            return .{ .index = index };
        },
        c.GHOSTTY_CELL_CONTENT_BG_COLOR_RGB => {
            var rgb: c.GhosttyColorRgb = undefined;
            try check(c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_COLOR_RGB, &rgb));
            return .{ .rgb = .{ rgb.r, rgb.g, rgb.b } };
        },
        else => return null,
    }
}
fn color(value: c.GhosttyStyleColor) Color {
    return switch (value.tag) {
        c.GHOSTTY_STYLE_COLOR_PALETTE => .{ .index = value.value.palette },
        c.GHOSTTY_STYLE_COLOR_RGB => .{ .rgb = .{ value.value.rgb.r, value.value.rgb.g, value.value.rgb.b } },
        else => .default,
    };
}
fn point(x: u16, y: u32) c.GhosttyPoint {
    return .{ .tag = c.GHOSTTY_POINT_TAG_SCREEN, .value = .{ .coordinate = .{ .x = x, .y = y } } };
}
/// Change generations are unique across every Vt, so a view that last
/// drew a freed Vt never mistakes a new one at the same address for it.
var next_generation = std.atomic.Value(u64).init(0);
const Impl = struct {
    query_colors: Vt.QueryColors = .{},
    cell: Vt.CellSize = .{},
    xtversion_buf: [64]u8 = undefined,
    xtversion_len: u8 = 0,
    color_scheme: ?Vt.ColorScheme = null,
    allocator: std.mem.Allocator,
    ca: c.GhosttyAllocator = undefined,
    terminal: c.GhosttyTerminal = null,
    anchor: c.GhosttyTrackedGridRef = null,
    epoch: u64 = 1,
    oldest: u64 = 0,
    anchor_abs: u64 = 0,
    reset_seen: bool = false,
    since_ground: usize = 0,
    history: ?*History = null,
    callbacks: Vt.Callbacks,
    // Row damage for Vt.changes, created on first use.
    render: c.GhosttyRenderState = null,
    render_rows: c.GhosttyRenderStateRowIterator = null,
    row_gen: []u64 = &.{},
    row_ids: []c.GhosttyRenderStateRowId = &.{},
    generation: u64 = 0,
    fn syncChanges(self: *Impl) Error!void {
        if (self.render == null) {
            try check(c.ghostty_render_state_new(&self.ca, &self.render));
            errdefer {
                c.ghostty_render_state_free(self.render);
                self.render = null;
            }
            try check(c.ghostty_render_state_row_iterator_new(&self.ca, &self.render_rows));
        }
        // The update consumes ghostty's dirty flags, so a failure from here
        // on forgets the rows: the next call reports every row changed.
        errdefer self.forgetRows();
        try check(c.ghostty_render_state_update(self.render, self.terminal));
        var dirty: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        try check(c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty));
        var rows: u16 = 0;
        try check(c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_ROWS, &rows));
        const resized = self.row_gen.len != rows;
        if (dirty == c.GHOSTTY_RENDER_STATE_DIRTY_FALSE and !resized) return;
        if (resized) {
            self.forgetRows();
            const gen = try self.allocator.alloc(u64, rows);
            errdefer self.allocator.free(gen);
            const ids = try self.allocator.alloc(c.GhosttyRenderStateRowId, rows);
            @memset(gen, 0);
            @memset(ids, std.mem.zeroes(c.GhosttyRenderStateRowId));
            self.row_gen = gen;
            self.row_ids = ids;
        }
        // Committed to self.generation only once every row is folded.
        const generation = next_generation.fetchAdd(1, .monotonic) + 1;
        const full = resized or dirty == c.GHOSTTY_RENDER_STATE_DIRTY_FULL;
        try check(c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.render_rows)));
        var y: usize = 0;
        while (y < rows and c.ghostty_render_state_row_iterator_next(self.render_rows)) : (y += 1) {
            var row_dirty = false;
            try check(c.ghostty_render_state_row_get(self.render_rows, c.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &row_dirty));
            var id: c.GhosttyRenderStateRowId = undefined;
            try check(c.ghostty_render_state_row_get(self.render_rows, c.GHOSTTY_RENDER_STATE_ROW_DATA_ID, &id));
            // A row id seen at another position means the row moved.
            if (full or row_dirty or !std.meta.eql(id.bits, self.row_ids[y].bits)) self.row_gen[y] = generation;
            self.row_ids[y] = id;
        }
        for (self.row_gen[y..]) |*g| g.* = generation;
        try check(c.ghostty_render_state_clean(self.render));
        self.generation = generation;
    }
    /// Drops the per-row state; the next sync treats every row as changed.
    fn forgetRows(self: *Impl) void {
        self.allocator.free(self.row_gen);
        self.allocator.free(self.row_ids);
        self.row_gen = &.{};
        self.row_ids = &.{};
    }
    fn get(self: *Impl, comptime T: type, key: c.GhosttyTerminalData) T {
        var value: T = undefined;
        check(c.ghostty_terminal_get(self.terminal, key, &value)) catch unreachable;
        return value;
    }
    /// Encodes a complete ghostty snapshot into memory owned by `allocator`.
    fn encode(self: *Impl, allocator: std.mem.Allocator) Error![]u8 {
        var bytes: [*c]u8 = null;
        var len: usize = 0;
        try check(c.ghostty_snapshot_encode_alloc(self.terminal, &self.ca, &bytes, &len));
        defer c.ghostty_free(&self.ca, bytes, len);
        return allocator.dupe(u8, bytes[0..len]);
    }
    fn endHistory(self: *Impl) void {
        const h = self.history orelse return;
        self.history = null;
        h.deinit(self.allocator);
    }
    fn newEpoch(self: *Impl) void {
        self.epoch += 1;
        self.oldest = 0;
        self.reset_seen = false;
    }
    fn reanchor(self: *Impl) Error!void {
        const y = self.get(usize, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS) - self.get(u16, c.GHOSTTY_TERMINAL_DATA_ROWS);
        // ACTIVE (0,0) is the same cell as SCREEN (0,total-rows), but
        // locating it starts at the active area rather than walking all
        // retained history pages on every anchor update.
        const pt: c.GhosttyPoint = .{ .tag = c.GHOSTTY_POINT_TAG_ACTIVE, .value = .{ .coordinate = .{ .x = 0, .y = 0 } } };
        if (self.anchor == null) try check(c.ghostty_terminal_grid_ref_track(self.terminal, pt, &self.anchor)) else try check(c.ghostty_tracked_grid_ref_set(self.anchor, self.terminal, pt));
        self.anchor_abs = self.oldest + y;
    }
    const color_options = [_]c.GhosttyTerminalOption{
        c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,
        c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND,
        c.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR,
    };
    const color_defaults = [_]c.GhosttyTerminalData{
        c.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT,
        c.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT,
        c.GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT,
    };
    fn queryDefaults(self: *Impl) [3]?c.GhosttyColorRgb {
        var out: [3]?c.GhosttyColorRgb = @splat(null);
        for (color_defaults, 0..) |key, i| {
            var rgb: c.GhosttyColorRgb = undefined;
            if (c.ghostty_terminal_get(self.terminal, key, &rgb) == c.GHOSTTY_SUCCESS) out[i] = rgb;
        }
        return out;
    }
    fn applyQueryDefaults(self: *Impl) Error!void {
        const colors = [_]?[3]u8{ self.query_colors.fg, self.query_colors.bg, self.query_colors.cursor };
        for (colors, color_options) |maybe_rgb, option| if (maybe_rgb) |rgb| {
            const value: c.GhosttyColorRgb = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
            try check(c.ghostty_terminal_set(self.terminal, option, &value));
        };
    }
    fn restoreDefaults(self: *Impl, colors: [3]?c.GhosttyColorRgb) void {
        for (colors, color_options) |maybe_rgb, option| {
            if (maybe_rgb) |rgb| {
                _ = c.ghostty_terminal_set(self.terminal, option, &rgb);
            } else _ = c.ghostty_terminal_set(self.terminal, option, null);
        }
    }

    fn setReplies(self: *Impl, replies: Vt.Replies) Error!void {
        if (replies.xtversion.len > self.xtversion_buf.len) return error.InvalidValue;
        const name: c.GhosttyString = .{ .ptr = replies.terminfo_name.ptr, .len = replies.terminfo_name.len };
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &name));
        @memcpy(self.xtversion_buf[0..replies.xtversion.len], replies.xtversion);
        self.xtversion_len = @intCast(replies.xtversion.len);
        self.color_scheme = replies.color_scheme;
    }
    /// A snapshot carries the current modes but not the values RIS restores,
    /// so set the reset default of mode 2027 again and keep the current value.
    fn restoreModeDefaults(self: *Impl) Error!void {
        var mode: c.GhosttyTerminalModeConfig = .{ .mode = c.GHOSTTY_MODE_GRAPHEME_CLUSTER, .value = false };
        try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_MODE, &mode));
        const current = mode.value;
        mode.value = Vt.grapheme_clustering_default;
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &mode));
        mode.value = current;
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_MODE, &mode));
    }
    fn installCallbacks(self: *Impl) Error!void {
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_USERDATA, self));
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(&writePty)));
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, @ptrCast(&programStatus)));
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, @ptrCast(&semanticPrompt)));
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_RESET, @ptrCast(&reset)));
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_BELL, @ptrCast(&bell)));
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_XTVERSION, @ptrCast(&xtversion)));
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_SIZE, @ptrCast(&sizeReport)));
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, @ptrCast(&colorScheme)));
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, @ptrCast(&deviceAttributes)));
    }
};
/// Receive state of a streamed snapshot, from the first prefix byte until
/// FINISH, an error, or abandonment.
const History = struct {
    vt: *Impl,
    continuation_bytes: usize,
    decoder: c.GhosttySnapshotDecoder = null,
    /// Received bytes not yet dropped. ghostty reads from `read_pos`.
    buf: std.ArrayList(u8) = .empty,
    read_pos: usize = 0,
    /// Start of the record at which the decoder's next step begins.
    step_pos: usize = 0,
    epoch: u64 = 0,
    fn deinit(self: *History, allocator: std.mem.Allocator) void {
        if (self.decoder != null) c.ghostty_snapshot_decoder_free(self.decoder);
        self.buf.deinit(allocator);
        allocator.destroy(self);
    }
    fn compact(self: *History, upto: usize) void {
        const keep = self.buf.items[upto..];
        std.mem.copyForwards(u8, self.buf.items[0..keep.len], keep);
        self.buf.items.len = keep.len;
        self.read_pos -= upto;
        self.step_pos -= upto;
    }
    fn read(ctx: ?*anyopaque, buffer: [*c]u8, capacity: usize, out: [*c]usize) callconv(.c) bool {
        const self: *History = @ptrCast(@alignCast(ctx.?));
        const n = @min(capacity, self.buf.items.len - self.read_pos);
        @memcpy(buffer[0..n], self.buf.items[self.read_pos..][0..n]);
        self.read_pos += n;
        out.* = n;
        return true;
    }
};
fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp <= 0x9f);
}
fn validatePlain(text: Vt.PlainText, options: Vt.PlainOptions) Error!void {
    if (text.cols == 0 or text.rows == 0 or options.continuation_bytes == 0) return error.InvalidValue;
    if (text.screen.len != text.rows or text.history.len > options.scrollback_lines) return error.InvalidValue;
    const max_rows = @min(options.max_rows, Vt.plain_max_rows);
    const max_bytes = @min(options.max_bytes, Vt.plain_max_bytes);
    if (text.history.len > max_rows or max_rows - text.history.len < text.rows) return error.InvalidValue;
    var bytes: usize = 0;
    for ([_][]const []const u8{ text.history, text.screen }) |part| for (part) |row| {
        bytes += row.len;
        if (bytes > max_bytes) return error.InvalidValue;
        var it = (std.unicode.Utf8View.init(row) catch return error.InvalidValue).iterator();
        while (it.nextCodepoint()) |cp| if (isControl(cp)) return error.InvalidValue;
    };
}
/// Scratch terminals `hydrateRow` needs for rows that do not hydrate on the
/// first try, made on first use and reused for every later row.
const HydrateProbes = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    /// `cols` wide, two rows: a row that wraps with autowrap on moves the
    /// cursor off row 0.
    wrap: ?Vt = null,
    /// `cols + 3` wide: where the cursor ends says how wide a row is, up to
    /// a little past `cols`.
    wide: ?Vt = null,

    fn deinit(self: *HydrateProbes) void {
        if (self.wrap) |*v| v.deinit();
        if (self.wide) |*v| v.deinit();
    }
    fn wrapProbe(self: *HydrateProbes) Error!*Impl {
        if (self.wrap == null) self.wrap = try Vt.init(self.allocator, .{ .cols = self.cols, .rows = 2, .scrollback_lines = 0 });
        return self.wrap.?.state();
    }
    fn wideProbe(self: *HydrateProbes) Error!*Impl {
        if (self.wide == null) self.wide = try Vt.init(self.allocator, .{ .cols = @intCast(@min(@as(u32, self.cols) + 3, std.math.maxInt(u16))), .rows = 1, .scrollback_lines = 0 });
        return self.wide.?.state();
    }
};
const RowMode = struct { wrap: bool, graphemes: bool };
/// Modes a row is laid out under, in the order they are tried: 2027 on (the
/// default, `Vt.grapheme_clustering_default`) with autowrap off and on, then
/// 2027 off the same way. The first that reads back wins, so a pane that never
/// turned 2027 off comes back as it was (a mark after the last column attaches
/// to the right cell only with autowrap on). Autowrap off runs in place; it
/// cannot spill into the next row.
const row_modes = [_]RowMode{ .{ .wrap = false, .graphemes = true }, .{ .wrap = true, .graphemes = true }, .{ .wrap = false, .graphemes = false }, .{ .wrap = true, .graphemes = false } };

/// Writes one validated row on the cursor's row and checks that it reads
/// back as `row`. The text came from a pane whose modes are unknown,
/// and two of them decide where cells land: mode 2027 (grapheme clusters, so
/// flags, ZWJ sequences and VS16 widths) and autowrap (a mark after the last
/// column only attaches to that cell while a wrap is pending). So each of
/// `row_modes` is tried once. Autowrap on is tried on a probe terminal first,
/// because an overlong row would wrap into the next one; only a row that
/// stays on its line is written for real.
///
/// A pane can also switch 2027 in the middle of a row, which no single mode
/// rebuilds, so such a row may read back in none of them (plain text is
/// lossy by design: it keeps cell text, not the modes that laid it out). The acceptance rule for that case, exactly:
/// the row is kept, and counted as cut (the return value), when
///   1. mode 2027 changes how it lays out (the two autowrap-off layouts
///      differ), and
///   2. its layout with 2027 on, the one that is kept, is at most `cols`
///      cells wide (measured on a `cols + 3` wide terminal: cursor column
///      <= `cols`).
/// The kept row is that 2027-on layout, cut at the last column. Anything else
/// is invalid: too wide (even by one cell), or a row 2027 does not affect
/// that does not read back (a leading combining mark).
///
/// Evidence for the bound: with the older, looser rule (any layout up to
/// `cols + 1`), the fuzz in plain_tests.zig (2027 switched on and off midway)
/// (seed 777, 40000 panes) sent 56 real rows down this path, and the 2027-on layout
/// of every real one was at most `cols` wide (by 0 to 2 cells under); none
/// was `cols + 1` or more. With this rule, the fuzz hydrates everything at
/// seeds 50 (6000 panes) and 777 (40000). Since mode 2027 is on by default
/// (and after RIS), seed 4242 (40000) finds one row it rejects: insert
/// characters (ICH) pushed a VS15-narrowed wide base into the last column,
/// which no left-to-right write rebuilds in either mode.
/// Text alone cannot tell a mixed-mode row from a malformed one that has the
/// same layouts, so this is
/// a bound, not a proof: a malformed row of 2027-sensitive text that fits
/// `cols` with 2027 on but does not read back is still kept.
fn hydrateRow(p: *Impl, probes: *HydrateProbes, scratch: *std.ArrayList(u8), row: []const u8, cols: u16, rows: u16) Error!bool {
    const allocator = probes.allocator;
    const total = p.get(usize, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS);
    const y: u32 = @intCast(total - rows + p.get(u16, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y));
    var off_hash: u64 = 0;
    var on_hash: u64 = 0;
    for (row_modes) |m| {
        if (!m.wrap) {
            try layoutRow(p.terminal, allocator, scratch, row, cols, y, m);
            if (readsBack(scratch.items, row)) return false;
            const h = std.hash.Wyhash.hash(0, scratch.items);
            if (m.graphemes) on_hash = h else off_hash = h;
            continue;
        }
        const pp = try probes.wrapProbe();
        c.ghostty_terminal_vt_write(pp.terminal, "\x1b[H", 3);
        try layoutRow(pp.terminal, allocator, scratch, row, cols, 0, m);
        if (pp.get(u16, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y) == 0 and readsBack(scratch.items, row)) {
            try layoutRow(p.terminal, allocator, scratch, row, cols, y, m);
            return false;
        }
    }
    if (off_hash == on_hash) return error.InvalidValue;
    const wp = try probes.wideProbe();
    try layoutRow(wp.terminal, allocator, scratch, row, cols, 0, .{ .wrap = false, .graphemes = true });
    if (wp.get(u16, c.GHOSTTY_TERMINAL_DATA_CURSOR_X) > cols) return error.InvalidValue;
    // The cut keeps the 2027-on, autowrap-off layout.
    try layoutRow(p.terminal, allocator, scratch, row, cols, y, .{ .wrap = false, .graphemes = true });
    return true;
}
/// Clears row `y` (the cursor's row), writes `row` into it under the given
/// modes and leaves its cells' text in `out`.
fn layoutRow(terminal: c.GhosttyTerminal, allocator: std.mem.Allocator, out: *std.ArrayList(u8), row: []const u8, cols: u16, y: u32, m: RowMode) Error!void {
    c.ghostty_terminal_vt_write(terminal, if (m.wrap) "\x1b[?7h" else "\x1b[?7l", 5);
    c.ghostty_terminal_vt_write(terminal, if (m.graphemes) "\x1b[?2027h" else "\x1b[?2027l", 8);
    c.ghostty_terminal_vt_write(terminal, "\r\x1b[2K", 5);
    writeLiteral(terminal, row);
    out.clearRetainingCapacity();
    try appendRow(terminal, allocator, out, cols, y);
}
fn readsBack(got: []const u8, row: []const u8) bool {
    return std.mem.startsWith(u8, got, row) and std.mem.indexOfNone(u8, got[row.len..], " ") == null;
}
/// Writes a validated row by re-encoding its printable characters.
fn writeLiteral(terminal: c.GhosttyTerminal, row: []const u8) void {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(row).iterator();
    while (it.nextCodepoint()) |cp| {
        std.debug.assert(!isControl(cp));
        if (len + 4 > buf.len) {
            c.ghostty_terminal_vt_write(terminal, &buf, len);
            len = 0;
        }
        len += std.unicode.utf8Encode(cp, buf[len..]) catch unreachable;
    }
    if (len > 0) c.ghostty_terminal_vt_write(terminal, &buf, len);
}
/// What a cell's codepoint reads and exports as. Cell contents come from
/// untrusted pane output and reading them must never fail. The emulator stores
/// a DEL from the PTY in a cell, where it takes a column but shows nothing, so
/// a control character renders as a space: the row keeps its columns and stays
/// free of controls, as `fromPlain` requires, and a reader never hands
/// a control to a host terminal or a clipboard. A value UTF-8 cannot
/// encode (no PTY byte produces one) is U+FFFD, like invalid UTF-8 on input.
fn plainCodepoint(cp: u32) u21 {
    if (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return 0xfffd;
    const scalar: u21 = @intCast(cp);
    return if (isControl(scalar)) ' ' else scalar;
}
/// Rows `exportPlain` asks the formatter for at a time. Bounds how far the
/// byte budget can be overshot in memory before the export stops.
const plain_chunk_rows = 1024;
/// Bulk row text for `exportPlain`. A cell-by-cell walk costs ~200 ns a cell
/// (`ghostty_terminal_grid_ref` finds the page again each time); the formatter
/// walks pages directly.
///
/// The formatter's text is not quite a row: it drops blank cells at the end
/// and skips spacer cells. So a row is its line plus one space per cell after
/// the last text. In a line of printable ASCII every cell is one column. Any
/// other line needs `contentEnd` to find where the text stops, which it does in
/// about 2 us a row. A control character takes a cell like any other
/// text, so a line holding one (a DEL) also costs that, with the character
/// rewritten to the space it renders as. Only a line that does not
/// decode goes through `appendRow`.
///
/// Most of a probe's cost is the page list: every formatter call with a
/// selection walks it from the top about six times, and a grid ref once. So a
/// run of rows with the same guess is checked by one call (`runBlankFrom`).
const PlainReader = struct {
    ca: *const c.GhosttyAllocator,
    terminal: c.GhosttyTerminal,
    formatter: c.GhosttyFormatter,
    cols: u16,
    first: usize = 0,
    count: usize = 0,
    /// The formatter's text for rows [first, first + count).
    text: []const u8 = &.{},
    /// Start of each line in `text`, then `text.len + 1`. Rows past the last
    /// line are blank: the formatter drops blank rows at the end.
    starts: [plain_chunk_rows + 1]usize = undefined,
    lines: usize = 0,
    /// What `load` knows about each of `lines`.
    plans: [plain_chunk_rows]LinePlan = undefined,
    /// Whether to guess from grapheme clusters first. It holds what worked on
    /// the last row whose two guesses differed: a pane tends to keep mode 2027
    /// one way, and a wrong guess costs about a row's whole time.
    clusters: bool = false,
    /// `clusters` when `plans` were made, so which guess each `guess` holds.
    planned_clusters: bool = false,

    fn init(ca: *const c.GhosttyAllocator, terminal: c.GhosttyTerminal, cols: u16) Error!PlainReader {
        var formatter: c.GhosttyFormatter = null;
        try check(c.ghostty_formatter_terminal_new(ca, &formatter, terminal));
        errdefer c.ghostty_formatter_free(formatter);
        const no = false;
        const extras: c.GhosttyFormatterExtras = c.GHOSTTY_FORMATTER_EXTRAS_NONE;
        try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_TRIM, &no));
        try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_UNWRAP, &no));
        try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_EXTRAS, &extras));
        return .{ .ca = ca, .terminal = terminal, .formatter = formatter, .cols = cols };
    }
    fn deinit(self: *PlainReader) void {
        self.freeText();
        c.ghostty_formatter_free(self.formatter);
    }
    fn freeText(self: *PlainReader) void {
        if (self.text.len > 0) c.ghostty_free(self.ca, @constCast(self.text.ptr), self.text.len);
        self.text = &.{};
        self.count = 0;
    }
    fn has(self: *const PlainReader, y: usize) bool {
        return y >= self.first and y - self.first < self.count;
    }
    /// Formats screen rows [first, first + count), count <= plain_chunk_rows.
    fn load(self: *PlainReader, first: usize, count: usize) Error!void {
        self.freeText();
        var selection: c.GhosttySelection = std.mem.zeroes(c.GhosttySelection);
        try check(c.ghostty_terminal_grid_ref(self.terminal, point(0, @intCast(first)), &selection.start));
        try check(c.ghostty_terminal_grid_ref(self.terminal, point(self.cols - 1, @intCast(first + count - 1)), &selection.end));
        try check(c.ghostty_formatter_set(self.formatter, c.GHOSTTY_FORMATTER_OPT_SELECTION, &selection));
        var bytes: [*c]u8 = null;
        var len: usize = 0;
        try check(c.ghostty_formatter_format_alloc(self.formatter, self.ca, &bytes, &len));
        if (len > 0) self.text = bytes[0..len];
        self.first = first;
        self.count = count;
        self.lines = 0;
        if (len == 0) return;
        var at: usize = 0;
        while (true) {
            if (self.lines == count) return error.Backend;
            self.starts[self.lines] = at;
            self.lines += 1;
            at = (std.mem.indexOfScalarPos(u8, self.text, at, '\n') orelse break) + 1;
        }
        self.starts[self.lines] = len + 1;
        self.planned_clusters = self.clusters;
        for (0..self.lines) |i| self.plans[i] = self.plan(self.line(i));
        self.probeRuns();
    }
    fn line(self: *const PlainReader, i: usize) []const u8 {
        return if (i < self.lines) self.text[self.starts[i] .. self.starts[i + 1] - 1] else "";
    }
    fn plan(self: *const PlainReader, text: []const u8) LinePlan {
        if (text.len == 0) return .{ .kind = .exact, .guess = 0 };
        if (text.len <= self.cols and isPrintableAscii(text)) return .{ .kind = .exact, .guess = @intCast(text.len) };
        var scanned = scanLine(text);
        if (self.clusters and scanned.kind != .undecodable) {
            if (clusterColumns(text)) |columns| scanned.guess = @intCast(columns);
        }
        return scanned;
    }
    /// Checks each run of lines that need `contentEnd` and share a guess.
    fn probeRuns(self: *PlainReader) void {
        var i: usize = 0;
        while (i < self.lines) {
            const first = self.plans[i];
            var end = i + 1;
            if (first.needsEnd()) {
                while (end < self.lines and self.plans[end].needsEnd() and self.plans[end].guess == first.guess) end += 1;
                // A lone row costs the same either way, later and only if asked.
                // Any failure just leaves the rows to `blankFrom`, which only
                // asks about rows the export keeps.
                if (end - i >= 2 and first.guess >= 1 and first.guess < self.cols and
                    (self.runBlankFrom(i, end, first.guess) catch false))
                {
                    for (self.plans[i..end]) |*p| p.blank_from = first.guess;
                }
            }
            i = end;
        }
    }
    /// Whether all of lines [from, to) are blank from column `x` on, with one
    /// formatter call on a rectangle of them. Only the all-blank answer can be
    /// used: where there is text, the lines do not line up with the rows. Past
    /// column 0 the formatter writes no newline between pages, or for a row
    /// that starts on a spacer head. So one row with text past the guess sends
    /// the whole run to `blankFrom`, row by row.
    fn runBlankFrom(self: *const PlainReader, from: usize, to: usize, x: usize) Error!bool {
        var selection: c.GhosttySelection = std.mem.zeroes(c.GhosttySelection);
        selection.rectangle = true;
        try check(c.ghostty_terminal_grid_ref(self.terminal, point(@intCast(x), @intCast(self.first + from)), &selection.start));
        try check(c.ghostty_terminal_grid_ref(self.terminal, point(self.cols - 1, @intCast(self.first + to - 1)), &selection.end));
        try check(c.ghostty_formatter_set(self.formatter, c.GHOSTTY_FORMATTER_OPT_SELECTION, &selection));
        var buf: [512]u8 = undefined;
        var written: usize = 0;
        const result = c.ghostty_formatter_format_buf(self.formatter, &buf, buf.len, &written);
        if (result == c.GHOSTTY_OUT_OF_SPACE) return false;
        try check(result);
        return written == 0;
    }
    /// Appends row `y`, which `has` must report loaded.
    fn append(self: *PlainReader, allocator: std.mem.Allocator, out: *std.ArrayList(u8), y: usize) Error!void {
        const i = y - self.first;
        const text = self.line(i);
        const planned: LinePlan = if (i < self.lines) self.plans[i] else .{ .kind = .exact, .guess = 0 };
        const end: usize = switch (planned.kind) {
            .exact => planned.guess,
            .text, .controls => try self.contentEnd(y, text, planned),
            .undecodable => return appendRow(self.terminal, allocator, out, self.cols, @intCast(y)),
        };
        try out.ensureUnusedCapacity(allocator, text.len + self.cols - end);
        if (planned.kind == .controls) appendControlsAsSpaces(out, text) else out.appendSliceAssumeCapacity(text);
        out.appendNTimesAssumeCapacity(' ', self.cols - end);
    }
    /// The column of row `y`, which holds `text`, from which only blank cells
    /// follow. The guesses (the sum of codepoint widths and `clusterColumns`)
    /// can both be wrong, since mode 2027 can change midway through a row. The
    /// answer does not depend on them, only the cost does: at most one
    /// formatter call when the first is right, about log2(cols) when neither is.
    fn contentEnd(self: *PlainReader, y: usize, text: []const u8, planned: LinePlan) Error!usize {
        // Blank from `high` on, and not blank from `low - 1`.
        var low: usize = 1;
        var high: usize = self.cols;
        if (try self.tryGuess(y, std.math.clamp(planned.guess, low, high), &low, &high)) |end| return end;
        const second = if (self.planned_clusters) planned.columns else clusterColumns(text) orelse planned.columns;
        if (second != planned.guess and second >= low and second <= high) {
            if (try self.tryGuess(y, second, &low, &high)) |end| {
                self.clusters = !self.planned_clusters;
                return end;
            }
        }
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (try self.blankFrom(middle, y)) high = middle else low = middle + 1;
        }
        return high;
    }
    /// Returns `guess`, in [low, high], if it is the end of row `y`'s text.
    /// Otherwise narrows the range to the side the answer is on.
    fn tryGuess(self: *const PlainReader, y: usize, guess: usize, low: *usize, high: *usize) Error!?usize {
        if (guess == high.* or try self.blankFrom(guess, y)) {
            if (try self.usedAt(guess - 1, y)) return guess;
            high.* = @max(guess - 1, low.*);
        } else low.* = guess + 1;
        return null;
    }
    /// Whether the cell at column `x` of row `y` holds text or the tail of a
    /// wide cell: exactly when the row is not blank from `x` on, if the row is
    /// blank after `x`.
    fn usedAt(self: *const PlainReader, x: usize, y: usize) Error!bool {
        var ref: c.GhosttyGridRef = std.mem.zeroes(c.GhosttyGridRef);
        try check(c.ghostty_terminal_grid_ref(self.terminal, point(@intCast(x), @intCast(y)), &ref));
        var raw: c.GhosttyCell = undefined;
        try check(c.ghostty_grid_ref_cell(&ref, &raw));
        var wide: c.GhosttyCellWide = 0;
        try check(c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, &wide));
        if (wide == c.GHOSTTY_CELL_WIDE_SPACER_TAIL) return true;
        var has_text = false;
        try check(c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_HAS_TEXT, &has_text));
        return has_text;
    }
    /// Whether row `y` has no text from column `x` on. It is monotonic in `x`:
    /// a selection starting on the tail of a wide cell includes the wide cell,
    /// and the formatter writes nothing for blank cells at the end of a row.
    fn blankFrom(self: *const PlainReader, x: usize, y: usize) Error!bool {
        if (x >= self.plans[y - self.first].blank_from) return true;
        var selection: c.GhosttySelection = std.mem.zeroes(c.GhosttySelection);
        try check(c.ghostty_terminal_grid_ref(self.terminal, point(@intCast(x), @intCast(y)), &selection.start));
        try check(c.ghostty_terminal_grid_ref(self.terminal, point(self.cols - 1, @intCast(y)), &selection.end));
        try check(c.ghostty_formatter_set(self.formatter, c.GHOSTTY_FORMATTER_OPT_SELECTION, &selection));
        // Big enough that a probe rarely overflows: on overflow the formatter
        // runs a second time to count what did not fit.
        var buf: [512]u8 = undefined;
        var written: usize = 0;
        const result = c.ghostty_formatter_format_buf(self.formatter, &buf, buf.len, &written);
        if (result == c.GHOSTTY_OUT_OF_SPACE) return false;
        try check(result);
        return written == 0;
    }
};
/// How `PlainReader.append` will treat a line of the formatter's text.
const LinePlan = struct {
    kind: enum {
        /// `guess` is the row's text end, known from the line alone.
        exact,
        /// `contentEnd` finds the text end.
        text,
        /// The same, and the line needs `appendControlsAsSpaces`.
        controls,
        /// Goes through `appendRow`.
        undecodable,
    },
    /// The first guess: from clusters if `planned_clusters`, else `columns`.
    guess: u32 = 0,
    /// The sum of codepoint widths.
    columns: u32 = 0,
    /// A column the row is known to be blank from.
    blank_from: u32 = std.math.maxInt(u32),

    fn needsEnd(self: LinePlan) bool {
        return self.kind == .text or self.kind == .controls;
    }
};
/// The plan for a line that may hold anything, guessing from codepoint widths,
/// which is right for text laid out with mode 2027 off. A line that does not
/// decode can't be used: such a cell renders as U+FFFD.
fn scanLine(line: []const u8) LinePlan {
    const view = std.unicode.Utf8View.init(line) catch return .{ .kind = .undecodable };
    var it = view.iterator();
    var columns: u32 = 0;
    var controls = false;
    while (it.nextCodepoint()) |cp| {
        // The terminal gives everything it prints below U+0100 one column,
        // where the codepoint width of a control is 0.
        if (isControl(cp)) {
            controls = true;
            columns += 1;
        } else columns += if (cp < 0x80) 1 else c.ghostty_unicode_codepoint_width(cp);
    }
    return .{ .kind = if (controls) .controls else .text, .guess = columns, .columns = columns };
}
/// Most codepoints of a line `clusterColumns` measures.
const plain_cluster_cps = 1024;
/// Columns `line`, which decodes, probably takes with mode 2027 on, as a guess
/// for `contentEnd`. Null for a line too long to measure, which is just a
/// guess not made.
fn clusterColumns(line: []const u8) ?usize {
    var cps: [plain_cluster_cps]u32 = undefined;
    var len: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(line).iterator();
    while (it.nextCodepoint()) |cp| : (len += 1) {
        if (len == cps.len) return null;
        // Controls are outside what the width function defines.
        cps[len] = plainCodepoint(cp);
    }
    var columns: usize = 0;
    var i: usize = 0;
    while (i < len) {
        var width: u8 = 0;
        i += c.ghostty_unicode_grapheme_width(&cps[i], len - i, &width);
        columns += width;
    }
    return columns;
}
/// Appends `line`, which decodes, as `plainCodepoint` renders it. `out` has
/// room for `line`: this only ever shrinks it.
fn appendControlsAsSpaces(out: *std.ArrayList(u8), line: []const u8) void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const b = line[i];
        if (b == 0xc2 and line[i + 1] <= 0x9f) {
            // U+0080 to U+009F, encoded as 0xC2 and one more byte.
            out.appendAssumeCapacity(' ');
            i += 1;
        } else out.appendAssumeCapacity(if (b < 0x20 or b == 0x7f) ' ' else b);
    }
}
fn isPrintableAscii(text: []const u8) bool {
    var bad: u8 = 0;
    for (text) |b| bad |= @intFromBool(b < 0x20 or b >= 0x7f);
    return bad == 0;
}
/// Appends the plain text of screen-coordinate row `y` (0 = oldest), as
/// `exportRows` renders it but without a newline.
fn appendRow(terminal: c.GhosttyTerminal, allocator: std.mem.Allocator, out: *std.ArrayList(u8), cols: u16, y: u32) Error!void {
    var small: [16]u32 = undefined;
    for (0..cols) |col| {
        var ref: c.GhosttyGridRef = std.mem.zeroes(c.GhosttyGridRef);
        try check(c.ghostty_terminal_grid_ref(terminal, point(@intCast(col), y), &ref));
        var raw: c.GhosttyCell = undefined;
        try check(c.ghostty_grid_ref_cell(&ref, &raw));
        var wide: c.GhosttyCellWide = 0;
        try check(c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, &wide));
        if (wide == c.GHOSTTY_CELL_WIDE_SPACER_TAIL) continue;
        var count: usize = 0;
        var cps: []u32 = &small;
        var heap: ?[]u32 = null;
        defer if (heap) |h| allocator.free(h);
        const first = c.ghostty_grid_ref_graphemes(&ref, &small, small.len, &count);
        if (first == c.GHOSTTY_OUT_OF_SPACE) {
            heap = try allocator.alloc(u32, count);
            cps = heap.?;
            try check(c.ghostty_grid_ref_graphemes(&ref, cps.ptr, count, &count));
        } else try check(first);
        if (count == 0) {
            try out.append(allocator, ' ');
            continue;
        }
        for (cps[0..count]) |cp| {
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(plainCodepoint(cp), &enc) catch unreachable;
            try out.appendSlice(allocator, enc[0..n]);
        }
    }
}
test "appendControlsAsSpaces renders a line as plainCodepoint does" {
    const line = "a\x7fb\x01\xc2\x80\xc2\x9f\xc2\xa0\xcc\x81\xe7\x95\x8c\xe2\x80\x8d\xf0\x9f\x91\xa9\x7f";
    var buf: [line.len]u8 = undefined;
    var out: std.ArrayList(u8) = .initBuffer(&buf);
    appendControlsAsSpaces(&out, line);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(std.testing.allocator);
    var it = std.unicode.Utf8View.initUnchecked(line).iterator();
    while (it.nextCodepoint()) |cp| {
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(plainCodepoint(cp), &enc) catch unreachable;
        try want.appendSlice(std.testing.allocator, enc[0..n]);
    }
    try std.testing.expectEqualStrings(want.items, out.items);
    try std.testing.expectEqualStrings("a b   \xc2\xa0\xcc\x81\xe7\x95\x8c\xe2\x80\x8d\xf0\x9f\x91\xa9 ", out.items);
}
test "clusterColumns measures what mode 2027 lays out, and gives up on long lines" {
    try std.testing.expectEqual(@as(?usize, 4), clusterColumns("\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb\xf0\x9f\x87\xba\xf0\x9f\x87\xb8"));
    try std.testing.expectEqual(@as(?usize, 3), clusterColumns("a\x7fb"));
    try std.testing.expectEqual(@as(?usize, 0), clusterColumns(""));
    const long: [plain_cluster_cps + 1]u8 = @splat('x');
    try std.testing.expectEqual(@as(?usize, plain_cluster_cps), clusterColumns(long[0..plain_cluster_cps]));
    try std.testing.expectEqual(@as(?usize, null), clusterColumns(&long));
}
test "plainCodepoint covers values no PTY byte reaches" {
    try std.testing.expectEqual(@as(u21, ' '), plainCodepoint(0));
    try std.testing.expectEqual(@as(u21, ' '), plainCodepoint(0x7f));
    try std.testing.expectEqual(@as(u21, ' '), plainCodepoint(0x9f));
    try std.testing.expectEqual(@as(u21, 0xfffd), plainCodepoint(0xd800));
    try std.testing.expectEqual(@as(u21, 0xfffd), plainCodepoint(0xdfff));
    try std.testing.expectEqual(@as(u21, 0xfffd), plainCodepoint(0x110000));
    try std.testing.expectEqual(@as(u21, 0xfffd), plainCodepoint(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u21, 0xa0), plainCodepoint(0xa0));
    try std.testing.expectEqual(@as(u21, 0xe000), plainCodepoint(0xe000));
    try std.testing.expectEqual(@as(u21, 0x10ffff), plainCodepoint(0x10ffff));
}
fn getData(comptime T: type, terminal: c.GhosttyTerminal, key: c.GhosttyTerminalData) T {
    var value: T = undefined;
    check(c.ghostty_terminal_get(terminal, key, &value)) catch unreachable;
    return value;
}
fn continuationLen(terminal: c.GhosttyTerminal) usize {
    var len: usize = 0;
    const r = c.ghostty_terminal_continuation_buf(terminal, null, 0, &len);
    return if (r == c.GHOSTTY_SUCCESS or r == c.GHOSTTY_OUT_OF_SPACE) len else 0;
}
const SavedCursor = struct { x: u16, y: u16 };
/// Saved cursor (DECSC) of the active screen, from its SCREEN record.
fn savedCursor(snap: []const u8, lay: stream.Layout) ?SavedCursor {
    const h = lay.active_screen;
    const at = h.payloadStart();
    if (h.len < 57 or snap[at + 52] != 1) return null;
    return .{ .x = std.mem.readInt(u16, snap[at + 53 ..][0..2], .little), .y = std.mem.readInt(u16, snap[at + 55 ..][0..2], .little) };
}
/// State the ghostty formatter does not restore: cursor shape, title and
/// dynamic colours. Also palette overrides, because the formatter can only
/// write the whole palette. Written before the formatter's output, whose modes
/// (including cursor blinking) then take precedence.
fn writeTerminalState(p: *Impl, snap: []const u8, lay: stream.Layout, tables: stream.TerminalTables, w: *std.Io.Writer) Error!void {
    const screen = lay.active_screen;
    if (screen.len < 17 or lay.terminal.len < 30) return error.InvalidSnapshot;
    const is_default = snap[lay.terminal.payloadStart() + 29] != 0;
    if (!is_default) {
        var mode: c.GhosttyTerminalModeConfig = .{ .mode = c.GHOSTTY_MODE_CURSOR_BLINKING, .value = false };
        try check(c.ghostty_terminal_get(p.terminal, c.GHOSTTY_TERMINAL_DATA_MODE, &mode));
        const shape: u8 = switch (snap[screen.payloadStart() + 16]) {
            0 => 5, // bar
            2 => 3, // underline
            else => 1, // block, hollow block
        };
        w.print("\x1b[{d} q", .{shape + @intFromBool(!mode.value)}) catch return error.OutOfMemory;
    }
    var title: c.GhosttyString = undefined;
    try check(c.ghostty_terminal_get(p.terminal, c.GHOSTTY_TERMINAL_DATA_TITLE, &title));
    if (title.len > 0) w.print("\x1b]2;{s}\x1b\\", .{title.ptr[0..title.len]}) catch return error.OutOfMemory;
    const pairs = [_]struct { u8, c.GhosttyTerminalData, c.GhosttyTerminalData }{
        .{ 10, c.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, c.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT },
        .{ 11, c.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, c.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT },
        .{ 12, c.GHOSTTY_TERMINAL_DATA_COLOR_CURSOR, c.GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT },
    };
    for (pairs) |pair| {
        var current: c.GhosttyColorRgb = undefined;
        var default: c.GhosttyColorRgb = undefined;
        if (c.ghostty_terminal_get(p.terminal, pair[1], &current) != c.GHOSTTY_SUCCESS) continue;
        const has_default = c.ghostty_terminal_get(p.terminal, pair[2], &default) == c.GHOSTTY_SUCCESS;
        if (has_default and std.meta.eql(current, default)) continue;
        w.print("\x1b]{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ pair[0], current.r, current.g, current.b }) catch return error.OutOfMemory;
    }
    var rgb = tables.overrides;
    for (0..256) |index| {
        if (!tables.overridden(@intCast(index))) continue;
        w.print("\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ index, rgb[0], rgb[1], rgb[2] }) catch return error.OutOfMemory;
        rgb = rgb[3..];
    }
}
/// Appends the VT dump of `terminal`'s active screen: up to `history` rows of
/// scrollback (oldest first) then every screen row, with the given extras.
/// Returns the history rows included. With `drop_tabstops`, `extras` must
/// include the tab stops; they are cut from the output.
fn formatScreen(p: *Impl, terminal: c.GhosttyTerminal, w: *std.Io.Writer, marked: ?*bool, history: u64, extras: c.GhosttyFormatterExtras, drop_tabstops: bool) Error!u64 {
    const total = getData(usize, terminal, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS);
    const height = getData(u16, terminal, c.GHOSTTY_TERMINAL_DATA_ROWS);
    const cols = getData(u16, terminal, c.GHOSTTY_TERMINAL_DATA_COLS);
    const rows: u64 = @min(history, total - height);
    var formatter: c.GhosttyFormatter = null;
    try check(c.ghostty_formatter_terminal_new(&p.ca, &formatter, terminal));
    defer c.ghostty_formatter_free(formatter);
    const emit: c.GhosttyFormatterFormat = c.GHOSTTY_FORMATTER_FORMAT_VT;
    const no = false;
    try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_EMIT, &emit));
    try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_TRIM, &no));
    try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_UNWRAP, &no));
    try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_EXTRAS, &extras));
    var selection: c.GhosttySelection = std.mem.zeroes(c.GhosttySelection);
    try check(c.ghostty_terminal_grid_ref(terminal, point(0, @intCast(total - height - rows)), &selection.start));
    try check(c.ghostty_terminal_grid_ref(terminal, point(cols - 1, @intCast(total - 1)), &selection.end));
    try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_SELECTION, &selection));
    var bytes: [*c]u8 = null;
    var len: usize = 0;
    try check(c.ghostty_formatter_format_alloc(formatter, &p.ca, &bytes, &len));
    defer c.ghostty_free(&p.ca, bytes, len);
    var out: []const u8 = if (len > 0) bytes[0..len] else "";
    if (drop_tabstops) {
        // `CSI 3 g`, the stops, then the `CSI H` that the screen dump needs.
        // That home must stay after the formatter's modes: writing our own
        // before them would move the cursor that `?1049h` saves.
        const start = std.mem.indexOf(u8, out, "\x1b[3g") orelse return error.Backend;
        const home = std.mem.indexOfPos(u8, out, start, "\x1b[H") orelse return error.Backend;
        w.writeAll(out[0..start]) catch return error.OutOfMemory;
        out = out[home..];
    }
    const any = try writeWithPrompts(p, terminal, w, out, extras != c.GHOSTTY_FORMATTER_EXTRA_CURSOR, total - height - rows, rows + height);
    if (marked) |m| m.* = any;
    return rows;
}
fn refPrompt(ref: *const c.GhosttyGridRef) Error!Vt.RowPrompt {
    var raw: c.GhosttyRow = undefined;
    try check(c.ghostty_grid_ref_row(ref, &raw));
    var value: c.GhosttyRowSemanticPrompt = c.GHOSTTY_ROW_SEMANTIC_NONE;
    try check(c.ghostty_row_get(raw, c.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &value));
    return switch (value) {
        c.GHOSTTY_ROW_SEMANTIC_PROMPT => .start,
        c.GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION => .continuation,
        else => .none,
    };
}
/// Writes the formatter's VT `out` for `count` screen rows from screen row
/// `first`, with the OSC 133 flags the formatter drops put back: A at
/// the start of each prompt row (`k=c` for a continuation), and C at the end
/// of a prompt row that no continuation follows, so the rows after it are not
/// taken for continuation lines. Rows are separated by CRLF; the content
/// follows the `CSI H` that ends the modes when `has_modes`. Output that does
/// not have the expected shape is written unchanged. The last row keeps the
/// state a prompt leaves, as the source terminal has it at a prompt.
fn writeWithPrompts(p: *Impl, terminal: c.GhosttyTerminal, w: *std.Io.Writer, out: []const u8, has_modes: bool, first: usize, count: usize) Error!bool {
    const flags = try p.allocator.alloc(Vt.RowPrompt, count);
    defer p.allocator.free(flags);
    var any = false;
    for (flags, 0..) |*f, k| {
        var ref: c.GhosttyGridRef = std.mem.zeroes(c.GhosttyGridRef);
        try check(c.ghostty_terminal_grid_ref(terminal, point(0, @intCast(first + k)), &ref));
        f.* = try refPrompt(&ref);
        any = any or f.* != .none;
    }
    const start: ?usize = if (!has_modes) 0 else if (std.mem.indexOf(u8, out, "\x1b[H")) |i| i + 3 else null;
    if (!any or start == null or std.mem.count(u8, out[start.?..], "\r\n") != count - 1) {
        w.writeAll(out) catch return error.OutOfMemory;
        return false;
    }
    w.writeAll(out[0..start.?]) catch return error.OutOfMemory;
    var pos = start.?;
    for (flags, 0..) |f, k| {
        switch (f) {
            .none => {},
            .start => w.writeAll("\x1b]133;A\x07") catch return error.OutOfMemory,
            .continuation => w.writeAll("\x1b]133;A;k=c\x07") catch return error.OutOfMemory,
        }
        const end = std.mem.indexOfPos(u8, out, pos, "\r\n") orelse out.len;
        if (k + 1 == count) {
            w.writeAll(out[pos..]) catch return error.OutOfMemory;
            break;
        }
        w.writeAll(out[pos..end]) catch return error.OutOfMemory;
        if (f != .none and flags[k + 1] != .continuation) w.writeAll("\x1b]133;D\x07") catch return error.OutOfMemory;
        w.writeAll("\r\n") catch return error.OutOfMemory;
        pos = end + 2;
    }
    return true;
}
fn fromContext(ctx: ?*anyopaque) *Impl {
    return @ptrCast(@alignCast(ctx.?));
}
fn string(s: c.GhosttyString) []const u8 {
    return if (s.len == 0) "" else s.ptr[0..s.len];
}
fn writePty(_: c.GhosttyTerminal, ctx: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    const p = fromContext(ctx);
    if (p.callbacks.write_pty) |cb| cb(p.callbacks.context, data[0..len]);
}
fn programStatus(_: c.GhosttyTerminal, ctx: ?*anyopaque, raw: [*c]const c.GhosttyTerminalProgramStatus) callconv(.c) void {
    const p = fromContext(ctx);
    const r = raw.*;
    if (r.state > 5 or r.kind > 3) return;
    if (p.callbacks.program_status) |cb| cb(p.callbacks.context, .{ .state = @fromBackingInt(@intCast(r.state)), .kind = @fromBackingInt(@intCast(r.kind)), .progress = if (r.progress < 0) null else @intCast(r.progress), .id = string(r.id), .app = string(r.app), .title = string(r.title), .message = string(r.message) });
}
fn semanticPrompt(_: c.GhosttyTerminal, ctx: ?*anyopaque, raw: [*c]const c.GhosttyTerminalSemanticPrompt) callconv(.c) void {
    const p = fromContext(ctx);
    const r = raw.*;
    if (r.kind < 1 or r.kind > 4 or r.prompt_kind > 3) return;
    if (p.callbacks.semantic_prompt) |cb| cb(p.callbacks.context, .{ .kind = @fromBackingInt(@intCast(r.kind - 1)), .prompt = @fromBackingInt(@intCast(r.prompt_kind)), .exit_code = if (r.has_exit_code) r.exit_code else null, .command = string(r.command), .message = string(r.@"error") });
}
fn bell(_: c.GhosttyTerminal, ctx: ?*anyopaque) callconv(.c) void {
    const p = fromContext(ctx);
    if (p.callbacks.bell) |cb| cb(p.callbacks.context);
}
fn xtversion(_: c.GhosttyTerminal, ctx: ?*anyopaque) callconv(.c) c.GhosttyString {
    const p = fromContext(ctx);
    return .{ .ptr = &p.xtversion_buf, .len = p.xtversion_len };
}
fn sizeReport(terminal: c.GhosttyTerminal, ctx: ?*anyopaque, out: [*c]c.GhosttySizeReportSize) callconv(.c) bool {
    const p = fromContext(ctx);
    var cols: u16 = 0;
    var rows: u16 = 0;
    if (c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_COLS, &cols) != c.GHOSTTY_SUCCESS) return false;
    if (c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_ROWS, &rows) != c.GHOSTTY_SUCCESS) return false;
    out.* = .{ .rows = rows, .columns = cols, .cell_width = p.cell.width, .cell_height = p.cell.height };
    return true;
}
fn colorScheme(_: c.GhosttyTerminal, ctx: ?*anyopaque, out: [*c]c.GhosttyColorScheme) callconv(.c) bool {
    const scheme = fromContext(ctx).color_scheme orelse return false;
    out.* = if (scheme == .dark) c.GHOSTTY_COLOR_SCHEME_DARK else c.GHOSTTY_COLOR_SCHEME_LIGHT;
    return true;
}
/// libghostty's default replies, plus OSC 52 in DA1 (`?62;22;52c`), as the
/// ghostty app advertises it.
fn deviceAttributes(_: c.GhosttyTerminal, _: ?*anyopaque, out: [*c]c.GhosttyDeviceAttributes) callconv(.c) bool {
    out.*.primary.conformance_level = c.GHOSTTY_DA_CONFORMANCE_VT220;
    out.*.primary.features[0] = c.GHOSTTY_DA_FEATURE_ANSI_COLOR;
    out.*.primary.features[1] = c.GHOSTTY_DA_FEATURE_CLIPBOARD;
    out.*.primary.num_features = 2;
    out.*.secondary.device_type = c.GHOSTTY_DA_DEVICE_TYPE_VT220;
    return true;
}
fn reset(_: c.GhosttyTerminal, ctx: ?*anyopaque) callconv(.c) void {
    fromContext(ctx).reset_seen = true;
}
fn alloc(ctx: ?*anyopaque, len: usize, alignment: u8, ret: usize) callconv(.c) ?*anyopaque {
    return fromContext(ctx).allocator.rawAlloc(len, @fromBackingInt(@intCast(alignment)), ret);
}
fn free(ctx: ?*anyopaque, memory: ?*anyopaque, len: usize, alignment: u8, ret: usize) callconv(.c) void {
    fromContext(ctx).allocator.rawFree(@as([*]u8, @ptrCast(memory.?))[0..len], @fromBackingInt(@intCast(alignment)), ret);
}
const allocator_vtable: c.GhosttyAllocatorVtable = .{ .alloc = alloc, .resize = null, .remap = null, .free = free, .reserved = @splat(null) };

test {
    _ = @import("stream.zig");
    _ = @import("vt_tests.zig");
    _ = @import("stream_tests.zig");
    _ = @import("plain_tests.zig");
    _ = @import("input_encode_tests.zig");
}

/// Restores the source cursor's OSC 133 state after the rows and the final
/// CUP: the cursor flags of the active SCREEN record say whether it sits in
/// prompt, input or output content. The replay's own marks leave it in
/// output state, so output needs a D only when `marked`.
fn writeCursorSemantic(p: *Impl, snap: []const u8, lay: stream.Layout, marked: bool, w: *std.Io.Writer) Error!void {
    const h = lay.active_screen;
    if (h.len < 18) return;
    const flags = snap[h.payloadStart() + 17];
    const prompt = flags & 0x08 != 0;
    const input = flags & 0x04 != 0;
    if (input) {
        w.writeAll(if (flags & 0x10 != 0) "\x1b]133;I\x07" else "\x1b]133;B\x07") catch return error.OutOfMemory;
    } else if (prompt) {
        const y = getData(u16, p.terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y);
        var ref: c.GhosttyGridRef = std.mem.zeroes(c.GhosttyGridRef);
        const pt: c.GhosttyPoint = .{ .tag = c.GHOSTTY_POINT_TAG_ACTIVE, .value = .{ .coordinate = .{ .x = 0, .y = y } } };
        try check(c.ghostty_terminal_grid_ref(p.terminal, pt, &ref));
        w.writeAll(if (try refPrompt(&ref) == .continuation) "\x1b]133;P;k=c\x07" else "\x1b]133;P\x07") catch return error.OutOfMemory;
    } else if (marked) {
        w.writeAll("\x1b]133;D\x07") catch return error.OutOfMemory;
    }
}
test "writeWithPrompts passes output through when its shape is not the expected one" {
    var vt = try Vt.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer vt.deinit();
    try vt.feed("\x1b]133;A\x07$ \x1b]133;C\x07\r\nb\r\nc");
    const p = vt.state();
    const cases = [_]struct { out: []const u8, modes: bool }{
        .{ .out = "$ \r\nb\r\nc\r\nextra", .modes = false }, // one CRLF too many
        .{ .out = "$ b c", .modes = false }, // too few
        .{ .out = "$ \r\nb\r\nc", .modes = true }, // modes, but no CSI H
    };
    for (cases) |tc| {
        var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buf.deinit();
        try std.testing.expect(!try writeWithPrompts(p, p.terminal, &buf.writer, tc.out, tc.modes, 0, 3));
        try std.testing.expectEqualStrings(tc.out, buf.written());
    }
    // The expected shape is rewritten.
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try std.testing.expect(try writeWithPrompts(p, p.terminal, &buf.writer, "$ \r\nb\r\nc", false, 0, 3));
    try std.testing.expectEqualStrings("\x1b]133;A\x07$ \x1b]133;D\x07\r\nb\r\nc", buf.written());
}
