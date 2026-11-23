//! A document another program rewrote, read again and put in place of the
//! old one with the reader's places kept: `fenrir read --watch`, or the
//! `watch` setting.
//!
//! The file's half is `watch.zig`, which notices the change and reads the
//! new document on the rasterising thread; this is the session's half, which
//! asks it to and installs what comes back. A file of its own so that the
//! session's half is in one place, as the file's is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const watch = @import("../watch.zig");
const Job = render.Job;
const Lap = frame.Lap;
const Session = @import("Session.zig");
const frame = @import("frame.zig");
const render = @import("render.zig");
const Slot = render.Slot;
const msOf = frame.msOf;
const compare = @import("compare.zig");
const cursor = @import("cursor.zig");
const journal = @import("journal.zig");
const marks = @import("marks.zig");
const plugins_mod = @import("plugins.zig");
const search_mod = @import("search.zig");

const hlidskjalf = fenrir.hlidskjalf;

const View = hlidskjalf.View;
const keys = hlidskjalf.keys;

const caps = fenrir.build_options;

/// What the `watch` setting says: on, or anything else, which is off.
pub fn rememberedWatch(s: *Session) bool {
    const lib = s.library orelse return false;
    const said = (lib.get("watch") catch null) orelse return false;
    defer s.gpa.free(said);
    return std.mem.eql(u8, said, "on");
}

/// Follows the files, or holds them shut. Turned off, a file another
/// program wrote while it was followed is read once more, so that what
/// is held is what is shown.
pub fn setWatching(s: *Session, on: bool) void {
    if (s.diff != null or s.watching == on) return;
    s.watching = on;
    const io = s.io orelse return;
    var i: u32 = 0;
    while (i < s.bufferCount()) : (i += 1) {
        const d = s.disk(i);
        const b = s.buffer(i);
        if (on) {
            if (d.hold) |*h| h.release(io);
            d.hold = null;
            d.notice = noticeOf(s, b.path);
            continue;
        }
        if (d.notice) |n| n.stop(s.gpa);
        d.notice = null;
        d.stirred = false;
        d.hold = watch.Hold.take(io, b.path) catch null;
        const stamp = watch.stat(io, b.path) orelse continue;
        if (!stamp.eql(d.held) and d.reload == .none) d.reload = .auto;
    }
}

/// What tells the reader that `path` changed, or null where nothing
/// will, and it is looked at every `watch.interval_ns` instead.
pub fn noticeOf(s: *Session, path: []const u8) ?*watch.Notice {
    return watch.Notice.start(s.gpa, path) catch |err| {
        // Expected where there are no notices, and not worth a line.
        if (err != error.Unsupported) s.ctx.note("{s} is looked at twice a second: no notices ({t})", .{ path, err });
        return null;
    };
}

/// Asks each followed file's notice what happened, and looks at the
/// file -- a stat, never a read, and nothing allocated -- only when
/// `watch.tick` says to. `dt` is the frame clock's, which the loop reads
/// anyway.
pub fn poll(s: *Session, dt: f32) void {
    if (!s.watching) return;
    const io = s.io orelse return;
    var i: u32 = 0;
    while (i < s.bufferCount()) : (i += 1) {
        const d = s.disk(i);
        const b = s.buffer(i);
        var said: ?watch.Notice.Said = null;
        if (d.notice) |n| {
            said = n.take(dt);
            if (said == .gone) {
                n.stop(s.gpa);
                d.notice = null;
                said = null;
                s.say("{s} is looked at twice a second: no more notices", .{b.title});
            }
        }
        // Taken while a reload is pending too, so that a write during
        // one is looked into after it. Never acted on while a save is
        // out: the file is moving because the reader is moving it.
        if (!watch.tick(d, dt, said) or d.reload != .none or d.save == .posted) continue;
        const stamp = watch.stat(io, b.path) orelse continue;
        if (watch.due(d, stamp)) d.reload = .auto;
    }
}

/// A file waiting to be read again, as a job.
fn reloadJob(s: *Session) ?Job {
    var i: u32 = 0;
    while (i < s.bufferCount()) : (i += 1) {
        if (s.disk(i).reload != .none) return .{ .buffer = i, .page = 0, .zoom = 0, .want = .reload };
    }
    return null;
}

