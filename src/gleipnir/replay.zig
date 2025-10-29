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
//! * **Images.** No image decoder yet. `Options.image_boxes` outlines them.
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
const stroke = @import("stroke.zig");

const Bounds = geom.Bounds;
const Canvas = raster.Canvas;
const Color = paint.Color;
const FillRule = geom.FillRule;
const Point = geom.Point;
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

pub const Options = struct {
    /// How far a flattened segment may stray from its curve, in device pixels.
    tolerance: f32 = 0.1,
    /// Where glyph outlines come from. Without one, text is counted and not
    /// drawn.
    glyphs: ?GlyphSource = null,
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
};

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
        return s.unsupported_paint == 0 and s.images == 0 and s.shadings == 0 and
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
    var r: Replayer = .{
        .gpa = gpa,
        .canvas = canvas,
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
    canvas: *Canvas,
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

    /// One entry per open clip, so `clip_pop` knows whether its `clip_push`
    /// actually took effect.
    clip_stack: std.ArrayList(bool) = .empty,
    /// Constant alpha, multiplied down by every open transparency group.
    alpha: f32 = 1,
    /// What a `layer_push` saved, restored by its `layer_pop`. One stack
    /// rather than two, so a failed append cannot leave them disagreeing
    /// about how deep the nesting is.
    alpha_stack: std.ArrayList(SavedLayer) = .empty,

    fn deinit(r: *Replayer) void {
        r.flat.deinit(r.gpa);
        r.outline.deinit(r.gpa);
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

        const flat = r.flatten(p) orelse return;
        try r.paintFlattened(flat, rule, color);
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
        if (flat.isEmpty()) return;
        var m = try path.mesh(r.gpa, flat);
        defer m.deinit(r.gpa);
        r.canvas.fill(m, r.base, rule, color, r.alpha);
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

        var m = try path.mesh(r.gpa, outlined);
        defer m.deinit(r.gpa);
        // A stroke's outline is always nonzero: the rule is how the stamped
        // pieces are unioned, not a property of the path. See `stroke.zig`.
        r.canvas.fill(m, to_device, .nonzero, color, r.alpha);
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

        var m = try path.mesh(r.gpa, flat);
        defer m.deinit(r.gpa);
        try r.canvas.pushClip(r.gpa, m, r.base, rule);
        try r.clip_stack.append(r.gpa, true);
    }

    fn popClip(r: *Replayer) void {
        const pushed = r.clip_stack.pop() orelse return;
        if (pushed) r.canvas.popClip(r.gpa);
    }

    // -- groups -------------------------------------------------------------

    fn pushLayer(r: *Replayer, l: paint.Layer) Error!void {
        r.stats.layers += 1;
        try r.alpha_stack.append(r.gpa, .{ .alpha = r.alpha, .blend = r.canvas.blend_mode });
        r.alpha *= std.math.clamp(l.alpha, 0, 1);
        // The innermost mode that is not `normal` wins. A group composites
        // into its parent with its own mode and its *contents* are drawn
        // normally inside it -- so with the group folded into its contents
        // the way this does, a nested plain group must not cancel the
        // multiply an enclosing one asked for.
        if (l.blend != .normal) r.canvas.blend_mode = l.blend;
    }

    fn popLayer(r: *Replayer) void {
        const saved: SavedLayer = r.alpha_stack.pop() orelse .{ .alpha = 1, .blend = .normal };
        r.alpha = saved.alpha;
        r.canvas.blend_mode = saved.blend;
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

            var m = try path.mesh(r.gpa, flat);
            defer m.deinit(r.gpa);
            // Glyph outlines are always nonzero. TrueType and CFF both wind
            // counters the opposite way from the outer contour, which is what
            // makes the hole in an `o` a hole under this rule and under no
            // other -- even-odd would agree here and disagree the moment two
            // contours of a script face overlap.
            r.canvas.fill(m, to_device, .nonzero, color, r.alpha);
        }
    }

    fn image(r: *Replayer, img: DisplayList.Image) Error!void {
        r.stats.images += 1;
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

fn solid(p: paint.Paint) ?Color {
    return switch (p) {
        .solid => |c| c,
        else => null,
    };
}


// -- tests ------------------------------------------------------------------

const testing = std.testing;
const Builder = @import("../gelgja/Builder.zig");

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
        var b: Builder = .init(gpa, .fromRect(0, 0, w, h));
        errdefer b.deinit();
        try build(&b);
        const list = try b.finish();

        const size = canvasSize(list.page, scale);
        var canvas: Canvas = try .init(gpa, size[0], size[1], .{ .samples = .one });
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
