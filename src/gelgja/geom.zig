//! Geometry for the display list.
//!
//! Coordinates are `f32` here, deliberately, even though the parser works in
//! `f64`. The largest legal PDF page is 200 inches, or 14400 units, and an
//! `f32` resolves about 0.002 units at that magnitude -- under a hundredth of
//! a pixel at 300 dpi, and still under a fifth of a pixel at 6400% zoom. GPUs
//! want `f32`, so narrowing here rather than at the driver boundary keeps one
//! conversion in one place.
//!
//! The interpreter should still do its matrix arithmetic in `f64` and narrow
//! only when it records a command: concatenating a hundred `cm` operators in
//! `f32` accumulates visible drift.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Point = struct {
    x: f32,
    y: f32,

    pub const origin: Point = .{ .x = 0, .y = 0 };

    pub fn format(p: Point, w: *Writer) Writer.Error!void {
        try w.print("{d:.2},{d:.2}", .{ p.x, p.y });
    }
};

/// A PDF transformation matrix, in the spec's own layout (§8.3.3):
///
///     | a b 0 |
///     | c d 0 |
///     | e f 1 |
///
/// Row vectors, so a point is transformed as `[x y 1] * M`, and `concat`
/// applies its receiver first. This is the opposite convention from most
/// graphics maths libraries and matching the spec avoids a class of
/// transposition bug that is very hard to see in rendered output.
pub const Transform = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub const identity: Transform = .{};

    pub fn translation(tx: f32, ty: f32) Transform {
        return .{ .e = tx, .f = ty };
    }

    pub fn scaling(sx: f32, sy: f32) Transform {
        return .{ .a = sx, .d = sy };
    }

    pub fn rotation(radians: f32) Transform {
        const cos = @cos(radians);
        const sin = @sin(radians);
        return .{ .a = cos, .b = sin, .c = -sin, .d = cos };
    }

    pub fn apply(t: Transform, p: Point) Point {
        return .{
            .x = t.a * p.x + t.c * p.y + t.e,
            .y = t.b * p.x + t.d * p.y + t.f,
        };
    }

    /// Transforms a direction rather than a position: the translation is
    /// dropped. Used for extents and pen axes.
    pub fn applyVector(t: Transform, p: Point) Point {
        return .{
            .x = t.a * p.x + t.c * p.y,
            .y = t.b * p.x + t.d * p.y,
        };
    }

    /// `inner` first, then `outer` -- the order `cm` composes in.
    pub fn concat(inner: Transform, outer: Transform) Transform {
        return .{
            .a = inner.a * outer.a + inner.b * outer.c,
            .b = inner.a * outer.b + inner.b * outer.d,
            .c = inner.c * outer.a + inner.d * outer.c,
            .d = inner.c * outer.b + inner.d * outer.d,
            .e = inner.e * outer.a + inner.f * outer.c + outer.e,
            .f = inner.e * outer.b + inner.f * outer.d + outer.f,
        };
    }

    pub fn determinant(t: Transform) f32 {
        return t.a * t.d - t.b * t.c;
    }

    /// The average factor by which this matrix scales lengths, `sqrt(|det|)`.
    ///
    /// Two things need it. Flattening a Bézier requires a tolerance in device
    /// pixels, so the curve has to know how much it will be magnified. And a
    /// zero-width stroke means "the thinnest line the device can draw", which
    /// only has meaning after the matrix is known.
    pub fn expansion(t: Transform) f32 {
        return @sqrt(@abs(t.determinant()));
    }

    /// True when the matrix maps axes to axes, so a backend can take a fast
    /// path: no rotation or skew, only scale and translation (or a quarter
    /// turn).
    pub fn isAxisAligned(t: Transform) bool {
        const flat = (t.b == 0 and t.c == 0);
        const quarter = (t.a == 0 and t.d == 0);
        return flat or quarter;
    }

    /// Null when the matrix is singular, which happens in real files -- a
    /// `0 0 0 0 0 0 cm` collapses everything drawn after it to nothing.
    pub fn invert(t: Transform) ?Transform {
        const det = t.determinant();
        if (!std.math.isFinite(det) or det == 0) return null;
        const inv = 1.0 / det;
        return .{
            .a = t.d * inv,
            .b = -t.b * inv,
            .c = -t.c * inv,
            .d = t.a * inv,
            .e = (t.c * t.f - t.d * t.e) * inv,
            .f = (t.b * t.e - t.a * t.f) * inv,
        };
    }

    pub fn format(t: Transform, w: *Writer) Writer.Error!void {
        try w.print("[{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2}]", .{
            t.a, t.b, t.c, t.d, t.e, t.f,
        });
    }
};

