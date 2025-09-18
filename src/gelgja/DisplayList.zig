//! The display list: what Gjöll's interpreter produces and Gleipnir consumes.
//!
//! Gelgja is the cord threaded through the rock, and it knows nothing about
//! either end. There is no import of the PDF layer here and no import of any
//! graphics API; a display list is a self-contained recording of drawing
//! operations that can be built, inspected, diffed, and replayed with neither
//! a document nor a GPU present.
//!
//! Three decisions are worth stating, because they are the ones that would be
//! painful to change later:
//!
//! **Curves are not flattened.** Subdividing a Bézier needs a tolerance in
//! device pixels, which depends on the zoom. A list that has been flattened
//! must be rebuilt every time the user scrolls a wheel; one that keeps its
//! cubics is built once per page and replayed at any scale.
//!
//! **The CTM is baked into path points, but strokes still carry it.** Fills
//! only need geometry. Strokes do not: the pen is a circle in *user* space, so
//! a non-uniform matrix makes it an ellipse, and a zero width means "as thin
//! as the device can draw". Neither is recoverable from device-space points
//! alone, so `stroke_path` keeps the matrix that produced it.
//!
//! **Everything is stored in flat shared arrays, addressed by `Range`.** A
//! page with ten thousand small paths is one allocation per array rather than
//! ten thousand, and the whole list is contiguous, copyable, and trivially
//! serialisable.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("geom.zig");
const paint = @import("paint.zig");

const Bounds = geom.Bounds;
const FillRule = geom.FillRule;
const Point = geom.Point;
const Range = geom.Range;
const Transform = geom.Transform;
const Verb = geom.Verb;

const Layer = paint.Layer;
const ObjectId = paint.ObjectId;
const Paint = paint.Paint;
const Stroke = paint.Stroke;
const TextRenderMode = paint.TextRenderMode;

const DisplayList = @This();

cmds: []const DrawCmd = &.{},
verbs: []const Verb = &.{},
points: []const Point = &.{},
glyphs: []const Glyph = &.{},
/// Backing store for dash patterns and any other small float array.
scalars: []const f32 = &.{},
fonts: []const FontInfo = &.{},
/// Interned strings: marked-content tags and resource names.
strings: []const u8 = &.{},

/// The page box this list was recorded against, so a backend can build its
/// device transform without consulting the document.
page: Bounds = .empty,

/// Set when the recording ended with clips or layers still open, meaning the
/// producer emitted unbalanced `q`/`Q` -- common in damaged files. The builder
/// closes them and records that it had to.
unbalanced: bool = false,

/// A path, as a pair of spans into the list's shared arrays.
pub const Path = struct {
    verbs: Range = .empty,
    points: Range = .empty,

    pub fn isEmpty(p: Path) bool {
        return p.verbs.count == 0;
    }
};

/// A reference to a font, resolved by Týr when it exists. Interned in the
/// list's font table because a page shares a handful of fonts across hundreds
/// of runs.
pub const FontInfo = struct {
    /// The `/Font` resource name it was selected with, e.g. `F1`. A span into
    /// `strings`.
    name: Range = .empty,
    /// `/BaseFont`, e.g. `ABCDEF+Helvetica`. A span into `strings`.
    base_font: Range = .empty,
    /// The font dictionary, for the font layer to load.
    object: ObjectId = paint.no_object,
    /// True for `/Type0`: codes are multi-byte and map through a CMap.
    composite: bool = false,
};

pub const FontId = u32;

/// One positioned glyph within a run.
pub const Glyph = struct {
    /// The character code exactly as it appeared in the content stream: one
    /// byte for a simple font, usually two for `/Identity-H`. Kept alongside
    /// the glyph id because it is the only thing meaningful before the font
    /// layer exists, and because text extraction needs it either way.
    code: u32 = 0,
    /// Index into the font program. `unresolved` until Týr fills it in.
    id: u16 = unresolved_glyph,
    /// Position relative to the run origin, in text space.
    offset: Point = .origin,

    pub const unresolved_glyph: u16 = 0xffff;
};

