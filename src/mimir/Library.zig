//! What the reader remembers between sessions: which documents you have
//! opened, where you were in each, and the handful of settings that are
//! yours rather than a command line's.
//!
//! A handful of tables and a version number. The schema is small on purpose
//! -- this is a reader's memory, not a catalogue -- and is created whole at
//! `user_version` 1; see `schema_version` for why there are no migrations.
//!
//! ## What is stored, and what is not
//!
//! A recent entry is a *path*, a place in it, and a zoom. The place is a page
//! and an offset down that page in points, which is the precision that makes
//! reopening land on the line you were reading rather than at the top of the
//! page it was on. Not the document, not a thumbnail, not the text: this file
//! lives in a config directory and should stay kilobytes. A file that has
//! been moved or deleted is not noticed until it is opened; `forget` and
//! `--clear` are how a list is trimmed.
//!
//! Marks and ink are the things here that are a *change to a document*
//! rather than a note about reading it. **The PDF is modified by default**:
//! they are journaled here as they settle and go into the file as one
//! incremental update on `:w` and when the reader closes it, after which
//! their rows are gone (`clearJournal`), the file holding them. With the
//! `store` setting at `library`, or a document's own `store` saying so,
//! the file is never written and the rows stay here for good.
//!
//! Ink is the same kind of fact as a mark and is kept the same way: a
//! page, a colour, and geometry in that page's own user-space points. It has
//! a table of its own rather than more columns on `mark` because the
//! two differ in what geometry *is* -- a box is four numbers and a stroke is
//! a list of them -- and a table whose meaning depends on which of its
//! columns are null is a table nobody can read.
//!
//! ## Anchors, comments and links
//!
//! A comment is made on an *anchor*: the marks one selection made, which is
//! six rows for six lines and one annotation when the PDF takes it. Every
//! mark row names its anchor, and every comment names the anchor it is on,
//! so many comments can hang from one anchor. A link joins two comments.
//!
//! The names are the ones the PDF will hold, from the start: an anchor is
//! named by the `/NM` its annotation will carry, a comment by its own, and a
//! link by the two comments' -- `f` and a base-36 number, unique within one
//! document (see `makeName`). The first comment on an anchor is the anchor's own
//! `/Contents` in a PDF, so it takes the anchor's name; later ones are
//! replies with names of their own. Nothing is ever translated between a
//! row id and a name, because a program that rewrites a PDF renumbers every
//! object and keeps `/NM`.
//!
//! `document` holds the trailer's `/ID` beside the path. A path changes when
//! a file is moved or sent and the `/ID` does not, so a link to a comment in
//! another document names that document by its `/ID`.
//!
//! ## The journal
//!
//! The rows are also what the reader changed since its file was last
//! written, and a reopen takes them over the file by name: an anchor's
//! lines, a comment's text. A change to something the file holds -- a
//! highlight made in Acrobat, recoloured; a line taken off one of
//! fenrir's own -- is a row of the whole anchor, marked `edit`, and a
//! deletion of one is a `gone` row, because a deletion leaves no row to
//! win with. Without the two, a recolour of the file's highlight came
//! back in the file's colour and a deleted one came back at all.
//!
//! Settings are key and value, both text, because every one of them is
//! either a name, a colour or a number that a person may want to read in the
//! file. `author` is who annotations will be signed by; `accent` is the
//! colour the interface draws its own marks in.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Db = @import("Db.zig");
const geom = @import("../gelgja/geom.zig");
const paint = @import("../gelgja/paint.zig");

const Color = paint.Color;
const Point = geom.Point;
const Library = @This();

pub const Error = Db.Error;

/// The schema this build expects. A file from a *newer* version is left
/// alone and opened read-only in effect, because a later fenrir may have
/// added a column this one would drop on write.
///
/// One, and created whole by `create`: fenrir has not been released, so no
/// file exists anywhere that needs carrying forward. The author asked that
/// the versions before this be folded into one and their `ALTER TABLE`
/// steps removed. Until the first release a change to a table is a change
/// to `create`, with this left at 1 -- do not add a migration back for it.
/// A library from a build before the fold says 2 to 6 and is opened
/// read-only; it is deleted, not upgraded.
pub const schema_version: i64 = 1;

gpa: Allocator,
db: Db,
/// True when the file on disk is newer than `schema_version`, in which case
/// nothing is written to it.
future: bool = false,

pub fn open(gpa: Allocator, path: []const u8) Error!Library {
    var db = try Db.open(gpa, path);
    errdefer db.close();

    var lib: Library = .{ .gpa = gpa, .db = db };
    const found = try lib.userVersion();
    if (found > schema_version) {
        lib.future = true;
        return lib;
    }
    if (found < schema_version) try lib.create();
    return lib;
}

pub fn close(lib: *Library) void {
    lib.db.close();
}

/// What version the file on disk says it is. Public because `fenrir health`
/// asks: a library that opened and a library at the version this build
/// understands are two facts.
pub fn userVersion(lib: Library) Error!i64 {
    var s = try lib.db.prepare("PRAGMA user_version");
    defer s.finalize();
    if (!try s.step()) return 0;
    return s.columnInt(0);
}

/// Every table, in one transaction with the version that says they exist,
/// so a file is never left with half of them.
///
/// `recent.offset` is *points from the top of that page*, not pixels: a
/// pixel offset would put you somewhere else on reopening at another zoom or
/// on another screen, which is the bug that makes resuming not worth having.
///
/// `mark` is a box over words, in the same user-space points; `style` is how
/// it marks them, by PDF's names for the four ways -- `highlight`,
/// `underline`, `strikeout`, `squiggly` -- so the file still reads and
/// writing one into a PDF has nothing to translate. It is called `mark` and
/// not `highlight` because a highlight is one of the four.
///
/// `ink` is the same shape with the box replaced by the two things a pen has
/// that a highlighter does not: where it went, and how wide it was. `points`
/// is text and not a blob, which is the one decision here worth arguing. A
/// blob of f32 pairs is eight bytes a point against about twelve, and it
/// round-trips exactly. Text keeps the promise the rest of this file makes --
/// that this is a file a person can open and read -- and what it costs is a
/// hundredth of a point, which is a three-thousandth of a millimetre and is
/// not a thing anybody can draw. Size is `Marks.simplify`'s to worry about,
/// and it has far more of it to give than an encoding does.
///
/// Every table names its document by `path` rather than by a key into
/// `document` or `recent`, so that forgetting a recent file, or where a
/// document was left, does not silently throw away what was written on it.
/// `other` on a link is the other document's `/ID`, and empty when both
/// comments are in this one. See "Anchors, comments and links" at the top.
///
/// `document.named` is the highest name ever handed out in the document,
/// and `comment.page` the page of the anchor a comment is on, which is
/// how another program's name is told apart from the same name on another
/// page. `naming` gives a name to an annotation the file holds without a
/// usable one of its own, by what it looks like; see `nameAnnotation`.
///
/// `edit` on a mark, a stroke or a comment says the row is the reader's
/// version of something the file has, rather than something the reader
/// made; `gone` names what the reader deleted that the file still holds.
/// Those and the rest are the journal: what the next save writes into the
/// file. See "The journal" at the top. `appending` is a save on its way
/// into a file, and `document.store` where a document's marks are kept,
/// when it is not where the `store` setting says.
fn create(lib: *Library) Error!void {
    try lib.db.exec(
        \\BEGIN;
        \\CREATE TABLE IF NOT EXISTS settings (
        \\    key   TEXT PRIMARY KEY,
        \\    value TEXT NOT NULL
        \\) WITHOUT ROWID;
        \\CREATE TABLE IF NOT EXISTS recent (
        \\    path      TEXT PRIMARY KEY,
        \\    title     TEXT NOT NULL DEFAULT '',
        \\    page      INTEGER NOT NULL DEFAULT 0,
        \\    offset    REAL NOT NULL DEFAULT 0,
        \\    zoom      REAL NOT NULL DEFAULT 0,
        \\    opens     INTEGER NOT NULL DEFAULT 0,
        \\    opened_at INTEGER NOT NULL DEFAULT 0
        \\) WITHOUT ROWID;
        \\CREATE INDEX IF NOT EXISTS recent_by_time ON recent (opened_at DESC);
        \\CREATE TABLE IF NOT EXISTS mark (
        \\    id         INTEGER PRIMARY KEY,
        \\    path       TEXT NOT NULL,
        \\    page       INTEGER NOT NULL,
        \\    x0         REAL NOT NULL,
        \\    y0         REAL NOT NULL,
        \\    x1         REAL NOT NULL,
        \\    y1         REAL NOT NULL,
        \\    color      TEXT NOT NULL DEFAULT '',
        \\    style      TEXT NOT NULL DEFAULT 'highlight',
        \\    anchor     TEXT NOT NULL DEFAULT '',
        \\    edit       INTEGER NOT NULL DEFAULT 0,
        \\    created_at INTEGER NOT NULL DEFAULT 0
        \\);
        \\CREATE INDEX IF NOT EXISTS mark_by_doc ON mark (path, page);
        \\CREATE TABLE IF NOT EXISTS ink (
        \\    id         INTEGER PRIMARY KEY,
        \\    path       TEXT NOT NULL,
        \\    page       INTEGER NOT NULL,
        \\    color      TEXT NOT NULL DEFAULT '',
        \\    width      REAL NOT NULL DEFAULT 0,
        \\    points     TEXT NOT NULL DEFAULT '',
        \\    anchor     TEXT NOT NULL DEFAULT '',
        \\    edit       INTEGER NOT NULL DEFAULT 0,
        \\    created_at INTEGER NOT NULL DEFAULT 0
        \\);
        \\CREATE INDEX IF NOT EXISTS ink_by_doc ON ink (path, page);
        \\CREATE TABLE IF NOT EXISTS document (
        \\    id      INTEGER PRIMARY KEY,
        \\    path    TEXT NOT NULL UNIQUE,
        \\    file_id TEXT NOT NULL DEFAULT '',
        \\    named   INTEGER NOT NULL DEFAULT 0,
        \\    store   TEXT NOT NULL DEFAULT ''
        \\);
        \\CREATE INDEX IF NOT EXISTS document_by_file ON document (file_id);
        \\CREATE TABLE IF NOT EXISTS comment (
        \\    id          INTEGER PRIMARY KEY,
        \\    path        TEXT NOT NULL,
        \\    anchor      TEXT NOT NULL,
        \\    nm          TEXT NOT NULL,
        \\    page        INTEGER NOT NULL DEFAULT 0,
        \\    text        TEXT NOT NULL DEFAULT '',
        \\    edit        INTEGER NOT NULL DEFAULT 0,
        \\    created_at  INTEGER NOT NULL DEFAULT 0,
        \\    modified_at INTEGER NOT NULL DEFAULT 0
        \\);
        \\CREATE INDEX IF NOT EXISTS comment_by_doc ON comment (path, anchor);
        \\CREATE TABLE IF NOT EXISTS link (
        \\    id         INTEGER PRIMARY KEY,
        \\    path       TEXT NOT NULL,
        \\    from_nm    TEXT NOT NULL,
        \\    to_nm      TEXT NOT NULL,
        \\    other      TEXT NOT NULL DEFAULT '',
        \\    label      TEXT NOT NULL DEFAULT '',
        \\    created_at INTEGER NOT NULL DEFAULT 0
        \\);
        \\CREATE INDEX IF NOT EXISTS link_by_doc ON link (path);
        \\CREATE TABLE IF NOT EXISTS naming (
        \\    id    INTEGER PRIMARY KEY,
        \\    path  TEXT NOT NULL,
        \\    page  INTEGER NOT NULL,
        \\    shape TEXT NOT NULL,
        \\    nm    TEXT NOT NULL
        \\);
        \\CREATE INDEX IF NOT EXISTS naming_by_doc ON naming (path);
        \\CREATE TABLE IF NOT EXISTS gone (
        \\    id      INTEGER PRIMARY KEY,
        \\    path    TEXT NOT NULL,
        \\    nm      TEXT NOT NULL,
        \\    page    INTEGER NOT NULL DEFAULT 0,
        \\    comment INTEGER NOT NULL DEFAULT 0,
        \\    UNIQUE (path, nm, page, comment)
        \\);
        \\CREATE TABLE IF NOT EXISTS appending (
        \\    path   TEXT PRIMARY KEY,
        \\    held   INTEGER NOT NULL,
        \\    tail   TEXT NOT NULL,
        \\    bytes  BLOB NOT NULL,
        \\    out    INTEGER NOT NULL DEFAULT 0
        \\) WITHOUT ROWID;
        \\PRAGMA user_version = 1;
        \\COMMIT;
    );
}

