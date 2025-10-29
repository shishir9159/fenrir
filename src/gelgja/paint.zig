//! What a command is painted with: colour, stroke parameters, blending.
//!
//! Colour arrives here already resolved to RGBA. The interpreter is what runs
//! the tint transform of a `/Separation`, the palette lookup of an `/Indexed`,
//! or the naive CMYK conversion, because all of those need the document and
//! none of them need the device. The cost is that a print backend cannot
//! recover the original CMYK; that is the right trade for a screen renderer
//! and the wrong one for a RIP, and it is the first thing to revisit if this
//! ever has to drive a printer.

const std = @import("std");
const Writer = std.Io.Writer;

const geom = @import("geom.zig");
const Range = geom.Range;
const Transform = geom.Transform;

/// Non-premultiplied RGBA in the range 0..1.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn gray(v: f32) Color {
        return .{ .r = v, .g = v, .b = v };
    }

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    /// The conversion every PDF reader uses and no colour scientist endorses.
    /// Correct output needs the destination profile; this is what you get
    /// without one, and it is what Acrobat does in the absence of colour
    /// management too.
    pub fn fromCmyk(c: f32, m: f32, y: f32, k: f32) Color {
        return .{
            .r = (1 - @min(1.0, c + k)),
            .g = (1 - @min(1.0, m + k)),
            .b = (1 - @min(1.0, y + k)),
        };
    }

    pub fn withAlpha(c: Color, a: f32) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }

    pub fn format(c: Color, w: *Writer) Writer.Error!void {
        if (c.a == 1) {
            try w.print("rgb({d:.3} {d:.3} {d:.3})", .{ c.r, c.g, c.b });
        } else {
            try w.print("rgba({d:.3} {d:.3} {d:.3} {d:.3})", .{ c.r, c.g, c.b, c.a });
        }
    }
};

/// An opaque handle to something the producer knows how to fetch: an image
/// XObject, a shading dictionary, a font program. Gelgja never dereferences
/// one -- it is the cord, not either end -- so the whole display list stays
/// free of any dependency on the PDF layer and can be built and tested with
/// no document at all.
///
/// For a PDF producer this is the object number. Zero means "none".
pub const ObjectId = u32;

pub const no_object: ObjectId = 0;

/// How an area is coloured.
pub const Paint = union(enum) {
    solid: Color,
    /// A gradient or mesh (`sh`, or a shading used as a pattern). Types 1-3
    /// are analytic; 4-7 are meshes. The parameters stay in the document.
    shading: Shading,
    /// A tiling pattern: a content stream replayed over a lattice. A backend
    /// renders it by interpreting that stream into its own display list.
    tiling: Tiling,

    pub fn opaqueColor(p: Paint) ?Color {
        return switch (p) {
            .solid => |c| if (c.a == 1) c else null,
            else => null,
        };
    }
};

pub const Shading = struct {
    object: ObjectId = no_object,
    /// `/ShadingType` 1-7, kept so a trace can say which without the document.
    kind: u8 = 0,
    /// Pattern space to page space.
    transform: Transform = .identity,
    /// The average colour, for backends that have not implemented this
    /// shading type yet. Better than a hole.
    approximation: Color = .gray(0.5),
};

pub const Tiling = struct {
    object: ObjectId = no_object,
    transform: Transform = .identity,
    approximation: Color = .gray(0.5),
};

/// `/LC` (§8.4.3.3).
pub const Cap = enum(u8) {
    butt = 0,
    round = 1,
    square = 2,

    pub fn opName(c: Cap) []const u8 {
        return @tagName(c);
    }
};

/// `/LJ` (§8.4.3.4).
pub const Join = enum(u8) {
    miter = 0,
    round = 1,
    bevel = 2,

    pub fn opName(j: Join) []const u8 {
        return @tagName(j);
    }
};

pub const Stroke = struct {
    /// In user space, before the CTM. A width of zero is legal and means the
    /// thinnest line the device can render (§8.4.3.2), which is why the
    /// command carries its matrix: the backend cannot resolve either the pen
    /// shape or a zero width without it.
    width: f32 = 1,
    cap: Cap = .butt,
    join: Join = .miter,
    miter_limit: f32 = 10,
    /// Into `DisplayList.scalars`. Empty means a solid line.
    dash: Range = .empty,
    dash_phase: f32 = 0,
};

