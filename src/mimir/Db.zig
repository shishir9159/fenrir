//! SQLite, declared by hand.
//!
//! The same bargain as `lyngvi/vk.zig`: the C library is compiled from its
//! own source by the build, and the *declarations* are written here rather
//! than translated from `sqlite3.h`. That keeps the header out of the tree,
//! keeps the surface to the twenty-odd entry points this program actually
//! calls, and makes the calling convention and the ownership of every pointer
//! something written down instead of inferred.
//!
//! What SQLite is for here is stated once, because it is the only library
//! this project links on purpose: the reader has a handful of small facts to
//! remember between sessions -- where you were in a document, what colour you
//! chose, who you are -- and every one of them has to survive the program
//! being killed mid-write. That is a transaction, and a transaction over a
//! file is a database. The alternative is a config file rewritten in place,
//! which is the same problem solved worse.
//!
//! `-Dsqlite=false` builds without it. Every function here then returns
//! `error.NoDatabase` before touching a symbol, so the binary links no C and
//! `mimir.Library` degrades to remembering nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const Db = @This();

/// True when this build compiled SQLite in.
pub const available = build_options.sqlite;

pub const Error = error{
    NoDatabase,
    CannotOpen,
    Busy,
    BadStatement,
    Failed,
} || Allocator.Error;

/// An opaque `sqlite3 *` and `sqlite3_stmt *`. Never dereferenced here.
const Handle = opaque {};
const Statement = opaque {};

// -- the C entry points ------------------------------------------------------
//
// Only what is called. Anything added here has to match `sqlite3.h` exactly;
// a wrong signature compiles, links, and corrupts a stack at run time.

extern fn sqlite3_initialize() c_int;
extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*Handle, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close_v2(db: ?*Handle) c_int;
extern fn sqlite3_errmsg(db: ?*Handle) [*:0]const u8;
extern fn sqlite3_exec(
    db: ?*Handle,
    sql: [*:0]const u8,
    callback: ?*const fn (*anyopaque, c_int, [*][*:0]u8, [*][*:0]u8) callconv(.c) c_int,
    arg: ?*anyopaque,
    errmsg: ?*?[*:0]u8,
) c_int;
extern fn sqlite3_prepare_v2(
    db: ?*Handle,
    sql: [*]const u8,
    n_bytes: c_int,
    stmt: *?*Statement,
    tail: ?*[*:0]const u8,
) c_int;
extern fn sqlite3_step(stmt: ?*Statement) c_int;
extern fn sqlite3_reset(stmt: ?*Statement) c_int;
extern fn sqlite3_finalize(stmt: ?*Statement) c_int;
extern fn sqlite3_bind_int64(stmt: ?*Statement, index: c_int, value: i64) c_int;
extern fn sqlite3_bind_double(stmt: ?*Statement, index: c_int, value: f64) c_int;
extern fn sqlite3_bind_text(
    stmt: ?*Statement,
    index: c_int,
    text: [*]const u8,
    n_bytes: c_int,
    destructor: ?*const anyopaque,
) c_int;
extern fn sqlite3_column_count(stmt: ?*Statement) c_int;
extern fn sqlite3_column_int64(stmt: ?*Statement, col: c_int) i64;
extern fn sqlite3_column_double(stmt: ?*Statement, col: c_int) f64;
extern fn sqlite3_column_text(stmt: ?*Statement, col: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(stmt: ?*Statement, col: c_int) c_int;
extern fn sqlite3_libversion() [*:0]const u8;
extern fn sqlite3_changes(db: ?*Handle) c_int;
extern fn sqlite3_last_insert_rowid(db: ?*Handle) i64;

const ok: c_int = 0;
const row: c_int = 100;
const done: c_int = 101;
const busy: c_int = 5;

const open_readwrite: c_int = 0x02;
const open_create: c_int = 0x04;
/// `SQLITE_TRANSIENT`: SQLite copies the bytes before returning, which is
/// what makes it safe to bind a slice that lives on the stack.
const transient: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

handle: ?*Handle = null,

/// The library's own version string, for `fenrir info` and the tests that
/// check the build really did compile the amalgamation it was pinned to.
pub fn version() []const u8 {
    if (!available) return "";
    return std.mem.span(sqlite3_libversion());
}

/// Opens or creates a database. `path` may be `:memory:`.
///
/// `SQLITE_OMIT_AUTOINIT` is one of the flags this is compiled with, so the
/// library is initialised here instead: one call, idempotent, and the
/// alternative is an initialisation that happens implicitly on whichever
/// call happens to be first.
pub fn open(gpa: Allocator, path: []const u8) Error!Db {
    if (!available) return error.NoDatabase;
    if (sqlite3_initialize() != ok) return error.CannotOpen;

    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);

    var db: Db = .{};
    if (sqlite3_open_v2(z.ptr, &db.handle, open_readwrite | open_create, null) != ok) {
        _ = sqlite3_close_v2(db.handle);
        return error.CannotOpen;
    }
    // WAL so a reader and a writer do not block each other, and NORMAL
    // because the thing being protected is a list of recent files: worth a
    // transaction, not worth an fsync per write.
    db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;") catch {};
    return db;
}

pub fn close(db: *Db) void {
    if (!available) return;
    _ = sqlite3_close_v2(db.handle);
    db.handle = null;
}

/// The last error SQLite reported, for a message a person can act on.
pub fn message(db: Db) []const u8 {
    if (!available or db.handle == null) return "no database";
    return std.mem.span(sqlite3_errmsg(db.handle));
}

