//! Stroke to fill: turning a pen dragged along a path into an outline the
//! stencil pass can handle.
//!
//! ## Stamping, not offsetting
//!
//! The textbook way to stroke is to offset the path by half the line width on
//! each side and join the two offset curves into one outline. It produces the
//! fewest triangles and it is a minefield: offset curves of Béziers are not
//! Béziers, the two sides self-intersect wherever the path's curvature exceeds
//! `1/half_width`, and resolving those self-intersections correctly is most of
//! the work in a production stroker. Every renderer that does it this way has
//! a file of tests named after the shapes that broke it.
//!
//! This one does the other thing. Each flattened segment becomes a rectangle,
//! each join becomes a wedge, each cap becomes a disc or a square, every piece
//! is wound the same way, and the whole heap is filled with the **nonzero**
//! rule. Nonzero over consistently wound overlapping polygons is exactly the
//! union of them, so the pieces need no relationship to each other at all:
//! they may overlap, be contained in one another, or cover the same pixel
//! forty times, and the answer is the same.
//!
//! What it costs is triangles -- four vertices per segment plus a join, where
//! an offset outline would emit two. What it buys is that there is no case
//! analysis. A path that doubles back on itself, a curve tighter than the pen,
//! a subpath of one point, a dash pattern that lands exactly on a corner:
//! none of them is a special case here, because none of them can produce a
//! self-intersection that matters. Stencil-then-cover was chosen precisely
//! because it does not care how much geometry overlaps, and this is the
//! second time that pays.
//!
//! ## Round is a whole circle
//!
//! A round join is a disc of radius `w/2` at the joint, and a round cap is a
//! disc of radius `w/2` at the endpoint. Not a wedge and not a semicircle --
//! the full disc, in both cases. The half that a semicircle would leave out
//! is already covered by the segment rectangle next to it, and the union does
//! not care that it is covered twice. One function serves both, and the
//! angle bookkeeping that a wedge would need -- which way does the path turn,
//! which end of the arc is which -- disappears.
//!
//! ## Which space this happens in
//!
//! User space, not page space. The pen is a circle before the CTM and an
//! ellipse after it (§8.4.3.2), so a stroke generated in page space with a
//! scaled width is only correct when the matrix is a similarity. The display
//! list keeps `ctm` on every `stroke_path` for exactly this reason: the caller
//! maps the path back through the inverse, strokes here, and hands the
//! resulting outline to the shader with `ctm` in its push constant.
//!
//! That also fixes the flattening tolerance, which has to be a device-pixel
//! quantity: `Params.tolerance` is in the space the input is in, so the caller
//! divides by the *total* scale, the CTM's and the view's together.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");
const paint = @import("../gelgja/paint.zig");
const path = @import("path.zig");

const Bounds = geom.Bounds;
const Cap = paint.Cap;
const Flattened = path.Flattened;
const Flattener = path.Flattener;
const Join = paint.Join;
const Point = geom.Point;
const Vertex = path.Vertex;

pub const Error = path.Error;

/// The pen, resolved. Everything here is in the same space as the input path.
pub const Params = struct {
    /// Already resolved: a `/w` of zero means "the thinnest line the device
    /// can draw" (§8.4.3.2), and only the caller knows what that is in this
    /// space. `resolveWidth` does the arithmetic.
    width: f32 = 1,
    cap: Cap = .butt,
    join: Join = .miter,
    /// `/M`. The ratio of the miter's length to the line width at which the
    /// join gives up and bevels instead. 10 is the PDF default, which turns
    /// into a bevel at about 11.5 degrees.
    miter_limit: f32 = 10,
    /// Alternating on and off lengths. Empty is a solid line.
    dash: []const f32 = &.{},
    dash_phase: f32 = 0,
    /// How far a round join or cap may deviate from a true circle, in the
    /// input's own units.
    tolerance: f32 = 0.1,

    fn half(p: Params) f32 {
        return @max(p.width, 0) * 0.5;
    }
};

/// A zero line width means one device pixel, whatever that is here (§8.4.3.2).
///
/// `scale` is how much the composed page-to-device matrix magnifies lengths,
/// from `Transform.expansion`. A hairline is the one piece of PDF geometry
/// whose size is decided by the output device rather than by the file, so it
/// cannot be resolved until both matrices are known.
pub fn resolveWidth(width: f32, scale: f32) f32 {
    if (width > 0 and std.math.isFinite(width)) return width;
    const s = if (scale > 1e-6) scale else 1e-6;
    return 1.0 / s;
}