/// `Tr` (§9.3.6). Mode 3 is how scanned documents carry an invisible OCR text
/// layer over the page image, so a renderer that ignores it draws garbage over
/// every scan.
pub const TextRenderMode = enum(u8) {
    fill = 0,
    stroke = 1,
    fill_stroke = 2,
    invisible = 3,
    fill_clip = 4,
    stroke_clip = 5,
    fill_stroke_clip = 6,
    clip = 7,

    pub fn fromInt(v: i64) TextRenderMode {
        return if (v >= 0 and v <= 7) @enumFromInt(@as(u8, @intCast(v))) else .fill;
    }

    pub fn fills(m: TextRenderMode) bool {
        return switch (m) {
            .fill, .fill_stroke, .fill_clip, .fill_stroke_clip => true,
            else => false,
        };
    }

    pub fn strokes(m: TextRenderMode) bool {
        return switch (m) {
            .stroke, .fill_stroke, .stroke_clip, .fill_stroke_clip => true,
            else => false,
        };
    }

    /// Modes 4-7 add the glyph outlines to the clip path at `ET`.
    pub fn clips(m: TextRenderMode) bool {
        return @intFromEnum(m) >= 4;
    }
};

/// `/BM` (§11.3.5). The separable modes are per-channel functions; the last
/// four are not, and need the whole backdrop colour.
pub const BlendMode = enum(u8) {
    normal,
    multiply,
    screen,
    overlay,
    darken,
    lighten,
    color_dodge,
    color_burn,
    hard_light,
    soft_light,
    difference,
    exclusion,
    hue,
    saturation,
    color,
    luminosity,

    pub fn fromName(name: []const u8) BlendMode {
        const table = .{
            .{ "Normal", BlendMode.normal },       .{ "Compatible", BlendMode.normal },
            .{ "Multiply", BlendMode.multiply },   .{ "Screen", BlendMode.screen },
            .{ "Overlay", BlendMode.overlay },     .{ "Darken", BlendMode.darken },
            .{ "Lighten", BlendMode.lighten },     .{ "ColorDodge", BlendMode.color_dodge },
            .{ "ColorBurn", BlendMode.color_burn }, .{ "HardLight", BlendMode.hard_light },
            .{ "SoftLight", BlendMode.soft_light }, .{ "Difference", BlendMode.difference },
            .{ "Exclusion", BlendMode.exclusion },  .{ "Hue", BlendMode.hue },
            .{ "Saturation", BlendMode.saturation }, .{ "Color", BlendMode.color },
            .{ "Luminosity", BlendMode.luminosity },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return .normal;
    }

    /// True for the twelve modes that operate one channel at a time, which a
    /// fixed-function blender can do without a backdrop read.
    pub fn isSeparable(m: BlendMode) bool {
        return @intFromEnum(m) < @intFromEnum(BlendMode.hue);
    }

    /// `B(Cb, Cs)` from §11.3.5: the blended colour, before it is composited.
    ///
    /// Both arguments and the result are in the blending colour space, which
    /// for a page with no group of its own is the device's -- so a backend
    /// that composites in sRGB passes sRGB here and one that composites in
    /// light passes light. The functions are defined on the numbers, not on
    /// the physics, so that is a choice the caller makes and this does not.
    pub fn blend(m: BlendMode, cb: [3]f32, cs: [3]f32) [3]f32 {
        if (m.isSeparable()) {
            var out: [3]f32 = undefined;
            for (&out, cb, cs) |*o, b, s| o.* = separable(m, b, s);
            return out;
        }
        return switch (m) {
            // §11.3.5.3. Each is "keep two of hue, saturation and luminosity
            // from one colour and take the third from the other", written out.
            .hue => setLum(setSat(cs, sat(cb)), lum(cb)),
            .saturation => setLum(setSat(cb, sat(cs)), lum(cb)),
            .color => setLum(cs, lum(cb)),
            .luminosity => setLum(cb, lum(cs)),
            else => unreachable,
        };
    }

    fn separable(m: BlendMode, b: f32, s: f32) f32 {
        return switch (m) {
            .normal => s,
            .multiply => b * s,
            .screen => b + s - b * s,
            // Overlay is HardLight with the arguments the other way round.
            // The spec says so outright, and it is the only reason the two
            // are not one entry.
            .overlay => separable(.hard_light, s, b),
            .darken => @min(b, s),
            .lighten => @max(b, s),
            .color_dodge => if (b <= 0) 0 else if (s >= 1) 1 else @min(1, b / (1 - s)),
            .color_burn => if (b >= 1) 1 else if (s <= 0) 0 else 1 - @min(1, (1 - b) / s),
            .hard_light => if (s <= 0.5)
                separable(.multiply, b, 2 * s)
            else
                separable(.screen, b, 2 * s - 1),
            .soft_light => blk: {
                // D(x), the spec's own piecewise approximation to a smooth
                // dodge-and-burn. The 16/12/4 polynomial below the knee is
                // not a simplification of the square root above it; they are
                // two different curves that happen to meet at a quarter.
                const d = if (b <= 0.25)
                    ((16 * b - 12) * b + 4) * b
                else
                    @sqrt(b);
                break :blk if (s <= 0.5)
                    b - (1 - 2 * s) * b * (1 - b)
                else
                    b + (2 * s - 1) * (d - b);
            },
            .difference => @abs(b - s),
            .exclusion => b + s - 2 * b * s,
            else => unreachable,
        };
    }

    fn lum(c: [3]f32) f32 {
        return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2];
    }

    fn sat(c: [3]f32) f32 {
        return @max(c[0], @max(c[1], c[2])) - @min(c[0], @min(c[1], c[2]));
    }

    fn setLum(c: [3]f32, l: f32) [3]f32 {
        const d = l - lum(c);
        return clipColor(.{ c[0] + d, c[1] + d, c[2] + d });
    }

    /// Pulls a colour that left the unit cube back into it *along the line
    /// towards its own luminosity*, which is what keeps the hue: clamping
    /// each channel independently would not.
    fn clipColor(c: [3]f32) [3]f32 {
        const l = lum(c);
        const lo = @min(c[0], @min(c[1], c[2]));
        const hi = @max(c[0], @max(c[1], c[2]));
        var out = c;
        if (lo < 0 and l != lo) {
            for (&out, c) |*o, v| o.* = l + (v - l) * l / (l - lo);
        }
        if (hi > 1 and hi != l) {
            for (&out) |*o| o.* = l + (o.* - l) * (1 - l) / (hi - l);
        }
        return out;
    }

    fn setSat(c: [3]f32, s: f32) [3]f32 {
        // The spec writes this as min/mid/max by name; here the three indices
        // are found instead, so the values stay in their own channels.
        var lo: usize = 0;
        var hi: usize = 0;
        for (c, 0..) |v, i| {
            if (v < c[lo]) lo = i;
            if (v > c[hi]) hi = i;
        }
        if (lo == hi) return .{ 0, 0, 0 };
        const mid = 3 - lo - hi;

        var out: [3]f32 = undefined;
        out[hi] = s;
        out[mid] = (c[mid] - c[lo]) * s / (c[hi] - c[lo]);
        out[lo] = 0;
        return out;
    }
};

