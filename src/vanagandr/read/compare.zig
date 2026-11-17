//! What `fenrir diff` adds to the reader: its two documents side by side,
//! laid over each other or one at a time, held together as either moves,
//! and its changes washed over the pages and ticked on the scrollbar.
//!
//! A file of its own so that all of it is in one place, and so that a build
//! with no comparison -- whose `Session.diff` is `?noreturn` -- can leave the
//! file out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const diff_mod = @import("../diff.zig");
const Job = render.Job;
const Session = @import("Session.zig");
const render = @import("render.zig");
const windows = @import("windows.zig");

const content = fenrir.content;
const gleipnir = fenrir.gleipnir;

const Color = fenrir.gelgja.Color;
const DrawList = gleipnir.DrawList;
const View = fenrir.hlidskjalf.View;

const caps = fenrir.build_options;

/// A comparison made again with the second document moved, off the frame
/// thread: a nudge is a key held down, and every pair that differs is two
/// pages drawn again.
///
/// It opens its own views of the two files, as `raster --jobs` does. The
/// buffers' `Document`s belong to the rasterising thread, and the bytes
/// under them are only ever read.
pub const Rerun = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    /// What it was asked. Written before it starts and read by nobody else
    /// until `done`.
    gpa: Allocator = undefined,
    io: Io = undefined,
    bytes: [2][]const u8 = undefined,
    pairs: []const diff_mod.Pair = &.{},
    options: diff_mod.Options = .{},
    /// What it found, or why it found nothing.
    results: ?[]diff_mod.Result = null,
    failed: ?anyerror = null,
    /// A nudge came while it ran. What it is comparing is already stale,
    /// and it starts again when it is back.
    again: bool = false,

    fn work(r: *Rerun) void {
        var time: diff_mod.Timing = .{};
        r.results = diff_mod.compare(r.gpa, r.io, r.bytes, r.pairs, r.options, &time) catch |err| blk: {
            r.failed = err;
            break :blk null;
        };
        r.done.store(true, .release);
    }

    /// Waits for it, on the way out: it reads bytes the buffers own.
    pub fn finish(r: *Rerun) void {
        const thread = r.thread orelse return;
        thread.join();
        r.thread = null;
        if (r.results) |results| diff_mod.freeResults(r.gpa, results);
        r.results = null;
    }
};

/// The two windows of `fenrir diff`: the first document on the left and
/// the second on the right, both fitted, and both at the first change.
///
/// After the layout has a size and the first window its fit, because a
/// split halves the window and each half fits to what it is given.
pub fn arrangeComparison(s: *Session) void {
    const cmp = s.diff orelse return;
    if (s.layout().count() < 2) windows.splitWindow(s, .vertical);

    // A split focuses the new window, which is the one on the right.
    const right = s.view();
    right.buffer = 1;
    right.pages = s.buffer(1).pages;
    right.cursor = .{};
    right.scroll = 0;
    right.pan = 0;
    right.refit();
    _ = s.layout().focusSide(.left);
    s.dirty_title = true;

    if (cmp.changes.len == 0) {
        s.status = "no differences";
    } else {
        jumpChange(s, true);
    }
    lockComparison(s);
}

/// How a comparison is on screen, in the order `gd` goes round them:
/// diff-pdf's view, its `Ctrl+D` overlay, and its `Ctrl+<` and `Ctrl+>`.
pub const Showing = enum {
    side_by_side,
    /// One window on the first document's pages, each drawn as both
    /// pages laid over each other.
    overlay,
    first,
    second,

    /// The word `:diff` takes for each.
    pub fn byName(name: []const u8) ?Showing {
        const names = [_]struct { []const u8, Showing }{
            .{ "side", .side_by_side },
            .{ "overlay", .overlay },
            .{ "first", .first },
            .{ "second", .second },
        };
        for (names) |n| if (std.mem.eql(u8, n[0], name)) return n[1];
        return null;
    }

    pub fn label(s: Showing) []const u8 {
        return switch (s) {
            .side_by_side => "side by side",
            .overlay => "laid over each other -- red only in the first, blue only in the second",
            .first => "the first document alone",
            .second => "the second document alone",
        };
    }
};

