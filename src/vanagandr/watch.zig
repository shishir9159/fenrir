//! A document that another program rewrites while it is open: `fenrir read
//! --watch`, or the `watch` setting.
//!
//! `latexmk -pvc` rebuilds a paper on every save, a script re-plots a figure,
//! Acrobat adds a highlight. With watching on, the reader notices and puts
//! the new file in place of the old, on the page that changed. With it off,
//! the default, the file is held so that nothing else can change it under
//! the reader at all (`Hold`).
//!
//! These are decisions about a file on disk, so they are Vánagandr's: the
//! library layer opens no files.
//!
//! ## Noticing
//!
//! A stat, at most four times a second: size, modification time and inode,
//! the `Stamp`. A new stamp is acted on once two polls agree on it, because
//! TeX writes in place and a file caught halfway through is not one to show;
//! and the bytes are taken only if they end in `%%EOF` (`complete`), open,
//! and have a page. No platform notifier: a stat four times a second costs
//! nothing measurable, and the window layer's interface stays as it is.
//!
//! ## Where it changed
//!
//! A digest a page (`digest`), and the first page whose digest moved
//! (`firstChange`); on it, the first word that differs (`locate`). The
//! digest takes the page's own content, the forms and images it names, and
//! its annotations with their appearances -- so a highlight added in another
//! program is a change on its page, though no word of the page moved.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const content = fenrir.content;
const diff = fenrir.hlidskjalf.diff;
const text = fenrir.hlidskjalf.text;
const Document = fenrir.Document;
const Object = fenrir.Object;
const Page = fenrir.Page;
const Wyhash = std.hash.Wyhash;

/// How often the file is looked at.
pub const interval_ns: u64 = 250 * std.time.ns_per_ms;

/// What a stat says about a file: enough to tell that it was written.
pub const Stamp = struct {
    size: u64 = 0,
    mtime: i96 = 0,
    inode: Io.File.INode = 0,

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.size == b.size and a.mtime == b.mtime and a.inode == b.inode;
    }
};

/// One buffer's file, as the reader last found it.
pub const Disk = struct {
    /// The file the held `Document` was read from.
    held: Stamp = .{},
    /// What the last poll found.
    seen: Stamp = .{},
    /// Bytes that would not open, not tried again until the file moves on.
    refused: Stamp = .{},
    /// One a page of the held document, owned; empty until a reload first
    /// needs them.
    digests: []u64 = &.{},
    /// How many times the file has been read: 1 when it was opened.
    generation: u32 = 1,
    reload: Reload = .none,
    /// The file held shut against other programs, while not watching.
    hold: ?Hold = null,
    /// The names of the anchors and comments read out of the file rather
    /// than the library: what a reload takes away and reads again.
    taken: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub const Reload = enum { none, auto, forced };

    /// `io` is null where nothing was ever held: in a test.
    pub fn deinit(d: *Disk, gpa: Allocator, io: ?Io) void {
        gpa.free(d.digests);
        d.taken.deinit(gpa);
        if (d.hold) |*h| h.release(io.?);
        d.* = .{};
    }
};

/// The file's stamp now, or null when it cannot be seen -- gone for the
/// moment, as it is while a build replaces it.
pub fn stat(io: Io, path: []const u8) ?Stamp {
    const s = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .size = s.size, .mtime = s.mtime.nanoseconds, .inode = s.inode };
}

/// Whether a poll that found `now` should read the file again. The whole of
/// the decision, and nothing in it touches the disk.
pub fn due(d: *Disk, now: Stamp) bool {
    // The file the reader holds. This equality is also what will keep a
    // save by fenrir itself from reading the file back: the save records the
    // stamp it left. The author asked that fenrir's own save never cost a
    // reload -- do not take it out.
    if (now.eql(d.held)) {
        d.seen = now;
        return false;
    }
    if (now.eql(d.refused)) return false;
    // Still moving: wait for a second poll to find it where this one did.
    if (!now.eql(d.seen)) {
        d.seen = now;
        return false;
    }
    return true;
}

