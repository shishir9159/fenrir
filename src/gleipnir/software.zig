//! A CPU rasteriser for the rect pipeline, used as an oracle rather than as a
//! renderer.
//!
//! It exists because the GPU half of this pipeline cannot be tested. There is
//! no device yet, and when there is one, a test that needs a swapchain to run
//! is a test that will not run in CI, on a headless machine, or under a
//! debugger. So the shader's arithmetic lives in `sdf.zig`, this file drives
//! it over a framebuffer exactly the way a fragment shader would -- one pixel
//! centre at a time, in submission order, with the same blend equation -- and
//! `shader/rect.frag` is the third copy, the one that has to agree with the
//! other two.
//!
//! That makes the first real GPU bring-up a diff rather than an investigation:
//! render a frame both ways, subtract, and any difference is in the parts the
//! CPU cannot model -- rasterisation rules, sampler state, the sRGB
//! framebuffer -- which is a much smaller haystack than "the window is black".
//!
//! It is not fast and is not meant to be. Every instance walks its own bounding
//! box; there is no scanline structure, no coverage accumulation, no tiling.
//! The rasteriser Gleipnir actually ships is the GPU one, and the one for
//! paths is a separate piece of work.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");
const paint = @import("../gelgja/paint.zig");
const rect = @import("rect.zig");
const png = @import("png.zig");
const sdf = @import("sdf.zig");

const Bounds = geom.Bounds;
const Color = paint.Color;
const Instance = rect.Instance;
const Point = geom.Point;

/// Where texture fetches come from, so a test can supply a pattern without an
/// image decoder and a caller can supply a real glyph atlas.
///
/// Coordinates are normalised; wrapping and filtering are the samplers own
/// business and this leaves both to it. A pointer and a function rather than a
/// bare function, matching `Face`, `Shaper` and the UIs `Metrics`: without
/// somewhere to hang state, the only way to reach an atlas from inside the
/// callback is a global, and there is more than one atlas.
pub const Sampler = struct {
    ptr: *anyopaque,
    sample: *const fn (ptr: *anyopaque, tex: rect.TextureId, u: f32, v: f32) Color,

    pub fn at(s: Sampler, tex: rect.TextureId, u: f32, v: f32) Color {
        return s.sample(s.ptr, tex, u, v);
    }
};

/// Which encoding the stored channels carry, and therefore which space
/// compositing happens in.
///
/// This is not a detail. Compositing is `dst*(1-a) + src*a`, and that
/// expression means two different things depending on what the numbers are.
/// Black text on white paper at half coverage lands on 188 if the halving is
/// done in light and on 128 if it is done in sRGB -- the difference between a
/// page and a faded photocopy of one, applied to every antialiased edge in the
/// document at once.
pub const Space = enum {
    /// Linear light. What the GPU blends in when the colour attachment is an
    /// `_SRGB` format: the hardware decodes on read and encodes on write, so
    /// the blend in between happens in light. The rect pipeline's
    /// framebuffer, because this file has to stay an oracle for that shader.
    linear,
    /// sRGB-encoded, blended exactly as stored. What PDF asks for -- §11.3.8
    /// composites in the group's colour space, and a page with no transparency
    /// group inherits the device's, which for a screen is sRGB -- and what
    /// every other reader does. The page rasteriser's framebuffer.
    srgb,
};

