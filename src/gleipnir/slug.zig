//! Analytic path coverage, the way Slug computes it: the outline itself goes
//! to the GPU and the fragment shader works out how much of each pixel the
//! path covers, from the curves.
//!
//! This follows Eric Lengyel's reference shaders
//! (https://github.com/EricLengyel/Slug, MIT) in everything that decides
//! the picture -- two rays per pixel and how they are combined, bands in
//! both directions sorted for an early exit, lines left out of the bands
//! they run parallel to, and the pixel footprint taken from the transform.
//! It departs from them in two places, both said where they happen: the root
//! solve is the numerically stable one rather than an epsilon test, and the
//! curves and bands live in storage buffers rather than textures.
//!
//! ## What it computes
//!
//! Cast a ray from the pixel's centre towards +x. Every place the outline
//! crosses it, the outline either enters the shape or leaves it, and
//!
//!     xcov = Σ ±clamp((x_cross − x_pixel)·ppu + ½, 0, 1)
//!
//! is the winding number with each crossing ramped across the pixel's width:
//! a crossing well to the right counts fully, one well to the left not at
//! all, and one inside the pixel by how much of the pixel lies to its left.
//! Along that row it is the exact covered length, in closed form. Cast a
//! second ray towards +y and the same sum gives `ycov`.
//!
//! One ray is exact for an edge perpendicular to it and blind to an edge
//! parallel to it -- a horizontal ray across a horizontal edge is either
//! wholly inside or wholly outside. So each ray also reports a **weight**:
//! how close its nearest crossing is to the pixel's centre,
//! `clamp(1 − 2|r|, 0, 1)`, which is one for a crossing through the centre
//! and zero for one half a pixel away or more. The two are then blended by
//! their weights:
//!
//!     cov = max(|xcov·xw + ycov·yw| / max(xw + yw, ε), min(|xcov|, |ycov|))
//!
//! A vertical edge has a crossing near the pixel on the x ray and none on the
//! y ray, so it takes the x ray's answer, which is exact. A horizontal edge
//! the other way round. Where neither ray has a nearby crossing the pixel is
//! inside or outside and `min(|xcov|, |ycov|)` says which. Only where an edge
//! runs diagonally, or a corner sits inside the pixel, is this an
//! approximation -- and it is a smooth one, with no quantisation anywhere.
//!
//! ## What it costs, and bands
//!
//! Every curve crossing a ray has to be tested, and testing every curve of a
//! path per fragment is quadratic nonsense on anything bigger than a glyph.
//! So the path's box is cut into **horizontal bands** for the x ray and
//! **vertical bands** for the y ray, and a fragment tests the curves of one
//! of each. Within a band the curves are sorted by how far they reach in the
//! ray's direction, descending, so the loop stops at the first curve that
//! ends more than half a pixel behind the sample: every curve after it does
//! too. A curve that is a straight line along a band's direction is left out
//! of that band altogether, because a ray parallel to it cannot cross it.
//!
//! ## The two rules
//!
//! `cov` is a coverage-weighted winding number, so the fill rule is applied
//! to it last: nonzero clamps it to one, even-odd folds it into a triangle
//! wave. Both are exact except where a pixel straddles the point at which two
//! contours cross -- the same approximation Slug makes, bounded by a pixel,
//! and invisible on glyphs, which do not self-intersect.
//!
//! ## Where the copies of this live
//!
//! Three, meant to be read against each other:
//!
//! * `crossings` here is the readable one: it solves for the roots, checks
//!   they are in range and looks at the tangent.
//! * `crossingsTable` here is the branchless one, written the way a shader
//!   has to be. A test asserts the two agree bit for bit.
//! * `shader/slug.glsl` is `crossingsTable` and `coverageAt` transcribed.

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
        // Bands and early exits only need a conservative box.
        return .{
            .min_x = @min(c.x0, @min(c.x1, c.x2)),
            .min_y = @min(c.y0, @min(c.y1, c.y2)),
            .max_x = @max(c.x0, @max(c.x1, c.x2)),
            .max_y = @max(c.y0, @max(c.y1, c.y2)),
        };
    }

    /// The same curve with x and y exchanged, which is what turns the
    /// horizontal ray test into the vertical one.
    pub fn swapped(c: Curve) Curve {
        return .{ .x0 = c.y0, .y0 = c.x0, .x1 = c.y1, .y1 = c.x1, .x2 = c.y2, .y2 = c.x2 };
    }
};

/// A slice of `Store.indices`: the curves that reach into one band, sorted
/// so the shader can stop early. See `Store.buildBands`.
pub const Band = extern struct {
    first: u32 = 0,
    count: u32 = 0,
};