// -- names --------------------------------------------------------------------

/// The longest name `makeName` writes: `f` and a `u64` in base 36.
pub const name_len = 14;

/// Fenrir's name for the `n`th thing it has named in a document, as a PDF's
/// `/NM` will hold it: `f`, then `n` in base 36, lower case, from 1.
///
/// Base 36 because a name is written once per annotation and once per link
/// end, and `f2bj` is shorter than `f99991`. Lower case and with no leading
/// zero, so that of two names of one length the larger number is also the
/// later string.
pub fn makeName(buf: *[name_len]u8, n: u64) []const u8 {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var tail: [name_len - 1]u8 = undefined;
    var i: usize = tail.len;
    var v = n;
    while (true) {
        i -= 1;
        tail[i] = digits[@intCast(v % 36)];
        v /= 36;
        if (v == 0) break;
    }
    buf[0] = 'f';
    const len = tail.len - i;
    @memcpy(buf[1..][0..len], tail[i..]);
    return buf[0 .. 1 + len];
}

/// The number in a name `makeName` wrote, or null for any other: another
/// program's `/NM` is kept as it is and never counted, so it can never make
/// fenrir's next name collide with it.
pub fn nameNumber(nm: []const u8) ?u64 {
    if (nm.len < 2 or nm.len > name_len or nm[0] != 'f' or nm[1] == '0') return null;
    var n: u64 = 0;
    for (nm[1..]) |c| {
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            else => return null,
        };
        n = std.math.mul(u64, n, 36) catch return null;
        n = std.math.add(u64, n, d) catch return null;
    }
    return n;
}

/// The highest name fenrir has given in a document, or 0 for none. The next
/// is one more.
///
/// The rows, and `document.named` beside them. The rows alone would hand
/// a deleted mark's name out again, and a link that named it -- in the
/// library, or in a copy of the file sent before the delete -- would then
/// attach to whatever was made next. **A name is never handed out twice**:
/// do not go back to counting only what is still there.
pub fn highestName(lib: Library, path: []const u8) Error!u64 {
    var s = try lib.db.prepare(
        \\SELECT anchor FROM mark WHERE path = ?1
        \\UNION SELECT anchor FROM ink WHERE path = ?1
        \\UNION SELECT nm FROM comment WHERE path = ?1
        \\UNION SELECT nm FROM naming WHERE path = ?1
    );
    defer s.finalize();
    s.bindText(1, path);
    var high: u64 = 0;
    while (try s.step()) high = @max(high, nameNumber(s.columnText(0)) orelse 0);

    var named = try lib.db.prepare("SELECT named FROM document WHERE path = ?1");
    defer named.finalize();
    named.bindText(1, path);
    if (try named.step()) high = @max(high, @as(u64, @intCast(@max(0, named.columnInt(0)))));
    return high;
}

/// Records that names up to `n` have been handed out in a document, so
/// that none of them is handed out again. Never lowers what is there.
pub fn noteName(lib: Library, path: []const u8, n: u64) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare(
        \\INSERT INTO document (path, named) VALUES (?1, ?2)
        \\ON CONFLICT (path) DO UPDATE SET named = max(named, excluded.named)
    );
    defer s.finalize();
    s.bindText(1, path);
    s.bindInt(2, @intCast(@min(n, std.math.maxInt(i64))));
    try s.exec();
}

/// Moves every row that says `from` to `to`: a mark's anchor, a comment's
/// anchor and its own name, either end of a link. What a name the reader
/// made is changed to when a newer copy of the file turns out to hold the
/// same one for something else. One transaction, so a document is never
/// left half under each name.
pub fn renumber(lib: Library, path: []const u8, from: []const u8, to: []const u8) Error!void {
    if (lib.future) return;
    try lib.db.exec("BEGIN");
    errdefer lib.db.exec("ROLLBACK") catch {};
    const steps = [_][]const u8{
        "UPDATE mark SET anchor = ?3 WHERE path = ?1 AND anchor = ?2",
        "UPDATE ink SET anchor = ?3 WHERE path = ?1 AND anchor = ?2",
        "UPDATE comment SET anchor = ?3 WHERE path = ?1 AND anchor = ?2",
        "UPDATE comment SET nm = ?3 WHERE path = ?1 AND nm = ?2",
        "UPDATE link SET from_nm = ?3 WHERE path = ?1 AND from_nm = ?2",
        "UPDATE link SET to_nm = ?3 WHERE path = ?1 AND to_nm = ?2 AND other = ''",
        "UPDATE naming SET nm = ?3 WHERE path = ?1 AND nm = ?2",
    };
    for (steps) |sql| {
        var s = try lib.db.prepare(sql);
        defer s.finalize();
        s.bindText(1, path);
        s.bindText(2, from);
        s.bindText(3, to);
        try s.exec();
    }
    try lib.db.exec("COMMIT");
}

/// A name given to an annotation the file holds with none of its own, or
/// with one its page repeats: by its page and by `shape`, a hash of what
/// it looks like (`annots.shapeOf`), which is all that can find it again
/// in a file whose objects another program may have renumbered.
pub const Naming = struct {
    page: u32,
    shape: u64,
    /// `f` and a number.
    nm: []u8,
};

/// Records that the annotation on `page` with this shape is called `nm`
/// from now on, until a save writes the name into the file itself.
pub fn nameAnnotation(lib: Library, path: []const u8, page: u32, shape: u64, nm: []const u8) Error!void {
    if (lib.future) return;
    var hex: [16]u8 = undefined;
    var s = try lib.db.prepare("INSERT INTO naming (path, page, shape, nm) VALUES (?1, ?2, ?3, ?4)");
    defer s.finalize();
    s.bindText(1, path);
    s.bindInt(2, page);
    s.bindText(3, std.fmt.bufPrint(&hex, "{x:0>16}", .{shape}) catch unreachable);
    s.bindText(4, nm);
    try s.exec();
}

/// Every name given to a document's unnamed annotations, oldest first.
pub fn namings(lib: Library, path: []const u8) Error![]Naming {
    var out: std.ArrayList(Naming) = .empty;
    errdefer lib.freeNamings(out.items, out.items.len);
    var s = try lib.db.prepare("SELECT page, shape, nm FROM naming WHERE path = ?1 ORDER BY id");
    defer s.finalize();
    s.bindText(1, path);
    while (try s.step()) {
        const shape = std.fmt.parseInt(u64, s.columnText(1), 16) catch continue;
        const nm = try lib.gpa.dupe(u8, s.columnText(2));
        errdefer lib.gpa.free(nm);
        try out.append(lib.gpa, .{ .page = @intCast(@max(0, s.columnInt(0))), .shape = shape, .nm = nm });
    }
    return out.toOwnedSlice(lib.gpa);
}

pub fn freeNamings(lib: Library, list: []Naming, n: usize) void {
    for (list[0..n]) |x| lib.gpa.free(x.nm);
    if (list.len != 0) lib.gpa.free(list);
}

/// The name a new mark is given when its writer did not choose one, noted
/// as handed out before the row that carries it exists.
fn nextName(lib: Library, path: []const u8, buf: *[name_len]u8) Error![]const u8 {
    const n = try lib.highestName(path) + 1;
    try lib.noteName(path, n);
    return makeName(buf, n);
}

// -- settings ----------------------------------------------------------------

/// The value of `key`, or null. The caller owns the string.
pub fn get(lib: Library, key: []const u8) Error!?[]u8 {
    var s = try lib.db.prepare("SELECT value FROM settings WHERE key = ?1");
    defer s.finalize();
    s.bindText(1, key);
    if (!try s.step()) return null;
    const text = s.columnText(0);
    if (text.len == 0) return null;
    return try lib.gpa.dupe(u8, text);
}

pub fn set(lib: Library, key: []const u8, value: []const u8) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare(
        \\INSERT INTO settings (key, value) VALUES (?1, ?2)
        \\ON CONFLICT (key) DO UPDATE SET value = excluded.value
    );
    defer s.finalize();
    s.bindText(1, key);
    s.bindText(2, value);
    try s.exec();
}

pub fn remove(lib: Library, key: []const u8) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare("DELETE FROM settings WHERE key = ?1");
    defer s.finalize();
    s.bindText(1, key);
    try s.exec();
}

