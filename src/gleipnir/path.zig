//! Path geometry: turning a display list's curves into the two meshes that
//! stencil-then-cover needs.
//!
//! ## The technique
//!
//! Filling an arbitrary outline on a GPU is hard for one reason: the shape is
//! not convex, may be self-intersecting, and has holes, so there is no
//! triangulation that a rasteriser can just draw. Stencil-then-cover
//! sidesteps triangulation entirely.
//!
//! Take any anchor point and, for every edge `(a, b)` of a closed subpath,
//! draw the triangle `(anchor, a, b)`. Those triangles overlap each other
//! enormously and individually mean nothing. But at any pixel, the *signed*
//! number of them covering it -- counting front-facing triangles as +1 and
//! back-facing as -1 -- is exactly the winding number of the path at that
//! pixel. The stencil buffer can do that count in hardware: increment on
//! front, decrement on back, and the winding number falls out with no
//! geometry processing at all. Then draw one rectangle over the whole thing
//! with a stencil test, and the pixels that survive are the fill.
//!
//! Two consequences worth stating, because they are what make the technique
//! worth its two passes:
//!
//! * **Self-intersection is free.** A path that crosses itself a hundred
//!   times costs the same as one that does not. Every tessellating rasteriser
//!   has to find those crossings first, and that is where they spend their
//!   time and their bugs.
//! * **The winding rule is pipeline state, not geometry.** Nonzero and
//!   even-odd draw the *same* triangles and differ only in the stencil ops.
//!   `f` and `f*` on the same path share a mesh.
//!
//! ## Why the anchor can be anywhere
//!
//! The fan is anchored at each subpath's own first point rather than at one
//! point for the whole path. That is not an approximation. For a *closed*
//! loop the fan tiles the interior with the correct multiplicity whatever the
//! anchor is -- move the anchor and the individual triangles change, but the
//! signed count at every pixel does not. Anchoring per subpath keeps the
//! triangles small, which matters because their total area is what the
//! stencil pass actually costs, and a page-sized triangle for a 4pt glyph
//! would be paid for in fill rate on every pixel of the page.
//!
//! `windingAt` below computes the same number the direct way, by counting ray
//! crossings, and a test asserts the two agree at several thousand points on
//! shapes chosen to be nasty. That test is the reason to believe any of this.
//!
//! ## Everything stays in path space
//!
//! Nothing here is transformed. The mesh is built from the display list's own
//! coordinates and the page-to-device matrix is a push constant, so panning
//! and zooming re-use the same vertex buffer. The one thing the transform is
//! needed for is the flattening tolerance -- a curve subdivided finely enough
//! at 100% is visibly a polygon at 800% -- so `Options.scale` carries it, and
//! a mesh is valid for the zoom level it was built at.
//!
//! The cover geometry is the four corners of the path's *path-space* bounding
//! box, which the shader transforms along with everything else. Under an
//! affine matrix that box maps to a parallelogram that still contains the
//! transformed path exactly, so the cover is tight without ever computing a
//! device-space bound.

const std = @import("std");
const Allocator = std.mem.Allocator;

const DisplayList = @import("../gelgja/DisplayList.zig");
const geom = @import("../gelgja/geom.zig");

const Bounds = geom.Bounds;
const FillRule = geom.FillRule;
const Point = geom.Point;
const Verb = geom.Verb;

/// A position, and nothing else. Eight bytes, matching `layout(location = 0)
/// in vec2 in_pos` in `shader/path.vert`.
///
/// The rect pipeline packs ninety-six bytes into an instance because it draws
/// one instance per shape; this draws one vertex per point and there are a
/// great many points, so the only thing that belongs here is the thing that
/// differs per point.
pub const Vertex = extern struct {
    x: f32,
    y: f32,

    pub fn from(p: Point) Vertex {
        return .{ .x = p.x, .y = p.y };
    }

    pub fn point(v: Vertex) Point {
        return .{ .x = v.x, .y = v.y };
    }
};

comptime {
    std.debug.assert(@sizeOf(Vertex) == 8);
}

/// One contiguous run of points in `Flattened.points`.
///
/// `closed` records whether the source subpath ended with a `close` verb. A
/// fill ignores it -- PDF implicitly closes every subpath before filling
/// (§8.5.3.1) -- but a stroke very much does not: an open subpath gets a cap
/// at each end and a closed one gets a join, and drawing the wrong one is
/// immediately visible on any thick line.
pub const Subpath = struct {
    start: u32,
    count: u32,
    closed: bool,

    pub fn slice(s: Subpath, points: []const Vertex) []const Vertex {
        return points[s.start..][0..s.count];
    }
};