/// What the worker is asked for next.
///
/// **While a reload or a save is pending, nothing else.** A page asked of
/// the old document after it would be drawn from a document `install`
/// frees, and with nothing else posted the worker is parked when the job
/// comes back -- which is what lets `install` free it on this thread. A
/// reload goes first: a save waits for the file it would be written on.
pub fn jobToPost(s: *Session) ?Job {
    if (caps.marks) {
        if (s.saving != null) return journal.jobFor(s);
    }
    return reloadJob(s) orelse (if (caps.marks) journal.jobFor(s) else null) orelse render.nextJob(s);
}

/// Puts what a reload read in place of what the buffer had: the
/// document, its pages and outline, and everything that knew them.
/// Only from `collectPage`, with the worker parked; see `jobToPost`.
pub fn install(s: *Session, index: u32, outcome: watch.Outcome) void {
    var lap: ?Lap = if (s.io) |io| .start(io) else null;
    const d = s.disk(index);
    const b = s.buffer(index);
    const forced = d.reload == .forced;
    d.reload = .none;

    var loaded = switch (outcome) {
        .refused => |r| {
            d.refused = r.stamp;
            if (forced) {
                s.say("{s} would not open: {t}", .{ b.title, r.why });
            } else {
                s.say("{s} is incomplete; showing gen {d}", .{ b.title, d.generation });
            }
            return;
        },
        .loaded => |l| l,
    };

    const before = b.pages.len;
    b.doc.deinit();
    s.gpa.destroy(b.doc);
    b.doc = loaded.doc;
    b.pages = loaded.pages;
    b.outline = loaded.outline;

    // What the pages were, kept until each window's caret has asked.
    const was = d.digests;
    const old = loaded.old_digests orelse was;
    defer {
        s.gpa.free(was);
        if (loaded.old_digests) |o| s.gpa.free(o);
    }
    d.digests = loaded.digests;
    d.held = loaded.stamp;
    d.seen = loaded.stamp;
    d.generation += 1;

    stalePages(s, index, @intCast(b.pages.len));
    b.dropMaps(s.gpa);
    if (loaded.map) |*m| {
        // Kept for the caret, which every build has.
        if (loaded.first) |page| b.putMap(s.gpa, page, m.*) else m.deinit(s.gpa);
    }
    // Keyed by the old document's object numbers.
    const faces = s.facesOf(index);
    faces.deinit();
    faces.* = .init(s.gpa);

    var it = s.tabs.iterator();
    while (it.next()) |v| {
        if (v.buffer != index) continue;
        v.pages = b.pages;
        v.refit();
        keepCursor(s, v, old, d.digests);
        v.clampScroll();
    }
    if (caps.marks) {
        if (s.drag) |drag| {
            const kept = watch.unchanged(old, d.digests, drag.from.page) and watch.unchanged(old, d.digests, drag.to.page);
            if (drag.buffer == index and !kept) s.drag = null;
        }
    }
    if (loaded.first) |page| cursor.placeStale(s, index, page);
    if (caps.panels) s.rows_for = .{};

    // The file's own annotations, read again: those the library holds
    // stay, as they do at open. A build with no marks has them in the
    // pages, which are read again already.
    if (caps.marks) {
        _ = b.marks.forget(s.gpa, &d.taken) catch 0;
        d.taken.clearRetainingCapacity();
        marks.readAnnots(s, index, loaded.annots);
    }
    if (loaded.annots_arena) |*a| a.deinit();
    // A save that found the file moved, made again on what is held now.
    if (caps.marks and d.resave) {
        d.resave = false;
        d.save = .wanted;
    }

    if (loaded.first) |page| showChange(s, index, page, loaded.down);
    if (caps.search and s.view().buffer == index and s.find.query().len != 0) search_mod.requery(s);

    var count_buf: [32]u8 = undefined;
    const counted = if (b.pages.len == before) "" else std.fmt.bufPrint(&count_buf, ", {d} pages", .{b.pages.len}) catch "";
    if (loaded.first) |page| {
        s.say("gen {d}: page {d} changed{s}", .{ d.generation, page + 1, counted });
    } else {
        s.say("gen {d}: no page changed{s}", .{ d.generation, counted });
    }

    if (s.plugins) |rt| {
        const doc = plugins_mod.handleOf(s, index);
        rt.emit(.{ .event = .DocReload, .doc = doc, .path = b.path, .data = .{ .document = .{
            .handle = doc,
            .path = b.path,
            .title = b.title,
            .pages = @intCast(b.pages.len),
        } } });
    }
    if (s.timing) {
        const ns = loaded.ns;
        // `heard`: from the first notice to the look that found the file
        // still, so the rest of the line is what it cost after that.
        s.ctx.note("watch  gen {d}  heard {d:.0}ms  read {d:.1}  open {d:.1}  annots {d:.1}  digest {d:.1}  locate {d:.1}  install {d:.1}", .{
            d.generation,    d.heard * 1000,  msOf(ns.read),                      msOf(ns.open), msOf(ns.annots),
            msOf(ns.digest), msOf(ns.locate), if (lap) |*l| msOf(l.lap()) else 0,
        });
    }
    d.heard = 0;
}