/// Every setting, for `fenrir config` with no arguments. Caller owns both the
/// list and every string in it.
pub const Setting = struct { key: []u8, value: []u8 };

pub fn settings(lib: Library) Error![]Setting {
    var out: std.ArrayList(Setting) = .empty;
    errdefer {
        for (out.items) |it| {
            lib.gpa.free(it.key);
            lib.gpa.free(it.value);
        }
        out.deinit(lib.gpa);
    }

    var s = try lib.db.prepare("SELECT key, value FROM settings ORDER BY key");
    defer s.finalize();
    while (try s.step()) {
        const key = try lib.gpa.dupe(u8, s.columnText(0));
        errdefer lib.gpa.free(key);
        const value = try lib.gpa.dupe(u8, s.columnText(1));
        try out.append(lib.gpa, .{ .key = key, .value = value });
    }
    return out.toOwnedSlice(lib.gpa);
}

pub fn freeSettings(lib: Library, list: []Setting) void {
    for (list) |it| {
        lib.gpa.free(it.key);
        lib.gpa.free(it.value);
    }
    lib.gpa.free(list);
}

/// The name annotations are signed with, if one has been set.
pub fn author(lib: Library) Error!?[]u8 {
    return lib.get("author");
}

pub fn setAuthor(lib: Library, name: []const u8) Error!void {
    try lib.set("author", name);
}

/// Which set of colours the interface is drawn in, by name.
///
/// A name and not a table: the themes are compiled into Þviti, and a library
/// that stored eleven colours would be a second place for them to be wrong.
/// Whether the name is one that exists is asked where the themes are, which
/// is not here.
pub fn theme(lib: Library) Error!?[]u8 {
    return lib.get("theme");
}

pub fn setTheme(lib: Library, name: []const u8) Error!void {
    try lib.set("theme", name);
}

/// The colour the interface draws its own marks in: the scrollbar thumb, and
/// what a highlight made by hand would be.
pub fn accent(lib: Library) Error!?Color {
    const text = try lib.get("accent") orelse return null;
    defer lib.gpa.free(text);
    return parseColor(text);
}

pub fn setAccent(lib: Library, c: Color) Error!void {
    var buf: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{
        channel(c.r), channel(c.g), channel(c.b),
    }) catch return error.Failed;
    try lib.set("accent", text);
}

fn channel(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// `#rrggbb`, `rrggbb`, `#rgb`, or one of a few names a person would type.
///
/// Named colours are here rather than in a table of six hundred because the
/// question this answers is "what colour is my highlighter", and the answer
/// is one of about eight.
pub fn parseColor(text: []const u8) ?Color {
    const named = [_]struct { []const u8, u32 }{
        .{ "white", 0xffffff },  .{ "black", 0x000000 },
        .{ "red", 0xe4572e },    .{ "orange", 0xf4a259 },
        .{ "yellow", 0xf7e733 }, .{ "green", 0x3fa34d },
        .{ "blue", 0x4c9ed9 },   .{ "purple", 0x8d6cab },
        .{ "pink", 0xef476f },   .{ "grey", 0x9aa0a6 },
        .{ "gray", 0x9aa0a6 },
    };
    for (named) |n| {
        if (std.ascii.eqlIgnoreCase(text, n[0])) return fromRgb(n[1]);
    }

    var hex = text;
    if (hex.len > 0 and hex[0] == '#') hex = hex[1..];
    if (hex.len == 3) {
        var wide: [6]u8 = undefined;
        for (hex, 0..) |c, i| {
            wide[i * 2] = c;
            wide[i * 2 + 1] = c;
        }
        return fromRgb(std.fmt.parseInt(u32, &wide, 16) catch return null);
    }
    if (hex.len != 6) return null;
    return fromRgb(std.fmt.parseInt(u32, hex, 16) catch return null);
}

fn fromRgb(v: u32) Color {
    return .{
        .r = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255.0,
        .g = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255.0,
        .b = @as(f32, @floatFromInt(v & 0xff)) / 255.0,
        .a = 1,
    };
}

// -- recent files -------------------------------------------------------------

pub const Recent = struct {
    path: []u8,
    title: []u8,
    /// Where the reader was, numbered from zero, and at what zoom. A zoom of
    /// zero means "fit the width", which is what a document opened without
    /// one does.
    page: u32 = 0,
    /// Points from the top of that page. This is the half that makes
    /// reopening land on the line you were reading rather than at the top of
    /// the page containing it -- and it is in points rather than pixels so
    /// that it means the same thing at another zoom and on another display.
    offset: f32 = 0,
    zoom: f32 = 0,
    opens: u32 = 0,
    /// Seconds since the epoch, as the system clock reported them.
    opened_at: i64 = 0,
};

/// Where a document was left, as the reader thinks of it. Mirrors
/// `hlidskjalf.View.Place`, converted at the boundary: Mímir does not import
/// the reader and the reader does not write SQL.
pub const Place = struct {
    page: u32 = 0,
    offset: f32 = 0,
    zoom: f32 = 0,
};

const recent_columns = "path, title, page, offset, zoom, opens, opened_at";

/// Records that a document was opened, or updates where it was left.
///
/// One statement, because the two cases differ only in whether `opens` is
/// incremented, and doing it as a read then a write is a race between two
/// readers open on the same file.
pub fn visit(lib: Library, path: []const u8, title: []const u8, at: Place, now: i64) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare(
        \\INSERT INTO recent (path, title, page, offset, zoom, opens, opened_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6)
        \\ON CONFLICT (path) DO UPDATE SET
        \\    title = excluded.title,
        \\    page = excluded.page,
        \\    offset = excluded.offset,
        \\    zoom = excluded.zoom,
        \\    opens = recent.opens + 1,
        \\    opened_at = excluded.opened_at
    );
    defer s.finalize();
    s.bindText(1, path);
    s.bindText(2, title);
    s.bindInt(3, at.page);
    s.bindFloat(4, at.offset);
    s.bindFloat(5, at.zoom);
    s.bindInt(6, now);
    try s.exec();
}

/// Updates where a document was left without counting it as another opening.
pub fn leaveAt(lib: Library, path: []const u8, at: Place) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare(
        "UPDATE recent SET page = ?2, offset = ?3, zoom = ?4 WHERE path = ?1",
    );
    defer s.finalize();
    s.bindText(1, path);
    s.bindInt(2, at.page);
    s.bindFloat(3, at.offset);
    s.bindFloat(4, at.zoom);
    try s.exec();
}

/// Where this document was left, if it has been opened before.
pub fn lastSeen(lib: Library, path: []const u8) Error!?Recent {
    var s = try lib.db.prepare("SELECT " ++ recent_columns ++ " FROM recent WHERE path = ?1");
    defer s.finalize();
    s.bindText(1, path);
    if (!try s.step()) return null;
    return try lib.readRecent(s);
}

/// The most recently opened documents, newest first.
pub fn recent(lib: Library, limit: u32) Error![]Recent {
    var out: std.ArrayList(Recent) = .empty;
    errdefer lib.freeRecents(out.items, out.items.len);

    var s = try lib.db.prepare(
        "SELECT " ++ recent_columns ++ " FROM recent ORDER BY opened_at DESC LIMIT ?1",
    );
    defer s.finalize();
    s.bindInt(1, limit);
    while (try s.step()) {
        try out.append(lib.gpa, try lib.readRecent(s));
    }
    return out.toOwnedSlice(lib.gpa);
}

fn readRecent(lib: Library, s: Db.Stmt) Error!Recent {
    const path = try lib.gpa.dupe(u8, s.columnText(0));
    errdefer lib.gpa.free(path);
    const title = try lib.gpa.dupe(u8, s.columnText(1));
    return .{
        .path = path,
        .title = title,
        .page = @intCast(@max(0, s.columnInt(2))),
        .offset = @floatCast(s.columnFloat(3)),
        .zoom = @floatCast(s.columnFloat(4)),
        .opens = @intCast(@max(0, s.columnInt(5))),
        .opened_at = s.columnInt(6),
    };
}

// -- marks ------------------------------------------------------------------

/// One mark over words -- a highlight, an underline, a strike-through or a
/// squiggle -- as the file holds it.
///
/// The box is in the page's own user-space points, which is the only
/// coordinate that survives a different zoom, a different window and a
/// different machine. See `hlidskjalf/Marks.zig`, whose `Mark` this mirrors.
pub const Mark = struct {
    id: i64 = 0,
    page: u32 = 0,
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,
    /// `#rrggbb`, or empty for the reader's accent colour. Stored as text so
    /// that the file stays something a person can read and edit.
    color: []u8 = &.{},
    /// `highlight`, `underline`, `strikeout` or `squiggly`. Empty is written
    /// as `highlight`, which is what a caller that does not say means.
    style: []u8 = &.{},
    /// The name of the anchor this line is part of; see `makeName`. Empty is
    /// written as the document's next name, an anchor of one line.
    anchor: []u8 = &.{},
    /// The reader's version of one of the file's, not a mark it made.
    /// Written, never read back: what asks is `edits`.
    edit: bool = false,
};

fn styleOf(style: []const u8) []const u8 {
    return if (style.len == 0) "highlight" else style;
}

/// Writes a mark and returns the row it was given, so the caller can
/// delete exactly this one later.
pub fn addMark(lib: Library, path: []const u8, h: Mark, now: i64) Error!i64 {
    if (lib.future) return 0;
    var buf: [name_len]u8 = undefined;
    const anchor = if (h.anchor.len != 0) h.anchor else try lib.nextName(path, &buf);
    var s = try lib.db.prepare(
        \\INSERT INTO mark (path, page, x0, y0, x1, y1, color, style, anchor, created_at, edit)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
    );
    defer s.finalize();
    s.bindText(1, path);
    s.bindInt(2, h.page);
    s.bindFloat(3, h.x0);
    s.bindFloat(4, h.y0);
    s.bindFloat(5, h.x1);
    s.bindFloat(6, h.y1);
    s.bindText(7, h.color);
    s.bindText(8, styleOf(h.style));
    s.bindText(9, anchor);
    s.bindInt(10, now);
    s.bindInt(11, @intFromBool(h.edit));
    try s.exec();
    return lib.db.lastInsertRowId();
}

