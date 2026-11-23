//! A document's journal written into its file: one incremental update that
//! leaves the file holding what the library holds for it.
//!
//! What `fenrir marks F --store pdf` does, and what the reader does on `:w`
//! and on closing a document. The library's rows are the reader's changes
//! since the file was last written (`Library`, "The journal"); `planOf`
//! reads them into a `Plan`, `update` makes the bytes that put the plan in
//! the file, and `append` writes them on its end. The library layer opens
//! no files, so the last of the three is here.
//!
//! ## By name, in place
//!
//! An anchor the file already has is written over -- the same object, the
//! same number -- so its replies' `/IRT` and its page's `/Annots` still
//! name it, and a save costs the annotation and nothing around it. It is
//! found by `/NM`: fenrir's names are the document's, another program's are
//! its page's (§12.5.2), and one that came with no usable name is found by
//! what it looks like (`annots.shapeOf`) and is given the name the library
//! gave it, which is the one time the file is told it.
//!
//! What a plan does not mention is not touched. A comment the reader never
//! changed stays the file's, bytes and all, even on an anchor that is
//! written again; a deleted anchor takes the replies to it out with it.
//!
//! ## A torn append
//!
//! The library records what is about to be appended before it is (`Record`):
//! the length it goes on at, a hash of the bytes before it, and the bytes.
//! A record still there at the next open means the writer died appending,
//! and `judge` says which way: the whole update is there, the end of it is
//! missing, or the tail is somebody else's. A length alone proves none of
//! them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const annots = fenrir.annots;
const Document = fenrir.Document;
const Library = fenrir.mimir.Library;
const Writer = fenrir.Writer;
const Bounds = fenrir.gelgja.Bounds;
const Color = fenrir.gelgja.Color;
const Point = fenrir.gelgja.Point;
const Object = fenrir.Object;
const Ref = fenrir.Ref;

/// How wide a stroke stored with no width is drawn: the reader's pen.
pub const default_pen_width: f32 = 1.6;

/// How something the plan names is found in the file.
pub const Where = struct {
    /// What `/NM` holds, or will hold once this save has written it.
    name: []const u8,
    /// The page it is on, which only another program's name needs.
    page: u32 = 0,
    /// Another program's name: its page's and no other's.
    paged: bool = false,
    /// For one the file holds with no usable name: how it looks there.
    shape: ?u64 = null,
};

/// An anchor's lines on one page, which are one annotation.
pub const Piece = struct {
    page: u32,
    lines: []const Bounds = &.{},
    paths: []const []const Point = &.{},
    /// Where the words of an arrow's first line begin; see `annots.Written`.
    start: ?f32 = null,
};

/// An anchor as the library holds it.
pub const Anchor = struct {
    where: Where,
    kind: annots.Kind,
    color: ?Color = null,
    width: f32 = 0,
    /// The first comment on it, which is its `/Contents`; null keeps what
    /// the file says, and empty says nothing.
    note: ?[]const u8 = null,
    pieces: []const Piece,
};

/// A comment that is not its anchor's first: a reply to the anchor's
/// annotation, on the page it begins on.
pub const Reply = struct {
    where: Where,
    anchor: Where,
    text: []const u8,
};

/// The note on an anchor whose lines are the file's: the file's
/// annotation with its `/Contents` said again.
pub const Note = struct {
    where: Where,
    text: []const u8,
};

/// Something deleted that the file holds. An anchor takes its replies with
/// it; a comment that turns out to be an anchor's first is its note,
/// cleared, and the anchor stays.
pub const Drop = struct {
    where: Where,
    anchor: bool,
};

pub const Plan = struct {
    anchors: []const Anchor = &.{},
    notes: []const Note = &.{},
    replies: []const Reply = &.{},
    drops: []const Drop = &.{},
    /// `/T`, and `/M` in seconds since 1970, on everything written.
    author: []const u8 = "",
    when: i64 = 0,

    pub fn isEmpty(p: Plan) bool {
        return p.anchors.len == 0 and p.notes.len == 0 and p.replies.len == 0 and p.drops.len == 0;
    }
};

// -- the plan ---------------------------------------------------------------

/// The journal of `path` as a plan, in `a`.
///
/// Rows win over a deletion of the same name, as they do on open: an
/// undone deletion leaves both.
pub fn planOf(a: Allocator, lib: Library, path: []const u8) Library.Error!Plan {
    const rows = try lib.marks(path);
    defer lib.freeMarks(rows, rows.len);
    const ink = try lib.strokes(path);
    defer lib.freeStrokes(ink, ink.len);
    const said = try lib.comments(path);
    defer lib.freeComments(said, said.len);
    const gone = try lib.gones(path);
    defer lib.freeGones(gone, gone.len);
    const named = try lib.namings(path);
    defer lib.freeNamings(named, named.len);

    var made: std.StringArrayHashMapUnmanaged(Building) = .empty;
    for (rows) |r| {
        const b = try building(a, &made, r.anchor, kindOf(r.style), r.page, named);
        if (b.color == null) b.color = Library.parseColor(r.color);
        try (try b.lines(a, r.page)).append(a, .fromRect(r.x0, r.y0, r.x1, r.y1));
    }
    for (ink) |k| {
        const b = try building(a, &made, k.anchor, .ink, k.page, named);
        if (b.color == null) b.color = Library.parseColor(k.color);
        b.width = if (k.width > 0) k.width else default_pen_width;
        const path_points = try a.dupe(Point, k.points);
        try (try b.paths(a, k.page)).append(a, path_points);
    }

    var notes: std.ArrayList(Note) = .empty;
    var replies: std.ArrayList(Reply) = .empty;
    var drops: std.ArrayList(Drop) = .empty;
    for (said) |c| {
        const text = try a.dupe(u8, c.text);
        if (!std.mem.eql(u8, c.nm, c.anchor)) {
            try replies.append(a, .{
                .where = try whereOf(a, c.nm, c.page, named),
                .anchor = try whereOf(a, c.anchor, c.page, named),
                .text = text,
            });
        } else if (made.getPtr(c.anchor)) |b| {
            b.note = text;
        } else try notes.append(a, .{ .where = try whereOf(a, c.anchor, c.page, named), .text = text });
    }
    for (gone) |g| {
        if (g.comment) {
            const back = for (said) |c| {
                if (std.mem.eql(u8, c.nm, g.nm)) break true;
            } else false;
            if (back) continue;
            // The note on an anchor whose lines the library holds is said
            // with them; anything else is the file's to find.
            if (made.getPtr(g.nm)) |b| {
                if (b.note == null) b.note = "";
                continue;
            }
        } else if (made.contains(g.nm)) continue;
        try drops.append(a, .{ .where = try whereOf(a, g.nm, g.page, named), .anchor = !g.comment });
    }

    const anchors = try a.alloc(Anchor, made.count());
    for (made.values(), anchors) |*b, *out| out.* = try b.finish(a);
    return .{ .anchors = anchors, .notes = notes.items, .replies = replies.items, .drops = drops.items };
}

