//! `fenrir xref <file>` -- print the cross-reference table as resolved.

const std = @import("std");
const fenrir = @import("fenrir");

const Context = @import("Context.zig");

pub const usage =
    \\fenrir xref <file> [--verify]
    \\
    \\    Prints where every object lives after the whole /Prev chain has been
    \\    walked and newer sections have shadowed older ones.
    \\
    \\    --verify    Check that each in-file offset really points at its own
    \\                `N G obj` header, and report the ones that do not.
;

pub fn run(ctx: *Context, argv: []const []const u8) !void {
    var path: ?[]const u8 = null;
    var verify = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--verify")) {
            verify = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ctx.fail("unknown option {s}", .{arg});
        } else if (path == null) {
            path = arg;
        } else {
            return ctx.fail("xref takes one file", .{});
        }
    }
    const file = path orelse return ctx.fail("xref needs a file", .{});

    const bytes = ctx.readFile(file) catch |err|
        return ctx.fail("cannot read {s}: {t}", .{ file, err });

    var doc = fenrir.open(ctx.gpa, bytes) catch |err|
        return ctx.fail("cannot open {s}: {t}", .{ file, err });
    defer doc.deinit();

    if (doc.recovered) {
        ctx.note("note: this table was rebuilt by scanning; the file's own was unusable", .{});
    }

    const w = ctx.out;
    try w.writeAll("   obj  location\n");

    var mismatches: usize = 0;
    var it = try doc.objects();
    while (try it.next()) |item| {
        try w.print("{d: >6}  ", .{item.num});
        switch (item.entry) {
            .free => try w.writeAll("free"),
            .in_file => |at| {
                try w.print("offset {d: <10} gen {d}", .{ at.offset, at.gen });
                if (verify and !headerMatches(doc.bytes, at.offset, item.num)) {
                    try w.writeAll("   <- WRONG: no matching header here");
                    mismatches += 1;
                }
            },
            .in_stream => |at| try w.print(
                "object stream {d}, entry {d}",
                .{ at.container, at.index },
            ),
        }
        try w.print("   ({s})\n", .{item.object.typeName()});
    }

    if (verify) {
        try w.print("\n{d} of {d} offsets are wrong\n", .{ mismatches, doc.objectCount() });
    }
}

/// True if `N` followed by whitespace, a generation, and `obj` starts at
/// `offset`. This is exactly the check that decides whether a file needs
/// reconstruction, so it is worth being able to run it by hand.
fn headerMatches(bytes: []const u8, offset: u64, num: u32) bool {
    if (offset >= bytes.len) return false;
    const at: usize = @intCast(offset);

    var buf: [16]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{d}", .{num}) catch return false;
    if (!std.mem.startsWith(u8, bytes[at..], prefix)) return false;

    var i = at + prefix.len;
    if (i >= bytes.len or !fenrir.Lexer.isWhitespace(bytes[i])) return false;
    while (i < bytes.len and fenrir.Lexer.isWhitespace(bytes[i])) i += 1;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    while (i < bytes.len and fenrir.Lexer.isWhitespace(bytes[i])) i += 1;
    return std.mem.startsWith(u8, bytes[i..], "obj");
}
