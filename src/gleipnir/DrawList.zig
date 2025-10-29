//! The draw layer: immediate call sites in, one instance buffer out.
//!
//! Everything a frame draws goes through here, and the shape of the API is
//! taken from RAD Debugger: there is no retained scene, no node graph, no
//! invalidation. Code that wants a rectangle on the screen calls `fill` at the
//! point in its control flow where it knows the rectangle exists, and the call
//! appends 96 bytes. A frame is built from scratch every time, which sounds
//! wasteful and is not -- appending a hundred thousand instances is a
//! memcpy-rate operation, and it buys the thing retained scene graphs spend
//! all their complexity failing to guarantee, which is that what is on the
//! screen is a function of the current state and nothing else.
//!
//! ## The two stacks
//!
//! Both are ambient, both are scoped with `defer`, and both are applied by
//! this file rather than by the GPU:
//!
//!     d.pushClip(row);      defer d.popClip();
//!     d.pushTransform(.translate(0, -scroll));  defer d.popTransform();
//!
//! Every rectangle a call site passes is in the current transform's space and
//! is clipped by the current clip. The transform is baked into the instance
//! here; the clip is written into the instance and enforced by the vertex
//! shader. Neither becomes pipeline state, which is what keeps the frame at
//! one draw call however deeply the UI nests.
//!
//! ## Why the transform stack is not a full matrix
//!
//! `Xform` is scale and offset, not the affine `gelgja.Transform` the
//! interpreter works in. A rotated rectangle is not a rectangle, so it cannot
//! be one instance, and supporting it would mean either six more floats per
//! instance and a matrix multiply per vertex, or silently drawing the wrong
//! shape. Neither is worth it, because the things this pipeline actually draws
//! -- panels, borders, scrollbars, glyph quads, image tiles -- are never
//! rotated, and the one rotation a PDF reader really needs, `/Rotate 90` on a
//! page, is a property of the whole frame and belongs in the projection.
//!
//! Anything genuinely rotated or skewed is a path, and paths are the other
//! pipeline. `Xform.fromTransform` is the border post: it returns null for a
//! matrix this layer cannot honour, so the interpreter finds out by being told
//! rather than by looking at the output.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");
const paint = @import("../gelgja/paint.zig");
const rect = @import("rect.zig");
const sdf = @import("sdf.zig");

const Bounds = geom.Bounds;
const Color = paint.Color;
const Instance = rect.Instance;
const Point = geom.Point;
const Radius = sdf.Radius;
const TextureId = rect.TextureId;
const Transform = geom.Transform;

const DrawList = @This();

pub const Error = Allocator.Error;

/// Deep enough that no honest UI reaches it -- a hundred-deep nesting of
/// scroll views inside scroll views is a bug, not a layout -- and small enough
/// that both stacks are a cheap fixed part of the struct rather than two more
/// allocations to fail.
pub const stack_depth = 64;