/// Whether `bytes` end as a whole file does, in `%%EOF` and white space. A
/// TeX build caught halfway does not.
pub fn complete(bytes: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, bytes, " \t\r\n\x00\x0c");
    return std.mem.endsWith(u8, trimmed, "%%EOF");
}

// -- where it changed --------------------------------------------------------

/// What page `p` draws, as a number: its boxes and turn, the raw bytes of
/// its content streams and of every form and image it names, and its
/// annotations with the raw bytes of each one's appearance.
///
/// The annotations because the author asked that a file whose only change
/// is an appearance stream -- a highlight added or redrawn in another
/// program -- is reloaded as a change, and taken to its page. Do not leave
/// them out as "not the page's content".
///
/// Not `digest.Digests`, which follows references into fonts: TeX subsets a
/// font again whenever one new glyph is used, and every page from the first
/// would differ. Raw, not decoded: equal raw bytes decode equally, and the
/// other way round failing only makes the jump land early.
///
/// It chooses where to jump and nothing else. **Never keep pixels on it**: a
/// font changed under unchanged content would leave a wrong page on screen.
/// A part that will not read changes the digest, so it counts as changed.
pub fn digest(doc: *Document, p: Page) u64 {
    var h: Wyhash = .init(0);
    for ([_]Page.Rect{ p.media_box, p.crop_box }) |r| {
        for ([_]f64{ r.x0, r.y0, r.x1, r.y1 }) |v| h.update(std.mem.asBytes(&v));
    }
    h.update(std.mem.asBytes(&p.rotate));

    if (p.dict.get("Contents")) |raw| {
        // An array of streams, perhaps behind a reference of its own.
        const contents = doc.resolve(raw) catch Object.null_object;
        if (contents.asArray()) |parts| {
            for (parts) |part| streamInto(&h, doc, part);
        } else streamInto(&h, doc, contents);
    }

    if (p.resources.get("XObject")) |raw| {
        if ((doc.resolve(raw) catch null)) |named| {
            if (named.asDict()) |xobjects| {
                for (xobjects.keys(), xobjects.values()) |name, ref| {
                    h.update(name);
                    streamInto(&h, doc, ref);
                }
            }
        }
    }

    for (p.annotations(doc) catch &.{}) |raw| {
        const annot = (doc.resolve(raw) catch {
            h.update("unreadable");
            continue;
        }).asDict() orelse continue;
        valueInto(&h, .{ .dict = annot }, 0);
        // The appearance, which is what another reader draws and the whole
        // of what changes when a program redraws one: one state, or each.
        const ap = (doc.get(annot, "AP") catch null) orelse continue;
        const normal = (ap.asDict() orelse continue).get("N") orelse continue;
        const resolved = doc.resolve(normal) catch continue;
        // The stream first: `asDict` answers for a stream with the stream's
        // own dictionary, which is not a dictionary of states.
        if (resolved.asStream()) |s| {
            h.update(s.raw);
        } else if (resolved.asDict()) |states| {
            for (states.values()) |state| streamInto(&h, doc, state);
        }
    }
    return h.final();
}

/// A stream's raw bytes, through a reference. Not the reference's number,
/// which a program that rewrites the file changes without changing a thing.
fn streamInto(h: *Wyhash, doc: *Document, raw: Object) void {
    const resolved = doc.resolve(raw) catch {
        h.update("unreadable");
        return;
    };
    const s = resolved.asStream() orelse return;
    h.update(s.raw);
}

/// A direct value, as it reads: references stand for nothing, for the
/// reason `streamInto` gives.
fn valueInto(h: *Wyhash, v: Object, depth: u8) void {
    if (depth > 8) return;
    switch (v) {
        .null => h.update("n"),
        .boolean => |b| h.update(if (b) "t" else "f"),
        .integer => |i| h.update(std.mem.asBytes(&i)),
        .real => |r| h.update(std.mem.asBytes(&r)),
        .name => |n| {
            h.update("/");
            h.update(n);
        },
        .string => |s| {
            h.update("(");
            h.update(s);
        },
        .array => |items| {
            h.update("[");
            for (items) |item| valueInto(h, item, depth + 1);
        },
        .dict => |d| {
            h.update("<");
            for (d.keys(), d.values()) |k, item| {
                h.update(k);
                valueInto(h, item, depth + 1);
            }
        },
        .stream, .ref => h.update("r"),
    }
}

