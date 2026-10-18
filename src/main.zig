//! The `fenrir` command-line tool.
//!
//! Milestone 1 of the reader is "can we see the object graph?", and everything
//! here exists to answer that: open a file, resolve its cross-reference table,
//! and print what is inside. The Vulkan front end will link the same library.

const std = @import("std");
const Io = std.Io;

const Context = @import("vanagandr/Context.zig");
const commands_cmd = @import("vanagandr/commands.zig");
const dump = @import("vanagandr/dump.zig");
const extract = @import("vanagandr/extract.zig");
const fonts = @import("vanagandr/fonts.zig");
const health = @import("vanagandr/health.zig");
const icons = @import("vanagandr/icons.zig");
const info = @import("vanagandr/info.zig");
const pages = @import("vanagandr/pages.zig");
const rects = @import("vanagandr/rects.zig");
const raster = @import("vanagandr/raster.zig");
const read = @import("vanagandr/read.zig");
const trace = @import("vanagandr/trace.zig");
const ui = @import("vanagandr/ui.zig");
const library = @import("vanagandr/library.zig");
const plugins = @import("vanagandr/plugins.zig");
const view = @import("vanagandr/view.zig");
const xref = @import("vanagandr/xref.zig");

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
    .{ .name = "raster", .summary = "rasterise a page to a PNG on the CPU", .usage = raster.usage, .run = raster.run },
    .{ .name = "read", .summary = "open the document in a window and scroll through it", .usage = read.usage, .run = read.run },
    .{ .name = "recent", .summary = "the documents opened before, and where you were", .usage = library.recent_usage, .run = library.recentRun },
    .{ .name = "config", .summary = "the settings the reader remembers", .usage = library.config_usage, .run = library.configRun },
    .{ .name = "marks", .summary = "the highlights made in a document", .usage = library.marks_usage, .run = library.marksRun },
    .{ .name = "plugins", .summary = "load init.lua and the plugins, and report", .usage = plugins.usage, .run = plugins.run },
    .{ .name = "health", .summary = "what this build can do, and what it found", .usage = health.usage, .run = health.run },
    .{ .name = "commands", .summary = "list the reader's `:` commands", .usage = commands_cmd.usage, .run = commands_cmd.run },
    .{ .name = "trace", .summary = "interpret a page into a display list", .usage = trace.usage, .run = trace.run },
    .{ .name = "fonts", .summary = "list the compiled-in font backends", .usage = fonts.usage, .run = fonts.run },
    .{ .name = "icons", .summary = "list the icon registry, and draw a sheet of it", .usage = icons.usage, .run = icons.run },
    .{ .name = "rects", .summary = "render a demo frame through the rect pipeline", .usage = rects.usage, .run = rects.run },
    .{ .name = "ui", .summary = "render a frame of interface, layout and text included", .usage = ui.usage, .run = ui.run },
    .{ .name = "view", .summary = "open a window and draw on the GPU", .usage = view.usage, .run = view.run },
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
        .environ = init.environ_map,
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
