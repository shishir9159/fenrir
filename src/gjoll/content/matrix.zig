//! The interpreter's own matrix, in `f64`.
//!
//! Gelgja stores `f32`, and says why: a display list is going to a GPU, and
//! narrowing once at the recording boundary keeps the conversion in one place.
//! But the interpreter *composes* matrices, and composition is where `f32`
//! stops being enough. A page that sets up its coordinate system with a dozen
//! nested `cm` operators -- which is what every chart, every table rule, and
//! every form XObject inside a form XObject does -- accumulates the rounding
//! of every one of them. In `f32` that drift becomes a visible half-pixel
//! seam between two rectangles that the file says share an edge.
//!
//! So: `f64` here, `f32` at `toTransform`, which is called exactly once per
//! recorded command.
//!
//! The layout is the spec's (§8.3.3), the same as `geom.Transform`:
//!
//!     | a b 0 |
//!     | c d 0 |
//!     | e f 1 |
//!
//! Row vectors, so `[x y 1] * M`, and `concat` applies its receiver first.

const std = @import("std");

const geom = @import("../../gelgja/geom.zig");

pub const Matrix = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    pub const identity: Matrix = .{};

    pub fn translation(tx: f64, ty: f64) Matrix {
        return .{ .e = tx, .f = ty };
    }

    pub fn scaling(sx: f64, sy: f64) Matrix {
        return .{ .a = sx, .d = sy };
    }

    /// The six numbers of a `cm` or `Tm` operator, or a `/Matrix` entry.
    /// Non-finite entries are dropped to the identity's value rather than
    /// poisoning every later composition: one `nan` in a CTM turns an entire
    /// page blank, and files do contain them.
    pub fn fromOperands(v: [6]f64) Matrix {
        return .{
            .a = clean(v[0], 1),
            .b = clean(v[1], 0),
            .c = clean(v[2], 0),
            .d = clean(v[3], 1),
            .e = clean(v[4], 0),
            .f = clean(v[5], 0),
        };
    }

    fn clean(v: f64, fallback: f64) f64 {
        return if (std.math.isFinite(v)) v else fallback;
    }

    pub fn apply(m: Matrix, x: f64, y: f64) [2]f64 {
        return .{
            m.a * x + m.c * y + m.e,
            m.b * x + m.d * y + m.f,
        };
    }

    /// `inner` first, then `outer` -- the order `cm` composes in, and the
    /// order the spec writes text matrices in.
    pub fn concat(inner: Matrix, outer: Matrix) Matrix {
        return .{
            .a = inner.a * outer.a + inner.b * outer.c,
            .b = inner.a * outer.b + inner.b * outer.d,
            .c = inner.c * outer.a + inner.d * outer.c,
            .d = inner.c * outer.b + inner.d * outer.d,
            .e = inner.e * outer.a + inner.f * outer.c + outer.e,
            .f = inner.e * outer.b + inner.f * outer.d + outer.f,
        };
    }

    pub fn determinant(m: Matrix) f64 {
        return m.a * m.d - m.b * m.c;
    }

    /// `sqrt(|det|)`: the average factor by which lengths are scaled. A zero
    /// stroke width resolves through this, and so does the decision about
    /// whether a form XObject is small enough to be worth drawing at all.
    pub fn expansion(m: Matrix) f64 {
        return @sqrt(@abs(m.determinant()));
    }

    /// True when this matrix collapses everything to a line or a point.
    /// `0 0 0 0 0 0 cm` appears in real files, usually just before a `Do` that
    /// the producer meant to suppress.
    pub fn isDegenerate(m: Matrix) bool {
        const det = m.determinant();
        return !std.math.isFinite(det) or det == 0;
    }

    pub fn invert(m: Matrix) ?Matrix {
        const det = m.determinant();
        if (!std.math.isFinite(det) or det == 0) return null;
        const inv = 1.0 / det;
        return .{
            .a = m.d * inv,
            .b = -m.b * inv,
            .c = -m.c * inv,
            .d = m.a * inv,
            .e = (m.c * m.f - m.d * m.e) * inv,
            .f = (m.b * m.e - m.a * m.f) * inv,
        };
    }

    /// Narrows for recording. Called once per command, never inside a loop
    /// over points.
    pub fn toTransform(m: Matrix) geom.Transform {
        return .{
            .a = @floatCast(m.a),
            .b = @floatCast(m.b),
            .c = @floatCast(m.c),
            .d = @floatCast(m.d),
            .e = @floatCast(m.e),
            .f = @floatCast(m.f),
        };
    }

    /// Transforms and narrows a single point. The one hot path in the
    /// interpreter: every path point in the document goes through it.
    pub fn point(m: Matrix, x: f64, y: f64) geom.Point {
        const p = m.apply(x, y);
        return .{ .x = @floatCast(p[0]), .y = @floatCast(p[1]) };
    }
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "composition follows the PDF convention" {
    // Scale by 2, then translate by (10, 20): (1, 1) lands at (12, 22).
    const m = Matrix.scaling(2, 2).concat(.translation(10, 20));
    const p = m.apply(1, 1);
    try testing.expectApproxEqAbs(@as(f64, 12), p[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 22), p[1], 1e-12);
}

test "a non-finite operand does not poison the matrix" {
    const nan = std.math.nan(f64);
    const m = Matrix.fromOperands(.{ nan, 0, 0, nan, 5, 5 });
    try testing.expectEqual(@as(f64, 1), m.a);
    try testing.expectEqual(@as(f64, 1), m.d);
    try testing.expectEqual(@as(f64, 5), m.e);
}

test "a collapsed matrix is recognised rather than inverted" {
    const zero = Matrix.fromOperands(.{ 0, 0, 0, 0, 0, 0 });
    try testing.expect(zero.isDegenerate());
    try testing.expectEqual(@as(?Matrix, null), zero.invert());
}

test "inversion round-trips a point" {
    const m = Matrix.scaling(3, -2).concat(.translation(7, 11));
    const inv = m.invert().?;
    const there = m.apply(4, 9);
    const back = inv.apply(there[0], there[1]);
    try testing.expectApproxEqAbs(@as(f64, 4), back[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 9), back[1], 1e-9);
}

test "f64 composition does not drift the way f32 would" {
    // Fifty nested `cm` operators, each a scale and a shift back, ending where
    // it started. This is a form XObject inside a form XObject inside a table
    // cell -- and in f32 the error is visible on screen.
    var m: Matrix = .identity;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        m = m.concat(.scaling(1.1, 1.1)).concat(.translation(0.3, -0.7));
    }
    var back: Matrix = .identity;
    i = 0;
    while (i < 50) : (i += 1) {
        back = back.concat(.translation(-0.3, 0.7)).concat(.scaling(1.0 / 1.1, 1.0 / 1.1));
    }
    const round = m.concat(back);
    const p = round.apply(100, 100);
    try testing.expectApproxEqAbs(@as(f64, 100), p[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 100), p[1], 1e-6);
}

test "expansion is the geometric mean of the scale factors" {
    try testing.expectApproxEqAbs(@as(f64, 6), Matrix.scaling(4, 9).expansion(), 1e-12);
    // A mirror has a negative determinant but a positive expansion.
    try testing.expectApproxEqAbs(@as(f64, 1), Matrix.scaling(1, -1).expansion(), 1e-12);
}
