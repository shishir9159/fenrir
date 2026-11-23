//! The marks written into the file: `:w`, closing the reader, and a save
//! that died halfway, put right when the file is next opened.
//!
//! The library is the journal (`Library`, "The journal") and `save.zig`
//! makes the update and appends it. This is the session's half: whether a
//! document is written at all (`store`), the plan built on this thread
//! from the library, the job the rasterising thread runs -- it owns the
//! `Document` a save is made from -- and what comes back put in place.
//!
//! **A save is not a change.** What comes back is the bytes the reader
//! held with the update after them, opened: no read from disk, no new
//! generation, no jump, and every picture of every page kept, since an
//! update adds annotations, which the reader draws itself, and touches no
//! page's content. The author asked that fenrir's own save never cost a
//! reload; do not replace adopting the bytes with reading the file again.
//!
//! A file of its own so that a build with no marks, which has nothing to
//! write, leaves it out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const library = @import("../library.zig");
const Library = library.Library;
const save = @import("../save.zig");
const watch = @import("../watch.zig");
const Session = @import("Session.zig");
const marks = @import("marks.zig");
const plugins_mod = @import("plugins.zig");
const render = @import("render.zig");

const Document = fenrir.Document;

/// Where a document's marks are kept: written into the PDF, the default,
/// or only in the library, for a file that is not the reader's to change.
pub const Store = enum { pdf, library };

/// What the `store` setting says: `library`, or anything else, which is
/// the PDF.
pub fn rememberedStore(s: *Session) Store {
    const lib = s.library orelse return .pdf;
    const said = (lib.get("store") catch null) orelse return .pdf;
    defer s.gpa.free(said);
    return storeNamed(said) orelse .pdf;
}

pub fn storeNamed(name: []const u8) ?Store {
    return std.meta.stringToEnum(Store, name);
}

/// Where buffer `index`'s marks go: its own choice, which `fenrir marks
/// --store` makes, over the setting.
pub fn storeFor(s: *Session, index: u32) Store {
    const lib = s.library orelse return s.store;
    const own = (lib.storeOf(s.buffer(index).path) catch null) orelse return s.store;
    defer s.gpa.free(own);
    return storeNamed(own) orelse s.store;
}

/// A save on its way: the plan, built on this thread from the library,
/// and read by the rasterising thread. One at a time, as a reload is.
pub const Saving = struct {
    buffer: u32,
    arena: std.heap.ArenaAllocator,
    plan: save.Plan,
    /// Mixed into a new `/ID`: the path and the time.
    seed: []const u8,
};

/// What a save came back with.
pub const Outcome = union(enum) {
    written: Written,
    /// The plan came to nothing the file does not already say.
    unchanged,
    /// The file moved since it was read: it is read again, then written.
    stale,
    /// Not written, and why. The journal is kept.
    refused: anyerror,
};

pub const Written = struct {
    /// The held bytes and the update, opened, with its pages and outline
    /// in its arena; null when opening them failed, and the file is read
    /// again instead.
    doc: ?*Document = null,
    pages: []const fenrir.Page = &.{},
    outline: []const fenrir.outline.Entry = &.{},
    /// One a page, owned, when the held document had them.
    digests: ?[]u64 = null,
    stamp: watch.Stamp,
    bytes: usize,

    pub fn deinit(w: *Written, gpa: Allocator) void {
        if (w.doc) |doc| {
            doc.deinit();
            gpa.destroy(doc);
        }
        if (w.digests) |d| gpa.free(d);
        w.* = undefined;
    }
};

/// `:w`: asks for buffer `index`'s journal to be written into its file.
/// The save itself is the rasterising thread's, on a later frame.
pub fn write(s: *Session, index: u32) bool {
    const b = s.buffer(index);
    if (s.diff != null) {
        s.say("a comparison is not written: open the document on its own", .{});
        return false;
    }
    const lib = s.library orelse {
        s.say("no library: nothing was journaled, and nothing is written", .{});
        return false;
    };
    if (storeFor(s, index) == .library) {
        s.say("{s} keeps its marks in the library: store = library", .{b.title});
        return true;
    }
    if (!(lib.journaled(b.path) catch false)) {
        if (s.status.len == 0) s.say("{s}: nothing to write", .{b.title});
        return true;
    }
    s.disk(index).save = .wanted;
    return true;
}

/// The save the rasterising thread is to run next, if any: the one posted
/// until it comes back, so that nothing else is asked of the worker while
/// it is out -- `install` frees the document it was made from -- and
/// otherwise the first one asked for.
pub fn jobFor(s: *Session) ?render.Job {
    if (s.saving) |w| return jobOf(w.buffer);
    var i: u32 = 0;
    while (i < s.bufferCount()) : (i += 1) {
        const d = s.disk(i);
        if (d.save != .wanted or d.reload != .none) continue;
        begin(s, i);
        if (s.saving != null) return jobOf(i);
    }
    return null;
}

