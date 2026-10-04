//! SVG path data -- the `d` attribute, and nothing else around it.
//!
//! Icons are declared as outlines rather than shipped as pictures, and this
//! is the notation they are declared in: `M6 2h12v20l-6-5-6 5z` is a bookmark.
//! Every icon set worth having publishes exactly that string for every glyph
//! it has, which is why the `d` subset is the whole of the SVG this program
//! will ever read. Groups, transforms, gradients, masks and CSS would make
//! SVG a second document format to maintain beside PDF.
//!
//! The operator set is the one `Outline` already has -- move, line, quadratic,
//! cubic, close -- which is not a coincidence. Both descend from PostScript,
//! and it is why an icon costs no new machinery downstream: a path becomes an
//! outline, an outline becomes a glyph, and the atlas, the rasteriser and the
//! draw list never learn that icons exist.
//!
//! Elliptical arcs are the one operator with no counterpart, and they are
//! converted rather than represented: see `arcTo`.
//!
//! ## Two coordinate systems, one matrix
//!
//! A `d` string is written on a small grid -- 24 by 24 for most icon sets --
//! with y running *down* the page. A glyph lives on the em square with y
//! running *up* from the baseline. `viewBox` is that matrix, and it is
//! applied as each point is emitted rather than by walking the outline
//! afterwards.
//!
//! What is *not* transformed is the arithmetic: relative coordinates and the
//! reflected control points of `S` and `T` are worked out in the path's own
//! space, before the matrix. Reflecting a point that has already been
//! transformed gives a different curve under any matrix that is not a uniform
//! scale, and a y flip is exactly such a matrix.
//!
//! ## A bad path is an error, not a repair
//!
//! The rest of this program is damage-tolerant because its input is other
//! people's PDFs. Path data is not that: it is either written here or written
//! by whoever is authoring an icon theme, and both want to be told. So a
//! stray byte fails the whole string, and the icon falls back to the visible
//! `unknown` box rather than to half a drawing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");
const Outline = @import("Outline.zig");

const Point = geom.Point;
const Transform = geom.Transform;

pub const Error = error{ BadPathData, OutOfMemory };

pub const Options = struct {
    /// Where the path's own coordinates land. Identity draws the path as
    /// written, in a space with y downwards, which is what a test wants and
    /// no glyph does.
    transform: Transform = .identity,
};

/// The matrix from a square `viewBox="0 0 size size"` onto an em square, with
/// the y axis flipped: the top of the icon grid lands at the top of the em
/// and the bottom of it on the baseline.
///
/// The flip reverses the direction every contour is wound in, which changes
/// nothing about the fill. The nonzero rule cares only that a hole is wound
/// *against* its outer contour, and reversing both keeps that true.
pub fn viewBox(size: f32, units_per_em: f32) Transform {
    const s = units_per_em / size;
    return .{ .a = s, .d = -s, .f = units_per_em };
}

/// Appends `d` to `out`, which is not reset first -- several paths make one
/// glyph often enough that clearing here would be the wrong default.
///
/// On failure `out` holds whatever was parsed before the bad byte. The caller
/// decides what that is worth; `Face.outline` resets before it asks, so an
/// icon that fails to parse draws nothing rather than a fragment.
pub fn parse(gpa: Allocator, out: *Outline, d: []const u8, opts: Options) Error!void {
    var p: Parser = .{ .gpa = gpa, .out = out, .d = d, .t = opts.transform };
    return p.run();
}

