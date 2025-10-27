//! Filling an outline into 8-bit coverage, on the CPU.
//!
//! Every glyph in the atlas arrives through one of two doors: a backend that
//! rasterises (FreeType, stb_truetype) or this file. It exists for three
//! reasons, in order of how much they matter.
//!
//! **A backend is not required to rasterise.** Týr's own `glyf` and Type 2
//! parsers, when they are written, will produce outlines and nothing else --
//! writing a scan converter into each of them would be the same code three
//! times. `Face.caps.rasterize` is the switch, and this is the other branch.
//!
//! **It makes the atlas testable on a machine with no C dependencies**, which
//! is this one. Without it, every glyph path in the program would be dead code
//! until someone installs FreeType.
//!
//! **It is the thing FreeType gets diffed against.** The multi-backend design
//! exists so that two renderings of the same glyph can be subtracted; that
//! requires a second opinion that is ours.
//!
//! ## The algorithm
//!
//! Signed-area accumulation, the method Raph Levien's `font-rs` popularised.
//! For each line segment, the *signed area it contributes to each cell it
//! crosses* is added into a float buffer; a running sum along each row then
//! turns those deltas into winding-weighted coverage. There is no sorted edge
//! list, no active edge table, and no supersampling: the antialiasing is
//! analytic, so a near-horizontal stem edge is exact rather than quantised to
//! however many samples a scanline budget allowed.
//!
//! Coverage is `min(|accumulated|, 1)`. That is not quite the nonzero rule --
//! two contours wound the same way and overlapping give 2, which saturates to
//! 1, where nonzero would also give 1, so they agree; a counter-wound inner
//! contour gives 0, and they agree there too. They differ only where a contour
//! self-intersects with opposite winding, which well-formed glyph outlines do
//! not do. The even-odd rule genuinely differs and is not available here; PDF
//! page content needs it, and that is the path pipeline's problem, not this
//! one's.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");
const Outline = @import("Outline.zig");

const Bounds = geom.Bounds;
const Point = geom.Point;
const Verb = geom.Verb;

/// How the font's em square lands on the pixel grid.
///
///     device.x =  font.x * scale + dx
///     device.y = -font.y * scale + dy
///
/// The y negation is the one coordinate flip in the font layer: outlines are
/// y-up with the origin on the baseline, pixels are y-down. `dy` is therefore
/// the baseline row, and a glyph's device bounds normally straddle zero with
/// the ascender negative.
pub const Placement = struct {
    scale: f32 = 1,
    dx: f32 = 0,
    dy: f32 = 0,
};

/// Flatness in device pixels: how far a chord may sag away from the curve it
/// replaces.
///
/// A fiftieth, not the tenth that looks like enough. Chords always cut
/// *inside* a convex arc, so the error does not cancel -- it is a systematic
/// loss of about two thirds of the sagitta along every curved edge, and a
/// tenth of a pixel costs a round glyph a quarter of a percent of its ink and
/// shaves the outside of every bowl. The circle test below measures exactly
/// that, and was what moved this number.
///
/// Segment count grows as the reciprocal square root, so a fifth of the
/// tolerance is 2.2 times the segments -- paid once per glyph per size per
/// subpixel bucket, and then cached for the life of the atlas.
pub const tolerance: f32 = 0.02;

/// The most line segments one curve is allowed to become. Reached only by a
/// curve spanning hundreds of pixels, which in a glyph means either a display
/// size or a corrupt outline; both are better served by a slightly coarse
/// approximation than by an unbounded loop.
pub const max_segments: u32 = 96;

pub const Error = Allocator.Error;

