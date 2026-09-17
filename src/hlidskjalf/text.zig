//! Where the words are on a page, so a cursor has somewhere to stand.
//!
//! A PDF has no lines. It has `Tj` operators, each placing a run of glyphs at
//! a matrix, in whatever order the producer felt like emitting them -- which
//! for a two-column paper is often both columns interleaved, and for a
//! justified paragraph is one run per word. A caret that moved "down a line"
//! through that order would wander across the page.
//!
//! So the runs are taken apart into glyph boxes and put back together by
//! *position*: glyphs sharing a baseline are a line, lines are ordered down
//! the page, and within a line glyphs are ordered along it. That is the
//! reading order for the overwhelming majority of documents, and it is
//! recovered from geometry rather than trusted from the file.
//!
//! ## What a box is
//!
//! Everything here is in **PDF user space** -- points, y upwards, origin at
//! the bottom-left of the page -- which is the space the display list is in
//! and the space a highlight is stored in. It is the only page coordinate
//! that does not change when the zoom does, which is what a caret remembered
//! across a zoom and a highlight remembered across a session both need.
//!
//! A glyph's width is taken from the *next* glyph's offset rather than from
//! the font, because the run already contains the advance the producer chose,
//! kerning and `TJ` adjustments included, and asking the font would get a
//! different answer. The last glyph of a run has no next, and gets half its
//! size -- an estimate, and visibly one on a caret parked after a full stop,
//! but the alternative is loading a face here to measure one glyph.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gelgja = @import("../gelgja.zig");

const Bounds = gelgja.Bounds;
const DisplayList = gelgja.DisplayList;
const Point = gelgja.Point;

/// One glyph, placed.
pub const Box = struct {
    /// The character code from the content stream, as `DisplayList.Glyph`
    /// carries it. Kept so that a selection can one day become text; nothing
    /// here interprets it.
    code: u32 = 0,
    /// In PDF user space.
    box: Bounds = .empty,
    /// The glyph's own baseline in user space -- where the pen was, not where
    /// the box's bottom edge is. Kept because the box is padded by a guessed
    /// descender, and grouping by a guess would put the lines of a document
    /// two points off where its text actually sits.
    base: f32 = 0,
    /// The advance after this glyph looked like it contained a space.
    ///
    /// PDFs made by TeX, and many others, never draw a space: the gap between
    /// words is a kerning number in a `TJ` array, so a word boundary is only
    /// visible as a glyph whose advance is longer than a glyph's. This is that
    /// guess, made while the run is still together -- once glyphs are sorted
    /// into lines, which glyph followed which in the file is gone.
    space_after: bool = false,

    pub fn isSpace(b: Box) bool {
        return b.code == ' ';
    }

    pub fn middle(b: Box) f32 {
        return (b.box.min_x + b.box.max_x) * 0.5;
    }
};

/// Glyphs sharing a baseline, in the order they are read along it.
pub const Line = struct {
    /// A span of `Page.boxes`.
    first: u32 = 0,
    count: u32 = 0,
    /// The baseline's y in user space. Lines are sorted by it, descending,
    /// because user space counts upwards and reading goes down.
    baseline: f32 = 0,
    /// Every glyph on the line, together.
    box: Bounds = .empty,

    pub fn glyphs(l: Line, page: Page) []const Box {
        return page.boxes[l.first..][0..l.count];
    }
};