const Parser = struct {
    gpa: Allocator,
    out: *Outline,
    d: []const u8,
    t: Transform,
    i: usize = 0,

    /// The pen, in path space. `Outline` has one of these too, in transformed
    /// space, and the two are deliberately not the same number.
    cur: Point = .origin,
    /// Where the current contour started, for `Z`.
    begin: Point = .origin,
    /// The last curve's final control point, or null when the last command
    /// drew no curve of that degree. `S` and `T` reflect it; the spec says to
    /// use the current point when there is nothing to reflect.
    cubic_ctrl: ?Point = null,
    quad_ctrl: ?Point = null,

    fn run(p: *Parser) Error!void {
        var previous: u8 = 0;
        while (true) {
            p.skipSeparators();
            if (p.i == p.d.len) break;

            const c = p.d[p.i];
            const cmd = if (isCommand(c)) cmd: {
                p.i += 1;
                break :cmd c;
            } else cmd: {
                if (!startsNumber(c)) return error.BadPathData;
                // A bare coordinate repeats the last command, with the one
                // exception the spec is explicit about: a repeated moveto is
                // a lineto, or `M0 0 1 0 2 0` would be three contours of one
                // point each instead of a stroke through three.
                break :cmd switch (previous) {
                    'M' => 'L',
                    'm' => 'l',
                    // Nothing to repeat, or a close given arguments.
                    0, 'Z', 'z' => return error.BadPathData,
                    else => previous,
                };
            };

            try p.command(cmd);
            previous = cmd;
        }
    }

    fn command(p: *Parser, c: u8) Error!void {
        const rel = std.ascii.isLower(c);
        switch (std.ascii.toUpper(c)) {
            'M' => try p.moveTo(try p.point(rel)),
            'L' => try p.lineTo(try p.point(rel)),
            'H' => {
                const x = try p.number();
                try p.lineTo(.{ .x = if (rel) p.cur.x + x else x, .y = p.cur.y });
            },
            'V' => {
                const y = try p.number();
                try p.lineTo(.{ .x = p.cur.x, .y = if (rel) p.cur.y + y else y });
            },
            'C' => {
                const c1 = try p.point(rel);
                const c2 = try p.point(rel);
                try p.cubicTo(c1, c2, try p.point(rel));
            },
            'S' => {
                const c2 = try p.point(rel);
                try p.cubicTo(p.reflect(p.cubic_ctrl), c2, try p.point(rel));
            },
            'Q' => {
                const q = try p.point(rel);
                try p.quadTo(q, try p.point(rel));
            },
            'T' => try p.quadTo(p.reflect(p.quad_ctrl), try p.point(rel)),
            'A' => {
                const rx = try p.number();
                const ry = try p.number();
                const degrees = try p.number();
                const large = try p.flag();
                const sweep = try p.flag();
                try p.arcTo(rx, ry, degrees, large, sweep, try p.point(rel));
            },
            'Z' => try p.close(),
            else => return error.BadPathData,
        }
    }

    // -- emitting, which is where the matrix is applied ---------------------

    fn moveTo(p: *Parser, to: Point) Error!void {
        try p.out.moveTo(p.gpa, p.t.apply(to));
        p.cur = to;
        p.begin = to;
        p.cubic_ctrl = null;
        p.quad_ctrl = null;
    }

    fn lineTo(p: *Parser, to: Point) Error!void {
        try p.out.lineTo(p.gpa, p.t.apply(to));
        p.cur = to;
        p.cubic_ctrl = null;
        p.quad_ctrl = null;
    }

    fn cubicTo(p: *Parser, c1: Point, c2: Point, to: Point) Error!void {
        try p.out.cubicTo(p.gpa, p.t.apply(c1), p.t.apply(c2), p.t.apply(to));
        p.cur = to;
        p.cubic_ctrl = c2;
        p.quad_ctrl = null;
    }

    /// Elevated to a cubic by `Outline`, in transformed space. That is the
    /// same curve either way: elevation is an affine combination of the
    /// points, and an affine map commutes with those.
    fn quadTo(p: *Parser, q: Point, to: Point) Error!void {
        try p.out.quadTo(p.gpa, p.t.apply(q), p.t.apply(to));
        p.cur = to;
        p.quad_ctrl = q;
        p.cubic_ctrl = null;
    }

    /// An elliptical arc, as up to four cubics.
    ///
    /// This is the one operator `Outline` has no verb for, and adding one
    /// would push an arc all the way down through the rasteriser and the
    /// stroker to reach a shape no content stream can produce. So it is
    /// converted here, once, in the one file that knows what an arc is.
    ///
    /// The conversion is the specification's own (F.6.5): an arc is given by
    /// its endpoints, its radii and two flags, and the ellipse it lies on has
    /// to be recovered from them before anything can be drawn. Then the
    /// sweep is cut into quarter turns, each approximated by a cubic whose
    /// controls run `4/3 tan(t/4)` along the tangents. That approximation is
    /// exact at both ends and off by about one part in ten thousand of the
    /// radius in the middle of a quarter turn, which at a 24-pixel icon is
    /// four thousandths of a pixel.
    fn arcTo(
        p: *Parser,
        rx_in: f32,
        ry_in: f32,
        degrees: f32,
        large: bool,
        sweep: bool,
        to: Point,
    ) Error!void {
        const from = p.cur;
        // An arc that goes nowhere is dropped entirely (F.6.2). It is not a
        // closed loop, which is what treating the two endpoints as distinct
        // would eventually produce.
        if (from.x == to.x and from.y == to.y) return;

        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        // A zero radius is a straight line, and it is the form a rounded
        // corner degrades into when an icon set is generated with the corner
        // radius set to nothing.
        if (rx == 0 or ry == 0) return p.lineTo(to);

        const phi = degrees * std.math.pi / 180.0;
        const cos_phi = @cos(phi);
        const sin_phi = @sin(phi);

        // F.6.5.1: half the endpoint difference, rotated into the ellipse's
        // own frame, where it is an axis-aligned ellipse again.
        const dx = (from.x - to.x) * 0.5;
        const dy = (from.y - to.y) * 0.5;
        const x1 = cos_phi * dx + sin_phi * dy;
        const y1 = -sin_phi * dx + cos_phi * dy;

        // F.6.6: radii too small to reach across the gap are scaled up until
        // they just do, rather than rejected.
        const lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lambda > 1) {
            const s = @sqrt(lambda);
            rx *= s;
            ry *= s;
        }

        // F.6.5.2: the centre. Two ellipses pass through both endpoints and
        // the flags choose between them, which is what the sign is doing.
        const denom = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        if (denom == 0) return p.lineTo(to);
        // Clamped because the radii were only just made big enough above, and
        // the rounding can leave this a few ulps below zero.
        const num = @max(rx * rx * ry * ry - denom, 0);
        var coef = @sqrt(num / denom);
        if (large == sweep) coef = -coef;

        const cx1 = coef * rx * y1 / ry;
        const cy1 = -coef * ry * x1 / rx;
        const e: Ellipse = .{
            .c = .{
                .x = cos_phi * cx1 - sin_phi * cy1 + (from.x + to.x) * 0.5,
                .y = sin_phi * cx1 + cos_phi * cy1 + (from.y + to.y) * 0.5,
            },
            .rx = rx,
            .ry = ry,
            .cos_phi = cos_phi,
            .sin_phi = sin_phi,
        };

        // F.6.5.5 and F.6.5.6: where on that ellipse the endpoints sit, and
        // how far round it the arc runs. The flags decide the direction.
        const ux = (x1 - cx1) / rx;
        const uy = (y1 - cy1) / ry;
        const vx = (-x1 - cx1) / rx;
        const vy = (-y1 - cy1) / ry;
        const start = std.math.atan2(uy, ux);
        var span = std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
        if (!sweep and span > 0) span -= std.math.tau;
        if (sweep and span < 0) span += std.math.tau;

        const quarters = @ceil(@abs(span) / (std.math.pi * 0.5) - 1e-4);
        const pieces: u32 = @intFromFloat(@max(quarters, 1));
        const step = span / @as(f32, @floatFromInt(pieces));
        const k = (4.0 / 3.0) * @tan(step * 0.25);

        var n: u32 = 0;
        while (n < pieces) : (n += 1) {
            const a0 = start + step * @as(f32, @floatFromInt(n));
            const a1 = a0 + step;
            const p0 = e.at(a0);
            // The last piece ends on the point the file named, not on the one
            // the trigonometry arrived at. A chain of arcs drifts otherwise,
            // and a contour that should close ends a fraction short.
            const p3 = if (n + 1 == pieces) to else e.at(a1);
            const t0 = e.tangentAt(a0);
            const t1 = e.tangentAt(a1);
            try p.cubicTo(
                .{ .x = p0.x + k * t0.x, .y = p0.y + k * t0.y },
                .{ .x = p3.x - k * t1.x, .y = p3.y - k * t1.y },
                p3,
            );
        }

        // An `S` after an arc has nothing to reflect. The spec restricts the
        // reflection to a previous cubic, and an arc is not one however it is
        // drawn here.
        p.cubic_ctrl = null;
    }

    fn close(p: *Parser) Error!void {
        try p.out.close(p.gpa);
        p.cur = p.begin;
        p.cubic_ctrl = null;
        p.quad_ctrl = null;
    }

    fn reflect(p: *const Parser, ctrl: ?Point) Point {
        const c = ctrl orelse return p.cur;
        return .{ .x = 2 * p.cur.x - c.x, .y = 2 * p.cur.y - c.y };
    }

    // -- lexing -------------------------------------------------------------

    fn point(p: *Parser, rel: bool) Error!Point {
        const x = try p.number();
        const y = try p.number();
        return if (rel) .{ .x = p.cur.x + x, .y = p.cur.y + y } else .{ .x = x, .y = y };
    }

    /// One number, in the grammar SVG actually uses rather than the one a
    /// float parser assumes. The difference that matters is that `1.5.3` is
    /// two numbers: a second decimal point ends the first, and icon sets put
    /// through a minifier are written exactly that way.
    fn number(p: *Parser) Error!f32 {
        p.skipSeparators();
        const start = p.i;

        if (p.i < p.d.len and (p.d[p.i] == '+' or p.d[p.i] == '-')) p.i += 1;
        var any = p.digits();
        if (p.i < p.d.len and p.d[p.i] == '.') {
            p.i += 1;
            any = p.digits() or any;
        }
        if (!any) return error.BadPathData;

        if (p.i < p.d.len and (p.d[p.i] == 'e' or p.d[p.i] == 'E')) {
            const mantissa = p.i;
            p.i += 1;
            if (p.i < p.d.len and (p.d[p.i] == '+' or p.d[p.i] == '-')) p.i += 1;
            // `10e` is a number followed by a bad byte, not a bad number, and
            // the difference decides which message a theme author gets.
            if (!p.digits()) p.i = mantissa;
        }

        return std.fmt.parseFloat(f32, p.d[start..p.i]) catch error.BadPathData;
    }

    /// An arc flag: one character, `0` or `1`, and not a number.
    ///
    /// That distinction is the whole reason this is not `number`. The flags
    /// need no separator after them, so `a1 1 0 011 0` is a valid arc with
    /// both flags and an x of 1 packed into `011` -- and every minified icon
    /// set writes them that way.
    fn flag(p: *Parser) Error!bool {
        p.skipSeparators();
        if (p.i == p.d.len) return error.BadPathData;
        const c = p.d[p.i];
        if (c != '0' and c != '1') return error.BadPathData;
        p.i += 1;
        return c == '1';
    }

    fn digits(p: *Parser) bool {
        const start = p.i;
        while (p.i < p.d.len and std.ascii.isDigit(p.d[p.i])) p.i += 1;
        return p.i != start;
    }

    /// Whitespace and commas, in any order and any number. The grammar is
    /// stricter -- at most one comma between two numbers -- and being strict
    /// here would reject data every other renderer accepts.
    fn skipSeparators(p: *Parser) void {
        while (p.i < p.d.len) : (p.i += 1) {
            switch (p.d[p.i]) {
                ' ', '\t', '\r', '\n', 0x0c, ',' => {},
                else => return,
            }
        }
    }
};

