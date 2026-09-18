//! `fenrir plugins` -- load the configuration without a window, and say what
//! happened.
//!
//! The reader shows a failed plugin as one line in a title bar, which is the
//! right amount of noise while reading and the wrong amount while writing a
//! plugin. This runs exactly what `fenrir read` runs at startup -- `init.lua`,
//! then `plugins/` -- against a host with no document open, and prints every
//! plugin, every error with its traceback, and every key and command that
//! was registered.
//!
//! A plugin that touches the document at load time sees none here: `fenrir.
//! document()` is nil and `fenrir.page()` is nil, which is also what a
//! well-written plugin should expect before `start`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");
const library = @import("library.zig");

const galdr = fenrir.galdr;
const Host = galdr.Host;

pub const usage =
    \\fenrir plugins [--config DIR] [--db FILE]
    \\
    \\    Loads init.lua and every plugin the way `fenrir read` does, with no
    \\    window and no document, and prints what loaded, what failed and why,
    \\    and the keys and commands they registered. Exits non-zero if any
    \\    plugin failed.
    \\
    \\    --config DIR  Read plugins from DIR instead of the configuration
    \\                  directory. $FENRIR_CONFIG does the same.
    \\    --db FILE     The library `fenrir.store` reads and writes.
;

pub fn run(ctx: *Context, argv: []const []const u8) !void {
    var dir_arg: ?[]const u8 = null;
    var db_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--config needs a directory", .{});
            dir_arg = argv[i];
        } else if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--db needs a file", .{});
            db_path = argv[i];
        } else {
            return ctx.fail("unknown option {s}", .{arg});
        }
    }

    if (!galdr.available) return ctx.fail("this build has no Lua: rebuild without -Dlua=false", .{});

    const dir = if (dir_arg) |d|
        try ctx.gpa.dupe(u8, d)
    else
        galdr.configDir(ctx.gpa, library.environment(ctx)) catch
            return ctx.fail("no configuration directory: set FENRIR_CONFIG or pass --config", .{});

    var headless: Headless = .{ .ctx = ctx, .dir = dir, .library = library.open(ctx, db_path) };
    defer if (headless.library) |*l| l.close();

    ctx.out.print("configuration: {s}\n", .{dir}) catch {};

    const rt = galdr.Runtime.create(ctx.gpa, headless.host(), .{}) catch |err|
        return ctx.fail("cannot start Lua: {t}", .{err});
    defer rt.destroy();
    rt.loadConfig();

    if (rt.plugins.items.len == 0) {
        ctx.out.print("no init.lua and no plugins/ -- nothing to load\n", .{}) catch {};
        return;
    }

    var failed: usize = 0;
    for (rt.plugins.items) |p| {
        ctx.out.print("  {s}  {s}\n", .{ if (p.ok) "ok    " else "FAILED", p.name }) catch {};
        if (!p.ok) failed += 1;
    }

    if (rt.keymaps.items.len != 0) {
        ctx.out.print("keys:\n", .{}) catch {};
        for (rt.keymapList()) |k| {
            if (!k.live) continue;
            var modes: [3]u8 = undefined;
            var n: usize = 0;
            if (k.modes.normal) {
                modes[n] = 'n';
                n += 1;
            }
            if (k.modes.visual) {
                modes[n] = 'v';
                n += 1;
            }
            if (k.modes.edit) {
                modes[n] = 'e';
                n += 1;
            }
            ctx.out.print("  {s: <3} {s: <10} {s}\n", .{
                modes[0..n],
                k.spec,
                if (k.description.len != 0) k.description else if (k.line.len != 0) k.line else "(function)",
            }) catch {};
        }
    }
    if (rt.commands.items.len != 0) {
        ctx.out.print("commands:\n", .{}) catch {};
        for (rt.commandNames()) |c| {
            ctx.out.print("  :{s: <14} {s}\n", .{ c.name, c.description }) catch {};
        }
    }

    if (rt.messages.items.len != 0) {
        ctx.out.print("messages:\n", .{}) catch {};
        for (rt.messages.items) |m| ctx.out.print("{s}\n\n", .{m}) catch {};
    }
    if (failed != 0) return ctx.fail("{d} of {d} failed to load", .{ failed, rt.plugins.items.len });
}