/// A scale and an offset: the transforms that map a rectangle to a rectangle.
///
/// Stored as separate x and y scales rather than one, because a page fitted to
/// a window width and a list row stretched horizontally both want a
/// non-uniform scale, and forbidding it would push those cases out of the
/// pipeline for no benefit.
pub const Xform = struct {
    sx: f32 = 1,
    sy: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub const identity: Xform = .{};

    pub fn translate(tx: f32, ty: f32) Xform {
        return .{ .tx = tx, .ty = ty };
    }

    pub fn scale(s: f32) Xform {
        return .{ .sx = s, .sy = s };
    }

    /// `inner` first, then `outer` -- the same order as `gelgja.Transform`'s
    /// `concat`, so that the two compose the same way round and a reader does
    /// not have to remember which file they are in.
    pub fn then(inner: Xform, outer: Xform) Xform {
        return .{
            .sx = inner.sx * outer.sx,
            .sy = inner.sy * outer.sy,
            .tx = inner.tx * outer.sx + outer.tx,
            .ty = inner.ty * outer.sy + outer.ty,
        };
    }

    pub fn applyPoint(x: Xform, p: Point) Point {
        return .{ .x = p.x * x.sx + x.tx, .y = p.y * x.sy + x.ty };
    }

    /// Transforms and re-normalises, because a negative scale swaps min and
    /// max and a `Bounds` with max below min reads as empty.
    pub fn applyBounds(x: Xform, b: Bounds) Bounds {
        if (b.isEmpty()) return b;
        return .fromRect(
            b.min_x * x.sx + x.tx,
            b.min_y * x.sy + x.ty,
            b.max_x * x.sx + x.tx,
            b.max_y * x.sy + x.ty,
        );
    }

    /// Scales a thickness or a radius, which have no direction to be scaled
    /// along. The smaller of the two axes, so that a corner radius under a
    /// non-uniform scale can never exceed half the shorter side and produce
    /// the overlap `Radius.clampTo` exists to prevent. A radius is a circle
    /// and this pipeline has no ellipses.
    pub fn applyLength(x: Xform, v: f32) f32 {
        return v * @min(@abs(x.sx), @abs(x.sy));
    }

    /// Null when `t` rotates or skews, and so cannot be honoured by an
    /// axis-aligned instance. A quarter turn is rejected too: it maps
    /// rectangles to rectangles, but it also swaps which corner a radius
    /// belongs to and which way a gradient runs, and getting that wrong is
    /// worse than declining.
    pub fn fromTransform(t: Transform) ?Xform {
        if (t.b != 0 or t.c != 0) return null;
        return .{ .sx = t.a, .sy = t.d, .tx = t.e, .ty = t.f };
    }
};

/// What a box looks like. Every call site below is this struct with some
/// fields already filled in.
pub const Style = struct {
    /// The fill, used for all four corners unless `corners` overrides it.
    color: Color = .white,
    /// Per-corner colours for a gradient, clockwise from the top left.
    corners: ?[4]Color = null,
    radius: Radius = .none,
    /// Ring thickness in pixels, inside the edge. Zero fills.
    border: f32 = 0,
    /// Shadow radius in pixels. Zero still antialiases the edge.
    softness: f32 = 0,
};

pub const Texture = struct {
    width: u32,
    height: u32,
};

/// One `vkCmdDraw`. With descriptor indexing there is exactly one of these per
/// frame; without it, one per run of instances sharing a texture.
pub const Batch = struct {
    first: u32,
    count: u32,
    texture: TextureId,
};

gpa: Allocator,

instances: std.ArrayList(Instance) = .empty,
textures: std.ArrayList(Texture) = .empty,

/// The framebuffer, and the outermost clip. Nothing is drawn outside it.
viewport: Bounds,

clips: [stack_depth]Bounds = undefined,
clip_top: u32 = 0,
xforms: [stack_depth]Xform = undefined,
xform_top: u32 = 0,

/// Instances that would not have coloured a pixel and were never appended.
/// Worth counting rather than just dropping: a frame that culls ninety percent
/// of its draws is a UI walking a whole document when it should be walking a
/// visible range, and that only shows up as a number.
culled: u32 = 0,
/// Pushes past `stack_depth`. Always a bug in the caller; see `pushClip`.
overflows: u32 = 0,

pub fn init(gpa: Allocator, viewport: Bounds) DrawList {
    var d: DrawList = .{ .gpa = gpa, .viewport = viewport };
    d.clips[0] = viewport;
    d.xforms[0] = .identity;
    return d;
}

pub fn deinit(d: *DrawList) void {
    d.instances.deinit(d.gpa);
    d.textures.deinit(d.gpa);
    d.* = undefined;
}

/// Starts a new frame, keeping the buffers the last one grew.
///
/// Texture registrations survive, because a glyph atlas outlives a frame and
/// re-registering it every frame would renumber it every frame.
pub fn reset(d: *DrawList, viewport: Bounds) void {
    d.instances.clearRetainingCapacity();
    d.viewport = viewport;
    d.clips[0] = viewport;
    d.clip_top = 0;
    d.xforms[0] = .identity;
    d.xform_top = 0;
    d.culled = 0;
    d.overflows = 0;
}