/// A digest a page, owned by the caller.
pub fn digestAll(gpa: Allocator, doc: *Document, pages: []const Page) Allocator.Error![]u64 {
    const out = try gpa.alloc(u64, pages.len);
    for (pages, out) |p, *d| d.* = digest(doc, p);
    return out;
}

/// The first page whose digest differs, or null when none does. Pages added
/// at the end are a change at the first of them; pages taken off the end, a
/// change at the new last page.
pub fn firstChange(old: []const u64, new: []const u64) ?u32 {
    const n = @min(old.len, new.len);
    for (old[0..n], new[0..n], 0..) |a, b, i| {
        if (a != b) return @intCast(i);
    }
    if (old.len == new.len) return null;
    if (new.len > old.len) return @intCast(old.len);
    return if (new.len == 0) null else @intCast(new.len - 1);
}

/// Where on a changed page to look: how far below its top the first word
/// that differs is, and the new page's text map, which the reader's cache
/// takes at no further cost.
pub const Located = struct {
    /// Points below the top of the page as shown. Zero when no word differs
    /// -- a figure moved -- and the page's top is the change.
    down: f32 = 0,
    map: ?text.Page = null,
};

/// The first word that differs between two versions of a page: a head scan
/// over the two pages' words, which needs no Myers diff to find the first.
pub fn locate(gpa: Allocator, old_doc: *Document, old_page: Page, new_doc: *Document, new_page: Page, options: content.Options) !Located {
    var old_map = try mapOf(gpa, old_doc, old_page, options);
    defer old_map.deinit(gpa);
    var new_map = try mapOf(gpa, new_doc, new_page, options);
    errdefer new_map.deinit(gpa);

    var words: [2]std.ArrayList(diff.Word) = .{ .empty, .empty };
    var hashes: [2]std.ArrayList(u64) = .{ .empty, .empty };
    defer for (&words, &hashes) |*w, *hs| {
        w.deinit(gpa);
        hs.deinit(gpa);
    };
    try diff.words(gpa, old_map.text, &words[0], &hashes[0]);
    try diff.words(gpa, new_map.text, &words[1], &hashes[1]);

    const n = @min(hashes[0].items.len, hashes[1].items.len);
    const at: ?usize = for (hashes[0].items[0..n], hashes[1].items[0..n], 0..) |a, b, i| {
        if (a != b) break i;
    } else if (hashes[1].items.len > n)
        n
    else if (hashes[0].items.len > n and n != 0)
        // Words taken off the end: the change is after the last that is left.
        n - 1
    else
        null;

    var out: Located = .{};
    if (at) |i| {
        const word = words[1].items[i];
        if (new_map.glyphAt(word.at)) |g| {
            const top: f32 = @floatCast(new_page.displayHeight());
            out.down = @max(0, top - new_map.boxes[g].box.max_y);
        }
    }
    out.map = new_map;
    return out;
}

fn mapOf(gpa: Allocator, doc: *Document, p: Page, options: content.Options) !text.Page {
    var result = try content.page(gpa, doc, p, options);
    defer result.deinit(gpa);
    return text.build(gpa, result.list);
}

// -- reading it again ---------------------------------------------------------

/// The document being replaced, as the worker has it.
pub const Old = struct {
    doc: *Document,
    pages: []const Page,
    /// One a page, or empty when no reload has needed them yet.
    digests: []const u64,
};

