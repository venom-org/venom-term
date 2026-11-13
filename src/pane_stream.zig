//! venomx pane-stream client, shared by every program that shows a venomx
//! pane. It is transport-free: `handle` consumes S→C frames and C→S frames
//! queue in `outbox` (`flush` sends them), so a test can wire it straight to a
//! server. Each emulating instance owns one Vt that never answers queries (no
//! `write_pty`) and keeps one client-local viewport.
//!
//! Raw passthrough shares the handshake, offsets, resume and resync,
//! and can fall back to emulation at any time, so its state lives here
//! too. What raw bytes do to a host terminal doesn't: the caller supplies a
//! `Passthrough`, which holds the output filter that keeps unsafe
//! sequences away from the host terminal.
const std = @import("std");
const Vt = @import("vt").Vt;
const Value = std.json.Value;

/// Frame types: the pane-stream frame catalog, plus the two core wire-protocol
/// frames that end a stream.
pub const Kind = struct {
    pub const attach = 0x100;
    pub const attached = 0x101;
    pub const snapshot = 0x102;
    pub const ready = 0x103;
    pub const pty = 0x104;
    pub const scrollback = 0x105;
    pub const input = 0x106;
    pub const resize = 0x107;
    pub const resync = 0x108;
    pub const exit = 0x109;
    pub const err = 3;
    pub const close = 6;
};
/// The `HELLO` capability that offers pane streams.
pub const capability = "venomx.pane_stream";

pub const Size = Vt.Size;
/// One queued C→S frame. The stream owns it until `flush` has sent it.
pub const Out = struct {
    kind: u16,
    payload: []u8,
    pub fn deinit(self: Out, a: std.mem.Allocator) void {
        a.free(self.payload);
    }
};
pub const Exit = union(enum) { code: u8, signal: []u8 };
/// `pending`: SCROLLBACK may still arrive. `aborted`: it stopped early, on an
/// ABORTED frame, a local epoch change or a resume; see `recoverBackfill`.
pub const Backfill = enum { none, pending, done, aborted };
pub const Format = enum {
    ghostty,
    vt,
    fn name(self: Format) []const u8 {
        return if (self == .ghostty) Vt.ghostty_format else Vt.vt_format;
    }
};
pub const Mode = enum { emulate, raw };
/// Why the client asked for a fresh snapshot; kept for diagnostics and tests.
pub const ResyncCause = enum { gap, resize_offset, decode, backfill, size, cell };
/// `phase` follows the stream's lifecycle from the client's side. `snapshot`
/// keeps the previous Vt visible (no blank flash) until the next READY.
pub const Phase = enum { attaching, snapshot, live, closed };
pub const Resume = struct { source: []const u8, offset: u64 };
/// How long the row epoch and both sizes must hold still before lost history
/// is asked for again, so that a drag costs one snapshot instead of one per
/// reflow. Above the server's 30 ms `resize_coalesce_ms` and a host's resize
/// cadence, and short enough not to be noticed.
pub const backfill_settle_ms: i64 = 150;

/// Where a raw stream's bytes go. Both calls run inside `handle`, and
/// an error they return comes out of it.
pub const Passthrough = struct {
    ctx: *anyopaque,
    /// A snapshot replay follows: put the host in the state it expects.
    begin: *const fn (ctx: *anyopaque) anyerror!void,
    /// Replay or `PTY` bytes, split anywhere. `clipboard`: whether this
    /// attachment may let OSC 52 writes through.
    feed: *const fn (ctx: *anyopaque, bytes: []const u8, clipboard: bool) anyerror!void,
};

const Settling = struct { since: i64, epoch: u64, pane: Size, viewport: Size };