/// Rewrites what can change about a mark once it exists: its colour and its
/// style. Its box and page never change -- a mark moved to other words is a
/// different mark, and is removed and added as one. What is
/// written about it is a comment on its anchor.
pub fn updateMark(lib: Library, id: i64, color: []const u8, style: []const u8) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare("UPDATE mark SET color = ?2, style = ?3 WHERE id = ?1");
    defer s.finalize();
    s.bindInt(1, id);
    s.bindText(2, color);
    s.bindText(3, styleOf(style));
    try s.exec();
}

pub fn removeMark(lib: Library, id: i64) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare("DELETE FROM mark WHERE id = ?1");
    defer s.finalize();
    s.bindInt(1, id);
    try s.exec();
}

pub fn clearMarks(lib: Library, path: []const u8) Error!u32 {
    if (lib.future) return 0;
    var s = try lib.db.prepare("DELETE FROM mark WHERE path = ?1");
    defer s.finalize();
    s.bindText(1, path);
    try s.exec();
    return lib.db.changes();
}

/// Every mark on a document, oldest first so that they are drawn in the
/// order they were made.
pub fn marks(lib: Library, path: []const u8) Error![]Mark {
    var out: std.ArrayList(Mark) = .empty;
    errdefer lib.freeMarks(out.items, out.items.len);

    var s = try lib.db.prepare(
        \\SELECT id, page, x0, y0, x1, y1, color, style, anchor FROM mark
        \\WHERE path = ?1 ORDER BY id
    );
    defer s.finalize();
    s.bindText(1, path);
    while (try s.step()) {
        const color = try lib.gpa.dupe(u8, s.columnText(6));
        errdefer lib.gpa.free(color);
        const style = try lib.gpa.dupe(u8, s.columnText(7));
        errdefer lib.gpa.free(style);
        const anchor = try lib.gpa.dupe(u8, s.columnText(8));
        errdefer lib.gpa.free(anchor);
        try out.append(lib.gpa, .{
            .id = s.columnInt(0),
            .page = @intCast(@max(0, s.columnInt(1))),
            .x0 = @floatCast(s.columnFloat(2)),
            .y0 = @floatCast(s.columnFloat(3)),
            .x1 = @floatCast(s.columnFloat(4)),
            .y1 = @floatCast(s.columnFloat(5)),
            .color = color,
            .style = style,
            .anchor = anchor,
        });
    }
    return out.toOwnedSlice(lib.gpa);
}

pub fn freeMark(lib: Library, h: Mark) void {
    lib.gpa.free(h.color);
    lib.gpa.free(h.style);
    lib.gpa.free(h.anchor);
}

pub fn freeMarks(lib: Library, list: []Mark, n: usize) void {
    for (list[0..n]) |h| lib.freeMark(h);
    if (list.len != 0) lib.gpa.free(list);
}

// -- ink ----------------------------------------------------------------------

/// One freehand stroke, as the file holds it.
///
/// The points are in the page's own user-space points, for the reason a
/// mark's box is: a stroke is a fact about the document, and a stroke
/// stored in device pixels would land somewhere else at the next zoom.
///
/// `width` is in those same points, so the pen keeps its thickness relative
/// to the type it was drawn over however far the page is scaled. A width of
/// zero means the reader's default, the way an empty `color` means its
/// accent.
pub const Stroke = struct {
    id: i64 = 0,
    page: u32 = 0,
    /// `#rrggbb`, or empty for the reader's pen colour.
    color: []u8 = &.{},
    width: f32 = 0,
    points: []Point = &.{},
    /// The anchor it is, as for a mark. A stroke is always an anchor of
    /// its own.
    anchor: []u8 = &.{},
    /// As for a mark.
    edit: bool = false,
};

/// How many characters a point takes at the precision `writePoints` uses,
/// with room for a page-sized coordinate and the space after it.
const point_chars = 24;

/// The most points a stroke may hold.
///
/// A cap and not a warning, because the thing on the other side of it is a
/// reader who held the button down for a minute: `simplify` gets a normal
/// stroke to a few dozen points, so anything near this is a runaway rather
/// than a drawing, and a row too large to read back is worse than a stroke
/// that stopped.
pub const max_points = 4096;

/// Writes a stroke and returns the row it was given.
pub fn addStroke(lib: Library, path: []const u8, k: Stroke, now: i64) Error!i64 {
    if (lib.future) return 0;
    if (k.points.len < 2 or k.points.len > max_points) return error.Failed;

    const text = try lib.gpa.alloc(u8, k.points.len * point_chars);
    defer lib.gpa.free(text);
    const encoded = writePoints(text, k.points);
    var buf: [name_len]u8 = undefined;
    const anchor = if (k.anchor.len != 0) k.anchor else try lib.nextName(path, &buf);

    var s = try lib.db.prepare(
        \\INSERT INTO ink (path, page, color, width, points, anchor, created_at, edit)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    );
    defer s.finalize();
    s.bindText(1, path);
    s.bindInt(2, k.page);
    s.bindText(3, k.color);
    s.bindFloat(4, k.width);
    s.bindText(5, encoded);
    s.bindText(6, anchor);
    s.bindInt(7, now);
    s.bindInt(8, @intFromBool(k.edit));
    try s.exec();
    return lib.db.lastInsertRowId();
}

/// Rewrites what can change about a stroke once it exists: its colour. Where
/// the pen went is not editable -- a line drawn somewhere else is a different
/// line, and is removed and drawn again as one.
pub fn updateStroke(lib: Library, id: i64, color: []const u8) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare("UPDATE ink SET color = ?2 WHERE id = ?1");
    defer s.finalize();
    s.bindInt(1, id);
    s.bindText(2, color);
    try s.exec();
}

pub fn removeStroke(lib: Library, id: i64) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare("DELETE FROM ink WHERE id = ?1");
    defer s.finalize();
    s.bindInt(1, id);
    try s.exec();
}

pub fn clearStrokes(lib: Library, path: []const u8) Error!u32 {
    if (lib.future) return 0;
    var s = try lib.db.prepare("DELETE FROM ink WHERE path = ?1");
    defer s.finalize();
    s.bindText(1, path);
    try s.exec();
    return lib.db.changes();
}

/// Every stroke on a document, oldest first, so they are drawn in the order
/// they were made -- which for opaque ink is the order they overlap in.
pub fn strokes(lib: Library, path: []const u8) Error![]Stroke {
    var out: std.ArrayList(Stroke) = .empty;
    errdefer lib.freeStrokes(out.items, out.items.len);

    var s = try lib.db.prepare(
        \\SELECT id, page, color, width, points, anchor FROM ink
        \\WHERE path = ?1 ORDER BY id
    );
    defer s.finalize();
    s.bindText(1, path);
    while (try s.step()) {
        const color = try lib.gpa.dupe(u8, s.columnText(2));
        errdefer lib.gpa.free(color);
        // A row whose points will not parse is dropped rather than returned
        // half-read: it can only have come from a hand-edit, and half a
        // stroke on the page would be a worse answer than none.
        const points = readPoints(lib.gpa, s.columnText(4)) catch {
            lib.gpa.free(color);
            continue;
        };
        if (points.len < 2) {
            lib.gpa.free(color);
            lib.gpa.free(points);
            continue;
        }
        errdefer lib.gpa.free(points);
        const anchor = try lib.gpa.dupe(u8, s.columnText(5));
        errdefer lib.gpa.free(anchor);
        try out.append(lib.gpa, .{
            .id = s.columnInt(0),
            .page = @intCast(@max(0, s.columnInt(1))),
            .color = color,
            .width = @floatCast(s.columnFloat(3)),
            .points = points,
            .anchor = anchor,
        });
    }
    return out.toOwnedSlice(lib.gpa);
}

pub fn freeStroke(lib: Library, k: Stroke) void {
    lib.gpa.free(k.color);
    lib.gpa.free(k.points);
    lib.gpa.free(k.anchor);
}

pub fn freeStrokes(lib: Library, list: []Stroke, n: usize) void {
    for (list[0..n]) |k| lib.freeStroke(k);
    if (list.len != 0) lib.gpa.free(list);
}

/// `x y x y ...`, two decimals, which is a hundredth of a point. See
/// `create` for why this is text at all.
///
/// Takes its buffer rather than allocating: the caller knows how many points
/// there are and `point_chars` says what each costs, so the one allocation
/// happens once at the call site instead of growing here.
fn writePoints(buf: []u8, points: []const Point) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (points, 0..) |p, i| {
        if (i != 0) w.writeByte(' ') catch break;
        w.print("{d:.2} {d:.2}", .{ p.x, p.y }) catch break;
    }
    return w.buffered();
}

