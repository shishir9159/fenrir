//! `/`: the bar's query run over the document a page at a time, the matches
//! stepped through with `n` and `N`, and drawn over the page.
//!
//! The scan is `hlidskjalf.search` and the bar is `find.zig`; this is the
//! reader's side of the two. A file of its own so that all of it is in one
//! place, and so that a build with no search can leave the file out.

const std = @import("std");
const fenrir = @import("fenrir");

const find_mod = @import("../find.zig");
const Job = render.Job;
const Session = @import("../read.zig").Session;
const render = @import("render.zig");

const gelgja = fenrir.gelgja;
const hlidskjalf = fenrir.hlidskjalf;

const Color = gelgja.Color;
const DrawList = fenrir.gleipnir.DrawList;
const View = hlidskjalf.View;
const text = hlidskjalf.text;

/// `/`: the bar appears, empty, with the keyboard.
pub fn beginSearch(s: *Session) void {
    s.find.show();
    s.search.start(s.gpa, "", s.view().currentPage(), pageCount(s)) catch {};
}

/// Escape, or the close button: the bar goes and the highlights go with
/// it, which is the whole of what a reader means by ending a search.
pub fn endSearch(s: *Session) void {
    s.find.hide();
    s.search.start(s.gpa, "", 0, 0) catch {};
}

/// The query changed. The scan restarts from the page in front of the
/// reader, because a query one letter longer is a different search and
/// the hits for the old one are answers to a question nobody asked.
pub fn requery(s: *Session) void {
    s.search.start(s.gpa, s.find.query(), s.view().currentPage(), pageCount(s)) catch {};
}

/// `n`, `N`, and the two chevrons.
pub fn stepSearch(s: *Session, back: bool) void {
    const hit = s.search.step(back) orelse return;
    const v = s.view();
    // Not `scrollToPage`: the match may be the last line of a page that
    // is already half on screen, and scrolling to the top of it would
    // move the window away from the thing it was asked to show.
    // `scrollToBox` is the rule the caret and a chosen highlight use,
    // which is to move as little as will do.
    v.scrollToBox(hit.page, hit.box);
}

fn pageCount(s: *Session) u32 {
    return @intCast(s.buffer(s.view().buffer).pages.len);
}

/// What the bar was asked to do, carried out.
pub fn applyFind(s: *Session, what: find_mod.Action) void {
    switch (what) {
        .typed => requery(s),
        .step => |back| stepSearch(s, back),
        // Enter is `n` without moving the hands, and on the first press
        // that means landing on the first hit rather than stepping past
        // it -- which `search.step` already knows.
        .submitted => stepSearch(s, false),
        .close => endSearch(s),
    }
}

/// What the bar writes beside the field.
pub fn searchCount(s: *Session) find_mod.Count {
    var found: u32 = 0;
    var at: ?u32 = null;
    for (s.search.hits.items, 0..) |h, i| {
        if (!h.starts) continue;
        found += 1;
        if (s.search.landed and i == s.search.current) at = found;
    }
    return .{
        .at = at,
        .found = found,
        .scanned = s.search.scanned,
        .pages = s.search.pages,
    };
}

/// The next page the search wants interpreted, if it wants one.
pub fn searchJob(s: *Session) ?Job {
    const page = s.search.frontier() orelse return null;
    const v = s.layout().current();
    if (page >= v.pages.len) return null;
    return .{ .buffer = v.buffer, .page = page, .zoom = v.zoom, .want = .text };
}

