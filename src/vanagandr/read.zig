//! `fenrir read <file>` -- the document, in a window, scrollable.
//!
//! This is the command the rest of the project was for. Gjöll reads the file,
//! the interpreter turns each page into a display list, `gleipnir.replay`
//! rasterises it, Lyngvi opens a window and puts it on the screen, and the
//! loop below joins them and answers the wheel.
//!
//! ## Where the page is drawn
//!
//! On the CPU, into an RGBA8 image, which is then uploaded as a texture and
//! drawn by the rect pipeline as one quad. That is a deliberate intermediate
//! and not the end state:
//!
//! * `gleipnir/pathpipe.zig` specifies the GPU path pipeline and its shaders
//!   compile, but `lyngvi/Renderer.zig` has not been taught to create it --
//!   there is no stencil attachment, no multisampled colour attachment, and
//!   no vertex buffer. Until there is, the GPU cannot fill a path.
//! * The CPU rasteriser already draws every page in the corpus correctly,
//!   including clips, transparency groups and blend modes, and clipping is
//!   the part of a page the GPU pipeline has no answer for yet.
//!
//! So the choice is between a reader today whose pixels are exactly
//! `fenrir raster`'s, and no reader until a second rasteriser catches up with
//! the first. Every page you see here is the reference image.
//!
//! It also means the window is not a benchmark of the Vulkan path. What it
//! does exercise is the swapchain, the resize path, the descriptor array, the
//! upload path with megabyte-sized images rather than atlas patches, and the
//! frame loop -- all of which the GPU pipeline will need working underneath
//! it.
//!
//! ## Cost
//!
//! A page costs one interpretation and one rasterisation, tens of
//! milliseconds in a release build and several times that in a debug one. So
//! pages are rendered lazily, at most one per frame, and kept in a small
//! cache; scrolling past an unrendered page shows blank paper for a frame or
//! two rather than stalling the loop until it is ready.

const std = @import("std");
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("Context.zig");
const glyphmod = @import("glyphs.zig");

const content = fenrir.content;
const gelgja = fenrir.gelgja;
const gleipnir = fenrir.gleipnir;
const lyngvi = fenrir.lyngvi;
const replay = gleipnir.replay;

const Bounds = gelgja.Bounds;
const Color = gelgja.Color;
const DrawList = gleipnir.DrawList;
const Glyphs = glyphmod.Fonts;

pub const usage =
    \\fenrir read <file> [--page N] [--zoom N | --dpi N] [--size WxH]
    \\                   [--samples N] [--vsync on|off|adaptive]
    \\                   [--validate] [--gpu NAME] [--frames N]
    \\
    \\    Opens the document in a window and scrolls through it.
    \\
    \\    --page N     Start at this page, numbered from 1.
    \\    --zoom N     Device pixels per PDF point. 1.0 is 72 dpi.
    \\    --dpi N      The same thing in the other unit. Defaults to 110.
    \\    --size WxH   The window's initial size.
    \\    --samples N  Multisampling for the page raster: 1, 2, 4 or 8.
    \\                 Defaults to 8.
    \\    --frames N   Run N frames and exit, so the command can be scripted.
    \\    --shot F     Write one composed frame to F as a PNG and exit, with
    \\                 no window and no device. What the reader would look
    \\                 like, on a machine with no display and in a test.
    \\    --vsync      on (default), off, or adaptive.
    \\    --validate   Turn on the Khronos validation layers, if installed.
    \\    --gpu NAME   Prefer a device whose name contains NAME.
    \\
    \\keys:
    \\    wheel, up/down       scroll
    \\    page up / page down  a screen at a time
    \\    home / end           the first and last page
    \\    n / p                the next and previous page
    \\    + / -                zoom in and out
    \\    0                    fit the page width to the window
    \\    1                    one hundred per cent
    \\    escape, q            close
    \\
    \\    Pages are rasterised on the CPU and uploaded as textures -- the same
    \\    pixels `fenrir raster` writes to a PNG. The GPU path pipeline is
    \\    specified and its shaders compile, but the renderer does not create
    \\    it yet, so it is not what draws this.
;

/// How many rendered pages to keep. Six covers a screen and a half at any
/// sensible zoom, so scrolling back a page never re-renders it, and at four
/// bytes a pixel it is tens of megabytes rather than hundreds.
const cache_slots = 6;

/// Between pages, and around the document, in device pixels rather than
/// points: the gap is a property of the screen you are reading on, not of the
/// paper, so it should not grow when you zoom in.
const gap = 14.0;

const min_zoom = 0.15;
const max_zoom = 8.0;

