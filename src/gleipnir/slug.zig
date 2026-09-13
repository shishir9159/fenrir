//! Analytic path coverage, in the shape Slug put it in: the outline itself
//! goes to the GPU and the fragment shader works out how much of each pixel
//! the path covers, from the curves, exactly.
//!
//! This is the other way of filling a path, and it is not a faster
//! stencil-and-cover. It is a different answer to a different question.
//!
//! ## What it computes
//!
//! Take one horizontal line across a pixel, at height `y`. Every place the
//! outline crosses that line, it either enters the shape or leaves it. Sort
//! the crossings and you know exactly which parts of that line are inside:
//!
//!     F(y) = Σ  ±clamp((x_cross − x_pixel)·scale + ½, 0, 1)
//!
//! Each term is the fraction of the pixel's width lying to one side of a
//! crossing, and with the signs (up adds, down subtracts) the sum is the
//! **exact covered length of that line**, for any outline, at any resolution.
//! No sampling, no quantisation, no square root.
//!
//! The pixel's coverage is that length integrated down the pixel's height:
//!
//!     coverage = ∫ F(y) dy
//!
//! and *that* is the only part that is approximated. `rays` sub-rows evaluate
//! the integral by the midpoint rule.
//!
//! ## Why that is the right place for the error
//!
//! Multisampling quantises both axes: eight samples give a pixel nine
//! possible coverages, whichever way the edge runs. This quantises only the
//! vertical one. A vertical edge -- a stem, the side of a rule, the straight
//! part of almost every letter at a reading size -- lands on its exact
//! coverage with `rays = 1`, because it is the x integral that is closed
//! form. A horizontal edge is the bad case and gets `rays + 1` levels.
//!
//! Text is mostly vertical edges, so four rays here beat eight samples there,
//! on the axis that matters, for half the work. And the whole thing is
//! resolution independent: the same buffers draw the page at any zoom, which
//! is the property a reader actually wants.
//!
//! ## What it costs, and bands
//!
//! Every curve crossing the pixel's row has to be tested, and testing every
//! curve in the path per fragment is quadratic nonsense on anything bigger
//! than a glyph. So the path's bounding box is cut into horizontal **bands**,
//! each holding the curves that reach into it, and a fragment tests one
//! band's worth. `Store` builds them; `bandCount` picks how many.
//!
//! ## The two rules
//!
//! `F` is a winding number weighted by coverage, so the fill rule is applied
//! to it at the end: nonzero clamps the magnitude to one, even-odd folds it
//! into a triangle wave. Both are exact wherever a pixel is not straddling
//! the point at which two contours cross each other -- where the ramp method
//! double-counts by up to the area of the overlap inside that one pixel. It
//! is the same approximation Slug makes, it is bounded by a pixel, and it is
//! invisible on glyphs, which do not self-intersect at all.
//!
//! ## Where the copies of this live
//!
//! Three, and they are meant to be read against each other:
//!
//! * `coverageAt` here is the readable one, and the one the tests check.
//! * `windingTable` here is the branchless one, written the way a shader has
//!   to be written. A test asserts the two agree on random curves, which is
//!   what makes it safe to trust the third.
//! * `shader/slug.glsl` is `windingTable` transcribed into GLSL.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");
const DisplayList = @import("../gelgja/DisplayList.zig");

const Bounds = geom.Bounds;
const FillRule = geom.FillRule;
const Point = geom.Point;
const Transform = geom.Transform;
const Verb = geom.Verb;

/// A quadratic Bézier, in the path's own space.
///
/// Quadratic and not cubic because the crossing test is then a quadratic
/// equation -- two roots, one square root, no iteration. A cubic would need a
/// cubic solve per curve per fragment, which is the cost the whole design
/// exists to avoid. `addCubic` does the conversion once, on the way in.
pub const Curve = extern struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub fn at(c: Curve, t: f32) Point {
        const u = 1 - t;
        return .{
            .x = u * u * c.x0 + 2 * u * t * c.x1 + t * t * c.x2,
            .y = u * u * c.y0 + 2 * u * t * c.y1 + t * t * c.y2,
        };
    }

    pub fn bounds(c: Curve) Bounds {
        // The control point is outside the curve but the hull contains it, and
        // a hull box costs three comparisons instead of a derivative solve.
        // Bands only need a conservative box.
        return .{
            .min_x = @min(c.x0, @min(c.x1, c.x2)),
            .min_y = @min(c.y0, @min(c.y1, c.y2)),
            .max_x = @max(c.x0, @max(c.x1, c.x2)),
            .max_y = @max(c.y0, @max(c.y1, c.y2)),
        };
    }
};

/// A slice of `Store.indices`: the curves that reach into one band.
pub const Band = extern struct {
    first: u32 = 0,
    count: u32 = 0,
};