/// What a reload read.
pub const Loaded = struct {
    /// On the heap and owned, with its pages and outline in its arena.
    doc: *Document,
    pages: []const Page,
    outline: []const fenrir.outline.Entry,
    /// The new document's, owned.
    digests: []u64,
    /// The old document's, when `Old` came without them; owned.
    old_digests: ?[]u64 = null,
    stamp: Stamp,
    /// The first page that changed, and where on it.
    first: ?u32 = null,
    down: f32 = 0,
    /// That page's text map, owned.
    map: ?text.Page = null,
    /// Each page's annotations, read here because this thread owns the new
    /// document, and so that installing it does not walk the file on the
    /// frame thread. In `annots_arena`.
    annots: []const []const fenrir.annots.Annot = &.{},
    annots_arena: ?std.heap.ArenaAllocator = null,
    /// What each step cost, for `--time`.
    ns: struct { read: u64 = 0, open: u64 = 0, annots: u64 = 0, digest: u64 = 0, locate: u64 = 0 } = .{},

    pub fn deinit(l: *Loaded, gpa: Allocator) void {
        l.doc.deinit();
        gpa.destroy(l.doc);
        gpa.free(l.digests);
        if (l.old_digests) |d| gpa.free(d);
        if (l.map) |*m| m.deinit(gpa);
        if (l.annots_arena) |*a| a.deinit();
        l.* = undefined;
    }
};

pub const Outcome = union(enum) {
    loaded: Loaded,
    /// The file as it was found would not do, and why: `stamp` is not tried
    /// again until the file moves on.
    refused: struct { stamp: Stamp, why: anyerror },
};

/// Reads the file again, on the rasterising thread, which owns both
/// documents. `forced` is `:reload`, which takes a file that does not end
/// as a whole one does.
///
/// **Never holds the file open.** It is read whole and closed: on Windows a
/// build has to be able to truncate the file, and a viewer that keeps it
/// open is why TeX fails with a sharing violation -- and why SumatraPDF, which
/// does not, became the TeX viewer there.
pub fn load(gpa: Allocator, io: Io, path: []const u8, old: Old, forced: bool, options: content.Options) Outcome {
    // Stat before reading, so a write during the read is another reload
    // and never one missed.
    const stamp = stat(io, path) orelse return .{ .refused = .{ .stamp = .{}, .why = error.FileNotFound } };
    return loadAt(gpa, io, path, stamp, old, forced, options) catch |err| .{ .refused = .{ .stamp = stamp, .why = err } };
}

fn loadAt(gpa: Allocator, io: Io, path: []const u8, stamp: Stamp, old: Old, forced: bool, options: content.Options) !Outcome {
    var clock: Clock = .start(io);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30));
    var owned = true;
    defer if (owned) gpa.free(bytes);
    if (!forced and !complete(bytes)) return error.Incomplete;
    const read_ns = clock.lap();

    const doc = try gpa.create(Document);
    errdefer gpa.destroy(doc);
    // The document frees the bytes from here on, opened or not.
    owned = false;
    doc.* = try fenrir.open(gpa, bytes);
    errdefer doc.deinit();
    const pages = try fenrir.pages.all(doc);
    if (pages.len == 0) return error.NoPages;
    const outline = fenrir.outline.all(doc, pages) catch &.{};
    const open_ns = clock.lap();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const annots = try arena.allocator().alloc([]const fenrir.annots.Annot, pages.len);
    for (pages, annots) |p, *list| list.* = fenrir.annots.read(arena.allocator(), doc, p) catch &.{};
    const annots_ns = clock.lap();

    const digests = try digestAll(gpa, doc, pages);
    errdefer gpa.free(digests);
    const old_digests: ?[]u64 = if (old.digests.len == old.pages.len and old.pages.len != 0)
        null
    else
        try digestAll(gpa, old.doc, old.pages);
    errdefer if (old_digests) |d| gpa.free(d);
    const digest_ns = clock.lap();

    var loaded: Loaded = .{
        .doc = doc,
        .pages = pages,
        .outline = outline,
        .digests = digests,
        .old_digests = old_digests,
        .stamp = stamp,
        .annots = annots,
        .annots_arena = arena,
    };
    loaded.first = firstChange(old_digests orelse old.digests, digests);
    if (loaded.first) |page| {
        if (page < old.pages.len and page < pages.len) {
            const at = try locate(gpa, old.doc, old.pages[page], doc, pages[page], options);
            loaded.down = at.down;
            loaded.map = at.map;
        }
    }
    loaded.ns = .{ .read = read_ns, .open = open_ns, .annots = annots_ns, .digest = digest_ns, .locate = clock.lap() };
    return .{ .loaded = loaded };
}