/// The inverse. Errors on anything that is not a whole number of coordinates,
/// because a stroke with a coordinate missing is not a stroke.
fn readPoints(gpa: Allocator, text: []const u8) Error![]Point {
    var out: std.ArrayList(Point) = .empty;
    errdefer out.deinit(gpa);

    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |xs| {
        const ys = it.next() orelse return error.Failed;
        if (out.items.len == max_points) return error.Failed;
        try out.append(gpa, .{
            .x = std.fmt.parseFloat(f32, xs) catch return error.Failed,
            .y = std.fmt.parseFloat(f32, ys) catch return error.Failed,
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeRecent(lib: Library, r: Recent) void {
    lib.gpa.free(r.path);
    lib.gpa.free(r.title);
}

pub fn freeRecents(lib: Library, list: []Recent, n: usize) void {
    for (list[0..n]) |r| lib.freeRecent(r);
    if (list.len != 0) lib.gpa.free(list);
}

pub fn forget(lib: Library, path: []const u8) Error!u32 {
    if (lib.future) return 0;
    var s = try lib.db.prepare("DELETE FROM recent WHERE path = ?1");
    defer s.finalize();
    s.bindText(1, path);
    try s.exec();
    return lib.db.changes();
}

pub fn forgetAll(lib: Library) Error!void {
    if (lib.future) return;
    try lib.db.exec("DELETE FROM recent");
}

// -- comments -----------------------------------------------------------------

/// One comment, as the file holds it.
pub const Comment = struct {
    id: i64 = 0,
    /// The name of the anchor it is on: the `anchor` of the marks it is about.
    anchor: []u8 = &.{},
    /// Its own name. The first comment on an anchor has the anchor's, since
    /// in a PDF it is the anchor's `/Contents` and has no annotation of its
    /// own to carry another.
    nm: []u8 = &.{},
    /// The page of the anchor it is on, from 0. What tells two of another
    /// program's annotations apart when they have one name on two pages,
    /// which the standard allows (§12.5.2); fenrir's own names are the
    /// document's and need no page.
    page: u32 = 0,
    text: []u8 = &.{},
    /// As for a mark: the file's comment, changed, rather than a new one.
    edit: bool = false,
    /// Seconds since the epoch. `modified_at` is what a PDF's `/M` will say.
    created_at: i64 = 0,
    modified_at: i64 = 0,
};

/// Writes a comment and returns its row. The caller names it, because the
/// name has to be known before the row exists: a link made in the same
/// breath refers to it.
pub fn addComment(lib: Library, path: []const u8, c: Comment, now: i64) Error!i64 {
    if (lib.future) return 0;
    var s = try lib.db.prepare(
        \\INSERT INTO comment (path, anchor, nm, page, text, created_at, modified_at, edit)
        \\VALUES (?1, ?2, ?3, ?6, ?4, ?5, ?5, ?7)
    );
    defer s.finalize();
    s.bindText(1, path);
    s.bindText(2, c.anchor);
    s.bindText(3, c.nm);
    s.bindText(4, c.text);
    s.bindInt(5, now);
    s.bindInt(6, c.page);
    s.bindInt(7, @intFromBool(c.edit));
    try s.exec();
    return lib.db.lastInsertRowId();
}

/// A comment's text is the one thing about it that changes. Moved to another
/// anchor it would be another comment, and is removed and added as one.
pub fn updateComment(lib: Library, id: i64, text: []const u8, now: i64) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare("UPDATE comment SET text = ?2, modified_at = ?3 WHERE id = ?1");
    defer s.finalize();
    s.bindInt(1, id);
    s.bindText(2, text);
    s.bindInt(3, now);
    try s.exec();
}

pub fn removeComment(lib: Library, id: i64) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare("DELETE FROM comment WHERE id = ?1");
    defer s.finalize();
    s.bindInt(1, id);
    try s.exec();
}

pub fn clearComments(lib: Library, path: []const u8) Error!u32 {
    if (lib.future) return 0;
    var s = try lib.db.prepare("DELETE FROM comment WHERE path = ?1");
    defer s.finalize();
    s.bindText(1, path);
    try s.exec();
    return lib.db.changes();
}

/// Every comment on a document, oldest first: the order a thread reads in.
pub fn comments(lib: Library, path: []const u8) Error![]Comment {
    var out: std.ArrayList(Comment) = .empty;
    errdefer lib.freeComments(out.items, out.items.len);

    var s = try lib.db.prepare(
        \\SELECT id, anchor, nm, text, created_at, modified_at, page FROM comment
        \\WHERE path = ?1 ORDER BY id
    );
    defer s.finalize();
    s.bindText(1, path);
    while (try s.step()) {
        const anchor = try lib.gpa.dupe(u8, s.columnText(1));
        errdefer lib.gpa.free(anchor);
        const nm = try lib.gpa.dupe(u8, s.columnText(2));
        errdefer lib.gpa.free(nm);
        const text = try lib.gpa.dupe(u8, s.columnText(3));
        errdefer lib.gpa.free(text);
        try out.append(lib.gpa, .{
            .id = s.columnInt(0),
            .anchor = anchor,
            .nm = nm,
            .text = text,
            .created_at = s.columnInt(4),
            .modified_at = s.columnInt(5),
            .page = @intCast(@max(0, s.columnInt(6))),
        });
    }
    return out.toOwnedSlice(lib.gpa);
}

pub fn freeComment(lib: Library, c: Comment) void {
    lib.gpa.free(c.anchor);
    lib.gpa.free(c.nm);
    lib.gpa.free(c.text);
}

pub fn freeComments(lib: Library, list: []Comment, n: usize) void {
    for (list[0..n]) |c| lib.freeComment(c);
    if (list.len != 0) lib.gpa.free(list);
}

// -- links --------------------------------------------------------------------

/// Two comments joined, as the file holds it.
///
/// Both ends are names and never rows, so a link survives the PDF being
/// rewritten by a program that renumbers its objects. `from` is always in
/// the document the row is filed under; `to` is too unless `other` names
/// the document it is in, by `/ID`.
pub const Link = struct {
    id: i64 = 0,
    from: []u8 = &.{},
    to: []u8 = &.{},
    /// The other document's `/ID` as hex, or empty for this one.
    other: []u8 = &.{},
    /// `supports`, `contradicts`, or whatever the reader called it. Empty
    /// for a link with no label, which is most of them.
    label: []u8 = &.{},
};

pub fn addLink(lib: Library, path: []const u8, l: Link, now: i64) Error!i64 {
    if (lib.future) return 0;
    var s = try lib.db.prepare(
        \\INSERT INTO link (path, from_nm, to_nm, other, label, created_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    );
    defer s.finalize();
    s.bindText(1, path);
    s.bindText(2, l.from);
    s.bindText(3, l.to);
    s.bindText(4, l.other);
    s.bindText(5, l.label);
    s.bindInt(6, now);
    try s.exec();
    return lib.db.lastInsertRowId();
}

pub fn removeLink(lib: Library, id: i64) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare("DELETE FROM link WHERE id = ?1");
    defer s.finalize();
    s.bindInt(1, id);
    try s.exec();
}

pub fn clearLinks(lib: Library, path: []const u8) Error!u32 {
    if (lib.future) return 0;
    var s = try lib.db.prepare("DELETE FROM link WHERE path = ?1");
    defer s.finalize();
    s.bindText(1, path);
    try s.exec();
    return lib.db.changes();
}

/// Every link filed under a document, oldest first.
pub fn links(lib: Library, path: []const u8) Error![]Link {
    var out: std.ArrayList(Link) = .empty;
    errdefer lib.freeLinks(out.items, out.items.len);

    var s = try lib.db.prepare(
        \\SELECT id, from_nm, to_nm, other, label FROM link
        \\WHERE path = ?1 ORDER BY id
    );
    defer s.finalize();
    s.bindText(1, path);
    while (try s.step()) {
        const from = try lib.gpa.dupe(u8, s.columnText(1));
        errdefer lib.gpa.free(from);
        const to = try lib.gpa.dupe(u8, s.columnText(2));
        errdefer lib.gpa.free(to);
        const other = try lib.gpa.dupe(u8, s.columnText(3));
        errdefer lib.gpa.free(other);
        const label = try lib.gpa.dupe(u8, s.columnText(4));
        errdefer lib.gpa.free(label);
        try out.append(lib.gpa, .{
            .id = s.columnInt(0),
            .from = from,
            .to = to,
            .other = other,
            .label = label,
        });
    }
    return out.toOwnedSlice(lib.gpa);
}

pub fn freeLink(lib: Library, l: Link) void {
    lib.gpa.free(l.from);
    lib.gpa.free(l.to);
    lib.gpa.free(l.other);
    lib.gpa.free(l.label);
}

pub fn freeLinks(lib: Library, list: []Link, n: usize) void {
    for (list[0..n]) |l| lib.freeLink(l);
    if (list.len != 0) lib.gpa.free(list);
}

// -- what the file still holds ----------------------------------------------

/// Something the reader deleted that the file it was read from holds: an
/// anchor, by its annotation's name, or a comment. A deletion leaves no
/// row of its own to win with, so without this one the file would put it
/// back on the next open.
pub const Gone = struct {
    nm: []u8,
    /// The page of the annotation, for a name of another program's, which
    /// is its page's; see `Comment.page`.
    page: u32 = 0,
    /// A comment rather than an anchor. The first comment on an anchor has
    /// the anchor's name, and clearing it empties `/Contents` and leaves
    /// the highlight, so the two are told apart here and not by name.
    comment: bool = false,
};

/// Records a deletion. Said twice it is one row.
pub fn addGone(lib: Library, path: []const u8, g: Gone) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare(
        \\INSERT OR IGNORE INTO gone (path, nm, page, comment) VALUES (?1, ?2, ?3, ?4)
    );
    defer s.finalize();
    s.bindText(1, path);
    s.bindText(2, g.nm);
    s.bindInt(3, g.page);
    s.bindInt(4, @intFromBool(g.comment));
    try s.exec();
}

/// Every deletion recorded on a document, oldest first.
pub fn gones(lib: Library, path: []const u8) Error![]Gone {
    var out: std.ArrayList(Gone) = .empty;
    errdefer lib.freeGones(out.items, out.items.len);
    var s = try lib.db.prepare("SELECT nm, page, comment FROM gone WHERE path = ?1 ORDER BY id");
    defer s.finalize();
    s.bindText(1, path);
    while (try s.step()) {
        const nm = try lib.gpa.dupe(u8, s.columnText(0));
        errdefer lib.gpa.free(nm);
        try out.append(lib.gpa, .{
            .nm = nm,
            .page = @intCast(@max(0, s.columnInt(1))),
            .comment = s.columnInt(2) != 0,
        });
    }
    return out.toOwnedSlice(lib.gpa);
}

pub fn freeGones(lib: Library, list: []Gone, n: usize) void {
    for (list[0..n]) |g| lib.gpa.free(g.nm);
    if (list.len != 0) lib.gpa.free(list);
}

/// The names whose rows are the reader's versions of the file's, and so
/// never another fenrir's under the same name: a mark's or a stroke's
/// anchor, a comment's own. The caller owns them.
pub fn edits(lib: Library, path: []const u8) Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |nm| lib.gpa.free(nm);
        out.deinit(lib.gpa);
    }
    var s = try lib.db.prepare(
        \\SELECT anchor FROM mark WHERE path = ?1 AND edit = 1
        \\UNION SELECT anchor FROM ink WHERE path = ?1 AND edit = 1
        \\UNION SELECT nm FROM comment WHERE path = ?1 AND edit = 1
    );
    defer s.finalize();
    s.bindText(1, path);
    while (try s.step()) {
        const nm = try lib.gpa.dupe(u8, s.columnText(0));
        errdefer lib.gpa.free(nm);
        try out.append(lib.gpa, nm);
    }
    return out.toOwnedSlice(lib.gpa);
}

pub fn freeNames(lib: Library, list: [][]u8) void {
    for (list) |nm| lib.gpa.free(nm);
    if (list.len != 0) lib.gpa.free(list);
}

