//! A display list, prepared for the analytic path pipeline: outlines, the
//! instances that place them, and the clip stack they hang off.
//!
//! This is what `replay.zig` produces when it is asked to record rather than
//! to rasterise. The same walk, the same transforms, the same clip
//! discipline, the same glyph source -- and at the end, instead of pixels, six
//! flat arrays that go to the device as storage buffers.
//!
//! Sharing the walk is the point. A second traversal of the display list
//! would be a second set of decisions about what a `clip_push` means and how
//! a stroke's outline is built, and the two would drift; a page would render
//! one way on the CPU and another on the GPU, and the difference would be in
//! the traversal rather than in the rasteriser, which is the one place a
//! difference is useless. One walk, two sinks.
//!
//! ## What a clip is here
//!
//! A linked list, not a stack copied per instance. `clip_top` is the
//! innermost open clip and each node points at the one enclosing it, so a
//! thousand paths drawn inside the same two clips carry four bytes of clip
//! state each and the fragment shader walks two nodes. `popClip` restores the
//! previous top; the nodes themselves are never removed, because an instance
//! recorded earlier still refers to them.
//!
//! ## Blend modes
//!
//! Each instance carries a `slugpipe.Composite`, and the device draws a run
//! of instances with the same one through the pipeline for it. That covers
//! normal, multiply, screen, darken and lighten -- which is what highlighter
//! annotations and nearly every real document use. The other eleven modes
//! need the backdrop read in the shader, which a single-pass pipeline cannot
//! do; they are drawn normally and counted in `Stats.blended`, so a page with
//! them on it does not look finished when it is not.
//!
//! ## Images
//!
//! Recorded the way outlines are: the pixels are appended to one flat texel
//! array, each image gets an `ImageInfo` saying where its texels start, and
//! an instance names it. Merging renumbers both, and the device gets them as
//! two more storage buffers. Pixels are resampled on the way in to no more
//! than `max_image_scale` texels per recorded pixel of the image's placement,
//! because a scanned figure is often thousands of pixels printed an inch
//! wide, and the device should hold what the page can show rather than what
//! the file happened to contain.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("../gelgja/geom.zig");
const paint = @import("../gelgja/paint.zig");
const slug = @import("slug.zig");
const slugpipe = @import("slugpipe.zig");

const Bounds = geom.Bounds;
const Color = paint.Color;
const FillRule = geom.FillRule;
const Transform = geom.Transform;

/// What names one glyph outline: which font, and both the ways a display list
/// says which glyph. See `Scene.glyphHeader`.
pub const GlyphKey = struct {
    font: u32,
    code: u32,
    id: u32,
};

