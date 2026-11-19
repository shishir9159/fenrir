//! The window and what is drawn in it: the device, the swapchain and the
//! loop that drives them; each window's pages, scrollbar and edges composed
//! into the two lists the renderer draws; and `--time`, `--bench` and
//! `--shot`, which measure that loop or photograph one turn of it.
//!
//! With `render.zig` this is the reader's hot path: everything here runs
//! once a frame.

const std = @import("std");
const Io = std.Io;
const fenrir = @import("fenrir");

const Context = @import("../Context.zig");
const chrome_mod = @import("../chrome.zig");
const find_mod = @import("../find.zig");
const palette_mod = @import("../palette.zig");
const rails_mod = @import("../rails.zig");
const settings_page = @import("../settings.zig");
const Session = @import("Session.zig");
const compare = @import("compare.zig");
const cursor = @import("cursor.zig");
const ink = @import("ink.zig");
const interface = @import("interface.zig");
const marks = @import("marks.zig");
const plugins_mod = @import("plugins.zig");
const reload = @import("reload.zig");
const render = @import("render.zig");
const search_mod = @import("search.zig");
const windows = @import("windows.zig");

const content = fenrir.content;
const gelgja = fenrir.gelgja;
const gleipnir = fenrir.gleipnir;
const hlidskjalf = fenrir.hlidskjalf;
const lyngvi = fenrir.lyngvi;

const Bounds = gelgja.Bounds;
const Color = gelgja.Color;
const DrawList = gleipnir.DrawList;

const View = hlidskjalf.View;
const text = hlidskjalf.text;

const caps = fenrir.build_options;
const have_gpu = caps.path_gpu;
const max_zoom = View.max_zoom;

/// The benchmark driver and its workloads, or `noreturn` in a build that
/// has none -- the reason is on `Session.LibraryIfStored`.
pub const BenchKind = if (caps.bench) Bench.Kind else noreturn;
const BenchDriver = if (caps.bench) Bench else noreturn;

/// Frames a device shot waits for the visible pages before taking what it has.
const shot_patience: u32 = 3000;

pub const Settings = struct {
    width: u32,
    height: u32,
    frames: ?u32,
    /// Read one frame back from the device into this file, and exit.
    shot: ?[]const u8 = null,
    vsync: lyngvi.Vsync,
    start_page: u32,
    page_given: bool,
    splits: []const u8 = &.{},
    device: lyngvi.Device.Options,
    /// `--time`: what the frames cost, summarised on exit.
    time: bool = false,
    bench: ?BenchKind = null,
};

/// `--bench`: a workload that is the same on every run, so two builds, or the
/// two backends, can be set side by side on it.
///
/// A step moves the focused window, and the next waits until everything the
/// step brought into view has arrived. So the frames drawn with every page
/// present -- what scrolling and zooming cost, frame after frame -- and the
/// wait for a page -- what arriving costs -- are counted apart, and neither
/// hides in the other's average.
pub const Bench = struct {
    kind: Kind,
    step: u32 = 0,
    /// The scroll's stride, taken at the first step, so later zooms and page
    /// sizes do not change the run.
    stride: f32 = 0,
    /// Frames drawn while something visible was still missing.
    waited: u32 = 0,
    /// From a step to the last page it brought into view being there.
    arrival: lyngvi.Renderer.Samples = .{},
    pending: ?Lap = null,

    /// Steps each way between 50% and `max_zoom`, five percent a step. Taken
    /// at the first step, from the window's own 100%.
    zoom_steps: u32 = 0,

    pub const Kind = enum { scroll, zoom, flip };

    /// Up, down, up, down.
    const zoom_legs = 4;

    /// Moves the window for the next frame. False once the workload is done.
    fn advance(b: *Bench, v: *View) bool {
        defer b.step += 1;
        switch (b.kind) {
            .scroll => {
                if (b.step == 0) {
                    b.stride = v.pageSize(0)[1] / 20;
                    v.scroll = 0;
                } else {
                    if (v.scroll >= v.maxScroll()) return false;
                    v.scroll += b.stride;
                }
                v.clampScroll();
            },
            .zoom => {
                const half = 0.5 * v.hundredPercent();
                if (b.step == 0) b.zoom_steps = @intFromFloat(@ceil(@log(max_zoom / half) / @log(1.05)));
                const leg = b.step / b.zoom_steps;
                if (leg >= zoom_legs) return false;
                const k = b.step % b.zoom_steps;
                const up = if (leg % 2 == 0) k else b.zoom_steps - k;
                v.setZoom(half * std.math.pow(f32, 1.05, @floatFromInt(up)));
            },
            .flip => {
                if (b.step >= v.pages.len) return false;
                v.scrollToPage(b.step);
            },
        }
        return true;
    }
};