/// One page's text, laid out.
pub const Page = struct {
    boxes: []Box = &.{},
    lines: []Line = &.{},

    pub fn deinit(p: *Page, gpa: Allocator) void {
        gpa.free(p.boxes);
        gpa.free(p.lines);
        p.* = .{};
    }

    pub fn isEmpty(p: Page) bool {
        return p.lines.len == 0;
    }

    /// The line nearest a y in user space, for a click and for a cursor
    /// arriving from the page above.
    pub fn lineAt(p: Page, y: f32) u32 {
        if (p.lines.len == 0) return 0;
        var best: u32 = 0;
        var best_d: f32 = std.math.floatMax(f32);
        for (p.lines, 0..) |l, i| {
            const d = @abs(l.baseline - y);
            if (d < best_d) {
                best_d = d;
                best = @intCast(i);
            }
        }
        return best;
    }

    /// Whether glyph `i` of `line` begins a word: `w` and `b` stop here.
    ///
    /// Three signs of a boundary, any of which will do: an explicit space
    /// glyph before it, an advance before it long enough to hide one, or a
    /// visible gap between the two boxes -- which is how words emitted as
    /// separate `Tj` operators look. The gap is measured against the glyph's
    /// height so that it means the same at eight points and at twenty-four.
    pub fn wordStart(p: Page, line: u32, i: u32) bool {
        if (line >= p.lines.len) return false;
        const glyphs = p.lines[line].glyphs(p);
        if (i >= glyphs.len) return false;
        if (glyphs[i].isSpace()) return false;
        if (i == 0) return true;
        const prev = glyphs[i - 1];
        if (prev.isSpace() or prev.space_after) return true;
        const gap = glyphs[i].box.min_x - prev.box.max_x;
        return gap > glyphs[i].box.height() * 0.15;
    }

    /// Whether glyph `i` ends a word: `e` stops here.
    pub fn wordEnd(p: Page, line: u32, i: u32) bool {
        if (line >= p.lines.len) return false;
        const glyphs = p.lines[line].glyphs(p);
        if (i >= glyphs.len) return false;
        if (glyphs[i].isSpace()) return false;
        return i + 1 == glyphs.len or p.wordStart(line, i + 1) or glyphs[i + 1].isSpace();
    }

    /// The glyph on `line` whose middle is nearest `x`, which is how a caret
    /// keeps its column when it moves between lines of different lengths.
    pub fn columnAt(p: Page, line: u32, x: f32) u32 {
        if (line >= p.lines.len) return 0;
        const l = p.lines[line];
        if (l.count == 0) return 0;

        var best: u32 = 0;
        var best_d: f32 = std.math.floatMax(f32);
        for (l.glyphs(p), 0..) |g, i| {
            const d = @abs(g.middle() - x);
            if (d < best_d) {
                best_d = d;
                best = @intCast(i);
            }
        }
        // Past the middle of the last glyph is the position *after* it, the
        // way it is in every text editor: a caret can stand at the end of a
        // line as well as on each character of it.
        const last = l.glyphs(p)[l.count - 1];
        if (best == l.count - 1 and x > last.middle()) return l.count;
        return best;
    }
};

/// Builds the text map for one interpreted page.
///
/// Invisible text -- render mode 3, which is how every scanned document
/// carries its OCR layer -- is *kept*, and deliberately: on a scan it is the
/// only text there is, and a caret that could not stand on it would be a
/// caret that does not work on half the documents anyone owns.
pub fn build(gpa: Allocator, list: DisplayList) Allocator.Error!Page {
    var boxes: std.ArrayList(Box) = .empty;
    errdefer boxes.deinit(gpa);

    for (list.cmds) |cmd| {
        const run = switch (cmd) {
            .text => |t| t,
            else => continue,
        };
        const glyphs = list.glyphsOf(run);
        if (glyphs.len == 0) continue;
        const gap_after = wordGap(glyphs, run.size);

        for (glyphs, 0..) |g, i| {
            // The advance the producer actually used, which is what puts a
            // caret between two kerned letters rather than through one.
            const advance = if (i + 1 < glyphs.len)
                glyphs[i + 1].offset.x - g.offset.x
            else
                run.size * 0.5;
            // A negative advance is a run that moves backwards -- a `TJ` with
            // a large positive adjustment, or right-to-left text emitted in
            // visual order. Give it a forward box anyway; a zero-width one
            // would be a caret position that cannot be clicked on.
            const w = if (advance > 0) advance else run.size * 0.5;

            // Ascender and descender as fractions of the size. The true
            // numbers are in the font, and the font is not here; these are
            // the same proportions `replay` draws a debug text box with, so a
            // caret lines up with one.
            const corners = [_]Point{
                .{ .x = g.offset.x, .y = g.offset.y - run.size * 0.2 },
                .{ .x = g.offset.x + w, .y = g.offset.y - run.size * 0.2 },
                .{ .x = g.offset.x + w, .y = g.offset.y + run.size * 0.75 },
                .{ .x = g.offset.x, .y = g.offset.y + run.size * 0.75 },
            };

            var box: Bounds = .empty;
            for (corners) |c| box = box.add(run.transform.apply(c));
            if (box.isEmpty()) continue;
            if (!std.math.isFinite(box.min_x) or !std.math.isFinite(box.max_y)) continue;

            const pen = run.transform.apply(g.offset);
            try boxes.append(gpa, .{
                .code = g.code,
                .box = box,
                .base = pen.y,
                .space_after = i + 1 < glyphs.len and advance > gap_after,
            });
        }
    }

    if (boxes.items.len == 0) {
        boxes.deinit(gpa);
        return .{};
    }

    const owned = try boxes.toOwnedSlice(gpa);
    errdefer gpa.free(owned);
    const lines = try group(gpa, owned);
    return .{ .boxes = owned, .lines = lines };
}