/// A ceiling on one page's texture, matching `fenrir raster`. A page that
/// wants more than this at the requested zoom is rendered at whatever zoom
/// does fit rather than refused, because refusing means a blank window.
const max_page_pixels: u64 = 64 << 20;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    var name: ?[]const u8 = null;
    var start_page: u32 = 1;
    var zoom: f32 = 110.0 / 72.0;
    var width: u32 = 1000;
    var height: u32 = 900;
    var frames: ?u32 = null;
    var vsync: lyngvi.Vsync = .on;
    var validate = false;
    var prefer: ?[]const u8 = null;
    var samples: gleipnir.raster.Samples = .eight;
    var shot: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--validate")) {
            validate = true;
        } else if (std.mem.eql(u8, arg, "--page")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--page needs a number", .{});
            start_page = std.fmt.parseInt(u32, args[i], 10) catch
                return ctx.fail("--page wants a number, not '{s}'", .{args[i]});
            if (start_page == 0) return ctx.fail("pages are numbered from 1", .{});
        } else if (std.mem.eql(u8, arg, "--zoom")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--zoom needs a number", .{});
            zoom = std.fmt.parseFloat(f32, args[i]) catch
                return ctx.fail("--zoom wants a number, not '{s}'", .{args[i]});
        } else if (std.mem.eql(u8, arg, "--dpi")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--dpi needs a number", .{});
            const dpi = std.fmt.parseFloat(f32, args[i]) catch
                return ctx.fail("--dpi wants a number, not '{s}'", .{args[i]});
            zoom = dpi / 72.0;
        } else if (std.mem.eql(u8, arg, "--samples")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--samples needs 1, 2, 4 or 8", .{});
            samples = switch (std.fmt.parseInt(u8, args[i], 10) catch 0) {
                1 => .one,
                2 => .two,
                4 => .four,
                8 => .eight,
                else => return ctx.fail("--samples wants 1, 2, 4 or 8", .{}),
            };
        } else if (std.mem.eql(u8, arg, "--frames")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--frames needs a count", .{});
            frames = std.fmt.parseInt(u32, args[i], 10) catch
                return ctx.fail("--frames wants a number, not '{s}'", .{args[i]});
        } else if (std.mem.eql(u8, arg, "--shot")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--shot needs a file", .{});
            shot = args[i];
        } else if (std.mem.eql(u8, arg, "--gpu")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--gpu needs a name", .{});
            prefer = args[i];
        } else if (std.mem.eql(u8, arg, "--vsync")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--vsync needs on, off or adaptive", .{});
            vsync = if (std.mem.eql(u8, args[i], "on"))
                .on
            else if (std.mem.eql(u8, args[i], "off"))
                .off
            else if (std.mem.eql(u8, args[i], "adaptive"))
                .adaptive
            else
                return ctx.fail("--vsync wants on, off or adaptive", .{});
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--size needs WxH", .{});
            const x = std.mem.indexOfScalar(u8, args[i], 'x') orelse
                return ctx.fail("--size wants WxH", .{});
            width = std.fmt.parseInt(u32, args[i][0..x], 10) catch
                return ctx.fail("--size wants WxH", .{});
            height = std.fmt.parseInt(u32, args[i][x + 1 ..], 10) catch
                return ctx.fail("--size wants WxH", .{});
            if (width == 0 or height == 0) return ctx.fail("--size must be positive", .{});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ctx.fail("unknown option {s}", .{arg});
        } else if (name == null) {
            name = arg;
        } else {
            return ctx.fail("read takes one file", .{});
        }
    }

    const file = name orelse return ctx.fail("read needs a file", .{});
    if (!(zoom > 0) or !std.math.isFinite(zoom)) {
        return ctx.fail("a zoom has to be positive and finite", .{});
    }

    if (shot == null and !lyngvi.has_window) {
        return ctx.fail(
            "no window backend for this platform yet: Lyngvi speaks Win32, and the xcb backend is a stub",
            .{},
        );
    }

    const bytes = ctx.readFile(file) catch |err|
        return ctx.fail("cannot read {s}: {t}", .{ file, err });

    var doc = fenrir.open(ctx.gpa, bytes) catch |err|
        return ctx.fail("cannot open {s}: {t}", .{ file, err });
    defer doc.deinit();

    const pages = fenrir.pages.all(&doc) catch |err|
        return ctx.fail("cannot read the page tree: {t}", .{err});
    if (pages.len == 0) return ctx.fail("this document has no pages", .{});
    if (start_page > pages.len) {
        return ctx.fail("page {d}: this document has {d} pages", .{ start_page, pages.len });
    }

    var reader: Reader = .{
        .ctx = ctx,
        .doc = &doc,
        .pages = pages,
        .file = file,
        .zoom = std.math.clamp(zoom, min_zoom, max_zoom),
        .samples = samples,
    };
    defer reader.deinit();

    if (shot) |dest| return reader.shoot(dest, width, height, start_page - 1);

    try reader.open(.{
        .width = width,
        .height = height,
        .frames = frames,
        .vsync = vsync,
        .start_page = start_page - 1,
        .device = .{ .validation = validate, .prefer = prefer },
    });
}

const Settings = struct {
    width: u32,
    height: u32,
    frames: ?u32,
    vsync: lyngvi.Vsync,
    start_page: u32,
    device: lyngvi.Device.Options,
};

