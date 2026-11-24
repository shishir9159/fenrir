//! What a patch covers: the convex hull of the words it replaces, one a
//! column a page.
//!
//! A patch hides a passage and sets a correction in its place, so its shape
//! is the passage's -- and a passage is a run of lines, each a box from
//! `selectionBoxes`, the first begun wherever the selection began and the
//! last ended wherever it ended. The hull of stacked boxes like that is at
//! most a hexagon:
//!
//!     x0 ·────────────────────────────· R      first line
//!       ╱                             │
//!   L ·                               │        whole lines
//!     │                               · (R, foot of the lines above the last)
//!     │                                ╲
//!     ·────────────────────────────────· x1    last line
//!
//! Its box is every line together, and two corners are cut off it: the
//! top-left, from where the first line begins down to the column's left
//! edge one line lower, and the bottom-right, from the column's right edge
//! down to where the last line ends. Four numbers say how much: `Insets`.
//! One line, or a `V` selection, is the box with nothing cut.
//!
//! **Several columns, or several pages, are several hulls.** A hull across
//! the gutter of a paper would cover the column beside it, and one across
//! a page break has no page to be on. `hulls` splits the lines by page and
//! by the column `text.Line` gives each, and takes the hull of each run.
//!
//! ## Where
//!
//! In the space every mark is in -- the page as displayed, points, y
//! upwards. So `top` is `box.max_y` and a line lower is a smaller y.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gelgja = @import("../gelgja.zig");

const Bounds = gelgja.Bounds;
const Point = gelgja.Point;

/// The two corners a hull cuts off its box, in points. All four are zero
/// for a rectangle.
pub const Insets = struct {
    /// How far right of the box's left edge the first line begins.
    head: f32 = 0,
    /// How far left of the box's right edge the last line ends.
    tail: f32 = 0,
    /// How far down the left edge the top-left cut reaches: about the first
    /// line's height.
    rise: f32 = 0,
    /// How far up the right edge the bottom-right cut reaches: about the
    /// last line's height.
    fall: f32 = 0,

    pub fn isRectangle(i: Insets) bool {
        return (i.head == 0 or i.rise == 0) and (i.tail == 0 or i.fall == 0);
    }
};

/// One line of a selection, as `hulls` is given it: where it is, and which
/// column of its page it belongs to.
pub const Line = struct {
    page: u32,
    column: u32 = 0,
    box: Bounds,
};

/// One piece of a patch: a hull on one page.
pub const Hull = struct {
    page: u32 = 0,
    box: Bounds = .empty,
    insets: Insets = .{},

    /// The six corners, clockwise from where the first line begins. Two of
    /// them coincide with their neighbours on a rectangle, which costs a
    /// reader of them nothing.
    pub fn corners(h: Hull) [6]Point {
        const b = h.box;
        const i = h.insets;
        return .{
            .{ .x = b.min_x + i.head, .y = b.max_y },
            .{ .x = b.max_x, .y = b.max_y },
            .{ .x = b.max_x, .y = b.min_y + i.fall },
            .{ .x = b.max_x - i.tail, .y = b.min_y },
            .{ .x = b.min_x, .y = b.min_y },
            .{ .x = b.min_x, .y = b.max_y - i.rise },
        };
    }

    /// Whether `p` is on the patch: in the box, and not in either corner it
    /// cuts off. What a click on a patch asks, since its box takes in the
    /// words before the first line's and after the last line's.
    pub fn contains(h: Hull, p: Point) bool {
        const b = h.box;
        if (!b.contains(p)) return false;
        const i = h.insets;
        // Each corner's triangle, measured from the corner it cuts: a point
        // whose two fractions along the legs sum under one is inside it.
        if (i.head > 0 and i.rise > 0) {
            const u = (p.x - b.min_x) / i.head;
            const w = (b.max_y - p.y) / i.rise;
            if (u + w < 1) return false;
        }
        if (i.tail > 0 and i.fall > 0) {
            const u = (b.max_x - p.x) / i.tail;
            const w = (p.y - b.min_y) / i.fall;
            if (u + w < 1) return false;
        }
        return true;
    }

    /// Where the hull's left edge is at height `y`, and its right: the
    /// span a scanline at that height covers. Both are the box's edges away
    /// from the two cuts.
    pub fn span(h: Hull, y: f32) [2]f32 {
        const b = h.box;
        const i = h.insets;
        var left = b.min_x;
        var right = b.max_x;
        if (i.rise > 0 and y > b.max_y - i.rise) {
            left += i.head * std.math.clamp((y - (b.max_y - i.rise)) / i.rise, 0, 1);
        }
        if (i.fall > 0 and y < b.min_y + i.fall) {
            right -= i.tail * std.math.clamp((b.min_y + i.fall - y) / i.fall, 0, 1);
        }
        return .{ left, right };
    }
};

