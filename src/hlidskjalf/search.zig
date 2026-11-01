//! Finding a string in a document, a page at a time.
//!
//! The search itself is three lines: a page is a string and a query is a
//! string. Everything here is about the other two problems, which are that
//! the strings do not exist yet and that there are six hundred of them.
//!
//! ## The scan is a frontier, not a loop
//!
//! A page's text costs one interpretation of its content stream -- the same
//! work that draws it -- so searching a six-hundred-page book is six hundred
//! page renders' worth of work and cannot happen between two frames. The
//! state here is therefore a *frontier*: which page to look at next, and
//! everything found so far. The reader's worker thread takes one page off it
//! per turn, hands back a text map, and the hits appear as they are found.
//! Nothing here starts a thread or waits for one.
//!
//! ## The order is a rotation, which is what makes `n` work
//!
//! The scan starts at the page the cursor is on and wraps at the end, so the
//! hits arrive in the order a reader meets them: the next one is the next in
//! the list, all the way round and back to where they started. That is `n`,
//! and `N` is the same list backwards, with no sorting and no search for
//! "the first hit after the cursor" anywhere.
//!
//! ## What the matching does and does not do
//!
//! Byte-wise, over the page's text, with two folds applied to both sides:
//! ASCII case, and a newline reading as a space so that a phrase split over
//! a line break still matches. Both are per-byte, so a match's offset in the
//! folded text is its offset in the real text and a hit needs no adjustment.
//!
//! Case is Vim's smartcase: a query in lower case ignores case, a query with
//! a capital in it does not. Outside ASCII nothing is folded -- `Ä` does not
//! match `ä` -- because case folding the rest of Unicode is a table as large
//! as everything else in this program put together. A hyphen at a line break
//! is not undone either: `gradi-\nent` does not match `gradient`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gelgja = @import("../gelgja.zig");
const text = @import("text.zig");

const Bounds = gelgja.Bounds;

/// The longest query worth carrying. A search box is not a paste buffer, and
/// the bound keeps the folded copy on the stack.
pub const max_query = 128;

/// One match, on one line. A match that runs over a line break is two hits
/// sharing a page, because a highlight is a rectangle and a match across two
/// lines is two of them.
pub const Hit = struct {
    page: u32,
    line: u32,
    /// The glyphs covered, as a span of that page's `boxes`.
    first: u32 = 0,
    count: u32 = 0,
    /// Their union, in PDF user space -- the space a highlight is drawn in.
    box: Bounds = .empty,
    /// True for the first hit of a match, so `n` steps over matches rather
    /// than over the halves of one.
    starts: bool = true,
};

