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
//!
//! `--api` answers the other half of the question, which is what a plugin
//! *could* have called. It is written out of the table that builds the
//! `fenrir` table, so it is a reference that cannot be out of date: there is
//! no second copy of the list for anybody to forget.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");
const library = @import("library.zig");

const galdr = fenrir.galdr;
const Host = galdr.Host;

pub const usage =
    \\fenrir plugins [--api] [--config DIR] [--db FILE]
    \\
    \\    Loads init.lua and every plugin the way `fenrir read` does, with no
    \\    window and no document, and prints what loaded, what it asked to
    \\    reach, what failed and why, and the keys and commands they
    \\    registered. Exits non-zero if any plugin failed.
    \\
    \\    --api         Print the whole `fenrir` table instead: every
    \\                  function, what it takes, and which capability has to
    \\                  be asked for before a plugin can see it.
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
        if (std.mem.eql(u8, arg, "--api")) {
            return writeApi(ctx);
        } else if (std.mem.eql(u8, arg, "--config")) {
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
        ctx.out.print("  {s}  {s}", .{ if (p.ok) "ok    " else "FAILED", p.name }) catch {};
        if (p.manifest.version.len != 0) ctx.out.print(" {s}", .{p.manifest.version}) catch {};
        if (p.manifest.about.len != 0) ctx.out.print("  -- {s}", .{p.manifest.about}) catch {};
        ctx.out.print("\n", .{}) catch {};
        // What it can reach, which is the half of a manifest worth reading
        // before installing something. A plugin that declared none says so
        // rather than printing the whole list it was given by default.
        if (p.manifest.declared) {
            ctx.out.print("          asks for", .{}) catch {};
            var any = false;
            inline for (@typeInfo(galdr.Runtime.Capability).@"enum".field_values) |value| {
                const c: galdr.Runtime.Capability = @enumFromInt(value);
                if (p.manifest.caps.has(c)) {
                    ctx.out.print(" {s}{s}", .{ c.name(), if (c.reserved()) " (reserved)" else "" }) catch {};
                    any = true;
                }
            }
            ctx.out.print("{s}\n", .{if (any) "" else " nothing"}) catch {};
        } else {
            ctx.out.print("          no manifest, so everything\n", .{}) catch {};
        }
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
    if (rt.panels.items.len != 0) {
        ctx.out.print("panels:\n", .{}) catch {};
        for (rt.panelList()) |p| {
            if (!p.live) continue;
            ctx.out.print("  {s: <14} {s: <18} {s}\n", .{ p.name, p.title, p.icon }) catch {};
        }
    }
    if (rt.settings.items.len != 0) {
        ctx.out.print("settings:\n", .{}) catch {};
        for (rt.settingList()) |row| {
            if (!row.live) continue;
            ctx.out.print("  {s: <20} {s}\n", .{ row.key, row.about }) catch {};
        }
    }
    if (rt.rails.items.len != 0) {
        ctx.out.print("rails:\n", .{}) catch {};
        for (rt.railList()) |b| {
            if (!b.live) continue;
            ctx.out.print("  {s: <6} {s: <18} {s: <20} {s}\n", .{
                @tagName(b.side),
                b.label,
                b.icon,
                if (b.line.len != 0) b.line else "(function)",
            }) catch {};
        }
    }
    if (rt.handlers.items.len != 0) {
        ctx.out.print("events:\n", .{}) catch {};
        for (rt.handlerList()) |h| {
            if (!h.live) continue;
            ctx.out.print("  {s: <18} {s}", .{ @tagName(h.event), h.pattern }) catch {};
            if (h.group.len != 0) ctx.out.print("  group {s}", .{h.group}) catch {};
            // A handler on an event nothing fires is not an error, but it is
            // the difference between a plugin that does nothing and a plugin
            // that was never asked to.
            if (!h.event.fires()) ctx.out.print("  (reserved: never fires)", .{}) catch {};
            ctx.out.print("\n", .{}) catch {};
        }
    }
    if (rt.commands.items.len != 0) {
        ctx.out.print("commands:\n", .{}) catch {};
        for (rt.commandNames()) |c| {
            if (!c.live) continue;
            ctx.out.print("  :{s: <14} {s}", .{ c.name, c.description }) catch {};
            if (c.group.len != 0) ctx.out.print("  group {s}", .{c.group}) catch {};
            ctx.out.print("\n", .{}) catch {};
        }
    }

    if (rt.messages.items.len != 0) {
        ctx.out.print("messages:\n", .{}) catch {};
        for (rt.messages.items) |m| ctx.out.print("{s}\n\n", .{m}) catch {};
    }
    if (failed != 0) return ctx.fail("{d} of {d} failed to load", .{ failed, rt.plugins.items.len });
}