/// Everything the shader needs to know about one path, and nothing about
/// where it is drawn -- that is the instance's business, which is what lets
/// one uploaded path be drawn at several transforms.
///
/// Forty bytes, and every member a scalar. A `vec4` for the box would read
/// better in GLSL and would make the struct 48 bytes there -- std430 aligns a
/// struct to its most-aligned member, and a `vec4` aligns to sixteen -- while
/// this side wrote forty. That mismatch shipped once: every header after the
/// first was read eight bytes further along per index than it was written,
/// and a page came out as its own glyphs, huge and scattered. The SPIR-V
/// layout test in `lyngvi/shaders.zig` is what stops it shipping again.
pub const Header = extern struct {
    min_x: f32 = 0,
    min_y: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,
    curve_first: u32 = 0,
    curve_count: u32 = 0,
    /// The horizontal bands, then the vertical ones, back to back.
    band_first: u32 = 0,
    /// Bands across y, cut horizontally, for the ray towards +x.
    h_bands: u32 = 0,
    /// Bands across x, cut vertically, for the ray towards +y.
    v_bands: u32 = 0,
    /// `0` nonzero, `1` even-odd. A `u32` because GLSL has no enums and the
    /// std430 layout has to be written out in full anyway.
    rule: u32 = 0,

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
/// asked for. A fiftieth of a point is a hundredth of a pixel at a reading
/// zoom and costs perhaps two segments where one would have done.
pub const default_tolerance: f32 = 0.02;

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

    /// Where the store currently ends, for `rewind`.
    pub const Mark = struct { curves: usize, bands: usize, indices: usize, headers: usize };

    pub fn mark(s: Store) Mark {
        return .{
            .curves = s.curves.items.len,
            .bands = s.bands.items.len,
            .indices = s.indices.items.len,
            .headers = s.headers.items.len,
        };
    }

    /// Drops everything added since `m`, keeping the capacity.
    ///
    /// What a CPU replay does with a path it has finished with: the outline
    /// was needed for one fill and the store would otherwise grow by every
    /// path on the page. Glyphs are the exception -- they are kept and reused,
    /// which is why this takes a mark rather than resetting.
    pub fn rewind(s: *Store, m: Mark) void {
        s.curves.shrinkRetainingCapacity(m.curves);
        s.bands.shrinkRetainingCapacity(m.bands);
        s.indices.shrinkRetainingCapacity(m.indices);
        s.headers.shrinkRetainingCapacity(m.headers);
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
    /// of the wrong shapes: a header's `curve_first` and `band_first` move by
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
            out.band_first += band_base;
            s.headers.appendAssumeCapacity(out);
        }
        return header_base;
    }

    /// Adds a path's curves and builds its bands. Returns its header index,
    /// which is what an instance refers to it by.
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
            const n = bandCount(curves.len);
            header.band_first = @intCast(s.bands.items.len);
            header.h_bands = n;
            header.v_bands = n;
            try s.buildBands(gpa, curves, first, box, .horizontal, n);
            try s.buildBands(gpa, curves, first, box, .vertical, n);
        }

        const id: u32 = @intCast(s.headers.items.len);
        try s.headers.append(gpa, header);
        return id;
    }

    /// Sorts the curves into bands along one axis, as a counted-then-filled
    /// index array, and orders each band for the early exit.
    ///
    /// `.horizontal` bands are cut across y and serve the ray towards +x:
    /// they leave out curves that are straight horizontal lines, and sort by
    /// the largest x, descending. `.vertical` is the same with the axes
    /// exchanged.
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
        axis: Axis,
        count: u32,
    ) Allocator.Error!void {
        const band_first = s.bands.items.len;
        try s.bands.appendNTimes(gpa, .{}, count);
        const lo, const hi = axis.across(box);
        const extent = @max(hi - lo, std.math.floatEps(f32));
        const per = @as(f32, @floatFromInt(count)) / extent;
        // Bands overlap by a sliver, so a sample landing on a boundary finds
        // every curve that touches it whichever side rounding puts it on.
        const eps = extent / @as(f32, @floatFromInt(count)) / 64.0;

        // Pass one: how many curves reach into each band.
        for (curves) |c| {
            if (axis.parallel(c)) continue;
            const a, const b = axis.across(c.bounds());
            const first, const last = bandSpan(a - eps, b + eps, lo, per, count);
            var i = first;
            while (i <= last) : (i += 1) s.bands.items[band_first + i].count += 1;
        }

        // Running offsets, so each band knows where its indices start.
        var total: u32 = @intCast(s.indices.items.len);
        for (s.bands.items[band_first..]) |*band| {
            band.first = total;
            total += band.count;
            // Reused below as a write cursor, and restored by the fill.
            band.count = 0;
        }
        try s.indices.resize(gpa, total);

        // Pass two: fill them in.
        for (curves, 0..) |c, ci| {
            if (axis.parallel(c)) continue;
            const a, const b = axis.across(c.bounds());
            const first, const last = bandSpan(a - eps, b + eps, lo, per, count);
            var i = first;
            while (i <= last) : (i += 1) {
                const band = &s.bands.items[band_first + i];
                s.indices.items[band.first + band.count] = curve_first + @as(u32, @intCast(ci));
                band.count += 1;
            }
        }

        // Descending by how far each curve reaches along the ray, so the
        // shader's loop can stop at the first curve that ends behind the
        // pixel. The sort is what makes the break correct; without it the
        // break skips curves that do cross.
        for (s.bands.items[band_first..]) |band| {
            const slice = s.indices.items[band.first..][0..band.count];
            std.sort.pdq(u32, slice, SortContext{ .curves = s.curves.items, .axis = axis }, SortContext.lessThan);
        }
    }
};

const Axis = enum {
    horizontal,
    vertical,

    /// The range a box covers across the bands, which is y for horizontal
    /// bands and x for vertical ones.
    fn across(axis: Axis, b: Bounds) struct { f32, f32 } {
        return switch (axis) {
            .horizontal => .{ b.min_y, b.max_y },
            .vertical => .{ b.min_x, b.max_x },
        };
    }

    /// How far a curve reaches in the ray's direction.
    fn reach(axis: Axis, c: Curve) f32 {
        return switch (axis) {
            .horizontal => @max(c.x0, @max(c.x1, c.x2)),
            .vertical => @max(c.y0, @max(c.y1, c.y2)),
        };
    }

    /// A straight line running along the ray, which the ray cannot cross.
    fn parallel(axis: Axis, c: Curve) bool {
        return switch (axis) {
            .horizontal => c.y0 == c.y1 and c.y1 == c.y2,
            .vertical => c.x0 == c.x1 and c.x1 == c.x2,
        };
    }
};

const SortContext = struct {
    curves: []const Curve,
    axis: Axis,

    fn lessThan(ctx: SortContext, a: u32, b: u32) bool {
        return ctx.axis.reach(ctx.curves[a]) > ctx.axis.reach(ctx.curves[b]);
    }
};

/// The bands a range touches, clamped into range.
fn bandSpan(min: f32, max: f32, origin: f32, per: f32, count: u32) struct { u32, u32 } {
    const last = count - 1;
    const a = (min - origin) * per;
    const b = (max - origin) * per;
    const lo: u32 = if (!(a > 0)) 0 else @min(last, @as(u32, @intFromFloat(a)));
    const hi: u32 = if (!(b > 0)) 0 else @min(last, @as(u32, @intFromFloat(b)));
    return .{ lo, @max(lo, hi) };
}

/// Which band a coordinate lands in. The shader's `bandOf`.
fn bandOf(lo: f32, hi: f32, v: f32, count: u32) u32 {
    const extent = hi - lo;
    if (!(extent > 0) or count == 0) return 0;
    const t = (v - lo) / extent * @as(f32, @floatFromInt(count));
    if (!(t > 0)) return 0;
    return @min(@as(u32, @intFromFloat(t)), count - 1);
}

/// How many bands a path with this many curves gets, in each direction.
///
/// The cost per fragment is the curves in one band of each kind, roughly
/// `2n/bands` before the early exit, and the memory is roughly `2n` indices
/// plus the bands themselves. Balancing the two puts the count near the
/// square root, which for a glyph of forty curves is nine bands of four or
/// five -- and for a path of one or two curves is one band.
pub fn bandCount(curves: usize) u32 {
    if (curves <= 2) return 1;
    const n: u32 = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(curves)) * 2.0)));
    return std.math.clamp(n, 1, max_bands);
}

/// A ceiling on bands per direction. A path with more curves than this
/// squared just gets fuller bands; the alternative is a store whose band
/// array is larger than its curve array.
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

