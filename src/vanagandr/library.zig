//! Opening Mímir's library from a command, and the three commands that are
//! nothing but the library: `fenrir recent`, `fenrir marks` and `fenrir config`.
//!
//! Every command that remembers anything goes through `open` here, so there
//! is one answer to where the database lives and one place that decides what
//! to do when there is none. That answer is always "carry on": a reader whose
//! library cannot be opened still opens documents, and says so once.

const std = @import("std");
const fenrir = @import("fenrir");
const Io = std.Io;

const Context = @import("Context.zig");
const mimir = fenrir.mimir;

pub const Library = mimir.Library;

/// The process environment, in the shape Mímir asks for.
pub fn environment(ctx: *const Context) mimir.Environment {
    return .{ .ptr = ctx, .lookup = lookup };
}

fn lookup(ptr: *const anyopaque, name: []const u8) ?[]const u8 {
    const ctx: *const Context = @ptrCast(@alignCast(ptr));
    return ctx.env(name);
}

/// Opens the library, or returns null and says why once.
///
/// `path` is `--db`, if it was given. A null return is not a failure of the
/// command: everything above this treats it as "this build, or this machine,
/// remembers nothing".
pub fn open(ctx: *Context, db: ?[]const u8) ?Library {
    return openWith(ctx, ctx.gpa, db);
}

/// The same, on an allocator of the caller's choosing.
///
/// The reader passes its own heap rather than the CLI's arena: a library
/// hands back strings the caller frees, and on an arena those frees are
/// no-ops that accumulate for as long as the window is open. It also keeps
/// one allocator on both sides of every row, which is what makes
/// `freeRecent` a method here rather than a free function that can be handed
/// the wrong one.
pub fn openWith(ctx: *Context, gpa: std.mem.Allocator, db: ?[]const u8) ?Library {
    if (!mimir.available) return null;
    const lib = mimir.open(gpa, ctx.io, environment(ctx), db);
    if (lib == null) ctx.note("no library: recent files and settings will not be remembered", .{});
    return lib;
}

/// Where the library is, for a message. Caller owns it.
pub fn path(ctx: *Context) ?[]u8 {
    return mimir.defaultPath(ctx.gpa, environment(ctx)) catch null;
}

/// Seconds since the Unix epoch, from the platform clock the `Io` carries.
pub fn now(io: Io) i64 {
    const t = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(t.nanoseconds, std.time.ns_per_s));
}

// -- fenrir recent -----------------------------------------------------------

pub const recent_usage =
    \\fenrir recent [--limit N] [--forget FILE] [--clear] [--db FILE]
    \\
    \\    The documents opened before, most recent first, with where each was
    \\    left. `fenrir read` writes these; nothing else does.
    \\
    \\    --limit N     How many to list. Defaults to 20.
    \\    --forget F    Drop one document from the list.
    \\    --clear       Drop all of them.
    \\    --db FILE     Use this database instead of the default.
;