/// Empties a document's journal: every row the save just wrote into its
/// file, and the record of that save. Its links stay, being nothing a PDF
/// holds yet.
pub fn clearJournal(lib: Library, path: []const u8) Error!void {
    if (lib.future) return;
    for ([_][]const u8{
        "DELETE FROM mark WHERE path = ?1",
        "DELETE FROM ink WHERE path = ?1",
        "DELETE FROM comment WHERE path = ?1",
        "DELETE FROM gone WHERE path = ?1",
        "DELETE FROM naming WHERE path = ?1",
        "DELETE FROM appending WHERE path = ?1",
    }) |sql| {
        var s = try lib.db.prepare(sql);
        defer s.finalize();
        s.bindText(1, path);
        try s.exec();
    }
}

/// Whether a document has anything in its journal: what a save would
/// write, and what closing an unchanged document finds none of.
pub fn journaled(lib: Library, path: []const u8) Error!bool {
    var s = try lib.db.prepare(
        \\SELECT EXISTS (SELECT 1 FROM mark WHERE path = ?1)
        \\OR EXISTS (SELECT 1 FROM ink WHERE path = ?1)
        \\OR EXISTS (SELECT 1 FROM comment WHERE path = ?1)
        \\OR EXISTS (SELECT 1 FROM gone WHERE path = ?1)
    );
    defer s.finalize();
    s.bindText(1, path);
    return try s.step() and s.columnInt(0) != 0;
}

// -- a save on its way --------------------------------------------------------

/// What is about to be appended to a document's file, written before it is:
/// what tells the next open whether the writer died halfway.
pub const Appending = struct {
    /// The file's length before.
    held: u64,
    /// A hash of the bytes before it.
    tail: u64,
    /// The update, owned by the caller.
    bytes: []u8,
    /// It took the document's marks out of the file rather than putting
    /// them in: finished, it leaves the rows, which are the marks now.
    out: bool = false,
};

pub fn recordAppend(lib: Library, path: []const u8, a: struct { held: u64, tail: u64, bytes: []const u8, out: bool = false }) Error!void {
    if (lib.future) return;
    var hex: [16]u8 = undefined;
    var s = try lib.db.prepare("INSERT OR REPLACE INTO appending (path, held, tail, bytes, out) VALUES (?1, ?2, ?3, ?4, ?5)");
    defer s.finalize();
    s.bindText(1, path);
    s.bindInt(2, @intCast(a.held));
    s.bindText(3, std.fmt.bufPrint(&hex, "{x:0>16}", .{a.tail}) catch unreachable);
    s.bindBlob(4, a.bytes);
    s.bindInt(5, @intFromBool(a.out));
    try s.exec();
}

/// The save a document's file was last left in the middle of, or null.
pub fn appending(lib: Library, path: []const u8) Error!?Appending {
    var s = try lib.db.prepare("SELECT held, tail, bytes, out FROM appending WHERE path = ?1");
    defer s.finalize();
    s.bindText(1, path);
    if (!try s.step()) return null;
    return .{
        .held = @intCast(@max(0, s.columnInt(0))),
        .tail = std.fmt.parseInt(u64, s.columnText(1), 16) catch 0,
        .bytes = try lib.gpa.dupe(u8, s.columnBlob(2)),
        .out = s.columnInt(3) != 0,
    };
}

/// Forgets what the journal said about the file's own annotations -- what
/// was deleted of them, and the names given those that had none -- once
/// the file holds none of the reader's: after its marks were taken out.
pub fn forgetFile(lib: Library, path: []const u8) Error!void {
    if (lib.future) return;
    for ([_][]const u8{
        "DELETE FROM gone WHERE path = ?1",
        "DELETE FROM naming WHERE path = ?1",
        "DELETE FROM appending WHERE path = ?1",
    }) |sql| {
        var s = try lib.db.prepare(sql);
        defer s.finalize();
        s.bindText(1, path);
        try s.exec();
    }
}

pub fn clearAppend(lib: Library, path: []const u8) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare("DELETE FROM appending WHERE path = ?1");
    defer s.finalize();
    s.bindText(1, path);
    try s.exec();
}

// -- documents ----------------------------------------------------------------

/// The most of an `/ID` kept, as hex. The standard's are sixteen bytes; a
/// longer one keeps its first sixty-four, which no two files share by chance.
pub const id_hex_len = 128;

/// An `/ID` as the library holds it: lower-case hex, so that it reads in the
/// file and compares as text.
pub fn hexId(buf: *[id_hex_len]u8, raw: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    const n = @min(raw.len, id_hex_len / 2);
    for (raw[0..n], 0..) |b, i| {
        buf[i * 2] = digits[b >> 4];
        buf[i * 2 + 1] = digits[b & 15];
    }
    return buf[0 .. n * 2];
}

/// Writes down a document's `/ID` -- the first of the trailer's two strings,
/// as hex -- beside its path. Empty for a file that has none, which a later
/// save will give one.
pub fn setFileId(lib: Library, path: []const u8, file_id: []const u8) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare(
        \\INSERT INTO document (path, file_id) VALUES (?1, ?2)
        \\ON CONFLICT (path) DO UPDATE SET file_id = excluded.file_id
    );
    defer s.finalize();
    s.bindText(1, path);
    s.bindText(2, file_id);
    try s.exec();
}

/// The `/ID` a document was last seen with, or null when it has not been
/// seen or had none. The caller owns it.
pub fn fileId(lib: Library, path: []const u8) Error!?[]u8 {
    var s = try lib.db.prepare("SELECT file_id FROM document WHERE path = ?1");
    defer s.finalize();
    s.bindText(1, path);
    if (!try s.step()) return null;
    const text = s.columnText(0);
    if (text.len == 0) return null;
    return try lib.gpa.dupe(u8, text);
}

/// Where a document's marks are kept when it says for itself -- `pdf` or
/// `library`, as `fenrir marks --store` left it -- or null, for wherever
/// the `store` setting says. The caller owns it.
pub fn storeOf(lib: Library, path: []const u8) Error!?[]u8 {
    var s = try lib.db.prepare("SELECT store FROM document WHERE path = ?1");
    defer s.finalize();
    s.bindText(1, path);
    if (!try s.step()) return null;
    const text = s.columnText(0);
    if (text.len == 0) return null;
    return try lib.gpa.dupe(u8, text);
}

pub fn setStore(lib: Library, path: []const u8, store: []const u8) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare(
        \\INSERT INTO document (path, store) VALUES (?1, ?2)
        \\ON CONFLICT (path) DO UPDATE SET store = excluded.store
    );
    defer s.finalize();
    s.bindText(1, path);
    s.bindText(2, store);
    try s.exec();
}

/// Where the document with this `/ID` was seen, which is the first place a
/// link into it looks. When copies were opened from two places, the one
/// recorded later. The caller owns it.
pub fn pathOf(lib: Library, file_id: []const u8) Error!?[]u8 {
    if (file_id.len == 0) return null;
    var s = try lib.db.prepare("SELECT path FROM document WHERE file_id = ?1 ORDER BY id DESC LIMIT 1");
    defer s.finalize();
    s.bindText(1, file_id);
    if (!try s.step()) return null;
    return try lib.gpa.dupe(u8, s.columnText(0));
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn memory() !Library {
    return Library.open(testing.allocator, ":memory:");
}

test "a fresh database is created at the schema this build knows" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();
    try testing.expectEqual(schema_version, try lib.userVersion());
    // Creating again is a no-op, which is what makes opening an existing
    // file the same code path as making one.
    try lib.create();
    try testing.expectEqual(schema_version, try lib.userVersion());
}

test "a setting round-trips, overwrites, and disappears" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    try testing.expect((try lib.get("author")) == null);
    try lib.setAuthor("Nahid Hasan");
    {
        const name = (try lib.author()).?;
        defer testing.allocator.free(name);
        try testing.expectEqualStrings("Nahid Hasan", name);
    }
    try lib.setAuthor("Someone Else");
    {
        const name = (try lib.author()).?;
        defer testing.allocator.free(name);
        try testing.expectEqualStrings("Someone Else", name);
    }
    try lib.remove("author");
    try testing.expect((try lib.author()) == null);
}

test "a colour survives the trip through the file" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    try lib.setAccent(.{ .r = 1, .g = 0.5, .b = 0, .a = 1 });
    const c = (try lib.accent()).?;
    try testing.expectApproxEqAbs(@as(f32, 1), c.r, 0.005);
    try testing.expectApproxEqAbs(@as(f32, 0.5), c.g, 0.005);
    try testing.expectApproxEqAbs(@as(f32, 0), c.b, 0.005);

    // And it is stored as something a person can read and edit.
    const text = (try lib.get("accent")).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("#ff8000", text);
}

test "colours are named, hashed, short or refused" {
    try testing.expectEqual(@as(?Color, null), parseColor("not a colour"));
    try testing.expectEqual(@as(?Color, null), parseColor("#ff00"));
    try testing.expectApproxEqAbs(@as(f32, 1), parseColor("#fff").?.g, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), parseColor("ffffff").?.b, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), parseColor("black").?.r, 0.001);
    // Case is not a thing a person should have to get right.
    try testing.expectEqual(parseColor("Yellow").?.r, parseColor("yellow").?.r);
}

test "a document is remembered where it was left, and counted once per opening" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    try lib.visit("a.pdf", "A", .{ .page = 3, .zoom = 1.5 }, 100);
    try lib.visit("b.pdf", "B", .{}, 200);
    try lib.visit("a.pdf", "A", .{ .page = 7, .offset = 120, .zoom = 2.0 }, 300);

    const seen = (try lib.lastSeen("a.pdf")).?;
    defer lib.freeRecent(seen);
    try testing.expectEqual(@as(u32, 7), seen.page);
    try testing.expectApproxEqAbs(@as(f32, 2.0), seen.zoom, 0.001);
    // Two openings of the same path are one row, opened twice.
    try testing.expectEqual(@as(u32, 2), seen.opens);

    // Leaving somewhere else moves the place without counting a visit.
    try lib.leaveAt("a.pdf", .{ .page = 9, .zoom = 1.0 });
    const later = (try lib.lastSeen("a.pdf")).?;
    defer lib.freeRecent(later);
    try testing.expectEqual(@as(u32, 9), later.page);
    try testing.expectEqual(@as(u32, 2), later.opens);

    // Newest first, whatever order they were written in.
    const list = try lib.recent(10);
    defer lib.freeRecents(list, list.len);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("a.pdf", list[0].path);
    try testing.expectEqualStrings("b.pdf", list[1].path);
}