/// Collects the quadratics of a glyph outline, scaled by `scale`.
///
/// The same walk as `fromPath` over the verbs and points a `GlyphSource`
/// hands back, with the em normalisation folded in so the curves come out in
/// em units: one unit is one em, whatever the font program counts in. That is
/// what lets one recorded outline serve every size the glyph is drawn at --
/// the size is the instance's matrix.
pub fn fromOutline(
    gpa: Allocator,
    out: *std.ArrayList(Curve),
    verbs: []const Verb,
    points: []const Point,
    scale: f32,
    tolerance: f32,
) Allocator.Error!void {
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
                start = scaled(points[i], scale);
                cur = start;
                open = true;
            },
            .line => {
                const to = scaled(points[i], scale);
                try lineOf(gpa, out, cur, to);
                cur = to;
            },
            .cubic => {
                const c1 = scaled(points[i], scale);
                const c2 = scaled(points[i + 1], scale);
                const to = scaled(points[i + 2], scale);
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

fn scaled(p: Point, by: f32) Point {
    return .{ .x = p.x * by, .y = p.y * by };
}

/// How far a quadratic may stray from the cubic it stands in for, in em
/// units, for an outline recorded once and drawn at every size.
///
/// A two-thousandth of an em is a twentieth of a pixel on a hundred-pixel
/// glyph, which is larger than anything on a page of text and half the size
/// of the largest display type. It cannot be derived from the size the way
/// `default_tolerance` is, because the whole point of recording in em space
/// is that the size is not known yet.
pub const glyph_tolerance: f32 = 1.0 / 2048.0;

/// Collects the quadratics of an already-flattened path.
///
/// Every segment becomes a straight quadratic. That throws away the
/// resolution independence for anything that arrives this way -- a stroke's
/// generated outline, and a clip path, which the replay flattens for the
/// canvas's stencil and hands to a scene as well -- but it is what makes the
/// analytic fill usable for everything on the page today rather than for
/// path fills alone.
///
/// `fromPath` is the one that keeps curves as curves, and it is the one a
/// `fill_path` command goes through. A glyph goes through `fromOutline`,
/// which is the same walk.
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

/// A line as a quadratic, with the control point in the middle.
///
/// Lengyel's reference duplicates the second endpoint instead, `{p1, p2,
/// p2}`, because its solver switches to the linear formula below an epsilon
/// and a midpoint control makes `a` land near that epsilon. The stable solve
/// here has no epsilon, so the midpoint is fine -- and it is the one that
/// keeps a horizontal line's control point on the line, which is what lets
/// `Axis.parallel` recognise it exactly.
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

/// Device pixels per path unit, in each axis, as the rays see them.
///
/// Slug takes this from `fwidth` of the interpolated em-space coordinate:
/// the path-space distance one pixel step covers in x, plus the one in y.
/// For an affine transform that is a property of the inverse matrix and not
/// of the fragment, so it is computed from the matrix -- which is also what
/// lets the CPU model and the shader agree exactly. Under a page transform,
/// a scale with a flip, it is the scale; under a rotation it widens the ramp
/// the way `fwidth` does, rather than taking the column lengths and leaving
/// a rotated edge too sharp.
pub const Scale = struct {
    x: f32,
    y: f32,

    pub fn of(xform: Transform) Scale {
        const det = @abs(xform.a * xform.d - xform.b * xform.c);
        const across_x = @abs(xform.c) + @abs(xform.d);
        const across_y = @abs(xform.a) + @abs(xform.b);
        return .{
            .x = if (across_x > 0) det / across_x else 0,
            .y = if (across_y > 0) det / across_y else 0,
        };
    }
};

/// One ray's crossings with one curve: the coverage-weighted winding it adds
/// and the weight of its nearest crossing.
pub const Ray = struct {
    cov: f32 = 0,
    wgt: f32 = 0,
};

/// The fraction of the pixel centred on `(x, y)` that the path covers.
///
/// This is the model of the fragment shader, line for line: the x ray over
/// one horizontal band, the y ray over one vertical band, each stopping at
/// the first curve behind the pixel, and Lengyel's combination of the two.
pub fn coverageAt(s: Store, header: u32, x: f32, y: f32, ppu: Scale) f32 {
    if (header >= s.headers.items.len) return 0;
    const h = s.headers.items[header];
    if (h.curve_count == 0 or h.h_bands == 0 or !(ppu.x > 0) or !(ppu.y > 0)) return 0;

    // Further outside the box than half a pixel is outside the path.
    const half_x = 0.5 / ppu.x;
    const half_y = 0.5 / ppu.y;
    if (x + half_x < h.min_x or x - half_x > h.max_x) return 0;
    if (y + half_y < h.min_y or y - half_y > h.max_y) return 0;

    const xr = rayAlongX(s, h, x, y, ppu.x);
    const yr = rayAlongY(s, h, x, y, ppu.y);
    return combine(xr, yr, h.rule);
}

/// The ray towards +x, over the horizontal band containing `y`.
pub fn rayAlongX(s: Store, h: Header, x: f32, y: f32, ppu_x: f32) Ray {
    const band = s.bands.items[h.band_first + bandOf(h.min_y, h.max_y, y, h.h_bands)];
    var out: Ray = .{};
    var k: u32 = 0;
    while (k < band.count) : (k += 1) {
        const c = s.curves.items[s.indices.items[band.first + k]];
        // Sorted by reach: once one curve ends behind the pixel, all the rest
        // do, and none of them can contribute.
        if ((@max(c.x0, @max(c.x1, c.x2)) - x) * ppu_x < -0.5) break;
        const r = crossingsTable(c, x, y, ppu_x);
        out.cov += r.cov;
        out.wgt = @max(out.wgt, r.wgt);
    }
    return out;
}

/// The ray towards +y, over the vertical band containing `x`.
///
/// `crossingsTable` on the curve with its axes exchanged. Exchanging the axes
/// is a reflection, which reverses every contour's orientation, so the sum
/// comes back negated -- and is negated again here, so the two rays agree in
/// sign about which side of an outline is inside. Their weighted sum is
/// meaningless otherwise.
pub fn rayAlongY(s: Store, h: Header, x: f32, y: f32, ppu_y: f32) Ray {
    const band = s.bands.items[h.band_first + h.h_bands + bandOf(h.min_x, h.max_x, x, h.v_bands)];
    var out: Ray = .{};
    var k: u32 = 0;
    while (k < band.count) : (k += 1) {
        const c = s.curves.items[s.indices.items[band.first + k]];
        if ((@max(c.y0, @max(c.y1, c.y2)) - y) * ppu_y < -0.5) break;
        const r = crossingsTable(c.swapped(), y, x, ppu_y);
        out.cov -= r.cov;
        out.wgt = @max(out.wgt, r.wgt);
    }
    return out;
}

/// Lengyel's combination of the two rays, and then the fill rule. See the
/// module comment for why each term is there.
pub fn combine(xr: Ray, yr: Ray, rule: u32) f32 {
    const weighted = @abs(xr.cov * xr.wgt + yr.cov * yr.wgt) / @max(xr.wgt + yr.wgt, 1.0 / 65536.0);
    const cov = @max(weighted, @min(@abs(xr.cov), @abs(yr.cov)));
    return applyRule(cov, rule);
}

/// One curve's crossings with the ray from `(x, y)` towards +x: the readable
/// version.
///
/// Finds where the curve crosses the ray's line, and for each crossing adds
/// the fraction of the pixel's width lying to the left of it -- positive
/// where the outline is going up, negative where it is going down, because
/// that is what makes the sum a winding number rather than a count.
pub fn crossings(c: Curve, x: f32, y: f32, ppu_x: f32) Ray {
    // Relative to the sample: the ray is then the positive x axis.
    const y0 = c.y0 - y;
    const y1 = c.y1 - y;
    const y2 = c.y2 - y;

    // B(t) = a·t² − 2b·t + c, from the Bernstein form.
    const a = y0 - 2 * y1 + y2;
    const b = y0 - y1;
    const disc = b * b - a * y0;
    if (disc < 0) return .{};

    const lo, const hi = roots(a, b, y0, disc);

    var out: Ray = .{};
    for ([2]f32{ lo, hi }) |tt| {
        // Half-open, so a crossing shared by two curves at their joint is
        // counted once rather than twice or not at all.
        if (!(tt >= 0) or tt >= 1) continue;
        // dy/dt at the crossing decides the direction. Up adds, down
        // subtracts.
        const dy = 2 * ((y1 - y0) + tt * (y0 - 2 * y1 + y2));
        if (dy == 0) continue;
        const r = (xAt(c, tt) - x) * ppu_x;
        const ramp = std.math.clamp(r + 0.5, 0, 1);
        out.cov += if (dy > 0) ramp else -ramp;
        out.wgt = @max(out.wgt, std.math.clamp(1 - @abs(r) * 2, 0, 1));
    }
    return out;
}

fn xAt(c: Curve, t: f32) f32 {
    const u = 1 - t;
    return u * u * c.x0 + 2 * u * t * c.x1 + t * t * c.x2;
}

/// Both roots of `a·t² − 2b·t + c = 0`, as `(b − √d)/a` and `(b + √d)/a`,
/// computed so that neither is destroyed by cancellation.
///
/// Lengyel's `SolveHorizPoly` switches to the linear formula when
/// `|a| < 1/65536`. That threshold is in em units, where a glyph is one unit
/// tall; here a path is in page points and a curve's `a` is three orders of
/// magnitude larger or smaller depending on what drew it, so no fixed
/// epsilon is right. The stable form needs none. Take `s = b ± √d` with the
/// sign that makes the two terms add rather than cancel; then `s/a` is the
/// root of larger magnitude and `c/s` is the other, by Vieta. As `a → 0`,
/// `s → 2b` and `c/s → c/2b`, which is exactly the root of the linear
/// equation that is left -- no special case, no branch.
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
/// `root_table`. That is Slug's root eligibility test, and it is what makes
/// the method robust -- a crossing exactly at a joint between two curves is
/// counted by exactly one of them, decided by signs rather than by comparing
/// a computed `t` against 0 and 1.
///
/// `crossings` is the specification; this is the implementation; the test
/// "the branchless crossing test agrees with the readable one" is the bridge.
pub fn crossingsTable(c: Curve, x: f32, y: f32, ppu_x: f32) Ray {
    const y0 = c.y0 - y;
    const y1 = c.y1 - y;
    const y2 = c.y2 - y;

    const shift: u4 = @intCast((@as(u32, @intFromBool(y0 > 0)) << 1) |
        (@as(u32, @intFromBool(y1 > 0)) << 2) |
        (@as(u32, @intFromBool(y2 > 0)) << 3));
    const code = (root_table >> shift) & 3;
    if (code == 0) return .{};

    const a = y0 - 2 * y1 + y2;
    const b = y0 - y1;

    // The table is an upper bound on the crossings, not the count of them.
    // Its `3` cases say "the control point is on the far side of the ray from
    // both ends", and a quadratic does not pass through its control point --
    // it may bend towards the ray and turn back without ever reaching it. The
    // discriminant is what knows the difference, so it is tested and not
    // merely clamped. Lengyel's reference clamps it, treating the near miss
    // as a double root at the vertex whose two crossings cancel in `cov`; the
    // weight they leave behind is what the test here avoids.
    const disc = b * b - a * y0;
    if (disc < 0) return .{};

    const t0, const t1 = roots(a, b, y0, disc);

    var out: Ray = .{};
    if (code & 1 != 0) {
        const r = (xAt(c, t0) - x) * ppu_x;
        out.cov -= std.math.clamp(r + 0.5, 0, 1);
        out.wgt = @max(out.wgt, std.math.clamp(1 - @abs(r) * 2, 0, 1));
    }
    if (code & 2 != 0) {
        const r = (xAt(c, t1) - x) * ppu_x;
        out.cov += std.math.clamp(r + 0.5, 0, 1);
        out.wgt = @max(out.wgt, std.math.clamp(1 - @abs(r) * 2, 0, 1));
    }
    return out;
}

/// Which roots of `B(t) = 0` lie in `[0, 1)`, and with which sign, for each
/// of the eight sign patterns of `(y₀, y₁, y₂)`.
///
/// Two bits per pattern, indexed by `2·[y₀>0] + 4·[y₁>0] + 8·[y₂>0]`: bit 0
/// means the lower root crosses downward, bit 1 means the upper root crosses
/// upward. The constant is Slug's; the indexing is by positive signs where
/// the reference extracts negative ones, which reads the same table from the
/// other end.
///
/// Reading it out: `0` for all-below and all-above, because a curve entirely
/// on one side of the ray never meets it; `3` where the middle point is on
/// the other side from both ends, because the curve crosses and comes back.
pub const root_table: u16 = 0x2E74;

/// Turns a coverage-weighted winding number into a coverage.
///
/// Nonzero stops at one, which is also what makes an overlapping stroke
/// outline -- where the winding is two or three deep -- come out solid
/// instead of over-bright. Even-odd folds it into a triangle wave, so
/// winding two is empty again; this is Lengyel's `1 − |1 − 2·fract(w/2)|`.
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

const unit: Scale = .{ .x = 1, .y = 1 };

test "a pixel well inside a shape is fully covered and one outside is not" {
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 10, 10, 30, 30);

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);

    try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, id, 20, 20, unit), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), coverageAt(store, id, 5, 20, unit), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), coverageAt(store, id, 35, 20, unit), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), coverageAt(store, id, 20, 40, unit), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), coverageAt(store, id, 20, 5, unit), 0.001);
}

