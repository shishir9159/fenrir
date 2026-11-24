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
const save = @import("save.zig");
const mimir = fenrir.mimir;

const Marks = fenrir.hlidskjalf.Marks;
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
/// Where one plugin's value lives in the settings table.
///
/// Under `galdr.` so that `fenrir config` shows it and a plugin cannot
/// overwrite `author`, and under the plugin's own name inside that, so that
/// three plugins keeping `enabled` keep three values. The separator is `/`,
/// which neither a plugin's name -- one component of a directory listing --
/// nor a key -- letters, digits, `_`, `-` and `.` -- can contain, so no key
/// a plugin is able to write reaches into another plugin's.
///
/// An empty namespace is the console's: `:lua` and `fenrir plugins` keep
/// the flat keys, which are also the ones written before plugins had a
/// namespace at all. Those are readable from `:lua` and are not migrated,
/// because nothing records which plugin wrote them.
pub fn pluginKey(buf: []u8, plugin: []const u8, key: []const u8) ?[]const u8 {
    if (plugin.len == 0) return std.fmt.bufPrint(buf, "galdr.{s}", .{key}) catch null;
    return std.fmt.bufPrint(buf, "galdr.{s}/{s}", .{ plugin, key }) catch null;
}

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
    \\                    [--style STYLE] [--ink PAGE X Y X Y ... [COLOUR]]
    \\                    [--patch PAGE X0 Y0 X1 Y1 TEXT]
    \\                    [--comment ANCHOR TEXT] [--link FROM TO [LABEL]]
    \\                    [--store pdf|library] [--bytes] [--db FILE]
    \\
    \\    The marks made on a document that the library holds and its file
    \\    does not yet: the highlights made with m or a palette colour, the
    \\    ink drawn in draw mode, the comments on them and the links between
    \\    those, and what was deleted of the file's own. `fenrir read` writes
    \\    them into the PDF on :w and when it closes; until then they are
    \\    here. A selection is not a mark and is never stored.
    \\
    \\    fenrir marks paper.pdf              list them
    \\    fenrir marks paper.pdf --clear      remove every one, ink, comments
    \\                                        and links included
    \\    fenrir marks paper.pdf --add 3 72 700 300 712 yellow
    \\                                        add a highlight, for scripting
    \\    --style STYLE                       what --add makes: highlight,
    \\                                        underline, strikeout, squiggly
    \\                                        or arrow
    \\    fenrir marks paper.pdf --ink 3 72 700 120 690 160 705 red
    \\                                        draw a stroke, the same way
    \\    fenrir marks paper.pdf --patch 3 72 700 300 712 "the right words"
    \\                                        hide the words in a box and set
    \\                                        a correction in their place
    \\    fenrir marks paper.pdf --comment f3 "is this right?"
    \\                                        comment on the mark named f3
    \\    fenrir marks paper.pdf --link f3 f7 supports
    \\                                        link two comments, by name
    \\    fenrir marks paper.pdf --store pdf  write them into the file, as
    \\                                        the reader does on :w, and
    \\                                        keep this document's there
    \\    fenrir marks paper.pdf --store library
    \\                                        take the file's out of it, into
    \\                                        the library, and keep them there:
    \\                                        the reader writes it no more
    \\    fenrir marks paper.pdf --bytes      each revision of the file, its
    \\                                        size, and what is in it
    \\
    \\    Pages are numbered from 1. Boxes and strokes alike are in PDF points
    \\    on the page as it is displayed, measured from its bottom-left corner
    \\    -- the same numbers `read` stores when it makes a highlight.
    \\
    \\    Each mark is listed with the name of its anchor: the lines one
    \\    selection marked share one, and a comment is made on it. Names are
    \\    the ones a PDF will hold as /NM, so they mean the same thing here,
    \\    in the reader and in the file.
;

