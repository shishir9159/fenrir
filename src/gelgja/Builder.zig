//! Records a `DisplayList`.
//!
//! The API deliberately mirrors the content-stream operators, so that the
//! interpreter is a translation rather than a design: you build a path with
//! `moveTo`/`lineTo`/`curveTo`/`rect`, and then exactly one painting call
//! consumes it, the same way `m l c re` accumulate and `f S B n` consume.
//!
//! Damage tolerance matches the rest of the codebase. A recording that ends
//! with clips or layers still open -- unbalanced `q`/`Q`, which is common --
//! is closed out and flagged rather than rejected. A painting operator with no
//! current path records nothing instead of erroring.

const std = @import("std");
const Allocator = std.mem.Allocator;

const DisplayList = @import("DisplayList.zig");
const geom = @import("geom.zig");
const paint = @import("paint.zig");

const Bounds = geom.Bounds;
const FillRule = geom.FillRule;
const Point = geom.Point;
const Range = geom.Range;
const Transform = geom.Transform;
const Verb = geom.Verb;

const DrawCmd = DisplayList.DrawCmd;
const FontId = DisplayList.FontId;
const FontInfo = DisplayList.FontInfo;
const Glyph = DisplayList.Glyph;
const Image = DisplayList.Image;
const Layer = paint.Layer;
const ObjectId = paint.ObjectId;
const Paint = paint.Paint;
const Path = DisplayList.Path;
const Stroke = paint.Stroke;
const TextRun = DisplayList.TextRun;
const UnicodeSpan = DisplayList.UnicodeSpan;

const Builder = @This();

gpa: Allocator,

cmds: std.ArrayList(DrawCmd) = .empty,
verbs: std.ArrayList(Verb) = .empty,
points: std.ArrayList(Point) = .empty,
glyphs: std.ArrayList(Glyph) = .empty,
scalars: std.ArrayList(f32) = .empty,
fonts: std.ArrayList(FontInfo) = .empty,
strings: std.ArrayList(u8) = .empty,
bytes: std.ArrayList(u8) = .empty,
unicode: std.ArrayList(UnicodeSpan) = .empty,
unicode_text: std.ArrayList(u8) = .empty,

page: Bounds = .empty,

/// Where the path under construction began in `verbs` and `points`.
path_verb_start: u32 = 0,
path_point_start: u32 = 0,
/// Start of the current subpath, for `close`.
subpath_start: ?Point = null,
cursor: Point = .origin,

clip_depth: u32 = 0,
layer_depth: u32 = 0,

pub const Error = Allocator.Error;

pub fn init(gpa: Allocator, page: Bounds) Builder {
    return .{ .gpa = gpa, .page = page };
}

/// Releases everything. Not needed after a successful `finish`, which
/// transfers ownership.
pub fn deinit(b: *Builder) void {
    b.cmds.deinit(b.gpa);
    b.verbs.deinit(b.gpa);
    b.points.deinit(b.gpa);
    b.glyphs.deinit(b.gpa);
    b.scalars.deinit(b.gpa);
    b.fonts.deinit(b.gpa);
    b.strings.deinit(b.gpa);
    b.bytes.deinit(b.gpa);
    b.unicode.deinit(b.gpa);
    b.unicode_text.deinit(b.gpa);
    b.* = undefined;
}

// -- path construction ------------------------------------------------------

pub fn moveTo(b: *Builder, p: Point) Error!void {
    try b.verbs.append(b.gpa, .move);
    try b.points.append(b.gpa, p);
    b.subpath_start = p;
    b.cursor = p;
}

pub fn lineTo(b: *Builder, p: Point) Error!void {
    // A subpath that begins with a line is malformed; treat the first point
    // as a move so the geometry is still usable.
    if (b.subpath_start == null) return b.moveTo(p);
    try b.verbs.append(b.gpa, .line);
    try b.points.append(b.gpa, p);
    b.cursor = p;
}

pub fn curveTo(b: *Builder, c1: Point, c2: Point, end: Point) Error!void {
    if (b.subpath_start == null) try b.moveTo(b.cursor);
    try b.verbs.append(b.gpa, .cubic);
    try b.points.appendSlice(b.gpa, &.{ c1, c2, end });
    b.cursor = end;
}

pub fn closePath(b: *Builder) Error!void {
    if (b.subpath_start) |start| {
        try b.verbs.append(b.gpa, .close);
        b.cursor = start;
    }
}