test "the two rays agree about which side of an outline is inside" {
    // The weighted sum adds the two rays' windings, so they have to have the
    // same sign for the same shape. If the y ray's reflection were not undone
    // every edge would cancel against itself.
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 10, 10, 30, 30);

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);
    const h = store.headers.items[id];

    const xr = rayAlongX(store, h, 20, 20, 1);
    const yr = rayAlongY(store, h, 20, 20, 1);
    try testing.expectApproxEqAbs(@as(f32, 1), @abs(xr.cov), 0.001);
    try testing.expectEqual(std.math.sign(xr.cov), std.math.sign(yr.cov));

    // And a clockwise square flips both together.
    curves.clearRetainingCapacity();
    try square(gpa, &curves, 30, 10, 10, 30);
    const cw = try store.add(gpa, curves.items, .nonzero);
    const hc = store.headers.items[cw];
    const xc = rayAlongX(store, hc, 20, 20, 1);
    const yc = rayAlongY(store, hc, 20, 20, 1);
    try testing.expectEqual(std.math.sign(xc.cov), std.math.sign(yc.cov));
    try testing.expect(std.math.sign(xc.cov) != std.math.sign(xr.cov));
}

test "a vertical edge is exact at every sub-pixel offset" {
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 10, 0, 100, 100);

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);

    // The shape's left edge is at x = 10 and it extends to the right, so a
    // pixel centred at 10 + f has `0.5 + f` of its width inside.
    var f: f32 = -0.45;
    while (f <= 0.45) : (f += 0.05) {
        const want = std.math.clamp(0.5 + f, 0, 1);
        try testing.expectApproxEqAbs(want, coverageAt(store, id, 10 + f, 50, unit), 0.001);
    }
}