/// One rendered page, on the device and in the display list's numbering.
///
/// `gpu` and `list` are the same number by construction -- both registries
/// hand out ids in creation order and both are only added to here -- but the
/// two mean different things, so they are kept apart and asserted equal rather
/// than assumed to be one field.
const Slot = struct {
    page: u32 = no_page,
    zoom: f32 = 0,
    gpu: u32 = 0,
    list: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// A monotonic frame stamp, for evicting the least recently drawn.
    used: u64 = 0,

    const no_page = std.math.maxInt(u32);

    fn matches(s: Slot, page: u32, zoom: f32) bool {
        return s.page == page and s.zoom == zoom;
    }
};

/// The rendered pages, kept on the CPU so `--shot` can sample them without a
/// device. The window does not use this: there the pixels go to the GPU and
/// the buffer is freed the same frame.
const CpuTextures = struct {
    entries: [cache_slots]?Reader.Image = @splat(null),

    fn deinit(t: *CpuTextures, gpa: std.mem.Allocator) void {
        for (&t.entries) |*e| {
            if (e.*) |image| gpa.free(image.pixels);
            e.* = null;
        }
    }

    fn sampler(t: *CpuTextures) gleipnir.software.Sampler {
        return .{ .ptr = t, .sample = sample };
    }

    /// Nearest neighbour. The page is drawn at exactly the size it was
    /// rasterised, so every sample lands in the middle of its own texel and a
    /// bilinear filter would have nothing to interpolate.
    fn sample(ptr: *anyopaque, tex: u32, u: f32, v: f32) Color {
        const t: *CpuTextures = @ptrCast(@alignCast(ptr));
        if (tex == 0 or tex > t.entries.len) return .transparent;
        const image = t.entries[tex - 1] orelse return .transparent;

        const x = std.math.clamp(@as(i64, @intFromFloat(u * @as(f32, @floatFromInt(image.width)))), 0, image.width - 1);
        const y = std.math.clamp(@as(i64, @intFromFloat(v * @as(f32, @floatFromInt(image.height)))), 0, image.height - 1);
        const o = (@as(usize, @intCast(y)) * image.width + @as(usize, @intCast(x))) * 4;
        return .{
            .r = @as(f32, @floatFromInt(image.pixels[o + 0])) / 255.0,
            .g = @as(f32, @floatFromInt(image.pixels[o + 1])) / 255.0,
            .b = @as(f32, @floatFromInt(image.pixels[o + 2])) / 255.0,
            .a = @as(f32, @floatFromInt(image.pixels[o + 3])) / 255.0,
        };
    }
};