/// Everything the shader needs to know about one path, and nothing about
/// where it is drawn -- that is the instance's business, which is what lets
/// one uploaded path be drawn at several transforms.
pub const Header = extern struct {
    min_x: f32 = 0,
    min_y: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,
    curve_first: u32 = 0,
    curve_count: u32 = 0,
    /// Bands across y, for the horizontal rays.
    row_first: u32 = 0,
    row_count: u32 = 0,
    /// `0` nonzero, `1` even-odd. A `u32` because GLSL has no enums and the
    /// std430 layout has to be written out in full anyway.
    rule: u32 = 0,
    _pad: u32 = 0,

    pub fn bounds(h: Header) Bounds {
        return .{ .min_x = h.min_x, .min_y = h.min_y, .max_x = h.max_x, .max_y = h.max_y };
    }
};

comptime {
    std.debug.assert(@sizeOf(Curve) == 24);
    std.debug.assert(@sizeOf(Band) == 8);
    std.debug.assert(@sizeOf(Header) == 40);
}

/// How close a quadratic has to stay to the cubic it replaces, in path units.
///
/// Small, and it can afford to be: splitting a cubic in half cuts the error
/// by eight, so the segment count grows as the cube root of the precision
/// asked for. A tenth of a point is a hundredth of a pixel at a reading zoom
/// and costs perhaps two segments where one would have done.
pub const default_tolerance: f32 = 0.02;

/// Sub-rows per pixel: how finely `∫ F(y) dy` is sampled.
///
/// Four is the default. It is the only quantisation in the method and it
/// applies to horizontal edges alone, so it buys more than the same number of
/// multisamples would.
pub const default_rays: u32 = 4;

/// The buffers the shader reads, built on the CPU.
///
/// Four flat arrays and no pointers, because the whole thing is memcpy'd into
/// storage buffers. `headers[i]` names spans of the other three.
pub const Store = struct {
    curves: std.ArrayList(Curve) = .empty,
    bands: std.ArrayList(Band) = .empty,
    indices: std.ArrayList(u32) = .empty,
    headers: std.ArrayList(Header) = .empty,

    pub fn deinit(s: *Store, gpa: Allocator) void {
        s.curves.deinit(gpa);
        s.bands.deinit(gpa);
        s.indices.deinit(gpa);
        s.headers.deinit(gpa);
        s.* = .{};
    }

    pub fn reset(s: *Store) void {
        s.curves.clearRetainingCapacity();
        s.bands.clearRetainingCapacity();
        s.indices.clearRetainingCapacity();
        s.headers.clearRetainingCapacity();
    }

    /// Bytes to upload, in the order the descriptor set binds them.
    pub fn curveBytes(s: Store) []const u8 {
        return std.mem.sliceAsBytes(s.curves.items);
    }

    pub fn bandBytes(s: Store) []const u8 {
        return std.mem.sliceAsBytes(s.bands.items);
    }

    pub fn indexBytes(s: Store) []const u8 {
        return std.mem.sliceAsBytes(s.indices.items);
    }

    pub fn headerBytes(s: Store) []const u8 {
        return std.mem.sliceAsBytes(s.headers.items);
    }

    /// Appends another store's contents, renumbering every index in it.
    ///
    /// Returns how much to add to a header index from `src` to find the same
    /// header here, which is what lets a scene recorded on its own -- on
    /// another thread, at another time -- be merged into a shared one without
    /// re-extracting a single curve.
    ///
    /// Three levels of renumbering, and missing any of them draws a page made
    /// of the wrong shapes: a header's `curve_first` and `row_first` move by
    /// this store's curve and band counts, and a band's `first` moves by its
    /// index count.
    pub fn merge(s: *Store, gpa: Allocator, src: Store) Allocator.Error!u32 {
        const curve_base: u32 = @intCast(s.curves.items.len);
        const band_base: u32 = @intCast(s.bands.items.len);
        const index_base: u32 = @intCast(s.indices.items.len);
        const header_base: u32 = @intCast(s.headers.items.len);

        try s.curves.appendSlice(gpa, src.curves.items);

        try s.bands.ensureUnusedCapacity(gpa, src.bands.items.len);
        for (src.bands.items) |b| {
            s.bands.appendAssumeCapacity(.{ .first = b.first + index_base, .count = b.count });
        }

        try s.indices.ensureUnusedCapacity(gpa, src.indices.items.len);
        for (src.indices.items) |i| s.indices.appendAssumeCapacity(i + curve_base);

        try s.headers.ensureUnusedCapacity(gpa, src.headers.items.len);
        for (src.headers.items) |h| {
            var out = h;
            out.curve_first += curve_base;
            out.row_first += band_base;
            s.headers.appendAssumeCapacity(out);
        }
        return header_base;
    }

    /// Adds a path's curves and builds its bands. Returns its header index,
    /// which is what an instance refers to it by.
    ///
    /// `curves` is consumed rather than copied where it can be: they are
    /// appended to the store's own array, which is where the shader reads
    /// them from.
    pub fn add(
        s: *Store,
        gpa: Allocator,
        curves: []const Curve,
        rule: FillRule,
    ) Allocator.Error!u32 {
        const first: u32 = @intCast(s.curves.items.len);
        try s.curves.appendSlice(gpa, curves);

        var box: Bounds = .empty;
        for (curves) |c| box = box.unionWith(c.bounds());

        var header: Header = .{
            .min_x = box.min_x,
            .min_y = box.min_y,
            .max_x = box.max_x,
            .max_y = box.max_y,
            .curve_first = first,
            .curve_count = @intCast(curves.len),
            .rule = switch (rule) {
                .nonzero => 0,
                .even_odd => 1,
            },
        };

        if (curves.len != 0 and !box.isEmpty()) {
            const rows = bandCount(curves.len);
            header.row_first = @intCast(s.bands.items.len);
            header.row_count = rows;
            try s.buildBands(gpa, curves, first, box, rows);
        }

        const id: u32 = @intCast(s.headers.items.len);
        try s.headers.append(gpa, header);
        return id;
    }

    /// Sorts the curves into rows, as a counted-then-filled index array.
    ///
    /// Two passes rather than a list per band: the answer is one allocation
    /// of exactly the right size, which matters because this runs once per
    /// path on a page that has thousands of them.
    fn buildBands(
        s: *Store,
        gpa: Allocator,
        curves: []const Curve,
        curve_first: u32,
        box: Bounds,
        rows: u32,
    ) Allocator.Error!void {
        const band_first = s.bands.items.len;
        try s.bands.appendNTimes(gpa, .{}, rows);
        const height = @max(box.max_y - box.min_y, std.math.floatEps(f32));
        const per = @as(f32, @floatFromInt(rows)) / height;

        // Pass one: how many curves reach into each row.
        for (curves) |c| {
            const cb = c.bounds();
            const lo, const hi = rowSpan(cb.min_y, cb.max_y, box.min_y, per, rows);
            var r = lo;
            while (r <= hi) : (r += 1) s.bands.items[band_first + r].count += 1;
        }

        // Running offsets, so each row knows where its indices start.
        var total: u32 = @intCast(s.indices.items.len);
        for (s.bands.items[band_first..]) |*b| {
            b.first = total;
            total += b.count;
            // Reused below as a write cursor, and restored after.
            b.count = 0;
        }
        try s.indices.resize(gpa, total);

        // Pass two: fill them in.
        for (curves, 0..) |c, i| {
            const cb = c.bounds();
            const lo, const hi = rowSpan(cb.min_y, cb.max_y, box.min_y, per, rows);
            var r = lo;
            while (r <= hi) : (r += 1) {
                const b = &s.bands.items[band_first + r];
                s.indices.items[b.first + b.count] = curve_first + @as(u32, @intCast(i));
                b.count += 1;
            }
        }
    }
};