/// An anchor being gathered out of its rows.
const Building = struct {
    where: Where,
    kind: annots.Kind,
    color: ?Color = null,
    width: f32 = 0,
    note: ?[]const u8 = null,
    pages: std.AutoArrayHashMapUnmanaged(u32, Gathered) = .empty,

    const Gathered = struct {
        lines: std.ArrayList(Bounds) = .empty,
        paths: std.ArrayList([]const Point) = .empty,
    };

    fn lines(b: *Building, a: Allocator, page: u32) Allocator.Error!*std.ArrayList(Bounds) {
        return &(try b.pages.getOrPutValue(a, page, .{})).value_ptr.lines;
    }

    fn paths(b: *Building, a: Allocator, page: u32) Allocator.Error!*std.ArrayList([]const Point) {
        return &(try b.pages.getOrPutValue(a, page, .{})).value_ptr.paths;
    }

    fn finish(b: *Building, a: Allocator) Allocator.Error!Anchor {
        const Order = struct {
            fn page(_: void, x: u32, y: u32) bool {
                return x < y;
            }
            // Down the page, then along it: the order a reader reads the
            // lines in, which is the order another reader lists them.
            fn line(_: void, x: Bounds, y: Bounds) bool {
                return x.max_y > y.max_y or (x.max_y == y.max_y and x.min_x < y.min_x);
            }
        };
        const keys = try a.dupe(u32, b.pages.keys());
        std.mem.sort(u32, keys, {}, Order.page);
        const pieces = try a.alloc(Piece, keys.len);
        for (keys, pieces) |page, *p| {
            const g = b.pages.getPtr(page).?;
            std.mem.sort(Bounds, g.lines.items, {}, Order.line);
            p.* = .{ .page = page, .lines = g.lines.items, .paths = g.paths.items };
        }
        b.where.page = keys[0];
        return .{ .where = b.where, .kind = b.kind, .color = b.color, .width = b.width, .note = b.note, .pieces = pieces };
    }
};

fn building(
    a: Allocator,
    made: *std.StringArrayHashMapUnmanaged(Building),
    anchor: []const u8,
    kind: annots.Kind,
    page: u32,
    named: []const Library.Naming,
) Allocator.Error!*Building {
    const got = try made.getOrPut(a, anchor);
    if (!got.found_existing) {
        got.key_ptr.* = try a.dupe(u8, anchor);
        got.value_ptr.* = .{ .where = try whereOf(a, anchor, page, named), .kind = kind };
    }
    return got.value_ptr;
}

/// How the file holds a name: fenrir's anywhere, another program's on its
/// page, and one given to an annotation that had none by its shape there.
fn whereOf(a: Allocator, nm: []const u8, page: u32, named: []const Library.Naming) Allocator.Error!Where {
    for (named) |n| {
        if (std.mem.eql(u8, n.nm, nm)) return .{ .name = try a.dupe(u8, nm), .page = n.page, .shape = n.shape };
    }
    return .{ .name = try a.dupe(u8, nm), .page = page, .paged = Library.nameNumber(nm) == null };
}

fn kindOf(style: []const u8) annots.Kind {
    return std.meta.stringToEnum(annots.Kind, style) orelse .highlight;
}


// -- the update -------------------------------------------------------------

pub const Error = annots.WriteError || error{
    /// A certification signature forbids it (DocMDP, P 1 or 2).
    Certified,
};

/// The bytes that put `plan` into `doc`, to be appended to `doc.bytes`.
/// Empty when there is nothing to write. `seed` goes into a new `/ID`.
pub fn update(gpa: Allocator, doc: *Document, plan: Plan, seed: []const u8) Error![]u8 {
    var w = try Writer.init(gpa, doc);
    defer w.deinit();
    // P 3 permits annotations, which is all this writes.
    if (try Writer.certified(doc)) |p| {
        if (p < 3) return error.Certified;
    }
    const a = w.allocator();
    const list = try fenrir.pages.all(doc);

    var file: Index = .{ .entries = try indexOf(a, doc, list) };
    var ap: annots.Appearances = .{};
    defer ap.deinit(gpa);
    // The shared forms a fenrir save left, from the pages that hold one of
    // its annotations: no other program's form is ever adopted anyway.
    var adopted: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (file.entries) |e| {
        if (Library.nameNumber(e.annot.name) == null) continue;
        if ((try adopted.getOrPut(a, e.page)).found_existing) continue;
        try ap.adopt(gpa, doc, list[e.page]);
    }

    var edits: Edits = .{};
    // What each anchor written here begins with, for its replies.
    var targets: std.StringHashMapUnmanaged(Target) = .empty;

    for (plan.anchors) |an| {
        var found = try file.find(a, an.where);
        var first: ?Target = null;
        for (an.pieces, 0..) |piece, i| {
            if (piece.page >= list.len) continue;
            const into = takeOn(&found, piece.page);
            // The note goes on the first page's; the file's is kept when
            // the plan does not say.
            const note: []const u8 = if (i != 0) "" else an.note orelse if (into) |e| e.annot.text else "";
            const ref = try annots.write(&w, &ap, list[piece.page], .{
                .kind = an.kind,
                .name = an.where.name,
                .lines = piece.lines,
                .paths = piece.paths,
                .color = an.color,
                .width = an.width,
                .text = note,
            }, .{ .author = plan.author, .when = plan.when, .into = if (into) |e| e.ref else null, .start = piece.start });
            try edits.wrote(a, ref);
            if (into == null) try edits.add(a, piece.page, ref);
            if (first == null) first = .{ .ref = ref, .page = piece.page, .at = firstLine(piece), .color = an.color };
        }
        // What the file had on pages the anchor has left.
        for (found.items) |e| try dropWithReplies(a, &edits, &file, e);
        if (first) |t| try targets.put(a, an.where.name, t);
    }

    for (plan.notes) |n| {
        const found = try file.find(a, n.where);
        for (found.items) |e| try rewriteNote(a, &w, &edits, e, n.where, n.text, plan);
    }

    for (plan.replies) |r| {
        const target = targets.get(r.anchor.name) orelse blk: {
            const found = try file.find(a, r.anchor);
            if (found.items.len == 0) break :blk null;
            const e = found.items[0];
            break :blk Target{ .ref = e.ref, .page = e.page, .at = boundsOf(e.annot), .color = e.annot.color };
        } orelse continue;
        var found = try file.find(a, r.where);
        const into = takeOn(&found, target.page);
        const ref = try annots.write(&w, &ap, list[target.page], .{
            .kind = .reply,
            .name = r.where.name,
            .lines = &.{target.at},
            .color = target.color,
            .text = r.text,
        }, .{ .author = plan.author, .when = plan.when, .answers = target.ref, .into = if (into) |e| e.ref else null });
        try edits.wrote(a, ref);
        if (into == null) try edits.add(a, target.page, ref);
        // A reply the anchor's first page has left behind on another.
        for (found.items) |e| try edits.drop(a, e.page, e.ref);
    }

    for (plan.drops) |d| {
        const found = try file.find(a, d.where);
        for (found.items) |e| {
            if (d.anchor or e.annot.kind == .reply) {
                try dropWithReplies(a, &edits, &file, e);
            } else try rewriteNote(a, &w, &edits, e, d.where, "", plan);
        }
    }

    for (edits.pages.keys(), edits.pages.values()) |page, *e| {
        try annots.attach(&w, list[page], e.add.items, e.drop.items);
        for (e.drop.items) |ref| {
            if (!edits.written.contains(ref.num)) try w.free(ref.num);
        }
    }
    return w.finish(.{ .seed = seed });
}