const Reader = struct {
    ctx: *Context,
    doc: *fenrir.Document,
    pages: []const fenrir.Page,
    file: []const u8,
    zoom: f32,
    samples: gleipnir.raster.Samples,

    /// The top of the viewport, in document pixels at the current zoom.
    scroll: f32 = 0,
    /// Sideways, for when a page is wider than the window.
    pan: f32 = 0,
    viewport: [2]f32 = .{ 1, 1 },

    slots: [cache_slots]Slot = @splat(.{}),
    stamp: u64 = 0,

    /// Set when something moved, so the title is only rewritten when it would
    /// change: `setTitle` is a system call and a taskbar update.
    dirty_title: bool = true,
    shown_page: u32 = Slot.no_page,
    shown_zoom: f32 = 0,

    pages_rendered: u64 = 0,

    fn deinit(r: *Reader) void {
        _ = r;
    }

    // -- layout -------------------------------------------------------------

    /// A page's size in device pixels, rounded exactly the way
    /// `replay.canvasSize` rounds it, so the texture and the rectangle it is
    /// drawn into are the same size to the pixel.
    fn pageSize(r: *const Reader, index: usize) [2]f32 {
        const p = r.pages[index];
        return .{
            @max(1.0, @ceil(@as(f32, @floatCast(p.displayWidth())) * r.zoom)),
            @max(1.0, @ceil(@as(f32, @floatCast(p.displayHeight())) * r.zoom)),
        };
    }

    /// The top of page `index` in document pixels. Pages are stacked with a
    /// fixed gap, so this is a running sum rather than a table -- documents
    /// with thousands of pages would want the table.
    fn pageTop(r: *const Reader, index: usize) f32 {
        var y: f32 = gap;
        var i: usize = 0;
        while (i < index) : (i += 1) y += r.pageSize(i)[1] + gap;
        return y;
    }

    fn documentHeight(r: *const Reader) f32 {
        return r.pageTop(r.pages.len);
    }

    fn widestPage(r: *const Reader) f32 {
        var w: f32 = 1;
        for (0..r.pages.len) |i| w = @max(w, r.pageSize(i)[0]);
        return w;
    }

    fn maxScroll(r: *const Reader) f32 {
        return @max(0, r.documentHeight() - r.viewport[1]);
    }

    fn clampScroll(r: *Reader) void {
        r.scroll = std.math.clamp(r.scroll, 0, r.maxScroll());
        const slack = @max(0, r.widestPage() + gap * 2 - r.viewport[0]);
        r.pan = std.math.clamp(r.pan, -slack / 2, slack / 2);
    }

    /// The page occupying the middle of the viewport: what "which page am I
    /// on" means when two of them are on screen at once.
    fn currentPage(r: *const Reader) u32 {
        const middle = r.scroll + r.viewport[1] * 0.5;
        var i: usize = 0;
        while (i < r.pages.len) : (i += 1) {
            if (middle < r.pageTop(i) + r.pageSize(i)[1] + gap * 0.5) return @intCast(i);
        }
        return @intCast(r.pages.len - 1);
    }

    fn scrollToPage(r: *Reader, index: usize) void {
        r.scroll = r.pageTop(index) - gap;
        r.clampScroll();
    }

    /// Changes the zoom about the middle of the viewport, so the line you were
    /// reading stays where it was rather than sliding off the top.
    fn setZoom(r: *Reader, want: f32) void {
        const next = std.math.clamp(want, min_zoom, max_zoom);
        if (next == r.zoom) return;
        // Which page, and how far down it, the middle of the screen is on.
        const page = r.currentPage();
        const top = r.pageTop(page);
        const into = (r.scroll + r.viewport[1] * 0.5 - top) / @max(1, r.pageSize(page)[1]);

        r.zoom = next;
        r.scroll = r.pageTop(page) + into * r.pageSize(page)[1] - r.viewport[1] * 0.5;
        r.clampScroll();
        r.dirty_title = true;
    }

    fn fitWidth(r: *Reader) void {
        const page = r.currentPage();
        const points: f32 = @floatCast(r.pages[page].displayWidth());
        if (points > 0) r.setZoom((r.viewport[0] - gap * 2) / points);
        r.pan = 0;
    }

    // -- one frame, with no device ------------------------------------------

    /// Composes a frame and rasterises it with the CPU model of the rect
    /// pipeline, exactly as `fenrir ui` does.
    ///
    /// The point is not the picture. It is that the layout -- where a page
    /// lands, how big it is, what the scroll offset means -- can be checked on
    /// a machine with no display, in a test, and in a diff, rather than only
    /// by looking at a window. The pages inside it are the same images the
    /// window uploads.
    fn shoot(r: *Reader, dest: []const u8, width: u32, height: u32, start_page: u32) !void {
        const ctx = r.ctx;
        const gpa = ctx.gpa;

        r.viewport = .{ @floatFromInt(width), @floatFromInt(height) };
        r.scrollToPage(start_page);

        var list: DrawList = .init(gpa, .fromRect(0, 0, r.viewport[0], r.viewport[1]));
        defer list.deinit();

        var images: CpuTextures = .{};
        defer images.deinit(gpa);

        // Every visible page, rendered up front: there is no next frame to
        // finish in.
        var slot: usize = 0;
        while (r.firstMissing()) |page| {
            if (slot >= cache_slots) break;
            const image = r.rasterise(page) catch break;
            const id = try list.registerTexture(image.width, image.height);
            images.entries[id - 1] = image;
            r.slots[slot] = .{
                .page = page,
                .zoom = r.zoom,
                .gpu = id,
                .list = id,
                .width = image.width,
                .height = image.height,
            };
            slot += 1;
        }

        try r.compose(&list);

        var fb = try gleipnir.Framebuffer.init(gpa, width, height, .linear);
        defer fb.deinit(gpa);
        fb.clear(page_backdrop);
        gleipnir.software.render(fb, list.instances.items, images.sampler());

        var file = Io.Dir.cwd().createFile(ctx.io, dest, .{}) catch |err|
            return ctx.fail("cannot create {s}: {t}", .{ dest, err });
        defer file.close(ctx.io);

        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(ctx.io, &buf);
        fb.writePng(gpa, &writer.interface) catch |err|
            return ctx.fail("cannot write {s}: {t}", .{ dest, err });
        writer.interface.flush() catch |err|
            return ctx.fail("cannot write {s}: {t}", .{ dest, err });

        ctx.out.print("wrote {d}x{d} to {s}: {d} page{s} at {d:.0}%\n", .{
            width,
            height,
            dest,
            slot,
            if (slot == 1) "" else "s",
            r.zoom * 100,
        }) catch {};
    }

    // -- the window ---------------------------------------------------------

    fn open(r: *Reader, settings: Settings) !void {
        const ctx = r.ctx;
        const gpa = ctx.gpa;

        var window = lyngvi.open(gpa, .{
            .title = "fenrir",
            .width = settings.width,
            .height = settings.height,
        }) catch |err| return ctx.fail("could not open a window: {s}", .{@errorName(err)});
        defer window.destroy();

        var device = lyngvi.Device.init(gpa, window, settings.device) catch |err| {
            return switch (err) {
                error.NoVulkanLoader => ctx.fail(
                    "no Vulkan loader on this system. Install the graphics driver; the SDK is not needed.",
                    .{},
                ),
                error.NoSuitableDevice => ctx.fail(
                    "a Vulkan loader is present but no device can present to a window.",
                    .{},
                ),
                else => ctx.fail("could not create a device: {s}", .{@errorName(err)}),
            };
        };
        defer device.deinit();

        const size = window.size();
        var swapchain = lyngvi.Swapchain.init(gpa, &device, .{
            .width = size.width,
            .height = size.height,
        }, settings.vsync) catch |err| {
            return ctx.fail("could not create a swapchain: {s}", .{@errorName(err)});
        };
        defer swapchain.deinit();

        var renderer = lyngvi.Renderer.init(gpa, &device, &swapchain) catch |err| {
            return switch (err) {
                error.NoDescriptorIndexing => ctx.fail(
                    "{s} has no descriptor indexing, which the one-draw-call path requires.",
                    .{device.name()},
                ),
                else => ctx.fail("could not create the renderer: {s}", .{@errorName(err)}),
            };
        };
        defer renderer.deinit();

        ctx.note("{s}, {d}x{d}, {s}", .{
            device.name(),
            swapchain.extent.width,
            swapchain.extent.height,
            @tagName(swapchain.present_mode),
        });
        if (renderer.shaders_missing) {
            ctx.note("no SPIR-V in this build, so the window clears and presents but draws nothing", .{});
            ctx.note("{s}", .{lyngvi.shaders.compile_hint});
            return;
        }

        var list: DrawList = .init(gpa, .fromRect(0, 0, 1, 1));
        defer list.deinit();

        r.viewport = .{ @floatFromInt(size.width), @floatFromInt(size.height) };
        r.scrollToPage(settings.start_page);

        var uploads: std.ArrayList(lyngvi.Renderer.Upload) = .empty;
        defer uploads.deinit(gpa);

        var clock: lyngvi.Clock = .start(ctx.io);
        var drawn: u32 = 0;

        while (true) {
            window.pump();
            if (window.shouldClose()) break;
            if (settings.frames) |limit| {
                if (drawn >= limit) break;
            }

            const input = try window.events().take(clock.tick());
            const client = window.size();

            if (window.events().resized or swapchain.extent.width != client.width or
                swapchain.extent.height != client.height)
            {
                try swapchain.recreate(.{ .width = client.width, .height = client.height });
                try renderer.refresh();
            }
            if (swapchain.isMinimised()) {
                window.wait(100);
                continue;
            }

            r.viewport = .{
                @floatFromInt(swapchain.extent.width),
                @floatFromInt(swapchain.extent.height),
            };
            if (r.handle(input)) break;
            r.clampScroll();

            // One page per frame, so a scroll that crosses three unrendered
            // pages stays responsive and fills in over the next three frames
            // instead of freezing for the sum of them.
            var pixels: ?[]u8 = null;
            defer if (pixels) |p| gpa.free(p);
            pixels = r.renderOne(&renderer, &list, &uploads) catch |err| switch (err) {
                error.OutOfMemory => return ctx.fail("out of memory rendering a page", .{}),
                else => null,
            };

            list.reset(.fromRect(0, 0, r.viewport[0], r.viewport[1]));
            try r.compose(&list);
            r.updateTitle(window);

            switch (try renderer.frame(&list, uploads.items, page_backdrop)) {
                .drawn => drawn += 1,
                .needs_recreate => {
                    try swapchain.recreate(.{ .width = client.width, .height = client.height });
                    try renderer.refresh();
                },
                .skipped => window.wait(100),
            }
            uploads.clearRetainingCapacity();
        }

        renderer.waitIdle();
        ctx.note("{d} frames drawn, {d} pages rasterised, {d} MiB uploaded", .{
            renderer.frames_drawn,
            r.pages_rendered,
            renderer.bytes_uploaded / (1024 * 1024),
        });
    }

    fn updateTitle(r: *Reader, window: lyngvi.Window) void {
        const page = r.currentPage();
        if (!r.dirty_title and page == r.shown_page and r.zoom == r.shown_zoom) return;
        r.dirty_title = false;
        r.shown_page = page;
        r.shown_zoom = r.zoom;

        var buf: [512]u8 = undefined;
        const base = std.fs.path.basename(r.file);
        const title = std.fmt.bufPrint(&buf, "{s} -- page {d} of {d} -- {d:.0}%", .{
            base[0..@min(base.len, 200)],
            page + 1,
            r.pages.len,
            r.zoom * 100,
        }) catch return;
        window.setTitle(title);
    }

    // -- input --------------------------------------------------------------

    /// Returns true when the reader should close.
    fn handle(r: *Reader, in: lyngvi.Input) bool {
        const line = 60.0;
        const screen = r.viewport[1] * 0.9;

        if (in.modifiers.ctrl and in.scroll.y != 0) {
            // Ctrl and the wheel is zoom everywhere else, so it is zoom here.
            r.setZoom(r.zoom * std.math.pow(f32, 1.0015, in.scroll.y));
        } else {
            r.scroll -= in.scroll.y;
            r.pan += in.scroll.x;
        }

        if (in.repeated(.down)) r.scroll += line;
        if (in.repeated(.up)) r.scroll -= line;
        if (in.repeated(.right)) r.pan -= line;
        if (in.repeated(.left)) r.pan += line;
        if (in.repeated(.page_down)) r.scroll += screen;
        if (in.repeated(.page_up)) r.scroll -= screen;
        if (in.pressedOnce(.home)) r.scroll = 0;
        if (in.pressedOnce(.end)) r.scroll = r.maxScroll();
        if (in.pressedOnce(.escape)) return true;

        var buf: [32]u8 = undefined;
        for (in.typedText(&buf)) |c| switch (c) {
            'q', 'Q' => return true,
            'n', 'N', ' ' => r.scrollToPage(@min(r.currentPage() + 1, r.pages.len - 1)),
            'p', 'P' => r.scrollToPage(r.currentPage() -| 1),
            '+', '=' => r.setZoom(r.zoom * 1.25),
            '-', '_' => r.setZoom(r.zoom / 1.25),
            '0' => r.fitWidth(),
            '1' => r.setZoom(1),
            else => {},
        };
        return false;
    }

    // -- the cache ----------------------------------------------------------

    /// Renders at most one page that is on screen and not yet in the cache,
    /// and returns the pixel buffer the caller must keep alive until the frame
    /// has been submitted -- `Upload.pixels` is read during `frame`.
    fn renderOne(
        r: *Reader,
        renderer: *lyngvi.Renderer,
        list: *DrawList,
        uploads: *std.ArrayList(lyngvi.Renderer.Upload),
    ) !?[]u8 {
        const want = r.firstMissing() orelse return null;
        const gpa = r.ctx.gpa;

        const image = r.rasterise(want) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // A page that will not interpret is a blank page, not a dead
            // reader. It stays uncached and is retried, which is cheap
            // because it failed early.
            else => return null,
        };
        errdefer gpa.free(image.pixels);

        const slot = try r.claim(renderer, list, image.width, image.height);
        slot.page = want;
        slot.zoom = r.zoom;
        slot.width = image.width;
        slot.height = image.height;
        slot.used = r.stamp;

        try uploads.append(gpa, .{
            .texture = slot.gpu,
            .x = 0,
            .y = 0,
            .w = image.width,
            .h = image.height,
            .pixels = image.pixels,
            .stride = image.width * 4,
        });
        r.pages_rendered += 1;
        return image.pixels;
    }

    /// The first visible page with no up-to-date texture, nearest the top of
    /// the screen -- so a fresh window fills in downwards the way a person
    /// reads rather than in page order.
    fn firstMissing(r: *const Reader) ?u32 {
        var i: usize = 0;
        while (i < r.pages.len) : (i += 1) {
            const top = r.pageTop(i) - r.scroll;
            const bottom = top + r.pageSize(i)[1];
            // A page whose last row is exactly on the top edge contributes no
            // pixels, and neither does one whose first row is exactly on the
            // bottom. Rendering either is a page of work for nothing.
            if (bottom <= 0) continue;
            if (top >= r.viewport[1]) break;
            if (r.find(@intCast(i)) == null) return @intCast(i);
        }
        return null;
    }

    fn find(r: *const Reader, page: u32) ?*const Slot {
        for (&r.slots) |*s| {
            if (s.matches(page, r.zoom)) return s;
        }
        return null;
    }

    /// A slot to render into: an unused one, then the stalest, with its
    /// texture resized if the page is a different size from the last thing
    /// that lived there.
    fn claim(
        r: *Reader,
        renderer: *lyngvi.Renderer,
        list: *DrawList,
        width: u32,
        height: u32,
    ) !*Slot {
        var chosen: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (&r.slots, 0..) |*s, i| {
            if (s.gpu == 0) {
                // Never used: create the pair of registrations now. They are
                // handed out in creation order by both sides, which is what
                // makes the two ids equal -- checked, not trusted.
                const gpu = try renderer.createTexture(width, height, .color);
                const in_list = try list.registerTexture(width, height);
                std.debug.assert(gpu == in_list);
                s.gpu = gpu;
                s.list = in_list;
                s.width = width;
                s.height = height;
                return s;
            }
            if (s.used < oldest) {
                oldest = s.used;
                chosen = i;
            }
        }

        const s = &r.slots[chosen];
        if (s.width != width or s.height != height) {
            // A device-wide wait. Only on a zoom change or a document whose
            // pages differ in size, which is not per frame.
            try renderer.resizeTexture(s.gpu, width, height);
            list.setTextureSize(s.list, width, height);
        }
        return s;
    }

    pub const Image = struct { pixels: []u8, width: u32, height: u32 };

    /// One page, interpreted and rasterised. The same three calls
    /// `fenrir raster` makes, which is why the two produce identical images.
    fn rasterise(r: *Reader, index: u32) !Image {
        const gpa = r.ctx.gpa;

        var result = try content.page(gpa, r.doc, r.pages[index], .{});
        defer result.deinit(gpa);

        var zoom = r.zoom;
        var size = replay.canvasSize(result.list.page, zoom);
        while (@as(u64, size[0]) * size[1] > max_page_pixels and zoom > min_zoom) {
            zoom *= 0.5;
            size = replay.canvasSize(result.list.page, zoom);
        }

        var canvas = try gleipnir.raster.Canvas.init(gpa, size[0], size[1], .{ .samples = r.samples });
        defer canvas.deinit(gpa);
        canvas.fb.clear(.white);

        var glyphs: Glyphs = try .init(gpa, r.doc, result.list, r.ctx.io);
        defer glyphs.deinit();

        _ = replay.render(
            gpa,
            &canvas,
            result.list,
            replay.pageTransform(result.list.page, zoom),
            .{ .glyphs = glyphs.source() },
        ) catch |err| return err;

        return .{
            .pixels = try canvas.fb.toRgba8(gpa),
            .width = size[0],
            .height = size[1],
        };
    }

    // -- the frame ----------------------------------------------------------

    /// The backdrop a page sits on. Dark enough that white paper is obviously
    /// paper and not the whole window, and neutral so it does not tint what is
    /// next to it.
    const page_backdrop: Color = .gray(0.16);
    const paper: Color = .white;
    const shadow: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0.45 };
    const white: Color = .white;

    fn compose(r: *Reader, list: *DrawList) !void {
        r.stamp += 1;

        var i: usize = 0;
        while (i < r.pages.len) : (i += 1) {
            const size = r.pageSize(i);
            const top = r.pageTop(i) - r.scroll;
            if (top + size[1] <= 0) continue;
            if (top >= r.viewport[1]) break;

            const x = @round((r.viewport[0] - size[0]) * 0.5 + r.pan);
            const y = @round(top);
            const rect: Bounds = .fromRect(x, y, x + size[0], y + size[1]);

            // The shadow first, so the page sits on it rather than under it.
            try list.shadow(
                .fromRect(rect.min_x, rect.min_y + 3, rect.max_x, rect.max_y + 3),
                .{},
                8,
                shadow,
            );

            if (r.slotFor(@intCast(i))) |s| {
                s.used = r.stamp;
                try list.image(
                    rect,
                    s.list,
                    .fromRect(0, 0, @floatFromInt(s.width), @floatFromInt(s.height)),
                    white,
                );
            } else {
                // Paper with nothing on it yet. Better than a hole, and it
                // tells you the page exists and is coming.
                try list.fill(rect, paper);
            }
        }

        try r.scrollbar(list);
    }

    fn slotFor(r: *Reader, page: u32) ?*Slot {
        for (&r.slots) |*s| {
            if (s.matches(page, r.zoom)) return s;
        }
        return null;
    }

    /// A thumb on the right edge, wide enough to see and narrow enough to
    /// ignore. Not interactive yet -- it reports where you are, which is the
    /// half of a scrollbar that matters while reading.
    fn scrollbar(r: *Reader, list: *DrawList) !void {
        const total = r.documentHeight();
        if (total <= r.viewport[1]) return;

        const track = r.viewport[1] - gap * 2;
        const height = @max(24.0, track * r.viewport[1] / total);
        const travel = track - height;
        const y = gap + travel * (r.scroll / @max(1, r.maxScroll()));

        try list.rounded(
            .fromRect(r.viewport[0] - 12, y, r.viewport[0] - 6, y + height),
            .all(3),
            .{ .r = 1, .g = 1, .b = 1, .a = 0.35 },
        );
    }
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// `n` identical Letter-sized pages, with nothing in them: the layout below
/// reads only the boxes, so a page needs no document behind it to be laid out.
fn fakePages(buf: []fenrir.Page, n: usize) []fenrir.Page {
    const letter: fenrir.Page.Rect = .{ .x0 = 0, .y0 = 0, .x1 = 600, .y1 = 800 };
    for (buf[0..n], 0..) |*p, i| p.* = .{
        .index = @intCast(i),
        .ref = .{ .num = 0, .gen = 0 },
        .dict = .empty,
        .resources = .empty,
        .media_box = letter,
        .crop_box = letter,
        .rotate = .none,
    };
    return buf[0..n];
}