/// `--time`'s startup stopwatch.
///
/// The reader's start is a sequence of one-off costs -- the library, the
/// documents, a Vulkan device, a swapchain, two pipelines, and then the first
/// page actually rendered -- and until one of them is named with a number,
/// "startup feels slow" cannot be acted on. Every stage prints how long it
/// took and how long the run has been going, so both the individual cost and
/// the point the window appears are readable off one list.
///
/// Off unless `--time` was given, and then it is a handful of `note` calls on
/// a path that runs once.
pub const Stage = struct {
    ctx: *Context,
    on: bool,
    clock: Lap,
    total: u64 = 0,

    pub fn mark(s: *Stage, comptime what: []const u8) void {
        const ns = s.clock.lap();
        if (!s.on) return;
        s.total += ns;
        s.ctx.note("start  {s:<12} {d:>8.2}ms  ({d:.2} in)", .{
            what,
            @as(f64, @floatFromInt(ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(s.total)) / 1_000_000.0,
        });
    }
};

pub fn msOf(ns: u64) f32 {
    return @floatCast(@as(f64, @floatFromInt(ns)) / 1_000_000.0);
}

/// One line of `--time`'s exit summary.
fn reportSpread(ctx: *Context, comptime what: []const u8, samples: *lyngvi.Renderer.Samples) void {
    const sp = samples.spread();
    if (sp.n == 0) return;
    ctx.note("time   {s:<10} best {d:.3}ms  median {d:.3}  p95 {d:.3}  of {d}", .{
        what, sp.best, sp.median, sp.p95, sp.n,
    });
}

/// A stopwatch over `Io`'s monotonic clock. Zig 0.16 has no `std.time.Timer`,
/// and `lyngvi.Clock` answers in seconds of `f32`, which cannot resolve a
/// stage that takes two milliseconds.
pub const Lap = struct {
    io: Io,
    last: Io.Timestamp,

    pub fn start(io: Io) Lap {
        return .{ .io = io, .last = Io.Clock.awake.now(io) };
    }

    pub fn lap(l: *Lap) u64 {
        const now = Io.Clock.awake.now(l.io);
        const ns = l.last.durationTo(now).nanoseconds;
        l.last = now;
        return if (ns <= 0) 0 else @intCast(ns);
    }
};

// -- the frame ---------------------------------------------------------------

/// The backdrop a page sits on, the paper under one that has not arrived,
/// the shadow it sits on, and the line between two windows.
///
/// Four literals until the theme reached this far down. They were
/// `gray(0.16)`, white, black at 0.45 and `gray(0.08)`, which are the
/// dark theme's `ground`, `paper`, `shadow` and `divider` to within a
/// hundredth -- the light theme needed all four to move together, and a
/// backdrop that stayed near black under a light interface is exactly
/// the sort of half-applied theme this file was meant not to have.
const white: Color = .white;

fn compose(s: *Session, list: *DrawList, over: *DrawList) !void {
    s.stamp += 1;
    s.recorded.stamp = s.stamp;

    if (!caps.splits) {
        // One window: no order to draw windows in, no lines between them
        // and no focus ring to say which one is meant. Still clipped, so
        // that a page's shadow stays off the status bar as it would in a
        // split.
        const v = s.view();
        list.pushClip(v.rect);
        over.pushClip(v.rect);
        defer list.popClip();
        defer over.popClip();
        return composeView(s, v, list, over);
    }

    s.order.clearRetainingCapacity();
    try s.layout().leaves(&s.order, s.gpa);

    for (s.order.items) |leaf| {
        const v = s.layout().viewAt(s.layout().nodes.items[leaf].pane.view().?);
        // Everything a window draws is confined to its own rectangle, or
        // a page scrolled past the bottom of one split would appear in
        // the next.
        list.pushClip(v.rect);
        over.pushClip(v.rect);
        defer list.popClip();
        defer over.popClip();
        try composeView(s, v, list, over);
    }

    // The lines between windows, then the focus ring, on top of
    // everything so neither is covered by a page.
    s.borders.clearRetainingCapacity();
    try s.layout().borders(&s.borders, s.gpa);
    for (s.borders.items) |b| try over.fill(b, s.theme.divider);

    if (s.layout().count() > 1) {
        const focused = s.layout().nodes.items[s.layout().focus].rect;
        try over.border(focused, .all(0), 2, .{
            .r = s.accent.r,
            .g = s.accent.g,
            .b = s.accent.b,
            .a = 0.9,
        });
    }
}

fn composeView(s: *Session, v: *View, list: *DrawList, over: *DrawList) !void {
    const b = s.buffer(v.buffer);
    const range = v.visiblePages();
    const overlay = caps.compare and compare.overlaid(s, v);

    var i = range.first;
    while (i < range.end) : (i += 1) {
        const rect = v.pageRect(i);

        // The shadow first, so the page sits on it rather than under it.
        try list.shadow(
            .fromRect(rect.min_x, rect.min_y + 3, rect.max_x, rect.max_y + 3),
            .{},
            8,
            s.theme.shadow,
        );

        if (s.backend == .gpu and !overlay) {
            // Blank paper. The path pipeline draws on it, in its own pass
            // between this list and `over`.
            s.recorded.touch(v.buffer, i);
            try list.fill(rect, s.theme.paper);
        } else if (render.slotFor(s, v.buffer, i, v.zoom, overlay)) |slot| {
            slot.used = s.stamp;
            try list.image(
                rect,
                slot.list,
                .fromRect(0, 0, @floatFromInt(slot.width), @floatFromInt(slot.height)),
                white,
            );
        } else {
            // Paper with nothing on it yet. Better than a hole, and it
            // tells you the page exists and is coming.
            try list.fill(rect, s.theme.paper);
        }
    }

    try compare.drawChanges(s, v, range, over);
    if (caps.marks) {
        try marks.drawMarks(s, v, b, range, over);
        try ink.drawInk(s, v, b, range, over);
    }
    if (caps.search) try search_mod.drawSearchHits(s, v, range, over);

    if (caps.marks) {
        v.marks_seen = b.marks.revision;
        try cursor.drawSelection(s, v, over);
        try cursor.drawCaret(s, v, over);
    }
    try drawScrollbar(s, v, over);
}

/// A highlight's own shape: the glyph boxes, padded.
///
/// The text map's boxes are tight around the type -- they are what a
/// caret is placed against -- and a block drawn exactly on them clips the
/// ascenders and reads as a stripe rather than as something laid over the
/// words. A little air on each side, in device pixels so it does not grow
/// with the zoom, is the difference.
pub fn blockOf(box: Bounds, zoom: f32) Bounds {
    const pad = @max(1.0, zoom * 0.6);
    return .fromRect(box.min_x - pad, box.min_y - pad, box.max_x + pad, box.max_y + pad);
}

pub fn markRadius(zoom: f32) f32 {
    return @max(2.0, zoom * 1.5);
}

fn drawScrollbar(s: *Session, v: *View, list: *DrawList) !void {
    const bar = v.scrollbarAt() orelse return;
    const alpha: f32 = if (v.dragging != null) 0.75 else if (v.hot_thumb) 0.55 else 0.35;
    try list.rounded(
        .fromRect(bar.x0, bar.y, bar.x1, bar.y + bar.height),
        .all(3),
        .{ .r = s.accent.r, .g = s.accent.g, .b = s.accent.b, .a = alpha },
    );
    try compare.drawChangeTicks(s, v, bar, list);
}

/// The rectangle the windows get, which is the client area less whatever
/// the interface has taken off it.
///
/// The status bar and the rails are *reserved*, not drawn over: a bar
/// that floated on top would cover the last line of the page, and a
/// reader whose last line is hidden is worse than one with a shorter
/// page. Every window's fit refits to this, because `Layout.arrange`
/// calls `refit` on each rectangle it hands out -- which is also why a
/// page fitted down the window fits above the bar rather than behind it.
///
/// Reserving the rail rather than floating it is also what settles which
/// of the two a click belonged to: a pointer over a rail is never also
/// over a page, so there is nothing to arbitrate. The panels are the ones
/// that overlay, and they are asked about separately.
///
/// A build with no rails reserves nothing for them, and its pages have the
/// width.
pub fn windowRect(s: *const Session, width: f32, height: f32) Bounds {
    if (s.chrome == null) return .fromRect(0, 0, width, @max(height, 1));
    const rail: f32 = if (caps.panels) rails_mod.width else 0;
    const top = if (caps.splits) windows.tabInset(s) else 0;
    return .fromRect(
        rail,
        top,
        @max(width - rail, rail + 1),
        @max(height - chrome_mod.status_height, top + 1),
    );
}

// -- one frame, with no device -----------------------------------------------

/// The rendered pages, kept on the CPU so `--shot` can sample them without a
/// device. The window does not use this: there the pixels go to the GPU and
/// the buffer is freed the same frame.
const CpuTextures = struct {
    entries: [render.cache_slots]?render.Image = @splat(null),

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

/// Composes a frame and rasterises it with the CPU model of the rect
/// pipeline, exactly as `fenrir ui` does.
///
/// The point is not the picture. It is that the layout -- where a page
/// lands, how big it is, where a split falls -- can be checked on a
/// machine with no display, in a test, and in a diff, rather than only by
/// looking at a window.
pub fn shoot(s: *Session, dest: []const u8, width: u32, height: u32, start_page: u32, splits: []const u8) !void {
    const ctx = s.ctx;
    const gpa = s.gpa;

    // There is no device here, so there is no path pipeline either: a
    // shot is always the CPU rasteriser, whatever the window would use.
    s.backend = .cpu;

    s.tabs.arrange(.fromRect(0, 0, @floatFromInt(width), @floatFromInt(height)));
    if (caps.splits) windows.applySplits(s, splits);

    var it = s.layout().iterator();
    while (it.next()) |v| {
        if (v.fit_on_open) v.fitTo(.width);
        if (v.scroll == 0) v.scrollToPage(start_page);
    }
    compare.arrangeComparison(s);

    var list: DrawList = .init(gpa, .fromRect(0, 0, @floatFromInt(width), @floatFromInt(height)));
    defer list.deinit();

    var images: CpuTextures = .{};
    defer images.deinit(gpa);

    // Every visible page, rendered up front: there is no next frame to
    // finish in, and no thread to finish it on.
    var slot: usize = 0;
    while (render.firstMissing(s)) |job| {
        if (slot >= render.cache_slots) break;

        const image = if (caps.compare and job.want == .overlay)
            compare.rasteriseOverlay(s, job) catch {
                render.noteFailure(s, job);
                continue;
            }
        else page: {
            const b = s.buffer(job.buffer);
            var result = content.page(gpa, b.doc, b.pages[job.page], render.page_options) catch break;
            defer result.deinit(gpa);

            if (caps.marks) {
                if (text.build(gpa, result.list) catch null) |map| b.putMap(gpa, job.page, map);
            }

            break :page render.rasterise(s, job, result.list, b) catch {
                render.noteFailure(s, job);
                continue;
            };
        };
        const id = try list.registerTexture(image.width, image.height);
        images.entries[id - 1] = image;
        s.slots[slot] = .{
            .buffer = job.buffer,
            .page = job.page,
            .zoom = job.zoom,
            .gpu = id,
            .list = id,
            .width = image.width,
            .height = image.height,
            .overlay = job.want == .overlay,
        };
        slot += 1;
    }

    // `--shot` models the rect pipeline only, so the two layers go into
    // one list: there is no path pass between them to separate.
    try compose(s, &list, &list);

    var fb = try gleipnir.Framebuffer.init(gpa, width, height, .linear);
    defer fb.deinit(gpa);
    fb.clear(s.theme.ground);
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

    ctx.out.print("wrote {d}x{d} to {s}: {d} page{s} in {d} window{s} at {d:.0}%\n", .{
        width,
        height,
        dest,
        slot,
        if (slot == 1) "" else "s",
        s.layout().count(),
        if (s.layout().count() == 1) "" else "s",
        s.view().percent(),
    }) catch {};
}

// -- the window --------------------------------------------------------------

pub fn open(s: *Session, settings: Settings) !void {
    const ctx = s.ctx;
    const gpa = s.gpa;

    var window = lyngvi.open(gpa, .{
        .title = "fenrir",
        .width = settings.width,
        .height = settings.height,
        // A shot is read back from the device, not looked at.
        .visible = settings.shot == null,
    }) catch |err| return ctx.fail("could not open a window: {s}", .{@errorName(err)});
    defer window.destroy();
    if (s.stage) |g| g.mark("window");

    // The interface, before the device: the face comes off the disk and
    // the first frame's glyphs are rasterised on the CPU, so none of it
    // waits on a Vulkan device that takes three quarters of a second to
    // create. A reader that cannot find a face still opens -- Týr's
    // fallback draws boxes -- so this is a note, not a failure.
    s.chrome = chrome_mod.Chrome.create(gpa, ctx.io) catch |err| blk: {
        ctx.note("no interface font ({s}); the status bar will draw as boxes", .{
            @errorName(err),
        });
        break :blk null;
    };
    if (s.chrome) |c| {
        if (!c.hasFace()) {
            ctx.note("no face for the interface on this machine; drawing Tyr's boxes", .{});
        }
    }

    const size = window.size();

    // Where every window starts, settled here rather than after the
    // device, because none of it needs one: the display's scale and the
    // window's size are known as soon as the window is, and the zoom
    // decides where every page begins.
    //
    // Now there is a display to be a percentage of, and a window to fit
    // to. Both have to happen before the first `scrollToPage`.
    const scale = window.scale();
    s.tabs.arrange(windowRect(s, @floatFromInt(size.width), @floatFromInt(size.height)));
    {
        const v = s.view();
        v.dpi_scale = scale;
        if (v.fit_on_open) v.fitTo(.width);
    }
    if (caps.splits) windows.applySplits(s, settings.splits);
    {
        // After the splits, because a split refits the zoom and a zoom
        // moves where every page starts: scrolling to `--page` first
        // would land above it by however much the refit moved things.
        var it = s.layout().iterator();
        while (it.next()) |v| {
            v.dpi_scale = scale;
            if (settings.page_given) v.scrollToPage(settings.start_page);
        }
    }
    compare.arrangeComparison(s);
    s.remember(s.view());
    // The window exists and every window is where it will start, so a
    // plugin reacting to `start` can split, scroll or zoom and see it.
    if (s.plugins) |rt| {
        rt.emit(.{ .event = .Start });
        plugins_mod.reportChanges(s);
    }

    var worker: render.Rasteriser = .{ .session = s, .io = ctx.io };
    worker.start() catch |err| {
        return ctx.fail("could not start the rasterising thread: {s}", .{@errorName(err)});
    };
    defer worker.stop();

    // Page one, asked for before the device exists.
    //
    // Rasterising it is CPU work and creating a Vulkan device and a
    // swapchain is the driver's; on this machine the second takes three
    // quarters of a second and the first a fifth of one, and doing them
    // one after the other meant the window appeared and then sat on blank
    // paper. Started here, the page is finished and waiting by the time
    // there is anything to upload it to. The worker fills one job and
    // blocks, so this costs one page of memory and no more.
    //
    // Only when the backend is already settled. A GPU session can still
    // fall back to the CPU if the path pipeline will not compile, and
    // `produce` reads `backend` on the worker thread -- starting before
    // that decision would be a race on it, and could rasterise the page
    // in the form the session turns out not to want.
    if (s.backend == .cpu) {
        if (render.nextJob(s)) |job| worker.post(job);
    }

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
    if (s.stage) |g| g.mark("device");

    var swapchain = lyngvi.Swapchain.init(gpa, &device, .{
        .width = size.width,
        .height = size.height,
    }, settings.vsync) catch |err| {
        return ctx.fail("could not create a swapchain: {s}", .{@errorName(err)});
    };
    defer swapchain.deinit();
    if (s.stage) |g| g.mark("swapchain");
    if (settings.shot != null) {
        swapchain.readable = true;
        swapchain.recreate(.{ .width = size.width, .height = size.height }) catch |err| {
            return ctx.fail("could not create a swapchain: {s}", .{@errorName(err)});
        };
    }

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
    if (s.stage) |g| g.mark("renderer");

    ctx.note("{s}, {d}x{d}, {s}, shaders from {s}", .{
        device.name(),
        swapchain.extent.width,
        swapchain.extent.height,
        @tagName(swapchain.present_mode),
        if (lyngvi.shaders.compiler.len == 0) "nowhere" else lyngvi.shaders.compiler,
    });
    if (renderer.shaders_missing) {
        ctx.note("no SPIR-V in this build, so the window clears and presents but draws nothing", .{});
        ctx.note("{s}", .{lyngvi.shaders.compile_hint});
        return;
    }

    // The analytic path pipeline, if this build has it and the reader is
    // using it. Created lazily: a `--path cpu` session should not pay for
    // storage buffers and a pipeline compile it will never bind.
    var paths_renderer: ?lyngvi.PathRenderer = if (have_gpu and s.backend == .gpu)
        lyngvi.PathRenderer.init(gpa, &device, &swapchain) catch |err| blk: {
            ctx.note("no GPU path pipeline ({s}); falling back to the CPU rasteriser", .{
                @errorName(err),
            });
            s.backend = .cpu;
            break :blk null;
        }
    else
        null;
    defer if (paths_renderer) |*p| p.deinit();
    if (s.stage) |g| g.mark("paths");

    if (paths_renderer) |p| {
        if (p.shaders_missing) {
            ctx.note("no SPIR-V for the path pipeline; falling back to the CPU rasteriser", .{});
            s.backend = .cpu;
        }
    }
    ctx.note("paths: {s}", .{@tagName(s.backend)});

    var list: DrawList = .init(gpa, .fromRect(0, 0, 1, 1));
    defer list.deinit();
    // The layer above the document: scrollbars, highlights, the caret,
    // and anything else that must not be covered by the page it sits on.
    var over: DrawList = .init(gpa, .fromRect(0, 0, 1, 1));
    defer over.deinit();

    // The atlas takes texture one on the device and on both lists,
    // before any page slot does. See `Chrome.attach` for why all three.
    if (s.chrome) |c| {
        c.attach(&renderer, &list, &over) catch |err| {
            ctx.note("no atlas for the interface ({s}); its text will draw as blocks", .{
                @errorName(err),
            });
        };
        c.theme = s.theme;
    }

    var uploads: std.ArrayList(lyngvi.Renderer.Upload) = .empty;
    defer uploads.deinit(gpa);

    var clock: lyngvi.Clock = .start(ctx.io);
    var drawn: u32 = 0;

    // `--time`: from one drawn frame to the next, and the placement, on
    // the CPU. The device's side is in `renderer.gpu_frame`.
    var interval: lyngvi.Renderer.Samples = .{};
    var placing: lyngvi.Renderer.Samples = .{};
    var lap: Lap = .start(ctx.io);
    // `?BenchDriver` and not `?Bench`: a build with no benchmark driver
    // holds an optional that cannot have a value, so the two blocks that
    // step the workload below fold away rather than testing a null every
    // frame.
    var bench: ?BenchDriver = null;
    if (caps.bench) {
        if (settings.bench) |kind| bench = .{ .kind = kind };
    }

    while (true) {
        window.pump();
        if (window.shouldClose()) break;
        if (settings.frames) |limit| {
            if (drawn >= limit) break;
        }

        const dt = clock.tick();
        const input = try window.events().take(dt);
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

        s.tabs.arrange(windowRect(
            s,
            @floatFromInt(swapchain.extent.width),
            @floatFromInt(swapchain.extent.height),
        ));
        if (s.handle(input)) break;
        reload.poll(s, dt);

        // Collect whatever the rasterising thread finished, and ask it
        // for the next page. Neither waits: the frame is drawn from what
        // is in the cache now, and a page still being worked on is blank
        // paper until it arrives.
        //
        // `pixels` stays alive until the frame is submitted, because
        // `Upload.pixels` is read during `frame`.
        var pixels: ?[]u8 = null;
        defer if (pixels) |p| gpa.free(p);
        pixels = render.collectPage(s, &worker, &renderer, &list, &uploads) catch |err| switch (err) {
            error.OutOfMemory => return ctx.fail("out of memory rendering a page", .{}),
            else => null,
        };
        // After what arrived is in and before the next job is chosen, so
        // the worker is asked for what the step just brought into view.
        if (bench) |*b| {
            if (render.firstMissing(s) != null) {
                b.waited += 1;
            } else if (b.pending) |*l| {
                // Arrived. Drawn for a frame before the next step, or a
                // flip would move on from every page unseen.
                b.arrival.push(msOf(l.lap()));
                b.pending = null;
            } else {
                if (!b.advance(s.view())) break;
                if (render.firstMissing(s) != null) b.pending = .start(ctx.io);
            }
        }
        if (reload.jobToPost(s)) |job| worker.post(job);

        // One resumption each for the handlers that yielded, and no more:
        // a handler that gave the frame back gets it back on the next
        // one, which is the whole of what a coroutine is promised here.
        if (s.plugins) |rt| {
            rt.pump();
            marks.applyEffects(s);
        }

        const extent: Bounds = .fromRect(
            0,
            0,
            @floatFromInt(swapchain.extent.width),
            @floatFromInt(swapchain.extent.height),
        );
        list.reset(extent);
        over.reset(extent);
        try compose(s, &list, &over);
        s.updateTitle(window);

        // The interface, on top of the page and the marks on it. The
        // same frame's input the keymap already read: Þviti derives
        // presses by comparing with last frame and consumes nothing, so
        // both may have it.
        if (s.chrome) |c| {
            try c.begin(extent, input);
            // Before anything that starts below the bar: the rails and
            // the panel are floated against the top of the window and
            // have to be told how much of it is already spoken for.
            if (caps.splits) c.top = windows.tabInset(s);
            const want = try c.status(s.statusLine());
            if (caps.splits) {
                if (try c.tabBar(windows.tabLabels(s), s.tabs.active)) |asked_tabs| windows.applyTabs(s, asked_tabs);
            }
            if (caps.panels) {
                const asked = try c.rightRail(interface.railLine(s));
                if (asked) |wanted| interface.applyRail(s, wanted);
                if (try c.leftRail(interface.modeRail(s))) |wanted| interface.applyRail(s, wanted);
                try interface.drawPanel(s, c);
            }
            const asked_find: ?find_mod.Action = if (caps.search) try find_mod.bar(
                &c.ui,
                c.face,
                c.theme,
                &c.icons,
                &s.find,
                search_mod.searchCount(s),
                c.top,
            ) else null;
            // After the bar, the rails and the panel, so it is over all
            // of them: a popup is on top by being built last, and nothing
            // here sorts.
            //
            // Refilled first when a plugin changed what it declared
            // while the page was open. Nothing is read from the library
            // unless Galdr's revision moved, so an open page costs one
            // comparison a frame.
            if (caps.panels and s.settings.open and interface.pluginSettingsStale(s)) interface.readSettings(s);
            const changed: ?settings_page.Change = if (caps.panels)
                try settings_page.page(&c.ui, c.face, c.theme, &s.settings)
            else
                null;
            const chosen: ?palette_mod.Chosen = if (caps.panels) try palette_mod.palette(
                &c.ui,
                c.face,
                c.theme,
                &c.icons,
                s.palette_rows.items,
                &s.palette,
            ) else null;
            // The rails' tooltips: nothing else in the chrome has one.
            if (caps.panels) try c.tips();
            c.end();
            if (want) |wanted| s.applyZoom(wanted);
            if (changed) |c2| interface.changeSetting(s, c2);
            if (asked_find) |what| search_mod.applyFind(s, what);
            // After the frame is closed, because a command may open
            // another window, close this one, or leave the reader.
            if (chosen) |what| interface.runChosen(s, what);
            try c.flush(&over, &list, &renderer, &uploads);
        }

        // The path pass, between the two rect lists. Placing is a matrix
        // per instance and nothing else, so this runs every frame even
        // while scrolling at the refresh rate.
        var paths: ?lyngvi.Renderer.Paths = null;
        if (s.backend == .gpu) {
            if (paths_renderer) |*pr| {
                // Only when something has actually moved. A reader
                // sitting still then uploads nothing at all: the outlines
                // are on the device and so is the placement.
                const key = render.placementKey(s);
                if (s.placed == null or s.placed.? != key) {
                    var place_lap: Lap = .start(ctx.io);
                    try render.placeVisible(s);
                    s.placed = key;
                    if (settings.time) placing.push(msOf(place_lap.lap()));
                }
                paths = .{
                    .renderer = pr,
                    .scene = &s.recorded.scene,
                    .frame = &s.recorded.frame,
                };
            }
        }

        // A shot waits for every visible page, or gives up after a few
        // seconds' worth of frames and takes what there is.
        const shooting = settings.shot != null and
            (render.firstMissing(s) == null or drawn >= shot_patience);
        renderer.capture_next = shooting;

        switch (try renderer.frameWith(&list, uploads.items, s.theme.ground, paths, &over)) {
            .drawn => {
                // The first frame and the first frame with the page on
                // it are different moments, and the second is the one a
                // reader calls "started". The window is up before the
                // worker has finished page one, so the two are reported
                // separately rather than as one number.
                if (drawn == 0) {
                    if (s.stage) |g| g.mark("first frame");
                }
                if (s.pages_rendered != 0) {
                    if (s.stage) |g| {
                        g.mark("first page");
                        s.stage = null;
                    }
                }
                drawn += 1;
                // The first interval is startup, which `Stage` reports,
                // and under a bench a frame waiting for a page is the
                // arrival's, which it reports.
                const since = lap.lap();
                const steady = if (bench) |b| b.pending == null else true;
                if (settings.time and drawn > 1 and steady) interval.push(msOf(since));
                if (shooting) {
                    if (renderer.captured) |c| try writeShot(s, settings.shot.?, c);
                    break;
                }
            },
            .needs_recreate => {
                try swapchain.recreate(.{ .width = client.width, .height = client.height });
                try renderer.refresh();
            },
            .skipped => window.wait(100),
        }
        uploads.clearRetainingCapacity();
    }

    renderer.waitIdle();
    // Before the place is written, so a plugin that moves on `quit` is
    // remembered where it left the reader.
    if (s.plugins) |rt| {
        rt.emit(.{
            .event = .Quit,
            .doc = plugins_mod.handleOf(s, s.view().buffer),
            .path = s.buffer(s.view().buffer).path,
        });
        marks.applyEffects(s);
    }
    s.rememberAll();
    ctx.note("{d} frames drawn, {d} pages prepared, {d} MiB uploaded", .{
        renderer.frames_drawn,
        s.pages_rendered,
        renderer.bytes_uploaded / (1024 * 1024),
    });
    if (paths_renderer) |p| {
        ctx.note(
            "paths: {d} instances at most, {d} curves, {d} image texels, {d} draw calls over {d} frames, {d} MiB uploaded",
            .{
                p.instance_high_water,
                p.curve_high_water,
                p.texel_high_water,
                p.draw_calls,
                renderer.frames_drawn,
                p.bytes_uploaded / (1024 * 1024),
            },
        );
        const stats = s.recorded.scene.stats;
        if (stats.blended != 0 or stats.clips_too_deep != 0 or stats.images_dropped != 0) {
            ctx.note(
                "         {d} with a blend mode drawn normal, {d} clips too deep, {d} images over the texel budget",
                .{ stats.blended, stats.clips_too_deep, stats.images_dropped },
            );
        }
    }
    if (bench) |*b| {
        ctx.note("bench  {t}: {d} steps, {d} frames drawn waiting for a page", .{ b.kind, b.step, b.waited });
        reportSpread(ctx, "arrival", &b.arrival);
    }
    if (settings.time) {
        reportSpread(ctx, "frame", &interval);
        reportSpread(ctx, "place", &placing);
        if (paths_renderer) |*p| {
            if (p.memoryType()) |t| {
                const kind = device.memory.memory_types[t];
                ctx.note("time   paths in   {s}, of a {d} MiB heap", .{
                    lyngvi.choose.memoryKind(kind.property_flags),
                    device.memory.memory_heaps[kind.heap_index].size >> 20,
                });
            } else {
                ctx.note("time   paths in   more than one kind of memory", .{});
            }
        }
        if (renderer.query_pool == lyngvi.vk.null_handle) {
            ctx.note("time   this queue keeps no timestamps; no device times", .{});
        } else {
            reportSpread(ctx, "gpu frame", &renderer.gpu_frame);
            if (paths_renderer != null) reportSpread(ctx, "gpu paths", &renderer.gpu_paths);
        }
        const frames: f64 = @floatFromInt(@max(renderer.frames_drawn, 1));
        const paths_bytes = if (paths_renderer) |p| p.bytes_uploaded else 0;
        ctx.note("time   uploads    {d:.1} KiB a frame for rects and textures, {d:.1} for paths", .{
            @as(f64, @floatFromInt(renderer.bytes_uploaded)) / 1024.0 / frames,
            @as(f64, @floatFromInt(paths_bytes)) / 1024.0 / frames,
        });
    }
}

/// Writes a frame read back from the device.
fn writeShot(s: *Session, dest: []const u8, c: lyngvi.Renderer.Capture) !void {
    const ctx = s.ctx;
    var file = Io.Dir.cwd().createFile(ctx.io, dest, .{}) catch |err|
        return ctx.fail("cannot create {s}: {t}", .{ dest, err });
    defer file.close(ctx.io);

    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(ctx.io, &buf);
    gleipnir.png.write(s.gpa, &writer.interface, c.pixels, c.width, c.height) catch |err|
        return ctx.fail("cannot write {s}: {t}", .{ dest, err });
    writer.interface.flush() catch |err|
        return ctx.fail("cannot write {s}: {t}", .{ dest, err });

    ctx.out.print("wrote {d}x{d} to {s}: read back from the device, paths on the {s}, at {d:.0}%\n", .{
        c.width,
        c.height,
        dest,
        @tagName(s.backend),
        s.view().percent(),
    }) catch {};
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const closeSession = fixtures.closeSession;
const fakePages = fixtures.fakePages;
const sessionOf = fixtures.sessionOf;

test "each bench workload runs its course and then stops" {
    const gpa = testing.allocator;
    var buf: [8]fenrir.Page = undefined;
    var s = try sessionOf(gpa, fakePages(&buf, 8), 1, 1000, 800);
    defer closeSession(&s);

    // Every page once, ending on the last.
    var flip: Bench = .{ .kind = .flip };
    var steps: u32 = 0;
    while (flip.advance(s.view())) steps += 1;
    try testing.expectEqual(@as(u32, 8), steps);
    try testing.expectEqual(@as(u32, 7), s.view().currentPage());

    // From half size to the limit and back, twice, and nowhere outside that.
    var zoom: Bench = .{ .kind = .zoom };
    var lo: f32 = max_zoom;
    var hi: f32 = 0;
    steps = 0;
    while (zoom.advance(s.view())) : (steps += 1) {
        lo = @min(lo, s.view().zoom);
        hi = @max(hi, s.view().zoom);
    }
    try testing.expectEqual(Bench.zoom_legs * zoom.zoom_steps, steps);
    try testing.expectApproxEqRel(0.5 * s.view().hundredPercent(), lo, 1e-5);
    try testing.expectEqual(max_zoom, hi);

    // Top to bottom, twenty steps a page.
    s.view().setZoom(1);
    var scroll: Bench = .{ .kind = .scroll };
    steps = 0;
    while (scroll.advance(s.view())) steps += 1;
    try testing.expectEqual(s.view().maxScroll(), s.view().scroll);
    try testing.expect(steps > 7 * 20 and steps < 8 * 20);
}
