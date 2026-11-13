//! `Vt.exportPlain` cost for a pane at the plain-text export bounds.
//! Feeds the same 16 MiB / 99,864 rows as venomx `test/checkpoint_bench.py`,
//! times repeated exports and prints a hash of the rows, so two builds can
//! be compared for identical output. Times need a release build; on a busy
//! machine `cpu` (process CPU time) is steadier than `wall`.
//!
//! Usage: plain-bench [ascii|mixed|short|del|cjk|box|zwj|delvar|zwjvar] [trials]
//!   ascii  167 'x' per row (the checkpoint bench's load)
//!   mixed  the same, with one wide character in every row
//!   short  40 'x' per row, the rest blank
//!   del    167 columns per row, one of them a DEL
//!   cjk    60 wide characters per row, the rest blank
//!   box    a full row of box drawing, no blank cell
//!   zwj    ZWJ emoji under mode 2027, where summing codepoint widths is wrong
//!   delvar   `del` with a different length on each row, so no two neighbours
//!            share a column guess (the worst case for `runBlankFrom`)
//!   zwjvar   the same for `zwj`
const std = @import("std");
const Vt = @import("vt").Vt;
const cols = 200;
const screen_rows = 50;
const rows_total = 16 * 1024 * 1024 / 168;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const load = if (args.len > 1) args[1] else "ascii";
    const trials = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 5;
    const gpa = init.gpa;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    if (std.mem.eql(u8, load, "ascii")) {
        try line.appendNTimes(gpa, 'x', 167);
    } else if (std.mem.eql(u8, load, "mixed")) {
        try line.appendSlice(gpa, "界");
        try line.appendNTimes(gpa, 'x', 165);
    } else if (std.mem.eql(u8, load, "short")) {
        try line.appendNTimes(gpa, 'x', 40);
    } else if (std.mem.eql(u8, load, "del")) {
        try line.appendNTimes(gpa, 'x', 83);
        try line.append(gpa, 0x7f);
        try line.appendNTimes(gpa, 'x', 83);
    } else if (std.mem.eql(u8, load, "cjk")) {
        for (0..60) |_| try line.appendSlice(gpa, "界");
    } else if (std.mem.eql(u8, load, "box")) {
        for (0..cols) |_| try line.appendSlice(gpa, "─");
    } else if (std.mem.eql(u8, load, "zwj") or std.mem.eql(u8, load, "zwjvar")) {
        for (0..20) |_| try line.appendSlice(gpa, "👩\u{200d}💻");
    } else if (std.mem.eql(u8, load, "delvar")) {
        try line.append(gpa, 0x7f);
        try line.appendNTimes(gpa, 'x', 166);
    } else return error.InvalidLoad;
    const unit: usize = if (std.mem.eql(u8, load, "zwjvar")) "👩\u{200d}💻".len else if (std.mem.eql(u8, load, "delvar")) 1 else 0;
    const varied = unit != 0;
    const full = line.items.len;
    try line.appendSlice(gpa, "\r\n");

    var vt = try Vt.init(gpa, .{ .cols = cols, .rows = screen_rows, .scrollback_lines = rows_total + 1000 });
    defer vt.deinit();
    if (std.mem.eql(u8, load, "zwj") or std.mem.eql(u8, load, "zwjvar")) try vt.feed("\x1b[?2027h");
    for (0..rows_total) |row| {
        if (!varied) {
            try vt.feed(line.items);
            continue;
        }
        // Drop 0 to 6 units from the end of the row, in a cycle.
        try vt.feed(line.items[0 .. full - unit * (row % 7)]);
        try vt.feed("\r\n");
    }

    const limits: Vt.PlainLimits = .{ .max_rows = Vt.plain_max_rows, .max_bytes = Vt.plain_max_bytes };
    const times = try gpa.alloc(u64, trials);
    defer gpa.free(times);
    const cpu = try gpa.alloc(u64, trials);
    defer gpa.free(cpu);
    var hash: u64 = 0;
    var kept: usize = 0;
    for (times, cpu) |*t, *u| {
        const start = std.Io.Timestamp.now(init.io, .awake);
        const start_cpu = std.Io.Clock.cpu_process.now(init.io);
        const out = (try vt.exportPlain(gpa, limits)).?;
        t.* = @intCast(start.durationTo(std.Io.Timestamp.now(init.io, .awake)).toNanoseconds());
        u.* = @intCast(start_cpu.durationTo(std.Io.Clock.cpu_process.now(init.io)).toNanoseconds());
        defer out.deinit(gpa);
        var h = std.hash.Wyhash.init(0);
        for (out.lines) |row| {
            h.update(row);
            h.update("\n");
        }
        hash = h.final();
        kept = out.lines.len;
    }
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    std.mem.sort(u64, cpu, {}, std.sort.asc(u64));
    std.debug.print("load={s} rows={d} hash={x} wall_ms min={d} median={d} max={d} cpu_ms min={d} median={d} max={d}\n", .{ load, kept, hash, times[0] / 1_000_000, times[trials / 2] / 1_000_000, times[trials - 1] / 1_000_000, cpu[0] / 1_000_000, cpu[trials / 2] / 1_000_000, cpu[trials - 1] / 1_000_000 });
}