pub fn recentRun(ctx: *Context, argv: []const []const u8) !void {
    var limit: u32 = 20;
    var forget: ?[]const u8 = null;
    var clear = false;
    var db_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--limit needs a count", .{});
            limit = std.fmt.parseInt(u32, argv[i], 10) catch
                return ctx.fail("--limit wants a number, not '{s}'", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--forget")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--forget needs a file", .{});
            forget = argv[i];
        } else if (std.mem.eql(u8, arg, "--clear")) {
            clear = true;
        } else if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--db needs a file", .{});
            db_path = argv[i];
        } else {
            return ctx.fail("unknown option {s}", .{arg});
        }
    }

    var lib = open(ctx, db_path) orelse return ctx.fail(
        "this build has no library: rebuild without -Dsqlite=false",
        .{},
    );
    defer lib.close();

    if (clear) {
        lib.forgetAll() catch |err| return ctx.fail("cannot clear: {t}", .{err});
        ctx.out.print("forgot every document\n", .{}) catch {};
        return;
    }
    if (forget) |f| {
        const dropped = lib.forget(f) catch |err| return ctx.fail("cannot forget: {t}", .{err});
        if (dropped == 0) {
            ctx.out.print("{s} was not in the list\n", .{f}) catch {};
        } else {
            ctx.out.print("forgot {s}\n", .{f}) catch {};
        }
        return;
    }

    const list = lib.recent(limit) catch |err| return ctx.fail("cannot read the list: {t}", .{err});
    defer lib.freeRecents(list, list.len);

    if (list.len == 0) {
        ctx.out.print("nothing opened yet\n", .{}) catch {};
        return;
    }
    for (list) |r| {
        // The page, and how far down it -- the second number is why
        // reopening lands on the line you were reading. Shown only when it is
        // not the top of the page, so the common case stays a short line.
        ctx.out.print("page {d: >4}", .{r.page + 1}) catch {};
        if (r.offset > 1) {
            ctx.out.print(" +{d: >4.0}pt", .{r.offset}) catch {};
        } else {
            ctx.out.print("        ", .{}) catch {};
        }
        ctx.out.print("  {s}", .{r.path}) catch {};
        if (r.title.len != 0) ctx.out.print("  ({s})", .{r.title}) catch {};
        ctx.out.print("\n", .{}) catch {};
    }
}

// -- fenrir marks ------------------------------------------------------------

pub const marks_usage =
    \\fenrir marks <file> [--clear] [--add PAGE X0 Y0 X1 Y1 [COLOUR]]
    \\                    [--ink PAGE X Y X Y ... [COLOUR]] [--db FILE]
    \\
    \\    The marks made on a document, which `fenrir read` draws and keeps
    \\    here rather than writing into the PDF: the highlights made with m
    \\    or a palette colour, and the ink drawn in draw mode. A selection is
    \\    not a mark and is never stored.
    \\
    \\    fenrir marks paper.pdf              list them
    \\    fenrir marks paper.pdf --clear      remove every one, ink included
    \\    fenrir marks paper.pdf --add 3 72 700 300 712 yellow
    \\                                        add a highlight, for scripting
    \\    fenrir marks paper.pdf --ink 3 72 700 120 690 160 705 red
    \\                                        draw a stroke, the same way
    \\
    \\    Pages are numbered from 1. Boxes and strokes alike are in PDF points
    \\    on the page as it is displayed, measured from its bottom-left corner
    \\    -- the same numbers `read` stores when it makes a highlight.
;

