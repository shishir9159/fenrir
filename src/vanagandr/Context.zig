//! Everything a command needs from its environment, in one struct.
//!
//! Commands take a `*Context` rather than reaching for globals, so they can be
//! driven from a test with a different writer just as easily as from `main`.

const std = @import("std");
const Io = std.Io;

const Context = @This();

gpa: std.mem.Allocator,
io: Io,
/// Program output. Buffered; `main` flushes it once at the end.
out: *Io.Writer,
/// Diagnostics. Kept separate so `fenrir extract | ...` stays clean.
err: *Io.Writer,
/// The process's environment, or null in a test. Read by Mímir to find where
/// its database lives, and by nothing else: a command that wants a setting
/// asks the library for it rather than the environment.
environ: ?*std.process.Environ.Map = null,
/// The process's exit status, for a command whose status is an answer and
/// not only a verdict on whether it ran. `fenrir diff` exits 1 for "these
/// differ" and 3 for "a file would not open", as diff-pdf does, and a script
/// branching on that cannot be handed the same 1 for both. Null is the usual
/// rule: 0 for success and 1 for any error.
exit: ?u8 = null,

/// The value of an environment variable, or null.
pub fn env(ctx: *const Context, name: []const u8) ?[]const u8 {
    const map = ctx.environ orelse return null;
    return map.get(name);
}

/// Reads a whole file into memory. Documents are random-access by nature --
/// the cross-reference table is at the end and points backwards -- so there is
/// no streaming path worth having here.
pub fn readFile(ctx: *Context, path: []const u8) ![]u8 {
    return ctx.readFileWith(ctx.gpa, path);
}

/// Reads a file with an allocator that is not the command's.
///
/// `Document` frees the bytes it was opened with, using the allocator it was
/// opened with, so a command that gives `fenrir.open` its own heap -- as
/// `read` does, because the CLI's arena never frees and a reader runs until
/// you close it -- has to read the file with that same heap or the free at
/// the end is an invalid one.
pub fn readFileWith(ctx: *Context, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    // One gibibyte is far past any real document and keeps a corrupt length
    // from turning into an allocation failure at an awkward moment.
    const max_size: Io.Limit = .limited(1 << 30);
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, gpa, max_size);
}

pub fn fail(ctx: *Context, comptime fmt: []const u8, args: anytype) error{CommandFailed} {
    ctx.err.print("fenrir: " ++ fmt ++ "\n", args) catch {};
    ctx.err.flush() catch {};
    return error.CommandFailed;
}

pub fn note(ctx: *Context, comptime fmt: []const u8, args: anytype) void {
    ctx.err.print(fmt ++ "\n", args) catch {};
}