pub const Scene = struct {
    /// The outlines: curves, bands, band indices, headers. Uploaded verbatim.
    store: slug.Store = .{},
    /// One per drawn path.
    instances: std.ArrayList(slugpipe.Instance) = .empty,
    /// The clip nodes every instance's `clip_node` points into.
    clips: std.ArrayList(slugpipe.ClipNode) = .empty,

    /// The innermost open clip, or `no_clip`.
    clip_top: u32 = slugpipe.no_clip,
    /// One entry per open clip: what `clip_top` was before it, and the device
    /// box in force. Restored by `popClip`.
    clip_stack: std.ArrayList(SavedClip) = .empty,
    /// The device-space box of every open clip, intersected. Instances are
    /// scissored to it so the quad never covers fragments the clip would
    /// discard anyway.
    clip_box: [4]f32 = .{ 0, 0, 0, 0 },

    /// Where each image's texels are. See the module comment.
    images: std.ArrayList(slugpipe.ImageInfo) = .empty,
    texels: std.ArrayList(u32) = .empty,
    /// Images already recorded in this scene, by the address of the pixels
    /// they came from, so a logo drawn forty times is stored once. Only
    /// meaningful while recording: a merged scene's images came from pixels
    /// that may since have been freed, and `merge` does not carry it.
    image_seen: std.AutoHashMapUnmanaged(ImageKey, u32) = .empty,
    /// Glyph outlines already in the store, by font and glyph id. Recording
    /// only; `merge` does not carry it, because the headers it names are
    /// renumbered on the way in and the next page will ask for its own.
    glyphs: std.AutoHashMapUnmanaged(GlyphKey, u32) = .empty,

    /// The framebuffer, which is the widest any scissor can be.
    viewport: [2]f32 = .{ 1, 1 },

    /// Bumped whenever the store changes.
    ///
    /// The outlines are the expensive half -- a page of text is a hundred
    /// thousand curves, several megabytes -- and they change only when a page
    /// comes into view. The placement changes every frame you scroll. So the
    /// device is told which is which, and a scroll uploads kilobytes instead
    /// of megabytes.
    generation: u32 = 0,

    stats: Stats = .{},

    const SavedClip = struct { top: u32, box: [4]f32 };
    const ImageKey = struct { ptr: usize, width: u32, height: u32 };

    pub const Stats = struct {
        paths: u32 = 0,
        clips: u32 = 0,
        images: u32 = 0,
        /// Clips nested deeper than the shader will walk. What is drawn shows
        /// too much rather than too little, which is the safe direction but
        /// is still wrong.
        clips_too_deep: u32 = 0,
        /// Instances whose blend mode has no pipeline, and so were drawn
        /// `normal`. See the module comment.
        blended: u32 = 0,
        /// Images left out because the scene's texel budget was spent.
        images_dropped: u32 = 0,
        /// Paths with no curves after conversion: an empty subpath, or a
        /// degenerate one.
        empty: u32 = 0,
        /// Glyph outlines recorded. A page of text draws thousands of glyphs
        /// and records a few hundred outlines; the ratio is what the store
        /// costs instead of what it would have.
        glyph_outlines: u32 = 0,
    };


    pub fn deinit(s: *Scene, gpa: Allocator) void {
        s.store.deinit(gpa);
        s.instances.deinit(gpa);
        s.clips.deinit(gpa);
        s.clip_stack.deinit(gpa);
        s.images.deinit(gpa);
        s.texels.deinit(gpa);
        s.image_seen.deinit(gpa);
        s.glyphs.deinit(gpa);
        s.* = .{};
    }

    /// Bytes to upload for the two image bindings.
    pub fn imageBytes(s: Scene) []const u8 {
        return std.mem.sliceAsBytes(s.images.items);
    }

    pub fn texelBytes(s: Scene) []const u8 {
        return std.mem.sliceAsBytes(s.texels.items);
    }

    /// Empties everything but the capacity, for the next page.
    pub fn reset(s: *Scene, viewport: [2]f32) void {
        s.store.reset();
        s.instances.clearRetainingCapacity();
        s.clips.clearRetainingCapacity();
        s.clip_stack.clearRetainingCapacity();
        s.images.clearRetainingCapacity();
        s.texels.clearRetainingCapacity();
        s.image_seen.clearRetainingCapacity();
        s.glyphs.clearRetainingCapacity();
        s.clip_top = slugpipe.no_clip;
        s.viewport = viewport;
        s.clip_box = .{ 0, 0, viewport[0], viewport[1] };
        s.stats = .{};
        s.generation +%= 1;
    }

    pub fn isEmpty(s: Scene) bool {
        return s.instances.items.len == 0;
    }

    pub fn instanceCount(s: Scene) u32 {
        return @intCast(s.instances.items.len);
    }

    /// Records one filled outline.
    pub fn draw(
        s: *Scene,
        gpa: Allocator,
        curves: []const slug.Curve,
        rule: FillRule,
        xform: Transform,
        color: Color,
        alpha: f32,
        blend: paint.BlendMode,
    ) Allocator.Error!void {
        if (curves.len == 0) {
            s.stats.empty += 1;
            return;
        }

        const header = try s.store.add(gpa, curves, rule);
        try s.drawHeader(gpa, header, xform, color, alpha, blend);
    }

    /// Draws an outline already in the store: one instance, no curves.
    ///
    /// This is what makes a page of text cheap. A glyph is recorded once, in
    /// em units, and every place it appears is eighty bytes naming it and the
    /// matrix that puts it there -- which is the property the whole design is
    /// spent on, applied to the thing a page has thousands of.
    pub fn drawHeader(
        s: *Scene,
        gpa: Allocator,
        header: u32,
        xform: Transform,
        color: Color,
        alpha: f32,
        blend: paint.BlendMode,
    ) Allocator.Error!void {
        var it: slugpipe.Instance = .init(header, xform, s.clip_box, color, alpha, s.compositeOf(blend));
        it.clip_node = s.clip_top;
        try s.instances.append(gpa, it);
        s.stats.paths += 1;
    }

    /// The outline recorded for one glyph, if it has been seen.
    ///
    /// Not keyed by size: the outline is in em units, so the size is the
    /// instance's matrix. Keyed by the character code *and* the glyph id
    /// because a display list may carry either -- a simple font's glyph index
    /// is often left unresolved for the font layer to work out from the code,
    /// and keying on the id alone then names every glyph in the font the
    /// same. It draws a page of one repeated letter, which is how this was
    /// found.
    pub fn glyphHeader(s: *const Scene, key: GlyphKey) ?u32 {
        return s.glyphs.get(key);
    }

    /// Records a glyph's outline and remembers it under `key`.
    pub fn addGlyph(
        s: *Scene,
        gpa: Allocator,
        key: GlyphKey,
        curves: []const slug.Curve,
    ) Allocator.Error!u32 {
        const header = try s.store.add(gpa, curves, .nonzero);
        try s.glyphs.put(gpa, key, header);
        s.stats.glyph_outlines += 1;
        return header;
    }

    fn compositeOf(s: *Scene, blend: paint.BlendMode) slugpipe.Composite {
        return slugpipe.Composite.of(blend) orelse {
            s.stats.blended += 1;
            return .normal;
        };
    }

    /// What `drawImage` is given: straight RGBA, eight bits a channel.
    pub const Bitmap = struct {
        pixels: []const u8,
        width: u32,
        height: u32,
        /// The alpha is a stencil and the colour is `color`.
        is_mask: bool = false,
    };

    /// Records one image, placed by `xform` over the unit square.
    pub fn drawImage(
        s: *Scene,
        gpa: Allocator,
        bitmap: Bitmap,
        xform: Transform,
        color: Color,
        alpha: f32,
        blend: paint.BlendMode,
    ) Allocator.Error!void {
        if (bitmap.width == 0 or bitmap.height == 0) return;
        if (bitmap.pixels.len < @as(usize, bitmap.width) * bitmap.height * 4) return;
        s.stats.images += 1;

        const key: ImageKey = .{
            .ptr = @intFromPtr(bitmap.pixels.ptr),
            .width = bitmap.width,
            .height = bitmap.height,
        };
        const index = s.image_seen.get(key) orelse blk: {
            const size = storedSize(bitmap.width, bitmap.height, xform);
            const count = @as(usize, size[0]) * size[1];
            if (s.texels.items.len + count > max_texels) {
                s.stats.images_dropped += 1;
                return;
            }
            const offset: u32 = @intCast(s.texels.items.len);
            try s.texels.resize(gpa, s.texels.items.len + count);
            resample(bitmap, s.texels.items[offset..], size[0], size[1]);

            const id: u32 = @intCast(s.images.items.len);
            try s.images.append(gpa, .{ .offset = offset, .width = size[0], .height = size[1] });
            try s.image_seen.put(gpa, key, id);
            break :blk id;
        };

        var it: slugpipe.Instance = .initImage(
            index,
            bitmap.is_mask,
            xform,
            s.clip_box,
            color,
            alpha,
            s.compositeOf(blend),
        );
        it.clip_node = s.clip_top;
        try s.instances.append(gpa, it);
    }

    /// Opens a clip. The path's own curves, placed by `xform`, intersected
    /// with whatever is already in force.
    pub fn pushClip(
        s: *Scene,
        gpa: Allocator,
        curves: []const slug.Curve,
        rule: FillRule,
        xform: Transform,
    ) Allocator.Error!void {
        s.stats.clips += 1;
        try s.clip_stack.append(gpa, .{ .top = s.clip_top, .box = s.clip_box });

        if (curves.len == 0) {
            // A degenerate clip path hides everything until its pop, which is
            // not the same as no clip at all. An empty scissor says so with
            // no node and no fragments.
            s.clip_box = .{ 0, 0, 0, 0 };
            return;
        }

        const header = try s.store.add(gpa, curves, rule);
        const node: u32 = @intCast(s.clips.items.len);
        try s.clips.append(gpa, .{
            .xform = .{ xform.a, xform.b, xform.c, xform.d },
            .translate = .{ xform.e, xform.f },
            .header = header,
            .parent = s.clip_top,
        });
        s.clip_top = node;

        // The device box of this clip path, intersected into the scissor. The
        // fragment shader would reach the same answer, one fragment at a
        // time; this is the cheap conservative half of it.
        const box = s.store.headers.items[header].bounds();
        s.clip_box = intersect(s.clip_box, deviceBox(box, xform));

        if (s.depth() > slugpipe.max_clip_walk) s.stats.clips_too_deep += 1;
    }

    pub fn popClip(s: *Scene) void {
        const saved = s.clip_stack.pop() orelse return;
        s.clip_top = saved.top;
        s.clip_box = saved.box;
    }

    fn depth(s: Scene) u32 {
        var n: u32 = 0;
        var node = s.clip_top;
        while (node != slugpipe.no_clip and n < 1024) : (n += 1) {
            node = s.clips.items[node].parent;
        }
        return n;
    }

    /// Where one recording ends up in a shared scene.
    ///
    /// A reader records several pages into one `Scene`, so that they share a
    /// store and go to the device as one set of buffers. This is the span a
    /// given page occupies, and what `Frame.place` needs to copy it.
    pub const Range = struct {
        first_instance: u32 = 0,
        instance_count: u32 = 0,
        first_clip: u32 = 0,
        clip_count: u32 = 0,
    };

    /// Appends a scene recorded elsewhere, renumbering its headers and its
    /// clip chain, and returns the range it landed in.
    ///
    /// This is how a page recorded on the rasterising thread joins the shared
    /// store the device reads. Everything that was an index in `src` becomes
    /// an index here: headers through `Store.merge`, clip nodes through their
    /// own base, and both of those appear in two places each -- an instance's
    /// `header` and `clip_node`, and a node's `header` and `parent`.
    pub fn merge(s: *Scene, gpa: Allocator, src: Scene) Allocator.Error!Range {
        const start = s.rangeStart();
        const header_base = try s.store.merge(gpa, src.store);
        const clip_base: u32 = @intCast(s.clips.items.len);

        try s.clips.ensureUnusedCapacity(gpa, src.clips.items.len);
        for (src.clips.items) |node| {
            var out = node;
            out.header += header_base;
            if (out.parent != slugpipe.no_clip) out.parent += clip_base;
            s.clips.appendAssumeCapacity(out);
        }

        const image_base: u32 = @intCast(s.images.items.len);
        const texel_base: u32 = @intCast(s.texels.items.len);
        try s.texels.appendSlice(gpa, src.texels.items);
        try s.images.ensureUnusedCapacity(gpa, src.images.items.len);
        for (src.images.items) |info| {
            var out = info;
            out.offset += texel_base;
            s.images.appendAssumeCapacity(out);
        }

        try s.instances.ensureUnusedCapacity(gpa, src.instances.items.len);
        for (src.instances.items) |it| {
            var out = it;
            if (out.flags & slugpipe.flag.image != 0) {
                out.image += image_base;
            } else {
                out.header += header_base;
            }
            if (out.clip_node != slugpipe.no_clip) out.clip_node += clip_base;
            s.instances.appendAssumeCapacity(out);
        }

        s.stats.paths += src.stats.paths;
        s.stats.clips += src.stats.clips;
        s.stats.images += src.stats.images;
        s.stats.clips_too_deep += src.stats.clips_too_deep;
        s.stats.blended += src.stats.blended;
        s.stats.images_dropped += src.stats.images_dropped;
        s.stats.empty += src.stats.empty;
        s.stats.glyph_outlines += src.stats.glyph_outlines;
        s.generation +%= 1;
        return s.rangeEnd(start);
    }

    /// The range a recording will start at. Take this before recording and
    /// `rangeEnd` after.
    pub fn rangeStart(s: Scene) Range {
        return .{
            .first_instance = @intCast(s.instances.items.len),
            .first_clip = @intCast(s.clips.items.len),
        };
    }

    pub fn rangeEnd(s: Scene, start: Range) Range {
        return .{
            .first_instance = start.first_instance,
            .instance_count = @as(u32, @intCast(s.instances.items.len)) - start.first_instance,
            .first_clip = start.first_clip,
            .clip_count = @as(u32, @intCast(s.clips.items.len)) - start.first_clip,
        };
    }
};