/// Runs one or more statements with no parameters and no rows.
pub fn exec(db: Db, sql: [:0]const u8) Error!void {
    if (!available) return error.NoDatabase;
    const rc = sqlite3_exec(db.handle, sql.ptr, null, null, null);
    if (rc == ok) return;
    return if (rc == busy) error.Busy else error.Failed;
}

pub fn prepare(db: Db, sql: []const u8) Error!Stmt {
    if (!available) return error.NoDatabase;
    var stmt: ?*Statement = null;
    const rc = sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &stmt, null);
    if (rc != ok or stmt == null) return error.BadStatement;
    return .{ .stmt = stmt };
}

/// A prepared statement: bind, step, read, finish.
///
/// Parameters are numbered from one, as SQLite numbers them, and columns from
/// zero, as SQLite numbers those. The asymmetry is SQLite's and is left alone
/// rather than papered over, so that a query written against the
/// documentation reads the same here.
pub const Stmt = struct {
    stmt: ?*Statement,

    pub fn finalize(s: *Stmt) void {
        if (!available) return;
        _ = sqlite3_finalize(s.stmt);
        s.stmt = null;
    }

    pub fn reset(s: Stmt) void {
        if (!available) return;
        _ = sqlite3_reset(s.stmt);
    }

    pub fn bindText(s: Stmt, index: c_int, value: []const u8) void {
        if (!available) return;
        _ = sqlite3_bind_text(s.stmt, index, value.ptr, @intCast(value.len), transient);
    }

    pub fn bindInt(s: Stmt, index: c_int, value: i64) void {
        if (!available) return;
        _ = sqlite3_bind_int64(s.stmt, index, value);
    }

    pub fn bindFloat(s: Stmt, index: c_int, value: f64) void {
        if (!available) return;
        _ = sqlite3_bind_double(s.stmt, index, value);
    }

    /// True when a row is ready, false when the statement is done.
    pub fn step(s: Stmt) Error!bool {
        if (!available) return error.NoDatabase;
        const rc = sqlite3_step(s.stmt);
        return switch (rc) {
            row => true,
            done => false,
            busy => error.Busy,
            else => error.Failed,
        };
    }

    /// Runs a statement that returns no rows.
    pub fn exec(s: Stmt) Error!void {
        while (try s.step()) {}
    }

    pub fn columnInt(s: Stmt, col: c_int) i64 {
        if (!available) return 0;
        return sqlite3_column_int64(s.stmt, col);
    }

    pub fn columnFloat(s: Stmt, col: c_int) f64 {
        if (!available) return 0;
        return sqlite3_column_double(s.stmt, col);
    }

    /// Borrowed until the next `step` or `finalize`, which is SQLite's rule
    /// and is why every caller here copies before it moves on.
    pub fn columnText(s: Stmt, col: c_int) []const u8 {
        if (!available) return "";
        const ptr = sqlite3_column_text(s.stmt, col) orelse return "";
        const n = sqlite3_column_bytes(s.stmt, col);
        if (n <= 0) return "";
        return ptr[0..@intCast(n)];
    }

    pub fn columnCount(s: Stmt) u32 {
        if (!available) return 0;
        return @intCast(sqlite3_column_count(s.stmt));
    }
};

/// How many rows the last statement changed.
pub fn changes(db: Db) u32 {
    if (!available) return 0;
    const n = sqlite3_changes(db.handle);
    return if (n < 0) 0 else @intCast(n);
}

/// The row id the last insert was given. The way to learn the identity of a
/// row you have just written without reading it back, and the only reliable
/// one -- a `SELECT max(id)` would be a race between two readers.
pub fn lastInsertRowId(db: Db) i64 {
    if (!available) return 0;
    return sqlite3_last_insert_rowid(db.handle);
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "a database in memory takes a statement and gives back a row" {
    if (!available) return error.SkipZigTest;
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE t (a TEXT, b INTEGER, c REAL)");
    {
        var s = try db.prepare("INSERT INTO t VALUES (?1, ?2, ?3)");
        defer s.finalize();
        s.bindText(1, "hello");
        s.bindInt(2, 42);
        s.bindFloat(3, 1.5);
        try s.exec();
    }
    try testing.expectEqual(@as(u32, 1), db.changes());

    var q = try db.prepare("SELECT a, b, c FROM t");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("hello", q.columnText(0));
    try testing.expectEqual(@as(i64, 42), q.columnInt(1));
    try testing.expectEqual(@as(f64, 1.5), q.columnFloat(2));
    try testing.expect(!try q.step());
}

test "the version is the one the build pinned" {
    if (!available) return error.SkipZigTest;
    // Pinned in `build.zig.zon` by hash, so this is the amalgamation that was
    // downloaded and not whatever a system library happens to be.
    try testing.expectEqualStrings("3.53.4", version());
}

test "a double-quoted string is an error rather than an identifier" {
    // `-DSQLITE_DQS=0`. Without it, `WHERE name = "value"` quietly becomes a
    // comparison against the column `value`, or against the constant string
    // if there is no such column -- the one SQLite misfeature most likely to
    // turn a typo into a query that runs and answers wrongly.
    if (!available) return error.SkipZigTest;
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (a TEXT)");
    try testing.expectError(error.BadStatement, db.prepare("SELECT * FROM t WHERE a = \"b\""));
}

test "a statement that will not parse is refused rather than run" {
    if (!available) return error.SkipZigTest;
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    try testing.expectError(error.BadStatement, db.prepare("SELECT FROM"));
    try testing.expectError(error.Failed, db.exec("NOT SQL"));
}