/// Scratch that outlives a single glyph.
///
/// A page of text is thousands of glyphs, and both buffers here are exactly
/// the kind that would otherwise be thousands of allocations. `Raster` is
/// stored on the atlas and reused for the life of the program.
pub const Raster = struct {
    /// The flattened outline, as device-space segments.
    lines: std.ArrayList([2]Point) = .empty,
    /// The area accumulator, `(width + 2) * height` floats. Two columns of
    /// slack rather than one because a segment ending exactly on the right
    /// edge writes one cell past its own ceiling.
    acc: std.ArrayList(f32) = .empty,

    pub fn deinit(r: *Raster, gpa: Allocator) void {
        r.lines.deinit(gpa);
        r.acc.deinit(gpa);
        r.* = .{};
    }

    /// Flattens `o` under `p` into `lines`, returning the exact device-space
    /// bounds of the result.
    ///
    /// Exact, meaning of the flattened segments rather than of the control
    /// points: `Outline.bounds` includes off-curve controls and so reports a
    /// box that can be a pixel or two too big in every direction. For a glyph
    /// atlas that is not a rounding error, it is wasted texels on every glyph
    /// and a visibly loose fit when a caller draws the cell.
    pub fn flatten(r: *Raster, gpa: Allocator, o: Outline, p: Placement) Error!Bounds {
        r.lines.clearRetainingCapacity();

        var b: Bounds = .empty;
        var start: Point = .origin;
        var cur: Point = .origin;
        var i: usize = 0;

        for (o.verbs.items) |verb| {
            switch (verb) {
                .move => {
                    // An unclosed contour is closed here rather than dropped.
                    // The accumulator needs closed loops -- an open one leaks
                    // winding across the whole row -- and a subsetted font
                    // with a missing `closepath` should draw, not smear.
                    if (!eq(cur, start)) try r.segment(gpa, cur, start);
                    cur = map(o.points.items[i], p);
                    start = cur;
                    b = b.add(cur);
                },
                .line => {
                    const to = map(o.points.items[i], p);
                    try r.segment(gpa, cur, to);
                    cur = to;
                    b = b.add(to);
                },
                .cubic => {
                    const c1 = map(o.points.items[i], p);
                    const c2 = map(o.points.items[i + 1], p);
                    const to = map(o.points.items[i + 2], p);
                    try r.cubic(gpa, cur, c1, c2, to, &b);
                    cur = to;
                },
                .close => {
                    if (!eq(cur, start)) try r.segment(gpa, cur, start);
                    cur = start;
                },
            }
            i += verb.pointCount();
        }
        if (!eq(cur, start)) try r.segment(gpa, cur, start);

        return b;
    }

    /// Rasterises what `flatten` left, translated so that `(ox, oy)` in device
    /// space lands at `dst[0]`.
    ///
    /// `dst` is 8-bit coverage, `stride` bytes per row, and is written in
    /// full: every pixel of the `width * height` window is assigned, so a
    /// caller packing into a shared atlas does not have to clear first.
    pub fn fill(
        r: *Raster,
        gpa: Allocator,
        dst: []u8,
        width: u32,
        height: u32,
        stride: u32,
        ox: f32,
        oy: f32,
    ) Error!void {
        if (width == 0 or height == 0) return;

        const w: usize = width;
        const h: usize = height;
        const cells = (w + 2) * h;
        if (r.acc.items.len < cells) try r.acc.resize(gpa, cells);
        const a = r.acc.items[0..cells];
        @memset(a, 0);

        for (r.lines.items) |seg| {
            drawLine(
                a,
                w,
                h,
                .{ .x = seg[0].x - ox, .y = seg[0].y - oy },
                .{ .x = seg[1].x - ox, .y = seg[1].y - oy },
            );
        }

        // The running sum turns per-cell deltas into winding, and the absolute
        // value turns winding into ink. Rows are independent, which is why the
        // accumulator never needed a sorted edge list in the first place.
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const src = a[y * (w + 2) ..][0 .. w + 2];
            const row = dst[y * stride ..][0..w];
            var sum: f32 = 0;
            for (row, src[0..w]) |*px, delta| {
                sum += delta;
                const c = @min(@abs(sum), 1.0) * 255.0;
                px.* = @intFromFloat(c + 0.5);
            }
        }
    }

    fn segment(r: *Raster, gpa: Allocator, from: Point, to: Point) Error!void {
        // Horizontal segments contribute no winding to any row and are the
        // commonest degenerate case in hinted outlines, so they are dropped
        // here rather than in the inner loop.
        if (from.y == to.y) return;
        try r.lines.append(gpa, .{ from, to });
    }

    fn cubic(r: *Raster, gpa: Allocator, p0: Point, c1: Point, c2: Point, p3: Point, b: *Bounds) Error!void {
        const n = subdivisions(p0, c1, c2, p3);
        var prev = p0;
        var k: u32 = 1;
        while (k <= n) : (k += 1) {
            const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
            const q = evalCubic(p0, c1, c2, p3, t);
            try r.segment(gpa, prev, q);
            b.* = b.add(q);
            prev = q;
        }
        // The bounds take the flattened vertices, so a curve that bulges
        // between samples is under-measured by at most `tolerance`. That is
        // the same tenth of a pixel the flattening already conceded.
        b.* = b.add(p0);
    }
};

fn map(p: Point, pl: Placement) Point {
    return .{ .x = p.x * pl.scale + pl.dx, .y = -p.y * pl.scale + pl.dy };
}

