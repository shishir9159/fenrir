//! One window onto a buffer: where it is scrolled, how far it is zoomed, and
//! where its cursor stands.
//!
//! Everything here is *per view*. Two splits showing the same document have
//! two of these and one `Buffer`, which is the whole distinction: scroll one
//! and the other does not move, highlight in one and the other shows it,
//! because the scroll lives here and the highlight lives there.
//!
//! ## Coordinates, of which there are three
//!
//! **User space** -- PDF points, y upwards, origin at the bottom-left of a
//! page. What the document is written in, what a mark is stored in, and what
//! the cursor remembers.
//!
//! **View space** -- device pixels, y downwards, origin at this view's own
//! top-left corner, with the pages stacked down it and the scroll subtracted.
//! What `pageTop` and `scroll` are in.
//!
//! **Window space** -- device pixels from the window's top-left. View space
//! plus `rect`'s corner. Only `placement` and the input handlers convert, so
//! the arithmetic below never has to think about where in the window it is.
//!
//! A view borrows its buffer's `pages` and does not own them. The buffer
//! outlives every view on it, which `Layout` enforces by closing views first.

const std = @import("std");

const fenrir = @import("../root.zig");
const gelgja = @import("../gelgja.zig");
const text = @import("text.zig");

const Bounds = gelgja.Bounds;
const Point = gelgja.Point;
const Transform = gelgja.Transform;

const View = @This();

/// Between pages, and around the document, in device pixels rather than
/// points: the gap is a property of the screen you are reading on, not of the
/// paper, so it should not grow when you zoom in.
pub const gap = 14.0;

pub const min_zoom = 0.15;
pub const max_zoom = 8.0;

/// How far either side of the thumb still counts as the thumb. A six-pixel
/// bar is a hard target with a mouse and an impossible one on a trackpad.
pub const grab_margin = 6.0;

/// Which buffer this is looking at. An index into the session's buffer list,
/// not a pointer, because that list moves when a document is opened.
buffer: u32 = 0,

/// The buffer's pages, borrowed. Valid for as long as the buffer is open.
pages: []const fenrir.Page = &.{},

/// Where this view sits in the window, in device pixels. Assigned by
/// `Layout.arrange`; a view never decides its own rectangle.
rect: Bounds = .fromRect(0, 0, 1, 1),

/// The top of the viewport, in view-space pixels at the current zoom.
scroll: f32 = 0,
/// Sideways, for when a page is wider than the view.
pan: f32 = 0,
zoom: f32 = 1,

/// Fit the page width as soon as there is a rectangle to fit to. Set when
/// neither `--zoom` nor a remembered zoom said otherwise.
fit_on_open: bool = false,

/// The zoom follows the width of this view, rather than being a number.
///
/// A *mode*, not an action, because that is what "fit width" means in every
/// reader anyone has used: split the window and each half refits; drag the
/// edge and the page follows. Set by `fitWidth`, cleared by any zoom that
/// names a number. Without it a split of a fitted window leaves two halves
/// each showing the middle of a page twice as wide as they are.
fit_width: bool = false,

/// Device pixels per logical pixel, from the platform, so that a percentage
/// means the page's true physical size.
dpi_scale: f32 = 1,

cursor: Cursor = .{},

/// Where the pointer took hold of the scrollbar thumb, as the distance from
/// the thumb's top to the pointer. Kept rather than recomputed, which is the
/// difference between a thumb that follows the grab and one that jumps so its
/// middle is under the cursor on the first pixel of movement.
dragging: ?f32 = null,
hot_thumb: bool = false,
was_down: bool = false,

/// Where a visual selection started, or null outside visual mode. Per window
/// and not per buffer, as in Vim: two windows on one document can each have
/// their own selection.
anchor: ?Position = null,

/// The buffer's `Marks.revision` as this view last drew it. Not equal means
/// something highlighted the document -- possibly another split -- and this
/// view's picture is stale.
marks_seen: u64 = 0,

/// A caret in the text: which glyph, on which line, of which page.
///
/// Held as indices and not as a rectangle because the rectangle depends on
/// the text map, which is built per page and evicted with the page cache. The
/// `caret` box is a cache of where those indices last resolved to, so that
/// drawing and scrolling work on a page whose map has since been dropped.
pub const Cursor = struct {
    page: u32 = 0,
    line: u32 = 0,
    /// Glyph index within the line. Equal to the line's length means the
    /// position *after* the last glyph, which is a place a caret can stand.
    column: u32 = 0,
    /// Where the caret is, in user space. Empty until it has been resolved
    /// against a text map at least once.
    caret: Bounds = .empty,
    /// Shown at all. A reader that has never pressed a cursor key has no
    /// caret on screen, the way a document viewer should not.
    visible: bool = false,
    /// The x the cursor is trying to keep as it moves up and down, in user
    /// space. Without it, moving down through a short line and back up lands
    /// in a different column than it started -- the single most irritating
    /// bug a text cursor can have.
    goal: f32 = 0,

    pub fn position(c: Cursor) Position {
        return .{ .page = c.page, .line = c.line, .column = c.column };
    }
};