test "forgetting one leaves the others, and forgetting all leaves none" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    try lib.visit("a.pdf", "A", .{}, 1);
    try lib.visit("b.pdf", "B", .{}, 2);
    try testing.expectEqual(@as(u32, 1), try lib.forget("a.pdf"));
    try testing.expectEqual(@as(u32, 0), try lib.forget("a.pdf"));
    {
        const list = try lib.recent(10);
        defer lib.freeRecents(list, list.len);
        try testing.expectEqual(@as(usize, 1), list.len);
    }

    try lib.forgetAll();
    const empty = try lib.recent(10);
    defer lib.freeRecents(empty, empty.len);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "a file from a newer fenrir is read and not written" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();
    try lib.visit("a.pdf", "A", .{ .page = 4, .zoom = 1 }, 1);

    // What a database written by a later version looks like from here.
    try lib.db.exec("PRAGMA user_version = 99");
    var future = Library{ .gpa = testing.allocator, .db = lib.db, .future = true };
    try future.set("author", "nobody");
    try future.visit("b.pdf", "B", .{}, 2);
    try testing.expect((try future.get("author")) == null);

    // And what was already there still reads.
    const seen = (try future.lastSeen("a.pdf")).?;
    defer lib.freeRecent(seen);
    try testing.expectEqual(@as(u32, 4), seen.page);
}

test "the place in a page is remembered, not just which page" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    // Two thirds of the way down page 7, at 150%.
    try lib.visit("paper.pdf", "paper", .{ .page = 7, .offset = 512.5, .zoom = 1.5 }, 100);
    const seen = (try lib.lastSeen("paper.pdf")).?;
    defer lib.freeRecent(seen);
    try testing.expectEqual(@as(u32, 7), seen.page);
    try testing.expectApproxEqAbs(@as(f32, 512.5), seen.offset, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.5), seen.zoom, 0.001);

    // And leaving somewhere else moves all three together, so a reader that
    // scrolled up the same page is not put back where it started.
    try lib.leaveAt("paper.pdf", .{ .page = 7, .offset = 20, .zoom = 1.5 });
    const later = (try lib.lastSeen("paper.pdf")).?;
    defer lib.freeRecent(later);
    try testing.expectApproxEqAbs(@as(f32, 20), later.offset, 0.01);
}

test "a highlight round-trips, and is deleted by the id it was given" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    const id = try lib.addMark("a.pdf", .{
        .page = 2,
        .x0 = 100,
        .y0 = 700,
        .x1 = 220,
        .y1 = 712,
        .color = @constCast("#f7e733"),
    }, 1000);
    try testing.expect(id != 0);
    _ = try lib.addMark("a.pdf", .{ .page = 4, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1001);
    _ = try lib.addMark("b.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1002);

    {
        const list = try lib.marks("a.pdf");
        defer lib.freeMarks(list, list.len);
        // This document's own, oldest first, so they redraw in the order they
        // were made.
        try testing.expectEqual(@as(usize, 2), list.len);
        try testing.expectEqual(@as(u32, 2), list[0].page);
        try testing.expectApproxEqAbs(@as(f32, 100), list[0].x0, 0.01);
        try testing.expectApproxEqAbs(@as(f32, 712), list[0].y1, 0.01);
        try testing.expectEqualStrings("#f7e733", list[0].color);
        try testing.expectEqual(@as(u32, 4), list[1].page);
    }

    // Deleting one takes exactly that row, and leaves the other document's
    // marks alone.
    try lib.removeMark(id);
    {
        const list = try lib.marks("a.pdf");
        defer lib.freeMarks(list, list.len);
        try testing.expectEqual(@as(usize, 1), list.len);
        try testing.expectEqual(@as(u32, 4), list[0].page);
    }

    try testing.expectEqual(@as(u32, 1), try lib.clearMarks("a.pdf"));
    {
        const list = try lib.marks("b.pdf");
        defer lib.freeMarks(list, list.len);
        try testing.expectEqual(@as(usize, 1), list.len);
    }
}

test "forgetting a document does not throw away what was highlighted in it" {
    // Deliberate: a recent-files list is a convenience and a highlight is
    // something someone made. Clearing the first must not silently destroy
    // the second, which is why `highlight` keys on the path rather than on a
    // foreign key into `recent`.
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    try lib.visit("a.pdf", "A", .{}, 1);
    _ = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1);
    try lib.forgetAll();

    const list = try lib.marks("a.pdf");
    defer lib.freeMarks(list, list.len);
    try testing.expectEqual(@as(usize, 1), list.len);
}

test "a highlight's colour and style can be changed in place" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    const id = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1);
    {
        // Not saying is saying `highlight`, in the file as well.
        const list = try lib.marks("a.pdf");
        defer lib.freeMarks(list, list.len);
        try testing.expectEqualStrings("highlight", list[0].style);
    }
    try lib.updateMark(id, "#3fa34d", "squiggly");

    const list = try lib.marks("a.pdf");
    defer lib.freeMarks(list, list.len);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(id, list[0].id);
    try testing.expectEqualStrings("#3fa34d", list[0].color);
    try testing.expectEqualStrings("squiggly", list[0].style);
}

test "a stroke round-trips through the file, points and all" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    var points = [_]Point{
        .{ .x = 72.5, .y = 700.25 },
        .{ .x = 90, .y = 690 },
        .{ .x = 110.75, .y = 705.5 },
    };
    const id = try lib.addStroke("a.pdf", .{
        .page = 2,
        .color = @constCast("#c04040"),
        .width = 1.5,
        .points = &points,
    }, 7);

    const list = try lib.strokes("a.pdf");
    defer lib.freeStrokes(list, list.len);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(id, list[0].id);
    try testing.expectEqual(@as(u32, 2), list[0].page);
    try testing.expectEqualStrings("#c04040", list[0].color);
    try testing.expectApproxEqAbs(@as(f32, 1.5), list[0].width, 0.001);
    try testing.expectEqual(points.len, list[0].points.len);
    for (points, list[0].points) |want, got| {
        try testing.expectApproxEqAbs(want.x, got.x, 0.01);
        try testing.expectApproxEqAbs(want.y, got.y, 0.01);
    }

    try lib.removeStroke(id);
    const gone = try lib.strokes("a.pdf");
    defer lib.freeStrokes(gone, gone.len);
    try testing.expectEqual(@as(usize, 0), gone.len);
}

test "ink and highlights are two tables and are cleared separately" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    var points = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 } };
    _ = try lib.addStroke("a.pdf", .{ .page = 0, .points = &points }, 1);
    _ = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1);

    try testing.expectEqual(@as(u32, 1), try lib.clearStrokes("a.pdf"));

    const list = try lib.marks("a.pdf");
    defer lib.freeMarks(list, list.len);
    try testing.expectEqual(@as(usize, 1), list.len);
}

test "a stroke of one point, or one whose points will not parse, is not a stroke" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    // A pen put down and lifted without moving. Refused on the way in, so
    // nothing downstream has to draw a line between one point and itself.
    var one = [_]Point{.{ .x = 5, .y = 5 }};
    try testing.expectError(error.Failed, lib.addStroke("a.pdf", .{ .points = &one }, 1));

    // A row somebody edited by hand into nonsense: dropped on the way out,
    // rather than returned as the half of it that did parse.
    try lib.db.exec(
        \\INSERT INTO ink (path, page, color, width, points, created_at)
        \\VALUES ('a.pdf', 0, '', 1, '10 20 30', 0);
    );
    const list = try lib.strokes("a.pdf");
    defer lib.freeStrokes(list, list.len);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "a stroke's colour changes in place, and it keeps its anchor" {
    // What is written about a stroke is a comment on its anchor, so the
    // anchor is the one thing about it that must not move with an edit.
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    var points = [_]Point{ .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 40 } };
    const id = try lib.addStroke("a.pdf", .{ .page = 1, .points = &points }, 7);
    try lib.updateStroke(id, "#c04040");

    const list = try lib.strokes("a.pdf");
    defer lib.freeStrokes(list, list.len);
    try testing.expectEqualStrings("#c04040", list[0].color);
    try testing.expectEqualStrings("f1", list[0].anchor);
}

test "a name is f and base 36, and only fenrir's are counted" {
    var buf: [name_len]u8 = undefined;
    try testing.expectEqualStrings("f1", makeName(&buf, 1));
    try testing.expectEqualStrings("fz", makeName(&buf, 35));
    try testing.expectEqualStrings("f10", makeName(&buf, 36));
    try testing.expectEqual(@as(?u64, 36), nameNumber("f10"));
    const most = std.math.maxInt(u64);
    try testing.expectEqual(@as(?u64, most), nameNumber(makeName(&buf, most)));

    // Another program's `/NM`, and the forms fenrir never writes.
    for ([_][]const u8{ "f", "F1", "f01", "f1A", "f-1", "8a7d-41c2", "fzzzzzzzzzzzzz" }) |other| {
        try testing.expectEqual(@as(?u64, null), nameNumber(other));
    }
}

test "a mark written without an anchor is the next name, and comments count" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    _ = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1);
    var points = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 9, .y = 9 } };
    _ = try lib.addStroke("a.pdf", .{ .points = &points }, 1);
    // A reply's name is past every anchor's, and another program's is not
    // a number at all.
    _ = try lib.addComment("a.pdf", .{ .anchor = @constCast("f1"), .nm = @constCast("f9"), .text = @constCast("why") }, 1);
    _ = try lib.addComment("a.pdf", .{ .anchor = @constCast("f2"), .nm = @constCast("{8a7d-41c2}") }, 1);
    _ = try lib.addMark("a.pdf", .{ .page = 1, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1);
    // Each document counts its own.
    _ = try lib.addMark("b.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1);

    const list = try lib.marks("a.pdf");
    defer lib.freeMarks(list, list.len);
    try testing.expectEqualStrings("f1", list[0].anchor);
    try testing.expectEqualStrings("fa", list[1].anchor);
    const ink = try lib.strokes("a.pdf");
    defer lib.freeStrokes(ink, ink.len);
    try testing.expectEqualStrings("f2", ink[0].anchor);
    try testing.expectEqual(@as(u64, 10), try lib.highestName("a.pdf"));
    try testing.expectEqual(@as(u64, 1), try lib.highestName("b.pdf"));

    // A writer that names its own anchor keeps it, which is how six lines
    // of one selection are one anchor.
    _ = try lib.addMark("a.pdf", .{ .page = 2, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4, .anchor = @constCast("fa") }, 1);
    try testing.expectEqual(@as(u64, 10), try lib.highestName("a.pdf"));
}

test "a name handed out stays handed out when its row goes" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    const id = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1);
    try lib.removeMark(id);
    // Counted from the rows alone this would be 0, and the next mark f1.
    try testing.expectEqual(@as(u64, 1), try lib.highestName("a.pdf"));

    // A reader that handed names out without writing rows says so, and is
    // never taken down by a lower number.
    try lib.noteName("a.pdf", 40);
    try lib.noteName("a.pdf", 7);
    try testing.expectEqual(@as(u64, 40), try lib.highestName("a.pdf"));
    try testing.expectEqual(@as(u64, 0), try lib.highestName("b.pdf"));
    // The `/ID` and the count share a row, and neither writes over the other.
    try lib.setFileId("a.pdf", "00ff");
    try testing.expectEqual(@as(u64, 40), try lib.highestName("a.pdf"));
    const file = (try lib.fileId("a.pdf")).?;
    defer testing.allocator.free(file);
    try testing.expectEqualStrings("00ff", file);
}

