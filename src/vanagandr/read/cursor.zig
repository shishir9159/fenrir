//! The caret and the selection: where the keyboard is in the text, what
//! visual mode or a drag is holding, and both drawn over the page.
//!
//! Neither is a mark. A selection belongs to the interface and is gone with
//! the session; `marks.zig` is what turns one into something kept. A file of
//! its own so that all of it is in one place, and so that a build with no
//! use for a selection can leave the file out.

const std = @import("std");
const fenrir = @import("fenrir");

const Session = @import("../read.zig").Session;
const frame = @import("frame.zig");

const gelgja = fenrir.gelgja;
const hlidskjalf = fenrir.hlidskjalf;

const Bounds = gelgja.Bounds;
const Color = gelgja.Color;
const Point = gelgja.Point;
const DrawList = fenrir.gleipnir.DrawList;

const View = hlidskjalf.View;

/// A selection made with the mouse: which buffer, and its two ends.
///
/// It outlives the button. Letting go of a drag leaves the words selected,
/// the way letting go in a browser does, and the next press anywhere puts
/// the selection away. A selection is not a mark on the document: nothing
/// of it is written to the database and nothing of it survives the
/// session. `m` is what turns one into a highlight.
pub const Drag = struct {
    buffer: u32,
    from: View.Position,
    to: View.Position,
    /// The button is still down, so the far end follows the pointer.
    held: bool = true,
};

/// Moves the focused window's cursor, fetching the neighbouring page's
/// text map when the cursor runs off the end of this one.
///
/// A move that needs a map which is not built yet does nothing this
/// frame: `missingIn` will ask for it, and the next press works. That is
/// the same bargain as a page that is still blank paper.
pub fn moveCursor(s: *Session, step: View.Step) void {
    const v = s.view();
    const b = s.buffer(v.buffer);
    if (v.cursor.page >= v.pages.len) v.cursor.page = v.currentPage();

    // A cursor being shown for the first time appears on the page in
    // front of you, not on whichever page it was left on.
    if (!v.cursor.visible) v.cursor.page = v.currentPage();

    const map = b.textMap(v.cursor.page) orelse {
        v.cursor.visible = true;
        return;
    };
    if (v.cursor.stale) v.cursorNear(map);

    switch (v.moveCursor(step, map)) {
        .moved, .blocked => {},
        .page_above => {
            if (v.cursor.page == 0) return;
            const above = v.cursor.page - 1;
            const other = b.textMap(above) orelse return;
            v.enterPage(above, other, step);
        },
        .page_below => {
            if (v.cursor.page + 1 >= v.pages.len) return;
            const below = v.cursor.page + 1;
            const other = b.textMap(below) orelse return;
            v.enterPage(below, other, step);
        },
    }
    v.scrollToCursor();
}

/// Makes sure the focused window has a caret to work from: the one it
/// has, or one at the top of the page in front of the reader. Returns
/// false when that page's text is not ready yet.
pub fn ensureCursor(s: *Session) bool {
    const v = s.view();
    const b = s.buffer(v.buffer);
    if (!v.cursor.visible or v.cursor.page >= v.pages.len) {
        const page = v.currentPage();
        const map = b.textMap(page) orelse {
            v.cursor.page = page;
            v.cursor.visible = true;
            return false;
        };
        v.cursorToPage(page, map, false);
        return true;
    }
    const map = b.textMap(v.cursor.page) orelse return false;
    if (v.cursor.stale) v.cursorNear(map);
    return true;
}

/// The text position under a window point, or null if it is not over
/// text whose map is ready.
pub fn positionAt(s: *Session, v: *View, p: Point) ?View.Position {
    const page = v.pageAt(p) orelse return null;
    const at = v.userSpaceAt(page, p) orelse return null;
    const map = s.buffer(v.buffer).textMap(page) orelse return null;
    if (map.isEmpty()) return null;
    const line = map.lineAt(at.x, at.y);
    return .{ .page = page, .line = line, .column = map.columnAt(line, at.x) };
}

