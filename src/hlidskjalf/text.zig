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
//! their column, and columns are ordered left to right. That is the reading
//! order for the overwhelming majority of documents, and it is recovered from
//! geometry rather than trusted from the file.
//!
//! The columns matter as much as the lines. A selection is a range of line
//! indices, so if the two columns of a paper were interleaved down the page,
//! dragging over a paragraph in the left column would take in whatever the
//! right column had at the same heights. `findGutters` is what stops that.
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
//! different answer. The last glyph of a run has no next, and is measured
//! against `TextRun.advance` -- where the pen finished -- which the
//! interpreter carries for exactly this. It used to get half its size
//! instead, and that guess is why the right-hand edge of a selection over a
//! justified paragraph was ragged: every line ends at the same place on the
//! paper, and half an em past the *start* of the last letter is a different
//! place for an `l` than for an `m`.
//!
//! ## Displayed equations are still wrong, and are the next thing here
//!
//! Inline mathematics is handled: `fold` puts a dropped subscript back on the
//! line it belongs to, so dragging over a paragraph of a paper takes its
//! `x_i`s with it. A *displayed* equation is not, and cannot be by the method
//! this file uses.
//!
//! Its rows are genuinely several points apart -- a numerator, a bar, a
//! denominator, a limit under a sum -- so they arrive here as four or five
//! lines, which by geometry is exactly what they are. But they are one
//! expression, and reading order through them is not "left to right, then
//! down": it is the order the mathematics is spoken in, which no arrangement
//! of boxes on a page carries. So a selection dragged across a display picks
//! up a staggered set of blocks, a caret walks along a row of exponents on
//! its own, and both are behaving correctly and looking wrong.
//!
//! The fix is not another threshold. It is to recognise a display as a unit
//! -- a run of lines, well inside the text column, with no line of body text
//! between them, in a document that has body text either side -- and to let a
//! selection that touches any part of it take the whole thing, the way a
//! browser takes a whole image rather than part of one. That is a structure
//! this file does not have yet, and it is what to build here next.

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
    /// Which column of the page the line belongs to, counting from the left.
    /// Zero on a page with one column, which is most of them.
    column: u32 = 0,

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

    /// The line nearest a point in user space, for a click and for a cursor
    /// arriving from the page above.
    ///
    /// The column is chosen first and the baseline second, because on a paper
    /// the left column's lines are the same height as the right column's: a
    /// click in one of them must not land in the other, however close the
    /// baseline is. Within a column the nearest baseline wins, so a click in
    /// the margin beside a line still lands on that line.
    pub fn lineAt(p: Page, x: f32, y: f32) u32 {
        if (p.lines.len == 0) return 0;

        const want = p.columnNear(x);
        var best: u32 = 0;
        var best_d: f32 = std.math.floatMax(f32);
        for (p.lines, 0..) |l, i| {
            if (l.column != want) continue;
            const d = @abs(l.baseline - y);
            if (d < best_d) {
                best_d = d;
                best = @intCast(i);
            }
        }
        return best;
    }

    /// The column whose lines come nearest an x, which is the column a click
    /// at that x is in.
    pub fn columnNear(p: Page, x: f32) u32 {
        var best: u32 = 0;
        var best_d: f32 = std.math.floatMax(f32);
        for (p.lines) |l| {
            const d = if (x < l.box.min_x)
                l.box.min_x - x
            else if (x > l.box.max_x)
                x - l.box.max_x
            else
                0;
            if (d < best_d) {
                best_d = d;
                best = l.column;
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
                run.advance - g.offset.x;
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
/// Reading order is column by column, and within a column down the page: the
/// left column of a paper is read to its foot before the right column starts.
/// Everything above this depends on that, because a selection is a *range of
/// line indices* -- dragging from the middle of the left column to its foot
/// must not pick up the right column's lines at the same heights, and the
/// only thing that stops it is that they are not in between.
///
/// The line test is the *overlap* of two glyphs' vertical extents rather than
/// the distance between their baselines, because a distance threshold has to
/// be in some unit and a page mixes eight-point footnotes with a
/// twenty-four-point heading. Overlap scales itself.
fn group(gpa: Allocator, boxes: []Box) Allocator.Error![]Line {
    // Down the page, which is the order the gutter scan reads rows in.
    std.mem.sort(Box, boxes, {}, struct {
        fn less(_: void, a: Box, b: Box) bool {
            if (a.box.min_y != b.box.min_y) return a.box.min_y > b.box.min_y;
            return a.box.min_x < b.box.min_x;
        }
    }.less);

    var gutters_buf: [max_columns - 1]f32 = undefined;
    const gutters = findGutters(boxes, &gutters_buf);

    // Column first, then down the page, then along each line. User space
    // counts upwards, so "down" is descending y.
    if (gutters.len != 0) std.mem.sort(Box, boxes, gutters, struct {
        fn less(cuts: []const f32, a: Box, b: Box) bool {
            const ca = columnOf(cuts, a);
            const cb = columnOf(cuts, b);
            if (ca != cb) return ca < cb;
            if (a.box.min_y != b.box.min_y) return a.box.min_y > b.box.min_y;
            return a.box.min_x < b.box.min_x;
        }
    }.less);

    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(gpa);

    // How far off a baseline a fragment may sit and still belong to the line
    // above it. See `fold` below for what this is for and why it is this
    // number.
    const fold_gap = medianHeight(boxes) * 0.35;

    var start: usize = 0;
    var i: usize = 1;
    while (i <= boxes.len) : (i += 1) {
        const ends = i == boxes.len or
            columnOf(gutters, boxes[start]) != columnOf(gutters, boxes[i]) or
            !sameLine(boxes[start], boxes[i]);
        if (!ends) continue;

        // Along the line, which the sort above only did within one y.
        const on_line = boxes[start..i];
        std.mem.sort(Box, on_line, {}, byX);

        var box: Bounds = .empty;
        var baseline: f32 = 0;
        for (on_line) |g| {
            box = box.unionWith(g.box);
            baseline += g.base;
        }
        const line: Line = .{
            .first = @intCast(start),
            .count = @intCast(on_line.len),
            .baseline = baseline / @as(f32, @floatFromInt(on_line.len)),
            .box = box,
            .column = columnOf(gutters, on_line[0]),
        };

        if (lines.items.len != 0 and fold(&lines.items[lines.items.len - 1], line, boxes, fold_gap)) {
            start = i;
            continue;
        }
        try lines.append(gpa, line);
        start = i;
    }
    return lines.toOwnedSlice(gpa);
}

fn byX(_: void, a: Box, b: Box) bool {
    return a.box.min_x < b.box.min_x;
}

/// Puts the pieces of one typeset line back together, and says whether it
/// did.
///
/// A line with mathematics in it does not arrive as one line. A subscript
/// sits a point and a half below the words around it and a superscript the
/// same above, which is not enough box overlap for `sameLine`, so the walk
/// cuts the line in two: the words, and then a one-glyph line holding the
/// `i` of an `x_i`. On a page of a paper there are a dozen of these. The
/// consequences are all the reader's: the caret steps down onto a row with
/// one glyph on it, and a selection dragged across the paragraph draws the
/// words and leaves their subscripts unselected in the middle of it.
///
/// So a line that sits within `gap` of the one before it, in the same column
/// and overlapping it in x, is folded into it. The gap is a third of the
/// page's median glyph height -- about three and a half points on a paper set
/// in ten. That is wide enough for every sub- and superscript, which are one
/// to three points off, and narrow enough to leave the rows of a *displayed*
/// equation alone: those are five points and more apart, and they really are
/// separate lines, on paper as well as in here.
///
/// Only the line immediately before, and only when its glyphs end exactly
/// where these begin -- a `Line` is a span of one shared array, so two lines
/// can only become one when they are already next to each other in it. They
/// are, because the walk emits them in the order the array holds them.
fn fold(prev: *Line, line: Line, boxes: []Box, gap: f32) bool {
    if (prev.column != line.column) return false;
    if (prev.first + prev.count != line.first) return false;
    if (@abs(prev.baseline - line.baseline) > gap) return false;
    // Side by side is two things, not one: a marginal note beside a line is
    // at its height and nowhere near it.
    if (prev.box.min_x > line.box.max_x or line.box.min_x > prev.box.max_x) return false;

    prev.count += line.count;
    prev.box = prev.box.unionWith(line.box);

    // The glyphs of both, in reading order along the line: a caret moving
    // through `x_i + y` has to meet the `i` between the `x` and the `+`.
    const merged = boxes[prev.first..][0..prev.count];
    std.mem.sort(Box, merged, {}, byX);

    // Weighted, so the baseline stays the words' and is not dragged down by
    // a subscript. `lineAt` picks the nearest baseline to a click.
    var sum: f32 = 0;
    for (merged) |g| sum += g.base;
    prev.baseline = sum / @as(f32, @floatFromInt(merged.len));
    return true;
}

// -- columns ------------------------------------------------------------------

/// As many columns as a page is believed to have. Seven gutters is more than
/// any page anybody reads, and the bound is what keeps the scan a fixed-size
/// buffer on the stack rather than an allocation per page.
const max_columns = 8;

/// How many slices the page's width is examined in. One part in five hundred
/// of a letter page is about a point and a half, which is finer than any
/// gutter worth finding and coarse enough to stay in L1.
const bins = 512;

/// Which column a glyph is in, given the x of each gutter's middle.
fn columnOf(gutters: []const f32, b: Box) u32 {
    for (gutters, 0..) |cut, i| {
        if (b.middle() < cut) return @intCast(i);
    }
    return @intCast(gutters.len);
}

/// The vertical white channels that divide a page into columns, as the x of
/// each one's middle, left to right.
///
/// A column gutter is a band of x that almost no line crosses and that has a
/// full height of text on either side of it. Both halves of that matter. The
/// first alone would call the ragged right edge of a paragraph a gutter; the
/// second is what tells a two-column paper from a two-column *table*, whose
/// gap is just as empty but only as tall as the table.
///
/// A page-wide title or figure caption sits across the gutter and would close
/// it, so a band is allowed to be crossed by a few lines rather than none.
fn findGutters(boxes: []const Box, out: *[max_columns - 1]f32) []const f32 {
    if (boxes.len < 40) return out[0..0];

    var page: Bounds = .empty;
    for (boxes) |b| page = page.unionWith(b.box);
    const w = page.width();
    const h = page.height();
    if (!(w > 0) or !(h > 0)) return out[0..0];

    // How many *rows* of text cross each slice, not how many glyphs: a row
    // that crosses the gutter counts once however long it is, so a running
    // head cannot outvote a column of body text.
    var crossings: [bins]u16 = @splat(0);
    var rows: u16 = 0;
    var seen: [bins]bool = @splat(false);
    const step = w / bins;

    var start: usize = 0;
    var i: usize = 0;
    while (i <= boxes.len) : (i += 1) {
        if (i == boxes.len or !overlapsRow(boxes[start].box, boxes[i].box)) {
            for (&crossings, seen) |*c, s| c.* += @intFromBool(s);
            rows +|= 1;
            seen = @splat(false);
            start = i;
            if (i == boxes.len) break;
        }
        const lo = binOf(boxes[i].box.min_x, page.min_x, step);
        const hi = binOf(boxes[i].box.max_x, page.min_x, step);
        for (seen[lo .. hi + 1]) |*s| s.* = true;
    }
    if (rows < 8) return out[0..0];

    // Wide enough to be a gutter rather than a word space: a thirtieth of the
    // text width, and never narrower than a glyph is tall. The second floor
    // is what a word space has to clear, and it scales with the type: the
    // line pitch would be the tidier number and is too large, because a real
    // two-column gutter is often only a little wider than a line is tall.
    const min_gap = @max(w / 40.0, medianHeight(boxes));
    const crossable = @max(1, rows / 8);

    var found: usize = 0;
    var run_start: ?usize = null;
    for (crossings, 0..) |c, bin| {
        if (c <= crossable) {
            if (run_start == null) run_start = bin;
            continue;
        }
        if (run_start) |s| {
            found += tryGutter(boxes, page, s, bin, step, min_gap, h, out[found..]);
            run_start = null;
        }
        if (found == out.len) break;
    }
    return out[0..found];
}

/// Accepts one empty band as a gutter if it is wide enough and there is a
/// column's worth of text, top to bottom, on both sides of it. Returns how
/// many were written -- one, or none.
fn tryGutter(
    boxes: []const Box,
    page: Bounds,
    first_bin: usize,
    end_bin: usize,
    step: f32,
    min_gap: f32,
    page_h: f32,
    out: []f32,
) usize {
    if (out.len == 0) return 0;
    const x0 = page.min_x + @as(f32, @floatFromInt(first_bin)) * step;
    const x1 = page.min_x + @as(f32, @floatFromInt(end_bin)) * step;
    if (x1 - x0 < min_gap) return 0;
    // A band touching either edge of the text is a margin, not a gutter.
    if (first_bin == 0 or end_bin >= bins) return 0;

    const mid = (x0 + x1) * 0.5;
    var left: Bounds = .empty;
    var right: Bounds = .empty;
    var n_left: usize = 0;
    var n_right: usize = 0;
    for (boxes) |b| {
        if (b.middle() < mid) {
            left = left.unionWith(b.box);
            n_left += 1;
        } else {
            right = right.unionWith(b.box);
            n_right += 1;
        }
    }
    const tenth = boxes.len / 10;
    if (n_left < tenth or n_right < tenth) return 0;
    if (left.height() < page_h * 0.55 or right.height() < page_h * 0.55) return 0;

    out[0] = mid;
    return 1;
}

/// The typical height of a glyph box, which stands in for the size of the
/// type the page is set in. A sample rather than every box: a page of a scan
/// has tens of thousands and the median of a few hundred of them evenly
/// spread down the page is the same number.
fn medianHeight(boxes: []const Box) f32 {
    var buf: [256]f32 = undefined;
    const n = @min(boxes.len, buf.len);
    if (n == 0) return 0;
    const stride = boxes.len / n;
    for (0..n) |i| buf[i] = boxes[i * stride].box.height();
    std.mem.sort(f32, buf[0..n], {}, std.sort.asc(f32));
    return buf[n / 2];
}

fn binOf(x: f32, origin: f32, step: f32) usize {
    if (!(step > 0)) return 0;
    const k = (x - origin) / step;
    if (!(k > 0)) return 0;
    return @min(@as(usize, @intFromFloat(k)), bins - 1);
}

/// Whether a glyph shares a height with the one that started the row, for the
/// scan that counts how many rows cross each slice of the page. Looser than
/// `sameLine` on purpose: a row here is every glyph at a height, across every
/// column, which is exactly what has to cross a gutter to close it.
fn overlapsRow(first: Bounds, b: Bounds) bool {
    return @min(first.max_y, b.max_y) - @max(first.min_y, b.min_y) > 0;
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
        .advance = advance * @as(f32, @floatFromInt(n)),
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

    // The last glyph has no next to measure against, and is measured against
    // where the pen finished instead -- the same advance as the rest.
    try testing.expectApproxEqAbs(@as(f32, 6), page.boxes[3].box.width(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 124), page.lines[0].box.max_x, 0.01);
}

test "the line ends where the pen did, not half an em past its last letter" {
    const gpa = testing.allocator;

    // Two lines of one run each, justified to the same right margin at 200:
    // the first ends in a narrow letter and the second in a wide one, which
    // in a real document means the last glyph *starts* in different places.
    const glyphs = try gpa.alloc(DisplayList.Glyph, 4);
    defer gpa.free(glyphs);
    glyphs[0] = .{ .code = 'x', .offset = .{ .x = 0, .y = 0 } };
    glyphs[1] = .{ .code = 'l', .offset = .{ .x = 97, .y = 0 } };
    glyphs[2] = .{ .code = 'x', .offset = .{ .x = 0, .y = 0 } };
    glyphs[3] = .{ .code = 'm', .offset = .{ .x = 92, .y = 0 } };

    const cmds = try gpa.alloc(DisplayList.DrawCmd, 2);
    defer gpa.free(cmds);
    for (cmds, 0..) |*c, i| c.* = .{ .text = .{
        .size = 10,
        .transform = .translation(100, 700 - 12 * @as(f32, @floatFromInt(i))),
        .glyphs = .{ .start = @intCast(i * 2), .count = 2 },
        .advance = 100,
    } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), page.lines.len);
    // Both end at the margin. Half a size each would have put them at 202
    // and 197, which is the ragged selection edge this is here to stop.
    try testing.expectApproxEqAbs(@as(f32, 200), page.lines[0].box.max_x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 200), page.lines[1].box.max_x, 0.01);
}

test "a run that never said where its pen finished still gets a box" {
    const gpa = testing.allocator;

    // `advance` is zero on a display list built by hand rather than by the
    // interpreter, and a zero-width last glyph would be a caret position
    // nobody could click on.
    const glyphs = try gpa.alloc(DisplayList.Glyph, 1);
    defer gpa.free(glyphs);
    glyphs[0] = .{ .code = 'a', .offset = .origin };

    var cmds = try gpa.alloc(DisplayList.DrawCmd, 1);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{
        .size = 10,
        .transform = .translation(100, 700),
        .glyphs = .{ .start = 0, .count = 1 },
    } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);

    try testing.expectApproxEqAbs(@as(f32, 5), page.boxes[0].box.width(), 0.01);
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

test "a dropped subscript is folded back into its line, a stacked one is not" {
    const gpa = testing.allocator;

    // A line of five glyphs at size ten with a subscript under the third:
    // set at seven points and dropped two, which is what `x_i` looks like in
    // a paper and is too little box overlap for the line test on its own.
    const glyphs = try gpa.alloc(DisplayList.Glyph, 6);
    defer gpa.free(glyphs);
    for (glyphs[0..5], 0..) |*g, i| g.* = .{
        .code = 'a' + @as(u32, @intCast(i)),
        .offset = .{ .x = 6 * @as(f32, @floatFromInt(i)), .y = 0 },
    };
    glyphs[5] = .{ .code = 'i', .offset = .origin };

    var cmds = try gpa.alloc(DisplayList.DrawCmd, 2);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{
        .size = 10,
        .transform = .translation(100, 700),
        .glyphs = .{ .start = 0, .count = 5 },
    } };
    cmds[1] = .{ .text = .{
        .size = 7,
        .transform = .translation(113, 698),
        .glyphs = .{ .start = 5, .count = 1 },
    } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), page.lines.len);
    try testing.expectEqual(@as(u32, 6), page.lines[0].count);
    // And in reading order along the line, between the glyph it belongs to
    // and the one after it.
    try testing.expectEqual(@as(u32, 'i'), page.lines[0].glyphs(page)[3].code);
    // The baseline stays the words', not the subscript's.
    try testing.expectApproxEqAbs(@as(f32, 700), page.lines[0].baseline, 0.5);

    // The row of a displayed equation is far enough below to stay its own
    // line: this is the case the fold must not swallow.
    cmds[1] = .{ .text = .{
        .size = 10,
        .transform = .translation(113, 692),
        .glyphs = .{ .start = 5, .count = 1 },
    } };
    var stacked = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer stacked.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), stacked.lines.len);
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
    try testing.expectEqual(@as(u32, 0), page.lineAt(100, 400));
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