/// A transparency group (§11.6.6): everything until the matching pop composites
/// into an offscreen buffer, then that buffer composites into the parent with
/// these parameters.
pub const Layer = struct {
    /// `/ca` for fills, `/CA` for strokes. The interpreter folds the relevant
    /// one into each paint's alpha; this is the group's own constant alpha.
    alpha: f32 = 1,
    blend: BlendMode = .normal,
    /// An `/SMask` luminosity or alpha mask. The backend interprets that form
    /// XObject into its own display list and uses the result as a mask.
    soft_mask: ObjectId = no_object,
    /// An isolated group composites against transparent black rather than
    /// against its backdrop.
    isolated: bool = false,
    /// A knockout group composites every element against the group's initial
    /// backdrop rather than against the elements before it.
    knockout: bool = false,

    pub const opaque_normal: Layer = .{};

    /// True when the group changes nothing and a backend may skip the
    /// offscreen buffer entirely -- which is the common case, and worth
    /// detecting because that buffer is expensive.
    pub fn isTrivial(l: Layer) bool {
        return l.alpha == 1 and l.blend == .normal and
            l.soft_mask == no_object and !l.isolated and !l.knockout;
    }
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "cmyk conversion hits the obvious corners" {
    try testing.expectEqual(Color.white, Color.fromCmyk(0, 0, 0, 0));
    try testing.expectEqual(Color.black, Color.fromCmyk(0, 0, 0, 1));

    const cyan = Color.fromCmyk(1, 0, 0, 0);
    try testing.expectApproxEqAbs(@as(f32, 0), cyan.r, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), cyan.g, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), cyan.b, 1e-6);
}

