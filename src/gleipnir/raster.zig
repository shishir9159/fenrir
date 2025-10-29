//! Stencil-then-cover on the CPU: the same two passes, the same stencil
//! buffer, the same wrap-around arithmetic.
//!
//! This is the oracle, and it is written to be a *model* of the GPU rather
//! than a second implementation that happens to agree. Every decision here is
//! made because Vulkan makes it:
//!
//! * The stencil buffer is **eight bits and wraps**, because
//!   `VK_STENCIL_OP_INCREMENT_AND_WRAP` does. A path whose winding number
//!   reaches 256 at some pixel renders wrong on the GPU, and it renders wrong
//!   here in the same way rather than correctly, which is what makes this an
//!   oracle instead of a second opinion.
//! * The cover pass zeroes **every sample it touches**, passing or failing,
//!   because the pipeline sets both `failOp` and `passOp` to `ZERO`. That is
//!   what leaves the buffer clean for the next path and lets one stencil
//!   attachment serve a whole page with no clear in between.
//! * Antialiasing is multisampling, at Vulkan's own standard sample
//!   positions, because an outline has no signed distance field to sample.
//!   The rect pipeline gets its edges from `sdf.zig` and needs none of this;
//!   the two pipelines antialias by different means and that is deliberate.
//!
//! It shares `software.Framebuffer` with the rect rasteriser -- same
//! premultiplied float pixels, same blend, same PNG writer -- so a page’s
//! rects and paths land in one image and `fenrir raster` can put a real PDF
//! page on disk with no GPU in the process. The one thing it does not share
//! is the compositing space: the rect pipeline models an `_SRGB` colour
//! attachment and blends in light, and a page blends in the device’s own
//! space, because that is what PDF asks for. `software.Space` is where that
//! choice is written down.
//!
//! ## Speed
//!
//! It is a scanline rasteriser with incremental edge functions, which is fast
//! enough to render a page in well under a second and slow enough that nobody
//! will mistake it for the shipping renderer. The fan triangles overlap
//! enormously -- that is the technique -- so the work is proportional to the
//! summed area of the fan rather than to the area of the path, and a large
//! path with many segments is the worst case. The GPU does not care; this
//! does.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");
const paint = @import("../gelgja/paint.zig");
const path = @import("path.zig");
const rect = @import("rect.zig");
const software = @import("software.zig");

const Bounds = geom.Bounds;
const Color = paint.Color;
const FillRule = geom.FillRule;
const Framebuffer = software.Framebuffer;
const Space = software.Space;
const Mesh = path.Mesh;
const Transform = geom.Transform;
const Vertex = path.Vertex;

/// How many samples a pixel is split into.
///
/// Eight is the default, which is more than a UI would want and about right
/// for text: see `Options.samples`. One exists so a test can assert on exact
/// pixel coverage without reasoning about sample positions.
pub const Samples = enum(u8) {
    one = 1,
    two = 2,
    four = 4,
    eight = 8,

    pub fn count(s: Samples) u8 {
        return @intFromEnum(s);
    }

    /// Vulkan's standard sample locations (§27.6, "Standard sample
    /// locations"), as offsets from the top-left of the pixel. Matching these
    /// rather than inventing a pattern is what lets a coverage value from this
    /// file be compared against one from a device without a fudge factor.
    pub fn positions(s: Samples) []const [2]f32 {
        return switch (s) {
            .one => &.{.{ 0.5, 0.5 }},
            .two => &.{ .{ 0.75, 0.75 }, .{ 0.25, 0.25 } },
            .four => &.{
                .{ 0.375, 0.125 }, .{ 0.875, 0.375 },
                .{ 0.125, 0.625 }, .{ 0.625, 0.875 },
            },
            .eight => &.{
                .{ 0.5625, 0.3125 }, .{ 0.4375, 0.6875 },
                .{ 0.8125, 0.5625 }, .{ 0.3125, 0.1875 },
                .{ 0.1875, 0.8125 }, .{ 0.0625, 0.4375 },
                .{ 0.6875, 0.9375 }, .{ 0.9375, 0.0625 },
            },
        };
    }
};

pub const Options = struct {
    /// Eight, not four. Coverage from N samples has N+1 levels, so four gives
    /// a glyph edge five shades to work with and eight gives it nine — and a
    /// stem at a reading size is one or two pixels wide, so those levels are
    /// most of what its weight is made of. The extra samples cost about a
    /// quarter more time on a page and are the cheapest quality in the
    /// renderer.
    samples: Samples = .eight,
    /// Which space partial coverage is composited in.
    ///
    /// sRGB by default, which is not the physically correct answer and is the
    /// right one. PDF composites in the device colour space (§11.3.8), every
    /// other reader does the same, and a page blended in linear light comes
    /// out looking like a photocopy: a stem edge at half coverage lands on
    /// 188 instead of 128, so every glyph in the document is a shade too
    /// light and a fraction too thin.
    space: Space = .srgb,
};