pub fn marksRun(ctx: *Context, argv: []const []const u8) !void {
    var file: ?[]const u8 = null;
    var db_path: ?[]const u8 = null;
    var clear = false;
    var add: ?Library.Mark = null;
    var style: Marks.Style = .highlight;
    var colour: []const u8 = "";
    var ink_page: ?u32 = null;
    var ink: std.ArrayList(fenrir.gelgja.Point) = .empty;
    defer ink.deinit(ctx.gpa);
    var comment: ?struct { anchor: []const u8, text: []const u8 } = null;
    var patch: ?Library.Patch = null;
    var store: ?enum { pdf, library } = null;
    var bytes = false;
    var link: ?struct { from: []const u8, to: []const u8, label: []const u8 = "" } = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--db needs a file", .{});
            db_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--clear")) {
            clear = true;
        } else if (std.mem.eql(u8, arg, "--style")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--style needs a style", .{});
            style = std.meta.stringToEnum(Marks.Style, argv[i]) orelse
                return ctx.fail("{s} is not a style: highlight, underline, strikeout, squiggly or arrow", .{argv[i]});
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
        } else if (std.mem.eql(u8, arg, "--patch")) {
            // A box and nothing cut from it: a rectangle, as `V` makes. A
            // hull with its corners cut is the reader's to make from words.
            if (i + 6 >= argv.len) return ctx.fail("--patch needs PAGE X0 Y0 X1 Y1 TEXT", .{});
            const page = std.fmt.parseInt(u32, argv[i + 1], 10) catch
                return ctx.fail("--patch wants a page number, not '{s}'", .{argv[i + 1]});
            if (page == 0) return ctx.fail("pages are numbered from 1", .{});
            var box: [4]f32 = undefined;
            for (&box, 0..) |*v, k| {
                v.* = std.fmt.parseFloat(f32, argv[i + 2 + k]) catch
                    return ctx.fail("--patch wants numbers, not '{s}'", .{argv[i + 2 + k]});
            }
            patch = .{
                .page = page - 1,
                .x0 = @min(box[0], box[2]),
                .y0 = @min(box[1], box[3]),
                .x1 = @max(box[0], box[2]),
                .y1 = @max(box[1], box[3]),
                .text = @constCast(argv[i + 6]),
            };
            i += 6;
        } else if (std.mem.eql(u8, arg, "--store")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--store needs pdf or library", .{});
            store = if (std.mem.eql(u8, argv[i], "pdf"))
                .pdf
            else if (std.mem.eql(u8, argv[i], "library"))
                .library
            else
                return ctx.fail("--store is pdf or library, not {s}", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--bytes")) {
            bytes = true;
        } else if (std.mem.eql(u8, arg, "--comment")) {
            if (i + 2 >= argv.len) return ctx.fail("--comment needs ANCHOR TEXT", .{});
            comment = .{ .anchor = argv[i + 1], .text = argv[i + 2] };
            i += 2;
        } else if (std.mem.eql(u8, arg, "--link")) {
            if (i + 2 >= argv.len) return ctx.fail("--link needs FROM TO", .{});
            link = .{ .from = argv[i + 1], .to = argv[i + 2] };
            i += 2;
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                i += 1;
                link.?.label = argv[i];
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
    // The file's own history, which needs no library.
    if (bytes) return revisions(ctx, name);
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
        const n = lib.clearMarks(key) catch |err| return ctx.fail("cannot clear: {t}", .{err});
        const k = lib.clearStrokes(key) catch |err| return ctx.fail("cannot clear: {t}", .{err});
        const p = lib.clearPatches(key) catch |err| return ctx.fail("cannot clear: {t}", .{err});
        // And what was written on them, which has nothing left to be about.
        const c = lib.clearComments(key) catch |err| return ctx.fail("cannot clear: {t}", .{err});
        const l = lib.clearLinks(key) catch |err| return ctx.fail("cannot clear: {t}", .{err});
        ctx.out.print("removed {d} highlight{s}, {d} stroke{s}, {d} piece{s} of patches, {d} comment{s} and {d} link{s}\n", .{
            n, if (n == 1) "" else "s",
            k, if (k == 1) "" else "s",
            p, if (p == 1) "" else "s",
            c, if (c == 1) "" else "s",
            l, if (l == 1) "" else "s",
        }) catch {};
        return;
    }

    if (store) |where| return switch (where) {
        .pdf => storeInFile(ctx, &lib, key, name),
        .library => storeInLibrary(ctx, &lib, key, name),
    };
    if (comment) |c| return addComment(ctx, &lib, key, c.anchor, c.text);
    if (link) |l| return addLink(ctx, &lib, key, l.from, l.to, l.label);

    if (add) |h| {
        var row = h;
        row.style = @constCast(@tagName(style));
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
        var anchor: [Library.name_len]u8 = undefined;
        row.anchor = @constCast(try nextName(ctx, &lib, key, &anchor));
        _ = lib.addMark(key, row, now(ctx.io)) catch |err|
            return ctx.fail("cannot add: {t}", .{err});
        ctx.out.print("added {s} {s} on page {d}\n", .{ style.label(), row.anchor, h.page + 1 }) catch {};
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
        var anchor: [Library.name_len]u8 = undefined;
        const named = try nextName(ctx, &lib, key, &anchor);
        _ = lib.addStroke(key, .{
            .page = page,
            .color = @constCast(text),
            .points = ink.items,
            .anchor = @constCast(named),
        }, now(ctx.io)) catch |err| return ctx.fail("cannot add: {t}", .{err});
        ctx.out.print("added stroke {s} of {d} points on page {d}\n", .{
            named, ink.items.len, page + 1,
        }) catch {};
        return;
    }

    if (patch) |p| {
        if (p.text.len > Library.max_correction) return ctx.fail("a patch says at most {d} bytes", .{Library.max_correction});
        var row = p;
        var anchor: [Library.name_len]u8 = undefined;
        row.anchor = @constCast(try nextName(ctx, &lib, key, &anchor));
        _ = lib.addPatch(key, row, now(ctx.io)) catch |err| return ctx.fail("cannot add: {t}", .{err});
        ctx.out.print("added patch {s} on page {d}\n", .{ row.anchor, p.page + 1 }) catch {};
        return;
    }

    const list = lib.marks(key) catch |err| return ctx.fail("cannot read them: {t}", .{err});
    defer lib.freeMarks(list, list.len);

    const patched = lib.patches(key) catch |err| return ctx.fail("cannot read them: {t}", .{err});
    defer lib.freePatches(patched, patched.len);

    const strokes = lib.strokes(key) catch |err| return ctx.fail("cannot read them: {t}", .{err});
    defer lib.freeStrokes(strokes, strokes.len);

    const said = lib.comments(key) catch |err| return ctx.fail("cannot read them: {t}", .{err});
    defer lib.freeComments(said, said.len);

    const joined = lib.links(key) catch |err| return ctx.fail("cannot read them: {t}", .{err});
    defer lib.freeLinks(joined, joined.len);

    // The `/ID` the reader saw the file with last, which is what a link from
    // another document names it by.
    if (lib.fileId(key) catch null) |id| {
        defer ctx.gpa.free(id);
        ctx.out.print("id {s}\n", .{id}) catch {};
    }
    if (list.len == 0 and strokes.len == 0 and patched.len == 0 and said.len == 0) {
        ctx.out.print("no marks in {s}\n", .{name}) catch {};
        return;
    }
    for (list) |h| {
        ctx.out.print("page {d: >4}  ({d:.1}, {d:.1}) - ({d:.1}, {d:.1})  {s}", .{
            h.page + 1, h.x0, h.y0, h.x1, h.y1, h.anchor,
        }) catch {};
        if (!std.mem.eql(u8, h.style, "highlight")) ctx.out.print("  {s}", .{h.style}) catch {};
        if (h.color.len != 0) ctx.out.print("  {s}", .{h.color}) catch {};
        ctx.out.print("\n", .{}) catch {};
    }
    // The box a stroke covers rather than the points it is made of: a line
    // of forty coordinates is not something anybody reads off a terminal,
    // and where it is and how long it is are the two facts worth printing.
    // The file itself is where the points are, and it is readable on purpose.
    for (strokes) |k| {
        var box: fenrir.gelgja.Bounds = .empty;
        for (k.points) |p| box = box.add(p);
        ctx.out.print("page {d: >4}  ink {d} points  ({d:.1}, {d:.1}) - ({d:.1}, {d:.1})  {s}", .{
            k.page + 1, k.points.len, box.min_x, box.min_y, box.max_x, box.max_y, k.anchor,
        }) catch {};
        if (k.color.len != 0) ctx.out.print("  {s}", .{k.color}) catch {};
        if (k.width != 0) ctx.out.print("  w{d:.2}", .{k.width}) catch {};
        ctx.out.print("\n", .{}) catch {};
    }
    // A piece by its box, with the corners its hull cuts when it cuts any,
    // and what the patch says.
    for (patched) |p| {
        ctx.out.print("page {d: >4}  patch ({d:.1}, {d:.1}) - ({d:.1}, {d:.1})  {s}", .{
            p.page + 1, p.x0, p.y0, p.x1, p.y1, p.anchor,
        }) catch {};
        if (p.head != 0 or p.tail != 0) ctx.out.print("  cut {d:.1} {d:.1} {d:.1} {d:.1}", .{ p.head, p.tail, p.rise, p.fall }) catch {};
        if (p.color.len != 0) ctx.out.print("  {s}", .{p.color}) catch {};
        ctx.out.print("  \"{s}\"\n", .{p.text}) catch {};
    }
    // A comment by its own name and the anchor it hangs from, in the order
    // written, which is the order a thread reads in. The first on an anchor
    // has the anchor's name, as it will in the PDF.
    for (said) |c| {
        ctx.out.print("comment {s} on {s}  \"{s}\"\n", .{ c.nm, c.anchor, c.text }) catch {};
    }
    for (joined) |l| {
        ctx.out.print("link {s} -> {s}", .{ l.from, l.to }) catch {};
        if (l.other.len != 0) ctx.out.print(" in {s}", .{l.other}) catch {};
        if (l.label.len != 0) ctx.out.print("  {s}", .{l.label}) catch {};
        ctx.out.print("\n", .{}) catch {};
    }
}

