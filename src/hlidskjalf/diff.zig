//! What changed between two texts, word by word.
//!
//! Pixels can say that a paragraph moved. They cannot say that one word in
//! it was replaced, because the replacement pushes the rest of the line
//! along and every glyph after it lands on a pixel of its own. So a changed
//! page is also compared as words: each page's text split on white space,
//! each word hashed, and the two lists of hashes put through Myers' diff.
//! What comes out is the edit script a person would write -- these words
//! went, these came -- and each word is still a span of `text.Page.text`,
//! so it goes back to boxes on the page the way a search hit does.
//!
//! The same script over whole pages, a hash of each page's text, is how two
//! documents are paired when an inserted page would otherwise put every page
//! after it against the wrong partner. See `vanagandr/diff.zig`.
//!
//! ## Cost
//!
//! Myers is O((N + M) D) in time, for D edits, and keeping the path to walk
//! back along is O(D²) in memory. Two things keep both small. A common head
//! and tail are cut off first, which on a revised page is almost all of it.
//! And past `max_edits` the script gives up and says everything in the
//! middle changed: a page rewritten from top to bottom has no better answer,
//! and finding the minimal one would cost megabytes to say so.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gelgja = @import("../gelgja.zig");
const text = @import("text.zig");

const Bounds = gelgja.Bounds;

/// One stretch of an edit script: `len` items the same in both, gone from
/// the first, or new in the second. `a` and `b` are where it starts in each;
/// the side it does not touch keeps the position it is at.
pub const Run = struct {
    kind: Kind,
    a: u32,
    b: u32,
    len: u32,

    pub const Kind = enum { same, removed, added };
};

/// Edits past which the middle is called changed wholesale.
pub const max_edits = 2000;

/// The shortest edit script from `a` to `b`, as runs in order.
pub fn script(gpa: Allocator, a: []const u64, b: []const u64) ![]Run {
    var runs: std.ArrayList(Run) = .empty;
    errdefer runs.deinit(gpa);

    var head: u32 = 0;
    while (head < a.len and head < b.len and a[head] == b[head]) head += 1;
    var tail: u32 = 0;
    while (tail < a.len - head and tail < b.len - head and
        a[a.len - 1 - tail] == b[b.len - 1 - tail]) tail += 1;

    try push(gpa, &runs, .same, 0, 0, head);
    const mid_a = a[head .. a.len - tail];
    const mid_b = b[head .. b.len - tail];
    if (!try middle(gpa, &runs, mid_a, mid_b, head)) {
        try push(gpa, &runs, .removed, head, head, @intCast(mid_a.len));
        try push(gpa, &runs, .added, head + @as(u32, @intCast(mid_a.len)), head, @intCast(mid_b.len));
    }
    try push(gpa, &runs, .same, @intCast(a.len - tail), @intCast(b.len - tail), tail);
    return runs.toOwnedSlice(gpa);
}

/// Appends a run, merged into the last one when it continues it.
fn push(gpa: Allocator, runs: *std.ArrayList(Run), kind: Run.Kind, a: u32, b: u32, len: u32) !void {
    if (len == 0) return;
    if (runs.items.len != 0) {
        const last = &runs.items[runs.items.len - 1];
        if (last.kind == kind) {
            last.len += len;
            return;
        }
    }
    try runs.append(gpa, .{ .kind = kind, .a = a, .b = b, .len = len });
}