fn eq(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn evalCubic(p0: Point, c1: Point, c2: Point, p3: Point, t: f32) Point {
    const mt = 1 - t;
    const w0 = mt * mt * mt;
    const w1 = 3 * mt * mt * t;
    const w2 = 3 * mt * t * t;
    const w3 = t * t * t;
    return .{
        .x = w0 * p0.x + w1 * c1.x + w2 * c2.x + w3 * p3.x,
        .y = w0 * p0.y + w1 * c1.y + w2 * c2.y + w3 * p3.y,
    };
}

/// Segments needed to hold a cubic within `tolerance`.
///
/// The bound is the standard one: the deviation of a Bézier from its chord is
/// controlled by its second difference, and halving the parameter step
/// quarters that deviation, so `n` grows as the square root. Computed once per
/// curve from the two second differences rather than by recursive bisection,
/// which would allocate a stack and test flatness at every level to reach the
/// same answer.
fn subdivisions(p0: Point, c1: Point, c2: Point, p3: Point) u32 {
    const d1x = p0.x - 2 * c1.x + c2.x;
    const d1y = p0.y - 2 * c1.y + c2.y;
    const d2x = c1.x - 2 * c2.x + p3.x;
    const d2y = c1.y - 2 * c2.y + p3.y;
    const dev = @max(d1x * d1x + d1y * d1y, d2x * d2x + d2y * d2y);
    if (dev <= 0) return 1;
    const n = @ceil(@sqrt(@sqrt(dev) * (3.0 / (4.0 * tolerance))));
    if (!(n >= 1)) return 1; // NaN, from a coordinate that was already NaN.
    return @intFromFloat(@min(n, @as(f32, @floatFromInt(max_segments))));
}

/// Accumulates one segment's signed area into the cells it crosses.
///
/// Transliterated from `font-rs`, with two changes. Horizontal clipping is
/// added: `x` is clamped to `[0, w]`, which piles a segment running off the
/// left edge onto column zero -- which is exactly what clipping means to an
/// area accumulator, since the winding it carries still has to be counted for
/// every cell to its right. And the y range is clamped at both ends rather
/// than assuming the caller's box contains the outline, because it is reached
/// with coordinates derived from a font file.
fn drawLine(a: []f32, w: usize, h: usize, from: Point, to: Point) void {
    if (from.y == to.y) return;

    var dir: f32 = 1;
    var p0 = from;
    var p1 = to;
    if (p0.y > p1.y) {
        dir = -1;
        p0 = to;
        p1 = from;
    }

    const dxdy = (p1.x - p0.x) / (p1.y - p0.y);
    var x = p0.x;
    if (p0.y < 0) x -= p0.y * dxdy;

    const first = @max(@floor(p0.y), 0);
    const last = @min(@ceil(p1.y), @as(f32, @floatFromInt(h)));
    if (!(last > first)) return;

    const stride = w + 2;
    const wf: f32 = @floatFromInt(w);

    var y: usize = @intFromFloat(first);
    const y_end: usize = @intFromFloat(last);

    while (y < y_end) : (y += 1) {
        const yf: f32 = @floatFromInt(y);
        const line = y * stride;
        const dy = @min(yf + 1, p1.y) - @max(yf, p0.y);
        const xnext = x + dxdy * dy;
        const d = dy * dir;

        const x0 = std.math.clamp(@min(x, xnext), 0, wf);
        const x1 = std.math.clamp(@max(x, xnext), 0, wf);
        const x0floor = @floor(x0);
        const x0i: usize = @intFromFloat(x0floor);
        const x1ceil = @ceil(x1);
        const x1i: usize = @intFromFloat(x1ceil);

        if (x1i <= x0i + 1) {
            // The segment stays inside one column: split its area between
            // that column and the next by where its midpoint falls.
            const xmf = 0.5 * (x0 + x1) - x0floor;
            a[line + x0i] += d - d * xmf;
            a[line + x0i + 1] += d * xmf;
        } else {
            const s = 1.0 / (x1 - x0);
            const x0f = x0 - x0floor;
            const a0 = 0.5 * s * (1.0 - x0f) * (1.0 - x0f);
            const x1f = x1 - x1ceil + 1.0;
            const am = 0.5 * s * x1f * x1f;

            a[line + x0i] += d * a0;
            if (x1i == x0i + 2) {
                a[line + x0i + 1] += d * (1.0 - a0 - am);
            } else {
                const a1 = s * (1.5 - x0f);
                a[line + x0i + 1] += d * (a1 - a0);
                var xi = x0i + 2;
                while (xi < x1i - 1) : (xi += 1) a[line + xi] += d * s;
                const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                a[line + x1i - 1] += d * (1.0 - a2 - am);
            }
            a[line + x1i] += d * am;
        }

        x = xnext;
    }
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// Fills an outline into a freshly allocated tight buffer, the way the atlas
/// does, so the tests exercise the same path.
const Rendered = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    left: i32,
    top: i32,

    fn deinit(r: *Rendered, gpa: Allocator) void {
        gpa.free(r.pixels);
    }

    fn at(r: Rendered, x: u32, y: u32) u8 {
        return r.pixels[y * r.width + x];
    }

    fn total(r: Rendered) f64 {
        var sum: f64 = 0;
        for (r.pixels) |p| sum += @as(f64, @floatFromInt(p)) / 255.0;
        return sum;
    }
};

fn render(gpa: Allocator, o: Outline, p: Placement) !Rendered {
    var r: Raster = .{};
    defer r.deinit(gpa);

    const b = try r.flatten(gpa, o, p);
    if (b.isEmpty()) return .{ .pixels = &.{}, .width = 0, .height = 0, .left = 0, .top = 0 };

    const x0 = @floor(b.min_x);
    const y0 = @floor(b.min_y);
    const width: u32 = @intFromFloat(@max(@ceil(b.max_x) - x0, 0));
    const height: u32 = @intFromFloat(@max(@ceil(b.max_y) - y0, 0));

    const pixels = try gpa.alloc(u8, width * height);
    @memset(pixels, 0);
    try r.fill(gpa, pixels, width, height, width, x0, y0);

    return .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .left = @intFromFloat(x0),
        .top = @intFromFloat(-y0),
    };
}