/// `gd` and `gD`: round the ways of showing a comparison.
pub fn turnComparison(s: *Session, delta: i32) void {
    const n: i32 = @typeInfo(Showing).@"enum".field_names.len;
    const next = @mod(@as(i32, @intFromEnum(s.diff_showing)) + delta, n);
    showComparison(s, @enumFromInt(next));
}

/// Shows the comparison as `want`, at the place the reader is now.
///
/// Two windows for side by side and one for the rest. The one kept is
/// the focused one, moved to the page of its new document that was
/// compared with the page it was on -- which is what makes flipping
/// between the first alone and the second alone a blink comparator: the
/// page does not move, and the eye catches what did.
pub fn showComparison(s: *Session, want: Showing) void {
    const cmp = s.diff orelse {
        s.status = "nothing is being compared -- fenrir diff A B";
        return;
    };
    if (want == s.diff_showing) return;

    const v = s.view();
    const side: u1 = if (v.buffer == 1) 1 else 0;
    const at = v.place();
    const pages: [2]u32 = .{
        if (side == 0) at.page else cmp.partner(1, at.page),
        if (side == 1) at.page else cmp.partner(0, at.page),
    };

    s.layout().only(s.gpa);
    s.placed = null;
    const kept = s.view();
    const alone: u1 = if (want == .second) 1 else 0;
    showDocument(s, kept, alone, .{ .page = pages[alone], .offset = at.offset, .zoom = at.zoom });

    if (want == .side_by_side) {
        windows.splitWindow(s, .vertical);
        // The new window is focused, and on the right.
        showDocument(s, s.view(), 1, .{ .page = pages[1], .offset = at.offset, .zoom = at.zoom });
        _ = s.layout().focusSide(.left);
        s.diff_seen = @splat(.{});
    }
    s.diff_showing = want;
    s.dirty_title = true;
    s.say("{s}", .{want.label()});
}

/// A window put on a document at a place. A fitted window fits the
/// rectangle it has now -- half the width it had, or twice -- and a free
/// one keeps the zoom it was at; the place is in points either way.
fn showDocument(s: *Session, v: *View, index: u32, place: View.Place) void {
    v.buffer = index;
    v.pages = s.buffer(index).pages;
    v.cursor = .{};
    v.anchor = null;
    if (v.fit == .free) v.zoom = place.zoom else v.refit();
    v.goTo(place);
}

/// Whether this window draws the overlay rather than its own pages.
pub fn overlaid(s: *const Session, v: *const View) bool {
    return s.diff_showing == .overlay and v.buffer == 0;
}

/// What the worker is asked for to put this window's pages on screen.
pub fn pixelsFor(s: *const Session, v: *const View) Job.Want {
    return if (overlaid(s, v)) .overlay else .page;
}

pub fn shiftFor(s: *const Session, v: *const View) [2]f32 {
    return if (overlaid(s, v)) s.diff_offset else .{ 0, 0 };
}

/// `<C-arrows>`: the second document a point further across or down.
pub fn nudge(s: *Session, by: [2]i8) void {
    setOffset(s, .{
        s.diff_offset[0] + @as(f32, @floatFromInt(by[0])),
        s.diff_offset[1] + @as(f32, @floatFromInt(by[1])),
    });
}

/// Moves the second document against the first and compares them again.
///
/// The overlay follows at once, since it is drawn with the offset it is
/// asked for; the washes and `]d` follow when the comparison comes back,
/// because until then the regions they would draw are the old ones.
pub fn setOffset(s: *Session, offset: [2]f32) void {
    if (s.diff == null) {
        s.status = "nothing is being compared -- fenrir diff A B";
        return;
    }
    s.diff_offset = offset;
    compareAgain(s);
    var buf: [64]u8 = undefined;
    s.say("comparing again, the second document {s}", .{offsetWords(&buf, offset)});
}

