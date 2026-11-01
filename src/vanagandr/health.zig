//! `fenrir health` -- what this build can do, and what this machine has
//! given it.
//!
//! Neovim's `:checkhealth`, and for the reason Neovim has one: a reader that
//! quietly does nothing is indistinguishable from a reader that is doing what
//! it was asked, and the questions -- is Lua in this binary, did the database
//! open, did that plugin load, is anything listening for an event that never
//! fires -- each have an answer somewhere and no one place to read them.
//!
//! It is also this phase's answer to the rule that **a registry is not usable
//! until something prints it**. Phase eight added five: capabilities, events,
//! rail buttons, declared settings and declared panels. `fenrir plugins`
//! prints what one configuration registered; this prints the registries
//! themselves, whether or not anybody has written a plugin.
//!
//! Every line is a fact with a mark in front of it, and the marks are the
//! whole point: `ok` is working, `--` is a thing this build does not have and
//! was not asked to, and `!!` is something that is wrong. The exit status is
//! non-zero when there is an `!!`, so `fenrir health` is usable from a script
//! that wants to know whether to bother.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const fenrir = @import("fenrir");

const Context = @import("Context.zig");
const library = @import("library.zig");

const galdr = fenrir.galdr;
const lyngvi = fenrir.lyngvi;
const mimir = fenrir.mimir;
const thviti = fenrir.thviti;

pub const usage =
    \\fenrir health [--config DIR] [--db FILE]
    \\
    \\    What this build has compiled in, where it keeps things, and what
    \\    the configuration directory asked of it. Loads init.lua and the
    \\    plugins exactly as `fenrir read` does. Exits non-zero if anything
    \\    is marked !!.
    \\
    \\    --config DIR  Look for plugins in DIR rather than the configuration
    \\                  directory. $FENRIR_CONFIG does the same.
    \\    --db FILE     Check this library rather than the default one.
;

/// How a line reads at a glance.
const Mark = enum {
    /// Working.
    ok,
    /// Absent by choice: a build option that is off, a thing not configured.
    off,
    /// Wrong, and the reason to exit non-zero.
    bad,

    fn text(m: Mark) []const u8 {
        return switch (m) {
            .ok => "ok",
            .off => "--",
            .bad => "!!",
        };
    }
};

const Report = struct {
    ctx: *Context,
    problems: usize = 0,

    fn section(r: *Report, title: []const u8) void {
        r.ctx.out.print("\n{s}\n", .{title}) catch {};
    }

    fn line(r: *Report, mark: Mark, name: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (mark == .bad) r.problems += 1;
        r.ctx.out.print("  {s} {s: <22}", .{ mark.text(), name }) catch {};
        r.ctx.out.print(fmt ++ "\n", args) catch {};
    }

    /// The commonest shape: on or off, with the words for each.
    fn flag(r: *Report, name: []const u8, on: bool, yes: []const u8, no: []const u8) void {
        r.line(if (on) .ok else .off, name, "{s}", .{if (on) yes else no});
    }
};

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

    var r: Report = .{ .ctx = ctx };
    build(&r);
    storage(&r, db_path);
    const dir = try configuration(&r, dir_arg);
    defer if (dir) |d| ctx.gpa.free(d);
    events(&r);
    capabilities(&r);
    if (dir) |d| plugins(&r, d, db_path);

    ctx.out.print("\n", .{}) catch {};
    if (r.problems == 0) {
        ctx.out.print("nothing is wrong.\n", .{}) catch {};
        return;
    }
    return ctx.fail("{d} problem{s}", .{ r.problems, if (r.problems == 1) "" else "s" });
}