/// The `re` operator: a complete closed subpath, counter-clockwise from the
/// given corner (§8.5.2.1).
pub fn rect(b: *Builder, x: f32, y: f32, w: f32, h: f32) Error!void {
    try b.moveTo(.{ .x = x, .y = y });
    try b.lineTo(.{ .x = x + w, .y = y });
    try b.lineTo(.{ .x = x + w, .y = y + h });
    try b.lineTo(.{ .x = x, .y = y + h });
    try b.closePath();
}

/// True when anything has been recorded into the path under construction.
pub fn hasPath(b: *const Builder) bool {
    return b.verbs.items.len > b.path_verb_start;
}

/// Takes the path under construction without resetting it, so `B` can fill and
/// then stroke the same geometry.
///
/// Public because the interpreter needs it for `W`: the clip is set from the
/// path that the *following* painting operator has already consumed, so the
/// range has to be taken before the paint and used after it.
pub fn currentPath(b: *const Builder) Path {
    return .{
        .verbs = .{
            .start = b.path_verb_start,
            .count = @intCast(b.verbs.items.len - b.path_verb_start),
        },
        .points = .{
            .start = b.path_point_start,
            .count = @intCast(b.points.items.len - b.path_point_start),
        },
    };
}

/// Ends the current path without painting it: the `n` operator. Every painting
/// call finishes with this.
pub fn endPath(b: *Builder) void {
    b.path_verb_start = @intCast(b.verbs.items.len);
    b.path_point_start = @intCast(b.points.items.len);
    b.subpath_start = null;
}

// -- painting ---------------------------------------------------------------

pub fn fill(b: *Builder, rule: FillRule, with: Paint) Error!void {
    if (b.hasPath()) {
        try b.cmds.append(b.gpa, .{ .fill_path = .{
            .path = b.currentPath(),
            .rule = rule,
            .paint = with,
        } });
    }
    b.endPath();
}

pub fn stroke(b: *Builder, style: Stroke, with: Paint, ctm: Transform) Error!void {
    if (b.hasPath()) {
        try b.cmds.append(b.gpa, .{ .stroke_path = .{
            .path = b.currentPath(),
            .stroke = style,
            .paint = with,
            .ctm = ctm,
        } });
    }
    b.endPath();
}

/// `B` and `B*`: fill, then stroke the same path. Two commands sharing one
/// path range.
pub fn fillThenStroke(
    b: *Builder,
    rule: FillRule,
    fill_paint: Paint,
    style: Stroke,
    stroke_paint: Paint,
    ctm: Transform,
) Error!void {
    if (b.hasPath()) {
        const path = b.currentPath();
        try b.cmds.append(b.gpa, .{ .fill_path = .{
            .path = path,
            .rule = rule,
            .paint = fill_paint,
        } });
        try b.cmds.append(b.gpa, .{ .stroke_path = .{
            .path = path,
            .stroke = style,
            .paint = stroke_paint,
            .ctm = ctm,
        } });
    }
    b.endPath();
}

/// `W`/`W*` followed by a painting operator. Unlike the PDF operators, which
/// mark the clip and apply it after the next paint, this applies immediately;
/// the interpreter is responsible for the deferral.
pub fn pushClip(b: *Builder, rule: FillRule) Error!void {
    const path = if (b.hasPath()) b.currentPath() else Path{};
    try b.pushClipPath(path, rule);
    b.endPath();
}

/// Clips with a path recorded earlier, leaving the path under construction
/// alone.
///
/// `W f` means "fill this path, then clip to it", in that order: the fill must
/// not be clipped by the region it is about to establish. So the interpreter
/// takes the range with `currentPath`, paints -- which consumes the path --
/// and then clips with the range it kept.
pub fn pushClipPath(b: *Builder, path: Path, rule: FillRule) Error!void {
    try b.cmds.append(b.gpa, .{ .clip_push = .{ .path = path, .rule = rule } });
    b.clip_depth += 1;
}

pub fn popClip(b: *Builder) Error!void {
    if (b.clip_depth == 0) return;
    try b.cmds.append(b.gpa, .clip_pop);
    b.clip_depth -= 1;
}

pub fn pushLayer(b: *Builder, layer: Layer) Error!void {
    try b.cmds.append(b.gpa, .{ .layer_push = layer });
    b.layer_depth += 1;
}

pub fn popLayer(b: *Builder) Error!void {
    if (b.layer_depth == 0) return;
    try b.cmds.append(b.gpa, .layer_pop);
    b.layer_depth -= 1;
}

pub fn drawImage(b: *Builder, img: Image) Error!void {
    try b.cmds.append(b.gpa, .{ .image = img });
}