/// `2pt right, 1pt up`.
fn offsetWords(buf: []u8, offset: [2]f32) []const u8 {
    if (offset[0] == 0 and offset[1] == 0) return "where it was";
    var w: Io.Writer = .fixed(buf);
    if (offset[0] != 0) w.print("{d}pt {s}", .{ @abs(offset[0]), if (offset[0] > 0) "right" else "left" }) catch {};
    if (offset[0] != 0 and offset[1] != 0) w.writeAll(", ") catch {};
    if (offset[1] != 0) w.print("{d}pt {s}", .{ @abs(offset[1]), if (offset[1] > 0) "down" else "up" }) catch {};
    return w.buffered();
}

/// Starts the comparison again with the offset in force, unless one is
/// already running -- then it is started again when that one is back,
/// with whatever the offset is by then. A held key is a nudge a frame,
/// and comparing for each would be comparing for none.
fn compareAgain(s: *Session) void {
    const cmp = s.diff orelse return;
    if (s.rerun.thread != null) {
        s.rerun.again = true;
        return;
    }
    const io = s.io orelse return;
    s.rerun = .{
        .gpa = cmp.gpa,
        .io = io,
        .bytes = .{ s.buffer(0).doc.bytes, s.buffer(1).doc.bytes },
        .pairs = cmp.pairs,
        .options = cmp.options,
    };
    s.rerun.options.offset = s.diff_offset;
    s.rerun.options.output_dir = null;
    // Every core: somebody is waiting on this, and the rasterising
    // thread has one page at a time to do.
    s.rerun.options.jobs = diff_mod.cpuCount();
    s.rerun.thread = std.Thread.spawn(.{}, Rerun.work, .{&s.rerun}) catch {
        s.status = "could not start comparing again";
        return;
    };
}

/// Takes the comparison made again, if it is back. Every frame, and it
/// never waits.
pub fn collectRerun(s: *Session) void {
    const thread = s.rerun.thread orelse return;
    if (!s.rerun.done.load(.acquire)) return;
    thread.join();
    s.rerun.thread = null;
    const cmp = s.diff.?;

    const results = s.rerun.results orelse {
        s.say("could not compare again: {t}", .{s.rerun.failed orelse error.Unexpected});
        return;
    };
    s.rerun.results = null;
    if (s.rerun.again or !std.meta.eql(s.rerun.options.offset, s.diff_offset)) {
        diff_mod.freeResults(cmp.gpa, results);
        s.rerun.again = false;
        compareAgain(s);
        return;
    }
    cmp.replace(results) catch {
        diff_mod.freeResults(cmp.gpa, results);
        s.status = "out of memory comparing again";
        return;
    };
    cmp.options.offset = s.rerun.options.offset;
    s.diff_at = null;
    for (&s.diff_ticks) |*t| t.zoom = 0;

    var buf: [64]u8 = undefined;
    s.say("{d} change{s}, the second document {s}", .{
        cmp.changes.len,
        if (cmp.changes.len == 1) "" else "s",
        offsetWords(&buf, cmp.options.offset),
    });
}

/// A page of the first document and its partner in the second, drawn at
/// the job's zoom and laid over each other as `--output-diff` lays them.
///
/// One picture the size of the first document's page, uploaded as that
/// page's texture on either backend: the GPU path draws outlines, and
/// "red where only one of two outlines is" is not a blend mode it has or
/// should grow for this.
///
/// **Runs on the rasterising thread**, which owns both documents.
pub fn rasteriseOverlay(s: *Session, job: Job) !render.Image {
    const cmp = s.diff.?;
    const gpa = s.gpa;
    const pair = cmp.pairs[cmp.pair_of[0][job.page]];

    var canvases: [2]?gleipnir.raster.Canvas = .{ null, null };
    defer for (&canvases) |*c| if (c.*) |*canvas| canvas.deinit(gpa);
    for ([2]?u32{ job.page, pair.b }, 0..) |maybe, side| {
        const page = maybe orelse continue;
        const b = s.buffer(@intCast(side));
        var result = try content.page(gpa, b.doc, b.pages[page], .{});
        defer result.deinit(gpa);
        canvases[side] = try render.drawCanvas(s, @intCast(side), page, result.list, job.zoom, if (side == 1) job.shift else .{ 0, 0 }, b);
    }

    const a = canvases[0].?.fb;
    var blank: ?gleipnir.Framebuffer = null;
    defer if (blank) |*fb| fb.deinit(gpa);
    const b = if (canvases[1]) |c| c.fb else blk: {
        blank = try diff_mod.blank(gpa, a);
        break :blk blank.?;
    };

    var out = try gleipnir.Framebuffer.init(gpa, a.width, a.height, .srgb);
    defer out.deinit(gpa);
    diff_mod.overlay(out, a, b, cmp.options.channel_tolerance, false);
    return .{ .pixels = try out.toRgba8(gpa), .width = out.width, .height = out.height };
}