/// One frame's worth of placement: the instances and clips actually drawn,
/// composed from recordings in a `Scene`.
///
/// This is the half of the pipeline that changes when you scroll. The
/// outlines -- curves, bands, headers, the megabytes -- were recorded once in
/// page space and do not move; what moves is a matrix per instance. So a
/// scroll rewrites a few hundred kilobytes of instances and leaves everything
/// else on the device untouched, and a zoom does the same, at any zoom, with
/// no re-tessellation and no re-upload.
///
/// That property is the reason the curves go to the device as curves. It is
/// worth restating because it is what the whole design is spent on.
pub const Frame = struct {
    instances: std.ArrayList(slugpipe.Instance) = .empty,
    clips: std.ArrayList(slugpipe.ClipNode) = .empty,
    /// Bumped by `reset`, so a frame that did not move is not sent again. A
    /// reader sitting still uploads nothing at all.
    generation: u32 = 0,

    pub fn deinit(f: *Frame, gpa: Allocator) void {
        f.instances.deinit(gpa);
        f.clips.deinit(gpa);
        f.* = .{};
    }

    pub fn reset(f: *Frame) void {
        f.instances.clearRetainingCapacity();
        f.clips.clearRetainingCapacity();
        f.generation +%= 1;
    }

    pub fn isEmpty(f: Frame) bool {
        return f.instances.items.len == 0;
    }

    pub fn instanceCount(f: Frame) u32 {
        return @intCast(f.instances.items.len);
    }

    /// Copies a recorded range into this frame, composing `xform` onto every
    /// transform in it and clamping every scissor to `box`.
    ///
    /// The clip chain is renumbered on the way: a page's nodes were indexed
    /// within the recording and land somewhere else here, so both the
    /// instances' `clip_node` and the nodes' own `parent` are shifted. A page
    /// whose clips referred to another page's would be a silent disaster, and
    /// the reason it cannot happen is that a clip is always pushed and popped
    /// within one recording.
    pub fn place(
        f: *Frame,
        gpa: Allocator,
        s: Scene,
        range: Scene.Range,
        xform: Transform,
        box: [4]f32,
    ) Allocator.Error!void {
        if (range.instance_count == 0) return;

        const clip_base: u32 = @intCast(f.clips.items.len);
        const src_clips = s.clips.items[range.first_clip..][0..range.clip_count];
        try f.clips.ensureUnusedCapacity(gpa, src_clips.len);
        for (src_clips) |node| {
            const placed = compose(node.xform, node.translate, xform);
            f.clips.appendAssumeCapacity(.{
                .xform = placed.xform,
                .translate = placed.translate,
                .header = node.header,
                .parent = shift(node.parent, range.first_clip, clip_base),
            });
        }

        const src = s.instances.items[range.first_instance..][0..range.instance_count];
        try f.instances.ensureUnusedCapacity(gpa, src.len);
        for (src) |it| {
            var out = it;
            const placed = compose(it.xform, it.translate, xform);
            out.xform = placed.xform;
            out.translate = placed.translate;
            out.clip = intersect(placeBox(it.clip, xform), box);
            out.clip_node = shift(it.clip_node, range.first_clip, clip_base);
            f.instances.appendAssumeCapacity(out);
        }
    }
};

