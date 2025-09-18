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

test "a default layer is trivial and can be skipped" {
    try testing.expect(Layer.opaque_normal.isTrivial());
    try testing.expect(!(Layer{ .alpha = 0.5 }).isTrivial());
    try testing.expect(!(Layer{ .blend = .multiply }).isTrivial());
    try testing.expect(!(Layer{ .soft_mask = 12 }).isTrivial());
}