/// The rows a curve's y-range touches, clamped into range.
fn rowSpan(min_y: f32, max_y: f32, origin: f32, per: f32, rows: u32) struct { u32, u32 } {
    const last = rows - 1;
    const a = (min_y - origin) * per;
    const b = (max_y - origin) * per;
    const lo: u32 = if (a <= 0) 0 else @min(last, @as(u32, @intFromFloat(a)));
    const hi: u32 = if (b <= 0) 0 else @min(last, @as(u32, @intFromFloat(b)));
    return .{ lo, @max(lo, hi) };
}

/// How many bands a path with this many curves gets.
///
/// The cost per fragment is the curves in one band, roughly `n/bands`, and
/// the memory is roughly `n` indices plus the bands themselves. Balancing the
/// two puts the band count near the square root, which for a glyph of forty
/// curves is nine bands of four or five -- and for a path of one curve is one
/// band, with no arithmetic wasted on it.
pub fn bandCount(curves: usize) u32 {
    if (curves <= 2) return 1;
    const n: u32 = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(curves)) * 2.0)));
    return std.math.clamp(n, 1, max_bands);
}

/// A ceiling on bands per path. A path with more curves than this squared
/// just gets fuller bands; the alternative is a store whose band array is
/// larger than its curve array.
pub const max_bands: u32 = 64;

// -- turning a path into curves ----------------------------------------------

/// Collects the quadratics of a display-list path, through a transform.
///
/// Closes every open subpath, because coverage is only defined for a closed
/// outline: an unclosed contour would leave a crossing unpaired and every
/// pixel to one side of it would be filled.
pub fn fromPath(
    gpa: Allocator,
    out: *std.ArrayList(Curve),
    list: DisplayList,
    p: DisplayList.Path,
    xform: Transform,
    tolerance: f32,
) Allocator.Error!void {
    const verbs = list.verbsOf(p);
    const points = list.pointsOf(p);

    var start: Point = .origin;
    var cur: Point = .origin;
    var open = false;
    var i: usize = 0;

    for (verbs) |verb| {
        const n = verb.pointCount();
        if (i + n > points.len) break;
        switch (verb) {
            .move => {
                if (open) try lineOf(gpa, out, cur, start);
                start = xform.apply(points[i]);
                cur = start;
                open = true;
            },
            .line => {
                const to = xform.apply(points[i]);
                try lineOf(gpa, out, cur, to);
                cur = to;
            },
            .cubic => {
                const c1 = xform.apply(points[i]);
                const c2 = xform.apply(points[i + 1]);
                const to = xform.apply(points[i + 2]);
                try addCubic(gpa, out, cur, c1, c2, to, tolerance, 16);
                cur = to;
            },
            .close => {
                try lineOf(gpa, out, cur, start);
                cur = start;
                open = false;
            },
        }
        i += n;
    }
    if (open) try lineOf(gpa, out, cur, start);
}

