//! `fenrir trace <file>` -- interpret a page and print its display list.
//!
//! This is the command the interpreter was written against. `fenrir extract
//! --page 1` shows what the file says; `fenrir trace --page 1` shows what the
//! interpreter decided it meant. When a page renders wrong, the two side by
//! side say within one diff whether the mistake is in the reading or in the
//! drawing -- which is the question that otherwise costs an afternoon.
//!
//! The output is designed to be diffed rather than parsed, so it is stable
//! across runs and quiet about things that did not change.

const std = @import("std");
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");

const content = fenrir.content;
const trace = fenrir.gelgja.trace;

pub const usage =
    \\fenrir trace <file> [--page N | --all] [options]
    \\
    \\    Interprets a page's content stream and prints the display list it
    \\    produces: one line per drawing command, indented by clip and layer
    \\    depth.
    \\
    \\    --page N     Which page, numbered from 1. Defaults to 1.
    \\    --all        Every page, with a banner between them.
    \\    --stats      Only the summary line and any diagnostics.
    \\    --paths      Print every verb and point instead of a count.
    \\    --glyphs     Print one line per glyph instead of a decoded string.
    \\    --no-rotate  Ignore /Rotate, so coordinates match the file's own
    \\                 numbers rather than what a reader would display.
    \\    --no-type3   Do not run Type 3 glyph procedures.
    \\
    \\    Nothing here can fail a page: an unknown operator, a missing
    \\    resource, or a truncated stream is counted and reported at the end.
;

pub fn run(ctx: *Context, argv: []const []const u8) !void {
    var path: ?[]const u8 = null;
    var page_number: u32 = 1;
    var all = false;
    var stats_only = false;
    var options: content.Options = .{};
    var trace_options: trace.Options = .{};

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--page")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--page needs a page number", .{});
            page_number = std.fmt.parseInt(u32, argv[i], 10) catch
                return ctx.fail("not a page number: {s}", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            stats_only = true;
        } else if (std.mem.eql(u8, arg, "--paths")) {
            trace_options.paths = true;
        } else if (std.mem.eql(u8, arg, "--glyphs")) {
            trace_options.glyphs = true;
        } else if (std.mem.eql(u8, arg, "--no-rotate")) {
            options.rotate = false;
        } else if (std.mem.eql(u8, arg, "--no-type3")) {
            options.type3 = false;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ctx.fail("unknown option {s}", .{arg});
        } else if (path == null) {
            path = arg;
        } else {
            return ctx.fail("trace takes one file", .{});
        }
    }

    const file = path orelse return ctx.fail("trace needs a file", .{});
    if (page_number == 0) return ctx.fail("pages are numbered from 1", .{});

    const bytes = ctx.readFile(file) catch |err|
        return ctx.fail("cannot read {s}: {t}", .{ file, err });

    var doc = fenrir.open(ctx.gpa, bytes) catch |err|
        return ctx.fail("cannot open {s}: {t}", .{ file, err });
    defer doc.deinit();

    const list = fenrir.pages.all(&doc) catch |err|
        return ctx.fail("cannot read the page tree: {t}", .{err});

    if (list.len == 0) return ctx.fail("this document has no pages", .{});

    if (all) {
        var total: content.Interpreter.Diagnostics = .{};
        for (list, 0..) |p, index| {
            if (index != 0) try ctx.out.writeByte('\n');
            try ctx.out.print("# ---- page {d} of {d} ----\n", .{ index + 1, list.len });
            const diag = try tracePage(ctx, &doc, p, options, trace_options, stats_only);
            accumulate(&total, diag);
        }
        try ctx.out.print("\n# {d} pages\n", .{list.len});
        try writeDiagnostics(ctx, total);
        return;
    }

    if (page_number > list.len) {
        return ctx.fail("page {d}: this document has {d} pages", .{ page_number, list.len });
    }

    const diag = try tracePage(
        ctx,
        &doc,
        list[page_number - 1],
        options,
        trace_options,
        stats_only,
    );
    try writeDiagnostics(ctx, diag);
}

