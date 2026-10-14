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
/// Sample data for inline images. See `Image.data` for why this pool exists
/// and why nothing else lives in it.
bytes: []const u8 = &.{},
/// Every font's code-to-Unicode spans, end to end; a `FontInfo.unicode`
/// range picks out the one font's.
unicode: []const UnicodeSpan = &.{},
/// The UTF-8 those spans point into. A pool of its own for the reason
/// `bytes` has one: a range that has gone wrong must not hand a caller a
/// resource name where it expected a letter.
unicode_text: []const u8 = &.{},

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
    /// This font's span of `unicode`, sorted by `low`. Empty when nothing in
    /// the document says what its codes mean.
    unicode: Range = .empty,
};

/// The most UTF-8 one character code can stand for. A `/ToUnicode`
/// destination is a UTF-16BE *string*, not a code point, because a code can
/// be a ligature -- `ffi` is three -- or a letter with its accent spelled
/// out after it.
pub const max_unicode = 32;

/// What a range of character codes means, in UTF-8.
///
/// Per font and not per glyph, which is the decision worth stating. A `Glyph`
/// is sixteen bytes and a page carries tens of thousands of them, so a code
/// point on each would grow the busiest array in the list by a quarter to
/// repeat what a few dozen spans say once -- and every pass over the glyphs
/// pays for that, not only the extraction that wanted it. A subsetted font's
/// whole map is one span per code it uses; a CJK font's is one per `bfrange`.
pub const UnicodeSpan = struct {
    /// The lowest code this span maps.
    low: u32 = 0,
    /// The highest, inclusive.
    high: u32 = 0,
    /// Where `low`'s text begins in `unicode_text`, and how long it is.
    at: u32 = 0,
    len: u16 = 0,
    /// A `bfrange` with a string destination: a code's distance from `low` is
    /// added to the *last* code point of that string (§9.10.3). False for a
    /// `bfchar`, and for one entry of a `bfrange` array, where `low` equals
    /// `high` and there is nothing to shift.
    step: bool = false,
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
    /// Where the pen finished, in the space `Glyph.offset` is measured in:
    /// the run's whole advance, the spacing after its last glyph included.
    ///
    /// Here because the last glyph of a run has no next glyph to be measured
    /// against, and it is the one a selection ends on. Guessing a width for
    /// it -- which is what `hlidskjalf.text` did -- makes the right-hand edge
    /// of a selection over a justified paragraph ragged by however much each
    /// line's final letter differs from the guess. The interpreter already
    /// has the number, since it is what advanced the text matrix, so this is
    /// one float per run rather than a measurement.
    ///
    /// Zero means nobody said, and the guess is what happens.
    advance: f32 = 0,
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

    /// An inline image's samples, a span into `bytes`, already through its
    /// filter chain.
    ///
    /// An `Image` normally carries only an `object` and lets the backend fetch
    /// the pixels, which keeps a page of photographs from being copied into
    /// the display list. An inline image (`BI ... ID ... EI`) has no object to
    /// fetch: it exists only inside the content stream that has already been
    /// consumed. So its samples are copied here, and the whole list stays
    /// replayable with no document -- which is the property the rest of Gelgja
    /// is built on. They are small by construction: §8.9.7 limits an inline
    /// image to four kilobytes of data.
    data: Range = .empty,
    /// Only meaningful when `data` is non-empty.
    bits_per_component: u8 = 8,
    components: u8 = 1,
    /// `/Decode [1 0]`: the samples run the other way. Common on stencil
    /// masks, where it is the difference between a shape and its negative.
    inverted: bool = false,

    /// True for an image whose pixels are in the list rather than in the
    /// document.
    pub fn isInline(img: Image) bool {
        return !img.data.isEmpty();
    }
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

pub fn bytesOf(l: DisplayList, r: Range) []const u8 {
    return r.slice(l.bytes);
}

/// What one character code of one font means, written into `buf`.
///
/// Empty when nothing knows: a composite font with no `/ToUnicode` addresses
/// its glyphs by a CID whose meaning is in an external character collection,
/// and guessing there would put Latin letters through a page of Japanese.
///
/// `buf` rather than a returned slice because this is called once per glyph
/// of a page and a shifted `bfrange` entry has to be *built* -- the text for
/// code `low + 3` is nowhere in the pool. One stack buffer in the caller's
/// loop is the shape that costs nothing.
pub fn unicodeFor(l: DisplayList, font: FontId, code: u32, buf: *[max_unicode]u8) []const u8 {
    const info = l.fontOf(font);
    const mapped = unicodeIn(info.unicode.slice(l.unicode), l.unicode_text, code, buf);
    if (mapped.len != 0) return mapped;

    // Nothing mapped it. A simple font's codes are bytes and the printable
    // ASCII range means itself under all three standard encodings, so this
    // recovers the usual case for a list built without a font table at all --
    // which is every test of the layer above, and a page whose font
    // dictionary would not resolve.
    if (info.composite or code < 0x20 or code >= 0x7f) return &.{};
    buf[0] = @intCast(code);
    return buf[0..1];
}

/// The lookup on its own, over a span list that is not in a display list yet.
/// The PDF layer builds one font's map with this before handing it over, and
/// it is where the whole meaning of `step` lives.
pub fn unicodeIn(
    spans: []const UnicodeSpan,
    pool: []const u8,
    code: u32,
    buf: *[max_unicode]u8,
) []const u8 {
    const s = findSpan(spans, code) orelse return &.{};
    const from = @min(s.at, pool.len);
    const stored = pool[from..][0..@min(s.len, pool.len - from)];
    return shift(stored, if (s.step) code - s.low else 0, buf);
}

/// The span containing `code`, by binary search: spans are sorted by `low`
/// and a CJK font's `/ToUnicode` runs to thousands of them.
fn findSpan(spans: []const UnicodeSpan, code: u32) ?UnicodeSpan {
    var lo: usize = 0;
    var hi: usize = spans.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (spans[mid].low <= code) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const s = spans[lo - 1];
    return if (code <= s.high) s else null;
}

/// `text` with its last code point moved on by `delta`, copied into `buf`.
fn shift(text: []const u8, delta: u32, buf: *[max_unicode]u8) []const u8 {
    const n = @min(text.len, max_unicode);
    @memcpy(buf[0..n], text[0..n]);
    if (delta == 0 or n == 0) return buf[0..n];

    // Back up over the continuation bytes to the last code point's first.
    var start = n;
    while (start > 0 and (buf[start - 1] & 0xc0) == 0x80) start -= 1;
    if (start == 0) return buf[0..n];
    start -= 1;

    const cp = std.unicode.utf8Decode(buf[start..n]) catch return buf[0..n];
    const moved = @as(u32, cp) + delta;
    // A range that runs off the end of Unicode, or through the surrogates,
    // is a malformed CMap. Keep the unshifted text rather than nothing: it is
    // wrong for every code but the first, and nothing is wrong for all of
    // them.
    if (moved > 0x10ffff or (moved >= 0xd800 and moved <= 0xdfff)) return buf[0..n];
    const len = std.unicode.utf8Encode(@intCast(moved), buf[start..]) catch return buf[0..n];
    return buf[0 .. start + len];
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
    gpa.free(l.bytes);
    gpa.free(l.unicode);
    gpa.free(l.unicode_text);
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

test "a stepping span moves the last code point along with the code" {
    // `<0041> <0043> <0061>`: codes 0x41..0x43 mean a, b, c.
    const spans = [_]UnicodeSpan{
        .{ .low = 0x41, .high = 0x43, .at = 0, .len = 1, .step = true },
    };
    var buf: [max_unicode]u8 = undefined;
    try testing.expectEqualStrings("a", unicodeIn(&spans, "a", 0x41, &buf));
    try testing.expectEqualStrings("c", unicodeIn(&spans, "a", 0x43, &buf));
    // Outside the span is nothing, not the nearest neighbour.
    try testing.expectEqualStrings("", unicodeIn(&spans, "a", 0x44, &buf));
}

test "a ligature keeps every code point, and only the last one steps" {
    // The trap a code point per glyph would have walked into: `fi` is one
    // code and two letters, and a search for "fill" has to find it.
    const spans = [_]UnicodeSpan{
        .{ .low = 1, .high = 2, .at = 0, .len = 2, .step = true },
    };
    var buf: [max_unicode]u8 = undefined;
    try testing.expectEqualStrings("fi", unicodeIn(&spans, "fi", 1, &buf));
    try testing.expectEqualStrings("fj", unicodeIn(&spans, "fi", 2, &buf));
}

test "an unmapped code in a simple font falls back to ASCII, and in a CID font does not" {
    // A list built with no font table at all -- which is every test of the
    // layer above -- still reads as text.
    const l: DisplayList = .{};
    var buf: [max_unicode]u8 = undefined;
    try testing.expectEqualStrings("A", l.unicodeFor(0, 'A', &buf));

    // A composite font's codes are CIDs into a character collection this
    // program does not have. CID 65 is not `A`, and saying it is would read
    // a page of Japanese as Latin.
    const fonts = [_]FontInfo{.{ .composite = true }};
    const cid: DisplayList = .{ .fonts = &fonts };
    try testing.expectEqualStrings("", cid.unicodeFor(0, 'A', &buf));
}

test "a span list is searched, not scanned, so the order it was built in is irrelevant" {
    const spans = [_]UnicodeSpan{
        .{ .low = 10, .high = 10, .at = 0, .len = 1 },
        .{ .low = 20, .high = 29, .at = 1, .len = 1, .step = true },
        .{ .low = 40, .high = 40, .at = 2, .len = 1 },
    };
    var buf: [max_unicode]u8 = undefined;
    try testing.expectEqualStrings("x", unicodeIn(&spans, "xAz", 10, &buf));
    try testing.expectEqualStrings("A", unicodeIn(&spans, "xAz", 20, &buf));
    try testing.expectEqualStrings("J", unicodeIn(&spans, "xAz", 29, &buf));
    try testing.expectEqualStrings("", unicodeIn(&spans, "xAz", 30, &buf));
    try testing.expectEqualStrings("z", unicodeIn(&spans, "xAz", 40, &buf));
}
