//! Replaying a display list onto a canvas: the first place in the project
//! where a PDF becomes pixels.
//!
//! Everything below this has been building toward one function. Gjöll turns
//! bytes into objects, the interpreter turns objects into a `DisplayList`,
//! `path.zig` turns its curves into triangles, `stroke.zig` turns its pens
//! into outlines, and `raster.zig` turns triangles into coverage. This walks
//! the list and calls them in order.
//!
//! ## What it draws, and what it does not
//!
//! Fills, strokes, and clips, with solid paint. That is line art, table rules,
//! borders, boxes, underlines, figures, charts, signatures and every vector
//! drawing on a page -- most of the marks on most documents that are not text.
//!
//! Three things are counted and skipped, each because the layer under it does
//! not exist yet rather than because of anything here:
//!
//! * **Text.** Týr has no outline extraction -- no `glyf` parser, no Type 2
//!   charstring interpreter -- so there is nothing to hand the path pipeline.
//!   The moment there is, a glyph is a path and `fill` below takes it with no
//!   change. `Options.text_boxes` draws the advance rectangles instead, which
//!   is a layout debugging aid and is off by default because a box is not a
//!   letter and an image that pretends otherwise is worse than one with a gap.
//! * **Images.** An image XObject is decoded behind `ImageSource`; an inline
//!   image (`BI ... ID ... EI`) carries its samples in the list and is turned
//!   into pixels here, by `inlineBitmap`. `Options.image_boxes` outlines
//!   whatever could not be had.
//! * **Shadings and tiling patterns.** The interpreter resolves both into
//!   `Paint`, and painting them needs a gradient rasteriser and a recursive
//!   replay respectively. Solid paint is exact; these are skipped.
//!
//! `Stats` counts every one of them, so a rendered page comes with an honest
//! account of what is missing from it rather than looking finished.
//!
//! ## Transparency groups
//!
//! `layer_push` multiplies its alpha into everything inside and `layer_pop`
//! restores it. That is exact for a non-isolated, non-knockout group in normal
//! blend mode, and an approximation otherwise: a correct implementation
//! renders the group to its own buffer and composites once, which matters when
//! the group's contents overlap each other. Doing it properly needs an
//! offscreen canvas per group, which is a real feature and not a line of code,
//! so this is marked as an approximation rather than quietly done wrong.

const std = @import("std");
const Allocator = std.mem.Allocator;

const DisplayList = @import("../gelgja/DisplayList.zig");
const geom = @import("../gelgja/geom.zig");
const paint = @import("../gelgja/paint.zig");
const path = @import("path.zig");
const raster = @import("raster.zig");
const scene_mod = @import("scene.zig");
const slug = @import("slug.zig");
const stroke = @import("stroke.zig");

const Bounds = geom.Bounds;
const Canvas = raster.Canvas;
const Color = paint.Color;
const FillRule = geom.FillRule;
const Point = geom.Point;
const Scene = scene_mod.Scene;
const Transform = geom.Transform;

pub const Error = path.Error;

/// What a `layer_push` saved, restored by its `layer_pop`.
const SavedLayer = struct { alpha: f32, blend: paint.BlendMode };

/// One glyph's outline, in the font program's own units.
///
/// Expressed in Gelgja's vocabulary -- the same verbs and points a display
/// list path uses -- rather than in Týr's `Outline`, so that Gleipnir keeps
/// importing nothing but Gelgja. A glyph is a path; the only thing that makes
/// it special is that its coordinates are in em units and have to be divided
/// by `units_per_em` before they mean anything.
pub const GlyphOutline = struct {
    verbs: []const geom.Verb,
    points: []const Point,
    /// 1000 for CFF and Type 1, usually 2048 for TrueType.
    units_per_em: u16 = 1000,
};

/// Where glyph outlines come from.
///
/// An interface rather than a dependency, because resolving a character code
/// to an outline needs a font program, and finding *that* needs the PDF
/// document -- which is the one thing a display list exists to be independent
/// of. The caller wires Gjöll and Týr together behind this and hands the
/// result in; `src/vanagandr/glyphs.zig` is the implementation.
///
/// The returned slices are borrowed and valid only until the next call.
pub const GlyphSource = struct {
    ptr: *anyopaque,
    lookup: *const fn (
        ptr: *anyopaque,
        font: DisplayList.FontId,
        glyph: DisplayList.Glyph,
    ) ?GlyphOutline,

    pub fn get(s: GlyphSource, font: DisplayList.FontId, glyph: DisplayList.Glyph) ?GlyphOutline {
        return s.lookup(s.ptr, font, glyph);
    }
};

/// Where decoded images come from.
///
/// The same arrangement as `GlyphSource`, and for the same reason: a display
/// list records which object an image is and stops there, because decoding it
/// needs the document and a display list exists to be independent of one. The
/// caller wires Gjöll's `image.zig` behind this;
/// `src/vanagandr/images.zig` is the implementation.
///
/// The returned pixels are borrowed and must stay valid for the whole replay,
/// which is what makes a page that draws the same logo forty times decode it
/// once.
pub const ImageSource = struct {
    ptr: *anyopaque,
    lookup: *const fn (ptr: *anyopaque, object: u32, name: []const u8) ?Bitmap,

    /// Straight RGBA, eight bits a channel.
    pub const Bitmap = struct {
        pixels: []const u8,
        width: u32,
        height: u32,
        /// The alpha is a stencil and the colour comes from the current fill.
        is_mask: bool = false,
    };

    pub fn get(s: ImageSource, object: u32, name: []const u8) ?Bitmap {
        return s.lookup(s.ptr, object, name);
    }
};

pub const Options = struct {
    /// How far a flattened segment may stray from its curve, in device pixels.
    tolerance: f32 = 0.1,
    /// Where glyph outlines come from. Without one, text is counted and not
    /// drawn.
    glyphs: ?GlyphSource = null,
    /// Where decoded image pixels come from. Without one, images are counted
    /// and not drawn.
    images: ?ImageSource = null,
    /// Draw a rectangle where each glyph would be, instead of the glyph. A
    /// layout aid for when there is no glyph source, or when the question is
    /// whether the interpreter put the text in the right place rather than
    /// what it looks like.
    text_boxes: bool = false,
    /// Outline each image's placement.
    image_boxes: bool = false,
    /// A ceiling on the clip stack, so a damaged list that pushes without
    /// popping cannot exhaust memory a framebuffer at a time.
    max_clip_depth: u32 = 64,
    /// Which rasteriser fills an outline.
    path_backend: PathBackend = .stencil,
    /// How far a quadratic may stray from the cubic it stands in for, in the
    /// path's own units rather than in pixels.
    ///
    /// Not `tolerance`, and not derived from it, because it is answering a
    /// different question. `tolerance` is how coarsely a curve may be
    /// flattened *for this zoom*; this is how coarsely a cubic may be
    /// rewritten as quadratics *once, for every zoom*, since the curves go to
    /// the device and stay there. A fiftieth of a point is a fiftieth of a
    /// pixel at 100% and still under a fifth at eight times that.
    curve_tolerance: f32 = slug.default_tolerance,
};

/// The two ways to turn an outline into coverage.
///
/// They are not a fast one and a slow one. They answer different questions
/// and have different failure modes, and both are kept because each is the
/// other's check:
///
///   **stencil** counts winding per sample and resolves, which is what a
///   Vulkan stencil attachment does. Exact in the limit, quantised to
///   `samples + 1` coverage levels, and the cost is the summed area of the
///   fan triangles.
///
///   **slug** asks the outline how much of each pixel is inside, from the
///   curves. Continuous coverage across an edge, resolution independent, and
///   the cost is the curves in one band per fragment. This is the model of
///   the GPU pipeline; `raster.Canvas.fillSlug` is the fragment shader.
///
/// `fenrir raster --path both` renders a page each way and reports the
/// difference, which is the whole reason there is a runtime switch here and
/// not a compile-time one.
pub const PathBackend = enum { stencil, slug };

/// What the page contained and what was actually drawn.
pub const Stats = struct {
    fills: u32 = 0,
    strokes: u32 = 0,
    clips: u32 = 0,
    /// Paths whose paint was a shading or a tiling pattern, so nothing was
    /// painted.
    unsupported_paint: u32 = 0,
    text_runs: u32 = 0,
    glyphs: u32 = 0,
    images: u32 = 0,
    /// Images actually sampled onto the page, and images whose pixels could
    /// not be had -- an undecodable codec, or a backend with no sampler.
    images_drawn: u32 = 0,
    images_not_drawn: u32 = 0,
    shadings: u32 = 0,
    layers: u32 = 0,
    /// Segments produced by flattening, summed. The number that explains why a
    /// page took as long as it did.
    segments: u64 = 0,
    /// Clip pushes refused because `max_clip_depth` was reached.
    clips_dropped: u32 = 0,
    /// Paths abandoned because they exceeded the flattener's point budget.
    paths_dropped: u32 = 0,
    /// Glyphs actually filled, and glyphs whose outline could not be found:
    /// a code the encoding chain did not resolve, or a font program that would
    /// not open.
    glyphs_drawn: u32 = 0,
    glyphs_missing: u32 = 0,
    /// Glyphs that resolved to an outline with nothing in it. A space, and
    /// most of the blank half of any page of text -- counted apart from the
    /// drawn ones so that "drawn" is not quietly short of "total" by the
    /// number of word gaps.
    glyphs_blank: u32 = 0,
    /// Glyphs in render mode 3, which paints nothing by design: the OCR layer
    /// of a scanned page. Not a failure to draw them -- drawing them would put
    /// a second copy of the text over the scan.
    glyphs_invisible: u32 = 0,
    /// Text runs skipped because there was no glyph source at all.
    text_not_drawn: u32 = 0,

    /// True when everything on the page was drawn as it was recorded.
    pub fn complete(s: Stats) bool {
        return s.unsupported_paint == 0 and s.images_not_drawn == 0 and s.shadings == 0 and
            s.clips_dropped == 0 and s.paths_dropped == 0 and
            s.text_not_drawn == 0 and s.glyphs_missing == 0;
    }
};