/// A framebuffer, a stencil buffer, and a clip.
pub const Canvas = struct {
    fb: Framebuffer,
    /// One byte per sample, `width * height * samples`. Zero everywhere
    /// between paths, which is an invariant a test checks rather than a hope.
    stencil: []u8,
    /// Per-pixel clip coverage, 255 everywhere by default.
    ///
    /// A rectangular clip could be a loop bound, but PDF clips with paths --
    /// `W n` is on nearly every page that has a figure on it -- and an
    /// arbitrary clip region has to be stored somewhere. A GPU implementation
    /// would keep this in a second attachment or in the high bits of the same
    /// stencil; a byte per pixel is the CPU's version of that and it
    /// antialiases the clip edge for free, which the stencil-bit version
    /// cannot.
    clip: []u8,
    /// Saved clips, for `pushClip` / `popClip`.
    clip_stack: std.ArrayList([]u8) = .empty,
    /// How many samples of each pixel the cover pass has claimed so far, for
    /// the path being drawn. Zero everywhere between paths.
    ///
    /// The cover quad is *two* triangles, so a pixel on their shared diagonal
    /// is reached twice, with some of its samples each time. Blending once per
    /// triangle would then composite the same colour over that pixel twice at
    /// partial coverage -- which is not the same as once at full coverage, and
    /// shows as a lighter line down the diagonal of every filled shape on the
    /// page.
    ///
    /// A GPU does not have this problem: it blends *per sample* and resolves
    /// at the end, so two fragments covering disjoint samples of one pixel
    /// compose exactly. Keeping a sample-resolution framebuffer here would
    /// model that directly and cost four times the memory; accumulating the
    /// count and blending once is equivalent, because within one cover pass
    /// every sample gets the same colour, and each sample is claimed by
    /// exactly one of the two triangles.
    cover: []u8,
    samples: Samples,
    /// `/BM` for everything drawn until it is set again (§11.3.5).
    ///
    /// Device state, like the clip, rather than an argument to every call --
    /// which is what it is in PDF too. It is here and not on the paint because
    /// the blend function needs the backdrop, so it belongs to the surface
    /// being drawn on rather than to the colour being drawn with.
    blend_mode: paint.BlendMode = .normal,

    pub fn init(gpa: Allocator, w: u32, h: u32, options: Options) Allocator.Error!Canvas {
        const n = @as(usize, w) * h;
        const fb = try Framebuffer.init(gpa, w, h, options.space);
        errdefer {
            var f = fb;
            f.deinit(gpa);
        }
        const stencil = try gpa.alloc(u8, n * options.samples.count());
        errdefer gpa.free(stencil);
        @memset(stencil, 0);
        const clip = try gpa.alloc(u8, n);
        errdefer gpa.free(clip);
        @memset(clip, 255);
        const cover = try gpa.alloc(u8, n);
        @memset(cover, 0);
        return .{
            .fb = fb,
            .stencil = stencil,
            .clip = clip,
            .cover = cover,
            .samples = options.samples,
        };
    }

    pub fn deinit(c: *Canvas, gpa: Allocator) void {
        c.fb.deinit(gpa);
        gpa.free(c.stencil);
        gpa.free(c.clip);
        gpa.free(c.cover);
        for (c.clip_stack.items) |m| gpa.free(m);
        c.clip_stack.deinit(gpa);
        c.* = undefined;
    }

    pub fn width(c: Canvas) u32 {
        return c.fb.width;
    }

    pub fn height(c: Canvas) u32 {
        return c.fb.height;
    }

    pub fn bounds(c: Canvas) Bounds {
        return c.fb.bounds();
    }

    /// True when every sample is zero. The invariant that makes one stencil
    /// buffer serve a whole page.
    pub fn stencilIsClean(c: Canvas) bool {
        for (c.stencil) |s| {
            if (s != 0) return false;
        }
        return true;
    }

    /// Intersects the clip with a path. The mesh is rendered to coverage the
    /// same way a fill is, and multiplied into the existing mask.
    pub fn pushClip(c: *Canvas, gpa: Allocator, m: Mesh, xform: Transform, rule: FillRule) Allocator.Error!void {
        const saved = try gpa.dupe(u8, c.clip);
        errdefer gpa.free(saved);
        try c.clip_stack.append(gpa, saved);

        // Coverage of the clip path, then `clip *= coverage`. Multiplying
        // rather than replacing is what makes nested clips intersect, which is
        // the only thing PDF's clip stack ever does (§8.5.4): a clip can be
        // narrowed by `W` and widened only by `Q`.
        const mask = try gpa.alloc(u8, c.clip.len);
        defer gpa.free(mask);
        @memset(mask, 0);
        c.coverage(m, xform, rule, mask);

        for (c.clip, mask) |*dst, src| {
            dst.* = @intCast((@as(u32, dst.*) * src + 127) / 255);
        }
    }

    pub fn popClip(c: *Canvas, gpa: Allocator) void {
        const saved = c.clip_stack.pop() orelse return;
        gpa.free(c.clip);
        c.clip = saved;
    }

    /// Fills a mesh. The two passes, in order.
    pub fn fill(c: *Canvas, m: Mesh, xform: Transform, rule: FillRule, color: Color, alpha: f32) void {
        if (m.isEmpty()) return;
        c.stencilPass(m, xform);
        c.coverPass(m, xform, rule, color, alpha, null);
    }

    /// Rasterises the mesh to an eight-bit coverage buffer instead of blending
    /// it, for a clip path or a soft mask. Runs the same two passes, so a clip
    /// and a fill of the same path cover exactly the same samples.
    pub fn coverage(c: *Canvas, m: Mesh, xform: Transform, rule: FillRule, out: []u8) void {
        if (m.isEmpty()) return;
        c.stencilPass(m, xform);
        c.coverPass(m, xform, rule, null, 1.0, out);
    }

    // -- pass one: winding into the stencil ---------------------------------

    fn stencilPass(c: *Canvas, m: Mesh, xform: Transform) void {
        var i: u32 = 0;
        while (i < m.stencil_count) : (i += 3) {
            const a = apply(xform, m.vertices[m.indices[i + 0]]);
            const b = apply(xform, m.vertices[m.indices[i + 1]]);
            const t = apply(xform, m.vertices[m.indices[i + 2]]);
            c.rasterTriangle(a, b, t, .stencil, null);
        }
    }

    // -- pass two: the stencil test, and zeroing behind it ------------------

    fn coverPass(
        c: *Canvas,
        m: Mesh,
        xform: Transform,
        rule: FillRule,
        color: ?Color,
        alpha: f32,
        out: ?[]u8,
    ) void {
        // The quad's device-space bounds, which is the region the resolve
        // below has to sweep and the only region `cover` can have been
        // written in.
        var box: Bounds = .empty;
        var k: u32 = 0;
        while (k < Mesh.cover_count) : (k += 1) {
            box = box.add(apply(xform, m.vertices[m.indices[m.cover_first + k]]).point());
        }
        const area = box.intersect(c.bounds());
        if (area.isEmpty()) return;

        var cov: CoverState = .{ .rule = rule };
        var i: u32 = 0;
        while (i < Mesh.cover_count) : (i += 3) {
            const a = apply(xform, m.vertices[m.indices[m.cover_first + i + 0]]);
            const b = apply(xform, m.vertices[m.indices[m.cover_first + i + 1]]);
            const t = apply(xform, m.vertices[m.indices[m.cover_first + i + 2]]);
            c.rasterTriangle(a, b, t, .cover, &cov);
        }

        c.resolve(area, color, alpha, out);
    }

    /// Turns the accumulated sample counts into colour, once per pixel, and
    /// clears them for the next path.
    fn resolve(c: *Canvas, area: Bounds, color: ?Color, alpha: f32, out: ?[]u8) void {
        const inv_n = 1.0 / @as(f32, @floatFromInt(c.samples.count()));

        const x0: u32 = @intFromFloat(@max(0.0, @floor(area.min_x)));
        const y0: u32 = @intFromFloat(@max(0.0, @floor(area.min_y)));
        const x1: u32 = @min(c.width(), @as(u32, @intFromFloat(@max(0.0, @ceil(area.max_x)))) + 1);
        const y1: u32 = @min(c.height(), @as(u32, @intFromFloat(@max(0.0, @ceil(area.max_y)))) + 1);

        var y: u32 = y0;
        while (y < y1) : (y += 1) {
            var x: u32 = x0;
            while (x < x1) : (x += 1) {
                const pixel = @as(usize, y) * c.width() + x;
                const n = c.cover[pixel];
                if (n == 0) continue;
                c.cover[pixel] = 0;

                const frac = @as(f32, @floatFromInt(n)) * inv_n *
                    (@as(f32, @floatFromInt(c.clip[pixel])) / 255.0);

                if (out) |mask| {
                    const v: u8 = @intFromFloat(@round(std.math.clamp(frac, 0, 1) * 255.0));
                    mask[pixel] = @max(mask[pixel], v);
                } else {
                    c.blend(pixel, color.?, frac * alpha);
                }
            }
        }
    }

    const CoverState = struct {
        rule: FillRule,
    };

    const Pass = enum { stencil, cover };

    /// One triangle, one scanline at a time, with the edge functions carried
    /// incrementally across x.
    ///
    /// The cover quad is two triangles that share a diagonal, so a sample on
    /// that diagonal must land in exactly one of them or it is either zeroed
    /// twice -- harmless -- or blended twice, which shows as a bright seam
    /// down the middle of every filled shape. `edgeInside` is the top-left
    /// rule that prevents it, and it is the same rule the hardware uses.
    fn rasterTriangle(c: *Canvas, a: Vertex, b: Vertex, t: Vertex, pass: Pass, state: ?*CoverState) void {
        const area = signedArea(a, b, t);
        if (area == 0 or !std.math.isFinite(area)) return;

        // Consistent orientation, so one set of edge tests serves both
        // windings. The original sign is kept: it is the increment.
        const p0 = a;
        const p1 = if (area > 0) b else t;
        const p2 = if (area > 0) t else b;
        const front = area > 0;

        var box: Bounds = .empty;
        for ([_]Vertex{ a, b, t }) |v| box = box.add(v.point());
        const area_px = box.intersect(c.bounds());
        if (area_px.isEmpty()) return;

        const x0: u32 = @intFromFloat(@max(0.0, @floor(area_px.min_x)));
        const y0: u32 = @intFromFloat(@max(0.0, @floor(area_px.min_y)));
        const x1: u32 = @min(c.width(), @as(u32, @intFromFloat(@max(0.0, @ceil(area_px.max_x)))) + 1);
        const y1: u32 = @min(c.height(), @as(u32, @intFromFloat(@max(0.0, @ceil(area_px.max_y)))) + 1);

        const positions = c.samples.positions();
        const n = c.samples.count();

        var y: u32 = y0;
        while (y < y1) : (y += 1) {
            var x: u32 = x0;
            while (x < x1) : (x += 1) {
                const pixel = @as(usize, y) * c.width() + x;

                // Clipped-away pixels produce no fragments at all, which is
                // both faster and the reason a clip never leaves stencil bits
                // behind: the cover pass skips exactly the pixels the stencil
                // pass skipped.
                if (c.clip[pixel] == 0) continue;

                var covered: u32 = 0;
                for (positions, 0..) |off, si| {
                    const px = @as(f32, @floatFromInt(x)) + off[0];
                    const py = @as(f32, @floatFromInt(y)) + off[1];
                    if (!inside(p0, p1, p2, px, py)) continue;

                    const slot = pixel * n + si;
                    switch (pass) {
                        .stencil => {
                            // INCREMENT_AND_WRAP / DECREMENT_AND_WRAP.
                            c.stencil[slot] = if (front)
                                c.stencil[slot] +% 1
                            else
                                c.stencil[slot] -% 1;
                        },
                        .cover => {
                            const s = c.stencil[slot];
                            // Both failOp and passOp are ZERO, so the sample is
                            // cleared whether it passed or not.
                            c.stencil[slot] = 0;
                            const in = switch (state.?.rule) {
                                .nonzero => s != 0,
                                .even_odd => (s & 1) != 0,
                            };
                            if (in) covered += 1;
                        },
                    }
                }

                if (pass == .stencil or covered == 0) continue;

                // Accumulated, not blended. `resolve` does the blending once
                // the other cover triangle has had its say -- see the comment
                // on `Canvas.cover`.
                c.cover[pixel] += @intCast(covered);
            }
        }
    }

    /// Premultiplied source over destination, in the framebuffer's own space,
    /// through the current blend mode.
    ///
    /// §11.3.6 in full is
    ///
    ///     Cr = (1 - as)*Cb + as*[ (1 - ab)*Cs + ab*B(Cb, Cs) ]
    ///
    /// which for the common case of an opaque backdrop collapses to
    /// `(1 - as)*Cb + as*B(Cb, Cs)` -- and for `normal`, where `B` is just
    /// `Cs`, to the plain source-over every other path here uses. Writing the
    /// general form costs one unpremultiply and buys every blend mode,
    /// including over the transparent regions a page can have.
    fn blend(c: *Canvas, pixel: usize, color: Color, cov: f32) void {
        const a = std.math.clamp(color.a, 0, 1) * std.math.clamp(cov, 0, 1);
        if (a <= 0) return;
        const o = pixel * 4;
        const ab = c.fb.pixels[o + 3];

        var cs = [3]f32{
            c.fb.encode(std.math.clamp(color.r, 0, 1)),
            c.fb.encode(std.math.clamp(color.g, 0, 1)),
            c.fb.encode(std.math.clamp(color.b, 0, 1)),
        };
        if (c.blend_mode != .normal and ab > 0) {
            const cb = [3]f32{
                c.fb.pixels[o + 0] / ab,
                c.fb.pixels[o + 1] / ab,
                c.fb.pixels[o + 2] / ab,
            };
            const mixed = c.blend_mode.blend(cb, cs);
            for (&cs, mixed) |*s, m| s.* = s.* * (1 - ab) + m * ab;
        }

        const inv = 1.0 - a;
        c.fb.pixels[o + 0] = c.fb.pixels[o + 0] * inv + cs[0] * a;
        c.fb.pixels[o + 1] = c.fb.pixels[o + 1] * inv + cs[1] * a;
        c.fb.pixels[o + 2] = c.fb.pixels[o + 2] * inv + cs[2] * a;
        c.fb.pixels[o + 3] = ab * inv + a;
    }
};