/// Premultiplied, four floats a pixel, in whichever `Space` it was created in.
///
/// Premultiplied because it is the only representation in which compositing is
/// associative, which is what lets a hundred overlapping instances land in any
/// order without the result drifting.
///
/// Float rather than eight-bit because this is the reference. Eight bits per
/// channel of *linear* light bands visibly in the darks, and an oracle that
/// bands is an oracle that cannot tell you whether the GPU banded.
pub const Framebuffer = struct {
    pixels: []f32,
    width: u32,
    height: u32,
    space: Space,

    pub fn init(gpa: Allocator, width: u32, height: u32, space: Space) Allocator.Error!Framebuffer {
        const fb: Framebuffer = .{
            .pixels = try gpa.alloc(f32, @as(usize, width) * height * 4),
            .width = width,
            .height = height,
            .space = space,
        };
        fb.clear(.transparent);
        return fb;
    }

    /// An sRGB-encoded channel as this framebuffer stores it.
    pub fn encode(fb: Framebuffer, s: f32) f32 {
        return switch (fb.space) {
            .linear => rect.srgbToLinear(s),
            .srgb => s,
        };
    }

    /// The inverse: a stored channel as sRGB, which is what every caller
    /// outside this file speaks.
    pub fn decode(fb: Framebuffer, v: f32) f32 {
        return switch (fb.space) {
            .linear => rect.linearToSrgb(v),
            .srgb => v,
        };
    }

    pub fn deinit(fb: *Framebuffer, gpa: Allocator) void {
        gpa.free(fb.pixels);
        fb.* = undefined;
    }

    /// `c` is given the way every colour in this renderer is given: sRGB
    /// encoded, straight alpha. It is encoded for this framebuffers space and
    /// premultiplied here.
    pub fn clear(fb: Framebuffer, c: Color) void {
        const p = premultiplied(c, 1.0, fb.space);
        var i: usize = 0;
        while (i < fb.pixels.len) : (i += 4) {
            fb.pixels[i + 0] = p[0];
            fb.pixels[i + 1] = p[1];
            fb.pixels[i + 2] = p[2];
            fb.pixels[i + 3] = p[3];
        }
    }

    pub fn bounds(fb: Framebuffer) Bounds {
        return .fromRect(0, 0, @floatFromInt(fb.width), @floatFromInt(fb.height));
    }

    /// The pixel as it would be read back: straight alpha, sRGB encoded, which
    /// is what a test wants to compare against a colour it wrote.
    pub fn at(fb: Framebuffer, x: u32, y: u32) Color {
        const i = (@as(usize, y) * fb.width + x) * 4;
        const a = fb.pixels[i + 3];
        if (a <= 0) return .transparent;
        return .{
            .r = fb.decode(fb.pixels[i + 0] / a),
            .g = fb.decode(fb.pixels[i + 1] / a),
            .b = fb.decode(fb.pixels[i + 2] / a),
            .a = a,
        };
    }

    /// Alpha alone, which is what most of the geometry tests care about:
    /// coverage is where the SDF can be wrong, colour is where the packing
    /// can be.
    pub fn alphaAt(fb: Framebuffer, x: u32, y: u32) f32 {
        return fb.pixels[(@as(usize, y) * fb.width + x) * 4 + 3];
    }

    /// Binary PPM, because it is eight lines to write and every image viewer
    /// and diff tool already reads it. PNG belongs in the same commit as the
    /// regression suite that needs it, not before.
    pub fn writePpm(fb: Framebuffer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("P6\n{d} {d}\n255\n", .{ fb.width, fb.height });
        var y: u32 = 0;
        while (y < fb.height) : (y += 1) {
            var x: u32 = 0;
            while (x < fb.width) : (x += 1) {
                const c = fb.at(x, y);
                // Over an opaque black page, so a partly covered pixel reads
                // as darker rather than as an undefined colour.
                try w.writeByte(byteOf(c.r * c.a));
                try w.writeByte(byteOf(c.g * c.a));
                try w.writeByte(byteOf(c.b * c.a));
            }
        }
    }

    /// The framebuffer as the eight-bit sRGB RGBA a file format wants:
    /// straight alpha, not premultiplied, because that is what PNG stores and
    /// what every tool that reads one expects.
    pub fn toRgba8(fb: Framebuffer, gpa: Allocator) Allocator.Error![]u8 {
        const out = try gpa.alloc(u8, @as(usize, fb.width) * fb.height * 4);
        var y: u32 = 0;
        while (y < fb.height) : (y += 1) {
            var x: u32 = 0;
            while (x < fb.width) : (x += 1) {
                const c = fb.at(x, y);
                const o = (@as(usize, y) * fb.width + x) * 4;
                out[o + 0] = byteOf(c.r);
                out[o + 1] = byteOf(c.g);
                out[o + 2] = byteOf(c.b);
                out[o + 3] = byteOf(c.a);
            }
        }
        return out;
    }

    pub fn writePng(fb: Framebuffer, gpa: Allocator, w: *std.Io.Writer) png.Error!void {
        const rgba = try fb.toRgba8(gpa);
        defer gpa.free(rgba);
        try png.write(gpa, w, rgba, fb.width, fb.height);
    }
};

