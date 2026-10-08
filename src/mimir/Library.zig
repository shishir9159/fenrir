//! What the reader remembers between sessions: which documents you have
//! opened, where you were in each, and the handful of settings that are
//! yours rather than a command line's.
//!
//! Three tables and a version number. The schema is small on purpose -- this
//! is a reader's memory, not a catalogue -- and it is migrated by
//! `user_version` rather than by a table of migrations, because there is
//! exactly one sequence of versions and no branching.
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
//! Highlights are the one thing here that is a *change to a document* rather
//! than a note about reading it, and they are still kept here rather than
//! written into the PDF: writing an annotation back means rewriting the file,
//! and a reader should not modify what it was asked to display until someone
//! asks it to. `fenrir` will grow a command that exports them as real
//! `/Annots`; until then they live beside the document and not in it.
//!
//! Settings are key and value, both text, because every one of them is
//! either a name, a colour or a number that a person may want to read in the
//! file. `author` is who annotations will be signed by; `accent` is the
//! colour the interface draws its own marks in.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Db = @import("Db.zig");
const paint = @import("../gelgja/paint.zig");

const Color = paint.Color;
const Library = @This();

pub const Error = Db.Error;

/// The schema this build expects. A file from an older version is migrated
/// forward on open; one from a *newer* version is left alone and opened
/// read-only in effect, because a later fenrir may have added a column this
/// one would drop on write.
pub const schema_version: i64 = 2;

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
    if (found < schema_version) try lib.migrate(found);
    return lib;
}

pub fn close(lib: *Library) void {
    lib.db.close();
}

fn userVersion(lib: Library) Error!i64 {
    var s = try lib.db.prepare("PRAGMA user_version");
    defer s.finalize();
    if (!try s.step()) return 0;
    return s.columnInt(0);
}

/// Brings a file at version `from` up to `schema_version`.
///
/// Each step is one `if`, in order, with no `else`: a file three versions old
/// runs three of them. `PRAGMA user_version` cannot be parameterised, which
/// is why the last statement is the only formatted SQL in this file.
fn migrate(lib: *Library, from: i64) Error!void {
    if (from < 1) {
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
            \\    zoom      REAL NOT NULL DEFAULT 0,
            \\    opens     INTEGER NOT NULL DEFAULT 0,
            \\    opened_at INTEGER NOT NULL DEFAULT 0
            \\) WITHOUT ROWID;
            \\CREATE INDEX IF NOT EXISTS recent_by_time ON recent (opened_at DESC);
            \\COMMIT;
        );
    }

    if (from < 2) {
        // Where in the page, and the highlights drawn on it.
        //
        // `offset` is *points from the top of that page*, not pixels: a pixel
        // offset would put you somewhere else on reopening at another zoom or
        // on another screen, which is the bug that makes resuming not worth
        // having. Added with a default so that a version-1 file migrates
        // without a rewrite -- every existing row means "the top of the page",
        // which is where those readers were left.
        //
        // A highlight's box is in the same user-space points, and `path` is
        // the document rather than a foreign key, so that forgetting a recent
        // file does not silently throw away what was marked in it.
        try lib.db.exec(
            \\BEGIN;
            \\ALTER TABLE recent ADD COLUMN offset REAL NOT NULL DEFAULT 0;
            \\CREATE TABLE IF NOT EXISTS highlight (
            \\    id         INTEGER PRIMARY KEY,
            \\    path       TEXT NOT NULL,
            \\    page       INTEGER NOT NULL,
            \\    x0         REAL NOT NULL,
            \\    y0         REAL NOT NULL,
            \\    x1         REAL NOT NULL,
            \\    y1         REAL NOT NULL,
            \\    color      TEXT NOT NULL DEFAULT '',
            \\    note       TEXT NOT NULL DEFAULT '',
            \\    created_at INTEGER NOT NULL DEFAULT 0
            \\);
            \\CREATE INDEX IF NOT EXISTS highlight_by_doc ON highlight (path, page);
            \\COMMIT;
        );
    }

    var buf: [64]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&buf, "PRAGMA user_version = {d}", .{schema_version}) catch return error.Failed;
    try lib.db.exec(sql);
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

