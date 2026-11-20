//! The caret: where the keyboard is in the text, moved by the motions and
//! drawn over the page.
//!
//! In every build, light included: `j` and `k` move it a line at a time,
//! as Vim's cursor moves. What a caret and a drag select is the
//! selection's, in `selection.zig`, which only a build with marks has.

const std = @import("std");
const fenrir = @import("fenrir");

const Session = @import("Session.zig");

const hlidskjalf = fenrir.hlidskjalf;

const DrawList = fenrir.gleipnir.DrawList;

const View = hlidskjalf.View;

/// Moves the focused window's cursor, fetching the neighbouring page's
/// text map when the cursor runs off the end of this one.
///
/// A move that needs a map which is not built yet does nothing this
/// frame: `missingIn` will ask for it, and the next press works. That is
/// the same bargain as a page that is still blank paper.
///
/// `j` and `k` come here in every build, and move the caret a line at a
/// time, as Vim's do. In `light` they once scrolled a tenth of a screen
/// instead, for want of a caret; the author asked for the caret. Do not
/// give a build a scroll in place of this.
pub fn moveCursor(s: *Session, step: View.Step) void {
    const v = s.view();
    const b = s.buffer(v.buffer);
    if (v.cursor.page >= v.pages.len) v.cursor.page = v.currentPage();

    // A cursor being shown for the first time appears on the page in
    // front of you, not on whichever page it was left on.
    if (!v.cursor.visible) v.cursor.page = v.currentPage();

    const map = b.textMap(v.cursor.page) orelse {
        // Its page's text is not read yet -- which, in a build that reads
        // a page's text only for the caret, is every first press. Shown,
        // and put on the page when the text comes: see `placeStale`. A
        // caret shown for the first time has nowhere on this page to be
        // near, and goes to its first line.
        if (!v.cursor.visible) v.cursor.caret = .empty;
        v.cursor.visible = true;
        v.cursor.stale = true;
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

/// The text of `page` has come: a caret waiting on it is put on the glyph
/// nearest where it was. One a reload left stale keeps its place on the
/// page; one shown before the text was read goes to the first line, and
/// is scrolled to, as the press that showed it would have scrolled.
pub fn placeStale(s: *Session, index: u32, page: u32) void {
    const map = s.buffer(index).textMap(page) orelse return;
    var it = s.tabs.iterator();
    while (it.next()) |v| {
        if (v.buffer != index or !v.cursor.stale or v.cursor.page != page) continue;
        const shown = v.cursor.caret.isEmpty();
        v.cursorNear(map);
        if (shown) v.scrollToCursor();
    }
}

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

test "j and k move the caret a line at a time, in every build" {
    // The author asked for this. `light` had no caret, and `j` and `k`
    // scrolled it a tenth of a screen a press; they are a line, as in Vim,
    // and the page moves only to keep the caret in sight. Do not make this
    // test skip in a build without marks: light is the build it is for.
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    try putText(&s, 0, 4, 6);
    const v = s.view();
    const scroll = v.scroll;

    // The first press shows it, on the first line of the page in front.
    _ = s.apply(.{ .move_cursor = .down });
    try testing.expect(v.cursor.visible);
    try testing.expectEqual(@as(u32, 0), v.cursor.line);

    _ = s.apply(.{ .move_cursor = .down });
    try testing.expectEqual(@as(u32, 1), v.cursor.line);
    _ = s.apply(.{ .move_cursor = .down });
    try testing.expectEqual(@as(u32, 2), v.cursor.line);
    _ = s.apply(.{ .move_cursor = .up });
    try testing.expectEqual(@as(u32, 1), v.cursor.line);
    try testing.expectEqual(scroll, v.scroll);

    // Escape puts it away, and the next press brings it back.
    _ = s.apply(.hide_cursor);
    try testing.expect(!v.cursor.visible);
    _ = s.apply(.{ .move_cursor = .down });
    try testing.expect(v.cursor.visible);
}

test "a caret shown before its page's text is read goes on the page when the text comes" {
    // Every first press, in a build that reads a page's text only for the
    // caret: the press shows it with nowhere to stand, and the text that
    // comes puts it on the page's first line.
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);
    const v = s.view();

    _ = s.apply(.{ .move_cursor = .down });
    try testing.expect(v.cursor.visible);
    try testing.expect(v.cursor.caret.isEmpty());

    try putText(&s, 0, 4, 6);
    placeStale(&s, 0, 0);
    try testing.expect(!v.cursor.stale);
    try testing.expect(!v.cursor.caret.isEmpty());
    try testing.expectEqual(@as(u32, 0), v.cursor.line);

    // And on from there, a line a press.
    _ = s.apply(.{ .move_cursor = .down });
    try testing.expectEqual(@as(u32, 1), v.cursor.line);
}