/// A run of glyphs sharing one font, matrix, and paint -- the natural unit,
/// because that is exactly what one `Tj` or `TJ` operator produces.
pub const TextRun = struct {
    font: FontId = 0,
    /// Text space to page space: the text matrix times the CTM, *without* the
    /// font size folded in. A glyph is placed by taking its `offset`, scaling
    /// glyph-space units by `size`, and applying this.
    transform: Transform = .identity,
    /// `Tf` size, in text space units.
    size: f32 = 0,
    mode: TextRenderMode = .fill,
    fill: Paint = .{ .solid = .black },
    /// Present only when `mode` strokes.
    stroke: ?Stroke = null,
    glyphs: Range = .empty,
};

pub const Image = struct {
    object: ObjectId = paint.no_object,
    /// Resource name, e.g. `Im1`. A span into `strings`.
    name: Range = .empty,
    width: u32 = 0,
    height: u32 = 0,
    /// The unit square to page space. PDF maps every image into `[0,1]²` and
    /// leaves the CTM to place and scale it (§8.9.5), so this matrix is the
    /// entire geometry of the draw.
    transform: Transform = .identity,
    /// `/ImageMask`: a 1-bit stencil painted with `fill` rather than an image
    /// with colours of its own.
    is_mask: bool = false,
    /// Only meaningful when `is_mask`.
    fill: Paint = .{ .solid = .black },
    /// `/Interpolate`, a hint that the image should be smoothed when scaled up.
    interpolate: bool = false,
};

/// One drawing operation.
///
/// Clips and layers are push/pop pairs rather than state carried on every
/// command: a backend keeps its own stack, which is how both stencil buffers
/// and mask textures want to work anyway.
///
/// `B` and its variants -- fill *and* stroke the same path -- record two
/// commands sharing one path range. Duplicating a range costs eight bytes and
/// saves every backend from a third code path.
pub const DrawCmd = union(enum) {
    fill_path: struct {
        path: Path,
        rule: FillRule,
        paint: Paint,
    },
    stroke_path: struct {
        path: Path,
        stroke: Stroke,
        paint: Paint,
        /// The matrix the path was recorded under. Needed to recover the pen
        /// ellipse and to resolve a zero width; see the note at the top.
        ctm: Transform,
    },
    /// Intersects the clip with `path` until the matching `clip_pop`.
    clip_push: struct {
        path: Path,
        rule: FillRule,
    },
    clip_pop,
    text: TextRun,
    image: Image,
    /// The `sh` operator: paint a shading across the whole current clip.
    shading: paint.Shading,
    /// A transparency group.
    layer_push: Layer,
    layer_pop,
    /// `BDC`/`BMC`. Carries no rendering meaning; a backend uses it for
    /// optional content groups, and a redaction or accessibility pass uses it
    /// for structure. A span into `strings`.
    marked_begin: Range,
    marked_end,

    pub fn name(c: DrawCmd) []const u8 {
        return @tagName(c);
    }
};

// -- accessors --------------------------------------------------------------

pub fn verbsOf(l: DisplayList, path: Path) []const Verb {
    return path.verbs.slice(l.verbs);
}

pub fn pointsOf(l: DisplayList, path: Path) []const Point {
    return path.points.slice(l.points);
}

pub fn glyphsOf(l: DisplayList, run: TextRun) []const Glyph {
    return run.glyphs.slice(l.glyphs);
}

pub fn dashOf(l: DisplayList, stroke: Stroke) []const f32 {
    return stroke.dash.slice(l.scalars);
}

pub fn fontOf(l: DisplayList, id: FontId) FontInfo {
    return if (id < l.fonts.len) l.fonts[id] else .{};
}

