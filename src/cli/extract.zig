//! `fenrir extract <file> <object>` -- write a stream's decoded bytes out.
//!
//! This is the command that makes the rest of the project debuggable: it is
//! how you look at a content stream, an embedded font program, or the header
//! of an object stream without leaving the terminal.

const std = @import("std");
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");

pub const usage =
    \\fenrir extract <file> <object> [--raw] [-o <path>]
    \\fenrir extract <file> --page <N> [-o <path>]
    \\
    \\    Writes the decoded contents of a stream object to stdout, or to
    \\    <path> with -o.
    \\
    \\    --page N    Write page N's content stream instead of one object.
    \\                Pages are numbered from 1, and an array of /Contents
    \\                streams is joined the way a renderer would read it.
    \\    --raw       Skip the filter chain and emit the encoded bytes.
    \\
    \\    Image codecs (DCT, JPX, CCITT, JBIG2) are never decoded: their
    \\    encoded bytes are emitted as-is, which is usually the useful thing.
;

pub fn run(ctx: *Context, argv: []const []const u8) !void {
    var path: ?[]const u8 = null;
    var number: ?u32 = null;
    var page_number: ?u32 = null;
    var out_path: ?[]const u8 = null;
    var raw = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--raw")) {
            raw = true;
        } else if (std.mem.eql(u8, arg, "--page")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--page needs a page number", .{});
            page_number = std.fmt.parseInt(u32, argv[i], 10) catch
                return ctx.fail("not a page number: {s}", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i == argv.len) return ctx.fail("-o needs a path", .{});
            out_path = argv[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ctx.fail("unknown option {s}", .{arg});
        } else if (path == null) {
            path = arg;
        } else if (number == null) {
            number = std.fmt.parseInt(u32, arg, 10) catch
                return ctx.fail("not an object number: {s}", .{arg});
        } else {
            return ctx.fail("extract takes one file and one object number", .{});
        }
    }

    const file = path orelse return ctx.fail("extract needs a file", .{});
    if (number == null and page_number == null) {
        return ctx.fail("extract needs an object number, or --page N", .{});
    }

    const bytes = ctx.readFile(file) catch |err|
        return ctx.fail("cannot read {s}: {t}", .{ file, err });

    var doc = fenrir.open(ctx.gpa, bytes) catch |err|
        return ctx.fail("cannot open {s}: {t}", .{ file, err });
    defer doc.deinit();

    if (page_number) |n| return extractPage(ctx, &doc, n, out_path);

    const num = number.?;
    const obj = doc.fetch(.{ .num = num, .gen = 0 }) catch |err|
        return ctx.fail("object {d}: {t}", .{ num, err });

    const stream = obj.asStream() orelse
        return ctx.fail("object {d} is a {s}, not a stream", .{ num, obj.typeName() });

    const data = if (raw) stream.raw else blk: {
        const result = doc.streamData(stream) catch |err|
            return ctx.fail("cannot decode object {d}: {t}", .{ num, err });

        if (result.stopped_at) |kind| ctx.note(
            "note: stopped at {s}; emitting its encoded bytes{s}",
            .{
                kind.displayName(),
                if (kind.imageExtension()) |ext| switch (ext[0]) {
                    'j' => " (a JPEG-family bitstream)",
                    else => "",
                } else "",
            },
        );
        break :blk result.data;
    };

    if (out_path) |dest| {
        try writeToFile(ctx, dest, data);
        ctx.note("wrote {d} bytes to {s}", .{ data.len, dest });
    } else {
        try ctx.out.writeAll(data);
    }
}

/// Page content is what the interpreter will consume, so being able to pull
/// it out by page number -- rather than hunting for the right object first --
/// is the difference between debugging a page and debugging a file.
fn extractPage(ctx: *Context, doc: *fenrir.Document, number: u32, out_path: ?[]const u8) !void {
    if (number == 0) return ctx.fail("pages are numbered from 1", .{});

    const list = try fenrir.pages.all(doc);
    if (number > list.len) {
        return ctx.fail("page {d}: this document has {d} pages", .{ number, list.len });
    }

    const page = list[number - 1];
    const data = page.contents(doc) catch |err|
        return ctx.fail("page {d}: {t}", .{ number, err });

    if (out_path) |dest| {
        try writeToFile(ctx, dest, data);
        ctx.note("wrote {d} bytes of page {d} to {s}", .{ data.len, number, dest });
    } else {
        try ctx.out.writeAll(data);
    }
}

fn writeToFile(ctx: *Context, dest: []const u8, data: []const u8) !void {
    var file = Io.Dir.cwd().createFile(ctx.io, dest, .{}) catch |err|
        return ctx.fail("cannot create {s}: {t}", .{ dest, err });
    defer file.close(ctx.io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(ctx.io, &buf);
    writer.interface.writeAll(data) catch |err|
        return ctx.fail("cannot write {s}: {t}", .{ dest, err });
    writer.interface.flush() catch |err|
        return ctx.fail("cannot write {s}: {t}", .{ dest, err });
}