pub fn marksRun(ctx: *Context, argv: []const []const u8) !void {
    var file: ?[]const u8 = null;
    var db_path: ?[]const u8 = null;
    var clear = false;
    var add: ?Library.Highlight = null;
    var colour: []const u8 = "";
    var ink_page: ?u32 = null;
    var ink: std.ArrayList(fenrir.gelgja.Point) = .empty;
    defer ink.deinit(ctx.gpa);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--db needs a file", .{});
            db_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--clear")) {
            clear = true;
        } else if (std.mem.eql(u8, arg, "--add")) {
            if (i + 5 >= argv.len) return ctx.fail("--add needs PAGE X0 Y0 X1 Y1", .{});
            const page = std.fmt.parseInt(u32, argv[i + 1], 10) catch
                return ctx.fail("--add wants a page number, not '{s}'", .{argv[i + 1]});
            if (page == 0) return ctx.fail("pages are numbered from 1", .{});
            var box: [4]f32 = undefined;
            for (&box, 0..) |*v, k| {
                v.* = std.fmt.parseFloat(f32, argv[i + 2 + k]) catch
                    return ctx.fail("--add wants numbers, not '{s}'", .{argv[i + 2 + k]});
            }
            add = .{
                .page = page - 1,
                .x0 = @min(box[0], box[2]),
                .y0 = @min(box[1], box[3]),
                .x1 = @max(box[0], box[2]),
                .y1 = @max(box[1], box[3]),
            };
            i += 5;
            // An optional colour, if the next word is not another option.
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                i += 1;
                colour = argv[i];
                if (Library.parseColor(colour) == null) {
                    return ctx.fail("{s} is not a colour: try a name or #rrggbb", .{colour});
                }
            }
        } else if (std.mem.eql(u8, arg, "--ink")) {
            // A page and then every number until the next option, in pairs.
            // Variadic because a stroke has no fixed length, which is the
            // whole difference between ink and a highlight.
            if (i + 1 >= argv.len) return ctx.fail("--ink needs PAGE X Y X Y ...", .{});
            i += 1;
            const page = std.fmt.parseInt(u32, argv[i], 10) catch
                return ctx.fail("--ink wants a page number, not '{s}'", .{argv[i]});
            if (page == 0) return ctx.fail("pages are numbered from 1", .{});
            ink_page = page - 1;
            while (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                // A word that is not a number ends the stroke and is the
                // colour, as it is for `--add`.
                const x = std.fmt.parseFloat(f32, argv[i + 1]) catch break;
                if (i + 2 == argv.len) return ctx.fail("--ink wants x and y in pairs", .{});
                const y = std.fmt.parseFloat(f32, argv[i + 2]) catch
                    return ctx.fail("--ink wants x and y in pairs, not '{s}'", .{argv[i + 2]});
                try ink.append(ctx.gpa, .{ .x = x, .y = y });
                i += 2;
            }
            if (ink.items.len < 2) return ctx.fail("a stroke is at least two points", .{});
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                i += 1;
                colour = argv[i];
                if (Library.parseColor(colour) == null) {
                    return ctx.fail("{s} is not a colour: try a name or #rrggbb", .{colour});
                }
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ctx.fail("unknown option {s}", .{arg});
        } else if (file == null) {
            file = arg;
        } else {
            return ctx.fail("marks takes one file", .{});
        }
    }

    const name = file orelse return ctx.fail("marks needs a file", .{});
    var lib = open(ctx, db_path) orelse return ctx.fail(
        "this build has no library: rebuild without -Dsqlite=false",
        .{},
    );
    defer lib.close();

    // The same key `read` uses, or the two would never find each other's
    // highlights.
    const key = try absolute(ctx, name);
    defer ctx.gpa.free(key);

    if (clear) {
        // Both tables, because `--clear` means the document goes back to
        // being unmarked, and a reader who cleared their marks and still
        // found ink on page four would rightly call that a bug.
        const n = lib.clearHighlights(key) catch |err| return ctx.fail("cannot clear: {t}", .{err});
        const k = lib.clearStrokes(key) catch |err| return ctx.fail("cannot clear: {t}", .{err});
        ctx.out.print("removed {d} highlight{s} and {d} stroke{s}\n", .{
            n, if (n == 1) "" else "s",
            k, if (k == 1) "" else "s",
        }) catch {};
        return;
    }

    if (add) |h| {
        var row = h;
        // Normalised before it is stored, so the file holds `#rrggbb` whatever
        // name was typed -- the form `read` writes, and the one a person
        // editing the file would expect.
        var hex: [8]u8 = undefined;
        if (colour.len != 0) {
            const c = Library.parseColor(colour).?;
            row.color = @constCast(std.fmt.bufPrint(&hex, "#{x:0>2}{x:0>2}{x:0>2}", .{
                toByte(c.r), toByte(c.g), toByte(c.b),
            }) catch unreachable);
        }
        const id = lib.addHighlight(key, row, now(ctx.io)) catch |err|
            return ctx.fail("cannot add: {t}", .{err});
        ctx.out.print("added highlight {d} on page {d}\n", .{ id, h.page + 1 }) catch {};
        return;
    }

    if (ink_page) |page| {
        var hex: [8]u8 = undefined;
        var text: []const u8 = "";
        if (colour.len != 0) {
            const c = Library.parseColor(colour).?;
            text = std.fmt.bufPrint(&hex, "#{x:0>2}{x:0>2}{x:0>2}", .{
                toByte(c.r), toByte(c.g), toByte(c.b),
            }) catch unreachable;
        }
        const id = lib.addStroke(key, .{
            .page = page,
            .color = @constCast(text),
            .points = ink.items,
        }, now(ctx.io)) catch |err| return ctx.fail("cannot add: {t}", .{err});
        ctx.out.print("added stroke {d} of {d} points on page {d}\n", .{
            id, ink.items.len, page + 1,
        }) catch {};
        return;
    }

    const list = lib.highlights(key) catch |err| return ctx.fail("cannot read them: {t}", .{err});
    defer lib.freeHighlights(list, list.len);

    const strokes = lib.strokes(key) catch |err| return ctx.fail("cannot read them: {t}", .{err});
    defer lib.freeStrokes(strokes, strokes.len);

    if (list.len == 0 and strokes.len == 0) {
        ctx.out.print("no marks in {s}\n", .{name}) catch {};
        return;
    }
    for (list) |h| {
        ctx.out.print("page {d: >4}  ({d:.1}, {d:.1}) - ({d:.1}, {d:.1})", .{
            h.page + 1, h.x0, h.y0, h.x1, h.y1,
        }) catch {};
        if (h.color.len != 0) ctx.out.print("  {s}", .{h.color}) catch {};
        if (h.note.len != 0) ctx.out.print("  \"{s}\"", .{h.note}) catch {};
        ctx.out.print("\n", .{}) catch {};
    }
    // The box a stroke covers rather than the points it is made of: a line
    // of forty coordinates is not something anybody reads off a terminal,
    // and where it is and how long it is are the two facts worth printing.
    // The file itself is where the points are, and it is readable on purpose.
    for (strokes) |k| {
        var box: fenrir.gelgja.Bounds = .empty;
        for (k.points) |p| box = box.add(p);
        ctx.out.print("page {d: >4}  ink {d} points  ({d:.1}, {d:.1}) - ({d:.1}, {d:.1})", .{
            k.page + 1, k.points.len, box.min_x, box.min_y, box.max_x, box.max_y,
        }) catch {};
        if (k.color.len != 0) ctx.out.print("  {s}", .{k.color}) catch {};
        if (k.width != 0) ctx.out.print("  w{d:.2}", .{k.width}) catch {};
        ctx.out.print("\n", .{}) catch {};
    }
}