fn byteOf(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255.0));
}

/// How far two renders of the same page disagree, in levels out of 255 of
/// what is stored.
///
/// Levels, because that is the unit a difference has to be judged in: a mean
/// under one is invisible, a worst of a few is an antialiased edge landing
/// differently, and a large share of big differences is a shape in the wrong
/// place. A pixel's difference is its largest colour channel's. Alpha is left
/// out: both renders are onto the same opaque page, so it can only differ
/// where the colour already does.
pub const Difference = struct {
    pixels: u64 = 0,
    /// Summed rather than averaged, so `mean` divides once.
    total: f64 = 0,
    worst: f32 = 0,
    over_1: u64 = 0,
    over_8: u64 = 0,

    /// Null when the sizes differ, which is two different pages.
    pub fn of(a: Framebuffer, b: Framebuffer) ?Difference {
        if (a.width != b.width or a.height != b.height) return null;
        var out: Difference = .{ .pixels = @as(u64, a.width) * a.height };
        var i: usize = 0;
        while (i < a.pixels.len) : (i += 4) {
            var d: f32 = 0;
            for (0..3) |c| d = @max(d, @abs(a.pixels[i + c] - b.pixels[i + c]));
            const levels = d * 255.0;
            out.total += levels;
            out.worst = @max(out.worst, levels);
            if (levels > 1) out.over_1 += 1;
            if (levels > 8) out.over_8 += 1;
        }
        return out;
    }

    pub fn mean(d: Difference) f64 {
        if (d.pixels == 0) return 0;
        return d.total / @as(f64, @floatFromInt(d.pixels));
    }

    /// `count` as a percentage of the pixels compared.
    pub fn percent(d: Difference, count: u64) f64 {
        if (d.pixels == 0) return 0;
        return @as(f64, @floatFromInt(count)) * 100.0 / @as(f64, @floatFromInt(d.pixels));
    }
};

/// Encodes an sRGB colour for `space` and premultiplies it by its own alpha
/// and by `cov`.
fn premultiplied(c: Color, cov: f32, space: Space) [4]f32 {
    const a = std.math.clamp(c.a, 0, 1) * cov;
    const e = struct {
        fn f(s: f32, sp: Space) f32 {
            return switch (sp) { .linear => rect.srgbToLinear(s), .srgb => s };
        }
    }.f;
    return .{
        e(std.math.clamp(c.r, 0, 1), space) * a,
        e(std.math.clamp(c.g, 0, 1), space) * a,
        e(std.math.clamp(c.b, 0, 1), space) * a,
        a,
    };
}

/// Draws the instances in order. Order is the whole of the depth test here, as
/// it is on the GPU: there is no z buffer, the pipeline is one draw call, and
/// Vulkan guarantees instances rasterise in index order.
pub fn render(fb: Framebuffer, instances: []const Instance, sampler: ?Sampler) void {
    // This file models an `_SRGB` colour attachment, where the hardware
    // decodes on read and encodes on write. Handed a framebuffer that stores
    // sRGB directly it would still draw, and would no longer be an oracle.
    std.debug.assert(fb.space == .linear);
    for (instances) |i| drawOne(fb, i, sampler);
}