test "text render modes classify correctly" {
    try testing.expect(TextRenderMode.fill.fills());
    try testing.expect(!TextRenderMode.fill.strokes());
    try testing.expect(!TextRenderMode.fill.clips());

    try testing.expect(TextRenderMode.fill_stroke.fills());
    try testing.expect(TextRenderMode.fill_stroke.strokes());

    // Mode 3 paints nothing at all -- the OCR layer over a scan.
    try testing.expect(!TextRenderMode.invisible.fills());
    try testing.expect(!TextRenderMode.invisible.strokes());
    try testing.expect(!TextRenderMode.invisible.clips());

    try testing.expect(TextRenderMode.clip.clips());
    try testing.expect(TextRenderMode.fill_stroke_clip.clips());
}

test "out of range render modes fall back to fill" {
    try testing.expectEqual(TextRenderMode.fill, TextRenderMode.fromInt(-1));
    try testing.expectEqual(TextRenderMode.fill, TextRenderMode.fromInt(99));
    try testing.expectEqual(TextRenderMode.invisible, TextRenderMode.fromInt(3));
}

test "blend mode names and separability" {
    try testing.expectEqual(BlendMode.multiply, BlendMode.fromName("Multiply"));
    try testing.expectEqual(BlendMode.normal, BlendMode.fromName("Compatible"));
    try testing.expectEqual(BlendMode.normal, BlendMode.fromName("NotAMode"));

    try testing.expect(BlendMode.multiply.isSeparable());
    try testing.expect(!BlendMode.hue.isSeparable());
    try testing.expect(!BlendMode.luminosity.isSeparable());
}

test "every blend mode leaves its own identity colour alone" {
    // Each separable mode has a source value that makes it the identity, and
    // it is a different value for each. Checking the whole set against a
    // backdrop that is not grey catches an entry that was copied from the
    // line above it and not edited -- which is how these tables go wrong.
    const b = [3]f32{ 0.2, 0.5, 0.9 };
    const cases = [_]struct { m: BlendMode, s: [3]f32 }{
        .{ .m = .multiply, .s = @splat(1) },
        .{ .m = .screen, .s = @splat(0) },
        .{ .m = .overlay, .s = @splat(0.5) },
        .{ .m = .darken, .s = @splat(1) },
        .{ .m = .lighten, .s = @splat(0) },
        .{ .m = .color_dodge, .s = @splat(0) },
        .{ .m = .color_burn, .s = @splat(1) },
        .{ .m = .hard_light, .s = @splat(0.5) },
        .{ .m = .soft_light, .s = @splat(0.5) },
        .{ .m = .difference, .s = @splat(0) },
        .{ .m = .exclusion, .s = @splat(0) },
    };
    for (cases) |c| {
        const got = c.m.blend(b, c.s);
        for (got, b) |g, want| try testing.expectApproxEqAbs(want, g, 1e-5);
    }
}

