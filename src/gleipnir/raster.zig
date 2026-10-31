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
const slug = @import("slug.zig");
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

/// A half-open rectangle of device pixels: `x0 <= x < x1`, `y0 <= y < y1`.
///
/// Integer, not `Bounds`, because it is a range of array indices and every
/// use of it is a loop bound. `Bounds` is the float geometry it comes from.
pub const Box = struct {
    x0: u32 = 0,
    y0: u32 = 0,
    x1: u32 = 0,
    y1: u32 = 0,

    pub fn widthOf(b: Box) u32 {
        return b.x1 -| b.x0;
    }

    pub fn heightOf(b: Box) u32 {
        return b.y1 -| b.y0;
    }

    pub fn area(b: Box) usize {
        return @as(usize, b.widthOf()) * b.heightOf();
    }

    pub fn isEmpty(b: Box) bool {
        return b.x1 <= b.x0 or b.y1 <= b.y0;
    }

    pub fn intersect(a: Box, b: Box) Box {
        return .{
            .x0 = @max(a.x0, b.x0),
            .y0 = @max(a.y0, b.y0),
            .x1 = @min(a.x1, b.x1),
            .y1 = @min(a.y1, b.y1),
        };
    }

    pub fn contains(b: Box, x: u32, y: u32) bool {
        return x >= b.x0 and x < b.x1 and y >= b.y0 and y < b.y1;
    }

    /// Every pixel a `Bounds` touches, clamped to `limit`.
    ///
    /// The `+ 1` on the maxima is the same one the two rasterising loops use:
    /// a shape ending at x = 10.0 still deposits samples in pixel 10, because
    /// the sample positions inside a pixel are offsets from its corner.
    pub fn fromBounds(b: Bounds, limit: Box) Box {
        if (b.isEmpty()) return .{};
        const x0: u32 = @intFromFloat(@max(0.0, @floor(b.min_x)));
        const y0: u32 = @intFromFloat(@max(0.0, @floor(b.min_y)));
        const x1: u32 = @as(u32, @intFromFloat(@max(0.0, @ceil(b.max_x)))) +| 1;
        const y1: u32 = @as(u32, @intFromFloat(@max(0.0, @ceil(b.max_y)))) +| 1;
        return (Box{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }).intersect(limit);
    }
};

/// Somewhere to rasterise coverage that is not the framebuffer: a clip path,
/// or a soft mask. One byte per pixel of `box`, and nothing outside it.
pub const Mask = struct {
    data: []u8,
    box: Box,

    pub fn at(m: Mask, x: u32, y: u32) u8 {
        if (!m.box.contains(x, y)) return 0;
        return m.data[@as(usize, y - m.box.y0) * m.box.widthOf() + (x - m.box.x0)];
    }
};

/// One entry of the clip stack: the mask a `pushClip` displaced, and where it
/// lived. Restoring a clip is two assignments, whatever its size.
const SavedClip = struct { mask: []u8, box: Box };

/// One analytic fill: which path in the store, and where to put it.
///
/// The curves stay in their own space and the transform is carried separately
/// -- the same arrangement the GPU pipeline uses, and for the same reason.
/// One uploaded outline can be drawn at any scale, so a zoom changes a matrix
/// rather than every buffer on the device.
pub const SlugFill = struct {
    store: *const slug.Store,
    header: u32,
    /// Path space to device space.
    xform: Transform,
};

/// One drawn image: decoded pixels, and the matrix that puts the unit square
/// where they go.
pub const ImageFill = struct {
    /// Straight (not premultiplied) RGBA, eight bits a channel.
    pixels: []const u8,
    width: u32,
    height: u32,
    /// The unit square to device pixels.
    xform: Transform,
    /// `/ImageMask`: the alpha is a stencil and the colour comes from the
    /// fill in force, not from the image.
    is_mask: bool = false,
    mask_color: Color = .black,
};

/// How many samples to take across one device pixel, from how many source
/// pixels it covers.
///
/// One when magnifying -- there is nothing to average, and averaging would
/// only blur. Up to four when minifying, which is sixteen samples a pixel at
/// the limit and enough to stop a page-sized photograph from shimmering.
fn sampleSteps(footprint: f32) u32 {
    if (!(footprint > 1.5)) return 1;
    return @min(4, @as(u32, @intFromFloat(@ceil(footprint))));
}

/// A `Bounds` through a transform: the box of the four mapped corners, which
/// is what a rotated path needs and what an axis-aligned one costs nothing.
fn mapBounds(b: Bounds, t: Transform) Bounds {
    if (b.isEmpty()) return .empty;
    var out: Bounds = .empty;
    for ([4][2]f32{
        .{ b.min_x, b.min_y }, .{ b.max_x, b.min_y },
        .{ b.max_x, b.max_y }, .{ b.min_x, b.max_y },
    }) |corner| {
        out = out.add(t.apply(.{ .x = corner[0], .y = corner[1] }));
    }
    return out;
}