/// Texels kept per pixel of an image's recorded placement, in each direction.
///
/// A page is recorded at one device pixel per point, and a reader zooms it.
/// Four is enough to stay sharp to 400%, and an image is never stored larger
/// than the file gave it.
pub const max_image_scale: f32 = 4;

/// The longest side an image is stored at, whatever its placement.
pub const max_image_side: u32 = 4096;

/// The most texels one scene holds: 128 MiB, which is the smallest storage
/// buffer range Vulkan promises every device supports.
pub const max_texels: usize = (128 << 20) / 4;

/// How big an image is stored: its own size, or what `xform` shows of it at
/// `max_image_scale`, whichever is smaller.
fn storedSize(width: u32, height: u32, xform: Transform) [2]u32 {
    // The unit square's sides through the matrix: how many recorded pixels
    // the image's width and height span on the page.
    const across = @sqrt(xform.a * xform.a + xform.b * xform.b) * max_image_scale;
    const down = @sqrt(xform.c * xform.c + xform.d * xform.d) * max_image_scale;
    return .{ fit(width, across), fit(height, down) };
}

fn fit(have: u32, want: f32) u32 {
    const limit = @min(have, max_image_side);
    if (!(want >= 1)) return 1;
    if (want >= @as(f32, @floatFromInt(limit))) return limit;
    return @max(1, @as(u32, @intFromFloat(@ceil(want))));
}