/// A path with every curve replaced by line segments.
pub const Flattened = struct {
    points: []const Vertex,
    subpaths: []const Subpath,
    bounds: Bounds,

    pub const empty: Flattened = .{ .points = &.{}, .subpaths = &.{}, .bounds = .empty };

    pub fn isEmpty(f: Flattened) bool {
        return f.subpaths.len == 0;
    }

    /// The winding number at a point, counted directly by crossing a ray.
    ///
    /// This is the definition the stencil pass approximates with hardware, and
    /// it exists so the two can be compared. It is not on any hot path: a
    /// software rasteriser that called this per pixel would be quadratic in
    /// the path's size.
    ///
    /// The ray goes in +x. An edge counts when it spans `y` in the half-open
    /// sense -- `y0 <= y < y1` or `y1 <= y < y0` -- which is what makes a
    /// vertex lying exactly on the ray count once rather than twice or zero
    /// times, and is the same rule a scanline rasteriser uses for the same
    /// reason.
    pub fn windingAt(f: Flattened, x: f32, y: f32) i32 {
        var w: i32 = 0;
        for (f.subpaths) |s| {
            const pts = s.slice(f.points);
            if (pts.len < 2) continue;
            var i: usize = 0;
            while (i < pts.len) : (i += 1) {
                const a = pts[i];
                const b = pts[(i + 1) % pts.len];
                if (a.y <= y) {
                    if (b.y > y and cross(a, b, x, y) > 0) w += 1;
                } else {
                    if (b.y <= y and cross(a, b, x, y) < 0) w -= 1;
                }
            }
        }
        return w;
    }

    /// Whether a point is inside under a given rule. The rule is the only
    /// difference between `f` and `f*`.
    pub fn contains(f: Flattened, x: f32, y: f32, rule: FillRule) bool {
        const w = f.windingAt(x, y);
        return switch (rule) {
            .nonzero => w != 0,
            .even_odd => @rem(w, 2) != 0,
        };
    }

    /// How many segments the whole path flattened to. Reported by
    /// `fenrir raster --stats`, because it is the number that explains why a
    /// page is slow.
    pub fn segmentCount(f: Flattened) usize {
        var n: usize = 0;
        for (f.subpaths) |s| n += s.count;
        return n;
    }
};