const Clock = struct {
    io: Io,
    last: Io.Timestamp,

    fn start(io: Io) Clock {
        return .{ .io = io, .last = Io.Clock.awake.now(io) };
    }

    fn lap(c: *Clock) u64 {
        const now = Io.Clock.awake.now(c.io);
        const ns = c.last.durationTo(now).nanoseconds;
        c.last = now;
        return if (ns <= 0) 0 else @intCast(ns);
    }
};

// -- holding it ---------------------------------------------------------------

/// The file held open so that no other program can change it, while the
/// reader is not watching. Watching is off unless asked for, so this is how
/// a document is open by default.
///
/// **The author asked for both halves:** watching off by default, and a file
/// that is not watched locked against every other program. Do not make the
/// lock advisory on Windows, nor turn watching on by default, to spare a
/// TeX build its sharing violation: `--watch`, or `watch = on`, is the way.
///
/// On Windows it is enforced: the file is opened sharing reading and nothing
/// else, so a program that opens it to write, truncate, rename or delete it
/// is refused with a sharing violation. That is how Acrobat holds a file,
/// and why a TeX build fails against it -- which is the point of watching
/// being the other mode. Elsewhere a lock on a file is advisory: a shared
/// `flock`, which a program that asks for a lock respects and one that does
/// not ask never sees.
///
/// Not `Io.File.Lock` on Windows: that is a lock on one byte, taken after an
/// open that shares writing and deleting, and leaves the file free to be
/// truncated or replaced whole.
pub const Hold = struct {
    file: Io.File,

    pub const Error = error{
        /// Another program has the file open to write it, or holds it the
        /// way this would.
        Busy,
        FileNotFound,
        AccessDenied,
        BadPathName,
        Unexpected,
    };

    pub fn take(io: Io, path: []const u8) Error!Hold {
        switch (builtin.os.tag) {
            .windows => {
                // Reading, and nothing else: no writing, and no deleting,
                // which is also what a rename over the file needs.
                const handle = try ntOpen(path, .{ .READ = true }, .{ .READ = true });
                return .{ .file = .{ .handle = handle, .flags = .{ .nonblocking = false } } };
            },
            else => {
                const file = Io.Dir.cwd().openFile(io, path, .{ .lock = .shared, .lock_nonblocking = true }) catch |err| return switch (err) {
                    error.WouldBlock => error.Busy,
                    error.FileNotFound => error.FileNotFound,
                    error.AccessDenied, error.PermissionDenied => error.AccessDenied,
                    else => error.Unexpected,
                };
                return .{ .file = file };
            },
        }
    }

    pub fn release(h: *Hold, io: Io) void {
        h.file.close(io);
        h.* = undefined;
    }

    /// `NtCreateFile` with the sharing given, which `Io` does not let a
    /// caller choose.
    fn ntOpen(path: []const u8, generic: std.os.windows.ACCESS_MASK.Generic, share: std.os.windows.FILE.SHARE) Error!std.os.windows.HANDLE {
        const w = std.os.windows;
        const cwd = Io.Dir.cwd().handle;
        const wide = Io.Threaded.sliceToPrefixedFileW(cwd, path, .{}) catch return error.BadPathName;
        const span = wide.span();
        var name = w.UNICODE_STRING.init(span);
        var handle: w.HANDLE = undefined;
        var iosb: w.IO_STATUS_BLOCK = undefined;
        const status = w.ntdll.NtCreateFile(
            &handle,
            .{ .STANDARD = .{ .SYNCHRONIZE = true }, .GENERIC = generic },
            &.{
                .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(span)) null else cwd,
                .ObjectName = &name,
            },
            &iosb,
            null,
            .{ .NORMAL = true },
            share,
            .OPEN,
            .{ .IO = .SYNCHRONOUS_NONALERT, .NON_DIRECTORY_FILE = true },
            null,
            0,
        );
        return switch (status) {
            .SUCCESS => handle,
            .SHARING_VIOLATION => error.Busy,
            .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            .OBJECT_NAME_INVALID => error.BadPathName,
            else => error.Unexpected,
        };
    }
};