/// Where a window was, to tell whether it has moved since.
pub const Seen = struct {
    scroll: f32 = -1,
    zoom: f32 = 0,
    pan: f32 = 0,

    fn of(v: *const View) Seen {
        return .{ .scroll = v.scroll, .zoom = v.zoom, .pan = v.pan };
    }
};

/// Holds the two documents' windows together. Whichever moved since the
/// last frame leads, and the other is put on the page its page was
/// compared with, as far down it, at the same zoom.
///
/// Compared rather than hooked into every scroll: a window moves with a
/// key, the wheel, the scrollbar, a jump, a fit and a resize, and a lock
/// that had to be told about each would be a lock that slips on the one
/// somebody forgot.
pub fn lockComparison(s: *Session) void {
    const cmp = s.diff orelse return;
    const views = comparedViews(s);
    const a = views[0] orelse return;
    const b = views[1] orelse return;

    const moved = [2]bool{
        !std.meta.eql(s.diff_seen[0], Seen.of(a)),
        !std.meta.eql(s.diff_seen[1], Seen.of(b)),
    };
    if (moved[0] or moved[1]) {
        // Both moved, as on a resize that refits each: the one being
        // looked at is the one to keep still.
        const lead: u1 = if (moved[0] and moved[1])
            (if (s.view() == b) 1 else 0)
        else if (moved[0]) 0 else 1;
        const from = views[lead].?;
        const to = views[lead ^ 1].?;
        const at = from.place();
        to.zoom = from.zoom;
        to.fit = from.fit;
        to.pan = from.pan;
        to.goTo(.{ .page = cmp.partner(lead, at.page), .offset = at.offset, .zoom = from.zoom });
    }
    s.diff_seen = .{ .of(a), .of(b) };
}

/// The first window on each document, in this tabpage.
fn comparedViews(s: *Session) [2]?*View {
    var views: [2]?*View = .{ null, null };
    var it = s.layout().iterator();
    while (it.next()) |v| {
        if (v.buffer < 2 and views[v.buffer] == null) views[v.buffer] = v;
    }
    return views;
}

/// `]d` and `[d`: the next or previous change, from the one landed on
/// last if the window has stayed where that left it, and otherwise from
/// where a jump would have put one -- a quarter of the way down.
pub fn jumpChange(s: *Session, forwards: bool) void {
    const cmp = s.diff orelse {
        s.status = "nothing is being compared -- fenrir diff A B";
        return;
    };
    const n = cmp.changes.len;
    if (n == 0) {
        s.status = "no differences";
        return;
    }
    const v = s.view();
    const side: u1 = if (v.buffer == 1) 1 else 0;

    var wrapped = false;
    var next: usize = undefined;
    const stayed = if (s.diff_at) |at| at.side == side and at.scroll == v.scroll else false;
    if (stayed) {
        const at = s.diff_at.?.change;
        wrapped = if (forwards) at + 1 == n else at == 0;
        next = if (forwards) (at + 1) % n else (at + n - 1) % n;
    } else {
        next = changeFrom(s, v, side, forwards, &wrapped);
    }
    goToChange(s, next);
    const round: []const u8 = if (!wrapped) "" else if (forwards) ", from the top" else ", from the end";
    s.say("change {d}/{d}{s}", .{ next + 1, n, round });
}