/// A place in a document's text, independent of any window: which glyph of
/// which line of which page. What a selection is made of.
pub const Position = struct {
    page: u32 = 0,
    line: u32 = 0,
    column: u32 = 0,

    pub fn lessThan(a: Position, b: Position) bool {
        if (a.page != b.page) return a.page < b.page;
        if (a.line != b.line) return a.line < b.line;
        return a.column < b.column;
    }

    /// The two ends of a selection in reading order, whichever way it was
    /// dragged or extended.
    pub fn ordered(a: Position, b: Position) [2]Position {
        return if (b.lessThan(a)) .{ b, a } else .{ a, b };
    }
};

/// What a cursor move needs from the caller. The view has no document, so it
/// asks for the page it would like to continue on rather than fetching it.
pub const Move = enum {
    /// Done: the cursor is where it should be.
    moved,
    /// Nothing happened -- the top of the first page, or a page with no text.
    blocked,
    /// The cursor wants the page above, entered at its last line.
    page_above,
    /// The cursor wants the page below, entered at its first line.
    page_below,
};

pub const Step = enum {
    left,
    right,
    up,
    down,
    line_start,
    line_end,
    /// `w`: the start of the next word.
    word_next,
    /// `b`: the start of this word, or of the one before.
    word_previous,
    /// `e`: the end of this word, or of the next.
    word_end,

    /// Whether a move that runs off the page enters the next one at its
    /// start (forwards) or the previous one at its end.
    pub fn forwards(s: Step) bool {
        return switch (s) {
            .right, .down, .line_end, .word_next, .word_end => true,
            else => false,
        };
    }

    /// Whether this step moves along the text rather than between lines, in
    /// which case entering a new page means its first or last glyph rather
    /// than the column the cursor was keeping.
    pub fn alongText(s: Step) bool {
        return s != .up and s != .down;
    }
};

// -- layout -------------------------------------------------------------------

pub fn width(v: View) f32 {
    return @max(1, v.rect.width());
}

pub fn height(v: View) f32 {
    return @max(1, v.rect.height());
}

/// A page's size in device pixels, rounded exactly the way
/// `replay.canvasSize` rounds it, so a texture and the rectangle it is drawn
/// into are the same size to the pixel.
pub fn pageSize(v: View, index: usize) [2]f32 {
    const p = v.pages[index];
    return .{
        @max(1.0, @ceil(@as(f32, @floatCast(p.displayWidth())) * v.zoom)),
        @max(1.0, @ceil(@as(f32, @floatCast(p.displayHeight())) * v.zoom)),
    };
}

/// The top of page `index` in view-space pixels, before the scroll.
pub fn pageTop(v: View, index: usize) f32 {
    var y: f32 = gap;
    var i: usize = 0;
    while (i < index) : (i += 1) y += v.pageSize(i)[1] + gap;
    return y;
}

pub fn documentHeight(v: View) f32 {
    return v.pageTop(v.pages.len);
}

pub fn widestPage(v: View) f32 {
    var w: f32 = 1;
    for (0..v.pages.len) |i| w = @max(w, v.pageSize(i)[0]);
    return w;
}

pub fn maxScroll(v: View) f32 {
    return @max(0, v.documentHeight() - v.height());
}

pub fn clampScroll(v: *View) void {
    v.scroll = std.math.clamp(v.scroll, 0, v.maxScroll());
    const slack = @max(0, v.widestPage() + gap * 2 - v.width());
    v.pan = std.math.clamp(v.pan, -slack / 2, slack / 2);
}

/// The page occupying the middle of the viewport: what "which page am I on"
/// means when two of them are on screen at once.
pub fn currentPage(v: View) u32 {
    const middle = v.scroll + v.height() * 0.5;
    var i: usize = 0;
    while (i < v.pages.len) : (i += 1) {
        if (middle < v.pageTop(i) + v.pageSize(i)[1] + gap * 0.5) return @intCast(i);
    }
    return @intCast(v.pages.len -| 1);
}

pub fn scrollToPage(v: *View, index: usize) void {
    v.scroll = v.pageTop(index) - gap;
    v.clampScroll();
}

/// Changes the zoom about the middle of the viewport, so the line you were
/// reading stays where it was rather than sliding off the top.
///
/// A zoom to a number ends fit-width mode: someone who pressed `+` wants that
/// size, and a window resize snapping it back would be fighting them.
pub fn setZoom(v: *View, want: f32) void {
    v.fit_width = false;
    v.zoomAbout(want);
}

fn zoomAbout(v: *View, want: f32) void {
    const next = std.math.clamp(want, min_zoom, max_zoom);
    if (next == v.zoom) return;
    const page = v.currentPage();
    const top = v.pageTop(page);
    const into = (v.scroll + v.height() * 0.5 - top) / @max(1, v.pageSize(page)[1]);

    v.zoom = next;
    v.scroll = v.pageTop(page) + into * v.pageSize(page)[1] - v.height() * 0.5;
    v.clampScroll();
}

