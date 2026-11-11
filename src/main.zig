//! The `fenrir` command-line tool.
//!
//! Milestone 1 of the reader is "can we see the object graph?", and everything
//! here exists to answer that: open a file, resolve its cross-reference table,
//! and print what is inside. The Vulkan front end will link the same library.

const std = @import("std");
const Io = std.Io;
const fenrir = @import("fenrir");

/// What this build contains. `-Dprofile` resolved it once; the table below is
/// generated from it, so a command this profile left out is not registered,
/// not compiled and not callable -- registering one and then hiding it from
/// the help text is not exclusion.
const caps = fenrir.build_options;

const Context = @import("vanagandr/Context.zig");
const commands_cmd = @import("vanagandr/commands.zig");
const diff = @import("vanagandr/diff.zig");
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
const run_cmd = @import("vanagandr/run.zig");
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

/// The command table, built at comptime from the capability set.
///
/// A flat array that a `for` walks, as before -- but one whose entries this
/// profile actually has. The branches are comptime-known, so a command left
/// out is never referenced, its module is never analysed, and `fenrir dump`
/// in a `light` binary is an unknown command rather than a hidden one.
const commands = table: {
    var buf: [21]Command = undefined;
    var n: usize = 0;

    // The reader, in every profile. `read` stays a name because that is what
    // every script and every note already says; `fenrir <file>` is the form
    // `light` is for.
    buf[n] = .{ .name = "read", .summary = "open the document in a window and scroll through it", .usage = read.usage, .run = read.run };
    n += 1;

    if (caps.tools) {
        buf[n] = .{ .name = "info", .summary = "summarise a document", .usage = info.usage, .run = info.run };
        n += 1;
        buf[n] = .{ .name = "pages", .summary = "list pages and their geometry", .usage = pages.usage, .run = pages.run };
        n += 1;
        buf[n] = .{ .name = "fonts", .summary = "list the compiled-in font backends", .usage = fonts.usage, .run = fonts.run };
        n += 1;
        buf[n] = .{ .name = "commands", .summary = "list the reader's `:` commands", .usage = commands_cmd.usage, .run = commands_cmd.run };
        n += 1;
        buf[n] = .{ .name = "health", .summary = "what this build can do, and what it found", .usage = health.usage, .run = health.run };
        n += 1;
    }

    // `raster` rasterises with no device in the process, so it needs the CPU
    // rasteriser to be in the binary -- which `-Dpath=gpu` outside `debug`
    // means it is not.
    if (caps.tools and caps.path_cpu) {
        buf[n] = .{ .name = "raster", .summary = "rasterise a page to a PNG on the CPU", .usage = raster.usage, .run = raster.run };
        n += 1;
    }

    if (caps.compare) {
        buf[n] = .{ .name = "diff", .summary = "which pages of two documents differ", .usage = diff.usage, .run = diff.run };
        n += 1;
    }

    // Three views of one database, so they stand or fall together.
    if (caps.sqlite) {
        buf[n] = .{ .name = "recent", .summary = "the documents opened before, and where you were", .usage = library.recent_usage, .run = library.recentRun };
        n += 1;
        buf[n] = .{ .name = "config", .summary = "the settings the reader remembers", .usage = library.config_usage, .run = library.configRun };
        n += 1;
        buf[n] = .{ .name = "marks", .summary = "the highlights made in a document", .usage = library.marks_usage, .run = library.marksRun };
        n += 1;
    }

    if (caps.lua) {
        buf[n] = .{ .name = "plugins", .summary = "load init.lua and the plugins, and report", .usage = plugins.usage, .run = plugins.run };
        n += 1;
        buf[n] = .{ .name = "run", .summary = "run a Lua script over a document, with no window", .usage = run_cmd.usage, .run = run_cmd.run };
        n += 1;
    }

    // The commands that answer a question about fenrir rather than about a
    // document.
    if (caps.diagnostics) {
        buf[n] = .{ .name = "dump", .summary = "print the object graph", .usage = dump.usage, .run = dump.run };
        n += 1;
        buf[n] = .{ .name = "xref", .summary = "print the cross-reference table", .usage = xref.usage, .run = xref.run };
        n += 1;
        buf[n] = .{ .name = "extract", .summary = "write a stream's decoded bytes", .usage = extract.usage, .run = extract.run };
        n += 1;
        buf[n] = .{ .name = "trace", .summary = "interpret a page into a display list", .usage = trace.usage, .run = trace.run };
        n += 1;
        buf[n] = .{ .name = "icons", .summary = "list the icon registry, and draw a sheet of it", .usage = icons.usage, .run = icons.run };
        n += 1;
        buf[n] = .{ .name = "rects", .summary = "render a demo frame through the rect pipeline", .usage = rects.usage, .run = rects.run };
        n += 1;
        buf[n] = .{ .name = "ui", .summary = "render a frame of interface, layout and text included", .usage = ui.usage, .run = ui.run };
        n += 1;
        buf[n] = .{ .name = "view", .summary = "open a window and draw on the GPU", .usage = view.usage, .run = view.run };
        n += 1;
    }

    const out = buf[0..n].*;
    break :table out;
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

    status catch std.process.exit(ctx.exit orelse 1);
    if (ctx.exit) |code| std.process.exit(code);
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

    // `fenrir paper.pdf --watch`: the document straight away, with no verb.
    // Only when one of the arguments really is a file, so a mistyped command
    // is still reported as one rather than handed to the reader, which would
    // say it cannot open `dmup`.
    if (namesAFile(ctx, args)) return read.run(ctx, args);

    ctx.note("fenrir: unknown command '{s}'", .{name});
    try writeUsage(ctx);
    return error.CommandFailed;
}