/// Collects the quadratics of an already-flattened path.
///
/// Every segment becomes a degenerate quadratic. That throws away the
/// resolution independence for anything that arrives this way -- a stroke's
/// generated outline, and a glyph, both of which are flattened by the layer
/// that produces them -- but it is what makes the analytic fill usable for
/// everything on the page today rather than for path fills alone.
///
/// `fromPath` is the one that keeps curves as curves, and it is the one a
/// `fill_path` command goes through.
pub fn fromFlattened(
    gpa: Allocator,
    out: *std.ArrayList(Curve),
    f: @import("path.zig").Flattened,
) Allocator.Error!void {
    for (f.subpaths) |sub| {
        const pts = sub.slice(f.points);
        if (pts.len < 2) continue;
        for (pts[1..], pts[0 .. pts.len - 1]) |b, a| {
            try lineOf(gpa, out, a.point(), b.point());
        }
        // The flattener leaves a subpath open unless it was closed; coverage
        // needs it shut either way, or the winding never comes back to zero.
        try lineOf(gpa, out, pts[pts.len - 1].point(), pts[0].point());
    }
}

/// A line as a quadratic, with the control point in the middle. Degenerate on
/// purpose: one curve type through the shader means one code path, and the
/// root solve handles `a == 0` anyway because a great many real curves are
/// straight in y.
fn lineOf(gpa: Allocator, out: *std.ArrayList(Curve), from: Point, to: Point) Allocator.Error!void {
    if (from.x == to.x and from.y == to.y) return;
    try out.append(gpa, .{
        .x0 = from.x,
        .y0 = from.y,
        .x1 = (from.x + to.x) * 0.5,
        .y1 = (from.y + to.y) * 0.5,
        .x2 = to.x,
        .y2 = to.y,
    });
}

/// Appends the quadratics that approximate a cubic to within `tolerance`.
///
/// The quadratic that stands in for a cubic is the one through both ends
/// whose control point is where the end tangents meet, `(3c₁ + 3c₂ − p₀ −
/// p₃)/4`. Its greatest distance from the cubic is bounded by
/// `√3/36 · |p₃ − 3c₂ + 3c₁ − p₀|`, and halving the cubic divides that bound
/// by eight -- so this recursion terminates fast and `max_depth` is a guard
/// against denormals rather than a real limit.
pub fn addCubic(
    gpa: Allocator,
    out: *std.ArrayList(Curve),
    p0: Point,
    c1: Point,
    c2: Point,
    p3: Point,
    tolerance: f32,
    depth: u8,
) Allocator.Error!void {
    const vx = p3.x - 3 * c2.x + 3 * c1.x - p0.x;
    const vy = p3.y - 3 * c2.y + 3 * c1.y - p0.y;
    const err = 0.0481125224 * @sqrt(vx * vx + vy * vy); // √3/36

    if (depth == 0 or err <= tolerance) {
        try out.append(gpa, .{
            .x0 = p0.x,
            .y0 = p0.y,
            .x1 = (3 * c1.x + 3 * c2.x - p0.x - p3.x) * 0.25,
            .y1 = (3 * c1.y + 3 * c2.y - p0.y - p3.y) * 0.25,
            .x2 = p3.x,
            .y2 = p3.y,
        });
        return;
    }

    // de Casteljau at t = ½.
    const a: Point = .{ .x = (p0.x + c1.x) * 0.5, .y = (p0.y + c1.y) * 0.5 };
    const b: Point = .{ .x = (c1.x + c2.x) * 0.5, .y = (c1.y + c2.y) * 0.5 };
    const c: Point = .{ .x = (c2.x + p3.x) * 0.5, .y = (c2.y + p3.y) * 0.5 };
    const d: Point = .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
    const e: Point = .{ .x = (b.x + c.x) * 0.5, .y = (b.y + c.y) * 0.5 };
    const m: Point = .{ .x = (d.x + e.x) * 0.5, .y = (d.y + e.y) * 0.5 };

    try addCubic(gpa, out, p0, a, d, m, tolerance, depth - 1);
    try addCubic(gpa, out, m, e, c, p3, tolerance, depth - 1);
}

// -- the coverage itself -----------------------------------------------------