// -- highlights ---------------------------------------------------------------

/// One highlight, as the file holds it.
///
/// The box is in the page's own user-space points, which is the only
/// coordinate that survives a different zoom, a different window and a
/// different machine. See `hlidskjalf/Marks.zig`, whose `Mark` this mirrors.
pub const Highlight = struct {
    id: i64 = 0,
    page: u32 = 0,
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,
    /// `#rrggbb`, or empty for the reader's accent colour. Stored as text so
    /// that the file stays something a person can read and edit.
    color: []u8 = &.{},
    note: []u8 = &.{},
};

/// Writes a highlight and returns the row it was given, so the caller can
/// delete exactly this one later.
pub fn addHighlight(lib: Library, path: []const u8, h: Highlight, now: i64) Error!i64 {
    if (lib.future) return 0;
    var s = try lib.db.prepare(
        \\INSERT INTO highlight (path, page, x0, y0, x1, y1, color, note, created_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
    );
    defer s.finalize();
    s.bindText(1, path);
    s.bindInt(2, h.page);
    s.bindFloat(3, h.x0);
    s.bindFloat(4, h.y0);
    s.bindFloat(5, h.x1);
    s.bindFloat(6, h.y1);
    s.bindText(7, h.color);
    s.bindText(8, h.note);
    s.bindInt(9, now);
    try s.exec();
    return lib.db.lastInsertRowId();
}

/// Rewrites what can change about a highlight once it exists: its colour and
/// its note. Its box and page never change -- a highlight moved to other
/// words is a different highlight, and is removed and added as one.
pub fn updateHighlight(lib: Library, id: i64, color: []const u8, note: []const u8) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare("UPDATE highlight SET color = ?2, note = ?3 WHERE id = ?1");
    defer s.finalize();
    s.bindInt(1, id);
    s.bindText(2, color);
    s.bindText(3, note);
    try s.exec();
}

pub fn removeHighlight(lib: Library, id: i64) Error!void {
    if (lib.future) return;
    var s = try lib.db.prepare("DELETE FROM highlight WHERE id = ?1");
    defer s.finalize();
    s.bindInt(1, id);
    try s.exec();
}

pub fn clearHighlights(lib: Library, path: []const u8) Error!u32 {
    if (lib.future) return 0;
    var s = try lib.db.prepare("DELETE FROM highlight WHERE path = ?1");
    defer s.finalize();
    s.bindText(1, path);
    try s.exec();
    return lib.db.changes();
}

/// Every highlight on a document, oldest first so that they are drawn in the
/// order they were made.
pub fn highlights(lib: Library, path: []const u8) Error![]Highlight {
    var out: std.ArrayList(Highlight) = .empty;
    errdefer lib.freeHighlights(out.items, out.items.len);

    var s = try lib.db.prepare(
        \\SELECT id, page, x0, y0, x1, y1, color, note FROM highlight
        \\WHERE path = ?1 ORDER BY id
    );
    defer s.finalize();
    s.bindText(1, path);
    while (try s.step()) {
        const color = try lib.gpa.dupe(u8, s.columnText(6));
        errdefer lib.gpa.free(color);
        const note = try lib.gpa.dupe(u8, s.columnText(7));
        try out.append(lib.gpa, .{
            .id = s.columnInt(0),
            .page = @intCast(@max(0, s.columnInt(1))),
            .x0 = @floatCast(s.columnFloat(2)),
            .y0 = @floatCast(s.columnFloat(3)),
            .x1 = @floatCast(s.columnFloat(4)),
            .y1 = @floatCast(s.columnFloat(5)),
            .color = color,
            .note = note,
        });
    }
    return out.toOwnedSlice(lib.gpa);
}

pub fn freeHighlight(lib: Library, h: Highlight) void {
    lib.gpa.free(h.color);
    lib.gpa.free(h.note);
}

