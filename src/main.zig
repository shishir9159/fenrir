//! The `fenrir` command-line tool.
//!
//! Milestone 1 of the reader is "can we see the object graph?", and everything
//! here exists to answer that: open a file, resolve its cross-reference table,
//! and print what is inside. The Vulkan front end will link the same library.

const std = @import("std");
const Io = std.Io;

const Context = @import("cli/Context.zig");
const dump = @import("cli/dump.zig");
const extract = @import("cli/extract.zig");
const info = @import("cli/info.zig");
const pages = @import("cli/pages.zig");
const xref = @import("cli/xref.zig");

const Command = struct {
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
    run: *const fn (ctx: *Context, args: []const []const u8) anyerror!void,
};

const commands = [_]Command{
    .{ .name = "info", .summary = "summarise a document", .usage = info.usage, .run = info.run },
    .{ .name = "dump", .summary = "print the object graph", .usage = dump.usage, .run = dump.run },
    .{ .name = "pages", .summary = "list pages and their geometry", .usage = pages.usage, .run = pages.run },
    .{ .name = "xref", .summary = "print the cross-reference table", .usage = xref.usage, .run = xref.run },
    .{ .name = "extract", .summary = "write a stream's decoded bytes", .usage = extract.usage, .run = extract.run },
};

pub fn main(init: std.process.Init) !void {
    // A CLI process is short-lived and the document graph is arena-shaped
    // anyway, so one arena for the whole run is both the simplest and the
    // fastest choice. `Document` still frees precisely; the arena just makes
    // those frees free.
    const gpa = init.arena.allocator();
    const io = init.io;

    var out_buf: [64 * 1024]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buf);

    var err_buf: [4096]u8 = undefined;
    var err_file: Io.File.Writer = .init(.stderr(), io, &err_buf);

    var ctx: Context = .{
        .gpa = gpa,
        .io = io,
        .out = &out_file.interface,
        .err = &err_file.interface,
    };

    const argv = try init.minimal.args.toSlice(gpa);
    const status = dispatch(&ctx, argv[1..]);

    ctx.out.flush() catch {};
    ctx.err.flush() catch {};

    status catch std.process.exit(1);
}

fn dispatch(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0) {
        try writeUsage(ctx);
        return error.CommandFailed;
    }

    const name = args[0];
    if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h") or
        std.mem.eql(u8, name, "help"))
    {
        // `fenrir help dump` prints just that command's usage.
        if (args.len > 1) {
            for (commands) |cmd| {
                if (std.mem.eql(u8, args[1], cmd.name)) {
                    try ctx.out.print("{s}\n", .{cmd.usage});
                    return;
                }
            }
        }
        try writeUsage(ctx);
        return;
    }

    for (commands) |cmd| {
        if (std.mem.eql(u8, name, cmd.name)) return cmd.run(ctx, args[1..]);
    }

    ctx.note("fenrir: unknown command '{s}'", .{name});
    try writeUsage(ctx);
    return error.CommandFailed;
}

fn writeUsage(ctx: *Context) !void {
    const w = ctx.out;
    try w.writeAll(
        \\fenrir -- a PDF reader written from scratch in Zig
        \\
        \\usage: fenrir <command> [arguments]
        \\
        \\commands:
        \\
    );
    for (commands) |cmd| {
        try w.print("  {s: <9} {s}\n", .{ cmd.name, cmd.summary });
    }
    try w.writeAll(
        \\
        \\Run `fenrir help <command>` for the options a command takes.
        \\
    );
}

test {
    // Compile the command modules under `zig build test`.
    std.testing.refAllDecls(@This());
}