/// A framebuffer, a stencil buffer, and a clip.
pub const Canvas = struct {
    fb: Framebuffer,
    /// One byte per sample, `width * height * samples`. Zero everywhere
    /// between paths, which is an invariant a test checks rather than a hope.
    stencil: []u8,
    /// Clip coverage inside `clip_box`, one byte per pixel. Outside the box
    /// the clip is zero *by definition* -- there is no storage for it and
    /// nothing is drawn there.
    ///
    /// A rectangular clip could be a loop bound, but PDF clips with paths --
    /// `W n` is on nearly every page that has a figure on it -- and an
    /// arbitrary clip region has to be stored somewhere. A GPU implementation
    /// would keep this in a second attachment or in the high bits of the same
    /// stencil; a byte per pixel is the CPU's version of that and it
    /// antialiases the clip edge for free, which the stencil-bit version
    /// cannot.
    ///
    /// The box is not an optimisation of the common case, it is the
    /// difference between a usable reader and an unusable one. A scatter plot
    /// draws each marker inside its own two-point clip: page 4 of a paper in
    /// the corpus has 1,635 of them. Storing each as a full-page mask means
    /// duplicating, zeroing and multiplying a megabyte three times per marker
    /// -- five gigabytes of memory traffic for a page whose clipped area adds
    /// up to a few thousand pixels, and three and a half seconds of it. With
    /// the box, each of those clips costs the nine bytes it covers.
    clip: []u8,
    /// Where `clip` lives. Starts as the whole canvas and only ever shrinks
    /// until a `popClip` restores a wider one.
    clip_box: Box = .{},
    /// Saved clips, for `pushClip` / `popClip`.
    clip_stack: std.ArrayList(SavedClip) = .empty,
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
            .clip_box = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h },
            .cover = cover,
            .samples = options.samples,
        };
    }

    pub fn deinit(c: *Canvas, gpa: Allocator) void {
        c.fb.deinit(gpa);
        gpa.free(c.stencil);
        if (c.clip.len != 0) gpa.free(c.clip);
        gpa.free(c.cover);
        for (c.clip_stack.items) |s| {
            if (s.mask.len != 0) gpa.free(s.mask);
        }
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

    /// The clip's coverage at one pixel, which is zero outside the box.
    pub inline fn clipAt(c: *const Canvas, x: u32, y: u32) u8 {
        const b = c.clip_box;
        if (!b.contains(x, y)) return 0;
        return c.clip[@as(usize, y - b.y0) * b.widthOf() + (x - b.x0)];
    }

    /// Intersects the clip with a path. The mesh is rendered to coverage the
    /// same way a fill is, and multiplied into the existing mask.
    ///
    /// The new mask covers the intersection of the old box with the path's
    /// own bounds, because that is the only place the result can be non-zero:
    /// outside the path there is no coverage, and outside the old box there
    /// was no clip. So a clip costs its own area and not the page's.
    pub fn pushClip(c: *Canvas, gpa: Allocator, m: Mesh, xform: Transform, rule: FillRule) Allocator.Error!void {
        // A mesh with no triangles -- a line, a dot, a subpath of two points
        // -- has no cover quad, so there are no bounds to read: `meshBounds`
        // would index an empty list. Such a path meets the page nowhere,
        // which is the case immediately below.
        const want: Box = if (m.isEmpty()) .{} else Box.fromBounds(meshBounds(m, xform), c.clip_box);

        try c.clip_stack.append(gpa, .{ .mask = c.clip, .box = c.clip_box });
        errdefer _ = c.clip_stack.pop();

        // A clip that meets the page nowhere is not the same as no clip: it
        // hides everything until its `Q`, which is what `W n` with a
        // degenerate or off-page path is asking for.
        if (want.isEmpty()) {
            c.clip = &.{};
            c.clip_box = .{};
            return;
        }

        const mask = try gpa.alloc(u8, want.area());
        @memset(mask, 0);

        // Coverage of the clip path, then `clip *= coverage`. Multiplying
        // rather than replacing is what makes nested clips intersect, which is
        // the only thing PDF's clip stack ever does (§8.5.4): a clip can be
        // narrowed by `W` and widened only by `Q`.
        //
        // `coverage` still reads the *old* clip through `clipAt`, which is
        // both correct -- coverage outside the enclosing clip cannot matter --
        // and what keeps the stencil buffer clean, since the two passes skip
        // exactly the same pixels.
        c.coverage(m, xform, rule, .{ .data = mask, .box = want });

        const stride = want.widthOf();
        var y: u32 = want.y0;
        while (y < want.y1) : (y += 1) {
            const row = @as(usize, y - want.y0) * stride;
            var x: u32 = want.x0;
            while (x < want.x1) : (x += 1) {
                const i = row + (x - want.x0);
                mask[i] = @intCast((@as(u32, mask[i]) * c.clipAt(x, y) + 127) / 255);
            }
        }

        c.clip = mask;
        c.clip_box = want;
    }

    pub fn popClip(c: *Canvas, gpa: Allocator) void {
        const saved = c.clip_stack.pop() orelse return;
        if (c.clip.len != 0) gpa.free(c.clip);
        c.clip = saved.mask;
        c.clip_box = saved.box;
    }

    /// Fills a mesh. The two passes, in order.
    pub fn fill(c: *Canvas, m: Mesh, xform: Transform, rule: FillRule, color: Color, alpha: f32) void {
        if (m.isEmpty()) return;
        // Nothing survives an empty clip, and a path outside the clip box
        // touches no pixel the resolve would keep. Both are worth an early
        // exit: on a clipped page most fills are one or the other.
        if (c.clip_box.isEmpty()) return;
        if (Box.fromBounds(meshBounds(m, xform), c.clip_box).isEmpty()) return;
        c.stencilPass(m, xform);
        c.coverPass(m, xform, rule, color, alpha, null);
    }

    /// Fills a path from its curves instead of from a mesh: the CPU model of
    /// the slug pipeline's fragment shader, pixel for pixel.
    ///
    /// There is no stencil pass, no cover pass and no mesh. Each pixel asks
    /// the outline directly how much of itself is inside, which is why this
    /// can be checked against `fill` on a real page -- two independent
    /// rasterisers, one display list, one difference to look at. That
    /// comparison is `fenrir raster --path both`, and it is the only evidence
    /// that the shader is right that does not require a GPU to collect.
    pub fn fillSlug(c: *Canvas, f: SlugFill, color: Color, alpha: f32) void {
        const store = f.store;
        if (f.header >= store.headers.items.len) return;
        const h = store.headers.items[f.header];
        if (h.curve_count == 0) return;

        const inverse = f.xform.invert() orelse return;
        const area = Box.fromBounds(mapBounds(h.bounds(), f.xform), c.clip_box);
        if (area.isEmpty()) return;

        const scale: slug.Scale = .of(f.xform);
        const src = c.encodeColor(color);

        var y: u32 = area.y0;
        while (y < area.y1) : (y += 1) {
            var x: u32 = area.x0;
            while (x < area.x1) : (x += 1) {
                const clip = c.clipAt(x, y);
                if (clip == 0) continue;
                // The pixel's centre, back in the space the curves are in.
                const p = inverse.apply(.{
                    .x = @as(f32, @floatFromInt(x)) + 0.5,
                    .y = @as(f32, @floatFromInt(y)) + 0.5,
                });
                const cov = slug.coverageAt(store.*, f.header, p.x, p.y, scale);
                if (cov <= 0) continue;
                c.blendEncoded(
                    @as(usize, y) * c.width() + x,
                    src,
                    cov * (@as(f32, @floatFromInt(clip)) / 255.0) * alpha,
                );
            }
        }
    }

    /// Draws a decoded image through its placement matrix.
    ///
    /// PDF maps every image into the unit square and leaves the CTM to place
    /// it (§8.9.5), so the geometry is one matrix and the work is entirely in
    /// the sampling: each device pixel in the image's device-space box is
    /// mapped *back* through the inverse to find where it lands in the image.
    /// That is what makes a rotated or sheared image come out right, and it
    /// is why there is no separate path for the axis-aligned case.
    ///
    /// The unit square's `v` runs up and the image's rows run down, so row
    /// zero is at `v = 1`. Getting that backwards flips every figure on every
    /// page vertically, which is obvious once seen and easy to write.
    pub fn drawImage(c: *Canvas, img: ImageFill, alpha: f32) void {
        if (img.width == 0 or img.height == 0 or img.pixels.len == 0) return;
        const inverse = img.xform.invert() orelse return;
        const area = Box.fromBounds(mapBounds(.fromRect(0, 0, 1, 1), img.xform), c.clip_box);
        if (area.isEmpty()) return;

        // How many source pixels one device pixel covers, which decides
        // whether this is magnifying (sample once) or minifying (average, or
        // the page moirés). A figure scaled from 1600 pixels down to 160 has
        // a footprint of ten, and taking one sample in ten throws away the
        // other nine and shimmers when it moves.
        const fx = @abs(inverse.a) + @abs(inverse.c);
        const fy = @abs(inverse.b) + @abs(inverse.d);
        const steps_x = sampleSteps(fx * @as(f32, @floatFromInt(img.width)));
        const steps_y = sampleSteps(fy * @as(f32, @floatFromInt(img.height)));
        const n = @as(f32, @floatFromInt(steps_x * steps_y));

        // The sample offsets within a pixel, and the image's own size as a
        // float. All of them are the same for every pixel of the image, and
        // there are up to sixteen samples per pixel over a figure that covers
        // half a page -- so working them out here rather than in the innermost
        // loop takes two divisions and two conversions off every one of them.
        var offs_x: [4]f32 = undefined;
        var offs_y: [4]f32 = undefined;
        for (offs_x[0..steps_x], 0..) |*o, k| {
            o.* = (@as(f32, @floatFromInt(k)) + 0.5) / @as(f32, @floatFromInt(steps_x));
        }
        for (offs_y[0..steps_y], 0..) |*o, k| {
            o.* = (@as(f32, @floatFromInt(k)) + 0.5) / @as(f32, @floatFromInt(steps_y));
        }
        const img_w: f32 = @floatFromInt(img.width);
        const img_h: f32 = @floatFromInt(img.height);

        var y: u32 = area.y0;
        while (y < area.y1) : (y += 1) {
            const fyp: f32 = @floatFromInt(y);
            var x: u32 = area.x0;
            while (x < area.x1) : (x += 1) {
                const clip = c.clipAt(x, y);
                if (clip == 0) continue;

                const fxp: f32 = @floatFromInt(x);
                var acc: [4]f32 = @splat(0);
                var taken: u32 = 0;
                for (offs_y[0..steps_y]) |oy| {
                    for (offs_x[0..steps_x]) |ox| {
                        const px = fxp + ox;
                        const py = fyp + oy;
                        const uv = inverse.apply(.{ .x = px, .y = py });
                        if (uv.x < 0 or uv.x >= 1 or uv.y < 0 or uv.y >= 1) continue;

                        const ix: u32 = @min(img.width - 1, @as(u32, @intFromFloat(uv.x * img_w)));
                        const iy: u32 = @min(img.height - 1, @as(u32, @intFromFloat((1 - uv.y) * img_h)));
                        const at = (@as(usize, iy) * img.width + ix) * 4;
                        if (at + 4 > img.pixels.len) continue;

                        // Averaged premultiplied, so a transparent texel does
                        // not drag its colour into the average.
                        const a = @as(f32, @floatFromInt(img.pixels[at + 3])) / 255.0;
                        acc[0] += @as(f32, @floatFromInt(img.pixels[at + 0])) / 255.0 * a;
                        acc[1] += @as(f32, @floatFromInt(img.pixels[at + 1])) / 255.0 * a;
                        acc[2] += @as(f32, @floatFromInt(img.pixels[at + 2])) / 255.0 * a;
                        acc[3] += a;
                        taken += 1;
                    }
                }
                if (taken == 0) continue;

                // Divided by the full sample count and not by how many landed
                // inside: a device pixel half off the edge of the image is
                // half covered, and that is its antialiased edge.
                const cover = acc[3] / n;
                if (cover <= 0) continue;

                const color: Color = if (img.is_mask) .{
                    .r = img.mask_color.r,
                    .g = img.mask_color.g,
                    .b = img.mask_color.b,
                    .a = img.mask_color.a,
                } else .{
                    .r = acc[0] / acc[3],
                    .g = acc[1] / acc[3],
                    .b = acc[2] / acc[3],
                    .a = 1,
                };

                c.blend(
                    @as(usize, y) * c.width() + x,
                    color,
                    cover * (@as(f32, @floatFromInt(clip)) / 255.0) * alpha,
                );
            }
        }
    }

    /// Rasterises the mesh to an eight-bit coverage mask instead of blending
    /// it, for a clip path or a soft mask. Runs the same two passes, so a clip
    /// and a fill of the same path cover exactly the same samples.
    pub fn coverage(c: *Canvas, m: Mesh, xform: Transform, rule: FillRule, out: Mask) void {
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
        out: ?Mask,
    ) void {
        // The quad's device-space bounds, which is the region the resolve
        // below has to sweep and the only region `cover` can have been
        // written in. Narrowed by the clip, because `rasterTriangle` deposits
        // nothing outside it.
        const area = Box.fromBounds(meshBounds(m, xform), c.clip_box);
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
    fn resolve(c: *Canvas, area: Box, color: ?Color, alpha: f32, out: ?Mask) void {
        const inv_n = 1.0 / @as(f32, @floatFromInt(c.samples.count()));

        // The colour is the same for every pixel of the sweep, so its clamp
        // and its transfer function are the same answer every pixel. Encoded
        // once here rather than once per covered pixel.
        const src: Encoded = if (color) |k| c.encodeColor(k) else undefined;

        // `area` is the cover quad's box already intersected with the clip
        // box, so the bounds test in `clipAt` is known to pass and the row
        // base below replaces it.
        const clip_box = c.clip_box;
        const clip_w = clip_box.widthOf();
        const w = c.width();

        var y: u32 = area.y0;
        while (y < area.y1) : (y += 1) {
            const pixel_row = @as(usize, y) * w;
            const clip_row = @as(usize, y - clip_box.y0) * clip_w;

            // Most of a cover quad is empty -- a glyph fills a third of its
            // own box and a comma a twentieth -- so the row is swept a vector
            // at a time looking for anything at all, and only the blocks that
            // hold something are walked pixel by pixel.
            var x: u32 = area.x0;
            while (x < area.x1) {
                const run = @min(skip_width, area.x1 - x);
                if (run == skip_width) {
                    const block: @Vector(skip_width, u8) = c.cover[pixel_row + x ..][0..skip_width].*;
                    if (@reduce(.Or, block) == 0) {
                        x += skip_width;
                        continue;
                    }
                }

                const stop = x + run;
                while (x < stop) : (x += 1) {
                    const pixel = pixel_row + x;
                    const n = c.cover[pixel];
                    if (n == 0) continue;
                    c.cover[pixel] = 0;

                    const frac = @as(f32, @floatFromInt(n)) * inv_n *
                        (@as(f32, @floatFromInt(c.clip[clip_row + (x - clip_box.x0)])) / 255.0);

                    if (out) |mask| {
                        if (!mask.box.contains(x, y)) continue;
                        const i = @as(usize, y - mask.box.y0) * mask.box.widthOf() +
                            (x - mask.box.x0);
                        const v: u8 = @intFromFloat(@round(std.math.clamp(frac, 0, 1) * 255.0));
                        mask.data[i] = @max(mask.data[i], v);
                    } else {
                        c.blendEncoded(pixel, src, frac * alpha);
                    }
                }
            }
        }
    }

    /// How many pixels of `cover` are tested for emptiness at once. Sixteen
    /// is one SSE register and divides every page width this draws on.
    const skip_width = 16;

    const CoverState = struct {
        rule: FillRule,
    };

    const Pass = enum { stencil, cover };


    /// One triangle, one scanline at a time.
    ///
    /// The cover quad is two triangles that share a diagonal, so a sample on
    /// that diagonal must land in exactly one of them or it is either zeroed
    /// twice -- harmless -- or blended twice, which shows as a bright seam
    /// down the middle of every filled shape. `edgeInside` is the top-left
    /// rule that prevents it, and it is the same rule the hardware uses.
    ///
    /// The sample count, the pass and the fill rule are constant for the whole
    /// of the loop and were read inside it. Switching on all three here
    /// instantiates the body once per combination, which makes `positions` a
    /// comptime array the sample loop unrolls over and takes two branches out
    /// of the innermost scope.
    fn rasterTriangle(c: *Canvas, a: Vertex, b: Vertex, t: Vertex, pass: Pass, state: ?*CoverState) void {
        switch (c.samples) {
            inline else => |s| switch (pass) {
                .stencil => c.triangle(s, .stencil, .nonzero, a, b, t),
                .cover => switch (state.?.rule) {
                    inline else => |r| c.triangle(s, .cover, r, a, b, t),
                },
            },
        }
    }

    fn triangle(
        c: *Canvas,
        comptime s: Samples,
        comptime pass: Pass,
        comptime rule: FillRule,
        a: Vertex,
        b: Vertex,
        t: Vertex,
    ) void {
        const n = comptime s.count();
        const positions: [n][2]f32 = comptime s.positions()[0..n].*;

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
        // Clipped-away pixels produce no fragments at all, which is both
        // faster and the reason a clip never leaves stencil bits behind: the
        // cover pass skips exactly the pixels the stencil pass skipped. Most
        // of that skipping is free, as a loop bound rather than a test.
        const area_px = Box.fromBounds(box, c.clip_box);
        if (area_px.isEmpty()) return;

        // The three edge tests, bracketed over a pixel. See `Edge`.
        const edges: [3]Edge = .{
            .of(p0, p1, area_px),
            .of(p1, p2, area_px),
            .of(p2, p0, area_px),
        };

        // `area_px` is already intersected with the clip box, so every pixel
        // below is inside it and the bounds test `clipAt` makes is known to
        // pass. A row base computed once replaces it.
        const clip_box = c.clip_box;
        const clip_w = clip_box.widthOf();
        const w = c.width();

        var y: u32 = area_px.y0;
        while (y < area_px.y1) : (y += 1) {
            const fy: f32 = @floatFromInt(y);
            const clip_row = @as(usize, y - clip_box.y0) * clip_w;
            const pixel_row = @as(usize, y) * w;

            // The edge function is affine, so along a row it is `base - dy*x`.
            // Hoisting the y half out of the pixel loop leaves one fused
            // multiply-add per edge per pixel where there were two multiplies
            // and two subtractions, and unlike carrying `d` incrementally it
            // accumulates no error across the row.
            var base: [3]f32 = undefined;
            for (&base, edges) |*v, e| v.* = e.dx * (fy - e.ay) + e.dy * e.ax;

            var x: u32 = area_px.x0;
            while (x < area_px.x1) : (x += 1) {
                const pixel = pixel_row + x;

                if (c.clip[clip_row + (x - clip_box.x0)] == 0) continue;

                // Which side of each edge the pixel's corner is on, and
                // whether its samples can straddle the edge at all. A pixel
                // wholly outside any edge is skipped without touching a
                // sample, and one wholly inside all three takes every sample
                // without testing it -- between them that is most of the
                // pixels in a triangle's box, and all of the arithmetic.
                const fx: f32 = @floatFromInt(x);
                var whole = true;
                var outside = false;
                inline for (edges, base) |e, b0| {
                    const d = b0 - e.dy * fx;
                    if (d + e.hi < -e.margin) outside = true;
                    if (d + e.lo <= e.margin) whole = false;
                }
                if (outside) continue;

                const cell: *[n]u8 = c.stencil[pixel * n ..][0..n];

                // A cover triangle over a pixel no stencil triangle reached
                // has nothing to test and nothing to clear. Worth checking
                // because the cover quad is the whole path's box while the
                // path is usually a small part of it -- an `o` fills about a
                // third of its own box, and a comma a twentieth.
                if (pass == .cover and allClear(n, cell)) continue;

                var covered: u32 = 0;
                inline for (positions, 0..) |off, si| {
                    var hit = true;
                    if (!whole) hit = inside(p0, p1, p2, fx + off[0], fy + off[1]);
                    if (hit) switch (pass) {
                        .stencil => {
                            // INCREMENT_AND_WRAP / DECREMENT_AND_WRAP.
                            cell[si] = if (front) cell[si] +% 1 else cell[si] -% 1;
                        },
                        .cover => {
                            const v = cell[si];
                            // Both failOp and passOp are ZERO, so the sample
                            // is cleared whether it passed or not.
                            cell[si] = 0;
                            const on = switch (rule) {
                                .nonzero => v != 0,
                                .even_odd => (v & 1) != 0,
                            };
                            if (on) covered += 1;
                        },
                    };
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
        c.blendEncoded(pixel, c.encodeColor(color), cov);
    }

    /// A colour clamped and put through the framebuffer's transfer function,
    /// which is the half of `blend` that does not depend on the pixel. A sweep
    /// over one path does it once instead of once per covered pixel.
    const Encoded = struct { rgb: [3]f32, a: f32 };

    fn encodeColor(c: *const Canvas, color: Color) Encoded {
        return .{
            .rgb = .{
                c.fb.encode(std.math.clamp(color.r, 0, 1)),
                c.fb.encode(std.math.clamp(color.g, 0, 1)),
                c.fb.encode(std.math.clamp(color.b, 0, 1)),
            },
            .a = std.math.clamp(color.a, 0, 1),
        };
    }

    fn blendEncoded(c: *Canvas, pixel: usize, color: Encoded, cov: f32) void {
        const a = color.a * std.math.clamp(cov, 0, 1);
        if (a <= 0) return;
        const o = pixel * 4;
        const ab = c.fb.pixels[o + 3];

        var cs = color.rgb;
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

/// The device-space bounds of a mesh, taken from its cover quad.
///
/// The quad is the path's own bounding box carried through the mesh, so this
/// is four transformed points rather than a sweep of every vertex -- which
/// matters, because it is called once per fill and per clip on a page that
/// may have thousands of both.
fn meshBounds(m: Mesh, xform: Transform) Bounds {
    var box: Bounds = .empty;
    var k: u32 = 0;
    while (k < Mesh.cover_count) : (k += 1) {
        box = box.add(apply(xform, m.vertices[m.indices[m.cover_first + k]]).point());
    }
    return box;
}

fn apply(t: Transform, v: Vertex) Vertex {
    return .{
        .x = t.a * v.x + t.c * v.y + t.e,
        .y = t.b * v.x + t.d * v.y + t.f,
    };
}

/// Whether every sample of one pixel is clear. Folded rather than compared so
/// that the whole pixel is one or two machine words either way, and folded as
/// a vector because `n` is a comptime power of two at every call site.
inline fn allClear(comptime n: u8, cell: *const [n]u8) bool {
    return @reduce(.Or, @as(@Vector(n, u8), cell.*)) == 0;
}

fn signedArea(a: Vertex, b: Vertex, c: Vertex) f32 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

fn inside(p0: Vertex, p1: Vertex, p2: Vertex, x: f32, y: f32) bool {
    return edgeInside(p0, p1, x, y) and edgeInside(p1, p2, x, y) and edgeInside(p2, p0, x, y);
}

/// One directed edge of a triangle, with the range its test can take across a
/// single pixel.
///
/// `edgeInside` evaluates `dx*(y - ay) - dy*(x - ax)` at a sample, and every
/// sample of a pixel lies in the unit square at that pixel's corner. Since
/// the expression is affine, `d(x + u, y + v) = d(x, y) + dx*v - dy*u`, so
/// the corner's value plus `lo .. hi` brackets everything the pixel's samples
/// can produce. A bracket entirely below zero means no sample is inside and a
/// bracket entirely above it means all of them are, and either way the
/// per-sample tests can be skipped -- which on a page of text is most of the
/// pixels in a triangle's box, since a glyph's triangles are thin and their
/// boxes are not.
const Edge = struct {
    dx: f32,
    dy: f32,
    ax: f32,
    ay: f32,
    lo: f32,
    hi: f32,
    /// How far clear of zero the bracket has to be before it is believed.
    ///
    /// The bracket and the per-sample test are the same arithmetic in a
    /// different order, so they can disagree in the last bits, and a
    /// disagreement exactly on an edge would light or drop a sample that the
    /// exact test would not -- which is the one thing the top-left rule
    /// exists to prevent. This is the largest `d` the triangle's box can
    /// produce, times a hundred times the float's own epsilon: anything
    /// inside it takes the slow path rather than guessing.
    margin: f32,

    fn of(a: Vertex, b: Vertex, box: Box) Edge {
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const span_x = @max(
            @abs(@as(f32, @floatFromInt(box.x0)) - a.x),
            @abs(@as(f32, @floatFromInt(box.x1)) - a.x),
        );
        const span_y = @max(
            @abs(@as(f32, @floatFromInt(box.y0)) - a.y),
            @abs(@as(f32, @floatFromInt(box.y1)) - a.y),
        );
        return .{
            .dx = dx,
            .dy = dy,
            .ax = a.x,
            .ay = a.y,
            .lo = @min(dx, 0) - @max(dy, 0),
            .hi = @max(dx, 0) - @min(dy, 0),
            .margin = (@abs(dx) * span_y + @abs(dy) * span_x) * 1e-5,
        };
    }
};

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

/// A polygon's curves in a store of their own, for the analytic fill.
fn slugPolygon(gpa: Allocator, store: *slug.Store, pts: []const [2]f32) !u32 {
    var f: Flattener = .init(.{});
    defer f.deinit(gpa);
    const flat = try polygon(gpa, &f, pts);
    var curves: std.ArrayList(slug.Curve) = .empty;
    defer curves.deinit(gpa);
    try slug.fromFlattened(gpa, &curves, flat);
    return store.add(gpa, curves.items, .nonzero);
}

fn inkSum(c: Canvas) f64 {
    var sum: f64 = 0;
    var y: u32 = 0;
    while (y < c.height()) : (y += 1) {
        var x: u32 = 0;
        while (x < c.width()) : (x += 1) sum += c.fb.alphaAt(x, y);
    }
    return sum;
}

test "the analytic fill and the stencil fill agree, and both keep the area" {
    // `fillSlug` is the fragment shader's model and `fill` is the stencil
    // pipeline's, and neither had been run against the other outside
    // `raster --path both`. Two things are checked. Every pixel is within a
    // quarter of the other rasteriser's answer, which is what eight samples
    // and the two-ray blend can each be off by on a diagonal. And the ink
    // summed over the canvas is the polygon's area, to a tenth of a percent,
    // for both.
    const gpa = testing.allocator;
    const pts = [_][2]f32{ .{ 8.3, 6.1 }, .{ 52.7, 10.4 }, .{ 58.2, 40.9 }, .{ 30.5, 57.6 }, .{ 5.9, 35.2 } };

    var stencil: Canvas = try .init(gpa, 64, 64, .{ .samples = .eight });
    defer stencil.deinit(gpa);
    stencil.fb.clear(.transparent);
    var f: Flattener = .init(.{});
    defer f.deinit(gpa);
    try fillPath(gpa, &stencil, try polygon(gpa, &f, &pts), .identity, .nonzero, .black);

    var analytic: Canvas = try .init(gpa, 64, 64, .{ .samples = .one });
    defer analytic.deinit(gpa);
    analytic.fb.clear(.transparent);
    var store: slug.Store = .{};
    defer store.deinit(gpa);
    const id = try slugPolygon(gpa, &store, &pts);
    analytic.fillSlug(.{ .store = &store, .header = id, .xform = .identity }, .black, 1);

    var area: f64 = 0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        area += @as(f64, p[0]) * q[1] - @as(f64, q[0]) * p[1];
    }
    area = @abs(area) / 2;
    // Measured at 0.03% for eight samples and 0.007% for the analytic fill.
    try testing.expectApproxEqRel(area, inkSum(stencil), 0.001);
    try testing.expectApproxEqRel(area, inkSum(analytic), 0.001);

    var worst: f32 = 0;
    var y: u32 = 0;
    while (y < 64) : (y += 1) {
        var x: u32 = 0;
        while (x < 64) : (x += 1) {
            worst = @max(worst, @abs(stencil.fb.alphaAt(x, y) - analytic.fb.alphaAt(x, y)));
        }
    }
    try testing.expect(worst <= 0.25);
}

test "the analytic fill goes through its transform and obeys the clip" {
    const gpa = testing.allocator;
    var c: Canvas = try .init(gpa, 64, 64, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.transparent);

    // A unit square, placed by the matrix: the curves stay where they were
    // recorded and the fill inverts the transform per pixel, which is how an
    // instance draws a glyph.
    var store: slug.Store = .{};
    defer store.deinit(gpa);
    const id = try slugPolygon(gpa, &store, &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } });
    const place = Transform.scaling(48, 16).concat(.translation(8, 8));

    var cf: Flattener = .init(.{});
    defer cf.deinit(gpa);
    var clip_mesh = try path.mesh(gpa, try polygon(gpa, &cf, &.{ .{ 0, 0 }, .{ 32, 0 }, .{ 32, 64 }, .{ 0, 64 } }));
    defer clip_mesh.deinit(gpa);
    try c.pushClip(gpa, clip_mesh, .identity, .nonzero);

    c.fillSlug(.{ .store = &store, .header = id, .xform = place }, .black, 0.5);
    // The constant alpha scales the coverage, inside the clip.
    try testing.expectApproxEqAbs(@as(f32, 0.5), c.fb.alphaAt(16, 16), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(48, 16), 0.001);
    // Outside the square's placed rows, nothing.
    try testing.expectApproxEqAbs(@as(f32, 0), c.fb.alphaAt(16, 30), 0.001);

    c.popClip(gpa);
    c.fillSlug(.{ .store = &store, .header = id, .xform = place }, .black, 1);
    try testing.expectApproxEqAbs(@as(f32, 1), c.fb.alphaAt(48, 16), 0.001);
    // A singular matrix places nothing, and does not divide by zero.
    c.fb.clear(.transparent);
    c.fillSlug(.{ .store = &store, .header = id, .xform = Transform.scaling(0, 16) }, .black, 1);
    try testing.expectEqual(@as(f64, 0), inkSum(c));
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

test "a clip costs its own area, not the page's" {
    // The property that makes a page of small clipped marks affordable. A
    // scatter plot pushes one clip per marker; if each of those held a mask
    // the size of the page, the page would take seconds rather than
    // milliseconds, which is exactly what it used to do.
    const gpa = testing.allocator;
    var c = try Canvas.init(gpa, 512, 512, .{ .samples = .four });
    defer c.deinit(gpa);

    // No clip: the box is the whole canvas, and the mask is a byte a pixel.
    try testing.expectEqual(@as(usize, 512 * 512), c.clip.len);
    try testing.expectEqual(Box{ .x0 = 0, .y0 = 0, .x1 = 512, .y1 = 512 }, c.clip_box);

    var flat: Flattener = .{};
    defer flat.deinit(gpa);
    const small = try polygon(gpa, &flat, &.{
        .{ 100, 100 }, .{ 104, 100 }, .{ 104, 104 }, .{ 100, 104 },
    });
    var mesh = try path.mesh(gpa, small);
    defer mesh.deinit(gpa);

    try c.pushClip(gpa, mesh, .identity, .nonzero);
    // Six pixels a side at most: the four the square covers, plus the one the
    // sample positions can reach past each edge.
    try testing.expect(c.clip_box.widthOf() <= 6);
    try testing.expect(c.clip_box.heightOf() <= 6);
    try testing.expect(c.clip.len <= 36);
    try testing.expectEqual(c.clip_box.area(), c.clip.len);

    // Inside the square the clip is open, outside it is shut -- and "outside"
    // includes everywhere there is no longer any storage.
    try testing.expectEqual(@as(u8, 255), c.clipAt(102, 102));
    try testing.expectEqual(@as(u8, 0), c.clipAt(400, 400));
    try testing.expectEqual(@as(u8, 0), c.clipAt(0, 0));

    c.popClip(gpa);
    try testing.expectEqual(@as(u8, 255), c.clipAt(400, 400));
    try testing.expectEqual(Box{ .x0 = 0, .y0 = 0, .x1 = 512, .y1 = 512 }, c.clip_box);
    try testing.expect(c.stencilIsClean());
}

test "a clip that misses the page shuts everything out until it is popped" {
    const gpa = testing.allocator;
    var c = try Canvas.init(gpa, 64, 64, .{ .samples = .four });
    defer c.deinit(gpa);
    c.fb.clear(.white);

    var flat: Flattener = .{};
    defer flat.deinit(gpa);
    const away = try polygon(gpa, &flat, &.{
        .{ 500, 500 }, .{ 520, 500 }, .{ 520, 520 }, .{ 500, 520 },
    });
    var mesh = try path.mesh(gpa, away);
    defer mesh.deinit(gpa);

    try c.pushClip(gpa, mesh, .identity, .nonzero);
    try testing.expect(c.clip_box.isEmpty());
    try testing.expectEqual(@as(usize, 0), c.clip.len);

    // A fill that would have covered the canvas paints nothing, because an
    // off-page clip is still a clip. Not the same as no clip at all.
    var solid: Flattener = .{};
    defer solid.deinit(gpa);
    const all = try polygon(gpa, &solid, &.{
        .{ 0, 0 }, .{ 64, 0 }, .{ 64, 64 }, .{ 0, 64 },
    });
    var all_mesh = try path.mesh(gpa, all);
    defer all_mesh.deinit(gpa);
    c.fill(all_mesh, .identity, .nonzero, .black, 1.0);
    try testing.expectEqual(@as(f32, 1.0), c.fb.at(32, 32).r);

    c.popClip(gpa);
    c.fill(all_mesh, .identity, .nonzero, .black, 1.0);
    try testing.expectEqual(@as(f32, 0.0), c.fb.at(32, 32).r);
    try testing.expect(c.stencilIsClean());
}

test "an image lands the right way up and inside its rectangle" {
    // The orientation trap: PDF maps an image into the unit square with v
    // running *up* while its rows run *down*, so row zero is at v = 1. Get it
    // backwards and every figure on every page is mirrored vertically, which
    // on a photograph is obvious and on a plot with a symmetric axis is not.
    const gpa = testing.allocator;
    var c = try Canvas.init(gpa, 40, 40, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.white);

    // Two rows: red on top (row 0), blue underneath.
    const pixels = [_]u8{
        255, 0, 0, 255, 255, 0, 0, 255,
        0,   0, 255, 255, 0, 0, 255, 255,
    };

    // The unit square into a 20x20 box at (10, 10), *with the page's y flip
    // in it* -- which is what `pageTransform` always contributes, and which
    // is why v = 1 is the top of the drawn rectangle and not the bottom.
    c.drawImage(.{
        .pixels = &pixels,
        .width = 2,
        .height = 2,
        .xform = Transform.scaling(20, -20).concat(.translation(10, 30)),
    }, 1.0);

    // Row 0 of the image is at v = 1, which the flip puts at the top.
    const top = c.fb.at(15, 14);
    try testing.expect(top.r > 0.9 and top.b < 0.1);
    const bottom = c.fb.at(15, 26);
    try testing.expect(bottom.b > 0.9 and bottom.r < 0.1);

    // And nothing outside the rectangle was touched.
    try testing.expectEqual(@as(f32, 1.0), c.fb.at(2, 2).r);
    try testing.expectEqual(@as(f32, 1.0), c.fb.at(35, 35).b);
}

test "an image mask paints the fill colour where its alpha is set" {
    const gpa = testing.allocator;
    var c = try Canvas.init(gpa, 20, 20, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.white);

    // Left half opaque, right half transparent. The colours in an image mask
    // mean nothing; only the alpha does.
    const pixels = [_]u8{
        0, 255, 0, 255,
        0, 255, 0, 0,
    };

    c.drawImage(.{
        .pixels = &pixels,
        .width = 2,
        .height = 1,
        .xform = Transform.scaling(20, 20),
        .is_mask = true,
        .mask_color = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
    }, 1.0);

    // Red where the mask is set -- not the green in the pixels.
    const left = c.fb.at(5, 10);
    try testing.expect(left.r > 0.9 and left.g < 0.1);
    // Untouched where it is not.
    const right = c.fb.at(15, 10);
    try testing.expectEqual(@as(f32, 1.0), right.g);
}

test "an image obeys the clip like everything else" {
    const gpa = testing.allocator;
    var c = try Canvas.init(gpa, 40, 40, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.white);

    var flat: Flattener = .{};
    defer flat.deinit(gpa);
    const half = try polygon(gpa, &flat, &.{
        .{ 0, 0 }, .{ 20, 0 }, .{ 20, 40 }, .{ 0, 40 },
    });
    var mesh = try path.mesh(gpa, half);
    defer mesh.deinit(gpa);
    try c.pushClip(gpa, mesh, .identity, .nonzero);

    const pixels = [_]u8{ 0, 0, 0, 255 };
    c.drawImage(.{
        .pixels = &pixels,
        .width = 1,
        .height = 1,
        .xform = Transform.scaling(40, 40),
    }, 1.0);

    try testing.expectEqual(@as(f32, 0.0), c.fb.at(10, 20).r);
    try testing.expectEqual(@as(f32, 1.0), c.fb.at(30, 20).r);
    c.popClip(gpa);
}

test "minifying averages rather than picking one texel in ten" {
    // A checkerboard scaled far down is mid grey if it is filtered and either
    // black or white if it is not. Nearest-neighbour on a page-sized
    // photograph is what makes a scanned document shimmer when it scrolls.
    const gpa = testing.allocator;
    var c = try Canvas.init(gpa, 8, 8, .{ .samples = .one });
    defer c.deinit(gpa);
    c.fb.clear(.white);

    var pixels: [16 * 16 * 4]u8 = undefined;
    for (0..16) |y| {
        for (0..16) |x| {
            const v: u8 = if ((x + y) % 2 == 0) 0 else 255;
            const o = (y * 16 + x) * 4;
            pixels[o + 0] = v;
            pixels[o + 1] = v;
            pixels[o + 2] = v;
            pixels[o + 3] = 255;
        }
    }

    // Sixteen source pixels into four device pixels: a footprint of four.
    c.drawImage(.{
        .pixels = &pixels,
        .width = 16,
        .height = 16,
        .xform = Transform.scaling(4, 4).concat(.translation(2, 2)),
    }, 1.0);

    const mid = c.fb.at(3, 3).r;
    try testing.expect(mid > 0.2 and mid < 0.8);
}