/// Where a window's caret is after its document is read again.
///
/// On a page that reads as it did, where it was: its line and column
/// count the same text. On one that changed, it keeps its place on the
/// page and is put on the nearest glyph when the page's text comes
/// (`cursor.placeStale`). A page that is gone sends it to the top of the
/// last. A selection with an end on a changed page goes, and visual mode
/// with it.
///
/// The author asked that a reload keep the caret; it first went to the
/// top of its page on every one. Do not go back to resetting it.
fn keepCursor(s: *Session, v: *View, old: []const u64, new: []const u64) void {
    const kept = watch.unchanged(old, new, v.cursor.page);
    const last: u32 = @intCast(v.pages.len - 1);
    if (v.cursor.page > last) {
        v.cursor.page = last;
        v.cursor.line = 0;
        v.cursor.column = 0;
        v.cursor.caret = .empty;
        v.cursor.stale = false;
    } else if (!kept) {
        v.cursor.stale = true;
    }
    const anchor = v.anchor orelse return;
    if (kept and watch.unchanged(old, new, anchor.page)) return;
    v.anchor = null;
    if (v == s.layout().current() and s.keymap.mode.isVisual()) s.keymap.mode = .normal;
}

/// Every cached picture of a buffer's pages is stale, and drawn until
/// its page comes again; a page past the new end is dropped.
fn stalePages(s: *Session, index: u32, pages: u32) void {
    for (&s.slots) |*slot| {
        if (slot.buffer != index or slot.page == Slot.no_page) continue;
        if (slot.page >= pages) {
            slot.page = Slot.no_page;
            slot.stale = false;
        } else slot.stale = true;
    }
    var dropped = false;
    for (&s.recorded.pages) |*e| {
        if (e.buffer != index or e.source == null) continue;
        if (e.page >= pages) {
            e.source.?.deinit(s.gpa);
            e.* = .{};
            dropped = true;
        } else e.stale = true;
    }
    if (dropped) s.recorded.rebuild(s.gpa) catch {};
    s.placed = null;
    // A page that would not draw before may now.
    for (&s.failures) |*f| {
        if (f.buffer == index) f.* = .{ .buffer = 0, .page = Slot.no_page, .zoom = 0 };
    }
}

