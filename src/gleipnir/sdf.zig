//! The signed distance field the rect pipeline is built on, in Zig.
//!
//! This file is the reference. `shader/rect.frag` is a transliteration of it
//! into GLSL, line for line and name for name, and the two are meant to be
//! read side by side. The duplication is deliberate: the shader cannot be unit
//! tested without a device, and the alternatives -- generating GLSL from Zig,
//! or a shading language embedded in comptime -- buy a guarantee that is not
//! worth the machinery for sixty lines of arithmetic. What the duplication
//! does buy is that every number below is checked by a test, so when a rounded
//! corner comes out wrong on the GPU, the arithmetic is not the suspect.
//!
//! Everything here is in device pixels, y down, origin at the top left of the
//! framebuffer. Gelgja is y-up PDF space; that flip happens once, in the
//! page-to-screen transform, and never again below it.

const std = @import("std");

const geom = @import("../gelgja/geom.zig");

pub const Point = geom.Point;

/// Corner radii in pixels, clockwise from the top left.
///
/// Four rather than one because every interesting piece of chrome needs them:
/// a tab is rounded on top and square on the bottom, the first button in a
/// group is rounded on its left only, a scrollbar thumb is a capsule. One
/// radius means drawing those from several rects with visible seams, or a
/// second pipeline.
pub const Radius = extern struct {
    tl: f32 = 0,
    tr: f32 = 0,
    br: f32 = 0,
    bl: f32 = 0,

    pub const none: Radius = .{};

    pub fn all(r: f32) Radius {
        return .{ .tl = r, .tr = r, .br = r, .bl = r };
    }

    pub fn top(r: f32) Radius {
        return .{ .tl = r, .tr = r };
    }

    pub fn bottom(r: f32) Radius {
        return .{ .br = r, .bl = r };
    }

    pub fn left(r: f32) Radius {
        return .{ .tl = r, .bl = r };
    }

    pub fn right(r: f32) Radius {
        return .{ .tr = r, .br = r };
    }

    pub fn isZero(r: Radius) bool {
        return r.tl == 0 and r.tr == 0 and r.br == 0 and r.bl == 0;
    }

    /// A radius larger than half the shorter side has no meaning -- the two
    /// corners it belongs to would overlap -- and the field renders that
    /// overlap as a visible notch rather than failing. Clamping happens once,
    /// on the CPU, so the shader can assume it and a caller can write
    /// `Radius.all(9999)` to mean "capsule" without knowing the size.
    pub fn clampTo(r: Radius, half_w: f32, half_h: f32) Radius {
        const lim = @max(0.0, @min(half_w, half_h));
        return .{
            .tl = std.math.clamp(r.tl, 0, lim),
            .tr = std.math.clamp(r.tr, 0, lim),
            .br = std.math.clamp(r.br, 0, lim),
            .bl = std.math.clamp(r.bl, 0, lim),
        };
    }

    pub fn asArray(r: Radius) [4]f32 {
        return .{ r.tl, r.tr, r.br, r.bl };
    }
};

/// Signed distance from `p` to a rounded box centred on the origin with
/// half extents `half`. Negative inside, zero on the edge, positive outside,
/// and the magnitude is a true Euclidean distance everywhere outside -- which
/// is what lets one `smoothstep` produce both antialiasing and a soft shadow,
/// with only the width of the ramp changing between them.
///
/// The one place it is not a true distance is deep inside a square corner,
/// where it reports the distance to the nearer side rather than to the corner
/// point. Nothing reads the field that far in, so the cheaper form is right.
pub fn roundedBox(p: Point, half: Point, r: Radius) f32 {
    // The quadrant p falls in picks its radius. y is down, so a negative y is
    // the top of the rect.
    const rad = if (p.y < 0)
        (if (p.x < 0) r.tl else r.tr)
    else
        (if (p.x < 0) r.bl else r.br);

    const qx = @abs(p.x) - half.x + rad;
    const qy = @abs(p.y) - half.y + rad;
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @min(@max(qx, qy), 0.0) + @sqrt(ox * ox + oy * oy) - rad;
}

/// Turns a filled shape into a ring of the given thickness, lying inside the
/// original edge.
///
/// Inside rather than centred on the edge, because a border is nearly always
/// wanted within a layout box: a 1px frame around a 100px button should still
/// occupy 100px, or every bordered thing in a list sits a pixel proud of every
/// unbordered one.
pub fn ring(d: f32, thickness: f32) f32 {
    if (thickness <= 0) return d;
    const half = thickness * 0.5;
    return @abs(d + half) - half;
}

/// Coverage in 0..1 for a distance, given how wide the transition should be.
///
/// `softness` is the shadow radius in pixels; zero means a hard edge, which
/// still gets a one-pixel ramp so it is antialiased rather than jagged. The
/// same function therefore serves a crisp button and a drop shadow, and there
/// is no separate blur pass anywhere in this renderer.
///
/// `pixel` is the width of one pixel in the units `d` is measured in -- always
/// 1.0 here, because the CPU bakes the transform into the instance before it
/// is uploaded. The parameter exists so the GLSL can pass `fwidth(d)` and stay
/// correct if a global zoom is ever moved onto the GPU.
pub fn coverage(d: f32, softness: f32, pixel: f32) f32 {
    const w = @max(softness * 2.0, pixel);
    const t = std.math.clamp(0.5 - d / w, 0.0, 1.0);
    // Smoothstep rather than the raw ramp: over one pixel the difference is
    // barely visible, but a shadow with a linear falloff has a hard crease
    // where it reaches zero, and this does not.
    return t * t * (3.0 - 2.0 * t);
}