/// Moves the caret to where the pointer is, which is what a click in text
/// means everywhere else and is how the keyboard picks up a selection the
/// mouse began: `v` after a drag extends from the end of it, and `w` or
/// `j` after a click carries on from where the reader was looking.
///
/// Not scrolled to, unlike a cursor move from the keyboard -- the pointer
/// is already somewhere the reader can see, and a page that jumped under
/// a drag would be unusable.
pub fn carryCursor(s: *Session, v: *View, at: View.Position) void {
    const map = s.buffer(v.buffer).textMap(at.page) orelse return;
    if (map.isEmpty()) return;
    v.cursorTo(at, map);
}

/// One box on one page: what a selection and a highlight are made of.
pub const PageBox = struct { page: u32, box: Bounds };

/// The glyphs between two text positions, as one box per line per page.
///
/// Inclusive of both ends, as a Vim selection is: `v` on a letter selects
/// that letter. `lines` widens every line to its whole length, which is
/// `V`. Pages whose text is not ready are skipped rather than waited for;
/// `missingIn` asks for them, and the selection fills in a frame later.
pub fn selectionBoxes(
    s: *Session,
    buffer_index: u32,
    from: View.Position,
    to: View.Position,
    lines: bool,
    out: *std.ArrayList(PageBox),
) !void {
    out.clearRetainingCapacity();
    const b = s.buffer(buffer_index);
    const ends = View.Position.ordered(from, to);

    var page = ends[0].page;
    while (page <= ends[1].page and page < b.pages.len) : (page += 1) {
        const map = b.textMap(page) orelse continue;
        if (map.isEmpty()) continue;
        const last_line: u32 = @intCast(map.lines.len - 1);

        const first = if (page == ends[0].page) @min(ends[0].line, last_line) else 0;
        const last = if (page == ends[1].page) @min(ends[1].line, last_line) else last_line;

        var line = first;
        while (line <= last) : (line += 1) {
            const glyphs = map.lines[line].glyphs(map);
            const starts_here = !lines and page == ends[0].page and line == ends[0].line;
            const ends_here = !lines and page == ends[1].page and line == ends[1].line;
            const lo: usize = if (starts_here) @min(ends[0].column, glyphs.len) else 0;
            const hi: usize = if (ends_here) @min(ends[1].column + 1, glyphs.len) else glyphs.len;
            if (lo >= hi) continue;

            var box: Bounds = .empty;
            for (glyphs[lo..hi]) |g| box = box.unionWith(g.box);
            if (!box.isEmpty()) try out.append(s.gpa, .{ .page = page, .box = box });
        }
    }
}

/// What is selected right now, from the keyboard or from the mouse.
///
/// Visual mode wins when both are somehow live, because the reader asked
/// for that one last. The mouse's counts only in the window it was made
/// in: a selection in a split is that split's, as visual mode's is.
pub fn activeSelection(s: *Session, v: *View) ?[2]View.Position {
    if (v.selection()) |sel| return sel;
    const d = s.drag orelse return null;
    if (d.buffer != v.buffer or v != s.layout().current()) return null;
    return View.Position.ordered(d.from, d.to);
}

/// Nothing is selected any more, whichever of the two made it.
pub fn clearSelection(s: *Session) void {
    s.view().endSelection();
    s.drag = null;
}

pub fn lineSelection(s: *const Session) bool {
    return s.keymap.mode == .visual_line or (s.keymap.mode == .normal and s.last_visual_line);
}