/// Strokes `input` into `out`, which the caller then finishes and meshes.
///
/// The result must be filled with `.nonzero` regardless of what rule the
/// original path would have been filled with. A stroke has no fill rule of its
/// own: the rule is an implementation detail of how the pieces are unioned,
/// and even-odd over this heap would punch holes wherever two stamps overlap.
pub fn outline(gpa: Allocator, out: *Flattener, input: Flattened, p: Params) Error!void {
    const h = p.half();
    if (h <= 0) return;

    if (p.dash.len > 0 and dashIsUsable(p.dash)) {
        var d: Dasher = .{ .params = p, .out = out };
        try d.apply(gpa, input);
        return;
    }

    for (input.subpaths) |s| {
        try strokeRun(gpa, out, s.slice(input.points), s.closed, p);
    }
}

/// One open or closed polyline.
fn strokeRun(gpa: Allocator, out: *Flattener, pts: []const Vertex, closed: bool, p: Params) Error!void {
    const h = p.half();
    if (pts.len == 0) return;

    // A subpath with no length. `m` followed straight by `h`, or a dash whose
    // on-length rounded to nothing. With butt caps it marks nothing at all,
    // which is what the spec says (§8.4.3.3) and what a reader has to
    // reproduce -- generators use exactly this to draw nothing conditionally.
    if (pts.len == 1) {
        switch (p.cap) {
            .butt => {},
            .round => try disc(gpa, out, pts[0], h, p.tolerance),
            // Axis-aligned, because there is no direction to align to.
            .square => try quad(gpa, out, .{
                .{ .x = pts[0].x - h, .y = pts[0].y - h },
                .{ .x = pts[0].x + h, .y = pts[0].y - h },
                .{ .x = pts[0].x + h, .y = pts[0].y + h },
                .{ .x = pts[0].x - h, .y = pts[0].y + h },
            }),
        }
        return;
    }

    const n = pts.len;
    const segments = if (closed) n else n - 1;

    var i: usize = 0;
    while (i < segments) : (i += 1) {
        const a = pts[i];
        const b = pts[(i + 1) % n];
        try segment(gpa, out, a, b, h);
    }

    // Joins at every interior vertex, and at the seam too when the subpath is
    // closed -- that seam is a join and not two caps, which is the whole
    // difference `Subpath.closed` records.
    var j: usize = if (closed) 0 else 1;
    const last = if (closed) n else n - 1;
    while (j < last) : (j += 1) {
        const prev = pts[(j + n - 1) % n];
        const at = pts[j];
        const next = pts[(j + 1) % n];
        try join(gpa, out, prev, at, next, h, p);
    }

    if (!closed) {
        try cap(gpa, out, pts[1], pts[0], h, p);
        try cap(gpa, out, pts[n - 2], pts[n - 1], h, p);
    }
}

/// The rectangle swept by the pen along one segment.
fn segment(gpa: Allocator, out: *Flattener, a: Vertex, b: Vertex, h: f32) Error!void {
    const d = direction(a, b) orelse return;
    const nx = -d.y * h;
    const ny = d.x * h;
    try quad(gpa, out, .{
        .{ .x = a.x - nx, .y = a.y - ny },
        .{ .x = b.x - nx, .y = b.y - ny },
        .{ .x = b.x + nx, .y = b.y + ny },
        .{ .x = a.x + nx, .y = a.y + ny },
    });
}