fn apply(t: Transform, v: Vertex) Vertex {
    return .{
        .x = t.a * v.x + t.c * v.y + t.e,
        .y = t.b * v.x + t.d * v.y + t.f,
    };
}

fn signedArea(a: Vertex, b: Vertex, c: Vertex) f32 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

fn inside(p0: Vertex, p1: Vertex, p2: Vertex, x: f32, y: f32) bool {
    return edgeInside(p0, p1, x, y) and edgeInside(p1, p2, x, y) and edgeInside(p2, p0, x, y);
}

/// The top-left fill rule. A sample exactly on a shared edge belongs to
/// whichever triangle has that edge as a top or a left edge, so it is covered
/// once rather than twice or never.
fn edgeInside(a: Vertex, b: Vertex, x: f32, y: f32) bool {
    const d = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
    if (d > 0) return true;
    if (d < 0) return false;
    if (b.y == a.y) return b.x > a.x;
    return b.y < a.y;
}

// -- convenience -------------------------------------------------------------

/// Flattens, meshes and fills in one call. Allocates and frees the mesh, so it
/// is for tests and for one-off drawing rather than for a page: a real caller
/// keeps the mesh and redraws it.
pub fn fillPath(
    gpa: Allocator,
    c: *Canvas,
    flat: path.Flattened,
    xform: Transform,
    rule: FillRule,
    color: Color,
) Allocator.Error!void {
    var m = try path.mesh(gpa, flat);
    defer m.deinit(gpa);
    c.fill(m, xform, rule, color, 1.0);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const Flattener = path.Flattener;

fn polygon(gpa: Allocator, f: *Flattener, pts: []const [2]f32) !path.Flattened {
    try f.moveTo(gpa, .{ .x = pts[0][0], .y = pts[0][1] });
    for (pts[1..]) |p| try f.lineTo(gpa, .{ .x = p[0], .y = p[1] });
    try f.close(gpa);
    return f.finish(gpa);
}

test "a filled square covers exactly the pixels it should" {
    const gpa = testing.allocator;
    var c: Canvas = try .init(gpa, 32, 32, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.transparent);

    var f: Flattener = .init(.{});
    defer f.deinit(gpa);
    const flat = try polygon(gpa, &f, &.{ .{ 8, 8 }, .{ 24, 8 }, .{ 24, 24 }, .{ 8, 24 } });
    try fillPath(gpa, &c, flat, .identity, .nonzero, .black);

    try testing.expectApproxEqAbs(@as(f32, 1), c.fb.alphaAt(16, 16), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), c.fb.alphaAt(8, 8), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(7, 16), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(24, 16), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(16, 4), 0.001);
}