/// The matrix that puts a display list on a canvas.
///
/// The list's own space has the page box at `(0, 0, w, h)` with y running *up*,
/// which is PDF's convention and what the interpreter's base transform leaves
/// behind. A framebuffer has y running down. So this is a scale and a flip,
/// and it is the only flip in the renderer -- everything downstream, including
/// the vertex shader, works in pixels with y down.
pub fn pageTransform(page: Bounds, scale: f32) Transform {
    return .{ .a = scale, .b = 0, .c = 0, .d = -scale, .e = 0, .f = page.height() * scale };
}

/// How big a canvas that transform needs.
pub fn canvasSize(page: Bounds, scale: f32) [2]u32 {
    const w = @max(1.0, @ceil(page.width() * scale));
    const h = @max(1.0, @ceil(page.height() * scale));
    return .{ @intFromFloat(@min(w, 65535.0)), @intFromFloat(@min(h, 65535.0)) };
}

/// Draws `list` onto `canvas`. The canvas is not cleared first: a caller that
/// wants a white page clears it to white, and one compositing onto something
/// else does not.
pub fn render(
    gpa: Allocator,
    canvas: *Canvas,
    list: DisplayList,
    xform: Transform,
    options: Options,
) Error!Stats {
    return walk(gpa, .{ .canvas = canvas }, list, xform, options);
}

/// The same walk, ending in instances for the GPU instead of pixels.
///
/// Everything about how a page is interpreted -- clip nesting, stroke
/// outlines, glyph placement, the transform stack -- happens here exactly as
/// it does for `render`, because it *is* `render`, with the last call in each
/// branch pointed somewhere else. A page recorded this way and a page
/// rasterised on the CPU cannot disagree about anything but the rasteriser.
pub fn record(
    gpa: Allocator,
    target: *Scene,
    list: DisplayList,
    xform: Transform,
    options: Options,
) Error!Stats {
    var opts = options;
    // Recording has only one rasteriser to record for.
    opts.path_backend = .slug;
    return walk(gpa, .{ .scene = target }, list, xform, opts);
}

/// Where a replay's output goes. Exactly one of the two, chosen by the entry
/// point rather than by a flag, so there is no state in which both or neither
/// is set.
const Sink = union(enum) {
    canvas: *Canvas,
    scene: *Scene,
};

fn walk(
    gpa: Allocator,
    sink: Sink,
    list: DisplayList,
    xform: Transform,
    options: Options,
) Error!Stats {
    var r: Replayer = .{
        .gpa = gpa,
        .sink = sink,
        .list = list,
        .base = xform,
        .options = options,
        // Tolerance is a device-pixel quantity and the flattener works in page
        // space, so it is divided by however much the page is magnified. A
        // curve subdivided finely enough at 100% is visibly a polygon at 800%.
        .flat = .init(.{ .tolerance = options.tolerance, .scale = xform.expansion() }),
        .outline = .init(.{ .tolerance = options.tolerance, .scale = xform.expansion() }),
    };
    defer r.deinit();
    try r.run();
    return r.stats;
}

