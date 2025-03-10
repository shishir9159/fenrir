//! The instance the rect pipeline draws, and the packing that gets it there.
//!
//! One primitive does all of it. A filled rectangle, a rounded panel, a
//! button border, a drop shadow, an image, and a glyph are the same 96 bytes
//! with different fields set; there is no second vertex format, no second
//! shader, and no state to change between any two of them. That is the whole
//! reason this renderer can put a frame on the screen in one draw call, and
//! it is worth being strict about: anything that cannot be expressed as an
//! axis-aligned rounded box with a texture on it belongs to the path
//! pipeline, not here.
//!
//! ## Why the clip rectangle lives in the instance
//!
//! The obvious place for a scissor is the command buffer, one
//! `vkCmdSetScissor` per clipped region, and that is what most immediate-mode
//! renderers do -- RAD Debugger included, which groups its rects into batches
//! keyed on the clip. It costs a draw call every time the clip changes, and a
//! UI changes its clip constantly: every scroll view, every list row that
//! elides, every text field. A frame with two hundred clipped regions is two
//! hundred draw calls.
//!
//! Sixteen bytes per instance buys all of them back. The vertex shader shrinks
//! the quad to the intersection of the rect and its clip, so the clip is
//! enforced by rasterisation rather than by state, and instances with
//! different clips sit next to each other in one buffer. It is also strictly
//! less work on the GPU than a scissor test, because the clipped-away
//! fragments are never generated in the first place.
//!
//! ## Layout
//!
//! `extern struct`, laid out to match a `std430` storage buffer exactly: every
//! member is 16-byte aligned, the whole thing is 96 bytes, and the array
//! stride is therefore 96 with no padding for the driver to insert. The
//! matching GLSL declaration is in `shader/rect.glsl`, and `size_matches`
//! below fails the build if the two drift apart in size.

const std = @import("std");

const geom = @import("../gelgja/geom.zig");
const paint = @import("../gelgja/paint.zig");
const sdf = @import("sdf.zig");

const Bounds = geom.Bounds;
const Color = paint.Color;
const Radius = sdf.Radius;

/// An index into the texture array bound for the frame. Zero is reserved for
/// "no texture", so a `TextureId` doubles as an optional without a tag byte.
pub const TextureId = u32;

pub const no_texture: TextureId = 0;

pub const Flags = packed struct(u32) {
    /// Sample `src` from `texture` and modulate the colour by it.
    textured: bool = false,
    /// The texture holds coverage in its red channel rather than colour: a
    /// glyph out of Týr's atlas, or a mask. Only alpha is modulated.
    alpha_texture: bool = false,
    _reserved: u30 = 0,

    pub const none: Flags = .{};
};

/// Non-premultiplied RGBA packed one byte per channel, red in the low byte, to
/// match GLSL's `unpackUnorm4x8`.
///
/// The three colour channels are sRGB-encoded and alpha is linear, which is
/// both what a PDF `/DeviceRGB` triple already is and what a person writing UI
/// code means when they type `0.5`. Eight bits is exactly the right budget for
/// an sRGB-encoded value -- that encoding exists to make it so -- whereas eight
/// bits of *linear* light bands visibly in the darks. The shader decodes to
/// linear before it blends anything.
pub const Rgba8 = u32;

pub fn pack(c: Color) Rgba8 {
    const q = struct {
        fn f(v: f32) u32 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255.0));
        }
    }.f;
    return q(c.r) | (q(c.g) << 8) | (q(c.b) << 16) | (q(c.a) << 24);
}

pub fn unpack(v: Rgba8) Color {
    const q = struct {
        fn f(b: u32) f32 {
            return @as(f32, @floatFromInt(b & 0xff)) / 255.0;
        }
    }.f;
    return .{ .r = q(v), .g = q(v >> 8), .b = q(v >> 16), .a = q(v >> 24) };
}

/// The sRGB transfer function, matching GLSL's `srgbToLinear` in
/// `shader/rect.frag`. The software rasteriser uses this so that its output
/// and the GPU's can be compared pixel for pixel.
pub fn srgbToLinear(s: f32) f32 {
    return if (s <= 0.04045) s / 12.92 else std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
}