/// Puts the focused window at change `next`, and the other with it.
pub fn goToChange(s: *Session, next: usize) void {
    const cmp = s.diff orelse return;
    const v = s.view();
    const side: u1 = if (v.buffer == 1) 1 else 0;

    // A page only the other document has is shown in that document's
    // window, which then leads: placing this one beside the page before
    // it would leave the added page below the bottom of both.
    const change = cmp.changes[next];
    const pair = cmp.pairs[change.pair];
    const own: u1 = if ((if (side == 0) pair.a else pair.b) == null) side ^ 1 else side;
    const moving = comparedViews(s)[own] orelse v;
    const to = cmp.changeAt(own, change);
    // What led up to the change stays on screen above it.
    moving.goTo(.{ .page = to.page, .offset = to.down - moving.height() * lead_in / moving.zoom, .zoom = moving.zoom });
    if (moving != v) s.diff_seen[side] = .of(v);
    lockComparison(s);
    s.diff_at = .{ .change = @intCast(next), .side = side, .scroll = v.scroll };
}

/// How far down the window a jump puts a change.
pub const lead_in = 0.25;

/// The first change below the line a jump would put one on, or the last
/// above it. Changes are in page order on both sides, so their tops are
/// summed as the walk goes rather than asked for one at a time.
fn changeFrom(s: *Session, v: *View, side: u1, forwards: bool, wrapped: *bool) usize {
    const cmp = s.diff.?;
    const line = v.scroll + v.height() * lead_in;
    var top: f32 = View.gap;
    var page: u32 = 0;
    var before: ?usize = null;
    for (cmp.changes, 0..) |c, i| {
        const at = cmp.changeAt(side, c);
        while (page < at.page) : (page += 1) top += v.pageSize(page)[1] + View.gap;
        const y = top + at.down * v.zoom;
        // A pixel's slack each way, so the change a jump has just put on
        // the line is neither the next nor the previous one.
        if (forwards and y > line + 1) return i;
        if (!forwards and y < line - 1) before = i;
    }
    if (before) |i| return i;
    wrapped.* = true;
    return if (forwards) 0 else cmp.changes.len - 1;
}

/// Red on the first document and green on the second, over each change on
/// the pages a window can see; a whole page one document has alone is
/// washed from edge to edge.
///
/// Fixed colours and not the theme's, because the page's colours are the
/// document's: see "A colour drawn on the page cannot come from the
/// theme" in `ui.md`.
pub fn drawChanges(s: *Session, v: *View, range: View.Visible, over: *DrawList) !void {
    const cmp = s.diff orelse return;
    // The overlay is its own picture of the changes, in its own colours.
    if (v.buffer > 1 or overlaid(s, v)) return;
    const side: u1 = @intCast(v.buffer);
    const wash: Color = if (side == 0) diff_removed else diff_added;

    var page = range.first;
    while (page < range.end) : (page += 1) {
        const r = cmp.resultOn(side, page);
        if (!r.differs()) continue;
        if (r.regions.len == 0) {
            try over.fill(v.pageRect(page), wash.withAlpha(0.12));
            continue;
        }
        // The regions say where the pixels moved, lightly; the words
        // that went or came are what a reader reads, and are washed as a
        // highlighter would.
        const height = v.pageBox(page).max_y;
        for (r.regions) |region| {
            const box = v.windowBox(page, cmp.regionIn(side, region, height));
            try over.fill(box, wash.withAlpha(0.08));
            try over.border(box, .all(0), 1, wash.withAlpha(0.7));
        }
        for (if (side == 0) r.removed else r.added) |words| {
            try over.fill(v.windowBox(page, words), wash.withAlpha(0.3));
        }
    }
}