test "a name moved is moved in every row that says it, and nowhere else" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    _ = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4, .anchor = @constCast("f3") }, 1);
    _ = try lib.addComment("a.pdf", .{ .anchor = @constCast("f3"), .nm = @constCast("f3"), .text = @constCast("why") }, 1);
    _ = try lib.addLink("a.pdf", .{ .from = @constCast("f3"), .to = @constCast("f3"), .other = @constCast("abcd") }, 1);
    _ = try lib.addMark("b.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4, .anchor = @constCast("f3") }, 1);
    try lib.renumber("a.pdf", "f3", "f9");

    const list = try lib.marks("a.pdf");
    defer lib.freeMarks(list, list.len);
    try testing.expectEqualStrings("f9", list[0].anchor);
    const said = try lib.comments("a.pdf");
    defer lib.freeComments(said, said.len);
    try testing.expectEqualStrings("f9", said[0].anchor);
    try testing.expectEqualStrings("f9", said[0].nm);
    // The far end of a link names another document's f3, which is not this one.
    const joined = try lib.links("a.pdf");
    defer lib.freeLinks(joined, joined.len);
    try testing.expectEqualStrings("f9", joined[0].from);
    try testing.expectEqualStrings("f3", joined[0].to);
    const other = try lib.marks("b.pdf");
    defer lib.freeMarks(other, other.len);
    try testing.expectEqualStrings("f3", other[0].anchor);
}

test "an unnamed annotation is named by its page and its shape, and the name counts" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    try lib.nameAnnotation("a.pdf", 4, 0xdead_beef_0000_0001, "f12");
    _ = try lib.addComment("a.pdf", .{ .anchor = @constCast("f12"), .nm = @constCast("f12"), .page = 4, .text = @constCast("seen") }, 1);
    const named = try lib.namings("a.pdf");
    defer lib.freeNamings(named, named.len);
    try testing.expectEqual(@as(usize, 1), named.len);
    try testing.expectEqual(@as(u32, 4), named[0].page);
    try testing.expectEqual(@as(u64, 0xdead_beef_0000_0001), named[0].shape);
    try testing.expectEqualStrings("f12", named[0].nm);
    try testing.expectEqual(@as(u64, 38), try lib.highestName("a.pdf"));

    const said = try lib.comments("a.pdf");
    defer lib.freeComments(said, said.len);
    try testing.expectEqual(@as(u32, 4), said[0].page);
}

test "a deletion of the file's is a row of its own, and an edit is told from a new mark" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    // The anchor gone and, apart from it, the note cleared on another.
    try lib.addGone("a.pdf", .{ .nm = @constCast("305e35fa"), .page = 2 });
    try lib.addGone("a.pdf", .{ .nm = @constCast("305e35fa"), .page = 2 });
    try lib.addGone("a.pdf", .{ .nm = @constCast("f4"), .comment = true });
    const gone = try lib.gones("a.pdf");
    defer lib.freeGones(gone, gone.len);
    try testing.expectEqual(@as(usize, 2), gone.len);
    try testing.expectEqualStrings("305e35fa", gone[0].nm);
    try testing.expectEqual(@as(u32, 2), gone[0].page);
    try testing.expect(!gone[0].comment);
    try testing.expect(gone[1].comment);

    _ = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4, .anchor = @constCast("f1") }, 1);
    _ = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4, .anchor = @constCast("f2"), .edit = true }, 1);
    _ = try lib.addComment("a.pdf", .{ .anchor = @constCast("f2"), .nm = @constCast("f5"), .text = @constCast("x"), .edit = true }, 1);
    const changed = try lib.edits("a.pdf");
    defer lib.freeNames(changed);
    try testing.expectEqual(@as(usize, 2), changed.len);
    for (changed) |nm| try testing.expect(std.mem.eql(u8, nm, "f2") or std.mem.eql(u8, nm, "f5"));
}

test "a save on its way is recorded as bytes, and the journal goes once it is in" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    // Binary, noughts and all: an update is not text.
    const update = "1 0 obj\x00\xff<<>>endobj";
    try lib.recordAppend("a.pdf", .{ .held = 1234, .tail = 0xfeed, .bytes = update });
    const got = (try lib.appending("a.pdf")).?;
    defer testing.allocator.free(got.bytes);
    try testing.expectEqual(@as(u64, 1234), got.held);
    try testing.expectEqual(@as(u64, 0xfeed), got.tail);
    try testing.expectEqualSlices(u8, update, got.bytes);

    _ = try lib.addMark("a.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4, .anchor = @constCast("f1") }, 1);
    _ = try lib.addLink("a.pdf", .{ .from = @constCast("f1"), .to = @constCast("f1") }, 1);
    try lib.addGone("a.pdf", .{ .nm = @constCast("f9") });
    try testing.expect(try lib.journaled("a.pdf"));
    try lib.clearJournal("a.pdf");
    try testing.expect(!try lib.journaled("a.pdf"));
    try testing.expect(try lib.appending("a.pdf") == null);
    // A link is nothing a file holds yet, and stays.
    const joined = try lib.links("a.pdf");
    defer lib.freeLinks(joined, joined.len);
    try testing.expectEqual(@as(usize, 1), joined.len);

    try testing.expect(try lib.storeOf("a.pdf") == null);
    try lib.setStore("a.pdf", "library");
    const store = (try lib.storeOf("a.pdf")).?;
    defer testing.allocator.free(store);
    try testing.expectEqualStrings("library", store);
}

test "comments are many to an anchor, and change and go by row" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    const first = try lib.addComment("a.pdf", .{ .anchor = @constCast("f1"), .nm = @constCast("f1"), .text = @constCast("is this right?") }, 10);
    const reply = try lib.addComment("a.pdf", .{ .anchor = @constCast("f1"), .nm = @constCast("f2"), .text = @constCast("no") }, 11);
    _ = try lib.addComment("b.pdf", .{ .anchor = @constCast("f1"), .nm = @constCast("f1") }, 12);

    try lib.updateComment(reply, "yes, see lemma 3", 20);
    {
        const list = try lib.comments("a.pdf");
        defer lib.freeComments(list, list.len);
        try testing.expectEqual(@as(usize, 2), list.len);
        try testing.expectEqualStrings("is this right?", list[0].text);
        try testing.expectEqualStrings("yes, see lemma 3", list[1].text);
        try testing.expectEqual(@as(i64, 11), list[1].created_at);
        try testing.expectEqual(@as(i64, 20), list[1].modified_at);
    }

    try lib.removeComment(first);
    {
        const list = try lib.comments("a.pdf");
        defer lib.freeComments(list, list.len);
        try testing.expectEqual(@as(usize, 1), list.len);
        try testing.expectEqualStrings("f2", list[0].nm);
    }
    try testing.expectEqual(@as(u32, 1), try lib.clearComments("a.pdf"));
    const left = try lib.comments("b.pdf");
    defer lib.freeComments(left, left.len);
    try testing.expectEqual(@as(usize, 1), left.len);
}

test "a link names its comments, and another document by its /ID" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    const here = try lib.addLink("a.pdf", .{ .from = @constCast("f1"), .to = @constCast("f4"), .label = @constCast("supports") }, 1);
    _ = try lib.addLink("a.pdf", .{ .from = @constCast("f4"), .to = @constCast("f2"), .other = @constCast("0a1b2c3d4e5f60718293a4b5c6d7e8f9") }, 2);

    {
        const list = try lib.links("a.pdf");
        defer lib.freeLinks(list, list.len);
        try testing.expectEqual(@as(usize, 2), list.len);
        try testing.expectEqualStrings("f1", list[0].from);
        try testing.expectEqualStrings("f4", list[0].to);
        try testing.expectEqualStrings("supports", list[0].label);
        try testing.expectEqualStrings("", list[0].other);
        try testing.expectEqualStrings("0a1b2c3d4e5f60718293a4b5c6d7e8f9", list[1].other);
        try testing.expectEqualStrings("", list[1].label);
    }

    try lib.removeLink(here);
    {
        const list = try lib.links("a.pdf");
        defer lib.freeLinks(list, list.len);
        try testing.expectEqual(@as(usize, 1), list.len);
    }
    try testing.expectEqual(@as(u32, 1), try lib.clearLinks("a.pdf"));
}

test "a document's /ID is kept beside its path, and finds the path again" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    var hex: [id_hex_len]u8 = undefined;
    try testing.expectEqualStrings("00ff", hexId(&hex, "\x00\xff"));

    try testing.expect((try lib.fileId("a.pdf")) == null);
    try lib.setFileId("a.pdf", "00ff");
    try lib.setFileId("b.pdf", "");
    {
        const id = (try lib.fileId("a.pdf")).?;
        defer testing.allocator.free(id);
        try testing.expectEqualStrings("00ff", id);
    }
    // A file with no `/ID` has none to find it by.
    try testing.expect((try lib.fileId("b.pdf")) == null);
    try testing.expect((try lib.pathOf("")) == null);

    // Moved: the same `/ID` at another path is found at the later one.
    try lib.setFileId("moved/a.pdf", "00ff");
    const where = (try lib.pathOf("00ff")).?;
    defer testing.allocator.free(where);
    try testing.expectEqualStrings("moved/a.pdf", where);

    // A rebuilt file is a new `/ID` at the old path.
    try lib.setFileId("a.pdf", "1234");
    const now_id = (try lib.fileId("a.pdf")).?;
    defer testing.allocator.free(now_id);
    try testing.expectEqualStrings("1234", now_id);
}