/// The ellipse an arc lies on, once it has been recovered from the endpoints.
/// Rotated, so the two accessors carry the rotation rather than the caller
/// rotating every point it gets back.
const Ellipse = struct {
    c: Point,
    rx: f32,
    ry: f32,
    cos_phi: f32,
    sin_phi: f32,

    fn at(e: Ellipse, a: f32) Point {
        const ca = @cos(a);
        const sa = @sin(a);
        return .{
            .x = e.c.x + e.rx * ca * e.cos_phi - e.ry * sa * e.sin_phi,
            .y = e.c.y + e.rx * ca * e.sin_phi + e.ry * sa * e.cos_phi,
        };
    }

    /// The derivative with respect to the angle, which is what the cubic's
    /// control points run along. Not normalised: its length is part of the
    /// `4/3 tan(t/4)` scaling.
    fn tangentAt(e: Ellipse, a: f32) Point {
        const ca = @cos(a);
        const sa = @sin(a);
        return .{
            .x = -e.rx * sa * e.cos_phi - e.ry * ca * e.sin_phi,
            .y = -e.rx * sa * e.sin_phi + e.ry * ca * e.cos_phi,
        };
    }
};

fn isCommand(c: u8) bool {
    return switch (std.ascii.toUpper(c)) {
        'M', 'L', 'H', 'V', 'C', 'S', 'Q', 'T', 'A', 'Z' => true,
        else => false,
    };
}