pub fn drawShading(b: *Builder, sh: paint.Shading) Error!void {
    try b.cmds.append(b.gpa, .{ .shading = sh });
}

pub fn beginMarked(b: *Builder, tag: []const u8) Error!void {
    try b.cmds.append(b.gpa, .{ .marked_begin = try b.intern(tag) });
}

pub fn endMarked(b: *Builder) Error!void {
    try b.cmds.append(b.gpa, .marked_end);
}

// -- text -------------------------------------------------------------------

/// Parameters for a run, minus the glyphs themselves.
pub const RunStyle = struct {
    font: FontId = 0,
    transform: Transform = .identity,
    size: f32 = 0,
    mode: paint.TextRenderMode = .fill,
    fill: Paint = .{ .solid = .black },
    stroke: ?Stroke = null,
    /// See `DisplayList.TextRun.advance`.
    advance: f32 = 0,
};

/// Records one `Tj`/`TJ` worth of glyphs.
///
/// Invisible text (mode 3) is recorded rather than dropped: it is the OCR
/// layer of every scanned document, and search and selection need it even
/// though nothing paints it.
pub fn textRun(b: *Builder, style: RunStyle, glyphs: []const Glyph) Error!void {
    if (glyphs.len == 0) return;

    const start: u32 = @intCast(b.glyphs.items.len);
    try b.glyphs.appendSlice(b.gpa, glyphs);

    try b.cmds.append(b.gpa, .{ .text = .{
        .font = style.font,
        .transform = style.transform,
        .size = style.size,
        .mode = style.mode,
        .fill = style.fill,
        .stroke = style.stroke,
        .glyphs = .{ .start = start, .count = @intCast(glyphs.len) },
        .advance = style.advance,
    } });
}

// -- interning --------------------------------------------------------------

/// Adds a font to the table, reusing the entry if this object is already
/// there. A page shares a handful of fonts across hundreds of runs, and the
/// font layer wants to load each program exactly once.
pub fn fontId(
    b: *Builder,
    object: ObjectId,
    name: []const u8,
    base_font: []const u8,
    composite: bool,
) Error!FontId {
    if (object != paint.no_object) {
        for (b.fonts.items, 0..) |existing, i| {
            if (existing.object == object) return @intCast(i);
        }
    }
    const id: FontId = @intCast(b.fonts.items.len);
    try b.fonts.append(b.gpa, .{
        .name = try b.intern(name),
        .base_font = try b.intern(base_font),
        .object = object,
        .composite = composite,
    });
    return id;
}

/// Records what a font's character codes mean, in UTF-8.
///
/// Separate from `fontId` because the two are known at different moments and
/// by different code: a font is interned the instant `Tf` names it, and what
/// its codes *mean* is a `/ToUnicode` stream plus an encoding chain that the
/// PDF layer resolves afterwards. Called twice for one font, the second call
/// is ignored -- `fontId` reuses an entry when the object matches, and the
/// spans would otherwise be appended a second time.
///
/// The spans are sorted here rather than trusted from the caller, because
/// `DisplayList.unicodeFor` binary-searches them and a CMap's entries arrive
/// in whatever order the producer wrote them.
pub fn fontUnicode(
    b: *Builder,
    id: FontId,
    spans: []const UnicodeSpan,
    pool: []const u8,
) Error!void {
    if (id >= b.fonts.items.len or spans.len == 0) return;
    if (b.fonts.items[id].unicode.count != 0) return;

    const text_base: u32 = @intCast(b.unicode_text.items.len);
    try b.unicode_text.appendSlice(b.gpa, pool);

    const start: u32 = @intCast(b.unicode.items.len);
    for (spans) |s| {
        if (s.len == 0 or s.high < s.low) continue;
        if (@as(usize, s.at) + s.len > pool.len) continue;
        try b.unicode.append(b.gpa, .{
            .low = s.low,
            .high = s.high,
            .at = text_base + s.at,
            .len = s.len,
            .step = s.step,
        });
    }

    const added = b.unicode.items[start..];
    std.mem.sort(UnicodeSpan, added, {}, lowerCode);
    b.fonts.items[id].unicode = .{ .start = start, .count = @intCast(added.len) };
}

fn lowerCode(_: void, a: UnicodeSpan, c: UnicodeSpan) bool {
    return a.low < c.low;
}

/// Copies a string into the list's string pool and returns its span.
pub fn intern(b: *Builder, s: []const u8) Error!Range {
    if (s.len == 0) return .empty;
    const start: u32 = @intCast(b.strings.items.len);
    try b.strings.appendSlice(b.gpa, s);
    return .{ .start = start, .count = @intCast(s.len) };
}