test "multiply darkens and screen lightens, and neither can escape the unit range" {
    const half = [3]f32{ 0.5, 0.5, 0.5 };
    const got = BlendMode.multiply.blend(half, half);
    try testing.expectApproxEqAbs(@as(f32, 0.25), got[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.75), BlendMode.screen.blend(half, half)[0], 1e-5);

    // The two are duals: multiply(b, s) = 1 - screen(1-b, 1-s).
    const b = [3]f32{ 0.1, 0.4, 0.8 };
    const s = [3]f32{ 0.7, 0.2, 0.3 };
    const inv_b = [3]f32{ 1 - b[0], 1 - b[1], 1 - b[2] };
    const inv_s = [3]f32{ 1 - s[0], 1 - s[1], 1 - s[2] };
    const m = BlendMode.multiply.blend(b, s);
    const sc = BlendMode.screen.blend(inv_b, inv_s);
    for (m, sc) |mv, sv| try testing.expectApproxEqAbs(mv, 1 - sv, 1e-5);
}

test "overlay is hard light with the arguments exchanged" {
    const b = [3]f32{ 0.2, 0.55, 0.9 };
    const s = [3]f32{ 0.8, 0.3, 0.45 };
    const over = BlendMode.overlay.blend(b, s);
    const hard = BlendMode.hard_light.blend(s, b);
    for (over, hard) |o, h| try testing.expectApproxEqAbs(o, h, 1e-6);
}

test "the non-separable modes move exactly the attribute they name" {
    const b = [3]f32{ 0.2, 0.6, 0.4 };
    const s = [3]f32{ 0.9, 0.1, 0.3 };

    // Luminosity takes the backdrop's colour and the source's brightness, so
    // the result's luminosity is the source's.
    const l = BlendMode.luminosity.blend(b, s);
    try testing.expectApproxEqAbs(BlendMode.lum(s), BlendMode.lum(l), 1e-4);

    // Color is its mirror: the source's colour at the backdrop's brightness.
    const c = BlendMode.color.blend(b, s);
    try testing.expectApproxEqAbs(BlendMode.lum(b), BlendMode.lum(c), 1e-4);

    // Saturation keeps the backdrop.s brightness and takes the source.s
    // saturation -- as far as the unit cube allows. Setting the saturation to
    // 0.8 and then the luminosity back to the backdrop.s pushes a channel
    // below zero here, and pulling it back in costs some of the saturation
    // that was just set. That is the spec.s own order of operations, not a
    // rounding error: brightness wins, and the result is merely more
    // saturated than the backdrop was.
    const sat_result = BlendMode.saturation.blend(b, s);
    try testing.expectApproxEqAbs(BlendMode.lum(b), BlendMode.lum(sat_result), 1e-4);
    try testing.expect(BlendMode.sat(sat_result) > BlendMode.sat(b));
    try testing.expect(BlendMode.sat(sat_result) <= BlendMode.sat(s) + 1e-5);

    // And a grey source has no hue to donate, so `hue` returns a grey.
    const grey = BlendMode.hue.blend(b, .{ 0.5, 0.5, 0.5 });
    try testing.expectApproxEqAbs(grey[0], grey[1], 1e-5);
    try testing.expectApproxEqAbs(grey[1], grey[2], 1e-5);
}

test "clipping a colour back into the cube keeps it in the cube" {
    // `setLum` can push a channel past one or below zero, and the pull-back
    // has to be towards the luminance rather than a per-channel clamp -- a
    // clamp would change the hue, which is the one thing these modes exist to
    // preserve.
    for ([_][3]f32{
        .{ 0.9, 0.95, 1.0 },
        .{ 0.02, 0.0, 0.1 },
        .{ 1.0, 0.0, 0.5 },
    }) |c| {
        for ([_]f32{ 0, 0.25, 0.5, 0.9, 1 }) |target| {
            const out = BlendMode.setLum(c, target);
            for (out) |v| {
                try testing.expect(v >= -1e-5 and v <= 1 + 1e-5);
            }
        }
    }
}

test "a default layer is trivial and can be skipped" {
    try testing.expect(Layer.opaque_normal.isTrivial());
    try testing.expect(!(Layer{ .alpha = 0.5 }).isTrivial());
    try testing.expect(!(Layer{ .blend = .multiply }).isTrivial());
    try testing.expect(!(Layer{ .soft_mask = 12 }).isTrivial());
}