pub fn freeHighlights(lib: Library, list: []Highlight, n: usize) void {
    for (list[0..n]) |h| lib.freeHighlight(h);
    if (list.len != 0) lib.gpa.free(list);
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

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn memory() !Library {
    return Library.open(testing.allocator, ":memory:");
}

test "a fresh database is migrated to the schema this build knows" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();
    try testing.expectEqual(schema_version, try lib.userVersion());
    // Migrating again is a no-op, which is what makes opening an existing
    // file the same code path as creating one.
    try lib.migrate(schema_version);
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

test "a version-1 file gains the offset column without losing its rows" {
    if (!Db.available) return error.SkipZigTest;
    const gpa = testing.allocator;

    // A database as the previous release left it: the old schema, one row,
    // and `user_version` at 1.
    var db = try Db.open(gpa, ":memory:");
    defer db.close();
    try db.exec(
        \\CREATE TABLE recent (
        \\    path TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '',
        \\    page INTEGER NOT NULL DEFAULT 0, zoom REAL NOT NULL DEFAULT 0,
        \\    opens INTEGER NOT NULL DEFAULT 0, opened_at INTEGER NOT NULL DEFAULT 0
        \\) WITHOUT ROWID;
        \\CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        \\INSERT INTO recent (path, title, page, zoom, opens, opened_at)
        \\VALUES ('old.pdf', 'old', 5, 1.25, 3, 99);
        \\PRAGMA user_version = 1;
    );

    var lib: Library = .{ .gpa = gpa, .db = db };
    try lib.migrate(1);
    try testing.expectEqual(schema_version, try lib.userVersion());

    // The row survived, and where it was read stopped is the top of the page
    // it was on -- which is where that reader actually left off.
    const seen = (try lib.lastSeen("old.pdf")).?;
    defer lib.freeRecent(seen);
    try testing.expectEqual(@as(u32, 5), seen.page);
    try testing.expectEqual(@as(u32, 3), seen.opens);
    try testing.expectApproxEqAbs(@as(f32, 0), seen.offset, 0.001);
}

test "a highlight round-trips, and is deleted by the id it was given" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    const id = try lib.addHighlight("a.pdf", .{
        .page = 2,
        .x0 = 100,
        .y0 = 700,
        .x1 = 220,
        .y1 = 712,
        .color = @constCast("#f7e733"),
    }, 1000);
    try testing.expect(id != 0);
    _ = try lib.addHighlight("a.pdf", .{ .page = 4, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1001);
    _ = try lib.addHighlight("b.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1002);

    {
        const list = try lib.highlights("a.pdf");
        defer lib.freeHighlights(list, list.len);
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
    try lib.removeHighlight(id);
    {
        const list = try lib.highlights("a.pdf");
        defer lib.freeHighlights(list, list.len);
        try testing.expectEqual(@as(usize, 1), list.len);
        try testing.expectEqual(@as(u32, 4), list[0].page);
    }

    try testing.expectEqual(@as(u32, 1), try lib.clearHighlights("a.pdf"));
    {
        const list = try lib.highlights("b.pdf");
        defer lib.freeHighlights(list, list.len);
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
    _ = try lib.addHighlight("a.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1);
    try lib.forgetAll();

    const list = try lib.highlights("a.pdf");
    defer lib.freeHighlights(list, list.len);
    try testing.expectEqual(@as(usize, 1), list.len);
}

test "a highlight's colour and note can be changed in place" {
    if (!Db.available) return error.SkipZigTest;
    var lib = try memory();
    defer lib.close();

    const id = try lib.addHighlight("a.pdf", .{ .page = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 1);
    try lib.updateHighlight(id, "#3fa34d", "see lemma 3");

    const list = try lib.highlights("a.pdf");
    defer lib.freeHighlights(list, list.len);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(id, list[0].id);
    try testing.expectEqualStrings("#3fa34d", list[0].color);
    try testing.expectEqualStrings("see lemma 3", list[0].note);
}