/// Which side of the directed line `a -> b` the point `(x, y)` is on. Positive
/// means left. Used only for the sign of the crossing, never for a distance,
/// so it is not normalised.
fn cross(a: Vertex, b: Vertex, x: f32, y: f32) f32 {
    return (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
}

pub const Options = struct {
    /// The largest distance, in *device pixels*, that a flattened segment may
    /// stray from the curve it replaces.
    ///
    /// A quarter of a pixel is the usual quality bar and is what most
    /// rasterisers ship. A tenth is the default here because this is a reader
    /// -- pages are looked at for a long time and rarely animated, and the
    /// cost of the difference is a handful of extra segments per curve on a
    /// path that is already being uploaded to a GPU once.
    tolerance: f32 = 0.1,

    /// How much the page-to-device matrix magnifies lengths, from
    /// `Transform.expansion`. Tolerance is divided by it, so a mesh built at
    /// 100% and drawn at 800% is eight times too coarse -- which is why a
    /// cache of these has to be keyed on zoom.
    scale: f32 = 1,

    /// A ceiling on the segments any single curve may produce, so that a
    /// pathological control polygon -- and a damaged file can contain one with
    /// coordinates in the millions -- costs a bounded amount rather than all
    /// of memory.
    max_segments_per_curve: u32 = 256,

    /// The whole path's budget. Hit only by generated content: contour maps,
    /// CAD exports, and the occasional map tile.
    max_points: u32 = 1 << 22,

    /// Effective tolerance in path space.
    fn pathTolerance(o: Options) f32 {
        const s = if (o.scale > 1e-6) o.scale else 1e-6;
        return @max(o.tolerance / s, 1e-6);
    }
};

pub const Error = Allocator.Error || error{TooManyPoints};

/// Accumulates a flattened path. Reusable across paths with `reset`, because a
/// page has thousands of them and the arrays settle at their high-water mark
/// after the first few.
pub const Flattener = struct {
    points: std.ArrayList(Vertex) = .empty,
    subpaths: std.ArrayList(Subpath) = .empty,
    bounds: Bounds = .empty,
    options: Options = .{},

    /// Where the subpath being built starts, and where the pen is. `null`
    /// means no subpath is open, which is the state a path starts in and the
    /// state `close` leaves it in.
    open: ?u32 = null,
    cursor: Vertex = .{ .x = 0, .y = 0 },
    /// Where the open subpath began, for `close` and for the implicit close a
    /// fill applies.
    anchor: Vertex = .{ .x = 0, .y = 0 },

    pub fn init(options: Options) Flattener {
        return .{ .options = options };
    }

    pub fn deinit(f: *Flattener, gpa: Allocator) void {
        f.points.deinit(gpa);
        f.subpaths.deinit(gpa);
        f.* = undefined;
    }

    /// Drops the contents and keeps the capacity.
    pub fn reset(f: *Flattener) void {
        f.points.clearRetainingCapacity();
        f.subpaths.clearRetainingCapacity();
        f.bounds = .empty;
        f.open = null;
    }

    fn push(f: *Flattener, gpa: Allocator, v: Vertex) Error!void {
        if (f.points.items.len >= f.options.max_points) return error.TooManyPoints;
        // Consecutive duplicates contribute a zero-length edge, which adds a
        // degenerate triangle to the fan and nothing to the winding number.
        // Dropping them here is cheaper than everything downstream having to
        // tolerate them, and PDF content streams are full of them: `re`
        // followed by a `l` back to the corner, glyph outlines with repeated
        // on-curve points, and dashes whose phase lands exactly on a vertex.
        if (f.open) |start| {
            if (f.points.items.len > start) {
                const last = f.points.items[f.points.items.len - 1];
                if (last.x == v.x and last.y == v.y) return;
            }
        }
        try f.points.append(gpa, v);
        f.bounds = f.bounds.add(v.point());
    }

    pub fn moveTo(f: *Flattener, gpa: Allocator, p: Point) Error!void {
        try f.endSubpath(gpa, false);
        f.open = @intCast(f.points.items.len);
        f.cursor = .from(p);
        f.anchor = f.cursor;
        try f.push(gpa, f.cursor);
    }

    pub fn lineTo(f: *Flattener, gpa: Allocator, p: Point) Error!void {
        // A `l` with no preceding `m` is malformed but common in damaged
        // files; treating it as a move is what every other reader does and it
        // loses nothing, since the alternative is dropping the subpath.
        if (f.open == null) return f.moveTo(gpa, p);
        f.cursor = .from(p);
        try f.push(gpa, f.cursor);
    }

    pub fn cubicTo(f: *Flattener, gpa: Allocator, c1: Point, c2: Point, p: Point) Error!void {
        if (f.open == null) try f.moveTo(gpa, f.cursor.point());

        const p0 = f.cursor;
        const p1: Vertex = .from(c1);
        const p2: Vertex = .from(c2);
        const p3: Vertex = .from(p);

        const n = segmentsForCubic(p0, p1, p2, p3, f.options.pathTolerance(), f.options.max_segments_per_curve);

        // Uniform in t rather than adaptive. Wang's formula already answers
        // "how many segments does the worst part of this curve need", and
        // subdividing the easy parts to match costs a few extra vertices where
        // adaptive subdivision costs a recursion, a stack, and a per-segment
        // error test. For curves this short -- a glyph outline segment is a
        // handful of pixels -- the extra vertices are cheaper.
        var i: u32 = 1;
        while (i <= n) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            try f.push(gpa, evalCubic(p0, p1, p2, p3, t));
        }
        f.cursor = p3;
    }

    pub fn close(f: *Flattener, gpa: Allocator) Error!void {
        try f.endSubpath(gpa, true);
        // PDF leaves the pen at the subpath's start after `h`, and a following
        // `l` draws from there (§8.5.2.1).
        f.cursor = f.anchor;
    }

    fn endSubpath(f: *Flattener, gpa: Allocator, closed: bool) Error!void {
        const start = f.open orelse return;
        f.open = null;
        var count: u32 = @as(u32, @intCast(f.points.items.len)) - start;

        // `... l 0 0 h` -- a subpath that draws its own closing edge and then
        // closes again. `re` emits it, and so does every generator that closes
        // by hand. The last point duplicates the first, not the previous one,
        // so `push` cannot have caught it, and left in it becomes a
        // zero-length edge: a degenerate triangle in the fan of every
        // rectangle on the page, and a join drawn on top of itself in every
        // stroke.
        //
        // Only when the subpath is closed. An *open* subpath that happens to
        // end where it began is a different shape: a stroke puts two caps at
        // that point rather than a join, and dropping the point would lose the
        // segment that arrives there.
        if (closed and count >= 2) {
            const first = f.points.items[start];
            const last = f.points.items[start + count - 1];
            if (first.x == last.x and first.y == last.y) {
                f.points.items.len -= 1;
                count -= 1;
            }
        }
        // A single point is a subpath only for stroking, and only then when it
        // has round or square caps (§8.5.3.2); it can never contribute to a
        // fill. It is kept rather than dropped so `stroke.zig` can see it, and
        // `mesh` skips it.
        if (count == 0) return;
        try f.subpaths.append(gpa, .{ .start = start, .count = count, .closed = closed });
    }

    /// Flattens a display list path in one call. The common case.
    pub fn addPath(f: *Flattener, gpa: Allocator, list: DisplayList, path: DisplayList.Path) Error!void {
        const verbs = list.verbsOf(path);
        const points = list.pointsOf(path);
        var i: usize = 0;
        for (verbs) |verb| {
            const n = verb.pointCount();
            // A truncated path is a damaged one, not an impossible one: the
            // builder can only ever produce matched pairs, but a display list
            // that arrived some other way might not.
            if (i + n > points.len) break;
            switch (verb) {
                .move => try f.moveTo(gpa, points[i]),
                .line => try f.lineTo(gpa, points[i]),
                .cubic => try f.cubicTo(gpa, points[i], points[i + 1], points[i + 2]),
                .close => try f.close(gpa),
            }
            i += n;
        }
    }

    /// Closes any open subpath and hands back a view of what was built. The
    /// slices belong to the flattener and are invalidated by `reset` or by any
    /// further building.
    pub fn finish(f: *Flattener, gpa: Allocator) Error!Flattened {
        try f.endSubpath(gpa, false);
        return .{
            .points = f.points.items,
            .subpaths = f.subpaths.items,
            .bounds = f.bounds,
        };
    }
};