/// Copies inline image samples into the list's byte pool. Kept separate from
/// `strings` so that a `stringOf` on a bad range cannot hand a caller a
/// megabyte of pixels where it expected a resource name.
pub fn blob(b: *Builder, data: []const u8) Error!Range {
    if (data.len == 0) return .empty;
    const start: u32 = @intCast(b.bytes.items.len);
    try b.bytes.appendSlice(b.gpa, data);
    return .{ .start = start, .count = @intCast(data.len) };
}

/// Copies a dash pattern into the scalar pool. Zero-length and all-zero
/// patterns mean "solid" (§8.4.3.6) and are dropped here so no backend has to
/// special-case them.
pub fn dash(b: *Builder, pattern: []const f32) Error!Range {
    var all_zero = true;
    for (pattern) |v| {
        if (!std.math.isFinite(v) or v < 0) return .empty;
        if (v != 0) all_zero = false;
    }
    if (pattern.len == 0 or all_zero) return .empty;

    const start: u32 = @intCast(b.scalars.items.len);
    try b.scalars.appendSlice(b.gpa, pattern);
    return .{ .start = start, .count = @intCast(pattern.len) };
}

// -- finishing --------------------------------------------------------------

/// Transfers ownership of every array to the returned list, which the caller
/// frees with `DisplayList.deinit`. The builder is reset to empty and may be
/// reused for another page.
pub fn finish(b: *Builder) Error!DisplayList {
    const unbalanced = b.clip_depth != 0 or b.layer_depth != 0;

    // Close what the content stream left open. A damaged file should render
    // what it can, not nothing.
    while (b.layer_depth > 0) try b.popLayer();
    while (b.clip_depth > 0) try b.popClip();

    const list: DisplayList = .{
        .cmds = try b.cmds.toOwnedSlice(b.gpa),
        .verbs = try b.verbs.toOwnedSlice(b.gpa),
        .points = try b.points.toOwnedSlice(b.gpa),
        .glyphs = try b.glyphs.toOwnedSlice(b.gpa),
        .scalars = try b.scalars.toOwnedSlice(b.gpa),
        .fonts = try b.fonts.toOwnedSlice(b.gpa),
        .strings = try b.strings.toOwnedSlice(b.gpa),
        .bytes = try b.bytes.toOwnedSlice(b.gpa),
        .unicode = try b.unicode.toOwnedSlice(b.gpa),
        .unicode_text = try b.unicode_text.toOwnedSlice(b.gpa),
        .page = b.page,
        .unbalanced = unbalanced,
    };

    b.path_verb_start = 0;
    b.path_point_start = 0;
    b.subpath_start = null;
    b.cursor = .origin;
    return list;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "a rectangle fill records one command and five verbs" {
    var b: Builder = .init(testing.allocator, .fromRect(0, 0, 612, 792));
    defer b.deinit();

    try b.rect(72, 700, 200, 24);
    try b.fill(.nonzero, .{ .solid = .black });

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), list.cmds.len);
    const cmd = list.cmds[0].fill_path;
    try testing.expectEqual(FillRule.nonzero, cmd.rule);
    // move, line, line, line, close
    try testing.expectEqual(@as(usize, 5), list.verbsOf(cmd.path).len);

    const bounds = list.pathBounds(cmd.path);
    try testing.expectApproxEqAbs(@as(f32, 72), bounds.min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 200), bounds.width(), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 24), bounds.height(), 1e-4);
}

test "painting consumes the path so the next one starts clean" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.rect(0, 0, 10, 10);
    try b.fill(.nonzero, .{ .solid = .black });
    try b.rect(50, 50, 10, 10);
    try b.fill(.even_odd, .{ .solid = .white });

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), list.cmds.len);
    const second = list.cmds[1].fill_path;
    try testing.expectEqual(@as(usize, 5), list.verbsOf(second.path).len);
    try testing.expectApproxEqAbs(@as(f32, 50), list.pathBounds(second.path).min_x, 1e-4);
}

test "fill then stroke shares one path range" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.rect(0, 0, 10, 10);
    try b.fillThenStroke(
        .nonzero,
        .{ .solid = .white },
        .{ .width = 2 },
        .{ .solid = .black },
        .identity,
    );

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), list.cmds.len);
    try testing.expectEqual(list.cmds[0].fill_path.path.verbs, list.cmds[1].stroke_path.path.verbs);
    // One path recorded, not two.
    try testing.expectEqual(@as(usize, 5), list.verbs.len);
}