/// What is selected, drawn the way the highlight `m` would make of it, so
/// that committing one changes nothing a reader can see. From the
/// keyboard in visual mode, or from the mouse.
///
/// Grey, and a shade darker than the highlight that follows it, because a
/// selection is not a mark on the document: it is the interface saying
/// which words it is holding. Drawn over the text at an alpha that
/// darkens the paper rather than lifting the type -- see `highlight`.
pub fn drawSelection(s: *Session, v: *View, over: *DrawList) !void {
    const sel = activeSelection(s, v) orelse return;
    // Whole lines only when visual line mode made it; a mouse drag is
    // always the glyphs it went over.
    const lines = v.selection() != null and lineSelection(s);

    s.boxes.clearRetainingCapacity();
    selectionBoxes(s, v.buffer, sel[0], sel[1], lines, &s.boxes) catch return;
    const radius = frame.markRadius(v.zoom);
    for (s.boxes.items) |pb| {
        if (pb.page >= v.pages.len) continue;
        const block = frame.blockOf(v.windowBox(pb.page, pb.box), v.zoom);
        try over.rounded(block, .all(radius), selection_block);
        // A hairline the same grey at full strength, so the ends of the
        // selection are legible against a figure or a dark background as
        // well as against paper.
        try over.border(block, .all(radius), 1, selection_edge);
    }
}

/// The selection block, and the line around it. Grey rather than the
/// system blue every other reader uses: the page underneath is the
/// document's colour, and the interface has no business tinting it.
const selection_block: Color = .{ .r = 0.32, .g = 0.33, .b = 0.35, .a = 0.30 };
const selection_edge: Color = .{ .r = 0.32, .g = 0.33, .b = 0.35, .a = 0.55 };

/// The caret: a thin bar at the leading edge of the glyph it is on.
pub fn drawCaret(s: *Session, v: *View, over: *DrawList) !void {
    if (!v.cursor.visible or v.cursor.caret.isEmpty()) return;
    if (v.cursor.page >= v.pages.len) return;

    const box = v.windowBox(v.cursor.page, v.cursor.caret);
    // A hairline at this zoom, never thinner than a pixel, so it is
    // visible on a page scaled down to a thumbnail.
    const w = @max(1.5, v.zoom);
    const focused = v == s.layout().current();
    try over.fill(
        .fromRect(box.min_x - w * 0.5, box.min_y, box.min_x + w * 0.5, box.max_y),
        if (focused) .{ .r = 0.1, .g = 0.45, .b = 0.95, .a = 1 } else .gray(0.55),
    );
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const putText = fixtures.putText;
const sessionOf = fixtures.sessionOf;

test "a selection runs in reading order, inclusive, and across pages" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try putText(&s, 0, 3, 4);
    try putText(&s, 1, 3, 4);

    var boxes: std.ArrayList(PageBox) = .empty;
    defer boxes.deinit(gpa);

    // From the middle of the first line to the middle of the last: three
    // boxes, the middle one whole and the ends partial.
    try selectionBoxes(&s, 0, .{ .page = 0, .line = 0, .column = 2 }, .{ .page = 0, .line = 2, .column = 1 }, false, &boxes);
    try testing.expectEqual(@as(usize, 3), boxes.items.len);
    try testing.expect(boxes.items[1].box.width() > boxes.items[0].box.width());
    try testing.expect(boxes.items[1].box.width() > boxes.items[2].box.width());

    // Backwards is the same selection.
    var backwards: std.ArrayList(PageBox) = .empty;
    defer backwards.deinit(gpa);
    try selectionBoxes(&s, 0, .{ .page = 0, .line = 2, .column = 1 }, .{ .page = 0, .line = 0, .column = 2 }, false, &backwards);
    try testing.expectEqual(boxes.items.len, backwards.items.len);
    try testing.expectApproxEqAbs(boxes.items[0].box.min_x, backwards.items[0].box.min_x, 0.01);

    // One glyph is a selection of one glyph: `v` then `m` highlights the
    // letter under the cursor, as it does in Vim.
    try selectionBoxes(&s, 0, .{ .page = 0, .line = 1, .column = 1 }, .{ .page = 0, .line = 1, .column = 1 }, false, &boxes);
    try testing.expectEqual(@as(usize, 1), boxes.items.len);

    // Line-wise, and over a page break: the last line of page 0 and the
    // first of page 1, both whole.
    try selectionBoxes(&s, 0, .{ .page = 0, .line = 2, .column = 3 }, .{ .page = 1, .line = 0, .column = 0 }, true, &boxes);
    try testing.expectEqual(@as(usize, 2), boxes.items.len);
    try testing.expectEqual(@as(u32, 0), boxes.items[0].page);
    try testing.expectEqual(@as(u32, 1), boxes.items[1].page);
    try testing.expectApproxEqAbs(boxes.items[0].box.width(), boxes.items[1].box.width(), 0.01);
}