/// The wedge that fills the gap on the outside of a corner.
///
/// Only the outside needs filling: on the inside the two segment rectangles
/// already overlap, and the union does not care. Which side is outside is
/// decided by the sign of the turn, and getting it backwards fills a wedge
/// that was already covered and leaves the real gap open -- visible on any
/// stroke thicker than a couple of pixels as a nick at every corner.
fn join(gpa: Allocator, out: *Flattener, prev: Vertex, at: Vertex, next: Vertex, h: f32, p: Params) Error!void {
    // Round does not need to know any of that.
    if (p.join == .round) return disc(gpa, out, at, h, p.tolerance);

    const d0 = direction(prev, at) orelse return;
    const d1 = direction(at, next) orelse return;

    const turn = d0.x * d1.y - d0.y * d1.x;
    if (turn == 0) {
        // Collinear. Either straight through, which needs no join, or a
        // reversal, which needs one and has no outside -- the miter is
        // infinite and the bevel is degenerate, so a butt end is all a bevel
        // or a miter can mean there. A round join would have covered it, and
        // that is the documented difference between the two at a spike.
        return;
    }
    // The outward normal is on the opposite side from the turn.
    const s: f32 = if (turn > 0) -1 else 1;

    const c0: Vertex = .{ .x = at.x - d0.y * h * s, .y = at.y + d0.x * h * s };
    const c1: Vertex = .{ .x = at.x - d1.y * h * s, .y = at.y + d1.x * h * s };

    if (p.join == .miter) {
        // The interior angle between the two segments. cos(phi) = -d0 . d1,
        // and the miter is `1 / sin(phi/2)` line widths long (§8.4.3.5) -- so
        // a sharp spike has a long miter and a right angle has one of 1.41.
        const cos_phi = -(d0.x * d1.x + d0.y * d1.y);
        // sin(phi/2) = sqrt((1 - cos phi) / 2). Not (1 + cos phi), which is
        // cos(phi/2) -- the two agree at exactly ninety degrees and nowhere
        // else, so a right-angled corner is the one test that cannot tell them
        // apart.
        const sin_half = @sqrt(@max((1 - cos_phi) * 0.5, 0));
        if (sin_half > 1e-6 and 1.0 / sin_half <= @max(p.miter_limit, 1)) {
            var bx = -(d0.y + d1.y) * s;
            var by = (d0.x + d1.x) * s;
            const len = @sqrt(bx * bx + by * by);
            if (len > 1e-9) {
                bx /= len;
                by /= len;
                const reach = h / sin_half;
                const tip: Vertex = .{ .x = at.x + bx * reach, .y = at.y + by * reach };
                return quad(gpa, out, .{ at, c0, tip, c1 });
            }
        }
        // Over the limit: bevel, which is what the limit is for.
    }

    try triangle(gpa, out, at, c0, c1);
}

/// The end of an open subpath. `from` is the point before `end`, which is what
/// gives the cap a direction to point in.
fn cap(gpa: Allocator, out: *Flattener, from: Vertex, end: Vertex, h: f32, p: Params) Error!void {
    switch (p.cap) {
        .butt => {},
        .round => try disc(gpa, out, end, h, p.tolerance),
        .square => {
            const d = direction(from, end) orelse return;
            const ex = d.x * h;
            const ey = d.y * h;
            const nx = -d.y * h;
            const ny = d.x * h;
            try quad(gpa, out, .{
                .{ .x = end.x - nx, .y = end.y - ny },
                .{ .x = end.x - nx + ex, .y = end.y - ny + ey },
                .{ .x = end.x + nx + ex, .y = end.y + ny + ey },
                .{ .x = end.x + nx, .y = end.y + ny },
            });
        },
    }
}

const Direction = struct { x: f32, y: f32 };

/// The unit vector from `a` to `b`, or null when they are the same point.
fn direction(a: Vertex, b: Vertex) ?Direction {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    if (!(len2 > 0) or !std.math.isFinite(len2)) return null;
    const len = @sqrt(len2);
    return .{ .x = dx / len, .y = dy / len };
}

/// How many sides an `n`-gon needs to stay within `tolerance` of a circle of
/// radius `r`.
///
/// The sagitta of one side is `r * (1 - cos(pi/n))`, which is about
/// `r * pi^2 / (2 n^2)`, so `n = pi * sqrt(r / (2 * tolerance))`. Four is the
/// floor because a round join on a hairline is a square and nobody can tell;
/// the ceiling stops a pen the size of a page from generating thousands of
/// vertices at every corner.
pub fn circleSegments(r: f32, tolerance: f32) u32 {
    if (!(r > 0) or !std.math.isFinite(r)) return 4;
    const tol = @max(tolerance, 1e-6);
    const n = std.math.pi * @sqrt(r / (2 * tol));
    if (!(n > 4)) return 4;
    if (n >= 128) return 128;
    return @intFromFloat(@ceil(n));
}

fn disc(gpa: Allocator, out: *Flattener, at: Vertex, r: f32, tolerance: f32) Error!void {
    const n = circleSegments(r, tolerance);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const a = 2 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const p: Point = .{ .x = at.x + r * @cos(a), .y = at.y + r * @sin(a) };
        if (i == 0) try out.moveTo(gpa, p) else try out.lineTo(gpa, p);
    }
    try out.close(gpa);
}

fn quad(gpa: Allocator, out: *Flattener, v: [4]Vertex) Error!void {
    try emit(gpa, out, &v);
}

fn triangle(gpa: Allocator, out: *Flattener, a: Vertex, b: Vertex, c: Vertex) Error!void {
    try emit(gpa, out, &.{ a, b, c });
}