/// What a reply answers: the anchor's annotation on its first page, and
/// where on it the reply's icon goes.
const Target = struct { ref: Ref, page: u32, at: Bounds, color: ?Color };

fn firstLine(p: Piece) Bounds {
    if (p.lines.len != 0) return p.lines[0];
    var box: Bounds = .empty;
    for (p.paths) |path| {
        for (path) |pt| box = box.add(pt);
    }
    return box;
}

fn boundsOf(x: annots.Annot) Bounds {
    return firstLine(.{ .page = 0, .lines = x.lines, .paths = x.paths });
}

/// The file's annotation with only its note said again, and its name when
/// the library gave it one: everything else is the file's, copied as it is.
fn rewriteNote(a: Allocator, w: *Writer, edits: *Edits, e: Entry, where: Where, text: []const u8, plan: Plan) Error!void {
    if (edits.written.contains(e.ref.num)) return;
    const was = (try w.doc.fetch(e.ref)).asDict() orelse return;
    var d = try was.clone(a);
    if (where.shape != null) try d.put(a, "NM", .{ .string = where.name });
    if (text.len == 0) {
        _ = d.orderedRemove("Contents");
    } else try d.put(a, "Contents", .{ .string = try fenrir.outline.encode(a, text) });
    if (plan.when != 0) try d.put(a, "M", .{ .string = try annots.dateOf(a, plan.when) });
    try w.put(e.ref.num, .{ .dict = d });
    try edits.wrote(a, e.ref);
}

fn dropWithReplies(a: Allocator, edits: *Edits, file: *const Index, e: Entry) Allocator.Error!void {
    try edits.drop(a, e.page, e.ref);
    for (file.entries) |r| {
        if (r.answers) |to| {
            if (to.num == e.ref.num) try edits.drop(a, r.page, r.ref);
        }
    }
}

fn takeOn(found: *std.ArrayList(Entry), page: u32) ?Entry {
    for (found.items, 0..) |e, i| {
        if (e.page == page) return found.orderedRemove(i);
    }
    return null;
}

/// What the save changes on each page's `/Annots`, and what it has written,
/// which is never then freed.
const Edits = struct {
    pages: std.AutoArrayHashMapUnmanaged(u32, Page) = .empty,
    written: std.AutoHashMapUnmanaged(u32, void) = .empty,

    const Page = struct {
        add: std.ArrayList(Ref) = .empty,
        drop: std.ArrayList(Ref) = .empty,
    };

    fn add(e: *Edits, a: Allocator, page: u32, ref: Ref) Allocator.Error!void {
        try (try e.pages.getOrPutValue(a, page, .{})).value_ptr.add.append(a, ref);
    }

    fn drop(e: *Edits, a: Allocator, page: u32, ref: Ref) Allocator.Error!void {
        if (e.written.contains(ref.num)) return;
        const p = (try e.pages.getOrPutValue(a, page, .{})).value_ptr;
        for (p.drop.items) |r| {
            if (r.num == ref.num) return;
        }
        try p.drop.append(a, ref);
    }

    fn wrote(e: *Edits, a: Allocator, ref: Ref) Allocator.Error!void {
        try e.written.put(a, ref.num, {});
    }
};

/// One of the file's annotations the reader takes, and where it is.
const Entry = struct {
    page: u32,
    ref: Ref,
    annot: annots.Annot,
    /// Its name is the only one its page gives.
    unique: bool,
    /// For a reply, the annotation its thread begins at.
    answers: ?Ref,
};

const Index = struct {
    entries: []const Entry,

    /// Everything `where` names: by shape first, for one the library named,
    /// and by name when that finds nothing -- the file has the name already
    /// when the save that wrote it did not live to clear the journal.
    fn find(ix: Index, a: Allocator, where: Where) Allocator.Error!std.ArrayList(Entry) {
        var out: std.ArrayList(Entry) = .empty;
        if (where.shape) |shape| {
            for (ix.entries) |e| {
                if (e.page != where.page or (e.unique and e.annot.name.len != 0)) continue;
                if (annots.shapeOf(e.annot) == shape) try out.append(a, e);
            }
            if (out.items.len != 0) return out;
        }
        for (ix.entries) |e| {
            if (!e.unique or !std.mem.eql(u8, e.annot.name, where.name)) continue;
            if (where.paged and e.page != where.page) continue;
            try out.append(a, e);
        }
        return out;
    }
};