fn rectOutline(gpa: Allocator, o: *Outline, x0: f32, y0: f32, x1: f32, y1: f32) !void {
    try o.moveTo(gpa, .{ .x = x0, .y = y0 });
    try o.lineTo(gpa, .{ .x = x1, .y = y0 });
    try o.lineTo(gpa, .{ .x = x1, .y = y1 });
    try o.lineTo(gpa, .{ .x = x0, .y = y1 });
    try o.close(gpa);
}

test "an axis-aligned box on the pixel grid is solid and exact" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);
    try rectOutline(gpa, &o, 0, 0, 4, 3);

    var img = try render(gpa, o, .{ .scale = 1 });
    defer img.deinit(gpa);

    try testing.expectEqual(@as(u32, 4), img.width);
    try testing.expectEqual(@as(u32, 3), img.height);
    for (img.pixels) |p| try testing.expectEqual(@as(u8, 255), p);
    // The box sits above the baseline, so its top edge is 3 pixels up and its
    // left edge is at the pen.
    try testing.expectEqual(@as(i32, 0), img.left);
    try testing.expectEqual(@as(i32, 3), img.top);
}

test "a half-covered column is half covered, not rounded to a pixel" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);
    // Two pixels wide and a half deep into the third.
    try rectOutline(gpa, &o, 0, 0, 2.5, 1);

    var img = try render(gpa, o, .{ .scale = 1 });
    defer img.deinit(gpa);

    try testing.expectEqual(@as(u32, 3), img.width);
    try testing.expectEqual(@as(u8, 255), img.at(0, 0));
    try testing.expectEqual(@as(u8, 255), img.at(1, 0));
    // This is the whole reason for an area accumulator: 128, not 0 and not 255.
    try testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(img.at(2, 0))), 1.5);
}

test "winding direction does not change the ink" {
    const gpa = testing.allocator;

    var ccw: Outline = .{};
    defer ccw.deinit(gpa);
    try rectOutline(gpa, &ccw, 0, 0, 5, 5);

    var cw: Outline = .{};
    defer cw.deinit(gpa);
    try cw.moveTo(gpa, .{ .x = 0, .y = 0 });
    try cw.lineTo(gpa, .{ .x = 0, .y = 5 });
    try cw.lineTo(gpa, .{ .x = 5, .y = 5 });
    try cw.lineTo(gpa, .{ .x = 5, .y = 0 });
    try cw.close(gpa);

    var a = try render(gpa, ccw, .{ .scale = 1 });
    defer a.deinit(gpa);
    var b = try render(gpa, cw, .{ .scale = 1 });
    defer b.deinit(gpa);

    try testing.expectEqualSlices(u8, a.pixels, b.pixels);
}