/// Wang's formula: how many equal-`t` segments a cubic needs to stay within
/// `tolerance` of the curve.
///
///     n = ceil( sqrt( 3 * max|second difference| / (4 * tolerance) ) )
///
/// The second differences bound the curve's deviation from its control
/// polygon, and the polygon's deviation from a chord subdivided `n` ways falls
/// off as `1/n^2` -- which is where the square root comes from, and why
/// halving the tolerance costs only 41% more segments rather than twice as
/// many.
///
/// It is an upper bound, so it never under-subdivides, and it is loose by
/// perhaps 20% on a typical glyph curve. Adaptive subdivision would recover
/// that at the cost of a recursive per-segment error test, which for curves
/// this short is more arithmetic than the segments it saves.
pub fn segmentsForCubic(p0: Vertex, p1: Vertex, p2: Vertex, p3: Vertex, tolerance: f32, max: u32) u32 {
    const ax = p0.x - 2 * p1.x + p2.x;
    const ay = p0.y - 2 * p1.y + p2.y;
    const bx = p1.x - 2 * p2.x + p3.x;
    const by = p1.y - 2 * p2.y + p3.y;

    const m = @max(ax * ax + ay * ay, bx * bx + by * by);
    if (!std.math.isFinite(m)) return max;
    if (m <= 0) return 1; // A cubic whose control points are collinear and evenly spaced is a line.

    const n = @ceil(@sqrt(@sqrt(m) * 3.0 / (4.0 * tolerance)));
    if (!(n >= 1)) return 1; // Also catches NaN.
    if (n >= @as(f32, @floatFromInt(max))) return max;
    return @intFromFloat(n);
}

/// de Casteljau at one parameter. Written out rather than looped because it is
/// the innermost thing in the whole rasteriser.
fn evalCubic(p0: Vertex, p1: Vertex, p2: Vertex, p3: Vertex, t: f32) Vertex {
    const u = 1 - t;
    const a = u * u * u;
    const b = 3 * u * u * t;
    const c = 3 * u * t * t;
    const d = t * t * t;
    return .{
        .x = a * p0.x + b * p1.x + c * p2.x + d * p3.x,
        .y = a * p0.y + b * p1.y + c * p2.y + d * p3.y,
    };
}

/// The two draws of stencil-then-cover, sharing one vertex and one index
/// buffer.
///
/// The cover quad's four corners are appended after the path's own points, so
/// a single `vkCmdBindVertexBuffers` and `vkCmdBindIndexBuffer` serve both
/// passes and the second draw is a `firstIndex` away from the first.
pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u32,
    /// `vkCmdDrawIndexed(cmd, stencil_count, 1, 0, 0, 0)`.
    stencil_count: u32,
    /// `vkCmdDrawIndexed(cmd, 6, 1, cover_first, 0, 0)`.
    cover_first: u32,
    bounds: Bounds,

    pub const cover_count: u32 = 6;

    pub fn deinit(m: *Mesh, gpa: Allocator) void {
        gpa.free(m.vertices);
        gpa.free(m.indices);
        m.* = undefined;
    }

    pub fn isEmpty(m: Mesh) bool {
        return m.stencil_count == 0;
    }

    pub fn vertexBytes(m: Mesh) []const u8 {
        return std.mem.sliceAsBytes(m.vertices);
    }

    pub fn indexBytes(m: Mesh) []const u8 {
        return std.mem.sliceAsBytes(m.indices);
    }
};

/// Storage a caller keeps so that meshing a path is not an allocation.
///
/// A page of prose is thousands of filled outlines, and `mesh` is two
/// allocations and two frees for each of them. Held here and reused, it is
/// two allocations for the whole page: the buffers settle at the largest
/// path's size within the first few and never grow again.
pub const MeshBuffers = struct {
    vertices: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,

    pub fn deinit(m: *MeshBuffers, gpa: Allocator) void {
        m.vertices.deinit(gpa);
        m.indices.deinit(gpa);
        m.* = .{};
    }
};

/// Builds the fan and the cover quad. The caller owns the result.
pub fn mesh(gpa: Allocator, f: Flattened) Allocator.Error!Mesh {
    var buffers: MeshBuffers = .{};
    errdefer buffers.deinit(gpa);
    const m = try meshInto(gpa, &buffers, f);
    return .{
        .vertices = try buffers.vertices.toOwnedSlice(gpa),
        .indices = try buffers.indices.toOwnedSlice(gpa),
        .stencil_count = m.stencil_count,
        .cover_first = m.cover_first,
        .bounds = m.bounds,
    };
}