/// Fits the page width to the view, and stays fitted: see `fit_width`.
pub fn fitWidth(v: *View) void {
    v.fit_width = true;
    v.refit();
}

/// Re-applies fit-width to the view's current rectangle. Called by `Layout`
/// whenever it gives this view a new one.
pub fn refit(v: *View) void {
    if (!v.fit_width or v.pages.len == 0) return;
    const page = v.currentPage();
    const points: f32 = @floatCast(v.pages[page].displayWidth());
    if (points > 0) v.zoomAbout((v.width() - gap * 2) / points);
    v.pan = 0;
}

/// The `zoom` at which the page is its true physical size. A PDF point is
/// 1/72 inch and an unscaled display is 96 dpi by convention.
pub fn hundredPercent(v: View) f32 {
    return v.dpi_scale * (96.0 / 72.0);
}

pub fn percent(v: View) f32 {
    return v.zoom / v.hundredPercent() * 100.0;
}

/// Where page `index` sits in the *window*, as a matrix from its own page
/// space to the framebuffer. This is the one place view space becomes window
/// space.
pub fn placement(v: View, index: usize) Transform {
    const size = v.pageSize(index);
    const x = @round(v.rect.min_x + (v.width() - size[0]) * 0.5 + v.pan);
    const y = @round(v.rect.min_y + v.pageTop(index) - v.scroll);
    return Transform.scaling(v.zoom, v.zoom).concat(.translation(x, y));
}

/// The rectangle page `index` occupies in the window, in device pixels.
pub fn pageRect(v: View, index: usize) Bounds {
    const size = v.pageSize(index);
    const x = @round(v.rect.min_x + (v.width() - size[0]) * 0.5 + v.pan);
    const y = @round(v.rect.min_y + v.pageTop(index) - v.scroll);
    return .fromRect(x, y, x + size[0], y + size[1]);
}

/// Which pages have pixels in this view, as a half-open range.
pub fn visiblePages(v: View) struct { first: u32, end: u32 } {
    var first: u32 = 0;
    var end: u32 = 0;
    var seen = false;
    var i: usize = 0;
    while (i < v.pages.len) : (i += 1) {
        const top = v.pageTop(i) - v.scroll;
        if (top + v.pageSize(i)[1] <= 0) continue;
        if (top >= v.height()) break;
        if (!seen) {
            first = @intCast(i);
            seen = true;
        }
        end = @intCast(i + 1);
    }
    return .{ .first = first, .end = end };
}

/// The page's own extent in user space.
///
/// Always anchored at the origin, because the interpreter shifts the crop
/// box's corner there and applies `/Rotate` before anything is recorded. So
/// user space here is the page *as displayed*, which is what a highlight
/// should be stored in -- it stays on the same words if the file is later
/// re-saved with a different crop.
pub fn pageBox(v: View, index: usize) Bounds {
    const p = v.pages[index];
    return .fromRect(0, 0, @floatCast(p.displayWidth()), @floatCast(p.displayHeight()));
}

/// A point in the window, in the user space of `page`, or null if it is not
/// over that page. The inverse of `placement`, which is what a click needs.
pub fn userSpaceAt(v: View, index: usize, p: Point) ?Point {
    const rect = v.pageRect(index);
    if (!rect.contains(p)) return null;
    // Window to page pixels, then page pixels to user space: the same flip
    // `replay.pageTransform` applies, undone.
    return .{
        .x = (p.x - rect.min_x) / v.zoom,
        .y = v.pageBox(index).max_y - (p.y - rect.min_y) / v.zoom,
    };
}

/// The page under a window point, if any.
pub fn pageAt(v: View, p: Point) ?u32 {
    const range = v.visiblePages();
    var i = range.first;
    while (i < range.end) : (i += 1) {
        if (v.pageRect(i).contains(p)) return i;
    }
    return null;
}

/// A box in user space, as a rectangle in the window.
pub fn windowBox(v: View, index: usize, box: Bounds) Bounds {
    const rect = v.pageRect(index);
    const y1 = v.pageBox(index).max_y;
    // y flips: a larger user-space y is further up the screen.
    return .fromRect(
        rect.min_x + box.min_x * v.zoom,
        rect.min_y + (y1 - box.max_y) * v.zoom,
        rect.min_x + box.max_x * v.zoom,
        rect.min_y + (y1 - box.min_y) * v.zoom,
    );
}

// -- where the reader was left ------------------------------------------------

/// A place in a document, in units that do not depend on the window.
///
/// The page, and how far down it in *points* rather than pixels. A pixel
/// offset would put you somewhere else on reopening at a different zoom or on
/// a different screen, which is exactly the bug that makes "resume where I
/// was" not worth having.
pub const Place = struct {
    page: u32 = 0,
    /// Points from the top edge of that page. Negative in the gap above it.
    offset: f32 = 0,
    zoom: f32 = 0,
};

pub fn place(v: View) Place {
    const page = v.currentPage();
    const into = v.scroll - v.pageTop(page);
    return .{
        .page = page,
        .offset = if (v.zoom > 0) into / v.zoom else 0,
        .zoom = v.zoom,
    };
}