fn toByte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// The path a document is keyed under. Must match `read.zig`'s
/// `absolutePath` exactly, which is why it is the same call: a highlight
/// added here under a relative path would be invisible to the reader.
/// The key every command uses for a document in the library: its real path,
/// or what was typed when the filesystem will not resolve it. Public because
/// `fenrir run` writes highlights too, and two commands that keyed a
/// document differently would never find each other's.
pub fn absolute(ctx: *Context, file: []const u8) std.mem.Allocator.Error![]u8 {
    if (Io.Dir.cwd().realPathFileAlloc(ctx.io, file, ctx.gpa)) |real| {
        defer ctx.gpa.free(real);
        return ctx.gpa.dupe(u8, real);
    } else |_| {}
    return ctx.gpa.dupe(u8, file);
}

// -- fenrir config -----------------------------------------------------------

pub const config_usage =
    \\fenrir config [KEY [VALUE]] [--unset KEY] [--db FILE]
    \\
    \\    The settings the reader keeps. With no arguments, prints them all.
    \\
    \\    fenrir config                  list every setting
    \\    fenrir config author           print one
    \\    fenrir config author "Name"    set one
    \\    fenrir config accent yellow    a colour by name, or #rrggbb
    \\    fenrir config theme light      dark or light
    \\    fenrir config --unset accent   back to the default
    \\
    \\    Known keys:
    \\      author   the name annotations are signed with
    \\      accent   the colour the interface draws its own marks in
    \\      theme    which set of colours the interface is drawn in
    \\      zoom     the zoom a document opens at, or `fit`
;