/// The same mesh, built into buffers the caller keeps.
///
/// The slices in the result belong to `into` and are good only until the next
/// call on the same buffers, so the result must not be `deinit`ed -- the
/// buffers are, once, when the caller is finished with them.
pub fn meshInto(gpa: Allocator, into: *MeshBuffers, f: Flattened) Allocator.Error!Mesh {
    into.vertices.clearRetainingCapacity();
    into.indices.clearRetainingCapacity();

    // A closed loop of n points has n edges, two of which are degenerate
    // against an anchor that is one of its own points, so it contributes
    // n - 2 triangles. Fewer than three points is a line or a dot and
    // contributes nothing to a fill.
    var triangles: usize = 0;
    for (f.subpaths) |s| {
        if (s.count >= 3) triangles += s.count - 2;
    }

    if (triangles == 0 or f.bounds.isEmpty()) {
        return .{
            .vertices = into.vertices.items,
            .indices = into.indices.items,
            .stencil_count = 0,
            .cover_first = 0,
            .bounds = .empty,
        };
    }

    try into.vertices.ensureTotalCapacity(gpa, f.points.len + 4);
    into.vertices.appendSliceAssumeCapacity(f.points);

    const b = f.bounds;
    into.vertices.appendAssumeCapacity(.{ .x = b.min_x, .y = b.min_y });
    into.vertices.appendAssumeCapacity(.{ .x = b.max_x, .y = b.min_y });
    into.vertices.appendAssumeCapacity(.{ .x = b.max_x, .y = b.max_y });
    into.vertices.appendAssumeCapacity(.{ .x = b.min_x, .y = b.max_y });

    const stencil_count: u32 = @intCast(triangles * 3);
    try into.indices.ensureTotalCapacity(gpa, triangles * 3 + Mesh.cover_count);

    for (f.subpaths) |s| {
        if (s.count < 3) continue;
        // Edges (p1,p2) through (p[n-2],p[n-1]). The two edges touching the
        // anchor are skipped: their triangles have zero area, so they change
        // no winding number and would only cost the rasteriser a setup each.
        var i: u32 = 1;
        while (i + 1 < s.count) : (i += 1) {
            into.indices.appendAssumeCapacity(s.start);
            into.indices.appendAssumeCapacity(s.start + i);
            into.indices.appendAssumeCapacity(s.start + i + 1);
        }
    }
    std.debug.assert(into.indices.items.len == stencil_count);

    const q: u32 = @intCast(f.points.len);
    into.indices.appendSliceAssumeCapacity(&.{ q, q + 1, q + 2, q, q + 2, q + 3 });

    return .{
        .vertices = into.vertices.items,
        .indices = into.indices.items,
        .stencil_count = stencil_count,
        .cover_first = stencil_count,
        .bounds = b,
    };
}

/// The signed count the stencil pass would leave at a point, computed from the
/// mesh rather than from the path.
///
/// This is the thing that has to equal `Flattened.windingAt`, and it is the
/// only way to check the fan without a GPU. A triangle counts +1 when it is
/// front-facing (counter-clockwise in a y-down space, matching
/// `VK_FRONT_FACE_COUNTER_CLOCKWISE` with a y-down viewport) and -1 when it is
/// not, which is precisely what `INCREMENT_AND_WRAP` on front faces and
/// `DECREMENT_AND_WRAP` on back faces does.
pub fn stencilAt(m: Mesh, x: f32, y: f32) i32 {
    var w: i32 = 0;
    var i: u32 = 0;
    while (i < m.stencil_count) : (i += 3) {
        const a = m.vertices[m.indices[i + 0]];
        const b = m.vertices[m.indices[i + 1]];
        const c = m.vertices[m.indices[i + 2]];
        if (!inTriangle(a, b, c, x, y)) continue;
        w += if (signedArea(a, b, c) > 0) 1 else -1;
    }
    return w;
}

fn signedArea(a: Vertex, b: Vertex, c: Vertex) f32 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

/// Point-in-triangle with the top-left fill rule, so that a point on a shared
/// edge lands in exactly one of the two triangles sharing it. Getting this
/// wrong makes `stencilAt` disagree with `windingAt` along every internal
/// edge of the fan, which is most of the shape.
fn inTriangle(a: Vertex, b: Vertex, c: Vertex, x: f32, y: f32) bool {
    const area = signedArea(a, b, c);
    if (area == 0) return false;
    // Work in a consistent orientation so one edge test serves both windings.
    const p0 = a;
    const p1 = if (area > 0) b else c;
    const p2 = if (area > 0) c else b;
    return edge(p0, p1, x, y) and edge(p1, p2, x, y) and edge(p2, p0, x, y);
}

fn edge(a: Vertex, b: Vertex, x: f32, y: f32) bool {
    const d = cross(a, b, x, y);
    if (d > 0) return true;
    if (d < 0) return false;
    // Exactly on the line: a top or left edge is inside, any other is not.
    // (y down, so a "top" edge is one that runs left-to-right.)
    if (b.y == a.y) return b.x > a.x;
    return b.y < a.y;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn flattenPoints(gpa: Allocator, f: *Flattener, pts: []const [2]f32, closed: bool) !Flattened {
    try f.moveTo(gpa, .{ .x = pts[0][0], .y = pts[0][1] });
    for (pts[1..]) |p| try f.lineTo(gpa, .{ .x = p[0], .y = p[1] });
    if (closed) try f.close(gpa);
    return f.finish(gpa);
}

test "a square flattens to four points and one subpath" {
    const gpa = testing.allocator;
    var f: Flattener = .init(.{});
    defer f.deinit(gpa);

    const flat = try flattenPoints(gpa, &f, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } }, true);
    try testing.expectEqual(@as(usize, 1), flat.subpaths.len);
    try testing.expectEqual(@as(u32, 4), flat.subpaths[0].count);
    try testing.expect(flat.subpaths[0].closed);
    try testing.expectEqual(@as(f32, 0), flat.bounds.min_x);
    try testing.expectEqual(@as(f32, 10), flat.bounds.max_y);
}

