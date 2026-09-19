//! **Mímir** — what the reader remembers.
//!
//! Mímir's well is the one you give an eye for a drink from: memory, and what
//! has been seen before. This is the smallest component in the project and
//! the only one that links a library, because the job -- remember a handful
//! of facts across crashes and across two processes open at once -- is a
//! transaction, and SQLite is the answer to that.
//!
//! * `Db` is SQLite with its entry points declared by hand.
//! * `Library` is the schema: recent files with where you were in each, and
//!   settings, including the author name and the accent colour.
//!
//! Nothing above this layer may assume it exists. `-Dsqlite=false` compiles
//! it away to functions that report `error.NoDatabase`, and every caller is
//! written so that a reader with no memory still opens documents -- it simply
//! starts each one at the beginning.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Db = @import("mimir/Db.zig");
pub const Library = @import("mimir/Library.zig");

/// True when this build can remember anything.
pub const available = Db.available;

pub const Error = Db.Error || error{NoHome};

/// Where to look for the environment variables that decide the path.
///
/// An interface and not `std.process` directly, because the environment
/// belongs to the process and this is a library: the CLI hands its own map
/// in, and a test hands in whatever it wants the answer to be.
pub const Environment = struct {
    ptr: *const anyopaque,
    lookup: *const fn (ptr: *const anyopaque, name: []const u8) ?[]const u8,

    pub fn get(e: Environment, name: []const u8) ?[]const u8 {
        return e.lookup(e.ptr, name);
    }

    /// An environment with nothing in it, so every lookup falls through to
    /// the platform default.
    pub const none: Environment = .{ .ptr = undefined, .lookup = nothing };

    fn nothing(_: *const anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }
};

/// The file the library lives in, under the platform's own place for a
/// program's data.
///
///   Windows   %APPDATA%\fenrir\fenrir.db
///   macOS     ~/Library/Application Support/fenrir/fenrir.db
///   otherwise $XDG_DATA_HOME/fenrir/fenrir.db, or ~/.local/share/...
///
/// `FENRIR_DB` overrides all of it, which is what a portable install and the
/// tests use. The caller owns the returned path.
pub fn defaultPath(gpa: Allocator, env: Environment) Error![]u8 {
    if (env.get("FENRIR_DB")) |override| {
        if (override.len != 0) return gpa.dupe(u8, override);
    }

    const builtin = @import("builtin");
    const join = std.fs.path.join;
    switch (builtin.os.tag) {
        .windows => {
            const base = set(env.get("APPDATA")) orelse set(env.get("LOCALAPPDATA")) orelse
                return error.NoHome;
            return join(gpa, &.{ base, "fenrir", "fenrir.db" }) catch error.OutOfMemory;
        },
        .macos, .ios => {
            const home = set(env.get("HOME")) orelse return error.NoHome;
            return join(gpa, &.{ home, "Library", "Application Support", "fenrir", "fenrir.db" }) catch
                error.OutOfMemory;
        },
        else => {
            if (set(env.get("XDG_DATA_HOME"))) |x| {
                return join(gpa, &.{ x, "fenrir", "fenrir.db" }) catch error.OutOfMemory;
            }
            const home = set(env.get("HOME")) orelse return error.NoHome;
            return join(gpa, &.{ home, ".local", "share", "fenrir", "fenrir.db" }) catch
                error.OutOfMemory;
        },
    }
}

/// A variable that is present but empty counts as unset, which is what a
/// shell leaves behind when something was not substituted.
fn set(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

/// Opens the library at `path`, or at `defaultPath` when none is given,
/// creating the directory it lives in.
///
/// Returns null rather than an error when there is nothing to open: a build
/// without SQLite, a read-only home, a disk that is full. None of those is a
/// reason for a reader to refuse to open a document, and every caller here
/// treats a null library as "remember nothing".
pub fn open(gpa: Allocator, io: std.Io, env: Environment, path: ?[]const u8) ?Library {
    if (!available) return null;

    const where = if (path) |p|
        gpa.dupe(u8, p) catch return null
    else
        defaultPath(gpa, env) catch return null;
    defer gpa.free(where);

    if (std.fs.path.dirname(where)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    return Library.open(gpa, where) catch null;
}

test {
    _ = Db;
    _ = Library;
}

/// An environment made of pairs, for the tests.
const FakeEnv = struct {
    pairs: []const [2][]const u8,

    fn environment(f: *const FakeEnv) Environment {
        return .{ .ptr = f, .lookup = lookup };
    }

    fn lookup(ptr: *const anyopaque, name: []const u8) ?[]const u8 {
        const f: *const FakeEnv = @ptrCast(@alignCast(ptr));
        for (f.pairs) |p| {
            if (std.mem.eql(u8, p[0], name)) return p[1];
        }
        return null;
    }
};

test "the database path follows the platform, and FENRIR_DB overrides it" {
    const gpa = std.testing.allocator;

    const override: FakeEnv = .{ .pairs = &.{.{ "FENRIR_DB", "C:/tmp/x.db" }} };
    const chosen = try defaultPath(gpa, override.environment());
    defer gpa.free(chosen);
    try std.testing.expectEqualStrings("C:/tmp/x.db", chosen);

    // Empty is unset, so the platform's own place is used instead.
    const empty: FakeEnv = .{ .pairs = &.{
        .{ "FENRIR_DB", "" },
        .{ "APPDATA", "C:/Users/x/AppData/Roaming" },
        .{ "HOME", "/home/x" },
        .{ "XDG_DATA_HOME", "" },
    } };
    const fallback = try defaultPath(gpa, empty.environment());
    defer gpa.free(fallback);
    try std.testing.expect(std.mem.endsWith(u8, fallback, "fenrir.db"));
    try std.testing.expect(std.mem.indexOf(u8, fallback, "fenrir") != null);

    // Nothing to go on is an error and not a path in the current directory,
    // which would put a database wherever the program happened to start.
    const nothing: FakeEnv = .{ .pairs = &.{} };
    try std.testing.expectError(error.NoHome, defaultPath(gpa, nothing.environment()));
}