/// The name the next thing written into a document gets, noted as handed
/// out so that no later one is given it again.
fn nextName(ctx: *Context, lib: *Library, key: []const u8, buf: *[Library.name_len]u8) ![]const u8 {
    const high = lib.highestName(key) catch |err| return ctx.fail("cannot read the names: {t}", .{err});
    lib.noteName(key, high + 1) catch |err| return ctx.fail("cannot note the name: {t}", .{err});
    return Library.makeName(buf, high + 1);
}

/// The file's bytes as they are, with what a save that did not finish left
/// put right first, so that nothing is appended to bytes another save was
/// in the middle of.
fn readRepaired(ctx: *Context, lib: *Library, key: []const u8, file: []const u8) ![]u8 {
    const gpa = ctx.gpa;
    var bytes = ctx.readFileWith(gpa, file) catch |err| return ctx.fail("cannot read {s}: {t}", .{ file, err });
    const verdict = save.repair(gpa, ctx.io, lib.*, key, file, bytes) catch |err| {
        gpa.free(bytes);
        return ctx.fail("cannot put the last save right: {t}", .{err});
    };
    if (verdict) |v| switch (v) {
        .finished => ctx.note("the last save into {s} had finished; its journal is cleared", .{file}),
        .torn => {
            ctx.note("the last save into {s} was cut short; it is cut back, and written again", .{file});
            gpa.free(bytes);
            bytes = ctx.readFileWith(gpa, file) catch |err| return ctx.fail("cannot read {s}: {t}", .{ file, err });
        },
        .foreign => ctx.note("{s} has changed since the last save began; that save is forgotten", .{file}),
    };
    return bytes;
}