test "the stencil buffer is clean again after every fill" {
    // The invariant the whole design rests on: no clear between paths, because
    // the cover pass zeroes what the stencil pass wrote. If it ever fails, the
    // leftovers show up inside some *later* path on the page, with nothing to
    // connect the two.
    const gpa = testing.allocator;
    var c: Canvas = try .init(gpa, 64, 64, .{});
    defer c.deinit(gpa);

    try testing.expect(c.stencilIsClean());

    // Shapes chosen to leave a mess: self-intersecting, partly off-canvas, and
    // one whose winding number is large.
    const shapes = [_][]const [2]f32{
        &.{ .{ 10, 10 }, .{ 50, 10 }, .{ 10, 50 }, .{ 50, 50 } },
        &.{ .{ -20, -20 }, .{ 30, -20 }, .{ 30, 30 }, .{ -20, 30 } },
        &.{ .{ 40, 40 }, .{ 90, 40 }, .{ 90, 90 }, .{ 40, 90 } },
    };
    for (shapes) |pts| {
        var f: Flattener = .init(.{});
        defer f.deinit(gpa);
        const flat = try polygon(gpa, &f, pts);
        try fillPath(gpa, &c, flat, .identity, .nonzero, .black);
        try testing.expect(c.stencilIsClean());
    }
}