fn jobOf(index: u32) render.Job {
    return .{ .buffer = index, .page = 0, .zoom = 0, .want = .save };
}

/// The plan, made here: the library is read on this thread, and the worker
/// gets plain data.
fn begin(s: *Session, index: u32) void {
    const d = s.disk(index);
    const b = s.buffer(index);
    d.save = .none;
    const lib = s.library orelse return;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    const a = arena.allocator();
    var plan = save.planOf(a, lib, b.path) catch |err| {
        arena.deinit();
        s.say("{s}: the journal would not read ({t})", .{ b.title, err });
        return;
    };
    if (plan.isEmpty()) {
        arena.deinit();
        s.say("{s}: nothing to write", .{b.title});
        return;
    }
    startArrows(s, index, &plan);
    if (lib.author() catch null) |name| {
        defer s.gpa.free(name);
        plan.author = a.dupe(u8, name) catch "";
    }
    plan.when = now(s);
    const seed = std.fmt.allocPrint(a, "{s}{d}", .{ b.path, plan.when }) catch "";

    // The worker writes the file, which a hold shuts against everybody,
    // this process included. Taken again when the save comes back.
    if (d.hold) |*h| {
        if (s.io) |io| h.release(io);
        d.hold = null;
    }
    d.save = .posted;
    s.saving = .{ .buffer = index, .arena = arena, .plan = plan, .seed = seed };
}

/// Where an arrow's first line begins, from the text map, so that the
/// arrow written into the file stops short of the line's words and not of
/// the mark, as the reader draws it (`marks.lineStart`). Left to the mark's
/// edge where the page's text is not known.
fn startArrows(s: *Session, index: u32, plan: *save.Plan) void {
    const b = s.buffer(index);
    for (plan.anchors) |an| {
        if (an.kind != .arrow or an.pieces.len == 0) continue;
        const first = an.pieces[0];
        if (first.lines.len == 0) continue;
        const map = b.textMap(first.page) orelse continue;
        if (map.isEmpty()) continue;
        const line = first.lines[0];
        const at = map.lines[map.lineAt(line.min_x, (line.min_y + line.max_y) * 0.5)].box;
        // `planOf` made these in its arena, as anything but const.
        @constCast(&an.pieces[0]).start = @min(at.min_x, line.min_x);
    }
}

/// The worker's half: the save made, checked against the stamp the file
/// was read with, appended, and the result opened. On the rasterising
/// thread, which owns the document.
pub fn produce(s: *Session, index: u32) Outcome {
    const w = s.saving.?;
    const io = s.io orelse return .{ .refused = error.NoIo };
    const d = s.disk(index);
    const b = s.buffer(index);
    const digest = d.digests.len == b.pages.len and b.pages.len != 0;
    return writeOut(s.gpa, io, s.library.?, b.path, b.doc, d.held, w.plan, w.seed, b.pages.len, digest);
}

/// One save of `doc`, which was read from `path` when it had `held`.
///
/// **Never appended to bytes it has not parsed.** Another program's save
/// is found by the stamp `--watch` polls, before anything is written, and
/// the reader reads the file again rather than writing on top of it.
fn writeOut(
    gpa: Allocator,
    io: Io,
    lib: Library,
    path: []const u8,
    doc: *Document,
    held: watch.Stamp,
    plan: save.Plan,
    seed: []const u8,
    /// How many pages the held document has, which the one opened after
    /// must have too; zero to open nothing.
    adopt: usize,
    digest: bool,
) Outcome {
    const now_stamp = watch.stat(io, path) orelse return .{ .refused = error.FileNotFound };
    if (!now_stamp.eql(held)) return .stale;
    const bytes = save.write(gpa, io, lib, path, path, doc, plan, seed, .in) catch |err| return .{ .refused = err };
    defer gpa.free(bytes);
    if (bytes.len == 0) return .unchanged;
    var got: Written = .{ .stamp = watch.stat(io, path) orelse .{}, .bytes = bytes.len };
    if (adopt != 0) opened(gpa, doc, bytes, adopt, digest, &got) catch {};
    return .{ .written = got };
}

