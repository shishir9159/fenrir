//! `fenrir run <script.lua> [document.pdf]` -- a plugin over a document, with
//! no window.
//!
//! The reader is where a plugin is *used*, and it is a poor place to write
//! one: every change is a restart, every `print` is a line in a title bar that
//! is gone by the time you have read it, and anything that touches a document
//! has to be reached by opening one and scrolling to it. `fenrir plugins`
//! answers "did it load"; this answers "what does it do".
//!
//! It is also the honest way to use this program from a script. A plugin that
//! counts something, marks something, or reports something needs no interface
//! at all, and a reader that can only be driven from a window is a reader that
//! cannot be put in a pipeline.
//!
//! ## What a script sees
//!
//! Exactly the `Host` the reader implements, over a real `Document`: the
//! path, the title, the page count, a current page that `fenrir.go` moves,
//! a zoom, the highlights the library holds for that file, and a store. What
//! it does not see is a window, so `fenrir.exec` fails and says why, and
//! everything that draws -- rails, panels, settings -- is accepted and
//! recorded and never shown. Recorded rather than refused because a plugin
//! written for the reader should *run* here, not be rewritten for here.
//!
//! The events fire in the order the reader fires them: every document opens
//! with `DocOpen`, then `Start`, then `Quit` on the way out -- so a plugin
//! written against those does the same work here that it does in the window.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");
const library = @import("library.zig");

const galdr = fenrir.galdr;
const Host = galdr.Host;
const Library = library.Library;
const Marks = fenrir.hlidskjalf.Marks;

pub const usage =
    \\fenrir run <script.lua> [file...] [--config DIR] [--db FILE] [--plugins]
    \\
    \\    Runs a Lua script against the documents named, with no window. The
    \\    script sees the same `fenrir` table a plugin sees: the document, its
    \\    pages, its highlights, and its own store. Events fire in the order
    \\    the reader fires them -- DocOpen for each file, then Start, then
    \\    Quit -- so a plugin runs here unchanged.
    \\
    \\    print and fenrir.notify go to standard output. Exits non-zero if
    \\    the script fails.
    \\
    \\    --config DIR  Where `require` looks, and where --plugins reads from.
    \\                  $FENRIR_CONFIG does the same.
    \\    --plugins     Load init.lua and plugins/ first, as the reader does.
    \\    --db FILE     The library highlights and `fenrir.store` use.
    \\    --quiet       Only what the script says; no frame around it.
;

pub fn run(ctx: *Context, argv: []const []const u8) !void {
    var script: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var dir_arg: ?[]const u8 = null;
    var db_path: ?[]const u8 = null;
    var with_plugins = false;
    var quiet = false;

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
        } else if (std.mem.eql(u8, arg, "--plugins")) {
            with_plugins = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ctx.fail("unknown option {s}", .{arg});
        } else if (script == null) {
            script = arg;
        } else {
            try files.append(ctx.gpa, arg);
        }
    }

    const path = script orelse return ctx.fail("run needs a script", .{});
    if (!galdr.available) return ctx.fail("this build has no Lua: rebuild without -Dlua=false", .{});

    const source = ctx.readFile(path) catch |err|
        return ctx.fail("cannot read {s}: {t}", .{ path, err });

    // The configuration directory is where `require` looks, and it is not
    // needed for a script that requires nothing -- so a machine with no home
    // runs a script, and only `require` fails.
    const dir = if (dir_arg) |d|
        try ctx.gpa.dupe(u8, d)
    else
        galdr.configDir(ctx.gpa, library.environment(ctx)) catch "";

    var driver: Driver = .{
        .ctx = ctx,
        .dir = dir,
        .library = library.open(ctx, db_path),
        .quiet = quiet,
    };
    defer driver.deinit();

    for (files.items) |file| try driver.openDocument(file);

    const rt = galdr.Runtime.create(ctx.gpa, driver.host(), .{}) catch |err|
        return ctx.fail("cannot start Lua: {t}", .{err});
    defer rt.destroy();
    driver.runtime = rt;

    if (with_plugins) {
        rt.loadConfig();
        for (rt.plugins.items) |p| {
            if (!p.ok) ctx.note("{s} failed to load", .{p.name});
        }
    }

    const ok = rt.runPlugin(path, source);

    // The reader's order, so that a plugin that listens rather than doing its
    // work at the top level runs the same way it would in a window.
    for (driver.documents.items, 0..) |d, index| {
        driver.at = index;
        rt.emit(.{ .event = .DocOpen, .path = d.path, .data = .{ .document = .{
            .path = d.path,
            .title = d.title,
            .pages = @intCast(d.pages.len),
        } } });
    }
    driver.at = 0;
    rt.emit(.{ .event = .Start });
    driver.settle();
    rt.emit(.{ .event = .Quit, .path = driver.currentPath() });
    driver.settle();

    if (!quiet) driver.summarise();
    if (!ok or rt.messages.items.len != 0) {
        for (rt.messages.items) |m| ctx.err.print("{s}\n", .{m}) catch {};
        return ctx.fail("the script failed", .{});
    }
}

