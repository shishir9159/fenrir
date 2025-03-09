//! `fenrir pages <file>` -- list every page with its effective geometry.
//!
//! "Effective" is the point: the numbers here are what a renderer would use,
//! after inheritance from the page tree, after `/CropBox` has been clipped to
//! `/MediaBox`, and after `/Rotate` has been applied to the displayed size.

const std = @import("std");
const fenrir = @import("fenrir");

const Context = @import("Context.zig");

pub const usage =
    \\fenrir pages <file> [--verbose]
    \\
    \\    Lists each page with the geometry a renderer would use: inherited
    \\    attributes resolved, /CropBox clipped to /MediaBox, and the displayed
    \\    size after /Rotate.
    \\
    \\    --verbose   Also show the resource categories and annotation count.
;

pub fn run(ctx: *Context, argv: []const []const u8) !void {
    var path: ?[]const u8 = null;
    var verbose = false;

    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ctx.fail("unknown option {s}", .{arg});
        } else if (path == null) {
            path = arg;
        } else {
            return ctx.fail("pages takes one file", .{});
        }
    }
    const file = path orelse return ctx.fail("pages needs a file", .{});

    const bytes = ctx.readFile(file) catch |err|
        return ctx.fail("cannot read {s}: {t}", .{ file, err });

    var doc = fenrir.open(ctx.gpa, bytes) catch |err|
        return ctx.fail("cannot open {s}: {t}", .{ file, err });
    defer doc.deinit();

    const list = try fenrir.pages.all(&doc);
    if (list.len == 0) return ctx.fail("no pages found in {s}", .{file});

    // A tree whose /Count disagrees with the leaves it actually has is a
    // reliable sign of damage, and worth saying out loud rather than papering
    // over with whichever number happens to be larger.
    if (fenrir.pages.declaredCount(&doc)) |declared| {
        if (declared != @as(i64, @intCast(list.len))) ctx.note(
            "note: /Count says {d} but the tree holds {d} pages",
            .{ declared, list.len },
        );
    }

    try writeTable(ctx, &doc, list, verbose);
}

fn writeTable(ctx: *Context, doc: *fenrir.Document, list: []const fenrir.Page, verbose: bool) !void {
    const w = ctx.out;
    try w.writeAll(" page  object   media box (pt)     display (pt)     rot   content\n");

    var rotated: usize = 0;
    var cropped: usize = 0;
    var total_content: usize = 0;

    for (list) |page| {
        if (page.rotate != .none) rotated += 1;
        if (page.isCropped()) cropped += 1;

        const content = page.contents(doc) catch "";
        total_content += content.len;

        try w.print("{d: >5}  {d: >5} 0  {d: >7.1} x {d: <7.1}  {d: >7.1} x {d: <7.1}  {d: >3}   {d: >8}", .{
            page.index + 1,
            page.ref.num,
            page.media_box.width(),
            page.media_box.height(),
            page.displayWidth(),
            page.displayHeight(),
            page.rotate.degrees(),
            content.len,
        });
        if (page.isCropped()) try w.print("   crop {f}", .{page.crop_box});
        try w.writeByte('\n');

        if (verbose) try writeDetail(ctx, doc, page);
    }

    try w.print("\n{d} pages", .{list.len});
    if (rotated != 0) try w.print(", {d} rotated", .{rotated});
    if (cropped != 0) try w.print(", {d} cropped", .{cropped});
    try w.print(", {d} bytes of content\n", .{total_content});
}

/// Which resource categories a page can reach. This is the exact set the
/// content-stream interpreter will need to look things up in, so seeing it
/// per page is the useful next diagnostic.
fn writeDetail(ctx: *Context, doc: *fenrir.Document, page: fenrir.Page) !void {
    const w = ctx.out;

    if (page.resources.count() == 0) {
        try w.writeAll("         resources: none\n");
    } else {
        try w.writeAll("         resources:");
        for (page.resources.keys(), page.resources.values()) |key, raw| {
            const value = doc.resolve(raw) catch continue;
            // /ProcSet is a legacy array; everything else is a name -> object
            // dictionary whose size is what matters.
            if (value.asDict()) |d| {
                try w.print(" /{s}({d})", .{ key, d.count() });
            } else {
                try w.print(" /{s}", .{key});
            }
        }
        try w.writeByte('\n');
    }

    const annots = page.annotations(doc) catch &.{};
    if (annots.len != 0) try w.print("         annotations: {d}\n", .{annots.len});
}
