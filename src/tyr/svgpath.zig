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
//! draw list never learn that icons exist. Elliptical arcs are the one
//! operator with no counterpart, and they are the next commit.
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

fn isCommand(c: u8) bool {
    return switch (std.ascii.toUpper(c)) {
        'M', 'L', 'H', 'V', 'C', 'S', 'Q', 'T', 'Z' => true,
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
    // Arcs parse as soon as they are written, and not before.
    try testing.expectError(error.BadPathData, parse(gpa, &o, "M0 0 A1 1 0 0 1 2 2", .{}));

    // Empty data is a glyph with no ink, which is a space and not an error.
    var empty: Outline = .{};
    defer empty.deinit(gpa);
    try parse(gpa, &empty, "   ", .{});
    try testing.expect(empty.isEmpty());
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
