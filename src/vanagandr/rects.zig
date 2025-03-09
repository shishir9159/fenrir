//! `fenrir rects` -- draws a frame through the rect pipeline and writes it out.
//!
//! There is no window and no Vulkan device yet, so this is the only way to
//! look at what Gleipnir's rect pipeline produces. It builds a `DrawList`
//! exactly the way UI code will -- the same call sites, the same clip and
//! transform stacks -- and then runs it through the CPU oracle rather than a
//! GPU. When there is a device, the same scene rendered both ways is the
//! bring-up test: identical input, two rasterisers, subtract.
//!
//! It also reports the two numbers that decide whether this pipeline is doing
//! its job: how many instances the frame cost, and how many draw calls they
//! would take on a device without descriptor indexing.

const std = @import("std");
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");

const gleipnir = fenrir.gleipnir;
const Bounds = fenrir.gelgja.Bounds;
const Color = fenrir.gelgja.Color;
const DrawList = gleipnir.DrawList;
const Radius = gleipnir.Radius;

pub const usage =
    \\fenrir rects [--out FILE] [--size WxH]
    \\
    \\    Draws a demonstration frame through the rect pipeline and writes it
    \\    as a PNG, using the CPU reference rasteriser. Defaults to rects.png
    \\    at 960x540.
    \\
    \\    Every shape in the image is one instance of the same 96-byte
    \\    primitive: fills, gradients, rounded panels, borders, shadows, and
    \\    the clipped and scrolled contents of the panel on the right.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    var dest: []const u8 = "rects.png";
    var width: u32 = 960;
    var height: u32 = 540;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--out needs a file name", .{});
            dest = args[i];
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--size needs WxH", .{});
            const sep = std.mem.indexOfScalar(u8, args[i], 'x') orelse
                return ctx.fail("--size wants WxH, got {s}", .{args[i]});
            width = std.fmt.parseInt(u32, args[i][0..sep], 10) catch
                return ctx.fail("bad width in {s}", .{args[i]});
            height = std.fmt.parseInt(u32, args[i][sep + 1 ..], 10) catch
                return ctx.fail("bad height in {s}", .{args[i]});
            if (width == 0 or height == 0) return ctx.fail("--size must be positive", .{});
        } else {
            return ctx.fail("unknown option {s}", .{arg});
        }
    }

    var d: DrawList = .init(ctx.gpa, .fromRect(0, 0, @floatFromInt(width), @floatFromInt(height)));
    defer d.deinit();
    try scene(&d);

    var fb = try gleipnir.Framebuffer.init(ctx.gpa, width, height);
    defer fb.deinit(ctx.gpa);
    fb.clear(.gray(0.09));
    gleipnir.software.render(fb, d.instances.items, null);

    try writePng(ctx, dest, fb);

    ctx.note("{d} instances, {d} culled, {d} draw call{s} without descriptor indexing", .{
        d.count(),
        d.culled,
        d.runCount(),
        if (d.runCount() == 1) "" else "s",
    });
    ctx.note("wrote {d}x{d} to {s}", .{ width, height, dest });
}