/// The held bytes with the update after them, opened as the file now is.
fn opened(gpa: Allocator, held: *Document, update: []const u8, pages_held: usize, digest: bool, got: *Written) !void {
    const all = try std.mem.concat(gpa, u8, &.{ held.bytes, update });
    const doc = gpa.create(Document) catch |err| {
        gpa.free(all);
        return err;
    };
    errdefer gpa.destroy(doc);
    // The document frees the bytes from here on, opened or not.
    doc.* = try fenrir.open(gpa, all);
    errdefer doc.deinit();
    const pages = try fenrir.pages.all(doc);
    // An update adds annotations and no page; anything else is read again.
    if (pages.len != pages_held) return error.PagesMoved;
    got.outline = fenrir.outline.all(doc, pages) catch &.{};
    got.pages = pages;
    got.digests = if (digest) try watch.digestAll(gpa, doc, pages) else null;
    got.doc = doc;
}

/// Puts what a save came back with in place. From `collectPage`, with the
/// worker parked, as a reload is installed.
pub fn install(s: *Session, index: u32, outcome: Outcome) void {
    const d = s.disk(index);
    const b = s.buffer(index);
    d.save = .none;
    if (s.saving) |*w| w.arena.deinit();
    s.saving = null;
    defer if (!s.watching and d.hold == null) {
        if (s.io) |io| d.hold = watch.Hold.take(io, b.path) catch null;
    };

    switch (outcome) {
        .unchanged => s.say("{s}: nothing to write", .{b.title}),
        .refused => |err| s.say("{s} is not written, and its marks stay in the library: {s}", .{ b.title, save.whyNot(err) }),
        .stale => {
            d.reload = .auto;
            d.resave = true;
            s.say("{s} changed on disk: it is read again, then written", .{b.title});
        },
        .written => |got| {
            var w = got;
            inFile(s, index);
            d.held = w.stamp;
            d.seen = w.stamp;
            if (w.doc) |doc| {
                b.doc.deinit();
                s.gpa.destroy(b.doc);
                b.doc = doc;
                b.pages = w.pages;
                b.outline = w.outline;
                w.doc = null;
                // Keyed by the old document's objects, and holding its bytes.
                const faces = s.facesOf(index);
                faces.deinit();
                faces.* = .init(s.gpa);
                var it = s.tabs.iterator();
                while (it.next()) |v| {
                    if (v.buffer == index) v.pages = b.pages;
                }
                if (w.digests) |fresh| {
                    s.gpa.free(d.digests);
                    d.digests = fresh;
                    w.digests = null;
                }
            } else d.reload = .forced;
            w.deinit(s.gpa);
            s.say("{s}: written, {d} bytes", .{ b.title, got.bytes });
            if (s.plugins) |rt| {
                const doc = plugins_mod.handleOf(s, index);
                rt.emit(.{ .event = .DocSave, .doc = doc, .path = b.path, .data = .{ .document = .{
                    .handle = doc,
                    .path = b.path,
                    .title = b.title,
                    .pages = @intCast(b.pages.len),
                } } });
            }
        },
    }
}

/// What the library held is the file's now: the rows are gone, so every
/// mark and comment that had one has none, and its name is one the file
/// holds. A change made while the save was out had no row -- the library
/// was not written for this buffer meanwhile -- and stays the reader's.
fn inFile(s: *Session, index: u32) void {
    const b = s.buffer(index);
    const taken = &s.disk(index).taken;
    for (b.marks.list.items) |*m| {
        if (!m.saved()) continue;
        taken.put(s.gpa, m.anchor, {}) catch {};
        m.id = fenrir.hlidskjalf.Marks.Mark.unsaved;
    }
    for (b.marks.comments.items) |*c| {
        if (!c.saved()) continue;
        taken.put(s.gpa, c.name, {}) catch {};
        c.id = fenrir.hlidskjalf.Marks.Mark.unsaved;
    }
}

/// Closing: every document whose journal has anything in it is written,
/// unless it keeps its marks in the library. After the rasterising thread
/// has stopped, which makes every document this thread's, and so the same
/// save as `:w`'s with nobody to hand it to. Nothing is put in place, the
/// reader being on its way out.
pub fn closing(s: *Session) void {
    if (!s.writes_on_close) return;
    marks.retryEffects(s);
    const lib = s.library orelse return;
    const io = s.io orelse return;
    var i: u32 = 0;
    while (i < s.bufferCount()) : (i += 1) {
        const b = s.buffer(i);
        const d = s.disk(i);
        if (storeFor(s, i) != .pdf or !(lib.journaled(b.path) catch false)) continue;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var plan = save.planOf(a, lib, b.path) catch continue;
        if (plan.isEmpty()) continue;
        startArrows(s, i, &plan);
        if (lib.author() catch null) |name| {
            defer s.gpa.free(name);
            plan.author = a.dupe(u8, name) catch "";
        }
        plan.when = now(s);
        if (d.hold) |*h| {
            h.release(io);
            d.hold = null;
        }
        const seed = std.fmt.allocPrint(a, "{s}{d}", .{ b.path, plan.when }) catch "";
        switch (writeOut(s.gpa, io, lib, b.path, b.doc, d.held, plan, seed, 0, false)) {
            .written => |got| s.ctx.note("{s}: written, {d} bytes", .{ b.title, got.bytes }),
            .unchanged => {},
            .stale => s.ctx.note("{s} changed on disk; its marks stay in the library, and go in at the next save", .{b.title}),
            .refused => |err| s.ctx.note("{s} is not written, and its marks stay in the library: {s}", .{ b.title, save.whyNot(err) }),
        }
    }
}