/// A query, the frontier, and everything found so far.
pub const State = struct {
    /// The query as it was typed, which is what the search box shows.
    query: std.ArrayList(u8) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    /// Which hit the reader is standing on. Meaningless while `hits` is
    /// empty.
    current: u32 = 0,
    /// True once the reader has stepped onto a hit, so that the first `n`
    /// after a search goes to the first hit rather than the second.
    landed: bool = false,

    /// How many pages the document has, and how many of them have been
    /// looked at.
    pages: u32 = 0,
    scanned: u32 = 0,
    /// Where the scan began. The next page to look at is this plus
    /// `scanned`, modulo `pages`, which is the whole of the frontier.
    from: u32 = 0,
    /// Case is folded unless the query has a capital in it (smartcase).
    fold_case: bool = true,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.query.deinit(gpa);
        s.hits.deinit(gpa);
        s.* = .{};
    }

    pub fn isEmpty(s: State) bool {
        return s.query.items.len == 0;
    }

    /// Begins a search, throwing away whatever the last one found.
    ///
    /// `from` is the page the cursor is on, because that is where a reader
    /// expects `/` to start looking.
    pub fn start(
        s: *State,
        gpa: Allocator,
        query: []const u8,
        from: u32,
        pages: u32,
    ) Allocator.Error!void {
        s.query.clearRetainingCapacity();
        try s.query.appendSlice(gpa, query[0..@min(query.len, max_query)]);
        s.hits.clearRetainingCapacity();
        s.current = 0;
        s.landed = false;
        s.pages = pages;
        s.scanned = 0;
        s.from = if (pages == 0) 0 else from % pages;
        s.fold_case = !hasUpper(s.query.items);
    }

    /// The next page the worker should build a text map for, or null when
    /// every page has been looked at.
    pub fn frontier(s: State) ?u32 {
        if (s.pages == 0 or s.scanned >= s.pages or s.isEmpty()) return null;
        return (s.from + s.scanned) % s.pages;
    }

    /// Records what one page holds. Pages may arrive out of order -- the
    /// worker finishes whatever it was already doing first -- so this takes
    /// the page number rather than assuming the frontier, and advances the
    /// frontier only when the page that arrived is the one it was waiting
    /// for.
    pub fn take(
        s: *State,
        gpa: Allocator,
        page: u32,
        map: text.Page,
    ) Allocator.Error!void {
        if (s.frontier() != page) return;
        s.scanned += 1;
        try find(gpa, &s.hits, map, page, s.query.items, s.fold_case);
    }

    pub fn done(s: State) bool {
        return s.pages == 0 or s.scanned >= s.pages;
    }

    /// The hit the reader is standing on.
    pub fn at(s: State) ?Hit {
        if (s.hits.items.len == 0 or !s.landed) return null;
        return s.hits.items[@min(s.current, s.hits.items.len - 1)];
    }

    /// Moves to the next match, or the previous one when `back`. Null when
    /// nothing has been found yet.
    ///
    /// Steps over *matches*, not over hits: a match broken across a line
    /// break is two hits and one `n`.
    pub fn step(s: *State, back: bool) ?Hit {
        const n = s.hits.items.len;
        if (n == 0) return null;

        // The first `n` after a search lands on the first hit rather than
        // stepping off it, which is what a reader who has not moved yet
        // means by "next".
        if (!s.landed) {
            s.landed = true;
            // Backwards, the last hit may be the tail of a match that wrapped
            // a line, and `split` marks only a match's first hit. Landing on
            // the tail sent the next `N` to its own head instead of to the
            // match before it, so this walks back to the start the way the
            // steady-state loop below does. Forwards needs no walk: `hits[0]`
            // is a first hit by construction.
            var i: usize = if (back) n - 1 else 0;
            while (back and i > 0 and !s.hits.items[i].starts) i -= 1;
            s.current = @intCast(i);
            return s.hits.items[s.current];
        }

        var i = s.current;
        var guard: usize = 0;
        while (guard < n) : (guard += 1) {
            i = if (back)
                (if (i == 0) @as(u32, @intCast(n - 1)) else i - 1)
            else
                @intCast((@as(usize, i) + 1) % n);
            if (s.hits.items[i].starts) break;
        }
        s.current = i;
        return s.hits.items[i];
    }

    /// The hits on one page, for the frame that draws them. Hits are
    /// appended in scan order, which is not page order after a wrap, so this
    /// is a scan -- over a list that is a handful of entries on any page
    /// anyone is looking at.
    pub fn onPage(s: State, page: u32, out: []Hit) []const Hit {
        var n: usize = 0;
        for (s.hits.items) |h| {
            if (h.page != page) continue;
            if (n == out.len) break;
            out[n] = h;
            n += 1;
        }
        return out[0..n];
    }
};

/// Every match of `query` in one page, appended to `out`.
///
/// Split at line breaks, so a phrase running over one produces a hit on each
/// line with the glyphs it covers there. The first carries `starts`.
pub fn find(
    gpa: Allocator,
    out: *std.ArrayList(Hit),
    map: text.Page,
    page: u32,
    query: []const u8,
    fold_case: bool,
) Allocator.Error!void {
    if (query.len == 0 or query.len > map.text.len) return;

    var needle: [max_query]u8 = undefined;
    const q = query[0..@min(query.len, max_query)];
    for (q, 0..) |c, i| needle[i] = fold(c, fold_case);

    var at: usize = 0;
    while (at + q.len <= map.text.len) {
        if (!matches(map.text[at..], needle[0..q.len], fold_case)) {
            at += 1;
            continue;
        }
        try split(gpa, out, map, page, @intCast(at), @intCast(at + q.len));
        // Overlapping matches are not reported: `aa` in `aaa` is one hit,
        // the way it is in every editor.
        at += q.len;
    }
}

fn matches(haystack: []const u8, needle: []const u8, fold_case: bool) bool {
    for (needle, haystack[0..needle.len]) |n, h| {
        if (n != fold(h, fold_case)) return false;
    }
    return true;
}