/// Written the way UI code will be: no scene object, no retained state, just
/// calls in the order the things appear.
fn scene(d: *DrawList) !void {
    const w = d.viewport.width();
    const h = d.viewport.height();

    // A backdrop, so the shadows have something to fall on.
    try d.gradient(d.viewport, .none, .{
        .gray(0.16), .gray(0.12), .gray(0.08), .gray(0.10),
    });

    // A title bar with a bottom border, drawn as two instances rather than
    // three: the border is a ring, and only the bottom edge of it is visible
    // because the panel above covers the rest.
    try d.fill(.fromRect(0, 0, w, 40), .gray(0.20));
    try d.fill(.fromRect(0, 39, w, 40), .gray(0.30));

    // A row of buttons, showing the four-corner radius doing what one radius
    // cannot: a segmented control with square joins in the middle.
    const seg_y0: f32 = 64;
    const seg_y1: f32 = 96;
    const labels = [_]Radius{ .left(8), .none, .none, .right(8) };
    for (labels, 0..) |r, n| {
        const x0 = 24 + @as(f32, @floatFromInt(n)) * 90;
        const active = (n == 1);
        try d.rounded(
            .fromRect(x0, seg_y0, x0 + 88, seg_y1),
            r,
            if (active) .{ .r = 0.20, .g = 0.45, .b = 0.85 } else .gray(0.25),
        );
    }

    // A panel with a soft shadow under it. The shadow is its own instance,
    // offset down, with a large softness; there is no blur pass.
    const panel: Bounds = .fromRect(24, 128, 420, 500);
    try d.shadow(.fromRect(panel.min_x + 2, panel.min_y + 8, panel.max_x + 2, panel.max_y + 12), .all(14), 16, Color.black.withAlpha(0.55));
    try d.rounded(panel, .all(14), .gray(0.18));
    try d.border(panel, .all(14), 1, .gray(0.32));

    // Inside it, a list that is clipped and scrolled. This is the pair of
    // stacks doing the work the pipeline exists for: rows are drawn in list
    // coordinates, the transform moves them, the clip keeps them inside the
    // panel, and the rows entirely outside are dropped before they reach the
    // buffer rather than being clipped on the GPU.
    {
        d.pushClip(.fromRect(panel.min_x + 1, panel.min_y + 1, panel.max_x - 1, panel.max_y - 1));
        defer d.popClip();
        d.pushTransform(.translate(panel.min_x + 16, panel.min_y + 16 - 60));
        defer d.popTransform();

        var row: u32 = 0;
        while (row < 40) : (row += 1) {
            const y = @as(f32, @floatFromInt(row)) * 34;
            const shade: f32 = if (row % 2 == 0) 0.23 else 0.20;
            try d.rounded(.fromRect(0, y, 364, y + 30), .all(6), .gray(shade));
            // A fake text run: one capsule per "word", the shape a glyph quad
            // will have once there is an atlas behind it.
            var word: u32 = 0;
            const words = 2 + (row * 7) % 4;
            var x: f32 = 12;
            while (word < words) : (word += 1) {
                const len = 30 + @as(f32, @floatFromInt((row * 13 + word * 29) % 60));
                try d.rounded(.fromRect(x, y + 11, x + len, y + 19), .all(4), .gray(0.45));
                x += len + 8;
            }
        }
    }

    // A card on the right with a gradient and a capsule, so the oversized
    // radius clamp is visible in the output rather than only in a test.
    const card: Bounds = .fromRect(452, 128, w - 24, 320);
    try d.shadow(.fromRect(card.min_x + 2, card.min_y + 10, card.max_x + 2, card.max_y + 14), .all(16), 18, Color.black.withAlpha(0.5));
    try d.gradient(card, .all(16), .{
        .{ .r = 0.22, .g = 0.28, .b = 0.55 },
        .{ .r = 0.45, .g = 0.22, .b = 0.50 },
        .{ .r = 0.20, .g = 0.35, .b = 0.45 },
        .{ .r = 0.15, .g = 0.20, .b = 0.40 },
    });
    try d.rounded(.fromRect(card.min_x + 24, card.max_y - 56, card.min_x + 190, card.max_y - 24), .all(9999), Color.white.withAlpha(0.85));

    // A scrollbar: two capsules, one inside the other.
    try d.rounded(.fromRect(w - 20, 128, w - 12, h - 24), .all(4), .gray(0.14));
    try d.rounded(.fromRect(w - 20, 340, w - 12, 470), .all(4), .gray(0.38));

    // And the case worth seeing fail if the clip is ever wrong: something
    // drawn far outside every clip, which should leave no mark at all.
    {
        d.pushClip(.fromRect(0, 0, 10, 10));
        defer d.popClip();
        try d.fill(.fromRect(200, 200, 600, 400), .{ .r = 1, .g = 0, .b = 0 });
    }
}

fn writePng(ctx: *Context, dest: []const u8, fb: gleipnir.Framebuffer) !void {
    var file = Io.Dir.cwd().createFile(ctx.io, dest, .{}) catch |err|
        return ctx.fail("cannot create {s}: {t}", .{ dest, err });
    defer file.close(ctx.io);

    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(ctx.io, &buf);
    fb.writePng(ctx.gpa, &writer.interface) catch |err|
        return ctx.fail("cannot write {s}: {t}", .{ dest, err });
    writer.interface.flush() catch |err|
        return ctx.fail("cannot write {s}: {t}", .{ dest, err });
}
