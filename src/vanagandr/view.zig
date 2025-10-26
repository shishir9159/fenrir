//! `fenrir view` -- the same frame as `fenrir ui`, in a real window on a real
//! device.
//!
//! It draws the scene from `ui.zig` rather than a new one on purpose. That
//! scene is already rendered by the CPU reference rasteriser into `ui.png`, so
//! the two paths produce the same instances from the same box tree and the
//! difference between the images is the difference between the rasterisers --
//! which is the only way to find out whether the shader agrees with
//! `gleipnir/sdf.zig`.
//!
//! Three ways to run it:
//!
//! * `fenrir view` opens a window and stays open until it is closed.
//! * `fenrir view --frames 60` runs sixty frames and exits, which is what
//!   makes it usable from a script and on a machine nobody is sitting at.
//! * `fenrir view --probe` creates no window at all: it opens the Vulkan
//!   loader, enumerates the devices, and prints what each one can do. That
//!   works on a headless machine and is the first thing to run when something
//!   is wrong.

const std = @import("std");
const fenrir = @import("fenrir");

const Context = @import("Context.zig");
const ui_demo = @import("ui.zig");

const gleipnir = fenrir.gleipnir;
const lyngvi = fenrir.lyngvi;
const thviti = fenrir.thviti;
const tyr = fenrir.tyr;

const Bounds = fenrir.gelgja.Bounds;
const Color = fenrir.gelgja.Color;
const DrawList = gleipnir.DrawList;
const Fonts = tyr.Fonts;
const UI = thviti.UI;

pub const usage =
    \\fenrir view [--frames N] [--size WxH] [--vsync on|off|adaptive]
    \\            [--validate] [--gpu NAME] [--probe]
    \\
    \\    Opens a window, creates a Vulkan device and swapchain, and draws the
    \\    same interface `fenrir ui` writes to a PNG -- so the two can be
    \\    compared, which is the only way to tell whether the shader agrees
    \\    with the CPU reference rasteriser.
    \\
    \\    --frames N   run N frames and exit, instead of until the window is
    \\                 closed. Makes the command usable from a script.
    \\    --vsync      on (default) presents at the refresh rate and is what a
    \\                 document reader should do; off uses mailbox or immediate
    \\                 and burns a core to show frames nobody asked for.
    \\    --validate   turns on the Khronos validation layers, if installed.
    \\    --gpu NAME   prefers a device whose name contains NAME.
    \\    --probe      lists the devices and exits. Opens no window, so it
    \\                 works over ssh and on a machine with no display.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    var width: u32 = 1100;
    var height: u32 = 760;
    var frames: ?u32 = null;
    var vsync: lyngvi.Vsync = .on;
    var validate = false;
    var prefer: ?[]const u8 = null;
    var probe_only = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--probe")) {
            probe_only = true;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            validate = true;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            i += 1;
            if (i >= args.len) return ctx.fail("--frames needs a count", .{});
            frames = std.fmt.parseInt(u32, args[i], 10) catch
                return ctx.fail("--frames wants a number, not '{s}'", .{args[i]});
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
        } else {
            return ctx.fail("unknown option {s}", .{arg});
        }
    }

    const device_options: lyngvi.Device.Options = .{ .validation = validate, .prefer = prefer };
    if (probe_only) return probe(ctx, device_options);

    if (!lyngvi.has_window) {
        return ctx.fail(
            "no window backend for this platform yet: Lyngvi speaks Win32, and the xcb backend is a stub",
            .{},
        );
    }

    try render(ctx, .{
        .width = width,
        .height = height,
        .frames = frames,
        .vsync = vsync,
        .device = device_options,
    });
}

const Settings = struct {
    width: u32,
    height: u32,
    frames: ?u32,
    vsync: lyngvi.Vsync,
    device: lyngvi.Device.Options,
};