fn indexOf(a: Allocator, doc: *Document, list: []const fenrir.Page) Document.Error![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (list, 0..) |p, page| {
        const read = try annots.read(a, doc, p);
        for (read) |x| {
            const ref = x.ref orelse continue;
            var seen: usize = 0;
            for (read) |y| seen += @intFromBool(x.name.len != 0 and std.mem.eql(u8, x.name, y.name));
            const answers: ?Ref = if (x.thread) |t| read[t].ref else null;
            try out.append(a, .{ .page = @intCast(page), .ref = ref, .annot = x, .unique = seen == 1, .answers = answers });
        }
    }
    return out.items;
}

// -- the file ---------------------------------------------------------------

pub const AppendError = Io.File.OpenError || Io.File.WritePositionalError || Io.File.SyncError;

/// Writes `bytes` into the file at `at`, its length as it was read, and
/// makes sure they reached the disk. A failure part of the way is cut
/// back where it can be; where it cannot, the record `judge` reads is
/// what puts it right.
pub fn append(io: Io, path: []const u8, at: u64, bytes: []const u8) AppendError!void {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only });
    defer file.close(io);
    errdefer file.setLength(io, at) catch {};
    try file.writePositionalAll(io, bytes, at);
    try file.sync(io);
}

/// How much of the bytes before an update its record hashes: enough that a
/// different file of the same length is not taken for this one.
pub const tail_len = 4096;

pub fn tailHash(held: []const u8) u64 {
    return std.hash.Wyhash.hash(0, held[held.len -| tail_len ..]);
}

/// What the library keeps while an update is being appended.
pub const Record = struct {
    /// The file's length before it.
    held: u64,
    /// `tailHash` of the bytes before it.
    tail: u64,
    /// The update itself.
    update: []const u8,
};

pub const Verdict = enum {
    /// The whole update is there: nothing to put right.
    finished,
    /// Part of it, or none: cut back to `held` and save again.
    torn,
    /// The bytes are not the ones it went on, or what follows is not it.
    foreign,
};

/// What a record left behind says of the file as it is now.
pub fn judge(file: []const u8, r: Record) Verdict {
    if (file.len < r.held or tailHash(file[0..@intCast(r.held)]) != r.tail) return .foreign;
    const after = file[@intCast(r.held)..];
    if (after.len > r.update.len) return .foreign;
    if (!std.mem.eql(u8, after, r.update[0..after.len])) return .foreign;
    return if (after.len == r.update.len) .finished else .torn;
}

/// Cuts a torn append off.
pub fn cut(io: Io, path: []const u8, at: u64) (Io.File.OpenError || Io.File.SetLengthError || Io.File.SyncError)!void {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only });
    defer file.close(io);
    try file.setLength(io, at);
    try file.sync(io);
}

// -- one save, start to end ------------------------------------------------

/// Which way a save moves a document's marks, which decides what of the
/// journal it leaves once it is in.
pub const Way = enum {
    /// Into the file: the rows are the file's now, and go.
    in,
    /// Out of it (`takeOut`): the rows are the marks now, and stay; what
    /// the journal said about the file's annotations goes.
    out,
};

/// Makes, records and appends one save of `plan` onto the file at `path`,
/// whose bytes as they are now `doc` was opened from, and settles `key`'s
/// journal the `way` it went once the update is in. Returns the update,
/// which the caller owns and which is empty when there was nothing to write.
///
/// A failure keeps the journal, and the record too: the next open judges
/// what reached the file.
pub fn write(gpa: Allocator, io: Io, lib: Library, key: []const u8, path: []const u8, doc: *Document, plan: Plan, seed: []const u8, way: Way) ![]u8 {
    const bytes = try update(gpa, doc, plan, seed);
    errdefer gpa.free(bytes);
    if (bytes.len == 0) return bytes;
    try lib.recordAppend(key, .{ .held = doc.bytes.len, .tail = tailHash(doc.bytes), .bytes = bytes, .out = way == .out });
    try append(io, path, doc.bytes.len, bytes);
    try settle(lib, key, way);
    return bytes;
}

fn settle(lib: Library, key: []const u8, way: Way) Library.Error!void {
    switch (way) {
        .in => try lib.clearJournal(key),
        .out => try lib.forgetFile(key),
    }
}

/// Puts right what a save that did not finish left, given the file's bytes
/// as they are now: null when no save was on its way. A finished one has
/// its journal cleared, being in the file; a torn one is cut back, and its
/// journal kept for the next save; another program's tail is left alone.
pub fn repair(gpa: Allocator, io: Io, lib: Library, key: []const u8, path: []const u8, file: []const u8) !?Verdict {
    const r = (try lib.appending(key)) orelse return null;
    defer gpa.free(r.bytes);
    const verdict = judge(file, .{ .held = r.held, .tail = r.tail, .update = r.bytes });
    switch (verdict) {
        .finished => try settle(lib, key, if (r.out) .out else .in),
        .torn => {
            if (file.len != r.held) try cut(io, path, r.held);
            try lib.clearAppend(key);
        },
        .foreign => try lib.clearAppend(key),
    }
    return verdict;
}

/// Why a save did not go in, as the status line and `fenrir marks` say it.
pub fn whyNot(err: anyerror) []const u8 {
    return switch (err) {
        error.Encrypted => "the file is encrypted",
        error.Recovered => "its cross-reference table had to be rebuilt",
        error.Certified => "a certification signature forbids changes",
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => "it is read-only, or another program holds it",
        error.FileBusy, error.DeviceBusy, error.WouldBlock => "another program holds it",
        error.NoSpaceLeft, error.DiskQuota => "the disk is full",
        error.FileNotFound => "it is not there any more",
        else => @errorName(err),
    };
}

// -- out of the file --------------------------------------------------------

/// What `takeOut` moved.
pub const TakenOut = struct {
    /// The update that drops them from the file.
    plan: Plan,
    anchors: usize = 0,
    comments: usize = 0,
};