fn drawOne(fb: Framebuffer, i: Instance, sampler: ?Sampler) void {
    // The vertex shader's job: grow for the shadow, cut to the clip, cut to
    // the framebuffer. Anything outside this rectangle produces no fragments
    // there and no work here.
    const area = i.touched().intersect(fb.bounds());
    if (area.isEmpty()) return;

    const x0: u32 = @intFromFloat(@max(0.0, @floor(area.min_x)));
    const y0: u32 = @intFromFloat(@max(0.0, @floor(area.min_y)));
    const x1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(fb.width)), @ceil(area.max_x)));
    const y1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(fb.height)), @ceil(area.max_y)));

    const dst = i.rect();
    const center: Point = .{
        .x = (dst.min_x + dst.max_x) * 0.5,
        .y = (dst.min_y + dst.max_y) * 0.5,
    };
    const half: Point = .{ .x = dst.width() * 0.5, .y = dst.height() * 0.5 };
    const radius: sdf.Radius = .{
        .tl = i.radius[0],
        .tr = i.radius[1],
        .br = i.radius[2],
        .bl = i.radius[3],
    };
    const inv_w = if (dst.width() > 0) 1.0 / dst.width() else 0;
    const inv_h = if (dst.height() > 0) 1.0 / dst.height() else 0;

    // The four corner colours, decoded once. The shader does this per fragment
    // and the compiler hoists it; here it is hoisted by hand.
    var corner: [4][4]f32 = undefined;
    for (i.color, 0..) |packed_color, n| {
        const c = rect.unpack(packed_color);
        corner[n] = .{
            rect.srgbToLinear(c.r),
            rect.srgbToLinear(c.g),
            rect.srgbToLinear(c.b),
            c.a,
        };
    }
    const clip = i.clipRect();

    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;

            // A hard clip at pixel centres: exactly which fragments the
            // shrunken quad would have generated, and no partial coverage on
            // the clip edge, so two clipped regions that abut do not seam.
            if (!clip.contains(.{ .x = px, .y = py })) continue;

            var d = sdf.roundedBox(.{ .x = px - center.x, .y = py - center.y }, half, radius);
            d = sdf.ring(d, i.border);
            const cov = sdf.coverage(d, i.softness, 1.0);
            if (cov <= 0) continue;

            const tx = std.math.clamp((px - dst.min_x) * inv_w, 0, 1);
            const ty = std.math.clamp((py - dst.min_y) * inv_h, 0, 1);

            var src: [4]f32 = .{
                sdf.bilerp(.{ corner[0][0], corner[1][0], corner[2][0], corner[3][0] }, tx, ty),
                sdf.bilerp(.{ corner[0][1], corner[1][1], corner[2][1], corner[3][1] }, tx, ty),
                sdf.bilerp(.{ corner[0][2], corner[1][2], corner[2][2], corner[3][2] }, tx, ty),
                sdf.bilerp(.{ corner[0][3], corner[1][3], corner[2][3], corner[3][3] }, tx, ty),
            };

            if (i.flags.textured) {
                if (sampler) |s| {
                    const u = i.src[0] + (i.src[2] - i.src[0]) * tx;
                    const v = i.src[1] + (i.src[3] - i.src[1]) * ty;
                    const t = s.at(i.texture, u, v);
                    if (i.flags.alpha_texture) {
                        src[3] *= t.r;
                    } else {
                        src[0] *= rect.srgbToLinear(t.r);
                        src[1] *= rect.srgbToLinear(t.g);
                        src[2] *= rect.srgbToLinear(t.b);
                        src[3] *= t.a;
                    }
                }
            }

            const a = src[3] * cov;
            if (a <= 0) continue;

            const o = (@as(usize, y) * fb.width + x) * 4;
            const inv = 1.0 - a;
            fb.pixels[o + 0] = fb.pixels[o + 0] * inv + src[0] * a;
            fb.pixels[o + 1] = fb.pixels[o + 1] * inv + src[1] * a;
            fb.pixels[o + 2] = fb.pixels[o + 2] * inv + src[2] * a;
            fb.pixels[o + 3] = fb.pixels[o + 3] * inv + a;
        }
    }
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const DrawList = @import("DrawList.zig");