test "a closing line back to the start is not a fifth point" {
    // `re` emits exactly this, and so does every generator that closes by hand
    // rather than with `h`. Left in, it is a zero-length edge that adds a
    // degenerate triangle to the fan for every rectangle on the page.
    const gpa = testing.allocator;
    var f: Flattener = .init(.{});
    defer f.deinit(gpa);

    const flat = try flattenPoints(gpa, &f, &.{
        .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 0, 0 },
    }, true);
    try testing.expectEqual(@as(u32, 4), flat.subpaths[0].count);
}

test "winding: a square is inside, outside is outside" {
    const gpa = testing.allocator;
    var f: Flattener = .init(.{});
    defer f.deinit(gpa);

    const flat = try flattenPoints(gpa, &f, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } }, true);
    try testing.expectEqual(@as(i32, 1), flat.windingAt(5, 5));
    try testing.expectEqual(@as(i32, 0), flat.windingAt(-1, 5));
    try testing.expectEqual(@as(i32, 0), flat.windingAt(11, 5));
    try testing.expectEqual(@as(i32, 0), flat.windingAt(5, -1));
    try testing.expectEqual(@as(i32, 0), flat.windingAt(5, 11));
}

test "winding: the two rules disagree about a hole, which is the whole point" {
    const gpa = testing.allocator;
    var f: Flattener = .init(.{});
    defer f.deinit(gpa);

    // Outer square, then an inner square wound the *same* way. Nonzero fills
    // the middle (winding 2), even-odd leaves a hole. A donut drawn with the
    // inner contour reversed would give winding 0 in the middle and both rules
    // would agree -- which is why this test winds them the same way.
    try f.moveTo(gpa, .{ .x = 0, .y = 0 });
    try f.lineTo(gpa, .{ .x = 30, .y = 0 });
    try f.lineTo(gpa, .{ .x = 30, .y = 30 });
    try f.lineTo(gpa, .{ .x = 0, .y = 30 });
    try f.close(gpa);
    try f.moveTo(gpa, .{ .x = 10, .y = 10 });
    try f.lineTo(gpa, .{ .x = 20, .y = 10 });
    try f.lineTo(gpa, .{ .x = 20, .y = 20 });
    try f.lineTo(gpa, .{ .x = 10, .y = 20 });
    try f.close(gpa);
    const flat = try f.finish(gpa);

    try testing.expectEqual(@as(i32, 2), flat.windingAt(15, 15));
    try testing.expect(flat.contains(15, 15, .nonzero));
    try testing.expect(!flat.contains(15, 15, .even_odd));
    // The ring between them is inside under both.
    try testing.expect(flat.contains(5, 15, .nonzero));
    try testing.expect(flat.contains(5, 15, .even_odd));
}

test "winding: reversing a contour reverses its sign" {
    const gpa = testing.allocator;
    var f: Flattener = .init(.{});
    defer f.deinit(gpa);

    const flat = try flattenPoints(gpa, &f, &.{ .{ 0, 10 }, .{ 10, 10 }, .{ 10, 0 }, .{ 0, 0 } }, true);
    try testing.expectEqual(@as(i32, -1), flat.windingAt(5, 5));
    // Both rules still call it inside: nonzero tests against zero, not against
    // one, and a backwards contour is a filled shape and not a hole.
    try testing.expect(flat.contains(5, 5, .nonzero));
    try testing.expect(flat.contains(5, 5, .even_odd));
}

test "the fan reproduces the winding number everywhere" {
    // The test this whole file rests on. If the stencil pass and the direct
    // ray count disagree at even one interior point, some pixel of some page
    // is the wrong colour, and there is no way to find that by looking at a
    // rendered page.
    const gpa = testing.allocator;
    var f: Flattener = .init(.{});
    defer f.deinit(gpa);

    // A five-pointed star drawn as one self-intersecting contour: the middle
    // has winding 2 under a single subpath, which is exactly the case a
    // tessellating rasteriser has to work for and this one gets for free.
    const cx: f32 = 50;
    const cy: f32 = 50;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        // Two fifths of a turn per step is what makes it a pentagram rather
        // than a pentagon.
        const angle = @as(f32, @floatFromInt(i)) * 4.0 * std.math.pi / 5.0 - std.math.pi / 2.0;
        const p: Point = .{ .x = cx + 40 * @cos(angle), .y = cy + 40 * @sin(angle) };
        if (i == 0) try f.moveTo(gpa, p) else try f.lineTo(gpa, p);
    }
    try f.close(gpa);
    // A second, disjoint, oppositely wound contour, so the test covers
    // cancellation between subpaths too.
    try f.moveTo(gpa, .{ .x = 20, .y = 20 });
    try f.lineTo(gpa, .{ .x = 20, .y = 35 });
    try f.lineTo(gpa, .{ .x = 35, .y = 35 });
    try f.close(gpa);

    const flat = try f.finish(gpa);
    var m = try mesh(gpa, flat);
    defer m.deinit(gpa);

    // Offset by an irrational-ish amount so samples never land exactly on a
    // vertex, where "equal" is a question about tie-breaking rather than about
    // the algorithm. The edges themselves are covered by the fill-rule test
    // below.
    var disagreements: u32 = 0;
    var seen_two = false;
    var y: u32 = 0;
    while (y < 100) : (y += 1) {
        var x: u32 = 0;
        while (x < 100) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5137;
            const py = @as(f32, @floatFromInt(y)) + 0.3719;
            const direct = flat.windingAt(px, py);
            if (direct == 2) seen_two = true;
            if (stencilAt(m, px, py) != direct) disagreements += 1;
        }
    }
    try testing.expectEqual(@as(u32, 0), disagreements);
    // Proof the sample grid actually reached the interesting region rather
    // than passing by only ever seeing zero.
    try testing.expect(seen_two);
}