/// The hull of one run of lines on one page and in one column, in reading
/// order. `whole` is a `V` selection, whose lines are taken whole and whose
/// hull is a rectangle.
///
/// **The hull covers part of the unselected head of the first line, and of
/// the tail of the last, on purpose.** The author asked for the hull over
/// per-line `/QuadPoints`, which cover exactly the selection: those are
/// concave, a staircase down the left of the passage and up the right, and
/// a correction set inside a staircase reads as torn paper. The words before
/// the first line's and after the last line's that a cut leaves under the
/// patch are the price of a shape that reads as one patch. Do not simplify
/// this back to a box a line.
pub fn hullOf(page: u32, lines: []const Bounds, whole: bool) Hull {
    std.debug.assert(lines.len != 0);
    var box: Bounds = .empty;
    for (lines) |l| box = box.unionWith(l);
    var h: Hull = .{ .page = page, .box = box };
    if (whole or lines.len == 1) return h;

    const first = lines[0];
    const last = lines[lines.len - 1];

    // The left cut comes down to the top of the highest line after the
    // first, or to the first line's foot if that is lower: nothing but the
    // first line is ever inside it.
    var below = first.min_y;
    for (lines[1..]) |l| below = @max(below, l.max_y);
    below = std.math.clamp(below, box.min_y, box.max_y);
    // And the right cut up to the foot of the lowest line before the last,
    // or to the last line's top if that is higher.
    var above = last.max_y;
    for (lines[0 .. lines.len - 1]) |l| above = @min(above, l.min_y);
    above = std.math.clamp(above, box.min_y, box.max_y);

    h.insets = .{
        .head = first.min_x - box.min_x,
        .tail = box.max_x - last.max_x,
        .rise = box.max_y - below,
        .fall = above - box.min_y,
    };
    std.debug.assert(convex(&h.corners()));
    return h;
}

/// Splits `lines`, in reading order, into runs of one page and one column,
/// and appends the hull of each to `out`.
pub fn hulls(gpa: Allocator, lines: []const Line, whole: bool, out: *std.ArrayList(Hull)) Allocator.Error!void {
    var boxes: std.ArrayList(Bounds) = .empty;
    defer boxes.deinit(gpa);

    var start: usize = 0;
    while (start < lines.len) {
        var end = start + 1;
        while (end < lines.len and lines[end].page == lines[start].page and lines[end].column == lines[start].column) end += 1;

        boxes.clearRetainingCapacity();
        for (lines[start..end]) |l| try boxes.append(gpa, l.box);
        try out.append(gpa, hullOf(lines[start].page, boxes.items, whole));
        start = end;
    }
}