/// Scrolls to a remembered place. The zoom must already be set, since the
/// offset is converted through it.
pub fn goTo(v: *View, p: Place) void {
    if (p.page >= v.pages.len) return;
    v.scroll = v.pageTop(p.page) + p.offset * v.zoom;
    v.clampScroll();
}

// -- the cursor ---------------------------------------------------------------

/// Puts the cursor at the start of `page`, given that page's text map.
pub fn cursorToPage(v: *View, page: u32, map: text.Page, from_bottom: bool) void {
    v.cursor.page = page;
    v.cursor.visible = true;
    if (map.isEmpty()) {
        v.cursor.line = 0;
        v.cursor.column = 0;
        v.cursor.caret = .empty;
        return;
    }
    v.cursor.line = if (from_bottom) @intCast(map.lines.len - 1) else 0;
    v.cursor.column = map.columnAt(v.cursor.line, v.cursor.goal);
    v.resolve(map);
}

/// Moves the cursor one step, given the text map of the page it is on.
///
/// Returns what the caller must do next: nothing, or fetch a neighbouring
/// page's map and call `cursorToPage`. The view cannot do that itself because
/// it has no document -- and that separation is what lets every one of these
/// rules be tested without opening a file.
pub fn moveCursor(v: *View, step: Step, map: text.Page) Move {
    if (map.isEmpty()) {
        return switch (step) {
            .down => .page_below,
            .up => .page_above,
            else => .blocked,
        };
    }
    if (!v.cursor.visible) {
        // The first press shows the caret where the reader is looking rather
        // than moving it from wherever it was left.
        v.cursor.visible = true;
        v.cursor.line = @min(v.cursor.line, @as(u32, @intCast(map.lines.len - 1)));
        v.cursor.column = @min(v.cursor.column, map.lines[v.cursor.line].count);
        v.resolve(map);
        return .moved;
    }

    v.cursor.line = @min(v.cursor.line, @as(u32, @intCast(map.lines.len - 1)));
    const line = map.lines[v.cursor.line];

    switch (step) {
        .left => {
            if (v.cursor.column > 0) {
                v.cursor.column -= 1;
            } else if (v.cursor.line > 0) {
                v.cursor.line -= 1;
                v.cursor.column = map.lines[v.cursor.line].count;
            } else {
                return .page_above;
            }
            v.resolve(map);
            v.cursor.goal = (v.cursor.caret.min_x + v.cursor.caret.max_x) * 0.5;
            return .moved;
        },
        .right => {
            if (v.cursor.column < line.count) {
                v.cursor.column += 1;
            } else if (v.cursor.line + 1 < map.lines.len) {
                v.cursor.line += 1;
                v.cursor.column = 0;
            } else {
                return .page_below;
            }
            v.resolve(map);
            v.cursor.goal = (v.cursor.caret.min_x + v.cursor.caret.max_x) * 0.5;
            return .moved;
        },
        .up => {
            if (v.cursor.line == 0) return .page_above;
            v.cursor.line -= 1;
            v.cursor.column = map.columnAt(v.cursor.line, v.cursor.goal);
            v.resolve(map);
            return .moved;
        },
        .down => {
            if (v.cursor.line + 1 >= map.lines.len) return .page_below;
            v.cursor.line += 1;
            v.cursor.column = map.columnAt(v.cursor.line, v.cursor.goal);
            v.resolve(map);
            return .moved;
        },
        .line_start => {
            v.cursor.column = 0;
            v.resolve(map);
            v.cursor.goal = v.cursor.caret.min_x;
            return .moved;
        },
        .line_end => {
            v.cursor.column = line.count;
            v.resolve(map);
            v.cursor.goal = v.cursor.caret.max_x;
            return .moved;
        },
        .word_next => {
            // Forward to the next glyph that starts a word, across lines.
            var at = v.cursor.position();
            while (true) {
                at.column += 1;
                if (at.column >= map.lines[at.line].count) {
                    if (at.line + 1 >= map.lines.len) return .page_below;
                    at.line += 1;
                    at.column = 0;
                }
                if (map.wordStart(at.line, at.column)) break;
            }
            return v.land(map, at);
        },
        .word_previous => {
            var at = v.cursor.position();
            while (true) {
                if (at.column == 0) {
                    if (at.line == 0) return .page_above;
                    at.line -= 1;
                    at.column = map.lines[at.line].count;
                    if (at.column == 0) continue;
                }
                at.column -= 1;
                if (map.wordStart(at.line, at.column)) break;
            }
            return v.land(map, at);
        },
        .word_end => {
            var at = v.cursor.position();
            while (true) {
                at.column += 1;
                if (at.column >= map.lines[at.line].count) {
                    if (at.line + 1 >= map.lines.len) return .page_below;
                    at.line += 1;
                    at.column = 0;
                }
                if (map.wordEnd(at.line, at.column)) break;
            }
            return v.land(map, at);
        },
    }
}