/// Appends one convex stamp, reversed if it came out wound the wrong way.
///
/// Every piece of the stroke has to wind the same direction or nonzero
/// subtracts one from another where they overlap, and a stroke overlaps itself
/// constantly -- at every join, at both ends of every dash. Rather than
/// reason about the orientation of each shape separately, each one is measured
/// and flipped if needed. It is one cross product per stamp and it makes the
/// invariant impossible to break by adding a new kind of piece later.
fn emit(gpa: Allocator, out: *Flattener, v: []const Vertex) Error!void {
    if (v.len < 3) return;
    const area = signedArea(v);
    if (area == 0) return;

    if (area > 0) {
        for (v, 0..) |p, i| {
            if (i == 0) try out.moveTo(gpa, p.point()) else try out.lineTo(gpa, p.point());
        }
    } else {
        var i: usize = v.len;
        while (i > 0) {
            i -= 1;
            if (i == v.len - 1) try out.moveTo(gpa, v[i].point()) else try out.lineTo(gpa, v[i].point());
        }
    }
    try out.close(gpa);
}

fn signedArea(v: []const Vertex) f32 {
    var sum: f32 = 0;
    for (v, 0..) |p, i| {
        const q = v[(i + 1) % v.len];
        sum += p.x * q.y - q.x * p.y;
    }
    return sum;
}

// -- dashes -----------------------------------------------------------------

/// A dash array is unusable if it is empty, has a negative entry, or sums to
/// zero (§8.4.3.6). All three mean a solid line rather than an error, and the
/// third one matters: `[0 0] 0 d` appears in real files, and walking it as a
/// pattern is an infinite loop.
fn dashIsUsable(dash: []const f32) bool {
    var total: f32 = 0;
    for (dash) |d| {
        if (!(d >= 0) or !std.math.isFinite(d)) return false;
        total += d;
    }
    return total > 0;
}