fn startsNumber(c: u8) bool {
    return std.ascii.isDigit(c) or c == '+' or c == '-' or c == '.';
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const Verb = geom.Verb;

fn parsed(d: []const u8, opts: Options) !Outline {
    var o: Outline = .{};
    errdefer o.deinit(testing.allocator);
    try parse(testing.allocator, &o, d, opts);
    return o;
}

test "the operators that need no arithmetic" {
    var o = try parsed("M 1 2 L 3 4 H 5 V 6 Z", .{});
    defer o.deinit(testing.allocator);

    try testing.expectEqualSlices(Verb, &.{ .move, .line, .line, .line, .close }, o.verbs.items);
    const p = o.points.items;
    try testing.expectEqual(Point{ .x = 1, .y = 2 }, p[0]);
    try testing.expectEqual(Point{ .x = 3, .y = 4 }, p[1]);
    // H keeps y, V keeps x, and both are absolute.
    try testing.expectEqual(Point{ .x = 5, .y = 4 }, p[2]);
    try testing.expectEqual(Point{ .x = 5, .y = 6 }, p[3]);
}

test "lower case is relative to the pen" {
    var o = try parsed("m10 10 l5 0 h5 v5 z", .{});
    defer o.deinit(testing.allocator);

    const p = o.points.items;
    try testing.expectEqual(Point{ .x = 10, .y = 10 }, p[0]);
    try testing.expectEqual(Point{ .x = 15, .y = 10 }, p[1]);
    try testing.expectEqual(Point{ .x = 20, .y = 10 }, p[2]);
    try testing.expectEqual(Point{ .x = 20, .y = 15 }, p[3]);
}

test "a repeated moveto is a lineto, and a repeated anything else is itself" {
    var o = try parsed("M0 0 1 0 2 0", .{});
    defer o.deinit(testing.allocator);

    // One contour of three points, not three contours of one.
    try testing.expectEqual(@as(u32, 1), o.contourCount());
    try testing.expectEqualSlices(Verb, &.{ .move, .line, .line }, o.verbs.items);

    var c = try parsed("M0 0 C1 1 2 1 3 0 4 -1 5 -1 6 0", .{});
    defer c.deinit(testing.allocator);
    try testing.expectEqualSlices(Verb, &.{ .move, .cubic, .cubic }, c.verbs.items);
}

test "a relative moveto after a close starts where the close left the pen" {
    var o = try parsed("M10 10 h5 z m0 5 h5", .{});
    defer o.deinit(testing.allocator);

    // `z` returns the pen to (10,10), so the second contour begins at (10,15)
    // and not at (15,15) where the line had ended.
    try testing.expectEqual(@as(u32, 2), o.contourCount());
    // A close is a verb with no point of its own, so the second contour's
    // move is the third point and not the fourth.
    try testing.expectEqual(Point{ .x = 10, .y = 15 }, o.points.items[2]);
}

test "S reflects the previous cubic control, and a lone S has nothing to reflect" {
    var o = try parsed("M0 0 C0 10 10 10 10 0 S20 -10 20 0", .{});
    defer o.deinit(testing.allocator);

    // The reflection of (10,10) through the pen at (10,0).
    try testing.expectEqual(Point{ .x = 10, .y = -10 }, o.points.items[4]);

    var lone = try parsed("M5 5 S10 0 15 5", .{});
    defer lone.deinit(testing.allocator);
    // No curve before it, so the control is the current point itself.
    try testing.expectEqual(Point{ .x = 5, .y = 5 }, lone.points.items[1]);
}

test "T reflects the previous quadratic control across an elevation" {
    var o = try parsed("M0 0 Q5 10 10 0 T20 0", .{});
    defer o.deinit(testing.allocator);

    // Both quadratics arrive as cubics, so the check is on the curve rather
    // than on a stored control: the reflected quadratic control is (15,-10),
    // whose elevated first cubic control is two thirds of the way there from
    // the pen at (10,0).
    try testing.expectEqualSlices(Verb, &.{ .move, .cubic, .cubic }, o.verbs.items);
    const c1 = o.points.items[4];
    try testing.expectApproxEqAbs(@as(f32, 10 + (2.0 / 3.0) * 5), c1.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -(2.0 / 3.0) * 10), c1.y, 1e-4);
}