/// Moves the cursor to a position on this page and makes that column the one
/// it keeps -- a word motion sets the goal, the way `w` does in Vim.
fn land(v: *View, map: text.Page, at: Position) Move {
    v.cursor.line = at.line;
    v.cursor.column = at.column;
    v.resolve(map);
    v.cursor.goal = v.cursor.caret.min_x;
    return .moved;
}

/// Enters a page from a move that ran off the one before or after it.
///
/// A move along the text -- `l`, `w`, `e` -- arrives at the first glyph of
/// the next page, and one backwards at the last glyph of the previous; a move
/// between lines keeps its column. Getting this wrong makes `w` at the end of
/// a page jump to the middle of the first line of the next.
pub fn enterPage(v: *View, page: u32, map: text.Page, step: Step) void {
    if (step.alongText()) v.cursor.goal = if (step.forwards()) -std.math.floatMax(f32) else std.math.floatMax(f32);
    v.cursorToPage(page, map, !step.forwards());
    if (map.isEmpty()) return;
    // `e` wants the end of the first word, not its start; and `b` the start
    // of the last word, not the position after the last glyph.
    switch (step) {
        .word_end => if (!map.wordEnd(v.cursor.line, v.cursor.column)) {
            _ = v.moveCursor(.word_end, map);
        },
        .word_previous => {
            v.cursor.column = map.lines[v.cursor.line].count;
            _ = v.moveCursor(.word_previous, map);
        },
        else => {},
    }
    if (step.alongText()) v.cursor.goal = v.cursor.caret.min_x;
}

/// Puts the cursor at a position, clamped to what the map holds.
pub fn cursorTo(v: *View, at: Position, map: text.Page) void {
    v.cursor.page = at.page;
    v.cursor.visible = true;
    if (map.isEmpty()) {
        v.cursor.line = 0;
        v.cursor.column = 0;
        v.cursor.caret = .empty;
        return;
    }
    v.cursor.line = @min(at.line, @as(u32, @intCast(map.lines.len - 1)));
    v.cursor.column = @min(at.column, map.lines[v.cursor.line].count);
    v.resolve(map);
    v.cursor.goal = v.cursor.caret.min_x;
}

/// Starts a visual selection at the cursor.
pub fn beginSelection(v: *View) void {
    v.anchor = v.cursor.position();
}

pub fn endSelection(v: *View) void {
    v.anchor = null;
}

/// `o` in visual mode: the cursor goes to the other end, and the end it left
/// becomes the anchor. Resolving the new caret is the caller's, because it
/// may be on another page with its own map.
pub fn swapSelectionEnds(v: *View) ?Position {
    const anchor = v.anchor orelse return null;
    v.anchor = v.cursor.position();
    return anchor;
}

/// The selection in reading order, or null outside visual mode.
pub fn selection(v: View) ?[2]Position {
    const anchor = v.anchor orelse return null;
    return Position.ordered(anchor, v.cursor.position());
}

/// Turns the cursor's indices into a caret box in user space.
///
/// The caret is a thin rectangle at the *leading edge* of the glyph it is on,
/// the width of a hairline at this zoom rather than of the glyph, because a
/// block cursor over proportional text reads as a selection.
fn resolve(v: *View, map: text.Page) void {
    if (map.isEmpty()) {
        v.cursor.caret = .empty;
        return;
    }
    const line = map.lines[@min(v.cursor.line, map.lines.len - 1)];
    if (line.count == 0) {
        v.cursor.caret = .fromRect(line.box.min_x, line.box.min_y, line.box.min_x, line.box.max_y);
        return;
    }
    const glyphs = line.glyphs(map);
    const at = @min(v.cursor.column, line.count);
    const x = if (at == line.count) glyphs[line.count - 1].box.max_x else glyphs[at].box.min_x;
    const top = if (at == line.count) glyphs[line.count - 1].box else glyphs[at].box;
    v.cursor.caret = .fromRect(x, top.min_y, x, top.max_y);
}

/// Brings the caret into view, scrolling as little as is needed.
///
/// Called after every cursor move, which is why it does nothing when the
/// caret is already on screen: a cursor that recentred the page on every
/// press would make reading down a page a series of jumps.
pub fn scrollToCursor(v: *View) void {
    if (!v.cursor.visible or v.cursor.caret.isEmpty()) return;
    v.scrollToBox(v.cursor.page, v.cursor.caret);
}

/// Brings a box in user space on `page` into view, scrolling as little as is
/// needed. The same rule as the cursor, for a highlight chosen in edit mode.
pub fn scrollToBox(v: *View, page: u32, user: Bounds) void {
    if (page >= v.pages.len or user.isEmpty()) return;

    const box = v.windowBox(page, user);
    const top = box.min_y - v.rect.min_y;
    const bottom = box.max_y - v.rect.min_y;
    // A line of slack at each edge, so the caret is never against the frame.
    const margin = @min(v.height() * 0.25, 60.0);

    if (top < margin) {
        v.scroll -= margin - top;
    } else if (bottom > v.height() - margin) {
        v.scroll += bottom - (v.height() - margin);
    }
    v.clampScroll();
}