/// `--store pdf`: the document's journal written into its file, as one
/// incremental update, and the document's marks kept there from now on.
fn storeInFile(ctx: *Context, lib: *Library, key: []const u8, file: []const u8) !void {
    const gpa = ctx.gpa;
    const bytes = try readRepaired(ctx, lib, key, file);
    // The document frees the bytes, opened or not.
    var doc = fenrir.open(gpa, bytes) catch |err| return ctx.fail("cannot open {s}: {t}", .{ file, err });
    defer doc.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var plan = save.planOf(arena.allocator(), lib.*, key) catch |err| return ctx.fail("cannot read the journal: {t}", .{err});
    if (plan.isEmpty()) {
        lib.setStore(key, "pdf") catch {};
        ctx.out.print("nothing to write: {s} holds every change\n", .{file}) catch {};
        return;
    }
    const author = lib.author() catch null;
    defer if (author) |name| gpa.free(name);
    plan.author = author orelse "";
    plan.when = now(ctx.io);

    var seed: [64]u8 = undefined;
    const update = save.write(gpa, ctx.io, lib.*, key, file, &doc, plan, std.fmt.bufPrint(&seed, "{d}", .{plan.when}) catch "", .in) catch |err|
        return ctx.fail("{s} is not written, and its marks stay in the library: {s}", .{ file, save.whyNot(err) });
    defer gpa.free(update);
    lib.setStore(key, "pdf") catch {};
    ctx.out.print("wrote {d} anchor{s}, {d} repl{s} and {d} deletion{s} into {s}: {d} bytes\n", .{
        plan.anchors.len + plan.notes.len, if (plan.anchors.len + plan.notes.len == 1) "" else "s",
        plan.replies.len,                  if (plan.replies.len == 1) "y" else "ies",
        plan.drops.len,                    if (plan.drops.len == 1) "" else "s",
        file,                              update.len,
    }) catch {};
}

