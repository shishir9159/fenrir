//! `fenrir ui` -- builds a frame of interface and writes what it looks like.
//!
//! No window and no device, on purpose: Þviti builds a box tree and solves it,
//! Týr rasterises the glyphs into an atlas, Gleipnir turns the tree into
//! instances, and the CPU reference rasteriser turns those into a PNG. Every
//! layer except the GPU is on that path.
//!
//! `fenrir view` runs the same scene through a real device, so the two images
//! differ only by the rasteriser that produced them -- which is the whole
//! reason this command survives now that there is a window to use instead.
//!
//! It runs several frames rather than one, and that is not padding. Hover is
//! resolved from the geometry the previous frame solved, and the hover and
//! press animations approach their targets over time; a single frame would
//! show neither, and the screenshot would silently be of a UI in a state no
//! user ever sees.
//!
//! **The text will be boxes** on a build with no real glyph source, which is
//! any build without `-Dfreetype` or `-Dstb-truetype`. That is Týr's fallback
//! doing its job: a row of `.notdef` boxes at the right size in the right
//! places says that shaping, measurement, atlas packing, subpixel bucketing
//! and placement all work, and only the outlines are missing. A page of
//! nothing would have said none of it.

const std = @import("std");
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");

const gleipnir = fenrir.gleipnir;
const thviti = fenrir.thviti;
const tyr = fenrir.tyr;

const Bounds = fenrir.gelgja.Bounds;
const Color = fenrir.gelgja.Color;
const DrawList = gleipnir.DrawList;
const Fonts = tyr.Fonts;
const Point = fenrir.gelgja.Point;
const UI = thviti.UI;
const w = thviti.widgets;