pub fn linearToSrgb(l: f32) f32 {
    return if (l <= 0.0031308) l * 12.92 else 1.055 * std.math.pow(f32, l, 1.0 / 2.4) - 0.055;
}

pub const Instance = extern struct {
    /// The rectangle, in device pixels: min x, min y, max x, max y.
    dst: [4]f32,
    /// Texture coordinates for the four sides, normalised. Meaningless unless
    /// `flags.textured`; the CPU divides by the texture size so the shader
    /// never needs to know it.
    src: [4]f32 = .{ 0, 0, 1, 1 },
    /// The scissor, in device pixels. Enforced by shrinking the quad, not by
    /// pipeline state -- see the header.
    clip: [4]f32,
    /// Corner radii, clockwise from the top left, already clamped to half the
    /// shorter side.
    radius: [4]f32 = .{ 0, 0, 0, 0 },
    /// Corner colours in the same order. All four equal is a flat fill, which
    /// is the overwhelmingly common case and costs nothing extra.
    color: [4]Rgba8,
    /// Ring thickness in pixels, drawn inside the edge. Zero fills.
    border: f32 = 0,
    /// Shadow radius in pixels. Zero still antialiases.
    softness: f32 = 0,
    texture: TextureId = no_texture,
    flags: Flags = .none,

    pub fn rect(i: Instance) Bounds {
        return .{ .min_x = i.dst[0], .min_y = i.dst[1], .max_x = i.dst[2], .max_y = i.dst[3] };
    }

    pub fn clipRect(i: Instance) Bounds {
        return .{ .min_x = i.clip[0], .min_y = i.clip[1], .max_x = i.clip[2], .max_y = i.clip[3] };
    }

    /// Every pixel this instance can affect: the rectangle grown by the soft
    /// falloff, then cut down by the clip.
    ///
    /// A shadow reaches beyond its own rectangle, so the quad has to be grown
    /// or the blur is sliced off square. The pad is `2 * softness` because
    /// that is where `sdf.coverage` reaches zero, plus one pixel for the
    /// antialiasing ramp on a hard edge.
    pub fn touched(i: Instance) Bounds {
        const pad = @max(i.softness * 2.0, 1.0);
        const grown: Bounds = .{
            .min_x = i.dst[0] - pad,
            .min_y = i.dst[1] - pad,
            .max_x = i.dst[2] + pad,
            .max_y = i.dst[3] + pad,
        };
        return grown.intersect(i.clipRect());
    }

    /// True when nothing this instance draws can land on a pixel, so the
    /// caller can drop it before it reaches the buffer.
    pub fn isInvisible(i: Instance) bool {
        if (i.touched().isEmpty()) return true;
        if (i.dst[2] <= i.dst[0] or i.dst[3] <= i.dst[1]) return true;
        // Fully transparent at every corner. Checked on the packed bytes so
        // this stays a handful of integer compares.
        const opaque_anywhere = (i.color[0] | i.color[1] | i.color[2] | i.color[3]) & 0xff00_0000;
        return opaque_anywhere == 0;
    }
};