test "two columns are read down one and then down the other" {
    // Two columns of forty lines each: x = 60..260 and x = 300..500, the
    // gutter forty points wide. Emitted a row at a time, left then right,
    // which is what an interleaved producer does and the order that used to
    // put them on one line together.
    const gpa = testing.allocator;

    const rows = 40;
    const per_line = 20;
    const n = rows * per_line * 2;
    const glyphs = try gpa.alloc(DisplayList.Glyph, n);
    defer gpa.free(glyphs);
    var cmds = try gpa.alloc(DisplayList.DrawCmd, rows * 2);
    defer gpa.free(cmds);

    var g: u32 = 0;
    for (0..rows) |r| {
        for ([_]f32{ 60, 300 }, 0..) |x, side| {
            for (0..per_line) |i| {
                glyphs[g + i] = .{
                    .code = 'a',
                    .offset = .{ .x = 10 * @as(f32, @floatFromInt(i)), .y = 0 },
                };
            }
            cmds[r * 2 + side] = .{ .text = .{
                .size = 10,
                .transform = .translation(x, 700 - 14 * @as(f32, @floatFromInt(r))),
                .glyphs = .{ .start = g, .count = per_line },
            } };
            g += per_line;
        }
    }

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);

    // Forty lines a column, not forty lines of both columns together.
    try testing.expectEqual(@as(usize, rows * 2), page.lines.len);
    for (page.lines[0..rows]) |l| {
        try testing.expectEqual(@as(u32, 0), l.column);
        try testing.expect(l.box.max_x < 290);
    }
    for (page.lines[rows..]) |l| {
        try testing.expectEqual(@as(u32, 1), l.column);
        try testing.expect(l.box.min_x > 290);
    }

    // The left column runs top to bottom before the right one starts, so the
    // lines between two points in one column are all in that column.
    try testing.expect(page.lines[0].baseline > page.lines[rows - 1].baseline);
    try testing.expect(page.lines[rows].baseline > page.lines[rows * 2 - 1].baseline);

    // A click in the right column lands in the right column, not on the left
    // column's line at the same height.
    const right = page.lineAt(400, 700 - 14 * 5);
    try testing.expectEqual(@as(u32, 1), page.lines[right].column);
    const left = page.lineAt(100, 700 - 14 * 5);
    try testing.expectEqual(@as(u32, 0), page.lines[left].column);
    try testing.expectApproxEqAbs(page.lines[left].baseline, page.lines[right].baseline, 0.5);
}