/// Walks a path cutting it into on and off runs by arc length.
///
/// Kept as a struct rather than a function because the phase carries across
/// segments and, within a subpath, across the whole polyline: a dash that
/// starts in the middle of a segment has to continue into the next one at the
/// right offset, and a pattern that is reset per segment turns every flattened
/// curve into a dotted line.
const Dasher = struct {
    params: Params,
    out: *Flattener,

    /// Which entry of the array we are in, and how much of it is left.
    index: usize = 0,
    remaining: f32 = 0,
    on: bool = true,

    /// The run being accumulated, in points. Bounded by `max_run`: a dash
    /// pattern of 1e-30 against a page-sized path would otherwise generate
    /// segments until memory ran out, and damaged files contain exactly that.
    run: std.ArrayList(Vertex) = .empty,

    const max_run = 1 << 16;

    fn reset(d: *Dasher) void {
        const dash = d.params.dash;
        var phase = d.params.dash_phase;
        if (!std.math.isFinite(phase) or phase < 0) phase = 0;

        var total: f32 = 0;
        for (dash) |v| total += v;
        // A phase longer than the pattern is legal and means what it says, but
        // walking it one entry at a time is O(phase / total) -- and a phase of
        // 1e9 against a pattern of 3 is a hang. One modulo instead.
        if (total > 0) phase = @mod(phase, total * @as(f32, if (dash.len % 2 == 1) 2 else 1));

        d.index = 0;
        d.on = true;
        d.remaining = dash[0];
        while (phase > 0) {
            if (phase < d.remaining) {
                d.remaining -= phase;
                break;
            }
            phase -= d.remaining;
            d.advance();
        }
    }

    /// On and off alternate with every entry consumed, never with the index.
    ///
    /// That one line is what makes an odd-length array work. `[3] 0 d` is
    /// three on, three off, three on -- one entry that changes meaning each
    /// time round -- and `[2 4 6] 0 d` has a period of six entries rather than
    /// three, because the second pass through it starts off rather than on
    /// (§8.4.3.6). Toggling on the index instead would make both of those draw
    /// a solid line.
    fn advance(d: *Dasher) void {
        d.index = (d.index + 1) % d.params.dash.len;
        d.on = !d.on;
        d.remaining = d.params.dash[d.index];
    }

    fn apply(d: *Dasher, gpa: Allocator, input: Flattened) Error!void {
        defer d.run.deinit(gpa);
        for (input.subpaths) |s| {
            const pts = s.slice(input.points);
            if (pts.len < 2) {
                // A dot survives dashing only if the pattern starts on.
                d.reset();
                if (d.on and pts.len == 1) try strokeRun(gpa, d.out, pts, false, d.params);
                continue;
            }
            // The phase restarts at the beginning of every subpath (§8.4.3.6),
            // which is why a dashed rectangle has a dash starting at each
            // corner it was drawn from rather than one continuous pattern.
            d.reset();
            d.run.clearRetainingCapacity();

            const n = pts.len;
            const segments = if (s.closed) n else n - 1;
            var i: usize = 0;
            while (i < segments) : (i += 1) {
                try d.walk(gpa, pts[i], pts[(i + 1) % n]);
            }
            try d.flush(gpa);
        }
    }

    fn walk(d: *Dasher, gpa: Allocator, a: Vertex, b: Vertex) Error!void {
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const len = @sqrt(dx * dx + dy * dy);
        if (!(len > 0) or !std.math.isFinite(len)) return;

        var travelled: f32 = 0;
        if (d.on and d.run.items.len == 0) try d.push(gpa, a);

        while (travelled < len) {
            // A zero-length entry in the middle of a pattern -- `[3 0 3] 0 d`,
            // which draws a dot between dashes -- has to advance the state
            // without consuming any of the segment, or this loop never ends.
            if (d.remaining <= 0) {
                try d.boundary(gpa, a, b, travelled / len);
                d.advance();
                continue;
            }
            const step = @min(d.remaining, len - travelled);
            travelled += step;
            d.remaining -= step;
            if (d.remaining <= 0 and travelled < len) {
                try d.boundary(gpa, a, b, travelled / len);
                d.advance();
            }
        }

        if (d.on) try d.push(gpa, b);
    }

    /// Reached the end of a dash entry part-way along a segment: emit the
    /// point, and either close the run that was on or open the next one.
    fn boundary(d: *Dasher, gpa: Allocator, a: Vertex, b: Vertex, t: f32) Error!void {
        const p: Vertex = .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
        if (d.on) {
            try d.push(gpa, p);
            try d.flush(gpa);
        } else {
            d.run.clearRetainingCapacity();
            try d.push(gpa, p);
        }
    }

    fn push(d: *Dasher, gpa: Allocator, v: Vertex) Error!void {
        if (d.run.items.len >= max_run) return error.TooManyPoints;
        if (d.run.items.len > 0) {
            const last = d.run.items[d.run.items.len - 1];
            if (last.x == v.x and last.y == v.y) return;
        }
        try d.run.append(gpa, v);
    }

    /// Strokes whatever has accumulated. Every dash is an open subpath and
    /// gets the line cap at both ends, which is what makes a round-capped
    /// dashed line a row of lozenges rather than a row of rectangles.
    fn flush(d: *Dasher, gpa: Allocator) Error!void {
        if (d.run.items.len >= 1) {
            try strokeRun(gpa, d.out, d.run.items, false, d.params);
        }
        d.run.clearRetainingCapacity();
    }
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// Strokes a polyline and returns the filled region as a predicate, which is
/// the only thing about a stroke worth asserting: not how many triangles it
/// took, but which points ended up inside.
const Stroked = struct {
    flattener: Flattener,
    flat: Flattened,

    fn init(gpa: Allocator, pts: []const [2]f32, closed: bool, p: Params) !Stroked {
        var in: Flattener = .init(.{});
        defer in.deinit(gpa);
        try in.moveTo(gpa, .{ .x = pts[0][0], .y = pts[0][1] });
        for (pts[1..]) |q| try in.lineTo(gpa, .{ .x = q[0], .y = q[1] });
        if (closed) try in.close(gpa);
        const input = try in.finish(gpa);

        var s: Stroked = .{ .flattener = .init(.{}), .flat = undefined };
        errdefer s.flattener.deinit(gpa);
        try outline(gpa, &s.flattener, input, p);
        s.flat = try s.flattener.finish(gpa);
        return s;
    }

    fn deinit(s: *Stroked, gpa: Allocator) void {
        s.flattener.deinit(gpa);
    }

    /// Strokes are always filled nonzero. See `outline`.
    fn has(s: Stroked, x: f32, y: f32) bool {
        return s.flat.contains(x, y, .nonzero);
    }
};

test "a horizontal line becomes a rectangle of the right thickness" {
    const gpa = testing.allocator;
    var s = try Stroked.init(gpa, &.{ .{ 0, 50 }, .{ 100, 50 } }, false, .{ .width = 10 });
    defer s.deinit(gpa);

    try testing.expect(s.has(50, 50));
    try testing.expect(s.has(50, 46));
    try testing.expect(s.has(50, 54));
    try testing.expect(!s.has(50, 44));
    try testing.expect(!s.has(50, 56));
    // Butt caps: nothing past the ends.
    try testing.expect(!s.has(-1, 50));
    try testing.expect(!s.has(101, 50));
}

test "caps put back exactly what the spec says they do" {
    const gpa = testing.allocator;

    var butt = try Stroked.init(gpa, &.{ .{ 20, 50 }, .{ 80, 50 } }, false, .{ .width = 10, .cap = .butt });
    defer butt.deinit(gpa);
    var round = try Stroked.init(gpa, &.{ .{ 20, 50 }, .{ 80, 50 } }, false, .{ .width = 10, .cap = .round });
    defer round.deinit(gpa);
    var square = try Stroked.init(gpa, &.{ .{ 20, 50 }, .{ 80, 50 } }, false, .{ .width = 10, .cap = .square });
    defer square.deinit(gpa);

    // Just past the end, on the axis: butt stops, the other two continue.
    try testing.expect(!butt.has(83, 50));
    try testing.expect(round.has(83, 50));
    try testing.expect(square.has(83, 50));

    // The corner of the square cap, which is outside the round one: at
    // (84, 54) the distance from the endpoint is 5.66, past the radius of 5.
    try testing.expect(!round.has(84, 54));
    try testing.expect(square.has(84, 54));

    // And neither goes past half a width.
    try testing.expect(!square.has(86, 50));
    try testing.expect(!round.has(86, 50));
}

test "a miter reaches past the corner and a bevel does not" {
    const gpa = testing.allocator;
    const corner = [_][2]f32{ .{ 20, 20 }, .{ 80, 20 }, .{ 80, 80 } };

    var mitered = try Stroked.init(gpa, &corner, false, .{ .width = 10, .join = .miter });
    defer mitered.deinit(gpa);
    var bevelled = try Stroked.init(gpa, &corner, false, .{ .width = 10, .join = .bevel });
    defer bevelled.deinit(gpa);
    var rounded = try Stroked.init(gpa, &corner, false, .{ .width = 10, .join = .round });
    defer rounded.deinit(gpa);

    // The outside of this corner is up and to the right of (80, 20). A miter
    // on a right angle reaches to (85, 15) exactly; a bevel cuts that corner
    // off and a round join arcs inside it.
    try testing.expect(mitered.has(84, 16));
    try testing.expect(!bevelled.has(84, 16));
    try testing.expect(!rounded.has(84, 16));

    // All three agree about the inside of the corner and about the parts of
    // the line away from it.
    for ([_]*const Stroked{ &mitered, &bevelled, &rounded }) |st| {
        try testing.expect(st.has(50, 20));
        try testing.expect(st.has(80, 50));
        try testing.expect(st.has(78, 22));
        try testing.expect(!st.has(50, 50));
    }
}

test "the miter limit turns a spike into a bevel" {
    const gpa = testing.allocator;
    // A very sharp return: the two segments meet at about 4 degrees, so the
    // miter would be roughly 1/sin(2 deg) = 28 line widths long.
    const spike = [_][2]f32{ .{ 0, 50 }, .{ 200, 50 }, .{ 0, 64 } };

    var long = try Stroked.init(gpa, &spike, false, .{ .width = 10, .join = .miter, .miter_limit = 40 });
    defer long.deinit(gpa);
    var clipped = try Stroked.init(gpa, &spike, false, .{ .width = 10, .join = .miter, .miter_limit = 10 });
    defer clipped.deinit(gpa);

    // How far the outline reaches past the corner at x = 200 is the whole
    // question, and it is a more honest assertion than a point picked by hand:
    // the spike's axis is barely off the horizontal, so guessing a point
    // inside a 143-unit-long sliver two units tall is guessing.
    //
    // 1/sin(2 deg) is 28.6 line widths, or 143 units at a width of 10, so the
    // miter should reach about x = 343 and the bevel should stop at the corner.
    try testing.expect(long.flat.bounds.max_x > 330);
    try testing.expect(clipped.flat.bounds.max_x < 210);

    // A point well past the corner and inside the sliver. Neither segment's
    // own rectangle reaches x = 240 -- the first ends at 200 with a butt cap
    // and the second runs the other way -- so only the miter can put it there.
    try testing.expect(long.has(240, 48));
    try testing.expect(!clipped.has(240, 48));

    // Both still draw the lines themselves.
    try testing.expect(long.has(100, 50));
    try testing.expect(clipped.has(100, 50));
}

test "a closed subpath is joined at the seam rather than capped" {
    const gpa = testing.allocator;
    const square = [_][2]f32{ .{ 20, 20 }, .{ 80, 20 }, .{ 80, 80 }, .{ 20, 80 } };

    var closed = try Stroked.init(gpa, &square, true, .{ .width = 10, .join = .miter });
    defer closed.deinit(gpa);
    var open = try Stroked.init(gpa, &square, false, .{ .width = 10, .join = .miter, .cap = .butt });
    defer open.deinit(gpa);

    // The seam is at (20, 20). Closed, it is a mitered corner reaching to
    // (15, 15); open, the subpath starts and ends there with butt caps and
    // that corner is empty.
    try testing.expect(closed.has(16, 16));
    try testing.expect(!open.has(16, 16));

    // Closed also draws the fourth side, which the open one leaves out.
    try testing.expect(closed.has(20, 50));
    try testing.expect(!open.has(20, 50));

    // Neither fills the middle. A stroke is a ring.
    try testing.expect(!closed.has(50, 50));
}

test "a stroke that doubles back on itself does not punch a hole in itself" {
    // The case that would break even-odd, and the reason `outline` documents
    // that its result is nonzero-only. Two segments lying on top of each other
    // overlap everywhere; under even-odd the overlap would cancel and the line
    // would vanish.
    const gpa = testing.allocator;
    var s = try Stroked.init(gpa, &.{ .{ 20, 50 }, .{ 80, 50 }, .{ 20, 50 } }, false, .{ .width = 10 });
    defer s.deinit(gpa);

    try testing.expect(s.has(50, 50));
    try testing.expect(s.has(30, 52));
    try testing.expect(!s.flat.contains(50, 50, .even_odd));
}

test "a lone point is a dot only when the cap says so" {
    const gpa = testing.allocator;

    for ([_]struct { cap: Cap, marks: bool }{
        .{ .cap = .butt, .marks = false },
        .{ .cap = .round, .marks = true },
        .{ .cap = .square, .marks = true },
    }) |c| {
        var s = try Stroked.init(gpa, &.{.{ 50, 50 }}, false, .{ .width = 10, .cap = c.cap });
        defer s.deinit(gpa);
        try testing.expectEqual(c.marks, s.has(50, 50));
    }
}

test "a zero-length closed subpath marks nothing with butt caps" {
    // `10 10 m 10 10 l h S`. Generators emit it to draw conditionally, and a
    // reader that puts a dot there covers whatever was underneath.
    const gpa = testing.allocator;
    var s = try Stroked.init(gpa, &.{ .{ 10, 10 }, .{ 10, 10 } }, true, .{ .width = 8, .cap = .butt });
    defer s.deinit(gpa);
    try testing.expect(!s.has(10, 10));
}

test "dashes leave gaps where the pattern says and nowhere else" {
    const gpa = testing.allocator;
    const dash = [_]f32{ 10, 10 };
    var s = try Stroked.init(gpa, &.{ .{ 0, 50 }, .{ 100, 50 } }, false, .{
        .width = 6,
        .dash = &dash,
        .cap = .butt,
    });
    defer s.deinit(gpa);

    // on [0,10) off [10,20) on [20,30) ...
    try testing.expect(s.has(5, 50));
    try testing.expect(!s.has(15, 50));
    try testing.expect(s.has(25, 50));
    try testing.expect(!s.has(35, 50));
    try testing.expect(s.has(45, 50));
    // Still the right thickness inside a dash.
    try testing.expect(s.has(5, 52));
    try testing.expect(!s.has(5, 54));
}

test "the dash phase shifts the pattern" {
    const gpa = testing.allocator;
    const dash = [_]f32{ 10, 10 };
    var s = try Stroked.init(gpa, &.{ .{ 0, 50 }, .{ 100, 50 } }, false, .{
        .width = 6,
        .dash = &dash,
        .dash_phase = 10,
        .cap = .butt,
    });
    defer s.deinit(gpa);

    // Ten units in, so the pattern starts in its off entry.
    try testing.expect(!s.has(5, 50));
    try testing.expect(s.has(15, 50));
    try testing.expect(!s.has(25, 50));
}

test "an odd dash array swaps its phases every pass" {
    // `[3] 0 d` is three on, three off, three on: the array repeats with on
    // and off exchanged, which is what makes an odd length legal at all.
    const gpa = testing.allocator;
    const dash = [_]f32{3};
    var s = try Stroked.init(gpa, &.{ .{ 0, 50 }, .{ 30, 50 } }, false, .{
        .width = 4,
        .dash = &dash,
        .cap = .butt,
    });
    defer s.deinit(gpa);

    try testing.expect(s.has(1.5, 50));
    try testing.expect(!s.has(4.5, 50));
    try testing.expect(s.has(7.5, 50));
    try testing.expect(!s.has(10.5, 50));
}

test "a dash pattern that cannot be walked draws a solid line instead" {
    const gpa = testing.allocator;

    // All three unusable forms from the spec, plus one that would hang.
    const cases = [_][]const f32{
        &.{ 0, 0 },
        &.{-4},
        &.{ 5, std.math.nan(f32) },
    };
    for (cases) |d| {
        var s = try Stroked.init(gpa, &.{ .{ 0, 50 }, .{ 100, 50 } }, false, .{ .width = 6, .dash = d });
        defer s.deinit(gpa);
        try testing.expect(s.has(15, 50));
        try testing.expect(s.has(55, 50));
    }
}

test "a huge dash phase is taken modulo rather than walked" {
    // A hang, not a wrong answer, if the phase is consumed one entry at a
    // time. Real files carry phases in the millions from generators that
    // accumulate them.
    const gpa = testing.allocator;
    const dash = [_]f32{ 10, 10 };
    var s = try Stroked.init(gpa, &.{ .{ 0, 50 }, .{ 40, 50 } }, false, .{
        .width = 6,
        .dash = &dash,
        .dash_phase = 1e9,
        .cap = .butt,
    });
    defer s.deinit(gpa);
    // Whatever phase it lands on, it drew something and came back.
    try testing.expect(s.has(5, 50) or s.has(15, 50));
}

test "a zero entry in the middle of a pattern terminates" {
    const gpa = testing.allocator;
    const dash = [_]f32{ 5, 0, 5 };
    var s = try Stroked.init(gpa, &.{ .{ 0, 50 }, .{ 60, 50 } }, false, .{ .width = 4, .dash = &dash });
    defer s.deinit(gpa);
    try testing.expect(s.has(2, 50));
}

test "a zero width resolves to one device pixel" {
    try testing.expectEqual(@as(f32, 1), resolveWidth(0, 1));
    try testing.expectEqual(@as(f32, 0.25), resolveWidth(0, 4));
    // A given width is left alone whatever the scale.
    try testing.expectEqual(@as(f32, 3), resolveWidth(3, 4));
    // And a nonsense one is treated as zero rather than propagated.
    try testing.expectEqual(@as(f32, 1), resolveWidth(std.math.nan(f32), 1));
    try testing.expect(resolveWidth(-2, 1) == 1);
}

test "round joins get finer as the pen gets bigger" {
    // The count is driven by the sagitta, so it grows with the square root of
    // the radius: a pen ten times wider needs about three times the sides.
    const small = circleSegments(1, 0.1);
    const big = circleSegments(100, 0.1);
    try testing.expect(big > small);
    try testing.expect(big <= 128);
    try testing.expect(circleSegments(0, 0.1) == 4);
    try testing.expect(circleSegments(std.math.inf(f32), 0.1) == 4);
}

test "the stroke of a closed square is a ring with the right bounds" {
    const gpa = testing.allocator;
    var s = try Stroked.init(gpa, &.{
        .{ 20, 20 }, .{ 80, 20 }, .{ 80, 80 }, .{ 20, 80 },
    }, true, .{ .width = 10, .join = .miter });
    defer s.deinit(gpa);

    // A mitered right angle reaches exactly half a width diagonally, so the
    // outline runs from 15 to 85 on both axes.
    try testing.expectApproxEqAbs(@as(f32, 15), s.flat.bounds.min_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 15), s.flat.bounds.min_y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 85), s.flat.bounds.max_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 85), s.flat.bounds.max_y, 0.001);
}

test "every stamp is wound the same way" {
    // The invariant `emit` exists to keep. If one piece comes out reversed,
    // nonzero subtracts it wherever it overlaps another, and the symptom is a
    // notch in a stroke somewhere far from the code that produced it.
    const gpa = testing.allocator;
    var s = try Stroked.init(gpa, &.{
        .{ 10, 10 }, .{ 90, 30 }, .{ 40, 80 }, .{ 95, 95 },
    }, true, .{ .width = 12, .join = .round, .cap = .round });
    defer s.deinit(gpa);

    for (s.flat.subpaths) |sub| {
        const pts = sub.slice(s.flat.points);
        try testing.expect(pts.len >= 3);
        try testing.expect(signedArea(pts) > 0);
    }
}