/// A box filter from `bitmap` into `out`, `w` by `h`, packed as texels.
///
/// Averaged premultiplied and stored straight, the same as the CPU sampler
/// averages, so a transparent texel does not drag its colour into its
/// neighbours'. At the source's own size it is a copy.
fn resample(bitmap: Scene.Bitmap, out: []u32, w: u32, h: u32) void {
    const sw = bitmap.width;
    const sh = bitmap.height;
    const px = bitmap.pixels;

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const y0 = @as(u64, y) * sh / h;
        const y1 = @max(y0 + 1, (@as(u64, y) + 1) * sh / h);
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const x0 = @as(u64, x) * sw / w;
            const x1 = @max(x0 + 1, (@as(u64, x) + 1) * sw / w);

            var acc: [4]u64 = @splat(0);
            var n: u64 = 0;
            var sy = y0;
            while (sy < y1) : (sy += 1) {
                var sx = x0;
                while (sx < x1) : (sx += 1) {
                    const at = (sy * sw + sx) * 4;
                    const a: u64 = px[at + 3];
                    acc[0] += @as(u64, px[at]) * a;
                    acc[1] += @as(u64, px[at + 1]) * a;
                    acc[2] += @as(u64, px[at + 2]) * a;
                    acc[3] += a;
                    n += 1;
                }
            }
            const alpha = acc[3];
            const texel = if (alpha == 0)
                slugpipe.packTexel(0, 0, 0, 0)
            else
                slugpipe.packTexel(
                    @intCast(@min(255, (acc[0] + alpha / 2) / alpha)),
                    @intCast(@min(255, (acc[1] + alpha / 2) / alpha)),
                    @intCast(@min(255, (acc[2] + alpha / 2) / alpha)),
                    @intCast(@min(255, (alpha + n / 2) / n)),
                );
            out[@as(usize, y) * w + x] = texel;
        }
    }
}

/// Renumbers a clip index from a recording's numbering into a frame's, and
/// leaves `no_clip` alone.
fn shift(node: u32, from: u32, to: u32) u32 {
    if (node == slugpipe.no_clip) return node;
    return node - from + to;
}

const Placed = struct { xform: [4]f32, translate: [2]f32 };

/// The recorded matrix followed by the frame's, in that order: a point goes
/// through the page's own placement first and then onto the screen.
fn compose(m: [4]f32, t: [2]f32, outer: Transform) Placed {
    const inner: Transform = .{ .a = m[0], .b = m[1], .c = m[2], .d = m[3], .e = t[0], .f = t[1] };
    const c = inner.concat(outer);
    return .{ .xform = .{ c.a, c.b, c.c, c.d }, .translate = .{ c.e, c.f } };
}