test "a press in text moves the caret there and a drag carries it along" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try putText(&s, 0, 3, 4);

    const v = s.view();
    try testing.expect(!v.cursor.visible);

    // The window point of the second glyph of the second line.
    const map = s.buffer(0).textMap(0).?;
    const target = map.lines[1].glyphs(map)[1];
    const at = v.windowPoint(0, .{ .x = target.middle(), .y = target.base }) orelse
        return error.SkipZigTest;

    s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    try testing.expect(v.cursor.visible);
    try testing.expectEqual(@as(u32, 1), v.cursor.line);
    try testing.expectEqual(@as(u32, 1), v.cursor.column);
    try testing.expect(s.drag != null);

    // The drag carries the caret with it rather than leaving it where the
    // press was: releasing and pressing `v` has to extend from the end.
    const later = map.lines[2].glyphs(map)[3];
    const to = v.windowPoint(0, .{ .x = later.middle(), .y = later.base }) orelse
        return error.SkipZigTest;
    s.pointer(.{ .mouse = to, .buttons = .{ .left = true } });
    try testing.expectEqual(@as(u32, 2), v.cursor.line);
    try testing.expectEqual(@as(u32, 3), v.cursor.column);
}

test "letting go of a drag leaves a selection, not a highlight" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try putText(&s, 0, 3, 4);

    const v = s.view();
    const map = s.buffer(0).textMap(0).?;
    const first = map.lines[1].glyphs(map)[0];
    const last = map.lines[2].glyphs(map)[2];
    const at = v.windowPoint(0, .{ .x = first.middle(), .y = first.base }) orelse
        return error.SkipZigTest;
    const to = v.windowPoint(0, .{ .x = last.middle(), .y = last.base }) orelse
        return error.SkipZigTest;

    s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = to, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = to, .buttons = .{} });

    // The words stay selected and nothing was written to the document: a
    // selection belongs to the interface, a highlight to the reader.
    try testing.expect(s.drag != null);
    try testing.expect(!s.drag.?.held);
    try testing.expect(activeSelection(&s, v) != null);
    try testing.expectEqual(@as(usize, 0), s.buffer(0).marks.count());

    // A press puts the selection away, the way a click in a browser does,
    // and a press that goes nowhere is a click and selects nothing.
    s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    try testing.expect(std.meta.eql(s.drag.?.from, s.drag.?.to));
    s.pointer(.{ .mouse = at, .buttons = .{} });
    try testing.expect(s.drag == null);

    // `y` puts it away and writes nothing either. It used to highlight, and
    // the author had that taken out along with the highlight on letting go.
    s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = to, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = to, .buttons = .{} });
    _ = s.apply(.yank_selection);
    try testing.expect(s.drag == null);
    try testing.expectEqual(@as(usize, 0), s.buffer(0).marks.count());

    // `m` is what makes a highlight of it, and puts the selection away.
    s.pointer(.{ .mouse = at, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = to, .buttons = .{ .left = true } });
    s.pointer(.{ .mouse = to, .buttons = .{} });
    _ = s.apply(.toggle_highlight);
    try testing.expect(s.drag == null);
    try testing.expect(s.buffer(0).marks.count() > 0);
}