/// The search's matches on the pages a window can see.
///
/// Over the page rather than under it, like a highlight and for the same
/// reason: a PDF's paper is opaque.
///
/// Not in the accent, which is the trap. The accent is white by default,
/// and white at a wash's alpha over white paper leaves the paper exactly
/// as white as it was -- every match would be invisible on the only kind
/// of page most documents have. So these are fixed colours, the way the
/// selection's grey and the caret's blue are fixed and for the argument
/// written beside them: the page underneath is the document's colour and
/// the interface has no business tinting it. Matches get the selection's
/// grey, because a match is the same kind of thing -- the interface
/// pointing at the page, not a mark on it -- and the one being stood on
/// gets the caret's blue, which is already this reader's word for where
/// you are.
///
/// Drawn in every window and not only the focused one: two windows on
/// one document are looking at one search.
pub fn drawSearchHits(s: *Session, v: *View, range: View.Visible, over: *DrawList) !void {
    const hits = s.search.hits.items;
    if (hits.len == 0) return;

    // Which hits are the match being stood on: the current one, plus its
    // continuation onto the next line if it has one. Both halves of a
    // match across a line break are one thing and are drawn as one.
    var last = s.search.current;
    if (s.search.at() != null) {
        while (last + 1 < hits.len and !hits[last + 1].starts) last += 1;
    }
    const standing = s.search.at() != null;

    const radius = Session.markRadius(v.zoom);
    for (hits, 0..) |hit, i| {
        if (hit.page < range.first or hit.page >= range.end) continue;
        const on = standing and i >= s.search.current and i <= last;
        const block = Session.blockOf(v.windowBox(hit.page, hit.box), v.zoom);
        try over.rounded(block, .all(radius), if (on) current_block else match_block);
        try over.border(block, .all(radius), 1, if (on) current_edge else match_edge);
    }
}

/// A match, and the one the reader is standing on. See `drawSearchHits`
/// for why neither is the accent.
const match_block: Color = .{ .r = 0.32, .g = 0.33, .b = 0.35, .a = 0.22 };
const match_edge: Color = .{ .r = 0.32, .g = 0.33, .b = 0.35, .a = 0.5 };
const current_block: Color = .{ .r = 0.1, .g = 0.45, .b = 0.95, .a = 0.28 };
const current_edge: Color = .{ .r = 0.1, .g = 0.45, .b = 0.95, .a = 0.95 };

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const sessionOf = fixtures.sessionOf;

/// One page of `words`, one run a word, at the top of the page. The same
/// shape `search.zig`'s own fixture uses, because a word gap only reaches
/// the text map as a gap between runs.
fn putWords(s: *Session, page: u32, words: []const []const u8) !void {
    const gpa = s.gpa;
    var glyphs: std.ArrayList(gelgja.DisplayList.Glyph) = .empty;
    defer glyphs.deinit(gpa);
    var cmds: std.ArrayList(gelgja.DisplayList.DrawCmd) = .empty;
    defer cmds.deinit(gpa);

    var x: f32 = 100;
    for (words) |word| {
        const start: u32 = @intCast(glyphs.items.len);
        for (word, 0..) |c, i| try glyphs.append(gpa, .{
            .code = c,
            .offset = .{ .x = 5 * @as(f32, @floatFromInt(i)), .y = 0 },
        });
        const advance = 5 * @as(f32, @floatFromInt(word.len));
        try cmds.append(gpa, .{ .text = .{
            .size = 10,
            .transform = .translation(x, 700),
            .glyphs = .{ .start = start, .count = @intCast(word.len) },
            .advance = advance,
        } });
        x += advance + 4;
    }
    s.buffer(0).putMap(gpa, page, try text.build(gpa, .{
        .glyphs = glyphs.items,
        .cmds = cmds.items,
    }));
}

/// Runs the scan to completion the way the frame loop would: the frontier
/// asks for a page, the worker builds its map, the search takes it.
fn scanAll(s: *Session, on: []const []const []const u8) !void {
    while (searchJob(s)) |job| {
        try putWords(s, job.page, on[job.page]);
        const map = s.buffer(job.buffer).textMap(job.page).?;
        try s.search.take(s.gpa, job.page, map);
    }
}

test "slash opens a search that is empty until something is typed" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 3), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(.enter_search);
    try testing.expect(s.find.open);
    try testing.expect(s.find.typing);
    // An empty query asks for no pages at all: a scan of the whole document
    // for nothing is the worst thing `/` could do on its own.
    try testing.expect(searchJob(&s) == null);
}