/// A recorded scissor through the frame's transform. The recorded box was in
/// the recording's device space, which the placement moves.
fn placeBox(b: [4]f32, t: Transform) [4]f32 {
    var out: Bounds = .empty;
    for ([4][2]f32{ .{ b[0], b[1] }, .{ b[2], b[1] }, .{ b[2], b[3] }, .{ b[0], b[3] } }) |c| {
        out = out.add(t.apply(.{ .x = c[0], .y = c[1] }));
    }
    return .{ out.min_x, out.min_y, out.max_x, out.max_y };
}

/// A path-space box through a transform, as a device-space scissor.
fn deviceBox(b: Bounds, t: Transform) [4]f32 {
    if (b.isEmpty()) return .{ 0, 0, 0, 0 };
    var out: Bounds = .empty;
    for ([4][2]f32{
        .{ b.min_x, b.min_y }, .{ b.max_x, b.min_y },
        .{ b.max_x, b.max_y }, .{ b.min_x, b.max_y },
    }) |c| {
        out = out.add(t.apply(.{ .x = c[0], .y = c[1] }));
    }
    // A pixel of margin, the same one the vertex shader adds: coverage comes
    // from the pixel's whole area, so a pixel whose centre is outside the
    // outline can still be partly inside it.
    return .{ out.min_x - 1, out.min_y - 1, out.max_x + 1, out.max_y + 1 };
}

fn intersect(a: [4]f32, b: [4]f32) [4]f32 {
    const x0 = @max(a[0], b[0]);
    const y0 = @max(a[1], b[1]);
    return .{ x0, y0, @max(x0, @min(a[2], b[2])), @max(y0, @min(a[3], b[3])) };
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn square(gpa: Allocator, out: *std.ArrayList(slug.Curve), x0: f32, y0: f32, x1: f32, y1: f32) !void {
    const pts = [_][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        try out.append(gpa, .{
            .x0 = p[0],
            .y0 = p[1],
            .x1 = (p[0] + q[0]) * 0.5,
            .y1 = (p[1] + q[1]) * 0.5,
            .x2 = q[0],
            .y2 = q[1],
        });
    }
}

test "clips nest as a chain and a pop restores the one outside it" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    defer s.deinit(gpa);
    s.reset(.{ 500, 500 });

    var curves: std.ArrayList(slug.Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 0, 0, 100, 100);

    try testing.expectEqual(slugpipe.no_clip, s.clip_top);

    try s.pushClip(gpa, curves.items, .nonzero, .identity);
    const outer = s.clip_top;
    try testing.expect(outer != slugpipe.no_clip);
    try testing.expectEqual(slugpipe.no_clip, s.clips.items[outer].parent);

    curves.clearRetainingCapacity();
    try square(gpa, &curves, 20, 20, 60, 60);
    try s.pushClip(gpa, curves.items, .nonzero, .identity);
    const inner = s.clip_top;
    try testing.expect(inner != outer);
    // The chain points outwards, which is the direction the shader walks.
    try testing.expectEqual(outer, s.clips.items[inner].parent);

    s.popClip();
    try testing.expectEqual(outer, s.clip_top);
    s.popClip();
    try testing.expectEqual(slugpipe.no_clip, s.clip_top);
}

test "an instance carries the clip that was open when it was recorded" {
    // The thing a stack-of-nodes gets right and a single current-clip field
    // gets wrong: a path drawn inside a clip has to keep referring to that
    // clip after the clip is popped, because the instance is drawn later.
    const gpa = testing.allocator;
    var s: Scene = .{};
    defer s.deinit(gpa);
    s.reset(.{ 500, 500 });

    var curves: std.ArrayList(slug.Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 0, 0, 100, 100);

    try s.draw(gpa, curves.items, .nonzero, .identity, .black, 1.0, .normal);
    try s.pushClip(gpa, curves.items, .nonzero, .identity);
    const under = s.clip_top;
    try s.draw(gpa, curves.items, .nonzero, .identity, .black, 1.0, .normal);
    s.popClip();
    try s.draw(gpa, curves.items, .nonzero, .identity, .black, 1.0, .normal);

    try testing.expectEqual(@as(usize, 3), s.instances.items.len);
    try testing.expectEqual(slugpipe.no_clip, s.instances.items[0].clip_node);
    try testing.expectEqual(under, s.instances.items[1].clip_node);
    try testing.expectEqual(slugpipe.no_clip, s.instances.items[2].clip_node);
}