pub fn stringOf(l: DisplayList, r: Range) []const u8 {
    return r.slice(l.strings);
}

/// Control-point bounds, which for a cubic is conservative: the curve lies
/// inside its control hull but may not touch it. Exact bounds need the
/// derivative roots, and no caller so far needs the tightness.
pub fn pathBounds(l: DisplayList, path: Path) Bounds {
    var b: Bounds = .empty;
    for (l.pointsOf(path)) |p| b = b.add(p);
    return b;
}

/// The union of every painted command's bounds. Ignores clipping, so it is an
/// upper bound on what a page can mark.
pub fn contentBounds(l: DisplayList) Bounds {
    var b: Bounds = .empty;
    for (l.cmds) |cmd| {
        b = b.unionWith(switch (cmd) {
            .fill_path => |c| l.pathBounds(c.path),
            .stroke_path => |c| l.pathBounds(c.path),
            .image => |c| imageBounds(c),
            // Text bounds need glyph metrics, which live in the font layer.
            else => continue,
        });
    }
    return b;
}

fn imageBounds(img: Image) Bounds {
    var b: Bounds = .empty;
    const corners = [_]Point{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 },
    };
    for (corners) |c| b = b.add(img.transform.apply(c));
    return b;
}

pub const Stats = struct {
    fills: u32 = 0,
    strokes: u32 = 0,
    clips: u32 = 0,
    text_runs: u32 = 0,
    glyphs: u32 = 0,
    images: u32 = 0,
    shadings: u32 = 0,
    layers: u32 = 0,
    /// Total path segments across every recorded path.
    verbs: u32 = 0,
};

pub fn stats(l: DisplayList) Stats {
    var s: Stats = .{ .verbs = @intCast(l.verbs.len), .glyphs = @intCast(l.glyphs.len) };
    for (l.cmds) |cmd| switch (cmd) {
        .fill_path => s.fills += 1,
        .stroke_path => s.strokes += 1,
        .clip_push => s.clips += 1,
        .text => s.text_runs += 1,
        .image => s.images += 1,
        .shading => s.shadings += 1,
        .layer_push => s.layers += 1,
        else => {},
    };
    return s;
}

pub fn deinit(l: *DisplayList, gpa: Allocator) void {
    gpa.free(l.cmds);
    gpa.free(l.verbs);
    gpa.free(l.points);
    gpa.free(l.glyphs);
    gpa.free(l.scalars);
    gpa.free(l.fonts);
    gpa.free(l.strings);
    l.* = .{};
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "an empty list is well formed" {
    const l: DisplayList = .{};
    try testing.expectEqual(@as(usize, 0), l.cmds.len);
    try testing.expect(l.contentBounds().isEmpty());
    try testing.expectEqual(@as(u32, 0), l.stats().fills);
}

test "path accessors resolve ranges" {
    const verbs = [_]Verb{ .move, .line, .close };
    const points = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 20 } };
    const l: DisplayList = .{ .verbs = &verbs, .points = &points };

    const path: Path = .{
        .verbs = .{ .start = 0, .count = 3 },
        .points = .{ .start = 0, .count = 2 },
    };
    try testing.expectEqual(@as(usize, 3), l.verbsOf(path).len);
    try testing.expectEqual(Verb.close, l.verbsOf(path)[2]);

    const b = l.pathBounds(path);
    try testing.expectEqual(@as(f32, 10), b.width());
    try testing.expectEqual(@as(f32, 20), b.height());
}

test "image bounds come from the unit square through the matrix" {
    const img: Image = .{
        .width = 100,
        .height = 50,
        // Images are placed entirely by the CTM: this one covers a 200x100
        // area at (72, 700).
        .transform = Transform.scaling(200, 100).concat(.translation(72, 700)),
    };
    const b = imageBounds(img);
    try testing.expectApproxEqAbs(@as(f32, 72), b.min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 700), b.min_y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 200), b.width(), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), b.height(), 1e-4);
}