test "one column of the same text stays one column" {
    // The same page with the gutter closed: a single block of text must not
    // be cut in two by a ragged edge or a word space.
    const gpa = testing.allocator;

    const rows = 40;
    const per_line = 44;
    const glyphs = try gpa.alloc(DisplayList.Glyph, rows * per_line);
    defer gpa.free(glyphs);
    var cmds = try gpa.alloc(DisplayList.DrawCmd, rows);
    defer gpa.free(cmds);

    var g: u32 = 0;
    for (0..rows) |r| {
        // Ragged right: every third line is short, the way a paragraph ends.
        const count: u32 = if (r % 3 == 0) per_line / 2 else per_line;
        for (0..count) |i| {
            glyphs[g + i] = .{
                .code = if (i % 6 == 5) ' ' else 'a',
                .offset = .{ .x = 10 * @as(f32, @floatFromInt(i)), .y = 0 },
            };
        }
        cmds[r] = .{ .text = .{
            .size = 10,
            .transform = .translation(60, 700 - 14 * @as(f32, @floatFromInt(r))),
            .glyphs = .{ .start = g, .count = count },
        } };
        g += count;
    }

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds[0..rows] });
    defer page.deinit(gpa);

    try testing.expectEqual(@as(usize, rows), page.lines.len);
    for (page.lines) |l| try testing.expectEqual(@as(u32, 0), l.column);
}