const Replayer = struct {
    gpa: Allocator,
    sink: Sink,
    list: DisplayList,
    base: Transform,
    options: Options,
    stats: Stats = .{},

    /// Reused across every path on the page. A page has thousands, and the
    /// arrays settle at their high-water mark after the first few.
    flat: path.Flattener,
    /// The stroker's output, kept separate so a stroke does not have to
    /// destroy the flattened input it is being built from.
    outline: path.Flattener,
    /// Scratch for `.stencil`: the fan and cover quad of the path being
    /// filled. Reused for the same reason `flat` is -- meshing was two
    /// allocations and two frees per glyph, which on a page of prose is
    /// thousands of both.
    meshes: path.MeshBuffers = .{},

    /// Scratch for `.slug`: one path's curves, and the store that holds the
    /// bands built over them. Both are reset rather than reallocated per
    /// path, which is what keeps a page of thousands of glyphs to a handful
    /// of allocations.
    curves: std.ArrayList(slug.Curve) = .empty,
    store: slug.Store = .{},
    /// Glyph outlines already in `store`, by font and glyph id. The canvas
    /// sink's half of what `Scene.glyphs` does: a page of text rasterises
    /// from a few hundred outlines rather than converting one per glyph.
    glyphs: std.AutoHashMapUnmanaged(scene_mod.GlyphKey, u32) = .empty,

    /// One entry per open clip, so `clip_pop` knows whether its `clip_push`
    /// actually took effect.
    clip_stack: std.ArrayList(bool) = .empty,
    /// The blend mode in force. See `setBlend`.
    blend: paint.BlendMode = .normal,
    /// Constant alpha, multiplied down by every open transparency group.
    alpha: f32 = 1,
    /// What a `layer_push` saved, restored by its `layer_pop`. One stack
    /// rather than two, so a failed append cannot leave them disagreeing
    /// about how deep the nesting is.
    alpha_stack: std.ArrayList(SavedLayer) = .empty,

    fn deinit(r: *Replayer) void {
        r.flat.deinit(r.gpa);
        r.outline.deinit(r.gpa);
        r.meshes.deinit(r.gpa);
        r.curves.deinit(r.gpa);
        r.store.deinit(r.gpa);
        r.glyphs.deinit(r.gpa);
        r.clip_stack.deinit(r.gpa);
        r.alpha_stack.deinit(r.gpa);
    }

    fn run(r: *Replayer) Error!void {
        for (r.list.cmds) |cmd| {
            switch (cmd) {
                .fill_path => |c| try r.fill(c.path, c.rule, c.paint),
                .stroke_path => |c| try r.strokePath(c.path, c.stroke, c.paint, c.ctm),
                .clip_push => |c| try r.pushClip(c.path, c.rule),
                .clip_pop => r.popClip(),
                .text => |t| try r.text(t),
                .image => |img| try r.image(img),
                .shading => r.stats.shadings += 1,
                .layer_push => |l| try r.pushLayer(l),
                .layer_pop => r.popLayer(),
                .marked_begin, .marked_end => {},
            }
        }
        // A list can end with clips still open -- `DisplayList.unbalanced`
        // records exactly that, and damaged files produce it constantly.
        // Unwinding here keeps the canvas reusable for a second page.
        while (r.clip_stack.items.len > 0) r.popClip();
        while (r.alpha_stack.items.len > 0) r.popLayer();
    }

    // -- fills --------------------------------------------------------------

    fn fill(r: *Replayer, p: DisplayList.Path, rule: FillRule, pnt: paint.Paint) Error!void {
        r.stats.fills += 1;
        const color = solid(pnt) orelse {
            r.stats.unsupported_paint += 1;
            return;
        };

        // The analytic rasteriser takes the path's own curves, unflattened.
        // That is the whole point of it: a cubic stays a cubic pair all the
        // way to the fragment, so the same buffers draw the page at any zoom
        // and a curve never shows the flat spots of its approximation.
        //
        // Glyphs do the same, from the font's outline in em units, in
        // `drawGlyphOutline`. Strokes and clips cannot yet: the stroker's
        // outline and the clip path are flattened at the recording's scale,
        // and go through `paintThrough` and `pushClip` as segments. That is
        // F1 in OPTIMIZING.md.
        if (r.options.path_backend == .slug) {
            r.curves.clearRetainingCapacity();
            slug.fromPath(
                r.gpa,
                &r.curves,
                r.list,
                p,
                .identity,
                r.options.curve_tolerance,
            ) catch {
                r.stats.paths_dropped += 1;
                return;
            };
            try r.paintCurves(rule, color, r.base);
            return;
        }

        const flat = r.flatten(p) orelse return;
        try r.paintFlattened(flat, rule, color);
    }

    /// Fills whatever is in `r.curves`: the one place the two sinks part.
    fn paintCurves(r: *Replayer, rule: FillRule, color: Color, xform: Transform) Error!void {
        if (r.curves.items.len == 0) return;
        switch (r.sink) {
            .canvas => |c| {
                // Added and then dropped again: this outline is wanted for
                // one fill. The glyphs kept in the same store below are the
                // exception, which is why this rewinds rather than resets.
                const mark = r.store.mark();
                defer r.store.rewind(mark);
                const id = try r.store.add(r.gpa, r.curves.items, rule);
                c.fillSlug(.{
                    .store = &r.store,
                    .header = id,
                    .xform = xform,
                }, color, r.alpha);
            },
            .scene => |s| try s.draw(
                r.gpa,
                r.curves.items,
                rule,
                xform,
                color,
                r.alpha,
                r.blend,
            ),
        }
    }

    /// Flattens a path, or counts it as dropped and returns null.
    ///
    /// A path over the point budget is a damaged or generated one -- a contour
    /// map, a CAD export, a file with coordinates in the millions. Dropping it
    /// and saying so is better than either rendering half of it silently or
    /// failing the whole page.
    fn flatten(r: *Replayer, p: DisplayList.Path) ?path.Flattened {
        r.flat.reset();
        r.flat.addPath(r.gpa, r.list, p) catch |e| switch (e) {
            error.TooManyPoints => {
                r.stats.paths_dropped += 1;
                return null;
            },
            else => return null,
        };
        const flat = r.flat.finish(r.gpa) catch return null;
        r.stats.segments += flat.segmentCount();
        return flat;
    }

    fn paintFlattened(r: *Replayer, flat: path.Flattened, rule: FillRule, color: Color) Error!void {
        try r.paintThrough(flat, r.base, rule, color);
    }

    /// Every filled outline on the page goes through here, whichever
    /// rasteriser is in force: a path fill, a stroke's generated outline, a
    /// glyph. One place, so the two backends cannot drift apart in *what*
    /// they are asked to draw -- only in how they draw it, which is the whole
    /// point of being able to compare them.
    fn paintThrough(
        r: *Replayer,
        flat: path.Flattened,
        xform: Transform,
        rule: FillRule,
        color: Color,
    ) Error!void {
        if (flat.isEmpty()) return;
        switch (r.options.path_backend) {
            .stencil => {
                // Only a canvas has a stencil buffer; `record` forces `.slug`
                // before the walk starts, so this arm is unreachable with a
                // scene and the switch says so rather than silently drawing
                // nothing.
                const c = switch (r.sink) {
                    .canvas => |c| c,
                    .scene => unreachable,
                };
                const m = try path.meshInto(r.gpa, &r.meshes, flat);
                c.fill(m, xform, rule, color, r.alpha);
            },
            .slug => {
                r.curves.clearRetainingCapacity();
                try slug.fromFlattened(r.gpa, &r.curves, flat);
                try r.paintCurves(rule, color, xform);
            },
        }
    }

    // -- strokes ------------------------------------------------------------

    /// The one command that has to leave page space.
    ///
    /// The path's points are already through the CTM, but the pen is a circle
    /// *before* it: a matrix that scales x twice as much as y draws an
    /// elliptical pen, and a stroke generated from page-space points with a
    /// single scaled width cannot express that. So the points go back through
    /// the inverse, the stroke is built in user space where the pen is round,
    /// and the outline is drawn with `ctm` composed into its transform.
    ///
    /// For the overwhelmingly common case of a similarity matrix this is
    /// arithmetic that cancels out. It is done anyway rather than special-cased
    /// because the special case would be a second code path exercised by five
    /// percent of documents, which is the worst possible amount of testing.
    fn strokePath(
        r: *Replayer,
        p: DisplayList.Path,
        s: paint.Stroke,
        pnt: paint.Paint,
        ctm: Transform,
    ) Error!void {
        r.stats.strokes += 1;
        const color = solid(pnt) orelse {
            r.stats.unsupported_paint += 1;
            return;
        };

        // A singular matrix maps the page to a line and the stroke with it.
        const inverse = ctm.invert() orelse return;
        const to_device = ctm.concat(r.base);
        const scale = to_device.expansion();
        if (!(scale > 0) or !std.math.isFinite(scale)) return;

        // Flatten in user space, at a tolerance that accounts for the whole
        // journey to a pixel.
        r.flat.reset();
        r.flat.options = .{ .tolerance = r.options.tolerance, .scale = scale };
        const flat = r.flattenThrough(p, inverse) orelse return;

        const dash = r.list.dashOf(s);
        r.outline.reset();
        r.outline.options = .{ .tolerance = r.options.tolerance, .scale = scale };
        stroke.outline(r.gpa, &r.outline, flat, .{
            .width = stroke.resolveWidth(s.width, scale),
            .cap = s.cap,
            .join = s.join,
            .miter_limit = s.miter_limit,
            .dash = dash,
            .dash_phase = s.dash_phase,
            .tolerance = r.options.tolerance / scale,
        }) catch |e| switch (e) {
            error.TooManyPoints => {
                r.stats.paths_dropped += 1;
                return;
            },
            else => return,
        };
        const outlined = r.outline.finish(r.gpa) catch return;
        if (outlined.isEmpty()) return;

        // A stroke.s outline is always nonzero: the rule is how the stamped
        // pieces are unioned, not a property of the path. See `stroke.zig`.
        try r.paintThrough(outlined, to_device, .nonzero, color);
    }

    /// Like `flatten`, but maps every point through `pre` first.
    fn flattenThrough(r: *Replayer, p: DisplayList.Path, pre: Transform) ?path.Flattened {
        const verbs = r.list.verbsOf(p);
        const points = r.list.pointsOf(p);
        var i: usize = 0;
        for (verbs) |verb| {
            const n = verb.pointCount();
            if (i + n > points.len) break;
            const ok = switch (verb) {
                .move => r.flat.moveTo(r.gpa, pre.apply(points[i])),
                .line => r.flat.lineTo(r.gpa, pre.apply(points[i])),
                .cubic => r.flat.cubicTo(
                    r.gpa,
                    pre.apply(points[i]),
                    pre.apply(points[i + 1]),
                    pre.apply(points[i + 2]),
                ),
                .close => r.flat.close(r.gpa),
            };
            ok catch {
                r.stats.paths_dropped += 1;
                return null;
            };
            i += n;
        }
        const flat = r.flat.finish(r.gpa) catch return null;
        r.stats.segments += flat.segmentCount();
        return flat;
    }

    // -- clips --------------------------------------------------------------

    fn pushClip(r: *Replayer, p: DisplayList.Path, rule: FillRule) Error!void {
        r.stats.clips += 1;
        if (r.clip_stack.items.len >= r.options.max_clip_depth) {
            r.stats.clips_dropped += 1;
            // Still pushed, so the matching pop stays balanced. A dropped clip
            // draws too much rather than too little, which is the safer way to
            // be wrong: content appears where it should have been hidden,
            // rather than a page coming out blank.
            try r.clip_stack.append(r.gpa, false);
            return;
        }

        const flat = r.flatten(p) orelse {
            try r.clip_stack.append(r.gpa, false);
            return;
        };
        if (flat.isEmpty()) {
            // An empty clip path clips everything away, which is not the same
            // as no clip at all -- `W n` with a degenerate path is how some
            // generators hide content.
            try r.clip_stack.append(r.gpa, false);
            return;
        }

        switch (r.sink) {
            .canvas => |c| {
                const m = try path.meshInto(r.gpa, &r.meshes, flat);
                try c.pushClip(r.gpa, m, r.base, rule);
            },
            .scene => |s| {
                // The clip goes to the device as an outline like any other,
                // and the fragment shader intersects it by multiplying
                // coverages. No mask, no second attachment, and an
                // antialiased clip edge for free.
                r.curves.clearRetainingCapacity();
                try slug.fromFlattened(r.gpa, &r.curves, flat);
                try s.pushClip(r.gpa, r.curves.items, rule, r.base);
            },
        }
        try r.clip_stack.append(r.gpa, true);
    }

    fn popClip(r: *Replayer) void {
        const pushed = r.clip_stack.pop() orelse return;
        if (!pushed) return;
        switch (r.sink) {
            .canvas => |c| c.popClip(r.gpa),
            .scene => |s| s.popClip(),
        }
    }

    // -- groups -------------------------------------------------------------

    fn pushLayer(r: *Replayer, l: paint.Layer) Error!void {
        r.stats.layers += 1;
        try r.alpha_stack.append(r.gpa, .{ .alpha = r.alpha, .blend = r.blend });
        r.alpha *= std.math.clamp(l.alpha, 0, 1);
        // The innermost mode that is not `normal` wins. A group composites
        // into its parent with its own mode and its *contents* are drawn
        // normally inside it -- so with the group folded into its contents
        // the way this does, a nested plain group must not cancel the
        // multiply an enclosing one asked for.
        if (l.blend != .normal) r.setBlend(l.blend);
    }

    fn popLayer(r: *Replayer) void {
        const saved: SavedLayer = r.alpha_stack.pop() orelse .{ .alpha = 1, .blend = .normal };
        r.alpha = saved.alpha;
        r.setBlend(saved.blend);
    }

    /// The replayer owns the current blend mode and the canvas mirrors it.
    ///
    /// It used to live only on the canvas, which was fine while a canvas was
    /// the only thing a replay could end in. A recorded scene has nowhere to
    /// put device state, so the mode is kept here and pushed down.
    fn setBlend(r: *Replayer, mode: paint.BlendMode) void {
        r.blend = mode;
        switch (r.sink) {
            .canvas => |c| c.blend_mode = mode,
            .scene => {},
        }
    }

    // -- the not-yet-drawable ------------------------------------------------

    /// A run of glyphs, drawn as the paths they are.
    ///
    /// There is nothing special here about text. A glyph is an outline in em
    /// units; scale it by `size / units_per_em`, put it at the glyph's offset,
    /// run it through the run's matrix and the page's, and fill it nonzero
    /// like any other path. Everything that makes text hard -- encodings,
    /// CMaps, font programs, subsetting -- happened before `GlyphSource`
    /// answered, which is the point of that interface.
    fn text(r: *Replayer, tr: DisplayList.TextRun) Error!void {
        r.stats.text_runs += 1;
        const glyphs = r.list.glyphsOf(tr);
        r.stats.glyphs += @intCast(glyphs.len);

        // Mode 3 is how every scanned document carries its OCR layer: real
        // text, positioned over the page image, painting nothing. Drawing it
        // would put a second copy of the text on top of the scan.
        if (tr.mode == .invisible) {
            r.stats.glyphs_invisible += @intCast(glyphs.len);
            return;
        }

        if (r.options.glyphs) |src| {
            if (!r.options.text_boxes) {
                try r.drawGlyphs(src, tr, glyphs);
                return;
            }
        }
        if (!r.options.text_boxes) {
            r.stats.text_not_drawn += 1;
            return;
        }

        // Where each glyph would sit, as a box on the baseline. Only a layout
        // aid: it says the interpreter put the text in the right place, and
        // says nothing about what the letters look like.
        for (glyphs) |g| {
            const w = tr.size * 0.5;
            const h = tr.size * 0.7;
            const corners = [_]Point{
                .{ .x = g.offset.x, .y = g.offset.y },
                .{ .x = g.offset.x + w, .y = g.offset.y },
                .{ .x = g.offset.x + w, .y = g.offset.y + h },
                .{ .x = g.offset.x, .y = g.offset.y + h },
            };
            r.flat.reset();
            for (corners, 0..) |p, i| {
                const at = tr.transform.apply(p);
                (if (i == 0) r.flat.moveTo(r.gpa, at) else r.flat.lineTo(r.gpa, at)) catch return;
            }
            r.flat.close(r.gpa) catch return;
            const flat = r.flat.finish(r.gpa) catch return;
            try r.paintFlattened(flat, .nonzero, .{ .r = 0.6, .g = 0.6, .b = 0.75, .a = 0.4 });
        }
    }

    fn drawGlyphs(
        r: *Replayer,
        src: GlyphSource,
        tr: DisplayList.TextRun,
        glyphs: []const DisplayList.Glyph,
    ) Error!void {
        const color = solid(tr.fill) orelse {
            r.stats.unsupported_paint += 1;
            return;
        };
        // A stroked or clipping render mode is drawn as a plain fill. The
        // outline is right and the paint is not; the alternative is nothing at
        // all, and mode 1 and 2 are a fraction of a percent of text.
        if (!tr.mode.fills() and tr.mode != .clip) {
            if (!tr.mode.strokes()) return;
        }

        for (glyphs) |g| {
            const out = src.get(tr.font, g) orelse {
                r.stats.glyphs_missing += 1;
                continue;
            };
            if (out.verbs.len == 0) {
                r.stats.glyphs_blank += 1;
                continue;
            }

            // Font units to text space: divide by the em, scale by `Tf`, and
            // land at the glyph's own offset within the run. Then the run's
            // matrix, then the page's.
            const em = @as(f32, @floatFromInt(if (out.units_per_em == 0) 1000 else out.units_per_em));
            const s = tr.size / em;
            const place: Transform = .{ .a = s, .d = s, .e = g.offset.x, .f = g.offset.y };
            const to_device = place.concat(tr.transform).concat(r.base);

            const scale = to_device.expansion();
            if (!(scale > 0) or !std.math.isFinite(scale)) continue;

            // The analytic rasteriser takes the outline as curves, in em
            // units, once per glyph -- however many times the glyph appears
            // and at whatever sizes. See `drawGlyphOutline`.
            if (r.options.path_backend == .slug) {
                const em_place: Transform = .{
                    .a = tr.size,
                    .d = tr.size,
                    .e = g.offset.x,
                    .f = g.offset.y,
                };
                if (try r.drawGlyphOutline(
                    .{ .font = tr.font, .code = g.code, .id = g.id },
                    out,
                    em_place.concat(tr.transform).concat(r.base),
                    color,
                )) {
                    r.stats.glyphs_drawn += 1;
                } else {
                    r.stats.glyphs_blank += 1;
                }
                continue;
            }

            r.flat.reset();
            r.flat.options = .{ .tolerance = r.options.tolerance, .scale = scale };
            var i: usize = 0;
            var ok = true;
            for (out.verbs) |verb| {
                const n = verb.pointCount();
                if (i + n > out.points.len) break;
                (switch (verb) {
                    .move => r.flat.moveTo(r.gpa, out.points[i]),
                    .line => r.flat.lineTo(r.gpa, out.points[i]),
                    .cubic => r.flat.cubicTo(r.gpa, out.points[i], out.points[i + 1], out.points[i + 2]),
                    .close => r.flat.close(r.gpa),
                }) catch {
                    ok = false;
                    break;
                };
                i += n;
            }
            if (!ok) {
                r.stats.paths_dropped += 1;
                continue;
            }

            const flat = r.flat.finish(r.gpa) catch continue;
            if (flat.isEmpty()) continue;
            r.stats.segments += flat.segmentCount();
            r.stats.glyphs_drawn += 1;

            // Glyph outlines are always nonzero. TrueType and CFF both wind
            // counters the opposite way from the outer contour, which is what
            // makes the hole in an `o` a hole under this rule and under no
            // other -- even-odd would agree here and disagree the moment two
            // contours of a script face overlap.
            try r.paintThrough(flat, to_device, .nonzero, color);
        }
    }

    /// One glyph, as the curves it is made of, drawn through `xform`.
    ///
    /// The outline goes into the store in em units and is kept there under
    /// its font and glyph id, so the second `e` on a page costs an instance
    /// and no curves at all. That is worth more here than anywhere else: a
    /// page of prose is a few thousand glyphs drawn from a few hundred
    /// outlines, and before this each occurrence carried its own flattened
    /// copy -- 121,651 curves for the 3,805 glyphs of one page of a paper,
    /// where 5,700 say the same thing.
    ///
    /// Keeping them as curves rather than flattening is the other half. A
    /// flattened outline is only right for the size it was flattened at, so
    /// it could not be shared between a heading and a footnote, and it is a
    /// polygon at any zoom past the one it was made for.
    ///
    /// Returns false for an outline with nothing in it, which is a space.
    fn drawGlyphOutline(
        r: *Replayer,
        key: scene_mod.GlyphKey,
        out: GlyphOutline,
        xform: Transform,
        color: Color,
    ) Error!bool {
        const em = @as(f32, @floatFromInt(if (out.units_per_em == 0) 1000 else out.units_per_em));

        switch (r.sink) {
            .scene => |s| {
                if (s.glyphHeader(key)) |header| {
                    try s.drawHeader(r.gpa, header, xform, color, r.alpha, r.blend);
                    return true;
                }
                r.curves.clearRetainingCapacity();
                try slug.fromOutline(r.gpa, &r.curves, out.verbs, out.points, 1.0 / em, slug.glyph_tolerance);
                if (r.curves.items.len == 0) return false;
                const header = try s.addGlyph(r.gpa, key, r.curves.items);
                try s.drawHeader(r.gpa, header, xform, color, r.alpha, r.blend);
                return true;
            },
            .canvas => |c| {
                const header = r.glyphs.get(key) orelse blk: {
                    r.curves.clearRetainingCapacity();
                    try slug.fromOutline(r.gpa, &r.curves, out.verbs, out.points, 1.0 / em, slug.glyph_tolerance);
                    if (r.curves.items.len == 0) return false;
                    const h = try r.store.add(r.gpa, r.curves.items, .nonzero);
                    try r.glyphs.put(r.gpa, key, h);
                    break :blk h;
                };
                c.fillSlug(.{ .store = &r.store, .header = header, .xform = xform }, color, r.alpha);
                return true;
            },
        }
    }

    /// Pixels in hand, to whichever sink this replay ends in.
    fn drawBitmap(r: *Replayer, img: DisplayList.Image, bitmap: ImageSource.Bitmap) Error!void {
        const mask_color: Color = solid(img.fill) orelse .black;
        const xform = img.transform.concat(r.base);
        switch (r.sink) {
            .canvas => |c| c.drawImage(.{
                .pixels = bitmap.pixels,
                .width = bitmap.width,
                .height = bitmap.height,
                .xform = xform,
                .is_mask = bitmap.is_mask,
                .mask_color = mask_color,
            }, r.alpha),
            .scene => |s| {
                const dropped = s.stats.images_dropped;
                try s.drawImage(r.gpa, .{
                    .pixels = bitmap.pixels,
                    .width = bitmap.width,
                    .height = bitmap.height,
                    .is_mask = bitmap.is_mask,
                }, xform, mask_color, r.alpha, r.blend);
                if (s.stats.images_dropped != dropped) {
                    r.stats.images_not_drawn += 1;
                    return;
                }
            },
        }
        r.stats.images_drawn += 1;
    }

    fn image(r: *Replayer, img: DisplayList.Image) Error!void {
        r.stats.images += 1;

        if (img.isInline()) {
            // The samples are in the list. Decoded here, drawn, and freed:
            // §8.9.7 keeps an inline image to a few kilobytes, so there is
            // nothing worth caching, and a scene copies what it keeps.
            if (try inlineBitmap(r.gpa, r.list, img)) |pixels| {
                defer r.gpa.free(pixels);
                try r.drawBitmap(img, .{
                    .pixels = pixels,
                    .width = img.width,
                    .height = img.height,
                    .is_mask = img.is_mask,
                });
                return;
            }
        } else if (r.options.images) |source| {
            if (source.get(img.object, r.list.stringOf(img.name))) |bitmap| {
                try r.drawBitmap(img, bitmap);
                return;
            }
        }

        // Not drawn: no source, undecodable samples, or a scene out of room
        // for texels. The outline below
        // is a debugging aid and is not the image, so it does not make the
        // page complete.
        r.stats.images_not_drawn += 1;
        if (!r.options.image_boxes) return;

        // The unit square through the image's own matrix, which is how PDF
        // places every image (§8.9.5.2).
        const corners = [_]Point{
            .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 },
            .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 },
        };
        r.flat.reset();
        for (corners, 0..) |c, i| {
            const at = img.transform.apply(c);
            (if (i == 0) r.flat.moveTo(r.gpa, at) else r.flat.lineTo(r.gpa, at)) catch return;
        }
        r.flat.close(r.gpa) catch return;
        const flat = r.flat.finish(r.gpa) catch return;
        try r.paintFlattened(flat, .nonzero, .{ .r = 0.85, .g = 0.85, .b = 0.9, .a = 0.5 });
    }
};

