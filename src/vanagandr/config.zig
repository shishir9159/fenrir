//! `fenrir.toml` -- what a person would otherwise type every time.
//!
//! Not `fenrir config`, which is the library's settings table and which the
//! reader writes as it runs. This file is never written by fenrir. It is read
//! once at start, from the directory fenrir started in or else from beside
//! the library (see `mimir.configPath`), and only by the builds that have it:
//! `light` reads nothing it was not handed, so none of this is in it.
//!
//!     theme  = "light"          # settings, at the top
//!     accent = "#e4572e"
//!
//!     [read]                    # `fenrir read`'s flags, written down
//!     zoom  = 1.25
//!     size  = "1400x1000"
//!     vsync = "adaptive"
//!     clean = true              # a switch is true, or left out
//!
//! `[read]` is not a second set of options with names of their own. Each key
//! is the flag of that name, and the reader puts them through the loop that
//! reads the typed ones, ahead of them -- so the file accepts exactly what
//! this build's command line accepts, refuses the rest in the same words,
//! and a flag typed now wins over one written down.
//!
//! The settings win over the library's for the session and are never written
//! into it. The library holds what was last clicked; this file holds what
//! somebody wrote down to have every time, and a project's own file must not
//! change how every other document opens.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");
const library = @import("library.zig");

const mimir = fenrir.mimir;
const toml = mimir.toml;
const Color = fenrir.gelgja.Color;
const Theme = fenrir.thviti.Theme;

pub const Written = struct {
    /// Where it was found, for a message.
    path: []const u8,
    /// `[read]`, as the flags it stands for, in the order written.
    flags: []const []const u8 = &.{},
    theme: ?Theme = null,
    accent: ?Color = null,
};

pub const Error = toml.Error || Io.Dir.ReadFileAllocError;

/// The file this process would read, or null. Caller owns the path.
pub fn find(ctx: *Context) ?[]u8 {
    return mimir.configPath(ctx.gpa, ctx.io, Io.Dir.cwd(), library.environment(ctx));
}

/// The file, read and checked, or null when there is none.
///
/// A file that is there and wrong fails the command at its line. An option
/// somebody wrote down and the reader quietly went without is worse than a
/// reader that will not start until the line is fixed.
pub fn load(ctx: *Context) error{CommandFailed}!?Written {
    const path = find(ctx) orelse return null;
    var diag: toml.Diagnostic = .{};
    return read(ctx.gpa, ctx.io, path, &diag) catch |err| switch (err) {
        error.Invalid => ctx.fail("{s}:{d}: {s}", .{ path, diag.line, diag.message() }),
        else => ctx.fail("cannot read {s}: {t}", .{ path, err }),
    };
}

/// Reads and interprets `path`. Allocates with `gpa` and frees nothing,
/// which is right for the CLI's arena and is what a test's arena is for.
pub fn read(gpa: Allocator, io: Io, path: []const u8, diag: *toml.Diagnostic) Error!Written {
    // A configuration file a megabyte long is not one anybody wrote.
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    const doc = try toml.parse(gpa, bytes, diag);
    return interpret(gpa, path, doc.entries, diag);
}

/// What the entries ask for. Their strings are borrowed; `gpa` as `read`.
pub fn interpret(gpa: Allocator, path: []const u8, entries: []const toml.Entry, diag: *toml.Diagnostic) toml.Error!Written {
    var out: Written = .{ .path = path };
    var flags: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        if (e.table.len == 0) {
            try setting(&out, e, diag);
        } else if (std.mem.eql(u8, e.table, "read")) {
            try flag(gpa, &flags, e);
        } else {
            return diag.set(e.line, "no table called [{s}]: there is [read], for its flags", .{e.table});
        }
    }
    out.flags = flags.items;
    return out;
}