fn frame(gpa: Allocator, w: u32, h: u32, build: *const fn (*DrawList) anyerror!void) !Framebuffer {
    var d: DrawList = .init(gpa, .fromRect(0, 0, @floatFromInt(w), @floatFromInt(h)));
    defer d.deinit();
    try build(&d);

    const fb = try Framebuffer.init(gpa, w, h, .linear);
    render(fb, d.instances.items, null);
    return fb;
}

test "a square fill covers its interior and nothing outside it" {
    var fb = try frame(testing.allocator, 32, 32, struct {
        fn f(d: *DrawList) anyerror!void {
            try d.fill(.fromRect(8, 8, 24, 24), .white);
        }
    }.f);
    defer fb.deinit(testing.allocator);

    try testing.expectApproxEqAbs(1.0, fb.alphaAt(16, 16), 1e-5);
    try testing.expectApproxEqAbs(1.0, fb.alphaAt(8, 8), 1e-5);
    try testing.expectApproxEqAbs(1.0, fb.alphaAt(23, 23), 1e-5);
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(7, 16));
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(24, 16));
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(0, 0));
}

test "an edge on a half-pixel is half covered" {
    var fb = try frame(testing.allocator, 16, 16, struct {
        fn f(d: *DrawList) anyerror!void {
            // The right edge lands on the centre of column 8.
            try d.fill(.fromRect(0, 0, 8.5, 16), .white);
        }
    }.f);
    defer fb.deinit(testing.allocator);

    try testing.expectApproxEqAbs(1.0, fb.alphaAt(7, 8), 1e-5);
    try testing.expectApproxEqAbs(0.5, fb.alphaAt(8, 8), 1e-5);
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(9, 8));
}

test "a rounded corner leaves its corner pixel empty" {
    var fb = try frame(testing.allocator, 32, 32, struct {
        fn f(d: *DrawList) anyerror!void {
            try d.rounded(.fromRect(0, 0, 32, 32), .all(12), .white);
        }
    }.f);
    defer fb.deinit(testing.allocator);

    // Well outside the quarter circle at each corner.
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(0, 0));
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(31, 0));
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(31, 31));
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(0, 31));
    // The middle of each side is still flat against the edge.
    try testing.expectApproxEqAbs(1.0, fb.alphaAt(16, 0), 1e-5);
    try testing.expectApproxEqAbs(1.0, fb.alphaAt(0, 16), 1e-5);
}

test "only the corners with a radius are cut" {
    var fb = try frame(testing.allocator, 32, 32, struct {
        fn f(d: *DrawList) anyerror!void {
            try d.rounded(.fromRect(0, 0, 32, 32), .top(12), .white);
        }
    }.f);
    defer fb.deinit(testing.allocator);

    try testing.expectEqual(@as(f32, 0), fb.alphaAt(0, 0));
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(31, 0));
    try testing.expectApproxEqAbs(1.0, fb.alphaAt(0, 31), 1e-5);
    try testing.expectApproxEqAbs(1.0, fb.alphaAt(31, 31), 1e-5);
}

test "a border draws a ring and leaves the middle alone" {
    var fb = try frame(testing.allocator, 32, 32, struct {
        fn f(d: *DrawList) anyerror!void {
            try d.border(.fromRect(4, 4, 28, 28), .none, 4, .white);
        }
    }.f);
    defer fb.deinit(testing.allocator);

    // Inside the ring.
    try testing.expectApproxEqAbs(1.0, fb.alphaAt(6, 16), 1e-5);
    try testing.expectApproxEqAbs(1.0, fb.alphaAt(16, 6), 1e-5);
    // Past its inner edge.
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(16, 16));
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(12, 12));
    // Outside the box entirely.
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(1, 16));
}