test "a horizontal edge is exact too, which one ray could not make it" {
    // What the second ray is for. The x ray through a pixel on a horizontal
    // edge is entirely inside or entirely outside; the y ray crosses the edge
    // inside the pixel, carries all the weight, and gets the true answer.
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 0, 10, 100, 100);

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);

    var off: f32 = -0.45;
    while (off <= 0.45) : (off += 0.05) {
        const want = std.math.clamp(0.5 + off, 0, 1);
        try testing.expectApproxEqAbs(want, coverageAt(store, id, 50, 10 + off, unit), 0.001);
    }
}

test "a diagonal edge is close to its true coverage" {
    // The case the combination approximates. A 45° edge through a pixel's
    // centre covers exactly half of it; both rays cross at the centre with
    // full weight and the blend gives the half.
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try lineOf(gpa, &curves, .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 });
    try lineOf(gpa, &curves, .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 100 });
    try lineOf(gpa, &curves, .{ .x = 100, .y = 100 }, .{ .x = 0, .y = 0 });

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);

    try testing.expectApproxEqAbs(@as(f32, 0.5), coverageAt(store, id, 50.5, 50.5, unit), 0.001);
    // A quarter pixel into the shape along the normal is past three
    // quarters in truth; the blend is monotone and lands between.
    const inside = coverageAt(store, id, 50.75, 50.25, unit);
    try testing.expect(inside > 0.5 and inside <= 1.0);
    const outside = coverageAt(store, id, 50.25, 50.75, unit);
    try testing.expect(outside < 0.5 and outside >= 0.0);
}

test "the branchless crossing test agrees with the readable one" {
    // What makes the GLSL safe to trust: the table in the shader is this
    // table, and this table gives the same answers -- coverage and weight --
    // as the version that solves for the roots and looks at the tangent.
    var rng: std.Random.DefaultPrng = .init(0x51a6);
    const rand = rng.random();

    var worst_cov: f32 = 0;
    var worst_wgt: f32 = 0;
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
        worst_cov = @max(worst_cov, @abs(a.cov - b.cov));
        worst_wgt = @max(worst_wgt, @abs(a.wgt - b.wgt));
    }
    try testing.expectEqual(@as(f32, 0), worst_cov);
    try testing.expectEqual(@as(f32, 0), worst_wgt);
}

test "the early exit never skips a curve that would have contributed" {
    // The sort and the break are a pair: this renders random shapes with the
    // break and compares against summing every curve in the path.
    const gpa = testing.allocator;
    var rng: std.Random.DefaultPrng = .init(0xba2d);
    const rand = rng.random();

    var store: Store = .{};
    defer store.deinit(gpa);
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);

    for (0..40) |_| {
        curves.clearRetainingCapacity();
        // A closed polygon of random quadratics.
        var pts: [12]Point = undefined;
        for (&pts) |*p| p.* = .{ .x = rand.float(f32) * 40, .y = rand.float(f32) * 40 };
        for (pts, 0..) |p, i| {
            const q = pts[(i + 1) % pts.len];
            try curves.append(gpa, .{
                .x0 = p.x,
                .y0 = p.y,
                .x1 = rand.float(f32) * 40,
                .y1 = rand.float(f32) * 40,
                .x2 = q.x,
                .y2 = q.y,
            });
        }
        const id = try store.add(gpa, curves.items, .nonzero);
        const h = store.headers.items[id];

        for (0..50) |_| {
            const x = rand.float(f32) * 40;
            const y = rand.float(f32) * 40;
            var all_x: Ray = .{};
            var all_y: Ray = .{};
            for (curves.items) |c| {
                const r = crossingsTable(c, x, y, 1);
                all_x.cov += r.cov;
                all_x.wgt = @max(all_x.wgt, r.wgt);
                const v = crossingsTable(c.swapped(), y, x, 1);
                all_y.cov -= v.cov;
                all_y.wgt = @max(all_y.wgt, v.wgt);
            }
            const xr = rayAlongX(store, h, x, y, 1);
            const yr = rayAlongY(store, h, x, y, 1);
            try testing.expectApproxEqAbs(all_x.cov, xr.cov, 0.0001);
            try testing.expectApproxEqAbs(all_x.wgt, xr.wgt, 0.0001);
            try testing.expectApproxEqAbs(all_y.cov, yr.cov, 0.0001);
            try testing.expectApproxEqAbs(all_y.wgt, yr.wgt, 0.0001);
        }
    }
}

test "a straight line is left out of the bands it runs along" {
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 0, 0, 10, 10);

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);
    const h = store.headers.items[id];

    // Every horizontal band holds the two vertical sides and nothing else,
    // and every vertical band the two horizontal ones.
    for (store.bands.items[h.band_first..][0..h.h_bands]) |hb| {
        try testing.expectEqual(@as(u32, 2), hb.count);
        for (store.indices.items[hb.first..][0..hb.count]) |i| {
            try testing.expect(store.curves.items[i].x0 == store.curves.items[i].x2);
        }
    }
    for (store.bands.items[h.band_first + h.h_bands ..][0..h.v_bands]) |vb| {
        try testing.expectEqual(@as(u32, 2), vb.count);
        for (store.indices.items[vb.first..][0..vb.count]) |i| {
            try testing.expect(store.curves.items[i].y0 == store.curves.items[i].y2);
        }
    }
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

    // In the overlap the winding is two.
    try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, nz, 20, 20, unit), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), coverageAt(store, eo, 20, 20, unit), 0.001);
    // In the ring between them it is one, and both rules fill it.
    try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, nz, 5, 20, unit), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, eo, 5, 20, unit), 0.001);
}