/// How the sample point relates to the pixel grid: one pixel is `1/scale`
/// path units across, in each direction separately.
///
/// Two numbers and not a matrix because the ray is cast in path space, where
/// the bands are. For a page transform -- a scale, possibly with a quarter
/// turn -- these are exact. Under a rotation or a skew they are the lengths
/// of the transform's columns, which is the right answer to first order and
/// wrong only in how wide the antialiased band along an edge is.
pub const Scale = struct {
    x: f32,
    y: f32,

    /// The device pixels one path unit spans, in each axis.
    pub fn of(xform: Transform) Scale {
        return .{
            .x = @sqrt(xform.a * xform.a + xform.b * xform.b),
            .y = @sqrt(xform.c * xform.c + xform.d * xform.d),
        };
    }
};

/// The fraction of the pixel at `(x, y)` that the path covers.
///
/// This is the model of the fragment shader, and the only part of it that is
/// approximate is `rays`: the pixel's height is split into that many rows,
/// each row's covered length is computed exactly, and the results averaged.
pub fn coverageAt(
    s: Store,
    header: u32,
    x: f32,
    y: f32,
    scale: Scale,
    rays: u32,
) f32 {
    if (header >= s.headers.items.len) return 0;
    const h = s.headers.items[header];
    if (h.curve_count == 0 or h.row_count == 0) return 0;

    // A pixel's worth of path space, and the half of it above and below the
    // sample point.
    const pixel_h = if (scale.y > 0) 1.0 / scale.y else 0;
    const n = @max(1, rays);
    const step = pixel_h / @as(f32, @floatFromInt(n));
    const top = y - pixel_h * 0.5 + step * 0.5;

    // Outside the path's box by more than the pixel is outside the path.
    if (x + 0.5 / @max(scale.x, std.math.floatEps(f32)) < h.min_x) return 0;
    if (y + pixel_h * 0.5 < h.min_y or y - pixel_h * 0.5 > h.max_y) return 0;

    var total: f32 = 0;
    var j: u32 = 0;
    while (j < n) : (j += 1) {
        const ray_y = top + step * @as(f32, @floatFromInt(j));
        total += applyRule(windingAlongRow(s, h, x, ray_y, scale.x), h.rule);
    }
    return std.math.clamp(total / @as(f32, @floatFromInt(n)), 0, 1);
}

/// `F(y)`: the covered length of one row of the pixel, in pixel widths.
///
/// Only the curves in the band containing `y` are tested, which is the whole
/// reason the bands exist.
pub fn windingAlongRow(s: Store, h: Header, x: f32, y: f32, scale_x: f32) f32 {
    const row = rowOf(h, y);
    if (row >= h.row_count) return 0;
    const band = s.bands.items[h.row_first + row];

    var sum: f32 = 0;
    var k: u32 = 0;
    while (k < band.count) : (k += 1) {
        const curve = s.curves.items[s.indices.items[band.first + k]];
        sum += crossings(curve, x, y, scale_x);
    }
    return sum;
}

/// Which band a y lands in.
fn rowOf(h: Header, y: f32) u32 {
    const height = h.max_y - h.min_y;
    if (!(height > 0) or h.row_count == 0) return 0;
    const t = (y - h.min_y) / height * @as(f32, @floatFromInt(h.row_count));
    if (t <= 0) return 0;
    const i: u32 = @intFromFloat(t);
    return @min(i, h.row_count - 1);
}

/// One curve's contribution to `F(y)`: the readable version.
///
/// Finds where the curve crosses the ray, and for each crossing adds the
/// fraction of the pixel's width lying to the left of it -- positive where
/// the outline is going up, negative where it is going down, because that is
/// what makes the sum a winding number rather than a count.
pub fn crossings(c: Curve, x: f32, y: f32, scale_x: f32) f32 {
    // Relative to the sample: the ray is then the positive x axis.
    const y0 = c.y0 - y;
    const y1 = c.y1 - y;
    const y2 = c.y2 - y;

    // B(t) = a·t² − 2b·t + c, from the Bernstein form.
    const a = y0 - 2 * y1 + y2;
    const b = y0 - y1;
    const disc = b * b - a * y0;
    if (disc < 0) return 0;

    const lo, const hi = roots(a, b, y0, disc);

    var sum: f32 = 0;
    for ([2]f32{ lo, hi }) |tt| {
        // Half-open, so a crossing shared by two curves at their joint is
        // counted once rather than twice or not at all.
        if (!(tt >= 0) or tt >= 1) continue;
        // dy/dt at the crossing decides the direction. Up adds, down
        // subtracts: see the derivation in the module comment.
        const dy = 2 * ((y1 - y0) + tt * (y0 - 2 * y1 + y2));
        if (dy == 0) continue;
        const cx = xAt(c, tt) - x;
        const ramp = std.math.clamp(cx * scale_x + 0.5, 0, 1);
        sum += if (dy > 0) ramp else -ramp;
    }
    return sum;
}