// -- stacks -----------------------------------------------------------------

pub fn clip(d: *const DrawList) Bounds {
    return d.clips[d.clip_top];
}

pub fn transform(d: *const DrawList) Xform {
    return d.xforms[d.xform_top];
}

/// Narrows the clip to `b`, expressed in the current transform's space.
///
/// Overflowing the stack re-pushes the current clip and counts it, rather than
/// failing or asserting. The call sites are `defer`-balanced, so refusing the
/// push would unbalance the pops and corrupt every clip after it; repeating
/// the top keeps the pairing intact and errs towards clipping more, which
/// leaves a visible missing rectangle instead of an invisible drawing outside
/// its scroll view. `overflows` is the honest report.
pub fn pushClip(d: *DrawList, b: Bounds) void {
    const device = d.transform().applyBounds(b);
    d.pushClipDevice(device);
}

/// `pushClip` for a rectangle already in device pixels, for callers that have
/// done their own mapping.
pub fn pushClipDevice(d: *DrawList, device: Bounds) void {
    const next = d.clips[d.clip_top].intersect(device);
    if (d.clip_top + 1 >= stack_depth) {
        d.overflows += 1;
        return;
    }
    d.clip_top += 1;
    d.clips[d.clip_top] = next;
}

pub fn popClip(d: *DrawList) void {
    if (d.clip_top > 0) d.clip_top -= 1;
}

/// Composes `x` inside the current transform, so nesting reads outermost
/// first, the way the call sites are written.
pub fn pushTransform(d: *DrawList, x: Xform) void {
    const next = x.then(d.xforms[d.xform_top]);
    if (d.xform_top + 1 >= stack_depth) {
        d.overflows += 1;
        return;
    }
    d.xform_top += 1;
    d.xforms[d.xform_top] = next;
}

pub fn popTransform(d: *DrawList) void {
    if (d.xform_top > 0) d.xform_top -= 1;
}

// -- textures ---------------------------------------------------------------

/// Registers a texture and returns its index in the array bound for the frame.
///
/// The size is kept so that source rectangles can be given in texels, which is
/// what a glyph atlas and an image tiler both produce; normalising is done
/// here so the shader never needs a texture size and the instance never
/// carries one.
pub fn registerTexture(d: *DrawList, width: u32, height: u32) Error!TextureId {
    try d.textures.append(d.gpa, .{ .width = width, .height = height });
    // Ids are one-based: zero means "no texture", so a `TextureId` is an
    // optional without a tag byte.
    return @intCast(d.textures.items.len);
}

/// Records that a registered texture is now a different size, keeping its id.
///
/// The counterpart to `Renderer.resizeTexture`: the two hold the same fact in
/// two places -- the device holds the image, this holds the size that turns a
/// texel rectangle into a normalised one -- and a caller that changes one and
/// not the other samples the right image through the wrong rectangle, which
/// looks like a page drawn at the wrong zoom rather than like a bug.
pub fn setTextureSize(d: *DrawList, id: TextureId, width: u32, height: u32) void {
    if (id == rect.no_texture or id > d.textures.items.len) return;
    d.textures.items[id - 1] = .{ .width = width, .height = height };
}

pub fn textureSize(d: *const DrawList, id: TextureId) ?Texture {
    if (id == rect.no_texture or id > d.textures.items.len) return null;
    return d.textures.items[id - 1];
}

// -- call sites -------------------------------------------------------------