// -- tests --------------------------------------------------------------------

const testing = std.testing;

/// A one-page document, through reconstruction (`startxref 0`), so that no
/// offsets are counted by hand. `first` is the number its objects start
/// from, which is how a test renumbers the same content; `objects` are
/// numbered by the caller, from 30.
const Fixture = struct {
    first: u32 = 1,
    body: []const u8 = "",
    resources: []const u8 = "",
    page: []const u8 = "",
    font: []const u8 = "",
    objects: []const u8 = "",
};

fn docOf(f: Fixture) !Document {
    return Document.open(testing.allocator, try bytesOf(f));
}

fn bytesOf(f: Fixture) ![]u8 {
    const n = f.first;
    return std.fmt.allocPrint(testing.allocator,
        \\%PDF-1.7
        \\{d} 0 obj << /Type /Catalog /Pages {d} 0 R >> endobj
        \\{d} 0 obj << /Type /Pages /Kids [{d} 0 R] /Count 1 >> endobj
        \\{d} 0 obj << /Type /Page /Parent {d} 0 R /MediaBox [0 0 200 200] {s}
        \\  /Resources << /Font << /F1 {d} 0 R >> {s} >> /Contents {d} 0 R >> endobj
        \\{d} 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica {s} >> endobj
        \\{d} 0 obj << /Length {d} >> stream
        \\{s}
        \\endstream endobj
        \\{s}
        \\trailer << /Root {d} 0 R >>
        \\startxref 0
        \\%%EOF
        \\
    , .{
        n,     n + 1,  n + 1, n + 2,      n + 2,  n + 1,     f.page, n + 3, f.resources, n + 4,
        n + 3, f.font, n + 4, f.body.len, f.body, f.objects, n,
    });
}

fn digestOf(doc: *Document) !u64 {
    return digest(doc, (try fenrir.pages.all(doc))[0]);
}

test "a digest is the page's content, whatever its objects are numbered" {
    var a = try docOf(.{ .body = "BT /F1 12 Tf 20 150 Td (ABC) Tj ET" });
    defer a.deinit();
    var b = try docOf(.{ .first = 40, .body = "BT /F1 12 Tf 20 150 Td (ABC) Tj ET" });
    defer b.deinit();
    var c = try docOf(.{ .body = "BT /F1 12 Tf 20 150 Td (ABD) Tj ET" });
    defer c.deinit();
    try testing.expectEqual(try digestOf(&a), try digestOf(&b));
    try testing.expect(try digestOf(&a) != try digestOf(&c));
}