test "bands hold every curve that reaches into them and no pixel misses one" {
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    // A tall thin shape made of many short segments, so the bands actually
    // divide it in both directions.
    var y: f32 = 0;
    while (y < 400) : (y += 10) {
        try lineOf(gpa, &curves, .{ .x = 4, .y = y }, .{ .x = 4, .y = y + 10 });
    }
    try lineOf(gpa, &curves, .{ .x = 4, .y = 400 }, .{ .x = 0, .y = 400 });
    while (y > 0) : (y -= 10) {
        try lineOf(gpa, &curves, .{ .x = 0, .y = y }, .{ .x = 0, .y = y - 10 });
    }
    try lineOf(gpa, &curves, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 });

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);
    const h = store.headers.items[id];
    try testing.expect(h.h_bands > 1);

    var probe: f32 = 2;
    while (probe < 398) : (probe += 3.7) {
        try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, id, 2, probe, unit), 0.001);
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
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 10, 0, 100, 100);

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);

    // At four device pixels per path unit a pixel is a quarter of a unit, so
    // a quarter unit past the edge is half a pixel in and fully covered.
    const fine: Scale = .{ .x = 4, .y = 4 };
    try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, id, 10.125, 50, fine), 0.001);
    // At one pixel per unit the same place is still on the edge.
    try testing.expectApproxEqAbs(@as(f32, 0.625), coverageAt(store, id, 10.125, 50, unit), 0.001);
    // And the midpoint of the ramp is the edge at either scale.
    try testing.expectApproxEqAbs(@as(f32, 0.5), coverageAt(store, id, 10, 50, fine), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), coverageAt(store, id, 10, 50, unit), 0.001);
}

test "the pixel footprint comes from the inverse, the way fwidth does" {
    // Axis-aligned, with the page's flip: the scale itself.
    const page = Scale.of(.{ .a = 2, .b = 0, .c = 0, .d = -3, .e = 5, .f = 7 });
    try testing.expectApproxEqAbs(@as(f32, 2), page.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 3), page.y, 0.0001);

    // A 45° rotation at unit scale: one pixel step moves √½ in x and √½ in
    // y, so fwidth is √2 and the pixels per unit are √½.
    const r = std.math.sqrt1_2;
    const rot = Scale.of(.{ .a = r, .b = r, .c = -r, .d = r });
    try testing.expectApproxEqAbs(@as(f32, r), rot.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, r), rot.y, 0.0001);
}

test "a merged store draws each path exactly as its source did" {
    // Three levels of renumbering, and a page made of the wrong shapes if any
    // of them is missed. Merging moves data and never arithmetic, so the
    // coverage is compared bit for bit rather than to a tolerance.
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);

    var a: Store = .{};
    defer a.deinit(gpa);
    try square(gpa, &curves, 0, 0, 10, 10);
    const small = try a.add(gpa, curves.items, .nonzero);

    var b: Store = .{};
    defer b.deinit(gpa);
    curves.clearRetainingCapacity();
    try square(gpa, &curves, 0, 0, 40, 40);
    try square(gpa, &curves, 10, 10, 30, 30);
    const ring = try b.add(gpa, curves.items, .even_odd);
    curves.clearRetainingCapacity();
    try addCubic(gpa, &curves, .{ .x = 0, .y = 0 }, .{ .x = 30, .y = 40 }, .{ .x = 10, .y = 40 }, .{ .x = 40, .y = 0 }, 0.02, 16);
    try lineOf(gpa, &curves, .{ .x = 40, .y = 0 }, .{ .x = 0, .y = 0 });
    const arch = try b.add(gpa, curves.items, .nonzero);

    var merged: Store = .{};
    defer merged.deinit(gpa);
    const base_a = try merged.merge(gpa, a);
    const base_b = try merged.merge(gpa, b);
    // Merged a second time, so a base is never right by being zero.
    const base_c = try merged.merge(gpa, b);
    try testing.expectEqual(@as(u32, 0), base_a);
    try testing.expectEqual(@as(u32, 1), base_b);
    try testing.expectEqual(@as(u32, 3), base_c);
    try testing.expectEqual(merged.curves.items.len, a.curves.items.len + 2 * b.curves.items.len);

    const cases = [_]struct { src: *const Store, id: u32, base: u32 }{
        .{ .src = &a, .id = small, .base = base_a },
        .{ .src = &b, .id = ring, .base = base_b },
        .{ .src = &b, .id = arch, .base = base_b },
        .{ .src = &b, .id = arch, .base = base_c },
    };
    for (cases) |case| {
        var y: f32 = -2;
        while (y < 42) : (y += 0.7) {
            var x: f32 = -2;
            while (x < 42) : (x += 0.7) {
                try testing.expectEqual(
                    coverageAt(case.src.*, case.id, x, y, unit),
                    coverageAt(merged, case.id + case.base, x, y, unit),
                );
            }
        }
    }
}

test "rewinding to a mark drops what came after it and keeps what came before" {
    // What a CPU replay does around a one-off fill: the glyphs added before
    // the mark are kept and reused, the fill after it is dropped, and the
    // arrays keep their capacity for the next one.
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    var s: Store = .{};
    defer s.deinit(gpa);

    try square(gpa, &curves, 0, 0, 10, 10);
    const glyph = try s.add(gpa, curves.items, .nonzero);
    const before = s.mark();
    const covered = coverageAt(s, glyph, 5, 5, unit);
    const edge = coverageAt(s, glyph, 10.25, 5, unit);

    curves.clearRetainingCapacity();
    var x: f32 = 0;
    while (x < 200) : (x += 10) try square(gpa, &curves, x, 0, x + 5, 100);
    _ = try s.add(gpa, curves.items, .even_odd);
    const grown = s.indices.capacity;

    s.rewind(before);
    try testing.expectEqual(before, s.mark());
    try testing.expectEqual(grown, s.indices.capacity);
    try testing.expectEqual(covered, coverageAt(s, glyph, 5, 5, unit));
    try testing.expectEqual(edge, coverageAt(s, glyph, 10.25, 5, unit));

    // The next path takes the place of the dropped one.
    curves.clearRetainingCapacity();
    try square(gpa, &curves, 0, 0, 1, 1);
    try testing.expectEqual(glyph + 1, try s.add(gpa, curves.items, .nonzero));
}