/// Whether a polygon turns the same way at every corner, or goes straight
/// on: no reflex corner. A hull has none by construction, and this is the
/// check that construction keeps.
pub fn convex(points: []const Point) bool {
    var sign: f32 = 0;
    for (points, 0..) |a, i| {
        const b = points[(i + 1) % points.len];
        const c = points[(i + 2) % points.len];
        const turn = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
        // A slack of a thousandth of a square point: two corners that
        // coincide make a turn of nothing, which is not a turn either way.
        if (@abs(turn) < 1e-3) continue;
        if (sign == 0) sign = std.math.sign(turn);
        if (std.math.sign(turn) != sign) return false;
    }
    return true;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn line(x0: f32, y0: f32, x1: f32, y1: f32) Bounds {
    return .fromRect(x0, y0, x1, y1);
}

/// A paragraph's run as a selection gives it: the first line from x0, the
/// whole lines between, the last line to x1, twelve points a line.
fn paragraph(x0: f32, x1: f32, count: usize, buf: []Bounds) []const Bounds {
    for (buf[0..count], 0..) |*l, i| {
        const top = 700 - @as(f32, @floatFromInt(i)) * 12;
        const left: f32 = if (i == 0) x0 else 72;
        const right: f32 = if (i == count - 1) x1 else 540;
        l.* = line(left, top - 10, right, top);
    }
    return buf[0..count];
}

test "one line is a rectangle, and so is a V selection" {
    var buf: [4]Bounds = undefined;
    const one = hullOf(0, paragraph(200, 400, 1, &buf), false);
    try testing.expect(one.insets.isRectangle());
    try testing.expectEqual(line(200, 690, 400, 700), one.box);

    const whole = hullOf(0, paragraph(200, 400, 4, &buf), true);
    try testing.expect(whole.insets.isRectangle());
    try testing.expectEqual(line(72, 654, 540, 700), whole.box);
}

test "a paragraph's hull is a hexagon cut from where it begins to where it ends" {
    var buf: [4]Bounds = undefined;
    const lines = paragraph(200, 400, 4, &buf);
    const h = hullOf(0, lines, false);

    try testing.expectEqual(line(72, 654, 540, 700), h.box);
    try testing.expectEqual(@as(f32, 128), h.insets.head);
    try testing.expectEqual(@as(f32, 140), h.insets.tail);
    // Down the left to the first line's foot, which is below the second
    // line's top here; and up the right to the last line's top.
    try testing.expectEqual(@as(f32, 10), h.insets.rise);
    try testing.expectEqual(@as(f32, 10), h.insets.fall);

    const c = h.corners();
    try testing.expectEqual(Point{ .x = 200, .y = 700 }, c[0]);
    try testing.expectEqual(Point{ .x = 540, .y = 664 }, c[2]);
    try testing.expectEqual(Point{ .x = 400, .y = 654 }, c[3]);
    try testing.expectEqual(Point{ .x = 72, .y = 690 }, c[5]);
    try testing.expect(convex(&c));
}

test "every selected line is inside its hull, and the cut corners are not" {
    var buf: [4]Bounds = undefined;
    const lines = paragraph(200, 400, 4, &buf);
    const h = hullOf(0, lines, false);
    for (lines) |l| {
        for ([_]Point{
            .{ .x = l.min_x, .y = l.min_y }, .{ .x = l.max_x, .y = l.min_y },
            .{ .x = l.min_x, .y = l.max_y }, .{ .x = l.max_x, .y = l.max_y },
        }) |p| try testing.expect(h.contains(p));
    }
    // The column's top-left and bottom-right corners are cut away.
    try testing.expect(!h.contains(.{ .x = 73, .y = 699 }));
    try testing.expect(!h.contains(.{ .x = 539, .y = 655 }));
}

test "the hull covers some of the words before the first line's and after the last line's, as asked" {
    // The author chose the hull over a box a line, knowing it takes in the
    // foot of the first line's unselected head and the top of the last
    // line's unselected tail. This pins that it does: do not "fix" it.
    var buf: [4]Bounds = undefined;
    const lines = paragraph(200, 400, 4, &buf);
    const h = hullOf(0, lines, false);
    try testing.expect(h.contains(.{ .x = 180, .y = 691 }));
    try testing.expect(h.contains(.{ .x = 420, .y = 663 }));
}

test "a scanline's span runs between the cuts" {
    var buf: [4]Bounds = undefined;
    const h = hullOf(0, paragraph(200, 400, 4, &buf), false);
    try testing.expectEqual([2]f32{ 200, 540 }, h.span(700));
    try testing.expectEqual([2]f32{ 136, 540 }, h.span(695));
    try testing.expectEqual([2]f32{ 72, 540 }, h.span(677));
    try testing.expectEqual([2]f32{ 72, 470 }, h.span(659));
    try testing.expectEqual([2]f32{ 72, 400 }, h.span(654));
}

test "lines split by page and by column, one hull a run" {
    const gpa = testing.allocator;
    const lines = [_]Line{
        .{ .page = 2, .column = 1, .box = line(150, 90, 280, 100) },
        .{ .page = 2, .column = 1, .box = line(72, 78, 280, 88) },
        .{ .page = 2, .column = 2, .box = line(320, 690, 540, 700) },
        .{ .page = 2, .column = 2, .box = line(320, 678, 400, 688) },
        .{ .page = 3, .column = 1, .box = line(72, 690, 120, 700) },
    };
    var out: std.ArrayList(Hull) = .empty;
    defer out.deinit(gpa);
    try hulls(gpa, &lines, false, &out);

    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqual(line(72, 78, 280, 100), out.items[0].box);
    try testing.expectEqual(@as(f32, 78), out.items[0].insets.head);
    try testing.expectEqual(line(320, 678, 540, 700), out.items[1].box);
    try testing.expectEqual(@as(u32, 3), out.items[2].page);
    try testing.expect(out.items[2].insets.isRectangle());
}

/// `contains` with a thousandth of slack, for a corner that lies on a cut
/// and comes out of the division a rounding either side of it.
fn holds(h: Hull, p: Point) bool {
    const e = 1e-3;
    const b = h.box;
    if (p.x < b.min_x - e or p.x > b.max_x + e or p.y < b.min_y - e or p.y > b.max_y + e) return false;
    const i = h.insets;
    if (i.head > 0 and i.rise > 0 and (p.x - b.min_x) / i.head + (b.max_y - p.y) / i.rise < 1 - e) return false;
    if (i.tail > 0 and i.fall > 0 and (b.max_x - p.x) / i.tail + (p.y - b.min_y) / i.fall < 1 - e) return false;
    return true;
}

test "a hull is convex however ragged the lines it is made of" {
    var prng: std.Random.DefaultPrng = .init(0x9a7c4);
    const r = prng.random();
    var buf: [12]Bounds = undefined;
    for (0..2000) |_| {
        const n = r.intRangeAtMost(usize, 2, buf.len);
        var top: f32 = 700;
        for (buf[0..n]) |*l| {
            // Ragged edges, uneven leading, and lines that overlap the one
            // above, as a superscript or a tight setting makes them.
            const h = 6 + r.float(f32) * 10;
            const x0 = 60 + r.float(f32) * 300;
            const x1 = x0 + 5 + r.float(f32) * 300;
            l.* = line(x0, top - h, x1, top);
            top -= h * (0.6 + r.float(f32));
        }
        const hull = hullOf(0, buf[0..n], false);
        try testing.expect(convex(&hull.corners()));
        for (buf[0..n]) |l| {
            for ([_]Point{
                .{ .x = l.min_x, .y = l.min_y }, .{ .x = l.max_x, .y = l.min_y },
                .{ .x = l.min_x, .y = l.max_y }, .{ .x = l.max_x, .y = l.max_y },
            }) |p| try testing.expect(holds(hull, p));
        }
    }
}