/// The one that does the work. Every other call below is this with fields
/// filled in.
pub fn box(d: *DrawList, b: Bounds, style: Style) Error!void {
    const dst = d.transform().applyBounds(b);
    if (dst.isEmpty()) {
        d.culled += 1;
        return;
    }

    const x = d.transform();
    const r = Radius.clampTo(.{
        .tl = x.applyLength(style.radius.tl),
        .tr = x.applyLength(style.radius.tr),
        .br = x.applyLength(style.radius.br),
        .bl = x.applyLength(style.radius.bl),
    }, dst.width() * 0.5, dst.height() * 0.5);

    var colors: [4]rect.Rgba8 = undefined;
    if (style.corners) |c| {
        for (c, 0..) |col, i| colors[i] = rect.pack(col);
    } else {
        colors = @splat(rect.pack(style.color));
    }

    try d.push(.{
        .dst = .{ dst.min_x, dst.min_y, dst.max_x, dst.max_y },
        .clip = boundsToArray(d.clip()),
        .radius = r.asArray(),
        .color = colors,
        .border = x.applyLength(style.border),
        .softness = x.applyLength(style.softness),
    });
}

pub fn fill(d: *DrawList, b: Bounds, color: Color) Error!void {
    return d.box(b, .{ .color = color });
}

pub fn rounded(d: *DrawList, b: Bounds, radius: Radius, color: Color) Error!void {
    return d.box(b, .{ .color = color, .radius = radius });
}

pub fn border(d: *DrawList, b: Bounds, radius: Radius, thickness: f32, color: Color) Error!void {
    return d.box(b, .{ .color = color, .radius = radius, .border = thickness });
}

/// A drop shadow. `b` is the shadow's own rectangle, so a caller offsets it
/// themselves -- there is no implicit light direction here, because a UI that
/// wants one wants it applied consistently by its own theme code rather than
/// by the renderer.
pub fn shadow(d: *DrawList, b: Bounds, radius: Radius, blur: f32, color: Color) Error!void {
    return d.box(b, .{ .color = color, .radius = radius, .softness = blur });
}

pub fn gradient(d: *DrawList, b: Bounds, radius: Radius, corners: [4]Color) Error!void {
    return d.box(b, .{ .corners = corners, .radius = radius });
}

/// An image or an atlas region. `src` is in texels of `tex`.
pub fn image(d: *DrawList, b: Bounds, tex: TextureId, src: Bounds, tint: Color) Error!void {
    return d.textured(b, tex, src, tint, .{ .textured = true }, .none);
}

/// A glyph out of a coverage atlas: the texture modulates alpha only, so the
/// colour comes entirely from `color` and one atlas serves every colour of
/// text on the screen.
pub fn glyph(d: *DrawList, b: Bounds, tex: TextureId, src: Bounds, color: Color) Error!void {
    return d.textured(b, tex, src, color, .{ .textured = true, .alpha_texture = true }, .none);
}

fn textured(
    d: *DrawList,
    b: Bounds,
    tex: TextureId,
    src: Bounds,
    color: Color,
    flags: rect.Flags,
    radius: Radius,
) Error!void {
    const dst = d.transform().applyBounds(b);
    if (dst.isEmpty()) {
        d.culled += 1;
        return;
    }

    // An unregistered texture draws untextured rather than sampling whatever
    // happens to be in that slot. A missing atlas should look like a solid
    // block, which is obvious, and not like someone else's glyphs.
    const size = d.textureSize(tex) orelse {
        return d.box(b, .{ .color = color, .radius = radius });
    };
    const tw: f32 = @floatFromInt(size.width);
    const th: f32 = @floatFromInt(size.height);

    try d.push(.{
        .dst = .{ dst.min_x, dst.min_y, dst.max_x, dst.max_y },
        .src = .{ src.min_x / tw, src.min_y / th, src.max_x / tw, src.max_y / th },
        .clip = boundsToArray(d.clip()),
        .radius = radius.asArray(),
        .color = @splat(rect.pack(color)),
        .texture = tex,
        .flags = flags,
    });
}

/// The escape hatch: an instance already in device pixels, with its own clip.
/// Bypasses both stacks, which is the point -- it exists for code that has
/// already done the mapping, such as a replay of a recorded frame.
pub fn raw(d: *DrawList, i: Instance) Error!void {
    if (i.isInvisible()) {
        d.culled += 1;
        return;
    }
    try d.instances.append(d.gpa, i);
}