fn render(ctx: *Context, settings: Settings) !void {
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
                "{s} has no descriptor indexing, which the one-draw-call path requires. " ++
                    "The fallback is DrawList.textureRuns and a single-texture shader, which is not written yet.",
                .{device.name()},
            ),
            else => ctx.fail("could not create the renderer: {s}", .{@errorName(err)}),
        };
    };
    defer renderer.deinit();

    ctx.note("{s} ({s}{s}), Vulkan {d}.{d}, {s}", .{
        device.name(),
        device.properties.vendor(),
        if (device.properties.vendor().len == 0) device.properties.device_type.name() else "",
        fenrir.lyngvi.vk.versionMajor(device.properties.api_version),
        fenrir.lyngvi.vk.versionMinor(device.properties.api_version),
        @tagName(swapchain.present_mode),
    });
    ctx.note("{d}x{d} in {d} swapchain image{s}, {s}", .{
        swapchain.extent.width,
        swapchain.extent.height,
        swapchain.imageCount(),
        if (swapchain.imageCount() == 1) "" else "s",
        @tagName(swapchain.format),
    });
    if (!swapchain.srgb) {
        ctx.note(
            "no sRGB surface format on offer: the shader blends in linear light and this frame will look dark",
            .{},
        );
    }
    if (renderer.shaders_missing) {
        ctx.note("no SPIR-V in this build, so nothing is drawn -- the window still clears and presents", .{});
        ctx.note("{s}", .{lyngvi.shaders.compile_hint});
    }

    // -- the rest of the stack, exactly as `fenrir ui` builds it ------------

    var fonts: Fonts = try .init(gpa, .{ .subpixel_positions = 3 });
    defer fonts.deinit();

    var ui: UI = .init(gpa, thviti.text.metricsOf(&fonts));
    defer ui.deinit();

    var list: DrawList = .init(gpa, .fromRect(0, 0, 1, 1));
    defer list.deinit();

    var draw: thviti.draw.Renderer = .init(gpa);
    defer draw.deinit();

    // The atlas texture, registered in both places in the same order so the
    // ids match. `Renderer.createTexture` and `DrawList.registerTexture` both
    // hand out one-based ids in creation order, which is a convention rather
    // than a link between them -- so it is asserted here rather than assumed.
    const gpu_atlas = try renderer.createTexture(fonts.atlasWidth(), fonts.atlasHeight(), .coverage);
    const list_atlas = try list.registerTexture(fonts.atlasWidth(), fonts.atlasHeight());
    std.debug.assert(gpu_atlas == list_atlas);

    var atlas_height = fonts.atlasHeight();
    var state: ui_demo.State = .{};
    var clock: lyngvi.Clock = .start(ctx.io);
    var drawn: u32 = 0;

    // A whole-atlas upload for the first frame: the texture was just created
    // and nothing in it is valid yet, so the dirty region is everything.
    var uploads: std.ArrayList(lyngvi.Renderer.Upload) = .empty;
    defer uploads.deinit(gpa);

    while (true) {
        window.pump();
        if (window.shouldClose()) break;
        if (settings.frames) |limit| {
            if (drawn >= limit) break;
        }

        const input = try window.events().take(clock.tick());
        const client = window.size();

        // A resize is answered before the frame that needs it, not after: the
        // UI lays out at the new size and the swapchain is already the new
        // size when the draw arrives.
        if (window.events().resized or swapchain.extent.width != client.width or
            swapchain.extent.height != client.height)
        {
            try swapchain.recreate(.{ .width = client.width, .height = client.height });
            try renderer.refresh();
        }
        if (swapchain.isMinimised()) {
            // Nothing to draw into. Block for a message instead of spinning:
            // a minimised window that burns a core is a bug people notice on
            // battery long before they notice it anywhere else.
            window.wait(100);
            continue;
        }

        const viewport: Bounds = .fromRect(
            0,
            0,
            @floatFromInt(swapchain.extent.width),
            @floatFromInt(swapchain.extent.height),
        );

        fonts.beginFrame();
        try ui.begin(viewport, input);
        try ui_demo.scene(&ui, &state);
        ui.end();

        // Þviti's tree becomes instances, and the glyphs Týr rasterised this
        // frame become an upload.
        list.reset(viewport);
        try draw.render(&list, &ui, &fonts, list_atlas);

        uploads.clearRetainingCapacity();
        if (fonts.atlasHeight() != atlas_height) {
            // The atlas doubled. Every cached rectangle is still valid -- Týr
            // grows downwards for exactly this reason -- but the image is a
            // different size, so it is rebuilt and re-uploaded whole.
            atlas_height = fonts.atlasHeight();
            try renderer.resizeTexture(gpu_atlas, fonts.atlasWidth(), atlas_height);
            _ = fonts.takeDirty();
            try uploads.append(gpa, .{
                .texture = gpu_atlas,
                .x = 0,
                .y = 0,
                .w = fonts.atlasWidth(),
                .h = atlas_height,
                .pixels = fonts.atlasPixels(),
                .stride = fonts.atlasWidth(),
            });
        } else if (fonts.takeDirty()) |dirty| {
            try uploads.append(gpa, .{
                .texture = gpu_atlas,
                .x = dirty.x,
                .y = dirty.y,
                .w = dirty.w,
                .h = dirty.h,
                .pixels = fonts.atlasPixels(),
                .stride = fonts.atlasWidth(),
            });
        }

        switch (try renderer.frame(&list, uploads.items, .gray(0.07))) {
            .drawn => drawn += 1,
            .needs_recreate => {
                try swapchain.recreate(.{ .width = client.width, .height = client.height });
                try renderer.refresh();
            },
            .skipped => window.wait(100),
        }
    }

    renderer.waitIdle();

    ctx.note("{d} frames drawn, {d} skipped, {d} swapchain rebuilds", .{
        renderer.frames_drawn,
        renderer.frames_skipped,
        renderer.recreates,
    });
    ctx.note("{d} instances at the high-water mark, {d} draw call{s} without descriptor indexing", .{
        renderer.instance_high_water,
        list.runCount(),
        if (list.runCount() == 1) "" else "s",
    });
    ctx.note("atlas {d}x{d}, {d} glyphs, {d} bytes uploaded", .{
        fonts.atlasWidth(),
        fonts.atlasHeight(),
        fonts.atlas.count(),
        renderer.bytes_uploaded,
    });
    if (!tyr.glyphs_are_real) {
        ctx.note("no glyph source in this build: every character is Tyr's fallback box", .{});
    }
}