/// An inline image's samples as straight RGBA, or null for one whose samples
/// do not add up to its size.
///
/// The interpreter has already run the filters and recorded how many
/// components a sample has, but not the colour space itself -- a display list
/// is replayable without a document, and a colour space can name a function.
/// So one component is grey, three are RGB and four are CMYK, and that is
/// right for every inline image in practice: they are small stencils, rules
/// and logos, not calibrated photographs. An `/Indexed` inline image comes
/// out as the grey of its index, which is the known gap.
///
/// A stencil mask (`/IM true`) paints where a sample is 0, per §8.9.6.2 --
/// and where it is 1 under `/Decode [1 0]`, which is what `inverted` says.
pub fn inlineBitmap(gpa: Allocator, list: DisplayList, img: DisplayList.Image) Allocator.Error!?[]u8 {
    const data = list.bytesOf(img.data);
    const w: usize = img.width;
    const h: usize = img.height;
    if (w == 0 or h == 0 or w * h > 1 << 24) return null;

    const bpc: usize = if (img.is_mask) 1 else img.bits_per_component;
    const comps: usize = if (img.is_mask) 1 else @max(img.components, 1);
    if (bpc == 0 or bpc > 16) return null;
    const row_bits = w * comps * bpc;
    const row_bytes = (row_bits + 7) / 8;
    if (data.len < row_bytes * h) return null;

    const out = try gpa.alloc(u8, w * h * 4);
    const max: u32 = if (bpc == 16) 65535 else (@as(u32, 1) << @intCast(bpc)) - 1;

    for (0..h) |y| {
        const row = data[y * row_bytes ..][0..row_bytes];
        for (0..w) |x| {
            var v: [4]f32 = @splat(0);
            for (0..@min(comps, 4)) |k| {
                const raw = readSample(row, (x * comps + k) * bpc, bpc);
                var f = @as(f32, @floatFromInt(raw)) / @as(f32, @floatFromInt(max));
                if (img.inverted and !img.is_mask) f = 1 - f;
                v[k] = f;
            }
            const o = (y * w + x) * 4;
            if (img.is_mask) {
                const paints = (v[0] < 0.5) != img.inverted;
                out[o..][0..4].* = .{ 0, 0, 0, if (paints) 255 else 0 };
                continue;
            }
            const rgb: [3]f32 = switch (comps) {
                1, 2 => .{ v[0], v[0], v[0] },
                3 => .{ v[0], v[1], v[2] },
                // The naive conversion, the same one Gjöll uses for
                // `/DeviceCMYK` with no profile.
                else => .{
                    (1 - v[0]) * (1 - v[3]),
                    (1 - v[1]) * (1 - v[3]),
                    (1 - v[2]) * (1 - v[3]),
                },
            };
            out[o..][0..4].* = .{ byteOf(rgb[0]), byteOf(rgb[1]), byteOf(rgb[2]), 255 };
        }
    }
    return out;
}