/// An axis-aligned bounding box. Starts inverted so that `add` and `unionWith`
/// build it up without a separate "is this the first point" flag.
pub const Bounds = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    pub const empty: Bounds = .{
        .min_x = std.math.inf(f32),
        .min_y = std.math.inf(f32),
        .max_x = -std.math.inf(f32),
        .max_y = -std.math.inf(f32),
    };

    pub fn fromRect(x0: f32, y0: f32, x1: f32, y1: f32) Bounds {
        return .{
            .min_x = @min(x0, x1),
            .min_y = @min(y0, y1),
            .max_x = @max(x0, x1),
            .max_y = @max(y0, y1),
        };
    }

    pub fn isEmpty(b: Bounds) bool {
        return !(b.max_x >= b.min_x and b.max_y >= b.min_y);
    }

    pub fn add(b: Bounds, p: Point) Bounds {
        return .{
            .min_x = @min(b.min_x, p.x),
            .min_y = @min(b.min_y, p.y),
            .max_x = @max(b.max_x, p.x),
            .max_y = @max(b.max_y, p.y),
        };
    }

    pub fn unionWith(a: Bounds, b: Bounds) Bounds {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{
            .min_x = @min(a.min_x, b.min_x),
            .min_y = @min(a.min_y, b.min_y),
            .max_x = @max(a.max_x, b.max_x),
            .max_y = @max(a.max_y, b.max_y),
        };
    }

    /// The other half of a clip stack. Unlike `unionWith`, an intersection
    /// with an empty box is empty rather than the other operand, so a clip
    /// that has been reduced to nothing stays nothing however deep it is
    /// nested -- which is what lets a caller test `isEmpty` once and skip
    /// building a whole subtree.
    ///
    /// The result can come back inverted (`max < min`); `isEmpty` reports
    /// that, and nothing here silently repairs it, because an inverted clip
    /// means the caller asked for a region that does not exist.
    pub fn intersect(a: Bounds, b: Bounds) Bounds {
        return .{
            .min_x = @max(a.min_x, b.min_x),
            .min_y = @max(a.min_y, b.min_y),
            .max_x = @min(a.max_x, b.max_x),
            .max_y = @min(a.max_y, b.max_y),
        };
    }

    /// Everything, so that a clip stack has something to start from.
    pub const infinite: Bounds = .{
        .min_x = -std.math.inf(f32),
        .min_y = -std.math.inf(f32),
        .max_x = std.math.inf(f32),
        .max_y = std.math.inf(f32),
    };

    pub fn contains(b: Bounds, p: Point) bool {
        return p.x >= b.min_x and p.x <= b.max_x and p.y >= b.min_y and p.y <= b.max_y;
    }

    pub fn width(b: Bounds) f32 {
        return if (b.isEmpty()) 0 else b.max_x - b.min_x;
    }

    pub fn height(b: Bounds) f32 {
        return if (b.isEmpty()) 0 else b.max_y - b.min_y;
    }

    pub fn format(b: Bounds, w: *Writer) Writer.Error!void {
        if (b.isEmpty()) {
            try w.writeAll("[empty]");
            return;
        }
        try w.print("[{d:.2} {d:.2} {d:.2} {d:.2}]", .{ b.min_x, b.min_y, b.max_x, b.max_y });
    }
};

/// Path segment kinds. PDF has no quadratic curves -- `v` and `y` are cubics
/// with a duplicated control point -- so four verbs cover the whole language.
pub const Verb = enum(u8) {
    /// Starts a new subpath. One point.
    move,
    /// One point.
    line,
    /// Two control points then the endpoint. Three points.
    cubic,
    /// Closes the current subpath back to its start. No points.
    close,

    pub fn pointCount(v: Verb) u8 {
        return switch (v) {
            .move, .line => 1,
            .cubic => 3,
            .close => 0,
        };
    }
};

/// Which points a fill considers inside (§8.5.3.3).
pub const FillRule = enum {
    /// The default. `f`, `B`, `W`.
    nonzero,
    /// `f*`, `B*`, `W*`.
    even_odd,

    pub fn opName(r: FillRule) []const u8 {
        return switch (r) {
            .nonzero => "nonzero",
            .even_odd => "evenodd",
        };
    }
};