test "a font is left out of the digest, and a form is in it" {
    // TeX subsets a font again for every new glyph: a page whose content did
    // not change must not count as changed because its font did. A form the
    // page draws is the page.
    const form = "/XObject << /X0 30 0 R >>";
    var a = try docOf(.{ .body = "/X0 Do", .resources = form, .objects =
        \\30 0 obj << /Subtype /Form /BBox [0 0 9 9] /Length 12 >> stream
        \\0 0 9 9 re f
        \\endstream endobj
    });
    defer a.deinit();
    var b = try docOf(.{ .body = "/X0 Do", .resources = form, .objects =
        \\30 0 obj << /Subtype /Form /BBox [0 0 9 9] /Length 12 >> stream
        \\0 0 8 9 re f
        \\endstream endobj
    });
    defer b.deinit();
    try testing.expect(try digestOf(&a) != try digestOf(&b));

    const font = "/FontDescriptor 30 0 R";
    var fa = try docOf(.{ .body = "BT /F1 12 Tf (A) Tj ET", .font = font, .objects =
        \\30 0 obj << /Type /FontDescriptor /FontFile 31 0 R >> endobj
        \\31 0 obj << /Length 4 >> stream
        \\AAAA
        \\endstream endobj
    });
    defer fa.deinit();
    var fb = try docOf(.{ .body = "BT /F1 12 Tf (A) Tj ET", .font = font, .objects =
        \\30 0 obj << /Type /FontDescriptor /FontFile 31 0 R >> endobj
        \\31 0 obj << /Length 4 >> stream
        \\BBBB
        \\endstream endobj
    });
    defer fb.deinit();
    try testing.expectEqual(try digestOf(&fa), try digestOf(&fb));
}

test "an annotation redrawn by another program changes its page" {
    // The author asked that a change to an appearance stream alone counts:
    // a highlight recoloured in Acrobat moves no word of the page, and is
    // still where the reader should go.
    const annot =
        \\30 0 obj << /Subtype /Highlight /Rect [10 10 50 20] /C [1 1 0] /AP << /N 31 0 R >> >> endobj
        \\31 0 obj << /Subtype /Form /BBox [0 0 1 1] /Length 22 >> stream
        \\
    ;
    const end_ = "\nendstream endobj";
    var a = try docOf(.{ .page = "/Annots [30 0 R]", .objects = annot ++ "1 1 0 rg 0 0 1 1 re f" ++ end_ });
    defer a.deinit();
    var b = try docOf(.{ .page = "/Annots [30 0 R]", .objects = annot ++ "1 0 0 rg 0 0 1 1 re f" ++ end_ });
    defer b.deinit();
    var c = try docOf(.{ .first = 40, .page = "/Annots [30 0 R]", .objects = annot ++ "1 1 0 rg 0 0 1 1 re f" ++ end_ });
    defer c.deinit();
    try testing.expect(try digestOf(&a) != try digestOf(&b));
    try testing.expectEqual(try digestOf(&a), try digestOf(&c));
}

test "the first change: in the middle, pages added, pages taken off, none" {
    try testing.expectEqual(@as(?u32, null), firstChange(&.{ 1, 2, 3 }, &.{ 1, 2, 3 }));
    try testing.expectEqual(@as(?u32, 1), firstChange(&.{ 1, 2, 3 }, &.{ 1, 9, 3 }));
    try testing.expectEqual(@as(?u32, 3), firstChange(&.{ 1, 2, 3 }, &.{ 1, 2, 3, 4 }));
    try testing.expectEqual(@as(?u32, 1), firstChange(&.{ 1, 2, 3 }, &.{ 1, 2 }));
}

test "a file is complete when it ends in %%EOF, white space and all" {
    try testing.expect(complete("%PDF-1.7\n...\n%%EOF\n"));
    try testing.expect(complete("%PDF-1.7\n...\n%%EOF  \r\n\n"));
    try testing.expect(!complete("%PDF-1.7\n1 0 obj << /Type /Cata"));
    try testing.expect(!complete(""));
}

test "a poll reads again only when two agree on a stamp that is not held" {
    var d: Disk = .{ .held = .{ .size = 10, .mtime = 1 }, .seen = .{ .size = 10, .mtime = 1 } };
    // Unchanged.
    try testing.expect(!due(&d, .{ .size = 10, .mtime = 1 }));
    // Moved once: still being written, perhaps.
    try testing.expect(!due(&d, .{ .size = 20, .mtime = 2 }));
    // The same stamp twice: done.
    try testing.expect(due(&d, .{ .size = 20, .mtime = 2 }));
    // A stamp that would not open stays refused until the file moves on.
    d.refused = .{ .size = 20, .mtime = 2 };
    try testing.expect(!due(&d, .{ .size = 20, .mtime = 2 }));
    // Back at what is held -- a build put the same bytes back, or fenrir
    // wrote it -- is nothing to read.
    try testing.expect(!due(&d, .{ .size = 10, .mtime = 1 }));
    try testing.expect(d.seen.eql(d.held));
}