pub const PaneStream = struct {
    a: std.mem.Allocator,
    pane: []u8,
    id: u32,
    size: Size,
    /// The viewport last sent in ATTACH or RESIZE.
    reported: Size = .{ .cols = 0, .rows = 0 },
    history: u64,
    formats: []const Format = &.{ .ghostty, .vt },
    claim: bool = true,
    /// The host terminal's cell size in pixels, sent as `ATTACH.cell`.
    /// Set it with `setCell`.
    cell: ?Vt.CellSize = null,
    /// Set before `attach`, with `formats = &.{.vt}` and `passthrough`, for a
    /// raw stream. `fallback` sets it back to `emulate`.
    mode: Mode = .emulate,
    /// A raw stream's output. It never creates a Vt until it falls back.
    passthrough: ?Passthrough = null,
    /// The `clipboard` argument of `Passthrough.feed`: this client is a writer
    /// and the server's `raw_clipboard` isn't `off`.
    clipboard: bool = false,
    phase: Phase = .attaching,
    format: Format = .ghostty,
    source: ?[]u8 = null,
    writer: bool = false,
    /// The pane's authoritative size (READY/RESIZE/ATTACHED), not the viewport.
    pane_size: Size = .{ .cols = 1, .rows = 1 },
    snap: u32 = 0,
    decoder: ?Vt.Decoder = null,
    prefix: std.ArrayList(u8) = .empty,
    vt: ?Vt = null,
    /// End of the last applied PTY byte: the next expected PTY offset.
    offset: u64 = 0,
    /// Waiting for the server's RESYNC after asking for one; PTY is discarded.
    discarding: bool = false,
    backfill: Backfill = .none,
    /// Lowest absolute row the server will backfill for this snapshot.
    history_floor: u64 = 0,
    history_epoch: u64 = 0,
    /// This snapshot left rows for SCROLLBACK to bring: never with history 0,
    /// none retained, or a raw or `vt` stream, which have no backfill to lose.
    history_wanted: bool = false,
    /// This snapshot was taken on the alternate screen, which has no history
    /// (`top` is 0). The primary screen's rows were never sent, so leaving the
    /// alternate screen finds them lost, though no SCROLLBACK was ever due.
    alt_snapshot: bool = false,
    /// A recovery RESYNC is out; the next READY renumbers this client's rows.
    recovering: bool = false,
    /// What `recoverBackfill` last saw changing; null while nothing is lost.
    settling: ?Settling = null,
    exit: ?Exit = null,
    closed: ?[]u8 = null,
    outbox: std.ArrayList(Out) = .empty,
    resyncs: u32 = 0,
    last_resync: ?ResyncCause = null,
    /// Bumped on every visible change; the presentation layer redraws on it.
    generation: u64 = 1,

    /// `id` is the odd stream ID the caller picked for this attach.
    pub fn init(a: std.mem.Allocator, pane: []const u8, id: u32, size: Size, history: u64) !PaneStream {
        if (id % 2 == 0 or size.cols == 0 or size.rows == 0) return error.InvalidParams;
        return .{ .a = a, .pane = try a.dupe(u8, pane), .id = id, .size = size, .history = history };
    }
    pub fn deinit(self: *PaneStream) void {
        if (self.decoder) |*d| d.deinit();
        if (self.vt) |*v| v.deinit();
        self.prefix.deinit(self.a);
        if (self.source) |src| self.a.free(src);
        if (self.exit) |e| if (e == .signal) self.a.free(e.signal);
        if (self.closed) |c| self.a.free(c);
        for (self.outbox.items) |o| o.deinit(self.a);
        self.outbox.deinit(self.a);
        self.a.free(self.pane);
    }
    fn queue(self: *PaneStream, kind: u16, value: anytype) !void {
        const payload = try std.json.Stringify.valueAlloc(self.a, value, .{ .emit_null_optional_fields = false });
        errdefer self.a.free(payload);
        try self.outbox.append(self.a, .{ .kind = kind, .payload = payload });
    }
    fn queueBytes(self: *PaneStream, kind: u16, bytes: []const u8) !void {
        const payload = try self.a.dupe(u8, bytes);
        errdefer self.a.free(payload);
        try self.outbox.append(self.a, .{ .kind = kind, .payload = payload });
    }
    fn formatNames(self: *const PaneStream, buf: *[2][]const u8) []const []const u8 {
        for (self.formats, 0..) |f, i| buf[i] = f.name();
        return buf[0..self.formats.len];
    }
    /// Queue ATTACH. With `resume`, the server continues at `offset` when it
    /// still can; otherwise it answers with a fresh snapshot.
    pub fn attach(self: *PaneStream, @"resume": ?Resume) !void {
        var names: [2][]const u8 = undefined;
        try self.queue(Kind.attach, .{ .pane = self.pane, .mode = @tagName(self.mode), .formats = self.formatNames(&names), .size = self.size, .history = self.history, .claim = self.claim, .@"resume" = @"resume", .cell = self.cell });
        self.phase = .attaching;
        self.reported = self.size;
    }
    /// Reconnect: reuse the emulator state and ask to resume on stream `id`.
    pub fn reattach(self: *PaneStream, id: u32) !void {
        for (self.outbox.items) |o| o.deinit(self.a);
        self.outbox.clearRetainingCapacity();
        self.id = id;
        self.discarding = false;
        if (self.decoder) |*d| d.deinit();
        self.decoder = null;
        const resumable = (self.vt != null or self.mode == .raw) and self.source != null and self.phase == .live;
        try self.attach(if (resumable) .{ .source = self.source.?, .offset = self.offset } else null);
    }
    /// Hand the queued C→S frames to `send`, oldest first. A frame leaves the
    /// outbox before it is freed, so when `send` fails part-way the stream
    /// still owns exactly the frames not yet sent; freeing in a `defer` and
    /// clearing afterwards would free them twice on an error.
    pub fn flush(self: *PaneStream, ctx: anytype, comptime send: fn (@TypeOf(ctx), u32, Out) anyerror!void) !void {
        var sent: usize = 0;
        defer {
            for (self.outbox.items[0..sent]) |o| o.deinit(self.a);
            const left = self.outbox.items.len - sent;
            std.mem.copyForwards(Out, self.outbox.items[0..left], self.outbox.items[sent..]);
            self.outbox.items.len = left;
        }
        for (self.outbox.items) |o| {
            try send(ctx, self.id, o);
            sent += 1;
        }
    }
    /// Bytes for the pane's PTY; dropped unless this client is a writer.
    pub fn input(self: *PaneStream, bytes: []const u8) !void {
        if (!self.writer or self.phase == .attaching or self.phase == .closed or bytes.len == 0) return;
        try self.queueBytes(Kind.input, bytes);
    }
    /// Record this client's viewport for the pane. Only writers report it;
    /// zero dimensions are never sent.
    pub fn viewport(self: *PaneStream, size: Size) !void {
        if (size.cols == 0 or size.rows == 0) return;
        self.size = size;
        try self.report();
        if (self.mode == .raw and self.phase == .live and !std.meta.eql(self.size, self.pane_size)) try self.fallback();
    }
    /// Record the host's cell size; null or a zero dimension means unknown.
    /// A writer that is live sends a change with a RESYNC.
    pub fn setCell(self: *PaneStream, cell: ?Vt.CellSize) !void {
        const known: ?Vt.CellSize = if (cell) |cs| (if (cs.width == 0 or cs.height == 0) null else cs) else null;
        if (std.meta.eql(known, self.cell)) return;
        self.cell = known;
        if (known != null and self.writer) try self.requestResync(.cell);
    }
    /// Stop passing through and render as an emulating client.
    pub fn fallback(self: *PaneStream) !void {
        self.mode = .emulate;
        // The raw handshake only negotiated VT; the daemon may use another
        // ghostty pin. Keep VT as the sole format so the RESYNC response has
        // an unambiguous decoder even without a new ATTACHED frame.
        self.formats = &.{.vt};
        self.format = .vt;
        // ATTACHED/READY can reveal a mismatch before any live bytes.
        self.phase = .live;
        try self.requestResync(.size);
    }
    fn report(self: *PaneStream) !void {
        if (!self.writer or self.phase == .attaching or self.phase == .closed or std.meta.eql(self.size, self.reported)) return;
        try self.queue(Kind.resize, self.size);
        self.reported = self.size;
    }
    /// Ask for a fresh snapshot. Discards PTY until the server's RESYNC.
    pub fn requestResync(self: *PaneStream, cause: ResyncCause) !void {
        if (self.phase != .live or self.discarding) return;
        var names: [2][]const u8 = undefined;
        // Getting history back is not activity. With the stream's
        // `claim` it could take the pane's size from the active writer, and
        // that reflow would abort the other writer's backfill in turn.
        const claim: ?bool = if (cause == .backfill) false else null;
        try self.queue(Kind.resync, .{ .mode = @tagName(self.mode), .formats = self.formatNames(&names), .history = self.history, .claim = claim, .cell = self.cell });
        self.discarding = true;
        self.resyncs += 1;
        self.last_resync = cause;
        if (cause == .backfill) self.recovering = true;
    }
    fn backfillLost(self: *const PaneStream) bool {
        // A snapshot taken on the alternate screen has no history and would
        // replace the rows this client has. Leaving it starts a new epoch, so
        // recovery then waits out the settle time as usual.
        return self.backfill == .aborted and self.history_wanted and self.phase == .live and !self.discarding and self.vt.?.screen() == .primary;
    }
    /// Once per transport turn: ask for history again after an aborted, stale
    /// or unresumed backfill, once nothing has
    /// changed for `backfill_settle_ms`. `now` is in milliseconds, from any
    /// clock that only moves forward.
    pub fn recoverBackfill(self: *PaneStream, now: i64) !void {
        if (!self.backfillLost()) {
            self.settling = null;
            return;
        }
        const seen: Settling = .{ .since = now, .epoch = self.vt.?.rows().epoch, .pane = self.pane_size, .viewport = self.size };
        const last = self.settling orelse {
            self.settling = seen;
            return;
        };
        if (last.epoch != seen.epoch or !std.meta.eql(last.pane, seen.pane) or !std.meta.eql(last.viewport, seen.viewport)) {
            self.settling = seen;
            return;
        }
        if (now - last.since < backfill_settle_ms) return;
        self.settling = null;
        try self.requestResync(.backfill);
    }
    /// When `recoverBackfill` must run next; null when nothing is waiting.
    pub fn recoveryDeadline(self: *const PaneStream) ?i64 {
        if (!self.backfillLost()) return null;
        const settling = self.settling orelse return null;
        return settling.since + backfill_settle_ms;
    }
    pub fn detach(self: *PaneStream) !void {
        if (self.phase == .closed) return;
        try self.queueBytes(Kind.close, "{}");
        try self.close("detached");
    }
    fn close(self: *PaneStream, reason: []const u8) !void {
        if (self.closed == null) self.closed = try self.a.dupe(u8, reason);
        self.phase = .closed;
        self.changed();
    }
    fn changed(self: *PaneStream) void {
        self.generation +%= 1;
    }
    /// Rows `[low, high)` the server will still send as SCROLLBACK. The
    /// presentation shows them as loading rather than as blank history.
    pub fn pendingRows(self: *const PaneStream) ?struct { low: u64, high: u64 } {
        if (self.backfill != .pending) return null;
        const vt = self.vt orelse return null;
        const rows = vt.rows();
        if (rows.epoch != self.history_epoch or rows.oldest <= self.history_floor) return null;
        return .{ .low = self.history_floor, .high = rows.oldest };
    }

    /// Consume one S→C frame for this stream. `error.BadFrame` means the frame
    /// broke the pane-stream rules; the caller decides whether to resync or close.
    pub fn handle(self: *PaneStream, kind: u16, payload: []const u8) !void {
        if (self.phase == .closed) return;
        switch (kind) {
            Kind.attached => try self.onAttached(payload),
            Kind.snapshot => try self.onSnapshot(payload),
            Kind.ready => try self.onReady(payload),
            Kind.pty => try self.onPty(payload),
            Kind.scrollback => try self.onScrollback(payload),
            Kind.resize => try self.onResize(payload),
            Kind.resync => try self.onResync(payload),
            Kind.exit => try self.onExit(payload),
            Kind.close => {
                const parsed = std.json.parseFromSlice(Value, self.a, payload, .{}) catch null;
                defer if (parsed) |p| p.deinit();
                try self.close(if (parsed) |p| string(p.value, "reason") orelse "closed" else "closed");
            },
            Kind.err => {
                const parsed = std.json.parseFromSlice(Value, self.a, payload, .{}) catch null;
                defer if (parsed) |p| p.deinit();
                try self.close(if (parsed) |p| string(p.value, "code") orelse "error" else "error");
            },
            else => return error.BadFrame,
        }
    }
    fn onAttached(self: *PaneStream, payload: []const u8) !void {
        if (self.phase != .attaching) return error.BadFrame;
        const parsed = try std.json.parseFromSlice(Value, self.a, payload, .{});
        defer parsed.deinit();
        const v = parsed.value;
        const source = string(v, "source") orelse return error.BadFrame;
        const format_name = string(v, "format") orelse return error.BadFrame;
        self.format = if (std.mem.eql(u8, format_name, Vt.ghostty_format)) .ghostty else if (std.mem.eql(u8, format_name, Vt.vt_format)) .vt else return error.BadFrame;
        if (self.mode == .raw and (self.format != .vt or !std.mem.eql(u8, string(v, "mode") orelse "", "raw"))) return error.BadFrame;
        const owned = try self.a.dupe(u8, source);
        if (self.source) |old| self.a.free(old);
        self.source = owned;
        self.writer = boolean(v, "input") orelse false;
        self.clipboard = self.writer and !std.mem.eql(u8, string(v, "raw_clipboard") orelse "external", "off");
        if (field(v, "size")) |sz| self.pane_size = try parseSize(sz);
        if (boolean(v, "resumed") orelse false) {
            const at = try uint(field(v, "offset") orelse return error.BadFrame);
            if ((self.vt == null and self.mode != .raw) or at != self.offset) return error.BadFrame;
            self.phase = .live;
            // Unfinished backfill is not resumed: nothing follows.
            if (self.backfill == .pending) {
                if (self.vt) |vt| if (vt.historyPending()) vt.abandonHistory();
                self.backfill = if (self.history_wanted) .aborted else .done;
            }
        } else {
            self.phase = .snapshot;
            self.snap = 0;
            self.prefix.clearRetainingCapacity();
        }
        if (self.mode == .raw and self.phase == .live and !std.meta.eql(self.size, self.pane_size)) {
            try self.fallback();
            return;
        }
        // The viewport may have changed while ATTACH was in flight.
        try self.report();
        self.changed();
    }
    fn onSnapshot(self: *PaneStream, payload: []const u8) !void {
        if (self.discarding) return;
        if (self.phase != .snapshot or payload.len < 12) return error.BadFrame;
        const snap = std.mem.readInt(u32, payload[0..4], .big);
        if (snap != self.snap) {
            // First chunk of a new snapshot: earlier partial state is stale.
            if (snap <= self.snap) return error.BadFrame;
            self.snap = snap;
            if (self.decoder) |*d| d.deinit();
            self.decoder = null;
            self.prefix.clearRetainingCapacity();
            if (self.format == .ghostty) self.decoder = try Vt.Decoder.init(self.a, .{});
        }
        const bytes = payload[12..];
        if (self.decoder) |d| try d.feedPrefix(bytes) else try self.prefix.appendSlice(self.a, bytes);
    }
    fn onReady(self: *PaneStream, payload: []const u8) !void {
        if (self.discarding) return;
        if (self.phase != .snapshot) return error.BadFrame;
        const parsed = try std.json.parseFromSlice(Value, self.a, payload, .{});
        defer parsed.deinit();
        const v = parsed.value;
        const snap = try uint(field(v, "snap") orelse return error.BadFrame);
        if (snap != self.snap) {
            // A snapshot whose prefix fits in no chunk still has a number.
            if (snap < self.snap or self.decoder != null or self.prefix.items.len != 0) return error.BadFrame;
            self.snap = std.math.cast(u32, snap) orelse return error.BadFrame;
            if (self.format == .ghostty) self.decoder = try Vt.Decoder.init(self.a, .{});
        }
        const meta: Vt.Ready = .{
            .epoch = try uint(field(v, "epoch") orelse return error.BadFrame),
            .oldest = try uint(field(v, "oldest") orelse return error.BadFrame),
            .top = try uint(field(v, "top") orelse return error.BadFrame),
            .active = try uint(field(v, "active") orelse return error.BadFrame),
            .cols = std.math.cast(u16, try uint(field(v, "cols") orelse return error.BadFrame)) orelse return error.BadFrame,
            .rows = std.math.cast(u16, try uint(field(v, "rows") orelse return error.BadFrame)) orelse return error.BadFrame,
        };
        const offset = try uint(field(v, "offset") orelse return error.BadFrame);
        if (self.mode == .raw) {
            self.pane_size = .{ .cols = meta.cols, .rows = meta.rows };
            if (!std.meta.eql(self.size, self.pane_size)) return self.fallback();
            const out = self.passthrough orelse return error.NoPassthrough;
            try out.begin(out.ctx);
            try out.feed(out.ctx, self.prefix.items, self.clipboard);
            self.prefix.clearRetainingCapacity();
            self.offset = offset;
            self.phase = .live;
            self.discarding = false;
            self.backfill = .pending;
            self.history_wanted = false;
            self.alt_snapshot = false;
            self.changed();
            return;
        }
        var fresh = self.build(meta) catch |err| {
            if (err == error.OutOfMemory) return err;
            // Undecodable snapshot: keep the old screen and ask again.
            self.phase = .live;
            self.discarding = false;
            return self.requestResync(.decode);
        };
        errdefer fresh.deinit();
        if (self.vt) |*old| old.deinit();
        self.vt = fresh;
        self.recovering = false;
        self.offset = offset;
        self.pane_size = .{ .cols = meta.cols, .rows = meta.rows };
        self.discarding = false;
        self.phase = .live;
        // The vt format carries no SCROLLBACK; only ghostty backfills rows.
        const want = if (self.format == .ghostty) @min(self.history, meta.top -| meta.oldest) else 0;
        self.history_floor = meta.top - want;
        self.history_epoch = fresh.rows().epoch;
        self.alt_snapshot = self.format == .ghostty and self.history > 0 and fresh.screen() == .alternate;
        self.history_wanted = want > 0 or self.alt_snapshot;
        self.backfill = .pending;
        self.changed();
    }
    fn build(self: *PaneStream, meta: Vt.Ready) !Vt {
        switch (self.format) {
            .ghostty => {
                if (self.decoder == null) return error.InvalidSnapshot;
                defer self.decoder = null;
                // ready() consumes the decoder on success only.
                return self.decoder.?.ready(meta) catch |err| {
                    self.decoder.?.deinit();
                    return err;
                };
            },
            .vt => {
                defer self.prefix.clearRetainingCapacity();
                var live = try Vt.init(self.a, .{ .cols = meta.cols, .rows = meta.rows });
                errdefer live.deinit();
                try live.feed(self.prefix.items);
                return live;
            },
        }
    }
    fn onPty(self: *PaneStream, payload: []const u8) !void {
        if (payload.len < 8) return error.BadFrame;
        if (self.phase != .live or self.discarding) return;
        const at = std.mem.readInt(u64, payload[0..8], .big);
        // A gap or overlap means this emulator no longer matches the pane.
        if (at != self.offset) return self.requestResync(.gap);
        if (self.mode == .raw) {
            const out = self.passthrough orelse return error.NoPassthrough;
            try out.feed(out.ctx, payload[8..], self.clipboard);
        } else try self.vt.?.feed(payload[8..]);
        self.offset += payload.len - 8;
        self.changed();
    }
    fn onScrollback(self: *PaneStream, payload: []const u8) !void {
        if (payload.len < 21) return error.BadFrame;
        const snap = std.mem.readInt(u32, payload[0..4], .big);
        // Backfill of an abandoned snapshot ends without LAST.
        if (snap != self.snap or self.backfill != .pending) return;
        if (self.phase != .live and self.phase != .snapshot) return;
        const flags = payload[20];
        const bytes = payload[21..];
        if (self.mode == .raw) {
            if (bytes.len != 0) return error.BadFrame;
            if (flags & 1 != 0) self.backfill = .done;
            return;
        }
        const vt = self.vt orelse return;
        if (bytes.len != 0 and self.format == .ghostty and !self.discarding) {
            _ = vt.feedHistory(bytes) catch |err| switch (err) {
                // A local epoch change (resize) stops backfill here, too.
                error.StaleRows => {
                    vt.abandonHistory();
                    self.backfill = .aborted;
                    self.changed();
                    return;
                },
                else => return err,
            };
            self.changed();
        }
        if (flags & 1 != 0) {
            if (flags & 2 != 0 or vt.historyPending()) vt.abandonHistory();
            // A LAST that ends an alternate-screen snapshot's backfill
            // brought no primary rows, so those are still lost.
            self.backfill = if (flags & 2 != 0 or self.alt_snapshot) .aborted else .done;
            self.changed();
        }
    }
    fn onResize(self: *PaneStream, payload: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Value, self.a, payload, .{});
        defer parsed.deinit();
        const v = parsed.value;
        const size = try parseSize(v);
        if (self.phase != .live or self.discarding) {
            self.pane_size = size;
            return;
        }
        const at = try uint(field(v, "offset") orelse return error.BadFrame);
        if (at != self.offset) return self.requestResync(.resize_offset);
        if (self.mode == .raw) {
            self.pane_size = size;
            if (!std.meta.eql(size, self.size)) try self.fallback();
            return;
        }
        try self.vt.?.resize(size.cols, size.rows);
        self.pane_size = size;
        self.changed();
    }
    fn onResync(self: *PaneStream, payload: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Value, self.a, payload, .{});
        defer parsed.deinit();
        if (self.phase == .attaching) return error.BadFrame;
        self.writer = boolean(parsed.value, "input") orelse self.writer;
        if (string(parsed.value, "raw_clipboard")) |policy| self.clipboard = self.writer and !std.mem.eql(u8, policy, "off");
        if (!self.writer) self.clipboard = false;
        // The number of the snapshot that follows. A resumed stream's numbering
        // starts over on the server, so it can be at or below ours.
        if (field(parsed.value, "snap")) |next| {
            const n = std.math.cast(u32, try uint(next)) orelse return error.BadFrame;
            if (n == 0) return error.BadFrame;
            self.snap = n - 1;
        }
        // Keep showing the old screen; replace it at the next READY.
        self.phase = .snapshot;
        self.discarding = false;
        if (self.vt) |vt| if (vt.historyPending()) vt.abandonHistory();
        self.backfill = .none;
        self.changed();
    }
    fn onExit(self: *PaneStream, payload: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Value, self.a, payload, .{});
        defer parsed.deinit();
        const v = parsed.value;
        const status: Exit = if (field(v, "exit_code")) |code|
            .{ .code = std.math.cast(u8, try uint(code)) orelse return error.BadFrame }
        else
            .{ .signal = try self.a.dupe(u8, string(v, "signal") orelse "unknown") };
        if (self.exit) |e| if (e == .signal) self.a.free(e.signal);
        self.exit = status;
        self.changed();
    }
};

fn field(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}
fn string(v: Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}
fn boolean(v: Value, key: []const u8) ?bool {
    const f = field(v, key) orelse return null;
    return if (f == .bool) f.bool else null;
}
fn uint(v: Value) !u64 {
    if (v != .integer or v.integer < 0) return error.BadFrame;
    return @intCast(v.integer);
}
fn parseSize(v: Value) !Size {
    const cols = std.math.cast(u16, try uint(field(v, "cols") orelse return error.BadFrame)) orelse return error.BadFrame;
    const rows = std.math.cast(u16, try uint(field(v, "rows") orelse return error.BadFrame)) orelse return error.BadFrame;
    if (cols == 0 or rows == 0) return error.BadFrame;
    return .{ .cols = cols, .rows = rows };
}

test {
    _ = @import("pane_stream_tests.zig");
}