/// Puts right a save into `path` that the reader did not live to finish,
/// before the file is held or read for showing: a torn one is cut back,
/// a finished one's journal cleared. Said once, on the terminal.
pub fn repairAt(s: *Session, path: []const u8) void {
    const lib = s.library orelse return;
    const io = s.io orelse return;
    const was = (lib.appending(path) catch return) orelse return;
    s.gpa.free(was.bytes);
    const bytes = s.ctx.readFileWith(s.gpa, path) catch return;
    defer s.gpa.free(bytes);
    const verdict = (save.repair(s.gpa, io, lib, path, path, bytes) catch |err| {
        s.ctx.note("{s}: the last save did not finish, and could not be put right ({t})", .{ path, err });
        return;
    }) orelse return;
    switch (verdict) {
        .finished => s.ctx.note("{s}: the last save had finished; its journal is cleared", .{path}),
        .torn => s.ctx.note("{s}: the last save was cut short; it is cut back, and goes in again at the next", .{path}),
        .foreign => s.ctx.note("{s}: changed since the last save began; that save is forgotten, and its marks stay in the library", .{path}),
    }
}

fn now(s: *const Session) i64 {
    const io = s.io orelse return 0;
    return library.now(io);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");

/// One blank page with a cross-reference table the writer can take.
fn blankPdf(gpa: Allocator) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    const objects = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] >>",
    };
    try w.writeAll("%PDF-1.7\n");
    var offsets: [objects.len]usize = undefined;
    for (objects, 0..) |obj, i| {
        offsets[i] = out.written().len;
        try w.print("{d} 0 obj\n{s}\nendobj\n", .{ i + 1, obj });
    }
    const at = out.written().len;
    try w.print("xref\n0 {d}\n0000000000 65535 f\r\n", .{objects.len + 1});
    for (offsets) |o| try w.print("{d:0>10} 00000 n\r\n", .{o});
    try w.print("trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ objects.len + 1, at });
    return out.toOwnedSlice();
}