fn xAt(c: Curve, t: f32) f32 {
    const u = 1 - t;
    return u * u * c.x0 + 2 * u * t * c.x1 + t * t * c.x2;
}

/// Both roots of `a·t² − 2b·t + c = 0`, as `(b − √d)/a` and `(b + √d)/a`,
/// computed so that neither is destroyed by cancellation.
///
/// The textbook formula has two failure modes and a path fill walks into
/// both. When `a` is near zero -- which is every straight segment, and every
/// curve whose ends and control point happen to line up in y, so most of a
/// page -- dividing by it turns a root that should be at infinity into a
/// large finite number and, worse, turns the other one into `0/0`. A line
/// that never meets the ray then reports a crossing at `t = 0` and half the
/// page fills in.
///
/// Testing `|a| < ε` instead only moves the problem: the right ε depends on
/// the size of the numbers, and a page in points and a glyph in em units are
/// three orders of magnitude apart. The stable form has no ε at all. Take
/// `s = b ± √d` with the sign that makes the two terms add rather than
/// cancel; then `s/a` is the root of larger magnitude and `c/s` is the other,
/// by Vieta. As `a → 0`, `s → 2b` and `c/s → c/2b`, which is exactly the root
/// of the linear equation that is left -- no special case, no branch.
fn roots(a: f32, b: f32, c: f32, disc: f32) struct { f32, f32 } {
    const root = @sqrt(disc);
    // `s` takes the sign of `b` so that `b` and `±√d` reinforce.
    const s = if (b >= 0) b + root else b - root;
    if (s == 0) {
        // `b` and the discriminant are both zero: the curve is constant in y
        // at this ray, so it crosses nowhere. Returning roots outside [0, 1)
        // is how that is said in a form the caller already handles.
        return .{ 2, 2 };
    }
    const far = s / a; // ±inf when a is zero, which is correct
    const near = c / s;
    // `(b − √d)/a` first, `(b + √d)/a` second, whichever of the two each is.
    return if (b >= 0) .{ near, far } else .{ far, near };
}

/// The same contribution, written the way the shader writes it.
///
/// No loop, no root-range test, no derivative: which of the two roots to use
/// and with what sign falls out of the signs of the three y values, through
/// `root_table`. That is worth having because a fragment shader runs this
/// tens of times per pixel and every branch in it is a branch the whole warp
/// takes.
///
/// `crossings` is the specification; this is the implementation; the test
/// "the branchless crossing test agrees with the readable one" is the bridge.
pub fn crossingsTable(c: Curve, x: f32, y: f32, scale_x: f32) f32 {
    const y0 = c.y0 - y;
    const y1 = c.y1 - y;
    const y2 = c.y2 - y;

    const shift: u4 = @intCast((@as(u32, @intFromBool(y0 > 0)) << 1) |
        (@as(u32, @intFromBool(y1 > 0)) << 2) |
        (@as(u32, @intFromBool(y2 > 0)) << 3));
    const code = (root_table >> shift) & 3;
    if (code == 0) return 0;

    const a = y0 - 2 * y1 + y2;
    const b = y0 - y1;

    // The table is an upper bound on the crossings, not the count of them.
    // Its `3` cases say "the control point is on the far side of the ray from
    // both ends", and a quadratic does not pass through its control point --
    // it may bend towards the ray and turn back without ever reaching it. The
    // discriminant is what knows the difference, so it is tested and not
    // merely clamped. Clamping a negative one to zero invents a pair of
    // crossings at the parabola's vertex, and a page drawn that way grows a
    // faint wrong-coloured smear wherever a curve comes close to a scanline.
    const disc = b * b - a * y0;
    if (disc < 0) return 0;

    const t0, const t1 = roots(a, b, y0, disc);

    // No range test on `t`: the table is what decides which root is in
    // `[0, 1)`, which is the whole point of it. The sign is the other half --
    // the lower root of a crossing pair leaves the shape and the upper one
    // enters it, in the orientation `crossings` derives from the tangent.
    var sum: f32 = 0;
    if (code & 1 != 0) sum -= std.math.clamp((xAt(c, t0) - x) * scale_x + 0.5, 0, 1);
    if (code & 2 != 0) sum += std.math.clamp((xAt(c, t1) - x) * scale_x + 0.5, 0, 1);
    return sum;
}

/// Which roots of `B(t) = 0` lie in `[0, 1)`, and with which sign, for each
/// of the eight sign patterns of `(y₀, y₁, y₂)`.
///
/// Two bits per pattern, indexed by `2·[y₀>0] + 4·[y₁>0] + 8·[y₂>0]`: bit 0
/// means the lower root crosses downward, bit 1 means the upper root crosses
/// upward. The shift is by twos so the index can be built with shifts instead
/// of a multiply.
///
/// Reading it out: `0` for all-below and all-above, because a curve entirely
/// on one side of the ray never meets it; `3` where the middle point is on
/// the other side from both ends, because the curve crosses and comes back.
pub const root_table: u16 = 0x2E74;