test "the scissor shrinks with the clip and never grows past the viewport" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    defer s.deinit(gpa);
    s.reset(.{ 500, 400 });
    try testing.expectEqual([4]f32{ 0, 0, 500, 400 }, s.clip_box);

    var curves: std.ArrayList(slug.Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 100, 100, 200, 200);
    try s.pushClip(gpa, curves.items, .nonzero, .identity);

    // The clip's own box, with the one-pixel coverage margin.
    try testing.expectEqual([4]f32{ 99, 99, 201, 201 }, s.clip_box);

    // A second clip reaching outside the first cannot widen it.
    curves.clearRetainingCapacity();
    try square(gpa, &curves, 0, 150, 500, 160);
    try s.pushClip(gpa, curves.items, .nonzero, .identity);
    try testing.expectEqual(@as(f32, 99), s.clip_box[0]);
    try testing.expectEqual(@as(f32, 201), s.clip_box[2]);
    try testing.expectEqual(@as(f32, 149), s.clip_box[1]);
    try testing.expectEqual(@as(f32, 161), s.clip_box[3]);

    s.popClip();
    try testing.expectEqual([4]f32{ 99, 99, 201, 201 }, s.clip_box);
}

test "a clip path with nothing in it hides everything until its pop" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    defer s.deinit(gpa);
    s.reset(.{ 500, 400 });

    try s.pushClip(gpa, &.{}, .nonzero, .identity);
    try testing.expectEqual([4]f32{ 0, 0, 0, 0 }, s.clip_box);
    s.popClip();
    try testing.expectEqual([4]f32{ 0, 0, 500, 400 }, s.clip_box);
}

test "a reset keeps the capacity and forgets the page" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    defer s.deinit(gpa);
    s.reset(.{ 100, 100 });

    var curves: std.ArrayList(slug.Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 0, 0, 10, 10);
    try s.draw(gpa, curves.items, .nonzero, .identity, .black, 1.0, .normal);
    try testing.expectEqual(@as(u32, 1), s.stats.paths);

    s.reset(.{ 100, 100 });
    try testing.expect(s.isEmpty());
    try testing.expectEqual(@as(u32, 0), s.stats.paths);
    try testing.expectEqual(@as(usize, 0), s.store.curves.items.len);
    // The arrays kept their allocation, which is what makes a page cost no
    // allocations after the first.
    try testing.expect(s.instances.capacity > 0);
}

test "a blend mode with a pipeline is carried, and one without is counted" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    defer s.deinit(gpa);
    s.reset(.{ 100, 100 });

    var curves: std.ArrayList(slug.Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 0, 0, 10, 10);

    try s.draw(gpa, curves.items, .nonzero, .identity, .black, 1.0, .normal);
    try s.draw(gpa, curves.items, .nonzero, .identity, .black, 1.0, .multiply);
    try testing.expectEqual(@as(u32, 0), s.stats.blended);
    try testing.expectEqual(slugpipe.Composite.multiply, s.instances.items[1].compositeOf());

    try s.draw(gpa, curves.items, .nonzero, .identity, .black, 1.0, .color_dodge);
    try testing.expectEqual(@as(u32, 1), s.stats.blended);
    try testing.expectEqual(slugpipe.Composite.normal, s.instances.items[2].compositeOf());
}

test "an image is stored once however often it is drawn, and no larger than it shows" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    defer s.deinit(gpa);
    s.reset(.{ 1000, 1000 });

    // 64 by 64, drawn over ten recorded pixels: stored at forty.
    var pixels: [64 * 64 * 4]u8 = undefined;
    for (0..64 * 64) |i| {
        pixels[i * 4 ..][0..4].* = .{ 255, 0, 0, 255 };
    }
    const bmp: Scene.Bitmap = .{ .pixels = &pixels, .width = 64, .height = 64 };
    try s.drawImage(gpa, bmp, .scaling(10, 10), .black, 1, .normal);
    try s.drawImage(gpa, bmp, Transform.scaling(10, 10).concat(.translation(50, 0)), .black, 1, .normal);

    try testing.expectEqual(@as(usize, 1), s.images.items.len);
    try testing.expectEqual(@as(usize, 2), s.instances.items.len);
    try testing.expectEqual(@as(u32, 40), s.images.items[0].width);
    try testing.expectEqual(@as(usize, 40 * 40), s.texels.items.len);
    try testing.expectEqual(slugpipe.packTexel(255, 0, 0, 255), s.texels.items[123]);

    // Drawn over a thousand pixels, it is kept at its own size.
    try s.drawImage(gpa, .{ .pixels = &pixels, .width = 32, .height = 128 }, .scaling(1000, 1000), .black, 1, .normal);
    try testing.expectEqual(@as(u32, 32), s.images.items[1].width);
    try testing.expectEqual(@as(u32, 128), s.images.items[1].height);
}

