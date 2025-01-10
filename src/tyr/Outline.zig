//! A glyph outline, in font units, in Gelgja's vocabulary.
//!
//! Every backend decomposes glyphs into this, which is what makes two backends
//! comparable: the same font through FreeType and through a native `glyf`
//! parser must produce the same points, and a test can say so without a
//! rasteriser existing.
//!
//! Two conversions happen here rather than in each backend, because both are
//! easy to get subtly wrong and a bug in one copy would be invisible next to a
//! correct one:
//!
//! **Quadratics are elevated to cubics.** TrueType outlines are quadratic,
//! CFF outlines are cubic, and Gelgja has only cubics because PDF has only
//! cubics. The elevation is exact -- a quadratic *is* a cubic with its control
//! points moved two thirds of the way -- so nothing is approximated and no
//! tolerance is involved. The alternative, adding a `quad` verb to Gelgja,
//! would make every rasteriser handle a case no content stream can produce.
//!
//! **Units stay in font units.** Backends are asked for unscaled outlines
//! (`FT_LOAD_NO_SCALE` and its equivalents) and the caller divides by
//! `units_per_em`. Normalising here would round-trip through float twice for
//! no gain, and would throw away the integer grid that hinting needs.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");
const Bounds = geom.Bounds;
const Point = geom.Point;
const Verb = geom.Verb;

const Outline = @This();

verbs: std.ArrayList(Verb) = .empty,
points: std.ArrayList(Point) = .empty,

/// The em square these coordinates are in: 1000 for CFF and Type 1, usually
/// 2048 for TrueType. A glyph is placed by scaling by `size / units_per_em`.
units_per_em: u16 = 1000,

/// Where the current contour began, so `close` knows where to return to.
start: ?Point = null,
cur: Point = .origin,

pub fn deinit(o: *Outline, gpa: Allocator) void {
    o.verbs.deinit(gpa);
    o.points.deinit(gpa);
    o.* = .{};
}

/// Keeps the allocation and drops the contents. Glyphs are decoded one after
/// another into the same buffer: a page of text is thousands of glyphs and
/// should not be thousands of allocations.
pub fn reset(o: *Outline, units_per_em: u16) void {
    o.verbs.clearRetainingCapacity();
    o.points.clearRetainingCapacity();
    o.units_per_em = units_per_em;
    o.start = null;
    o.cur = .origin;
}

pub fn isEmpty(o: Outline) bool {
    return o.verbs.items.len == 0;
}

// -- the sink, as a backend sees it -----------------------------------------

pub fn moveTo(o: *Outline, gpa: Allocator, p: Point) !void {
    try o.verbs.append(gpa, .move);
    try o.points.append(gpa, p);
    o.start = p;
    o.cur = p;
}

pub fn lineTo(o: *Outline, gpa: Allocator, p: Point) !void {
    // A contour that opens with a line has no start point. Repairing it into a
    // move keeps the verb and point arrays in step, which every consumer
    // relies on; dropping it would silently lose a stroke.
    if (o.start == null) return o.moveTo(gpa, p);
    try o.verbs.append(gpa, .line);
    try o.points.append(gpa, p);
    o.cur = p;
}

/// Degree elevation, exact: for a quadratic with control `q` running from the
/// current point to `p`, the cubic controls are `cur + 2/3 (q - cur)` and
/// `p + 2/3 (q - p)`.
pub fn quadTo(o: *Outline, gpa: Allocator, q: Point, p: Point) !void {
    if (o.start == null) try o.moveTo(gpa, o.cur);
    const p0 = o.cur;
    const c1: Point = .{
        .x = p0.x + (2.0 / 3.0) * (q.x - p0.x),
        .y = p0.y + (2.0 / 3.0) * (q.y - p0.y),
    };
    const c2: Point = .{
        .x = p.x + (2.0 / 3.0) * (q.x - p.x),
        .y = p.y + (2.0 / 3.0) * (q.y - p.y),
    };
    try o.cubicTo(gpa, c1, c2, p);
}

