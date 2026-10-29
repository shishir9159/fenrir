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
//! right column had at the same heights. `findGutters` is what stops that,
//! and `findBands` stops it on the pages where a full-width figure or caption
//! crosses the gutter and no gutter runs the height of the page.
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
//! ## The page as a string
//!
//! `Page.text` is the same glyphs read as words: every line's text end to
//! end, in reading order, with a newline between lines. It exists so that a
//! search is a substring search over one buffer rather than a walk over
//! boxes, and every box and line carries its span of it, so a byte offset
//! comes back as a rectangle on the page in two binary searches.
//!
//! What a code *means* is not worked out here. `DisplayList.unicodeFor` has
//! it, resolved once per font by the layer that could still see the font
//! dictionary; this asks per glyph and writes down the answer.
//!
//! The only text this file invents is the word spaces, and the rule for them
//! is `gapIsSpace`, which is worth reading before changing anything about
//! word boundaries.
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
    /// carries it. Kept beside the text because it is what a font binding
    /// and a trace are written in terms of.
    code: u32 = 0,
    /// What this glyph says, as a span of `Page.text`. Usually one letter;
    /// several for a ligature, and none for a code the document gives no
    /// meaning to.
    at: u32 = 0,
    len: u8 = 0,
    /// In PDF user space.
    box: Bounds = .empty,
    /// The glyph's own baseline in user space -- where the pen was, not where
    /// the box's bottom edge is. Kept because the box is padded by a guessed
    /// descender, and grouping by a guess would put the lines of a document
    /// two points off where its text actually sits.
    base: f32 = 0,
    /// True when this glyph *is* a space, taken from what it says rather
    /// than from its code: a composite font's code 32 is a CID and means
    /// whatever the character collection says it means, which on a page of
    /// Japanese is a letter.
    space: bool = false,

    pub fn isSpace(b: Box) bool {
        return b.space;
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
    /// Which column of the page the line belongs to, counting from the left
    /// and then down the page a band at a time: a full-width figure above two
    /// columns is column 0, and the columns under it are 1 and 2. Zero on a
    /// page with one column, which is most of them.
    column: u32 = 0,
    /// Which band of the page the line is in, counting down. See `group`.
    band: u32 = 0,
    /// The line as a span of `Page.text`, its inserted word spaces included
    /// and its newline not.
    at: u32 = 0,
    len: u32 = 0,

    pub fn glyphs(l: Line, page: Page) []const Box {
        return page.boxes[l.first..][0..l.count];
    }

    pub fn string(l: Line, page: Page) []const u8 {
        return page.text[@min(l.at, page.text.len)..][0..@min(l.len, page.text.len - l.at)];
    }
};