/// The marks `doc` holds put into the library under `key` as rows of the
/// reader's own, and the plan of an update that drops them from the file:
/// `fenrir marks --store library`. What the journal holds already wins,
/// as it does in the reader: an anchor or a comment with rows keeps them,
/// and one the reader deleted is dropped and not copied.
///
/// **Rows first, the update after.** A file that will not take the update
/// still has the marks, and the library has them under the same names, so
/// the next open shows each once. One that came with no usable name is
/// named here and noted by its shape (`nameAnnotation`), for that same
/// reason; the notes go once the update is in (`Way.out`).
///
/// A markup with no line the reader could read, or ink with no path, is
/// left in the file: dropped, it would be gone from both.
pub fn takeOut(a: Allocator, lib: Library, key: []const u8, doc: *Document, now: i64) !TakenOut {
    const list = try fenrir.pages.all(doc);

    var held: std.StringHashMapUnmanaged(void) = .empty;
    var said: std.StringHashMapUnmanaged(void) = .empty;
    var gone: std.StringHashMapUnmanaged(void) = .empty;
    var unsaid: std.StringHashMapUnmanaged(void) = .empty;
    {
        const rows = try lib.marks(key);
        defer lib.freeMarks(rows, rows.len);
        for (rows) |r| try held.put(a, try a.dupe(u8, r.anchor), {});
        const ink = try lib.strokes(key);
        defer lib.freeStrokes(ink, ink.len);
        for (ink) |k| try held.put(a, try a.dupe(u8, k.anchor), {});
        const comments = try lib.comments(key);
        defer lib.freeComments(comments, comments.len);
        for (comments) |c| try said.put(a, try a.dupe(u8, c.nm), {});
        const deleted = try lib.gones(key);
        defer lib.freeGones(deleted, deleted.len);
        for (deleted) |g| try (if (g.comment) &unsaid else &gone).put(a, try a.dupe(u8, g.nm), {});
    }

    var drops: std.ArrayList(Drop) = .empty;
    var out: TakenOut = .{ .plan = .{} };
    for (list, 0..) |p, at| {
        const page: u32 = @intCast(at);
        const read = try annots.read(a, doc, p);
        if (read.len == 0) continue;
        const names = try a.alloc([]const u8, read.len);
        for (read, names) |x, *name| {
            if (unique(read, x.name)) {
                name.* = x.name;
            } else {
                var buf: [Library.name_len]u8 = undefined;
                const n = try lib.highestName(key) + 1;
                try lib.noteName(key, n);
                name.* = try a.dupe(u8, Library.makeName(&buf, n));
                try lib.nameAnnotation(key, page, annots.shapeOf(x), name.*);
            }
        }

        for (read, names) |x, name| {
            if (x.kind == .reply) continue;
            if (x.kind == .ink and x.paths.len == 0) continue;
            if (x.kind != .ink and x.lines.len == 0) continue;
            const where: Where = if (unique(read, x.name))
                .{ .name = name, .page = page, .paged = Library.nameNumber(name) == null }
            else
                .{ .name = name, .page = page, .shape = annots.shapeOf(x) };
            // Its replies go with it, in the file and out of it.
            try drops.append(a, .{ .where = where, .anchor = true });
            if (gone.contains(name)) continue;

            if (!held.contains(name)) {
                var hex: [7]u8 = undefined;
                const color: []u8 = if (x.color) |c| @constCast(hexOf(c, &hex)) else &.{};
                if (x.kind == .ink) {
                    for (x.paths) |path| {
                        if (path.len < 2) continue;
                        _ = try lib.addStroke(key, .{
                            .page = page,
                            .color = color,
                            .width = x.width,
                            .points = @constCast(path),
                            .anchor = @constCast(name),
                        }, now);
                    }
                } else for (x.lines) |box| {
                    _ = try lib.addMark(key, .{
                        .page = page,
                        .x0 = box.min_x,
                        .y0 = box.min_y,
                        .x1 = box.max_x,
                        .y1 = box.max_y,
                        .color = color,
                        .style = @constCast(@tagName(x.kind)),
                        .anchor = @constCast(name),
                    }, now);
                }
                out.anchors += 1;
            }
            if (x.text.len != 0 and !said.contains(name) and !unsaid.contains(name)) {
                _ = try lib.addComment(key, .{ .anchor = @constCast(name), .nm = @constCast(name), .page = page, .text = @constCast(x.text) }, now);
                out.comments += 1;
            }
        }

        for (read, names) |x, name| {
            if (x.kind != .reply or x.text.len == 0) continue;
            const thread = x.thread orelse continue;
            if (gone.contains(names[thread]) or said.contains(name) or unsaid.contains(name)) continue;
            _ = try lib.addComment(key, .{ .anchor = @constCast(names[thread]), .nm = @constCast(name), .page = page, .text = @constCast(x.text) }, now);
            out.comments += 1;
        }
    }
    out.plan = .{ .drops = drops.items };
    return out;
}

/// Whether `name` names one annotation on its page and no other.
fn unique(read: []const annots.Annot, name: []const u8) bool {
    if (name.len == 0) return false;
    var seen: usize = 0;
    for (read) |y| seen += @intFromBool(std.mem.eql(u8, name, y.name));
    return seen == 1;
}

fn hexOf(c: Color, buf: *[7]u8) []const u8 {
    const byte = struct {
        fn of(v: f32) u8 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }
    }.of;
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ byte(c.r), byte(c.g), byte(c.b) }) catch unreachable;
}

// -- what each save cost ----------------------------------------------------

/// Each revision of a file, its size and what is in it: `fenrir marks F
/// --bytes`, which is the check on what a save costs.
///
/// A revision ends at each `%%EOF`. What is in one is what its
/// cross-reference data says moved: the tables of the file up to its end
/// and up to the last one's are read, and the objects whose entries differ
/// are counted by what they are. One that names an annotation `f` and a
/// number is fenrir's. A prefix that does not open as a file of its own --
/// the first part of a linearized file -- is counted with the next.
pub fn describeRevisions(gpa: Allocator, bytes: []const u8, w: *Io.Writer) !void {
    var prev: ?Document = null;
    defer if (prev) |*p| p.deinit();
    var prev_end: usize = 0;
    var number: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, "%%EOF")) |i| {
        var end = i + "%%EOF".len;
        while (end < bytes.len and (bytes[end] == '\r' or bytes[end] == '\n')) end += 1;
        at = end;
        var doc = Document.openBorrowed(gpa, bytes[0..end]) catch continue;
        if (doc.recovered or doc.table.recovered) {
            doc.deinit();
            continue;
        }
        number += 1;
        if (prev) |*p| {
            try w.print("revision {d}  {d} bytes  ", .{ number, end - prev_end });
            try describeOne(gpa, p, &doc, w);
            p.deinit();
        } else try w.print("revision {d}  {d} bytes  the file as it was made\n", .{ number, end });
        prev = doc;
        prev_end = end;
    }
    if (number == 0) return error.NoRevision;
}