test "the scan walks every page from the one in front of the reader" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 4), 1, 1000, 800);
    defer closeSession(&s);

    s.view().scrollToPage(2);
    _ = s.apply(.enter_search);
    s.find.field.bytes = &s.find.query_buf;
    _ = s.find.field.insert("fox");
    applyFind(&s, .typed);

    // Page 2 first, because that is the one being read.
    try testing.expectEqual(@as(u32, 2), searchJob(&s).?.page);
    try scanAll(&s, &.{
        &.{ "the", "fox" },
        &.{"nothing"},
        &.{"nothing"},
        &.{ "a", "fox", "here" },
    });

    try testing.expect(s.search.done());
    try testing.expectEqual(@as(u32, 2), searchCount(&s).found);
    // Page 3 comes before page 0, because a reader on page 2 meets it first.
    try testing.expectEqual(@as(u32, 3), s.search.hits.items[0].page);
    try testing.expectEqual(@as(u32, 0), s.search.hits.items[1].page);
}

test "n steps the matches while a search is live and turns the page when it is not" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 4), 1, 1000, 800);
    defer closeSession(&s);

    // No search: `n` is the next page, as it has always been.
    try testing.expectEqual(@as(u32, 0), s.view().currentPage());
    _ = s.apply(.{ .search_step = false });
    try testing.expectEqual(@as(u32, 1), s.view().currentPage());

    s.view().scrollToPage(0);
    _ = s.apply(.enter_search);
    s.find.field.bytes = &s.find.query_buf;
    _ = s.find.field.insert("fox");
    applyFind(&s, .typed);
    try scanAll(&s, &.{
        &.{"nothing"},
        &.{ "a", "fox" },
        &.{"nothing"},
        &.{ "another", "fox" },
    });

    // Now it steps the matches, and the first `n` lands on the first rather
    // than stepping past it.
    //
    // The check is that the match is *on screen*, not that the window has
    // moved to the top of its page: `scrollToBox` moves as little as will
    // do, so a match near the top of the next page is brought into view
    // with the page before it still mostly showing -- which is the right
    // thing and makes `currentPage` the wrong question.
    _ = s.apply(.{ .search_step = false });
    try testing.expectEqual(@as(u32, 1), s.search.at().?.page);
    try testing.expectEqual(@as(u32, 1), searchCount(&s).at.?);
    try testing.expect(onScreen(s.view(), 1));

    _ = s.apply(.{ .search_step = false });
    try testing.expectEqual(@as(u32, 3), s.search.at().?.page);
    try testing.expectEqual(@as(u32, 2), searchCount(&s).at.?);
    try testing.expect(onScreen(s.view(), 3));

    // And back round, which is what wrapping means.
    _ = s.apply(.{ .search_step = false });
    try testing.expectEqual(@as(u32, 1), s.search.at().?.page);
    try testing.expect(onScreen(s.view(), 1));
}

fn onScreen(v: *View, page: u32) bool {
    const range = v.visiblePages();
    return page >= range.first and page < range.end;
}

test "escape ends the search, takes the highlights with it, and gives n back" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 4), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(.enter_search);
    s.find.field.bytes = &s.find.query_buf;
    _ = s.find.field.insert("fox");
    applyFind(&s, .typed);
    try scanAll(&s, &.{
        &.{ "a", "fox" },
        &.{"nothing"},
        &.{"nothing"},
        &.{"nothing"},
    });
    try testing.expectEqual(@as(u32, 1), searchCount(&s).found);

    // The field no longer has the keyboard -- enter gave it back -- so this
    // is the escape the keymap sends, not the field's own.
    s.find.typing = false;
    _ = s.apply(.hide_cursor);
    try testing.expect(!s.find.open);
    try testing.expectEqual(@as(usize, 0), s.search.hits.items.len);

    // And `n` is the next page again.
    const was = s.view().currentPage();
    _ = s.apply(.{ .search_step = false });
    try testing.expectEqual(was + 1, s.view().currentPage());
}

test "a query that matches nothing says so rather than saying nothing" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 1000, 800);
    defer closeSession(&s);

    _ = s.apply(.enter_search);
    s.find.field.bytes = &s.find.query_buf;
    _ = s.find.field.insert("aardvark");
    applyFind(&s, .typed);
    try scanAll(&s, &.{ &.{"nothing"}, &.{"nothing"} });

    const count = searchCount(&s);
    try testing.expectEqual(@as(u32, 0), count.found);
    try testing.expect(!count.scanning());
    try testing.expect(count.at == null);
    // Stepping a search with nothing in it moves nothing.
    const was = s.view().scroll;
    _ = s.apply(.{ .search_step = false });
    try testing.expectEqual(was, s.view().scroll);
}