/// One open document, and where the script is in it.
const Open = struct {
    path: []const u8,
    title: []const u8,
    doc: *fenrir.Document,
    bytes: []u8,
    pages: []const fenrir.Page,
    /// From zero here and from one in Lua, as everywhere else.
    page: u32 = 0,
    zoom: f32 = 100,
};

/// The reader, as much of it as exists without a window.
const Driver = struct {
    ctx: *Context,
    dir: []const u8,
    library: ?Library,
    quiet: bool,
    runtime: ?*galdr.Runtime = null,

    documents: std.ArrayList(Open) = .empty,
    /// Which document is the focused one. A window has one; this has the
    /// first, until a plugin's handler is being told about another.
    at: usize = 0,
    /// Marks read for the document being asked about, so that `highlightAt`
    /// can answer by index the way the reader's does.
    ///
    /// Two lists and one index space, highlights then ink -- which is the
    /// order the reader's `Marks` holds them in, and it has to be the same
    /// order or `fenrir.highlights()` would mean one thing in a window and
    /// another in a script.
    marks: []Library.Highlight = &.{},
    ink: []Library.Stroke = &.{},
    marks_for: []const u8 = "",
    /// A highlight's colour as text, for the one call being answered.
    hex: [7]u8 = undefined,

    said: usize = 0,
    refused: usize = 0,

    fn deinit(d: *Driver) void {
        const gpa = d.ctx.gpa;
        if (d.library) |lib| {
            lib.freeHighlights(d.marks, d.marks.len);
            lib.freeStrokes(d.ink, d.ink.len);
            var l = lib;
            l.close();
        }
        for (d.documents.items) |o| {
            o.doc.deinit();
            gpa.destroy(o.doc);
            gpa.free(o.bytes);
            gpa.free(o.path);
        }
        d.documents.deinit(gpa);
        if (d.dir.len != 0) gpa.free(d.dir);
    }

    fn openDocument(d: *Driver, file: []const u8) !void {
        const ctx = d.ctx;
        const gpa = ctx.gpa;
        const bytes = ctx.readFileWith(gpa, file) catch |err|
            return ctx.fail("cannot read {s}: {t}", .{ file, err });

        const doc = try gpa.create(fenrir.Document);
        doc.* = fenrir.open(gpa, bytes) catch |err| {
            gpa.destroy(doc);
            gpa.free(bytes);
            return ctx.fail("cannot open {s}: {t}", .{ file, err });
        };
        const pages = fenrir.pages.all(doc) catch &.{};
        try d.documents.append(gpa, .{
            // The real path, which is the key `read` and `marks` use: a
            // script that keyed a document by what was typed would write
            // highlights neither of the others could ever find.
            .path = try library.absolute(ctx, file),
            .title = std.fs.path.basename(file),
            .doc = doc,
            .bytes = bytes,
            .pages = pages,
        });
    }

    fn current(d: *Driver) ?*Open {
        if (d.at >= d.documents.items.len) return null;
        return &d.documents.items[d.at];
    }

    fn currentPath(d: *Driver) []const u8 {
        const o = d.current() orelse return "";
        return o.path;
    }

    /// Resumes every handler that yielded, until none has anything left.
    ///
    /// Unlike the reader, which gives one resumption a frame: there is no
    /// next frame here, so "give the rest of the work back" has to mean
    /// "finish it before the process exits". The resume limit is what stops a
    /// handler that yields forever.
    fn settle(d: *Driver) void {
        const rt = d.runtime orelse return;
        while (rt.waiting() != 0) rt.pump();
    }

    fn summarise(d: *Driver) void {
        const w = d.ctx.out;
        const rt = d.runtime orelse return;
        w.print("\n{d} document{s}, {d} line{s} said", .{
            d.documents.items.len,
            if (d.documents.items.len == 1) "" else "s",
            d.said,
            if (d.said == 1) "" else "s",
        }) catch {};
        var handlers: usize = 0;
        for (rt.handlerList()) |h| {
            if (h.live) handlers += 1;
        }
        if (handlers != 0) w.print(", {d} handler{s}", .{ handlers, if (handlers == 1) "" else "s" }) catch {};
        // What a window would have drawn and this could not. Said rather than
        // hidden: a plugin that put three buttons somewhere and saw nothing
        // happen should be told where they went.
        if (d.refused != 0) {
            w.print(", {d} command line{s} with no reader to run {s}", .{
                d.refused,
                if (d.refused == 1) "" else "s",
                if (d.refused == 1) "it" else "them",
            }) catch {};
        }
        w.print("\n", .{}) catch {};
    }

    // -- the host ------------------------------------------------------------

    fn host(d: *Driver) Host {
        return .{ .ptr = d, .vtable = &vtable };
    }

    fn of(ptr: *anyopaque) *Driver {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable: Host.VTable = .{
        .notify = notify,
        .exec = exec,
        .document = document,
        .page = page,
        .goTo = goTo,
        .zoom = zoom,
        .setZoom = setZoom,
        .mode = struct {
            fn f(_: *anyopaque) []const u8 {
                // There is no keymap here, and normal is what a reader is in
                // when nobody has pressed anything.
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
        .highlightCount = highlightCount,
        .highlightAt = highlightAt,
        .addHighlight = addHighlight,
        .removeHighlight = removeHighlight,
        .storeGet = storeGet,
        .storeSet = storeSet,
        .readFile = readFile,
        .listDir = listDir,
    };

    fn notify(ptr: *anyopaque, message: []const u8) void {
        const d = of(ptr);
        d.said += 1;
        d.ctx.out.print("{s}\n", .{message}) catch {};
    }

    fn exec(ptr: *anyopaque, line: []const u8) bool {
        const d = of(ptr);
        d.refused += 1;
        if (!d.quiet) d.ctx.note("no reader here, so `{s}` did nothing", .{line});
        return false;
    }

    fn document(ptr: *anyopaque) ?Host.Document {
        const o = of(ptr).current() orelse return null;
        return .{ .path = o.path, .title = o.title, .pages = @intCast(o.pages.len) };
    }

    fn page(ptr: *anyopaque) ?u32 {
        const o = of(ptr).current() orelse return null;
        return o.page + 1;
    }

    fn goTo(ptr: *anyopaque, to: u32, _: f32) bool {
        const o = of(ptr).current() orelse return false;
        if (to == 0 or to > o.pages.len) return false;
        o.page = to - 1;
        return true;
    }

    fn zoom(ptr: *anyopaque) ?f32 {
        const o = of(ptr).current() orelse return null;
        return o.zoom;
    }

    fn setZoom(ptr: *anyopaque, percent: f32) void {
        const o = of(ptr).current() orelse return;
        o.zoom = percent;
    }

    /// The marks of the focused document, read once and kept until the focus
    /// moves or one is written.
    ///
    /// Read rather than held from the start because a script may add one and
    /// then ask for the list, and the list it gets should have it in.
    fn loadMarks(d: *Driver) void {
        const lib = d.library orelse return;
        const o = d.current() orelse return;
        if (std.mem.eql(u8, d.marks_for, o.path) and d.marks_for.len != 0) return;
        lib.freeHighlights(d.marks, d.marks.len);
        lib.freeStrokes(d.ink, d.ink.len);
        d.marks = lib.highlights(o.path) catch &.{};
        d.ink = lib.strokes(o.path) catch &.{};
        d.marks_for = o.path;
    }

    fn forget(d: *Driver) void {
        const lib = d.library orelse return;
        lib.freeHighlights(d.marks, d.marks.len);
        lib.freeStrokes(d.ink, d.ink.len);
        d.marks = &.{};
        d.ink = &.{};
        d.marks_for = "";
    }

    fn highlightCount(ptr: *anyopaque) usize {
        const d = of(ptr);
        d.loadMarks();
        return d.marks.len + d.ink.len;
    }

    fn highlightAt(ptr: *anyopaque, index: usize) ?Host.Highlight {
        const d = of(ptr);
        d.loadMarks();
        if (index >= d.marks.len) return d.strokeAt(index - d.marks.len);
        const list = d.marks;
        const h = list[index];
        return .{
            .id = @intCast(h.id),
            .page = h.page + 1,
            .x0 = h.x0,
            .y0 = h.y0,
            .x1 = h.x1,
            .y1 = h.y1,
            // Valid until the next call, which Galdr does not make until it
            // has copied this one into Lua -- the same promise the reader's
            // host makes, and for the same reason.
            .color = if (h.color.len <= d.hex.len) blk: {
                @memcpy(d.hex[0..h.color.len], h.color);
                break :blk d.hex[0..h.color.len];
            } else "",
            .note = h.note,
        };
    }

    /// A stroke, as an annotation: the box it covers, and `kind` to say that
    /// the box is not what it is. Where the pen went is not offered -- the
    /// API has no shape for a point list, and a plugin that wants one should
    /// have it added rather than inferred from a bounding box.
    fn strokeAt(d: *Driver, index: usize) ?Host.Highlight {
        if (index >= d.ink.len) return null;
        const k = d.ink[index];
        const box = Marks.inkBounds(k.points, k.width);
        return .{
            .id = @intCast(k.id),
            .page = k.page + 1,
            .x0 = box.min_x,
            .y0 = box.min_y,
            .x1 = box.max_x,
            .y1 = box.max_y,
            .color = if (k.color.len <= d.hex.len) blk: {
                @memcpy(d.hex[0..k.color.len], k.color);
                break :blk d.hex[0..k.color.len];
            } else "",
            .note = k.note,
            .kind = "ink",
        };
    }

    fn addHighlight(ptr: *anyopaque, h: Host.Highlight) ?u64 {
        const d = of(ptr);
        const lib = d.library orelse return null;
        const o = d.current() orelse return null;
        if (h.page == 0 or h.page > o.pages.len) return null;
        const id = lib.addHighlight(o.path, .{
            .page = h.page - 1,
            .x0 = @min(h.x0, h.x1),
            .y0 = @min(h.y0, h.y1),
            .x1 = @max(h.x0, h.x1),
            .y1 = @max(h.y0, h.y1),
            .color = @constCast(h.color),
            .note = @constCast(h.note),
        }, library.now(d.ctx.io)) catch return null;
        d.forget();
        return @intCast(id);
    }

    fn removeHighlight(ptr: *anyopaque, id: u64) bool {
        const d = of(ptr);
        const lib = d.library orelse return false;
        if (id == 0 or id > std.math.maxInt(i64)) return false;
        lib.removeHighlight(@intCast(id)) catch return false;
        d.forget();
        return true;
    }

    /// Plugin values live in Mímir's settings under `galdr.`, exactly as the
    /// reader's do, so a script and a window read the same values.
    fn storeKey(buf: []u8, key: []const u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "galdr.{s}", .{key}) catch null;
    }

    fn storeGet(ptr: *anyopaque, gpa: Allocator, key: []const u8) ?[]u8 {
        const d = of(ptr);
        const lib = d.library orelse return null;
        var buf: [256]u8 = undefined;
        const full = storeKey(&buf, key) orelse return null;
        const value = (lib.get(full) catch return null) orelse return null;
        defer d.ctx.gpa.free(value);
        return gpa.dupe(u8, value) catch null;
    }

    fn storeSet(ptr: *anyopaque, key: []const u8, value: ?[]const u8) bool {
        const lib = of(ptr).library orelse return false;
        var buf: [256]u8 = undefined;
        const full = storeKey(&buf, key) orelse return false;
        if (value) |v| lib.set(full, v) catch return false else lib.remove(full) catch return false;
        return true;
    }

    fn under(d: *Driver, buf: []u8, rel: []const u8) ?[]const u8 {
        if (d.dir.len == 0 or !Host.isContained(rel)) return null;
        return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ d.dir, std.fs.path.sep, rel }) catch null;
    }

    fn readFile(ptr: *anyopaque, gpa: Allocator, rel: []const u8) ?[]u8 {
        const d = of(ptr);
        var buf: [4096]u8 = undefined;
        const full = d.under(&buf, rel) orelse return null;
        return Io.Dir.cwd().readFileAlloc(d.ctx.io, full, gpa, .limited(1 << 20)) catch null;
    }

    fn listDir(ptr: *anyopaque, gpa: Allocator, rel: []const u8) ?[][]u8 {
        const d = of(ptr);
        var buf: [4096]u8 = undefined;
        const full = d.under(&buf, rel) orelse return null;
        const io = d.ctx.io;

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