pub fn cubicTo(o: *Outline, gpa: Allocator, c1: Point, c2: Point, p: Point) !void {
    if (o.start == null) try o.moveTo(gpa, o.cur);
    try o.verbs.append(gpa, .cubic);
    try o.points.appendSlice(gpa, &.{ c1, c2, p });
    o.cur = p;
}

pub fn close(o: *Outline, gpa: Allocator) !void {
    if (o.start == null) return;
    try o.verbs.append(gpa, .close);
    o.cur = o.start.?;
    o.start = null;
}

// -- reading it back --------------------------------------------------------

pub fn bounds(o: Outline) Bounds {
    var b: Bounds = .empty;
    for (o.points.items) |p| b = b.add(p);
    return b;
}

/// The scale from font units to text space, before the font size is applied.
pub fn unitScale(o: Outline) f32 {
    return 1.0 / @as(f32, @floatFromInt(o.units_per_em));
}

/// Contour count, which is the number of `move` verbs. Cheap enough to use as
/// a structural assertion: a `.notdef` box has two, and so does an `o`.
pub fn contourCount(o: Outline) u32 {
    var n: u32 = 0;
    for (o.verbs.items) |v| {
        if (v == .move) n += 1;
    }
    return n;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "quadratic elevation is exact at the midpoint" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);

    // A quadratic from (0,0) to (100,0) with control (50,100) passes through
    // (50, 50) at t = 0.5.
    try o.moveTo(gpa, .{ .x = 0, .y = 0 });
    try o.quadTo(gpa, .{ .x = 50, .y = 100 }, .{ .x = 100, .y = 0 });

    const p = o.points.items;
    try testing.expectEqual(@as(usize, 4), p.len);
    const c1 = p[1];
    const c2 = p[2];
    const p3 = p[3];
    try testing.expectApproxEqAbs(@as(f32, 100.0 / 3.0), c1.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 200.0 / 3.0), c1.y, 1e-4);

    // Evaluate the elevated cubic at t = 0.5 and check it agrees.
    const t: f32 = 0.5;
    const mt = 1 - t;
    const x = 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * p3.x;
    const y = 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * p3.y;
    try testing.expectApproxEqAbs(@as(f32, 50), x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 50), y, 1e-3);
}

test "a contour opening with a line is repaired into a move" {
    var o: Outline = .{};
    defer o.deinit(testing.allocator);
    try o.lineTo(testing.allocator, .{ .x = 5, .y = 5 });
    try testing.expectEqual(Verb.move, o.verbs.items[0]);
    try testing.expectEqual(@as(usize, 1), o.verbs.items.len);
}

test "close returns the cursor to the contour start" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);

    try o.moveTo(gpa, .{ .x = 10, .y = 10 });
    try o.lineTo(gpa, .{ .x = 90, .y = 10 });
    try o.close(gpa);
    try testing.expectEqual(@as(f32, 10), o.cur.x);

    // A second close with no open contour is a no-op, not a stray verb.
    try o.close(gpa);
    try testing.expectEqual(@as(usize, 3), o.verbs.items.len);
}

test "verb and point counts stay in step" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);

    try o.moveTo(gpa, .origin);
    try o.lineTo(gpa, .{ .x = 1, .y = 0 });
    try o.quadTo(gpa, .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 0 });
    try o.cubicTo(gpa, .{ .x = 4, .y = 1 }, .{ .x = 5, .y = 1 }, .{ .x = 6, .y = 0 });
    try o.close(gpa);

    var expected: usize = 0;
    for (o.verbs.items) |v| expected += v.pointCount();
    try testing.expectEqual(expected, o.points.items.len);
    try testing.expectEqual(@as(u32, 1), o.contourCount());
}

test "reset keeps capacity and takes a new em square" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);

    try o.moveTo(gpa, .{ .x = 1, .y = 1 });
    const cap = o.points.capacity;

    o.reset(2048);
    try testing.expect(o.isEmpty());
    try testing.expectEqual(cap, o.points.capacity);
    try testing.expectEqual(@as(u16, 2048), o.units_per_em);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 2048.0), o.unitScale(), 1e-9);
}