test "merging renumbers images and their texels, and leaves paths' headers alone" {
    const gpa = testing.allocator;
    var a: Scene = .{};
    defer a.deinit(gpa);
    a.reset(.{ 100, 100 });
    var b: Scene = .{};
    defer b.deinit(gpa);
    b.reset(.{ 100, 100 });

    var pixels: [4 * 4 * 4]u8 = @splat(255);
    try a.drawImage(gpa, .{ .pixels = &pixels, .width = 4, .height = 4 }, .scaling(100, 100), .black, 1, .normal);
    try b.drawImage(gpa, .{ .pixels = &pixels, .width = 4, .height = 4 }, .scaling(100, 100), .black, 1, .normal);

    var curves: std.ArrayList(slug.Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 0, 0, 10, 10);
    try b.draw(gpa, curves.items, .nonzero, .identity, .black, 1.0, .normal);

    _ = try a.merge(gpa, b);
    try testing.expectEqual(@as(usize, 2), a.images.items.len);
    try testing.expectEqual(@as(u32, 16), a.images.items[1].offset);
    try testing.expectEqual(@as(u32, 1), a.instances.items[1].image);
    // The path after the image points at the only header there is.
    try testing.expectEqual(@as(u32, 0), a.instances.items[2].header);
}

test "merging a scene renumbers every index in it" {
    // The failure this exists to catch is quiet and total: a page merged
    // without its headers renumbered draws the *previous* page's outlines at
    // this page's positions, which looks like a rendering bug anywhere but
    // here.
    const gpa = testing.allocator;

    var a: Scene = .{};
    defer a.deinit(gpa);
    a.reset(.{ 100, 100 });

    var b: Scene = .{};
    defer b.deinit(gpa);
    b.reset(.{ 100, 100 });

    var curves: std.ArrayList(slug.Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 0, 0, 10, 10);

    // One path in `a`, then a clipped path in `b`.
    try a.draw(gpa, curves.items, .nonzero, .identity, .black, 1.0, .normal);

    try b.pushClip(gpa, curves.items, .nonzero, .identity);
    try b.draw(gpa, curves.items, .nonzero, .identity, .black, 1.0, .normal);
    b.popClip();

    const a_headers = a.store.headers.items.len;
    const a_curves = a.store.curves.items.len;
    const range = try a.merge(gpa, b);

    try testing.expectEqual(@as(u32, 1), range.first_instance);
    try testing.expectEqual(@as(u32, 1), range.instance_count);
    try testing.expectEqual(@as(u32, 0), range.first_clip);
    try testing.expectEqual(@as(u32, 1), range.clip_count);

    // The merged instance points past `a`'s headers, not at them.
    const merged = a.instances.items[1];
    try testing.expectEqual(@as(u32, @intCast(a_headers + 1)), merged.header);
    try testing.expectEqual(@as(u32, 0), merged.clip_node);
    try testing.expectEqual(@as(u32, @intCast(a_headers)), a.clips.items[0].header);

    // And the header it points at names curves that are really there.
    const h = a.store.headers.items[merged.header];
    try testing.expectEqual(@as(u32, @intCast(a_curves + curves.items.len)), h.curve_first);
    try testing.expect(h.curve_first + h.curve_count <= a.store.curves.items.len);

    // Every band's slice, and every index in it, is in range -- the check
    // that the three levels of renumbering agree.
    for (a.store.bands.items) |band| {
        try testing.expect(band.first + band.count <= a.store.indices.items.len);
        for (a.store.indices.items[band.first..][0..band.count]) |i| {
            try testing.expect(i < a.store.curves.items.len);
        }
    }
}

test "placing a recorded page composes its transform and keeps the chain" {
    const gpa = testing.allocator;

    var s: Scene = .{};
    defer s.deinit(gpa);
    s.reset(.{ 100, 100 });

    var curves: std.ArrayList(slug.Curve) = .empty;
    defer curves.deinit(gpa);
    try square(gpa, &curves, 0, 0, 10, 10);

    const start = s.rangeStart();
    try s.pushClip(gpa, curves.items, .nonzero, .identity);
    try s.draw(gpa, curves.items, .nonzero, .identity, .black, 1.0, .normal);
    s.popClip();
    const range = s.rangeEnd(start);

    var f: Frame = .{};
    defer f.deinit(gpa);

    // Placed twice, at two offsets: one recording, two pages on screen.
    try f.place(gpa, s, range, .translation(50, 0), .{ 0, 0, 1000, 1000 });
    try f.place(gpa, s, range, .translation(0, 200), .{ 0, 0, 1000, 1000 });

    try testing.expectEqual(@as(usize, 2), f.instances.items.len);
    try testing.expectEqual(@as(usize, 2), f.clips.items.len);

    // Each instance carries its own placement.
    try testing.expectEqual([2]f32{ 50, 0 }, f.instances.items[0].translate);
    try testing.expectEqual([2]f32{ 0, 200 }, f.instances.items[1].translate);

    // And each points at *its own* copy of the clip, not at the other's.
    try testing.expectEqual(@as(u32, 0), f.instances.items[0].clip_node);
    try testing.expectEqual(@as(u32, 1), f.instances.items[1].clip_node);
    try testing.expectEqual([2]f32{ 50, 0 }, f.clips.items[0].translate);
    try testing.expectEqual([2]f32{ 0, 200 }, f.clips.items[1].translate);
}