/// Turns a coverage-weighted winding number into a coverage.
///
/// Nonzero keeps the magnitude and stops at one, which is also what makes an
/// overlapping stroke outline -- where the winding is two or three deep --
/// come out solid instead of over-bright. Even-odd folds it into a triangle
/// wave, so winding two is empty again.
pub fn applyRule(winding: f32, rule: u32) f32 {
    const w = @abs(winding);
    if (rule == 0) return @min(w, 1);
    const m = @mod(w, 2);
    return if (m <= 1) m else 2 - m;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn square(gpa: Allocator, out: *std.ArrayList(Curve), x0: f32, y0: f32, x1: f32, y1: f32) !void {
    // Counter-clockwise in a y-up sense, so the winding comes out positive.
    try lineOf(gpa, out, .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 });
    try lineOf(gpa, out, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 });
    try lineOf(gpa, out, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 });
    try lineOf(gpa, out, .{ .x = x0, .y = y1 }, .{ .x = x0, .y = y0 });
}

test "a pixel well inside a shape is fully covered and one outside is not" {
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 10, 10, 30, 30);

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);

    const scale: Scale = .{ .x = 1, .y = 1 };
    try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, id, 20, 20, scale, 4), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), coverageAt(store, id, 5, 20, scale, 4), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), coverageAt(store, id, 35, 20, scale, 4), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), coverageAt(store, id, 20, 40, scale, 4), 0.001);
}

test "a vertical edge is exact at every sub-pixel offset" {
    // The property the whole method is for. Multisampling gives an edge as
    // many coverage levels as it has samples; this gives it the real number,
    // because the x integral is closed form and only the y one is sampled.
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 10, 0, 100, 100);

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);
    const scale: Scale = .{ .x = 1, .y = 1 };

    // The shape's left edge is at x = 10 and it extends to the right, so a
    // pixel centred at 10 + f has `0.5 + f` of its width inside -- and gets
    // exactly that, from a single ray, at every offset.
    var f: f32 = -0.45;
    while (f <= 0.45) : (f += 0.05) {
        const want = std.math.clamp(0.5 + f, 0, 1);
        const got = coverageAt(store, id, 10 + f, 50, scale, 1);
        try testing.expectApproxEqAbs(want, got, 0.001);
    }
}

test "a horizontal edge is quantised, and by exactly the ray count" {
    // The other half of the trade, stated rather than hidden: the y integral
    // is a midpoint rule, so a horizontal edge gets `rays + 1` levels. With
    // one ray it is a hard edge; with four it is five steps; with sixteen it
    // is close enough to the truth to measure.
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 0, 10, 100, 100);

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);
    const scale: Scale = .{ .x = 1, .y = 1 };

    // Dead on the edge: half the pixel is inside, whatever the ray count.
    try testing.expectApproxEqAbs(@as(f32, 0.5), coverageAt(store, id, 50, 10, scale, 4), 0.001);

    // A quarter of a pixel above it, four rays can only say "three quarters".
    try testing.expectApproxEqAbs(@as(f32, 0.75), coverageAt(store, id, 50, 10.25, scale, 4), 0.001);

    // And sixteen rays land within a sixteenth of the truth.
    var off: f32 = -0.4;
    while (off <= 0.4) : (off += 0.1) {
        const want = std.math.clamp(0.5 + off, 0, 1);
        const got = coverageAt(store, id, 50, 10 + off, scale, 16);
        try testing.expectApproxEqAbs(want, got, 1.0 / 16.0);
    }
}

test "the branchless crossing test agrees with the readable one" {
    // What makes the GLSL safe to trust: the table in the shader is this
    // table, and this table gives the same answers as the version that
    // actually solves for the roots and looks at the tangent.
    var rng: std.Random.DefaultPrng = .init(0x51a6);
    const rand = rng.random();

    var worst: f32 = 0;
    for (0..20000) |_| {
        const c: Curve = .{
            .x0 = rand.float(f32) * 20 - 10,
            .y0 = rand.float(f32) * 20 - 10,
            .x1 = rand.float(f32) * 20 - 10,
            .y1 = rand.float(f32) * 20 - 10,
            .x2 = rand.float(f32) * 20 - 10,
            .y2 = rand.float(f32) * 20 - 10,
        };
        const x = rand.float(f32) * 20 - 10;
        const y = rand.float(f32) * 20 - 10;
        const a = crossings(c, x, y, 1.0);
        const b = crossingsTable(c, x, y, 1.0);
        worst = @max(worst, @abs(a - b));
    }
    // Bit-exact over twenty thousand random curves, which is more than the
    // bridge needs to carry but is what it happens to hold: the two compute
    // the same roots by the same stable formula and differ only in how they
    // decide which of them is in range.
    try testing.expectEqual(@as(f32, 0), worst);
}