/// `fenrir plugins --api`: the whole `fenrir` table, written out of the table
/// that builds it.
///
/// Grouped by capability rather than alphabetically, because the order a
/// person needs is "what do I have to ask for to get this", and a manifest is
/// written before any of these are called. The reference cannot go stale:
/// there is one table, it is what `pushFenrir` reads, and every row of it has
/// to have a sentence or the build fails.
fn writeApi(ctx: *Context) !void {
    // Before the table is touched, and not only for the message: the entries
    // hold pointers to the functions themselves, so reading one in a build
    // with no Lua would ask the linker for `lua_pushnil`. A comptime-false
    // condition takes the rest of this function out with it.
    if (!galdr.available) return ctx.fail("this build has no Lua: rebuild without -Dlua=false", .{});
    const Runtime = galdr.Runtime;
    const w = ctx.out;

    try w.print("the fenrir table -- {d} functions, {d} of them behind a capability\n", .{
        Runtime.api.len + Runtime.store.len,
        countGated(),
    });
    try w.writeAll(
        \\
        \\A plugin with no manifest sees all of it. One that declares a
        \\manifest sees the functions under `always` and the ones for the
        \\capabilities it asked for; the rest are not refused, they are nil.
        \\
    );

    try group(ctx, "always", null);
    inline for (@typeInfo(Runtime.Capability).@"enum".field_values) |value| {
        const c: Runtime.Capability = @enumFromInt(value);
        try group(ctx, c.name(), c);
    }

    try w.writeAll("\nfenrir.store -- always, and a key space of this plugin's own\n");
    for (Runtime.store) |e| try writeEntry(ctx, "fenrir.store.", e);

    try w.writeAll("\nand in the globals\n");
    for (Runtime.globals) |e| try writeEntry(ctx, "", e);
}

fn countGated() usize {
    var n: usize = 0;
    for (galdr.Runtime.api) |e| {
        if (e.cap != null) n += 1;
    }
    return n;
}

/// One capability's functions, or the ungated ones when `cap` is null.
/// Prints nothing at all for a capability that has none, which is how a
/// reserved name shows as reserved without a word being written for it.
fn group(ctx: *Context, title: []const u8, cap: ?galdr.Runtime.Capability) !void {
    var any = false;
    for (galdr.Runtime.api) |e| {
        if (!std.meta.eql(e.cap, cap)) continue;
        if (!any) {
            try ctx.out.print("\n{s}\n", .{title});
            any = true;
        }
        try writeEntry(ctx, "fenrir.", e);
    }
}

fn writeEntry(ctx: *Context, prefix: []const u8, e: galdr.Runtime.Entry) !void {
    const w = ctx.out;
    // A function with no arguments still takes a pair of brackets, and the
    // difference matters here more than anywhere: `fenrir.page` is the
    // function and `fenrir.page()` is the page. The two entries with no
    // function behind them are fields and get neither.
    const args = if (e.args.len != 0) e.args else if (e.func != null) "()" else "";
    try w.print("  {s}{s}{s}", .{ prefix, e.name, args });
    if (e.returns.len != 0) try w.print(" -> {s}", .{e.returns});
    try w.print("\n        {s}\n", .{e.about});
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

    fn storeGet(ptr: *anyopaque, gpa: Allocator, plugin: []const u8, key: []const u8) ?[]u8 {
        const h = of(ptr);
        const lib = h.library orelse return null;
        var buf: [320]u8 = undefined;
        const full = library.pluginKey(&buf, plugin, key) orelse return null;
        const value = (lib.get(full) catch return null) orelse return null;
        defer h.ctx.gpa.free(value);
        return gpa.dupe(u8, value) catch null;
    }

    fn storeSet(ptr: *anyopaque, plugin: []const u8, key: []const u8, value: ?[]const u8) bool {
        const lib = of(ptr).library orelse return false;
        var buf: [320]u8 = undefined;
        const full = library.pluginKey(&buf, plugin, key) orelse return false;
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

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "every function in the fenrir table is documented, and only once" {
    if (!galdr.available) return error.SkipZigTest;
    // The reference is generated from the table that builds the table Lua
    // sees, so this is the check that keeps the two the same thing: a
    // function added without a sentence, or added twice, is caught here
    // rather than by a reader of `--api` wondering what it does.
    const Runtime = galdr.Runtime;
    inline for (.{ Runtime.api, Runtime.store, Runtime.globals }) |list| {
        for (list) |e| {
            try testing.expect(e.name.len != 0);
            try testing.expect(e.about.len != 0);
            // A sentence, not a label: anything shorter than this is a
            // restatement of the name.
            try testing.expect(e.about.len > 12);
        }
    }
    for (Runtime.api, 0..) |a, i| {
        for (Runtime.api[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
        try testing.expect(a.func != null);
    }
    for (Runtime.store) |e| try testing.expect(e.func != null);

    // The three that every plugin has, whatever it asked for. A capability
    // put on one of these would be a plugin that cannot declare itself.
    for ([_][]const u8{ "manifest", "on", "off" }) |name| {
        for (Runtime.api) |e| {
            if (std.mem.eql(u8, e.name, name)) try testing.expect(e.cap == null);
        }
    }
}