/// Where each change is on this window's scrollbar, as a tick beside the
/// track, the way diff-pdf's gutter marks a page.
///
/// Worked out from the page tops once per zoom and kept: a document of
/// five hundred pages and a thousand changes would otherwise walk every
/// page above each change, every frame.
pub fn drawChangeTicks(s: *Session, v: *View, bar: View.Scrollbar, list: *DrawList) !void {
    const cmp = s.diff orelse return;
    if (v.buffer > 1) return;
    const side: u1 = @intCast(v.buffer);
    const ticks = &s.diff_ticks[side];
    if (ticks.zoom != v.zoom) {
        ticks.at.clearRetainingCapacity();
        const total = v.documentHeight();
        var top: f32 = View.gap;
        var page: u32 = 0;
        for (cmp.changes) |c| {
            const at = cmp.changeAt(side, c);
            // Changes are in page order, so the tops are summed once.
            while (page < at.page) : (page += 1) top += v.pageSize(page)[1] + View.gap;
            try ticks.at.append(s.gpa, (top + at.down * v.zoom) / total);
        }
        ticks.zoom = v.zoom;
    }

    // Across the thumb's column and a little either side, over the thumb,
    // so a change inside the visible stretch is marked there too.
    const track = bar.travel + bar.height;
    const wash: Color = if (side == 0) diff_removed else diff_added;
    for (ticks.at.items) |f| {
        const y = @round(bar.top + f * track);
        try list.fill(.fromRect(bar.x0 - 3, y - 1, bar.x1 + 2, y + 2), wash);
    }
}