/// Myers' greedy forward search, then the walk back along the path it kept.
/// False when the edits pass `max_edits`, and nothing has been appended.
fn middle(gpa: Allocator, runs: *std.ArrayList(Run), a: []const u64, b: []const u64, at: u32) !bool {
    const n: i32 = @intCast(a.len);
    const m: i32 = @intCast(b.len);
    if (n == 0 and m == 0) return true;
    const limit: i32 = @min(n + m, max_edits);

    // `v[k]` is how far along `a` the furthest path on diagonal k reached,
    // with k = x - y offset by `limit + 1` to be an index. A copy is kept
    // for every step, which is the O(D²).
    const width: usize = @intCast(2 * limit + 3);
    var v = try gpa.alloc(i32, width);
    defer gpa.free(v);
    @memset(v, 0);
    var trace: std.ArrayList(i32) = .empty;
    defer trace.deinit(gpa);

    const origin = limit + 1;
    var d: i32 = 0;
    const found = search: while (d <= limit) : (d += 1) {
        try trace.appendSlice(gpa, v[@intCast(origin - d - 1)..@intCast(origin + d + 2)]);
        var k = -d;
        while (k <= d) : (k += 2) {
            const i: usize = @intCast(origin + k);
            var x = if (k == -d or (k != d and v[i - 1] < v[i + 1])) v[i + 1] else v[i - 1] + 1;
            var y = x - k;
            while (x < n and y < m and a[@intCast(x)] == b[@intCast(y)]) {
                x += 1;
                y += 1;
            }
            v[i] = x;
            if (x >= n and y >= m) break :search true;
        }
    } else false;
    if (!found) return false;

    // Back from the end, one edit a step, collecting runs backwards.
    var back: std.ArrayList(Run) = .empty;
    defer back.deinit(gpa);
    var x = n;
    var y = m;
    var step = d;
    var start: usize = trace.items.len;
    while (step >= 0) : (step -= 1) {
        const size: usize = @intCast(2 * step + 3);
        start -= size;
        const saved = trace.items[start..][0..size];
        // Index of diagonal k in this step's saved window.
        const k = x - y;
        const at_k = struct {
            fn f(w: []const i32, s: i32, kk: i32) i32 {
                return w[@intCast(kk + s + 1)];
            }
        }.f;
        const prev_k = if (k == -step or (k != step and at_k(saved, step, k - 1) < at_k(saved, step, k + 1))) k + 1 else k - 1;
        const prev_x = if (step == 0) 0 else at_k(saved, step, prev_k);
        const prev_y = if (step == 0) 0 else prev_x - prev_k;

        const snake: u32 = @intCast(@min(x - prev_x, y - prev_y));
        if (snake != 0) try back.append(gpa, .{ .kind = .same, .a = @intCast(x - @as(i32, @intCast(snake))), .b = @intCast(y - @as(i32, @intCast(snake))), .len = snake });
        if (step == 0) break;
        // Down from the diagonal above is a step along `b`: an addition.
        const kind: Run.Kind = if (prev_k == k + 1) .added else .removed;
        try back.append(gpa, .{ .kind = kind, .a = @intCast(prev_x), .b = @intCast(prev_y), .len = 1 });
        x = prev_x;
        y = prev_y;
    }

    var i = back.items.len;
    while (i > 0) {
        i -= 1;
        const r = back.items[i];
        try push(gpa, runs, r.kind, r.a + at, r.b + at, r.len);
    }
    return true;
}

/// A word of a page's text: a span of `text.Page.text` with no white space
/// in it.
pub const Word = struct {
    at: u32,
    len: u32,
};

/// The page's words, and a hash of each to diff.
pub fn words(gpa: Allocator, page_text: []const u8, out: *std.ArrayList(Word), hashes: *std.ArrayList(u64)) !void {
    var i: usize = 0;
    while (i < page_text.len) {
        while (i < page_text.len and std.ascii.isWhitespace(page_text[i])) i += 1;
        const start = i;
        while (i < page_text.len and !std.ascii.isWhitespace(page_text[i])) i += 1;
        if (i == start) break;
        try out.append(gpa, .{ .at = @intCast(start), .len = @intCast(i - start) });
        try hashes.append(gpa, std.hash.Wyhash.hash(0, page_text[start..i]));
    }
}