/// `--comment`: a comment on an anchor that exists. The first on it takes
/// the anchor's name, because in a PDF it is the anchor's `/Contents`; a
/// later one is a reply and takes a name of its own.
fn addComment(ctx: *Context, lib: *Library, key: []const u8, anchor: []const u8, text: []const u8) !void {
    const blocks = lib.marks(key) catch |err| return ctx.fail("cannot read them: {t}", .{err});
    defer lib.freeMarks(blocks, blocks.len);
    const strokes = lib.strokes(key) catch |err| return ctx.fail("cannot read them: {t}", .{err});
    defer lib.freeStrokes(strokes, strokes.len);
    const said = lib.comments(key) catch |err| return ctx.fail("cannot read them: {t}", .{err});
    defer lib.freeComments(said, said.len);

    const marked = for (blocks) |h| {
        if (std.mem.eql(u8, h.anchor, anchor)) break true;
    } else for (strokes) |k| {
        if (std.mem.eql(u8, k.anchor, anchor)) break true;
    } else false;
    if (!marked) return ctx.fail("no mark in this document is named {s}: `fenrir marks` lists them", .{anchor});

    const taken = for (said) |c| {
        if (std.mem.eql(u8, c.nm, anchor)) break true;
    } else false;
    var buf: [Library.name_len]u8 = undefined;
    const nm = if (taken) try nextName(ctx, lib, key, &buf) else anchor;
    _ = lib.addComment(key, .{
        .anchor = @constCast(anchor),
        .nm = @constCast(nm),
        .text = @constCast(text),
    }, now(ctx.io)) catch |err| return ctx.fail("cannot add: {t}", .{err});
    ctx.out.print("added comment {s} on {s}\n", .{ nm, anchor }) catch {};
}

/// `--link`: two comments of this document joined. A link into another
/// document is the reader's to make, since it has to know that document's
/// `/ID`.
fn addLink(ctx: *Context, lib: *Library, key: []const u8, from: []const u8, to: []const u8, label: []const u8) !void {
    const said = lib.comments(key) catch |err| return ctx.fail("cannot read them: {t}", .{err});
    defer lib.freeComments(said, said.len);
    for ([_][]const u8{ from, to }) |end| {
        for (said) |c| {
            if (std.mem.eql(u8, c.nm, end)) break;
        } else return ctx.fail("no comment in this document is named {s}: a link joins two comments", .{end});
    }
    _ = lib.addLink(key, .{
        .from = @constCast(from),
        .to = @constCast(to),
        .label = @constCast(label),
    }, now(ctx.io)) catch |err| return ctx.fail("cannot add: {t}", .{err});
    ctx.out.print("linked {s} to {s}\n", .{ from, to }) catch {};
}