/// A comparison's washes: what the first document has and the second
/// does not, and the other way round. diff-pdf's view uses the same two.
pub const diff_removed: Color = .{ .r = 0.86, .g = 0.15, .b = 0.15 };
pub const diff_added: Color = .{ .r = 0.1, .g = 0.62, .b = 0.25 };

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const interface = @import("interface.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const sessionOf = fixtures.sessionOf;

test {
    // The tests of a feature this build left out are left out with it. See
    // `comparison_tests`.
    if (caps.compare) _ = comparison_tests;
}

/// The comparison tests, which only a build that has a comparison can run.
///
/// Nested in a struct the test block above references only when the
/// capability is on: a test declaration inside a container that is never
/// analysed is never registered. `error.SkipZigTest` could not have done
/// this -- the body would still have to compile, and `Session.diff` has no
/// payload type in a build with no comparison.
const comparison_tests = struct {
    /// Six pages against seven: one change a third of the way down page three,
    /// and a seventh page only the second document has. Regions measured at one
    /// pixel a point, so they read as points.
    fn comparedSession(gpa: Allocator, buf: []fenrir.Page, results: *[7]diff_mod.Result, cmp: *diff_mod.Comparison) !Session {
        var s = try sessionOf(gpa, fakePages(buf, 6), 1, 1000, 800);
        errdefer closeSession(&s);
        try s.buffers.append(gpa, .{
            .path = try gpa.dupe(u8, "/docs/b.pdf"),
            .title = "b.pdf",
            .pages = fakePages(buf[6..], 7),
        });
        const pairs = try diff_mod.pairByNumber(gpa, 6, 7);
        errdefer gpa.free(pairs);
        results.* = @splat(.{ .kind = .same_list });
        results[2] = .{ .kind = .differ, .pixels = 400, .regions = &.{.{ .x0 = 40, .y0 = 300, .x1 = 240, .y1 = 320 }} };
        results[6] = .{ .kind = .only_b };
        cmp.* = try .init(gpa, pairs, results, .{ 6, 7 }, .{ .dpi = 72 });
        s.diff = cmp;
        return s;
    }

    fn closeCompared(s: *Session, cmp: *diff_mod.Comparison) void {
        s.gpa.free(cmp.pairs);
        cmp.deinit();
        for (&s.diff_ticks) |*t| t.at.deinit(s.gpa);
        closeSession(s);
    }

    test "a comparison opens side by side at its first change, and the windows move together" {
        const gpa = testing.allocator;
        var buf: [13]fenrir.Page = undefined;
        var results: [7]diff_mod.Result = undefined;
        var cmp: diff_mod.Comparison = undefined;
        var s = try comparedSession(gpa, &buf, &results, &cmp);
        defer closeCompared(&s, &cmp);

        arrangeComparison(&s);
        try testing.expectEqual(@as(u32, 2), s.layout().count());
        const views = comparedViews(&s);
        const a = views[0].?;
        const b = views[1].?;
        // The first document on the left, and focused.
        try testing.expect(a.rect.min_x < b.rect.min_x);
        try testing.expectEqual(a, s.view());

        // At the change, a quarter of the way down, in both.
        try testing.expectEqual(@as(u32, 2), a.currentPage());
        const line = a.scroll + a.height() * 0.25;
        try testing.expectApproxEqAbs(a.pageTop(2) + 300, line, 0.5);
        try testing.expectEqual(a.scroll, b.scroll);
        try testing.expectEqualStrings("change 1/2", s.status);

        // Scrolling or zooming either one moves the other.
        b.scroll += 120;
        lockComparison(&s);
        try testing.expectEqual(b.scroll, a.scroll);
        a.setZoom(1.5);
        lockComparison(&s);
        try testing.expectEqual(@as(f32, 1.5), b.zoom);
        try testing.expectEqual(a.currentPage(), b.currentPage());
    }

    test "]d shows a page only one document has in that document's window, and wraps" {
        const gpa = testing.allocator;
        var buf: [13]fenrir.Page = undefined;
        var results: [7]diff_mod.Result = undefined;
        var cmp: diff_mod.Comparison = undefined;
        var s = try comparedSession(gpa, &buf, &results, &cmp);
        defer closeCompared(&s, &cmp);
        arrangeComparison(&s);

        jumpChange(&s, true);
        const views = comparedViews(&s);
        // The seventh page is the second document's, and its window has it;
        // the first document's stays beside its last page rather than past it.
        try testing.expectEqual(@as(u32, 6), views[1].?.currentPage());
        try testing.expectEqual(@as(u32, 5), views[0].?.currentPage());
        try testing.expectEqualStrings("change 2/2", s.status);

        jumpChange(&s, true);
        try testing.expectEqualStrings("change 1/2, from the top", s.status);
        try testing.expectEqual(@as(u32, 2), views[0].?.currentPage());

        // Backwards from the first is the last.
        jumpChange(&s, false);
        try testing.expectEqualStrings("change 2/2, from the end", s.status);
    }

    test "gd goes round side by side, the overlay, and each document alone, at one place" {
        const gpa = testing.allocator;
        var buf: [13]fenrir.Page = undefined;
        var results: [7]diff_mod.Result = undefined;
        var cmp: diff_mod.Comparison = undefined;
        var s = try comparedSession(gpa, &buf, &results, &cmp);
        defer closeCompared(&s, &cmp);
        arrangeComparison(&s);
        const scroll = s.view().scroll;

        // The overlay: one window, on the first document's pages, asking the
        // worker for pictures of both rather than for the page.
        _ = s.apply(.{ .diff_view = 1 });
        try testing.expectEqual(Showing.overlay, s.diff_showing);
        try testing.expectEqual(@as(u32, 1), s.layout().count());
        try testing.expectEqual(@as(u32, 0), s.view().buffer);
        try testing.expectEqual(Job.Want.overlay, render.firstMissing(&s).?.want);
        try testing.expectEqual(scroll, s.view().scroll);

        // Each alone, and the blink between them keeps the place.
        _ = s.apply(.{ .diff_view = 1 });
        try testing.expectEqual(Job.Want.page, render.firstMissing(&s).?.want);
        _ = s.apply(.{ .diff_view = 1 });
        try testing.expectEqual(Showing.second, s.diff_showing);
        try testing.expectEqual(@as(u32, 1), s.view().buffer);
        try testing.expectEqual(scroll, s.view().scroll);
        _ = s.apply(.{ .diff_view = -1 });
        try testing.expectEqual(@as(u32, 0), s.view().buffer);
        try testing.expectEqual(scroll, s.view().scroll);

        // And back to two windows, first on the left, still together.
        _ = s.apply(.{ .diff_view = -1 });
        _ = s.apply(.{ .diff_view = -1 });
        try testing.expectEqual(Showing.side_by_side, s.diff_showing);
        const views = comparedViews(&s);
        try testing.expect(views[0].?.rect.min_x < views[1].?.rect.min_x);
        lockComparison(&s);
        try testing.expectEqual(views[0].?.scroll, views[1].?.scroll);
    }

    test "the changes panel is a row a page that differs, numbered from the window's side" {
        const gpa = testing.allocator;
        var buf: [13]fenrir.Page = undefined;
        var results: [7]diff_mod.Result = undefined;
        var cmp: diff_mod.Comparison = undefined;
        var s = try comparedSession(gpa, &buf, &results, &cmp);
        defer closeCompared(&s, &cmp);
        arrangeComparison(&s);
        results[2].detail = "\"fox\" → \"cat\"";

        const rows = interface.panelRows(&s, .changes);
        try testing.expectEqual(@as(usize, 2), rows.len);
        try testing.expectEqualStrings("\"fox\" → \"cat\"", rows[0].label);
        try testing.expectEqual(@as(u32, 3), rows[0].page);
        // The seventh page is the second document's alone. From the first
        // document's window it stands beside that document's last page.
        try testing.expectEqualStrings("only in the second document", rows[1].label);
        try testing.expectEqual(@as(u32, 6), rows[1].page);
        try testing.expectEqual(@as(u64, 7), rows[1].id);
    }

    test "a nudge moves the overlay at once, and a picture of the old offset is not wanted" {
        const gpa = testing.allocator;
        var buf: [13]fenrir.Page = undefined;
        var results: [7]diff_mod.Result = undefined;
        var cmp: diff_mod.Comparison = undefined;
        var s = try comparedSession(gpa, &buf, &results, &cmp);
        defer closeCompared(&s, &cmp);
        arrangeComparison(&s);
        showComparison(&s, .overlay);

        const before = render.firstMissing(&s).?;
        _ = s.apply(.{ .nudge = .{ 1, 0 } });
        _ = s.apply(.{ .nudge = .{ 1, 0 } });
        _ = s.apply(.{ .nudge = .{ 0, -1 } });
        try testing.expectEqual([2]f32{ 2, -1 }, s.diff_offset);
        try testing.expectEqualStrings("comparing again, the second document 2pt right, 1pt up", s.status);

        const after = render.firstMissing(&s).?;
        try testing.expectEqual([2]f32{ 2, -1 }, after.shift);
        try testing.expect(!before.eql(after));
        try testing.expect(!render.wantedNow(&s, before));
        try testing.expect(render.wantedNow(&s, after));

        // The regions stay the ones they were found at until the comparison
        // made again comes back.
        try testing.expectEqual([2]f32{ 0, 0 }, cmp.options.offset);
        _ = s.exec("diff offset");
        try testing.expectEqual([2]f32{ 0, 0 }, s.diff_offset);
    }

    test "a comparison made again on its own thread comes back with the offset's answer" {
        var one: [512]u8 = undefined;
        var two: [512]u8 = undefined;
        const pairs = [_]diff_mod.Pair{.{ .a = 0, .b = 0 }};
        var r: Rerun = .{
            .gpa = testing.allocator,
            .io = testing.io,
            .bytes = .{ diff_mod.rectanglePdf(&one, 72), diff_mod.rectanglePdf(&two, 108) },
            .pairs = &pairs,
            .options = .{ .dpi = 36, .offset = .{ -36, 0 } },
        };
        r.thread = try std.Thread.spawn(.{}, Rerun.work, .{&r});
        defer r.finish();
        r.thread.?.join();
        r.thread = null;

        try testing.expect(r.done.load(.acquire));
        try testing.expectEqual(diff_mod.Result.Kind.same_pixels, r.results.?[0].kind);
        diff_mod.freeResults(r.gpa, r.results.?);
        r.results = null;
    }
};