test "a painting operator with no path records nothing" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.fill(.nonzero, .{ .solid = .black });
    try b.stroke(.{}, .{ .solid = .black }, .identity);

    var list = try b.finish();
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), list.cmds.len);
}

test "a subpath starting with lineTo is repaired into a move" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.lineTo(.{ .x = 5, .y = 5 });
    try b.lineTo(.{ .x = 10, .y = 10 });
    try b.fill(.nonzero, .{ .solid = .black });

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const verbs = list.verbsOf(list.cmds[0].fill_path.path);
    try testing.expectEqual(Verb.move, verbs[0]);
    try testing.expectEqual(Verb.line, verbs[1]);
}

test "unbalanced clips are closed and reported" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.rect(0, 0, 100, 100);
    try b.pushClip(.nonzero);
    try b.rect(10, 10, 10, 10);
    try b.pushClip(.nonzero);
    // Two pushes, no pops -- what a truncated content stream looks like.

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    try testing.expect(list.unbalanced);
    try testing.expectEqual(@as(usize, 4), list.cmds.len);
    try testing.expectEqual(DrawCmd.clip_pop, list.cmds[2]);
    try testing.expectEqual(DrawCmd.clip_pop, list.cmds[3]);
}

test "a balanced recording is not flagged" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.rect(0, 0, 100, 100);
    try b.pushClip(.nonzero);
    try b.popClip();

    var list = try b.finish();
    defer list.deinit(testing.allocator);
    try testing.expect(!list.unbalanced);
}

test "an unmatched pop is ignored rather than underflowing" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.popClip();
    try b.popLayer();

    var list = try b.finish();
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), list.cmds.len);
    try testing.expect(!list.unbalanced);
}

test "fonts intern by object id" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    const a = try b.fontId(12, "F1", "Helvetica", false);
    const again = try b.fontId(12, "F1", "Helvetica", false);
    const other = try b.fontId(13, "F2", "Times-Roman", false);

    try testing.expectEqual(a, again);
    try testing.expect(a != other);

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), list.fonts.len);
    try testing.expectEqualStrings("Helvetica", list.stringOf(list.fontOf(a).base_font));
    try testing.expectEqualStrings("F2", list.stringOf(list.fontOf(other).name));
}

test "solid dash patterns are dropped" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try testing.expect((try b.dash(&.{})).isEmpty());
    // `[0 0] 0 d` is a solid line, not an infinitely fine dash.
    try testing.expect((try b.dash(&.{ 0, 0 })).isEmpty());
    // A negative entry is malformed.
    try testing.expect((try b.dash(&.{ 3, -1 })).isEmpty());

    const real = try b.dash(&.{ 3, 2 });
    try testing.expectEqual(@as(u32, 2), real.count);
}

test "a text run records its glyphs" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    const font = try b.fontId(7, "F1", "Helvetica", false);
    try b.textRun(.{
        .font = font,
        .transform = .translation(72, 700),
        .size = 12,
    }, &.{
        .{ .code = 'H', .offset = .{ .x = 0, .y = 0 } },
        .{ .code = 'i', .offset = .{ .x = 7.2, .y = 0 } },
    });

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const run = list.cmds[0].text;
    const glyphs = list.glyphsOf(run);
    try testing.expectEqual(@as(usize, 2), glyphs.len);
    try testing.expectEqual(@as(u32, 'i'), glyphs[1].code);
    try testing.expectEqual(Glyph.unresolved_glyph, glyphs[0].id);
    try testing.expectApproxEqAbs(@as(f32, 12), run.size, 1e-6);
}

test "an empty text run records nothing" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.textRun(.{}, &.{});
    var list = try b.finish();
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), list.cmds.len);
}

test "stats count what was recorded" {
    var b: Builder = .init(testing.allocator, .empty);
    defer b.deinit();

    try b.rect(0, 0, 10, 10);
    try b.fill(.nonzero, .{ .solid = .black });
    try b.rect(0, 0, 10, 10);
    try b.stroke(.{ .width = 1 }, .{ .solid = .black }, .identity);
    try b.drawImage(.{ .width = 4, .height = 4 });

    var list = try b.finish();
    defer list.deinit(testing.allocator);

    const s = list.stats();
    try testing.expectEqual(@as(u32, 1), s.fills);
    try testing.expectEqual(@as(u32, 1), s.strokes);
    try testing.expectEqual(@as(u32, 1), s.images);
    try testing.expectEqual(@as(u32, 10), s.verbs);
}