fn probe(ctx: *Context, options: lyngvi.Device.Options) !void {
    const version = lyngvi.Device.loaderVersion() orelse {
        return ctx.fail(
            "no Vulkan loader on this system. Install the graphics driver; the SDK is not needed.",
            .{},
        );
    };
    const vk = lyngvi.vk;

    const w = ctx.out;
    try w.print("loader          Vulkan {d}.{d}.{d}\n", .{
        vk.versionMajor(version),
        vk.versionMinor(version),
        vk.versionPatch(version),
    });
    try w.print("shaders         {s}\n", .{
        if (lyngvi.has_shaders) "SPIR-V compiled into this binary" else "none in this build",
    });
    try w.print("window backend  {s}\n\n", .{
        if (lyngvi.has_window) "win32" else "none for this platform",
    });

    const reports = lyngvi.Device.probe(ctx.gpa, options) catch |err| {
        return ctx.fail("could not enumerate devices: {s}", .{@errorName(err)});
    };
    defer ctx.gpa.free(reports);

    if (reports.len == 0) {
        try w.writeAll("no Vulkan devices. The loader is installed but no driver registered with it.\n");
        return;
    }

    for (reports, 0..) |r, i| {
        try w.print("device {d}  {s}\n", .{ i, r.deviceName() });
        try w.print("  kind          {s}{s}{s}\n", .{
            r.kind.name(),
            if (r.vendor.len == 0) "" else ", ",
            r.vendor,
        });
        try w.print("  api           {d}.{d}.{d}\n", .{
            vk.versionMajor(r.api_version),
            vk.versionMinor(r.api_version),
            vk.versionPatch(r.api_version),
        });
        try w.print("  memory        {d} MiB device-local\n", .{r.vram / (1024 * 1024)});
        try w.print("  swapchain     {s}\n", .{if (r.swapchain) "yes" else "no"});
        // The one that decides whether a frame is one draw call or one per
        // texture run, which for the demo interface is the difference between
        // 1 and 18.
        try w.print("  indexing      {s}\n", .{if (r.descriptor_indexing) "yes" else "no"});
    }
}