/// Takes a window on the buffer to where a reload changed it: the focused
/// one if it shows the buffer, else the first that does. A change already
/// on screen moves nothing, and the other windows keep their place.
fn showChange(s: *Session, index: u32, page: u32, down: f32) void {
    const v = if (s.view().buffer == index) s.view() else blk: {
        var it = s.layout().iterator();
        while (it.next()) |w| {
            if (w.buffer == index) break :blk w;
        }
        return;
    };
    if (page >= v.pages.len) return;
    const at = v.pageTop(page) + down * v.zoom;
    if (at >= v.scroll and at <= v.scroll + v.height()) return;
    // What led up to the change stays on screen above it, as for `]d`.
    v.goTo(.{ .page = page, .offset = down - v.height() * compare.lead_in / v.zoom, .zoom = v.zoom });
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const putText = fixtures.putText;
const sessionOf = fixtures.sessionOf;

/// A document of `n` Letter-sized pages with nothing on them, on the heap
/// as a buffer holds one.
fn blankDocument(gpa: Allocator, n: usize) !*fenrir.Document {
    var src: Io.Writer.Allocating = .init(gpa);
    errdefer src.deinit();
    try src.writer.writeAll("%PDF-1.7\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [");
    for (0..n) |i| try src.writer.print("{d} 0 R ", .{i + 3});
    try src.writer.print("] /Count {d} >> endobj\n", .{n});
    for (0..n) |i| try src.writer.print("{d} 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] >> endobj\n", .{i + 3});
    try src.writer.writeAll("trailer << /Root 1 0 R >>\nstartxref 0\n%%EOF\n");

    const doc = try gpa.create(fenrir.Document);
    errdefer gpa.destroy(doc);
    doc.* = try fenrir.open(gpa, try src.toOwnedSlice());
    return doc;
}

/// A session on a real document of `n` pages, with its disk beside it: what
/// a reload is installed into. There is no worker; `install` is handed what
/// `watch.load` would have made.
fn watchedSession(gpa: Allocator, n: usize) !Session {
    const doc = try blankDocument(gpa, n);
    errdefer {
        doc.deinit();
        gpa.destroy(doc);
    }
    var s = try sessionOf(gpa, @constCast(try fenrir.pages.all(doc)), 1, 600, 900);
    s.buffer(0).doc = doc;
    return s;
}

fn closeWatched(s: *Session) void {
    const doc = s.buffer(0).doc;
    doc.deinit();
    s.gpa.destroy(doc);
    closeSession(s);
}

/// What `watch.load` hands back for a file of `n` blank pages that changed
/// at `first`, `down` points below its top.
fn reloadOf(gpa: Allocator, n: usize, first: ?u32, down: f32) !watch.Outcome {
    const doc = try blankDocument(gpa, n);
    const digests = try gpa.alloc(u64, n);
    @memset(digests, 0);
    return .{ .loaded = .{
        .doc = doc,
        .pages = try fenrir.pages.all(doc),
        .outline = &.{},
        .digests = digests,
        .stamp = .{ .size = 1, .mtime = 1 },
        .first = first,
        .down = down,
    } };
}

test "a reload leaves its buffer's pages stale, drawn until they come again" {
    const gpa = testing.allocator;
    var s = try watchedSession(gpa, 3);
    defer closeWatched(&s);
    s.slots[0] = .{ .buffer = 0, .page = 0, .zoom = 1, .gpu = 1 };
    s.slots[1] = .{ .buffer = 0, .page = 2, .zoom = 1, .gpu = 2 };
    // Another document's page, which a reload of this one leaves alone.
    s.slots[2] = .{ .buffer = 1, .page = 0, .zoom = 1, .gpu = 3 };

    install(&s, 0, try reloadOf(gpa, 2, null, 0));
    try testing.expect(s.slots[0].stale);
    // Past the new end.
    try testing.expectEqual(Slot.no_page, s.slots[1].page);
    try testing.expect(!s.slots[2].stale);

    // Still drawn, and asked for again.
    const v = s.view();
    try testing.expect(render.slotFor(&s, 0, 0, 1, false) != null);
    try testing.expect(!render.cached(&s, v, 0));
    try testing.expectEqual(@as(usize, 2), v.pages.len);
    try testing.expectEqual(@as(u32, 2), s.disk(0).generation);
    try testing.expect(s.disk(0).held.eql(.{ .size = 1, .mtime = 1 }));
    try testing.expectEqualStrings("gen 2: no page changed, 2 pages", s.status);
}

test "a reload goes to the change, unless the change is already on screen" {
    const gpa = testing.allocator;
    var s = try watchedSession(gpa, 3);
    defer closeWatched(&s);
    const v = s.view();
    v.scroll = 0;

    // A hundred points down the third page, which is below the window: it
    // lands a quarter of the way down, as `]d` puts a change.
    install(&s, 0, try reloadOf(gpa, 3, 2, 100));
    const at = v.pageTop(2) + 100 * v.zoom;
    try testing.expectApproxEqAbs(v.height() * compare.lead_in, at - v.scroll, 1);
    try testing.expectEqualStrings("gen 2: page 3 changed", s.status);

    // On screen now, so a second change there moves nothing.
    const kept = v.scroll;
    install(&s, 0, try reloadOf(gpa, 3, 2, 150));
    try testing.expectEqual(kept, v.scroll);
    // Nor does a reload that changed nothing.
    install(&s, 0, try reloadOf(gpa, 3, null, 0));
    try testing.expectEqual(kept, v.scroll);
}

/// What `watch.load` hands back when the pages' digests are `digests`, for
/// a held document whose own are set to compare them with.
fn reloadDigests(gpa: Allocator, digests: []const u64, first: ?u32) !watch.Outcome {
    const outcome = try reloadOf(gpa, digests.len, first, 0);
    @memcpy(outcome.loaded.digests, digests);
    return outcome;
}

test "a reload keeps the caret where the page did not change, and finds it where it did" {
    // The author asked for this: a reload first sent every caret to the top
    // of its page, wherever the change was.
    const gpa = testing.allocator;
    var s = try watchedSession(gpa, 3);
    defer closeWatched(&s);
    const v = s.view();

    // On the third line of the first page, which will not change.
    s.disk(0).digests = try gpa.dupe(u64, &.{ 1, 2, 3 });
    try putText(&s, 0, 4, 6);
    v.cursorTo(.{ .page = 0, .line = 2, .column = 3 }, s.buffer(0).textMap(0).?);
    const caret = v.cursor.caret;
    install(&s, 0, try reloadDigests(gpa, &.{ 1, 9, 3 }, 1));
    try testing.expectEqual(View.Position{ .page = 0, .line = 2, .column = 3 }, v.cursor.position());
    try testing.expect(!v.cursor.stale);
    try testing.expectEqual(caret, v.cursor.caret);

    // On the second page, which will: kept by its place until the page's
    // text comes, then put on the glyph there.
    try putText(&s, 1, 4, 6);
    v.cursorTo(.{ .page = 1, .line = 3, .column = 1 }, s.buffer(0).textMap(1).?);
    install(&s, 0, try reloadDigests(gpa, &.{ 1, 8, 3 }, 1));
    try testing.expect(v.cursor.stale);
    try testing.expectEqual(@as(u32, 1), v.cursor.page);
    try putText(&s, 1, 4, 6);
    cursor.placeStale(&s, 0, 1);
    try testing.expect(!v.cursor.stale);
    try testing.expectEqual(View.Position{ .page = 1, .line = 3, .column = 1 }, v.cursor.position());

    // A page taken off the end takes the caret to the top of the last.
    install(&s, 0, try reloadDigests(gpa, &.{ 1, 8 }, 1));
    try testing.expectEqual(View.Position{ .page = 1, .line = 3, .column = 1 }, v.cursor.position());
    v.cursor.page = 2;
    install(&s, 0, try reloadDigests(gpa, &.{1}, 0));
    try testing.expectEqual(View.Position{ .page = 0, .line = 0, .column = 0 }, v.cursor.position());
}

test "a selection is kept through a reload only where neither end's page changed" {
    if (!caps.marks) return error.SkipZigTest;
    const gpa = testing.allocator;
    var s = try watchedSession(gpa, 3);
    defer closeWatched(&s);
    const v = s.view();
    s.disk(0).digests = try gpa.dupe(u64, &.{ 1, 2, 3 });
    try putText(&s, 0, 4, 6);

    s.keymap.mode = .visual;
    v.cursorTo(.{ .page = 0, .line = 0, .column = 0 }, s.buffer(0).textMap(0).?);
    v.beginSelection();
    v.cursorTo(.{ .page = 0, .line = 1, .column = 4 }, s.buffer(0).textMap(0).?);

    install(&s, 0, try reloadDigests(gpa, &.{ 1, 7, 3 }, 1));
    try testing.expect(v.selection() != null);
    try testing.expectEqual(keys.Mode.visual, s.keymap.mode);

    install(&s, 0, try reloadDigests(gpa, &.{ 6, 7, 3 }, 0));
    try testing.expect(v.selection() == null);
    try testing.expectEqual(keys.Mode.normal, s.keymap.mode);
}

test "a file caught halfway is not shown, and is not tried again" {
    const gpa = testing.allocator;
    var s = try watchedSession(gpa, 2);
    defer closeWatched(&s);
    s.disk(0).reload = .auto;
    install(&s, 0, .{ .refused = .{ .stamp = .{ .size = 7 }, .why = error.Incomplete } });
    try testing.expectEqualStrings("a.pdf is incomplete; showing gen 1", s.status);
    try testing.expect(s.disk(0).refused.eql(.{ .size = 7 }));
    try testing.expectEqual(watch.Disk.Reload.none, s.disk(0).reload);
    try testing.expectEqual(@as(usize, 2), s.view().pages.len);
}

test "while a reload is pending, nothing else is asked of the worker" {
    const gpa = testing.allocator;
    var buf: [4]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 4), 1, 600, 900);
    defer closeSession(&s);

    // Pages are missing, and would be asked for.
    try testing.expectEqual(Job.Want.page, jobToPost(&s).?.want);
    s.disk(0).reload = .auto;
    try testing.expectEqual(Job.Want.reload, jobToPost(&s).?.want);
}

test ":reload reads the document again, and :set watch follows the file or holds it" {
    const gpa = testing.allocator;
    var buf: [2]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 2), 1, 600, 900);
    defer closeSession(&s);

    try testing.expect(s.exec("e!"));
    try testing.expectEqual(watch.Disk.Reload.forced, s.disk(0).reload);

    // Off unless asked for.
    try testing.expect(!s.watching);
    try testing.expect(s.exec("set watch=on"));
    try testing.expect(s.watching);
    try testing.expect(!s.exec("set watch=maybe"));
    try testing.expect(s.watching);
    try testing.expect(s.exec("set watch=off"));
    try testing.expect(!s.watching);
}