test "every band is sorted by reach and holds every curve that meets it" {
    // The invariant the early exit stands on, checked directly rather than
    // through its consequence: a band out of order, or one missing a curve
    // that reaches into it, is a pixel with the wrong winding.
    const gpa = testing.allocator;
    var rng: std.Random.DefaultPrng = .init(0xb4d5);
    const rand = rng.random();

    var store: Store = .{};
    defer store.deinit(gpa);
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);

    for (0..24) |_| {
        curves.clearRetainingCapacity();
        const n = 3 + rand.uintLessThan(usize, 90);
        const first: Point = .{ .x = rand.float(f32) * 100, .y = rand.float(f32) * 100 };
        var prev = first;
        for (0..n) |i| {
            const next: Point = if (i == n - 1)
                first
            else
                .{ .x = rand.float(f32) * 100, .y = rand.float(f32) * 100 };
            // Every fourth one straight, and some of those horizontal or
            // vertical, so the parallel-line exclusion has work to do.
            var to = next;
            if (i % 8 == 1 and i != n - 1) to.y = prev.y;
            if (i % 8 == 5 and i != n - 1) to.x = prev.x;
            const ctrl: Point = if (i % 4 == 1)
                .{ .x = (prev.x + to.x) * 0.5, .y = (prev.y + to.y) * 0.5 }
            else
                .{ .x = rand.float(f32) * 100, .y = rand.float(f32) * 100 };
            try curves.append(gpa, .{ .x0 = prev.x, .y0 = prev.y, .x1 = ctrl.x, .y1 = ctrl.y, .x2 = to.x, .y2 = to.y });
            prev = to;
        }
        const id = try store.add(gpa, curves.items, .nonzero);
        const h = store.headers.items[id];
        try testing.expectEqual(bandCount(curves.items.len), h.h_bands);
        try testing.expectEqual(bandCount(curves.items.len), h.v_bands);

        for ([_]Axis{ .horizontal, .vertical }) |axis| {
            const band_first = h.band_first + if (axis == .horizontal) 0 else h.h_bands;
            const count = if (axis == .horizontal) h.h_bands else h.v_bands;
            const lo, const hi = axis.across(h.bounds());
            const step = (hi - lo) / @as(f32, @floatFromInt(count));

            for (0..count) |bi| {
                const band = store.bands.items[band_first + bi];
                const ids = store.indices.items[band.first..][0..band.count];
                if (ids.len > 1) {
                    for (ids[1..], ids[0 .. ids.len - 1]) |later, earlier| {
                        try testing.expect(axis.reach(store.curves.items[earlier]) >= axis.reach(store.curves.items[later]));
                    }
                }

                const band_lo = lo + step * @as(f32, @floatFromInt(bi));
                const band_hi = band_lo + step;
                for (h.curve_first..h.curve_first + h.curve_count) |ci| {
                    const c = store.curves.items[ci];
                    const listed = std.mem.indexOfScalar(u32, ids, @intCast(ci)) != null;
                    if (axis.parallel(c)) {
                        try testing.expect(!listed);
                        continue;
                    }
                    const a, const b = axis.across(c.bounds());
                    if (b < band_lo or a > band_hi) continue;
                    try testing.expect(listed);
                }
            }
        }
    }
}

test "every coordinate lands in some band, the awkward ones included" {
    // The shader's `bandOf` is a transcription of this, so the edges are
    // pinned here: a sample on a boundary goes up, one past either end is
    // clamped into the last or first band, and a NaN or a path with no extent
    // reads band zero rather than an index off the end of the array.
    try testing.expectEqual(@as(u32, 0), bandOf(0, 10, -5, 4));
    try testing.expectEqual(@as(u32, 3), bandOf(0, 10, 15, 4));
    try testing.expectEqual(@as(u32, 3), bandOf(0, 10, 10, 4));
    try testing.expectEqual(@as(u32, 1), bandOf(0, 10, 2.5, 4));
    try testing.expectEqual(@as(u32, 0), bandOf(0, 10, std.math.nan(f32), 4));
    try testing.expectEqual(@as(u32, 0), bandOf(5, 5, 5, 4));
    try testing.expectEqual(@as(u32, 0), bandOf(0, 10, 5, 0));

    // A span is clamped the same way, and never comes back inverted.
    const whole = bandSpan(-5, 25, 0, 0.4, 4);
    try testing.expectEqual(@as(u32, 0), whole[0]);
    try testing.expectEqual(@as(u32, 3), whole[1]);
    const nan = bandSpan(std.math.nan(f32), std.math.nan(f32), 0, 0.4, 4);
    try testing.expectEqual(@as(u32, 0), nan[0]);
    try testing.expectEqual(@as(u32, 0), nan[1]);
    const point = bandSpan(6, 6, 0, 0.4, 4);
    try testing.expectEqual(@as(u32, 2), point[0]);
    try testing.expectEqual(@as(u32, 2), point[1]);

    // And how many bands a path gets: one for a line or two, about the
    // square root of twice the curves, and never more than the ceiling.
    try testing.expectEqual(@as(u32, 1), bandCount(0));
    try testing.expectEqual(@as(u32, 1), bandCount(2));
    try testing.expectEqual(@as(u32, 9), bandCount(40));
    try testing.expectEqual(max_bands, bandCount(2048));
    try testing.expectEqual(max_bands, bandCount(1 << 20));
}

test "a pixel at infinity is uncovered rather than a crash" {
    // A matrix singular to within a float inverts to infinities, and a
    // fragment then asks about a point nowhere. The box test answers first,
    // so no infinity reaches the float-to-integer conversion in `bandOf`.
    const gpa = testing.allocator;
    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 0, 0, 10, 10);
    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);

    const inf = std.math.inf(f32);
    try testing.expectEqual(@as(f32, 0), coverageAt(store, id, inf, 5, unit));
    try testing.expectEqual(@as(f32, 0), coverageAt(store, id, 5, -inf, unit));
    try testing.expectEqual(@as(f32, 0), coverageAt(store, id, 5, 5, .{ .x = 0, .y = 1 }));
    // And an id past the end is not a path.
    try testing.expectEqual(@as(f32, 0), coverageAt(store, id + 1, 5, 5, unit));
}

const Builder = @import("../gelgja/Builder.zig");

fn firstFill(list: DisplayList) DisplayList.Path {
    for (list.cmds) |cmd| switch (cmd) {
        .fill_path => |c| return c.path,
        else => {},
    };
    unreachable;
}

test "an open subpath is closed, so its winding comes back to zero" {
    // Coverage is only defined for a closed outline. Left open, the crossing
    // the missing edge would have made is unpaired, and every pixel to one
    // side of the shape is filled.
    const gpa = testing.allocator;
    var b: Builder = .init(gpa, .fromRect(0, 0, 100, 100));
    // Two subpaths, neither closed: the second move is what ends the first.
    try b.moveTo(.{ .x = 10, .y = 10 });
    try b.lineTo(.{ .x = 30, .y = 10 });
    try b.lineTo(.{ .x = 30, .y = 30 });
    try b.lineTo(.{ .x = 10, .y = 30 });
    try b.moveTo(.{ .x = 50, .y = 10 });
    try b.lineTo(.{ .x = 70, .y = 10 });
    try b.lineTo(.{ .x = 70, .y = 30 });
    try b.fill(.nonzero, .{ .solid = .black });
    var list = try b.finish();
    defer list.deinit(gpa);

    var curves: std.ArrayList(Curve) = .empty;
    defer curves.deinit(gpa);
    try fromPath(gpa, &curves, list, firstFill(list), .identity, default_tolerance);
    // Three sides and two, each with its closing edge added.
    try testing.expectEqual(@as(usize, 7), curves.items.len);

    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, curves.items, .nonzero);
    try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, id, 20, 20, unit), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), coverageAt(store, id, 66, 14, unit), 0.001);
    // Above the triangle's diagonal, between the two, and past both: empty.
    try testing.expectApproxEqAbs(@as(f32, 0), coverageAt(store, id, 54, 26, unit), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), coverageAt(store, id, 40, 20, unit), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), coverageAt(store, id, 90, 20, unit), 0.001);
}