/// `theme` and `accent`, checked here as `fenrir config` checks them, so a
/// name nobody has is found while whoever wrote it is still looking.
fn setting(out: *Written, e: toml.Entry, diag: *toml.Diagnostic) toml.Error!void {
    const known = std.mem.eql(u8, e.key, "theme") or std.mem.eql(u8, e.key, "accent");
    if (!known) {
        return diag.set(e.line, "no setting called {s}: there is theme and accent, and [read] for flags", .{e.key});
    }
    const name = switch (e.value) {
        .string => |s| s,
        else => return diag.set(e.line, "{s} is a name in quotes, not {s}", .{ e.key, e.value.kind() }),
    };
    if (std.mem.eql(u8, e.key, "theme")) {
        out.theme = Theme.byName(name) orelse
            return diag.set(e.line, "no theme called {s}: there is {s}", .{ name, theme_names });
    } else {
        out.accent = mimir.Library.parseColor(name) orelse
            return diag.set(e.line, "{s} is not a colour: try a name or #rrggbb", .{name});
    }
}

const theme_names = names: {
    var s: []const u8 = "";
    for (Theme.all, 0..) |t, i| s = s ++ (if (i == 0) "" else ", ") ++ t.name;
    break :names s;
};

/// One key of `[read]`, as the words that would have been typed.
///
/// `true` is the switch alone. Anything else is the flag and its value, and
/// that includes `false`: written as a value, `vsync = false` is refused by
/// `--vsync` and `clean = false` by the reader's check for a switch handed a
/// value, where leaving it out would have let either mean nothing at all.
fn flag(gpa: Allocator, flags: *std.ArrayList([]const u8), e: toml.Entry) Allocator.Error!void {
    const name = try std.fmt.allocPrint(gpa, "--{s}", .{e.key});
    const value = switch (e.value) {
        .boolean => |on| if (on) return flags.append(gpa, name) else "false",
        .string => |s| s,
        .integer => |n| try std.fmt.allocPrint(gpa, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(gpa, "{d}", .{f}),
    };
    try flags.appendSlice(gpa, &.{ name, value });
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn interpreted(arena: *std.heap.ArenaAllocator, source: []const u8, diag: *toml.Diagnostic) toml.Error!Written {
    const a = arena.allocator();
    const doc = try toml.parse(a, source, diag);
    return interpret(a, "fenrir.toml", doc.entries, diag);
}

test "[read] comes back as the flags it stands for, in the order written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: toml.Diagnostic = .{};

    const w = try interpreted(&arena,
        \\theme = "light"
        \\accent = "orange"
        \\[read]
        \\zoom = 1.25
        \\samples = 4
        \\vsync = "off"
        \\clean = true
        \\validate = false
    , &diag);

    try testing.expectEqualStrings("light", w.theme.?.name);
    try testing.expect(w.accent != null);

    const want = [_][]const u8{ "--zoom", "1.25", "--samples", "4", "--vsync", "off", "--clean", "--validate", "false" };
    try testing.expectEqual(want.len, w.flags.len);
    for (want, w.flags) |a, b| try testing.expectEqualStrings(a, b);
}

test "a setting is checked where it is written, at its line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { []const u8, u32, []const u8 }{
        .{ "theme = \"sepia\"", 1, "there is dark, light" },
        .{ "\n\naccent = \"mauve-ish\"", 3, "not a colour" },
        .{ "theme = 1", 1, "a name in quotes" },
        .{ "author = \"Nahid\"", 1, "no setting called author" },
        .{ "[window]\nsize = \"1x1\"", 2, "no table called [window]" },
    };
    for (cases) |c| {
        var diag: toml.Diagnostic = .{};
        try testing.expectError(error.Invalid, interpreted(&arena, c[0], &diag));
        try testing.expectEqual(c[1], diag.line);
        try testing.expect(std.mem.indexOf(u8, diag.message(), c[2]) != null);
    }
}

test "an empty file asks for nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: toml.Diagnostic = .{};

    const w = try interpreted(&arena, "# nothing yet\n", &diag);
    try testing.expect(w.theme == null and w.accent == null);
    try testing.expectEqual(@as(usize, 0), w.flags.len);
}