fn describeOne(gpa: Allocator, was: *Document, now: *Document, w: *Io.Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var kinds: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var forms: usize = 0;
    var lists: usize = 0;
    var pages: usize = 0;
    var freed: usize = 0;
    var other: usize = 0;
    var fenrirs = false;

    var it = now.table.entries.iterator();
    while (it.next()) |e| {
        const num = e.key_ptr.*;
        if (was.table.get(num)) |before| {
            if (std.meta.eql(before, e.value_ptr.*)) continue;
        }
        if (e.value_ptr.* == .free) {
            freed += 1;
            continue;
        }
        const obj = now.fetch(.{ .num = num, .gen = 0 }) catch {
            other += 1;
            continue;
        };
        switch (obj) {
            .array => lists += 1,
            .stream => |st| {
                if (st.dict.get("Subtype")) |sub| {
                    if (sub.isName("Form")) {
                        forms += 1;
                        continue;
                    }
                }
                const t = st.dict.get("Type") orelse Object.null_object;
                if (!t.isName("ObjStm") and !t.isName("XRef")) other += 1;
            },
            .dict => |d| {
                if (d.get("Type")) |t| {
                    if (t.isName("Page")) {
                        pages += 1;
                        continue;
                    }
                }
                const sub = (d.get("Subtype") orelse {
                    other += 1;
                    continue;
                }).asName() orelse {
                    other += 1;
                    continue;
                };
                if (d.get("NM")) |nm| {
                    if (Library.nameNumber(nm.asString() orelse "") != null) fenrirs = true;
                }
                const got = try kinds.getOrPut(a, sub);
                if (!got.found_existing) got.value_ptr.* = 0;
                got.value_ptr.* += 1;
            },
            else => other += 1,
        }
    }

    // Whose it is, where an annotation in it says: one that only drops
    // some, as `--store library`'s does, names nobody.
    if (kinds.count() != 0) try w.writeAll(if (fenrirs) "fenrir's: " else "another program's: ");
    var any = false;
    for (kinds.keys(), kinds.values()) |k, n| {
        try w.print("{s}{d} {s}", .{ if (any) ", " else "", n, k });
        any = true;
    }
    const tail = [_]struct { usize, []const u8 }{
        .{ forms, "form" }, .{ lists, "list" }, .{ pages, "page" }, .{ freed, "freed" }, .{ other, "other" },
    };
    for (tail) |t| {
        if (t[0] == 0) continue;
        try w.print("{s}{d} {s}", .{ if (any) ", " else "", t[0], t[1] });
        any = true;
    }
    if (!any) try w.writeAll("nothing");
    try w.writeAll("\n");
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// A one-page file with a proper cross-reference table, which the writer
/// needs and reconstruction does not give. `page_extra` goes on the page and
/// `objects` follow it from number 4.
fn fileWith(page_extra: []const u8, objects: []const []const u8) ![]u8 {
    const gpa = testing.allocator;
    const page = try std.fmt.allocPrint(gpa, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] {s} >>", .{page_extra});
    defer gpa.free(page);
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, &.{ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", page });
    try all.appendSlice(gpa, objects);

    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("%PDF-1.7\n");
    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(gpa);
    for (all.items, 1..) |obj, num| {
        try offsets.append(gpa, out.written().len);
        try w.print("{d} 0 obj\n{s}\nendobj\n", .{ num, obj });
    }
    const at = out.written().len;
    try w.print("xref\n0 {d}\n0000000000 65535 f\r\n", .{all.items.len + 1});
    for (offsets.items) |o| try w.print("{d:0>10} 00000 n\r\n", .{o});
    try w.print("trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ all.items.len + 1, at });
    return out.toOwnedSlice();
}

/// `doc` with `plan` saved onto it, opened again.
fn saved(doc: *Document, plan: Plan) !Document {
    const bytes = try update(testing.allocator, doc, plan, "test");
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len != 0);
    return Document.open(testing.allocator, try std.mem.concat(testing.allocator, u8, &.{ doc.bytes, bytes }));
}

fn annotsOf(doc: *Document, arena: Allocator) ![]const annots.Annot {
    return annots.read(arena, doc, (try fenrir.pages.all(doc))[0]);
}

const yellow: Color = .{ .r = 1, .g = 0.9, .b = 0.2 };
const blue: Color = .{ .r = 0.3, .g = 0.6, .b = 0.85 };

test "an anchor and its comments go in as one annotation and a reply, and are written over by name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.open(testing.allocator, try fileWith("", &.{}));
    defer doc.deinit();

    const lines = [_]Bounds{ .fromRect(72, 700, 300, 712), .fromRect(72, 686, 200, 698) };
    const anchor: Anchor = .{
        .where = .{ .name = "f1" },
        .kind = .highlight,
        .color = yellow,
        .note = "why",
        .pieces = &.{.{ .page = 0, .lines = &lines }},
    };
    var first = try saved(&doc, .{
        .anchors = &.{anchor},
        .replies = &.{.{ .where = .{ .name = "f2" }, .anchor = .{ .name = "f1" }, .text = "because" }},
        .author = "a reader",
    });
    defer first.deinit();
    const got = try annotsOf(&first, a);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("f1", got[0].name);
    try testing.expectEqual(@as(usize, 2), got[0].lines.len);
    try testing.expectEqualStrings("why", got[0].text);
    try testing.expectEqual(annots.Kind.reply, got[1].kind);
    try testing.expectEqual(@as(?u32, 0), got[1].thread);
    try testing.expectEqualStrings("because", got[1].text);

    // Recoloured, a line taken off, and the reply deleted: the anchor is the
    // same object, and the page lists one annotation.
    var changed = anchor;
    changed.color = blue;
    changed.note = null;
    changed.pieces = &.{.{ .page = 0, .lines = lines[0..1] }};
    var second = try saved(&first, .{
        .anchors = &.{changed},
        .drops = &.{.{ .where = .{ .name = "f2" }, .anchor = false }},
    });
    defer second.deinit();
    const after = try annotsOf(&second, a);
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expectEqual(got[0].ref.?.num, after[0].ref.?.num);
    try testing.expectEqual(@as(usize, 1), after[0].lines.len);
    // The note the plan did not mention is the file's, kept.
    try testing.expectEqualStrings("why", after[0].text);
    try testing.expect(@abs(after[0].color.?.b - blue.b) < 0.01);
}

test "another program's is found on its page, and one with no name by its shape, which is named" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.open(testing.allocator, try fileWith("/Annots [4 0 R 5 0 R 6 0 R]", &.{
        "<< /Subtype /Highlight /Rect [100 700 300 712] /NM (abc) /Contents (theirs) /QuadPoints [100 712 300 712 100 700 300 700] >>",
        "<< /Subtype /Underline /Rect [100 500 300 512] /QuadPoints [100 512 300 512 100 500 300 500] >>",
        "<< /Subtype /Text /Rect [0 0 9 9] /IRT 4 0 R /NM (r1) /Contents (a reply) >>",
    }));
    defer doc.deinit();
    const before = try annotsOf(&doc, a);
    const shape = annots.shapeOf(before[1]);

    // The note on theirs cleared, the reply said again, and the underline
    // given fenrir's name with a comment.
    var after = try saved(&doc, .{
        .notes = &.{
            .{ .where = .{ .name = "abc", .page = 0, .paged = true }, .text = "" },
            .{ .where = .{ .name = "f3", .page = 0, .shape = shape }, .text = "underlined" },
        },
        .replies = &.{.{ .where = .{ .name = "r1", .page = 0, .paged = true }, .anchor = .{ .name = "abc", .page = 0, .paged = true }, .text = "said again" }},
    });
    defer after.deinit();
    const got = try annotsOf(&after, a);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("", got[0].text);
    try testing.expectEqual(@as(u32, 4), got[0].ref.?.num);
    // Named in place by the note, its quadrilaterals untouched.
    try testing.expectEqual(@as(u32, 5), got[1].ref.?.num);
    try testing.expectEqualStrings("underlined", got[1].text);
    try testing.expectEqualStrings("said again", got[2].text);
    try testing.expectEqual(@as(?u32, 0), got[2].thread);
}