pub fn configRun(ctx: *Context, argv: []const []const u8) !void {
    var db_path: ?[]const u8 = null;
    var unset: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var value: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--db needs a file", .{});
            db_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--unset")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--unset needs a key", .{});
            unset = argv[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ctx.fail("unknown option {s}", .{arg});
        } else if (key == null) {
            key = arg;
        } else if (value == null) {
            value = arg;
        } else {
            return ctx.fail("config takes a key and a value", .{});
        }
    }

    var lib = open(ctx, db_path) orelse return ctx.fail(
        "this build has no library: rebuild without -Dsqlite=false",
        .{},
    );
    defer lib.close();

    if (unset) |k| {
        lib.remove(k) catch |err| return ctx.fail("cannot unset {s}: {t}", .{ k, err });
        ctx.out.print("unset {s}\n", .{k}) catch {};
        return;
    }

    if (key) |k| {
        if (value) |v| {
            // A colour is checked here rather than stored and found wrong on
            // the next start, when whoever typed it is no longer watching.
            if (std.mem.eql(u8, k, "accent")) {
                const c = Library.parseColor(v) orelse
                    return ctx.fail("{s} is not a colour: try a name or #rrggbb", .{v});
                lib.setAccent(c) catch |err| return ctx.fail("cannot set accent: {t}", .{err});
                ctx.out.print("accent = {s}\n", .{v}) catch {};
                return;
            }
            // The same argument as a colour: a theme nobody has is found
            // here, while whoever typed it is still watching, rather than on
            // the next start by quietly staying dark.
            if (std.mem.eql(u8, k, "theme")) {
                if (fenrir.thviti.Theme.byName(v) == null) {
                    var names: std.Io.Writer.Allocating = .init(ctx.gpa);
                    defer names.deinit();
                    for (fenrir.thviti.Theme.all, 0..) |t, n| {
                        names.writer.print("{s}{s}", .{ if (n == 0) "" else ", ", t.name }) catch {};
                    }
                    return ctx.fail("no theme called {s}: there is {s}", .{ v, names.written() });
                }
                lib.setTheme(v) catch |err| return ctx.fail("cannot set theme: {t}", .{err});
                ctx.out.print("theme = {s}\n", .{v}) catch {};
                return;
            }
            lib.set(k, v) catch |err| return ctx.fail("cannot set {s}: {t}", .{ k, err });
            ctx.out.print("{s} = {s}\n", .{ k, v }) catch {};
            return;
        }

        const got = lib.get(k) catch |err| return ctx.fail("cannot read {s}: {t}", .{ k, err });
        if (got) |text| {
            defer ctx.gpa.free(text);
            ctx.out.print("{s}\n", .{text}) catch {};
        } else {
            ctx.out.print("{s} is not set\n", .{k}) catch {};
        }
        return;
    }

    const all = lib.settings() catch |err| return ctx.fail("cannot read the settings: {t}", .{err});
    defer lib.freeSettings(all);
    if (all.len == 0) {
        ctx.out.print("no settings\n", .{}) catch {};
    } else {
        for (all) |s| ctx.out.print("{s} = {s}\n", .{ s.key, s.value }) catch {};
    }

    // Where the file is, and what wrote it: the two things to know before
    // deleting it or asking why a setting did not take.
    if (db_path) |p| {
        ctx.out.print("library: {s}", .{p}) catch {};
    } else if (path(ctx)) |where| {
        defer ctx.gpa.free(where);
        ctx.out.print("library: {s}", .{where}) catch {};
    } else {
        ctx.out.print("library: nowhere this platform would put one", .{}) catch {};
    }
    ctx.out.print(" (SQLite {s})\n", .{mimir.Db.version()}) catch {};
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "the environment reaches Mímir through the context" {
    // The path decision is Mímir's; what is checked here is that a command
    // hands it the process's environment rather than reading one of its own.
    var out: Io.Writer.Discarding = .init(&.{});
    var ctx: Context = .{
        .gpa = testing.allocator,
        .io = undefined,
        .out = &out.writer,
        .err = &out.writer,
    };
    // With no environment at all there is nothing to find, and `path`
    // reports that rather than inventing a location.
    try testing.expect(ctx.env("FENRIR_DB") == null);
    try testing.expect(path(&ctx) == null);
}