/// How long an advance has to be before it is taken to contain a space.
///
/// The larger of three-fifths of an em and half as much again as the run's
/// typical advance. The em alone would split every `m` and `W` in two; the
/// median alone would split every word of a run set in a narrow font.
/// Together they catch TeX's interword space, which is a letter plus a third
/// of an em, and miss the widest letters.
fn wordGap(glyphs: []const DisplayList.Glyph, size: f32) f32 {
    if (glyphs.len < 2) return std.math.floatMax(f32);
    var buf: [256]f32 = undefined;
    const n = @min(glyphs.len - 1, buf.len);
    for (0..n) |i| buf[i] = glyphs[i + 1].offset.x - glyphs[i].offset.x;
    std.mem.sort(f32, buf[0..n], {}, std.sort.asc(f32));
    const median = buf[n / 2];
    return @max(size * 0.6, median * 1.45);
}

/// Sorts glyphs into reading order and cuts them into lines.
///
/// The line test is the *overlap* of two glyphs' vertical extents rather than
/// the distance between their baselines, because a distance threshold has to
/// be in some unit and a page mixes eight-point footnotes with a
/// twenty-four-point heading. Overlap scales itself.
fn group(gpa: Allocator, boxes: []Box) Allocator.Error![]Line {
    // Down the page first, then along each line. User space counts upwards,
    // so "down" is descending y.
    std.mem.sort(Box, boxes, {}, struct {
        fn less(_: void, a: Box, b: Box) bool {
            if (a.box.min_y != b.box.min_y) return a.box.min_y > b.box.min_y;
            return a.box.min_x < b.box.min_x;
        }
    }.less);

    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(gpa);

    var start: usize = 0;
    var i: usize = 1;
    while (i <= boxes.len) : (i += 1) {
        const ends = i == boxes.len or !sameLine(boxes[start], boxes[i]);
        if (!ends) continue;

        // Along the line, which the sort above only did within one y.
        const on_line = boxes[start..i];
        std.mem.sort(Box, on_line, {}, struct {
            fn less(_: void, a: Box, b: Box) bool {
                return a.box.min_x < b.box.min_x;
            }
        }.less);

        var box: Bounds = .empty;
        var baseline: f32 = 0;
        for (on_line) |g| {
            box = box.unionWith(g.box);
            baseline += g.base;
        }
        try lines.append(gpa, .{
            .first = @intCast(start),
            .count = @intCast(on_line.len),
            .baseline = baseline / @as(f32, @floatFromInt(on_line.len)),
            .box = box,
        });
        start = i;
    }
    return lines.toOwnedSlice(gpa);
}