fn push(d: *DrawList, i: Instance) Error!void {
    if (i.isInvisible()) {
        d.culled += 1;
        return;
    }
    try d.instances.append(d.gpa, i);
}

fn boundsToArray(b: Bounds) [4]f32 {
    return .{ b.min_x, b.min_y, b.max_x, b.max_y };
}

// -- submission -------------------------------------------------------------

pub fn count(d: *const DrawList) u32 {
    return @intCast(d.instances.items.len);
}

/// The bytes to upload. One `memcpy` into a mapped host-visible buffer, then
/// `vkCmdDraw(cmd, 4, count, 0, 0)` with a triangle strip: no vertex buffer,
/// no index buffer, the quad's four corners generated from `gl_VertexIndex`
/// and the instance read from a storage buffer by `gl_InstanceIndex`.
pub fn bytes(d: *const DrawList) []const u8 {
    return std.mem.sliceAsBytes(d.instances.items);
}

/// The single batch, for a device that can index the texture array
/// non-uniformly -- which is the intended path, and the reason the clip is in
/// the instance.
pub fn wholeFrame(d: *const DrawList) Batch {
    return .{ .first = 0, .count = d.count(), .texture = rect.no_texture };
}

/// Splits the frame into runs of one texture, for a device without descriptor
/// indexing.
///
/// Worth having even when it is not used, because its length is a direct
/// measure of how well the caller ordered its drawing: text interleaved with
/// panels produces a run per glyph, and text drawn in a pass produces one run.
/// That number is a performance bug the fallback path would pay for and the
/// intended path would hide.
pub const RunIterator = struct {
    items: []const Instance,
    i: u32 = 0,

    pub fn next(it: *RunIterator) ?Batch {
        if (it.i >= it.items.len) return null;
        const first = it.i;
        const tex = it.items[first].texture;
        while (it.i < it.items.len and it.items[it.i].texture == tex) it.i += 1;
        return .{ .first = first, .count = it.i - first, .texture = tex };
    }
};

pub fn textureRuns(d: *const DrawList) RunIterator {
    return .{ .items = d.instances.items };
}