pub const usage =
    \\fenrir ui [--out FILE] [--size WxH] [--mouse X,Y] [--frames N] [--atlas FILE]
    \\
    \\    Builds a frame of user interface, solves its layout, rasterises its
    \\    text into a glyph atlas, and writes the result as a PNG using the CPU
    \\    reference rasteriser. Defaults to ui.png at 1000x640 with the pointer
    \\    over the toolbar.
    \\
    \\    Several frames are run before the one that is written, because hover
    \\    is resolved from the previous frame's geometry and the interaction
    \\    animations take time to settle.
    \\
    \\    --atlas writes the glyph atlas itself, which is the fastest way to
    \\    see whether the packer and the rasteriser are doing their jobs.
    \\
    \\    Without -Dfreetype or -Dstb-truetype there is no real glyph source,
    \\    and every character is drawn as the box Tyr's fallback produces.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    var dest: []const u8 = "ui.png";
    var atlas_dest: ?[]const u8 = null;
    var width: u32 = 1000;
    var height: u32 = 640;
    var mouse: Point = .{ .x = 140, .y = 58 };
    var frames: u32 = 24;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--out needs a file name", .{});
            dest = args[i];
        } else if (std.mem.eql(u8, arg, "--atlas")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--atlas needs a file name", .{});
            atlas_dest = args[i];
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--size needs WxH", .{});
            const pair = try parsePair(ctx, args[i], 'x');
            width = @intFromFloat(pair.x);
            height = @intFromFloat(pair.y);
            if (width == 0 or height == 0) return ctx.fail("--size must be positive", .{});
        } else if (std.mem.eql(u8, arg, "--mouse")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--mouse needs X,Y", .{});
            mouse = try parsePair(ctx, args[i], ',');
        } else if (std.mem.eql(u8, arg, "--frames")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--frames needs a count", .{});
            frames = std.fmt.parseInt(u32, args[i], 10) catch
                return ctx.fail("bad frame count {s}", .{args[i]});
            if (frames == 0) return ctx.fail("--frames must be at least 1", .{});
        } else {
            return ctx.fail("unknown option {s}", .{arg});
        }
    }

    var fonts: Fonts = try .init(ctx.gpa, .{ .subpixel_positions = 3 });
    defer fonts.deinit();

    var ui: UI = .init(ctx.gpa, thviti.text.metricsOf(&fonts));
    defer ui.deinit();

    var d: DrawList = .init(ctx.gpa, .fromRect(0, 0, @floatFromInt(width), @floatFromInt(height)));
    defer d.deinit();

    var renderer: thviti.draw.Renderer = .init(ctx.gpa);
    defer renderer.deinit();

    const viewport: Bounds = .fromRect(0, 0, @floatFromInt(width), @floatFromInt(height));
    var state: State = .{};

    // The atlas grows as glyphs are added, so the texture is registered after
    // the frames have run and every glyph the scene needs is in it. On a real
    // device this is the same order: upload, then draw.
    var n: u32 = 0;
    while (n < frames) : (n += 1) {
        fonts.beginFrame();
        try ui.begin(viewport, .{ .mouse = mouse, .dt = 1.0 / 60.0 });
        try scene(&ui, &state);
        ui.end();
    }

    const atlas = try d.registerTexture(fonts.atlasWidth(), fonts.atlasHeight());
    d.reset(viewport);
    try renderer.render(&d, &ui, &fonts, atlas);

    var fb = try gleipnir.Framebuffer.init(ctx.gpa, width, height, .linear);
    defer fb.deinit(ctx.gpa);
    fb.clear(.gray(0.07));

    var source: AtlasSampler = .{ .fonts = &fonts };
    gleipnir.software.render(fb, d.instances.items, source.sampler());

    try writePng(ctx, dest, fb);
    if (atlas_dest) |path| try writeAtlas(ctx, path, &fonts);

    ctx.note("{d} boxes solved, {d} drawn, {d} glyph quads", .{
        ui.boxCount(),
        renderer.boxes_drawn,
        renderer.glyphs_drawn,
    });
    ctx.note("{d} instances, {d} culled, {d} draw call{s} without descriptor indexing", .{
        d.count(),
        d.culled,
        d.runCount(),
        if (d.runCount() == 1) "" else "s",
    });
    ctx.note("atlas {d}x{d}, {d} glyphs, {d:.0}% full, {d} rasterised", .{
        fonts.atlasWidth(),
        fonts.atlasHeight(),
        fonts.atlas.count(),
        fonts.atlas.occupancy() * 100,
        fonts.atlas.misses,
    });
    if (!tyr.glyphs_are_real) {
        ctx.note("no glyph source in this build: every character is Tyr's fallback box", .{});
    }
    ctx.note("wrote {d}x{d} to {s}", .{ width, height, dest });
}

/// Everything the interface remembers that is not interface state.
///
/// The distinction is the whole point of the layer: hover, focus, scroll and
/// animation are the UI's and live in the box cache, so what a program has to
/// hold is only what it would have held anyway.
pub const State = struct {
    page: u32 = 3,
    pages: u32 = 128,
    zoom: u32 = 125,
    outline_open: bool = true,
    continuous: bool = true,
};

/// A reader's chrome, written the way it would be written for real.
pub fn scene(ui: *UI, state: *State) !void {
    ui.pushStyle(.{ .bg = .{ .r = 0.13, .g = 0.14, .b = 0.17 } });
    defer ui.popStyle();

    ui.next(.{ .w = .fill, .h = .fill, .axis = .y, .flags = .{ .draw_background = true } });
    const window = try ui.open("window");
    defer ui.close(window);

    try titleBar(ui, state);
    try toolBar(ui, state);
    try body(ui, state);
    try statusBar(ui, state);
}

fn titleBar(ui: *UI, state: *State) !void {
    ui.next(.{
        .w = .fill,
        .h = .px(36),
        .axis = .x,
        .child_align = .center,
        .bg = .{ .r = 0.10, .g = 0.11, .b = 0.13 },
        .flags = .{ .draw_background = true },
    });
    const bar = try ui.open("title");
    defer ui.close(bar);

    try w.spacer(ui, .px(14));
    ui.next(.{ .fg = .{ .r = 0.95, .g = 0.95, .b = 0.97 }, .font_size = 15 });
    _ = try w.label(ui, "fenrir");
    try w.spacer(ui, .px(10));
    ui.next(.{ .fg = .{ .r = 0.55, .g = 0.57, .b = 0.62 } });
    _ = try w.labelf(ui, "document.pdf - {d} pages###doc", .{state.pages});
    try w.fill(ui);
}