fn layoutOf(pages: []fenrir.Page, zoom: f32, viewport: [2]f32) Reader {
    return .{
        .ctx = undefined,
        .doc = undefined,
        .pages = pages,
        .file = "test.pdf",
        .zoom = zoom,
        .samples = .four,
        .viewport = viewport,
    };
}

test "pages stack with a gap and the document is as tall as their sum" {
    var buf: [4]fenrir.Page = undefined;
    var r = layoutOf(fakePages(&buf, 3), 1, .{ 700, 500 });

    try testing.expectEqual(@as(f32, 600), r.pageSize(0)[0]);
    try testing.expectEqual(@as(f32, 800), r.pageSize(0)[1]);

    try testing.expectEqual(@as(f32, gap), r.pageTop(0));
    try testing.expectEqual(@as(f32, gap + 800 + gap), r.pageTop(1));
    try testing.expectEqual(@as(f32, 3 * (800 + gap) + gap), r.documentHeight());
}

test "a page's size is the ceiling of its points times the zoom" {
    // Exactly what `replay.canvasSize` does, because the rectangle the page is
    // drawn into has to be the size of the texture to the pixel or the image
    // is resampled -- which on text is immediately visible.
    var buf: [1]fenrir.Page = undefined;
    var r = layoutOf(fakePages(&buf, 1), 0.3333, .{ 700, 500 });
    const size = r.pageSize(0);
    try testing.expectEqual(replay.canvasSize(.fromRect(0, 0, 600, 800), 0.3333), [2]u32{
        @intFromFloat(size[0]),
        @intFromFloat(size[1]),
    });
}