test "the two fill rules disagree about a hole, on real pixels" {
    const gpa = testing.allocator;

    for ([_]struct { rule: FillRule, inside: bool }{
        .{ .rule = .nonzero, .inside = true },
        .{ .rule = .even_odd, .inside = false },
    }) |case| {
        var c: Canvas = try .init(gpa, 64, 64, .{ .samples = .one });
        defer c.deinit(gpa);
        c.fb.clear(.transparent);

        // Two squares wound the same way, one inside the other.
        var f: Flattener = .init(.{});
        defer f.deinit(gpa);
        try f.moveTo(gpa, .{ .x = 8, .y = 8 });
        try f.lineTo(gpa, .{ .x = 56, .y = 8 });
        try f.lineTo(gpa, .{ .x = 56, .y = 56 });
        try f.lineTo(gpa, .{ .x = 8, .y = 56 });
        try f.close(gpa);
        try f.moveTo(gpa, .{ .x = 20, .y = 20 });
        try f.lineTo(gpa, .{ .x = 44, .y = 20 });
        try f.lineTo(gpa, .{ .x = 44, .y = 44 });
        try f.lineTo(gpa, .{ .x = 20, .y = 44 });
        try f.close(gpa);
        const flat = try f.finish(gpa);

        try fillPath(gpa, &c, flat, .identity, case.rule, .black);

        // The ring is filled either way.
        try testing.expectApproxEqAbs(@as(f32, 1), c.fb.alphaAt(12, 32), 0.001);
        // The middle is the question.
        const middle = c.fb.alphaAt(32, 32);
        try testing.expectApproxEqAbs(if (case.inside) @as(f32, 1) else 0, middle, 0.001);
    }
}