/// Two glyphs are on one line when their vertical extents overlap by more
/// than half the shorter one. Superscripts and inline maths join the line
/// they sit in; the next line down does not.
fn sameLine(a: Box, b: Box) bool {
    const low = @max(a.box.min_y, b.box.min_y);
    const high = @min(a.box.max_y, b.box.max_y);
    const overlap = high - low;
    if (overlap <= 0) return false;
    const shorter = @min(a.box.height(), b.box.height());
    if (!(shorter > 0)) return false;
    return overlap > shorter * 0.5;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

/// A display list holding one run of glyphs at `size`, starting at
/// `(x, y)` in user space and advancing by `advance` each.
fn runOf(
    gpa: Allocator,
    x: f32,
    y: f32,
    size: f32,
    advance: f32,
    n: u32,
) !DisplayList {
    const glyphs = try gpa.alloc(DisplayList.Glyph, n);
    for (glyphs, 0..) |*g, i| {
        g.* = .{
            .code = 'a' + @as(u32, @intCast(i)),
            .offset = .{ .x = advance * @as(f32, @floatFromInt(i)), .y = 0 },
        };
    }
    var cmds = try gpa.alloc(DisplayList.DrawCmd, 1);
    cmds[0] = .{ .text = .{
        .size = size,
        .transform = .translation(x, y),
        .glyphs = .{ .start = 0, .count = n },
    } };
    return .{ .glyphs = glyphs, .cmds = cmds };
}

test "a run becomes one line of boxes in reading order" {
    const gpa = testing.allocator;
    const list = try runOf(gpa, 100, 700, 10, 6, 4);
    defer {
        gpa.free(list.glyphs);
        gpa.free(list.cmds);
    }

    var page = try build(gpa, list);
    defer page.deinit(gpa);

    try testing.expectEqual(@as(usize, 4), page.boxes.len);
    try testing.expectEqual(@as(usize, 1), page.lines.len);
    try testing.expectEqual(@as(u32, 4), page.lines[0].count);

    // Each box starts where the last one ended: the advance is the file's,
    // not a guess.
    try testing.expectApproxEqAbs(@as(f32, 100), page.boxes[0].box.min_x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 106), page.boxes[0].box.max_x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 106), page.boxes[1].box.min_x, 0.01);
    try testing.expectEqual(@as(u32, 'a'), page.boxes[0].code);

    // The last glyph has no next to measure against and gets half a size.
    try testing.expectApproxEqAbs(@as(f32, 5), page.boxes[3].box.width(), 0.01);
}

test "glyphs on different baselines are different lines, down the page" {
    const gpa = testing.allocator;

    // Two runs, the second twenty points *below* the first -- which in user
    // space is a smaller y.
    const glyphs = try gpa.alloc(DisplayList.Glyph, 4);
    defer gpa.free(glyphs);
    for (glyphs, 0..) |*g, i| g.* = .{
        .code = @intCast(i),
        .offset = .{ .x = 6 * @as(f32, @floatFromInt(i % 2)), .y = 0 },
    };

    var cmds = try gpa.alloc(DisplayList.DrawCmd, 2);
    defer gpa.free(cmds);
    // Emitted bottom-first, to prove the order comes from the geometry and
    // not from the file.
    cmds[0] = .{ .text = .{
        .size = 10,
        .transform = .translation(100, 680),
        .glyphs = .{ .start = 2, .count = 2 },
    } };
    cmds[1] = .{ .text = .{
        .size = 10,
        .transform = .translation(100, 700),
        .glyphs = .{ .start = 0, .count = 2 },
    } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), page.lines.len);
    try testing.expectApproxEqAbs(@as(f32, 700), page.lines[0].baseline, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 680), page.lines[1].baseline, 0.5);
}

test "a superscript joins the line it sits in rather than starting one" {
    const gpa = testing.allocator;

    const glyphs = try gpa.alloc(DisplayList.Glyph, 2);
    defer gpa.free(glyphs);
    glyphs[0] = .{ .code = 'x', .offset = .origin };
    glyphs[1] = .{ .code = '2', .offset = .origin };

    var cmds = try gpa.alloc(DisplayList.DrawCmd, 2);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{
        .size = 10,
        .transform = .translation(100, 700),
        .glyphs = .{ .start = 0, .count = 1 },
    } };
    // Raised four points and set smaller, the way a superscript is.
    cmds[1] = .{ .text = .{
        .size = 7,
        .transform = .translation(106, 704),
        .glyphs = .{ .start = 1, .count = 1 },
    } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), page.lines.len);
    try testing.expectEqual(@as(u32, 2), page.lines[0].count);
}