fn toolBar(ui: *UI, state: *State) !void {
    ui.next(.{
        .w = .fill,
        .h = .px(44),
        .axis = .x,
        .child_align = .center,
        .bg = .{ .r = 0.16, .g = 0.17, .b = 0.20 },
        .flags = .{ .draw_background = true },
    });
    const bar = try ui.open("toolbar");
    defer ui.close(bar);

    ui.pushStyle(.{ .radius = .all(5), .bg = .{ .r = 0.22, .g = 0.23, .b = 0.27 } });
    defer ui.popStyle();

    try w.spacer(ui, .px(12));
    _ = try w.button(ui, "Open");
    try w.spacer(ui, .px(6));

    if ((try w.buttonWith(ui, "Prev", .{ .disabled = state.page == 1 })).clicked) {
        state.page -|= 1;
    }
    try w.spacer(ui, .px(4));
    if ((try w.button(ui, "Next")).clicked) {
        state.page = @min(state.page + 1, state.pages);
    }

    try w.spacer(ui, .px(16));
    ui.next(.{ .fg = .{ .r = 0.72, .g = 0.74, .b = 0.80 } });
    _ = try w.labelf(ui, "{d} / {d}###pageno", .{ state.page, state.pages });

    try w.fill(ui);

    _ = try w.checkbox(ui, "Continuous", &state.continuous);
    try w.spacer(ui, .px(8));
    ui.next(.{ .fg = .{ .r = 0.72, .g = 0.74, .b = 0.80 } });
    _ = try w.labelf(ui, "{d}%###zoom", .{state.zoom});
    try w.spacer(ui, .px(12));
}

fn body(ui: *UI, state: *State) !void {
    ui.next(.{ .w = .fill, .h = .fill, .axis = .x });
    const row = try ui.open("body");
    defer ui.close(row);

    if (state.outline_open) try sidebar(ui, state);
    try pageView(ui, state);
}

const row_height: f32 = 30;

fn sidebar(ui: *UI, state: *State) !void {
    ui.next(.{
        .w = .px(230),
        .h = .fill,
        .axis = .y,
        .bg = .{ .r = 0.15, .g = 0.16, .b = 0.19 },
        .flags = .{ .draw_background = true },
    });
    const panel = try ui.open("sidebar");
    defer ui.close(panel);

    ui.next(.{
        .w = .fill,
        .h = .px(30),
        .child_align = .center,
        .axis = .x,
        .fg = .{ .r = 0.55, .g = 0.57, .b = 0.62 },
    });
    const head = try ui.open("outline head");
    try w.spacer(ui, .px(12));
    ui.next(.{ .font_size = 12 });
    _ = try w.label(ui, "OUTLINE");
    ui.close(head);

    ui.next(.{ .w = .fill, .h = .fill, .axis = .x });
    const split = try ui.open("outline split");
    defer ui.close(split);

    // Only the rows the view can see are built. At a hundred and twenty-eight
    // sections that is a few hundred boxes saved; at a six-hundred-page
    // outline it is the difference between a frame and a stall, and the
    // `culled` counter this command prints is what says so either way.
    ui.next(.{ .w = .fill, .h = .fill });
    const rows = try w.list.open(ui, "outline", .{
        .count = state.pages,
        .row_height = row_height,
    });
    {
        defer w.list.close(ui, rows);

        ui.pushStyle(.{ .font_size = 12, .fg = .{ .r = 0.70, .g = 0.72, .b = 0.78 } });
        defer ui.popStyle();

        var it = rows.rows();
        while (it.next()) |n| {
            const current = n + 1 == state.page;
            if (current) ui.pushStyle(.{ .fg = .{ .r = 1, .g = 1, .b = 1 } });
            defer if (current) ui.popStyle();

            var buf: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "Section {d}", .{n + 1});
            const sig = try w.list.row(ui, rows, n, text, .{
                .selected = current,
                .indent = 12,
                .selection = .{ .r = 0.20, .g = 0.36, .b = 0.62 },
            });
            if (sig.clicked) state.page = n + 1;
        }
    }

    ui.next(.{ .bg = .{ .r = 0.12, .g = 0.13, .b = 0.15 } });
    try w.list.scrollBar(ui, "outline bar", rows);
}