/// A host with a configuration directory, a library, and no reader.
const Headless = struct {
    ctx: *Context,
    dir: []const u8,
    library: ?library.Library,

    fn host(h: *Headless) Host {
        return .{ .ptr = h, .vtable = &vtable };
    }

    fn of(ptr: *anyopaque) *Headless {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable: Host.VTable = .{
        .notify = notify,
        .exec = struct {
            fn f(_: *anyopaque, _: []const u8) bool {
                return false;
            }
        }.f,
        .document = struct {
            fn f(_: *anyopaque) ?Host.Document {
                return null;
            }
        }.f,
        .page = struct {
            fn f(_: *anyopaque) ?u32 {
                return null;
            }
        }.f,
        .goTo = struct {
            fn f(_: *anyopaque, _: u32, _: f32) bool {
                return false;
            }
        }.f,
        .zoom = struct {
            fn f(_: *anyopaque) ?f32 {
                return null;
            }
        }.f,
        .setZoom = struct {
            fn f(_: *anyopaque, _: f32) void {}
        }.f,
        .mode = struct {
            fn f(_: *anyopaque) []const u8 {
                return "normal";
            }
        }.f,
        .cursor = struct {
            fn f(_: *anyopaque) ?Host.Position {
                return null;
            }
        }.f,
        .selection = struct {
            fn f(_: *anyopaque) ?[2]Host.Position {
                return null;
            }
        }.f,
        .highlightCount = struct {
            fn f(_: *anyopaque) usize {
                return 0;
            }
        }.f,
        .highlightAt = struct {
            fn f(_: *anyopaque, _: usize) ?Host.Highlight {
                return null;
            }
        }.f,
        .addHighlight = struct {
            fn f(_: *anyopaque, _: Host.Highlight) ?u64 {
                return null;
            }
        }.f,
        .removeHighlight = struct {
            fn f(_: *anyopaque, _: u64) bool {
                return false;
            }
        }.f,
        .storeGet = storeGet,
        .storeSet = storeSet,
        .readFile = readFile,
        .listDir = listDir,
    };

    fn notify(ptr: *anyopaque, message: []const u8) void {
        of(ptr).ctx.out.print("  | {s}\n", .{message}) catch {};
    }

    fn storeGet(ptr: *anyopaque, gpa: Allocator, key: []const u8) ?[]u8 {
        const h = of(ptr);
        const lib = h.library orelse return null;
        var buf: [256]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "galdr.{s}", .{key}) catch return null;
        const value = (lib.get(full) catch return null) orelse return null;
        defer h.ctx.gpa.free(value);
        return gpa.dupe(u8, value) catch null;
    }

    fn storeSet(ptr: *anyopaque, key: []const u8, value: ?[]const u8) bool {
        const lib = of(ptr).library orelse return false;
        var buf: [256]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "galdr.{s}", .{key}) catch return false;
        if (value) |v| lib.set(full, v) catch return false else lib.remove(full) catch return false;
        return true;
    }

    fn path(h: *Headless, buf: []u8, rel: []const u8) ?[]const u8 {
        if (!Host.isContained(rel)) return null;
        return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ h.dir, std.fs.path.sep, rel }) catch null;
    }

    fn readFile(ptr: *anyopaque, gpa: Allocator, rel: []const u8) ?[]u8 {
        const h = of(ptr);
        var buf: [4096]u8 = undefined;
        const full = h.path(&buf, rel) orelse return null;
        return Io.Dir.cwd().readFileAlloc(h.ctx.io, full, gpa, .limited(1 << 20)) catch null;
    }

    fn listDir(ptr: *anyopaque, gpa: Allocator, rel: []const u8) ?[][]u8 {
        const h = of(ptr);
        var buf: [4096]u8 = undefined;
        const full = h.path(&buf, rel) orelse return null;
        const io = h.ctx.io;

        var dir = Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch return null;
        defer dir.close(io);

        // Freed by hand on failure: this returns an optional, so an
        // `errdefer` would never run.
        var names: std.ArrayList([]u8) = .empty;
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            const made = switch (entry.kind) {
                .directory => std.fmt.allocPrint(gpa, "{s}/", .{entry.name}),
                .file, .sym_link => gpa.dupe(u8, entry.name),
                else => continue,
            };
            const name = made catch break;
            names.append(gpa, name) catch {
                gpa.free(name);
                break;
            };
        } else {
            std.mem.sort([]u8, names.items, {}, struct {
                fn less(_: void, a: []u8, b: []u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.less);
            if (names.toOwnedSlice(gpa)) |list| return list else |_| {}
        }
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
        return null;
    }
};