test "multisampling antialiases a diagonal and one sample does not" {
    const gpa = testing.allocator;

    // A triangle with a 45-degree edge through the middle of the canvas. With
    // one sample every pixel is 0 or 1; with four, the pixels the edge passes
    // through take intermediate values.
    const tri = [_][2]f32{ .{ 0, 0 }, .{ 32, 0 }, .{ 0, 32 } };

    var partials_1: u32 = 0;
    var partials_4: u32 = 0;
    for ([_]Samples{ .one, .four }, 0..) |s, which| {
        var c: Canvas = try .init(gpa, 32, 32, .{ .samples = s });
        defer c.deinit(gpa);
        c.fb.clear(.transparent);

        var f: Flattener = .init(.{});
        defer f.deinit(gpa);
        const flat = try polygon(gpa, &f, &tri);
        try fillPath(gpa, &c, flat, .identity, .nonzero, .black);

        var count: u32 = 0;
        var y: u32 = 0;
        while (y < 32) : (y += 1) {
            var x: u32 = 0;
            while (x < 32) : (x += 1) {
                const a = c.fb.alphaAt(x, y);
                if (a > 0.01 and a < 0.99) count += 1;
            }
        }
        if (which == 0) partials_1 = count else partials_4 = count;
    }

    try testing.expectEqual(@as(u32, 0), partials_1);
    // Roughly one partial pixel per row along the diagonal.
    try testing.expect(partials_4 > 20);
}

test "the eight-bit stencil wraps exactly where the hardware does" {
    // Not a bug being tolerated -- a fidelity requirement. A path with 256
    // coincident windings is mis-filled by a GPU, and an oracle that got it
    // right would report a difference that is really agreement.
    const gpa = testing.allocator;
    var c: Canvas = try .init(gpa, 16, 16, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.transparent);

    var f: Flattener = .init(.{});
    defer f.deinit(gpa);
    // 256 concentric copies of the same square, all wound the same way, so the
    // winding number in the middle is exactly 256 and the stencil reads zero.
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        try f.moveTo(gpa, .{ .x = 2, .y = 2 });
        try f.lineTo(gpa, .{ .x = 14, .y = 2 });
        try f.lineTo(gpa, .{ .x = 14, .y = 14 });
        try f.lineTo(gpa, .{ .x = 2, .y = 14 });
        try f.close(gpa);
    }
    const flat = try f.finish(gpa);
    try testing.expectEqual(@as(i32, 256), flat.windingAt(8, 8));

    try fillPath(gpa, &c, flat, .identity, .nonzero, .black);
    // Wrapped to zero, so nonzero says outside. The direct winding count says
    // inside. The GPU agrees with the stencil, not with the count.
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(8, 8), 0.001);
    try testing.expect(c.stencilIsClean());
}

test "a transform moves the fill without rebuilding the mesh" {
    // The property that makes panning and zooming cheap: one mesh, many
    // matrices, and the vertex buffer never re-uploaded.
    const gpa = testing.allocator;
    var f: Flattener = .init(.{});
    defer f.deinit(gpa);
    const flat = try polygon(gpa, &f, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } });
    var m = try path.mesh(gpa, flat);
    defer m.deinit(gpa);

    var c: Canvas = try .init(gpa, 64, 64, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.transparent);

    c.fill(m, .translation(5, 5), .nonzero, .black, 1.0);
    c.fill(m, Transform.scaling(2, 2).concat(.translation(30, 30)), .nonzero, .black, 1.0);

    try testing.expectApproxEqAbs(@as(f32, 1), c.fb.alphaAt(10, 10), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(20, 20), 0.001);
    // The scaled copy runs from (30,30) to (50,50).
    try testing.expectApproxEqAbs(@as(f32, 1), c.fb.alphaAt(45, 45), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(55, 55), 0.001);
}

test "a clip path cuts the fill and pops back" {
    const gpa = testing.allocator;
    var c: Canvas = try .init(gpa, 64, 64, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.transparent);

    var cf: Flattener = .init(.{});
    defer cf.deinit(gpa);
    const clip_flat = try polygon(gpa, &cf, &.{ .{ 0, 0 }, .{ 32, 0 }, .{ 32, 64 }, .{ 0, 64 } });
    var clip_mesh = try path.mesh(gpa, clip_flat);
    defer clip_mesh.deinit(gpa);

    try c.pushClip(gpa, clip_mesh, .identity, .nonzero);
    try testing.expect(c.stencilIsClean());

    var ff: Flattener = .init(.{});
    defer ff.deinit(gpa);
    const flat = try polygon(gpa, &ff, &.{ .{ 8, 8 }, .{ 56, 8 }, .{ 56, 24 }, .{ 8, 24 } });
    try fillPath(gpa, &c, flat, .identity, .nonzero, .black);

    // Left of the clip edge, painted; right of it, not.
    try testing.expectApproxEqAbs(@as(f32, 1), c.fb.alphaAt(16, 16), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(48, 16), 0.001);

    c.popClip(gpa);
    try fillPath(gpa, &c, flat, .identity, .nonzero, .black);
    try testing.expectApproxEqAbs(@as(f32, 1), c.fb.alphaAt(48, 16), 0.001);
}

