//! `fenrir dump <file> [options]` -- print the object graph.

const std = @import("std");
const fenrir = @import("fenrir");

const Context = @import("Context.zig");

pub const usage =
    \\fenrir dump <file> [--obj N] [--depth N] [--follow] [--all]
    \\
    \\    --obj N     Print object N only. Repeatable.
    \\    --depth N   Nesting limit before eliding (default 6).
    \\    --follow    Replace indirect references with their targets.
    \\    --all       Print every object, not just the trailer and catalog.
;

const Args = struct {
    path: []const u8,
    wanted: []const u32,
    all: bool,
    options: fenrir.print.Options,
};

pub fn run(ctx: *Context, argv: []const []const u8) !void {
    const args = try parse(ctx, argv);

    const bytes = ctx.readFile(args.path) catch |err|
        return ctx.fail("cannot read {s}: {t}", .{ args.path, err });

    var doc = fenrir.open(ctx.gpa, bytes) catch |err|
        return ctx.fail("cannot open {s}: {t}", .{ args.path, err });
    defer doc.deinit();

    if (doc.isEncrypted()) {
        ctx.note("warning: this document is encrypted; strings and stream data are ciphertext", .{});
    }

    if (args.wanted.len != 0) return dumpSelected(ctx, &doc, args);
    if (args.all) return dumpAll(ctx, &doc, args);
    return dumpRoots(ctx, &doc, args);
}

fn dumpSelected(ctx: *Context, doc: *fenrir.Document, args: Args) !void {
    for (args.wanted) |num| {
        const obj = doc.fetch(.{ .num = num, .gen = 0 }) catch |err| {
            ctx.note("object {d}: {t}", .{ num, err });
            continue;
        };
        try ctx.out.print("{d} 0 obj\n", .{num});
        try fenrir.print.write(ctx.out, doc, obj, args.options);
        try ctx.out.writeAll("endobj\n\n");
    }
}

fn dumpAll(ctx: *Context, doc: *fenrir.Document, args: Args) !void {
    var it = try doc.objects();
    while (try it.next()) |item| {
        if (item.entry == .free) continue;
        try ctx.out.print("{d} 0 obj", .{item.num});
        if (item.entry == .in_stream) {
            try ctx.out.print("  % in object stream {d}", .{item.entry.in_stream.container});
        }
        try ctx.out.writeByte('\n');
        try fenrir.print.write(ctx.out, doc, item.object, args.options);
        try ctx.out.writeAll("endobj\n\n");
    }
}

/// The default view: the two places every traversal starts from.
fn dumpRoots(ctx: *Context, doc: *fenrir.Document, args: Args) !void {
    try ctx.out.writeAll("trailer\n");
    try fenrir.print.write(ctx.out, doc, .{ .dict = doc.trailer() }, args.options);

    const cat = doc.catalog() catch |err|
        return ctx.fail("no usable catalog: {t}", .{err});

    try ctx.out.writeAll("\ncatalog\n");
    try fenrir.print.write(ctx.out, doc, .{ .dict = cat }, args.options);
    try ctx.out.writeAll("\n(pass --all to print every object, or --obj N for one)\n");
}

fn parse(ctx: *Context, argv: []const []const u8) !Args {
    var path: ?[]const u8 = null;
    var wanted: std.ArrayList(u32) = .empty;
    var all = false;
    var options: fenrir.print.Options = .{};

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, arg, "--follow")) {
            options.follow_refs = true;
        } else if (std.mem.eql(u8, arg, "--obj")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--obj needs an object number", .{});
            const num = std.fmt.parseInt(u32, argv[i], 10) catch
                return ctx.fail("not an object number: {s}", .{argv[i]});
            try wanted.append(ctx.gpa, num);
        } else if (std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i == argv.len) return ctx.fail("--depth needs a value", .{});
            options.max_depth = std.fmt.parseInt(u8, argv[i], 10) catch
                return ctx.fail("not a depth: {s}", .{argv[i]});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ctx.fail("unknown option {s}", .{arg});
        } else if (path == null) {
            path = arg;
        } else {
            return ctx.fail("dump takes one file", .{});
        }
    }

    return .{
        .path = path orelse return ctx.fail("dump needs a file", .{}),
        .wanted = wanted.items,
        .all = all,
        .options = options,
    };
}