fn toByte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// The path a document is keyed under. Must match `read/Session.zig`'s
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

/// `--store library`: the marks the file holds taken out of it, into the
/// library (`save.takeOut`), by one update that drops them from `/Annots`,
/// and the document kept in the library from now on. `--store pdf` puts
/// them back under the same names.
fn storeInLibrary(ctx: *Context, lib: *Library, key: []const u8, file: []const u8) !void {
    const gpa = ctx.gpa;
    const bytes = try readRepaired(ctx, lib, key, file);
    var doc = fenrir.open(gpa, bytes) catch |err| return ctx.fail("cannot open {s}: {t}", .{ file, err });
    defer doc.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const when = now(ctx.io);
    const taken = save.takeOut(arena.allocator(), lib.*, key, &doc, when) catch |err|
        return ctx.fail("cannot take the marks out of {s}: {t}", .{ file, err });
    // Kept there whatever the file says next: the reader writes it no more.
    lib.setStore(key, "library") catch {};
    if (taken.plan.isEmpty()) {
        ctx.out.print("{s} holds no marks; its marks are kept in the library from now on\n", .{file}) catch {};
        return;
    }
    var seed: [64]u8 = undefined;
    const update = save.write(gpa, ctx.io, lib.*, key, file, &doc, taken.plan, std.fmt.bufPrint(&seed, "{d}", .{when}) catch "", .out) catch |err|
        return ctx.fail("{s} still holds its marks, and the library has them too: {s}", .{ file, save.whyNot(err) });
    defer gpa.free(update);
    ctx.out.print("took {d} anchor{s} and {d} comment{s} out of {s}, into the library: {d} bytes\n", .{
        taken.anchors,  if (taken.anchors == 1) "" else "s",
        taken.comments, if (taken.comments == 1) "" else "s",
        file,           update.len,
    }) catch {};
}

/// `--bytes`: each revision of the file, its size, and what is in it.
fn revisions(ctx: *Context, file: []const u8) !void {
    const bytes = ctx.readFileWith(ctx.gpa, file) catch |err| return ctx.fail("cannot read {s}: {t}", .{ file, err });
    defer ctx.gpa.free(bytes);
    save.describeRevisions(ctx.gpa, bytes, ctx.out) catch |err| return ctx.fail("cannot read {s}'s revisions: {t}", .{ file, err });
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
    \\      comment_anchor
    \\               what c leaves on the words: `highlight` or `arrow`
    \\      watch    `on` to follow a file another program rewrites; `off`,
    \\               the default, holds it so that none can
    \\      store    `pdf`, the default: marks are written into the file on
    \\               :w and when the reader closes it; `library` keeps
    \\               them here and never writes the file
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
            // And the same for what `c` leaves on the words, which a reader
            // would otherwise read as a highlight without a word said.
            if (std.mem.eql(u8, k, "comment_anchor")) {
                if (!std.mem.eql(u8, v, "highlight") and !std.mem.eql(u8, v, "arrow"))
                    return ctx.fail("comment_anchor is highlight or arrow, not {s}", .{v});
            }
            if (std.mem.eql(u8, k, "watch")) {
                if (!std.mem.eql(u8, v, "on") and !std.mem.eql(u8, v, "off"))
                    return ctx.fail("watch is on or off, not {s}", .{v});
            }
            // And whether the reader writes files at all.
            if (std.mem.eql(u8, k, "store")) {
                if (!std.mem.eql(u8, v, "pdf") and !std.mem.eql(u8, v, "library"))
                    return ctx.fail("store is pdf or library, not {s}", .{v});
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