/// One page's text, laid out.
pub const Page = struct {
    boxes: []Box = &.{},
    lines: []Line = &.{},
    /// The whole page as one string, in reading order: each line's glyphs
    /// end to end, a space where a word boundary was drawn as a gap rather
    /// than as a space, and a newline between lines.
    ///
    /// One string and not one per line, because a search is a substring
    /// search and a search that had to be run per line would miss nothing
    /// and allocate per line to find it. Every box and every line carries
    /// its span of this, so a byte offset in here goes back to a rectangle
    /// on the page in two binary searches.
    text: []const u8 = &.{},

    pub fn deinit(p: *Page, gpa: Allocator) void {
        gpa.free(p.boxes);
        gpa.free(p.lines);
        gpa.free(p.text);
        p.* = .{};
    }

    pub fn isEmpty(p: Page) bool {
        return p.lines.len == 0;
    }

    /// What one glyph says.
    pub fn stringOf(p: Page, b: Box) []const u8 {
        if (b.at >= p.text.len) return &.{};
        return p.text[b.at..][0..@min(b.len, p.text.len - b.at)];
    }

    /// Where a byte of `text` is on the page: the glyph that wrote it, as an
    /// index into `boxes`.
    ///
    /// Boxes are in reading order and so their spans ascend, which is what
    /// makes this a search rather than a scan -- a match in the footnotes of
    /// a dense page is forty thousand boxes in.
    ///
    /// A byte that no glyph wrote -- an inserted word space, a newline --
    /// belongs to the glyph before it, which is the one a search wants: a
    /// match beginning at a space still has to highlight something.
    pub fn glyphAt(p: Page, at: u32) ?u32 {
        if (p.boxes.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = p.boxes.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (p.boxes[mid].at <= at) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) 0 else @intCast(lo - 1);
    }

    /// Which line a box belongs to. Lines are spans of `boxes` in order, so
    /// this is the same search from the other side.
    pub fn lineOf(p: Page, box: u32) u32 {
        if (p.lines.len == 0) return 0;
        var lo: usize = 0;
        var hi: usize = p.lines.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (p.lines[mid].first <= box) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) 0 else @intCast(lo - 1);
    }

    /// The line nearest a point in user space, for a click and for a cursor
    /// arriving from the page above.
    ///
    /// The column is chosen first and the baseline second, because on a paper
    /// the left column's lines are the same height as the right column's: a
    /// click in one of them must not land in the other, however close the
    /// baseline is. Within a column the nearest baseline wins, so a click in
    /// the margin beside a line still lands on that line.
    ///
    /// The band is chosen before either. A drag down the left column under a
    /// full-width figure must stay in that column, and the figure's own lines
    /// are as near its x as the column's are -- nearer, being wider.
    pub fn lineAt(p: Page, x: f32, y: f32) u32 {
        if (p.lines.len == 0) return 0;

        const want = p.columnNear(p.bandNear(y), x);
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

    /// The band whose lines come nearest a height: the one it is in, or the
    /// nearer of the two it falls between.
    pub fn bandNear(p: Page, y: f32) u32 {
        var best: u32 = 0;
        var best_d: f32 = std.math.floatMax(f32);
        for (p.lines) |l| {
            const d = if (y < l.box.min_y)
                l.box.min_y - y
            else if (y > l.box.max_y)
                y - l.box.max_y
            else
                0;
            if (d < best_d) {
                best_d = d;
                best = l.band;
            }
        }
        return best;
    }

    /// The column of `band` whose lines come nearest an x, which is the
    /// column a click at that x is in.
    pub fn columnNear(p: Page, band: u32, x: f32) u32 {
        var best: u32 = 0;
        var best_d: f32 = std.math.floatMax(f32);
        for (p.lines) |l| {
            if (l.band != band) continue;
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
    /// Two signs, either of which will do: a space glyph before it, or a
    /// visible gap between the two boxes. See `gapIsSpace`.
    pub fn wordStart(p: Page, line: u32, i: u32) bool {
        if (line >= p.lines.len) return false;
        const glyphs = p.lines[line].glyphs(p);
        if (i >= glyphs.len) return false;
        if (glyphs[i].isSpace()) return false;
        if (i == 0) return true;
        return glyphs[i - 1].isSpace() or gapIsSpace(glyphs[i - 1], glyphs[i]);
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

    // What each glyph says, in the order the content stream drew them. The
    // page's own string cannot be built here: reading order is not drawing
    // order and is not known until the boxes have been grouped. So the text
    // is gathered once, addressed by span, and copied into its final order
    // below -- which is one pass over a few hundred kilobytes rather than
    // resolving every code a second time.
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var meaning_buf: [DisplayList.max_unicode]u8 = undefined;

    for (list.cmds) |cmd| {
        const run = switch (cmd) {
            .text => |t| t,
            else => continue,
        };
        const glyphs = list.glyphsOf(run);
        if (glyphs.len == 0) continue;

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

            const meaning = list.unicodeFor(run.font, g.code, &meaning_buf);
            const at: u32 = @intCast(scratch.items.len);
            try scratch.appendSlice(gpa, meaning);

            const pen = run.transform.apply(g.offset);
            try boxes.append(gpa, .{
                .code = g.code,
                .at = at,
                .len = @intCast(meaning.len),
                .box = box,
                .base = pen.y,
                .space = meaning.len == 1 and meaning[0] == ' ',
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
    errdefer gpa.free(lines);
    const text = try flatten(gpa, owned, lines, scratch.items);
    return .{ .boxes = owned, .lines = lines, .text = text };
}

/// Puts the page's text together in reading order, and rewrites every box's
/// and line's span to point into it.
///
/// The two insertions are the whole of the work. A **space** goes in wherever
/// a word boundary was drawn as a gap rather than as a space glyph, which on
/// a page set by TeX is every word boundary there is -- without it the page
/// reads as one unbroken word and no search for two words could match. A
/// **newline** goes between lines, and not a space, because a line break is
/// the one thing a reader can see in the extracted text that tells them the
/// match they are looking at spans two lines.
fn flatten(
    gpa: Allocator,
    boxes: []Box,
    lines: []Line,
    scratch: []const u8,
) Allocator.Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    try text.ensureTotalCapacity(gpa, scratch.len + boxes.len / 4);

    for (lines, 0..) |*l, i| {
        if (i != 0) try text.append(gpa, '\n');
        l.at = @intCast(text.items.len);

        const on_line = boxes[l.first..][0..l.count];
        for (on_line, 0..) |*b, k| {
            // Two spaces in a row would be a word break that a search for
            // "the end" could not match across, so a drawn space suppresses
            // an inserted one on either side of it.
            if (k != 0 and !b.space and !on_line[k - 1].space and
                gapIsSpace(on_line[k - 1], b.*))
            {
                try text.append(gpa, ' ');
            }

            const said = scratch[b.at..][0..b.len];
            b.at = @intCast(text.items.len);
            try text.appendSlice(gpa, said);
        }

        l.len = @intCast(text.items.len - l.at);
    }

    return text.toOwnedSlice(gpa);
}

/// Whether the space between two glyphs on a line is a word boundary.
///
/// This is the *only* word boundary a PDF has that is not a space glyph, and
/// working out why took a page of measurements. A document set by TeX never
/// draws a space: the gap is a number in a `TJ` array. But a number in a `TJ`
/// array moves the text matrix, which ends the run -- so an interword gap is
/// never inside a run at all, it is a run that starts a few points to the
/// right of where the last one finished. Inside a run, every offset comes
/// from `/Widths` plus a spacing that is the same for every glyph, so a long
/// advance there is a wide letter and nothing else.
///
/// Which is why the old rule here -- an advance longer than the run's typical
/// one -- could only ever be wrong. It fired on the `A` of `Alternative` and
/// the `m` of `commonly`, and it could not fire on a word boundary, because
/// the last glyph of a run has no next glyph to be measured against.
///
/// On the paper this was measured against, at 14.35pt: every gap within a
/// word is between -0.5 and 0, and every gap between words is 3.5 or more.
/// A seventh of the glyph's height sits in the middle of that and scales
/// with the type, so it means the same on a footnote as on a heading.
fn gapIsSpace(prev: Box, next: Box) bool {
    return next.box.min_x - prev.box.max_x > next.box.height() * 0.15;
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
///
/// A page is read a *band* at a time, top to bottom, and each band down its
/// own columns. Most pages are one band. The others are the ones a two-column
/// paper puts a full-width figure, caption or title on: its lines cross the
/// gutter, so no gutter runs the height of the page, and without bands the
/// whole page came out as one column -- the left and right columns fused
/// into one line at every height, and a drag down the left column selecting
/// the right one too. The author reported that as a regression of the
/// column work; `findBands` is the fix. Do not go back to one set of
/// gutters for the page.
fn group(gpa: Allocator, boxes: []Box) Allocator.Error![]Line {
    // Down the page, which is the order the gutter scan reads rows in.
    std.mem.sort(Box, boxes, {}, struct {
        fn less(_: void, a: Box, b: Box) bool {
            if (a.box.min_y != b.box.min_y) return a.box.min_y > b.box.min_y;
            return a.box.min_x < b.box.min_x;
        }
    }.less);

    var bands_buf: [max_bands]Band = undefined;
    const bands = findBands(boxes, &bands_buf);

    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(gpa);

    // How far off a baseline a fragment may sit and still belong to the line
    // above it. See `fold` below for what this is for and why it is this
    // number.
    const fold_gap = medianHeight(boxes) * 0.35;

    var column_base: u32 = 0;
    var band_start: usize = 0;
    for (bands, 0..) |*band, band_index| {
        if (band.end <= band_start) continue;
        const gutters = band.cuts();

        // Column first, then down the band, then along each line. User space
        // counts upwards, so "down" is descending y. A band is a run of whole
        // rows of the sort above, so sorting it in place keeps every band
        // after the one above it.
        if (gutters.len != 0) std.mem.sort(Box, boxes[band_start..band.end], gutters, struct {
            fn less(cuts: []const f32, a: Box, b: Box) bool {
                const ca = columnOf(cuts, a);
                const cb = columnOf(cuts, b);
                if (ca != cb) return ca < cb;
                if (a.box.min_y != b.box.min_y) return a.box.min_y > b.box.min_y;
                return a.box.min_x < b.box.min_x;
            }
        }.less);

        var start: usize = band_start;
        var i: usize = band_start + 1;
        while (i <= band.end) : (i += 1) {
            const ends = i == band.end or
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
                .column = column_base + columnOf(gutters, on_line[0]),
                .band = @intCast(band_index),
            };

            if (lines.items.len != 0 and fold(&lines.items[lines.items.len - 1], line, boxes, fold_gap)) {
                start = i;
                continue;
            }
            try lines.append(gpa, line);
            start = i;
        }
        column_base += @intCast(gutters.len + 1);
        band_start = band.end;
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

// -- bands --------------------------------------------------------------------

/// As many bands as a page is cut into. A paper's worst is a title, a figure,
/// its caption and the columns under them; sixteen is that twice over, and
/// past it the last band takes the rest.
const max_bands = 16;

/// As many rows as the band search looks at. A page of prose is fifty and a
/// dense table a few hundred; a page past this is read as one band, rather
/// than costing an allocation per page to hold its rows.
const max_rows = 1024;

/// How many rows a stretch has to run for before it is worth asking whether
/// it has columns: the same eight `findGutters` asks of a whole page.
const min_band_rows = 8;

/// A run of whole rows of the page, and the gutters that divide it.
const Band = struct {
    /// One past its last box, in the page's top-to-bottom order. A band
    /// begins where the one before it ended.
    end: u32,
    gutters: [max_columns - 1]f32 = undefined,
    n: u8 = 0,

    fn cuts(b: *const Band) []const f32 {
        return b.gutters[0..b.n];
    }
};

/// Cuts a page, sorted top to bottom, into bands, with each band's gutters.
///
/// A page with a gutter down its whole height is one band, exactly as it was
/// read before there were bands, and nothing below runs for it. Otherwise the
/// page is searched for the *stretch* of rows a gutter runs down -- the rows
/// under a full-width figure and its caption -- and that stretch is a band
/// with whatever gutters `findGutters` finds in it alone. Above and below it
/// are searched the same way, so columns, a wide table and columns again are
/// three bands.
///
/// A band's gutter has to pass every test a page's does, run on the band.
/// The band has to be a quarter of the page tall as well, which is what keeps
/// a two-column table on a page of prose from being read down its columns.
fn findBands(boxes: []const Box, out: *[max_bands]Band) []const Band {
    var whole: Band = .{ .end = @intCast(boxes.len) };
    whole.n = @intCast(findGutters(boxes, &whole.gutters).len);
    out[0] = whole;
    if (whole.n != 0) return out[0..1];

    var rows_buf: [max_rows + 1]u32 = undefined;
    const rows = rowStarts(boxes, &rows_buf) orelse return out[0..1];

    var page: Bounds = .empty;
    for (boxes) |b| page = page.unionWith(b.box);

    var list: BandList = .{ .out = out };
    splitBands(boxes, rows, 0, rows.len - 1, page, &list);
    if (list.len == 0) {
        out[0] = whole;
        return out[0..1];
    }
    return out[0..list.len];
}

/// Where each row of a sorted page begins, grouped the way `findGutters`
/// groups them, and one past the end. Null past `max_rows`.
fn rowStarts(boxes: []const Box, out: *[max_rows + 1]u32) ?[]const u32 {
    var n: usize = 0;
    var start: usize = 0;
    for (boxes, 0..) |b, i| {
        if (i != 0 and overlapsRow(boxes[start].box, b.box)) continue;
        if (n == max_rows) return null;
        out[n] = @intCast(i);
        n += 1;
        start = i;
    }
    out[n] = @intCast(boxes.len);
    return out[0 .. n + 1];
}

const BandList = struct {
    out: *[max_bands]Band,
    len: usize = 0,

    /// A band with no gutters. Two in a row are one band, so the single-
    /// column parts of a page cut around its columns read exactly as they
    /// would have uncut: a subscript still folds into the line above it.
    fn single(l: *BandList, end: u32) void {
        if (l.len != 0 and l.out[l.len - 1].n == 0) {
            l.out[l.len - 1].end = end;
            return;
        }
        l.push(.{ .end = end });
    }

    /// Past the last slot the last band takes the rest, by its own gutters.
    fn push(l: *BandList, b: Band) void {
        if (l.len == max_bands) {
            l.out[max_bands - 1].end = b.end;
            return;
        }
        l.out[l.len] = b;
        l.len += 1;
    }
};

/// Rows `lo..hi` of the page, as bands, appended in order.
fn splitBands(
    boxes: []const Box,
    rows: []const u32,
    lo: usize,
    hi: usize,
    page: Bounds,
    list: *BandList,
) void {
    if (lo >= hi) return;
    const found = columnStretch(boxes, rows, lo, hi, page) orelse return list.single(rows[hi]);
    splitBands(boxes, rows, lo, found.lo, page, list);
    list.push(found.band);
    splitBands(boxes, rows, found.hi, hi, page, list);
}

const Stretch = struct { lo: usize, hi: usize, band: Band };

/// The longest run of rows in `lo..hi` that some slice of x is never crossed
/// in, when that run has columns.
///
/// One pass down the rows counts, for every slice, the longest run of rows
/// that leave it empty. A gutter is a slice with a long one. So is the space
/// between two plots of a figure, which is why each candidate is put to
/// `findGutters` before it is believed -- longest first, and only a few:
/// the fifth-longest channel on a page is not its gutter.
///
/// A slice rather than the whole gutter, because an equation that pokes a
/// few points past the left column's edge breaks the run of the slices it
/// reaches and not of the rest.
///
/// Each glyph is widened by a third of its own height first, which closes a
/// word space and leaves a gutter open. Without it a caption or a running
/// title across the page has a word gap somewhere over the gutter, the run
/// goes straight through it, and the line is cut in two mid-word. Its own
/// height and not the page's, because the page's is a figure's tick labels
/// as often as it is the text.
fn columnStretch(boxes: []const Box, rows: []const u32, lo: usize, hi: usize, page: Bounds) ?Stretch {
    if (hi - lo < min_band_rows) return null;

    var region: Bounds = .empty;
    for (boxes[rows[lo]..rows[hi]]) |b| region = region.unionWith(b.box);
    const step = region.width() / bins;
    if (!(step > 0)) return null;

    var run: [bins]u16 = @splat(0);
    var longest: [bins]u16 = @splat(0);
    // One past the last row of each slice's longest run, counted from `lo`.
    var ends: [bins]u16 = @splat(0);
    var seen: [bins]bool = undefined;
    for (lo..hi) |r| {
        seen = @splat(false);
        // A line's glyphs arrive left to right and overlap once widened, so
        // they are merged into one span and marked once -- rather than every
        // slice under a line being written by the three glyphs over it.
        var span_lo: f32 = 0;
        var span_hi: f32 = -std.math.floatMax(f32);
        for (boxes[rows[r]..rows[r + 1]]) |b| {
            const widen = b.box.height() * 0.3;
            const x0 = b.box.min_x - widen;
            const x1 = b.box.max_x + widen;
            if (x0 <= span_hi and x1 >= span_lo) {
                span_lo = @min(span_lo, x0);
                span_hi = @max(span_hi, x1);
                continue;
            }
            if (span_hi >= span_lo) markSpan(&seen, span_lo, span_hi, region.min_x, step);
            span_lo = x0;
            span_hi = x1;
        }
        if (span_hi >= span_lo) markSpan(&seen, span_lo, span_hi, region.min_x, step);
        for (&run, &longest, &ends, seen) |*n, *best, *end, s| {
            n.* = if (s) 0 else n.* + 1;
            if (n.* > best.*) {
                best.* = n.*;
                end.* = @intCast(r + 1 - lo);
            }
        }
    }

    for (0..4) |_| {
        // The longest channel left, away from the region's edges: a slice
        // at either edge is a margin.
        var pick: usize = 1;
        for (2..bins - 1) |bin| {
            if (longest[bin] > longest[pick]) pick = bin;
        }
        const length = longest[pick];
        if (length < min_band_rows) return null;
        const end = ends[pick];
        // Every slice that ran down exactly these rows is this candidate.
        for (&longest, ends) |*l, e| {
            if (l.* == length and e == end) l.* = 0;
        }

        const r1 = lo + end;
        const r0 = r1 - length;
        const slice = boxes[rows[r0]..rows[r1]];
        var extent: Bounds = .empty;
        for (slice) |b| extent = extent.unionWith(b.box);
        if (extent.height() < page.height() * 0.25) continue;

        // The channel itself as the cut, before `findGutters` is paid for.
        // On a page of one column every candidate is a ragged edge or an
        // indent, with a sliver of text on one side, and fails here in one
        // pass over the glyphs; a scanned book is five hundred such pages.
        const channel = region.min_x + (@as(f32, @floatFromInt(pick)) + 0.5) * step;
        if (!columnsOfText(boxes, rows, r0, r1, &.{channel}, page.width())) continue;

        var band: Band = .{ .end = rows[r1] };
        band.n = @intCast(findGutters(slice, &band.gutters).len);
        if (band.n == 0) continue;

        // A line across a gutter is not in a column. `findGutters` lets a few
        // through, which is right inside a band -- an equation that pokes
        // into the gutter is still the left column's -- and wrong at its
        // ends, where the line is the running title above a figure, and cut
        // into the figure's columns it no longer reads as a title or finds
        // in a search. Those go to the band beside this one.
        var top = r0;
        var foot = r1;
        while (top < foot and crosses(boxes[rows[top]..rows[top + 1]], band.cuts())) top += 1;
        while (foot > top and crosses(boxes[rows[foot - 1]..rows[foot]], band.cuts())) foot -= 1;
        if (foot - top < min_band_rows) continue;
        if (!columnsOfText(boxes, rows, top, foot, band.cuts(), page.width())) continue;
        band.end = rows[foot];
        return .{ .lo = top, .hi = foot, .band = band };
    }
    return null;
}

/// Whether every column of a band is text set in columns: a sixth of the
/// page wide or more, and a third of its lines or more at least half its
/// width, which is what a paragraph's lines are.
///
/// The gaps between a figure's plots and between the words of a diagram are
/// gutters by every other test here. Read down them, a plot's tick labels
/// come out a subplot at a time, which is harmless, and a click in the white
/// beside a figure finds a label rather than the line it was level with,
/// which is not. Bands are for the columns of a paper, and only for them.
fn columnsOfText(
    boxes: []const Box,
    rows: []const u32,
    lo: usize,
    hi: usize,
    cuts: []const f32,
    page_w: f32,
) bool {
    const n = cuts.len + 1;
    const far = std.math.floatMax(f32);

    var left: [max_columns]f32 = @splat(far);
    var right: [max_columns]f32 = @splat(-far);
    for (boxes[rows[lo]..rows[hi]]) |b| {
        const c = columnOf(cuts, b);
        left[c] = @min(left[c], b.box.min_x);
        right[c] = @max(right[c], b.box.max_x);
    }
    for (0..n) |c| {
        if (!(right[c] - left[c] >= page_w / 6)) return false;
    }

    var used: [max_columns]u32 = @splat(0);
    var wide: [max_columns]u32 = @splat(0);
    for (lo..hi) |r| {
        var a: [max_columns]f32 = @splat(far);
        var z: [max_columns]f32 = @splat(-far);
        for (boxes[rows[r]..rows[r + 1]]) |b| {
            const c = columnOf(cuts, b);
            a[c] = @min(a[c], b.box.min_x);
            z[c] = @max(z[c], b.box.max_x);
        }
        for (0..n) |c| {
            if (z[c] < a[c]) continue;
            used[c] += 1;
            if (z[c] - a[c] >= (right[c] - left[c]) * 0.5) wide[c] += 1;
        }
    }
    for (0..n) |c| {
        if (wide[c] * 3 < used[c]) return false;
    }
    return true;
}

fn markSpan(seen: *[bins]bool, x0: f32, x1: f32, origin: f32, step: f32) void {
    const a = binOf(x0, origin, step);
    const z = binOf(x1, origin, step);
    @memset(seen[a .. z + 1], true);
}

/// Whether a row of glyphs runs across any of `cuts`, word spaces closed the
/// way `columnStretch` closes them.
fn crosses(row: []const Box, cuts: []const f32) bool {
    for (row) |b| {
        const widen = b.box.height() * 0.3;
        for (cuts) |cut| {
            if (b.box.min_x - widen < cut and cut < b.box.max_x + widen) return true;
        }
    }
    return false;
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
    // "ab cd" as TeX emits it: a `TJ` kern between the words, which moves
    // the text matrix and therefore ends the run. So it is two runs, and the
    // word gap is the 3.3 points between where one stops and the next
    // starts -- not an advance inside either of them.
    const gpa = testing.allocator;
    const glyphs = try gpa.alloc(DisplayList.Glyph, 4);
    defer gpa.free(glyphs);
    for (glyphs, 0..) |*g, i| g.* = .{
        .code = "abcd"[i],
        .offset = .{ .x = if (i % 2 == 0) 0 else 5, .y = 0 },
    };
    const cmds = try gpa.alloc(DisplayList.DrawCmd, 2);
    defer gpa.free(cmds);
    for (cmds, 0..) |*c, i| c.* = .{ .text = .{
        .size = 10,
        .transform = .translation(if (i == 0) 100 else 113.3, 700),
        .glyphs = .{ .start = @intCast(i * 2), .count = 2 },
        .advance = 10,
    } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);

    try testing.expect(page.wordStart(0, 0));
    try testing.expect(!page.wordStart(0, 1));
    try testing.expect(page.wordStart(0, 2));
    try testing.expect(!page.wordStart(0, 3));

    try testing.expect(!page.wordEnd(0, 0));
    try testing.expect(page.wordEnd(0, 1));
    try testing.expect(page.wordEnd(0, 3));

    // And the page reads as two words, with the space nobody drew.
    try testing.expectEqualStrings("ab cd", page.text);
}

test "a wide letter is not a word break" {
    // `mwm` at size 10 with advances of 8 -- as wide as letters get, and
    // three points more than the letters either side of them. Inside a run
    // that is a wide glyph and never a space, because a kern would have
    // ended the run.
    const gpa = testing.allocator;
    const glyphs = try gpa.alloc(DisplayList.Glyph, 3);
    defer gpa.free(glyphs);
    for (glyphs, 0..) |*g, i| g.* = .{ .code = "mwm"[i], .offset = .{ .x = 8 * @as(f32, @floatFromInt(i)), .y = 0 } };
    var cmds = try gpa.alloc(DisplayList.DrawCmd, 1);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{ .size = 10, .transform = .translation(100, 700), .glyphs = .{ .start = 0, .count = 3 }, .advance = 24 } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);
    try testing.expect(!page.wordStart(0, 1));
    try testing.expect(!page.wordStart(0, 2));
    try testing.expectEqualStrings("mwm", page.text);
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

/// A block of lines for `blocksOf`: `count` lines fourteen points apart from
/// `top` down, each `per_line` glyphs ten points apart, drawn once at every x
/// in `at`.
const Block = struct { top: f32, count: u32, per_line: u32, at: []const f32 };

/// A page made of blocks of lines, emitted a row at a time across the page,
/// which is the interleaved order that fuses two columns if nothing stops it.
fn blocksOf(gpa: Allocator, blocks: []const Block) !DisplayList {
    var n_glyphs: u32 = 0;
    var n_runs: u32 = 0;
    for (blocks) |b| {
        n_glyphs += b.count * b.per_line * @as(u32, @intCast(b.at.len));
        n_runs += b.count * @as(u32, @intCast(b.at.len));
    }
    const glyphs = try gpa.alloc(DisplayList.Glyph, n_glyphs);
    errdefer gpa.free(glyphs);
    const cmds = try gpa.alloc(DisplayList.DrawCmd, n_runs);

    var g: u32 = 0;
    var c: u32 = 0;
    for (blocks) |b| {
        for (0..b.count) |r| {
            for (b.at) |x| {
                for (0..b.per_line) |i| glyphs[g + i] = .{
                    .code = 'a',
                    .offset = .{ .x = 10 * @as(f32, @floatFromInt(i)), .y = 0 },
                };
                cmds[c] = .{ .text = .{
                    .size = 10,
                    .transform = .translation(x, b.top - 14 * @as(f32, @floatFromInt(r))),
                    .glyphs = .{ .start = g, .count = b.per_line },
                    .advance = 10 * @as(f32, @floatFromInt(b.per_line)),
                } };
                g += b.per_line;
                c += 1;
            }
        }
    }
    return .{ .glyphs = glyphs, .cmds = cmds };
}

test "two columns under a full-width figure are still two columns" {
    // The page the author found this on: a figure and its caption across the
    // top of a two-column paper. Their lines cross the gutter, no gutter runs
    // the height of the page, and before bands the page was one column -- the
    // two columns fused at every height, and a drag down the left one took
    // the right one with it. It was reported as a regression; keep this.
    //
    // The caption is two lines under a solid figure, with a word space right
    // over the gutter -- page 8 of the paper it came from. Two lines is few
    // enough for a gutter to be allowed across, so if the word space opened
    // a way down, the caption would be taken into the columns and cut in two
    // mid-word.
    const gpa = testing.allocator;
    const list = try blocksOf(gpa, &.{
        .{ .top = 700, .count = 8, .per_line = 44, .at = &.{60} },
        .{ .top = 588, .count = 2, .per_line = 22, .at = &.{ 60, 283 } },
        .{ .top = 546, .count = 30, .per_line = 20, .at = &.{ 60, 300 } },
    });
    defer {
        gpa.free(list.glyphs);
        gpa.free(list.cmds);
    }

    var page = try build(gpa, list);
    defer page.deinit(gpa);

    // The figure's and the caption's ten lines, then thirty down the left,
    // then thirty down the right: nothing fused, the caption whole, and the
    // columns in reading order.
    try testing.expectEqual(@as(usize, 10 + 30 + 30), page.lines.len);
    for (page.lines[0..10]) |l| {
        try testing.expectEqual(@as(u32, 0), l.band);
        try testing.expect(l.box.max_x > 490);
    }
    for (page.lines[10..40]) |l| {
        try testing.expectEqual(@as(u32, 1), l.band);
        try testing.expect(l.box.max_x < 290);
    }
    for (page.lines[40..]) |l| {
        try testing.expectEqual(@as(u32, 1), l.band);
        try testing.expect(l.box.min_x > 290);
    }
    try testing.expect(page.lines[10].column != page.lines[40].column);

    // A drag down the left column stays in it: the line under the pointer at
    // the foot of the page is the left column's, so everything between the
    // two ends of the drag is too.
    const top = page.lineAt(100, 546);
    const foot = page.lineAt(100, 546 - 14 * 29);
    try testing.expectEqual(@as(u32, 10), top);
    try testing.expectEqual(@as(u32, 39), foot);
    for (page.lines[top .. foot + 1]) |l| try testing.expect(l.box.max_x < 290);

    // The right column at the same height, and the caption above either.
    try testing.expectEqual(@as(u32, 40), page.lineAt(400, 546));
    try testing.expectEqual(@as(u32, 8), page.lineAt(400, 588));
}

test "columns either side of a full-width block are two bands of columns" {
    // Columns, a table across the page, and columns again: read down the
    // first pair, across the table, then down the second pair -- not down the
    // left of both pairs as though the table were not there. Six rows of
    // table, because a page-wide gutter tolerates an eighth of the rows
    // crossing it and this has to be a page it gives up on.
    const gpa = testing.allocator;
    const list = try blocksOf(gpa, &.{
        .{ .top = 700, .count = 16, .per_line = 20, .at = &.{ 60, 300 } },
        .{ .top = 460, .count = 6, .per_line = 44, .at = &.{60} },
        .{ .top = 360, .count = 16, .per_line = 20, .at = &.{ 60, 300 } },
    });
    defer {
        gpa.free(list.glyphs);
        gpa.free(list.cmds);
    }

    var page = try build(gpa, list);
    defer page.deinit(gpa);

    try testing.expectEqual(@as(usize, 16 * 2 + 6 + 16 * 2), page.lines.len);
    const expect = [_]struct { first: usize, n: usize, left: bool, wide: bool }{
        .{ .first = 0, .n = 16, .left = true, .wide = false },
        .{ .first = 16, .n = 16, .left = false, .wide = false },
        .{ .first = 32, .n = 6, .left = true, .wide = true },
        .{ .first = 38, .n = 16, .left = true, .wide = false },
        .{ .first = 54, .n = 16, .left = false, .wide = false },
    };
    for (expect) |e| {
        for (page.lines[e.first..][0..e.n]) |l| {
            if (e.wide) {
                try testing.expect(l.box.max_x > 490);
            } else if (e.left) {
                try testing.expect(l.box.max_x < 290);
            } else {
                try testing.expect(l.box.min_x > 290);
            }
        }
    }
}

test "a page's text is its lines in reading order, one newline between them" {
    const gpa = testing.allocator;
    const glyphs = try gpa.alloc(DisplayList.Glyph, 4);
    defer gpa.free(glyphs);
    for (glyphs, 0..) |*g, i| g.* = .{ .code = "abcd"[i], .offset = .origin };
    const cmds = try gpa.alloc(DisplayList.DrawCmd, 4);
    defer gpa.free(cmds);
    // Two lines of two letters, emitted bottom line first: the file's order
    // is not reading order and the string has to be the second one.
    const place = [_][2]f32{ .{ 100, 680 }, .{ 110, 680 }, .{ 100, 700 }, .{ 110, 700 } };
    for (cmds, 0..) |*c, i| c.* = .{ .text = .{
        .size = 10,
        .transform = .translation(place[i][0], place[i][1]),
        .glyphs = .{ .start = @intCast(i), .count = 1 },
        .advance = 10,
    } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);
    try testing.expectEqualStrings("cd\nab", page.text);
    try testing.expectEqualStrings("cd", page.lines[0].string(page));
    try testing.expectEqualStrings("ab", page.lines[1].string(page));
}

test "a byte of the page's text goes back to the glyph that wrote it" {
    const gpa = testing.allocator;
    const glyphs = try gpa.alloc(DisplayList.Glyph, 6);
    defer gpa.free(glyphs);
    for (glyphs, 0..) |*g, i| g.* = .{ .code = "abcdef"[i], .offset = .{ .x = 5 * @as(f32, @floatFromInt(i % 3)), .y = 0 } };
    const cmds = try gpa.alloc(DisplayList.DrawCmd, 2);
    defer gpa.free(cmds);
    for (cmds, 0..) |*c, i| c.* = .{ .text = .{
        .size = 10,
        .transform = .translation(100, 700 - 20 * @as(f32, @floatFromInt(i))),
        .glyphs = .{ .start = @intCast(i * 3), .count = 3 },
        .advance = 15,
    } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);
    try testing.expectEqualStrings("abc\ndef", page.text);

    // The `e` is byte 5, and it is the fifth box, on the second line.
    const box = page.glyphAt(5).?;
    try testing.expectEqualStrings("e", page.stringOf(page.boxes[box]));
    try testing.expectEqual(@as(u32, 1), page.lineOf(box));

    // The newline was written by nobody, so it belongs to the glyph before
    // it -- a match that starts on a line break still has to be drawn.
    try testing.expectEqualStrings("c", page.stringOf(page.boxes[page.glyphAt(3).?]));
}

test "a drawn space is not doubled by an inserted one" {
    const gpa = testing.allocator;
    const glyphs = try gpa.alloc(DisplayList.Glyph, 3);
    defer gpa.free(glyphs);
    for (glyphs, 0..) |*g, i| g.* = .{ .code = "a b"[i], .offset = .origin };
    const cmds = try gpa.alloc(DisplayList.DrawCmd, 3);
    defer gpa.free(cmds);
    // Three runs, each a visible gap apart -- so every boundary looks like a
    // word break, and the middle one already draws a space.
    for (cmds, 0..) |*c, i| c.* = .{ .text = .{
        .size = 10,
        .transform = .translation(100 + 12 * @as(f32, @floatFromInt(i)), 700),
        .glyphs = .{ .start = @intCast(i), .count = 1 },
        .advance = 5,
    } };

    var page = try build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer page.deinit(gpa);
    try testing.expectEqualStrings("a b", page.text);
}