/// `bits` bits starting `bit` bits into `row`, most significant first.
fn readSample(row: []const u8, bit: usize, bits: usize) u32 {
    if (bits == 8) return row[bit / 8];
    if (bits == 16) return (@as(u32, row[bit / 8]) << 8) | row[bit / 8 + 1];
    var v: u32 = 0;
    for (0..bits) |i| {
        const at = bit + i;
        const b = (row[at / 8] >> @intCast(7 - at % 8)) & 1;
        v = (v << 1) | b;
    }
    return v;
}

fn byteOf(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

fn solid(p: paint.Paint) ?Color {
    return switch (p) {
        .solid => |c| c,
        else => null,
    };
}


// -- tests ------------------------------------------------------------------

const testing = std.testing;
const Builder = @import("../gelgja/Builder.zig");
const software = @import("software.zig");

/// Records a display list, replays it at a given scale, and hands back the
/// canvas. The shape every test below takes.
const Rendered = struct {
    canvas: Canvas,
    stats: Stats,
    list: DisplayList,

    fn init(
        gpa: Allocator,
        w: f32,
        h: f32,
        scale: f32,
        options: Options,
        build: *const fn (*Builder) anyerror!void,
    ) !Rendered {
        return initOn(gpa, .{ .samples = .one }, w, h, scale, options, build);
    }

    /// `init` onto a canvas set up some other way: more samples, when two
    /// backends are being compared rather than one being checked for where
    /// it put things.
    fn initOn(
        gpa: Allocator,
        canvas_options: raster.Options,
        w: f32,
        h: f32,
        scale: f32,
        options: Options,
        build: *const fn (*Builder) anyerror!void,
    ) !Rendered {
        var b: Builder = .init(gpa, .fromRect(0, 0, w, h));
        errdefer b.deinit();
        try build(&b);
        const list = try b.finish();

        const size = canvasSize(list.page, scale);
        var canvas: Canvas = try .init(gpa, size[0], size[1], canvas_options);
        errdefer canvas.deinit(gpa);
        canvas.fb.clear(.white);

        const stats = try render(gpa, &canvas, list, pageTransform(list.page, scale), options);
        return .{ .canvas = canvas, .stats = stats, .list = list };
    }

    fn deinit(r: *Rendered, gpa: Allocator) void {
        r.canvas.deinit(gpa);
        var l = r.list;
        l.deinit(gpa);
    }

    /// How dark a pixel is: 0 for the white page, 1 for solid black.
    fn ink(r: Rendered, x: u32, y: u32) f32 {
        return 1.0 - r.canvas.fb.at(x, y).r;
    }

    /// Ink summed over the page: the area drawn, in pixels, for black.
    fn totalInk(r: Rendered) f64 {
        var sum: f64 = 0;
        var y: u32 = 0;
        while (y < r.canvas.height()) : (y += 1) {
            var x: u32 = 0;
            while (x < r.canvas.width()) : (x += 1) sum += r.ink(x, y);
        }
        return sum;
    }

    fn anyInk(r: Rendered) bool {
        var y: u32 = 0;
        while (y < r.canvas.height()) : (y += 1) {
            var x: u32 = 0;
            while (x < r.canvas.width()) : (x += 1) {
                if (r.ink(x, y) > 0.05) return true;
            }
        }
        return false;
    }
};

fn box(b: *Builder, x0: f32, y0: f32, x1: f32, y1: f32) !void {
    try b.moveTo(.{ .x = x0, .y = y0 });
    try b.lineTo(.{ .x = x1, .y = y0 });
    try b.lineTo(.{ .x = x1, .y = y1 });
    try b.lineTo(.{ .x = x0, .y = y1 });
    try b.closePath();
}

test "a filled rectangle lands where the page says, with y flipped" {
    // The flip is what a symmetric test cannot see, so the rectangle sits near
    // the *bottom* of the page in PDF terms, which is the bottom of the image.
    const gpa = testing.allocator;
    var r = try Rendered.init(gpa, 100, 100, 1, .{}, struct {
        fn build(b: *Builder) !void {
            try box(b, 10, 10, 40, 30);
            try b.fill(.nonzero, .{ .solid = .black });
        }
    }.build);
    defer r.deinit(gpa);

    // PDF y = 10..30 is image y = 70..90.
    try testing.expectApproxEqAbs(@as(f32, 1), r.ink(25, 80), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), r.ink(25, 20), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), r.ink(60, 80), 0.01);
    try testing.expectEqual(@as(u32, 1), r.stats.fills);
    try testing.expect(r.stats.complete());
}

test "scale magnifies without moving the origin" {
    const gpa = testing.allocator;
    var r = try Rendered.init(gpa, 50, 50, 4, .{}, struct {
        fn build(b: *Builder) !void {
            try box(b, 0, 40, 10, 50);
            try b.fill(.nonzero, .{ .solid = .black });
        }
    }.build);
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u32, 200), r.canvas.width());
    try testing.expectEqual(@as(u32, 200), r.canvas.height());
    // The top-left corner of the page, four times bigger.
    try testing.expectApproxEqAbs(@as(f32, 1), r.ink(20, 20), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), r.ink(60, 60), 0.01);
}

test "a stroke draws a ring and not a disc" {
    const gpa = testing.allocator;
    var r = try Rendered.init(gpa, 100, 100, 1, .{}, struct {
        fn build(b: *Builder) !void {
            try box(b, 20, 20, 80, 80);
            try b.stroke(.{ .width = 8 }, .{ .solid = .black }, .identity);
        }
    }.build);
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u32, 1), r.stats.strokes);
    // On the left edge, inked; in the middle, not.
    try testing.expectApproxEqAbs(@as(f32, 1), r.ink(20, 50), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), r.ink(50, 50), 0.01);
    // The pen is eight wide, so 23 is inked and 28 is clear.
    try testing.expectApproxEqAbs(@as(f32, 1), r.ink(23, 50), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), r.ink(28, 50), 0.01);
}