test "the even-odd rule empties what the nonzero rule fills" {
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    // Two squares wound the same way, one inside the other.
    try square(gpa, &curves, 0, 0, 40, 40);
    try square(gpa, &curves, 10, 10, 30, 30);

    var store: Store = .{};
    defer store.deinit(gpa);
    const nz = try store.add(gpa, curves.items, .nonzero);
    const eo = try store.add(gpa, curves.items, .even_odd);
    const scale: Scale = .{ .x = 1, .y = 1 };

    // In the overlap the winding is two.
    try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, nz, 20, 20, scale, 4), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), coverageAt(store, eo, 20, 20, scale, 4), 0.001);
    // In the ring between them it is one, and both rules fill it.
    try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, nz, 5, 20, scale, 4), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, eo, 5, 20, scale, 4), 0.001);
}

test "bands hold every curve that reaches into them and no pixel misses one" {
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    // A tall thin shape, so the bands actually divide it.
    try square(gpa, &curves, 0, 0, 4, 400);

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);
    const h = store.headers.items[id];
    try testing.expect(h.row_count > 1);

    // The two long sides span every band; the two short ends span one each.
    var seen: u32 = 0;
    for (store.bands.items[h.row_first..][0..h.row_count]) |b| seen += b.count;
    try testing.expect(seen >= h.row_count * 2);

    // And the shape is filled all the way down, which is the thing the bands
    // could silently break.
    const scale: Scale = .{ .x = 1, .y = 1 };
    var y: f32 = 2;
    while (y < 398) : (y += 7) {
        try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, id, 2, y, scale, 4), 0.001);
    }
}

test "a cubic becomes as many quadratics as the tolerance asks for and no more" {
    const gpa = testing.allocator;
    var out: std.ArrayList(Curve) = .empty;
    defer out.deinit(gpa);

    // A quarter circle of radius 100, the usual test case: its cubic
    // approximation is close to circular, so the quadratics have somewhere to
    // be wrong.
    const k = 0.5522847 * 100.0;
    const p0: Point = .{ .x = 100, .y = 0 };
    const c1: Point = .{ .x = 100, .y = k };
    const c2: Point = .{ .x = k, .y = 100 };
    const p3: Point = .{ .x = 0, .y = 100 };

    try addCubic(gpa, &out, p0, c1, c2, p3, 0.02, 16);
    try testing.expect(out.items.len >= 2);
    try testing.expect(out.items.len <= 16);

    // The chain is continuous and ends where the cubic does.
    try testing.expectApproxEqAbs(p0.x, out.items[0].x0, 0.001);
    try testing.expectApproxEqAbs(p3.y, out.items[out.items.len - 1].y2, 0.001);
    for (out.items[1..], out.items[0 .. out.items.len - 1]) |next, prev| {
        try testing.expectApproxEqAbs(prev.x2, next.x0, 0.001);
        try testing.expectApproxEqAbs(prev.y2, next.y0, 0.001);
    }

    // And every point of it is within tolerance of the cubic it replaces.
    const n = out.items.len;
    for (out.items, 0..) |q, i| {
        var s: f32 = 0;
        while (s <= 1.0) : (s += 0.125) {
            const t = (@as(f32, @floatFromInt(i)) + s) / @as(f32, @floatFromInt(n));
            const want = cubicAt(p0, c1, c2, p3, t);
            const got = q.at(s);
            try testing.expectApproxEqAbs(want.x, got.x, 0.05);
            try testing.expectApproxEqAbs(want.y, got.y, 0.05);
        }
    }
}

fn cubicAt(p0: Point, c1: Point, c2: Point, p3: Point, t: f32) Point {
    const u = 1 - t;
    const a = u * u * u;
    const b = 3 * u * u * t;
    const c = 3 * u * t * t;
    const d = t * t * t;
    return .{
        .x = a * p0.x + b * c1.x + c * c2.x + d * p3.x,
        .y = a * p0.y + b * c1.y + c * c2.y + d * p3.y,
    };
}

test "a coarser zoom widens the antialiased band rather than moving the edge" {
    // Resolution independence, which is the reason the curves and not the
    // pixels go to the device: the same store, drawn at two scales, puts the
    // edge in the same place and only changes how many pixels the transition
    // takes.
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 10, 0, 100, 100);

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);

    // At four device pixels per path unit a pixel is a quarter of a unit, so
    // a quarter unit past the edge is a whole pixel in and fully covered.
    const fine: Scale = .{ .x = 4, .y = 4 };
    try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, id, 10.25, 50, fine, 4), 0.001);
    // At one pixel per unit the same place is still on the edge.
    const coarse: Scale = .{ .x = 1, .y = 1 };
    try testing.expectApproxEqAbs(@as(f32, 0.75), coverageAt(store, id, 10.25, 50, coarse, 4), 0.001);
    // And the midpoint of the ramp is the edge at either scale.
    try testing.expectApproxEqAbs(@as(f32, 0.5), coverageAt(store, id, 10, 50, fine, 4), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), coverageAt(store, id, 10, 50, coarse, 4), 0.001);
}
