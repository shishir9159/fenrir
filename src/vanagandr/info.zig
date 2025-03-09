//! `fenrir info <file>` -- a one-screen summary of a document's structure.

const std = @import("std");
const fenrir = @import("fenrir");

const Context = @import("Context.zig");

pub const usage =
    \\fenrir info <file>
    \\
    \\    Summarises the header, trailer, cross-reference table, and document
    \\    information dictionary.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args.len != 1) return ctx.fail("info takes exactly one file", .{});

    const bytes = ctx.readFile(args[0]) catch |err|
        return ctx.fail("cannot read {s}: {t}", .{ args[0], err });

    var doc = fenrir.open(ctx.gpa, bytes) catch |err|
        return ctx.fail("cannot open {s}: {t}", .{ args[0], err });
    defer doc.deinit();

    const w = ctx.out;
    try w.print("file          {s}\n", .{args[0]});
    try w.print("size          {d} bytes\n", .{doc.bytes.len});
    try w.print("version       {s}", .{doc.headerVersion() orelse "unknown"});
    if (doc.catalogVersion()) |v| try w.print(" (catalog says {s})", .{v});
    try w.writeByte('\n');

    try w.print("objects       {d}\n", .{doc.objectCount()});
    try w.print("xref          {s}\n", .{
        if (doc.recovered) "rebuilt by scanning (the file's own table was unusable)" else "read from the file",
    });
    try w.print("encrypted     {s}\n", .{
        if (doc.isEncrypted()) "yes -- strings and streams will read as ciphertext" else "no",
    });

    try writeTrailerSummary(ctx, &doc);
    try writeDocumentInfo(ctx, &doc);
    try writeStorageBreakdown(ctx, &doc);
}

fn writeTrailerSummary(ctx: *Context, doc: *fenrir.Document) !void {
    const w = ctx.out;
    const trailer = doc.trailer();

    try w.writeAll("\ntrailer\n");
    for ([_][]const u8{ "Size", "Root", "Info", "Encrypt", "ID", "Prev" }) |key| {
        const value = trailer.get(key) orelse continue;
        try w.print("  /{s: <8} ", .{key});
        try fenrir.print.write(w, doc, value, .{ .max_items = 4, .max_string = 24 });
    }

    // The page count is the first thing anyone wants to know. Report what the
    // tree actually holds rather than what /Count claims, and say so when the
    // two disagree -- a damaged file will happily assert a number it cannot
    // deliver.
    if (doc.catalog()) |_| {
        const list = fenrir.pages.all(doc) catch &.{};
        try w.print("  pages     {d}", .{list.len});
        if (fenrir.pages.declaredCount(doc)) |declared| {
            if (declared != @as(i64, @intCast(list.len))) {
                try w.print("  (/Count claims {d})", .{declared});
            }
        }
        try w.writeByte('\n');
    } else |err| {
        try w.print("  (no usable catalog: {t})\n", .{err});
    }
}

fn writeDocumentInfo(ctx: *Context, doc: *fenrir.Document) !void {
    const w = ctx.out;
    const info_ref = doc.trailer().get("Info") orelse return;
    const info = (doc.resolve(info_ref) catch return).asDict() orelse return;

    try w.writeAll("\ninfo\n");
    for (info.keys(), info.values()) |key, raw| {
        const value = doc.resolve(raw) catch continue;
        try w.print("  /{s: <12} ", .{key});
        try fenrir.print.write(w, doc, value, .{ .max_string = 72 });
    }
}

/// Where the objects actually live. A file dominated by `in object stream`
/// entries is a modern one; a file with none predates PDF 1.5 or was written
/// by a conservative producer.
fn writeStorageBreakdown(ctx: *Context, doc: *fenrir.Document) !void {
    var in_file: usize = 0;
    var in_stream: usize = 0;
    var free: usize = 0;
    var streams: usize = 0;

    var it = try doc.objects();
    while (try it.next()) |item| {
        switch (item.entry) {
            .in_file => in_file += 1,
            .in_stream => in_stream += 1,
            .free => free += 1,
        }
        if (item.object == .stream) streams += 1;
    }

    const w = ctx.out;
    try w.writeAll("\nstorage\n");
    try w.print("  {d: >6} objects written directly in the file\n", .{in_file});
    try w.print("  {d: >6} objects packed into object streams\n", .{in_stream});
    try w.print("  {d: >6} free entries\n", .{free});
    try w.print("  {d: >6} stream objects\n", .{streams});
}