test "the column nearest an x is found, and past the last glyph is the end" {
    const gpa = testing.allocator;
    const list = try runOf(gpa, 100, 700, 10, 6, 4);
    defer {
        gpa.free(list.glyphs);
        gpa.free(list.cmds);
    }
    var page = try build(gpa, list);
    defer page.deinit(gpa);

    try testing.expectEqual(@as(u32, 0), page.columnAt(0, 101));
    try testing.expectEqual(@as(u32, 1), page.columnAt(0, 108));
    // Well past the right of the line: the caret goes after the last glyph,
    // which is a position, not a glyph.
    try testing.expectEqual(@as(u32, 4), page.columnAt(0, 500));
    // And well before it, on the first.
    try testing.expectEqual(@as(u32, 0), page.columnAt(0, -100));
}

test "a page with no text at all is empty rather than a line of nothing" {
    const gpa = testing.allocator;
    var page = try build(gpa, .{});
    defer page.deinit(gpa);
    try testing.expect(page.isEmpty());
    try testing.expectEqual(@as(u32, 0), page.lineAt(400));
}

test "words are found in a run that draws no spaces, the way TeX sets them" {
    // "ab cd": four glyphs at size 10, letters advancing 5 points, and the
    // gap between the words hidden in the advance after `b` -- a letter plus
    // a third of an em, which is what a `TJ` kern of -333 produces.
    const gpa = testing.allocator;
    const glyphs = try gpa.alloc(DisplayList.Glyph, 4);
    defer gpa.free(glyphs);
    const xs = [_]f32{ 0, 5, 13.3, 18.3 };
    for (glyphs, 0..) |*g, i| g.* = .{ .code = "abcd"[i], .offset = .{ .x = xs[i], .y = 0 } };
    var cmds = try gpa.alloc(DisplayList.DrawCmd, 1);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{ .size = 10, .transform = .translation(100, 700), .glyphs = .{ .start = 0, .count = 4 } } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);

    try testing.expect(page.wordStart(0, 0));
    try testing.expect(!page.wordStart(0, 1));
    try testing.expect(page.wordStart(0, 2));
    try testing.expect(!page.wordStart(0, 3));

    try testing.expect(!page.wordEnd(0, 0));
    try testing.expect(page.wordEnd(0, 1));
    try testing.expect(page.wordEnd(0, 3));
}

test "a wide letter is not a word break" {
    // `mwm` at size 10 with advances of 8 -- as wide as letters get. The
    // median rule is what keeps these together.
    const gpa = testing.allocator;
    const glyphs = try gpa.alloc(DisplayList.Glyph, 3);
    defer gpa.free(glyphs);
    for (glyphs, 0..) |*g, i| g.* = .{ .code = "mwm"[i], .offset = .{ .x = 8 * @as(f32, @floatFromInt(i)), .y = 0 } };
    var cmds = try gpa.alloc(DisplayList.DrawCmd, 1);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{ .size = 10, .transform = .translation(100, 700), .glyphs = .{ .start = 0, .count = 3 } } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);
    try testing.expect(!page.wordStart(0, 1));
    try testing.expect(!page.wordStart(0, 2));
}

test "an explicit space glyph separates words and is not one" {
    const gpa = testing.allocator;
    const glyphs = try gpa.alloc(DisplayList.Glyph, 3);
    defer gpa.free(glyphs);
    for (glyphs, 0..) |*g, i| g.* = .{ .code = "a b"[i], .offset = .{ .x = 5 * @as(f32, @floatFromInt(i)), .y = 0 } };
    var cmds = try gpa.alloc(DisplayList.DrawCmd, 1);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{ .size = 10, .transform = .translation(100, 700), .glyphs = .{ .start = 0, .count = 3 } } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);
    try testing.expect(page.wordStart(0, 0));
    try testing.expect(!page.wordStart(0, 1));
    try testing.expect(page.wordStart(0, 2));
}
