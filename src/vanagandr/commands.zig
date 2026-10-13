//! `fenrir commands` -- the command registry, printed.
//!
//! Every registry in this program gets a command that prints it in the same
//! commit it gets its table, because a registry nothing prints is a registry
//! whose mistakes are found by clicking. `fenrir icons` found three wrong
//! paths in the minute after it first ran; this is that command for the `:`
//! commands, and it does the same second job -- an entry can be *written*
//! and still be wrong, because its icon is a string that has to name
//! something the icon registry has heard of.
//!
//! So the listing opens an icon registry and asks. A command whose icon does
//! not resolve is marked and makes the command exit non-zero, which turns a
//! typo into a failing build step rather than a blank gutter somebody
//! notices six weeks later.
//!
//! Plugin commands are not here: they exist only once Lua has run, and
//! `fenrir plugins` loads the configuration and prints them. This is the
//! table that is in the binary.

const std = @import("std");
const fenrir = @import("fenrir");

const Context = @import("Context.zig");
const palette = @import("palette.zig");

const commands = fenrir.hlidskjalf.commands;
const Fonts = fenrir.tyr.Fonts;
const Icons = fenrir.thviti.Icons;

pub const usage =
    \\fenrir commands [--names] [--match QUERY]
    \\
    \\    Lists every built-in `:` command: its name, the abbreviations it
    \\    also answers to, what it takes, the keys that reach the same thing
    \\    without the command line, and what it is for. An entry naming an
    \\    icon the registry does not have is marked, and makes the command
    \\    exit non-zero.
    \\
    \\    --names  just the names and abbreviations, one per line, for
    \\             completion in a shell.
    \\    --match QUERY
    \\             what the palette would show for QUERY, in its order, with
    \\             the score beside each. How the ranking is checked without
    \\             opening a window and typing into one.
    \\
    \\    The commands plugins add are not in this table -- they exist once
    \\    Lua has run. `fenrir plugins` loads the configuration and lists
    \\    those.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    var names_only = false;
    var query: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--names")) {
            names_only = true;
        } else if (std.mem.eql(u8, args[i], "--match")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--match needs something to match", .{});
            query = args[i];
        } else {
            return ctx.fail("unknown option {s}", .{args[i]});
        }
    }

    const w = ctx.out;
    if (query) |q| return matched(ctx, q);
    if (names_only) {
        for (commands.table) |e| {
            try w.print("{s}\n", .{e.name});
            for (e.aliases) |a| try w.print("{s}\n", .{a});
        }
        return;
    }

    // The registry an icon name is checked against. The same one the reader
    // builds, built the same way -- a check against a table written out here
    // would be a second registry to keep in step.
    var fonts: Fonts = try .init(ctx.gpa, .{});
    defer fonts.deinit();
    var icons: Icons = try .init(ctx.gpa, &fonts);
    defer icons.deinit();

    try w.print("{d} commands. A command is typed after `:`.\n\n", .{commands.table.len});

    var missing: usize = 0;
    for (commands.table) |e| {
        var spelt: [48]u8 = undefined;
        var alias: [32]u8 = undefined;

        try w.print("  :{s: <30} {s: <12} {s: <8} {s}", .{
            std.fmt.bufPrint(&spelt, "{s}{s}{s}", .{
                e.name,
                if (e.args.len == 0) "" else " ",
                e.args,
            }) catch e.name,
            joined(&alias, e.aliases),
            e.binding,
            e.about,
        });

        // At the end of the line rather than in a column of its own: this is
        // empty for every command on a day nothing is wrong, and a column
        // that is always blank is a column nobody reads.
        if (e.icon.len != 0 and icons.find(e.icon) == null) {
            missing += 1;
            try w.print("   <- no icon called {s}", .{e.icon});
        }
        try w.writeByte('\n');
    }

    try w.writeAll(
        \\
        \\The second column is what the command also answers to, the third the
        \\keys that do the same thing without the command line.
        \\
    );

    if (missing != 0) return ctx.fail("{d} command{s} name an icon nothing registers", .{
        missing,
        if (missing == 1) "" else "s",
    });
}

/// What the palette would show, in its order.
///
/// The ranking is the half of a palette that is worth being sure of, and the
/// half a picture cannot check: a screenshot says the list is drawn, not that
/// `tn` should have found `tabnew` before `tabonly`. This prints it, so a
/// change to the scoring is a diff of two listings rather than an afternoon
/// of typing into a window.
fn matched(ctx: *Context, query: []const u8) !void {
    var storage: [palette.max_rows]palette.Row = undefined;
    const rows = palette.builtins(&storage);

    var order: [palette.max_rows]u16 = undefined;
    const n = palette.rank(query, rows, &order);

    const w = ctx.out;
    try w.print("{d} of {d} commands match '{s}':\n\n", .{ n, rows.len, query });
    for (order[0..n]) |index| {
        const r = rows[index];
        try w.print("  {d: >5}  :{s: <14} {s}\n", .{
            palette.scoreRow(query, r).?,
            r.name,
            r.about,
        });
    }
}

/// `qa, quitall`, in a caller's buffer. A command has one abbreviation or
/// two; anything that does not fit is cut, since this column is a reminder
/// and the names above it are the answer.
fn joined(buf: []u8, words: []const []const u8) []const u8 {
    var n: usize = 0;
    for (words, 0..) |word, i| {
        if (i != 0 and n + 2 <= buf.len) {
            buf[n] = ',';
            buf[n + 1] = ' ';
            n += 2;
        }
        const take = @min(word.len, buf.len - n);
        @memcpy(buf[n..][0..take], word[0..take]);
        n += take;
    }
    return buf[0..n];
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "every icon a command names is one the registry has" {
    var fonts: Fonts = try .init(testing.allocator, .{});
    defer fonts.deinit();
    var icons: Icons = try .init(testing.allocator, &fonts);
    defer icons.deinit();

    for (commands.table) |e| {
        if (e.icon.len == 0) continue;
        testing.expect(icons.find(e.icon) != null) catch |err| {
            std.debug.print("no icon called {s}, named by :{s}\n", .{ e.icon, e.name });
            return err;
        };
    }
}

test "abbreviations are joined, and a short buffer cuts rather than overruns" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("", joined(&buf, &.{}));
    try testing.expectEqualStrings("q", joined(&buf, &.{"q"}));
    try testing.expectEqualStrings("qa, quitall", joined(&buf, &.{ "qa", "quitall" }));

    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("qa, ", joined(&tiny, &.{ "qa", "quitall" }));
}