pub fn runCount(d: *const DrawList) u32 {
    var it = d.textureRuns();
    var n: u32 = 0;
    while (it.next()) |_| n += 1;
    return n;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn scratch() DrawList {
    return .init(testing.allocator, .fromRect(0, 0, 200, 100));
}

test "a fill lands in device pixels with the current clip attached" {
    var d = scratch();
    defer d.deinit();

    try d.fill(.fromRect(10, 20, 30, 40), .white);
    try testing.expectEqual(@as(u32, 1), d.count());

    const i = d.instances.items[0];
    try testing.expectEqual([4]f32{ 10, 20, 30, 40 }, i.dst);
    try testing.expectEqual([4]f32{ 0, 0, 200, 100 }, i.clip);
    try testing.expectEqual(rect.pack(.white), i.color[0]);
}

test "the transform stack composes outermost first" {
    var d = scratch();
    defer d.deinit();

    d.pushTransform(.translate(100, 0));
    defer d.popTransform();
    d.pushTransform(.scale(2));
    defer d.popTransform();

    // The inner scale applies first, then the outer translation.
    try d.fill(.fromRect(0, 0, 10, 10), .white);
    try testing.expectEqual([4]f32{ 100, 0, 120, 20 }, d.instances.items[0].dst);
}

test "popping restores what was there before" {
    var d = scratch();
    defer d.deinit();

    d.pushTransform(.translate(50, 50));
    d.pushClip(.fromRect(0, 0, 10, 10));
    try testing.expectEqual(Bounds.fromRect(50, 50, 60, 60), d.clip());
    d.popClip();
    d.popTransform();

    try testing.expectEqual(Bounds.fromRect(0, 0, 200, 100), d.clip());
    try testing.expectEqual(Xform.identity, d.transform());
}

test "clips are given in the current space and only ever narrow" {
    var d = scratch();
    defer d.deinit();

    d.pushTransform(.translate(20, 20));
    d.pushClip(.fromRect(0, 0, 1000, 1000));
    // Transformed to (20,20)-(1020,1020), then intersected with the viewport.
    try testing.expectEqual(Bounds.fromRect(20, 20, 200, 100), d.clip());
}

test "a negative scale keeps the rectangle the right way up" {
    var d = scratch();
    defer d.deinit();

    // The y flip that turns PDF space into screen space.
    d.pushTransform(.{ .sy = -1, .ty = 100 });
    try d.fill(.fromRect(0, 0, 10, 10), .white);
    try testing.expectEqual([4]f32{ 0, 90, 10, 100 }, d.instances.items[0].dst);
}

test "drawing entirely outside the clip is dropped, not queued" {
    var d = scratch();
    defer d.deinit();

    d.pushClip(.fromRect(0, 0, 50, 50));
    try d.fill(.fromRect(100, 100, 150, 150), .white);
    try testing.expectEqual(@as(u32, 0), d.count());
    try testing.expectEqual(@as(u32, 1), d.culled);

    // Straddling the edge is kept whole; the shader trims it.
    try d.fill(.fromRect(40, 40, 60, 60), .white);
    try testing.expectEqual(@as(u32, 1), d.count());
}

test "a scaled radius stays a circle and stays within the box" {
    var d = scratch();
    defer d.deinit();

    d.pushTransform(.{ .sx = 4, .sy = 1 });
    try d.rounded(.fromRect(0, 0, 10, 10), .all(5), .white);

    // 5 scaled by the smaller axis is 5, and half the shorter side of the
    // 40x10 result is also 5, so it survives the clamp exactly.
    try testing.expectEqual([4]f32{ 5, 5, 5, 5 }, d.instances.items[0].radius);
}

test "an oversized radius is clamped to the drawn size, not the asked size" {
    var d = scratch();
    defer d.deinit();

    try d.rounded(.fromRect(0, 0, 40, 10), .all(9999), .white);
    // A capsule: half the shorter side.
    try testing.expectEqual([4]f32{ 5, 5, 5, 5 }, d.instances.items[0].radius);
}

test "stack overflow keeps the pairing and is counted" {
    var d = scratch();
    defer d.deinit();

    var n: u32 = 0;
    while (n < stack_depth + 10) : (n += 1) d.pushClip(.fromRect(0, 0, 1000, 1000));
    try testing.expect(d.overflows > 0);
    try testing.expectEqual(@as(u32, stack_depth - 1), d.clip_top);

    // The same number of pops still returns to the outermost clip, which is
    // the property that stops one overflow corrupting the rest of the frame.
    n = 0;
    while (n < stack_depth + 10) : (n += 1) d.popClip();
    try testing.expectEqual(@as(u32, 0), d.clip_top);
    try testing.expectEqual(Bounds.fromRect(0, 0, 200, 100), d.clip());
}

test "source rectangles are normalised by the registered texture size" {
    var d = scratch();
    defer d.deinit();

    const atlas = try d.registerTexture(256, 128);
    try testing.expectEqual(@as(TextureId, 1), atlas);

    try d.glyph(.fromRect(0, 0, 8, 16), atlas, .fromRect(64, 32, 72, 48), .black);
    const i = d.instances.items[0];
    try testing.expectEqual([4]f32{ 0.25, 0.25, 0.28125, 0.375 }, i.src);
    try testing.expect(i.flags.textured and i.flags.alpha_texture);
}

test "an unregistered texture draws as a solid block" {
    var d = scratch();
    defer d.deinit();

    try d.image(.fromRect(0, 0, 8, 8), 7, .fromRect(0, 0, 8, 8), .white);
    const i = d.instances.items[0];
    try testing.expect(!i.flags.textured);
    try testing.expectEqual(rect.no_texture, i.texture);
}

test "a frame is one batch, and the run count says what it would cost without one" {
    var d = scratch();
    defer d.deinit();

    const atlas = try d.registerTexture(64, 64);
    try d.fill(.fromRect(0, 0, 10, 10), .white);
    try d.glyph(.fromRect(0, 0, 8, 8), atlas, .fromRect(0, 0, 8, 8), .black);
    try d.glyph(.fromRect(8, 0, 16, 8), atlas, .fromRect(0, 0, 8, 8), .black);
    try d.fill(.fromRect(20, 0, 30, 10), .white);

    try testing.expectEqual(Batch{ .first = 0, .count = 4, .texture = rect.no_texture }, d.wholeFrame());
    // Panel, two glyphs, panel: three runs, because the drawing interleaved.
    try testing.expectEqual(@as(u32, 3), d.runCount());

    var it = d.textureRuns();
    try testing.expectEqual(Batch{ .first = 0, .count = 1, .texture = 0 }, it.next().?);
    try testing.expectEqual(Batch{ .first = 1, .count = 2, .texture = atlas }, it.next().?);
    try testing.expectEqual(Batch{ .first = 3, .count = 1, .texture = 0 }, it.next().?);
    try testing.expectEqual(@as(?Batch, null), it.next());
}

test "the upload is the instance array with nothing around it" {
    var d = scratch();
    defer d.deinit();

    try d.fill(.fromRect(0, 0, 10, 10), .white);
    try d.fill(.fromRect(0, 0, 20, 20), .black);
    try testing.expectEqual(@as(usize, 2 * 96), d.bytes().len);
}

test "reset keeps the textures and the capacity but not the frame" {
    var d = scratch();
    defer d.deinit();

    const atlas = try d.registerTexture(64, 64);
    try d.fill(.fromRect(0, 0, 10, 10), .white);
    const capacity = d.instances.capacity;

    d.reset(.fromRect(0, 0, 400, 300));
    try testing.expectEqual(@as(u32, 0), d.count());
    try testing.expectEqual(capacity, d.instances.capacity);
    try testing.expect(d.textureSize(atlas) != null);
    try testing.expectEqual(Bounds.fromRect(0, 0, 400, 300), d.clip());
}

test "a rotation cannot become an instance and says so" {
    try testing.expectEqual(@as(?Xform, null), Xform.fromTransform(.rotation(0.3)));
    // A quarter turn maps rectangles to rectangles but moves the corners, so
    // it is refused too rather than drawn with the radii in the wrong places.
    try testing.expectEqual(@as(?Xform, null), Xform.fromTransform(.rotation(std.math.pi / 2.0)));

    const x = Xform.fromTransform(.{ .a = 2, .d = 3, .e = 10, .f = 20 }).?;
    try testing.expectEqual(Xform{ .sx = 2, .sy = 3, .tx = 10, .ty = 20 }, x);
}

test "Xform composition matches gelgja's, in the same order" {
    const inner: Xform = .{ .sx = 2, .sy = 2, .tx = 5, .ty = 5 };
    const outer: Xform = .{ .sx = 3, .sy = 3, .tx = 1, .ty = 1 };

    const p: Point = .{ .x = 7, .y = 11 };
    const stepwise = outer.applyPoint(inner.applyPoint(p));
    const composed = inner.then(outer).applyPoint(p);
    try testing.expectApproxEqAbs(stepwise.x, composed.x, 1e-5);
    try testing.expectApproxEqAbs(stepwise.y, composed.y, 1e-5);

    const g_inner: Transform = .{ .a = 2, .d = 2, .e = 5, .f = 5 };
    const g_outer: Transform = .{ .a = 3, .d = 3, .e = 1, .f = 1 };
    const g = g_inner.concat(g_outer).apply(p);
    try testing.expectApproxEqAbs(g.x, composed.x, 1e-5);
    try testing.expectApproxEqAbs(g.y, composed.y, 1e-5);
}