test "a non-uniform CTM makes the pen an ellipse" {
    // The whole reason `stroke_path` carries its matrix. Under a matrix that
    // scales x three times as much as y, a round pen draws a stroke three
    // times thicker across a vertical line than across a horizontal one -- and
    // a renderer that strokes in page space with one scaled width cannot
    // produce that at all.
    const gpa = testing.allocator;
    var r = try Rendered.init(gpa, 120, 120, 1, .{}, struct {
        fn build(b: *Builder) !void {
            const ctm: Transform = .{ .a = 3, .d = 1 };
            for ([_][4]f32{
                .{ 5, 30, 35, 30 }, // horizontal: measured across y
                .{ 20, 60, 20, 110 }, // vertical: measured across x
            }) |seg| {
                try b.moveTo(ctm.apply(.{ .x = seg[0], .y = seg[1] }));
                try b.lineTo(ctm.apply(.{ .x = seg[2], .y = seg[3] }));
                try b.stroke(.{ .width = 4 }, .{ .solid = .black }, ctm);
            }
        }
    }.build);
    defer r.deinit(gpa);

    // The horizontal line is at page y = 30, image y = 90, four units thick.
    try testing.expectApproxEqAbs(@as(f32, 1), r.ink(45, 89), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), r.ink(45, 85), 0.01);

    // The vertical line is at page x = 60. Four *user* units thick, which the
    // matrix stretches to twelve page units: 56 and 64 are inked, 52 is not.
    try testing.expectApproxEqAbs(@as(f32, 1), r.ink(56, 30), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), r.ink(64, 30), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), r.ink(52, 30), 0.01);
}

test "a clip hides what is outside it and stops when it is popped" {
    const gpa = testing.allocator;
    var r = try Rendered.init(gpa, 100, 100, 1, .{}, struct {
        fn build(b: *Builder) !void {
            try box(b, 0, 50, 100, 100);
            try b.pushClip(.nonzero);
            try box(b, 0, 0, 100, 100);
            try b.fill(.nonzero, .{ .solid = .black });
            try b.popClip();
            try box(b, 90, 0, 100, 10);
            try b.fill(.nonzero, .{ .solid = .black });
        }
    }.build);
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u32, 1), r.stats.clips);
    // Inside the clip (PDF y 50..100 is image y 0..50): painted.
    try testing.expectApproxEqAbs(@as(f32, 1), r.ink(50, 25), 0.01);
    // Outside it: not.
    try testing.expectApproxEqAbs(@as(f32, 0), r.ink(50, 75), 0.01);
    // After the pop, the second fill lands even though it is outside.
    try testing.expectApproxEqAbs(@as(f32, 1), r.ink(95, 95), 0.01);
}

test "a transparency group alpha reaches everything inside it" {
    const gpa = testing.allocator;
    var r = try Rendered.init(gpa, 60, 60, 1, .{}, struct {
        fn build(b: *Builder) !void {
            try b.pushLayer(.{ .alpha = 0.5 });
            try box(b, 5, 30, 25, 55);
            try b.fill(.nonzero, .{ .solid = .black });
            try b.popLayer();
            try box(b, 35, 30, 55, 55);
            try b.fill(.nonzero, .{ .solid = .black });
        }
    }.build);
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u32, 1), r.stats.layers);
    const inside = r.ink(15, 15);
    try testing.expectApproxEqAbs(@as(f32, 1), r.ink(45, 15), 0.01);
    // Half alpha over white is half ink, because the canvas composites in the
    // device's colour space the way PDF asks it to. Blended in linear light
    // the same fill reads as about 0.26 -- see the pair of cases in
    // `raster.zig` that pin both answers.
    try testing.expectApproxEqAbs(@as(f32, 0.5), inside, 0.02);
}

test "a shading fill is counted rather than half-drawn" {
    const gpa = testing.allocator;
    var r = try Rendered.init(gpa, 40, 40, 1, .{}, struct {
        fn build(b: *Builder) !void {
            try box(b, 5, 5, 35, 35);
            try b.fill(.nonzero, .{ .shading = .{} });
        }
    }.build);
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u32, 1), r.stats.fills);
    try testing.expectEqual(@as(u32, 1), r.stats.unsupported_paint);
    try testing.expect(!r.stats.complete());
    try testing.expect(!r.anyInk());
}

test "the stencil buffer is clean after a whole page" {
    // The page-scale version of the invariant `raster.zig` checks per path. It
    // is the one that decides whether a stencil attachment can be shared, and
    // a failure shows up as a stray shape somewhere unrelated.
    const gpa = testing.allocator;
    var r = try Rendered.init(gpa, 100, 100, 1, .{}, struct {
        fn build(b: *Builder) !void {
            var i: u32 = 0;
            while (i < 20) : (i += 1) {
                const f: f32 = @floatFromInt(i * 4);
                try box(b, f, f, f + 30, f + 30);
                if (i % 3 == 0) {
                    try b.stroke(.{ .width = 2, .join = .round }, .{ .solid = .black }, .identity);
                } else {
                    try b.fill(if (i % 2 == 0) .nonzero else .even_odd, .{ .solid = .gray(0.4) });
                }
            }
        }
    }.build);
    defer r.deinit(gpa);

    try testing.expect(r.canvas.stencilIsClean());
    try testing.expectEqual(@as(u32, 20), r.stats.fills + r.stats.strokes);
    try testing.expect(r.stats.segments > 0);
}

test "an unbalanced clip stack is unwound rather than leaked" {
    const gpa = testing.allocator;
    var r = try Rendered.init(gpa, 40, 40, 1, .{}, struct {
        fn build(b: *Builder) !void {
            try box(b, 0, 0, 20, 20);
            try b.pushClip(.nonzero);
            try box(b, 0, 0, 40, 40);
            try b.fill(.nonzero, .{ .solid = .black });
            // No pop. The builder closes it and sets `unbalanced`.
        }
    }.build);
    defer r.deinit(gpa);

    // PDF (0,0)-(20,20) is image (0,20)-(20,40).
    try testing.expectApproxEqAbs(@as(f32, 1), r.ink(10, 30), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), r.ink(30, 10), 0.01);
}

test "the page transform is a scale and exactly one flip" {
    const page: Bounds = .fromRect(0, 0, 200, 100);
    const t = pageTransform(page, 2);
    // The page bottom-left goes to the image bottom-left.
    const bl = t.apply(.{ .x = 0, .y = 0 });
    try testing.expectApproxEqAbs(@as(f32, 0), bl.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 200), bl.y, 0.001);
    // Its top-right goes to the image top-right.
    const tr = t.apply(.{ .x = 200, .y = 100 });
    try testing.expectApproxEqAbs(@as(f32, 400), tr.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), tr.y, 0.001);
    // A flip is a negative determinant. Two flips would be positive, and would
    // look almost right on a symmetric page.
    try testing.expect(t.determinant() < 0);
    try testing.expectEqual([2]u32{ 400, 200 }, canvasSize(page, 2));
}

test "an inline image is drawn from its own samples, with no image source" {
    const gpa = testing.allocator;
    var r = try Rendered.init(gpa, 60, 60, 1, .{}, struct {
        fn build(b: *Builder) !void {
            // Two grey samples, black then white, over PDF (10,10)-(30,30).
            try b.drawImage(.{
                .transform = .{ .a = 20, .d = 20, .e = 10, .f = 10 },
                .width = 2,
                .height = 1,
                .data = try b.blob(&.{ 0x00, 0xff }),
                .bits_per_component = 8,
                .components = 1,
            });
        }
    }.build);
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u32, 1), r.stats.images_drawn);
    try testing.expect(r.stats.complete());
    // PDF y 10..30 is image y 30..50.
    try testing.expect(r.ink(15, 40) > 0.95);
    try testing.expect(r.ink(25, 40) < 0.05);
    try testing.expect(r.ink(15, 20) < 0.05);
}

test "an inline stencil paints its zeros, or its ones under an inverted decode" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa, .fromRect(0, 0, 10, 10));
    defer b.deinit();
    const img: DisplayList.Image = .{
        .width = 8,
        .height = 1,
        .is_mask = true,
        .data = try b.blob(&.{0b1010_0000}),
    };
    var list = try b.finish();
    defer list.deinit(gpa);

    const plain = (try inlineBitmap(gpa, list, img)).?;
    defer gpa.free(plain);
    try testing.expectEqual(@as(u8, 0), plain[0 * 4 + 3]);
    try testing.expectEqual(@as(u8, 255), plain[1 * 4 + 3]);
    try testing.expectEqual(@as(u8, 255), plain[7 * 4 + 3]);

    var flipped = img;
    flipped.inverted = true;
    const inv = (try inlineBitmap(gpa, list, flipped)).?;
    defer gpa.free(inv);
    try testing.expectEqual(@as(u8, 255), inv[0 * 4 + 3]);
    try testing.expectEqual(@as(u8, 0), inv[1 * 4 + 3]);

    // Too few samples for the size it claims is not an image.
    var short = img;
    short.height = 2;
    try testing.expect((try inlineBitmap(gpa, list, short)) == null);
}

/// A glyph source with one square outline per code, in 1000-unit em space.
const Squares = struct {
    verbs: [5]geom.Verb = .{ .move, .line, .line, .line, .close },
    points: [4]Point = undefined,
    asked: u32 = 0,

    fn source(s: *Squares) GlyphSource {
        return .{ .ptr = s, .lookup = lookup };
    }

    fn lookup(ptr: *anyopaque, font: DisplayList.FontId, g: DisplayList.Glyph) ?GlyphOutline {
        _ = font;
        const s: *Squares = @ptrCast(@alignCast(ptr));
        s.asked += 1;
        // A different square per code, so a cache that confuses two glyphs
        // draws a visibly different shape.
        const w = 200.0 + @as(f32, @floatFromInt(g.code % 4)) * 100.0;
        s.points = .{
            .{ .x = 0, .y = 0 },
            .{ .x = w, .y = 0 },
            .{ .x = w, .y = 700 },
            .{ .x = 0, .y = 700 },
        };
        return .{ .verbs = &s.verbs, .points = &s.points, .units_per_em = 1000 };
    }
};