test "scrolling is clamped to the document, both ends" {
    var buf: [4]fenrir.Page = undefined;
    var r = layoutOf(fakePages(&buf, 3), 1, .{ 700, 500 });

    r.scroll = -1000;
    r.clampScroll();
    try testing.expectEqual(@as(f32, 0), r.scroll);

    r.scroll = 1e9;
    r.clampScroll();
    try testing.expectEqual(r.documentHeight() - 500, r.scroll);
}

test "a document shorter than the window does not scroll at all" {
    var buf: [1]fenrir.Page = undefined;
    var r = layoutOf(fakePages(&buf, 1), 0.2, .{ 700, 900 });
    r.scroll = 500;
    r.clampScroll();
    try testing.expectEqual(@as(f32, 0), r.scroll);
}

test "the current page is the one under the middle of the viewport" {
    var buf: [4]fenrir.Page = undefined;
    var r = layoutOf(fakePages(&buf, 3), 1, .{ 700, 400 });

    r.scrollToPage(0);
    try testing.expectEqual(@as(u32, 0), r.currentPage());
    r.scrollToPage(1);
    try testing.expectEqual(@as(u32, 1), r.currentPage());
    r.scrollToPage(2);
    try testing.expectEqual(@as(u32, 2), r.currentPage());

    // And past the end it stays on the last one rather than running off the
    // array, which is what a document whose final page is shorter than the
    // window does on every `end` press.
    r.scroll = 1e9;
    r.clampScroll();
    try testing.expectEqual(@as(u32, 2), r.currentPage());
}