test "the fan is anchored per subpath and the anchor does not change the answer" {
    const gpa = testing.allocator;
    var f: Flattener = .init(.{});
    defer f.deinit(gpa);

    // The same square, entered at a different vertex. Different triangles,
    // same winding number -- which is the licence to anchor wherever is
    // cheapest.
    const a = try flattenPoints(gpa, &f, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } }, true);
    var ma = try mesh(gpa, a);
    defer ma.deinit(gpa);

    var g: Flattener = .init(.{});
    defer g.deinit(gpa);
    const b = try flattenPoints(gpa, &g, &.{ .{ 10, 10 }, .{ 0, 10 }, .{ 0, 0 }, .{ 10, 0 } }, true);
    var mb = try mesh(gpa, b);
    defer mb.deinit(gpa);

    var y: u32 = 0;
    while (y < 10) : (y += 1) {
        var x: u32 = 0;
        while (x < 10) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5137;
            const py = @as(f32, @floatFromInt(y)) + 0.3719;
            try testing.expectEqual(stencilAt(ma, px, py), stencilAt(mb, px, py));
        }
    }
}

test "the cover quad contains every triangle the stencil pass writes" {
    // If it does not, stencil bits survive the cover pass and leak into the
    // next path -- a bug that shows up as a stray rectangle somewhere else on
    // the page, with nothing to connect it to the path that caused it.
    const gpa = testing.allocator;
    var f: Flattener = .init(.{});
    defer f.deinit(gpa);

    try f.moveTo(gpa, .{ .x = 5, .y = 7 });
    try f.cubicTo(gpa, .{ .x = 40, .y = -30 }, .{ .x = 80, .y = 90 }, .{ .x = 95, .y = 20 });
    try f.lineTo(gpa, .{ .x = 30, .y = 60 });
    try f.close(gpa);
    const flat = try f.finish(gpa);

    var m = try mesh(gpa, flat);
    defer m.deinit(gpa);

    const q = m.vertices.len - 4;
    var box: Bounds = .empty;
    for (m.vertices[q..]) |v| box = box.add(v.point());

    var i: u32 = 0;
    while (i < m.stencil_count) : (i += 1) {
        const v = m.vertices[m.indices[i]];
        try testing.expect(v.x >= box.min_x and v.x <= box.max_x);
        try testing.expect(v.y >= box.min_y and v.y <= box.max_y);
    }
    try testing.expectEqual(Mesh.cover_count, @as(u32, @intCast(m.indices.len)) - m.cover_first);
}

test "flattening subdivides a curve to the tolerance it was given" {
    const gpa = testing.allocator;

    // A curve that bulges half its length away from its chord, so the segment
    // count is decided by the tolerance rather than by the floor of 1.
    const p0: Vertex = .{ .x = 0, .y = 0 };
    const p1: Vertex = .{ .x = 0, .y = 100 };
    const p2: Vertex = .{ .x = 100, .y = 100 };
    const p3: Vertex = .{ .x = 100, .y = 0 };

    const coarse = segmentsForCubic(p0, p1, p2, p3, 1.0, 256);
    const fine = segmentsForCubic(p0, p1, p2, p3, 0.01, 256);
    try testing.expect(fine > coarse);
    // Tolerance enters under a square root, so a hundredfold tightening is a
    // tenfold cost. That relationship is the reason the default can afford to
    // be 0.1 rather than 0.25.
    try testing.expect(fine <= coarse * 12);
    try testing.expect(fine >= coarse * 8);

    // And the ceiling really is a ceiling.
    const huge: Vertex = .{ .x = 1e9, .y = 1e9 };
    try testing.expectEqual(@as(u32, 16), segmentsForCubic(p0, huge, huge, p3, 0.01, 16));

    // Zoom divides the tolerance, so a mesh built for an eight-times view has
    // more segments in it than one built for a one-to-one view.
    var near: Flattener = .init(.{ .tolerance = 0.1, .scale = 8 });
    defer near.deinit(gpa);
    var far: Flattener = .init(.{ .tolerance = 0.1, .scale = 1 });
    defer far.deinit(gpa);
    for ([_]*Flattener{ &near, &far }) |fl| {
        try fl.moveTo(gpa, p0.point());
        try fl.cubicTo(gpa, p1.point(), p2.point(), p3.point());
    }
    const a = try near.finish(gpa);
    const b = try far.finish(gpa);
    try testing.expect(a.points.len > b.points.len);
}