/// Where a run of words is on the page: one box per line it crosses, in
/// user space, each the union of its words' glyphs.
pub fn boxesOf(gpa: Allocator, page: text.Page, run: []const Word, out: *std.ArrayList(Bounds)) !void {
    var line: ?u32 = null;
    var box: Bounds = .empty;
    for (run) |w| {
        const first = page.glyphAt(w.at) orelse continue;
        const last = page.glyphAt(w.at + w.len - 1) orelse continue;
        const on = page.lineOf(first);
        if (line != null and line.? != on) {
            try out.append(gpa, box);
            box = .empty;
        }
        line = on;
        for (page.boxes[first .. last + 1]) |g| box = box.unionWith(g.box);
    }
    if (line != null) try out.append(gpa, box);
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

/// Each letter a word, so a script reads as the letters it moves.
fn letters(s: []const u8, buf: []u64) []const u64 {
    for (s, 0..) |c, i| buf[i] = c;
    return buf[0..s.len];
}

fn expectScript(from: []const u8, to: []const u8, want: []const Run) !void {
    var a: [64]u64 = undefined;
    var b: [64]u64 = undefined;
    const runs = try script(testing.allocator, letters(from, &a), letters(to, &b));
    defer testing.allocator.free(runs);
    try testing.expectEqualSlices(Run, want, runs);
}

test "one word replaced is one removed and one added, between what stayed" {
    try expectScript("abxcd", "abycd", &.{
        .{ .kind = .same, .a = 0, .b = 0, .len = 2 },
        .{ .kind = .removed, .a = 2, .b = 2, .len = 1 },
        .{ .kind = .added, .a = 3, .b = 2, .len = 1 },
        .{ .kind = .same, .a = 3, .b = 3, .len = 2 },
    });
}

test "a script through the middle finds what the ends do not share" {
    // No common head or tail: all of it goes through the search.
    try expectScript("xaby", "zabw", &.{
        .{ .kind = .removed, .a = 0, .b = 0, .len = 1 },
        .{ .kind = .added, .a = 1, .b = 0, .len = 1 },
        .{ .kind = .same, .a = 1, .b = 1, .len = 2 },
        .{ .kind = .removed, .a = 3, .b = 3, .len = 1 },
        .{ .kind = .added, .a = 4, .b = 3, .len = 1 },
    });
}

test "inserted and deleted runs, and texts that are the same or empty" {
    try expectScript("abc", "abc", &.{.{ .kind = .same, .a = 0, .b = 0, .len = 3 }});
    try expectScript("", "ab", &.{.{ .kind = .added, .a = 0, .b = 0, .len = 2 }});
    try expectScript("ab", "", &.{.{ .kind = .removed, .a = 0, .b = 0, .len = 2 }});
    try expectScript("abcd", "abXYcd", &.{
        .{ .kind = .same, .a = 0, .b = 0, .len = 2 },
        .{ .kind = .added, .a = 2, .b = 2, .len = 2 },
        .{ .kind = .same, .a = 2, .b = 4, .len = 2 },
    });
}

test "every script turns the first text into the second" {
    // Applying the runs to `a` must give `b`, whatever the inputs: the one
    // property that holds for every correct diff and fails for a wrong one.
    const cases = [_][2][]const u8{
        .{ "kitten", "sitting" },
        .{ "abcabba", "cbabac" },
        .{ "the quick brown", "quick brown the" },
        .{ "aaaa", "bbbb" },
    };
    for (cases) |c| {
        var a: [64]u64 = undefined;
        var b: [64]u64 = undefined;
        const from = letters(c[0], &a);
        const to = letters(c[1], &b);
        const runs = try script(testing.allocator, from, to);
        defer testing.allocator.free(runs);

        var built: std.ArrayList(u64) = .empty;
        defer built.deinit(testing.allocator);
        for (runs) |r| switch (r.kind) {
            .same => try built.appendSlice(testing.allocator, from[r.a..][0..r.len]),
            .added => try built.appendSlice(testing.allocator, to[r.b..][0..r.len]),
            .removed => {},
        };
        try testing.expectEqualSlices(u64, to, built.items);
    }
}

test "words are what the white space leaves, with their spans kept" {
    var ws: std.ArrayList(Word) = .empty;
    defer ws.deinit(testing.allocator);
    var hs: std.ArrayList(u64) = .empty;
    defer hs.deinit(testing.allocator);
    try words(testing.allocator, "  the quick\nfox  ", &ws, &hs);
    try testing.expectEqual(@as(usize, 3), ws.items.len);
    try testing.expectEqual(Word{ .at = 6, .len = 5 }, ws.items[1]);
    try testing.expectEqual(hs.items[0], std.hash.Wyhash.hash(0, "the"));
}