/// The distance from `p` to the nearest point of a chain of quadratics,
/// measured against each as a polyline fine enough that its chords sit well
/// inside any tolerance the tests ask about.
fn distanceToQuads(p: Point, quads: []const Curve) f32 {
    const steps = 64;
    var best = std.math.inf(f32);
    for (quads) |q| {
        var prev = q.at(0);
        for (1..steps + 1) |k| {
            const next = q.at(@as(f32, @floatFromInt(k)) / steps);
            const dx = next.x - prev.x;
            const dy = next.y - prev.y;
            const len2 = dx * dx + dy * dy;
            const t = if (len2 > 0) std.math.clamp(((p.x - prev.x) * dx + (p.y - prev.y) * dy) / len2, 0, 1) else 0;
            const ex = prev.x + t * dx - p.x;
            const ey = prev.y + t * dy - p.y;
            best = @min(best, @sqrt(ex * ex + ey * ey));
            prev = next;
        }
    }
    return best;
}

test "a cubic's quadratics stay within the tolerance of it, whatever its shape" {
    // The bound `addCubic` recurses on is the distance between the cubic and
    // its quadratic at the same parameter, which is never less than the
    // distance to the nearest point. The shapes are the ones a quarter circle
    // does not have: an inflection, a loop, a cusp.
    const gpa = testing.allocator;
    const tolerance = default_tolerance;
    const shapes = [_][4]Point{
        // An S: one inflection.
        .{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 0, .y = 100 }, .{ .x = 100, .y = 100 } },
        // A loop: the control points cross over.
        .{ .{ .x = 0, .y = 0 }, .{ .x = 150, .y = 100 }, .{ .x = -50, .y = 100 }, .{ .x = 100, .y = 0 } },
        // A cusp: the tangent vanishes in the middle.
        .{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 100 }, .{ .x = 0, .y = 100 }, .{ .x = 100, .y = 0 } },
        // Collinear and evenly spaced: already a line.
        .{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 }, .{ .x = 30, .y = 30 } },
    };

    var out: std.ArrayList(Curve) = .empty;
    defer out.deinit(gpa);
    for (shapes) |c| {
        out.clearRetainingCapacity();
        try addCubic(gpa, &out, c[0], c[1], c[2], c[3], tolerance, 16);
        try testing.expect(out.items.len >= 1);
        // Continuous, and ending where the cubic does.
        try testing.expectEqual(c[0].x, out.items[0].x0);
        try testing.expectEqual(c[3].y, out.items[out.items.len - 1].y2);
        for (out.items[1..], out.items[0 .. out.items.len - 1]) |next, prev| {
            try testing.expectEqual(prev.x2, next.x0);
            try testing.expectEqual(prev.y2, next.y0);
        }
        var i: u32 = 0;
        while (i <= 200) : (i += 1) {
            const at = cubicAt(c[0], c[1], c[2], c[3], @as(f32, @floatFromInt(i)) / 200);
            try testing.expect(distanceToQuads(at, out.items) <= tolerance * 1.01);
        }
    }
    // The line takes one quadratic.
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // So does a point. Its box is a point and it still gets a band, but no ray
    // crosses it, so it draws nothing rather than a dot.
    const p: Point = .{ .x = 5, .y = 5 };
    out.clearRetainingCapacity();
    try addCubic(gpa, &out, p, p, p, p, tolerance, 16);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    var store: Store = .{};
    defer store.deinit(gpa);
    const id = try store.add(gpa, out.items, .nonzero);
    for ([_]f32{ 4.5, 5, 5.5 }) |at| {
        try testing.expectEqual(@as(f32, 0), coverageAt(store, id, at, 5, unit));
        try testing.expectEqual(@as(f32, 0), coverageAt(store, id, 5, at, unit));
    }
}

test "a glyph outline comes out in em units, and a short one stops cleanly" {
    const gpa = testing.allocator;
    var out: std.ArrayList(Curve) = .empty;
    defer out.deinit(gpa);

    // A 1000-unit em, as a Type 1 or CFF font counts: a square with one
    // curved side.
    const verbs = [_]Verb{ .move, .line, .cubic, .line, .close };
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 500, .y = 0 },
        .{ .x = 600, .y = 200 },
        .{ .x = 600, .y = 500 },
        .{ .x = 500, .y = 700 },
        .{ .x = 0, .y = 700 },
    };
    try fromOutline(gpa, &out, &verbs, &points, 1.0 / 1000.0, glyph_tolerance);
    var box: Bounds = .empty;
    for (out.items) |c| box = box.unionWith(c.bounds());
    try testing.expectApproxEqAbs(@as(f32, 0.7), box.max_y, 0.0001);
    // The curved side bulges to its midpoint, 0.575 of an em, not out to its
    // control points at 0.6: the quadratics hug the curve, not its hull.
    try testing.expectApproxEqAbs(@as(f32, 0.575), box.max_x, 0.001);
    try testing.expectEqual(@as(f32, 0), box.min_x);

    // A font program that ends mid-curve: a cubic with one point where it
    // needs three. The walk stops there and still closes what it had, rather
    // than reading past the end of the points.
    out.clearRetainingCapacity();
    try fromOutline(gpa, &out, &verbs, points[0..3], 1.0 / 1000.0, glyph_tolerance);
    // The line, and the edge closing it back to the start.
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(f32, 0), out.items[1].x2);
}

test "a flattened path becomes one straight quadratic per segment" {
    // Strokes and clips arrive this way. Each subpath is shut whether or not
    // it was closed, and a closing edge that is already there is not doubled.
    const gpa = testing.allocator;
    const path_mod = @import("path.zig");
    var f: path_mod.Flattener = .init(.{});
    defer f.deinit(gpa);
    try f.moveTo(gpa, .{ .x = 0, .y = 0 });
    try f.lineTo(gpa, .{ .x = 10, .y = 0 });
    try f.lineTo(gpa, .{ .x = 0, .y = 10 });
    try f.close(gpa);
    try f.moveTo(gpa, .{ .x = 20, .y = 0 });
    try f.lineTo(gpa, .{ .x = 30, .y = 0 });
    try f.lineTo(gpa, .{ .x = 30, .y = 10 });
    const flat = try f.finish(gpa);

    var out: std.ArrayList(Curve) = .empty;
    defer out.deinit(gpa);
    try fromFlattened(gpa, &out, flat);
    try testing.expectEqual(flat.segmentCount(), out.items.len);
    try testing.expectEqual(@as(usize, 6), out.items.len);
    // Straight: the control point is the midpoint, exactly, which is what
    // lets `Axis.parallel` recognise a horizontal one.
    for (out.items) |c| {
        try testing.expectEqual((c.x0 + c.x2) * 0.5, c.x1);
        try testing.expectEqual((c.y0 + c.y2) * 0.5, c.y1);
    }
}