fn tracePage(
    ctx: *Context,
    doc: *fenrir.Document,
    p: fenrir.Page,
    options: content.Options,
    trace_options: trace.Options,
    stats_only: bool,
) !content.Interpreter.Diagnostics {
    var result = content.page(ctx.gpa, doc, p, options) catch |err|
        return ctx.fail("page {d}: {t}", .{ p.index + 1, err });
    defer result.deinit(ctx.gpa);

    if (stats_only) {
        const s = result.list.stats();
        try ctx.out.print(
            "page {d}: {d} commands, {d} fills, {d} strokes, {d} clips, " ++
                "{d} text runs ({d} glyphs), {d} images, {d} shadings\n",
            .{
                p.index + 1,
                result.list.cmds.len,
                s.fills,
                s.strokes,
                s.clips,
                s.text_runs,
                s.glyphs,
                s.images,
                s.shadings,
            },
        );
    } else {
        try trace.write(ctx.out, result.list, trace_options);
    }

    return result.diagnostics;
}

fn accumulate(total: *content.Interpreter.Diagnostics, one: content.Interpreter.Diagnostics) void {
    total.operators += one.operators;
    total.unknown_operators += one.unknown_operators;
    total.stack_underflows += one.stack_underflows;
    total.missing_resources += one.missing_resources;
    total.forms_drawn += one.forms_drawn;
    total.images_drawn += one.images_drawn;
    total.inline_images += one.inline_images;
    total.recursive_forms += one.recursive_forms;
    total.text_without_font += one.text_without_font;
    total.deepest_nesting = @max(total.deepest_nesting, one.deepest_nesting);
    total.truncated = total.truncated or one.truncated;

    // Keep the first few distinct names across every page, which is what
    // makes `--all` useful for finding an operator nobody implemented.
    for (0..one.unknown_count) |i| {
        const name = one.unknownName(i);
        if (total.unknown_count == total.unknown_names.len) break;
        var seen = false;
        for (0..total.unknown_count) |k| {
            if (std.mem.eql(u8, total.unknownName(k), name)) seen = true;
        }
        if (seen) continue;
        @memcpy(total.unknown_names[total.unknown_count][0..name.len], name);
        total.unknown_lens[total.unknown_count] = @intCast(name.len);
        total.unknown_count += 1;
    }
}

/// Everything the interpreter noticed, on stderr so that a trace can still be
/// piped somewhere without the notes in it.
fn writeDiagnostics(ctx: *Context, d: content.Interpreter.Diagnostics) !void {
    ctx.note("{d} operators", .{d.operators});

    if (d.unknown_operators != 0) {
        ctx.err.print("{d} unknown operators (", .{d.unknown_operators}) catch {};
        for (0..d.unknown_count) |i| {
            if (i != 0) ctx.err.writeAll(", ") catch {};
            ctx.err.print("{s}", .{d.unknownName(i)}) catch {};
        }
        ctx.err.writeAll(")\n") catch {};
    }
    if (d.stack_underflows != 0) ctx.note("{d} unmatched Q", .{d.stack_underflows});
    if (d.missing_resources != 0) ctx.note("{d} missing resources", .{d.missing_resources});
    if (d.text_without_font != 0) ctx.note("{d} strings shown with no font", .{d.text_without_font});
    if (d.recursive_forms != 0) ctx.note("{d} recursive form XObjects refused", .{d.recursive_forms});
    if (d.forms_drawn != 0) ctx.note("{d} form XObjects, nested {d} deep", .{ d.forms_drawn, d.deepest_nesting });
    if (d.images_drawn != 0 or d.inline_images != 0) {
        ctx.note("{d} images ({d} inline)", .{ d.images_drawn + d.inline_images, d.inline_images });
    }
    if (d.truncated) ctx.note("WARNING: the page was truncated at the command limit", .{});
}