test "the change is found at the first word that differs" {
    var a = try docOf(.{ .body = "BT /F1 12 Tf 20 150 Td (AB BA) Tj 0 -40 Td (CC AA) Tj ET" });
    defer a.deinit();
    var b = try docOf(.{ .body = "BT /F1 12 Tf 20 150 Td (AB BA) Tj 0 -40 Td (CC AB) Tj ET" });
    defer b.deinit();
    const pa = (try fenrir.pages.all(&a))[0];
    const pb = (try fenrir.pages.all(&b))[0];

    var at = try locate(testing.allocator, &a, pa, &b, pb, .{});
    defer if (at.map) |*m| m.deinit(testing.allocator);
    // The second line, whose baseline is 110 points up a 200-point page:
    // 90 points down to it, less the height of its capitals.
    try testing.expect(at.down > 75 and at.down < 90);
    try testing.expect(at.map != null);

    var same = try locate(testing.allocator, &a, pa, &a, pa, .{});
    defer if (same.map) |*m| m.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 0), same.down);
}

test "a reload takes a whole file, finds what changed, and refuses half of one" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const before = try bytesOf(.{ .body = "BT /F1 12 Tf 20 150 Td (AB BA) Tj ET" });
    defer gpa.free(before);
    const after = try bytesOf(.{ .body = "BT /F1 12 Tf 20 150 Td (AB CC) Tj ET" });
    defer gpa.free(after);
    try tmp.dir.writeFile(io, .{ .sub_path = "w.pdf", .data = after });
    const path = try tmp.dir.realPathFileAlloc(io, "w.pdf", gpa);
    defer gpa.free(path);

    var old = try Document.open(gpa, try gpa.dupe(u8, before));
    defer old.deinit();
    const old_pages = try fenrir.pages.all(&old);

    var outcome = load(gpa, io, path, .{ .doc = &old, .pages = old_pages, .digests = &.{} }, false, .{});
    try testing.expect(outcome == .loaded);
    const got = &outcome.loaded;
    defer got.deinit(gpa);
    try testing.expectEqual(@as(?u32, 0), got.first);
    try testing.expect(got.old_digests != null);
    try testing.expect(got.map != null);
    try testing.expect(got.down > 30 and got.down < 50);
    try testing.expect(got.stamp.eql(stat(io, path).?));

    // Caught halfway through a build: not shown, and not tried again until
    // the file moves on.
    try tmp.dir.writeFile(io, .{ .sub_path = "w.pdf", .data = after[0 .. after.len / 2] });
    const half = load(gpa, io, path, .{ .doc = &old, .pages = old_pages, .digests = got.digests }, false, .{});
    try testing.expect(half == .refused);
    try testing.expectEqual(error.Incomplete, half.refused.why);
    try testing.expect(half.refused.stamp.eql(stat(io, path).?));
}

test "a file held while not watching cannot be written by anyone else" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "held.pdf", .data = "%PDF-1.7\n%%EOF\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "held.pdf", testing.allocator);
    defer testing.allocator.free(path);

    // As a build opens it: to write, sharing everything. Asked of the
    // system directly, because `Io` retries a sharing violation for seconds.
    const writing: std.os.windows.ACCESS_MASK.Generic = .{ .WRITE = true };
    var hold = try Hold.take(io, path);
    // Reading it is still allowed; writing it is not.
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(1 << 10));
    testing.allocator.free(bytes);
    try testing.expectError(error.Busy, Hold.ntOpen(path, writing, .VALID_FLAGS));
    hold.release(io);

    // Let go of, it can be written again.
    std.os.windows.CloseHandle(try Hold.ntOpen(path, writing, .VALID_FLAGS));
}