test "a glyph's outline is recorded once however many times it is drawn" {
    // The page of text this exists for: 3,805 glyphs drawn from a hundred
    // outlines. Before it, each occurrence carried its own flattened copy.
    const gpa = testing.allocator;
    var b: Builder = .init(gpa, .fromRect(0, 0, 200, 100));
    const font = try b.fontId(1, "F1", "Test", false);
    try b.textRun(.{ .font = font, .size = 20, .transform = .translation(5, 20) }, &.{
        .{ .code = 'a', .offset = .{ .x = 0, .y = 0 } },
        .{ .code = 'b', .offset = .{ .x = 20, .y = 0 } },
        .{ .code = 'a', .offset = .{ .x = 40, .y = 0 } },
        .{ .code = 'a', .offset = .{ .x = 60, .y = 0 } },
    });
    var list = try b.finish();
    defer list.deinit(gpa);

    var glyphs: Squares = .{};
    var s: Scene = .{};
    defer s.deinit(gpa);
    s.reset(.{ 200, 100 });
    const stats = try record(gpa, &s, list, pageTransform(list.page, 1), .{
        .glyphs = glyphs.source(),
    });

    try testing.expectEqual(@as(u32, 4), stats.glyphs_drawn);
    // Four instances, two outlines.
    try testing.expectEqual(@as(usize, 4), s.instances.items.len);
    try testing.expectEqual(@as(u32, 2), s.stats.glyph_outlines);
    try testing.expectEqual(@as(usize, 2), s.store.headers.items.len);
    try testing.expectEqual(s.instances.items[0].header, s.instances.items[2].header);
    try testing.expect(s.instances.items[0].header != s.instances.items[1].header);

    // The outline is in em units, so the size is the instance's matrix: a
    // 700-unit tall square at 20pt is 14 device pixels, and the header's box
    // is 0.7 of an em.
    const h = s.store.headers.items[s.instances.items[0].header];
    try testing.expectApproxEqAbs(@as(f32, 0.7), h.max_y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), s.instances.items[0].xform[0], 0.001);

    // And each occurrence sits where the run put it.
    try testing.expectApproxEqAbs(@as(f32, 5), s.instances.items[0].translate[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 45), s.instances.items[2].translate[0], 0.001);
}

test "a recorded image goes into the scene as texels" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa, .fromRect(0, 0, 60, 60));
    try b.drawImage(.{
        .transform = .{ .a = 20, .d = 20, .e = 10, .f = 10 },
        .width = 2,
        .height = 1,
        .data = try b.blob(&.{ 0x00, 0xff }),
        .components = 1,
    });
    var list = try b.finish();
    defer list.deinit(gpa);

    var s: Scene = .{};
    defer s.deinit(gpa);
    s.reset(.{ 60, 60 });
    const stats = try record(gpa, &s, list, pageTransform(list.page, 1), .{});

    try testing.expectEqual(@as(u32, 1), stats.images_drawn);
    try testing.expectEqual(@as(usize, 1), s.images.items.len);
    try testing.expectEqual(@as(usize, 2), s.texels.items.len);
    try testing.expect(s.instances.items[0].flags & @import("slugpipe.zig").flag.image != 0);
}

test "text and images are counted, and drawn only when asked" {
    const gpa = testing.allocator;

    for ([_]bool{ false, true }) |boxes| {
        var r = try Rendered.init(gpa, 60, 60, 1, .{
            .text_boxes = boxes,
            .image_boxes = boxes,
        }, struct {
            fn build(b: *Builder) !void {
                const font = try b.fontId(1, "F1", "Helvetica", false);
                try b.textRun(.{
                    .font = font,
                    .size = 20,
                    .transform = .translation(5, 20),
                }, &.{
                    .{ .code = 'A', .offset = .{ .x = 0, .y = 0 } },
                    .{ .code = 'B', .offset = .{ .x = 12, .y = 0 } },
                });
                try b.drawImage(.{ .transform = .{ .a = 20, .d = 20, .e = 30, .f = 30 } });
            }
        }.build);
        defer r.deinit(gpa);

        try testing.expectEqual(@as(u32, 1), r.stats.text_runs);
        try testing.expectEqual(@as(u32, 2), r.stats.glyphs);
        try testing.expectEqual(@as(u32, 1), r.stats.images);
        // Never complete either way: something on the page was not drawn.
        try testing.expect(!r.stats.complete());
        // With boxes off the page is blank; with them on it is not.
        try testing.expectEqual(boxes, r.anyInk());
    }
}

/// The page `record` and `render` are held to agreeing on: a curved fill, a
/// round-joined stroke and glyphs under two nested clips, one of them
/// diagonal, over a grey ground, and a multiply group across its edge.
fn busyPage(b: *Builder) !void {
    try box(b, 5, 5, 75, 55);
    try b.fill(.nonzero, .{ .solid = .gray(0.8) });

    try box(b, 10, 10, 70, 50);
    try b.pushClip(.nonzero);
    try b.moveTo(.{ .x = 10, .y = 10 });
    try b.lineTo(.{ .x = 70, .y = 10 });
    try b.lineTo(.{ .x = 10, .y = 50 });
    try b.closePath();
    try b.pushClip(.nonzero);

    // A circle, as the four cubics a PDF writes one with.
    const k: f32 = 0.5523 * 18;
    try b.moveTo(.{ .x = 53, .y = 30 });
    try b.curveTo(.{ .x = 53, .y = 30 + k }, .{ .x = 35 + k, .y = 48 }, .{ .x = 35, .y = 48 });
    try b.curveTo(.{ .x = 35 - k, .y = 48 }, .{ .x = 17, .y = 30 + k }, .{ .x = 17, .y = 30 });
    try b.curveTo(.{ .x = 17, .y = 30 - k }, .{ .x = 35 - k, .y = 12 }, .{ .x = 35, .y = 12 });
    try b.curveTo(.{ .x = 35 + k, .y = 12 }, .{ .x = 53, .y = 30 - k }, .{ .x = 53, .y = 30 });
    try b.closePath();
    try b.fill(.nonzero, .{ .solid = .{ .r = 0.8, .g = 0.1, .b = 0.1 } });

    try b.moveTo(.{ .x = 12, .y = 14 });
    try b.lineTo(.{ .x = 40, .y = 40 });
    try b.lineTo(.{ .x = 60, .y = 14 });
    try b.stroke(.{ .width = 3, .join = .round }, .{ .solid = .{ .r = 0.1, .g = 0.2, .b = 0.9 } }, .identity);
    try b.popClip();

    // Past the diagonal, so they show only if the pop restored the outer clip.
    const font = try b.fontId(1, "F1", "Test", false);
    try b.textRun(.{ .font = font, .size = 10, .transform = .translation(46, 38) }, &.{
        .{ .code = 'a', .offset = .{ .x = 0, .y = 0 } },
        .{ .code = 'b', .offset = .{ .x = 6, .y = 0 } },
        .{ .code = 'a', .offset = .{ .x = 12, .y = 0 } },
    });
    try b.popClip();

    try b.pushLayer(.{ .blend = .multiply });
    try box(b, 50, 8, 78, 20);
    try b.fill(.nonzero, .{ .solid = .{ .r = 1, .g = 0.9, .b = 0.2 } });
    try b.popLayer();
}

/// Black stripes under a clip: something for a page to be merged behind, and
/// to draw instead of it if the merge forgets to renumber.
fn stripes(b: *Builder) !void {
    try box(b, 0, 0, 80, 60);
    try b.pushClip(.nonzero);
    for (0..4) |i| {
        const x: f32 = @floatFromInt(i * 20);
        try box(b, x, 0, x + 10, 60);
        try b.fill(.nonzero, .{ .solid = .black });
    }
    try b.popClip();
}