// -- the scrollbar ------------------------------------------------------------

/// The scrollbar's geometry, or null when the document fits and there is no
/// scrollbar at all.
///
/// One function, because the thumb that is drawn and the thumb that is
/// grabbed have to be the same rectangle to within nothing. Computing it
/// twice is how a scrollbar ends up with a few pixels that look live and are
/// not.
pub const Scrollbar = struct {
    x0: f32,
    x1: f32,
    y: f32,
    height: f32,
    top: f32,
    travel: f32,

    pub fn holds(s: Scrollbar, p: Point) bool {
        return p.x >= s.x0 - grab_margin and p.x <= s.x1 + grab_margin and
            p.y >= s.y and p.y <= s.y + s.height;
    }

    pub fn onTrack(s: Scrollbar, p: Point) bool {
        return p.x >= s.x0 - grab_margin and p.x <= s.x1 + grab_margin;
    }

    pub fn scrollAt(s: Scrollbar, y: f32, max: f32) f32 {
        if (!(s.travel > 0)) return 0;
        return std.math.clamp((y - s.top) / s.travel, 0, 1) * max;
    }
};

pub fn scrollbarAt(v: View) ?Scrollbar {
    const total = v.documentHeight();
    if (total <= v.height()) return null;

    const track = v.height() - gap * 2;
    const h = @max(24.0, track * v.height() / total);
    const travel = track - h;
    return .{
        .x0 = v.rect.max_x - 12,
        .x1 = v.rect.max_x - 6,
        .y = v.rect.min_y + gap + travel * (v.scroll / @max(1, v.maxScroll())),
        .height = h,
        .top = v.rect.min_y + gap,
        .travel = travel,
    };
}

/// The pointer's half of the scrollbar: grab the thumb and drag it, or press
/// the track to move a screen towards the press.
///
/// Returns true when the pointer belongs to the scrollbar this frame, so the
/// caller knows not to treat the same press as anything else.
pub fn dragScrollbar(v: *View, mouse: Point, down: bool) bool {
    const pressed = down and !v.was_down;
    v.was_down = down;

    const bar = v.scrollbarAt() orelse {
        v.dragging = null;
        v.hot_thumb = false;
        return false;
    };

    if (v.dragging) |grab| {
        if (!down) {
            v.dragging = null;
            v.hot_thumb = bar.holds(mouse);
            return true;
        }
        v.scroll = bar.scrollAt(mouse.y - grab, v.maxScroll());
        v.hot_thumb = true;
        return true;
    }

    v.hot_thumb = bar.holds(mouse);
    if (!pressed or !bar.onTrack(mouse)) return false;

    if (v.hot_thumb) {
        v.dragging = mouse.y - bar.y;
        return true;
    }

    // The track: a screen towards the press, which is what every scrollbar
    // that is not a slider does. Jumping the thumb to the pointer instead
    // loses your place on a misclick.
    const screen = v.height() * 0.9;
    v.scroll += if (mouse.y < bar.y) -screen else screen;
    v.clampScroll();
    return true;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn fakePages(buf: []fenrir.Page, n: usize) []fenrir.Page {
    const letter: fenrir.Page.Rect = .{ .x0 = 0, .y0 = 0, .x1 = 600, .y1 = 800 };
    for (buf[0..n], 0..) |*p, i| p.* = .{
        .index = @intCast(i),
        .ref = .{ .num = 0, .gen = 0 },
        .dict = .empty,
        .resources = .empty,
        .media_box = letter,
        .crop_box = letter,
        .rotate = .none,
    };
    return buf[0..n];
}

fn viewOf(pages: []fenrir.Page, zoom: f32, w: f32, h: f32) View {
    return .{ .pages = pages, .zoom = zoom, .rect = .fromRect(0, 0, w, h) };
}

test "a view's arithmetic is in its own rectangle, not the window's" {
    var buf: [4]fenrir.Page = undefined;
    const pages = fakePages(&buf, 3);

    // The same view, once at the origin and once in the right-hand half of a
    // window. Everything about the layout is identical; only `placement` and
    // the scrollbar know where the rectangle is.
    var left = viewOf(pages, 1, 700, 500);
    var right = View{ .pages = pages, .zoom = 1, .rect = .fromRect(700, 0, 1400, 500) };

    try testing.expectEqual(left.documentHeight(), right.documentHeight());
    try testing.expectEqual(left.maxScroll(), right.maxScroll());

    left.scroll = 100;
    right.scroll = 100;
    try testing.expectEqual(left.currentPage(), right.currentPage());

    const lp = left.placement(0);
    const rp = right.placement(0);
    try testing.expectApproxEqAbs(@as(f32, 700), rp.e - lp.e, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), rp.f - lp.f, 0.001);

    // And the scrollbar is on the right edge of the *view*.
    try testing.expectApproxEqAbs(@as(f32, 1400 - 12), right.scrollbarAt().?.x0, 0.001);
}