fn pageView(ui: *UI, state: *State) !void {
    ui.next(.{
        .w = .fill,
        .h = .fill,
        .axis = .y,
        .child_align = .center,
        .bg = .{ .r = 0.09, .g = 0.10, .b = 0.12 },
        .flags = .{ .draw_background = true, .clip = true },
    });
    const area = try ui.open("page area");
    defer ui.close(area);

    try w.spacer(ui, .px(24));

    // A sheet of paper, with a drop shadow under it. One instance each.
    ui.next(.{
        .w = .px(430),
        .h = .px(470),
        .axis = .y,
        .bg = .{ .r = 0.97, .g = 0.97, .b = 0.96 },
        .shadow = 26,
        .shadow_color = .{ .r = 0, .g = 0, .b = 0, .a = 0.6 },
        .flags = .{ .draw_background = true, .draw_shadow = true, .clip = true },
    });
    const sheet = try ui.open("sheet");
    defer ui.close(sheet);

    ui.pushStyle(.{ .fg = .{ .r = 0.12, .g = 0.12, .b = 0.14 } });
    defer ui.popStyle();

    try w.spacer(ui, .px(46));
    ui.next(.{ .w = .fill, .h = .px(28), .text_align = .center, .font_size = 19 });
    _ = try w.label(ui, "Gylfaginning 34");
    try w.spacer(ui, .px(18));

    // Text as it will look once there is a real face behind it: measured,
    // shaped, packed and placed, whatever the glyphs turn out to be.
    const lines = [_][]const u8{
        "Then the gods took a fetter, and it was called",
        "Gleipnir. It was made of six things: the noise of",
        "a cat's footfall, the beard of a woman, the roots",
        "of a mountain, the sinews of a bear, the breath of",
        "a fish, and the spittle of a bird. And though thou",
        "understand not these matters already, yet now",
        "thou mayest speedily find certain proof herein",
        "that no lie is told thee.",
    };
    for (lines, 0..) |line, n| {
        ui.next(.{ .w = .fill, .h = .px(24), .font_size = 13, .flags = .{ .draw_text = true } });
        _ = try ui.boxf("{s}###line{d}", .{ line, n });
    }

    try w.spacer(ui, .px(20));
    ui.next(.{
        .w = .fill,
        .h = .px(2),
        .bg = .{ .r = 0.80, .g = 0.80, .b = 0.78 },
        .flags = .{ .draw_background = true },
    });
    _ = try ui.box("rule");

    _ = state;
}

fn statusBar(ui: *UI, state: *State) !void {
    ui.next(.{
        .w = .fill,
        .h = .px(26),
        .axis = .x,
        .child_align = .center,
        .bg = .{ .r = 0.10, .g = 0.11, .b = 0.13 },
        .fg = .{ .r = 0.50, .g = 0.52, .b = 0.58 },
        .font_size = 12,
        .flags = .{ .draw_background = true },
    });
    const bar = try ui.open("status");
    defer ui.close(bar);

    try w.spacer(ui, .px(12));
    _ = try w.labelf(ui, "page {d}###status page", .{state.page});
    try w.fill(ui);
    _ = try w.label(ui, "PDF 2.0");
    try w.spacer(ui, .px(12));
}

// -- the atlas, as the software rasteriser sees it --------------------------