/// A half-open span into one of the display list's shared arrays.
///
/// Ranges rather than slices because the builder appends to growing arrays
/// while recording, and a reallocation would dangle every slice handed out so
/// far. Resolution happens through the finished list.
pub const Range = struct {
    start: u32 = 0,
    count: u32 = 0,

    pub const empty: Range = .{};

    pub fn isEmpty(r: Range) bool {
        return r.count == 0;
    }

    pub fn slice(r: Range, items: anytype) @TypeOf(items) {
        return items[r.start..][0..r.count];
    }
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "transform composition follows the PDF convention" {
    // Scale by 2, then translate by (10, 20): a point at (1, 1) lands at
    // (12, 22), not (21, 41).
    const m = Transform.scaling(2, 2).concat(.translation(10, 20));
    const p = m.apply(.{ .x = 1, .y = 1 });
    try testing.expectApproxEqAbs(@as(f32, 12), p.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 22), p.y, 1e-5);
}

test "vectors ignore translation" {
    const m = Transform.scaling(2, 3).concat(.translation(100, 100));
    const v = m.applyVector(.{ .x = 1, .y = 1 });
    try testing.expectApproxEqAbs(@as(f32, 2), v.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 3), v.y, 1e-5);
}

test "expansion reports the average scale" {
    try testing.expectApproxEqAbs(@as(f32, 2), Transform.scaling(2, 2).expansion(), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 6), Transform.scaling(4, 9).expansion(), 1e-5);
    // Rotation preserves area.
    try testing.expectApproxEqAbs(@as(f32, 1), Transform.rotation(0.7).expansion(), 1e-5);
}

test "inversion round trips, and singular matrices report themselves" {
    const m = Transform.scaling(2, 4).concat(.rotation(0.5)).concat(.translation(3, 7));
    const back = m.invert().?;
    const p: Point = .{ .x = 12.5, .y = -3.25 };
    const round = back.apply(m.apply(p));
    try testing.expectApproxEqAbs(p.x, round.x, 1e-3);
    try testing.expectApproxEqAbs(p.y, round.y, 1e-3);

    const collapsed: Transform = .{ .a = 0, .b = 0, .c = 0, .d = 0 };
    try testing.expectEqual(@as(?Transform, null), collapsed.invert());
}

test "axis alignment covers quarter turns" {
    try testing.expect(Transform.identity.isAxisAligned());
    try testing.expect(Transform.scaling(3, -1).isAxisAligned());
    try testing.expect((Transform{ .a = 0, .b = 1, .c = -1, .d = 0 }).isAxisAligned());
    try testing.expect(!Transform.rotation(0.4).isAxisAligned());
}

test "bounds start empty and grow" {
    var b: Bounds = .empty;
    try testing.expect(b.isEmpty());

    b = b.add(.{ .x = 10, .y = 20 });
    try testing.expect(!b.isEmpty());
    try testing.expectEqual(@as(f32, 0), b.width());

    b = b.add(.{ .x = -5, .y = 40 });
    try testing.expectEqual(@as(f32, 15), b.width());
    try testing.expectEqual(@as(f32, 20), b.height());
}

test "union with an empty box is a no-op" {
    const a: Bounds = .fromRect(0, 0, 10, 10);
    try testing.expectEqual(a, a.unionWith(.empty));
    try testing.expectEqual(a, Bounds.empty.unionWith(a));
}

test "verb point counts" {
    try testing.expectEqual(@as(u8, 1), Verb.move.pointCount());
    try testing.expectEqual(@as(u8, 3), Verb.cubic.pointCount());
    try testing.expectEqual(@as(u8, 0), Verb.close.pointCount());
}

test "intersection with an empty box is empty, unlike union" {
    const a: Bounds = .fromRect(0, 0, 10, 10);
    try testing.expect(a.intersect(.empty).isEmpty());
    try testing.expect(Bounds.empty.intersect(a).isEmpty());
    try testing.expectEqual(a, a.intersect(.infinite));
}

test "nested clips only ever shrink" {
    const outer: Bounds = .fromRect(0, 0, 100, 100);
    const inner = outer.intersect(.fromRect(20, 20, 60, 60));
    try testing.expectEqual(Bounds.fromRect(20, 20, 60, 60), inner);

    // Disjoint: the result is inverted, and stays empty however far it is
    // nested afterwards.
    const gone = inner.intersect(.fromRect(200, 200, 300, 300));
    try testing.expect(gone.isEmpty());
    try testing.expect(gone.intersect(outer).isEmpty());
}

test "contains is inclusive on the boundary" {
    const b: Bounds = .fromRect(0, 0, 10, 10);
    try testing.expect(b.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(b.contains(.{ .x = 10, .y = 10 }));
    try testing.expect(!b.contains(.{ .x = 10.5, .y = 5 }));
}