test "a place is remembered in points, so reopening at another zoom lands there" {
    var buf: [8]fenrir.Page = undefined;
    var v = viewOf(fakePages(&buf, 6), 1, 700, 500);
    v.scrollToPage(3);
    v.scroll += 120; // 120 pixels at zoom 1 is 120 points down the page.

    const p = v.place();
    try testing.expectEqual(@as(u32, 3), p.page);

    // The same document opened at twice the zoom: the same *point* of the
    // page is at the top, which is twice as many pixels down.
    var other = viewOf(fakePages(&buf, 6), 2, 700, 500);
    other.goTo(p);
    const back = other.place();
    try testing.expectEqual(p.page, back.page);
    try testing.expectApproxEqAbs(p.offset, back.offset, 0.5);
}

test "the cursor keeps its column through a short line" {
    const gpa = testing.allocator;

    // Three lines: long, short, long. Moving down through the short one and
    // back up has to return to the column it started in.
    const glyphs = try gpa.alloc(gelgja.DisplayList.Glyph, 3 + 1 + 3);
    defer gpa.free(glyphs);
    for (glyphs, 0..) |*g, i| g.* = .{
        .code = 'a',
        .offset = .{ .x = 10 * @as(f32, @floatFromInt(i % 3)), .y = 0 },
    };
    var cmds = try gpa.alloc(gelgja.DisplayList.DrawCmd, 3);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{ .size = 10, .transform = .translation(100, 700), .glyphs = .{ .start = 0, .count = 3 } } };
    cmds[1] = .{ .text = .{ .size = 10, .transform = .translation(100, 680), .glyphs = .{ .start = 3, .count = 1 } } };
    cmds[2] = .{ .text = .{ .size = 10, .transform = .translation(100, 660), .glyphs = .{ .start = 4, .count = 3 } } };

    var map = try text.build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer map.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), map.lines.len);

    var buf: [2]fenrir.Page = undefined;
    var v = viewOf(fakePages(&buf, 1), 1, 700, 900);
    v.cursorToPage(0, map, false);

    // Out to the third column of the first line.
    try testing.expectEqual(Move.moved, v.moveCursor(.right, map));
    try testing.expectEqual(Move.moved, v.moveCursor(.right, map));
    const column = v.cursor.column;
    try testing.expectEqual(@as(u32, 2), column);

    // Down onto the short line, which cannot hold that column...
    try testing.expectEqual(Move.moved, v.moveCursor(.down, map));
    try testing.expectEqual(@as(u32, 1), v.cursor.line);
    // ...and down again onto a long one, where the goal column is recovered.
    try testing.expectEqual(Move.moved, v.moveCursor(.down, map));
    try testing.expectEqual(@as(u32, 2), v.cursor.line);
    try testing.expectEqual(column, v.cursor.column);
}

test "the cursor asks for the next page rather than fetching one" {
    const gpa = testing.allocator;
    const glyphs = try gpa.alloc(gelgja.DisplayList.Glyph, 1);
    defer gpa.free(glyphs);
    glyphs[0] = .{ .code = 'x', .offset = .origin };
    var cmds = try gpa.alloc(gelgja.DisplayList.DrawCmd, 1);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{ .size = 10, .transform = .translation(100, 700), .glyphs = .{ .start = 0, .count = 1 } } };

    var map = try text.build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer map.deinit(gpa);

    var buf: [2]fenrir.Page = undefined;
    var v = viewOf(fakePages(&buf, 2), 1, 700, 900);
    v.cursorToPage(0, map, false);

    // One line on the page, so up and down both run off it.
    try testing.expectEqual(Move.page_below, v.moveCursor(.down, map));
    try testing.expectEqual(Move.page_above, v.moveCursor(.up, map));

    // And a page with no text at all passes the cursor straight through
    // rather than swallowing it.
    try testing.expectEqual(Move.page_below, v.moveCursor(.down, .{}));
}

test "the caret is brought into view without recentring the page" {
    const gpa = testing.allocator;
    const glyphs = try gpa.alloc(gelgja.DisplayList.Glyph, 40);
    defer gpa.free(glyphs);
    var cmds = try gpa.alloc(gelgja.DisplayList.DrawCmd, 40);
    defer gpa.free(cmds);
    // Forty lines, twenty points apart, down an 800-point page.
    for (0..40) |i| {
        glyphs[i] = .{ .code = 'x', .offset = .origin };
        cmds[i] = .{ .text = .{
            .size = 10,
            .transform = .translation(100, 780 - 20 * @as(f32, @floatFromInt(i))),
            .glyphs = .{ .start = @intCast(i), .count = 1 },
        } };
    }
    var map = try text.build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
    defer map.deinit(gpa);

    var buf: [2]fenrir.Page = undefined;
    var v = viewOf(fakePages(&buf, 1), 1, 700, 400);
    v.cursorToPage(0, map, false);

    // A caret already comfortably on screen moves nothing.
    v.scroll = 0;
    const still = v.scroll;
    _ = v.moveCursor(.down, map);
    v.scrollToCursor();
    try testing.expectEqual(still, v.scroll);

    // Walking down past the bottom edge scrolls, and keeps scrolling by a
    // line rather than by a screen.
    var last = v.scroll;
    var jumps: u32 = 0;
    for (0..30) |_| {
        _ = v.moveCursor(.down, map);
        v.scrollToCursor();
        if (v.scroll - last > 100) jumps += 1;
        last = v.scroll;
    }
    try testing.expect(v.scroll > 0);
    try testing.expectEqual(@as(u32, 0), jumps);
}