/// Bilinear coverage out of the glyph atlas.
///
/// Bilinear rather than nearest because that is what the sampler on the device
/// will be, and this rasteriser exists to be diffed against it. In practice
/// the two agree exactly here: glyph quads land on whole pixels and their
/// source rectangles are whole texels, so every tap falls on a texel centre.
/// It stops agreeing the moment anything is scaled, which is when the
/// difference would otherwise be blamed on the shader.
const AtlasSampler = struct {
    fonts: *Fonts,

    fn sampler(a: *AtlasSampler) gleipnir.software.Sampler {
        return .{ .ptr = a, .sample = sample };
    }

    fn sample(ptr: *anyopaque, tex: gleipnir.rect.TextureId, u: f32, v: f32) Color {
        _ = tex;
        const a: *AtlasSampler = @ptrCast(@alignCast(ptr));
        const fonts = a.fonts;
        const width = fonts.atlasWidth();
        const height = fonts.atlasHeight();
        if (width == 0 or height == 0) return .transparent;

        const fx = u * @as(f32, @floatFromInt(width)) - 0.5;
        const fy = v * @as(f32, @floatFromInt(height)) - 0.5;
        const x0 = @floor(fx);
        const y0 = @floor(fy);
        const tx = fx - x0;
        const ty = fy - y0;

        const c00 = texel(fonts, x0, y0);
        const c10 = texel(fonts, x0 + 1, y0);
        const c01 = texel(fonts, x0, y0 + 1);
        const c11 = texel(fonts, x0 + 1, y0 + 1);
        const top = c00 + (c10 - c00) * tx;
        const bot = c01 + (c11 - c01) * tx;
        const cov = top + (bot - top) * ty;

        // Coverage arrives in red, which is what `flags.alpha_texture` reads.
        return .{ .r = cov, .g = cov, .b = cov, .a = cov };
    }

    fn texel(fonts: *Fonts, x: f32, y: f32) f32 {
        if (x < 0 or y < 0) return 0;
        const xi: u32 = @intFromFloat(x);
        const yi: u32 = @intFromFloat(y);
        if (xi >= fonts.atlasWidth() or yi >= fonts.atlasHeight()) return 0;
        return @as(f32, @floatFromInt(fonts.atlasPixels()[yi * fonts.atlasWidth() + xi])) / 255.0;
    }
};

// -- output -----------------------------------------------------------------

fn parsePair(ctx: *Context, s: []const u8, sep: u8) !Point {
    const at = std.mem.indexOfScalar(u8, s, sep) orelse
        return ctx.fail("expected two numbers separated by '{c}', got {s}", .{ sep, s });
    const a = std.fmt.parseFloat(f32, s[0..at]) catch
        return ctx.fail("bad number in {s}", .{s});
    const b = std.fmt.parseFloat(f32, s[at + 1 ..]) catch
        return ctx.fail("bad number in {s}", .{s});
    return .{ .x = a, .y = b };
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

/// The atlas as a grey image, which is the fastest way to see whether the
/// packer left holes and whether the glyphs came out at all.
fn writeAtlas(ctx: *Context, dest: []const u8, fonts: *Fonts) !void {
    const width = fonts.atlasWidth();
    const height = fonts.atlasHeight();
    const rgba = try ctx.gpa.alloc(u8, @as(usize, width) * height * 4);
    defer ctx.gpa.free(rgba);

    for (fonts.atlasPixels(), 0..) |cov, n| {
        rgba[n * 4 + 0] = cov;
        rgba[n * 4 + 1] = cov;
        rgba[n * 4 + 2] = cov;
        rgba[n * 4 + 3] = 255;
    }

    var file = Io.Dir.cwd().createFile(ctx.io, dest, .{}) catch |err|
        return ctx.fail("cannot create {s}: {t}", .{ dest, err });
    defer file.close(ctx.io);

    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(ctx.io, &buf);
    gleipnir.png.write(ctx.gpa, &writer.interface, rgba, width, height) catch |err|
        return ctx.fail("cannot write {s}: {t}", .{ dest, err });
    writer.interface.flush() catch |err|
        return ctx.fail("cannot write {s}: {t}", .{ dest, err });

    ctx.note("wrote the atlas ({d}x{d}) to {s}", .{ width, height, dest });
}