/// Whether any argument that is not an option is a file this process can see.
fn namesAFile(ctx: *Context, args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) continue;
        if (Io.Dir.cwd().access(ctx.io, arg, .{})) |_| return true else |_| {}
    }
    return false;
}

fn writeUsage(ctx: *Context) !void {
    const w = ctx.out;
    try w.print(
        \\fenrir -- a PDF reader written from scratch in Zig ({s} build)
        \\
        \\usage: fenrir <file>... [options]
        \\       fenrir <command> [arguments]
        \\
        \\commands:
        \\
    , .{caps.profile});
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
    _ = @import("vanagandr/watch.zig");
}

test "the table holds exactly the commands this configuration has" {
    const has = struct {
        fn f(name: []const u8) bool {
            for (commands) |cmd| {
                if (std.mem.eql(u8, cmd.name, name)) return true;
            }
            return false;
        }
    }.f;

    // The reader is the one command no profile may drop; it is what fenrir
    // is.
    try std.testing.expect(has("read"));

    // Each gated command is registered exactly when its capability is on.
    // Written as an equality and not as "light has no dump", so the
    // assertion is the same sentence in all nine configurations.
    try std.testing.expectEqual(caps.diagnostics, has("dump"));
    try std.testing.expectEqual(caps.diagnostics, has("trace"));
    try std.testing.expectEqual(caps.compare, has("diff"));
    try std.testing.expectEqual(caps.sqlite, has("recent"));
    try std.testing.expectEqual(caps.sqlite, has("marks"));
    try std.testing.expectEqual(caps.lua, has("plugins"));
    try std.testing.expectEqual(caps.tools, has("info"));
    try std.testing.expectEqual(caps.tools, has("health"));
    // `raster` renders with no device in the process, so it needs the CPU
    // rasteriser to be in the binary and not merely named by -Dpath.
    try std.testing.expectEqual(caps.tools and caps.path_cpu, has("raster"));

    // Two entries of the same name would make the second unreachable, which
    // is the failure a comptime table built by hand can have and a literal
    // one cannot.
    for (commands, 0..) |a, i| {
        for (commands[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}
test "the help text offers no flag this build would reject" {
    // The parser and the usage read the same capabilities; this is the test
    // that they go on doing so. A flag in the text that the parser does not
    // know is a bug report from somebody following the documentation.
    const u = read.usage;
    const mentions = struct {
        fn f(haystack: []const u8, flag: []const u8) bool {
            return std.mem.indexOf(u8, haystack, flag) != null;
        }
    }.f;

    try std.testing.expect(mentions(u, "--page"));
    try std.testing.expect(mentions(u, "--zoom"));
    try std.testing.expectEqual(caps.bench, mentions(u, "--bench"));
    try std.testing.expectEqual(caps.bench, mentions(u, "--time"));
    try std.testing.expectEqual(caps.diagnostics, mentions(u, "--shot"));
    try std.testing.expectEqual(caps.splits, mentions(u, "--split "));
    try std.testing.expectEqual(caps.sqlite, mentions(u, "--db"));
    try std.testing.expectEqual(caps.lua, mentions(u, "--clean"));
    try std.testing.expectEqual(caps.config, mentions(u, "fenrir.toml"));
    try std.testing.expectEqual(caps.instruments, mentions(u, "--validate"));
    try std.testing.expectEqual(caps.path_cpu and caps.path_gpu, mentions(u, "--path"));
}