test "a page recorded, merged and placed draws as the same page rendered" {
    // The scene format against the rasteriser, with no device. One side is
    // `record`, a merge behind another page, `Frame.place` and
    // `scene.modelFrame`; the other is `render` through `fillSlug`. Both ask
    // the same curves the same question, so what differs is the format -- a
    // header renumbered wrong, a clip chain the merge broke, a scissor too
    // tight, a composite with the wrong blend state. The one honest
    // difference is along the diagonal clip, which the canvas keeps as a
    // stencil mask and the device computes as coverage.
    const gpa = testing.allocator;

    var pb: Builder = .init(gpa, .fromRect(0, 0, 80, 60));
    try busyPage(&pb);
    var list = try pb.finish();
    defer list.deinit(gpa);
    var ob: Builder = .init(gpa, .fromRect(0, 0, 80, 60));
    try stripes(&ob);
    var other_list = try ob.finish();
    defer other_list.deinit(gpa);

    const at: Transform = .translation(3, 2);
    const page_xform = pageTransform(list.page, 1);
    var glyphs: Squares = .{};

    // Linear light, which is what the device blends in.
    var canvas: Canvas = try .init(gpa, 90, 70, .{ .samples = .eight, .space = .linear });
    defer canvas.deinit(gpa);
    canvas.fb.clear(.white);
    const rendered = try render(gpa, &canvas, list, page_xform.concat(at), .{
        .path_backend = .slug,
        .glyphs = glyphs.source(),
    });

    var shared: Scene = .{};
    defer shared.deinit(gpa);
    shared.reset(.{ 1, 1 });
    var other: Scene = .{};
    defer other.deinit(gpa);
    other.reset(.{ 80, 60 });
    _ = try record(gpa, &other, other_list, page_xform, .{});
    _ = try shared.merge(gpa, other);

    var page: Scene = .{};
    defer page.deinit(gpa);
    page.reset(.{ 80, 60 });
    const recorded = try record(gpa, &page, list, page_xform, .{ .glyphs = glyphs.source() });
    const range = try shared.merge(gpa, page);
    try testing.expect(range.first_instance > 0 and range.first_clip > 0);

    var frame: scene_mod.Frame = .{};
    defer frame.deinit(gpa);
    try frame.place(gpa, shared, range, at, .{ 0, 0, 90, 70 });

    var fb = try software.Framebuffer.init(gpa, 90, 70, .linear);
    defer fb.deinit(gpa);
    fb.clear(.white);
    const drawn = scene_mod.modelFrame(&fb, shared, frame);

    try testing.expectEqual(@as(u32, 3), rendered.glyphs_drawn);
    try testing.expectEqual(rendered.glyphs_drawn, recorded.glyphs_drawn);
    try testing.expectEqual(page.instanceCount(), drawn.paths);
    try testing.expectEqual(@as(u32, 0), page.stats.blended);

    // Every pixel that differs is on the diagonal: (10, 50) to (70, 10) on
    // the page, which is (13, 12) to (73, 52) here.
    var worst: f32 = 0;
    for (0..fb.height) |y| {
        for (0..fb.width) |x| {
            const i = (y * fb.width + x) * 4;
            var d: f32 = 0;
            for (0..4) |c| d = @max(d, @abs(canvas.fb.pixels[i + c] - fb.pixels[i + c]));
            if (d <= 1e-4) continue;
            worst = @max(worst, d);
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const off_line = @abs(40 * (px - 13) - 60 * (py - 12)) / @sqrt(@as(f32, 60 * 60 + 40 * 40));
            try testing.expect(off_line < 1.5);
        }
    }
    // Eight samples against the exact area: 0.14 measured.
    try testing.expect(worst < 0.2);
}

/// How far apart the two backends drew one page: per pixel, and in how much
/// ink each put down in all.
const Agreement = struct {
    pixels: software.Difference,
    /// The analytic backend's ink over the stencil's, less one.
    ink: f64,
};

/// One page through each backend, onto canvases alike in everything else.
fn backendsDiffer(
    gpa: Allocator,
    scale: f32,
    options: Options,
    build: *const fn (*Builder) anyerror!void,
) !Agreement {
    var opts = options;
    opts.path_backend = .stencil;
    var stencil = try Rendered.initOn(gpa, .{}, 60, 60, scale, opts, build);
    defer stencil.deinit(gpa);
    try testing.expect(stencil.anyInk());

    opts.path_backend = .slug;
    var analytic = try Rendered.initOn(gpa, .{}, 60, 60, scale, opts, build);
    defer analytic.deinit(gpa);
    return .{
        .pixels = software.Difference.of(stencil.canvas.fb, analytic.canvas.fb).?,
        .ink = analytic.totalInk() / stencil.totalInk() - 1,
    };
}

fn circle(b: *Builder) !void {
    const k: f32 = 0.5523 * 22;
    try b.moveTo(.{ .x = 52, .y = 30 });
    try b.curveTo(.{ .x = 52, .y = 30 + k }, .{ .x = 30 + k, .y = 52 }, .{ .x = 30, .y = 52 });
    try b.curveTo(.{ .x = 30 - k, .y = 52 }, .{ .x = 8, .y = 30 + k }, .{ .x = 8, .y = 30 });
    try b.curveTo(.{ .x = 8, .y = 30 - k }, .{ .x = 30 - k, .y = 8 }, .{ .x = 30, .y = 8 });
    try b.curveTo(.{ .x = 30 + k, .y = 8 }, .{ .x = 52, .y = 30 - k }, .{ .x = 52, .y = 30 });
    try b.closePath();
    try b.fill(.nonzero, .{ .solid = .black });
}

fn zigzag(b: *Builder) !void {
    try b.moveTo(.{ .x = 6, .y = 10 });
    try b.lineTo(.{ .x = 18, .y = 50 });
    try b.lineTo(.{ .x = 30, .y = 12 });
    try b.curveTo(.{ .x = 36, .y = 30 }, .{ .x = 44, .y = 52 }, .{ .x = 54, .y = 40 });
    try b.stroke(.{ .width = 4, .join = .round, .cap = .round }, .{ .solid = .black }, .identity);
}

fn words(b: *Builder) !void {
    const font = try b.fontId(1, "F1", "Test", false);
    try b.textRun(.{ .font = font, .size = 11, .transform = .translation(4.3, 30.6) }, &.{
        .{ .code = 'a', .offset = .{ .x = 0, .y = 0 } },
        .{ .code = 'b', .offset = .{ .x = 6.2, .y = 0 } },
        .{ .code = 'c', .offset = .{ .x = 12.7, .y = 0 } },
        .{ .code = 'd', .offset = .{ .x = 19.1, .y = 0 } },
        .{ .code = 'a', .offset = .{ .x = 25.5, .y = 0 } },
        .{ .code = 'c', .offset = .{ .x = 33.4, .y = 0 } },
        .{ .code = 'd', .offset = .{ .x = 40.8, .y = 0 } },
    });
}

test "the stencil and analytic backends draw a curve, a stroke and glyphs alike" {
    // `raster --path both` on shapes small enough that every pixel is near
    // an edge, which is the hard case for the mean.
    //
    // The worst single pixel is not bounded, because each backend is wrong
    // somewhere by up to half a pixel: eight samples quantise an edge, and
    // the analytic one's two rays are approximate at a corner (0.25 against
    // 0), on an edge near 45 degrees (0.5 against 0.8), and where the
    // stroker's overlapping pieces meet an edge, which it counts twice (0.5
    // against 1.0 on the zigzag). What is bounded is that those stay a few
    // pixels, and that no shape moved or changed its area.
    const gpa = testing.allocator;
    var glyphs: Squares = .{};
    for ([_]*const fn (*Builder) anyerror!void{ circle, zigzag, words }) |build| {
        // Measured, at 1x then 3x: means of 0.72, 1.51 and 0.49 levels and
        // 0.24, 0.51 and 0.13; 3.0, 5.1 and 2.0% of pixels over 8 levels
        // and 0.9, 1.7 and 0.7%; ink within 1.9% (the stroke) and 0.6%.
        for ([_]f32{ 1, 3 }, [_]f64{ 2, 0.75 }, [_]f64{ 7, 2.5 }, [_]f64{ 0.03, 0.01 }) |scale, mean, over_8, ink| {
            const a = try backendsDiffer(gpa, scale, .{ .glyphs = glyphs.source() }, build);
            try testing.expect(a.pixels.mean() < mean);
            try testing.expect(a.pixels.percent(a.pixels.over_8) < over_8);
            try testing.expect(@abs(a.ink) < ink);
        }
    }
}

test "a clip past max_clip_depth is counted, and what it would have hidden is drawn" {
    const gpa = testing.allocator;
    for ([_]PathBackend{ .stencil, .slug }) |backend| {
        var r = try Rendered.init(gpa, 40, 40, 1, .{ .max_clip_depth = 1, .path_backend = backend }, struct {
            fn build(b: *Builder) !void {
                try box(b, 0, 0, 40, 40);
                try b.pushClip(.nonzero);
                try box(b, 0, 0, 20, 40);
                try b.pushClip(.nonzero);
                try box(b, 0, 0, 40, 40);
                try b.fill(.nonzero, .{ .solid = .black });
                try b.popClip();
                try b.popClip();
                // Balanced still: the dropped clip's pop did not take the
                // first one with it, so this is clipped by nothing.
                try box(b, 0, 0, 40, 40);
                try b.fill(.nonzero, .{ .solid = .black });
            }
        }.build);
        defer r.deinit(gpa);

        try testing.expectEqual(@as(u32, 2), r.stats.clips);
        try testing.expectEqual(@as(u32, 1), r.stats.clips_dropped);
        try testing.expect(!r.stats.complete());
        // Right of the dropped clip's edge: drawn, which is too much.
        try testing.expectApproxEqAbs(@as(f32, 1), r.ink(30, 20), 0.01);
        try testing.expectApproxEqAbs(@as(f32, 1), r.ink(10, 20), 0.01);
    }
}

test "a hairline is one device pixel of ink at any zoom" {
    // Width zero is the thinnest line the device can draw (§8.4.3.2), so it
    // is resolved against the whole matrix and a zoom does not fatten it.
    // The GPU path resolves it once, when the page is recorded, and does
    // fatten it: F1 in OPTIMIZING.md.
    const gpa = testing.allocator;
    for ([_]f32{ 1, 4 }) |scale| {
        for ([_]PathBackend{ .stencil, .slug }) |backend| {
            var r = try Rendered.initOn(gpa, .{}, 40, 40, scale, .{ .path_backend = backend }, struct {
                fn build(b: *Builder) !void {
                    try b.moveTo(.{ .x = 5, .y = 20.3 });
                    try b.lineTo(.{ .x = 35, .y = 20.3 });
                    try b.stroke(.{ .width = 0 }, .{ .solid = .black }, .identity);
                }
            }.build);
            defer r.deinit(gpa);

            // Summed down one column, which is the line's width in pixels.
            const x: u32 = @intFromFloat(20 * scale);
            var ink: f32 = 0;
            for (0..r.canvas.height()) |y| ink += r.ink(x, @intCast(y));
            try testing.expectApproxEqAbs(@as(f32, 1), ink, 0.02);
        }
    }
}