test "the view box matrix flips y and scales to the em" {
    var o = try parsed("M0 0 L24 24", .{ .transform = viewBox(24, 1000) });
    defer o.deinit(testing.allocator);

    // The top left of the icon grid is the top left of the em square, and its
    // bottom right sits on the baseline at the full em width.
    try testing.expectEqual(Point{ .x = 0, .y = 1000 }, o.points.items[0]);
    try testing.expectEqual(Point{ .x = 1000, .y = 0 }, o.points.items[1]);
}

test "reflection happens before the matrix, not after" {
    var o = try parsed("M0 0 C0 10 10 10 10 0 S20 -10 20 0", .{ .transform = viewBox(24, 24) });
    defer o.deinit(testing.allocator);

    // The same reflected control as above, then flipped: 24 - (-10).
    try testing.expectEqual(Point{ .x = 10, .y = 34 }, o.points.items[4]);
}

test "the number grammar, as a minifier writes it" {
    var o = try parsed("M.5.5L1e1 2 -3-4", .{});
    defer o.deinit(testing.allocator);

    const p = o.points.items;
    // A second decimal point ends the first number.
    try testing.expectEqual(Point{ .x = 0.5, .y = 0.5 }, p[0]);
    try testing.expectEqual(Point{ .x = 10, .y = 2 }, p[1]);
    // A minus sign is a separator as well as a sign.
    try testing.expectEqual(Point{ .x = -3, .y = -4 }, p[2]);
}