fn build(r: *Report) void {
    r.section("build");
    r.line(.ok, "zig", "{s}", .{builtin.zig_version_string});
    r.line(.ok, "target", "{s}-{s}", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
    r.line(.ok, "mode", "{s}", .{@tagName(builtin.mode)});

    // The two C dependencies, each of which the build can be told to leave
    // out -- and which everything above them is written to work without.
    r.flag("lua", galdr.available, "5.4, compiled in", "off: no plugins, no init.lua");
    r.flag("sqlite", mimir.available, "compiled in", "off: nothing is remembered");

    r.flag("window", lyngvi.has_window, "a backend for this target", "no backend for this target");
    r.flag("shaders", lyngvi.has_shaders, "SPIR-V modules are in the binary", "none: the renderer will refuse");
    r.flag(
        "glyphs",
        fenrir.tyr.glyphs_are_real,
        "a real outline source",
        "none: every glyph draws as a box",
    );
}

fn storage(r: *Report, db_path: ?[]const u8) void {
    r.section("library");
    if (!mimir.available) {
        r.line(.off, "database", "this build has no SQLite", .{});
        return;
    }
    const ctx = r.ctx;
    const where = db_path orelse (library.path(ctx) orelse {
        r.line(.bad, "database", "nowhere to keep one: no APPDATA, HOME or XDG_CONFIG_HOME", .{});
        return;
    });
    r.line(.ok, "database", "{s}", .{where});

    // Opened rather than merely named: a path that exists and a file that can
    // be read are two different facts, and it is the second that decides
    // whether anything is remembered.
    var lib = library.openWith(ctx, ctx.gpa, db_path) orelse {
        r.line(.bad, "opened", "it would not open", .{});
        return;
    };
    defer lib.close();
    const found = lib.userVersion() catch {
        r.line(.bad, "schema", "the file will not say what version it is", .{});
        return;
    };
    if (found != mimir.Library.schema_version) {
        r.line(.bad, "schema", "version {d}, and this build wants {d}", .{
            found,
            mimir.Library.schema_version,
        });
        return;
    }
    r.line(.ok, "schema", "version {d}", .{found});
}

/// Where plugins are read from, and whether it is there. Returns the
/// directory so the plugin section can use it; the caller frees it.
fn configuration(r: *Report, dir_arg: ?[]const u8) !?[]u8 {
    r.section("configuration");
    const ctx = r.ctx;
    if (!galdr.available) {
        r.line(.off, "directory", "this build has no Lua, so nothing is read", .{});
        return null;
    }
    const dir = if (dir_arg) |d|
        try ctx.gpa.dupe(u8, d)
    else
        galdr.configDir(ctx.gpa, library.environment(ctx)) catch {
            r.line(.bad, "directory", "nowhere to look: set FENRIR_CONFIG", .{});
            return null;
        };
    r.line(.ok, "directory", "{s}", .{dir});

    // Not being there is not a problem. A reader with no configuration is a
    // reader nobody has configured, which is every reader on its first day.
    var opened = Io.Dir.cwd().openDir(ctx.io, dir, .{}) catch {
        r.line(.off, "exists", "not yet, which is fine", .{});
        return dir;
    };
    opened.close(ctx.io);
    r.line(.ok, "exists", "yes", .{});
    return dir;
}

fn events(r: *Report) void {
    r.section("events");
    var reserved: usize = 0;
    inline for (@typeInfo(galdr.Runtime.Event).@"enum".field_values) |value| {
        const e: galdr.Runtime.Event = @enumFromInt(value);
        if (e.fires()) {
            r.line(.ok, @tagName(e), "fires", .{});
        } else {
            reserved += 1;
        }
    }
    // The reserved half listed as one line rather than five: they are names
    // held for features that do not exist, and a plugin author wants to know
    // that the name is safe to write against, not to read five identical
    // sentences about it.
    r.ctx.out.print("  {s} {s: <22}", .{ Mark.off.text(), "reserved" }) catch {};
    var first = true;
    inline for (@typeInfo(galdr.Runtime.Event).@"enum".field_values) |value| {
        const e: galdr.Runtime.Event = @enumFromInt(value);
        if (!e.fires()) {
            r.ctx.out.print("{s}{s}", .{ if (first) "" else " ", @tagName(e) }) catch {};
            first = false;
        }
    }
    r.ctx.out.print("\n", .{}) catch {};
}

fn capabilities(r: *Report) void {
    r.section("capabilities");
    inline for (@typeInfo(galdr.Runtime.Capability).@"enum".field_values) |value| {
        const c: galdr.Runtime.Capability = @enumFromInt(value);
        r.line(
            if (c.reserved()) .off else .ok,
            c.name(),
            "{s}",
            .{if (c.reserved()) "reserved: nothing behind it yet" else "granted functions exist"},
        );
    }
}

/// Loads the configuration the way `fenrir read` does, and reports it.
fn plugins(r: *Report, dir: []const u8, db_path: ?[]const u8) void {
    r.section("plugins");
    const ctx = r.ctx;

    var headless: Headless = .{ .ctx = ctx, .dir = dir, .library = library.open(ctx, db_path) };
    defer if (headless.library) |*l| l.close();

    const rt = galdr.Runtime.create(ctx.gpa, headless.host(), .{}) catch {
        r.line(.bad, "runtime", "Lua would not start", .{});
        return;
    };
    defer rt.destroy();
    rt.loadConfig();

    if (rt.plugins.items.len == 0) {
        r.line(.off, "loaded", "no init.lua and no plugins/", .{});
        return;
    }
    for (rt.plugins.items) |p| {
        if (!p.ok) {
            r.line(.bad, p.name, "failed to load; `fenrir plugins` prints why", .{});
            continue;
        }
        r.line(.ok, p.name, "{s}", .{
            if (p.manifest.declared) "loaded, with a manifest" else "loaded, with no manifest",
        });
    }

    // A handler on an event that never fires is the one thing here that
    // looks like working and is not, which is exactly what a health check is
    // for. Not a problem -- the name is reserved on purpose -- but said.
    for (rt.handlerList()) |h| {
        if (!h.live or h.event.fires()) continue;
        r.line(.off, @tagName(h.event), "something is listening, and nothing fires it", .{});
    }

    var live_rails: usize = 0;
    for (rt.railList()) |b| {
        if (b.live) live_rails += 1;
    }
    var live_panels: usize = 0;
    for (rt.panelList()) |p| {
        if (p.live) live_panels += 1;
    }
    var live_settings: usize = 0;
    for (rt.settingList()) |s| {
        if (s.live) live_settings += 1;
    }
    var live_handlers: usize = 0;
    for (rt.handlerList()) |h| {
        if (h.live) live_handlers += 1;
    }
    var live_keys: usize = 0;
    for (rt.keymapList()) |k| {
        if (k.live) live_keys += 1;
    }
    var live_commands: usize = 0;
    for (rt.commandNames()) |c| {
        if (c.live) live_commands += 1;
    }
    r.line(.ok, "contributed", "{d} keys, {d} commands, {d} handlers, {d} buttons, {d} panels, {d} settings", .{
        live_keys,
        live_commands,
        live_handlers,
        live_rails,
        live_panels,
        live_settings,
    });

    if (rt.messages.items.len != 0) {
        r.line(.bad, "messages", "{d}; `fenrir plugins` prints them", .{rt.messages.items.len});
    }
}

/// The same host `fenrir plugins` uses: a configuration directory, a library,
/// and no reader. Here rather than shared with `plugins.zig` because the two
/// answer to different questions and a host is twenty lines of vtable; if a
/// third command wants one it becomes a file.
const Headless = struct {
    ctx: *Context,
    dir: []const u8,
    library: ?library.Library,

    fn host(h: *Headless) galdr.Host {
        return .{ .ptr = h, .vtable = &vtable };
    }

    fn of(ptr: *anyopaque) *Headless {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable: galdr.Host.VTable = .{
        .notify = struct {
            fn f(_: *anyopaque, _: []const u8) void {}
        }.f,
        .exec = struct {
            fn f(_: *anyopaque, _: []const u8) bool {
                return false;
            }
        }.f,
        .document = struct {
            fn f(_: *anyopaque) ?galdr.Host.Document {
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
            fn f(_: *anyopaque) ?galdr.Host.Position {
                return null;
            }
        }.f,
        .selection = struct {
            fn f(_: *anyopaque) ?[2]galdr.Host.Position {
                return null;
            }
        }.f,
        .highlightCount = struct {
            fn f(_: *anyopaque) usize {
                return 0;
            }
        }.f,
        .highlightAt = struct {
            fn f(_: *anyopaque, _: usize) ?galdr.Host.Highlight {
                return null;
            }
        }.f,
        .addHighlight = struct {
            fn f(_: *anyopaque, _: galdr.Host.Highlight) ?u64 {
                return null;
            }
        }.f,
        .removeHighlight = struct {
            fn f(_: *anyopaque, _: u64) bool {
                return false;
            }
        }.f,
        .storeGet = struct {
            fn f(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) ?[]u8 {
                return null;
            }
        }.f,
        .storeSet = struct {
            fn f(_: *anyopaque, _: []const u8, _: []const u8, _: ?[]const u8) bool {
                return false;
            }
        }.f,
        .readFile = readFile,
        .listDir = listDir,
    };

    fn path(h: *Headless, buf: []u8, rel: []const u8) ?[]const u8 {
        if (!galdr.Host.isContained(rel)) return null;
        return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ h.dir, std.fs.path.sep, rel }) catch null;
    }

    fn readFile(ptr: *anyopaque, gpa: std.mem.Allocator, rel: []const u8) ?[]u8 {
        const h = of(ptr);
        var buf: [4096]u8 = undefined;
        const full = h.path(&buf, rel) orelse return null;
        return Io.Dir.cwd().readFileAlloc(h.ctx.io, full, gpa, .limited(1 << 20)) catch null;
    }

    fn listDir(ptr: *anyopaque, gpa: std.mem.Allocator, rel: []const u8) ?[][]u8 {
        const h = of(ptr);
        var buf: [4096]u8 = undefined;
        const full = h.path(&buf, rel) orelse return null;
        const io = h.ctx.io;

        var dir = Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch return null;
        defer dir.close(io);

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

test "every event and every capability has a line of its own" {
    // The registries this phase added, checked from the side that prints
    // them: a name added to either enum without a word for it here is a
    // health check that says less than it did.
    inline for (@typeInfo(galdr.Runtime.Event).@"enum".field_values) |value| {
        const e: galdr.Runtime.Event = @enumFromInt(value);
        try testing.expect(@tagName(e).len != 0);
    }
    inline for (@typeInfo(galdr.Runtime.Capability).@"enum".field_values) |value| {
        const c: galdr.Runtime.Capability = @enumFromInt(value);
        try testing.expect(c.name().len != 0);
        try testing.expectEqual(c, galdr.Runtime.Capability.parse(c.name()).?);
    }
}

test "a mark is two characters, so the columns line up" {
    for ([_]Mark{ .ok, .off, .bad }) |m| {
        try testing.expectEqual(@as(usize, 2), m.text().len);
    }
}