test "zooming keeps the middle of the screen on the same part of the page" {
    // The property that makes zoom usable: the line you were reading is still
    // the line you are reading. Anchoring on the top of the document instead
    // sends you to a different chapter every time you press a key.
    var buf: [4]fenrir.Page = undefined;
    var r = layoutOf(fakePages(&buf, 3), 1, .{ 700, 500 });
    r.scrollToPage(1);
    r.scroll += 200;

    const page = r.currentPage();
    const before = (r.scroll + 250 - r.pageTop(page)) / r.pageSize(page)[1];
    r.setZoom(2);
    const after = (r.scroll + 250 - r.pageTop(page)) / r.pageSize(page)[1];

    try testing.expectEqual(page, r.currentPage());
    try testing.expectApproxEqAbs(before, after, 1e-3);
}

test "fit-width makes the page as wide as the window, less the margins" {
    var buf: [1]fenrir.Page = undefined;
    var r = layoutOf(fakePages(&buf, 1), 1, .{ 928, 500 });
    r.fitWidth();
    try testing.expectApproxEqAbs(@as(f32, 900), r.pageSize(0)[0], 1);
}

test "the zoom stays inside its limits however hard it is pushed" {
    var buf: [1]fenrir.Page = undefined;
    var r = layoutOf(fakePages(&buf, 1), 1, .{ 700, 500 });
    for (0..64) |_| r.setZoom(r.zoom * 4);
    try testing.expectEqual(@as(f32, max_zoom), r.zoom);
    for (0..64) |_| r.setZoom(r.zoom / 4);
    try testing.expectEqual(@as(f32, min_zoom), r.zoom);
}

test "only the pages on screen are asked for" {
    // The cache is six slots and a document is hundreds of pages, so the
    // decision of what to render has to be driven by the viewport rather than
    // by the page list.
    var buf: [64]fenrir.Page = undefined;
    // Half scale, so two pages fit on the screen at once and "the next one
    // down" is a page that is actually visible.
    var r = layoutOf(fakePages(&buf, 40), 0.5, .{ 700, 500 });
    r.scrollToPage(20);

    // Nothing cached: the first thing wanted is the page at the top of the
    // screen, not page zero.
    try testing.expectEqual(@as(u32, 20), r.firstMissing().?);

    // With that one cached, the next one down.
    r.slots[0] = .{ .page = 20, .zoom = r.zoom, .gpu = 1, .list = 1 };
    try testing.expectEqual(@as(u32, 21), r.firstMissing().?);

    // A slot rendered at a different zoom is not a hit.
    r.slots[0].zoom = r.zoom * 2;
    try testing.expectEqual(@as(u32, 20), r.firstMissing().?);
}