test "the clip cuts what the rectangle would otherwise cover" {
    var fb = try frame(testing.allocator, 32, 32, struct {
        fn f(d: *DrawList) anyerror!void {
            d.pushClip(.fromRect(0, 0, 16, 32));
            defer d.popClip();
            try d.fill(.fromRect(0, 0, 32, 32), .white);
        }
    }.f);
    defer fb.deinit(testing.allocator);

    try testing.expectApproxEqAbs(1.0, fb.alphaAt(15, 16), 1e-5);
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(16, 16));
}

test "a shadow reaches outside its own rectangle and fades" {
    var fb = try frame(testing.allocator, 64, 64, struct {
        fn f(d: *DrawList) anyerror!void {
            try d.shadow(.fromRect(24, 24, 40, 40), .none, 8, .black);
        }
    }.f);
    defer fb.deinit(testing.allocator);

    const inside = fb.alphaAt(32, 32);
    const at_edge = fb.alphaAt(32, 24);
    const outside = fb.alphaAt(32, 32 - 14);

    // Not quite 1: the ramp is 2 * softness wide, which for an 8px shadow on a
    // 16px box is as wide as the box itself, so even the centre sits inside the
    // falloff. That is the correct behaviour and worth pinning down, because
    // the tempting fix -- saturating the field before the ramp -- would make a
    // large shadow behind a small object read as a hard-edged slab.
    try testing.expect(inside > 0.99);
    try testing.expectApproxEqAbs(0.5, at_edge, 0.1);
    try testing.expect(outside > 0);
    try testing.expect(outside < 0.1);
    // And it does reach past 2 * softness nowhere.
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(32, 5));
}

test "instances composite in submission order" {
    var fb = try frame(testing.allocator, 16, 16, struct {
        fn f(d: *DrawList) anyerror!void {
            try d.fill(.fromRect(0, 0, 16, 16), .black);
            try d.fill(.fromRect(0, 0, 16, 16), .white);
        }
    }.f);
    defer fb.deinit(testing.allocator);

    const c = fb.at(8, 8);
    try testing.expectApproxEqAbs(1.0, c.r, 1e-3);
    try testing.expectApproxEqAbs(1.0, c.a, 1e-5);
}

test "a half-transparent white over black is mid grey in light, not in bytes" {
    var fb = try frame(testing.allocator, 16, 16, struct {
        fn f(d: *DrawList) anyerror!void {
            try d.fill(.fromRect(0, 0, 16, 16), .black);
            try d.fill(.fromRect(0, 0, 16, 16), Color.white.withAlpha(0.5));
        }
    }.f);
    defer fb.deinit(testing.allocator);

    // Half the light of white, which is 0.5 linear and about 0.735 encoded.
    // Getting 0.5 back here would mean the blend happened in sRGB, which is
    // the classic wrong-gamma compositing bug and the reason this is a test.
    const c = fb.at(8, 8);
    try testing.expectApproxEqAbs(0.7354, c.r, 5e-3);
}

test "a gradient puts each colour at its own corner" {
    var fb = try frame(testing.allocator, 64, 64, struct {
        fn f(d: *DrawList) anyerror!void {
            try d.gradient(.fromRect(0, 0, 64, 64), .none, .{
                .{ .r = 1, .g = 0, .b = 0 },
                .{ .r = 0, .g = 1, .b = 0 },
                .{ .r = 0, .g = 0, .b = 1 },
                .{ .r = 1, .g = 1, .b = 1 },
            });
        }
    }.f);
    defer fb.deinit(testing.allocator);

    try testing.expect(fb.at(0, 0).r > 0.9);
    try testing.expect(fb.at(63, 0).g > 0.9);
    try testing.expect(fb.at(63, 63).b > 0.9);
    const bl = fb.at(0, 63);
    try testing.expect(bl.r > 0.9 and bl.g > 0.9 and bl.b > 0.9);
}