/// Turns one match into a hit per line it touches.
fn split(
    gpa: Allocator,
    out: *std.ArrayList(Hit),
    map: text.Page,
    page: u32,
    from: u32,
    to: u32,
) Allocator.Error!void {
    const first = map.glyphAt(from) orelse return;
    const last = map.glyphAt(to - 1) orelse return;

    var box = first;
    var starts = true;
    while (box <= last) {
        const line = map.lineOf(box);
        const l = map.lines[line];
        const end = @min(last, l.first + l.count - 1);

        var bounds: Bounds = .empty;
        for (map.boxes[box .. end + 1]) |b| bounds = bounds.unionWith(b.box);

        try out.append(gpa, .{
            .page = page,
            .line = line,
            .first = box,
            .count = end - box + 1,
            .box = bounds,
            .starts = starts,
        });

        starts = false;
        box = end + 1;
    }
}

/// The two folds, applied to both sides. A newline reads as a space so that
/// a phrase split over a line break still matches; case is folded only when
/// the query asked for it.
fn fold(c: u8, fold_case: bool) u8 {
    if (c == '\n') return ' ';
    return if (fold_case) std.ascii.toLower(c) else c;
}

fn hasUpper(query: []const u8) bool {
    for (query) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;
const DisplayList = gelgja.DisplayList;

/// One line per string, one run per word, laid out the way a page is: a
/// visible gap between words and twenty points between lines.
fn pageOf(gpa: Allocator, lines: []const []const u8) !text.Page {
    var glyphs: std.ArrayList(DisplayList.Glyph) = .empty;
    defer glyphs.deinit(gpa);
    var cmds: std.ArrayList(DisplayList.DrawCmd) = .empty;
    defer cmds.deinit(gpa);

    for (lines, 0..) |line, row| {
        var x: f32 = 100;
        var word = std.mem.tokenizeScalar(u8, line, ' ');
        while (word.next()) |w| {
            const start: u32 = @intCast(glyphs.items.len);
            for (w, 0..) |c, i| try glyphs.append(gpa, .{
                .code = c,
                .offset = .{ .x = 5 * @as(f32, @floatFromInt(i)), .y = 0 },
            });
            const advance = 5 * @as(f32, @floatFromInt(w.len));
            try cmds.append(gpa, .{ .text = .{
                .size = 10,
                .transform = .translation(x, 700 - 20 * @as(f32, @floatFromInt(row))),
                .glyphs = .{ .start = start, .count = @intCast(w.len) },
                .advance = advance,
            } });
            x += advance + 4;
        }
    }
    return text.build(gpa, .{ .glyphs = glyphs.items, .cmds = cmds.items });
}

test "the page laid out for these tests reads back as it was written" {
    const gpa = testing.allocator;
    var map = try pageOf(gpa, &.{ "the quick brown", "fox jumps" });
    defer map.deinit(gpa);
    try testing.expectEqualStrings("the quick brown\nfox jumps", map.text);
}

test "a match is the glyphs it covers, in user space" {
    const gpa = testing.allocator;
    var map = try pageOf(gpa, &.{"the quick brown fox"});
    defer map.deinit(gpa);

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(gpa);
    try find(gpa, &hits, map, 3, "quick", true);

    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(@as(u32, 3), hits.items[0].page);
    try testing.expectEqual(@as(u32, 5), hits.items[0].count);
    try testing.expect(!hits.items[0].box.isEmpty());

    // The glyphs really are the word, not five boxes starting anywhere.
    const h = hits.items[0];
    var buf: [16]u8 = undefined;
    var n: usize = 0;
    for (map.boxes[h.first..][0..h.count]) |b| {
        const said = map.stringOf(b);
        @memcpy(buf[n..][0..said.len], said);
        n += said.len;
    }
    try testing.expectEqualStrings("quick", buf[0..n]);
}

test "smartcase: a lower-case query ignores case and a capital does not" {
    const gpa = testing.allocator;
    var map = try pageOf(gpa, &.{"The Quick brown"});
    defer map.deinit(gpa);

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(gpa);

    try find(gpa, &hits, map, 0, "the", true);
    try testing.expectEqual(@as(usize, 1), hits.items.len);

    hits.clearRetainingCapacity();
    try find(gpa, &hits, map, 0, "the", false);
    try testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "a phrase over a line break matches, as two hits and one match" {
    const gpa = testing.allocator;
    var map = try pageOf(gpa, &.{ "one point", "convex here" });
    defer map.deinit(gpa);

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(gpa);
    try find(gpa, &hits, map, 0, "point convex", true);

    // A highlight is a rectangle, so a match on two lines is two of them --
    // but only the first says it begins a match, so `n` steps over the pair.
    try testing.expectEqual(@as(usize, 2), hits.items.len);
    try testing.expect(hits.items[0].starts);
    try testing.expect(!hits.items[1].starts);
    try testing.expectEqual(@as(u32, 0), hits.items[0].line);
    try testing.expectEqual(@as(u32, 1), hits.items[1].line);

    // And the first `N` on that pair lands on the match and not on its tail.
    // It used to take `hits[n - 1]` with no `starts` test, which put the
    // reader on the second line of the match and the next `N` on its first.
    var st: State = .{ .hits = hits, .pages = 1, .scanned = 1 };
    const first = st.step(true).?;
    try testing.expect(first.starts);
    try testing.expectEqual(@as(u32, 0), first.line);
}

test "the scan starts where the cursor is and wraps, so n walks forward" {
    const gpa = testing.allocator;
    var st: State = .{};
    defer st.deinit(gpa);

    try st.start(gpa, "fox", 2, 4);
    try testing.expectEqual(@as(?u32, 2), st.frontier());

    // A page arriving that the frontier was not waiting for is ignored: the
    // worker finishes whatever it had started before it takes a search job.
    var other = try pageOf(gpa, &.{"fox"});
    defer other.deinit(gpa);
    try st.take(gpa, 0, other);
    try testing.expectEqual(@as(?u32, 2), st.frontier());

    // Pages 2 and 3, then round to 0 and 1.
    const has = [_]bool{ true, false, false, true };
    for (0..4) |_| {
        const page = st.frontier().?;
        var map = try pageOf(gpa, if (has[page]) &.{"a fox here"} else &.{"nothing"});
        defer map.deinit(gpa);
        try st.take(gpa, page, map);
    }
    try testing.expect(st.done());
    try testing.expect(st.frontier() == null);

    // Two hits, and the one on page 3 comes first because that is the one a
    // reader on page 2 meets next.
    try testing.expectEqual(@as(usize, 2), st.hits.items.len);
    try testing.expectEqual(@as(u32, 3), st.step(false).?.page);
    try testing.expectEqual(@as(u32, 0), st.step(false).?.page);
    // And round again, which is what wrapping means.
    try testing.expectEqual(@as(u32, 3), st.step(false).?.page);
    try testing.expectEqual(@as(u32, 0), st.step(true).?.page);
}

test "n after a search lands on the first hit rather than stepping past it" {
    const gpa = testing.allocator;
    var st: State = .{};
    defer st.deinit(gpa);

    try st.start(gpa, "fox", 0, 1);
    var map = try pageOf(gpa, &.{ "fox one", "fox two" });
    defer map.deinit(gpa);
    try st.take(gpa, 0, map);

    try testing.expectEqual(@as(usize, 2), st.hits.items.len);
    try testing.expect(st.at() == null);
    try testing.expectEqual(@as(u32, 0), st.step(false).?.line);
    try testing.expectEqual(@as(u32, 1), st.step(false).?.line);
    try testing.expectEqual(@as(u32, 0), st.step(false).?.line);
    try testing.expectEqual(@as(u32, 0), st.at().?.line);
}

test "a search with nothing found stays quiet rather than answering wrongly" {
    const gpa = testing.allocator;
    var st: State = .{};
    defer st.deinit(gpa);

    try st.start(gpa, "aardvark", 0, 1);
    var map = try pageOf(gpa, &.{"the quick brown fox"});
    defer map.deinit(gpa);
    try st.take(gpa, 0, map);

    try testing.expect(st.done());
    try testing.expectEqual(@as(usize, 0), st.hits.items.len);
    try testing.expect(st.step(false) == null);
    try testing.expect(st.at() == null);
}

test "overlapping matches are counted once" {
    const gpa = testing.allocator;
    var map = try pageOf(gpa, &.{"aaaa"});
    defer map.deinit(gpa);

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(gpa);
    try find(gpa, &hits, map, 0, "aa", true);
    try testing.expectEqual(@as(usize, 2), hits.items.len);
}

test "a document with no pages has no frontier and cannot loop" {
    const gpa = testing.allocator;
    var st: State = .{};
    defer st.deinit(gpa);
    try st.start(gpa, "fox", 0, 0);
    try testing.expect(st.frontier() == null);
    try testing.expect(st.done());
}