/// A session on a real file in `dir`, with a library, as `openBuffer`
/// leaves one: its document on the heap, its stamp held.
const OnFile = struct {
    s: Session,
    lib: Library,
    path: []u8,

    fn open(gpa: Allocator, dir: Io.Dir) !OnFile {
        const io = testing.io;
        const bytes = try blankPdf(gpa);
        defer gpa.free(bytes);
        try dir.writeFile(io, .{ .sub_path = "a.pdf", .data = bytes });
        // Copied, and freed as the sentinel slice it is.
        const real = try dir.realPathFileAlloc(io, "a.pdf", gpa);
        defer gpa.free(real);
        const path = try gpa.dupe(u8, real);
        errdefer gpa.free(path);

        const doc = try gpa.create(Document);
        doc.* = try fenrir.open(gpa, try gpa.dupe(u8, bytes));
        var s = try fixtures.sessionOf(gpa, @constCast(try fenrir.pages.all(doc)), 1, 600, 900);
        const b = s.buffer(0);
        b.doc = doc;
        gpa.free(b.path);
        b.path = try gpa.dupe(u8, path);
        s.io = io;
        s.disk(0).held = watch.stat(io, path).?;
        const lib = try Library.open(gpa, ":memory:");
        try fixtures.giveLibrary(&s, lib);
        return .{ .s = s, .lib = lib, .path = path };
    }

    fn close(f: *OnFile) void {
        const gpa = f.s.gpa;
        const doc = f.s.buffer(0).doc;
        if (f.s.saving) |*w| w.arena.deinit();
        // Taken again when a save came back, as the reader does.
        if (f.s.disk(0).hold) |*h| h.release(testing.io);
        f.s.disk(0).hold = null;
        doc.deinit();
        gpa.destroy(doc);
        fixtures.closeSession(&f.s);
        f.lib.close();
        gpa.free(f.path);
    }

    fn fileLen(f: *OnFile) !usize {
        const bytes = try Io.Dir.cwd().readFileAlloc(testing.io, f.path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(bytes);
        return bytes.len;
    }
};

test ":w writes the journal into the file, and the reader holds the file without reading it again" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try OnFile.open(gpa, tmp.dir);
    defer f.close();
    const s = &f.s;
    const b = s.buffer(0);

    const anchor = marks.markBoxes(s, 0, &.{.{ .page = 0, .box = .fromRect(100, 700, 300, 712) }}, s.accent, .highlight);
    marks.applyEffects(s);
    try testing.expect(try f.lib.journaled(b.path));

    try testing.expect(s.exec("w"));
    try testing.expectEqual(watch.Disk.Save.wanted, s.disk(0).save);
    // Posted, and nothing else asked of the worker until it is back.
    try testing.expectEqual(render.Job.Want.save, @import("reload.zig").jobToPost(s).?.want);
    try testing.expectEqual(watch.Disk.Save.posted, s.disk(0).save);
    try testing.expectEqual(render.Job.Want.save, @import("reload.zig").jobToPost(s).?.want);

    const before = b.doc.bytes.len;
    install(s, 0, produce(s, 0));
    try testing.expectEqual(watch.Disk.Save.none, s.disk(0).save);
    try testing.expect(s.saving == null);
    try testing.expect(std.mem.indexOf(u8, s.status, "written") != null);

    // The held document is the file now, adopted rather than read; the
    // stamp is the file's, so the next look finds nothing to do.
    try testing.expect(b.doc.bytes.len > before);
    try testing.expectEqual(b.doc.bytes.len, try f.fileLen());
    try testing.expect(s.disk(0).held.eql(watch.stat(testing.io, f.path).?));
    try testing.expectEqual(watch.Disk.Reload.none, s.disk(0).reload);

    // The journal is empty, and the mark is one of the file's.
    try testing.expect(!try f.lib.journaled(b.path));
    try testing.expect(!b.marks.items()[0].saved());
    try testing.expect(s.disk(0).taken.contains(anchor));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const got = try fenrir.annots.read(arena.allocator(), b.doc, b.pages[0]);
    try testing.expectEqual(@as(usize, 1), got.len);
    var name: [Library.name_len]u8 = undefined;
    try testing.expectEqualStrings(Library.makeName(&name, anchor), got[0].name);

    // A second :w has nothing to write, and leaves the file alone.
    const len = try f.fileLen();
    try testing.expect(s.exec("w"));
    try testing.expectEqual(watch.Disk.Save.none, s.disk(0).save);
    try testing.expectEqual(len, try f.fileLen());
}

test "a save that finds the file changed writes nothing, and asks for it to be read first" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try OnFile.open(gpa, tmp.dir);
    defer f.close();
    const s = &f.s;

    _ = marks.markBoxes(s, 0, &.{.{ .page = 0, .box = .fromRect(100, 700, 300, 712) }}, s.accent, .highlight);
    marks.applyEffects(s);
    try testing.expect(s.exec("w"));
    _ = @import("reload.zig").jobToPost(s);

    // Another program's save, between the reader's read and its write.
    const theirs = try blankPdf(gpa);
    defer gpa.free(theirs);
    const longer = try std.mem.concat(gpa, u8, &.{ theirs, "%% theirs\n" });
    defer gpa.free(longer);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.pdf", .data = longer });

    install(s, 0, produce(s, 0));
    try testing.expectEqual(longer.len, try f.fileLen());
    try testing.expectEqual(watch.Disk.Reload.auto, s.disk(0).reload);
    try testing.expect(s.disk(0).resave);
    // The journal waits for the save made after the reload.
    try testing.expect(try f.lib.journaled(s.buffer(0).path));
}

test "a document whose marks are kept in the library is never written" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try OnFile.open(gpa, tmp.dir);
    defer f.close();
    const s = &f.s;

    _ = marks.markBoxes(s, 0, &.{.{ .page = 0, .box = .fromRect(100, 700, 300, 712) }}, s.accent, .highlight);
    marks.applyEffects(s);
    try testing.expect(s.exec("set store=library"));
    try testing.expect(!s.exec("set store=elsewhere"));
    try testing.expect(s.exec("w"));
    try testing.expectEqual(watch.Disk.Save.none, s.disk(0).save);
    try testing.expect(std.mem.indexOf(u8, s.status, "library") != null);

    // A document's own choice is over the setting, either way.
    s.store = .library;
    try f.lib.setStore(s.buffer(0).path, "pdf");
    try testing.expectEqual(Store.pdf, storeFor(s, 0));
}