const checker: Sampler = .{ .ptr = @constCast(@ptrCast(&checker_tag)), .sample = checkerSample };
const checker_tag: u8 = 0;

fn checkerSample(_: *anyopaque, tex: rect.TextureId, u: f32, v: f32) Color {
    _ = tex;
    const on = (@as(i32, @intFromFloat(@floor(u * 4))) + @as(i32, @intFromFloat(@floor(v * 4)))) & 1;
    return if (on == 0) Color.white else Color.black;
}

test "an alpha texture modulates coverage and not colour" {
    const gpa = testing.allocator;
    var d: DrawList = .init(gpa, .fromRect(0, 0, 32, 32));
    defer d.deinit();

    const atlas = try d.registerTexture(32, 32);
    try d.glyph(.fromRect(0, 0, 32, 32), atlas, .fromRect(0, 0, 32, 32), .{ .r = 1, .g = 0, .b = 0 });

    var fb = try Framebuffer.init(gpa, 32, 32, .linear);
    defer fb.deinit(gpa);
    render(fb, d.instances.items, checker);

    // The lit squares of the checker keep the instance's own red...
    const lit = fb.at(4, 4);
    try testing.expectApproxEqAbs(1.0, lit.a, 1e-5);
    try testing.expect(lit.r > 0.9 and lit.g < 0.05);
    // ...and the dark ones contribute nothing at all.
    try testing.expectEqual(@as(f32, 0), fb.alphaAt(12, 4));
}

test "the PPM header and payload are the size they claim" {
    const gpa = testing.allocator;
    var fb = try Framebuffer.init(gpa, 4, 3, .linear);
    defer fb.deinit(gpa);
    fb.clear(.white);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try fb.writePpm(&w);

    const out = w.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "P6\n4 3\n255\n"));
    try testing.expectEqual(@as(usize, 11 + 4 * 3 * 3), out.len);
    try testing.expectEqual(@as(u8, 255), out[11]);
}

test "a difference is counted in levels, by each pixel's worst channel" {
    const gpa = testing.allocator;
    var a = try Framebuffer.init(gpa, 10, 10, .srgb);
    defer a.deinit(gpa);
    var b = try Framebuffer.init(gpa, 10, 10, .srgb);
    defer b.deinit(gpa);
    a.clear(.white);
    b.clear(.white);

    const same = Difference.of(a, b).?;
    try testing.expectEqual(@as(u64, 100), same.pixels);
    try testing.expectEqual(@as(f32, 0), same.worst);
    try testing.expectEqual(@as(f64, 0), same.mean());

    // One pixel two levels off in green and half a level in red: two, not
    // two and a half. Another ten levels off in blue.
    b.pixels[4 * 3 + 0] -= 0.5 / 255.0;
    b.pixels[4 * 3 + 1] -= 2.0 / 255.0;
    b.pixels[4 * 7 + 2] -= 10.0 / 255.0;
    // And an alpha that differs where the colour does not, which is ignored.
    b.pixels[4 * 9 + 3] = 0.5;

    const d = Difference.of(a, b).?;
    try testing.expectApproxEqAbs(@as(f32, 10), d.worst, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0.12), d.mean(), 1e-4);
    try testing.expectEqual(@as(u64, 2), d.over_1);
    try testing.expectEqual(@as(u64, 1), d.over_8);
    try testing.expectApproxEqAbs(@as(f64, 1), d.percent(d.over_8), 1e-9);

    // Two sizes are two pages.
    var c = try Framebuffer.init(gpa, 10, 9, .srgb);
    defer c.deinit(gpa);
    try testing.expect(Difference.of(a, c) == null);
}