test "a stray byte fails the whole string" {
    const gpa = testing.allocator;
    var o: Outline = .{};
    defer o.deinit(gpa);

    try testing.expectError(error.BadPathData, parse(gpa, &o, "M0 0 L10 10 X", .{}));
    try testing.expectError(error.BadPathData, parse(gpa, &o, "M0 0 L10", .{}));
    try testing.expectError(error.BadPathData, parse(gpa, &o, "10 10", .{}));
    // An arc flag is one character and only ever `0` or `1`.
    try testing.expectError(error.BadPathData, parse(gpa, &o, "M0 0 A5 5 0 2 1 10 0", .{}));

    // Empty data is a glyph with no ink, which is a space and not an error.
    var empty: Outline = .{};
    defer empty.deinit(gpa);
    try parse(gpa, &empty, "   ", .{});
    try testing.expect(empty.isEmpty());
}

test "an arc's flags choose which way round it goes" {
    // A half circle from (0,0) to (10,0). The sweep flag is the whole
    // difference between the two, and it mirrors the arc about the chord.
    var up = try parsed("M0 0 A5 5 0 1 1 10 0", .{});
    defer up.deinit(testing.allocator);
    var down = try parsed("M0 0 A5 5 0 1 0 10 0", .{});
    defer down.deinit(testing.allocator);

    const a = up.bounds();
    try testing.expectApproxEqAbs(@as(f32, -5), a.min_y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), a.max_y, 1e-3);

    const b = down.bounds();
    try testing.expectApproxEqAbs(@as(f32, 0), b.min_y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 5), b.max_y, 1e-3);

    // Half a turn is two quarters, and each is one cubic.
    try testing.expectEqualSlices(Verb, &.{ .move, .cubic, .cubic }, up.verbs.items);
}