/// Bilinear blend of four corner values at `t` in the unit square, corners in
/// `Radius` order: top left, top right, bottom right, bottom left.
pub fn bilerp(c: [4]f32, tx: f32, ty: f32) f32 {
    const top_v = c[0] + (c[1] - c[0]) * tx;
    const bot_v = c[3] + (c[2] - c[3]) * tx;
    return top_v + (bot_v - top_v) * ty;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn expectClose(expected: f32, actual: f32) !void {
    try testing.expectApproxEqAbs(expected, actual, 1e-4);
}

test "a square box is the classic box distance" {
    const half: Point = .{ .x = 10, .y = 5 };
    const r: Radius = .none;

    // Centre: the distance to the nearest side.
    try expectClose(-5, roundedBox(.{ .x = 0, .y = 0 }, half, r));
    // On an edge.
    try expectClose(0, roundedBox(.{ .x = 10, .y = 0 }, half, r));
    try expectClose(0, roundedBox(.{ .x = 0, .y = -5 }, half, r));
    // Straight out from a side.
    try expectClose(3, roundedBox(.{ .x = 13, .y = 0 }, half, r));
    // Diagonally out from a corner: a true Euclidean distance.
    try expectClose(5, roundedBox(.{ .x = 13, .y = 9 }, half, r));
}

test "a radius rounds only its own corner" {
    const half: Point = .{ .x = 10, .y = 10 };
    const r: Radius = .{ .tl = 10 };

    // The top left corner point is now outside the shape: a quarter circle of
    // radius 10 has pulled the surface back towards the centre.
    try expectClose(@sqrt(200.0) - 10, roundedBox(.{ .x = -10, .y = -10 }, half, r));
    // Every other corner is untouched.
    try expectClose(0, roundedBox(.{ .x = 10, .y = -10 }, half, r));
    try expectClose(0, roundedBox(.{ .x = 10, .y = 10 }, half, r));
    try expectClose(0, roundedBox(.{ .x = -10, .y = 10 }, half, r));
}

test "a fully rounded square is a circle" {
    const half: Point = .{ .x = 20, .y = 20 };
    const r: Radius = .all(20);
    // Every point 25 from the centre is 5 outside a circle of radius 20,
    // whatever direction it lies in.
    var angle: f32 = 0;
    while (angle < 6.2) : (angle += 0.3) {
        const p: Point = .{ .x = 25 * @cos(angle), .y = 25 * @sin(angle) };
        try expectClose(5, roundedBox(p, half, r));
    }
}

test "a capsule falls out of an oversized radius once it is clamped" {
    const half: Point = .{ .x = 40, .y = 10 };
    const r = Radius.all(9999).clampTo(half.x, half.y);
    try testing.expectEqual(Radius.all(10), r);
    // The straight run along the top is flat.
    try expectClose(0, roundedBox(.{ .x = 0, .y = -10 }, half, r));
    // The ends are semicircles of radius 10 about (+-30, 0).
    try expectClose(0, roundedBox(.{ .x = 40, .y = 0 }, half, r));
    try expectClose(0, roundedBox(.{ .x = 30 + 10 * @cos(0.7), .y = 10 * @sin(0.7) }, half, r));
}

test "a border is a ring lying inside the edge" {
    const half: Point = .{ .x = 10, .y = 10 };
    const d_edge = roundedBox(.{ .x = 10, .y = 0 }, half, .none);
    const d_in2 = roundedBox(.{ .x = 8, .y = 0 }, half, .none);
    const d_in4 = roundedBox(.{ .x = 6, .y = 0 }, half, .none);

    // With a 4px border the ring is centred 2px in from the edge, so the edge
    // itself and the point 4px in are both on its boundary, and 2px in is the
    // deepest point of the ring.
    try expectClose(0, ring(d_edge, 4));
    try expectClose(0, ring(d_in4, 4));
    try expectClose(-2, ring(d_in2, 4));
    // The middle of the box is far outside the ring, so it is not filled.
    try testing.expect(ring(roundedBox(.{ .x = 0, .y = 0 }, half, .none), 4) > 0);
}

test "coverage is a half at the edge and saturates either side" {
    try expectClose(0.5, coverage(0, 0, 1));
    try testing.expectEqual(@as(f32, 1), coverage(-1, 0, 1));
    try testing.expectEqual(@as(f32, 0), coverage(1, 0, 1));
    // Softness widens the ramp without moving its midpoint.
    try expectClose(0.5, coverage(0, 8, 1));
    try testing.expect(coverage(-4, 8, 1) > 0.5);
    try testing.expect(coverage(-4, 8, 1) < 1.0);
    try testing.expectEqual(@as(f32, 1), coverage(-16, 8, 1));
}

test "coverage is monotone, which is what makes a shadow look like one" {
    var prev: f32 = coverage(-20, 6, 1);
    var d: f32 = -20;
    while (d <= 20) : (d += 0.5) {
        const c = coverage(d, 6, 1);
        try testing.expect(c <= prev + 1e-6);
        prev = c;
    }
}

test "bilerp hits the corners it was given" {
    const c = [4]f32{ 0, 1, 2, 3 };
    try expectClose(0, bilerp(c, 0, 0));
    try expectClose(1, bilerp(c, 1, 0));
    try expectClose(2, bilerp(c, 1, 1));
    try expectClose(3, bilerp(c, 0, 1));
    try expectClose(1.5, bilerp(c, 0.5, 0.5));
}