test "nested clips intersect and never widen" {
    const gpa = testing.allocator;
    var c: Canvas = try .init(gpa, 64, 64, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.transparent);

    var a: Flattener = .init(.{});
    defer a.deinit(gpa);
    const left = try polygon(gpa, &a, &.{ .{ 0, 0 }, .{ 32, 0 }, .{ 32, 64 }, .{ 0, 64 } });
    var left_mesh = try path.mesh(gpa, left);
    defer left_mesh.deinit(gpa);

    var b: Flattener = .init(.{});
    defer b.deinit(gpa);
    const top = try polygon(gpa, &b, &.{ .{ 0, 0 }, .{ 64, 0 }, .{ 64, 32 }, .{ 0, 32 } });
    var top_mesh = try path.mesh(gpa, top);
    defer top_mesh.deinit(gpa);

    try c.pushClip(gpa, left_mesh, .identity, .nonzero);
    try c.pushClip(gpa, top_mesh, .identity, .nonzero);

    var ff: Flattener = .init(.{});
    defer ff.deinit(gpa);
    const flat = try polygon(gpa, &ff, &.{ .{ 0, 0 }, .{ 64, 0 }, .{ 64, 64 }, .{ 0, 64 } });
    try fillPath(gpa, &c, flat, .identity, .nonzero, .black);

    try testing.expectApproxEqAbs(@as(f32, 1), c.fb.alphaAt(16, 16), 0.001); // both
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(48, 16), 0.001); // top only
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(16, 48), 0.001); // left only
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(48, 48), 0.001); // neither

    c.popClip(gpa);
    c.popClip(gpa);
}

test "overlapping fills composite in submission order" {
    const gpa = testing.allocator;
    var c: Canvas = try .init(gpa, 32, 32, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.white);

    var f: Flattener = .init(.{});
    defer f.deinit(gpa);
    const flat = try polygon(gpa, &f, &.{ .{ 4, 4 }, .{ 28, 4 }, .{ 28, 28 }, .{ 4, 28 } });

    try fillPath(gpa, &c, flat, .identity, .nonzero, .{ .r = 1, .g = 0, .b = 0 });
    try fillPath(gpa, &c, flat, .identity, .nonzero, .{ .r = 0, .g = 0, .b = 1 });

    const got = c.fb.at(16, 16);
    try testing.expectApproxEqAbs(@as(f32, 0), got.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), got.b, 0.01);
}

test "a multiply fill lets the backdrop through, which is what a highlight is" {
    // The whole reason blend modes are here. A highlight annotation is a
    // yellow rectangle over the text with `/BM /Multiply`; drawn normally it
    // is a yellow rectangle over the text and the text is gone.
    const gpa = testing.allocator;
    var c: Canvas = try .init(gpa, 16, 16, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.white);

    var f: Flattener = .init(.{});
    defer f.deinit(gpa);

    // A black bar across the middle: the "text".
    {
        const flat = try polygon(gpa, &f, &.{ .{ 0, 6 }, .{ 16, 6 }, .{ 16, 10 }, .{ 0, 10 } });
        var m = try path.mesh(gpa, flat);
        defer m.deinit(gpa);
        c.fill(m, .identity, .nonzero, .black, 1);
    }

    f.reset();
    c.blend_mode = .multiply;
    {
        const flat = try polygon(gpa, &f, &.{ .{ 0, 0 }, .{ 16, 0 }, .{ 16, 16 }, .{ 0, 16 } });
        var m = try path.mesh(gpa, flat);
        defer m.deinit(gpa);
        c.fill(m, .identity, .nonzero, .{ .r = 1, .g = 1, .b = 0 }, 1);
    }
    c.blend_mode = .normal;

    // Off the bar: white times yellow is yellow.
    const paper = c.fb.at(8, 2);
    try testing.expectApproxEqAbs(@as(f32, 1), paper.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), paper.b, 0.01);

    // On it: black times anything is black, so the text survives.
    const ink = c.fb.at(8, 8);
    try testing.expectApproxEqAbs(@as(f32, 0), ink.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), ink.g, 0.01);
}

test "the compositing space decides what half of black over white means" {
    // The whole of the difference between a page and a photocopy of one, in
    // one pixel. Half coverage of black over white is 0.5 if the halving is
    // done in sRGB and 0.735 if it is done in light, and every antialiased
    // glyph edge in a document is that pixel. Both answers are defensible in
    // the abstract; PDF composites in the device's colour space (11.3.8) and
    // so does every other reader, so `.srgb` is the default and this pins it
    // rather than leaving it to whichever one a later edit happens to write.
    const gpa = testing.allocator;

    for ([_]struct { space: Space, want: f32 }{
        .{ .space = .srgb, .want = 0.5 },
        .{ .space = .linear, .want = 0.7354 },
    }) |case| {
        var c: Canvas = try .init(gpa, 16, 16, .{ .samples = .one, .space = case.space });
        defer c.deinit(gpa);
        c.fb.clear(.white);

        var f: Flattener = .init(.{});
        defer f.deinit(gpa);
        const flat = try polygon(gpa, &f, &.{ .{ 2, 2 }, .{ 14, 2 }, .{ 14, 14 }, .{ 2, 14 } });
        var m = try path.mesh(gpa, flat);
        defer m.deinit(gpa);
        c.fill(m, .identity, .nonzero, .black, 0.5);

        try testing.expectApproxEqAbs(case.want, c.fb.at(8, 8).r, 0.01);
    }
}