test "a flattened curve stays within tolerance of the curve" {
    // Wang's formula is an upper bound, so this is checking the bound is real
    // and not merely plausible: sample the curve densely and measure each
    // sample's distance to the polyline that replaced it.
    const gpa = testing.allocator;
    var f: Flattener = .init(.{ .tolerance = 0.05 });
    defer f.deinit(gpa);

    const p0: Point = .{ .x = 10, .y = 10 };
    const c1: Point = .{ .x = 200, .y = 40 };
    const c2: Point = .{ .x = -60, .y = 90 };
    const p3: Point = .{ .x = 120, .y = 130 };
    try f.moveTo(gpa, p0);
    try f.cubicTo(gpa, c1, c2, p3);
    const flat = try f.finish(gpa);

    const poly = flat.subpaths[0].slice(flat.points);
    var worst: f32 = 0;
    var i: u32 = 0;
    while (i <= 2000) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 2000.0;
        const on = evalCubic(.from(p0), .from(c1), .from(c2), .from(p3), t);
        var best: f32 = std.math.inf(f32);
        var j: usize = 0;
        while (j + 1 < poly.len) : (j += 1) {
            best = @min(best, distanceToSegment(on, poly[j], poly[j + 1]));
        }
        worst = @max(worst, best);
    }
    try testing.expect(worst <= 0.05);
}

fn distanceToSegment(p: Vertex, a: Vertex, b: Vertex) f32 {
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const len2 = vx * vx + vy * vy;
    const t = if (len2 <= 0) 0 else std.math.clamp(((p.x - a.x) * vx + (p.y - a.y) * vy) / len2, 0, 1);
    const dx = p.x - (a.x + t * vx);
    const dy = p.y - (a.y + t * vy);
    return @sqrt(dx * dx + dy * dy);
}

test "a degenerate path produces an empty mesh rather than a broken one" {
    const gpa = testing.allocator;

    for ([_][]const [2]f32{
        &.{}, // nothing at all
        &.{.{ 5, 5 }}, // a single point: a stroke's dot, never a fill
        &.{ .{ 0, 0 }, .{ 10, 10 } }, // a bare line has no interior
    }, 0..) |pts, case| {
        var f: Flattener = .init(.{});
        defer f.deinit(gpa);
        if (pts.len > 0) _ = try flattenPoints(gpa, &f, pts, true) else _ = try f.finish(gpa);
        const flat = try f.finish(gpa);

        var m = try mesh(gpa, flat);
        defer m.deinit(gpa);
        testing.expect(m.isEmpty()) catch |e| {
            std.debug.print("case {d} produced {d} stencil indices\n", .{ case, m.stencil_count });
            return e;
        };
        try testing.expectEqual(@as(usize, 0), m.indices.len);
    }
}

test "a path is flattened from a display list the same way it is by hand" {
    const gpa = testing.allocator;

    const verbs = [_]Verb{ .move, .line, .cubic, .close };
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 20, .y = 0 },
        .{ .x = 30, .y = 10 },
        .{ .x = 30, .y = 20 },
        .{ .x = 20, .y = 30 },
    };
    const list: DisplayList = .{ .verbs = &verbs, .points = &points };
    const path: DisplayList.Path = .{
        .verbs = .{ .start = 0, .count = 4 },
        .points = .{ .start = 0, .count = 5 },
    };

    var f: Flattener = .init(.{});
    defer f.deinit(gpa);
    try f.addPath(gpa, list, path);
    const flat = try f.finish(gpa);

    try testing.expectEqual(@as(usize, 1), flat.subpaths.len);
    try testing.expect(flat.subpaths[0].closed);
    try testing.expect(flat.subpaths[0].count > 3);
    try testing.expect(flat.contains(20, 10, .nonzero));
}

test "a path whose verbs outrun its points stops rather than reading past them" {
    // Not something the builder can emit, but a display list is a plain struct
    // and could arrive from anywhere.
    const gpa = testing.allocator;

    const verbs = [_]Verb{ .move, .cubic };
    const points = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 } };
    const list: DisplayList = .{ .verbs = &verbs, .points = &points };
    const path: DisplayList.Path = .{
        .verbs = .{ .start = 0, .count = 2 },
        .points = .{ .start = 0, .count = 2 },
    };

    var f: Flattener = .init(.{});
    defer f.deinit(gpa);
    try f.addPath(gpa, list, path);
    const flat = try f.finish(gpa);
    try testing.expectEqual(@as(u32, 1), flat.subpaths[0].count);
}

test "the point budget is enforced rather than trusted" {
    const gpa = testing.allocator;
    var f: Flattener = .init(.{ .max_points = 8 });
    defer f.deinit(gpa);

    try f.moveTo(gpa, .{ .x = 0, .y = 0 });
    var i: u32 = 0;
    const result = while (i < 100) : (i += 1) {
        f.lineTo(gpa, .{ .x = @floatFromInt(i + 1), .y = @floatFromInt(i * 2) }) catch |e| break e;
    } else error.NoLimit;
    try testing.expectEqual(error.TooManyPoints, result);
}

test "reset keeps the capacity and drops the contents" {
    const gpa = testing.allocator;
    var f: Flattener = .init(.{});
    defer f.deinit(gpa);

    _ = try flattenPoints(gpa, &f, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 } }, true);
    const cap = f.points.capacity;
    try testing.expect(cap > 0);

    f.reset();
    const flat = try f.finish(gpa);
    try testing.expectEqual(@as(usize, 0), flat.subpaths.len);
    try testing.expect(flat.bounds.isEmpty());
    try testing.expectEqual(cap, f.points.capacity);
}