test "a deleted anchor takes its replies with it, and only them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.open(testing.allocator, try fileWith("/Annots [4 0 R 5 0 R 6 0 R]", &.{
        "<< /Subtype /Highlight /Rect [100 700 300 712] /NM (f1) /QuadPoints [100 712 300 712 100 700 300 700] >>",
        "<< /Subtype /Text /Rect [0 0 9 9] /IRT 4 0 R /NM (f2) /Contents (gone too) >>",
        "<< /Subtype /Link /Rect [0 0 9 9] >>",
    }));
    defer doc.deinit();
    var after = try saved(&doc, .{ .drops = &.{.{ .where = .{ .name = "f1" }, .anchor = true }} });
    defer after.deinit();
    try testing.expectEqual(@as(usize, 0), (try annotsOf(&after, a)).len);
    // The link is not the reader's, and stays on the page.
    const listed = try (try fenrir.pages.all(&after))[0].annotations(&after);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqual(@as(u32, 6), listed[0].asRef().?.num);
}

test "a certified file takes no annotations at P 1 or 2, and does at P 3" {
    const cert = "<< /Type /Sig /Reference [<< /TransformMethod /DocMDP /TransformParams << /P {d} >> >>] >>";
    for ([_]u8{ 1, 2, 3 }) |p| {
        const sig = try std.fmt.allocPrint(testing.allocator, cert, .{p});
        defer testing.allocator.free(sig);
        const bytes = try fileWith("", &.{ sig, "<< /Type /Catalog /Pages 2 0 R /Perms << /DocMDP 4 0 R >> >>" });
        // The catalog that names the signature is object 5; point the
        // trailer at it.
        const root = try std.mem.replaceOwned(u8, testing.allocator, bytes, "/Root 1 0 R", "/Root 5 0 R");
        testing.allocator.free(bytes);
        var doc = try Document.open(testing.allocator, root);
        defer doc.deinit();
        try testing.expectEqual(@as(?u8, p), try Writer.certified(&doc));
        const plan: Plan = .{ .anchors = &.{.{
            .where = .{ .name = "f1" },
            .kind = .highlight,
            .pieces = &.{.{ .page = 0, .lines = &.{.fromRect(1, 1, 9, 9)} }},
        }} };
        if (p < 3) {
            try testing.expectError(error.Certified, update(testing.allocator, &doc, plan, ""));
        } else {
            const out = try update(testing.allocator, &doc, plan, "");
            testing.allocator.free(out);
        }
    }
}

test "a torn append is told from a finished one and from somebody else's tail" {
    const held = "%PDF-1.7 ... %%EOF\n";
    const r: Record = .{ .held = held.len, .tail = tailHash(held), .update = "1 0 obj ... %%EOF\n" };
    try testing.expectEqual(Verdict.finished, judge(held ++ "1 0 obj ... %%EOF\n", r));
    try testing.expectEqual(Verdict.torn, judge(held ++ "1 0 obj", r));
    try testing.expectEqual(Verdict.torn, judge(held, r));
    // Something else after the same bytes, or other bytes before.
    try testing.expectEqual(Verdict.foreign, judge(held ++ "2 0 obj", r));
    try testing.expectEqual(Verdict.foreign, judge(held ++ "1 0 obj ... %%EOF\nmore", r));
    try testing.expectEqual(Verdict.foreign, judge("%PDF-1.4 ... %%EOF\n1 0 obj", r));
}

test "an update goes on the end of the file, and a torn one is cut back" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.pdf", .data = "held" });
    const path = try tmp.dir.realPathFileAlloc(io, "a.pdf", testing.allocator);
    defer testing.allocator.free(path);

    try append(io, path, 4, " and more");
    const got = try tmp.dir.readFileAlloc(io, "a.pdf", testing.allocator, .limited(64));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("held and more", got);

    try cut(io, path, 4);
    const back = try tmp.dir.readFileAlloc(io, "a.pdf", testing.allocator, .limited(64));
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("held", back);
}

