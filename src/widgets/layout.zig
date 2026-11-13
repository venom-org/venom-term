//! Split layout: side by side (horizontal) or stacked (vertical).
const std = @import("std");
const Region = @import("types").Region;

pub const Direction = enum { horizontal, vertical };

/// A cell position relative to a region's top-left corner.
pub const Hit = struct { col: u16, row: u16 };

/// Where screen cell (`x`, `y`) falls inside `region`, or null when it is
/// outside. Takes mouse coordinates, which may be negative.
pub fn hit(region: Region, x: i32, y: i32) ?Hit {
    if (x < region.x or y < region.y) return null;
    const col: u32 = @intCast(x - region.x);
    const row: u32 = @intCast(y - region.y);
    if (col >= region.width or row >= region.height) return null;
    return .{ .col = @intCast(col), .row = @intCast(row) };
}

pub const Constraint = union(enum) {
    /// Exactly this many cells (less if the region is too small).
    fixed: u16,
    /// A percentage of the whole extent, rounded down.
    percent: u8,
    /// A share of what is left after fixed and percent parts, by weight.
    fill: u16,
};

/// Splits `region` along `dir` into `out.len == constraints.len` parts.
/// Fixed and percent parts are taken in order and clamped to what is left;
/// the rest is shared by fill weights, with the remainder going to the last
/// fill part. Without a fill part, unused space stays at the end.
pub fn split(region: Region, dir: Direction, constraints: []const Constraint, out: []Region) void {
    std.debug.assert(out.len == constraints.len);
    const total: u32 = if (dir == .horizontal) region.width else region.height;
    var sizes: [64]u32 = undefined;
    std.debug.assert(constraints.len <= sizes.len);
    var left = total;
    var weights: u32 = 0;
    var last_fill: ?usize = null;
    for (constraints, 0..) |c, i| {
        sizes[i] = switch (c) {
            .fixed => |n| @min(n, left),
            .percent => |p| @min(total * @min(p, 100) / 100, left),
            .fill => |wt| blk: {
                weights += wt;
                last_fill = i;
                break :blk 0;
            },
        };
        left -= sizes[i];
    }
    if (last_fill) |lf| {
        var given: u32 = 0;
        for (constraints, 0..) |c, i| if (c == .fill) {
            sizes[i] = if (weights == 0) 0 else left * c.fill / weights;
            given += sizes[i];
        };
        sizes[lf] += left - given;
    }
    var pos: u32 = if (dir == .horizontal) region.x else region.y;
    for (out, 0..) |*r, i| {
        r.* = if (dir == .horizontal)
            .{ .x = @intCast(pos), .y = region.y, .width = @intCast(sizes[i]), .height = region.height }
        else
            .{ .x = region.x, .y = @intCast(pos), .width = region.width, .height = @intCast(sizes[i]) };
        pos += sizes[i];
    }
}

/// `split` into a fixed-size array.
pub fn splitN(comptime n: usize, region: Region, dir: Direction, constraints: [n]Constraint) [n]Region {
    var out: [n]Region = undefined;
    split(region, dir, &constraints, &out);
    return out;
}

/// Two regions side by side; `left` sizes the first, the second fills.
pub fn sideBySide(region: Region, left: Constraint) [2]Region {
    return splitN(2, region, .horizontal, .{ left, .{ .fill = 1 } });
}

/// Two regions stacked; `bottom` sizes the second, the first fills.
pub fn stacked(region: Region, bottom: Constraint) [2]Region {
    return splitN(2, region, .vertical, .{ .{ .fill = 1 }, bottom });
}

/// Shrinks a region by `n` cells on every side.
pub fn inset(region: Region, n: u16) Region {
    const w = region.width -| 2 * n;
    const h = region.height -| 2 * n;
    return .{ .x = region.x + @min(n, region.width), .y = region.y + @min(n, region.height), .width = w, .height = h };
}

test "split shares fill space by weight and clamps fixed parts" {
    const r: Region = .{ .x = 2, .y = 1, .width = 100, .height = 30 };
    const cols = splitN(3, r, .horizontal, .{ .{ .percent = 30 }, .{ .fill = 1 }, .{ .fixed = 20 } });
    try std.testing.expectEqual(Region{ .x = 2, .y = 1, .width = 30, .height = 30 }, cols[0]);
    try std.testing.expectEqual(Region{ .x = 32, .y = 1, .width = 50, .height = 30 }, cols[1]);
    try std.testing.expectEqual(Region{ .x = 82, .y = 1, .width = 20, .height = 30 }, cols[2]);

    const rows = splitN(3, r, .vertical, .{ .{ .fill = 1 }, .{ .fill = 2 }, .{ .fixed = 3 } });
    try std.testing.expectEqual(@as(u16, 9), rows[0].height);
    try std.testing.expectEqual(@as(u16, 18), rows[1].height);
    try std.testing.expectEqual(@as(u16, 28), rows[2].y);

    const tiny = splitN(2, .{ .width = 5, .height = 1 }, .horizontal, .{ .{ .fixed = 4 }, .{ .fixed = 4 } });
    try std.testing.expectEqual(@as(u16, 4), tiny[0].width);
    try std.testing.expectEqual(@as(u16, 1), tiny[1].width);

    const two = stacked(.{ .width = 10, .height = 10 }, .{ .fixed = 3 });
    try std.testing.expectEqual(@as(u16, 7), two[0].height);
    try std.testing.expectEqual(@as(u16, 7), two[1].y);
    try std.testing.expectEqual(Region{ .x = 1, .y = 1, .width = 8, .height = 8 }, inset(.{ .width = 10, .height = 10 }, 1));
    try std.testing.expectEqual(@as(u16, 0), inset(.{ .width = 1, .height = 1 }, 1).width);
}

test "hit maps screen cells into a region" {
    const r: Region = .{ .x = 2, .y = 1, .width = 3, .height = 2 };
    try std.testing.expectEqual(Hit{ .col = 0, .row = 0 }, hit(r, 2, 1).?);
    try std.testing.expectEqual(Hit{ .col = 2, .row = 1 }, hit(r, 4, 2).?);
    try std.testing.expect(hit(r, 5, 1) == null);
    try std.testing.expect(hit(r, 2, 3) == null);
    try std.testing.expect(hit(r, -1, 1) == null);
    try std.testing.expect(hit(.{ .width = 0, .height = 0 }, 0, 0) == null);
}