test "an empty mesh draws nothing and touches nothing" {
    const gpa = testing.allocator;
    var c: Canvas = try .init(gpa, 16, 16, .{});
    defer c.deinit(gpa);
    c.fb.clear(.transparent);

    var f: Flattener = .init(.{});
    defer f.deinit(gpa);
    const flat = try f.finish(gpa);
    try fillPath(gpa, &c, flat, .identity, .nonzero, .black);

    try testing.expect(c.stencilIsClean());
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(8, 8), 0.001);
}

test "a path entirely off the canvas is clipped rather than crashing" {
    const gpa = testing.allocator;
    var c: Canvas = try .init(gpa, 16, 16, .{});
    defer c.deinit(gpa);

    for ([_][2]f32{ .{ -1000, -1000 }, .{ 1000, 1000 }, .{ -1000, 1000 } }) |o| {
        var f: Flattener = .init(.{});
        defer f.deinit(gpa);
        const flat = try polygon(gpa, &f, &.{
            .{ o[0], o[1] },       .{ o[0] + 50, o[1] },
            .{ o[0] + 50, o[1] + 50 }, .{ o[0], o[1] + 50 },
        });
        try fillPath(gpa, &c, flat, .identity, .nonzero, .black);
        try testing.expect(c.stencilIsClean());
    }
}

test "the standard sample positions are the ones Vulkan specifies" {
    // Copied from the specification rather than derived, so this is a
    // transcription check: all inside the pixel, and the counts right.
    for ([_]Samples{ .one, .two, .four, .eight }) |s| {
        const p = s.positions();
        try testing.expectEqual(@as(usize, s.count()), p.len);
        for (p) |q| {
            try testing.expect(q[0] > 0 and q[0] < 1);
            try testing.expect(q[1] > 0 and q[1] < 1);
        }
    }
}

test "a stroked outline rasterises as a ring" {
    const gpa = testing.allocator;
    const stroke = @import("stroke.zig");

    var in: Flattener = .init(.{});
    defer in.deinit(gpa);
    const square = try polygon(gpa, &in, &.{ .{ 16, 16 }, .{ 48, 16 }, .{ 48, 48 }, .{ 16, 48 } });

    var out: Flattener = .init(.{});
    defer out.deinit(gpa);
    try stroke.outline(gpa, &out, square, .{ .width = 6, .join = .miter });
    const outlined = try out.finish(gpa);

    var c: Canvas = try .init(gpa, 64, 64, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.transparent);
    try fillPath(gpa, &c, outlined, .identity, .nonzero, .black);

    // On the line, painted; inside and outside the ring, not.
    try testing.expectApproxEqAbs(@as(f32, 1), c.fb.alphaAt(32, 15), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(32, 32), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(32, 8), 0.001);
    try testing.expect(c.stencilIsClean());
}

test "the interior of a multisampled fill is solid, diagonal included" {
    // The cover geometry is a quad, which is two triangles sharing the
    // bounding box's diagonal. Blending once per triangle composites the same
    // colour over that diagonal's pixels twice at partial coverage: 0.5 then
    // 0.5 again is 0.75, not 1. The result is a lighter line corner to corner
    // through every filled shape on the page -- invisible at one sample,
    // because there only one triangle can claim the single sample, and plainly
    // visible at four.
    //
    // Deliberately at fractional coordinates: on integer bounds the diagonal
    // passes through pixel corners and the artefact hides.
    const gpa = testing.allocator;
    var c: Canvas = try .init(gpa, 48, 48, .{ .samples = .four });
    defer c.deinit(gpa);
    c.fb.clear(.white);

    var f: Flattener = .init(.{});
    defer f.deinit(gpa);
    const flat = try polygon(gpa, &f, &.{
        .{ 6.37, 8.21 }, .{ 41.63, 8.21 }, .{ 41.63, 39.79 }, .{ 6.37, 39.79 },
    });
    try fillPath(gpa, &c, flat, .identity, .nonzero, .black);

    // Every pixel strictly inside must be fully covered. Before the fix the
    // ones on the diagonal came out at 0.75.
    var worst: f32 = 1;
    var at: [2]u32 = .{ 0, 0 };
    var y: u32 = 9;
    while (y < 39) : (y += 1) {
        var x: u32 = 7;
        while (x < 41) : (x += 1) {
            const a = c.fb.alphaAt(x, y);
            if (a < worst) {
                worst = a;
                at = .{ x, y };
            }
        }
    }
    testing.expectApproxEqAbs(@as(f32, 1), worst, 0.001) catch |e| {
        std.debug.print("pixel {d},{d} is only {d:.3} covered\n", .{ at[0], at[1], worst });
        return e;
    };
}