test "a plan from the journal: lines by anchor and page, comments as notes or replies, deletions" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    var lib = try Library.open(testing.allocator, ":memory:");
    defer lib.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fenrir's two-line highlight with a note and a reply; a line taken off
    // another program's underline; that program's note on a third cleared;
    // and a deletion undone, which the rows win.
    _ = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 72, .y0 = 686, .x1 = 200, .y1 = 698, .color = @constCast("#4c9ed9"), .anchor = @constCast("f1") }, 1);
    _ = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 72, .y0 = 700, .x1 = 300, .y1 = 712, .color = @constCast("#4c9ed9"), .anchor = @constCast("f1") }, 1);
    _ = try lib.addComment("a.pdf", .{ .anchor = @constCast("f1"), .nm = @constCast("f1"), .text = @constCast("why") }, 1);
    _ = try lib.addComment("a.pdf", .{ .anchor = @constCast("f1"), .nm = @constCast("f2"), .text = @constCast("because") }, 1);
    _ = try lib.addMark("a.pdf", .{ .page = 2, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4, .style = @constCast("underline"), .anchor = @constCast("{u}"), .edit = true }, 1);
    try lib.addGone("a.pdf", .{ .nm = @constCast("{c}"), .page = 1, .comment = true });
    try lib.addGone("a.pdf", .{ .nm = @constCast("f1") });
    try lib.addGone("a.pdf", .{ .nm = @constCast("f9") });

    const plan = try planOf(a, lib, "a.pdf");
    try testing.expectEqual(@as(usize, 2), plan.anchors.len);
    const f1 = plan.anchors[0];
    try testing.expectEqualStrings("f1", f1.where.name);
    try testing.expect(!f1.where.paged);
    try testing.expectEqualStrings("why", f1.note.?);
    // Down the page, whatever order the rows were written in.
    try testing.expectEqual(@as(f32, 712), f1.pieces[0].lines[0].max_y);
    const theirs = plan.anchors[1];
    try testing.expectEqual(annots.Kind.underline, theirs.kind);
    try testing.expect(theirs.where.paged);
    try testing.expectEqual(@as(u32, 2), theirs.where.page);
    try testing.expectEqual(@as(?[]const u8, null), theirs.note);

    try testing.expectEqual(@as(usize, 1), plan.replies.len);
    try testing.expectEqualStrings("f2", plan.replies[0].where.name);
    // f1's deletion was undone; f9's and the cleared note were not.
    try testing.expectEqual(@as(usize, 2), plan.drops.len);
    try testing.expectEqualStrings("{c}", plan.drops[0].where.name);
    try testing.expect(!plan.drops[0].anchor);
    try testing.expectEqual(@as(u32, 1), plan.drops[0].where.page);
    try testing.expectEqualStrings("f9", plan.drops[1].where.name);
    try testing.expect(plan.drops[1].anchor);
}

test "marks taken out of the file come back as the rows they went in as, and leave the file" {
    if (!fenrir.mimir.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    // A highlight of two lines with a note and a reply, and a stroke.
    var points = [_]Point{ .{ .x = 72, .y = 600 }, .{ .x = 120, .y = 620.5 }, .{ .x = 160, .y = 605 } };
    _ = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 72, .y0 = 700, .x1 = 300, .y1 = 712, .color = @constCast("#4c9ed9"), .anchor = @constCast("f1") }, 1);
    _ = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 72, .y0 = 686, .x1 = 200, .y1 = 698, .color = @constCast("#4c9ed9"), .anchor = @constCast("f1") }, 1);
    _ = try lib.addComment("a.pdf", .{ .anchor = @constCast("f1"), .nm = @constCast("f1"), .text = @constCast("why") }, 1);
    _ = try lib.addComment("a.pdf", .{ .anchor = @constCast("f1"), .nm = @constCast("f2"), .text = @constCast("because") }, 1);
    _ = try lib.addStroke("a.pdf", .{ .points = &points, .width = 2.5, .color = @constCast("#e4572e"), .anchor = @constCast("f3") }, 1);

    var doc = try Document.open(gpa, try fileWith("", &.{}));
    defer doc.deinit();
    var in = try saved(&doc, try planOf(a, lib, "a.pdf"));
    defer in.deinit();
    try lib.clearJournal("a.pdf");

    const taken = try takeOut(a, lib, "a.pdf", &in, 2);
    try testing.expectEqual(@as(usize, 2), taken.anchors);
    try testing.expectEqual(@as(usize, 2), taken.comments);
    try testing.expectEqual(@as(usize, 2), taken.plan.drops.len);

    const rows = try lib.marks("a.pdf");
    defer lib.freeMarks(rows, rows.len);
    try testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |r| {
        try testing.expectEqualStrings("f1", r.anchor);
        try testing.expectEqualStrings("#4c9ed9", r.color);
        try testing.expectEqualStrings("highlight", r.style);
    }
    try testing.expectApproxEqAbs(@as(f32, 712), rows[0].y1, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 200), rows[1].x1, 0.01);
    const ink = try lib.strokes("a.pdf");
    defer lib.freeStrokes(ink, ink.len);
    try testing.expectEqual(@as(usize, 1), ink.len);
    try testing.expectEqualStrings("f3", ink[0].anchor);
    try testing.expectEqualStrings("#e4572e", ink[0].color);
    try testing.expectEqual(@as(f32, 2.5), ink[0].width);
    try testing.expectEqual(@as(usize, 3), ink[0].points.len);
    const said = try lib.comments("a.pdf");
    defer lib.freeComments(said, said.len);
    try testing.expectEqual(@as(usize, 2), said.len);
    try testing.expectEqualStrings("why", said[0].text);
    try testing.expectEqualStrings("f2", said[1].nm);
    try testing.expectEqualStrings("f1", said[1].anchor);

    // And the update leaves nothing of the reader's in the file.
    var out = try saved(&in, taken.plan);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 0), (try annotsOf(&out, a)).len);
}

test "a file's revisions are listed with their size and what each holds" {
    const gpa = testing.allocator;
    var doc = try Document.open(gpa, try fileWith("", &.{}));
    defer doc.deinit();
    var after = try saved(&doc, .{ .anchors = &.{.{
        .where = .{ .name = "f1" },
        .kind = .highlight,
        .pieces = &.{.{ .page = 0, .lines = &.{.fromRect(72, 700, 300, 712)} }},
    }} });
    defer after.deinit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try describeRevisions(gpa, after.bytes, &out.writer);
    const text = out.written();
    try testing.expect(std.mem.startsWith(u8, text, "revision 1  "));
    const second = std.mem.indexOf(u8, text, "revision 2  ").?;
    const line = text[second..];
    try testing.expect(std.mem.indexOf(u8, line, "fenrir's: 1 Highlight") != null);
    try testing.expect(std.mem.indexOf(u8, line, "form") != null);
    try testing.expect(std.mem.indexOf(u8, line, "page") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "revision "));
}