test "a counter-wound inner contour leaves a hole" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);

    // Outer counter-clockwise, inner clockwise: the `.notdef` box's shape.
    try rectOutline(gpa, &o, 0, 0, 10, 10);
    try o.moveTo(gpa, .{ .x = 3, .y = 3 });
    try o.lineTo(gpa, .{ .x = 3, .y = 7 });
    try o.lineTo(gpa, .{ .x = 7, .y = 7 });
    try o.lineTo(gpa, .{ .x = 7, .y = 3 });
    try o.close(gpa);

    var img = try render(gpa, o, .{ .scale = 1 });
    defer img.deinit(gpa);

    try testing.expectEqual(@as(u8, 255), img.at(1, 1)); // the frame
    try testing.expectEqual(@as(u8, 0), img.at(5, 5)); // the hole
    // 100 minus the 16 removed.
    try testing.expectApproxEqAbs(@as(f64, 84), img.total(), 0.01);
}

test "coverage integrates to the area, whatever the subpixel offset" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);
    try rectOutline(gpa, &o, 0, 0, 7, 5);

    // The property the whole subpixel-positioning scheme rests on: shifting a
    // shape by a fraction of a pixel redistributes ink without creating or
    // destroying any. A rasteriser that snapped to the grid would still pass
    // the aligned case above and fail here.
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const dx = @as(f32, @floatFromInt(i)) / 8.0;
        var img = try render(gpa, o, .{ .scale = 1, .dx = dx });
        defer img.deinit(gpa);
        // Not exact: the result is eight-bit, so every partially covered pixel
        // rounds by up to half a level, and a shifted rectangle has about
        // forty of them. That is the whole error budget here.
        try testing.expectApproxEqAbs(@as(f64, 35), img.total(), 0.1);
    }
}

test "a circle's coverage is pi r squared" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);

    // Four cubics, with the usual 4/3 (sqrt 2 - 1) control offset.
    const r: f32 = 40;
    const k: f32 = r * 0.5522847498;
    try o.moveTo(gpa, .{ .x = r, .y = 0 });
    try o.cubicTo(gpa, .{ .x = r, .y = k }, .{ .x = k, .y = r }, .{ .x = 0, .y = r });
    try o.cubicTo(gpa, .{ .x = -k, .y = r }, .{ .x = -r, .y = k }, .{ .x = -r, .y = 0 });
    try o.cubicTo(gpa, .{ .x = -r, .y = -k }, .{ .x = -k, .y = -r }, .{ .x = 0, .y = -r });
    try o.cubicTo(gpa, .{ .x = k, .y = -r }, .{ .x = r, .y = -k }, .{ .x = r, .y = 0 });
    try o.close(gpa);

    var img = try render(gpa, o, .{ .scale = 1 });
    defer img.deinit(gpa);

    // Within a tenth of a percent: the flattening tolerance and the Bézier's
    // own departure from a true circle are both well inside that.
    const expected = std.math.pi * r * r;
    try testing.expectApproxEqRel(@as(f64, expected), img.total(), 1e-3);
    try testing.expectEqual(@as(u32, 80), img.width);
    try testing.expectEqual(@as(u32, 80), img.height);
}

test "an unclosed contour is closed rather than smeared" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);

    // Three sides of a square, no `close`. An area accumulator handed an open
    // loop leaks winding to the right edge of the row, so the failure mode is
    // a bright bar across the glyph rather than a missing line.
    try o.moveTo(gpa, .{ .x = 0, .y = 0 });
    try o.lineTo(gpa, .{ .x = 6, .y = 0 });
    try o.lineTo(gpa, .{ .x = 6, .y = 6 });
    try o.lineTo(gpa, .{ .x = 0, .y = 6 });

    var img = try render(gpa, o, .{ .scale = 1 });
    defer img.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 36), img.total(), 0.01);
}

test "scaling down keeps the proportion of ink" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);
    try rectOutline(gpa, &o, 0, 0, 1000, 1000);

    // A thousand-unit em at sixteen pixels.
    var img = try render(gpa, o, .{ .scale = 16.0 / 1000.0 });
    defer img.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 256), img.total(), 0.01);
}

test "an empty outline renders nothing rather than trapping" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);

    var img = try render(gpa, o, .{ .scale = 1 });
    defer img.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), img.width);
}

test "a degenerate scale does not write outside the buffer" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);
    try rectOutline(gpa, &o, -1000, -1000, 1000, 1000);

    // Deliberately mismatched: a two-pixel window over a shape that reaches
    // far outside it in every direction. The clamping in `drawLine` is what
    // keeps this in bounds, and a debug build traps if it does not.
    var r: Raster = .{};
    defer r.deinit(gpa);
    _ = try r.flatten(gpa, o, .{ .scale = 1 });

    var buf: [4]u8 = undefined;
    try r.fill(gpa, &buf, 2, 2, 2, 0, 0);
    for (buf) |p| try testing.expectEqual(@as(u8, 255), p);
}