/// Two lines of TeX-style text with no space glyphs: "ab cd" over "ef gh".
fn twoLines(gpa: std.mem.Allocator) !text.Page {
    const glyphs = try gpa.alloc(gelgja.DisplayList.Glyph, 8);
    defer gpa.free(glyphs);
    const xs = [_]f32{ 0, 5, 13.3, 18.3 };
    for (glyphs, 0..) |*g, i| g.* = .{ .code = "abcdefgh"[i], .offset = .{ .x = xs[i % 4], .y = 0 } };
    const cmds = try gpa.alloc(gelgja.DisplayList.DrawCmd, 2);
    defer gpa.free(cmds);
    cmds[0] = .{ .text = .{ .size = 10, .transform = .translation(100, 700), .glyphs = .{ .start = 0, .count = 4 } } };
    cmds[1] = .{ .text = .{ .size = 10, .transform = .translation(100, 680), .glyphs = .{ .start = 4, .count = 4 } } };
    return text.build(gpa, .{ .glyphs = glyphs, .cmds = cmds });
}

test "w, b and e move by words, across lines, and ask for the next page at the end" {
    const gpa = testing.allocator;
    var map = try twoLines(gpa);
    defer map.deinit(gpa);

    var buf: [2]fenrir.Page = undefined;
    var v = viewOf(fakePages(&buf, 2), 1, 700, 900);
    v.cursorToPage(0, map, false);
    try testing.expectEqual(Position{ .page = 0, .line = 0, .column = 0 }, v.cursor.position());

    try testing.expectEqual(Move.moved, v.moveCursor(.word_next, map));
    try testing.expectEqual(Position{ .page = 0, .line = 0, .column = 2 }, v.cursor.position());
    // Off the end of the line, onto the first word of the next.
    try testing.expectEqual(Move.moved, v.moveCursor(.word_next, map));
    try testing.expectEqual(Position{ .page = 0, .line = 1, .column = 0 }, v.cursor.position());

    try testing.expectEqual(Move.moved, v.moveCursor(.word_end, map));
    try testing.expectEqual(Position{ .page = 0, .line = 1, .column = 1 }, v.cursor.position());

    // Back over the line break to "cd".
    try testing.expectEqual(Move.moved, v.moveCursor(.word_previous, map));
    try testing.expectEqual(Position{ .page = 0, .line = 1, .column = 0 }, v.cursor.position());
    try testing.expectEqual(Move.moved, v.moveCursor(.word_previous, map));
    try testing.expectEqual(Position{ .page = 0, .line = 0, .column = 2 }, v.cursor.position());

    // At the last word of the page, `w` wants the next page.
    v.cursorTo(.{ .page = 0, .line = 1, .column = 2 }, map);
    try testing.expectEqual(Move.page_below, v.moveCursor(.word_next, map));
}

test "entering a page by moving along the text lands on its first or last word" {
    const gpa = testing.allocator;
    var map = try twoLines(gpa);
    defer map.deinit(gpa);

    var buf: [3]fenrir.Page = undefined;
    var v = viewOf(fakePages(&buf, 3), 1, 700, 900);

    // Keeping a column far to the right, as a cursor at a line end would.
    v.cursor.goal = 1e6;
    v.enterPage(1, map, .word_next);
    try testing.expectEqual(Position{ .page = 1, .line = 0, .column = 0 }, v.cursor.position());

    v.enterPage(1, map, .word_previous);
    try testing.expectEqual(Position{ .page = 1, .line = 1, .column = 2 }, v.cursor.position());

    // But `j` keeps the column it had.
    v.cursor.goal = 1e6;
    v.enterPage(1, map, .down);
    try testing.expectEqual(@as(u32, 0), v.cursor.line);
    try testing.expectEqual(@as(u32, 4), v.cursor.column);
}

test "a selection is in reading order whichever way it was extended" {
    var buf: [3]fenrir.Page = undefined;
    var v = viewOf(fakePages(&buf, 3), 1, 700, 900);

    v.cursor = .{ .page = 1, .line = 4, .column = 2, .visible = true };
    v.beginSelection();
    v.cursor.page = 0;
    v.cursor.line = 9;

    const sel = v.selection().?;
    try testing.expectEqual(@as(u32, 0), sel[0].page);
    try testing.expectEqual(@as(u32, 1), sel[1].page);

    // `o` swaps ends: the cursor goes to where the anchor was.
    const other = v.swapSelectionEnds().?;
    try testing.expectEqual(Position{ .page = 1, .line = 4, .column = 2 }, other);
    try testing.expectEqual(@as(u32, 0), v.anchor.?.page);

    v.endSelection();
    try testing.expect(v.selection() == null);
}