// Guards the one invariant the GPU cannot check for us. A mismatch here is a
// silent, total corruption of every frame -- every instance after the first
// reads a few bytes off -- and it is the kind of thing that happens when
// someone adds a field in a hurry.
comptime {
    std.debug.assert(@sizeOf(Instance) == 96);
    std.debug.assert(@alignOf(Instance) == 4);
    std.debug.assert(@offsetOf(Instance, "dst") == 0);
    std.debug.assert(@offsetOf(Instance, "src") == 16);
    std.debug.assert(@offsetOf(Instance, "clip") == 32);
    std.debug.assert(@offsetOf(Instance, "radius") == 48);
    std.debug.assert(@offsetOf(Instance, "color") == 64);
    std.debug.assert(@offsetOf(Instance, "border") == 80);
    std.debug.assert(@offsetOf(Instance, "softness") == 84);
    std.debug.assert(@offsetOf(Instance, "texture") == 88);
    std.debug.assert(@offsetOf(Instance, "flags") == 92);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "packing a colour round-trips within a byte" {
    for ([_]Color{
        .black,
        .white,
        .transparent,
        .gray(0.5),
        .{ .r = 0.1, .g = 0.7, .b = 0.33, .a = 0.9 },
    }) |c| {
        const back = unpack(pack(c));
        try testing.expectApproxEqAbs(c.r, back.r, 1.0 / 255.0);
        try testing.expectApproxEqAbs(c.g, back.g, 1.0 / 255.0);
        try testing.expectApproxEqAbs(c.b, back.b, 1.0 / 255.0);
        try testing.expectApproxEqAbs(c.a, back.a, 1.0 / 255.0);
    }
}

test "red is in the low byte, alpha in the high one" {
    try testing.expectEqual(@as(Rgba8, 0xff0000ff), pack(.{ .r = 1, .g = 0, .b = 0 }));
    try testing.expectEqual(@as(Rgba8, 0xffff0000), pack(.{ .r = 0, .g = 0, .b = 1 }));
    try testing.expectEqual(@as(Rgba8, 0x00000000), pack(Color.transparent));
}

test "out-of-range colour components are clamped, not wrapped" {
    // The interpreter can produce these: a tint transform is an arbitrary
    // PDF function and nothing bounds its output.
    try testing.expectEqual(@as(Rgba8, 0xff0000ff), pack(.{ .r = 4.0, .g = -1.0, .b = -0.0 }));
}

test "the sRGB transfer function round-trips and brackets linear" {
    var s: f32 = 0;
    while (s <= 1.0) : (s += 1.0 / 64.0) {
        try testing.expectApproxEqAbs(s, linearToSrgb(srgbToLinear(s)), 1e-5);
    }
    // Mid grey is the case that makes the encoding worth having: half of the
    // encoded range is a fifth of the light.
    try testing.expectApproxEqAbs(0.2140, srgbToLinear(0.5), 1e-3);
    try testing.expectEqual(@as(f32, 0), srgbToLinear(0));
    try testing.expectApproxEqAbs(1.0, srgbToLinear(1.0), 1e-6);
}

test "touched grows by the shadow and is then cut by the clip" {
    const i: Instance = .{
        .dst = .{ 10, 10, 20, 20 },
        .clip = .{ 0, 0, 100, 100 },
        .color = @splat(pack(.white)),
        .softness = 4,
    };
    // 2 * softness on every side.
    try testing.expectEqual(Bounds.fromRect(2, 2, 28, 28), i.touched());

    var clipped = i;
    clipped.clip = .{ 0, 0, 15, 15 };
    try testing.expectEqual(Bounds.fromRect(2, 2, 15, 15), clipped.touched());
}

test "a hard edge is still padded by a pixel for its antialiasing" {
    const i: Instance = .{
        .dst = .{ 10, 10, 20, 20 },
        .clip = .{ 0, 0, 100, 100 },
        .color = @splat(pack(.white)),
    };
    try testing.expectEqual(Bounds.fromRect(9, 9, 21, 21), i.touched());
}

test "invisible instances are recognised" {
    const base: Instance = .{
        .dst = .{ 10, 10, 20, 20 },
        .clip = .{ 0, 0, 100, 100 },
        .color = @splat(pack(.white)),
    };
    try testing.expect(!base.isInvisible());

    var off_screen = base;
    off_screen.clip = .{ 500, 500, 600, 600 };
    try testing.expect(off_screen.isInvisible());

    var degenerate = base;
    degenerate.dst = .{ 10, 10, 10, 20 };
    try testing.expect(degenerate.isInvisible());

    var clear = base;
    clear.color = @splat(pack(.transparent));
    try testing.expect(clear.isInvisible());

    // One opaque corner is enough to keep it.
    var one_corner = clear;
    one_corner.color[2] = pack(.white);
    try testing.expect(!one_corner.isInvisible());
}