test "an arc lands exactly on the point it was given" {
    // Two arcs and a close: the contour has to meet itself, which it will not
    // if the endpoint comes from the trigonometry rather than from the file.
    var o = try parsed("M2 12 a10 10 0 1 1 20 0 a10 10 0 1 1 -20 0 z", .{});
    defer o.deinit(testing.allocator);

    const p = o.points.items;
    const last = p[p.len - 1];
    try testing.expectEqual(@as(f32, 2), last.x);
    try testing.expectEqual(@as(f32, 12), last.y);

    const b = o.bounds();
    try testing.expectApproxEqAbs(@as(f32, 2), b.min_x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 22), b.max_x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 2), b.min_y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 22), b.max_y, 1e-3);
}

test "radii too small are grown, and a radius of zero is a line" {
    // The gap is twenty and the radii are one: F.6.6 scales them until the
    // ellipse reaches, rather than refusing the path.
    var grown = try parsed("M0 0 A1 1 0 0 1 20 0", .{});
    defer grown.deinit(testing.allocator);
    const b = grown.bounds();
    try testing.expectApproxEqAbs(@as(f32, 20), b.max_x, 1e-2);
    try testing.expectApproxEqAbs(@as(f32, -10), b.min_y, 1e-2);

    var flat = try parsed("M0 0 A0 5 0 0 1 20 0", .{});
    defer flat.deinit(testing.allocator);
    try testing.expectEqualSlices(Verb, &.{ .move, .line }, flat.verbs.items);
}

test "the arc flags need no separator after them" {
    // `011 0` is large=0, sweep=1, then the point (1,0). A number parser
    // would read `011` as eleven and the path would be a different shape.
    var packed_flags = try parsed("M0 0a1 1 0 011 0", .{});
    defer packed_flags.deinit(testing.allocator);
    var spaced = try parsed("M0 0 a1 1 0 0 1 1 0", .{});
    defer spaced.deinit(testing.allocator);

    try testing.expectEqualSlices(Point, spaced.points.items, packed_flags.points.items);
}

test "an S after an arc has nothing to reflect" {
    var o = try parsed("M0 0 A5 5 0 0 1 10 0 S15 5 20 0", .{});
    defer o.deinit(testing.allocator);

    // The first control of the S is the pen itself, not a reflection of the
    // last control the arc's cubics happened to leave behind.
    const p = o.points.items;
    const s_first = p[p.len - 3];
    try testing.expectApproxEqAbs(@as(f32, 10), s_first.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), s_first.y, 1e-4);
}

test "a real icon, as an icon set publishes it" {
    // The bookmark: a tall rectangle with a notch cut into its bottom edge.
    var o = try parsed("M6 2h12v20l-6-5-6 5z", .{ .transform = viewBox(24, 1000) });
    defer o.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), o.contourCount());
    try testing.expectEqualSlices(
        Verb,
        &.{ .move, .line, .line, .line, .line, .close },
        o.verbs.items,
    );

    const b = o.bounds();
    try testing.expectApproxEqAbs(@as(f32, 250), b.min_x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 750), b.max_x, 1e-3);
    // The grid's y=22 is the lowest ink, a twelfth of the em above the
    // baseline once flipped.
    try testing.expectApproxEqAbs(@as(f32, 1000.0 / 12.0), b.min_y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1000 - 1000.0 / 12.0), b.max_y, 1e-3);
}
